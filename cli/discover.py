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