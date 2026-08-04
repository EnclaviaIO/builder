#!/bin/sh
set -eu

if [ "$#" -ne 8 ]; then
    echo "usage: $0 BEFORE_BASE_KERNEL AFTER_BASE_KERNEL BEFORE_STORAGE_KERNEL AFTER_STORAGE_KERNEL BEFORE_BASE_EIF AFTER_BASE_EIF BEFORE_STORAGE_EIF AFTER_STORAGE_EIF" >&2
    exit 2
fi

bytes() {
    wc -c < "$1" | tr -d ' '
}

row() {
    label=$1
    before=$(bytes "$2")
    after=$(bytes "$3")
    reduction=$((before - after))
    percent=$(awk -v before="$before" -v reduction="$reduction" 'BEGIN { printf "%.1f", reduction * 100 / before }')
    printf '| %s | %s | %s | %s | %s%% |\n' "$label" "$before" "$after" "$reduction" "$percent"
}

echo '| Artifact | Before (bytes) | After (bytes) | Reduction (bytes) | Reduction |'
echo '|---|---:|---:|---:|---:|'
row 'base bzImage' "$1" "$2"
row 'storage bzImage' "$3" "$4"
row 'base image.eif' "$5" "$6"
row 'storage image.eif' "$7" "$8"
