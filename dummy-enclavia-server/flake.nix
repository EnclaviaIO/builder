{
  # Stub flake — placeholder for the enclavia-server input.
  # Override at build time: --override-input enclavia-server path:../enclavia-server
  description = "enclavia-server stub";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  outputs = { self, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system: {
      packages.enclavia-server =
        throw "enclavia-server input not configured — use --override-input enclavia-server path:/path/to/enclavia-server";
    });
}
