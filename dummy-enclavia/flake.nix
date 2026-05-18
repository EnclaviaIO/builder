{
  # Stub flake — placeholder for the `enclavia` input.
  # Override at build time:
  #   --override-input enclavia path:/path/to/enclavia
  # or
  #   --override-input enclavia git+ssh://git@github.com/EnclaviaIO/enclavia?ref=main
  description = "enclavia stub";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  outputs = { self, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system: {
      packages.enclavia-server =
        throw "enclavia input not configured; use --override-input enclavia path:/path/to/enclavia";
    });
}
