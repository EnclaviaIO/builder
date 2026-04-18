#!/usr/bin/env bash
#
# Launch an Enclavia enclave EIF in QEMU for local testing.
#
# Requires:
#   - qemu-system-x86_64 (with nitro-enclave support: libcbor + gnutls)
#   - vhost-device-vsock  (cargo install vhost-device-vsock, or from nixpkgs)
#   - python3             (for the heartbeat responder)
#   - KVM access          (/dev/kvm)
#
# The enclave's vsock port 5000 (enclavia-server) is forwarded to a unix
# socket so host-side software can connect to it for testing.

set -euo pipefail

EIF_PATH="${1:?Usage: $0 <path-to-image.eif> [memory] [cpus]}"
MEMORY="${2:-4G}"
CPUS="${3:-2}"

GUEST_CID=4
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOCK_DIR="$(mktemp -d /tmp/enclave-debug.XXXXXX)"

VHOST_SOCKET="${SOCK_DIR}/vhost.sock"
UDS_PREFIX="${SOCK_DIR}/v"

cleanup() {
    echo "debug-run: cleaning up..."
    # Kill background processes
    kill "${HEARTBEAT_PID:-}" "${VHOST_PID:-}" 2>/dev/null || true
    wait "${HEARTBEAT_PID:-}" "${VHOST_PID:-}" 2>/dev/null || true
    rm -rf "${SOCK_DIR}"
}
trap cleanup EXIT

echo "debug-run: socket dir = ${SOCK_DIR}"
echo "debug-run: EIF        = ${EIF_PATH}"
echo "debug-run: memory     = ${MEMORY}, cpus = ${CPUS}"

# --- 1. Start vhost-device-vsock ---
# Guest connections to any port are forwarded to unix sockets at ${UDS_PREFIX}_${PORT}.
# Host connections to ${UDS_PREFIX}_${PORT} are forwarded to the guest on that port.
echo "debug-run: starting vhost-device-vsock (CID ${GUEST_CID})..."
vhost-device-vsock \
    --vm "guest-cid=${GUEST_CID},socket=${VHOST_SOCKET},uds-path=${UDS_PREFIX}" &
VHOST_PID=$!

# Wait for the vhost socket to appear
for i in $(seq 1 50); do
    [ -S "${VHOST_SOCKET}" ] && break
    sleep 0.1
done
if [ ! -S "${VHOST_SOCKET}" ]; then
    echo "debug-run: ERROR: vhost-device-vsock did not create socket" >&2
    exit 1
fi

# --- 2. Start heartbeat responder ---
# The enclave init sends 0xB7 to CID 3 port 9000 and expects 0xB7 back.
echo "debug-run: starting heartbeat responder..."
python3 "${SCRIPT_DIR}/heartbeat.py" "${UDS_PREFIX}_9000" &
HEARTBEAT_PID=$!

# --- 3. Launch QEMU ---
echo "debug-run: launching QEMU..."
echo ""
echo "  Enclave vsock port 5000 is forwarded to: ${UDS_PREFIX}_5000"
echo "  Connect host-side software to that unix socket for testing."
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
