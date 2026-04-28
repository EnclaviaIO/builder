#!/bin/sh

set -e

CONFIG="/etc/enclavia/config.json"

# Read the customer app port from config (default 8080).
# Parse with shell builtins only — no cat/sed/head available in minimal enclave.
CONTAINER_PORT=8080
if [ -f "$CONFIG" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
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

# --- Optional storage setup ---
# Parse storage.enabled from config using shell builtins.
STORAGE_ENABLED=false
if [ -f "$CONFIG" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            *'"enabled"'*'true'*)
                # Only match if we're in the storage section (heuristic: after "storage")
                STORAGE_ENABLED=true
                ;;
        esac
    done < "$CONFIG"
fi

if [ "$STORAGE_ENABLED" = "true" ]; then
    # Mount devtmpfs at /dev — the init binary's chroot leaves /dev empty,
    # but we need kernel device nodes (e.g., /dev/nbd0) for storage.
    /bin/mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
    # Mount sysfs so we can check /sys/block/nbd0/size
    /bin/mount -t sysfs sysfs /sys 2>/dev/null || true

    # Start NBD client — connects to host via vsock CID 2:5001, sets up /dev/nbd0
    /bin/enclavia-nbd-client &

    # Wait for nbd-client to configure the device (non-zero size).
    # With NBD built into the kernel, /dev/nbd0 exists from boot but has
    # size 0 until nbd-client completes the handshake and ioctls.
    i=0
    while [ $i -lt 100 ]; do
        read -r size < /sys/block/nbd0/size 2>/dev/null
        [ -n "$size" ] && [ "$size" -gt 0 ] 2>/dev/null && break
        /bin/sleep 0.1
        i=$((i + 1))
    done

    read -r size < /sys/block/nbd0/size 2>/dev/null
    if [ -n "$size" ] && [ "$size" -gt 0 ] 2>/dev/null; then
        # Get/create LUKS passphrase via KMS (writes /tmp/luks.key).
        /bin/enclavia-crypto init

        # Format on first use, then unlock.
        # --pbkdf-memory caps Argon2id at 64MB (default ~1GB OOMs in small enclaves).
        if ! /bin/cryptsetup isLuks /dev/nbd0 2>/dev/null; then
            /bin/cryptsetup luksFormat \
                --batch-mode \
                --pbkdf-memory 65536 \
                --key-file /tmp/luks.key \
                /dev/nbd0
        fi
        /bin/cryptsetup luksOpen --key-file /tmp/luks.key /dev/nbd0 encdata

        # Remove plaintext key — must not be accessible to customer code.
        # The upgrade flow re-decrypts via KMS rather than reading this file.
        /bin/rm -f /tmp/luks.key

        /bin/blkid /dev/mapper/encdata >/dev/null 2>&1 || /bin/mkfs.ext4 -q /dev/mapper/encdata
        /bin/mkdir -p /data
        /bin/mount /dev/mapper/encdata /data
        echo "storage: encrypted volume mounted at /data"

        # Bind-mount into container rootfs so the app can access it
        /bin/mkdir -p "$ROOTFS/data"
        /bin/mount --bind /data "$ROOTFS/data" 2>/dev/null || true
    else
        echo "WARNING: /dev/nbd0 not configured (size=0), storage unavailable" >&2
    fi
fi

# Start the customer's container in the background using crun.
# --no-pivot: use chroot instead of pivot_root (required on initramfs)
/bin/crun run --no-pivot --bundle /var/lib/oci/bundle customer &

# Start enclavia-server in the foreground, forwarding to the customer's port
exec /bin/enclavia-server --container-addr "127.0.0.1:${CONTAINER_PORT}"
