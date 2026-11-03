# Wordtable headless test runner (walking skeleton).
# Run with: godot --headless --path . -s tests/test_runner.gd
# Prints `RESULT: PASS` (or `RESULT: FAIL`) and exits 0 (or 1) so CI can gate.
extends SceneTree

var passed := 0
var failed := 0


func _initialize() -> void:
	for t: String in [
		"test_engine_version",
		"test_project_files",
		"test_server_default_port",
		"test_ping_match",
		"test_ping_reject",
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
