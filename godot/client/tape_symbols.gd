# The pictograms of Continuance's tapes (docs/floors/story.md section 2, "The pictograms"): flat yellow
# shapes on one blue field, built from circles, squares, bars and triangles like road signs. No art
# files, no outlines, no shading, no third colour. A shape that needs a hole has it knocked out in the
# field's blue. Every function draws on a CanvasItem in its own pixels (the tape is drawn at 480x270)
# around a point, at a scale `s` (1 = the size the tape uses most).
#
# A resident is only ever the hollow diamond with a question mark (resident()). Never a body.
extends RefCounted

## The pictograms a tape may use (tapes.json "symbols"); tests/prop_tapes.gd holds every shot to this list.
const NAMES: Array[String] = ["line", "city", "floors", "you", "crew", "car", "resident", "instrument", "waves",
	"credit", "hazard", "hazard?", "meter", "button", "doors", "clock", "up", "down", "bank", "bunk", "drawer", "lid",
	"hook", "tally", "mark"]

## The field and the ink. Cobalt and chrome yellow.
const BLUE := Color("#1c3fb0")
const YELLOW := Color("#ffc814")

## The six blocks of the city: [x offset from the centre, width, height], at s = 1.
const CITY: Array = [[-112, 30, 34], [-74, 28, 56], [-38, 34, 40], [4, 24, 66], [36, 36, 46], [80, 30, 30]]

## A 5x7 asterisk for captions (the camcorder font has none).
const STAR: Array[String] = ["00000", "00100", "10101", "01110", "10101", "00100", "00000"]

static func ease_out(x: float) -> float:
	var k := clampf(x, 0.0, 1.0)
	return 1.0 - (1.0 - k) * (1.0 - k)

static func ease_in_out(x: float) -> float:
	var k := clampf(x, 0.0, 1.0)
	return k * k * (3.0 - 2.0 * k)

## 0 to 1 with a small overshoot: a sign popping up.
static func pop(x: float) -> float:
	var k := clampf(x, 0.0, 1.0)
	var c := 2.2
	return 1.0 + (c + 1.0) * pow(k - 1.0, 3.0) + c * pow(k - 1.0, 2.0)

## A frame `w` pixels thick (a hollow box).
static func frame(ci: CanvasItem, r: Rect2, w: float, col: Color) -> void:
	ci.draw_rect(Rect2(r.position, Vector2(r.size.x, w)), col)
	ci.draw_rect(Rect2(r.position + Vector2(0, r.size.y - w), Vector2(r.size.x, w)), col)
	ci.draw_rect(Rect2(r.position, Vector2(w, r.size.y)), col)
	ci.draw_rect(Rect2(r.position + Vector2(r.size.x - w, 0), Vector2(w, r.size.y)), col)

## The ground line: the one rule that stays on screen. City above, shaft below.
static func ground(ci: CanvasItem, y: float, x0: float, x1: float, col := YELLOW) -> void:
	if x1 > x0:
		ci.draw_rect(Rect2(x0, y - 2, x1 - x0, 4), col)

## The city: blocks standing on the line, `shown` of them popped up (fractional while one rises), the
## first `lit` of them lit (solid); a dark block is a frame.
static func city(ci: CanvasItem, base: Vector2, s: float, shown: float, lit: float, col := YELLOW) -> void:
	for i in CITY.size():
		var b: Array = CITY[i]
		var k := pop(shown - i)
		if shown - i <= 0.0:
			continue
		var w: float = float(b[1]) * s
		var h: float = float(b[2]) * s * k
		var r := Rect2(base.x + float(b[0]) * s, base.y - h - 2, w, h)
		if lit - i >= 1.0:
			ci.draw_rect(r, col)
		else:
			frame(ci, r, maxf(2.0, 3.0 * s), col)
			# A roof cap so a dark block still reads as a building.
			ci.draw_rect(Rect2(r.position, Vector2(w, minf(h, 5.0 * s))), col)

## Empty boxes hanging under the line, `shown` of them unrolled.
static func floors(ci: CanvasItem, top: Vector2, w: float, h: float, gap: float, shown: float, col := YELLOW) -> void:
	var count := int(ceil(shown))
	for i in count:
		var k := clampf(shown - i, 0.0, 1.0)
		var r := Rect2(top.x - w * 0.5, top.y + i * (h + gap), w, h * ease_out(k))
		if r.size.y >= 3.0:
			frame(ci, r, 3.0, col)

## The screen mask's doodles, as strokes in the square's own 0..1 space.
static func doodle(kind: int) -> Array:
	match kind:
		0:  # a smile
			return [[Vector2(0.3, 0.3), Vector2(0.3, 0.42)], [Vector2(0.7, 0.3), Vector2(0.7, 0.42)],
				[Vector2(0.24, 0.6), Vector2(0.36, 0.74), Vector2(0.5, 0.78), Vector2(0.64, 0.74), Vector2(0.76, 0.6)]]
		1:  # round glasses
			return [_ring(Vector2(0.3, 0.38), 0.14), _ring(Vector2(0.7, 0.38), 0.14), [Vector2(0.44, 0.38), Vector2(0.56, 0.38)],
				[Vector2(0.38, 0.72), Vector2(0.62, 0.72)]]
		2:  # a zigzag grin
			return [[Vector2(0.25, 0.34), Vector2(0.4, 0.3)], [Vector2(0.6, 0.3), Vector2(0.75, 0.34)],
				[Vector2(0.2, 0.66), Vector2(0.32, 0.76), Vector2(0.44, 0.64), Vector2(0.56, 0.76), Vector2(0.68, 0.64), Vector2(0.8, 0.74)]]
		_:  # a moustache
			return [[Vector2(0.32, 0.3), Vector2(0.32, 0.4)], [Vector2(0.68, 0.3), Vector2(0.68, 0.4)],
				[Vector2(0.18, 0.7), Vector2(0.3, 0.6), Vector2(0.5, 0.64), Vector2(0.7, 0.6), Vector2(0.82, 0.7)]]

static func _ring(c: Vector2, r: float) -> Array:
	var out: Array = []
	for i in 13:
		var a := TAU * i / 12.0
		out.append(c + Vector2(cos(a), sin(a)) * r)
	return out

## Draws the first `k` (0..1, by length) of some strokes inside `r`.
static func strokes(ci: CanvasItem, list: Array, r: Rect2, k: float, w: float, col: Color) -> void:
	var total := 0.0
	for st: Array in list:
		for i in range(1, st.size()):
			total += (st[i] as Vector2).distance_to(st[i - 1] as Vector2)
	var left := total * clampf(k, 0.0, 1.0)
	for st: Array in list:
		for i in range(1, st.size()):
			if left <= 0.0:
				return
			var a: Vector2 = st[i - 1]
			var b: Vector2 = st[i]
			var d := a.distance_to(b)
			var f := minf(1.0, left / maxf(d, 0.0001))
			ci.draw_line(r.position + a * r.size, r.position + a.lerp(b, f) * r.size, col, w)
			left -= d

## You: a round-shouldered figure, its head a square screen mask with two dots, a bar on the chest
## (the patch). `face` -1 draws the two dots, -2 a blank screen, 0..3 that doodle drawn `face_k` of
## the way. `diamond` swaps the body for a hollow diamond and keeps the square head.
static func you(ci: CanvasItem, feet: Vector2, s: float, face := -1, face_k := 1.0, patch := true, diamond := false, col := YELLOW, bg := BLUE) -> void:
	var top := feet.y - 30.0 * s
	if diamond:
		var c := Vector2(feet.x, feet.y - 15.0 * s)
		_hollow_diamond(ci, c, Vector2(15.0, 16.0) * s, 4.0 * s, col, bg)
	else:
		var pts := PackedVector2Array()
		pts.append(Vector2(feet.x - 13.0 * s, feet.y))
		for i in 7:
			var a := PI + (PI * 0.5) * i / 6.0
			pts.append(Vector2(feet.x - 5.0 * s, top + 8.0 * s) + Vector2(cos(a), sin(a)) * 8.0 * s)
		for i in 7:
			var a := PI * 1.5 + (PI * 0.5) * i / 6.0
			pts.append(Vector2(feet.x + 5.0 * s, top + 8.0 * s) + Vector2(cos(a), sin(a)) * 8.0 * s)
		pts.append(Vector2(feet.x + 13.0 * s, feet.y))
		ci.draw_colored_polygon(pts, col)
		if patch:
			ci.draw_rect(Rect2(feet.x + 3.0 * s, top + 6.0 * s, 6.0 * s, 2.5 * s), bg)
	# The neck gap, then the head.
	var head := Rect2(feet.x - 9.0 * s, top - 3.0 * s - 18.0 * s, 18.0 * s, 18.0 * s)
	ci.draw_rect(head, col)
	var inner := head.grow(-2.5 * s)
	if face == -1:
		ci.draw_rect(Rect2(head.position + Vector2(4.5, 6.0) * s, Vector2(3.0, 3.0) * s), bg)
		ci.draw_rect(Rect2(head.position + Vector2(10.5, 6.0) * s, Vector2(3.0, 3.0) * s), bg)
	elif face >= 0:
		strokes(ci, doodle(face), inner, face_k, maxf(1.5, 1.8 * s), bg)

## A resident: the hollow diamond with a question mark. `turn` squeezes it sideways (a turn about its
## upright, 1 flat on, 0 edge on); `mirror` draws the question mark backwards (facing away).
static func resident(ci: CanvasItem, c: Vector2, s: float, turn := 1.0, mirror := false, col := YELLOW, bg := BLUE) -> void:
	var sx := maxf(0.08, absf(turn))
	_hollow_diamond(ci, c, Vector2(19.0 * sx, 21.0) * s, 4.5 * s, col, bg)
	if sx > 0.45:
		var px := maxf(1.0, round(2.0 * s))
		var rows := PixelFont.rows("?")
		var o := c - Vector2(5.0 * px * sx, 7.0 * px) * 0.5
		for y in rows.size():
			var row: String = rows[y]
			for x in 5:
				if row[x] == "1":
					var fx := (4 - x) if mirror else x
					ci.draw_rect(Rect2(o + Vector2(fx * px * sx, y * px), Vector2(ceilf(px * sx), px)), col)

static func _hollow_diamond(ci: CanvasItem, c: Vector2, half: Vector2, w: float, col: Color, bg: Color) -> void:
	ci.draw_colored_polygon(PackedVector2Array([c + Vector2(0, -half.y), c + Vector2(half.x, 0), c + Vector2(0, half.y), c + Vector2(-half.x, 0)]), col)
	var k := 1.0 - w / maxf(half.x, 0.001)
	var hy := maxf(0.0, half.y - w * half.y / maxf(half.x, 0.001))
	var hx := maxf(0.0, half.x * k)
	if hx > 0.5:
		ci.draw_colored_polygon(PackedVector2Array([c + Vector2(0, -hy), c + Vector2(hx, 0), c + Vector2(0, hy), c + Vector2(-hx, 0)]), bg)

## The car: a box on a vertical rail, with an arrow. `dir` -1 up, 1 down, 0 none. `riders` small heads inside.
static func car(ci: CanvasItem, c: Vector2, s: float, dir: int, riders := 0, col := YELLOW, bg := BLUE) -> void:
	var r := Rect2(c - Vector2(24, 26) * s, Vector2(48, 52) * s)
	ci.draw_rect(r.grow(3.0), bg)
	frame(ci, r, 4.0 * s, col)
	for i in riders:
		var hx := c.x + (-17.0 + i * 9.0) * s
		ci.draw_rect(Rect2(hx, c.y - 1.0 * s, 6.0 * s, 6.0 * s), col)
		ci.draw_rect(Rect2(hx, c.y + 7.0 * s, 6.0 * s, 13.0 * s), col)
	if dir != 0:
		arrow(ci, Vector2(r.end.x + 16.0 * s, c.y), 0.8 * s, dir < 0, col)

static func rail(ci: CanvasItem, x: float, y0: float, y1: float, col := YELLOW) -> void:
	ci.draw_rect(Rect2(x - 2, y0, 4, y1 - y0), col)

## An arrow, up or down.
static func arrow(ci: CanvasItem, c: Vector2, s: float, up: bool, col := YELLOW) -> void:
	var d := -1.0 if up else 1.0
	ci.draw_rect(Rect2(c.x - 3.0 * s, c.y - 12.0 * s, 6.0 * s, 24.0 * s), col)
	var tip := c + Vector2(0, d * 22.0 * s)
	ci.draw_colored_polygon(PackedVector2Array([tip, c + Vector2(13.0 * s, d * 8.0 * s), c + Vector2(-13.0 * s, d * 8.0 * s)]), col)

## The instrument: a small box with a needle on a dial; `needle` -1..1.
static func instrument(ci: CanvasItem, c: Vector2, s: float, needle: float, col := YELLOW, bg := BLUE) -> void:
	var r := Rect2(c - Vector2(14, 10) * s, Vector2(28, 20) * s)
	ci.draw_rect(r, col)
	var dial := Rect2(r.position + Vector2(4, 4) * s, Vector2(20, 12) * s)
	ci.draw_rect(dial, bg)
	var pivot := Vector2(dial.get_center().x, dial.end.y - 1.0 * s)
	var a := -PI * 0.5 + clampf(needle, -1.0, 1.0) * 1.0
	ci.draw_line(pivot, pivot + Vector2(cos(a), sin(a)) * 10.0 * s, col, maxf(1.5, 2.0 * s))
	ci.draw_rect(Rect2(c.x - 3.0 * s, r.end.y, 6.0 * s, 9.0 * s), col)

## Three arcs travelling from `from` towards `to`; `phase` 0..1 moves them along, `k` shows them.
static func waves(ci: CanvasItem, from: Vector2, to: Vector2, phase: float, k := 1.0, col := YELLOW) -> void:
	var d := from.distance_to(to)
	var dir := (to - from).angle()
	for i in 3:
		var f := fposmod(i / 3.0 + phase, 1.0)
		if f < 0.08 or f > 0.95:
			continue
		var r := d * f
		var span := 0.42 + 0.25 * (1.0 - f)
		ci.draw_arc(from, r, dir - span, dir + span, 16, col, 4.0 * clampf(k, 0.0, 1.0), false)

## A credit: a disc with a notch.
static func credit(ci: CanvasItem, c: Vector2, r: float, col := YELLOW, bg := BLUE) -> void:
	if r <= 0.5:
		return
	ci.draw_circle(c, r, col)
	ci.draw_colored_polygon(PackedVector2Array([c + Vector2(0, -r * 0.55), c + Vector2(-r * 0.3, -r - 1), c + Vector2(r * 0.3, -r - 1)]), bg)

## A hazard sign: a triangle with an exclamation mark, or with a question mark (`question`).
static func hazard(ci: CanvasItem, c: Vector2, s: float, question: bool, col := YELLOW, bg := BLUE) -> void:
	if s <= 0.02:
		return
	var h := 44.0 * s
	ci.draw_colored_polygon(PackedVector2Array([c + Vector2(0, -h * 0.62), c + Vector2(h * 0.6, h * 0.38), c + Vector2(-h * 0.6, h * 0.38)]), col)
	var px := maxf(1.0, round(2.4 * s))
	var rows := PixelFont.rows("?" if question else "!")
	var o := c + Vector2(-2.5 * px, -2.0 * px)
	for y in rows.size():
		var row: String = rows[y]
		for x in 5:
			if row[x] == "1":
				ci.draw_rect(Rect2(o + Vector2(x * px, y * px), Vector2(px, px)), bg)

## A meter: a bar that fills, `k` 0..1.
static func meter(ci: CanvasItem, r: Rect2, k: float, col := YELLOW) -> void:
	frame(ci, r, 4.0, col)
	var inner := r.grow(-8.0)
	ci.draw_rect(Rect2(inner.position, Vector2(inner.size.x * clampf(k, 0.0, 1.0), inner.size.y)), col)

## The call button: a circle in a square; `press` 0..1 pushes it in.
static func button(ci: CanvasItem, c: Vector2, s: float, press: float, col := YELLOW, bg := BLUE) -> void:
	var r := Rect2(c - Vector2(20, 20) * s, Vector2(40, 40) * s)
	frame(ci, r, 4.0 * s, col)
	var k := clampf(press, 0.0, 1.0)
	ci.draw_circle(c, (11.0 - 3.5 * k) * s, col)
	if k > 0.0:
		ci.draw_circle(c, 3.0 * s * k, bg)

## Doors: two bars closing inside `r`, `k` 0 open to 1 shut.
static func doors(ci: CanvasItem, r: Rect2, k: float, col := YELLOW, bg := BLUE) -> void:
	var w := (r.size.x * 0.5 - 1.0) * clampf(k, 0.0, 1.0)
	ci.draw_rect(Rect2(r.position, Vector2(w, r.size.y)), col)
	ci.draw_rect(Rect2(Vector2(r.end.x - w, r.position.y), Vector2(w, r.size.y)), col)
	if k >= 1.0:
		ci.draw_rect(Rect2(r.get_center().x - 1.0, r.position.y, 2.0, r.size.y), bg)

## A clock: a circle with one hand at `angle` (radians from twelve).
static func clock(ci: CanvasItem, c: Vector2, r: float, angle: float, col := YELLOW, bg := BLUE) -> void:
	ci.draw_circle(c, r, col)
	ci.draw_circle(c, r - 5.0, bg)
	var a := angle - PI * 0.5
	ci.draw_line(c, c + Vector2(cos(a), sin(a)) * (r - 9.0), col, 4.0)
	ci.draw_circle(c, 3.5, col)

## Bank: a disc over an up arrow.
static func bank(ci: CanvasItem, c: Vector2, s: float, col := YELLOW, bg := BLUE) -> void:
	arrow(ci, c + Vector2(0, 20.0 * s), 0.8 * s, true, col)
	credit(ci, c - Vector2(0, 14.0 * s), 12.0 * s, col, bg)

## A bunk: a bar on two legs, a moon over it.
static func bunk(ci: CanvasItem, c: Vector2, s: float, col := YELLOW, bg := BLUE) -> void:
	ci.draw_rect(Rect2(c.x - 26.0 * s, c.y - 4.0 * s, 52.0 * s, 8.0 * s), col)
	ci.draw_rect(Rect2(c.x - 24.0 * s, c.y + 4.0 * s, 5.0 * s, 13.0 * s), col)
	ci.draw_rect(Rect2(c.x + 19.0 * s, c.y + 4.0 * s, 5.0 * s, 13.0 * s), col)
	var m := c + Vector2(6.0 * s, -34.0 * s)
	ci.draw_circle(m, 12.0 * s, col)
	ci.draw_circle(m + Vector2(6.0, -4.0) * s, 10.5 * s, bg)

## A tally: `n` marks, in fives, each four upright and one across, from `at` (top left) to the right.
static func tally(ci: CanvasItem, at: Vector2, n: int, h: float, col := YELLOW) -> float:
	var x := at.x
	for i in n:
		if i % 5 == 4:
			ci.draw_line(Vector2(x - 30.0, at.y + h * 0.8), Vector2(x + 2.0, at.y + h * 0.2), col, 3.0)
			x += 12.0
		else:
			ci.draw_rect(Rect2(x, at.y, 3.0, h), col)
			x += 8.0
	return x

## Continuance's mark: an arrow rising out of a ring.
## The ring lies flat (seen from the side, an ellipse): the arrow climbs straight up out of it, in front
## of the ring's far edge. `c` is the ring's centre.
static func mark(ci: CanvasItem, c: Vector2, s: float, col := YELLOW, bg := BLUE) -> void:
	if s <= 0.02:
		return
	var rx := 26.0 * s
	var ry := 9.0 * s
	var ring := PackedVector2Array()
	for i in 41:
		var a := TAU * i / 40.0
		ring.append(c + Vector2(cos(a) * rx, sin(a) * ry))
	ci.draw_polyline(ring, col, 5.0 * s)
	# The shaft, with a margin of field around it where it passes in front of the far edge.
	ci.draw_rect(Rect2(c.x - 6.5 * s, c.y - 30.0 * s, 13.0 * s, 32.0 * s), bg)
	ci.draw_rect(Rect2(c.x - 3.5 * s, c.y - 30.0 * s, 7.0 * s, 32.0 * s), col)
	ci.draw_colored_polygon(PackedVector2Array([c + Vector2(0, -48.0 * s), c + Vector2(14.0 * s, -28.0 * s), c + Vector2(-14.0 * s, -28.0 * s)]), col)

## Text in the camcorder font, plus the tape's own asterisk. Returns its width.
static func text(ci: CanvasItem, t: String, pos: Vector2, px: float, col := YELLOW) -> float:
	for i in t.length():
		var ch := t[i]
		var rows: Array = STAR if ch == "*" else PixelFont.rows(ch)
		for y in rows.size():
			var row: String = rows[y]
			for x in 5:
				if row[x] == "1":
					ci.draw_rect(Rect2(pos + Vector2((i * 6 + x) * px, y * px), Vector2(px, px)), col)
	return PixelFont.width(t) * px

static func text_width(t: String, px: float) -> float:
	return PixelFont.width(t) * px
