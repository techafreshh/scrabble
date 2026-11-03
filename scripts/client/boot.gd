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


# Graphical boot lands on the Start screen.
func _show_start() -> void:
	var packed := load(START_SCENE) as PackedScene
	if packed == null:
		push_error("WordBoot: cannot load start scene %s" % START_SCENE)
		return
	var start: Node = packed.instantiate()
	start.name = "Start"
	add_child(start)


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
