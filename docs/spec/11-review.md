# 11. Review

Every milestone is reviewed before the user is asked to approve it. This file
is the process and the scale. The briefs the reviewers receive, word for word,
are in `.claude/skills/milestone-review/`. The reasons are in ADR 0024.

## Principles

1. **A finding is a claim until something decides it.** A failing test decides
   it. Where no test can run on the development machine, a second reader who
   never saw the first one's reasoning decides it.
2. **A rule decides what is fixed.** Not the reviewer who found it, and not
   the session that would fix it. A finding gets a grade from closed lists,
   and its plan follows from the grade.
3. **A fix is a change.** It can break what worked. So fixes are few, each has
   a test seen failing first, and the fixes of a round are reviewed once.
4. **The record is in the repository.** CI does not ask for the user's
   approval while a finding is open.
5. **What is not fixed is written down with its reason** and shown to the user
   once, at approval.

## Who does what

| Role | Who | Does |
|---|---|---|
| Build session | A session that implements the milestone | Builds, opens the pull request, gets CI green. It does not review its own work and does not write the findings file. |
| Review session | A new session, with no memory of the build, started by the user | Runs the round below: launches the reviewers, records their claims, fixes what the plan says, launches the fix reviewer, closes the record. |
| Correctness reviewer | An agent launched by the review session | Reads the range for defects against the code and the specification. |
| Security reviewer | An agent, launched when the trigger matches | Reads the range as each attacker that exists. |
| Verifier | An agent, launched only for claims no local test can decide | Rebuilds each claim from the code, without the reviewer's reasoning. |
| Fix reviewer | An agent, launched once if product code was fixed | Answers one question about the fix commits: what did they break or leave half done. |
| `tools/findings.py` | A script | Checks the record against the lists, derives each plan, lists open findings, computes the security trigger. |
| The user | | Answers questions, may pick a recorded finding to be fixed, approves, merges. |

Every agent runs on the Opus model at maximum effort, with a fresh context, in
a git worktree of its own, one agent at a time. Its final message is its
report. The review session saves each report whole, outside the repository.

The review session holds these judgments and no others:

- which paths the range covers and which criteria of the milestone apply;
- when a finding becomes a question for the user (the cases are listed under
  "Questions");
- how each fix is written.

It does not change a grade, drop a claim, or fix a finding the plan records.

## The round

```
BUILT        pull request open, `ci` and `e2e` green, build session ended
  |
REVIEWING    the correctness reviewer, then the security reviewer if triggered
  |
VERIFYING    only if a claim that would be fixed rests on inspection
  |
RECORDED     every claim is in the findings file, committed before any fix
  |
FIXING       one commit per finding, its test seen failing first
  |
FIX REVIEW   once, if a fix changed product code: its claims are recorded,
  |          then fixed; a second pass only in the case below, never a third
QUESTIONS    the user answers what only the user can decide
  |
CLOSED       every finding has an outcome; the summary is in the pull request
  |
APPROVAL     the user reads, may pick a recorded finding, approves, merges
```

Product code means `src/`, `tools/`, `.github/` and `examples/`: not tests,
documents or the findings file.

| State | Entry | What happens | Exit |
|---|---|---|---|
| BUILT | The build session reported | The user starts a new session with `/milestone-review <PR>` | The review session has checked out the head and found `ci` and `e2e` green |
| REVIEWING | A range fixed as two commit hashes: the merge base with `v2`, and the head | The correctness reviewer runs, once, or once per scope above 1 000 changed lines of product code. Then the trigger is computed and, if it matches, the security reviewer runs. | Each report is saved whole |
| VERIFYING | At least one claim whose grade plans a fix has `inspection` as evidence | One verifier receives those claims only | Each such claim is `verified`, `not confirmed` or a question |
| RECORDED | All claims graded | One commit, `docs(findings): record the M<N> review`: the round's header and every claim, with its plan. No fix is in it or before it. | `findings.py check` passes |
| FIXING | The record is committed | Each finding planned `fix`: test first and seen failing, then the fix, one commit whose subject ends with the finding's id. Sibling search where the rule asks for it. Questions keep their assumption. | No finding planned `fix` is left without its fix or its question |
| FIX REVIEW | A fix changed product code | One fix reviewer over the round's fix commits. Its claims are graded and recorded in a commit of their own before their fixes. No sibling search in this pass. | No claim planned `fix` is left |
| Second pass | A fix made in the fix review changed a destructive operation, or code that handles input from an attacker that exists | The fix reviewer once more, over those fixes only | Done. There is never a third pass: what remains is the user's to read. |
| QUESTIONS | The fixes are done and a question is open | The session asks the user with a question box. Each answer is recorded in its question and applied. If the user is not there, the session reports the questions and the record stays open. | Every question has an answer |
| CLOSED | The last fix and the last answer | One commit, `docs(findings): close the M<N> review`: every outcome, the round's header complete, `STATUS.md`. The summary goes into the pull request's description. CI green again. | `findings.py open` prints nothing |
| APPROVAL | The record is closed, so the approval request exists | The user reads the summary and may pick recorded findings to be fixed | Approved and merged; or decisions to apply (see "After the user's decisions") |

Above 1 000 changed lines of product code in the range (added plus deleted),
the correctness reviewer runs once per scope:

- `core`: `src/vmseed/config/`, `catalog/`, `guest/`, `plan.py`,
  `templating.py`, `errors.py`;
- `edge`: `src/vmseed/host/`, `ops/`, `state.py`, `cli.py`, `display.py`,
  `tools/`, `.github/`, `examples/`.

A round interrupted by the end of a session is continued by a new one from
the findings file and the commits: nothing about the round lives only in a
conversation.

Commits that add or change behaviour after the reviewed head, other than
fixes that cite a finding, get a round of their own over those commits.

## What the reviewers look for

The briefs are literal text in the skill; the review session fills their
placeholders and changes nothing else. In short:

- **Correctness.** Each changed line against the input, state, failure or
  platform that makes it wrong; behaviour removed by the change; callers and
  callees; the pitfalls of Python, of generated shell, YAML and XML, and of
  file and process handling; fakes that accept what the real tool rejects;
  each acceptance criterion and each rule of the milestone's sections traced
  through the code; a probe or a test that cannot fail; what the change relies
  on and did not change.
- **Security.** For each attacker that exists: where its bytes enter the
  changed code and where they can end up. For each security invariant of 01
  the range touches: where the code holds it, and an attempt to break it.
- **Not reported:** style, naming, formatting, typing, reuse, simplification,
  efficiency, structure, comments, the wording of documents, the shape of
  tests; hardening beyond what the specification asks; a limit the
  specification already states; disagreement with a decision. A reviewer that
  believes a decision cannot work says so in a note, and the review session
  turns it into a question.
- There is no floor: a reviewer returns what is real, and an empty report is a
  valid report. At most 15 claims per report; anything beyond them is named in
  a note, one line each, so nothing is dropped silently.

## The scale

A claim's **grade** is its path, its effect and its clause. Each comes from a
closed list. The reviewer writes its reproduction first, as steps or as a
test, and reads the grade off it: what the steps need is the path, what the
failing assertion shows is the effect. It states what the lists give, never
what it would like to see fixed.

### Path

The path is forced only when the reproduction needs one of the last five rows.

| `path` | The reproduction needs |
|---|---|
| `ordinary` | Nothing below. An honest user running documented commands with a fleet file, valid or not, on a supported host and image. This includes the failures the specification names: a guest that never reports, an interrupted `create`, a missing tool, a refused image. |
| `hostile` | One of the attackers that exist (see "Attackers"). The claim names it. |
| `tool` | Something made by hand that vmseed does not document as input: an edited state record or cache file, a domain changed behind vmseed, a module called directly. The fleet file, recipes, command-line options and environment variables of 02 are documented input. |
| `race` | Two things at the same instant: a reproduction that cannot be written as steps done one after another. Two commands run one after the other are `ordinary`. |
| `failure` | An internal failure the specification does not name: the process killed, a full disk, a power cut, a tool that crashes. |
| `unsupported` | A platform outside the supported matrix: another architecture, or a host or an image that 06 and 08 do not list. |

### Effect

There is an effect only when the list holds it. When two fit, it is the first
of `lost`, `exposed`, `misreport`, `wrong`, `blocked` that holds.

| `effect` | What happens |
|---|---|
| `lost` | Data is lost, or a file is deleted or overwritten that the command was not asked to touch. |
| `exposed` | Something the specification keeps private or closed becomes reachable: a file mode, a secret in a log, a port, a guest setting weaker than a control states. |
| `misreport` | vmseed states something false: a control `ok` whose intent does not hold, a summary or an exit code that contradicts what happened, a document that describes behaviour the code does not have. |
| `wrong` | Something vmseed produces or stores is wrong: a domain definition, a seed, a guest script, a state record, an inventory, a `known_hosts` line, a catalog entry. |
| `blocked` | A documented command cannot complete, does something other than asked, or completes only another way. |
| `none` | Nothing above. |

### Clause

At most one. When two hold, it is the first in this order.

| `clause` | When | Also required |
|---|---|---|
| `destructive` | Data lost, or success reported after a failure, in an operation that deletes or overwrites: `destroy`, the cleanup after a failed `create`, the `known_hosts` rewrite, a state record write, a cache replacement. On any path, `failure` and `tool` included. | |
| `boundary` | An attacker that exists makes vmseed act outside what the specification allows: read, write or delete a path, run a command, connect to an address, show control characters, accept bytes that were not verified. | `path = "hostile"` |
| `decided` | What was decided is absent, or the opposite, in the code: an acceptance criterion of the milestone, a rule of the specification, a security invariant of 01, a code rule of `CLAUDE.md`, an ADR. | `rule` names it |
| `sibling` | The same mistake as another finding, elsewhere in the code. | `root` names that finding, whose own plan is `fix` by a clause or by an effect other than `blocked` |

When the specification's own text is what is wrong, ambiguous or silent, the
claim is not `decided`: it is a question.

### In doubt

- A path that fits no forced row is `ordinary`.
- A reviewer that finds an ordinary sequence improbable still writes
  `ordinary`, and says why in `unlikely`. The lists change only by the user's
  decision, on what the records count.

### The plan

The first row that holds.

| `plan` | When |
|---|---|
| `question` | The finding has a `question`. |
| `fix` | A clause holds; or the path is `ordinary` and the effect is not `none`. |
| `record` | Anything else: a forced path with no clause, or no effect. |

`tools/findings.py` derives the plan from the grade and refuses a file whose
`plan` says otherwise.

### Who grades

- A reviewer grades its own claims.
- The verifier grades the claims it receives. Its grade replaces the
  reviewer's, and the difference is noted in the finding.
- A defect the user reports, or that CI or real use reveals after the review,
  is recorded by the session that meets it, graded the same way, with `source`
  saying where it came from.
- The review session never grades a reviewer's claim and never changes a
  grade. If it disagrees, it raises a question.

## Evidence

| `evidence` | Meaning |
|---|---|
| `test` | A test of tier 1 or 2 fails on the reviewed head because of the defect. The reviewer wrote and ran it in its worktree. Its text is in the report and becomes the regression test. |
| `ci` | An end-to-end test fails in a CI run, cited by its URL. Used when only a boot can show the defect: the failing test is pushed as a commit of its own before the fix. |
| `inspection` | Read from the code. No test of tier 1 or 2 can decide it. |
| `verified` | An inspection claim that the verifier rebuilt and held. |

A claim with `inspection` as evidence whose grade plans a fix goes to the
verifier, even when it also carries a question: the user is not asked about a
defect nobody confirmed. A claim that would only be recorded is not verified:
it is only written down.

The verifier receives, for each claim, its id, file, line, summary, scenario
and, when the claim names one, the rule. It does not receive the reviewer's
reasoning, reproduction or grade. It builds the path from the code itself and
answers:

| Answer | What follows |
|---|---|
| `holds`, `holds with conditions` | Evidence becomes `verified`. The verifier's grade stands. |
| `does not hold` | No fix. The outcome is `not confirmed`, with the decisive point. It appears in the summary. |
| `cannot tell` | A question for the user, with what would decide the claim: an e2e scenario, or a host check. |

If the verifier finds that a local test can decide the claim after all, it
writes and runs it, and the evidence is `test`.

## Attackers

A claim may assume only an attacker that exists. The list changes by the
user's decision.

| Attacker | Exists | What it controls |
|---|---|---|
| `guest` | yes | Everything inside a VM once it boots: the bytes on the console and report channels, the output of what `verify` runs over SSH, the content of the VM's disk and firmware variables. |
| `data-dir` | yes | Another local account that can write a VM's data directory (ADR 0005): it plants symlinks, and pre-creates or replaces the fixed file names. |
| `download` | yes | The bytes fetched from a mirror (images, checksum files, signatures) and the network path to the mirror. |
| `local-user` | yes | Another unprivileged account on the host: it reads what file modes allow, creates files in shared directories, connects to loopback ports. |
| `contributor` | yes | Someone who opens a pull request against the public repository: the code and the workflow files of that pull request, as far as GitHub runs them. |
| The invoking user | no | Whoever can write the fleet file, the recipes, the control directory or the user's environment already holds the user's privileges. The rules of 02 for those inputs are decided rules, not defences against this actor. |
| Root, the kernel, the hypervisor | no | A guest that escapes the hypervisor, or an account that controls the hypervisor of its own VM, is outside what vmseed defends (ADR 0005). |
| Physical access, the hosting service | no | |

## When the security reviewer runs

It runs when the range changes a file under one of these paths:

```
src/vmseed/host/       src/vmseed/ops/        src/vmseed/guest/
src/vmseed/catalog/    src/vmseed/data/       src/vmseed/state.py
src/vmseed/display.py  src/vmseed/templating.py
src/vmseed/config/loader.py   src/vmseed/config/models.py
tools/                 examples/              .github/
pyproject.toml         uv.lock                constraints.txt
.claude/skills/milestone-review/
```

or adds, in any other file under `src/`, a line that contains one of:

```
subprocess  Popen  os.open  os.unlink  os.rename  os.replace  os.chmod
os.chown  os.umask  shutil.  tempfile.  urllib  shlex  yaml.load  pickle
eval(  exec(
```

`tools/findings.py trigger <base>..<head>` prints what matched. The round's
header records it, or records `not triggered`, so the user can check the
decision against the diff.

## The findings file

One file per milestone: `docs/findings/m<N>.toml` (`m3a.toml` for a slice).
The review session writes it; `tools/findings.py` checks it. It is public, so
its text follows these rules: English; paths relative to the repository root;
no local path, account name or host name; output from a guest or from CI only
when bounded and passed through the sanitiser; no secret.

```toml
milestone = "M3"
pr = 12

[[round]]
n = 1
base = "3f2c1ab"              # merge base with v2
head = "9d41e07"              # the reviewed head
date = 2026-12-01
correctness = "ran"           # or "ran: core, edge"
security = "ran"              # or "not triggered"
security_trigger = ["src/vmseed/guest/controls/ssh.py"]
verifier = "not needed"       # or "ran"
fix_review = "ran"            # or "ran twice", or "not needed"

[[finding]]
id = "M3-F04"
round = 1
source = "correctness"        # correctness | security | verifier | fix-review
                              # | sibling-search | user | ci
ref = "C4"                    # the reviewer's own id
file = "src/vmseed/guest/controls/ssh.py"
line = 88
summary = "SSH-07 passes when the guest serves two host keys."
scenario = "A guest with an ed25519 and an RSA host key reports SSH-07 ok."
evidence = "test"
reproduction = "tests/unit/guest/test_ssh_controls.py::test_two_host_keys_fail"
path = "ordinary"
effect = "misreport"
clause = "decided"
rule = "03 SSH-07"
plan = "fix"
outcome = "fixed"

[[question]]
id = "M3-Q1"
findings = ["M3-F09"]
text = "The specification does not say what `list` shows for a VM whose data directory is missing."
options = ["Show it as drifted", "Refuse with exit 5"]
recommendation = "Show it as drifted"
assumption = "Shown as drifted"
answer = ""                   # the user's decision, in their words
```

Other keys of a finding, present only when they apply: `attacker` (with
`path = "hostile"`), `root` (with `clause = "sibling"`), `about` (for a claim
of the fix reviewer: the finding whose fix it is about), `unlikely`,
`question` (the question's id), `picked` (a recorded finding the user chose to
have fixed), `note`.

A point where a reviewer says the specification is wrong, ambiguous or silent
is recorded as a finding with `effect = "none"` and a question.

Identifiers: `M<N>-F<nn>` for findings and `M<N>-Q<n>` for questions, in order
of recording across the milestone's rounds. They start with the file's
`milestone` value, and the file's name is the first part of the branch name:
`m3a-primitives` gives `docs/findings/m3a.toml` and `M3a-F01`.

A reviewer's own ids (`C` for correctness, `S` for security, `V` for what the
verifier found on the way, `R` for the fix reviewer) stay in `ref`. Commits
and summaries cite the finding's id. **Nothing in the record is a commit hash
except the round's two ends:** a merge by rebase rewrites hashes, so a fix is
found by its finding's id in the commit subject (`git log --grep M3-F04`).

Every claim a reviewer reports becomes a finding, including the ones that end
`not reproduced` or `not confirmed`. The counts come from the file.

### Outcomes

A finding is open while `outcome` is empty.

| `plan` | Allowed `outcome` |
|---|---|
| `fix` | `fixed`; `not reproduced` (the test written first did not fail); `not confirmed: <the decisive point>` (the verifier's answer) |
| `question` | The same three; or `kept as built: <the decision>`; or `deferred: <where it is tracked>`. All but `not reproduced` and `not confirmed` need the user's answer in the question. |
| `record` | `recorded: forced path (<path>)`; `recorded: no effect`; or `fixed` with `picked = true` when the user chose it |

A finding closed as `fixed` has `test`, `ci` or `verified` as evidence, unless
the user decided the fix in a question or picked it. A finding the user
picked ends `fixed`: until then its outcome stays empty, so it keeps the
record open.

### The tool

`tools/findings.py`, standard library only, covered by its own tests:

| Command | Does |
|---|---|
| `check [files]` | Refuses an unknown key, a value outside a list, a clause without what it requires, a `plan` that differs from the derived one, an outcome the plan does not allow, a duplicate or foreign id, a home-directory path in a text field. With no file, it checks every file under `docs/findings/`. |
| `open [files]` | Prints findings with no outcome and questions with no answer; exits 1 if there is one. |
| `count [files]` | Per source: claims, by plan and by outcome. The numbers the next change to this process will be decided on. |
| `summary <file>` | The Markdown section for the pull request. |
| `trigger <base>..<head>` | What matched the security trigger. |
| `gate <branch>` | For a milestone's branch (`m<N>-<slug>`): the milestone's file exists, `check` passes and `open` prints nothing. For any other branch: passes, saying no record is required. |

A test compares the lists inside the tool with the tables of this file.

### The gate in CI

The `approval` workflow has two jobs. `review-record` runs
`findings.py gate`. `approve` needs it, and is the job bound to the
`merge-approval` environment. So no approval is requested, and none can be
given, before the record exists and is closed. During the build the
`review-record` job is red: that is its meaning, not a failure to fix.

## Fixing

- **The record comes first.** No fix is made before the commit that records
  the round's claims, so every fix can be read against what it answers.
- **One finding, one commit, test first.** The test is run and seen to fail
  before the fix is written. For a defect only a boot can show, the failing
  e2e test is pushed as its own commit, and the red run is cited as evidence
  before the fix follows. The subject ends with the finding's id:
  `fix(report): refuse a second host-key record (M3-F04)`. The body names the
  mistake in one line.
- **A test that does not fail** closes the finding as `not reproduced`. The
  test stays when it is a useful guard.
- **Siblings.** For a finding fixed under a clause, or for `lost`, `exposed`,
  `misreport` or `wrong` on an ordinary path, the fixer searches the code for
  the same mistake. Each instance is a finding of its own (`source =
  "sibling-search"`, `clause = "sibling"`), fixed the same way. For any other
  finding there is no search.
- **No redesign inside a fix.** A fix closes its finding's scenario and
  nothing else. If that needs a decision, it is a question.
- **A fix never weakens a test, a probe or a check to pass.**
- **Recorded means not fixed.** A finding planned `record` is left as it is.
  The user may pick it at approval.

### Questions

Only the review session sets a question, in these cases:

1. The specification's own text is wrong, ambiguous or silent on the point.
2. The fix would change a decision, or needs a design the finding does not
   settle.
3. The fix would leave the milestone's scope, change `.github/` in a
   milestone that does not change CI, or amount to building a part of the
   milestone that was left out. A review does not finish a build: the user
   decides who does.
4. The verifier answered `cannot tell`.
5. The claim can be decided only on the user's host. It also becomes an item
   of the next host-check batch.
6. The review session disagrees with a grade. It says so, with its reason. It
   still changes nothing.

A question carries its options, a recommendation and the assumption the
session applied meanwhile. The session does not wait: it goes on with the
other findings, and asks the user with a question box at the end, or at once
if nothing else can proceed.

## The fix review

One question, over the fix commits of the round: **what did these fixes break,
and what did they leave half done.** For each fix commit the fix reviewer
reads the finding it cites and checks:

1. behaviour the fix removed: a guard, an error path, a validation, an
   assertion;
2. the fix against its finding, on every path the finding reaches, the
   failure branches included;
3. what the fix adds, and the callers and callees it did not touch;
4. siblings the fix names and did not cover;
5. by running it: that the regression test fails without the fix;
6. a test, a probe or a check weakened to make something pass.

Its claims are graded like any, recorded in a commit of their own, then fixed.
It reports nothing about style and nothing it could not reproduce or trace.

## Closing, and what the user reads

The closing commit fills every outcome and updates `STATUS.md`. The pull
request's description gets a "Review" section from `findings.py summary`:

- the counts, by reviewer and by plan;
- each question, with its options, the recommendation, the assumption
  applied and the user's answer;
- each finding recorded and not fixed, one line, with its condition;
- each claim not reproduced or not confirmed, with the decisive point;
- what the security trigger matched, or that it did not;
- what is still unverified on a real VM.

That section, the findings file and the diff are what the user needs. The
reviewers' full reports are on the development machine for when a finding
deserves a closer look.

### After the user's decisions

An answer given after the review session ended, or a recorded finding the user
picks at approval, is applied by a new session started the same way. It
records the decision, fixes test-first, runs the fix review again only if
product code changed, and closes the record again.

## Records kept outside the repository

Each agent's final message is saved whole under
`$XDG_CACHE_HOME/vmseed-dev/review/<milestone>/round-<n>/` (`correctness.md`,
`security.md`, `verifier.md`, `fix-review.md`). They may contain local paths,
so they are never committed and never pasted into a pull request.

## What this process is worth

- The reviewers read a diff. One angle asks what the change relies on and did
  not change; beyond that, a defect in older code, an incoherence in the
  specification, and whether the tool is pleasant to use are found by the user
  and by real use.
- The limits on an agent are its instructions and its separate worktree. They
  are not a sandbox.
- The record says a review ran. Nothing proves it. The user's reading is the
  check.
- Behaviour that only a booted VM shows is decided by CI, or by a host check,
  never on the development machine.
- A finding on a forced path that no clause covers is not fixed. It can reach
  real use and become a fix of its own. That is the price accepted, and the
  counts exist to show when it is too high.

## Changing the process

By an ADR, with the user. The closed lists, the attackers and the trigger
change only by the user's decision, on what `findings.py count` and the
`unlikely` fields show, and on any later defect that traces back to a finding
that was recorded and not fixed.
