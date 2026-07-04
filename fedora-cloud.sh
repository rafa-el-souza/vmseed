#!/usr/bin/env bash
#
# fedora-cloud.sh — provision a Fedora Cloud image with cloud-init and boot it
# under libvirt. Two SSH-only users (standard + admin), hardened sshd, verified
# image downloads. Covers both the traditional (BIOS) and UKI (UEFI) variants.
#
# Requires bash >= 4.3 (namerefs, dynamic-scope locals).
#
# PUBLIC API (subcommands):
#   build                                 render keys into build/user-data (+seed.iso)
#   boot [--fresh] <image> [MODE]         boot an existing image under libvirt
#   run  [MODE|--download-only]           download + verify + build + boot, end-to-end
#   help                                  show usage
#
#   MODE = bios | uefi | uefi-secure      (bios -> Generic image, uefi* -> UKI image)
#
# Everything below lives inside main(): there are no global variables — the
# nested cmd_*/_* functions read main's locals via bash dynamic scoping.
# Naming: cmd_*  = public commands,  _*  = private helpers.
set -euo pipefail

main() {
  # ========================= CONFIGURATION =========================
  # All values are locals; override any of them via the matching env var.
  local self="${0##*/}"
  local script_dir; script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

  # Paths / seed
  local template="${TEMPLATE:-$script_dir/user-data.yaml}"
  local keys_dir="${KEYS_DIR:-$script_dir/keys}"
  local std_key_file="${STD_KEY_FILE:-$keys_dir/appuser.pub}"
  local adm_key_file="${ADM_KEY_FILE:-$keys_dir/admin.pub}"
  local build_dir="${BUILD_DIR:-$script_dir/build}"
  local images_dir="${IMAGES_DIR:-$script_dir/images}"
  local instance_id="${INSTANCE_ID:-fedora-01}"
  local vm_hostname="${VM_HOSTNAME:-fedora-01}"

  # libvirt / boot
  local domain="${DOMAIN:-fedora-cloud-01}"
  local ram_mb="${RAM_MB:-2048}"
  local vcpus="${VCPUS:-2}"
  local libvirt_uri="${LIBVIRT_URI:-qemu:///system}"
  local network="${NETWORK:-network=default}"
  local osinfo="${OSINFO:-detect=on,require=off}"
  local ovmf_code="${OVMF_CODE:-}"

  # download / verification
  local ver="${VER:-44}"
  local arch="${ARCH:-x86_64}"
  local base_url="https://download.fedoraproject.org/pub/fedora/linux/releases/${ver}/Cloud/${arch}/images"
  local fedora_gpg_url="${FEDORA_GPG_URL:-https://fedoraproject.org/fedora.gpg}"
  local checksum_url="${CHECKSUM_URL:-}"
  local compose="${COMPOSE:-}"

  # ===================== PRIVATE API (helpers) =====================
  # Diagnostics go to stderr so a function's stdout is only its return value.
  _log()  { printf '==> %s\n' "$*" >&2; }
  _note() { printf 'note: %s\n' "$*" >&2; }
  _die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

  _need() {  # _need <bin>...  — fail unless every binary is on PATH
    local bin
    for bin in "$@"; do
      command -v "$bin" >/dev/null 2>&1 || _die "required command not found: $bin"
    done
  }

  _assert_pubkey() {  # reject private keys / garbage before they reach the guest
    local key="$1"
    case "$key" in
      ssh-*|ecdsa-*|sk-*)  return 0 ;;
      *"PRIVATE KEY"*)     _die "a key file contains a PRIVATE key — use the .pub file" ;;
      *)                   _die "not an SSH public key: ${key:0:40}..." ;;
    esac
  }

  _render_user_data() {  # _render_user_data <std_key> <adm_key>  -> user-data on stdout
    # awk (not sed) so special chars in a key can't break substitution.
    awk -v std="$1" -v adm="$2" '
      { gsub(/PLACEHOLDER_STANDARD_KEY/, std); gsub(/PLACEHOLDER_ADMIN_KEY/, adm); print }
    ' "$template"
  }

  _validate_seed() {  # cloud-init schema check, if cloud-init is installed
    local userdata="$1"
    if command -v cloud-init >/dev/null 2>&1; then
      _log "validating user-data schema"
      cloud-init schema --config-file "$userdata" --annotate
    else
      _note "cloud-init not installed; skipping schema validation"
    fi
  }

  _build_seed_iso() {  # optional NoCloud ISO for non-libvirt/manual qemu flows
    local dir="$1"
    if command -v cloud-localds >/dev/null 2>&1; then
      _log "building seed.iso"
      cloud-localds "$dir/seed.iso" "$dir/user-data" "$dir/meta-data"
    else
      _note "cloud-localds not found (install cloud-utils); wrote user-data + meta-data only"
    fi
  }

  _firmware_args() {  # _firmware_args <mode> <out_array_name>  — populate virt-install --boot
    local mode="$1"
    local -n _ref="$2"
    _ref=()
    case "$mode" in
      bios) ;;  # default SeaBIOS; no --boot needed
      uefi)
        if [[ -n "$ovmf_code" ]]; then
          _ref=(--boot "uefi,loader=${ovmf_code},loader.readonly=yes,loader.type=pflash")
        else
          _ref=(--boot uefi)  # libvirt firmware autoselection
        fi ;;
      uefi-secure)
        _ref=(--boot "uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=yes") ;;
      *) _die "unknown firmware mode '$mode' (use: bios|uefi|uefi-secure)" ;;
    esac
  }

  _undefine_domain() {  # tear down a prior domain of the same name, incl. UEFI nvram
    local dom="$1"
    if virsh --connect "$libvirt_uri" dominfo "$dom" >/dev/null 2>&1; then
      _log "removing existing domain '$dom'"
      virsh --connect "$libvirt_uri" destroy  "$dom"          >/dev/null 2>&1 || true
      virsh --connect "$libvirt_uri" undefine "$dom" --nvram  >/dev/null 2>&1 || true
    fi
  }

  _make_overlay() {  # boot from a qcow2 overlay so the base image stays pristine
    local base="$1" overlay="$2" fresh="$3"
    if [[ "$fresh" == "1" || ! -f "$overlay" ]]; then
      _log "creating overlay $overlay (backing: $base)"
      rm -f "$overlay"
      qemu-img create -f qcow2 -F qcow2 -b "$(realpath "$base")" "$overlay" >/dev/null
    fi
  }

  _print_connect_help() {
    printf '\n' >&2
    _log "booted. Once cloud-init has run:"
    printf '      virsh --connect %s domifaddr %s\n' "$libvirt_uri" "$domain" >&2
    printf '      ssh -i keys/admin   admin@<IP>\n'                            >&2
    printf '      ssh -i keys/appuser appuser@<IP>\n'                          >&2
    printf '    console: virsh --connect %s console %s   (Ctrl+] to exit)\n' "$libvirt_uri" "$domain" >&2
  }

  _fetch_keyring() {  # cache Fedora's OpenPGP keyring locally
    local keyring="$1"
    if [[ ! -s "$keyring" ]]; then
      _log "fetching Fedora OpenPGP keyring: $fedora_gpg_url"
      curl -fsSL "$fedora_gpg_url" -o "$keyring"
    fi
  }

  _resolve_checksum_url() {  # -> CHECKSUM url on stdout (env > compose > mirror discovery)
    if [[ -n "$checksum_url" ]]; then
      printf '%s\n' "$checksum_url"; return 0
    fi
    if [[ -n "$compose" ]]; then
      printf '%s/Fedora-Cloud-%s-%s-%s-CHECKSUM\n' "$base_url" "$ver" "$compose" "$arch"; return 0
    fi
    _log "discovering CHECKSUM filename from $base_url/"
    local name
    name="$(curl -fsSL "$base_url/" \
      | grep -oE "Fedora-Cloud-[0-9]+-[0-9.]+-${arch}-CHECKSUM" \
      | sort -u | tail -1 || true)"
    [[ -n "$name" ]] || _die "could not auto-discover CHECKSUM; set CHECKSUM_URL or COMPOSE and retry"
    printf '%s/%s\n' "$base_url" "$name"
  }

  _pick_image() {  # _pick_image <verified_checksum> <generic|uki>  -> qcow2 filename
    local checksum_file="$1" kind="$2" all
    all="$(grep -oE 'Fedora-Cloud-[^ )]*\.qcow2' "$checksum_file" | sort -u)"
    case "$kind" in
      uki)     printf '%s\n' "$all" | grep -iE  'UKI' | tail -1 || true ;;
      generic) printf '%s\n' "$all" | grep -viE 'UKI' | tail -1 || true ;;
    esac
  }

  _fetch_and_verify_image() {  # download (if absent) then check SHA-256 against verified CHECKSUM
    local img="$1" checksum_file="$2"
    [[ -n "$img" ]] || _die "image name not found in CHECKSUM"
    local dest="$images_dir/$img"
    if [[ ! -s "$dest" ]]; then
      _log "downloading $img"
      curl -fL --progress-bar "$base_url/$img" -o "$dest"
    else
      _log "$img already present, skipping download"
    fi
    _log "verifying SHA-256 of $img"
    local line
    line="$( cd "$images_dir" \
      && sha256sum -c --ignore-missing "$(basename "$checksum_file")" 2>/dev/null \
      | grep -E "^${img}:" || true )"
    [[ "$line" == "${img}: OK" ]] || _die "checksum verification FAILED for $img"
    _log "checksum OK"
  }

  # ===================== PUBLIC API (commands) =====================
  cmd_build() {
    _need awk
    local f
    for f in "$template" "$std_key_file" "$adm_key_file"; do
      [[ -f "$f" ]] || _die "missing required file: $f"
    done
    local std_key adm_key
    std_key="$(< "$std_key_file")"
    adm_key="$(< "$adm_key_file")"
    _assert_pubkey "$std_key"
    _assert_pubkey "$adm_key"

    mkdir -p "$build_dir"
    _render_user_data "$std_key" "$adm_key" > "$build_dir/user-data"
    printf 'instance-id: %s\nlocal-hostname: %s\n' "$instance_id" "$vm_hostname" > "$build_dir/meta-data"

    _validate_seed "$build_dir/user-data"
    _build_seed_iso "$build_dir"
    _log "seed ready: $build_dir/user-data"
  }

  cmd_boot() {
    local fresh=0
    if [[ "${1:-}" == "--fresh" ]]; then fresh=1; shift; fi
    local image="${1:-}"
    [[ -n "$image" ]] || _die "usage: $self boot [--fresh] <image.qcow2> [bios|uefi|uefi-secure]"
    local mode="${2:-bios}"

    _need virt-install virsh qemu-img
    local f
    for f in "$build_dir/user-data" "$build_dir/meta-data"; do
      [[ -f "$f" ]] || _die "$f not found — run '$self build' first"
    done
    [[ -f "$image" ]] || _die "image not found: $image"

    local -a boot_args
    _firmware_args "$mode" boot_args

    _undefine_domain "$domain"

    local overlay="$build_dir/${domain}.qcow2"
    _make_overlay "$image" "$overlay" "$fresh"

    _log "starting '$domain' [$mode] via $libvirt_uri"
    virt-install \
      --connect "$libvirt_uri" \
      --name "$domain" \
      --memory "$ram_mb" \
      --vcpus "$vcpus" \
      --osinfo "$osinfo" \
      --import \
      --disk "path=$overlay,format=qcow2,bus=virtio" \
      --cloud-init "user-data=$build_dir/user-data,meta-data=$build_dir/meta-data" \
      --network "$network" \
      --graphics none \
      --noautoconsole \
      "${boot_args[@]}"

    _print_connect_help
  }

  cmd_run() {
    local mode="${1:-bios}" download_only=0
    case "$mode" in
      --download-only)        download_only=1 ;;
      bios|uefi|uefi-secure)  ;;
      *) _die "usage: $self run [bios|uefi|uefi-secure|--download-only]" ;;
    esac

    _need curl gpgv sha256sum
    mkdir -p "$images_dir"

    local keyring="$images_dir/fedora.gpg"
    _fetch_keyring "$keyring"

    local checksum_url_resolved checksum_raw="$images_dir/CHECKSUM"
    checksum_url_resolved="$(_resolve_checksum_url)"
    _log "fetching CHECKSUM: $checksum_url_resolved"
    curl -fsSL "$checksum_url_resolved" -o "$checksum_raw"

    # Verify signature AND strip to plaintext in one step; fails on a bad sig.
    local checksum_verified="$images_dir/CHECKSUM.verified"
    _log "verifying CHECKSUM signature against Fedora keyring"
    gpgv --keyring "$keyring" --output "$checksum_verified" "$checksum_raw"
    _log "signature OK"

    # Resolve image filenames FROM the verified checksum — nothing hardcoded.
    local generic_img uki_img
    generic_img="$(_pick_image "$checksum_verified" generic)"
    uki_img="$(_pick_image "$checksum_verified" uki)"

    if [[ "$download_only" == "1" ]]; then
      _fetch_and_verify_image "$generic_img" "$checksum_verified"
      _fetch_and_verify_image "$uki_img"     "$checksum_verified"
      _log "verified images in $images_dir:"
      printf '      generic (bios): %s\n' "$generic_img" >&2
      printf '      uki (uefi):     %s\n' "$uki_img"     >&2
      return 0
    fi

    local image
    case "$mode" in
      bios)             image="$generic_img" ;;
      uefi|uefi-secure) image="$uki_img" ;;
    esac
    _fetch_and_verify_image "$image" "$checksum_verified"

    cmd_build
    _log "booting [$mode]"
    cmd_boot "$images_dir/$image" "$mode"
  }

  cmd_help() {
    cat >&2 <<EOF
$self — provision & boot a Fedora Cloud image with cloud-init

Usage:
  $self build                              render keys/*.pub into build/user-data
  $self boot [--fresh] <image> [MODE]      boot an existing image under libvirt
  $self run  [MODE|--download-only]        download + verify + build + boot
  $self help                               this message

MODE:
  bios         Cloud Base Generic image (traditional hybrid)   [default]
  uefi         Cloud Base UKI image (UEFI-only)
  uefi-secure  Cloud Base UKI image + Secure Boot

Examples:
  $self run                 # fetch+verify+boot the BIOS image
  $self run uefi            # ... the UKI image under UEFI
  $self run --download-only # fetch+verify BOTH variants, no boot
  $self boot --fresh images/Fedora-Cloud-Base-Generic-44-1.5.x86_64.qcow2 bios

Config is via env vars (see the CONFIGURATION block): VER, ARCH, DOMAIN,
RAM_MB, VCPUS, LIBVIRT_URI, OVMF_CODE, COMPOSE, CHECKSUM_URL, ...
EOF
  }

  # ========================== DISPATCH ==========================
  local subcommand="${1:-help}"
  shift || true
  case "$subcommand" in
    build)          cmd_build "$@" ;;
    boot)           cmd_boot  "$@" ;;
    run)            cmd_run   "$@" ;;
    help|-h|--help) cmd_help ;;
    *) _die "unknown command '$subcommand' (try: $self help)" ;;
  esac
}

main "$@"
