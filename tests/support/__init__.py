"""Helpers shared by the test tiers."""

import os
import shutil
from pathlib import Path

import pytest

#: The repository root, whatever the current directory is.
REPO = Path(__file__).resolve().parents[2]

#: In CI this is "1": a contract test whose tool is missing fails instead of
#: skipping (docs/spec/08-testing.md, "Missing tool policy").
REQUIRE_TOOLS = "VMSEED_REQUIRE_TOOLS"


def require_tool(name: str) -> str:
    """Return the path of a host tool a contract test needs.

    A missing tool skips the test with a visible reason, or fails it when
    VMSEED_REQUIRE_TOOLS=1.
    """
    path = shutil.which(name)
    if path is not None:
        return path
    if os.environ.get(REQUIRE_TOOLS) == "1":
        pytest.fail(f"{name} is not installed, and {REQUIRE_TOOLS}=1 requires it")
    pytest.skip(f"{name} is not installed")
