# Builds a minimal OCI runtime bundle for testing.
# Contains busybox (sh, nc, etc.) and a config.json that starts
# a hello-world HTTP server on port 8080.
{ pkgs }:

let
  config = pkgs.writeText "oci-config.json" (builtins.toJSON {
    ociVersion = "1.0.2";
    process = {
      terminal = false;
      user = { uid = 0; gid = 0; };
      args = [
        "/bin/sh" "-c"
        ''
          echo 'hello-server: starting on port 8080'
          while true; do
            echo -e 'HTTP/1.1 200 OK\r\nContent-Length: 13\r\nContent-Type: text/plain\r\n\r\nHello, world!' | nc -l -p 8080 -q 0 2>/dev/null || break
          done
        ''
      ];
      env = [
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        "TERM=xterm"
      ];
      cwd = "/";
    };
    root = {
      path = "rootfs";
      readonly = false;
    };
    linux = {
      # No mount namespace — initramfs rootfs doesn't support mount propagation
      # changes, which OCI runtimes require when creating mount namespaces.
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

in pkgs.runCommand "test-oci-bundle" {} ''
  mkdir -p $out/rootfs/bin $out/rootfs/tmp

  # Use busybox for sh, nc, and basic utilities
  cp ${pkgs.pkgsStatic.busybox}/bin/busybox $out/rootfs/bin/busybox
  for cmd in sh nc echo cat ls mkdir; do
    ln -s busybox $out/rootfs/bin/$cmd
  done

  cp ${config} $out/config.json
''
