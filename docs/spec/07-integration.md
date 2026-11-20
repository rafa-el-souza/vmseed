# 07. Integration contract

vmseed creates and certifies VMs. Another tool operates them. This document is
the contract between the two. It is written for any operator tool: `virsh`,
virt-manager, or a script of the user's own.

## Boundary

| vmseed | Operator tool |
|---|---|
| Fetch and verify the image | Start and stop the VM |
| Render the seed, define the domain | Open a shell, a viewer, copy files |
| Two verified boots, host-key capture | Read a share, or expose it on the host |
| List what it created, export the inventory | Storage encryption, backups |
| Destroy what it created | Edit a domain or a network |

Each side works without the other. vmseed never calls the operator tool and
never needs it installed.

## Conventions vmseed guarantees

These are stable. Changing one is a breaking change and needs an ADR.

1. **Name.** A VM name matches `^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$` and is
   not all digits. It is the libvirt domain name and the guest hostname.
2. **Keys.** The default public key of user `U` on VM `V` is
   `~/.ssh/U-V.pub`; the private key is the same path without `.pub`.
3. **Host key.** The guest's host key is recorded in vmseed's own
   `known_hosts` file under the alias `vm-<name>`. A connection that passes
   `-o UserKnownHostsFile=<that file> -o HostKeyAlias=vm-<name>` needs no
   first-connection confirmation. The inventory gives the file's path.
4. **No listening console.** A domain has no graphics, or SPICE with
   `listen type='none'`.
5. **Address from the configuration.** A bridge VM has the declared static
   address from first boot. A passt VM is reached on the declared port on
   `127.0.0.1`. The MAC address is derived from the name and survives
   re-creation.
6. **Self-contained data directory.** Disk and NVRAM live in the VM's data
   directory. That directory plus the domain definition is a complete backup.
   After `create` succeeds, vmseed writes nothing more there until `destroy`.
7. **No seed dependency.** A delivered domain references no seed file.
8. **UIDs.** Guest users have the UIDs the configuration pins.

## Inventory

`vmseed list --json` prints schema version 1. Fields are only added within a
schema version; removing or changing one bumps it.

```json
{
  "schema": 1,
  "generated_by": "vmseed 1.0.0",
  "known_hosts": "/home/u/.local/share/vmseed/known_hosts",
  "vms": [
    {
      "name": "dev01",
      "managed": true,
      "status": "ready",
      "libvirt_uri": "qemu:///session",
      "uuid": "00000000-0000-4000-8000-000000000000",
      "distro": "fedora",
      "image": "fedora-44",
      "data_dir": "/srv/vms/dev01",
      "network": {
        "kind": "bridge",
        "bridge": "virbr0",
        "mac": "52:54:00:aa:bb:cc",
        "ipv4": "192.168.122.11"
      },
      "ssh": {
        "host": "192.168.122.11",
        "port": 22,
        "host_key_alias": "vm-dev01",
        "users": [
          { "name": "ops", "role": "admin",    "uid": 1000, "identity": "/home/u/.ssh/ops-dev01" },
          { "name": "dev", "role": "standard", "uid": 1001, "identity": "/home/u/.ssh/dev-dev01" }
        ]
      },
      "shares": [
        { "kind": "virtiofs", "source": "/srv/vms/shares/dev01",
          "mount": "/home/dev/projects", "readonly": false, "owner": "dev" }
      ],
      "verification": { "at": "2026-11-20T23:14:02Z", "ok": 21, "fail": 0, "na": 0, "skip": 0 }
    }
  ]
}
```

- For `passt`, `network` carries `ssh_port` and `forward`, and `ssh.host` is
  `127.0.0.1`.
- `identity` is `null` when the key was given inline.
- `uuid`, `data_dir` and `verification` are `null` for an `absent` or adopted
  VM.
- Adopted VMs appear with `managed: false` and the facts declared in the fleet
  file.

The inventory is built from the user's fleet file and from vmseed's private
state records, using typed and validated values only. Nothing in it is read
back from the hypervisor or reported by a guest. A consumer may treat it as
the user's own data.

## Optional shared lock

`host.lock_file` names a file. State-changing commands (`create`, `destroy`)
take a non-blocking exclusive `flock` on it before they change anything, and
before their own per-VM lock. They fail at once if it is held. Reading the
configuration and running preflight, which change nothing, happen first.

Pointing it at the operator tool's own lock makes the two tools mutually
exclusive, so that for example a backup or a storage shutdown cannot overlap a
`create`. vmseed holds the lock for the whole command, which for `create` is
minutes. Children do not inherit it.

## Adopted VMs

A VM that existed before vmseed v2 is declared with `managed = false` (see
02). It is listed, exported and verifiable. That lets one fleet file describe
every VM, so a consumer has a single source.

## Shares

A share is a host directory. The contract is the trust model in 03: the guest
writes, the host reads, and no guest identity is the invoking user. An
operator tool that exposes a share elsewhere on the host should keep that
property (for example by mounting it read-only and without following
symlinks). vmseed mounts nothing on the host.

## Other-user hypervisors

If VMs run under a hypervisor daemon owned by another, less trusted account,
the guarantees listed in 04 hold: per-VM URI, console and report through the
libvirt connection, control data out of that account's reach, a data directory
treated as hostile. Sharing the data directory's group between the two
accounts is the user's setup.

## What a hand-made VM needed, and what vmseed delivers

| Manual step with a hand-made VM | With vmseed v2 |
|---|---|
| Fill per-VM address and user tables in the operator tool | Generated from the inventory |
| Reserve an address for the VM in the network's DHCP server | `network.ipv4` in the fleet file |
| Remove the console's listening port from the domain | Domains are created without one |
| Compare the SSH host-key fingerprint on the console | Recorded automatically under `vm-<name>` |
| Keep a file-share password per VM | Gone: shares need no credential |

Changes on the operator-tool side (reading the inventory, passing
`UserKnownHostsFile`) are out of scope here.

## What vmseed never does

- Start, stop, pause or connect to a VM after `create`, except `verify`'s own
  SSH session and the power-off that `destroy --force` performs.
- Mount anything on the host.
- Change the owner or mode of a share source. It only adds the access entries
  described in 04, and shows them in the plan.
- Modify libvirt networks, storage pools or other domains.
- Write the user's own `~/.ssh/known_hosts`, or delete SSH keys.
- Call `sudo`.
