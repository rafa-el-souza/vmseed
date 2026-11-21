## Your task: security

Read the commits <BASE>..<HEAD> as each attacker the scale marks as existing
would. This review was set off by changes to: <TRIGGER>. Number your claims
S1, S2, and so on.

1. **Where their bytes come in.** List every place in the changed code where
   data an attacker controls enters: the report and console channels, the
   output of commands run over SSH, files and names in a VM's data directory,
   downloaded bytes, a tool's error message, the files of a pull request in a
   workflow.

2. **Where they can end up.** Follow each one to its sinks: a path that is
   opened, created or deleted; an argument list or a generated script; an
   address the host connects to; the terminal; a `known_hosts` line, a state
   record, an inventory or an `ssh-config` line; a YAML or XML document. A
   sink reached without the validation the specification names is a claim.

3. **The invariants.** For each security invariant of
   `docs/spec/01-architecture.md` that the change touches, find the code that
   holds it, then try to break it with a test: a symlink in any path
   component, a file that already exists, a name with a separator or a leading
   dash, a second record, an escape sequence, an input that is oversized or
   cut short, an image with a backing file or a data file, a URI that names a
   command.

4. **What a control promises.** For a control or a probe in the change: can
   the probe report `ok` while the intent written in
   `docs/spec/03-guest-baseline.md` does not hold? Can the mechanism leave the
   guest weaker than the control states, on either distro?

5. **Secrets and modes.** A private key read, copied or logged. A file created
   with a mode wider than the specification gives it. Something written to a
   public CI log.

6. **Workflows**, when the change touches `.github/`: what a pull request from
   a fork can run, and with which token; an action not pinned by commit; a
   permission wider than the job needs; anything that could produce a
   deployment to `merge-approval` without the owner's approval.

A claim on a `hostile` path names its attacker. A broken invariant is
`decided`, with the invariant as its rule. Acting on an attacker's input
outside what the specification allows is `boundary`.

Do not claim what needs an attacker that does not exist. Do not claim a limit
the specification already states. A defence you would add that the
specification does not ask for is a note.

## Output

Your final message is one JSON object and nothing else:

```
{"claims": [ ...claims in the format above... ],
 "notes": ["one line each: claims beyond the 15; a defence the specification does not ask for; a decision or a text of the specification that looks wrong"],
 "covered": ["one line each: the entry points and the invariants you examined, and what you ran, so that an empty report can be weighed"]}
```
