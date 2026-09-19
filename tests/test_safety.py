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