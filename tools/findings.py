#!/usr/bin/env python3
"""Check, list, count and summarise a milestone's review record.

The record is ``docs/findings/m<N>.toml``. docs/spec/11-review.md specifies
it, its closed lists, and this tool. Standard library only: CI runs it with
the runner's ``python3``, without installing the project.

Commands:

  check [FILE ...]        refuse a record that breaks the rules of 11
  open [FILE ...]         list what is still open; exit 1 if anything is
  count [FILE ...]        claims per source, by plan and by outcome
  summary FILE            the "Review" section of the pull request
  trigger BASE..HEAD      what in the range sets off the security reviewer
  gate BRANCH             pass when the branch needs no record, or its
                          record exists and is closed

Without FILE, every ``docs/findings/*.toml`` is read.

Exit status: 0 on success; 1 when ``check`` refuses a file, ``open`` finds
something open, or ``gate`` does not pass; 2 for a usage error, for a record
that ``open``, ``count`` or ``summary`` cannot use, and for a failed ``git``.

Two readings of 11 that its text leaves to the tool:

- ``open`` also lists a round whose header is incomplete, because a complete
  header is part of closing the record, and closing ends when ``open`` prints
  nothing.
- A question without an answer is open only while one of its findings is
  open. A finding that ends ``not reproduced`` or ``not confirmed`` needs no
  answer: the user is not asked about a defect nobody confirmed.
"""

import argparse
import datetime as dt
import re
import subprocess
import sys
import tomllib
from collections import Counter
from collections.abc import Iterator, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import cast

ROOT = Path(__file__).resolve().parent.parent
FINDINGS_DIR = Path("docs/findings")

# --------------------------------------------------------------------------
# The lists of docs/spec/11-review.md. A test compares each one with its
# table there: change both together, and only by the user's decision.
# --------------------------------------------------------------------------

#: "Path": what the reproduction needs. Every row but the first is forced.
PATHS = ("ordinary", "hostile", "tool", "race", "failure", "unsupported")

#: "Effect", in the order that decides between two that fit.
EFFECTS = ("lost", "exposed", "misreport", "wrong", "blocked", "none")

#: "Clause", in the order that decides between two that hold.
CLAUSES = ("destructive", "boundary", "decided", "sibling")

#: "Also required" by a clause: the key, and the value it must have if any.
CLAUSE_REQUIRES: dict[str, tuple[str, str]] = {
    "boundary": ("path", "hostile"),
    "decided": ("rule", ""),
    "sibling": ("root", ""),
}

#: "The plan", in the order its rows are tried.
PLANS = ("question", "fix", "record")

#: "Evidence".
EVIDENCE = ("test", "ci", "inspection", "verified")

#: "Attackers" that exist. A claim on a hostile path names one of them.
ATTACKERS = ("guest", "data-dir", "download", "local-user", "contributor")

#: Where a finding comes from.
SOURCES = (
    "correctness",
    "security",
    "verifier",
    "fix-review",
    "sibling-search",
    "user",
    "ci",
)

#: The letter of a reviewer's own ids, which stay in ``ref``.
REF_PREFIXES = {"correctness": "C", "security": "S", "verifier": "V", "fix-review": "R"}

#: The values of a round's header. Empty means the round is still running.
ROUND_VALUES = {
    "correctness": ("ran", "ran: core, edge"),
    "security": ("ran", "not triggered"),
    "verifier": ("not needed", "ran"),
    "fix_review": ("ran", "ran twice", "not needed"),
}

#: "Outcomes": what each plan allows. ``<...>`` is text the record supplies.
_SAME_THREE = ("fixed", "not reproduced", "not confirmed: <the decisive point>")
OUTCOMES = {
    "fix": _SAME_THREE,
    "question": (
        *_SAME_THREE,
        "kept as built: <the decision>",
        "deferred: <where it is tracked>",
    ),
    "record": ("recorded: forced path (<path>)", "recorded: no effect", "fixed"),
}

#: Outcomes of a question's finding that need the user's answer.
NEEDS_ANSWER = ("fixed", "kept as built", "deferred")

# The two trigger lists keep the layout of their blocks in 11, so that the
# two can be read side by side.


def _items(block: str) -> tuple[str, ...]:
    """The items of a block laid out as in 11: two spaces or more apart."""
    return tuple(
        item
        for line in block.split("\n")
        for item in re.split(r" {2,}", line.strip())
        if item
    )


#: The security trigger: a change to a file under one of these paths, ...
TRIGGER_PATHS = _items(
    """
    src/vmseed/host/       src/vmseed/ops/        src/vmseed/guest/
    src/vmseed/catalog/    src/vmseed/data/       src/vmseed/state.py
    src/vmseed/display.py  src/vmseed/templating.py
    src/vmseed/config/loader.py   src/vmseed/config/models.py
    tools/                 examples/              .github/
    pyproject.toml         uv.lock                constraints.txt
    .claude/skills/milestone-review/
    """
)

#: ... or a line added to any other file under src/ containing one of these.
TRIGGER_PATTERNS = _items(
    """
    subprocess  Popen  os.open  os.unlink  os.rename  os.replace  os.chmod
    os.chown  os.umask  shutil.  tempfile.  urllib  shlex  yaml.load  pickle
    eval(  exec(
    from os import  from shutil import  from tempfile import  from yaml import
    """
)

#: The commands of "The tool".
COMMANDS = ("check", "open", "count", "summary", "trigger", "gate")

#: The keys of the file, of a round, of a finding and of a question.
TOP_KEYS = ("milestone", "pr", "round")
TOP_OPTIONAL_KEYS = ("finding", "question")
ROUND_KEYS = (
    "n",
    "base",
    "head",
    "date",
    "correctness",
    "security",
    "security_trigger",
    "verifier",
    "fix_review",
)
FINDING_KEYS = (
    "id",
    "round",
    "source",
    "ref",
    "file",
    "line",
    "summary",
    "scenario",
    "evidence",
    "reproduction",
    "path",
    "effect",
    "clause",
    "rule",
    "plan",
    "outcome",
)
#: Keys of a finding present only when they apply.
FINDING_OPTIONAL_KEYS = (
    "attacker",
    "root",
    "about",
    "unlikely",
    "question",
    "picked",
    "note",
)
QUESTION_KEYS = (
    "id",
    "findings",
    "text",
    "options",
    "recommendation",
    "assumption",
    "answer",
)

MILESTONE = re.compile(r"M\d+[a-z]?")
FINDING_ID = re.compile(r"(?P<milestone>M\d+[a-z]?)-F(?P<n>\d{2,})")
QUESTION_ID = re.compile(r"(?P<milestone>M\d+[a-z]?)-Q(?P<n>\d+)")
COMMIT = re.compile(r"[0-9a-f]{7,40}")

#: A path into somebody's home directory. The record is public (11, "The
#: findings file"): paths are relative to the repository root.
HOME_PATH = re.compile(
    r"""
      (?<![\w.~-])~[\w.-]*/          # ~/x, ~user/x
    | (?<![\w.~-])/(?:home|Users)/[^/\s]
    | (?<![\w.~-])/var/home/[^/\s]
    | (?<![\w.~-])/root(?![\w.-])
    | \$HOME\b | \$\{HOME\}
    | \b[A-Za-z]:\\Users\\
    """,
    re.VERBOSE,
)

#: What the display sanitiser escapes (01, "Untrusted text"): C0 controls
#: other than tab and newline, DEL, and C1 controls.
CONTROL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]")


# --------------------------------------------------------------------------
# The record
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class Round:
    """The header of one review round."""

    n: int
    base: str
    head: str
    date: dt.date
    correctness: str
    security: str
    security_trigger: tuple[str, ...]
    verifier: str
    fix_review: str

    def incomplete(self) -> list[str]:
        """The header keys still empty while the round runs."""
        values = {
            "correctness": self.correctness,
            "security": self.security,
            "verifier": self.verifier,
            "fix_review": self.fix_review,
        }
        return [key for key, value in values.items() if not value]


@dataclass(frozen=True)
class Finding:
    """One claim, its grade, its plan and its outcome."""

    id: str
    round: int
    source: str
    ref: str
    file: str
    line: int
    summary: str
    scenario: str
    evidence: str
    reproduction: str
    path: str
    effect: str
    clause: str
    rule: str
    plan: str
    outcome: str
    attacker: str = ""
    root: str = ""
    about: str = ""
    unlikely: str = ""
    question: str = ""
    picked: bool = False
    note: str = ""


@dataclass(frozen=True)
class Question:
    """A point only the user can decide."""

    id: str
    findings: tuple[str, ...]
    text: str
    options: tuple[str, ...]
    recommendation: str
    assumption: str
    answer: str


@dataclass(frozen=True)
class Record:
    """A review record that passed ``check``."""

    name: str
    milestone: str
    pr: int
    rounds: tuple[Round, ...]
    findings: tuple[Finding, ...]
    questions: tuple[Question, ...]


class RecordError(Exception):
    """A record that ``check`` refuses; ``errors`` says why."""

    def __init__(self, name: str, errors: Sequence[str]) -> None:
        super().__init__(f"{name}: refused")
        self.name = name
        self.errors = tuple(errors)


def derive_plan(*, path: str, effect: str, clause: str, question: str) -> str:
    """The plan a grade gives (11, "The plan"): the first row that holds."""
    if question:
        return "question"
    if clause or (path == "ordinary" and effect != "none"):
        return "fix"
    return "record"


def outcome_kind(template: str) -> str:
    """``not confirmed: <the decisive point>`` -> ``not confirmed``."""
    return template.partition("<")[0].rstrip(" :(")


def _outcome_pattern(template: str) -> re.Pattern[str]:
    before, placeholder, rest = template.partition("<")
    if not placeholder:
        return re.compile(re.escape(template))
    after = rest.partition(">")[2]
    return re.compile(re.escape(before) + r"(?P<detail>.*\S.*)" + re.escape(after))


def parse_outcome(plan: str, outcome: str) -> tuple[str, str] | None:
    """The kind and the supplied text of an outcome the plan allows, or None."""
    for template in OUTCOMES.get(plan, ()):
        match = _outcome_pattern(template).fullmatch(outcome)
        if match:
            detail = match.groupdict().get("detail") or ""
            return outcome_kind(template), detail
    return None


# --------------------------------------------------------------------------
# Reading a table, with every shape error recorded
# --------------------------------------------------------------------------


class _Table:
    """The keys of one TOML table; each read records what is wrong."""

    def __init__(
        self,
        where: str,
        value: object,
        *,
        required: Sequence[str],
        optional: Sequence[str] = (),
        errors: list[str],
    ) -> None:
        self.where = where
        self._errors = errors
        self._items: dict[str, object] = {}
        if not isinstance(value, dict):
            self.error("must be a table")
            return
        self._items = cast(dict[str, object], value)
        for key in self._items:
            if key not in required and key not in optional:
                self.error(f"unknown key {key!r}")
        for key in required:
            if key not in self._items:
                self.error(f"missing key {key!r}")

    def error(self, message: str) -> None:
        self._errors.append(f"{self.where}: {message}")

    def has(self, key: str) -> bool:
        return key in self._items

    def text(self, key: str, *, blank: bool = True) -> str:
        if key not in self._items:
            return ""
        value = self._items[key]
        if not isinstance(value, str):
            self.error(f"{key} must be a string")
            return ""
        if not blank and not value.strip():
            self.error(f"{key} must not be empty")
        return value

    def choice(self, key: str, allowed: Sequence[str], *, empty: bool = False) -> str:
        value = self.text(key)
        if not self.has(key) or (empty and value == "") or value in allowed:
            return value
        if isinstance(self._items[key], str):
            self.error(f"{key} = {value!r} is not one of: {', '.join(allowed)}")
        return ""

    def integer(self, key: str, *, minimum: int) -> int:
        if key not in self._items:
            return minimum
        value = self._items[key]
        if isinstance(value, bool) or not isinstance(value, int):
            self.error(f"{key} must be an integer")
            return minimum
        if value < minimum:
            self.error(f"{key} = {value} must be {minimum} or more")
        return value

    def boolean(self, key: str) -> bool:
        if key not in self._items:
            return False
        value = self._items[key]
        if not isinstance(value, bool):
            self.error(f"{key} must be true or false")
            return False
        return value

    def date(self, key: str) -> dt.date:
        value = self._items.get(key)
        if isinstance(value, dt.date) and not isinstance(value, dt.datetime):
            return value
        if key in self._items:
            self.error(f"{key} must be a date (YYYY-MM-DD)")
        return dt.date.min

    def texts(self, key: str) -> tuple[str, ...]:
        if key not in self._items:
            return ()
        value = self._items[key]
        if isinstance(value, list):
            items = cast(list[object], value)
            strings = [item for item in items if isinstance(item, str)]
            if len(strings) == len(items):
                return tuple(strings)
        self.error(f"{key} must be a list of strings")
        return ()

    def tables(self, key: str) -> list[object]:
        if key not in self._items:
            return []
        value = self._items[key]
        if isinstance(value, list):
            return cast(list[object], value)
        self.error(f"{key} must be an array of tables, [[{key}]]")
        return []


def _peek_id(value: object) -> str:
    if isinstance(value, dict):
        ident = cast(dict[str, object], value).get("id")
        if isinstance(ident, str) and ident:
            return f" ({ident})"
    return ""


def _read_round(index: int, value: object, errors: list[str]) -> Round:
    table = _Table(f"round #{index}", value, required=ROUND_KEYS, errors=errors)
    hashes = {key: table.text(key) for key in ("base", "head")}
    for key, commit in hashes.items():
        if table.has(key) and not COMMIT.fullmatch(commit):
            table.error(f"{key} = {commit!r} must be a commit hash, never a branch")
    return Round(
        n=table.integer("n", minimum=1),
        base=hashes["base"],
        head=hashes["head"],
        date=table.date("date"),
        correctness=table.choice(
            "correctness", ROUND_VALUES["correctness"], empty=True
        ),
        security=table.choice("security", ROUND_VALUES["security"], empty=True),
        security_trigger=table.texts("security_trigger"),
        verifier=table.choice("verifier", ROUND_VALUES["verifier"], empty=True),
        fix_review=table.choice("fix_review", ROUND_VALUES["fix_review"], empty=True),
    )


def _read_finding(index: int, value: object, errors: list[str]) -> Finding:
    table = _Table(
        f"finding #{index}{_peek_id(value)}",
        value,
        required=FINDING_KEYS,
        optional=FINDING_OPTIONAL_KEYS,
        errors=errors,
    )
    file = table.text("file", blank=False)
    if file.startswith(("/", "~")) or "\\" in file or ".." in Path(file).parts:
        table.error(f"file = {file!r} must be a path from the repository root")
    return Finding(
        id=table.text("id", blank=False),
        round=table.integer("round", minimum=1),
        source=table.choice("source", SOURCES),
        ref=table.text("ref"),
        file=file,
        line=table.integer("line", minimum=0),
        summary=table.text("summary", blank=False),
        scenario=table.text("scenario", blank=False),
        evidence=table.choice("evidence", EVIDENCE),
        reproduction=table.text("reproduction", blank=False),
        path=table.choice("path", PATHS),
        effect=table.choice("effect", EFFECTS),
        clause=table.choice("clause", CLAUSES, empty=True),
        rule=table.text("rule"),
        plan=table.choice("plan", PLANS),
        outcome=table.text("outcome"),
        attacker=table.choice("attacker", ATTACKERS, empty=True),
        root=table.text("root"),
        about=table.text("about"),
        unlikely=table.text("unlikely"),
        question=table.text("question"),
        picked=table.boolean("picked"),
        note=table.text("note"),
    )


def _read_question(index: int, value: object, errors: list[str]) -> Question:
    table = _Table(
        f"question #{index}{_peek_id(value)}",
        value,
        required=QUESTION_KEYS,
        errors=errors,
    )
    return Question(
        id=table.text("id", blank=False),
        findings=table.texts("findings"),
        text=table.text("text", blank=False),
        options=table.texts("options"),
        recommendation=table.text("recommendation", blank=False),
        assumption=table.text("assumption", blank=False),
        answer=table.text("answer"),
    )


def _strings(value: object, where: str) -> Iterator[tuple[str, str]]:
    if isinstance(value, str):
        yield where, value
    elif isinstance(value, dict):
        for key, item in cast(dict[str, object], value).items():
            yield from _strings(item, f"{where}.{key}" if where else key)
    elif isinstance(value, list):
        for index, item in enumerate(cast(list[object], value), 1):
            yield from _strings(item, f"{where}[{index}]")


def _text_rules(document: object) -> list[str]:
    errors: list[str] = []
    for where, text in _strings(document, ""):
        if CONTROL.search(text):
            errors.append(f"{where}: contains a control character")
        home = HOME_PATH.search(text)
        if home:
            errors.append(
                f"{where}: contains a home-directory path ({home.group(0)!r}); "
                "write paths from the repository root"
            )
    return errors


# --------------------------------------------------------------------------
# Checking a record
# --------------------------------------------------------------------------


def validate(document: object, *, stem: str, name: str) -> Record:
    """Check a parsed record; raise RecordError with every error found."""
    errors: list[str] = []
    top = _Table(
        "the file",
        document,
        required=TOP_KEYS,
        optional=TOP_OPTIONAL_KEYS,
        errors=errors,
    )
    milestone = top.text("milestone")
    if top.has("milestone"):
        if not MILESTONE.fullmatch(milestone):
            top.error(f"milestone = {milestone!r} must look like M3 or M3a")
        elif stem != milestone.lower():
            top.error(
                f"milestone {milestone} is recorded in {stem}.toml; "
                f"its file is {milestone.lower()}.toml"
            )
    pr = top.integer("pr", minimum=1)
    rounds = [_read_round(i, v, errors) for i, v in enumerate(top.tables("round"), 1)]
    if top.has("round") and not rounds:
        top.error("a record has one round at least")
    findings = [
        _read_finding(i, v, errors) for i, v in enumerate(top.tables("finding"), 1)
    ]
    questions = [
        _read_question(i, v, errors) for i, v in enumerate(top.tables("question"), 1)
    ]
    errors.extend(_text_rules(document))
    if not errors:
        errors.extend(_check_rounds(rounds))
        errors.extend(_check_ids(milestone, findings, questions))
        errors.extend(_check_findings(rounds, findings, questions))
        errors.extend(_check_questions(findings, questions))
    if errors:
        raise RecordError(name, errors)
    return Record(
        name=name,
        milestone=milestone,
        pr=pr,
        rounds=tuple(rounds),
        findings=tuple(findings),
        questions=tuple(questions),
    )


def _check_rounds(rounds: Sequence[Round]) -> list[str]:
    errors: list[str] = []
    for index, round_ in enumerate(rounds, 1):
        where = f"round #{index}"
        if round_.n != index:
            errors.append(f"{where}: n = {round_.n}; rounds are numbered 1, 2, ...")
        if round_.security == "ran" and not round_.security_trigger:
            errors.append(
                f"{where}: security ran, so security_trigger says what matched"
            )
        if round_.security == "not triggered" and round_.security_trigger:
            errors.append(f"{where}: security_trigger matched, so security ran")
    return errors


def _check_ids(
    milestone: str, findings: Sequence[Finding], questions: Sequence[Question]
) -> list[str]:
    errors: list[str] = []
    kinds: tuple[
        tuple[str, Sequence[Finding] | Sequence[Question], re.Pattern[str]], ...
    ]
    kinds = (("finding", findings, FINDING_ID), ("question", questions, QUESTION_ID))
    for kind, items, pattern in kinds:
        seen: set[str] = set()
        for index, item in enumerate(items, 1):
            expected = (
                f"{milestone}-F{index:02d}"
                if kind == "finding"
                else f"{milestone}-Q{index}"
            )
            match = pattern.fullmatch(item.id)
            if item.id in seen:
                errors.append(f"{kind} #{index}: duplicate id {item.id}")
            elif not match:
                errors.append(f"{kind} #{index}: id {item.id!r} is not like {expected}")
            elif match.group("milestone") != milestone:
                errors.append(
                    f"{kind} #{index}: id {item.id} is foreign: this record is "
                    f"{milestone}'s"
                )
            elif item.id != expected:
                errors.append(
                    f"{kind} #{index}: id {item.id} is out of order; ids follow "
                    f"the order of recording, so this one is {expected}"
                )
            seen.add(item.id)
    return errors


def _check_findings(
    rounds: Sequence[Round],
    findings: Sequence[Finding],
    questions: Sequence[Question],
) -> list[str]:
    errors: list[str] = []
    by_id = {finding.id: finding for finding in findings}
    questions_by_id = {question.id: question for question in questions}
    rounds_by_n = {round_.n: round_ for round_ in rounds}
    for finding in findings:
        problems = _finding_problems(finding, by_id, questions_by_id, rounds_by_n)
        errors.extend(f"finding {finding.id}: {problem}" for problem in problems)
    return errors


def _finding_problems(
    finding: Finding,
    findings: dict[str, Finding],
    questions: dict[str, Question],
    rounds: dict[int, Round],
) -> list[str]:
    problems: list[str] = []
    if finding.round not in rounds:
        problems.append(f"round = {finding.round} names no round of this record")
    prefix = REF_PREFIXES.get(finding.source)
    if prefix and not re.fullmatch(rf"{prefix}\d+", finding.ref):
        problems.append(
            f"ref = {finding.ref!r}: a {finding.source} claim keeps its "
            f"reviewer's id, {prefix}1, {prefix}2, ..."
        )
    if not prefix and finding.ref:
        problems.append(f"ref is a reviewer's id; a {finding.source} finding has none")
    problems.extend(_grade_problems(finding, findings))
    if finding.source == "fix-review":
        if finding.about not in findings or finding.about == finding.id:
            problems.append("about must name the finding whose fix this claim is about")
    elif finding.about:
        problems.append("about is only for a claim of the fix reviewer")
    if finding.question:
        question = questions.get(finding.question)
        if question is None:
            problems.append(f"question = {finding.question} names no question")
        elif finding.id not in question.findings:
            problems.append(f"question {finding.question} does not list this finding")
    derived = derive_plan(
        path=finding.path,
        effect=finding.effect,
        clause=finding.clause,
        question=finding.question,
    )
    if finding.plan != derived:
        problems.append(f"plan = {finding.plan}, but its grade gives {derived}")
    elif finding.picked and finding.plan != "record":
        problems.append("picked is for a finding planned record")
    else:
        problems.extend(_outcome_problems(finding, questions))
    round_ = rounds.get(finding.round)
    if round_ is not None:
        problems.extend(_header_problems(finding, round_))
    return problems


def _grade_problems(finding: Finding, findings: dict[str, Finding]) -> list[str]:
    problems: list[str] = []
    if finding.path == "hostile" and not finding.attacker:
        problems.append("a hostile path names its attacker")
    if finding.path != "hostile" and finding.attacker:
        problems.append("attacker is only for path = hostile")
    requires = CLAUSE_REQUIRES.get(finding.clause)
    if requires:
        key, value = requires
        actual = str(getattr(finding, key)).strip()
        if (value and actual != value) or not actual:
            wanted = f"{key} = {value!r}" if value else key
            problems.append(f"clause = {finding.clause} requires {wanted}")
    if finding.clause == "sibling":
        root = findings.get(finding.root)
        if root is None or root.id == finding.id:
            problems.append("root must name another finding of this record")
        elif not (
            root.clause
            or (root.path == "ordinary" and root.effect not in ("none", "blocked"))
        ):
            problems.append(
                f"root {root.id} is planned fix neither by a clause nor by an "
                "effect other than blocked"
            )
    elif finding.root:
        problems.append("root is only for clause = sibling")
    return problems


def _outcome_problems(finding: Finding, questions: dict[str, Question]) -> list[str]:
    if not finding.outcome:
        return []
    parsed = parse_outcome(finding.plan, finding.outcome)
    if parsed is None:
        allowed = " | ".join(OUTCOMES[finding.plan])
        return [
            f"outcome {finding.outcome!r} is not allowed by plan = "
            f"{finding.plan}: {allowed}"
        ]
    kind, detail = parsed
    question = questions.get(finding.question)
    answered = question is not None and bool(question.answer.strip())
    problems: list[str] = []
    if finding.plan == "question" and kind in NEEDS_ANSWER and not answered:
        problems.append(f"outcome {kind} needs the user's answer in its question")
    if kind == "recorded: forced path":
        if finding.path == "ordinary":
            problems.append("the path is ordinary, not forced")
        elif detail != finding.path:
            problems.append(
                f"the outcome names path {detail!r}; the finding's is {finding.path}"
            )
    if kind == "recorded: no effect" and finding.effect != "none":
        problems.append(
            f"the outcome says no effect; the finding's is {finding.effect}"
        )
    if kind == "not reproduced" and finding.evidence == "inspection":
        problems.append("not reproduced means a test was written first: not inspection")
    if kind == "fixed" and finding.plan == "record" and not finding.picked:
        problems.append("a finding planned record is fixed only if the user picked it")
    if finding.picked and kind != "fixed":
        problems.append(f"the user picked it, so it ends fixed, not {kind}")
    if (
        kind == "fixed"
        and finding.evidence == "inspection"
        and not (answered or finding.picked)
    ):
        problems.append(
            "fixed on inspection alone: the verifier rebuilds it first "
            "(evidence verified), unless the user decided the fix"
        )
    return problems


def _header_problems(finding: Finding, round_: Round) -> list[str]:
    problems: list[str] = []
    if finding.source == "security" and round_.security == "not triggered":
        problems.append(f"a security claim, but round {round_.n} says not triggered")
    kind = (parse_outcome(finding.plan, finding.outcome) or ("", ""))[0]
    verifier_ran = finding.source == "verifier" or finding.evidence == "verified"
    if (verifier_ran or kind == "not confirmed") and round_.verifier == "not needed":
        problems.append(f"the verifier ran on it, but round {round_.n} says not needed")
    if finding.source == "fix-review" and round_.fix_review == "not needed":
        problems.append(f"a fix-review claim, but round {round_.n} says not needed")
    return problems


def _check_questions(
    findings: Sequence[Finding], questions: Sequence[Question]
) -> list[str]:
    errors: list[str] = []
    by_id = {finding.id: finding for finding in findings}
    for question in questions:
        where = f"question {question.id}"
        if not question.findings:
            errors.append(f"{where}: findings must name one finding at least")
        for finding_id in question.findings:
            finding = by_id.get(finding_id)
            if finding is None:
                errors.append(f"{where}: {finding_id} is foreign: no such finding")
            elif finding.question != question.id:
                errors.append(f"{where}: finding {finding_id} does not name it")
        options = [option for option in question.options if option.strip()]
        if len(options) != len(question.options) or len(set(options)) < 2:
            errors.append(f"{where}: options must be two distinct texts at least")
        if question.recommendation not in question.options:
            errors.append(f"{where}: the recommendation must be one of the options")
    return errors


def load(path: Path, name: str) -> Record:
    """Read and check one record."""
    try:
        document = tomllib.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise RecordError(name, [f"cannot read it: {error.strerror}"]) from error
    except UnicodeDecodeError as error:
        raise RecordError(name, ["is not UTF-8"]) from error
    except tomllib.TOMLDecodeError as error:
        raise RecordError(name, [f"is not valid TOML: {error}"]) from error
    return validate(document, stem=path.stem, name=name)


# --------------------------------------------------------------------------
# open, count, summary
# --------------------------------------------------------------------------


def open_items(record: Record) -> list[str]:
    """What keeps the record open: headers, findings and questions."""
    items: list[str] = []
    for round_ in record.rounds:
        missing = round_.incomplete()
        if missing:
            items.append(f"round {round_.n}: header incomplete: {', '.join(missing)}")
    open_findings = {finding.id for finding in record.findings if not finding.outcome}
    items.extend(
        f"{finding.id}: no outcome (plan {finding.plan}): {finding.summary}"
        for finding in record.findings
        if finding.id in open_findings
    )
    items.extend(
        f"{question.id}: no answer: {question.text}"
        for question in record.questions
        if not question.answer.strip()
        and any(finding_id in open_findings for finding_id in question.findings)
    )
    return items


def _kind(finding: Finding) -> str:
    parsed = parse_outcome(finding.plan, finding.outcome) if finding.outcome else None
    return parsed[0] if parsed else "open"


def _outcome_kinds() -> list[str]:
    kinds: list[str] = []
    for templates in OUTCOMES.values():
        for template in templates:
            kind = outcome_kind(template)
            if kind not in kinds:
                kinds.append(kind)
    return [*kinds, "open"]


def _table(header: Sequence[str], rows: Sequence[Sequence[object]]) -> list[str]:
    lines = [
        "| " + " | ".join(header) + " |",
        "|" + "|".join(["---", *["---:"] * (len(header) - 1)]) + "|",
    ]
    lines.extend("| " + " | ".join(str(cell) for cell in row) + " |" for row in rows)
    return lines


def count(records: Sequence[Record]) -> str:
    """Claims per source, by plan and by outcome, across the records."""
    names = ", ".join(record.name for record in records) or "none"
    findings = [finding for record in records for finding in record.findings]
    lines = [f"Records: {names}", "", *_count_lines(findings)]
    return "\n".join(lines) + "\n"


def _count_lines(findings: Sequence[Finding]) -> list[str]:
    sources = [s for s in SOURCES if any(f.source == s for f in findings)]
    plans = Counter((f.source, f.plan) for f in findings)
    outcomes = Counter((f.source, _kind(f)) for f in findings)
    kinds = _outcome_kinds()
    claims = Counter(f.source for f in findings)
    lines = ["Claims by plan", ""]
    rows: list[list[object]] = [
        [s, claims[s], *(plans[(s, p)] for p in PLANS)] for s in sources
    ]
    rows.append(
        ["total", len(findings), *(sum(plans[(s, p)] for s in sources) for p in PLANS)]
    )
    lines.extend(_table(["source", "claims", *PLANS], rows))
    lines.extend(["", "Claims by outcome", ""])
    rows = [[s, *(outcomes[(s, k)] for k in kinds)] for s in sources]
    rows.append(["total", *(sum(outcomes[(s, k)] for s in sources) for k in kinds)])
    lines.extend(_table(["source", *kinds], rows))
    unlikely = sum(1 for f in findings if f.unlikely)
    lines.extend(["", f"Claims the reviewer marked unlikely: {unlikely}"])
    return lines


def summary(record: Record) -> str:
    """The "Review" section of the pull request (11, "Closing")."""
    lines = [
        "## Review",
        "",
        f"Milestone {record.milestone}, pull request #{record.pr}. "
        f"The record is `{record.name}`.",
        "",
    ]
    rows: list[list[object]] = [
        [
            r.n,
            f"`{r.base}..{r.head}`",
            r.date.isoformat(),
            r.correctness or "running",
            r.security or "running",
            r.verifier or "running",
            r.fix_review or "running",
        ]
        for r in record.rounds
    ]
    header = [
        "round",
        "range",
        "date",
        "correctness",
        "security",
        "verifier",
        "fix review",
    ]
    lines.extend(_table(header, rows))
    lines.append("")
    for round_ in record.rounds:
        if round_.security_trigger:
            matched = ", ".join(f"`{item}`" for item in round_.security_trigger)
            lines.append(f"Security trigger, round {round_.n}: matched {matched}.")
        else:
            lines.append(f"Security trigger, round {round_.n}: did not match.")
    lines.extend(["", "### Counts", "", *_count_lines(record.findings)])
    lines.extend(_summary_questions(record))
    lines.extend(_summary_findings(record))
    return "\n".join(lines).rstrip("\n") + "\n"


def _summary_questions(record: Record) -> list[str]:
    if not record.questions:
        return ["", "### Questions", "", "None."]
    lines = ["", "### Questions", ""]
    open_findings = {f.id for f in record.findings if not f.outcome}
    for question in record.questions:
        if question.answer.strip():
            answer = question.answer
        elif any(f in open_findings for f in question.findings):
            answer = "not answered yet"
        else:
            answer = "not asked: no finding needed the answer"
        about = ", ".join(question.findings)
        lines.extend(
            [
                f"- **{question.id}** ({about}): {question.text}",
                f"  - Options: {'; '.join(question.options)}",
                f"  - Recommendation: {question.recommendation}",
                f"  - Assumption applied: {question.assumption}",
                f"  - Answer: {answer}",
            ]
        )
    return lines


def _summary_findings(record: Record) -> list[str]:
    sections: dict[str, list[str]] = {
        "Fixed": [],
        "Decided by the user": [],
        "Recorded, not fixed": [],
        "Not reproduced or not confirmed": [],
        "Open": [],
    }
    for f in record.findings:
        kind = _kind(f)
        if kind == "fixed":
            picked = " (picked by the user)" if f.picked else ""
            sections["Fixed"].append(f"- {f.id}{picked}: {f.summary}")
        elif kind in ("kept as built", "deferred"):
            sections["Decided by the user"].append(
                f"- {f.id}: {f.summary} Outcome: {f.outcome}."
            )
        elif kind.startswith("recorded"):
            condition = f"path {f.path}, effect {f.effect}"
            unlikely = f" Unlikely: {f.unlikely}" if f.unlikely else ""
            sections["Recorded, not fixed"].append(
                f"- {f.id}: {f.summary} ({condition}; {f.outcome}).{unlikely}"
            )
        elif kind == "not reproduced":
            sections["Not reproduced or not confirmed"].append(
                f"- {f.id}: {f.summary} Not reproduced: the test written first "
                f"did not fail ({f.reproduction})."
            )
        elif kind == "not confirmed":
            sections["Not reproduced or not confirmed"].append(
                f"- {f.id}: {f.summary} {f.outcome[0].upper()}{f.outcome[1:]}."
            )
        else:
            sections["Open"].append(f"- {f.id}: {f.summary}")
    lines: list[str] = []
    for title, items in sections.items():
        if items or title != "Open":
            lines.extend(["", f"### {title}", "", *(items or ["None."])])
    return lines


# --------------------------------------------------------------------------
# trigger
# --------------------------------------------------------------------------

REVISION = re.compile(r"[\w][\w./@{}^~-]*")


class GitError(Exception):
    """git failed, or a revision is not one."""


def _git(root: Path, *args: str) -> bytes:
    command = ["git", "-C", str(root), "-c", "core.quotePath=false", *args]
    try:
        result = subprocess.run(command, capture_output=True, check=False, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise GitError(f"cannot run git: {error}") from error
    if result.returncode != 0:
        message = result.stderr.decode("utf-8", "replace").strip()
        raise GitError(f"git {args[0]} failed: {_safe(message)}")
    return result.stdout


def _commit(root: Path, revision: str) -> str:
    if not REVISION.fullmatch(revision) or ".." in revision:
        raise GitError(f"not a revision: {revision!r}")
    output = _git(
        root, "rev-parse", "--verify", "--end-of-options", f"{revision}^{{commit}}"
    )
    return output.decode("ascii").strip()


def trigger(revision_range: str, root: Path) -> list[str]:
    """What in BASE..HEAD matches the security trigger (11)."""
    base, separator, head = revision_range.partition("..")
    if not separator or not base or not head or head.startswith("."):
        raise GitError(f"expected BASE..HEAD, got {revision_range!r}")
    base_commit, head_commit = _commit(root, base), _commit(root, head)
    changed = _git(
        root, "diff", "--name-only", "--no-renames", "-z", base_commit, head_commit
    )
    matches: list[str] = []
    for raw in changed.split(b"\0"):
        if not raw:
            continue
        name = raw.decode("utf-8", "surrogateescape")
        shown = _safe(raw.decode("utf-8", "replace"))
        if any(
            name.startswith(p) if p.endswith("/") else name == p for p in TRIGGER_PATHS
        ):
            matches.append(shown)
        elif name.startswith("src/"):
            found = _patterns_added(root, base_commit, head_commit, name)
            if found:
                matches.append(f"{shown}: {', '.join(found)}")
    return matches


def _patterns_added(root: Path, base: str, head: str, name: str) -> list[str]:
    diff = _git(
        root,
        "diff",
        "--unified=0",
        "--no-renames",
        "--no-color",
        "--no-ext-diff",
        "--no-textconv",
        "--text",
        base,
        head,
        "--",
        name,
    )
    added: list[str] = []
    in_hunk = False
    # git ends a line at "\n" only; str.splitlines() would also break it at a
    # form feed, a lone CR, NEL or U+2028, and lose what follows.
    for line in diff.decode("utf-8", "replace").split("\n"):
        if line.startswith("@@"):
            in_hunk = True
        elif in_hunk and line.startswith("+"):
            added.append(line[1:])
    return [p for p in TRIGGER_PATTERNS if any(p in line for line in added)]


# --------------------------------------------------------------------------
# gate
# --------------------------------------------------------------------------

MILESTONE_BRANCH = re.compile(r"m(?P<n>\d+)(?P<slice>[a-z]?)(?:[-_/.].*)?", re.I | re.S)


def _safe(text: str) -> str:
    """Escape what a terminal or a log would interpret."""
    return CONTROL.sub(lambda match: f"\\x{ord(match.group(0)):02x}", text)


def gate(branch: str, root: Path) -> tuple[bool, list[str]]:
    """Whether the approval may be requested for BRANCH, and why."""
    shown = _safe(branch)
    if not re.match(r"m\d", branch, re.I):
        return True, [
            f"Branch {shown!r} is not a milestone's branch (m<N>-<slug>): "
            "no review record is required."
        ]
    match = MILESTONE_BRANCH.fullmatch(branch)
    if match is None:
        return False, [
            f"Branch {shown!r} looks like a milestone's branch but is not "
            "m<N>-<slug>: rename it, so its review record can be found."
        ]
    stem = f"m{int(match.group('n'))}{match.group('slice').lower()}"
    relative = FINDINGS_DIR / f"{stem}.toml"
    path = root / relative
    where = f"Branch {shown!r} is milestone M{stem[1:]}'s"
    expected = "This job stays red until the review session closes the record."
    if not path.is_file():
        return False, [
            f"{where}: its review record {relative} does not exist yet.",
            expected,
        ]
    try:
        record = load(path, str(relative))
    except RecordError as error:
        return False, [
            f"{where}: its review record {relative} is refused:",
            *(f"  - {e}" for e in error.errors),
        ]
    items = open_items(record)
    if items:
        return False, [
            f"{where}: its review record {relative} is still open:",
            *(f"  - {item}" for item in items),
            expected,
        ]
    return True, [f"{where}: its review record {relative} is closed."]


# --------------------------------------------------------------------------
# Command line
# --------------------------------------------------------------------------


def _records(files: Sequence[Path], root: Path) -> list[tuple[Path, str]]:
    if not files:
        found = sorted((root / FINDINGS_DIR).glob("*.toml"))
        return [(path, str(path.relative_to(root))) for path in found]
    named: list[tuple[Path, str]] = []
    for file in files:
        try:
            name = str(file.resolve().relative_to(root.resolve()))
        except ValueError:
            name = str(file)
        named.append((file, name))
    return named


def _load_all(files: Sequence[Path], root: Path) -> list[Record]:
    records: list[Record] = []
    for path, name in _records(files, root):
        records.append(load(path, name))
    return records


def _print_refusal(error: RecordError) -> None:
    print(f"{error.name}: refused")
    for message in error.errors:
        print(f"  - {message}")


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="findings.py",
        description=(__doc__ or "").split("\n\n")[0],
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=ROOT,
        help="the repository root (default: the parent of tools/)",
    )
    commands = parser.add_subparsers(dest="command", required=True)
    for name, text in (
        ("check", "refuse a record that breaks the rules of docs/spec/11-review.md"),
        ("open", "list what is still open; exit 1 if anything is"),
        ("count", "claims per source, by plan and by outcome"),
    ):
        command = commands.add_parser(name, help=text)
        command.add_argument("files", nargs="*", type=Path, metavar="FILE")
    command = commands.add_parser("summary", help="the Review section of the PR")
    command.add_argument("file", type=Path, metavar="FILE")
    command = commands.add_parser("trigger", help="what sets off the security reviewer")
    command.add_argument("range", metavar="BASE..HEAD")
    command = commands.add_parser("gate", help="whether the approval may be requested")
    command.add_argument("branch", metavar="BRANCH")
    args = parser.parse_args(argv)
    root: Path = args.root
    match args.command:
        case "check":
            return _check(args.files, root)
        case "trigger":
            try:
                matches = trigger(args.range, root)
            except GitError as error:
                print(f"findings.py: {error}", file=sys.stderr)
                return 2
            for line in matches:
                print(line)
            if not matches:
                print("not triggered", file=sys.stderr)
            return 0
        case "gate":
            passed, lines = gate(args.branch, root)
            print("\n".join(lines))
            return 0 if passed else 1
        case _:
            return _report(args.command, args, root)


def _check(files: Sequence[Path], root: Path) -> int:
    named = _records(files, root)
    if not named:
        print(f"No review record under {FINDINGS_DIR}/.")
        return 0
    status = 0
    for path, name in named:
        try:
            load(path, name)
        except RecordError as error:
            _print_refusal(error)
            status = 1
        else:
            print(f"{name}: ok")
    return status


def _report(command: str, args: argparse.Namespace, root: Path) -> int:
    files: list[Path] = [args.file] if command == "summary" else args.files
    try:
        records = _load_all(files, root)
    except RecordError as error:
        _print_refusal(error)
        return 2
    if command == "count":
        print(count(records), end="")
        return 0
    if command == "summary":
        print(summary(records[0]), end="")
        return 0
    status = 0
    for record in records:
        for item in open_items(record):
            print(f"{record.name}: {item}")
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
