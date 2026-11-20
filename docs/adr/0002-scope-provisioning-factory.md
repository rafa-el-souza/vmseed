# 0002. Scope: a provisioning factory, not a VM manager

Status: accepted, 2026-11-20

## Context

v0 downloads, seeds, boots and exits. It does not know whether provisioning
succeeded and cannot list or remove what it created.

The author already operates VMs with a separate tool of their own: start,
stop, shell, viewer, copy, storage, backups. That tool never creates or removes
a VM. A "full lifecycle" vmseed would have duplicated `start`, `stop`, `ssh`
and `list`, with weaker knowledge of the host.

The author's real use is an isolated development VM where a coding agent runs
as an unprivileged user.

## Decision

- vmseed is the **factory**: `create`, `verify`, `list`, `destroy`, `render`,
  plus the supporting `keygen`, `images`, `controls`, `doctor` and `config`.
- No `start`, `stop`, `ssh`, console or `recreate`. After `create`, the VM
  belongs to the operator's tools.
- The core is generic. The developer sandbox is an example recipe under
  `examples/`, not a product identity.

## Consequences

- No overlap with operator tools; a clear story: provisioner, not manager.
- `verify` and `destroy` fill gaps that neither tool covered.
- Someone using only vmseed logs in with the `ssh` line it prints, and stops
  the VM with `virsh`.
- "Change a VM" means destroy and create.

## Alternatives

- **Factory plus thin `start`, `stop`, `ssh`.** Friendlier alone, but three
  duplicated commands with different trust rules, and a path to becoming a
  manager.
- **Absorb VM operations into vmseed.** One tool, but the scope more than
  doubles and personal desktop pieces enter the portfolio tool.
- **A seed generator only.** Minimal, but drops verified download and boot.
- **A product for AI-agent sandboxes.** Distinctive, but ties identity and
  defaults to one use.
