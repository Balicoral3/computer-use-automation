"""Checkpoint verification."""

from __future__ import annotations

from playwright.sync_api import Page

from ..artifact.schema import Checkpoint
from .locator import resolve


def verify(page: Page, checkpoint: Checkpoint) -> tuple[bool, str]:
    """Return (passed, observed_text_or_reason)."""
    try:
        loc = resolve(page, checkpoint.locator, timeout_ms=checkpoint.timeout_ms)
        text = loc.first.inner_text(timeout=checkpoint.timeout_ms)
    except Exception as exc:
        return False, f"Checkpoint locator failed: {exc}"

    if checkpoint.expected_text:
        if checkpoint.expected_text.lower() not in text.lower():
            return False, f"Expected {checkpoint.expected_text!r} not in {text!r}"
    return True, text