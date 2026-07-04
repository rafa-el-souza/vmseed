#!/usr/bin/env bash
#
# fedora-cloud.sh — provision a Fedora Cloud image with cloud-init and boot it
# under libvirt. Two SSH-only users (standard + admin), hardened sshd, verified
# image downloads. Covers both the traditional (BIOS) and UKI (UEFI) variants.
#
# Requires bash >= 4.3 (namerefs, associative arrays, dynamic-scope locals).
#
# PUBLIC API (subcommands):
#   build                                 render keys into build/user-data (+seed.iso)
#   boot [--fresh] <image> [MODE]         boot an existing image under libvirt
#   run  [MODE|--download-only]           download + verify + build + boot, end-to-end
#   help                                  show usage
#
#   MODE = bios | uefi | uefi-secure      (bios -> Generic image, uefi* -> UKI image)
#
# GLOBAL OPTION:
#   --config <file>   Load configuration from a KEY=VALUE file. REQUIRED for
#                     build/boot/run (help does not need it). See the shipped
#                     fedora-cloud.conf.example for the recognised keys.
#
# Configuration comes only from the --config file (no environment variables).
# The file is parsed, never sourced, and every value is strictly validated.
#
# Everything below lives inside main(): there are no global variables — the
# nested cmd_*/_* functions read main's locals via bash dynamic scoping.
# Naming: cmd_*  = public commands,  _*  = private helpers.
set -euo pipefail

main() {
  local self="${0##*/}"
  local script_dir; script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

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

  _require_config() {  # gate for commands that cannot run without a config file
    [[ -n "$config_file" ]] || _die "'--config <file>' is required for the '$1' command"
  }

  _require_overlay_dir() {  # OVERLAY_IMAGE_DIR has no default — must be configured
    [[ -n "$overlay_image_dir" ]] \
      || _die "OVERLAY_IMAGE_DIR is required in the config for the '$1' command"
  }

  _require_base_dir() {  # BASE_IMAGE_DIR has no default — needed for downloads
    [[ -n "$base_image_dir" ]] \
      || _die "BASE_IMAGE_DIR is required in the config for the 'run' command"
  }

  # ---- config: known keys, per-key validation, strict KEY=VALUE parser ----
  _is_known_key() {
    case "$1" in
      TEMPLATE|KEYS_DIR|STD_KEY_FILE|ADM_KEY_FILE|TMUX_CONF|OVERLAY_IMAGE_DIR|\
      BASE_IMAGE_DIR|STD_USER|ADMIN_USER|GENERATE_KEYS|ENCRYPT_KEYS|SEED_METHOD|\
      INSTANCE_ID|VM_HOSTNAME|DOMAIN|RAM_MB|VCPUS|LIBVIRT_URI|NETWORK|OSINFO|OVMF_CODE|\
      NVRAM_PATH|VER|ARCH|FEDORA_GPG_URL|CHECKSUM_URL|COMPOSE) return 0 ;;
      *) return 1 ;;
    esac
  }

  _validate_value() {  # _validate_value <key> <value> <lineno>  — die on bad input
    local key="$1" val="$2" ln="$3"
    [[ -n "$val" ]] || _die "config:$ln: empty value for $key"
    local where="config:$ln: $key"
    case "$key" in
      RAM_MB|VCPUS|VER)
        [[ "$val" =~ ^[1-9][0-9]*$ ]] || _die "$where must be a positive integer, got '$val'" ;;
      ARCH)
        case "$val" in x86_64|aarch64|ppc64le|s390x) ;; *) _die "$where invalid: '$val'" ;; esac ;;
      COMPOSE)
        [[ "$val" =~ ^[0-9]+(\.[0-9]+)*$ ]] || _die "$where must look like N or N.N, got '$val'" ;;
      FEDORA_GPG_URL|CHECKSUM_URL)
        { [[ "$val" == https://* ]] && [[ "$val" != *[[:space:]]* ]]; } \
          || _die "$where must be an https:// URL with no whitespace" ;;
      LIBVIRT_URI)
        [[ "$val" =~ ^[a-z]+(\+[a-z]+)?:// ]] || _die "$where must be a libvirt URI (e.g. qemu:///session)" ;;
      DOMAIN|INSTANCE_ID|VM_HOSTNAME)
        [[ "$val" =~ ^[A-Za-z0-9._-]+$ ]] || _die "$where may contain only [A-Za-z0-9._-], got '$val'" ;;
      GENERATE_KEYS|ENCRYPT_KEYS)
        [[ "$val" =~ ^(yes|no)$ ]] || _die "$where must be 'yes' or 'no', got '$val'" ;;
      SEED_METHOD)
        [[ "$val" =~ ^(seed-iso|cloud-init)$ ]] || _die "$where must be 'seed-iso' or 'cloud-init', got '$val'" ;;
      STD_USER|ADMIN_USER)
        [[ "$val" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
          || _die "$where must be a valid Linux username (^[a-z_][a-z0-9_-]{0,31}$), got '$val'"
        # Reserved: always-present root, the distro default user kept by
        # `- default` (fedora), the cloud-init keyword, and common system
        # accounts on the base image — creating any of these would collide.
        case "$val" in
          root|default|fedora|nobody|bin|daemon|adm|sync|shutdown|halt|mail|operator|games|ftp|sshd)
            _die "$where '$val' is a reserved/system account; choose another name" ;;
        esac ;;
      OSINFO)
        [[ "$val" =~ ^[A-Za-z0-9=,._:-]+$ ]] || _die "$where has invalid characters: '$val'" ;;
      NETWORK)
        [[ "$val" =~ ^[A-Za-z0-9=,._:/-]+$ ]] || _die "$where has invalid characters: '$val'" ;;
      TEMPLATE|KEYS_DIR|STD_KEY_FILE|ADM_KEY_FILE|TMUX_CONF|OVERLAY_IMAGE_DIR|BASE_IMAGE_DIR|OVMF_CODE|NVRAM_PATH)
        [[ "$val" != *[[:space:]]* ]] || _die "$where (a path) must not contain whitespace" ;;
    esac
  }

  _load_config() {  # _load_config <file>  — parse into cfg[]; strict, never sourced
    local file="$1" lineno=0 line key val
    [[ -f "$file" ]] || _die "config file not found: $file"
    [[ -r "$file" ]] || _die "config file not readable: $file"
    while IFS= read -r line || [[ -n "$line" ]]; do
      lineno=$((lineno + 1))
      line="${line#"${line%%[![:space:]]*}"}"   # ltrim
      line="${line%"${line##*[![:space:]]}"}"   # rtrim
      [[ -z "$line" || "$line" == \#* ]] && continue
      [[ "$line" == *=* ]] || _die "config:$lineno: not KEY=VALUE: '$line'"
      key="${line%%=*}"; val="${line#*=}"
      # Strip a trailing inline comment: whitespace followed by '#'. None of the
      # recognised values contain a space-then-'#', so this is safe (a '#' with
      # no leading whitespace, e.g. in a hash, is kept).
      val="${val%%[[:space:]]#*}"
      key="${key%"${key##*[![:space:]]}"}"; key="${key#"${key%%[![:space:]]*}"}"
      val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
      _is_known_key "$key" || _die "config:$lineno: unknown key: '$key'"
      _validate_value "$key" "$val" "$lineno"
      cfg["$key"]="$val"
    done < "$file"
  }

  # ---- build helpers ----
  _assert_pubkey() {  # reject private keys / garbage before they reach the guest
    local key="$1"
    case "$key" in
      ssh-*|ecdsa-*|sk-*)  return 0 ;;
      *"PRIVATE KEY"*)     _die "a key file contains a PRIVATE key — use the .pub file" ;;
      *)                   _die "not an SSH public key: ${key:0:40}..." ;;
    esac
  }

  _ensure_keypair() {  # _ensure_keypair <pubfile> <comment> — create the key if absent
    local pub="$1" comment="$2"
    [[ -f "$pub" ]] && return 0
    # Missing key. Only generate it if the operator opted in (GENERATE_KEYS=yes).
    [[ "$generate_keys" == "yes" ]] \
      || _die "key file not found: $pub (GENERATE_KEYS=no — create it, or set GENERATE_KEYS=yes)"
    # To create it we need the .pub naming convention so we can derive the
    # private-key path.
    [[ "$pub" == *.pub ]] \
      || _die "key file '$pub' does not exist and can't be auto-generated (its name must end in .pub)"
    _need ssh-keygen
    local priv="${pub%.pub}" dir
    dir="$(dirname "$pub")"
    mkdir -p "$dir" && chmod 700 "$dir"
    if [[ -f "$priv" ]]; then
      # Private key exists but its public half is gone — derive it, don't clobber.
      _log "deriving public key from existing private key: $priv"
      ssh-keygen -y -f "$priv" > "$pub"
    elif [[ "$encrypt_keys" == "no" ]]; then
      # Non-interactive: empty passphrase. -a (KDF rounds) is a no-op here.
      _log "no key at $pub — generating an UNENCRYPTED ed25519 key pair (ENCRYPT_KEYS=no)"
      ssh-keygen -t ed25519 -a 100 -N '' -f "$priv" -C "$comment"
    else
      # Interactive: ssh-keygen prompts the operator for a passphrase.
      _log "no key at $pub — generating an ed25519 key pair (ssh-keygen will prompt for a passphrase)"
      ssh-keygen -t ed25519 -a 100 -f "$priv" -C "$comment"
    fi
    [[ -f "$pub" ]] || _die "failed to create $pub"
  }

  _render_user_data() {  # _render_user_data <std_key> <adm_key> <tmux_b64> <std_user> <admin_user>
    # awk (not sed) so special chars in a value can't break substitution. The
    # replacement text is passed literally (gsub's target is a fixed string here,
    # and none of the values contain awk's '&' backreference character).
    awk -v std="$1" -v adm="$2" -v tmux="$3" -v su="$4" -v au="$5" '
      {
        gsub(/PLACEHOLDER_STANDARD_KEY/, std)
        gsub(/PLACEHOLDER_ADMIN_KEY/, adm)
        gsub(/PLACEHOLDER_TMUX_CONF_B64/, tmux)
        gsub(/PLACEHOLDER_STD_USER/, su)
        gsub(/PLACEHOLDER_ADMIN_USER/, au)
        print
      }
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

  _build_seed_iso() {  # build the NoCloud cidata ISO (caller has ensured cloud-localds)
    local dir="$1"
    _log "building seed.iso"
    cloud-localds "$dir/seed.iso" "$dir/user-data" "$dir/meta-data"
  }

  # ---- boot helpers ----
  _firmware_args() {  # _firmware_args <mode> <out_array_name>  — populate virt-install --boot
    local mode="$1"
    local -n _ref="$2"
    _ref=()
    local boot
    case "$mode" in
      bios) return 0 ;;  # default SeaBIOS; no --boot needed (nvram is UEFI-only)
      uefi)
        if [[ -n "$ovmf_code" ]]; then
          boot="uefi,loader=${ovmf_code},loader.readonly=yes,loader.type=pflash"
        else
          boot="uefi"  # libvirt firmware autoselection
        fi ;;
      uefi-secure)
        boot="uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=yes" ;;
      *) _die "unknown firmware mode '$mode' (use: bios|uefi|uefi-secure)" ;;
    esac
    # Custom per-VM UEFI varstore path; overrides autoselection's default
    # location while keeping template-based init. Empty -> libvirt's default.
    [[ -n "$nvram_path" ]] && boot+=",nvram=${nvram_path}"
    _ref=(--boot "$boot")
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
    _log "booted. Reach the guest on the serial console:"
    printf '      virsh --connect %s console %s   (Ctrl+] to exit)\n' "$libvirt_uri" "$domain" >&2
    case "$network" in
      network=*)
        # A libvirt-managed NAT network yields a queryable lease via domifaddr.
        _log "or find its IP and SSH in:"
        printf '      virsh --connect %s domifaddr %s\n' "$libvirt_uri" "$domain" >&2
        printf '      ssh -i %s %s@<IP>   /   ssh -i %s %s@<IP>\n' \
          "${adm_key_file%.pub}" "$admin_user" "${std_key_file%.pub}" "$std_user" >&2 ;;
      bridge=*)
        # Bridged: lease is served by whoever owns the bridge (e.g. virbr0's dnsmasq).
        _log "or find its IP on the bridge and SSH in:"
        printf '      virsh -c qemu:///system net-dhcp-leases default   # if bridged to virbr0\n' >&2
        printf '      ip neigh show dev %s\n' "${network#bridge=}" >&2
        printf '      ssh -i %s %s@<IP>   /   ssh -i %s %s@<IP>\n' \
          "${adm_key_file%.pub}" "$admin_user" "${std_key_file%.pub}" "$std_user" >&2 ;;
      *)
        # User-mode networking (session default): no queryable lease.
        _note "NETWORK=$network gives no queryable lease; use the console, or a bridge/system NAT for direct SSH" ;;
    esac
  }

  # ---- download / verification helpers ----
  _fetch_keyring() {  # cache Fedora's OpenPGP keyring locally
    local keyring="$1"
    if [[ ! -s "$keyring" ]]; then
      _log "fetching Fedora OpenPGP keyring: $fedora_gpg_url"
      curl -fsSL "$fedora_gpg_url" -o "$keyring"
    fi
  }

  _resolve_checksum_url() {  # -> CHECKSUM url on stdout (explicit > compose > mirror discovery)
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
    [[ -n "$name" ]] || _die "could not auto-discover CHECKSUM; set CHECKSUM_URL or COMPOSE in the config and retry"
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
    local dest="$base_image_dir/$img"
    if [[ ! -s "$dest" ]]; then
      _log "downloading $img"
      curl -fL --progress-bar "$base_url/$img" -o "$dest"
    else
      _log "$img already present, skipping download"
    fi
    _log "verifying SHA-256 of $img"
    local line
    line="$( cd "$base_image_dir" \
      && sha256sum -c --ignore-missing "$(basename "$checksum_file")" 2>/dev/null \
      | grep -E "^${img}:" || true )"
    [[ "$line" == "${img}: OK" ]] || _die "checksum verification FAILED for $img"
    _log "checksum OK"
  }

  # ===================== PUBLIC API (commands) =====================
  cmd_build() {
    _require_config build
    _require_overlay_dir build
    _need awk base64
    [[ "$std_user" != "$admin_user" ]] \
      || _die "STD_USER and ADMIN_USER must differ (both '$std_user')"
    local f
    for f in "$template" "$tmux_conf"; do
      [[ -f "$f" ]] || _die "missing required file: $f"
    done
    # SSH keys: use the files if present. If absent, GENERATE_KEYS=no fails;
    # GENERATE_KEYS=yes (default) creates them — ENCRYPT_KEYS=yes prompts for a
    # passphrase (once per key), ENCRYPT_KEYS=no makes it non-interactive.
    _ensure_keypair "$std_key_file" "$std_user"
    _ensure_keypair "$adm_key_file" "$admin_user"
    local std_key adm_key tmux_b64
    std_key="$(< "$std_key_file")"
    adm_key="$(< "$adm_key_file")"
    _assert_pubkey "$std_key"
    _assert_pubkey "$adm_key"
    # Inject the tmux config as a single base64 line (encoding: b64 in the
    # template) so multi-line content can't break YAML indentation.
    tmux_b64="$(base64 -w0 < "$tmux_conf")"

    # Seed artifacts live in the build/ subdir of the overlay image dir.
    local seed_dir="$overlay_image_dir/build"
    mkdir -p "$seed_dir"
    _render_user_data "$std_key" "$adm_key" "$tmux_b64" "$std_user" "$admin_user" > "$seed_dir/user-data"
    printf 'instance-id: %s\nlocal-hostname: %s\n' "$instance_id" "$vm_hostname" > "$seed_dir/meta-data"

    _validate_seed "$seed_dir/user-data"
    # SEED_METHOD=seed-iso: build the cidata ISO that boot attaches (cloud-localds
    # required). cloud-init: boot lets virt-install build its own seed, so skip.
    if [[ "$seed_method" == "seed-iso" ]]; then
      _need cloud-localds
      _build_seed_iso "$seed_dir"
    fi
    _log "seed ready: $seed_dir/user-data"
  }

  cmd_boot() {
    _require_config boot
    _require_overlay_dir boot
    local fresh=0
    if [[ "${1:-}" == "--fresh" ]]; then fresh=1; shift; fi
    local image="${1:-}"
    [[ -n "$image" ]] || _die "usage: $self --config <file> boot [--fresh] <image.qcow2> [bios|uefi|uefi-secure]"
    local mode="${2:-bios}"

    _need virt-install virsh qemu-img
    local seed_dir="$overlay_image_dir/build"
    # How the seed reaches the guest depends on SEED_METHOD:
    #   seed-iso    -> attach the cidata ISO built by `build` as a CDROM
    #   cloud-init  -> let virt-install build+attach its own seed from the files
    local -a seed_args
    if [[ "$seed_method" == "seed-iso" ]]; then
      [[ -f "$seed_dir/seed.iso" ]] \
        || _die "$seed_dir/seed.iso not found — run '$self --config <file> build' first (SEED_METHOD=seed-iso)"
      seed_args=(--disk "path=$seed_dir/seed.iso,device=cdrom")
    else
      local f
      for f in "$seed_dir/user-data" "$seed_dir/meta-data"; do
        [[ -f "$f" ]] || _die "$f not found — run '$self --config <file> build' first"
      done
      seed_args=(--cloud-init "user-data=$seed_dir/user-data,meta-data=$seed_dir/meta-data")
    fi
    [[ -f "$image" ]] || _die "image not found: $image"

    local -a boot_args
    _firmware_args "$mode" boot_args

    _undefine_domain "$domain"

    mkdir -p "$overlay_image_dir"
    local overlay="$overlay_image_dir/${domain}.qcow2"
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
      --network "$network" \
      --graphics none \
      --noautoconsole \
      "${seed_args[@]}" \
      "${boot_args[@]}"

    _print_connect_help
  }

  cmd_run() {
    _require_config run
    _require_base_dir
    local mode="${1:-bios}" download_only=0
    case "$mode" in
      --download-only)        download_only=1 ;;
      bios|uefi|uefi-secure)  ;;
      *) _die "usage: $self --config <file> run [bios|uefi|uefi-secure|--download-only]" ;;
    esac

    _need curl gpgv sha256sum
    mkdir -p "$base_image_dir"

    local keyring="$base_image_dir/fedora.gpg"
    _fetch_keyring "$keyring"

    local checksum_url_resolved checksum_raw="$base_image_dir/CHECKSUM"
    checksum_url_resolved="$(_resolve_checksum_url)"
    _log "fetching CHECKSUM: $checksum_url_resolved"
    curl -fsSL "$checksum_url_resolved" -o "$checksum_raw"

    # Verify signature AND strip to plaintext in one step; fails on a bad sig.
    local checksum_verified="$base_image_dir/CHECKSUM.verified"
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
      _log "verified images in $base_image_dir:"
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
    cmd_boot "$base_image_dir/$image" "$mode"
  }

  cmd_help() {
    cat >&2 <<EOF
$self — provision & boot a Fedora Cloud image with cloud-init

Usage:
  $self --config <file> build                         render SSH keys into build/user-data
  $self --config <file> boot [--fresh] <image> [MODE] boot an existing image under libvirt
  $self --config <file> run  [MODE|--download-only]   download + verify + build + boot
  $self help                                          this message

MODE:
  bios         Cloud Base Generic image (traditional hybrid)   [default]
  uefi         Cloud Base UKI image (UEFI-only)
  uefi-secure  Cloud Base UKI image + Secure Boot

Configuration:
  All settings come from the --config KEY=VALUE file (required for build/boot/run;
  no environment variables). Copy fedora-cloud.conf.example, edit it, and pass it
  with --config. Unknown keys and malformed values are rejected.

Examples:
  $self --config fedora-cloud.conf run                 # fetch+verify+boot BIOS image
  $self --config fedora-cloud.conf run uefi            # ... the UKI image under UEFI
  $self --config fedora-cloud.conf run --download-only # fetch+verify BOTH, no boot
  $self --config fedora-cloud.conf build
EOF
  }

  # ========================= CONFIGURATION =========================
  # Built-in defaults; every one is overridable via the --config file. Only
  # file-provided values are validated (defaults are trusted). STD_KEY_FILE /
  # ADM_KEY_FILE default to files under KEYS_DIR and are derived after loading.
  # OVERLAY_IMAGE_DIR and BASE_IMAGE_DIR have NO default — they must be set in
  # the config (OVERLAY_IMAGE_DIR for build/boot/run, BASE_IMAGE_DIR for run).
  local -A cfg=(
    [TEMPLATE]="$script_dir/user-data.yaml"
    [TMUX_CONF]="$script_dir/dotfiles/tmux.conf"
    [KEYS_DIR]="$HOME/.ssh"
    [STD_USER]="appuser"
    [ADMIN_USER]="admin"
    [GENERATE_KEYS]="yes"
    [ENCRYPT_KEYS]="yes"
    [SEED_METHOD]="seed-iso"
    [INSTANCE_ID]="fedora-01"
    [VM_HOSTNAME]="fedora-01"
    [DOMAIN]="fedora-cloud-01"
    [RAM_MB]="2048"
    [VCPUS]="2"
    [LIBVIRT_URI]="qemu:///session"
    [NETWORK]="user"
    [OSINFO]="detect=on,require=off"
    [VER]="44"
    [ARCH]="x86_64"
    [FEDORA_GPG_URL]="https://fedoraproject.org/fedora.gpg"
  )

  # ---------------- global option parsing (--config) ---------------
  local config_file="" ; local -a rest=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)   shift; [[ $# -gt 0 ]] || _die "--config requires a file argument"; config_file="$1"; shift ;;
      --config=*) config_file="${1#*=}"; shift ;;
      --)         shift; while [[ $# -gt 0 ]]; do rest+=("$1"); shift; done ;;
      *)          rest+=("$1"); shift ;;
    esac
  done
  [[ -n "$config_file" ]] && _load_config "$config_file"

  # Derived defaults: key files are KEYS_DIR/<user>-<DOMAIN>.pub unless the config
  # sets them explicitly — so the per-VM keys don't collide across domains
  # (e.g. STD_USER=alice, DOMAIN=web01 -> KEYS_DIR/alice-web01.pub).
  : "${cfg[STD_KEY_FILE]:=${cfg[KEYS_DIR]}/${cfg[STD_USER]}-${cfg[DOMAIN]}.pub}"
  : "${cfg[ADM_KEY_FILE]:=${cfg[KEYS_DIR]}/${cfg[ADMIN_USER]}-${cfg[DOMAIN]}.pub}"

  # Project the validated config into readable locals used by the commands.
  local template="${cfg[TEMPLATE]}"
  local tmux_conf="${cfg[TMUX_CONF]}"
  local std_user="${cfg[STD_USER]}"
  local admin_user="${cfg[ADMIN_USER]}"
  local generate_keys="${cfg[GENERATE_KEYS]}"
  local encrypt_keys="${cfg[ENCRYPT_KEYS]}"
  local seed_method="${cfg[SEED_METHOD]}"
  local std_key_file="${cfg[STD_KEY_FILE]}"
  local adm_key_file="${cfg[ADM_KEY_FILE]}"
  # Required (no default); presence is enforced per-command by _require_* below.
  local overlay_image_dir="${cfg[OVERLAY_IMAGE_DIR]:-}"
  local base_image_dir="${cfg[BASE_IMAGE_DIR]:-}"
  local instance_id="${cfg[INSTANCE_ID]}"
  local vm_hostname="${cfg[VM_HOSTNAME]}"
  local domain="${cfg[DOMAIN]}"
  local ram_mb="${cfg[RAM_MB]}"
  local vcpus="${cfg[VCPUS]}"
  local libvirt_uri="${cfg[LIBVIRT_URI]}"
  local network="${cfg[NETWORK]}"
  local osinfo="${cfg[OSINFO]}"
  local ovmf_code="${cfg[OVMF_CODE]:-}"
  local nvram_path="${cfg[NVRAM_PATH]:-}"
  local ver="${cfg[VER]}"
  local arch="${cfg[ARCH]}"
  local fedora_gpg_url="${cfg[FEDORA_GPG_URL]}"
  local checksum_url="${cfg[CHECKSUM_URL]:-}"
  local compose="${cfg[COMPOSE]:-}"
  local base_url="https://download.fedoraproject.org/pub/fedora/linux/releases/${ver}/Cloud/${arch}/images"

  # ========================== DISPATCH ==========================
  local subcommand="${rest[0]:-help}"
  rest=("${rest[@]:1}")
  case "$subcommand" in
    build)          cmd_build "${rest[@]}" ;;
    boot)           cmd_boot  "${rest[@]}" ;;
    run)            cmd_run   "${rest[@]}" ;;
    help|-h|--help) cmd_help ;;
    *) _die "unknown command '$subcommand' (try: $self help)" ;;
  esac
}

main "$@"
