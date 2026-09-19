"""Execute tool calls against the live Playwright surface."""

from __future__ import annotations

import base64
from typing import Any, Dict, Optional, Tuple

from playwright.sync_api import Frame, Page
from playwright.sync_api import Error as PlaywrightError


class ActionError(Exception):
    def __init__(self, code: str, message: str, kind: str = "hard") -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.kind = kind


def _resolve_target(page: Page, frame_selector: Optional[str]) -> Page | Frame:
    if not frame_selector:
        return page
    frame = page.frame_locator(frame_selector)
    # frame_locator is not a Page/Frame; wrap usage in locator helpers below
    return frame  # type: ignore[return-value]


def _locator(page: Page, args: Dict[str, Any]):
    strategy = args.get("locator_strategy")
    value = args.get("locator_value", "")
    name = args.get("locator_name")
    frame_selector = args.get("frame_selector")
    scope: Any = page
    if frame_selector:
        scope = page.frame_locator(frame_selector)

    if strategy == "role":
        # Playwright expects a role string; we approximate with get_by_role
        return scope.get_by_role(value, name=name)  # type: ignore[arg-type]
    if strategy == "label":
        return scope.get_by_label(value)
    if strategy == "text":
        return scope.get_by_text(value)
    if strategy == "placeholder":
        return scope.get_by_placeholder(value)
    if strategy == "css":
        return scope.locator(value)
    if strategy == "xpath":
        return scope.locator(f"xpath={value}")
    if strategy == "coordinates":
        raise ActionError("COORDINATES_UNSUPPORTED", "coordinates locator not implemented in v1")
    raise ActionError("UNKNOWN_STRATEGY", f"Unknown locator strategy: {strategy}")


def _step_to_locator_args(step: Dict[str, Any]) -> Dict[str, Any]:
    return step


def execute(page: Page, action: str, args: Dict[str, Any]) -> Tuple[Dict[str, Any], Optional[Dict[str, Any]]]:
    """Run one tool call. Returns (result_dict, read_output_or_none)."""
    if action == "navigate":
        url = args["url"]
        page.goto(url, wait_until="domcontentloaded")
        return {"ok": True, "url": page.url}, None

    if action == "click":
        loc = _locator(page, args)
        loc.first.click(timeout=8000)
        page.wait_for_load_state("networkidle", timeout=8000)
        return {"ok": True}, None

    if action == "fill":
        loc = _locator(page, args)
        loc.first.fill(args["text"], timeout=8000)
        return {"ok": True}, None

    if action == "select_option":
        loc = _locator(page, args)
        loc.first.select_option(label=args["option_label"], timeout=8000)
        return {"ok": True}, None

    if action == "read":
        loc = _locator(page, args)
        text = loc.first.inner_text(timeout=8000)
        return {"ok": True, "text": text}, {"output_name": args["output_name"], "value": text}

    if action == "wait_for":
        timeout = int(args.get("timeout_ms", 8000))
        loc = _locator(page, args)
        loc.first.wait_for(state="visible", timeout=timeout)
        return {"ok": True}, None

    raise ActionError("UNKNOWN_ACTION", f"Unknown action: {action}")