# <img src="icon.svg" width="32" height="32" alt="Wordtable logo"> Wordtable

A cozy game-night word game for 2–4 seats: hot-seat on one couch or live over WebSockets with room codes, bots, chat and emotes, timers with a stall guard, drop-resume, and a recap with word history plus one-click rematch.

**Why it exists:** game night needs a table that survives real life — players join from the couch or across the internet, a dropped connection resyncs instead of ruining the game, and a bot can fill an empty seat so play never stalls.

- [Features](#features) • [Requirements](#requirements) • [Quickstart](#quickstart) • [Usage](#usage) • [Configuration](#configuration) • [Testing](#testing) • [Limitations and roadmap](#limitations-and-roadmap) • [Architecture](#architecture) • [Docs](#docs)

> [!NOTE]
> The server and the game rules live in one Godot project: the same checkout runs headless as the WebSocket server or windowed as the graphical client.

## Features

- 2–4 seats per room (`MAX_SEATS := 4` in `scripts/server/rooms.gd`), addressed by 4-letter room codes (`CODE_LEN := 4`).
- Hot-seat play plus networked rooms: create → join → start → pass, with strict-token rejoin/resync after a drop.
- Room bots: the host seats `Botgomery` (`add_bot`), which commits one greedy-crossword move per turn and passes when it has none.
- Turn clocks with a stall guard: 90 s with the clock on, 180 s with it off, auto-pass on expiry.
- Lobby/table chat and emotes, private per-seat racks, word-history recap with rematch.
- Sound toggle (`Sound: On/Off`) persisted across runs.

## Requirements

- [Godot 4.7](https://godotengine.org/download/) (CI installs `4.7.2-stable`; `project.godot` targets the `4.7` feature set).
- Python 3 (stdlib only) for the `tests/ws_probe.py` driver — no pip packages needed.

## Quickstart

Clone and start the headless server (default `ws://localhost:9080`). In graphical runs the same project boots the Start screen instead (`scripts/client/boot.gd`).

```sh
git clone https://github.com/techafreshh/scrabble.git
cd scrabble
godot --headless --path .
```

> [!TIP]
> The server prints `Wordtable server listening on 9080` (`scripts/server/server.gd`). Keep it running and use a second terminal below.

Check the server answers, then run one full create → join → start → pass cycle:

```sh
python3 tests/ws_probe.py --ping
CREATE_OUT=$(python3 tests/ws_probe.py --create --name Host)
echo "$CREATE_OUT"   # prints code=XXXX and token=...
CODE=$(echo "$CREATE_OUT" | sed -n 's/^code=//p' | tr -d '\r\n ')
TOKEN=$(echo "$CREATE_OUT" | sed -n 's/^token=//p' | tr -d '\r\n ')
python3 tests/ws_probe.py --join "$CODE" --name Guest   # seats=2
python3 tests/ws_probe.py --start --code "$CODE" --token "$TOKEN"   # started=true
python3 tests/ws_probe.py --pass-turn --code "$CODE" --token "$TOKEN"
```

This is the same sequence the CI `gates` / `Probe dev server` job runs.

Play with the graphical client while the server is up:

```sh
godot --path .
```

Point a client at a non-default server without editing anything:

```sh
godot --path . -- --server-url=ws://localhost:9080
# or: WORDTABLE_SERVER_URL=ws://localhost:9080 godot --path .
```

## Usage

**Staging tiles.** Tap a rack tile, then tap a board square to stage it. `Play` commits the staged word (`thunk` on success; illegal words bounce back with `Not in my book: WORD`). `Recall` clears pending tiles, `Shuffle` reorders the rack, `Exchange` swaps tiles with the bag, `Pass` hands the turn over. Six successive scoreless turns end the game (`six_scoreless`, `SCORELESS_LIMIT := 6` in `scripts/game/game.gd`); emptying the bag ends it with unplayed-tile bonuses.

**Starting a room.** One client creates a room and becomes the host (seat 0); guests join with the 4-letter code. Play starts once at least 2 seats are filled — solo `start_game` is refused with `NEED_OPPONENT`. The host can seat a bot (`add_bot` → `Botgomery`, `is_bot: true`), remove one (`remove_bot`), and trigger a fresh deal after a finished game (`rematch`).

**Chat and emotes.** Lobby/table chat plus three emotes. Names truncate to 16 chars (`MAX_NAME_LEN := 16`) and chat/emote text to 200 chars (`MAX_TEXT_LEN := 200`), trimmed, never rejected (`scripts/server/game_binding.gd`).

**Sound and nickname.** The `Sound: On/Off` button mutes the thunk/fanfare and the Start screen remembers your nickname; both persist in `user://wordtable_settings.cfg` (`SETTINGS_PATH` in `scripts/client/sound_bank.gd` and `scripts/client/screens/start_screen.gd`).

**Timers.** Lobbies default to clocks on. When a started room's deadline passes, the server auto-passes the turn seat and broadcasts the result with `auto_pass: true`; every pass counts as scoreless.

**Reconnects.** Rejoin with the same `code` + `token` for a full-state resync snapshot (`board_tiles`, `started`, scores, your private rack). An unknown token is refused with `BAD_TOKEN` and never mints a seat.

## Configuration

| Knob | Where | Default | Effect |
|---|---|---|---|
| Server port | `--port=NNNN` CLI flag, else `PORT` env | `9080` (`DEFAULT_PORT` in `scripts/server/server.gd`) | TCP port the headless server listens on. Precedence: `--port=` > `PORT` > default. |
| Server URL | `--server-url=` CLI flag, else `WORDTABLE_SERVER_URL` env | `ws://localhost:9080` (`DEFAULT_URL` in `scripts/client/net_client.gd`) | Server the clients dial. Precedence: `--server-url=` > `WORDTABLE_SERVER_URL` > default. |
| `timer_on` / `timer_off` | room `options` (or top level) | on | Per-turn clock vs. the 180 s stall guard (`parse_timer_on` in `scripts/server/game_binding.gd`). |
| `turn_secs` (aliases: `timer_secs`, `turn_timeout`, `timeout_secs`, `turn_limit_secs`) | room `options` (or top level) | `90` clock on / `180` stall guard | Per-turn limit in seconds, clamped 1–3600 (`parse_turn_secs` / `turn_limit_secs` in `scripts/server/game_binding.gd`). |
| `test_mode` | room `options` at create | off | Enables host-only debug pins `debug_set_rack` / `debug_set_bag`; refused with `BAD_STATE` on live rooms (`scripts/server/rooms.gd`). |
| Lexicon | `dictionaries/sowpods.txt` (`DEFAULT_PATH` in `scripts/game/dictionary.gd`) | bundled | Word validation. If the file is missing the server still boots, but word checks are skipped. |

Deploying beyond localhost (systemd unit, `wss://` via Cloudflare Tunnel) is covered by [`docs/runbook.md`](docs/runbook.md); the full wire surface (envelope, method table, error codes) by [`docs/protocol.md`](docs/protocol.md).

## Testing

Full headless matrix (exits 0, prints `RESULT: PASS`):

```sh
godot --headless --path . --script res://tests/test_runner.gd
```

Single suite and the seeded bot-vs-bot soak (2 bots per game, `--games` default 20):

```sh
godot --headless --path . --script res://tests/test_runner.gd --suite polish
godot --headless --path . -s res://tests/bot_soak.gd --games 20
```

The soak exits 0 with `soak_games=20`, `soak_recaps=20`, `illegal_states=0`. The scripted network smoke (two clients, forced drop, full legit game) and the Web end-to-end (static serve, scripted play, tab-reload resume) run in CI:

```sh
python3 tests/ws_probe.py --smoke
godot --headless -s tests/net_smoke.gd
```

Look for `smoke_game_over=true`, `smoke_resync=true`, `illegal_states=0`.

## Limitations and roadmap

- **4 seats max.** Rooms hold at most 4 seats; extra joins are refused with `ROOM_FULL`. Larger tables are future work.
- **No solo games.** Starting with fewer than 2 seats fails with `NEED_OPPONENT` — invite a guest or seat `Botgomery` via `add_bot` first.
- **Debug pins are test-only.** `debug_set_rack` / `debug_set_bag` require rooms created with `test_mode: true` plus the host token.
- **Word checks need the bundled lexicon.** Without `dictionaries/sowpods.txt` the server boots but skips word validation; gameplay rules are still enforced.
- **Exports are single-threaded Web.** The Web preset pins `variant/thread_support=false` so the build runs on any static host without COOP/COEP headers; desktop presets cover Windows, Linux, and macOS.

## Architecture

```text
scripts/game/    rules, board, bag, dictionary, game state (six-scoreless, pass_turn)
scripts/server/  headless WebSocket server, room registry, game binding, bot seats
scripts/client/  autoload Net client, boot dispatcher, views (start/lobby/table/recap), sounds
scenes/          main.tscn plus start, lobby, table, and recap scenes
tests/           headless suites (test_runner.gd), bot soak, net smoke, ws_probe.py driver
docs/            protocol.md (wire surface), runbook.md (deployment)
dictionaries/   bundled SOWPODS word list
```

## Docs

- Wire protocol: [`docs/protocol.md`](docs/protocol.md)
- Deployment runbook (written, not executed): [`docs/runbook.md`](docs/runbook.md)

## Lexicon

Word checks use the bundled SOWPODS list at `dictionaries/sowpods.txt`; see [`dictionaries/LICENSE-credit.md`](dictionaries/LICENSE-credit.md) for the source and format credit.
