# 06. Images

## Model

- The **catalog** is a versioned data file shipped with vmseed. Each entry pins
  one image by URL and digest.
- At run time vmseed downloads, checks the digest, and checks that the image
  is safe to open. No listing is scraped and no signature tool is needed on
  the host.
- Upstream **signatures are verified when the catalog is refreshed**, by a
  maintainer tool that runs in CI and opens a pull request.

The root of trust is data shipped with vmseed in both this model and the v0
model (a key fingerprint there, a digest here). The catalog trades "always the
newest image" for reproducibility and for immunity to upstream renames.

**A digest establishes identity, not safety.** It proves the bytes are the
expected ones. It says nothing about what those bytes make a tool open. Every
image, from the catalog or user-defined, also passes the safety check in 04
before it is used.

## Catalog entry

`src/vmseed/data/catalog.toml`:

```toml
[fedora-44]
distro       = "fedora"
release      = "44"
arch         = "x86_64"
url          = "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2"
digest       = "sha256:<filled by the refresh tool>"
size         = 0            # bytes; filled by the refresh tool
virtual_size = 0            # bytes; filled by the refresh tool
firmware     = ["uefi", "bios"]
secure_boot  = true
```

| Key | Meaning |
|---|---|
| `distro` | Selects the `Distro` (see 01). |
| `release`, `arch` | Informational, and inputs to the refresh tool. |
| `url` | Where to download. Transport security is not relied upon. |
| `digest` | `<algorithm>:<hex>`; `sha256` or `sha512`, whichever upstream signs. |
| `size` | Expected size in bytes. A download is aborted as soon as it exceeds it. |
| `virtual_size` | The disk size the image declares, used by preflight. |
| `firmware` | Firmware kinds the image boots under. |
| `secure_boot` | Whether the image has a signed boot chain. |

## Supported matrix at release

"Supported" means present in the catalog and booted in CI.

| Id | Image | Firmware | Secure Boot |
|---|---|---|---|
| `fedora-44` | Fedora Cloud Base Generic 44 | uefi, bios | yes |
| `fedora-45` | Fedora Cloud Base Generic 45 | uefi, bios | yes |
| `fedora-44-uki` | Fedora Cloud Base UEFI-UKI 44 | uefi | yes |
| `fedora-45-uki` | Fedora Cloud Base UEFI-UKI 45 | uefi | yes |
| `alpine-3.24` | Alpine 3.24, cloud-init variant, VM kernel | uefi, bios | no (A) |

Known file names on 2026-11-20 (the refresh tool is the authority):

```
Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2
Fedora-Cloud-Base-UEFI-UKI-44-1.7.x86_64.qcow2
Fedora-Cloud-Base-Generic-45-1.4.x86_64.qcow2
Fedora-Cloud-Base-UEFI-UKI-45-1.4.x86_64.qcow2
alpine-3.24.4-x86_64-cloudinit-r0.qcow2
```

Alpine notes: the `cloudinit` bootstrap variant is used, not `tiny`, so both
distros share one seed generator. The non-`metal` variant is the VM kernel.
Alpine 3.24 images use the Limine boot loader, which handles BIOS and UEFI
according to its published metadata; booting under each is still to be
confirmed (see 10). The Secure Boot capability marked (A) is an assumption.

`x86_64` only in v1. The `arch` field exists so another architecture is a
catalog and matrix change, not a redesign.

## User-defined images

```toml
[images.alpine-custom]
distro      = "alpine"
url         = "https://example.org/alpine-custom.qcow2"   # or: path = "/abs/file.qcow2"
digest      = "sha512:0000"
firmware    = ["uefi"]
secure_boot = false
```

- Same schema as a catalog entry. `digest` is always required.
- `virtual_size` is optional here; without it the size check runs after the
  download.
- A `path` image is copied into the cache through the same hashing path. It is
  never used in place.
- An id that collides with a catalog id is an error.
- `distro` must be a registered distro.
- A user-defined image is the user's own trust decision. The safety check
  still applies: it stops the image from reading host files at creation, not
  from being a hostile guest.

## Cache

`<host.cache_dir>/images/<algorithm>-<hex>.qcow2`

The cache directory must be owned by the invoking user and not writable by
anyone else; otherwise it is refused.

Algorithm for `ensure(entry)`:

1. Take the per-image lock.
2. If the final file does not exist: download to `<final>.part`, streaming,
   with a progress display, bounded retries and a timeout, aborting as soon as
   the size exceeds `size`. Check size, then digest. On mismatch delete the
   partial file and fail. `rename` to the final name.
3. **Re-hash the final file** against the digest. A cached file is never
   trusted by its name alone: a cache may have been restored from a backup or
   from a CI cache.
4. Run the safety check (04).

The fetcher uses the standard library, follows redirects, and never executes
or interprets the payload. The cache is content-addressed, so entries pointing
at the same bytes share a file.

## Refresh tool

`tools/refresh_catalog.py` is a maintainer tool, not part of the CLI. It needs
network access and `gpgv`. It rewrites `catalog.toml`.

Each distro has an `ImageSource` with two operations: discover candidates, and
return a verified digest, size and virtual size.

**Fedora**

1. Read the release's `Cloud/x86_64/images/` listing and find the `CHECKSUM`
   file.
2. Verify its OpenPGP signature with `gpgv` against the release signing key,
   pinned by full fingerprint.
3. From the verified text, take the SHA-256 and the byte size of the Generic
   and UEFI-UKI qcow2.

**Alpine**

1. Read the release's `releases/cloud/` listing; select the newest
   `alpine-<version>-x86_64-cloudinit-r<N>.qcow2` (not `metal`). Several
   revisions of one version can coexist.
2. Download the image and its detached `.asc` signature.
3. Verify the signature with `gpgv` against the Alpine cloud images key,
   pinned by full fingerprint (`F26A DFAD BAE7 02EF 7AF6 3745 9DA7 EF23 BFFC
   DF22` as published on the Alpine cloud page on 2026-11-20).
4. Compute the SHA-512 of the verified file.

Rules:

- Keys are vendored under `tools/keys/` and pinned by full fingerprint in the
  tool. How each fingerprint was obtained is recorded next to it.
- A candidate that fails verification never reaches the catalog.
- **No downgrade.** The tool never replaces an entry with an older version,
  compose or revision, whatever a mirror lists.
- The tool changes only `url`, `digest`, `size` and `virtual_size`.
  Capabilities are edited by hand and proven by e2e.
- **Signature verification exists from M1**, for the first image the catalog
  holds. No catalog digest is ever taken on trust from the server that hosts
  the image.

### Reviewing a catalog change

A digest cannot be checked by eye, and a check that runs the pull request's
own code only proves that the pull request agrees with itself. Therefore:

- the scheduled `catalog` job runs the tool **from the protected branch** and
  opens the pull request;
- for any other pull request that touches the catalog, the keys or the tool, a
  required check recomputes the digests with the tool **from the base
  branch**, without checking out the pull request's code;
- the pull request must also pass the e2e matrix, which proves the image
  boots, not where it came from.

Alpine renamed its image files three times within the 3.23 series and again
within 3.24. Discovery patterns are expected to need maintenance; that cost is
confined to this tool and never reaches users.

## Staleness

A pinned image ages. This is acceptable because the baseline upgrades every
package during the first boot (UPD-01). The catalog is refreshed on a schedule
and when a new release is added.
