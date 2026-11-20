# 0001. Python rewrite in the same repository

Status: accepted, 2026-11-20

## Context

v0 is a 950-line Bash script with a custom template engine. Fedora is baked
into its name, URLs, parsing and template; everything lives inside one
function, so nothing can be tested in isolation. Supporting a second distro
means rewriting it. The repository name, `vmseed`, was already distro-neutral.

## Decision

- Rewrite in Python, in this repository.
- Tag the last Bash commit `v0-bash`.
- Develop on a long-lived `v2` branch, one pull request per milestone.
- `v2` replaces `main` at release.
- v0 is a source of guest-side knowledge. It is never a structural template.

## Consequences

- Name, URL and history are kept. The history shows the evolution from script
  to engineered tool.
- The history mixes Bash and Python.
- Discipline is needed not to port v0's structure. The spec carries the
  knowledge worth keeping (see `03-guest-baseline.md`, "Carried from v0").

## Alternatives

- **A new repository.** Clean history and freedom to rename, but two
  repositories and no visible continuity.
- **An orphan branch in this repository.** Clean `main` history, but two
  unconnected histories and a rewritten `main`.
