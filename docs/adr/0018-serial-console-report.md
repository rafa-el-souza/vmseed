# 0018. Two boots, reports over a dedicated serial channel

Status: accepted, 2026-11-20; revised 2026-11-21

## Context

v0 returns as soon as the domain starts. "Booted" is not "provisioned".
`create` must learn when provisioning ended and whether every control holds,
without becoming interactive (ADR 0008) and whatever the network kind
(ADR 0017).

The first version of this record used one report at the end of the first boot,
on the console. A design review found four weaknesses:

- a recipe command runs as root before that report and could falsify it;
- after the upgrade the VM still runs the old kernel;
- some state only changes at the first reboot (Fedora creates more host keys
  once cloud-init is gone), so a first-boot report cannot see it;
- the console is shared with kernel and boot output, which can land inside a
  record.

## Decision

- `create` boots the VM **twice**.
  - Boot 1: baseline, then the **baseline report**, then the upgrade and the
    recipes, then power off.
  - The host removes the seed and starts the VM again.
  - Boot 2: the **final report**, on the upgraded kernel, without cloud-init.
  - The VM is ready only if both reports are complete and clean.
- Reports travel on a **dedicated second serial port**, read through
  `virsh console`. The first port keeps the ordinary console output, captured
  as a log.
- The protocol is line-based, versioned, with a per-run nonce, a phase, and a
  checksum per record. The guest sends each report twice; conflicting records
  are an error. The guest only ever says `ok` or `fail`; `n/a` and `skip` come
  from the plan.
- The guest's host key is carried in both reports and must be the same in
  both.
- A later `verify` renders the report script again from the current
  configuration and runs it over SSH as an admin user, with a hardened command
  line that ignores the user's ssh configuration.

## Consequences

- The baseline's proof does not depend on recipe code.
- The delivered VM runs its upgraded kernel, has no seed device, and has shown
  that the baseline survives a reboot.
- Works with any network kind. Needs no private key, passphrase, agent or
  extra guest package.
- `create` takes one more boot, and each distro needs a "run once at next
  boot" primitive.
- The host key arrives over a channel a network attacker cannot reach.
- Reading through the libvirt connection keeps ADR 0005.
- A report is still self-description by the guest, and guest root can read the
  nonce. It detects errors and drift, not a guest that lies.

## Alternatives

- **One boot, one report.** Faster and simpler, with the four weaknesses
  above.
- **One boot and a "reboot required" notice.** Fixes the ordering problems
  but not the others.
- **Everything over SSH.** One channel, but `create` would need a reachable
  network and a usable private key at that moment.
- **The QEMU guest agent.** Independent of network and keys, but adds a
  package and a host-to-guest execution channel to every VM, and on Fedora
  command execution through the agent is blocked by default.
- **Reports on the console port.** One port less, but kernel output can damage
  a record.
