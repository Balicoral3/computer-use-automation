"""CLI: replay a saved artifact deterministically.

Usage:
  python -m cli.replay --artifact-id lookup_member_balance --param member_id=12345
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from dotenv import load_dotenv
from playwright.sync_api import sync_playwright

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from src.artifact.schema import ActionType, RiskLevel, SafetyPolicy, Step
from src.artifact.store import ArtifactStore
from src.evidence.logger import RunLogger
from src.replay.engine import ReplayEngine
from src.replay.errors import OutcomeKind
from src.safety.allowlist import Allowlist
from src.handoff.cli import CLIHandoff, HandoffRequest


def _parse_params(items):
    out = {}
    for item in items or []:
        if "=" not in item:
            raise SystemExit(f"Bad --param (expected key=value): {item}")
        k, v = item.split("=", 1)
        out[k.strip()] = v.strip()
    return out


def _make_confirm(page, logger):
    def confirm(step: Step, reason: str) -> bool:
        # Offer the human a choice via handoff console.
        print(f"\n[safety] Step {step.id} ({step.action.value}) flagged: {reason}")
        try:
            ans = input("Approve this step? [y/N] ").strip().lower()
        except EOFError:
            ans = "n"
        logger.log("safety.confirm", step_id=step.id, approved=(ans == "y"))
        return ans == "y"
    return confirm


def main() -> int:
    load_dotenv()
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact-id", required=True)
    parser.add_argument("--param", action="append", default=[])
    parser.add_argument("--headless", action="store_true")
    parser.add_argument("--auto-handoff", action="store_true",
                        help="If a hard failure occurs, offer handoff instead of exiting.")
    args = parser.parse_args()

    params = _parse_params(args.param)
    store = ArtifactStore(os.environ.get("ARTIFACTS_DIR", "artifacts"))
    artifact = store.load(args.artifact_id)

    allowed = artifact.safety.allowed_domains or ["127.0.0.1", "localhost"]
    allowlist = Allowlist(policy=artifact.safety)

    logger = RunLogger(kind="replay")

    with sync_playwright() as pw_ctx:
        browser = pw_ctx.chromium.launch(headless=args.headless)
        context = browser.new_context(viewport={"width": 1280, "height": 800})
        page = context.new_page()
        page.set_default_timeout(10_000)

        confirm_fn = _make_confirm(page, logger)
        engine = ReplayEngine(page=page, allowlist=allowlist, logger=logger,
                              confirm=confirm_fn)

        outcome = engine.run(artifact, params)

        print()
        print("=" * 70)
        print(f"Replay outcome: {outcome.kind.value}  code={outcome.code}")
        print(f"Message: {outcome.message}")
        if outcome.outputs:
            print(f"Outputs: {json.dumps(outcome.outputs, indent=2)}")
        print(f"Evidence: {logger.path}")
        print("=" * 70)

        # Optional: offer handoff on failure
        if outcome.kind == OutcomeKind.FAILURE and args.auto_handoff:
            handoff = CLIHandoff(page=page, logger=logger)
            res = handoff.request(HandoffRequest(
                reason=f"Replay failed at {outcome.step_id}: {outcome.code}",
                step_id=outcome.step_id,
                context=outcome.message,
            ))
            if res.resumed:
                print("Handoff complete. (Not resuming replay automatically in v1.)")
            else:
                print("Handoff aborted.")

        browser.close()

    return 0 if outcome.kind == OutcomeKind.SUCCESS else 1


if __name__ == "__main__":
    raise SystemExit(main())