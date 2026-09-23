"""Deterministic replay engine.

No LLM in the loop. Reads a CapabilityArtifact, substitutes parameters,
executes each step, verifies checkpoints, and returns a structured outcome.

Error handling design:

  Each step may declare a list of ErrorHandlers. They are evaluated in three
  places, in this order:

    1) BEFORE the step action: if the page already shows a matching error
       surface, we short-circuit and return the appropriate outcome.
    2) ON step failure: if the action raised, we check the declared handlers
       before falling back to a generic failure.
    3) AFTER the step action: the same check runs again, in case the action
       itself produced the error state.

  Detection is content-based (innerText, in the main frame AND all iframes)
  and polling-based: when a handler declares `detect_text`, we wait up to
  `poll_timeout_ms` for it to appear before declaring "not matched". This is
  what makes iframe-based legacy UIs work: content arrives asynchronously
  after the click and is not on screen instantly.

  A separate global signature table catches generic error surfaces that were
  not declared per-step, as a safety net.
"""

from __future__ import annotations

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


ConfirmFn = Callable[[Step, str], bool]

# Tunables
CLICK_SETTLE_MS = 300            # pause after click before observing
HANDLER_POLL_TIMEOUT_MS = 3000   # wait for detect_text to appear
HANDLER_POLL_INTERVAL_S = 0.2


def _default_confirm(step: Step, message: str) -> bool:
    print(f"[safety] Refusing without confirmation: {message}")
    return False


def _all_frames_text(page: Page) -> str:
    """Concatenate innerText across the main frame and every child iframe."""
    chunks = []
    try:
        frames = list(page.frames)
    except Exception:
        frames = []
    for fr in frames:
        try:
            txt = fr.evaluate("() => document.body ? document.body.innerText : ''")
            if txt:
                chunks.append(txt)
        except Exception:
            continue
    return "\n".join(chunks)


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
            params=dict(params),
        )

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
            entry = (
                artifact.render_value(artifact.target.entry_url, params)
                or artifact.target.entry_url
            )
            self.page.goto(entry, wait_until="domcontentloaded")
            self.allowlist.enforce_url(self.page.url)
        except SafetyViolation as exc:
            return ReplayOutcome(
                kind=OutcomeKind.FAILURE, code="SAFETY_BLOCK", message=str(exc),
            )

        for step in artifact.steps:
            outcome = self._execute_step(step, artifact, params, outputs)
            if outcome is not None:
                self.logger.write_result(outcome.to_dict())
                return outcome

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

        value = artifact.render_value(step.value, params)

        self.logger.log(
            "replay.step", step_id=step.id, action=step.action.value,
            description=step.description, risk=step.risk.value,
        )

        # (1) Check declared handlers BEFORE the action.
        declared = self._check_declared_handlers(step, outputs, tag="pre", poll=False)
        if declared is not None:
            return declared

        # (2) Perform the action.
        try:
            self._perform(step, value)
        except StepFailure as exc:
            return self._handle_step_failure(step, exc, outputs)
        except Exception as exc:
            declared = self._check_declared_handlers(step, outputs, tag="on_error", poll=False)
            if declared is not None:
                return declared
            self._capture_failure_evidence(step.id)
            return ReplayOutcome(
                kind=OutcomeKind.FAILURE, code="STEP_ACTION_ERROR",
                message=f"{type(exc).__name__}: {exc}",
                step_id=step.id,
                evidence_path=str(self.logger.path),
            )

        # Small settle after click so iframes can re-render before we poll.
        if step.action == ActionType.CLICK:
            time.sleep(CLICK_SETTLE_MS / 1000.0)

        # (3) READ output extraction.
        if step.action == ActionType.READ and step.locator is not None:
            try:
                loc = loc_mod.resolve(self.page, step.locator, step.timeout_ms)
                text = loc.first.inner_text(timeout=step.timeout_ms)
                name = step.description.split("->")[-1].strip() if "->" in step.description else step.id
                declared_out = next(
                    (o for o in artifact.outputs if o.from_step == step.id), None
                )
                key = declared_out.name if declared_out else name
                outputs[key] = text
                self.logger.log("replay.read", step_id=step.id, output_name=key)
            except Exception as exc:
                self.logger.log("replay.read_error", step_id=step.id, error=str(exc))

        # (4) Check declared handlers AFTER the action.
        _poll_post = step.action in (ActionType.CLICK, ActionType.NAVIGATE)
        declared = self._check_declared_handlers(
            step, outputs, tag="post", poll=_poll_post
        )
        if declared is not None:
            return declared

        # (5) Post-step explicit checkpoint.
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

        # (6) Global signature fallback.
        post_outcome = self._detect_global_signature(step, outputs)
        if post_outcome is not None:
            return post_outcome

        return None

    # ------------------------------------------------------------------
    def _check_declared_handlers(
        self,
        step: Step,
        outputs: Dict[str, Any],
        tag: str,
        poll: bool = False,
    ) -> Optional[ReplayOutcome]:
        """Evaluate this step's declared error_handlers. Return an outcome or None.

        `poll=True` is used after a state-changing action (click, navigate):
        we wait up to HANDLER_POLL_TIMEOUT_MS for a detect_text to appear,
        because the page content may still be rendering inside an iframe.

        `poll=False` is used before an action or on non-state-changing steps:
        we do a single check. This avoids wasting 5s per handler when we are
        simply verifying "is the page already in an error state".
        """
        if not step.error_handlers:
            return None

        for handler in step.error_handlers:
            matched = False

            # -- detect_text
            if handler.detect_text:
                needle = handler.detect_text.lower()
                if poll:
                    deadline = time.time() + HANDLER_POLL_TIMEOUT_MS / 1000.0
                    while True:
                        body = _all_frames_text(self.page)
                        if needle in body.lower():
                            matched = True
                            break
                        if time.time() >= deadline:
                            break
                        time.sleep(HANDLER_POLL_INTERVAL_S)
                else:
                    body = _all_frames_text(self.page)
                    if needle in body.lower():
                        matched = True

            # -- detect_locator: single check (visibility)
            if not matched and handler.detect_locator is not None:
                try:
                    loc = loc_mod.resolve(
                        self.page, handler.detect_locator, timeout_ms=1500
                    )
                    if loc.first.is_visible(timeout=500):
                        matched = True
                except Exception:
                    pass

            if not matched:
                continue

            self.logger.log(
                "replay.declared_handler_matched",
                step_id=step.id, tag=tag,
                code=handler.code, kind=handler.kind.value,
            )
            self._capture_failure_evidence(f"{step.id}_{handler.code}")

            if handler.kind == ErrorKind.BUSINESS:
                return ReplayOutcome(
                    kind=OutcomeKind.BUSINESS,
                    code=handler.code,
                    message=handler.message or f"Business outcome {handler.code}",
                    outputs=outputs,
                    step_id=step.id,
                    evidence_path=str(self.logger.path),
                )
            if handler.kind == ErrorKind.HARD:
                return ReplayOutcome(
                    kind=OutcomeKind.FAILURE,
                    code=handler.code,
                    message=handler.message or f"Hard failure {handler.code}",
                    outputs=outputs,
                    step_id=step.id,
                    evidence_path=str(self.logger.path),
                )
            if handler.kind == ErrorKind.RECOVERABLE:
                if handler.recover_action == "skip":
                    self.logger.log("replay.recover_skip", step_id=step.id)
                    return None
                return ReplayOutcome(
                    kind=OutcomeKind.BUSINESS,
                    code=handler.code,
                    message=handler.message or f"Recoverable condition {handler.code}",
                    outputs=outputs, step_id=step.id,
                    evidence_path=str(self.logger.path),
                )

        return None

    # ------------------------------------------------------------------
    def _detect_global_signature(
        self, step: Step, outputs: Dict[str, Any]
    ) -> Optional[ReplayOutcome]:
        body = _all_frames_text(self.page)
        detected = detect_known_outcome(body)
        if detected is None:
            return None
        code, kind = detected
        if kind == ErrorKind.BUSINESS:
            self._capture_failure_evidence(f"{step.id}_global_{code}")
            return ReplayOutcome(
                kind=OutcomeKind.BUSINESS, code=code,
                message=f"Business outcome {code} at step {step.id}",
                outputs=outputs, step_id=step.id,
                evidence_path=str(self.logger.path),
            )
        return None

    # ------------------------------------------------------------------
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
            raise StepFailure("MISSING_LOCATOR",
                              f"{step.action.value} requires locator",
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
        return

    # ------------------------------------------------------------------
    def _handle_step_failure(
        self, step: Step, exc: StepFailure, outputs: Dict[str, Any]
    ) -> ReplayOutcome:
        declared = self._check_declared_handlers(step, outputs, tag="on_stepfailure", poll=False)
        if declared is not None:
            return declared

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

    # ------------------------------------------------------------------
    def _capture_failure_evidence(self, tag: str) -> None:
        try:
            self.page.screenshot(
                path=str(self.logger.screenshot_path(f"failure_{tag}"))
            )
        except Exception:
            pass
        try:
            html = self.page.content()
            self.logger.dom_path(f"failure_{tag}").write_text(html, encoding="utf-8")
        except Exception:
            pass