# Wordtable SOWPODS dictionary loader (pure logic, no scene deps).
# Reads a one-word-per-line UTF-8 file into an in-memory hash set and answers
# case-insensitive legality checks. Default path is the bundled lexicon.
# Run headless via res://tests/test_runner.gd (`--suite dictionary` or full run).
class_name WordDictionary
extends RefCounted

const DEFAULT_PATH := "res://dictionaries/sowpods.txt"

var _words: Dictionary = {}


func load_from_path(path: String) -> int:
	_words.clear()
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("WordDictionary: cannot open %s" % path)
		return 0
	while not file.eof_reached():
		var line: String = file.get_line().strip_edges().to_upper()
		if line == "":
			continue
		if not _is_alpha(line):
			continue
		_words[line] = true
	return _words.size()


func is_word(raw: String) -> bool:
	var word: String = raw.strip_edges().to_upper()
	if word == "":
		return false
	return _words.has(word)


func word_count() -> int:
	return _words.size()


func clear() -> void:
	_words.clear()


func _is_alpha(word: String) -> bool:
	for i: int in range(word.length()):
		var code: int = word.unicode_at(i)
		if code < 65 or code > 90:
			return false
	return true
