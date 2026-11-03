# Wordtable sound bank: mute state plus WAV lookups (pure logic, no scene deps).
# Owns the persisted mute toggle (ConfigFile at user://wordtable_settings.cfg,
# section [audio], key muted) and resolves the three table sounds
# (thunk/place, fanfare/win, bag/shuffle) to AudioStream resources.
# Never touches AudioServer buses, so headless runs stay deterministic.
# Run headless via res://tests/test_runner.gd (suite `strip_chat`).
class_name SoundBank
extends RefCounted

const SETTINGS_PATH := "user://wordtable_settings.cfg"
const SECTION := "audio"
const KEY := "muted"
const SOUND_NAMES: Array = ["thunk", "fanfare", "bag"]

var muted: bool = false


func _init() -> void:
	load_state()


func set_muted(value: bool) -> void:
	muted = value
	save_state()


func toggle_muted() -> bool:
	set_muted(not muted)
	return muted


func save_state() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value(SECTION, KEY, muted)
	cfg.save(SETTINGS_PATH)


func load_state() -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return muted
	muted = bool(cfg.get_value(SECTION, KEY, muted))
	return muted


func stream_for(sound_name: String):
	if not SOUND_NAMES.has(sound_name):
		return null
	var stream = ResourceLoader.load("res://assets/sounds/%s.wav" % sound_name) as AudioStream
	return stream


func is_muted() -> bool:
	return muted


func play(sound_name: String) -> bool:
	if muted:
		return false
	return stream_for(sound_name) != null
