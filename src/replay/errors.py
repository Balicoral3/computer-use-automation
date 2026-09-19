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