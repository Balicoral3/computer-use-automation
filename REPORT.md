# Design Write-Up

## Architecture

The system has five boundaries.

**1. Target surface.** The live UI being automated. In this repository, a
Flask app that mimics a 2000s-era teller console: server-rendered tables, an
iframe shell, generated class names, and no test IDs. This is a stand-in for
the legacy banking surfaces the product is aimed at.

**2. Discovery agent** (`src/agent/`). An LLM-driven observe-decide-act loop.
Each turn:
- The agent receives a compact text observation of the current page
  (URL, title, visible text, interactive elements with stable attributes).
- It issues a typed tool call: `navigate`, `click`, `fill`, `select_option`,
  `read`, `wait_for`, or `finish`.
- Every action is checked against the safety allowlist before execution.

The observation is deliberately text-first and token-efficient: the observer
caps at 25 interactive elements, truncates text to 250 chars, and only
includes iframe blocks that actually contain interactive elements. This keeps
the loop under free-tier input token budgets and works with any text-capable
model.

**3. Artifact store** (`src/artifact/`). After a successful run, the trace is
distilled into a `CapabilityArtifact` - a Pydantic model serialized to JSON.
The artifact is deliberately decoupled from the raw LLM transcript: a human
reviewer can read it, and a calling agent can invoke it with typed parameters.

**4. Replay engine** (`src/replay/`). The production execution path. Reads an
artifact, substitutes parameters, executes each step with layered locators,
verifies checkpoints, extracts declared outputs, and classifies the result as
**success**, a **business outcome**, or a **failure**. No LLM in the loop.

**5. Evidence and handoff** (`src/evidence/`, `src/handoff/`). Every run gets
its own directory with a structured JSONL log, per-step screenshots, and DOM
snapshots on failure. When the system is stuck, a human-in-the-loop handoff
pauses automation and lets an operator take control of the same live session.

**Key decision: text-first observation, semantic locators, layered fallbacks.**
We chose text observation over screenshot-plus-coordinates because the target
environment has *stable* UIs; the hard part is not visual drift, it is runtime
exceptional states. Text observation produces reviewable artifacts and works
with cheap or free text-only models. Coordinates remain available in the
`Locator` schema as a last-resort fallback for surfaces where text fails
(canvas, image maps).

**Trade-off.** Text observation loses pixel-level fidelity, and depends on a
parseable DOM or accessibility tree. On a purely visual surface (canvas-based
core banking) we would need the screenshot path. We chose it because the
problem statement emphasizes stable UIs with real runtime errors, which is
exactly where text-first shines.

## Artifact schema

See `src/artifact/schema.py`. Shape:

    CapabilityArtifact
      schema_version, id, name, version, description, created_at, llm_model
      target: TargetInfo { app_id, entry_url, surface_type, tenant_id, ... }
      parameters: [Parameter]
      outputs:    [Output]
      steps:      [Step]
      checkpoint: Checkpoint
      safety:     SafetyPolicy

Why this shape:

- **Separate parameters and outputs sections.** A calling agent needs a
  contract: what do I give it, what do I get back, in what type? Embedding
  those inside steps would force the caller to reverse-engineer them. Types
  are a small closed set (string, integer, float, boolean) to keep replay
  simple and reviewable.

- **`Locator` with explicit `fallbacks` and `frame_path`.** Legacy surfaces
  have no test IDs and often live inside iframes. A single CSS selector is not
  a locator strategy; a chain is. The schema makes the chain explicit and
  reviewable, and `frame_path` lets an artifact target a control inside a
  nested iframe without the calling agent knowing the surface details.

- **`Step.risk` per action.** Risk is a property of the action, not the goal.
  A click that submits a form is risky; a click that opens a tab is not. This
  lets the safety layer treat the two differently without the caller having to
  reason about it.

- **`ErrorHandler` per step.** Recoverable conditions (dismissible
  interstitial) and business outcomes (a "not found" banner) are declared
  *at the step where they can occur*. This is what allows the replay engine to
  distinguish "the flow failed" from "the flow succeeded and the answer is no
  such member".

- **`SafetyPolicy` embedded per artifact.** An artifact carries its own
  allowlist. There is no global mutable policy that a careless call site could
  loosen.

- **`version` and `schema_version`.** Artifacts evolve. The version fields let
  a replay engine refuse an artifact it cannot understand, and give a future
  approval workflow a place to hang a "reviewed" state.

### Draft, reviewed, approved

Discovery produces a **draft** artifact. A human reviewer (or an automated
review pass) then:

1. Ensures no plaintext credentials leaked into `Step.value`. Sensitive values
   are replaced with `{{parameter}}` templates.
2. Replaces hardcoded per-run values (member IDs, URLs) with template
   parameters so the artifact is reusable across invocations.
3. Ensures every declared `Output` has a corresponding `read` step that
   produces it.
4. Adds or reviews `ErrorHandler`s for the business outcomes that the flow
   can legitimately hit.

In our recorded example, the LLM-generated draft had plaintext credentials in
two steps, hardcoded member IDs in three steps, duplicate/broken click steps,
and no `read` step for the declared output. After review, the artifact is
parameterized, has explicit error handlers, and replays deterministically.
This draft-to-approved pipeline is the natural home for the "confidence &
approval" stretch goal; we describe the seam but do not implement gating.

## Determinism & error handling

Determinism comes from four sources.

1. **No LLM in the loop.** The replay engine never calls a model.
2. **Layered locators.** `src/replay/locator.py` tries the primary locator,
   then each declared fallback, in order. A locator resolved through a
   different strategy is graceful degradation, not a failure.
3. **Explicit checkpoints.** Every replay verifies a checkpoint on success
   and may verify per-step checkpoints. A successful click that did not
   actually change state is caught, not silently accepted.
4. **Templated values.** `Step.value` supports `{{name}}` substitution, so a
   single artifact drives many invocations.

### The three-way error taxonomy

This is the load-bearing decision.

| Kind | Example | Replay behavior |
|---|---|---|
| **Business** | "No members matched", "You do not have permission" | Return as a structured outcome to the caller. Do not retry, do not crash. |
| **Recoverable** | Session expired, transient slow load, dismissible interstitial | Attempt bounded recovery (retry / dismiss) and continue. |
| **Hard** | Selector not found, action failed, checkpoint failed | Stop, capture screenshot and DOM snapshot, return a debuggable error. |

Conflating "no such member" (a legitimate answer the caller needs) with
"replay failed" (a bug) is the most common design mistake in this space.

### How detection actually works

Each step may declare a list of `ErrorHandler`s. They are evaluated in three
places, in this order:

1. **Before** the action. If the page already shows a matching error surface,
   we short-circuit. This handles cases where the previous step's effect only
   became visible now.
2. **On step failure.** If the action raised, we check declared handlers
   before falling back to a generic failure.
3. **After** the action. The same check runs again, in case the action itself
   produced the error state.

Two details that matter in practice:

- **Cross-frame text.** Legacy apps put content inside iframes. Our detection
  reads `innerText` across the main frame *and every child iframe*, not just
  `document.body`. Without this, a "No members matched" banner inside
  `#mainFrame` is invisible to the engine.

- **Polling vs single check.** When we look for a `detect_text` *after* a
  state-changing action (`click`, `navigate`), we poll for up to 3 seconds
  because the iframe content is rendered asynchronously. When we look
  *before* an action, or on a non-state-changing step, we do a single check,
  because we are only asking "is the page already in an error state". Polling
  everywhere would add seconds to every replay; polling nowhere would miss
  errors that appear half a second after the click.

In the recorded example, all three outcomes were produced end-to-end:

    member_id=12345 -> success  code=OK    savings_balance=$12345.67
    member_id=99999 -> business code=NOT_FOUND
    member_id=00000 -> business code=PERMISSION_DENIED

Replay for the success case runs in about 18 seconds wall-clock, including
Chromium launch and per-step screenshots. The two business-outcome replays
run faster (3-10 seconds) because they exit as soon as the error surface is
detected, without proceeding to the next step.

## Heterogeneity & multi-tenant

We implemented against one surface (a legacy web app), but the design does not
assume it.

**Surface abstraction.** `TargetInfo.adapter` names the adapter
(`playwright-web` in v1). A `desktop` adapter would speak to OS APIs (UIA on
Windows, AX on macOS) but expose the same `Locator` interface to the artifact.
The seam is: artifacts declare *what* to target (role, label, text, name,
frame path, CSS); adapters know *how* to resolve that on their surface.
`LocatorStrategy` already includes `COORDINATES`, the common denominator
between web and desktop.

**Multi-tenant reuse.** Hundreds of tenants running the same vendor product
with different configuration share a lot of UI. We model this in `TargetInfo`
by carrying `tenant_id` and `app_version`. The intended reuse pattern:

1. Record a **base artifact** against a canonical tenant.
2. Record **overrides** (a small explicit list of `Locator` replacements and
   parameter defaults) per tenant or per app version.
3. Replay applies overrides on top of the base artifact.

Drift is detected at replay time: when the primary locator fails and a
declared fallback succeeds, that is a signal. The replay engine logs a
`locator_fallback_used` event, which can be aggregated per
`(tenant_id, app_version)` to produce a drift dashboard without a
UI-diffing engine.

**What we did not build.** Tenant override application, drift aggregation,
and a desktop adapter are design-only. They are clean seams, deliberately
not implemented, called out in *Cuts*.

## Escalation & handoff

"Stuck" states are detected in two places:

1. **During discovery:** the agent hits `max_steps`, times out, or repeatedly
   fails the same action.
2. **During replay:** a hard failure, an unhandled recoverable after retries,
   or a `risky`/`irreversible` step that requires approval.

Handoff (`src/handoff/cli.py`) works as follows:

- Automation runs in a **headed** browser. The session is a single, live
  `BrowserContext` - not a snapshot, not a re-login.
- On a stuck state, the engine calls `handoff.request(...)` with a
  `HandoffRequest` carrying reason, step id, and a free-form context string.
- The CLI prints the request, takes a **pre-handoff screenshot**, and blocks
  on stdin. The operator now drives the same browser window directly.
- On `resume`, the operator may attach notes; the CLI takes a **post-handoff
  screenshot** and a **DOM snapshot**, records both as evidence, and returns
  control to automation.
- A **control token** (`control=automation` vs `control=operator`) is written
  to the structured log at every transition, so a reviewer can reconstruct
  exactly who had control at each moment.

The seam is real: pause, transfer, resume on the same session. The operator
UI is intentionally a CLI, not a co-browsing console; the mechanism (control
transfer, evidence capture, operator notes) is what matters.

## Safety

Three layers.

**1. Allowlist** (`src/safety/allowlist.py`). Per-artifact `SafetyPolicy`
with `allowed_domains` and `allowed_actions`. Enforced before every action
and before every navigation. Domain matching is suffix-aware, but the default
policy for the mock app is tight: `127.0.0.1`, `localhost`.

**2. Risk classification.** `RiskLevel.SAFE | RISKY | IRREVERSIBLE`. Replay
requires interactive confirmation for `RISKY` steps and blocks `IRREVERSIBLE`
steps outright unless the policy explicitly allows them. The discovery agent
applies the same policy: it will not perform actions outside the allowlist,
even if the LLM asks.

**3. Redaction** (`src/safety/redaction.py`). Two complementary layers:

- **Pattern-based.** Match common secret/PII shapes anywhere in a string:
  API keys, SSNs, email addresses, 9-16 digit account numbers, currency
  amounts.
- **Field-name-based.** If the *key* of a mapping entry looks sensitive
  (`password`, `secret`, `token`, `api_key`, `authorization`, `session_id`,
  `cookie`, ...), mask the entire value regardless of its shape. This is the
  layer that catches credentials like `password123`, which no shape-based
  pattern would match.

Both layers are applied to every field written to the structured log and to
the evidence result file. Declared outputs are returned to the caller in the
*result* but redacted in *logs and evidence*: the caller needs the balance,
the audit trail does not.

**Limits.** This is not a formal data-flow policy engine. A motivated caller
could exfiltrate a value by encoding it (base64, spacing tricks). Redaction is
defense in depth, not the primary control. The primary control is the
allowlist forbidding the network destinations where exfiltration could happen.

## Cuts

Deliberately not built, and why:

- **Full operator console (co-browsing UI).** The handoff mechanism and the
  control-transfer model are real; the operator surface is a CLI. A WebSocket
  console with live screenshots would be a two-day project and would not
  change the design.
- **Desktop surface adapter.** The `TargetInfo.adapter` seam exists and
  `LocatorStrategy.COORDINATES` is reserved, but only `playwright-web` is
  implemented.
- **Multi-tenant override engine.** Modeled in the schema and described
  above. Not implemented.
- **Visual locators (image template matching).** A useful fallback for
  surfaces where nothing else works, but bounded value for the target
  environment, which has stable UIs.
- **Approval workflow (draft to approved).** The draft/reviewed/approved
  pipeline is described above. The gating mechanism (a status field on the
  artifact plus a review CLI) is not implemented.
- **Assisted fallback on replay failure.** A bounded, policy-checked LLM
  recovery for a single step is a natural next extension. Not implemented.

**Next, in priority order:**

1. Approval state on artifacts plus a review CLI. Gate unattended replay on
   `status == "approved"`.
2. Assisted fallback: allow a single bounded LLM recovery on a replay step
   failure, recorded as evidence, gated by the safety allowlist.
3. Canonicalization of concrete routes and values into parameterized patterns
   (`/member/12345` to `/member/:id`), enabling cross-tenant reuse.
4. Multi-run stability: replay each artifact N times and emit a flakiness
   score per artifact, per tenant.