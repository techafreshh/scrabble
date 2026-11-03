# Placement suite: tap-tap, drag-drop, recall/shuffle, live provisional.
# Run headless via res://tests/test_runner.gd (`--suite placement` or full run).
# Prints the placement acceptance markers on every placement run:
# rack_slots=7, provisional=+8, recall_ok=true.
class_name TestPlacement
extends RefCounted

const RACK_PATH := "res://scenes/table/rack.tscn"


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


# Minimal board double: occupancy only (duck-typed via tile_at).
class FakeBoard extends RefCounted:
	var _cells: Dictionary = {}

	func set_tile(col: int, row: int, letter: String) -> void:
		_cells[Vector2i(col, row)] = letter.strip_edges().to_upper()

	func tile_at(col: int, row: int) -> String:
		return str(_cells.get(Vector2i(col, row), ""))


static func run_all(runner: SceneTree) -> void:
	_controller_checks(runner)
	_hello_fixture_checks(runner)
	_recall_shuffle_checks(runner)
	_scene_checks(runner)
	_drag_checks(runner)


static func _controller_checks(runner: SceneTree) -> void:
	var ctrl := PlacementController.new()
	ctrl.set_rack(["H", "E", "L", "L", "O", "A", "B"])
	runner.assert_eq(ctrl.slot_count(), 7, "placement_slot_count_7")
	runner.assert_eq(ctrl.pending_count(), 0, "placement_starts_empty")
	runner.assert_eq(ctrl.selected_slot(), -1, "placement_starts_unselected")

	# Empty pendings render the provisional label as +0.
	var empty_board := ScrabbleBoard.new()
	var empty_lex := FakeLexicon.new(["HELLO"])
	runner.assert_eq(ctrl.provisional_label(empty_board, empty_lex), "+0", "placement_empty_label_plus_zero")

	# Tap-tap: select slot 0 (H) and place at (6, 7).
	runner.assert_true(ctrl.select_slot(0), "placement_select_slot0_ok")
	runner.assert_eq(ctrl.selected_slot(), 0, "placement_selected_slot0")
	runner.assert_true(ctrl.can_place_at(6, 7), "placement_can_place_6_7")
	runner.assert_true(ctrl.place_at(6, 7), "placement_place_h_6_7")
	runner.assert_eq(ctrl.pending_count(), 1, "placement_pending_1")
	runner.assert_eq(ctrl.selected_slot(), -1, "placement_place_clears_selection")

	# Double-place on the same cell is rejected; OOB is rejected.
	runner.assert_eq(ctrl.can_place_at(6, 7), false, "placement_rejects_double_place")
	runner.assert_true(ctrl.select_slot(1), "placement_select_slot1_ok")
	runner.assert_eq(ctrl.can_place_at(6, 7), false, "placement_still_blocked_after_select")
	runner.assert_eq(ctrl.place_at(6, 7), false, "placement_place_blocked_cell_false")
	runner.assert_eq(ctrl.can_place_at(-1, 0), false, "placement_rejects_oob_col")
	runner.assert_eq(ctrl.can_place_at(15, 15), false, "placement_rejects_oob_corner")
	runner.assert_eq(ctrl.select_slot(99), false, "placement_select_oob_false")

	# Two diagonal pendings yield the NOT_IN_LINE reason label.
	var diag := PlacementController.new()
	diag.set_rack(["A", "B", "C", "D", "E", "F", "G"])
	diag.select_slot(0)
	diag.place_at(5, 5)
	diag.select_slot(1)
	diag.place_at(6, 6)
	var diag_res := diag.provisional(FakeBoard.new(), FakeLexicon.new(["AB"]))
	runner.assert_eq(diag_res.get("ok"), false, "placement_diag_not_ok")
	runner.assert_eq(str(diag_res.get("reason", "")), "NOT_IN_LINE", "placement_diag_not_in_line")
	runner.assert_eq(diag.provisional_label(FakeBoard.new(), FakeLexicon.new(["AB"])), "NOT_IN_LINE", "placement_diag_label_reason")


static func _hello_fixture_checks(runner: SceneTree) -> void:
	# HELLO fixture: committed E at center (7,7); pendings form HELLO across.
	var board := ScrabbleBoard.new()
	board.place_tile(7, 7, "E")
	var lex := FakeLexicon.new(["HELLO"])
	var ctrl := PlacementController.new()
	ctrl.set_rack(["H", "L", "L", "O", "A", "B", "C"])
	ctrl.select_slot(0)
	ctrl.place_at(6, 7)
	ctrl.select_slot(1)
	ctrl.place_at(8, 7)
	ctrl.select_slot(2)
	ctrl.place_at(9, 7)
	ctrl.select_slot(3)
	ctrl.place_at(10, 7)
	runner.assert_eq(ctrl.pending_count(), 4, "placement_hello_pending_4")
	var res := ctrl.provisional(board, lex)
	runner.assert_eq(res.get("ok"), true, "placement_hello_ok")
	runner.assert_eq(int(res.get("total", -1)), 8, "placement_hello_total_8")
	runner.assert_eq(ctrl.provisional_label(board, lex), "+8", "placement_hello_label_plus_8")
	print("provisional=+8")


static func _recall_shuffle_checks(runner: SceneTree) -> void:
	var board := ScrabbleBoard.new()
	board.place_tile(7, 7, "E")
	var lex := FakeLexicon.new(["HELLO"])
	var ctrl := PlacementController.new()
	ctrl.set_rack(["H", "L", "L", "O", "A", "B", "C"])
	ctrl.select_slot(0)
	ctrl.place_at(6, 7)
	ctrl.select_slot(1)
	ctrl.place_at(8, 7)
	ctrl.select_slot(2)
	ctrl.place_at(9, 7)
	ctrl.select_slot(3)
	ctrl.place_at(10, 7)
	runner.assert_eq(ctrl.pending_count(), 4, "placement_recall_setup_4")
	var recalled := ctrl.recall()
	runner.assert_eq(recalled, 4, "placement_recall_count_4")
	runner.assert_eq(ctrl.pending_count(), 0, "placement_recall_clears_pending")
	runner.assert_eq(ctrl.provisional_label(board, lex), "+0", "placement_recall_label_plus_zero")
	var faces: Array = ctrl.get_faces()
	var letters: Array = []
	for f in faces:
		letters.append(str((f as Dictionary).get("letter", "")))
	letters.sort()
	var expect := ["A", "B", "C", "H", "L", "L", "O"]
	expect.sort()
	runner.assert_eq(letters, expect, "placement_recall_restores_faces")
	print("recall_ok=true")

	# Shuffle preserves the multiset while reordering unplaced tiles in place.
	var sh := PlacementController.new()
	sh.set_rack(["A", "B", "C", "D", "E", "F", "G"])
	var before: Array = []
	for f in sh.get_faces():
		before.append(str((f as Dictionary).get("letter", "")))
	sh.shuffle()
	var after: Array = []
	for f in sh.get_faces():
		after.append(str((f as Dictionary).get("letter", "")))
	var sb: Array = before.duplicate()
	sb.sort()
	var sa: Array = after.duplicate()
	sa.sort()
	runner.assert_eq(sb, sa, "placement_shuffle_preserves_multiset")
	runner.assert_eq(sh.pending_count(), 0, "placement_shuffle_no_pending")

	# Shuffle leaves pending tiles on the board (pending slots stay empty).
	var sh2 := PlacementController.new()
	sh2.set_rack(["A", "B", "C", "D", "E", "F", "G"])
	sh2.select_slot(0)
	sh2.place_at(6, 7)
	sh2.shuffle()
	runner.assert_eq(sh2.pending_count(), 1, "placement_shuffle_keeps_pending")
	runner.assert_eq(sh2.slot_letter(0), "", "placement_shuffle_pending_slot_stays_empty")


static func _scene_checks(runner: SceneTree) -> void:
	runner.assert_true(ResourceLoader.exists(RACK_PATH), "placement_rack_file_exists")
	var packed := load(RACK_PATH) as PackedScene
	runner.assert_true(packed != null, "placement_rack_loads_as_packed_scene")
	if packed == null:
		return
	var rack: RackView = packed.instantiate() as RackView
	runner.assert_true(rack != null, "placement_rack_instantiates_rack_view")
	if rack == null:
		return
	runner.assert_true(rack.has_signal("tile_chosen"), "placement_rack_has_tile_chosen_signal")
	runner.root.add_child(rack)
	runner.assert_eq(rack.get_slot_count(), 7, "placement_rack_slot_count_7")
	print("rack_slots=7")
	runner.assert_eq(RackView.RACK_SIZE, 7, "placement_rack_size_const_7")

	# Provisional label reads +8 on the HELLO fixture via the shared validator.
	var board := ScrabbleBoard.new()
	board.place_tile(7, 7, "E")
	var lex := FakeLexicon.new(["HELLO"])
	var ctrl := PlacementController.new()
	ctrl.set_rack(["H", "L", "L", "O", "A", "B", "C"])
	ctrl.select_slot(0)
	ctrl.place_at(6, 7)
	ctrl.select_slot(1)
	ctrl.place_at(8, 7)
	ctrl.select_slot(2)
	ctrl.place_at(9, 7)
	ctrl.select_slot(3)
	ctrl.place_at(10, 7)
	rack.bind_controller(ctrl)
	var label_text := rack.refresh_provisional(board, lex, ctrl)
	runner.assert_eq(label_text, "+8", "placement_rack_label_plus_8")
	runner.assert_eq(rack.get_provisional_label(), "+8", "placement_rack_node_reads_plus_8")
	var prov_node := (rack as Node).get_node_or_null("%Provisional") as Label
	if prov_node == null:
		prov_node = (rack as Node).get_node_or_null("Provisional") as Label
	runner.assert_true(prov_node != null, "placement_provisional_node_exists")

	rack.queue_free()


static func _drag_checks(runner: SceneTree) -> void:
	var tile := RackTile.new()
	tile.slot_idx = 2
	tile.set_face("L", false)
	runner.assert_eq(tile.text, "L", "placement_tile_face_shown")
	tile.set_face("", true)
	runner.assert_eq(tile.text, "□", "placement_blank_shows_square")
	tile.set_face("H", false)
	var payload: Dictionary = tile._get_drag_data(Vector2.ZERO)
	runner.assert_eq(int(payload.get("slot", -1)), 2, "placement_drag_payload_slot")
	runner.assert_eq(str(payload.get("letter", "")), "H", "placement_drag_payload_letter")

	var cell := BoardCell.new()
	cell.col = 6
	cell.row = 7
	runner.assert_true(cell._can_drop_data(Vector2.ZERO, payload), "placement_cell_accepts_tile_payload")
	runner.assert_eq(cell._can_drop_data(Vector2.ZERO, {"nope": 1}), false, "placement_cell_rejects_junk")
	var oob := BoardCell.new()
	oob.col = 15
	oob.row = 15
	runner.assert_eq(oob._can_drop_data(Vector2.ZERO, payload), false, "placement_cell_rejects_oob")

	tile.queue_free()
	cell.queue_free()
	oob.queue_free()
