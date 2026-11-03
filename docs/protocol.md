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
  frames for the same request are broadcasts (same connection only — the
  server does not yet fan out to other seats' sockets).
- The bare text frame `ping` (any case/whitespace) still answers `PONG`
  and never touches the RPC layer. Non-JSON, non-ping text is ignored.
- Field names not listed here are ignored; unknown methods, bad versions,
  and unparseable `{`-frames get error replies, never a dropped connection.

## Methods

| `m` | Needs | Effect | Reply (`ok: true`) |
|---|---|---|---|
| `create_room` | `name` | New room, caller is seat 0 (host) | `code`, `token`, `seat: 0`, `seats: 1` |
| `join_room` | `code`, `name`, optional `token` | Known `token` re-seats (rejoin); otherwise a fresh seat | `code`, `token`, `seat`/`you`, `seats` |
| `add_bot` | host `code`+`token` | Seats the `Botgomery` stub (never moves) | `bot_seat`, `seats` |
| `remove_bot` | host `code`+`token`, optional `seat` | Removes one bot seat (default: last) | `seats` |
| `start_game` | host `code`+`token` | Builds one `LocalGame` for the seats | `started: true`, `turn`, `scores` |
| `place_tiles` (`place`) | `code`+`token`, `tiles` | Facade `place`; `tiles: [{square: "H8", letter: "Q", blank_as: ""}]` (`{col,row,letter,blank}` dicts also accepted) | `total`, `turn`, `scores`, `over` |
| `pass` (`pass_turn`) | `code`+`token` | Facade `pass_turn` | `accepted: true`, `turn` |
| `exchange` | `code`+`token`, `count` | Facade `exchange` | `accepted: true`, `turn` |
| `recall` | `code`+`token` | Facade `recall` (clears pending) | `recalled`, `rack`, `turn` |
| `shuffle_rack` (`shuffle`) | `code`+`token` | Facade `shuffle` | `rack`, `turn` |
| `chat` | `code`+`token`, `text` | Lobby/table chat | `chat_ok: true`, `from`, `text`, `ts` |
| `emote` | `code`+`token`, `text` | Chat-kind emote | `emote_ok: true`, `from`, `text`, `ts` |

Aliases accepted for inputs: `code`/`room`/`room_code` (case-insensitive,
whitespace trimmed, stored uppercase); `token`/`session`/`session_token`;
`name`/`player`/`player_name`; `tiles`/`placements`. Squares parse as
`H8` or `8H` (letter A-O = column, number 1-15 = row, either order).

Rooms hold at most 4 seats. `timer_on` is accepted inside `options` (or
top level) and stored, but no timers are enforced in this lap. Any seated
token may submit intents for the current player; seat==turn gating is a
later lap. The `add_bot` seat is a stub and never acts.

## Broadcasts

`room_created`, `room_joined`, `seat_update`, `state_sync`,
`turn_update`/`game_over` (the facade `delta` with the room `code`
attached), `chat`. Each carries `code` and the fields its name implies
(`seats`/`seats_list`, `turn`/`scores`, `from`/`text`/`ts`).

## Error codes

`NO_ROOM` (unknown code), `ROOM_FULL` (4 seats taken), `NOT_HOST`
(host-only action by a guest token), `NO_TOKEN` (token is not a seat),
`BAD_STATE` (e.g. double `start_game`, fresh join after start, move
before start), `NEED_OPPONENT` (solo `start_game`), `BAD_JSON`
(`{`-frame that does not parse), `BAD_VERSION` (`v != 1`), and
`UNKNOWN_MESSAGE`. Gameplay rejects echo facade reasons (`NOT_IN_DICTIONARY`,
`PENDING_NOT_EMPTY`, `BAG_TOO_SMALL`, `GAME_OVER`, …), and malformed
move/chat input yields `BAD_TILES`/`BAD_TEXT`.

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
