"""The installed command and the published constraints file (ADR 0020)."""

import subprocess
import sys
from pathlib import Path

import pytest

from tests.support import REPO, require_tool
from vmseed import __version__

pytestmark = pytest.mark.contract

#: How constraints.txt is made from uv.lock: the runtime dependencies at the
#: versions CI tested. No hashes: uv does not check hashes in a constraints
#: file, so they would promise what the install does not do.
EXPORT = (
    "export",
    "--frozen",
    "--format",
    "requirements.txt",
    "--no-dev",
    "--no-emit-project",
    "--no-hashes",
    "--no-header",
)


def test_the_installed_command_prints_the_version() -> None:
    command = Path(sys.executable).parent / "vmseed"

    result = subprocess.run(
        [str(command), "--version"],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )

    assert (result.returncode, result.stdout) == (0, f"vmseed {__version__}\n")


def test_the_constraints_file_is_current_with_the_lock() -> None:
    uv = require_tool("uv")

    result = subprocess.run(
        [uv, *EXPORT],
        cwd=REPO,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    current = (REPO / "constraints.txt").read_text(encoding="utf-8")
    regenerate = f"uv {' '.join(EXPORT)} --output-file constraints.txt"
    assert current == result.stdout, f"constraints.txt is stale: run {regenerate}"
