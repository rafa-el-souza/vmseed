# 0010. Users as a list with roles

Status: accepted, 2026-11-20; revised 2026-11-21

## Context

v0 creates exactly two users, one standard and one admin, and keeps the
image's stock account alive while blocking it in sshd.

Images are not blank. The official Alpine cloud image ships an `alpine`
account in the admin group, with a rule that lets that group become root
without a password. Not asking cloud-init to configure an account does not
remove it.

## Decision

- A VM declares a list of users. Each has a role: `admin` or `standard`.
- `admin` gets passwordless privilege escalation through the distro's
  mechanism (`sudo` on Fedora, `doas` on Alpine). `standard` gets none.
- At least one admin is required.
- **Accounts and privilege rules the image ships are removed**, and the
  baseline checks that no other principal can escalate.
- UIDs are pinned in the configuration, so identities are the same on every
  VM and share ownership is deterministic.
- A user may not be put in a group that is equivalent to root; `role` is the
  only way to grant privilege.
- No user has a password. Escalation is passwordless because no password
  exists to satisfy a prompt.

## Consequences

- Covers the author's case (an agent as a standard user, a human as admin) and
  others, such as a single-user VM.
- An admin's SSH private key is equivalent to root on that VM. The
  documentation must state it.
- Console login is impossible; recovery of a broken VM is re-creation.
- Each distro must declare, as data, which accounts and rules its image ships
  and which groups are privileged.

## Alternatives

- **Two fixed users.** Simplest and enough today, but rigid.
- **A single admin user.** Minimal, but loses the privilege separation that is
  the point of the sandbox recipe.
