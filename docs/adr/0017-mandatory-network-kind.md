# 0017. The network kind is mandatory

Status: accepted, 2026-11-20; revised 2026-11-21

## Context

v0 defaults to QEMU user-mode networking, which creates a VM nobody can SSH
into. The author runs VMs on a bridge today, with an address reserved by hand,
and plans to move some to passt later.

passt needs no root and gives each VM its own layer-2 segment. But it maps the
guest's gateway to the host's loopback: the guest can reach services bound to
the host's `127.0.0.1`, which includes the forwarded ports of every other
passt VM. libvirt has no option to turn that off (confirmed in the libvirt
reference and measured by the author). The mitigation is a host firewall rule
keyed on a dedicated user, outside vmseed's reach.

Where the host connects must not be decided by a guest. An address learned
from DHCP could only come from the guest or the hypervisor.

## Decision

- Two kinds per VM: `bridge` and `passt`.
- **No built-in default.** A configuration without a network kind is an error
  that explains both kinds and their risks. The quickstart example uses passt
  and documents its limits.
- **The endpoint always comes from the configuration.** A bridge VM requires a
  static IPv4 address, applied inside the guest through cloud-init's network
  configuration. A passt VM requires its forwarded SSH port.
- The MAC address is derived from the VM name.
- SSH is reachable from any source on the VM's network by default;
  `ssh.allow_from` restricts it explicitly.
- The known limits of both kinds are part of the security model
  (`03-guest-baseline.md`, "Network limits").

## Consequences

- Network topology, a security decision, is never guessed.
- `verify`, the hand-off line and the inventory never depend on anything a
  guest reports.
- One more line of configuration, usually once in `[defaults]`, and an address
  to choose per bridge VM, outside the network's DHCP range.
- The static address is self-contained: no second libvirt connection, no
  shared host state to undo at `destroy`, any bridge works.
- SSH is open by default because passwords are locked: a wrong allow-list
  after moving a VM to another bridge would leave it unreachable even from the
  console.

## Alternatives

- **passt as the default.** Works anywhere, but silently exposes the host's
  loopback services to the guest.
- **bridge as the default.** Matches the author's fleet, but needs a one-time
  root setup, so the example fails for a newcomer.
- **DHCP on a bridge.** Convenient, but the address would have to be learned
  from the guest or the hypervisor.
- **A DHCP reservation in the libvirt network.** The network knows the
  address, but it needs a second, privileged connection and leaves state to
  clean.
