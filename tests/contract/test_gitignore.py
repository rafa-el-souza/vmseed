"""The .gitignore of v2 keeps a host's files out of the repository (M0)."""

import subprocess
from pathlib import Path

import pytest

from tests.support import REPO, require_tool

pytestmark = pytest.mark.contract

IGNORED = [
    "vmseed.toml",
    "somewhere/vmseed.toml",
    "images/Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2",
    "disk.qcow2",
    "alpine.img",
    "disk.raw",
    "seed.iso",
    "nvram.fd",
    "console.log",
    "vms/dev01/report.log",
    "state/vms/dev01/vmseed.json",
    "vms/dev01/domain.xml",
    "known_hosts",
    "docs/host-checks/output/batch-1.txt",
    "id_ed25519",
    "id_ed25519.pub",
    "client.pem",
    ".venv/bin/python",
    "src/vmseed/__pycache__/cli.cpython-312.pyc",
    ".coverage",
    ".hypothesis/examples/x",
    ".claude/settings.local.json",
    ".claude/worktrees/agent-1/README.md",
]

KEPT = [
    "examples/quickstart/vmseed.toml",
    "tests/e2e/scenarios/alpine-base/vmseed.toml",
    "tests/fixtures/report.log",
    "tests/fixtures/vmseed.json",
    "tests/fixtures/known_hosts",
    "tests/fixtures/vms/dev01/domain.xml",
    "tests/golden/alpine-base/domain.xml",
    "src/vmseed/data/catalog.toml",
    "docs/findings/m0.toml",
    "docs/host-checks/batch-1.md",
    "constraints.txt",
    "uv.lock",
    ".claude/skills/milestone-review/SKILL.md",
]


def ignored(paths: list[str], home: Path) -> dict[str, bool]:
    """Whether .gitignore ignores each path, with no global or system config."""
    environment = {
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(home),
        "GIT_CONFIG_NOSYSTEM": "1",
        "PATH": "/usr/bin:/bin",
    }
    result = subprocess.run(
        [
            *(require_tool("git"), "-C", str(REPO), "check-ignore", "--no-index"),
            *("--verbose", "--non-matching", "--", *paths),
        ],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
        env=environment,
    )
    assert result.returncode in (0, 1), result.stderr
    status: dict[str, bool] = {}
    for line in result.stdout.splitlines():
        source, _, path = line.partition("\t")
        pattern = source.split(":", 2)[-1]
        status[path] = bool(pattern) and not pattern.startswith("!")
    return status


@pytest.mark.parametrize("path", IGNORED)
def test_a_hosts_file_is_ignored(tmp_path: Path, path: str) -> None:
    assert ignored([path], tmp_path) == {path: True}


@pytest.mark.parametrize("path", KEPT)
def test_a_project_file_is_not_ignored(tmp_path: Path, path: str) -> None:
    assert ignored([path], tmp_path) == {path: False}


#: Files the Bash tool told its user to keep in the checkout (its personal
#: config and temp/ at the root, guest diagnostics brought back from a VM),
#: which v0's ignore rules kept out of the repository.
BASH_TOOL_PRIVATE = [
    "fedora-cloud.conf",
    "temp/notes.txt",
    "tools/diagnostics-results/vmseed-diag.txt",
]


@pytest.mark.parametrize("path", BASH_TOOL_PRIVATE)
def test_a_private_file_of_the_bash_tool_is_not_staged_by_add_all(
    tmp_path: Path, path: str
) -> None:
    checkout = tmp_path / "checkout"
    checkout.mkdir()
    (checkout / ".gitignore").write_bytes((REPO / ".gitignore").read_bytes())
    private = checkout / path
    private.parent.mkdir(parents=True, exist_ok=True)
    private.write_text("OVERLAY_IMAGE_DIR=/srv/example/overlays\n", encoding="utf-8")
    env = {
        "HOME": str(tmp_path),
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "PATH": "/usr/bin:/bin",
    }

    def git(*args: str) -> str:
        command = [require_tool("git"), "-C", str(checkout), *args]
        result = subprocess.run(
            command, capture_output=True, text=True, timeout=60, check=True, env=env
        )
        return result.stdout

    git("init", "--quiet")
    staged = git("add", "--all", "--dry-run")

    assert f"add '{path}'" not in staged
