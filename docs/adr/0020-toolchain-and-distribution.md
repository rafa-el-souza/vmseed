# 0020. Toolchain and distribution

Status: accepted, 2026-11-20; revised 2026-11-21

## Context

v0 depends on `virt-install`, `cloud-localds`, `gpgv` and `awk` on the host
and builds YAML by text substitution, which forced fragile rules (a generated
password had to be alphanumeric so it would not break the template engine).

`uv tool install` resolves dependencies afresh: it does not read the project's
lock file. Pinning in `uv.lock` therefore protects CI and development, not
someone who installs the tool.

## Decision

**Runtime:** Python 3.12 or newer, with `pydantic` (validation and schema),
`typer` (CLI), `PyYAML` (emit cloud-config), `pycdlib` (build the seed ISO in
Python) and `rich` (tables and progress).

**Development:** `uv`, `ruff`, `pyright` in strict mode, `pytest`,
`pytest-cov`, `hypothesis`.

**Rules:**
- Structured artifacts are built as data and serialised. No template engine.
- Downloads use the standard library.
- Untrusted text is sanitised before display and never passed to `rich` as
  markup.
- Adding a dependency needs the user's approval.

**Host requirements:** libvirt (`virsh`), `qemu-img` and OpenSSH's client
tools. For shares: `virtiofsd`, subordinate ID ranges and an ACL tool.

**Distribution:** GitHub only for now, installed from the repository with
`uv tool install`. A **constraints file exported from `uv.lock`** is published
and kept current by CI, and the documented install command uses it, so a user
gets the dependency versions that were tested. The packaging is PyPI-ready, so
publishing later is a workflow, not a redesign. The project name's
availability on PyPI has not been checked.

**Language:** everything in the repository is in English. **License:** MIT, as
before.

## Consequences

- Every dependency has prebuilt wheels; nothing compiles at install time.
- The host needs far fewer tools than v0 did.
- Six direct dependencies to keep current, one of them development-only.
- An install that follows the documentation is pinned; one that ignores it is
  not.
- No install by name until PyPI publication is decided.

## Alternatives

- **Standard library only.** Elegant, but YAML and ISO would need home-made
  emitters or host tools, exactly where v0 suffered.
- **A broader stack** (Jinja2, httpx, structlog). Convenient, more surface,
  little gain for a CLI this size.
- **PyPI now**, or **PyPI plus an RPM.** More reach, more to maintain from
  day one.
- **No coverage target.** One dependency fewer, but test quality would rest on
  review alone.
