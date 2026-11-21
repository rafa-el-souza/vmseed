"""`findings.py open | count | summary | gate`, and the exit status of each."""

from pathlib import Path
from typing import Any

import pytest

from tests.support.records import (
    a_finding,
    a_question,
    a_record,
    a_round,
    replace,
    the_findings,
    to_toml,
    write,
)
from tools import findings


def record_of(**changes: Any) -> findings.Record:
    document = a_record(**changes)
    return findings.validate(document, stem="m3", name="docs/findings/m3.toml")


def run(capsys: pytest.CaptureFixture[str], root: Path, *argv: str) -> tuple[int, str]:
    status = findings.main(["--root", str(root), *argv])
    return status, capsys.readouterr().out


# -- open -----------------------------------------------------------------------


def test_a_closed_record_has_nothing_open() -> None:
    assert findings.open_items(record_of()) == []


def test_open_lists_a_finding_without_an_outcome() -> None:
    record = record_of(findings=replace(the_findings(), 0, outcome=""))

    assert findings.open_items(record) == [
        "M3-F01: no outcome (plan fix): SSH-07 passes when the guest serves two "
        "host keys."
    ]


def test_open_lists_a_question_without_an_answer_while_its_finding_is_open() -> None:
    record = record_of(
        findings=replace(the_findings(), 1, outcome=""),
        questions=[a_question(answer="")],
    )

    items = findings.open_items(record)

    assert [item.split(":")[0] for item in items] == ["M3-F02", "M3-Q1"]


def test_a_question_whose_findings_were_not_confirmed_is_not_open() -> None:
    record = record_of(
        findings=replace(
            the_findings(),
            1,
            evidence="inspection",
            outcome="not confirmed: the record is read before the lock",
        ),
        questions=[a_question(answer="")],
    )

    assert findings.open_items(record) == []


def test_open_lists_a_round_whose_header_is_incomplete() -> None:
    record = record_of(rounds=[a_round(fix_review="")])

    assert findings.open_items(record) == ["round 1: header incomplete: fix_review"]


def test_open_exits_1_and_prints_what_is_open(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    write(tmp_path, a_record(findings=replace(the_findings(), 4, outcome="")))

    status, output = run(capsys, tmp_path, "open")

    assert status == 1
    assert output.startswith("docs/findings/m3.toml: M3-F05: no outcome")


def test_open_exits_0_on_a_closed_record(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    path = write(tmp_path, a_record())

    assert run(capsys, tmp_path, "open", str(path)) == (0, "")


def test_open_exits_2_on_a_record_check_refuses(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    write(tmp_path, a_record(pr=0))

    status, output = run(capsys, tmp_path, "open")

    assert status == 2
    assert "refused" in output


# -- count ------------------------------------------------------------------------


def test_count_gives_claims_per_source_by_plan_and_by_outcome() -> None:
    text = findings.count([record_of()])

    assert "| source | claims | question | fix | record |" in text
    assert "| correctness | 5 | 1 | 2 | 2 |" in text
    assert "| security | 1 | 0 | 1 | 0 |" in text
    assert "| sibling-search | 1 | 0 | 1 | 0 |" in text
    assert "| fix-review | 1 | 0 | 1 | 0 |" in text
    assert "| total | 8 | 1 | 5 | 2 |" in text
    header = (
        "| source | fixed | not reproduced | not confirmed | kept as built | "
        "deferred | recorded: forced path | recorded: no effect | open |"
    )
    assert header in text
    assert "| correctness | 1 | 0 | 1 | 1 | 0 | 1 | 1 | 0 |" in text
    assert "| total | 3 | 1 | 1 | 1 | 0 | 1 | 1 | 0 |" in text
    assert "Claims the reviewer marked unlikely: 1" in text


def test_count_reads_every_record_when_given_no_file(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    write(tmp_path, a_record())
    m4 = a_record(
        milestone="M4",
        findings=[a_finding(1, id="M4-F01", outcome="")],
        questions=[],
    )
    write(tmp_path, m4, name="m4.toml")

    status, output = run(capsys, tmp_path, "count")

    assert status == 0
    assert output.startswith("Records: docs/findings/m3.toml, docs/findings/m4.toml")
    assert "| total | 9 | 1 | 6 | 2 |" in output


def test_count_with_no_record_says_so(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    status, output = run(capsys, tmp_path, "count")

    assert status == 0
    assert output.startswith("Records: none")


# -- summary ----------------------------------------------------------------------


def test_summary_is_the_review_section_the_user_reads() -> None:
    text = findings.summary(record_of())

    assert text.startswith("## Review\n\nMilestone M3, pull request #12.")
    assert "| 1 | `3f2c1ab..9d41e07` | 2026-12-01 | ran | ran | ran | ran |" in text
    assert "Security trigger, round 1: matched `src/vmseed/guest/controls/ssh.py`." in (
        text
    )
    assert "- **M3-Q1** (M3-F02): The specification does not say" in text
    assert "  - Recommendation: Show it as drifted" in text
    assert "  - Assumption applied: Shown as drifted" in text
    assert "  - Answer: Show it as drifted." in text
    assert "- M3-F02: SSH-07 passes when the guest serves two host keys. Outcome: " in (
        text
    )
    assert "(path tool, effect wrong; recorded: forced path (tool))." in text
    assert "recorded: no effect). Unlikely: Two runs a second apart." in text
    assert "Not reproduced: the test written first did not fail" in text
    assert "Not confirmed: the lock is taken before the check." in text
    assert "### Open" not in text


def test_summary_says_when_the_trigger_did_not_match_and_lists_what_is_open() -> None:
    record = record_of(
        rounds=[a_round(security="not triggered", security_trigger=[])],
        findings=[a_finding(1, outcome="")],
        questions=[],
    )

    text = findings.summary(record)

    assert "Security trigger, round 1: did not match." in text
    assert "### Questions\n\nNone." in text
    assert "### Open\n\n- M3-F01: SSH-07" in text


def test_summary_tells_an_unanswered_question_from_one_never_asked() -> None:
    needed = record_of(
        findings=replace(the_findings(), 1, outcome=""),
        questions=[a_question(answer="")],
    )
    not_needed = record_of(
        findings=replace(
            the_findings(),
            1,
            evidence="inspection",
            outcome="not confirmed: the record is read before the lock",
        ),
        questions=[a_question(answer="")],
    )

    assert "  - Answer: not answered yet" in findings.summary(needed)
    assert "  - Answer: not asked: no finding needed the answer" in findings.summary(
        not_needed
    )


def test_summary_marks_a_picked_finding(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    path = write(
        tmp_path,
        a_record(findings=replace(the_findings(), 3, outcome="fixed", picked=True)),
    )

    status, output = run(capsys, tmp_path, "summary", str(path))

    assert status == 0
    assert "- M3-F04 (picked by the user): " in output


def test_summary_exits_2_on_a_record_check_refuses(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    path = write(tmp_path, a_record(pr=0))

    status, _ = run(capsys, tmp_path, "summary", str(path))

    assert status == 2


# -- check, from the command line ---------------------------------------------------


def test_check_without_a_record_passes(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    assert run(capsys, tmp_path, "check") == (
        0,
        "No review record under docs/findings/.\n",
    )


def test_check_reads_every_record_and_exits_1_if_one_is_refused(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    write(tmp_path, a_record())
    write(tmp_path, a_record(milestone="M4", findings=[], questions=[]), "m4.toml")
    write(tmp_path, a_record(), name="m5.toml")

    status, output = run(capsys, tmp_path, "check")

    assert status == 1
    assert output.splitlines()[:3] == [
        "docs/findings/m3.toml: ok",
        "docs/findings/m4.toml: ok",
        "docs/findings/m5.toml: refused",
    ]


@pytest.mark.parametrize(
    ("content", "message"),
    [
        (b"milestone = \n", "is not valid TOML"),
        (b"milestone = '\xff'\n", "is not UTF-8"),
    ],
)
def test_check_refuses_a_file_it_cannot_parse(
    tmp_path: Path, capsys: pytest.CaptureFixture[str], content: bytes, message: str
) -> None:
    path = tmp_path / "m3.toml"
    path.write_bytes(content)

    status, output = run(capsys, tmp_path, "check", str(path))

    assert status == 1
    assert message in output
    assert output.startswith("m3.toml: refused")


def test_check_refuses_a_file_it_cannot_read(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    status, output = run(capsys, tmp_path, "check", str(tmp_path / "m3.toml"))

    assert status == 1
    assert "cannot read it" in output


def test_check_round_trips_a_record_through_toml(tmp_path: Path) -> None:
    path = write(tmp_path, a_record())

    assert findings.load(path, "docs/findings/m3.toml") == record_of()
    assert "[[finding]]" in to_toml(a_record())


# -- gate -----------------------------------------------------------------------------


def test_gate_passes_a_branch_that_is_not_a_milestones(tmp_path: Path) -> None:
    passed, lines = findings.gate("fix-typo", tmp_path)

    assert passed
    assert lines == [
        "Branch 'fix-typo' is not a milestone's branch (m<N>-<slug>): no review "
        "record is required."
    ]


def test_gate_stops_a_milestone_branch_without_its_record(tmp_path: Path) -> None:
    passed, lines = findings.gate("m3-distros", tmp_path)

    assert not passed
    assert lines[0] == (
        "Branch 'm3-distros' is milestone M3's: its review record "
        "docs/findings/m3.toml does not exist yet."
    )


def test_gate_stops_a_record_check_refuses(tmp_path: Path) -> None:
    write(tmp_path, a_record(pr=0))

    passed, lines = findings.gate("m3-distros", tmp_path)

    assert not passed
    assert lines[0].endswith("is refused:")


def test_gate_stops_a_record_with_an_open_finding(tmp_path: Path) -> None:
    write(tmp_path, a_record(findings=replace(the_findings(), 0, outcome="")))

    passed, lines = findings.gate("m3-distros", tmp_path)

    assert not passed
    assert lines[0].endswith("is still open:")
    assert lines[1].startswith("  - M3-F01: no outcome")


def test_gate_passes_a_closed_record(tmp_path: Path) -> None:
    write(tmp_path, a_record())

    passed, lines = findings.gate("m3-distros", tmp_path)

    assert passed
    assert lines == [
        "Branch 'm3-distros' is milestone M3's: its review record "
        "docs/findings/m3.toml is closed."
    ]


@pytest.mark.parametrize(
    ("branch", "record"),
    [
        ("m3a-primitives", "docs/findings/m3a.toml"),
        ("M3A_primitives", "docs/findings/m3a.toml"),
        ("m10-later", "docs/findings/m10.toml"),
        ("m03-padded", "docs/findings/m3.toml"),
        ("m0", "docs/findings/m0.toml"),
    ],
)
def test_gate_finds_the_record_from_the_branch_name(
    tmp_path: Path, branch: str, record: str
) -> None:
    passed, lines = findings.gate(branch, tmp_path)

    assert not passed
    assert f"its review record {record} does not exist yet." in lines[0]


@pytest.mark.parametrize("branch", ["m3ab-x", "m3!x", "M3b+x"])
def test_gate_stops_a_branch_that_only_looks_like_a_milestones(
    tmp_path: Path, branch: str
) -> None:
    passed, lines = findings.gate(branch, tmp_path)

    assert not passed
    assert "looks like a milestone's branch but is not m<N>-<slug>" in lines[0]


@pytest.mark.parametrize("branch", ["main", "v2", "migrate-x", "mx-1"])
def test_gate_passes_names_that_merely_start_with_m(
    tmp_path: Path, branch: str
) -> None:
    passed, _ = findings.gate(branch, tmp_path)

    assert passed


def test_gate_escapes_control_characters_in_the_branch_name(tmp_path: Path) -> None:
    _, lines = findings.gate("x\x1b[31m", tmp_path)

    assert "\x1b" not in lines[0]
    assert "x\\\\x1b[31m" in lines[0]


def test_gate_from_the_command_line(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    write(tmp_path, a_record())

    assert run(capsys, tmp_path, "gate", "m3-distros")[0] == 0
    assert run(capsys, tmp_path, "gate", "m4-lifecycle")[0] == 1


def test_a_command_is_required(capsys: pytest.CaptureFixture[str]) -> None:
    with pytest.raises(SystemExit) as stopped:
        findings.main([])

    assert stopped.value.code == 2
    assert "required" in capsys.readouterr().err


def test_the_tool_runs_as_a_script(capsys: pytest.CaptureFixture[str]) -> None:
    import runpy
    import sys

    script = Path(findings.__file__)
    argv = sys.argv
    sys.argv = [str(script), "gate", "fix-typo"]
    try:
        with pytest.raises(SystemExit) as stopped:
            runpy.run_path(str(script), run_name="__main__")
    finally:
        sys.argv = argv

    assert stopped.value.code == 0
    assert "no review record is required" in capsys.readouterr().out
