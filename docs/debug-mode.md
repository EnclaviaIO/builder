# Debug mode

The builder produces an EIF that, in production, runs on AWS Nitro
hardware. On a developer laptop or a CI box there is no Nitro hypervisor,
so the same EIF needs to be bootable under QEMU instead. Debug mode is
the set of build-time and run-time choices that make that work.

This document covers what debug mode is and why each piece exists. For
hands-on "how do I boot one of these in QEMU right now," see
[debug-qemu.md](debug-qemu.md).

## Why a debug mode at all

The Nitro EIF format is just a packed kernel + ramdisks. QEMU 9.2 added a
`nitro-enclave` machine type that knows how to boot that format, so the
kernel side of "run an enclave locally" is solved upstream. The harder
parts are everything that sits between the enclave and the parent EC2
instance: vsock transport, the heartbeat from the init binary, and the
fact that real Nitro hardware exposes the parent at CID 3 while QEMU has
no such notion.

Debug mode addresses these by:

1. Using the same patched init as production. It heartbeats CID 3 (the Nitro
   parent) and CID 2 (the QEMU host) concurrently and records the responder.
2. Standing up `vhost-device-vsock` in UDS mode alongside QEMU so all
   vsock traffic flows through a directory of Unix sockets that host
   services can connect to without depending on the kernel's
   `vhost_vsock` module.

`builder build --debug` changes the measured debug-attestation trust setting;
it does not swap the kernel or init. Consequently the same purpose-built EIF
boot path works on real Nitro and in the QEMU harness.

## Data path: router to guest

Host-side software (the Enclavia router, in production) reaches the
in-enclave Noise responder through this chain:

```
router  ->  Unix socket (proxy.sock)  ->  vhost-device-vsock
        ->  virtio-vsock              ->  guest enclavia-server
```

`vhost-device-vsock` is launched in UDS mode with two socket paths:

```
vhost-device-vsock \
    --vm "guest-cid=4,socket=$VHOST_SOCKET,uds-path=$PROXY_SOCKET"
```

- `$VHOST_SOCKET`: the control channel between QEMU and the
  vhost-device-vsock daemon. QEMU is started with `-chardev
  socket,path=$VHOST_SOCKET`.
- `$PROXY_SOCKET`: the Unix listener that host applications connect to
  in order to reach guest vsock ports.

### Host to guest: the `connect PORT\n` protocol

To talk to a guest vsock port, a host process connects to
`$PROXY_SOCKET` and writes a single line: `connect <port>\n`.
vhost-device-vsock replies with `OK <port>\n` and the same socket
becomes a bidirectional byte stream to the guest's vsock port.

This is how the Enclavia router reaches `enclavia-server` on port 5000:
it opens `$PROXY_SOCKET`, sends `connect 5000\n`, and from then on
WebSocket frames are bridged to vsock bytes.

### Guest to host: `$PROXY_SOCKET_$PORT`

The reverse direction is implicit. When a guest process connects to CID
2 on some port `N`, vhost-device-vsock looks for a Unix socket at
`${PROXY_SOCKET}_${N}` on the host and opens that. Whichever host
process is listening on `${PROXY_SOCKET}_${N}` receives the connection.

This is what the heartbeat (port 9000), `egress-host` (port 5006),
`storage-host` (port 5001 + 5002), and `mock-kms` (port 5003) all use.
Each listens on a Unix socket named with the appropriate port suffix.

### Why UDS mode (not `forward-cid`)

`vhost-device-vsock` also supports a `forward-cid=1` mode that binds
AF_VSOCK ports on the host. We do not use it in the test wrappers
because of a subtle kernel routing issue: host-side `connect()` calls to
those AF_VSOCK ports go through the kernel's `vsock_loopback` module,
not through `vhost-device-vsock`. The data never reaches the guest.

UDS mode sidesteps that entirely by keeping the path in userspace. As a
bonus it does not require the `vhost_vsock` kernel module on the host,
which is not always loadable inside containers or other constrained
environments.

The hands-on guide in [debug-qemu.md](debug-qemu.md) still references
`forward-cid=1` because it predates the UDS-mode test harnesses; the
test VM wrappers below use UDS mode exclusively.

## The patched init and the CID 2 heartbeat

The Nitro init binary (from `aws-nitro-enclaves-sdk-bootstrap`) sends a
single heartbeat byte (`0xB7`) to CID 3 port 9000 immediately after
boot. On real hardware the Nitro parent replies with the same byte and
init proceeds. Without that reply, init blocks forever and the enclave
never starts.

In QEMU there is no CID 3 and vhost-device-vsock handles CID 2. The patched
init in [`nix/init-patched/`](../nix/init-patched/) is a small Go
reimplementation of the upstream init which sends to both CIDs and proceeds
with the first reply. The flake ships it in debug and production EIFs. It also
supports the maintained kernel's in-tree, built-in NSM driver, so no mismatched
out-of-tree module is loaded.

The host side of the heartbeat is `nix/heartbeat.py`. In UDS mode it
listens on `${PROXY_SOCKET}_9000` and echoes the `0xB7` byte back.

## OCI bundle namespace stripping

When the builder unpacks a customer's Docker image into an OCI runtime
bundle (using `umoci --rootless`), the resulting `config.json` is not
directly usable inside the enclave. Two unrelated obstacles, both
addressed in `patch_bundle_config` in `src/main.rs`:

- **crun's mount-namespace setup fails on an initramfs root.** OCI PID, IPC,
  UTS, time and user namespaces add no value because the enclave is the
  security boundary, not the container. The builder therefore strips all
  entries from `/linux/namespaces`. The kernel enables the namespace umbrella
  only for `CONFIG_NET_NS`, used by init itself to isolate unbound; crun does
  not create that namespace.

- **`umoci --rootless` writes UID/GID mappings** that map container UID
  0 to the build user's UID (typically 1000). Inside the enclave the
  container runs as real root (UID 0), so these mappings are wrong.
  The builder removes them.

Several smaller patches travel with these for the same reason (no
per-container devpts, no UTS hostname, no per-container mounts):
`process.terminal` is forced to false, the hostname is dropped, and all
mounts are stripped (the init script pre-mounts proc, dev, sys, tmp into the
initramfs root). The image's capability sets are otherwise left intact. OCI
ownership now survives the deterministic tar-to-cpio handoff, so the builder
no longer expands every capability set merely to compensate for files owned
by the build user.

## Egress feature gate

The production recipe treats outbound networking as a measured build feature.
Without `--egress-allowlist`, the EIF omits `enclavia-egress`, Unbound, full
iproute2, and iptables; `init.sh` already skips all outbound setup when the
egress daemon is absent. Supplying an allowlist selects the corresponding
`-egress` flake target and includes the complete stack. Storage and debug mode
remain orthogonal dimensions generated from the same Nix recipe.

## Test wrappers

The flake exposes three QEMU wrappers that stand up a full debug
environment for end-to-end testing:

- `test-debug-vm`: minimal busybox HTTP test enclave plus
  vhost-device-vsock and the heartbeat responder. Used to exercise the
  router and Noise paths. Driven by
  [`enclavia-crates/tests/run_e2e_router.sh`](https://github.com/EnclaviaIO/enclavia-crates/blob/master/tests/run_e2e_router.sh).
- `test-storage-vm`: adds `storage-host` (vsock 5001 + 5002) and
  `mock-kms` (vsock 5003) so the enclave can format, unlock, and mount
  a LUKS + btrfs volume over NBD over vsock. Used by `run_e2e_router.sh`
  in storage mode and by
  [`enclavia-crates/tests/run_e2e_storage_persistence.sh`](https://github.com/EnclaviaIO/enclavia-crates/blob/master/tests/run_e2e_storage_persistence.sh).
- `test-egress-vm`: adds `egress-host` (vsock 5006) and boots a
  workload that opens a TCP connection to `$TARGET_IP:$TARGET_PORT`
  through the in-enclave TUN + smoltcp + vsock egress stack. Used by
  [`enclavia-crates/tests/run_e2e_egress.sh`](https://github.com/EnclaviaIO/enclavia-crates/blob/master/tests/run_e2e_egress.sh).

The e2e harness scripts live in the `enclavia-crates` repo (which is
private during the beta but moving toward public). They invoke the
wrappers from this repo via `nix run`, so the two repos must be checked
out side by side.

Each wrapper allocates a fresh socket directory, sets `GUEST_CID=4`,
brings up vhost-device-vsock + heartbeat + the path-specific
host-side daemons, then launches `qemu-system-x86_64` with the matching
EIF. On exit, all background processes are killed and the directory is
removed (or preserved with `STORAGE_TEST_DIR` for the storage
persistence test).
