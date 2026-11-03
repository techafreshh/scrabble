# Wordtable commit feedback: thunk + score-fly on legal, bounce-back on illegal.
#
# The unmistakable commit verdict: a legal commit plays a thunk and flies the
# score, an illegal commit bounces staged tiles back to the rack with inline
# text `Not in my book: WORD`. All verdicts stay local via ScrabbleRules;
# networking comes later.
#
# Entry points:
# - CommitFx.fx_for(result) -> String ("thunk,score_fly" when result.ok).
# - CommitFx.reject_text_for(result) -> String (prefix + reason_word on
#   NOT_IN_DICTIONARY, else "").
# - play_commit() -> bool (delegates to SoundBank.play("thunk")).
# - bounce(board_view, controller=null): clears BoardView pending state
#   (duck-typed clear_pending) and recalls rack slots (duck-typed recall).
#
# Run headless via res://tests/test_runner.gd (suite `blank_feedback`).
class_name CommitFx
extends RefCounted

const REJECT_PREFIX := "Not in my book: "
const COMMIT_FX := "thunk,score_fly"


static func fx_for(result: Dictionary) -> String:
	if bool(result.get("ok", false)):
		return COMMIT_FX
	return ""


static func reject_text_for(result: Dictionary) -> String:
	if bool(result.get("ok", false)):
		return ""
	if str(result.get("reason", "")) == ScrabbleRules.REASON_NOT_IN_DICTIONARY:
		return REJECT_PREFIX + str(result.get("reason_word", ""))
	return ""


func play_commit() -> bool:
	return SoundBank.new().play("thunk")


func play_win() -> bool:
	return SoundBank.new().play("fanfare")


func bounce(board_view, controller = null) -> void:
	if board_view != null and (board_view as Object).has_method("clear_pending"):
		(board_view as Object).call("clear_pending")
	if controller != null and (controller as Object).has_method("recall"):
		(controller as Object).call("recall")
