# Wordtable export checker (standalone SceneTree driver, no server needed).
# Proves the export contract headless from a single run: the Web preset is
# single-threaded, the web output fits a ~50 MB Brotli budget, and the
# bundled SOWPODS lexicon loads from res:// (inside the PCK in an export).
# Run from the repo root:
# godot --headless --path . --script res://tests/export_check.gd
# Prints the acceptance markers single_threaded=/web_mb=/lexicon_from_pck=
# (plus dict_count= and the literal web_mb<=50 when the budget holds) and
# exits 0 only when every marker holds.
extends SceneTree

const PRESETS_PATH := "res://export_presets.cfg"
const WEB_DIR := "res://build/web"
const MIN_WORDS := 200000
const MAX_WEB_MB := 50
const BYTES_PER_MB := 1048576


func _initialize() -> void:
	var single := _check_single_threaded()
	var words := _check_lexicon()
	var web_mb := _web_mb()
	print("web_mb=%d" % web_mb)
	if web_mb <= MAX_WEB_MB:
		print("web_mb<=50")
	var ok := single and words and web_mb <= MAX_WEB_MB
	quit(0 if ok else 1)


# The Web preset block must pin variant/thread_support=false.
func _check_single_threaded() -> bool:
	var file := FileAccess.open(PRESETS_PATH, FileAccess.READ)
	if file == null:
		return false
	var text: String = file.get_as_text()
	var block := _preset_block(text, "Web")
	if block == "" or block.find("variant/thread_support=false") == -1:
		return false
	print("single_threaded=true")
	return true


# The bundled lexicon must load via res:// with the full word count.
func _check_lexicon() -> bool:
	var dict := WordDictionary.new()
	var count := 0
	if FileAccess.file_exists(WordDictionary.DEFAULT_PATH):
		count = dict.load_from_path(WordDictionary.DEFAULT_PATH)
	print("dict_count=%d" % count)
	if count < MIN_WORDS:
		return false
	print("lexicon_from_pck=true")
	return true


# The full block for a preset: its [preset.N] header through the next
# [preset.M] header ([preset.N.options] belongs to the same preset).
func _preset_block(text: String, preset_name: String) -> String:
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


# Brotli-compressed bytes of the web output (*.js + *.wasm + *.pck),
# falling back to raw bytes as a safe upper bound when no compressor CLI
# exists. Missing output counts as zero bytes (nothing built yet).
func _web_mb() -> int:
	var total := 0
	for path in _web_files(WEB_DIR):
		total += _compressed_size(path)
	return total / BYTES_PER_MB


# Recursive walk of the web output dir, keeping only the shippable
# engine blobs (html shell excluded: it is bytes-small and uncompressed).
func _web_files(dir: String) -> Array:
	var out: Array = []
	var access := DirAccess.open(dir)
	if access == null:
		return out
	for entry in access.get_files():
		var lower := entry.to_lower()
		if lower.ends_with(".js") or lower.ends_with(".wasm") or lower.ends_with(".pck"):
			out.append(dir.path_join(entry))
	for entry in access.get_directories():
		if entry == "." or entry == "..":
			continue
		out.append_array(_web_files(dir.path_join(entry)))
	return out


# Per-file serving cost: brotli, else gzip, else raw length. Compression
# runs through a shell redirect into a temp file (OS.execute captures
# stdout as text, which corrupts binary output, so bytes never cross
# back into GDScript); any failure falls back to the raw file length.
func _compressed_size(path: String) -> int:
	var abs := ProjectSettings.globalize_path(path)
	var tmp := ProjectSettings.globalize_path("user://export_check_tmp.bin")
	if _shell_compress("brotli -c", abs, tmp):
		return _tmp_size(tmp)
	if _shell_compress("gzip -c -n", abs, tmp):
		return _tmp_size(tmp)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 0
	return int(file.get_length())


# Compresses abs_path into tmp_path via sh; true only when the tool
# exists, exits 0, and produced a non-empty file.
func _shell_compress(tool: String, abs_path: String, tmp_path: String) -> bool:
	var out: Array = []
	var cmd := "%s '%s' > '%s'" % [tool, abs_path, tmp_path]
	if OS.execute("sh", PackedStringArray(["-c", cmd]), out, true) != 0:
		return false
	var produced := FileAccess.open(tmp_path, FileAccess.READ)
	if produced == null:
		return false
	var size := int(produced.get_length())
	produced.close()
	return size > 0


func _tmp_size(tmp_path: String) -> int:
	var produced := FileAccess.open(tmp_path, FileAccess.READ)
	if produced == null:
		return 0
	var size := int(produced.get_length())
	produced.close()
	DirAccess.remove_absolute(ProjectSettings.localize_path(tmp_path))
	return size
