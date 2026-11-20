# 00. Overview

Status: agreed with the user on 2026-11-20; revised on 2026-11-21 after two
independent design reviews (technical soundness, and security). Changes go
through an ADR.

## What vmseed is

vmseed turns a declaration into a running, hardened virtual machine and a
report that proves it. Given a fleet file, `vmseed create <name>`:

1. fetches a cloud image pinned by digest in a versioned catalog, and checks
   that it is safe to open;
2. renders a cloud-init seed that applies a fixed security baseline;
3. defines a libvirt domain and boots it;
4. reads, over a dedicated serial channel, the result of every baseline
   control, reported before any user content runs;
5. removes the seed and boots the VM again, on its upgraded kernel, and reads
   a second report;
6. records the guest's SSH host key and hands the VM over.

After that vmseed steps back. Starting, stopping and logging in to the VM is
the job of the operator's own tools (`virsh`, virt-manager, or a script).

## Goals

- **G1. Hardened by default, and provably so.** Every hardening claim is a
  control with an identifier, an implementation per distro and an executable
  check.
- **G2. Distro-neutral.** Fedora Cloud Base 44 and 45 (Generic and UKI) and
  Alpine 3.24 at release. Adding a distro must not require touching controls.
- **G3. Easy to configure.** One typed TOML fleet file: shared defaults, plus
  what differs per VM.
- **G4. Reproducible.** The image is pinned by digest; the plan is a pure
  function of the configuration.
- **G5. A clear boundary.** vmseed creates, verifies, lists and destroys. It
  does not operate VMs.
- **G6. Portfolio quality.** Typed, tested in four tiers, documented from the
  code, and readable by someone evaluating the author.

## Non-goals

- Not a VM manager: no `start`, `stop`, `ssh`, console, copy or backup.
- No in-place reconfiguration. To change a VM, destroy and create it.
- No cloud providers, containers or Windows guests.
- No secret distribution. The seed is not a secret channel.
- No intrusion detection. Reports are a guest describing itself.
- No public plugin API in v1. Extension happens in-tree (see 01).
- No architectures other than `x86_64` in v1.
- No emulated TPM in v1.
- No remote hypervisors: only local `qemu` connections.
- No feature removed from v0 returns without an ADR: Samba, fail2ban,
  firewalld, the diagnostics script, the built-in developer environment.

## Principles

1. **Intent once, mechanism per distro.** A control states what must be true.
   Distro primitives say how to make it true.
2. **Functional core, imperative shell.** `config -> plan` is pure and
   snapshot-tested. Effects live at the edges.
3. **Data, not text.** YAML, XML and JSON are serialised from structures.
4. **The tool trusts only its own records.** They live where only the user
   can write. Nothing read back from a guest or from the hypervisor decides a
   path, an address or a destructive action.
5. **Untrusted input stays data.** Guest output, downloaded images and tool
   messages are validated, bounded and sanitised, never executed or followed.
6. **Explicit over implicit for security choices.** No built-in network kind.
   No silent defaults that weaken the baseline.
7. **Fail before side effects.** Validation and preflight run first and name
   the fix.
8. **Non-interactive provisioning.** `create` never prompts. Secrets are
   created by an explicit command (`keygen`).
9. **Say what a guarantee is worth.** Every limit the design knows about is
   written down and reaches the user documentation.
10. **Docs cannot drift.** Control and configuration references are generated
    from the code and checked in CI.
11. **Lean.** A dependency, a knob or a feature must pay for an implementation
    per distro, tests and a check.

## Glossary

| Term | Meaning |
|---|---|
| Fleet file | The `vmseed.toml` that declares defaults and VMs. |
| Control directory | Per VM, private to the user: state record, audit copies, logs. |
| Data directory | Per VM, used by the hypervisor: disk and NVRAM. |
| State record | `vmseed.json` in the control directory: what vmseed created, and the last verification. |
| Catalog | The versioned list of images with URL, digest and capabilities. |
| Control | One baseline item: ID, intent, implementation per distro, probe. |
| Probe | The executable check of a control, run inside the guest. |
| Knob | One of the few configuration keys that changes how a control is applied. |
| Recipe | A TOML file adding packages, files and commands after the baseline. Trusted code. |
| Distro primitive | A small strategy object (package manager, service manager, ...) a distro is composed of. |
| Report | The line protocol the guest writes with the result of every probe. |
| Baseline report | The report of boot 1, emitted before the upgrade and before any recipe. |
| Final report | The report of boot 2, after the upgrade, the recipes and a reboot. |
| Report channel | The second serial port, which carries only reports. |
| Managed VM | A VM created by vmseed. |
| Adopted VM | An existing VM declared with `managed = false`: listed and verifiable, never created or destroyed. |
| Operator tool | Whatever runs the VM day to day. |
| Host-check batch | A short script of commands the user runs on the real host at a milestone. |

## Decision index

| Topic | Decision | ADR |
|---|---|---|
| Repository | Same repo, `v2` branch, Bash tagged `v0-bash` | 0001 |
| Scope | Provisioning factory, not a VM manager; generic core plus a sandbox recipe | 0002 |
| Hypervisor | `virsh` plus self-generated domain XML; local connections only | 0003 |
| Integration | Documented conventions plus an exportable inventory; adopted VMs | 0004 |
| Other-user hypervisor | Compatible by design: control data private, data directory treated as hostile | 0005 |
| Configuration | One TOML fleet file with `[defaults]` | 0006 |
| Storage | Control and data directories per VM; independent disk; disposable cache | 0007 |
| SSH keys | Explicit `keygen`; `create` is non-interactive | 0008 |
| Hardening | Fixed, verifiable baseline of twenty-one controls | 0009 |
| Users | A list with roles `admin` and `standard`, pinned UIDs | 0010 |
| Firewall | nftables on every distro | 0011 |
| User content | Recipes: trusted code with guard rails | 0012 |
| Shares, removals | virtiofs, guest writes and host reads; Samba and fail2ban removed | 0013 |
| Updates | Upgrade during the first boot; automatic updates on by default | 0014 |
| Images | Pinned catalog; signatures verified at refresh; safety check on every use | 0015 |
| Firmware | UEFI by default; firmware is VM configuration; no vTPM | 0016 |
| Network | Kind is mandatory (bridge or passt); the address always comes from the configuration | 0017 |
| Verification | Two boots; reports over a dedicated serial channel | 0018 |
| Lockdown | Seed removed between the boots; cloud-init disabled | 0019 |
| Toolchain | Lean, established libraries; GitHub-only distribution for now; English | 0020 |
| Testing | Four tiers; real boots in CI; host checks at milestones | 0021 |
| Extensibility | Distro primitives by composition; self-contained controls | 0022 |
| Execution | Walking skeleton first; one PR per milestone; merges gated by the user; review pending | 0023 |

## Document map

| File | Content |
|---|---|
| `01-architecture.md` | Layers, modules, core types, extension points, invariants |
| `02-config.md` | The fleet file: every key, type, default and rule |
| `03-guest-baseline.md` | Distro primitives, the control catalog, limits, recipes in the guest |
| `04-host.md` | Directories, state record, domain XML, shares, seed, disk, `virsh` |
| `05-lifecycle.md` | Commands, the `create` steps, the report protocol |
| `06-images.md` | Catalog, cache, refresh tool |
| `07-integration.md` | The contract with operator tools |
| `08-testing.md` | Test tiers, CI, host-check batches |
| `09-milestones.md` | Milestones with acceptance criteria; session protocol |
| `10-assumptions.md` | What is verified, what is assumed, and the fallbacks |
| `STATUS.md` | Progress between sessions |
