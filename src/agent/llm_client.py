"""Provider-agnostic wrapper around an OpenAI-compatible chat completions API.

Works with any provider that exposes the OpenAI SDK interface:
  - Google Gemini   (https://generativelanguage.googleapis.com/v1beta/openai/)
  - OpenAI          (https://api.openai.com/v1)
  - Groq, Together, OpenRouter, local vLLM, etc.

Configuration is read from environment variables (loaded from .env if present):

  LLM_API_KEY    (required)
  LLM_BASE_URL   (required)
  LLM_MODEL      (required)

Retry policy: transient failures are retried with exponential backoff.
  - 429 rate limit: honor Retry-After / retryDelay hint if present
  - 5xx server errors (500, 502, 503): exponential backoff
  - Non-transient errors (400, 401, 404) raise immediately
"""

from __future__ import annotations

import os
import random
import re
import time
from typing import Any, Dict, List, Optional

from dotenv import load_dotenv
from openai import APIStatusError, InternalServerError, OpenAI, RateLimitError

load_dotenv()


def _require_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(
            f"Missing required environment variable: {name}. "
            f"Set it in .env (see .env.example) before running."
        )
    return value


def _parse_retry_after(error: Exception) -> Optional[float]:
    """Extract retry hint in seconds from a 429 response, if any."""
    try:
        header = error.response.headers.get("retry-after")  # type: ignore[union-attr]
        if header:
            return float(header)
    except Exception:
        pass
    try:
        text = str(error)
        m = re.search(r'"retryDelay"\s*:\s*"(\d+(?:\.\d+)?)s"', text)
        if m:
            return float(m.group(1))
        m = re.search(r'retry in (\d+(?:\.\d+)?)s', text, re.IGNORECASE)
        if m:
            return float(m.group(1))
    except Exception:
        pass
    return None


def _is_retryable(exc: Exception) -> bool:
    if isinstance(exc, RateLimitError):
        return True
    if isinstance(exc, InternalServerError):
        return True
    if isinstance(exc, APIStatusError):
        try:
            return 500 <= int(exc.status_code) < 600
        except Exception:
            return False
    return False


class LLMClient:
    """Thin, provider-agnostic wrapper with transient-error retry."""

    def __init__(
        self,
        api_key: Optional[str] = None,
        base_url: Optional[str] = None,
        model: Optional[str] = None,
        max_retries: int = 8,
    ) -> None:
        self.api_key = api_key or _require_env("LLM_API_KEY")
        self.base_url = base_url or _require_env("LLM_BASE_URL")
        self.model = model or _require_env("LLM_MODEL")
        self.client = OpenAI(api_key=self.api_key, base_url=self.base_url)
        self.max_retries = max_retries

    def chat(
        self,
        messages: List[Dict[str, Any]],
        tools: Optional[List[Dict[str, Any]]] = None,
        tool_choice: str = "auto",
        temperature: float = 0.1,
        max_tokens: int = 1024,
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

        last_error: Optional[Exception] = None
        for attempt in range(self.max_retries):
            try:
                return self.client.chat.completions.create(**kwargs)
            except Exception as exc:
                if not _is_retryable(exc):
                    raise
                last_error = exc
                hinted = _parse_retry_after(exc)
                if hinted is not None:
                    wait = min(hinted + 1.0, 90.0)
                else:
                    wait = min(2 ** attempt, 60) + random.uniform(0, 1)
                status = getattr(exc, "status_code", "?")
                print(
                    f"[llm] transient error {status} "
                    f"(attempt {attempt + 1}/{self.max_retries}); "
                    f"waiting {wait:.1f}s before retry"
                )
                time.sleep(wait)

        raise RuntimeError(
            f"Exhausted {self.max_retries} retries on transient errors. "
            f"Last error: {last_error}"
        )