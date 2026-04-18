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
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay, crane, nitro-util, enclavia-server, oci-bundle }:
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
        nitroLib = nitro-util.lib.${system};

        enclave = pkgs.callPackage ./nix/enclave.nix {
          inherit pkgs nitroLib enclaviaServerPkg;
          ociBundlePath = oci-bundle;
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
          inherit builder enclave debug-vm test-bundle test-enclave test-debug-vm;
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
