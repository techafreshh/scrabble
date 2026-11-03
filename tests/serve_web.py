#!/usr/bin/env python3
"""Wordtable static web server (stdlib only).

Serves the exported web build (`build/web` by default) over plain HTTP so
the friend-on-phone path and `tests/web_e2e.py` have a mechanically
checkable "web dir served" precondition. Single-threaded on purpose: the
web export is single-threaded (`variant/thread_support=false`), so no
COOP/COEP isolation headers are ever set here.

Port precedence mirrors scripts/server/server.gd `_resolve_port`:
`--port=` (or `--web-port=`) > `PORT` env > default 8080.
Directory precedence mirrors scripts/client/net_client.gd `resolve_url`
arg style: `--dir=` (or `--web-dir=`) > default `build/web`; when the
directory is absent the repo root is served instead with a warning so the
server still boots on machines without export templates installed.

Usage:
    python3 tests/serve_web.py [--port 8080] [--dir build/web]
    curl -s http://localhost:8080/ | head -1
"""

import argparse
import os
import sys
from functools import partial
from http.server import HTTPServer, SimpleHTTPRequestHandler
from pathlib import Path

DEFAULT_PORT = 8080
DEFAULT_DIR = "build/web"


def resolve_port(args):
    """`--port=`/`--web-port=` > `PORT` env > default, like server.gd."""
    for raw in (args.port, args.web_port):
        if raw is None:
            continue
        try:
            parsed = int(str(raw).strip())
        except (TypeError, ValueError):
            continue
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
    return DEFAULT_PORT


def resolve_dir(args):
    """`--dir=`/`--web-dir=` > default; missing dir falls back to repo root."""
    repo_root = Path(__file__).resolve().parent.parent
    raw = args.web_dir or args.dir or DEFAULT_DIR
    candidate = Path(str(raw))
    if not candidate.is_absolute():
        candidate = repo_root / candidate
    if candidate.is_dir():
        return candidate
    print("serve_web: warning: %s absent, serving repo root instead"
          % candidate, file=sys.stderr)
    return repo_root


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="Serve the Wordtable web export over plain HTTP.")
    parser.add_argument("--port", default=None, metavar="N",
                        help="port to listen on (default 8080, "
                        "overrides PORT env)")
    parser.add_argument("--web-port", default=None, metavar="N",
                        help="alias of --port")
    parser.add_argument("--dir", default=None, metavar="DIR",
                        help="directory to serve (default build/web)")
    parser.add_argument("--web-dir", default=None, metavar="DIR",
                        help="alias of --dir")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    port = resolve_port(args)
    root = resolve_dir(args)
    handler = partial(SimpleHTTPRequestHandler, directory=str(root))
    # HTTPServer is single-threaded by construction; the default handler
    # sets no Cross-Origin-Opener-Policy/Embedder-Policy headers, which is
    # exactly what the single-threaded web export requires.
    server = HTTPServer(("0.0.0.0", port), handler)
    print("serving %s on %d" % (root, port), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
