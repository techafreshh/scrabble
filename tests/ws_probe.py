#!/usr/bin/env python3
"""Wordtable dev-server probe (stdlib only).

Performs an RFC 6455 WebSocket handshake against the headless server and
speaks the versioned JSON RPC surface from docs/protocol.md: one JSON
object per text frame, every client frame carrying `v: 1` and `m: <method>`.

Usage:
    python3 tests/ws_probe.py --ping [--url ws://localhost:9080]
    python3 tests/ws_probe.py --create [--name Host]
    python3 tests/ws_probe.py --join CODE [--name Guest] [--token T]
    python3 tests/ws_probe.py --add-bot --code C --token T
    python3 tests/ws_probe.py --start --code C --token T
    python3 tests/ws_probe.py --pass-turn --code C --token T
    python3 tests/ws_probe.py --chat TEXT --code C --token T
    python3 tests/ws_probe.py --rpc '{"v":1,"m":"chat",...}' [--code C --token T]
    python3 tests/ws_probe.py --smoke

Any action accepts repeatable `--expect k=v`, asserted against the flat
keys of the reply object (`expect_fail k expected=X got=Y`, exit 1).
`--join` also accepts `--code CODE` or a bare positional code; error
replies print exactly `error=<REASON>` with exit 1.
"""

import argparse
import base64
import hashlib
import json
import os
import socket
import struct
import sys
import time
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
    mask = os.urandom(4)
    count = len(payload)
    if count <= 125:
        header = struct.pack("!BB", 0x81, 0x80 | count)
    elif count <= 65535:
        header = struct.pack("!BBH", 0x81, 0x80 | 126, count)
    else:
        header = struct.pack("!BBQ", 0x81, 0x80 | 127, count)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    sock.sendall(header + mask + masked)


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


def open_socket(url, timeout):
    parsed = urlparse(url)
    if parsed.scheme not in ("ws", "http"):
        raise IOError("unsupported URL scheme: %s" % parsed.scheme)
    host = parsed.hostname or "localhost"
    port = parsed.port or 80
    path = parsed.path or "/"
    sock = socket.create_connection((host, port), timeout=timeout)
    sock.settimeout(timeout)
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    do_handshake(sock, host, port, path, key)
    return sock


def rpc_exchange(url, timeout, payload, extra_wait=0.4):
    """Send one JSON object, return every reply frame as decoded objects."""
    sock = open_socket(url, timeout)
    try:
        send_masked_text(sock, json.dumps(payload, separators=(",", ":")))
        messages = []
        while True:
            try:
                opcode, raw = read_frame(sock)
            except IOError as exc:
                if messages:
                    break
                raise
            if opcode == 0x8:
                break
            if opcode != 0x1:
                continue
            try:
                text = raw.decode("utf-8")
            except UnicodeDecodeError:
                raise IOError("reply frame is not valid UTF-8")
            try:
                messages.append(json.loads(text))
            except ValueError:
                messages.append({"_raw": text})
            if len(messages) == 1:
                sock.settimeout(extra_wait)
        return messages
    finally:
        try:
            sock.settimeout(timeout)
        except OSError:
            pass
        sock.close()


def _flat_str(value):
    if value is True:
        return "true"
    if value is False:
        return "false"
    if value is None:
        return "null"
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return str(value)


_FLAT_KEYS = ("m", "ok", "code", "token", "seat", "you", "seats",
             "started", "turn", "accepted", "points", "total", "reason",
             "auto_pass", "rack", "over", "ending", "chat_ok", "emote_ok",
             "recalled", "bag_remaining", "error")


def _flat_lines(reply):
    lines = []
    if isinstance(reply, dict):
        for key in _FLAT_KEYS:
            if key in reply:
                lines.append("%s=%s" % (key, _flat_str(reply[key])))
    return lines


def _rack_str(value):
    if not isinstance(value, list):
        return ""
    return "".join("?" if str(x) == "" else str(x) for x in value)


def check_expects(reply, expects):
    for item in expects or []:
        if "=" not in item:
            print("probe failure: bad --expect %r (want k=v)" % item,
                  file=sys.stderr)
            return 1
        key, _, want = item.partition("=")
        got = _flat_str(reply.get(key, "MISSING")) if isinstance(reply, dict) \
            else "MISSING"
        if got != want:
            print("expect_fail %s expected=%s got=%s" % (key, want, got))
            return 1
    return 0


def emit_extra(messages):
    for extra in messages[1:]:
        if isinstance(extra, dict):
            print("event=%s" % extra.get("m", "unknown"))
        else:
            print("event=unknown")


def run_ping(url, timeout):
    try:
        sock = open_socket(url, timeout)
    except (OSError, IOError) as exc:
        return _fail("cannot connect: %s" % exc)
    try:
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


def run_rpc_action(url, timeout, payload, expects, on_ok):
    try:
        messages = rpc_exchange(url, timeout, payload)
    except (OSError, IOError) as exc:
        return _fail("request failed: %s" % exc)
    if not messages or not isinstance(messages[0], dict):
        return _fail("empty reply from server")
    reply = messages[0]
    if not reply.get("ok", False):
        for line in _flat_lines(reply):
            print(line)
        print("error=%s" % reply.get("error", reply.get("reason", "UNKNOWN")))
        return 1
    for line in on_ok(reply):
        print(line)
    emit_extra(messages)
    return check_expects(reply, expects)


def do_create(args):
    payload = {"v": 1, "m": "create_room", "name": args.name or "Host"}
    opts = {}
    if args.timer_off:
        opts["timer_on"] = False
        payload["timer_on"] = False
    if args.turn_secs is not None:
        opts["turn_secs"] = args.turn_secs
        payload["turn_secs"] = args.turn_secs
    if args.test_mode:
        opts["test_mode"] = True
        payload["test_mode"] = True
    if opts:
        payload["options"] = opts

    def on_ok(reply):
        return ("code=%s" % reply.get("code", ""),
                "token=%s" % reply.get("token", ""),
                "seats=%s" % _flat_str(reply.get("seats", 1)))

    return run_rpc_action(args.url, args.timeout, payload, args.expect, on_ok)


def do_join(args, code):
    payload = {"v": 1, "m": "join_room", "code": code,
               "name": args.name or "Guest"}
    if args.token:
        payload["token"] = args.token

    def on_ok(reply):
        return ("seats=%s" % _flat_str(reply.get("seats", "")),
                "you=%s" % _flat_str(reply.get("you", reply.get("seat", ""))),
                "token=%s" % reply.get("token", ""))

    return run_rpc_action(args.url, args.timeout, payload, args.expect, on_ok)


def do_add_bot(args, code):
    payload = {"v": 1, "m": "add_bot", "code": code, "token": args.token or ""}

    def on_ok(reply):
        return ("seats=%s" % _flat_str(reply.get("seats", "")),)

    return run_rpc_action(args.url, args.timeout, payload, args.expect, on_ok)


def do_start(args, code):
    payload = {"v": 1, "m": "start_game", "code": code,
               "token": args.token or ""}

    def on_ok(reply):
        return ("started=true",
                "turn=%s" % _flat_str(reply.get("turn", "")))

    return run_rpc_action(args.url, args.timeout, payload, args.expect, on_ok)


def do_pass_turn(args, code):
    payload = {"v": 1, "m": "pass", "code": code, "token": args.token or ""}

    def on_ok(reply):
        return ("accepted=true",
                "turn=%s" % _flat_str(reply.get("turn", "")))

    return run_rpc_action(args.url, args.timeout, payload, args.expect, on_ok)


def do_chat(args, code):
    payload = {"v": 1, "m": "chat", "code": code, "token": args.token or "",
               "text": args.chat}

    def on_ok(reply):
        return ("chat_ok=true",)

    return run_rpc_action(args.url, args.timeout, payload, args.expect, on_ok)


def do_place_tiles(args, code):
    try:
        tiles = json.loads(args.tiles) if args.tiles else []
    except ValueError as exc:
        print("probe failure: bad --tiles JSON: %s" % exc, file=sys.stderr)
        return 2
    payload = {"v": 1, "m": "place_tiles", "code": code,
               "token": args.token or "", "tiles": tiles}

    def on_ok(reply):
        return ("accepted=%s" % _flat_str(reply.get("accepted", "")),
                "points=%s" % _flat_str(reply.get("points", "")),
                "reason=%s" % _flat_str(reply.get("reason", "")),
                "total=%s" % _flat_str(reply.get("total", "")),
                "turn=%s" % _flat_str(reply.get("turn", "")))

    return run_rpc_action(args.url, args.timeout, payload, args.expect, on_ok)


def do_rack_dump(args, code):
    payload = {"v": 1, "m": "get_rack", "code": code,
               "token": args.token or ""}

    def on_ok(reply):
        return ("rack=%s" % _rack_str(reply.get("rack", "")),
                "seat=%s" % _flat_str(reply.get("seat", "")),
                "turn=%s" % _flat_str(reply.get("turn", "")))

    return run_rpc_action(args.url, args.timeout, payload, args.expect, on_ok)


def _parse_debug_tiles(text):
    s = (text or "").strip()
    if s.startswith("["):
        try:
            value = json.loads(s)
        except ValueError as exc:
            raise IOError("bad tiles JSON: %s" % exc)
        if isinstance(value, list):
            return [str(x) for x in value]
        return [str(value)]
    return [ch for ch in s if ch not in (",", ";", "|", " ", "\t")]


def do_debug_rack(args, code):
    spec = args.debug_rack or ""
    if ":" not in spec:
        print("probe failure: --debug-rack needs SEAT:TILES", file=sys.stderr)
        return 2
    seat_s, _, tiles_s = spec.partition(":")
    try:
        seat = int(seat_s.strip())
    except ValueError:
        print("probe failure: bad --debug-rack seat %r" % seat_s,
              file=sys.stderr)
        return 2
    try:
        tiles = _parse_debug_tiles(tiles_s)
    except IOError as exc:
        print("probe failure: %s" % exc, file=sys.stderr)
        return 2
    payload = {"v": 1, "m": "debug_set_rack", "code": code,
               "token": args.token or "", "seat": seat, "tiles": tiles}

    def on_ok(reply):
        return ("seat=%s" % _flat_str(reply.get("seat", "")),
                "rack=%s" % _rack_str(reply.get("rack", "")))

    return run_rpc_action(args.url, args.timeout, payload, args.expect, on_ok)


def do_debug_bag(args, code):
    try:
        tiles = _parse_debug_tiles(args.debug_bag)
    except IOError as exc:
        print("probe failure: %s" % exc, file=sys.stderr)
        return 2
    payload = {"v": 1, "m": "debug_set_bag", "code": code,
               "token": args.token or "", "tiles": tiles}

    def on_ok(reply):
        return ("bag_remaining=%s"
                % _flat_str(reply.get("bag_remaining", "")),)

    return run_rpc_action(args.url, args.timeout, payload, args.expect, on_ok)


def do_rejoin(args, code):
    payload = {"v": 1, "m": "rejoin", "code": code,
               "token": args.token or ""}
    start = time.monotonic()
    try:
        messages = rpc_exchange(args.url, args.timeout, payload)
    except (OSError, IOError) as exc:
        return _fail("request failed: %s" % exc)
    if not messages or not isinstance(messages[0], dict):
        return _fail("empty reply from server")
    reply = messages[0]
    if not reply.get("ok", False):
        for line in _flat_lines(reply):
            print(line)
        print("error=%s" % reply.get("error", reply.get("reason", "UNKNOWN")))
        return 1
    ms = int((time.monotonic() - start) * 1000)
    for line in _flat_lines(reply):
        print(line)
    print("rack=%s" % _rack_str(reply.get("rack", "")))
    scores = reply.get("scores", [])
    if isinstance(scores, list):
        print("scores=%s" % ",".join(_flat_str(x) for x in scores))
    tiles = reply.get("board_tiles", [])
    print("board_tiles=%d" % (len(tiles) if isinstance(tiles, list) else -1))
    print("resync_ms=%d" % ms)
    emit_extra(messages)
    return check_expects(reply, args.expect)


def do_listen(args, code):
    try:
        secs = float(args.listen)
    except (TypeError, ValueError):
        print("probe failure: bad --listen value %r" % (args.listen,),
              file=sys.stderr)
        return 2
    payload = {"v": 1, "m": "get_rack", "code": code,
               "token": args.token or ""}
    try:
        sock = open_socket(args.url, args.timeout)
    except (OSError, IOError) as exc:
        return _fail("cannot connect: %s" % exc)
    try:
        try:
            send_masked_text(sock, json.dumps(payload, separators=(",", ":")))
        except (OSError, ValueError) as exc:
            return _fail("failed to send listen probe: %s" % exc)
        end = time.monotonic() + max(0.0, secs)
        while True:
            remaining = end - time.monotonic()
            if remaining <= 0:
                break
            try:
                sock.settimeout(remaining)
                opcode, raw = read_frame(sock)
            except IOError:
                break
            if opcode == 0x8:
                break
            if opcode != 0x1:
                continue
            try:
                text = raw.decode("utf-8")
            except UnicodeDecodeError:
                print("frame=<non-utf8>")
                continue
            try:
                msg = json.loads(text)
            except ValueError:
                print("frame=%s" % text)
                continue
            print("frame=%s" % json.dumps(msg, separators=(",", ":"),
                                            sort_keys=True))
            if isinstance(msg, dict) and msg.get("auto_pass") is True:
                print("auto_pass=true")
    finally:
        sock.close()
    return 0


def do_check_private(args):
    code, tok_a, tok_b = args.check_private
    try:
        ra = rpc_exchange(args.url, args.timeout,
                          {"v": 1, "m": "get_rack", "code": code,
                           "token": tok_a})
        rb = rpc_exchange(args.url, args.timeout,
                          {"v": 1, "m": "get_rack", "code": code,
                           "token": tok_b})
    except (OSError, IOError) as exc:
        return _fail("request failed: %s" % exc)
    fa = ""
    fb = ""
    if ra and isinstance(ra[0], dict) and ra[0].get("ok", False):
        fa = _rack_str(ra[0].get("rack", ""))
    if rb and isinstance(rb[0], dict) and rb[0].get("ok", False):
        fb = _rack_str(rb[0].get("rack", ""))
    print("rack_a=%s" % fa)
    print("rack_b=%s" % fb)
    print("racks_private=%s" % ("true" if (fa and fb and fa != fb) else "false"))
    return 0


def _smoke_rpc(url, timeout, payload):
    """One fresh socket per RPC: send one JSON object, return the reply."""
    sock = open_socket(url, timeout)
    try:
        send_masked_text(sock, json.dumps(payload, separators=(",", ":")))
        while True:
            opcode, raw = read_frame(sock)
            if opcode == 0x8:
                return None
            if opcode != 0x1:
                continue
            try:
                text = raw.decode("utf-8")
            except UnicodeDecodeError:
                return None
            try:
                return json.loads(text)
            except ValueError:
                return None
    finally:
        sock.close()


def _norm_smoke_tiles(tiles):
    norm = []
    if isinstance(tiles, list):
        for tile in tiles:
            if isinstance(tile, dict):
                norm.append((str(tile.get("square", "")),
                             str(tile.get("letter", ""))))
    return sorted(norm)


def _smoke_finish(illegal, resync_ok, gameover_ok):
    print("smoke_game_over=%s" % ("true" if gameover_ok else "false"))
    print("smoke_resync=%s" % ("true" if resync_ok else "false"))
    print("illegal_states=%d" % illegal)
    if resync_ok and gameover_ok and illegal == 0:
        return 0
    return 1


def do_smoke(args):
    """Full legit game over one stateless socket at a time.

    Mirrors tests/net_smoke.gd: test-mode room, CAT opening, forced drop
    of the guest with token rejoin, CATS extension, then six alternating
    passes to the six_scoreless game_over. Every assertion uses only the
    direct RPC reply on a fresh socket, so no broadcast drain is needed.
    """
    illegal = 0
    resync_ok = False
    gameover_ok = False
    resync_ms = -1

    def note(reason):
        nonlocal illegal
        illegal += 1
        print("smoke_note=%s" % reason)

    def rpc(payload):
        try:
            return _smoke_rpc(args.url, args.timeout, payload)
        except (OSError, IOError) as exc:
            note("rpc_error_%s" % payload.get("m", "?"))
            print("smoke_error=%s" % exc)
            return None

    def ok_reply(reply):
        return isinstance(reply, dict) and reply.get("ok", False) is True

    created = rpc({"v": 1, "m": "create_room", "name": "SmokeA",
                   "test_mode": True, "timer_on": False,
                   "options": {"test_mode": True, "timer_on": False}})
    if not ok_reply(created):
        note("create_room")
        return _smoke_finish(illegal, resync_ok, gameover_ok)
    code = created.get("code", "")
    tok_a = created.get("token", "")
    if not code or not tok_a or created.get("seat", -1) != 0:
        note("create_identity")
        return _smoke_finish(illegal, resync_ok, gameover_ok)
    joined = rpc({"v": 1, "m": "join_room", "code": code,
                  "name": "SmokeB"})
    if not ok_reply(joined):
        note("join_room")
        return _smoke_finish(illegal, resync_ok, gameover_ok)
    tok_b = joined.get("token", "")
    if not tok_b or joined.get("seat", joined.get("you", -1)) != 1:
        note("join_identity")
        return _smoke_finish(illegal, resync_ok, gameover_ok)
    if joined.get("seats", 0) != 2:
        note("join_seats")
        return _smoke_finish(illegal, resync_ok, gameover_ok)
    started = rpc({"v": 1, "m": "start_game", "code": code,
                   "token": tok_a})
    if not ok_reply(started) or started.get("started", False) is not True:
        note("start_game")
        return _smoke_finish(illegal, resync_ok, gameover_ok)
    pin0 = rpc({"v": 1, "m": "debug_set_rack", "code": code,
                "token": tok_a, "seat": 0,
                "tiles": ["C", "A", "T", "D", "E", "F", "G"]})
    if not ok_reply(pin0) or pin0.get("seat", -1) != 0:
        note("pin_seat0")
        return _smoke_finish(illegal, resync_ok, gameover_ok)
    pin1 = rpc({"v": 1, "m": "debug_set_rack", "code": code,
                "token": tok_a, "seat": 1,
                "tiles": ["S", "H", "I", "J", "K", "L", "M"]})
    if not ok_reply(pin1) or pin1.get("seat", -1) != 1:
        note("pin_seat1")
        return _smoke_finish(illegal, resync_ok, gameover_ok)
    cat = rpc({"v": 1, "m": "place_tiles", "code": code,
               "token": tok_a,
               "tiles": [{"square": "8G", "letter": "C"},
                         {"square": "8H", "letter": "A"},
                         {"square": "8I", "letter": "T"}]})
    if not ok_reply(cat) or cat.get("accepted", False) is not True:
        note("cat_not_accepted")
        return _smoke_finish(illegal, resync_ok, gameover_ok)
    snap = rpc({"v": 1, "m": "rejoin", "code": code, "token": tok_b})
    if not ok_reply(snap):
        note("snapshot_rejoin")
        return _smoke_finish(illegal, resync_ok, gameover_ok)
    if len(snap.get("board_tiles", []) or []) != 3:
        note("snapshot_tiles_not_3")
        return _smoke_finish(illegal, resync_ok, gameover_ok)
    snap_rack = snap.get("rack", [])
    snap_scores = snap.get("scores", [])
    snap_tiles = _norm_smoke_tiles(snap.get("board_tiles", []))
    try:
        drop = open_socket(args.url, args.timeout)
        try:
            send_masked_text(drop, json.dumps(
                {"v": 1, "m": "get_rack", "code": code,
                 "token": tok_b}, separators=(",", ":")))
            read_frame(drop)
        finally:
            drop.close()
    except (OSError, IOError, ValueError) as exc:
        note("drop_probe")
        print("smoke_error=%s" % exc)
        return _smoke_finish(illegal, resync_ok, gameover_ok)
    begin = time.monotonic()
    again = rpc({"v": 1, "m": "rejoin", "code": code,
                 "token": tok_b})
    resync_ms = int((time.monotonic() - begin) * 1000)
    print("smoke_resync_ms=%d" % resync_ms)
    if not ok_reply(again):
        note("rejoin")
        return _smoke_finish(illegal, resync_ok, gameover_ok)
    same = (again.get("seat", again.get("you", -9)) == 1
            and again.get("rack", []) == snap_rack
            and again.get("scores", []) == snap_scores
            and _norm_smoke_tiles(again.get("board_tiles", [])) == snap_tiles)
    if resync_ms >= 3000:
        note("resync_too_slow")
        return _smoke_finish(illegal, resync_ok, gameover_ok)
    if not same:
        note("resync_snapshot_mismatch")
        return _smoke_finish(illegal, resync_ok, gameover_ok)
    resync_ok = True
    print("smoke_resync=true")
    cats = rpc({"v": 1, "m": "place_tiles", "code": code,
                "token": tok_b,
                "tiles": [{"square": "8J", "letter": "S"}]})
    if not ok_reply(cats) or cats.get("accepted", False) is not True:
        note("cats_not_accepted")
        return _smoke_finish(illegal, resync_ok, gameover_ok)
    final = None
    for i in range(6):
        tok = tok_a if i % 2 == 0 else tok_b
        passed = rpc({"v": 1, "m": "pass", "code": code, "token": tok})
        if not ok_reply(passed):
            note("pass_%d_reply" % i)
            return _smoke_finish(illegal, resync_ok, gameover_ok)
        if passed.get("accepted", False) is not True:
            note("pass_%d_not_accepted" % i)
            return _smoke_finish(illegal, resync_ok, gameover_ok)
        final = passed
    if not isinstance(final, dict) or final.get("over", False) is not True:
        note("game_never_over")
        return _smoke_finish(illegal, resync_ok, gameover_ok)
    if final.get("ending", "") != "six_scoreless":
        note("ending_not_six_scoreless")
        return _smoke_finish(illegal, resync_ok, gameover_ok)
    delta = final.get("delta", {})
    history = delta.get("history", []) if isinstance(delta, dict) else []
    if not isinstance(history, list) or len(history) < 2:
        note("history_too_short")
        return _smoke_finish(illegal, resync_ok, gameover_ok)
    gameover_ok = True
    print("smoke_game_over=true")
    return _smoke_finish(illegal, resync_ok, gameover_ok)


def do_generic_rpc(args):
    try:
        payload = json.loads(args.rpc)
    except ValueError as exc:
        print("probe failure: bad --rpc JSON: %s" % exc, file=sys.stderr)
        return 2
    if not isinstance(payload, dict):
        print("probe failure: --rpc must be a JSON object", file=sys.stderr)
        return 2
    code = args.code or args.positional_code
    if code and "code" not in payload:
        payload["code"] = code
    if args.token and "token" not in payload:
        payload["token"] = args.token
    if "v" not in payload and "version" not in payload:
        payload["v"] = 1

    def on_ok(reply):
        lines = _flat_lines(reply)
        lines.append("json=%s" % json.dumps(reply, separators=(",", ":"),
                                            sort_keys=True))
        return lines

    return run_rpc_action(args.url, args.timeout, payload, args.expect, on_ok)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Probe the Wordtable server.")
    parser.add_argument("--ping", action="store_true",
                        help="send a ping frame and expect PONG")
    parser.add_argument("--create", action="store_true",
                        help="create a room and print code=/token=/seats=")
    parser.add_argument("--join", nargs="?", const=True, default=None,
                        metavar="CODE",
                        help="join a room (value, --code, or positional)")
    parser.add_argument("--code", default=None,
                        help="room code alias for join/add-bot/start/pass/chat")
    parser.add_argument("--name", default=None,
                        help="seat display name (default Host/Guest)")
    parser.add_argument("--token", default="",
                        help="session token for room actions")
    parser.add_argument("--add-bot", action="store_true",
                        help="seat the Botgomery stub (needs --code/--token)")
    parser.add_argument("--start", action="store_true",
                        help="start the game (needs --code/--token)")
    parser.add_argument("--pass-turn", action="store_true",
                        help="pass the current turn (needs --code/--token)")
    parser.add_argument("--chat", nargs="?", const="", default=None,
                        metavar="TEXT",
                        help="send a chat message (needs --code/--token)")
    parser.add_argument("--place-tiles", action="store_true",
                        help="commit tiles (needs --code/--token/--tiles)")
    parser.add_argument("--tiles", default=None, metavar="JSON",
                        help="tiles array for --place-tiles")
    parser.add_argument("--rack-dump", action="store_true",
                        help="print this seat's private rack (needs --code/--token)")
    parser.add_argument("--rejoin", action="store_true",
                        help="rejoin with the stored token (needs --code, "
                        "optional --token; wrong tokens print error=BAD_TOKEN)")
    parser.add_argument("--debug-rack", default=None, metavar="SEAT:TILES",
                        help="pin a seat rack on a test-mode room "
                        "(needs --code/--token)")
    parser.add_argument("--debug-bag", default=None, metavar="TILES",
                        help="replace the bag on a test-mode room "
                        "(needs --code/--token)")
    parser.add_argument("--listen", nargs="?", const=4.0, default=None,
                        type=float, metavar="SECS",
                        help="watch room broadcasts for SECS seconds "
                        "(needs --code/--token)")
    parser.add_argument("--check-private", nargs=3, default=None,
                        metavar=("CODE", "TOKA", "TOKB"),
                        help="compare two seats' racks for privacy")
    parser.add_argument("--timer-off", action="store_true",
                        help="with --create: store timer_on false")
    parser.add_argument("--turn-secs", type=int, default=None, metavar="N",
                        help="with --create: per-turn clock override in seconds")
    parser.add_argument("--test-mode", action="store_true",
                        help="with --create: allow host debug pin RPCs")
    parser.add_argument("--rpc", default=None, metavar="JSON",
                        help="send a raw JSON object frame")
    parser.add_argument("--smoke", action="store_true",
                        help="run the 2-client forced-drop full-game smoke "
                        "(prints smoke_game_over/smoke_resync/illegal_states)")
    parser.add_argument("--expect", action="append", default=[],
                        metavar="k=v",
                        help="assert a flat reply key (repeatable)")
    parser.add_argument("--url", default="ws://localhost:9080",
                        help="websocket URL of the server (default ws://localhost:9080)")
    parser.add_argument("--timeout", type=float, default=5.0,
                        help="socket timeout in seconds (default 5)")
    parser.add_argument("positional_code", nargs="?", default=None,
                        help="room code (implies --join)")
    args = parser.parse_args(argv)

    if args.ping:
        return run_ping(args.url, args.timeout)
    if args.smoke:
        return do_smoke(args)
    if args.create:
        return do_create(args)
    join_value = None
    if args.join is not None:
        join_value = args.join if isinstance(args.join, str) else None
        code = join_value or args.code or args.positional_code
        if not code:
            parser.print_usage(sys.stderr)
            print("probe failure: --join needs a room code",
                  file=sys.stderr)
            return 2
        return do_join(args, code)
    if args.rejoin:
        code = args.code or args.positional_code
        if not code:
            parser.print_usage(sys.stderr)
            print("probe failure: --rejoin needs --code", file=sys.stderr)
            return 2
        return do_rejoin(args, code)
    if args.positional_code is not None and args.rpc is None \
            and not (args.add_bot or args.start or args.pass_turn
                     or args.chat is not None or args.place_tiles
                     or args.rack_dump or args.debug_rack is not None
                     or args.debug_bag is not None or args.listen is not None):
        return do_join(args, args.positional_code)
    needs_room = args.add_bot or args.start or args.pass_turn \
        or args.chat is not None or args.place_tiles or args.rack_dump \
        or args.debug_rack is not None or args.debug_bag is not None \
        or args.listen is not None
    if needs_room:
        code = args.code or args.positional_code
        if not code:
            parser.print_usage(sys.stderr)
            print("probe failure: this action needs --code", file=sys.stderr)
            return 2
        if not args.token:
            parser.print_usage(sys.stderr)
            print("probe failure: this action needs --token", file=sys.stderr)
            return 2
        if args.add_bot:
            return do_add_bot(args, code)
        if args.start:
            return do_start(args, code)
        if args.pass_turn:
            return do_pass_turn(args, code)
        if args.place_tiles:
            return do_place_tiles(args, code)
        if args.rack_dump:
            return do_rack_dump(args, code)
        if args.debug_rack is not None:
            return do_debug_rack(args, code)
        if args.debug_bag is not None:
            return do_debug_bag(args, code)
        if args.listen is not None:
            return do_listen(args, code)
        return do_chat(args, code)
    if args.check_private is not None:
        return do_check_private(args)
    if args.rpc is not None:
        return do_generic_rpc(args)
    parser.print_usage(sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
