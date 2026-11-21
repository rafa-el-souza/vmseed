"""The lists inside tools/findings.py equal the tables of docs/spec/11-review.md.

Each test reads one table or block of the specification and compares it with
the tool. When the specification changes, by the user's decision, these
tests fail until the tool follows.
"""

import re
import tomllib

import pytest

from tests.support import REPO
from tools import findings

SPEC = (REPO / "docs" / "spec" / "11-review.md").read_text(encoding="utf-8")


def _lines_outside_code() -> list[tuple[int, str, bool]]:
    lines: list[tuple[int, str, bool]] = []
    in_code = False
    for number, line in enumerate(SPEC.splitlines()):
        if line.startswith("```"):
            in_code = not in_code
        lines.append((number, line, in_code))
    return lines


def section(title: str) -> str:
    """The text under a heading, up to the next heading of its level or above."""
    lines = SPEC.splitlines()
    headings = [
        (number, len(line) - len(line.lstrip("#")), line.lstrip("#").strip())
        for number, line, in_code in _lines_outside_code()
        if line.startswith("#") and not in_code
    ]
    for index, (start, level, text) in enumerate(headings):
        if text == title:
            end = next(
                (n for n, lvl, _ in headings[index + 1 :] if lvl <= level), len(lines)
            )
            return "\n".join(lines[start + 1 : end])
    raise AssertionError(f"no section {title!r} in 11-review.md")


def table(text: str) -> list[list[str]]:
    """The body rows of the first Markdown table in TEXT."""
    rows: list[list[str]] = []
    for line in text.splitlines():
        if line.startswith("|"):
            rows.append([cell.strip() for cell in line.strip().strip("|").split("|")])
        elif rows:
            break
    return rows[2:]


def code(text: str) -> list[str]:
    return re.findall(r"`([^`]+)`", text)


def blocks(text: str) -> list[str]:
    return re.findall(r"```[a-z]*\n(.*?)```", text, re.DOTALL)


def first_column(title: str) -> list[str]:
    return [code(row[0])[0] for row in table(section(title))]


@pytest.mark.parametrize(
    ("title", "listed"),
    [
        ("Path", findings.PATHS),
        ("Effect", findings.EFFECTS),
        ("Clause", findings.CLAUSES),
        ("The plan", findings.PLANS),
        ("Evidence", findings.EVIDENCE),
    ],
)
def test_a_list_of_the_scale_equals_its_table(
    title: str, listed: tuple[str, ...]
) -> None:
    assert tuple(first_column(title)) == listed


def test_what_each_clause_requires_equals_the_clause_table() -> None:
    required: dict[str, tuple[str, str]] = {}
    for row in table(section("Clause")):
        tokens = code(row[2])
        if tokens:
            key, _, value = tokens[0].partition(" = ")
            required[code(row[0])[0]] = (key, value.strip('"'))
    sibling = next(row for row in table(section("Clause")) if "`sibling`" in row[0])

    assert required == findings.CLAUSE_REQUIRES
    assert "`fix` by a clause or by an effect other than `blocked`" in sibling[2]


def test_the_plan_rows_are_the_rules_the_tool_derives() -> None:
    rows = {code(row[0])[0]: row[1] for row in table(section("The plan"))}

    assert rows["question"] == "The finding has a `question`."
    assert rows["fix"] == (
        "A clause holds; or the path is `ordinary` and the effect is not `none`."
    )
    assert rows["record"].startswith("Anything else")


def test_the_attackers_that_exist_equal_the_attackers_table() -> None:
    rows = table(section("Attackers"))
    existing = [code(row[0])[0] for row in rows if row[1] == "yes"]
    absent = [row[0] for row in rows if row[1] == "no"]

    assert tuple(existing) == findings.ATTACKERS
    assert all(not code(name) for name in absent)


def test_the_outcomes_equal_the_outcomes_table() -> None:
    rows = {code(row[0])[0]: row[1] for row in table(section("Outcomes"))}
    fix = code(rows["fix"])
    first_sentence, _, answer_rule = rows["question"].partition(". ")
    record = [token for token in code(rows["record"]) if " = " not in token]

    assert first_sentence.startswith("The same three")
    assert tuple(fix) == findings.OUTCOMES["fix"]
    assert tuple(fix + code(first_sentence)) == findings.OUTCOMES["question"]
    assert tuple(record) == findings.OUTCOMES["record"]
    assert "`picked = true`" in rows["record"]
    exempt = set(code(answer_rule))
    kinds = {findings.outcome_kind(t) for t in findings.OUTCOMES["question"]}
    assert exempt == {"not reproduced", "not confirmed"}
    assert kinds - exempt == set(findings.NEEDS_ANSWER)


def test_the_trigger_equals_the_two_blocks_of_the_specification() -> None:
    paths, patterns = blocks(section("When the security reviewer runs"))

    assert tuple(paths.split()) == findings.TRIGGER_PATHS
    assert tuple(patterns.split()) == findings.TRIGGER_PATTERNS


def test_the_commands_equal_the_tool_table() -> None:
    names = [code(row[0])[0].split()[0] for row in table(section("The tool"))]

    assert tuple(names) == findings.COMMANDS


def _example() -> str:
    return blocks(section("The findings file"))[0]


def test_the_keys_equal_the_example_record() -> None:
    example = tomllib.loads(_example())
    finding_keys = tuple(example["finding"][0])

    assert set(example) == {*findings.TOP_KEYS, *findings.TOP_OPTIONAL_KEYS}
    assert tuple(example["round"][0]) == findings.ROUND_KEYS
    assert finding_keys == findings.FINDING_KEYS
    assert tuple(example["question"][0]) == findings.QUESTION_KEYS


def test_the_optional_finding_keys_equal_the_specification() -> None:
    paragraph = section("The findings file").split("Other keys of a finding")[1]
    paragraph = paragraph.split("\n\n")[0]
    keys = [token for token in code(paragraph) if re.fullmatch(r"[a-z_]+", token)]

    assert tuple(keys) == findings.FINDING_OPTIONAL_KEYS


def test_the_round_values_equal_the_example_comments() -> None:
    values: dict[str, tuple[str, ...]] = {}
    for line in _example().splitlines():
        match = re.match(r'(\w+) = "([^"]*)"\s+# or (.*)', line)
        if match:
            values[match.group(1)] = (
                match.group(2),
                *re.findall(r'"([^"]+)"', line[match.start(3) :]),
            )

    assert values == findings.ROUND_VALUES


def test_the_sources_equal_the_example_comment() -> None:
    text = _example()
    start = text.index('source = "correctness"')
    comment = text[start:].split("\n")[:2]
    sources = [
        word.strip()
        for line in comment
        for word in line.partition("#")[2].split("|")
        if word.strip()
    ]

    assert tuple(sources) == findings.SOURCES


def test_the_reference_letters_equal_the_specification() -> None:
    sentence = section("The findings file").split("A reviewer's own ids")[1]
    named = re.findall(
        r"`([A-Z])` for (?:what )?(?:the )?"
        r"(correctness|security|verifier|fix reviewer)",
        sentence.replace("\n", " "),
    )
    letters = {
        word.replace("fix reviewer", "fix-review"): letter for letter, word in named
    }

    assert letters == findings.REF_PREFIXES


def test_the_identifier_forms_equal_the_specification() -> None:
    text = section("The findings file")

    assert "`M<N>-F<nn>` for findings and `M<N>-Q<n>` for questions" in text
    assert findings.FINDING_ID.fullmatch("M3a-F01")
    assert findings.QUESTION_ID.fullmatch("M3a-Q1")
    assert "`m3a-primitives` gives `docs/findings/m3a.toml` and `M3a-F01`" in (
        text.replace("\n", " ")
    )
