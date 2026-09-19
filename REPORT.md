# Design Write-Up

## Architecture

The system has five boundaries:

1. Target surface - the live UI being automated. In this repo, a Flask app
   that mimics a 2000s-era teller console: server-rendered tables, an iframe
   shell, generated class names, and no test IDs. Stand-in for legacy banking
   surfaces.

2. Discovery agent (src/agent/) - an LLM-driven observe, decide, act loop. The
   agent receives a compact text observation of the page and issues typed tool
   calls (navigate, click, fill, select_option, read, wait_for, finish). All
   actions are checked against the safety allowlist before execution.

3. Artifact store (src/artifact/) - after a successful run, the trace is
   distilled into a CapabilityArtifact (Pydantic model, JSON on disk). The
   artifact is decoupled from the raw LLM transcript.

4. Replay engine (src/replay/) - the production path. Reads an artifact,
   substitutes parameters, executes each step with layered locators, verifies
   checkpoints, extracts outputs, and classifies the result as success,
   business outcome, or failure. No LLM in the loop.

5. Evidence and handoff (src/evidence/, src/handoff/) - every run gets its own
   directory with structured JSONL log, screenshots, and DOM snapshots. On a
   stuck state, a human-in-the-loop handoff pauses automation and lets an
   operator take control of the same live session.

Key decision: text-first observation, semantic locators, layered fallbacks.
The agent observes a text summary of the page rather than pixels. This works
with any text-capable model and produces artifacts that are easy to review.
Trade-off: loses pixel fidelity. Alternative (screenshot + coordinates)
handles more surfaces but is brittle and expensive. We chose text-first
because the target environment has stable UIs; the hard part is runtime
errors, not visual drift.

## Artifact schema

See src/artifact/schema.py. Shape:

    CapabilityArtifact
      schema_version, id, name, version, description, created_at, llm_model
      target: TargetInfo { app_id, entry_url, surface_type, tenant_id, ... }
      parameters: [Parameter]
      outputs:    [Output]
      steps:      [Step]
      checkpoint: Checkpoint
      safety:     SafetyPolicy

Why this shape:

- Separate parameters and outputs sections. A calling agent needs a contract:
  what do I give it, what do I get back, in what type? Embedding those in
  steps would force the caller to reverse-engineer them. Types are a small
  closed set (string, integer, float, boolean) to keep replay simple.

- Locator with explicit fallbacks and frame_path. Legacy surfaces have no
  test IDs and often live inside iframes. A single CSS selector is not a
  locator strategy; a chain is. The schema makes the chain explicit.

- Step.risk per action. Risk is a property of the action, not the goal. A
  click that submits a form is risky; a click that opens a tab is not.

- ErrorHandler per step. Recoverable conditions like a dismissible
  interstitial are declared at the step they can occur, not globally.

- SafetyPolicy embedded per artifact. An artifact carries its own allowlist.
  No global mutable policy.

- version and schema_version. Artifacts evolve. The version fields let a
  replay engine refuse an artifact it cannot understand.

## Determinism & error handling

Determinism comes from four sources:

1. No LLM. The replay engine never calls a model.
2. Layered locators. The engine tries the primary locator, then each declared
   fallback. A locator resolved through a different strategy is graceful
   degradation, not a failure.
3. Explicit checkpoints. Every replay verifies a checkpoint on success.
4. Templated values. Step.value supports {{name}} substitution.

Error taxonomy:

- Business: "No such member", "permission denied", "validation error".
  Return as a structured outcome. Do not retry, do not crash.
- Recoverable: "session expired", transient slow load, dismissible
  interstitial. Attempt recovery, bounded by max_retries.
- Hard: selector not found, action failed, checkpoint failed. Stop; capture
  screenshot + DOM snapshot; return a debuggable error.

Detection happens both before and after each step. Conflating "no such
member" (a legitimate answer) with "replay failed" (a bug) is the classic
mistake in this space.

## Heterogeneity & multi-tenant

We implemented against one surface (legacy web), but the design does not
assume it.

- Surface abstraction. TargetInfo.adapter names the adapter
  (playwright-web in v1). A desktop adapter would speak to OS APIs (UIA on
  Windows, AX on macOS) but expose the same Locator interface to the
  artifact. The seam is: artifacts say what to target; adapters know how.
  LocatorStrategy already includes COORDINATES as the common denominator
  between web and desktop.

- Multi-tenant reuse. Modeled in TargetInfo by carrying tenant_id and
  app_version. Intended pattern:
    1. Record a base artifact against a canonical tenant.
    2. Record overrides (locator replacements, parameter defaults) per tenant
       or per app version.
    3. Replay applies overrides on top of the base artifact.
  Drift is detected at replay time: if the primary locator fails and a
  declared fallback succeeds, log it as locator_fallback_used. Aggregate per
  (tenant, app_version) for a drift dashboard.

- What we did not build. Tenant override application, drift aggregation, and
  a desktop adapter are all design-only. Clean seams, deliberately not
  implemented, called out in Cuts.

## Escalation & handoff

Stuck states are detected in two places:

1. During discovery: max_steps hit, timeout, or repeated failures.
2. During replay: a hard failure, an unhandled recoverable after retries, or
   a risky/irreversible step requiring approval.

Handoff (src/handoff/cli.py) works as follows:

- Automation runs in a headed browser. Single live BrowserContext.
- On a stuck state, the engine calls handoff.request(...) with a reason,
  step id, and free-form context.
- CLI prints the request, takes a pre-handoff screenshot, and blocks on
  stdin. The operator drives the same browser window directly.
- On resume, the operator may attach notes; CLI takes a post-handoff
  screenshot and DOM snapshot, records both, and returns control.
- A control token (control=automation vs control=operator) is written to the
  structured log at every transition.

The seam is real: pause, transfer, resume on the same session. The operator
UI is intentionally a CLI.

## Safety

Three layers:

1. Allowlist (src/safety/allowlist.py). Per-artifact SafetyPolicy with
   allowed_domains and allowed_actions. Enforced before every action and
   before every navigation. Domain matching is suffix-aware but the default
   policy is tight: 127.0.0.1, localhost.

2. Risk classification. RiskLevel.SAFE | RISKY | IRREVERSIBLE. Replay
   requires interactive confirmation for RISKY steps and blocks IRREVERSIBLE
   steps outright. The discovery agent applies the same policy.

3. Redaction (src/safety/redaction.py). Regex-based redaction for API keys,
   SSNs, email addresses, 9-16 digit numbers, and currency amounts. Applied
   to every field written to the structured log and to the evidence result
   file. Declared outputs are returned to the caller in the result but
   redacted in logs and evidence.

Limits. Not a formal data-flow policy engine. A motivated caller could
exfiltrate via encoding tricks. Redaction is defense in depth, not the
primary control. The primary control is the allowlist forbidding the network
destinations where exfiltration could happen.

## Cuts

Deliberately not built, and why:

- Full operator console (co-browsing UI). The handoff mechanism and
  control-transfer model are real; the operator surface is a CLI. A
  WebSocket console with live screenshots would be a two-day project and
  would not change the design.
- Desktop surface adapter. TargetInfo.adapter seam is there; only
  playwright-web is implemented.
- Multi-tenant override engine. Modeled in the schema and described above.
  Not implemented.
- Visual locators (image template matching). Useful fallback for surfaces
  where nothing else works. Bounded value for a stable-UI environment.
- Approval workflow (draft to approved). The version field exists. The
  workflow does not.

Next, in priority order:

1. Approval state on artifacts and a review CLI.
2. Assisted fallback: bounded, policy-checked LLM recovery for a single step
   on replay failure, recorded as evidence.
3. Canonicalization of concrete routes/values into parameterized patterns.
4. Multi-run stability: replay N times and emit a flakiness score.