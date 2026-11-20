# 0016. UEFI by default

Status: accepted, 2026-11-20; revised 2026-11-21

## Context

In v0 the firmware (`bios`, `uefi`, `uefi-secure`) is a command-line argument
defaulting to BIOS, while the image variant is a configuration key. There are
separate keys for an emulated TPM, the OVMF path and the NVRAM path.

## Decision

- Firmware is VM configuration: `firmware = "uefi" | "bios"`, default `uefi`,
  and `secure_boot = false`.
- UEFI uses libvirt's firmware autoselection, with the NVRAM file inside the
  VM's data directory.
- When Secure Boot is not requested it is declared **off** explicitly, so
  autoselection cannot pick firmware with enrolled keys for an image that has
  no signed boot chain.
- The catalog records what each image supports. Impossible combinations are
  refused before any download.
- No emulated TPM in v1.

## Consequences

- One place decides how a VM boots.
- UKI images, which are UEFI-only, need no special case.
- Each UEFI VM has an NVRAM file, kept with the VM's data.
- The host needs UEFI firmware packages; preflight reports a missing one.
- The TPM option and its troubleshooting disappear. Nothing in the guest
  consumed it.
- Secure Boot depends on which keys the host's firmware enrolls. A change of
  signing authority upstream could stop a Secure Boot VM from booting after an
  update; this is recorded as an assumption to test before release.

## Alternatives

- **BIOS by default.** No NVRAM file and no firmware package, but the legacy
  path.
- **Secure Boot by default where the image allows.** The strongest default,
  but asymmetric between distros and with more first-boot edge cases.
