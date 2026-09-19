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