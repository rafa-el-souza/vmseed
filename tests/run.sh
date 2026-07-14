#!/usr/bin/env bash
#
# Run the bats suite.
#
#   tests/run.sh                 # everything
#   tests/run.sh --filter samba  # a subset (any bats argument works)
#
# Needs bats on PATH: `dnf install bats`, `apt-get install bats`, or
# https://github.com/bats-core/bats-core. The suite is self-contained — each test
# works inside its own mktemp dir and stubs out libvirt, QEMU and the network, so
# it never mutates the host and never reaches the network. That is also why CI can
# run it directly on the runner, with nothing but bats installed.
#
# For schema coverage, install cloud-init too: the two schema tests validate the
# rendered seed for real when `cloud-init` is present, and self-skip when it is not.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v bats >/dev/null 2>&1; then
  echo "error: bats not found on PATH — install bats-core (dnf/apt install bats)" >&2
  exit 1
fi

exec bats "$repo_root/tests/" "$@"
