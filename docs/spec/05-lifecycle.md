# 05. Lifecycle and commands

## Command set

```
vmseed create  NAME [--timeout DURATION] [--cleanup-on-failure] [--keep-running] [--shutdown]
vmseed verify  NAME [--user USER] [--identity PATH] [--batch] [--json]
vmseed list    [--json | --format ssh-config]
vmseed destroy NAME [--force] [--yes]
vmseed render  NAME [--what ARTIFACT] [--output DIR]
vmseed keygen  NAME [--user USER]
vmseed images  [list | fetch IMAGE | prune]
vmseed controls [--json | --markdown]
vmseed doctor  [NAME]
vmseed config  check | show NAME | schema
```

Global options: `--config PATH`, `--verbose`, `--quiet`, `--no-color`,
`--version`.

There is deliberately no `start`, `stop`, `ssh`, `console` or `recreate`
(ADR 0002). To change a VM: `destroy`, then `create`.

Exit codes are defined in 01. Results go to stdout, progress to stderr. Every
string that originates in a guest or in a tool's output is sanitised before it
is shown (01, "Untrusted text").

## `create`

Non-interactive. Never prompts. Boots the VM twice and leaves it **running**
and verified.

### Steps

| # | Step | On failure |
|---|---|---|
| 1 | Load and validate the fleet file; resolve the VM | exit 2 |
| 2 | Preflight (see 04) | exit 2, nothing changed |
| 3 | Take the external lock (if configured), then the VM lock | exit 5 if held |
| 4 | Existence check: no state record, no same-named domain, no data directory, no `known_hosts` entry for the alias | exit 5 |
| 5 | Ensure the image is in the cache: download, digest, safety check | exit 1 |
| 6 | Create the control directory; write the state record, `status = provisioning` | exit 1 |
| 7 | Create the data directory (exclusive); prepare writable shares | exit 1 |
| 8 | Create the disk (convert, resize) | exit 1 |
| 9 | Render the seed; write the audit copies; build and place `seed.iso` | exit 1 |
| 10 | Render the domain XML with the seed; write the audit copy; `define` | exit 1 |
| 11 | **Boot 1**: `start --paused`, attach both channels, `resume` | exit 1 |
| 12 | Wait for the baseline report **and** for the guest to power off | exit 4 |
| 13 | Evaluate the baseline report | exit 3, or 1 for a protocol error |
| 14 | Redefine the domain without the seed; delete `seed.iso` | exit 1 |
| 15 | **Boot 2**: `start --paused`, attach both channels, `resume` | exit 1 |
| 16 | Wait for the final report | exit 4 |
| 17 | Evaluate the final report; its host key must equal the baseline's | exit 3, or 1 for a protocol error |
| 18 | Record the host key; `status = ready`; print the hand-off summary | exit 0 |

Rules:

- **The existence check runs under the locks** and exits 5. Running `create`
  twice therefore exits 5 the second time, never 2.
- **A VM that failed is not left running.** On any failure from step 11 on,
  vmseed powers the domain off, sets `status = failed` and keeps the files for
  inspection. Inspection needs the logs and the disk, not a live guest that is
  only partly hardened. `--keep-running` opts out; `--cleanup-on-failure` runs
  `destroy` instead.
- A VM whose boot timed out never has its host key recorded. Error messages
  never suggest accepting a host key by hand.
- Interrupting (`Ctrl-C`) powers the domain off, releases the locks and leaves
  `status = provisioning`. `destroy` cleans it.
- `--timeout` bounds the whole command. Default: 30 minutes. A full upgrade on
  first boot can be slow; see `10-assumptions.md`.
- `--shutdown` requests a graceful shutdown after step 18 and waits for it.
- If the guest powers off before a complete baseline report arrives, or stops
  during boot 2, the boot failed: exit 4, with the sanitised tail of
  `console.log` and its path.

After step 18 the running instance has no seed device, runs the upgraded
kernel, and has proven that the baseline survives a reboot.

### Hand-off summary

Printed on success: the endpoint, a ready-to-run `ssh` line per user, the
verification summary, and both directories.

```
dev01 is ready (21 ok)

  ssh -o UserKnownHostsFile=~/.local/share/vmseed/known_hosts \
      -o HostKeyAlias=vm-dev01 -o IdentitiesOnly=yes -a -x \
      -i ~/.ssh/ops-dev01 ops@192.168.122.11

  shorter: vmseed list --format ssh-config

  data:    /srv/vms/dev01
  control: ~/.local/state/vmseed/vms/dev01
```

`IdentitiesOnly` matters: the baseline allows three authentication attempts,
and an agent holding several keys would otherwise exhaust them.

## Report protocol

Version 1. The guest writes one record per line to the report channel. Every
record starts with a fixed prefix and ends with a checksum.

```
VMSEED:1:<nonce>:<phase>:BEGIN:<vm name>:<crc>
VMSEED:1:<nonce>:<phase>:HOSTKEY:<base64 of the host public key line>:<crc>
VMSEED:1:<nonce>:<phase>:CONTROL:<id>:<result>:<base64 of the evidence>:<crc>
VMSEED:1:<nonce>:<phase>:END:<number of CONTROL records>:<crc>
```

- `phase`: `baseline` (boot 1), `final` (boot 2) or `verify`.
- `result`: `ok` or `fail`. Nothing else. `n/a` and `skip` are never sent by a
  guest; the host fills them in from the plan.
- `crc`: CRC-32 of the record's text before the last colon, as 8 hex digits.
- Evidence is UTF-8 text, truncated by the emitter to 512 bytes before
  encoding. A record never exceeds 1024 bytes.
- `HOSTKEY` appears exactly once in `baseline` and in `final`, never in
  `verify`.

### The nonce

32 hex characters, generated per `create` and per `verify` run.

It tells this run's records apart from stale output and from anything written
by guest code that cannot read it, which is all non-root code: cloud-init keeps
the user-data root-only, and vmseed keeps the nonce out of command lines,
environments, world-readable files and trace logs (03).

It is **not** a defence against guest root. Root can read it and write to the
channel.

### Emitter (guest)

- Writes to `/dev/ttyS1` during `create`, to stdout under `verify`.
- One `write` per record.
- Emits the whole report **twice** in a row, so that one damaged line does not
  fail a run.
- Emits exactly one `CONTROL` record per probe that runs, in registry order. A
  probe that crashes produces `fail` with the error as evidence.

### Parser (host)

Per phase, the plan lists the controls expected to report and, for the others,
the status the host assigns (`na` or `skip`).

- A line is a record only if it contains the exact prefix
  `VMSEED:1:<nonce>:<phase>:`, matches the grammar, and its checksum is
  correct. Any other line is counted and ignored.
- A report is **complete** when `BEGIN`, the required `HOSTKEY`, one `CONTROL`
  for every expected control and an `END` with the matching count have each
  been seen at least once.
- It is a **protocol error** if a valid record names a control the plan does
  not expect in this phase, if two valid copies of a record differ, or if a
  second, different `HOSTKEY` appears.
- The parser keeps reading until the boot ends, so a conflicting record that
  arrives after the report was complete is still caught.
- The `HOSTKEY` payload is validated as described in 04 before anything is
  done with it.
- A protocol error fails the command with exit 1 and points at `report.log`.

### What a report proves

See 03, "What the proof is worth". In short: the baseline report does not
depend on recipe code; the final report and `verify` detect errors and drift,
not a guest that lies.

## `verify`

Re-runs every probe on a running VM and updates the state record.

1. Resolve the VM. Works for managed and adopted VMs.
2. Render the report script from the **current** configuration with a fresh
   nonce, phase `verify`.
3. Run it through SSH as an admin user, elevated with the distro's primitive:

   ```
   ssh -F none
       -o IdentitiesOnly=yes -o PreferredAuthentications=publickey
       -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no
       -o StrictHostKeyChecking=yes -o UpdateHostKeys=no
       -o UserKnownHostsFile=<file> -o GlobalKnownHostsFile=/dev/null
       -o HostKeyAlias=vm-<name>
       -o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes
       -o PermitLocalCommand=no -o ControlMaster=no -o ControlPath=none
       -i <identity> -p <port> <admin>@<host>  <elevate> sh -s   < script
   ```

4. Parse the report; print a table; store the result with `channel = "ssh"`.

- `-F none` keeps the user's ssh configuration out: no agent forwarding, no
  connection reuse, no proxy or local command, no prompt in the guest's words.
- The endpoint comes from the configuration, never from the guest.
- Admin user: the first `admin` in the configuration, or `--user`.
- Identity: the user's first key path without `.pub`, or `--identity`.
- ssh may ask for a key passphrase on the terminal. `--batch` adds
  `BatchMode=yes` for automation.
- Managed VM: `<file>` is vmseed's `known_hosts`. Strict checking against the
  recorded key makes host-key continuity part of every verification.
- Adopted VM: `<file>` is a temporary file holding the declared `host_key`.
  Without `host_key`, `verify` refuses.
- Exit 0 if no control failed, 3 otherwise.
- For an adopted VM, failing controls are expected: the output measures the
  divergence from the baseline.

Output:

```
ACC-01  only declared accounts exist            ok
SSH-06  modern algorithms only                  ok
NET-02  only declared TCP ports listening       FAIL
        expected: 22   found: 22, 8080
MAC-01  mandatory access control enforcing      n/a   no MAC on alpine
UPD-02  automatic updates enabled               skip  updates.automatic = false

21 controls: 18 ok, 1 fail, 1 n/a, 1 skip
```

## `list`

Shows every declared VM and every state record found that is no longer
declared.

| Column | Values |
|---|---|
| `NAME` | |
| `STATUS` | `absent` (declared, not created), `provisioning`, `ready`, `failed`, `adopted`, `orphan` (state record without a declaration) |
| `DOMAIN` | libvirt state by UUID: `running`, `shut off`, `missing`, `unknown` (libvirt unreachable). Informational. |
| `IMAGE` | |
| `ENDPOINT` | address and port, from the configuration |
| `VERIFIED` | date and counts of the last verification |
| `DRIFT` | `config changed` when the stored `config_digest` differs |

`--json` prints the inventory, a stable contract specified in 07.
`--format ssh-config` prints OpenSSH `Host` blocks carrying the same options as
the hand-off line. Both are built only from typed, validated values: an IP
address, an integer port, validated names, normalised paths free of control
characters.

## `destroy`

Removes a managed VM and everything vmseed created for it.

1. Load the state record strictly. No record: exit 5 ("not managed by
   vmseed"). An adopted VM: exit 5. A record whose `name` is not the requested
   name: exit 5.
2. Take the locks.
3. Look the domain up by UUID. If it exists under another name, refuse (exit
   5). If it is running, refuse unless `--force`, which powers it off.
4. Print exactly what will be removed: the domain, the three data file names,
   the control directory, the `known_hosts` line. Ask for confirmation.
   Without a terminal, refuse unless `--yes`.
5. `undefine --keep-nvram`. A domain that is already gone is not an error.
6. In the data directory, with the defensive rules of 04: delete
   `disk.qcow2`, `nvram.fd` and `seed.iso` if present, then remove the
   directory if it is empty. Otherwise warn and list what is left.
7. Remove the `known_hosts` line that carries the VM's marker.
8. In the control directory: delete the known file names, then the directory.

A file that is already missing counts as removed. Partial failure leaves the
state record in place, so `destroy` can be run again.

Never removed: SSH keys, share sources and their access entries, cached
images, anything vmseed did not create.

## `render`

Prints artifacts without side effects. `--what`: `plan` (default, a summary of
everything `create` would do, including every host file a recipe reads and
every host action on a share), `user-data`, `meta-data`, `network-config`,
`firstboot`, `report`, `domain-xml`, `inventory`. `--output DIR` writes files
instead.

UUID and nonce are fixed placeholders, so output is deterministic. `render`
needs the public keys but no image and no hypervisor.

## `keygen`

Creates the key pairs a VM's configuration expects and that do not exist.

- Only for `ssh_keys` entries that are paths ending in `.pub`.
- Runs `ssh-keygen -t ed25519 -a 100`, which asks for a passphrase on the
  terminal. This is the only interactive command.
- An existing private key without its `.pub`: the public key is derived, the
  private key is never overwritten.
- The key directory is created `0700`.
- Prints what it created and what already existed.

## `images`

- `list`: catalog and user-defined images, with capabilities and cache status.
- `fetch IMAGE`: download and verify into the cache (used by CI to warm it).
- `prune`: delete cached images no catalog entry references.

## `controls`

Prints the control catalog from the registry. `--markdown` is the source of
the generated control reference; CI fails if the committed reference is stale.

## `doctor`

Runs preflight without creating anything: host-wide checks, or the checks for
one VM. Exit 0 when everything passes, 2 otherwise.

## `config`

- `check`: validate the fleet file, including the fleet-level checks; exit 2
  with every error listed.
- `show NAME`: the resolved configuration of one VM with the origin of each
  value (`built-in`, `defaults`, `vm`).
- `schema`: the JSON Schema of the fleet file.
