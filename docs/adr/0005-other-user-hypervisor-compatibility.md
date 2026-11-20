# 0005. Compatible with a hypervisor run by another user

Status: accepted, 2026-11-20; revised 2026-11-21

## Context

The author is considering running VMs under a dedicated, less trusted host
account, with its own libvirt daemon and URI. That plan is not settled and has
no code. If it goes ahead, qemu no longer runs as the invoking user, and
neither the daemon's answers nor the directories that account can write are
trustworthy.

The first version of this record claimed compatibility while keeping vmseed's
state record in the directory that account must write. A design review showed
that the account could then rewrite the record `destroy` trusts, or plant
symlinks where vmseed writes. The claim did not hold.

## Decision

Do nothing specific to that setup, but make these rules hold from the start:

1. The libvirt URI is per VM, restricted to local connections (ADR 0003).
2. **Control data is private.** The state record, audit copies and logs live
   in a control directory only the invoking user can write (ADR 0007).
3. **The data directory is treated as hostile.** vmseed creates and deletes
   only fixed names there, through a directory descriptor, without following
   symlinks, with exclusive creation.
4. Console and report are read through the libvirt connection, never from a
   file a hypervisor daemon writes.
5. Nothing read from libvirt or from the data directory chooses a path, an
   address or a destructive action.
6. Access for a second account is an explicit setting (`data_access =
   "group"`), never a side effect of the umask.

Creating accounts, changing ownership and setting up the daemon remain the
user's work.

## Consequences

- The compatibility claim is now true for what vmseed controls: the user's own
  files and the other VMs are protected from that account.
- It does not extend to the truth of a report. An account that controls the
  hypervisor controls the VM and can forge that VM's reports.
- Each VM has two locations instead of one.
- A backup of the data directory does not include vmseed's record; a VM
  restored without it can be declared as adopted.
- The defensive file handling is one code path, used in every setup, and is
  covered by contract tests with planted symlinks.
- No e2e scenario runs against another account's daemon yet; that is an open
  question.

## Alternatives

- **Ignore it.** Simpler now; permissions, state and `destroy` would need
  rework later.
- **One directory, and a narrower claim.** Simplest today, but separating
  later would be a breaking change.
- **First-class support now.** Managing owners, ACLs and socket URIs would be
  specified on ground that may still move.
