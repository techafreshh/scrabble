# Wordtable rules gold-corpus suite (pure logic, no scene deps).
# Run headless via res://tests/test_runner.gd (`--suite rules` or full run).
# Prints the gold_pass / QUARTZ / bingo_bonus / blank_points markers.
class_name TestRules
extends RefCounted


# Minimal board double: occupancy only, official premiums are irrelevant here
# because ScrabbleRules embeds the layout itself (duck-typed via tile_at).
class FakeBoard extends RefCounted:
	var _cells: Dictionary = {}

	func set_tile(col: int, row: int, letter: String) -> void:
		_cells[Vector2i(col, row)] = letter.strip_edges().to_upper()

	func tile_at(col: int, row: int) -> String:
		return str(_cells.get(Vector2i(col, row), ""))


# Minimal lexicon double over the corpus word list (duck-typed via is_word).
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


static func run_all(runner: SceneTree) -> void:
	var lex := FakeLexicon.new([
		"QUARTZ", "AZ", "OT", "AX", "CAT", "CATS", "RETINAS",
		"BED", "BEL", "ZESTERS", "ZO", "OX", "CO", "TE", "QI",
	])
	var valid_passed := 0
	var quartz_total := 0
	var bingo_val := 0
	var blank_pts := 0

	# Spot-check the pure helpers the scorer is built on.
	runner.assert_eq(ScrabbleRules.premium_at(7, 7), "STAR_DW", "rules_center_is_star_dw")
	runner.assert_eq(ScrabbleRules.premium_at(0, 0), "TW", "rules_a1_is_tw")
	runner.assert_eq(ScrabbleRules.premium_at(1, 1), "DW", "rules_b2_is_dw")
	runner.assert_eq(ScrabbleRules.premium_at(5, 1), "TL", "rules_f2_is_tl")
	runner.assert_eq(ScrabbleRules.premium_at(3, 0), "DL", "rules_d1_is_dl")
	runner.assert_eq(ScrabbleRules.premium_at(7, 8), "--", "rules_plain_square")
	runner.assert_eq(ScrabbleRules.letter_points("Q", false), 10, "rules_q_scores_10")
	runner.assert_eq(ScrabbleRules.letter_points("A", false), 1, "rules_a_scores_1")
	runner.assert_eq(ScrabbleRules.letter_points("C", true), 0, "rules_blank_scores_0")
	runner.assert_eq(ScrabbleRules.letter_points("Z", true), 0, "rules_blank_z_scores_0")
	runner.assert_eq(ScrabbleRules.board_is_first_move(FakeBoard.new()), true, "rules_empty_is_first")
	var real_board := ScrabbleBoard.new()
	runner.assert_eq(ScrabbleRules.board_is_first_move(real_board), true, "rules_real_board_empty_is_first")
	real_board.place_tile(7, 7, "A")
	runner.assert_eq(ScrabbleRules.board_is_first_move(real_board), false, "rules_real_board_used_not_first")

	# 1. QUARTZ multi-word fixture: main 25 + cross AZ 11 + cross OT 2 = 38.
	var quartz_board := _board([[6, 6, "A"], [5, 6, "O"]])
	var quartz_move := [
		_pl(1, 7, "Q"), _pl(2, 7, "U"), _pl(3, 7, "A"),
		_pl(4, 7, "R"), _pl(5, 7, "T"), _pl(6, 7, "Z"),
	]
	var quartz_rack := ["Q", "U", "A", "R", "T", "Z"]
	var r_quartz := ScrabbleRules.validate_move(quartz_board, quartz_move, lex, quartz_rack)
	runner.assert_eq(r_quartz.get("ok"), true, "rules_quartz_ok")
	runner.assert_eq(r_quartz.get("main_points"), 25, "rules_quartz_main_25")
	runner.assert_eq(r_quartz.get("cross_points"), 13, "rules_quartz_cross_13")
	runner.assert_eq(r_quartz.get("bingo"), 0, "rules_quartz_no_bingo")
	runner.assert_eq(r_quartz.get("total"), 38, "rules_quartz_total_38")
	var quartz_words: Array = r_quartz.get("words", [])
	runner.assert_eq(quartz_words.size(), 3, "rules_quartz_three_words")
	var quartz_main: Dictionary = quartz_words[0]
	runner.assert_eq(str(quartz_main.get("word", "")), "QUARTZ", "rules_quartz_main_word")
	runner.assert_eq(int(quartz_main.get("points", -1)), 25, "rules_quartz_main_points")
	quartz_total = int(r_quartz.get("total", 0))
	if quartz_total == 38:
		valid_passed += 1
	var r_quartz_score := ScrabbleRules.score_move(quartz_board, quartz_move, lex, quartz_rack)
	runner.assert_eq(r_quartz_score.get("total"), 38, "rules_quartz_score_move_parity")
	var r_quartz_place := ScrabbleRules.validate_placement(
		quartz_board, quartz_rack, quartz_move, {}, lex
	)
	runner.assert_eq(r_quartz_place.get("total"), 38, "rules_quartz_placement_parity")

	# 2. AX triple-word entry: single new A(0,0) on TW extends X: (1+8)x3 = 27.
	var r_ax := ScrabbleRules.validate_move(
		_board([[0, 1, "X"]]), [_pl(0, 0, "A")], lex, ["A"]
	)
	runner.assert_eq(r_ax.get("ok"), true, "rules_ax_ok")
	runner.assert_eq(r_ax.get("main_points"), 27, "rules_ax_main_27")
	runner.assert_eq(r_ax.get("total"), 27, "rules_ax_total_27")
	if int(r_ax.get("total", 0)) == 27:
		valid_passed += 1

	# 3. RETINAS bingo entry: 7-tile first move E8-K8 over STAR:
	# letters 7 x2 = 14 + 50 = 64.
	var retinas_move := [
		_pl(4, 7, "R"), _pl(5, 7, "E"), _pl(6, 7, "T"), _pl(7, 7, "I"),
		_pl(8, 7, "N"), _pl(9, 7, "A"), _pl(10, 7, "S"),
	]
	var r_retinas := ScrabbleRules.validate_move(
		_board([]), retinas_move, lex, ["R", "E", "T", "I", "N", "A", "S"]
	)
	runner.assert_eq(r_retinas.get("ok"), true, "rules_retinas_ok")
	runner.assert_eq(r_retinas.get("main_points"), 14, "rules_retinas_main_14")
	runner.assert_eq(r_retinas.get("bingo"), 50, "rules_retinas_bingo_50")
	runner.assert_eq(r_retinas.get("total"), 64, "rules_retinas_total_64")
	bingo_val = int(r_retinas.get("bingo", 0))
	if int(r_retinas.get("total", 0)) == 64:
		valid_passed += 1

	# 4. CAT blank entry: first move with blank C at G8: (0+1+1) x2 = 4.
	var r_cat := ScrabbleRules.validate_move(
		_board([]),
		[_pl(6, 7, "C", true), _pl(7, 7, "A"), _pl(8, 7, "T")],
		lex,
		["", "A", "T"]
	)
	runner.assert_eq(r_cat.get("ok"), true, "rules_cat_ok")
	runner.assert_eq(r_cat.get("total"), 4, "rules_cat_total_4")
	blank_pts = ScrabbleRules.letter_points("C", true)
	runner.assert_eq(blank_pts, 0, "rules_blank_tile_points_0")
	if int(r_cat.get("total", 0)) == 4:
		valid_passed += 1

	# 5. BED double-letter entry: B/D land on DL flanking E: 6+1+4 = 11.
	var hello := [[7, 7, "H"], [7, 8, "E"], [7, 9, "L"], [7, 10, "L"], [7, 11, "O"]]
	var r_bed := ScrabbleRules.validate_move(
		_board(hello), [_pl(6, 8, "B"), _pl(8, 8, "D")], lex, ["B", "D"]
	)
	runner.assert_eq(r_bed.get("ok"), true, "rules_bed_ok")
	runner.assert_eq(r_bed.get("total"), 11, "rules_bed_total_11")
	if int(r_bed.get("total", 0)) == 11:
		valid_passed += 1

	# 6. BEL triple-letter entry: B on TL: 9+1+1 = 11.
	var r_bel := ScrabbleRules.validate_move(
		_board(hello), [_pl(5, 9, "B"), _pl(6, 9, "E")], lex, ["B", "E"]
	)
	runner.assert_eq(r_bel.get("ok"), true, "rules_bel_ok")
	runner.assert_eq(r_bel.get("total"), 11, "rules_bel_total_11")
	if int(r_bel.get("total", 0)) == 11:
		valid_passed += 1

	# 7. ZESTERS bingo-on-TW entry: main (10+1+1+2+1+1+1)x3=51 (T lands
	# on the D1 DL), cross ZO (10+1)x3=33, bingo 50: total 134. The TW
	# triples both words the new tile completes.
	var zest_move := [
		_pl(0, 0, "Z"), _pl(1, 0, "E"), _pl(2, 0, "S"), _pl(3, 0, "T"),
		_pl(4, 0, "E"), _pl(5, 0, "R"), _pl(6, 0, "S"),
	]
	var r_zest := ScrabbleRules.validate_move(
		_board([[0, 1, "O"]]), zest_move, lex,
		["Z", "E", "S", "T", "E", "R", "S"]
	)
	runner.assert_eq(r_zest.get("ok"), true, "rules_zest_ok")
	runner.assert_eq(r_zest.get("main_points"), 51, "rules_zest_main_51")
	runner.assert_eq(r_zest.get("cross_points"), 33, "rules_zest_cross_33")
	runner.assert_eq(r_zest.get("bingo"), 50, "rules_zest_bingo_50")
	runner.assert_eq(r_zest.get("total"), 134, "rules_zest_total_134")
	if int(r_zest.get("total", 0)) == 134:
		valid_passed += 1

	# 8. Overlap-extension entry: replaying the shared A costs no rack tile;
	# CATS scores face 3+1+1+1 = 6.
	var cat_board := [[6, 7, "C"], [7, 7, "A"], [8, 7, "T"]]
	var r_cats := ScrabbleRules.validate_move(
		_board(cat_board), [_pl(7, 7, "A"), _pl(9, 7, "S")], lex, ["S"]
	)
	runner.assert_eq(r_cats.get("ok"), true, "rules_cats_ok")
	runner.assert_eq(r_cats.get("total"), 6, "rules_cats_total_6")
	if int(r_cats.get("total", 0)) == 6:
		valid_passed += 1

	# 9. Parallel-adjacency entry: OX under CAT links CO + AX crosses:
	# main 10 + crosses 5 + 9 = 24.
	var r_ox := ScrabbleRules.validate_move(
		_board(cat_board), [_pl(6, 8, "O"), _pl(7, 8, "X")], lex, ["O", "X"]
	)
	runner.assert_eq(r_ox.get("ok"), true, "rules_ox_ok")
	runner.assert_eq(r_ox.get("main_points"), 10, "rules_ox_main_10")
	runner.assert_eq(r_ox.get("cross_points"), 14, "rules_ox_cross_14")
	runner.assert_eq(r_ox.get("total"), 24, "rules_ox_total_24")
	if int(r_ox.get("total", 0)) == 24:
		valid_passed += 1

	# 10. Single-tile cross entry: E under T forms TE (1 + 1x2 DL) = 3.
	var r_te := ScrabbleRules.validate_move(
		_board(cat_board), [_pl(8, 8, "E")], lex, ["E"]
	)
	runner.assert_eq(r_te.get("ok"), true, "rules_te_ok")
	runner.assert_eq(r_te.get("total"), 3, "rules_te_total_3")
	if int(r_te.get("total", 0)) == 3:
		valid_passed += 1

	runner.assert_eq(valid_passed, 10, "rules_gold_corpus_complete")

	# Invalid gold entries: one per reason code (plus duplicate-square and
	# blank-without-blank variants), each asserting ok == false exactly.
	_invalid(runner, lex, [], [], "EMPTY_MOVE", "", "rules_reject_empty_move")
	_invalid(runner, lex, [], [_pl(15, 7, "A")], "OUT_OF_BOUNDS", "", "rules_reject_oob")
	_invalid(runner, lex, [], [_pl(7, 7, "A"), _pl(8, 8, "B")],
		"NOT_IN_LINE", "", "rules_reject_not_in_line")
	_invalid(runner, lex, [], [_pl(5, 7, "A"), _pl(7, 7, "B")], "GAP_IN_RUN", "", "rules_reject_gap")
	_invalid(runner, lex, [[7, 7, "A"]], [_pl(7, 7, "B")],
		"TILE_CONFLICT", "", "rules_reject_conflict")
	_invalid(runner, lex, [], [_pl(5, 7, "A"), _pl(5, 7, "B")],
		"TILE_CONFLICT", "", "rules_reject_dup_square")
	_invalid(runner, lex, [], [_pl(0, 0, "A"), _pl(1, 0, "B")],
		"FIRST_MOVE_OFF_CENTER", "", "rules_reject_off_center")
	_invalid(runner, lex, [], [_pl(7, 7, "A")],
		"FIRST_MOVE_TOO_SHORT", "", "rules_reject_too_short")
	_invalid(runner, lex, [[7, 7, "A"]], [_pl(0, 0, "A"), _pl(0, 1, "X")],
		"NOT_CONNECTED", "", "rules_reject_not_connected")
	_invalid_rack(runner, lex, "RACK_SHORTAGE", "rules_reject_rack_shortage")
	_invalid(runner, lex, [], [_pl(7, 7, "Q"), _pl(8, 7, "X")],
		"NOT_IN_DICTIONARY", "QX", "rules_reject_qx")
	_invalid(runner, lex, cat_board, [_pl(9, 7, "Z")],
		"NOT_IN_DICTIONARY", "CATZ", "rules_reject_catz")

	print("gold_pass=%d" % valid_passed)
	print("QUARTZ=%d" % quartz_total)
	print("bingo_bonus=%d" % bingo_val)
	print("blank_points=%d" % blank_pts)


static func _invalid(
	runner: SceneTree, lex: FakeLexicon, committed: Array, move: Array,
	want_reason: String, want_word: String, label: String
) -> void:
	var res := ScrabbleRules.validate_move(_board(committed), move, lex, [])
	runner.assert_eq(res.get("ok"), false, label + "_not_ok")
	runner.assert_eq(str(res.get("reason", "")), want_reason, label + "_reason")
	runner.assert_eq(str(res.get("reason_word", "")), want_word, label + "_word")
	runner.assert_eq(int(res.get("total", -1)), 0, label + "_total_zero")


static func _invalid_rack(runner: SceneTree, lex: FakeLexicon, want_reason: String, label: String) -> void:
	# CATS with a rack holding only Z: no S available.
	var res := ScrabbleRules.validate_move(
		_board([[6, 7, "C"], [7, 7, "A"], [8, 7, "T"]]),
		[_pl(9, 7, "S")], lex, ["Z"]
	)
	runner.assert_eq(res.get("ok"), false, label + "_not_ok")
	runner.assert_eq(str(res.get("reason", "")), want_reason, label + "_reason")
	# A blank C with no blank in the rack is also a shortage.
	var res2 := ScrabbleRules.validate_move(
		_board([]),
		[_pl(6, 7, "C", true), _pl(7, 7, "A"), _pl(8, 7, "T")],
		lex, ["C", "A", "T"]
	)
	runner.assert_eq(res2.get("ok"), false, label + "_blank_not_ok")
	runner.assert_eq(str(res2.get("reason", "")), want_reason, label + "_blank_reason")


static func _board(committed: Array) -> FakeBoard:
	var b := FakeBoard.new()
	for t in committed:
		b.set_tile(int((t as Array)[0]), int((t as Array)[1]), str((t as Array)[2]))
	return b


static func _pl(col: int, row: int, letter: String, blank: bool = false) -> Dictionary:
	return {"col": col, "row": row, "letter": letter, "blank": blank}
