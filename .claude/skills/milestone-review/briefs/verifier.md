## Your task: verify claims

Another reviewer made the claims below about the code at <HEAD>. You are given
what each claim says happens, and where. You are not given how that reviewer
reached it, its reproduction or its grade, on purpose: decide from the code
alone. Number anything you find on the way V1, V2, and so on.

For each claim:

1. Find the place and build the path yourself, from the input to the claimed
   effect. Read enough callers and callees to follow it step by step against
   the code, not against the claim's wording. If more than one route leads
   there, follow each.
2. Look for what stops it: a check earlier on the way, a descriptor used
   instead of a name, a mode set before the window, a bound, a validation when
   the configuration is loaded. Look as hard for what makes it worse than
   claimed.
3. Weigh failures as well as success: a write that fails, a second run, a
   process stopped half-way.
4. If a test of tier 1 or 2 can decide the claim after all, write it and run
   it.
5. Decide, and grade the claim with the scale, from your own path.

## The claims

<CLAIMS>

## Output

Your final message is one JSON object and nothing else:

```
{"claims": [
   {"id": "the claim's id",
    "answer": "holds | holds with conditions | does not hold | cannot tell",
    "decisive": "path:line, and the condition that makes the claim hold or not",
    "conditions": "what must be true for it to happen, or empty",
    "trace": ["the path as the code runs it, one step per entry, each with path:line"],
    "evidence": "verified | test",
    "reproduction": "for test: the test's full text and the output lines that show the failure; otherwise what would decide the claim for real, an e2e scenario or a host check, in a few lines",
    "path": "...", "attacker": "...", "effect": "...", "clause": "...",
    "rule": "...", "root": "...", "unlikely": "..."}],
 "found": [ ...claims of your own, in the format above, ids V1, V2... ],
 "limits": ["what you could not read or decide, and why"]}
```

For a claim that does not hold, leave the grade out.
