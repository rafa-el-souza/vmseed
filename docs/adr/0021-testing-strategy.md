# 0021. Testing strategy

Status: accepted, 2026-11-20; revised 2026-11-21

## Context

v0's 135 tests run the script as a subprocess with fake binaries on `PATH` and
compare argument strings. No test boots a VM.

The development machine has no KVM and no sudo, and cannot reach the user's
host. The project's main risk is integration: real images, cloud-init on
Alpine, SELinux on the host.

Hosted CI runners have offered KVM in practice, but without official support,
and since late October 2026 standard Linux jobs may run on a second cloud
about which nothing is stated.

## Decision

Four tiers (`08-testing.md`):

1. **Unit and golden.** Pure code, fakes for adapters, reviewed snapshots of
   every rendered artifact, property tests for hostile input, probe tests
   against fixtures of passing and failing states, a conformance suite over
   distros and controls.
2. **Contract.** Rendered artifacts fed to the real tools that consume them,
   and safety rules exercised against the real file system, without a VM.
3. **End to end.** Real boots of every supported image in GitHub Actions.
   Every job checks for KVM first and reports "no KVM" as its own visible
   result; it never falls back to emulation silently.
4. **Host checks.** Four short batches the user runs on the real host at
   defined milestones. One of them is a spike that validates the share
   mechanism before it is implemented.

Branch coverage of at least 90%. Nothing is called verified end to end without
a CI run to cite. A host check runs only from a branch the user has merged.

## Consequences

- Guest behaviour is proven on every image at every pull request, when KVM is
  available.
- Host-only behaviour is proven four times instead of never.
- A probe is tested for the failure it must detect, not only for success.
- If hosted KVM becomes unreliable, the fallback is a decision for the user,
  recorded in `10-assumptions.md`.
- Sessions need to push and read CI results (ADR 0023).

## Alternatives

- **Manual host checks only.** The real environment, but a slow loop that
  depends on the user for every attempt.
- **No real boots during implementation.** Simple to run, but integration
  problems surface at the end, when they cost most.
- **A self-hosted runner on the user's host.** Reliable KVM, but it would run
  pull-request code from a public repository on the machine that matters most.
