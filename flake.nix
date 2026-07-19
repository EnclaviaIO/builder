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

    # Placeholder — the builder overrides this with a directory containing
    # `bundle.tar`, its deterministic OCI payload archive.
    #   --override-input oci-bundle path:/path/to/archive-input
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
      # Pinned to EnclaviaIO/enclavia master after #76, which builds the
      # customer-enclave binaries as fully static musl executables. This
      # avoids pulling glibc and libgcc into the measured initramfs.
      url = "github:EnclaviaIO/enclavia/b414ec0334594b390b98c1157cd1cc2537827e28";
    };
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay, crane, nitro-util, oci-bundle, enclavia-crates, enclavia }:
    # Building EIFs depends on Linux/x86_64-specific Nitro tooling. Restrict
    # the output matrix so unsupported hosts fail during flake resolution,
    # before evaluating the build dependency graph.
    flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
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
        enclaviaSecretsInitPkg = enclavia.packages.${system}.enclavia-secrets-init;
        enclaviaChainInitPkg = enclavia.packages.${system}.enclavia-chain-init;
        mockKmsPkg = enclavia.packages.${system}.mock-kms;
        nitroLib = nitro-util.lib.${system};

        # In-tree fixtures are ordinary Nix-built bundle directories. Package
        # them with the same rootfs-relative shape consumed by enclave.nix.
        # Production does not use this helper: the Rust builder supplies an
        # umoci-generated tar which retains the customer's original metadata.
        mkOciBundleArchive = name: bundle: pkgs.runCommand "${name}-payload.tar" {
          nativeBuildInputs = [ pkgs.gnutar pkgs.coreutils ];
        } ''
          set -euo pipefail
          mkdir -p staging/rootfs/var/lib/oci staging/rootfs/etc/enclavia
          chmod 0755 staging staging/rootfs staging/rootfs/var \
            staging/rootfs/var/lib staging/rootfs/var/lib/oci \
            staging/rootfs/etc staging/rootfs/etc/enclavia
          cp -a ${bundle} staging/rootfs/var/lib/oci/bundle
          if [ -f ${bundle}/enclavia-config.json ]; then
            cp ${bundle}/enclavia-config.json staging/rootfs/etc/enclavia/config.json
            chmod 0644 staging/rootfs/etc/enclavia/config.json
          fi
          if [ -f ${bundle}/egress.json ]; then
            cp ${bundle}/egress.json staging/rootfs/etc/enclavia/egress.json
            chmod 0644 staging/rootfs/etc/enclavia/egress.json
          fi
          tar \
            --create \
            --file=$out \
            --format=posix \
            --sort=name \
            --mtime=@1 \
            --owner=0 \
            --group=0 \
            --numeric-owner \
            --pax-option=delete=atime,delete=ctime \
            --xattrs \
            --directory=staging \
            rootfs
        '';

        suppliedBundleArchive = oci-bundle + "/bundle.tar";
        ociBundleArchive = if builtins.pathExists suppliedBundleArchive
          then suppliedBundleArchive
          else mkOciBundleArchive "placeholder-oci-bundle" oci-bundle;

        # Test KMS key ID seeded into the bootstrap blob (first 4KB of the
        # backing file) by test-storage-vm. enclavia-crypto reads it from there
        # at boot to talk to mock-kms.
        testKmsKeyId = "test-key-001";

        # Both EIF profiles use the maintained kernel pinned by nixpkgs.  A
        # small KCONFIG_ALLCONFIG seed is resolved with allnoconfig first, so
        # advancing nixpkgs cannot silently add new default-y kernel features.
        kernelSource = pkgs.linuxPackages_latest.kernel;
        enclaveKernelConfig = pkgs.callPackage ./nix/kernel-config.nix {
          kernel = kernelSource;
        };
        storageKernelConfig = pkgs.callPackage ./nix/kernel-config.nix {
          kernel = kernelSource;
          storage = true;
        };

        mkEnclaveKernel = { config, kernelPatches ? [] }:
          pkgs.linuxManualConfig {
            version = kernelSource.version;
            src = kernelSource.src;
            configfile = "${config}/config";
            allowImportFromDerivation = true;
            inherit kernelPatches;
          };

        enclaveKernel = mkEnclaveKernel {
          config = enclaveKernelConfig;
        };

        storageKernel = mkEnclaveKernel {
          config = storageKernelConfig;
          kernelPatches = [{
            name = "nbd-vsock-support";
            patch = ./nix/nbd-vsock.patch;
          }];
        };

        # Builds the two bzImages and representative EIFs, then records their
        # byte sizes alongside the retired Linux 4.14 non-storage blob.
        # Storage's before/after comparison requires a separate build of the
        # earlier worktree; see docs/kernel.md.
        kernelSizeReport = pkgs.runCommand "enclavia-kernel-size-report" {} ''
          mkdir "$out"
          legacy_bytes=$(${pkgs.coreutils}/bin/stat -c %s ${nitroLib.blobs.x86_64.kernel})
          legacy_built_ins=$(${pkgs.gawk}/bin/awk -F= '$2 == "y" { count++ } END { print count + 0 }' ${nitroLib.blobs.x86_64.kernelConfig})
          legacy_modules=$(${pkgs.gawk}/bin/awk -F= '$2 == "m" { count++ } END { print count + 0 }' ${nitroLib.blobs.x86_64.kernelConfig})
          base_bytes=$(${pkgs.coreutils}/bin/stat -c %s ${enclaveKernel}/bzImage)
          storage_bytes=$(${pkgs.coreutils}/bin/stat -c %s ${storageKernel}/bzImage)
          base_eif_bytes=$(${pkgs.coreutils}/bin/stat -c %s ${test-enclave}/image.eif)
          storage_eif_bytes=$(${pkgs.coreutils}/bin/stat -c %s ${test-enclave-storage-debug}/image.eif)
          base_reduction=$((legacy_bytes - base_bytes))
          base_percent=$((base_reduction * 100 / legacy_bytes))
          {
            echo "legacy-linux-4.14-bzimage-bytes=$legacy_bytes"
            echo "legacy-linux-4.14-built-in-options=$legacy_built_ins"
            echo "legacy-linux-4.14-module-options=$legacy_modules"
            echo "base-bzimage-bytes=$base_bytes"
            echo "base-vs-legacy-reduction-bytes=$base_reduction"
            echo "base-vs-legacy-reduction-percent=$base_percent"
            echo "storage-bzimage-bytes=$storage_bytes"
            echo "base-test-eif-bytes=$base_eif_bytes"
            echo "storage-test-eif-bytes=$storage_eif_bytes"
          } > "$out/report"
          cp ${enclaveKernelConfig}/report "$out/base-config-report"
          cp ${storageKernelConfig}/report "$out/storage-config-report"
        '';

        # Keep the production feature matrix in one recipe. The unsuffixed
        # targets are deny-all and contain no egress stack; `-egress` targets
        # opt in explicitly when the builder receives --egress-allowlist.
        mkProductionEnclave = {
          debugMode ? false,
          storageEnabled ? false,
          egressEnabled ? false,
          rootfsOnly ? false,
        }: pkgs.callPackage ./nix/enclave.nix {
          inherit pkgs nitroLib enclaviaServerPkg nbdClientPkg enclaviaCryptoPkg enclaviaSecretsInitPkg enclaviaChainInitPkg;
          inherit ociBundleArchive debugMode storageEnabled egressEnabled rootfsOnly;
          enclaviaEgressPkg = if egressEnabled then enclaviaEgressPkg else null;
          customKernel = if storageEnabled then storageKernel else enclaveKernel;
        };

        enclave = mkProductionEnclave { };
        enclave-debug = mkProductionEnclave { debugMode = true; };
        enclave-storage = mkProductionEnclave { storageEnabled = true; };
        enclave-storage-debug = mkProductionEnclave {
          debugMode = true;
          storageEnabled = true;
        };

        enclave-egress = mkProductionEnclave { egressEnabled = true; };
        enclave-egress-debug = mkProductionEnclave {
          debugMode = true;
          egressEnabled = true;
        };
        enclave-storage-egress = mkProductionEnclave {
          storageEnabled = true;
          egressEnabled = true;
        };
        enclave-storage-egress-debug = mkProductionEnclave {
          debugMode = true;
          storageEnabled = true;
          egressEnabled = true;
        };

        # --- Uncompressed rootfs size budgets -------------------------
        # Measure only builder-owned runtime overhead. Customer payloads are
        # arbitrary in size and live in their own ramdisk, outside this budget.
        # rootfsOnly also avoids compiling the storage kernel or assembling an
        # EIF merely to count bytes.
        baseRootfsForSizeCheck = mkProductionEnclave {
          rootfsOnly = true;
        };

        storageRootfsForSizeCheck = mkProductionEnclave {
          storageEnabled = true;
          rootfsOnly = true;
        };

        egressRootfsForFeatureCheck = mkProductionEnclave {
          egressEnabled = true;
          rootfsOnly = true;
        };

        # Leave room for ordinary dependency-size drift while remaining
        # tight enough to catch a glibc closure, a duplicated runtime tree,
        # or another multi-megabyte packaging regression. Raising either
        # limit should require reviewing the emitted per-path manifest.
        baseRootfsSizeBudget = 64 * 1024 * 1024;
        storageRootfsSizeBudget = 96 * 1024 * 1024;

        baseRootfsSizeCheck = pkgs.callPackage ./nix/rootfs-size-check.nix {
          name = "base";
          rootfs = baseRootfsForSizeCheck;
          maxBytes = baseRootfsSizeBudget;
        };

        storageRootfsSizeCheck = pkgs.callPackage ./nix/rootfs-size-check.nix {
          name = "storage";
          rootfs = storageRootfsForSizeCheck;
          maxBytes = storageRootfsSizeBudget;
        };

        egressFeatureGateCheck = pkgs.runCommand "egress-feature-gate-check" { } ''
          set -euo pipefail
          for path in \
            bin/enclavia-egress \
            bin/unbound \
            bin/iproute2-ip \
            bin/xtables-legacy-multi \
            bin/iptables \
            etc/unbound
          do
            if [ -e ${baseRootfsForSizeCheck}/$path ]; then
              echo "no-egress rootfs unexpectedly contains /$path" >&2
              exit 1
            fi
            if [ ! -e ${egressRootfsForFeatureCheck}/$path ]; then
              echo "egress-enabled rootfs is missing /$path" >&2
              exit 1
            fi
          done
          touch $out
        '';

        ociMetadataCheck = pkgs.runCommand "oci-tar-to-cpio-metadata-check" {
          nativeBuildInputs = [ pkgs.python3 ];
        } ''
          TAR_TO_CPIO=${./nix/tar-to-cpio.py} \
            python3 ${./nix/test_tar_to_cpio.py}
          touch $out
        '';

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
        testBundleArchive = mkOciBundleArchive "test-oci-bundle" test-bundle;

        test-enclave = pkgs.callPackage ./nix/enclave.nix {
          inherit pkgs nitroLib enclaviaServerPkg;
          ociBundleArchive = testBundleArchive;
          customKernel = enclaveKernel;
        };

        # Note: deliberately does NOT pass `enclaviaChainInitPkg`. The
        # router-path e2e (`tests/run_e2e_router.sh` in
        # enclavia-crates) boots this EIF without standing up
        # `chain-host` on the parent, so a baked-in chain-init would
        # dial vsock 5005, hit its 30s connect timeout, exit 1, and
        # `set -e` in init.sh would abort the boot. Reboot loop, CI
        # runner wedges until the workflow timeout kills it (~51 min
        # observed). Sibling test enclaves (test-enclave-egress-debug,
        # test-enclave-storage-debug, test-enclave-secrets-debug)
        # already follow this pattern — they only inherit the packages
        # the scenario actually needs. Chain submission is exercised
        # via the production launcher in enclavia-crates, not via this
        # test wrapper.
        test-enclave-debug = pkgs.callPackage ./nix/enclave.nix {
          inherit pkgs nitroLib enclaviaServerPkg;
          ociBundleArchive = testBundleArchive;
          debugMode = true;
          customKernel = enclaveKernel;
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
        testWsBundleArchive = mkOciBundleArchive "test-ws-oci-bundle" test-ws-bundle;

        test-enclave-ws-debug = pkgs.callPackage ./nix/enclave.nix {
          inherit pkgs nitroLib enclaviaServerPkg;
          ociBundleArchive = testWsBundleArchive;
          debugMode = true;
          customKernel = enclaveKernel;
        };

        # --- Egress test bundle + enclave ---
        # Minimal OCI bundle that opens TCP to TARGET_IP:TARGET_PORT (env vars
        # set by the e2e wrapper), writes "ping\n", and exits 0 iff the reply
        # is "pong\n". Used by tests/run_e2e_egress.sh.
        test-egress-bundle = pkgs.callPackage ./nix/test-egress-bundle.nix { inherit pkgs; };
        testEgressBundleArchive = mkOciBundleArchive "test-egress-oci-bundle" test-egress-bundle;

        test-enclave-egress-debug = pkgs.callPackage ./nix/enclave.nix {
          inherit pkgs nitroLib enclaviaServerPkg enclaviaEgressPkg;
          ociBundleArchive = testEgressBundleArchive;
          debugMode = true;
          egressEnabled = true;
          customKernel = enclaveKernel;
        };

        # --- Secrets test bundle + enclave (#169) ---
        # Minimal OCI bundle whose entrypoint inspects SECRET_BIN /
        # SECRET_TEXT in its env and prints assertion markers to the
        # serial console. The bundle is the same across the inject /
        # empty / skip-host runs; the host harness varies only the
        # SECRETS_PAYLOAD passed on stdin to secrets-host (and the
        # presence of the daemon itself).
        test-secrets-bundle = pkgs.callPackage ./nix/test-secrets-bundle.nix { inherit pkgs; };
        testSecretsBundleArchive = mkOciBundleArchive "test-secrets-oci-bundle" test-secrets-bundle;

        test-enclave-secrets-debug = pkgs.callPackage ./nix/enclave.nix {
          inherit pkgs nitroLib enclaviaServerPkg enclaviaSecretsInitPkg;
          ociBundleArchive = testSecretsBundleArchive;
          debugMode = true;
          customKernel = enclaveKernel;
        };

        # --- Storage test bundle + enclave ---
        test-storage-bundle = pkgs.callPackage ./nix/test-storage-bundle.nix { inherit pkgs; };
        testStorageBundleArchive = mkOciBundleArchive "test-storage-oci-bundle" test-storage-bundle;

        test-enclave-storage-debug = pkgs.callPackage ./nix/enclave.nix {
          # enclaviaSecretsInitPkg is baked in here (unlike the other
          # test EIFs) because the storage path runs `enclavia-crypto
          # init`, which on real Nitro needs AWS_* creds pulled by
          # `enclavia-secrets-init --mode aws-creds` from vsock 5013
          # before the KMS call (#199 / #198). The storage e2e exercises
          # that pull -> source -> scrub flow with static dummy creds.
          inherit pkgs nitroLib enclaviaServerPkg nbdClientPkg enclaviaCryptoPkg enclaviaSecretsInitPkg;
          ociBundleArchive = testStorageBundleArchive;
          debugMode = true;
          storageEnabled = true;
          customKernel = storageKernel;
        };

        # Diagnostic variant: storage path skips LUKS so the proxy is exercised
        # against raw btrfs writes. Used to isolate proxy throughput from
        # cryptsetup overhead on TCG.
        test-enclave-storage-debug-no-luks = pkgs.callPackage ./nix/enclave.nix {
          inherit pkgs nitroLib enclaviaServerPkg nbdClientPkg enclaviaCryptoPkg;
          ociBundleArchive = testStorageBundleArchive;
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
          # AWS-creds boot pass (#199 / #198): the in-enclave
          # `enclavia-crypto init` pulls AWS_* creds from a second
          # secrets-host on this port before the KMS call. mock-kms
          # ignores SigV4, so static dummy creds exercise the full
          # pull -> source -> scrub flow.
          AWS_CREDS_VSOCK_PORT=5013
          KMS_KEY_ID="${testKmsKeyId}"

          cleanup() {
              echo ""
              echo "storage-test-vm: cleaning up..."
              kill "''${HEARTBEAT_PID:-}" "''${VHOST_PID:-}" "''${STORAGE_PID:-}" "''${MOCK_KMS_PID:-}" "''${AWS_CREDS_PID:-}" "''${SECRETS_PID:-}" 2>/dev/null || true
              wait "''${HEARTBEAT_PID:-}" "''${VHOST_PID:-}" "''${STORAGE_PID:-}" "''${MOCK_KMS_PID:-}" "''${AWS_CREDS_PID:-}" "''${SECRETS_PID:-}" 2>/dev/null || true
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

          # 5b. Start the AWS-creds secrets-host (#199 / #198). A SECOND
          # single-shot enclavia-secrets-host instance, on the dedicated
          # creds port 5013 (distinct from the 5004 workload-secrets
          # port — same-port-twice would race the single-shot daemon),
          # serving a CBOR map of static dummy AWS creds. The in-enclave
          # `enclavia-secrets-init --mode aws-creds` pulls it before
          # `enclavia-crypto init`, lands it in init.sh's env via
          # /run/aws-creds.env, and init.sh scrubs it before crun start.
          # mock-kms ignores SigV4, so dummy creds are sufficient to
          # drive the full plumbing + scrub end to end.
          AWS_CREDS_LISTEN_PATH="''${PROXY_SOCKET}_''${AWS_CREDS_VSOCK_PORT}"
          AWS_CREDS_PAYLOAD="''${SOCK_DIR}/aws-creds.cbor"
          # CBOR encoding of the dummy creds map, matching the wire type
          # the host serves and the in-enclave secrets-init decodes:
          # BTreeMap<String, Vec<u8>>. KEYS are CBOR text strings
          # (0x60+len for len<24); VALUES are CBOR BYTE strings (Vec<u8>:
          # 0x40+len for len<24, else 0x58 <len>) — NOT text strings.
          # a4 = map of 4 pairs; BTreeMap order is lexicographic.
          #   key AWS_ACCESS_KEY_ID(17,0x71)     val(21,0x55)
          #   key AWS_REGION(10,0x6a)            val(12,0x4c)
          #   key AWS_SECRET_ACCESS_KEY(21,0x75) val(43,0x58 0x2b)
          #   key AWS_SESSION_TOKEN(17,0x71)     val(31,0x58 0x1f)
          # Hand-encoded so the wrapper needs no CBOR tooling; the byte
          # layout is round-trip-verified against ciborium.
          ${pkgs.coreutils}/bin/printf '%b' '\xa4\x71AWS_ACCESS_KEY_ID\x55AKIADUMMYSTORAGEE2E00\x6aAWS_REGION\x4ceu-central-1\x75AWS_SECRET_ACCESS_KEY\x58\x2bdummystoragee2esecret0000000000000000000000\x71AWS_SESSION_TOKEN\x58\x1fdummy-storage-e2e-session-token' \
              > "''${AWS_CREDS_PAYLOAD}"
          echo "storage-test-vm: starting aws-creds secrets-host on ''${AWS_CREDS_LISTEN_PATH}..."
          LISTEN_PATH="''${AWS_CREDS_LISTEN_PATH}" \
          RUST_LOG="''${RUST_LOG:-info}" \
              ${secretsHostBin} --port "''${AWS_CREDS_VSOCK_PORT}" \
              < "''${AWS_CREDS_PAYLOAD}" &
          AWS_CREDS_PID=$!

          for i in $(${pkgs.coreutils}/bin/seq 1 50); do
              [ -S "''${AWS_CREDS_LISTEN_PATH}" ] && break
              ${pkgs.coreutils}/bin/sleep 0.1
          done
          if [ ! -S "''${AWS_CREDS_LISTEN_PATH}" ]; then
              echo "storage-test-vm: ERROR: aws-creds secrets-host socket not ready" >&2
              exit 1
          fi
          echo "storage-test-vm: aws-creds secrets-host ready"

          # 5c. Start the workload-secrets secrets-host (#169) on vsock
          # 5004. The storage EIF bakes `enclavia-secrets-init`, and
          # init.sh's FINAL pass (`enclavia-secrets-init /var/lib/oci/bundle`,
          # default `--mode workload-secrets`) dials vsock 5004 right
          # before `crun start` to inject the workload's OCI-bundle env.
          # That binary treats ANY vsock connect failure as fatal (it has
          # no "exit 0 when no daemon is listening" path), so the real
          # local-qemu launcher ALWAYS stands up a 5004 secrets-host —
          # even for an enclave with no secrets — serving an empty CBOR
          # map (see enclavia-crates launcher/local_qemu.rs: "'no secrets
          # configured' has to look the same from its side as 'secrets
          # configured': a listener that answers with a CBOR map").
          # Without it the guest's 5004 dial connects to a non-existent
          # ''${PROXY_SOCKET}_5004, vhost-device-vsock cannot reach a host
          # app, the guest connect times out (os error 110), and init.sh's
          # `set -e` aborts the boot just before crun. We serve an empty
          # map (empty stdin -> secrets-host serves `0xa0`); the storage
          # test workload reads its env from the kernel cmdline, not from
          # injected secrets, so an empty map is exactly right.
          SECRETS_VSOCK_PORT=5004
          SECRETS_LISTEN_PATH="''${PROXY_SOCKET}_''${SECRETS_VSOCK_PORT}"
          SECRETS_PAYLOAD="''${SOCK_DIR}/workload-secrets.cbor"
          # Empty file -> secrets-host serves an empty CBOR map after EOF.
          : > "''${SECRETS_PAYLOAD}"
          echo "storage-test-vm: starting workload-secrets secrets-host on ''${SECRETS_LISTEN_PATH} (empty map)..."
          LISTEN_PATH="''${SECRETS_LISTEN_PATH}" \
          RUST_LOG="''${RUST_LOG:-info}" \
              ${secretsHostBin} < "''${SECRETS_PAYLOAD}" &
          SECRETS_PID=$!

          for i in $(${pkgs.coreutils}/bin/seq 1 50); do
              [ -S "''${SECRETS_LISTEN_PATH}" ] && break
              ${pkgs.coreutils}/bin/sleep 0.1
          done
          if [ ! -S "''${SECRETS_LISTEN_PATH}" ]; then
              echo "storage-test-vm: ERROR: workload-secrets secrets-host socket not ready" >&2
              exit 1
          fi
          echo "storage-test-vm: workload-secrets secrets-host ready"

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

        secretsHostBin = "${enclavia-crates.packages.${system}.secrets-host-debug or (throw "secrets-host not built; override enclavia-crates input")}/bin/enclavia-secrets-host";

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

        # Wrapper for the per-enclave secrets e2e test (#169). Same UDS-mode
        # vsock plumbing as test-egress-vm; on top of that we stand up
        # `enclavia-secrets-host` listening on ${PROXY_SOCKET}_5004 with the
        # CBOR payload piped on stdin from $SECRETS_PAYLOAD_BASE64.
        #
        # SECRETS_SKIP_DAEMON=1 intentionally suppresses the daemon spawn so
        # the harness can exercise the in-enclave failure-fast path
        # (enclavia-secrets-init times out, init.sh's `set -e` fires before
        # crun launches the workload).
        #
        # SECRETS_MODE=inject|empty is propagated to the workload via the
        # nitro-enclave `append=` kernel command line (init.sh parses
        # enclavia.secrets_mode=).
        test-secrets-vm = pkgs.writeShellScriptBin "enclavia-test-secrets-vm" ''
          set -euo pipefail

          EIF_PATH="${test-enclave-secrets-debug}/image.eif"
          MEMORY="''${MEMORY:-4G}"
          CPUS="''${CPUS:-2}"

          SECRETS_MODE="''${SECRETS_MODE:-inject}"
          SECRETS_SKIP_DAEMON="''${SECRETS_SKIP_DAEMON:-0}"

          GUEST_CID=4
          SECRETS_VSOCK_PORT=5004

          SOCK_DIR="$(${pkgs.coreutils}/bin/mktemp -d /tmp/enclave-secrets-test.XXXXXX)"
          VHOST_SOCKET="''${SOCK_DIR}/vhost.sock"
          PROXY_SOCKET="''${SOCK_DIR}/proxy.sock"

          cleanup() {
              echo ""
              echo "secrets-test-vm: cleaning up..."
              kill "''${HEARTBEAT_PID:-}" "''${VHOST_PID:-}" "''${SECRETS_PID:-}" 2>/dev/null || true
              wait "''${HEARTBEAT_PID:-}" "''${VHOST_PID:-}" "''${SECRETS_PID:-}" 2>/dev/null || true
              ${pkgs.coreutils}/bin/rm -rf "''${SOCK_DIR}"
          }
          trap cleanup EXIT

          echo "secrets-test-vm: socket dir       = ''${SOCK_DIR}"
          echo "secrets-test-vm: EIF              = ''${EIF_PATH}"
          echo "secrets-test-vm: mode             = ''${SECRETS_MODE}"
          echo "secrets-test-vm: skip-daemon      = ''${SECRETS_SKIP_DAEMON}"
          echo "secrets-test-vm: memory = ''${MEMORY}, cpus = ''${CPUS}"

          echo "secrets-test-vm: starting vhost-device-vsock (CID ''${GUEST_CID}, UDS mode)..."
          vhost-device-vsock \
              --vm "guest-cid=''${GUEST_CID},socket=''${VHOST_SOCKET},uds-path=''${PROXY_SOCKET}" &
          VHOST_PID=$!

          for i in $(${pkgs.coreutils}/bin/seq 1 50); do
              [ -S "''${VHOST_SOCKET}" ] && break
              ${pkgs.coreutils}/bin/sleep 0.1
          done
          if [ ! -S "''${VHOST_SOCKET}" ]; then
              echo "secrets-test-vm: ERROR: vhost-device-vsock did not create socket" >&2
              exit 1
          fi

          echo "secrets-test-vm: starting heartbeat responder..."
          ${pkgs.python3}/bin/python3 ${heartbeatScript} --uds "''${PROXY_SOCKET}_9000" &
          HEARTBEAT_PID=$!

          for i in $(${pkgs.coreutils}/bin/seq 1 50); do
              [ -S "''${PROXY_SOCKET}_9000" ] && break
              ${pkgs.coreutils}/bin/sleep 0.1
          done

          if [ "''${SECRETS_SKIP_DAEMON}" = "1" ]; then
              echo "secrets-test-vm: SECRETS_SKIP_DAEMON=1 — NOT spawning enclavia-secrets-host"
              echo "secrets-test-vm:   expecting enclavia-secrets-init to fail fast in-enclave"
          else
              # Materialise the CBOR payload from $SECRETS_PAYLOAD_BASE64 (an
              # empty value is valid: the daemon then serves an empty CBOR
              # map after stdin EOF).
              SECRETS_LISTEN_PATH="''${PROXY_SOCKET}_''${SECRETS_VSOCK_PORT}"
              PAYLOAD_FILE="''${SOCK_DIR}/secrets.cbor"
              if [ -n "''${SECRETS_PAYLOAD_BASE64:-}" ]; then
                  ${pkgs.coreutils}/bin/printf '%s' "''${SECRETS_PAYLOAD_BASE64}" \
                      | ${pkgs.coreutils}/bin/base64 -d > "''${PAYLOAD_FILE}"
              else
                  : > "''${PAYLOAD_FILE}"
              fi

              echo "secrets-test-vm: starting enclavia-secrets-host on ''${SECRETS_LISTEN_PATH} (payload=$(${pkgs.coreutils}/bin/stat -c %s "''${PAYLOAD_FILE}") bytes)..."
              LISTEN_PATH="''${SECRETS_LISTEN_PATH}" \
              RUST_LOG="''${RUST_LOG:-info}" \
                  ${secretsHostBin} < "''${PAYLOAD_FILE}" &
              SECRETS_PID=$!

              for i in $(${pkgs.coreutils}/bin/seq 1 50); do
                  [ -S "''${SECRETS_LISTEN_PATH}" ] && break
                  ${pkgs.coreutils}/bin/sleep 0.1
              done
              if [ ! -S "''${SECRETS_LISTEN_PATH}" ]; then
                  echo "secrets-test-vm: ERROR: secrets-host socket did not appear" >&2
                  exit 1
              fi
          fi

          echo ""
          echo "  Watch the console output for 'secrets-test:' messages."
          echo ""

          APPEND="enclavia.secrets_mode=''${SECRETS_MODE}"
          QEMU_ARGS=(
              -M "nitro-enclave,vsock=c,id=enclavia-secrets-test,append=''${APPEND}"
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
        checks = {
          egress-feature-gate = egressFeatureGateCheck;
          oci-metadata = ociMetadataCheck;
          rootfs-size-base = baseRootfsSizeCheck;
          rootfs-size-storage = storageRootfsSizeCheck;
        };

        packages = {
          inherit builder enclave enclave-debug enclave-egress enclave-egress-debug enclave-storage enclave-storage-debug enclave-storage-egress enclave-storage-egress-debug debug-vm test-bundle test-enclave test-enclave-debug test-debug-vm test-storage-bundle test-enclave-storage-debug test-enclave-storage-debug-no-luks test-storage-vm test-egress-bundle test-enclave-egress-debug test-egress-vm test-ws-bundle test-enclave-ws-debug test-secrets-bundle test-enclave-secrets-debug test-secrets-vm;
          enclave-kernel = enclaveKernel;
          enclave-storage-kernel = storageKernel;
          enclave-kernel-config = enclaveKernelConfig;
          enclave-storage-kernel-config = storageKernelConfig;
          kernel-size-report = kernelSizeReport;
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
