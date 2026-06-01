# Builds a minimal OCI runtime bundle for the WS end-to-end test.
#
# The workload is the `ws-echo-test` Rust binary (built in
# `enclavia-crates`): a tokio-tungstenite WS echo server bound to
# `0.0.0.0:8080`. It accepts upgrades at any path, echoes text/binary
# frames, replies to pings with pongs, and shuts down cleanly when the
# peer closes.
#
# Unlike `test-bundle.nix` / `test-egress-bundle.nix` which can lean on
# pkgsStatic.busybox, this binary is dynamically linked against glibc.
# We copy the runtime closure (lib + ld-linux) into the OCI rootfs so
# crun can exec the workload without a chroot escape.
{ pkgs, wsEchoBin }:

let
  config = pkgs.writeText "oci-config.json" (builtins.toJSON {
    ociVersion = "1.0.2";
    process = {
      terminal = false;
      user = { uid = 0; gid = 0; };
      args = [ "/bin/ws-echo-test" ];
      env = [
        "PATH=/bin"
        "RUST_LOG=info"
      ];
      cwd = "/";
    };
    root = {
      path = "rootfs";
      readonly = false;
    };
    linux = {
      # Same as the other test bundles: no namespaces. The OCI runtime
      # would otherwise create a fresh net ns and lose loopback.
      namespaces = [];
    };
    mounts = [
      {
        destination = "/dev";
        type = "tmpfs";
        source = "tmpfs";
        options = [ "nosuid" "strictatime" "mode=755" "size=65536k" ];
      }
    ];
  });

  closure = pkgs.closureInfo { rootPaths = [ wsEchoBin ]; };

in pkgs.runCommand "test-ws-oci-bundle" {} ''
  mkdir -p $out/rootfs/bin $out/rootfs/tmp

  cp ${wsEchoBin}/bin/ws-echo-test $out/rootfs/bin/ws-echo-test
  chmod +x $out/rootfs/bin/ws-echo-test

  # The binary is dynamically linked; pull glibc + libgcc into the
  # rootfs at the same /nix/store paths the binary was linked against.
  # This keeps the closure identical to what `ldd` reports outside the
  # enclave, so the in-enclave loader resolves the same files. The
  # closureInfo derivation enumerates the runtime deps for us.
  mkdir -p $out/rootfs/nix/store
  for path in $(cat ${closure}/store-paths); do
    # Preserve the original modes so the dynamic loader (ld-linux) keeps
    # its +x bit; otherwise crun's `exec ws-echo-test` returns
    # `Permission denied` because the kernel cannot run the interpreter.
    cp -r "$path" $out/rootfs/nix/store/
    chmod -R u+w "$out/rootfs/nix/store/$(basename "$path")"
  done

  cp ${config} $out/config.json
''
