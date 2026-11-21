# Status

Updated at the end of every session. Newest state first.

## Now

- **2026-11-21, M0 reviewed.** Pull request #2 (`m0-foundation`) waits for
  the owner's approval and merge. The record `docs/findings/m0.toml` is
  closed: 26 findings. 14 are fixed: 12 by 11 commits, each with its test
  seen failing first, and 2 by the owner's GitHub settings. 7 are kept as
  built and 5 deferred, by the user's answers to 14 questions. Its summary is
  in the pull request's description.
- **Next, at the user's request:** a session of its own to review calmly the
  decisions taken in M0's review (the answers to M0-Q1 to M0-Q14), before the
  process amendment below is written.
- **Process amendment** (a revision of ADR 0024 and a pull request of its own,
  with its own review), from M0's answers:
  - align 11's `open` row and 09's definition of done with the Outcomes
    table (M0-Q3), and the Clause table on a sibling's root (M0-Q4);
  - a gate that ties the record to the pull request's head (M0-Q6). Until
    then the owner checks at approval that every commit after the last
    round's head cites a finding or only changes the record;
  - before M3, a form for guest-side paths that `check` accepts (M0-Q7);
  - the correctness scopes when one holds no file of the range or a file is
    in none (M0-Q9);
  - `approval.yml` runs `v2`'s `findings.py` once M0 is merged (M0-Q11);
  - a picked finding may end `not reproduced` (M0-Q13);
  - 11 states the limit of literal trigger patterns (M0-Q14).
- **What did not fit M0's review, the first run of 11:**
  - The build session put a co-author trailer on every commit. With the
    user's leave, the review session rewrote the seven messages before the
    review (same trees) and force-pushed `m0-foundation` once, with a lease.
    No session adds attribution lines any more.
  - Claude Code made the first reviewer's worktree from `main`, not from the
    reviewed head, until the user set `worktree.baseRef = head` (M0-F03).
  - The `core` scope held no file of the range: the correctness reviewer ran
    once over every path, recorded as `ran` (M0-Q9).
  - A reviewer's note has no id, but `check` wants one in `ref`: the record
    numbers such notes after the reviewer's claims and says so in `note`.
  - The user was present, so the questions were asked after the planned
    fixes and before the fix review: the fixes their answers called for
    (M0-F07, M0-F10, M0-F19) were reviewed with the others.
- Reviewer notes that are not findings, for later sessions:
  - `tests/unit/test_workflows.py` does not catch `if: always()` on `approve`
    or `continue-on-error` on `review-record`; the required status check now
    blocks the merge in either case.
  - The approval step runs `findings.py gate "$BRANCH"` without `--`; a branch
    named like an option prints help and passes, as any branch that is not a
    milestone's does.
  - `findings.py` echoes a record's raw id in `check`'s error lines, and
    `summary` writes record text into Markdown unescaped (an unterminated
    `<!--` hides the rest). No attacker writes a record.
  - `test_git_outside_a_repository_is_an_error` fails when pytest's temporary
    directory is inside a git checkout; harmless in CI.
  - On the 1-vCPU dev VM, `test_check_decides_any_document` can fail
    Hypothesis's `too_slow` health check on a cold run; a rerun passes.
  - Checked by the review session: `setup-uv`'s `require-checksums` input
    exists at the pinned commit, and both pinned actions are their tagged
    releases.
- The merge gate was first shown with throwaway pull request #3, and again
  with throwaway pull request #4 after `review-record` became a required
  status check (A-GH-GATE, A-REV-GATE).
- Earlier on 2026-11-21: the specification was reviewed by two independent
  sessions and revised; the review of each milestone was decided (ADR 0024,
  `11-review.md`). `v2` was pushed once by the planning session, with the
  user's approval, so that M0 has a base for its pull request. From then on
  nothing is pushed to `v2` directly.

## Waiting on the user

| Item | For | Detail |
|---|---|---|
| Approve and merge M0 | M0 | Pull request #2: the approval request appears once `review-record` is green on the closing commit. The ruleset allows a rebase merge only. |
| Review of M0's decisions | Process amendment | The session the user asked for, before the amendment is written. |
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
| M0 | Foundation | reviewed (waiting for approval): PR #2 |
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
  successful deployment to `merge-approval` required, the status check
  `review-record` from GitHub Actions required (added 2026-11-21, M0-Q2), no
  force-push, no deletion, no bypass. Because a rebase merge rewrites commit
  hashes, the review record cites finding ids, never hashes (see 11).
- Default workflow permissions: read repository contents only
  (V-GH-DEFAULT-TOKEN).
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
| 2026-11-21 | M0 review | The build's commit messages rewritten without the co-author trailer (user's decision). Correctness and security reviewers, no verifier, one fix review: 26 findings, 14 questions answered by the user. Fixes test-first, one commit per finding. `review-record` made a required check by the user and shown with throwaway PR #4 (closed unmerged). Record closed. |
