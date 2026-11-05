# Wordtable offline seat picker: 2-4 named seats with optional bot flags.
#
# The Play-now setup view: editable seat names (LineEdit, 16-char cap) plus
# a per-seat Bot CheckButton, mirroring the LobbyView seat/bot/gate idiom
# (code-built rows so count can never drift, 2-4 clamp, 16-char trim,
# seat_changed/play signals, can_start gate). Unlike the lobby it has no
# room code, join link, or timer toggle: offline play never touches Net.
#
# Entry points:
# - set_seats(names)/add_seat(name)/remove_last_seat()/seat_count().
# - set_seat_name(i, name)/get_seat_name(i)/get_seat_names().
# - toggle_bot(i)/set_bot(i, value)/is_bot(i)/get_bot_flags().
# - can_start() (true iff 2+ seats) / request_play_now() -> bool.
# - set_status(text)/get_status().
#
# No networking: the view only emits seats_changed and
# play_now_pressed(names, bots) for WordBoot offline binding.
#
# Run headless via res://tests/test_runner.gd (suite `playnow`).
class_name PlayNowSetup
extends Control

signal seats_changed
signal play_now_pressed(names: Array, bots: Array)

const MIN_SEATS := 2
const MAX_SEATS := 4
const MAX_NAME_LEN := 16

var _seats: Array = []
var _status := ""
var _built := false


func _ready() -> void:
	_ensure_built()
	_refresh_chrome()


# Wire-only and idempotent: never refreshes here so getters can call it
# safely without re-entrancy. Mutators refresh explicitly.
func _ensure_built() -> void:
	if _built:
		return
	var seat_list := get_node_or_null("%SeatList") as VBoxContainer
	if seat_list == null:
		seat_list = get_node_or_null("SeatList") as VBoxContainer
	var start_btn := get_node_or_null("%StartButton") as Button
	if start_btn == null:
		start_btn = get_node_or_null("StartButton") as Button
	if seat_list == null and start_btn == null:
		var status_label := get_node_or_null("%StatusLabel") as Label
		if status_label == null:
			status_label = get_node_or_null("StatusLabel") as Label
		if status_label == null:
			return
	if start_btn != null and not start_btn.pressed.is_connected(_on_start_button):
		start_btn.pressed.connect(_on_start_button)
	_built = true
	_refresh_chrome()


func set_seats(names: Array) -> void:
	_seats.clear()
	for raw in names.slice(0, MAX_SEATS):
		_seats.append({"name": _clean_name(raw), "is_bot": false})
	seat_changed_safe()
	_refresh_chrome()


func add_seat(raw_name: String) -> bool:
	if _seats.size() >= MAX_SEATS:
		return false
	_seats.append({"name": _clean_name(raw_name), "is_bot": false})
	seats_changed.emit()
	_refresh_chrome()
	return true


func remove_last_seat() -> bool:
	if _seats.size() <= MIN_SEATS:
		return false
	_seats.pop_back()
	seats_changed.emit()
	_refresh_chrome()
	return true


func seat_count() -> int:
	return _seats.size()


func get_seat_name(i: int) -> String:
	if i < 0 or i >= _seats.size():
		return ""
	return str((_seats[i] as Dictionary).get("name", ""))


func get_seat_names() -> Array:
	var out: Array = []
	for entry in _seats:
		out.append(str((entry as Dictionary).get("name", "")))
	return out


func set_seat_name(i: int, raw_name: String) -> bool:
	if i < 0 or i >= _seats.size():
		return false
	(_seats[i] as Dictionary)["name"] = _clean_name(raw_name)
	seats_changed.emit()
	_refresh_chrome()
	return true


func is_bot(i: int) -> bool:
	if i < 0 or i >= _seats.size():
		return false
	return bool((_seats[i] as Dictionary).get("is_bot", false))


func get_bot_flags() -> Array:
	var out: Array = []
	for entry in _seats:
		out.append(bool((entry as Dictionary).get("is_bot", false)))
	return out


func set_bot(i: int, value: bool) -> bool:
	if i < 0 or i >= _seats.size():
		return false
	(_seats[i] as Dictionary)["is_bot"] = value
	seats_changed.emit()
	_refresh_chrome()
	return true


func toggle_bot(i: int) -> bool:
	if i < 0 or i >= _seats.size():
		return false
	(_seats[i] as Dictionary)["is_bot"] = not bool((_seats[i] as Dictionary).get("is_bot", false))
	seats_changed.emit()
	_refresh_chrome()
	return bool((_seats[i] as Dictionary).get("is_bot", false))


func can_start() -> bool:
	return _seats.size() >= MIN_SEATS


func request_play_now() -> bool:
	if not can_start():
		return false
	play_now_pressed.emit(get_seat_names(), get_bot_flags())
	return true


func get_status() -> String:
	return _status


func set_status(text: String) -> void:
	_status = text
	var label := get_node_or_null("%StatusLabel") as Label
	if label == null:
		label = get_node_or_null("StatusLabel") as Label
	if label != null:
		label.text = text


func _on_start_button() -> void:
	request_play_now()


func _on_name_changed(new_text: String, idx: int) -> void:
	if idx < 0 or idx >= _seats.size():
		return
	(_seats[idx] as Dictionary)["name"] = _clean_name(new_text)
	seats_changed.emit()


func _on_seat_bot_toggled(pressed: bool, idx: int) -> void:
	if idx < 0 or idx >= _seats.size():
		return
	(_seats[idx] as Dictionary)["is_bot"] = pressed
	seats_changed.emit()


# Emits seats_changed only when someone is listening-safe: direct emit is
# fine sceneless (no listeners), this helper just keeps set_seats quiet-safe.
func seat_changed_safe() -> void:
	seats_changed.emit()


# Seat rows are built here in code so the row count can never drift from
# set_seats()/add_seat() (the PlayerStrip idiom).
func _refresh_chrome() -> void:
	var status_label := get_node_or_null("%StatusLabel") as Label
	if status_label == null:
		status_label = get_node_or_null("StatusLabel") as Label
	if status_label != null and status_label.text != _status and _status != "":
		status_label.text = _status
	var start_btn := get_node_or_null("%StartButton") as Button
	if start_btn == null:
		start_btn = get_node_or_null("StartButton") as Button
	if start_btn != null:
		start_btn.disabled = not can_start()
	_rebuild_seat_rows()


func _rebuild_seat_rows() -> void:
	var seat_list := get_node_or_null("%SeatList") as VBoxContainer
	if seat_list == null:
		seat_list = get_node_or_null("SeatList") as VBoxContainer
	if seat_list == null:
		return
	for child in seat_list.get_children():
		child.queue_free()
	for i: int in range(_seats.size()):
		var entry := _seats[i] as Dictionary
		var row := HBoxContainer.new()
		row.name = "Seat%d" % i
		row.add_theme_constant_override("separation", 8)
		var field := LineEdit.new()
		field.name = "Name"
		field.text = str(entry.get("name", ""))
		field.max_length = MAX_NAME_LEN
		field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var idx := i
		field.text_changed.connect(_on_name_changed.bind(idx))
		row.add_child(field)
		var bot := CheckButton.new()
		bot.name = "BotToggle"
		bot.text = "Bot"
		bot.button_pressed = bool(entry.get("is_bot", false))
		bot.toggled.connect(_on_seat_bot_toggled.bind(idx))
		row.add_child(bot)
		seat_list.add_child(row)


func _clean_name(raw) -> String:
	var text := str(raw).strip_edges().substr(0, MAX_NAME_LEN).strip_edges()
	if text.is_empty():
		text = "Player"
	return text
