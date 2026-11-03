# Plan: Wordtable — Live Online Scrabble-Style Game (MVP)

## Summary

Implement the approved design (`docs/superpowers/specs/2026-11-03-scrabble-multiplayer-design.md`) and PRD (`.agents/PRDs/PRD.md`): a server-authoritative, live multiplayer Scrabble-style game in one Godot 4.7 (GDScript) codebase. The build goes bottom-up: a pure, headless-tested rules core (P1), a Warm-club touch-first table UI proven via a local hot-seat driver (P2), WebSocket networking with rooms/reconnect against a headless dedicated server (P3), a dictionary-driven bot on the server (P4), and web/desktop exports plus a drafted-not-executed deployment runbook (P5). The repo is greenfield — every pattern below is either defined here or sourced from the project's installed Godot skills; the client reuses the same rules core for provisional scoring, which is the central code-reuse bet of this plan.

## User Story

As a **friend joining from a shared link**, I want to be seated at a full-rules Scrabble table in under a minute — drag tiles, see provisional scores, chat, reconnect after dropping — so that we can play real Scrabble together from any device, and the server keeps everyone honest.

## Metadata

| Field | Value |
|-------|-------|
| Type | NEW_CAPABILITY |
| Complexity | HIGH |
| Systems Affected | rules engine, UI (board/rack/lobby/recap), networking (server harness + client), bot AI, exports/packaging |
| Jira Issue | N/A |
| Inputs | PRD `.agents/PRDs/PRD.md` · design `docs/superpowers/specs/2026-11-03-scrabble-multiplayer-design.md` |

## Patterns to Follow

Source-of-truth note: the repo has no code yet, so pattern sources are the **installed project skills** and Godot 4.7 docs, not existing files.

### Naming / structure
```
// SOURCE: PRD §6 directory sketch; project convention
scripts/game/   # PURE rules: bag.gd, board.gd, rack.gd, rules.gd, dictionary.gd, game.gd — no scene/visual deps
scripts/server/ # server.gd autoload, rooms.gd, bot.gd — headless-only code
scripts/client/ # net_client.gd autoload, UI controllers
scenes/  dictionaries/  tests/  assets/
```
Class names `PascalCase`, files `snake_case.gd`. Pure game classes use `class_name` + static-typing everywhere; server-only and client-only code are separated by autoload + `OS.has_feature("dedicated_server")` gates.

### Testing
```
// SOURCE: .agents/skills/godot-gdscript-headless-testing/SKILL.md (verified against Godot 4.7.2)
Write the runner as a SceneTree script, NOT a Node scene; bare assert() does NOT set exit codes.
Run: godot --headless --path . --import   (first, once)
     godot --headless --path . --script res://tests/test_runner.gd   (read EXIT CODE, not stdout)
```
All test suites follow this: `tests/*_test.gd` discovered by the runner; deterministic suites seed `RandomNumberGenerator`.

### Networking
```
// SOURCE: .agents/skills/godot-multiplayer/SKILL.md (+ references/replication-and-rpc.md for SceneMultiplayer auth + dedicated-server notes)
Adopt: @rpc vocabulary, per-node authority, "treat client input as untrusted; keep the server authoritative".
DEVIATE deliberately: transport is WebSocketMultiplayerPeer (browsers) — the skill's ENet hosting does NOT apply;
replication is state-sync of a pure logic core (PRD §10 protocol table), NOT MultiplayerSpawner/Synchronizer node replication.
```

### UI
```
// SOURCE: .agents/skills/godot-ui-control/SKILL.md, godot-signals-groups/SKILL.md, godot-resources/SKILL.md
All table UI = Control nodes with anchors/theme (no physics nodes); drag & drop via Control drag-and-drop
virtuals (_get_drag_data/_can_drop_data/_drop_data) with tap-tile→tap-square touch fallback;
Warm-club look lives in a Theme resource + premium-layout Resource; UI↔logic wired by signals through an
event-bus autoload so P2 hot-seat and P3 networked play swap drivers without UI changes.
```

## Files to Change

| File | Action | Purpose |
|------|--------|---------|
| `project.godot` | CREATE | Godot 4.7 project: Compatibility renderer, autoloads, display settings |
| `.gitignore` | UPDATE | add `.godot/`, export build dirs |
| `tests/test_runner.gd` | CREATE | SceneTree test runner with exit codes (P1 harness used by all later tasks) |
| `dictionaries/sowpods.txt` + `dictionaries/SOURCE-CREDIT.md` | CREATE | bundled lexicon + credit (pluggable one-word-per-line format) |
| `scripts/game/*.gd` | CREATE | bag.gd, board.gd, rack.gd, rules.gd, dictionary.gd, game.gd, local_game.gd (pure core + hot-seat driver) |
| `scripts/game/board_layout.gd` (+ `.tres`) | CREATE | custom Resource: official 15×15 premium-square layout |
| `scripts/client/theme/` warm-club Theme + tile/board/lobby/recap/chat scenes | CREATE | P2 UI (scenes/ for tscn, controllers in scripts/client/) |
| `scripts/server/server.gd`, `rooms.gd`, `bot.gd`, `session_tokens.gd` | CREATE | P3/P4 headless server: rooms, timers, tokens, bot |
| `scripts/client/net_client.gd` | CREATE | P3 client autoload: connect/join/resync/reconnect |
| `tests/*_test.gd`, `tests/net_smoke.gd`, `tests/bot_soak.gd` | CREATE | rule suites, network smoke, seeded bot-vs-bot soak |
| `export_presets.cfg` | CREATE | P5 web (single-threaded) + Windows/Linux (+macOS) presets |
| `docs/deployment-runbook.md`, `README.md` | CREATE | P5: systemd + Cloudflare Tunnel runbook (draft), portfolio README |

## Tasks

Execute in order; **P1–P2 require no networking** and every P1 task validates headless.

### Task 0: Install toolchain
- **Action**: SETUP
- **Implement**: install Godot 4.7.x Linux binary (headless-capable) to `~/.local/bin/godot`; confirm `godot --headless --version` ≥ 4.7. Install export templates in P5 only.
- **Validate**: `godot --headless --version` prints 4.7.x.

### Task 1: Project scaffold (P1)
- **File**: `project.godot`, skeleton dirs, `.gitignore`
- **Implement**: Compatibility (`gl_compatibility`) renderer, window 1280×800 base, `Wordtable` project name, empty main scene, autoload placeholders commented until needed; commit `.import` sidecar policy (commit sidecars, ignore `.godot/`).
- **Validate**: `godot --headless --path . --import` exits 0.

### Task 2: Headless test runner (P1)
- **File**: `tests/test_runner.gd`
- **Implement**: SceneTree script per headless-testing skill: discover/collect `tests/*_test.gd`, run each, count pass/fail, print summary, `quit(1)` on any failure; helper `ok()/fail()` (bare `assert()` is forbidden in tests).
- **Validate**: `--script res://tests/test_runner.gd` exits 0 with a sample passing test; then with one intentionally failing suite exits 1 → remove the failing suite.

### Task 3: Tile bag (P1)
- **File**: `scripts/game/bag.gd`
- **Implement**: official 100-tile distribution incl. 2 blanks; seeded shuffle; `draw(n)`, `return(tiles)`; empty-bag semantics (draws stop when empty).
- **Validate**: headless suite — counts per letter ×5 tests, exhaust + restore behavior.

### Task 4: Board model + premium layout (P1)
- **File**: `scripts/game/board.gd`, `scripts/game/board_layout.gd` (+ Resource)
- **Implement**: 15×15 grid; official premium layout as a custom Resource (star at H8); `"5F"`↔row/col algebra; line/word extraction (used later by scoring + recap history); last-move tracking.
- **Validate**: headless suite — premium counts match official (8 TW, 17 DW, 12 TL, 24 DL, 1 star); coordinate round-trips; word extraction on placed tiles.

### Task 5: Dictionary module (P1)
- **File**: `scripts/game/dictionary.gd`, `dictionaries/sowpods.txt`, `dictionaries/SOURCE-CREDIT.md`
- **Implement**: fetch a commonly redistributed SOWPODS copy, normalize (uppercase, dedupe, A–Z only); loader (path from config, default bundled); `has_word()`.
- **Validate**: headless script loads bundled file (≈267k words) and `has_word("QUARTZY")==true`, `has_word("QUARTZIES")==false` (or whatever SOWPODS truth says is a word — test must encode the list's actual behavior); load time logged < 3 s.

### Task 6: Move validation + scoring (P1)
- **File**: `scripts/game/rules.gd`
- **Implement**: pure `validate_placement(board, rack, pendings, blank_map)` → result {ok, reason, words[{word, squares, points}], total, bingo}; official algorithms: first move covers star & ≥2 tiles; single line; adjacency/crossword linkage after move 1; blanks count 0; premiums apply to newly placed tiles only; 50-pt bingo; reason strings per failure class.
- **Validate**: headless suite with a hand-verified gold corpus (≥10 valid placements w/ exact scores incl. cross-words, premiums, bingo, blank plays; ≥12 invalid cases each triggering its reason class).

### Task 7: Game state machine (P1)
- **File**: `scripts/game/game.gd`
- **Implement**: seats/turn order; commit accepted placements (mutate board/rack/bag, apply scores); exchange (bag ≥ 7); pass; six-successive-scoreless-turns ending (every pass counts); bag-empty + rack-out ending; tournament final scoring (unplayed-tile deductions; out-player collects opponents' counts; leader deducts own rack on scoreless ending); rematch reset.
- **Validate**: headless suite — three scripted full games: normal ending, scoreless ending, exchange/pass-heavy game; exact final score assertions.

### Task 8: Game facade + hot-seat driver (P1)
- **File**: `scripts/game/local_game.gd`
- **Implement**: one `LocalGame` API over game.gd exposing player intents (place_pending/recall/shuffle/commit/exchange/pass/chat) and state events; three "players" driven in-process. This seam is what P3's server binds rooms to and P2's UI listens to.
- **Validate**: headless suite — scripted 3-player complete game through the facade.

### Task 9: Warm-club theme + art tokens (P2)
- **File**: `scripts/client/theme/`, `assets/` placeholders
- **Implement**: Theme resource: wood/felt/ivory palette, brass accents, tile StyleBoxes, fonts; programmatic flat-color art (textures generated in an artist script or simple gradients — `create-game-assets` optional).
- **Validate**: visually open a scratch scene in a window; theme applied everywhere.

### Task 10: Board scene (P2)
- **File**: `scenes/board.tscn` + controller
- **Implement**: 15×15 Control grid, premium coloring, star; committed tiles (ivory, letter+value); pending tiles (raised, soft outline); last-move highlight; fully anchor-based responsive scaling incl. narrow/phone portrait variant (board shrinks, strip + rack reflow).
- **Validate**: scripted scene check at desktop + 390×844 viewports (programmatic screenshot or manual pass).

### Task 11: Rack + placement interaction (P2)
- **File**: `scenes/rack.tscn`, controller
- **Implement**: 7-tile ledge; drag & drop onto board squares (Control drag virtuals) + tap-then-tap fallback for touch; Recall; Shuffle; provisional score computed via `rules.gd` preview mode (invalid pending → Play disabled + reason line, valid → "+38" label).
- **Validate**: hot-seat scripted interaction test (drag simulation) + manual touch-fallback check in narrow viewport.

### Task 12: Commit feedback + blanks (P2)
- **File**: controller + `scenes/blank_picker.tscn`
- **Implement**: blank letter-picker popup; commit thunk + score-fly Tween on accept; reject bounce-back animation + inline "Not in my book: X" (copy style per design doc).
- **Validate**: hot-seat scripted game exercises blank placement + illegal reject.

### Task 13: Player strip, chat UI, sounds (P2)
- **File**: `scenes/player_strip.tscn`, `scenes/chat_bubble.tscn`, audio autoload
- **Implement**: score strip (avatar dot, name, score, tile count, active glow + timer ring); corner chat bubble w/ unread badge → panel + emote row (local echo; relay wired in P3); thunk/fanfare/bag sounds + persistent mute toggle (user:// config).
- **Validate**: headless suite for config persistence; visual pass.

### Task 14: Start, lobby, recap + hot-seat end-to-end (P2)
- **File**: `scenes/start.tscn`, `scenes/lobby.tscn`, `scenes/recap.tscn`
- **Implement**: start screen (nickname remembered); lobby seat plaques, bot-seat toggle (placeholder, functional in P4), timer on/off, Start gates ≥1 opponent, room code display; recap overlay (podium, final scores, full word history, Rematch) — all driven by LocalGame.
- **Validate**: scripted hot-seat full game start→play→recap→rematch in a real window; second pass at 390×844.

### Task 15: Protocol + server harness (P3)
- **File**: `scripts/server/server.gd`, `scripts/server/rooms.gd`, `scripts/server/session_tokens.gd`
- **Implement**: headless/dedicated_server feature gate; `WebSocketMultiplayerPeer.create_server()` listener; rooms registry (codes 4–6 chars, options incl. timer_on, seats, host, grace window on empty); per-player session tokens (join + rejoin-scoped); RPC surface exactly per PRD §10 (versioned, typed, JSON-able).
- **Validate**: headless script boots server, fake client connects + creates room, exits 0.

### Task 16: Server-Game binding + timers (P3)
- **File**: `scripts/server/rooms.gd`, `scripts/server/server.gd`
- **Implement**: room owns a `game.gd` instance; map intents→facade; broadcast `state_sync` (own-rack-only privacy per peer) + `turn_update`/`game_over`; server clock: 90 s default auto-pass, host-off mode falls back to 3-min stall guard for disconnected players only; scoreless counting incl. auto-passes.
- **Validate**: headless suite — intents adjudicated remotely; forced-exit client auto-passes; six-scoreless ending fires; no rack leakage between peers.

### Task 17: Client NetClient + UI rebinding (P3)
- **File**: `scripts/client/net_client.gd`
- **Implement**: connect(url)/join(code, token); apply `state_sync` + deltas into the same signal-bus shape P2's UI already consumes (UI unchanged); server URL override per export config.
- **Validate**: headless server + two scripted client instances complete a full legit game; boards equal across peers at end.

### Task 18: Reconnect UX (P3)
- **File**: `scripts/client/net_client.gd`, reconnect overlay scene
- **Implement**: "Reconnecting…" overlay (auto-retry w/ backoff + manual retry); token-based rejoin restores rack/scores/pending state; web refresh re-joins via persisted token.
- **Validate**: smoke test kills a client process mid-game, restarts, asserts resumed state byte-equal (per PRD §11).

### Task 19: Network smoke test (P3)
- **File**: `tests/net_smoke.gd`
- **Validate**: `godot --headless --path . --script res://tests/net_smoke.gd` exits 0 (spawns server + clients, full game + disconnect/resume, assertions on final states).

### Task 20: Bot move generator (P4)
- **File**: `scripts/server/bot.gd`
- **Implement**: crossword-aware move generator — anchor scan, dictionary-directed expansion (letter-indexed buckets from the lexicon), blanks as wildcards, time budget ~300 ms/move, cross-check legality via `rules.gd`; play choice = top-scoring w/ small jitter; think delay 5–15 s; no UI.
- **Validate**: headless suite — fixed seeds produce scores ≥ human baseline corpus; move time p95 < budget; legality asserted every move.

### Task 21: Bot in rooms + soak (P4)
- **File**: `scripts/server/rooms.gd`, `tests/bot_soak.gd`
- **Validate**: seeded bot-vs-bot soak (≥20 games) — all complete, 0 illegal states; lobby bot-fill works end-to-end.

### Task 22: Exports (P5)
- **File**: `export_presets.cfg`
- **Implement**: Web preset (threads OFF, single-threaded default), Windows + Linux desktop presets; icons/splash Warm-club; verify lexicon ships in PCK.
- **Validate**: `godot --headless --export-release` per target exits 0; web build size ≤ ~50 MB compressed; PCK contains dictionary.

### Task 23: Web end-to-end (P5)
- **Implement**: serve web build locally (static server, gzip/brotli); headless game server on localhost; browser session opens the web export, plays scripted moves, reloads tab → state intact.
- **Validate**: browser-driven E2E pass (agent-browser tooling) + desktop export quick game.

### Task 24: Polish + runbook + README (P5)
- **File**: `docs/deployment-runbook.md`, `README.md`
- **Implement**: game-feel sweep (thunk/fly/bounce tuned, emotes, sounds final); deploy runbook — systemd unit, Cloudflare Tunnel config, domain checklist (~$10/yr + free tier), lexicon swap instructions — drafted, NOT executed (deferred per design doc); portfolio README (what/why, architecture diagram, repo tour, dev/hot-seat instructions, runbook pointer).
- **Validate**: runbook reviewed against VPS assumptions; README renders; `git tag v0.1.0-mvp`.

## Validation

```bash
# First import (once, after scaffold)
godot --headless --path . --import

# Full unit suite (P1–P4, every milestone)
godot --headless --path . --script res://tests/test_runner.gd    # exit code is the gate

# Network smoke (P3+)
godot --headless --path . --script res://tests/net_smoke.gd

# Bot soak (P4+)
godot --headless --path . --script res://tests/bot_soak.gd

# Exports (P5)
godot --headless --path . --export-release "Web" build/web/index.html
godot --headless --path . --export-release "Linux" build/wordtable.x86_64
```
CI (optional, cheap): one job running the three headless suites on the pinned binary; fails on non-zero exit.

## Acceptance Criteria

- [ ] All tasks completed; every milestone's validation commands exit 0
- [ ] PRD §11 functional checklist holds (friend-on-phone < 60 s seated; 0 illegal boards in soak; resume byte-equality; no storable stall; web ≤ ~50 MB compressed)
- [ ] Full-rules fidelity proven by rule suites incl. six-scoreless ending + tournament final scoring
- [ ] Server-authoritative: no rack/board truth on clients; rejoin needs session token
- [ ] Browser + desktop exports from one codebase; Android/iOS/runbook-execution remain follow-ups
- [ ] Warm-club Big-board match: layout + style per approved mockups; touch-first interactions work at phone viewport
