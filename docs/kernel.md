# Purpose-built enclave kernels

Both base and storage EIFs use a maintained kernel built from
`linuxPackages_latest`, pinned by `flake.lock`. The base image no longer ships
the Linux 4.14 kernel or out-of-tree NSM module from `nitro-util`. Updating the
nixpkgs lock updates both profiles together and changes the measured EIF PCRs.

`nix/enclave-kernel.config` is a reviewed common policy seed, not a copied
distribution `.config`. `nix/kernel-config.nix` combines it with
`nix/enclave-storage-kernel.config` for storage images and runs
`make ARCH=x86_64 allnoconfig`. This matters: unspecified features resolve off,
rather than taking new upstream defaults when the kernel is updated. The
generator then fails if a requested option did not resolve, a forbidden option
resolved to `y` or `m`, any module exists, or the resolved built-in count exceeds
500 for base / 600 for storage.

## Required and retained capabilities

| Capability | Profile | Why it is retained |
|---|---|---|
| x86-64 SMP (up to the existing 128-vCPU limit), ACPI/MP discovery, KVM guest clocks | both | Nitro Enclaves and the QEMU `nitro-enclave` machine |
| relocatable XZ-compressed bzImage | both | EIF loading, KASLR, and smaller kernel payload |
| gzip initramfs decompression | both | all EIF system and user ramdisks are `cpio.gz` |
| proc, sysfs, devtmpfs, tmpfs, devpts | both | fatal mounts performed by `init-patched` and `init.sh` |
| ELF/scripts, futex, epoll and fd/timer/signal events | both | Go, Rust/Tokio, libc and customer process ABI |
| cgroups v1 device controller | both | patched init mounts enabled controllers and crun applies OCI device policy |
| seccomp filters | both | crun applies the workload's OCI syscall policy |
| IPv4, Unix sockets and virtio-vsock | both | local workload proxying and all enclave/host services |
| virtio-mmio command-line discovery and built-in NSM | both | Nitro has no usable PCI bus (`pci=off`) and `/dev/nsm` must exist before userspace |
| network namespace, veth and TUN | both | isolated unbound resolver and userspace egress transport |
| legacy IPv4 iptables filter table | both | the single resolver-source anti-spoof `OUTPUT ... DROP` rule |
| NBD with the AF_VSOCK patch | storage | block I/O to `storage-host` over vsock |
| device mapper, dm-crypt, AES-XTS | storage | LUKS2 data-volume encryption |
| Btrfs with POSIX ACLs | storage | the only persistent filesystem and normal data-volume permissions |

Modules are disabled; NSM, vsock, console, networking and storage drivers are
built in. Retained production hardening includes KASLR, randomized kernel-stack
offsets, strict kernel W^X, strong stack canaries, fortified copies, hardened
usercopy/slab/list handling, and current x86 CPU vulnerability mitigations.
These are defense-in-depth controls, not optional LSM policy engines.

`NET_NS` is the only selectable namespace type retained. Current kernels build
mount-namespace code unconditionally and cgroup-namespace code with the
required cgroup core; those are not independent Kconfig options. The OCI
configuration contains no namespace requests, so crun does not instantiate
them.

## Deliberate exclusions

The policy rejects SELinux and the other heavyweight LSM/integrity stacks;
NFS/NFSD and all other network filesystems; ext4, SquashFS, XFS, F2FS, FUSE and
OverlayFS; IPv6 and IPv6 netfilter; nftables, conntrack, NAT and unused iptables
tables/targets; PCI and physical network/storage drivers; KVM host support and
32-bit ABIs; profiling, perf, tracing, probes, debugfs, symbols and sanitizers;
ORC/frame-pointer unwind metadata, io_uring/AIO/core dumps; and loadable
modules. The zero-overhead guess unwinder remains for basic panic diagnostics.
Only `RD_GZIP` is retained for initramfs input. `KERNEL_XZ` is independent: it
compresses the bzImage itself, not an initramfs. Kernel keyrings are also
omitted; the storage init passes
`--disable-keyring` to cryptsetup so its LUKS2 volume key goes directly to
dm-crypt.

Btrfs necessarily selects its on-disk checksum, RAID and zlib/LZO/Zstd
compatibility helpers. dm-crypt similarly selects the crypto template helpers
needed to instantiate AES-XTS. Those transitive options are part of the storage
format implementation, not general-purpose initramfs decompressors.

## Verification on an x86_64 Linux builder

Policy resolution is much cheaper than compiling the kernels and produces the
complete configs plus exact option-count reports:

```sh
nix build .#packages.x86_64-linux.enclave-kernel-config \
  -o result-base-kernel-config
nix build .#packages.x86_64-linux.enclave-storage-kernel-config \
  -o result-storage-kernel-config
cat result-base-kernel-config/report
cat result-storage-kernel-config/report
```

Build both kernels and representative EIFs:

```sh
nix build .#packages.x86_64-linux.enclave-kernel \
  -o result-base-kernel
nix build .#packages.x86_64-linux.enclave-storage-kernel \
  -o result-storage-kernel
nix build .#packages.x86_64-linux.test-enclave \
  -o result-base-eif
nix build .#packages.x86_64-linux.test-enclave-storage-debug \
  -o result-storage-eif
```

Then run the existing non-storage and storage QEMU harnesses on a Linux host
with the real `enclavia-crates` input. A successful storage run must create the
NBD device, open the LUKS mapping, mount Btrfs and report backing-file I/O; the
base run must reach the test workload and vsock server.

```sh
nix run .#test-debug-vm
nix run \
  --override-input enclavia-crates path:../enclavia-crates \
  .#test-storage-vm
```

## Size accounting

The previous storage config contained 1,016 built-ins and 44 modules. Each
reviewed seed now requests 115 common built-ins plus 11 storage-only built-ins
and no modules. Those seed counts exclude dependencies selected by Kconfig, so
each generated config records its authoritative resolved count and reduction in
`result/report`. `nix build .#packages.x86_64-linux.kernel-size-report` also
records both current bzImage and representative EIF byte sizes, plus the base
kernel's reduction from the retired Linux 4.14 blob. Linux CI publishes this
report in the job summary.

Kernel and full-EIF before/after numbers must be taken from the same x86_64
builder, nixpkgs lock, OCI bundle and input overrides. Build the baseline commit
and this commit with distinct `-o` links, locate the baseline storage kernel in
the EIF closure (`nix-store -qR <result>`, selecting the path containing
`bzImage`), then produce the checked table with:

```sh
sh nix/size-report.sh \
  BASELINE_BASE/bzImage CURRENT_BASE/bzImage \
  BASELINE_STORAGE/bzImage CURRENT_STORAGE/bzImage \
  BASELINE_BASE/image.eif CURRENT_BASE/image.eif \
  BASELINE_STORAGE/image.eif CURRENT_STORAGE/image.eif
```

Do not compare NAR closure sizes: the relevant attack-surface and delivery
metrics are the compressed `bzImage` embedded in the EIF and `image.eif` itself.
