"""Allowlist enforcement for actions and domains."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import List
from urllib.parse import urlparse

from ..artifact.schema import ActionType, RiskLevel, SafetyPolicy


class SafetyViolation(Exception):
    """Raised when an action would violate the safety policy."""


@dataclass
class Decision:
    allowed: bool
    requires_confirmation: bool
    reason: str


@dataclass
class Allowlist:
    policy: SafetyPolicy
    _domains: List[str] = field(init=False)

    def __post_init__(self) -> None:
        self._domains = [d.strip().lower() for d in self.policy.allowed_domains]

    def check_url(self, url: str) -> Decision:
        host = (urlparse(url).hostname or "").lower()
        if not host:
            return Decision(False, False, f"Unparseable URL: {url}")
        for d in self._domains:
            if host == d or host.endswith("." + d):
                return Decision(True, False, f"Domain {host} allowed")
        return Decision(False, False, f"Domain {host} not in allowlist {self._domains}")

    def check_action(self, action: ActionType, risk: RiskLevel) -> Decision:
        if action not in self.policy.allowed_actions:
            return Decision(False, False, f"Action {action.value} not allowed")
        if risk == RiskLevel.IRREVERSIBLE and self.policy.irreversible_blocked:
            return Decision(False, True, "Irreversible action requires confirmation")
        if risk == RiskLevel.RISKY and self.policy.risky_requires_confirmation:
            return Decision(True, True, "Risky action requires confirmation")
        return Decision(True, False, "Action allowed")

    def enforce_url(self, url: str) -> None:
        d = self.check_url(url)
        if not d.allowed:
            raise SafetyViolation(d.reason)

    def enforce_action(self, action: ActionType, risk: RiskLevel) -> Decision:
        d = self.check_action(action, risk)
        if not d.allowed:
            raise SafetyViolation(d.reason)
        return d