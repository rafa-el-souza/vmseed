# vmseed

[![ci](https://github.com/rafa-el-souza/vmseed/actions/workflows/ci.yml/badge.svg?branch=v2)](https://github.com/rafa-el-souza/vmseed/actions/workflows/ci.yml?query=branch%3Av2)

> **v2 is in development, on this branch.** It is a rewrite in Python and
> does not create a VM yet.

vmseed turns a declaration into a running, hardened virtual machine and a
report that proves it. From a fleet file, `vmseed create <name>` fetches a
cloud image pinned by digest, renders a cloud-init seed that applies a fixed
security baseline, boots the VM twice under libvirt, and reads the result of
every baseline control over a dedicated serial channel. Then it steps back:
running the VM is the job of the operator's own tools.

## Where things are

- **The Bash version (v0)** is kept at the tag
  [`v0-bash`](https://github.com/rafa-el-souza/vmseed/tree/v0-bash), with its
  own README.
- **The plan for v2** is in [`docs/spec/`](docs/spec/). Start with
  [`00-overview.md`](docs/spec/00-overview.md); progress is in
  [`STATUS.md`](docs/spec/STATUS.md). The reasons behind each decision are in
  [`docs/adr/`](docs/adr/).
- **The review record** of each milestone is in
  [`docs/findings/`](docs/findings/) once its review has run
  ([`11-review.md`](docs/spec/11-review.md)).

## Development

You need [uv](https://docs.astral.sh/uv/) 0.13. Every tool, the type checker's
Node.js runtime included, is pinned by `uv.lock`.

```bash
uv sync
uv run vmseed --version
```

The quality gates, all of which must pass before a push:

```bash
uv run ruff format --check .
uv run ruff check .
uv run pyright
uv run pytest            # unit, golden and contract tiers
python3 tools/findings.py check
```

`constraints.txt` holds the runtime dependencies at the versions CI tested.
A test checks that it matches `uv.lock`; to regenerate it:

```bash
uv export --frozen --format requirements.txt --no-dev --no-emit-project \
  --no-hashes --no-header --output-file constraints.txt
```

## License

MIT. See [LICENSE](LICENSE).
