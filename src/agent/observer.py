"""Observe the current surface and produce a compact representation for the LLM.

The observation is intentionally text-based so it works with any model
(including text-only ones). It includes:
  - current URL and title
  - the visible text summary of the main content area
  - a list of interactive elements (buttons, inputs, links, selects) with
    stable attributes for locator construction
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

from playwright.sync_api import Frame, Page


_MAX_ELEMENTS = 80


_JS_OBSERVE = r"""
() => {
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

  const tags = ['a', 'button', 'input', 'select', 'textarea', '[role=button]', '[role=link]'];
  const nodes = document.querySelectorAll(tags.join(','));
  const out = [];
  for (const el of nodes) {
    if (!isVisible(el)) continue;
    const tag = el.tagName.toLowerCase();
    const type = el.getAttribute('type') || '';
    if (type === 'hidden') continue;
    const item = {
      tag,
      type,
      id: el.id || '',
      name: el.getAttribute('name') || '',
      role: el.getAttribute('role') || '',
      text: (el.innerText || el.value || '').trim().slice(0, 120),
      label: labelText(el).slice(0, 120),
      placeholder: el.getAttribute('placeholder') || '',
      href: el.getAttribute('href') || '',
      value: (el.value || '').slice(0, 80),
    };
    out.push(item);
    if (out.length >= %d) break;
  }
  return out;
}
""" % _MAX_ELEMENTS


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


def _observe_frame(frame: Frame, prefix: str = "") -> List[str]:
    lines: List[str] = []
    try:
        url = frame.url
        title = frame.title()
    except Exception:
        return lines
    lines.append(f"{prefix}URL: {url}")
    lines.append(f"{prefix}Title: {title}")
    try:
        text = frame.evaluate("() => document.body ? document.body.innerText : ''")
    except Exception:
        text = ""
    if text:
        snippet = " ".join(text.split())[:600]
        lines.append(f"{prefix}Visible text: {snippet}")
    try:
        elements = frame.evaluate(_JS_OBSERVE)
    except Exception as exc:
        lines.append(f"{prefix}[observe error: {exc}]")
        elements = []
    if elements:
        lines.append(f"{prefix}Interactive elements:")
        for el in elements:
            lines.append(f"{prefix}  - {_describe_element(el)}")
    return lines


def observe(page: Page) -> str:
    """Return a compact, human-readable observation of the current page."""
    lines: List[str] = []
    lines.extend(_observe_frame(page.main_frame))
    frames = page.frames
    for i, fr in enumerate(frames):
        if fr == page.main_frame:
            continue
        child = fr.child_frames
        if child:
            continue
        lines.append(f"[iframe {i}]")
        lines.extend(_observe_frame(fr, prefix="  "))
    return "\n".join(lines)