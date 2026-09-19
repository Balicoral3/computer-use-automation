# setup_batch3.ps1
# Batch 3: mock legacy bank app, replay engine, handoff, CLI replay.
# Run from project root with venv active:
#   cd C:\Projects\computer-use-automation
#   .\.venv\Scripts\Activate.ps1
#   .\setup_batch3.ps1

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

Write-Host ""
Write-Host "Writing target app..." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# src/target_app/data.py
# ---------------------------------------------------------------------------
Write-ProjectFile "src\target_app\data.py" @'
"""Mock member database for the legacy bank target app."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List


@dataclass
class Member:
    member_id: str
    full_name: str
    ssn_last4: str
    savings_balance: float
    checking_balance: float
    status: str
    subaccounts: List[Dict[str, str]] = field(default_factory=list)


MEMBERS: Dict[str, Member] = {
    "12345": Member(
        member_id="12345",
        full_name="Alice M. Johnson",
        ssn_last4="4821",
        savings_balance=12345.67,
        checking_balance=890.12,
        status="active",
        subaccounts=[
            {"id": "SA-001", "type": "Christmas Club", "balance": "500.00"},
        ],
    ),
    "67890": Member(
        member_id="67890",
        full_name="Robert L. Chen",
        ssn_last4="7733",
        savings_balance=45210.00,
        checking_balance=2200.45,
        status="active",
        subaccounts=[],
    ),
    "00000": Member(
        member_id="00000",
        full_name="Restricted Account",
        ssn_last4="0000",
        savings_balance=0.0,
        checking_balance=0.0,
        status="restricted",
        subaccounts=[],
    ),
}


VALID_USERS = {
    "teller1": "password123",
    "admin": "admin456",
}
'@

# ---------------------------------------------------------------------------
# src/target_app/app.py
# ---------------------------------------------------------------------------
Write-ProjectFile "src\target_app\app.py" @'
"""Mock legacy bank back-office app.

Intentionally built to feel like a 2000s-era server-rendered enterprise app:
  - layout via <table>, not CSS grid
  - main content inside an <iframe>
  - no data-testid, no semantic ARIA
  - generated-looking class names
  - a few runtime error states to exercise the replay engine
"""

from __future__ import annotations

import os
import random
import time
from functools import wraps

from flask import (
    Flask,
    redirect,
    render_template,
    request,
    session,
    url_for,
)

from .data import MEMBERS, VALID_USERS

app = Flask(__name__)
app.secret_key = os.environ.get("FLASK_SECRET", "dev-only-not-for-production")


def login_required(fn):
    @wraps(fn)
    def wrapper(*args, **kwargs):
        if not session.get("user"):
            return redirect(url_for("login", next=request.path))
        return fn(*args, **kwargs)
    return wrapper


@app.route("/login", methods=["GET", "POST"])
def login():
    error = None
    if request.method == "POST":
        user = request.form.get("username", "").strip()
        pw = request.form.get("password", "")
        if VALID_USERS.get(user) == pw:
            session["user"] = user
            return redirect(url_for("home"))
        error = "Invalid username or password."
    return render_template("login.html", error=error)


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


@app.route("/")
@login_required
def home():
    return render_template("base.html", user=session["user"], content_url=url_for("search"))


@app.route("/search", methods=["GET", "POST"])
@login_required
def search():
    results = None
    query = ""
    if request.method == "POST":
        query = request.form.get("q", "").strip()
        results = [MEMBERS[query]] if query in MEMBERS else []
    return render_template("search.html", query=query, results=results)


@app.route("/member/<member_id>")
@login_required
def member_detail(member_id: str):
    if member_id == "00000":
        return render_template(
            "error.html", code="PERMISSION_DENIED",
            message="You do not have permission to view this record.",
        ), 403
    m = MEMBERS.get(member_id)
    if m is None:
        return render_template(
            "error.html", code="NOT_FOUND",
            message=f"No member found with ID {member_id}.",
        ), 404
    return render_template("member_detail.html", member=m)


@app.route("/member/<member_id>/subaccount/new", methods=["GET", "POST"])
@login_required
def subaccount_new(member_id: str):
    m = MEMBERS.get(member_id)
    if m is None:
        return render_template(
            "error.html", code="NOT_FOUND",
            message=f"No member found with ID {member_id}.",
        ), 404
    if m.status == "restricted":
        return render_template(
            "error.html", code="PERMISSION_DENIED",
            message="Account is restricted; cannot open new sub-accounts.",
        ), 403

    if request.method == "POST":
        sub_type = request.form.get("sub_type", "").strip()
        initial = request.form.get("initial_deposit", "").strip()
        nickname = request.form.get("nickname", "").strip()

        errors = []
        if not sub_type:
            errors.append("Sub-account type is required.")
        if not initial:
            errors.append("Initial deposit is required.")
        else:
            try:
                amt = float(initial)
                if amt < 25.0:
                    errors.append("Initial deposit must be at least $25.00.")
            except ValueError:
                errors.append("Initial deposit must be a number.")

        if errors:
            return render_template(
                "subaccount_form.html", member=m, errors=errors,
                sub_type=sub_type, initial=initial, nickname=nickname,
            ), 400

        return render_template(
            "subaccount_confirm.html", member=m,
            sub_type=sub_type, initial=initial, nickname=nickname,
        )

    return render_template(
        "subaccount_form.html", member=m, errors=None,
        sub_type="", initial="", nickname="",
    )


@app.route("/_sim/slow")
@login_required
def sim_slow():
    time.sleep(random.uniform(3.0, 6.0))
    return render_template(
        "error.html", code="SLOW", message="This page was slow to load."
    )


@app.route("/_sim/dialog")
@login_required
def sim_dialog():
    return render_template(
        "error.html", code="DIALOG",
        message="An unexpected dialog appeared.",
    ), 200


@app.route("/_sim/timeout")
@login_required
def sim_timeout():
    session.clear()
    return redirect(url_for("login"))


if __name__ == "__main__":
    port = int(os.environ.get("TARGET_APP_PORT", "5000"))
    app.run(host="127.0.0.1", port=port, debug=False)
'@

Write-Host ""
Write-Host "Writing target templates..." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# templates
# ---------------------------------------------------------------------------
Write-ProjectFile "src\target_app\templates\base.html" @'
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>CoreBank Teller Console</title>
  <link rel="stylesheet" href="{{ url_for('static', filename='legacy.css') }}">
</head>
<body>
  <table class="cls_top" width="100%" cellpadding="0" cellspacing="0">
    <tr>
      <td class="cls_hdr" width="220">CoreBank Teller Console</td>
      <td class="cls_hdr">&nbsp;</td>
      <td class="cls_hdr" align="right">
        Signed in as <b>{{ user }}</b> |
        <a href="{{ url_for('logout') }}">Sign out</a>
      </td>
    </tr>
  </table>
  <table class="cls_shell" width="100%" cellpadding="0" cellspacing="0">
    <tr>
      <td class="cls_nav" width="180" valign="top">
        <div class="cls_navitem">Member Search</div>
        <div class="cls_navitem">Transactions</div>
        <div class="cls_navitem">Sub-Accounts</div>
        <div class="cls_navitem">Reports</div>
      </td>
      <td valign="top">
        <iframe id="mainFrame" name="mainFrame"
                src="{{ content_url }}"
                width="100%" height="640" frameborder="0"></iframe>
      </td>
    </tr>
  </table>
</body>
</html>
'@

Write-ProjectFile "src\target_app\templates\login.html" @'
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>CoreBank - Sign In</title>
  <link rel="stylesheet" href="{{ url_for('static', filename='legacy.css') }}">
</head>
<body>
  <table class="cls_login" cellpadding="8" cellspacing="0">
    <tr><td class="cls_login_hdr" colspan="2">CoreBank Sign In</td></tr>
    <form method="post" action="{{ url_for('login') }}">
      <tr>
        <td class="cls_lbl">Username</td>
        <td><input type="text" name="username" size="24"></td>
      </tr>
      <tr>
        <td class="cls_lbl">Password</td>
        <td><input type="password" name="password" size="24"></td>
      </tr>
      <tr>
        <td colspan="2" align="right">
          <input type="submit" value="Sign In">
        </td>
      </tr>
    </form>
    {% if error %}
    <tr><td colspan="2" class="cls_err">{{ error }}</td></tr>
    {% endif %}
  </table>
</body>
</html>
'@

Write-ProjectFile "src\target_app\templates\search.html" @'
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Member Search</title>
  <link rel="stylesheet" href="{{ url_for('static', filename='legacy.css') }}">
</head>
<body>
  <h3>Member Search</h3>
  <form method="post" action="{{ url_for('search') }}">
    <table cellpadding="4" cellspacing="0">
      <tr>
        <td>Member ID</td>
        <td><input type="text" name="q" value="{{ query }}" size="20"></td>
        <td><input type="submit" value="Search"></td>
      </tr>
    </table>
  </form>

  {% if results is not none %}
    {% if results %}
      <table class="cls_grid" cellpadding="4" cellspacing="0" border="1">
        <tr>
          <th>Member ID</th><th>Name</th><th>Status</th><th>&nbsp;</th>
        </tr>
        {% for m in results %}
        <tr>
          <td>{{ m.member_id }}</td>
          <td>{{ m.full_name }}</td>
          <td>{{ m.status }}</td>
          <td><a href="{{ url_for('member_detail', member_id=m.member_id) }}">Open</a></td>
        </tr>
        {% endfor %}
      </table>
    {% else %}
      <p class="cls_warn">No members matched "{{ query }}".</p>
    {% endif %}
  {% endif %}
</body>
</html>
'@

Write-ProjectFile "src\target_app\templates\member_detail.html" @'
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Member {{ member.member_id }}</title>
  <link rel="stylesheet" href="{{ url_for('static', filename='legacy.css') }}">
</head>
<body>
  <h3>Member Detail</h3>
  <table class="cls_grid" cellpadding="4" cellspacing="0" border="1">
    <tr><td class="cls_lbl">Member ID</td><td id="memberId">{{ member.member_id }}</td></tr>
    <tr><td class="cls_lbl">Full Name</td><td id="memberName">{{ member.full_name }}</td></tr>
    <tr><td class="cls_lbl">SSN (last 4)</td><td>{{ member.ssn_last4 }}</td></tr>
    <tr><td class="cls_lbl">Status</td><td>{{ member.status }}</td></tr>
    <tr><td class="cls_lbl">Savings Balance</td>
        <td id="savingsBalance">${{ "%.2f"|format(member.savings_balance) }}</td></tr>
    <tr><td class="cls_lbl">Checking Balance</td>
        <td id="checkingBalance">${{ "%.2f"|format(member.checking_balance) }}</td></tr>
  </table>

  <p>
    <a id="newSubaccount" href="{{ url_for('subaccount_new', member_id=member.member_id) }}">
      Open a new sub-account
    </a>
  </p>

  {% if member.subaccounts %}
  <h4>Existing Sub-Accounts</h4>
  <table class="cls_grid" cellpadding="4" cellspacing="0" border="1">
    <tr><th>ID</th><th>Type</th><th>Balance</th></tr>
    {% for sa in member.subaccounts %}
    <tr><td>{{ sa.id }}</td><td>{{ sa.type }}</td><td>${{ sa.balance }}</td></tr>
    {% endfor %}
  </table>
  {% endif %}
</body>
</html>
'@

Write-ProjectFile "src\target_app\templates\subaccount_form.html" @'
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>New Sub-Account</title>
  <link rel="stylesheet" href="{{ url_for('static', filename='legacy.css') }}">
</head>
<body>
  <h3>Open New Sub-Account &mdash; Member {{ member.member_id }}</h3>

  {% if errors %}
  <table class="cls_errbox" cellpadding="4" cellspacing="0">
    {% for e in errors %}
    <tr><td class="cls_err">{{ e }}</td></tr>
    {% endfor %}
  </table>
  {% endif %}

  <form method="post" action="{{ url_for('subaccount_new', member_id=member.member_id) }}">
    <table cellpadding="4" cellspacing="0">
      <tr>
        <td>Sub-Account Type</td>
        <td>
          <select name="sub_type">
            <option value="">-- select --</option>
            <option value="Christmas Club" {% if sub_type == "Christmas Club" %}selected{% endif %}>Christmas Club</option>
            <option value="Vacation Club" {% if sub_type == "Vacation Club" %}selected{% endif %}>Vacation Club</option>
            <option value="Money Market" {% if sub_type == "Money Market" %}selected{% endif %}>Money Market</option>
          </select>
        </td>
      </tr>
      <tr>
        <td>Initial Deposit (USD)</td>
        <td><input type="text" name="initial_deposit" value="{{ initial }}" size="16"></td>
      </tr>
      <tr>
        <td>Nickname (optional)</td>
        <td><input type="text" name="nickname" value="{{ nickname }}" size="24"></td>
      </tr>
      <tr>
        <td colspan="2" align="right">
          <input type="submit" value="Continue to Confirmation">
        </td>
      </tr>
    </table>
  </form>
</body>
</html>
'@

Write-ProjectFile "src\target_app\templates\subaccount_confirm.html" @'
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Confirm Sub-Account</title>
  <link rel="stylesheet" href="{{ url_for('static', filename='legacy.css') }}">
</head>
<body>
  <h3>Confirmation</h3>
  <table class="cls_grid" cellpadding="4" cellspacing="0" border="1">
    <tr><td class="cls_lbl">Member</td><td id="confirmMember">{{ member.member_id }} &mdash; {{ member.full_name }}</td></tr>
    <tr><td class="cls_lbl">Sub-Account Type</td><td id="confirmType">{{ sub_type }}</td></tr>
    <tr><td class="cls_lbl">Initial Deposit</td><td id="confirmDeposit">${{ "%.2f"|format(initial|float) }}</td></tr>
    <tr><td class="cls_lbl">Nickname</td><td>{{ nickname or "(none)" }}</td></tr>
  </table>
  <p class="cls_ok" id="confirmMsg">Sub-account is ready to be opened. This is the confirmation screen.</p>
</body>
</html>
'@

Write-ProjectFile "src\target_app\templates\error.html" @'
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Error</title>
  <link rel="stylesheet" href="{{ url_for('static', filename='legacy.css') }}">
  {% if code == "DIALOG" %}
  <script>
    window.onload = function () {
      confirm("Session notice: an unexpected dialog has appeared.");
    };
  </script>
  {% endif %}
</head>
<body>
  <table class="cls_errbox" cellpadding="6" cellspacing="0" id="errorBox">
    <tr><td class="cls_err_hdr" id="errorCode">Error: {{ code }}</td></tr>
    <tr><td class="cls_err" id="errorMessage">{{ message }}</td></tr>
  </table>
</body>
</html>
'@

Write-ProjectFile "src\target_app\static\legacy.css" @'
body { font-family: Verdana, Arial, sans-serif; font-size: 12px; background:#d9d9d9; margin:0; }
.cls_top { background:#003366; color:#fff; }
.cls_hdr { padding:6px 10px; font-weight:bold; font-size:12px; }
.cls_shell { background:#f4f4f4; }
.cls_nav { background:#e6e6e6; border-right:1px solid #999; height:640px; padding:8px 4px; }
.cls_navitem { padding:6px 8px; border-bottom:1px solid #ccc; color:#003366; cursor:pointer; }
.cls_navitem:hover { background:#d0d0d0; }
.cls_login { margin:80px auto; background:#efefef; border:1px solid #666; }
.cls_login_hdr { background:#003366; color:#fff; font-weight:bold; text-align:center; padding:8px; }
.cls_lbl { background:#e0e0e0; font-weight:bold; }
.cls_err { color:#990000; font-weight:bold; padding:4px; }
.cls_errbox { margin:20px; border:1px solid #990000; background:#fff0f0; }
.cls_err_hdr { background:#990000; color:#fff; font-weight:bold; }
.cls_ok { color:#006600; font-weight:bold; }
.cls_warn { color:#996600; font-weight:bold; }
.cls_grid { background:#fff; border-collapse:collapse; }
.cls_grid th { background:#003366; color:#fff; }
h3 { color:#003366; }
a { color:#003366; }
'@

# ---------------------------------------------------------------------------
# cli/serve_app.py
# ---------------------------------------------------------------------------
Write-ProjectFile "cli\serve_app.py" @'
"""Run the mock legacy bank app."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from src.target_app.app import app

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5000, debug=False)
'@

Write-Host ""
Write-Host "Writing replay engine..." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# src/replay/errors.py
# ---------------------------------------------------------------------------
Write-ProjectFile "src\replay\errors.py" @'
"""Error taxonomy for replay.

Three kinds, as the brief demands:
  - BUSINESS: a legitimate outcome the caller must see (NOT_FOUND, etc.)
  - RECOVERABLE: transient; replay can dismiss/retry and continue
  - HARD: stop and surface a debuggable error
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Dict, List, Optional


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
    """Raised when a step cannot proceed and is not recoverable."""

    def __init__(self, code: str, message: str, observed: str = "",
                 expected: str = "", step_id: str = "") -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.observed = observed
        self.expected = expected
        self.step_id = step_id


# Detection heuristics ------------------------------------------------------

ERROR_SIGNATURES = [
    ("NOT_FOUND", "No member found", OutcomeKind.BUSINESS),
    ("PERMISSION_DENIED", "You do not have permission", OutcomeKind.BUSINESS),
    ("PERMISSION_DENIED", "Account is restricted", OutcomeKind.BUSINESS),
    ("VALIDATION_ERROR", "is required", OutcomeKind.BUSINESS),
    ("VALIDATION_ERROR", "must be a number", OutcomeKind.BUSINESS),
    ("VALIDATION_ERROR", "must be at least", OutcomeKind.BUSINESS),
    ("SESSION_EXPIRED", "CoreBank Sign In", OutcomeKind.RECOVERABLE),
]


def detect_known_outcome(page_text: str) -> Optional[tuple]:
    """Return (code, kind) if page_text matches a known error signature."""
    if not page_text:
        return None
    for code, needle, kind in ERROR_SIGNATURES:
        if needle.lower() in page_text.lower():
            return (code, kind)
    return None
'@

# ---------------------------------------------------------------------------
# src/replay/locator.py
# ---------------------------------------------------------------------------
Write-ProjectFile "src\replay\locator.py" @'
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
'@

# ---------------------------------------------------------------------------
# src/replay/checkpoint.py
# ---------------------------------------------------------------------------
Write-ProjectFile "src\replay\checkpoint.py" @'
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
'@

Write-Host ""
Write-Host "Writing replay engine..." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# src/replay/engine.py
# ---------------------------------------------------------------------------
Write-ProjectFile "src\replay\engine.py" @'
"""Deterministic replay engine.

No LLM in the loop. Reads a CapabilityArtifact, substitutes parameters,
executes each step, verifies checkpoints, and returns a structured outcome.
"""

from __future__ import annotations

import json
import time
from typing import Any, Callable, Dict, Optional

from playwright.sync_api import Page

from ..artifact.schema import (
    ActionType,
    CapabilityArtifact,
    ErrorKind,
    RiskLevel,
    Step,
)
from ..evidence.logger import RunLogger
from ..safety.allowlist import Allowlist, SafetyViolation
from . import locator as loc_mod
from .checkpoint import verify as verify_checkpoint
from .errors import (
    OutcomeKind,
    ReplayOutcome,
    StepFailure,
    detect_known_outcome,
)


# A confirmation callback: given (step, message) returns True to proceed.
ConfirmFn = Callable[[Step, str], bool]


def _default_confirm(step: Step, message: str) -> bool:
    # Non-interactive default: refuse risky actions rather than silently doing them.
    print(f"[safety] Refusing without confirmation: {message}")
    return False


class ReplayEngine:
    def __init__(
        self,
        page: Page,
        allowlist: Allowlist,
        logger: RunLogger,
        confirm: Optional[ConfirmFn] = None,
    ) -> None:
        self.page = page
        self.allowlist = allowlist
        self.logger = logger
        self.confirm = confirm or _default_confirm

    # -- public ------------------------------------------------------------
    def run(self, artifact: CapabilityArtifact, params: Dict[str, Any]) -> ReplayOutcome:
        self.logger.log(
            "replay.start",
            artifact_id=artifact.id,
            version=artifact.version,
            params={k: v for k, v in params.items()},
        )

        # Validate params
        missing = [
            p.name for p in artifact.parameters
            if p.required and p.name not in params
        ]
        if missing:
            return ReplayOutcome(
                kind=OutcomeKind.FAILURE,
                code="MISSING_PARAMS",
                message=f"Missing required parameters: {missing}",
            )

        outputs: Dict[str, Any] = {}

        try:
            self.page.goto(artifact.target.entry_url, wait_until="domcontentloaded")
            self.allowlist.enforce_url(self.page.url)
        except SafetyViolation as exc:
            return ReplayOutcome(
                kind=OutcomeKind.FAILURE, code="SAFETY_BLOCK",
                message=str(exc),
            )

        for step in artifact.steps:
            outcome = self._execute_step(step, artifact, params, outputs)
            if outcome is not None:
                self.logger.write_result(outcome.to_dict())
                return outcome

        # Final checkpoint
        passed, observed = verify_checkpoint(self.page, artifact.checkpoint)
        if not passed:
            self._capture_failure_evidence("final_checkpoint")
            outcome = ReplayOutcome(
                kind=OutcomeKind.FAILURE,
                code="CHECKPOINT_FAILED",
                message=artifact.checkpoint.description,
                outputs=outputs,
                expected=artifact.checkpoint.description,
                observed=observed,
                evidence_path=str(self.logger.path),
            )
            self.logger.write_result(outcome.to_dict())
            return outcome

        outcome = ReplayOutcome(
            kind=OutcomeKind.SUCCESS,
            code="OK",
            message="Replay completed and checkpoint verified.",
            outputs=outputs,
            evidence_path=str(self.logger.path),
        )
        self.logger.log("replay.success", outputs=list(outputs.keys()))
        self.logger.write_result(outcome.to_dict())
        return outcome

    # -- internals ---------------------------------------------------------
    def _execute_step(
        self,
        step: Step,
        artifact: CapabilityArtifact,
        params: Dict[str, Any],
        outputs: Dict[str, Any],
    ) -> Optional[ReplayOutcome]:
        # Safety gate
        try:
            decision = self.allowlist.enforce_action(step.action, step.risk)
        except SafetyViolation as exc:
            return ReplayOutcome(
                kind=OutcomeKind.FAILURE, code="SAFETY_BLOCK",
                message=str(exc), step_id=step.id,
                evidence_path=str(self.logger.path),
            )

        if decision.requires_confirmation:
            approved = self.confirm(step, decision.reason)
            if not approved:
                return ReplayOutcome(
                    kind=OutcomeKind.FAILURE,
                    code="CONFIRMATION_DENIED",
                    message=f"Risky step {step.id} not confirmed",
                    step_id=step.id,
                )

        # Resolve value with params
        value = artifact.render_value(step.value, params)

        self.logger.log("replay.step", step_id=step.id, action=step.action.value,
                        description=step.description, risk=step.risk.value)

        # Pre-step business / recoverable detection: check for known error surface
        pre_outcome = self._detect_pre_step_outcome(step, outputs)
        if pre_outcome is not None:
            return pre_outcome

        try:
            self._perform(step, value)
        except StepFailure as exc:
            return self._handle_step_failure(step, exc, outputs)
        except Exception as exc:
            self._capture_failure_evidence(step.id)
            return ReplayOutcome(
                kind=OutcomeKind.FAILURE, code="STEP_ACTION_ERROR",
                message=f"{type(exc).__name__}: {exc}",
                step_id=step.id,
                evidence_path=str(self.logger.path),
            )

        # Post-step: read into outputs if action is READ
        if step.action == ActionType.READ and step.locator is not None:
            try:
                loc = loc_mod.resolve(self.page, step.locator, step.timeout_ms)
                text = loc.first.inner_text(timeout=step.timeout_ms)
                name = step.description.split("->")[-1].strip() if "->" in step.description else step.id
                # Prefer output declared in artifact with from_step == step.id
                declared = next((o for o in artifact.outputs if o.from_step == step.id), None)
                key = declared.name if declared else name
                outputs[key] = text
                self.logger.log("replay.read", step_id=step.id, output_name=key)
            except Exception as exc:
                self.logger.log("replay.read_error", step_id=step.id, error=str(exc))

        # Post-step: explicit checkpoint
        if step.post_checkpoint is not None:
            passed, observed = verify_checkpoint(self.page, step.post_checkpoint)
            if not passed:
                self._capture_failure_evidence(f"{step.id}_checkpoint")
                return ReplayOutcome(
                    kind=OutcomeKind.FAILURE,
                    code="CHECKPOINT_FAILED",
                    message=step.post_checkpoint.description,
                    outputs=outputs,
                    step_id=step.id,
                    expected=step.post_checkpoint.description,
                    observed=observed,
                    evidence_path=str(self.logger.path),
                )

        # Post-step: detect known business outcomes
        post_outcome = self._detect_known_outcome_after(step, outputs)
        if post_outcome is not None:
            return post_outcome

        return None

    def _perform(self, step: Step, value: Optional[str]) -> None:
        page = self.page
        if step.action == ActionType.NAVIGATE:
            if not value:
                raise StepFailure("MISSING_VALUE", "navigate step has no URL",
                                  step_id=step.id)
            self.allowlist.enforce_url(value)
            page.goto(value, wait_until="domcontentloaded")
            return

        if step.locator is None:
            raise StepFailure("MISSING_LOCATOR", f"{step.action.value} requires locator",
                              step_id=step.id)

        loc = loc_mod.resolve(page, step.locator, step.timeout_ms)

        if step.action == ActionType.CLICK:
            loc.first.click(timeout=step.timeout_ms)
            try:
                page.wait_for_load_state("networkidle", timeout=3000)
            except Exception:
                pass
        elif step.action == ActionType.FILL:
            loc.first.fill(value or "", timeout=step.timeout_ms)
        elif step.action == ActionType.SELECT:
            loc.first.select_option(label=value or "", timeout=step.timeout_ms)
        elif step.action == ActionType.PRESS:
            loc.first.press(value or "Enter", timeout=step.timeout_ms)
        elif step.action == ActionType.WAIT_FOR:
            loc.first.wait_for(state="visible", timeout=step.timeout_ms)
        elif step.action == ActionType.ASSERT_TEXT:
            text = loc.first.inner_text(timeout=step.timeout_ms)
            if value and value.lower() not in text.lower():
                raise StepFailure(
                    "ASSERT_FAILED",
                    f"Expected {value!r} in {text!r}",
                    expected=value, observed=text, step_id=step.id,
                )
        elif step.action == ActionType.SCREENSHOT:
            self.page.screenshot(path=str(self.logger.screenshot_path(step.id)))
        # READ handled by caller
        return

    # -- detection helpers -------------------------------------------------
    def _detect_pre_step_outcome(
        self, step: Step, outputs: Dict[str, Any]
    ) -> Optional[ReplayOutcome]:
        # Look for error surfaces already present before this step.
        try:
            body = self.page.evaluate("() => document.body ? document.body.innerText : ''")
        except Exception:
            body = ""
        detected = detect_known_outcome(body)
        if detected is None:
            return None
        code, kind = detected
        if kind == OutcomeKind.RECOVERABLE:
            # try to recover: if session expired, re-login is the caller's concern.
            self.logger.log("replay.recoverable", step_id=step.id, code=code)
            # We don't re-login here; instead surface as business-level recoverable
            return ReplayOutcome(
                kind=OutcomeKind.BUSINESS, code=code,
                message="Recoverable condition encountered (session).",
                step_id=step.id, evidence_path=str(self.logger.path),
            )
        if kind == OutcomeKind.BUSINESS:
            self._capture_failure_evidence(f"{step.id}_business")
            return ReplayOutcome(
                kind=OutcomeKind.BUSINESS, code=code,
                message=f"Business outcome {code} detected before step {step.id}",
                outputs=outputs, step_id=step.id,
                evidence_path=str(self.logger.path),
            )
        return None

    def _detect_known_outcome_after(
        self, step: Step, outputs: Dict[str, Any]
    ) -> Optional[ReplayOutcome]:
        try:
            body = self.page.evaluate("() => document.body ? document.body.innerText : ''")
        except Exception:
            body = ""
        detected = detect_known_outcome(body)
        if detected is None:
            return None
        code, kind = detected
        if kind == OutcomeKind.BUSINESS:
            self._capture_failure_evidence(f"{step.id}_business")
            return ReplayOutcome(
                kind=OutcomeKind.BUSINESS, code=code,
                message=f"Business outcome {code} at step {step.id}",
                outputs=outputs, step_id=step.id,
                evidence_path=str(self.logger.path),
            )
        return None

    def _handle_step_failure(
        self, step: Step, exc: StepFailure, outputs: Dict[str, Any]
    ) -> ReplayOutcome:
        # Check declared error handlers for this step
        for handler in step.error_handlers:
            if handler.code == exc.code or handler.kind == ErrorKind.BUSINESS:
                if handler.kind == ErrorKind.BUSINESS:
                    return ReplayOutcome(
                        kind=OutcomeKind.BUSINESS, code=handler.code,
                        message=handler.message or exc.message,
                        outputs=outputs, step_id=step.id,
                        evidence_path=str(self.logger.path),
                    )
                if handler.kind == ErrorKind.RECOVERABLE and handler.recover_action == "retry":
                    for _ in range(handler.max_retries):
                        try:
                            self._perform(step, None)
                            return None  # type: ignore[return-value]
                        except Exception:
                            continue
        self._capture_failure_evidence(step.id)
        return ReplayOutcome(
            kind=OutcomeKind.FAILURE, code=exc.code, message=exc.message,
            outputs=outputs, step_id=step.id,
            expected=exc.expected, observed=exc.observed,
            evidence_path=str(self.logger.path),
        )

    def _capture_failure_evidence(self, tag: str) -> None:
        try:
            self.page.screenshot(path=str(self.logger.screenshot_path(f"failure_{tag}")))
        except Exception:
            pass
        try:
            html = self.page.content()
            self.logger.dom_path(f"failure_{tag}").write_text(html, encoding="utf-8")
        except Exception:
            pass
'@

Write-Host ""
Write-Host "Writing handoff + replay CLI..." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# src/handoff/cli.py
# ---------------------------------------------------------------------------
Write-ProjectFile "src\handoff\cli.py" @'
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
'@

# ---------------------------------------------------------------------------
# cli/replay.py
# ---------------------------------------------------------------------------
Write-ProjectFile "cli\replay.py" @'
"""CLI: replay a saved artifact deterministically.

Usage:
  python -m cli.replay --artifact-id lookup_member_balance --param member_id=12345
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from dotenv import load_dotenv
from playwright.sync_api import sync_playwright

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from src.artifact.schema import ActionType, RiskLevel, SafetyPolicy, Step
from src.artifact.store import ArtifactStore
from src.evidence.logger import RunLogger
from src.replay.engine import ReplayEngine
from src.replay.errors import OutcomeKind
from src.safety.allowlist import Allowlist
from src.handoff.cli import CLIHandoff, HandoffRequest


def _parse_params(items):
    out = {}
    for item in items or []:
        if "=" not in item:
            raise SystemExit(f"Bad --param (expected key=value): {item}")
        k, v = item.split("=", 1)
        out[k.strip()] = v.strip()
    return out


def _make_confirm(page, logger):
    def confirm(step: Step, reason: str) -> bool:
        # Offer the human a choice via handoff console.
        print(f"\n[safety] Step {step.id} ({step.action.value}) flagged: {reason}")
        try:
            ans = input("Approve this step? [y/N] ").strip().lower()
        except EOFError:
            ans = "n"
        logger.log("safety.confirm", step_id=step.id, approved=(ans == "y"))
        return ans == "y"
    return confirm


def main() -> int:
    load_dotenv()
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact-id", required=True)
    parser.add_argument("--param", action="append", default=[])
    parser.add_argument("--headless", action="store_true")
    parser.add_argument("--auto-handoff", action="store_true",
                        help="If a hard failure occurs, offer handoff instead of exiting.")
    args = parser.parse_args()

    params = _parse_params(args.param)
    store = ArtifactStore(os.environ.get("ARTIFACTS_DIR", "artifacts"))
    artifact = store.load(args.artifact_id)

    allowed = artifact.safety.allowed_domains or ["127.0.0.1", "localhost"]
    allowlist = Allowlist(policy=artifact.safety)

    logger = RunLogger(kind="replay")

    with sync_playwright() as pw_ctx:
        browser = pw_ctx.chromium.launch(headless=args.headless)
        context = browser.new_context(viewport={"width": 1280, "height": 800})
        page = context.new_page()
        page.set_default_timeout(10_000)

        confirm_fn = _make_confirm(page, logger)
        engine = ReplayEngine(page=page, allowlist=allowlist, logger=logger,
                              confirm=confirm_fn)

        outcome = engine.run(artifact, params)

        print()
        print("=" * 70)
        print(f"Replay outcome: {outcome.kind.value}  code={outcome.code}")
        print(f"Message: {outcome.message}")
        if outcome.outputs:
            print(f"Outputs: {json.dumps(outcome.outputs, indent=2)}")
        print(f"Evidence: {logger.path}")
        print("=" * 70)

        # Optional: offer handoff on failure
        if outcome.kind == OutcomeKind.FAILURE and args.auto_handoff:
            handoff = CLIHandoff(page=page, logger=logger)
            res = handoff.request(HandoffRequest(
                reason=f"Replay failed at {outcome.step_id}: {outcome.code}",
                step_id=outcome.step_id,
                context=outcome.message,
            ))
            if res.resumed:
                print("Handoff complete. (Not resuming replay automatically in v1.)")
            else:
                print("Handoff aborted.")

        browser.close()

    return 0 if outcome.kind == OutcomeKind.SUCCESS else 1


if __name__ == "__main__":
    raise SystemExit(main())
'@

Write-Host ""
Write-Host "Batch 3 files written." -ForegroundColor Green
Write-Host ""
Write-Host "Verify with:" -ForegroundColor Yellow
Write-Host "  python -c `"from src.target_app.app import app; print('app OK')`""
Write-Host "  python -c `"from src.replay.engine import ReplayEngine; print('replay OK')`""
Write-Host "  python -c `"from src.handoff.cli import CLIHandoff; print('handoff OK')`""
Write-Host "  python -c `"from cli.replay import main; print('replay cli OK')`""