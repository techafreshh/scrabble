# Wordtable LocalGame facade scripted suite (pure logic, no scene deps).
# Run headless via res://tests/test_runner.gd (`--suite facade` or full run).
# Drives one scripted 3-player headless game through every intent and prints
# the acceptance markers: facade_players=3, facade_complete=true.
class_name TestFacade
extends RefCounted


# Minimal lexicon double over the scripted word list (duck-typed is_word).
class FakeLexicon extends RefCounted:
	var _words: Dictionary = {}

	func _init(word_list: Array = []) -> void:
		for w in word_list:
			_words[str(w).strip_edges().to_upper()] = true

	func is_word(raw: String) -> bool:
		return _words.has(str(raw).strip_edges().to_upper())


static func run_all(runner: SceneTree) -> void:
	print("facade_players=3")
	var lex := FakeLexicon.new(["CAT", "CATS", "TE", "OX", "CO", "AX"])
	var game := LocalGame.new(3, 1234, lex)
	runner.assert_eq(game.player_count(), 3, "facade_three_players")
	runner.assert_eq(game.current_player(), 0, "facade_starts_p0")
	runner.assert_eq(game.is_over(), false, "facade_not_over_at_start")

	# P0 first move: CAT through the center star; commit total must equal a
	# direct rules call on the same position (scoring parity).
	game.debug_set_rack(0, ["C", "A", "T", "D", "E", "F", "G"])
	var cat_move := [
		{"col": 6, "row": 7, "letter": "C"},
		{"col": 7, "row": 7, "letter": "A"},
		{"col": 8, "row": 7, "letter": "T"},
	]
	var want := ScrabbleRules.validate_move(
		ScrabbleBoard.new(), cat_move, lex, game.rack_letters(0)
	)
	runner.assert_true(bool(want.get("ok", false)), "facade_cat_reference_ok")
	var res := game.place(cat_move)
	runner.assert_true(bool(res.get("ok", false)), "facade_cat_commit_ok")
	runner.assert_eq(str(res.get("kind", "")), "commit", "facade_cat_kind_commit")
	runner.assert_eq(
		int(res.get("total", -1)), int(want.get("total", -2)), "facade_cat_parity"
	)
	var cat_words: Array = res.get("words", [])
	runner.assert_eq(
		str((cat_words[0] as Dictionary).get("word", "")), "CAT", "facade_cat_word"
	)
	runner.assert_eq(game.current_player(), 1, "facade_turn_advances_p1")
	runner.assert_eq(
		int((game.scores() as Array)[0]),
		int(want.get("total", 0)),
		"facade_cat_scores_p0"
	)
	runner.assert_eq(
		str(game.state_delta().get("m", "")), "turn_update", "facade_delta_turn_update"
	)

	# P1 extends CAT to CATS; parity against a shadow board with CAT placed.
	game.debug_set_rack(1, ["S", "D", "E", "F", "G", "H", "I"])
	var cats_move := [{"col": 9, "row": 7, "letter": "S"}]
	var want2 := ScrabbleRules.validate_move(
		_shadow(["C", "A", "T"], 6, 7, true), cats_move, lex, game.rack_letters(1)
	)
	runner.assert_true(bool(want2.get("ok", false)), "facade_cats_reference_ok")
	var res2 := game.place(cats_move)
	runner.assert_eq(str(res2.get("kind", "")), "commit", "facade_cats_kind_commit")
	runner.assert_eq(
		int(res2.get("total", -1)), int(want2.get("total", -2)), "facade_cats_parity"
	)
	runner.assert_eq(game.current_player(), 2, "facade_turn_advances_p2")
	runner.assert_eq(game.history().size(), 2, "facade_history_two")

	# P2 probes: preview is pure (OX cross scores 24 per the rules gold
	# corpus), recall on empty pendings, shuffle keeps the rack multiset,
	# exchange conserves the bag, pass advances the turn.
	game.debug_set_rack(2, ["O", "X", "D", "E", "F", "G", "H"])
	var ox_move := [
		{"col": 6, "row": 8, "letter": "O"},
		{"col": 7, "row": 8, "letter": "X"},
	]
	var bag_before_preview: int = game.bag_remaining()
	var turn_before_preview: int = game.current_player()
	var scores_before_preview: Array = game.scores()
	var pv := game.preview(ox_move)
	runner.assert_true(bool(pv.get("ok", false)), "facade_preview_ok")
	runner.assert_eq(int(pv.get("total", -1)), 24, "facade_preview_ox_24")
	runner.assert_eq(game.get_board().tile_at(6, 8), "", "facade_preview_no_write")
	runner.assert_eq(game.current_player(), turn_before_preview, "facade_preview_no_turn")
	runner.assert_eq(game.scores(), scores_before_preview, "facade_preview_no_score")
	runner.assert_eq(game.bag_remaining(), bag_before_preview, "facade_preview_no_bag")

	var rec0 := game.recall()
	runner.assert_eq(str(rec0.get("kind", "")), "recall", "facade_recall_kind")
	runner.assert_eq(int(rec0.get("recalled", -1)), 0, "facade_recall_empty_zero")

	var rack_before: Array = game.rack_letters(2)
	var sh := game.shuffle()
	runner.assert_true(bool(sh.get("ok", false)), "facade_shuffle_ok")
	runner.assert_eq(str(sh.get("kind", "")), "shuffle", "facade_shuffle_kind")
	runner.assert_eq(
		_sorted(game.rack_letters(2)), _sorted(rack_before), "facade_shuffle_multiset"
	)
	runner.assert_eq(game.current_player(), 2, "facade_shuffle_no_turn")

	var bag_before: int = game.bag_remaining()
	var ex := game.exchange(2)
	runner.assert_true(bool(ex.get("ok", false)), "facade_exchange_ok")
	runner.assert_eq(str(ex.get("kind", "")), "exchange", "facade_exchange_kind")
	runner.assert_eq(game.bag_remaining(), bag_before, "facade_exchange_bag_conserved")
	runner.assert_eq(game.current_player(), 0, "facade_exchange_turn_p0")

	var ps := game.pass_turn()
	runner.assert_true(bool(ps.get("ok", false)), "facade_pass_ok")
	runner.assert_eq(str(ps.get("kind", "")), "pass", "facade_pass_kind")
	runner.assert_eq(game.current_player(), 1, "facade_pass_turn_p1")

	# P1 reject: CATSZ is not in the lexicon; board/scores/turn untouched.
	game.debug_set_rack(1, ["Z", "D", "E", "F", "G", "H", "I"])
	var turn_before: int = game.current_player()
	var scores_before: Array = game.scores()
	var bad := game.place([{"col": 10, "row": 7, "letter": "Z"}])
	runner.assert_eq(bool(bad.get("ok", true)), false, "facade_reject_not_ok")
	runner.assert_eq(str(bad.get("kind", "")), "reject", "facade_reject_kind")
	runner.assert_eq(
		str(bad.get("reason", "")), "NOT_IN_DICTIONARY", "facade_reject_reason"
	)
	runner.assert_eq(str(bad.get("reason_word", "")), "CATSZ", "facade_reject_word")
	runner.assert_eq(game.get_board().tile_at(10, 7), "", "facade_reject_no_write")
	runner.assert_eq(game.scores(), scores_before, "facade_reject_no_score")
	runner.assert_eq(game.current_player(), turn_before, "facade_reject_no_turn")

	# Pendings survive the reject: exchange/shuffle refuse until recall.
	var ex_blocked := game.exchange(1)
	runner.assert_eq(bool(ex_blocked.get("ok", true)), false, "facade_blocked_not_ok")
	runner.assert_eq(
		str(ex_blocked.get("reason", "")),
		"PENDING_NOT_EMPTY",
		"facade_blocked_exchange_reason"
	)
	runner.assert_eq(game.current_player(), turn_before, "facade_blocked_no_turn")
	var sh_blocked := game.shuffle()
	runner.assert_eq(
		str(sh_blocked.get("reason", "")),
		"PENDING_NOT_EMPTY",
		"facade_blocked_shuffle_reason"
	)
	var rec1 := game.recall()
	runner.assert_eq(str(rec1.get("kind", "")), "recall", "facade_recall_kind_again")
	runner.assert_eq(int(rec1.get("recalled", -1)), 1, "facade_recall_one_pending")

	# P1 scoring cross TE (under the T) resets the scoreless streak; parity
	# with rules on a shadow board carrying CAT + S.
	game.debug_set_rack(1, ["E", "D", "F", "G", "H", "I", "J"])
	var te_move := [{"col": 8, "row": 8, "letter": "E"}]
	var shadow2 := _shadow(["C", "A", "T"], 6, 7, true)
	shadow2.place_tile(9, 7, "S")
	var want3 := ScrabbleRules.validate_move(
		shadow2, te_move, lex, game.rack_letters(1)
	)
	runner.assert_true(bool(want3.get("ok", false)), "facade_te_reference_ok")
	var res3 := game.place(te_move)
	runner.assert_eq(str(res3.get("kind", "")), "commit", "facade_te_kind_commit")
	runner.assert_eq(
		int(res3.get("total", -1)), int(want3.get("total", -2)), "facade_te_parity"
	)
	runner.assert_eq(game.current_player(), 2, "facade_turn_advances_p2_again")

	# Six straight scoreless turns end the game with a game_over delta.
	for i: int in range(6):
		var p := game.pass_turn()
		runner.assert_true(bool(p.get("ok", false)), "facade_final_pass_ok")
	runner.assert_true(game.is_over(), "facade_over_after_six")
	runner.assert_eq(game.ending(), "six_scoreless", "facade_ending_scoreless")
	runner.assert_eq(
		str(game.state_delta().get("m", "")), "game_over", "facade_delta_game_over"
	)
	print("facade_complete=true")


# Shadow board with `letters` laid across (or down) from (col, row).
static func _shadow(letters: Array, col: int, row: int, across: bool) -> ScrabbleBoard:
	var b := ScrabbleBoard.new()
	for i: int in range(letters.size()):
		var c := col + i if across else col
		var r := row if across else row + i
		b.place_tile(c, r, str(letters[i]))
	return b


static func _sorted(rack: Array) -> Array:
	var out := rack.duplicate()
	out.sort()
	return out
