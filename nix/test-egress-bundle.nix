# Builds a minimal OCI runtime bundle for the egress e2e test.
#
# The workload reads TARGET_IP and TARGET_PORT from its env, opens a TCP
# connection to that destination, sends `ping\n`, reads up to 16 bytes,
# and exits 0 iff the response starts with `pong`. Anything else exits
# non-zero so the e2e harness can detect the failure mode.
#
# busybox `nc` is the only piece we need beyond a shell.
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
          set -u
          # init.sh writes target IP/port (from kernel cmdline) into this
          # file before launching us, since the OCI process env is baked
          # in at build time and the e2e harness picks the destination at
          # runtime. Falls back to localhost defaults so the bundle is
          # still runnable when nothing was injected.
          TARGET_IP="127.0.0.1"
          TARGET_PORT="0"
          if [ -r /etc/egress-test.env ]; then
            . /etc/egress-test.env
          fi
          : "''${TARGET_IP:?TARGET_IP not set}"
          : "''${TARGET_PORT:?TARGET_PORT not set}"
          echo "egress-test: dialing $TARGET_IP:$TARGET_PORT" >&2
          # busybox nc exits as soon as stdin EOFs without waiting for
          # the server's reply. Keep stdin open with `sleep` so nc stays
          # connected until the echo server writes `pong\n` and closes,
          # which surfaces as EOF on the socket and lets nc terminate.
          # `-w 10` is the connect + idle timeout that bounds the whole
          # exchange.
          REPLY=$( { printf 'ping\n'; sleep 5; } | nc -w 10 "$TARGET_IP" "$TARGET_PORT")
          echo "egress-test: got reply: $REPLY" >&2
          case "$REPLY" in
            pong*) echo "egress-test: SUCCESS" >&2; exit 0 ;;
            *) echo "egress-test: FAILURE (unexpected reply)" >&2; exit 1 ;;
          esac
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
      # Same rule as test-bundle: no namespaces. The OCI runtime would
      # otherwise create a fresh net namespace and lose tun0.
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

in pkgs.runCommand "test-egress-oci-bundle" {} ''
  mkdir -p $out/rootfs/bin $out/rootfs/tmp

  cp ${pkgs.pkgsStatic.busybox}/bin/busybox $out/rootfs/bin/busybox
  for cmd in sh nc echo cat ls mkdir printf sleep; do
    ln -s busybox $out/rootfs/bin/$cmd
  done

  cp ${config} $out/config.json
''
