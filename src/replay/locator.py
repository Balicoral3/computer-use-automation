"""Layered locator resolution.

Strategy: try the primary locator; if it fails, walk through fallbacks.
Also supports iframe paths: when a locator declares a frame_path, we
scope the search to the frame_locator for the innermost frame.
"""

from __future__ import annotations

from typing import Any, Optional

from playwright.sync_api import Error as PlaywrightError
from playwright.sync_api import Locator, Page

from ..artifact.schema import Locator as LocatorSpec
from ..artifact.schema import LocatorStrategy


def _build(scope: Any, spec: LocatorSpec) -> Locator:
    s = spec.strategy
    v = spec.value
    if s == LocatorStrategy.ROLE:
        kwargs = {"name": spec.name} if spec.name else {}
        return scope.get_by_role(v, **kwargs)  # type: ignore[arg-type]
    if s == LocatorStrategy.LABEL:
        return scope.get_by_label(v, exact=spec.exact)
    if s == LocatorStrategy.TEXT:
        return scope.get_by_text(v, exact=spec.exact)
    if s == LocatorStrategy.PLACEHOLDER:
        return scope.get_by_placeholder(v, exact=spec.exact)
    if s == LocatorStrategy.NAME:
        return scope.locator(f'[name="{v}"]')
    if s == LocatorStrategy.CSS:
        return scope.locator(v)
    if s == LocatorStrategy.XPATH:
        return scope.locator(f"xpath={v}")
    if s == LocatorStrategy.COORDINATES:
        raise NotImplementedError("Coordinates locator not supported in v1")
    raise ValueError(f"Unknown strategy: {s}")


def _scope_for(page: Page, spec: LocatorSpec) -> Any:
    scope: Any = page
    if spec.frame_path:
        for selector in spec.frame_path:
            scope = scope.frame_locator(selector)
    return scope


def resolve(page: Page, spec: LocatorSpec, timeout_ms: int = 8000) -> Locator:
    """Resolve the primary locator, falling back through the chain if needed."""
    candidates = [spec] + list(spec.fallbacks)
    last_error: Optional[Exception] = None
    for cand in candidates:
        try:
            scope = _scope_for(page, cand)
            loc = _build(scope, cand)
            loc.first.wait_for(state="attached", timeout=timeout_ms)
            return loc
        except (PlaywrightError, NotImplementedError, ValueError) as exc:
            last_error = exc
            continue
    raise RuntimeError(
        f"All locator candidates failed for {spec.describe()}: {last_error}"
    )