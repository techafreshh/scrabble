# Wordtable bot seat helper (pure logic, no scene/socket deps).
# Single move-choice seam for room auto-play and the headless soak: every
# bot turn flows through BotSeat.choose_move, which delegates to the
# ScrabbleBot crossword-aware greedy generator merged for issue #19 (anchor
# scan, blank-face expansion, ScrabbleRules.validate_move oracle, 250 ms
# budget, seeded +-2 jitter). Live rooms drive it from
# RoomRegistry.poll_timers via a per-room bot_deadline_ms armed with
# think_delay_ms (5-15 s); headless proof lives in tests/bot_soak.gd.
class_name BotSeat
extends RefCounted

# Headless generation budget (50 ms margin under the 300 ms acceptance).
const TIME_BUDGET_MS := 250
# Live think-delay window before a bot commits in a room.
const THINK_MIN_SECS := 5
const THINK_MAX_SECS := 15
# Final-pick noise radius in points (seeded, deterministic per seed).
const JITTER_POINTS := 2


# Deterministic think delay in seconds: 5 + (abs(seed) % 11), range 5-15.
static func think_delay_secs(seed: int) -> int:
	return ScrabbleBot.think_delay_secs(seed)


# Think delay in milliseconds for arming RoomRegistry.bot_deadline_ms.
static func think_delay_ms(seed: int) -> int:
	return ScrabbleBot.think_delay_ms(seed)


# Returns {ok, placements, blank_map, total, words, reason}: placements are
# {col, row, letter, blank} dicts ready for LocalGame.place, blank_map keys
# Vector2i cells to their face letters. Empty result is ok:false/NO_MOVE.
static func choose_move(board, rack: Array, lexicon, seed: int = 0, time_budget_ms: int = TIME_BUDGET_MS) -> Dictionary:
	return ScrabbleBot.generate_move(board, rack, lexicon, seed, time_budget_ms)
