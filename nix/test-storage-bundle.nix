# Builds a minimal OCI runtime bundle for testing enclave storage.
# The container writes a test file to /data (the NBD-backed mount) and
# serves its contents over HTTP on port 8080 so the host can verify.
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
          echo 'storage-test: container starting'

          # Wait for /data to be mounted by init.sh
          i=0
          while [ $i -lt 100 ]; do
            if mountpoint -q /data 2>/dev/null; then
              break
            fi
            sleep 0.1
            i=$((i + 1))
          done

          if mountpoint -q /data 2>/dev/null; then
            echo 'storage-test: /data is mounted!'

            # Cross-boot persistence probe: if /data/persist.bin already exists
            # from a previous boot, verify its md5 matches the recorded one.
            PERSIST_STATUS="first-boot"
            if [ -f /data/persist.bin ] && [ -f /data/persist.md5 ]; then
              EXPECTED=$(cat /data/persist.md5)
              ACTUAL=$(md5sum /data/persist.bin | cut -d' ' -f1)
              if [ "$EXPECTED" = "$ACTUAL" ]; then
                PERSIST_STATUS="persist-ok md5=$ACTUAL"
                echo "storage-test: PERSIST_OK existing data verified (md5=$ACTUAL)"
              else
                PERSIST_STATUS="persist-corrupt expected=$EXPECTED actual=$ACTUAL"
                echo "storage-test: ERROR persist.bin corrupt expected=$EXPECTED actual=$ACTUAL"
              fi
            else
              echo 'storage-test: first boot, creating persist.bin'
              dd if=/dev/urandom of=/data/persist.bin bs=1024 count=64 2>/dev/null
              md5sum /data/persist.bin | cut -d' ' -f1 > /data/persist.md5
              sync
              PERSIST_STATUS="created md5=$(cat /data/persist.md5)"
            fi

            # Per-boot write test (always fresh)
            echo 'STORAGE_TEST_OK' > /data/test.txt
            dd if=/dev/urandom of=/data/random.bin bs=1024 count=64 2>/dev/null
            CHECKSUM=$(md5sum /data/random.bin | cut -d' ' -f1)
            sync

            echo "storage-test: wrote test.txt and random.bin (md5=$CHECKSUM)"

            VERIFY=$(md5sum /data/random.bin | cut -d' ' -f1)
            if [ "$CHECKSUM" = "$VERIFY" ]; then
              echo 'storage-test: read-back checksum OK'
            else
              echo 'storage-test: ERROR checksum mismatch!'
            fi

            # --- Throughput benchmark ---
            # /data is the encrypted-storage path (LUKS+btrfs over NBD over vsock).
            # /tmp is a tmpfs set up by init.sh — same TCG overhead, no proxy/LUKS.
            BENCH_BYTES=$((16 * 1024 * 1024))
            BENCH_COUNT=16
            BENCH_BS=1M

            echo '===== BENCH BEGIN ====='

            echo 'bench: /data sequential write (16 MiB, bs=1M, fsync)'
            dd if=/dev/zero of=/data/bench.bin bs=$BENCH_BS count=$BENCH_COUNT conv=fsync 2>&1 | grep -v records
            sync
            echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

            echo 'bench: /data sequential read'
            dd if=/data/bench.bin of=/dev/null bs=$BENCH_BS 2>&1 | grep -v records
            rm -f /data/bench.bin
            sync

            echo 'bench: /tmp (ramdisk) sequential write (16 MiB, bs=1M, fsync)'
            dd if=/dev/zero of=/tmp/bench.bin bs=$BENCH_BS count=$BENCH_COUNT conv=fsync 2>&1 | grep -v records
            sync
            echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

            echo 'bench: /tmp sequential read'
            dd if=/tmp/bench.bin of=/dev/null bs=$BENCH_BS 2>&1 | grep -v records
            rm -f /tmp/bench.bin

            echo '===== BENCH END ====='

            BODY="PASS: storage=$CHECKSUM persist=$PERSIST_STATUS"
          else
            echo 'storage-test: WARNING /data not mounted'
            BODY="FAIL: /data not mounted"
          fi

          echo "storage-test: starting HTTP server on port 8080"
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

in pkgs.runCommand "test-storage-oci-bundle" {} ''
  mkdir -p $out/rootfs/bin $out/rootfs/tmp $out/rootfs/data

  # Use busybox for sh, nc, dd, md5sum, and basic utilities
  cp ${pkgs.pkgsStatic.busybox}/bin/busybox $out/rootfs/bin/busybox
  for cmd in sh nc echo cat ls mkdir dd md5sum sleep sync mountpoint cut grep rm; do
    ln -s busybox $out/rootfs/bin/$cmd
  done

  cp ${config} $out/config.json

  # No enclavia-config.json override — enclave.nix auto-generates a config
  # with the appropriate storage + kms_key_id when storageEnabled = true.
''
