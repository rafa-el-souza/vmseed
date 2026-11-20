# 0015. A pinned image catalog

Status: accepted, 2026-11-20; revised 2026-11-21

## Context

v0 scrapes a mirror's directory listing to find the newest image and verifies
an OpenPGP signature on every run. Some mirrors block listings. Alpine renamed
its cloud image files three times within the 3.23 series and again within
3.24, so discovery by pattern is fragile. Two runs can produce different VMs.

A digest says which bytes an image is. It does not say what opening those
bytes does: a qcow2 header can name another file as its backing file or data
file, and converting such an image copies that host file into the new disk.

## Decision

- vmseed ships a versioned **catalog** that pins each image by URL and digest,
  with its size, virtual size and capabilities.
- At run time vmseed downloads and checks the digest. No listing, no signature
  tool on the host.
- **Every image is checked to be safe to open** before use, and re-hashed on
  every use: a plain qcow2, no backing file, no external data file.
- A maintainer **refresh tool** discovers new images, verifies upstream
  signatures against keys pinned by full fingerprint, never downgrades an
  entry, and opens a pull request.
- **A catalog change is checked by trusted code**: the digests are recomputed
  with the tool from the protected branch, not with the pull request's own
  code.
- Signature verification exists from the first image the catalog holds.
- Users may declare their own images, always with a digest.
- Supported at release: Fedora Cloud Base 44 and 45, Generic and UEFI-UKI, and
  Alpine 3.24 in its cloud-init variant. `x86_64` only.

## Consequences

- Reproducible, and immune to upstream renames at run time.
- The root of trust is data shipped with vmseed, as it was in v0 (a key
  fingerprint there, a digest here).
- Creating a VM cannot read host files through a crafted image.
- A newer image arrives only when the catalog is refreshed. The first-boot
  upgrade covers the gap.
- Discovery patterns need maintenance, but only in the refresh tool.
- Alpine uses the cloud-init variant, not tiny-cloud, so both distros share
  one seed generator.

## Alternatives

- **Discovery and signature at run time.** Always current, no catalog to
  maintain, but fragile, needs `gpg` on the host, and is not reproducible.
- **Hybrid** with a `latest` mode. Covers both uses with two code paths.
- **Trusting a cached file by its name.** Saves a few seconds of hashing, but
  a cache restored from elsewhere would be used unverified.
