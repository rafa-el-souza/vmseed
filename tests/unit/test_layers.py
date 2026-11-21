"""The import rule between layers (docs/spec/01-architecture.md).

`config`, `catalog`, `guest` and `plan` never import `host`, `ops` or `cli`;
`host` never imports `ops`. Importing a module runs every module it imports,
and the `__init__` of every package above them, so the rule is checked on
what a module reaches, not only on what it names. Imports inside functions
and under `TYPE_CHECKING` count. A dynamic import counts by the module it
names; one whose name is not a literal is refused in a restricted layer. A
dynamic import is a call of `__import__`, `importlib.import_module`,
`pkgutil.resolve_name` or `runpy.run_module`, under whatever name the
module's imports give it; `importlib.util.find_spec` counts by the packages
above the module it names, which it imports. A call reached through
`getattr`, `exec` or `eval` is not followed.
"""

import ast
import importlib.util
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


#: The functions that import the module a string names, by the dotted name
#: that a module's imports give them.
DYNAMIC_IMPORTS = frozenset(
    {
        "builtins.__import__",
        "importlib.__import__",
        "importlib.import_module",
        "pkgutil.resolve_name",
        "runpy.run_module",
        "importlib.util.find_spec",
    }
)

#: Of those, the ones that import only the packages above the module named.
IMPORTS_ONLY_PARENTS = frozenset({"importlib.util.find_spec"})


def _bindings(tree: ast.Module) -> dict[str, str]:
    """The dotted name that each name bound by an import in TREE stands for."""
    names: dict[str, str] = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                top = alias.name.split(".")[0]
                names[alias.asname or top] = alias.name if alias.asname else top
        elif isinstance(node, ast.ImportFrom) and node.module and not node.level:
            for alias in node.names:
                names[alias.asname or alias.name] = f"{node.module}.{alias.name}"
    return names


def _called(call: ast.Call, bindings: dict[str, str]) -> str:
    """The dotted name of what CALL calls, as far as the imports tell."""
    attributes: list[str] = []
    function = call.func
    while isinstance(function, ast.Attribute):
        attributes.insert(0, function.attr)
        function = function.value
    if not isinstance(function, ast.Name):
        return ""
    default = "builtins.__import__" if function.id == "__import__" else function.id
    return ".".join([bindings.get(function.id, default), *attributes])


def _is_dynamic_import(call: ast.Call, called: str) -> bool:
    function = call.func
    if isinstance(function, ast.Attribute) and function.attr == "import_module":
        return True
    return called in DYNAMIC_IMPORTS


def _literal(node: ast.expr) -> str | None:
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    return None


def _dynamic_target(call: ast.Call, called: str) -> str | None:
    """The module a dynamic import names; None when it is not a literal."""
    name = _literal(call.args[0]) if call.args else None
    if name is None:
        return None
    if called == "pkgutil.resolve_name":
        name = name.partition(":")[0]
    if not name.startswith("."):
        return name
    package = _literal(call.args[1]) if len(call.args) > 1 else None
    for keyword in call.keywords:
        if keyword.arg == "package":
            package = _literal(keyword.value)
    if package is None:
        return None
    try:
        return importlib.util.resolve_name(name, package)
    except (ImportError, ValueError):
        return None


def imports_of(module: str, path: Path, known: set[str]) -> set[str]:
    """The vmseed modules that importing MODULE runs directly."""
    is_package = path.name == "__init__.py"
    package = module if is_package else module.rpartition(".")[0]
    found = with_parents(module) - {module}
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    bindings = _bindings(tree)
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
        elif isinstance(node, ast.Call):
            called = _called(node, bindings)
            if _is_dynamic_import(node, called):
                target = _dynamic_target(node, called)
                if not target:
                    found.add(UNKNOWN)
                elif called in IMPORTS_ONLY_PARENTS:
                    found |= with_parents(target) - {target}
                else:
                    found |= with_parents(target)
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


@pytest.mark.parametrize(
    ("files", "expected"),
    [
        pytest.param(
            {
                "guest/registry.py": "from importlib import import_module\n"
                "import_module('vmseed.host.virsh')\n",
                "host/virsh.py": "",
            },
            "vmseed.guest.registry imports vmseed.host",
            id="import_module imported by name, literal",
        ),
        pytest.param(
            {
                "config/models.py": "from importlib import import_module\n"
                "name = 'vmseed.' + 'ops'\nimport_module(name)\n",
                "ops/create.py": "",
            },
            f"vmseed.config.models imports {UNKNOWN}",
            id="import_module imported by name, computed",
        ),
    ],
)
def test_a_dynamic_import_through_a_bare_import_module_is_found(
    tmp_path: Path, files: dict[str, str], expected: str
) -> None:
    found = violations(write_tree(tmp_path, files))

    assert any(line.startswith(expected) for line in found), found


@pytest.mark.parametrize(
    "source",
    [
        pytest.param(
            "import importlib\nimportlib.import_module('.virsh', 'vmseed.host')\n",
            id="import_module of a relative name",
        ),
        pytest.param(
            "import importlib\nimportlib.__import__('vmseed.host.virsh')\n",
            id="importlib.__import__",
        ),
        pytest.param(
            "import builtins\nbuiltins.__import__('vmseed.host.virsh')\n",
            id="builtins.__import__",
        ),
        pytest.param(
            "import pkgutil\npkgutil.resolve_name('vmseed.host.virsh')\n",
            id="pkgutil.resolve_name",
        ),
        pytest.param(
            "from importlib import import_module as load\nload('vmseed.host.virsh')\n",
            id="import_module imported under another name",
        ),
        pytest.param(
            "import runpy\nrunpy.run_module('vmseed.host.virsh')\n",
            id="runpy.run_module",
        ),
        pytest.param(
            "import importlib.util\nimportlib.util.find_spec('vmseed.host.virsh')\n",
            id="importlib.util.find_spec",
        ),
    ],
)
def test_a_dynamic_import_through_another_spelling_is_found(
    tmp_path: Path, source: str
) -> None:
    files = {"guest/registry.py": source, "host/virsh.py": ""}

    found = violations(write_tree(tmp_path, files))

    assert any(
        line.startswith("vmseed.guest.registry imports vmseed.host") for line in found
    ), found


def test_a_function_of_the_same_name_is_not_a_dynamic_import(tmp_path: Path) -> None:
    src = write_tree(
        tmp_path,
        {
            "config/names.py": "def resolve_name(name):\n    return name\n",
            "config/models.py": "from vmseed.config.names import resolve_name\n"
            "vm = 'web'\nresolve_name(vm)\n",
        },
    )

    assert violations(src) == []


def test_a_spec_lookup_counts_only_the_packages_above(tmp_path: Path) -> None:
    src = write_tree(
        tmp_path,
        {
            "config/probe.py": "import importlib.util\n"
            "importlib.util.find_spec('vmseed.host')\n",
            "host/virsh.py": "",
        },
    )

    assert violations(src) == []
