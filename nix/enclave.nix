{
  pkgs,
  nitroLib,
  enclaviaServerPkg,
  ociBundlePath,
  containerPort ? 8080,
  debugMode ? false,
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

  enclaviaConfig = if hasCustomConfig
    then bundleConfig
    else pkgs.writeText "enclavia-config.json" (builtins.toJSON {
      listen_vsock_port = 5000;
      oci_bundle_path = "/var/lib/oci/bundle";
      customer_app = {
        port = containerPort;
        health_check = "/health";
        startup_timeout_secs = 30;
      };
    });

  initScript = pkgs.writeShellScript "enclave-init" (builtins.readFile ./init.sh);

  rootfs = pkgs.runCommand "enclave-rootfs" {} ''
    mkdir -p $out/bin $out/etc/enclavia $out/var/lib/oci

    # Binaries
    cp ${enclaviaServerPkg}/bin/enclavia-server $out/bin/
    cp ${pkgs.crun}/bin/crun $out/bin/

    # Minimal busybox for networking setup (ip link set lo up)
    cp ${pkgs.pkgsStatic.busybox}/bin/busybox $out/bin/busybox
    ln -s busybox $out/bin/ip
    ln -s busybox $out/bin/mount
    ln -s busybox $out/bin/mkdir

    # Init script — must be inside the rootfs since the init binary
    # does chroot("/rootfs") before executing the entrypoint.
    cp ${initScript} $out/bin/enclave-init
    chmod +x $out/bin/enclave-init

    # Enclavia config
    cp ${enclaviaConfig} $out/etc/enclavia/config.json

    # OCI bundle (customer's image)
    cp -r ${ociBundlePath} $out/var/lib/oci/bundle
  '';

  initBinary = if debugMode
    then "${patchedInit}/bin/init"
    else blobs.init;

in
  nitroLib.buildEif {
    name = "enclavia-enclave";
    kernel = blobs.kernel;
    kernelConfig = blobs.kernelConfig;
    nsmKo = blobs.nsmKo;
    copyToRoot = rootfs;
    entrypoint = "/bin/enclave-init";
    init = initBinary;
  }
