# Wordtable — Live Online Scrabble-Style Game: Design

**Date:** 2026-11-03
**Status:** Draft for approval
**Working title:** Wordtable (mechanics follow official Scrabble rules; neutral name chosen because "Scrabble" is Hasbro/Mattel IP and this is meant to be shown publicly — user can rename freely)

## Intent and why

A live, online, full-rules Scrabble-style game the user and their friends actually play — a game that starts with "send a code, everyone joins in under a minute." Second goal: a portfolio piece with a coherent story (one Godot codebase exporting to browser + desktop, authoritative dedicated server, real-time networking, a word-AI bot). The user is new to Godot and is delegating technical choices; the builder should stick to mainstream Godot 4 patterns and keep the Godot-specific learning curve readable in the code.

## Goals / non-goals / anti-goals

**Goals (v1):**
- Live-session multiplayer, 2–4 humans per table, join via room code or link. Games take ~20–30 min, everyone online simultaneously.
- Full official rules: 15×15 board with standard premium-square distribution, 7-tile rack, full 100-tile bag, blanks (letter chosen when placed), 50-point bingo bonus, end-of-game final scoring (unplayed-tile penalties, bag empty + rack out), standard turn order.
- Dictionary validation, server-side. Both SOWPODS and NWL word lists bundled; room host picks the lexicon at table creation.
- Server-authoritative play: clients render and propose moves; the headless server owns the tile bag, rack contents, board, scores, and validation. No client can cheat by editing memory.
- Seamless reconnect: drop a connection (browsers suspend tabs!) and the game continues; rejoining players re-sync.
- Choosing seats: bots can fill any empty seat so a game can always start. Rematch in one click.
- In-game chat (text) + one-tap emotes.
- End-of-game recap: podium, final scores, full word history (word, position, points per move).
- Exports: browser (WASM web export) and desktop (Windows/Mac/Linux) for v1. Android APK shortly after; iOS deferred (App Store fees/review) — the codebase doesn't change for these, only packaging.

**Non-goals (v1):** accounts/profiles/persistent stats, play-over-days correspondence mode, spectator mode, public matchmaking with strangers, tournaments, challenge rule (see behavior calls), move-undo after commit, cross-device saved games.
**Anti-goals:** ads, data collection beyond what a live game needs, anything that adds friction between "friend got the link" and "friend is seated."

## Approaches considered

- **A. One Godot codebase + headless Godot dedicated server (CHOSEN).** The whole game in one GDScript project; a headless export of the same project acts as the authoritative server. WebSocket transport works on every export target (browsers cannot do ENet/UDP), Cloudflare fronts the VPS for TLS. Trade-offs: Godot web export = ~30–50 MB first load; iOS deferred. Why chosen: single codebase for all platforms, real Godot multiplayer machinery, one deployable server, no second language, strong portfolio narrative.
- **B. Godot front end + separate Node/Go backend owning rules.** Rejected: two codebases/languages, rules divorced from the engine's multiplayer APIs, more moving parts, weakens the "one Godot project" story.
- **C. Player-hosted P2P.** Rejected: cross-network connecting is unreliable (NAT) without relay infrastructure; breaks "send a code, play now."

## Constraints

- Engine: Godot 4.x, GDScript (C# cannot export to web), Compatibility renderer (only WebGL 2.0 option on web).
- Transport: `WebSocketMultiplayerPeer` + high-level multiplayer API, server-authoritative. Headless server export via "Export as dedicated server" resource stripping; run under systemd on the VPS; `OS.has_feature("dedicated_server")` gates server startup code.
- Hosting: user's own VPS; Cloudflare (Tunnel or proxied WebSocket) in front, giving `wss://` required by the browser build. Client/server URL configurable (dev = localhost).
- Web export: single-threaded (Godot 4.3+ default), served with Brotli/gzip. Browsers suspend inactive tabs → the reconnect design is mandatory, not optional.
- Players identify by nickname only (stored per-device); rooms are 4–6 char codes; a game exists in server memory for the live session and dies after everyone leaves (with a grace window for rematch).

## Decisions made with the user

- **Audience/purpose:** friends actually playing it + portfolio piece; polish and reliability over breadth.
- **Pace:** live sessions only.
- **Rules:** full official rules, auto-validated; no challenge rule in v1 (server rejects invalid words at commit time with a friendly inline message; played tiles return to rack).
- **Multiplayer:** online with friends, room code/link, no accounts.
- **Extras in v1:** in-game chat, bot player, rematch + recap. (Emotes shipped as one-tap reactions inside chat bubble.)
- **Stack:** Godot (user's call, despite web-stack leanings).
- **Platforms:** browser + desktop for v1; Android right after; iOS later.
- **Hosting:** user's VPS behind Cloudflare.
- **Table layout:** "Big board" — player/score strip on top, chat collapsed to a corner bubble, board gets the space.
- **Visual style:** "Warm club" — dark wood, green felt board, ivory tiles, brass accents; subtle sounds (tile thunk, fanfare) with a mute toggle.
- **Behavior calls (user-approved):** ① turn timer ON by default (90 s, auto-pass on expiry, host-off at room creation); ② dictionary auto-rejects (no challenge/penalty system); ③ blanks open a letter-picker; ④ disconnected players' timers keep running and auto-pass so nobody waits.
- **Placement interaction:** drag & drop with tap-then-tap fallback; live provisional score while pending tiles are arranged; Recall returns pendings; Shuffle randomizes rack order.

## What's left to the builder

Project/scene structure, exact RPC message set, bot algorithm internals, server room-management details, CI/CD scripts, packaging, and naming polish. Suggested milestones (builder may re-cut): M1 rules engine + dictionary + headless validation tests; M2 table screen (UI fully testable hot-seat/local); M3 networking, rooms, reconnect; M4 bot; M5 exports + VPS/Cloudflare deploy + recap/rematch polish.

Open items the builder may settle with sensible defaults: exact bot difficulty behavior (v1: one "reasonable" bot ≈ greedy best move with slight jitter), emote set, sound asset sourcing, board color palette final tuning within the Warm-club direction.
