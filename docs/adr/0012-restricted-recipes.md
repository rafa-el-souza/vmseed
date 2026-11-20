# 0012. Recipes: trusted code with guard rails

Status: accepted, 2026-11-20; revised 2026-11-21

## Context

v0's template hard-codes the author's environment: Claude Code installed with
`curl | bash`, tmux and its plugins, `gh`, `btop`. A generic tool needs a way
to add such content without owning it.

The first version of this record called recipes "restricted" and said the
baseline's guarantees survive them. A design review showed that this
overstates it: a recipe command runs as root in the guest, and the one thing a
recipe could do on the host, reading a file through `source`, was unconfined.

## Decision

- A **recipe** is a TOML file with packages, files and commands, with
  per-distro additions and declared parameters. It is applied after the
  baseline.
- **A recipe is trusted code**, to be reviewed like a shell script. The rules
  below prevent accidents. They are not a boundary against a hostile recipe,
  and the documentation says so.
- On the host, a recipe can only read files inside its own directory. The plan
  lists every file it reads.
- In the guest: `run_as` is required on every command; package names are
  validated and passed as operands; file modes cannot be setuid, setgid or
  world-writable; files cannot target paths that the baseline owns or that
  decide who is trusted; a recipe cannot open a port.
- The **baseline report is emitted before any recipe command runs**, so it
  does not depend on recipe code. The final report, after a reboot, detects
  accidental breakage (ADR 0018).
- The author's environment becomes `examples/sandbox/`.

## Consequences

- The proof of the baseline does not rest on recipe code.
- An honest recipe cannot quietly weaken the machine: breakage shows in the
  final report.
- A hostile recipe is still root in the guest. Using someone else's recipe is
  a trust decision, and the tool does not pretend otherwise.
- A small vocabulary to learn instead of raw cloud-config.
- Recipes are not a secret channel.

## Alternatives

- **Raw cloud-config passthrough.** All of cloud-init's power and nothing new
  to learn, but the merge can override the baseline, merge rules are subtle,
  and distro differences fall on the user.
- **Recipes plus an escape hatch** limited to keys vmseed does not own. Covers
  rare cases at the cost of more surface now; can be added later.
- **Commands run as a non-root user by default.** Safer by default, but
  ambiguous with several users; an explicit `run_as` is clearer.
- **Nothing.** Purest, but the sandbox example could not exist.
