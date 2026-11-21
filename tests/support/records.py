"""Review records for the tests of tools/findings.py.

`a_record()` is a closed, valid record of milestone M3 that walks most rules
of docs/spec/11-review.md: each test changes one thing in it.
"""

import datetime as dt
import json
from collections.abc import Sequence
from pathlib import Path
from typing import cast

type Table = dict[str, object]


def a_round(**changes: object) -> Table:
    table: Table = {
        "n": 1,
        "base": "3f2c1ab",
        "head": "9d41e07",
        "date": dt.date(2026, 12, 1),
        "correctness": "ran",
        "security": "ran",
        "security_trigger": ["src/vmseed/guest/controls/ssh.py"],
        "verifier": "ran",
        "fix_review": "ran",
    }
    return {**table, **changes}


def a_finding(number: int, **changes: object) -> Table:
    table: Table = {
        "id": f"M3-F{number:02d}",
        "round": 1,
        "source": "correctness",
        "ref": f"C{number}",
        "file": "src/vmseed/guest/controls/ssh.py",
        "line": 88,
        "summary": "SSH-07 passes when the guest serves two host keys.",
        "scenario": "A guest with an ed25519 and an RSA host key reports SSH-07 ok.",
        "evidence": "test",
        "reproduction": "tests/unit/guest/test_ssh.py::test_two_host_keys_fail",
        "path": "ordinary",
        "effect": "misreport",
        "clause": "decided",
        "rule": "03 SSH-07",
        "plan": "fix",
        "outcome": "fixed",
    }
    return {**table, **changes}


def a_question(**changes: object) -> Table:
    table: Table = {
        "id": "M3-Q1",
        "findings": ["M3-F02"],
        "text": "The specification does not say what list shows for a lost data dir.",
        "options": ["Show it as drifted", "Refuse with exit 5"],
        "recommendation": "Show it as drifted",
        "assumption": "Shown as drifted",
        "answer": "Show it as drifted.",
    }
    return {**table, **changes}


def the_findings() -> list[Table]:
    """One finding per kind of grade and outcome, all closed."""
    return [
        a_finding(1),
        a_finding(
            2,
            effect="none",
            clause="",
            rule="",
            question="M3-Q1",
            plan="question",
            outcome="kept as built: shown as drifted",
        ),
        a_finding(
            3,
            source="security",
            ref="S1",
            evidence="verified",
            path="hostile",
            attacker="guest",
            effect="exposed",
            clause="boundary",
            rule="",
        ),
        a_finding(
            4,
            path="tool",
            effect="wrong",
            clause="",
            rule="",
            plan="record",
            outcome="recorded: forced path (tool)",
        ),
        a_finding(
            5,
            effect="none",
            clause="",
            rule="",
            plan="record",
            outcome="recorded: no effect",
            unlikely="Two runs a second apart.",
        ),
        a_finding(6, source="sibling-search", ref="", clause="sibling", root="M3-F01"),
        a_finding(
            7,
            source="fix-review",
            ref="R1",
            about="M3-F01",
            effect="wrong",
            clause="",
            rule="",
            outcome="not reproduced",
        ),
        a_finding(
            8,
            evidence="inspection",
            effect="wrong",
            clause="",
            rule="",
            outcome="not confirmed: the lock is taken before the check",
        ),
    ]


def a_record(
    *,
    rounds: Sequence[Table] | None = None,
    findings: Sequence[Table] | None = None,
    questions: Sequence[Table] | None = None,
    **top: object,
) -> Table:
    record: Table = {"milestone": "M3", "pr": 12, **top}
    record["round"] = list(rounds) if rounds is not None else [a_round()]
    record["finding"] = list(findings) if findings is not None else the_findings()
    record["question"] = list(questions) if questions is not None else [a_question()]
    return record


def replace(tables: Sequence[Table], index: int, **changes: object) -> list[Table]:
    """The tables with one of them changed; a value of None removes its key."""
    changed = [dict(table) for table in tables]
    for key, value in changes.items():
        if value is None:
            changed[index].pop(key, None)
        else:
            changed[index][key] = value
    return changed


def _value(value: object) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int | str):
        return json.dumps(value)
    if isinstance(value, dt.date):
        return value.isoformat()
    if isinstance(value, list):
        items = cast(list[object], value)
        return "[" + ", ".join(_value(item) for item in items) + "]"
    raise TypeError(f"no TOML for {value!r}")


def to_toml(document: Table) -> str:
    """The TOML text of a record: scalars first, then arrays of tables."""
    lines: list[str] = []
    arrays: list[tuple[str, list[Table]]] = []
    for key, value in document.items():
        if key in ("round", "finding", "question") and isinstance(value, list):
            arrays.append((key, cast(list[Table], value)))
        else:
            lines.append(f"{key} = {_value(value)}")
    for key, tables in arrays:
        for table in tables:
            lines.extend(["", f"[[{key}]]"])
            lines.extend(f"{name} = {_value(value)}" for name, value in table.items())
    return "\n".join(lines) + "\n"


def write(directory: Path, document: Table, name: str = "m3.toml") -> Path:
    path = directory / "docs" / "findings" / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(to_toml(document), encoding="utf-8")
    return path
