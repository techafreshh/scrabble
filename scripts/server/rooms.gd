# Wordtable room registry (headless authoritative host, no scene deps).
# Owns room codes, per-seat session tokens, the host gate, timer fields,
# and one LocalGame per started room for real move adjudication. Pure
# policy (caps, turn gating, reason mapping, clocks, personalization)
# lives in GameBinding; this file owns the rooms dict, the game
# instances, and the `handle_dict` dispatch. Transport-agnostic: the
# server feeds one Dictionary per JSON text frame into `handle_dict` and
# sends back every Dictionary in the returned Array (reply first,
# broadcasts after; the server fans broadcasts out with per-recipient
# racks). Run headless via res://tests/test_runner.gd.
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
	"create_room", "join_room", "rejoin", "resync", "add_bot", "remove_bot", "start_game",
	"place_tiles", "place", "pass", "pass_turn", "exchange", "recall",
	"shuffle_rack", "shuffle", "chat", "emote",
	"get_rack", "rack", "debug_set_rack", "debug_set_bag",
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
	var who := GameBinding.clean_name(player_name, "Host")
	var room := {
		"code": code,
		"seats": [{"seat": 0, "name": who, "token": token, "is_bot": false}],
		"started": false,
		"game": null,
		"options": options.duplicate(true),
		"seed": 0,
		"timer_on": GameBinding.parse_timer_on(options),
		"turn_secs": GameBinding.parse_turn_secs(options),
		"test_mode": GameBinding.parse_test_mode(options),
		"deadline_ms": -1,
		"bot_deadline_ms": -1,
	}
	_rooms[code] = room
	return {
		"ok": true, "m": "create_room", "code": code, "room": code,
		"room_code": code, "seat": 0, "player_id": 0, "you": 0,
		"token": token, "session": token, "seats": 1, "seat_count": 1,
		"started": false, "timer_on": bool(room.get("timer_on", true)),
		"seats_list": _public_seats(room),
	}


# Empty or unknown token means a fresh seat; a known token re-seats the
# caller on their existing seat (rejoin across connections).
func join_room(code: String, player_name: String, token: String = "") -> Dictionary:
	var room := _get_room(code)
	if room.is_empty():
		return _gate_error("join_room", "NO_ROOM")
	var who := GameBinding.clean_name(player_name, "Guest")
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


# Strict token rejoin with a full-state resync snapshot. Unknown rooms
# answer NO_ROOM; an unknown token (empty or wrong alike) answers exactly
# BAD_TOKEN and never mints a seat, so a typo cannot steal or grow the
# table. A known token restores the caller's seat with their own private
# rack plus the shared board, scores, turn, and ending state.
func rejoin(code: String, token: String) -> Dictionary:
	var room := _get_room(code)
	if room.is_empty():
		return _gate_error("rejoin", "NO_ROOM")
	if _seat_by_token(room, token).is_empty():
		return _gate_error("rejoin", "BAD_TOKEN")
	var me := _seat_no(room, token)
	var game = room.get("game", null)
	var turn := 0
	var scores: Array = []
	var rack: Array = []
	var tiles: Array = []
	var over := false
	var ending := ""
	if game is LocalGame:
		turn = (game as LocalGame).current_player()
		scores = (game as LocalGame).scores()
		over = (game as LocalGame).is_over()
		ending = (game as LocalGame).ending()
		if bool(room.get("started", false)):
			rack = rack_for_seat(str(room["code"]), me)
			tiles = (game as LocalGame).board_tiles()
	var seats: Array = room.get("seats", [])
	return {
		"ok": true, "m": "rejoin", "code": str(room["code"]),
		"room": str(room["code"]), "seat": me, "player_id": me, "you": me,
		"token": str(token).strip_edges(), "session": str(token).strip_edges(),
		"seats": seats.size(), "seat_count": seats.size(),
		"started": bool(room.get("started", false)),
		"turn": turn, "scores": scores, "rack": rack,
		"board_tiles": tiles, "over": over, "ending": ending,
		"seats_list": _public_seats(room),
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
		"seat": BOT_NAME, "bot_seated": true,
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
	GameBinding.refresh_deadline(room, _clock_ms())
	_arm_bot(room, _clock_ms())
	var delta: Dictionary = game.state_delta()
	var reply := {
		"ok": true, "m": "start_game", "code": str(room["code"]),
		"started": true, "turn": game.current_player(),
		"seats": seats.size(), "seat_count": seats.size(),
		"scores": game.scores(), "over": game.is_over(),
		"ending": game.ending(), "delta": delta,
		"seats_list": _public_seats(room),
	}
	return GameBinding.personalize(reply, _seat_no(room, token), game.rack_letters(_seat_no(room, token)))


# tiles: [{square: "H8", letter: "Q", blank_as: ""}] with col/row/letter
# dicts also accepted. Only the seat holding the turn may submit; every
# other seated token gets NOT_YOUR_TURN.
func place_tiles(code: String, token: String, tiles: Array) -> Dictionary:
	var room := _get_room(code)
	if room.is_empty():
		return _gate_error("place_tiles", "NO_ROOM")
	if _seat_by_token(room, token).is_empty():
		return _gate_error("place_tiles", "NO_TOKEN")
	if not bool(room.get("started", false)) or room.get("game") == null:
		return _gate_error("place_tiles", "BAD_STATE")
	var game: LocalGame = room["game"]
	var me := _seat_no(room, token)
	if me != game.current_player():
		return _turn_error("place_tiles", room, me)
	var conv := _to_placements(tiles)
	if not bool(conv.get("ok", false)):
		return _gate_error("place_tiles", str(conv.get("error", "BAD_TILES")))
	var res: Dictionary = game.place(conv.get("placements", []), conv.get("blank_map", {}))
	if not bool(res.get("ok", false)):
		return {
			"ok": false, "m": "place_tiles", "code": str(room["code"]),
			"accepted": false, "points": 0,
			"error": GameBinding.map_reason(str(res.get("reason", "BAD_PLAY"))),
			"reason": GameBinding.map_reason(str(res.get("reason", "BAD_PLAY"))),
			"reason_word": str(res.get("reason_word", "")),
			"kind": str(res.get("kind", "reject")),
			"total": int(res.get("total", 0)),
			"turn": game.current_player(), "scores": game.scores(),
			"over": game.is_over(), "ending": game.ending(),
		}
	GameBinding.refresh_deadline(room, _clock_ms())
	_arm_bot(room, _clock_ms())
	var total := int(res.get("total", 0))
	var reply := {
		"ok": true, "m": "place_tiles", "code": str(room["code"]),
		"kind": "commit", "reason": "OK",
		"accepted": true, "points": total,
		"words": res.get("words", []),
		"main_points": int(res.get("main_points", 0)),
		"cross_points": int(res.get("cross_points", 0)),
		"bingo": int(res.get("bingo", 0)), "total": total,
		"turn": game.current_player(), "scores": game.scores(),
		"over": game.is_over(), "ending": game.ending(),
		"delta": res.get("delta", {}),
	}
	return GameBinding.personalize(reply, me, game.rack_letters(me))


func pass_turn(code: String, token: String) -> Dictionary:
	var room := _get_room(code)
	if room.is_empty():
		return _gate_error("pass", "NO_ROOM")
	if _seat_by_token(room, token).is_empty():
		return _gate_error("pass", "NO_TOKEN")
	if not bool(room.get("started", false)) or room.get("game") == null:
		return _gate_error("pass", "BAD_STATE")
	var game: LocalGame = room["game"]
	var me := _seat_no(room, token)
	if me != game.current_player():
		return _turn_error("pass", room, me)
	var res: Dictionary = game.pass_turn()
	if not bool(res.get("ok", false)):
		return {
			"ok": false, "m": "pass", "code": str(room["code"]),
			"accepted": false,
			"error": GameBinding.map_reason(str(res.get("reason", "BAD_PLAY"))),
			"reason": GameBinding.map_reason(str(res.get("reason", "BAD_PLAY"))),
			"turn": game.current_player(), "scores": game.scores(),
			"over": game.is_over(), "ending": game.ending(),
		}
	GameBinding.refresh_deadline(room, _clock_ms())
	_arm_bot(room, _clock_ms())
	var reply := {
		"ok": true, "m": "pass", "code": str(room["code"]),
		"kind": "pass", "reason": "OK", "accepted": true,
		"turn": game.current_player(), "scores": game.scores(),
		"over": game.is_over(), "ending": game.ending(),
		"delta": res.get("delta", {}),
	}
	return GameBinding.personalize(reply, me, game.rack_letters(me))


func exchange(code: String, token: String, count: int) -> Dictionary:
	var room := _get_room(code)
	if room.is_empty():
		return _gate_error("exchange", "NO_ROOM")
	if _seat_by_token(room, token).is_empty():
		return _gate_error("exchange", "NO_TOKEN")
	if not bool(room.get("started", false)) or room.get("game") == null:
		return _gate_error("exchange", "BAD_STATE")
	var game: LocalGame = room["game"]
	var me := _seat_no(room, token)
	if me != game.current_player():
		return _turn_error("exchange", room, me)
	var res: Dictionary = game.exchange(count)
	if not bool(res.get("ok", false)):
		return {
			"ok": false, "m": "exchange", "code": str(room["code"]),
			"accepted": false,
			"error": GameBinding.map_reason(str(res.get("reason", "BAD_PLAY"))),
			"reason": GameBinding.map_reason(str(res.get("reason", "BAD_PLAY"))),
			"turn": game.current_player(), "scores": game.scores(),
			"over": game.is_over(), "ending": game.ending(),
		}
	GameBinding.refresh_deadline(room, _clock_ms())
	_arm_bot(room, _clock_ms())
	var reply := {
		"ok": true, "m": "exchange", "code": str(room["code"]),
		"kind": "exchange", "reason": "OK", "accepted": true,
		"turn": game.current_player(), "scores": game.scores(),
		"over": game.is_over(), "ending": game.ending(),
		"delta": res.get("delta", {}),
	}
	return GameBinding.personalize(reply, me, game.rack_letters(me))


func recall(code: String, token: String) -> Dictionary:
	var room := _get_room(code)
	if room.is_empty():
		return _gate_error("recall", "NO_ROOM")
	if _seat_by_token(room, token).is_empty():
		return _gate_error("recall", "NO_TOKEN")
	if not bool(room.get("started", false)) or room.get("game") == null:
		return _gate_error("recall", "BAD_STATE")
	var game: LocalGame = room["game"]
	var me := _seat_no(room, token)
	if me != game.current_player():
		return _turn_error("recall", room, me)
	var res: Dictionary = game.recall()
	var reply := {
		"ok": true, "m": "recall", "code": str(room["code"]),
		"kind": "recall", "reason": "OK",
		"recalled": int(res.get("recalled", 0)),
		"rack": res.get("rack", []),
		"turn": game.current_player(), "scores": game.scores(),
		"over": game.is_over(), "ending": game.ending(),
	}
	return GameBinding.personalize(reply, me, game.rack_letters(me))


func shuffle_rack(code: String, token: String) -> Dictionary:
	var room := _get_room(code)
	if room.is_empty():
		return _gate_error("shuffle_rack", "NO_ROOM")
	if _seat_by_token(room, token).is_empty():
		return _gate_error("shuffle_rack", "NO_TOKEN")
	if not bool(room.get("started", false)) or room.get("game") == null:
		return _gate_error("shuffle_rack", "BAD_STATE")
	var game: LocalGame = room["game"]
	var me := _seat_no(room, token)
	if me != game.current_player():
		return _turn_error("shuffle_rack", room, me)
	var res: Dictionary = game.shuffle()
	if not bool(res.get("ok", false)):
		return {
			"ok": false, "m": "shuffle_rack", "code": str(room["code"]),
			"accepted": false,
			"error": GameBinding.map_reason(str(res.get("reason", "BAD_PLAY"))),
			"reason": GameBinding.map_reason(str(res.get("reason", "BAD_PLAY"))),
			"turn": game.current_player(),
		}
	var reply := {
		"ok": true, "m": "shuffle_rack", "code": str(room["code"]),
		"kind": "shuffle", "reason": "OK",
		"rack": res.get("rack", []),
		"turn": game.current_player(), "scores": game.scores(),
	}
	return GameBinding.personalize(reply, me, game.rack_letters(me))


# Caller-only rack dump: the reply carries just this seat's letters and
# is never broadcast, so racks stay private to their owners.
func get_rack(code: String, token: String) -> Dictionary:
	var room := _get_room(code)
	if room.is_empty():
		return _gate_error("get_rack", "NO_ROOM")
	if _seat_by_token(room, token).is_empty():
		return _gate_error("get_rack", "NO_TOKEN")
	if not bool(room.get("started", false)) or room.get("game") == null:
		return _gate_error("get_rack", "BAD_STATE")
	var game: LocalGame = room["game"]
	var me := _seat_no(room, token)
	return {
		"ok": true, "m": "get_rack", "code": str(room["code"]),
		"seat": me, "you": me,
		"rack": game.rack_letters(me),
		"turn": game.current_player(), "scores": game.scores(),
		"over": game.is_over(), "ending": game.ending(),
	}


# Test-only hooks: rooms created with options.test_mode accept host-driven
# rack/bag pins so scenarios can force legal, illegal, and privacy cases.
# Any other room (or a non-host caller) is refused without touching state.
func debug_set_rack(code: String, token: String, seat: int, tiles: Array) -> Dictionary:
	var room := _get_room(code)
	if room.is_empty():
		return _gate_error("debug_set_rack", "NO_ROOM")
	if _seat_by_token(room, token).is_empty():
		return _gate_error("debug_set_rack", "NO_TOKEN")
	if not bool(room.get("test_mode", false)):
		return _gate_error("debug_set_rack", "BAD_STATE")
	if not _is_host(room, token):
		return _gate_error("debug_set_rack", "NOT_HOST")
	if not bool(room.get("started", false)) or room.get("game") == null:
		return _gate_error("debug_set_rack", "BAD_STATE")
	var game: LocalGame = room["game"]
	if seat < 0 or seat >= game.player_count():
		return _gate_error("debug_set_rack", "BAD_STATE")
	game.debug_set_rack(seat, tiles)
	return {
		"ok": true, "m": "debug_set_rack", "code": str(room["code"]),
		"seat": seat, "rack": game.rack_letters(seat),
	}


func debug_set_bag(code: String, token: String, tiles: Array) -> Dictionary:
	var room := _get_room(code)
	if room.is_empty():
		return _gate_error("debug_set_bag", "NO_ROOM")
	if _seat_by_token(room, token).is_empty():
		return _gate_error("debug_set_bag", "NO_TOKEN")
	if not bool(room.get("test_mode", false)):
		return _gate_error("debug_set_bag", "BAD_STATE")
	if not _is_host(room, token):
		return _gate_error("debug_set_bag", "NOT_HOST")
	if not bool(room.get("started", false)) or room.get("game") == null:
		return _gate_error("debug_set_bag", "BAD_STATE")
	var game: LocalGame = room["game"]
	game.debug_set_bag(tiles)
	return {
		"ok": true, "m": "debug_set_bag", "code": str(room["code"]),
		"bag_remaining": game.bag_remaining(),
	}


# Seat helpers for per-recipient fan-out: -1 (or []) when unknown.
func seat_of_token(code: String, token: String) -> int:
	var room := _get_room(code)
	if room.is_empty():
		return -1
	return _seat_no(room, token)


func rack_for_seat(code: String, seat: int) -> Array:
	var room := _get_room(code)
	if room.is_empty() or room.get("game", null) == null:
		return []
	if not bool(room.get("started", false)):
		return []
	var game: LocalGame = room["game"]
	if seat < 0 or seat >= game.player_count():
		return []
	return game.rack_letters(seat)


# Test hook: force this room's deadline to expire on the next poll.
func debug_expire(code: String) -> bool:
	var room := _get_room(code)
	if room.is_empty():
		return false
	room["deadline_ms"] = 0
	return true


# Clock sweep: one shared broadcast frame per expired started non-over
# room. Auto-pass runs facade recall() then pass_turn() (never the state
# machine directly, so _events/delta bookkeeping stays consistent),
# refreshes the deadline, and counts like any manual scoreless turn.
func poll_timers(now_ms: int) -> Array:
	var out: Array = []
	for key in _rooms.keys():
		var room = _rooms[key]
		if not (room is Dictionary):
			continue
		if not bool((room as Dictionary).get("started", false)):
			continue
		if (room as Dictionary).get("game", null) == null:
			continue
		var game: LocalGame = (room as Dictionary)["game"]
		if game.is_over():
			continue
		if _poll_bot(room as Dictionary, game, int(now_ms), out):
			continue
		if not GameBinding.is_expired(room as Dictionary, int(now_ms)):
			continue
		game.recall()
		game.pass_turn()
		GameBinding.refresh_deadline(room as Dictionary, int(now_ms))
		var frame: Dictionary = game.state_delta()
		frame["code"] = str((room as Dictionary).get("code", key))
		frame["board_tiles"] = game.board_tiles()
		frame["auto_pass"] = true
		out.append(frame)
	return out


# Bot think-delay branch: when the turn sits on a bot seat past its think
# deadline, commit one BotSeat move (pass fallback when none is legal),
# refresh the clock, re-arm for the next turn, and emit the same
# turn_update/game_over frame shape as auto-pass plus bot_move:true.
# Returns true when it consumed this tick for the room. No new wire methods.
func _poll_bot(room: Dictionary, game: LocalGame, now_ms: int, out: Array) -> bool:
	if int(room.get("bot_deadline_ms", -1)) < 0:
		return false
	if int(now_ms) < int(room.get("bot_deadline_ms", -1)):
		return false
	var turn := game.current_player()
	var seats: Array = room.get("seats", [])
	if turn < 0 or turn >= seats.size():
		room["bot_deadline_ms"] = -1
		return false
	var seat = seats[turn]
	if not (seat is Dictionary) or not bool((seat as Dictionary).get("is_bot", false)):
		room["bot_deadline_ms"] = -1
		return false
	var mv := BotSeat.choose_move(game.board, game.rack_letters(turn), _lexicon, _bot_seed(room))
	if bool(mv.get("ok", false)):
		game.place(mv.get("placements", []), mv.get("blank_map", {}))
	else:
		game.recall()
		game.pass_turn()
	GameBinding.refresh_deadline(room, now_ms)
	_arm_bot(room, now_ms)
	var frame: Dictionary = game.state_delta()
	frame["code"] = str(room.get("code", ""))
	frame["board_tiles"] = game.board_tiles()
	frame["bot_move"] = true
	out.append(frame)
	return true


# Bot seed per turn: the room seed plus completed turns so every bot move
# draws a fresh deterministic seed.
func _bot_seed(room: Dictionary) -> int:
	var h := 0
	var game = room.get("game", null)
	if game is LocalGame:
		h = (game as LocalGame).history().size()
	return int(room.get("seed", 0)) + h


# Arms the think deadline when the turn sits on a bot seat of a live game,
# else leaves it disarmed (-1), mirroring GameBinding.refresh_deadline.
# Driven through the BotSeat seam so rooms and the soak share one oracle.
func _arm_bot(room: Dictionary, now_ms: int) -> void:
	room["bot_deadline_ms"] = -1
	if not bool(room.get("started", false)):
		return
	var game = room.get("game", null)
	if not (game is LocalGame):
		return
	if (game as LocalGame).is_over():
		return
	var seats: Array = room.get("seats", [])
	var turn := (game as LocalGame).current_player()
	if turn < 0 or turn >= seats.size():
		return
	var seat = seats[turn]
	if seat is Dictionary and bool((seat as Dictionary).get("is_bot", false)):
		room["bot_deadline_ms"] = int(now_ms) + BotSeat.think_delay_ms(_bot_seed(room))


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
	var msg := GameBinding.clean_text(text)
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
			for k in ["timer_on", "timer_off", "test_mode"] + GameBinding.TURN_SECS_ALIASES:
				if req.has(k) and not (opts as Dictionary).has(k):
					opts[k] = req[k]
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
		"rejoin", "resync":
			var reply := rejoin(
				_str_field(req, ["code", "room", "room_code"], ""),
				_str_field(req, ["token", "session", "session_token"], "")
			)
			reply["m"] = m_raw
			return [reply]
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
		"get_rack", "rack":
			var reply := get_rack(
				_str_field(req, ["code", "room", "room_code"], ""),
				_str_field(req, ["token", "session", "session_token"], "")
			)
			reply["m"] = m_raw
			return [reply]
		"debug_set_rack":
			var arg = req.get("tiles", req.get("rack", req.get("letters", [])))
			var reply := debug_set_rack(
				_str_field(req, ["code", "room", "room_code"], ""),
				_str_field(req, ["token", "session", "session_token"], ""),
				_opt_seat(req), _parse_tiles_arg(arg)
			)
			reply["m"] = m_raw
			return [reply]
		"debug_set_bag":
			var argb = req.get("tiles", req.get("bag", req.get("letters", [])))
			var reply := debug_set_bag(
				_str_field(req, ["code", "room", "room_code"], ""),
				_str_field(req, ["token", "session", "session_token"], ""),
				_parse_tiles_arg(argb)
			)
			reply["m"] = m_raw
			return [reply]
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


func _clock_ms() -> int:
	return int(Time.get_ticks_msec())


func _seat_no(room: Dictionary, token: String) -> int:
	var seat := _seat_by_token(room, token)
	if seat.is_empty():
		return -1
	return int(seat.get("seat", -1))


# Turn-authority reject: every gated intent carries accepted:false so
# probes can assert on one flat shape; place rejects also carry the
# points/total/reason_word fields of gameplay rejects.
func _turn_error(m: String, room: Dictionary, seat: int) -> Dictionary:
	var game: LocalGame = room["game"]
	var frame := {
		"m": m, "ok": false,
		"error": GameBinding.NOT_YOUR_TURN, "reason": GameBinding.NOT_YOUR_TURN,
		"accepted": false,
		"turn": game.current_player(), "scores": game.scores(),
		"over": game.is_over(), "ending": game.ending(),
	}
	if m == "place_tiles" or m == "place":
		frame["kind"] = "reject"
		frame["points"] = 0
		frame["total"] = 0
		frame["reason_word"] = ""
	return frame


func _gate_error(m: String, code: String) -> Dictionary:
	return {"m": m, "ok": false, "error": code, "reason": code}


# Seat-number parsing for wire input: JSON numbers arrive as floats, so
# numeric values convert directly; strings must be valid ints. Anything
# else (missing, blank, garbage) yields -1 and the caller refuses it.
static func _opt_seat(req: Dictionary) -> int:
	for k in ["seat", "player", "player_id", "you", "bot_seat"]:
		if not req.has(k) or req.get(k) == null:
			continue
		var v = req.get(k)
		if v is bool:
			continue
		if v is int or v is float:
			return int(v)
		var s := str(v).strip_edges()
		if s == "":
			continue
		if s.is_valid_int():
			return int(s)
		return -1
	return -1


# Debug tile-arg normalization: a bare String is one tile per character
# ("CATDEFG"; "_", "?", ".", "*" mean blank), an Array is one tile
# per element; anything else yields [].
static func _parse_tiles_arg(raw) -> Array:
	var out: Array = []
	if raw is String:
		var s := str(raw)
		for i: int in range(s.length()):
			var ch := s.substr(i, 1).strip_edges().to_upper()
			if ch == "" or ch == "," or ch == ";" or ch == "|" or ch == " ":
				continue
			if ch == "_" or ch == "?" or ch == "." or ch == "*":
				out.append("")
			else:
				out.append(ch)
		return out
	if raw is Array:
		for t in (raw as Array):
			if t is Dictionary:
				var d := t as Dictionary
				out.append(str(d.get("letter", d.get("face", ""))).strip_edges().to_upper())
			else:
				out.append(str(t).strip_edges().to_upper())
		return out
	return out


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
		sync["board_tiles"] = (game as LocalGame).board_tiles()
	return sync


func _turn_frame(code: String, reply: Dictionary) -> Dictionary:
	var room := _get_room(code)
	var delta = reply.get("delta", {})
	if delta is Dictionary and str((delta as Dictionary).get("m", "")) != "":
		var frame: Dictionary = (delta as Dictionary).duplicate(true)
		frame["code"] = code
		if not room.is_empty() and room.get("game", null) is LocalGame:
			frame["board_tiles"] = (room["game"] as LocalGame).board_tiles()
		return frame
	if room.is_empty() or room.get("game") == null:
		return {"m": "turn_update", "code": code}
	var game: LocalGame = room["game"]
	var frame: Dictionary = game.state_delta()
	frame["code"] = code
	frame["board_tiles"] = game.board_tiles()
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
