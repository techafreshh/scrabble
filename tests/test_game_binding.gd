# Wordtable server-game binding suite (pure logic, no scene deps).
# Run headless via res://tests/test_runner.gd (`--suite game_binding` or full run).
# Covers caps, turn gating, lexicon mapping, reply shaping, rack privacy,
# timer auto-pass/deadline discipline, and the six-scoreless ending.
# Prints the acceptance marker: game_binding_complete=true.
class_name TestGameBinding
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


const HUGE_NOW := 4000000000000000000


static func _open2(runner: SceneTree, lex: FakeLexicon, options: Dictionary = {}) -> Array:
	var reg := RoomRegistry.new(lex)
	var h := reg.create_room("Host", options)
	var hc := str(h.get("code", ""))
	var ht := str(h.get("token", ""))
	var gt := str(reg.join_room(hc, "Guest").get("token", ""))
	reg.start_game(hc, ht)
	runner.assert_true(bool(reg.debug_game(hc) != null), "binding_game_present")
	return [reg, hc, ht, gt]


static func run_all(runner: SceneTree) -> void:
	var lex := FakeLexicon.new(["CAT", "CATS", "OX", "CO", "AX", "TE", "OXE"])

	# 16/200 caps mirror the client views.
	runner.assert_eq(
		GameBinding.clean_name("0123456789ABCDEFGHIJ", "Host"),
		"0123456789ABCDEF", "binding_name_cap_16"
	)
	runner.assert_eq(GameBinding.clean_name("   ", "Host"), "Host", "binding_name_blank_host")
	runner.assert_eq(GameBinding.clean_name("  Bob  ", "Guest"), "Bob", "binding_name_trim")
	runner.assert_eq(GameBinding.clean_text("x".repeat(250)).length(), 200, "binding_text_cap_200")
	runner.assert_eq(GameBinding.clean_text("  hi  "), "hi", "binding_text_trim")
	runner.assert_eq(GameBinding.map_reason("NOT_IN_DICTIONARY"), "NOT_IN_LEXICON", "binding_map_lexicon")
	runner.assert_eq(GameBinding.map_reason("PENDING_NOT_EMPTY"), "PENDING_NOT_EMPTY", "binding_map_passthrough")
	runner.assert_eq(GameBinding.parse_timer_on({"timer_off": true}), false, "binding_timer_off")
	runner.assert_eq(GameBinding.parse_timer_on({"timer_on": false}), false, "binding_timer_explicit_off")
	runner.assert_eq(GameBinding.parse_timer_on({}), true, "binding_timer_default_on")
	runner.assert_eq(GameBinding.parse_turn_secs({"timer_secs": 5}), 5, "binding_alias_timer_secs")
	runner.assert_eq(GameBinding.parse_turn_secs({"turn_timeout": 7}), 7, "binding_alias_turn_timeout")
	runner.assert_eq(GameBinding.parse_turn_secs({"timeout_secs": 9}), 9, "binding_alias_timeout_secs")
	runner.assert_eq(GameBinding.parse_turn_secs({"turn_limit_secs": 11}), 11, "binding_alias_turn_limit_secs")
	runner.assert_eq(GameBinding.parse_turn_secs({"turn_secs": 99999}), 3600, "binding_turn_secs_clamp_hi")
	runner.assert_eq(GameBinding.parse_turn_secs({}), 0, "binding_turn_secs_unset")
	runner.assert_eq(GameBinding.turn_limit_secs({"turn_secs": 0, "timer_on": true}), 90, "binding_limit_on")
	runner.assert_eq(GameBinding.turn_limit_secs({"turn_secs": 0, "timer_on": false}), 180, "binding_limit_off")
	runner.assert_eq(GameBinding.turn_limit_secs({"turn_secs": 5, "timer_on": false}), 5, "binding_limit_override")
	var no_clock := {"deadline_ms": -1}
	runner.assert_eq(GameBinding.is_expired(no_clock, 999999999), false, "binding_no_deadline_never")
	no_clock["deadline_ms"] = 100
	runner.assert_eq(GameBinding.is_expired(no_clock, 99), false, "binding_not_yet_expired")
	runner.assert_eq(GameBinding.is_expired(no_clock, 100), true, "binding_expired_at_deadline")

	var reg0 := RoomRegistry.new(lex)
	var named := reg0.create_room("0123456789ABCDEFGHIJ0123456789")
	var seats_list: Array = named.get("seats_list", [])
	runner.assert_eq(
		str((seats_list[0] as Dictionary).get("name", "")).length(), 16, "binding_room_name_cap_16"
	)
	runner.assert_eq(bool(named.get("timer_on", false)), true, "binding_timer_default_true")

	# NOT_YOUR_TURN on all five gated intents; get_rack stays ungated.
	var parts := _open2(runner, lex)
	var reg: RoomRegistry = parts[0]
	var hc: String = parts[1]
	var ht: String = parts[2]
	var gt: String = parts[3]
	var gp := reg.place_tiles(hc, gt, [{"col": 6, "row": 7, "letter": "C"}])
	runner.assert_eq(bool(gp.get("ok", true)), false, "binding_gate_place_not_ok")
	runner.assert_eq(str(gp.get("error", "")), "NOT_YOUR_TURN", "binding_gate_place_turn")
	runner.assert_eq(bool(gp.get("accepted", true)), false, "binding_gate_place_accepted")
	var gpass := reg.pass_turn(hc, gt)
	runner.assert_eq(str(gpass.get("error", "")), "NOT_YOUR_TURN", "binding_gate_pass_turn")
	runner.assert_eq(bool(gpass.get("accepted", true)), false, "binding_gate_pass_accepted")
	var gex := reg.exchange(hc, gt, 1)
	runner.assert_eq(str(gex.get("error", "")), "NOT_YOUR_TURN", "binding_gate_exchange_turn")
	var grec := reg.recall(hc, gt)
	runner.assert_eq(str(grec.get("error", "")), "NOT_YOUR_TURN", "binding_gate_recall_turn")
	var gsh := reg.shuffle_rack(hc, gt)
	runner.assert_eq(str(gsh.get("error", "")), "NOT_YOUR_TURN", "binding_gate_shuffle_turn")
	var gr := reg.get_rack(hc, gt)
	runner.assert_true(bool(gr.get("ok", false)), "binding_rack_ungated_ok")
	runner.assert_eq(int(gr.get("seat", -1)), 1, "binding_rack_ungated_seat")
	var hpass := reg.pass_turn(hc, ht)
	runner.assert_true(bool(hpass.get("ok", false)), "binding_host_pass_ok")
	runner.assert_eq(int(hpass.get("turn", -1)), 1, "binding_host_pass_turn_1")
	runner.assert_eq(bool(hpass.get("accepted", false)), true, "binding_host_pass_accepted")
	var hpass2 := reg.pass_turn(hc, ht)
	runner.assert_eq(str(hpass2.get("error", "")), "NOT_YOUR_TURN", "binding_gate_host_after_pass")

	# NOT_IN_LEXICON mapping with reason_word preserved; then a legal CAT.
	var parts2 := _open2(runner, lex)
	var reg2: RoomRegistry = parts2[0]
	var hc2: String = parts2[1]
	var ht2: String = parts2[2]
	var game2: LocalGame = reg2.debug_game(hc2)
	game2.debug_set_rack(0, ["Z", "Z", "Q", "J", "X", "E", "F"])
	var bad := reg2.place_tiles(hc2, ht2, [
		{"col": 5, "row": 7, "letter": "Z"},
		{"col": 6, "row": 7, "letter": "Z"},
		{"col": 7, "row": 7, "letter": "Q"},
		{"col": 8, "row": 7, "letter": "J"},
		{"col": 9, "row": 7, "letter": "X"},
	])
	runner.assert_eq(bool(bad.get("ok", true)), false, "binding_lexicon_not_ok")
	runner.assert_eq(str(bad.get("reason", "")), "NOT_IN_LEXICON", "binding_lexicon_mapped")
	runner.assert_eq(str(bad.get("error", "")), "NOT_IN_LEXICON", "binding_lexicon_error_mapped")
	runner.assert_eq(bool(bad.get("accepted", true)), false, "binding_lexicon_accepted")
	runner.assert_eq(int(bad.get("points", -1)), 0, "binding_lexicon_points_zero")
	runner.assert_eq(str(bad.get("reason_word", "")), "ZZQJX", "binding_lexicon_word_kept")
	var recalled := reg2.recall(hc2, ht2)
	runner.assert_true(bool(recalled.get("ok", false)), "binding_recall_clears_pending")
	game2.debug_set_rack(0, ["C", "A", "T", "D", "E", "F", "G"])
	var good := reg2.place_tiles(hc2, ht2, [
		{"square": "G8", "letter": "C"},
		{"square": "H8", "letter": "A"},
		{"square": "I8", "letter": "T"},
	])
	runner.assert_true(bool(good.get("ok", false)), "binding_cat_ok")
	runner.assert_eq(bool(good.get("accepted", false)), true, "binding_cat_accepted")
	runner.assert_eq(int(good.get("points", -1)), int(good.get("total", -2)), "binding_cat_points_total")
	runner.assert_true(int(good.get("total", 0)) > 0, "binding_cat_total_positive")
	runner.assert_eq(int(good.get("turn", -1)), 1, "binding_cat_advances_turn")
	runner.assert_true((good.get("rack", []) as Array).size() == 7, "binding_cat_reply_has_rack")
	runner.assert_eq(int(good.get("seat", -1)), 0, "binding_cat_reply_seat_mover")
	runner.assert_eq(int(good.get("you", -1)), 0, "binding_cat_reply_you_mover")

	# Per-seat rack privacy: distinct pinned racks, frames carry no foreign letters.
	game2.debug_set_rack(0, ["C", "A", "T", "D", "E", "F", "G"])
	game2.debug_set_rack(1, ["Z", "Z", "Z", "Z", "Z", "Z", "Z"])
	var gt2: String = parts2[3]
	var rack0: Array = reg2.get_rack(hc2, ht2).get("rack", [])
	var rack1: Array = reg2.get_rack(hc2, gt2).get("rack", [])
	runner.assert_true(rack0 != rack1, "binding_racks_differ")
	runner.assert_true(not ("Z" in rack0), "binding_rack0_no_foreign_z")
	runner.assert_true("C" in rack0, "binding_rack0_own_c")
	var framed := GameBinding.personalize({"m": "turn_update"}, 0, rack0)
	runner.assert_true(not ("Z" in (framed.get("rack", []) as Array)), "binding_frame_no_foreign_z")
	runner.assert_eq(int(framed.get("you", -1)), 0, "binding_frame_you")
	var chats := reg2.chat(hc2, ht2, "hello")
	runner.assert_eq(str(chats.get("text", "")), "hello", "binding_chat_echo")
	var kept := GameBinding.personalize(chats, 1, rack1)
	runner.assert_eq(str(kept.get("seat", -1)), str(chats.get("seat", "")), "binding_chat_seat_preserved")
	runner.assert_eq(int(kept.get("you", -1)), 1, "binding_chat_you_recipient")

	# Debug RPC gates: live rooms refuse, guests are refused, hosts may pin.
	var reg_nt := RoomRegistry.new(lex)
	var hnt := reg_nt.create_room("Host")
	var hntc := str(hnt.get("code", ""))
	var hntt := str(hnt.get("token", ""))
	reg_nt.join_room(hntc, "Guest")
	reg_nt.start_game(hntc, hntt)
	var refused := reg_nt.debug_set_rack(hntc, hntt, 0, ["A", "B", "C", "D", "E", "F", "G"])
	runner.assert_eq(str(refused.get("error", "")), "BAD_STATE", "binding_debug_live_bad_state")
	var reg_tm := RoomRegistry.new(lex)
	var htm := reg_tm.create_room("Host", {"test_mode": true})
	var htmc := str(htm.get("code", ""))
	var htmt := str(htm.get("token", ""))
	var gtmt := str(reg_tm.join_room(htmc, "Guest").get("token", ""))
	var live := reg_tm.debug_set_rack(htmc, gtmt, 1, ["A"])
	runner.assert_eq(str(live.get("error", "")), "NOT_HOST", "binding_debug_guest_not_host")
	reg_tm.start_game(htmc, htmt)
	var pinned := reg_tm.debug_set_rack(htmc, htmt, 1, ["Q", "W", "E", "R", "T", "Y", "U"])
	runner.assert_true(bool(pinned.get("ok", false)), "binding_debug_host_ok")
	runner.assert_true("Q" in (pinned.get("rack", []) as Array), "binding_debug_pins_rack")
	# Wire numbers arrive as floats (JSON has no ints); the dispatcher must
	# still resolve the seat instead of refusing with BAD_STATE.
	var wired: Array = reg_tm.handle_dict({
		"v": 1, "m": "debug_set_rack", "code": htmc, "token": htmt,
		"seat": 1.0, "tiles": ["Q", "W"],
	})
	runner.assert_true(bool((wired[0] as Dictionary).get("ok", false)), "binding_debug_float_seat_ok")
	var bagged := reg_tm.debug_set_bag(htmc, htmt, ["E", "E", "E"])
	runner.assert_true(bool(bagged.get("ok", false)), "binding_debug_bag_ok")

	# Timers: unstarted rooms never fire, expiry auto-passes with a flag.
	var reg_u := RoomRegistry.new(lex)
	var hu := reg_u.create_room("Host")
	var huc := str(hu.get("code", ""))
	reg_u.join_room(huc, "Guest")
	runner.assert_true(reg_u.debug_expire(huc), "binding_expire_unstarted_true")
	runner.assert_eq(reg_u.poll_timers(HUGE_NOW).size(), 0, "binding_unstarted_never_fires")
	var parts_a := _open2(runner, lex)
	var reg_a: RoomRegistry = parts_a[0]
	var hca: String = parts_a[1]
	runner.assert_true(reg_a.debug_expire(hca), "binding_expire_true")
	var due: Array = reg_a.poll_timers(HUGE_NOW)
	runner.assert_eq(due.size(), 1, "binding_auto_pass_one_frame")
	var frame: Dictionary = due[0]
	runner.assert_eq(bool(frame.get("auto_pass", false)), true, "binding_auto_pass_flag")
	runner.assert_eq(int(frame.get("turn", -1)), 1, "binding_auto_pass_advances_turn")
	runner.assert_eq(str(frame.get("code", "")), hca, "binding_auto_pass_code")
	runner.assert_eq(str(frame.get("m", "")), "turn_update", "binding_auto_pass_delta")

	# Deadline refreshes on success but not on expiry alone.
	var parts_b := _open2(runner, lex)
	var reg_b: RoomRegistry = parts_b[0]
	var hcb: String = parts_b[1]
	var htb: String = parts_b[2]
	reg_b.debug_expire(hcb)
	runner.assert_true(bool(reg_b.pass_turn(hcb, htb).get("ok", false)), "binding_refresh_pass_ok")
	runner.assert_eq(reg_b.poll_timers(1).size(), 0, "binding_refresh_silences_poll")
	var parts_c := _open2(runner, lex)
	var reg_c: RoomRegistry = parts_c[0]
	var hcc: String = parts_c[1]
	reg_c.debug_expire(hcc)
	runner.assert_eq(reg_c.poll_timers(1).size(), 1, "binding_no_refresh_still_fires")

	# Six consecutive scoreless turns (manual + auto mix) end six_scoreless.
	var parts_s := _open2(runner, lex)
	var reg_s: RoomRegistry = parts_s[0]
	var hcs: String = parts_s[1]
	var toks := [str(parts_s[2]), str(parts_s[3])]
	var game_s: LocalGame = reg_s.debug_game(hcs)
	for i: int in range(6):
		if game_s.is_over():
			break
		if i % 2 == 0:
			var tok: String = toks[game_s.current_player()]
			var res := reg_s.pass_turn(hcs, tok)
			runner.assert_true(bool(res.get("ok", false)), "binding_scoreless_manual_%d_ok" % i)
		else:
			reg_s.debug_expire(hcs)
			var auto: Array = reg_s.poll_timers(HUGE_NOW - i)
			runner.assert_eq(auto.size(), 1, "binding_scoreless_auto_%d_fires" % i)
			runner.assert_eq(
				bool((auto[0] as Dictionary).get("auto_pass", false)), true,
				"binding_scoreless_auto_%d_flag" % i
			)
	runner.assert_true(game_s.is_over(), "binding_scoreless_over")
	runner.assert_eq(game_s.ending(), "six_scoreless", "binding_scoreless_ending")
	reg_s.debug_expire(hcs)
	runner.assert_eq(reg_s.poll_timers(HUGE_NOW).size(), 0, "binding_over_never_fires")
	print("game_binding_complete=true")
