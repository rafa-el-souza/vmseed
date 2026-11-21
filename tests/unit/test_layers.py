"""The import rule between layers (docs/spec/01-architecture.md).

`config`, `catalog`, `guest` and `plan` never import `host`, `ops` or `cli`;
`host` never imports `ops`. Importing a module runs every module it imports,
and the `__init__` of every package above them, so the rule is checked on
what a module reaches, not only on what it names. Imports inside functions
and under `TYPE_CHECKING` count. A dynamic import counts by the module it
names; one whose name is not a literal is refused in a restricted layer.
"""

import ast
from collections import deque
from pathlib import Path

import pytest

from tests.support import REPO

FORBIDDEN = {
    "config": frozenset({"host", "ops", "cli"}),
    "catalog": frozenset({"host", "ops", "cli"}),
    "guest": frozenset({"host", "ops", "cli"}),
    "plan": frozenset({"host", "ops", "cli"}),
    "host": frozenset({"ops"}),
}

#: Stands for a dynamic import whose module name is not a literal.
UNKNOWN = "<a module named at run time>"


def layer_of(module: str) -> str | None:
    parts = module.split(".")
    if len(parts) > 1 and parts[0] == "vmseed":
        return parts[1]
    return None


def with_parents(module: str) -> set[str]:
    parts = module.split(".")
    return {".".join(parts[:end]) for end in range(1, len(parts) + 1)}


def modules_under(src: Path) -> dict[str, Path]:
    modules: dict[str, Path] = {}
    for path in sorted(src.rglob("*.py")):
        parts = path.relative_to(src.parent).with_suffix("").parts
        if parts[-1] == "__init__":
            parts = parts[:-1]
        modules[".".join(parts)] = path
    return modules


def _is_dynamic_import(call: ast.Call) -> bool:
    function = call.func
    if isinstance(function, ast.Name):
        return function.id == "__import__"
    return isinstance(function, ast.Attribute) and function.attr == "import_module"


def imports_of(module: str, path: Path, known: set[str]) -> set[str]:
    """The vmseed modules that importing MODULE runs directly."""
    is_package = path.name == "__init__.py"
    package = module if is_package else module.rpartition(".")[0]
    found = with_parents(module) - {module}
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                found |= with_parents(alias.name)
        elif isinstance(node, ast.ImportFrom):
            if node.level:
                anchor = package.split(".")
                anchor = anchor[: len(anchor) - (node.level - 1)]
                base = ".".join([*anchor, *([node.module] if node.module else [])])
            else:
                base = node.module or ""
            found |= with_parents(base)
            found |= {f"{base}.{a.name}" for a in node.names} & known
        elif isinstance(node, ast.Call) and _is_dynamic_import(node):
            name = node.args[0] if node.args else None
            if isinstance(name, ast.Constant) and isinstance(name.value, str):
                found |= with_parents(name.value)
            else:
                found.add(UNKNOWN)
    return {m for m in found if m == UNKNOWN or m.split(".")[0] == "vmseed"}


def violations(src: Path) -> list[str]:
    """Each restricted module that reaches a layer it must not import."""
    modules = modules_under(src)
    known = set(modules)
    graph = {name: imports_of(name, path, known) for name, path in modules.items()}
    found: list[str] = []
    for start in modules:
        forbidden = FORBIDDEN.get(layer_of(start) or "")
        if not forbidden:
            continue
        chains = {start: [start]}
        queue = deque([start])
        while queue:
            current = queue.popleft()
            for target in sorted(graph.get(current, ())):
                if target in chains:
                    continue
                chains[target] = [*chains[current], target]
                if target == UNKNOWN or layer_of(target) in forbidden:
                    found.append(
                        f"{start} imports {target}: {' -> '.join(chains[target])}"
                    )
                else:
                    queue.append(target)
    return found


def test_the_package_follows_the_import_rule() -> None:
    assert violations(REPO / "src" / "vmseed") == []


def write_tree(root: Path, files: dict[str, str]) -> Path:
    src = root / "vmseed"
    for name, text in {"__init__.py": "", **files}.items():
        path = src / name
        path.parent.mkdir(parents=True, exist_ok=True)
        for parent in path.relative_to(src).parents:
            (src / parent / "__init__.py").touch()
        path.write_text(text, encoding="utf-8")
    return src


@pytest.mark.parametrize(
    ("files", "expected"),
    [
        pytest.param(
            {"plan.py": "import vmseed.host.virsh\n", "host/virsh.py": ""},
            "vmseed.plan imports vmseed.host",
            id="plan imports host",
        ),
        pytest.param(
            {"guest/assemble.py": "from vmseed import ops\n", "ops/create.py": ""},
            "vmseed.guest.assemble imports vmseed.ops",
            id="from-import of a layer",
        ),
        pytest.param(
            {"config/loader.py": "from ..cli import app\n", "cli.py": ""},
            "vmseed.config.loader imports vmseed.cli",
            id="relative import",
        ),
        pytest.param(
            {
                "catalog/cache.py": "import vmseed.state\n",
                "state.py": "from vmseed.host import safeio\n",
                "host/safeio.py": "",
            },
            "vmseed.catalog.cache imports vmseed.host: "
            "vmseed.catalog.cache -> vmseed.state -> vmseed.host",
            id="through a module outside the rule",
        ),
        pytest.param(
            {"guest/shell.py": "def f():\n    import vmseed.cli\n", "cli.py": ""},
            "vmseed.guest.shell imports vmseed.cli",
            id="import inside a function",
        ),
        pytest.param(
            {
                "plan.py": "from typing import TYPE_CHECKING\n"
                "if TYPE_CHECKING:\n    from vmseed.ops import create\n",
                "ops/create.py": "",
            },
            "vmseed.plan imports vmseed.ops",
            id="import under TYPE_CHECKING",
        ),
        pytest.param(
            {
                "guest/registry.py": "import importlib\n"
                "importlib.import_module('vmseed.host.virsh')\n",
                "host/virsh.py": "",
            },
            "vmseed.guest.registry imports vmseed.host",
            id="dynamic import of a literal name",
        ),
        pytest.param(
            {"config/models.py": "name = 'x'\nm = __import__(name)\n"},
            f"vmseed.config.models imports {UNKNOWN}",
            id="dynamic import of a computed name",
        ),
        pytest.param(
            {
                "host/domain.py": "from vmseed.ops.create import run\n",
                "ops/create.py": "",
            },
            "vmseed.host.domain imports vmseed.ops",
            id="host imports ops",
        ),
        pytest.param(
            {
                "__init__.py": "from vmseed import cli\n",
                "cli.py": "",
                "config/models.py": "",
            },
            "vmseed.config imports vmseed.cli: vmseed.config -> vmseed -> vmseed.cli",
            id="the package above runs a forbidden layer",
        ),
    ],
)
def test_a_forbidden_import_is_found(
    tmp_path: Path, files: dict[str, str], expected: str
) -> None:
    found = violations(write_tree(tmp_path, files))

    assert any(line.startswith(expected) for line in found), found


def test_the_allowed_directions_pass(tmp_path: Path) -> None:
    src = write_tree(
        tmp_path,
        {
            "config/models.py": "import vmseed.templating\n",
            "templating.py": "",
            "catalog/builtin.py": "from vmseed.config import models\n",
            "guest/assemble.py": "from ..config import models\n",
            "plan.py": "import vmseed.guest.assemble, vmseed.catalog.builtin\n",
            "host/domain.py": "import vmseed.plan\nfrom vmseed.config import models\n",
            "ops/create.py": "import vmseed.host.domain\nimport vmseed.plan\n",
            "cli.py": "from vmseed.ops import create\n",
        },
    )

    assert violations(src) == []
