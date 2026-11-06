#!/usr/bin/env python3
"""ProxyCommand helper: open a TCP connection to host:port through the
runtime HTTP proxy's Tailscale port (3130), using HTTP CONNECT, then
relay stdin/stdout. Used by ssh-mac.sh:

    ssh -o ProxyCommand="python3 mac-proxy-connect.py %h %p" user@host

The proxy address and credentials are read from the HTTPS_PROXY
environment variable; only the port is changed to 3130.
"""
import base64
import os
import select
import socket
import sys
import urllib.parse


def main() -> int:
    host, port = sys.argv[1], int(sys.argv[2])
    proxy = urllib.parse.urlparse(os.environ["HTTPS_PROXY"])
    upstream = socket.create_connection((proxy.hostname, 3130), timeout=30)

    auth = ""
    if proxy.username:
        cred = base64.b64encode(
            f"{proxy.username}:{proxy.password}".encode()).decode()
        auth = f"Proxy-Authorization: Basic {cred}\r\n"
    target = f"{host}:{port}"
    upstream.sendall(
        f"CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n{auth}\r\n".encode())

    resp = b""
    while b"\r\n\r\n" not in resp:
        chunk = upstream.recv(4096)
        if not chunk:
            print("proxy closed during CONNECT", file=sys.stderr)
            return 1
        resp += chunk
    status = resp.split(b"\r\n", 1)[0]
    if b" 200 " not in status and not status.endswith(b" 200"):
        print(f"CONNECT failed: {status!r}", file=sys.stderr)
        return 1
    # Any bytes after the header belong to the tunneled stream.
    head, _, rest = resp.partition(b"\r\n\r\n")
    if rest:
        sys.stdout.buffer.write(rest)
        sys.stdout.buffer.flush()

    upstream.setblocking(False)
    stdin = sys.stdin.buffer
    while True:
        rlist, _, _ = select.select([upstream, stdin], [], [], 60)
        if not rlist:
            continue
        for src in rlist:
            if src is upstream:
                data = upstream.recv(65536)
                if not data:
                    return 0
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
            else:
                data = os.read(0, 65536)
                if not data:
                    try:
                        upstream.shutdown(socket.SHUT_WR)
                    except OSError:
                        pass
                    continue
                upstream.sendall(data)


if __name__ == "__main__":
    sys.exit(main())
