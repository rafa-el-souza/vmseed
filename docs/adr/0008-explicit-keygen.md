# 0008. Explicit key generation

Status: accepted, 2026-11-20

## Context

v0 generates a key pair per user and per VM during the build, asking for a
passphrase in the middle of the run. The operator tool expects the private key
at `~/.ssh/<user>-<vm>`.

## Decision

- The configuration declares each user's public keys: a path or an inline key.
  The default path stays `~/.ssh/<user>-<vm>.pub`.
- `vmseed keygen <vm>` creates the missing pairs. It is the only interactive
  command and the only one that creates key material.
- `create` never prompts. A missing key is an error that prints the `keygen`
  command.
- vmseed reads public keys only, rejects a private key offered as one, and
  never deletes a key.

## Consequences

- Provisioning is non-interactive, so it can be automated and tested.
- Creating a secret is a visible, separate act.
- First use is two commands instead of one.

## Alternatives

- **Generate during `create`.** One command, but an interactive step and
  secret creation hidden inside provisioning.
- **Never generate.** No side effects in `~/.ssh`, but manual `ssh-keygen` for
  every user of every VM.
