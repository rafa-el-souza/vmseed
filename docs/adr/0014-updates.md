# 0014. Updates during the first boot and automatically

Status: accepted, 2026-11-20; revised 2026-11-21

## Context

v0 upgrades every package at first boot and never again. A VM that lives for
months ages silently.

A design review added three facts. An upgraded kernel is not the running
kernel until a reboot. On Alpine an upgrade removes the running kernel's
modules, so anything that needs a module afterwards fails. And Fedora's
automatic-update tool only downloads by default: enabling its timer is not
enough.

## Decision

- Upgrade every package during the first boot (control UPD-01), **after** the
  firewall is loaded and shares are mounted, and after the baseline report.
- `create` then boots the VM a second time (ADR 0018), so the delivered VM
  runs the upgraded kernel.
- Enable the distro's automatic update mechanism by default (control UPD-02),
  configured to **apply** updates. No automatic reboot.
- UPD-02's probe checks the effective configuration and that a successful run
  is recent, not only that a timer exists.
- Two knobs, `updates.first_boot` and `updates.automatic`, disable each part.
  A disabled part is reported as `skip`, never as `ok`.

## Consequences

- "Secure by default" holds for long-lived VMs, from a current kernel on day
  one.
- An update can change something the user did not ask for. Later kernel
  updates wait for a reboot the user chooses.
- The knobs make ephemeral VMs and fast e2e runs possible, visibly.
- A pinned catalog image may be old; the first-boot upgrade compensates
  (see ADR 0015).
- One Alpine e2e scenario runs with the upgrade on at every pull request,
  because that is where this is most likely to break.

## Alternatives

- **Automatic updates off by default.** Nothing changes unasked, but the
  default returns to a VM that ages.
- **First boot only.** Simplest and predictable; keeping current is manual.
- **Upgrade first, then the baseline.** The order v0 used. It leaves the
  firewall down for the whole upgrade and breaks on Alpine when the kernel
  changes.
