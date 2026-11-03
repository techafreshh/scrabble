# Wordtable server policy helper (pure logic, no scene deps).
# Stateless constants plus static policy for the room surface: display-name
# and chat caps mirroring the client views, the NOT_YOUR_TURN gate, the
# NOT_IN_DICTIONARY -> NOT_IN_LEXICON boundary mapping, per-turn clock
# limits and deadline bookkeeping, and per-recipient frame personalization.
# RoomRegistry owns all room state and calls in here; nothing here may
# touch scenes, sockets, or the game rules directly.
# Run headless via res://tests/test_runner.gd (`--suite game_binding`).
class_name GameBinding
extends RefCounted

const TURN_SECS_ON := 90
const STALL_SECS_OFF := 180
const MAX_NAME_LEN := 16
const MAX_TEXT_LEN := 200
const NOT_YOUR_TURN := "NOT_YOUR_TURN"
const LEXICON_REASON := "NOT_IN_LEXICON"

# First present key wins (top level or inside `options`).
const TURN_SECS_ALIASES := [
	"turn_secs", "timer_secs", "turn_timeout", "timeout_secs", "turn_limit_secs",
]
const TIMER_ON_KEYS := ["timer_on"]
const TIMER_OFF_KEYS := ["timer_off"]
const TEST_MODE_KEYS := ["test_mode"]


# Trims and truncates to MAX_NAME_LEN; blank input falls back so callers
# keep their Host/Guest defaults without rejecting.
static func clean_name(raw, fallback: String = "Host") -> String:
	var s := str(raw).strip_edges().substr(0, MAX_NAME_LEN).strip_edges()
	if s == "":
		return fallback
	return s


# Trims and truncates to MAX_TEXT_LEN; blank stays blank so callers can
# still answer BAD_TEXT for empty chat.
static func clean_text(raw) -> String:
	return str(raw).strip_edges().substr(0, MAX_TEXT_LEN).strip_edges()


# Boundary mapping: the rules/facade spell it NOT_IN_DICTIONARY and their
# suites pin that spelling; only the room surface exposes NOT_IN_LEXICON.
static func map_reason(reason) -> String:
	if str(reason) == "NOT_IN_DICTIONARY":
		return LEXICON_REASON
	return str(reason)


# Reads one key from the options dict itself or from a nested `options`
# sub-dict (the probe sends timer fields both top level and nested).
static func _opt(options: Dictionary, key: String):
	if options.has(key):
		return options[key]
	var nested = options.get("options", null)
	if nested is Dictionary and (nested as Dictionary).has(key):
		return (nested as Dictionary)[key]
	return null


static func _first_present(options: Dictionary, keys: Array):
	for k in keys:
		var v = _opt(options, str(k))
		if v == null:
			continue
		if str(v).strip_edges() == "":
			continue
		return v
	return null


static func _as_bool(raw, fallback: bool) -> bool:
	if raw is bool:
		return raw
	var s := str(raw).strip_edges().to_lower()
	if s == "1" or s == "true" or s == "yes" or s == "on":
		return true
	if s == "0" or s == "false" or s == "no" or s == "off":
		return false
	return fallback


# Lobbies default to clocks on; an explicit timer_off negates it.
static func parse_timer_on(options: Dictionary) -> bool:
	var on = _first_present(options, TIMER_ON_KEYS)
	if on != null:
		return _as_bool(on, true)
	var off = _first_present(options, TIMER_OFF_KEYS)
	if off != null:
		return not _as_bool(off, false)
	return true


static func parse_test_mode(options: Dictionary) -> bool:
	var v = _first_present(options, TEST_MODE_KEYS)
	if v == null:
		return false
	return _as_bool(v, false)


# First alias hit wins, clamped 1-3600; 0 means unset (use the clock default).
static func parse_turn_secs(options: Dictionary) -> int:
	var raw = _first_present(options, TURN_SECS_ALIASES)
	if raw == null or raw is bool:
		return 0
	var v := -1
	if raw is int or raw is float:
		v = int(raw)
	elif raw is String and str(raw).strip_edges().is_valid_int():
		v = int(str(raw).strip_edges())
	else:
		return 0
	return clampi(v, 1, 3600)


# Explicit override wins, else 90 s with the clock on, else the 180 s stall guard.
static func turn_limit_secs(room: Dictionary) -> int:
	var over := int(room.get("turn_secs", 0))
	if over > 0:
		return clampi(over, 1, 3600)
	if bool(room.get("timer_on", true)):
		return TURN_SECS_ON
	return STALL_SECS_OFF


static func refresh_deadline(room: Dictionary, now_ms: int) -> void:
	room["deadline_ms"] = int(now_ms) + turn_limit_secs(room) * 1000


# A negative deadline means no clock (unstarted rooms never fire).
static func is_expired(room: Dictionary, now_ms: int) -> bool:
	var deadline := int(room.get("deadline_ms", -1))
	return deadline >= 0 and int(now_ms) >= deadline


# Per-recipient fan-out shaping: everyone gets their own rack plus a `you`
# marker; `seat` is only filled in when the frame has none, so sender-seat
# fields (chat, room_joined) are never clobbered. seat_no < 0 passes through.
static func personalize(frame: Dictionary, seat_no: int, rack: Array) -> Dictionary:
	var out: Dictionary = frame.duplicate(true)
	if seat_no < 0:
		return out
	out["rack"] = rack.duplicate()
	out["you"] = seat_no
	if not out.has("seat"):
		out["seat"] = seat_no
	return out
