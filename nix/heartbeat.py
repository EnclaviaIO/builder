#!/usr/bin/env python3
"""
Heartbeat responder for QEMU nitro-enclave.

The enclave's init process connects to CID 3 port 9000 and sends a single
byte (0xB7) expecting the same byte back. Without this response the enclave
will not finish booting.

Supports two modes:
  - AF_VSOCK: listen on vsock CID for host-forwarded connections (default)
  - Unix socket: listen on a Unix domain socket path (--uds <path>)
"""

import os
import socket
import sys


HEARTBEAT_PORT = 9000


def listen_vsock():
    """Listen on AF_VSOCK (used with vhost-device-vsock --forward-cid)."""
    AF_VSOCK = 40  # socket.AF_VSOCK
    VMADDR_CID_ANY = 0xFFFFFFFF

    srv = socket.socket(AF_VSOCK, socket.SOCK_STREAM)
    srv.bind((VMADDR_CID_ANY, HEARTBEAT_PORT))
    srv.listen(1)

    print(f"heartbeat: listening on vsock port {HEARTBEAT_PORT}", flush=True)
    return srv


def listen_uds(path):
    """Listen on a Unix domain socket (used with vhost-device-vsock --uds-path)."""
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    srv.listen(1)

    print(f"heartbeat: listening on {path}", flush=True)
    return srv


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "--uds":
        srv = listen_uds(sys.argv[2])
    else:
        srv = listen_vsock()

    while True:
        conn, addr = srv.accept()
        try:
            data = conn.recv(1)
            if data == b"\xb7":
                conn.sendall(b"\xb7")
                print(f"heartbeat: replied to enclave init (from {addr})", flush=True)
        finally:
            conn.close()


if __name__ == "__main__":
    main()
