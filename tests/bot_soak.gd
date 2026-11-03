# Wordtable bot-vs-bot soak (standalone SceneTree driver, no server needed).
# Proves long-game correctness headless: it loops seeded 2-bot LocalGames
# through the single BotSeat.choose_move seam (ScrabbleBot greedy oracle),
# committing place or recall+pass_turn with zero think delay, and counts any
# referee mismatch, tile-conservation break, or missing recap as an illegal
# state. Run from the repo root:
# godot --headless --path . -s res://tests/bot_soak.gd --games 20
# Prints the acceptance markers soak_games=/soak_recaps=/illegal_states=
# and exits 0 only when every game completed with zero illegal states.
extends SceneTree

const DEFAULT_GAMES := 20
const DEFAULT_SEED := 1234
const HALF_MOVE_CAP := 500
const TILE_TOTAL := 100
# Per-move generation budget for the soak only (live rooms keep the 250 ms
# BotSeat default): the oracle validates every candidate, so a smaller
# budget keeps the 20-game soak fast without risking any illegal state.
const SOAK_BUDGET_MS := 50

# Small built-in word list used only when the bundled SOWPODS lexicon is
# missing; wide 2-letter coverage so random racks can almost always move.
const FALLBACK_WORDS := [
	"AA", "AB", "AD", "AE", "AG", "AH", "AI", "AL", "AM", "AN", "AR", "AS",
	"AT", "AW", "AX", "AY", "BA", "BE", "BI", "BO", "BY", "DA", "DE", "DO",
	"ED", "EF", "EH", "EL", "EM", "EN", "ER", "ES", "ET", "EX", "FA", "FE",
	"GO", "HA", "HE", "HI", "ID", "IF", "IN", "IS", "IT", "JO", "KA", "LA",
	"LI", "LO", "MA", "ME", "MI", "MO", "MU", "MY", "NA", "NE", "NO", "NU",
	"OD", "OE", "OF", "OH", "OI", "OK", "ON", "OP", "OR", "OS", "OW", "OX",
	"OY", "PA", "PE", "PI", "QI", "RE", "SH", "SI", "SO", "TA", "TI", "TO",
	"UH", "UM", "UN", "UP", "US", "UT", "WE", "WO", "XI", "XU", "YA", "YE",
	"YO", "ZA", "CAT", "CATS", "DOG", "TE", "CO", "OXE",
]


# Minimal lexicon double over a word list (duck-typed via is_word).
class FallbackLexicon extends RefCounted:
	var _words: Dictionary = {}

	func _init(word_list: Array = []) -> void:
		for w in word_list:
			_words[str(w).strip_edges().to_upper()] = true

	func is_word(raw: String) -> bool:
		var w := str(raw).strip_edges().to_upper()
		if w.is_empty():
			return false
		return _words.has(w)


var _illegal := 0
var _recaps := 0


func _initialize() -> void:
	var games := _parse_int_arg("games", DEFAULT_GAMES)
	var base_seed := _parse_int_arg("seed", DEFAULT_SEED)
	if games < 1:
		games = 1
	var lexicon = _load_lexicon()
	var completed := 0
	for i in range(games):
		if _run_game(base_seed + i, lexicon):
			completed += 1
	print("soak_games=%d" % games)
	print("soak_recaps=%d" % _recaps)
	print("illegal_states=%d" % _illegal)
	var ok := completed == games and _recaps == games and _illegal == 0
	quit(0 if ok else 1)


func _run_game(game_seed: int, lexicon) -> bool:
	var game := LocalGame.new(2, game_seed, lexicon)
	var over := false
	for half in range(HALF_MOVE_CAP):
		if game.is_over():
			over = true
			break
		var turn := game.current_player()
		var rack: Array = game.rack_letters(turn)
		var mv: Dictionary = BotSeat.choose_move(
			game.board, rack, lexicon, game_seed + half, SOAK_BUDGET_MS
		)
		if bool(mv.get("ok", false)):
			var res: Dictionary = game.place(
				mv.get("placements", []), mv.get("blank_map", {})
			)
			if not bool(res.get("ok", false)):
				_illegal += 1
				push_error("bot_soak: referee mismatch game=%d half=%d" % [game_seed, half])
				game.recall()
				game.pass_turn()
		else:
			game.recall()
			game.pass_turn()
		if not _conserved(game):
			_illegal += 1
			push_error("bot_soak: tile break game=%d half=%d" % [game_seed, half])
		if game.is_over():
			over = true
			break
	if not over or not game.is_over():
		push_error("bot_soak: cap exceeded game=%d" % game_seed)
		return false
	if str(game.ending()) == "" or game.history().is_empty():
		push_error("bot_soak: missing recap game=%d" % game_seed)
		return false
	if not _conserved(game):
		_illegal += 1
		push_error("bot_soak: final tile break game=%d" % game_seed)
		return false
	_recaps += 1
	return true


func _conserved(game: LocalGame) -> bool:
	var total := game.board_tiles().size() + game.bag_remaining()
	for p in range(game.player_count()):
		total += game.rack_letters(p).size()
	return total == TILE_TOTAL


func _load_lexicon():
	var dict := WordDictionary.new()
	var count := 0
	if FileAccess.file_exists(WordDictionary.DEFAULT_PATH):
		count = dict.load_from_path(WordDictionary.DEFAULT_PATH)
	if count > 0:
		return dict
	return FallbackLexicon.new(FALLBACK_WORDS)


func _parse_int_arg(key: String, fallback: int) -> int:
	var args := OS.get_cmdline_user_args()
	args.append_array(OS.get_cmdline_args())
	for i in range(args.size()):
		var s := str(args[i]).strip_edges()
		if s == "--" + key and i + 1 < args.size():
			var nxt := str(args[i + 1]).strip_edges()
			if nxt.is_valid_int():
				return int(nxt)
		if s.begins_with("--" + key + "="):
			var val := s.get_slice("=", 1).strip_edges()
			if val.is_valid_int():
				return int(val)
	return fallback
