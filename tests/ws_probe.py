#!/usr/bin/env python3
"""Wordtable dev-server probe (walking skeleton, stdlib only).

Performs an RFC 6455 WebSocket handshake against the headless server, sends a
masked text frame `ping`, and expects a text frame `PONG`.

Usage:
    python3 tests/ws_probe.py --ping [--url ws://localhost:9080] [--timeout 5]
"""

import argparse
import base64
import hashlib
import os
import socket
import struct
import sys
from urllib.parse import urlparse

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def _fail(message):
    print("probe failure: %s" % message, file=sys.stderr)
    return 1


def _recv_exact(sock, count, timeout_desc="peer"):
    chunks = b""
    while len(chunks) < count:
        try:
            data = sock.recv(count - len(chunks))
        except socket.timeout:
            raise IOError("timed out reading from %s" % timeout_desc)
        if not data:
            raise IOError("connection closed by %s" % timeout_desc)
        chunks += data
    return chunks


def do_handshake(sock, host, port, path, key):
    request = (
        "GET %s HTTP/1.1\r\n"
        "Host: %s:%d\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Key: %s\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n" % (path, host, port, key)
    )
    sock.sendall(request.encode("ascii"))
    response = b""
    while b"\r\n\r\n" not in response:
        try:
            chunk = sock.recv(4096)
        except socket.timeout:
            raise IOError("timed out waiting for handshake response")
        if not chunk:
            raise IOError("connection closed during handshake")
        response += chunk
        if len(response) > 65536:
            raise IOError("handshake response too large")
    header = response.split(b"\r\n\r\n", 1)[0].decode("latin1")
    lines = header.split("\r\n")
    if "101" not in lines[0]:
        raise IOError("expected 101 Switching Protocols, got: %s" % lines[0])
    accept_expected = base64.b64encode(
        hashlib.sha1((key + WS_GUID).encode("ascii")).digest()
    ).decode("ascii")
    headers = {}
    for line in lines[1:]:
        if ":" in line:
            name, _, value = line.partition(":")
            headers[name.strip().lower()] = value.strip()
    if headers.get("sec-websocket-accept") != accept_expected:
        raise IOError("bad Sec-WebSocket-Accept in handshake response")


def send_masked_text(sock, text):
    payload = text.encode("utf-8")
    if len(payload) > 125:
        raise ValueError("payload too large for skeleton probe")
    mask = os.urandom(4)
    header = struct.pack("!BB", 0x81, 0x80 | len(payload)) + mask
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    sock.sendall(header + masked)


def read_frame(sock):
    hdr = _recv_exact(sock, 2, "server")
    b1, b2 = hdr[0], hdr[1]
    opcode = b1 & 0x0F
    masked = (b2 & 0x80) != 0
    length = b2 & 0x7F
    if length == 126:
        length = struct.unpack("!H", _recv_exact(sock, 2, "server"))[0]
    elif length == 127:
        length = struct.unpack("!Q", _recv_exact(sock, 8, "server"))[0]
    mask_key = _recv_exact(sock, 4, "server") if masked else None
    payload = _recv_exact(sock, length, "server") if length else b""
    if masked:
        payload = bytes(b ^ mask_key[i % 4] for i, b in enumerate(payload))
    return opcode, payload


def run_ping(url, timeout):
    parsed = urlparse(url)
    if parsed.scheme not in ("ws", "http"):
        return _fail("unsupported URL scheme: %s" % parsed.scheme)
    host = parsed.hostname or "localhost"
    port = parsed.port or 80
    path = parsed.path or "/"
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    try:
        sock = socket.create_connection((host, port), timeout=timeout)
    except OSError as exc:
        return _fail("cannot connect to %s:%d: %s" % (host, port, exc))
    try:
        sock.settimeout(timeout)
        try:
            do_handshake(sock, host, port, path, key)
        except IOError as exc:
            return _fail("handshake failed: %s" % exc)
        try:
            send_masked_text(sock, "ping")
        except (OSError, ValueError) as exc:
            return _fail("failed to send ping frame: %s" % exc)
        try:
            opcode, payload = read_frame(sock)
        except IOError as exc:
            return _fail("failed to read pong frame: %s" % exc)
        if opcode != 0x1:
            return _fail("expected text frame (0x1), got opcode 0x%x" % opcode)
        try:
            text = payload.decode("utf-8")
        except UnicodeDecodeError:
            return _fail("pong payload is not valid UTF-8")
        if text != "PONG":
            return _fail("expected PONG, got %r" % text)
    finally:
        sock.close()
    print("PONG")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="Probe the Wordtable dev server.")
    parser.add_argument("--ping", action="store_true",
                        help="send a ping frame and expect PONG")
    parser.add_argument("--url", default="ws://localhost:9080",
                        help="websocket URL of the server (default ws://localhost:9080)")
    parser.add_argument("--timeout", type=float, default=5.0,
                        help="socket timeout in seconds (default 5)")
    args = parser.parse_args(argv)
    if not args.ping:
        parser.print_usage(sys.stderr)
        return 2
    return run_ping(args.url, args.timeout)


if __name__ == "__main__":
    sys.exit(main())
