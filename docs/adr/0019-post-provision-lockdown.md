# 0019. Lockdown between the two boots

Status: accepted, 2026-11-20; revised 2026-11-21

## Context

In v0 the seed ISO stays attached forever: if the file disappears the VM does
not start. cloud-init runs at every boot and would re-apply a changed seed if
the instance identifier changed.

## Decision

- At the end of the first boot the guest disables cloud-init (control CIN-01)
  and powers off.
- Before the second boot, vmseed redefines the domain without the seed device
  and deletes the ISO.
- The second boot therefore runs exactly as the VM will run from then on, and
  its report confirms that hostname, network, users and keys persisted.
- The applied `user-data`, `meta-data` and `network-config` stay in the
  control directory as text, for audit.

## Consequences

- The VM is its disk and NVRAM. Nothing is re-applied later, and a swapped
  seed cannot reconfigure the machine.
- A delivered VM never has the seed attached, not even in its running
  instance.
- Persistence without cloud-init is checked on every VM, not assumed.
- It matches the factory role (ADR 0002): to change a VM, re-create it.
- Growing the disk later requires resizing the partition by hand in the guest.

## Alternatives

- **Keep the seed attached and cloud-init active.** Keeps automatic partition
  growth, but the seed file becomes a permanent dependency.
- **Detach the seed only.** Removes the file dependency, but cloud-init
  without a data source behaves differently per distro at later boots.
- **Detach after a single boot.** The running instance keeps the device until
  its next cold start, and nothing shows the VM survives that restart.
