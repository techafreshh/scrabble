# Wordtable move validation and scoring (pure logic, no scene deps).
#
# The single shared referee for Wordtable: headless gold-corpus tests,
# provisional client scoring, and (later) server adjudication all bind to
# this API. Boards and lexicons are duck-typed -- anything exposing
# `tile_at(col, row)` / `is_word(word)` works -- so the real
# `ScrabbleBoard` / `WordDictionary` drop in with zero rework, while the
# suite runs standalone on inline fakes.
#
# Entry points:
# - `validate_move(board, placements, lexicon, rack=[])` is the primary
#   referee. Placements are Dictionaries {col, row, letter, blank}; a blank
#   tile scores 0 for its own letter but must still declare its face letter
#   and still triggers a word multiplier on its square.
# - `validate_placement(board, rack, pendings, blank_map={}, lexicon=null)`
#   is the Task 6 facade: same result shape; pendings may also be Vector2i
#   or [col, row] cells with blank faces supplied via blank_map.
# - `score_move(board, placements, lexicon, rack=[])` is the
#   provisional-scoring alias of `validate_move` used for live "+N / reason"
#   labels by later client code.
#
# Result shape (all entry points): {ok, reason, reason_word,
# words[{word, col, row, across, squares, points}], main_points,
# cross_points, bingo, total}. `reason` is "OK" on success, otherwise one of
# the REASON_* codes below; `reason_word` names the offending word for
# NOT_IN_DICTIONARY failures and is "" otherwise.
class_name ScrabbleRules
extends RefCounted

# Board geometry: classic 15x15 grid, 0-indexed, center star at H8.
const SIZE := 15
const CENTER := Vector2i(7, 7)

# Bingo: exactly 7 newly placed tiles in one move.
const BINGO_TILES := 7
const BINGO_BONUS := 50

# Official premium layout, 0-indexed (col, row) pairs, x=column, y=row.
# TW (8): row 1 A/H/O, row 8 A/O, row 15 A/H/O.
const TW: Array = [
	Vector2i(0, 0), Vector2i(7, 0), Vector2i(14, 0),
	Vector2i(0, 7), Vector2i(14, 7),
	Vector2i(0, 14), Vector2i(7, 14), Vector2i(14, 14),
]
# DW (17): diagonals B2/N2, C3/M3, D4/L4, E5/K5, center H8 star,
# E11/K11, D12/L12, C13/M13, B14/N14.
const DW: Array = [
	Vector2i(1, 1), Vector2i(13, 1),
	Vector2i(2, 2), Vector2i(12, 2),
	Vector2i(3, 3), Vector2i(11, 3),
	Vector2i(4, 4), Vector2i(10, 4),
	Vector2i(7, 7),
	Vector2i(4, 10), Vector2i(10, 10),
	Vector2i(3, 11), Vector2i(11, 11),
	Vector2i(2, 12), Vector2i(12, 12),
	Vector2i(1, 13), Vector2i(13, 13),
]
# TL (12): F2/J2, B6/F6/J6/N6, B10/F10/J10/N10, F14/J14.
const TL: Array = [
	Vector2i(5, 1), Vector2i(9, 1),
	Vector2i(1, 5), Vector2i(5, 5), Vector2i(9, 5), Vector2i(13, 5),
	Vector2i(1, 9), Vector2i(5, 9), Vector2i(9, 9), Vector2i(13, 9),
	Vector2i(5, 13), Vector2i(9, 13),
]
# DL (24): D1/L1, G3/I3, A4/H4/O4, C7/G7/I7/M7, D8/L8,
# C9/G9/I9/M9, A12/H12/O12, G13/I13, D15/L15.
const DL: Array = [
	Vector2i(3, 0), Vector2i(11, 0),
	Vector2i(6, 2), Vector2i(8, 2),
	Vector2i(0, 3), Vector2i(7, 3), Vector2i(14, 3),
	Vector2i(2, 6), Vector2i(6, 6), Vector2i(8, 6), Vector2i(12, 6),
	Vector2i(3, 7), Vector2i(11, 7),
	Vector2i(2, 8), Vector2i(6, 8), Vector2i(8, 8), Vector2i(12, 8),
	Vector2i(0, 11), Vector2i(7, 11), Vector2i(14, 11),
	Vector2i(6, 12), Vector2i(8, 12),
	Vector2i(3, 14), Vector2i(11, 14),
]

# Standard English letter values (blanks are worth 0, see letter_points).
const LETTER_VALUES := {
	"A": 1, "B": 3, "C": 3, "D": 2, "E": 1, "F": 4, "G": 2,
	"H": 4, "I": 1, "J": 8, "K": 5, "L": 1, "M": 3, "N": 1,
	"O": 1, "P": 3, "Q": 10, "R": 1, "S": 1, "T": 1, "U": 1,
	"V": 4, "W": 4, "X": 8, "Y": 4, "Z": 10,
}

# Typed reason codes: "OK" on success, otherwise exactly one of these.
const REASON_OK := "OK"
const REASON_EMPTY_MOVE := "EMPTY_MOVE"
const REASON_OUT_OF_BOUNDS := "OUT_OF_BOUNDS"
const REASON_TILE_CONFLICT := "TILE_CONFLICT"
const REASON_NOT_IN_LINE := "NOT_IN_LINE"
const REASON_GAP_IN_RUN := "GAP_IN_RUN"
const REASON_FIRST_MOVE_OFF_CENTER := "FIRST_MOVE_OFF_CENTER"
const REASON_FIRST_MOVE_TOO_SHORT := "FIRST_MOVE_TOO_SHORT"
const REASON_NOT_CONNECTED := "NOT_CONNECTED"
const REASON_RACK_SHORTAGE := "RACK_SHORTAGE"
const REASON_NOT_IN_DICTIONARY := "NOT_IN_DICTIONARY"


# Premium label for a cell: "STAR_DW" only at the center, else
# "TW" / "DW" / "TL" / "DL", or "--" for a plain square.
static func premium_at(col: int, row: int) -> String:
	var cell := Vector2i(col, row)
	if cell == CENTER:
		return "STAR_DW"
	if TW.has(cell):
		return "TW"
	if DW.has(cell):
		return "DW"
	if TL.has(cell):
		return "TL"
	if DL.has(cell):
		return "DL"
	return "--"


static func is_in_bounds(col: int, row: int) -> bool:
	return col >= 0 and col < SIZE and row >= 0 and row < SIZE


# Face value of one letter; a blank tile always scores 0 for its own letter
# (it still triggers a word multiplier on its square -- see _score_word).
static func letter_points(letter: String, is_blank: bool) -> int:
	if is_blank:
		return 0
	return int(LETTER_VALUES.get(letter.strip_edges().to_upper(), 0))


# True when the board holds no tiles at all (duck-typed via tile_at).
static func board_is_first_move(board) -> bool:
	for r: int in range(SIZE):
		for c: int in range(SIZE):
			if str(board.tile_at(c, r)) != "":
				return false
	return true


# Primary referee. `placements` is an Array of Dictionaries
# {col, row, letter, blank}; `lexicon` exposes `is_word(word)`; `rack` is an
# Array of Strings ("" = wild blank) or tile Dictionaries
# {letter, is_blank} and is only enforced when non-empty.
static func validate_move(board, placements: Array, lexicon, rack: Array = []) -> Dictionary:
	if placements.is_empty():
		return _fail(REASON_EMPTY_MOVE)
	var norm := _normalize_placements(placements)
	if not bool(norm.get("ok", false)):
		return _fail(str(norm.get("error", REASON_TILE_CONFLICT)))
	var tiles: Array = norm.get("tiles", [])

	for t: Dictionary in tiles:
		if not is_in_bounds(int(t.get("col", -1)), int(t.get("row", -1))):
			return _fail(REASON_OUT_OF_BOUNDS)

	# Board occupancy snapshot (pre-existing tiles only).
	var board_cells := _snapshot_board(board)

	# Dedupe exact re-posts; same-square different letters conflict, as does
	# any placement disagreeing with a pre-existing tile. A placement that
	# repeats a pre-existing letter is absorbed as an existing tile: it
	# scores face value, consumes no rack, and counts as linkage.
	var seen := {}
	var fresh: Array = []
	for t: Dictionary in tiles:
		var key := "%d,%d" % [int(t.get("col", -1)), int(t.get("row", -1))]
		if seen.has(key):
			var prev: Dictionary = seen[key]
			if str(prev.get("letter", "")) != str(t.get("letter", "")) \
					or bool(prev.get("blank", false)) != bool(t.get("blank", false)):
				return _fail(REASON_TILE_CONFLICT)
			continue
		seen[key] = t
		var cell := Vector2i(int(t.get("col", -1)), int(t.get("row", -1)))
		if board_cells.has(cell):
			if str(board_cells[cell].get("letter", "")) != str(t.get("letter", "")):
				return _fail(REASON_TILE_CONFLICT)
		else:
			fresh.append(t)
	if fresh.is_empty():
		return _fail(REASON_EMPTY_MOVE)

	# Single straight line for 2+ new tiles.
	var across := true
	if fresh.size() >= 2:
		var same_row := true
		var same_col := true
		var r0 := int((fresh[0] as Dictionary).get("row", -1))
		var c0 := int((fresh[0] as Dictionary).get("col", -1))
		for t: Dictionary in fresh:
			if int(t.get("row", -1)) != r0:
				same_row = false
			if int(t.get("col", -1)) != c0:
				same_col = false
		if same_row and not same_col:
			across = true
		elif same_col and not same_row:
			across = false
		else:
			return _fail(REASON_NOT_IN_LINE)

	# Merged view: pre-existing tiles plus the new ones.
	var merged := board_cells.duplicate()
	for t: Dictionary in fresh:
		var cell := Vector2i(int(t.get("col", -1)), int(t.get("row", -1)))
		merged[cell] = {
			"letter": str(t.get("letter", "")),
			"is_new": true,
			"is_blank": bool(t.get("blank", false)),
		}

	# No holes between the extreme new tiles unless a tile is already there.
	if fresh.size() >= 2:
		var lo := 1 << 30
		var hi := -1
		var fixed := 0
		for t: Dictionary in fresh:
			var v := int(t.get("col", -1)) if across else int(t.get("row", -1))
			lo = mini(lo, v)
			hi = maxi(hi, v)
			fixed = int(t.get("row", -1)) if across else int(t.get("col", -1))
		for v: int in range(lo, hi + 1):
			var cell := Vector2i(v, fixed) if across else Vector2i(fixed, v)
			if not merged.has(cell):
				return _fail(REASON_GAP_IN_RUN)

	var first_move := board_cells.is_empty()
	if first_move:
		if not merged.has(CENTER):
			return _fail(REASON_FIRST_MOVE_OFF_CENTER)
		if fresh.size() < 2:
			return _fail(REASON_FIRST_MOVE_TOO_SHORT)
	else:
		var linked := false
		for t: Dictionary in fresh:
			var c := int(t.get("col", -1))
			var r := int(t.get("row", -1))
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				if board_cells.has(Vector2i(c + d.x, r + d.y)):
					linked = true
					break
			if linked:
				break
		if not linked:
			return _fail(REASON_NOT_CONNECTED)

	# Rack check, skipped entirely when no rack is passed. "" (or is_blank)
	# entries are wild blanks that cover blank placements.
	if not rack.is_empty():
		var pool := _normalize_rack(rack)
		for t: Dictionary in fresh:
			if not _consume(pool, str(t.get("letter", "")), bool(t.get("blank", false))):
				return _fail(REASON_RACK_SHORTAGE)

	# Form words: the main run along the play axis plus every perpendicular
	# cross-word of length >= 2. A lone tile takes the longer of its two
	# runs (across on ties) as its main word.
	var lex = _resolve_lexicon(board, lexicon)
	var scored: Array = []
	if fresh.size() == 1:
		var t0: Dictionary = fresh[0]
		var run_a := _run_text(merged, int(t0.get("col", -1)), int(t0.get("row", -1)), true)
		var run_d := _run_text(merged, int(t0.get("col", -1)), int(t0.get("row", -1)), false)
		var a_len := (str(run_a.get("word", ""))).length()
		var d_len := (str(run_d.get("word", ""))).length()
		if a_len < 2 and d_len < 2:
			return _fail(REASON_NOT_CONNECTED)
		if a_len >= 2 and d_len >= 2:
			if d_len > a_len:
				scored.append(_with_across(run_d, false))
				scored.append(_with_across(run_a, true))
			else:
				scored.append(_with_across(run_a, true))
				scored.append(_with_across(run_d, false))
		elif a_len >= 2:
			scored.append(_with_across(run_a, true))
		else:
			scored.append(_with_across(run_d, false))
	else:
		var f0: Dictionary = fresh[0]
		var main := _run_text(merged, int(f0.get("col", -1)), int(f0.get("row", -1)), across)
		scored.append(_with_across(main, across))
		for t: Dictionary in fresh:
			var cross := _run_text(
				merged, int(t.get("col", -1)), int(t.get("row", -1)), not across
			)
			if (str(cross.get("word", ""))).length() >= 2:
				scored.append(_with_across(cross, not across))

	# Every formed word must be dictionary-legal; the whole move is rejected
	# on the first illegal word (main word first, then crosses in order).
	var words: Array = []
	var main_points := 0
	var cross_points := 0
	var is_main := true
	for entry: Dictionary in scored:
		var w := str(entry.get("word", ""))
		if lex != null and not lex.is_word(w):
			return _fail(REASON_NOT_IN_DICTIONARY, w)
		var pts := _score_word(merged, entry.get("cells", []))
		words.append({
			"word": w,
			"col": int(entry.get("col", -1)),
			"row": int(entry.get("row", -1)),
			"across": bool(entry.get("across", true)),
			"squares": entry.get("cells", []),
			"points": pts,
		})
		if is_main:
			main_points = pts
		else:
			cross_points += pts
		is_main = false

	# Bingo: exactly 7 newly placed tiles in one move, scored after word sums.
	var bingo := 0
	if fresh.size() == BINGO_TILES:
		bingo = BINGO_BONUS
	return {
		"ok": true,
		"reason": REASON_OK,
		"reason_word": "",
		"words": words,
		"main_points": main_points,
		"cross_points": cross_points,
		"bingo": bingo,
		"total": main_points + cross_points + bingo,
	}


# Provisional-scoring alias of `validate_move` for live "+N / reason" labels.
static func score_move(board, placements: Array, lexicon, rack: Array = []) -> Dictionary:
	return validate_move(board, placements, lexicon, rack)


# Task 6 facade: (board, rack, pendings, blank_map[, lexicon]) -> result.
# Pendings are placement Dictionaries {col, row, letter, blank}; Vector2i or
# [col, row] cells are also accepted with their face letter taken from
# blank_map (keyed by Vector2i or "col,row"; a String value both marks the
# tile blank and assigns its face letter). When `lexicon` is omitted it is
# resolved from `board.get_lexicon()` / `board.dictionary` / `board.lexicon`
# when available; without any lexicon the dictionary check is skipped.
static func validate_placement(
	board, rack: Array, pendings: Array, blank_map: Dictionary = {}, lexicon = null
) -> Dictionary:
	var placements: Array = []
	for p in pendings:
		placements.append(_pending_to_placement(p, blank_map))
	return validate_move(board, placements, _resolve_lexicon(board, lexicon), rack)


static func _fail(reason: String, reason_word: String = "") -> Dictionary:
	return {
		"ok": false,
		"reason": reason,
		"reason_word": reason_word,
		"words": [],
		"main_points": 0,
		"cross_points": 0,
		"bingo": 0,
		"total": 0,
	}


static func _with_across(run: Dictionary, across: bool) -> Dictionary:
	var out := (run as Dictionary).duplicate()
	out["across"] = across
	return out


# Normalizes raw placement dicts to {col, row, letter, blank}. Anything that
# is not a well-formed single A-Z tile (including a blank with no declared
# face letter) is a tile conflict, never silently dropped.
static func _normalize_placements(placements: Array) -> Dictionary:
	var tiles: Array = []
	for p in placements:
		if not (p is Dictionary):
			return {"ok": false, "error": REASON_TILE_CONFLICT}
		var d: Dictionary = p
		var col := int(d.get("col", -1))
		var row := int(d.get("row", -1))
		var letter := str(d.get("letter", "")).strip_edges().to_upper()
		var blank := bool(d.get("blank", d.get("is_blank", false)))
		if letter.length() != 1 or letter < "A" or letter > "Z":
			return {"ok": false, "error": REASON_TILE_CONFLICT}
		tiles.append({"col": col, "row": row, "letter": letter, "blank": blank})
	return {"ok": true, "tiles": tiles}


static func _pending_to_placement(p, blank_map: Dictionary) -> Dictionary:
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


static func _snapshot_board(board) -> Dictionary:
	var out := {}
	for r: int in range(SIZE):
		for c: int in range(SIZE):
			var letter := str(board.tile_at(c, r)).strip_edges().to_upper()
			if letter != "":
				out[Vector2i(c, r)] = {
					"letter": letter,
					"is_new": false,
					"is_blank": false,
				}
	return out


static func _normalize_rack(rack: Array) -> Array:
	var pool: Array = []
	for e in rack:
		if e is String:
			var s := str(e).strip_edges().to_upper()
			pool.append({"letter": s, "blank": s == ""})
		elif e is Dictionary:
			var d: Dictionary = e
			var face := str(d.get("letter", "")).strip_edges().to_upper()
			var b := bool(d.get("is_blank", d.get("blank", face == "")))
			pool.append({"letter": face, "blank": b})
	return pool


static func _consume(pool: Array, letter: String, blank: bool) -> bool:
	for i: int in range(pool.size()):
		var e: Dictionary = pool[i]
		if blank:
			if bool(e.get("blank", false)):
				pool.remove_at(i)
				return true
		else:
			if not bool(e.get("blank", false)) and str(e.get("letter", "")) == letter:
				pool.remove_at(i)
				return true
	return false


static func _resolve_lexicon(board, lexicon):
	if lexicon != null:
		return lexicon
	if board is Object:
		if (board as Object).has_method("get_lexicon"):
			return (board as Object).call("get_lexicon")
		for key: String in ["dictionary", "lexicon"]:
			var v = (board as Object).get(key)
			if v != null:
				return v
	return null


# Full contiguous run through (col, row) along an axis over the merged tile
# map: {word, col, row, cells} anchored at the run's start cell.
static func _run_text(cells: Dictionary, col: int, row: int, across: bool) -> Dictionary:
	var c := col
	var r := row
	if across:
		while cells.has(Vector2i(c - 1, r)):
			c -= 1
	else:
		while cells.has(Vector2i(c, r - 1)):
			r -= 1
	var word := ""
	var run: Array = []
	var cc := c
	var rr := r
	while cells.has(Vector2i(cc, rr)):
		var info: Dictionary = cells[Vector2i(cc, rr)]
		word += str(info.get("letter", ""))
		run.append(Vector2i(cc, rr))
		if across:
			cc += 1
		else:
			rr += 1
	return {"word": word, "col": c, "row": r, "cells": run}


# Official scoring for one word: letter premiums (DL x2 / TL x3) apply only
# to newly placed tiles (blanks contribute 0 for their own letter), word
# premiums (TW x3 / DW or STAR_DW x2) multiply the whole word once per newly
# placed tile covering them -- including inside cross-words.
static func _score_word(cells: Dictionary, run: Array) -> int:
	var face := 0
	var mult := 1
	for cell in run:
		var info: Dictionary = cells[cell]
		var letter := str(info.get("letter", ""))
		var pts := 0
		if bool(info.get("is_new", false)):
			if not bool(info.get("is_blank", false)):
				pts = int(LETTER_VALUES.get(letter, 0))
			match premium_at((cell as Vector2i).x, (cell as Vector2i).y):
				"DL":
					pts *= 2
				"TL":
					pts *= 3
				"TW":
					mult *= 3
				"DW", "STAR_DW":
					mult *= 2
		else:
			pts = int(LETTER_VALUES.get(letter, 0))
		face += pts
	return face * mult
