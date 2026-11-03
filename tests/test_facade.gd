# Wordtable LocalGame facade scripted suite (pure logic, no scene deps).
# Run headless via res://tests/test_runner.gd (`--suite facade` or full run).
# Drives one scripted 3-player game through place/exchange/pass/recall/shuffle
# and prints the acceptance markers: facade_players=3, facade_complete=true.
class_name TestFacade
extends RefCounted


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


static func _pl(col: int, row: int, letter: String, blank: bool = false) -> Dictionary:
	return {"col": col, "row": row, "letter": letter, "blank": blank}


static func run_all(runner: SceneTree) -> void:
	print("facade_players=3")
	var lex := FakeLexicon.new(["CAT", "CATS", "OX", "CO", "AX", "TE", "OXE"])
	var fg := LocalGame.new(3, 1234, lex)
	runner.assert_eq(fg.player_count(), 3, "facade_three_players")
	runner.assert_eq(fg.current_player(), 0, "facade_starts_p0")

	# Deterministic racks plus a full bag so the exchange path conserves size.
	fg.debug_set_rack(0, ["C", "A", "T", "D", "E", "F", "G"])
	fg.debug_set_rack(1, ["S", "B", "C", "D", "E", "F", "G"])
	fg.debug_set_rack(2, ["O", "X", "C", "D", "E", "F", "G"])
	var full: Array = []
	for i: int in range(100):
		full.append("E")
	fg.debug_set_bag(full)
	runner.assert_eq(fg.bag_remaining(), 100, "facade_full_bag_100")

	# P0 first move CAT through the center; total must equal the direct
	# rules call on identical input (scoring parity).
	var cat_move := [_pl(6, 7, "C"), _pl(7, 7, "A"), _pl(8, 7, "T")]
	var rack0: Array = fg.rack_letters(0)
	var expect := ScrabbleRules.validate_move(fg.board, cat_move, lex, rack0)
	runner.assert_true(bool(expect.get("ok", false)), "facade_cat_expect_ok")
	var r0 := fg.place(cat_move)
	runner.assert_true(bool(r0.get("ok", false)), "facade_cat_ok")
	runner.assert_eq(str(r0.get("kind", "")), "commit", "facade_cat_kind_commit")
	runner.assert_eq(
		int(r0.get("total", -1)), int(expect.get("total", -2)), "facade_parity_cat_total"
	)
	runner.assert_eq(int(fg.scores()[0]), int(expect.get("total", 0)), "facade_cat_banks_p0")
	runner.assert_eq(fg.current_player(), 1, "facade_cat_advances_turn")
	runner.assert_eq(str(fg.state_delta().get("m", "")), "turn_update", "facade_delta_turn_update")
	runner.assert_eq(fg.board.tile_at(7, 7), "A", "facade_cat_center_a")

	# P1 extends to CATS with a lone S at (9,7); replay-free single tile.
	fg.debug_set_rack(1, ["S", "H", "I", "J", "K", "L", "M"])
	var r1 := fg.place([_pl(9, 7, "S")])
	runner.assert_true(bool(r1.get("ok", false)), "facade_cats_ok")
	runner.assert_eq(str(r1.get("kind", "")), "commit", "facade_cats_kind_commit")
	runner.assert_eq(int(r1.get("total", -1)), 6, "facade_cats_total_6")
	var w1: Array = r1.get("words", [])
	runner.assert_true(w1.size() >= 1, "facade_cats_has_words")
	if w1.size() >= 1:
		runner.assert_eq(
			str((w1[0] as Dictionary).get("word", "")), "CATS", "facade_cats_word"
		)
	runner.assert_eq(fg.current_player(), 2, "facade_cats_advances_turn")

	# P2 OX under CAT: main OX plus CO/AX crosses, 10 + 5 + 9 = 24.
	fg.debug_set_rack(2, ["O", "X", "N", "P", "Q", "R", "S"])
	var r2 := fg.place([_pl(6, 8, "O"), _pl(7, 8, "X")])
	runner.assert_true(bool(r2.get("ok", false)), "facade_ox_ok")
	runner.assert_eq(str(r2.get("kind", "")), "commit", "facade_ox_kind_commit")
	runner.assert_eq(int(r2.get("total", -1)), 24, "facade_ox_total_24")
	runner.assert_eq(fg.current_player(), 0, "facade_ox_wraps_to_p0")
	runner.assert_eq(fg.history().size(), 3, "facade_history_three_commits")

	# Forced NOT_IN_DICTIONARY reject: Q at (8,8) forms XQ across and TQ
	# down, neither in the fake lexicon. Board, scores, and turn stay put.
	fg.debug_set_rack(0, ["Q", "X", "E", "E", "E", "E", "E"])
	var turn_before: int = fg.current_player()
	var scores_before: Array = fg.scores()
	var tile_before := fg.board.tile_at(8, 8)
	var rbad := fg.place([_pl(8, 8, "Q")])
	runner.assert_eq(bool(rbad.get("ok", true)), false, "facade_reject_not_ok")
	runner.assert_eq(str(rbad.get("kind", "")), "reject", "facade_reject_kind")
	runner.assert_eq(
		str(rbad.get("reason", "")), "NOT_IN_DICTIONARY", "facade_reject_reason_dict"
	)
	runner.assert_eq(int(rbad.get("total", -1)), 0, "facade_reject_total_zero")
	runner.assert_eq(fg.board.tile_at(8, 8), tile_before, "facade_reject_board_unchanged")
	runner.assert_eq(fg.scores(), scores_before, "facade_reject_scores_unchanged")
	runner.assert_eq(fg.current_player(), turn_before, "facade_reject_turn_unchanged")

	# Pending buffer kept on reject blocks exchange/shuffle/pass_turn.
	var rex_blocked := fg.exchange(1)
	runner.assert_eq(bool(rex_blocked.get("ok", true)), false, "facade_pending_blocks_exchange")
	runner.assert_eq(
		str(rex_blocked.get("reason", "")), "PENDING_NOT_EMPTY", "facade_pending_exchange_reason"
	)
	var rsh_blocked := fg.shuffle()
	runner.assert_eq(bool(rsh_blocked.get("ok", true)), false, "facade_pending_blocks_shuffle")
	runner.assert_eq(
		str(rsh_blocked.get("reason", "")), "PENDING_NOT_EMPTY", "facade_pending_shuffle_reason"
	)
	var rpass_blocked := fg.pass_turn()
	runner.assert_eq(bool(rpass_blocked.get("ok", true)), false, "facade_pending_blocks_pass")
	runner.assert_eq(
		str(rpass_blocked.get("reason", "")), "PENDING_NOT_EMPTY", "facade_pending_pass_reason"
	)

	# Preview is pure: E at (8,8) extends OX to OXE across and TE down
	# (both lexicon-legal) and touches nothing.
	fg.debug_set_rack(0, ["E", "E", "E", "E", "E", "E", "E"])
	var turn_p: int = fg.current_player()
	var scores_p: Array = fg.scores()
	var rprev := fg.preview([_pl(8, 8, "E")])
	runner.assert_true(bool(rprev.get("ok", false)), "facade_preview_ok")
	runner.assert_eq(fg.current_player(), turn_p, "facade_preview_turn_unchanged")
	runner.assert_eq(fg.scores(), scores_p, "facade_preview_scores_unchanged")
	runner.assert_eq(fg.board.tile_at(8, 8), tile_before, "facade_preview_board_unchanged")

	# Recall clears the pending buffer set by the rejected place.
	var rrec := fg.recall()
	runner.assert_true(bool(rrec.get("ok", false)), "facade_recall_ok")
	runner.assert_eq(str(rrec.get("kind", "")), "recall", "facade_recall_kind")
	runner.assert_eq(int(rrec.get("recalled", -1)), 1, "facade_recall_count_1")
	runner.assert_eq(fg.pending_count(), 0, "facade_recall_clears_pending")

	# Shuffle reorders only the current rack and preserves the multiset.
	fg.debug_set_rack(fg.current_player(), ["A", "B", "C", "D", "E", "F", "G"])
	var rack_before: Array = fg.rack_letters(fg.current_player())
	var rsh := fg.shuffle()
	runner.assert_true(bool(rsh.get("ok", false)), "facade_shuffle_ok")
	runner.assert_eq(str(rsh.get("kind", "")), "shuffle", "facade_shuffle_kind")
	var rack_after: Array = fg.rack_letters(fg.current_player())
	var sb: Array = rack_before.duplicate()
	sb.sort()
	var sa: Array = rack_after.duplicate()
	sa.sort()
	runner.assert_eq(sb, sa, "facade_shuffle_preserves_multiset")
	runner.assert_eq(fg.current_player(), turn_p, "facade_shuffle_keeps_turn")

	# Exchange conserves the bag and advances the turn as a scoreless move.
	var bag_before: int = fg.bag_remaining()
	var turn_e: int = fg.current_player()
	var rex := fg.exchange(2)
	runner.assert_true(bool(rex.get("ok", false)), "facade_exchange_ok")
	runner.assert_eq(str(rex.get("kind", "")), "exchange", "facade_exchange_kind")
	runner.assert_eq(fg.bag_remaining(), bag_before, "facade_exchange_conserves_bag")
	runner.assert_eq(fg.rack_letters(0).size(), 7, "facade_exchange_rack_p0_7")
	runner.assert_eq(fg.rack_letters(1).size(), 7, "facade_exchange_rack_p1_7")
	runner.assert_eq(fg.rack_letters(2).size(), 7, "facade_exchange_rack_p2_7")
	runner.assert_eq(
		fg.current_player(), (turn_e + 1) % 3, "facade_exchange_advances_turn"
	)

	# Pass is a scoreless turn with kind pass.
	var turn_pass: int = fg.current_player()
	var rpass := fg.pass_turn()
	runner.assert_true(bool(rpass.get("ok", false)), "facade_pass_ok")
	runner.assert_eq(str(rpass.get("kind", "")), "pass", "facade_pass_kind")
	runner.assert_eq(
		fg.current_player(), (turn_pass + 1) % 3, "facade_pass_advances_turn"
	)

	# Six straight scoreless turns end the game (exchange + pass above count
	# toward the streak, so drain until the machine reports six_scoreless).
	for i: int in range(6):
		if fg.is_over():
			break
		fg.pass_turn()
	runner.assert_true(fg.is_over(), "facade_over")
	runner.assert_eq(fg.ending(), "six_scoreless", "facade_ending_scoreless")
	var delta := fg.state_delta()
	runner.assert_eq(str(delta.get("m", "")), "game_over", "facade_delta_game_over")
	runner.assert_true(bool(delta.get("over", false)), "facade_delta_over_true")
	runner.assert_true((delta.get("history", []) as Array).size() >= 3, "facade_delta_keeps_history")
	_facade_exact_rack_consumption(runner)
	print("facade_complete=true")


# End-to-end rack-identity regression: the played letters sit mid-rack,
# so the old pop-front path would keep the wrong tiles; the commit must
# drop exactly the fresh faces written to the board.
static func _facade_exact_rack_consumption(runner: SceneTree) -> void:
	var lex := FakeLexicon.new(["CAT", "CATS", "OX", "CO", "AX", "TE", "OXE"])
	var fg := LocalGame.new(2, 4321, lex)
	fg.debug_set_rack(0, ["X", "C", "A", "T", "D", "E", "F"])
	var full: Array = []
	for i: int in range(100):
		full.append("E")
	fg.debug_set_bag(full)
	var r := fg.place([_pl(6, 7, "C"), _pl(7, 7, "A"), _pl(8, 7, "T")])
	runner.assert_true(bool(r.get("ok", false)), "facade_exact_commit_ok")
	var after: Array = fg.rack_letters(0).duplicate()
	after.sort()
	# Pre-rack minus C/A/T plus three E refills from the pinned bag.
	runner.assert_eq(after, ["D", "E", "E", "E", "E", "F", "X"], "facade_exact_drops_played_faces")
