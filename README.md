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
- Runtime errors are classified as business outcomes, recoverable conditions,
  or hard failures.
- A human-in-the-loop handoff pauses automation and lets an operator take
  control of the same live session.
- An allowlist + redaction layer enforces safety on regulated data.

## Setup

Requires Python 3.11+ on Windows, macOS, or Linux.

    cd C:\Projects\computer-use-automation
    python -m venv .venv
    .\.venv\Scripts\Activate.ps1
    python -m pip install -r requirements.txt
    python -m playwright install chromium

Copy .env.example to .env and fill in your API key if you intend to run the
discovery step:

    DEEPSEEK_API_KEY=sk-...

Replay does not need an API key.

## Demo path (offline, no API key)

Start the mock legacy bank app in a terminal:

    python -m cli.serve_app

Leave that terminal running. In a second terminal, copy the fixture artifact
once:

    Copy-Item tests\fixtures\lookup_member_balance.json artifacts\

Then run the replay:

    python -m cli.replay --artifact-id lookup_member_balance --param base_url=http://127.0.0.1:5000 --param username=teller1 --param password=password123 --param member_id=12345

Expected: success with savings_balance = $12345.67, evidence under evidence/.

Try the business-outcome path (legitimate "no such member" result):

    python -m cli.replay --artifact-id lookup_member_balance --param base_url=http://127.0.0.1:5000 --param username=teller1 --param password=password123 --param member_id=99999

Expected: business with code NOT_FOUND.

Try the permission-denied path:

    python -m cli.replay --artifact-id lookup_member_balance --param base_url=http://127.0.0.1:5000 --param username=teller1 --param password=password123 --param member_id=00000

Expected: business with code PERMISSION_DENIED.

## Demo path (discovery, requires API key)

In one terminal:

    python -m cli.serve_app

In another:

    python -m cli.discover --artifact-id lookup_member_balance --goal "Look up member 12345 and read their savings balance" --entry-url http://127.0.0.1:5000

The discovery run will drive a headed Chromium, sign in with
TARGET_USERNAME/TARGET_PASSWORD from .env, and emit
artifacts/lookup_member_balance.json, with evidence under evidence/.

Then replay the freshly recorded artifact:

    python -m cli.replay --artifact-id lookup_member_balance --param member_id=12345

## Running tests

    python -m pytest -v

Tests spin up the mock app in a background thread on a dynamic port and run a
headless Chromium against it. No external services, no API key needed.

## Repository layout

    src/
      target_app/       Mock legacy bank app (Flask, tables, iframe, no test IDs)
      agent/            LLM-driven discovery loop
      artifact/         Capability schema (Pydantic) + file store
      replay/           Deterministic replay engine, locator, error taxonomy
      safety/           Allowlist + PII/secret redaction
      handoff/          CLI human-in-the-loop
      evidence/         Structured JSON logger + screenshots + DOM snapshots
    cli/
      serve_app.py      Run the mock bank app
      discover.py       Run discovery
      replay.py         Run replay
    tests/              Pytest suite
    artifacts/          Saved capability artifacts
    evidence/           Run evidence

## Safety at a glance

- Domain allowlist (default 127.0.0.1, localhost).
- Action allowlist (navigate, click, fill, select, read, ...).
- Risky actions require explicit confirmation.
- Irreversible actions are blocked by default.
- Secrets and PII (API keys, SSNs, 9-16 digit numbers, email, currency
  amounts) are redacted in logs and evidence.
- Artifact schema refuses to embed values that look like API keys.

## Design write-up

See REPORT.md for the seven-section design document.