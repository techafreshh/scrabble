# Wordtable bot move generator suite (pure logic, no scene deps).
# Proves the ScrabbleBot contract headless: a mid-game board plus a rack
# with a blank yields a legal rules-parity move within 300 ms, seeds
# jitter the pick, and an empty board plus a blank opens through the star
# with the blank declaring its face. Prints the bot_move_legal /
# bot_gen_ms / bot_jitter acceptance markers.
class_name TestBotGen
extends RefCounted


# Minimal lexicon double over a word list (duck-typed via is_word).
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
	# Fixture A: CAT committed mid-board, rack holding a blank.
	var board := ScrabbleBoard.new()
	board.place_tile(6, 7, "C")
	board.place_tile(7, 7, "A")
	board.place_tile(8, 7, "T")
	var lex := FakeLexicon.new(["CAT", "CATS", "OX", "CO", "AX", "TE", "OXE"])
	var rack := ["S", "O", "X", "E", "D", "F", ""]
	var t0 := Time.get_ticks_msec()
	var mv := ScrabbleBot.generate_move(board, rack, lex, 7)
	var elapsed := int(Time.get_ticks_msec() - t0)
	runner.assert_eq(bool(mv.get("ok", false)), true, "bot_gen_finds_move")
	var placements: Array = mv.get("placements", [])
	runner.assert_true(not placements.is_empty(), "bot_gen_nonempty")
	var parity := ScrabbleRules.validate_move(board, placements, lex, rack)
	runner.assert_eq(bool(parity.get("ok", false)), true, "bot_gen_parity_ok")
	runner.assert_eq(int(parity.get("total", -1)), int(mv.get("total", -2)), "bot_gen_total_parity")
	if bool(mv.get("ok", false)) and bool(parity.get("ok", false)):
		print("bot_move_legal=true")
	else:
		print("bot_move_legal=false")
	print("bot_gen_ms=%d" % elapsed)
	runner.assert_true(elapsed < 300, "bot_gen_under_300ms")
	var mv_b := ScrabbleBot.generate_move(board, rack, lex, 8)
	var jitter := ScrabbleBot.think_delay_secs(7) != ScrabbleBot.think_delay_secs(8)
	jitter = jitter or str(placements) != str(mv_b.get("placements", []))
	runner.assert_true(jitter, "bot_gen_seed_jitter")
	if jitter:
		print("bot_jitter=true")
	else:
		print("bot_jitter=false")
	for s in [0, 1, 7, 8, 100, 1000003]:
		runner.assert_true(
			ScrabbleBot.think_delay_secs(s) >= ScrabbleBot.THINK_MIN_SECS
			and ScrabbleBot.think_delay_secs(s) <= ScrabbleBot.THINK_MAX_SECS,
			"bot_think_range_%d" % s
		)
	runner.assert_eq(ScrabbleBot.think_delay_ms(7), ScrabbleBot.think_delay_secs(7) * 1000, "bot_think_ms_parity")

	# Fixture B: empty board, blank + A + T against a CAT-only lexicon.
	var empty_board := ScrabbleBoard.new()
	var lex_b := FakeLexicon.new(["CAT"])
	var mv2 := ScrabbleBot.generate_move(empty_board, ["", "A", "T"], lex_b, 7)
	runner.assert_eq(bool(mv2.get("ok", false)), true, "bot_blank_finds_move")
	var blanks := 0
	var blank_is_c := false
	var covers_center := false
	for p in (mv2.get("placements", []) as Array):
		var d: Dictionary = p
		if bool(d.get("blank", false)):
			blanks += 1
			if str(d.get("letter", "")) == "C":
				blank_is_c = true
		if int(d.get("col", -1)) == ScrabbleBoard.CENTER.x and int(d.get("row", -1)) == ScrabbleBoard.CENTER.y:
			covers_center = true
	runner.assert_eq(blanks, 1, "bot_blank_single_blank")
	runner.assert_true(blank_is_c, "bot_blank_face_c")
	runner.assert_true(covers_center, "bot_blank_covers_center")
	var parity2 := ScrabbleRules.validate_move(
		empty_board, mv2.get("placements", []), lex_b, ["", "A", "T"]
	)
	runner.assert_eq(bool(parity2.get("ok", false)), true, "bot_blank_parity_ok")
	runner.assert_eq(int(parity2.get("total", -1)), int(mv2.get("total", -2)), "bot_blank_total_parity")

	# Fixture C: no legal move exists (rack cannot spell anything).
	var mv3 := ScrabbleBot.generate_move(board, ["Q", "Q", "Q"], FakeLexicon.new(["CAT"]), 7)
	runner.assert_eq(bool(mv3.get("ok", false)), false, "bot_no_move_false")
	runner.assert_eq(str(mv3.get("reason", "")), "NO_MOVE", "bot_no_move_reason")
