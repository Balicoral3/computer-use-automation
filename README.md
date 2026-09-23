# Computer-Use Automation System

An LLM-driven computer-use automation system with a deterministic replay path.
Built for back-office applications (legacy bank software, servicing tools,
admin consoles) that expose no API, where the only way in is to drive the UI
the way a human operator would.

The through-line:

> The model discovers. The artifact becomes a reusable capability.
> Deterministic replay is how the AI agent invokes it in production.

- An LLM agent drives a live UI to accomplish a natural-language goal.
- The successful run is recorded as a typed, versioned, reviewable artifact.
- The artifact is replayed deterministically with input parameters, no LLM in
  the loop, and returns typed outputs.
- Runtime errors are classified as **business outcomes**, **recoverable
  conditions**, or **hard failures**.
- A human-in-the-loop handoff pauses automation and lets an operator take
  control of the same live session.
- An allowlist plus redaction layer enforces safety on regulated data.

## Setup

Requires Python 3.11+ on Windows, macOS, or Linux. An OpenAI-compatible LLM
endpoint is needed for the discovery step only; replay does not need one.

    cd C:\Projects\computer-use-automation
    python -m venv .venv
    .\.venv\Scripts\Activate.ps1
    python -m pip install -r requirements.txt
    python -m playwright install chromium

Copy `.env.example` to `.env` and fill in your LLM credentials. Any
OpenAI-compatible provider works. For example:

    # Google Gemini free tier
    LLM_API_KEY=AIza...
    LLM_BASE_URL=https://generativelanguage.googleapis.com/v1beta/openai/
    LLM_MODEL=gemini-3.6-flash

    # Groq free tier
    LLM_API_KEY=gsk_...
    LLM_BASE_URL=https://api.groq.com/openai/v1
    LLM_MODEL=openai/gpt-oss-120b

    # OpenAI
    LLM_API_KEY=sk-...
    LLM_BASE_URL=https://api.openai.com/v1
    LLM_MODEL=gpt-4o-mini

## Demo path (offline, no API key)

Start the mock legacy bank app in a terminal:

    python -m cli.serve_app

Leave that terminal running. In a second terminal, the fixture artifact
lets you exercise the full replay engine without any LLM:

    Copy-Item tests\fixtures\lookup_member_balance.json artifacts\

    # Success case: read the savings balance for member 12345
    python -m cli.replay --artifact-id lookup_member_balance --param base_url=http://127.0.0.1:5000 --param username=teller1 --param password=password123 --param member_id=12345

    # Business outcome: no such member
    python -m cli.replay --artifact-id lookup_member_balance --param base_url=http://127.0.0.1:5000 --param username=teller1 --param password=password123 --param member_id=99999

    # Business outcome: permission denied
    python -m cli.replay --artifact-id lookup_member_balance --param base_url=http://127.0.0.1:5000 --param username=teller1 --param password=password123 --param member_id=00000

Expected outputs:

    success  code=OK              savings_balance=$12345.67
    business code=NOT_FOUND       (member 99999 does not exist)
    business code=PERMISSION_DENIED  (member 00000 is restricted)

The same commands work against the artifact produced by an LLM discovery
run, once it has been reviewed (see below).

## Demo path (discovery, requires API key)

In one terminal:

    python -m cli.serve_app

In another:

    python -m cli.discover --artifact-id lookup_member_balance --goal "Log in with username teller1 and password password123, then look up member 12345 and read their savings balance" --entry-url http://127.0.0.1:5000

The discovery run will:

1. Drive a headed Chromium browser against the app.
2. Observe the page, decide the next action, and act, one step at a time.
3. Sign in, navigate to the member, and read the savings balance.
4. Emit `artifacts/lookup_member_balance.json`.
5. Write evidence to `evidence/discovery-*/`.

Review the produced artifact before deploying it. The LLM's draft may contain
plaintext credentials, hardcoded values, or duplicated steps. A reviewed
example is provided in `examples/lookup_member_balance.json`.

## Running tests

    python -m pytest -v

Tests spin up the mock app in a background thread on a dynamic port and run a
headless Chromium against it. No external services, no API key needed.

## Repository layout

    src/
      target_app/       Mock legacy bank app (Flask, tables, iframe, no test IDs)
      agent/            LLM-driven discovery loop
      artifact/         Capability schema (Pydantic) plus file store
      replay/           Deterministic replay engine, locator, error taxonomy
      safety/           Allowlist plus PII/secret redaction
      handoff/          CLI human-in-the-loop
      evidence/         Structured JSON logger, screenshots, DOM snapshots
    cli/
      serve_app.py      Run the mock bank app
      discover.py       Run discovery
      replay.py         Run replay
    tests/              Pytest suite, includes an offline fixture artifact
    examples/           Reviewed artifacts committed as reference
    artifacts/          Runtime output of discovery (gitignored)

## Safety at a glance

- Domain allowlist (default `127.0.0.1`, `localhost`).
- Action allowlist (`navigate`, `click`, `fill`, `select`, `read`, ...).
- Risky actions require explicit interactive confirmation.
- Irreversible actions are blocked by default.
- Secrets and PII (API keys, SSNs, 9-16 digit account numbers, email, currency
  amounts) are redacted in logs and evidence, via both pattern matching and
  sensitive-key detection.
- The artifact schema refuses to embed values that look like API keys.

## Design write-up

See [REPORT.md](REPORT.md) for the seven-section design document, including
the artifact schema rationale, the three-way error taxonomy, and the
heterogeneity and multi-tenant design.