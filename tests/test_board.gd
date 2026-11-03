# Wordtable board suite (pure logic, no scene deps).
# Run headless via res://tests/test_runner.gd (`--suite board` or full run).
# Prints the board_size / H8 / extract acceptance markers on every board run.
class_name TestBoard
extends RefCounted


static func run_all(runner: SceneTree) -> void:
	runner.assert_eq(ScrabbleBoard.SIZE, 15, "board_size_is_15")
	runner.assert_eq(ScrabbleBoard.TW.size(), 8, "board_tw_count_8")
	runner.assert_eq(ScrabbleBoard.DW.size(), 17, "board_dw_count_17")
	runner.assert_eq(ScrabbleBoard.TL.size(), 12, "board_tl_count_12")
	runner.assert_eq(ScrabbleBoard.DL.size(), 24, "board_dl_count_24")
	var tw := 0
	var dw := 0
	var tl := 0
	var dl := 0
	for r: int in range(ScrabbleBoard.SIZE):
		for c: int in range(ScrabbleBoard.SIZE):
			match ScrabbleBoard.premium_at(c, r):
				"TW":
					tw += 1
				"DW", "STAR_DW":
					dw += 1
				"TL":
					tl += 1
				"DL":
					dl += 1
	runner.assert_eq(tw, 8, "board_tw_cells_8")
	runner.assert_eq(dw, 17, "board_dw_cells_17")
	runner.assert_eq(tl, 12, "board_tl_cells_12")
	runner.assert_eq(dl, 24, "board_dl_cells_24")
	print("board_size=15x15")

	runner.assert_eq(ScrabbleBoard.premium_at(7, 7), "STAR_DW", "board_center_is_star")
	runner.assert_eq(ScrabbleBoard.premium_at(0, 0), "TW", "board_a1_is_tw")
	runner.assert_eq(ScrabbleBoard.premium_at(1, 1), "DW", "board_b2_is_dw")
	runner.assert_eq(ScrabbleBoard.premium_at(5, 1), "TL", "board_f2_is_tl")
	runner.assert_eq(ScrabbleBoard.premium_at(3, 0), "DL", "board_d1_is_dl")
	runner.assert_eq(ScrabbleBoard.premium_at(7, 0), "TW", "board_h1_is_tw")
	runner.assert_eq(ScrabbleBoard.premium_at(3, 7), "DL", "board_d8_is_dl")
	runner.assert_eq(ScrabbleBoard.premium_at(0, 3), "DL", "board_a4_is_dl")
	runner.assert_eq(ScrabbleBoard.premium_at(7, 7), "STAR_DW", "board_h8_is_star_dw")
	print("H8=STAR_DW")

	runner.assert_eq(ScrabbleBoard.square_to_cell("5F"), Vector2i(5, 4), "board_5f_to_cell")
	runner.assert_eq(ScrabbleBoard.cell_to_square(5, 4), "5F", "board_cell_to_5f")
	runner.assert_eq(ScrabbleBoard.square_to_cell("H8"), Vector2i(7, 7), "board_h8_to_cell")
	runner.assert_eq(
		ScrabbleBoard.square_to_cell(ScrabbleBoard.cell_to_square(7, 7)),
		Vector2i(7, 7),
		"board_h8_roundtrip"
	)
	runner.assert_eq(ScrabbleBoard.square_to_cell("f5"), Vector2i(5, 4), "board_lowercase_ok")
	runner.assert_eq(ScrabbleBoard.square_to_cell("  H8 "), Vector2i(7, 7), "board_padded_ok")
	runner.assert_eq(ScrabbleBoard.square_to_cell("A1"), Vector2i(0, 0), "board_a1_to_cell")
	runner.assert_eq(ScrabbleBoard.square_to_cell("O15"), Vector2i(14, 14), "board_o15_to_cell")
	runner.assert_eq(ScrabbleBoard.cell_to_square(0, 0), "1A", "board_corner_square")
	runner.assert_eq(ScrabbleBoard.square_to_cell(""), Vector2i(-1, -1), "board_empty_invalid")
	runner.assert_eq(ScrabbleBoard.square_to_cell("ZZ"), Vector2i(-1, -1), "board_zz_invalid")
	runner.assert_eq(ScrabbleBoard.square_to_cell("A16"), Vector2i(-1, -1), "board_a16_invalid")
	runner.assert_eq(ScrabbleBoard.square_to_cell("P5"), Vector2i(-1, -1), "board_p5_invalid")
	runner.assert_eq(ScrabbleBoard.cell_to_square(-1, 0), "", "board_offboard_square_empty")
	runner.assert_eq(ScrabbleBoard.cell_to_square(15, 15), "", "board_oob_square_empty")

	var board := ScrabbleBoard.new()
	runner.assert_eq(board.tile_at(7, 7), "", "board_center_starts_empty")
	runner.assert_eq(board.tile_at(-1, 0), "", "board_oob_tile_empty")
	runner.assert_eq(board.place_tile(7, 7, ""), false, "board_empty_letter_rejected")
	runner.assert_eq(board.place_tile(-1, 0, "A"), false, "board_oob_place_rejected")

	var letters := ["H", "E", "L", "L", "O"]
	for i: int in range(letters.size()):
		runner.assert_eq(board.place_tile(7, 7 + i, letters[i]), true, "board_place_hello_%d" % i)
	runner.assert_eq(board.place_tile(7, 8, "E"), true, "board_replacing_same_letter_ok")
	runner.assert_eq(board.place_tile(7, 8, "X"), false, "board_overwrite_rejected")
	runner.assert_eq(board.tile_at(7, 8), "E", "board_overwrite_keeps_old")
	var probe := ScrabbleBoard.new()
	runner.assert_eq(probe.try_place_tile(7, 7, "H"), ScrabbleBoard.PLACE_PLACED, "board_try_place_fresh")
	runner.assert_eq(probe.tile_at(7, 7), "H", "board_try_place_fresh_writes")
	runner.assert_eq(probe.try_place_tile(7, 7, "H"), ScrabbleBoard.PLACE_DUPLICATE, "board_try_place_duplicate")
	runner.assert_eq(probe.try_place_tile(7, 7, " h "), ScrabbleBoard.PLACE_DUPLICATE, "board_try_place_duplicate_padded_lower")
	runner.assert_eq(probe.tile_at(7, 7), "H", "board_try_place_duplicate_keeps_cell")
	runner.assert_eq(probe.place_tile(7, 7, "H"), true, "board_replace_same_still_true")
	runner.assert_eq(probe.try_place_tile(7, 7, "X"), ScrabbleBoard.PLACE_REJECTED, "board_try_place_conflict_rejected")
	runner.assert_eq(probe.try_place_tile(-1, 0, "A"), ScrabbleBoard.PLACE_REJECTED, "board_try_place_oob_rejected")
	runner.assert_eq(probe.try_place_tile(0, 0, ""), ScrabbleBoard.PLACE_REJECTED, "board_try_place_empty_rejected")
	runner.assert_eq(probe.tile_at(7, 7), "H", "board_try_place_rejected_keeps_cell")
	runner.assert_eq(board.extract_word_at(7, 7, false), "HELLO", "board_extract_hello_down")
	runner.assert_eq(board.extract_word_at(7, 11, false), "HELLO", "board_extract_hello_tail")
	runner.assert_eq(board.extract_word_at(7, 8, true), "E", "board_extract_single_across")
	runner.assert_eq(board.extract_word_at(0, 0, true), "", "board_extract_empty")
	print("extract=HELLO")

	runner.assert_eq(board.place_tile(6, 8, "B"), true, "board_place_b_left")
	runner.assert_eq(board.place_tile(8, 8, "D"), true, "board_place_d_right")
	runner.assert_eq(board.extract_word_at(6, 8, true), "BED", "board_extract_bed_across")
	var down: Array = board.collect_words(
		[Vector2i(7, 7), Vector2i(7, 8), Vector2i(7, 9), Vector2i(7, 10), Vector2i(7, 11)],
		false
	)
	var down_words: Array = []
	for entry: Dictionary in down:
		down_words.append(str(entry.get("word", "")))
	runner.assert_true(down_words.has("HELLO"), "board_collect_has_hello_main")
	runner.assert_true(down_words.has("BED"), "board_collect_has_bed_cross")
	runner.assert_eq(down.size(), 2, "board_collect_down_two_words")
	var across_run: Array = board.collect_words(
		[Vector2i(6, 8), Vector2i(7, 8), Vector2i(8, 8)], true
	)
	runner.assert_eq(across_run.size(), 2, "board_collect_across_two_words")
	var first_entry: Dictionary = across_run[0]
	runner.assert_eq(str(first_entry.get("word", "")), "BED", "board_collect_main_bed")
	runner.assert_eq(int(first_entry.get("col", -1)), 6, "board_collect_main_col")
	runner.assert_eq(int(first_entry.get("row", -1)), 8, "board_collect_main_row")
	runner.assert_eq(bool(first_entry.get("across", false)), true, "board_collect_main_across")
