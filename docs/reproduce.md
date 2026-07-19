# Reproducing an enclave's EIF

An Enclavia enclave's identity is its PCRs, and its PCRs are derived
from the rootfs of the EIF that booted it. If you can rebuild the same
rootfs from the same sources, you can compute the same PCRs locally
and verify that the enclave you are talking to over the wire is the
one whose source you just audited.

`enclavia reproduce <enclave-id>` is the CLI command that drives that
flow end to end. This document describes what it does, what is pinned,
and where reproducibility currently has rough edges.

## Why this matters

The trust story for Enclavia is built around attestation. An attested
session gives the client a signed document containing the enclave's
PCRs. Those PCRs are determined entirely by what is inside the EIF: the
kernel, the init, the in-enclave services, the customer's container,
and a small set of build-time configuration files (`enclavia-config.json`,
`/etc/enclavia/egress.json`).

That signed document only tells you "the enclave's PCRs are X." It does
not tell you whether X is the X you expected. The expected X has to
come from somewhere outside the enclave, and the only honest answer is:
"rebuild the EIF from the same inputs and check." Reproducibility is
not a nice-to-have here, it is the only way the attestation chain
closes.

## What is pinned, what is not

The reproducible inputs are deliberately small and deliberately
content-addressed:

- **The Docker image, by digest.** When the backend builds an EIF for
  enclave row `e`, it resolves `e.docker_image` (a tag like
  `<registry>/<owner>/<repo>:<tag>`) to its content-addressed digest
  and stores `e.image_digest` next to it. The CLI rebuilds from the
  digest, not the tag, so a later push to the same tag cannot mutate
  what `reproduce` sees.

- **`flake.lock` revs for `builder` and `enclavia-crates`.** The
  backend reads its own deployment's `flake.lock` at startup and
  stamps `e.builder_rev` and `e.crates_rev` onto each new enclave row.
  These are git revisions, so the reproducer can pin to the exact
  source tree the backend was running.

- **The egress allowlist JSON.** The user-supplied document is stored
  verbatim on the row (`e.egress_allowlist`). At build time the
  builder stages it at `/etc/enclavia/egress.json` in the archived
  rootfs payload. Changing it changes PCR2.

- **The storage configuration** (size, mount point). Same story as
  the egress allowlist: it lives on the row and is baked into
  `enclavia-config.json`.

The OCI bundle is passed across the Nix boundary as a deterministic,
uncompressed tar archive rather than as an unpacked path. After patching the
runtime bundle, the builder removes umoci's per-host bookkeeping
(`umoci.json`, `sha256_*.mtree`) and asks umoci to serialize the final payload
with `SOURCE_DATE_EPOCH=1`. That serializer understands umoci's rootless
ownership marker, so tar headers contain the container UID/GID rather than the
build user's IDs; it also retains hardlinks, complete mode bits, and supported
xattrs. The flake input directory contains only `bundle.tar`, making the NAR
hash a hash of opaque archive bytes.

`enclave.nix` converts that tar directly to the final Linux `newc` archive and
appends it as the last user ramdisk. There is no unpacked Nix store output in
between. The direct conversion retains the metadata fields representable by
initramfs (`mode`, UID/GID, inode/link identity, and device numbers). Linux's
[`newc` initramfs format](https://www.kernel.org/doc/html/latest/driver-api/early-userspace/buffer-format.html)
has no xattr or ACL fields, so those remain in the transport tar but cannot be
represented by the current initramfs format. See
[builder#10](https://github.com/EnclaviaIO/builder/issues/10) for the original
reproducibility history.

The kernel and init blobs come from `nitro-util/blobs/x86_64/` (Linux
4.14 for the base EIF, plus our `linuxManualConfig` kernel build for
the storage-enabled variant). These are reproducible upstream: the
flake's `nitro-util` input is pinned to a specific revision in
`flake.lock`, so anyone rebuilding with the same lockfile gets the
same blobs.

## The flow

`enclavia reproduce <enclave-id>` does the following:

1. **Fetch the build provenance from the backend.** `GET /enclaves/<id>`
   returns the canonical image reference, `image_digest`, `builder_rev`,
   `crates_rev`, `egress_allowlist`, the storage block, and the PCRs the
   backend recorded at build time.

2. **Rebuild the EIF locally.** The CLI invokes
   `nix build path:<builder-rev>#<eif-name>` (where `<eif-name>` is
   `enclave` or `enclave-storage` depending on the row), passing
   `--override-input enclavia-crates path:<crates-rev>` and, for the
   image input, a deterministic OCI payload archive produced from the
   pinned digest. The builder binary is the same one the backend ran,
   just driven by the CLI.

3. **Compare PCRs.** The local rebuild produces a `pcr.json` next to
   the EIF. The CLI compares that against the PCRs the backend
   reported. A match means the running enclave was built from sources
   you have on disk, in front of you.

The reproducer does not need any trust in the backend beyond "did it
tell me the right digest and revs." If it lied, the local PCRs will
not match the attested PCRs and the chain breaks.

## What `enclavia reproduce` surfaces about egress

The egress allowlist is part of the rootfs (it lives at
`/etc/enclavia/egress.json`), so it is covered by PCR2. The
reproducer surfaces the allowlist document from the row alongside the
PCRs so the user can see exactly which destinations the running
enclave is allowed to reach. Changing the allowlist necessarily
changes PCR2, which means a fresh attestation, which means clients can
notice that the egress posture has changed.

## Known limits

- **Initramfs cannot carry xattrs or ACLs.** The deterministic tar preserves
  them across Nix, but Linux's `newc` archive has no fields for them. A future
  rootfs format would be needed to expose them inside the enclave.

- **`flake.lock` revs are only as good as the deployment's discipline.**
  The backend stamps whatever its own `flake.lock` says at startup.
  A deployment that builds from a dirty working tree, or that skips
  setting `FLAKE_LOCK_PATH`, ends up with NULL revs on new enclave
  rows and reproduce cannot pin sources.

- **The image registry is not part of the trust boundary.** A digest
  pins the image content, but if the registry ever serves different
  bytes for the same digest (it should not, by design) the chain
  silently breaks. There is no signature check beyond the registry's
  TLS, today.

- **Hardware attestation is real, debug-mode attestation is synthetic.**
  Reproduce works against both, but only the production path provides
  Amazon-rooted signatures on the attestation document. Debug-mode
  PCRs are still useful for local "did the rebuild match" checks; they
  are not useful for trusting a remote enclave you do not control.
