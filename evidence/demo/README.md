# Evidence

This folder contains the evidence required by the assessment brief
(Section 6.3): a saved example artifact plus logs from both a discovery run
and a replay run.

## Contents

    artifacts/
      lookup_member_balance_llm_draft.json    Raw artifact as produced by the LLM
      lookup_member_balance_reviewed.json     Reviewed, parameterized version

    discovery/                                LLM-driven discovery run
      run.jsonl                               Structured log of every step
      result.json                             Final structured result
      screenshots/                            Per-step screenshots
      dom/                                    DOM snapshots (if any)

    replay_success/                           Deterministic replay, success path
      run.jsonl
      result.json                             kind=success, code=OK
      screenshots/

    replay_business_outcome/                  Deterministic replay, business outcome
      run.jsonl
      result.json                             kind=business, code=NOT_FOUND or PERMISSION_DENIED
      screenshots/

## How the discovery run works

The discovery step is LLM-driven. In the recorded run, the model chose each
action itself (fill username, fill password, click Sign In, search for the
member, click Open, read the balance), observed the page after every step,
and finally called `finish` with the savings balance as its output.

The raw artifact it produced is in `artifacts/lookup_member_balance_llm_draft.json`.
It has some issues the reviewer must fix (plaintext credential, hardcoded
member IDs, duplicated steps, no `read` step for the declared output). Those
fixes are applied by hand and the result is saved as
`artifacts/lookup_member_balance_reviewed.json`. This draft-to-reviewed
pipeline is described in REPORT.md.

## How the replay runs work

Replay is fully deterministic: no LLM in the loop. The engine reads the
reviewed artifact, substitutes parameters, executes each step with layered
locators, verifies the checkpoint, and returns a structured outcome.

Three outcomes are demonstrated across runs:

    member_id=12345   success   code=OK                 savings_balance=$12345.67
    member_id=99999   business  code=NOT_FOUND          (no such member)
    member_id=00000   business  code=PERMISSION_DENIED  (account is restricted)

The distinction between "no such member" (a legitimate answer) and a hard
failure (a bug) is the central design point of the error taxonomy; see
REPORT.md.