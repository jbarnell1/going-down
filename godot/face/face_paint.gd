# The picture being drawn: a square of colour indices, the brush, the bucket, undo, and the starting
# faces. No drawing on screen and no input here (face_editor.gd does that), so tests can paint.
# Coordinates are in cells, continuous: (0, 0) is the top-left corner of the top-left cell and the
# centre of cell (x, y) is (x + 0.5, y + 0.5).
class_name FacePaint
extends RefCounted

const UNDO_MAX := 64
const STARTERS: Array[String] = ["smile", "frown", "shock"]

var side := 32
var px := PackedByteArray()
var _undo: Array[PackedByteArray] = []
var _before := PackedByteArray()     # the picture when the current stroke began
var _in_stroke := false

func _init(cells := 32) -> void:
	side = cells
	px.resize(side * side)
	px.fill(0)

func at(x: int, y: int) -> int:
	if x < 0 or y < 0 or x >= side or y >= side:
		return -1
	return px[y * side + x]

func put(x: int, y: int, c: int) -> void:
	if x >= 0 and y >= 0 and x < side and y < side:
		px[y * side + x] = c

## Replaces the whole picture (as one undo step). False if `indices` is the wrong size.
func set_all(indices: PackedByteArray) -> bool:
	if indices.size() != side * side:
		return false
	_change_begin()
	px = indices.duplicate()
	_change_end()
	return true

func clear(c := 0) -> void:
	_change_begin()
	px.fill(c)
	_change_end()

func can_undo() -> bool:
	return not _undo.is_empty()

func undo() -> bool:
	if _undo.is_empty():
		return false
	px = _undo.pop_back()
	return true

## Undo history is per drawing session: a loaded face starts with none.
func forget_undo() -> void:
	_undo.clear()

# --- strokes ---------------------------------------------------------------------------------------

func stroke_begin() -> void:
	_change_begin()
	_in_stroke = true

func stroke_end() -> void:
	if _in_stroke:
		_in_stroke = false
		_change_end()

## A round dab of `diameter` cells centred on `p`; the cell under `p` is always painted.
func dab(p: Vector2, diameter: float, c: int) -> void:
	var r := maxf(diameter * 0.5, 0.5)
	var r2 := r * r + 0.01
	for y in range(int(floor(p.y - r)), int(ceil(p.y + r)) + 1):
		for x in range(int(floor(p.x - r)), int(ceil(p.x + r)) + 1):
			var dx := x + 0.5 - p.x
			var dy := y + 0.5 - p.y
			if dx * dx + dy * dy <= r2:
				put(x, y, c)
	put(int(floor(p.x)), int(floor(p.y)), c)

func line(a: Vector2, b: Vector2, diameter: float, c: int) -> void:
	var n := maxi(1, int(ceil(a.distance_to(b) / 0.25)))
	for i in n + 1:
		dab(a.lerp(b, float(i) / n), diameter, c)

## The bucket: fills the 4-connected area of one colour under `cell` (one undo step).
func fill(cell: Vector2i, c: int) -> void:
	var from := at(cell.x, cell.y)
	if from < 0 or from == c:
		return
	_change_begin()
	var todo: Array[Vector2i] = [cell]
	while not todo.is_empty():
		var q: Vector2i = todo.pop_back()
		if at(q.x, q.y) != from:
			continue
		put(q.x, q.y, c)
		todo.append(q + Vector2i(1, 0))
		todo.append(q + Vector2i(-1, 0))
		todo.append(q + Vector2i(0, 1))
		todo.append(q + Vector2i(0, -1))
	_change_end()

func _change_begin() -> void:
	if not _in_stroke:
		_before = px.duplicate()

func _change_end() -> void:
	if _in_stroke:
		return
	if _before != px:
		_undo.append(_before)
		if _undo.size() > UNDO_MAX:
			_undo.pop_front()
	_before = PackedByteArray()

# --- the starting faces ------------------------------------------------------------------------------

## A starting face (32 x 32, FaceCodec colours) by name, or an empty array for an unknown name.
## Bold on purpose: dark ink on the lit screen, every stroke at least 3 cells, so it still reads 3 m
## away. Colour only as an accent (red, blue, white), since the tape filter smears colour.
static func starter(which: String) -> PackedByteArray:
	var p := FacePaint.new(32)
	match which:
		"smile":       # ink: round eyes, a wide grin; red cheeks
			p.dab(Vector2(10.5, 12.0), 6.0, 1)
			p.dab(Vector2(21.5, 12.0), 6.0, 1)
			p._arc(Vector2(16.0, 13.0), 10.5, 25.0, 155.0, 3.0, 1)
			p.dab(Vector2(5.5, 19.5), 3.0, 2)
			p.dab(Vector2(26.5, 19.5), 3.0, 2)
		"frown":       # ink: worried brows, small eyes, a down-turned mouth; one blue tear
			p.line(Vector2(5.5, 9.0), Vector2(12.5, 6.0), 2.5, 1)
			p.line(Vector2(19.5, 6.0), Vector2(26.5, 9.0), 2.5, 1)
			p.dab(Vector2(10.5, 13.5), 4.5, 1)
			p.dab(Vector2(21.5, 13.5), 4.5, 1)
			p._arc(Vector2(16.0, 32.0), 9.5, 218.0, 322.0, 3.0, 1)
			p.line(Vector2(7.5, 18.0), Vector2(7.5, 21.0), 2.5, 3)
		"shock":       # ink: staring white-ringed eyes, raised brows; a red O of a mouth
			for ex: float in [9.5, 22.5]:
				p._ellipse(Vector2(ex, 13.0), 5.0, 5.0, 6)
				p._ring(Vector2(ex, 13.0), 5.5, 2.2, 1)
				p.dab(Vector2(ex, 13.0), 2.5, 1)
				p.line(Vector2(ex - 4.0, 3.5), Vector2(ex + 4.0, 3.5), 2.5, 1)
			p._ellipse(Vector2(16.0, 25.0), 4.5, 5.5, 2)
			p._ring_ellipse(Vector2(16.0, 25.0), 4.5, 5.5, 1.6, 1)
		_:
			return PackedByteArray()
	return p.px

# Angles in degrees, screen space (y down): 90 is straight below the centre.
func _arc(c: Vector2, r: float, from_deg: float, to_deg: float, width: float, col: int) -> void:
	var steps := 48
	for i in steps + 1:
		var a := deg_to_rad(lerpf(from_deg, to_deg, float(i) / steps))
		dab(c + Vector2(cos(a), sin(a)) * r, width, col)

func _ring(c: Vector2, r: float, width: float, col: int) -> void:
	_arc(c, r, 0.0, 360.0, width, col)

func _ellipse(c: Vector2, rx: float, ry: float, col: int) -> void:
	for y in side:
		for x in side:
			var dx := (x + 0.5 - c.x) / rx
			var dy := (y + 0.5 - c.y) / ry
			if dx * dx + dy * dy <= 1.0:
				put(x, y, col)

func _ring_ellipse(c: Vector2, rx: float, ry: float, width: float, col: int) -> void:
	for i in 65:
		var a := TAU * i / 64.0
		dab(c + Vector2(cos(a) * rx, sin(a) * ry), width, col)
