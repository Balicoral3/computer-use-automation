"""Unit tests for the artifact schema."""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from src.artifact.schema import (
    ActionType,
    CapabilityArtifact,
    Checkpoint,
    Locator,
    LocatorStrategy,
    Parameter,
    SafetyPolicy,
    Step,
    TargetInfo,
)


def _minimal_artifact() -> CapabilityArtifact:
    return CapabilityArtifact(
        id="t",
        name="Test",
        description="Test artifact",
        llm_model="deepseek-chat",
        target=TargetInfo(app_id="mock", entry_url="http://127.0.0.1:5000/login"),
        parameters=[Parameter(name="member_id", type="string", description="ID")],
        steps=[
            Step(id="s1", action=ActionType.NAVIGATE,
                 description="Go to login", value="http://127.0.0.1:5000/login"),
        ],
        checkpoint=Checkpoint(
            description="On login page",
            locator=Locator(strategy=LocatorStrategy.CSS, value="body"),
        ),
        safety=SafetyPolicy(
            allowed_domains=["127.0.0.1", "localhost"],
            allowed_actions=list(ActionType),
        ),
    )


def test_minimal_artifact_roundtrip():
    a = _minimal_artifact()
    payload = a.model_dump(mode="json")
    b = CapabilityArtifact.model_validate(payload)
    assert b.id == "t"
    assert b.steps[0].action == ActionType.NAVIGATE


def test_render_value_substitutes_templates():
    a = _minimal_artifact()
    out = a.render_value("http://x/member/{{member_id}}", {"member_id": "12345"})
    assert out == "http://x/member/12345"


def test_render_value_handles_none():
    a = _minimal_artifact()
    assert a.render_value(None, {}) is None


def test_step_rejects_api_key_like_value():
    with pytest.raises(ValidationError):
        Step(id="s1", action=ActionType.FILL, description="x",
             value="sk-abcdefghijklmnopqrstuv")


def test_locator_describe():
    loc = Locator(strategy=LocatorStrategy.ROLE, value="button", name="Sign In")
    assert "button" in loc.describe()
    assert "Sign In" in loc.describe()


def test_parameter_names_helper():
    a = _minimal_artifact()
    assert a.parameter_names() == ["member_id"]