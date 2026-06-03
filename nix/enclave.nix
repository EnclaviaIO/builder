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
  storageEnabled ? false,
  customKernel ? null,
  # Diagnostic: skip LUKS and mount raw btrfs on the NBD device directly.
  # Used to isolate proxy throughput from cryptsetup overhead during testing.
  skipLuks ? false,
}:

let
  arch = "x86_64";
  blobs = nitroLib.blobs.${arch};

  # In debug mode (QEMU + vhost-device-vsock UDS backend), the init binary
  # must connect to CID 2 (VSOCK_HOST_CID) instead of CID 3 (Nitro parent).
  # Build a patched init with the correct CID.
  patchedInit = pkgs.buildGoModule {
    name = "eif-init-debug";
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

  initScript = pkgs.writeShellScript "enclave-init" (builtins.readFile ./init.sh);

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

  rootfs = pkgs.runCommand "enclave-rootfs" {} ''
    mkdir -p $out/bin $out/etc/enclavia $out/etc/unbound $out/var/lib/oci

    # Binaries
    cp ${enclaviaServerPkg}/bin/enclavia-server $out/bin/
    cp ${pkgs.crun}/bin/crun $out/bin/

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
    '' else ""}

    # Init script — must be inside the rootfs since the init binary
    # does chroot("/rootfs") before executing the entrypoint.
    cp ${initScript} $out/bin/enclave-init
    chmod +x $out/bin/enclave-init

    # Enclavia config
    cp ${enclaviaConfig} $out/etc/enclavia/config.json

    ${if hasEgressAllowlist then ''
    # Egress allowlist (#138). The in-enclave daemon reads this at boot;
    # init.sh only overwrites it when the e2e test fixtures are on the
    # kernel command line.
    cp ${bundleEgressAllowlist} $out/etc/enclavia/egress.json
    '' else ""}

    # OCI bundle (customer's image)
    cp -r ${ociBundlePath} $out/var/lib/oci/bundle
  '';

  initBinary = if debugMode
    then "${patchedInit}/bin/init"
    else blobs.init;

in
  nitroLib.buildEif {
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
    entrypoint = "/bin/enclave-init";
    init = initBinary;
  }
