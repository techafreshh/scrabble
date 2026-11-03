# Board cell: drop target Button for tactile placement.
#
# A stock-Button-compatible grid cell carrying its (col, row) plus an
# optional accept_drop Callable(col, row, payload) -> bool. By default it
# accepts any Dictionary payload holding a single A-Z face letter (or an
# unassigned blank) when the cell is in bounds. Drops emit
# cell_drop(col, row, payload) for RackView/table wiring.
class_name BoardCell
extends Button

signal cell_drop(col: int, row: int, payload: Dictionary)

var col := -1
var row := -1
var accept_drop := Callable()


func _can_drop_data(_at: Vector2, data: Variant) -> bool:
	if accept_drop.is_valid():
		return bool(accept_drop.call(col, row, data))
	return _default_accept(col, row, data)


func _drop_data(_at: Vector2, data: Variant) -> void:
	var payload := {}
	if data is Dictionary:
		payload = (data as Dictionary).duplicate()
	cell_drop.emit(col, row, payload)


func _default_accept(c: int, r: int, data: Variant) -> bool:
	if not ScrabbleBoard.is_in_bounds(c, r):
		return false
	if not (data is Dictionary):
		return false
	var d: Dictionary = data
	if not d.has("letter"):
		return false
	var face := str(d.get("letter", "")).strip_edges().to_upper()
	var blank := bool(d.get("is_blank", d.get("blank", false)))
	if face == "" and blank:
		return true
	if face.length() != 1:
		return false
	return face >= "A" and face <= "Z"
