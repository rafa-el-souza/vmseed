#!/usr/bin/env bats
# SSH key handling: generation, derivation, and the guards that stop a PRIVATE key
# from being shipped into a guest as if it were a public one.

load helpers

@test "keys: GENERATE_KEYS=yes creates both key pairs when absent" {
  run bash "$SCRIPT" --config "$(mkconf)" build
  assert_success
  [ -f "$TMP/keys/appuser-fedora-cloud-01.pub" ]
  [ -f "$TMP/keys/appuser-fedora-cloud-01" ]
  [ -f "$TMP/keys/admin-fedora-cloud-01.pub" ]
  [ -f "$TMP/keys/admin-fedora-cloud-01" ]
}

@test "keys: generated private keys are not world-readable" {
  bash "$SCRIPT" --config "$(mkconf)" build >/dev/null 2>&1
  assert_file_mode "$TMP/keys/admin-fedora-cloud-01" 600
}

@test "keys: the keys dir itself is locked down" {
  rm -rf "$TMP/keys"
  bash "$SCRIPT" --config "$(mkconf)" build >/dev/null 2>&1
  assert_file_mode "$TMP/keys" 700
}

@test "keys: GENERATE_KEYS=no refuses to invent a missing key" {
  run bash "$SCRIPT" --config "$(mkconf "GENERATE_KEYS=no")" build
  assert_failure
  assert_contains "key file not found"
  assert_contains "GENERATE_KEYS=no"
}

@test "keys: an existing public key is used as-is, not regenerated" {
  local pub="$TMP/keys/appuser-fedora-cloud-01.pub"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMARKER appuser\n' > "$pub"
  local before; before="$(cat "$pub")"
  bash "$SCRIPT" --config "$(mkconf)" build >/dev/null 2>&1
  [ "$(cat "$pub")" = "$before" ]
  # ...and it is what landed in the seed
  assert_contains "AAAAIMARKER" "$(cat "$TMP/overlay/build/fedora-cloud-01/user-data")"
}

@test "keys: a public key is DERIVED from an existing private key, never clobbered" {
  # The private half exists, the .pub was deleted. Regenerating would silently
  # break every guest already trusting that key, so the script must derive instead.
  local priv="$TMP/keys/appuser-fedora-cloud-01"
  ssh-keygen -t ed25519 -N '' -f "$priv" -C appuser >/dev/null 2>&1
  local fingerprint; fingerprint="$(ssh-keygen -lf "$priv.pub" | awk '{print $2}')"
  rm -f "$priv.pub"

  run bash "$SCRIPT" --config "$(mkconf)" build
  assert_success
  assert_contains "deriving public key from existing private key"
  [ -f "$priv.pub" ]
  # Same key, not a new one.
  [ "$(ssh-keygen -lf "$priv.pub" | awk '{print $2}')" = "$fingerprint" ]
}

@test "keys: a key path that cannot end in .pub cannot be auto-generated" {
  local conf; conf="$(mkconf "STD_KEY_FILE=$TMP/keys/nodotpub")"
  run bash "$SCRIPT" --config "$conf" build
  assert_failure
  assert_contains "can't be auto-generated"
}

@test "keys: a PRIVATE key handed in as the public one is refused" {
  # The mistake that silently ships your private key to the guest.
  local pub="$TMP/keys/appuser-fedora-cloud-01.pub"
  printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaA==\n-----END OPENSSH PRIVATE KEY-----\n' > "$pub"
  run bash "$SCRIPT" --config "$(mkconf)" build
  assert_failure
  assert_contains "contains a PRIVATE key"
}

@test "keys: a file that is not an SSH key at all is refused" {
  printf 'hello world\n' > "$TMP/keys/appuser-fedora-cloud-01.pub"
  run bash "$SCRIPT" --config "$(mkconf)" build
  assert_failure
  assert_contains "not an SSH public key"
}

@test "keys: ecdsa and sk- (FIDO) key types are accepted" {
  printf 'ecdsa-sha2-nistp256 AAAAE2VjZHNh test\n' > "$TMP/keys/appuser-fedora-cloud-01.pub"
  printf 'sk-ssh-ed25519@openssh.com AAAAGnNr test\n' > "$TMP/keys/admin-fedora-cloud-01.pub"
  run bash "$SCRIPT" --config "$(mkconf)" build
  assert_success
}

@test "keys: key filenames are per-DOMAIN, so two guests never share a key" {
  bash "$SCRIPT" --config "$(mkconf "DOMAIN=web01")" build >/dev/null 2>&1
  bash "$SCRIPT" --config "$(mkconf "DOMAIN=web02")" build >/dev/null 2>&1
  [ -f "$TMP/keys/appuser-web01.pub" ]
  [ -f "$TMP/keys/appuser-web02.pub" ]
  # Distinct keys, not the same one reused.
  ! diff -q "$TMP/keys/appuser-web01.pub" "$TMP/keys/appuser-web02.pub" >/dev/null
}

@test "keys: STD_KEY_FILE / ADM_KEY_FILE override the derived names" {
  printf 'ssh-ed25519 AAAAC3CUSTOMSTD std\n' > "$TMP/keys/custom-std.pub"
  printf 'ssh-ed25519 AAAAC3CUSTOMADM adm\n' > "$TMP/keys/custom-adm.pub"
  run bash "$SCRIPT" --config "$(mkconf \
    "STD_KEY_FILE=$TMP/keys/custom-std.pub" \
    "ADM_KEY_FILE=$TMP/keys/custom-adm.pub")" build
  assert_success
  local ud="$TMP/overlay/build/fedora-cloud-01/user-data"
  assert_contains "AAAAC3CUSTOMSTD" "$(cat "$ud")"
  assert_contains "AAAAC3CUSTOMADM" "$(cat "$ud")"
}
