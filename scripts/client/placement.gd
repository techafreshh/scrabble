# Placement controller: pure-logic rack plus pending tiles with live scoring.
#
# Owns rack faces, pendings with origin slots, blank face overrides, tap
# selection, recall/shuffle, and provisional scoring that delegates 100% to
# ScrabbleRules.validate_placement -- it never reimplements premiums,
# linkage, or dictionary checks.
#
# Entry points:
# - set_rack(faces: Array): 7 slots of String or {letter, is_blank} dicts.
# - slot_count() -> int (always RACK_SIZE).
# - select_slot(i: int) -> bool / selected_slot() -> int.
# - can_place_at(col, row) -> bool / place_at(col, row) -> bool.
# - remove_at(col, row) -> bool / recall() -> int / shuffle().
# - pending_count() -> int, provisional(board, lexicon) -> Dictionary.
# - provisional_label(board, lexicon) -> String ("+N", reason, or "+0").
#
# No scene deps: headless-testable via res://tests/test_runner.gd
# (suite `placement`).
class_name PlacementController
extends RefCounted

const RACK_SIZE := 7

var _faces: Array = []
var _pendings: Array = []
var _selected := -1
var _blanks := {}
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	_faces.clear()
	for i: int in range(RACK_SIZE):
		_faces.append({"letter": "", "is_blank": false})
	_pendings.clear()
	_selected = -1
	_blanks.clear()
	_rng.randomize()


func set_rack(faces: Array) -> void:
	_faces.clear()
	for i: int in range(RACK_SIZE):
		if i < faces.size():
			_faces.append(_normalize_face(faces[i]))
		else:
			_faces.append({"letter": "", "is_blank": false})
	_pendings.clear()
	_blanks.clear()
	_selected = -1


func slot_count() -> int:
	return RACK_SIZE


func get_faces() -> Array:
	return _faces.duplicate(true)


func slot_face(slot: int) -> Dictionary:
	if slot < 0 or slot >= RACK_SIZE:
		return {"letter": "", "is_blank": false}
	return (_faces[slot] as Dictionary).duplicate()


func slot_letter(slot: int) -> String:
	return str(slot_face(slot).get("letter", ""))


func is_slot_empty(slot: int) -> bool:
	if slot < 0 or slot >= RACK_SIZE:
		return true
	return str((_faces[slot] as Dictionary).get("letter", "")) == "" \
		and not bool((_faces[slot] as Dictionary).get("is_blank", false))


func is_slot_placed(slot: int) -> bool:
	for p in _pendings:
		if int((p as Dictionary).get("slot", -1)) == slot:
			return true
	return false


func select_slot(i: int) -> bool:
	if i < 0 or i >= RACK_SIZE:
		return false
	if is_slot_empty(i):
		return false
	if is_slot_placed(i):
		return false
	_selected = i
	return true


func selected_slot() -> int:
	return _selected


func can_place_at(col: int, row: int) -> bool:
	if not ScrabbleBoard.is_in_bounds(col, row):
		return false
	for p in _pendings:
		if int((p as Dictionary).get("col", -999)) == col \
				and int((p as Dictionary).get("row", -999)) == row:
			return false
	return true


func place_at(col: int, row: int) -> bool:
	if _selected < 0 or _selected >= RACK_SIZE:
		return false
	if not can_place_at(col, row):
		return false
	if is_slot_empty(_selected):
		return false
	if is_slot_placed(_selected):
		return false
	var face: Dictionary = _faces[_selected]
	var letter := str(face.get("letter", ""))
	var blank := bool(face.get("is_blank", false))
	_pendings.append({
		"col": col,
		"row": row,
		"letter": letter,
		"blank": blank,
		"slot": _selected,
	})
	if blank and letter != "":
		_blanks[Vector2i(col, row)] = letter
	_faces[_selected] = {"letter": "", "is_blank": false}
	_selected = -1
	return true


func remove_at(col: int, row: int) -> bool:
	for i: int in range(_pendings.size()):
		var p: Dictionary = _pendings[i]
		if int(p.get("col", -999)) == col and int(p.get("row", -999)) == row:
			var slot := int(p.get("slot", -1))
			if slot >= 0 and slot < RACK_SIZE:
				_faces[slot] = {
					"letter": str(p.get("letter", "")),
					"is_blank": bool(p.get("blank", false)),
				}
			_pendings.remove_at(i)
			_blanks.erase(Vector2i(col, row))
			_blanks.erase("%d,%d" % [col, row])
			return true
	return false


func recall() -> int:
	var n := _pendings.size()
	for p in _pendings:
		var slot := int((p as Dictionary).get("slot", -1))
		if slot >= 0 and slot < RACK_SIZE:
			_faces[slot] = {
				"letter": str((p as Dictionary).get("letter", "")),
				"is_blank": bool((p as Dictionary).get("blank", false)),
			}
	_pendings.clear()
	_blanks.clear()
	_selected = -1
	return n


func shuffle() -> void:
	var pending_slots := {}
	for p in _pendings:
		pending_slots[int((p as Dictionary).get("slot", -1))] = true
	var indices: Array = []
	for i: int in range(RACK_SIZE):
		if not pending_slots.has(i):
			indices.append(i)
	var values: Array = []
	for i in indices:
		values.append((_faces[i] as Dictionary).duplicate())
	for i: int in range(values.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var tmp: Dictionary = values[i]
		values[i] = values[j]
		values[j] = tmp
	for k: int in range(indices.size()):
		_faces[int(indices[k])] = values[k]


func pending_count() -> int:
	return _pendings.size()


func get_pendings() -> Array:
	return _pendings.duplicate(true)


func pending_cells() -> Array:
	var out: Array = []
	for p in _pendings:
		out.append(Vector2i(int((p as Dictionary).get("col", -1)), int((p as Dictionary).get("row", -1))))
	return out


func provisional(board, lexicon) -> Dictionary:
	var placements: Array = []
	for p in _pendings:
		placements.append({
			"col": int((p as Dictionary).get("col", -1)),
			"row": int((p as Dictionary).get("row", -1)),
			"letter": str((p as Dictionary).get("letter", "")),
			"blank": bool((p as Dictionary).get("blank", false)),
		})
	return ScrabbleRules.validate_placement(board, [], placements, _blanks, lexicon)


func provisional_label(board, lexicon) -> String:
	if _pendings.is_empty():
		return "+0"
	var res := provisional(board, lexicon)
	if bool(res.get("ok", false)):
		return "+%d" % int(res.get("total", 0))
	return str(res.get("reason", ""))


func _normalize_face(raw) -> Dictionary:
	if raw is String:
		var s := str(raw).strip_edges().to_upper()
		if s == "":
			return {"letter": "", "is_blank": true}
		if s.length() == 1 and s >= "A" and s <= "Z":
			return {"letter": s, "is_blank": false}
		return {"letter": "", "is_blank": false}
	if raw is Dictionary:
		var d: Dictionary = raw
		var face := str(d.get("letter", "")).strip_edges().to_upper()
		var b := bool(d.get("is_blank", d.get("blank", face == "")))
		if face == "":
			if b:
				return {"letter": "", "is_blank": true}
			return {"letter": "", "is_blank": false}
		if face.length() == 1 and face >= "A" and face <= "Z":
			return {"letter": face, "is_blank": b}
		return {"letter": "", "is_blank": false}
	return {"letter": "", "is_blank": false}
