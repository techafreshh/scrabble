# Wordtable board-scene suite (scene deps, no networking).
# Run headless via res://tests/test_runner.gd (`--suite board_scene` or full run).
# Prints the board_cells / star_cell acceptance markers on every board_scene run.
class_name TestBoardScene
extends RefCounted

const SCENE_PATH := "res://scenes/table/board.tscn"


static func run_all(runner: SceneTree) -> void:
	runner.assert_true(ResourceLoader.exists(SCENE_PATH), "board_scene_file_exists")
	var packed := load(SCENE_PATH) as PackedScene
	runner.assert_true(packed != null, "board_scene_loads_as_packed_scene")
	if packed == null:
		return
	var view: BoardView = packed.instantiate() as BoardView
	runner.assert_true(view != null, "board_scene_instantiates_board_view")
	if view == null:
		return
	runner.assert_true(view.has_signal("cell_pressed"), "board_scene_has_cell_pressed_signal")
	runner.root.add_child(view)

	runner.assert_eq(view.get_cell_count(), 225, "board_scene_cell_count_225")
	print("board_cells=225")

	runner.assert_eq(view.cell_premium(7, 7), "STAR_DW", "board_scene_center_is_star")
	runner.assert_eq(view.star_square(), "H8", "board_scene_star_square_h8")
	print("star_cell=H8")

	var center := view.get_cell(7, 7)
	runner.assert_true(center != null, "board_scene_center_cell_exists")
	if center != null:
		runner.assert_eq(center.text, "★", "board_scene_center_shows_star")
	runner.assert_true(view.get_cell(-1, 0) == null, "board_scene_oob_cell_null")
	runner.assert_true(view.get_cell(15, 15) == null, "board_scene_corner_oob_cell_null")

	for r: int in range(ScrabbleBoard.SIZE):
		for c: int in range(ScrabbleBoard.SIZE):
			runner.assert_eq(
				view.cell_premium(c, r),
				ScrabbleBoard.premium_at(c, r),
				"board_scene_premium_%d_%d" % [c, r]
			)

	var grid := (view as Node).get_node_or_null("%Grid") as GridContainer
	runner.assert_true(grid != null, "board_scene_grid_exists")
	if grid != null:
		runner.assert_eq(grid.columns, 15, "board_scene_grid_columns_15")
		runner.assert_eq(grid.get_child_count(), 225, "board_scene_grid_holds_225_cells")

	var aspect := (view as Node).get_node_or_null("Aspect") as AspectRatioContainer
	runner.assert_true(aspect != null, "board_scene_aspect_exists")
	if aspect != null:
		runner.assert_eq(aspect.ratio, 1.0, "board_scene_aspect_ratio_square")

	var sample := view.get_cell(0, 0)
	runner.assert_true(sample != null, "board_scene_sample_cell_exists")
	if sample != null:
		runner.assert_true(
			sample.custom_minimum_size.x >= 24.0 and sample.custom_minimum_size.y >= 24.0,
			"board_scene_cell_minimum_24px"
		)
		runner.assert_true(
			sample.size_flags_horizontal == Control.SIZE_EXPAND_FILL,
			"board_scene_cell_expands_horizontally"
		)
		runner.assert_true(
			sample.size_flags_vertical == Control.SIZE_EXPAND_FILL,
			"board_scene_cell_expands_vertically"
		)

	runner.assert_true(view.set_tile(7, 7, "H"), "board_scene_set_tile_ok")
	runner.assert_eq(view.get_cell(7, 7).text, "H", "board_scene_tile_face_shown")
	runner.assert_eq(view.set_tile(0, 0, "AB"), false, "board_scene_set_tile_rejects_word")
	runner.assert_eq(view.set_tile(-1, 0, "A"), false, "board_scene_set_tile_rejects_oob")
	view.clear_tile(7, 7)
	runner.assert_eq(view.get_cell(7, 7).text, "★", "board_scene_clear_restores_star")

	view.set_pending([Vector2i(7, 7), Vector2i(7, 8), [8, 8], Vector2i(-1, -1)])
	runner.assert_true(view.is_pending(7, 7), "board_scene_pending_center")
	runner.assert_true(view.is_pending(7, 8), "board_scene_pending_below_center")
	runner.assert_true(view.is_pending(8, 8), "board_scene_pending_array_form")
	runner.assert_eq(view.is_pending(0, 0), false, "board_scene_not_pending_elsewhere")
	view.clear_pending()
	runner.assert_eq(view.is_pending(7, 7), false, "board_scene_pending_cleared")
	runner.assert_eq(view.is_pending(8, 8), false, "board_scene_pending_cleared_all")

	view.set_last_move([Vector2i(7, 7), Vector2i(8, 7)])
	runner.assert_true(view.is_last_move(7, 7), "board_scene_last_move_center")
	runner.assert_true(view.is_last_move(8, 7), "board_scene_last_move_neighbor")
	runner.assert_eq(view.is_last_move(0, 0), false, "board_scene_not_last_move_elsewhere")
	view.clear_last_move()
	runner.assert_eq(view.is_last_move(7, 7), false, "board_scene_last_move_cleared")

	view.queue_free()
