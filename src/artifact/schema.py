"""Capability artifact schema.

This is the focal point of the system: a typed, versioned, serializable
description of a reusable UI automation flow. It is deliberately decoupled
from the raw LLM transcript so that:

  1. A human reviewer can read it and understand what the capability does.
  2. A calling AI agent can invoke it with typed params and get typed outputs.
  3. The replay engine can execute it deterministically without an LLM.

Design decisions (defended in REPORT.md):
  - Locators are layered: role/label/text first (semantic, stable), then
    CSS/XPath, then coordinates as a last-resort fallback.
  - Errors are classified into three kinds: business outcomes, recoverable
    conditions, and hard failures.
  - Values in steps are templated ("{{member_id}}") so one artifact can be
    invoked with different parameters.
  - Steps carry a risk level so the safety layer can gate irreversible
    actions behind human confirmation.
"""

from __future__ import annotations

from datetime import datetime, timezone
from enum import Enum
from typing import Any, Dict, List, Literal, Optional

from pydantic import BaseModel, Field, field_validator


class LocatorStrategy(str, Enum):
    ROLE = "role"
    LABEL = "label"
    TEXT = "text"
    PLACEHOLDER = "placeholder"
    CSS = "css"
    XPATH = "xpath"
    COORDINATES = "coordinates"


class ActionType(str, Enum):
    NAVIGATE = "navigate"
    CLICK = "click"
    FILL = "fill"
    SELECT = "select"
    PRESS = "press"
    READ = "read"
    WAIT_FOR = "wait_for"
    ASSERT_TEXT = "assert_text"
    SCREENSHOT = "screenshot"


class RiskLevel(str, Enum):
    SAFE = "safe"
    RISKY = "risky"
    IRREVERSIBLE = "irreversible"


class ErrorKind(str, Enum):
    BUSINESS = "business"
    RECOVERABLE = "recoverable"
    HARD = "hard"


class SurfaceType(str, Enum):
    WEB = "web"
    LEGACY_WEB = "legacy_web"
    DESKTOP = "desktop"


class Locator(BaseModel):
    strategy: LocatorStrategy
    value: str
    name: Optional[str] = None
    exact: bool = True
    frame_path: Optional[List[str]] = None
    fallbacks: List["Locator"] = Field(default_factory=list)

    def describe(self) -> str:
        if self.strategy == LocatorStrategy.ROLE:
            return f"role={self.value!r} name={self.name!r}"
        return f"{self.strategy.value}={self.value!r}"


class Parameter(BaseModel):
    name: str
    type: Literal["string", "integer", "float", "boolean"]
    required: bool = True
    description: str
    example: Optional[str] = None
    pattern: Optional[str] = None
    redact: bool = False


class Output(BaseModel):
    name: str
    type: Literal["string", "integer", "float", "boolean"]
    description: str
    from_step: str
    locator: Optional[Locator] = None
    regex: Optional[str] = None
    redact: bool = True


class ErrorHandler(BaseModel):
    kind: ErrorKind
    code: str
    detect_locator: Optional[Locator] = None
    detect_text: Optional[str] = None
    recover_action: Optional[Literal["retry", "dismiss", "skip"]] = None
    max_retries: int = 1
    message: Optional[str] = None


class Checkpoint(BaseModel):
    description: str
    locator: Locator
    expected_text: Optional[str] = None
    timeout_ms: int = 10_000


class Step(BaseModel):
    id: str
    action: ActionType
    description: str
    locator: Optional[Locator] = None
    value: Optional[str] = None
    risk: RiskLevel = RiskLevel.SAFE
    timeout_ms: int = 10_000
    error_handlers: List[ErrorHandler] = Field(default_factory=list)
    post_checkpoint: Optional[Checkpoint] = None

    @field_validator("value")
    @classmethod
    def _no_secrets_in_value(cls, v: Optional[str]) -> Optional[str]:
        if v and v.startswith("sk-"):
            raise ValueError("Refusing to embed API-key-like value in step.")
        return v


class TargetInfo(BaseModel):
    app_id: str
    entry_url: str
    surface_type: SurfaceType = SurfaceType.LEGACY_WEB
    tenant_id: Optional[str] = None
    app_version: Optional[str] = None
    adapter: str = "playwright-web"


class SafetyPolicy(BaseModel):
    allowed_domains: List[str]
    allowed_actions: List[ActionType]
    risky_requires_confirmation: bool = True
    irreversible_blocked: bool = True


class CapabilityArtifact(BaseModel):
    schema_version: str = "1.0"
    id: str
    name: str
    version: str = "1.0.0"
    description: str
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    llm_model: str
    target: TargetInfo
    parameters: List[Parameter] = Field(default_factory=list)
    outputs: List[Output] = Field(default_factory=list)
    steps: List[Step] = Field(default_factory=list)
    checkpoint: Checkpoint
    safety: SafetyPolicy
    metadata: Dict[str, Any] = Field(default_factory=dict)

    def render_value(self, template: Optional[str], params: Dict[str, Any]) -> Optional[str]:
        if template is None:
            return None
        out = template
        for key, val in params.items():
            out = out.replace("{{" + key + "}}", str(val))
        return out

    def parameter_names(self) -> List[str]:
        return [p.name for p in self.parameters]


Locator.model_rebuild()
Step.model_rebuild()
CapabilityArtifact.model_rebuild()