# PRD: Wordtable — Live Online Scrabble-Style Game

| Field | Value |
|-------|-------|
| Working title | Wordtable (mechanics = official Scrabble rules; neutral title because "Scrabble" is Hasbro/Mattel IP and the repo is meant to be shown publicly) |
| Status | Approved — companion design doc: `docs/superpowers/specs/2026-11-03-scrabble-multiplayer-design.md` |
| Date | 2026-11-03 |

## 1. Executive Summary

Wordtable is a live, online Scrabble-style game for small circles of friends. The owner creates a table and shares a code or link; friends are seated within a minute whether they're on a laptop or tapping the link on a phone. A full game takes 20–30 minutes with everyone online at once — this is deliberately not a Words-With-Friends-style multiple-days game.

The game implements full official Scrabble rules on the classic 15×15 board: the complete 100-tile bag with blanks, premium squares, 50-point bingo bonus, dictionary-validated words (SOWPODS bundled), and every official end-of-game condition including the six-successive-scoreless-turns rule. Word legality is decided only by the server, so nobody at the table can cheat.

It is built as a single Godot 4 (GDScript) codebase. A headless export of the same project acts as the authoritative game server; browser (WASM), desktop, and later phone builds are views over a WebSocket connection. Beyond being something friends actually play, it is designed as a coherent portfolio piece: one codebase, real-time networking, an authoritative dedicated server, and a word-AI bot. Cozy presentation — dark wood, green felt, ivory tiles ("Warm club") — with the board getting maximum screen space.

**MVP goal:** two humans and/or a bot can play a complete, correct, full-rules game live — join by code, chat, reconnect after dropping, see the recap, rematch — playable in the browser and on desktop from a single codebase.

## 2. Mission

**Mission:** make real Scrabble with your people as easy as sending a link.

**Core principles:**
1. **Zero friction to seated** — no accounts, no downloads (web), no setup; nickname + room code.
2. **The server is the referee** — clients render and propose; only the headless server owns bag, racks, board, scores, and validation.
3. **Rules are real** — full official rules, decided in code and covered by headless tests, not approximated.
4. **One codebase, many tables** — browser, desktop (and later phones) from the same GDScript project.
5. **Game night, not a tournament app** — warm, playful, forgiving; timers protect the table, and nobody polices anything.

## 3. Target Users

**The Host (primary)** — the owner and their game-hosting friends. Semi-technical: comfortable clicking a link, sharing a link, and (much later) running a deploy runbook. Needs: create a table instantly, fill an empty seat with a bot, keep the game moving.

**The Friend (primary)** — non-technical, often on a phone, arrives from a group-chat link. Comfort level: low; patience for a ~30–50 MB first web load, none for signups. Needs: land seated, drag or tap tiles, never feel stupid by the UI.

**The Returning Player** — someone whose browser tab napped or whose train went through a tunnel. Needs: reopen the link, be back at the table with score intact, nobody waiting on them forever.

**The Builder (secondary)** — the owner learning Godot and growing a portfolio. Needs: readable Godot-idiomatic code, mainstream patterns, milestones that leave something playable early.

Pain points addressed: scheduling full-rules Scrabble with friends spread across devices; janky web clones with honor-system words; multiplayer apps that die when one person's tab sleeps.

## 4. MVP Scope

### In Scope
**Core functionality**
- [ ] Live-session multiplayer, 2–4 players per table (humans + bots mixed), join via 4–6 char room code or link
- [ ] Full official rules: 15×15 classic premium layout, 100-tile bag, 7-tile racks, blanks (letter picked at placement), 50-pt bingo, exchange (bag ≥ 7), all official end-game/final scoring, six-successive-scoreless-turns ending
- [ ] Server-side SOWPODS validation; invalid plays rejected at commit with friendly inline message; no challenge rule
- [ ] Server-authoritative play; reconnect-and-resync for dropped players (browser tab-suspend is an expected case)
- [ ] Turn timer: 90 s default with auto-pass, host-toggleable at table creation; 3-minute stall-guard auto-pass for disconnected players even when the timer is off; every pass counts as scoreless
- [ ] Bot player fills any empty seat (one "reasonable" difficulty: near-greedy best move with jitter, 5–15 s think time)
- [ ] In-game text chat + one-tap emotes
- [ ] End-of-game recap (podium, final scores, complete word history) + one-click rematch with same seats
- [ ] Audio: subtle tile thunk/fanfares + mute toggle

**UX / presentation**
- [ ] "Big board" layout: score strip on top, board center, rack + Recall/Shuffle/Play below, chat as corner bubble
- [ ] "Warm club" style: dark wood, green felt board, ivory tiles, brass accents
- [ ] Drag & drop placement (mouse + touch) with tap-then-tap fallback; live provisional score while pending tiles are arranged
- [ ] Start screen (nickname, remembered per device), lobby with seat plaques, responsive touch-first table for phone browsers

**Technical / packaging**
- [ ] Headless dedicated-server export; cleanup of visuals for server builds
- [ ] Browser (WASM, single-threaded) + Windows/Mac/Linux desktop exports from one project
- [ ] SOWPODS word list bundled with visible credit in a pluggable one-word-per-line file format
- [ ] Local game runs against `ws://localhost` server for dev/testing
- [ ] **CI workflow as a first-lap deliverable**: `.github/workflows/ci.yml` that installs Godot 4.7.x headless and runs the repo's headless test suites (`tests/test_runner.gd`, later `tests/net_smoke.gd` + `tests/bot_soak.gd`) — the process exit code is the gate
- [ ] Deployment runbook (systemd unit, Cloudflare Tunnel, domain checklist) — written, not executed

### Out of Scope (deferred)
- [ ] Accounts, profiles, persistent stats/screenshots, friends lists
- [ ] Play-over-days correspondence mode, notifications
- [ ] Spectator mode, public matchmaking, tournaments
- [ ] Challenge rule (scored challenges, penalty variants)
- [ ] Move undo after commit
- [ ] Second lexicon + room-creation lexicon picker (loader is ready; ships when a second list is licensed/sourced)
- [ ] Android APK (immediately post-MVP), iOS App Store (later, $99/yr program)
- [ ] Executed deployment to VPS + domain registration (follow-up session; runbook prepared)
- [ ] Cross-device saved games

## 5. User Stories

1. As a **host**, I want to create a table and share a code or link, so that friends can join from wherever they are in under a minute. *Example: I tap "Create table" on my laptop, see SCRAB-4Z2P, paste the link into the group chat.*
2. As a **friend on a phone**, I want to open the link, type a nickname, and be seated without installing anything, so that I can play from the couch. *Example: link opens in mobile Safari, I type "Mira", I'm in the lobby.*
3. As a **player**, I want to drag tiles onto the board and see the provisional score before committing, so that I can plan risky moves. *Example: I arrange QUARTZ on a triple word, see "+38", then hit Play.*
4. As a **player**, I want fake words bounced back with a wink, so that the rules stay honest without embarrassment. *Example: "Not in my book: QUARTZIES" — tiles return to my rack.*
5. As a **player whose connection dropped**, I want to reopen the link and resume exactly where I was, so that a dead zone costs me nothing. *Example: tunnel kills my train Wi-Fi; back online, my rack, score, and pending placement are intact.*
6. As a **host with two friends**, I want to drop a bot into the third seat so we can still play at a full table. *Example: lobby shows an empty seat; one tap makes it "Botgomery".*
7. As a **player waiting on someone**, I want turns to auto-pass (and the six-scoreless rule to end comatose games), so that nobody stalls the table. *Example: a friend goes offline for good; after the guard timer and scoreless turns, the recap crowns someone.*
8. As a **host who just won**, I want a recap of every word played and a one-tap rematch, so that the table can roll straight into game two.
9. **(Technical)** As the builder, I want the rules engine to be pure, headless-testable GDScript, so that every official rule is verified without a renderer and reused identically by server and client (provisional scoring).
10. **(Technical)** As the builder, I want clients to hold no trusted state, so that a hacked client can't cheat and a reconnecting client just re-syncs.

## 6. Core Architecture & Patterns

**High-level approach:** one Godot 4 project, three run-modes from the same codebase.

```
Wordtable project (GDScript)
├── client (any export target)      ← renders board, sends intents
├── headless dedicated server       ← owns ALL game state, arbitrates
└── local "hot-seat" dev mode       ← UI testable without networking
```

**Key architecture points:**
- **Authoritative server:** a headless export runs an autoload server harness (rooms registry, sessions, timers). Clients connect via `WebSocketMultiplayerPeer`; high-level multiplayer API carries typed RPCs (client→server: intents; server→clients: state deltas).
- **Pure logic core, scene-independent:** bag, board (15×15 premium constants), racks, move validation, scoring, turn state machine — plain GDScript classes with zero scene/visual deps. The server uses them authoritatively; the client reuses the same validator for instant provisional scores; headless unit tests run them directly.
- **Clients are views:** on connect (or reconnect) the client receives a full state sync; afterwards only deltas. Client never trusts its own validation — a rejected play reverts pending tiles.
- **Protocol sketch:** `create_room / join_room(code) / take_seat / add_bot / start_game`, in-game `place_tiles(pendings) / recall / shuffle_rack / exchange / pass / chat / emote`, server→all `state_sync / seat_update / turn_update(commit result) / game_over(recap)`. Reconnect = same code + per-player session token (persisted in the client's local storage).
- **Directory sketch:**
```
project.godot
scripts/game/      # pure rules: bag.gd, board.gd, rack.gd, rules.gd, dictionary.gd, game.gd
scripts/server/    # server.gd autoload, rooms.gd, bot.gd
scripts/client/    # net_client.gd autoload, ui controllers
scenes/            # start, lobby, table, themes, tiles
dictionaries/      # sowpods.txt (+ LICENSE-credit.md)
tests/             # headless test runner + rule/bot suites
assets/            # wood/felt art, sounds, fonts
```

## 7. Tools / Features (feature spec)

- **Start screen:** nickname field (remembered locally); Create table / Join by code or pasted link.
- **Lobby:** wooden seat plaques per seat; host can toggle a bot into any empty seat; timer on/off; Start enabled with ≥1 opponent; room code + copy link always visible.
- **Table screen:** top player strip (avatar dot, name, score, tile count, active-player warm glow + timer ring); center felt board; bottom rack ledge with 7 ivory tiles; Recall / Shuffle / brass **Play word**; corner chat bubble (unread count) opening a panel with input + emote row (👍😂😭).
- **Placement:** drag & drop from rack to board (Godot drag-and-drop Control API) with tap-tile→tap-square fallback for touch; pending tiles raised with soft outline; provisional +score computed by the shared validator as tiles are arranged; blanks open a letter-picker popup.
- **Commit & feedback:** Play word → server verdict: legal commit (thunk, score flies) or reject (tiles bounce back, inline message).
- **Timers:** server clock; per-turn 90 s ring on active player; expiry auto-pass; 3-min stall guard for disconnected players when timer is off; six consecutive scoreless turns end the game.
- **Recap overlay:** podium, final scores, scrollable word history (word · position · points · player), **Rematch** (same seats, fresh bag/board).
- **Connection:** "Reconnecting…" overlay with auto-retry + manual retry; full resync on success; session token so refreshes/reopens rejoin the same game.
- **Sound & mute:** subtle thunk/fanfare/early-bag sounds with a persistent mute toggle.

## 8. Technology Stack

| Layer | Choice | Notes |
|-------|--------|-------|
| Engine / language | **Godot 4.x, GDScript** | Compatibility renderer (only option for web); C# explicitly avoided (no web export) |
| Transport | `WebSocketMultiplayerPeer` + high-level multiplayer API | Works on native + web targets; ENet/UDP impossible in browsers |
| Server | Headless Godot export (`dedicated_server` feature tag) | systemd + Cloudflare Tunnel noted in runbook (execution deferred) |
| Data | SOWPODS text file (~270k words), UTF-8, one word/line | Loaded into an in-memory set at startup; pluggable path |
| Client persistence | Local storage (nickname, session token, mute) | IndexedDB-backed on web |
| Testing | Headless test-runner script (`godot --headless -s tests/run_tests.gd`) | Unit suites for rules/dictionary/bot; scripted 2-instance network smoke test |
| Exports | Web (single-threaded, Brotli-compressed), Windows/Mac/Linux desktop | Android preset prepared post-MVP |
| Third-party services | None | No accounts, no backend services, no analytics |

## 9. Security & Configuration

- **AuthN/AuthZ:** none in the account sense. Identity = nickname + per-player session token scoped to a room. Reconnect requires the token (stored per device), preventing bystanders from hijacking a seat by code alone.
- **Anti-cheat:** server-authoritative — racks, bag, and validation exist only server-side; clients receive only what a player may see (their own rack during play).
- **Configuration:** server: listen port, lexicon path, default turn length, stall guard, log level (CLI args or env, `--headless`-safe). Client: server URL (localhost default; production override baked at export), nickname, mute.
- **Security scope — in:** token-scoped rejoin, server-only state, sane input limits (nickname/chat length caps, room-code rate limiting kept minimal). **Out of scope:** DDoS defense, moderation tooling, encryption beyond TLS-terminated Cloudflare, persistent PII (none is stored; games die with the process).
- **Deployment (deferred):** runbook covers systemd hardening (auto-restart, journald logging with `flush_stdout_on_print`), Cloudflare Tunnel for public `wss://` without open ports, domain registration note (~$10/yr, Cloudflare free tier).

## 10. API Specification (WebSocket RPC summary)

Channel: Godot high-level multiplayer RPCs over a single `WebSocketMultiplayerPeer` connection. JSON-serializable args; versioned by a `v` field for forward safety.

| Message | Direction | Payload (abridged) | Response |
|---------|-----------|--------------------|----------|
| `create_room` | C→S | `{v, name, options{timer_on}}` | `{ok, code, player_id, token}` |
| `join_room` | C→S | `{v, code, name, token?}` | `{ok, seats[], you{seat}, state_sync?}` |
| `add_bot / remove_bot / start_game` | C→S | host only | broadcast `seat_update` / `state_sync` |
| `place_tiles` | C→S | `{v, tiles:[{square, letter, is_blank, blank_as?}]}` | broadcast `turn_update{accepted, commit\|reject, reason?}` |
| `recall / shuffle_rack` | C→S | `{v}` | `state_sync` (own rack/board pendings) |
| `exchange / pass` | C→S | `{v, discard?:[letters]}` | `turn_update` |
| `chat / emote` | C→S | `{v, text}` / `{v, emote_id}` | broadcast `chat{from, text, ts}` |
| `turn_update` | S→C | `{turn, active, scores[], timer_deadline, last_move{word, squares, points}}` | — |
| `game_over` | S→C | `{reason, final_scores[], history[], ender_bonus_rows[]}` | — |

Example — commit: `{"v":1,"m":"place_tiles","tiles":[{"square":"5F","letter":"Z","is_blank":false}, …]}` → `{"m":"turn_update","accepted":true,"commit":{"word":"QUARTZ","points":38,"player":"Mira"}}`. Full field-level spec is the builder's M3 deliverable, guided by this table.

## 11. Success Criteria

**MVP definition:** a complete full-rules game — 2 humans + 1 bot — played live, one participant in the browser, one on desktop, with one mid-game tab-suspend recovery, ending in a correct recap and a played rematch.

**Functional (must all hold):**
- [ ] Friend-on-phone: link → seated in < 60 s on first load; no install, no account
- [ ] Every official rule verified by headless tests (bag distribution, premiums, blanks, bingo, exchange, endings, final scoring incl. unplayed-tile bonuses)
- [ ] 0 illegal board states across seeded bot-vs-bot soak (best-of N games)
- [ ] Disconnect at any point → reopen → resumed state byte-identical to server truth
- [ ] No game can stall: timer auto-pass, stall guard, and six-scoreless ending all fire in tests
- [ ] Invalid words always rejected with the tiles-back behavior clients can't bypass
- [ ] Web + desktop exports from the same project; web first load ≤ ~50 MB compressed

**Quality indicators:** review verdict on code clarity for a Godot newcomer (goal from brainstorm); ServerFrame per move < 50 ms in GDScript; reconnect < 3 s on localhost.

**UX goals:** the table *feels* like game night (Warm club held everywhere — lobby, table, recap); provisional scoring keeps planning playful; rejection copy stays kind.

## 12. Implementation Phases

| Phase | Goal | Deliverables | Validation | Est. |
|-------|------|--------------|------------|------|
| **P1 — Rules core** | Pure GDScript engine, fully tested headless | `bag/board/rack/rules/dictionary/game`; SOWPODS fetched + credited; test runner | All rule unit suites green (`godot --headless`); dictionary load < 3 s | 3–4 d |
| **P2 — Table UI** | Playable local table, Warm club, touch-first | Theme; board/rack/tile scenes; drag+tap placement; provisional score; lobby/start/recap; hot-seat dev mode; chat UI; sounds | Full hot-seat game on desktop window + phone-sized viewport; interaction tests via scripted input | 5–6 d |
| **P3 — Networking** | Live online tables with reconnect | Server harness + rooms + sessions; client Net; RPC set per §10; timers/auto-pass/stall guard; reconnect overlay | Localhost: headless server + 2 clients + forced disconnect/resume; full legit game | 5–6 d |
| **P4 — Bot** | Bot fills any seat | Server-side bot: crossword-aware move gen (blanks included), jitter, think delay | Seeded bot-vs-bot soak green; game completes solo | 2–3 d |
| **P5 — Exports & polish** | MVP shippable from one repo | Web + Windows/Linux (+Mac) exports; sizes checked; presentation polish; **deployment runbook (drafted)** | Web export runs against local server; desktop drag-drop; recap/rematch loop verified | 3–4 d |

Total: ~2–4 weeks focused effort (agreed scale). Order is deliberate: something playable exists from P2 onward, and every later phase rides on a tested core.

### Build order — task-level (the slicing source; mirrors `.agents/plans/wordtable-multiplayer.plan.md`)

This PRD is delivered through the pi-dark-factory: each numbered task below becomes ~one GitHub issue, in this order. Task IDs are stable identifiers; acceptance for each is its validation command in the referenced plan.

- **T0** Install/pin Godot 4.7.x headless binary; `godot --headless --version` gates.
- **T1** Godot project scaffold (Compatibility renderer, dirs per §6, `.gitignore`); `--import` exits 0.
- **T2** Headless test runner (`tests/test_runner.gd`, SceneTree script, exit-code gate) + sample suites.
- **T3** Tile bag (official 100-tile distribution, blanks, seeded shuffle, draw/return) + suite.
- **T4** Board model + official premium layout Resource (star at H8; "5F"↔rc algebra; word extraction) + suite.
- **T5** Dictionary module + fetch/credit/cleanup SOWPODS (~267k words, <3 s load).
- **T6** Move validation + scoring (first-move rules, line/adjacency rules, premiums, blanks=0, bingo, per-failure reason classes) + hand-verified gold corpus suite.
- **T7** Game state machine (turns, exchange ≥7 bag, pass, six-scoreless ending, bag-empty ending, tournament final scoring, rematch reset) + three full scripted games in tests.
- **T8** Game facade `LocalGame` (intents → events seam shared by server, client, bot) + scripted 3-player game.
- **T9** Warm-club theme + art tokens (Theme/StyleBox Resources, flat-color placeholders).
- **T10** Board scene (15×15 Control grid, pending-tile states, last-move highlight, responsive/phone scaling).
- **T11** Rack + placement (drag & drop + tap-tap fallback, Recall/Shuffle, live provisional score via shared validator).
- **T12** Blank letter-picker; commit thunk + score-fly; reject bounce-back + inline message.
- **T13** Player strip (active glow + timer ring), chat bubble + emotes (local echo), sounds + mute.
- **T14** Start / lobby / recap screens + full hot-seat playable loop (end-to-end on desktop + phone viewport).
- **T15** Server harness: headless boot, `WebSocketMultiplayerPeer` listener, rooms, session tokens, versioned RPC surface (§10).
- **T16** Server–Game binding: intents→facade, per-peer private state, timers (90 s default, 3-min stall guard), auto-pass, scoreless counting.
- **T17** Client Net autoload: connect/join, full `state_sync` + deltas into the same event bus P2's UI consumes.
- **T18** Reconnect UX: overlay, auto-retry backoff, token rejoin, web-refresh resume.
- **T19** Network smoke suite: headless server + 2 scripted clients, forced disconnect/resume, full legit game.
- **T20** Bot move generator (anchors, dictionary-directed search, wildcards, ~300 ms budget, jitter, think delay) + tests.
- **T21** Bot in rooms + seeded bot-vs-bot soak (≥20 games, 0 illegal states).
- **T22** Exports: Web (single-threaded) + Windows/Linux presets, icons/splash, lexicon ships in PCK, size budget.
- **T23** Web end-to-end: local static serving + local server, scripted browser play, tab-reload resume.
- **T24** Game-feel polish sweep; deployment runbook drafted (systemd + Cloudflare Tunnel, NOT executed); portfolio README + `v0.1.0-mvp` tag.

Operator-only steps (never issues: laps cannot do them) are tracked in the deployment runbook checklist: domain registration, Cloudflare/Tunnel bring-up, VPS systemd install, mobile store packaging.

## 13. Future Considerations

- Android APK (near-term, same codebase) → iOS App Store later
- Executed deployment: domain + Cloudflare Tunnel + systemd (runbook ready)
- Second lexicon (NWL if ever licensed, or free alternatives) → re-enables the host-side lexicon picker
- Accounts-lite: optional profiles, win/loss history, rematch-with-the-same-people shortcuts
- Play-over-days mode (server-side persistence) and notifications
- Spectator seats, tournaments, higher difficulties / persona bots ("Botgomery: aggressive bingo hunter")
- Glossaries per language (FISE Spanish etc.) via the same pluggable loader

## 14. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Web export weight/decision quirks (Safari WebGL2, ~30–50 MB load) | Friend-on-phone bounce-off | Single-threaded build + Brotli; test mobile Safari early in P5; desktop export is the guaranteed fallback |
| Browsers suspend tabs → mid-game disconnects | Games die, friends frustrated | Reconnect-first architecture (server owns state, token rejoin, full resync); treated as a first-class feature (P3), and six-scoreless ending bounds worst case |
| GDScript bot performance (16M-position board space) | Slow/hang turns | Time-budgeted greedy generator with pruning (anchors,rack sampling); seeded soak tests in CI-style headless runs; bot is P4 so perf measured before polish |
| Word-list redistribution legality (NWL proprietary) | Legal/portfolio exposure | Ship SOWPODS + credit only; pluggable loader; repo stays shareable |
| Godot-version drift / install friction for the builder | Blocked validation early | Pin exact Godot version in docs; headless test runner minimized to not depend on editor add-ons |

## 15. Appendix

- **Approved design doc:** `docs/superpowers/specs/2026-11-03-scrabble-multiplayer-design.md` (decisions log: approaches A/B/C, user behavior calls ①–④, builder-check resolutions)
- **Mockups:** `.superpowers/brainstorm/…/content/` (layout options, three Warm-club-style candidates — Big-board + Warm club selected)
- **Key external refs:** Godot docs — WebSocket multiplayer, Exporting for web (single-threaded, COOP/COEP only if threads), Exporting for dedicated servers; SOWPODS distributable copies (credit required)
- **Repo layout:** see §6 directory sketch; design doc + PRD under version control from day one
