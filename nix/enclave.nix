{
  pkgs,
  nitroLib,
  enclaviaServerPkg,
  ociBundlePath,
}:

let
  arch = "x86_64";
  blobs = nitroLib.blobs.${arch};

  enclaviaConfig = pkgs.writeText "enclavia-config.json" (builtins.toJSON {
    listen_vsock_port = 5000;
    oci_bundle_path = "/var/lib/oci/bundle";
    customer_app = {
      port = 8080;
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

    # Init script — must be inside the rootfs since the init binary
    # does chroot("/rootfs") before executing the entrypoint.
    cp ${initScript} $out/bin/enclave-init
    chmod +x $out/bin/enclave-init

    # Enclavia config
    cp ${enclaviaConfig} $out/etc/enclavia/config.json

    # OCI bundle (customer's image)
    cp -r ${ociBundlePath} $out/var/lib/oci/bundle
  '';

in
  nitroLib.buildEif {
    name = "enclavia-enclave";
    kernel = blobs.kernel;
    kernelConfig = blobs.kernelConfig;
    nsmKo = blobs.nsmKo;
    copyToRoot = rootfs;
    entrypoint = "/bin/enclave-init";
  }
