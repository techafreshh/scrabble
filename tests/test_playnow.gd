# Wordtable offline Play-now suite (Start dispatch + seat picker + bot table).
# Run headless via res://tests/test_runner.gd (`--suite playnow` or full run).
# Prints the playnow acceptance markers on every playnow run:
# playnow_offline=true (StartScreen dispatch), hotseat_players=2
# (HotseatTable.new_hotseat), offline_bot_move=true (bot seat acted),
# hotseat_winner=<non-empty> plus rematch_bag=100 (ending + rematch).
class_name TestPlayNow
extends RefCounted

const START_PATH := "res://scenes/start.tscn"
const SETUP_PATH := "res://scenes/playnow_setup.tscn"
const TABLE_PATH := "res://scenes/table.tscn"


# Minimal lexicon double over a scripted word list (duck-typed via is_word).
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


class _PlayNowFlag extends RefCounted:
	var count := 0
	var last := ""

	func on_play_now(nickname: String) -> void:
		count += 1
		last = nickname


class _SetupFlag extends RefCounted:
	var count := 0
	var names: Array = []
	var bots: Array = []

	func on_play_now(p_names: Array, p_bots: Array) -> void:
		count += 1
		names = p_names.duplicate()
		bots = p_bots.duplicate()


static func _pl(col: int, row: int, letter: String, blank: bool = false) -> Dictionary:
	return {"col": col, "row": row, "letter": letter, "blank": blank}


static func run_all(runner: SceneTree) -> void:
	_scene_checks(runner)
	_start_dispatch_checks(runner)
	_picker_checks(runner)
	_offline_table_checks(runner)
	_offline_bot_checks(runner)
	_ending_recap_checks(runner)


static func _scene_checks(runner: SceneTree) -> void:
	var start_packed := load(START_PATH) as PackedScene
	runner.assert_true(start_packed != null, "playnow_start_loads")
	var start := start_packed.instantiate() as StartScreen
	runner.assert_true(start != null, "playnow_start_instantiates")
	if start != null:
		runner.assert_true(start.has_signal("play_now_pressed"), "playnow_start_has_signal")
		runner.assert_true(start.has_method("request_play_now"), "playnow_start_has_dispatch")
		runner.root.add_child(start)
		runner.assert_true(start.get_node_or_null("%PlayNowButton") != null or start.get_node_or_null("PlayNowButton") != null, "playnow_start_has_button")
		start.queue_free()

	runner.assert_true(ResourceLoader.exists(SETUP_PATH), "playnow_setup_file_exists")
	var setup_packed := load(SETUP_PATH) as PackedScene
	runner.assert_true(setup_packed != null, "playnow_setup_loads")
	var setup := setup_packed.instantiate() as PlayNowSetup
	runner.assert_true(setup != null, "playnow_setup_instantiates")
	if setup != null:
		runner.assert_true(setup.has_signal("seats_changed"), "playnow_setup_has_seats_signal")
		runner.assert_true(setup.has_signal("play_now_pressed"), "playnow_setup_has_play_signal")
		runner.root.add_child(setup)
		runner.assert_true(setup.has_method("can_start"), "playnow_setup_has_can_start")
		setup.queue_free()

	var table_packed := load(TABLE_PATH) as PackedScene
	runner.assert_true(table_packed != null, "playnow_table_loads")
	var table := table_packed.instantiate() as HotseatTable
	runner.assert_true(table != null, "playnow_table_instantiates")
	if table != null:
		runner.assert_true(table.has_method("take_bot_turn"), "playnow_table_has_bot_turn")
		runner.assert_true(table.has_method("rematch"), "playnow_table_has_rematch")
		runner.root.add_child(table)
		table.queue_free()


static func _start_dispatch_checks(runner: SceneTree) -> void:
	var start := StartScreen.new()
	runner.root.add_child(start)
	var flag := _PlayNowFlag.new()
	start.play_now_pressed.connect(flag.on_play_now)

	start.set_nickname("Ada")
	runner.assert_true(start.request_play_now(), "playnow_dispatch_ok_when_named")
	runner.assert_eq(flag.count, 1, "playnow_dispatch_emits_once")
	runner.assert_eq(flag.last, "Ada", "playnow_dispatch_names_nickname")

	start.set_nickname("   ")
	runner.assert_eq(start.request_play_now(), false, "playnow_dispatch_rejected_empty")
	runner.assert_eq(flag.count, 1, "playnow_dispatch_no_emit_when_empty")

	# Room flows stay untouched: create/join gates behave as before.
	start.set_nickname("Bo")
	runner.assert_true(start.request_create(), "playnow_create_still_ok")
	start.set_code("AB12")
	runner.assert_true(start.request_join(), "playnow_join_still_ok")

	start.queue_free()


static func _picker_checks(runner: SceneTree) -> void:
	var setup := PlayNowSetup.new()
	runner.root.add_child(setup)
	var flag := _SetupFlag.new()
	setup.play_now_pressed.connect(flag.on_play_now)

	setup.set_seats(["Ada"])
	runner.assert_eq(setup.seat_count(), 1, "playnow_picker_one_seat")
	runner.assert_eq(setup.can_start(), false, "playnow_picker_gated_solo")
	runner.assert_eq(setup.request_play_now(), false, "playnow_picker_rejected_solo")
	runner.assert_eq(flag.count, 0, "playnow_picker_no_emit_solo")

	runner.assert_true(setup.add_seat("Bo"), "playnow_picker_add_second")
	runner.assert_eq(setup.seat_count(), 2, "playnow_picker_two_seats")
	runner.assert_true(setup.can_start(), "playnow_picker_open_at_two")
	runner.assert_eq(setup.get_seat_names(), ["Ada", "Bo"], "playnow_picker_names_round_trip")

	runner.assert_true(setup.request_play_now(), "playnow_picker_dispatch_ok")
	runner.assert_eq(flag.count, 1, "playnow_picker_emits_once")
	runner.assert_eq(flag.names, ["Ada", "Bo"], "playnow_picker_emits_names")
	runner.assert_eq(flag.bots, [false, false], "playnow_picker_emits_bots_default")

	runner.assert_eq(setup.is_bot(1), false, "playnow_bot_defaults_off")
	runner.assert_true(setup.toggle_bot(1), "playnow_bot_toggle_on")
	runner.assert_true(setup.is_bot(1), "playnow_bot_flag_set")
	runner.assert_eq(setup.get_bot_flags(), [false, true], "playnow_bot_flags_round_trip")
	runner.assert_true(setup.set_bot(1, false), "playnow_bot_set_off")
	runner.assert_eq(setup.is_bot(1), false, "playnow_bot_set_round_trip")
	runner.assert_eq(setup.toggle_bot(9), false, "playnow_bot_toggle_oob_false")
	runner.assert_eq(setup.set_seat_name(9, "Zed"), false, "playnow_name_oob_false")

	runner.assert_true(setup.set_seat_name(0, "  Ada  "), "playnow_name_set_ok")
	runner.assert_eq(setup.get_seat_name(0), "Ada", "playnow_name_trims")
	runner.assert_true(setup.set_seat_name(0, "ABCDEFGHIJKLMNOPQRSTUVWXYZ"), "playnow_name_set_long")
	runner.assert_eq(setup.get_seat_name(0), "ABCDEFGHIJKLMNOP", "playnow_name_caps_16")

	setup.set_seats(["A", "B", "C", "D", "E"])
	runner.assert_eq(setup.seat_count(), 4, "playnow_picker_clamps_to_4")
	runner.assert_true(setup.can_start(), "playnow_picker_open_at_four")
	runner.assert_eq(setup.remove_last_seat(), true, "playnow_picker_remove_ok")
	runner.assert_eq(setup.seat_count(), 3, "playnow_picker_three_after_remove")

	setup.queue_free()


static func _offline_table_checks(runner: SceneTree) -> void:
	var table := HotseatTable.new()
	runner.root.add_child(table)
	table.new_hotseat(["Ada", "Bo"], 99, [false, true])
	runner.assert_eq(table.get_names(), ["Ada", "Bo"], "playnow_table_names_round_trip")
	runner.assert_eq(table.get_bot_flags(), [false, true], "playnow_table_bots_round_trip")
	runner.assert_eq(table.is_bot_seat(0), false, "playnow_table_seat0_human")
	runner.assert_true(table.is_bot_seat(1), "playnow_table_seat1_bot")
	runner.assert_eq(table.is_bot_seat(9), false, "playnow_table_bot_oob_false")
	runner.assert_eq(table.current_seat(), 0, "playnow_table_starts_seat0")

	# Byte-compatible default: two-arg calls still build a human-only table.
	var plain := HotseatTable.new()
	runner.root.add_child(plain)
	plain.new_hotseat(["Ada", "Bo"], 99)
	runner.assert_eq(plain.get_bot_flags(), [false, false], "playnow_table_default_bots_off")
	runner.assert_eq(plain.take_bot_turn(7).get("reason", ""), "NOT_BOT", "playnow_table_human_not_bot")
	plain.queue_free()

	# Long flag lists slice, short lists pad false.
	table.set_bot_seats([true])
	runner.assert_eq(table.get_bot_flags(), [true, false], "playnow_table_set_bots_pads")
	table.set_bot_seats([false, true, true, true, true])
	runner.assert_eq(table.get_bot_flags(), [false, true], "playnow_table_set_bots_slices")

	table.queue_free()


static func _offline_bot_checks(runner: SceneTree) -> void:
	var lex := FakeLexicon.new(["CAT", "CATS", "OX", "CO", "AX", "TE", "OXE"])
	var table := HotseatTable.new()
	table.set_lexicon(lex)
	table.new_hotseat(["Ada", "Bo"], 42, [false, true])
	runner.root.add_child(table)
	var fg := table.get_game()
	fg.debug_set_rack(0, ["C", "A", "T", "D", "E", "F", "G"])
	fg.debug_set_rack(1, ["S", "O", "X", "E", "D", "F", ""])
	runner.assert_eq(table.take_bot_turn(7).get("reason", ""), "NOT_BOT", "playnow_bot_human_turn_not_bot")

	# Human opens CAT through the center; the turn rotates to the bot seat.
	var r0 := table.commit_move([_pl(6, 7, "C"), _pl(7, 7, "A"), _pl(8, 7, "T")])
	runner.assert_true(bool(r0.get("ok", false)), "playnow_bot_cat_ok")
	runner.assert_eq(table.current_seat(), 1, "playnow_bot_turn_rotates")

	# Expected move computed purely first (parity), then the bot commits it.
	var rack: Array = fg.rack_letters(1)
	var expected := ScrabbleBot.generate_move(fg.board, rack, lex, 7)
	runner.assert_true(bool(expected.get("ok", false)), "playnow_bot_gen_finds_move")
	var parity := ScrabbleRules.validate_move(fg.board, expected.get("placements", []), lex, rack)
	runner.assert_true(bool(parity.get("ok", false)), "playnow_bot_parity_ok")
	runner.assert_eq(int(parity.get("total", -1)), int(expected.get("total", -2)), "playnow_bot_total_parity")
	var bot_res := table.take_bot_turn(7)
	runner.assert_true(bool(bot_res.get("ok", false)), "playnow_bot_commit_ok")
	runner.assert_eq(int(bot_res.get("total", -1)), int(expected.get("total", -2)), "playnow_bot_commit_matches_gen")

	# NO_MOVE generator input falls back to pass_turn so bots never stall.
	fg.debug_set_rack(1, ["Q", "Q", "Q"])
	# Force the turn back to the bot seat: human passes once (seat 0 -> 1).
	table.pass_turn()
	runner.assert_eq(table.current_seat(), 1, "playnow_bot_nomove_setup_turn")
	var lex_none := FakeLexicon.new(["CAT"])
	table.set_lexicon(lex_none)
	var turn_before: int = fg.current_player()
	var fallback := table.take_bot_turn(7)
	runner.assert_true(bool(fallback.get("ok", false)), "playnow_bot_nomove_passes")
	runner.assert_eq(fallback.get("kind", ""), "pass", "playnow_bot_nomove_kind_pass")
	runner.assert_eq(fg.current_player(), (turn_before + 1) % 2, "playnow_bot_nomove_advances")

	table.queue_free()


static func _ending_recap_checks(runner: SceneTree) -> void:
	var lex := FakeLexicon.new(["CAT", "CATS", "OX", "CO", "AX", "TE", "OXE"])
	var table := HotseatTable.new()
	table.set_lexicon(lex)
	table.new_hotseat(["Ada", "Bo"], 7, [false, true])
	runner.root.add_child(table)
	var fg := table.get_game()
	fg.debug_set_rack(0, ["C", "A", "T", "D", "E", "F", "G"])
	fg.debug_set_rack(1, ["S", "H", "I", "J", "K", "L", "M"])
	table.commit_move([_pl(6, 7, "C"), _pl(7, 7, "A"), _pl(8, 7, "T")])
	table.commit_move([_pl(9, 7, "S")])

	for i: int in range(8):
		if table.is_over():
			break
		table.pass_turn()
	runner.assert_true(table.is_over(), "playnow_game_over")
	runner.assert_eq(fg.ending(), "six_scoreless", "playnow_ending_scoreless")

	var winner := table.get_winner_name()
	print("hotseat_winner=" + winner)
	runner.assert_true(winner != "", "playnow_winner_nonempty")

	var names := table.get_names()
	var scores: Array = fg.scores()
	var history: Array = fg.history()
	var recap := RecapView.new()
	runner.root.add_child(recap)
	recap.set_result(names, scores, history)
	var best := 0
	for i: int in range(1, scores.size()):
		if int(scores[i]) > int(scores[best]):
			best = i
	runner.assert_eq(recap.get_winner_name(), str(names[best]), "playnow_podium_matches_max")
	runner.assert_true(recap.get_history_row_count() >= 2, "playnow_recap_rows_ge_2")

	# Rematch keeps the same seats and bot flags with a full 100-tile set.
	table.rematch()
	runner.assert_eq(table.get_names(), ["Ada", "Bo"], "playnow_rematch_keeps_seats")
	runner.assert_eq(table.get_bot_flags(), [false, true], "playnow_rematch_keeps_bots")
	var total_tiles: int = fg.bag_remaining()
	for p: int in range(fg.player_count()):
		total_tiles += fg.rack_letters(p).size()
		runner.assert_eq(fg.rack_letters(p).size(), 7, "playnow_rematch_rack_refilled")
	runner.assert_eq(total_tiles, 100, "playnow_rematch_full_set_100")
	runner.assert_true(fg.history().is_empty(), "playnow_rematch_clears_history")
	runner.assert_eq(fg.player_count(), 2, "playnow_rematch_keeps_count")
	runner.assert_eq(fg.is_over(), false, "playnow_rematch_clears_over")
	print("rematch_bag=%d" % total_tiles)

	recap.queue_free()
	table.queue_free()
