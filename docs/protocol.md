# Wordtable wire protocol (§10 reference)

Headless server: `ws://localhost:9080`. Transport is raw WebSocket text
frames; each frame carries exactly one JSON object, UTF-8 encoded. The
stdlib-only driver `tests/ws_probe.py` speaks exactly this surface.

## Envelope rules

- Client → server objects carry `v: 1` (protocol version) and `m: <method>`.
  `version` is accepted as an alias of `v`, `method` as an alias of `m`.
- Every server reply carries `m` (echoing the request's method string) and
  `ok: true|false`. Error replies carry `error: <CODE>` plus a `reason`
  alias with the same value.
- The first frame sent back for a request is always the reply; any later
  frames for the same request are broadcasts fanned out to every open
  socket mapped to that room code (see Broadcasts).
- The bare text frame `ping` (any case/whitespace) still answers `PONG`
  and never touches the RPC layer. Non-JSON, non-ping text is ignored.
- Field names not listed here are ignored; unknown methods, bad versions,
  and unparseable `{`-frames get error replies, never a dropped connection.
- Names truncate to 16 chars, chat/emote text truncates to 200 chars
  (both trimmed; over-long input is shortened, never rejected).

## Methods

| `m` | Needs | Effect | Reply (`ok: true`) |
|---|---|---|---|
| `create_room` | `name` | New room, caller is seat 0 (host) | `code`, `token`, `seat: 0`, `seats: 1` |
| `join_room` | `code`, `name`, optional `token` | Known `token` re-seats (rejoin); otherwise a fresh seat | `code`, `token`, `seat`/`you`, `seats` |
| `rejoin` (`resync`) | `code`+`token` | Strict token rejoin: unknown `token` answers `BAD_TOKEN` and never mints a seat | full snapshot: `seat`/`you`, `started`, `turn`, `scores`, own `rack`, `board_tiles`, `over`, `ending`, `seats_list` |
| `add_bot` | host `code`+`token` | Seats the `Botgomery` stub (never moves) | `bot_seat`, `seats` |
| `remove_bot` | host `code`+`token`, optional `seat` | Removes one bot seat (default: last) | `seats` |
| `start_game` | host `code`+`token` | Builds one `LocalGame` for the seats | `started: true`, `turn`, `scores` |
| `place_tiles` (`place`) | turn seat's `code`+`token`, `tiles` | Facade `place` (active seat only); `tiles: [{square: "H8", letter: "Q", blank_as: ""}]` (`{col,row,letter,blank}` dicts also accepted) | `accepted: true`, `points` (= `total`), `turn`, `scores`, `over` |
| `pass` (`pass_turn`) | turn seat's `code`+`token` | Facade `pass_turn` | `accepted: true`, `turn` |
| `exchange` | turn seat's `code`+`token`, `count` | Facade `exchange` | `accepted: true`, `turn` |
| `recall` | turn seat's `code`+`token` | Facade `recall` (clears pending) | `recalled`, `rack`, `turn` |
| `shuffle_rack` (`shuffle`) | turn seat's `code`+`token` | Facade `shuffle` | `rack`, `turn` |
| `get_rack` (`rack`) | `code`+`token` (any seat) | This seat's private rack (reply only, never broadcast) | `rack`, `seat`/`you`, `turn` |
| `debug_set_rack` | host `code`+`token`, `seat`, `tiles` | Pin one seat's rack (test rooms only) | `seat`, `rack` |
| `debug_set_bag` | host `code`+`token`, `tiles` | Replace the bag (test rooms only) | `bag_remaining` |
| `chat` | `code`+`token`, `text` | Lobby/table chat | `chat_ok: true`, `from`, `text`, `ts` |
| `emote` | `code`+`token`, `text` | Chat-kind emote | `emote_ok: true`, `from`, `text`, `ts` |

Aliases accepted for inputs: `code`/`room`/`room_code` (case-insensitive,
whitespace trimmed, stored uppercase); `token`/`session`/`session_token`;
`name`/`player`/`player_name`; `tiles`/`placements`. Squares parse as
`H8` or `8H` (letter A-O = column, number 1-15 = row, either order).

Rooms hold at most 4 seats. `timer_on` is accepted inside `options` (or
top level) and defaults to true; `timer_off: true` negates it. The
per-turn limit resolves from the first present key among `turn_secs`,
`timer_secs`, `turn_timeout`, `timeout_secs`, `turn_limit_secs` (top level
or inside `options`), clamped 1–3600 — else 90 s with the clock on, else
the 180 s stall guard with it off. The deadline refreshes on `start_game`
and after every successful `place_tiles`/`pass_turn`/`exchange`/auto-pass.
When a started, non-over room's deadline passes, the server auto-passes
the turn seat (facade `recall` then `pass_turn`) and broadcasts the
resulting `turn_update`/`game_over` with `auto_pass: true`; every pass —
manual or automatic — counts as scoreless toward the six-scoreless
ending. Only the seat holding the turn may submit `place_tiles`,
`pass`, `exchange`, `recall`, or `shuffle_rack`; any other seated token
gets `NOT_YOUR_TURN` (`accepted: false` where that field applies).
`get_rack`, `chat`, and `emote` stay ungated. Gameplay rejects spell the
lexicon failure `NOT_IN_LEXICON` at the room boundary (the rules/facade
`NOT_IN_DICTIONARY` spelling is unchanged underneath). `place_tiles`
success replies carry both `points` (= `total`) and `total`; rejects
carry `accepted: false`, `points: 0`, the mapped `reason`, and the
preserved `reason_word`. The `add_bot` seat is a stub and never acts;
`debug_set_rack`/`debug_set_bag` need `options.test_mode: true` plus the
host token and are refused with `BAD_STATE` otherwise.

## Broadcasts

`room_created`, `room_joined`, `seat_update`, `state_sync`,
`turn_update`/`game_over` (the facade `delta` with the room `code`
attached), `chat`. Each carries `code` and the fields its name implies
(`seats`/`seats_list`, `turn`/`scores`, `from`/`text`/`ts`).
Broadcasts fan out to every open socket mapped to the room code — the
requestor's socket is mapped from its request (falling back to the
reply's `code`/`token`, so `create_room` maps too) — and each copy is
personalized per recipient seat: the recipient's own `rack` plus a `you`
marker, with `seat` filled in only when the frame has none (sender-seat
fields such as chat's are never clobbered). Single-frame replies
(`get_rack`, the debug pins) go to the requestor only, so racks stay
private to their owners.

## Error codes

`NO_ROOM` (unknown code), `ROOM_FULL` (4 seats taken), `NOT_HOST`
(host-only action by a guest token), `NO_TOKEN` (token is not a seat),
`BAD_TOKEN` (rejoin with an unknown `token`),
`BAD_STATE` (e.g. double `start_game`, fresh join after start, move
before start, debug pins on a live room), `NOT_YOUR_TURN` (intent from a
seat that does not hold the turn), `NEED_OPPONENT` (solo `start_game`), `BAD_JSON`
(`{`-frame that does not parse), `BAD_VERSION` (`v != 1`), and
`UNKNOWN_MESSAGE`. Gameplay rejects echo facade reasons
(`PENDING_NOT_EMPTY`, `BAG_TOO_SMALL`, `GAME_OVER`, …) mapped through
the room boundary (`NOT_IN_DICTIONARY` → `NOT_IN_LEXICON`), and
malformed move/chat input yields `BAD_TILES`/`BAD_TEXT`.

## Transcript (create → join → start → pass)

```
C: {"v":1,"m":"create_room","name":"Host"}
S: {"m":"create_room","ok":true,"code":"KQ7M","token":"9f2c…","seat":0,"seats":1}
S: {"m":"room_created","code":"KQ7M","seat":0,"seats":1}

C: {"v":1,"m":"join_room","code":"kq7m","name":"Guest"}
S: {"m":"join_room","ok":true,"code":"KQ7M","token":"41ab…","seat":1,"you":1,"seats":2}
S: {"m":"room_joined","code":"KQ7M","seat":1,"name":"Guest","seats":2}
S: {"m":"seat_update","code":"KQ7M","seats":2,…}

C: {"v":1,"m":"start_game","code":"KQ7M","token":"9f2c…"}
S: {"m":"start_game","ok":true,"started":true,"turn":0,"seats":2,"scores":[0,0],…}
S: {"m":"state_sync","code":"KQ7M","seats":2,"started":true,"turn":0,…}

C: {"v":1,"m":"pass","code":"KQ7M","token":"9f2c…"}
S: {"m":"pass","ok":true,"accepted":true,"turn":1,"scores":[0,0],…}
S: {"m":"turn_update","code":"KQ7M","turn":1,"scores":[0,0],"over":false,…}

C: {"v":1,"m":"join_room","code":"ZZZZ","name":"X"}
S: {"m":"join_room","ok":false,"error":"NO_ROOM","reason":"NO_ROOM"}
```

Equivalent probe session:

```
$ python3 tests/ws_probe.py --create --name Host
code=KQ7M
token=9f2c…
seats=1
$ python3 tests/ws_probe.py --join KQ7M --name Guest
seats=2
you=1
token=41ab…
$ python3 tests/ws_probe.py --join ZZZZ --name X
error=NO_ROOM        # exit 1
```
