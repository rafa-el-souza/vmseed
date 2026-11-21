# 10. Assumptions and open questions

The specification was written on a machine that cannot boot a VM. Nothing
below has been confirmed on a VM created by vmseed. Each row says what
supports it so far, where it gets verified, and what happens if it is false.

Rules:

- An assumption stays open until a CI run or a host-check result is recorded
  here. Reading upstream source raises confidence; it does not close a row.
- Never rely on an open assumption without saying so.
- A fallback marked "needs an ADR" changes a decision: stop and ask the user.

## Verified

Checked directly, on the dev VM or in the primary source.

| ID | Statement | Evidence |
|---|---|---|
| V-NFT-NS | An nftables ruleset can be loaded for real, without root, inside `unshare -rn` | Dev VM, 2026-11-20 |
| V-SSHD-T | `sshd -T -f <file>` prints the effective configuration for an unprivileged user | Dev VM, 2026-11-20 |
| V-SSHD-MATCH | Plain `sshd -T` shows hardened global values while a later `Match` block overrides them; `sshd -T -C user=...` shows the override | Dev VM, 2026-11-21 |
| V-CI-SCHEMA | cloud-init's Python schema API validates a cloud-config through the system interpreter; the `cloud-init schema` command fails unprivileged on a provisioned machine | Dev VM, cloud-init 26.1, 2026-11-20 |
| V-SSH-DEFAULTS | OpenSSH's compiled-in defaults still offer `umac-64` and `hmac-sha1` MACs, so explicit lists are needed | Dev VM, 2026-11-20 |
| V-QCOW-BACKING | `qemu-img convert` copies into the new disk the content of a file the source image names as its backing file; disabling the backing prevents it | Dev VM, qemu-img 10.2.2, 2026-11-21 |
| V-FED-LLMNR | A Fedora 44 Cloud system listens on TCP 5355 on all addresses | Dev VM, 2026-11-21 |
| V-FED-RPFILTER | systemd ships `net.ipv4.conf.*.rp_filter = 2`, and the interface value is 2 | Dev VM, 2026-11-21 |
| V-FED-KEYGEN | Fedora's units create RSA and ECDSA host keys whenever cloud-init is not active at boot | Unit files on the dev VM, 2026-11-21 |
| V-ALP-KEYGEN | Alpine's sshd init script runs `ssh-keygen -A` on start and on reload unless configured otherwise | Alpine `openssh` init script, 3.24 branch, read 2026-11-21 |
| V-ALP-ACCOUNT | The Alpine cloud image builder creates an `alpine` account in `wheel` and writes `permit nopass :wheel` | Image builder script, read 2026-11-21 |
| V-VIRTIOFS-MAP | Without an ID map, session-mode libvirt maps guest root to the invoking user and other IDs to the subordinate range | libvirt virtiofs documentation, read 2026-11-21 |
| V-URI-CMD | A libvirt URI can name a program to run (`ext` and `ssh` transports) | libvirt URI reference, read 2026-11-21 |
| V-PASST-FWD | A passt interface with a forward on `127.0.0.1` gives working SSH in session mode, and the guest can reach host loopback services | Measured by the author on a Fedora 44 host, libvirt 12.0.0, 2026-10-13 |
| V-GH-PERMS | For a fine-grained token: merging a pull request needs Contents write; approving a pending deployment needs Deployments write; dispatching a workflow needs Actions write | GitHub permissions reference, read 2026-11-21 |
| V-GH-TOKEN | The dev VM's token is fine-grained and limited to this repository: it can write contents and pull requests, and is refused for administration, deployments, commit statuses, Actions writes, secrets, variables and webhooks. It holds the workflow permission while M0 runs: the push of M0's workflow files was accepted | Read requests, and write requests built to fail validation, 2026-11-21; the push of branch `m0-foundation`, 2026-11-21 |
| V-GH-CLOUD | Since 2026-10-28 standard Linux runners may run on a second cloud; nothing is stated about KVM there | GitHub changelog, read 2026-11-21 |
| V-NAMES | Upstream file names and release numbers in 06 | Mirrors read on 2026-11-20 |
| V-PYRIGHT-NODE | The `pyright` wheel carries the type checker itself. It takes Node.js from the `nodejs-wheel-binaries` wheel when that is installed (the `nodejs` extra), otherwise from `PATH`, otherwise it downloads it with `nodeenv` on first run. Unless `PYRIGHT_PYTHON_IGNORE_WARNINGS` is set, each run also asks PyPI whether a newer version exists | Wheel source of pyright 1.1.414 read, and an offline run on the dev VM that used the locked Node.js and downloaded nothing, 2026-11-21 |
| V-UV-BUILD | uv builds a project whose backend is `uv_build`, in a version range that includes uv's own version, by itself ("direct build"): nothing outside `uv.lock` is downloaded to install the project | Offline `uv sync` on the dev VM, uv 0.13.7, 2026-11-21 |
| A-CI-USERNS | On the `ubuntu-24.04` runner the job relaxes AppArmor's restriction on unprivileged user namespaces (`kernel.apparmor_restrict_unprivileged_userns=0`), after which an nftables ruleset loads in an unprivileged user and network namespace | CI run 44862028406 (image 20261116.133.1), contract test on Python 3.12, 3.13 and 3.14, 2026-11-21 |
| V-UV-CONSTRAINTS | `uv tool install --constraints FILE` installs the versions the file pins, but does not check the hashes it carries: an install with every hash of one package replaced by zeros succeeded. `constraints.txt` therefore pins versions only | Dev VM, uv 0.13.7, 2026-11-21 |

## Infrastructure and process

| ID | Statement | Support so far | Verify | If false |
|---|---|---|---|---|
| A-CI-KVM | GitHub-hosted x86_64 Linux runners give a usable `/dev/kvm` often enough to rely on | Reported to work; not officially supported; may be intermittent (V-GH-CLOUD) | M1, then every run logs it | The job retries once and ends "no KVM". If persistent, ask the user: e2e on the host from a reviewed branch only, or a small Alpine subset under emulation. |
| A-CI-LIBVIRT | Session-mode libvirt with passt works on the runner image | None; AppArmor denials are reported for this combination on some images | M1 | e2e uses a system daemon on the runner with `data_access = "group"`, or a bridge |
| A-CI-TIME | A PR's e2e matrix fits in about 20 minutes | None | M3, M6 | A small set per PR, the rest scheduled |
| A-GH-GATE | A required deployment to an environment with a required reviewer blocks merging until the owner approves, and the session's token cannot approve | V-GH-PERMS | M0, with a throwaway PR | A separate machine account as PR author with required approval; or the user merges by hand. Ask the user. |
| A-GH-UNATTR | The ruleset option that asks for an extra approval on unattributed changes does not block a pull request opened with the owner's token while zero approvals are required | GitHub's rules reference: it adds one approval to a pull request opened by Copilot, and only when approvals are required. Third-party reports disagree | M0, with the throwaway PR | Turn the option off in the ruleset |
| A-REV-GATE | The approval request can be made to wait for the review record: `approve` needs `review-record`, so no deployment is requested before the record is closed | The `needs` rule of GitHub Actions. On M0's pull request, with no record yet, `review-record` failed, `approve` was skipped and no deployment exists for the head (run 44862028448, 2026-11-21). An open record, and the request appearing once the record is closed, are still to be seen | M0 | The gate becomes advisory: the user checks the record before approving |
| A-REV-WORKTREE | On the dev VM a reviewer agent can work in a git worktree of its own, with its own virtual environment, within the disk and memory available | uv links packages from its cache | M0's review | The reviewer writes no test; the review session runs the reproductions it proposes, one at a time |
| A-REV-YIELD | Fixing only what the scale of 11 plans as `fix` leaves no defect that matters unfixed | None measured on this project | The counts at M3 and at M9, and any later defect traced to a finding that was only recorded | Widen the lists, by the user's decision |

## Hypervisor and host

| ID | Statement | Support so far | Verify | If false |
|---|---|---|---|---|
| A-PTY | `virsh console --devname` works on a PTY created by vmseed, for two ports at once; `start --paused`, attach, `resume` loses no output | libvirt source: needs a TTY, works on a paused domain | M1, batch 1 | Attach right after a normal start |
| A-TTYS1 | The second serial port is `/dev/ttyS1` on every image and carries only what the report script writes | None | M1, M3, M6 | A virtio-serial channel as the report port |
| A-POWEROFF | The guest powering itself off ends boot 1 with the domain shut off, and vmseed can start boot 2 | None | M1 | vmseed shuts the domain down after seeing the end of the baseline report |
| A-NEXTBOOT | The next-boot reporter runs exactly once, late enough for services to be up, on both distros | None | M1, M3 | Per-distro ordering fixes in the primitive |
| A-NVRAM | A custom NVRAM path in the data directory works with firmware autoselection in session mode | libvirt source keeps a user-supplied path | M1, batch 1 | Needs an ADR: libvirt's default location is outside the data directory |
| A-SB-OFF | Declaring the `secure-boot` firmware feature as `no` selects firmware without Secure Boot | libvirt source; such firmware descriptors exist on Fedora and Ubuntu | M1, M6 | Select the firmware explicitly |
| A-FDPATH | `qemu-img` can write its output through the path of a descriptor vmseed opened exclusively | None | M1 | Convert inside the control directory, then copy into the data directory with exclusive creation |
| A-HOST-SELINUX | With SELinux enforcing on the user's host, session-mode qemu can use a disk and seed in the data directory, including on encrypted storage | None | batch 1 | Document the required label or location; never loosen SELinux from vmseed |
| A-BRIDGE | A `bridge` interface works in session mode through the bridge helper | v0 does this through `virt-install` | batch 2 | Document the one-time host setup |
| A-VFS-START | `virtiofsd` starts in session mode on the user's host | None | batch 2 | Needs an ADR: return the share model to the user |
| A-VFS-IDMAP | An explicit ID map sending every guest ID into the subordinate range is accepted, and guest root then cannot write as the invoking user | The element validates against libvirt's schema | batch 2 | Needs an ADR |
| A-VFS-ACL | An access entry for the mapped owner lets it write a directory the invoking user owns, and a default entry keeps the invoking user's access to new files | None | batch 2 | Needs an ADR |
| A-FW-HOST | The host firmware packages provide UEFI with and without Secure Boot for q35 | Descriptors exist in the distro packages | M6, batch 3 | Preflight reports the missing package |
| A-SB-CA | The firmware's enrolled keys cover the shims of the supported Fedora images and of their updates, through the Microsoft UEFI CA transition | None | M6, batch 3 | Needs an ADR: a Secure Boot VM could stop booting after an automatic update |

## Guest: both distros

| ID | Statement | Support so far | Verify | If false |
|---|---|---|---|---|
| A-ISO | cloud-init's NoCloud source reads a `pycdlib` ISO labelled `CIDATA` with Joliet and Rock Ridge | The label and names read back correctly with `blkid` | M1, M3 | Adjust the ISO options. A VFAT seed would need a new dependency: ADR. |
| A-CIN | With cloud-init disabled and the seed gone, hostname, network, users and keys persist | By design, every `create` checks this in the final report | M1, M3 | Needs an ADR |
| A-GROW | The root filesystem grows to the declared disk size during the first boot | The Alpine image includes the grow tools | M3 | An explicit grow step through a primitive |
| A-NET02 | After the baseline, sshd is the only non-loopback TCP listener | False on stock Fedora (V-FED-LLMNR); the resolver primitive addresses it | M3 | Disable the extra listener; never allow-list it |
| A-SYSCTL | Each distro's list of sysctl keys matches its kernel | Fedora observed; Alpine from its kernel configuration | M3 | Correct the list |
| A-SYSCTL-IF | The per-interface mechanism makes the NET-03 values effective on both distros | None | M3 | Another mechanism in the primitive |
| A-SSH-ALGOS | One explicit algorithm list is accepted by OpenSSH 10.2 (Fedora 44), 10.6 (Fedora 45), 10.3 (Alpine 3.24) and the contract-tier sshd | Versions read from package metadata | M3, M6 | Lists become per-distro data |
| A-UPD-KERNEL | After the upgrade and the reboot, the running kernel is the newest installed | None | M3 | Per-distro boot-entry handling in the primitive |
| A-NETCFG | A version 2 `network-config` with a static address renders correctly on both distros and persists | None | M7 | Configure the address in the first-boot script through a primitive |
| A-TIME | Two boots with a full upgrade fit in the 30-minute default | None | M3, `e2e-full` | Raise the default; document it |

## Guest: Alpine

| ID | Statement | Support so far | Verify | If false |
|---|---|---|---|---|
| A-ALP-BOOT | The Alpine 3.24 cloud-init image boots under UEFI and under BIOS with q35 and virtio | Its metadata says the boot loader handles both | M1, M6 | Narrow the catalog entry's `firmware` |
| A-ALP-SB | The Alpine image cannot boot with Secure Boot | None | M6 | Set `secure_boot = true` in the catalog and test it |
| A-ALP-LOCK | A password field of `*` allows key login with the stock sshd, while `!` blocks it | Alpine's own documentation and image builder; OpenSSH source | M1 | Use `lock_passwd: true` as on Fedora |
| A-ALP-DOAS | Removing the image's wheel rule and writing vmseed's own rule file gives exactly the intended grants | Alpine's doas reads the main file and a drop-in directory | M3 | Write the rule where doas reads it |
| A-ALP-SSHD | Alpine's `sshd_config` includes the drop-in directory before other settings | Upstream packaging | M3 | The primitive adds the `Include` line at the top |
| A-ALP-KEYTYPES | Setting the key types to generate stops the init script from creating other host keys | V-ALP-KEYGEN | M3 | Disable generation entirely and rely on cloud-init's key |
| A-ALP-NFT | Alpine's nftables service loads `/etc/nftables.nft` and does not save on stop | Upstream packaging | M3 | Adjust the layout primitive |
| A-ALP-CRON | BusyBox `crond`, once enabled, runs `/etc/periodic/daily` | Upstream packaging | M3 | Another scheduling primitive |
| A-ALP-UPGRADE | With the firewall loaded and shares mounted before it, an upgrade that replaces the kernel breaks nothing before the reboot | The upgrade removes the running kernel's modules | M3 | Load any module needed later before upgrading |
| A-ALP-OPENRC | Service commands issued from inside cloud-init's final stage work under OpenRC | None | M1, M3 | Defer them to the next-boot reporter |
| A-ALP-VIRTIOFS | The Alpine VM kernel can mount virtiofs | Its configuration builds it as a module | M7 | Load the module explicitly |

## Guest: Fedora

| ID | Statement | Support so far | Verify | If false |
|---|---|---|---|---|
| A-FED-NFT | `nftables.service` loads `/etc/sysconfig/nftables.conf`, and the package is in the image | Observed on a Fedora 44 Cloud system | M3 | Adjust the layout primitive |
| A-FED-AUTO | On Fedora 44 and 45 the automatic-update package, timer and configuration are those named in 03 | Package metadata and dnf5 documentation | M3 | Correct the names in the primitive |
| A-FED-KEYMASK | Masking the RSA and ECDSA key-generation units keeps a single host key across boots | V-FED-KEYGEN | M3 | Remove extra keys at each boot through the primitive |
| A-FED-RESOLVED | The resolver drop-in removes the 5355 listeners without breaking name resolution | None | M3 | Another setting in the primitive |
| A-FED-ROOT | root's password field on the image is locked or can be locked by the explicit step | None | M3 | Adjust the step |
| A-FED-UKI | A UKI image completes its first boot reliably | v0 noted an early shim problem that needed a reset | M6 | `create` retries one reset for UKI; document it |
| A-FED-UKI-CON | The UKI's sealed command line has a serial console | None; affects `console.log` only, not the report | M6 | Document that the console log is empty for UKI |
| A-FED-VIRTIOFS | Under SELinux enforcing in the guest, the share's owner can read and write a virtiofs mount | None | M7 | A mount context option through the primitive |

## Open questions

| ID | Question | Owner | Blocks |
|---|---|---|---|
| Q-CRED | With one account, two limits remain: while the token may change workflows a pull request could fabricate the approval, and release tags cannot be protected from the token. A separate machine account would close both. | User | Nothing: M0 starts with the single-account setup |
| Q-PYPI | Publish to PyPI, and under which name? The name's availability has not been checked. | User | Nothing until after 1.0.0 |
| Q-PTRACE | Does `ptrace_scope = 1` need a knob for developer sandboxes? | Decide after real use | Nothing |
| Q-USERNS | Should the baseline restrict unprivileged user namespaces or io_uring? Both are large kernel surfaces, and both are needed by rootless containers and sandboxing tools. | User, after real use | Nothing |
| Q-RA | Should the baseline stop accepting router advertisements, at the cost of IPv6 autoconfiguration? | Future ADR | Nothing |
| Q-EGRESS | Should a later version limit what a guest can reach, for example the host's loopback under passt? | Future ADR | Nothing in v1 |
| Q-SYSTEM | Should e2e include a scenario against a system daemon, to exercise the other-user rules of ADR 0005? | Decide in M4 | Nothing |
