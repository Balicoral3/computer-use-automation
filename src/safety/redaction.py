"""PII / secret redaction for logs, evidence, and artifacts.

Two layers:

1. Pattern-based: match common secret/PII shapes (API keys, SSNs, emails,
   9-16 digit numbers, currency amounts) anywhere in a string.

2. Field-name-based: if the *key* of a mapping entry looks sensitive
   (password, secret, token, api_key, authorization, etc.), mask the entire
   value regardless of shape. This is the layer that catches credentials
   like "password123", which no shape-based pattern would match.

Field-name masking is deliberately aggressive because a credential that
leaks into a log is unrecoverable; a false positive is merely annoying.
"""

from __future__ import annotations

import re
from typing import Any, Dict, Iterable

# ---------------------------------------------------------------------------
# Pattern-based redaction (shape of the value)
# ---------------------------------------------------------------------------
_PATTERNS = [
    (re.compile(r"\bsk-[A-Za-z0-9]{16,}\b"), "[REDACTED_API_KEY]"),
    (re.compile(r"\b\d{3}-\d{2}-\d{4}\b"), "[REDACTED_SSN]"),
    (re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.-]+\b"), "[REDACTED_EMAIL]"),
    (re.compile(r"\b\d{9,16}\b"), "[REDACTED_NUMBER]"),
    (re.compile(r"\$\s?\d{1,3}(?:,\d{3})*(?:\.\d{2})?"), "[REDACTED_AMOUNT]"),
]

# ---------------------------------------------------------------------------
# Field-name based redaction (name of the key)
# ---------------------------------------------------------------------------
_SENSITIVE_KEY_SUBSTRINGS = (
    "password",
    "passwd",
    "pwd",
    "secret",
    "token",
    "api_key",
    "apikey",
    "authorization",
    "auth",
    "credential",
    "session_id",
    "cookie",
    "private_key",
    "access_key",
    "client_secret",
)


def _is_sensitive_key(key: Any) -> bool:
    if not isinstance(key, str):
        return False
    k = key.lower()
    return any(sub in k for sub in _SENSITIVE_KEY_SUBSTRINGS)


def redact_text(text: str) -> str:
    if text is None:
        return text
    out = text
    for pat, repl in _PATTERNS:
        out = pat.sub(repl, out)
    return out


def redact_value(value: Any) -> Any:
    if isinstance(value, str):
        return redact_text(value)
    if isinstance(value, dict):
        return {
            k: ("[REDACTED_SECRET]" if _is_sensitive_key(k) else redact_value(v))
            for k, v in value.items()
        }
    if isinstance(value, (list, tuple)):
        return [redact_value(v) for v in value]
    return value


def redact_mapping(d: Dict[str, Any], skip_keys: Iterable[str] = ()) -> Dict[str, Any]:
    """Redact a mapping. skip_keys opt out of field-name masking (rare)."""
    skip = set(skip_keys)
    out: Dict[str, Any] = {}
    for k, v in d.items():
        if k in skip:
            out[k] = v
        elif _is_sensitive_key(k):
            out[k] = "[REDACTED_SECRET]"
        else:
            out[k] = redact_value(v)
    return out