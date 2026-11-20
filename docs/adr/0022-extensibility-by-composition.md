# 0022. Extensibility by composition

Status: accepted, 2026-11-20; revised 2026-11-21

## Context

The user wants adding distros, and other things, to be easy. Controls and
distros form a matrix: each control must work on each distro.

- One class per distro with one method per control makes a new distro easy and
  a new control touch every class.
- One function per control switching on the distro does the opposite.

Distros rarely differ in what a control intends. They differ in a few
primitives: installing a package, enabling a service, granting admin rights,
scheduling updates.

Controls also share artifacts: seven SSH controls write one sshd drop-in,
three write one sysctl file, three shape the same user entries.

## Decision

- A **distro is a composition of primitives** (package manager, service
  manager, accounts, privilege, SSH server, firewall layout, resolver,
  updates, MAC, crypto policy, sysctl). Primitives are small protocols that
  return data. A distro also declares facts as data: accounts its image ships,
  privileged groups, sysctl keys its kernel has.
- Each **control is written once** against the primitives, in one module that
  holds its application, its probe and its documentation. No control branches
  on the distro identifier. A missing capability is `None`, and the control
  reports `n/a`.
- A control contributes **typed fragments** (an sshd directive, a sysctl
  entry, a user attribute, a firewall rule, a file, a step). The assembler
  merges fragments of a kind into their single artifact. A collision is two
  controls setting the same directive, key or attribute.
- **Network and share kinds** are selected by a `kind` field and implemented
  by a small behaviour object each.
- **Registries are explicit** tuples in the code.
- A **conformance suite** runs every control against every registered distro.
- First-class extension points in v1: distros, controls, network and share
  kinds. The hypervisor has only a thin protocol for testing.

## Consequences

- A new distro is mostly a declaration, plus any primitive that does not exist
  yet. A new control is one module.
- Controls stay one per module even though they share files.
- The conformance suite tells a contributor what is missing.
- A little more structure than two distros strictly need. Alpine differs from
  Fedora on every primitive, which is what makes the abstraction real.

## Alternatives

- **One class per distro.** Everything about a distro in one file, but a new
  control edits every class and similar distros duplicate code or grow
  inheritance trees.
- **Distros as data files.** No Python to add a distro, but real differences
  are not only names; the format grows conditionals without type checking.
- **External plugins through entry points.** Most open, but a public API
  frozen from v1 and third-party code loaded into a provisioning tool. Can be
  layered on this design later.
- **A hypervisor extension point.** An abstraction designed around a single
  real implementation usually has the wrong shape.
- **One file per control, no sharing.** Simple to merge, but seven sshd
  drop-ins and three sysctl files where one of each is clearer.
