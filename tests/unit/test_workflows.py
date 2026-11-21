"""The rules every workflow follows (docs/spec/08-testing.md, "CI workflows").

Actions are pinned by commit, permissions are declared and minimal, and the
approval of a merge waits for the review record (docs/spec/11-review.md).
"""

import re
from pathlib import Path
from typing import cast

import pytest
import yaml

from tests.support import REPO

WORKFLOWS = sorted((REPO / ".github" / "workflows").glob("*.yml"))

type Mapping = dict[str, object]


def load(path: Path) -> Mapping:
    return cast(Mapping, yaml.safe_load(path.read_text(encoding="utf-8")))


def jobs(workflow: Mapping) -> dict[str, Mapping]:
    return cast(dict[str, Mapping], workflow["jobs"])


def steps(job: Mapping) -> list[Mapping]:
    return cast(list[Mapping], job.get("steps", []))


def triggers(workflow: Mapping) -> Mapping:
    # YAML 1.1 reads the key `on` as the boolean true.
    keys = cast(dict[object, object], workflow)
    return cast(Mapping, keys.get("on", keys.get(True)))


def test_the_workflows_of_m0_exist() -> None:
    assert {path.name for path in WORKFLOWS} >= {"ci.yml", "approval.yml"}


@pytest.mark.parametrize("path", WORKFLOWS, ids=lambda path: path.name)
def test_every_action_is_pinned_by_commit(path: Path) -> None:
    for job in jobs(load(path)).values():
        for step in steps(job):
            if "uses" in step:
                assert re.fullmatch(r"[\w.-]+/[\w.-]+@[0-9a-f]{40}", str(step["uses"]))


@pytest.mark.parametrize("path", WORKFLOWS, ids=lambda path: path.name)
def test_permissions_are_declared_and_never_write(path: Path) -> None:
    workflow = load(path)
    scopes = [workflow["permissions"]]
    scopes += [
        job["permissions"] for job in jobs(workflow).values() if "permissions" in job
    ]

    for scope in scopes:
        assert scope == {} or set(cast(Mapping, scope).values()) <= {"read", "none"}


@pytest.mark.parametrize("path", WORKFLOWS, ids=lambda path: path.name)
def test_no_workflow_runs_with_the_base_repositorys_token(path: Path) -> None:
    assert not {"pull_request_target", "workflow_run"} & set(triggers(load(path)))


@pytest.mark.parametrize("path", WORKFLOWS, ids=lambda path: path.name)
def test_a_checkout_keeps_no_credentials(path: Path) -> None:
    for job in jobs(load(path)).values():
        for step in steps(job):
            if str(step.get("uses", "")).startswith("actions/checkout@"):
                assert cast(Mapping, step["with"])["persist-credentials"] is False


def test_the_approval_waits_for_the_review_record() -> None:
    workflow = load(REPO / ".github" / "workflows" / "approval.yml")
    review_record, approve = jobs(workflow)["review-record"], jobs(workflow)["approve"]
    gate = [str(step["run"]) for step in steps(review_record) if "run" in step]

    assert cast(Mapping, triggers(workflow)["pull_request"])["branches"] == [
        "main",
        "v2",
    ]
    assert approve["needs"] == "review-record"
    assert approve["environment"] == "merge-approval"
    assert gate == ['python3 tools/findings.py gate "$BRANCH"']
    assert steps(review_record)[-1]["env"] == {"BRANCH": "${{ github.head_ref }}"}


def test_the_ci_runs_every_gate_on_every_supported_python() -> None:
    workflow = load(REPO / ".github" / "workflows" / "ci.yml")
    job = jobs(workflow)["gates"]
    commands = [str(step.get("run", "")) for step in steps(job)]
    matrix = cast(Mapping, cast(Mapping, job["strategy"])["matrix"])

    assert matrix["python"] == ["3.12", "3.13", "3.14"]
    assert cast(Mapping, job["env"])["VMSEED_REQUIRE_TOOLS"] == "1"
    for gate in (
        "uv run ruff format --check .",
        "uv run ruff check .",
        "uv run pyright",
        'uv run pytest -m "not contract and not e2e" --cov --cov-report=',
        "uv run pytest -m contract --cov --cov-append --cov-fail-under=90",
        "uv run python tools/findings.py check",
    ):
        assert gate in commands
