extends RefCounted

const Marks = preload("res://sim/marks.gd")
const PROMPT := "HOLD F  PEEL MARK"

var mark := -1
var began_ms := -1
var fill := -1.0

func begin(id: int, now_ms: int) -> void:
	mark = id
	began_ms = now_ms
	fill = 0.0

func reset() -> void:
	mark = -1
	began_ms = -1
	fill = -1.0

## One press picks one arrow. Losing the prompt, changing aim or releasing F ends the hold.
func advance(target: int, held: bool, now_ms: int) -> int:
	if mark < 0:
		return -1
	if target != mark or not held:
		reset()
		return -1
	fill = clampf(float(now_ms - began_ms) / (1000.0 * Marks.PEEL_SECONDS), 0.0, 1.0)
	if fill < 1.0:
		return -1
	var id := mark
	reset()
	return id
