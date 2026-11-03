# Wordtable tile-bag rules core (pure logic, no scene deps).
# Holds the official English 100-tile distribution, shuffles with a per-instance
# seeded RandomNumberGenerator, and deals via draw()/return_tiles().
# Run headless via res://tests/test_runner.gd (suite `bag`).
class_name TileBag
extends RefCounted

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

const BLANK_COUNT: int = 2
const BLANK_VALUE: int = 0

var _tiles: Array[Dictionary] = []


func _init(p_seed: int = 0) -> void:
	_tiles.clear()
	for row: Array in DISTRIBUTION:
		var letter: String = str(row[0])
		var count: int = int(row[1])
		var value: int = int(row[2])
		for i: int in range(count):
			_tiles.append({"letter": letter, "value": value, "is_blank": false})
	for i: int in range(BLANK_COUNT):
		_tiles.append({"letter": "", "value": BLANK_VALUE, "is_blank": true})
	var rng := RandomNumberGenerator.new()
	rng.seed = p_seed
	for i: int in range(_tiles.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var tmp: Dictionary = _tiles[i]
		_tiles[i] = _tiles[j]
		_tiles[j] = tmp


static func with_seed(p_seed: int) -> TileBag:
	return TileBag.new(p_seed)


static func letter_value(p_letter: String) -> int:
	if p_letter == "":
		return BLANK_VALUE
	for row: Array in DISTRIBUTION:
		if str(row[0]) == p_letter:
			return int(row[2])
	return 0


static func full_distribution() -> Dictionary:
	var out := {}
	for row: Array in DISTRIBUTION:
		out[str(row[0])] = {"count": int(row[1]), "value": int(row[2])}
	out[""] = {"count": BLANK_COUNT, "value": BLANK_VALUE}
	return out


func remaining() -> int:
	return _tiles.size()


func is_empty() -> bool:
	return _tiles.is_empty()


func blanks_remaining() -> int:
	var n: int = 0
	for t: Dictionary in _tiles:
		if bool(t.get("is_blank", false)):
			n += 1
	return n


func counts_by_letter() -> Dictionary:
	var out := {}
	for t: Dictionary in _tiles:
		var letter: String = str(t.get("letter", ""))
		out[letter] = int(out.get(letter, 0)) + 1
	return out


func draw(p_count: int) -> Array:
	if p_count <= 0:
		return []
	var n: int = mini(p_count, _tiles.size())
	var out: Array = []
	for i: int in range(n):
		out.append(_tiles.pop_back())
	return out


func return_tiles(p_tiles: Array) -> void:
	for t in p_tiles:
		if t is Dictionary:
			_tiles.append(t)
