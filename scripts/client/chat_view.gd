# Wordtable corner chat: bubble with unread badge, input, three-tap emotes.
#
# The table-corner chirp box: a bubble button showing an unread-count badge,
# opening a panel with a session log, a capped text input (200 chars) plus
# send button, and a row of exactly three emote buttons (PRD trio).
# Local echo only: sent text/emotes append "You: <...>" to the session log
# and emit signals; networked relay is deferred to a later lap.
# Layout only lives in res://scenes/table/chat.tscn; the three emote
# buttons are built here in code so the count can never drift.
#
# Entry points:
# - send_local(text: String) -> bool (false on empty; caps at 200 chars).
# - send_emote(idx: int) -> bool (false on OOB index).
# - get_emote_count() -> int, get_last_message() -> String.
# - get_unread() -> int (bumps only while the panel is hidden).
# - open_panel() / close_panel() (open zeroes unread), is_panel_open().
#
# No networking: the view only emits message_sent(text) and
# emote_sent(emote_id) for later rooms.gd binding; it never touches
# server code.
#
# Run headless via res://tests/test_runner.gd (suite `strip_chat`).
class_name ChatView
extends Control

signal message_sent(text: String)
signal emote_sent(emote_id: int)

const EMOTES: Array = ["👍", "😂", "😭"]
const MAX_TEXT_LEN := 200
const MAX_NAME_LEN := 16

var _log: PackedStringArray = PackedStringArray()
var _unread := 0
var _panel_open := false
var _built := false


func _ready() -> void:
	_ensure_built()


func _ensure_built() -> void:
	if _built:
		return
	var bubble := get_node_or_null("%Bubble") as Button
	if bubble == null:
		bubble = get_node_or_null("Bubble") as Button
	var send := get_node_or_null("%Send") as Button
	if send == null:
		send = get_node_or_null("Panel/VBox/InputRow/Send") as Button
	var input := _find_input()
	if bubble == null or send == null or input == null:
		return
	if not bubble.pressed.is_connected(_on_bubble_pressed):
		bubble.pressed.connect(_on_bubble_pressed)
	if not send.pressed.is_connected(_on_send_pressed):
		send.pressed.connect(_on_send_pressed)
	if not input.text_submitted.is_connected(_on_input_submitted):
		input.text_submitted.connect(_on_input_submitted)
	_build_emote_row()
	_refresh_chrome()
	_built = true


func get_emote_count() -> int:
	_ensure_built()
	return EMOTES.size()


func get_emote_glyph(idx: int) -> String:
	if idx < 0 or idx >= EMOTES.size():
		return ""
	return str(EMOTES[idx])


func get_last_message() -> String:
	if _log.is_empty():
		return ""
	return _log[_log.size() - 1]


func get_log() -> PackedStringArray:
	return _log


func get_unread() -> int:
	return _unread


func is_panel_open() -> bool:
	return _panel_open


func open_panel() -> void:
	_panel_open = true
	_unread = 0
	_refresh_chrome()


func close_panel() -> void:
	_panel_open = false
	_refresh_chrome()


func toggle_panel() -> void:
	if _panel_open:
		close_panel()
	else:
		open_panel()


func send_local(text: String) -> bool:
	_ensure_built()
	var clean := text.strip_edges().substr(0, MAX_TEXT_LEN).strip_edges()
	if clean.is_empty():
		return false
	_append("You: " + clean)
	message_sent.emit(clean)
	return true


func send_emote(idx: int) -> bool:
	_ensure_built()
	if idx < 0 or idx >= EMOTES.size():
		return false
	_append("You: " + str(EMOTES[idx]))
	emote_sent.emit(idx)
	return true


func _append(line: String) -> void:
	_log.append(line)
	var log_view := get_node_or_null("%Log") as RichTextLabel
	if log_view == null:
		log_view = get_node_or_null("Panel/VBox/Log") as RichTextLabel
	if log_view != null:
		log_view.append_text(line + "\n")
	if not _panel_open:
		_unread += 1
	_refresh_chrome()


func _on_bubble_pressed() -> void:
	toggle_panel()


func _on_send_pressed() -> void:
	var input := _find_input()
	if input == null:
		return
	if send_local(input.text):
		input.text = ""


func _on_input_submitted(text: String) -> void:
	var input := _find_input()
	if send_local(text) and input != null:
		input.text = ""


func _on_emote_pressed(idx: int) -> void:
	send_emote(idx)


func _find_input() -> LineEdit:
	var input := get_node_or_null("%Input") as LineEdit
	if input == null:
		input = get_node_or_null("Panel/VBox/InputRow/Input") as LineEdit
	return input


func _build_emote_row() -> void:
	var row := get_node_or_null("%EmoteRow") as HBoxContainer
	if row == null:
		row = get_node_or_null("Panel/VBox/EmoteRow") as HBoxContainer
	if row == null:
		return
	for child in row.get_children():
		child.queue_free()
	for i: int in range(EMOTES.size()):
		var btn := Button.new()
		btn.name = "Emote%d" % i
		btn.text = str(EMOTES[i])
		btn.focus_mode = Control.FOCUS_NONE
		btn.custom_minimum_size = Vector2(44, 36)
		btn.pressed.connect(_on_emote_pressed.bind(i))
		row.add_child(btn)


func _refresh_chrome() -> void:
	var panel := get_node_or_null("%Panel") as PanelContainer
	if panel == null:
		panel = get_node_or_null("Panel") as PanelContainer
	if panel != null:
		panel.visible = _panel_open
	var badge := get_node_or_null("%Unread") as Label
	if badge == null:
		badge = get_node_or_null("Unread") as Label
	if badge != null:
		badge.text = str(_unread)
		badge.visible = _unread > 0
