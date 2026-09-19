# setup_batch4.ps1 (v2 - tanpa README/REPORT)
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

Write-Host "Rewriting src/replay/errors.py ..." -ForegroundColor Cyan
Write-ProjectFile "src\replay\errors.py" @'
"""Error taxonomy for replay.

Three kinds of runtime conditions, per the brief:
  - BUSINESS: a legitimate outcome the caller must see (NOT_FOUND, etc.)
  - RECOVERABLE: transient; replay can dismiss/retry and continue
  - HARD: stop and surface a debuggable error

Note: BUSINESS/RECOVERABLE/HARD are categories of detection (ErrorKind).
The result of a replay is one of SUCCESS/BUSINESS/FAILURE (OutcomeKind).
Don't conflate the two.

We do NOT include a "session expired" default signature: the mock login
page contains "CoreBank Sign In", which would false-positive on every
navigation to /login. Session-expiry handling is declared per-step.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Dict, Optional, Tuple

from ..artifact.schema import ErrorKind


class OutcomeKind(str, Enum):
    SUCCESS = "success"
    BUSINESS = "business"
    FAILURE = "failure"


@dataclass
class ReplayOutcome:
    kind: OutcomeKind
    code: str
    message: str
    outputs: Dict[str, Any] = field(default_factory=dict)
    step_id: Optional[str] = None
    expected: Optional[str] = None
    observed: Optional[str] = None
    evidence_path: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            "kind": self.kind.value,
            "code": self.code,
            "message": self.message,
            "outputs": self.outputs,
            "step_id": self.step_id,
            "expected": self.expected,
            "observed": self.observed,
            "evidence_path": self.evidence_path,
        }


class StepFailure(Exception):
    def __init__(self, code: str, message: str, observed: str = "",
                 expected: str = "", step_id: str = "") -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.observed = observed
        self.expected = expected
        self.step_id = step_id


ERROR_SIGNATURES = [
    ("NOT_FOUND",         "No member found",              ErrorKind.BUSINESS),
    ("PERMISSION_DENIED", "You do not have permission",   ErrorKind.BUSINESS),
    ("PERMISSION_DENIED", "Account is restricted",        ErrorKind.BUSINESS),
    ("VALIDATION_ERROR",  "is required",                  ErrorKind.BUSINESS),
    ("VALIDATION_ERROR",  "must be a number",             ErrorKind.BUSINESS),
    ("VALIDATION_ERROR",  "must be at least",             ErrorKind.BUSINESS),
]


def detect_known_outcome(page_text: str) -> Optional[Tuple[str, ErrorKind]]:
    if not page_text:
        return None
    for code, needle, kind in ERROR_SIGNATURES:
        if needle.lower() in page_text.lower():
            return (code, kind)
    return None
'@

Write-Host "Patching src/replay/engine.py ..." -ForegroundColor Cyan
$enginePath = Join-Path $root "src\replay\engine.py"
$engine = [System.IO.File]::ReadAllText($enginePath, $utf8)
$old = '            self.page.goto(artifact.target.entry_url, wait_until="domcontentloaded")'
$new = '            entry = artifact.render_value(artifact.target.entry_url, params) or artifact.target.entry_url
            self.page.goto(entry, wait_until="domcontentloaded")'
if ($engine.Contains($old)) {
    $engine = $engine.Replace($old, $new)
    [System.IO.File]::WriteAllText($enginePath, $engine, $utf8)
    Write-Host "  patched entry_url templating" -ForegroundColor Green
} else {
    Write-Host "  (already patched or pattern not found)" -ForegroundColor Yellow
}

Write-Host "Rewriting pyproject.toml ..." -ForegroundColor Cyan
Write-ProjectFile "pyproject.toml" @'
[project]
name = "computer-use-automation"
version = "0.1.0"
description = "LLM-driven computer-use automation with deterministic replay"
requires-python = ">=3.11"

[tool.pytest.ini_options]
testpaths = ["tests"]
pythonpath = ["."]

[tool.ruff]
line-length = 100
target-version = "py311"
'@

Write-Host "Writing tests/conftest.py ..." -ForegroundColor Cyan
Write-ProjectFile "tests\conftest.py" @'
"""Pytest fixtures.

We spin the mock bank app in a background thread on a dynamic port and
launch a single Playwright Chromium instance for the whole session.
"""

from __future__ import annotations

import socket
import threading
import time

import pytest
from playwright.sync_api import sync_playwright
from werkzeug.serving import make_server


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture(scope="session")
def target_app_url():
    from src.target_app.app import app as flask_app

    flask_app.config["TESTING"] = True
    port = _free_port()
    server = make_server("127.0.0.1", port, flask_app, threaded=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    time.sleep(0.3)
    url = f"http://127.0.0.1:{port}"
    yield url
    server.shutdown()
    thread.join(timeout=2)


@pytest.fixture(scope="session")
def browser():
    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=True)
        yield browser
        browser.close()


@pytest.fixture
def page(browser):
    ctx = browser.new_context(viewport={"width": 1280, "height": 800})
    p = ctx.new_page()
    p.set_default_timeout(8_000)
    yield p
    ctx.close()
'@

Write-Host "Writing tests/test_schema.py ..." -ForegroundColor Cyan
Write-ProjectFile "tests\test_schema.py" @'
"""Unit tests for the artifact schema."""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from src.artifact.schema import (
    ActionType,
    CapabilityArtifact,
    Checkpoint,
    Locator,
    LocatorStrategy,
    Parameter,
    SafetyPolicy,
    Step,
    TargetInfo,
)


def _minimal_artifact() -> CapabilityArtifact:
    return CapabilityArtifact(
        id="t",
        name="Test",
        description="Test artifact",
        llm_model="deepseek-chat",
        target=TargetInfo(app_id="mock", entry_url="http://127.0.0.1:5000/login"),
        parameters=[Parameter(name="member_id", type="string", description="ID")],
        steps=[
            Step(id="s1", action=ActionType.NAVIGATE,
                 description="Go to login", value="http://127.0.0.1:5000/login"),
        ],
        checkpoint=Checkpoint(
            description="On login page",
            locator=Locator(strategy=LocatorStrategy.CSS, value="body"),
        ),
        safety=SafetyPolicy(
            allowed_domains=["127.0.0.1", "localhost"],
            allowed_actions=list(ActionType),
        ),
    )


def test_minimal_artifact_roundtrip():
    a = _minimal_artifact()
    payload = a.model_dump(mode="json")
    b = CapabilityArtifact.model_validate(payload)
    assert b.id == "t"
    assert b.steps[0].action == ActionType.NAVIGATE


def test_render_value_substitutes_templates():
    a = _minimal_artifact()
    out = a.render_value("http://x/member/{{member_id}}", {"member_id": "12345"})
    assert out == "http://x/member/12345"


def test_render_value_handles_none():
    a = _minimal_artifact()
    assert a.render_value(None, {}) is None


def test_step_rejects_api_key_like_value():
    with pytest.raises(ValidationError):
        Step(id="s1", action=ActionType.FILL, description="x",
             value="sk-abcdefghijklmnopqrstuv")


def test_locator_describe():
    loc = Locator(strategy=LocatorStrategy.ROLE, value="button", name="Sign In")
    assert "button" in loc.describe()
    assert "Sign In" in loc.describe()


def test_parameter_names_helper():
    a = _minimal_artifact()
    assert a.parameter_names() == ["member_id"]
'@

Write-Host "Writing tests/test_safety.py ..." -ForegroundColor Cyan
Write-ProjectFile "tests\test_safety.py" @'
"""Unit tests for safety: allowlist and redaction."""

from __future__ import annotations

import pytest

from src.artifact.schema import ActionType, RiskLevel, SafetyPolicy
from src.safety.allowlist import Allowlist, SafetyViolation
from src.safety.redaction import redact_text, redact_value


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
'@

Write-Host "Writing tests/fixtures/lookup_member_balance.json ..." -ForegroundColor Cyan
Write-ProjectFile "tests\fixtures\lookup_member_balance.json" @'
{
  "schema_version": "1.0",
  "id": "lookup_member_balance",
  "name": "Lookup Member Balance",
  "version": "1.0.0",
  "description": "Sign in to the teller console, open a member record, and read the savings balance.",
  "llm_model": "fixture-no-llm",
  "target": {
    "app_id": "mock-corebank",
    "entry_url": "{{base_url}}/login",
    "surface_type": "legacy_web",
    "tenant_id": "default",
    "app_version": "1.0",
    "adapter": "playwright-web"
  },
  "parameters": [
    { "name": "base_url", "type": "string", "required": true, "description": "Base URL of the teller console", "example": "http://127.0.0.1:5000" },
    { "name": "username", "type": "string", "required": true, "description": "Operator username", "example": "teller1" },
    { "name": "password", "type": "string", "required": true, "description": "Operator password", "redact": true },
    { "name": "member_id", "type": "string", "required": true, "description": "Member ID to look up", "example": "12345" }
  ],
  "outputs": [
    { "name": "savings_balance", "type": "string", "description": "Savings balance shown on the member detail screen", "from_step": "s5", "redact": true }
  ],
  "steps": [
    { "id": "s1", "action": "fill", "description": "Enter username", "locator": { "strategy": "css", "value": "input[name=\"username\"]" }, "value": "{{username}}", "risk": "safe" },
    { "id": "s2", "action": "fill", "description": "Enter password", "locator": { "strategy": "css", "value": "input[name=\"password\"]" }, "value": "{{password}}", "risk": "safe" },
    { "id": "s3", "action": "click", "description": "Submit sign-in form", "locator": { "strategy": "role", "value": "button", "name": "Sign In", "fallbacks": [ { "strategy": "css", "value": "input[value=\"Sign In\"]" }, { "strategy": "text", "value": "Sign In" } ] }, "risk": "safe" },
    { "id": "s4", "action": "navigate", "description": "Open member detail page", "value": "{{base_url}}/member/{{member_id}}", "risk": "safe" },
    { "id": "s5", "action": "read", "description": "Read savings balance", "locator": { "strategy": "css", "value": "#savingsBalance" }, "risk": "safe" }
  ],
  "checkpoint": { "description": "Member detail page shows a savings balance", "locator": { "strategy": "css", "value": "#savingsBalance" }, "timeout_ms": 8000 },
  "safety": { "allowed_domains": ["127.0.0.1", "localhost"], "allowed_actions": ["navigate", "click", "fill", "select", "press", "read", "wait_for", "assert_text", "screenshot"], "risky_requires_confirmation": true, "irreversible_blocked": true },
  "metadata": { "fixture": true }
}
'@

Write-Host "Writing tests/test_replay.py ..." -ForegroundColor Cyan
Write-ProjectFile "tests\test_replay.py" @'
"""End-to-end replay tests using the offline fixture artifact."""

from __future__ import annotations

import json
from pathlib import Path

from src.artifact.schema import CapabilityArtifact
from src.evidence.logger import RunLogger
from src.replay.engine import ReplayEngine
from src.replay.errors import OutcomeKind
from src.safety.allowlist import Allowlist

FIXTURE_PATH = Path(__file__).parent / "fixtures" / "lookup_member_balance.json"


def _load_artifact() -> CapabilityArtifact:
    return CapabilityArtifact.model_validate(json.loads(FIXTURE_PATH.read_text(encoding="utf-8")))


def _run_replay(page, target_app_url, member_id, tmp_path):
    artifact = _load_artifact()
    allowlist = Allowlist(policy=artifact.safety)
    logger = RunLogger(root=tmp_path / "evidence", kind="replay_test")
    engine = ReplayEngine(page=page, allowlist=allowlist, logger=logger)
    return engine.run(artifact, {
        "base_url": target_app_url,
        "username": "teller1",
        "password": "password123",
        "member_id": member_id,
    })


def test_replay_success_reads_balance(page, target_app_url, tmp_path):
    outcome = _run_replay(page, target_app_url, "12345", tmp_path)
    assert outcome.kind == OutcomeKind.SUCCESS, outcome
    assert outcome.outputs.get("savings_balance") == "$12345.67"


def test_replay_not_found_is_business_outcome(page, target_app_url, tmp_path):
    outcome = _run_replay(page, target_app_url, "99999", tmp_path)
    assert outcome.kind == OutcomeKind.BUSINESS, outcome
    assert outcome.code == "NOT_FOUND"


def test_replay_permission_denied_is_business_outcome(page, target_app_url, tmp_path):
    outcome = _run_replay(page, target_app_url, "00000", tmp_path)
    assert outcome.kind == OutcomeKind.BUSINESS, outcome
    assert outcome.code == "PERMISSION_DENIED"


def test_replay_missing_param_fails_fast(page, target_app_url, tmp_path):
    artifact = _load_artifact()
    allowlist = Allowlist(policy=artifact.safety)
    logger = RunLogger(root=tmp_path / "evidence", kind="replay_test")
    engine = ReplayEngine(page=page, allowlist=allowlist, logger=logger)
    outcome = engine.run(artifact, {"base_url": target_app_url})
    assert outcome.kind == OutcomeKind.FAILURE
    assert outcome.code == "MISSING_PARAMS"
'@

Write-Host "Writing Makefile, docker-compose.yml, CI ..." -ForegroundColor Cyan
Write-ProjectFile "Makefile" @'
.RECIPEPREFIX = >

PYTHON ?= python
ARTIFACT_ID ?= lookup_member_balance

.PHONY: help setup serve discover replay replay-notfound test clean

help:
> @echo "make setup         - install deps + chromium"
> @echo "make serve         - run the mock bank app"
> @echo "make discover      - LLM discovery run (needs DEEPSEEK_API_KEY)"
> @echo "make replay        - deterministic replay (member 12345)"
> @echo "make replay-notfound  - replay with member 99999"
> @echo "make test          - run pytest"

setup:
> $(PYTHON) -m pip install -r requirements.txt
> $(PYTHON) -m playwright install chromium

serve:
> $(PYTHON) -m cli.serve_app

discover:
> $(PYTHON) -m cli.discover --artifact-id $(ARTIFACT_ID) --goal "Look up member 12345 and read their savings balance"

replay:
> $(PYTHON) -m cli.replay --artifact-id $(ARTIFACT_ID) --param base_url=http://127.0.0.1:5000 --param username=teller1 --param password=password123 --param member_id=12345

replay-notfound:
> $(PYTHON) -m cli.replay --artifact-id $(ARTIFACT_ID) --param base_url=http://127.0.0.1:5000 --param username=teller1 --param password=password123 --param member_id=99999

test:
> $(PYTHON) -m pytest -v

clean:
> $(PYTHON) -c "import shutil,pathlib;[shutil.rmtree(p,ignore_errors=True) for p in pathlib.Path('.').rglob('__pycache__')]"
> $(PYTHON) -c "import shutil;shutil.rmtree('.pytest_cache',ignore_errors=True)"
'@

Write-ProjectFile "docker-compose.yml" @'
# Optional: run the mock legacy bank app in a container.
services:
  target-app:
    image: python:3.11-slim
    working_dir: /app
    volumes:
      - ./:/app
    command: >
      sh -c "pip install --quiet flask==3.0.3 && python -m cli.serve_app"
    ports:
      - "5000:5000"
    environment:
      - TARGET_APP_PORT=5000
'@

Write-ProjectFile ".github\workflows\ci.yml" @'
name: CI

on:
  push:
    branches: [main, master]
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - name: Install dependencies
        run: |
          python -m pip install --upgrade pip
          pip install -r requirements.txt
      - name: Install Playwright Chromium
        run: python -m playwright install --with-deps chromium
      - name: Run tests
        run: python -m pytest -v
'@

Write-Host ""
Write-Host "Batch 4 (v2) done. README.md and REPORT.md will be created manually." -ForegroundColor Green