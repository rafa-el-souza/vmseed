# 0013. virtiofs shares; Samba and fail2ban removed

Status: accepted, 2026-11-20; revised 2026-11-21. **The share mechanism is
unproven** until host-check batch 2 passes.

## Context

v0 exports the standard user's `~/projects` over Samba. That one feature
brings a plaintext password in the seed, an SELinux label, a firewall rule,
network prerequisites and a custom fail2ban filter: the largest source of
coupling in the tool. Its own README says virtiofs would be better.

fail2ban is optional and off by default in v0. With key-only SSH it cannot
prevent anything a password guess could achieve; it reduces log noise. It
needs a different backend per distro, and a mis-set ignore list once banned
the author's host from a VM.

In session mode, libvirt's default for virtiofs maps guest root to the
invoking user and every other guest ID to the user's subordinate range. Left
as is, guest root would write files as the user on the host, and an
unprivileged guest user could not write the share at all. A share is also a
channel through which an untrusted guest hands code to the host.

## Decision

- **Shares:** optional virtiofs per VM, under one model: **the guest writes,
  the host reads**.
  - vmseed writes an explicit ID map that sends every guest ID, root
    included, into the user's subordinate range. No guest identity is the
    invoking user.
  - Guest UIDs are pinned in the configuration, so ownership is deterministic.
  - For a writable share, vmseed grants the mapped guest owner access to the
    source directory with an access control entry, shown in the plan. It never
    changes the directory's owner or mode.
  - `readonly` must be stated. A read-only share is how files are sent in.
  - The guest mounts shares `nosuid,nodev`.
  - `source` and `mount` are validated against sensitive locations.
  - The trust model is documented: read and copy out; treat what is there as
    untrusted code.
- **Samba is removed.**
- **fail2ban is removed.** Restricting who reaches SSH is done with
  `ssh.allow_from` in the firewall.
- The knowledge stays readable in the `v0-bash` tag.

## Consequences

- No network, password or server is needed to share files, and the seed
  carries no secret.
- Files the guest writes are not the user's on the host. Tools such as git
  refuse to operate on them, which is the intended protection. The user cannot
  edit them in place.
- Needs `virtiofsd`, subordinate ID ranges and an ACL tool on the host.
- The ID map and the access-entry preparation have not been run on a real
  host. A spike in host-check batch 2 validates them before the share kind is
  implemented. If it fails, the share model returns to the user.
- One implementation of each removed feature per distro is avoided.

## Alternatives

- **A shared working tree**, mapping the share's guest owner to the invoking
  user. Convenient, as the old Samba mount was, but anything in the guest that
  becomes that user or root then writes files as the user on the host, and git
  does not warn.
- **libvirt's default mapping.** Works out of the box, but guest root writes
  as the user.
- **No shares in v1**, until the host test is done. Smaller, but the author's
  main use has no way to get work out except `scp`.
- **Keep Samba as an option.** Works today, but keeps the coupling and the
  secret and needs an Alpine implementation.
- **fail2ban optional on both distros, or on Fedora only.** Defence in depth,
  at the cost of two implementations, or of an asymmetry between distros.
