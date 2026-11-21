## Your task: correctness

Find defects in the commits <BASE>..<HEAD> under these paths: <PATHS>. Read
the tests that exercise them too. Number your claims C1, C2, and so on.

Work through each angle below on its own. Do not let the conclusion of one
silence another.

A. **Line by line.** Read every hunk and the function around it. For each
   changed line ask which input, state, failure or platform makes it wrong: an
   inverted condition, an off-by-one, `None` or an empty value, an exception
   swallowed or caught too broadly, a wrong variable, a missing bound, bytes
   taken for text, a path taken for a string.

B. **What the change removed.** For each line deleted or replaced, name what
   it enforced and find where the new code enforces it again: a guard, an
   error path, a validation, a test case.

C. **Callers and callees.** For each changed function, find its callers and
   check each call against the new precondition, return value, exception and
   order of effects. Check what it calls the same way.

D. **Pitfalls of the materials.**
   - Python: a mutable default; a closure over a loop variable; the
     truthiness of `0`, `""` and empty containers; `is` against a value; a
     generator used twice; a regular expression that `$` or `match` leaves
     open at the end; an encoding or an `errors=` left to the default; a
     model that coerces or ignores what it should refuse.
   - Processes: a value placed where an option could be read; a missing
     `--`; a return code not checked; no timeout; output decoded without a
     rule; a signal or an interruption that leaves a half-made state.
   - Files: a check and a use on a name instead of a descriptor; a symlink
     followed; a mode left to the umask; a write that is not atomic where the
     specification says it is; a temporary file in a shared directory.
   - Generated text: a script that is not POSIX `sh`, or that BusyBox `ash`
     runs differently; a value not quoted; a YAML scalar that changes type
     when read back (`no`, `1e3`, a leading zero); XML or YAML assembled from
     strings.

E. **Seams and fakes.** An adapter forwards what its callers use. A fake
   accepts only what the real tool accepts: a fake more lenient than the tool
   hides defects from every unit test that uses it.

F. **The specification.** For each acceptance criterion of the milestone and
   each rule of the sections you were given, trace what the code does against
   what the text says: the exit code, the message, the order of steps, the
   refusal. A rule the code does not meet, or meets on one path only, is a
   claim with the clause `decided`.

G. **Tests and probes that cannot fail.** A probe that passes while its
   control's intent does not hold. A test named by an acceptance criterion
   that passes when the behaviour it names is broken. A golden file that
   blesses a wrong value. Show it by breaking the behaviour in your worktree
   and running the test.

H. **What the change relies on.** What does this code assume that it did not
   change and that no test here checks: an earlier module, a tool's
   behaviour, a row of `docs/spec/10-assumptions.md`? If you can show the
   assumption false, it is a claim. If it is only unverified, it is a note.

## Output

Your final message is one JSON object and nothing else:

```
{"claims": [ ...claims in the format above... ],
 "notes": ["one line each: claims beyond the 15; a decision or a text of the specification that looks wrong; anything outside this brief that the user should see"],
 "covered": ["one line each: what you read and what you ran, so that an empty report can be weighed"]}
```
