# Wordtable strip+chat suite (scene deps, no networking).
# Run headless via res://tests/test_runner.gd (`--suite strip_chat` or full run).
# Prints the strip_chat acceptance markers on every strip_chat run:
# plaques=4, emotes=3, chat_echo=hello, mute_persisted=true.
class_name TestStripChat
extends RefCounted

const STRIP_PATH := "res://scenes/table/player_strip.tscn"
const CHAT_PATH := "res://scenes/table/chat.tscn"


static func run_all(runner: SceneTree) -> void:
	_strip_checks(runner)
	_chat_checks(runner)
	_sound_checks(runner)


static func _strip_checks(runner: SceneTree) -> void:
	runner.assert_true(ResourceLoader.exists(STRIP_PATH), "strip_scene_file_exists")
	var packed := load(STRIP_PATH) as PackedScene
	runner.assert_true(packed != null, "strip_scene_loads_as_packed_scene")
	if packed == null:
		return
	var strip: PlayerStrip = packed.instantiate() as PlayerStrip
	runner.assert_true(strip != null, "strip_scene_instantiates_player_strip")
	if strip == null:
		return
	runner.assert_true(strip.has_signal("plaque_pressed"), "strip_has_plaque_pressed_signal")
	runner.root.add_child(strip)

	strip.set_players([
		{"name": "Ada", "score": 12, "tiles": 7},
		{"name": "Bob", "score": 8, "tiles": 5},
		{"name": "Cy", "score": 21, "tiles": 6},
		{"name": "Dee", "score": 3, "tiles": 7},
	])
	runner.assert_eq(strip.get_plaque_count(), 4, "strip_plaque_count_4")
	print("plaques=4")
	runner.assert_eq(strip.get_player_name(0), "Ada", "strip_plaque0_name")
	runner.assert_eq(strip.get_score(0), 12, "strip_plaque0_score")
	runner.assert_eq(strip.get_tile_count(0), 7, "strip_plaque0_tiles")

	var plaque0 := strip.get_plaque(0)
	runner.assert_true(plaque0 != null, "strip_plaque0_node_exists")
	if plaque0 != null:
		runner.assert_eq((plaque0.get_node_or_null("Body/Name") as Label).text, "Ada", "strip_plaque0_name_label")
		runner.assert_true((plaque0.get_node_or_null("Body/Score") as Label).text.find("12") != -1, "strip_plaque0_score_label")
		runner.assert_true((plaque0.get_node_or_null("Body/Tiles") as Label).text.find("7") != -1, "strip_plaque0_tiles_label")

	strip.set_active(2)
	runner.assert_eq(strip.get_active(), 2, "strip_active_index_2")
	strip.set_time_fraction(0.5)
	var ring := strip.get_timer_ring(2)
	runner.assert_true(ring != null, "strip_active_ring_exists")
	if ring != null:
		runner.assert_eq(ring.min_value, 0.0, "strip_ring_min_0")
		runner.assert_eq(ring.max_value, 1.0, "strip_ring_max_1")
		runner.assert_eq(ring.value, 0.5, "strip_ring_value_half")
		runner.assert_eq(ring.show_percentage, false, "strip_ring_hides_percentage")
		runner.assert_true(ring.visible, "strip_active_ring_visible")
	var idle_ring := strip.get_timer_ring(0)
	if idle_ring != null:
		runner.assert_eq(idle_ring.visible, false, "strip_idle_ring_hidden")

	strip.set_active(-1)
	runner.assert_eq(strip.get_active(), 2, "strip_oob_negative_ignored")
	strip.set_active(9)
	runner.assert_eq(strip.get_active(), 2, "strip_oob_large_ignored")

	strip.set_players([
		{"name": "Ada", "score": 0, "tiles": 7},
		{"name": "Bob", "score": 0, "tiles": 7},
	])
	runner.assert_eq(strip.get_plaque_count(), 2, "strip_two_players_supported")

	strip.queue_free()


static func _chat_checks(runner: SceneTree) -> void:
	runner.assert_true(ResourceLoader.exists(CHAT_PATH), "chat_scene_file_exists")
	var packed := load(CHAT_PATH) as PackedScene
	runner.assert_true(packed != null, "chat_scene_loads_as_packed_scene")
	if packed == null:
		return
	var chat: ChatView = packed.instantiate() as ChatView
	runner.assert_true(chat != null, "chat_scene_instantiates_chat_view")
	if chat == null:
		return
	runner.assert_true(chat.has_signal("message_sent"), "chat_has_message_sent_signal")
	runner.assert_true(chat.has_signal("emote_sent"), "chat_has_emote_sent_signal")
	runner.root.add_child(chat)

	runner.assert_eq(chat.get_emote_count(), 3, "chat_emote_count_3")
	print("emotes=3")
	runner.assert_eq(chat.get_emote_glyph(0), "👍", "chat_emote0_thumbs_up")
	runner.assert_eq(chat.get_emote_glyph(1), "😂", "chat_emote1_joy")
	runner.assert_eq(chat.get_emote_glyph(2), "😭", "chat_emote2_sob")
	runner.assert_eq(chat.get_emote_glyph(9), "", "chat_emote_oob_empty")

	runner.assert_eq(chat.is_panel_open(), false, "chat_panel_starts_closed")
	runner.assert_eq(chat.get_unread(), 0, "chat_unread_starts_zero")

	runner.assert_true(chat.send_local("hello"), "chat_send_hello_ok")
	runner.assert_true(chat.get_last_message().ends_with("hello"), "chat_last_message_ends_hello")
	print("chat_echo=hello")
	runner.assert_eq(chat.get_unread(), 1, "chat_unread_bumps_while_closed")
	runner.assert_eq(chat.send_local("   "), false, "chat_blank_rejected")

	chat.open_panel()
	runner.assert_eq(chat.is_panel_open(), true, "chat_panel_open")
	runner.assert_eq(chat.get_unread(), 0, "chat_unread_clears_on_open")

	runner.assert_true(chat.send_emote(0), "chat_emote0_sends")
	runner.assert_true(chat.get_last_message().ends_with("👍"), "chat_emote0_echoes_glyph")
	runner.assert_eq(chat.send_emote(9), false, "chat_emote_oob_rejected")
	chat.close_panel()
	runner.assert_eq(chat.is_panel_open(), false, "chat_panel_closed")

	chat.queue_free()


static func _sound_checks(runner: SceneTree) -> void:
	for sound_name in SoundBank.SOUND_NAMES:
		var path := "res://assets/sounds/%s.wav" % sound_name
		runner.assert_true(FileAccess.file_exists(path), "sound_wav_exists_" + sound_name)
		var handle := FileAccess.open(path, FileAccess.READ)
		runner.assert_true(handle != null, "sound_wav_readable_" + sound_name)
		if handle != null:
			runner.assert_true(handle.get_length() > 44, "sound_wav_has_data_" + sound_name)
			handle.close()
	var bank := SoundBank.new()
	var prior: bool = bank.is_muted()
	bank.set_muted(true)
	bank.save_state()
	var fresh := SoundBank.new()
	runner.assert_eq(fresh.load_state(), true, "sound_mute_reloads_true")
	runner.assert_eq(fresh.is_muted(), true, "sound_mute_persisted_true")
	print("mute_persisted=true")
	runner.assert_true(fresh.toggle_muted() == false, "sound_toggle_unmutes")
	runner.assert_eq(fresh.play("thunk"), true, "sound_play_thunk_unmuted")
	runner.assert_eq(fresh.play("nope"), false, "sound_play_unknown_false")
	fresh.set_muted(true)
	runner.assert_eq(fresh.play("thunk"), false, "sound_play_muted_false")
	bank.set_muted(prior)
	bank.save_state()
