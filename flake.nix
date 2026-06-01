{
  description = "Enclavia Builder — transforms Docker images into Nitro Enclave EIFs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane.url = "github:ipetkov/crane";

    nitro-util = {
      url = "github:monzo/aws-nitro-util";
      # Don't follow our nixpkgs — nitro-util's Go builds break with newer nixpkgs
    };

    # Placeholder — override at build time:
    #   --override-input oci-bundle path:/path/to/bundle
    oci-bundle = {
      url = "path:./dummy-bundle";
      flake = false;
    };

    # Host-side packages (egress-host, storage-host) live in the
    # closed-source enclavia-crates. Override at build time:
    #   --override-input enclavia-crates path:../enclavia-crates
    enclavia-crates = {
      url = "path:./dummy-enclavia-crates";
    };

    # In-enclave services (enclavia-server, enclavia-crypto, nbd-client,
    # enclavia-egress) plus the dev-only mock-kms live in the public
    # EnclaviaIO/enclavia workspace. `github:` is unauthenticated HTTPS,
    # so `nix build .#builder` and `enclavia reproduce` work out of the
    # box for users without an SSH key on file with GitHub.
    # Override during local development with
    # `--override-input enclavia path:../enclavia`.
    enclavia = {
      url = "github:EnclaviaIO/enclavia";
    };
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay, crane, nitro-util, oci-bundle, enclavia-crates, enclavia }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          overlays = [ rust-overlay.overlays.default ];
          inherit system;
        };

        # --- Rust toolchain ---
        rustToolchain = pkgs: (pkgs.rust-bin.stable."1.88.0".default.override {
          extensions = [ "rust-src" "rust-analyzer" ];
        });

        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

        # --- Builder binary ---
        builderSrc = craneLib.cleanCargoSource ./.;

        builderCommonArgs = {
          src = builderSrc;
          strictDeps = true;
        };

        builderCargoArtifacts = craneLib.buildDepsOnly builderCommonArgs;

        # The builder shells out to `skopeo` (pull OCI image), `umoci`
        # (unpack to a runtime bundle), and `nix` (drive the EIF build).
        # `nix` is a reasonable PATH assumption (you can't install the
        # builder without it), but `skopeo` and `umoci` aren't, so wrap
        # them into the binary's PATH at install time. Without this,
        # `BUILDER_PATH=result/bin/builder enclavia reproduce <id>`
        # trips on `skopeo: No such file or directory` on the very first
        # call.
        #
        # We do NOT bake a default `BUILDER_FLAKE`. The flake source
        # determines the recipe used to build the EIF and therefore the
        # PCRs the comparison will produce: defaulting to `self` would
        # silently make the local rebuild use this binary's own source
        # tree, which is almost never the rev the backend was deployed
        # from. Callers (the `enclavia` CLI, deployment systemd units)
        # must pass `BUILDER_FLAKE` explicitly, ideally pointing at the
        # rev the backend recorded for the enclave being reproduced.
        builder = craneLib.buildPackage (builderCommonArgs // {
          cargoArtifacts = builderCargoArtifacts;
          doCheck = false;
          nativeBuildInputs = (builderCommonArgs.nativeBuildInputs or []) ++ [ pkgs.makeWrapper ];
          postInstall = ''
            wrapProgram $out/bin/builder \
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.skopeo pkgs.umoci ]}
          '';
        });

        # --- Enclave EIF ---
        # In-enclave packages + mock-kms come from the public EnclaviaIO/enclavia
        # workspace. Host-side packages (storage-host, egress-host) still
        # come from `enclavia-crates` further below.
        enclaviaServerPkg = enclavia.packages.${system}.enclavia-server;
        nbdClientPkg = enclavia.packages.${system}.nbd-client;
        enclaviaCryptoPkg = enclavia.packages.${system}.enclavia-crypto;
        enclaviaEgressPkg = enclavia.packages.${system}.enclavia-egress;
        mockKmsPkg = enclavia.packages.${system}.mock-kms;
        nitroLib = nitro-util.lib.${system};

        # Test KMS key ID seeded into the bootstrap blob (first 4KB of the
        # backing file) by test-storage-vm. enclavia-crypto reads it from there
        # at boot to talk to mock-kms.
        testKmsKeyId = "test-key-001";

        # Custom kernel with NBD block device support for storage-enabled enclaves.
        # Based on the minimal AWS nitro kernel config (~1000 options) with
        # CONFIG_BLK_DEV_NBD=y and CONFIG_NSM=y added, adapted to a modern
        # kernel source via `make oldconfig`.
        storageKernel = pkgs.linuxManualConfig {
          version = pkgs.linuxPackages_latest.kernel.version;
          src = pkgs.linuxPackages_latest.kernel.src;
          configfile = ./nix/enclave-kernel.config;
          allowImportFromDerivation = true;
          kernelPatches = [{
            name = "nbd-vsock-support";
            patch = ./nix/nbd-vsock.patch;
          }];
        };

        enclave = pkgs.callPackage ./nix/enclave.nix {
          inherit pkgs nitroLib enclaviaServerPkg enclaviaEgressPkg;
          ociBundlePath = oci-bundle;
        };

        enclave-debug = pkgs.callPackage ./nix/enclave.nix {
          inherit pkgs nitroLib enclaviaServerPkg enclaviaEgressPkg;
          ociBundlePath = oci-bundle;
          debugMode = true;
        };

        enclave-storage = pkgs.callPackage ./nix/enclave.nix {
          inherit pkgs nitroLib enclaviaServerPkg nbdClientPkg enclaviaCryptoPkg enclaviaEgressPkg;
          ociBundlePath = oci-bundle;
          storageEnabled = true;
          customKernel = storageKernel;
        };

        enclave-storage-debug = pkgs.callPackage ./nix/enclave.nix {
          inherit pkgs nitroLib enclaviaServerPkg nbdClientPkg enclaviaCryptoPkg enclaviaEgressPkg;
          ociBundlePath = oci-bundle;
          debugMode = true;
          storageEnabled = true;
          customKernel = storageKernel;
        };

        # --- Debug VM launcher ---
        # Wraps the EIF with a script that launches QEMU nitro-enclave locally.
        # Handles vhost-device-vsock setup and heartbeat responding.
        heartbeatScript = ./nix/heartbeat.py;

        debug-vm = pkgs.writeShellScriptBin "enclavia-debug-vm" ''
          set -euo pipefail

          EIF_PATH="${enclave}/image.eif"
          MEMORY="''${1:-4G}"
          CPUS="''${2:-2}"

          GUEST_CID=4
          SOCK_DIR="$(${pkgs.coreutils}/bin/mktemp -d /tmp/enclave-debug.XXXXXX)"
          VHOST_SOCKET="''${SOCK_DIR}/vhost.sock"

          cleanup() {
              echo "debug-vm: cleaning up..."
              kill "''${HEARTBEAT_PID:-}" "''${VHOST_PID:-}" 2>/dev/null || true
              wait "''${HEARTBEAT_PID:-}" "''${VHOST_PID:-}" 2>/dev/null || true
              ${pkgs.coreutils}/bin/rm -rf "''${SOCK_DIR}"
          }
          trap cleanup EXIT

          echo "debug-vm: socket dir = ''${SOCK_DIR}"
          echo "debug-vm: EIF        = ''${EIF_PATH}"
          echo "debug-vm: memory     = ''${MEMORY}, cpus = ''${CPUS}"

          # 1. Start vhost-device-vsock with --forward-cid for guest-to-host forwarding
          echo "debug-vm: starting vhost-device-vsock (CID ''${GUEST_CID})..."
          vhost-device-vsock \
              --vm "guest-cid=''${GUEST_CID},socket=''${VHOST_SOCKET},forward-cid=1" &
          VHOST_PID=$!

          for i in $(${pkgs.coreutils}/bin/seq 1 50); do
              [ -S "''${VHOST_SOCKET}" ] && break
              ${pkgs.coreutils}/bin/sleep 0.1
          done
          if [ ! -S "''${VHOST_SOCKET}" ]; then
              echo "debug-vm: ERROR: vhost-device-vsock did not create socket" >&2
              exit 1
          fi

          # 2. Start heartbeat responder on AF_VSOCK (enclave init sends 0xB7 to port 9000)
          echo "debug-vm: starting heartbeat responder..."
          ${pkgs.python3}/bin/python3 ${heartbeatScript} &
          HEARTBEAT_PID=$!

          # 3. Launch QEMU
          echo ""
          echo "  Enclave vsock port 5000 is forwarded via AF_VSOCK."
          echo "  Connect host-side software to vsock CID ''${GUEST_CID} port 5000 for testing."
          echo ""

          qemu-system-x86_64 \
              -M "nitro-enclave,vsock=c,id=enclavia-debug" \
              -chardev "socket,id=c,path=''${VHOST_SOCKET}" \
              -kernel "''${EIF_PATH}" \
              -nographic \
              -m "''${MEMORY}" \
              -smp "''${CPUS}" \
              --enable-kvm \
              -cpu host
        '';

        # --- Test bundle + enclave ---
        # Minimal OCI bundle with a busybox hello-world HTTP server for testing.
        test-bundle = pkgs.callPackage ./nix/test-bundle.nix { inherit pkgs; };

        test-enclave = pkgs.callPackage ./nix/enclave.nix {
          inherit pkgs nitroLib enclaviaServerPkg enclaviaEgressPkg;
          ociBundlePath = test-bundle;
        };

        test-enclave-debug = pkgs.callPackage ./nix/enclave.nix {
          inherit pkgs nitroLib enclaviaServerPkg enclaviaEgressPkg;
          ociBundlePath = test-bundle;
          debugMode = true;
        };

        # --- WS test bundle + enclave ---
        # OCI bundle whose entrypoint is the `ws-echo-test` binary built
        # in the enclavia-crates workspace (a tokio-tungstenite echo
        # server bound to 0.0.0.0:8080). Used by tests/run_e2e_ws.sh to
        # drive a real WebSocket upgrade end-to-end through router +
        # enclavia-server + crun.
        wsEchoBin = enclavia-crates.packages.${system}.ws-echo-test
          or (throw "ws-echo-test not built; override enclavia-crates input");

        test-ws-bundle = pkgs.callPackage ./nix/test-ws-bundle.nix {
          inherit pkgs wsEchoBin;
        };

        test-enclave-ws-debug = pkgs.callPackage ./nix/enclave.nix {
          inherit pkgs nitroLib enclaviaServerPkg enclaviaEgressPkg;
          ociBundlePath = test-ws-bundle;
          debugMode = true;
        };

        # --- Egress test bundle + enclave ---
        # Minimal OCI bundle that opens TCP to TARGET_IP:TARGET_PORT (env vars
        # set by the e2e wrapper), writes "ping\n", and exits 0 iff the reply
        # is "pong\n". Used by tests/run_e2e_egress.sh.
        test-egress-bundle = pkgs.callPackage ./nix/test-egress-bundle.nix { inherit pkgs; };

        test-enclave-egress-debug = pkgs.callPackage ./nix/enclave.nix {
          inherit pkgs nitroLib enclaviaServerPkg enclaviaEgressPkg;
          ociBundlePath = test-egress-bundle;
          debugMode = true;
        };

        # --- Storage test bundle + enclave ---
        test-storage-bundle = pkgs.callPackage ./nix/test-storage-bundle.nix { inherit pkgs; };

        test-enclave-storage-debug = pkgs.callPackage ./nix/enclave.nix {
          inherit pkgs nitroLib enclaviaServerPkg nbdClientPkg enclaviaCryptoPkg enclaviaEgressPkg;
          ociBundlePath = test-storage-bundle;
          debugMode = true;
          storageEnabled = true;
          customKernel = storageKernel;
        };

        # Diagnostic variant: storage path skips LUKS so the proxy is exercised
        # against raw btrfs writes. Used to isolate proxy throughput from
        # cryptsetup overhead on TCG.
        test-enclave-storage-debug-no-luks = pkgs.callPackage ./nix/enclave.nix {
          inherit pkgs nitroLib enclaviaServerPkg nbdClientPkg enclaviaCryptoPkg enclaviaEgressPkg;
          ociBundlePath = test-storage-bundle;
          debugMode = true;
          storageEnabled = true;
          skipLuks = true;
          customKernel = storageKernel;
        };

        storageHostBin = "${enclavia-crates.packages.${system}.storage-host-debug or (throw "storage-host not built — override enclavia-crates input")}/bin/enclavia-storage";
        mockKmsBin = "${mockKmsPkg}/bin/enclavia-mock-kms";

        test-storage-vm = pkgs.writeShellScriptBin "enclavia-test-storage-vm" ''
          set -euo pipefail

          # NO_LUKS=1 swaps in a diagnostic EIF where init.sh runs mkfs.btrfs
          # straight on /dev/nbd0, bypassing cryptsetup. Used to isolate the
          # NBD proxy's behaviour from LUKS overhead on TCG.
          if [ "''${NO_LUKS:-0}" = "1" ]; then
              EIF_PATH="${test-enclave-storage-debug-no-luks}/image.eif"
              echo "storage-test-vm: NO_LUKS=1 → using LUKS-bypass EIF"
          else
              EIF_PATH="${test-enclave-storage-debug}/image.eif"
          fi
          MEMORY="''${1:-4G}"
          CPUS="''${2:-2}"

          GUEST_CID=4
          # If STORAGE_TEST_DIR is set, reuse that directory across runs (persistence test).
          # Otherwise mktemp a fresh dir and clean it up at exit.
          if [ -n "''${STORAGE_TEST_DIR:-}" ]; then
              SOCK_DIR="''${STORAGE_TEST_DIR}"
              ${pkgs.coreutils}/bin/mkdir -p "''${SOCK_DIR}"
              PERSIST=1
          else
              SOCK_DIR="$(${pkgs.coreutils}/bin/mktemp -d /tmp/enclave-storage-test.XXXXXX)"
              PERSIST=0
          fi
          VHOST_SOCKET="''${SOCK_DIR}/vhost.sock"
          PROXY_SOCKET="''${SOCK_DIR}/proxy.sock"
          BACKING_FILE="''${SOCK_DIR}/disk.img"
          KEY_DIR="''${SOCK_DIR}/kms-keys"
          STORAGE_VSOCK_PORT=5001
          META_VSOCK_PORT=5002
          KMS_VSOCK_PORT=5003
          KMS_KEY_ID="${testKmsKeyId}"

          cleanup() {
              echo ""
              echo "storage-test-vm: cleaning up..."
              kill "''${HEARTBEAT_PID:-}" "''${VHOST_PID:-}" "''${STORAGE_PID:-}" "''${MOCK_KMS_PID:-}" 2>/dev/null || true
              wait "''${HEARTBEAT_PID:-}" "''${VHOST_PID:-}" "''${STORAGE_PID:-}" "''${MOCK_KMS_PID:-}" 2>/dev/null || true
              if [ -f "''${BACKING_FILE}" ]; then
                  BLOCKS=$(${pkgs.coreutils}/bin/stat --format=%b "''${BACKING_FILE}")
                  SIZE=$(${pkgs.coreutils}/bin/stat --format=%s "''${BACKING_FILE}")
                  echo "storage-test-vm: backing file: apparent=''${SIZE} bytes, blocks=''${BLOCKS}"
                  if [ "''${BLOCKS}" -gt 0 ]; then
                      echo "storage-test-vm: ===== STORAGE I/O DETECTED (backing file has data) ====="
                  else
                      echo "storage-test-vm: WARNING: backing file has no data blocks"
                  fi
              fi
              if [ "''${PERSIST}" = "1" ]; then
                  echo "storage-test-vm: STORAGE_TEST_DIR set — preserving ''${SOCK_DIR} for re-run"
                  # Sockets won't survive a re-run anyway, drop them so the new run can recreate.
                  ${pkgs.coreutils}/bin/rm -f "''${VHOST_SOCKET}" "''${PROXY_SOCKET}"_* 2>/dev/null || true
              else
                  ${pkgs.coreutils}/bin/rm -rf "''${SOCK_DIR}"
              fi
          }
          trap cleanup EXIT

          echo "storage-test-vm: socket dir    = ''${SOCK_DIR}"
          echo "storage-test-vm: EIF           = ''${EIF_PATH}"
          echo "storage-test-vm: backing file  = ''${BACKING_FILE}"
          echo "storage-test-vm: memory = ''${MEMORY}, cpus = ''${CPUS}"

          # 1. Start vhost-device-vsock in UDS mode.
          # Guest vsock connections to CID 2:PORT map to ''${PROXY_SOCKET}_PORT
          echo "storage-test-vm: starting vhost-device-vsock (CID ''${GUEST_CID}, UDS mode)..."
          vhost-device-vsock \
              --vm "guest-cid=''${GUEST_CID},socket=''${VHOST_SOCKET},uds-path=''${PROXY_SOCKET}" &
          VHOST_PID=$!

          for i in $(${pkgs.coreutils}/bin/seq 1 50); do
              [ -S "''${VHOST_SOCKET}" ] && break
              ${pkgs.coreutils}/bin/sleep 0.1
          done
          if [ ! -S "''${VHOST_SOCKET}" ]; then
              echo "storage-test-vm: ERROR: vhost-device-vsock did not create socket" >&2
              exit 1
          fi

          # 2. Start heartbeat responder.
          # In UDS mode, guest CID 2:9000 maps to ''${PROXY_SOCKET}_9000
          echo "storage-test-vm: starting heartbeat responder..."
          ${pkgs.python3}/bin/python3 ${heartbeatScript} --uds "''${PROXY_SOCKET}_9000" &
          HEARTBEAT_PID=$!

          for i in $(${pkgs.coreutils}/bin/seq 1 50); do
              [ -S "''${PROXY_SOCKET}_9000" ] && break
              ${pkgs.coreutils}/bin/sleep 0.1
          done

          # 3. Pre-write the bootstrap key blob to the first 4KB of the backing file.
          # The backend would do this in production; in dev we synthesize it here.
          # Skip if the file already exists and has data (persistence-test re-run).
          if [ -s "''${BACKING_FILE}" ]; then
              echo "storage-test-vm: re-using existing backing file (size=$(${pkgs.coreutils}/bin/stat --format=%s "''${BACKING_FILE}"))"
          else
              echo "storage-test-vm: writing bootstrap key blob..."
              ${pkgs.coreutils}/bin/printf '%s' '{"version":1,"kms_key_id":"'"''${KMS_KEY_ID}"'"}' > "''${BACKING_FILE}"
              ${pkgs.coreutils}/bin/truncate -s 4096 "''${BACKING_FILE}"
          fi

          # 4. Start storage daemon (NBD on 5001, key-blob on 5002).
          # 256M is the practical floor: btrfs requires ~114M, and LUKS eats a
          # 16M header on top, so anything smaller fails mkfs.
          echo "storage-test-vm: starting storage daemon (backing=''${BACKING_FILE}, 256M)..."
          BACKING_FILE="''${BACKING_FILE}" \
          DISK_SIZE="256M" \
          LISTEN_PATH="''${PROXY_SOCKET}_''${STORAGE_VSOCK_PORT}" \
          META_LISTEN_PATH="''${PROXY_SOCKET}_''${META_VSOCK_PORT}" \
          RUST_LOG="''${RUST_LOG:-info}" \
              ${storageHostBin} &
          STORAGE_PID=$!

          for i in $(${pkgs.coreutils}/bin/seq 1 50); do
              [ -S "''${PROXY_SOCKET}_''${STORAGE_VSOCK_PORT}" ] \
                  && [ -S "''${PROXY_SOCKET}_''${META_VSOCK_PORT}" ] \
                  && break
              ${pkgs.coreutils}/bin/sleep 0.1
          done
          if [ ! -S "''${PROXY_SOCKET}_''${STORAGE_VSOCK_PORT}" ] \
              || [ ! -S "''${PROXY_SOCKET}_''${META_VSOCK_PORT}" ]; then
              echo "storage-test-vm: ERROR: storage daemon sockets not ready" >&2
              exit 1
          fi
          echo "storage-test-vm: storage daemon ready"

          # 5. Start mock-kms (UDS at PROXY_SOCKET_5003 so guest CID 2:5003 reaches it).
          echo "storage-test-vm: starting mock-kms (key_dir=''${KEY_DIR})..."
          ${pkgs.coreutils}/bin/mkdir -p "''${KEY_DIR}"
          LISTEN_PATH="''${PROXY_SOCKET}_''${KMS_VSOCK_PORT}" \
          KEY_DIR="''${KEY_DIR}" \
          RUST_LOG=info \
              ${mockKmsBin} &
          MOCK_KMS_PID=$!

          for i in $(${pkgs.coreutils}/bin/seq 1 50); do
              [ -S "''${PROXY_SOCKET}_''${KMS_VSOCK_PORT}" ] && break
              ${pkgs.coreutils}/bin/sleep 0.1
          done
          if [ ! -S "''${PROXY_SOCKET}_''${KMS_VSOCK_PORT}" ]; then
              echo "storage-test-vm: ERROR: mock-kms socket not ready" >&2
              exit 1
          fi
          echo "storage-test-vm: mock-kms ready"

          # 6. Launch QEMU
          echo ""
          echo "  Watch the console output for 'storage-test:' messages."
          echo "  The enclave will mount a LUKS-encrypted btrfs at /data via NBD and write test files."
          echo "  Press Ctrl-C to stop."
          echo ""

          QEMU_ARGS=(
              -M "nitro-enclave,vsock=c,id=enclavia-debug"
              -chardev "socket,id=c,path=''${VHOST_SOCKET}"
              -kernel "''${EIF_PATH}"
              -nographic
              -m "''${MEMORY}"
              -smp "''${CPUS}"
          )

          if [ -e /dev/kvm ]; then
              QEMU_ARGS+=(--enable-kvm -cpu host)
          else
              QEMU_ARGS+=(-cpu max)
          fi

          qemu-system-x86_64 "''${QEMU_ARGS[@]}"
        '';

        egressHostBin = "${enclavia-crates.packages.${system}.egress-host-debug or (throw "egress-host not built; override enclavia-crates input")}/bin/enclavia-egress-host";

        # Wrapper for the egress e2e test. UDS mode (not forward-cid) so the
        # guest's CID-2 vsock 5006 connect()s land on ${PROXY}_5006, which
        # egress-host listens on. The TARGET_IP / TARGET_PORT for the
        # in-enclave workload are passed via the kernel command line; init.sh
        # surfaces them as /etc/egress-test.env inside the OCI rootfs.
        test-egress-vm = pkgs.writeShellScriptBin "enclavia-test-egress-vm" ''
          set -euo pipefail

          EIF_PATH="${test-enclave-egress-debug}/image.eif"
          MEMORY="''${MEMORY:-4G}"
          CPUS="''${CPUS:-2}"

          # The in-enclave workload connects to TARGET_IP:TARGET_PORT. The
          # destination must NOT be in 127.0.0.0/8 (the enclave's `lo` would
          # grab it and the egress path would never see the SYN). The harness
          # script chooses a host-routable IP, typically derived from
          # `ip route get`, and passes it in.
          : "''${TARGET_IP:?TARGET_IP not set (point at where egress-host can reach the echo server)}"
          : "''${TARGET_PORT:?TARGET_PORT not set}"

          GUEST_CID=4
          EGRESS_VSOCK_PORT=5006

          SOCK_DIR="$(${pkgs.coreutils}/bin/mktemp -d /tmp/enclave-egress-test.XXXXXX)"
          VHOST_SOCKET="''${SOCK_DIR}/vhost.sock"
          PROXY_SOCKET="''${SOCK_DIR}/proxy.sock"

          cleanup() {
              echo ""
              echo "egress-test-vm: cleaning up..."
              kill "''${HEARTBEAT_PID:-}" "''${VHOST_PID:-}" "''${EGRESS_PID:-}" 2>/dev/null || true
              wait "''${HEARTBEAT_PID:-}" "''${VHOST_PID:-}" "''${EGRESS_PID:-}" 2>/dev/null || true
              ${pkgs.coreutils}/bin/rm -rf "''${SOCK_DIR}"
          }
          trap cleanup EXIT

          echo "egress-test-vm: socket dir   = ''${SOCK_DIR}"
          echo "egress-test-vm: EIF          = ''${EIF_PATH}"
          echo "egress-test-vm: target       = ''${TARGET_IP}:''${TARGET_PORT}"
          echo "egress-test-vm: memory       = ''${MEMORY}, cpus = ''${CPUS}"

          echo "egress-test-vm: starting vhost-device-vsock (CID ''${GUEST_CID}, UDS mode)..."
          vhost-device-vsock \
              --vm "guest-cid=''${GUEST_CID},socket=''${VHOST_SOCKET},uds-path=''${PROXY_SOCKET}" &
          VHOST_PID=$!

          for i in $(${pkgs.coreutils}/bin/seq 1 50); do
              [ -S "''${VHOST_SOCKET}" ] && break
              ${pkgs.coreutils}/bin/sleep 0.1
          done
          if [ ! -S "''${VHOST_SOCKET}" ]; then
              echo "egress-test-vm: ERROR: vhost-device-vsock did not create socket" >&2
              exit 1
          fi

          echo "egress-test-vm: starting heartbeat responder..."
          ${pkgs.python3}/bin/python3 ${heartbeatScript} --uds "''${PROXY_SOCKET}_9000" &
          HEARTBEAT_PID=$!

          for i in $(${pkgs.coreutils}/bin/seq 1 50); do
              [ -S "''${PROXY_SOCKET}_9000" ] && break
              ${pkgs.coreutils}/bin/sleep 0.1
          done

          echo "egress-test-vm: starting egress-host on ''${PROXY_SOCKET}_''${EGRESS_VSOCK_PORT}..."
          EGRESS_LISTEN_PATH="''${PROXY_SOCKET}_''${EGRESS_VSOCK_PORT}" \
          RUST_LOG="''${RUST_LOG:-info}" \
              ${egressHostBin} &
          EGRESS_PID=$!

          for i in $(${pkgs.coreutils}/bin/seq 1 50); do
              [ -S "''${PROXY_SOCKET}_''${EGRESS_VSOCK_PORT}" ] && break
              ${pkgs.coreutils}/bin/sleep 0.1
          done
          if [ ! -S "''${PROXY_SOCKET}_''${EGRESS_VSOCK_PORT}" ]; then
              echo "egress-test-vm: ERROR: egress-host socket did not appear" >&2
              exit 1
          fi

          echo ""
          echo "  Watch the console output for 'egress-test:' messages."
          echo "  The workload tries TARGET_IP:TARGET_PORT once and exits."
          echo ""

          # The nitro-enclave machine has its own `append=` option for the
          # kernel command line; the top-level `-append` flag is masked. Pass
          # the target plumbing as machine properties so init.sh sees them
          # in /proc/cmdline.
          APPEND="enclavia.target_ip=''${TARGET_IP} enclavia.target_port=''${TARGET_PORT}"
          if [ -n "''${RESOLVER:-}" ]; then
              APPEND="''${APPEND} enclavia.resolver=''${RESOLVER}"
          fi
          QEMU_ARGS=(
              -M "nitro-enclave,vsock=c,id=enclavia-egress-test,append=''${APPEND}"
              -chardev "socket,id=c,path=''${VHOST_SOCKET}"
              -kernel "''${EIF_PATH}"
              -nographic
              -m "''${MEMORY}"
              -smp "''${CPUS}"
          )

          if [ -e /dev/kvm ]; then
              QEMU_ARGS+=(--enable-kvm -cpu host)
          else
              QEMU_ARGS+=(-cpu max)
          fi

          qemu-system-x86_64 "''${QEMU_ARGS[@]}"
        '';

        test-debug-vm = pkgs.writeShellScriptBin "enclavia-test-debug-vm" ''
          set -euo pipefail

          EIF_PATH="${test-enclave}/image.eif"
          MEMORY="''${1:-4G}"
          CPUS="''${2:-2}"

          GUEST_CID=4
          SOCK_DIR="$(${pkgs.coreutils}/bin/mktemp -d /tmp/enclave-debug.XXXXXX)"
          VHOST_SOCKET="''${SOCK_DIR}/vhost.sock"

          cleanup() {
              echo "debug-vm: cleaning up..."
              kill "''${HEARTBEAT_PID:-}" "''${VHOST_PID:-}" 2>/dev/null || true
              wait "''${HEARTBEAT_PID:-}" "''${VHOST_PID:-}" 2>/dev/null || true
              ${pkgs.coreutils}/bin/rm -rf "''${SOCK_DIR}"
          }
          trap cleanup EXIT

          echo "debug-vm: socket dir = ''${SOCK_DIR}"
          echo "debug-vm: EIF        = ''${EIF_PATH}"
          echo "debug-vm: memory     = ''${MEMORY}, cpus = ''${CPUS}"

          echo "debug-vm: starting vhost-device-vsock (CID ''${GUEST_CID})..."
          vhost-device-vsock \
              --vm "guest-cid=''${GUEST_CID},socket=''${VHOST_SOCKET},forward-cid=1" &
          VHOST_PID=$!

          for i in $(${pkgs.coreutils}/bin/seq 1 50); do
              [ -S "''${VHOST_SOCKET}" ] && break
              ${pkgs.coreutils}/bin/sleep 0.1
          done
          if [ ! -S "''${VHOST_SOCKET}" ]; then
              echo "debug-vm: ERROR: vhost-device-vsock did not create socket" >&2
              exit 1
          fi

          echo "debug-vm: starting heartbeat responder..."
          ${pkgs.python3}/bin/python3 ${heartbeatScript} &
          HEARTBEAT_PID=$!

          echo ""
          echo "  Enclave vsock port 5000 is forwarded via AF_VSOCK."
          echo "  Connect host-side software to vsock CID ''${GUEST_CID} port 5000 for testing."
          echo ""

          qemu-system-x86_64 \
              -M "nitro-enclave,vsock=c,id=enclavia-debug" \
              -chardev "socket,id=c,path=''${VHOST_SOCKET}" \
              -kernel "''${EIF_PATH}" \
              -nographic \
              -m "''${MEMORY}" \
              -smp "''${CPUS}" \
              --enable-kvm \
              -cpu host
        '';

      in
      {
        packages = {
          inherit builder enclave enclave-debug enclave-storage enclave-storage-debug debug-vm test-bundle test-enclave test-enclave-debug test-debug-vm test-storage-bundle test-enclave-storage-debug test-enclave-storage-debug-no-luks test-storage-vm test-egress-bundle test-enclave-egress-debug test-egress-vm test-ws-bundle test-enclave-ws-debug;
          default = builder;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            (rustToolchain pkgs)
            pkgs.skopeo
            pkgs.umoci
          ];
        };
      }
    );
}
