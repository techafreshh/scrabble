# Wordtable dev/health WebSocket server (walking skeleton).
# Listens on DEFAULT_PORT (overridable via `--port=NNNN` user arg or `PORT`
# env var) and answers a bare text `ping` frame with a text `PONG` frame.
# All other frames are ignored; inbound data is untrusted and never crashes us.
extends Node

const DEFAULT_PORT := 9080

var _tcp := TCPServer.new()
var _peers: Array[WebSocketPeer] = []
var _port := DEFAULT_PORT
var _rooms: RoomRegistry
var _lexicon = null


func _ready() -> void:
	_port = _resolve_port()
	_load_lexicon()
	_rooms = RoomRegistry.new(_lexicon)
	var err := _tcp.listen(_port)
	if err != OK:
		push_error("Wordtable server failed to listen on %d: %s" % [_port, err])
		return
	print("Wordtable server listening on %d" % _port)


# Shared lexicon for every room's LocalGame. When the bundled file is
# missing the server still boots with a null lexicon (word check skipped,
# all other rules enforced) instead of refusing connections.
func _load_lexicon() -> void:
	var dict := WordDictionary.new()
	var count: int = dict.load_from_path(WordDictionary.DEFAULT_PATH)
	if count > 0:
		_lexicon = dict
	else:
		_lexicon = null
		push_error("Wordtable server running without a lexicon (word check skipped)")


func _process(_delta: float) -> void:
	if not _tcp.is_listening():
		return
	while _tcp.is_connection_available():
		var stream := _tcp.take_connection()
		var ws := WebSocketPeer.new()
		var err := ws.accept_stream(stream)
		if err != OK:
			push_error("Wordtable server rejected a connection: %s" % err)
			continue
		_peers.append(ws)
	for i in range(_peers.size() - 1, -1, -1):
		var ws := _peers[i]
		ws.poll()
		var state := ws.get_ready_state()
		if state == WebSocketPeer.STATE_CLOSED:
			_peers.remove_at(i)
		elif state == WebSocketPeer.STATE_OPEN:
			_drain(ws)


# Port precedence: `--port=NNNN` (user or engine args) > `PORT` env > default.
func _resolve_port() -> int:
	for arg in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if arg.begins_with("--port="):
			var parsed := int(arg.get_slice("=", 1))
			if parsed > 0 and parsed <= 65535:
				return parsed
	var env := OS.get_environment("PORT")
	if env != "":
		var parsed_env := int(env)
		if parsed_env > 0 and parsed_env <= 65535:
			return parsed_env
	return DEFAULT_PORT


# A frame counts as ping when it is text and trims (case-insensitively) to
# exactly `ping`. Anything else — binary, garbage, other text — gets no reply.
static func is_ping_text(text: String) -> bool:
	return text.strip_edges().to_lower() == "ping"


func _drain(ws: WebSocketPeer) -> void:
	while ws.get_available_packet_count() > 0:
		var packet := ws.get_packet()
		var is_text := ws.was_string_packet()
		if not is_text:
			continue
		_handle_text(ws, packet.get_string_from_utf8())


# One JSON object per text frame, UTF-8. The bare `ping` path stays
# byte-identical; frames starting with `{` go to the RPC dispatcher; any
# other text is ignored. No inbound bytes may raise: parse failures get a
# BAD_JSON reply and the connection stays open.
func _handle_text(ws: WebSocketPeer, text: String) -> void:
	if is_ping_text(text):
		var ping_err := ws.send_text("PONG")
		if ping_err != OK:
			push_error("Wordtable server failed to send PONG: %s" % ping_err)
		return
	if not text.strip_edges().begins_with("{"):
		return
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		_send_dict(ws, {"m": "error", "ok": false, "error": "BAD_JSON", "reason": "BAD_JSON"})
		return
	if _rooms == null:
		_send_dict(ws, {"m": "error", "ok": false, "error": "BAD_STATE", "reason": "BAD_STATE"})
		return
	var frames: Array = _rooms.handle_dict(parsed as Dictionary)
	for frame in frames:
		if frame is Dictionary:
			_send_dict(ws, frame)


func _send_dict(ws: WebSocketPeer, reply: Dictionary) -> void:
	var err := ws.send_text(JSON.stringify(reply))
	if err != OK:
		push_error("Wordtable server failed to send JSON reply: %s" % err)
