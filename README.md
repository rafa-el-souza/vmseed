# Fedora Cloud provisioning with cloud-init

Provisions a [Fedora Cloud Base](https://fedoraproject.org/cloud/download) image
on first boot with two SSH-only users:

| User      | Privileges                          | Group   | Config key   |
|-----------|-------------------------------------|---------|--------------|
| `appuser` | Standard, no sudo                   | —       | `STD_USER`   |
| `admin`   | Passwordless sudo (`NOPASSWD:ALL`)  | `wheel` | `ADMIN_USER` |

The usernames shown are the **defaults** — set `STD_USER` / `ADMIN_USER` in your
config to rename them. They must be valid Linux names, must differ from each
other, and can't be a reserved/system account (`root`, `fedora`, `default`,
`nobody`, …) — the build rejects any of these. Each user gets a public key from
`~/.ssh/<username>-<DOMAIN>.pub` (see [SSH keys](#ssh-keys)). Password login is
disabled (`lock_passwd: true`) — SSH key authentication only.

## What gets provisioned

On first boot, cloud-init also:

- **Upgrades the system** (`package_update` + `package_upgrade`).
- **Installs global tools**: `tmux`, `gh`, `git`, `btop` (dnf is idempotent, so
  anything already present is skipped).
- **Sets up the standard user (`STD_USER`) only** (run as that user via `runuser -l`):
  - [Claude Code](https://claude.ai) via `curl -fsSL https://claude.ai/install.sh | bash`
  - tmux TPM plugin manager → `~/.tmux/plugins/tpm`
  - tmux Catppuccin theme (v2.3.0) → `~/.config/tmux/plugins/catppuccin/tmux`
  - all `@plugin`s from `~/.tmux.conf` installed headlessly via
    `tpm/bin/install_plugins`, so **tmux is ready on first launch** (no
    interactive `prefix + I`)
- **Writes the standard user's `~/.tmux.conf`** from a build-time file (see below).

### appuser's tmux config (`TMUX_CONF`)

The contents of the file at `TMUX_CONF` (default `./dotfiles/tmux.conf`, tracked
in this repo) are base64-encoded at build time and injected into the
cloud-config; on the guest cloud-init decodes them to `/home/appuser/.tmux.conf`
(owned by `appuser`, written with `defer: true` so it lands *after* the user is
created). Base64 keeps multi-line content from breaking YAML indentation.

Edit `dotfiles/tmux.conf` to change the shipped config, or point `TMUX_CONF` at a
different file in your config.

## SSH hardening

`user-data.yaml` also drops a hardened sshd config into
`/etc/ssh/sshd_config.d/00-hardening.conf` (via cloud-init `write_files`) and
reloads sshd. Because Fedora's `sshd_config` ends with
`Include /etc/ssh/sshd_config.d/*.conf` and sshd takes the **first** value it
sees for each option, the `00-` prefix makes this drop-in win over the distro
defaults without editing the main config. It sets:

| Directive | Value | Purpose |
|-----------|-------|---------|
| `PermitRootLogin` | `no` | no direct root SSH |
| `PasswordAuthentication` / `KbdInteractiveAuthentication` | `no` | key-only auth |
| `PermitEmptyPasswords` | `no` | reject blank passwords |
| `AllowUsers` | `<ADMIN_USER> <STD_USER>` | only the two provisioned users may log in |
| `MaxAuthTries` | `3` | fewer brute-force attempts per connection |
| `LoginGraceTime` | `20` | close unauthenticated sessions fast |
| `ClientAliveInterval` / `ClientAliveCountMax` | `300` / `2` | drop idle sessions |
| `X11Forwarding` / `AllowAgentForwarding` / `AllowTcpForwarding` / `PermitTunnel` | `no` | shrink attack surface |

Cipher/MAC/KEX selection is **not** hardcoded in the drop-in. Instead a `runcmd`
tightens Fedora's system-wide crypto policy via `update-crypto-policies --set
$CRYPTO_POLICY` (**default `DEFAULT:NO-SHA1`**), then `sshd -t && systemctl reload
sshd` validates and applies the config — a malformed config fails the boot loudly
instead of locking you out.

> **Why `DEFAULT:NO-SHA1` and not `FUTURE`?** `FUTURE` also requires 3072-bit RSA,
> which **breaks TLS to CDNs serving 2048-bit RSA certs** — including the Claude
> Code installer (`curl` fails cert verification). `DEFAULT:NO-SHA1` still bans
> SHA-1 but keeps that compatibility. Set `CRYPTO_POLICY=FUTURE` if you want the
> stricter policy and don't need those endpoints.
>
> `AllowUsers` is generated from `STD_USER`/`ADMIN_USER` at build time, so it
> always matches the provisioned users — no manual edit needed when you rename.

## Accounts, sudo & passwords

**No passwords are set during provisioning** — every account is SSH-key-only:

- **standard user** — no sudo, password locked.
- **admin** — in `wheel`, `sudo: ALL=(ALL) NOPASSWD:ALL`, password locked.
- **root** — SSH disabled (`PermitRootLogin no` + not in `AllowUsers`), and its
  password is explicitly locked (`passwd -l root`, defense-in-depth). Reachable
  only via the admin's sudo.

### Why `NOPASSWD:ALL` + locked passwords

Because provisioning deliberately sets no passwords, the escalation path has to
work without one — which is exactly what this combination provides:

- With **no password hash** on the box, a password-*prompting* sudo rule
  (`ALL=(ALL) ALL`, or Fedora's default `%wheel` rule) can never be satisfied —
  the admin could SSH in but **never escalate**. `NOPASSWD:ALL` is the only rule
  that works at first boot, and it's what bootstraps everything else.
- `lock_passwd: true` is almost a no-op while no password exists (there's no hash
  to lock), but it's the safe default and the first `passwd` you run replaces it.
- The **admin's SSH private key is effectively root** (passwordless sudo). Protect
  it — generate it encrypted (`ENCRYPT_KEYS=yes`, the default).

### Setting passwords later (over SSH)

SSH in as the admin (key auth), then use `sudo passwd` — it runs as root, so it
never asks for the *old* password:

```bash
ssh -i ~/.ssh/admin-<DOMAIN> admin@<host>
sudo passwd admin          # set the admin's own password
sudo passwd appuser        # set the standard user's password
sudo passwd root           # set root's password (this also unlocks it — only if you
                           # really want console root; SSH root stays disabled)
```

Password SSH login stays disabled (`PasswordAuthentication no`), so these
passwords only apply to the local console and to `sudo` — not to SSH.

### Switching the admin to password-required sudo

Once the admin has a password (above), you can drop the passwordless rule:

```bash
sudo passwd admin                                   # 1. ensure a password exists first!
sudo rm /etc/sudoers.d/90-cloud-init-users          # 2. remove cloud-init's NOPASSWD rule
# admin now falls back to Fedora's default `%wheel ALL=(ALL) ALL` — password-prompted sudo
sudo -k && sudo -v                                  # 3. verify you can still authenticate
```

> ⚠️ **Order matters.** Set the password *before* removing the `NOPASSWD` rule.
> Remove it first and you lock yourself out of sudo (no password to fall back on).
> To make it permanent for future VMs, change the admin's `sudo:` line in
> `user-data.yaml` and rebuild instead.

## Layout

The repo itself only holds the tool and its inputs:

```
fedora-cloud.sh          # single entry point: build | boot | run | help
fedora-cloud.conf.example # sample config — copy to fedora-cloud.conf and edit
user-data.yaml           # cloud-config TEMPLATE (PLACEHOLDER_* tokens)
dotfiles/tmux.conf       # standard user's tmux config, injected into ~/.tmux.conf
```

Generated artifacts live **outside** the repo, in directories you configure
(no defaults — see [Configuration](#configuration)):

```
$OVERLAY_IMAGE_DIR/<DOMAIN>.qcow2            # the qcow2 overlay (base image stays pristine)
$OVERLAY_IMAGE_DIR/build/<DOMAIN>/user-data  # rendered cloud-config (per-DOMAIN)
$OVERLAY_IMAGE_DIR/build/<DOMAIN>/meta-data
$OVERLAY_IMAGE_DIR/build/<DOMAIN>/seed.iso   # with SEED_METHOD=seed-iso (the default)
$BASE_IMAGE_DIR/Fedora-Cloud-…qcow2          # downloaded base image(s)
$BASE_IMAGE_DIR/{fedora.gpg,CHECKSUM,CHECKSUM.verified}
```

Both the overlay and its seed are keyed by `DOMAIN`, so multiple guests can share
one `OVERLAY_IMAGE_DIR` without clobbering each other — see
[Running multiple guests](#running-multiple-guests).

SSH keys live in `KEYS_DIR` (default `~/.ssh`), also outside the repo — see
[SSH keys](#ssh-keys).

Everything is one script, `fedora-cloud.sh`, with three subcommands. All of them
require a `--config <file>` (see [Configuration](#configuration)):

| Command | Does |
|---------|------|
| `fedora-cloud.sh --config <f> build` | render the seed into `$OVERLAY_IMAGE_DIR/build/<DOMAIN>/` (+ `seed.iso` unless `SEED_METHOD=cloud-init`) |
| `fedora-cloud.sh --config <f> boot [--fresh] <image> [MODE]` | boot an existing image under libvirt |
| `fedora-cloud.sh --config <f> run [MODE\|--download-only]` | download + verify + build + boot, end-to-end |

`MODE` is the VM **firmware** — `bios` (default), `uefi`, or `uefi-secure`. The
**image** is chosen separately by `IMAGE_VARIANT` (`generic` default, or `uki`) —
see [Image variants](#image-variants).

## Configuration

All settings come from a required `--config` file in simple `KEY=VALUE` format
(no environment variables). Start from the sample:

```bash
cp fedora-cloud.conf.example fedora-cloud.conf
$EDITOR fedora-cloud.conf
```

The file is **parsed, never sourced** (so a config file cannot execute code), and
every value is **strictly validated** — unknown keys, malformed lines, and
out-of-range values are rejected with a `config:<line>` error. Most keys have a
built-in default; the two directory keys do **not** and must be set:

| Key | Required for | Holds |
|-----|--------------|-------|
| `OVERLAY_IMAGE_DIR` | `build`, `boot`, `run` | the qcow2 overlay + the `build/` seed subdir |
| `BASE_IMAGE_DIR` | `run` | downloaded base images, CHECKSUM, keyring |

Both are auto-created if missing. **Paths are literal** (no `~`/variable
expansion) — use an absolute path. Other common keys: `STD_USER` / `ADMIN_USER`
(the two usernames), `IMAGE_VARIANT` (`generic`/`uki`), `DOMAIN`, `RAM_MB`,
`VCPUS`, `LIBVIRT_URI`, `VER`, `ARCH`, `OVMF_CODE`, and `COMPOSE` /
`CHECKSUM_URL` (to pin a download).

Your personal `fedora-cloud.conf` is git-ignored; only the `.example` is tracked.

## Running multiple guests

The base and overlay directories play different roles when you run more than one
VM:

- **`BASE_IMAGE_DIR` is meant to be shared.** Base images are pristine and
  read-only; every guest boots from its own copy-on-write overlay that *backs
  onto* the shared base. Pointing several guests at one base dir means the image
  is downloaded and verified once, then reused. Parallel `run`s are safe: the
  fetch/verify block is guarded by an `flock` on `$BASE_IMAGE_DIR/.fetch.lock`,
  so concurrent runs queue through it instead of racing on the shared `CHECKSUM`
  / `CHECKSUM.verified` / image files. And once an image is verified, a stamp
  file lets later runs skip re-hashing the multi-GB base while it stays unchanged
  (a new compose, or a changed file size/mtime, re-triggers verification). The
  one standing caveat: the base is a permanent backing dependency — moving or
  deleting it breaks every overlay built on it.
- **`OVERLAY_IMAGE_DIR` can be shared too, but each guest needs its own
  `DOMAIN`.** Both the overlay (`<DOMAIN>.qcow2`) and its seed
  (`build/<DOMAIN>/…`) are keyed by `DOMAIN`, so distinct domains never collide.
  Reusing the *same* `DOMAIN` for two guests would overwrite one's overlay and
  seed and let `virsh undefine` tear down the sibling — so also vary
  `VM_HOSTNAME`, `INSTANCE_ID`, and the key files per guest.

In short: one config per guest, sharing `BASE_IMAGE_DIR`, each with its own
`DOMAIN` (and ideally its own `OVERLAY_IMAGE_DIR` if you like them fully
separated).

## Seed delivery

`SEED_METHOD` controls how the rendered cloud-config reaches the guest:

| `SEED_METHOD` | `build` produces | `boot` attaches | Needs `cloud-localds` |
|---------------|------------------|-----------------|-----------------------|
| `seed-iso` (default) | a `cidata` ISO at `$OVERLAY_IMAGE_DIR/build/seed.iso` | that ISO, as a CDROM (`--disk …,device=cdrom`) | **yes**, at `build` time |
| `cloud-init` | just `user-data` + `meta-data` | via `virt-install --cloud-init` (it builds its own ISO) | no |

With `seed-iso` the exact ISO you can inspect is the one that boots, and the same
file works with a manual `qemu-system` invocation. With `cloud-init` you avoid the
`cloud-localds` dependency, but the seed virt-install boots is its own internal
copy. Both produce an identical NoCloud datasource on the guest.

## SSH keys

Each provisioned user is authenticated by an SSH **public key** read at build
time from `KEYS_DIR/<username>-<DOMAIN>.pub` (default `KEYS_DIR=~/.ssh`, so with
`DOMAIN=fedora-cloud-01` that's `~/.ssh/appuser-fedora-cloud-01.pub` and
`~/.ssh/admin-fedora-cloud-01.pub`). Including the VM name keeps per-VM keys from
colliding across domains. Override individual paths with `STD_KEY_FILE` /
`ADM_KEY_FILE`.

> **Config paths are literal.** The config file is parsed, never sourced, so `~`
> is **not** expanded there — use an absolute path (e.g. `/home/you/.ssh`) if you
> set `KEYS_DIR` yourself. The built-in default is your real `$HOME/.ssh`.

**If a key file is missing**, `GENERATE_KEYS` decides what happens:

| `GENERATE_KEYS` | Behaviour when a key file is absent |
|-----------------|-------------------------------------|
| `yes` (default) | `build` creates it (see `ENCRYPT_KEYS` below) |
| `no` | `build` fails — you must provide the key yourself |

When generating, `build` runs:

```bash
ssh-keygen -t ed25519 -a 100 -f ~/.ssh/<username>-<DOMAIN> -C <username>
```

(`-a 100` sets 100 KDF rounds, hardening an encrypted private key against
brute force.) Whether it's encrypted is controlled by `ENCRYPT_KEYS`:

| `ENCRYPT_KEYS` | Behaviour |
|----------------|-----------|
| `yes` (default) | ssh-keygen **prompts** for a passphrase — interactive, once per key created |
| `no` | generates with `-N ''` (no passphrase) — fully **non-interactive**, for automation |

A passphrase is never stored in the config file. If a private key already exists
but its `.pub` is missing, `build` derives the `.pub` (`ssh-keygen -y`) instead
of overwriting the private key.

To reuse an existing key, point `STD_KEY_FILE` / `ADM_KEY_FILE` at its `.pub`, or
copy it into place:

```bash
cp ~/.ssh/id_ed25519.pub ~/.ssh/admin-fedora-cloud-01.pub
```

Only public keys ever enter the cloud-config; private keys stay on your machine.

## Session URI with a bridged network

The default `qemu:///session` + `NETWORK=user` keeps everything unprivileged but
gives the guest no routable IP (no `domifaddr` lease, no inbound SSH). To get a
**real IP while staying on the session URI**, attach the VM to an existing Linux
bridge via QEMU's setuid `qemu-bridge-helper`. The VM stays unprivileged; only
the one-time bridge/ACL setup needs root.

**1. Have a bridge.** The simplest is to reuse libvirt's default NAT bridge
`virbr0` (owned by *system* libvirt, with its own dnsmasq DHCP):

```bash
sudo virsh net-start default        # if not already active
sudo virsh net-autostart default    # persist across reboots
ip -br link show virbr0             # confirm it exists
```

For an IP on your physical LAN instead, create a NetworkManager bridge (e.g.
`br0`) enslaving your NIC and use that name below.

**2. Allow the bridge for the unprivileged helper** (one-time, needs root). Add
the bridge to the QEMU helper ACL and confirm the helper is setuid:

```bash
echo 'allow virbr0' | sudo tee -a /etc/qemu/bridge.conf
ls -l /usr/libexec/qemu-bridge-helper   # want -rwsr-xr-x (Debian/Ubuntu: /usr/lib/qemu/)
# if the setuid bit is missing:  sudo chmod u+s /usr/libexec/qemu-bridge-helper
```

**3. Point the config at the bridge** (keep the session URI):

```ini
LIBVIRT_URI=qemu:///session
NETWORK=bridge=virbr0
```

**4. Boot and connect by IP.** The DHCP server belongs to the *system* side
(virbr0's dnsmasq), so query the lease there even though the VM runs in your
session:

```bash
./fedora-cloud.sh --config fedora-cloud.conf run bios
virsh -c qemu:///system net-dhcp-leases default   # -> the guest's IP (virbr0)
# any bridge:  ip neigh show dev virbr0
ssh -i ~/.ssh/admin-fedora-cloud-01 admin@<IP>
```

Notes:
- `virbr0` must be **active before** the VM boots, or the interface has nothing to
  attach to.
- The guest lands on the `192.168.122.0/24` NAT network; reachable from the host,
  NAT'd outbound — same addressing as a system `network=default`, but the domain
  itself stays under `qemu:///session`.
- `bridge=<name>` passes the config validator; no other change is needed.

## Quick start (one command)

With a config file ready (keys are auto-generated if missing), `run` does everything —
downloads the image, **verifies its GPG signature and SHA-256 checksum**, builds
the seed, and boots:

```bash
# MODE = firmware; the image is IMAGE_VARIANT in the config (default: generic).
./fedora-cloud.sh --config fedora-cloud.conf run              # generic image, BIOS
./fedora-cloud.sh --config fedora-cloud.conf run uefi         # generic image, UEFI
./fedora-cloud.sh --config fedora-cloud.conf run uefi-secure  # generic image, UEFI + Secure Boot
# set IMAGE_VARIANT=uki in the config to fetch/boot the UKI image (uefi/uefi-secure only)
./fedora-cloud.sh --config fedora-cloud.conf run --download-only   # fetch + verify BOTH variants, no boot
```

It fetches Fedora's OpenPGP keyring, discovers the current `CHECKSUM` file,
verifies its signature with `gpgv`, resolves the exact image filenames **from the
verified checksum** (so nothing is hardcoded to a compose number), downloads the
qcow2, and checks its SHA-256 before booting. Set `VER=44` in the config, or pin
a compose with `COMPOSE=1.5` / `CHECKSUM_URL=...` if auto-discovery is blocked by
a mirror.

The steps below are the manual equivalent if you already have an image.

## Image variants

Two independent choices: **which image** (`IMAGE_VARIANT`) and **which VM
firmware** (`MODE`). They are not the same axis — the Generic image is a hybrid
that boots under BIOS *or* UEFI. **The same `user-data.yaml` works on both
images** — cloud-init behaves identically.

| `IMAGE_VARIANT` | `generic` (default) | `uki` |
|---|---|---|
| Firmware support | Hybrid **BIOS + UEFI** | **UEFI-only** |
| Bootloader | shim → GRUB → kernel | shim → UKI directly (no GRUB) |
| initramfs | built on the host by dracut | prebuilt, baked into the signed kernel image |
| Kernel cmdline | editable via GRUB / `grubby` | **sealed inside the signed UKI** — not freely editable |
| Secure Boot | signs kernel only (initrd unsigned) | signs kernel **+ initrd + cmdline** |
| Confidential computing | noisy TPM measurements | **predictable, attestable** measurements |

Compatible `MODE` per variant:

| image ↓ / MODE → | `bios` | `uefi` | `uefi-secure` |
|---|:---:|:---:|:---:|
| `generic` | ✓ | ✓ | ✓ |
| `uki` | ✗ | ✓ | ✓ |

`run` refuses the one impossible pairing (`uki` + `bios`). `boot` takes an
explicit image path, so pairing it sensibly with `MODE` is up to you.

**Which to use:** `generic` is the safe default — boots any firmware and you can
tweak kernel params freely. Choose `uki` when you specifically need Secure Boot
with a signed initrd or confidential-computing attestation (and pair it with
`uefi`/`uefi-secure`).

> ⚠️ **UKI kernel cmdline caveat.** This project does not set any kernel command
> line, so both variants work as-is. But if you later add tooling that edits
> kernel params (`grubby`, GRUB edits), it will **not** take effect on the UKI
> image — its cmdline lives inside the signed binary. Use systemd-boot /
> `kernel-install` drop-ins or `.cmdline` add-ons there instead.
>
> UKI images are also UEFI-only and were, in early testing, subject to a shim
> bug that could fail the first boot and need a VM reset.

## Usage

1. (Optional) Provide the SSH keys yourself — otherwise `build` generates them
   (see [SSH keys](#ssh-keys)):

   ```bash
   ssh-keygen -t ed25519 -a 100 -f ~/.ssh/appuser-fedora-cloud-01 -C appuser@fedora
   ssh-keygen -t ed25519 -a 100 -f ~/.ssh/admin-fedora-cloud-01   -C admin@fedora
   ```

2. Build the seed (`--config` is required):

   ```bash
   chmod +x fedora-cloud.sh                          # first time only
   cp fedora-cloud.conf.example fedora-cloud.conf    # first time only
   ./fedora-cloud.sh --config fedora-cloud.conf build
   ```

   This renders `$OVERLAY_IMAGE_DIR/build/user-data`, validates it with
   `cloud-init schema`, and — with the default `SEED_METHOD=seed-iso` — builds
   `$OVERLAY_IMAGE_DIR/build/seed.iso` (see [Seed delivery](#seed-delivery)).

   > Install the tooling on Fedora with:
   > `sudo dnf install cloud-utils virt-install libvirt qemu-img edk2-ovmf`
   > and ensure libvirtd is running: `sudo systemctl enable --now libvirtd`

3. Boot an image under libvirt with `boot <image> <MODE>`. `MODE` is the VM
   firmware; make sure it's compatible with the image you pass (a UKI image needs
   `uefi`/`uefi-secure` — see [Image variants](#image-variants) below):

   ```bash
   ./fedora-cloud.sh --config fedora-cloud.conf boot Fedora-Cloud-Base-Generic.qcow2 bios         # hybrid image, BIOS
   ./fedora-cloud.sh --config fedora-cloud.conf boot Fedora-Cloud-Base-Generic.qcow2 uefi         # same image, UEFI
   ./fedora-cloud.sh --config fedora-cloud.conf boot Fedora-Cloud-Base-UKI.qcow2 uefi-secure      # UKI image, Secure Boot
   ```

   `boot` attaches the seed per [`SEED_METHOD`](#seed-delivery), boots from a
   qcow2 **overlay** so the base image stays pristine, and lets libvirt's firmware
   autoselection pick OVMF for the UEFI modes. Re-run with `--fresh` to reset the
   disk.

   For cloud providers, pass `$OVERLAY_IMAGE_DIR/build/user-data` to the
   platform's user-data field instead (e.g. `openstack server create --user-data
   …/build/user-data`, EC2 user data, ...).

4. Connect. With the default **`qemu:///session` + `NETWORK=user`**, the guest is
   NAT'd behind user-mode networking, so `domifaddr` won't show a routable lease —
   use the serial console:

   ```bash
   virsh -c qemu:///session console fedora-cloud-01   # Ctrl+] to exit
   ```

   For direct SSH by IP, run on the **system** libvirt with a managed NAT network —
   set `LIBVIRT_URI=qemu:///system` and `NETWORK=network=default` in your config,
   then:

   ```bash
   virsh -c qemu:///system domifaddr fedora-cloud-01
   ssh -i ~/.ssh/admin-fedora-cloud-01   admin@<IP>
   ssh -i ~/.ssh/appuser-fedora-cloud-01 appuser@<IP>
   ```

## Verify on the guest

```bash
cloud-init status --long   # 'status: done' == success
sudo -l                    # admin: NOPASSWD rule; appuser: not permitted
```

Logs: `/var/log/cloud-init.log`, `/var/log/cloud-init-output.log`.

## Notes

- **cloud-init runs once per instance.** To re-test on the same disk:
  `sudo cloud-init clean --logs && sudo reboot`, or boot a fresh image copy.
- **`users:` replaces the default set.** The `- default` entry in
  `user-data.yaml` keeps the stock `fedora` user; remove it for only the two
  users above.

## Troubleshooting

**`run`: "could not auto-discover the CHECKSUM file".**
The mirror blocked the directory listing (some mirrors and the bot-protected
`dl.fedoraproject.org` do). Bypass discovery by pinning the compose or the URL:

Set one of these in your config file, then re-run:

```ini
COMPOSE=1.5
# or, fully explicit:
CHECKSUM_URL=https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-44-1.5-x86_64-CHECKSUM
```

Find the current compose id on the [Fedora Cloud download page](https://fedoraproject.org/cloud/download/).

**`gpgv: Can't check signature: No public key`.**
The wrong or a stale keyring. Delete `$BASE_IMAGE_DIR/fedora.gpg` so `run`
refetches it, or point `FEDORA_GPG_URL=` at the correct keyring. Never skip this
step — an unverified image is the whole thing this project guards against.

**`sha256sum -c` reports FAILED.**
A truncated or tampered download. Delete the file from `$BASE_IMAGE_DIR` and re-run; if it
fails again from a different mirror, do not boot it.

**`virsh domifaddr` shows no address (or `N/A`).**
Expected with the default `qemu:///session` + `NETWORK=user`: user-mode
networking gives no queryable lease. Reach the guest via the serial console
(`virsh -c qemu:///session console fedora-cloud-01`, Ctrl+] to exit). For a
routable IP, switch to a system NAT setup — set `LIBVIRT_URI=qemu:///system` and
`NETWORK=network=default`, then:
- Watch progress on the serial console: `virsh -c qemu:///system console fedora-cloud-01` (Ctrl+] to exit).
- Confirm the VM is on the NAT network: `virsh -c qemu:///system domiflist fedora-cloud-01`.
- Ensure the default network is active: `virsh -c qemu:///system net-start default`.

**SSH: `Permission denied (publickey)`.**
- You're connecting with the wrong key — use `-i ~/.ssh/<user>-<DOMAIN>` (the private key whose `.pub` you built with).
- `AllowUsers` only permits the two provisioned users (`STD_USER`/`ADMIN_USER`); any other account is rejected. Check the sshd drop-in.
- cloud-init may not have finished. On the console: `cloud-init status --long` should read `done`; check `/var/log/cloud-init-output.log`.

**`systemd-tpm2-setup.service` failed in the guest.**
Expected when the VM has no TPM (the default) — the unit that provisions the TPM2
has nothing to talk to. It's **harmless** and unrelated to Secure Boot (which
validates signatures, not TPM measurements). To make it succeed, set `TPM=yes`
in the config (attaches an emulated TPM 2.0; needs `swtpm` on the host:
`sudo dnf install swtpm swtpm-tools`) and rebuild.

**`systemd-tpm2-setup.service` still fails *with* `TPM=yes` (Fedora 44).**
The TPM is working — check the journal and you'll see the real work succeeded:

```
SRK already stored in the TPM.
Successfully written anchor secret to '/var/lib/systemd/nvpcr/nvpcr-anchor.cred'.
2 NvPCRs already initialized.
Failed to write anchor secret file to
'/boot/efi/loader/credentials/nvpcr-anchor.….cred': Permission denied
```

Only the last line fails, and it's an **SELinux policy gap**, not a TPM fault.
systemd 258/259 added [NvPCR](https://www.freedesktop.org/software/systemd/man/latest/systemd-tpm2-setup.service.html),
which mirrors the anchor secret to the EFI System Partition; Fedora 44's
`selinux-policy` doesn't yet allow the early-boot `init_t` domain to create files
on the vfat ESP (`dosfs_t`). Confirm with:

```bash
sudo ausearch -m avc -ts boot | grep -i tpm2
# avc: denied { create } … scontext=…init_t tcontext=…dosfs_t tclass=file
```

The SRK and NvPCRs are provisioned in TPM NV storage (and mirrored to
`/var/lib/systemd/nvpcr/`); only the ESP copy — which nothing in a cloud VM
consumes — is missing. **Leave it as-is**: masking the unit would skip real SRK
setup on future TPM/firmware changes, and an `audit2allow` module would grant
all of `init_t` write access to the ESP just to silence a cosmetic failure. The
proper fix is an upstream `selinux-policy` update.

**UKI image fails on the very first boot.**
Early UKI images were subject to a shim bug where the first boot can fail and need
a reset. Force one boot cycle:

```bash
virsh -c qemu:///session reset fedora-cloud-01
```

**`error: config:<n>: ...` on startup.**
The config file failed strict validation at that line — e.g. a non-integer
`RAM_MB`, an `http://` URL, an unknown key, or a line that isn't `KEY=VALUE`. Fix
that line; see `fedora-cloud.conf.example` for the allowed keys and value formats.

**`error: '--config <file>' is required ...`.**
`build`, `boot`, and `run` all need `--config`. Only `help` runs without it.

**A strict crypto policy broke TLS / locked out a client.**
Symptoms: `curl` reports *"failed to verify the legitimacy of the server"* (e.g.
the Claude installer against a 2048-bit-RSA CDN), or an older SSH/TLS client is
refused. This happens with `CRYPTO_POLICY=FUTURE`. On the guest, relax it:
`sudo update-crypto-policies --set DEFAULT:NO-SHA1 && sudo systemctl reload sshd`.
To make it stick for future VMs, set `CRYPTO_POLICY=DEFAULT:NO-SHA1` (the default)
in the config and rebuild.

**Re-running `boot` uses the old disk state.**
The qcow2 overlay in `$OVERLAY_IMAGE_DIR` persists between runs. Reset it with
`./fedora-cloud.sh --config <f> boot --fresh <image> <mode>`, which recreates the
overlay from the pristine base — cloud-init only re-applies on a fresh instance.

## References

- [Users and Groups module](https://docs.cloud-init.io/en/latest/reference/modules.html)
- [Cloud-config examples](https://docs.cloud-init.io/en/latest/reference/examples.html)
- [NoCloud datasource](https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html)
