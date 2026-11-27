# LA6: the Playroom's walls, upper deck and soft shapes dressed (looks only; client/playroom_view.gd calls it).
# Above the low padded band every plain wall gets a second, taller band of stitched vinyl panels in the faded
# primaries, and above that simple painted pictures (clouds, a sun, hills, small plain animals, stars, flowers).
# The walls of the upper storey's rooms and walkways get padded posts and grey netting in front of them, its rooms a
# padded roof bar or two with bunting; cut-out clouds and stars hang from the ceilings; in the longer walkways the
# company's PLAY NICELY in cut-out letters. The soft shapes the view already places (cubes, drums, steps) are drawn as
# soft-play pieces with foam seams and piping inside their own boxes, and the playhouse's front gets a painted door.
# Near the lift everything is clean and straight; with the walk from the lift (Level.corruption, the measure the
# view's walls and mats already bleach by, carried to the shader in the vertex colour's red) the paint bleaches, a
# panel here and there is gone and leaves a pale patch, and the cut-out letters hang crooked or are missing.
#
# Nothing here is a rule and nothing may change what a player can see (the rules decide sight from the plan alone,
# sim/sight.gd), so, as the Clinic's dressing (client/clinic_dress.gd):
#  - at eye height only on wall faces, at most PROUD_MAX off the face, and kept short of any end of a face where the
#    wall stops (a doorway, an opening, a corner the wall turns round): a body keeps 30 cm off every wall line, so a
#    line between two bodies only comes near a face where it crosses the wall's line through a gap. Crossing it L m
#    before the wall starts, a line is still inside the drawn wall (FACE thick) along its start unless it leaves the
#    line steeper than FACE / L; then it is more than d off the face only beyond (FACE + d) / slope. So a piece d deep
#    keeps d / FACE * L (and TRIM_SPARE) short of that end, L the gap's whole length along the line (trim());
#  - not on a lower wall under the slab's opening whose upper wall is not solid (a line from the deck comes down
#    steeply there), nor on an upper wall over an opening whose lower wall is not solid;
#  - high (HIGH_Y and up) on the upper storey anywhere, on the lower storey only in a room with no opening over it;
#  - netting is see-through (as the rails' and the dens' nets);
#  - nothing within reach of a hide's body or the floor in front of it, a squeaker, a door, the landing, the lift's
#    wall in the lobby, a sign or a mural; nothing lower than FLOOR_CLEAR over its floor (the crew's marks lie there).
# tests/test_playroom_dress.gd checks it with the plan's own sight check. No collision, no light, no glow (vertex alpha
# 1 everywhere, so the shader's self-lit path is never taken), no shadow; it goes dark with the strip lights.
#
# One atlas texture drawn here by code, one material for the walls' pieces (and the view's netting material for the
# nets, its prop material for the soft shapes), merged into the view's chunks.
extends RefCounted

const AnnexView = preload("res://client/annex_view.gd")
const Floor = preload("res://sim/floor.gd")
const Playroom = preload("res://sim/playroom.gd")

const S := 2.0
const LH := 3.2
## The wall's half thickness: a wall face stands this far off the wall line.
const FACE := 0.07
## A wall piece stands at most this far off its wall face (m).
const PROUD_MAX := 0.15
## The lowest point of a high piece over its floor: above every point of a figure the rules look at (2.6 m).
const HIGH_Y := 2.65
## Nothing comes lower than this over its floor (the crew's marks lie at 2.5 cm).
const FLOOR_CLEAR := 0.05
## The padded panels' band over the floor, and how far they stand off the face.
const BAND_LO := 1.16
const BAND_HI := 1.96
const BAND_D := 0.02
## The painted pictures' middle over the floor, and how far the paint stands off the face.
const PAINT_Y := 2.42
const PAINT_D := 0.006
## The paint on a doorway's jambs stands this far off them.
const JAMB_D := 0.003
## Kept this much further short of an end where the wall stops than the slope rule asks (trim()); and no piece goes
## on a face where it would have to keep more than TRIM_MAX short.
const TRIM_SPARE := 0.12
const TRIM_MAX := 1.5
## The upper storey's padded posts and nets in front of its walls.
const POST_W := 0.14
const POST_D := 0.05
const NET_D := 0.05
const POST_TOP := 3.12
## The roof bars over the upper storey's play rooms, and the cut-out shapes hung from the ceilings.
const BAR_LO := 2.92
const BAR_H := 0.13
const HANG_LO := 2.7
## Cut-out letters in the walkways: pixel size and the top of the word over the floor.
const LETTER_PX := 0.05
const LETTER_TOP := 2.62
const LETTER_D := 0.02
## The corruption (0 at the lift, 1 furthest) past which pieces wear, and past which they are most worn.
const WEAR := 0.45
const FAR := 0.72
## The walkways' words, from the lift outwards: the right one, then letters gone or swapped. Never a word about
## looking, hiding, counting or keeping quiet (the test reads them all).
const WORDS: Array[String] = ["PLAY NICELY", "PLAY NICELY", "PLAY NIC LY", "PLAY NICLEY", "PL Y NICELY", "PLAY  ICELY"]
const MAX_WORDS := 6
## Where the word's own space is (every variant keeps it): any other space is a letter gone.
const WORD_GAP := 4

const RED := Color(0.82, 0.36, 0.32)
const YELLOW := Color(0.92, 0.78, 0.36)
const BLUE := Color(0.36, 0.55, 0.8)
const GREEN := Color(0.45, 0.72, 0.45)
const PAL: Array[Color] = [RED, YELLOW, BLUE, GREEN]
const WHITE := Color(0.95, 0.95, 0.92)
const CORD := Color(0.55, 0.55, 0.53)
const INK := Color(0.2, 0.19, 0.22)

## Tests only: leaves the Playroom undressed (to compare a floor with and without it).
static var off := false
## Tests only: one deliberate break by name, to prove the checks ("proud", "low", "trim", "hole", "glow", "seed",
## "wear", "hide", "soft", "leak", "flat", "jamb", "thin", "storey", "netonly", "runs").
static var test_break := ""

# --- the atlas ------------------------------------------------------------------------------------------------------

const ATLAS := 512
## The panels' paint is the low band's: the palette times the padding texture's grey there (211 of 255), so far from
## the lift, where the shader bleaches both alike, the second band stands off the white wall as the low band does.
const PANEL_SHADE := 0.83
## Panels: four colours, 64 px square; a pale patch where one is gone; posts' sleeves 16 by 64.
const PANEL_PX := 64
const PICS: Array[String] = ["cloud", "hills", "sun", "duck", "fish", "snail", "star", "flower", "ladybird"]
## The pictures that hang (cut out, painted both sides).
const HANGS: Array[String] = ["cloud", "star"]
## Painted size on the wall (m): [width, height].
const PIC_SIZE := {"cloud": Vector2(0.9, 0.45), "hills": Vector2(1.1, 0.55), "sun": Vector2(0.55, 0.55), "duck": Vector2(0.42, 0.42),
	"fish": Vector2(0.42, 0.42), "snail": Vector2(0.42, 0.42), "star": Vector2(0.4, 0.4), "flower": Vector2(0.36, 0.5), "ladybird": Vector2(0.36, 0.36),
	"door": Vector2(0.28, 0.72), "window_box": Vector2(0.5, 0.1)}

static var _tex: ImageTexture
static var _rects := {}

static func rect(name: String) -> Rect2i:
	atlas()
	return _rects[name]

## The atlas UV of a named region, inset half a texel.
static func uv(name: String) -> Rect2:
	var r := rect(name)
	return Rect2((r.position.x + 0.5) / ATLAS, (r.position.y + 0.5) / ATLAS, (r.size.x - 1.0) / ATLAS, (r.size.y - 1.0) / ATLAS)

## The middle of a solid colour block.
static func solid(i: int) -> Vector2:
	var r := rect("solid%d" % i)
	return Vector2((r.position.x + r.size.x * 0.5) / ATLAS, (r.position.y + r.size.y * 0.5) / ATLAS)

## Solid blocks: 0-3 the palette, 4 white, 5 cord grey, 6 ink, 7-10 the palette's darker piping.
static func _solid_cols() -> Array[Color]:
	return [RED, YELLOW, BLUE, GREEN, WHITE, CORD, INK, RED * 0.78, YELLOW * 0.8, BLUE * 0.78, GREEN * 0.78]

static func atlas() -> ImageTexture:
	if _tex != null:
		return _tex
	var img := Image.create(ATLAS, ATLAS, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for i in 4:
		var r := Rect2i(i * PANEL_PX, 0, PANEL_PX, PANEL_PX)
		_rects["panel%d" % i] = r
		_panel(img, r, PAL[i] * PANEL_SHADE)
		var p := Rect2i(448 + i * 16, 0, 16, 64)
		_rects["post%d" % i] = p
		_panel(img, p, PAL[i] * PANEL_SHADE)
	var ghost := Rect2i(256, 0, PANEL_PX, PANEL_PX)
	_rects["ghost"] = ghost
	img.fill_rect(ghost, Color(0.9, 0.9, 0.86))
	for k in PANEL_PX:
		for e: Vector2i in [Vector2i(k, 2), Vector2i(k, PANEL_PX - 3), Vector2i(2, k), Vector2i(PANEL_PX - 3, k)]:
			img.set_pixelv(ghost.position + e, Color(0.8, 0.8, 0.76))
	var cols := _solid_cols()
	for i in cols.size():
		var r := Rect2i(320 + (i % 8) * 16, (i / 8) * 16, 16, 16)
		_rects["solid%d" % i] = r
		img.fill_rect(r, cols[i])
	var at := {"cloud": Rect2i(0, 64, 128, 64), "hills": Rect2i(128, 64, 128, 64), "sun": Rect2i(256, 64, 64, 64), "duck": Rect2i(320, 64, 64, 64),
		"fish": Rect2i(384, 64, 64, 64), "snail": Rect2i(448, 64, 64, 64), "star": Rect2i(0, 128, 64, 64), "flower": Rect2i(64, 128, 64, 64),
		"ladybird": Rect2i(128, 128, 64, 64), "door": Rect2i(192, 128, 32, 64), "window_box": Rect2i(224, 128, 64, 16)}
	for k: String in at:
		_rects[k] = at[k]
		_draw_pic(img, k, at[k])
	img.generate_mipmaps()
	_tex = ImageTexture.create_from_image(img)
	return _tex

## A stitched vinyl panel: its colour, a darker welded seam round the edge, a dashed stitch line inside, pillowed.
static func _panel(img: Image, r: Rect2i, col: Color) -> void:
	var w := r.size.x
	var h := r.size.y
	for y in h:
		for x in w:
			var dx := absf((x + 0.5) / w - 0.5) * 2.0
			var dy := absf((y + 0.5) / h - 0.5) * 2.0
			var c := col * (1.05 - 0.12 * maxf(dx, dy) * maxf(dx, dy))
			var e := mini(mini(x, w - 1 - x), mini(y, h - 1 - y))
			if e < 2:
				c = col * 0.72
			elif e == 4 and ((x + y) / 3) % 2 == 0:
				c = col.lerp(WHITE, 0.45)
			c.a = 1.0
			img.set_pixel(r.position.x + x, r.position.y + y, c)

static func _disc(img: Image, r: Rect2i, c: Vector2, rad: float, col: Color, sy := 1.0) -> void:
	for y in r.size.y:
		for x in r.size.x:
			var d := Vector2(x + 0.5 - c.x, (y + 0.5 - c.y) / sy)
			if d.length() <= rad:
				img.set_pixel(r.position.x + x, r.position.y + y, col)

static func _poly(img: Image, r: Rect2i, pts: PackedVector2Array, col: Color) -> void:
	for y in r.size.y:
		for x in r.size.x:
			if Geometry2D.is_point_in_polygon(Vector2(x + 0.5, y + 0.5), pts):
				img.set_pixel(r.position.x + x, r.position.y + y, col)

static func _line(img: Image, r: Rect2i, a: Vector2, b: Vector2, t: float, col: Color) -> void:
	for y in r.size.y:
		for x in r.size.x:
			var p := Vector2(x + 0.5, y + 0.5)
			if Geometry2D.get_closest_point_to_segment(p, a, b).distance_to(p) <= t:
				img.set_pixel(r.position.x + x, r.position.y + y, col)

## Draws a painted picture, our own plain shapes, with a dark outline round its parts (painted first, a size bigger).
static func _draw_pic(img: Image, k: String, r: Rect2i) -> void:
	var o := INK * 1.2
	o.a = 1.0
	match k:
		"cloud":
			for pass_ in 2:
				var g := 2.0 if pass_ == 0 else 0.0
				var col := o if pass_ == 0 else WHITE
				for c: Vector3 in [Vector3(34, 38, 16), Vector3(56, 28, 20), Vector3(80, 30, 18), Vector3(98, 40, 14), Vector3(64, 42, 16)]:
					_disc(img, r, Vector2(c.x, c.y), c.z + g, col)
		"hills":
			for pass_ in 2:
				var g := 2.0 if pass_ == 0 else 0.0
				_disc(img, r, Vector2(40, 70), 44 + g, o if pass_ == 0 else GREEN, 0.7)
				_disc(img, r, Vector2(92, 72), 40 + g, o if pass_ == 0 else GREEN * 0.85, 0.75)
			for f: Vector2 in [Vector2(30, 48), Vector2(52, 52), Vector2(84, 50), Vector2(104, 56)]:
				_disc(img, r, f, 2.5, RED)
		"sun":
			for i in 12:
				var a := i * TAU / 12.0
				_line(img, r, Vector2(32, 32) + Vector2(cos(a), sin(a)) * 19.0, Vector2(32, 32) + Vector2(cos(a), sin(a)) * 28.0, 2.2, YELLOW * 0.9)
			_disc(img, r, Vector2(32, 32), 17, o)
			_disc(img, r, Vector2(32, 32), 15, YELLOW)
		"duck":
			_disc(img, r, Vector2(30, 42), 18, o, 0.65)
			_disc(img, r, Vector2(44, 22), 11, o)
			_disc(img, r, Vector2(30, 42), 16, YELLOW, 0.65)
			_disc(img, r, Vector2(44, 22), 9, YELLOW)
			_poly(img, r, PackedVector2Array([Vector2(51, 20), Vector2(62, 24), Vector2(51, 28)]), Color(0.9, 0.55, 0.25))
			_disc(img, r, Vector2(46, 19), 1.8, INK)
		"fish":
			_poly(img, r, PackedVector2Array([Vector2(8, 18), Vector2(22, 32), Vector2(8, 46)]), BLUE * 0.8)
			_disc(img, r, Vector2(36, 32), 21, o, 0.6)
			_disc(img, r, Vector2(36, 32), 19, BLUE, 0.6)
			_disc(img, r, Vector2(46, 28), 2.2, INK)
			for s in 3:
				_line(img, r, Vector2(28 + s * 6, 26), Vector2(26 + s * 6, 38), 0.9, BLUE * 0.75)
		"snail":
			_disc(img, r, Vector2(34, 50), 22, o, 0.25)
			_disc(img, r, Vector2(34, 50), 20, Color(0.85, 0.78, 0.55), 0.25)
			_disc(img, r, Vector2(30, 34), 16, o)
			for i in 4:
				_disc(img, r, Vector2(30, 34), 14.0 - i * 3.5, RED if i % 2 == 0 else RED * 0.8)
			_line(img, r, Vector2(50, 46), Vector2(54, 36), 1.2, INK)
			_line(img, r, Vector2(46, 46), Vector2(47, 37), 1.2, INK)
		"star":
			var pts := PackedVector2Array()
			var pin := PackedVector2Array()
			for i in 10:
				var a := -PI * 0.5 + i * TAU / 10.0
				var rr := 28.0 if i % 2 == 0 else 12.0
				pts.append(Vector2(32, 34) + Vector2(cos(a), sin(a)) * rr)
				pin.append(Vector2(32, 34) + Vector2(cos(a), sin(a)) * (rr - 2.5))
			_poly(img, r, pts, o)
			_poly(img, r, pin, YELLOW)
		"flower":
			_line(img, r, Vector2(32, 30), Vector2(32, 62), 2.0, GREEN * 0.8)
			_disc(img, r, Vector2(24, 50), 6, GREEN, 0.5)
			for i in 6:
				var a := i * TAU / 6.0
				_disc(img, r, Vector2(32, 22) + Vector2(cos(a), sin(a)) * 10.0, 7.5, o)
			for i in 6:
				var a := i * TAU / 6.0
				_disc(img, r, Vector2(32, 22) + Vector2(cos(a), sin(a)) * 10.0, 6.0, RED)
			_disc(img, r, Vector2(32, 22), 6, YELLOW)
		"ladybird":
			_disc(img, r, Vector2(32, 16), 9, INK)
			_disc(img, r, Vector2(32, 36), 22, o)
			_disc(img, r, Vector2(32, 36), 20, RED)
			_line(img, r, Vector2(32, 16), Vector2(32, 56), 1.0, INK)
			for d: Vector2 in [Vector2(23, 30), Vector2(41, 30), Vector2(21, 44), Vector2(43, 44), Vector2(32, 50)]:
				_disc(img, r, d, 3.5, INK)
		"door":
			img.fill_rect(Rect2i(r.position.x + 1, r.position.y + 1, 30, 63), o)
			img.fill_rect(Rect2i(r.position.x + 3, r.position.y + 3, 26, 61), BLUE)
			img.fill_rect(Rect2i(r.position.x + 6, r.position.y + 7, 20, 18), BLUE * 0.85)
			img.fill_rect(Rect2i(r.position.x + 6, r.position.y + 30, 20, 28), BLUE * 0.85)
			_disc(img, r, Vector2(24, 34), 2.2, YELLOW)
		"window_box":
			img.fill_rect(Rect2i(r.position.x, r.position.y + 6, 64, 10), Color(0.6, 0.42, 0.25))
			for i in 7:
				_disc(img, r, Vector2(5 + i * 9, 5), 3.5, PAL[i % 2 * 2])
				_disc(img, r, Vector2(5 + i * 9, 5), 1.2, YELLOW)

# --- building ------------------------------------------------------------------------------------------------------

## What the dressing drew, for the tests: {kind, level, aabb, n (into the room; ZERO for a high or a free piece), face
## (a point on the wall face), cell (the front cell), corr, see (see-through), high, ghost, tilt, old (a soft shape's
## box as the view drew it before), col}.
var records: Array[Dictionary] = []
var view: Node3D
var lv: Level
var keep_out: Array[AABB] = []
var stars: Array[Vector3] = []

static func build(v: Node3D) -> RefCounted:
	var d := new()
	d.view = v
	d.lv = v.get("lv")
	if not off:
		d._build()
	d.lv.set_meta(&"playroom_dress", d.records)
	return d

func _build() -> void:
	stars = view.get("stars")
	_keep_outs()
	_index_keep_outs()
	var faces := wall_faces()
	var runs := _runs(faces)
	_run_gaps(runs)
	var worded := _words(runs)
	for f: Dictionary in faces:
		_face(f, worded.has(_face_key(f)))
	_jambs()
	_roof_bars()
	_hangers()
	_playhouse_fronts()

func _corr(p: Vector3) -> float:
	return lv.corruption_at(p)

func _h(text: String) -> int:
	return absi(hash(str(lv.plan.seed) + ":la6:" + text + ("" if test_break != "seed" else str(Time.get_ticks_usec()))))

func _h01(text: String) -> float:
	return float(_h(text) % 10007) / 10007.0

## The places nothing goes near: every hide's body (the slide's climb up its wall included) and the floor in front of
## it out past the Minder's front spot, the doorways, the landing and the lobby's lift wall, the zone and EXIT signs,
## the murals, the cut-out words and the party signs, the lobby's notices and benches.
##
## What stands or hangs in a room keeps the room's own walls clear, never the other side of them: those boxes are
## cut to the room (a walkway behind a mural's wall is dressed as any other).
func _keep_outs() -> void:
	var fp: Floor.FloorPlan = view.get("fp")
	var room_box := {}
	for r: Dictionary in lv.plan.rooms:
		room_box[int(r.id)] = AABB(Vector3(int(r.x) * S, int(r.level) * LH, int(r.y) * S), Vector3(int(r.w) * S, LH, int(r.h) * S))
	for h: Playroom.Hide in view.get("hides"):
		var base := h.level * LH
		var c := Vector3(h.inside.x / 100.0, base, h.inside.y / 100.0)
		var half: float = {&"pit": 2.95, &"slide": 0.75, &"den": 0.7, &"playhouse": 0.85, &"table": 1.6, &"chest": 0.65, &"cubby": 0.6}.get(h.kind, 0.9)
		var top := LH if h.kind == &"slide" or h.kind == &"cubby" else 2.2
		var rb: AABB = room_box.get(h.room, AABB())
		_keep_in("hide body", AABB(c - Vector3(half, 0, half), Vector3(half * 2.0, top, half * 2.0)), rb)
		var f := Vector3(h.front.x / 100.0, base, h.front.y / 100.0)
		var lo := Vector3(minf(c.x, f.x), base, minf(c.z, f.z)) - Vector3(0.7, 0, 0.7)
		var hi := Vector3(maxf(c.x, f.x), base + 2.2, maxf(c.z, f.z)) + Vector3(0.7, 0, 0.7)
		_keep_in("hide front", AABB(lo, hi - lo), rb)
	for d: Floor.Door in (view.get("fp") as Floor.FloorPlan).doors:
		var a := lv.cell_center(d.level, d.ax, d.ay)
		var b := lv.cell_center(d.level, d.bx, d.by)
		var m := (a + b) * 0.5
		var across := Vector3(absf(b.z - a.z), 0, absf(b.x - a.x)).normalized()
		var thru := (b - a).normalized().abs()
		var lo := m - across * 0.75 - thru * 0.6
		_keep("doorway", AABB(lo, across * 1.5 + thru * 1.2 + Vector3(0, LH, 0)))
	var lc := lv.cell_center(lv.landing.x, lv.landing.y, lv.landing.z)
	_keep("landing", AABB(lc - Vector3(1.1, 0, 1.1), Vector3(2.2, LH, 2.2)))
	for s: Dictionary in view.get("signs"):
		_keep("zone sign", AABB(s.pos, Vector3.ZERO).grow(0.7))
	for w: Dictionary in view.get("words"):
		var p: Vector3 = w.pos
		var half := (str(w.text).length() * 6) * 0.07 * 0.5 + 0.3
		_keep_in("cut-out word", AABB(p - Vector3(half, 0.6, half), Vector3(half * 2.0, 1.2, half * 2.0)), room_box[int(w.room)])
	for m: Dictionary in view.get("murals"):
		var p: Vector3 = m.pos
		_keep_in("mural", AABB(p - Vector3(2.0, 1.0, 2.0), Vector3(4.0, 2.0, 4.0)), room_box[int(m.room)])
	# The ready-made slides and towers stand against walls: the cells under them.
	for pc: Dictionary in view.get("pieces"):
		for c: Vector2i in pc.cells:
			var p := lv.cell_center(int(pc.level), c.x, c.y)
			_keep("slide or tower", AABB(p - Vector3(S * 0.5, 0, S * 0.5), Vector3(S, LH, S)))
	for r: Dictionary in lv.plan.rooms:
		var kind := str(r.kind)
		var level := int(r.level)
		if kind == "cloak":
			# The coat cubbies' shelves line the cloakrooms' walls.
			_keep("cloakroom", AABB(Vector3(int(r.x) * S, level * LH, int(r.y) * S), Vector3(int(r.w) * S, LH, int(r.h) * S)))
		if kind == "party":
			# The PARTY ROOM sign and the bunting's ends on its plainest wall.
			var w: Array = view.call("_plain_wall", r)
			if int(w[2]) >= 2:
				_keep_in("party sign", _wall_span(r, int(w[0]), float(w[1]) + float(w[2]) * 0.5, 1.2, 1.2, 2.2), room_box[int(r.id)])
		if kind == "lobby":
			# The lift's wall: the height chart, SOCKS MUST BE WORN, the benches, the call button.
			var v := lv._dir_vec(lv.lift_dir)
			var out := Vector3(v.x, 0, v.y)
			var wall := lc + out * (S * 0.5)
			var along := Vector3(absf(out.z), 0, absf(out.x))
			_keep_in("lobby lift wall", AABB(wall - along * 4.5 - out.abs() * 1.0 + Vector3(0, level * LH, 0), along * 9.0 + out.abs() * 2.0 + Vector3(0, LH, 0)), room_box[int(r.id)])

## Why each keep-out is there (for the tests and the measuring).
var keep_why: Array[String] = []

func _keep(why: String, box: AABB) -> void:
	keep_out.append(box)
	keep_why.append(why)

## A keep-out cut to its room's box (nothing when they do not meet).
func _keep_in(why: String, box: AABB, room: AABB) -> void:
	if test_break == "leak":
		_keep(why, box)
		return
	var cut := box.intersection(room)
	if cut.size.x > 0.0 and cut.size.z > 0.0:
		_keep(why, cut)

## The first keep-out a box meets, by why it is there, leaving out those in `ignore`; "" for none.
func kept_by(box: AABB, ignore: Array[String] = []) -> String:
	for i in keep_out.size():
		if keep_out[i].intersects(box) and not ignore.has(keep_why[i]):
			return keep_why[i]
	return ""

## A box on side `side` of room r, `mid_i` cells along it, `half` m either way, from `y0` to `y1` over the floor.
func _wall_span(r: Dictionary, side: int, mid_i: float, half: float, y0: float, y1: float) -> AABB:
	var base := Vector3(int(r.x) * S, int(r.level) * LH, int(r.y) * S)
	var p: Vector3
	match side:
		0: p = base + Vector3(mid_i * S, 0, 0)
		1: p = base + Vector3(int(r.w) * S, 0, mid_i * S)
		2: p = base + Vector3(mid_i * S, 0, int(r.h) * S)
		_: p = base + Vector3(0, 0, mid_i * S)
	return AABB(p + Vector3(-half, y0, -half), Vector3(half * 2.0, y1 - y0, half * 2.0))

## The keep-outs by KO_CELL m square of the floor, for _kept_out.
const KO_CELL := 4.0
var _ko_grid := {}

func _index_keep_outs() -> void:
	for i in keep_out.size():
		var k := keep_out[i]
		for gz in range(floori(k.position.z / KO_CELL), floori(k.end.z / KO_CELL) + 1):
			for gx in range(floori(k.position.x / KO_CELL), floori(k.end.x / KO_CELL) + 1):
				var g := Vector2i(gx, gz)
				if not _ko_grid.has(g):
					_ko_grid[g] = []
				(_ko_grid[g] as Array).append(i)

func _kept_out(box: AABB) -> bool:
	for gz in range(floori(box.position.z / KO_CELL), floori(box.end.z / KO_CELL) + 1):
		for gx in range(floori(box.position.x / KO_CELL), floori(box.end.x / KO_CELL) + 1):
			for i: int in _ko_grid.get(Vector2i(gx, gz), []):
				if keep_out[i].intersects(box):
					return true
	return false

## The edge kind on side d (a DIRS vector) of cell (x, y) on `level`; "wall" off the plan.
func edge(level: int, x: int, y: int, d: Vector2i) -> String:
	if x < 0 or y < 0 or x >= lv.W or y >= lv.H:
		return "wall"
	return view.call("_edge_kind", level, x, y, d)

func _hole(x: int, y: int) -> bool:
	var k := lv.kind(1, x, y)
	return k == "atriumOpen" or k == "stair"

func _room_kind(level: int, x: int, y: int) -> String:
	return view.call("_room_kind", level, x, y)

## Every wall face a piece may go on: {level, cell, side, d, n, along, a (the face line's start at the floor), t0, t1
## (how far short of each end), canyon (the upper half of a wall two storeys high over the walkway below)}.
func wall_faces() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var lift := lv._lift_edge()
	var lift_v := lv._dir_vec(lv.lift_dir)
	for level in 2:
		for y in lv.H:
			for x in lv.W:
				var k := lv.kind(level, x, y)
				var canyon := false
				if k == "atriumOpen" and level == 1:
					canyon = lv.walkable(0, x, y) and lv.kind(0, x, y) != "stair"
					if not canyon:
						continue
				elif k != "room" and k != "corridor" and k != "landing":
					continue
				for side in 4:
					var d: Vector2i = AnnexView.DIRS[side]
					if edge(level, x, y, d) != "wall":
						continue
					if canyon and edge(0, x, y, d) != "wall":
						continue
					var eid := Vector4i(0, x + 1 if d.x > 0 else x, y, 1) if d.x != 0 else Vector4i(1, x, y + 1 if d.y > 0 else y, 1)
					if level == lv.landing.x and eid == lift:
						continue
					if _room_kind(level, x, y) == "lobby" and d == lift_v:
						continue
					var along_i := Vector2i(absi(d.y), absi(d.x))
					if _steep(level, Vector2i(x, y), d, canyon) and test_break != "hole":
						continue
					var n := -Vector3(d.x, 0, d.y)
					var mid := lv.cell_center(level, x, y) + Vector3(d.x, 0, d.y) * (S * 0.5)
					# The face line at floor height 0: every piece adds its own storey's height (_frame, _record).
					if test_break != "storey":
						mid.y = 0.0
					var along := Vector3(along_i.x, 0, along_i.y)
					var a := mid - along * (S * 0.5)
					var gaps: Array[Vector2] = []
					for s: int in [-1, 1]:
						gaps.append(_gap(level, Vector2i(x, y), d, along_i * s))
					var pe := edge(level, x, y, along_i)
					var runs_on := pe != "wall" and pe != "door" and edge(level, x + along_i.x, y + along_i.y, d) == "wall"
					out.append({"level": level, "cell": Vector2i(x, y), "side": side, "d": d, "n": n, "along": along, "a": a,
						"t0": gaps[0].x, "t1": gaps[1].x, "j0": gaps[0].y, "j1": gaps[1].y, "canyon": canyon, "runs_on": runs_on})
	return out

## Whether a line between the storeys can come steeply down (or up) beside the wall on side d of cell c: the slab is
## open over c or a neighbour along the wall and the other storey's wall on that line is not solid.
func _steep(level: int, c: Vector2i, d: Vector2i, canyon := false) -> bool:
	var along_i := Vector2i(absi(d.y), absi(d.x))
	for s: int in [-1, 0, 1]:
		var q := c + along_i * s
		if level == 0 and _hole(q.x, q.y) and edge(1, q.x, q.y, d) != "wall":
			return true
		if level == 1 and not canyon and _hole(q.x, q.y) and edge(0, q.x, q.y, d) != "wall":
			return true
	return false

## The gap in the wall's line beyond the face's end towards `step`: Vector2(its length along the line, the jamb between
## the face and the gap). Zero at a corner the wall turns into (a door in that wall is a door into another room, whose
## lines cross the corner's wall first) or where the wall runs on.
func _gap(level: int, c: Vector2i, d: Vector2i, step: Vector2i) -> Vector2:
	var pe := edge(level, c.x, c.y, step)
	if pe == "wall" or pe == "door":
		return Vector2.ZERO
	var e2 := edge(level, c.x + step.x, c.y + step.y, d)
	if e2 == "wall":
		return Vector2.ZERO
	if e2 == "door":
		return Vector2(Level.DOOR_W, (S - Level.DOOR_W) * 0.5)
	var k := 1
	while k < 6:
		var e := edge(level, c.x + step.x * (k + 1), c.y + step.y * (k + 1), d)
		if e == "wall" or e == "door":
			break
		k += 1
	return Vector2(k * S, 0.0)

## How far short of an end with gap `g` (_gap) a piece `depth` deep keeps.
## `off`: how far along the wall the face starts from the end of its run of wall where that gap is (a face further
## along a run keeps the rest of the same distance).
static func trim(g: Vector2, depth: float, off := 0.0) -> float:
	if g.x <= 0.0 or test_break == "trim":
		return 0.0
	if off <= 0.0:
		return maxf(0.0, depth / FACE * g.x - g.y) + TRIM_SPARE
	return maxf(0.0, depth / FACE * g.x - g.y - off + TRIM_SPARE)

func _face_key(f: Dictionary) -> String:
	return "%d:%s:%d" % [int(f.level), f.cell, int(f.side)]

## Gives every face its run's gaps: g0, gj0 (the gap and jamb at the run's start, as _gap), o0 (how far the face starts
## from it), and g1, gj1, o1 at its other end. A line crossing the wall's line through a gap can graze the wall past the
## run's first face, so every face of the run keeps its share of the distance trim() asks for.
func _run_gaps(runs: Array) -> void:
	for run: Array in runs:
		var first: Dictionary = run[0]
		var last: Dictionary = run[run.size() - 1]
		for i in run.size():
			var f: Dictionary = run[i]
			f["g0"] = first.t0
			f["gj0"] = first.j0
			f["o0"] = i * S if test_break != "runs" else (0.0 if i == 0 else 99.0)
			f["g1"] = last.t1
			f["gj1"] = last.j1
			f["o1"] = (run.size() - 1 - i) * S if test_break != "runs" else (0.0 if i == run.size() - 1 else 99.0)

## Runs of faces along one wall line with no stop between: [faces in order].
func _runs(faces: Array[Dictionary]) -> Array:
	var by := {}
	for f in faces:
		by[_face_key(f)] = f
	var seen := {}
	var out: Array = []
	for f in faces:
		if seen.has(_face_key(f)):
			continue
		var run: Array = [f]
		seen[_face_key(f)] = true
		var cur := f
		while float(cur.t1) == 0.0:
			var ai := Vector2i(roundi((cur.along as Vector3).x), roundi((cur.along as Vector3).z))
			var nk := "%d:%s:%d" % [int(cur.level), (cur.cell as Vector2i) + ai, int(cur.side)]
			if not by.has(nk) or seen.has(nk):
				break
			cur = by[nk]
			seen[nk] = true
			run.append(cur)
		out.append(run)
	return out

## A frame on a face: x along the face (left to right for someone facing it), y up, z out of the wall into the room.
func _frame(f: Dictionary, along_m: float, y: float, out_m: float) -> Transform3D:
	var n: Vector3 = f.n
	var right := (-n).cross(Vector3.UP).normalized()
	var a: Vector3 = f.a
	var along: Vector3 = f.along
	var p := a + along * along_m + n * (FACE + out_m) + Vector3(0, int(f.level) * LH + y, 0)
	return Transform3D(Basis(right, Vector3.UP, n), p)

func _record(kind: String, f: Dictionary, box: AABB, corr: float, extra := {}) -> void:
	var r := {"kind": kind, "level": int(f.level), "aabb": box, "n": f.n, "face": (f.a as Vector3) + (f.n as Vector3) * FACE + Vector3(0, int(f.level) * LH, 0),
		"cell": f.cell, "corr": corr, "see": false, "high": false, "ghost": false, "tilt": 0.0}
	r.merge(extra, true)
	records.append(r)

## The pieces are merged into one mesh per GROUP cells square per storey (few enough lamps meet each for the renderer's
## per-mesh limit: tests/test_light_pairs.gd), named like the view's chunks so the lower storey's go on its layer.
const GROUP := 8

func _st(level: int, p: Vector3) -> SurfaceTool:
	var key := "%d_%d_%d_pldress" % [level, floori(p.x / (S * GROUP)), floori(p.z / (S * GROUP))]
	if not lv._chunks.has(key):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		lv._chunks[key] = st
	return lv._chunks[key]

## Which faces a cuboid draws (bits): its front (+z), back (-z), right, left, top, bottom.
const F_FRONT := 1
const F_BACK := 2
const F_SIDES := 12
const F_TOP := 16
const F_BOTTOM := 32
const F_ALL := 63
const F_WALL := F_ALL & ~F_BACK

## A cuboid in frame xf (centre c, size sz): its +z face shows `front` (an atlas rect), the others a solid colour; only
## the faces in `faces` are drawn (by default all but the one against the wall). Vertex colour: the corruption in red
## (the shader bleaches by it), alpha 1.
static func cuboid(st: SurfaceTool, xf: Transform3D, sz: Vector3, c: Vector3, front: Rect2, side_uv: Vector2, corr: float, faces := F_WALL) -> AABB:
	var h := sz * 0.5
	var col := Color(corr, 0.0, 0.0, 1.0)
	var box := AABB(xf * (c - h), Vector3.ZERO)
	for k in 8:
		box = box.expand(xf * (c + Vector3(h.x * (1 if k & 1 else -1), h.y * (1 if k & 2 else -1), h.z * (1 if k & 4 else -1))))
	var axes: Array[Vector3] = [Vector3.BACK, Vector3.FORWARD, Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN]
	for i in 6:
		if faces & (1 << i) == 0:
			continue
		var ax := axes[i]
		var t1 := Vector3(ax.y, ax.z, ax.x).abs()
		var t2 := ax.abs().cross(t1)
		var fc := c + ax * h
		var e1 := t1 * h
		var e2 := t2 * h
		var nw := (xf.basis * ax).normalized()
		if ax == Vector3.BACK:
			# The picture's face: left (-x) at u0, top (+y) at v0.
			AnnexView.quad(st, xf * (c + Vector3(-h.x, -h.y, h.z)), xf * (c + Vector3(h.x, -h.y, h.z)), xf * (c + Vector3(h.x, h.y, h.z)), xf * (c + Vector3(-h.x, h.y, h.z)),
				Vector2(front.position.x, front.end.y), front.end, Vector2(front.end.x, front.position.y), front.position, nw, col)
		else:
			AnnexView.quad(st, xf * (fc - e1 - e2), xf * (fc + e1 - e2), xf * (fc + e1 + e2), xf * (fc - e1 + e2), side_uv, side_uv, side_uv, side_uv, nw, col)
	return box

## A flat picture in frame xf at its origin, w by h, facing +z.
static func flat(st: SurfaceTool, xf: Transform3D, w: float, h: float, uvr: Rect2, corr: float) -> AABB:
	var col := Color(corr, 0.0, 0.0, 1.0)
	var a := xf * Vector3(-w * 0.5, -h * 0.5, 0)
	var b := xf * Vector3(w * 0.5, -h * 0.5, 0)
	var c := xf * Vector3(w * 0.5, h * 0.5, 0)
	var d := xf * Vector3(-w * 0.5, h * 0.5, 0)
	AnnexView.quad(st, a, b, c, d, Vector2(uvr.position.x, uvr.end.y), uvr.end, Vector2(uvr.end.x, uvr.position.y), uvr.position, (xf.basis * Vector3.BACK).normalized(), col)
	return AABB(a, Vector3.ZERO).expand(b).expand(c).expand(d)

# --- the walls ------------------------------------------------------------------------------------------------------

## A face's span for a piece `depth` deep: Vector2(from, to) along it; zero long when it must keep too far short.
func span_of(f: Dictionary, depth: float) -> Vector2:
	var t0 := trim(Vector2(f.g0, f.gj0), depth, f.o0)
	var t1 := trim(Vector2(f.g1, f.gj1), depth, f.o1)
	if t0 > TRIM_MAX or t1 > TRIM_MAX:
		return Vector2.ZERO
	return Vector2(t0, S - t1)

func _face(f: Dictionary, worded: bool) -> void:
	var level := int(f.level)
	var proud := BAND_D if test_break != "proud" else 0.4
	var sp := span_of(f, proud)
	var t0 := sp.x
	var span := sp.y - sp.x
	var key := _face_key(f)
	var mid := (f.a as Vector3) + (f.along as Vector3) * S * 0.5 + Vector3(0, level * LH, 0)
	var corr := _corr(mid + (f.n as Vector3) * 0.5)
	if test_break == "thin" and corr > FAR:
		return
	if test_break == "netonly" and level == 1:
		_posts_and_net(f, corr)
		return
	var stp := mid
	if span < 0.45:
		span = 0.0
	# The padded band: panels about a metre wide with a seam between, the palette by where they are.
	var n_p := maxi(1, roundi(span / 1.0)) if span > 0.0 else 0
	var pw := span / maxi(n_p, 1)
	for i in n_p:
		var am := t0 + pw * (i + 0.5)
		var y_lo := BAND_LO if test_break != "low" else 0.0
		var xf := _frame(f, am, (y_lo + BAND_HI) * 0.5, proud * 0.5)
		var sz := Vector3(pw - 0.03, BAND_HI - y_lo, proud)
		var probe := AABB(xf * (-sz * 0.5), Vector3.ZERO).expand(xf * (sz * 0.5))
		if _kept_out(probe) and test_break != "hide":
			continue
		var wpos: Vector3 = xf.origin
		var pi_ := posmod(floori((wpos.x + wpos.z) / 1.0) + level, 4)
		# Far from the lift a panel here and there is gone, never a face's first: a worn wall is never bare.
		var gone := (corr > FAR or test_break == "wear") and i > 0 and _h01(key + ":gone:%d" % i) < 0.45
		if gone:
			var g := _frame(f, am, (BAND_LO + BAND_HI) * 0.5, PAINT_D * 0.5)
			var box := flat(_st(level, stp), g, pw - 0.06, BAND_HI - BAND_LO - 0.05, uv("ghost"), corr)
			_record("ghost", f, box.grow(0.001), corr, {"ghost": true})
			continue
		var box := cuboid(_st(level, stp), xf, sz, Vector3.ZERO, uv("panel%d" % pi_), solid(pi_), corr, F_FRONT | F_SIDES | F_TOP)
		_record("band", f, box, corr, {"col": PAL[pi_]})
	# Where the wall stops near an end and a panel standing off it could cut a line grazing along the wall, the band goes
	# on painted flat in the wall's own plane (PAINT_D off it): the same panels as a picture, no depth to hide behind.
	var fsp := span_of(f, PAINT_D)
	var flats: Array[Vector2] = []
	if span <= 0.0:
		flats.append(fsp)
	else:
		flats.append(Vector2(fsp.x, sp.x - 0.015))
		flats.append(Vector2(sp.y + 0.015, fsp.y))
	for fl in flats:
		_flat_band(f, fl, corr, key, [] as Array[String])
	if worded:
		return
	# A painted picture over the band, one face in two or so.
	var psp := span_of(f, PAINT_D)
	t0 = psp.x
	span = psp.y - psp.x
	if _h01(key + ":pic") < 0.55 and span > 0.3:
		var pic: String = PICS[_h(key + ":which") % PICS.size()]
		var sz: Vector2 = PIC_SIZE[pic]
		if sz.x <= span - 0.1:
			var slack := span - sz.x
			var am := t0 + sz.x * 0.5 + slack * _h01(key + ":where")
			var y := PAINT_Y + (_h01(key + ":up") - 0.5) * 0.2
			var xf := _frame(f, am, y, PAINT_D)
			if corr > WEAR:
				xf.basis = xf.basis * Basis(Vector3.BACK, (_h01(key + ":tilt") - 0.5) * 0.12)
			var probe := face_box(xf, sz.x, sz.y, 0.05)
			if not _kept_out(probe):
				var box := flat(_st(level, stp), xf, sz.x, sz.y, uv(pic), corr)
				_record("paint", f, box.grow(0.001), corr, {"pic": pic})
	# The upper storey's play structure: padded posts at the face's ends and its middle, netting between.
	if level == 1 and not bool(f.canyon) and _netted(f):
		_posts_and_net(f, corr)

## The box a piece w by h centred on frame xf takes up, from its plane `depth` out into the room (never through the wall
## behind it: what the other side keeps clear is that side's).
static func face_box(xf: Transform3D, w: float, h: float, depth: float) -> AABB:
	var box := AABB(xf * Vector3(-w * 0.5, -h * 0.5, -0.004), Vector3.ZERO)
	for k in 8:
		box = box.expand(xf * Vector3(w * (0.5 if k & 1 else -0.5), h * (0.5 if k & 2 else -0.5), depth if k & 4 else -0.004))
	return box

## A flat painted band along a face from `fl.x` to `fl.y`: padded panels painted on the wall, PAINT_D off it. Far from
## the lift one panel in three is gone, leaving the pale patch. `ignore`: keep-outs that do not stop it (by why).
func _flat_band(f: Dictionary, fl: Vector2, corr: float, key: String, ignore: Array[String], depth := PAINT_D) -> void:
	var w := fl.y - fl.x
	if w < 0.2:
		return
	var level := int(f.level)
	var n_p := maxi(1, roundi(w / 1.0))
	var pw := w / n_p
	for i in n_p:
		var am := fl.x + pw * (i + 0.5)
		var xf := _frame(f, am, (BAND_LO + BAND_HI) * 0.5, depth if test_break != "flat" else 0.06)
		var probe := face_box(xf, pw, BAND_HI - BAND_LO, 0.05)
		if _kept_out(probe) and kept_by(probe, ignore) != "":
			continue
		var pi_ := posmod(floori((xf.origin.x + xf.origin.z) / 1.0) + level, 4)
		var gone := corr > FAR and i > 0 and _h01(key + ":flatgone:%d:%.2f" % [i, fl.x]) < 0.45
		var box := flat(_st(level, xf.origin), xf, pw - 0.03, BAND_HI - BAND_LO, uv("ghost" if gone else "panel%d" % pi_), corr)
		_record("ghost" if gone else "flatband", f, box.grow(0.001), corr, {"ghost": gone})

## The short walls either side of every doorway (its jambs, S - DOOR_W over 2 wide): the band painted flat on both
## faces, JAMB_D off them, kept short of the opening as any face is of a gap (trim(): the opening is DOOR_W long and
## a line through it can leave it grazing the jamb). A doorway's own keep-out and its zone sign (over the door, above
## the band) do not stop it.
func _jambs() -> void:
	var lift := lv._lift_edge()
	var jamb := (S - Level.DOOR_W) * 0.5
	for level in 2:
		for y in lv.H:
			for x in lv.W:
				var k := lv.kind(level, x, y)
				if k != "room" and k != "corridor" and k != "landing":
					continue
				if test_break == "jamb":
					continue
				for side in 4:
					var d: Vector2i = AnnexView.DIRS[side]
					if edge(level, x, y, d) != "door":
						continue
					var eid := Vector4i(0, x + 1 if d.x > 0 else x, y, 1) if d.x != 0 else Vector4i(1, x, y + 1 if d.y > 0 else y, 1)
					if level == lv.landing.x and eid == lift:
						continue
					# As the faces: not under the slab's opening where a line comes down steeply through the doorway.
					if _steep(level, Vector2i(x, y), d) and test_break != "hole":
						continue
					var along_i := Vector2i(absi(d.y), absi(d.x))
					var mid := lv.cell_center(level, x, y) + Vector3(d.x, 0, d.y) * (S * 0.5)
					mid.y = 0.0
					var along := Vector3(along_i.x, 0, along_i.y)
					var f := {"level": level, "cell": Vector2i(x, y), "side": side, "d": d, "n": -Vector3(d.x, 0, d.y), "along": along,
						"a": mid - along * (S * 0.5), "t0": 0.0, "t1": 0.0, "j0": 0.0, "j1": 0.0, "canyon": false, "runs_on": false}
					var corr := _corr(lv.cell_center(level, x, y))
					var key := "jamb:" + _face_key(f)
					var keep := trim(Vector2(Level.DOOR_W, 0.0), JAMB_D)
					_flat_band(f, Vector2(0.04, jamb - keep), corr, key, ["doorway", "zone sign"] as Array[String], JAMB_D)
					_flat_band(f, Vector2(S - jamb + keep, S - 0.04), corr, key, ["doorway", "zone sign"] as Array[String], JAMB_D)

func _netted(f: Dictionary) -> bool:
	var c: Vector2i = f.cell
	if lv.kind(1, c.x, c.y) == "corridor":
		return true
	return _room_kind(1, c.x, c.y) in ["deck", "nook", "den", "upper", "toddler", "ballpit", "frame"]

func _posts_and_net(f: Dictionary, corr: float) -> void:
	var depth := POST_D if test_break != "proud" else 0.5
	var sp := span_of(f, depth)
	if sp.y - sp.x < POST_W + 0.05:
		return
	var t0 := sp.x
	var t1 := S - sp.y
	var stp: Vector3 = f.a
	# A post at the face's start, and at its end where the wall does not run on into the next face (whose own start
	# post stands there).
	var spots: Array[float] = [t0 + POST_W * 0.5 + 0.01]
	if not bool(f.runs_on):
		spots.append(S - t1 - POST_W * 0.5 - 0.01)
	if test_break == "netonly":
		spots.clear()
	var pi_ := posmod(int((f.cell as Vector2i).x + (f.cell as Vector2i).y), 4)
	for am in spots:
		# Two padded sleeves stacked from FLOOR_CLEAR to POST_TOP.
		var seg := (POST_TOP - FLOOR_CLEAR) / 2.0
		var whole := AABB()
		var ok := true
		for k in 2:
			var xf := _frame(f, am, FLOOR_CLEAR + seg * (k + 0.5), depth * 0.5)
			var probe := face_box(xf, POST_W + 0.06, seg, depth)
			if _kept_out(probe):
				ok = false
				break
		if not ok:
			continue
		for k in 2:
			var xf := _frame(f, am, FLOOR_CLEAR + seg * (k + 0.5), depth * 0.5)
			var b := cuboid(_st(1, stp), xf, Vector3(POST_W, seg - 0.012, depth), Vector3.ZERO, uv("post%d" % ((pi_ + k) % 4)), solid(7 + (pi_ + k) % 4), corr,
				F_FRONT | F_SIDES | (F_TOP if k == 1 else 0))
			whole = b if k == 0 else whole.merge(b)
		_record("post", f, whole, corr)
	# The netting between the posts: see-through, the view's netting material.
	var a0 := t0 + POST_W + 0.02
	var a1 := S - t1 - POST_W - 0.02
	if a1 - a0 < 0.3:
		return
	var xf := _frame(f, (a0 + a1) * 0.5, (FLOOR_CLEAR + POST_TOP) * 0.5, NET_D)
	var w := a1 - a0
	var h := POST_TOP - FLOOR_CLEAR - 0.02
	var probe := face_box(xf, w, h, 0.05)
	if _kept_out(probe):
		return
	var col := (view.call("_tone", Color.WHITE, xf.origin) as Color)
	var ns := lv._st(1, (f.a as Vector3).x, (f.a as Vector3).z, "pnet")
	var nn := (xf.basis * Vector3.BACK).normalized()
	var box := AABB()
	for sd: float in [1.0, -1.0]:
		var o := nn * 0.004 * sd
		var p0 := xf * Vector3(-w * 0.5, -h * 0.5, 0) + o
		var p1 := xf * Vector3(w * 0.5, -h * 0.5, 0) + o
		var p2 := xf * Vector3(w * 0.5, h * 0.5, 0) + o
		var p3 := xf * Vector3(-w * 0.5, h * 0.5, 0) + o
		AnnexView.quad(ns, p0, p1, p2, p3, Vector2(0, h / 0.1), Vector2(w / 0.1, h / 0.1), Vector2(w / 0.1, 0), Vector2.ZERO, nn * sd, col)
		box = AABB(p0, Vector3.ZERO).expand(p1).expand(p2).expand(p3)
	_record("net", f, box.grow(0.005), corr, {"see": true})

# --- cut-out letters in the walkways ---------------------------------------------------------------------------------

## The words go on runs of plain wall at least WORD_RUN faces long, in walkways and the upper storey's rooms, spread
## out, at most MAX_WORDS a floor. Returns the face keys they cover (no picture goes there).
func _words(runs: Array) -> Dictionary:
	var covered := {}
	var placed: Array[Vector3] = []
	var cands: Array = []
	for run: Array in runs:
		if run.size() < 3:
			continue
		var f0: Dictionary = run[0]
		var c: Vector2i = f0.cell
		if bool(f0.canyon) or not (lv.kind(int(f0.level), c.x, c.y) == "corridor" or int(f0.level) == 1):
			continue
		cands.append(run)
	var order := {}
	for run: Array in cands:
		order[run] = _h(_face_key(run[0]))
	cands.sort_custom(func(a: Array, b: Array) -> bool: return int(order[a]) < int(order[b]))
	for run: Array in cands:
		if placed.size() >= MAX_WORDS:
			break
		var f0: Dictionary = run[0]
		var fl: Dictionary = run[run.size() - 1]
		var lt0 := trim(Vector2(f0.t0, f0.j0), LETTER_D)
		var lt1 := trim(Vector2(fl.t1, fl.j1), LETTER_D)
		if maxf(lt0, lt1) > TRIM_MAX:
			continue
		var len := run.size() * S - lt0 - lt1
		var mid_m := lt0 + len * 0.5
		var mid := (f0.a as Vector3) + (f0.along as Vector3) * mid_m + Vector3(0, int(f0.level) * LH, 0)
		var far_enough := true
		for p in placed:
			if p.distance_to(mid) < 14.0:
				far_enough = false
		if not far_enough:
			continue
		var corr := _corr(mid + (f0.n as Vector3) * 0.5)
		var text: String = WORDS[mini(int(corr * WORDS.size()), WORDS.size() - 1)]
		var width := PixelFont.width(text) * LETTER_PX
		if width > len - 0.6:
			continue
		var probe := AABB(mid - Vector3(width * 0.5, 0, width * 0.5) + Vector3(0, LETTER_TOP - 0.4, 0), Vector3(width, 0.45, width))
		if _kept_out(probe):
			continue
		_word(f0, mid_m, text, corr)
		placed.append(mid)
		for f: Dictionary in run:
			covered[_face_key(f)] = true
	return covered

func _word(f: Dictionary, mid_m: float, text: String, corr: float) -> void:
	var st := _st(int(f.level), (f.a as Vector3) + (f.along as Vector3) * mid_m)
	var width := PixelFont.width(text) * LETTER_PX
	var key := _face_key(f)
	# Reading left to right, whichever way the face's line runs.
	var sgn := signf(((-(f.n as Vector3)).cross(Vector3.UP)).dot(f.along as Vector3))
	for i in text.length():
		if text[i] == " ":
			continue
		var pi_ := i % 4
		var lx := -width * 0.5 + (i * 6 + 2.5) * LETTER_PX
		# Further in, a letter or two hangs crooked from one pin.
		var tilt := 0.0
		if corr > WEAR and _h01(key + ":tilt:%d" % i) < 0.3:
			tilt = (0.25 + 0.5 * _h01(key + ":ang:%d" % i)) * (1.0 if _h(key + ":sgn:%d" % i) % 2 == 0 else -1.0)
		var cxf := _frame(f, mid_m + lx * sgn, LETTER_TOP - 3.5 * LETTER_PX, LETTER_D * 0.5)
		cxf.basis = cxf.basis * Basis(Vector3.BACK, tilt)
		var rows := PixelFont.rows(text[i])
		var whole := AABB()
		var first := true
		for y in rows.size():
			var row: String = rows[y] + "0"
			var x0 := -1
			for x in 6:
				if row[x] == "1" and x0 < 0:
					x0 = x
				elif row[x] != "1" and x0 >= 0:
					var b := cuboid(st, cxf, Vector3(LETTER_PX * (x - x0), LETTER_PX, LETTER_D), Vector3(((x0 + x - 1) * 0.5 - 2) * LETTER_PX, (3 - y) * LETTER_PX, 0),
						Rect2(solid(pi_), Vector2.ZERO), solid(7 + pi_), corr)
					whole = b if first else whole.merge(b)
					first = false
					x0 = -1
		_record("letter", f, whole, corr, {"tilt": tilt, "text": text})
	# Where a letter is gone, the pale mark it left.
	for i in text.length():
		if text[i] == " " and i != WORD_GAP:
			var lx := -width * 0.5 + (i * 6 + 2.5) * LETTER_PX
			var g := _frame(f, mid_m + lx * sgn, LETTER_TOP - 3.5 * LETTER_PX, PAINT_D * 0.5)
			var box := flat(st, g, 5 * LETTER_PX, 7 * LETTER_PX, uv("ghost"), corr)
			_record("ghost", f, box.grow(0.001), corr, {"ghost": true})

# --- high: roof bars, bunting, hanging shapes ------------------------------------------------------------------------

## Whether a piece over cell (x, y) on `level` may hang there: the upper storey anywhere; the lower storey only in a
## room with no opening over any of its cells.
func _hang_ok(level: int, x: int, y: int) -> bool:
	if level == 1:
		return true
	var rid: int = lv.room_at[0][y * lv.W + x]
	if rid < 0:
		return false
	var r: Dictionary = lv.plan.rooms[rid]
	for yy in range(int(r.y), int(r.y) + int(r.h)):
		for xx in range(int(r.x), int(r.x) + int(r.w)):
			if _hole(xx, yy):
				return false
	return true

## A padded roof bar or two across each of the upper storey's play rooms, on the lines between cells (clear of the
## strip lights), each with a string of bunting under it.
func _roof_bars() -> void:
	for r: Dictionary in lv.plan.rooms:
		if int(r.level) != 1 or not (str(r.kind) in ["deck", "nook", "den", "upper"]):
			continue
		var w := int(r.w)
		var hh := int(r.h)
		if w < 3 or hh < 3:
			continue
		# Bars run across the room's short way, on the cell lines along its long way.
		var long_x := w >= hh
		var nl := (w if long_x else hh)
		var lines: Array[int] = []
		if nl >= 3:
			lines.append(nl / 3 if nl >= 5 else 1)
		if nl >= 6:
			lines.append(nl - nl / 3)
		for li in lines:
			var base := Vector3(int(r.x) * S, LH, int(r.y) * S)
			var a: Vector3
			var b: Vector3
			if long_x:
				a = base + Vector3((li) * S, 0, FACE + 0.02)
				b = base + Vector3((li) * S, 0, hh * S - FACE - 0.02)
			else:
				a = base + Vector3(FACE + 0.02, 0, li * S)
				b = base + Vector3(w * S - FACE - 0.02, 0, li * S)
			_bar(r, a, b)

func _bar(r: Dictionary, a: Vector3, b: Vector3) -> void:
	var mid := (a + b) * 0.5
	var corr := _corr(mid + Vector3(0, 0.1, 0))
	var dir := (b - a).normalized()
	var xf := Transform3D(Basis(dir, Vector3.UP, dir.cross(Vector3.UP)), mid + Vector3(0, BAR_LO + BAR_H * 0.5, 0))
	var st := _st(1, mid)
	var len := a.distance_to(b)
	var pi_ := int(r.id) % 4
	var box := cuboid(st, xf, Vector3(len, BAR_H, BAR_H), Vector3.ZERO, Rect2(solid(pi_), Vector2.ZERO), solid(pi_), corr, F_FRONT | F_BACK | F_TOP | F_BOTTOM)
	# Piping along its lower edges.
	for s: float in [-1.0, 1.0]:
		box = box.merge(cuboid(st, xf, Vector3(len, 0.025, 0.025), Vector3(0, -BAR_H * 0.5 + 0.0125, s * (BAR_H * 0.5 - 0.0125)), Rect2(solid(7 + (pi_ + 1) % 4), Vector2.ZERO), solid(7 + (pi_ + 1) % 4), corr, F_FRONT | F_BACK | F_BOTTOM))
	records.append({"kind": "bar", "level": 1, "aabb": box, "n": Vector3.ZERO, "face": mid, "cell": Vector2i(int(mid.x / S), int(mid.z / S)), "corr": corr,
		"see": false, "high": true, "ghost": false, "tilt": 0.0})
	_bunting(1, a + dir * 0.3 + Vector3(0, BAR_LO, 0), b - dir * 0.3 + Vector3(0, BAR_LO, 0), corr)

## Little flags under a line, down to HANG_LO.
func _bunting(level: int, a: Vector3, b: Vector3, corr: float) -> void:
	var st := _st(level, (a + b) * 0.5)
	var len := a.distance_to(b)
	var dir := (b - a) / len
	var into := Vector3(-dir.z, 0, dir.x)
	var n := int(len / 0.36)
	var col := Color(corr, 0, 0, 1)
	var box := AABB(a, Vector3.ZERO).expand(b)
	var top := a.y
	var drop := top - (level * LH + HANG_LO)
	for k in n:
		var p := a + dir * ((k + 0.5) * len / n)
		# None over a slide or tower's top, a hide or a doorway.
		if _kept_out(AABB(Vector3(p.x - 0.12, level * LH + 1.0, p.z - 0.12), Vector3(0.24, 0.5, 0.24))):
			continue
		var u := solid(k % 4)
		var p0 := p - dir * 0.11
		var p1 := p + dir * 0.11
		var p2 := p + Vector3(0, -minf(drop, 0.2) if test_break != "low" else -2.5, 0)
		for sd: float in [1.0, -1.0]:
			for q: Vector3 in ([p0, p1, p2] if sd > 0.0 else [p0, p2, p1]):
				st.set_normal(into * sd)
				st.set_color(col)
				st.set_uv(u)
				st.add_vertex(q)
		box = box.expand(p2)
	records.append({"kind": "bunting", "level": level, "aabb": box.grow(0.002), "n": Vector3.ZERO, "face": (a + b) * 0.5, "cell": Vector2i(int(a.x / S), int(a.z / S)),
		"corr": corr, "see": false, "high": true, "ghost": false, "tilt": 0.0})

## Cut-out clouds and stars hung on cords from the ceilings, a few to a room, clear of the strip lights, the ceiling's
## glowing stars, the doorways and the hides.
func _hangers() -> void:
	var star_at := {}
	for s in stars:
		var g := Vector3i(floori(s.x / S), floori(s.z / S), 1 if s.y > LH + 0.5 else 0)
		if not star_at.has(g):
			star_at[g] = []
		(star_at[g] as Array).append(s)
	for level in 2:
		for y in lv.H:
			for x in lv.W:
				var k := lv.kind(level, x, y)
				if k != "room" and k != "corridor":
					continue
				if not _hang_ok(level, x, y):
					continue
				var key := "hang:%d:%d:%d" % [level, x, y]
				if _h01(key) > (0.3 if k == "room" else 0.18):
					continue
				var c := lv.cell_center(level, x, y)
				var off := Vector3(0.55 if _h(key + ":x") % 2 == 0 else -0.55, 0, 0.55 if _h(key + ":z") % 2 == 0 else -0.55)
				var p := c + off
				var ceil_y: float = view.call("_ceiling_y", level, x, y)
				if ceil_y > level * LH + LH:
					continue
				var near_star := false
				for gz in range(floori((p.z - 0.5) / S), floori((p.z + 0.5) / S) + 1):
					for gx in range(floori((p.x - 0.5) / S), floori((p.x + 0.5) / S) + 1):
						for s: Vector3 in star_at.get(Vector3i(gx, gz, level), []):
							if absf(s.y - ceil_y) < 0.1 and Vector2(s.x - p.x, s.z - p.z).length() < 0.45:
								near_star = true
				if near_star:
					continue
				var pic: String = HANGS[_h(key + ":pic") % HANGS.size()]
				var sz: Vector2 = PIC_SIZE[pic] * 0.6
				var lo := level * LH + HANG_LO
				var probe := AABB(Vector3(p.x - 0.4, level * LH, p.z - 0.4), Vector3(0.8, LH, 0.8))
				if _kept_out(probe):
					continue
				var corr := _corr(p + Vector3(0, 0.1, 0))
				var turn := _h01(key + ":turn") * PI
				var st := _st(level, p)
				var xf := Transform3D(Basis(Vector3.UP, turn), Vector3(p.x, lo + sz.y * 0.5 if test_break != "low" else level * LH + 1.0, p.z))
				var box := flat(st, xf, sz.x, sz.y, uv(pic), corr)
				var back := xf * Transform3D(Basis(Vector3.UP, PI), Vector3(0, 0, -0.004))
				box = box.merge(flat(st, back, sz.x, sz.y, uv(pic), corr))
				# The cord to the ceiling.
				var top := xf.origin.y + sz.y * 0.5
				box = box.merge(cuboid(st, Transform3D(Basis.IDENTITY, Vector3(p.x, (top + ceil_y) * 0.5, p.z)), Vector3(0.008, ceil_y - top, 0.008), Vector3.ZERO,
					Rect2(solid(5), Vector2.ZERO), solid(5), corr, F_FRONT | F_BACK | F_SIDES))
				records.append({"kind": "hang", "level": level, "aabb": box, "n": Vector3.ZERO, "face": p, "cell": Vector2i(x, y), "corr": corr,
					"see": false, "high": true, "ghost": false, "tilt": 0.0, "pic": pic})

# --- the playhouses' fronts ------------------------------------------------------------------------------------------

## A painted door beside the shutter and a painted window box under it, flat on the front wall's outside.
func _playhouse_fronts() -> void:
	for h: Playroom.Hide in view.get("hides"):
		if h.kind != &"playhouse":
			continue
		var at := Vector3(h.inside.x / 100.0, h.level * LH, h.inside.y / 100.0)
		var g := Vector3(Floor.dir_dx(h.gap), 0, Floor.dir_dy(h.gap))
		var xf := Transform3D(Basis(Vector3.UP.cross(g).normalized(), Vector3.UP, g), at)
		var corr := _corr(at)
		var st := _st(h.level, at)
		# The front wall's outside is at d/2 = 0.42 m along the gap (playroom_view.gd _playhouse).
		var z := 0.42 + 0.0015
		var dxf := xf * Transform3D(Basis.IDENTITY, Vector3(-0.42, 0.06 + 0.36, z))
		var box := flat(st, dxf, 0.26, 0.72, uv("door"), corr)
		var wxf := xf * Transform3D(Basis.IDENTITY, Vector3(0, 0.74, z))
		box = box.merge(flat(st, wxf, 0.5, 0.09, uv("window_box"), corr))
		records.append({"kind": "playhouse_paint", "level": h.level, "aabb": box.grow(0.001), "n": Vector3.ZERO, "face": at, "cell": Playroom.cell_of(h.inside),
			"corr": corr, "see": false, "high": false, "ghost": false, "tilt": 0.0, "hide": h.id})

# --- the soft shapes -------------------------------------------------------------------------------------------------

## A soft shape the view placed (playroom_view.gd _soft_shape, from the floor's seed): `kind` 0 a cube `s` on a side
## turned `turn`, 1 a drum 0.6 across and 0.5 tall, 2 three steps 0.8 by 0.6 turned `turn`. Drawn as a soft-play piece
## inside the same box: a piped foam block or a two-tier step block; a drum with rims or a roller on a cradle; steps
## with piped noses or a wedge. Into the view's prop chunk, toned as its props.
static func soft_shape(v: Node3D, level: int, at: Vector3, kind: int, s: float, turn: float, col: Color, col2: Color) -> void:
	var lvl: Level = v.get("lv")
	var recs: Array = lvl.get_meta(&"playroom_soft", [])
	var pick := absi(hash("%s:soft:%.3f:%.3f" % [str(lvl.plan.seed), at.x, at.z])) % 2
	var pipe := col2 if col2 != col else PAL[(PAL.find(col) + 1) % 4]
	var boxes: Array = []
	var xf := Transform3D(Basis(Vector3.UP, turn), at)
	var old: Array = []
	var wedge := false
	match kind:
		0:
			old = [_bx(s, s, s, 0, 0, 0)]
			if pick == 0 or s < 0.55:
				var k := s - 0.04
				boxes = [[Vector3(k, k, k), Vector3(0, s * 0.5, 0), col]]
				for sx: float in [-1.0, 1.0]:
					for sz: float in [-1.0, 1.0]:
						boxes.append([Vector3(0.035, s, 0.035), Vector3(sx * (s * 0.5 - 0.0175), s * 0.5, sz * (s * 0.5 - 0.0175)), pipe])
					boxes.append([Vector3(s, 0.035, 0.035), Vector3(0, s - 0.0175, sx * (s * 0.5 - 0.0175)), pipe])
					boxes.append([Vector3(0.035, 0.035, s), Vector3(sx * (s * 0.5 - 0.0175), s - 0.0175, 0), pipe])
			else:
				boxes = [[Vector3(s, s * 0.5, s), Vector3(0, s * 0.25, 0), col], [Vector3(s, s * 0.5 - 0.02, s * 0.5), Vector3(0, s * 0.75 - 0.01, -s * 0.25), pipe]]
				boxes.append([Vector3(s, 0.03, 0.03), Vector3(0, s * 0.5 - 0.015, s * 0.5 - 0.015), pipe])
				boxes.append([Vector3(s, 0.03, 0.03), Vector3(0, s - 0.035, -0.015), col])
		1:
			old = [_bx(0.6, 0.5, 0.6, 0, 0, 0)]
			if pick == 0:
				v.call("_prim", level, _cyl(0.28, 0.28, 0.42, 14), Transform3D(Basis.IDENTITY, at + Vector3(0, 0.25, 0)), col, "pprops")
				for y: float in [0.025, 0.475]:
					v.call("_prim", level, _cyl(0.3, 0.3, 0.05, 14), Transform3D(Basis.IDENTITY, at + Vector3(0, y, 0)), pipe, "pprops")
				boxes = [[Vector3(0.02, 0.42, 0.02), Vector3(0, 0.25, 0.285), pipe]]
			else:
				var axis := Basis(Vector3.FORWARD, PI * 0.5) if absi(hash(at)) % 2 == 0 else Basis(Vector3.RIGHT, PI * 0.5)
				v.call("_prim", level, _cyl(0.2, 0.2, 0.54, 14), Transform3D(axis, at + Vector3(0, 0.26, 0)), col, "pprops")
				for e: float in [-0.25, 0.25]:
					v.call("_prim", level, _cyl(0.205, 0.205, 0.03, 14), Transform3D(axis, at + Vector3(0, 0.26, 0) + axis * Vector3(0, e, 0)), pipe, "pprops")
				var long := axis * Vector3.UP
				boxes = [[Vector3(0.5, 0.08, 0.3) if absf(long.x) > 0.5 else Vector3(0.3, 0.08, 0.5), Vector3(0, 0.04, 0), pipe]]
		_:
			old = [_bx(0.8, 0.6, 0.6, 0, 0, 0)]
			if pick == 0:
				boxes = [[Vector3(0.8, 0.2, 0.6), Vector3(0, 0.1, 0), col], [Vector3(0.8, 0.2, 0.4), Vector3(0, 0.3, -0.1), col2], [Vector3(0.8, 0.2, 0.2), Vector3(0, 0.5, -0.2), col]]
				for i in 3:
					boxes.append([Vector3(0.8, 0.03, 0.03), Vector3(0, 0.2 * (i + 1) - 0.015, 0.3 - 0.2 * i - 0.015), pipe if i != 1 else col])
			else:
				boxes = [[Vector3(0.8, 0.1, 0.6), Vector3(0, 0.05, 0), col2]]
				_wedge(v, level, xf, col)
				wedge = true
	if test_break == "soft":
		boxes.append([Vector3(1.2, 0.2, 1.2), Vector3(0, 0.1, 0), col])
	var drawn := AABB(xf * Vector3.ZERO, Vector3.ZERO)
	if wedge:
		for k in 4:
			drawn = drawn.expand(xf * Vector3(0.4 if k & 1 else -0.4, 0.6 if k & 2 else 0.1, -0.3 if k & 2 else 0.3))
	for b: Array in boxes:
		var h: Vector3 = (b[0] as Vector3) * 0.5
		for k in 8:
			drawn = drawn.expand(xf * ((b[1] as Vector3) + Vector3(h.x * (1 if k & 1 else -1), h.y * (1 if k & 2 else -1), h.z * (1 if k & 4 else -1))))
	v.call("_boxes", level, xf, boxes, "pprops")
	var ob := AABB(xf * Vector3.ZERO, Vector3.ZERO)
	var oh: Vector3 = (old[0][0] as Vector3) * 0.5
	var oc: Vector3 = old[0][1]
	var oxf := xf if kind != 1 else Transform3D(Basis.IDENTITY, at)
	for k in 8:
		ob = ob.expand(oxf * (oc + Vector3(oh.x * (1 if k & 1 else -1), oh.y * (1 if k & 2 else -1), oh.z * (1 if k & 4 else -1))))
	if kind == 1:
		drawn = drawn.merge(AABB(at + Vector3(-0.3, 0, -0.3), Vector3(0.6, 0.5, 0.6)) if pick == 0 else AABB(at + Vector3(-0.27, 0.06, -0.27), Vector3(0.54, 0.4, 0.54)))
	recs.append({"kind": "soft", "shape": kind, "pick": pick, "level": level, "aabb": drawn, "old": ob, "col": col, "corr": lvl.corruption_at(at)})
	lvl.set_meta(&"playroom_soft", recs)

static func _cyl(r: float, r2: float, h: float, seg: int) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = r
	c.bottom_radius = r2
	c.height = h
	c.radial_segments = seg
	c.rings = 1
	return c

static func _bx(sx: float, sy: float, sz: float, cx: float, y0: float, cz: float) -> Array:
	return [Vector3(sx, sy, sz), Vector3(cx, y0 + sy * 0.5, cz)]

## A foam wedge 0.8 wide, 0.6 deep, rising from 0.1 m at its front (+z) to 0.6 m at its back, on a 0.1 m base.
static func _wedge(v: Node3D, level: int, xf: Transform3D, col: Color) -> void:
	var lvl: Level = v.get("lv")
	var st := lvl._st(level, xf.origin.x, xf.origin.z, "pprops")
	var c := v.call("_tone", col, xf.origin) as Color
	var hw := 0.4
	var p := [Vector3(-hw, 0.1, 0.3), Vector3(hw, 0.1, 0.3), Vector3(hw, 0.6, -0.3), Vector3(-hw, 0.6, -0.3), Vector3(-hw, 0.1, -0.3), Vector3(hw, 0.1, -0.3)]
	var w: Array[Vector3] = []
	for q: Vector3 in p:
		w.append(xf * q)
	var slope := (xf.basis * Vector3(0, 0.6, 0.5)).normalized()
	AnnexView.quad(st, w[0], w[1], w[2], w[3], Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, slope, c)
	AnnexView.quad(st, w[3], w[2], w[5], w[4], Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, (xf.basis * Vector3.FORWARD).normalized(), Color(c.r * 0.92, c.g * 0.92, c.b * 0.92, 1.0))
	for tri: Array in [[w[0], w[3], w[4], (xf.basis * Vector3.LEFT).normalized()], [w[1], w[5], w[2], (xf.basis * Vector3.RIGHT).normalized()]]:
		for i in 3:
			st.set_normal(tri[3])
			st.set_color(Color(c.r * 0.96, c.g * 0.96, c.b * 0.96, 1.0))
			st.set_uv(Vector2.ZERO)
			st.add_vertex(tri[i])

# --- committing -----------------------------------------------------------------------------------------------------

## The dressing's material: the view's lit shader (it goes dark with the strip lights, no glow), mode 0 (the atlas,
## bleached by the corruption in the vertex colour's red), cut out where the atlas is clear.
static func material(v: Node3D) -> ShaderMaterial:
	# Its own light as the view's walls (playroom_view.gd SELF_WALL), scaled with the strip lights by the view.
	var m: ShaderMaterial = v.call("_shade", atlas(), 0, 0.5, 0.5)
	if test_break == "glow":
		(v.get("_lit_mats") as Array).erase(m)
	return m
