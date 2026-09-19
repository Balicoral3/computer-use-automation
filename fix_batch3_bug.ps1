# fix_batch3_bug.ps1
# Fixes: ERROR_SIGNATURES used OutcomeKind.RECOVERABLE (doesn't exist).
# Correct type is ErrorKind (from ..artifact.schema).

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

Note: BUSINESS/RECOVERABLE/HARD are *categories of detection* (ErrorKind).
The *result* of a replay is one of SUCCESS/BUSINESS/FAILURE (OutcomeKind).
Don't conflate the two.
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
# Each entry: (code, needle_in_page_text, ErrorKind)
ERROR_SIGNATURES = [
    ("NOT_FOUND",         "No member found",              ErrorKind.BUSINESS),
    ("PERMISSION_DENIED", "You do not have permission",   ErrorKind.BUSINESS),
    ("PERMISSION_DENIED", "Account is restricted",        ErrorKind.BUSINESS),
    ("VALIDATION_ERROR",  "is required",                  ErrorKind.BUSINESS),
    ("VALIDATION_ERROR",  "must be a number",             ErrorKind.BUSINESS),
    ("VALIDATION_ERROR",  "must be at least",             ErrorKind.BUSINESS),
    ("SESSION_EXPIRED",   "CoreBank Sign In",             ErrorKind.RECOVERABLE),
]


def detect_known_outcome(page_text: str) -> Optional[Tuple[str, ErrorKind]]:
    """Return (code, ErrorKind) if page_text matches a known error signature."""
    if not page_text:
        return None
    for code, needle, kind in ERROR_SIGNATURES:
        if needle.lower() in page_text.lower():
            return (code, kind)
    return None
'@

Write-Host ""
Write-Host "Patching src/replay/engine.py ..." -ForegroundColor Cyan

$enginePath = Join-Path $root "src\replay\engine.py"
if (-not (Test-Path $enginePath)) {
    Write-Host "ERROR: engine.py not found at $enginePath" -ForegroundColor Red
    exit 1
}

$engine = [System.IO.File]::ReadAllText($enginePath, $utf8)

# Two targeted replacements: comparisons against the detection result must
# use ErrorKind (categories of detection), not OutcomeKind (replay result).
$engine = $engine.Replace(
    "if kind == OutcomeKind.RECOVERABLE:",
    "if kind == ErrorKind.RECOVERABLE:"
)
$engine = $engine.Replace(
    "if kind == OutcomeKind.BUSINESS:",
    "if kind == ErrorKind.BUSINESS:"
)

[System.IO.File]::WriteAllText($enginePath, $engine, $utf8)
Write-Host "  patched src/replay/engine.py" -ForegroundColor Green

Write-Host ""
Write-Host "Done. Verifying..." -ForegroundColor Yellow
Write-Host ""

python -c "from src.replay.errors import detect_known_outcome, OutcomeKind; print('errors OK')"
python -c "from src.replay.engine import ReplayEngine; print('replay OK')"
python -c "from cli.replay import main; print('replay cli OK')"