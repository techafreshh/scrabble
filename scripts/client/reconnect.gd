# Wordtable reconnect overlay (pure logic plus a thin Control shell).
# Owns the visible `Reconnecting…` state, the deterministic backoff ladder,
# the persisted `{code, token}` session, and the before/after snapshot
# comparison behind `resync_identical=true`. NetClient binds itself via
# bind_net so the Retry button sends an immediate rejoin; the overlay never
# touches the socket itself.
#
# Session persistence mirrors scripts/client/sound_bank.gd: a ConfigFile at
# user://wordtable_session.cfg, section [session], keys code/token — plain
# local storage headless CI can exercise like the mute toggle.
#
# Run headless via res://tests/test_runner.gd (`--suite reconnect`).
class_name ReconnectOverlay
extends Control

const SESSION_PATH := "user://wordtable_session.cfg"
const SESSION_SECTION := "session"
const BASE_DELAY_MS := 250
const MAX_DELAY_MS := 4000

var _net = null
var _status_label: Label = null
var _retry_button: Button = null


func _ready() -> void:
	visible = false
	_status_label = get_node_or_null("%StatusLabel") as Label
	_retry_button = get_node_or_null("%RetryButton") as Button
	if _retry_button != null and not _retry_button.pressed.is_connected(_on_retry_pressed):
		_retry_button.pressed.connect(_on_retry_pressed)


# The bound client for the Retry button's immediate rejoin (duck-typed so
# the overlay also parses and runs with no client attached).
func bind_net(net) -> void:
	_net = net


# Deterministic exponential backoff: 250·2^(n-1) ms capped at 4000 ms
# (attempt starts at 1; attempts below 1 clamp to the first step).
static func compute_delay_ms(attempt: int) -> int:
	var n := maxi(attempt, 1)
	return mini(BASE_DELAY_MS << (n - 1), MAX_DELAY_MS)


# Persists the room identity every ok reply hands us (mirrors
# SoundBank.save_state: cfg.load before set_value so unrelated keys in the
# same file survive).
static func save_session(code: String, token: String, path := SESSION_PATH) -> void:
	var cfg := ConfigFile.new()
	cfg.load(path)
	cfg.set_value(SESSION_SECTION, "code", code)
	cfg.set_value(SESSION_SECTION, "token", token)
	cfg.save(path)


static func load_session(path := SESSION_PATH) -> Dictionary:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return {"code": "", "token": ""}
	return {
		"code": str(cfg.get_value(SESSION_SECTION, "code", "")),
		"token": str(cfg.get_value(SESSION_SECTION, "token", "")),
	}


static func clear_session(path := SESSION_PATH) -> void:
	var cfg := ConfigFile.new()
	cfg.load(path)
	cfg.erase_section(SESSION_SECTION)
	cfg.save(path)


func show_overlay(reason := "closed") -> void:
	visible = true
	if _status_label != null:
		_status_label.text = "Reconnecting…"
	print("overlay=Reconnecting")


func hide_overlay() -> void:
	visible = false


func is_showing() -> bool:
	return visible


func _on_retry_pressed() -> void:
	if _net != null and _net.has_method("rejoin_room"):
		_net.call("rejoin_room")


# True only when rack, scores, and board_tiles (order-normalized) all
# match between a pre-drop snapshot and a resync reply.
static func compare_snapshots(before: Dictionary, after: Dictionary) -> bool:
	if (before.get("rack", []) as Array) != (after.get("rack", []) as Array):
		return false
	if (before.get("scores", []) as Array) != (after.get("scores", []) as Array):
		return false
	return _norm_tiles(before.get("board_tiles", [])) == _norm_tiles(after.get("board_tiles", []))


static func _norm_tiles(raw) -> Array:
	var out: Array = []
	if raw is Array:
		for t in (raw as Array):
			if t is Dictionary:
				out.append({
					"square": str((t as Dictionary).get("square", "")),
					"letter": str((t as Dictionary).get("letter", "")),
				})
	out.sort_custom(func(a, b) -> bool: return str(a.get("square", "")) < str(b.get("square", "")))
	return out
