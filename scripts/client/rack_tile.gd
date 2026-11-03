# Rack tile: one slot button, drag source plus tap path.
#
# A single rack slot: shows its face letter (or "□" for an unassigned blank,
# empty text when the slot holds no tile) and acts as a drag source whose
# payload is a Dictionary {slot, letter, is_blank}. The tap path is the
# Button `pressed` signal, left for RackView to connect -- exactly like
# BoardView binds `pressed` per cell.
class_name RackTile
extends Button

var slot_idx := -1
var letter := ""
var is_blank := false


func set_face(p_letter: String, p_is_blank: bool = false) -> void:
	letter = p_letter.strip_edges().to_upper()
	is_blank = p_is_blank
	if letter == "" and is_blank:
		text = "□"
	else:
		text = letter


func _get_drag_data(_at: Vector2) -> Variant:
	return {"slot": slot_idx, "letter": letter, "is_blank": is_blank}
