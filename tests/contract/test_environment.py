"""What the contract tier needs from the machine it runs on (08, tier 2).

The nftables contract tests load a ruleset for real inside an unprivileged
user and network namespace. Some CI runner images restrict those namespaces;
the job relaxes the restriction first (assumption A-CI-USERNS).
"""

import subprocess
from pathlib import Path

import pytest

from tests.support import require_tool

pytestmark = pytest.mark.contract

RULESET = """\
table inet vmseed_probe {
  chain input {
    type filter hook input priority 0; policy drop;
    iif "lo" accept
  }
}
"""


def test_an_nftables_ruleset_loads_in_an_unprivileged_network_namespace(
    tmp_path: Path,
) -> None:
    unshare, nft = require_tool("unshare"), require_tool("nft")
    ruleset = tmp_path / "probe.nft"
    ruleset.write_text(RULESET, encoding="utf-8")

    result = subprocess.run(
        [
            *(unshare, "--user", "--map-root-user", "--net", "--"),
            *(nft, "--echo", "--handle", "--file", str(ruleset)),
        ],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert 'add rule inet vmseed_probe input iif "lo" accept # handle' in result.stdout
