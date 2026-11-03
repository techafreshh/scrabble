# Wordtable blank picker: A-Z letter choice overlay for blank tiles.
#
# The forgiving blank flow: dropping a blank opens this overlay with exactly
# 26 letter buttons (A-Z) built here in code so the count can never drift;
# layout only lives in res://scenes/table/blank_picker.tscn (%Letters
# GridContainer with columns 13 for two tidy rows A-M / N-Z).
# Local verdict only: the view emits letter_chosen(letter) / picker_cancelled
# for later table wiring; it never touches server code.
#
# Entry points:
# - get_option_count() -> int (26 when the scene built the grid).
# - get_options() -> Array (A-Z faces).
# - open_for(col, row) / choose(letter) -> bool / cancel() / is_open().
# - get_cell() -> Vector2i (the square the open pick is for).
#
# Run headless via res://tests/test_runner.gd (suite `blank_feedback`).
class_name BlankPicker
extends Control

signal letter_chosen(letter: String)
signal picker_cancelled

const LETTERS: Array = [
	"A", "B", "C", "D", "E", "F", "G",
	"H", "I", "J", "K", "L", "M", "N",
	"O", "P", "Q", "R", "S", "T", "U",
	"V", "W", "X", "Y", "Z",
]

var _buttons: Array = []
var _cell := Vector2i(-1, -1)
var _open := false
var _built := false


func _ready() -> void:
	_ensure_built()


func _ensure_built() -> void:
	if _built:
		return
	var grid := get_node_or_null("%Letters") as GridContainer
	if grid == null:
		grid = get_node_or_null("Letters") as GridContainer
	if grid == null:
		return
	grid.columns = 13
	for child in grid.get_children():
		child.queue_free()
	_buttons.clear()
	for face in LETTERS:
		var btn := Button.new()
		btn.name = "Letter%s" % face
		btn.text = str(face)
		btn.focus_mode = Control.FOCUS_NONE
		btn.custom_minimum_size = Vector2(24, 24)
		btn.pressed.connect(_on_letter_pressed.bind(str(face)))
		grid.add_child(btn)
		_buttons.append(btn)
	_built = true


func get_option_count() -> int:
	_ensure_built()
	return _buttons.size()


func get_options() -> Array:
	return LETTERS.duplicate()


func open_for(col: int, row: int) -> bool:
	_ensure_built()
	_cell = Vector2i(col, row)
	_open = true
	visible = true
	return true


func choose(letter: String) -> bool:
	if not _open:
		return false
	var face := letter.strip_edges().to_upper()
	if face.length() != 1 or face < "A" or face > "Z":
		return false
	_open = false
	visible = false
	letter_chosen.emit(face)
	return true


func cancel() -> void:
	_open = false
	visible = false
	picker_cancelled.emit()


func is_open() -> bool:
	return _open


func get_cell() -> Vector2i:
	return _cell


func _on_letter_pressed(letter: String) -> void:
	choose(letter)
