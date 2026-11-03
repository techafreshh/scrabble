# Wordtable

A cozy game-night word game for 2–4 seats: hot-seat on one couch or live
over WebSockets with room codes, bots, chat and emotes, timers with a
stall guard, drop-resume, and a recap with word history plus one-click
rematch.

## Controls

- **Rack / board**: tap a rack tile, then tap a board square to stage it.
  `Play` commits the staged word (`thunk` on success, bounce-back with
  `Not in my book: WORD` on a reject).
- **Recall / Shuffle / Exchange / Pass**: staging and turn tools on the
  table; passing six times in a row ends the game scoreless.
- **Chat**: lobby/table chat plus three emotes (👍 😂 😭).
- **Sound**: the `Sound: On/Off` button mutes the thunk/fanfare; the
  choice persists across runs.

## Quickstart

Headless server (default `ws://localhost:9080`):

```
godot --headless --path .
```

Scripted probe against the running server:

```
python3 tests/ws_probe.py --create --name Host
python3 tests/ws_probe.py --join <CODE> --name Guest
python3 tests/ws_probe.py --start --code <CODE> --token <HOST_TOKEN>
python3 tests/ws_probe.py --smoke
```

Full headless test matrix (exits 0, prints `RESULT: PASS`):

```
godot --headless --path . -s tests/test_runner.gd
```

Single suites and the bot soak:

```
godot --headless --path . -s tests/test_runner.gd --suite polish
godot --headless --path . -s res://tests/bot_soak.gd --games 20
```

## Docs

- Wire protocol: [`docs/protocol.md`](docs/protocol.md)
- Deployment runbook (written, not executed):
  [`docs/runbook.md`](docs/runbook.md)

## Lexicon

Word checks use the bundled SOWPODS list at `dictionaries/sowpods.txt`;
see [`dictionaries/LICENSE-credit.md`](dictionaries/LICENSE-credit.md) for
the source and format credit.
