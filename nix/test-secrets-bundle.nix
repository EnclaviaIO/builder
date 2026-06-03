# Builds a minimal OCI runtime bundle for the per-enclave secrets e2e
# test (#169).
#
# The workload reads its OCI env, inspects two well-known secret names
# (SECRET_BIN, SECRET_TEXT), and prints assertion markers to the serial
# console for the host-side harness to grep.
#
# The exact assertion run is selected via SECRETS_MODE on the kernel
# command line (the host harness sets it via `enclavia.secrets_mode=`,
# surfaced into /etc/secrets-test.mode by init.sh):
#
#   inject  — expect SECRET_BIN (8 bytes 0x01..=0x08, picked to avoid
#             a leading NUL byte that POSIX env-var transport would
#             truncate) and SECRET_TEXT (the literal "smörgåsbord,
#             naïve" string). Failure if either is missing or
#             mismatched.
#
#   empty   — expect that no env var named SECRET_BIN or SECRET_TEXT
#             is present at all. Failure if either is set.
#
# In both modes the workload prints `secrets-test: ...` markers and then
# loops on `nc -l` on port 8080 so the EIF stays up (init.sh's
# enclavia-server is still the foreground process; we just keep the
# container alive past the assertion).
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

          MODE="inject"
          if [ -r /etc/secrets-test.mode ]; then
              MODE="$(cat /etc/secrets-test.mode)"
          fi
          echo "secrets-test: mode=$MODE"

          # Dump all env, then narrow to SECRET_* — useful both for
          # debugging and for the host-side absence assertion in
          # 'empty' mode.
          SECRET_NAMES=$(env | awk -F= '/^SECRET_/{print $1}' | sort | tr '\n' ',' )
          echo "secrets-test: secret-names=$SECRET_NAMES"

          case "$MODE" in
              inject)
                  EXPECTED_BIN_HEX="0102030405060708"
                  EXPECTED_TEXT="smörgåsbord, naïve"

                  if [ -z "''${SECRET_BIN:-}" ]; then
                      echo "secrets-test: FAILURE SECRET_BIN missing"
                      BODY="FAIL: SECRET_BIN missing"
                  elif [ -z "''${SECRET_TEXT:-}" ]; then
                      echo "secrets-test: FAILURE SECRET_TEXT missing"
                      BODY="FAIL: SECRET_TEXT missing"
                  else
                      ACTUAL_BIN_HEX=$(printf '%s' "$SECRET_BIN" | od -An -tx1 | tr -d ' \n')
                      echo "secrets-test: SECRET_BIN_HEX=$ACTUAL_BIN_HEX"
                      echo "secrets-test: SECRET_TEXT=$SECRET_TEXT"

                      if [ "$ACTUAL_BIN_HEX" != "$EXPECTED_BIN_HEX" ]; then
                          echo "secrets-test: FAILURE SECRET_BIN expected=$EXPECTED_BIN_HEX got=$ACTUAL_BIN_HEX"
                          BODY="FAIL: SECRET_BIN mismatch"
                      elif [ "$SECRET_TEXT" != "$EXPECTED_TEXT" ]; then
                          echo "secrets-test: FAILURE SECRET_TEXT expected=$EXPECTED_TEXT got=$SECRET_TEXT"
                          BODY="FAIL: SECRET_TEXT mismatch"
                      else
                          echo "secrets-test: SUCCESS inject"
                          BODY="OK"
                      fi
                  fi
                  ;;
              empty)
                  if [ -n "''${SECRET_BIN:-}" ] || [ -n "''${SECRET_TEXT:-}" ]; then
                      echo "secrets-test: FAILURE empty-mode leaked SECRET_BIN=''${SECRET_BIN:-} SECRET_TEXT=''${SECRET_TEXT:-}"
                      BODY="FAIL: empty leaked"
                  elif [ -n "$SECRET_NAMES" ]; then
                      echo "secrets-test: FAILURE empty-mode unexpected SECRET_* vars: $SECRET_NAMES"
                      BODY="FAIL: unexpected secrets"
                  else
                      echo "secrets-test: SUCCESS empty"
                      BODY="OK"
                  fi
                  ;;
              *)
                  echo "secrets-test: FAILURE unknown mode $MODE"
                  BODY="FAIL: unknown mode"
                  ;;
          esac

          echo "secrets-test: starting HTTP server on port 8080"
          while true; do
              echo -e "HTTP/1.1 200 OK\r\nContent-Length: ''${#BODY}\r\nContent-Type: text/plain\r\n\r\n$BODY" | nc -l -p 8080 -q 0 2>/dev/null || break
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

in pkgs.runCommand "test-secrets-oci-bundle" {} ''
  mkdir -p $out/rootfs/bin $out/rootfs/tmp

  cp ${pkgs.pkgsStatic.busybox}/bin/busybox $out/rootfs/bin/busybox
  for cmd in sh nc echo cat ls mkdir env awk sort tr printf od; do
    ln -s busybox $out/rootfs/bin/$cmd
  done

  cp ${config} $out/config.json
''
