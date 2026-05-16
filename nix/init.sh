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

# Optional egress test fixtures from kernel cmdline: the e2e egress harness
# passes `enclavia.target_ip=X enclavia.target_port=Y` via QEMU `-append`,
# which the workload reads from /etc/enclavia/egress-test.env. Real
# enclaves never see these tokens, so the file just stays absent.
TEST_TARGET_IP=""
TEST_TARGET_PORT=""
TEST_RESOLVER=""
if [ -r /proc/cmdline ]; then
    while IFS= read -r cmdline || [ -n "$cmdline" ]; do
        for tok in $cmdline; do
            case "$tok" in
                enclavia.target_ip=*) TEST_TARGET_IP="${tok#enclavia.target_ip=}" ;;
                enclavia.target_port=*) TEST_TARGET_PORT="${tok#enclavia.target_port=}" ;;
                enclavia.resolver=*) TEST_RESOLVER="${tok#enclavia.resolver=}" ;;
            esac
        done
    done < /proc/cmdline
fi

# Bring up the loopback interface so enclavia-server can reach the container.
/bin/ip link set lo up
/bin/ip addr add 127.0.0.1/8 dev lo 2>/dev/null || true

# --- Outbound network egress ---
# When enclavia-egress is present, start it before crun so the workload's
# default route through tun0 is in place by the time the container runs.
# enclavia-egress owns /dev/net/tun, opens it, creates tun0 with the
# configured local IP, and brings it up itself. We add the default route
# once tun0 appears.
if [ -x /bin/enclavia-egress ]; then
    # Ensure /dev/net/tun exists. devtmpfs auto-creates it when CONFIG_TUN=y,
    # but the parent directory /dev/net is only created when the first
    # devtmpfs entry under it is registered; mknod ourselves if missing.
    if [ ! -c /dev/net/tun ]; then
        /bin/mkdir -p /dev/net
        /bin/mknod /dev/net/tun c 10 200 2>/dev/null || true
    fi

    # Egress allowlist (#135 / #138). Missing/empty == deny-all. Real
    # enclaves get their allowlist baked into the EIF at build time (the
    # builder copies the caller's `--egress-allowlist` JSON into the
    # rootfs at `/etc/enclavia/egress.json`). The e2e harness instead
    # asks for an exact-target permit via `enclavia.target_ip=` /
    # `enclavia.target_port=` on the kernel command line; that path only
    # fires when no real allowlist is already in place.
    if [ -n "$TEST_TARGET_IP" ] && [ -n "$TEST_TARGET_PORT" ] \
       && [ ! -f /etc/enclavia/egress.json ]; then
        /bin/mkdir -p /etc/enclavia
        if [ -n "$TEST_RESOLVER" ]; then
            # `one.one.one.one` is the probe target (queried by nslookup
            # below once unbound is ready). Adding it as a hostname
            # entry punches the necessary `local-zone transparent` hole
            # in unbound's default-refuse policy. Nothing connects to it;
            # it exists only so the resolver test can succeed.
            printf '{ "version": 1, "resolvers": ["%s"], "egress": [ {"host":"%s","port":%s,"protocol":"tcp"}, {"host":"one.one.one.one","port":443,"protocol":"tcp"} ] }\n' \
                "$TEST_RESOLVER" "$TEST_TARGET_IP" "$TEST_TARGET_PORT" \
                > /etc/enclavia/egress.json
            echo "egress: e2e test allowlist installed for ${TEST_TARGET_IP}:${TEST_TARGET_PORT}, resolver=${TEST_RESOLVER}, probe=one.one.one.one"
        else
            printf '{ "version": 1, "egress": [ {"host":"%s","port":%s,"protocol":"tcp"} ] }\n' \
                "$TEST_TARGET_IP" "$TEST_TARGET_PORT" \
                > /etc/enclavia/egress.json
            echo "egress: e2e test allowlist installed for ${TEST_TARGET_IP}:${TEST_TARGET_PORT}"
        fi
    fi

    # Render the unbound config from the template. The template's
    # `server:` block ends with `local-zone: "." refuse` (default-deny).
    # We append, in order:
    #   1. one `local-zone: "<host>." transparent` per allow-listed
    #      hostname in egress.json (still inside the server: block,
    #      since no new section header has appeared yet)
    #   2. a single `forward-zone: "."` block listing the configured
    #      resolvers as `forward-addr` lines
    # The egress daemon parses the same egress.json and auto-injects
    # matching `<resolver>:53/tcp` entries into its IP allowlist so
    # unbound's outbound forwarder traffic is permitted.
    #
    # We only kick off unbound if the rootfs actually shipped it. The
    # daemon is only present when enclavia-egress is, but storage-only
    # / debug-only EIFs may still want the egress daemon without a real
    # allowlist; in that case unbound stays running with an empty
    # forward list, the daemon-side resolver call will fail, and
    # hostname-allowlist entries will deny.
    if [ -x /bin/unbound ] && [ -f /etc/unbound/unbound.conf.template ]; then
        RESOLVERS=""
        HOSTNAMES=""
        if [ -f /etc/enclavia/egress.json ]; then
            # Resolvers are dotted-quad IPv4 strings under .resolvers.
            RESOLVERS=$(/bin/jq -r '.resolvers // [] | .[]' /etc/enclavia/egress.json)
            # Hostname allowlist entries: any .egress[].host that isn't
            # a bare IPv4 (with optional /CIDR). The IPv4 case is handled
            # purely at the egress daemon's L3 allowlist, no DNS involved.
            HOSTNAMES=$(/bin/jq -r '
                .egress // []
                | .[]
                | .host
                | select(test("^[0-9.]+(/[0-9]+)?$") | not)
            ' /etc/enclavia/egress.json)
        fi

        /bin/mkdir -p /etc/unbound
        /bin/cp /etc/unbound/unbound.conf.template /etc/unbound/unbound.conf

        # Per-hostname allowlist overrides. These extend the server:
        # block of the template (no new section header has been written
        # yet), each one punching a hole in `local-zone: "." refuse`.
        {
            for host in $HOSTNAMES; do
                printf '    local-zone: "%s." transparent\n' "$host"
                echo "unbound: allow-listing $host" >&2
            done
        } >> /etc/unbound/unbound.conf

        # Single forward-zone catching everything that survived the
        # local-zone gate. Unbound also uses this zone for its own
        # DNSSEC chain queries (DS/DNSKEY for parent zones), which are
        # not subject to the local-zone refuse check.
        {
            echo ""
            echo "forward-zone:"
            echo "    name: \".\""
            echo "    forward-tls-upstream: no"
            echo "    forward-tcp-upstream: yes"
            for ip in $RESOLVERS; do
                printf '    forward-addr: %s@53\n' "$ip"
                echo "unbound: forwarding to ${ip}:53/tcp" >&2
            done
        } >> /etc/unbound/unbound.conf

        if [ -z "$RESOLVERS" ]; then
            echo "unbound: WARNING: no resolvers in egress.json, hostname allowlist entries will deny" >&2
        fi

        # Start unbound. It listens on 127.0.0.1:53 once it's up; the
        # readiness check below TCP-connects to that port in a loop
        # (unbound-control is not in the rootfs, dig isn't either, but
        # a plain TCP connect is enough to confirm the listener is up).
        /bin/unbound -c /etc/unbound/unbound.conf -d >/tmp/unbound.log 2>&1 &
    fi

    /bin/enclavia-egress >/tmp/egress.log 2>&1 &

    # Wait for tun0 to come up.
    i=0
    while [ $i -lt 100 ]; do
        if /bin/ip link show tun0 >/dev/null 2>&1; then
            break
        fi
        /bin/sleep 0.1
        i=$((i + 1))
    done

    if /bin/ip link show tun0 >/dev/null 2>&1; then
        /bin/ip route add default dev tun0 2>/dev/null || true
        echo "egress: tun0 up, default route installed"
    else
        echo "WARNING: tun0 did not come up; egress unavailable" >&2
    fi

    # Wait for unbound to start listening on 127.0.0.1:53.
    # busybox `nc -z` is the lightest available probe.
    if [ -x /bin/unbound ]; then
        i=0
        while [ $i -lt 50 ]; do
            if /bin/nc -z 127.0.0.1 53 2>/dev/null; then
                echo "unbound: ready on 127.0.0.1:53"
                break
            fi
            /bin/sleep 0.1
            i=$((i + 1))
        done
        if [ $i -ge 50 ]; then
            echo "WARNING: unbound did not become ready in 5s; hostname allowlist will deny" >&2
        fi
    fi

    # Resolver probe (test-only): when the harness supplies a resolver via
    # kernel cmdline, fire one nslookup through unbound to confirm the full
    # forwarding chain (enclavia-egress -> vsock -> egress-host -> upstream)
    # is actually moving DNS packets. Real enclaves do not run this probe.
    if [ -n "$TEST_RESOLVER" ] && [ -x /bin/nslookup ]; then
        echo "unbound-probe: querying one.one.one.one via 127.0.0.1"
        if /bin/nslookup one.one.one.one 127.0.0.1 >/tmp/nslookup.log 2>&1; then
            if /bin/grep -q "1.1.1.1\|1.0.0.1" /tmp/nslookup.log; then
                echo "unbound-probe: SUCCESS"
            else
                echo "unbound-probe: FAILURE (unexpected response):"
                /bin/awk '{print}' /tmp/nslookup.log >&2
            fi
        else
            echo "unbound-probe: FAILURE (nslookup exit nonzero):"
            /bin/awk '{print}' /tmp/nslookup.log >&2
        fi
    fi
fi

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
# Parse storage.enabled / storage.skip_luks from config using shell builtins.
# `builtins.toJSON` in Nix produces a single-line JSON, so case-in-while only
# fires the first matching arm. Use independent `if` checks instead.
STORAGE_ENABLED=false
SKIP_LUKS=false
if [ -f "$CONFIG" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            *'"enabled":true'*) STORAGE_ENABLED=true ;;
            *'"enabled": true'*) STORAGE_ENABLED=true ;;
        esac
        case "$line" in
            *'"skip_luks":true'*) SKIP_LUKS=true ;;
            *'"skip_luks": true'*) SKIP_LUKS=true ;;
        esac
    done < "$CONFIG"
fi

if [ "$STORAGE_ENABLED" = "true" ]; then
    # Mount devtmpfs at /dev — the init binary's chroot leaves /dev empty,
    # but we need kernel device nodes (e.g., /dev/nbd0) for storage.
    /bin/mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
    # Mount sysfs so we can check /sys/block/nbd0/size
    /bin/mount -t sysfs sysfs /sys 2>/dev/null || true

    # Start NBD client — connects to host via vsock CID 2:5001, sets up /dev/nbd0.
    # In skip-LUKS diagnostic mode, the proxy sees raw btrfs writes (no dm-crypt
    # offset translation), so superblock offsets line up at LUKS_DATA_OFFSET=0.
    if [ "$SKIP_LUKS" = "true" ]; then
        LUKS_DATA_OFFSET=0 /bin/enclavia-nbd-client &
    else
        /bin/enclavia-nbd-client &
    fi

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
    if [ -z "$size" ] || ! [ "$size" -gt 0 ] 2>/dev/null; then
        echo "WARNING: /dev/nbd0 not configured (size=0), storage unavailable" >&2
    elif [ "$SKIP_LUKS" = "true" ]; then
        # Diagnostic path: skip LUKS entirely. Format btrfs directly on the
        # raw NBD device and mount it. Used to isolate the proxy's behaviour
        # from cryptsetup's KDF + 16 MiB header wipe overhead on TCG.
        /bin/blkid /dev/nbd0 >/dev/null 2>&1 || /bin/mkfs.btrfs -f /dev/nbd0
        /bin/mkdir -p /data
        /bin/mount -o noatime,noexec,nosuid,nodev /dev/nbd0 /data
        echo "storage: btrfs mounted at /data (LUKS bypassed, diagnostic mode)"
        /bin/mkdir -p "$ROOTFS/data"
        /bin/mount --bind /data "$ROOTFS/data" 2>/dev/null || true
    else
        # Get/create LUKS passphrase via KMS (writes /tmp/luks.key).
        /bin/enclavia-crypto init

        if ! /bin/cryptsetup isLuks /dev/nbd0 2>/dev/null; then
            /bin/cryptsetup luksFormat \
                --batch-mode \
                --key-file /tmp/luks.key \
                /dev/nbd0
        fi
        /bin/cryptsetup luksOpen --key-file /tmp/luks.key /dev/nbd0 encdata

        # Remove plaintext key — must not be accessible to customer code.
        # The upgrade flow re-decrypts via KMS rather than reading this file.
        /bin/rm -f /tmp/luks.key

        # Format with btrfs on first boot. Btrfs gives us csum-tree-rooted
        # tamper detection; the per-superblock-write hooks in nbd-client
        # rely on btrfs's fixed superblock offsets {64KiB, 64MiB, 256GiB}.
        /bin/blkid /dev/mapper/encdata >/dev/null 2>&1 || /bin/mkfs.btrfs -f /dev/mapper/encdata
        /bin/mkdir -p /data
        /bin/mount -o noatime,noexec,nosuid,nodev /dev/mapper/encdata /data
        echo "storage: LUKS-encrypted btrfs mounted at /data"

        # Bind-mount into container rootfs so the app can access it
        /bin/mkdir -p "$ROOTFS/data"
        /bin/mount --bind /data "$ROOTFS/data" 2>/dev/null || true
    fi
fi

# Plumb test-only egress targets to the workload via a known file. The
# e2e harness sets `enclavia.target_ip=` / `enclavia.target_port=` on
# the kernel command line; we surface them as `/etc/egress-test.env`
# inside the OCI rootfs so the busybox workload can `.` it. A real
# enclave's bundle would never look for this file.
if [ -n "$TEST_TARGET_IP" ] && [ -n "$TEST_TARGET_PORT" ]; then
    /bin/mkdir -p "$ROOTFS/etc"
    printf 'TARGET_IP=%s\nTARGET_PORT=%s\n' "$TEST_TARGET_IP" "$TEST_TARGET_PORT" \
        > "$ROOTFS/etc/egress-test.env"
fi

# Start the customer's container in the background using crun.
# --no-pivot: use chroot instead of pivot_root (required on initramfs)
/bin/crun run --no-pivot --bundle /var/lib/oci/bundle customer &

# Start enclavia-server in the foreground, forwarding to the customer's port
exec /bin/enclavia-server --container-addr "127.0.0.1:${CONTAINER_PORT}"
