# Debugging Enclave Images with QEMU

QEMU 9.2+ includes a `nitro-enclave` machine type that can boot EIF images
locally, without AWS hardware. This is useful for testing the full enclave
boot sequence: kernel, init, NSM module, crun container launch, and
enclavia-server startup.

## Prerequisites

- **QEMU >= 9.2** — must include `nitro-enclave` machine type support.
  Available in nixpkgs (`nix shell nixpkgs#qemu`).

- **vhost-device-vsock** — userspace vsock backend for QEMU. Install with:
  ```
  cargo install vhost-device-vsock
  ```

- **Python 3** — for the heartbeat responder script.

- **KVM** (optional) — `/dev/kvm` access for hardware acceleration. Without it,
  QEMU falls back to TCG (software emulation), which is significantly slower
  (~6s to boot with KVM vs ~12s+ with TCG).

## Quick Start with Nix

The flake provides two debug VM packages that handle all the plumbing
automatically (vhost-device-vsock, heartbeat, QEMU):

### Test enclave (built-in busybox HTTP server)

```bash
# Build and boot the test enclave — no external image needed
nix build .#test-enclave --override-input enclavia-server path:../enclavia-server
nix run .#test-debug-vm --override-input enclavia-server path:../enclavia-server
```

### Custom enclave (from a Docker image)

```bash
# 1. Build the enclave from an OCI bundle
nix build .#enclave \
  --override-input enclavia-server path:../enclavia-server \
  --override-input oci-bundle path:/path/to/your/bundle

# 2. Boot it
nix run .#debug-vm \
  --override-input enclavia-server path:../enclavia-server \
  --override-input oci-bundle path:/path/to/your/bundle
```

Both scripts accept optional positional arguments for memory and CPU count:

```bash
nix run .#test-debug-vm -- 8G 4    # 8 GB RAM, 4 vCPUs
```

> **Note:** The Nix-based debug-vm scripts expect `vhost-device-vsock` and
> `qemu-system-x86_64` to be on your `PATH`. They are not pulled in as Nix
> dependencies since `vhost-device-vsock` is not yet packaged in nixpkgs.

## Manual Setup

If you prefer to run the components yourself (or need more control), here's
what the debug-vm scripts do under the hood.

### 1. Start vhost-device-vsock

This provides the vsock transport between QEMU and the host:

```bash
SOCK_DIR=$(mktemp -d /tmp/enclave-debug.XXXXXX)

vhost-device-vsock \
    --vm "guest-cid=4,socket=${SOCK_DIR}/vhost.sock,forward-cid=1" &
```

- `guest-cid=4` — the CID assigned to the enclave VM (any value >= 3 works).
- `forward-cid=1` — forwards guest vsock connections to the host's AF_VSOCK
  socket family. This allows the heartbeat responder (and any other host
  service) to listen on AF_VSOCK normally.

Wait for the socket to appear before proceeding:

```bash
while [ ! -S "${SOCK_DIR}/vhost.sock" ]; do sleep 0.1; done
```

### 2. Start the heartbeat responder

The nitro-util init binary sends a heartbeat (byte `0xB7`) to CID 3, port
9000 immediately after boot. On real AWS hardware, the Nitro hypervisor
responds. In QEMU, we need to provide our own responder:

```bash
python3 nix/heartbeat.py &
```

This listens on AF_VSOCK (`VMADDR_CID_ANY`, port 9000), receives `0xB7`, and
sends `0xB7` back. The init blocks until the heartbeat succeeds, so the
enclave won't proceed without it.

### 3. Launch QEMU

```bash
qemu-system-x86_64 \
    -M "nitro-enclave,vsock=c,id=enclavia-debug" \
    -chardev "socket,id=c,path=${SOCK_DIR}/vhost.sock" \
    -kernel /path/to/image.eif \
    -nographic \
    -m 4G \
    -smp 2 \
    --enable-kvm \
    -cpu host
```

Omit `--enable-kvm -cpu host` if KVM is not available (e.g. in a VM or CI).
QEMU will fall back to TCG with `-cpu max`.

### 4. Cleanup

Kill the background processes and remove the socket directory:

```bash
kill $VHOST_PID $HEARTBEAT_PID
rm -rf "$SOCK_DIR"
```

## What to Expect

A successful boot looks like this (abbreviated):

```
[    0.000000] Linux version 4.14.256 ...
...
[    6.xxx] nsm: loading out-of-tree module taints kernel.
[    6.xxx] NSM RNG: returning rand bytes = ...
[    6.xxx] random: crng init done
launched cmd=/bin/enclave-init
hello-server: starting on port 8080     # (or your app's output)
```

Key milestones in order:
1. **Kernel boot** — Linux 4.14 (from nitro-util blobs)
2. **NSM module load** — provides `/dev/nsm` for attestation requests
3. **Heartbeat** — init sends 0xB7 to CID 3:9000, waits for response
4. **chroot** — init enters `/rootfs` (the enclave rootfs we built)
5. **enclave-init** — our init script starts crun + enclavia-server
6. **Customer container** — crun launches the OCI bundle

## Connecting to the Enclave from the Host

Once the enclave is running, you need to connect to enclavia-server's vsock
port 5000 from the host. This requires the `vhost_vsock` kernel module, which
provides AF_VSOCK routing to guest VMs.

```bash
# Check if the module is available
modprobe vhost_vsock
```

With the module loaded, connect to the guest CID (4 by default) on port 5000:

```bash
# From your client or proxy:
# VsockStream::connect(4, 5000)   — Rust (tokio-vsock)
# socket.connect((4, 5000))       — Python (AF_VSOCK = 40)
```

> **Without `vhost_vsock`:** AF_VSOCK connections to the guest CID will fail
> with `ENODEV`. The `--forward-cid=1` option only handles guest→host
> connections (e.g. heartbeat), not host→guest. If your environment lacks this
> module (containers, some VMs), you can still test enclavia-server in debug
> mode (Unix socket) without QEMU — only the vsock transport layer differs.

## Limitations

- **NSM attestation is simulated** — the NSM module loads and `/dev/nsm`
  exists, but attestation documents contain synthetic data, not real
  hardware measurements. PCR values in the attestation won't match the
  build-time PCR values from `pcr.json`.

- **No vsock CID 3 in guest** — on real AWS Nitro, CID 3 is the parent VM.
  In QEMU, the heartbeat responder fakes this. Other code that connects to
  CID 3 will also reach the host.

- **TCG is slower** — without KVM, boot takes longer due to software CPU
  emulation (~10s for the test enclave vs ~6s with KVM). Larger EIFs will
  see a bigger difference since initramfs unpacking is CPU-bound.

- **Single-socket AF_VSOCK** — `--forward-cid 1` makes guest vsock traffic
  appear as regular AF_VSOCK connections on the host. If you need to run
  multiple enclave VMs simultaneously, use different guest CIDs.

## Standalone Script

`nix/debug-run.sh` is a self-contained bash script that does the same thing
as the Nix debug-vm packages, but without Nix. It expects the tools to be on
your PATH:

```bash
./nix/debug-run.sh result/image.eif [memory] [cpus]
```
