# 0007. Control and data directories, independent disk

Status: accepted, 2026-11-20; revised 2026-11-21

## Context

v0 requires two directories with no default, spreads a VM's files across
them, and boots from a qcow2 overlay that depends forever on a base image
elsewhere. The disk is never resized. The author keeps disks and NVRAM on
encrypted storage and backs it up.

The first version of this record put everything, including vmseed's state
record, in one directory per VM with permissions left to the umask. A design
review found two problems: the disk holds the guest's secrets, and a
hypervisor running as another account must write that directory, which would
let it tamper with the record `destroy` trusts (ADR 0005).

## Decision

- Each VM has **two directories**:
  - a **control directory**, private to the user (`0700`), under a
    configurable state directory: state record, audit copies, logs;
  - a **data directory**, configurable per VM: only the disk and the NVRAM
    (and the seed during the first boot).
- Locks live under the state directory, independent of any VM.
- Every path has a default and can be changed: the state directory, the cache
  directory, the data directory, the `known_hosts` file.
- Permissions are explicit and set at creation: data directory `0700` and
  files `0600` by default; a `group` setting opens it to a shared group.
- `create` claims the data directory with an exclusive `mkdir`. It never
  writes into a directory that already exists.
- The disk is an **independent** qcow2: converted from the checked base, then
  resized to the declared size. No backing file.
- The image cache is separate, content-addressed and disposable.

## Consequences

- Backing up or removing a VM's data is one directory, and the cache can be
  deleted at any time.
- What vmseed trusts is out of reach of anything but the user.
- A VM has two locations; `destroy` cleans both.
- vmseed's record is not part of a storage backup. A VM restored without it is
  declared as adopted.
- Creation costs a few seconds and a few hundred megabytes more per VM.
- First use works without configuring directories.

## Alternatives

- **One directory holding everything.** Simplest to explain, but the trusted
  record sits where another account may write, and a typo in `dir` could
  overwrite another VM's disk.
- **One directory with an optional separate state directory.** Two code paths
  in the part of the tool that deletes files.
- **Overlay on the base.** Instant and compact, but every VM depends on a file
  outside its directory and backups are incomplete.
- **Required directories, no default**, or **a `.vmseed/` directory beside the
  configuration.** Friction on first use, or wrong for dedicated storage.
