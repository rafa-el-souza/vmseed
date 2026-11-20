# 0009. A fixed, verifiable baseline

Status: accepted, 2026-11-20; revised 2026-11-21

## Context

v0's hardening is a set of on/off flags (firewall, fail2ban, Samba) with
cross-dependencies checked by hand. What a machine contains depends on the
combination chosen, and nothing checks the result.

A design review also showed how a check can pass while its intent fails: a
probe that reads only the global sshd configuration, a sysctl written where
the kernel does not look, a setting counted as fine because its key is absent.

## Decision

- One baseline, always applied, with the same intent on every distro.
- Each item is a **control**: identifier, intent, mechanism per distro, and an
  executable probe.
- A few **knobs** change how a control is applied; each is known to its probe.
  No control can be switched off.
- Depth: essentials plus network and kernel sysctls. Twenty-one controls at
  release (`03-guest-baseline.md`).
- A control that cannot exist on a distro reports `n/a` with a reason. A knob
  that relaxes a control reports `skip`. Neither is shown as `ok`, and both
  are decided by the plan on the host, never by the guest.
- **A probe checks the effect, not the gesture**: the configuration sshd
  applies to each user, the value in force on each interface, the rule that
  actually grants a privilege. A declared item that is missing fails.
- Adding, removing or weakening a control needs an ADR.

## Consequences

- Every machine carries the same promise, and `verify` proves it.
- The control and its check cannot drift apart: they live in one module, and
  the documentation is generated from it.
- Less flexibility for unusual cases.
- Probes are tested against fixtures of failing states, not only passing ones.
- A report is the guest describing itself. It proves provisioning and detects
  drift. It is not intrusion detection, and the docs must say so.

## Alternatives

- **Hardening levels.** Familiar, but multiplies the test matrix, and the
  weakest level becomes the easy way out.
- **Everything optional.** Maximum flexibility, exponential combinations, no
  standard.
- **A wide CIS-style baseline.** Forty or more controls per distro: costly,
  likelier to break development tools, and largely irrelevant on a
  password-less single-purpose VM.
