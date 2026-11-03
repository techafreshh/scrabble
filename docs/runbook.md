# Wordtable deployment runbook

> Written, not executed. This file is documentation only: no VPS, domain
> registrar, Cloudflare dashboard, or store listing was touched to produce
> it. Follow it by hand when you are ready to host a live table.

## 0. What you need

- A Linux host (any small VPS) with `godot` 4.7 headless binaries.
- A domain you control (for `wss://` play through Cloudflare Tunnel).
- This repo checked out on the host with the SOWPODS lexicon bundled
  (`dictionaries/sowpods.txt` ships in the repo; no download step).

## 1. systemd unit (autostart with restart)

Install as `/etc/systemd/system/wordtable.service`:

```ini
[Unit]
Description=Wordtable headless game server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=wordtable
WorkingDirectory=/opt/wordtable
Environment=PORT=9080
ExecStart=/usr/local/bin/godot --headless --path /opt/wordtable
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

Then:

```
sudo systemctl daemon-reload
sudo systemctl enable --now wordtable
journalctl -u wordtable -f   # journald log tail
```

Notes:

- `Restart=always` keeps the table up across crashes and reboots
  (`enable` wires it into boot).
- `PORT` env overrides the default `9080` (CLI `--port=NNNN` wins over
  env when both are set).
- All server output goes to stdout, so `journald` already captures it;
  no log files to rotate.

## 2. Cloudflare Tunnel (no open ports)

Serve secure `wss://` clients without opening firewall ports: run
`cloudflared` on the same host and point it at the local server.

`/etc/cloudflared/config.yml`:

```yaml
tunnel: <TUNNEL_ID>
credentials-file: /etc/cloudflared/<TUNNEL_ID>.json

ingress:
  - hostname: play.example.com
    service: ws://localhost:9080
  - service: http_status:404
```

Then:

```
cloudflare tunnel route dns <TUNNEL_ID> play.example.com
sudo systemctl enable --now cloudflared
```

Clients connect to `wss://play.example.com` (append
`--server-url=wss://play.example.com` or set `WORDTABLE_SERVER_URL`).
The Cloudflare Tunnel edge terminates TLS, so the game server itself
stays plain `ws://` on localhost and the host firewall can stay closed.

## 3. Domain checklist

- [ ] Domain registered and added to the Cloudflare account (nameservers
      pointing at Cloudflare).
- [ ] `play.<domain>` DNS record created by the `tunnel route dns`
      command above (proxied/orange cloud).
- [ ] Edge TLS mode `Full (strict)` or better; HSTS optional.
- [ ] Wait for certificate issuance, then open
      `https://play.<domain>` in a browser and confirm the WebSocket
      upgrade succeeds (a `ping` frame answers `PONG`).
- [ ] Confirm a two-client smoke passes through the tunnel:
      `python3 tests/ws_probe.py --smoke --url wss://play.<domain>`.

## 4. Environment knobs

| Knob | Where | Default | Effect |
|---|---|---|---|
| `PORT` | env / `--port=` | `9080` | TCP port the headless server listens on |
| `WORDTABLE_SERVER_URL` | client env / `--server-url=` | `ws://localhost:9080` | server the clients dial |
| `timer_on` / `timer_off` | room `options` | on | per-turn clock vs. 180 s stall guard |
| `turn_secs` (aliases: `timer_secs`, `turn_timeout`, `timeout_secs`, `turn_limit_secs`) | room `options` | `90` (clock on) | per-turn limit, clamped 1–3600 s |
| lexicon | `dictionaries/sowpods.txt` | bundled | word validation; server boots without it but skips word checks |

Health checks after deploy: `python3 tests/ws_probe.py --ping` answers
`PONG`; the CI `gates` and `network-smoke` jobs exercise create, join,
start, private racks, legal/illegal commits, chat, timers, reconnect,
and the six-scoreless full-game smoke.
