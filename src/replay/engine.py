"""Deterministic replay engine.

No LLM in the loop. Reads a CapabilityArtifact, substitutes parameters,
executes each step, verifies checkpoints, and returns a structured outcome.
"""

from __future__ import annotations

import json
import time
from typing import Any, Callable, Dict, Optional

from playwright.sync_api import Page

from ..artifact.schema import (
    ActionType,
    CapabilityArtifact,
    ErrorKind,
    RiskLevel,
    Step,
)
from ..evidence.logger import RunLogger
from ..safety.allowlist import Allowlist, SafetyViolation
from . import locator as loc_mod
from .checkpoint import verify as verify_checkpoint
from .errors import (
    OutcomeKind,
    ReplayOutcome,
    StepFailure,
    detect_known_outcome,
)


# A confirmation callback: given (step, message) returns True to proceed.
ConfirmFn = Callable[[Step, str], bool]


def _default_confirm(step: Step, message: str) -> bool:
    # Non-interactive default: refuse risky actions rather than silently doing them.
    print(f"[safety] Refusing without confirmation: {message}")
    return False


class ReplayEngine:
    def __init__(
        self,
        page: Page,
        allowlist: Allowlist,
        logger: RunLogger,
        confirm: Optional[ConfirmFn] = None,
    ) -> None:
        self.page = page
        self.allowlist = allowlist
        self.logger = logger
        self.confirm = confirm or _default_confirm

    # -- public ------------------------------------------------------------
    def run(self, artifact: CapabilityArtifact, params: Dict[str, Any]) -> ReplayOutcome:
        self.logger.log(
            "replay.start",
            artifact_id=artifact.id,
            version=artifact.version,
            params={k: v for k, v in params.items()},
        )

        # Validate params
        missing = [
            p.name for p in artifact.parameters
            if p.required and p.name not in params
        ]
        if missing:
            return ReplayOutcome(
                kind=OutcomeKind.FAILURE,
                code="MISSING_PARAMS",
                message=f"Missing required parameters: {missing}",
            )

        outputs: Dict[str, Any] = {}

        try:
            entry = artifact.render_value(artifact.target.entry_url, params) or artifact.target.entry_url
            self.page.goto(entry, wait_until="domcontentloaded")
            self.allowlist.enforce_url(self.page.url)
        except SafetyViolation as exc:
            return ReplayOutcome(
                kind=OutcomeKind.FAILURE, code="SAFETY_BLOCK",
                message=str(exc),
            )

        for step in artifact.steps:
            outcome = self._execute_step(step, artifact, params, outputs)
            if outcome is not None:
                self.logger.write_result(outcome.to_dict())
                return outcome

        # Final checkpoint
        passed, observed = verify_checkpoint(self.page, artifact.checkpoint)
        if not passed:
            self._capture_failure_evidence("final_checkpoint")
            outcome = ReplayOutcome(
                kind=OutcomeKind.FAILURE,
                code="CHECKPOINT_FAILED",
                message=artifact.checkpoint.description,
                outputs=outputs,
                expected=artifact.checkpoint.description,
                observed=observed,
                evidence_path=str(self.logger.path),
            )
            self.logger.write_result(outcome.to_dict())
            return outcome

        outcome = ReplayOutcome(
            kind=OutcomeKind.SUCCESS,
            code="OK",
            message="Replay completed and checkpoint verified.",
            outputs=outputs,
            evidence_path=str(self.logger.path),
        )
        self.logger.log("replay.success", outputs=list(outputs.keys()))
        self.logger.write_result(outcome.to_dict())
        return outcome

    # -- internals ---------------------------------------------------------
    def _execute_step(
        self,
        step: Step,
        artifact: CapabilityArtifact,
        params: Dict[str, Any],
        outputs: Dict[str, Any],
    ) -> Optional[ReplayOutcome]:
        # Safety gate
        try:
            decision = self.allowlist.enforce_action(step.action, step.risk)
        except SafetyViolation as exc:
            return ReplayOutcome(
                kind=OutcomeKind.FAILURE, code="SAFETY_BLOCK",
                message=str(exc), step_id=step.id,
                evidence_path=str(self.logger.path),
            )

        if decision.requires_confirmation:
            approved = self.confirm(step, decision.reason)
            if not approved:
                return ReplayOutcome(
                    kind=OutcomeKind.FAILURE,
                    code="CONFIRMATION_DENIED",
                    message=f"Risky step {step.id} not confirmed",
                    step_id=step.id,
                )

        # Resolve value with params
        value = artifact.render_value(step.value, params)

        self.logger.log("replay.step", step_id=step.id, action=step.action.value,
                        description=step.description, risk=step.risk.value)

        # Pre-step business / recoverable detection: check for known error surface
        pre_outcome = self._detect_pre_step_outcome(step, outputs)
        if pre_outcome is not None:
            return pre_outcome

        try:
            self._perform(step, value)
        except StepFailure as exc:
            return self._handle_step_failure(step, exc, outputs)
        except Exception as exc:
            self._capture_failure_evidence(step.id)
            return ReplayOutcome(
                kind=OutcomeKind.FAILURE, code="STEP_ACTION_ERROR",
                message=f"{type(exc).__name__}: {exc}",
                step_id=step.id,
                evidence_path=str(self.logger.path),
            )

        # Post-step: read into outputs if action is READ
        if step.action == ActionType.READ and step.locator is not None:
            try:
                loc = loc_mod.resolve(self.page, step.locator, step.timeout_ms)
                text = loc.first.inner_text(timeout=step.timeout_ms)
                name = step.description.split("->")[-1].strip() if "->" in step.description else step.id
                # Prefer output declared in artifact with from_step == step.id
                declared = next((o for o in artifact.outputs if o.from_step == step.id), None)
                key = declared.name if declared else name
                outputs[key] = text
                self.logger.log("replay.read", step_id=step.id, output_name=key)
            except Exception as exc:
                self.logger.log("replay.read_error", step_id=step.id, error=str(exc))

        # Post-step: explicit checkpoint
        if step.post_checkpoint is not None:
            passed, observed = verify_checkpoint(self.page, step.post_checkpoint)
            if not passed:
                self._capture_failure_evidence(f"{step.id}_checkpoint")
                return ReplayOutcome(
                    kind=OutcomeKind.FAILURE,
                    code="CHECKPOINT_FAILED",
                    message=step.post_checkpoint.description,
                    outputs=outputs,
                    step_id=step.id,
                    expected=step.post_checkpoint.description,
                    observed=observed,
                    evidence_path=str(self.logger.path),
                )

        # Post-step: detect known business outcomes
        post_outcome = self._detect_known_outcome_after(step, outputs)
        if post_outcome is not None:
            return post_outcome

        return None

    def _perform(self, step: Step, value: Optional[str]) -> None:
        page = self.page
        if step.action == ActionType.NAVIGATE:
            if not value:
                raise StepFailure("MISSING_VALUE", "navigate step has no URL",
                                  step_id=step.id)
            self.allowlist.enforce_url(value)
            page.goto(value, wait_until="domcontentloaded")
            return

        if step.locator is None:
            raise StepFailure("MISSING_LOCATOR", f"{step.action.value} requires locator",
                              step_id=step.id)

        loc = loc_mod.resolve(page, step.locator, step.timeout_ms)

        if step.action == ActionType.CLICK:
            loc.first.click(timeout=step.timeout_ms)
            try:
                page.wait_for_load_state("networkidle", timeout=3000)
            except Exception:
                pass
        elif step.action == ActionType.FILL:
            loc.first.fill(value or "", timeout=step.timeout_ms)
        elif step.action == ActionType.SELECT:
            loc.first.select_option(label=value or "", timeout=step.timeout_ms)
        elif step.action == ActionType.PRESS:
            loc.first.press(value or "Enter", timeout=step.timeout_ms)
        elif step.action == ActionType.WAIT_FOR:
            loc.first.wait_for(state="visible", timeout=step.timeout_ms)
        elif step.action == ActionType.ASSERT_TEXT:
            text = loc.first.inner_text(timeout=step.timeout_ms)
            if value and value.lower() not in text.lower():
                raise StepFailure(
                    "ASSERT_FAILED",
                    f"Expected {value!r} in {text!r}",
                    expected=value, observed=text, step_id=step.id,
                )
        elif step.action == ActionType.SCREENSHOT:
            self.page.screenshot(path=str(self.logger.screenshot_path(step.id)))
        # READ handled by caller
        return

    # -- detection helpers -------------------------------------------------
    def _detect_pre_step_outcome(
        self, step: Step, outputs: Dict[str, Any]
    ) -> Optional[ReplayOutcome]:
        # Look for error surfaces already present before this step.
        try:
            body = self.page.evaluate("() => document.body ? document.body.innerText : ''")
        except Exception:
            body = ""
        detected = detect_known_outcome(body)
        if detected is None:
            return None
        code, kind = detected
        if kind == ErrorKind.RECOVERABLE:
            # try to recover: if session expired, re-login is the caller's concern.
            self.logger.log("replay.recoverable", step_id=step.id, code=code)
            # We don't re-login here; instead surface as business-level recoverable
            return ReplayOutcome(
                kind=OutcomeKind.BUSINESS, code=code,
                message="Recoverable condition encountered (session).",
                step_id=step.id, evidence_path=str(self.logger.path),
            )
        if kind == ErrorKind.BUSINESS:
            self._capture_failure_evidence(f"{step.id}_business")
            return ReplayOutcome(
                kind=OutcomeKind.BUSINESS, code=code,
                message=f"Business outcome {code} detected before step {step.id}",
                outputs=outputs, step_id=step.id,
                evidence_path=str(self.logger.path),
            )
        return None

    def _detect_known_outcome_after(
        self, step: Step, outputs: Dict[str, Any]
    ) -> Optional[ReplayOutcome]:
        try:
            body = self.page.evaluate("() => document.body ? document.body.innerText : ''")
        except Exception:
            body = ""
        detected = detect_known_outcome(body)
        if detected is None:
            return None
        code, kind = detected
        if kind == ErrorKind.BUSINESS:
            self._capture_failure_evidence(f"{step.id}_business")
            return ReplayOutcome(
                kind=OutcomeKind.BUSINESS, code=code,
                message=f"Business outcome {code} at step {step.id}",
                outputs=outputs, step_id=step.id,
                evidence_path=str(self.logger.path),
            )
        return None

    def _handle_step_failure(
        self, step: Step, exc: StepFailure, outputs: Dict[str, Any]
    ) -> ReplayOutcome:
        # Check declared error handlers for this step
        for handler in step.error_handlers:
            if handler.code == exc.code or handler.kind == ErrorKind.BUSINESS:
                if handler.kind == ErrorKind.BUSINESS:
                    return ReplayOutcome(
                        kind=OutcomeKind.BUSINESS, code=handler.code,
                        message=handler.message or exc.message,
                        outputs=outputs, step_id=step.id,
                        evidence_path=str(self.logger.path),
                    )
                if handler.kind == ErrorKind.RECOVERABLE and handler.recover_action == "retry":
                    for _ in range(handler.max_retries):
                        try:
                            self._perform(step, None)
                            return None  # type: ignore[return-value]
                        except Exception:
                            continue
        self._capture_failure_evidence(step.id)
        return ReplayOutcome(
            kind=OutcomeKind.FAILURE, code=exc.code, message=exc.message,
            outputs=outputs, step_id=step.id,
            expected=exc.expected, observed=exc.observed,
            evidence_path=str(self.logger.path),
        )

    def _capture_failure_evidence(self, tag: str) -> None:
        try:
            self.page.screenshot(path=str(self.logger.screenshot_path(f"failure_{tag}")))
        except Exception:
            pass
        try:
            html = self.page.content()
            self.logger.dom_path(f"failure_{tag}").write_text(html, encoding="utf-8")
        except Exception:
            pass