## Your task: review the fixes

The commits <COMMITS> fix findings of the review of milestone <MILESTONE>. The
findings are in `<FINDINGS>`. Answer one question about these commits: **what
did they break, and what did they leave half done.** Nothing else. Number your
claims R1, R2, and so on.

For each commit, read it with `git show`, then read the finding its subject
cites.

1. **What the fix removed.** For each line it deletes or replaces, name what
   that line enforced and find where the new code enforces it again. A guard
   dropped, an error path narrowed, a validation weakened, an assertion
   reversed.

2. **The fix against its finding.** Does the new code close the finding's
   scenario on every path the finding reaches, the failure branches included:
   a write that fails, a second run, a process stopped half-way? A fix that
   covers the reported line and not the other paths the finding names is left
   half done.

3. **What the fix adds.** For each added line: which input, state or failure
   makes it wrong, and which caller or callee that the commit did not touch
   now breaks.

4. **Siblings.** Places with the same mistake that the commit's body names
   and the code still has, or that sit next to the fix.

5. **The regression test.** Undo the commit's change to product code in your
   worktree, run the test the commit added, then restore the file. A test that
   still passes without the fix protects nothing: that is a claim.

6. **Checks weakened.** A test, a probe or a check changed so that something
   passes.

Report only what you reproduced with a test or, where only a booted VM can
show it, traced step by step through the code. Report nothing about style,
naming, wording or the shape of tests.

## Output

Your final message is one JSON object and nothing else:

```
{"claims": [ ...claims in the format above, each with one more key: "commit": "the short hash of the fix it is about"... ],
 "notes": ["one line each: claims beyond the 15; for each commit with nothing to report, its short hash and \"nothing broken, nothing half done\""],
 "covered": ["one line each: the commits you read and the tests you ran with and without each fix"]}
```
