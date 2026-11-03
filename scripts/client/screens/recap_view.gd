# Wordtable recap view: podium, final scores, word history, Rematch.
#
# The end-of-game overlay: takes names/scores/history (straight from a
# finished LocalGame), sorts seats into a podium (highest score first),
# lists final scores, and renders one history row per commit in the form
# `<name>: <WORDS> (+<total>)`. The rows are built here in code so the
# count can never drift from the history (the PlayerStrip idiom); the
# verdict helpers are static with zero scene deps (the CommitFx idiom).
# Rematch keeps the same seats and resets to a full bag; requesting one
# emits rematch_requested and prints the `rematch_started=true` marker.
#
# Entry points:
# - RecapView.podium_order(scores) -> Array (static, indices desc).
# - RecapView.format_row(name, words_string, total) -> String (static).
# - set_result(names, scores, history) / clear().
# - get_winner_name()/get_ordered_names()/get_ordered_scores().
# - get_history_row_count()/get_row(i)/get_rows().
# - request_rematch() (emits rematch_requested, prints marker).
#
# No networking: the view only emits rematch_requested for later binding.
#
# Run headless via res://tests/test_runner.gd (suite `hotseat`).
class_name RecapView
extends Control

signal rematch_requested

var _names: Array = []
var _scores: Array = []
var _order: Array = []
var _rows: Array = []
var _built := false


func _ready() -> void:
	_ensure_built()


func _ensure_built() -> void:
	if _built:
		return
	var rematch_btn := get_node_or_null("%RematchButton") as Button
	if rematch_btn == null:
		rematch_btn = get_node_or_null("RematchButton") as Button
	var podium := get_node_or_null("%Podium") as VBoxContainer
	if podium == null:
		podium = get_node_or_null("Podium") as VBoxContainer
	var scores_box := get_node_or_null("%Scores") as VBoxContainer
	if scores_box == null:
		scores_box = get_node_or_null("Scores") as VBoxContainer
	var history_list := get_node_or_null("%HistoryList") as ItemList
	if history_list == null:
		history_list = get_node_or_null("HistoryList") as ItemList
	if rematch_btn == null and podium == null and scores_box == null and history_list == null:
		return
	if rematch_btn != null and not rematch_btn.pressed.is_connected(_on_rematch_button):
		rematch_btn.pressed.connect(_on_rematch_button)
	_built = true
	_refresh_chrome()


# Indices into scores sorted descending; stable on ties (lower seat first).
static func podium_order(scores: Array) -> Array:
	var order: Array = []
	for i: int in range(scores.size()):
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		if int(scores[a]) != int(scores[b]):
			return int(scores[a]) > int(scores[b])
		return a < b
	)
	return order


static func format_row(player_name: String, words_string: String, total: int) -> String:
	return "%s: %s (+%d)" % [player_name, words_string, total]


static func words_string(entry_words: Array) -> String:
	var faces: Array = []
	for w in entry_words:
		if w is Dictionary:
			faces.append(str((w as Dictionary).get("word", "")))
		else:
			faces.append(str(w))
	return ", ".join(faces)


func set_result(names: Array, scores: Array, history: Array) -> void:
	_names = names.duplicate()
	_scores = scores.duplicate()
	_order = podium_order(_scores)
	_rows.clear()
	for entry in history:
		if entry is Dictionary:
			var d := entry as Dictionary
			var seat := int(d.get("player", -1))
			var who := "Player"
			if seat >= 0 and seat < _names.size():
				who = str(_names[seat])
			_rows.append(format_row(who, words_string(d.get("words", [])), int(d.get("total", 0))))
		else:
			_rows.append(str(entry))
	_refresh_chrome()


func clear() -> void:
	_names.clear()
	_scores.clear()
	_order.clear()
	_rows.clear()
	_refresh_chrome()


func get_winner_name() -> String:
	var ordered := get_ordered_names()
	if ordered.is_empty():
		return ""
	return str(ordered[0])


func get_ordered_names() -> Array:
	var out: Array = []
	for idx in _order:
		out.append(str(_names[int(idx)]))
	return out


func get_ordered_scores() -> Array:
	var out: Array = []
	for idx in _order:
		out.append(int(_scores[int(idx)]))
	return out


func get_history_row_count() -> int:
	return _rows.size()


func get_row(i: int) -> String:
	if i < 0 or i >= _rows.size():
		return ""
	return str(_rows[i])


func get_rows() -> Array:
	return _rows.duplicate()


func request_rematch() -> void:
	print("rematch_started=true")
	rematch_requested.emit()


func _on_rematch_button() -> void:
	request_rematch()


# Podium/score/history rows are built here in code so the counts can never
# drift from set_result() (the PlayerStrip idiom).
func _refresh_chrome() -> void:
	var podium := get_node_or_null("%Podium") as VBoxContainer
	if podium == null:
		podium = get_node_or_null("Podium") as VBoxContainer
	if podium != null:
		for child in podium.get_children():
			child.queue_free()
		for place: int in range(_order.size()):
			var idx := int(_order[place])
			var label := Label.new()
			label.name = "Place%d" % place
			label.text = "%d. %s — %d" % [place + 1, str(_names[idx]), int(_scores[idx])]
			podium.add_child(label)
	var scores_box := get_node_or_null("%Scores") as VBoxContainer
	if scores_box == null:
		scores_box = get_node_or_null("Scores") as VBoxContainer
	if scores_box != null:
		for child in scores_box.get_children():
			child.queue_free()
		for i: int in range(_names.size()):
			var row := Label.new()
			row.name = "Score%d" % i
			row.text = "%s: %d" % [str(_names[i]), int(_scores[i])]
			scores_box.add_child(row)
	var history_list := get_node_or_null("%HistoryList") as ItemList
	if history_list == null:
		history_list = get_node_or_null("HistoryList") as ItemList
	if history_list != null:
		history_list.clear()
		for line in _rows:
			history_list.add_item(str(line))
