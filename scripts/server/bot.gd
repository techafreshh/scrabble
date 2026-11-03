# Wordtable bot move generator (pure logic, no scene/socket deps).
# A dictionary-directed, crossword-aware greedy search: it enumerates
# anchor-adjacent placements (empty cells touching a tile, or the center
# star on an empty board) across both axes, fills board gaps from the
# rack, expands blank slots over face letters, and validates every
# candidate through ScrabbleRules.validate_move (main + cross words,
# premiums, bingo in one call). The best candidate wins by rules total
# plus a small seeded jitter; generation aborts on a time budget and
# returns the best move found so far. Live rooms drive it from
# RoomRegistry.poll_timers via a per-room bot_deadline_ms armed with
# think_delay_ms (5-15 s); headless proof lives in tests/test_bot_gen.gd.
class_name ScrabbleBot
extends RefCounted

# Headless generation budget (50 ms margin under the 300 ms acceptance).
const TIME_BUDGET_MS := 250
# Live think delay window before a bot commits in a room.
const THINK_MIN_SECS := 5
const THINK_MAX_SECS := 15
# Final-pick noise radius in points (seeded, deterministic per seed).
const JITTER_POINTS := 2
# Hard cap on validated candidates per call (time budget is the live guard).
const MAX_CANDIDATES := 2000
# Longest placement run considered (a bingo needs exactly 7 fresh tiles).
const MAX_RUN_LENGTH := 7

const _FACES := "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
const _VOWELS := ["A", "E", "I", "O", "U"]
const _DIRS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]


# Deterministic think delay in seconds: 5 + (abs(seed) % 11), range 5-15.
static func think_delay_secs(seed: int) -> int:
	return THINK_MIN_SECS + (absi(seed) % (THINK_MAX_SECS - THINK_MIN_SECS + 1))


static func think_delay_ms(seed: int) -> int:
	return think_delay_secs(seed) * 1000


# Returns {ok, placements, blank_map, total, words, reason}: placements are
# {col, row, letter, blank} dicts ready for LocalGame.place, blank_map keys
# Vector2i cells to their face letters. Empty result is ok:false/NO_MOVE.
static func generate_move(board, rack: Array, lexicon, seed: int = 0, time_budget_ms: int = TIME_BUDGET_MS) -> Dictionary:
	var started_ms := Time.get_ticks_msec()
	var occ := _snapshot(board)
	var tiles := _normalize_rack(rack)
	if tiles.is_empty():
		return _no_move()
	var buckets: Array = [[], [], [], [], [], [], []]
	for anchor in _anchors(occ):
		var cell: Vector2i = anchor
		for across in [true, false]:
			var fixed := cell.y if across else cell.x
			var coord := cell.x if across else cell.y
			for start in range(maxi(0, coord - (MAX_RUN_LENGTH - 1)), coord + 1):
				for length in range(1, MAX_RUN_LENGTH + 1):
					if coord < start or coord > start + length - 1:
						continue
					var cells: Array = []
					var in_bounds := true
					for i in range(length):
						var at := Vector2i(start + i, fixed) if across else Vector2i(fixed, start + i)
						if at.x < 0 or at.x >= ScrabbleRules.SIZE or at.y < 0 or at.y >= ScrabbleRules.SIZE:
							in_bounds = false
							break
						cells.append(at)
					if not in_bounds:
						continue
					var empty_count := 0
					for at in cells:
						if not occ.has(at):
							empty_count += 1
					if empty_count == 0 or empty_count > tiles.size():
						continue
					if empty_count > MAX_RUN_LENGTH:
						continue
					(buckets[empty_count - 1] as Array).append(cells)
	var face_rng := RandomNumberGenerator.new()
	face_rng.seed = seed * 31 + 7
	var pair_faces := _sample_faces(face_rng)
	var scored: Array = []
	var checked := 0
	var done := false
	for bucket in buckets:
		if done:
			break
		for cells in (bucket as Array):
			if done:
				break
			var slot_of := {}
			var slots: Array = []
			for at in (cells as Array):
				if not occ.has(at):
					slot_of[at] = slots.size()
					slots.append(at)
			for tup in _index_tuples(tiles.size(), slots.size()):
				if done:
					break
				var blank_pos: Array = []
				for i in range((tup as Array).size()):
					var tile: Dictionary = tiles[int((tup as Array)[i])]
					if bool(tile.get("blank", false)):
						blank_pos.append(i)
				for faces in _face_grid(blank_pos.size(), pair_faces):
					var placements: Array = []
					var blank_map := {}
					var fi := 0
					for at in (cells as Array):
						if occ.has(at):
							placements.append({"col": (at as Vector2i).x, "row": (at as Vector2i).y, "letter": str(occ[at]), "blank": false})
						else:
							var tile: Dictionary = tiles[int((tup as Array)[int(slot_of[at])])]
							if bool(tile.get("blank", false)):
								var face := str((faces as Array)[fi])
								fi += 1
								placements.append({"col": (at as Vector2i).x, "row": (at as Vector2i).y, "letter": face, "blank": true})
								blank_map[at] = face
							else:
								placements.append({"col": (at as Vector2i).x, "row": (at as Vector2i).y, "letter": str(tile.get("letter", "")), "blank": false})
					var res := ScrabbleRules.validate_move(board, placements, lexicon, rack)
					checked += 1
					if bool(res.get("ok", false)):
						scored.append({
							"placements": placements,
							"blank_map": blank_map,
							"total": int(res.get("total", 0)),
							"words": (res.get("words", []) as Array).duplicate(true),
						})
					if checked >= MAX_CANDIDATES:
						done = true
						break
					if checked % 32 == 0 and int(Time.get_ticks_msec() - started_ms) >= time_budget_ms:
						done = true
						break
	if scored.is_empty():
		return _no_move()
	var pick_rng := RandomNumberGenerator.new()
	pick_rng.seed = seed
	var best: Dictionary = scored[0]
	var best_eff := -999999999
	for cand in scored:
		var eff := int((cand as Dictionary).get("total", 0)) + pick_rng.randi_range(-JITTER_POINTS, JITTER_POINTS)
		if eff > best_eff:
			best_eff = eff
			best = cand
	return {
		"ok": true,
		"reason": "OK",
		"placements": (best as Dictionary).get("placements", []),
		"blank_map": (best as Dictionary).get("blank_map", {}),
		"total": int((best as Dictionary).get("total", 0)),
		"words": (best as Dictionary).get("words", []),
	}


static func _no_move() -> Dictionary:
	return {
		"ok": false, "reason": "NO_MOVE", "placements": [],
		"blank_map": {}, "total": 0, "words": [],
	}


# Occupancy snapshot (pre-existing tiles only), duck-typed via tile_at like
# ScrabbleRules.board_is_first_move.
static func _snapshot(board) -> Dictionary:
	var out := {}
	for r: int in range(ScrabbleRules.SIZE):
		for c: int in range(ScrabbleRules.SIZE):
			var letter := str(board.tile_at(c, r)).strip_edges().to_upper()
			if letter != "":
				out[Vector2i(c, r)] = letter
	return out


# Row-major anchor list: every empty cell orthogonally touching a tile, or
# the center star when the board is empty.
static func _anchors(occ: Dictionary) -> Array:
	if occ.is_empty():
		return [ScrabbleBoard.CENTER]
	var seen := {}
	var out: Array = []
	for cell in occ.keys():
		var c: Vector2i = cell
		for d in _DIRS:
			var n: Vector2i = c + d
			if n.x < 0 or n.x >= ScrabbleRules.SIZE or n.y < 0 or n.y >= ScrabbleRules.SIZE:
				continue
			if occ.has(n) or seen.has(n):
				continue
			seen[n] = true
			out.append(n)
	out.sort_custom(func(a, b): return a.y < b.y or (a.y == b.y and a.x < b.x))
	return out


# Rack entries to {letter, blank} dicts; "" (or is_blank) entries are wild.
static func _normalize_rack(rack: Array) -> Array:
	var out: Array = []
	for e in rack:
		if e is String:
			var s := str(e).strip_edges().to_upper()
			out.append({"letter": s, "blank": s == ""})
		elif e is Dictionary:
			var d: Dictionary = e
			var face := str(d.get("letter", "")).strip_edges().to_upper()
			out.append({"letter": face, "blank": bool(d.get("is_blank", d.get("blank", face == "")))})
	return out


# All ordered index tuples: distinct rack indices taken k at a time.
static func _index_tuples(n: int, k: int) -> Array:
	var out: Array = []
	if k <= 0:
		out.append([])
		return out
	if k > n:
		return out
	var used: Array = []
	for i in range(n):
		used.append(false)
	_tuples_into(n, k, [], used, out)
	return out


static func _tuples_into(n: int, k: int, cur: Array, used: Array, out: Array) -> void:
	if cur.size() == k:
		out.append(cur.duplicate())
		return
	for i in range(n):
		if not bool(used[i]):
			used[i] = true
			cur.append(i)
			_tuples_into(n, k, cur, used, out)
			cur.pop_back()
			used[i] = false


# Vowel + seeded consonant sample for the double-blank case (still A-Z,
# capped so pairs stay cheap).
static func _sample_faces(rng: RandomNumberGenerator) -> Array:
	var faces := _VOWELS.duplicate()
	var cons: Array = []
	for i in range(26):
		var ch := String.chr(65 + i)
		if not (ch in _VOWELS):
			cons.append(ch)
	for i in range(cons.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = cons[i]
		cons[i] = cons[j]
		cons[j] = tmp
	for i in range(mini(3, cons.size())):
		faces.append(cons[i])
	return faces


# Face-letter grids per blank count: single blank tries all of A-Z,
# two blanks try the reduced vowel/sample pairs, three or more use vowels.
static func _face_grid(blank_count: int, pair_faces: Array) -> Array:
	if blank_count <= 0:
		return [[]]
	if blank_count == 1:
		var out: Array = []
		for i in range(26):
			out.append([String.chr(65 + i)])
		return out
	var pool: Array = pair_faces if blank_count == 2 else _VOWELS
	var grids: Array = [[]]
	for _b in range(blank_count):
		var grown: Array = []
		for prefix in grids:
			for face in pool:
				var combo: Array = (prefix as Array).duplicate()
				combo.append(face)
				grown.append(combo)
		grids = grown
	return grids
