# 0004. Integration contract and adopted VMs

Status: accepted, 2026-11-20; revised 2026-11-21

## Context

vmseed and the operator tool that runs the author's VMs already depended on
each other through unwritten conventions: a key path per user and VM, a
host-key alias per VM, and address and user tables filled in by hand. Their
name rules differed. After creating a VM by hand the author had to reserve an
address, remove the console's listening port, and compare the SSH host-key
fingerprint on the console.

Existing VMs were made by v0 or by hand, so an inventory limited to VMs
created by v2 would be incomplete.

The user's `known_hosts` file is the trust store for every host they reach.
Writing guest-provided key material into it puts that whole store at risk if
the handling has a flaw.

## Decision

- vmseed documents **stable conventions** (`07-integration.md`): the name
  rule, default key paths, the `vm-<name>` alias, no listening console, an
  address that always comes from the configuration, a self-contained data
  directory, pinned UIDs.
- Host keys go to **vmseed's own `known_hosts` file**, never to the user's.
  Its path is configurable and exported. Connections pass
  `UserKnownHostsFile` and `HostKeyAlias`.
- A host-key line is built from validated fields: exactly one ed25519 key per
  VM, nothing copied verbatim from the guest.
- `vmseed list --json` exports an **inventory** with a versioned schema, built
  from typed values only.
- An optional external lock file lets vmseed share mutual exclusion with an
  operator tool.
- Existing VMs are **adopted** with `managed = false`: listed, exported and
  verifiable; never created or destroyed. To verify one, the user declares the
  host key they already trust.

## Consequences

- Each tool works without the other.
- The conventions and the inventory schema are compatibility surfaces;
  changing them is a breaking change.
- One fleet file can describe every VM.
- A flaw in vmseed's host-key handling cannot reach the trust of other hosts,
  and vmseed never competes with ssh's own edits.
- An operator tool must pass one more option (`UserKnownHostsFile`).
- Changes on the operator-tool side are out of scope for this project.

## Alternatives

- **Write the user's `~/.ssh/known_hosts`.** No extra option for consumers,
  but any flaw affects every host the user connects to, and stale or hashed
  entries, concurrent edits and symlinked files all become vmseed's problem.
- **A shared configuration file.** One source and no export step, but it
  couples both tools to one format.
- **libvirt as the only interface.** No coupling, but the manual tables and
  their drift remain.
- **Full import of existing domains.** Avoids re-creation, but trusts paths
  read from libvirt XML (see ADR 0005).
