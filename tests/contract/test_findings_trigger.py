"""`findings.py trigger BASE..HEAD` against a real git repository (tier 2)."""

import subprocess
from pathlib import Path

import pytest

from tests.support import require_tool
from tools import findings

pytestmark = pytest.mark.contract


def git(repo: Path, *args: str) -> str:
    command = [require_tool("git"), "-C", str(repo), *args]
    environment = {
        "GIT_AUTHOR_NAME": "test",
        "GIT_AUTHOR_EMAIL": "test@example.org",
        "GIT_COMMITTER_NAME": "test",
        "GIT_COMMITTER_EMAIL": "test@example.org",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "PATH": "/usr/bin:/bin",
    }
    result = subprocess.run(
        command, capture_output=True, text=True, check=True, env=environment
    )
    return result.stdout.strip()


def commit(repo: Path, files: dict[str, str | None], message: str) -> str:
    for name, text in files.items():
        path = repo / name
        if text is None:
            path.unlink()
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    git(repo, "add", "--all")
    git(repo, "commit", "--quiet", "--message", message)
    return git(repo, "rev-parse", "HEAD")


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    git(tmp_path, "init", "--quiet", "--initial-branch=v2")
    commit(
        tmp_path,
        {
            "README.md": "vmseed\n",
            "src/vmseed/plan.py": "import pickle\n",
            "src/vmseed/cli.py": "print('x')\n",
        },
        "base",
    )
    return tmp_path


def test_a_change_under_a_trigger_path_matches(repo: Path) -> None:
    base = git(repo, "rev-parse", "HEAD")
    commit(
        repo,
        {
            "tools/findings.py": "x = 1\n",
            ".github/workflows/ci.yml": "name: ci\n",
            "src/vmseed/state.py": "x = 1\n",
            "src/vmseed/guest/controls/ssh.py": "x = 1\n",
            "docs/spec/notes.md": "subprocess\n",
        },
        "head",
    )

    assert findings.trigger(f"{base}..HEAD", repo) == [
        ".github/workflows/ci.yml",
        "src/vmseed/guest/controls/ssh.py",
        "src/vmseed/state.py",
        "tools/findings.py",
    ]


def test_an_added_line_with_a_pattern_matches_and_names_it(repo: Path) -> None:
    base = git(repo, "rev-parse", "HEAD")
    commit(
        repo,
        {
            "src/vmseed/cli.py": "print('x')\nimport subprocess, shlex\n",
            "src/vmseed/errors.py": "class Error(Exception):\n    pass\n",
            "src/vmseed/notes.py": "x = 1\n++y = eval('2')\n",
        },
        "head",
    )

    assert findings.trigger(f"{base}..HEAD", repo) == [
        "src/vmseed/cli.py: subprocess, shlex",
        "src/vmseed/notes.py: eval(",
    ]


def test_a_removed_line_with_a_pattern_does_not_match(repo: Path) -> None:
    base = git(repo, "rev-parse", "HEAD")
    commit(repo, {"src/vmseed/plan.py": "x = 1\n"}, "drop pickle")

    assert findings.trigger(f"{base}..HEAD", repo) == []


def test_a_deleted_file_under_a_trigger_path_matches(repo: Path) -> None:
    commit(repo, {"examples/quickstart/vmseed.toml": "x = 1\n"}, "add")
    base = git(repo, "rev-parse", "HEAD")
    commit(repo, {"examples/quickstart/vmseed.toml": None}, "remove")

    assert findings.trigger(f"{base}..HEAD", repo) == [
        "examples/quickstart/vmseed.toml"
    ]


def test_the_command_prints_the_matches_one_per_line(
    repo: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    base = git(repo, "rev-parse", "HEAD")
    commit(repo, {"tools/a.py": "1\n", "tools/b.py": "2\n"}, "head")

    status = findings.main(["--root", str(repo), "trigger", f"{base}..HEAD"])

    assert status == 0
    assert capsys.readouterr().out == "tools/a.py\ntools/b.py\n"


def test_the_command_says_not_triggered_on_stderr_only(
    repo: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    base = git(repo, "rev-parse", "HEAD")
    commit(repo, {"README.md": "vmseed v2\n"}, "head")

    status = findings.main(["--root", str(repo), "trigger", f"{base}..HEAD"])

    captured = capsys.readouterr()
    assert status == 0
    assert (captured.out, captured.err) == ("", "not triggered\n")


@pytest.mark.parametrize(
    "revision_range",
    [
        "HEAD",
        "HEAD...HEAD",
        "..HEAD",
        "HEAD..",
        "--output=x..HEAD",
        "HEAD..-p",
        "no-such-branch..HEAD",
        "HEAD..HEAD..HEAD",
    ],
)
def test_a_range_that_is_not_base_dot_dot_head_is_refused(
    repo: Path, revision_range: str
) -> None:
    with pytest.raises(findings.GitError):
        findings.trigger(revision_range, repo)


def test_the_command_reports_a_bad_range_and_exits_2(
    repo: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    status = findings.main(["--root", str(repo), "trigger", "--", "--output=x..HEAD"])

    assert status == 2
    assert capsys.readouterr().err.startswith("findings.py: not a revision")


def test_git_outside_a_repository_is_an_error(tmp_path: Path) -> None:
    with pytest.raises(findings.GitError):
        findings.trigger("HEAD..HEAD", tmp_path)
