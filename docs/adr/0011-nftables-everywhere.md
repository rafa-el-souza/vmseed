# 0011. nftables on every distro

Status: accepted, 2026-11-20; revised 2026-11-21

## Context

Fedora Cloud Base enables no packet filter. v0 installs firewalld and stages
rich rules offline before starting it, because `firewall-cmd --permanent`
needs the running daemon. Alpine does not use firewalld.

## Decision

- vmseed generates **one nftables table**, identical on every distro: inbound
  denied by default; SSH allowed from anywhere or from a declared list;
  declared extra ports.
- Only an `input` chain. No `forward` or `output` chain.
- Loading replaces vmseed's own table atomically and touches no other table.
- The distro's stock ruleset file is replaced by one that loads only this
  table, and the distro's nftables service loads it at boot.
- The firewall is among the first baseline steps, before the upgrade.

## Consequences

- One policy, one implementation, one check on every distro.
- Loading is atomic; there is no daemon and no offline staging.
- On Fedora the distro's usual tool (`firewall-cmd`) is not used.
- Tables a container engine creates survive a reload.
- No `forward` chain: the VM is not a router, and a dropping one would break
  container engines a recipe may install. The cost is a documented limit:
  ports published by a container engine are not covered by this table.
- Outbound traffic is not filtered. Limiting it is a possible later decision.

## Alternatives

- **The native tool of each distro.** Idiomatic, but two implementations of
  one policy, with twice the tests and room for the semantics to diverge.
- **firewalld on both.** One tool, but it pulls D-Bus and Python into a 158 MB
  image.
- **Flushing the whole ruleset on load.** Guarantees nothing else is loaded,
  but destroys what container engines installed.
