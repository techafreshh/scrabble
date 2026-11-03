# Wordtable dev/health WebSocket server (walking skeleton).
# Listens on DEFAULT_PORT (overridable via `--port=NNNN` user arg or `PORT`
# env var) and answers a bare text `ping` frame with a text `PONG` frame.
# All other frames are ignored; inbound data is untrusted and never crashes us.
extends Node

const DEFAULT_PORT := 9080

var _tcp := TCPServer.new()
var _peers: Array[WebSocketPeer] = []
var _port := DEFAULT_PORT


func _ready() -> void:
	_port = _resolve_port()
	var err := _tcp.listen(_port)
	if err != OK:
		push_error("Wordtable server failed to listen on %d: %s" % [_port, err])
		return
	print("Wordtable server listening on %d" % _port)


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
		if is_ping_text(packet.get_string_from_utf8()):
			ws.send_text("PONG")
