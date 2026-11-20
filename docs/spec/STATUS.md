# Status

Updated at the end of every session. Newest state first.

## Now

- **2026-11-21.** The specification was reviewed by two independent sessions
  (technical soundness; security) and revised. No Python code yet. The `v2`
  branch exists locally with these documents; nothing has been pushed.
- **Next:** M0 (Foundation). See `09-milestones.md`.

## Waiting on the user

| Item | For | Detail |
|---|---|---|
| GitHub token | M0 | Fine-grained, this repository only: Contents RW, Pull requests RW, Actions R; Workflows RW only for milestones that change CI (M0, M1, M6). Nothing else. Then `gh auth login` on the dev VM. |
| Protection of `v2` and `main` | M0 | Pull request required; successful deployment to `merge-approval` required; no bypass, administrators included; no force-push; no deletion. |
| Environment `merge-approval` | M0 | The user as required reviewer; self-review prevention off. |
| `libvirt-client` on the dev VM | M0, M1 | Provides `virt-xml-validate` for the contract tier. `sudo dnf install libvirt-client`. |
| Review scheme | Any milestone review | The user will describe it. A provisional process is in `09-milestones.md`. |
| Host-check batch 1 | After M1 | Written by the M1 session. Run only from a merged branch. |

## Milestones

| # | Milestone | State |
|---|---|---|
| M0 | Foundation | not started |
| M1 | Walking skeleton | not started |
| M2 | Configuration | not started |
| M3 | Distros and baseline | not started |
| M4 | Lifecycle | not started |
| M5 | Verify and keygen | not started |
| M6 | Images and firmware | not started |
| M7 | Network and shares | not started |
| M8 | Recipes and examples | not started |
| M9 | Documentation and release | not started |

## Host-check batches

| Batch | When | State | Result |
|---|---|---|---|
| 1 | after M1 | not written | |
| 2 | start of M7 (share spike) | not written | |
| 3 | after M7 | not written | |
| 4 | before release | not written | |

## Dev VM facts (2026-11-20)

- Fedora 44 guest, 1 vCPU, 1 GiB RAM, about 3 GB free in `/home`. No sudo, no
  KVM, no libvirt.
- Present: Python 3.12, 3.13, 3.14 (uv), `sshd`, `ssh-keygen`, `nft`,
  `unshare` (user namespaces work), `shellcheck`, `xmllint`, `jq`, `gpgv`,
  `qemu-img` 10.2.2, `cloud-init` 26.1, `passt`.
- Absent: `virsh`, `virt-xml-validate`, any ISO tool, `gh` authentication.
- PyPI is reachable.

## Session log

| Date | Session | Outcome |
|---|---|---|
| 2026-11-20 | Planning | Decisions taken with the user; spec and ADRs 0001 to 0023 written. |
| 2026-11-21 | Design review | Two independent reviews (42 findings). Spec and ADRs revised; four decisions re-taken with the user: two-boot verification, control/data split, share model, vmseed's own `known_hosts`. |
