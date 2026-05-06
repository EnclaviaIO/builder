{
  # Stub flake — placeholder for the enclavia-crates input.
  # Override at build time: --override-input enclavia-crates path:/path/to/enclavia-crates
  description = "enclavia-crates stub";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  outputs = { self, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system: {
      packages.enclavia-server =
        throw "enclavia-crates input not configured — use --override-input enclavia-crates path:/path/to/enclavia-crates";
    });
}
