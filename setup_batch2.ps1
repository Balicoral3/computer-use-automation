# setup_batch2.ps1
# Creates all project files for the computer-use automation assessment.
# Run from project root with venv active:
#   cd C:\Projects\computer-use-automation
#   .\.venv\Scripts\Activate.ps1
#   .\setup_batch2.ps1

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

# ---------------------------------------------------------------------------
# Create directory skeleton
# ---------------------------------------------------------------------------
$dirs = @(
    "src", "src\artifact", "src\agent", "src\replay", "src\safety",
    "src\handoff", "src\evidence", "src\target_app",
    "src\target_app\templates", "src\target_app\static",
    "cli", "tests", "artifacts", "evidence"
)
foreach ($d in $dirs) {
    New-Item -ItemType Directory -Force -Path (Join-Path $root $d) | Out-Null
}

# ---------------------------------------------------------------------------
# __init__.py files
# ---------------------------------------------------------------------------
foreach ($p in @(
    "src\__init__.py", "src\artifact\__init__.py", "src\agent\__init__.py",
    "src\replay\__init__.py", "src\safety\__init__.py", "src\handoff\__init__.py",
    "src\evidence\__init__.py", "src\target_app\__init__.py", "tests\__init__.py"
)) {
    Write-ProjectFile $p ""
}

Write-Host ""
Write-Host "Writing config files..." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# .env.example
# ---------------------------------------------------------------------------
Write-ProjectFile ".env.example" @'
# DeepSeek API
DEEPSEEK_API_KEY=sk-your-key-here
DEEPSEEK_BASE_URL=https://api.deepseek.com/v1
DEEPSEEK_MODEL=deepseek-chat

# Target app
TARGET_APP_HOST=127.0.0.1
TARGET_APP_PORT=5000
TARGET_APP_BASE_URL=http://127.0.0.1:5000

# Credentials for the mock legacy bank app
TARGET_USERNAME=teller1
TARGET_PASSWORD=password123

# Safety
ALLOWED_DOMAINS=127.0.0.1,localhost
MAX_STEPS=25
STEP_TIMEOUT_SEC=10
GLOBAL_TIMEOUT_SEC=180

# Evidence
EVIDENCE_DIR=./evidence
ARTIFACTS_DIR=./artifacts
'@

# ---------------------------------------------------------------------------
# .gitignore
# ---------------------------------------------------------------------------
Write-ProjectFile ".gitignore" @'
__pycache__/
*.pyc
.env
.venv/
venv/
evidence/*
!evidence/.gitkeep
artifacts/*.json
!artifacts/.gitkeep
playwright-report/
test-results/
.vscode/
.idea/
*.log
'@

# ---------------------------------------------------------------------------
# pyproject.toml
# ---------------------------------------------------------------------------
Write-ProjectFile "pyproject.toml" @'
[project]
name = "computer-use-automation"
version = "0.1.0"
description = "LLM-driven computer-use automation with deterministic replay"
requires-python = ">=3.11"

[tool.pytest.ini_options]
testpaths = ["tests"]
asyncio_mode = "auto"

[tool.ruff]
line-length = 100
target-version = "py311"
'@

# ---------------------------------------------------------------------------
# requirements.txt
# ---------------------------------------------------------------------------
Write-ProjectFile "requirements.txt" @'
flask>=3.0.3
playwright>=1.47.0
pydantic>=2.9.2
python-dotenv>=1.0.1
openai>=1.51.0
rich>=13.9.2
pytest>=8.3.3
pytest-asyncio>=0.24.0
httpx>=0.27.2
'@

Write-Host ""
Write-Host "Writing artifact + safety + evidence..." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# src/artifact/schema.py
# ---------------------------------------------------------------------------
Write-ProjectFile "src\artifact\schema.py" @'
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
'@

# ---------------------------------------------------------------------------
# src/artifact/store.py
# ---------------------------------------------------------------------------
Write-ProjectFile "src\artifact\store.py" @'
"""Persistence for capability artifacts: file-based, versioned, reviewable."""

from __future__ import annotations

import json
from pathlib import Path
from typing import List

from .schema import CapabilityArtifact


class ArtifactStore:
    """File-backed store. Each artifact is a JSON file named <id>.json."""

    def __init__(self, root: Path | str = "artifacts"):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)

    def _path(self, artifact_id: str) -> Path:
        return self.root / f"{artifact_id}.json"

    def save(self, artifact: CapabilityArtifact) -> Path:
        path = self._path(artifact.id)
        path.write_text(
            json.dumps(artifact.model_dump(mode="json"), indent=2, ensure_ascii=False),
            encoding="utf-8",
        )
        return path

    def load(self, artifact_id: str) -> CapabilityArtifact:
        path = self._path(artifact_id)
        if not path.exists():
            raise FileNotFoundError(f"No artifact at {path}")
        data = json.loads(path.read_text(encoding="utf-8"))
        return CapabilityArtifact.model_validate(data)

    def list_ids(self) -> List[str]:
        return sorted(p.stem for p in self.root.glob("*.json"))

    def exists(self, artifact_id: str) -> bool:
        return self._path(artifact_id).exists()
'@

# ---------------------------------------------------------------------------
# src/safety/allowlist.py
# ---------------------------------------------------------------------------
Write-ProjectFile "src\safety\allowlist.py" @'
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
'@

# ---------------------------------------------------------------------------
# src/safety/redaction.py
# ---------------------------------------------------------------------------
Write-ProjectFile "src\safety\redaction.py" @'
"""PII / secret redaction for logs, evidence, and artifacts."""

from __future__ import annotations

import re
from typing import Any, Dict, Iterable

_PATTERNS = [
    (re.compile(r"\bsk-[A-Za-z0-9]{16,}\b"), "[REDACTED_API_KEY]"),
    (re.compile(r"\b\d{3}-\d{2}-\d{4}\b"), "[REDACTED_SSN]"),
    (re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.-]+\b"), "[REDACTED_EMAIL]"),
    (re.compile(r"\b\d{9,16}\b"), "[REDACTED_NUMBER]"),
    (re.compile(r"\$\s?\d{1,3}(?:,\d{3})*(?:\.\d{2})?"), "[REDACTED_AMOUNT]"),
]


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
        return {k: redact_value(v) for k, v in value.items()}
    if isinstance(value, list):
        return [redact_value(v) for v in value]
    return value


def redact_mapping(d: Dict[str, Any], skip_keys: Iterable[str] = ()) -> Dict[str, Any]:
    skip = set(skip_keys)
    return {k: (v if k in skip else redact_value(v)) for k, v in d.items()}
'@

# ---------------------------------------------------------------------------
# src/evidence/logger.py
# ---------------------------------------------------------------------------
Write-ProjectFile "src\evidence\logger.py" @'
"""Structured JSON logger + evidence writer."""

from __future__ import annotations

import json
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional

from ..safety.redaction import redact_value


class RunLogger:
    def __init__(self, root: Path | str = "evidence", run_id: Optional[str] = None,
                 kind: str = "run") -> None:
        self.root = Path(root)
        self.run_id = run_id or f"{kind}-{datetime.now().strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:6]}"
        self.dir = self.root / self.run_id
        self.dir.mkdir(parents=True, exist_ok=True)
        (self.dir / "screenshots").mkdir(exist_ok=True)
        (self.dir / "dom").mkdir(exist_ok=True)
        self._log_path = self.dir / "run.jsonl"
        self._t0 = time.time()

    def log(self, event: str, **fields: Any) -> None:
        record = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "t_rel": round(time.time() - self._t0, 3),
            "run_id": self.run_id,
            "event": event,
            **{k: redact_value(v) for k, v in fields.items()},
        }
        with self._log_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")

    def screenshot_path(self, name: str) -> Path:
        safe = "".join(c if c.isalnum() or c in "-_." else "_" for c in name)
        return self.dir / "screenshots" / f"{safe}.png"

    def dom_path(self, name: str) -> Path:
        safe = "".join(c if c.isalnum() or c in "-_." else "_" for c in name)
        return self.dir / "dom" / f"{safe}.html"

    def write_result(self, result: Dict[str, Any]) -> Path:
        path = self.dir / "result.json"
        path.write_text(
            json.dumps(redact_value(result), indent=2, ensure_ascii=False),
            encoding="utf-8",
        )
        return path

    @property
    def path(self) -> Path:
        return self.dir
'@

Write-Host ""
Write-Host "Writing agent layer..." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# src/agent/llm_client.py
# ---------------------------------------------------------------------------
Write-ProjectFile "src\agent\llm_client.py" @'
"""Thin wrapper around DeepSeek's OpenAI-compatible chat completions API."""

from __future__ import annotations

import os
from typing import Any, Dict, List, Optional

from openai import OpenAI


class LLMClient:
    def __init__(
        self,
        api_key: Optional[str] = None,
        base_url: Optional[str] = None,
        model: Optional[str] = None,
    ) -> None:
        self.api_key = api_key or os.environ.get("DEEPSEEK_API_KEY")
        if not self.api_key:
            raise RuntimeError("DEEPSEEK_API_KEY is not set")
        self.base_url = base_url or os.environ.get(
            "DEEPSEEK_BASE_URL", "https://api.deepseek.com/v1"
        )
        self.model = model or os.environ.get("DEEPSEEK_MODEL", "deepseek-chat")
        self.client = OpenAI(api_key=self.api_key, base_url=self.base_url)

    def chat(
        self,
        messages: List[Dict[str, Any]],
        tools: Optional[List[Dict[str, Any]]] = None,
        tool_choice: str = "auto",
        temperature: float = 0.1,
        max_tokens: int = 2048,
    ) -> Any:
        kwargs: Dict[str, Any] = dict(
            model=self.model,
            messages=messages,
            temperature=temperature,
            max_tokens=max_tokens,
        )
        if tools:
            kwargs["tools"] = tools
            kwargs["tool_choice"] = tool_choice
        return self.client.chat.completions.create(**kwargs)
'@

# ---------------------------------------------------------------------------
# src/agent/prompts.py
# ---------------------------------------------------------------------------
Write-ProjectFile "src\agent\prompts.py" @'
"""System prompt and tool schema for the discovery agent."""

from __future__ import annotations

from typing import Any, Dict, List

SYSTEM_PROMPT = """You are a computer-use agent that operates a legacy bank back-office \
web application to accomplish a user goal.

You interact with the application one step at a time, using the provided tools. \
After each action you will receive an updated observation of the page.

Operating principles:
  1. Prefer semantic locators: role + accessible name, then visible label text, \
then placeholder, then CSS, then XPath. Only use coordinates as a last resort.
  2. After any action that changes page state, verify you actually reached the \
expected state before proceeding.
  3. When the goal is complete, call `finish` with a clear checkpoint description \
and any outputs you read (as name -> value pairs).
  4. If you hit a "record not found" or similar business condition that is a \
legitimate outcome (not a crash), call `finish` with a `business_outcome` field \
set to a short code like `NOT_FOUND`.
  5. Do not invent data. If a value is not visible on screen, do not return it.
  6. Keep actions minimal. One click, one fill, one navigate per step.

When you receive login credentials in the context, use them when a login form is \
present.
"""


TOOLS: List[Dict[str, Any]] = [
    {
        "type": "function",
        "function": {
            "name": "navigate",
            "description": "Navigate to a URL.",
            "parameters": {
                "type": "object",
                "properties": {
                    "url": {"type": "string", "description": "Absolute URL to load."}
                },
                "required": ["url"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "click",
            "description": "Click an element on the page.",
            "parameters": {
                "type": "object",
                "properties": {
                    "locator_strategy": {
                        "type": "string",
                        "enum": ["role", "label", "text", "placeholder", "css", "xpath", "coordinates"],
                    },
                    "locator_value": {"type": "string"},
                    "locator_name": {
                        "type": "string",
                        "description": "Accessible name (only for strategy=role).",
                    },
                    "frame_selector": {
                        "type": "string",
                        "description": "CSS selector of the iframe containing the element, if any.",
                    },
                    "description": {"type": "string"},
                },
                "required": ["locator_strategy", "locator_value", "description"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "fill",
            "description": "Type text into an input field.",
            "parameters": {
                "type": "object",
                "properties": {
                    "locator_strategy": {"type": "string"},
                    "locator_value": {"type": "string"},
                    "locator_name": {"type": "string"},
                    "frame_selector": {"type": "string"},
                    "text": {"type": "string"},
                    "description": {"type": "string"},
                },
                "required": ["locator_strategy", "locator_value", "text", "description"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "select_option",
            "description": "Select an option from a <select> dropdown by visible label.",
            "parameters": {
                "type": "object",
                "properties": {
                    "locator_strategy": {"type": "string"},
                    "locator_value": {"type": "string"},
                    "locator_name": {"type": "string"},
                    "frame_selector": {"type": "string"},
                    "option_label": {"type": "string"},
                    "description": {"type": "string"},
                },
                "required": ["locator_strategy", "locator_value", "option_label", "description"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read",
            "description": "Read the visible text of an element into a named output.",
            "parameters": {
                "type": "object",
                "properties": {
                    "locator_strategy": {"type": "string"},
                    "locator_value": {"type": "string"},
                    "locator_name": {"type": "string"},
                    "frame_selector": {"type": "string"},
                    "output_name": {"type": "string"},
                    "description": {"type": "string"},
                },
                "required": ["locator_strategy", "locator_value", "output_name", "description"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "wait_for",
            "description": "Wait until an element is visible.",
            "parameters": {
                "type": "object",
                "properties": {
                    "locator_strategy": {"type": "string"},
                    "locator_value": {"type": "string"},
                    "locator_name": {"type": "string"},
                    "frame_selector": {"type": "string"},
                    "timeout_ms": {"type": "integer", "default": 8000},
                    "description": {"type": "string"},
                },
                "required": ["locator_strategy", "locator_value", "description"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "finish",
            "description": "Signal that the goal is complete (or a business outcome was reached).",
            "parameters": {
                "type": "object",
                "properties": {
                    "checkpoint_description": {
                        "type": "string",
                        "description": "Human-readable description of the final state you reached.",
                    },
                    "outputs": {
                        "type": "object",
                        "description": "Map of output_name -> value extracted from the page.",
                    },
                    "business_outcome": {
                        "type": "string",
                        "description": "Optional short code like NOT_FOUND, PERMISSION_DENIED.",
                    },
                },
                "required": ["checkpoint_description"],
            },
        },
    },
]


def build_system_message(credentials_hint: str = "") -> Dict[str, Any]:
    content = SYSTEM_PROMPT
    if credentials_hint:
        content += f"\n\nLogin credentials: {credentials_hint}"
    return {"role": "system", "content": content}
'@

# ---------------------------------------------------------------------------
# src/agent/observer.py
# ---------------------------------------------------------------------------
Write-ProjectFile "src\agent\observer.py" @'
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
'@

Write-Host ""
Write-Host "Writing actor + loop + CLI..." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# src/agent/actor.py
# ---------------------------------------------------------------------------
Write-ProjectFile "src\agent\actor.py" @'
"""Execute tool calls against the live Playwright surface."""

from __future__ import annotations

import base64
from typing import Any, Dict, Optional, Tuple

from playwright.sync_api import Frame, Page
from playwright.sync_api import Error as PlaywrightError


class ActionError(Exception):
    def __init__(self, code: str, message: str, kind: str = "hard") -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.kind = kind


def _resolve_target(page: Page, frame_selector: Optional[str]) -> Page | Frame:
    if not frame_selector:
        return page
    frame = page.frame_locator(frame_selector)
    # frame_locator is not a Page/Frame; wrap usage in locator helpers below
    return frame  # type: ignore[return-value]


def _locator(page: Page, args: Dict[str, Any]):
    strategy = args.get("locator_strategy")
    value = args.get("locator_value", "")
    name = args.get("locator_name")
    frame_selector = args.get("frame_selector")
    scope: Any = page
    if frame_selector:
        scope = page.frame_locator(frame_selector)

    if strategy == "role":
        # Playwright expects a role string; we approximate with get_by_role
        return scope.get_by_role(value, name=name)  # type: ignore[arg-type]
    if strategy == "label":
        return scope.get_by_label(value)
    if strategy == "text":
        return scope.get_by_text(value)
    if strategy == "placeholder":
        return scope.get_by_placeholder(value)
    if strategy == "css":
        return scope.locator(value)
    if strategy == "xpath":
        return scope.locator(f"xpath={value}")
    if strategy == "coordinates":
        raise ActionError("COORDINATES_UNSUPPORTED", "coordinates locator not implemented in v1")
    raise ActionError("UNKNOWN_STRATEGY", f"Unknown locator strategy: {strategy}")


def _step_to_locator_args(step: Dict[str, Any]) -> Dict[str, Any]:
    return step


def execute(page: Page, action: str, args: Dict[str, Any]) -> Tuple[Dict[str, Any], Optional[Dict[str, Any]]]:
    """Run one tool call. Returns (result_dict, read_output_or_none)."""
    if action == "navigate":
        url = args["url"]
        page.goto(url, wait_until="domcontentloaded")
        return {"ok": True, "url": page.url}, None

    if action == "click":
        loc = _locator(page, args)
        loc.first.click(timeout=8000)
        page.wait_for_load_state("networkidle", timeout=8000)
        return {"ok": True}, None

    if action == "fill":
        loc = _locator(page, args)
        loc.first.fill(args["text"], timeout=8000)
        return {"ok": True}, None

    if action == "select_option":
        loc = _locator(page, args)
        loc.first.select_option(label=args["option_label"], timeout=8000)
        return {"ok": True}, None

    if action == "read":
        loc = _locator(page, args)
        text = loc.first.inner_text(timeout=8000)
        return {"ok": True, "text": text}, {"output_name": args["output_name"], "value": text}

    if action == "wait_for":
        timeout = int(args.get("timeout_ms", 8000))
        loc = _locator(page, args)
        loc.first.wait_for(state="visible", timeout=timeout)
        return {"ok": True}, None

    raise ActionError("UNKNOWN_ACTION", f"Unknown action: {action}")
'@

# ---------------------------------------------------------------------------
# src/agent/loop.py
# ---------------------------------------------------------------------------
Write-ProjectFile "src\agent\loop.py" @'
"""Discovery loop: LLM-driven observe -> decide -> act until goal is met.

Produces a CapabilityArtifact from the recorded trace. The artifact is
deliberately decoupled from the raw LLM transcript: it captures the steps,
locators, parameters, outputs, and a checkpoint, in a form a replay engine
can execute without any model in the loop.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

from playwright.sync_api import Page

from ..artifact.schema import (
    ActionType,
    CapabilityArtifact,
    Checkpoint,
    Locator,
    LocatorStrategy,
    Output,
    Parameter,
    RiskLevel,
    SafetyPolicy,
    Step,
    TargetInfo,
)
from ..evidence.logger import RunLogger
from ..safety.allowlist import Allowlist, SafetyViolation
from . import actor, observer, prompts
from .llm_client import LLMClient


@dataclass
class DiscoveryResult:
    artifact: Optional[CapabilityArtifact]
    business_outcome: Optional[str]
    steps_taken: int
    finish_reason: str
    outputs: Dict[str, Any] = field(default_factory=dict)


def _locator_from_args(args: Dict[str, Any]) -> Locator:
    strategy = args["locator_strategy"]
    return Locator(
        strategy=LocatorStrategy(strategy),
        value=args["locator_value"],
        name=args.get("locator_name"),
        frame_path=[args["frame_selector"]] if args.get("frame_selector") else None,
    )


def _action_from_tool(tool_name: str) -> ActionType:
    return {
        "navigate": ActionType.NAVIGATE,
        "click": ActionType.CLICK,
        "fill": ActionType.FILL,
        "select_option": ActionType.SELECT,
        "read": ActionType.READ,
        "wait_for": ActionType.WAIT_FOR,
        "finish": ActionType.SCREENSHOT,  # unused; finish terminates
    }[tool_name]


def run_discovery(
    page: Page,
    goal: str,
    entry_url: str,
    artifact_id: str,
    llm: LLMClient,
    allowlist: Allowlist,
    logger: RunLogger,
    credentials_hint: str = "",
    max_steps: int = 25,
    target_app_id: str = "mock-corebank",
) -> DiscoveryResult:
    logger.log("discovery.start", goal=goal, entry_url=entry_url, artifact_id=artifact_id)

    if not page.url or page.url == "about:blank":
        page.goto(entry_url, wait_until="domcontentloaded")

    messages: List[Dict[str, Any]] = [
        prompts.build_system_message(credentials_hint),
        {"role": "user", "content": f"Goal: {goal}\n\nCurrent page observation:\n{observer.observe(page)}"},
    ]

    steps: List[Step] = []
    outputs_spec: List[Output] = []
    read_values: Dict[str, Any] = {}
    step_counter = 0

    for iteration in range(max_steps):
        response = llm.chat(messages=messages, tools=prompts.TOOLS, tool_choice="auto")
        choice = response.choices[0].message
        messages.append({
            "role": "assistant",
            "content": choice.content or "",
            "tool_calls": [
                {
                    "id": tc.id,
                    "type": "function",
                    "function": {"name": tc.function.name, "arguments": tc.function.arguments},
                }
                for tc in (choice.tool_calls or [])
            ] or None,
        })

        if not choice.tool_calls:
            logger.log("discovery.no_tool_call", content=choice.content)
            messages.append({"role": "user", "content": "Please call a tool."})
            continue

        for tc in choice.tool_calls:
            name = tc.function.name
            try:
                args = json.loads(tc.function.arguments or "{}")
            except json.JSONDecodeError:
                args = {}

            logger.log("discovery.tool_call", tool=name, args=args)

            if name == "finish":
                checkpoint_desc = args.get("checkpoint_description", "Goal complete")
                business_outcome = args.get("business_outcome")
                final_outputs = args.get("outputs") or {}
                # Merge any values captured via read()
                for k, v in read_values.items():
                    final_outputs.setdefault(k, v)

                # Build a minimal checkpoint (use last observed landmark)
                checkpoint = _build_checkpoint(page, checkpoint_desc)
                artifact = CapabilityArtifact(
                    id=artifact_id,
                    name=artifact_id.replace("_", " ").title(),
                    description=goal,
                    llm_model=llm.model,
                    target=TargetInfo(
                        app_id=target_app_id,
                        entry_url=entry_url,
                        tenant_id=os.environ.get("TENANT_ID", "default"),
                    ),
                    parameters=_infer_parameters(goal),
                    outputs=outputs_spec,
                    steps=steps,
                    checkpoint=checkpoint,
                    safety=SafetyPolicy(
                        allowed_domains=allowlist.policy.allowed_domains,
                        allowed_actions=list(ActionType),
                        risky_requires_confirmation=True,
                        irreversible_blocked=True,
                    ),
                    metadata={
                        "goal": goal,
                        "business_outcome": business_outcome,
                        "discovery_steps": len(steps),
                    },
                )
                logger.log(
                    "discovery.finish",
                    business_outcome=business_outcome,
                    outputs=final_outputs,
                    step_count=len(steps),
                )
                return DiscoveryResult(
                    artifact=artifact,
                    business_outcome=business_outcome,
                    steps_taken=len(steps),
                    finish_reason="finish_tool",
                    outputs=final_outputs,
                )

            # Enforce safety before executing
            action_type = _action_from_tool(name)
            risk = RiskLevel.SAFE
            if name in ("click",) and "submit" in json.dumps(args).lower():
                risk = RiskLevel.RISKY
            try:
                allowlist.enforce_action(action_type, risk)
            except SafetyViolation as exc:
                logger.log("safety.violation", tool=name, reason=str(exc))
                messages.append({"role": "tool", "tool_call_id": tc.id, "content": json.dumps({"error": str(exc)})})
                continue

            # Execute
            try:
                result, read_out = actor.execute(page, name, args)
            except Exception as exc:
                logger.log("discovery.action_error", tool=name, error=str(exc))
                result, read_out = {"ok": False, "error": str(exc)}, None

            step_counter += 1
            steps.append(_record_step(step_counter, name, args, risk))
            if read_out:
                read_values[read_out["output_name"]] = read_out["value"]
                outputs_spec.append(Output(
                    name=read_out["output_name"],
                    type="string",
                    description=f"Read from step {step_counter}",
                    from_step=f"s{step_counter}",
                ))

            # Take a screenshot as evidence
            shot = logger.screenshot_path(f"step_{step_counter:02d}_{name}")
            try:
                page.screenshot(path=str(shot), full_page=False)
            except Exception:
                pass

            messages.append({
                "role": "tool",
                "tool_call_id": tc.id,
                "content": json.dumps(result, ensure_ascii=False)[:2000],
            })

            # Append fresh observation
            try:
                obs = observer.observe(page)
            except Exception as exc:
                obs = f"[observe error: {exc}]"
            messages.append({"role": "user", "content": f"Current page observation:\n{obs}"})

    logger.log("discovery.max_steps")
    return DiscoveryResult(artifact=None, business_outcome=None, steps_taken=len(steps),
                           finish_reason="max_steps")


def _record_step(counter: int, tool_name: str, args: Dict[str, Any], risk: RiskLevel) -> Step:
    action = _action_from_tool(tool_name)
    locator = None
    value = None
    if tool_name == "navigate":
        value = args.get("url")
    elif tool_name in ("click", "fill", "select_option", "read", "wait_for"):
        locator = _locator_from_args(args)
        if tool_name == "fill":
            value = args.get("text")
        elif tool_name == "select_option":
            value = args.get("option_label")
    return Step(
        id=f"s{counter}",
        action=action,
        description=args.get("description", tool_name),
        locator=locator,
        value=value,
        risk=risk,
    )


def _build_checkpoint(page: Page, description: str) -> Checkpoint:
    # Heuristic: assert the main frame title is non-empty as the checkpoint.
    try:
        title = page.title() or "page"
    except Exception:
        title = "page"
    return Checkpoint(
        description=description,
        locator=Locator(strategy=LocatorStrategy.CSS, value="body"),
        expected_text=None,
    )


def _infer_parameters(goal: str) -> List[Parameter]:
    # Simple heuristic: if the goal contains a 4+ digit number, treat it as member_id.
    import re

    params: List[Parameter] = []
    m = re.search(r"\b(\d{4,})\b", goal)
    if m:
        params.append(Parameter(
            name="member_id",
            type="string",
            required=True,
            description="Member ID referenced in the goal",
            example=m.group(1),
        ))
    return params
'@

# ---------------------------------------------------------------------------
# cli/discover.py
# ---------------------------------------------------------------------------
Write-ProjectFile "cli\discover.py" @'
"""CLI: run the discovery loop against the target app and save the artifact."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from dotenv import load_dotenv
from playwright.sync_api import sync_playwright

# Ensure project root on sys.path when run as a module
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from src.agent.llm_client import LLMClient
from src.agent.loop import run_discovery
from src.artifact.schema import ActionType, SafetyPolicy
from src.artifact.store import ArtifactStore
from src.evidence.logger import RunLogger
from src.safety.allowlist import Allowlist


def main() -> int:
    load_dotenv()
    parser = argparse.ArgumentParser()
    parser.add_argument("--goal", required=True)
    parser.add_argument("--entry-url", default=os.environ.get("TARGET_APP_BASE_URL", "http://127.0.0.1:5000"))
    parser.add_argument("--artifact-id", required=True)
    parser.add_argument("--max-steps", type=int, default=int(os.environ.get("MAX_STEPS", "25")))
    parser.add_argument("--headed", action="store_true", default=True)
    parser.add_argument("--headless", action="store_true")
    args = parser.parse_args()

    headless = args.headless and not args.headed

    allowed = os.environ.get("ALLOWED_DOMAINS", "127.0.0.1,localhost").split(",")
    policy = SafetyPolicy(
        allowed_domains=[d.strip() for d in allowed],
        allowed_actions=list(ActionType),
    )
    allowlist = Allowlist(policy=policy)

    logger = RunLogger(kind="discovery")
    llm = LLMClient()
    store = ArtifactStore(os.environ.get("ARTIFACTS_DIR", "artifacts"))

    cred_hint = ""
    user = os.environ.get("TARGET_USERNAME")
    pw = os.environ.get("TARGET_PASSWORD")
    if user and pw:
        cred_hint = f"username={user} password={pw}"

    with sync_playwright() as pw_ctx:
        browser = pw_ctx.chromium.launch(headless=headless)
        context = browser.new_context(viewport={"width": 1280, "height": 800})
        page = context.new_page()
        page.set_default_timeout(10_000)

        try:
            result = run_discovery(
                page=page,
                goal=args.goal,
                entry_url=args.entry_url,
                artifact_id=args.artifact_id,
                llm=llm,
                allowlist=allowlist,
                logger=logger,
                credentials_hint=cred_hint,
                max_steps=args.max_steps,
            )
        finally:
            browser.close()

    summary = {
        "finish_reason": result.finish_reason,
        "steps_taken": result.steps_taken,
        "business_outcome": result.business_outcome,
        "outputs": result.outputs,
        "artifact_saved": False,
    }

    if result.artifact is not None:
        path = store.save(result.artifact)
        summary["artifact_saved"] = True
        summary["artifact_path"] = str(path)
        print(f"\nArtifact saved to: {path}")
    else:
        print("\nNo artifact produced.")

    logger.write_result(summary)
    print(f"Evidence: {logger.path}")
    print(f"Finish reason: {result.finish_reason}")
    print(f"Business outcome: {result.business_outcome}")
    print(f"Outputs: {result.outputs}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
'@

Write-Host ""
Write-Host "Batch 2 files written." -ForegroundColor Green
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. python -c `"from src.artifact.schema import CapabilityArtifact; print('schema OK')`""
Write-Host "  2. python -c `"from src.agent.loop import run_discovery; print('loop OK')`""
Write-Host "  3. python -c `"from cli.discover import main; print('cli OK')`""