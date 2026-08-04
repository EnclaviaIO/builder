{
  lib,
  runCommand,
  writeText,
  stdenv,
  bison,
  flex,
  gnumake,
  gnutar,
  xz,
  kernel,
  storage ? false,
}:

let
  profile = if storage then "storage" else "base";
  builtInBudget = if storage then 669 else 619;

  seed = writeText "enclavia-${profile}-kernel.seed" (
    builtins.readFile ./enclave-kernel.config
    + lib.optionalString storage ("\n" + builtins.readFile ./enclave-storage-kernel.config)
  );

  # These are profile-specific exclusions and therefore cannot all live in
  # the common seed (the storage profile intentionally enables them).
  profileForbidden = lib.optionals (!storage) [
    "CONFIG_BLOCK"
    "CONFIG_BLK_DEV_NBD"
    "CONFIG_MD"
    "CONFIG_BLK_DEV_DM"
    "CONFIG_DM_CRYPT"
    "CONFIG_CRYPTO"
    "CONFIG_BTRFS_FS"
  ];

  forbidden = writeText "enclavia-${profile}-kernel.forbidden" (
    lib.concatStringsSep "\n" profileForbidden + "\n"
  );
in
runCommand "enclavia-${profile}-kernel-config-${kernel.version}" {
  nativeBuildInputs = [ stdenv.cc bison flex gnumake gnutar xz ];
} ''
  set -eu

  mkdir source build "$out"
  if [ -d ${kernel.src} ]; then
    cp -R ${kernel.src}/. source/
    chmod -R u+w source
  else
    tar -xf ${kernel.src} --strip-components=1 -C source
  fi
  patchShebangs source/scripts

  # A complete allnoconfig result prevents new upstream default-y options from
  # entering an enclave unnoticed when the pinned maintained kernel advances.
  KCONFIG_ALLCONFIG=${seed} \
    make -C source O="$PWD/build" ARCH=x86_64 allnoconfig

  # A requested capability that was renamed or lost a dependency must fail
  # loudly.  Disabled lines accept either an explicit "not set" entry or an
  # absent symbol, but never a built-in/module result.
  while IFS= read -r requested || [ -n "$requested" ]; do
    case "$requested" in
      "# CONFIG_"*" is not set")
        set -- $requested
        symbol="$2"
        if grep -Eq "^$symbol=[ym]$" build/.config; then
          echo "kernel config policy violation: $symbol was enabled" >&2
          exit 1
        fi
        ;;
      \#*|"")
        ;;
      CONFIG_*=*)
        if ! grep -Fqx "$requested" build/.config; then
          echo "kernel config request was not satisfied: $requested" >&2
          exit 1
        fi
        ;;
    esac
  done < ${seed}

  while IFS= read -r symbol || [ -n "$symbol" ]; do
    [ -z "$symbol" ] && continue
    if grep -Eq "^$symbol=[ym]$" build/.config; then
      echo "kernel config policy violation: $symbol is forbidden in the ${profile} profile" >&2
      exit 1
    fi
  done < ${forbidden}

  built_ins=$(awk -F= '$2 == "y" { count++ } END { print count + 0 }' build/.config)
  modules=$(awk -F= '$2 == "m" { count++ } END { print count + 0 }' build/.config)
  if [ "$modules" -ne 0 ]; then
    echo "kernel config policy violation: expected no modules, found $modules" >&2
    exit 1
  fi
  if [ "$built_ins" -gt ${toString builtInBudget} ]; then
    echo "kernel config exceeds the ${profile} built-in budget (${toString builtInBudget}): $built_ins" >&2
    exit 1
  fi

  cp build/.config "$out/config"
  cp ${seed} "$out/seed"
  {
    echo "profile=${profile}"
    echo "kernel-version=${kernel.version}"
    echo "built-in-options=$built_ins"
    echo "module-options=$modules"
    echo "built-in-option-budget=${toString builtInBudget}"
  } > "$out/report"

  echo "enclavia ${profile} kernel: $built_ins built-ins, $modules modules; budget=${toString builtInBudget}"
''
