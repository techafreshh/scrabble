# Wordtable game-state scripted suite (pure logic, no scene deps).
# Run headless via res://tests/test_runner.gd (`--suite game_state` or full run).
# Plays exactly 3 scripted games and prints the acceptance markers:
# scripted_games=3, ending=six_scoreless, final_bonus_applied=true,
# rematch_bag=100 (total pool restored to the full 100 tiles on rematch).
class_name TestGameState
extends RefCounted


static func _rack_value(game: ScrabbleGame, player: int) -> int:
	var total := 0
	for face in game.rack_letters(player):
		total += int(ScrabbleGame.LETTER_VALUES.get(str(face), 0))
	return total


static func run_all(runner: SceneTree) -> void:
	_game_bag_empty(runner)
	_game_six_scoreless(runner)
	_game_exchange_and_rematch(runner)
	_game_record_score_exact_tiles(runner)
	print("scripted_games=3")


# Game 1: bag-empty ending. Player 0 goes out from a 1-tile rack with an
# empty bag; player 1 holds Z(10) + Q(10). Winner 5 + 20 = 25, loser -20.
static func _game_bag_empty(runner: SceneTree) -> void:
	var game := ScrabbleGame.new(2, 99)
	game.debug_set_bag([])
	game.debug_set_rack(0, ["A"])
	game.debug_set_rack(1, ["Z", "Q"])
	var res: Dictionary = game.record_score(5, 1, ["A"])
	runner.assert_true(bool(res.get("ok", false)), "game_bag_empty_move_ok")
	runner.assert_true(game.is_over(), "game_bag_empty_over")
	runner.assert_eq(game.ending(), "bag_empty", "game_bag_empty_ending")
	runner.assert_eq(game.score_of(0), 25, "game_bag_empty_winner_25")
	runner.assert_eq(game.score_of(1), -20, "game_bag_empty_loser_minus_20")
	runner.assert_true(game.bonus_applied(), "game_bag_empty_bonus_flag")
	print("final_bonus_applied=" + str(game.bonus_applied()))


# Game 2: six successive scoreless turns. Two passes, one scoring move
# (streak resets to 0), then six passes fire the six_scoreless ending with
# each side deducting only its own unplayed tiles and no bonus paid.
static func _game_six_scoreless(runner: SceneTree) -> void:
	var game := ScrabbleGame.new(2, 7)
	game.pass_turn()
	game.pass_turn()
	runner.assert_eq(game.scoreless_count(), 2, "game_streak_two_passes")
	var faces: Array = game.rack_letters(game.current_player()).slice(0, 2)
	var res: Dictionary = game.record_score(8, 2, faces)
	runner.assert_true(bool(res.get("ok", false)), "game_streak_score_ok")
	runner.assert_eq(game.scoreless_count(), 0, "game_streak_reset_on_score")
	for i: int in range(6):
		game.pass_turn()
	runner.assert_true(game.is_over(), "game_scoreless_over")
	runner.assert_eq(game.ending(), "six_scoreless", "game_scoreless_ending")
	runner.assert_eq(game.bonus_applied(), false, "game_scoreless_no_bonus")
	runner.assert_eq(game.score_of(0), 8 - _rack_value(game, 0), "game_scoreless_deducts_p0")
	runner.assert_eq(game.score_of(1), 0 - _rack_value(game, 1), "game_scoreless_deducts_p1")
	print("ending=" + game.ending())


# Game 3: exchange gating plus rematch reset. A 3-tile bag rejects the
# exchange with nothing touched; a restored full pool accepts it with the
# bag size conserved and the streak bumped; rematch then zeroes scores and
# restores the full 100-tile pool deterministically from the seed.
static func _game_exchange_and_rematch(runner: SceneTree) -> void:
	var game := ScrabbleGame.new(2, 42)
	game.debug_set_bag(["A", "B", "C"])
	var rack_before: Array = game.rack_letters(0)
	var bag_before: int = game.bag_remaining()
	var turn_before: int = game.current_player()
	var rej: Dictionary = game.exchange(2)
	runner.assert_eq(bool(rej.get("ok", true)), false, "game_exchange_rejected")
	runner.assert_eq(str(rej.get("reason", "")), "BAG_TOO_SMALL", "game_exchange_reason_bag_small")
	runner.assert_eq(game.rack_letters(0), rack_before, "game_exchange_reject_rack_unchanged")
	runner.assert_eq(game.bag_remaining(), bag_before, "game_exchange_reject_bag_unchanged")
	runner.assert_eq(game.current_player(), turn_before, "game_exchange_reject_turn_unchanged")
	runner.assert_eq(game.scoreless_count(), 0, "game_exchange_reject_streak_unchanged")

	var full: Array = []
	for i: int in range(100):
		full.append("E")
	game.debug_set_bag(full)
	runner.assert_eq(game.bag_remaining(), 100, "game_exchange_full_bag_100")
	var bad: Dictionary = game.exchange(0)
	runner.assert_eq(bool(bad.get("ok", true)), false, "game_exchange_bad_count_rejected")
	runner.assert_eq(str(bad.get("reason", "")), "BAD_COUNT", "game_exchange_bad_count_reason")

	var streak_before: int = game.scoreless_count()
	var ok: Dictionary = game.exchange(3)
	runner.assert_true(bool(ok.get("ok", false)), "game_exchange_ok")
	runner.assert_eq(game.bag_remaining(), 100, "game_exchange_bag_conserved")
	runner.assert_eq(game.rack_tile_count(0), 7, "game_exchange_rack_stays_7")
	runner.assert_eq(game.scoreless_count(), streak_before + 1, "game_exchange_bumps_streak")
	runner.assert_eq(game.current_player(), (turn_before + 1) % 2, "game_exchange_advances_turn")

	var pre: Array = game.rack_letters(game.current_player()).slice(0, 2)
	var mv: Dictionary = game.record_score(10, 2, pre)
	runner.assert_true(bool(mv.get("ok", false)), "game_prematch_score_ok")
	game.rematch()
	runner.assert_eq(game.score_of(0), 0, "game_rematch_zero_p0")
	runner.assert_eq(game.score_of(1), 0, "game_rematch_zero_p1")
	runner.assert_eq(game.current_player(), 0, "game_rematch_turn_zero")
	runner.assert_eq(game.scoreless_count(), 0, "game_rematch_streak_zero")
	runner.assert_eq(game.is_over(), false, "game_rematch_not_over")
	runner.assert_eq(game.ending(), "", "game_rematch_ending_cleared")
	runner.assert_eq(game.rack_tile_count(0), 7, "game_rematch_rack7_p0")
	runner.assert_eq(game.rack_tile_count(1), 7, "game_rematch_rack7_p1")
	var fresh := ScrabbleGame.new(2, 42)
	runner.assert_eq(game.rack_letters(0), fresh.rack_letters(0), "game_rematch_deterministic_p0")
	runner.assert_eq(game.rack_letters(1), fresh.rack_letters(1), "game_rematch_deterministic_p1")
	var total: int = game.bag_remaining() + game.rack_tile_count(0) + game.rack_tile_count(1)
	runner.assert_eq(total, 100, "game_rematch_total_100")
	print("rematch_bag=100")


# Rack-identity checks for record_score's exact-face path: non-front
# letters, duplicate faces, blank consumption, mismatch/shortage
# rejection, and the legacy count fallback. All racks/bags pinned.
static func _game_record_score_exact_tiles(runner: SceneTree) -> void:
	# Non-front letters: C/A/T sit mid-rack; the exact path keeps X/D/E/F.
	var game := ScrabbleGame.new(2, 5)
	game.debug_set_rack(0, ["X", "C", "A", "T", "D", "E", "F"])
	var full: Array = []
	for i: int in range(100):
		full.append("E")
	game.debug_set_bag(full)
	var res: Dictionary = game.record_score(5, 3, ["C", "A", "T"])
	runner.assert_true(bool(res.get("ok", false)), "game_exact_nonfront_ok")
	var leftover: Array = game.rack_letters(0).duplicate()
	leftover.sort()
	runner.assert_eq(leftover, ["D", "E", "E", "E", "E", "F", "X"], "game_exact_nonfront_keeps_unplayed")
	runner.assert_eq(game.score_of(0), 5, "game_exact_nonfront_banks")
	runner.assert_eq(game.current_player(), 1, "game_exact_nonfront_advances_turn")

	# Duplicate faces: two A tiles, only one consumed (lowercase + padding
	# also proves the face normalization).
	var dup := ScrabbleGame.new(2, 6)
	dup.debug_set_rack(0, ["A", "A", "B", "C", "D", "E", "F"])
	var zbag: Array = []
	for i: int in range(50):
		zbag.append("Z")
	dup.debug_set_bag(zbag)
	var rdup: Dictionary = dup.record_score(4, 1, [" a "])
	runner.assert_true(bool(rdup.get("ok", false)), "game_exact_duplicate_ok")
	var drack: Array = dup.rack_letters(0)
	var acount := 0
	for face in drack:
		if str(face) == "A":
			acount += 1
	runner.assert_eq(acount, 1, "game_exact_duplicate_consumes_one")
	runner.assert_true(drack.has("Z"), "game_exact_duplicate_refills")

	# Blank consumption: a blank placement consumes the blank tile, not
	# the same-face letter tile.
	var bl := ScrabbleGame.new(2, 7)
	bl.debug_set_rack(0, ["", "E", "A", "B", "C", "D", "F"])
	var ebag: Array = []
	for i: int in range(50):
		ebag.append("Z")
	bl.debug_set_bag(ebag)
	var rbl: Dictionary = bl.record_score(3, 1, [{"letter": "E", "blank": true}])
	runner.assert_true(bool(rbl.get("ok", false)), "game_exact_blank_ok")
	var brack: Array = bl.rack_letters(0)
	runner.assert_true(brack.has("E"), "game_exact_blank_keeps_letter_e")
	runner.assert_true(not brack.has(""), "game_exact_blank_consumes_blank")

	# Bare-string blank face ("") also consumes a blank tile.
	var bs := ScrabbleGame.new(2, 8)
	bs.debug_set_rack(0, ["", "Q", "A", "B", "C", "D", "F"])
	var qbag: Array = []
	for i: int in range(50):
		qbag.append("Z")
	bs.debug_set_bag(qbag)
	var rbs: Dictionary = bs.record_score(2, 1, [""])
	runner.assert_true(bool(rbs.get("ok", false)), "game_exact_bare_blank_ok")
	var bsrack: Array = bs.rack_letters(0)
	runner.assert_true(bsrack.has("Q"), "game_exact_bare_blank_keeps_q")
	runner.assert_true(not bsrack.has(""), "game_exact_bare_blank_consumed")

	# Size mismatch: played.size() != tiles_played rejects untouched.
	var mm := ScrabbleGame.new(2, 9)
	mm.debug_set_rack(0, ["C", "A", "T", "D", "E", "F", "G"])
	var mbag: Array = []
	for i: int in range(40):
		mbag.append("E")
	mm.debug_set_bag(mbag)
	var rack_before: Array = mm.rack_letters(0)
	var bag_before: int = mm.bag_remaining()
	var rmm: Dictionary = mm.record_score(5, 3, ["C", "A"])
	runner.assert_eq(bool(rmm.get("ok", true)), false, "game_exact_mismatch_rejected")
	runner.assert_eq(str(rmm.get("reason", "")), "BAD_PLAY", "game_exact_mismatch_reason")
	runner.assert_eq(mm.rack_letters(0), rack_before, "game_exact_mismatch_rack_unchanged")
	runner.assert_eq(mm.bag_remaining(), bag_before, "game_exact_mismatch_bag_unchanged")
	runner.assert_eq(mm.score_of(0), 0, "game_exact_mismatch_score_unchanged")
	runner.assert_eq(mm.current_player(), 0, "game_exact_mismatch_turn_unchanged")

	# Shortage: a played face absent from the rack rejects untouched.
	var rshort: Dictionary = mm.record_score(5, 1, ["Z"])
	runner.assert_eq(bool(rshort.get("ok", true)), false, "game_exact_shortage_rejected")
	runner.assert_eq(str(rshort.get("reason", "")), "BAD_PLAY", "game_exact_shortage_reason")
	runner.assert_eq(mm.rack_letters(0), rack_before, "game_exact_shortage_rack_unchanged")
	runner.assert_eq(mm.bag_remaining(), bag_before, "game_exact_shortage_bag_unchanged")
	runner.assert_eq(mm.score_of(0), 0, "game_exact_shortage_score_unchanged")
	runner.assert_eq(mm.current_player(), 0, "game_exact_shortage_turn_unchanged")

	# is_blank-keyed dict: same blank-aware consumption as the blank key.
	var bi := ScrabbleGame.new(2, 10)
	bi.debug_set_rack(0, ["", "E", "A", "B", "C", "D", "F"])
	var ibag: Array = []
	for i: int in range(50):
		ibag.append("Z")
	bi.debug_set_bag(ibag)
	var rbi: Dictionary = bi.record_score(3, 1, [{"letter": "E", "is_blank": true}])
	runner.assert_true(bool(rbi.get("ok", false)), "game_exact_is_blank_ok")
	var birack: Array = bi.rack_letters(0)
	runner.assert_true(birack.has("E"), "game_exact_is_blank_keeps_letter_e")
	runner.assert_true(not birack.has(""), "game_exact_is_blank_consumes_blank")

	# Malformed entries: a non-String/Dictionary face and an explicit
	# non-blank empty face both reject BAD_PLAY with state untouched.
	var mf := ScrabbleGame.new(2, 12)
	mf.debug_set_rack(0, ["C", "A", "T", "D", "E", "F", "G"])
	var fbag: Array = []
	for i: int in range(40):
		fbag.append("E")
	mf.debug_set_bag(fbag)
	var mf_rack: Array = mf.rack_letters(0)
	var mf_bag: int = mf.bag_remaining()
	var rmf: Dictionary = mf.record_score(5, 1, [42])
	runner.assert_eq(bool(rmf.get("ok", true)), false, "game_exact_malformed_rejected")
	runner.assert_eq(str(rmf.get("reason", "")), "BAD_PLAY", "game_exact_malformed_reason")
	runner.assert_eq(mf.rack_letters(0), mf_rack, "game_exact_malformed_rack_unchanged")
	runner.assert_eq(mf.bag_remaining(), mf_bag, "game_exact_malformed_bag_unchanged")
	runner.assert_eq(mf.score_of(0), 0, "game_exact_malformed_score_unchanged")
	runner.assert_eq(mf.current_player(), 0, "game_exact_malformed_turn_unchanged")
	var rempty: Dictionary = mf.record_score(5, 1, [{"letter": "", "blank": false}])
	runner.assert_eq(bool(rempty.get("ok", true)), false, "game_exact_empty_face_rejected")
	runner.assert_eq(str(rempty.get("reason", "")), "BAD_PLAY", "game_exact_empty_face_reason")
	runner.assert_eq(mf.rack_letters(0), mf_rack, "game_exact_empty_face_rack_unchanged")
	runner.assert_eq(mf.score_of(0), 0, "game_exact_empty_face_score_unchanged")
	runner.assert_eq(mf.current_player(), 0, "game_exact_empty_face_turn_unchanged")

	# Legacy count path removed: a count-only call rejects BAD_PLAY with
	# rack/bag/score/turn untouched instead of guessing front tiles.
	var leg := ScrabbleGame.new(2, 11)
	leg.debug_set_rack(0, ["X", "C", "A", "T", "D", "E", "F"])
	leg.debug_set_bag([])
	var leg_rack: Array = leg.rack_letters(0)
	var leg_bag: int = leg.bag_remaining()
	var rleg: Dictionary = leg.record_score(5, 2)
	runner.assert_eq(bool(rleg.get("ok", true)), false, "game_exact_legacy_rejected")
	runner.assert_eq(str(rleg.get("reason", "")), "BAD_PLAY", "game_exact_legacy_reason")
	runner.assert_eq(leg.rack_letters(0), leg_rack, "game_exact_legacy_rack_unchanged")
	runner.assert_eq(leg.bag_remaining(), leg_bag, "game_exact_legacy_bag_unchanged")
	runner.assert_eq(leg.score_of(0), 0, "game_exact_legacy_score_unchanged")
	runner.assert_eq(leg.current_player(), 0, "game_exact_legacy_turn_unchanged")
