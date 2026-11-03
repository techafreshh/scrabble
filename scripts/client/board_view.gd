# Wordtable board view: 15x15 playable grid with pending states.
#
# The touch-friendly surface for Wordtable: a square, phone-scalable grid of
# 225 stock Buttons built in code from ScrabbleBoard constants, tinted per
# premium square, with a center star, raised-outline pending tiles, and a
# last-move highlight. Layout only lives in res://scenes/table/board.tscn
# (AspectRatioContainer ratio 1.0 -> GridContainer columns 15); every cell
# is created here in _ready() so the count can never drift from SIZE.
#
# Entry points:
# - get_cell_count() -> int (225 when the scene built the grid).
# - get_cell(col, row) -> Button (null when out of bounds).
# - cell_premium(col, row) -> String (delegates to ScrabbleBoard.premium_at).
# - star_square() -> String ("H8", letter-first from ScrabbleBoard.CENTER).
# - set_tile(col, row, letter) -> bool / clear_tile(col, row): tile faces.
# - set_pending(cells) / clear_pending() / is_pending(col, row): staged
#   tiles render raised with a thick brass outline (grid layout cannot
#   z-lift a cell, so "raised" is outline + lightened background).
# - set_last_move(cells) / clear_last_move() / is_last_move(col, row):
#   highlight for the most recently committed move.
# Cells are Vector2i or [col, row] pairs; out-of-range entries are ignored.
#
# No networking: the view only emits cell_pressed(col, row) for later
# rack/hand wiring; it never touches server code.
#
# Run headless via res://tests/test_runner.gd (suite `board_scene`).
class_name BoardView
extends Control

signal cell_pressed(col: int, row: int)
signal cell_drop_received(col: int, row: int, payload: Dictionary)

const CELL_MIN := Vector2(24, 24)
const STAR_TEXT := "★"
const THEME_PATH := "res://themes/warm_club.tres"

var _cells: Array = []
var _pending := {}
var _last_move := {}
var _pal := {}


func _ready() -> void:
	_ensure_built()


func _ensure_built() -> void:
	if not _cells.is_empty():
		return
	var grid := get_node_or_null("Aspect/Grid") as GridContainer
	if grid == null:
		grid = get_node_or_null("%Grid") as GridContainer
	if grid == null:
		return
	grid.columns = ScrabbleBoard.SIZE
	_load_palette()
	for child in grid.get_children():
		child.queue_free()
	_cells.clear()
	for row: int in range(ScrabbleBoard.SIZE):
		for col: int in range(ScrabbleBoard.SIZE):
			var premium := ScrabbleBoard.premium_at(col, row)
			var btn := BoardCell.new()
			btn.col = col
			btn.row = row
			btn.focus_mode = Control.FOCUS_NONE
			btn.custom_minimum_size = CELL_MIN
			btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			btn.size_flags_vertical = Control.SIZE_EXPAND_FILL
			btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			btn.text = _square_label(premium)
			btn.tooltip_text = premium
			btn.add_theme_font_size_override("font_size", 12)
			btn.pressed.connect(_on_cell_pressed.bind(col, row))
			btn.cell_drop.connect(_on_cell_drop)
			grid.add_child(btn)
			_cells.append(btn)
			_refresh_cell(col, row)


func get_cell_count() -> int:
	_ensure_built()
	return _cells.size()


func get_cell(col: int, row: int) -> Button:
	_ensure_built()
	if not ScrabbleBoard.is_in_bounds(col, row):
		return null
	var idx := row * ScrabbleBoard.SIZE + col
	if idx < 0 or idx >= _cells.size():
		return null
	return _cells[idx] as Button


func cell_premium(col: int, row: int) -> String:
	return ScrabbleBoard.premium_at(col, row)


func star_square() -> String:
	return "%s%d" % [
		String.chr(65 + ScrabbleBoard.CENTER.x),
		ScrabbleBoard.CENTER.y + 1,
	]


func set_tile(col: int, row: int, letter: String) -> bool:
	var btn := get_cell(col, row)
	if btn == null:
		return false
	var face := letter.strip_edges().to_upper()
	if face.length() != 1:
		return false
	var ch := face.substr(0, 1)
	if ch < "A" or ch > "Z":
		return false
	btn.text = ch
	return true


func clear_tile(col: int, row: int) -> void:
	var btn := get_cell(col, row)
	if btn == null:
		return
	btn.text = _square_label(cell_premium(col, row))


func set_pending(cells: Array) -> void:
	var fresh := _normalize_cells(cells)
	for key in _pending.keys():
		if not fresh.has(key):
			_pending.erase(key)
			_refresh_cell((key as Vector2i).x, (key as Vector2i).y)
	for key in fresh.keys():
		if not _pending.has(key):
			_pending[key] = true
			_refresh_cell((key as Vector2i).x, (key as Vector2i).y)


func clear_pending() -> void:
	var old := _pending.keys()
	_pending.clear()
	for key in old:
		_refresh_cell((key as Vector2i).x, (key as Vector2i).y)


func is_pending(col: int, row: int) -> bool:
	return _pending.has(Vector2i(col, row))


func set_last_move(cells: Array) -> void:
	var fresh := _normalize_cells(cells)
	for key in _last_move.keys():
		if not fresh.has(key):
			_last_move.erase(key)
			_refresh_cell((key as Vector2i).x, (key as Vector2i).y)
	for key in fresh.keys():
		if not _last_move.has(key):
			_last_move[key] = true
			_refresh_cell((key as Vector2i).x, (key as Vector2i).y)


func clear_last_move() -> void:
	var old := _last_move.keys()
	_last_move.clear()
	for key in old:
		_refresh_cell((key as Vector2i).x, (key as Vector2i).y)


func is_last_move(col: int, row: int) -> bool:
	return _last_move.has(Vector2i(col, row))


func _on_cell_pressed(col: int, row: int) -> void:
	cell_pressed.emit(col, row)


func _on_cell_drop(col: int, row: int, payload: Dictionary) -> void:
	cell_drop_received.emit(col, row, payload)


func _square_label(premium: String) -> String:
	match premium:
		"STAR_DW":
			return STAR_TEXT
		"TW", "DW", "TL", "DL":
			return premium
	return ""


# Embedded fallback tints; adopts warm_club ivory/brass/felt when the theme
# file is present so the board matches the club palette without depending
# on the theme branch at parse time.
func _load_palette() -> void:
	_pal = {
		"plain": Color(0.953, 0.918, 0.827),
		"TW": Color(0.851, 0.302, 0.251),
		"DW": Color(0.949, 0.651, 0.553),
		"TL": Color(0.251, 0.451, 0.800),
		"DL": Color(0.553, 0.749, 0.898),
		"STAR_DW": Color(0.788, 0.635, 0.153),
		"ink": Color(0.290, 0.184, 0.114),
		"brass": Color(0.788, 0.635, 0.153),
		"felt": Color(0.114, 0.361, 0.247),
	}
	if not ResourceLoader.exists(THEME_PATH):
		return
	var theme := load(THEME_PATH) as Theme
	if theme == null:
		return
	if theme.has_color("ivory", "WarmClub"):
		_pal["plain"] = theme.get_color("ivory", "WarmClub")
	if theme.has_color("brass", "WarmClub"):
		_pal["STAR_DW"] = theme.get_color("brass", "WarmClub")
		_pal["brass"] = theme.get_color("brass", "WarmClub")
	if theme.has_color("felt", "WarmClub"):
		_pal["felt"] = theme.get_color("felt", "WarmClub")
	if theme.has_color("wood", "WarmClub"):
		_pal["ink"] = theme.get_color("wood", "WarmClub")


func _base_color(premium: String) -> Color:
	return _pal.get(premium, _pal.get("plain"))


func _refresh_cell(col: int, row: int) -> void:
	var btn := get_cell(col, row)
	if btn == null:
		return
	var premium := cell_premium(col, row)
	var bg := _base_color(premium)
	var border: Color = _pal.get("ink", Color(0.290, 0.184, 0.114))
	var width := 1
	if is_pending(col, row):
		bg = bg.lightened(0.3)
		border = _pal.get("brass", Color(0.788, 0.635, 0.153))
		width = 3
	elif is_last_move(col, row):
		bg = bg.lightened(0.12)
		border = _pal.get("felt", Color(0.114, 0.361, 0.247))
		width = 2
	var normal := _flat(bg, border, width)
	var hover := _flat(bg.lightened(0.08), border, width)
	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", hover)
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	btn.add_theme_color_override("font_color", _pal.get("ink", Color(0.290, 0.184, 0.114)))


func _flat(bg: Color, border: Color, width: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(width)
	sb.set_corner_radius_all(4)
	return sb


func _normalize_cells(cells: Array) -> Dictionary:
	var out := {}
	for entry in cells:
		var cell := _as_cell(entry)
		if ScrabbleBoard.is_in_bounds(cell.x, cell.y):
			out[cell] = true
	return out


func _as_cell(entry) -> Vector2i:
	if entry is Vector2i:
		return entry
	if entry is Array and (entry as Array).size() == 2:
		return Vector2i(int((entry as Array)[0]), int((entry as Array)[1]))
	return Vector2i(-1, -1)
