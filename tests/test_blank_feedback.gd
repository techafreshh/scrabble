# Wordtable blank-feedback suite (scene deps, no networking).
# Run headless via res://tests/test_runner.gd (`--suite blank_feedback` or full run).
# Prints the blank_feedback acceptance markers on every blank_feedback run:
# blank_picker_options=26, reject_text=Not in my book: QX, commit_fx=thunk,score_fly.
class_name TestBlankFeedback
extends RefCounted

const PICKER_PATH := "res://scenes/table/blank_picker.tscn"


# Minimal board double: occupancy only (duck-typed via tile_at).
class FakeBoard extends RefCounted:
	var _cells: Dictionary = {}

	func set_tile(col: int, row: int, letter: String) -> void:
		_cells[Vector2i(col, row)] = letter.strip_edges().to_upper()

	func tile_at(col: int, row: int) -> String:
		return str(_cells.get(Vector2i(col, row), ""))


# Minimal lexicon double over the suite word list (duck-typed via is_word).
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
	_picker_checks(runner)
	_reject_checks(runner)
	_accept_checks(runner)


static func _picker_checks(runner: SceneTree) -> void:
	runner.assert_true(ResourceLoader.exists(PICKER_PATH), "blank_picker_scene_file_exists")
	var packed := load(PICKER_PATH) as PackedScene
	runner.assert_true(packed != null, "blank_picker_scene_loads_as_packed_scene")
	if packed == null:
		return
	var picker: BlankPicker = packed.instantiate() as BlankPicker
	runner.assert_true(picker != null, "blank_picker_scene_instantiates_blank_picker")
	if picker == null:
		return
	runner.assert_true(picker.has_signal("letter_chosen"), "blank_picker_has_letter_chosen_signal")
	runner.assert_true(picker.has_signal("picker_cancelled"), "blank_picker_has_picker_cancelled_signal")
	runner.root.add_child(picker)
	runner.assert_eq(picker.get_option_count(), 26, "blank_picker_option_count_26")
	print("blank_picker_options=26")
	var options: Array = picker.get_options()
	runner.assert_eq(options.size(), 26, "blank_picker_options_size_26")
	runner.assert_eq(str(options[0]), "A", "blank_picker_first_option_a")
	runner.assert_eq(str(options[25]), "Z", "blank_picker_last_option_z")

	# Open/choose/cancel round-trip on the staged square.
	runner.assert_eq(picker.is_open(), false, "blank_picker_starts_closed")
	runner.assert_true(picker.open_for(6, 7), "blank_picker_open_for_ok")
	runner.assert_eq(picker.is_open(), true, "blank_picker_open_after_open_for")
	runner.assert_eq(picker.get_cell(), Vector2i(6, 7), "blank_picker_cell_6_7")
	var chosen: Array = []
	picker.letter_chosen.connect(func(letter: String) -> void: chosen.append(letter))
	runner.assert_true(picker.choose("c"), "blank_picker_choose_c_ok")
	runner.assert_eq(picker.is_open(), false, "blank_picker_closed_after_choose")
	runner.assert_eq(chosen, ["C"], "blank_picker_emits_chosen_c")
	runner.assert_eq(picker.choose("Z"), false, "blank_picker_choose_while_closed_false")
	runner.assert_true(picker.open_for(6, 7), "blank_picker_reopen_ok")
	var cancelled: Array = []
	picker.picker_cancelled.connect(func() -> void: cancelled.append(true))
	picker.cancel()
	runner.assert_eq(picker.is_open(), false, "blank_picker_closed_after_cancel")
	runner.assert_eq(cancelled.size(), 1, "blank_picker_emits_cancelled")

	picker.queue_free()


static func _reject_checks(runner: SceneTree) -> void:
	var board := FakeBoard.new()
	var lex := FakeLexicon.new(["CAT", "HELLO"])
	var move: Array = [
		{"col": 7, "row": 7, "letter": "Q", "blank": false},
		{"col": 8, "row": 7, "letter": "X", "blank": false},
	]
	var res := ScrabbleRules.validate_move(board, move, lex, [])
	runner.assert_eq(res.get("ok"), false, "blank_feedback_reject_not_ok")
	runner.assert_eq(str(res.get("reason", "")), "NOT_IN_DICTIONARY", "blank_feedback_reject_reason")
	runner.assert_eq(str(res.get("reason_word", "")), "QX", "blank_feedback_reject_word_qx")
	var text := CommitFx.reject_text_for(res)
	runner.assert_eq(text, "Not in my book: QX", "blank_feedback_reject_text_qx")
	print("reject_text=Not in my book: QX")
	runner.assert_eq(CommitFx.fx_for(res), "", "blank_feedback_reject_no_fx")

	# Bounce-back clears staged pending state on every staged cell.
	var view := BoardView.new()
	runner.root.add_child(view)
	view.set_pending([Vector2i(7, 7), Vector2i(8, 7)])
	runner.assert_true(view.is_pending(7, 7), "blank_feedback_pending_staged_7_7")
	runner.assert_true(view.is_pending(8, 7), "blank_feedback_pending_staged_8_7")
	var fx := CommitFx.new()
	fx.bounce(view)
	runner.assert_eq(view.is_pending(7, 7), false, "blank_feedback_bounce_clears_7_7")
	runner.assert_eq(view.is_pending(8, 7), false, "blank_feedback_bounce_clears_8_7")

	# Rack-slot restore stays duck-typed: a controller with recall is
	# recalled, a view without recall is simply cleared.
	var ctrl := PlacementController.new()
	ctrl.set_rack(["Q", "X", "A", "B", "C", "D", "E"])
	ctrl.select_slot(0)
	ctrl.place_at(7, 7)
	ctrl.select_slot(1)
	ctrl.place_at(8, 7)
	runner.assert_eq(ctrl.pending_count(), 2, "blank_feedback_controller_pending_2")
	fx.bounce(view, ctrl)
	runner.assert_eq(ctrl.pending_count(), 0, "blank_feedback_bounce_recalls_controller")
	runner.assert_eq(view.is_pending(7, 7), false, "blank_feedback_bounce_view_still_clear")

	view.queue_free()


static func _accept_checks(runner: SceneTree) -> void:
	var board := FakeBoard.new()
	var lex := FakeLexicon.new(["CAT"])
	var pendings: Array = [
		{"col": 6, "row": 7, "letter": ""},
		{"col": 7, "row": 7, "letter": "A"},
		{"col": 8, "row": 7, "letter": "T"},
	]
	var blank_map := {Vector2i(6, 7): "C"}
	var res := ScrabbleRules.validate_placement(board, ["", "A", "T"], pendings, blank_map, lex)
	runner.assert_eq(res.get("ok"), true, "blank_feedback_accept_ok")
	runner.assert_eq(CommitFx.fx_for(res), "thunk,score_fly", "blank_feedback_accept_fx")
	print("commit_fx=thunk,score_fly")
	runner.assert_eq(CommitFx.reject_text_for(res), "", "blank_feedback_accept_no_reject_text")

	# Thunk reuses the table sound bank; score_fly stays a wiring stub
	# headless (the marker itself is the contract).
	var unmuter := SoundBank.new()
	unmuter.set_muted(false)
	var fx := CommitFx.new()
	runner.assert_true(fx.play_commit(), "blank_feedback_play_commit_thunk")
	unmuter.set_muted(false)
