# 02. Configuration

One TOML file, the **fleet file**, declares everything.

## Discovery

First match wins:

1. `--config PATH`
2. `$VMSEED_CONFIG`
3. `$XDG_CONFIG_HOME/vmseed/vmseed.toml` (default `~/.config/vmseed/vmseed.toml`)

- The current directory is **not** searched. A fleet file can name host
  directories to share and files to read, so one found by accident (in a
  cloned repository, or in a directory a guest can write) must never be
  loaded.
- The fleet file must be owned by the invoking user and not writable by group
  or others. Otherwise it is refused.
- Every command prints, on stderr, which fleet file it used.
- No file found is a configuration error that names the three places.

The fleet file is trusted input: it is the user's own declaration.

## Structure

```text
[host]                 # this machine; all optional
[defaults]             # any VM key; applies to every VM
[vm.<name>]            # one table per VM; only what differs
[images.<id>]          # optional user-defined images (see 06)
```

### Merge rule

For each VM: start from built-in defaults, apply `[defaults]`, then
`[vm.<name>]`.

- Tables merge key by key, recursively.
- **Arrays replace.** A `users` array in `[vm.x]` replaces the one in
  `[defaults]`; it is not appended.

There is no other inheritance. `vmseed config show <name>` prints the resolved
configuration of one VM with the origin of each value.

### Strictness

- Unknown keys are errors, with the key path and the closest valid name.
- Every error names the file, the key path and the rule broken. All errors are
  reported together, not one at a time.
- The file is parsed, never executed. No environment variable expansion.

### Paths and placeholders

- A leading `~/` expands to the invoking user's home.
- A relative path in the fleet file is relative to the fleet file's directory.
- Placeholders use `{{ name }}`. Available names depend on the key and are
  listed below. An unknown placeholder is an error.
- Paths are normalised before any check is applied to them.

## `[host]`

Every path here has a default and can be changed.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `state_dir` | path | `$XDG_STATE_HOME/vmseed` | Control data, private to the user: state records, audit copies, logs, locks. Created `0700`. |
| `cache_dir` | path | `$XDG_CACHE_HOME/vmseed` | Base images. Disposable. Must be owned by the user and not writable by others. |
| `known_hosts` | path | `$XDG_DATA_HOME/vmseed/known_hosts` | vmseed's own `known_hosts` file, holding only the keys of VMs it created. |
| `lock_file` | path | unset | Optional external advisory lock taken by state-changing commands (see 07). |

## VM keys

Valid in `[defaults]` and in `[vm.<name>]`.

| Key | Type | Default | Rule |
|---|---|---|---|
| `managed` | bool | `true` | `false` declares an adopted VM (see below). Not valid in `[defaults]`. |
| `image` | string | required | A catalog id or an `[images.*]` id. |
| `libvirt_uri` | string | `qemu:///session` | One of the accepted forms below. |
| `dir` | path | `$XDG_DATA_HOME/vmseed/vms/{{ name }}` | The VM's **data directory**: disk and NVRAM. Placeholder: `name`. Must not exist yet. |
| `data_access` | enum | `"private"` | `private`: directory `0700`, files `0600`. `group`: directory `2770`, files `0660`, for a hypervisor that runs as another account. |
| `memory` | size | `"2G"` | Integer MiB, or `<n>M` / `<n>G`. Minimum 256M. |
| `vcpus` | int | `2` | 1 or more. |
| `disk` | size | `"20G"` | `<n>G` / `<n>T`. Not smaller than the image's virtual size. |
| `firmware` | enum | `"uefi"` | `uefi` or `bios`. Must be supported by the image. |
| `secure_boot` | bool | `false` | Requires `firmware = "uefi"` and an image that supports it. |
| `graphics` | enum | `"none"` | `none`, or `spice` (no listening port). |
| `users` | array | required | See Users. |
| `ssh` | table | see below | SSH knobs. |
| `firewall` | table | see below | Extra inbound ports. |
| `updates` | table | see below | Update knobs. |
| `network` | table | **required** | No built-in default. See Network. |
| `shares` | array | `[]` | See Shares. |
| `recipes` | array | `[]` | See Recipes. |

### VM name

The table key of `[vm.<name>]`. It is the libvirt domain name, the guest
hostname, and part of key file names and of the host-key alias.

- `^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`
- Not composed only of digits (`virsh` would read it as a domain id).

### `libvirt_uri`

Only local `qemu` connections:

- `qemu:///session`
- `qemu:///system`
- `qemu+unix:///session?socket=<absolute path>`
- `qemu+unix:///system?socket=<absolute path>`

Anything else is refused: other drivers, remote transports, and any other URI
parameter. libvirt's `ext` and `ssh` transports accept a `command` parameter
that names a program to run; a configuration value must never be able to do
that.

### `dir` and the default location

- The data directory itself must not exist; `create` makes it with an
  exclusive `mkdir`. Its parent must exist, except for the built-in default,
  whose parent vmseed creates (`0700`).
- Across the fleet, `dir` values must be unique and must not contain one
  another.
- A `dir` may not be inside `state_dir`, `cache_dir` or a share `source`.

### Users

```toml
[[defaults.users]]
name = "ops"
role = "admin"

[[defaults.users]]
name = "dev"
role = "standard"
ssh_keys = ["~/.ssh/{{ user }}-{{ vm }}.pub"]
```

| Key | Type | Default | Rule |
|---|---|---|---|
| `name` | string | required | `^[a-z_][a-z0-9_-]{0,31}$`; unique in the VM; not reserved by the distro (`root`, accounts the image ships, system accounts). |
| `role` | enum | required | `admin` (passwordless privilege escalation) or `standard` (none). |
| `ssh_keys` | array | `["~/.ssh/{{ user }}-{{ vm }}.pub"]` | Each item is a path to a public key file or an inline public key. Placeholders: `user`, `vm`. At least one. |
| `uid` | int | 1000 + position | 1000 to 59999; unique in the VM. Pinned so that share ownership is deterministic. The user's primary group has the same id. |
| `shell` | path | distro default | Absolute path. |
| `groups` | array | `[]` | Extra groups. The distro's privileged groups (for example `wheel`, `sudo`, `root`, `disk`, `docker`, `libvirt`) are refused: use `role`. |

Rules:

- At least one `admin` per VM. Passwords are locked, so a VM without an admin
  could never be administered.
- A key must parse as an OpenSSH public key. A private key is rejected with a
  message pointing at the `.pub` file.
- A missing key file is an error that prints the `vmseed keygen` command.
- No user has a password. There is no key to set one.

### `ssh`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `allow_from` | array of IP/CIDR | `[]` | Empty: SSH is reachable from any source on the VM's network. Non-empty: only these sources. Not valid with `network.kind = "passt"` (every connection arrives from the host). |
| `tcp_forwarding` | enum | `"no"` | `no`, `local` or `yes`. Maps to `AllowTcpForwarding`. |

A warning is printed when `allow_from` is set: with locked passwords, a wrong
list leaves the VM unreachable even from the console. The list filters source
addresses; on a shared bridge it does not authenticate them.

### `firewall`

```toml
[[vm.web01.firewall.allow]]
port  = 8080
proto = "tcp"                  # tcp (default) or udp
from  = ["192.168.122.1"]      # optional; default any source
```

Declared ports are the only ones, besides SSH, that may accept connections and
that may be listening (controls NET-01 and NET-02).

### `updates`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `first_boot` | bool | `true` | Upgrade every package during the first boot. |
| `automatic` | bool | `true` | Enable the distro's automatic update mechanism. No automatic reboot. |

Disabling either is reported by `verify` as `skip`, never as `ok`.

### `network`

There is no built-in kind. If no `network` table applies to a VM, the error
explains both kinds and their trade-offs.

**`kind = "bridge"`**: the VM joins an existing host bridge and has its own
address.

| Key | Type | Default | Rule |
|---|---|---|---|
| `bridge` | string | required | An existing bridge device. |
| `ipv4` | CIDR | **required** | Static address, e.g. `192.168.122.11/24`. Choose one outside the network's DHCP range. Unique in the fleet. |
| `gateway` | IP | first host address of the subnet | |
| `dns` | array of IP | `[gateway]` | |
| `mac` | MAC | derived | Default: `52:54:00` plus three bytes of SHA-256 of the VM name. Stable across re-creation. |

`ipv4` is required so that the address the host connects to always comes from
the configuration. A DHCP address could only be learned from the guest or the
hypervisor, and neither may decide where the host connects.

**`kind = "passt"`**: unprivileged user-mode networking; the host reaches the
guest through forwarded ports on `127.0.0.1`.

| Key | Type | Default | Rule |
|---|---|---|---|
| `ssh_port` | int | required | Host port forwarded to guest port 22. 1024 to 65535. Unique in the fleet. |
| `mac` | MAC | derived | As above. |
| `forward` | array | `[]` | Items `{ host = <port>, guest = <port>, proto = "tcp" }`. Each guest port is also allowed in the guest firewall. |

The limits of each kind are part of the security model (see 03, "Network
limits") and must appear in the user documentation.

### `shares`

A share is a host directory the guest can use. The model is **the guest
writes, the host reads**: no guest identity, root included, is the invoking
user on the host. See 04 for the mechanism and 03 for the trust model.

```toml
[[vm.dev01.shares]]
kind     = "virtiofs"                 # default, and the only kind in v1
source   = "/srv/vms/shares/dev01"    # host directory; must exist
mount    = "/home/dev/projects"       # guest mount point (absolute)
readonly = false                      # required: state it
owner    = "dev"                      # the declared user that may write
tag      = "projects"                 # default: last component of mount
```

| Key | Rule |
|---|---|
| `source` | Absolute. An existing directory owned by the invoking user, not a symlink. Not `$HOME` itself, and not inside or containing `~/.ssh`, `state_dir`, `cache_dir`, or any VM's `dir`. Unique in the fleet unless every use is `readonly`. |
| `mount` | Absolute. Not `/`, not a home directory itself, and not inside `/etc`, `/usr`, `/boot`, `/bin`, `/sbin`, `/lib*`, `/root`, `/proc`, `/sys`, `/dev`, `/run` or `/var/lib/vmseed`. |
| `readonly` | **Required.** `true`: the guest can only read; use it to send files in. `false`: `owner` can write. |
| `owner` | Required when `readonly = false`. A declared user of the VM. |
| `tag` | `^[a-z0-9][a-z0-9_-]{0,35}$`; unique in the VM. |

For a writable share, vmseed grants the mapped guest owner access to `source`
with an access control list, and says so in the plan. It does not change the
directory's owner or mode.

### `recipes`

```toml
recipes = [
  "recipes/hardening-extras.toml",
  { path = "recipes/dev-sandbox.toml", vars = { user = "dev" } },
]
```

Applied in order, after the baseline has been verified. See Recipe files
below.

## Adopted VMs

```toml
[vm.legacy01]
managed  = false
distro   = "fedora"                 # instead of `image`
host_key = "ssh-ed25519 AAAA..."    # needed by `verify`
network  = { kind = "bridge", bridge = "virbr0", ipv4 = "192.168.122.11/24" }

[[vm.legacy01.users]]
name = "ops"
role = "admin"
```

An adopted VM exists already and was not created by vmseed.

- It appears in `list` and in the inventory with the declared facts.
- `verify` runs the baseline probes over SSH and reports the divergence. It
  needs `host_key`: the user states the key they already trust. vmseed never
  learns an adopted VM's key by itself.
- `create`, `destroy` and `render` refuse it.
- Accepted keys: `managed`, `distro`, `host_key`, `libvirt_uri`, `users`,
  `ssh`, `firewall`, `updates`, `network`, `shares`. Any other key is an
  error: nothing is silently ignored.
- `network` describes facts (how to reach the VM), not something to apply.

## Recipe files

A recipe adds content after the baseline.

**A recipe is trusted code.** Its commands run inside the guest, as root if it
says so, during provisioning. Review a recipe as you would a shell script. The
rules below prevent accidents; they are not a boundary against a hostile
recipe.

```toml
description = "Developer sandbox: tmux, git, Claude Code for one user"
packages    = ["git", "tmux"]

[params.user]
description = "Unprivileged user that owns the environment"
# default = "dev"        # a param without a default is required

[distro.fedora]
packages = ["gh"]

[distro.alpine]
packages = ["github-cli", "bash"]

[[files]]
path   = "/home/{{ user }}/.tmux.conf"
source = "files/tmux.conf"          # or: content = "..."
owner  = "{{ user }}"
mode   = "0644"

[[commands]]
description = "Install Claude Code"
run_as  = "{{ user }}"              # required: root or a declared user
run     = "curl -fsSL https://claude.ai/install.sh | bash"
distros = ["fedora", "alpine"]      # optional filter
```

Rules:

- **`source` stays inside the recipe.** It is a relative path that must
  resolve, symlinks included, inside the recipe file's own directory. No
  absolute path, no `~`, no `..` escape. This is the only thing a recipe can
  read on the host. `render --what plan` lists every host file a recipe reads.
- **`run_as` is required** on every command. There is no default.
- **Package names** match `^[A-Za-z0-9][A-Za-z0-9._+-]*$` and are passed to the
  package manager after `--`.
- **`mode`** may not set setuid, setgid or sticky bits, nor be world-writable.
- **Placeholders** are the recipe's declared `params`, written `{{ name }}`,
  valid in `path`, `owner`, `run_as`, `run` and inline `content`. Files read
  through `source` are copied byte for byte. A parameter value is validated by
  the field it feeds: a user name must be a declared user; a path is
  normalised before any check.
- `owner` and `run_as` must resolve to `root` or to a user declared for the VM.
- **Reserved paths.** A file may not target a path owned by the baseline or
  one that decides who is trusted: the paths written by controls, plus
  `/etc/passwd`, `/etc/shadow`, `/etc/group`, `/etc/sudoers*`, `/etc/doas*`,
  `/etc/pam.d/`, `/etc/polkit-1/`, `/etc/ssh/`, `/etc/cloud/`,
  `/etc/yum.repos.d/`, `/etc/dnf/`, `/etc/pki/`, `/etc/apk/`,
  `/etc/ld.so.preload`, `/etc/profile.d/`, `/root/`, `/usr/local/sbin/vmseed-*`
  and `/var/lib/vmseed/`. The check runs after substitution and normalisation.
- A recipe cannot open a port. Ports are declared on the VM (`firewall.allow`).
- Size limits: 1 MiB per file, 8 MiB of files per VM.
- Commands are free-form and can break the baseline. The final report runs
  after them and detects accidental breakage. The baseline report, emitted
  before any recipe command runs, does not depend on recipe code at all.
- A recipe is not a secret channel. Its content is stored in the audit copy of
  the seed, in the guest, and its output in the console log.

## Fleet-level checks

`vmseed config check` also enforces, across all VMs:

- unique `dir`, none nested in another;
- unique `network.ipv4`, unique `network.ssh_port` and forwarded host ports;
- unique derived or declared MAC addresses;
- no `dir`, `source`, `state_dir` or `cache_dir` inside one another;
- every recipe file exists and passes its rules.

## Complete example

```toml
[host]
lock_file = "/run/user/1000/operator.lock"

[defaults]
image   = "fedora-44"
dir     = "/srv/vms/{{ name }}"
memory  = "4G"
vcpus   = 2
disk    = "40G"
recipes = [{ path = "recipes/dev-sandbox.toml", vars = { user = "dev" } }]

[defaults.network]
kind   = "bridge"
bridge = "virbr0"

[[defaults.users]]
name = "ops"
role = "admin"

[[defaults.users]]
name = "dev"
role = "standard"

[vm.dev01]
network = { ipv4 = "192.168.122.11/24" }

[[vm.dev01.shares]]
source   = "/srv/vms/shares/dev01"
mount    = "/home/dev/projects"
readonly = false
owner    = "dev"

[vm.alp01]
image   = "alpine-3.24"
memory  = "512M"
disk    = "8G"
recipes = []
network = { ipv4 = "192.168.122.12/24" }
```

## Generated reference

`vmseed config schema` prints the JSON Schema of the fleet file. The
configuration reference in the user documentation is generated from the models
and checked for staleness in CI.
