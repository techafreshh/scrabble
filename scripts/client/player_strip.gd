# Wordtable player strip: 2-4 seat presence bar (name, score, tile count).
#
# The top strip for the table: one plaque per seated player showing name,
# score and rack tile count, with a brass active glow on the current turn
# and a timer ring (a settable 0-1 fraction only; no countdown here).
# Layout only lives in res://scenes/table/player_strip.tscn (a full-rect
# Control root with an HBoxContainer named Plaques); every plaque is built
# here in code so the count can never drift from set_players().
#
# Entry points:
# - set_players(players: Array): dicts {name, score, tiles}, clamped 2-4.
# - set_active(idx: int) / get_active() -> int (OOB indices are ignored).
# - get_plaque_count() -> int, get_score(i: int), get_tile_count(i: int).
# - set_time_fraction(f: float): clamps 0-1 onto the active plaque's ring.
#
# No networking: the strip only emits plaque_pressed(index) for later
# turn/clock wiring; it never touches server code.
#
# Run headless via res://tests/test_runner.gd (suite `strip_chat`).
class_name PlayerStrip
extends Control

signal plaque_pressed(index: int)

const THEME_PATH := "res://themes/warm_club.tres"

var _plaques: Array = []
var _active := 0
var _pal := {}


func _ready() -> void:
	_ensure_built()


func _ensure_built() -> void:
	if not _plaques.is_empty():
		return
	var box := get_node_or_null("%Plaques") as HBoxContainer
	if box == null:
		box = get_node_or_null("Plaques") as HBoxContainer
	if box == null:
		return
	_load_palette()
	for child in box.get_children():
		child.queue_free()


func get_plaque_count() -> int:
	_ensure_built()
	return _plaques.size()


func get_active() -> int:
	return _active


func get_score(i: int) -> int:
	_ensure_built()
	if i < 0 or i >= _plaques.size():
		return 0
	return int((_plaques[i] as Dictionary).get("score", 0))


func get_tile_count(i: int) -> int:
	_ensure_built()
	if i < 0 or i >= _plaques.size():
		return 0
	return int((_plaques[i] as Dictionary).get("tiles", 0))


func get_player_name(i: int) -> String:
	_ensure_built()
	if i < 0 or i >= _plaques.size():
		return ""
	return str((_plaques[i] as Dictionary).get("name", ""))


func get_plaque(i: int) -> PanelContainer:
	_ensure_built()
	if i < 0 or i >= _plaques.size():
		return null
	return (_plaques[i] as Dictionary).get("node") as PanelContainer


func set_players(players: Array) -> void:
	_ensure_built()
	var box := get_node_or_null("%Plaques") as HBoxContainer
	if box == null:
		box = get_node_or_null("Plaques") as HBoxContainer
	if box == null:
		return
	_load_palette()
	for child in box.get_children():
		child.queue_free()
	_plaques.clear()
	var entries := players.slice(0, 4)
	while entries.size() < 2:
		entries.append({"name": "—", "score": 0, "tiles": 0})
	for i: int in range(entries.size()):
		var entry: Dictionary = _as_entry(entries[i])
		var plaque := PanelContainer.new()
		plaque.name = "Plaque%d" % i
		plaque.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var inner := VBoxContainer.new()
		inner.name = "Body"
		inner.add_theme_constant_override("separation", 2)
		plaque.add_child(inner)
		var name_label := Label.new()
		name_label.name = "Name"
		name_label.text = str(entry.get("name", ""))
		name_label.add_theme_color_override("font_color", _pal.get("ink"))
		inner.add_child(name_label)
		var score_label := Label.new()
		score_label.name = "Score"
		score_label.text = "Score: %d" % int(entry.get("score", 0))
		score_label.add_theme_color_override("font_color", _pal.get("ink"))
		inner.add_child(score_label)
		var tiles_label := Label.new()
		tiles_label.name = "Tiles"
		tiles_label.text = "Tiles: %d" % int(entry.get("tiles", 0))
		tiles_label.add_theme_color_override("font_color", _pal.get("ink"))
		inner.add_child(tiles_label)
		var ring := ProgressBar.new()
		ring.name = "TimerRing"
		ring.min_value = 0.0
		ring.max_value = 1.0
		ring.step = 0.01
		ring.value = 0.0
		ring.show_percentage = false
		ring.custom_minimum_size = Vector2(8, 8)
		inner.add_child(ring)
		var idx := i
		plaque.gui_input.connect(_on_plaque_input.bind(idx))
		box.add_child(plaque)
		_plaques.append({
			"node": plaque,
			"ring": ring,
			"name": str(entry.get("name", "")),
			"score": int(entry.get("score", 0)),
			"tiles": int(entry.get("tiles", 0)),
		})
	_active = 0
	_refresh_all()


func set_active(idx: int) -> void:
	_ensure_built()
	if idx < 0 or idx >= _plaques.size():
		return
	_active = idx
	_refresh_all()


func set_time_fraction(f: float) -> void:
	_ensure_built()
	var ring := get_timer_ring(_active)
	if ring == null:
		return
	ring.value = clampf(f, 0.0, 1.0)


func get_timer_ring(i: int) -> ProgressBar:
	_ensure_built()
	if i < 0 or i >= _plaques.size():
		return null
	var stored := (_plaques[i] as Dictionary).get("ring") as ProgressBar
	if stored != null and is_instance_valid(stored):
		return stored
	var plaque := get_plaque(i)
	if plaque == null:
		return null
	return plaque.get_node_or_null("Body/TimerRing") as ProgressBar


func _on_plaque_input(event: InputEvent, idx: int) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			plaque_pressed.emit(idx)


# Embedded fallback colors; adopts warm_club ivory/brass when the theme
# file is present so the strip matches the club palette without depending
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


func _refresh_all() -> void:
	for i: int in range(_plaques.size()):
		var plaque := (_plaques[i] as Dictionary).get("node") as PanelContainer
		if plaque == null:
			continue
		var ring := plaque.get_node_or_null("Body/TimerRing") as ProgressBar
		var is_active: bool = i == _active
		if ring != null:
			ring.visible = is_active
		var sb := StyleBoxFlat.new()
		if is_active:
			sb.bg_color = (_pal.get("ivory") as Color).lightened(0.05)
			sb.border_color = _pal.get("brass")
			sb.set_border_width_all(3)
		else:
			sb.bg_color = _pal.get("ivory")
			sb.border_color = _pal.get("felt")
			sb.set_border_width_all(1)
		sb.set_corner_radius_all(6)
		plaque.add_theme_stylebox_override("panel", sb)


func _as_entry(raw) -> Dictionary:
	var out := {"name": "—", "score": 0, "tiles": 0}
	if raw is Dictionary:
		var d := raw as Dictionary
		out["name"] = str(d.get("name", out["name"])) .substr(0, 16)
		out["score"] = int(d.get("score", 0))
		out["tiles"] = int(d.get("tiles", 0))
	elif raw is String:
		out["name"] = str(raw).substr(0, 16)
	return out
