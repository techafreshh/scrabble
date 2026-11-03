# Wordtable hot-seat table: offline playable loop over LocalGame.
#
# The first playable game: owns a LocalGame instance directly (the exact
# seam P3's server will later bind to), rotates hot-seat turns across 2-4
# named seats, and proxies commit/recall/shuffle/exchange/pass through to
# the facade. Rejects surface as inline text via CommitFx.reject_text_for().
# When the game ends it emits game_finished and prints the
# `hotseat_winner=<name>` acceptance marker. The recap reads
# LocalGame.history() straight from get_game().
#
# Scene composition lives in res://scenes/table.tscn, which instances the
# existing scenes/table/* subscenes; this script binds BoardView.cell_pressed
# and RackView.tile_chosen onto a shared PlacementController for tap-tap
# staging and mirrors its provisional_label(), exactly like
# tests/test_placement.gd drives them.
#
# Entry points:
# - set_lexicon(lex) (duck-typed is_word hook, like the facade suite).
# - new_hotseat(names: Array, seed: int) -> HotseatTable.
# - get_game()/get_names()/get_scores()/current_seat()/current_name().
# - commit_move(placements, blank_map={}) / recall() / shuffle().
# - exchange(count) / pass_turn() / get_last_reject_text().
# - is_over()/get_winner_name()/sync_rack_to_controller().
# - provisional_label() (controller scoring preview, "+N" or reason).
#
# Run headless via res://tests/test_runner.gd (suite `hotseat`).
class_name HotseatTable
extends Control

signal game_finished(winner_name: String)

const MIN_SEATS := 2
const MAX_SEATS := 4
const MAX_NAME_LEN := 16

var _game: LocalGame = null
var _names: Array = []
var _lexicon = null
var _controller := PlacementController.new()
var _last_reject_text := ""
var _built := false


func _ready() -> void:
	_ensure_built()


func _ensure_built() -> void:
	if _built:
		return
	_maybe_mount_reconnect_overlay()
	var board := _find_board()
	var rack := _find_rack()
	var play_btn := get_node_or_null("%PlayButton") as Button
	if play_btn == null:
		play_btn = get_node_or_null("PlayButton") as Button
	if board == null and rack == null and play_btn == null:
		return
	if rack != null and rack.has_method("bind_controller"):
		rack.bind_controller(_controller)
	if board != null and board.has_signal("cell_pressed"):
		if not board.cell_pressed.is_connected(_on_cell_pressed):
			board.cell_pressed.connect(_on_cell_pressed)
	if rack != null and rack.has_signal("tile_chosen"):
		if not rack.tile_chosen.is_connected(_on_tile_chosen):
			rack.tile_chosen.connect(_on_tile_chosen)
	if play_btn != null and not play_btn.pressed.is_connected(_on_play_button):
		play_btn.pressed.connect(_on_play_button)
	var mute_btn := get_node_or_null("%MuteButton") as Button
	if mute_btn == null:
		mute_btn = get_node_or_null("MuteButton") as Button
	if mute_btn != null and not mute_btn.pressed.is_connected(_on_mute_button):
		mute_btn.pressed.connect(_on_mute_button)
	_refresh_mute_label()
	_built = true
	_refresh_chrome()


func set_lexicon(lex) -> void:
	_lexicon = lex


func get_lexicon():
	return _lexicon


# Builds the hot-seat game: names clamped to 2-4 seats (short lists are
# padded with Player N, long lists sliced), then a LocalGame owned here.
func new_hotseat(names: Array, seed: int) -> HotseatTable:
	_names.clear()
	for raw in names.slice(0, MAX_SEATS):
		_names.append(_clean_name(raw))
	var n := MIN_SEATS
	while _names.size() < MIN_SEATS:
		n += 1
		_names.append("Player %d" % n)
	_game = LocalGame.new(_names.size(), seed, _lexicon)
	_last_reject_text = ""
	sync_rack_to_controller()
	_refresh_chrome()
	return self


func get_game() -> LocalGame:
	return _game


func get_names() -> Array:
	return _names.duplicate()


func get_scores() -> Array:
	if _game == null:
		return []
	return _game.scores()


func current_seat() -> int:
	if _game == null:
		return 0
	return _game.current_player()


func current_name() -> String:
	if _names.is_empty():
		return ""
	return str(_names[current_seat() % _names.size()])


func is_over() -> bool:
	return _game != null and _game.is_over()


func get_winner_name() -> String:
	if _game == null or _names.is_empty():
		return ""
	var scores: Array = _game.scores()
	var best := 0
	for i: int in range(1, scores.size()):
		if int(scores[i]) > int(scores[best]):
			best = i
	return str(_names[best % _names.size()])


func get_last_reject_text() -> String:
	return _last_reject_text


func get_controller() -> PlacementController:
	return _controller


# One-shot commit for the current hot-seat player. On success the rack
# controller resyncs to the next seat; on reject the inline text is kept
# for the status line (CommitFx idiom) until the next attempt.
func commit_move(placements: Array, blank_map: Dictionary = {}) -> Dictionary:
	if _game == null:
		return {}
	var res := _game.place(placements, blank_map)
	if bool(res.get("ok", false)):
		_last_reject_text = ""
		CommitFx.new().play_commit()
		_play_node("ThunkPlayer")
		sync_rack_to_controller()
	else:
		_last_reject_text = CommitFx.reject_text_for(res)
	_maybe_finish()
	_refresh_chrome()
	return res


func recall() -> Dictionary:
	if _game == null:
		return {}
	_controller.recall()
	var res := _game.recall()
	_refresh_chrome()
	return res


func shuffle() -> Dictionary:
	if _game == null:
		return {}
	_controller.shuffle()
	var res := _game.shuffle()
	sync_rack_to_controller()
	_refresh_chrome()
	return res


func exchange(count: int) -> Dictionary:
	if _game == null:
		return {}
	var res := _game.exchange(count)
	sync_rack_to_controller()
	_maybe_finish()
	_refresh_chrome()
	return res


func pass_turn() -> Dictionary:
	if _game == null:
		return {}
	var res := _game.pass_turn()
	sync_rack_to_controller()
	_maybe_finish()
	_refresh_chrome()
	return res


# Mounts the reconnect overlay as a hidden top-level child and binds it to
# the Net autoload. Guarded by resource/node lookups so offline hot-seat
# (or a headless tree without Net) never shows it and never raises.
func _on_mute_button() -> void:
	SoundBank.new().toggle_muted()
	_refresh_mute_label()


# Mute label follows the persisted SoundBank state (guarded: the button
# only exists in the full table scene).
func _refresh_mute_label() -> void:
	var mute_btn := get_node_or_null("%MuteButton") as Button
	if mute_btn == null:
		mute_btn = get_node_or_null("MuteButton") as Button
	if mute_btn == null:
		return
	mute_btn.text = "Sound: Off" if SoundBank.new().is_muted() else "Sound: On"


# Audible commit/finish players from the table scene (guarded: hot-seat
# unit instances built without the scene simply skip the sound).
func _play_node(node_name: String) -> void:
	var player := get_node_or_null(node_name) as AudioStreamPlayer
	if player != null:
		player.play()


func _maybe_mount_reconnect_overlay() -> void:
	if get_node_or_null("ReconnectOverlay") != null:
		return
	if not ResourceLoader.exists("res://scenes/reconnect_overlay.tscn"):
		return
	var packed := load("res://scenes/reconnect_overlay.tscn") as PackedScene
	if packed == null:
		return
	var overlay := packed.instantiate()
	overlay.name = "ReconnectOverlay"
	add_child(overlay)
	var net := get_node_or_null("/root/Net")
	if net == null:
		return
	if overlay.has_method("bind_net"):
		overlay.call("bind_net", net)
	if net.has_method("bind_overlay"):
		net.call("bind_overlay", overlay)


# Mirrors the current seat's rack into the staging controller so tap-tap
# placement and provisional_label() preview exactly this seat's tiles.
func sync_rack_to_controller() -> void:
	if _game == null:
		return
	_controller.set_rack(_game.rack_letters(_game.current_player()))
	_refresh_chrome()


func provisional_label() -> String:
	if _game == null:
		return "+0"
	return _controller.provisional_label(_game.board, _lexicon)


func _maybe_finish() -> void:
	if _game == null or not _game.is_over():
		return
	var winner := get_winner_name()
	CommitFx.new().play_win()
	_play_node("FanfarePlayer")
	print("hotseat_winner=" + winner)
	game_finished.emit(winner)


func _on_tile_chosen(slot: int) -> void:
	_controller.select_slot(slot)


func _on_cell_pressed(col: int, row: int) -> void:
	if _controller.selected_slot() < 0:
		return
	if not _controller.can_place_at(col, row):
		return
	_controller.place_at(col, row)
	_refresh_chrome()


func _on_play_button() -> void:
	var pendings := _controller.get_pendings()
	if pendings.is_empty():
		return
	var placements: Array = []
	for p in pendings:
		var d := p as Dictionary
		placements.append({
			"col": int(d.get("col", -1)),
			"row": int(d.get("row", -1)),
			"letter": str(d.get("letter", "")),
		})
	var res := commit_move(placements)
	if not bool(res.get("ok", false)):
		_controller.recall()
	set_status(_last_reject_text)


func set_status(text: String) -> void:
	var label := get_node_or_null("%StatusLabel") as Label
	if label == null:
		label = get_node_or_null("StatusLabel") as Label
	if label != null:
		label.text = text


func _find_board() -> Control:
	var board := get_node_or_null("Board") as Control
	if board != null:
		return board
	return get_node_or_null("%Board") as Control


func _find_rack() -> Control:
	var rack := get_node_or_null("Rack") as Control
	if rack != null:
		return rack
	return get_node_or_null("%Rack") as Control


func _refresh_chrome() -> void:
	var board := _find_board()
	if board != null and board.has_method("set_pending"):
		board.call("set_pending", _controller.pending_cells())
	var rack := _find_rack()
	if rack != null and rack.has_method("refresh_provisional") and _game != null:
		rack.call("refresh_provisional", _game.board, _lexicon, _controller)


func _clean_name(raw) -> String:
	var text := str(raw).strip_edges().substr(0, MAX_NAME_LEN).strip_edges()
	if text.is_empty():
		text = "Player"
	return text
