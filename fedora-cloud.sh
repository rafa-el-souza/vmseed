#!/usr/bin/env bash
#
# fedora-cloud.sh — provision a Fedora Cloud image with cloud-init and boot it
# under libvirt.
#
# Requires bash >= 4.3 (namerefs, associative arrays, dynamic-scope locals).
#
# PUBLIC API (subcommands):
#   build                                 render keys into build/<DOMAIN>/user-data (+seed.iso)
#   boot [--fresh] [--replace] <image> [MODE]  boot an existing image under libvirt
#   run  [MODE] [--replace] | --download-only  download + verify + build + boot, end-to-end
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

set -euo pipefail

main() {
  local self="${0##*/}"
  local script_dir; script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

  # ===================== PRIVATE API (helpers) =====================

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
      TEMPLATE|KEYS_DIR|STD_KEY_FILE|ADM_KEY_FILE|TMUX_CONF|DIAG_SCRIPT|OVERLAY_IMAGE_DIR|\
      BASE_IMAGE_DIR|STD_USER|ADMIN_USER|GENERATE_KEYS|ENCRYPT_KEYS|SEED_METHOD|\
      CRYPTO_POLICY|INSTANCE_ID|VM_HOSTNAME|DOMAIN|RAM_MB|VCPUS|LIBVIRT_URI|NETWORK|OSINFO|\
      OVMF_CODE|NVRAM_PATH|TPM|IMAGE_VARIANT|VER|ARCH|FEDORA_GPG_URL|CHECKSUM_URL|COMPOSE|\
      FIREWALL|SAMBA|FAIL2BAN|DIAGNOSTICS|SMB_ALLOW|SSH_ALLOW|SMB_PASSWORD_FILE|FAIL2BAN_IGNOREIP) return 0 ;;
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
      GENERATE_KEYS|ENCRYPT_KEYS|TPM|FIREWALL|SAMBA|FAIL2BAN|DIAGNOSTICS)
        [[ "$val" =~ ^(yes|no)$ ]] || _die "$where must be 'yes' or 'no', got '$val'" ;;
      SMB_ALLOW|SSH_ALLOW|FAIL2BAN_IGNOREIP)
        # Space-separated allowlists of source IPs/CIDRs. SMB_ALLOW feeds the
        # firewalld 445 rich rules + smb.conf `hosts allow`; SSH_ALLOW feeds the
        # ssh rich rules (empty = ssh left open); FAIL2BAN_IGNOREIP feeds fail2ban.
        # Restrict to the characters those consumers accept — anything else is a
        # typo that would otherwise surface as a broken rule or a silent lockout.
        [[ "$val" =~ ^[0-9a-fA-F.:/[:space:]]+$ ]] \
          || _die "$where must be space-separated IPs/CIDRs, got '$val'" ;;
      SEED_METHOD)
        [[ "$val" =~ ^(seed-iso|cloud-init)$ ]] || _die "$where must be 'seed-iso' or 'cloud-init', got '$val'" ;;
      IMAGE_VARIANT)
        [[ "$val" =~ ^(generic|uki)$ ]] || _die "$where must be 'generic' or 'uki', got '$val'" ;;
      CRYPTO_POLICY)
        # e.g. DEFAULT, FUTURE, LEGACY, FIPS, or a base with :MODIFIERS like DEFAULT:NO-SHA1
        [[ "$val" =~ ^[A-Za-z0-9]+(:[A-Za-z0-9_-]+)*$ ]] \
          || _die "$where invalid crypto policy (e.g. DEFAULT:NO-SHA1, FUTURE), got '$val'" ;;
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
      TEMPLATE|KEYS_DIR|STD_KEY_FILE|ADM_KEY_FILE|TMUX_CONF|DIAG_SCRIPT|OVERLAY_IMAGE_DIR|BASE_IMAGE_DIR|OVMF_CODE|NVRAM_PATH|SMB_PASSWORD_FILE)
        [[ "$val" != *[[:space:]]* ]] || _die "$where (a path) must not contain whitespace" ;;
    esac
  }

  _load_config() {  # _load_config <file>  — parse into cfg[]; strict, never sourced
    local file="$1" lineno=0 line key val rest
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
      # Expand a leading '~' (or '~/') in path values to $HOME. Config values are
      # read as literal strings, so the shell's own tilde expansion never runs on
      # them — without this a config path like '~/.ssh/foo.pub' would be taken
      # verbatim and create a literal '~' directory under the CWD instead of
      # landing in the home directory. (The built-in KEYS_DIR default uses "$HOME"
      # directly and so was never affected — which is why only config-set paths,
      # e.g. STD_KEY_FILE/ADM_KEY_FILE, misbehaved.)
      case "$key" in
        TEMPLATE|KEYS_DIR|STD_KEY_FILE|ADM_KEY_FILE|TMUX_CONF|DIAG_SCRIPT|OVERLAY_IMAGE_DIR|BASE_IMAGE_DIR|OVMF_CODE|NVRAM_PATH|SMB_PASSWORD_FILE)
          # Strip a leading '~'; if the value changed, it had one. Done with a
          # parameter expansion rather than a '~' case pattern so shellcheck does
          # not misread a quoted tilde as a failed expansion (SC2088).
          rest="${val#\~}"
          if [[ "$rest" != "$val" ]]; then
            case "$rest" in
              "")  val="$HOME" ;;        # value was exactly '~'
              /*)  val="$HOME$rest" ;;   # value was '~/...'
              # otherwise '~something' (e.g. ~user) — leave it untouched
            esac
          fi ;;
      esac
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

  _ensure_smb_password() {  # -> echoes the SMB password; creates the cred file if absent
    # The file is written in mount.cifs's `credentials=` format, so the very file
    # this generates is the one the host mounts with — no copying a secret around.
    #
    # Why the password is generated on the HOST and injected into the seed: the
    # host is the only client, so it has to hold this credential to mount at all.
    # The secret therefore already lives on the host, and putting it in the seed
    # crosses no new trust boundary. Generating it on the guest instead would force
    # a manual round-trip (SSH in, read it, write it here) before the share works,
    # which defeats a non-interactive provision. The cost is real and stated in the
    # README: the plaintext is in the seed ISO and in the guest's
    # /var/lib/cloud/instance/user-data.txt (0600 root) for the life of the guest.
    local file="$1" pw
    if [[ -f "$file" ]]; then
      pw="$(awk -F= '$1 == "password" { sub(/^password=/, ""); print; exit }' "$file")"
      [[ -n "$pw" ]] || _die "no 'password=' line in $file — delete it to regenerate"
      printf '%s\n' "$pw"
      return 0
    fi
    _need base64
    # 24 random bytes -> base64 -> keep only the alphanumerics. Done with a single
    # `head -c` (not `... | head -c`) so nothing gets SIGPIPE'd under `pipefail`,
    # and reduced to [A-Za-z0-9] so the value is safe in awk's gsub replacement
    # (no '&'), in YAML, and on a shell line.
    local raw; raw="$(head -c 24 /dev/urandom | base64 -w0)"
    pw="${raw//[^A-Za-z0-9]/}"
    [[ "${#pw}" -ge 16 ]] || _die "failed to generate an SMB password"
    local dir; dir="$(dirname "$file")"
    mkdir -p "$dir" && chmod 700 "$dir"
    # Create empty with 0600 BEFORE writing, so the secret is never briefly
    # world-readable between creat() and chmod.
    ( umask 077; : > "$file" )
    printf 'username=%s\npassword=%s\ndomain=WORKGROUP\n' "$std_user" "$pw" > "$file"
    _log "generated an SMB password -> $file (mount with -o credentials=$file)"
    printf '%s\n' "$pw"
  }

  _render_user_data() {  # <std_key> <adm_key> <tmux_b64> <smb_pass> <feats> <diag_b64>
    # Two passes in one: drop the blocks whose feature is off, then substitute the
    # PLACEHOLDER_* tokens in what survives.
    #
    # `feats` is the comma-wrapped list of ENABLED features (",SAMBA,FIREWALL,").
    # A `#@if A,B` block needs every named feature to be in it. Blocks nest: the
    # stack is just a depth counter plus the depth at which skipping began.
    #
    # awk (not sed) so special chars in a value can't break substitution. The
    # replacement text is passed literally — gsub's target is a fixed string here,
    # and no value can contain awk's '&' backreference character (the SSH keys and
    # the tmux/diagnostics base64 are base64 alphabets; the password is generated
    # alphanumeric; the rest are validated by _validate_value).
    awk -v std="$1" -v adm="$2" -v tmux="$3" -v smbpass="$4" -v feats="$5" \
        -v diag="$6" \
        -v su="$std_user" -v au="$admin_user" -v crypto="$crypto_policy" \
        -v smballow="$smb_allow" -v sshallow="$ssh_allow" -v f2bignore="$fail2ban_ignoreip" '
      function on(cond,   n, i, part) {   # every feature in "A,B" must be enabled
        n = split(cond, part, ",")
        for (i = 1; i <= n; i++)
          if (index(feats, "," part[i] ",") == 0) return 0
        return 1
      }
      /^[[:space:]]*#@if[[:space:]]/ {
        depth++
        cond = $0
        sub(/^[[:space:]]*#@if[[:space:]]+/, "", cond)
        sub(/[[:space:]]+$/, "", cond)
        # Only the OUTERMOST failing block decides; nested ifs inside a skipped
        # block are irrelevant (skipdepth is already set and stays set).
        if (skipdepth == 0 && !on(cond)) skipdepth = depth
        next
      }
      /^[[:space:]]*#@endif[[:space:]]*$/ {
        if (skipdepth == depth) skipdepth = 0
        depth--
        next
      }
      skipdepth != 0 { next }
      {
        gsub(/PLACEHOLDER_STANDARD_KEY/, std)
        gsub(/PLACEHOLDER_ADMIN_KEY/, adm)
        gsub(/PLACEHOLDER_TMUX_CONF_B64/, tmux)
        gsub(/PLACEHOLDER_DIAG_SCRIPT_B64/, diag)
        gsub(/PLACEHOLDER_STD_USER/, su)
        gsub(/PLACEHOLDER_ADMIN_USER/, au)
        gsub(/PLACEHOLDER_CRYPTO_POLICY/, crypto)
        gsub(/PLACEHOLDER_SMB_PASSWORD/, smbpass)
        gsub(/PLACEHOLDER_SMB_ALLOW/, smballow)
        gsub(/PLACEHOLDER_SSH_ALLOW/, sshallow)
        gsub(/PLACEHOLDER_F2B_IGNOREIP/, f2bignore)
        print
      }
      END {
        if (depth != 0) {
          print "template: unbalanced #@if / #@endif" > "/dev/stderr"
          exit 1
        }
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
    # umask, not a post-hoc chmod: with SAMBA=yes the ISO contains the SMB password,
    # and a chmod after the fact leaves a window where it is world-readable. qemu
    # runs as this same user under qemu:///session, so 0600 is enough for it to boot.
    ( umask 077; cloud-localds "$dir/seed.iso" "$dir/user-data" "$dir/meta-data" )
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
        # enrolled-keys=yes selects a firmware whose varstore ships the distro/MS
        # keys, so the signed shim/kernel actually validate under Secure Boot.
        boot="uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=yes,firmware.feature1.name=enrolled-keys,firmware.feature1.enabled=yes" ;;
      *) _die "unknown firmware mode '$mode' (use: bios|uefi|uefi-secure)" ;;
    esac
    # Custom per-VM UEFI varstore path; overrides autoselection's default
    # location while keeping template-based init. Empty -> libvirt's default.
    [[ -n "$nvram_path" ]] && boot+=",nvram=${nvram_path}"
    _ref=(--boot "$boot")
    # q35 is the modern machine for UEFI, and Secure Boot's SMM only works on q35
    # (without SMM+q35, autoselection can't match a secure-boot firmware:
    # "Unable to find 'efi' firmware compatible ...").
    case "$mode" in
      uefi)        _ref+=(--machine q35) ;;
      uefi-secure) _ref+=(--machine q35 --features smm.state=on) ;;
    esac
  }

  _undefine_domain() {  # tear down a prior domain of the same name, incl. UEFI nvram + TPM
    local dom="$1"
    if virsh --connect "$libvirt_uri" dominfo "$dom" >/dev/null 2>&1; then
      _log "removing existing domain '$dom'"
      virsh --connect "$libvirt_uri" destroy "$dom" >/dev/null 2>&1 || true
      # --tpm removes the emulated TPM state too (libvirt >= 7.x); fall back
      # without it on older libvirt.
      virsh --connect "$libvirt_uri" undefine "$dom" --nvram --tpm >/dev/null 2>&1 \
        || virsh --connect "$libvirt_uri" undefine "$dom" --nvram >/dev/null 2>&1 \
        || true
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

  _guest_ipv4() {  # best-effort: echo the guest's first IPv4 (no /prefix), or nothing
    local source="$1"
    virsh --connect "$libvirt_uri" domifaddr "$domain" --source "$source" 2>/dev/null \
      | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+' | head -1 | cut -d/ -f1
  }

  _wait_guest_ip() {  # poll domifaddr up to ~30s for a lease; echo the IP or nothing
    local source="$1" ip i
    for ((i = 0; i < 30; i++)); do
      ip="$(_guest_ipv4 "$source" || true)"
      [[ -n "$ip" ]] && { printf '%s\n' "$ip"; return 0; }
      sleep 1
    done
    return 1
  }

  _ssh_hint() {  # print a ready-to-run ssh line per user to <host> (an IP or '<IP>')
    local host="$1"
    printf '      ssh -i %s %s@%s\n' "${adm_key_file%.pub}" "$admin_user" "$host" >&2
    printf '      ssh -i %s %s@%s\n' "${std_key_file%.pub}" "$std_user"   "$host" >&2
  }

  _mount_hint() {  # print the host-side cifs mount for the projects share
    [[ "$samba" == "yes" ]] || return 0
    local host="$1"
    printf '\n' >&2
    _log "mount the guest's ~/projects on this host (needs cifs-utils):"
    # `seal` is not optional: smb.conf sets `server smb encrypt = required`, so an
    # unencrypted session is refused. uid/gid map the files to the invoking user —
    # SMB3 carries no POSIX ownership.
    printf '      sudo mount -t cifs //%s/projects /mnt/projects \\\n' "$host" >&2
    # shellcheck disable=SC2016  # $(id -u)/$(id -g) must reach the operator's terminal
    # UNexpanded — this is a line for them to copy and run, not one we evaluate. (We
    # run as them, but under sudo the mount's uid= must still resolve to their id.)
    printf '        -o credentials=%s,vers=3.1.1,seal,uid=$(id -u),gid=$(id -g),forceuid,forcegid,nosuid,nodev\n' \
      "$smb_password_file" >&2
    _note "the guest only accepts SMB from SMB_ALLOW ($smb_allow) — if this host is not in that list on the bridge, the mount will hang"
  }

  _print_connect_help() {
    printf '\n' >&2
    _log "booted. Reach the guest on the serial console:"
    printf '      virsh --connect %s console %s   (Ctrl+] to exit)\n' "$libvirt_uri" "$domain" >&2

    # Try to resolve a real IP so the ssh lines are copy-paste ready. Only NAT
    # (lease) and bridged (host ARP table) networks are queryable; user-mode has
    # no lease at all.
    local ip="" source=""
    case "$network" in
      network=*) source="lease" ;;
      bridge=*)  source="arp" ;;
      *)
        _note "NETWORK=$network gives no queryable lease; use the console, or a bridge/system NAT for direct SSH"
        return 0 ;;
    esac

    _log "waiting up to 30s for the guest to obtain an IP..."
    ip="$(_wait_guest_ip "$source" || true)"

    if [[ -n "$ip" ]]; then
      _log "or SSH straight in (IP $ip):"
      _ssh_hint "$ip"
      _mount_hint "$ip"
      return 0
    fi

    # No lease yet (the guest may still be booting) — fall back to the discovery
    # command for this network mode, then the ssh lines with an <IP> placeholder.
    _log "no lease yet — find the IP once it boots, then SSH in:"
    case "$network" in
      network=*) printf '      virsh --connect %s domifaddr %s\n' "$libvirt_uri" "$domain" >&2 ;;
      bridge=*)
        printf '      virsh -c qemu:///system net-dhcp-leases default   # if bridged to virbr0\n' >&2
        printf '      ip neigh show dev %s\n' "${network#bridge=}" >&2 ;;
    esac
    _ssh_hint '<IP>'
    _mount_hint '<IP>'
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

  _expected_sha() {  # SHA-256 hex for <img> from a BSD-tagged CHECKSUM ("SHA256 (file) = hex")
    local file="$1" img="$2"
    grep -F "($img) = " "$file" | grep -oE '[0-9a-fA-F]{64}' | tail -1
  }

  _file_sig() {  # cheap identity signature (size:mtime) to detect a changed file
    stat -c '%s:%Y' "$1"
  }

  _fetch_and_verify_image() {  # download (if absent) then check SHA-256 against verified CHECKSUM
    local img="$1" checksum_file="$2"
    [[ -n "$img" ]] || _die "image name not found in CHECKSUM"
    local dest="$base_image_dir/$img" stamp="$base_image_dir/.${img}.verified"

    # The signature-verified expected hash; used both to skip a redundant
    # re-hash and to key the stamp so a new compose invalidates it.
    local expected
    expected="$(_expected_sha "$checksum_file" "$img")"
    [[ -n "$expected" ]] || _die "no SHA-256 for $img in $(basename "$checksum_file")"

    if [[ ! -s "$dest" ]]; then
      _log "downloading $img"
      curl -fL --progress-bar "$base_url/$img" -o "$dest"
    elif [[ -f "$stamp" && "$(< "$stamp")" == "$expected $(_file_sig "$dest")" ]]; then
      # Already verified this exact file (same expected hash, size and mtime) on
      # a previous run — skip re-hashing the multi-GB image.
      _log "$img already present and verified, skipping re-hash"
      return 0
    else
      _log "$img already present, verifying"
    fi

    _log "verifying SHA-256 of $img"
    local line
    # shellcheck disable=SC2015  # || true is a deliberate fallback, not an else:
    # grep exits 1 on no match and the substitution must not trip `set -e`; the
    # actual verdict is the [[ ]] test below.
    line="$( cd "$base_image_dir" \
      && sha256sum -c --ignore-missing "$(basename "$checksum_file")" 2>/dev/null \
      | grep -E "^${img}:" || true )"
    [[ "$line" == "${img}: OK" ]] || _die "checksum verification FAILED for $img"
    # Stamp so the next run can skip the re-hash while the file stays unchanged.
    printf '%s %s\n' "$expected" "$(_file_sig "$dest")" > "$stamp"
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

    # ---- Samba prerequisites. Fail here, at build, rather than shipping a guest
    # that boots an smbd nobody can reach.
    if [[ "$samba" == "yes" ]]; then
      # The host has to be able to open a TCP connection TO the guest. NETWORK=user
      # (QEMU's user-mode/slirp stack) gives the guest no routable address at all —
      # it sits behind a userspace proxy and the host cannot initiate anything to
      # it. No firewall rule or smb.conf setting can fix that.
      case "$network" in
        bridge=*|network=*) ;;
        *) _die "SAMBA=yes needs a network the host can reach: NETWORK=$network gives the guest no routable address (QEMU user-mode). Use NETWORK=bridge=virbr0 (see README), or network=default with LIBVIRT_URI=qemu:///system." ;;
      esac
      # Without firewalld the share is reachable by every other guest on the
      # bridge, not just the host. The Cloud image ships no packet filter at all,
      # so this is not a hypothetical.
      [[ "$firewall" == "yes" ]] \
        || _die "SAMBA=yes requires FIREWALL=yes — otherwise port 445 is open to every host on the bridged network, not just SMB_ALLOW ($smb_allow)"
    fi
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

    # Same base64 treatment for the diagnostics script, but only when it's asked
    # for — its block (and PLACEHOLDER_DIAG_SCRIPT_B64) is stripped otherwise.
    local diag_b64=""
    if [[ "$diagnostics" == "yes" ]]; then
      [[ -f "$diag_script" ]] || _die "DIAGNOSTICS=yes but script not found: $diag_script"
      diag_b64="$(base64 -w0 < "$diag_script")"
    fi

    # The comma-wrapped list of enabled features drives the template's #@if blocks.
    local feats=","
    [[ "$firewall"    == "yes" ]] && feats+="FIREWALL,"
    [[ "$samba"       == "yes" ]] && feats+="SAMBA,"
    [[ "$fail2ban"    == "yes" ]] && feats+="FAIL2BAN,"
    [[ "$diagnostics" == "yes" ]] && feats+="DIAGNOSTICS,"

    # Only reachable when SAMBA=yes; otherwise the placeholder is stripped with its
    # block and the seed never sees a password.
    local smb_pass=""
    [[ "$samba" == "yes" ]] && smb_pass="$(_ensure_smb_password "$smb_password_file")"

    # Seed artifacts live in a per-domain build/ subdir so several guests can
    # share one OVERLAY_IMAGE_DIR without clobbering each other's cloud-config.
    local seed_dir="$overlay_image_dir/build/$domain"
    mkdir -p "$seed_dir"
    # 0600 from the start: with SAMBA=yes the rendered user-data carries the SMB
    # password, so it must never exist world-readable, not even briefly.
    ( umask 077; : > "$seed_dir/user-data" )
    _render_user_data "$std_key" "$adm_key" "$tmux_b64" "$smb_pass" "$feats" "$diag_b64" > "$seed_dir/user-data"
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
    local fresh=0 replace=0
    while [[ "${1:-}" == --* ]]; do
      case "$1" in
        --fresh)   fresh=1 ;;
        --replace) replace=1 ;;
        *) _die "unknown boot flag: $1" ;;
      esac
      shift
    done
    local image="${1:-}"
    [[ -n "$image" ]] || _die "usage: $self --config <file> boot [--fresh] [--replace] <image.qcow2> [bios|uefi|uefi-secure]"
    local mode="${2:-bios}"

    _need virt-install virsh qemu-img
    # Per-domain seed dir (matches cmd_build) so a shared OVERLAY_IMAGE_DIR is safe.
    local seed_dir="$overlay_image_dir/build/$domain"
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

    # Optional emulated TPM 2.0 (needs swtpm on the host). Makes
    # systemd-tpm2-setup succeed and enables measured boot.
    local -a tpm_args=()
    if [[ "$tpm" == "yes" ]]; then
      _need swtpm
      tpm_args=(--tpm "backend.type=emulator,backend.version=2.0")
    fi

    # Guard against clobbering a *different* guest that already owns this DOMAIN.
    # An active domain of this name is almost always a live sibling colliding on
    # the name, so refuse unless --replace; a shut-off domain is this guest's own
    # prior instance, so replace it (with a note). domstate is empty when the
    # domain does not exist — the common new-guest path — so it sails through.
    local dom_state
    dom_state="$(virsh --connect "$libvirt_uri" domstate "$domain" 2>/dev/null || true)"
    if [[ -n "$dom_state" ]]; then
      case "$dom_state" in
        "shut off"|crashed)
          _log "replacing existing (inactive) domain '$domain'" ;;
        *)  # running / paused / idle / pmsuspended / in shutdown — active
          [[ "$replace" == 1 ]] \
            || _die "domain '$domain' is already active on $libvirt_uri (state: $dom_state) — refusing to replace a live guest. Use a distinct DOMAIN per guest, or pass --replace to force it."
          _log "replacing active domain '$domain' (--replace)"
          virsh --connect "$libvirt_uri" destroy "$domain" >/dev/null 2>&1 || true ;;
      esac
    fi
    _undefine_domain "$domain"

    mkdir -p "$overlay_image_dir"
    local overlay="$overlay_image_dir/${domain}.qcow2"
    _make_overlay "$image" "$overlay" "$fresh"

    # Pin a virtio NIC unless the config already chose a model (so a generic
    # osinfo can't downgrade networking to an emulated e1000/rtl8139).
    local net_arg="$network"
    [[ "$net_arg" == *model=* ]] || net_arg+=",model=virtio"

    _log "starting '$domain' [$mode] via $libvirt_uri"
    virt-install \
      --connect "$libvirt_uri" \
      --name "$domain" \
      --memory "$ram_mb" \
      --vcpus "$vcpus" \
      --osinfo "$osinfo" \
      --import \
      --disk "path=$overlay,format=qcow2,bus=virtio,cache=none,discard=unmap" \
      --network "$net_arg" \
      --graphics none \
      --noautoconsole \
      "${seed_args[@]}" \
      "${tpm_args[@]}" \
      "${boot_args[@]}"

    _print_connect_help
  }

  cmd_run() {
    _require_config run
    _require_base_dir
    # MODE is the VM firmware; the image to fetch is IMAGE_VARIANT (independent).
    # --replace is forwarded to boot; --download-only skips build/boot entirely.
    local mode="bios" download_only=0 replace=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --download-only)        download_only=1 ;;
        --replace)              replace=1 ;;
        bios|uefi|uefi-secure)  mode="$1" ;;
        *) _die "usage: $self --config <file> run [bios|uefi|uefi-secure] [--replace] | run --download-only" ;;
      esac
      shift
    done
    # The only impossible combination: the UKI image is UEFI-only. (Fail before
    # any network work.)
    if [[ "$download_only" != "1" && "$image_variant" == "uki" && "$mode" == "bios" ]]; then
      _die "IMAGE_VARIANT=uki is UEFI-only; use MODE 'uefi'/'uefi-secure', or IMAGE_VARIANT=generic"
    fi

    _need curl gpgv sha256sum flock
    mkdir -p "$base_image_dir"

    # Serialize the shared-file fetch/verify (CHECKSUM, CHECKSUM.verified, the
    # base image) so parallel `run`s queue here instead of racing on those
    # fixed-name files. Held only for the fetch; the per-domain build+boot below
    # needs no lock. The lock frees automatically if the process dies.
    local lock_fd
    exec {lock_fd}>"$base_image_dir/.fetch.lock"
    flock "$lock_fd"

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
      exec {lock_fd}>&-   # release the fetch lock
      _log "verified images in $base_image_dir:"
      printf '      generic: %s\n' "$generic_img" >&2
      printf '      uki:     %s\n' "$uki_img"     >&2
      return 0
    fi

    local image
    case "$image_variant" in
      generic) image="$generic_img" ;;
      uki)     image="$uki_img" ;;
    esac
    _fetch_and_verify_image "$image" "$checksum_verified"
    exec {lock_fd}>&-   # release before the (parallel-safe) build+boot

    cmd_build
    _log "booting $image_variant image [$mode]"
    local -a replace_arg=()
    [[ "$replace" == 1 ]] && replace_arg=(--replace)
    cmd_boot "${replace_arg[@]}" "$base_image_dir/$image" "$mode"
  }

  cmd_help() {
    cat >&2 <<EOF
$self — provision & boot a Fedora Cloud image with cloud-init

Usage:
  $self --config <file> build                                   render SSH keys into build/<DOMAIN>/user-data
  $self --config <file> boot [--fresh] [--replace] <image> [MODE] boot an existing image under libvirt
  $self --config <file> run  [MODE] [--replace] | run --download-only  download + verify + build + boot
  $self help                                                    this message

MODE (the VM firmware — independent of the image):
  bios         legacy BIOS/SeaBIOS   [default]
  uefi         UEFI
  uefi-secure  UEFI + Secure Boot

Flags:
  --fresh      recreate the qcow2 overlay from the pristine base (re-runs cloud-init)
  --replace    replace an existing domain even if it is running (else boot refuses
               to clobber a live guest that already owns this DOMAIN)

Image is chosen separately by IMAGE_VARIANT in the config:
  generic  Cloud Base Generic, hybrid BIOS+UEFI — works with any MODE   [default]
  uki      Cloud Base UKI, UEFI-only — MODE must be uefi/uefi-secure

Configuration:
  All settings come from the --config KEY=VALUE file (required for build/boot/run;
  no environment variables). Copy fedora-cloud.conf.example, edit it, and pass it
  with --config. Unknown keys and malformed values are rejected.

Examples:
  $self --config fedora-cloud.conf run                 # generic image, BIOS firmware
  $self --config fedora-cloud.conf run uefi            # generic image, UEFI firmware
  $self --config fedora-cloud.conf run --download-only # fetch+verify BOTH variants, no boot
  $self --config fedora-cloud.conf build               # (IMAGE_VARIANT=uki -> UKI image)
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
    [DIAG_SCRIPT]="$script_dir/tools/guest-diagnostics.sh"
    [KEYS_DIR]="$HOME/.ssh"
    [STD_USER]="appuser"
    [ADMIN_USER]="admin"
    [GENERATE_KEYS]="yes"
    [ENCRYPT_KEYS]="yes"
    [SEED_METHOD]="seed-iso"
    [CRYPTO_POLICY]="DEFAULT:NO-SHA1"
    [INSTANCE_ID]="fedora-01"
    [VM_HOSTNAME]="fedora-01"
    # Security features. FIREWALL defaults ON because the Fedora Cloud Base image
    # ships with NO packet filter at all — this closes a real hole and costs
    # nothing (firewalld's default `public` zone already permits SSH). SAMBA and
    # FAIL2BAN default OFF: both have prerequisites (a reachable network; a
    # password) and neither should appear on a guest that did not ask for it.
    [FIREWALL]="yes"
    [SAMBA]="no"
    [FAIL2BAN]="no"
    # Drop the read-only guest-diagnostics.sh into the admin user's home. OFF by
    # default: it is a debugging aid, not something every guest should carry.
    [DIAGNOSTICS]="no"
    [SMB_ALLOW]="192.168.122.1"
    [SSH_ALLOW]=""
    [FAIL2BAN_IGNOREIP]="127.0.0.1/8 ::1 192.168.122.1"
    [DOMAIN]="fedora-cloud-01"
    [RAM_MB]="2048"
    [VCPUS]="2"
    [LIBVIRT_URI]="qemu:///session"
    [NETWORK]="user"
    [OSINFO]="detect=on,require=off,name=fedora43"
    [TPM]="no"
    [IMAGE_VARIANT]="generic"
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
  # Same per-VM naming for the SMB credentials file, for the same reason: so two
  # domains don't share one secret.
  : "${cfg[SMB_PASSWORD_FILE]:=${cfg[KEYS_DIR]}/smb-${cfg[STD_USER]}-${cfg[DOMAIN]}.cred}"

  # Project the validated config into readable locals used by the commands.
  local template="${cfg[TEMPLATE]}"
  local tmux_conf="${cfg[TMUX_CONF]}"
  local diag_script="${cfg[DIAG_SCRIPT]}"
  local std_user="${cfg[STD_USER]}"
  local admin_user="${cfg[ADMIN_USER]}"
  local generate_keys="${cfg[GENERATE_KEYS]}"
  local encrypt_keys="${cfg[ENCRYPT_KEYS]}"
  local crypto_policy="${cfg[CRYPTO_POLICY]}"
  local seed_method="${cfg[SEED_METHOD]}"
  local std_key_file="${cfg[STD_KEY_FILE]}"
  local adm_key_file="${cfg[ADM_KEY_FILE]}"
  local firewall="${cfg[FIREWALL]}"
  local samba="${cfg[SAMBA]}"
  local fail2ban="${cfg[FAIL2BAN]}"
  local diagnostics="${cfg[DIAGNOSTICS]}"
  local smb_allow="${cfg[SMB_ALLOW]}"
  local ssh_allow="${cfg[SSH_ALLOW]}"
  local smb_password_file="${cfg[SMB_PASSWORD_FILE]}"
  local fail2ban_ignoreip="${cfg[FAIL2BAN_IGNOREIP]}"
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
  local tpm="${cfg[TPM]}"
  local ovmf_code="${cfg[OVMF_CODE]:-}"
  local nvram_path="${cfg[NVRAM_PATH]:-}"
  local image_variant="${cfg[IMAGE_VARIANT]}"
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
