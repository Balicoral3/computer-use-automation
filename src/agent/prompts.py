"""System prompt and tool schema for the discovery agent.

Design notes:
  - Tool schemas use type arrays that include "null" for every optional
    field. Some providers (notably Groq running openai/gpt-oss-*) validate
    tool-call arguments strictly and reject `field: null` if the schema
    declares only `type: "string"`. Allowing null keeps us compatible with
    both the permissive providers (OpenAI, Anthropic) and the strict ones.
  - Locator strategies are ordered by robustness: role/label/text first
    (semantic, stable), then CSS/XPath, then coordinates as a last resort.
"""

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
  7. Omit optional fields entirely when they are not needed. Do NOT send \
`field: null` or empty strings for fields you are not using.
  8. Only set `frame_selector` when the observation explicitly marks the \
element as inside an <iframe>. Elements on the top-level page must NOT \
have a frame_selector.

When you receive login credentials in the context, use them when a login form is \
present.
"""


# Helper: JSON Schema for "optional string that may be omitted".
# We use a type array so strict validators accept either a string or null.
_OPTIONAL_STRING = {"type": ["string", "null"]}


def _locator_props() -> Dict[str, Any]:
    return {
        "locator_strategy": {
            "type": "string",
            "enum": [
                "role", "label", "text", "placeholder", "name",
                "css", "xpath", "coordinates"
            ],
            "description": "How to find the element.",
        },
        "locator_value": {
            "type": "string",
            "description": "The value for the chosen strategy (role name, label text, CSS selector, etc.).",
        },
        "locator_name": {
            **_OPTIONAL_STRING,
            "description": "Accessible name (only used when strategy=role).",
        },
        "frame_selector": {
            **_OPTIONAL_STRING,
            "description": (
                "CSS selector of the iframe containing the element. "
                "OMIT this field unless the observation explicitly shows the "
                "element is inside an <iframe>. Do NOT send it for elements "
                "on the top-level page."
            ),
        },
    }


TOOLS: List[Dict[str, Any]] = [
    {
        "type": "function",
        "function": {
            "name": "navigate",
            "description": "Navigate to a URL.",
            "parameters": {
                "type": "object",
                "properties": {
                    "url": {"type": "string", "description": "Absolute URL to load."},
                    "description": {"type": "string"},
                },
                "required": ["url", "description"],
                "additionalProperties": False,
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
                    **_locator_props(),
                    "description": {"type": "string"},
                },
                "required": ["locator_strategy", "locator_value", "description"],
                "additionalProperties": False,
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
                    **_locator_props(),
                    "text": {"type": "string"},
                    "description": {"type": "string"},
                },
                "required": ["locator_strategy", "locator_value", "text", "description"],
                "additionalProperties": False,
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
                    **_locator_props(),
                    "option_label": {"type": "string"},
                    "description": {"type": "string"},
                },
                "required": [
                    "locator_strategy", "locator_value", "option_label", "description"
                ],
                "additionalProperties": False,
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
                    **_locator_props(),
                    "output_name": {"type": "string"},
                    "description": {"type": "string"},
                },
                "required": [
                    "locator_strategy", "locator_value", "output_name", "description"
                ],
                "additionalProperties": False,
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
                    **_locator_props(),
                    "timeout_ms": {
                        "type": ["integer", "null"],
                        "description": "Maximum time to wait in milliseconds.",
                    },
                    "description": {"type": "string"},
                },
                "required": ["locator_strategy", "locator_value", "description"],
                "additionalProperties": False,
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
                        "type": ["object", "null"],
                        "description": "Map of output_name -> value extracted from the page.",
                        "additionalProperties": True,
                    },
                    "business_outcome": {
                        **_OPTIONAL_STRING,
                        "description": "Optional short code like NOT_FOUND, PERMISSION_DENIED.",
                    },
                },
                "required": ["checkpoint_description"],
                "additionalProperties": False,
            },
        },
    },
]


def build_system_message(credentials_hint: str = "") -> Dict[str, Any]:
    content = SYSTEM_PROMPT
    if credentials_hint:
        content += f"\n\nLogin credentials: {credentials_hint}"
    return {"role": "system", "content": content}