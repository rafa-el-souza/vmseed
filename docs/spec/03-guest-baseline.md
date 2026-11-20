# 03. Guest baseline

What vmseed puts inside every machine, and how it proves it.

## Model

- The baseline is **fixed**: every managed VM gets every applicable control.
  There is no switch to turn a control off.
- A few **knobs** change how a control is applied (who may reach SSH, extra
  ports, update behaviour). Each knob is known to the control's probe.
- The intent of a control is the same on every distro. The mechanism comes
  from the distro's primitives.
- A control that cannot exist on a distro reports `n/a` with a documented
  reason. That is visible, never silent. Whether a control is `n/a` or `skip`
  is decided by the plan on the host, never by the guest.

### What the proof is worth

Every result is the guest describing itself.

- The **baseline report**, emitted before any recipe command runs, depends
  only on the image and on vmseed's own code.
- The **final report**, emitted after a reboot, also covers what recipes and
  the upgrade did. A hostile recipe runs as root and could falsify it; it
  detects accidental breakage, not a recipe that lies.
- A later `verify` detects configuration drift. It is not intrusion
  detection: a compromised guest can answer whatever it likes.

The user documentation must state these limits.

## Two boots

`create` boots the VM twice (ADR 0018).

| Boot | What happens in the guest |
|---|---|
| 1 | cloud-init applies identity, files and network. `vmseed-firstboot` applies the baseline, emits the **baseline report**, upgrades, runs recipes, schedules the next-boot reporter, disables cloud-init, powers off. |
| 2 | No seed, no cloud-init. The next-boot reporter emits the **final report** on the upgraded kernel and removes itself. |

The VM is ready only if both reports are complete and every control in each
has an acceptable status.

## Division of labour in the guest

| Done by | What | Why |
|---|---|---|
| cloud-init | hostname, users with pinned UIDs and their keys, files (`write_files`), static network, launching the first-boot script | Mature, declarative, the same input format on both distros |
| `vmseed-firstboot` (generated `sh`) | everything stateful: packages, accounts fix-ups, services, sysctl, firewall, shares, upgrade, recipe commands, disabling cloud-init, reporting, powering off | One place for ordering, error capture and reporting |

cloud-config keys used: `hostname`, `users` (without `default`), `ssh_pwauth:
false`, `disable_root: true`, `ssh_deletekeys: true`, `ssh_genkeytypes:
[ed25519]`, `write_files`, `runcmd` (a single entry: the first-boot script).
`packages`, `package_update` and `package_upgrade` are **not** used.

`meta-data` carries `instance-id` (the VM's UUID) and `local-hostname`.
`network-config` exists only for a static address (see 04).

### Files vmseed owns in the guest

| Path | Content |
|---|---|
| `/usr/local/sbin/vmseed-firstboot` | First-boot script. `0700 root`. |
| `/usr/local/sbin/vmseed-report` | Report script as rendered at creation. `0700 root`. |
| `/var/lib/vmseed/` | Step results, markers, timestamps. `0700 root`. |
| `/etc/ssh/sshd_config.d/00-vmseed.conf` | sshd drop-in. `0600 root`. |
| the distro's nftables ruleset file | Firewall ruleset. |
| `/etc/sysctl.d/90-vmseed.conf` | Network and kernel sysctls. |
| distro-specific files | Privilege rule, update configuration, resolver drop-in, host-key generation setting, next-boot reporter. Listed per primitive. |

Every file starts with a `Managed by vmseed` comment. The nonce appears only
in root-only files. It is never placed on a command line, in the environment
of a non-root process, in a world-readable file or in a trace log.

## Distro primitives

Status of each statement: **(S)** supported by upstream source or
documentation, **(O)** observed on a Fedora 44 Cloud system, **(A)** assumed.
None has been confirmed on a VM booted by vmseed; see `10-assumptions.md`.

| Primitive | Fedora | Alpine |
|---|---|---|
| Packages | `dnf` (dnf5): `install`, `upgrade --refresh` | `apk`: `add`, `update`, `upgrade` |
| Services | systemd | OpenRC |
| Image accounts to remove | none (S) | `alpine`, created by the image builder with UID 1000, in `wheel` (S) |
| Admin privilege | sudoers rule `NOPASSWD:ALL` through cloud-init's `sudo:` (O) | Remove the image's `/etc/doas.d/wheel.conf` (`permit nopass :wheel`) (S); write vmseed's own rule file, one `permit nopass <user>` per admin |
| Privileged groups | `wheel`, `root`, `disk`, `adm`, plus engine groups such as `docker`, `libvirt` | `wheel`, `root`, `disk`, `adm`, `docker`, `libvirt` |
| Elevation for verify | `sudo -n` | `doas -n` |
| Password locking | `lock_passwd: true` (O) | field set to `*`, not `!`: Alpine's sshd is built without PAM and refuses key login to an account whose field starts with `!` (S) |
| Root lock | explicit lock step; the field must be non-empty and not a hash | same |
| Run as user | `runuser -l <user> -c` | `su -l <user> -c` |
| Default shell | `/bin/bash` | `/bin/ash` |
| sshd drop-in | included first by the stock config; written before sshd starts (O) | included first by the stock config (S); sshd may start before cloud-init writes it, so the first-boot reload applies it (S) |
| Host-key generation | mask `sshd-keygen@rsa.service` and `sshd-keygen@ecdsa.service`, which otherwise create keys at the first boot without cloud-init (O) | `key_types_to_generate="ed25519"` in `/etc/conf.d/sshd`; otherwise every start and reload runs `ssh-keygen -A` (S) |
| nftables | `nftables.service` loads `/etc/sysconfig/nftables.conf`; the package is in the image (O) | `nftables` service loads `/etc/nftables.nft`; saving on stop is already off (S) |
| Resolver listeners | systemd-resolved listens on TCP and UDP 5355 on all addresses (O): drop-in with `LLMNR=no`, `MulticastDNS=no` | none |
| Automatic updates | `dnf5-plugin-automatic`; `/etc/dnf/automatic.conf` with `apply_updates = yes`, `reboot = never` (the shipped default only downloads) (S); `dnf5-automatic.timer` | script in `/etc/periodic/daily/` running `apk upgrade`; enable `crond`, which is off by default (S) |
| MAC | SELinux, enforcing | none |
| Crypto policy | `update-crypto-policies` | none |
| sysctl | `sysctl --system`; glob keys such as `net.ipv4.conf.*.rp_filter` are accepted (S) | `sysctl -p <file>` and the `sysctl` boot service; no globs, so interface keys are written by name |
| sysctl keys absent | none of the listed keys (O) | `vm.unprivileged_userfaultfd` (kernel built without userfaultfd) (S) |
| Run once at next boot | a oneshot unit ordered after the network, sshd and nftables | a script in `/etc/local.d/`, which runs last |
| Power off | `systemctl poweroff` | `poweroff` |

## Control catalog

Twenty-one baseline controls and two conditional ones. IDs are stable; they
appear in reports, in the inventory and in documentation.

| ID | Control | Knob | Phases |
|---|---|---|---|
| ACC-01 | Only the declared human accounts exist | `users` | both |
| ACC-02 | root cannot log in: no usable password, no SSH | | both |
| ACC-03 | Declared users authenticate by key only | | both |
| ACC-04 | Only admins can escalate privilege | `users[].role` | both |
| SSH-01 | Public-key authentication only | | both |
| SSH-02 | No root login over SSH | | both |
| SSH-03 | Logins limited to the declared users | `users` | both |
| SSH-04 | Attempt limits and dead-peer detection | | both |
| SSH-05 | Forwarding and tunnelling off in the SSH service | `ssh.tcp_forwarding` | both |
| SSH-06 | Modern algorithms only | | both |
| SSH-07 | A single ed25519 host key, the one recorded on the host | | both |
| NET-01 | Default-deny inbound firewall | `ssh.allow_from`, `firewall.allow` | both |
| NET-02 | Only declared TCP ports listen on non-loopback addresses | `firewall.allow` | both |
| NET-03 | Network sysctls, effective on every interface | | both |
| KRN-01 | Kernel attack-surface sysctls | | both |
| KRN-02 | Filesystem link and core-dump protections | | both |
| UPD-01 | Fully upgraded, and running the upgraded kernel | `updates.first_boot` | final |
| UPD-02 | Automatic updates enabled and effective | `updates.automatic` | both |
| MAC-01 | Mandatory access control enforcing | | both |
| CRY-01 | System-wide crypto policy without SHA-1 signatures | | both |
| CIN-01 | Provisioning agent retired | | final |
| SHR-01 | Declared shares are mounted and usable (only if shares exist) | `shares` | both |
| RCP-01 | Every recipe step succeeded (only if recipes exist) | `recipes` | final |

"Both" means the baseline report and the final report.

Changing the list (adding, removing, or weakening a control) needs an ADR.

### Accounts

**ACC-01.** The `users` list has no `default` entry, and the `Accounts`
primitive removes the accounts the image itself ships.
Probe: the set of accounts with a UID from 1000 to 59999 equals the declared
users, each with its declared UID; no account other than `root` has UID 0.

**ACC-02.** cloud-init `disable_root: true` covers SSH keys; root's password
is locked by an explicit step.
Probe: root's shadow field is non-empty and starts with `!` or `*`; SSH-02
holds.

**ACC-03.** No user has a password. The mechanism is the distro's
password-locking primitive.
Probe: each declared user's shadow field is **non-empty**, is not a valid
hash, and is in the form the distro's sshd accepts for key login.

**ACC-04.** Admins get passwordless escalation through the distro's privilege
primitive. Nobody else can escalate.
Probe, all parts required:
- functional: as root, run the elevation test as each declared user; it must
  succeed for admins and fail for standard users;
- no passwordless rule (sudoers or doas) exists for any other user or group;
- the members of the distro's privileged groups are a subset of the declared
  admins.

Why passwordless: no password exists on the machine, so a prompting rule could
never be satisfied. An admin's SSH private key is therefore equivalent to root
on that VM; the user documentation must say so.

### SSH

One drop-in, validated with `sshd -t` before any reload. A failing validation
leaves the previous configuration in place and fails the step.

```
# Managed by vmseed.
PermitRootLogin no
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
AllowUsers <declared users>
MaxAuthTries 3
LoginGraceTime 20
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding <ssh.tcp_forwarding>
AllowStreamLocalForwarding no
GatewayPorts no
PermitTunnel no
HostKey /etc/ssh/ssh_host_ed25519_key
KexAlgorithms <explicit list>
Ciphers <explicit list>
MACs <explicit list>
HostKeyAlgorithms <explicit list>
PubkeyAcceptedAlgorithms <explicit list>
```

**How SSH probes read the configuration.** sshd keeps the first value it reads
for a *global* option, so an early drop-in wins there. A `Match` block in any
later file still overrides it for matching connections, and plain `sshd -T`
does not show that. Therefore:

- probes evaluate `sshd -T -C user=<u>,host=<h>,addr=<a>` for each declared
  user, for one undeclared name, and for an address inside and outside
  `ssh.allow_from`;
- the SSH controls fail if the effective configuration (the main file and
  everything it includes) contains any `Match` block. vmseed writes none.

**SSH-04.** `MaxAuthTries` and `LoginGraceTime` limit attempts. The
`ClientAlive` settings drop connections whose peer stopped answering; they are
not an idle timeout.

**SSH-05.** These settings reduce what the SSH service itself offers. They do
not confine a user who has a shell, who can run their own forwarder.

**SSH-06.** The algorithm lists are explicit on every distro, so the result
does not depend on a distro mechanism. They are chosen to be accepted by the
OpenSSH of every supported image and by the sshd used in the contract tier,
and are proven by `sshd -t` in e2e. The probe is a deny-list applied to the
five options vmseed sets (`kexalgorithms`, `ciphers`, `macs`,
`hostkeyalgorithms`, `pubkeyacceptedalgorithms`): no entry containing `sha1`,
`cbc`, `3des`, `arcfour`, `md5` or `umac-64`, and no `ssh-rsa` or `ssh-dss`
signature algorithm.

**SSH-07.** cloud-init regenerates host keys and creates only ed25519; the
`SshServer` primitive stops the distro from creating other types later.
Probe: sshd serves exactly one host key, and it is the key carried in the
report. Other key files found on disk are removed by the baseline and listed
as evidence.

### Network

**NET-01.** One nftables table, identical on every distro.

```
table inet vmseed
delete table inet vmseed
table inet vmseed {
  chain input {
    type filter hook input priority filter; policy drop;
    iif "lo" accept
    ct state established,related accept
    ct state invalid drop
    meta l4proto icmp icmp type { echo-request, destination-unreachable,
                                  time-exceeded, parameter-problem } accept
    meta l4proto ipv6-icmp accept
    udp sport 67 udp dport 68 accept
    ip6 saddr fe80::/10 udp dport 546 accept
    tcp dport 22 <source match, if ssh.allow_from> accept
    <one rule per firewall.allow entry and per passt forward>
  }
}
```

- The file replaces vmseed's own table atomically and touches no other table,
  so tables created by a container engine survive a reload.
- The distro's stock ruleset file is replaced by one that loads only this
  table.
- Only an `input` chain. The VM is not a router, and a dropping `forward`
  chain would break container engines a recipe might install.
- The firewall is loaded **before** the upgrade, as one of the first baseline
  steps.

Probe requirements: (a) the service is enabled; (b) the table exists and the
input policy is `drop`; (c) the loaded table equals the rendered one. For (c)
the probe loads the rendered file into a scratch network namespace with the
guest's own `nft` and compares the two listings of `table inet vmseed`, so
formatting differences between `nft` versions do not matter.

**NET-02.** The probe reads listening sockets from `/proc/net/tcp` and
`/proc/net/tcp6` and compares non-loopback TCP listeners with `22` plus the
declared ports. The `Resolver` primitive switches off stub-resolver listeners
(LLMNR and mDNS on Fedora).
Scope: TCP only. UDP is excluded and the rationale documented: client sockets
(DHCP, NTP) appear as listeners and are filtered by NET-01.
Principle for calibration: a listener the baseline cannot justify is
**disabled**, not added to an allow-list.

**NET-03.** Intent, per interface:

```
rp_filter = 1                 (IPv4, strict)
accept_redirects = 0          (IPv4 and IPv6)
send_redirects = 0            (IPv4)
accept_source_route = 0       (IPv4 and IPv6)
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
```

Writing only the `all` and `default` variants is not enough: the kernel uses
the larger of `all` and the interface value for `rp_filter`, systemd sets it
to 2 on every interface, and IPv6 `accept_redirects` on an existing interface
does not follow `all` or `default`. The `SysctlLayout` primitive therefore
sets the values per interface as well as `all` and `default`.
Probe: the **effective** value on every non-loopback interface.

`net.ipv4.ip_forward` is deliberately neither set nor checked: container
engines enable it.

### Network limits

Part of the security model; the user documentation must list them.

1. **Egress is not filtered.** The guest reaches whatever the host's network
   lets it reach. With passt it appears as the host.
2. **passt exposes the host's loopback.** The guest reaches services bound to
   the host's `127.0.0.1`, including the forwarded ports of every other passt
   VM. libvirt has no switch for it. passt isolates VMs at layer 2 only.
3. **Forwarded ports are local, not private.** A port forwarded on
   `127.0.0.1` is reachable by every user and process on the host.
4. **A session-mode bridge has no anti-spoofing.** Neighbouring VMs can spoof
   addresses and send router advertisements. `ssh.allow_from` and
   `firewall.allow.from` filter source addresses; they do not authenticate.
5. **Router advertisements are accepted.** Disabling them would break IPv6
   autoconfiguration; recorded as an open question.
6. **Ports published by a container engine bypass NET-01**, which has no
   `forward` chain, and NET-02 does not see them when no process listens.

### Kernel

**KRN-01.**

```
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.perf_event_paranoid = 2
kernel.yama.ptrace_scope = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
kernel.kexec_load_disabled = 1
kernel.sysrq = 0
dev.tty.ldisc_autoload = 0
vm.unprivileged_userfaultfd = 0
kernel.randomize_va_space = 2
```

**KRN-02.**

```
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
```

Each distro declares which of these keys its kernel has. Only those are
rendered, so no boot service fails on an unknown key.
Probe: every key the distro declares must exist and hold its value. A declared
key that is missing **fails** the control; a typo cannot pass silently.

Known costs and residuals:
- `ptrace_scope = 1` stops a user attaching a debugger to a process that is
  not its child. No knob in v1.
- Unprivileged user namespaces and io_uring stay enabled. They are large
  kernel surfaces for a local attacker, and they are also what rootless
  containers and sandboxing tools need. Recorded as an open question.

### System

**UPD-01.** After the baseline report, the first-boot script refreshes the
package index and upgrades everything. The second boot then runs the upgraded
kernel.
Probe (final report): the marker shows a successful upgrade, and the running
kernel is the newest one installed. `skip` when `updates.first_boot = false`.

**UPD-02.** The distro's automatic-update primitive, configured to **apply**
updates without rebooting. The update job records a timestamp on each
successful run.
Probe: the effective configuration applies updates; the timer (or periodic
script and cron daemon) is enabled and active; and either a successful run or
the VM's creation is less than seven days old. `skip` when
`updates.automatic = false`.

**MAC-01.** Asserted, not changed: the image must already enforce.
Probe: SELinux is `Enforcing` now and in its configuration file. `n/a` on a
distro without a MAC primitive (Alpine), with the reason in the report.

**CRY-01.** Fedora: `update-crypto-policies --set DEFAULT:NO-SHA1`. This bans
SHA-1 in signatures system-wide while keeping 2048-bit RSA, which stricter
policies break for some TLS endpoints. `n/a` where no crypto-policy primitive
exists.
Probe: the active policy is `DEFAULT:NO-SHA1`.

**CIN-01.** The first-boot script creates `/etc/cloud/cloud-init.disabled`
before powering off, and the host starts the second boot without the seed.
Probe (final report): the file exists, and the next-boot reporter has removed
itself.

### Conditional

**SHR-01.** Each declared share has a mount point, an `fstab` entry with
`nofail,nosuid,nodev` (plus `ro` when read-only), and is mounted that way.
Shares are mounted before the upgrade, while the running kernel's modules are
still on disk.
Probe: `/proc/mounts` shows each share with type `virtiofs` and the expected
options; for a writable share, `owner` can create and delete a file in it.

**RCP-01.** Probe (final report): every recipe step recorded exit status `0`,
and every recipe package is installed.

## Shares: trust model

Part of the security model; the user documentation must state it.

- A writable share is an **output channel from an untrusted machine**. Read
  and copy out of it. Do not run, build or open as a project anything in it
  without the care owed to untrusted code.
- No guest identity is the invoking user on the host, so files the guest
  writes are not the user's: tools such as git refuse to operate on them, and
  that refusal is a protection, not a nuisance.
- To send files into a guest, use a separate share with `readonly = true`.
- A share survives `destroy`. A new VM that mounts it sees what the old one
  wrote; `nosuid,nodev` on the guest mount limits what that can do.
- Do not share a directory that holds anything else.

## First-boot script

`vmseed-firstboot` is generated per VM. Order:

1. Install the baseline packages that are missing. No upgrade yet.
2. Baseline steps, in control registry order. The firewall is among the
   first.
3. Shares: mount points, `fstab`, mount.
4. **Baseline report** to the report channel.
5. Refresh the index and upgrade (unless disabled).
6. Recipe packages, then recipe commands in order, each as its `run_as` user.
7. Schedule the next-boot reporter.
8. Disable cloud-init.
9. Power off.

Semantics:

- Every step runs through a wrapper that records its exit status under
  `/var/lib/vmseed/steps/`. A failing step **does not stop** the script: both
  reports must always be emitted, and the probes report the real state.
- Network-dependent steps retry a bounded number of times.
- vmseed never re-runs the script.
- Recipe files arrive through `write_files` with `defer: true`, so they are
  written after users exist.

Why this order: the firewall, kernel modules and mounts are in place before
the upgrade (on Alpine the upgrade removes the running kernel's modules), and
the baseline is reported before any recipe code runs.

## Report script

`vmseed-report` contains one `sh` function per applicable control and prints
the protocol defined in 05. It is rendered per VM, with expected values
embedded.

- During `create` it writes to the dedicated report channel (the second serial
  port), once per boot.
- For `verify`, the host renders the script again from the **current**
  configuration and pipes it over SSH. The copy in the guest is never trusted
  or required. This is also what makes adopted VMs verifiable.
- Probes read system state through small helpers whose root can be redirected,
  so they can be tested on the host against fixture trees.

## Carried from v0

Knowledge paid for in v0 that still applies. Details and wording are in the
`v0-bash` tag (`user-data.yaml`, `README.md`).

- An early-sorting sshd drop-in wins for global options, because sshd keeps
  the first value it reads. A later `Match` block is a separate matter (see
  SSH above).
- Validate with `sshd -t` before reloading, so a bad file fails loudly instead
  of locking everyone out.
- `write_files` runs before users exist; files in a home directory need
  `defer: true`.
- Fedora Cloud Base enables no packet filter.
- A locked password plus a prompting sudo rule means the admin can never
  escalate: hence `NOPASSWD`.
- `DEFAULT:NO-SHA1` rather than `FUTURE`: the latter requires 3072-bit RSA and
  breaks TLS to some CDNs.
- UKI images are UEFI-only and their kernel command line is sealed.
- Secure Boot needs the q35 machine type with SMM, and firmware with enrolled
  keys.
- `systemd-tpm2-setup.service` fails harmlessly without a TPM.

## Removed from v0

| Removed | Replacement or reason |
|---|---|
| Samba share, SMB password in the seed | virtiofs shares (ADR 0013) |
| fail2ban and the custom Samba filter | Key-only SSH plus `ssh.allow_from` (ADR 0013) |
| firewalld and offline rich rules | nftables (ADR 0011) |
| `CRYPTO_POLICY` key | Fixed by CRY-01 |
| Built-in tmux, Claude Code, `gh`, `btop` | Example recipe in `examples/sandbox/` (ADR 0012) |
| `guest-diagnostics.sh` | `verify` and the captured console log |
| Stock `fedora` user kept | ACC-01 |
| Emulated TPM option | Out of v1 (ADR 0016) |
