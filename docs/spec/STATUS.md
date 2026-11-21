# Status

Updated at the end of every session. Newest state first.

## Now

- **2026-11-21, M0 built.** Pull request #2 (`m0-foundation`) is ready for
  review. `ci` is green on Python 3.12, 3.13 and 3.14. `approval` is red on
  purpose until the review closes `docs/findings/m0.toml`.
- The merge gate was shown end to end with throwaway pull request #3, closed
  unmerged: no approval was requested while its record was missing or open,
  the request appeared once the record was closed, the pull request stayed
  blocked until the owner approved, and was mergeable after. A direct push to
  `v2` was declined. See A-GH-GATE, A-GH-UNATTR and A-REV-GATE in
  `10-assumptions.md`.
- **Next:** the M0 review session. The user starts a new session with
  `/milestone-review 2`. It is the first run of the process of 11.
- Earlier on 2026-11-21: the specification was reviewed by two independent
  sessions and revised; the review of each milestone was decided (ADR 0024,
  `11-review.md`). `v2` was pushed once by the planning session, with the
  user's approval, so that M0 has a base for its pull request. From then on
  nothing is pushed to `v2` directly.

## Waiting on the user

| Item | For | Detail |
|---|---|---|
| M0 review session | M0 | Start a new session with `/milestone-review 2`. |
| Workflow permission on the token | M1, M6 | Granted now; M0 proved it. ADR 0023 grants it only while a milestone changes CI: it can be removed once M0 is merged, and granted again for M1 and M6. |
| Host-check batch 1 | After M1 | Written by the M1 session. Run only from a merged branch. |

Done on 2026-11-21: the token, including the workflow permission (see
V-GH-TOKEN in `10-assumptions.md`), `gh` authenticated on the dev VM,
`libvirt-client` installed, the review scheme, the environment
`merge-approval` with its required reviewer, the protection of `v2` and
`main`, the deployment approval of the throwaway pull request.

## Milestones

| # | Milestone | State |
|---|---|---|
| M0 | Foundation | built (ready for review): PR #2 |
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

- Branches: `main` (the Bash tool) and `v2`. Tag `v0-bash` on `120fd6a`, the
  last Bash commit of `main` (pushed 2026-11-21).
- One ruleset, on the default branch and `v2`: pull request required with no
  approval count, linear history, rebase as the only merge method, a
  successful deployment to `merge-approval` required, no force-push, no
  deletion, no bypass. Because a rebase merge rewrites commit hashes, the
  review record cites finding ids, never hashes (see 11).
- Environment `merge-approval`: the owner as required reviewer, self-review
  prevention off, no bypass for administrators, deployments from any branch.
- The workflow list shows `ci.yml` as "CI": GitHub names a workflow after the
  default branch's file, which is still v0's until `v2` replaces `main`.

## Session log

| Date | Session | Outcome |
|---|---|---|
| 2026-11-20 | Planning | Decisions taken with the user; spec and ADRs 0001 to 0023 written. |
| 2026-11-21 | Design review | Two independent reviews (42 findings). Spec and ADRs revised; four decisions re-taken with the user: two-boot verification, control/data split, share model, vmseed's own `known_hosts`. |
| 2026-11-21 | Review process | Decided with the user in two rounds of questions: ADR 0024, `11-review.md`, the `/milestone-review` skill and its briefs. The dev VM's token was checked. `v2` pushed. |
| 2026-11-21 | M0 build | Tag `v0-bash`; Bash tool removed from v2; Python project, tools, `findings.py`, workflows; PR #2 with `ci` green. Decided with the user: pyright with its `nodejs` extra (ADR 0020); the push to `v2` is tried only once its rules show in the API. After the user's GitHub settings, the gate was shown with throwaway PR #3 (closed unmerged) and a declined push to `v2`. M0 built. |
