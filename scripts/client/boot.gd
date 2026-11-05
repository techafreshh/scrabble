# Wordtable boot dispatcher (the Main scene's script).
# Decides at startup whether this instance serves headless, answers a
# `--smoke` lexicon probe, or boots the graphical Start screen:
# - headless (`DisplayServer.get_name() == "headless"`) or dedicated-server
#   builds keep today's server behavior by hosting scripts/server/server.gd
#   as a child (same port resolution and lexicon load, same RPC surface).
# - graphical builds instantiate res://scenes/start.tscn (the StartScreen
#   with create_pressed/join_pressed proven by TestHotseat._scene_checks).
# - `--smoke` (user or engine args) loads WordDictionary.DEFAULT_PATH via
#   res:// (which reads from inside the PCK in an export), prints
#   lexicon_from_pck=true only when count >= SMOKE_MIN_WORDS, prints
#   boot=Start, and quits. Headless-safe and used by desktop smoke runs.
# Run headless via res://tests/test_runner.gd (`--suite export`).
class_name WordBoot
extends Node

const START_SCENE := "res://scenes/start.tscn"
const SETUP_SCENE := "res://scenes/playnow_setup.tscn"
const TABLE_SCENE := "res://scenes/table.tscn"
const RECAP_SCENE := "res://scenes/recap.tscn"
const SERVER_SCRIPT := "res://scripts/server/server.gd"
const SMOKE_MIN_WORDS := 200000


# Pure branch predicate so the headless/dedicated truth table is unit
# testable without a display server.
static func should_serve_headless(is_headless: bool, is_dedicated: bool) -> bool:
	return is_headless or is_dedicated


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	args.append_array(OS.get_cmdline_args())
	if args.has("--smoke"):
		_run_smoke()
		return
	if should_serve_headless(
		DisplayServer.get_name() == "headless",
		OS.has_feature("dedicated_server")
	):
		_serve()
	else:
		_show_start()


# Hosts today's server unchanged as a child node.
func _serve() -> void:
	var server_script: GDScript = load(SERVER_SCRIPT)
	var server: Node = server_script.new()
	server.name = "Server"
	add_child(server)


# Graphical boot lands on the Start screen. The offline path is wired
# here: Start's play_now_pressed shows the seat picker, and the picker's
# play_now_pressed swaps in the offline table. No Net/server calls happen
# anywhere on this path.
func _show_start() -> void:
	var packed := load(START_SCENE) as PackedScene
	if packed == null:
		push_error("WordBoot: cannot load start scene %s" % START_SCENE)
		return
	var start: Node = packed.instantiate()
	start.name = "Start"
	add_child(start)
	if start.has_signal("play_now_pressed"):
		start.connect("play_now_pressed", _on_play_now_requested.bind(start))


# Start -> Setup: replace the Start screen with the offline seat picker,
# pre-filling seat 0 with the nickname already entered on the Start screen.
func _on_play_now_requested(_nickname: String, start: Node) -> void:
	var packed := load(SETUP_SCENE) as PackedScene
	if packed == null:
		push_error("WordBoot: cannot load setup scene %s" % SETUP_SCENE)
		return
	var setup: Node = packed.instantiate()
	setup.name = "PlayNowSetup"
	if setup.has_method("set_seats"):
		setup.call("set_seats", [_nickname, "Player 2"])
	if is_instance_valid(start):
		start.queue_free()
	add_child(setup)
	if setup.has_signal("play_now_pressed"):
		setup.connect("play_now_pressed", _on_setup_play_now.bind(setup))


# Setup -> Table: swap the picker for the offline hot-seat table owned
# directly by HotseatTable.new_hotseat (random live seed, bot flags kept).
func _on_setup_play_now(names: Array, bots: Array, setup: Node) -> void:
	var packed := load(TABLE_SCENE) as PackedScene
	if packed == null:
		push_error("WordBoot: cannot load table scene %s" % TABLE_SCENE)
		return
	var table: Node = packed.instantiate()
	table.name = "HotseatTable"
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	if is_instance_valid(setup):
		setup.queue_free()
	add_child(table)
	if table.has_method("new_hotseat"):
		table.call("new_hotseat", names, rng.randi(), bots)
	if table.has_signal("game_finished"):
		table.connect("game_finished", _on_table_finished.bind(table))


# Table -> Recap overlay: show the podium over the finished table; the
# overlay's rematch_requested resets the same table in place.
func _on_table_finished(_winner: String, table: Node) -> void:
	if not is_instance_valid(table) or not table.has_method("get_game"):
		return
	var packed := load(RECAP_SCENE) as PackedScene
	if packed == null:
		push_error("WordBoot: cannot load recap scene %s" % RECAP_SCENE)
		return
	var recap: Node = packed.instantiate()
	recap.name = "Recap"
	add_child(recap)
	if recap.has_method("set_result") and table.has_method("get_names"):
		var game = table.call("get_game")
		var history: Array = []
		if game != null and game.has_method("history"):
			history = game.call("history")
		recap.call("set_result", table.call("get_names"), table.call("get_scores"), history)
	if recap.has_signal("rematch_requested") and table.has_method("rematch"):
		recap.connect("rematch_requested", _on_recap_rematch.bind(table, recap))


func _on_recap_rematch(table: Node, recap: Node) -> void:
	if is_instance_valid(table) and table.has_method("rematch"):
		table.call("rematch")
	if is_instance_valid(recap):
		recap.queue_free()


# Export smoke probe: the bundled lexicon must load from the PCK.
func _run_smoke() -> void:
	var dict := WordDictionary.new()
	var count: int = dict.load_from_path(WordDictionary.DEFAULT_PATH)
	print("dict_count=%d" % count)
	var ok := count >= SMOKE_MIN_WORDS
	if ok:
		print("lexicon_from_pck=true")
	print("boot=Start")
	get_tree().quit(0 if ok else 1)
