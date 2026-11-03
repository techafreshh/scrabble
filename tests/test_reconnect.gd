# Wordtable reconnect suite (overlay, backoff, token rejoin, refresh resume).
# Pure part (always runs, no server): backoff ladder, session round-trip,
# overlay show/hide, canned rejoin routing (state replace plus board_tiles
# cache, no clobber on BAD_TOKEN), CAT board snapshot, and a stall-guard
# regression proving an expired deadline still auto-passes while away.
# Live part (only with --suite reconnect and a reachable server): two
# scripted clients create/join/start, pin racks, commit one legal word,
# snapshot the guest, kill its socket, rejoin with the stored token, and
# prove rack/scores/board identical; then a wrong token proves BAD_TOKEN.
# Prints resync_ms=<ms> (< 3000), resync_identical=true, error=BAD_TOKEN.
# Run headless via res://tests/test_runner.gd (`--suite reconnect`).
class_name TestReconnect
extends RefCounted

const PHASE_MS := 10000


# Minimal lexicon double mirroring TestRooms (duck-typed via is_word).
class FakeLexicon extends RefCounted:
	var _words: Dictionary = {}

	func _init(word_list: Array = []) -> void:
		for w in word_list:
			_words[str(w).strip_edges().to_upper()] = true

	func is_word(raw: String) -> bool:
		var w := str(raw).strip_edges().to_upper()
		if w.is_empty():
			return false
		return _words.has(w)


static func run_all(runner: SceneTree, live: bool) -> void:
	_pure_checks(runner)
	if live:
		_live_flow(runner)


static func _pure_checks(runner: SceneTree) -> void:
	# Backoff ladder: 250ms doubling, capped at 4000ms.
	runner.assert_eq(ReconnectOverlay.compute_delay_ms(1), 250, "reconnect_delay_1_250")
	runner.assert_eq(ReconnectOverlay.compute_delay_ms(2), 500, "reconnect_delay_2_500")
	runner.assert_eq(ReconnectOverlay.compute_delay_ms(3), 1000, "reconnect_delay_3_1000")
	runner.assert_eq(ReconnectOverlay.compute_delay_ms(4), 2000, "reconnect_delay_4_2000")
	runner.assert_eq(ReconnectOverlay.compute_delay_ms(5), 4000, "reconnect_delay_5_cap")
	runner.assert_eq(ReconnectOverlay.compute_delay_ms(6), 4000, "reconnect_delay_6_cap")
	runner.assert_eq(ReconnectOverlay.compute_delay_ms(100), 4000, "reconnect_delay_huge_cap")
	runner.assert_eq(ReconnectOverlay.compute_delay_ms(0), 250, "reconnect_delay_zero_clamps")

	# Session round-trip on a temp path (never touches the live session).
	var tmp := "user://reconnect_test_session.cfg"
	ReconnectOverlay.save_session("ABCD", "tok123", tmp)
	var loaded := ReconnectOverlay.load_session(tmp)
	runner.assert_eq(str(loaded.get("code", "")), "ABCD", "reconnect_session_code")
	runner.assert_eq(str(loaded.get("token", "")), "tok123", "reconnect_session_token")
	ReconnectOverlay.clear_session(tmp)
	var cleared := ReconnectOverlay.load_session(tmp)
	runner.assert_eq(str(cleared.get("code", "")), "", "reconnect_session_cleared_code")
	runner.assert_eq(str(cleared.get("token", "")), "", "reconnect_session_cleared_token")
	DirAccess.remove_absolute(tmp)

	# Overlay show/hide prints the marker and toggles visibility.
	var ov := ReconnectOverlay.new()
	runner.root.add_child(ov)
	ov.show_overlay("test")
	runner.assert_true(ov.is_showing(), "reconnect_overlay_showing")
	runner.assert_true(ov.visible, "reconnect_overlay_visible")
	ov.hide_overlay()
	runner.assert_eq(ov.is_showing(), false, "reconnect_overlay_hidden")
	ov.queue_free()

	# Canned rejoin frame routes through the replace-state path and caches
	# board_tiles; the BAD_TOKEN error never clobbers cached identity.
	var bus := EventBus.new()
	runner.root.add_child(bus)
	var synced := [0]
	bus.state_synced.connect(func() -> void: synced[0] += 1)
	var rack_before: Array = ["H", "I", "J", "K", "L", "M", "N"]
	var route := bus.apply_server_frame({
		"m": "rejoin", "ok": true, "code": "ABCD", "seat": 1, "you": 1,
		"token": "t", "session": "t", "seats": 2, "started": true,
		"turn": 1, "scores": [10, 0], "rack": rack_before,
		"board_tiles": [{"square": "8I", "letter": "T"}, {"square": "8G", "letter": "C"}, {"square": "8H", "letter": "A"}],
		"over": false, "ending": "", "seats_list": [],
	})
	runner.assert_eq(route, "rejoin+seats", "reconnect_canned_route")
	runner.assert_eq(synced[0], 1, "reconnect_canned_synced")
	runner.assert_eq(bus.get_rack(), rack_before, "reconnect_canned_rack")
	runner.assert_eq(bus.get_scores(), [10, 0], "reconnect_canned_scores")
	runner.assert_eq(bus.get_board_tiles(), [
		{"square": "8I", "letter": "T"}, {"square": "8G", "letter": "C"}, {"square": "8H", "letter": "A"}
	], "reconnect_canned_tiles")
	runner.assert_eq(
		ReconnectOverlay.compare_snapshots(
			{"rack": rack_before, "scores": [10, 0],
				"board_tiles": [{"square": "8G", "letter": "C"}, {"square": "8H", "letter": "A"}, {"square": "8I", "letter": "T"}]},
			{"rack": bus.get_rack(), "scores": bus.get_scores(), "board_tiles": bus.get_board_tiles()}
		), true, "reconnect_compare_order_insensitive"
	)
	runner.assert_eq(
		ReconnectOverlay.compare_snapshots(
			{"rack": rack_before, "scores": [10, 0], "board_tiles": []},
			{"rack": bus.get_rack(), "scores": bus.get_scores(), "board_tiles": bus.get_board_tiles()}
		), false, "reconnect_compare_tiles_mismatch"
	)
	var bad := bus.apply_server_frame({
		"m": "rejoin", "ok": false, "error": "BAD_TOKEN", "reason": "BAD_TOKEN", "code": "ABCD",
	})
	runner.assert_eq(bad, "rejoin_error", "reconnect_bad_token_route")
	runner.assert_eq(synced[0], 1, "reconnect_bad_token_no_resync")
	runner.assert_eq(bus.get_rack(), rack_before, "reconnect_bad_token_no_clobber")
	bus.queue_free()

	# CAT opening round-trips through the board snapshot helper.
	var game := LocalGame.new(2, 99, FakeLexicon.new(["CAT"]))
	game.debug_set_rack(0, ["C", "A", "T", "D", "E", "F", "G"])
	var res := game.place([
		{"col": 6, "row": 7, "letter": "C", "blank": false},
		{"col": 7, "row": 7, "letter": "A", "blank": false},
		{"col": 8, "row": 7, "letter": "T", "blank": false},
	], {})
	runner.assert_true(bool(res.get("ok", false)), "reconnect_cat_ok")
	var tiles := game.board_tiles()
	runner.assert_eq(tiles.size(), 3, "reconnect_tiles_3")
	var by_sq := {}
	for t in tiles:
		by_sq[str((t as Dictionary).get("square", ""))] = str((t as Dictionary).get("letter", ""))
	runner.assert_eq(str(by_sq.get("8G", "")), "C", "reconnect_tile_g8_c")
	runner.assert_eq(str(by_sq.get("8H", "")), "A", "reconnect_tile_h8_a")
	runner.assert_eq(str(by_sq.get("8I", "")), "T", "reconnect_tile_i8_t")

	# Stall guard still auto-passes while the seat is away (expired
	# deadline emits exactly one auto_pass frame, registry untouched).
	var reg := RoomRegistry.new(null)
	var h := reg.create_room("Host")
	var hc := str(h.get("code", ""))
	var ht := str(h.get("token", ""))
	reg.join_room(hc, "Guest")
	reg.start_game(hc, ht)
	runner.assert_true(reg.debug_expire(hc), "reconnect_expire_armed")
	var due: Array = reg.poll_timers(int(Time.get_ticks_msec()))
	runner.assert_eq(due.size(), 1, "reconnect_stall_one_frame")
	runner.assert_true(bool((due[0] as Dictionary).get("auto_pass", false)), "reconnect_stall_auto_pass")
	print("reconnect_pure=ok")


static func _live_flow(runner: SceneTree) -> void:
	var url := NetClient.resolve_url()
	var a := NetClient.new()
	var b := NetClient.new()
	runner.root.add_child(a)
	runner.root.add_child(b)
	var peers: Array = [a, b]
	a.connect_to_server(url)
	b.connect_to_server(url)
	if not _wait_until(peers, func() -> bool: return a.is_open() and b.is_open(), PHASE_MS):
		runner.assert_true(false, "reconnect_live_both_open " + a.last_error + " " + b.last_error)
		_cleanup(peers)
		return

	a.create_room("Alice", true, false)
	if not _wait_until(peers, func() -> bool: return _has_ok(a, "create_room"), PHASE_MS):
		runner.assert_true(false, "reconnect_live_created")
		_cleanup(peers)
		return
	runner.assert_true(a.code != "", "reconnect_live_code_set")

	b.join_room(a.code, "Bob")
	if not _wait_until(peers, func() -> bool: return _has_ok(b, "join_room"), PHASE_MS):
		runner.assert_true(false, "reconnect_live_joined")
		_cleanup(peers)
		return
	runner.assert_eq(b.seat, 1, "reconnect_live_guest_seat_1")

	a.start_game()
	if not _wait_until(peers, func() -> bool: return a.bus.is_synced() and b.bus.is_synced(), PHASE_MS):
		runner.assert_true(false, "reconnect_live_synced")
		_cleanup(peers)
		return

	a.debug_set_rack(0, ["C", "A", "T", "D", "E", "F", "G"])
	a.debug_set_rack(1, ["H", "I", "J", "K", "L", "M", "N"])
	if not _wait_until(peers, func() -> bool: return _rack_pinned(a, 1), PHASE_MS):
		runner.assert_true(false, "reconnect_live_pinned")
		_cleanup(peers)
		return

	# One legal word on the board, fanned out to the guest's bus cache.
	a.place_tiles([
		{"col": 6, "row": 7, "letter": "C", "blank": false},
		{"col": 7, "row": 7, "letter": "A", "blank": false},
		{"col": 8, "row": 7, "letter": "T", "blank": false},
	])
	if not _wait_until(peers, func() -> bool: return b.bus.get_board_tiles().size() == 3, PHASE_MS):
		runner.assert_true(false, "reconnect_live_word_visible")
		_cleanup(peers)
		return

	# Snapshot the guest, kill its socket, rejoin with the stored token.
	var snap := {
		"rack": b.bus.get_rack(), "scores": b.bus.get_scores(),
		"board_tiles": b.bus.get_board_tiles(),
	}
	runner.assert_eq((snap["rack"] as Array).size(), 7, "reconnect_live_snap_rack_7")
	runner.assert_eq((snap["board_tiles"] as Array).size(), 3, "reconnect_live_snap_tiles_3")
	var guest_token := b.token
	runner.assert_true(guest_token != "", "reconnect_live_token_stored")
	var t0 := Time.get_ticks_msec()
	b.disconnect_from_server()
	for i in range(10):
		_pump(peers)
		OS.delay_msec(5)
	b.rejoin_room()
	if not _wait_until(peers, func() -> bool: return _has_ok(b, "rejoin"), PHASE_MS):
		runner.assert_true(false, "reconnect_live_rejoined")
		_cleanup(peers)
		return
	var ms := int(Time.get_ticks_msec()) - t0
	print("resync_ms=%d" % ms)
	runner.assert_true(ms < 3000, "reconnect_live_resync_fast")
	runner.assert_eq(b.seat, 1, "reconnect_live_same_seat")
	runner.assert_eq(b.code, a.code, "reconnect_live_same_room")
	var same := ReconnectOverlay.compare_snapshots(snap, {
		"rack": b.bus.get_rack(), "scores": b.bus.get_scores(),
		"board_tiles": b.bus.get_board_tiles(),
	})
	runner.assert_true(same, "reconnect_live_identical")
	if same:
		print("resync_identical=true")
	else:
		print("resync_identical=false")

	# Wrong token answers exactly BAD_TOKEN and nothing else.
	b.token = "0".repeat(32)
	b.rejoin_room()
	if not _wait_until(peers, func() -> bool: return _has_err(b, "rejoin"), PHASE_MS):
		runner.assert_true(false, "reconnect_live_bad_token_reply")
		b.token = guest_token
		_cleanup(peers)
		return
	runner.assert_eq(str(_last_err(b, "rejoin").get("error", "")), "BAD_TOKEN", "reconnect_live_bad_token")
	print("error=BAD_TOKEN")
	b.token = guest_token
	_cleanup(peers)


static func _pump(clients: Array) -> void:
	for c in clients:
		(c as NetClient).poll()


static func _wait_until(clients: Array, pred: Callable, timeout_ms: int) -> bool:
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < timeout_ms:
		_pump(clients)
		if bool(pred.call()):
			return true
		OS.delay_msec(5)
	_pump(clients)
	return bool(pred.call())


static func _has_ok(client: NetClient, method: String) -> bool:
	for i in range(client.received.size() - 1, -1, -1):
		var f = client.received[i]
		if f is Dictionary and str((f as Dictionary).get("m", "")) == method \
				and bool((f as Dictionary).get("ok", false)):
			return true
	return false


static func _has_err(client: NetClient, method: String) -> bool:
	for i in range(client.received.size() - 1, -1, -1):
		var f = client.received[i]
		if f is Dictionary and str((f as Dictionary).get("m", "")) == method \
				and not bool((f as Dictionary).get("ok", false)):
			return true
	return false


static func _last_err(client: NetClient, method: String) -> Dictionary:
	for i in range(client.received.size() - 1, -1, -1):
		var f = client.received[i]
		if f is Dictionary and str((f as Dictionary).get("m", "")) == method \
				and not bool((f as Dictionary).get("ok", false)):
			return f as Dictionary
	return {}


static func _rack_pinned(host: NetClient, seat_no: int) -> bool:
	for i in range(host.received.size() - 1, -1, -1):
		var f = host.received[i]
		if f is Dictionary and str((f as Dictionary).get("m", "")) == "debug_set_rack" \
				and int((f as Dictionary).get("seat", -9)) == seat_no:
			return true
	return false


static func _cleanup(clients: Array) -> void:
	for c in clients:
		(c as NetClient).disconnect_from_server()
		(c as NetClient).queue_free()
