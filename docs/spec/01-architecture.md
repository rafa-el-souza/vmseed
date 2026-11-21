# 01. Architecture

## Shape

Functional core, imperative shell.

```
 fleet file ──► config ──► plan ─────────────► ops (create, verify, destroy, ...)
   (TOML)      (typed)    (pure data:            │
                 ▲         cloud-config,         ├─► host adapters: virsh, qemu-img,
 catalog ────────┘         scripts, domain XML,  │    ISO, ssh, known_hosts, files
 (pinned)                  file operations)      └─► state record (vmseed.json)
```

- **`config`** parses and validates the fleet file into immutable models.
- **`plan`** is a pure function: `(fleet, vm name, catalog, public keys,
  uuid, nonce) -> Plan`. A `Plan` holds every artifact as data, including, for
  each control and phase, the report statuses that are acceptable.
- **`ops`** execute a plan through adapters and record what they did.
- `vmseed render` prints a plan. `vmseed create` applies it. Both use the same
  plan, so what `render` shows is what `create` does.

Tests snapshot plans. Adapters are replaced by fakes behind small protocols.

## Package layout

```
src/vmseed/
  cli.py                 Typer app. Thin: parse, call an op, map errors to exit codes.
  errors.py              Exception hierarchy.
  templating.py          The {{ name }} substitution used by config and recipes.
  display.py             The one sanitiser for untrusted text, and output helpers.
  config/
    models.py            Pydantic models: Fleet, VmConfig, User, network and share kinds, ...
    loader.py            Discovery, TOML load, [defaults] merge, path expansion, error text.
    schema.py            JSON Schema export.
  catalog/
    models.py            ImageEntry, capabilities.
    builtin.py           Loads data/catalog.toml and [images.*] from the fleet file.
    cache.py             Download, digest check, atomic placement, locking.
    inspect.py           Image safety check (format, no backing or data file).
  guest/
    distro/              Distro dataclass, primitive protocols, fedora.py, alpine.py,
                         components/ (packages, services, accounts, privilege, ssh,
                         firewall, resolver, updates, mac, crypto, sysctl).
    controls/            Control protocol, Contribution, Probe, registry, one module
                         per family (acc, ssh, net, krn, upd, mac, cry, cin, shr, rcp).
    recipes.py           Recipe model, loading, parameter substitution, restrictions.
    shell.py             POSIX sh script builder and quoting helpers.
    assemble.py          Contributions + recipes -> cloud-config dict, first-boot
                         script, report script, next-boot reporter.
    cloudconfig.py       Serialisation: user-data, meta-data, network-config.
    report.py            Report protocol: guest-side emitter text, host-side parser.
  host/
    domain.py            DomainSpec -> libvirt XML (ElementTree).
    kinds.py             Behaviour of each network kind and share kind.
    virsh.py             Hypervisor protocol and its virsh implementation.
    console.py           Channel capture through `virsh console` on a PTY.
    qemu_img.py          Disk creation.
    safeio.py            Directory-descriptor file operations: exclusive, no-follow.
    seed.py              NoCloud ISO (pycdlib).
    known_hosts.py       vmseed's own known_hosts file.
    ssh_exec.py          Run a script over ssh (verify).
    keygen.py            ssh-keygen wrapper.
    preflight.py         Host checks used by create and doctor.
  state.py               VmRecord: strict load, atomic write, locks.
  plan.py                build_plan().
  ops/                   create.py, verify.py, destroy.py, listing.py, render.py, ...
  data/catalog.toml
tests/   unit/  golden/  contract/  e2e/
tools/   refresh_catalog.py   findings.py (the review record, see 11)
examples/ quickstart/  sandbox/
```

Import rule: `config`, `catalog`, `guest`, `plan` never import `host`, `ops`
or `cli`. `host` never imports `ops`. A test enforces this.

## Extension points

Three axes are first-class in v1: **distros**, **controls**, and **network and
share kinds**. Each has a small interface, an explicit in-tree registry, a
conformance suite and a how-to guide. The hypervisor is **not** an extension
point: it has one thin protocol so tests can use a fake.

### The problem being solved

Controls and distros form a matrix. If a distro were a class with one method
per control, a new control would touch every distro. If a control were a
function switching on the distro, a new distro would touch every control.

Distros rarely differ in what a control intends. They differ in a few
primitives: how to install a package, enable a service, grant admin rights,
schedule updates. So a distro is a **composition of primitives**, and each
control is written **once** against them.

### Distro

```python
@dataclass(frozen=True)
class Distro:
    id: str                         # "fedora", "alpine"
    packages: PackageManager        # Dnf(), Apk()
    services: ServiceManager        # Systemd(), OpenRC()
    accounts: Accounts              # image accounts to remove, password locking, run-as,
                                    # privileged groups, reserved names
    privilege: Privilege            # Sudo(group="wheel"), Doas()
    ssh: SshServer                  # drop-in location, service, validate/reload,
                                    # host-key generation
    firewall: NftablesLayout        # ruleset path, service name
    resolver: Resolver | None       # stub-resolver listeners to switch off
    updates: AutoUpdates            # DnfAutomatic(), ApkPeriodic()
    mac: MandatoryAccessControl | None      # SELinux(), None
    crypto_policy: CryptoPolicy | None      # FedoraCryptoPolicies(), None
    sysctl: SysctlLayout            # drop-in path, per-interface mechanism,
                                    # keys this distro's kernel has
```

Primitives are protocols with a handful of methods. They **return data**
(steps, file specs, cloud-config fragments, shell tests). They never run
anything. Indicative shape:

```python
class ServiceManager(Protocol):
    def enable_now(self, unit: str) -> Sequence[Step]: ...
    def reload_or_restart(self, unit: str) -> Sequence[Step]: ...
    def run_once_at_next_boot(self, script: str) -> Contribution: ...
    def power_off(self) -> Sequence[Step]: ...
    def test_enabled(self, unit: str) -> ShellTest: ...
    def test_active(self, unit: str) -> ShellTest: ...

class Privilege(Protocol):
    def cloud_config_for_admin(self, user: str) -> UserAttributes: ...
    def elevate(self, argv: Sequence[str]) -> Sequence[str]: ...   # ["sudo","-n",...] / ["doas","-n",...]
    def test_can_elevate(self, user: str) -> ShellTest: ...
    def test_no_other_grant(self, admins: Sequence[str]) -> ShellTest: ...
```

A capability a distro lacks is `None`, and the control that needs it reports
`not applicable` with a reason. No control tests `distro.id`.

### Control

```python
class Control(Protocol):
    id: str            # "SSH-01"
    title: str
    rationale: str     # one paragraph; the source of the generated docs
    phases: frozenset[Phase]   # {baseline, final} by default; some are {final}
    def applies(self, ctx: GuestContext) -> Applicability: ...   # ok | n/a(reason) | skipped(reason)
    def contribute(self, ctx: GuestContext) -> Contribution: ...
    def probe(self, ctx: GuestContext) -> Probe: ...
```

- `GuestContext` carries the resolved VM configuration, the `Distro`, and
  derived facts (users with their UIDs, endpoint, declared ports).
- `Probe` is a POSIX `sh` function body. It prints evidence and returns `0`
  (ok) or non-zero (fail). `n/a` and `skip` are decided by the plan, never by
  the guest.

Application, check and documentation of a control live in one module.

### Contributions and how they merge

Several controls shape the same artifact: seven SSH controls share one sshd
drop-in, three controls share one sysctl file, and three account controls
shape the same `users` entries. So a `Contribution` is made of **typed
fragments**, and `assemble` renders each kind of fragment into its single
artifact:

| Fragment | Rendered into | Collision |
|---|---|---|
| `SshdDirective(name, value)` | the one sshd drop-in | the same directive from two controls |
| `SysctlEntry(key, value)` | the one sysctl file | the same key from two controls |
| `UserAttribute(user, key, value)` | that user's cloud-config entry | the same attribute of the same user |
| `NftRule(...)` | the one ruleset | none: rules are a set |
| `Package(name)` | the install transaction | none: a set |
| `File(path, ...)` | `write_files` | the same path from two controls |
| `CloudConfigKey(key, value)` | top-level cloud-config | the same key from two controls |
| `Step(id, script, stage)` | the first-boot script, in registry order | the same id |

Merging is deterministic and follows registry order. A collision as defined in
the table is an error raised by `assemble` and caught by the conformance
suite.

### Network and share kinds

Kinds are selected by a `kind` field in the configuration (a Pydantic
discriminated union). Each kind has a behaviour object:

```python
class NetworkKind(Protocol):
    def validate(self, vm: VmConfig) -> None: ...
    def domain_interface(self, vm: VmConfig) -> ET.Element: ...
    def guest_network_config(self, vm: VmConfig) -> Mapping[str, object] | None: ...
    def endpoint(self, vm: VmConfig) -> Endpoint: ...          # always known from configuration
    def preflight(self, vm: VmConfig) -> Sequence[Check]: ...

class ShareKind(Protocol):
    def domain_devices(self, share: ShareConfig, ids: IdMap) -> Sequence[ET.Element]: ...
    def domain_requirements(self) -> DomainRequirements: ...   # e.g. shared memory
    def host_preparation(self, share: ShareConfig, ids: IdMap) -> Sequence[HostAction]: ...
    def guest_mounts(self, share: ShareConfig) -> Sequence[Mount]: ...
    def preflight(self, share: ShareConfig) -> Sequence[Check]: ...
```

`endpoint` is a pure function of the configuration. Nothing reported by a
guest or read from the hypervisor ever decides where the host connects.

v1 ships `bridge` and `passt` networks, and `virtiofs` shares.

### Registries

Registries are explicit tuples in code: `DISTROS`, `CONTROLS`, `NETWORK_KINDS`,
`SHARE_KINDS`. No entry points, no import-time discovery. Adding an item is a
new module plus one line in the registry.

### Conformance suite

Parametrised over every registered distro and control, it asserts:

- every control either applies or declares `n/a` with a reason, on every distro;
- contributions are deterministic and merge without a collision;
- every applicable control has a probe, and declares its phases;
- the rendered cloud-config is schema-valid;
- the rendered first-boot, report and next-boot scripts pass `sh -n` and
  `shellcheck -s sh`;
- every file path is absolute; every mode is explicit;
- every sysctl key rendered for a distro is in that distro's key list;
- golden files exist for each distro.

The suite is what makes "easy to add" true: a new distro or control is guided
by its failures.

### How to add

**A distro**
1. Write `guest/distro/<id>.py` composing existing primitives; add any missing
   primitive under `components/`.
2. Record the distro's facts as data: accounts the image ships, privileged
   groups, sysctl keys its kernel has.
3. Register it in `DISTROS`.
4. Add catalog entries and a refresh source (see 06).
5. Run the conformance suite; generate and review golden files.
6. Add the image to the e2e matrix; calibrate probes from the CI evidence.
7. Record every distro-specific finding in `10-assumptions.md`.

**A control**
1. Write the control (id, title, rationale, phases, `applies`, `contribute`,
   `probe`).
2. Register it; regenerate the control reference.
3. Add unit tests and probe fixture tests, update golden files, run e2e on
   every image.
4. If it changes the baseline's promise, add an ADR.

**A network or share kind**
1. Add the config model with its `kind` literal.
2. Add the behaviour object; register it.
3. Extend the inventory schema if the endpoint shape is new (see 07).
4. Unit, golden and e2e tests.

## Adapters and seams

Protocols with a real and a fake implementation:

| Protocol | Real | Purpose of the fake |
|---|---|---|
| `Hypervisor` | `virsh` subprocess | Domain lifecycle in unit tests |
| `ChannelSource` | `virsh console` on a PTY | Feeding scripted console and report output |
| `DiskTool` | `qemu-img` | No real images in unit tests |
| `Fetcher` | `urllib` | No network in unit tests |
| `RemoteShell` | `ssh` | Scripted verify output |
| `Clock`, `Ids` | system | Deterministic time, UUID, nonce |

Adapters capture stdout and stderr, apply a timeout, and raise
`ExternalToolError` carrying the command and the tool's own message. The
tool's message is shown to the user after passing through the sanitiser.

## Untrusted text

Text is untrusted when it comes from a guest (console, report evidence, ssh
output), from a downloaded file, or from a tool's error message.

- One function in `display.py` makes such text safe to show: it escapes C0
  controls other than tab and newline, ESC, DEL and C1 controls.
- Every untrusted string passes through it before reaching the terminal.
- Untrusted text is never passed to `rich` as markup.
- Unit tests feed hostile strings (clipboard, hyperlink and title escape
  sequences, markup) through every display path.

## Errors and exit codes

| Code | Meaning | Exception |
|---|---|---|
| 0 | Success | |
| 1 | Operational failure (a tool failed, I/O error, protocol error) | `ExternalToolError`, `OperationError` |
| 2 | Usage, configuration or preflight error; nothing was changed | `ConfigError`, `PreflightError` |
| 3 | The VM exists but one or more controls failed | `VerificationFailed` |
| 4 | A boot did not report in time, or the domain stopped unexpectedly | `BootTimeout` |
| 5 | Refused for safety (exists, unmanaged, running, not confirmed, locked) | `SafetyRefusal` |

Messages state what happened, why, and the command that fixes it. Results go to
stdout; progress and diagnostics go to stderr. `--json` is available wherever a
command produces data.

## Concurrency and locking

Locks are advisory `flock`s on files under `<state_dir>/locks/`, which exist
independently of any VM. State-changing commands take them in this order,
non-blocking, and fail with exit 5 if one is held:

1. the optional external lock (`host.lock_file`);
2. the per-VM lock `<state_dir>/locks/<name>.lock`.

Checks that decide whether to proceed (does the VM exist?) run **after** the
locks are held.

- A per-image lock serialises download and verification of the same image.
- A single lock covers every edit of vmseed's `known_hosts` file.
- File descriptors are close-on-exec, so no child inherits a lock.
- State records are written atomically (temp file in the same directory, then
  `rename`).

## Security invariants

1. **Two directories, two trust levels.** The control directory is private to
   the user and holds everything vmseed trusts: the state record, audit
   copies, logs. The data directory holds only what the hypervisor needs and
   may be writable by another account, so it is treated as hostile.
2. **File operations in the data directory** go through a directory
   descriptor, never follow a symlink in any path component, and create files
   exclusively. vmseed creates and deletes only fixed names there
   (`disk.qcow2`, `nvram.fd`, `seed.iso`).
3. **Deletion.** `destroy` removes only those fixed names and the known names
   in the control directory. It never deletes recursively, and never deletes
   a path read from libvirt or from a file another account can write.
4. **Identity.** A domain is addressed by the UUID vmseed generated. A domain
   with the same name and another UUID is foreign and is never touched.
   `destroy` requires the state record's name to equal the requested name.
5. **Shell.** No `shell=True`. Generated scripts quote every interpolated
   value with `shlex.quote`. Values reaching a script are validated first.
   Options are separated from operands with `--`.
6. **Images.** A digest proves identity, not safety. Before any use, an image
   is checked to be a plain qcow2 with no backing file and no external data
   file, and it is re-hashed on every use.
7. **Seed.** The seed contains no secret produced by vmseed.
8. **Keys.** vmseed reads public keys only. A private key offered as a public
   key is rejected. `keygen` is the only command that creates key material,
   and `destroy` never deletes it.
9. **Host keys.** vmseed writes only its own `known_hosts` file. A line is
   built from validated fields, never copied from guest bytes.
10. **Trust direction.** Guest output is data: parsed with a strict grammar,
    length-limited, sanitised before display, never executed, never used to
    choose a path, a command or an address.
11. **Endpoints.** Where the host connects comes only from the configuration.
12. **Hypervisor URI.** Only local `qemu` URIs are accepted (see 02). A URI
    cannot name a command to run.
