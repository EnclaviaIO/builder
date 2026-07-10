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
            pong*) echo "egress-test: positive egress OK" >&2 ;;
            *) echo "egress-test: FAILURE (allowed dest did not reply pong)" >&2; exit 1 ;;
          esac

          # --- DNS filter assertions ----------------------------------
          # The workload's only intended DNS path is the in-enclave
          # unbound (its resolv.conf points at the isolated resolver).
          # Assert that path enforces the hostname allow-list: an
          # allow-listed name resolves, a non-allow-listed one is
          # REFUSED (unbound `local-zone "." refuse`). These are the
          # reliable, workload-observable filter checks.
          #
          # NOTE on the direct-resolver bypass (the netns-split's whole
          # point): it is NOT asserted here. The workload cannot observe
          # the daemon's allow/deny decision, and neither a UDP nslookup
          # (fails trivially: the egress path is TCP-only) nor a raw
          # DNS-over-TCP probe discriminates: the daemon logs show that
          # WITHOUT the source-gating the workload's resolver:53 flow is
          # ALLOWED yet its splice still fails for a plain nc, so "no
          # answer" happens on both the allowed and denied paths. The
          # source-gating deny is covered by unit tests in the egress
          # daemon (a workload-sourced resolver:53 connect is denied). An
          # end-to-end assertion needs egress-daemon log observability,
          # which belongs with the test-hooks refactor (builder#53).
          resolves() { timeout 8 nslookup "$@" >/dev/null 2>&1; }

          if ! resolves one.one.one.one; then
            echo "egress-test: FAILURE (workload could not resolve an allow-listed name via unbound)" >&2; exit 1
          fi
          echo "egress-test: dns-allow (allow-listed name resolves via unbound) OK" >&2

          if resolves example.org; then
            echo "egress-test: FAILURE (unbound resolved a non-allow-listed name)" >&2; exit 1
          fi
          echo "egress-test: dns-deny (unbound refuses non-allow-listed name) OK" >&2

          echo "egress-test: SUCCESS" >&2
          exit 0
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
  for cmd in sh nc echo cat ls mkdir printf sleep nslookup timeout; do
    ln -s busybox $out/rootfs/bin/$cmd
  done

  cp ${config} $out/config.json
''
