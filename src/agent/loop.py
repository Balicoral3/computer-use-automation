"""Discovery loop: LLM-driven observe -> decide -> act until goal is met.

Produces a CapabilityArtifact from the recorded trace. The artifact is
deliberately decoupled from the raw LLM transcript.

Robustness note: some providers (notably gpt-oss on Groq) occasionally
emit tool calls with a name that is not in our tool list (e.g. their
internal "commentary" channel). The provider rejects the call with a 400
before we ever see it. We catch that specific failure and retry the same
turn with an explicit correction, bounded by a small retry budget.
"""

from __future__ import annotations

import json
import os
import re
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


_UNKNOWN_TOOL_HINT = (
    "Your last response tried to call a tool that does not exist. "
    "Use only the tools defined in this conversation: navigate, click, fill, "
    "select_option, read, wait_for, finish. Do not emit a tool called "
    "'commentary' or anything else. If the goal is already complete (or you "
    "hit a legitimate business outcome like NOT_FOUND), call `finish` with "
    "the appropriate arguments."
)


def _trim_history(messages: List[Dict[str, Any]], keep_tail: int = 8) -> List[Dict[str, Any]]:
    """Keep the conversation small enough for tight token budgets.

    Preserve the system message and the first user message (the goal), then
    keep only the most recent `keep_tail` messages. The tail must not start
    with a `tool` role (which would orphan a tool call); we advance the cut
    forward until it starts with a safe role.
    """
    if len(messages) <= keep_tail + 2:
        return messages
    head = messages[:2]
    tail = messages[-keep_tail:]
    while tail and tail[0].get("role") == "tool":
        tail = tail[1:]
    if tail and tail[0].get("role") == "assistant" and tail[0].get("tool_calls"):
        tail = tail[1:]
    return head + tail

def _is_unknown_tool_error(exc: Exception) -> bool:
    """Detect the provider-side 'attempted to call tool X which was not in request.tools' error."""
    text = str(exc)
    return (
        "not in request.tools" in text
        or "tool_use_failed" in text
        or ("Tool call validation failed" in text and "unknown" in text.lower())
    )


def _locator_from_args(args: Dict[str, Any]) -> Locator:
    strategy = args["locator_strategy"]
    frame_selector = args.get("frame_selector") or None
    locator_name = args.get("locator_name") or None
    return Locator(
        strategy=LocatorStrategy(strategy),
        value=args["locator_value"],
        name=locator_name,
        frame_path=[frame_selector] if frame_selector else None,
    )


def _action_from_tool(tool_name: str) -> ActionType:
    return {
        "navigate": ActionType.NAVIGATE,
        "click": ActionType.CLICK,
        "fill": ActionType.FILL,
        "select_option": ActionType.SELECT,
        "read": ActionType.READ,
        "wait_for": ActionType.WAIT_FOR,
        "finish": ActionType.SCREENSHOT,
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
        {
            "role": "user",
            "content": f"Goal: {goal}\n\nCurrent page observation:\n{observer.observe(page)}",
        },
    ]

    steps: List[Step] = []
    outputs_spec: List[Output] = []
    read_values: Dict[str, Any] = {}
    step_counter = 0
    unknown_tool_retries = 0
    MAX_UNKNOWN_TOOL_RETRIES = 5

    for iteration in range(max_steps):
        # ---- LLM turn, with retry on "unknown tool" provider rejections
        messages = _trim_history(messages, keep_tail=8)
        try:
            response = llm.chat(messages=messages, tools=prompts.TOOLS, tool_choice="auto")
        except Exception as exc:
            if _is_unknown_tool_error(exc) and unknown_tool_retries < MAX_UNKNOWN_TOOL_RETRIES:
                unknown_tool_retries += 1
                logger.log(
                    "discovery.unknown_tool_retry",
                    attempt=unknown_tool_retries,
                    error=str(exc)[:500],
                )
                print(
                    f"[agent] Provider rejected an unknown tool call "
                    f"(attempt {unknown_tool_retries}/{MAX_UNKNOWN_TOOL_RETRIES}). "
                    f"Retrying with a correction hint."
                )
                messages.append({"role": "user", "content": _UNKNOWN_TOOL_HINT})
                continue
            raise

        choice = response.choices[0].message
        assistant_msg: Dict[str, Any] = {
            "role": "assistant",
            "content": choice.content or "",
        }
        if choice.tool_calls:
            tool_calls_payload = []
            for tc in choice.tool_calls:
                entry: Dict[str, Any] = {
                    "id": tc.id,
                    "type": "function",
                    "function": {
                        "name": tc.function.name,
                        "arguments": tc.function.arguments,
                    },
                }
                # Preserve provider-specific extras (e.g. Gemini thought_signature)
                extra = getattr(tc, "extra_content", None)
                if extra:
                    entry["extra_content"] = extra
                tool_calls_payload.append(entry)
            assistant_msg["tool_calls"] = tool_calls_payload
        messages.append(assistant_msg)

        if not choice.tool_calls:
            logger.log("discovery.no_tool_call", content=choice.content)
            messages.append({"role": "user", "content": "Please call a tool."})
            continue

        # Reset the retry counter once we get a clean turn.
        unknown_tool_retries = 0

        for tc in choice.tool_calls:
            name = tc.function.name
            try:
                args = json.loads(tc.function.arguments or "{}")
            except json.JSONDecodeError:
                args = {}

            logger.log("discovery.tool_call", tool=name, args=args)

            # Sanity: reject any tool name we don't know (defense in depth).
            if name not in {t["function"]["name"] for t in prompts.TOOLS}:
                logger.log("discovery.unknown_tool", tool=name)
                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": tc.id,
                        "content": json.dumps({"error": f"Unknown tool: {name}"}),
                    }
                )
                messages.append({"role": "user", "content": _UNKNOWN_TOOL_HINT})
                continue

            if name == "finish":
                checkpoint_desc = args.get("checkpoint_description", "Goal complete")
                business_outcome = args.get("business_outcome")
                final_outputs = args.get("outputs") or {}
                for k, v in read_values.items():
                    final_outputs.setdefault(k, v)

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

            action_type = _action_from_tool(name)
            risk = RiskLevel.SAFE
            if name == "click" and "submit" in json.dumps(args).lower():
                risk = RiskLevel.RISKY
            try:
                allowlist.enforce_action(action_type, risk)
            except SafetyViolation as exc:
                logger.log("safety.violation", tool=name, reason=str(exc))
                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": tc.id,
                        "content": json.dumps({"error": str(exc)}),
                    }
                )
                continue

            try:
                result, read_out = actor.execute(page, name, args)
            except Exception as exc:
                logger.log("discovery.action_error", tool=name, error=str(exc))
                result, read_out = {"ok": False, "error": str(exc)}, None

            step_counter += 1
            steps.append(_record_step(step_counter, name, args, risk))
            if read_out:
                read_values[read_out["output_name"]] = read_out["value"]
                outputs_spec.append(
                    Output(
                        name=read_out["output_name"],
                        type="string",
                        description=f"Read from step {step_counter}",
                        from_step=f"s{step_counter}",
                    )
                )

            shot = logger.screenshot_path(f"step_{step_counter:02d}_{name}")
            try:
                page.screenshot(path=str(shot), full_page=False)
            except Exception:
                pass

            messages.append(
                {
                    "role": "tool",
                    "tool_call_id": tc.id,
                    "content": json.dumps(result, ensure_ascii=False)[:2000],
                }
            )

            try:
                obs = observer.observe(page)
            except Exception as exc:
                obs = f"[observe error: {exc}]"
            messages.append({"role": "user", "content": f"Current page observation:\n{obs}"})

    logger.log("discovery.max_steps")
    return DiscoveryResult(
        artifact=None,
        business_outcome=None,
        steps_taken=len(steps),
        finish_reason="max_steps",
    )


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
    try:
        _ = page.title() or "page"
    except Exception:
        pass
    return Checkpoint(
        description=description,
        locator=Locator(strategy=LocatorStrategy.CSS, value="body"),
        expected_text=None,
    )


def _infer_parameters(goal: str) -> List[Parameter]:
    import re

    params: List[Parameter] = []
    m = re.search(r"\b(\d{4,})\b", goal)
    if m:
        params.append(
            Parameter(
                name="member_id",
                type="string",
                required=True,
                description="Member ID referenced in the goal",
                example=m.group(1),
            )
        )
    return params