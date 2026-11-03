# Rack view: 7-slot tactile rack with live provisional score.
#
# The touch-friendly rack strip: exactly RACK_SIZE slot tiles plus a `+N`
# provisional label and Recall/Shuffle buttons. Tap-tile-then-tap-square
# and drag-and-drop converge on PlacementController.place_at; the label
# always formats the shared-validator total so planning feedback can never
# disagree with adjudication. Layout only lives in
# res://scenes/table/rack.tscn; the seven tiles are built here in code so
# the count can never drift from RACK_SIZE.
#
# Entry points:
# - get_slot_count() -> int (7 when the scene built the slots).
# - set_rack(faces: Array), get_tile(slot) -> RackTile.
# - bind_controller(ctrl: PlacementController), get_controller().
# - refresh_provisional(board, lexicon, controller) -> String.
# - get_provisional_label() -> String.
#
# No networking: the view only emits tile_chosen(slot) for later table
# wiring; it never touches server code.
#
# Run headless via res://tests/test_runner.gd (suite `placement`).
class_name RackView
extends Control

signal tile_chosen(slot: int)

const RACK_SIZE := 7
const THEME_PATH := "res://themes/warm_club.tres"

var _tiles: Array = []
var _controller: PlacementController = null
var _pal := {}
var _last_board = null
var _last_lexicon = null


func _ready() -> void:
	_ensure_built()


func _ensure_built() -> void:
	if not _tiles.is_empty():
		_ensure_wired()
		return
	var box := get_node_or_null("%Slots") as HBoxContainer
	if box == null:
		box = get_node_or_null("Slots") as HBoxContainer
	if box == null:
		return
	_load_palette()
	for child in box.get_children():
		child.queue_free()
	_tiles.clear()
	for i: int in range(RACK_SIZE):
		var tile := RackTile.new()
		tile.name = "Slot%d" % i
		tile.slot_idx = i
		tile.focus_mode = Control.FOCUS_NONE
		tile.custom_minimum_size = Vector2(48, 48)
		tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tile.size_flags_vertical = Control.SIZE_EXPAND_FILL
		tile.pressed.connect(_on_tile_pressed.bind(i))
		box.add_child(tile)
		_tiles.append(tile)
	_ensure_wired()
	_render_tiles()


func _ensure_wired() -> void:
	var recall := get_node_or_null("%Recall") as Button
	if recall == null:
		recall = get_node_or_null("Recall") as Button
	if recall != null and not recall.pressed.is_connected(_on_recall_pressed):
		recall.pressed.connect(_on_recall_pressed)
	var shuffle := get_node_or_null("%Shuffle") as Button
	if shuffle == null:
		shuffle = get_node_or_null("Shuffle") as Button
	if shuffle != null and not shuffle.pressed.is_connected(_on_shuffle_pressed):
		shuffle.pressed.connect(_on_shuffle_pressed)


func get_slot_count() -> int:
	_ensure_built()
	return _tiles.size()


func get_tile(slot: int) -> RackTile:
	_ensure_built()
	if slot < 0 or slot >= _tiles.size():
		return null
	return _tiles[slot] as RackTile


func get_controller() -> PlacementController:
	return _controller


func bind_controller(ctrl: PlacementController) -> void:
	_controller = ctrl
	_ensure_built()
	_render_tiles()


func set_rack(faces: Array) -> void:
	_ensure_built()
	if _controller == null:
		_controller = PlacementController.new()
	_controller.set_rack(faces)
	_render_tiles()


func get_provisional_label() -> String:
	_ensure_built()
	var label := get_node_or_null("%Provisional") as Label
	if label == null:
		label = get_node_or_null("Provisional") as Label
	if label == null:
		return ""
	return label.text


func refresh_provisional(board, lexicon, controller: PlacementController = null) -> String:
	_ensure_built()
	var ctrl := controller if controller != null else _controller
	if ctrl == null:
		return get_provisional_label()
	_last_board = board
	_last_lexicon = lexicon
	var label_text := ctrl.provisional_label(board, lexicon)
	_set_provisional_text(label_text)
	var res := ctrl.provisional(board, lexicon)
	if bool(res.get("ok", false)):
		print("provisional=+%d" % int(res.get("total", 0)))
	return label_text


func _on_tile_pressed(slot: int) -> void:
	_ensure_built()
	if _controller != null:
		_controller.select_slot(slot)
	tile_chosen.emit(slot)


func _on_recall_pressed() -> void:
	if _controller == null:
		return
	_controller.recall()
	_render_tiles()
	if _last_board != null:
		refresh_provisional(_last_board, _last_lexicon, _controller)
	else:
		_set_provisional_text("+0")


func _on_shuffle_pressed() -> void:
	if _controller == null:
		return
	_controller.shuffle()
	_render_tiles()


func _render_tiles() -> void:
	if _tiles.is_empty() or _controller == null:
		return
	for i: int in range(mini(_tiles.size(), RACK_SIZE)):
		var tile := _tiles[i] as RackTile
		if tile == null:
			continue
		var face: Dictionary = _controller.slot_face(i)
		tile.slot_idx = i
		tile.set_face(str(face.get("letter", "")), bool(face.get("is_blank", false)))


func _set_provisional_text(value: String) -> void:
	var label := get_node_or_null("%Provisional") as Label
	if label == null:
		label = get_node_or_null("Provisional") as Label
	if label != null:
		label.text = value


# Embedded fallback colors; adopts warm_club ivory/brass when the theme
# file is present so the rack matches the club palette without depending
# on the theme branch at parse time.
func _load_palette() -> void:
	_pal = {
		"ivory": Color(0.953, 0.918, 0.827),
		"brass": Color(0.788, 0.635, 0.153),
		"ink": Color(0.290, 0.184, 0.114),
		"felt": Color(0.114, 0.361, 0.247),
	}
	if not ResourceLoader.exists(THEME_PATH):
		return
	var theme := ResourceLoader.load(THEME_PATH) as Theme
	if theme == null:
		return
	for key in ["ivory", "brass", "felt", "wood"]:
		if theme.has_color(key, "WarmClub"):
			_pal[key] = theme.get_color(key, "WarmClub")
	if _pal.has("wood"):
		_pal["ink"] = _pal["wood"]
