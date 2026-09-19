"""End-to-end replay tests using the offline fixture artifact."""

from __future__ import annotations

import json
from pathlib import Path

from src.artifact.schema import CapabilityArtifact
from src.evidence.logger import RunLogger
from src.replay.engine import ReplayEngine
from src.replay.errors import OutcomeKind
from src.safety.allowlist import Allowlist

FIXTURE_PATH = Path(__file__).parent / "fixtures" / "lookup_member_balance.json"


def _load_artifact() -> CapabilityArtifact:
    return CapabilityArtifact.model_validate(json.loads(FIXTURE_PATH.read_text(encoding="utf-8")))


def _run_replay(page, target_app_url, member_id, tmp_path):
    artifact = _load_artifact()
    allowlist = Allowlist(policy=artifact.safety)
    logger = RunLogger(root=tmp_path / "evidence", kind="replay_test")
    engine = ReplayEngine(page=page, allowlist=allowlist, logger=logger)
    return engine.run(artifact, {
        "base_url": target_app_url,
        "username": "teller1",
        "password": "password123",
        "member_id": member_id,
    })


def test_replay_success_reads_balance(page, target_app_url, tmp_path):
    outcome = _run_replay(page, target_app_url, "12345", tmp_path)
    assert outcome.kind == OutcomeKind.SUCCESS, outcome
    assert outcome.outputs.get("savings_balance") == "$12345.67"


def test_replay_not_found_is_business_outcome(page, target_app_url, tmp_path):
    outcome = _run_replay(page, target_app_url, "99999", tmp_path)
    assert outcome.kind == OutcomeKind.BUSINESS, outcome
    assert outcome.code == "NOT_FOUND"


def test_replay_permission_denied_is_business_outcome(page, target_app_url, tmp_path):
    outcome = _run_replay(page, target_app_url, "00000", tmp_path)
    assert outcome.kind == OutcomeKind.BUSINESS, outcome
    assert outcome.code == "PERMISSION_DENIED"


def test_replay_missing_param_fails_fast(page, target_app_url, tmp_path):
    artifact = _load_artifact()
    allowlist = Allowlist(policy=artifact.safety)
    logger = RunLogger(root=tmp_path / "evidence", kind="replay_test")
    engine = ReplayEngine(page=page, allowlist=allowlist, logger=logger)
    outcome = engine.run(artifact, {"base_url": target_app_url})
    assert outcome.kind == OutcomeKind.FAILURE
    assert outcome.code == "MISSING_PARAMS"