# The Annex look's check, headless: on 40 floors (look-0..9 at depths 1 to 4), every room is dressed
# exactly like every other room of the same shape (client/annex_view.gd same_shape_problems, compared
# in the canonical frame, so position plays no part). Exit code 0 when it holds.
#   "$GODOT" --headless --path godot --script res://tools/annex_look_check.gd
# The break: in annex_view.gd _dress_rooms, seed the layout by position instead of by shape, i.e.
#   layout_for(sh, str(r.kind), hash("%d,%d,%d" % [int(r.level), int(r.x), int(r.y)]))
# and this goes red (jittered plants, boxes and tables, and posters on other walls).
# It also checks (Demo.check_floors) that no floor has more real lights than the renderer draws a frame
# (AnnexView.LIGHT_LIMIT, 256), and that the Annex's blackout ambient is never red (its red no higher
# than its green) while the Clinic's stays exactly as it was. The breaks: in annex_view.gd
# _panels_and_lights, set CORRIDOR_SPACING to 4.0 (a corridor light every other cell, as before: over
# 256 on the depth-4 floors); or in dress(), drop `level.ambient_dark = AMBIENT_DARK` (the Clinic's red).
extends SceneTree

const Demo = preload("res://client/annex_demo.gd")
const AnnexView = preload("res://client/annex_view.gd")

func _init() -> void:
	var floors: Array = []
	for i in 10:
		for d in range(1, 5):
			floors.append(["look-%d" % i, d])
	var t0 := Time.get_ticks_msec()
	var r: Dictionary = Demo.check_floors(floors)
	var problems: Array = r.problems
	print("annex look check: %s, %d floors, %d shapes seen more than once, %d rooms compared, %d props and pictures, at most %d lights a floor (limit %d), %d ms" % [
		"PASS" if problems.is_empty() else "FAIL (%d problems)" % problems.size(), r.floors, r.groups, r.rooms_compared, r.props, r.max_lights, AnnexView.LIGHT_LIMIT, Time.get_ticks_msec() - t0])
	for p: String in problems.slice(0, 10):
		print("  ", p)
	quit(0 if problems.is_empty() else 1)
