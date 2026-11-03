# Wordtable network smoke (standalone SceneTree driver, needs a live server).
# Boot one headless server first, then run from the repo root:
# godot --headless -s tests/net_smoke.gd
# Drives two in-process NetClient peers through the deterministic script
# shared with `python3 tests/ws_probe.py --smoke`: a test-mode room, the
# CAT opening, a forced guest drop with token rejoin, the CATS extension,
# then six alternating passes to the six_scoreless game_over. Prints the
# acceptance markers smoke_game_over=true, smoke_resync=true (plus
# smoke_resync_ms), and always illegal_states=<n>; exit 0 only when the
# game completed, the resync held, and no illegal reply or mismatch appeared.
extends SceneTree

const PHASE_MS := 10000
const RESYNC_BUDGET_MS := 3000

var _illegal := 0
var _resync_ok := false
var _gameover_ok := false
var _resync_ms := -1


func _initialize() -> void:
	var url := _parse_url()
	var a := NetClient.new()
	var b := NetClient.new()
	root.add_child(a)
	root.add_child(b)
	var peers: Array = [a, b]
	_run(url, a, b, peers)
	a.disconnect_from_server()
	b.disconnect_from_server()
	print("smoke_game_over=" + ("true" if _gameover_ok else "false"))
	print("smoke_resync=" + ("true" if _resync_ok else "false"))
	print("illegal_states=%d" % _illegal)
	quit(0 if (_gameover_ok and _resync_ok and _illegal == 0) else 1)


func _parse_url() -> String:
	var url := ""
	var port := ""
	var args := OS.get_cmdline_user_args()
	args.append_array(OS.get_cmdline_args())
	for arg in args:
		var s := str(arg)
		if s.begins_with("--url="):
			url = s.get_slice("=", 1).strip_edges()
		elif s.begins_with("--server-url="):
			url = s.get_slice("=", 1).strip_edges()
		elif s.begins_with("--port="):
			port = s.get_slice("=", 1).strip_edges()
	if url != "":
		return url
	if port != "" and port.is_valid_int():
		return "ws://localhost:%d" % port.to_int()
	return NetClient.DEFAULT_URL


func _note(reason: String) -> void:
	_illegal += 1
	push_error("net_smoke: " + reason)
	print("smoke_note=" + reason)


func _run(url: String, a: NetClient, b: NetClient, peers: Array) -> void:
	a.connect_to_server(url)
	b.connect_to_server(url)
	if not _wait_open(peers):
		_note("both_open_timeout")
		return
	a.create_room("SmokeA", true, false)
	if not _wait_ok(peers, a, "create_room"):
		_note("create_room_timeout")
		return
	if a.code == "" or a.token == "" or a.seat != 0:
		_note("create_room_identity")
		return
	b.join_room(a.code, "SmokeB")
	if not _wait_ok(peers, b, "join_room"):
		_note("join_room_timeout")
		return
	if b.seat != 1 or b.code != a.code:
		_note("join_room_identity")
		return
	a.start_game()
	if not _wait_synced(peers, a, b):
		_note("start_sync_timeout")
		return
	a.debug_set_rack(0, ["C", "A", "T", "D", "E", "F", "G"])
	if not _wait_pin(peers, a, 0):
		_note("pin_seat0_timeout")
		return
	a.debug_set_rack(1, ["S", "H", "I", "J", "K", "L", "M"])
	if not _wait_pin(peers, a, 1):
		_note("pin_seat1_timeout")
		return
	b.request_rack()
	if not _wait_ok(peers, b, "get_rack"):
		_note("guest_rack_timeout")
		return
	var since: int = a.received.size()
	a.place_tiles([
		{"col": 6, "row": 7, "letter": "C", "blank": false},
		{"col": 7, "row": 7, "letter": "A", "blank": false},
		{"col": 8, "row": 7, "letter": "T", "blank": false},
	])
	var cat := _wait_new_ok(peers, a, "place_tiles", since)
	if cat.is_empty():
		_note("cat_no_reply")
		return
	if not bool(cat.get("accepted", false)):
		_note("cat_not_accepted")
		return
	if not _wait_board(peers, b, 3):
		_note("cat_not_visible_on_guest")
		return
	var snap := {
		"rack": b.bus.get_rack(),
		"scores": b.bus.get_scores(),
		"board_tiles": b.bus.get_board_tiles(),
	}
	if (snap["rack"] as Array).size() != 7:
		_note("snap_rack_not_7")
	if (snap["board_tiles"] as Array).size() != 3:
		_note("snap_tiles_not_3")
		return
	var guest_token := b.token
	var guest_code := b.code
	var t0 := Time.get_ticks_msec()
	b.disconnect_from_server()
	for i in range(40):
		_pump(peers)
		OS.delay_msec(5)
	b.rejoin_room()
	if not _wait_ok(peers, b, "rejoin"):
		_note("rejoin_timeout")
		return
	_resync_ms = int(Time.get_ticks_msec()) - t0
	print("smoke_resync_ms=%d" % _resync_ms)
	var after := {
		"rack": b.bus.get_rack(),
		"scores": b.bus.get_scores(),
		"board_tiles": b.bus.get_board_tiles(),
	}
	var same := ReconnectOverlay.compare_snapshots(snap, after)
	if b.seat != 1 or b.code != guest_code or b.token != guest_token:
		_note("rejoin_identity_changed")
		return
	if _resync_ms >= RESYNC_BUDGET_MS:
		_note("resync_too_slow")
		return
	if not same:
		_note("resync_snapshot_mismatch")
		return
	_resync_ok = true
	print("smoke_resync=true")
	if not _wait_turn_is(peers, b, 1):
		_note("guest_turn_not_ready")
		return
	var since2: int = b.received.size()
	b.place_tiles([{"col": 9, "row": 7, "letter": "S", "blank": false}])
	var cats := _wait_new_ok(peers, b, "place_tiles", since2)
	if cats.is_empty():
		_note("cats_no_reply")
		return
	if not bool(cats.get("accepted", false)):
		_note("cats_not_accepted")
		return
	if not _wait_turn_is(peers, a, 0):
		_note("host_turn_not_ready")
		return
	var order: Array = [a, b, a, b, a, b]
	for i in range(6):
		var mover := order[i] as NetClient
		var turn_before: int = a.bus.get_turn()
		var psince: int = mover.received.size()
		mover.pass_turn()
		var reply := _wait_new_ok(peers, mover, "pass", psince)
		if reply.is_empty():
			_note("pass_%d_no_reply" % i)
			return
		if not bool(reply.get("accepted", false)):
			_note("pass_%d_not_accepted" % i)
			return
		if not _wait_turn_moved(peers, a, turn_before):
			_note("pass_%d_turn_stuck" % i)
			return
	if not _wait_over(peers, a, b):
		_note("game_never_over")
		return
	var fin := _find_game_over(a)
	if fin.is_empty():
		fin = _find_game_over(b)
	if fin.is_empty():
		_note("no_game_over_frame")
		return
	if str(fin.get("ending", "")) != "six_scoreless":
		_note("ending_not_six_scoreless")
		return
	var hist: Array = fin.get("history", [])
	if hist.size() < 2:
		_note("history_too_short")
		return
	_gameover_ok = true
	print("smoke_game_over=true")


func _pump(peers: Array) -> void:
	for c in peers:
		(c as NetClient).poll()


func _wait_open(peers: Array) -> bool:
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < PHASE_MS:
		_pump(peers)
		if (peers[0] as NetClient).is_open() and (peers[1] as NetClient).is_open():
			return true
		OS.delay_msec(5)
	_pump(peers)
	return (peers[0] as NetClient).is_open() and (peers[1] as NetClient).is_open()


func _wait_ok(peers: Array, client: NetClient, method: String) -> bool:
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < PHASE_MS:
		_pump(peers)
		if _has_ok(client, method):
			return true
		OS.delay_msec(5)
	_pump(peers)
	return _has_ok(client, method)


func _has_ok(client: NetClient, method: String) -> bool:
	for i in range(client.received.size() - 1, -1, -1):
		var f = client.received[i]
		if f is Dictionary and str((f as Dictionary).get("m", "")) == method \
				and bool((f as Dictionary).get("ok", false)):
			return true
	return false


func _wait_new_ok(peers: Array, client: NetClient, method: String, since: int) -> Dictionary:
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < PHASE_MS:
		_pump(peers)
		var hit := _scan_new_ok(client, method, since)
		if not hit.is_empty():
			return hit
		OS.delay_msec(5)
	_pump(peers)
	return _scan_new_ok(client, method, since)


func _scan_new_ok(client: NetClient, method: String, since: int) -> Dictionary:
	var lo := clampi(since, 0, client.received.size())
	for i in range(lo, client.received.size()):
		var f = client.received[i]
		if f is Dictionary and str((f as Dictionary).get("m", "")) == method \
				and bool((f as Dictionary).get("ok", false)):
			return f as Dictionary
	return {}


func _wait_pin(peers: Array, client: NetClient, seat_no: int) -> bool:
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < PHASE_MS:
		_pump(peers)
		if _has_pin(client, seat_no):
			return true
		OS.delay_msec(5)
	_pump(peers)
	return _has_pin(client, seat_no)


func _has_pin(client: NetClient, seat_no: int) -> bool:
	for i in range(client.received.size() - 1, -1, -1):
		var f = client.received[i]
		if f is Dictionary and str((f as Dictionary).get("m", "")) == "debug_set_rack" \
				and bool((f as Dictionary).get("ok", false)) \
				and int((f as Dictionary).get("seat", -9)) == seat_no:
			return true
	return false


func _wait_synced(peers: Array, a: NetClient, b: NetClient) -> bool:
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < PHASE_MS:
		_pump(peers)
		if a.bus.is_synced() and b.bus.is_synced():
			return true
		OS.delay_msec(5)
	_pump(peers)
	return a.bus.is_synced() and b.bus.is_synced()


func _wait_board(peers: Array, client: NetClient, count: int) -> bool:
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < PHASE_MS:
		_pump(peers)
		if client.bus.get_board_tiles().size() == count:
			return true
		OS.delay_msec(5)
	_pump(peers)
	return client.bus.get_board_tiles().size() == count


func _wait_turn_is(peers: Array, client: NetClient, want: int) -> bool:
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < PHASE_MS:
		_pump(peers)
		if client.bus.get_turn() == want:
			return true
		OS.delay_msec(5)
	_pump(peers)
	return client.bus.get_turn() == want


func _wait_turn_moved(peers: Array, client: NetClient, before: int) -> bool:
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < PHASE_MS:
		_pump(peers)
		if client.bus.get_turn() != before or client.bus.is_over():
			return true
		OS.delay_msec(5)
	_pump(peers)
	return client.bus.get_turn() != before or client.bus.is_over()


func _wait_over(peers: Array, a: NetClient, b: NetClient) -> bool:
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < PHASE_MS:
		_pump(peers)
		if a.bus.is_over() and b.bus.is_over():
			return true
		OS.delay_msec(5)
	_pump(peers)
	return a.bus.is_over() and b.bus.is_over()


func _find_game_over(client: NetClient) -> Dictionary:
	for i in range(client.received.size() - 1, -1, -1):
		var f = client.received[i]
		if f is Dictionary and str((f as Dictionary).get("m", "")) == "game_over":
			return f as Dictionary
	return {}
