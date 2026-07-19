{
  pkgs,
  nitroLib,
  enclaviaServerPkg,
  ociBundlePath,
  containerPort ? 8080,
  debugMode ? false,
  nbdClientPkg ? null,
  enclaviaCryptoPkg ? null,
  enclaviaEgressPkg ? null,
  # Per-enclave secrets injector (#169). Optional only because some
  # one-off test EIFs callPackage this file with a hand-built attrset;
  # the flake's regular invocations always supply it.
  enclaviaSecretsInitPkg ? null,
  # In-enclave boot-attestation submitter (#47 phase 3b). Optional for
  # the same reason as enclaviaSecretsInitPkg: hand-built test EIFs
  # may skip it, but every real-enclave variant passes it in.
  enclaviaChainInitPkg ? null,
  storageEnabled ? false,
  customKernel ? null,
  # CI size checks need the assembled, uncompressed rootfs without paying
  # to build the kernel, ramdisks, or final EIF.
  rootfsOnly ? false,
  # Diagnostic: skip LUKS and mount raw btrfs on the NBD device directly.
  # Used to isolate proxy throughput from cryptsetup overhead during testing.
  skipLuks ? false,
}:

let
  arch = "x86_64";
  blobs = nitroLib.blobs.${arch};

  # The init for ALL EIFs (debug and prod alike). Unlike AWS' stock blob
  # init (which heartbeats only the Nitro parent at CID 3 and can't be
  # modified), this one we control: it heartbeats BOTH CID 3 and CID 2
  # (VMADDR_CID_HOST, where QEMU's vhost-device-vsock answers), so a single
  # EIF boots on both QEMU and real Nitro. It is a port of AWS'
  # aws-nitro-enclaves-sdk-bootstrap init.c.
  patchedInit = pkgs.buildGoModule {
    name = "eif-init";
    src = ./init-patched;
    vendorHash = null;
    env.CGO_ENABLED = 0;
    ldflags = [ "-s" "-w" ];
  };

  # If the builder placed an enclavia-config.json in the bundle, use it.
  # Otherwise generate a default one.
  bundleConfig = ociBundlePath + "/enclavia-config.json";
  hasCustomConfig = builtins.pathExists bundleConfig;

  # Egress allowlist. The builder copies the user-supplied JSON into the
  # bundle as `egress.json` (only when the caller passed
  # `--egress-allowlist`). When present, the file is installed at
  # `/etc/enclavia/egress.json` and the in-enclave daemon enforces it.
  # When absent, no file is baked in and the daemon stays at deny-all.
  bundleEgressAllowlist = ociBundlePath + "/egress.json";
  hasEgressAllowlist = builtins.pathExists bundleEgressAllowlist;

  enclaviaConfig = if hasCustomConfig
    then bundleConfig
    else pkgs.writeText "enclavia-config.json" (builtins.toJSON ({
      listen_vsock_port = 5000;
      oci_bundle_path = "/var/lib/oci/bundle";
      customer_app = {
        port = containerPort;
        health_check = "/health";
        startup_timeout_secs = 30;
      };
    } // (if storageEnabled then {
      storage = {
        enabled = true;
        vsock_port = 5001;
        meta_vsock_port = 5002;
        kms_vsock_port = 5003;
        mount_point = "/data";
        device = "/dev/nbd0";
      } // (if skipLuks then { skip_luks = true; } else {});
    } else {})));

  # Plain copy of init.sh, keeping its own `#!/bin/sh` shebang (resolved
  # to the busybox sh baked into the rootfs). Deliberately NOT
  # writeShellScript: that prepends a `#!/nix/store/...-bash` shebang,
  # which drags the full bash closure (bash + ncurses + readline) into
  # the measured image for a script that is already POSIX sh.
  initScript = pkgs.writeTextFile {
    name = "enclave-init";
    executable = true;
    text = builtins.readFile ./init.sh;
  };

  # In-enclave validating DNS resolver (#136). Static musl build from
  # nixpkgs so it drops cleanly into the initramfs with no shared-library
  # closure to ship. The DNSSEC trust anchor and the runtime-substituted
  # config template live next to it on the rootfs.
  unboundPkg = pkgs.pkgsStatic.unbound;
  unboundConfTemplate = ./unbound.conf.template;
  # IANA DNSSEC root trust anchor, vendored from nixpkgs.dns-root-data.
  # Vendoring rather than fetching at boot is intentional: the anchor
  # file is hashed into the EIF, so any change to the anchor changes
  # the PCRs and is auditable via `enclavia reproduce`.
  rootKey = "${pkgs.dns-root-data}/root.key";

  # Minimal static crun. The stock nixpkgs crun is dynamically linked
  # and its nix closure is enormous for an initramfs: criu (which pulls
  # a full python3), libkrun + libkrunfw (a ~20 MiB microVM kernel
  # blob), systemd-minimal, glibc, sqlite, bash... none of which the
  # enclave ever executes -- we only need `crun run` on a pre-patched
  # bundle. Building it static (musl) with checkpoint/restore, systemd
  # cgroup support and the krun handler disabled turns a ~300 MiB
  # closure into one ~2 MiB self-contained binary.
  crunMinimal =
    (pkgs.pkgsStatic.crun.override {
      withLibkrun = false;
      withLibkrunSEV = false;
      # Null buildInputs are skipped by mkDerivation; configure then
      # simply doesn't find criu/systemd and compiles the fallbacks.
      criu = null;
      systemdMinimal = null;
    }).overrideAttrs (old: {
      # musl has no argp; crun's option parser needs the standalone lib.
      buildInputs = (old.buildInputs or [ ]) ++ [
        pkgs.pkgsStatic.argp-standalone
      ];
      # The stock derivation force-links criu.
      env = (old.env or { }) // { NIX_LDFLAGS = ""; };
      configureFlags = (old.configureFlags or [ ]) ++ [
        "--disable-criu"
        "--disable-systemd"
      ];
      # The test suite needs container privileges and a dynamic host
      # toolchain; irrelevant for this static build.
      doCheck = false;
      doInstallCheck = false;
    });

  runtimeRootfs = pkgs.runCommand "enclave-runtime-rootfs" {
    nativeBuildInputs = [ pkgs.nukeReferences ];
    # Everything supplied by the builder is self-contained. Keep this
    # invariant machine-checked so a newly copied dynamic binary cannot
    # silently reintroduce its Nix closure into the EIF.
    allowedReferences = [ ];
  } ''
    mkdir -p $out/bin $out/etc/enclavia $out/etc/unbound $out/var/lib/oci

    # Binaries
    cp ${enclaviaServerPkg}/bin/enclavia-server $out/bin/
    cp ${crunMinimal}/bin/crun $out/bin/

    ${if enclaviaSecretsInitPkg != null then ''
    # Per-enclave secrets injector (#169). init.sh dials vsock 5004 via
    # this binary right before `crun start` to pull the host-side
    # secrets snapshot and splice it into the OCI bundle's process.env.
    # Exits 0 cleanly when no host-side daemon is listening (the
    # backend only starts `secrets-host` when the enclave has secrets
    # configured), so it is always safe to invoke.
    cp ${enclaviaSecretsInitPkg}/bin/enclavia-secrets-init $out/bin/
    '' else ""}

    ${if enclaviaChainInitPkg != null then ''
    # In-enclave boot-attestation submitter (#47 phase 3b). init.sh
    # invokes it between secrets-init and `exec enclavia-server`;
    # it dials chain-host on vsock 5005, signs a boot link with the
    # enclave's NSM attestation doc, and submits it. When the binary
    # is baked in, failure is fatal: the genesis boot link is the only
    # authoritative record that the boot happened, so init.sh aborts
    # the boot (via `set -e`) rather than start the workload without
    # it. See the comment block above the invocation in init.sh.
    cp ${enclaviaChainInitPkg}/bin/enclavia-chain-init $out/bin/
    '' else ""}

    # Minimal busybox for networking setup (ip link set lo up)
    cp ${pkgs.pkgsStatic.busybox}/bin/busybox $out/bin/busybox
    ln -s busybox $out/bin/ip
    ln -s busybox $out/bin/mount
    ln -s busybox $out/bin/mkdir
    ln -s busybox $out/bin/sleep
    ln -s busybox $out/bin/insmod
    ln -s busybox $out/bin/sh
    ln -s busybox $out/bin/rm
    ln -s busybox $out/bin/mknod
    ln -s busybox $out/bin/awk
    ln -s busybox $out/bin/grep
    ln -s busybox $out/bin/tr
    ln -s busybox $out/bin/nc
    ln -s busybox $out/bin/nsenter
    ln -s busybox $out/bin/printf
    ln -s busybox $out/bin/nslookup
    ln -s busybox $out/bin/cp
    ln -s busybox $out/bin/cat
    ln -s busybox $out/bin/tail

    # jq for parsing /etc/enclavia/egress.json in init.sh. busybox awk
    # works but is fragile on single-line JSON (the original awk
    # forwarded-scoped resolvers list also matched IPs from the egress
    # array). jq's grammar makes the queries explicit and short.
    cp ${pkgs.pkgsStatic.jq}/bin/jq $out/bin/jq

    ${if storageEnabled && nbdClientPkg != null then ''
    # NBD client for enclave storage. The client also acts as a userspace
    # filter in the data path so it can observe per-superblock writes for
    # the synchronizer (logged-only for now).
    cp ${nbdClientPkg}/bin/enclavia-nbd-client $out/bin/

    # KMS key management — fetches/generates the LUKS passphrase.
    ${if enclaviaCryptoPkg != null then ''
      cp ${enclaviaCryptoPkg}/bin/enclavia-crypto $out/bin/
    '' else throw "enclaviaCryptoPkg is required when storageEnabled = true"}

    # cryptsetup (dm-crypt / LUKS2) and btrfs userspace.
    cp ${pkgs.pkgsStatic.cryptsetup}/bin/cryptsetup $out/bin/
    cp ${pkgs.pkgsStatic.btrfs-progs}/bin/mkfs.btrfs $out/bin/
    cp ${pkgs.pkgsStatic.util-linux}/bin/blkid $out/bin/
    '' else ""}

    ${if enclaviaEgressPkg != null then ''
    # Egress daemon: owns /dev/net/tun, runs smoltcp on it, relays
    # outbound TCP to egress-host over vsock port 5006.
    cp ${enclaviaEgressPkg}/bin/enclavia-egress $out/bin/

    # unbound + DNSSEC trust anchor for #136. unbound listens on
    # 127.0.0.1:53, forwards over DNS-over-TCP through enclavia-egress
    # to the operator-supplied resolvers. init.sh substitutes the
    # forward-addr lines into the template at boot.
    cp ${unboundPkg}/bin/unbound $out/bin/
    cp ${unboundConfTemplate} $out/etc/unbound/unbound.conf.template
    cp ${rootKey} $out/etc/unbound/root.key
    chmod 0644 $out/etc/unbound/root.key

    # Real (static) iproute2 for the network-namespace split that
    # isolates unbound (resolver-bypass hardening). busybox `ip` has no `netns` /
    # `link ... netns` support, so init.sh uses this binary for the
    # veth + netns setup; the existing lo/tun0 commands stay on
    # busybox `ip`. Named distinctly to avoid changing the busybox
    # applet the rest of init.sh relies on.
    cp ${pkgs.pkgsStatic.iproute2}/bin/ip $out/bin/iproute2-ip

    # Static legacy iptables (xtables-legacy backend; the enclave
    # kernel builds CONFIG_IP_NF_IPTABLES/FILTER, not nf_tables). One
    # boot-time OUTPUT rule stops a workload forging the isolated
    # resolver's source address with CAP_NET_RAW (resolver-bypass
    # hardening). The
    # multiplexer dispatches on argv0, so the `iptables` symlink
    # selects the legacy applet.
    cp ${pkgs.pkgsStatic.iptables}/bin/xtables-legacy-multi $out/bin/
    ln -s xtables-legacy-multi $out/bin/iptables
    '' else ""}

    # Init script — must be inside the rootfs since the init binary
    # does chroot("/rootfs") before executing the entrypoint.
    cp ${initScript} $out/bin/enclave-init
    chmod +x $out/bin/enclave-init

    # (No host-vsock-CID marker is baked into the measured rootfs: the
    # patched init heartbeats BOTH CIDs at boot, then writes whichever one
    # answered -- CID 3 on real Nitro, CID 2 under QEMU -- to
    # /run/enclavia-host-cid, and the in-enclave binaries read it via
    # enclavia-vsock::host_cid. The CID is a runtime fact, not part of the
    # enclave's identity, so it stays off the measured image. One EIF boots
    # in either environment with nothing to flip per-build.)

    # Enclavia config. This file carries the enclave's trust anchors
    # (#47 control_public_key, enclavia#208 synchronizer.expected_pcrs +
    # debug_attestation), which are only worth anything because they sit
    # INSIDE the measured rootfs: the rootfs is hashed into the EIF and
    # shows up in the PCRs, so the host can't substitute its own values
    # at runtime. Assert at build time that the copy actually landed,
    # is valid JSON, and that any synchronizer section carries a
    # non-empty expected_pcrs list (an empty one makes the in-enclave
    # nbd-client fail-stop at boot, so catch it before it's measured
    # into an EIF).
    cp ${enclaviaConfig} $out/etc/enclavia/config.json
    if ! test -s $out/etc/enclavia/config.json; then
      echo "enclave-rootfs: /etc/enclavia/config.json is missing or empty in the measured rootfs" >&2
      exit 1
    fi
    if ! ${pkgs.pkgsStatic.jq}/bin/jq -e '
      type == "object" and
      (if has("synchronizer") then
        (.synchronizer.expected_pcrs | type == "array" and length > 0)
      else true end)
    ' $out/etc/enclavia/config.json > /dev/null; then
      echo "enclave-rootfs: /etc/enclavia/config.json failed the trust-anchor sanity check" >&2
      echo "(must be a JSON object; a synchronizer section must carry a non-empty expected_pcrs array)" >&2
      exit 1
    fi

    ${if hasEgressAllowlist then ''
    # Egress allowlist (#138). The in-enclave daemon reads this at boot;
    # init.sh only overwrites it when the e2e test fixtures are on the
    # kernel command line.
    cp ${bundleEgressAllowlist} $out/etc/enclavia/egress.json
    '' else ""}

    # Every binary in this list is static (the Enclavia services target
    # musl; the remaining tools come from pkgsStatic). They can still
    # embed inert /nix/store strings in build metadata and configure-time
    # defaults, so scrub those strings. Keep the list explicit: adding a
    # binary requires confirming that it is self-contained before opting
    # it into this destructive operation. allowedReferences above turns
    # an omission into a build failure.
    for tool in \
      enclavia-server \
      enclavia-secrets-init \
      enclavia-chain-init \
      enclavia-nbd-client \
      enclavia-crypto \
      enclavia-egress \
      crun \
      busybox \
      jq \
      unbound \
      cryptsetup \
      mkfs.btrfs \
      blkid \
      iproute2-ip \
      xtables-legacy-multi
    do
      if [ -f "$out/bin/$tool" ]; then
        chmod u+w "$out/bin/$tool"
        nuke-refs "$out/bin/$tool"
        chmod a-w "$out/bin/$tool"
      fi
    done
  '';

  # Keep the customer OCI bundle separate from the zero-reference runtime
  # assertion above. A Nix-built workload may intentionally carry dynamic
  # libraries at /nix/store paths inside its own container rootfs (as the
  # WS test fixture does); those references are self-contained within the
  # bundle and must not cause the same closure to be copied into the outer
  # initramfs. The EIF therefore receives this assembled tree directly,
  # with copyToRootWithClosure disabled below.
  rootfs = pkgs.runCommand "enclave-rootfs" {} ''
    mkdir -p $out
    cp -r ${runtimeRootfs}/. $out/
    cp -r ${ociBundlePath} $out/var/lib/oci/bundle
  '';

  # Always the patched init (never AWS's stock CID-3-only blob init), so a
  # single EIF boots on both QEMU and real Nitro: the patched init
  # heartbeats CID 3 (Nitro parent) AND CID 2 (vhost-device-vsock host), then
  # records whichever answered to /run/enclavia-host-cid for the in-enclave
  # binaries to read (enclavia-vsock::host_cid). This is what lets
  # `enclavia reproduce` actually boot a Nitro-built image locally on QEMU,
  # not just compare PCRs. (debugMode no longer affects the init; it only
  # drives debug-attestation trust anchors in config.json.)
  initBinary = "${patchedInit}/bin/init";

in
  if rootfsOnly then rootfs else nitroLib.buildEif {
    name = "enclavia-enclave";
    kernel = if customKernel != null
      then "${customKernel}/bzImage"
      else blobs.kernel;
    kernelConfig = if customKernel != null
      then customKernel.configfile
      else blobs.kernelConfig;
    # Modern kernels (6.x+) have the NSM guest driver built-in
    nsmKo = if customKernel != null then null else blobs.nsmKo;
    copyToRoot = rootfs;
    copyToRootWithClosure = false;
    entrypoint = "/bin/enclave-init";
    init = initBinary;
  }
