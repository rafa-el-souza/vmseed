"""`check` decides every document: it accepts it or refuses it, never crashes.

A record can come from any pull request, so its shape is input like any other.
"""

import contextlib
import datetime as dt
from typing import cast

from hypothesis import given
from hypothesis import strategies as st

from tests.support.records import Table, a_record
from tools import findings

KEYS = st.sampled_from(
    [
        *findings.TOP_KEYS,
        *findings.TOP_OPTIONAL_KEYS,
        *findings.ROUND_KEYS,
        *findings.FINDING_KEYS,
        *findings.FINDING_OPTIONAL_KEYS,
        *findings.QUESTION_KEYS,
        "other",
    ]
)
SCALARS = st.one_of(
    st.text(max_size=20),
    st.sampled_from([*findings.PATHS, *findings.EFFECTS, *findings.PLANS, "M3-F01"]),
    st.integers(min_value=-2, max_value=3),
    st.booleans(),
    st.just(dt.date(2026, 12, 1)),
    st.just(dt.datetime(2026, 12, 1, 10, 0)),
    st.just(1.5),
)
VALUES = st.recursive(
    SCALARS,
    lambda inner: (
        st.lists(inner, max_size=3) | st.dictionaries(KEYS, inner, max_size=3)
    ),
    max_leaves=8,
)


def decide(document: object) -> None:
    """Accept or refuse; any other exception fails the property."""
    with contextlib.suppress(findings.RecordError):
        findings.validate(document, stem="m3", name="m3.toml")


@given(st.dictionaries(KEYS, VALUES, max_size=6))
def test_check_decides_any_document(document: dict[str, object]) -> None:
    decide(document)


@given(
    st.sampled_from(["round", "finding", "question"]),
    st.integers(min_value=0, max_value=2),
    KEYS,
    VALUES,
)
def test_check_decides_a_valid_record_with_one_value_changed(
    table: str, index: int, key: str, value: object
) -> None:
    document = a_record()
    tables = cast(list[Table], document[table])
    if index < len(tables):
        tables[index] = {**tables[index], key: value}

    decide(document)
