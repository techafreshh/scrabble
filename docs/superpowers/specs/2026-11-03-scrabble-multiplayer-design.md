# Wordtable — Live Online Scrabble-Style Game: Design

**Date:** 2026-11-03
**Status:** Draft for approval
**Working title:** Wordtable (mechanics follow official Scrabble rules; neutral name chosen because "Scrabble" is Hasbro/Mattel IP and this is meant to be shown publicly — user can rename freely)

## Intent and why

A live, online, full-rules Scrabble-style game the user and their friends actually play — a game that starts with "send a code, everyone joins in under a minute." Second goal: a portfolio piece with a coherent story (one Godot codebase exporting to browser + desktop, authoritative dedicated server, real-time networking, a word-AI bot). The user is new to Godot and is delegating technical choices; the builder should stick to mainstream Godot 4 patterns and keep the Godot-specific learning curve readable in the code.

## Goals / non-goals / anti-goals

**Goals (v1):**
- Live-session multiplayer, 2–4 humans per table, join via room code or link. Games take ~20–30 min, everyone online simultaneously.
- Full official rules: 15×15 board with standard premium-square distribution, 7-tile rack, full 100-tile bag, blanks (letter chosen when placed), 50-point bingo bonus, end-of-game final scoring (unplayed-tile penalties, bag empty + rack out), official six-successive-scoreless-turns ending, standard turn order.
- Dictionary validation, server-side. The lexicon is a pluggable word-list file the server loads at startup; v1 ships SOWPODS only (see Constraints for why not NWL).
- Server-authoritative play: clients render and propose moves; the headless server owns the tile bag, rack contents, board, scores, and validation. No client can cheat by editing memory.
- Seamless reconnect: drop a connection (browsers suspend tabs!) and the game continues; rejoining players re-sync.
- Choosing seats: bots can fill any empty seat so a game can always start. Rematch in one click.
- In-game chat (text) + one-tap emotes.
- End-of-game recap: podium, final scores, full word history (word, position, points per move).
- Exports: browser (WASM web export) and desktop (Windows/Mac/Linux) for v1, with the table screen responsive and touch-first from the start — phones opening the web link are a day-one audience. Android APK shortly after; iOS deferred (App Store fees/review) — the codebase doesn't change for these, only packaging.

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
- Word lists: NWL is proprietary (NASPA sells/controls it) and is NOT bundled. v1 ships SOWPODS (one word per line, UTF-8) sourced from a commonly redistributed copy with visible credit, so the repo stays safe to share publicly; the loader accepts any same-format file so a second lexicon (or a licensed NWL) can be dropped in later.
- Deployment is deferred (user call during builder check): v1 ends at the game running locally (ws://localhost, plus LAN testing) with browser + desktop exports. The VPS/Cloudflare runbook (systemd unit, tunnel config, wss:// domain) is still prepared, but a later session executes it once the user registers a domain (~$10/yr assumed) on Cloudflare's free tier. Players identify by nickname only (stored per-device); rooms are 4–6 char codes; a game exists in server memory for the live session and dies after everyone leaves (with a grace window for rematch).

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
- **Behavior calls (user-approved):** ① turn timer ON by default (90 s, auto-pass on expiry, host-off at room creation; when off, disconnected players still have a 3-minute stall-guard auto-pass); ② dictionary auto-rejects (no challenge/penalty system in v1); ③ blanks open a letter-picker; ④ all passes — manual or automatic — count as scoreless turns, and the official six-successive-scoreless-turns ending applies, so vanished players can't stall a game forever.
- **Placement interaction:** drag & drop with tap-then-tap fallback; live provisional score while pending tiles are arranged; Recall returns pendings; Shuffle randomizes rack order.

## What's left to the builder

Project/scene structure, exact RPC message set, bot algorithm internals, server room-management details, CI/CD scripts, packaging, and naming polish. Suggested milestones (builder may re-cut): M1 rules engine + dictionary + headless validation tests; M2 table screen, responsive + touch-first (UI fully testable hot-seat/local); M3 networking, rooms, reconnect; M4 bot; M5 browser + desktop exports and recap/rematch polish, plus the drafted-not-executed deployment runbook. Expected overall scale, agreed with the user: roughly 2–4 weeks of focused building; milestone order as listed so something playable exists as early as possible.

Open items the builder may settle with sensible defaults: exact bot difficulty behavior (v1: one "reasonable" bot ≈ greedy best move with slight jitter), emote set, sound asset sourcing, board color palette final tuning within the Warm-club direction.
