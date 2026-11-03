# Wordtable start screen: nickname entry gating Create/Join.
#
# The front door of the game: a nickname field plus Create and Join buttons
# and a room-code field for joining. Nicknames are trimmed and capped at 16
# chars (mirroring ChatView/PlayerStrip caps); Create/Join stay disabled on
# empty input. The nickname persists via a ConfigFile at
# user://wordtable_settings.cfg, section [player], key nickname (the same
# ConfigFile idiom as SoundBank, which owns the [audio] section).
#
# Entry points:
# - get_nickname()/set_nickname(name) (trimmed, capped at 16).
# - is_nickname_valid() / is_create_enabled() / is_join_enabled().
# - get_code()/set_code(code) (trimmed, uppercased join code).
# - load_nickname()/save_nickname() (ConfigFile round-trip).
# - request_create()/request_join() -> bool (emit signals when valid).
# - set_status(text)/get_status().
#
# No networking: the view only emits create_pressed(nickname) and
# join_pressed(nickname, code) for later rooms.gd binding.
#
# Run headless via res://tests/test_runner.gd (suite `hotseat`).
class_name StartScreen
extends Control

signal create_pressed(nickname: String)
signal join_pressed(nickname: String, code: String)

const MAX_NICKNAME_LEN := 16
const SETTINGS_PATH := "user://wordtable_settings.cfg"
const SECTION := "player"
const KEY := "nickname"

var _nickname := ""
var _code := ""
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
	var nick := get_node_or_null("%Nickname") as LineEdit
	if nick == null:
		nick = get_node_or_null("Nickname") as LineEdit
	var create_btn := get_node_or_null("%CreateButton") as Button
	if create_btn == null:
		create_btn = get_node_or_null("CreateButton") as Button
	var join_btn := get_node_or_null("%JoinButton") as Button
	if join_btn == null:
		join_btn = get_node_or_null("JoinButton") as Button
	var code_field := get_node_or_null("%CodeField") as LineEdit
	if code_field == null:
		code_field = get_node_or_null("CodeField") as LineEdit
	if nick == null and create_btn == null and join_btn == null and code_field == null:
		return
	if nick != null:
		nick.max_length = maxi(nick.max_length, MAX_NICKNAME_LEN)
		if _nickname != "":
			nick.text = _nickname
		else:
			_nickname = _clean_name(nick.text)
		if not nick.text_changed.is_connected(_on_nickname_changed):
			nick.text_changed.connect(_on_nickname_changed)
	if code_field != null:
		if _code != "":
			code_field.text = _code
		else:
			_code = _clean_code(code_field.text)
		if not code_field.text_changed.is_connected(_on_code_changed):
			code_field.text_changed.connect(_on_code_changed)
	if create_btn != null and not create_btn.pressed.is_connected(_on_create_button):
		create_btn.pressed.connect(_on_create_button)
	if join_btn != null and not join_btn.pressed.is_connected(_on_join_button):
		join_btn.pressed.connect(_on_join_button)
	_built = true


func get_nickname() -> String:
	_ensure_built()
	var nick := get_node_or_null("%Nickname") as LineEdit
	if nick == null:
		nick = get_node_or_null("Nickname") as LineEdit
	if nick != null:
		_nickname = _clean_name(nick.text)
	return _nickname


func set_nickname(raw: String) -> void:
	_ensure_built()
	_nickname = _clean_name(raw)
	var nick := get_node_or_null("%Nickname") as LineEdit
	if nick == null:
		nick = get_node_or_null("Nickname") as LineEdit
	if nick != null and nick.text != _nickname:
		nick.text = _nickname
	_refresh_chrome()


func get_code() -> String:
	_ensure_built()
	var code_field := get_node_or_null("%CodeField") as LineEdit
	if code_field == null:
		code_field = get_node_or_null("CodeField") as LineEdit
	if code_field != null:
		_code = _clean_code(code_field.text)
	return _code


func set_code(raw: String) -> void:
	_ensure_built()
	_code = _clean_code(raw)
	var code_field := get_node_or_null("%CodeField") as LineEdit
	if code_field == null:
		code_field = get_node_or_null("CodeField") as LineEdit
	if code_field != null and code_field.text != _code:
		code_field.text = _code
	_refresh_chrome()


func get_status() -> String:
	return _status


func set_status(text: String) -> void:
	_status = text
	var label := get_node_or_null("%StatusLabel") as Label
	if label == null:
		label = get_node_or_null("StatusLabel") as Label
	if label != null:
		label.text = text


func is_nickname_valid() -> bool:
	return not get_nickname().is_empty()


func is_create_enabled() -> bool:
	return is_nickname_valid()


func is_join_enabled() -> bool:
	return is_nickname_valid()


func is_code_valid() -> bool:
	return get_code().length() == 4


func load_nickname() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		_nickname = _clean_name(str(cfg.get_value(SECTION, KEY, _nickname)))
	var nick := get_node_or_null("%Nickname") as LineEdit
	if nick == null:
		nick = get_node_or_null("Nickname") as LineEdit
	if nick != null and _nickname != "" and nick.text != _nickname:
		nick.text = _nickname
	_refresh_chrome()
	return _nickname


func save_nickname() -> void:
	get_nickname()
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value(SECTION, KEY, _nickname)
	cfg.save(SETTINGS_PATH)


func request_create() -> bool:
	if not is_nickname_valid():
		return false
	save_nickname()
	create_pressed.emit(_nickname)
	return true


func request_join() -> bool:
	if not is_nickname_valid():
		return false
	if not is_code_valid():
		return false
	save_nickname()
	join_pressed.emit(_nickname, _code)
	return true


func _on_nickname_changed(_new_text: String) -> void:
	get_nickname()
	_refresh_chrome()


func _on_code_changed(_new_text: String) -> void:
	get_code()
	_refresh_chrome()


func _on_create_button() -> void:
	request_create()


func _on_join_button() -> void:
	request_join()


func _refresh_chrome() -> void:
	var create_btn := get_node_or_null("%CreateButton") as Button
	if create_btn == null:
		create_btn = get_node_or_null("CreateButton") as Button
	var join_btn := get_node_or_null("%JoinButton") as Button
	if join_btn == null:
		join_btn = get_node_or_null("JoinButton") as Button
	if create_btn != null:
		create_btn.disabled = not is_create_enabled()
	if join_btn != null:
		join_btn.disabled = not is_join_enabled()


func _clean_name(raw: String) -> String:
	return raw.strip_edges().substr(0, MAX_NICKNAME_LEN).strip_edges()


func _clean_code(raw: String) -> String:
	return raw.strip_edges().to_upper()
