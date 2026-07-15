#!/usr/bin/env bats
# `build`: rendering the seed, and the schema check on what comes out.

load helpers

ud() { printf '%s/overlay/build/%s/user-data\n' "$TMP" "${1:-fedora-cloud-01}"; }

@test "build: writes user-data and meta-data into a per-DOMAIN seed dir" {
  run bash "$SCRIPT" --config "$(mkconf "DOMAIN=web01")" build
  assert_success
  [ -f "$TMP/overlay/build/web01/user-data" ]
  [ -f "$TMP/overlay/build/web01/meta-data" ]
  assert_contains "seed ready"
}

@test "build: two domains do not clobber each other's seed" {
  bash "$SCRIPT" --config "$(mkconf "DOMAIN=web01" "VM_HOSTNAME=web01")" build >/dev/null 2>&1
  bash "$SCRIPT" --config "$(mkconf "DOMAIN=web02" "VM_HOSTNAME=web02")" build >/dev/null 2>&1
  assert_contains "local-hostname: web01" "$(cat "$TMP/overlay/build/web01/meta-data")"
  assert_contains "local-hostname: web02" "$(cat "$TMP/overlay/build/web02/meta-data")"
}

@test "build: meta-data carries instance-id and hostname" {
  bash "$SCRIPT" --config "$(mkconf "INSTANCE_ID=inst-9" "VM_HOSTNAME=host-9")" build >/dev/null 2>&1
  local md; md="$(cat "$TMP/overlay/build/fedora-cloud-01/meta-data")"
  assert_contains "instance-id: inst-9" "$md"
  assert_contains "local-hostname: host-9" "$md"
}

@test "build: every PLACEHOLDER token is substituted" {
  # Enable every feature so all tokens actually appear and must be filled.
  bash "$SCRIPT" --config "$(mkconf "NETWORK=bridge=virbr0" "SAMBA=yes" "FAIL2BAN=yes" \
    "DIAGNOSTICS=yes" "SSH_ALLOW=10.0.0.9")" build >/dev/null 2>&1
  # The header comment legitimately says the word PLACEHOLDER_*; the tokens
  # themselves must be gone. Check for the exact tokens, not the prose.
  local out; out="$(cat "$(ud)")"
  for token in PLACEHOLDER_STANDARD_KEY PLACEHOLDER_ADMIN_KEY PLACEHOLDER_TMUX_CONF_B64 \
               PLACEHOLDER_STD_USER PLACEHOLDER_ADMIN_USER PLACEHOLDER_CRYPTO_POLICY \
               PLACEHOLDER_SMB_PASSWORD PLACEHOLDER_SMB_ALLOW PLACEHOLDER_SSH_ALLOW \
               PLACEHOLDER_F2B_IGNOREIP PLACEHOLDER_DIAG_SCRIPT_B64; do
    refute_contains "$token" "$out"
  done
}

@test "build: no #@if / #@endif marker ever survives into the seed" {
  # A leaked marker is not cosmetic: at column 0 inside a YAML block scalar it
  # would terminate the block and change the meaning of the document.
  bash "$SCRIPT" --config "$(mkconf "SAMBA=yes" "FAIL2BAN=yes" "NETWORK=bridge=virbr0")" build >/dev/null 2>&1
  local out; out="$(grep -E '^\s*#@(if|endif)' "$(ud)" || true)"
  [ -z "$out" ]
}

@test "build: usernames reach both the users block and sshd AllowUsers" {
  bash "$SCRIPT" --config "$(mkconf "STD_USER=dev" "ADMIN_USER=ops")" build >/dev/null 2>&1
  local out; out="$(cat "$(ud)")"
  assert_contains "name: dev" "$out"
  assert_contains "name: ops" "$out"
  assert_contains "AllowUsers ops dev" "$out"
}

@test "build: CRYPTO_POLICY reaches the runcmd that applies it" {
  bash "$SCRIPT" --config "$(mkconf "CRYPTO_POLICY=FUTURE")" build >/dev/null 2>&1
  assert_contains "update-crypto-policies, --set, FUTURE" "$(cat "$(ud)")"
}

@test "build: the tmux config is injected as base64 that decodes to the source file" {
  # SAMBA=no, so the only quoted `content:` scalar in the seed is the tmux one.
  bash "$SCRIPT" --config "$(mkconf "SAMBA=no")" build >/dev/null 2>&1
  local b64
  b64="$(sed -n 's/^    content: "\(.*\)"$/\1/p' "$(ud)" | head -1)"
  [ -n "$b64" ]
  printf '%s' "$b64" | base64 -d | diff -q - "${BATS_TEST_DIRNAME}/../dotfiles/tmux.conf"
}

@test "build: a missing template is an error" {
  run bash "$SCRIPT" --config "$(mkconf "TEMPLATE=$TMP/nope.yaml")" build
  assert_failure
  assert_contains "missing required file"
}

@test "build: a missing tmux config is an error" {
  run bash "$SCRIPT" --config "$(mkconf "TMUX_CONF=$TMP/nope.conf")" build
  assert_failure
  assert_contains "missing required file"
}

@test "build: an unbalanced #@if in the template is caught, not silently rendered" {
  cp "${BATS_TEST_DIRNAME}/../user-data.yaml" "$TMP/broken.yaml"
  printf '#@if SAMBA\n# never closed\n' >> "$TMP/broken.yaml"
  run bash "$SCRIPT" --config "$(mkconf "TEMPLATE=$TMP/broken.yaml")" build
  assert_failure
  assert_contains "unbalanced #@if / #@endif"
}

# ------------------------------------------------------------- seed delivery

@test "build: SEED_METHOD=seed-iso needs cloud-localds and says so" {
  # No stub on PATH -> the _need gate must fire.
  run bash "$SCRIPT" --config "$(mkconf "SEED_METHOD=seed-iso")" build
  assert_failure
  assert_contains "required command not found: cloud-localds"
}

@test "build: SEED_METHOD=seed-iso invokes cloud-localds with the rendered files" {
  stub cloud-localds
  run bash "$SCRIPT" --config "$(mkconf "SEED_METHOD=seed-iso")" build
  assert_success
  local args; args="$(stub_args cloud-localds)"
  assert_contains "seed.iso" "$args"
  assert_contains "user-data" "$args"
  assert_contains "meta-data" "$args"
}

@test "build: SEED_METHOD=cloud-init does not need cloud-localds at all" {
  run bash "$SCRIPT" --config "$(mkconf "SEED_METHOD=cloud-init")" build
  assert_success
  [ ! -f "$TMP/overlay/build/fedora-cloud-01/seed.iso" ]
}

# ------------------------------------------------------- schema (real cloud-init)
# The test image ships cloud-init, so `cloud-init schema` genuinely runs here.
# These are the tests that would catch a YAML/cloud-config regression in the
# template — including one introduced by a feature block being stripped badly.

@test "schema: the rendered cloud-config validates, with every feature off" {
  run bash "$SCRIPT" --config "$(mkconf "FIREWALL=no" "SAMBA=no" "FAIL2BAN=no")" build
  assert_success
  assert_contains "validating user-data schema"
  run cloud-init schema --config-file "$(ud)" --annotate
  assert_success
}

@test "schema: the rendered cloud-config validates, with every feature on" {
  run bash "$SCRIPT" --config "$(mkconf \
    "NETWORK=bridge=virbr0" "FIREWALL=yes" "SAMBA=yes" "FAIL2BAN=yes")" build
  assert_success
  run cloud-init schema --config-file "$(ud)" --annotate
  assert_success
}

@test "schema: validation is skipped, not fatal, when cloud-init is absent" {
  # The other branch of _validate_seed: a missing cloud-init must degrade to a
  # note, never fail the build.
  PATH="$(path_without cloud-init)" run bash "$SCRIPT" --config "$(mkconf)" build
  assert_success
  assert_contains "cloud-init not installed; skipping schema validation"
}
