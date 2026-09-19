# fix_redaction.ps1
# Strengthen redaction: field-name based secrets masking.
$ErrorActionPreference = "Stop"
$root = (Get-Location).Path
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Write-ProjectFile {
    param([string]$RelPath, [string]$Content)
    $full = Join-Path $root $RelPath
    $dir = Split-Path $full -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    [System.IO.File]::WriteAllText($full, $Content, $utf8)
    Write-Host "  wrote $RelPath"
}

Write-Host "Rewriting src/safety/redaction.py ..." -ForegroundColor Cyan

Write-ProjectFile "src\safety\redaction.py" @'
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
'@

Write-Host "Patching tests/test_safety.py ..." -ForegroundColor Cyan

# Append field-name tests (full overwrite for clarity)
Write-ProjectFile "tests\test_safety.py" @'
"""Unit tests for safety: allowlist and redaction."""

from __future__ import annotations

import pytest

from src.artifact.schema import ActionType, RiskLevel, SafetyPolicy
from src.safety.allowlist import Allowlist, SafetyViolation
from src.safety.redaction import redact_mapping, redact_text, redact_value


def _policy() -> SafetyPolicy:
    return SafetyPolicy(
        allowed_domains=["127.0.0.1", "localhost"],
        allowed_actions=[ActionType.NAVIGATE, ActionType.CLICK, ActionType.FILL],
        risky_requires_confirmation=True,
        irreversible_blocked=True,
    )


def test_url_allowlist_accepts_known_host():
    a = Allowlist(_policy())
    assert a.check_url("http://127.0.0.1:5000/login").allowed
    assert a.check_url("http://localhost:5000/").allowed


def test_url_allowlist_rejects_unknown_host():
    a = Allowlist(_policy())
    assert not a.check_url("http://evil.example.com/").allowed


def test_url_allowlist_enforce_raises():
    a = Allowlist(_policy())
    with pytest.raises(SafetyViolation):
        a.enforce_url("http://evil.example.com/")


def test_action_allowlist_rejects_unlisted_action():
    a = Allowlist(_policy())
    assert not a.check_action(ActionType.SELECT, RiskLevel.SAFE).allowed


def test_risky_action_requires_confirmation():
    a = Allowlist(_policy())
    d = a.check_action(ActionType.CLICK, RiskLevel.RISKY)
    assert d.allowed and d.requires_confirmation


def test_irreversible_action_blocked():
    a = Allowlist(_policy())
    d = a.check_action(ActionType.CLICK, RiskLevel.IRREVERSIBLE)
    assert not d.allowed and d.requires_confirmation


# -- pattern-based ----------------------------------------------------------

def test_redact_ssn():
    assert "[REDACTED_SSN]" in redact_text("SSN 123-45-6789")


def test_redact_api_key():
    assert "[REDACTED_API_KEY]" in redact_text("key sk-abcdefghijklmnopqrstuv")


def test_redact_currency_amount():
    assert "[REDACTED_AMOUNT]" in redact_text("balance is $12,345.67")


def test_redact_value_nested():
    payload = {"account": "123456789", "note": "hello", "nested": {"ssn": "123-45-6789"}}
    out = redact_value(payload)
    assert "[REDACTED_NUMBER]" in out["account"]
    assert out["note"] == "hello"
    assert "[REDACTED_SSN]" in out["nested"]["ssn"]


# -- field-name based -------------------------------------------------------

def test_password_field_masked_regardless_of_value():
    out = redact_value({"password": "password123"})
    assert out["password"] == "[REDACTED_SECRET]"


def test_various_sensitive_keys_masked():
    payload = {
        "username": "teller1",
        "password": "whatever",
        "api_key": "anything",
        "access_token": "anything",
        "authorization": "Bearer xyz",
        "session_id": "abc123",
    }
    out = redact_value(payload)
    assert out["username"] == "teller1"
    assert out["password"] == "[REDACTED_SECRET]"
    assert out["api_key"] == "[REDACTED_SECRET]"
    assert out["access_token"] == "[REDACTED_SECRET]"
    assert out["authorization"] == "[REDACTED_SECRET]"
    assert out["session_id"] == "[REDACTED_SECRET]"


def test_redact_mapping_skip_keys_can_opt_out():
    d = {"password": "x", "note": "y"}
    out = redact_mapping(d, skip_keys=["password"])
    assert out["password"] == "x"
    assert out["note"] == "y"
'@

Write-Host ""
Write-Host "Done. Verifying..." -ForegroundColor Yellow
python -c "from src.safety.redaction import redact_value; print(redact_value({'password': 'password123'}))"
python -c "from src.safety.redaction import redact_mapping; print(redact_mapping({'user':'teller1','password':'password123'}))"