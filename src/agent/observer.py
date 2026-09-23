"""Observe the current surface and produce a compact representation for the LLM.

Token budget matters: free-tier providers cap input tokens per minute.
We keep the observation tight:
  - only the 25 most relevant interactive elements (visible, not disabled)
  - visible text snippet capped at 250 chars
  - iframes included only when they actually contain interactive elements
"""

from __future__ import annotations

from typing import Any, Dict, List

from playwright.sync_api import Frame, Page


_MAX_ELEMENTS = 25
_TEXT_SNIPPET_CHARS = 250


_JS_OBSERVE = r"""
(max) => {
  function isVisible(el) {
    if (!el) return false;
    const style = window.getComputedStyle(el);
    if (style.display === 'none' || style.visibility === 'hidden') return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  }
  function labelText(el) {
    if (el.labels && el.labels.length) {
      return Array.from(el.labels).map(l => l.innerText.trim()).join(' ').trim();
    }
    return '';
  }
  const tags = ['a', 'button', 'input', 'select', 'textarea'];
  const nodes = document.querySelectorAll(tags.join(','));
  const out = [];
  for (const el of nodes) {
    if (!isVisible(el)) continue;
    if (el.disabled) continue;
    const tag = el.tagName.toLowerCase();
    const type = el.getAttribute('type') || '';
    if (type === 'hidden') continue;
    const item = {
      tag,
      type,
      id: el.id || '',
      name: el.getAttribute('name') || '',
      role: el.getAttribute('role') || '',
      text: (el.innerText || el.value || '').trim().slice(0, 80),
      label: labelText(el).slice(0, 80),
      placeholder: el.getAttribute('placeholder') || '',
      href: el.getAttribute('href') || '',
      value: (el.value || '').slice(0, 40),
    };
    out.push(item);
    if (out.length >= max) break;
  }
  return out;
}
"""


def _describe_element(el: Dict[str, Any]) -> str:
    parts: List[str] = [f"<{el['tag']}"]
    if el.get("type"):
        parts.append(f" type={el['type']}")
    if el.get("id"):
        parts.append(f" id={el['id']!r}")
    if el.get("name"):
        parts.append(f" name={el['name']!r}")
    parts.append(">")
    line = "".join(parts)
    labels: List[str] = []
    if el.get("label"):
        labels.append(f"label={el['label']!r}")
    if el.get("placeholder"):
        labels.append(f"placeholder={el['placeholder']!r}")
    if el.get("text"):
        labels.append(f"text={el['text']!r}")
    if el.get("value"):
        labels.append(f"value={el['value']!r}")
    if el.get("href"):
        labels.append(f"href={el['href']!r}")
    if labels:
        line += " " + " ".join(labels)
    return line


def _observe_frame(frame: Frame, prefix: str = "", include_title: bool = True) -> List[str]:
    lines: List[str] = []
    try:
        url = frame.url
    except Exception:
        return lines
    if include_title:
        try:
            title = frame.title()
        except Exception:
            title = ""
        lines.append(f"{prefix}URL: {url}")
        lines.append(f"{prefix}Title: {title}")
    try:
        text = frame.evaluate("() => document.body ? document.body.innerText : ''")
    except Exception:
        text = ""
    if text:
        snippet = " ".join(text.split())[:_TEXT_SNIPPET_CHARS]
        lines.append(f"{prefix}Text: {snippet}")
    try:
        elements = frame.evaluate(_JS_OBSERVE, _MAX_ELEMENTS)
    except Exception as exc:
        lines.append(f"{prefix}[observe error: {exc}]")
        elements = []
    if elements:
        lines.append(f"{prefix}Elements:")
        for el in elements:
            lines.append(f"{prefix}  - {_describe_element(el)}")
    return lines


def observe(page: Page) -> str:
    """Return a compact observation. Top frame only unless iframes have elements."""
    lines: List[str] = []
    lines.extend(_observe_frame(page.main_frame, include_title=True))

    frames = page.frames
    for i, fr in enumerate(frames):
        if fr == page.main_frame:
            continue
        child = fr.child_frames
        if child:
            continue
        sub_lines = _observe_frame(fr, prefix="  ", include_title=False)
        # Only include an iframe block if it actually has interactive elements.
        has_elements = any("Elements:" in ln for ln in sub_lines)
        if not has_elements:
            continue
        lines.append(f"[iframe {i}]")
        lines.extend(sub_lines)
    return "\n".join(lines)