# Wordtable network client (autoloaded as `Net`, no scene deps beyond views).
# Raw-WebSocketPeer text frames with one JSON object per frame
# ({v:1, m:<method>}) — mirroring how scripts/server/server.gd drains
# peers — because that is the wire format the room server actually speaks.
#
# Owns the socket, an outbound queue (flushed once OPEN), the room
# identity (code/token/seat), a received-frame log for scripts/tests, and
# a bus: EventBus reference (adopts /root/Bus when present, else
# self-creates so headless suites stay isolated). Every inbound frame is
# delegated to bus.apply_server_frame; a place_tiles reply carrying
# accepted == false additionally bounce-clears the bound views via
# CommitFx duck-typing. The client never validates: tiles_for_commit only
# ships staged squares, never the full rack (privacy by construction).
#
# Run headless via res://tests/test_runner.gd (`--suite net_client`).
class_name NetClient
extends Node

const DEFAULT_URL := "ws://localhost:9080"
const PROTOCOL_VERSION := 1
const RECEIVED_CAP := 128

var bus: EventBus
var code := ""
var token := ""
var seat := -1
var last_reply := {}
var received: Array = []
var last_error := ""

var _overlay = null
var _reconnecting := false
var _reconnect_attempt := 0
var _reconnect_due_ms := -1
var _rejoin_pending := false
var _rejoin_sent_ms := 0
var _before_snap := {}

var _ws: WebSocketPeer
var _outbox: Array = []
var _board_view = null
var _placement = null


func _ready() -> void:
	if _ws == null:
		_ws = WebSocketPeer.new()
	if bus != null:
		return
	# Absolute lookups only resolve inside the active tree (autoload order
	# guarantees /root/Bus already exists in the real game); headless
	# `-s` suites never reach _ready and self-create via _ensure_ready.
	var shared := get_node_or_null("/root/Bus")
	if shared is EventBus:
		bus = shared
	else:
		_ensure_bus()


# Precedence mirrors server.gd: `--server-url=` args > WORDTABLE_SERVER_URL
# env > DEFAULT_URL.
static func resolve_url() -> String:
	for arg in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if arg.begins_with("--server-url="):
			var u := arg.get_slice("=", 1).strip_edges()
			if u != "":
				return u
	var env := OS.get_environment("WORDTABLE_SERVER_URL").strip_edges()
	if env != "":
		return env
	return DEFAULT_URL


func connect_to_server(url := "") -> Error:
	_ensure_ready()
	var target := url.strip_edges() if url.strip_edges() != "" else resolve_url()
	var err := _ws.connect_to_url(target)
	if err != OK:
		last_error = "connect failed: %s" % err
	return err


func is_open() -> bool:
	return _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN


func disconnect_from_server() -> void:
	_outbox.clear()
	if _ws != null:
		_ws.close()


func _process(_delta: float) -> void:
	poll()


# Handshake completion plus the server-style drain loop: first parse
# `ping` (ignored — the server never pings), then `{`-frames go to
# JSON.parse_string and on to handle_frame. Never raises on inbound bytes.
# A closed socket starts the reconnect episode (overlay plus backoff
# timer); the timer ticks on every poll path so a redial fires even while
# the peer sits in CLOSING.
func poll() -> void:
	_ensure_ready()
	if _ws == null:
		return
	var state := _ws.get_ready_state()
	if state == WebSocketPeer.STATE_CLOSED:
		_on_socket_lost()
		_tick_reconnect()
		return
	if state == WebSocketPeer.STATE_CLOSING:
		# The closing handshake only completes while polled; without this
		# a disconnect()ed peer never reaches CLOSED and never redials.
		_ws.poll()
		if _ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			_on_socket_lost()
		_tick_reconnect()
		return
	if state != WebSocketPeer.STATE_OPEN and state != WebSocketPeer.STATE_CONNECTING:
		_tick_reconnect()
		return
	_ws.poll()
	var after := _ws.get_ready_state()
	if after == WebSocketPeer.STATE_CLOSED:
		_on_socket_lost()
		_tick_reconnect()
		return
	if after != WebSocketPeer.STATE_OPEN:
		_tick_reconnect()
		return
	_flush()
	_drain()
	_tick_reconnect()


# _ready does not run for nodes added during SceneTree._initialize in
# `-s` script mode, so every entry point re-ensures socket and bus here.
func _ensure_ready() -> void:
	if _ws == null:
		_ws = WebSocketPeer.new()
	_ensure_bus()


func _ensure_bus() -> void:
	if bus != null:
		return
	bus = EventBus.new()
	add_child(bus)


# One inbound server frame: logged, identity captured from ok-replies
# only (broadcasts carry sender-seat fields that must not clobber our
# seat), delegated to the bus, and bounced on place rejects.
func handle_frame(frame: Dictionary) -> String:
	received.append(frame)
	while received.size() > RECEIVED_CAP:
		received.pop_front()
	last_reply = frame
	_ensure_ready()
	if bool(frame.get("ok", false)):
		if frame.has("code") and str(frame.get("code", "")) != "":
			code = str(frame.get("code", ""))
		if frame.has("token") and str(frame.get("token", "")) != "":
			token = str(frame.get("token", ""))
		if frame.has("seat"):
			seat = int(frame.get("seat"))
		elif frame.has("you"):
			seat = int(frame.get("you"))
		if code != "" and token != "":
			ReconnectOverlay.save_session(code, token)
	if bus == null:
		return "no_bus"
	var route := bus.apply_server_frame(frame)
	if route == "reject" and str(frame.get("m", "")) in ["place_tiles", "place"]:
		if _board_view != null:
			CommitFx.new().bounce(_board_view, _placement)
	if str(frame.get("m", "")) in ["rejoin", "resync"]:
		_on_resync_frame(frame)
	return route


# Remembers the P2 view doubles a commit rejects bounce back into.
func bind_views(board_view, placement = null) -> void:
	_board_view = board_view
	_placement = placement


# The overlay shell for the reconnect episode (duck-typed: the client
# works headless with none bound and still prints the markers).
func bind_overlay(overlay) -> void:
	_overlay = overlay
	if _overlay != null and _overlay.has_method("bind_net"):
		_overlay.call("bind_net", self)


# Immediate rejoin with the stored identity: snapshots first (when no
# episode snapshot exists yet), redials a dead socket, and queues the
# rejoin so the flush sends it the moment the socket is open. The Retry
# button and the backoff timer both funnel through here.
func rejoin_room() -> void:
	_ensure_ready()
	if code == "" or token == "":
		return
	if _before_snap.is_empty():
		_before_snap = _take_snapshot()
	if not _reconnecting:
		_reconnecting = true
		_reconnect_attempt = 1
	_show_overlay("manual")
	if not is_open() and _ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		connect_to_server()
	_rejoin_pending = true
	_rejoin_sent_ms = int(Time.get_ticks_msec())
	_send({"v": PROTOCOL_VERSION, "m": "rejoin", "code": code, "token": token})
	_reconnect_attempt += 1
	_arm_reconnect()


# Current bus state plus the last broadcast board: the before half of the
# resync comparison. Duck-typed so nothing here assumes overlay presence.
func _take_snapshot() -> Dictionary:
	var snap := {"rack": [], "scores": [], "board_tiles": []}
	if bus == null:
		return snap
	if bus.has_method("get_rack"):
		snap["rack"] = bus.call("get_rack")
	if bus.has_method("get_scores"):
		snap["scores"] = bus.call("get_scores")
	if bus.has_method("get_board_tiles"):
		snap["board_tiles"] = bus.call("get_board_tiles")
	return snap


func _show_overlay(reason: String) -> void:
	if _overlay != null and _overlay.has_method("show_overlay"):
		_overlay.call("show_overlay", reason)
	else:
		print("overlay=Reconnecting")


func _hide_overlay() -> void:
	if _overlay != null and _overlay.has_method("hide_overlay"):
		_overlay.call("hide_overlay")


func _overlay_visible() -> bool:
	if _overlay == null:
		return _reconnecting
	if _overlay.has_method("is_showing"):
		return bool(_overlay.call("is_showing"))
	return bool(_overlay.get("visible"))


func _stop_reconnect() -> void:
	_reconnecting = false
	_reconnect_attempt = 0
	_reconnect_due_ms = -1
	_rejoin_pending = false
	_hide_overlay()


func _arm_reconnect() -> void:
	_reconnect_due_ms = int(Time.get_ticks_msec()) + ReconnectOverlay.compute_delay_ms(_reconnect_attempt)


# Episode start on a dead socket: snapshot once, show the overlay, and arm
# the first backoff step. No-ops while open, without identity, or when an
# episode already runs, so every poll can call it unconditionally.
func _on_socket_lost() -> void:
	if is_open():
		return
	if code == "" or token == "":
		return
	if _reconnecting:
		return
	_reconnecting = true
	_reconnect_attempt = 1
	_before_snap = _take_snapshot()
	_show_overlay("closed")
	_arm_reconnect()


# One backoff step: redial a dead socket, send the rejoin once open, and
# re-arm while the reply is in flight. Stops itself when the identity is
# gone (nothing left to rejoin with).
func _tick_reconnect() -> void:
	if not _reconnecting:
		return
	if _reconnect_due_ms >= 0 and int(Time.get_ticks_msec()) < _reconnect_due_ms:
		return
	_reconnect_due_ms = -1
	if code == "" or token == "":
		_stop_reconnect()
		return
	if _rejoin_pending and is_open():
		_reconnect_attempt += 1
		_arm_reconnect()
		return
	if _rejoin_pending:
		# A reply can never arrive on a dead socket: drop the flag so the
		# arm below redials and resends instead of waiting on it.
		_rejoin_pending = false
	if not is_open():
		if _ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			connect_to_server()
		_reconnect_attempt += 1
		_arm_reconnect()
		return
	rejoin_room()


# Settles the episode: on ok, measures the round trip, compares the
# snapshot, prints the resync markers, and hides the overlay; on error
# (e.g. BAD_TOKEN) stops retrying so a wrong token cannot spin forever.
func _on_resync_frame(frame: Dictionary) -> void:
	if not _rejoin_pending:
		return
	_rejoin_pending = false
	if not bool(frame.get("ok", false)):
		_before_snap = {}
		_stop_reconnect()
		return
	var ms := int(Time.get_ticks_msec()) - _rejoin_sent_ms
	print("resync_ms=%d" % ms)
	var after := {
		"rack": frame.get("rack", []),
		"scores": frame.get("scores", []),
		"board_tiles": frame.get("board_tiles", []),
	}
	var same := ReconnectOverlay.compare_snapshots(_before_snap, after)
	print("resync_identical=" + ("true" if same else "false"))
	_before_snap = {}
	_stop_reconnect()


# Only staged squares go on the wire: [{square, letter, blank,
# blank_as}]. Slot indices and unplaced rack faces never leave the client.
static func tiles_for_commit(pendings: Array) -> Array:
	var out: Array = []
	for p in pendings:
		if not (p is Dictionary):
			continue
		var d: Dictionary = p
		var sq := ScrabbleBoard.cell_to_square(int(d.get("col", -1)), int(d.get("row", -1)))
		if sq == "":
			continue
		var face := str(d.get("letter", "")).strip_edges().to_upper()
		var blank := bool(d.get("blank", false))
		out.append({
			"square": sq,
			"letter": face,
			"blank": blank,
			"blank_as": face if blank else "",
		})
	return out


func create_room(player_name: String, test_mode := false, timer_on := true) -> void:
	var opts := {"test_mode": test_mode, "timer_on": timer_on}
	_send({
		"v": PROTOCOL_VERSION, "m": "create_room",
		"name": GameBinding.clean_name(player_name, "Host"),
		"test_mode": test_mode, "timer_on": timer_on, "options": opts,
	})


func join_room(room_code: String, player_name: String) -> void:
	_send({
		"v": PROTOCOL_VERSION, "m": "join_room",
		"code": room_code.strip_edges().to_upper(),
		"name": GameBinding.clean_name(player_name, "Guest"),
	})


func start_game() -> void:
	_send({"v": PROTOCOL_VERSION, "m": "start_game", "code": code, "token": token})


func rematch_room() -> void:
	_send({"v": PROTOCOL_VERSION, "m": "rematch", "code": code, "token": token})


# Rematch view binding (bind_overlay idiom): connects rematch_requested
# to rematch_room only when the view actually offers that signal.
func bind_rematch(view) -> void:
	if view == null:
		return
	if view.has_signal("rematch_requested") \
			and not view.is_connected("rematch_requested", rematch_room):
		view.connect("rematch_requested", rematch_room)


func place_tiles(tiles: Array) -> void:
	_send({"v": PROTOCOL_VERSION, "m": "place_tiles", "code": code, "token": token, "tiles": tiles})


func exchange_count(count: int) -> void:
	_send({"v": PROTOCOL_VERSION, "m": "exchange", "code": code, "token": token, "count": count})


func pass_turn() -> void:
	_send({"v": PROTOCOL_VERSION, "m": "pass", "code": code, "token": token})


func recall() -> void:
	_send({"v": PROTOCOL_VERSION, "m": "recall", "code": code, "token": token})


func shuffle_rack() -> void:
	_send({"v": PROTOCOL_VERSION, "m": "shuffle_rack", "code": code, "token": token})


func request_rack() -> void:
	_send({"v": PROTOCOL_VERSION, "m": "get_rack", "code": code, "token": token})


func send_chat(text: String) -> bool:
	var clean := GameBinding.clean_text(text)
	if clean == "":
		return false
	_send({"v": PROTOCOL_VERSION, "m": "chat", "code": code, "token": token, "text": clean})
	return true


func send_emote(text: String) -> bool:
	var clean := GameBinding.clean_text(text)
	if clean == "":
		return false
	_send({"v": PROTOCOL_VERSION, "m": "emote", "code": code, "token": token, "text": clean})
	return true


func debug_set_rack(seat_no: int, tiles: Array) -> void:
	_send({"v": PROTOCOL_VERSION, "m": "debug_set_rack", "code": code, "token": token, "seat": seat_no, "tiles": tiles})


func debug_set_bag(tiles: Array) -> void:
	_send({"v": PROTOCOL_VERSION, "m": "debug_set_bag", "code": code, "token": token, "tiles": tiles})


func _send(payload: Dictionary) -> void:
	payload["v"] = PROTOCOL_VERSION
	var text := JSON.stringify(payload)
	if is_open():
		var err := _ws.send_text(text)
		if err != OK:
			last_error = "send failed: %s" % err
			_outbox.append(text)
	else:
		_outbox.append(text)


func _flush() -> void:
	while is_open() and not _outbox.is_empty():
		var text := str(_outbox[0])
		var err := _ws.send_text(text)
		if err != OK:
			last_error = "flush failed: %s" % err
			_on_socket_lost()
			return
		_outbox.pop_front()


func _drain() -> void:
	while _ws.get_available_packet_count() > 0:
		var packet := _ws.get_packet()
		if not _ws.was_string_packet():
			continue
		_handle_text(packet.get_string_from_utf8())


func _handle_text(text: String) -> void:
	if text.strip_edges().to_lower() == "ping":
		return
	if not text.strip_edges().begins_with("{"):
		return
	var parsed = JSON.parse_string(text)
	if parsed is Dictionary:
		handle_frame(parsed as Dictionary)
