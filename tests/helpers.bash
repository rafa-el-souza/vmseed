#!/usr/bin/env bash
# shellcheck shell=bash
# $status / $output are set by bats' `run`, not by this file.
# shellcheck disable=SC2154
# Shared setup for the bats suite.
#
# Every test runs the real CLI as a subprocess (`fedora-cloud.sh --config <f>
# <cmd>`) instead of sourcing its internals — all the helpers live inside main(),
# so there is nothing to source, and driving the CLI from the outside is what
# actually exercises the contract users depend on.
#
# The commands that would touch libvirt, QEMU or the network (virt-install, virsh,
# qemu-img, swtpm, cloud-localds, curl, gpgv, flock) are replaced by stubs on
# PATH. The stubs record their arguments so a test can assert on exactly what the
# script *would have run* — the only honest way to test a wrapper around tools
# that cannot be executed under test.

SCRIPT="${BATS_TEST_DIRNAME}/../fedora-cloud.sh"

# A private temp dir per test, made and removed by us rather than relying on
# BATS_TEST_TMPDIR (absent on older bats releases, e.g. the one Ubuntu packages).
setup() {
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/vmseed-test.XXXXXX")"
  STUB_BIN="$TMP/bin"
  mkdir -p "$STUB_BIN" "$TMP/keys" "$TMP/overlay" "$TMP/base"
  PATH="$STUB_BIN:$PATH"
  # Where stubs record their invocations.
  export STUB_LOG="$TMP/stublog"
  mkdir -p "$STUB_LOG"
}

teardown() {
  [[ -n "${TMP:-}" && -d "$TMP" ]] && rm -rf "$TMP"
}

# ---------------------------------------------------------------- assertions
# bats-assert is not packaged in Fedora, so these are hand-rolled. They print the
# actual output on failure — without that, a red test tells you nothing.

assert_success() {
  if (( status != 0 )); then
    printf 'expected success, got exit %d\noutput:\n%s\n' "$status" "$output" >&2
    return 1
  fi
}

assert_failure() {
  if (( status == 0 )); then
    printf 'expected failure, got exit 0\noutput:\n%s\n' "$output" >&2
    return 1
  fi
}

assert_contains() {  # assert_contains <needle> [haystack, default $output]
  local needle="$1" hay="${2-$output}"
  if [[ "$hay" != *"$needle"* ]]; then
    printf 'expected to find: %s\nin:\n%s\n' "$needle" "$hay" >&2
    return 1
  fi
}

refute_contains() {  # refute_contains <needle> [haystack, default $output]
  local needle="$1" hay="${2-$output}"
  if [[ "$hay" == *"$needle"* ]]; then
    printf 'expected NOT to find: %s\nin:\n%s\n' "$needle" "$hay" >&2
    return 1
  fi
}

assert_file_mode() {  # assert_file_mode <file> <octal>  — secrets must not be readable
  local f="$1" want="$2" got
  got="$(stat -c '%a' "$f")"
  if [[ "$got" != "$want" ]]; then
    printf 'expected mode %s on %s, got %s\n' "$want" "$f" "$got" >&2
    return 1
  fi
}

# ------------------------------------------------------------------- configs
# mkconf [extra KEY=VALUE lines...] -> path of the config file
#
# Writes a config that is valid on its own: the two required dirs, a keys dir the
# test owns, and non-interactive key generation. SEED_METHOD=cloud-init by default
# so the happy path does not need cloud-localds; tests that care pass seed-iso.
mkconf() {
  local f="$TMP/test.conf"
  {
    printf 'OVERLAY_IMAGE_DIR=%s/overlay\n' "$TMP"
    printf 'BASE_IMAGE_DIR=%s/base\n' "$TMP"
    printf 'KEYS_DIR=%s/keys\n' "$TMP"
    printf 'GENERATE_KEYS=yes\n'
    printf 'ENCRYPT_KEYS=no\n'
    printf 'SEED_METHOD=cloud-init\n'
    local line
    for line in "$@"; do printf '%s\n' "$line"; done
  } > "$f"
  printf '%s\n' "$f"
}

# Same, but with NOTHING implied — for tests that need to control every key.
mkconf_raw() {
  local f="$TMP/test.conf" line
  : > "$f"
  for line in "$@"; do printf '%s\n' "$line" >> "$f"; done
  printf '%s\n' "$f"
}

run_build() { run bash "$SCRIPT" --config "$(mkconf "$@")" build; }

# --------------------------------------------------------------------- stubs
# stub <name> [exit_code] — record argv, then exit. The recording is what tests
# assert against.
stub() {
  local name="$1" code="${2:-0}"
  cat > "$STUB_BIN/$name" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$STUB_LOG/$name.args"
exit $code
EOF
  chmod +x "$STUB_BIN/$name"
}

# The set `boot` needs. virsh is special (it must answer queries), so it gets its
# own stub below.
stub_boot_tools() {
  stub virt-install
  stub qemu-img
  stub swtpm
  stub cloud-localds
  stub_virsh
}

# virsh has to *answer*, not just record:
#   domstate  -> whatever the test put in $STUB_LOG/domstate (absent = no such
#                domain, which is the normal new-guest path)
#   dominfo   -> succeeds only if the domain "exists"
#   domifaddr -> hands back an IP immediately, so _wait_guest_ip does not burn
#                30 real seconds of sleep in every boot test
stub_virsh() {
  cat > "$STUB_BIN/virsh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG/virsh.args"
case "$*" in
  *" domstate "*)
    if [[ -s "$STUB_LOG/domstate" ]]; then cat "$STUB_LOG/domstate"; exit 0; fi
    exit 1 ;;
  *" dominfo "*)
    [[ -s "$STUB_LOG/domstate" ]] && exit 0
    exit 1 ;;
  *" domifaddr "*)
    printf ' vnet0  52:54:00:aa:bb:cc  ipv4  192.168.122.10/24\n'
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB_BIN/virsh"
}

set_domstate() { printf '%s\n' "$1" > "$STUB_LOG/domstate"; }

# argv recorded by a stub across all its invocations
stub_args() { cat "$STUB_LOG/$1.args" 2>/dev/null || true; }

# path_without <name>... -> echoes a PATH that has everything /usr/bin does,
# EXCEPT the named binaries.
#
# Needed because the obvious tricks do not work. An empty PATH is too blunt: the
# script itself shells out to `dirname` before it ever reaches a _need gate, and
# bats cannot even find `bash` to launch it. And a non-executable stub does not
# shadow anything — `command -v` simply skips it and walks on to /usr/bin. So the
# only honest way to prove "this tool is missing" is a PATH where it truly is.
path_without() {
  local dir="$TMP/path-without-$*"
  dir="${dir// /_}"
  mkdir -p "$dir"
  local f base skip
  for f in /usr/bin/*; do
    base="${f##*/}"
    skip=""
    for name in "$@"; do [[ "$base" == "$name" ]] && skip=1; done
    [[ -n "$skip" ]] || ln -sf "$f" "$dir/$base"
  done
  printf '%s\n' "$dir"
}

# A file that merely has to exist to be a "base image".
fake_image() {
  local f="$TMP/base/Fedora-Cloud-Base-Generic.x86_64.qcow2"
  printf 'not-really-a-qcow2\n' > "$f"
  printf '%s\n' "$f"
}

# Renders a seed and echoes the path of the rendered user-data.
build_and_echo_userdata() {
  bash "$SCRIPT" --config "$(mkconf "$@")" build >/dev/null 2>&1 || return 1
  local dom="fedora-cloud-01"
  local line
  for line in "$@"; do [[ "$line" == DOMAIN=* ]] && dom="${line#DOMAIN=}"; done
  printf '%s/overlay/build/%s/user-data\n' "$TMP" "$dom"
}
