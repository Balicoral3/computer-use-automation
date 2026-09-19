"""Minimal human-in-the-loop handoff.

Model:
  - Automation runs in a headed browser. When the agent or replay hits a
    stuck/blocked state, we pause.
  - The operator (human) can take control of the SAME live session (same
    browser, same page, same cookies). We print instructions and wait for
    the operator to type `resume` on stdin.
  - While paused, the operator interacts with the browser window directly.
  - On resume, we capture what the operator did by taking a screenshot and
    snapshotting the DOM, then continue from the current state.
  - A control-token model is used so it's always clear who has control:
    the handoff log records "control=operator" / "control=automation".
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

from playwright.sync_api import Page

from ..evidence.logger import RunLogger


@dataclass
class HandoffRequest:
    reason: str
    step_id: Optional[str] = None
    context: Optional[str] = None


@dataclass
class HandoffResult:
    resumed: bool
    operator_notes: str = ""
    screenshot_path: Optional[str] = None
    dom_path: Optional[str] = None


class CLIHandoff:
    """Interactive CLI handoff. Works only when a TTY is available."""

    def __init__(self, page: Page, logger: RunLogger) -> None:
        self.page = page
        self.logger = logger

    def request(self, req: HandoffRequest, input_fn=input) -> HandoffResult:
        self.logger.log(
            "handoff.request",
            reason=req.reason,
            step_id=req.step_id,
            context=req.context,
            control="operator",
        )
        print()
        print("=" * 70)
        print("HUMAN INTERVENTION REQUESTED")
        print("-" * 70)
        print(f"Reason: {req.reason}")
        if req.step_id:
            print(f"At step: {req.step_id}")
        if req.context:
            print(f"Context: {req.context}")
        print("-" * 70)
        print("The browser window is now yours. Perform the manual steps,")
        print("then return here and type 'resume' (or 'abort' to give up).")
        print("=" * 70)

        # Pre-handoff evidence
        pre_shot = self.logger.screenshot_path("handoff_pre")
        try:
            self.page.screenshot(path=str(pre_shot))
        except Exception:
            pass

        while True:
            try:
                cmd = input_fn("handoff> ").strip().lower()
            except EOFError:
                cmd = "abort"
            if cmd in ("resume", "r"):
                break
            if cmd in ("abort", "a"):
                self.logger.log("handoff.abort")
                return HandoffResult(resumed=False)
            print("Commands: resume | abort")

        notes = ""
        try:
            notes = input_fn("Operator notes (optional): ").strip()
        except EOFError:
            notes = ""

        post_shot = self.logger.screenshot_path("handoff_post")
        dom = self.logger.dom_path("handoff_post")
        try:
            self.page.screenshot(path=str(post_shot))
            dom.write_text(self.page.content(), encoding="utf-8")
        except Exception:
            pass

        self.logger.log(
            "handoff.resume",
            notes=notes,
            control="automation",
            screenshot=str(post_shot),
            dom=str(dom),
        )
        print("Control returned to automation. Resuming...")
        return HandoffResult(
            resumed=True,
            operator_notes=notes,
            screenshot_path=str(post_shot),
            dom_path=str(dom),
        )