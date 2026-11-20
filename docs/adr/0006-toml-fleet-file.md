# 0006. One TOML fleet file

Status: accepted, 2026-11-20

## Context

v0's configuration is flat `KEY=VALUE` with 39 keys. It cannot express lists
(several users, several shares), holds one VM per file with nothing inherited,
and mixes host paths, VM hardware, users and download pinning. Three separate
keys name the same VM (domain, hostname, instance id).

## Decision

- One TOML file, the fleet file: `[host]`, `[defaults]`, `[vm.<name>]`,
  `[images.<id>]`.
- Two layers only: built-in defaults, then `[defaults]`, then `[vm.<name>]`.
  Tables merge recursively; arrays replace.
- Strict: unknown keys are errors; all errors are reported together.
- One name per VM, the table key: domain name and hostname.
- Placeholders are written `{{ name }}`, in the fleet file and in recipes.

## Consequences

- Parsed by the standard library; typed; comments allowed.
- One place describes the fleet, which `list` and the inventory rely on.
- The file grows with the fleet. Arrays of tables are verbose.
- "Arrays replace" must be documented clearly; `config show` prints the
  resolved result with the origin of each value.

## Alternatives

- **YAML.** Familiar to cloud-init users, but implicit typing and significant
  indentation cause silent errors, and it needs a parser dependency.
- **Keep `KEY=VALUE`.** No change of habit, but lists need naming tricks.
- **One file per VM with `extends`.** File equals VM, but inheritance chains
  are hard to follow and nothing describes the fleet.
- **Layered profiles.** Most flexible, but merge rules are a classic source of
  surprise.
