# Wordtable network event bus (autoloaded as `Bus`, no scene deps).
# The single UI-facing signal hub that unifies offline and online play:
# server frames from NetClient.handle_frame and offline LocalGame results
# from apply_local_result both funnel into the same five signals, so P2
# views (board, rack, chat, strip) never care where truth came from.
#
# Signals:
# - state_synced() — full snapshot replaced (join/start).
# - delta_applied(kind) — incremental turn/game progress ("turn_update",
#   "game_over", "commit", "pass", ...).
# - chat_received(from_name, text) — one lobby/table chat or emote line.
# - reject_shown(ui_text) — server or local rejection in display spelling.
# - seats_changed(count) — lobby seat count moved.
#
# State cache: only own-seat visible state (_turn, _scores, _rack, _over,
# _code) plus last_reject_text for bounce-back flows. The client never
# trusts its own validation: rejects arrive from the server and are only
# reformatted here via CommitFx.
#
# Run headless via res://tests/test_runner.gd (`--suite net_client`).
class_name EventBus
extends Node

signal state_synced
signal delta_applied(kind: String)
signal chat_received(from_name: String, text: String)
signal reject_shown(ui_text: String)
signal seats_changed(count: int)

# Server reason spelling for a dictionary miss; the rules/facade layers
# underneath still spell it NOT_IN_DICTIONARY.
const SERVER_LEXICON_REASON := "NOT_IN_LEXICON"

var _turn := 0
var _scores: Array = []
var _rack: Array = []
var _board_tiles: Array = []
var _over := false
var _code := ""
var _seat_count := 0
var _synced := false

var last_reject_text := ""
var reject_count := 0
var chat_log: Array = []


func get_turn() -> int:
	return _turn


func get_scores() -> Array:
	return _scores.duplicate()


func get_rack() -> Array:
	return _rack.duplicate()


func get_board_tiles() -> Array:
	return _board_tiles.duplicate(true)


func is_over() -> bool:
	return _over


func room_code() -> String:
	return _code


func seat_count() -> int:
	return _seat_count


func is_synced() -> bool:
	return _synced


func get_chat_log() -> Array:
	return chat_log.duplicate(true)


# Display spelling for a server rejection: the room-boundary
# NOT_IN_LEXICON maps back to ScrabbleRules.REASON_NOT_IN_DICTIONARY and
# delegates to CommitFx.reject_text_for, so the "Not in my book: " prefix
# in commit_fx.gd is reused, never retyped. Other reasons fall back to a
# plain `REASON` / `REASON: word` string.
static func ui_reject_text(reason, reason_word: String = "") -> String:
	var mapped := str(reason)
	if mapped == SERVER_LEXICON_REASON:
		mapped = ScrabbleRules.REASON_NOT_IN_DICTIONARY
	var text := CommitFx.reject_text_for({
		"ok": false, "reason": mapped, "reason_word": str(reason_word),
	})
	if text != "":
		return text
	if str(reason_word) != "":
		return "%s: %s" % [str(reason), str(reason_word)]
	return str(reason)


# One server frame in, route string out. Accepted==false gameplay replies
# always take the reject path regardless of `m`; full snapshots replace
# state; deltas refresh the cache; chat/emote replies (which carry `ok`)
# are skipped here because the matching broadcast carries the same line.
func apply_server_frame(frame: Dictionary) -> String:
	if frame.get("accepted", null) == false:
		last_reject_text = ui_reject_text(
			frame.get("reason", frame.get("error", "")), str(frame.get("reason_word", ""))
		)
		reject_count += 1
		_sync_state_fields(frame)
		reject_shown.emit(last_reject_text)
		return "reject"
	var m := str(frame.get("m", ""))
	match m:
		"rejoin", "resync":
			if not bool(frame.get("ok", false)):
				return "rejoin_error"
			_sync_state_fields(frame)
			_synced = true
			state_synced.emit()
			if _emit_seats(frame):
				return "rejoin+seats"
			return "rejoin"
		"state_sync":
			_sync_state_fields(frame)
			_synced = true
			state_synced.emit()
			if _emit_seats(frame):
				return "state_sync+seats"
			return "state_sync"
		"turn_update", "game_over":
			_sync_state_fields(frame)
			delta_applied.emit(m)
			return "delta"
		"chat", "emote":
			if frame.has("ok"):
				return "chat_reply"
			var line := {"from": str(frame.get("from", "")), "text": str(frame.get("text", ""))}
			chat_log.append(line)
			chat_received.emit(str(line["from"]), str(line["text"]))
			return "chat"
		"get_rack", "rack":
			_sync_state_fields(frame)
			return "rack"
		"create_room", "join_room", "room_created", "room_joined", "seat_update", \
		"start_game", "place_tiles", "place", "pass", "pass_turn", "exchange", \
		"recall", "shuffle_rack", "shuffle", "debug_set_rack", "debug_set_bag", \
		"add_bot", "remove_bot":
			_sync_state_fields(frame)
			if str(frame.get("m", "")) in ["place_tiles", "place", "pass", "pass_turn", "exchange"] \
					and bool(frame.get("ok", false)) and bool(frame.get("accepted", true)):
				delta_applied.emit(str(frame.get("kind", "commit")))
				return "delta"
			if _emit_seats(frame):
				return "seats"
			return "ack"
	return "ignored"


# Offline unification: a LocalGame commit/reject dict drives the same
# delta_applied / reject_shown signals the online path uses, so views
# bind once and work in both modes.
func apply_local_result(result: Dictionary) -> String:
	if bool(result.get("ok", false)):
		_sync_state_fields(result)
		delta_applied.emit(str(result.get("kind", "commit")))
		return "delta"
	last_reject_text = CommitFx.reject_text_for(result)
	reject_count += 1
	reject_shown.emit(last_reject_text)
	return "reject"


# Copies whichever own-seat fields the frame carries; absent keys leave
# the cache untouched so partial broadcasts never blank known state.
func _sync_state_fields(frame: Dictionary) -> void:
	if frame.has("turn"):
		_turn = int(frame.get("turn"))
	if frame.get("scores", null) is Array:
		_scores = (frame.get("scores") as Array).duplicate()
	if frame.get("rack", null) is Array:
		_rack = (frame.get("rack") as Array).duplicate()
	if frame.get("board_tiles", null) is Array:
		_board_tiles = (frame.get("board_tiles") as Array).duplicate(true)
	if frame.has("over"):
		_over = bool(frame.get("over"))
	if frame.has("code"):
		_code = str(frame.get("code", ""))
	if frame.has("seats"):
		_seat_count = int(frame.get("seats"))


# Emits seats_changed when the frame carries a seat count; true when fired.
func _emit_seats(frame: Dictionary) -> bool:
	if not frame.has("seats"):
		return false
	_seat_count = int(frame.get("seats"))
	seats_changed.emit(_seat_count)
	return true
