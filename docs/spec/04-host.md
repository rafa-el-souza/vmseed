# 04. Host side

What vmseed creates on the host, and how it talks to the hypervisor.

## Two directories per VM

A VM has a **control directory**, private to the user, and a **data
directory**, used by the hypervisor (ADR 0007).

```
<state_dir>/vms/<name>/        control directory: 0700, files 0600
  vmseed.json                  state record (authoritative)
  domain.xml                   the XML that was defined (audit copy)
  seed/user-data               the cloud-config applied (audit copy)
  seed/meta-data
  seed/network-config          only for a static address
  console.log                  console output captured during create
  report.log                   raw report channel captured during create

<dir>/                         data directory
  disk.qcow2                   independent disk, at the declared size
  nvram.fd                     UEFI variable store (UEFI only; created by libvirt)
  seed.iso                     present only during the first boot

<state_dir>/locks/<name>.lock  per-VM lock (exists independently of the VM)
```

Why two: the hypervisor may run as another, less trusted account that must be
able to write the data directory. Everything vmseed trusts therefore lives
where only the user can write.

### Control directory

- Created `0700`; files `0600`.
- Only vmseed writes here.
- `console.log`, `report.log` and report evidence hold guest output. They are
  data from an untrusted source and may hold whatever a recipe printed.

### Data directory

- `create` makes it with an exclusive `mkdir`: it must not exist. Its parent
  must exist (except for the built-in default; see 02).
- Permissions follow `data_access`: `private` gives `0700` and files `0600`;
  `group` gives `2770` and files `0660`, the group being the parent
  directory's.
- The disk holds the guest's secrets (its SSH host private key, whatever the
  guest stores). Its mode is set when the file is created, not afterwards.
- vmseed creates and deletes exactly three names here: `disk.qcow2`,
  `nvram.fd` (deleted only), `seed.iso`.
- **Every operation here is defensive**, because another account may be able
  to write the directory:
  - open the directory once and work relative to that descriptor;
  - never follow a symlink in any path component;
  - create files exclusively; fail if the name exists;
  - delete by name relative to the descriptor.
- Backing up a VM means the data directory plus the domain definition. The
  state record is not in the data directory; a VM restored without it can be
  declared as adopted.

### Other-user hypervisors (ADR 0005)

What holds in v1 when qemu runs as another account:

- the libvirt URI is per VM;
- console and report are read through the libvirt connection;
- the state record, audit copies and logs are out of that account's reach;
- nothing in the data directory or read from libvirt decides a path, an
  address or a destructive action.

What the user must arrange: a parent directory whose group both accounts
share, and `data_access = "group"`. vmseed does not create accounts, change
ownership or set up the hypervisor.

What does not hold: an account that controls the hypervisor controls the VM.
It can read the seed and write on the VM's serial ports, so it can forge that
VM's reports. The rules above protect the user's own files and the other VMs.
They do not make a report from a compromised hypervisor trustworthy.

## State record

`vmseed.json`, schema version 1, in the control directory, written atomically.

```json
{
  "schema": 1,
  "name": "dev01",
  "uuid": "00000000-0000-4000-8000-000000000000",
  "libvirt_uri": "qemu:///session",
  "vmseed_version": "1.0.0",
  "created_at": "2026-11-20T23:10:00Z",
  "status": "ready",
  "image": { "id": "fedora-44", "digest": "sha256:0000" },
  "distro": "fedora",
  "config_digest": "sha256:0000",
  "data_dir": "/srv/vms/dev01",
  "nonce": "00000000000000000000000000000000",
  "host_key": "ssh-ed25519 AAAA",
  "endpoint": { "kind": "bridge", "host": "192.168.122.11", "port": 22 },
  "verification": {
    "at": "2026-11-20T23:14:02Z",
    "channel": "report",
    "summary": { "ok": 21, "fail": 0, "na": 0, "skip": 0 },
    "results": [{ "id": "SSH-01", "phase": "final", "status": "ok", "detail": "" }]
  }
}
```

- `status`: `provisioning`, `ready` or `failed`.
- `config_digest` is the digest of the VM's resolved configuration in a
  canonical form. `list` compares it with the current configuration to show
  drift.
- The record is validated strictly on load: unknown schema, unknown field,
  wrong type or a `name` that differs from the directory name is an error.
  vmseed never guesses.
- `endpoint` and `data_dir` are copies of what the configuration said at
  creation. They are typed values (an IP address, an integer port, a
  normalised absolute path).

## Domain definition

Built as an element tree (`host/domain.py`) from a typed `DomainSpec`. The
serialised XML is snapshot-tested and, in the contract tier, validated against
libvirt's schema.

Common to every VM:

| Element | Value |
|---|---|
| `<domain type>` | `kvm` |
| `<name>`, `<uuid>` | VM name; UUID generated by vmseed |
| `<title>`, `<description>` | State that the domain is managed by vmseed |
| `<metadata>` | One element in namespace `urn:vmseed:domain:1` with the VM name; a marker, never trusted as data |
| `<memory>`, `<vcpu>` | From configuration |
| `<os>` | `hvm`, `arch='x86_64'`, `machine='q35'` |
| `<features>` | `acpi`, `apic` |
| `<cpu>` | `host-passthrough` |
| `<clock>` | `utc` |
| Disk | `virtio`, `qcow2`, `discard='unmap'`, source `<dir>/disk.qcow2` |
| Seed | SATA CD-ROM, read-only, source `<dir>/seed.iso`; **first boot only** |
| Serial port 0 | `pty`; the console (`/dev/ttyS0` in the guest) |
| Serial port 1 | `pty`; the **report channel** (`/dev/ttyS1`), used only by the report script |
| RNG | `virtio`, backed by `/dev/urandom` |
| Graphics | none by default |

Firmware:

| Configuration | XML |
|---|---|
| `firmware = "bios"` | No firmware attribute (SeaBIOS) |
| `firmware = "uefi"` | `<os firmware='efi'>`, `<firmware>` feature `secure-boot` **explicitly** `no`, `<nvram>` pointing at `<dir>/nvram.fd` |
| `secure_boot = true` | Features `secure-boot` and `enrolled-keys` `yes`; `<smm state='on'/>` |

Secure Boot is declared off when not requested: firmware autoselection could
otherwise pick a build with enrolled keys, and an image without a signed boot
chain would not boot. libvirt keeps a user-supplied `<nvram>` path and fills in
only its format, which on Fedora is qcow2.

`graphics = "spice"` adds a SPICE display with `<listen type='none'/>` and a
virtio video device. There is never a listening console port.

### Network kinds

`bridge`:

```xml
<interface type='bridge'>
  <source bridge='virbr0'/>
  <mac address='52:54:00:xx:yy:zz'/>
  <model type='virtio'/>
</interface>
```

The seed carries a `network-config` in version 2 format, matching the
interface by MAC address, with the declared address, default route and name
servers.

`passt`:

```xml
<interface type='user'>
  <backend type='passt'/>
  <mac address='52:54:00:xx:yy:zz'/>
  <model type='virtio'/>
  <portForward proto='tcp' address='127.0.0.1'>
    <range start='2201' to='22'/>
  </portForward>
</interface>
```

Forwards always bind `127.0.0.1`. No `network-config` is written; the guest
uses DHCP from passt.

### Shares

The model is **the guest writes, the host reads** (ADR 0013): no guest
identity is the invoking user.

Without an explicit map, a session-mode libvirt maps guest root to the
invoking user and every other guest ID to the user's subordinate range. vmseed
therefore always writes an explicit `<idmap>` that sends **every** guest ID,
root included, into the subordinate range:

```xml
<memoryBacking>
  <source type='memfd'/>
  <access mode='shared'/>
</memoryBacking>
...
<filesystem type='mount' accessmode='passthrough'>
  <driver type='virtiofs'/>
  <source dir='/srv/vms/shares/dev01'/>
  <target dir='projects'/>
  <idmap>
    <uid start='0' target='SUBUID_BASE' count='SUBUID_COUNT'/>
    <gid start='0' target='SUBGID_BASE' count='SUBGID_COUNT'/>
  </idmap>
  <readonly/>            <!-- only when readonly = true -->
</filesystem>
```

- The range comes from the invoking user's entries in `/etc/subuid` and
  `/etc/subgid`. A user without entries cannot use shares; preflight says so.
- Guest UIDs are pinned in the configuration (02), so the host ID of each
  guest user is known when the plan is built.
- **Host preparation** for a writable share: `source` stays owned by the
  invoking user. vmseed adds an access control entry granting the mapped
  `owner` read, write and search, and a default entry so that the invoking
  user keeps access to what the guest creates. The plan shows these actions;
  `destroy` leaves them in place.
- A read-only share needs no preparation: the guest reads what the invoking
  user can already offer to others.

This mechanism is **not yet proven** on a real host. It is validated by a
host-check spike before the share kind is implemented (see 08 and
`10-assumptions.md`). If it does not work, the share model returns to the
user as a decision.

## Seed

A NoCloud ISO built in Python with `pycdlib`: volume label `CIDATA`, Joliet
and Rock Ridge extensions so that `user-data`, `meta-data` and
`network-config` keep their names. No host tool is needed.

`user-data` starts with `#cloud-config` and is serialised from a dictionary.
The ISO is built in the control directory and then placed in the data
directory with the safe creation rules above.

## Image safety check

A digest proves that the bytes are the expected ones. It does not prove that
they are safe to open: a qcow2 header can name a backing file or an external
data file, with a relative or absolute path, and `qemu-img convert` would then
copy that host file into the new disk.

Before an image is used, on every use:

1. Re-hash it against the catalog digest.
2. Inspect it with `qemu-img info`, forcing the format to `qcow2` (no format
   probing), with JSON output and under CPU and memory limits.
3. Refuse it unless the format is `qcow2` and it has no backing file and no
   external data file.

Contract tests use crafted fixtures of both kinds.

## Disk

1. Convert the checked base into the data directory, opening the source with
   its format forced to `qcow2` and its backing explicitly disabled.
2. Resize to the declared size.

- The destination is created exclusively and without following symlinks.
  Because `qemu-img` opens its output by path, vmseed opens the file itself
  and hands `qemu-img` that descriptor's path.
- The result has **no backing file**; this is asserted after conversion.
- The image's virtual size comes from the catalog (`virtual_size`). A `disk`
  smaller than it is a preflight error. For a user-defined image without that
  field, the check runs after the download.
- Growing the root filesystem at first boot is the image's own cloud-init
  behaviour.

## Talking to libvirt

Only through the `virsh` command, behind the `Hypervisor` protocol.

- Every call passes `--connect <uri>` and addresses the domain by **UUID**.
- Commands used: `version`, `domcapabilities`, `list --all --uuid --name`,
  `define`, `start --paused`, `resume`, `domstate`, `dumpxml --inactive`,
  `shutdown`, `destroy`, `undefine --keep-nvram`, `console --devname`.
- `LC_ALL=C` for stable output. Prefer machine-readable output where `virsh`
  offers it. Every call has a timeout.
- A failing call raises with virsh's own message. A failing list is never
  treated as an empty list.
- A domain whose name matches but whose UUID differs is foreign.
- `undefine` always keeps the NVRAM file; vmseed deletes `nvram.fd` itself, by
  name. libvirt is never asked to delete a path.

## Channel capture

During each boot of `create`, vmseed runs one `virsh console` per serial port,
each attached to a pseudo-terminal:

| Port | Guest device | Carries | Written to |
|---|---|---|---|
| serial 0 | `/dev/ttyS0` | kernel, boot and cloud-init output | `console.log` |
| serial 1 | `/dev/ttyS1` | only the report | `report.log`, and the parser |

- Sequence per boot: `start --paused`, attach both channels, `resume`. No
  early output is lost.
- The report has its own port so that kernel messages and boot output cannot
  land inside a record.
- Both channels are drained until the boot ends. A size cap limits what is
  written to a log file; it never stops the reading, which would stall the
  guest.
- No input is ever sent to the guest.
- Capture ends with `create`.

## Host keys

vmseed keeps its own `known_hosts` file (`host.known_hosts`), separate from
the user's. It is created `0600` in a `0700` directory, is never a symlink,
and is written only by vmseed, under one lock. Every change rewrites the whole
file atomically, so lines can neither merge nor be half-written.

One line per managed VM:

```
vm-<name> ssh-ed25519 <base64 key> vmseed:<uuid>
```

- `vm-<name>` is the alias operator tools use with `HostKeyAlias`.
- The trailing comment is the marker. `destroy` removes the line whose marker
  carries the VM's UUID.
- The line is **built from validated fields**. The report's host-key record
  must decode to exactly the key type `ssh-ed25519` and one base64 blob whose
  contents are a well-formed ed25519 public key. Anything else (a comment, a
  second key, a marker, a control byte) is a protocol error.
- Exactly one host-key record is accepted per report. The key in the final
  report must equal the key in the baseline report.
- `create` refuses, in its existence check, if the file already matches the
  alias (checked with `ssh-keygen -F`, which also sees hashed entries).

Connections must name the file: `-o UserKnownHostsFile=<file> -o
HostKeyAlias=vm-<name>`. The hand-off line, the `ssh-config` output and the
inventory all carry it.

The key travels over the report channel, which a network attacker cannot
reach. This replaces manual fingerprint comparison.

## Preflight

`create` and `doctor` share the same checks. All run before any side effect,
and all failures are reported together.

| Check | Source |
|---|---|
| `virsh`, `qemu-img`, `ssh-keygen` present | `PATH` |
| URI reachable | `virsh version` |
| KVM, UEFI, Secure Boot available | `domcapabilities` |
| `passt` installed (passt VMs) | `PATH` |
| `virtiofsd` installed (shares) | QEMU's vhost-user descriptors |
| Subordinate ID ranges exist; ACL tool present (shares) | `/etc/subuid`, `/etc/subgid`, `PATH` |
| Bridge exists; session mode: the bridge helper allows it | `/sys/class/net`, the helper's ACL file when readable |
| passt host ports free | bind test on `127.0.0.1` |
| Share sources valid | filesystem |
| Public keys exist and parse | filesystem |
| Data directory parent exists and is writable; the directory itself does not exist | filesystem |
| Image supports the firmware and Secure Boot requested | catalog |
| `disk` not smaller than the image's virtual size | catalog |
| Enough free space for the image and the disk | filesystem |

`domcapabilities` only reports what QEMU can do. It does not tell whether the
`passt` or `virtiofsd` programs are installed, hence the explicit checks.

Each failure names the fix. Whether the VM already exists is **not** a
preflight check: it is decided after the locks are taken and exits 5 (see 05).
