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
	print("scripted_games=3")


# Game 1: bag-empty ending. Player 0 goes out from a 1-tile rack with an
# empty bag; player 1 holds Z(10) + Q(10). Winner 5 + 20 = 25, loser -20.
static func _game_bag_empty(runner: SceneTree) -> void:
	var game := ScrabbleGame.new(2, 99)
	game.debug_set_bag([])
	game.debug_set_rack(0, ["A"])
	game.debug_set_rack(1, ["Z", "Q"])
	var res: Dictionary = game.record_score(5, 1)
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
	var res: Dictionary = game.record_score(8, 2)
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

	var mv: Dictionary = game.record_score(10, 2)
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
