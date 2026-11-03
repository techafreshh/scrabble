# Wordtable lobby view: room code, seats, bot/timer flags, gated Start.
#
# The pre-game waiting room: shows the 4-char room code with a copyable
# `wordtable://join?code=XXXX` link, seat plaques built in code for 2-4
# players (the same code-built-count-can-never-drift idiom as PlayerStrip),
# per-seat bot toggle placeholder flags (display only: the seat still plays
# as a hot-seat human, no bot logic in this lap), a timer toggle that
# defaults ON (stored flag only, no countdown here), and a Start button
# that stays disabled until 2+ seats are present.
#
# Entry points:
# - LobbyView.new_room_code() -> String (static, 4 uppercase A-Z0-9 chars).
# - get_room_code()/set_room_code(code), get_join_link()/copy_link().
# - set_seats(names)/add_seat(name)/seat_count()/get_seat_name(i).
# - toggle_bot(i)/is_bot(i) (placeholder flags only).
# - set_timer_on(value)/is_timer_on() (default true).
# - can_start() (true iff 2+ seats) / request_start() -> bool.
#
# No networking: the view only emits seat_changed and start_pressed for
# later rooms.gd binding; it never touches server code.
#
# Run headless via res://tests/test_runner.gd (suite `hotseat`).
class_name LobbyView
extends Control

signal seat_changed
signal start_pressed

const MIN_SEATS := 2
const MAX_SEATS := 4
const MAX_NAME_LEN := 16
const CODE_LEN := 4
const CODE_ALPHABET := "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
const JOIN_SCHEME := "wordtable://join?code="

var _room_code := ""
var _seats: Array = []
var _timer_on := true
var _built := false


func _init() -> void:
	_room_code = new_room_code()


func _ready() -> void:
	_ensure_built()
	_refresh_chrome()



static func new_room_code() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var out := ""
	for i: int in range(CODE_LEN):
		out += CODE_ALPHABET[rng.randi_range(0, CODE_ALPHABET.length() - 1)]
	return out


static func is_valid_code(raw: String) -> bool:
	var code := raw.strip_edges().to_upper()
	if code.length() != CODE_LEN:
		return false
	for i: int in range(code.length()):
		if CODE_ALPHABET.find(code.substr(i, 1)) == -1:
			return false
	return true


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
	var copy_btn := get_node_or_null("%CopyLinkButton") as Button
	if copy_btn == null:
		copy_btn = get_node_or_null("CopyLinkButton") as Button
	var timer_toggle := get_node_or_null("%TimerToggle") as BaseButton
	if timer_toggle == null:
		timer_toggle = get_node_or_null("TimerToggle") as BaseButton
	if seat_list == null and start_btn == null and copy_btn == null and timer_toggle == null:
		var code_label := get_node_or_null("%CodeLabel") as Label
		if code_label == null:
			code_label = get_node_or_null("CodeLabel") as Label
		if code_label == null:
			return
	if copy_btn != null and not copy_btn.pressed.is_connected(_on_copy_link):
		copy_btn.pressed.connect(_on_copy_link)
	if start_btn != null and not start_btn.pressed.is_connected(_on_start_button):
		start_btn.pressed.connect(_on_start_button)
	if timer_toggle != null:
		timer_toggle.set_pressed_no_signal(_timer_on)
		if not timer_toggle.toggled.is_connected(_on_timer_toggled):
			timer_toggle.toggled.connect(_on_timer_toggled)
	_built = true
	_refresh_chrome()


func get_room_code() -> String:
	return _room_code


func set_room_code(raw: String) -> void:
	_room_code = raw.strip_edges().to_upper()
	_refresh_chrome()


func get_join_link() -> String:
	return JOIN_SCHEME + _room_code


func copy_link() -> String:
	var link := get_join_link()
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		DisplayServer.clipboard_set(link)
	return link


func set_seats(names: Array) -> void:
	_seats.clear()
	for raw in names.slice(0, MAX_SEATS):
		_seats.append({"name": _clean_name(raw), "is_bot": false})
	_refresh_chrome()


func add_seat(raw_name: String) -> bool:
	if _seats.size() >= MAX_SEATS:
		return false
	_seats.append({"name": _clean_name(raw_name), "is_bot": false})
	seat_changed.emit()
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


func is_bot(i: int) -> bool:
	if i < 0 or i >= _seats.size():
		return false
	return bool((_seats[i] as Dictionary).get("is_bot", false))


func toggle_bot(i: int) -> bool:
	if i < 0 or i >= _seats.size():
		return false
	(_seats[i] as Dictionary)["is_bot"] = not bool((_seats[i] as Dictionary).get("is_bot", false))
	seat_changed.emit()
	_refresh_chrome()
	return bool((_seats[i] as Dictionary).get("is_bot", false))


func is_timer_on() -> bool:
	return _timer_on


func set_timer_on(value: bool) -> void:
	_timer_on = value
	_refresh_chrome()


func can_start() -> bool:
	return _seats.size() >= MIN_SEATS


func request_start() -> bool:
	if not can_start():
		return false
	start_pressed.emit()
	return true


func _on_copy_link() -> void:
	copy_link()


func _on_start_button() -> void:
	request_start()


func _on_timer_toggled(pressed: bool) -> void:
	_timer_on = pressed
	_refresh_chrome()


# Seat plaques are built here in code so the row count can never drift
# from set_seats()/add_seat() (the PlayerStrip idiom).
func _refresh_chrome() -> void:
	var code_label := get_node_or_null("%CodeLabel") as Label
	if code_label == null:
		code_label = get_node_or_null("CodeLabel") as Label
	if code_label != null:
		code_label.text = _room_code
	var start_btn := get_node_or_null("%StartButton") as Button
	if start_btn == null:
		start_btn = get_node_or_null("StartButton") as Button
	if start_btn != null:
		start_btn.disabled = not can_start()
	var timer_toggle := get_node_or_null("%TimerToggle") as BaseButton
	if timer_toggle == null:
		timer_toggle = get_node_or_null("TimerToggle") as BaseButton
	if timer_toggle != null:
		timer_toggle.set_pressed_no_signal(_timer_on)
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
		var label := Label.new()
		label.name = "Name"
		label.text = str(entry.get("name", ""))
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		var bot := CheckButton.new()
		bot.name = "BotToggle"
		bot.text = "Bot"
		bot.button_pressed = bool(entry.get("is_bot", false))
		var idx := i
		bot.toggled.connect(_on_seat_bot_toggled.bind(idx))
		row.add_child(bot)
		seat_list.add_child(row)


func _on_seat_bot_toggled(pressed: bool, idx: int) -> void:
	if idx < 0 or idx >= _seats.size():
		return
	(_seats[idx] as Dictionary)["is_bot"] = pressed
	seat_changed.emit()


func _clean_name(raw) -> String:
	var text := str(raw).strip_edges().substr(0, MAX_NAME_LEN).strip_edges()
	if text.is_empty():
		text = "Player"
	return text
