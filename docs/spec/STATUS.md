# Status

Updated at the end of every session. Newest state first.

## Now

- **2026-11-21.** The specification was reviewed by two independent sessions
  (technical soundness; security) and revised. The review of each milestone
  was decided (ADR 0024, `11-review.md`). No Python code yet.
- The `v2` branch was pushed to GitHub once, by the planning session with the
  user's approval, so that M0 has a base for its pull request. From here on
  nothing is pushed to `v2` directly.
- **Next:** M0 (Foundation): a build session, then a review session
  (`/milestone-review <PR>`). See `09-milestones.md`.

## Waiting on the user

| Item | For | Detail |
|---|---|---|
| Environment `merge-approval` | M0 | Does not exist yet. The user as required reviewer; self-review prevention off. |
| Protection of `v2` and `main` | M0 | The existing ruleset covers only the default branch. Still to do: add `v2` to its targets; add "require deployments to succeed" with `merge-approval`; keep the bypass list empty. It already requires a pull request, a linear history and rebase merges, and blocks force-push and deletion. |
| Workflow permission on the token | M0, M1, M6 | It cannot be probed without changing a workflow. M0's first push that touches `.github/` proves it. |
| Host-check batch 1 | After M1 | Written by the M1 session. Run only from a merged branch. |

Done on 2026-11-21: the token (see V-GH-TOKEN in `10-assumptions.md`), `gh`
authenticated on the dev VM, `libvirt-client` installed, the review scheme.

## Milestones

| # | Milestone | State |
|---|---|---|
| M0 | Foundation | not started |
| M1 | Walking skeleton | not started |
| M2 | Configuration | not started |
| M3 | Distros and baseline | not started |
| M4 | Lifecycle | not started |
| M5 | Verify and keygen | not started |
| M6 | Images and firmware | not started |
| M7 | Network and shares | not started |
| M8 | Recipes and examples | not started |
| M9 | Documentation and release | not started |

States: not started, building, built (ready for review), in review, reviewed
(waiting for approval), merged.

## Host-check batches

| Batch | When | State | Result |
|---|---|---|---|
| 1 | after M1 | not written | |
| 2 | start of M7 (share spike) | not written | |
| 3 | after M7 | not written | |
| 4 | before release | not written | |

## Dev VM facts (2026-11-21)

- Fedora 44 guest, 1 vCPU, 1 GiB RAM, about 3 GB free in `/home`. No sudo, no
  KVM, no libvirt daemon.
- Present: Python 3.12, 3.13, 3.14 (uv), `sshd`, `ssh-keygen`, `nft`,
  `unshare` (user namespaces work), `shellcheck`, `xmllint`, `jq`, `gpgv`,
  `qemu-img` 10.2.2, `cloud-init` 26.1, `passt`, `virsh` and
  `virt-xml-validate` 12.0.0, `gh` (authenticated).
- Absent: any ISO tool (not needed: the seed is written with `pycdlib`).
- PyPI is reachable.

## Repository facts on GitHub (2026-11-21)

- Branches: `main` (the Bash tool) and `v2`. No tag yet.
- One ruleset, on the default branch only: pull request required with no
  approval count, linear history, rebase as the only merge method, no
  force-push, no deletion. Because a rebase merge rewrites commit hashes, the
  review record cites finding ids, never hashes (see 11).
- No environment and no required deployment yet (see "Waiting on the user").

## Session log

| Date | Session | Outcome |
|---|---|---|
| 2026-11-20 | Planning | Decisions taken with the user; spec and ADRs 0001 to 0023 written. |
| 2026-11-21 | Design review | Two independent reviews (42 findings). Spec and ADRs revised; four decisions re-taken with the user: two-boot verification, control/data split, share model, vmseed's own `known_hosts`. |
| 2026-11-21 | Review process | Decided with the user in two rounds of questions: ADR 0024, `11-review.md`, the `/milestone-review` skill and its briefs. The dev VM's token was checked. `v2` pushed. |
