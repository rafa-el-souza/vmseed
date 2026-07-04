# Fedora Cloud provisioning with cloud-init

Provisions a [Fedora Cloud Base](https://fedoraproject.org/cloud/download) image
on first boot with two SSH-only users:

| User      | Privileges                          | Group   |
|-----------|-------------------------------------|---------|
| `appuser` | Standard, no sudo                   | —       |
| `admin`   | Passwordless sudo (`NOPASSWD:ALL`)  | `wheel` |

Each user gets a public key loaded from a file in `keys/`. Password login is
disabled (`lock_passwd: true`) — SSH key authentication only.

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
| `AllowUsers` | `admin appuser` | only the provisioned users may log in |
| `MaxAuthTries` | `3` | fewer brute-force attempts per connection |
| `LoginGraceTime` | `20` | close unauthenticated sessions fast |
| `ClientAliveInterval` / `ClientAliveCountMax` | `300` / `2` | drop idle sessions |
| `X11Forwarding` / `AllowAgentForwarding` / `AllowTcpForwarding` / `PermitTunnel` | `no` | shrink attack surface |

Cipher/MAC/KEX selection is **not** hardcoded in the drop-in. Instead a `runcmd`
tightens Fedora's system-wide crypto policy with
`update-crypto-policies --set FUTURE`, which disables SHA-1, CBC-mode ciphers and
sub-3072-bit RSA everywhere (sshd, TLS, ...). Then `sshd -t && systemctl reload
sshd` validates and applies the config — a malformed config fails the boot loudly
instead of locking you out.

> **`FUTURE` is aggressive.** It can reject older SSH/TLS clients. Modern OpenSSH
> with ed25519/curve25519 keys (as generated in `keys/`) is fine. If you need
> broader compatibility, change the `runcmd` to
> `update-crypto-policies --set DEFAULT:NO-SHA1`.
>
> If you rename the users, update `AllowUsers` to match or you'll be locked out.

## Layout

```
fedora-cloud.sh  # single entry point: build | boot | run | help
user-data.yaml   # cloud-config TEMPLATE (PLACEHOLDER_* tokens)
keys/            # your *.pub files go here (private keys are git-ignored)
build/           # generated: user-data, meta-data, seed.iso, overlay (git-ignored)
images/          # downloaded qcow2 + CHECKSUM + fedora.gpg (git-ignored)
```

Everything is one script, `fedora-cloud.sh`, with three subcommands:

| Command | Does |
|---------|------|
| `fedora-cloud.sh build` | render `keys/*.pub` into `build/user-data` (+ optional `seed.iso`) |
| `fedora-cloud.sh boot [--fresh] <image> [MODE]` | boot an existing image under libvirt |
| `fedora-cloud.sh run [MODE\|--download-only]` | download + verify + build + boot, end-to-end |

`MODE` is `bios` (default), `uefi`, or `uefi-secure` — see [Image variants](#image-variants).

## Quick start (one command)

Once your keys are in `keys/`, `run` does everything — downloads the image,
**verifies its GPG signature and SHA-256 checksum**, builds the seed, and boots:

```bash
./fedora-cloud.sh run              # BIOS / Cloud Base Generic image
./fedora-cloud.sh run uefi         # UKI image (UEFI)
./fedora-cloud.sh run uefi-secure  # UKI image + Secure Boot
./fedora-cloud.sh run --download-only   # fetch + verify BOTH variants, no boot
```

It fetches Fedora's OpenPGP keyring, discovers the current `CHECKSUM` file,
verifies its signature with `gpgv`, resolves the exact image filenames **from the
verified checksum** (so nothing is hardcoded to a compose number), downloads the
qcow2, and checks its SHA-256 before booting. Override the release with
`VER=44`, or pin a compose with `COMPOSE=1.5` / `CHECKSUM_URL=...` if
auto-discovery is blocked by a mirror.

The steps below are the manual equivalent if you already have an image.

## Image variants

Fedora ships two Cloud Base variants. **The same `user-data.yaml` works on
both** — cloud-init behaves identically; only the boot firmware differs.

| | Traditional (non-UKI) | UKI |
|---|---|---|
| Firmware | Hybrid **BIOS + UEFI** | **UEFI-only** |
| Bootloader | shim → GRUB → kernel | shim → UKI directly (no GRUB) |
| initramfs | built on the host by dracut | prebuilt, baked into the signed kernel image |
| Kernel cmdline | editable via GRUB / `grubby` | **sealed inside the signed UKI** — not freely editable |
| Secure Boot | signs kernel only (initrd unsigned) | signs kernel **+ initrd + cmdline** |
| Confidential computing | noisy TPM measurements | **predictable, attestable** measurements |
| `MODE` argument | `bios` | `uefi` (or `uefi-secure`) |

**Which to use:** the non-UKI image is the safe default — BIOS/UEFI-compatible
and you can tweak kernel params freely. Choose the UKI image when you
specifically need Secure Boot with a signed initrd or confidential-computing
attestation.

> ⚠️ **UKI kernel cmdline caveat.** This project does not set any kernel command
> line, so both variants work as-is. But if you later add tooling that edits
> kernel params (`grubby`, GRUB edits), it will **not** take effect on the UKI
> image — its cmdline lives inside the signed binary. Use systemd-boot /
> `kernel-install` drop-ins or `.cmdline` add-ons there instead.
>
> UKI images are also UEFI-only and were, in early testing, subject to a shim
> bug that could fail the first boot and need a VM reset.

## Usage

1. Provide the public keys (see `keys/README.md`):

   ```bash
   ssh-keygen -t ed25519 -f keys/appuser -C appuser@fedora
   ssh-keygen -t ed25519 -f keys/admin   -C admin@fedora
   ```

2. Build the seed:

   ```bash
   chmod +x fedora-cloud.sh   # first time only
   ./fedora-cloud.sh build
   ```

   This renders `build/user-data`, validates it with `cloud-init schema`, and
   (if `cloud-localds` is installed) produces `build/seed.iso`.

   > Install the tooling on Fedora with:
   > `sudo dnf install cloud-utils virt-install libvirt qemu-img edk2-ovmf`
   > and ensure libvirtd is running: `sudo systemctl enable --now libvirtd`

3. Boot the image under libvirt with `boot` (pick the firmware mode to match
   the image variant — see [Image variants](#image-variants) below):

   ```bash
   ./fedora-cloud.sh boot Fedora-Cloud-Base.qcow2 bios              # traditional hybrid image
   ./fedora-cloud.sh boot Fedora-Cloud-Base-UKI.qcow2 uefi          # UKI image (UEFI-only)
   ./fedora-cloud.sh boot Fedora-Cloud-Base-UKI.qcow2 uefi-secure   # UKI + Secure Boot
   ```

   `boot` feeds `build/user-data` + `build/meta-data` to `virt-install
   --cloud-init` (which builds and attaches the NoCloud seed itself), boots from
   a qcow2 **overlay** so the base image stays pristine, and lets libvirt's
   firmware autoselection pick OVMF for the UEFI modes. Re-run with `--fresh` to
   reset the disk.

   For cloud providers, pass `build/user-data` to the platform's user-data field
   instead (e.g. `openstack server create --user-data build/user-data`, EC2 user
   data, ...). The `build/seed.iso` from `build` is only needed for manual
   qemu/`cloud-localds` workflows.

4. Connect (get the guest IP from libvirt's NAT lease):

   ```bash
   virsh -c qemu:///system domifaddr fedora-cloud-01
   ssh -i keys/admin   admin@<IP>
   ssh -i keys/appuser appuser@<IP>
   # or drop to the serial console:  virsh -c qemu:///system console fedora-cloud-01
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

```bash
COMPOSE=1.5 ./fedora-cloud.sh run uefi
# or, fully explicit:
CHECKSUM_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-44-1.5-x86_64-CHECKSUM" ./fedora-cloud.sh run uefi
```

Find the current compose id on the [Fedora Cloud download page](https://fedoraproject.org/cloud/download/).

**`gpgv: Can't check signature: No public key`.**
The wrong or a stale keyring. Delete `images/fedora.gpg` so `run` refetches it,
or point `FEDORA_GPG_URL=` at the correct keyring. Never skip this step — an
unverified image is the whole thing this project guards against.

**`sha256sum -c` reports FAILED.**
A truncated or tampered download. Delete the file from `images/` and re-run; if it
fails again from a different mirror, do not boot it.

**`virsh domifaddr` shows no address (or `N/A`).**
The lease appears only after the guest has booted and cloud-init has brought up
the network — give it 20–60s on first boot. If it never appears:
- Watch progress on the serial console: `virsh -c qemu:///system console fedora-cloud-01` (Ctrl+] to exit).
- Confirm the VM is on the NAT network: `virsh -c qemu:///system domiflist fedora-cloud-01`.
- Ensure the default network is active: `virsh -c qemu:///system net-start default`.

**SSH: `Permission denied (publickey)`.**
- You're connecting with the wrong key — use `-i keys/admin` / `-i keys/appuser` matching the `.pub` you built with.
- `AllowUsers` only permits `admin` and `appuser`; a renamed user is rejected. Check the sshd drop-in.
- cloud-init may not have finished. On the console: `cloud-init status --long` should read `done`; check `/var/log/cloud-init-output.log`.

**UKI image fails on the very first boot.**
Early UKI images were subject to a shim bug where the first boot can fail and need
a reset. Force one boot cycle:

```bash
virsh -c qemu:///system reset fedora-cloud-01
```

**`update-crypto-policies --set FUTURE` locked out an old client.**
`FUTURE` disables SHA-1/CBC/weak RSA system-wide. Connect via the serial console
and relax it: `sudo update-crypto-policies --set DEFAULT:NO-SHA1 && sudo systemctl reload sshd`,
or edit the `runcmd` in `user-data.yaml` before the next build.

**Re-running `boot` uses the old disk state.**
The qcow2 overlay in `build/` persists between runs. Reset it with
`./fedora-cloud.sh boot --fresh <image> <mode>`, which recreates the overlay from
the pristine base — and remember cloud-init only re-applies on a fresh instance.

## References

- [Users and Groups module](https://docs.cloud-init.io/en/latest/reference/modules.html)
- [Cloud-config examples](https://docs.cloud-init.io/en/latest/reference/examples.html)
- [NoCloud datasource](https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html)
