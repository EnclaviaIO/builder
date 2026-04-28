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

    # Stub placeholder — override at build time:
    #   --override-input enclavia-server path:../enclavia-server
    enclavia-server = {
      url = "path:./dummy-enclavia-server";
    };

    # Placeholder — override at build time:
    #   --override-input oci-bundle path:/path/to/bundle
    oci-bundle = {
      url = "path:./dummy-bundle";
      flake = false;
    };

    # NBD client for enclave storage — override at build time:
    #   --override-input nbd-client path:../enclavia-crates
    nbd-client = {
      url = "path:./dummy-nbd-client";
    };
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay, crane, nitro-util, enclavia-server, oci-bundle, nbd-client }:
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

        builder = craneLib.buildPackage (builderCommonArgs // {
          cargoArtifacts = builderCargoArtifacts;
          doCheck = false;
        });

        # --- Enclave EIF ---
        enclaviaServerPkg = enclavia-server.packages.${system}.enclavia-server-enclave;
        nbdClientPkg = nbd-client.packages.${system}.nbd-client-enclave;
        nitroLib = nitro-util.lib.${system};

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
          inherit pkgs nitroLib enclaviaServerPkg;
          ociBundlePath = oci-bundle;
        };

        enclave-debug = pkgs.callPackage ./nix/enclave.nix {
          inherit pkgs nitroLib enclaviaServerPkg;
          ociBundlePath = oci-bundle;
          debugMode = true;
        };

        enclave-storage = pkgs.callPackage ./nix/enclave.nix {
          inherit pkgs nitroLib enclaviaServerPkg nbdClientPkg;
          ociBundlePath = oci-bundle;
          storageEnabled = true;
          customKernel = storageKernel;
        };

        enclave-storage-debug = pkgs.callPackage ./nix/enclave.nix {
          inherit pkgs nitroLib enclaviaServerPkg nbdClientPkg;
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
          inherit pkgs nitroLib enclaviaServerPkg;
          ociBundlePath = test-bundle;
        };

        test-enclave-debug = pkgs.callPackage ./nix/enclave.nix {
          inherit pkgs nitroLib enclaviaServerPkg;
          ociBundlePath = test-bundle;
          debugMode = true;
        };

        # --- Storage test bundle + enclave ---
        test-storage-bundle = pkgs.callPackage ./nix/test-storage-bundle.nix { inherit pkgs; };

        test-enclave-storage-debug = pkgs.callPackage ./nix/enclave.nix {
          inherit pkgs nitroLib enclaviaServerPkg nbdClientPkg;
          ociBundlePath = test-storage-bundle;
          debugMode = true;
          storageEnabled = true;
          customKernel = storageKernel;
        };

        storageHostBin = "${nbd-client.packages.${system}.storage-host-debug or (throw "storage-host not built — override nbd-client input")}/bin/enclavia-storage";

        test-storage-vm = pkgs.writeShellScriptBin "enclavia-test-storage-vm" ''
          set -euo pipefail

          EIF_PATH="${test-enclave-storage-debug}/image.eif"
          MEMORY="''${1:-4G}"
          CPUS="''${2:-2}"

          GUEST_CID=4
          SOCK_DIR="$(${pkgs.coreutils}/bin/mktemp -d /tmp/enclave-storage-test.XXXXXX)"
          VHOST_SOCKET="''${SOCK_DIR}/vhost.sock"
          PROXY_SOCKET="''${SOCK_DIR}/proxy.sock"
          BACKING_FILE="''${SOCK_DIR}/disk.img"
          STORAGE_VSOCK_PORT=5001

          cleanup() {
              echo ""
              echo "storage-test-vm: cleaning up..."
              kill "''${HEARTBEAT_PID:-}" "''${VHOST_PID:-}" "''${STORAGE_PID:-}" 2>/dev/null || true
              wait "''${HEARTBEAT_PID:-}" "''${VHOST_PID:-}" "''${STORAGE_PID:-}" 2>/dev/null || true
              # Check if the backing file has data (non-zero blocks = I/O happened)
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
              ${pkgs.coreutils}/bin/rm -rf "''${SOCK_DIR}"
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

          # 3. Start storage daemon.
          # Guest CID 2:5001 maps to ''${PROXY_SOCKET}_5001
          echo "storage-test-vm: starting storage daemon (backing=''${BACKING_FILE}, 64M)..."
          BACKING_FILE="''${BACKING_FILE}" \
          DISK_SIZE="64M" \
          LISTEN_PATH="''${PROXY_SOCKET}_''${STORAGE_VSOCK_PORT}" \
          RUST_LOG=info \
              ${storageHostBin} &
          STORAGE_PID=$!

          for i in $(${pkgs.coreutils}/bin/seq 1 50); do
              [ -S "''${PROXY_SOCKET}_''${STORAGE_VSOCK_PORT}" ] && break
              ${pkgs.coreutils}/bin/sleep 0.1
          done
          if [ ! -S "''${PROXY_SOCKET}_''${STORAGE_VSOCK_PORT}" ]; then
              echo "storage-test-vm: ERROR: storage daemon socket not ready" >&2
              exit 1
          fi
          echo "storage-test-vm: storage daemon ready"

          # 4. Launch QEMU
          echo ""
          echo "  Watch the console output for 'storage-test:' messages."
          echo "  The enclave will mount /data via NBD and write test files."
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
          inherit builder enclave enclave-debug enclave-storage enclave-storage-debug debug-vm test-bundle test-enclave test-enclave-debug test-debug-vm test-storage-bundle test-enclave-storage-debug test-storage-vm;
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
