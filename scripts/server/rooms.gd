# Wordtable room registry (headless authoritative host, no scene deps).
# Owns room codes, per-seat session tokens, the host gate, and one LocalGame
# per started room for real move adjudication. Transport-agnostic: the server
# feeds one Dictionary per JSON text frame into `handle_dict` and sends back
# every Dictionary in the returned Array (reply first, broadcasts after).
# Run headless via res://tests/test_runner.gd (`--suite rooms` or full run).
class_name RoomRegistry
extends RefCounted

const CODE_LEN := 4
const CODE_ALPHABET := "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
const TOKEN_LEN := 32
const TOKEN_HEX := "0123456789abcdef"
const MAX_SEATS := 4
const PROTOCOL_VERSION := 1
const BOT_NAME := "Botgomery"

const KNOWN_METHODS := [
	"create_room", "join_room", "add_bot", "remove_bot", "start_game",
	"place_tiles", "place", "pass", "pass_turn", "exchange", "recall",
	"shuffle_rack", "shuffle", "chat", "emote",
]

var _rooms: Dictionary = {}
var _lexicon = null
var _rng := RandomNumberGenerator.new()


func _init(p_lexicon = null, p_seed: int = 0) -> void:
	_lexicon = p_lexicon
	if p_seed != 0:
		_rng.seed = p_seed
	else:
		_rng.randomize()


func set_lexicon(lex) -> void:
	_lexicon = lex


func room_count() -> int:
	return _rooms.size()


func has_room(code: String) -> bool:
	return _rooms.has(_norm_code(code))


# Test hook: exposes the room's live game so suites can pin racks/bags.
func debug_game(code: String):
	var room := _get_room(code)
	if room.is_empty():
		return null
	return room.get("game", null)


# Seat 0 is the host. Returns {ok, m, code, seat, player_id, you, token,
# seats, ...} with redundant aliases so version-tolerant clients can read
# whichever field name they know.
func create_room(player_name: String, options: Dictionary = {}) -> Dictionary:
	var code := _gen_code()
	var token := _gen_token()
	var who := player_name.strip_edges()
	if who == "":
		who = "Host"
	var room := {
		"code": code,
		"seats": [{"seat": 0, "name": who, "token": token, "is_bot": false}],
		"started": false,
		"game": null,
		"options": options.duplicate(true),
		"seed": 0,
	}
	_rooms[code] = room
	return {
		"ok": true, "m": "create_room", "code": code, "room": code,
		"room_code": code, "seat": 0, "player_id": 0, "you": 0,
		"token": token, "session": token, "seats": 1, "seat_count": 1,
		"started": false, "timer_on": bool(options.get("timer_on", false)),
		"seats_list": _public_seats(room),
	}


# Empty or unknown token means a fresh seat; a known token re-seats the
# caller on their existing seat (rejoin across connections).
func join_room(code: String, player_name: String, token: String = "") -> Dictionary:
	var room := _get_room(code)
	if room.is_empty():
		return _gate_error("join_room", "NO_ROOM")
	var who := player_name.strip_edges()
	if who == "":
		who = "Guest"
	var seats: Array = room["seats"]
	var again := _seat_by_token(room, token)
	if not again.is_empty():
		var n: int = int(again.get("seat", 0))
		return {
			"ok": true, "m": "join_room", "code": str(room["code"]),
			"room": str(room["code"]), "seat": n, "player_id": n, "you": n,
			"token": str(again.get("token", "")), "session": str(again.get("token", "")),
			"seats": seats.size(), "seat_count": seats.size(),
			"started": bool(room.get("started", false)),
			"seats_list": _public_seats(room),
		}
	if bool(room.get("started", false)):
		return _gate_error("join_room", "BAD_STATE")
	if seats.size() >= MAX_SEATS:
		return _gate_error("join_room", "ROOM_FULL")
	var fresh := _gen_token()
	var seat_no: int = seats.size()
	seats.append({"seat": seat_no, "name": who, "token": fresh, "is_bot": false})
	return {
		"ok": true, "m": "join_room", "code": str(room["code"]),
		"room": str(room["code"]), "seat": seat_no, "player_id": seat_no,
		"you": seat_no, "token": fresh, "session": fresh,
		"seats": seats.size(), "seat_count": seats.size(),
		"started": false, "seats_list": _public_seats(room),
	}


func add_bot(code: String, token: String) -> Dictionary:
	var room := _get_room(code)
	if room.is_empty():
		return _gate_error("add_bot", "NO_ROOM")
	if _seat_by_token(room, token).is_empty():
		return _gate_error("add_bot", "NO_TOKEN")
	if not _is_host(room, token):
		return _gate_error("add_bot", "NOT_HOST")
	if bool(room.get("started", false)):
		return _gate_error("add_bot", "BAD_STATE")
	var seats: Array = room["seats"]
	if seats.size() >= MAX_SEATS:
		return _gate_error("add_bot", "ROOM_FULL")
	var seat_no: int = seats.size()
	seats.append({"seat": seat_no, "name": BOT_NAME, "token": _gen_token(), "is_bot": true})
	return {
		"ok": true, "m": "add_bot", "code": str(room["code"]),
		"bot": BOT_NAME, "bot_seat": seat_no,
		"seats": seats.size(), "seat_count": seats.size(),
		"seats_list": _public_seats(room),
	}


func remove_bot(code: String, token: String, seat: int = -1) -> Dictionary:
	var room := _get_room(code)
	if room.is_empty():
		return _gate_error("remove_bot", "NO_ROOM")
	if _seat_by_token(room, token).is_empty():
		return _gate_error("remove_bot", "NO_TOKEN")
	if not _is_host(room, token):
		return _gate_error("remove_bot", "NOT_HOST")
	if bool(room.get("started", false)):
		return _gate_error("remove_bot", "BAD_STATE")
	var seats: Array = room["seats"]
	var target := -1
	if seat >= 0:
		for s in seats:
			if s is Dictionary and int((s as Dictionary).get("seat", -1)) == seat:
				if bool((s as Dictionary).get("is_bot", false)):
					target = seat
				break
		if target < 0:
			return _gate_error("remove_bot", "BAD_STATE")
	else:
		for i in range(seats.size() - 1, -1, -1):
			var s = seats[i]
			if s is Dictionary and bool((s as Dictionary).get("is_bot", false)):
				target = i
				break
		if target < 0:
			return _gate_error("remove_bot", "BAD_STATE")
		seats.remove_at(target)
		_renumber(room)
		return {
			"ok": true, "m": "remove_bot", "code": str(room["code"]),
			"seats": seats.size(), "seat_count": seats.size(),
			"seats_list": _public_seats(room),
		}
	for i in range(seats.size()):
		var s = seats[i]
		if s is Dictionary and int((s as Dictionary).get("seat", -1)) == target:
			seats.remove_at(i)
			break
	_renumber(room)
	return {
		"ok": true, "m": "remove_bot", "code": str(room["code"]),
		"seats": seats.size(), "seat_count": seats.size(),
		"seats_list": _public_seats(room),
	}


func start_game(code: String, token: String) -> Dictionary:
	var room := _get_room(code)
	if room.is_empty():
		return _gate_error("start_game", "NO_ROOM")
	if _seat_by_token(room, token).is_empty():
		return _gate_error("start_game", "NO_TOKEN")
	if not _is_host(room, token):
		return _gate_error("start_game", "NOT_HOST")
	if bool(room.get("started", false)):
		return _gate_error("start_game", "BAD_STATE")
	var seats: Array = room["seats"]
	if seats.size() < 2:
		return _gate_error("start_game", "NEED_OPPONENT")
	var seed := _rng.randi()
	var game := LocalGame.new(seats.size(), seed, _lexicon)
	room["game"] = game
	room["started"] = true
	room["seed"] = seed
	var delta: Dictionary = game.state_delta()
	return {
		"ok": true, "m": "start_game", "code": str(room["code"]),
		"started": true, "turn": game.current_player(),
		"seats": seats.size(), "seat_count": seats.size(),
		"scores": game.scores(), "over": game.is_over(),
		"ending": game.ending(), "delta": delta,
		"seats_list": _public_seats(room),
	}


# tiles: [{square: "H8", letter: "Q", blank_as: ""}] with col/row/letter
# dicts also accepted. Any seated token may submit for the current player;
# seat==turn gating is deliberately left to a later lap (see protocol.md).
func place_tiles(code: String, token: String, tiles: Array) -> Dictionary:
	var room := _get_room(code)
	if room.is_empty():
		return _gate_error("place_tiles", "NO_ROOM")
	if _seat_by_token(room, token).is_empty():
		return _gate_error("place_tiles", "NO_TOKEN")
	if not bool(room.get("started", false)) or room.get("game") == null:
		return _gate_error("place_tiles", "BAD_STATE")
	var conv := _to_placements(tiles)
	if not bool(conv.get("ok", false)):
		return _gate_error("place_tiles", str(conv.get("error", "BAD_TILES")))
	var game: LocalGame = room["game"]
	var res: Dictionary = game.place(conv.get("placements", []), conv.get("blank_map", {}))
	if not bool(res.get("ok", false)):
		return {
			"ok": false, "m": "place_tiles", "code": str(room["code"]),
			"error": str(res.get("reason", "BAD_PLAY")),
			"reason": str(res.get("reason", "BAD_PLAY")),
			"reason_word": str(res.get("reason_word", "")),
			"kind": str(res.get("kind", "reject")),
			"total": int(res.get("total", 0)),
			"turn": game.current_player(), "scores": game.scores(),
			"over": game.is_over(), "ending": game.ending(),
		}
	return {
		"ok": true, "m": "place_tiles", "code": str(room["code"]),
		"kind": "commit", "reason": "OK",
		"words": res.get("words", []),
		"main_points": int(res.get("main_points", 0)),
		"cross_points": int(res.get("cross_points", 0)),
		"bingo": int(res.get("bingo", 0)), "total": int(res.get("total", 0)),
		"turn": game.current_player(), "scores": game.scores(),
		"over": game.is_over(), "ending": game.ending(),
		"delta": res.get("delta", {}),
	}


func pass_turn(code: String, token: String) -> Dictionary:
	var room := _get_room(code)
	if room.is_empty():
		return _gate_error("pass", "NO_ROOM")
	if _seat_by_token(room, token).is_empty():
		return _gate_error("pass", "NO_TOKEN")
	if not bool(room.get("started", false)) or room.get("game") == null:
		return _gate_error("pass", "BAD_STATE")
	var game: LocalGame = room["game"]
	var res: Dictionary = game.pass_turn()
	if not bool(res.get("ok", false)):
		return {
			"ok": false, "m": "pass", "code": str(room["code"]),
			"error": str(res.get("reason", "BAD_PLAY")),
			"reason": str(res.get("reason", "BAD_PLAY")),
			"turn": game.current_player(), "scores": game.scores(),
			"over": game.is_over(), "ending": game.ending(),
		}
	return {
		"ok": true, "m": "pass", "code": str(room["code"]),
		"kind": "pass", "reason": "OK", "accepted": true,
		"turn": game.current_player(), "scores": game.scores(),
		"over": game.is_over(), "ending": game.ending(),
		"delta": res.get("delta", {}),
	}


func exchange(code: String, token: String, count: int) -> Dictionary:
	var room := _get_room(code)
	if room.is_empty():
		return _gate_error("exchange", "NO_ROOM")
	if _seat_by_token(room, token).is_empty():
		return _gate_error("exchange", "NO_TOKEN")
	if not bool(room.get("started", false)) or room.get("game") == null:
		return _gate_error("exchange", "BAD_STATE")
	var game: LocalGame = room["game"]
	var res: Dictionary = game.exchange(count)
	if not bool(res.get("ok", false)):
		return {
			"ok": false, "m": "exchange", "code": str(room["code"]),
			"error": str(res.get("reason", "BAD_PLAY")),
			"reason": str(res.get("reason", "BAD_PLAY")),
			"turn": game.current_player(), "scores": game.scores(),
			"over": game.is_over(), "ending": game.ending(),
		}
	return {
		"ok": true, "m": "exchange", "code": str(room["code"]),
		"kind": "exchange", "reason": "OK", "accepted": true,
		"turn": game.current_player(), "scores": game.scores(),
		"over": game.is_over(), "ending": game.ending(),
		"delta": res.get("delta", {}),
	}


func recall(code: String, token: String) -> Dictionary:
	var room := _get_room(code)
	if room.is_empty():
		return _gate_error("recall", "NO_ROOM")
	if _seat_by_token(room, token).is_empty():
		return _gate_error("recall", "NO_TOKEN")
	if not bool(room.get("started", false)) or room.get("game") == null:
		return _gate_error("recall", "BAD_STATE")
	var game: LocalGame = room["game"]
	var res: Dictionary = game.recall()
	return {
		"ok": true, "m": "recall", "code": str(room["code"]),
		"kind": "recall", "reason": "OK",
		"recalled": int(res.get("recalled", 0)),
		"rack": res.get("rack", []),
		"turn": game.current_player(), "scores": game.scores(),
		"over": game.is_over(), "ending": game.ending(),
	}


func shuffle_rack(code: String, token: String) -> Dictionary:
	var room := _get_room(code)
	if room.is_empty():
		return _gate_error("shuffle_rack", "NO_ROOM")
	if _seat_by_token(room, token).is_empty():
		return _gate_error("shuffle_rack", "NO_TOKEN")
	if not bool(room.get("started", false)) or room.get("game") == null:
		return _gate_error("shuffle_rack", "BAD_STATE")
	var game: LocalGame = room["game"]
	var res: Dictionary = game.shuffle()
	if not bool(res.get("ok", false)):
		return {
			"ok": false, "m": "shuffle_rack", "code": str(room["code"]),
			"error": str(res.get("reason", "BAD_PLAY")),
			"reason": str(res.get("reason", "BAD_PLAY")),
			"turn": game.current_player(),
		}
	return {
		"ok": true, "m": "shuffle_rack", "code": str(room["code"]),
		"kind": "shuffle", "reason": "OK",
		"rack": res.get("rack", []),
		"turn": game.current_player(), "scores": game.scores(),
	}


func chat(code: String, token: String, text: String) -> Dictionary:
	return _say("chat", code, token, text)


func emote(code: String, token: String, text: String) -> Dictionary:
	return _say("emote", code, token, text)


func _say(kind: String, code: String, token: String, text: String) -> Dictionary:
	var room := _get_room(code)
	if room.is_empty():
		return _gate_error(kind, "NO_ROOM")
	var seat := _seat_by_token(room, token)
	if seat.is_empty():
		return _gate_error(kind, "NO_TOKEN")
	var msg := text.strip_edges()
	if msg == "":
		return _gate_error(kind, "BAD_TEXT")
	var frame := {
		"m": "chat", "kind": kind, "code": str(room["code"]),
		"from": str(seat.get("name", "Player")),
		"seat": int(seat.get("seat", 0)),
		"text": msg, "ts": int(Time.get_unix_time_from_system()),
	}
	if kind == "chat":
		return {
			"ok": true, "m": "chat", "code": str(room["code"]),
			"chat_ok": true, "from": str(frame["from"]),
			"seat": int(frame["seat"]), "text": msg,
			"ts": int(frame["ts"]),
		}
	return {
		"ok": true, "m": "emote", "code": str(room["code"]),
		"emote_ok": true, "from": str(frame["from"]),
		"seat": int(frame["seat"]), "text": msg,
		"ts": int(frame["ts"]),
	}


# Single JSON-object frame in, array of JSON-object frames out. The first
# frame is always the reply ({m, ok, ...}); later frames are broadcasts.
# Nothing in here may raise: unknown input yields an error reply, and the
# caller only ever sends Dictionaries that came out of this function.
func handle_dict(req: Dictionary) -> Array:
	var m_raw := _str_field(req, ["m", "method"], "")
	if m_raw == "":
		return [_gate_error("error", "UNKNOWN_MESSAGE")]
	var ml := m_raw.to_lower()
	if _as_version(req) != PROTOCOL_VERSION:
		return [_gate_error(m_raw, "BAD_VERSION")]
	if not (ml in KNOWN_METHODS):
		return [_gate_error(m_raw, "UNKNOWN_MESSAGE")]
	match ml:
		"create_room":
			var who := _str_field(req, ["name", "player", "player_name"], "Host")
			var opts := {}
			if req.get("options", null) is Dictionary:
				opts = (req.get("options") as Dictionary).duplicate(true)
			var reply := create_room(who, opts)
			reply["m"] = m_raw
			var frames: Array = [reply]
			frames.append({
				"m": "room_created", "code": str(reply.get("code", "")),
				"seat": 0, "seats": 1, "seat_count": 1,
			})
			return frames
		"join_room":
			var code := _str_field(req, ["code", "room", "room_code"], "")
			var who := _str_field(req, ["name", "player", "player_name"], "Guest")
			var tok := _str_field(req, ["token", "session", "session_token"], "")
			var reply := join_room(code, who, tok)
			reply["m"] = m_raw
			if not bool(reply.get("ok", false)):
				return [reply]
			var frames: Array = [reply]
			frames.append({
				"m": "room_joined", "code": str(reply.get("code", "")),
				"seat": int(reply.get("seat", 0)), "you": int(reply.get("seat", 0)),
				"name": who, "seats": int(reply.get("seats", 0)),
				"seat_count": int(reply.get("seats", 0)),
			})
			frames.append(_seat_update(str(reply.get("code", ""))))
			return frames
		"add_bot":
			var reply := add_bot(
				_str_field(req, ["code", "room", "room_code"], ""),
				_str_field(req, ["token", "session", "session_token"], "")
			)
			reply["m"] = m_raw
			if not bool(reply.get("ok", false)):
				return [reply]
			return [reply, _seat_update(str(reply.get("code", "")))]
		"remove_bot":
			var seat_no := -1
			if req.has("seat") and str(req.get("seat")).strip_edges() != "":
				seat_no = int(req.get("seat"))
			elif req.has("bot_seat") and str(req.get("bot_seat")).strip_edges() != "":
				seat_no = int(req.get("bot_seat"))
			var reply := remove_bot(
				_str_field(req, ["code", "room", "room_code"], ""),
				_str_field(req, ["token", "session", "session_token"], ""),
				seat_no
			)
			reply["m"] = m_raw
			if not bool(reply.get("ok", false)):
				return [reply]
			return [reply, _seat_update(str(reply.get("code", "")))]
		"start_game":
			var reply := start_game(
				_str_field(req, ["code", "room", "room_code"], ""),
				_str_field(req, ["token", "session", "session_token"], "")
			)
			reply["m"] = m_raw
			if not bool(reply.get("ok", false)):
				return [reply]
			return [reply, _state_sync(str(reply.get("code", "")))]
		"place_tiles", "place":
			var tiles: Array = []
			if req.get("tiles", null) is Array:
				tiles = (req.get("tiles") as Array).duplicate(true)
			elif req.get("placements", null) is Array:
				tiles = (req.get("placements") as Array).duplicate(true)
			var reply := place_tiles(
				_str_field(req, ["code", "room", "room_code"], ""),
				_str_field(req, ["token", "session", "session_token"], ""),
				tiles
			)
			reply["m"] = m_raw
			if not bool(reply.get("ok", false)):
				return [reply]
			var frames: Array = [reply]
			frames.append(_turn_frame(str(reply.get("code", "")), reply))
			return frames
		"pass", "pass_turn":
			var reply := pass_turn(
				_str_field(req, ["code", "room", "room_code"], ""),
				_str_field(req, ["token", "session", "session_token"], "")
			)
			reply["m"] = m_raw
			if not bool(reply.get("ok", false)):
				return [reply]
			var frames: Array = [reply]
			frames.append(_turn_frame(str(reply.get("code", "")), reply))
			return frames
		"exchange":
			var count := 1
			for k in ["count", "n", "tiles"]:
				if req.has(k) and str(req.get(k)).strip_edges() != "":
					if (req.get(k) is Array):
						count = (req.get(k) as Array).size()
					else:
						count = int(str(req.get(k)).strip_edges())
					break
			var reply := exchange(
				_str_field(req, ["code", "room", "room_code"], ""),
				_str_field(req, ["token", "session", "session_token"], ""),
				count
			)
			reply["m"] = m_raw
			if not bool(reply.get("ok", false)):
				return [reply]
			var frames: Array = [reply]
			frames.append(_turn_frame(str(reply.get("code", "")), reply))
			return frames
		"recall":
			var reply := recall(
				_str_field(req, ["code", "room", "room_code"], ""),
				_str_field(req, ["token", "session", "session_token"], "")
			)
			reply["m"] = m_raw
			if not bool(reply.get("ok", false)):
				return [reply]
			return [reply, _state_sync(str(reply.get("code", "")))]
		"shuffle_rack", "shuffle":
			var reply := shuffle_rack(
				_str_field(req, ["code", "room", "room_code"], ""),
				_str_field(req, ["token", "session", "session_token"], "")
			)
			reply["m"] = m_raw
			if not bool(reply.get("ok", false)):
				return [reply]
			return [reply, _state_sync(str(reply.get("code", "")))]
		"chat", "emote":
			var reply: Dictionary
			if ml == "chat":
				reply = chat(
					_str_field(req, ["code", "room", "room_code"], ""),
					_str_field(req, ["token", "session", "session_token"], ""),
					str(req.get("text", req.get("message", "")))
				)
			else:
				reply = emote(
					_str_field(req, ["code", "room", "room_code"], ""),
					_str_field(req, ["token", "session", "session_token"], ""),
					str(req.get("text", req.get("emo", req.get("message", ""))))
				)
			reply["m"] = m_raw
			if not bool(reply.get("ok", false)):
				return [reply]
			var frames: Array = [reply]
			frames.append({
				"m": "chat", "kind": ml, "code": str(reply.get("code", "")),
				"from": str(reply.get("from", "")),
				"seat": int(reply.get("seat", 0)),
				"text": str(reply.get("text", "")),
				"ts": int(reply.get("ts", 0)),
			})
			return frames
	return [_gate_error(m_raw, "UNKNOWN_MESSAGE")]


func _gate_error(m: String, code: String) -> Dictionary:
	return {"m": m, "ok": false, "error": code, "reason": code}


func _norm_code(raw) -> String:
	return str(raw).strip_edges().to_upper()


func _get_room(code: String) -> Dictionary:
	var nc := _norm_code(code)
	if nc == "" or not _rooms.has(nc):
		return {}
	var room = _rooms[nc]
	if room is Dictionary:
		return room
	return {}


func _seat_by_token(room: Dictionary, token: String) -> Dictionary:
	var t := str(token).strip_edges()
	if t == "":
		return {}
	for s in (room.get("seats", []) as Array):
		if s is Dictionary and str((s as Dictionary).get("token", "")) == t:
			return s
	return {}


func _is_host(room: Dictionary, token: String) -> bool:
	var seats: Array = room.get("seats", [])
	if seats.is_empty():
		return false
	var first = seats[0]
	if not (first is Dictionary):
		return false
	return str((first as Dictionary).get("token", "")) == str(token).strip_edges()


func _public_seats(room: Dictionary) -> Array:
	var out: Array = []
	for s in (room.get("seats", []) as Array):
		if s is Dictionary:
			out.append({
				"seat": int((s as Dictionary).get("seat", 0)),
				"name": str((s as Dictionary).get("name", "")),
				"is_bot": bool((s as Dictionary).get("is_bot", false)),
			})
	return out


func _renumber(room: Dictionary) -> void:
	var seats: Array = room.get("seats", [])
	for i in range(seats.size()):
		if seats[i] is Dictionary:
			(seats[i] as Dictionary)["seat"] = i


func _seat_update(code: String) -> Dictionary:
	var room := _get_room(code)
	if room.is_empty():
		return {"m": "seat_update", "code": _norm_code(code), "seats": 0}
	var seats: Array = room.get("seats", [])
	return {
		"m": "seat_update", "code": str(room["code"]),
		"seats": seats.size(), "seat_count": seats.size(),
		"seats_list": _public_seats(room),
		"started": bool(room.get("started", false)),
	}


func _state_sync(code: String) -> Dictionary:
	var room := _get_room(code)
	if room.is_empty():
		return {"m": "state_sync", "code": _norm_code(code)}
	var game = room.get("game", null)
	var sync := {
		"m": "state_sync", "code": str(room["code"]),
		"seats": (room.get("seats", []) as Array).size(),
		"started": bool(room.get("started", false)),
		"seats_list": _public_seats(room),
	}
	if game is LocalGame:
		sync["turn"] = (game as LocalGame).current_player()
		sync["scores"] = (game as LocalGame).scores()
		sync["over"] = (game as LocalGame).is_over()
		sync["ending"] = (game as LocalGame).ending()
	return sync


func _turn_frame(code: String, reply: Dictionary) -> Dictionary:
	var room := _get_room(code)
	var delta = reply.get("delta", {})
	if delta is Dictionary and str((delta as Dictionary).get("m", "")) != "":
		var frame: Dictionary = (delta as Dictionary).duplicate(true)
		frame["code"] = code
		return frame
	if room.is_empty() or room.get("game") == null:
		return {"m": "turn_update", "code": code}
	var game: LocalGame = room["game"]
	var frame: Dictionary = game.state_delta()
	frame["code"] = code
	return frame


func _gen_code() -> String:
	while true:
		var code := ""
		for i: int in range(CODE_LEN):
			code += CODE_ALPHABET.substr(_rng.randi_range(0, CODE_ALPHABET.length() - 1), 1)
		if not _rooms.has(code):
			return code
	return "AAAA"


func _gen_token() -> String:
	while true:
		var tok := ""
		for i: int in range(TOKEN_LEN):
			tok += TOKEN_HEX.substr(_rng.randi_range(0, TOKEN_HEX.length() - 1), 1)
		if not _token_used(tok):
			return tok
	return "0".repeat(TOKEN_LEN)


func _token_used(tok: String) -> bool:
	for key in _rooms:
		var room = _rooms[key]
		if not (room is Dictionary):
			continue
		for s in ((room as Dictionary).get("seats", []) as Array):
			if s is Dictionary and str((s as Dictionary).get("token", "")) == tok:
				return true
	return false


static func _str_field(req: Dictionary, keys: Array, fallback: String = "") -> String:
	for k in keys:
		if req.has(k) and req[k] != null:
			var s := str(req[k]).strip_edges()
			if s != "":
				return s
	return fallback


static func _as_version(req: Dictionary) -> int:
	var raw = req.get("v", null)
	if raw == null:
		raw = req.get("version", null)
	if raw == null:
		return -1
	if raw is int:
		return int(raw)
	if raw is float:
		return int(raw)
	var s := str(raw).strip_edges()
	if s == "" or not s.is_valid_int():
		return -1
	return int(s)


# "H8" or "8H" (either order, any case): letter A-O is the column, number
# 1-15 is the row. Returns Vector2i(-1, -1) when the text is not a square.
static func parse_square(raw: String) -> Vector2i:
	var s := raw.strip_edges().to_upper()
	if s.is_empty():
		return Vector2i(-1, -1)
	var letters := ""
	var digits := ""
	for i: int in range(s.length()):
		var ch := s.substr(i, 1)
		if ch >= "A" and ch <= "Z":
			letters += ch
		elif ch >= "0" and ch <= "9":
			digits += ch
		else:
			return Vector2i(-1, -1)
	if letters.length() != 1 or digits == "":
		return Vector2i(-1, -1)
	var col := letters.unicode_at(0) - 65
	var row := int(digits) - 1
	if col < 0 or col > 14 or row < 0 or row > 14:
		return Vector2i(-1, -1)
	return Vector2i(col, row)


# Normalizes one place_tiles tile list into facade placements plus a
# blank_map. Accepts {square, letter, blank_as} triples and plain
# {col, row, letter, blank} dicts.
static func _to_placements(tiles: Array) -> Dictionary:
	var placements: Array = []
	var blank_map := {}
	if tiles.is_empty():
		return {"ok": false, "error": "BAD_TILES"}
	for t in tiles:
		if not (t is Dictionary):
			return {"ok": false, "error": "BAD_TILES"}
		var d: Dictionary = t
		var col := -1
		var row := -1
		var sq := _str_field(d, ["square", "sq", "pos", "cell", "coord"], "")
		if sq != "":
			var cell := parse_square(sq)
			if cell.x < 0:
				return {"ok": false, "error": "BAD_TILES"}
			col = cell.x
			row = cell.y
		else:
			var col_raw = d.get("col", d.get("x", null))
			var row_raw = d.get("row", d.get("y", null))
			if col_raw == null or row_raw == null:
				return {"ok": false, "error": "BAD_TILES"}
			col = int(col_raw)
			row = int(row_raw)
		if col < 0 or col > 14 or row < 0 or row > 14:
			return {"ok": false, "error": "BAD_TILES"}
		var face := _str_field(d, ["letter", "tile", "face", "value", "char"], "").to_upper()
		var blank_face := _str_field(d, ["blank_as", "face_as", "as"], "").to_upper()
		var blank_flag := bool(d.get("blank", d.get("is_blank", false)))
		if blank_face != "":
			blank_map[Vector2i(col, row)] = blank_face
			placements.append({"col": col, "row": row, "letter": blank_face, "blank": true})
		elif face != "":
			placements.append({"col": col, "row": row, "letter": face, "blank": blank_flag})
		else:
			return {"ok": false, "error": "BAD_TILES"}
	if placements.is_empty():
		return {"ok": false, "error": "BAD_TILES"}
	return {"ok": true, "placements": placements, "blank_map": blank_map}
