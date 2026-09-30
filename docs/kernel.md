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
619 for base / 669 for storage.

The generator takes a `kernelArch` argument, `x86_64` (the default) or
`aarch64`. The x86_64 policy and everything below up to
[aarch64 (Graviton) base profile](#aarch64-graviton-base-profile) describe the
x86_64 kernels that this repository's own EIFs use.

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
32-bit ABIs; profiling, tracing, probes, debugfs, symbols and sanitizers;
ORC/frame-pointer unwind metadata, io_uring/AIO/core dumps; and loadable
modules. The zero-overhead guess unwinder remains for basic panic diagnostics.
Only `RD_GZIP` is retained for initramfs input. `KERNEL_XZ` is independent: it
compresses the bzImage itself, not an initramfs. Kernel keyrings are also
omitted; the storage init passes
`--disable-keyring` to cryptsetup so its LUKS2 volume key goes directly to
dm-crypt.

Linux 7.1 requires the generic `PERF_EVENTS` core on x86 and selects the
`DEBUG_KERNEL` umbrella when `EXPERT` exposes the minimal-policy controls.
Those two symbols remain enabled so the supported x86 configuration compiles;
the concrete profiling, tracing, debugfs, debug-info and sanitizer facilities
remain disabled.

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
nix build .#packages.x86_64-linux.test-enclave-storage \
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

Each reviewed seed requests 119 common built-ins plus 11 storage-only built-ins
and no modules. Those seed counts exclude dependencies selected by Kconfig, so
each generated config records its authoritative resolved count and budget in
`result/report`. `nix build .#packages.x86_64-linux.kernel-size-report` also
records both current bzImage and representative EIF byte sizes, plus the base
kernel's reduction from the retired Linux 4.14 blob. Linux CI publishes this
report in the job summary.

Kernel and full-EIF before/after numbers must be taken from the same x86_64
builder, nixpkgs lock, OCI bundle and input overrides. Build the earlier commit
and this commit with distinct `-o` links, locate the earlier storage kernel in
the EIF closure (`nix-store -qR <result>`, selecting the path containing
`bzImage`), then produce the checked table with:

```sh
sh nix/size-report.sh \
  BEFORE_BASE/bzImage AFTER_BASE/bzImage \
  BEFORE_STORAGE/bzImage AFTER_STORAGE/bzImage \
  BEFORE_BASE/image.eif AFTER_BASE/image.eif \
  BEFORE_STORAGE/image.eif AFTER_STORAGE/image.eif
```

Do not compare NAR closure sizes: the relevant attack-surface and delivery
metrics are the compressed `bzImage` embedded in the EIF and `image.eif` itself.

## aarch64 (Graviton) base profile

The synchronizer's Graviton (c7g/c8g) Nitro Enclaves use an aarch64 build of
the base profile. This repository does not assemble aarch64 EIFs itself; it
exports the kernel and its resolved config for consumers such as the enclavia
repository's synchronizer EIF.

There is no aarch64 storage profile. Its only consumer is the synchronizer,
which does not use NBD, dm-crypt or Btrfs, so `kernelArch = "aarch64"` with
`storage = true` fails at evaluation. Adding one would need its own review of
the storage options on arm64.

### How it is built

Both the config and the kernel are cross-built on the x86_64 builder with
nixpkgs' `pkgsCross.aarch64-multiplatform` GCC, from the same pinned
`linuxPackages_latest` source as the x86_64 kernels. The cross build is the
canonical, reproducible build: its output is what the measured PCRs are
computed from, and a native aarch64 build is not expected to be bit-identical.
The policy is resolved with `make ARCH=arm64 CROSS_COMPILE=... allnoconfig`,
because Kconfig probes compiler features (`cc-option`) and those probes must
see the compiler that builds the kernel. The same request, forbidden-option,
no-module and built-in budget checks apply; the resolved config has 500
built-ins and no modules, and the budget is 500.

The seed is `nix/enclave-kernel-aarch64.config`. It is a complete seed rather
than a fragment on top of `nix/enclave-kernel.config`, because the x86_64 seed
mixes x86-only lines into its common sections, and keeping that file unchanged
keeps the x86_64 store paths and EIF measurements unchanged. Sections without
an `arm64:` note are the architecture-neutral policy; a change to the neutral
sections of one seed must be made in the other seed too.

### What differs from x86_64, and why

| Area | x86_64 | aarch64 | Why |
|---|---|---|---|
| Kernel image | XZ-compressed `bzImage`, 16 MiB `PHYSICAL_ALIGN` | uncompressed `Image` | the arm64 enclave firmware loads a plain `Image`; there is no self-decompressor, so `KERNEL_XZ` and the bzImage initrd-placement constraint do not apply |
| Firmware and device discovery | ACPI/MP tables; virtio-mmio devices passed as `virtio_mmio.device=` arguments | device tree only (`linux,dummy-virt`); `ACPI` and `EFI` off; `VIRTIO_MMIO_CMDLINE_DEVICES` off | the Nitro arm64 enclave firmware provides no ACPI tables and no UEFI; the UART, RTC and virtio-mmio devices (NSM, vsock) are all device-tree nodes |
| Console | 8250 at the legacy I/O port | 8250 via `SERIAL_OF_PLATFORM` | the UART is a device-tree MMIO node at `0x40001000` |
| Wall clock | kvm-clock | PL031 RTC: `RTC_CLASS`, `RTC_HCTOSYS`, `RTC_DRV_PL031` | **required**: arm64 KVM has no paravirtual wall clock. Without the PL031 driver the enclave boots at 1970 and X.509 validity checks during attestation verification fail |
| CPU mitigations | `MITIGATION_*` set | `UNMAP_KERNEL_AT_EL0`, `MITIGATE_SPECTRE_BRANCH_HISTORY` | arm64 equivalents of page-table isolation and branch-history defenses |
| Hardware hardening | none | `ARM64_PTR_AUTH` (+ `_KERNEL`), `ARM64_BTI` (userspace), `ARM64_E0PD`, `ARM64_EPAN` | Graviton3 (Neoverse-V1) and Graviton4 (Neoverse-V2) implement these. `ARM64_BTI_KERNEL` is unavailable with GCC |
| Errata | none | `ARM64_ERRATUM_3194386`, `ARM64_ERRATUM_4118414` | Neoverse-V1/V2 workarounds that are default-y upstream but dropped by `allnoconfig` |
| Pages and address space | fixed by x86_64 | 4K pages, 48-bit VA, 48-bit PA | see below |
| 32-bit ABI | `IA32_EMULATION`, `X86_X32_ABI` off | `COMPAT` off | no 32-bit userspace |

`ARM64_VA_BITS` is pinned to 48 (and `ARM64_PA_BITS` to 48); `allnoconfig`
would otherwise pick the 52-bit default. 52-bit virtual addresses with 4K pages
need FEAT_LPA2, which Neoverse-V1/V2 do not implement, so the kernel would fall
back to 48 bits at runtime while still carrying the LPA2 and five-level
page-table code. Upstream also warns that 52-bit VA reduces the pointer
authentication code from 7 to 3 bits. 48 bits gives 256 TiB of virtual address
space, far more than any enclave has. Compared with the 52-bit default, the only
resolved-config changes are the VA/PA bit counts, `ARM64_LPA2` off and
`PGTABLE_LEVELS` 5 to 4.

### Consuming the aarch64 kernel

The outputs exist only for the `x86_64-linux` system, because the build is a
cross build from x86_64:

| Output | Contents |
|---|---|
| `packages.x86_64-linux.enclave-kernel-aarch64` | `Image`, `System.map` |
| `packages.x86_64-linux.enclave-kernel-config-aarch64` | `config`, `seed`, `report` |
| `packages.x86_64-linux.eif-init-aarch64` | `bin/init`: the EIF init from `nix/init-patched`, statically linked |

Output names select profile and architecture: `enclave-` is the base profile
and `enclave-storage-` the storage profile; x86_64 outputs have no suffix and
aarch64 outputs end in `-aarch64`. The only aarch64 pair is the base profile.
With nitro-util's `buildEif`:

```nix
kernel = builder.packages.x86_64-linux.enclave-kernel-aarch64;
kernelConfig = builder.packages.x86_64-linux.enclave-kernel-config-aarch64;

nitroLib.buildEif {
  arch = "aarch64";
  kernel = "${kernel}/Image";
  kernelConfig = "${kernelConfig}/config";
  nsmKo = null; # NSM is built in
  init = "${builder.packages.x86_64-linux.eif-init-aarch64}/bin/init";
  # ...
}
```

The kernel command line used for x86_64 EIFs also works on arm64.

### Verification

```sh
nix build .#packages.x86_64-linux.enclave-kernel-config-aarch64 \
  -o result-aarch64-kernel-config
cat result-aarch64-kernel-config/report
nix build .#packages.x86_64-linux.enclave-kernel-aarch64 \
  -o result-aarch64-kernel
```

Boot coverage is on real Graviton Nitro hardware, through the consumer's EIF;
this repository has no aarch64 QEMU harness. A successful boot logs
`rtc-pl031 ... setting system clock to <current date>` and exposes `/dev/nsm`.
