"""The command line skeleton: `vmseed --version` (M0)."""

import runpy
import sys
import tomllib

import pytest
from typer.testing import CliRunner

from tests.support import REPO
from vmseed import __version__
from vmseed.cli import app


def test_version_prints_the_package_version() -> None:
    result = CliRunner().invoke(app, ["--version"])

    assert result.exit_code == 0
    assert result.output == f"vmseed {__version__}\n"


def test_the_version_comes_from_the_project_metadata() -> None:
    project = tomllib.loads((REPO / "pyproject.toml").read_text(encoding="utf-8"))

    assert __version__ == project["project"]["version"]


def test_no_arguments_prints_the_usage_and_exits_2() -> None:
    result = CliRunner().invoke(app, [])

    assert result.exit_code == 2
    assert "Usage:" in result.output
    assert "--version" in result.output


def test_an_unknown_command_is_a_usage_error() -> None:
    result = CliRunner().invoke(app, ["start", "dev01"])

    assert result.exit_code == 2
    assert "No such command 'start'" in result.output


def test_python_dash_m_runs_the_command_line(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(sys, "argv", ["vmseed", "--version"])

    with pytest.raises(SystemExit) as stopped:
        runpy.run_module("vmseed", run_name="__main__")

    assert stopped.value.code == 0
    assert capsys.readouterr().out == f"vmseed {__version__}\n"
