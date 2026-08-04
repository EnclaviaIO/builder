#!/usr/bin/env bash
#
# Launch an Enclavia enclave EIF in QEMU for local testing.
#
# Requires:
#   - qemu-system-x86_64 >= 9.2 (nitro-enclave machine type)
#   - vhost-device-vsock  (cargo install vhost-device-vsock)
#   - python3             (for the heartbeat responder)
#   - KVM access          (/dev/kvm) — or omit --enable-kvm for TCG (slow)
#
# See docs/debug-qemu.md for full setup instructions.

set -euo pipefail

EIF_PATH="${1:?Usage: $0 <path-to-image.eif> [memory] [cpus]}"
MEMORY="${2:-4G}"
CPUS="${3:-2}"

GUEST_CID=4
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOCK_DIR="$(mktemp -d /tmp/enclave-debug.XXXXXX)"

VHOST_SOCKET="${SOCK_DIR}/vhost.sock"

cleanup() {
    echo "debug-run: cleaning up..."
    kill "${HEARTBEAT_PID:-}" "${VHOST_PID:-}" 2>/dev/null || true
    wait "${HEARTBEAT_PID:-}" "${VHOST_PID:-}" 2>/dev/null || true
    rm -rf "${SOCK_DIR}"
}
trap cleanup EXIT

echo "debug-run: socket dir = ${SOCK_DIR}"
echo "debug-run: EIF        = ${EIF_PATH}"
echo "debug-run: memory     = ${MEMORY}, cpus = ${CPUS}"

# --- 1. Start vhost-device-vsock ---
# --forward-cid=1 forwards guest vsock connections to the host's AF_VSOCK,
# allowing the heartbeat responder and other host services to listen normally.
echo "debug-run: starting vhost-device-vsock (CID ${GUEST_CID})..."
vhost-device-vsock \
    --vm "guest-cid=${GUEST_CID},socket=${VHOST_SOCKET},forward-cid=1" &
VHOST_PID=$!

for i in $(seq 1 50); do
    [ -S "${VHOST_SOCKET}" ] && break
    sleep 0.1
done
if [ ! -S "${VHOST_SOCKET}" ]; then
    echo "debug-run: ERROR: vhost-device-vsock did not create socket" >&2
    exit 1
fi

# --- 2. Start heartbeat responder ---
# The enclave init sends 0xB7 to both Nitro CID 3 and QEMU CID 2 on port 9000,
# then accepts the first valid echo. Listen on AF_VSOCK here for the QEMU path.
echo "debug-run: starting heartbeat responder..."
python3 "${SCRIPT_DIR}/heartbeat.py" &
HEARTBEAT_PID=$!

# --- 3. Launch QEMU ---
echo "debug-run: launching QEMU..."
echo ""
echo "  Enclave vsock CID:  ${GUEST_CID}"
echo "  Enclave vsock port: 5000 (enclavia-server)"
echo ""

qemu-system-x86_64 \
    -M "nitro-enclave,vsock=c,id=enclavia-debug" \
    -chardev "socket,id=c,path=${VHOST_SOCKET}" \
    -kernel "${EIF_PATH}" \
    -nographic \
    -m "${MEMORY}" \
    -smp "${CPUS}" \
    --enable-kvm \
    -cpu host
