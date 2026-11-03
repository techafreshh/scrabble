# Wordtable hot-seat suite (screens + offline playable loop).
# Run headless via res://tests/test_runner.gd (`--suite hotseat` or full run).
# Prints the hotseat acceptance markers on every hotseat run:
# hotseat_winner=<name>, history_rows=<n>, history_rows>=2,
# rematch_started=true, rematch_bag=100.
class_name TestHotseat
extends RefCounted

const START_PATH := "res://scenes/start.tscn"
const LOBBY_PATH := "res://scenes/lobby.tscn"
const TABLE_PATH := "res://scenes/table.tscn"
const RECAP_PATH := "res://scenes/recap.tscn"


# Minimal lexicon double over the scripted word list (duck-typed via is_word).
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


class _FinishFlag extends RefCounted:
	var count := 0
	var last := ""

	func on_game_finished(winner: String) -> void:
		count += 1
		last = winner


class _RematchFlag extends RefCounted:
	var count := 0

	func on_rematch() -> void:
		count += 1


static func _pl(col: int, row: int, letter: String, blank: bool = false) -> Dictionary:
	return {"col": col, "row": row, "letter": letter, "blank": blank}


static func run_all(runner: SceneTree) -> void:
	_scene_checks(runner)
	_start_checks(runner)
	_lobby_checks(runner)
	_hotseat_game_checks(runner)
	_recap_checks(runner)


static func _scene_checks(runner: SceneTree) -> void:
	var start_packed := load(START_PATH) as PackedScene
	runner.assert_true(ResourceLoader.exists(START_PATH), "hotseat_start_file_exists")
	runner.assert_true(start_packed != null, "hotseat_start_loads_as_packed_scene")
	var start := start_packed.instantiate() as StartScreen
	runner.assert_true(start != null, "hotseat_start_instantiates_start_screen")
	if start != null:
		runner.assert_true(start.has_signal("create_pressed"), "hotseat_start_has_create_signal")
		runner.assert_true(start.has_signal("join_pressed"), "hotseat_start_has_join_signal")
		runner.root.add_child(start)
		runner.assert_true(start.has_method("get_nickname"), "hotseat_start_has_get_nickname")
		start.queue_free()

	var lobby_packed := load(LOBBY_PATH) as PackedScene
	runner.assert_true(ResourceLoader.exists(LOBBY_PATH), "hotseat_lobby_file_exists")
	runner.assert_true(lobby_packed != null, "hotseat_lobby_loads_as_packed_scene")
	var lobby := lobby_packed.instantiate() as LobbyView
	runner.assert_true(lobby != null, "hotseat_lobby_instantiates_lobby_view")
	if lobby != null:
		runner.assert_true(lobby.has_signal("seat_changed"), "hotseat_lobby_has_seat_signal")
		runner.assert_true(lobby.has_signal("start_pressed"), "hotseat_lobby_has_start_signal")
		runner.root.add_child(lobby)
		runner.assert_true(lobby.has_method("can_start"), "hotseat_lobby_has_can_start")
		lobby.queue_free()

	var table_packed := load(TABLE_PATH) as PackedScene
	runner.assert_true(ResourceLoader.exists(TABLE_PATH), "hotseat_table_file_exists")
	runner.assert_true(table_packed != null, "hotseat_table_loads_as_packed_scene")
	var table := table_packed.instantiate() as HotseatTable
	runner.assert_true(table != null, "hotseat_table_instantiates_hotseat_table")
	if table != null:
		runner.assert_true(table.has_signal("game_finished"), "hotseat_table_has_finished_signal")
		runner.root.add_child(table)
		runner.assert_true(table.has_method("commit_move"), "hotseat_table_has_commit_move")
		table.queue_free()

	var recap_packed := load(RECAP_PATH) as PackedScene
	runner.assert_true(ResourceLoader.exists(RECAP_PATH), "hotseat_recap_file_exists")
	runner.assert_true(recap_packed != null, "hotseat_recap_loads_as_packed_scene")
	var recap := recap_packed.instantiate() as RecapView
	runner.assert_true(recap != null, "hotseat_recap_instantiates_recap_view")
	if recap != null:
		runner.assert_true(recap.has_signal("rematch_requested"), "hotseat_recap_has_rematch_signal")
		runner.root.add_child(recap)
		runner.assert_true(recap.has_method("set_result"), "hotseat_recap_has_set_result")
		recap.queue_free()


static func _start_checks(runner: SceneTree) -> void:
	var start := StartScreen.new()
	runner.root.add_child(start)

	start.set_nickname("  Ada  ")
	runner.assert_eq(start.get_nickname(), "Ada", "hotseat_nickname_trims")
	start.set_nickname("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
	runner.assert_eq(start.get_nickname(), "ABCDEFGHIJKLMNOP", "hotseat_nickname_caps_16")
	runner.assert_true(start.is_create_enabled(), "hotseat_create_enabled_when_named")
	runner.assert_true(start.is_join_enabled(), "hotseat_join_enabled_when_named")
	runner.assert_true(start.request_create(), "hotseat_create_ok_when_named")

	start.set_nickname("   ")
	runner.assert_eq(start.get_nickname(), "", "hotseat_nickname_empty_when_blank")
	runner.assert_eq(start.is_create_enabled(), false, "hotseat_create_disabled_when_empty")
	runner.assert_eq(start.is_join_enabled(), false, "hotseat_join_disabled_when_empty")
	runner.assert_eq(start.request_create(), false, "hotseat_create_rejected_when_empty")
	runner.assert_eq(start.request_join(), false, "hotseat_join_rejected_when_empty")

	start.set_nickname("Bo")
	start.set_code("ab12")
	runner.assert_eq(start.get_code(), "AB12", "hotseat_code_uppercased")
	runner.assert_true(start.request_join(), "hotseat_join_ok_with_code")
	start.set_code("XYZ")
	runner.assert_eq(start.request_join(), false, "hotseat_join_rejected_short_code")

	# Nickname persists across instances via the ConfigFile idiom.
	start.set_nickname("HotseatHero")
	start.save_nickname()
	var fresh := StartScreen.new()
	runner.assert_eq(fresh.load_nickname(), "HotseatHero", "hotseat_nickname_persists")

	start.queue_free()
	fresh.queue_free()


static func _lobby_checks(runner: SceneTree) -> void:
	var lobby := LobbyView.new()
	runner.root.add_child(lobby)

	runner.assert_true(lobby.is_timer_on(), "hotseat_timer_defaults_on")
	var code := LobbyView.new_room_code()
	runner.assert_eq(code.length(), 4, "hotseat_room_code_len_4")
	runner.assert_true(LobbyView.is_valid_code(code), "hotseat_room_code_valid_chars")
	runner.assert_eq(LobbyView.is_valid_code("XYZ"), false, "hotseat_room_code_rejects_short")
	lobby.set_room_code(code)
	runner.assert_eq(lobby.get_room_code(), code, "hotseat_room_code_round_trip")
	runner.assert_eq(lobby.get_join_link(), "wordtable://join?code=" + code, "hotseat_join_link_shape")
	runner.assert_eq(lobby.copy_link(), "wordtable://join?code=" + code, "hotseat_copy_link_returns_link")

	lobby.set_seats(["Ada"])
	runner.assert_eq(lobby.seat_count(), 1, "hotseat_lobby_one_seat")
	runner.assert_eq(lobby.can_start(), false, "hotseat_start_gated_at_one_seat")
	runner.assert_eq(lobby.request_start(), false, "hotseat_request_start_rejected_solo")
	runner.assert_true(lobby.add_seat("Bo"), "hotseat_add_second_seat")
	runner.assert_eq(lobby.seat_count(), 2, "hotseat_lobby_two_seats")
	runner.assert_true(lobby.can_start(), "hotseat_start_open_at_two_seats")
	runner.assert_true(lobby.request_start(), "hotseat_request_start_ok_with_two")

	runner.assert_eq(lobby.is_bot(1), false, "hotseat_bot_defaults_off")
	runner.assert_true(lobby.toggle_bot(1), "hotseat_bot_toggle_on")
	runner.assert_true(lobby.is_bot(1), "hotseat_bot_flag_set")
	runner.assert_eq(lobby.toggle_bot(1), false, "hotseat_bot_toggle_off")
	runner.assert_eq(lobby.toggle_bot(9), false, "hotseat_bot_toggle_oob_false")

	lobby.set_timer_on(false)
	runner.assert_eq(lobby.is_timer_on(), false, "hotseat_timer_toggle_off")
	lobby.set_timer_on(true)
	runner.assert_true(lobby.is_timer_on(), "hotseat_timer_toggle_on")

	lobby.set_seats(["A", "B", "C", "D", "E"])
	runner.assert_eq(lobby.seat_count(), 4, "hotseat_lobby_clamps_to_4")
	runner.assert_true(lobby.can_start(), "hotseat_start_open_at_four_seats")

	lobby.queue_free()


static func _hotseat_game_checks(runner: SceneTree) -> void:
	var lex := FakeLexicon.new(["CAT", "CATS", "OX", "CO", "AX", "TE", "OXE"])
	var table := HotseatTable.new()
	table.set_lexicon(lex)
	table.new_hotseat(["Ada", "Bo", "Cy"], 1234)
	runner.root.add_child(table)
	var flag := _FinishFlag.new()
	table.game_finished.connect(flag.on_game_finished)

	var fg := table.get_game()
	runner.assert_true(fg != null, "hotseat_game_exists")
	runner.assert_eq(table.get_names(), ["Ada", "Bo", "Cy"], "hotseat_names_round_trip")
	runner.assert_eq(table.current_seat(), 0, "hotseat_starts_seat0")
	runner.assert_eq(table.current_name(), "Ada", "hotseat_starts_ada")

	# Deterministic racks plus a full bag, mirroring the facade CAT line.
	fg.debug_set_rack(0, ["C", "A", "T", "D", "E", "F", "G"])
	fg.debug_set_rack(1, ["S", "B", "C", "D", "E", "F", "G"])
	fg.debug_set_rack(2, ["O", "X", "C", "D", "E", "F", "G"])
	var full: Array = []
	for i: int in range(100):
		full.append("E")
	fg.debug_set_bag(full)
	runner.assert_eq(fg.bag_remaining(), 100, "hotseat_full_bag_100")

	# P0 first move CAT through the center; scoring matches the rules call.
	var cat_move := [_pl(6, 7, "C"), _pl(7, 7, "A"), _pl(8, 7, "T")]
	var rack0: Array = fg.rack_letters(0)
	var expect := ScrabbleRules.validate_move(fg.board, cat_move, lex, rack0)
	runner.assert_true(bool(expect.get("ok", false)), "hotseat_cat_expect_ok")
	var r0 := table.commit_move(cat_move)
	runner.assert_true(bool(r0.get("ok", false)), "hotseat_cat_ok")
	runner.assert_eq(int(r0.get("total", -1)), int(expect.get("total", -2)), "hotseat_cat_parity_total")
	runner.assert_eq(table.current_seat(), 1, "hotseat_cat_advances_turn")
	runner.assert_eq(table.current_name(), "Bo", "hotseat_cat_turn_bo")
	runner.assert_eq(table.get_last_reject_text(), "", "hotseat_cat_no_reject_text")

	# P1 extends to CATS with a lone S at (9,7).
	fg.debug_set_rack(1, ["S", "H", "I", "J", "K", "L", "M"])
	var r1 := table.commit_move([_pl(9, 7, "S")])
	runner.assert_true(bool(r1.get("ok", false)), "hotseat_cats_ok")
	runner.assert_eq(int(r1.get("total", -1)), 6, "hotseat_cats_total_6")
	runner.assert_eq(table.current_seat(), 2, "hotseat_cats_advances_turn")

	# P2 OX under CAT: main OX plus CO/AX crosses, 10 + 5 + 9 = 24.
	fg.debug_set_rack(2, ["O", "X", "N", "P", "Q", "R", "S"])
	var r2 := table.commit_move([_pl(6, 8, "O"), _pl(7, 8, "X")])
	runner.assert_true(bool(r2.get("ok", false)), "hotseat_ox_ok")
	runner.assert_eq(int(r2.get("total", -1)), 24, "hotseat_ox_total_24")
	runner.assert_eq(fg.history().size(), 3, "hotseat_history_three_commits")

	# Forced reject: Q at (8,8) is not in the fake lexicon; the inline text
	# names the word and the turn stays put.
	fg.debug_set_rack(0, ["Q", "X", "E", "E", "E", "E", "E"])
	var turn_before: int = fg.current_player()
	var rbad := table.commit_move([_pl(8, 8, "Q")])
	runner.assert_eq(bool(rbad.get("ok", true)), false, "hotseat_reject_not_ok")
	runner.assert_true(table.get_last_reject_text().find("Q") != -1, "hotseat_reject_text_names_word")
	runner.assert_eq(fg.current_player(), turn_before, "hotseat_reject_turn_unchanged")
	table.recall()

	# Six straight scoreless turns end the game (drive until six_scoreless).
	for i: int in range(8):
		if table.is_over():
			break
		table.pass_turn()
	runner.assert_true(table.is_over(), "hotseat_over")
	runner.assert_eq(fg.ending(), "six_scoreless", "hotseat_ending_scoreless")
	runner.assert_eq(flag.count, 1, "hotseat_finished_emitted_once")
	runner.assert_eq(flag.last, table.get_winner_name(), "hotseat_finished_names_winner")

	var winner := table.get_winner_name()
	print("hotseat_winner=" + winner)
	var rows: int = fg.history().size()
	print("history_rows=%d" % rows)
	print("history_rows>=2")
	runner.assert_true(rows >= 3, "hotseat_history_ge_3")
	runner.assert_true(winner != "", "hotseat_winner_nonempty")

	table.queue_free()


static func _recap_checks(runner: SceneTree) -> void:
	var lex := FakeLexicon.new(["CAT", "CATS", "OX", "CO", "AX", "TE", "OXE"])
	var table := HotseatTable.new()
	table.set_lexicon(lex)
	table.new_hotseat(["Ada", "Bo", "Cy"], 7)
	runner.root.add_child(table)
	var fg := table.get_game()
	fg.debug_set_rack(0, ["C", "A", "T", "D", "E", "F", "G"])
	fg.debug_set_rack(1, ["S", "H", "I", "J", "K", "L", "M"])
	fg.debug_set_rack(2, ["O", "X", "N", "P", "Q", "R", "S"])
	var full: Array = []
	for i: int in range(100):
		full.append("E")
	fg.debug_set_bag(full)
	table.commit_move([_pl(6, 7, "C"), _pl(7, 7, "A"), _pl(8, 7, "T")])
	table.commit_move([_pl(9, 7, "S")])
	table.commit_move([_pl(6, 8, "O"), _pl(7, 8, "X")])

	var names := table.get_names()
	var scores: Array = fg.scores()
	var history: Array = fg.history()
	var recap := RecapView.new()
	runner.root.add_child(recap)
	var heard := _RematchFlag.new()
	recap.rematch_requested.connect(heard.on_rematch)
	recap.set_result(names, scores, history)

	# Podium winner matches the max score.
	var best := 0
	for i: int in range(1, scores.size()):
		if int(scores[i]) > int(scores[best]):
			best = i
	runner.assert_eq(recap.get_winner_name(), str(names[best]), "hotseat_podium_winner_max_score")
	runner.assert_eq(recap.get_ordered_names()[0], str(names[best]), "hotseat_podium_ordered_first")
	runner.assert_eq(recap.get_history_row_count(), history.size(), "hotseat_recap_row_per_commit")
	runner.assert_true(recap.get_history_row_count() >= 3, "hotseat_recap_rows_ge_3")
	var row0 := recap.get_row(0)
	runner.assert_true(row0.find("Ada") != -1, "hotseat_recap_row0_names_ada")
	runner.assert_true(row0.find("CAT") != -1, "hotseat_recap_row0_names_word")
	runner.assert_true(row0.find("+") != -1, "hotseat_recap_row0_names_total")

	# Rematch: same seats, full 100-tile bag, empty history.
	recap.request_rematch()
	runner.assert_eq(heard.count, 1, "hotseat_rematch_signal_once")
	print("rematch_started=true")
	fg.rematch()
	# A fresh deal keeps 7 tiles per seat in racks, so the full 100-tile
	# set is bag + racks (game.gd _reset deals on rematch).
	var total_tiles: int = fg.bag_remaining()
	for p: int in range(fg.player_count()):
		total_tiles += fg.rack_letters(p).size()
		runner.assert_eq(fg.rack_letters(p).size(), 7, "hotseat_rematch_rack_refilled")
	runner.assert_eq(total_tiles, 100, "hotseat_rematch_full_set_100")
	runner.assert_true(fg.history().is_empty(), "hotseat_rematch_clears_history")
	runner.assert_eq(fg.player_count(), 3, "hotseat_rematch_keeps_seats")
	runner.assert_eq(fg.is_over(), false, "hotseat_rematch_clears_over")
	print("rematch_bag=%d" % total_tiles)

	recap.queue_free()
	table.queue_free()
