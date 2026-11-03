#!/usr/bin/env python3
"""Wordtable web end-to-end driver (stdlib only).

Black-box proof for the shippable web path: the static `build/web` dir is
served locally while two scripted "browser tabs" (two persistent WebSocket
sockets, the exact sockets the web export's `NetClient` opens) join one
room by code, complete real moves plus chat relay, and one tab survives a
reload via token rejoin with an identical rack and score.

The deterministic script mirrors `tests/ws_probe.py --smoke` and
`tests/net_smoke.gd`: test-mode room with the timer off, pinned racks,
seat 0 opens CAT at 8G/8H/8I, seat 1 extends to CATS with S at 8J, a
`hello-web` chat relay, then a close-and-`rejoin` resume check with
order-normalized board tiles (the `ReconnectOverlay.compare_snapshots`
rule). The HTTP servability fetch proves the "web dir served"
precondition but never gates the exit code: `build/` is gitignored and
export templates are not installed everywhere, so the play/resume/chat
proof must pass even when `build/web` is absent.

Markers (always printed; exit 0 only when all three hold):
    web_moves=<n>       number of accepted scripted moves (want 2)
    web_moves>=2         literal line printed when <n> >= 2
    web_chat=true|false  chat observed on the peer tab socket
    web_resume_identical=true|false  rejoin snapshot matches pre-drop state

Usage:
    python3 tests/web_e2e.py [--url ws://localhost:9080]
        [--web-url http://localhost:8080] [--web-dir build/web]
        [--web-port 8080] [--timeout 5]
"""

import argparse
import importlib.util
import json
import os
import socket
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path

WS_DEFAULT_URL = "ws://localhost:9080"
WEB_DEFAULT_DIR = "build/web"
WEB_DEFAULT_PORT = 8080
WAIT_SECS = 10.0
CHAT_TEXT = "hello-web"


def _load_probe():
    """Reuse the proven handshake/framing helpers from tests/ws_probe.py."""
    path = Path(__file__).resolve().parent / "ws_probe.py"
    spec = importlib.util.spec_from_file_location("ws_probe", str(path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_probe = _load_probe()


def resolve_ws_url(args):
    """`--server-url=` > `--url=` > `WORDTABLE_SERVER_URL` env, like NetClient."""
    if args.server_url:
        return args.server_url.strip()
    if args.url:
        return args.url.strip()
    env = os.environ.get("WORDTABLE_SERVER_URL", "").strip()
    if env != "":
        return env
    return WS_DEFAULT_URL


def resolve_web_port(args):
    """`--web-port=` > `PORT` env > default, like serve_web/server.gd."""
    if args.web_port is not None:
        try:
            parsed = int(str(args.web_port).strip())
        except (TypeError, ValueError):
            parsed = -1
        if 1 <= parsed <= 65535:
            return parsed
    env = os.environ.get("PORT", "").strip()
    if env != "":
        try:
            parsed_env = int(env)
        except ValueError:
            parsed_env = -1
        if 1 <= parsed_env <= 65535:
            return parsed_env
    return WEB_DEFAULT_PORT


def resolve_web_url(args):
    """`--web-url=` wins; otherwise http://localhost:<web port>."""
    if args.web_url:
        return args.web_url.strip()
    return "http://localhost:%d" % resolve_web_port(args)


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="Drive two scripted web tabs through moves, "
        "chat, and a reload resume.")
    parser.add_argument("--url", default=None, metavar="URL",
                        help="websocket URL of the server "
                        "(default ws://localhost:9080)")
    parser.add_argument("--server-url", default=None, metavar="URL",
                        help="alias of --url (NetClient.resolve_url style)")
    parser.add_argument("--timeout", type=float, default=5.0, metavar="SECS",
                        help="socket timeout in seconds (default 5)")
    parser.add_argument("--web-url", default=None, metavar="URL",
                        help="base URL of the served web dir "
                        "(default http://localhost:8080)")
    parser.add_argument("--web-dir", default=WEB_DEFAULT_DIR, metavar="DIR",
                        help="web dir expected behind --web-url "
                        "(default build/web)")
    parser.add_argument("--web-port", default=None, metavar="N",
                        help="static server port (default 8080, "
                        "overrides PORT env)")
    return parser.parse_args(argv)


def probe_web_dir(web_url, timeout):
    """GET <web-url>/index.html with urllib only; never raises."""
    target = web_url.rstrip("/") + "/index.html"
    try:
        with urllib.request.urlopen(target, timeout=timeout) as reply:
            status = reply.getcode()
            reply.read(1024)
    except urllib.error.HTTPError as exc:
        print("web_served=false")
        print("web_serve_reason=http_%d" % exc.code)
        return False
    except (urllib.error.URLError, socket.timeout, OSError, ValueError) as exc:
        print("web_served=false")
        detail = str(exc).splitlines()[0] if str(exc) else "unreachable"
        print("web_serve_reason=%s" % detail)
        return False
    if status == 200:
        print("web_served=true")
        print("web_http=200")
        return True
    print("web_served=false")
    print("web_serve_reason=http_%d" % status)
    return False


def _send(sock, payload):
    _probe.send_masked_text(sock, json.dumps(payload, separators=(",", ":")))


def _read_frames_until(sock, predicate, wait=WAIT_SECS):
    """Read text frames until predicate(frame) is true or the budget ends."""
    end = time.monotonic() + max(0.1, wait)
    while True:
        remaining = end - time.monotonic()
        if remaining <= 0:
            return None
        try:
            sock.settimeout(remaining)
            opcode, raw = _probe.read_frame(sock)
        except (OSError, IOError, ValueError):
            return None
        if opcode == 0x8:
            return None
        if opcode != 0x1:
            continue
        try:
            frame = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            continue
        if not isinstance(frame, dict):
            continue
        try:
            if predicate(frame):
                return frame
        except (KeyError, TypeError, ValueError):
            continue


def _is_reply(frame, method):
    # Replies always carry `ok`; broadcasts (chat fanout, turn_update,
    # state_sync, ...) never do, so `ok` separates a reply from a queued
    # broadcast that shares the same `m`.
    return frame.get("m") == method and "ok" in frame


def rpc(sock, payload, method, wait=WAIT_SECS):
    """Send one JSON object on a persistent tab socket, wait for its reply."""
    _send(sock, payload)
    return _read_frames_until(sock, lambda f: _is_reply(f, method), wait)


def _rack_str(rack):
    if not isinstance(rack, list):
        return ""
    return "".join("?" if str(x) == "" else str(x) for x in rack)


def _norm_tiles(tiles):
    norm = []
    if isinstance(tiles, list):
        for tile in tiles:
            if isinstance(tile, dict):
                norm.append((str(tile.get("square", "")),
                             str(tile.get("letter", ""))))
    return sorted(norm)


def _snap_equal(before, after):
    # Same rule as ReconnectOverlay.compare_snapshots: rack and scores
    # exact, board_tiles order-normalized.
    if before.get("rack") != after.get("rack"):
        return False
    if before.get("scores") != after.get("scores"):
        return False
    return _norm_tiles(before.get("board_tiles")) == \
        _norm_tiles(after.get("board_tiles"))


class _Abort(Exception):
    """Fatal step failure: stop the script, markers still print below."""


def _fail(reason):
    print("web_error=%s" % reason)
    raise _Abort()


def _ok_reply(reply):
    return isinstance(reply, dict) and reply.get("ok") is True


def _emit_markers(moves, chat_ok, resume_identical):
    # Gate markers print exactly once on every path so grep harnesses
    # never hang on a missing line; exit 0 only when all three hold.
    print("web_moves=%d" % moves)
    if moves >= 2:
        # Literal line for grep harnesses alongside the numeric marker.
        print("web_moves>=2")
    print("web_chat=%s" % ("true" if chat_ok else "false"))
    print("web_resume_identical=%s"
          % ("true" if resume_identical else "false"))


def run(argv=None):
    args = parse_args(argv)
    ws_url = resolve_ws_url(args)
    web_url = resolve_web_url(args)
    timeout = args.timeout if args.timeout and args.timeout > 0 else 5.0

    moves = 0
    chat_ok = False
    resume_identical = False

    # HTTP servability is informational only: it proves the "web dir
    # served" precondition when a static server runs, but a missing
    # build/web must never fail the play/resume/chat proof.
    probe_web_dir(web_url, timeout)

    sock_a = None
    sock_b = None
    try:
        try:
            sock_a = _probe.open_socket(ws_url, timeout)
            sock_b = _probe.open_socket(ws_url, timeout)
        except (OSError, IOError) as exc:
            _fail("cannot_connect_%s" % exc)
        print("web_tabs=2")

        created = rpc(sock_a,
                      {"v": 1, "m": "create_room", "name": "WebA",
                       "test_mode": True, "timer_on": False,
                       "options": {"test_mode": True, "timer_on": False}},
                      "create_room")
        if not _ok_reply(created):
            _fail("create_room")
        code = str(created.get("code", ""))
        tok_a = str(created.get("token", ""))
        if not code or not tok_a or created.get("seat", -1) != 0:
            _fail("create_identity")
        print("web_code=%s" % code)

        joined = rpc(sock_b, {"v": 1, "m": "join_room", "code": code,
                              "name": "WebB"}, "join_room")
        if not _ok_reply(joined):
            _fail("join_room")
        tok_b = str(joined.get("token", ""))
        if not tok_b:
            _fail("join_identity")

        started = rpc(sock_a, {"v": 1, "m": "start_game", "code": code,
                               "token": tok_a}, "start_game")
        if not _ok_reply(started) or started.get("started") is not True:
            _fail("start_game")
        print("web_started=true")

        pin0 = rpc(sock_a, {"v": 1, "m": "debug_set_rack", "code": code,
                            "token": tok_a, "seat": 0,
                            "tiles": ["C", "A", "T", "D", "E", "F", "G"]},
                   "debug_set_rack")
        if not _ok_reply(pin0):
            _fail("pin_seat0")
        pin1 = rpc(sock_a, {"v": 1, "m": "debug_set_rack", "code": code,
                            "token": tok_a, "seat": 1,
                            "tiles": ["S", "H", "I", "J", "K", "L", "M"]},
                   "debug_set_rack")
        if not _ok_reply(pin1):
            _fail("pin_seat1")

        # Move 1: seat 0 opens CAT across the center row.
        cat = rpc(sock_a, {"v": 1, "m": "place_tiles", "code": code,
                           "token": tok_a,
                           "tiles": [{"square": "8G", "letter": "C"},
                                     {"square": "8H", "letter": "A"},
                                     {"square": "8I", "letter": "T"}]},
                  "place_tiles")
        if isinstance(cat, dict) and cat.get("ok") is True \
                and cat.get("accepted") is True:
            moves = 1
            print("web_move1=CAT_accepted")
        else:
            print("web_error=cat_not_accepted")

        # Move 2: seat 1 extends to CATS with S at 8J.
        if moves == 1:
            cats = rpc(sock_b, {"v": 1, "m": "place_tiles", "code": code,
                                "token": tok_b,
                                "tiles": [{"square": "8J", "letter": "S"}]},
                       "place_tiles")
            if isinstance(cats, dict) and cats.get("ok") is True \
                    and cats.get("accepted") is True:
                moves = 2
                print("web_move2=CATS_accepted")
            else:
                print("web_error=cats_not_accepted")

        # Chat relay: seat 0 sends, the guest tab socket must observe it.
        chat_reply = rpc(sock_a, {"v": 1, "m": "chat", "code": code,
                                  "token": tok_a, "text": CHAT_TEXT}, "chat")
        if isinstance(chat_reply, dict) and chat_reply.get("ok") is True:
            seen = _read_frames_until(
                sock_b,
                lambda f: f.get("m") == "chat"
                and f.get("text") == CHAT_TEXT,
                WAIT_SECS)
            chat_ok = seen is not None

        # Tab-reload resume: snapshot the guest via rejoin, kill its
        # socket, rejoin on a fresh socket with the stored token.
        snap_reply = rpc(sock_b, {"v": 1, "m": "rejoin", "code": code,
                                  "token": tok_b}, "rejoin")
        if not _ok_reply(snap_reply):
            _fail("snapshot_rejoin")
        before = {"rack": snap_reply.get("rack", []),
                  "scores": snap_reply.get("scores", []),
                  "board_tiles": snap_reply.get("board_tiles", [])}
        try:
            sock_b.close()
        except OSError:
            pass
        sock_b = None
        try:
            sock_b = _probe.open_socket(ws_url, timeout)
        except (OSError, IOError) as exc:
            _fail("reconnect_failed_%s" % exc)
        again = rpc(sock_b, {"v": 1, "m": "rejoin", "code": code,
                             "token": tok_b}, "rejoin")
        if not _ok_reply(again):
            _fail("rejoin_failed")
        after = {"rack": again.get("rack", []),
                 "scores": again.get("scores", []),
                 "board_tiles": again.get("board_tiles", [])}
        resume_identical = _snap_equal(before, after)
        print("rack=%s" % _rack_str(after.get("rack", [])))
        scores = after.get("scores", [])
        if isinstance(scores, list):
            print("scores=%s" % ",".join(str(x) for x in scores))
        tiles = after.get("board_tiles", [])
        print("board_tiles=%d" % (len(tiles) if isinstance(tiles, list) else -1))
        _emit_markers(moves, chat_ok, resume_identical)
        if moves >= 2 and chat_ok and resume_identical:
            return 0
        return 1
    except _Abort:
        _emit_markers(moves, chat_ok, resume_identical)
        return 1
    finally:
        for sock in (sock_a, sock_b):
            if sock is not None:
                try:
                    sock.close()
                except OSError:
                    pass


def main(argv=None):
    try:
        return run(argv)
    except BrokenPipeError:
        return 1


if __name__ == "__main__":
    sys.exit(main())
