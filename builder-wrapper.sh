#!/usr/bin/env bash
# Wrapper that runs the builder binary inside its own nix develop shell,
# ensuring skopeo, umoci, and nix are available on PATH.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec nix develop "${SCRIPT_DIR}" -c "${SCRIPT_DIR}/target/release/builder" "$@"
