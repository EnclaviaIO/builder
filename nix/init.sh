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
TEST_SECRETS_MODE=""
if [ -r /proc/cmdline ]; then
    while IFS= read -r cmdline || [ -n "$cmdline" ]; do
        for tok in $cmdline; do
            case "$tok" in
                enclavia.target_ip=*) TEST_TARGET_IP="${tok#enclavia.target_ip=}" ;;
                enclavia.target_port=*) TEST_TARGET_PORT="${tok#enclavia.target_port=}" ;;
                enclavia.resolver=*) TEST_RESOLVER="${tok#enclavia.resolver=}" ;;
                enclavia.secrets_mode=*) TEST_SECRETS_MODE="${tok#enclavia.secrets_mode=}" ;;
            esac
        done
    done < /proc/cmdline
fi

# Bring up the loopback interface so enclavia-server can reach the container.
/bin/ip link set lo up
/bin/ip addr add 127.0.0.1/8 dev lo 2>/dev/null || true

# --- Host vsock CID ---
# Nothing to do here: the in-enclave binaries probe for the host CID at
# runtime (enclavia-vsock::host_cid -- CID 3 on real Nitro, CID 2 under
# QEMU), and the patched init heartbeats to both. One EIF, no per-build
# CID baking or env export.

# --- Outbound network egress ---
# When enclavia-egress is present, start it before crun so the workload's
# default route through tun0 is in place by the time the container runs.
# enclavia-egress owns /dev/net/tun, opens it, creates tun0 with the
# configured local IP, and brings it up itself. We add the default route
# once tun0 appears.
if [ -x /bin/enclavia-egress ]; then
    # --- Resolver network-namespace isolation (resolver-bypass hardening) ---
    # unbound runs in its own network namespace connected to the init
    # netns by a veth pair, so its upstream forwarder traffic reaches
    # tun0 from a source address (RESOLVER_IP) distinct from the
    # workload's (the tun address). The egress daemon trusts only
    # RESOLVER_IP for the auto-injected resolver:53 entries, so a
    # workload can no longer bypass unbound by dialing a resolver on
    # TCP/53 directly. The workload stays in the init netns, so the
    # documented inbound 127.0.0.1:<port> contract is untouched.
    RESOLVER_NS="resolver"
    RESOLVER_VETH_HOST="veth-r"     # init-netns end
    RESOLVER_VETH_NS="veth-rns"     # resolver-netns end
    RESOLVER_SUBNET="10.99.2.0/24"
    RESOLVER_GW_IP="10.99.2.1"      # veth-r (init netns)
    RESOLVER_IP="10.99.2.2"         # veth-rns (resolver netns) == unbound
    # `iproute2-ip` is the real static iproute2 (busybox `ip` has no
    # netns/veth support); `/bin/ip` stays busybox for the simple
    # lo/tun0 commands elsewhere in this script.
    IPR=/bin/iproute2-ip

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
    # `server:` block ends with `local-zone: "." refuse` (default-deny);
    # when egress.json says `"dns": "open"` that line is rewritten to
    # `transparent` so unbound resolves any name (the connect-time
    # egress allowlist still applies unchanged).
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
        DNS_MODE="allowlist"
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
            # DNS resolution mode: `allowlist` (default) keeps the
            # template's `local-zone: "." refuse`; `open` swaps it for
            # `transparent` so unbound resolves any name. Connect-time
            # egress enforcement is unaffected either way; this only
            # controls what unbound is willing to answer.
            DNS_MODE=$(/bin/jq -r '.dns // "allowlist"' /etc/enclavia/egress.json)
        fi

        /bin/mkdir -p /etc/unbound
        case "$DNS_MODE" in
            open)
                # awk, not sed: the rootfs busybox does not ship sed.
                # The marker matched here is the template's default-deny
                # line; keep the two in sync.
                /bin/awk '{
                    if ($0 ~ /^[ \t]*local-zone: "\." refuse[ \t]*$/)
                        print "    local-zone: \".\" transparent"
                    else
                        print
                }' /etc/unbound/unbound.conf.template > /etc/unbound/unbound.conf
                echo "unbound: dns mode open (resolving any name)" >&2
                ;;
            allowlist)
                /bin/cp /etc/unbound/unbound.conf.template /etc/unbound/unbound.conf
                ;;
            *)
                # Unknown value. The schema validation upstream (CLI +
                # backend) rejects anything but allowlist/open, so this
                # is belt-and-braces: fall back to the restrictive
                # default rather than failing the boot.
                echo "unbound: WARNING: unknown dns mode '$DNS_MODE', defaulting to allowlist" >&2
                DNS_MODE="allowlist"
                /bin/cp /etc/unbound/unbound.conf.template /etc/unbound/unbound.conf
                ;;
        esac

        # unbound now runs in the resolver netns, so it must listen on
        # the veth address the workload reaches it at (queries arrive
        # sourced from the init-netns veth end, RESOLVER_GW_IP). The
        # template still binds 127.0.0.1 too, which stays valid as the
        # resolver-netns loopback. These are extra server: clauses; no
        # section header has been written yet.
        {
            printf '    interface: %s\n' "$RESOLVER_IP"
            printf '    access-control: 127.0.0.0/8 allow\n'
            printf '    access-control: %s allow\n' "$RESOLVER_SUBNET"
        } >> /etc/unbound/unbound.conf

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

        # Build the resolver netns and the veth pair that links it to
        # the init netns. `ip netns add` bind-mounts a fresh net
        # namespace under /var/run/netns in the ROOT mount namespace (it
        # does not need CLONE_NEWNS, which is what fails on this
        # initramfs), so it works here where crun's mount-ns setup
        # would not. `ip netns add` does a bare (non-recursive)
        # `mkdir /var/run/netns`, so its parent must already exist; the
        # enclave initramfs ships no /var/run, so pre-create it or the
        # add fails ENOENT and set -e aborts the boot (reboot loop).
        /bin/mkdir -p /var/run/netns
        "$IPR" netns add "$RESOLVER_NS"
        "$IPR" link add "$RESOLVER_VETH_HOST" type veth peer name "$RESOLVER_VETH_NS"
        "$IPR" link set "$RESOLVER_VETH_NS" netns "$RESOLVER_NS"
        # Init-netns end: gateway address for the resolver subnet.
        "$IPR" addr add "${RESOLVER_GW_IP}/24" dev "$RESOLVER_VETH_HOST"
        "$IPR" link set "$RESOLVER_VETH_HOST" up
        # Resolver-netns end: unbound's address + loopback + a default
        # route back out through the init netns (where tun0 lives).
        #
        # Enter the netns with `nsenter -n<file>`, NOT `ip -n` /
        # `ip netns exec`: the iproute2 forms unshare a MOUNT namespace
        # and `mount --make-rslave /` + remount /sys, which fails with
        # EINVAL on the enclave's ramfs root (the same mount-ns
        # limitation that makes crun run with --no-pivot and no mount
        # ns). nsenter -n joins ONLY the network namespace, and the
        # ip link/addr/route ops below go over netlink (net-ns scoped),
        # so they land in the resolver netns without touching mounts.
        NSF="/var/run/netns/${RESOLVER_NS}"
        /bin/nsenter -n"$NSF" "$IPR" link set lo up
        /bin/nsenter -n"$NSF" "$IPR" addr add "${RESOLVER_IP}/24" dev "$RESOLVER_VETH_NS"
        /bin/nsenter -n"$NSF" "$IPR" link set "$RESOLVER_VETH_NS" up
        /bin/nsenter -n"$NSF" "$IPR" route add default via "$RESOLVER_GW_IP"
        echo "unbound: resolver netns up (${RESOLVER_IP} via ${RESOLVER_GW_IP})"

        # The egress daemon must trust the resolver's source address for
        # the auto-injected resolver:53 entries. Exported here so it is
        # in the daemon's environment when it starts below.
        export EGRESS_TRUSTED_SRC="$RESOLVER_IP"
        ISOLATED_UNBOUND=1

        # Start unbound INSIDE the resolver netns (net ns only, via
        # nsenter -n as above). It listens on RESOLVER_IP:53 (and its
        # own loopback) once up; the readiness check below TCP-connects
        # to RESOLVER_IP from the init netns over the veth.
        /bin/nsenter -n"$NSF" \
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

        # With unbound isolated, its upstream forwarder traffic is
        # ROUTED from the resolver netns (in on veth-r, out tun0), so
        # enable IPv4 forwarding.
        if [ "${ISOLATED_UNBOUND:-0}" = "1" ]; then
            echo 1 > /proc/sys/net/ipv4/ip_forward

            # Anti-spoof: stop a workload forging the resolver's source
            # address to reach a resolver on :53 directly (the exfil
            # channel the resolver-bypass hardening closes). Legitimate
            # resolver traffic is
            # FORWARDED (in on veth-r), so it never traverses OUTPUT; a
            # workload's raw-socket packet with a resolver-subnet source
            # is LOCALLY generated and does, so this OUTPUT drop hits it
            # without touching the real resolver path. Belt to the
            # source-attribution braces in enclavia-egress: the daemon
            # only trusts RESOLVER_IP, and this keeps that address
            # unforgeable even with CAP_NET_RAW.
            if [ -x /bin/iptables ]; then
                /bin/iptables -A OUTPUT -o tun0 -s "$RESOLVER_SUBNET" -j DROP \
                    && echo "egress: anti-spoof OUTPUT drop installed (${RESOLVER_SUBNET} -> tun0)" \
                    || echo "WARNING: failed to install anti-spoof iptables rule" >&2
            else
                echo "WARNING: /bin/iptables missing; resolver source is not spoof-protected" >&2
            fi
        fi
    else
        echo "WARNING: tun0 did not come up; egress unavailable" >&2
    fi

    # Wait for unbound to start listening on RESOLVER_IP:53. The probe
    # runs from the init netns and reaches unbound (in the resolver
    # netns) over the veth, exactly as the workload will. busybox
    # `nc -z` is the lightest available probe.
    if [ -x /bin/unbound ]; then
        i=0
        while [ $i -lt 50 ]; do
            if /bin/nc -z "$RESOLVER_IP" 53 2>/dev/null; then
                echo "unbound: ready on ${RESOLVER_IP}:53"
                break
            fi
            /bin/sleep 0.1
            i=$((i + 1))
        done
        if [ $i -ge 50 ]; then
            echo "WARNING: unbound did not become ready in 5s; hostname allowlist will deny" >&2
        fi
    fi

    # Pre-warm unbound's upstream forwarder. The first DNS query the
    # workload sends would otherwise race unbound's outbound TCP
    # handshake (egress-daemon → vsock → egress-host → upstream): the
    # default unbound forward timeout (~376ms) is shorter than the
    # cold-start dial, so the workload's very first lookup comes back
    # SERVFAIL even when the allowlist permits it. Subsequent lookups
    # reuse the warm TCP connection and resolve fine.
    #
    # Fix it cheaply for now by firing one best-effort lookup for the
    # first allowlisted hostname before crun spawns the workload. The
    # first iteration probably fails (cold dial); we retry a few times
    # at 1s intervals until it succeeds, then move on. Proper fix is to
    # have unbound pre-establish the TCP forwarder at startup (or bump
    # its `tcp-idle-timeout`); see issue link in the workaround comment.
    if [ -x /bin/nslookup ] && [ -f /etc/enclavia/egress.json ]; then
        WARMUP_HOST=$(/bin/jq -r '
            .egress // []
            | .[]
            | .host
            | select(test("^[0-9.]+(/[0-9]+)?$") | not)
        ' /etc/enclavia/egress.json | /bin/awk 'NR==1')
        if [ -n "$WARMUP_HOST" ]; then
            for i in 1 2 3 4 5; do
                if /bin/nslookup "$WARMUP_HOST" "$RESOLVER_IP" >/dev/null 2>&1; then
                    echo "unbound: pre-warmed upstream forwarder via $WARMUP_HOST"
                    break
                fi
                /bin/sleep 1
            done
        fi
    fi

    # Resolver probe (test-only): when the harness supplies a resolver via
    # kernel cmdline, fire one nslookup through unbound to confirm the full
    # forwarding chain (enclavia-egress -> vsock -> egress-host -> upstream)
    # is actually moving DNS packets. Real enclaves do not run this probe.
    if [ -n "$TEST_RESOLVER" ] && [ -x /bin/nslookup ]; then
        echo "unbound-probe: querying one.one.one.one via ${RESOLVER_IP}"
        if /bin/nslookup one.one.one.one "$RESOLVER_IP" >/tmp/nslookup.log 2>&1; then
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
# Parse storage.enabled / storage.skip_luks with jq, scoped to the
# `storage` section. The previous line-grep matched `"enabled": true`
# from ANY section, so the synchronizer section's `enabled` key (below)
# would have falsely switched storage on for storage-less enclaves; jq
# keys the lookup to exactly `.storage.*`.
STORAGE_ENABLED=false
SKIP_LUKS=false
if [ -f "$CONFIG" ]; then
    STORAGE_ENABLED="$(/bin/jq -r '.storage.enabled // false' "$CONFIG" 2>/dev/null || echo false)"
    SKIP_LUKS="$(/bin/jq -r '.storage.skip_luks // false' "$CONFIG" 2>/dev/null || echo false)"
fi

if [ "$STORAGE_ENABLED" = "true" ]; then
    # Mount devtmpfs at /dev — the init binary's chroot leaves /dev empty,
    # but we need kernel device nodes (e.g., /dev/nbd0) for storage.
    /bin/mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
    # Mount sysfs so we can check /sys/block/nbd0/size
    /bin/mount -t sysfs sysfs /sys 2>/dev/null || true

    # Anti-rollback wiring (enclavia#208): export SYNCHRONIZER_ENABLED=1
    # when the MEASURED config says so (`synchronizer.enabled == true`,
    # set by the builder's --synchronizer-enabled). jq scopes the lookup
    # precisely to that key, unlike the old line-grep for STORAGE which
    # would otherwise also fire on a synchronizer `enabled`. nbd-client
    # then reads synchronizer.expected_pcrs to authenticate the oracle
    # (and fail-stops without). False/absent leaves the var unset and
    # nbd-client runs exactly as before.
    #
    # Plain `export` rather than an `env VAR=... cmd` prefix: the rootfs
    # busybox does not link an `env` applet, and a literal KEY=value
    # prefix cannot be carried in a shell variable. Exporting into the
    # init environment is safe: the OCI workload's process.env is built
    # explicitly and never inherits from init.
    if [ -f "$CONFIG" ] && [ "$(/bin/jq -r '.synchronizer.enabled // false' "$CONFIG" 2>/dev/null)" = "true" ]; then
        export SYNCHRONIZER_ENABLED=1
        echo "init: synchronizer anti-rollback wiring ENABLED"
    fi

    # Start NBD client — connects to host via vsock <VSOCK_HOST_CID>:5001
    # (CID 3 on real Nitro, 2 under QEMU), sets up /dev/nbd0.
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
        # Storage is enabled but the device never came up (host daemon
        # missing, or nbd-client fail-stopped, e.g. the synchronizer's
        # anti-rollback boot verify refused to serve). Booting the
        # workload anyway would hand it an empty tmpfs /data and let it
        # silently run with fresh state, so abort the boot instead and
        # let the parent see the enclave as dead.
        echo "ERROR: /dev/nbd0 not configured (size=0); storage enabled but unavailable, aborting boot" >&2
        exit 1
    elif [ "$SKIP_LUKS" = "true" ]; then
        # Diagnostic path: skip LUKS entirely. Format btrfs directly on the
        # raw NBD device and mount it. Used to isolate the proxy's behaviour
        # from cryptsetup's KDF + 16 MiB header wipe overhead on TCG.
        # -m single: see the LUKS path below — DUP metadata is redundant
        # over EBS and doubles per-commit write I/O.
        /bin/blkid /dev/nbd0 >/dev/null 2>&1 || /bin/mkfs.btrfs -f -m single /dev/nbd0
        /bin/mkdir -p /data
        /bin/mount -o noatime,noexec,nosuid,nodev /dev/nbd0 /data
        echo "storage: btrfs mounted at /data (LUKS bypassed, diagnostic mode)"
        /bin/mkdir -p "$ROOTFS/data"
        if ! /bin/mount --bind /data "$ROOTFS/data"; then
            echo "ERROR: failed to bind persistent /data into the workload rootfs; aborting boot" >&2
            exit 1
        fi
    else
        # --- AWS credentials for the in-enclave KMS call (#199 / #198) ---
        # `enclavia-crypto init` below talks to KMS using in-enclave TLS
        # and hand-rolled SigV4, so it needs AWS_* credentials in ITS
        # process env. crypto inherits init.sh's environment, so we land
        # the creds in init.sh's own env here, BEFORE the call.
        #
        # We reuse the #169 host->enclave secrets channel, but a SECOND
        # pass with a different SINK: `--mode aws-creds` pulls a CBOR map
        # of AWS_* over vsock 5013 (a SEPARATE port from the 5004
        # workload-secrets pass — the host daemon is single-shot, so
        # same-port-twice would race) and writes it to a tmpfs env file
        # (/run/aws-creds.env, KEY=VALUE lines) instead of patching the
        # OCI bundle. We then source + export it so crypto sees the vars.
        #
        # Only present when the EIF baked in enclavia-secrets-init AND
        # the host stood up the creds daemon. On real Nitro the launcher
        # forwards IMDS instance-role creds; under QEMU they are static
        # dummies (mock-kms ignores SigV4). Boot-only: creds rotate
        # ~hourly but the KMS checks here run once, at boot.
        #
        # The pull is fatal-on-failure inside the binary (a missing host
        # daemon means crypto would fail to auth anyway), so `set -e`
        # promotes any failure to a boot abort with a clear log line.
        if [ -x /bin/enclavia-secrets-init ]; then
            echo "init: pulling AWS creds for KMS (vsock 5013) before enclavia-crypto init"
            /bin/enclavia-secrets-init --mode aws-creds /run/aws-creds.env
            if [ -f /run/aws-creds.env ]; then
                # The file is validated clean (KEY=value, valid shell
                # identifiers, no newlines) by enclavia-secrets-init, so
                # `set -a; . file; set +a` is safe and exports every
                # entry into init.sh's env for the crypto child.
                set -a
                # shellcheck disable=SC1091
                . /run/aws-creds.env
                set +a
                # `enclavia-crypto init` selects its real-KMS transport
                # (in-enclave TLS + SigV4 to kms.<region>.amazonaws.com)
                # off KMS_AWS_REGION; the creds feed delivers the region
                # under the standard name AWS_REGION. Bridge the two, but
                # ONLY on real Nitro (host CID 3): under QEMU the same
                # feed carries a dummy region, and KMS there is the
                # plaintext mock-kms, so KMS_AWS_REGION must stay unset to
                # keep crypto on its Mock transport. Without this bridge
                # the production genesis silently runs in Mock mode and
                # speaks plaintext to the TLS KMS endpoint (blob ciphertext
                # stays null, the volume is never LUKS-formatted).
                HOST_CID=""
                read -r HOST_CID < /run/enclavia-host-cid 2>/dev/null || true
                if [ "$HOST_CID" = "3" ] && [ -n "$AWS_REGION" ]; then
                    export KMS_AWS_REGION="$AWS_REGION"
                fi
            fi
        fi

        # Get/create LUKS passphrase via KMS (writes /tmp/luks.key).
        /bin/enclavia-crypto init

        # --- Scrub the AWS creds (load-bearing) ---
        # crypto has consumed them; nothing else at boot needs them. The
        # customer workload must NEVER see kms:Decrypt-capable creds, so
        # unset the vars from init.sh's env (they'd otherwise be inherited
        # by nothing the workload reads — the OCI process.env is built
        # explicitly — but unset anyway for defense in depth) and delete
        # the tmpfs file BEFORE crun start further down. The upgrade flow
        # re-fetches creds via the control path, not from this file.
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION KMS_AWS_REGION
        /bin/rm -f /run/aws-creds.env

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
        #
        # `-m single`: btrfs defaults metadata to DUP (two copies on a single
        # device, even on SSD in recent btrfs-progs), which doubles metadata
        # write I/O on every commit. The backing store is EBS over NBD/vsock
        # and already provides durable replication, so DUP's local-corruption
        # protection is redundant; single metadata roughly halves the writes
        # per durable commit (the dominant cost in the storage write path —
        # see enclavia-crates docs/synchronizer-storage-latency.md). The csum
        # tree and the fixed superblock offsets are unaffected by the profile.
        /bin/blkid /dev/mapper/encdata >/dev/null 2>&1 || /bin/mkfs.btrfs -f -m single /dev/mapper/encdata
        /bin/mkdir -p /data
        /bin/mount -o noatime,noexec,nosuid,nodev /dev/mapper/encdata /data
        echo "storage: LUKS-encrypted btrfs mounted at /data"

        # Bind-mount into container rootfs so the app can access it
        /bin/mkdir -p "$ROOTFS/data"
        if ! /bin/mount --bind /data "$ROOTFS/data"; then
            echo "ERROR: failed to bind persistent /data into the workload rootfs; aborting boot" >&2
            exit 1
        fi
    fi
fi

# Point the workload's libc resolver at the in-enclave unbound. Public
# base images typically ship `nameserver 8.8.8.8` in /etc/resolv.conf,
# which would send hostname lookups straight to the public resolver and
# bypass the unbound forward-zone (so the egress allowlist's hostname
# entries would silently never work). We only overwrite when the egress
# stack is in the rootfs; storage-only / non-egress builds keep whatever
# resolv.conf the OCI image baked in.
#
# unbound now lives in the resolver netns and answers on RESOLVER_IP
# (reachable from the workload's init netns over the veth), NOT on the
# workload's own loopback, so the nameserver is RESOLVER_IP.
if [ -x /bin/enclavia-egress ] && [ "${ISOLATED_UNBOUND:-0}" = "1" ]; then
    /bin/mkdir -p "$ROOTFS/etc"
    printf 'nameserver %s\noptions edns0\n' "$RESOLVER_IP" > "$ROOTFS/etc/resolv.conf"
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

# Per-enclave-secrets e2e (#169): surface enclavia.secrets_mode= so the
# workload can branch its expectations between the inject / empty test
# variants. Same convention as egress-test.env above. Real enclaves
# never set this token.
if [ -n "$TEST_SECRETS_MODE" ]; then
    /bin/mkdir -p "$ROOTFS/etc"
    printf '%s\n' "$TEST_SECRETS_MODE" > "$ROOTFS/etc/secrets-test.mode"
fi

# Per-enclave secrets injection (#169). Pull the host-side snapshot
# from vsock 5004 and splice the entries into the OCI bundle's
# `process.env` before crun reads the config. The binary exits 0
# cleanly when no host-side daemon is listening (the backend only
# starts `secrets-host` when the enclave has secrets configured),
# so it is always safe to invoke. Failures are fatal here: dropping
# secrets silently would let workloads boot with the wrong (or no)
# credentials, which is worse than refusing to start. We tee stderr
# into the serial log via the normal init stderr stream.
if [ -x /bin/enclavia-secrets-init ]; then
    /bin/enclavia-secrets-init /var/lib/oci/bundle
fi

# In-enclave boot-attestation submitter (#47 phase 3b). Dials
# chain-host on vsock 5005, builds a genesis ChainLink with the NSM
# attestation doc, and submits it. The launcher's wait-for-socket
# loop guarantees chain-host is listening before the EIF boots, so
# the dial should always succeed.
#
# Two cases:
#   * Binary absent: this EIF variant was built without chain-init
#     (e.g. a test variant). Skip silently. The corresponding
#     enclavia-crates path also does not stand up chain-host, so
#     there is nothing on the other side to talk to.
#   * Binary present: failure is fatal. Recording the genesis boot
#     link is the whole point of running this binary, and silently
#     swallowing the failure would leave the public chain
#     permanently missing its first entry, with no way for a client
#     walking it later to know whether the absence is "did not
#     happen yet" or "was lost". `set -e` at the top of this script
#     already promotes any non-zero exit here to a boot abort; we
#     prefix the line with the explicit error message so the
#     serial log carries a clear cause.
if [ -x /bin/enclavia-chain-init ]; then
    /bin/enclavia-chain-init \
        || (echo "ERROR: enclavia-chain-init failed; aborting boot" >&2; exit 1)
fi

# Start the customer's container in the background using crun.
# --no-pivot: use chroot instead of pivot_root (required on initramfs)
/bin/crun run --no-pivot --bundle /var/lib/oci/bundle customer &

# Start enclavia-server in the foreground, forwarding to the customer's port
exec /bin/enclavia-server --container-addr "127.0.0.1:${CONTAINER_PORT}"
