# Architecture decision records

One decision per file. Records 0001 to 0023 were taken with the user on
2026-11-20, and 0024 on 2026-11-21. Records marked "revised 2026-11-21" were
changed after two independent design reviews (technical soundness, and
security); where a revision altered what the user had decided, the user
decided again.

To change a decision: gather the evidence, ask the user, then amend the record
or add a new one that supersedes it. Never work around a record.

| # | Decision |
|---|---|
| [0001](0001-python-rewrite-in-the-same-repository.md) | Python rewrite in the same repository |
| [0002](0002-scope-provisioning-factory.md) | Scope: a provisioning factory, not a VM manager |
| [0003](0003-virsh-and-generated-domain-xml.md) | `virsh` plus generated domain XML; local connections only |
| [0004](0004-integration-contract-and-adopted-vms.md) | Integration contract, vmseed's own `known_hosts`, adopted VMs |
| [0005](0005-other-user-hypervisor-compatibility.md) | Compatible with a hypervisor run by another user |
| [0006](0006-toml-fleet-file.md) | One TOML fleet file |
| [0007](0007-vm-directory-and-independent-disk.md) | Control and data directories, independent disk |
| [0008](0008-explicit-keygen.md) | Explicit key generation |
| [0009](0009-fixed-verifiable-baseline.md) | A fixed, verifiable baseline |
| [0010](0010-users-with-roles.md) | Users as a list with roles |
| [0011](0011-nftables-everywhere.md) | nftables on every distro |
| [0012](0012-restricted-recipes.md) | Recipes: trusted code with guard rails |
| [0013](0013-virtiofs-shares-samba-and-fail2ban-removed.md) | virtiofs shares (guest writes, host reads); Samba and fail2ban removed |
| [0014](0014-updates.md) | Updates during the first boot and automatically |
| [0015](0015-pinned-image-catalog.md) | A pinned image catalog, with a safety check |
| [0016](0016-uefi-by-default.md) | UEFI by default |
| [0017](0017-mandatory-network-kind.md) | The network kind is mandatory; the endpoint comes from the configuration |
| [0018](0018-serial-console-report.md) | Two boots, reports over a dedicated serial channel |
| [0019](0019-post-provision-lockdown.md) | Lockdown between the two boots |
| [0020](0020-toolchain-and-distribution.md) | Toolchain and distribution |
| [0021](0021-testing-strategy.md) | Testing strategy |
| [0022](0022-extensibility-by-composition.md) | Extensibility by composition |
| [0023](0023-execution-process.md) | Execution process and merge gate |
| [0024](0024-review-process.md) | Review: a separate session, a graded record, fixes reviewed once |
