#!/usr/bin/env bats
# `boot` and `run`.
#
# libvirt, QEMU and the network are stubbed, so what these tests assert is the
# argv the script *would have handed to virt-install* — which is the entire
# contract of a wrapper like this.

load helpers

BRIDGE="NETWORK=bridge=virbr0"

# Renders a seed and returns a config path + a base image, ready for `boot`.
prep() {
  local conf; conf="$(mkconf "$@")"
  bash "$SCRIPT" --config "$conf" build >/dev/null 2>&1
  printf '%s\n' "$conf"
}

@test "boot: refuses without an image argument" {
  stub_boot_tools
  run bash "$SCRIPT" --config "$(prep)" boot
  assert_failure
  assert_contains "usage:"
}

@test "boot: refuses an unknown flag" {
  stub_boot_tools
  run bash "$SCRIPT" --config "$(prep)" boot --wat img.qcow2
  assert_failure
  assert_contains "unknown boot flag: --wat"
}

@test "boot: refuses an image path that does not exist" {
  stub_boot_tools
  run bash "$SCRIPT" --config "$(prep)" boot "$TMP/ghost.qcow2"
  assert_failure
  assert_contains "image not found"
}

@test "boot: refuses to boot before build (seed-iso)" {
  stub_boot_tools
  local conf; conf="$(mkconf "SEED_METHOD=seed-iso")"   # never built
  run bash "$SCRIPT" --config "$conf" boot "$(fake_image)"
  assert_failure
  assert_contains "run '"
  assert_contains "build' first"
}

@test "boot: refuses to boot before build (cloud-init seed)" {
  stub_boot_tools
  local conf; conf="$(mkconf "SEED_METHOD=cloud-init")"
  run bash "$SCRIPT" --config "$conf" boot "$(fake_image)"
  assert_failure
  assert_contains "build' first"
}

@test "boot: needs virt-install, virsh and qemu-img" {
  # No stubs on PATH at all.
  local conf; conf="$(prep)"
  PATH="/usr/bin:/bin" run bash "$SCRIPT" --config "$conf" boot "$(fake_image)"
  assert_failure
  assert_contains "required command not found"
}

# ----------------------------------------------------------------- firmware

@test "boot: bios passes no --boot at all (nvram is UEFI-only)" {
  stub_boot_tools
  run bash "$SCRIPT" --config "$(prep)" boot "$(fake_image)" bios
  assert_success
  refute_contains "--boot" "$(stub_args virt-install)"
}

@test "boot: uefi asks for uefi firmware on a q35 machine" {
  stub_boot_tools
  run bash "$SCRIPT" --config "$(prep)" boot "$(fake_image)" uefi
  assert_success
  local args; args="$(stub_args virt-install)"
  assert_contains "--boot uefi" "$args"
  assert_contains "--machine q35" "$args"
}

@test "boot: uefi-secure enrolls keys and turns on SMM" {
  stub_boot_tools
  run bash "$SCRIPT" --config "$(prep)" boot "$(fake_image)" uefi-secure
  assert_success
  local args; args="$(stub_args virt-install)"
  assert_contains "secure-boot" "$args"
  assert_contains "enrolled-keys" "$args"   # else the signed shim will not validate
  assert_contains "--features smm.state=on" "$args"
  assert_contains "--machine q35" "$args"
}

@test "boot: an unknown firmware mode is refused" {
  stub_boot_tools
  run bash "$SCRIPT" --config "$(prep)" boot "$(fake_image)" coreboot
  assert_failure
  assert_contains "unknown firmware mode 'coreboot'"
}

@test "boot: OVMF_CODE pins the loader; NVRAM_PATH pins the varstore" {
  stub_boot_tools
  local conf; conf="$(prep "OVMF_CODE=/usr/share/edk2/ovmf/OVMF_CODE.fd" \
                           "NVRAM_PATH=$TMP/vars.fd")"
  run bash "$SCRIPT" --config "$conf" boot "$(fake_image)" uefi
  assert_success
  local args; args="$(stub_args virt-install)"
  assert_contains "loader=/usr/share/edk2/ovmf/OVMF_CODE.fd" "$args"
  assert_contains "loader.readonly=yes" "$args"
  assert_contains "nvram=$TMP/vars.fd" "$args"
}

# ---------------------------------------------------------------------- TPM

@test "boot: TPM=no attaches no TPM" {
  stub_boot_tools
  run bash "$SCRIPT" --config "$(prep "TPM=no")" boot "$(fake_image)"
  assert_success
  refute_contains "--tpm" "$(stub_args virt-install)"
}

@test "boot: TPM=yes attaches an emulated TPM 2.0" {
  stub_boot_tools
  run bash "$SCRIPT" --config "$(prep "TPM=yes")" boot "$(fake_image)"
  assert_success
  assert_contains "backend.version=2.0" "$(stub_args virt-install)"
}

@test "boot: TPM=yes without swtpm on the host is refused" {
  stub virt-install; stub qemu-img; stub cloud-localds; stub_virsh   # no swtpm
  run bash "$SCRIPT" --config "$(prep "TPM=yes")" boot "$(fake_image)"
  assert_failure
  assert_contains "required command not found: swtpm"
}

# ------------------------------------------------------------------ network

@test "boot: a virtio NIC is pinned when the config does not choose a model" {
  stub_boot_tools
  run bash "$SCRIPT" --config "$(prep "$BRIDGE")" boot "$(fake_image)"
  assert_success
  assert_contains "bridge=virbr0,model=virtio" "$(stub_args virt-install)"
}

@test "boot: an explicit model in NETWORK is respected, not overridden" {
  stub_boot_tools
  run bash "$SCRIPT" --config "$(prep "NETWORK=bridge=virbr0,model=e1000e")" boot "$(fake_image)"
  assert_success
  local args; args="$(stub_args virt-install)"
  assert_contains "model=e1000e" "$args"
  refute_contains "model=virtio" "$args"
}

# ------------------------------------------------------- domain collision safety

@test "boot: a domain that does not exist yet sails straight through" {
  stub_boot_tools     # no domstate file -> domain absent
  run bash "$SCRIPT" --config "$(prep)" boot "$(fake_image)"
  assert_success
  refute_contains "replacing" "$output"
}

@test "boot: a RUNNING domain of the same name is NOT clobbered without --replace" {
  stub_boot_tools
  set_domstate "running"
  run bash "$SCRIPT" --config "$(prep)" boot "$(fake_image)"
  assert_failure
  assert_contains "refusing to replace a live guest"
  # And it really did not touch it.
  refute_contains "destroy" "$(stub_args virsh)"
}

@test "boot: --replace does replace a running domain" {
  stub_boot_tools
  set_domstate "running"
  run bash "$SCRIPT" --config "$(prep)" boot --replace "$(fake_image)"
  assert_success
  assert_contains "replacing active domain" "$output"
  assert_contains "destroy" "$(stub_args virsh)"
}

@test "boot: a shut-off domain is this guest's own prior instance — replaced, no flag needed" {
  stub_boot_tools
  set_domstate "shut off"
  run bash "$SCRIPT" --config "$(prep)" boot "$(fake_image)"
  assert_success
  assert_contains "replacing existing (inactive) domain" "$output"
}

@test "boot: undefining also clears the UEFI nvram and the TPM state" {
  stub_boot_tools
  set_domstate "shut off"
  run bash "$SCRIPT" --config "$(prep)" boot "$(fake_image)"
  assert_success
  assert_contains "undefine" "$(stub_args virsh)"
  assert_contains "--nvram" "$(stub_args virsh)"
}

# ------------------------------------------------------------------- overlay

@test "boot: an overlay is created from the pristine base" {
  stub_boot_tools
  run bash "$SCRIPT" --config "$(prep)" boot "$(fake_image)"
  assert_success
  local args; args="$(stub_args qemu-img)"
  assert_contains "create -f qcow2 -F qcow2" "$args"
  assert_contains "fedora-cloud-01.qcow2" "$args"
}

@test "boot: an existing overlay is reused — cloud-init does not re-run by accident" {
  stub_boot_tools
  local conf; conf="$(prep)"
  printf 'existing\n' > "$TMP/overlay/fedora-cloud-01.qcow2"
  run bash "$SCRIPT" --config "$conf" boot "$(fake_image)"
  assert_success
  [ -z "$(stub_args qemu-img)" ]     # never called
}

@test "boot: --fresh recreates the overlay, so cloud-init runs again" {
  stub_boot_tools
  local conf; conf="$(prep)"
  printf 'existing\n' > "$TMP/overlay/fedora-cloud-01.qcow2"
  run bash "$SCRIPT" --config "$conf" boot --fresh "$(fake_image)"
  assert_success
  assert_contains "create -f qcow2" "$(stub_args qemu-img)"
}

# --------------------------------------------------------------- seed delivery

@test "boot: seed-iso is attached as a cdrom" {
  stub_boot_tools
  local conf; conf="$(prep "SEED_METHOD=seed-iso")"
  touch "$TMP/overlay/build/fedora-cloud-01/seed.iso"   # the stubbed build made none
  run bash "$SCRIPT" --config "$conf" boot "$(fake_image)"
  assert_success
  assert_contains "device=cdrom" "$(stub_args virt-install)"
}

@test "boot: the cloud-init seed method hands the files to virt-install instead" {
  stub_boot_tools
  run bash "$SCRIPT" --config "$(prep "SEED_METHOD=cloud-init")" boot "$(fake_image)"
  assert_success
  local args; args="$(stub_args virt-install)"
  assert_contains "--cloud-init" "$args"
  assert_contains "user-data=" "$args"
  refute_contains "device=cdrom" "$args"
}

# ----------------------------------------------------------------- the hints

@test "boot: prints ssh lines pointing at the resolved guest IP" {
  stub_boot_tools
  run bash "$SCRIPT" --config "$(prep "$BRIDGE")" boot "$(fake_image)"
  assert_success
  assert_contains "192.168.122.10"
  assert_contains "ssh -i"
  assert_contains "admin@192.168.122.10"
}

@test "boot: prints the cifs mount line only when the share exists" {
  stub_boot_tools
  run bash "$SCRIPT" --config "$(prep "$BRIDGE" "SAMBA=yes")" boot "$(fake_image)"
  assert_success
  assert_contains "mount -t cifs //192.168.122.10/projects"
  assert_contains "seal"          # the server requires encryption
  assert_contains "credentials="

  run bash "$SCRIPT" --config "$(prep "$BRIDGE" "SAMBA=no")" boot "$(fake_image)"
  assert_success
  refute_contains "mount -t cifs"
}

@test "boot: NETWORK=user says plainly that there is no queryable lease" {
  stub_boot_tools
  run bash "$SCRIPT" --config "$(prep "NETWORK=user")" boot "$(fake_image)"
  assert_success
  assert_contains "no queryable lease"
}

# ------------------------------------------------------------------------ run

@test "run: the UKI image is UEFI-only, and that is caught before any download" {
  # No network stubs at all: if this reached the fetch, it would fail differently.
  run bash "$SCRIPT" --config "$(mkconf "IMAGE_VARIANT=uki")" run bios
  assert_failure
  assert_contains "IMAGE_VARIANT=uki is UEFI-only"
}

@test "run: an unknown argument is refused" {
  run bash "$SCRIPT" --config "$(mkconf)" run --wat
  assert_failure
  assert_contains "usage:"
}

@test "run: needs curl, gpgv, sha256sum and flock" {
  # curl and friends ARE installed in the test image (cloud-init drags them in),
  # so a plain /usr/bin would sail past the _need gate and go on to hit the
  # network. Take curl away specifically: _need runs before any fetch, and its
  # whole job is to fail here, by name.
  PATH="$(path_without curl)" run bash "$SCRIPT" --config "$(mkconf)" run
  assert_failure
  assert_contains "required command not found: curl"
}
