# Wordtable export-preset suite (config + boot + bundled lexicon).
# Run headless via res://tests/test_runner.gd (`--suite export` or full run).
# Proves the install-free distribution contract: export_presets.cfg carries
# the Web/Windows/Linux/macOS presets with single-threaded Web and a *.txt
# PCK include filter, every preset points under build/, the boot dispatcher
# serves headless exactly as today while landing graphical boots on Start,
# and the bundled SOWPODS lexicon loads with count >= 200000.
class_name TestExport
extends RefCounted

const PRESETS_PATH := "res://export_presets.cfg"
const EXPECTED_NAMES := ["Web", "Windows", "Linux", "macOS"]
const MIN_WORDS := 200000


static func run_all(runner: SceneTree) -> void:
	_preset_checks(runner)
	_boot_branch_checks(runner)
	_lexicon_checks(runner)


static func _preset_checks(runner: SceneTree) -> void:
	runner.assert_true(FileAccess.file_exists(PRESETS_PATH), "export_cfg_exists")
	var file := FileAccess.open(PRESETS_PATH, FileAccess.READ)
	if file == null:
		runner.assert_true(false, "export_cfg_readable")
		return
	var text: String = file.get_as_text()
	for preset_name in EXPECTED_NAMES:
		runner.assert_true(
			text.find("name=\"%s\"" % preset_name) != -1,
			"export_preset_%s_present" % preset_name.to_lower()
		)
	runner.assert_true(
		text.find("variant/thread_support=false") != -1,
		"export_web_single_threaded"
	)
	runner.assert_true(
		_thread_support_off_in_web_block(text),
		"export_thread_support_off_in_web_block"
	)
	runner.assert_true(text.find("*.txt") != -1, "export_txt_include_filter")
	runner.assert_true(
		text.find("single_threaded=true") != -1,
		"export_single_threaded_marker"
	)
	runner.assert_true(
		FileAccess.file_exists("res://icon.svg"),
		"export_icon_exists"
	)
	var paths := _preset_export_paths(text)
	runner.assert_eq(paths.size(), 4, "export_four_export_paths")
	for path in paths:
		runner.assert_true(path.begins_with("build/"), "export_path_under_build")


# The Web block runs from its [preset.N] header to the next [preset.M]
# header; thread_support=false must live inside it, not in another preset.
static func _thread_support_off_in_web_block(text: String) -> bool:
	return _preset_block(text, "Web").find("variant/thread_support=false") != -1


# The full block for a preset: its [preset.N] header through the next
# [preset.M] header ([preset.N.options] belongs to the same preset).
static func _preset_block(text: String, preset_name: String) -> String:
	var name_at := text.find("name=\"%s\"" % preset_name)
	if name_at == -1:
		return ""
	var header_at := text.rfind("[preset.", name_at)
	var block_start := header_at if header_at != -1 else 0
	var cursor := name_at
	while cursor < text.length():
		var next_at := text.find("[preset.", cursor)
		if next_at == -1:
			return text.substr(block_start)
		var header_end := text.find("]", next_at)
		var header := text.substr(next_at, header_end - next_at) if header_end != -1 else ""
		if header.find("options") == -1:
			return text.substr(block_start, next_at - block_start)
		cursor = next_at + 1
	return text.substr(block_start)


# One non-empty export_path per preset block ([preset.N], not .options).
static func _preset_export_paths(text: String) -> Array:
	var paths: Array = []
	var cursor := 0
	while true:
		var key_at := text.find("export_path=", cursor)
		if key_at == -1:
			break
		var quote_at := text.find("\"", key_at)
		if quote_at == -1:
			break
		var end_at := text.find("\"", quote_at + 1)
		if end_at == -1:
			break
		var value := text.substr(quote_at + 1, end_at - quote_at - 1).strip_edges()
		if value != "":
			paths.append(value)
		cursor = end_at + 1
	return paths


static func _boot_branch_checks(runner: SceneTree) -> void:
	runner.assert_eq(
		WordBoot.should_serve_headless(true, false), true, "export_boot_headless_serves"
	)
	runner.assert_eq(
		WordBoot.should_serve_headless(false, true), true, "export_boot_dedicated_serves"
	)
	runner.assert_eq(
		WordBoot.should_serve_headless(false, false), false, "export_boot_graphical_starts"
	)
	runner.assert_eq(
		WordBoot.should_serve_headless(true, true), true, "export_boot_both_serves"
	)
	runner.assert_true(
		ResourceLoader.exists("res://scenes/start.tscn"), "export_start_scene_exists"
	)
	var packed := load("res://scenes/start.tscn") as PackedScene
	runner.assert_true(packed != null, "export_start_scene_loads")
	runner.assert_true(
		WordBoot.START_SCENE == "res://scenes/start.tscn", "export_boot_start_path"
	)


static func _lexicon_checks(runner: SceneTree) -> void:
	var dict := WordDictionary.new()
	var start_ms: int = Time.get_ticks_msec()
	var count: int = dict.load_from_path(WordDictionary.DEFAULT_PATH)
	var elapsed_ms: int = Time.get_ticks_msec() - start_ms
	print("dict_count=%d" % count)
	print("dict_load_ms=%d" % elapsed_ms)
	runner.assert_true(count >= MIN_WORDS, "export_lexicon_count_ge_200000")
	runner.assert_true(dict.is_word("HELLO"), "export_lexicon_hit")
	runner.assert_eq(dict.is_word("ZZZZZZZZ"), false, "export_lexicon_miss")
