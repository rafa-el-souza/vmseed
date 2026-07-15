#!/usr/bin/env bats
# The config parser and per-key validation.
#
# This is the security boundary of the tool: the config file is PARSED, never
# sourced, so a hostile config must not be able to execute anything, and a
# malformed one must be rejected with a line number rather than silently doing
# something surprising.

load helpers

# ------------------------------------------------------------------- parsing

@test "parse: a missing config file is an error" {
  run bash "$SCRIPT" --config "$TMP/nope.conf" build
  assert_failure
  assert_contains "config file not found"
}

@test "parse: an unreadable config file is an error" {
  # root bypasses the DAC read check, so a 000 file is still readable to it and
  # the guard legitimately cannot fire. Skip rather than assert a falsehood.
  [[ "$EUID" -ne 0 ]] || skip "root bypasses file permission checks"
  local conf; conf="$(mkconf)"
  chmod 000 "$conf"
  run bash "$SCRIPT" --config "$conf" build
  assert_failure
  assert_contains "config file not readable"
}

@test "parse: a line that is not KEY=VALUE is refused, with its line number" {
  local conf; conf="$(mkconf_raw "OVERLAY_IMAGE_DIR=$TMP/overlay" "this is not a pair")"
  run bash "$SCRIPT" --config "$conf" build
  assert_failure
  assert_contains "config:2: not KEY=VALUE"
}

@test "parse: an unknown key is refused, with its line number" {
  local conf; conf="$(mkconf_raw "OVERLAY_IMAGE_DIR=$TMP/overlay" "WAT=1")"
  run bash "$SCRIPT" --config "$conf" build
  assert_failure
  assert_contains "config:2: unknown key: 'WAT'"
}

@test "parse: an empty value is refused" {
  local conf; conf="$(mkconf_raw "OVERLAY_IMAGE_DIR=$TMP/overlay" "DOMAIN=")"
  run bash "$SCRIPT" --config "$conf" build
  assert_failure
  assert_contains "empty value for DOMAIN"
}

@test "parse: blank lines and whole-line comments are ignored" {
  local conf; conf="$(mkconf_raw \
    "# a comment" \
    "" \
    "   " \
    "OVERLAY_IMAGE_DIR=$TMP/overlay" \
    "KEYS_DIR=$TMP/keys" \
    "GENERATE_KEYS=yes" \
    "ENCRYPT_KEYS=no" \
    "SEED_METHOD=cloud-init")"
  run bash "$SCRIPT" --config "$conf" build
  assert_success
}

@test "parse: surrounding whitespace is trimmed from key and value" {
  local conf; conf="$(mkconf_raw \
    "  OVERLAY_IMAGE_DIR  =  $TMP/overlay  " \
    "KEYS_DIR=$TMP/keys" \
    "GENERATE_KEYS=yes" \
    "ENCRYPT_KEYS=no" \
    "SEED_METHOD=cloud-init" \
    "  DOMAIN = trimmed  ")"
  run bash "$SCRIPT" --config "$conf" build
  assert_success
  [ -f "$TMP/overlay/build/trimmed/user-data" ]
}

@test "parse: a trailing inline comment is stripped from the value" {
  local conf; conf="$(mkconf "RAM_MB=4096   # plenty")"
  run bash "$SCRIPT" --config "$conf" build
  assert_success   # would fail validation as "4096   # plenty" if not stripped
}

@test "parse: a leading '~' in a config path is expanded to \$HOME" {
  # Config values are read as literal strings, so the shell never runs its own
  # tilde expansion on them. Without the expansion in _load_config, a path like
  # '~/keys/appuser-...pub' is taken verbatim and the key lands in a literal '~'
  # directory under the CWD instead of the home directory.
  local home="$TMP/home"; mkdir -p "$home"
  local conf; conf="$(mkconf_raw \
    "OVERLAY_IMAGE_DIR=$TMP/overlay" \
    "BASE_IMAGE_DIR=$TMP/base" \
    "KEYS_DIR=~/keys" \
    "STD_KEY_FILE=~/keys/appuser-fedora-cloud-01.pub" \
    "ADM_KEY_FILE=~/keys/admin-fedora-cloud-01.pub" \
    "GENERATE_KEYS=yes" \
    "ENCRYPT_KEYS=no" \
    "SEED_METHOD=cloud-init")"
  # Run from a CWD we own, so a literal '~' dir (the bug) would surface there.
  cd "$TMP"
  HOME="$home" run bash "$SCRIPT" --config "$conf" build
  assert_success
  # The keys landed under $HOME, expanded...
  [ -f "$home/keys/appuser-fedora-cloud-01.pub" ]
  [ -f "$home/keys/admin-fedora-cloud-01.pub" ]
  # ...and no literal '~' directory was created under the CWD.
  [ ! -e "$TMP/~" ]
}

@test "parse: a '#' with no leading whitespace is NOT a comment" {
  # Proven by the value reaching validation intact: DOMAIN rejects '#', and the
  # error quotes the whole value. If the stripper were too eager we would instead
  # see it silently truncated to 'abc'.
  local conf; conf="$(mkconf "DOMAIN=abc#def")"
  run bash "$SCRIPT" --config "$conf" build
  assert_failure
  assert_contains "got 'abc#def'"
}

@test "parse: the config is never sourced — a command substitution is inert" {
  # If the file were sourced, this would create the marker file. It must not.
  local conf; conf="$(mkconf "VM_HOSTNAME=\$(touch $TMP/PWNED)x")"
  run bash "$SCRIPT" --config "$conf" build
  assert_failure                 # rejected by VM_HOSTNAME's charset
  [ ! -e "$TMP/PWNED" ]          # and, crucially, nothing executed
}

# ---------------------------------------------------------------- validation

@test "validate: RAM_MB / VCPUS / VER must be positive integers" {
  for bad in 0 -1 abc 1.5; do
    run bash "$SCRIPT" --config "$(mkconf "RAM_MB=$bad")" build
    assert_failure
    assert_contains "must be a positive integer"
  done
  run bash "$SCRIPT" --config "$(mkconf "VCPUS=0")" build
  assert_failure
  run bash "$SCRIPT" --config "$(mkconf "VER=x")" build
  assert_failure
}

@test "validate: ARCH is an allowlist" {
  run bash "$SCRIPT" --config "$(mkconf "ARCH=riscv64")" build
  assert_failure
  assert_contains "ARCH invalid"
  run bash "$SCRIPT" --config "$(mkconf "ARCH=aarch64")" build
  assert_success
}

@test "validate: COMPOSE looks like N or N.N" {
  run bash "$SCRIPT" --config "$(mkconf "COMPOSE=beta")" build
  assert_failure
  assert_contains "must look like N or N.N"
  run bash "$SCRIPT" --config "$(mkconf "COMPOSE=1.5")" build
  assert_success
}

@test "validate: URLs must be https and free of whitespace" {
  run bash "$SCRIPT" --config "$(mkconf "FEDORA_GPG_URL=http://example.com/k.gpg")" build
  assert_failure
  assert_contains "must be an https:// URL"
  run bash "$SCRIPT" --config "$(mkconf "CHECKSUM_URL=https://e.com/a b")" build
  assert_failure
}

@test "validate: LIBVIRT_URI must look like a libvirt URI" {
  run bash "$SCRIPT" --config "$(mkconf "LIBVIRT_URI=/var/run/libvirt.sock")" build
  assert_failure
  assert_contains "must be a libvirt URI"
  run bash "$SCRIPT" --config "$(mkconf "LIBVIRT_URI=qemu+ssh://host/system")" build
  assert_success
}

@test "validate: DOMAIN / INSTANCE_ID / VM_HOSTNAME reject path and shell characters" {
  for key in DOMAIN INSTANCE_ID VM_HOSTNAME; do
    run bash "$SCRIPT" --config "$(mkconf "$key=../escape")" build
    assert_failure
    assert_contains "may contain only"
  done
}

@test "validate: yes/no keys reject anything else" {
  for key in GENERATE_KEYS ENCRYPT_KEYS TPM FIREWALL SAMBA FAIL2BAN; do
    run bash "$SCRIPT" --config "$(mkconf "$key=true")" build
    assert_failure
    assert_contains "must be 'yes' or 'no'"
  done
}

@test "validate: SEED_METHOD and IMAGE_VARIANT are allowlists" {
  run bash "$SCRIPT" --config "$(mkconf "SEED_METHOD=magic")" build
  assert_failure
  assert_contains "must be 'seed-iso' or 'cloud-init'"
  run bash "$SCRIPT" --config "$(mkconf "IMAGE_VARIANT=cloud")" build
  assert_failure
  assert_contains "must be 'generic' or 'uki'"
}

@test "validate: CRYPTO_POLICY accepts a policy with modifiers, rejects junk" {
  run bash "$SCRIPT" --config "$(mkconf "CRYPTO_POLICY=DEFAULT:NO-SHA1")" build
  assert_success
  run bash "$SCRIPT" --config "$(mkconf "CRYPTO_POLICY=FUTURE")" build
  assert_success
  run bash "$SCRIPT" --config "$(mkconf "CRYPTO_POLICY=DEFAULT NO-SHA1")" build
  assert_failure
  assert_contains "invalid crypto policy"
}

@test "validate: usernames must be valid Linux names" {
  run bash "$SCRIPT" --config "$(mkconf "STD_USER=Capital")" build
  assert_failure
  assert_contains "must be a valid Linux username"
  run bash "$SCRIPT" --config "$(mkconf "STD_USER=has space")" build
  assert_failure
}

@test "validate: reserved and system accounts are refused for both users" {
  for name in root default fedora nobody sshd; do
    run bash "$SCRIPT" --config "$(mkconf "STD_USER=$name")" build
    assert_failure
    assert_contains "reserved/system account"
  done
  run bash "$SCRIPT" --config "$(mkconf "ADMIN_USER=root")" build
  assert_failure
  assert_contains "reserved/system account"
}

@test "validate: STD_USER and ADMIN_USER must differ" {
  run bash "$SCRIPT" --config "$(mkconf "STD_USER=same" "ADMIN_USER=same")" build
  assert_failure
  assert_contains "must differ"
}

@test "validate: OSINFO and NETWORK reject stray characters" {
  run bash "$SCRIPT" --config "$(mkconf 'OSINFO=name=fedora43;rm -rf /')" build
  assert_failure
  assert_contains "has invalid characters"
  run bash "$SCRIPT" --config "$(mkconf 'NETWORK=bridge=virbr0;evil')" build
  assert_failure
  assert_contains "has invalid characters"
}

@test "validate: paths must not contain whitespace" {
  run bash "$SCRIPT" --config "$(mkconf "TMUX_CONF=/tmp/a file")" build
  assert_failure
  assert_contains "must not contain whitespace"
  run bash "$SCRIPT" --config "$(mkconf "SMB_PASSWORD_FILE=/tmp/a b.cred")" build
  assert_failure
  assert_contains "must not contain whitespace"
}

@test "validate: SMB_HOST_ADDR must be a bare IPv4, not a CIDR" {
  run bash "$SCRIPT" --config "$(mkconf "SMB_HOST_ADDR=192.168.122.0/24")" build
  assert_failure
  assert_contains "must be a bare IPv4 address"
  run bash "$SCRIPT" --config "$(mkconf "SMB_HOST_ADDR=host.local")" build
  assert_failure
}

@test "validate: SMB_HOST_ADDR range-checks each octet" {
  # A loose \d{1,3} would wave this through to firewalld, which would then fail at
  # boot instead of here.
  run bash "$SCRIPT" --config "$(mkconf "SMB_HOST_ADDR=999.1.1.1")" build
  assert_failure
  assert_contains "must be a bare IPv4 address"
  run bash "$SCRIPT" --config "$(mkconf "SMB_HOST_ADDR=192.168.122.255")" build
  assert_success
  run bash "$SCRIPT" --config "$(mkconf "SMB_HOST_ADDR=10.0.0.1")" build
  assert_success
}

@test "validate: FAIL2BAN_IGNOREIP takes space-separated IPs/CIDRs only" {
  run bash "$SCRIPT" --config "$(mkconf 'FAIL2BAN_IGNOREIP=127.0.0.1/8; rm -rf /')" build
  assert_failure
  assert_contains "must be space-separated IPs/CIDRs"
  run bash "$SCRIPT" --config "$(mkconf 'FAIL2BAN_IGNOREIP=127.0.0.1/8 ::1 10.0.0.0/8')" build
  assert_success
}
