# Wordtable board rules core (pure logic, no scene deps).
# Holds the canonical 15x15 grid, the official premium-square layout, square
# <-> cell coordinate math, tile placement, and contiguous-run word extraction.
# Run headless via res://tests/test_runner.gd (suite `board`).
class_name ScrabbleBoard
extends RefCounted

# Board dimensions: classic 15x15 grid, 0-indexed internally.
const SIZE := 15
# Center star square (H8): 0-indexed column/row.
const CENTER := Vector2i(7, 7)

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

# Row-major tile grid: 225 "" strings; placed tiles are single capitals.
var _cells: Array = []


func _init() -> void:
	_cells.clear()
	for i: int in range(SIZE * SIZE):
		_cells.append("")


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


# Square notation: letter = column A-O, number = row 1-15 (1-based).
# Accepts either order ("5F" or "F5", "H8" or "8H"), case-insensitive,
# trims whitespace; invalid input yields Vector2i(-1, -1), never an error.
static func square_to_cell(sq: String) -> Vector2i:
	var s := sq.strip_edges().to_upper()
	if s.is_empty():
		return Vector2i(-1, -1)
	var letter := ""
	var digits := ""
	for i: int in range(s.length()):
		var ch := s.substr(i, 1)
		if ch >= "A" and ch <= "O":
			if letter != "":
				return Vector2i(-1, -1)
			letter = ch
		elif ch >= "0" and ch <= "9":
			digits += ch
		else:
			return Vector2i(-1, -1)
	if letter == "" or digits == "":
		return Vector2i(-1, -1)
	var col := int(letter.unicode_at(0)) - 65
	var row := int(digits) - 1
	if not is_in_bounds(col, row):
		return Vector2i(-1, -1)
	return Vector2i(col, row)


# Inverse of square_to_cell, number-first ("5F"); "" when out of range.
static func cell_to_square(col: int, row: int) -> String:
	if not is_in_bounds(col, row):
		return ""
	return "%d%s" % [row + 1, String.chr(65 + col)]


# Letter on a cell, or "" when empty or out of range.
func tile_at(col: int, row: int) -> String:
	if not is_in_bounds(col, row):
		return ""
	return _cells[row * SIZE + col]


# Places a tile; false on out-of-range / empty-letter /
# overwriting a different letter. Re-placing the same letter is a no-op true.
func place_tile(col: int, row: int, letter: String) -> bool:
	if not is_in_bounds(col, row):
		return false
	var face := letter.strip_edges().to_upper()
	if face.length() != 1:
		return false
	var ch := face.substr(0, 1)
	if ch < "A" or ch > "Z":
		return false
	var idx := row * SIZE + col
	if _cells[idx] != "" and _cells[idx] != ch:
		return false
	_cells[idx] = ch
	return true


# Start of the contiguous tile run through (col, row) along an axis.
func _run_start(col: int, row: int, across: bool) -> Vector2i:
	var c := col
	var r := row
	if across:
		while tile_at(c - 1, r) != "":
			c -= 1
	else:
		while tile_at(c, r - 1) != "":
			r -= 1
	return Vector2i(c, r)


# Full contiguous word through (col, row) along an axis; "" when the cell
# itself is empty. Pure string assembly, no dictionary check.
func extract_word_at(col: int, row: int, across: bool = true) -> String:
	if tile_at(col, row) == "":
		return ""
	var start := _run_start(col, row, across)
	var out := ""
	var c := start.x
	var r := start.y
	while tile_at(c, r) != "":
		out += tile_at(c, r)
		if across:
			c += 1
		else:
			r += 1
	return out


# Normalizes one placement-run entry to Vector2i; garbage -> Vector2i(-1,-1).
static func _as_cell(entry) -> Vector2i:
	if entry is Vector2i:
		return entry
	if entry is Array and entry.size() == 2:
		return Vector2i(int(entry[0]), int(entry[1]))
	return Vector2i(-1, -1)


# Words formed by one straight placement run: the main word along its axis
# (axis inferred from the cells when 2+ align, else `across`) plus each
# perpendicular cross-word longer than one tile. Each entry is a Dictionary
# {word, col, row, across} anchored at the word's start cell.
func collect_words(cells: Array, across: bool = true) -> Array:
	var run: Array[Vector2i] = []
	for entry in cells:
		var cell := _as_cell(entry)
		if is_in_bounds(cell.x, cell.y):
			run.append(cell)
	if run.is_empty():
		return []
	var use_across := across
	if run.size() >= 2:
		if run[0].x == run[1].x and run[0].y != run[1].y:
			use_across = false
		elif run[0].y == run[1].y and run[0].x != run[1].x:
			use_across = true
	var out: Array = []
	var seen := {}
	var first: Vector2i = run[0]
	var main_word := extract_word_at(first.x, first.y, use_across)
	if main_word != "":
		var start := _run_start(first.x, first.y, use_across)
		var key := "%d,%d,%s" % [start.x, start.y, "A" if use_across else "D"]
		seen[key] = true
		out.append({"word": main_word, "col": start.x, "row": start.y, "across": use_across})
	for cell: Vector2i in run:
		var cross := extract_word_at(cell.x, cell.y, not use_across)
		if cross.length() <= 1:
			continue
		var cstart := _run_start(cell.x, cell.y, not use_across)
		var ckey := "%d,%d,%s" % [cstart.x, cstart.y, "D" if use_across else "A"]
		if seen.has(ckey):
			continue
		seen[ckey] = true
		out.append({"word": cross, "col": cstart.x, "row": cstart.y, "across": not use_across})
	return out
