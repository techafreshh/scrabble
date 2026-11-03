# Wordtable net-client suite (autoload Bus/Net driver + EventBus hub).
# Pure part (always runs, no server): payload shape via board square
# helpers, tiles_for_commit privacy, reject-text mapping, bus routing with
# canned frames, and tiles-back through P2 view doubles. Live part (only
# with --suite net_client and a reachable server): two scripted clients
# create/join/start, prove rack sync + privacy, force a dictionary reject,
# and relay chat. Prints sync_racks=2, ui_reject=Not in my book: QX and
# chat_relay=true on the live run.
# Run headless via res://tests/test_runner.gd (`--suite net_client`).
class_name TestNetClient
extends RefCounted

const PHASE_MS := 10000


static func run_all(runner: SceneTree, live: bool) -> void:
	_pure_checks(runner)
	if live:
		_live_flow(runner)


static func _pure_checks(runner: SceneTree) -> void:
	runner.assert_eq(NetClient.DEFAULT_URL, "ws://localhost:9080", "net_client_default_url")
	runner.assert_eq(NetClient.PROTOCOL_VERSION, 1, "net_client_protocol_v1")

	# Square algebra round-trips through the wire spelling (either order).
	for cell in [Vector2i(0, 0), Vector2i(7, 7), Vector2i(14, 14), Vector2i(3, 11)]:
		var back := ScrabbleBoard.square_to_cell(ScrabbleBoard.cell_to_square(cell.x, cell.y))
		runner.assert_eq(back, cell, "net_client_square_roundtrip_%d_%d" % [cell.x, cell.y])
	runner.assert_eq(ScrabbleBoard.cell_to_square(7, 7), "8H", "net_client_center_square_8h")
	runner.assert_eq(ScrabbleBoard.square_to_cell("H8"), Vector2i(7, 7), "net_client_letter_first_h8")
	runner.assert_eq(ScrabbleBoard.square_to_cell("8H"), Vector2i(7, 7), "net_client_number_first_8h")

	# Commit payloads carry only staged squares — no slots, no full rack.
	var pendings: Array = [
		{"col": 7, "row": 7, "letter": "Q", "blank": false, "slot": 0},
		{"col": 8, "row": 7, "letter": "E", "blank": true, "slot": 3},
	]
	var tiles := NetClient.tiles_for_commit(pendings)
	runner.assert_eq(tiles.size(), 2, "net_client_commit_two_tiles")
	runner.assert_eq((tiles[0] as Dictionary).get("square"), "8H", "net_client_commit_square_q")
	runner.assert_eq((tiles[0] as Dictionary).get("letter"), "Q", "net_client_commit_letter_q")
	runner.assert_eq((tiles[1] as Dictionary).get("square"), "8I", "net_client_commit_square_e")
	runner.assert_eq((tiles[1] as Dictionary).get("blank_as"), "E", "net_client_commit_blank_as")
	runner.assert_eq(str((tiles[0] as Dictionary).get("blank_as", "")), "", "net_client_commit_plain_no_blank_as")
	var leaked := false
	for t in tiles:
		if (t as Dictionary).has("slot") or (t as Dictionary).has("rack"):
			leaked = true
	runner.assert_eq(leaked, false, "net_client_commit_no_slot_or_rack")
	runner.assert_eq(NetClient.tiles_for_commit([]).size(), 0, "net_client_commit_empty")

	# Room-boundary spelling maps back to the shared reject prefix.
	runner.assert_eq(
		EventBus.ui_reject_text("NOT_IN_LEXICON", "QX"), "Not in my book: QX", "net_client_reject_text_qx"
	)
	runner.assert_eq(
		CommitFx.reject_text_for({"ok": false, "reason": "NOT_IN_DICTIONARY", "reason_word": "QX"}),
		"Not in my book: QX", "net_client_reject_prefix_shared"
	)

	# Bus routing with canned frames: sync replaces, deltas refresh,
	# chat logs once, replies never double-log, rejects show text.
	var bus := EventBus.new()
	runner.root.add_child(bus)
	var fired: Array = []
	bus.state_synced.connect(func() -> void: fired.append("synced"))
	bus.delta_applied.connect(func(kind: String) -> void: fired.append("delta:" + kind))
	bus.chat_received.connect(func(who: String, text: String) -> void: fired.append("chat:" + who + ":" + text))
	bus.reject_shown.connect(func(text: String) -> void: fired.append("reject:" + text))
	bus.seats_changed.connect(func(count: int) -> void: fired.append("seats:%d" % count))

	runner.assert_eq(
		bus.apply_server_frame({
			"m": "state_sync", "code": "ABCD", "turn": 1, "scores": [3, 5],
			"rack": ["A", "B", "C", "D", "E", "F", "G"], "seats": 2,
			"started": true, "over": false,
		}),
		"state_sync+seats", "net_client_sync_route"
	)
	runner.assert_true(bus.is_synced(), "net_client_sync_flag")
	runner.assert_eq(bus.get_turn(), 1, "net_client_sync_turn")
	runner.assert_eq(bus.get_scores(), [3, 5], "net_client_sync_scores")
	runner.assert_eq(bus.get_rack().size(), 7, "net_client_sync_rack_7")
	runner.assert_eq(bus.room_code(), "ABCD", "net_client_sync_code")
	runner.assert_true(fired.has("synced"), "net_client_sync_signal")
	runner.assert_true(fired.has("seats:2"), "net_client_sync_seats_signal")

	runner.assert_eq(
		bus.apply_server_frame({"m": "turn_update", "code": "ABCD", "turn": 0, "scores": [3, 5], "over": false}),
		"delta", "net_client_delta_route"
	)
	runner.assert_true(fired.has("delta:turn_update"), "net_client_delta_signal")
	runner.assert_eq(
		bus.apply_server_frame({"m": "game_over", "code": "ABCD", "turn": 0, "scores": [10, 5], "over": true, "ending": "scores"}),
		"delta", "net_client_game_over_route"
	)
	runner.assert_true(bus.is_over(), "net_client_game_over_flag")
	runner.assert_true(fired.has("delta:game_over"), "net_client_game_over_signal")

	runner.assert_eq(
		bus.apply_server_frame({"m": "chat", "code": "ABCD", "from": "Bob", "seat": 1, "text": "hi", "ts": 7}),
		"chat", "net_client_chat_route"
	)
	runner.assert_eq(bus.get_chat_log().size(), 1, "net_client_chat_logged")
	runner.assert_true(fired.has("chat:Bob:hi"), "net_client_chat_signal")
	runner.assert_eq(
		bus.apply_server_frame({"m": "chat", "ok": true, "chat_ok": true, "from": "Me", "text": "hi", "ts": 7}),
		"chat_reply", "net_client_chat_reply_route"
	)
	runner.assert_eq(bus.get_chat_log().size(), 1, "net_client_chat_reply_not_relogged")

	runner.assert_eq(
		bus.apply_server_frame({
			"m": "place_tiles", "ok": false, "accepted": false, "points": 0,
			"reason": "NOT_IN_LEXICON", "reason_word": "QX",
			"turn": 1, "scores": [3, 5], "over": false,
		}),
		"reject", "net_client_reject_route"
	)
	runner.assert_eq(bus.last_reject_text, "Not in my book: QX", "net_client_reject_text")
	runner.assert_true(fired.has("reject:Not in my book: QX"), "net_client_reject_signal")

	# Tiles-back through the real NetClient path with P2 view doubles.
	var view := BoardView.new()
	runner.root.add_child(view)
	view.set_pending([Vector2i(7, 7), Vector2i(8, 7)])
	var ctrl := PlacementController.new()
	ctrl.set_rack(["Q", "X", "A", "B", "C", "D", "E"])
	ctrl.select_slot(0)
	ctrl.place_at(7, 7)
	ctrl.select_slot(1)
	ctrl.place_at(8, 7)
	runner.assert_eq(ctrl.pending_count(), 2, "net_client_staged_two")
	var net := NetClient.new()
	runner.root.add_child(net)
	net.bind_views(view, ctrl)
	runner.assert_eq(
		net.handle_frame({
			"m": "place_tiles", "ok": false, "accepted": false, "points": 0,
			"reason": "NOT_IN_LEXICON", "reason_word": "QX",
			"turn": 0, "scores": [0, 0], "over": false,
		}),
		"reject", "net_client_bounce_route"
	)
	runner.assert_eq(net.bus.last_reject_text, "Not in my book: QX", "net_client_bounce_text")
	runner.assert_eq(ctrl.pending_count(), 0, "net_client_bounce_recalls")
	runner.assert_eq(view.is_pending(7, 7), false, "net_client_bounce_clears_view")
	runner.assert_eq(view.is_pending(8, 7), false, "net_client_bounce_clears_view2")

	# Offline facade results drive the same two signals.
	var offline := EventBus.new()
	runner.root.add_child(offline)
	var seen: Array = []
	offline.delta_applied.connect(func(kind: String) -> void: seen.append("delta:" + kind))
	offline.reject_shown.connect(func(text: String) -> void: seen.append("reject:" + text))
	runner.assert_eq(
		offline.apply_local_result({"ok": false, "kind": "reject", "reason": "NOT_IN_DICTIONARY", "reason_word": "QX"}),
		"reject", "net_client_offline_reject_route"
	)
	runner.assert_eq(offline.last_reject_text, "Not in my book: QX", "net_client_offline_reject_text")
	runner.assert_eq(
		offline.apply_local_result({"ok": true, "kind": "commit", "turn": 1, "scores": [8, 0], "over": false}),
		"delta", "net_client_offline_commit_route"
	)
	runner.assert_true(seen.has("reject:Not in my book: QX"), "net_client_offline_reject_signal")
	runner.assert_true(seen.has("delta:commit"), "net_client_offline_commit_signal")

	bus.queue_free()
	view.queue_free()
	net.queue_free()
	offline.queue_free()
	print("net_client_pure=ok")


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
		runner.assert_true(false, "net_client_live_both_open " + a.last_error + " " + b.last_error)
		_cleanup(peers)
		return

	a.create_room("Alice", true, false)
	if not _wait_until(peers, func() -> bool: return _has_ok(a, "create_room"), PHASE_MS):
		runner.assert_true(false, "net_client_live_created")
		_cleanup(peers)
		return
	runner.assert_true(a.code != "", "net_client_live_code_set")
	runner.assert_eq(a.seat, 0, "net_client_live_host_seat_0")

	b.join_room(a.code, "Bob")
	if not _wait_until(peers, func() -> bool: return _has_ok(b, "join_room"), PHASE_MS):
		runner.assert_true(false, "net_client_live_joined")
		_cleanup(peers)
		return
	runner.assert_eq(b.seat, 1, "net_client_live_guest_seat_1")
	runner.assert_eq(b.code, a.code, "net_client_live_same_room")

	a.start_game()
	if not _wait_until(peers, func() -> bool: return a.bus.is_synced() and b.bus.is_synced(), PHASE_MS):
		runner.assert_true(false, "net_client_live_synced")
		_cleanup(peers)
		return

	# Deterministic disjoint racks so privacy is checkable, then prove
	# both seats hold their own 7 tiles through the private get_rack path.
	a.debug_set_rack(0, ["A", "B", "C", "D", "E", "F", "G"])
	if not _wait_until(peers, func() -> bool: return _has_ok(a, "debug_set_rack"), PHASE_MS):
		runner.assert_true(false, "net_client_live_pin_a")
		_cleanup(peers)
		return
	a.debug_set_rack(1, ["H", "I", "J", "K", "L", "M", "N"])
	if not _wait_until(peers, func() -> bool: return _rack_pinned(a, 1), PHASE_MS):
		runner.assert_true(false, "net_client_live_pin_b")
		_cleanup(peers)
		return
	a.request_rack()
	b.request_rack()
	if not _wait_until(peers, func() -> bool: return _has_ok(a, "get_rack") and _has_ok(b, "get_rack"), PHASE_MS):
		runner.assert_true(false, "net_client_live_racks")
		_cleanup(peers)
		return
	var rack_a: Array = _last_reply_with(a, "get_rack").get("rack", [])
	var rack_b: Array = _last_reply_with(b, "get_rack").get("rack", [])
	runner.assert_eq(rack_a.size(), 7, "net_client_live_rack_a_7")
	runner.assert_eq(rack_b.size(), 7, "net_client_live_rack_b_7")
	runner.assert_true(rack_a != rack_b, "net_client_live_racks_private")
	if rack_a.size() == 7 and rack_b.size() == 7 and rack_a != rack_b:
		print("sync_racks=2")
	else:
		runner.assert_true(false, "net_client_live_sync_marker")

	# Forced dictionary reject: Q+X across the center spells QX, which the
	# bundled lexicon does not contain. Tiles must bounce back staged-side.
	a.debug_set_rack(0, ["Q", "X", "Z", "J", "K", "V", "B"])
	if not _wait_until(peers, func() -> bool: return _rack_has(a, ["Q", "X"]), PHASE_MS):
		runner.assert_true(false, "net_client_live_pin_qx")
		_cleanup(peers)
		return
	var view := BoardView.new()
	runner.root.add_child(view)
	view.set_pending([Vector2i(7, 7), Vector2i(8, 7)])
	var ctrl := PlacementController.new()
	ctrl.set_rack(["Q", "X", "Z", "J", "K", "V", "B"])
	ctrl.select_slot(0)
	ctrl.place_at(7, 7)
	ctrl.select_slot(1)
	ctrl.place_at(8, 7)
	a.bind_views(view, ctrl)
	a.place_tiles(NetClient.tiles_for_commit(ctrl.get_pendings()))
	if not _wait_until(peers, func() -> bool: return a.bus.last_reject_text != "", PHASE_MS):
		runner.assert_true(false, "net_client_live_rejected")
		view.queue_free()
		_cleanup(peers)
		return
	runner.assert_eq(ctrl.pending_count(), 0, "net_client_live_bounced")
	runner.assert_eq(a.bus.last_reject_text, "Not in my book: QX", "net_client_live_reject_text")
	print("ui_reject=" + a.bus.last_reject_text)
	view.queue_free()

	a.send_chat("hello-net")
	if not _wait_until(peers, func() -> bool: return _chat_has(b, "hello-net"), PHASE_MS):
		runner.assert_true(false, "net_client_live_chat")
		_cleanup(peers)
		return
	print("chat_relay=true")
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
	return not _last_reply_with(client, method).is_empty()


static func _last_reply_with(client: NetClient, method: String) -> Dictionary:
	for i in range(client.received.size() - 1, -1, -1):
		var f = client.received[i]
		if f is Dictionary and str((f as Dictionary).get("m", "")) == method \
				and bool((f as Dictionary).get("ok", false)):
			return f as Dictionary
	return {}


static func _rack_pinned(host: NetClient, seat_no: int) -> bool:
	for i in range(host.received.size() - 1, -1, -1):
		var f = host.received[i]
		if f is Dictionary and str((f as Dictionary).get("m", "")) == "debug_set_rack" \
				and int((f as Dictionary).get("seat", -9)) == seat_no:
			return true
	return false


static func _rack_has(client: NetClient, faces: Array) -> bool:
	for i in range(client.received.size() - 1, -1, -1):
		var f = client.received[i]
		if f is Dictionary and str((f as Dictionary).get("m", "")) == "debug_set_rack":
			var rack: Array = (f as Dictionary).get("rack", [])
			var ok := true
			for face in faces:
				if not rack.has(face):
					ok = false
			if ok:
				return true
	return false


static func _chat_has(client: NetClient, text: String) -> bool:
	for line in client.bus.get_chat_log():
		if line is Dictionary and str((line as Dictionary).get("text", "")) == text:
			return true
	return false


static func _cleanup(clients: Array) -> void:
	for c in clients:
		(c as NetClient).disconnect_from_server()
		(c as NetClient).queue_free()
