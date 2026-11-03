# Wordtable headless test runner (walking skeleton).
# Run with: godot --headless --path . -s tests/test_runner.gd
# Prints `RESULT: PASS` (or `RESULT: FAIL`) and exits 0 (or 1) so CI can gate.
extends SceneTree

var passed := 0
var failed := 0


func _initialize() -> void:
	var suite := _get_suite_filter()
	if suite == "bag":
		if call("test_bag_suite") != true:
			failed += 1
			push_error("FAIL test_bag_suite: did not finish (runtime error?)")
	elif suite == "board":
		if call("test_board_suite") != true:
			failed += 1
			push_error("FAIL test_board_suite: did not finish (runtime error?)")
	elif suite == "board_scene":
		if call("test_board_scene_suite") != true:
			failed += 1
			push_error("FAIL test_board_scene_suite: did not finish (runtime error?)")
	elif suite == "theme":
		if call("test_theme_suite") != true:
			failed += 1
			push_error("FAIL test_theme_suite: did not finish (runtime error?)")
	elif suite == "rules":
		if call("test_rules_suite") != true:
			failed += 1
			push_error("FAIL test_rules_suite: did not finish (runtime error?)")
	elif suite == "game_state":
		if call("test_game_state_suite") != true:
			failed += 1
			push_error("FAIL test_game_state_suite: did not finish (runtime error?)")
	elif suite == "facade":
		if call("test_facade_suite") != true:
			failed += 1
			push_error("FAIL test_facade_suite: did not finish (runtime error?)")
	elif suite == "strip_chat":
		if call("test_strip_chat_suite") != true:
			failed += 1
			push_error("FAIL test_strip_chat_suite: did not finish (runtime error?)")
	elif suite == "dictionary":
		for t: String in [
			"test_dictionary_load",
			"test_dictionary_lookup",
			"test_dictionary_pluggable_path",
		]:
			if call(t) != true:
				failed += 1
				push_error("FAIL %s: did not finish (runtime error?)" % t)
	else:
		for t: String in [
			"test_engine_version",
			"test_project_files",
			"test_server_default_port",
			"test_ping_match",
			"test_ping_reject",
			"test_bag_suite",
			"test_board_suite",
			"test_board_scene_suite",
			"test_theme_suite",
			"test_dictionary_load",
			"test_dictionary_lookup",
			"test_dictionary_pluggable_path",
			"test_rules_suite",
			"test_game_state_suite",
			"test_facade_suite",
			"test_strip_chat_suite",
		]:
			if call(t) != true:
				failed += 1
				push_error("FAIL %s: did not finish (runtime error?)" % t)
	if failed > 0:
		print("RESULT: FAIL")
	else:
		print("RESULT: PASS")
	print("Results: %d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func assert_eq(actual, expected, label: String) -> void:
	if actual == expected:
		passed += 1
	else:
		failed += 1
		push_error("FAIL %s: expected %s, got %s" % [label, expected, actual])


func assert_true(value: bool, label: String) -> void:
	assert_eq(value, true, label)


func test_engine_version() -> bool:
	var info := Engine.get_version_info()
	assert_eq(int(info.get("major", -1)), 4, "engine_major_is_4")
	assert_eq(int(info.get("minor", -1)), 7, "engine_minor_is_7")
	assert_true(str(info.get("string", "")).find("4.7") != -1, "engine_version_string_contains_4.7")
	return true


func test_project_files() -> bool:
	assert_true(FileAccess.file_exists("res://project.godot"), "project.godot_exists")
	assert_true(FileAccess.file_exists("res://icon.svg"), "icon.svg_exists")
	return true


func test_server_default_port() -> bool:
	var server_script: GDScript = load("res://scripts/server/server.gd")
	assert_eq(server_script.DEFAULT_PORT, 9080, "server_default_port_is_9080")
	return true


func test_ping_match() -> bool:
	var server_script: GDScript = load("res://scripts/server/server.gd")
	assert_true(server_script.is_ping_text("ping"), "ping_matches_lower")
	assert_true(server_script.is_ping_text("PING"), "ping_matches_upper")
	assert_true(server_script.is_ping_text("  Ping  "), "ping_matches_padded_mixed_case")
	return true


func test_ping_reject() -> bool:
	var server_script: GDScript = load("res://scripts/server/server.gd")
	assert_eq(server_script.is_ping_text("pong"), false, "pong_rejected")
	assert_eq(server_script.is_ping_text(""), false, "empty_rejected")
	assert_eq(server_script.is_ping_text("pingx"), false, "pingx_rejected")
	assert_eq(server_script.is_ping_text("{ping}"), false, "envelope_rejected")
	return true


func _get_suite_filter() -> String:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	args.append_array(OS.get_cmdline_args())
	for i: int in range(args.size()):
		var arg: String = args[i]
		if arg.begins_with("--suite="):
			return arg.get_slice("=", 1).strip_edges().to_lower()
		if arg == "--suite" and i + 1 < args.size():
			return args[i + 1].strip_edges().to_lower()
		if arg == "bag":
			return "bag"
		if arg == "board":
			return "board"
		if arg == "dictionary":
			return "dictionary"
		if arg == "rules":
			return "rules"
		if arg == "game_state":
			return "game_state"
		if arg == "facade":
			return "facade"
		if arg == "strip_chat":
			return "strip_chat"
	return ""


func test_dictionary_load() -> bool:
	var dict := WordDictionary.new()
	var start_ms: int = Time.get_ticks_msec()
	var count: int = dict.load_from_path(WordDictionary.DEFAULT_PATH)
	var elapsed_ms: int = Time.get_ticks_msec() - start_ms
	print("dict_count=%d" % count)
	print("dict_load_ms=%d" % elapsed_ms)
	assert_true(FileAccess.file_exists(WordDictionary.DEFAULT_PATH), "dictionary_file_exists")
	assert_true(FileAccess.file_exists("res://dictionaries/LICENSE-credit.md"), "dictionary_credit_exists")
	var credit := FileAccess.open("res://dictionaries/LICENSE-credit.md", FileAccess.READ)
	if credit == null:
		assert_true(false, "dictionary_credit_readable")
	else:
		var text: String = credit.get_as_text()
		assert_true(text.find("SOWPODS") != -1, "dictionary_credit_names_sowpods")
	assert_true(count >= 200000, "dictionary_count_ge_200000")
	assert_eq(dict.word_count(), count, "dictionary_word_count_matches")
	assert_true(elapsed_ms < 3000, "dictionary_load_under_3s")
	return true


func test_dictionary_lookup() -> bool:
	var dict := WordDictionary.new()
	dict.load_from_path(WordDictionary.DEFAULT_PATH)
	assert_true(dict.is_word("HELLO"), "dictionary_hit_upper")
	assert_true(dict.is_word("hello"), "dictionary_hit_lower")
	assert_true(dict.is_word("  HeLLo  "), "dictionary_hit_padded_mixed_case")
	assert_eq(dict.is_word("ZZZZZZZZ"), false, "dictionary_miss_nonsense")
	assert_eq(dict.is_word(""), false, "dictionary_miss_empty")
	assert_eq(dict.is_word("   "), false, "dictionary_miss_blank")
	return true


func test_dictionary_pluggable_path() -> bool:
	var tmp_path := "user://dict_pluggable_test.txt"
	var out := FileAccess.open(tmp_path, FileAccess.WRITE)
	if out == null:
		assert_true(false, "dictionary_tmp_writable")
		return true
	out.store_string("Apple\nBANANA\n")
	out.close()
	var dict := WordDictionary.new()
	var count: int = dict.load_from_path(tmp_path)
	assert_eq(count, 2, "dictionary_pluggable_count_2")
	assert_eq(dict.word_count(), 2, "dictionary_pluggable_word_count_2")
	assert_true(dict.is_word("apple"), "dictionary_pluggable_hit_lower")
	assert_true(dict.is_word("BANANA"), "dictionary_pluggable_hit_upper")
	assert_eq(dict.is_word("CHERRY"), false, "dictionary_pluggable_miss")
	var remove_err: Error = DirAccess.remove_absolute(tmp_path)
	assert_eq(remove_err, OK, "dictionary_pluggable_cleanup_ok")
	assert_eq(FileAccess.file_exists(tmp_path), false, "dictionary_pluggable_tmp_removed")
	return true


func test_bag_suite() -> bool:
	var bag_tests: GDScript = load("res://tests/test_bag.gd")
	bag_tests.run_all(self)
	return true


func test_board_suite() -> bool:
	var board_tests: GDScript = load("res://tests/test_board.gd")
	board_tests.run_all(self)
	return true


func test_board_scene_suite() -> bool:
	var board_scene_tests: GDScript = load("res://tests/test_board_scene.gd")
	board_scene_tests.run_all(self)
	return true


func test_theme_suite() -> bool:
	var theme_tests: GDScript = load("res://tests/test_theme.gd")
	theme_tests.run_all(self)
	return true


func test_rules_suite() -> bool:
	var rules_tests: GDScript = load("res://tests/test_rules.gd")
	rules_tests.run_all(self)
	return true


func test_game_state_suite() -> bool:
	var game_state_tests: GDScript = load("res://tests/test_game_state.gd")
	game_state_tests.run_all(self)
	return true


func test_facade_suite() -> bool:
	var facade_tests: GDScript = load("res://tests/test_facade.gd")
	facade_tests.run_all(self)
	return true


func test_strip_chat_suite() -> bool:
	var strip_chat_tests: GDScript = load("res://tests/test_strip_chat.gd")
	strip_chat_tests.run_all(self)
	return true
