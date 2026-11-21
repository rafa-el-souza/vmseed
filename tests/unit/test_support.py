"""The missing tool policy of the contract tier (docs/spec/08-testing.md)."""

import pytest

from tests.support import REQUIRE_TOOLS, require_tool


def test_a_present_tool_is_found() -> None:
    assert require_tool("sh").endswith("/sh")


def test_a_missing_tool_skips_the_test_locally(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv(REQUIRE_TOOLS, raising=False)
    monkeypatch.setenv("PATH", "")
    with pytest.raises(pytest.skip.Exception, match="not installed"):
        require_tool("sh")


def test_a_missing_tool_fails_the_test_when_tools_are_required(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv(REQUIRE_TOOLS, "1")
    monkeypatch.setenv("PATH", "")
    with pytest.raises(pytest.fail.Exception, match="requires it"):
        require_tool("sh")
