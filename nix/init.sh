#!/bin/sh

set -e

CONFIG="/etc/enclavia/config.json"

# Read the customer app port from config (default 8080).
# Parse with shell builtins only — no cat/sed/head available in minimal enclave.
CONTAINER_PORT=8080
if [ -f "$CONFIG" ]; then
    while IFS= read -r line; do
        case "$line" in
            *'"port"'*)
                # Extract number after "port": — handles "port": 3000 or "port":3000
                port="${line#*\"port\"}"
                port="${port#*:}"
                port="${port#"${port%%[! ]*}"}"
                port="${port%%[!0-9]*}"
                if [ -n "$port" ] && [ "$port" -gt 0 ] 2>/dev/null; then
                    CONTAINER_PORT="$port"
                fi
                ;;
        esac
    done < "$CONFIG"
fi

# Bring up the loopback interface so enclavia-server can reach the container.
/bin/ip link set lo up
/bin/ip addr add 127.0.0.1/8 dev lo 2>/dev/null || true

# Pre-mount essential filesystems in the container rootfs.
# The OCI config has all mounts stripped (they fail without mount namespace),
# so we set up what the container needs here.
ROOTFS="/var/lib/oci/bundle/rootfs"
/bin/mkdir -p "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/dev" "$ROOTFS/tmp"
/bin/mount -t proc proc "$ROOTFS/proc" 2>/dev/null || true
/bin/mount -t sysfs sysfs "$ROOTFS/sys" 2>/dev/null || true
/bin/mount -t devtmpfs devtmpfs "$ROOTFS/dev" 2>/dev/null || true
/bin/mount -t tmpfs tmpfs "$ROOTFS/tmp" 2>/dev/null || true

# Start the customer's container in the background using crun.
# --no-pivot: use chroot instead of pivot_root (required on initramfs)
/bin/crun run --no-pivot --bundle /var/lib/oci/bundle customer &

# Start enclavia-server in the foreground, forwarding to the customer's port
exec /bin/enclavia-server --container-addr "127.0.0.1:${CONTAINER_PORT}"
