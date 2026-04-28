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
            if mountpoint -q /data 2>/dev/null || [ -d /data/lost+found ]; then
              break
            fi
            sleep 0.1
            i=$((i + 1))
          done

          if [ -d /data/lost+found ]; then
            echo 'storage-test: /data is mounted!'

            # Write test data
            echo 'STORAGE_TEST_OK' > /data/test.txt
            dd if=/dev/urandom of=/data/random.bin bs=1024 count=64 2>/dev/null
            CHECKSUM=$(md5sum /data/random.bin | cut -d' ' -f1)
            echo "$CHECKSUM" > /data/checksum.txt
            sync

            echo "storage-test: wrote test.txt and random.bin (md5=$CHECKSUM)"

            # Re-read and verify
            VERIFY=$(md5sum /data/random.bin | cut -d' ' -f1)
            if [ "$CHECKSUM" = "$VERIFY" ]; then
              echo 'storage-test: read-back checksum OK'
            else
              echo 'storage-test: ERROR checksum mismatch!'
            fi

            BODY="PASS: storage=$CHECKSUM"
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

  # Config that tells enclavia-server + init about the container port
  enclaviaConfig = pkgs.writeText "enclavia-config.json" (builtins.toJSON {
    listen_vsock_port = 5000;
    oci_bundle_path = "/var/lib/oci/bundle";
    customer_app = {
      port = 8080;
      health_check = "/health";
      startup_timeout_secs = 30;
    };
    storage = {
      enabled = true;
      vsock_port = 5001;
      mount_point = "/data";
      device = "/dev/nbd0";
    };
  });

in pkgs.runCommand "test-storage-oci-bundle" {} ''
  mkdir -p $out/rootfs/bin $out/rootfs/tmp $out/rootfs/data

  # Use busybox for sh, nc, dd, md5sum, and basic utilities
  cp ${pkgs.pkgsStatic.busybox}/bin/busybox $out/rootfs/bin/busybox
  for cmd in sh nc echo cat ls mkdir dd md5sum sleep sync mountpoint cut; do
    ln -s busybox $out/rootfs/bin/$cmd
  done

  cp ${config} $out/config.json

  # Override enclavia config with storage-enabled version
  cp ${enclaviaConfig} $out/enclavia-config.json
''
