# Wordtable game state machine (pure logic, no scene deps).
# Owns turn order, pass/exchange handling, both official endings
# (bag-empty with unplayed-tile bonus, six successive scoreless turns),
# final scoring adjustments, and rematch reset.
# The state machine does NOT adjudicate legality or points (that is
# ScrabbleRules' job); it advances turns, tracks the scoreless streak,
# gates exchanges on bag size, detects endings, and resets for rematch.
# NOTE: the distribution/values table below intentionally duplicates
# TileBag's rows (see scripts/game/bag.gd) so headless runs never depend
# on other branches' merge order; a later lap may rewire onto TileBag.
# Run headless via res://tests/test_runner.gd (`--suite game_state` or full run).
class_name ScrabbleGame
extends RefCounted

const RACK_SIZE := 7
const EXCHANGE_MIN_BAG := 7
const SCORELESS_LIMIT := 6
const BLANK_COUNT := 2
const BLANK_VALUE := 0

# Official English distribution rows: [LETTER, COUNT, VALUE].
const DISTRIBUTION: Array = [
	["A", 9, 1],
	["B", 2, 3],
	["C", 2, 3],
	["D", 4, 2],
	["E", 12, 1],
	["F", 2, 4],
	["G", 3, 2],
	["H", 2, 4],
	["I", 9, 1],
	["J", 1, 8],
	["K", 1, 5],
	["L", 4, 1],
	["M", 2, 3],
	["N", 6, 1],
	["O", 8, 1],
	["P", 2, 3],
	["Q", 1, 10],
	["R", 6, 1],
	["S", 4, 1],
	["T", 6, 1],
	["U", 4, 1],
	["V", 2, 4],
	["W", 2, 4],
	["X", 1, 8],
	["Y", 2, 4],
	["Z", 1, 10],
]

const LETTER_VALUES := {
	"A": 1, "B": 3, "C": 3, "D": 2, "E": 1, "F": 4, "G": 2,
	"H": 4, "I": 1, "J": 8, "K": 5, "L": 1, "M": 3, "N": 1,
	"O": 1, "P": 3, "Q": 10, "R": 1, "S": 1, "T": 1, "U": 1,
	"V": 4, "W": 4, "X": 8, "Y": 4, "Z": 10,
}

var scores: Array[int] = []
var _bag: Array[Dictionary] = []
var _racks: Array = []
var _turn := 0
var _scoreless := 0
var _over := false
var _ending := ""
var _bonus_applied := false
var _seed := 0
var _players := 2


func _init(player_count: int = 2, p_seed: int = 0) -> void:
	_players = maxi(2, player_count)
	_seed = p_seed
	_reset()


# Rebuilds the full 100-tile bag from the construction seed, zeroes scores,
# deals fresh racks of RACK_SIZE, and clears turn/streak/over/ending/bonus.
func _reset() -> void:
	_bag.clear()
	for row: Array in DISTRIBUTION:
		var letter: String = str(row[0])
		var count: int = int(row[1])
		var value: int = int(row[2])
		for i: int in range(count):
			_bag.append({"letter": letter, "value": value, "is_blank": false})
	for i: int in range(BLANK_COUNT):
		_bag.append({"letter": "", "value": BLANK_VALUE, "is_blank": true})
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed
	for i: int in range(_bag.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var tmp: Dictionary = _bag[i]
		_bag[i] = _bag[j]
		_bag[j] = tmp
	scores.clear()
	for p: int in range(_players):
		scores.append(0)
	_racks.clear()
	for p: int in range(_players):
		var rack: Array = []
		for k: int in range(RACK_SIZE):
			if not _bag.is_empty():
				rack.append(_bag.pop_back())
		_racks.append(rack)
	_turn = 0
	_scoreless = 0
	_over = false
	_ending = ""
	_bonus_applied = false


static func letter_value(p_letter: String) -> int:
	if p_letter == "":
		return BLANK_VALUE
	return int(LETTER_VALUES.get(p_letter.strip_edges().to_upper(), 0))


func player_count() -> int:
	return _players


func current_player() -> int:
	return _turn


func bag_remaining() -> int:
	return _bag.size()


func is_over() -> bool:
	return _over


func ending() -> String:
	return _ending


func scoreless_count() -> int:
	return _scoreless


func bonus_applied() -> bool:
	return _bonus_applied


func score_of(p: int) -> int:
	if p < 0 or p >= scores.size():
		return 0
	return scores[p]


func rack_tile_count(p: int) -> int:
	if p < 0 or p >= _racks.size():
		return 0
	return (_racks[p] as Array).size()


func rack_letters(p: int) -> Array:
	var out: Array = []
	if p < 0 or p >= _racks.size():
		return out
	for t in (_racks[p] as Array):
		out.append(str((t as Dictionary).get("letter", "")))
	return out


# Test hook: replaces the whole bag with face letters ("" = blank, value 0).
func debug_set_bag(letters: Array) -> void:
	_bag.clear()
	for face in letters:
		_bag.append(_tile_for_face(str(face)))


# Test hook: replaces one player's rack with face letters ("" = blank).
func debug_set_rack(player: int, letters: Array) -> void:
	if player < 0 or player >= _racks.size():
		return
	var rack: Array = []
	for face in letters:
		rack.append(_tile_for_face(str(face)))
	_racks[player] = rack


static func _tile_for_face(face: String) -> Dictionary:
	if face == "":
		return {"letter": "", "value": BLANK_VALUE, "is_blank": true}
	var up := face.strip_edges().to_upper()
	return {"letter": up, "value": int(LETTER_VALUES.get(up, 0)), "is_blank": false}


# Removes exactly the faces listed in played_tiles from rack (verify first,
# mutate only on full success). Each entry is a bare String face ("" =
# blank) or a Dictionary with `letter` plus `blank`/`is_blank`. A blank
# entry consumes any is_blank rack tile regardless of face; a letter entry
# consumes a non-blank tile with the equal face (case/whitespace
# insensitive). Returns false on any size mismatch, malformed entry, or
# rack shortage, leaving rack untouched.
static func _remove_played_faces(rack: Array, played_tiles: Array) -> bool:
	var needed: Array = []
	for e in played_tiles:
		var letter := ""
		var blank := false
		if e is String:
			var s := str(e).strip_edges().to_upper()
			if s == "":
				blank = true
			else:
				letter = s
		elif e is Dictionary:
			var d: Dictionary = e
			var face := str(d.get("letter", "")).strip_edges().to_upper()
			blank = bool(d.get("blank", d.get("is_blank", face == "")))
			if not blank:
				if face == "":
					return false
				letter = face
			else:
				letter = face
		else:
			return false
		needed.append({"letter": letter, "blank": blank})
	var avail: Array = []
	for i: int in range(rack.size()):
		avail.append(i)
	var used: Array = []
	for n in needed:
		var need_blank := bool((n as Dictionary).get("blank", false))
		var need_letter := str((n as Dictionary).get("letter", ""))
		var found := -1
		for idx in avail:
			var t: Dictionary = rack[int(idx)] as Dictionary
			var tile_blank := bool(t.get("is_blank", false))
			if need_blank and tile_blank:
				found = int(idx)
				break
			if not need_blank and not tile_blank and str(t.get("letter", "")) == need_letter:
				found = int(idx)
				break
		if found == -1:
			return false
		avail.erase(found)
		used.append(found)
	used.sort()
	used.reverse()
	for idx in used:
		rack.remove_at(int(idx))
	return true


# Scoring move by the current player: banks points, removes exactly the
# faces in played_tiles (blank-aware exact-tile removal), refills to
# RACK_SIZE, resets the scoreless streak, then checks the bag-empty
# ending before advancing the turn. played_tiles is required: a
# count-only call (empty/missing faces), a size mismatch with
# tiles_played, or faces the rack cannot cover rejects BAD_PLAY with
# scores/bag/turn untouched.
func record_score(points: int, tiles_played: int, played_tiles: Array = []) -> Dictionary:
	if _over:
		return {"ok": false, "reason": "GAME_OVER", "over": _over, "ending": _ending}
	var me := _turn
	var rack: Array = _racks[me] as Array
	if points < 0 or tiles_played <= 0 or tiles_played > rack.size():
		return {"ok": false, "reason": "BAD_PLAY", "over": _over, "ending": _ending}
	if played_tiles.is_empty():
		return {"ok": false, "reason": "BAD_PLAY", "over": _over, "ending": _ending}
	if played_tiles.size() != tiles_played:
		return {"ok": false, "reason": "BAD_PLAY", "over": _over, "ending": _ending}
	if not _remove_played_faces(rack, played_tiles):
		return {"ok": false, "reason": "BAD_PLAY", "over": _over, "ending": _ending}
	scores[me] += points
	while rack.size() < RACK_SIZE and not _bag.is_empty():
		rack.append(_bag.pop_back())
	_scoreless = 0
	if _bag.is_empty() and rack.is_empty():
		_finish_bag_empty()
	_turn = (_turn + 1) % _players
	return {"ok": true, "over": _over, "ending": _ending}


# Scoreless turn: bumps the streak, ends the game at SCORELESS_LIMIT.
func pass_turn() -> Dictionary:
	if _over:
		return {"ok": false, "reason": "GAME_OVER", "over": _over, "ending": _ending}
	_scoreless += 1
	if _scoreless >= SCORELESS_LIMIT:
		_finish_scoreless()
	_turn = (_turn + 1) % _players
	return {"ok": true, "over": _over, "ending": _ending}


# Tile exchange by the current player. Rejected (nothing touched) when the
# bag holds fewer than EXCHANGE_MIN_BAG tiles or the count is out of range.
# Success draws replacements first, then returns the old tiles, so the
# requester can never redraw their own tiles and the bag size is unchanged.
func exchange(count: int) -> Dictionary:
	if _over:
		return {"ok": false, "reason": "GAME_OVER", "over": _over, "ending": _ending}
	if bag_remaining() < EXCHANGE_MIN_BAG:
		return {"ok": false, "reason": "BAG_TOO_SMALL", "over": _over, "ending": _ending}
	var me := _turn
	var rack: Array = _racks[me] as Array
	if count <= 0 or count > rack.size():
		return {"ok": false, "reason": "BAD_COUNT", "over": _over, "ending": _ending}
	var drawn: Array = []
	for i: int in range(count):
		drawn.append(_bag.pop_back())
	var old: Array = []
	for i: int in range(count):
		old.append(rack.pop_front())
	for t in drawn:
		rack.append(t)
	for t in old:
		_bag.append(t)
	_scoreless += 1
	if _scoreless >= SCORELESS_LIMIT:
		_finish_scoreless()
	_turn = (_turn + 1) % _players
	return {"ok": true, "over": _over, "ending": _ending}


func _unplayed_value(p: int) -> int:
	var total := 0
	if p < 0 or p >= _racks.size():
		return total
	for t in (_racks[p] as Array):
		total += int((t as Dictionary).get("value", 0))
	return total


# Bag-empty ending: the just-moved player went out; they gain the sum of
# all opponents' unplayed tile values, each opponent deducts their own.
func _finish_bag_empty() -> void:
	var winner := _turn
	var bonus := 0
	for p: int in range(_players):
		if p != winner:
			bonus += _unplayed_value(p)
	scores[winner] += bonus
	for p: int in range(_players):
		if p != winner:
			scores[p] -= _unplayed_value(p)
	_bonus_applied = true
	_over = true
	_ending = "bag_empty"


# Six-scoreless ending: every player deducts only their own unplayed tiles.
func _finish_scoreless() -> void:
	for p: int in range(_players):
		scores[p] -= _unplayed_value(p)
	_over = true
	_ending = "six_scoreless"


# Deterministic reset reusing the construction seed: same bag order, fresh
# racks, zeroed scores, cleared turn/streak/over/ending/bonus.
func rematch() -> void:
	_reset()
