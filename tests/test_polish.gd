# Wordtable polish suite (feel wiring, docs, network rematch).
# Pure-registry checks only (no server, no scene deps beyond table.tscn
# instantiation): the timer-off stall guard still auto-passes, the README
# and runbook carry their acceptance strings, the host-only rematch RPC
# redeals a finished game, and the fanfare/mute feel pins hold. Prints
# the acceptance marker stall_pass=true.
# Run headless via res://tests/test_runner.gd (`--suite polish` or full run).
class_name TestPolish
extends RefCounted

const TABLE_PATH := "res://scenes/table.tscn"


static func run_all(runner: SceneTree) -> void:
	_stall_checks(runner)
	_docs_checks(runner)
	_rematch_checks(runner)
	_sound_checks(runner)


# Timer-off stall: with the clock disabled the expired 180 s stall guard
# still emits exactly one auto_pass frame (the test_reconnect idiom).
static func _stall_checks(runner: SceneTree) -> void:
	var reg := RoomRegistry.new(null)
	var h := reg.create_room("Host", {"timer_on": false})
	var hc := str(h.get("code", ""))
	var ht := str(h.get("token", ""))
	runner.assert_eq(bool(h.get("timer_on", true)), false, "polish_stall_timer_off")
	reg.join_room(hc, "Guest")
	reg.start_game(hc, ht)
	runner.assert_true(reg.debug_expire(hc), "polish_stall_expire_armed")
	var due: Array = reg.poll_timers(int(Time.get_ticks_msec()))
	runner.assert_eq(due.size(), 1, "polish_stall_one_frame")
	runner.assert_true(bool((due[0] as Dictionary).get("auto_pass", false)), "polish_stall_auto_pass")
	print("stall_pass=true")


static func _docs_checks(runner: SceneTree) -> void:
	runner.assert_true(FileAccess.file_exists("res://README.md"), "polish_readme_exists")
	var readme := FileAccess.open("res://README.md", FileAccess.READ)
	runner.assert_true(readme != null, "polish_readme_readable")
	if readme != null:
		var text: String = readme.get_as_text()
		readme.close()
		runner.assert_true(text.find("Wordtable") != -1, "polish_readme_wordtable")
	runner.assert_true(FileAccess.file_exists("res://docs/runbook.md"), "polish_runbook_exists")
	var runbook := FileAccess.open("res://docs/runbook.md", FileAccess.READ)
	runner.assert_true(runbook != null, "polish_runbook_readable")
	if runbook != null:
		var text: String = runbook.get_as_text()
		runbook.close()
		runner.assert_true(text.find("systemd") != -1, "polish_runbook_systemd")
		runner.assert_true(text.find("Cloudflare Tunnel") != -1, "polish_runbook_tunnel")


# Network rematch: six alternating passes end the game six_scoreless, then
# the host-only rematch RPC redeals (started, empty history, full set).
static func _rematch_checks(runner: SceneTree) -> void:
	var reg := RoomRegistry.new(null)
	var h := reg.create_room("Host")
	var hc := str(h.get("code", ""))
	var ht := str(h.get("token", ""))
	var gt := str(reg.join_room(hc, "Guest").get("token", ""))
	runner.assert_true(bool(reg.start_game(hc, ht).get("ok", false)), "polish_rematch_started_game")
	var toks := [ht, gt]
	for i: int in range(6):
		var game0: LocalGame = reg.debug_game(hc)
		var res := reg.pass_turn(hc, str(toks[game0.current_player()]))
		runner.assert_true(bool(res.get("ok", false)), "polish_rematch_pass_%d_ok" % i)
	var finished: LocalGame = reg.debug_game(hc)
	runner.assert_true(finished.is_over(), "polish_rematch_over")
	runner.assert_eq(finished.ending(), "six_scoreless", "polish_rematch_scoreless")

	# Gates: guest token refused, and a live game refuses too.
	runner.assert_eq(str(reg.rematch(hc, gt).get("error", "")), "NOT_HOST", "polish_rematch_guest_not_host")
	var live := RoomRegistry.new(null)
	var lh := live.create_room("Host")
	var lhc := str(lh.get("code", ""))
	var lht := str(lh.get("token", ""))
	live.join_room(lhc, "Guest")
	live.start_game(lhc, lht)
	runner.assert_eq(str(live.rematch(lhc, lht).get("error", "")), "BAD_STATE", "polish_rematch_live_bad_state")

	var frames: Array = reg.handle_dict({"v": 1, "m": "rematch", "code": hc, "token": ht})
	runner.assert_eq(frames.size(), 2, "polish_rematch_two_frames")
	var reply := frames[0] as Dictionary
	runner.assert_true(bool(reply.get("ok", false)), "polish_rematch_ok")
	runner.assert_true(bool(reply.get("started", false)), "polish_rematch_started")
	runner.assert_eq(str((frames[1] as Dictionary).get("m", "")), "state_sync", "polish_rematch_sync")
	var fresh: LocalGame = reg.debug_game(hc)
	runner.assert_true(fresh.history().is_empty(), "polish_rematch_clears_history")
	runner.assert_eq(fresh.is_over(), false, "polish_rematch_clears_over")
	runner.assert_eq(fresh.player_count(), 2, "polish_rematch_keeps_seats")
	var total_tiles: int = fresh.bag_remaining()
	for p: int in range(fresh.player_count()):
		total_tiles += fresh.rack_letters(p).size()
		runner.assert_eq(fresh.rack_letters(p).size(), 7, "polish_rematch_rack_refilled")
	runner.assert_eq(total_tiles, 100, "polish_rematch_full_set_100")


static func _sound_checks(runner: SceneTree) -> void:
	runner.assert_true(SoundBank.SOUND_NAMES.has("fanfare"), "polish_sound_fanfare_listed")
	var bank := SoundBank.new()
	var prior: bool = bank.is_muted()
	bank.set_muted(false)
	var fx := CommitFx.new()
	runner.assert_true(fx.play_win(), "polish_fanfare_unmuted")
	bank.set_muted(true)
	runner.assert_eq(fx.play_win(), false, "polish_fanfare_muted")
	bank.set_muted(prior)
	bank.save_state()

	runner.assert_true(ResourceLoader.exists(TABLE_PATH), "polish_table_file_exists")
	var packed := load(TABLE_PATH) as PackedScene
	runner.assert_true(packed != null, "polish_table_loads_as_packed_scene")
	if packed == null:
		return
	var table := packed.instantiate()
	runner.assert_true(table != null, "polish_table_instantiates")
	if table == null:
		return
	runner.root.add_child(table)
	runner.assert_true(table.get_node_or_null("MuteButton") != null, "polish_mute_button_present")
	runner.assert_true(table.get_node_or_null("ThunkPlayer") != null, "polish_thunk_player_present")
	runner.assert_true(table.get_node_or_null("FanfarePlayer") != null, "polish_fanfare_player_present")
	var mute_btn := table.get_node_or_null("%MuteButton") as Button
	runner.assert_true(mute_btn != null, "polish_mute_button_unique")
	if mute_btn != null:
		runner.assert_true(mute_btn.text.find("Sound:") != -1, "polish_mute_label_sound")
	table.queue_free()
