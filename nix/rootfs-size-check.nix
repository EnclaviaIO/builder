{
  pkgs,
  name,
  rootfs,
  maxBytes,
}:

assert builtins.isInt maxBytes;
assert maxBytes > 0;

pkgs.runCommand "enclave-${name}-rootfs-size-budget" {} ''
  set -euo pipefail

  mkdir -p "$out"

  # List every non-directory path, including every name in a hardlink set.
  # Link count makes preserved hardlinks distinguishable from duplicated
  # files, while sorting by path keeps the manifest deterministic.
  {
    printf 'type\thardlinks\tapparent_bytes\tpath\n'
    (
      cd ${rootfs}
      ${pkgs.findutils}/bin/find . -xdev ! -type d \
        -printf '%y\t%n\t%s\t%p\n' \
        | LC_ALL=C ${pkgs.coreutils}/bin/sort -k4,4
    )
  } > "$out/rootfs-size-manifest.tsv"

  # GNU du is hardlink-aware by default: a preserved hardlink contributes
  # its contents once, while an accidentally duplicated file contributes
  # once per copy. --bytes measures uncompressed apparent size rather than
  # allocated filesystem blocks.
  total_bytes=$(${pkgs.coreutils}/bin/du --summarize --bytes ${rootfs} \
    | ${pkgs.coreutils}/bin/cut -f1)
  budget_bytes=${toString maxBytes}

  {
    printf 'variant\tapparent_bytes\tbudget_bytes\n'
    printf '%s\t%s\t%s\n' '${name}' "$total_bytes" "$budget_bytes"
  } > "$out/rootfs-size-summary.tsv"

  printf '%s rootfs: %s bytes (budget: %s bytes)\n' \
    '${name}' "$total_bytes" "$budget_bytes"

  if [ "$total_bytes" -gt "$budget_bytes" ]; then
    echo "enclave-${name}: uncompressed rootfs size budget exceeded" >&2
    echo "Per-path size manifest:" >&2
    ${pkgs.coreutils}/bin/cat "$out/rootfs-size-manifest.tsv" >&2
    exit 1
  fi
''
