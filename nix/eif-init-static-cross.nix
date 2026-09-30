# Static cross build of the EIF init for another architecture.
#
# nixpkgs' pkgsCross buildGoModule links this program externally against the
# target glibc (PT_INTERP plus NEEDED libc.so.6) even with CGO_ENABLED=0, and
# an EIF has no dynamic loader.  The host Go toolchain cross-compiles pure Go
# programs to a static binary by itself, so this uses it directly.  The x86_64
# EIFs keep their native buildGoModule init in nix/enclave.nix.
{
  lib,
  runCommand,
  go,
  binutils-unwrapped,
  # Go's name for the target architecture, e.g. "arm64".
  goArch,
}:

runCommand "eif-init-${goArch}" {
  nativeBuildInputs = [ go binutils-unwrapped ];
} ''
  cp -r ${lib.cleanSource ./init-patched} src
  chmod -R u+w src
  cd src

  export HOME="$TMPDIR" GOCACHE="$TMPDIR/gocache" GOPATH="$TMPDIR/gopath"
  export GOOS=linux GOARCH=${goArch} CGO_ENABLED=0 GOTOOLCHAIN=local
  export GOFLAGS="-mod=vendor -trimpath"

  mkdir -p "$out/bin"
  go build -buildvcs=false -ldflags "-s -w -buildid=" -o "$out/bin/init" .

  # The init runs before any userspace exists; it must not need a loader.
  if readelf -lW "$out/bin/init" | grep -q INTERP; then
    echo "eif-init-${goArch}: binary has a PT_INTERP program header" >&2
    exit 1
  fi
  if readelf -dW "$out/bin/init" | grep -q NEEDED; then
    echo "eif-init-${goArch}: binary has NEEDED shared-library entries" >&2
    exit 1
  fi
''
