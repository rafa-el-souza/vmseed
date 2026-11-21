"""`findings.py check`: what it accepts and each kind of bad file it refuses.

docs/spec/11-review.md, "The tool": check refuses an unknown key, a value
outside a list, a clause without what it requires, a plan that differs from
the derived one, an outcome the plan does not allow, a duplicate or foreign
id, and a home-directory path in a text field.
"""

import datetime as dt

import pytest

from tests.support.records import (
    Table,
    a_finding,
    a_question,
    a_record,
    a_round,
    replace,
    the_findings,
)
from tools import findings


def refusals(document: object, stem: str = "m3") -> list[str]:
    try:
        findings.validate(document, stem=stem, name=f"docs/findings/{stem}.toml")
    except findings.RecordError as error:
        return list(error.errors)
    return []


def refused(document: object, fragment: str, stem: str = "m3") -> bool:
    return any(fragment in error for error in refusals(document, stem))


def with_finding(index: int, **changes: object) -> Table:
    return a_record(findings=replace(the_findings(), index, **changes))


# -- accepted -------------------------------------------------------------


def test_a_closed_record_with_every_kind_of_outcome_passes() -> None:
    assert refusals(a_record()) == []


def test_a_round_without_claims_passes() -> None:
    document = a_record(
        rounds=[a_round(security="not triggered", security_trigger=[])],
        findings=[],
        questions=[],
    )

    assert refusals(document) == []


def test_a_round_still_running_passes_check() -> None:
    document = a_record(rounds=[a_round(fix_review="", verifier="")])

    assert refusals(document) == []


def test_a_slice_record_passes_under_its_own_name() -> None:
    document = a_record(
        milestone="M3a",
        findings=[a_finding(1, id="M3a-F01")],
        questions=[],
    )

    assert refusals(document, stem="m3a") == []


def test_an_open_finding_passes_check() -> None:
    assert refusals(with_finding(0, outcome="")) == []


def test_a_picked_finding_planned_record_may_be_fixed() -> None:
    assert refusals(with_finding(3, outcome="fixed", picked=True)) == []


def test_a_question_finding_fixed_on_inspection_passes_once_the_user_answered() -> None:
    document = with_finding(1, evidence="inspection", outcome="fixed")

    assert refusals(document) == []


# -- an unknown key ---------------------------------------------------------


@pytest.mark.parametrize(
    "document",
    [
        pytest.param(a_record(severity="high"), id="top level"),
        pytest.param(a_record(rounds=[a_round(reviewer="x")]), id="round"),
        pytest.param(with_finding(0, severity="high"), id="finding"),
        pytest.param(a_record(questions=[a_question(owner="x")]), id="question"),
    ],
)
def test_check_refuses_an_unknown_key(document: Table) -> None:
    assert refused(document, "unknown key")


@pytest.mark.parametrize(
    ("key", "table"),
    [("summary", "finding"), ("outcome", "finding"), ("head", "round")],
)
def test_check_refuses_a_missing_key(key: str, table: str) -> None:
    if table == "finding":
        document = with_finding(0, **{key: None})
    else:
        document = a_record(rounds=replace([a_round()], 0, **{key: None}))

    assert refused(document, f"missing key {key!r}")


# -- a value outside a list ---------------------------------------------------


@pytest.mark.parametrize(
    ("key", "value"),
    [
        ("path", "remote"),
        ("effect", "annoying"),
        ("clause", "severe"),
        ("evidence", "hunch"),
        ("source", "bot"),
        ("plan", "maybe"),
    ],
)
def test_check_refuses_a_finding_value_outside_its_list(key: str, value: str) -> None:
    assert refused(with_finding(0, **{key: value}), f"{key} = {value!r} is not one of")


def test_check_refuses_an_attacker_that_does_not_exist() -> None:
    document = with_finding(2, attacker="root")

    assert refused(document, "attacker = 'root' is not one of")


@pytest.mark.parametrize(
    ("key", "value"),
    [
        ("correctness", "skipped"),
        ("security", "maybe"),
        ("verifier", "skipped"),
        ("fix_review", "twice"),
    ],
)
def test_check_refuses_a_round_value_outside_its_list(key: str, value: str) -> None:
    document = a_record(rounds=[a_round(**{key: value})])

    assert refused(document, f"{key} = {value!r} is not one of")


# -- a clause without what it requires ---------------------------------------


def test_check_refuses_boundary_on_a_path_that_is_not_hostile() -> None:
    document = with_finding(2, path="ordinary", attacker=None)

    assert refused(document, "clause = boundary requires path = 'hostile'")


def test_check_refuses_decided_without_a_rule() -> None:
    assert refused(with_finding(0, rule=" "), "clause = decided requires rule")


def test_check_refuses_sibling_without_a_root() -> None:
    assert refused(with_finding(5, root=None), "clause = sibling requires root")


def test_check_refuses_a_sibling_that_is_its_own_root() -> None:
    assert refused(with_finding(5, root="M3-F06"), "root must name another finding")


@pytest.mark.parametrize(
    "root",
    [
        pytest.param("M3-F04", id="root recorded on a forced path"),
        pytest.param("M3-F05", id="root with no effect"),
    ],
)
def test_check_refuses_a_sibling_whose_root_is_not_planned_fix(root: str) -> None:
    assert refused(with_finding(5, root=root), "is planned fix neither by a clause")


def test_check_refuses_a_sibling_whose_root_is_fixed_only_for_being_blocked() -> None:
    changed = replace(the_findings(), 0, effect="blocked", clause="", rule="")
    document = a_record(findings=changed)

    assert refused(document, "is planned fix neither by a clause")


def test_check_refuses_a_hostile_path_without_its_attacker() -> None:
    assert refused(with_finding(2, attacker=None), "a hostile path names its attacker")


def test_check_refuses_an_attacker_on_a_path_that_is_not_hostile() -> None:
    assert refused(with_finding(0, attacker="guest"), "attacker is only for path")


def test_check_refuses_a_root_without_the_sibling_clause() -> None:
    assert refused(with_finding(0, root="M3-F03"), "root is only for clause = sibling")


# -- a plan that differs from the derived one --------------------------------


@pytest.mark.parametrize(
    ("changes", "derived"),
    [
        pytest.param(
            {"path": "tool", "effect": "wrong", "clause": "", "rule": ""},
            "record",
            id="forced path without a clause",
        ),
        pytest.param(
            {"effect": "none", "clause": "", "rule": ""},
            "record",
            id="ordinary path without an effect",
        ),
        pytest.param({"question": "M3-Q1"}, "question", id="a question first"),
    ],
)
def test_check_refuses_a_plan_its_grade_does_not_give(
    changes: dict[str, object], derived: str
) -> None:
    document = with_finding(0, **changes)

    assert refused(document, f"plan = fix, but its grade gives {derived}")


def test_check_refuses_fix_where_the_grade_gives_record() -> None:
    document = with_finding(3, plan="fix", outcome="fixed")

    assert refused(document, "plan = fix, but its grade gives record")


@pytest.mark.parametrize(
    ("path", "effect", "clause", "question", "plan"),
    [
        ("ordinary", "lost", "", "", "fix"),
        ("ordinary", "blocked", "", "", "fix"),
        ("ordinary", "none", "", "", "record"),
        ("ordinary", "none", "decided", "", "fix"),
        ("hostile", "exposed", "", "", "record"),
        ("hostile", "exposed", "boundary", "", "fix"),
        ("tool", "lost", "destructive", "", "fix"),
        ("race", "wrong", "", "", "record"),
        ("failure", "misreport", "", "", "record"),
        ("unsupported", "blocked", "sibling", "", "fix"),
        ("ordinary", "lost", "destructive", "M3-Q1", "question"),
        ("tool", "none", "", "M3-Q1", "question"),
    ],
)
def test_the_plan_is_the_first_row_of_the_scale_that_holds(
    path: str, effect: str, clause: str, question: str, plan: str
) -> None:
    derived = findings.derive_plan(
        path=path, effect=effect, clause=clause, question=question
    )

    assert derived == plan


# -- an outcome the plan does not allow --------------------------------------


@pytest.mark.parametrize(
    ("index", "outcome"),
    [
        pytest.param(0, "recorded: no effect", id="fix closed as recorded"),
        pytest.param(0, "kept as built: as is", id="fix closed by a decision"),
        pytest.param(0, "not confirmed: ", id="not confirmed without its point"),
        pytest.param(0, "Fixed", id="not a listed outcome"),
        pytest.param(3, "not reproduced", id="record closed as not reproduced"),
        pytest.param(3, "deferred: M4", id="record closed by a decision"),
    ],
)
def test_check_refuses_an_outcome_the_plan_does_not_allow(
    index: int, outcome: str
) -> None:
    assert refused(with_finding(index, outcome=outcome), "is not allowed by plan")


@pytest.mark.parametrize(
    "outcome",
    ["fixed", "kept as built: shown as drifted", "deferred: tracked in M4"],
)
def test_check_refuses_a_decision_without_the_users_answer(outcome: str) -> None:
    document = a_record(
        findings=replace(the_findings(), 1, outcome=outcome),
        questions=[a_question(answer="")],
    )

    assert refused(document, "needs the user's answer")


def test_a_question_finding_not_confirmed_needs_no_answer() -> None:
    document = a_record(
        findings=replace(
            the_findings(),
            1,
            evidence="inspection",
            outcome="not confirmed: the record is read before the lock",
        ),
        questions=[a_question(answer="")],
    )

    assert refusals(document) == []


def test_check_refuses_a_forced_path_outcome_that_names_another_path() -> None:
    document = with_finding(3, outcome="recorded: forced path (race)")

    assert refused(document, "the outcome names path 'race'")


def test_check_refuses_a_forced_path_outcome_on_an_ordinary_path() -> None:
    document = with_finding(4, outcome="recorded: forced path (ordinary)")

    assert refused(document, "the path is ordinary, not forced")


def test_check_refuses_no_effect_for_a_finding_that_has_one() -> None:
    document = with_finding(3, outcome="recorded: no effect")

    assert refused(document, "the outcome says no effect")


def test_check_refuses_a_recorded_finding_fixed_without_being_picked() -> None:
    assert refused(with_finding(3, outcome="fixed"), "only if the user picked it")


def test_check_refuses_picked_on_a_finding_planned_fix() -> None:
    assert refused(with_finding(0, picked=True), "picked is for a finding planned")


def test_check_refuses_a_fix_that_rests_on_inspection_alone() -> None:
    assert refused(with_finding(0, evidence="inspection"), "fixed on inspection alone")


def test_check_refuses_not_reproduced_on_inspection() -> None:
    document = with_finding(6, evidence="inspection")

    assert refused(document, "not reproduced means a test was written first")


# -- a duplicate or foreign id ------------------------------------------------


def test_check_refuses_a_duplicate_finding_id() -> None:
    assert refused(with_finding(1, id="M3-F01"), "duplicate id M3-F01")


def test_check_refuses_a_finding_id_of_another_milestone() -> None:
    assert refused(with_finding(0, id="M2-F01"), "id M2-F01 is foreign")


def test_check_refuses_a_malformed_finding_id() -> None:
    assert refused(with_finding(0, id="M3-1"), "is not like M3-F01")


def test_check_refuses_ids_out_of_the_order_of_recording() -> None:
    document = a_record(findings=[a_finding(2)], questions=[])

    assert refused(document, "is out of order")


def test_check_refuses_a_question_id_of_another_milestone() -> None:
    document = a_record(questions=[a_question(id="M2-Q1")])

    assert refused(document, "id M2-Q1 is foreign")


def test_check_refuses_a_duplicate_question_id() -> None:
    document = a_record(
        findings=replace(the_findings(), 0, question="M3-Q1", plan="question"),
        questions=[a_question(), a_question(findings=["M3-F01"])],
    )

    assert refused(document, "duplicate id M3-Q1")


@pytest.mark.parametrize(
    ("document", "fragment"),
    [
        pytest.param(
            a_record(questions=[a_question(findings=["M3-F02", "M3-F99"])]),
            "M3-F99 is foreign: no such finding",
            id="a question naming no finding",
        ),
        pytest.param(
            with_finding(1, question="M3-Q7"),
            "question = M3-Q7 names no question",
            id="a finding naming no question",
        ),
        pytest.param(
            with_finding(5, root="M3-F42"),
            "root must name another finding",
            id="a root naming no finding",
        ),
        pytest.param(
            with_finding(6, about="M3-F42"),
            "about must name the finding",
            id="about naming no finding",
        ),
        pytest.param(
            with_finding(0, round=2),
            "round = 2 names no round",
            id="a round that does not exist",
        ),
    ],
)
def test_check_refuses_a_reference_to_nothing(document: Table, fragment: str) -> None:
    assert refused(document, fragment)


def test_check_refuses_a_record_whose_file_name_is_another_milestones() -> None:
    assert refused(a_record(), "its file is m3.toml", stem="m4")


def test_check_refuses_a_question_and_a_finding_that_disagree() -> None:
    document = a_record(questions=[a_question(findings=["M3-F01"])])

    assert refused(document, "finding M3-F01 does not name it")


# -- a home-directory path in a text field ------------------------------------


HOME_PATHS = [
    "/home/someone/vmseed/x.py",
    "~/projects/vmseed",
    "~someone/vmseed",
    "/Users/someone/vmseed",
    "/var/home/someone/vmseed",
    "/root/.ssh/id_ed25519",
    "$HOME/.cache/vmseed-dev",
    "${HOME}/x",
    "file:///home/someone/x",
    r"C:\Users\someone\x",
]


@pytest.mark.parametrize("path", HOME_PATHS)
@pytest.mark.parametrize("key", ["summary", "reproduction", "note", "file"])
def test_check_refuses_a_home_directory_path_in_a_finding(key: str, path: str) -> None:
    document = with_finding(0, **{key: f"see {path} for it"})

    assert refused(document, "home-directory path")


@pytest.mark.parametrize("path", HOME_PATHS)
def test_check_refuses_a_home_directory_path_in_a_question_or_a_header(
    path: str,
) -> None:
    question = a_record(questions=[a_question(answer=f"Use {path}.")])
    header = a_record(rounds=[a_round(security_trigger=[path])])

    assert refused(question, "question[1].answer: contains a home-directory path")
    assert refused(header, "round[1].security_trigger[1]: contains a home-dir")


@pytest.mark.parametrize(
    "text",
    [
        "src/vmseed/home/x.py",
        "docs/root.md and /rootfs",
        "takes ~30 minutes",
        "$XDG_CACHE_HOME/vmseed-dev/review",
        "a path like /srv/vms/dev01",
    ],
)
def test_text_that_only_looks_like_a_home_path_passes(text: str) -> None:
    assert refusals(with_finding(0, note=text)) == []


@pytest.mark.parametrize("character", ["\x1b", "\x07", "\r", "\x7f", "\x9b"])
def test_check_refuses_a_control_character_in_a_text_field(character: str) -> None:
    document = with_finding(0, summary=f"a{character}]52;c;payload")

    assert refused(document, "summary: contains a control character")


# -- shapes -------------------------------------------------------------------


@pytest.mark.parametrize(
    ("document", "fragment"),
    [
        pytest.param(a_record(pr=0), "pr = 0 must be 1 or more", id="pr 0"),
        pytest.param(a_record(pr="12"), "pr must be an integer", id="pr text"),
        pytest.param(a_record(pr=True), "pr must be an integer", id="pr boolean"),
        pytest.param(a_record(milestone="3"), "must look like M3", id="milestone"),
        pytest.param(a_record(rounds=[]), "one round at least", id="no round"),
        pytest.param(
            a_record(rounds=[a_round(n=2)]), "rounds are numbered", id="round n"
        ),
        pytest.param(
            a_record(rounds=[a_round(base="v2")]),
            "must be a commit hash, never a branch",
            id="branch as base",
        ),
        pytest.param(
            a_record(rounds=[a_round(date="2026-12-01")]),
            "date must be a date",
            id="date as text",
        ),
        pytest.param(
            a_record(rounds=[a_round(date=dt.datetime(2026, 12, 1, 10, 0))]),
            "date must be a date",
            id="date and time",
        ),
        pytest.param(
            a_record(rounds=[a_round(security_trigger="tools/")]),
            "security_trigger must be a list of strings",
            id="trigger as text",
        ),
        pytest.param(
            a_record(rounds=[a_round(security_trigger=[])]),
            "security ran, so security_trigger says what matched",
            id="security ran without a trigger",
        ),
        pytest.param(
            a_record(rounds=[a_round(security="not triggered")]),
            "security_trigger matched, so security ran",
            id="a trigger but not triggered",
        ),
        pytest.param(
            {**a_record(), "round": {"n": 1}}, "array of tables", id="round table"
        ),
        pytest.param(with_finding(0, line=-1), "line = -1", id="negative line"),
        pytest.param(with_finding(0, picked="yes"), "true or false", id="picked"),
        pytest.param(with_finding(0, summary=" "), "must not be empty", id="blank"),
        pytest.param(with_finding(0, ref=7), "ref must be a string", id="ref type"),
        pytest.param(
            with_finding(0, file="../outside.py"),
            "must be a path from the repository root",
            id="file outside",
        ),
        pytest.param(
            {**a_record(), "finding": ["M3-F01"]}, "must be a table", id="finding text"
        ),
        pytest.param(
            a_record(questions=[a_question(options=["only one"])]),
            "two distinct texts",
            id="one option",
        ),
        pytest.param(
            a_record(questions=[a_question(recommendation="Neither")]),
            "the recommendation must be one of the options",
            id="recommendation",
        ),
        pytest.param(
            a_record(questions=[a_question(findings=[])]),
            "must name one finding at least",
            id="question without finding",
        ),
    ],
)
def test_check_refuses_a_malformed_value(document: object, fragment: str) -> None:
    assert refused(document, fragment)


def test_check_refuses_a_file_that_is_not_a_table() -> None:
    assert refused(["milestone"], "the file: must be a table")


@pytest.mark.parametrize(
    ("index", "changes", "fragment"),
    [
        pytest.param(
            0, {"ref": "S1"}, "a correctness claim keeps its", id="wrong letter"
        ),
        pytest.param(5, {"ref": "C9"}, "a sibling-search finding has none", id="ref"),
        pytest.param(0, {"about": "M3-F02"}, "about is only for", id="about"),
        pytest.param(6, {"about": "M3-F07"}, "about must name", id="about self"),
    ],
)
def test_check_refuses_a_source_and_reference_that_disagree(
    index: int, changes: dict[str, object], fragment: str
) -> None:
    assert refused(with_finding(index, **changes), fragment)


@pytest.mark.parametrize(
    ("index", "round_changes", "fragment"),
    [
        pytest.param(
            2,
            {"security": "not triggered", "security_trigger": []},
            "a security claim",
            id="security",
        ),
        pytest.param(
            2, {"verifier": "not needed"}, "the verifier ran on it", id="verified"
        ),
        pytest.param(
            7, {"verifier": "not needed"}, "the verifier ran on it", id="not confirmed"
        ),
        pytest.param(
            6, {"fix_review": "not needed"}, "a fix-review claim", id="fix review"
        ),
    ],
)
def test_check_refuses_a_header_that_contradicts_a_finding(
    index: int, round_changes: dict[str, object], fragment: str
) -> None:
    del index
    document = a_record(rounds=[a_round(**round_changes)])

    assert refused(document, fragment)
