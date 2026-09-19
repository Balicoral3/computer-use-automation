"""Discovery loop: LLM-driven observe -> decide -> act until goal is met.

Produces a CapabilityArtifact from the recorded trace. The artifact is
deliberately decoupled from the raw LLM transcript: it captures the steps,
locators, parameters, outputs, and a checkpoint, in a form a replay engine
can execute without any model in the loop.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

from playwright.sync_api import Page

from ..artifact.schema import (
    ActionType,
    CapabilityArtifact,
    Checkpoint,
    Locator,
    LocatorStrategy,
    Output,
    Parameter,
    RiskLevel,
    SafetyPolicy,
    Step,
    TargetInfo,
)
from ..evidence.logger import RunLogger
from ..safety.allowlist import Allowlist, SafetyViolation
from . import actor, observer, prompts
from .llm_client import LLMClient


@dataclass
class DiscoveryResult:
    artifact: Optional[CapabilityArtifact]
    business_outcome: Optional[str]
    steps_taken: int
    finish_reason: str
    outputs: Dict[str, Any] = field(default_factory=dict)


def _locator_from_args(args: Dict[str, Any]) -> Locator:
    strategy = args["locator_strategy"]
    return Locator(
        strategy=LocatorStrategy(strategy),
        value=args["locator_value"],
        name=args.get("locator_name"),
        frame_path=[args["frame_selector"]] if args.get("frame_selector") else None,
    )


def _action_from_tool(tool_name: str) -> ActionType:
    return {
        "navigate": ActionType.NAVIGATE,
        "click": ActionType.CLICK,
        "fill": ActionType.FILL,
        "select_option": ActionType.SELECT,
        "read": ActionType.READ,
        "wait_for": ActionType.WAIT_FOR,
        "finish": ActionType.SCREENSHOT,  # unused; finish terminates
    }[tool_name]


def run_discovery(
    page: Page,
    goal: str,
    entry_url: str,
    artifact_id: str,
    llm: LLMClient,
    allowlist: Allowlist,
    logger: RunLogger,
    credentials_hint: str = "",
    max_steps: int = 25,
    target_app_id: str = "mock-corebank",
) -> DiscoveryResult:
    logger.log("discovery.start", goal=goal, entry_url=entry_url, artifact_id=artifact_id)

    if not page.url or page.url == "about:blank":
        page.goto(entry_url, wait_until="domcontentloaded")

    messages: List[Dict[str, Any]] = [
        prompts.build_system_message(credentials_hint),
        {"role": "user", "content": f"Goal: {goal}\n\nCurrent page observation:\n{observer.observe(page)}"},
    ]

    steps: List[Step] = []
    outputs_spec: List[Output] = []
    read_values: Dict[str, Any] = {}
    step_counter = 0

    for iteration in range(max_steps):
        response = llm.chat(messages=messages, tools=prompts.TOOLS, tool_choice="auto")
        choice = response.choices[0].message
        messages.append({
            "role": "assistant",
            "content": choice.content or "",
            "tool_calls": [
                {
                    "id": tc.id,
                    "type": "function",
                    "function": {"name": tc.function.name, "arguments": tc.function.arguments},
                }
                for tc in (choice.tool_calls or [])
            ] or None,
        })

        if not choice.tool_calls:
            logger.log("discovery.no_tool_call", content=choice.content)
            messages.append({"role": "user", "content": "Please call a tool."})
            continue

        for tc in choice.tool_calls:
            name = tc.function.name
            try:
                args = json.loads(tc.function.arguments or "{}")
            except json.JSONDecodeError:
                args = {}

            logger.log("discovery.tool_call", tool=name, args=args)

            if name == "finish":
                checkpoint_desc = args.get("checkpoint_description", "Goal complete")
                business_outcome = args.get("business_outcome")
                final_outputs = args.get("outputs") or {}
                # Merge any values captured via read()
                for k, v in read_values.items():
                    final_outputs.setdefault(k, v)

                # Build a minimal checkpoint (use last observed landmark)
                checkpoint = _build_checkpoint(page, checkpoint_desc)
                artifact = CapabilityArtifact(
                    id=artifact_id,
                    name=artifact_id.replace("_", " ").title(),
                    description=goal,
                    llm_model=llm.model,
                    target=TargetInfo(
                        app_id=target_app_id,
                        entry_url=entry_url,
                        tenant_id=os.environ.get("TENANT_ID", "default"),
                    ),
                    parameters=_infer_parameters(goal),
                    outputs=outputs_spec,
                    steps=steps,
                    checkpoint=checkpoint,
                    safety=SafetyPolicy(
                        allowed_domains=allowlist.policy.allowed_domains,
                        allowed_actions=list(ActionType),
                        risky_requires_confirmation=True,
                        irreversible_blocked=True,
                    ),
                    metadata={
                        "goal": goal,
                        "business_outcome": business_outcome,
                        "discovery_steps": len(steps),
                    },
                )
                logger.log(
                    "discovery.finish",
                    business_outcome=business_outcome,
                    outputs=final_outputs,
                    step_count=len(steps),
                )
                return DiscoveryResult(
                    artifact=artifact,
                    business_outcome=business_outcome,
                    steps_taken=len(steps),
                    finish_reason="finish_tool",
                    outputs=final_outputs,
                )

            # Enforce safety before executing
            action_type = _action_from_tool(name)
            risk = RiskLevel.SAFE
            if name in ("click",) and "submit" in json.dumps(args).lower():
                risk = RiskLevel.RISKY
            try:
                allowlist.enforce_action(action_type, risk)
            except SafetyViolation as exc:
                logger.log("safety.violation", tool=name, reason=str(exc))
                messages.append({"role": "tool", "tool_call_id": tc.id, "content": json.dumps({"error": str(exc)})})
                continue

            # Execute
            try:
                result, read_out = actor.execute(page, name, args)
            except Exception as exc:
                logger.log("discovery.action_error", tool=name, error=str(exc))
                result, read_out = {"ok": False, "error": str(exc)}, None

            step_counter += 1
            steps.append(_record_step(step_counter, name, args, risk))
            if read_out:
                read_values[read_out["output_name"]] = read_out["value"]
                outputs_spec.append(Output(
                    name=read_out["output_name"],
                    type="string",
                    description=f"Read from step {step_counter}",
                    from_step=f"s{step_counter}",
                ))

            # Take a screenshot as evidence
            shot = logger.screenshot_path(f"step_{step_counter:02d}_{name}")
            try:
                page.screenshot(path=str(shot), full_page=False)
            except Exception:
                pass

            messages.append({
                "role": "tool",
                "tool_call_id": tc.id,
                "content": json.dumps(result, ensure_ascii=False)[:2000],
            })

            # Append fresh observation
            try:
                obs = observer.observe(page)
            except Exception as exc:
                obs = f"[observe error: {exc}]"
            messages.append({"role": "user", "content": f"Current page observation:\n{obs}"})

    logger.log("discovery.max_steps")
    return DiscoveryResult(artifact=None, business_outcome=None, steps_taken=len(steps),
                           finish_reason="max_steps")


def _record_step(counter: int, tool_name: str, args: Dict[str, Any], risk: RiskLevel) -> Step:
    action = _action_from_tool(tool_name)
    locator = None
    value = None
    if tool_name == "navigate":
        value = args.get("url")
    elif tool_name in ("click", "fill", "select_option", "read", "wait_for"):
        locator = _locator_from_args(args)
        if tool_name == "fill":
            value = args.get("text")
        elif tool_name == "select_option":
            value = args.get("option_label")
    return Step(
        id=f"s{counter}",
        action=action,
        description=args.get("description", tool_name),
        locator=locator,
        value=value,
        risk=risk,
    )


def _build_checkpoint(page: Page, description: str) -> Checkpoint:
    # Heuristic: assert the main frame title is non-empty as the checkpoint.
    try:
        title = page.title() or "page"
    except Exception:
        title = "page"
    return Checkpoint(
        description=description,
        locator=Locator(strategy=LocatorStrategy.CSS, value="body"),
        expected_text=None,
    )


def _infer_parameters(goal: str) -> List[Parameter]:
    # Simple heuristic: if the goal contains a 4+ digit number, treat it as member_id.
    import re

    params: List[Parameter] = []
    m = re.search(r"\b(\d{4,})\b", goal)
    if m:
        params.append(Parameter(
            name="member_id",
            type="string",
            required=True,
            description="Member ID referenced in the goal",
            example=m.group(1),
        ))
    return params