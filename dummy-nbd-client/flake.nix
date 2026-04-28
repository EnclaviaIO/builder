{
  # Stub flake — placeholder for the nbd-client input.
  # Override at build time: --override-input nbd-client path:../enclavia-crates
  description = "nbd-client stub";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  outputs = { self, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system: {
      packages.nbd-client-enclave =
        throw "nbd-client input not configured — use --override-input nbd-client path:/path/to/enclavia-crates";
    });
}
