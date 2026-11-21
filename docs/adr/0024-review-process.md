# 0024. Review: a separate session, a graded record, fixes reviewed once

Status: accepted, 2026-11-21

## Context

Milestones are built by sessions that start without context, and one person
approves every merge. ADR 0023 left the review of each milestone open, with a
provisional rule: a separate session reviews, findings carry a severity, and
each defect is reproduced by a test before its fix.

Four facts shape a lasting rule.

- **A reviewer's finding is a claim.** Some are wrong. Fixing a claim that was
  never shown to be real changes code for nothing.
- **A fix is new code written late**, with less attention than the feature it
  touches. A rule that obliges fixing everything a reviewer writes down spends
  most of its effort on what no user meets, and creates defects of its own.
  The working assumption here is that few findings change what a user gets
  (recorded as A-REV-YIELD, to be checked on this project's own counts).
- **This project can decide most claims by execution.** Tier 1 and 2 tests run
  on the development machine in seconds. Only what needs a booted VM cannot be
  shown there.
- **The tool's promise is security**, so some paths that an ordinary product
  would ignore are the product here: input from a guest, from a directory
  another account can write, from a download.

Left to judgment, three things go wrong: the session that would do the fixing
decides what deserves fixing; severity grows with the reviewer's wish to see
something fixed; and a rule that lives only in instructions is forgotten when
a session runs long.

## Decision

1. **Two sessions per milestone.** A build session implements and opens the
   pull request with CI green. A review session, started by the user with no
   memory of the build, runs the review round, makes the fixes and closes the
   record.
2. **Reviewers are agents with literal briefs.** The review session launches
   them with a fresh context, fills the briefs' placeholders and adds nothing.
   The briefs are versioned in `.claude/skills/milestone-review/`.
3. **Two first-look reviewers.** A correctness reviewer always. A security
   reviewer when the change touches a closed list of paths or code patterns;
   it reads the change as each attacker that exists, and may assume no other.
4. **A test decides a claim.** A reviewer works in its own worktree and
   reproduces each claim with a failing tier 1 or 2 test. A claim only a
   booted VM can show is marked as inspection.
5. **A verifier only where no test can decide.** Inspection claims that would
   be fixed, or put to the user, go to a second agent that receives the claim
   without the first one's reasoning.
6. **A grade from closed lists, and a plan derived from it.** Each finding has
   a path, an effect and at most one clause. The plan is `fix` when an honest
   user meets the defect on an ordinary path, or when a clause holds on any
   path: a destructive operation, a boundary crossed by an attacker that
   exists, a decided rule broken, a sibling of such a finding. Otherwise the
   finding is recorded with its condition and not fixed. A script derives the
   plan. The reviewer grades; the review session changes no grade.
7. **Questions go to the user with an assumption applied.** The session does
   not wait and does not decide for the user.
8. **Fixes are test-first, one commit per finding**, recorded only after the
   round's findings are committed.
9. **The fixes are reviewed once.** One agent asks what the fixes broke or
   left half done, and checks by running it that each regression test fails
   without its fix. It runs only if product code was fixed. A second pass runs
   only over fixes that changed a destructive operation or the handling of an
   attacker's input. Never a third.
10. **The record is a file in the repository**, one per milestone, checked by
    `tools/findings.py`. The approval job in CI depends on it: no approval is
    requested while the file is missing or a finding is open.
11. **All review agents run on Opus at maximum effort.**
12. **The counts are kept from the first milestone**, so that the next change
    to this process is decided on numbers.

The process and the scale are in `docs/spec/11-review.md`.

## Consequences

- The user starts two sessions per milestone, and is asked for approval once,
  when the record is closed.
- What is fixed does not depend on who found it or who fixes it. A defect on a
  forced path that no clause covers stays in the code, written down. It can
  reach real use and become a fix of its own. That price is accepted.
- The findings of every milestone are public, next to the code.
- The limits on an agent are its brief and its separate worktree, not a
  sandbox. And the record states that a review ran; it does not prove it.
- M0 has to build the findings tool and the CI gate, and its own review is the
  first run of the process.
- The provisional rule of ADR 0023 is replaced.

## Alternatives

- **The build session runs its own reviewers.** One session per milestone
  instead of two. The session that wrote the code would brief the reviewers
  and sort their findings, at the end of a long context.
- **Three sessions: build, review, fix.** The most separation. A third start
  per milestone, and a fixing session that has to learn code the reviewing
  session has just studied.
- **A verifier for every claim.** One more agent per round to confirm by
  reading what a test confirms by running.
- **No verifier.** Every claim that needs a boot would go to the user, who is
  the worst placed to decide it.
- **Severity with a threshold.** Familiar, but the grade is the reviewer's
  judgment, and the user ends up deciding the rest one by one.
- **Fix everything that is confirmed.** The simplest rule and the most fixes,
  including polish and paths nobody walks.
- **A fix reviewer only for sensitive areas, or none.** A list to keep right,
  with harmless-looking fixes outside it; or nobody looking at what fixes
  broke.
- **Security as one more angle of a single reviewer.** One agent less;
  attention divided on what the tool promises.
- **Findings only in the pull request, or only on the development machine.**
  Nothing CI can check, and nothing the next session finds without an API or
  that machine.
