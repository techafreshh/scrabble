# Wordtable local-game facade (pure logic, no scene deps).
# Single intents-to-events seam over ScrabbleBoard + ScrabbleGame +
# ScrabbleRules so server, UI, and bot share one rules wiring: five intents
# (place / exchange / pass_turn / recall / shuffle) become validated
# commit/reject dicts plus PRD-§10-shaped turn_update / game_over deltas.
# The facade scores nothing itself: legality and points come from one
# ScrabbleRules.validate_placement call, turn/bag/score accounting from
# ScrabbleGame. Pending placements are UI-owned staging: set on every
# `place` entry, cleared on commit, kept on reject (recall clears them);
# exchange / pass_turn / shuffle refuse while pendings exist.
# Run headless via res://tests/test_runner.gd (`--suite facade` or full run).
class_name LocalGame
extends RefCounted

const PENDING_NOT_EMPTY := "PENDING_NOT_EMPTY"

var _board: ScrabbleBoard
var _game: ScrabbleGame
var _lexicon = null
var _pending: Array = []
var _history: Array = []
var _events: Array = []
var _shuffle_rng := RandomNumberGenerator.new()


func _init(player_count: int = 3, p_seed: int = 0, lexicon = null) -> void:
	_board = ScrabbleBoard.new()
	_game = ScrabbleGame.new(player_count, p_seed)
	_lexicon = lexicon
	_pending = []
	_history = []
	_events = []
	_shuffle_rng = RandomNumberGenerator.new()
	# Own stream, independent of the game seed's bag/rack shuffle.
	_shuffle_rng.seed = p_seed ^ 0x5EED


func player_count() -> int:
	return _game.player_count()


func current_player() -> int:
	return _game.current_player()


func scores() -> Array:
	return _game.scores.duplicate()


func is_over() -> bool:
	return _game.is_over()


func ending() -> String:
	return _game.ending()


func rack_letters(p: int) -> Array:
	return _game.rack_letters(p)


func bag_remaining() -> int:
	return _game.bag_remaining()


func history() -> Array:
	return _history.duplicate(true)


func events() -> Array:
	return _events.duplicate(true)


func get_board() -> ScrabbleBoard:
	return _board


# Test hooks: rewire the underlying game's bag / racks (see game.gd).
func debug_set_bag(letters: Array) -> void:
	_game.debug_set_bag(letters)


func debug_set_rack(player: int, letters: Array) -> void:
	_game.debug_set_rack(player, letters)


# Pure legality/points probe: zero mutation, zero pending changes.
func preview(placements: Array, blank_map: Dictionary = {}) -> Dictionary:
	return ScrabbleRules.validate_placement(
		_board,
		_game.rack_letters(_game.current_player()),
		placements,
		blank_map,
		_lexicon
	)


# One-shot commit attempt. Reject leaves board/game untouched (pending kept
# so UI can bounce back); commit writes fresh squares, banks points via
# game.record_score, clears pending, and records history.
func place(placements: Array, blank_map: Dictionary = {}) -> Dictionary:
	var me := _game.current_player()
	_pending = (placements as Array).duplicate(true)
	if _game.is_over():
		return _record({
			"ok": false, "kind": "reject", "player": me,
			"reason": "GAME_OVER", "reason_word": "",
			"words": [], "total": 0,
			"scores": scores(), "turn": _game.current_player(),
			"over": true, "ending": _game.ending(),
		})
	var res := preview(placements, blank_map)
	if not bool(res.get("ok", false)):
		return _record({
			"ok": false, "kind": "reject", "player": me,
			"reason": str(res.get("reason", "")),
			"reason_word": str(res.get("reason_word", "")),
			"words": [], "total": 0,
			"scores": scores(), "turn": _game.current_player(),
			"over": _game.is_over(), "ending": _game.ending(),
		})
	# Fresh squares are counted against the board BEFORE writing: squares
	# already holding the same letter are absorbed (no rack consumed).
	var tiles := _normalize_for_board(placements, blank_map)
	var fresh := 0
	for t: Dictionary in tiles:
		if _board.tile_at(int(t.get("col", -1)), int(t.get("row", -1))) == "":
			fresh += 1
	for t: Dictionary in tiles:
		var c := int(t.get("col", -1))
		var r := int(t.get("row", -1))
		if _board.tile_at(c, r) == "":
			_board.place_tile(c, r, str(t.get("letter", "")))
	var total := int(res.get("total", 0))
	_game.record_score(total, fresh)
	_pending.clear()
	_history.append({
		"player": me,
		"words": (res.get("words", []) as Array).duplicate(true),
		"total": total,
	})
	return _record({
		"ok": true, "kind": "commit", "player": me,
		"reason": "OK", "reason_word": "",
		"words": (res.get("words", []) as Array).duplicate(true),
		"main_points": int(res.get("main_points", 0)),
		"cross_points": int(res.get("cross_points", 0)),
		"bingo": int(res.get("bingo", 0)),
		"total": total,
		"scores": scores(), "turn": _game.current_player(),
		"over": _game.is_over(), "ending": _game.ending(),
		"delta": state_delta(),
	})


# Scoreless turn swapping `count` rack tiles via the bag; refused while
# pendings exist, otherwise a straight game.exchange wrap.
func exchange(count: int) -> Dictionary:
	var me := _game.current_player()
	if not _pending.is_empty():
		return _reject_pending("exchange", me)
	var res := _game.exchange(count)
	var out := {
		"ok": bool(res.get("ok", false)), "kind": "exchange", "player": me,
		"scores": scores(), "turn": _game.current_player(),
		"over": _game.is_over(), "ending": _game.ending(),
		"delta": state_delta(),
	}
	if not bool(out.get("ok", false)):
		out["reason"] = str(res.get("reason", ""))
	return _record(out)


# Scoreless turn passing without play; refused while pendings exist.
func pass_turn() -> Dictionary:
	var me := _game.current_player()
	if not _pending.is_empty():
		return _reject_pending("pass", me)
	var res := _game.pass_turn()
	var out := {
		"ok": bool(res.get("ok", false)), "kind": "pass", "player": me,
		"scores": scores(), "turn": _game.current_player(),
		"over": _game.is_over(), "ending": _game.ending(),
		"delta": state_delta(),
	}
	if not bool(out.get("ok", false)):
		out["reason"] = str(res.get("reason", ""))
	return _record(out)


# Drops staged pendings without touching board/game; reports how many.
func recall() -> Dictionary:
	var me := _game.current_player()
	var n := _pending.size()
	_pending.clear()
	return _record({
		"ok": true, "kind": "recall", "player": me,
		"recalled": n, "rack": _game.rack_letters(me),
		"scores": scores(), "turn": _game.current_player(),
		"over": _game.is_over(), "ending": _game.ending(),
		"delta": state_delta(),
	})


# Fisher-Yates reorder of the current player's rack faces only: same tile
# multiset, own seeded stream, refused while pendings exist or game is over.
func shuffle() -> Dictionary:
	var me := _game.current_player()
	if not _pending.is_empty():
		return _reject_pending("shuffle", me)
	if _game.is_over():
		return _record({
			"ok": false, "kind": "shuffle", "player": me,
			"reason": "GAME_OVER",
			"scores": scores(), "turn": _game.current_player(),
			"over": true, "ending": _game.ending(),
			"delta": state_delta(),
		})
	var faces := _game.rack_letters(me)
	for i: int in range(faces.size() - 1, 0, -1):
		var j := _shuffle_rng.randi_range(0, i)
		var tmp = faces[i]
		faces[i] = faces[j]
		faces[j] = tmp
	_game.debug_set_rack(me, faces)
	return _record({
		"ok": true, "kind": "shuffle", "player": me,
		"rack": _game.rack_letters(me),
		"scores": scores(), "turn": _game.current_player(),
		"over": _game.is_over(), "ending": _game.ending(),
		"delta": state_delta(),
	})


# PRD-§10-abridged network delta: turn_update while playing, game_over once
# the state machine ends the game.
func state_delta() -> Dictionary:
	if _game.is_over():
		return {
			"m": "game_over", "turn": _game.current_player(),
			"scores": scores(), "over": true,
			"ending": _game.ending(),
			"history": _history.duplicate(true),
		}
	var last := {}
	if not _history.is_empty():
		last = (_history.back() as Dictionary).duplicate(true)
	return {
		"m": "turn_update", "turn": _game.current_player(),
		"scores": scores(), "over": false, "ending": "",
		"last_move": last,
	}


func _reject_pending(kind: String, me: int) -> Dictionary:
	return _record({
		"ok": false, "kind": kind, "player": me,
		"reason": PENDING_NOT_EMPTY,
		"scores": scores(), "turn": _game.current_player(),
		"over": _game.is_over(), "ending": _game.ending(),
		"delta": state_delta(),
	})


func _record(event: Dictionary) -> Dictionary:
	_events.append(event)
	return event


# Board-write normalization mirroring ScrabbleRules._pending_to_placement
# keying (Vector2i or "col,row" blank_map keys; String/Dictionary/true hits
# mark blanks). Rules already validated; this only locates squares to write.
static func _normalize_for_board(placements: Array, blank_map: Dictionary) -> Array:
	var out: Array = []
	for p in placements:
		out.append(_pending_to_tile(p, blank_map))
	return out


static func _pending_to_tile(p, blank_map: Dictionary) -> Dictionary:
	var col := -1
	var row := -1
	var letter := ""
	var blank := false
	if p is Dictionary:
		var d: Dictionary = p
		col = int(d.get("col", d.get("x", -1)))
		row = int(d.get("row", d.get("y", -1)))
		letter = str(d.get("letter", ""))
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
