# Enclavia Builder

This repository turns a Docker image into an AWS Nitro Enclave Image File
(EIF). It ships two things: a Nix flake that pins every byte of the
enclave rootfs (kernel, init, in-enclave services, OCI bundle), and a
small Rust CLI (`builder`) that drives the flake from a registry
reference.

The builder is part of the Enclavia trust kernel. Its outputs are PCR
measured: PCR0 covers the kernel + ramdisks, PCR2 covers the application
rootfs. The reproducibility story (see [docs/reproduce.md](docs/reproduce.md))
depends on this repo: a customer rebuilds the same EIF from the same
inputs, computes PCRs locally, and compares them against what the
backend reports for a running enclave.

## How it is invoked

Humans rarely run this directly. In production the Enclavia backend
shells out to the `builder` binary, passing a registry reference and
auth material. A typical invocation looks like:

```
builder build \
    --image registry.enclavia.io/<owner>/<repo>:<tag> \
    --registry-token <signed-bearer> \
    --output-dir ./out \
    --container-port 8080 \
    --enclave-id <uuid> \
    --egress-allowlist ./egress.json
```

Flags (see `src/main.rs` for the source of truth):

| Flag | Purpose |
|------|---------|
| `--image` | Docker image reference to pull (registry/repo:tag). |
| `--registry-user`, `--registry-password` | HTTP Basic credentials for the source registry. |
| `--registry-token` | Pre-minted bearer token; bypasses the auth realm round-trip. Mutually exclusive with the user/password pair. |
| `--output-dir` | Directory to write `image.eif` and `pcr.json` (default `./out`). |
| `--container-port` | Port the customer's container listens on inside the enclave (default `8080`). |
| `--debug` | Build with debug-attestation trust anchors for local QEMU testing. All profiles use the same dual Nitro/QEMU heartbeat init. See [docs/debug-mode.md](docs/debug-mode.md). |
| `--storage` | Build the storage-capable variant (LUKS + Btrfs over NBD over vsock). Adds the minimal storage kernel profile and `enclavia-crypto`. |
| `--control-pubkey` | Base64-encoded ECDSA P-256 public key (65 raw bytes, uncompressed SEC1) for the management control channel. |
| `--enclave-id` | Per-enclave identifier stamped into `enclavia-config.json`, so two enclaves built from identical inputs still get distinct PCRs. |
| `--image-digest` | Registry manifest digest (`sha256:<hex>`) of the image being built, stamped into `enclavia-config.json` for the in-enclave chain-init helper. |
| `--egress-allowlist` | Path to the egress allowlist JSON. Its presence enables the measured egress stack and bakes the policy at `/etc/enclavia/egress.json`; absent means deny-all and omits the stack entirely. |
| `--synchronizer-pcrs` | Synchronizer trust anchors for the storage anti-rollback wiring: a pcr.json path or inline JSON carrying one or more `{PCR0,PCR1,PCR2}` hex triples. Written into `enclavia-config.json` as `synchronizer.expected_pcrs` together with `debug_attestation` (mirrors `--debug`); when absent no `synchronizer` section is written. |
| `--synchronizer-enabled` | Turn the anti-rollback wiring ON: writes `synchronizer.enabled = true`, which the EIF init reads to export `SYNCHRONIZER_ENABLED=1` for the in-enclave nbd-client. Requires `--synchronizer-pcrs` (an enabled wiring with no expected oracle PCRs fail-stops at boot). Omit to bake the anchors disabled (flip on with a later rebuild). |

## What it produces

A successful `builder build` writes two files into the output directory:

- `image.eif`, the EIF image suitable for `nitro-cli run-enclave` (or
  QEMU's `nitro-enclave` machine type, in debug mode).
- `pcr.json`, the build-time PCR0 / PCR1 / PCR2 values.

The same two values are also printed to stdout as JSON on success, so a
calling process can consume them directly.

## Flake outputs

- `nix build .#builder`: the `builder` Rust binary itself.
- `nix build .#enclave[-debug]` / `.#enclave-storage[-debug]`: build a
  deny-all EIF without the egress stack. Add `-egress` before the optional
  `-debug` suffix (`.#enclave-egress-debug`,
  `.#enclave-storage-egress-debug`) to include outbound networking. Every
  target consumes a deterministic OCI payload archive supplied as
  `bundle.tar` inside the directory passed via
  `--override-input oci-bundle path:<archive-input-dir>`; production callers
  go through the `builder` CLI rather than invoking the flake directly.
- `nix build .#enclave-kernel[-config]` /
  `.#enclave-storage-kernel[-config]`: build or audit the two minimal
  kernel profiles. `.#kernel-size-report` records resolved option counts
  and bzImage sizes.
- `nix build .#test-debug-vm`: a wrapper that launches a minimal
  busybox-HTTP test enclave under QEMU with vhost-device-vsock
  stitched in. Used by the router e2e tests.
- `nix build .#test-storage-vm`: same idea, with storage-host +
  mock-kms running alongside QEMU so the enclave can mount its LUKS +
  btrfs volume over NBD over vsock.
- `nix build .#test-egress-vm`: same idea, with egress-host listening
  on vsock 5006 so the in-enclave workload can dial a host-routable
  TCP destination through the TUN + smoltcp path.

See [docs/debug-mode.md](docs/debug-mode.md) for the architecture
behind the QEMU wrappers and [docs/reproduce.md](docs/reproduce.md)
for the reproducibility story. The reviewed kernel capabilities,
exclusions, verification and size-accounting procedure are in
[docs/kernel.md](docs/kernel.md).

## License

Licensed under either of Apache License, Version 2.0, or MIT license, at
your option.
