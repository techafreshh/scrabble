# Wordtable LocalGame facade (pure logic, no scene deps).
# The single intents-to-events seam shared by server, UI, and bot: it owns a
# ScrabbleBoard plus a ScrabbleGame state machine, translates player intents
# (place/exchange/pass_turn/recall/shuffle) into validated commits/rejects,
# and emits PRD-§10-abridged turn_update/game_over deltas. All legality and
# points come from ScrabbleRules; all turn/bag/score accounting comes from
# ScrabbleGame; the facade itself scores nothing.
# Run headless via res://tests/test_runner.gd (`--suite facade` or full run).
class_name LocalGame
extends RefCounted

var board: ScrabbleBoard
var game: ScrabbleGame

var _lexicon = null
var _pending: Array = []
var _history: Array = []
var _events: Array = []
var _shuffle_rng := RandomNumberGenerator.new()


func _init(p_player_count: int = 3, p_seed: int = 0, p_lexicon = null) -> void:
	board = ScrabbleBoard.new()
	game = ScrabbleGame.new(p_player_count, p_seed)
	_lexicon = p_lexicon
	_pending = []
	_history = []
	_events = []
	_shuffle_rng = RandomNumberGenerator.new()
	_shuffle_rng.seed = p_seed * 7919 + 13


func player_count() -> int:
	return game.player_count()


func current_player() -> int:
	return game.current_player()


func scores() -> Array:
	return game.scores.duplicate()


func is_over() -> bool:
	return game.is_over()


func ending() -> String:
	return game.ending()


func rack_letters(p: int) -> Array:
	return game.rack_letters(p)


func bag_remaining() -> int:
	return game.bag_remaining()


func history() -> Array:
	return _history.duplicate(true)


func events() -> Array:
	return _events.duplicate(true)


func pending_count() -> int:
	return _pending.size()


# Test hooks: delegate to the owned state machine.
func debug_set_rack(player: int, letters: Array) -> void:
	game.debug_set_rack(player, letters)


func debug_set_bag(letters: Array) -> void:
	game.debug_set_bag(letters)


# Pure legality/points check with zero mutation; returns the rules result
# dict unchanged ({ok, reason, reason_word, words, main_points,
# cross_points, bingo, total}).
func preview(placements: Array, blank_map: Dictionary = {}) -> Dictionary:
	return ScrabbleRules.validate_placement(
		board, game.rack_letters(game.current_player()), placements, blank_map, _lexicon
	)


# One-shot commit attempt. Stores the attempt in _pending, validates via the
# rules, and on success writes fresh squares to the board, banks the total
# through the state machine, clears _pending, and records history. On
# failure the board and game are untouched and _pending is kept so the UI
# can bounce back (clear with recall).
func place(placements: Array, blank_map: Dictionary = {}) -> Dictionary:
	var me := game.current_player()
	_pending = placements.duplicate(true)
	if game.is_over():
		return _reject(me, "GAME_OVER", "")
	var res := preview(placements, blank_map)
	if not bool(res.get("ok", false)):
		return {
			"ok": false,
			"kind": "reject",
			"player": me,
			"reason": str(res.get("reason", "")),
			"reason_word": str(res.get("reason_word", "")),
			"words": [],
			"main_points": 0,
			"cross_points": 0,
			"bingo": 0,
			"total": 0,
			"scores": scores(),
			"turn": game.current_player(),
			"over": game.is_over(),
			"ending": game.ending(),
			"delta": state_delta(),
		}
	var normed: Array = []
	for p in placements:
		normed.append(_normalize_cell(p, blank_map))
	var seen := {}
	var fresh: Array = []
	for n in normed:
		var key := "%d,%d" % [int(n.get("col", -1)), int(n.get("row", -1))]
		if seen.has(key):
			continue
		seen[key] = true
		if board.tile_at(int(n.get("col", -1)), int(n.get("row", -1))) == "":
			fresh.append(n)
	var fresh_count := fresh.size()
	for n in fresh:
		board.place_tile(
			int(n.get("col", -1)), int(n.get("row", -1)), str(n.get("letter", ""))
		)
	var total := int(res.get("total", 0))
	var grec := game.record_score(total, fresh_count)
	if not bool(grec.get("ok", false)):
		return _reject(me, str(grec.get("reason", "BAD_PLAY")), "")
	_pending.clear()
	var words: Array = (res.get("words", []) as Array).duplicate(true)
	_history.append({"player": me, "words": words, "total": total})
	var delta := state_delta()
	_events.append(delta)
	return {
		"ok": true,
		"kind": "commit",
		"player": me,
		"reason": "OK",
		"reason_word": "",
		"words": words,
		"main_points": int(res.get("main_points", 0)),
		"cross_points": int(res.get("cross_points", 0)),
		"bingo": int(res.get("bingo", 0)),
		"total": total,
		"scores": scores(),
		"turn": game.current_player(),
		"over": game.is_over(),
		"ending": game.ending(),
		"delta": delta,
	}


# Scoreless turn: swaps rack tiles for bag tiles. Rejected while a pending
# buffer exists; otherwise delegates to the state machine (which counts the
# turn as scoreless and gates on bag size).
func exchange(count: int) -> Dictionary:
	var me := game.current_player()
	if not _pending.is_empty():
		return _reject(me, "PENDING_NOT_EMPTY", "")
	var res := game.exchange(count)
	var delta := state_delta()
	_events.append(delta)
	if not bool(res.get("ok", false)):
		return _reject(me, str(res.get("reason", "")), "")
	return {
		"ok": true,
		"kind": "exchange",
		"player": me,
		"reason": "OK",
		"scores": scores(),
		"turn": game.current_player(),
		"over": game.is_over(),
		"ending": game.ending(),
		"delta": delta,
	}


# Scoreless turn: bumps the streak, may end the game. Rejected while a
# pending buffer exists; otherwise delegates to the state machine.
func pass_turn() -> Dictionary:
	var me := game.current_player()
	if not _pending.is_empty():
		return _reject(me, "PENDING_NOT_EMPTY", "")
	var res := game.pass_turn()
	var delta := state_delta()
	_events.append(delta)
	if not bool(res.get("ok", false)):
		return _reject(me, str(res.get("reason", "")), "")
	return {
		"ok": true,
		"kind": "pass",
		"player": me,
		"reason": "OK",
		"scores": scores(),
		"turn": game.current_player(),
		"over": game.is_over(),
		"ending": game.ending(),
		"delta": delta,
	}


# Full reset for Rematch: a fresh board, a state-machine reset reusing
# the construction seed (same seats, full 100-tile bag), and cleared
# pending/history/events so the next game starts clean.
func rematch() -> void:
	board = ScrabbleBoard.new()
	game.rematch()
	_pending.clear()
	_history.clear()
	_events.clear()


# Clears the pending buffer without touching board or game.
func recall() -> Dictionary:
	var me := game.current_player()
	var n := _pending.size()
	_pending.clear()
	return {
		"ok": true,
		"kind": "recall",
		"player": me,
		"reason": "OK",
		"recalled": n,
		"rack": game.rack_letters(me),
		"scores": scores(),
		"turn": game.current_player(),
		"over": game.is_over(),
		"ending": game.ending(),
		"delta": state_delta(),
	}


# Reorders only the current player's rack in place, preserving the tile
# multiset, via its own seeded RNG. Rejected while pendings exist.
func shuffle() -> Dictionary:
	var me := game.current_player()
	if not _pending.is_empty():
		return _reject(me, "PENDING_NOT_EMPTY", "")
	var faces: Array = game.rack_letters(me)
	for i: int in range(faces.size() - 1, 0, -1):
		var j := _shuffle_rng.randi_range(0, i)
		var tmp = faces[i]
		faces[i] = faces[j]
		faces[j] = tmp
	game.debug_set_rack(me, faces)
	return {
		"ok": true,
		"kind": "shuffle",
		"player": me,
		"reason": "OK",
		"rack": game.rack_letters(me),
		"scores": scores(),
		"turn": game.current_player(),
		"over": game.is_over(),
		"ending": game.ending(),
		"delta": state_delta(),
	}


# PRD-§10-abridged event: turn_update while playing (with the last commit
# or {}), game_over with full history once the machine ends the game.
func state_delta() -> Dictionary:
	var sc: Array = scores()
	var t: int = game.current_player()
	if game.is_over():
		return {
			"m": "game_over",
			"turn": t,
			"scores": sc,
			"over": true,
			"ending": game.ending(),
			"history": history(),
		}
	var last := {}
	if not _history.is_empty():
		last = (_history[_history.size() - 1] as Dictionary).duplicate(true)
	return {
		"m": "turn_update",
		"turn": t,
		"scores": sc,
		"over": false,
		"ending": "",
		"last_move": last,
	}


func _reject(me: int, reason: String, reason_word: String) -> Dictionary:
	return {
		"ok": false,
		"kind": "reject",
		"player": me,
		"reason": reason,
		"reason_word": reason_word,
		"words": [],
		"main_points": 0,
		"cross_points": 0,
		"bingo": 0,
		"total": 0,
		"scores": scores(),
		"turn": game.current_player(),
		"over": game.is_over(),
		"ending": game.ending(),
		"delta": state_delta(),
	}


# Local copy of the rules placement normalization (dict / Vector2i /
# [col, row(, letter)] plus blank_map keyed by Vector2i or "col,row") so
# fresh-square counting and board writes use the same cells the referee saw.
static func _normalize_cell(p, blank_map: Dictionary) -> Dictionary:
	var col := -1
	var row := -1
	var letter := ""
	var blank := false
	if p is Dictionary:
		var d: Dictionary = p
		col = int(d.get("col", d.get("x", -1)))
		row = int(d.get("row", d.get("y", -1)))
		letter = str(d.get("letter", ""))
		if letter == "" and d.get("tile") is Dictionary:
			var tile: Dictionary = d.get("tile")
			letter = str(tile.get("letter", ""))
			blank = blank or bool(tile.get("is_blank", tile.get("blank", false)))
		blank = blank or bool(d.get("blank", d.get("is_blank", false)))
	elif p is Vector2i:
		col = (p as Vector2i).x
		row = (p as Vector2i).y
	elif p is Array and (p as Array).size() >= 2:
		col = int((p as Array)[0])
		row = int((p as Array)[1])
		if (p as Array).size() >= 3:
			letter = str((p as Array)[2])
	var vkey := Vector2i(col, row)
	var skey := "%d,%d" % [col, row]
	var hit = null
	if blank_map.has(vkey):
		hit = blank_map[vkey]
	elif blank_map.has(skey):
		hit = blank_map[skey]
	if hit is String and (hit as String) != "":
		blank = true
		letter = (hit as String).strip_edges().to_upper()
	elif hit is Dictionary:
		blank = true
		var face := str((hit as Dictionary).get("letter", ""))
		if face != "":
			letter = face.strip_edges().to_upper()
	elif hit == true:
		blank = true
	return {"col": col, "row": row, "letter": letter, "blank": blank}
