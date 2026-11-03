# Wordtable tile-bag suite (pure logic, no scene deps).
# Run headless via res://tests/test_runner.gd (`--suite bag` or full run).
# Prints the bag_* acceptance markers on every bag run.
class_name TestBag
extends RefCounted


static func run_all(runner: SceneTree) -> void:
	var bag := TileBag.new()
	runner.assert_eq(bag.remaining(), 100, "bag_total_is_100")
	print("bag_count=100")

	var counts: Dictionary = bag.counts_by_letter()
	for row: Array in TileBag.DISTRIBUTION:
		var letter: String = str(row[0])
		var expected_count: int = int(row[1])
		runner.assert_eq(int(counts.get(letter, 0)), expected_count, "bag_count_" + letter)

	runner.assert_eq(bag.blanks_remaining(), 2, "bag_blanks_is_2")
	print("bag_blanks_total=2")

	for row: Array in TileBag.DISTRIBUTION:
		var vletter: String = str(row[0])
		var expected_value: int = int(row[2])
		runner.assert_eq(TileBag.letter_value(vletter), expected_value, "bag_value_" + vletter)
	runner.assert_eq(TileBag.letter_value(""), 0, "bag_blank_value_is_0")

	var fresh := TileBag.new()
	var drawn: Array = fresh.draw(7)
	runner.assert_eq(drawn.size(), 7, "bag_draw_7_size")
	runner.assert_eq(fresh.remaining(), 93, "bag_remaining_after_draw_7")
	print("bag_remaining=93")

	fresh.return_tiles(drawn)
	runner.assert_eq(fresh.remaining(), 100, "bag_return_restores_100")

	var exhaust := TileBag.new()
	var all: Array = exhaust.draw(100)
	runner.assert_eq(all.size(), 100, "bag_draw_all_100")
	runner.assert_eq(exhaust.is_empty(), true, "bag_empty_after_draw_all")
	runner.assert_eq(exhaust.remaining(), 0, "bag_remaining_0_when_empty")
	var over: Array = exhaust.draw(7)
	runner.assert_eq(over.size(), 0, "bag_overdraw_empty_returns_empty")

	var partial := TileBag.new()
	partial.draw(95)
	var rest: Array = partial.draw(10)
	runner.assert_eq(rest.size(), 5, "bag_overdraw_returns_remainder")
	runner.assert_eq(partial.is_empty(), true, "bag_empty_after_overdraw")

	var edge := TileBag.new()
	runner.assert_eq(edge.draw(0).size(), 0, "bag_draw_zero_empty")
	runner.assert_eq(edge.draw(-3).size(), 0, "bag_draw_negative_empty")
	runner.assert_eq(edge.remaining(), 100, "bag_draw_invalid_keeps_100")

	var first := TileBag.with_seed(1234)
	var second := TileBag.with_seed(1234)
	var da: Array = first.draw(7)
	var db: Array = second.draw(7)
	var same: bool = da.size() == db.size()
	if same:
		for i: int in range(da.size()):
			var ta: Dictionary = da[i]
			var tb: Dictionary = db[i]
			if str(ta.get("letter")) != str(tb.get("letter")) or int(ta.get("value")) != int(tb.get("value")) or bool(ta.get("is_blank")) != bool(tb.get("is_blank")):
				same = false
				break
	runner.assert_eq(same, true, "bag_seed_reproducible_1234")
	print("bag_seed_reproducible=true")
