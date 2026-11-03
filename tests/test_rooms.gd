# Wordtable room registry suite (pure logic, no scene deps).
# Run headless via res://tests/test_runner.gd (`--suite rooms` or full run).
# Covers code/token shape and uniqueness, seats, token rejoin, the host
# gate, version/error gates, and facade scoring parity on the CAT opening.
# Prints the acceptance marker: rooms_complete=true.
class_name TestRooms
extends RefCounted


# Minimal lexicon double mirroring TestFacade's (duck-typed via is_word).
class FakeLexicon extends RefCounted:
	var _words: Dictionary = {}

	func _init(word_list: Array = []) -> void:
		for w in word_list:
			_words[str(w).strip_edges().to_upper()] = true

	func is_word(raw: String) -> bool:
		var w := str(raw).strip_edges().to_upper()
		if w.is_empty():
			return false
		return _words.has(w)


static func _is_code_char(ch: String) -> bool:
	return RoomRegistry.CODE_ALPHABET.find(ch) != -1


static func _is_hex_char(ch: String) -> bool:
	return RoomRegistry.TOKEN_HEX.find(ch) != -1


static func run_all(runner: SceneTree) -> void:
	print("rooms_players=4")
	var reg := RoomRegistry.new(null)

	# Code shape: 4 chars from the no-confusables alphabet.
	var r0 := reg.create_room("Host")
	runner.assert_true(bool(r0.get("ok", false)), "rooms_create_ok")
	var code := str(r0.get("code", ""))
	runner.assert_eq(code.length(), 4, "rooms_code_len_4")
	var code_clean := true
	for i: int in range(code.length()):
		if not _is_code_char(code.substr(i, 1)):
			code_clean = false
	runner.assert_true(code_clean, "rooms_code_charset")
	runner.assert_eq(int(r0.get("seat", -1)), 0, "rooms_host_seat_0")
	runner.assert_eq(int(r0.get("seats", -1)), 1, "rooms_create_seats_1")

	# Token shape: 32 lowercase hex chars.
	var tok0 := str(r0.get("token", ""))
	runner.assert_eq(tok0.length(), 32, "rooms_token_len_32")
	var tok_clean := true
	for i: int in range(tok0.length()):
		if not _is_hex_char(tok0.substr(i, 1)):
			tok_clean = false
	runner.assert_true(tok_clean, "rooms_token_hex")

	# Uniqueness over 200 rooms (codes and tokens alike).
	var seen_codes := {code: true}
	var seen_toks := {tok0: true}
	for i: int in range(199):
		var r := reg.create_room("P%d" % i)
		seen_codes[str(r.get("code", ""))] = true
		seen_toks[str(r.get("token", ""))] = true
	runner.assert_eq(seen_codes.size(), 200, "rooms_codes_unique_200")
	runner.assert_eq(seen_toks.size(), 200, "rooms_tokens_unique_200")

	# Join grows seats; token rejoin restores the same seat without growth.
	var j1 := reg.join_room(code, "Guest")
	runner.assert_true(bool(j1.get("ok", false)), "rooms_join_ok")
	runner.assert_eq(int(j1.get("seats", -1)), 2, "rooms_join_seats_2")
	runner.assert_eq(int(j1.get("seat", -1)), 1, "rooms_join_seat_1")
	var tok1 := str(j1.get("token", ""))
	var j1b := reg.join_room(code, "Guest?", tok1)
	runner.assert_true(bool(j1b.get("ok", false)), "rooms_rejoin_ok")
	runner.assert_eq(int(j1b.get("seat", -1)), 1, "rooms_rejoin_same_seat")
	runner.assert_eq(int(j1b.get("seats", -1)), 2, "rooms_rejoin_no_growth")
	runner.assert_eq(str(j1b.get("token", "")), tok1, "rooms_rejoin_same_token")

	# Case-insensitive code lookup with surrounding whitespace tolerated.
	var jlow := reg.join_room("  " + code.to_lower() + "  ", "Low")
	runner.assert_true(bool(jlow.get("ok", false)), "rooms_join_case_insensitive")
	runner.assert_eq(int(jlow.get("seats", -1)), 3, "rooms_join_seats_3")

	# Unknown room and bad token gates.
	var bad_room := reg.join_room("ZZZZ", "Nobody")
	runner.assert_eq(bool(bad_room.get("ok", true)), false, "rooms_unknown_room_not_ok")
	runner.assert_eq(str(bad_room.get("error", "")), "NO_ROOM", "rooms_unknown_room_no_room")
	var bad_tok := reg.start_game(code, "0".repeat(32))
	runner.assert_eq(str(bad_tok.get("error", "")), "NO_TOKEN", "rooms_bad_token_no_token")

	# Fourth seat fills the 4-seat cap; the fifth join is ROOM_FULL.
	var j3 := reg.join_room(code, "Fourth")
	runner.assert_true(bool(j3.get("ok", false)), "rooms_fourth_ok")
	runner.assert_eq(int(j3.get("seats", -1)), 4, "rooms_seats_cap_4")
	var full := reg.join_room(code, "Fifth")
	runner.assert_eq(str(full.get("error", "")), "ROOM_FULL", "rooms_fifth_room_full")

	# Host gate: guest token cannot add bots or start games.
	var guest_bot := reg.add_bot(code, tok1)
	runner.assert_eq(str(guest_bot.get("error", "")), "NOT_HOST", "rooms_guest_add_bot_not_host")
	var guest_start := reg.start_game(code, tok1)
	runner.assert_eq(str(guest_start.get("error", "")), "NOT_HOST", "rooms_guest_start_not_host")

	# Solo room cannot start without an opponent.
	var solo := reg.create_room("Solo")
	var solo_start := reg.start_game(str(solo.get("code", "")), str(solo.get("token", "")))
	runner.assert_eq(str(solo_start.get("error", "")), "NEED_OPPONENT", "rooms_solo_need_opponent")

	# Host adds the Botgomery stub, then starts for real.
	var bot := reg.add_bot(code, tok0)
	runner.assert_eq(bool(bot.get("ok", false)), false, "rooms_full_add_bot_fails")
	runner.assert_eq(str(bot.get("error", "")), "ROOM_FULL", "rooms_full_add_bot_room_full")
	var room2 := reg.create_room("Host2")
	var code2 := str(room2.get("code", ""))
	var tok2 := str(room2.get("token", ""))
	var bot2 := reg.add_bot(code2, tok2)
	runner.assert_true(bool(bot2.get("ok", false)), "rooms_add_bot_ok")
	runner.assert_eq(int(bot2.get("seats", -1)), 2, "rooms_add_bot_seats_2")
	runner.assert_true(bool(reg.remove_bot(code2, tok2).get("ok", false)), "rooms_remove_bot_ok")
	var guest2 := reg.join_room(code2, "Guest2")
	runner.assert_eq(int(guest2.get("seats", -1)), 2, "rooms_rejoin_after_remove_seats_2")
	var started := reg.start_game(code2, tok2)
	runner.assert_true(bool(started.get("ok", false)), "rooms_start_ok")
	runner.assert_true(bool(started.get("started", false)), "rooms_started_true")
	runner.assert_eq(int(started.get("turn", -1)), 0, "rooms_start_turn_0")
	var twice := reg.start_game(code2, tok2)
	runner.assert_eq(str(twice.get("error", "")), "BAD_STATE", "rooms_double_start_bad_state")

	# Dispatcher gates: bad version and unknown method.
	var bad_v := reg.handle_dict({"v": 2, "m": "create_room", "name": "H"})
	runner.assert_eq(bad_v.size(), 1, "rooms_bad_version_single_frame")
	runner.assert_eq(str((bad_v[0] as Dictionary).get("error", "")), "BAD_VERSION", "rooms_bad_version")
	var bad_m := reg.handle_dict({"v": 1, "m": "frobnicate"})
	runner.assert_eq(str((bad_m[0] as Dictionary).get("error", "")), "UNKNOWN_MESSAGE", "rooms_unknown_message")

	# Facade parity: registry place_tiles total equals the direct rules
	# total on the CAT opening from test_facade.gd.
	var lex := FakeLexicon.new(["CAT", "CATS", "OX", "CO", "AX", "TE", "OXE"])
	var reg3 := RoomRegistry.new(lex)
	var h := reg3.create_room("Host")
	var hc := str(h.get("code", ""))
	var ht := str(h.get("token", ""))
	var guest_tok := str(reg3.join_room(hc, "Guest").get("token", ""))
	reg3.start_game(hc, ht)
	var game: LocalGame = reg3.debug_game(hc)
	runner.assert_true(game != null, "rooms_debug_game_present")
	game.debug_set_rack(0, ["C", "A", "T", "D", "E", "F", "G"])
	var rack0: Array = game.rack_letters(0)
	var cat := [
		{"col": 6, "row": 7, "letter": "C", "blank": false},
		{"col": 7, "row": 7, "letter": "A", "blank": false},
		{"col": 8, "row": 7, "letter": "T", "blank": false},
	]
	var expect := ScrabbleRules.validate_move(game.board, cat, lex, rack0)
	runner.assert_true(bool(expect.get("ok", false)), "rooms_cat_expect_ok")
	var placed := reg3.place_tiles(hc, ht, cat)
	runner.assert_true(bool(placed.get("ok", false)), "rooms_cat_place_ok")
	runner.assert_eq(
		int(placed.get("total", -1)), int(expect.get("total", -2)), "rooms_parity_cat_total"
	)
	# Square-notation triple for the CATS extension on P1's turn.
	game.debug_set_rack(1, ["S", "H", "I", "J", "K", "L", "M"])
	var cats := [{"square": "J8", "letter": "S", "blank_as": ""}]
	var placed2 := reg3.place_tiles(hc, guest_tok, cats)
	runner.assert_true(bool(placed2.get("ok", false)), "rooms_cats_place_ok")
	runner.assert_eq(int(placed2.get("total", -1)), 6, "rooms_cats_total_6")
	# Pass advances the turn through the dispatcher (reply first frame).
	var frames: Array = reg3.handle_dict({"v": 1, "m": "pass", "code": hc, "token": ht})
	runner.assert_true((frames[0] as Dictionary).get("ok", false), "rooms_pass_ok")
	runner.assert_eq(int((frames[0] as Dictionary).get("turn", -1)), 1, "rooms_pass_turn_1")
	runner.assert_eq(str((frames[0] as Dictionary).get("m", "")), "pass", "rooms_pass_echoes_m")
	# Lobby chat round-trips the text with a chat broadcast attached.
	var said: Array = reg3.handle_dict({"v": 1, "m": "chat", "code": hc, "token": ht, "text": "gl hf"})
	runner.assert_true(bool((said[0] as Dictionary).get("ok", false)), "rooms_chat_ok")
	runner.assert_eq(str((said[0] as Dictionary).get("text", "")), "gl hf", "rooms_chat_echo")
	runner.assert_eq(str((said[1] as Dictionary).get("m", "")), "chat", "rooms_chat_broadcast")
	print("rooms_complete=true")
