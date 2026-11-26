# LA3: the Clinic's wall, ceiling and furniture-top dressing (looks only). Bed-head service panels behind the beds the
# rules place, the bed bays' curtains drawn back and bunched flat on the wall with their rails on the ceiling, ward
# whiteboards, hand-wash notices, towel and glove dispensers, clocks, notice boards, fire points, plain signs in the
# company's dry tone, the atrium's reception sign, directory, wall planters and banner, and a jug and a cup, a kidney
# dish or a box of supplies at the back of the lockers and cabinets the rules place. Near the lift every piece is clean
# and straight; with the walk from the lift (Level.corruption, the measure the walls' and the ceiling's grime already
# use) the same pieces yellow, hang crooked, tear, or are gone, leaving a pale patch where they hung.
#
# Nothing here is a rule, and nothing here may change what a player can see. The rules decide looking from the plan
# alone (sim/sight.gd), so every piece goes where no line between two spots the plan lets a body stand can reach it:
#  - at eye height only on a CLOSED wall run: a whole side of a room (or a corridor) with no door or opening in it,
#    ending at the room's own corners. A body keeps 30 cm off every wall line; a piece reaches at most 22 cm from the
#    line (the wall's 7 cm half thickness and PROUD_MAX), so inside a room's rectangle no line between two bodies comes
#    near it, and a line from outside comes in through a door in another side, at least 40 cm off this one;
#  - high (HIGH_Y and up) in a closed room on the lower storey, or anywhere on the upper storey: no eye is above 1.65 m
#    and no point of a figure above 2.6 m, and on the lower storey only a line through the atrium's or a stair's
#    opening rises above that, which never passes through a closed room;
#  - on top of furniture the rules already place, only within the same 22 cm of a closed run's wall;
#  - the nurse-call lamp over a doorway, high (a figure standing in the doorway reaches up past the lintel).
# tests/test_clinic_dress.gd checks it from the plan's own sight check. No piece has collision (the client draws no
# solids), none is a light, none casts a shadow, and none goes on a cell next to the landing (the call button).
#
# Everything is placed from the plan, the rules' hides and furniture, and hashes of the floor's seed and the spot,
# so every screen draws the same dressing. One atlas texture drawn here by code, one material, and the pieces merged
# into one mesh per GROUP cells square and storey (named like the walls' chunks, so the lower storey's go on its
# layer).
extends RefCounted

const FloorLib = preload("res://sim/floor.gd")
const PlayroomLib = preload("res://sim/playroom.gd")
const ANNEX_VIEW = preload("res://client/annex_view.gd")
const PixelFont = preload("res://client/pixel_font.gd")

## A piece stands at most this far off its wall face (m).
const PROUD_MAX := 0.15
## The wall's half thickness: a wall face stands this far off the wall line.
const FACE := 0.07
## The lowest point of a high piece over its floor (m): above every point of a figure the rules look at (2.6 m).
const HIGH_Y := 2.65
## A piece at eye height starts this high over its floor (above the bumper rail).
const EYE_LO := 1.33
## No piece on a cell this many walking steps or fewer from the landing (the call button and the lift's board).
const LIFT_CLEAR := 1
## How far the bed bay's curtain rail runs out from the wall face, and its height over the floor.
const BAY_DEPTH := 1.45
const RAIL_Y := 2.78
## Where the bunched curtain hangs along the wall from the bed's middle (beyond the bed's end, 1.025 m).
const CURTAIN_AT := 1.24
## The things on a piece of furniture stand within this far of its wall's face (m).
const TOP_REACH := 0.15
## The pieces are merged into one mesh per GROUP cells square per storey (few enough lamps meet each for the renderer's per-mesh limit: tests/test_light_pairs.gd).
const GROUP := 6
## The atlas texture's size, texels.
const ATLAS_W := 256
const ATLAS_H := 512

const PAPER := Color(0.95, 0.94, 0.89)
const CREAM := Color(0.88, 0.87, 0.8)
const STEEL := Color(0.72, 0.75, 0.76)
const CURTAIN := Color(0.62, 0.78, 0.76)
## The tint a piece takes on far from the lift (mixed in by the corruption), and a stain's.
const GRIME := Color(0.78, 0.7, 0.47)
const STAIN := Color(0.52, 0.44, 0.3)
## A pale patch on the wall where a piece hung and is gone.
const GHOST := Color(0.86, 0.87, 0.83)

## The sign texts: dry, plain, and never about looking or about what lives here.
const WASH: Array[String] = ["WASH HANDS", "BEFORE.", "AND AFTER.", "AND BEFORE."]
const STORES: Array[String] = ["STORES", "SIGN FOR", "WHAT YOU", "TAKE."]
const WAIT: Array[String] = ["PLEASE WAIT", "TO BE", "CALLED."]
const FIRE: Array[String] = ["FIRE", "POINT"]
const DIRECTORY: Array[String] = ["DIRECTORY", "0 WARDS", "0 EXAMINATION", "0 NURSES", "1 WARDS", "1 STORES"]
const RECEPTION: Array[String] = ["RECEPTION"]
const BANNER: Array[String] = ["YOUR CARE IS", "OUR CONCERN"]
const PLATES: Array[String] = ["KEEP CLEAR", "NO TROLLEYS", "QUIET PLEASE", "CORRIDOR"]
const ROTA: Array[String] = ["ROTA", "MON  ----", "TUE  ----", "WED  -", "THU", "FRI"]
const LABELS: Array[String] = ["GLOVES", "TOWELS"]
const BED_MARKS: Array[String] = ["----", "--", "---", "-----", "-", "--"]

## Every text the dressing prints (the test reads them all).
static func texts() -> Array[String]:
	var out: Array[String] = []
	for group: Array in [WASH, STORES, WAIT, FIRE, DIRECTORY, RECEPTION, BANNER, PLATES, ROTA, LABELS]:
		for s: String in group:
			out.append(s)
	for i in range(1, 10):
		out.append("WARD %d" % i)
	for n in range(1, 7):
		out.append_array(_board_rows(n))
	return out

static func _board_rows(n: int) -> Array[String]:
	var rows: Array[String] = ["ON THE WARD"]
	for b in range(1, n + 1):
		rows.append("BED %d  %s" % [b, BED_MARKS[b - 1]])
	return rows

## Tests only: leaves the Clinic undressed (to compare a floor with and without it).
static var off := false
static var _atlas_tex: ImageTexture
static var _uv := {}

# --- the atlas -------------------------------------------------------------------------------------

## The one texture every piece samples: the plain white block, the signs and notices (the notices also torn), the
## clock faces, the cork board's papers, the chart and the whiteboards. Drawn once.
static func atlas() -> ImageTexture:
	if _atlas_tex != null:
		return _atlas_tex
	var img := Image.create(ATLAS_W, ATLAS_H, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var pk := {"x": 0, "y": 0, "row": 0}
	img.fill_rect(_alloc(pk, "white", Vector2i(4, 4)), Color.WHITE)
	var ink := Color(0.15, 0.15, 0.17)
	var blue := Color(0.15, 0.25, 0.6)
	_text(img, pk, "wash", WASH, PAPER, Color(0.1, 0.35, 0.55), true)
	_text(img, pk, "stores", STORES, PAPER, ink, true)
	_text(img, pk, "wait", WAIT, PAPER, ink, true)
	_text(img, pk, "fire", FIRE, Color(0.78, 0.1, 0.08), Color.WHITE, true)
	_text(img, pk, "directory", DIRECTORY, Color(0.1, 0.2, 0.33), Color(0.92, 0.93, 0.9), false)
	_text(img, pk, "reception", RECEPTION, Color(0.08, 0.36, 0.38), Color(0.95, 0.96, 0.93), false)
	_text(img, pk, "banner", BANNER, Color(0.1, 0.42, 0.44), Color(0.97, 0.97, 0.93), false)
	_text(img, pk, "gloves", [LABELS[0]], Color(0.9, 0.92, 0.95), blue, false)
	_text(img, pk, "towels", [LABELS[1]], Color(0.9, 0.92, 0.95), blue, false)
	_text(img, pk, "rota", ROTA, Color(0.97, 0.97, 0.97), blue, false)
	for i in PLATES.size():
		_text(img, pk, "plate%d" % i, [PLATES[i]], Color(0.1, 0.36, 0.34), Color(0.95, 0.96, 0.92), true)
	for i in range(1, 10):
		_text(img, pk, "ward%d" % i, ["WARD %d" % i], Color(0.12, 0.3, 0.45), Color(0.96, 0.96, 0.92), false)
	for n in range(1, 7):
		_text(img, pk, "board%d" % n, _board_rows(n), Color(0.97, 0.97, 0.97), blue, false)
	_draw_clock(img, _alloc(pk, "clock", Vector2i(25, 25)), 10, 8)
	_draw_clock(img, _alloc(pk, "clock_stopped", Vector2i(25, 25)), 3, 47)
	_draw_cork(img, _alloc(pk, "cork", Vector2i(40, 28)))
	var r := _alloc(pk, "chart", Vector2i(16, 22))
	img.fill_rect(r, PAPER)
	for k in 6:
		img.fill_rect(Rect2i(r.position.x + 2, r.position.y + 4 + k * 3, 9 + (k * 5) % 4, 1), Color(0.35, 0.35, 0.4))
	_atlas_tex = ImageTexture.create_from_image(img)
	return _atlas_tex

## The region `name` in the atlas, in uv ("<name>_torn": its torn copy, where there is one).
static func uv(name: String) -> Rect2:
	atlas()
	return _uv.get(name, _uv["white"])

static func has_region(name: String) -> bool:
	atlas()
	return _uv.has(name)

## A free rectangle of the atlas for `name` (shelf packing, a texel apart).
static func _alloc(pk: Dictionary, name: String, size: Vector2i) -> Rect2i:
	if int(pk.x) + size.x + 1 > ATLAS_W:
		pk.x = 0
		pk.y = int(pk.y) + int(pk.row) + 1
		pk.row = 0
	var r := Rect2i(int(pk.x), int(pk.y), size.x, size.y)
	if r.end.y > ATLAS_H:
		push_error("clinic_dress: the atlas is full at %s" % name)
	_uv[name] = Rect2(Vector2(r.position) / Vector2(ATLAS_W, ATLAS_H), Vector2(r.size) / Vector2(ATLAS_W, ATLAS_H))
	pk.x = int(pk.x) + size.x + 1
	pk.row = maxi(int(pk.row), size.y)
	return r

static func _text(img: Image, pk: Dictionary, name: String, rows: Array, bg: Color, ink: Color, torn: bool) -> void:
	var w := 0
	for s: String in rows:
		w = maxi(w, PixelFont.width(s))
	var size := Vector2i(w + 4, rows.size() * 9 + 3)
	for copy in (2 if torn else 1):
		var r := _alloc(pk, name if copy == 0 else name + "_torn", size)
		img.fill_rect(r, bg)
		for k in rows.size():
			PixelFont.blit(img, rows[k], r.position + Vector2i(2, 2 + k * 9), ink)
		if copy == 1:
			# Its lower right corner torn away (cleared: the material cuts it out).
			var cut := mini(r.size.x, r.size.y) * 2 / 3
			for yy in cut:
				for xx in yy + 1:
					img.set_pixel(r.end.x - 1 - xx, r.end.y - cut + yy, Color(0, 0, 0, 0))

static func _draw_clock(img: Image, r: Rect2i, hour: int, minute: int) -> void:
	var c := Vector2(r.position) + Vector2(r.size) * 0.5
	var rad := r.size.x * 0.5
	for yy in r.size.y:
		for xx in r.size.x:
			var d := (Vector2(r.position.x + xx + 0.5, r.position.y + yy + 0.5) - c).length()
			if d <= rad:
				img.set_pixel(r.position.x + xx, r.position.y + yy, Color(0.12, 0.12, 0.13) if d > rad - 1.6 else Color(0.97, 0.97, 0.95))
	for k in 12:
		var a := TAU * k / 12.0
		img.set_pixelv(Vector2i(c + Vector2(sin(a), -cos(a)) * (rad - 3.0)), Color(0.1, 0.1, 0.1))
	for hand: Array in [[(hour % 12 + minute / 60.0) / 12.0, rad * 0.5], [minute / 60.0, rad * 0.8]]:
		var a: float = TAU * float(hand[0])
		for s in int(float(hand[1])):
			img.set_pixelv(Vector2i(c + Vector2(sin(a), -cos(a)) * s), Color(0.08, 0.08, 0.08))

static func _draw_cork(img: Image, r: Rect2i) -> void:
	img.fill_rect(r, Color(0.55, 0.4, 0.25))
	var papers: Array = [[2, 3, 10, 12, Color(0.95, 0.94, 0.88)], [14, 2, 9, 8, Color(0.95, 0.9, 0.55)], [25, 4, 12, 10, Color(0.95, 0.94, 0.88)],
		[5, 16, 12, 9, Color(0.75, 0.85, 0.95)], [20, 14, 8, 11, Color(0.95, 0.94, 0.88)], [30, 17, 8, 8, Color(0.98, 0.75, 0.7)]]
	for p: Array in papers:
		img.fill_rect(Rect2i(r.position.x + int(p[0]), r.position.y + int(p[1]), int(p[2]), int(p[3])), p[4])
		for k in (int(p[3]) - 3) / 2:
			img.fill_rect(Rect2i(r.position.x + int(p[0]) + 2, r.position.y + int(p[1]) + 2 + k * 2, int(p[2]) - 4, 1), Color(0.4, 0.4, 0.42))

# --- building --------------------------------------------------------------------------------------

var lv: Level
var _sts := {}
var _seed := ""
## What was placed: one record per box (tests). See _record.
var records: Array[Dictionary] = []
## The wall slots already taken: "level:x:y:sx:sy".
var _taken := {}
## Per level: the rules' furniture as drawn, with its top ({rect, top, piece, kind, hide, searchable, wall, wall_at}).
var _furniture: Array = [[], []]
## Per level: what no piece may touch below its top: each hide's and findable's body, and the floor in front of it (a
## hide's open side out past its front spot and a body; a findable's front out 70 cm), to 2.2 m. {rect, top, piece}.
var _keep: Array = [[], []]
var _ward_no := 0
## The piece now being placed: every box of one placement shares it (tests merge them).
var _pid := 0
## How worn the piece now being placed is (0 clean, 1 fully grimed): _tint sets it.
var _dirt := 0.0

## Dresses a built Clinic level (walls, furniture and lights are already there). Returns the records, also kept as the
## level's "dressing" meta.
static func build(level: Level) -> Array[Dictionary]:
	if off:
		return []
	var k := new()
	k.lv = level
	k._seed = "%s:%s" % [str(level.plan.get("seed", "")), str(level.plan.get("depth", 0))]
	k._index_furniture()
	for r: Dictionary in level.plan.rooms:
		k._room(r)
	k._corridors()
	k._commit()
	level.set_meta(&"dressing", k.records)
	return k.records

func _index_furniture() -> void:
	var by_id := {}
	for pc in lv.pieces:
		by_id[pc.id] = pc
	for d: Dictionary in lv.furniture_drawn:
		var pc: Variant = by_id.get(d.piece)
		if pc == null:
			continue
		(_furniture[pc.level] as Array).append({"rect": d.rect, "top": float(d.get("top", 2.0)), "piece": pc.id, "kind": String(pc.kind), "hide": pc.hide,
			"searchable": pc.searchable, "wall": pc.wall, "wall_at": pc.wall_at})
		if int(pc.hide) < 0 and not bool(pc.searchable):
			continue
		var rect: Rect2 = d.rect
		var front: Rect2
		if int(pc.hide) >= 0:
			var h: PlayroomLib.Hide = lv.hides[int(pc.hide)]
			var xf := ANNEX_VIEW.hide_xf(h)
			var hh := ANNEX_VIEW.hide_half(h.kind)
			var zf := (xf.affine_inverse() * Vector3(h.front.x / 100.0, xf.origin.y, h.front.y / 100.0)).z - 0.3
			var a := xf * Vector3(-hh.x, 0, zf)
			var b := xf * Vector3(hh.x, 0, -hh.y)
			front = Rect2(Vector2(minf(a.x, b.x), minf(a.z, b.z)), Vector2(absf(b.x - a.x), absf(b.z - a.z)))
		else:
			var fv := Vector2i(FloorLib.dir_dx(pc.facing), FloorLib.dir_dy(pc.facing))
			if fv.x > 0: front = Rect2(rect.end.x, rect.position.y, 0.7, rect.size.y)
			elif fv.x < 0: front = Rect2(rect.position.x - 0.7, rect.position.y, 0.7, rect.size.y)
			elif fv.y > 0: front = Rect2(rect.position.x, rect.end.y, rect.size.x, 0.7)
			else: front = Rect2(rect.position.x, rect.position.y - 0.7, rect.size.x, 0.7)
		(_keep[pc.level] as Array).append({"rect": rect, "top": float(d.get("top", 2.0)), "piece": pc.id})
		(_keep[pc.level] as Array).append({"rect": front, "top": 2.2, "piece": pc.id})

## Whether a piece on the floor plan `r` whose foot is `y_lo` over its floor would touch a hide or a findable (its body
## or the floor in front of it, see _keep); `own` a furniture piece it may sit over (a bed's own panel).
func _crowds(level: int, r: Rect2, y_lo: float, own := -1) -> bool:
	for k: Dictionary in _keep[level]:
		if int(k.piece) != own and y_lo < float(k.top) and (k.rect as Rect2).intersects(r.grow(0.01)):
			return true
	return false

## The floor plan of a slot's wall face out to `out` m, `half` m either way along it.
func _strip(s: Dictionary, half: float, out: float) -> Rect2:
	var at: Vector3 = s.at
	var along: Vector3 = s.along
	var n: Vector3 = s.n
	var a := at - along * half
	var b := at + along * half + n * out
	return Rect2(Vector2(minf(a.x, b.x), minf(a.z, b.z)), Vector2(absf(b.x - a.x), absf(b.z - a.z)))

## A number in [0, 1) from the floor's seed and `key`: the same on every screen.
func _h(key: String) -> float:
	return float(hash(_seed + ":" + key) & 0xFFFFFF) / float(0x1000000)

# --- wall slots ------------------------------------------------------------------------------------

## The kind of the edge on side `v` (a unit step toward it) of cell (x, y).
func _edge(level: int, x: int, y: int, v: Vector2i) -> String:
	if x < 0 or y < 0 or x >= lv.W or y >= lv.H:
		return "none"
	var vert: Array = lv.edges[level].vertical
	var hor: Array = lv.edges[level].horizontal
	if v == Vector2i(0, -1): return hor[y * lv.W + x]
	if v == Vector2i(0, 1): return hor[(y + 1) * lv.W + x]
	if v == Vector2i(-1, 0): return vert[y * (lv.W + 1) + x]
	return vert[y * (lv.W + 1) + x + 1]

## The region a cell belongs to: its room's id, -2 for a corridor, -9 for anything else.
func _region(level: int, x: int, y: int) -> int:
	var k := lv.kind(level, x, y)
	if k == "room":
		return int(lv.room_at[level][y * lv.W + x])
	if k == "corridor":
		return -2
	return -9

## Whether the wall on side `v` of cell c runs whole from corner to corner of its room (or corridor): every cell along
## it in the same region has a plain wall on that side, and both ends meet a plain wall across (the room's corners).
func closed_run(level: int, c: Vector2i, v: Vector2i) -> bool:
	if _edge(level, c.x, c.y, v) != "wall":
		return false
	var reg := _region(level, c.x, c.y)
	for u: Vector2i in [Vector2i(-v.y, v.x), Vector2i(v.y, -v.x)]:
		var e := c
		var steps := 0
		while _edge(level, e.x, e.y, u) != "wall":
			var nx := e + u
			if _region(level, nx.x, nx.y) != reg or _edge(level, nx.x, nx.y, v) != "wall" or steps > 64:
				return false
			e = nx
			steps += 1
	return true

## Whether every outer edge of a room is a plain wall or a door: nothing is seen into it but through a doorway.
func closed_room(r: Dictionary) -> bool:
	var level := int(r.level)
	for y in range(int(r.y), int(r.y) + int(r.h)):
		for x in range(int(r.x), int(r.x) + int(r.w)):
			if _region(level, x, y) != int(r.id):
				continue
			for v: Vector2i in [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]:
				var n := Vector2i(x, y) + v
				if _region(level, n.x, n.y) == int(r.id):
					continue
				var e := _edge(level, x, y, v)
				if e != "wall" and e != "door":
					return false
	return true

## A slot: the middle of cell c's wall on side v, at its floor: {level, cell, v, at (on the wall face), along, n, key}.
func _slot(level: int, c: Vector2i, v: Vector2i) -> Dictionary:
	var centre := lv.cell_center(level, c.x, c.y)
	var n := Vector3(-v.x, 0, -v.y)
	var at := centre - n * (Level.S * 0.5 - FACE)
	return {"level": level, "cell": c, "v": v, "at": at, "along": Vector3(-v.y, 0, v.x), "n": n, "key": "%d:%d:%d:%d:%d" % [level, c.x, c.y, v.x, v.y],
		"corr": lv.corruption(level, c.x, c.y)}

## The highest top of the furniture standing in front of a slot's wall (within `half` along it, 45 cm out), 0 for none.
func _furniture_top(s: Dictionary, half := 0.8) -> float:
	var at: Vector3 = s.at
	var along: Vector3 = s.along
	var n: Vector3 = s.n
	var a := at - along * half - n * FACE
	var b := at + along * half + n * 0.45
	var strip := Rect2(Vector2(minf(a.x, b.x), minf(a.z, b.z)), Vector2(absf(b.x - a.x), absf(b.z - a.z)))
	var top := 0.0
	for f: Dictionary in _furniture[int(s.level)]:
		if (f.rect as Rect2).intersects(strip):
			top = maxf(top, float(f.top))
	return top

## The plain walls of some cells that may take a piece (none next to the landing), in the seed's order.
func _slots_of(level: int, cells: Array[Vector2i]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for c in cells:
		var d := lv.dist[lv.pidx(level, c.x, c.y)]
		if d >= 0 and d <= LIFT_CLEAR:
			continue
		for v: Vector2i in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
			if _edge(level, c.x, c.y, v) != "wall":
				continue
			var s := _slot(level, c, v)
			if _taken.has(s.key):
				continue
			s["closed"] = closed_run(level, c, v)
			s["top"] = _furniture_top(s)
			s["crowds"] = _crowds(level, _strip(s, 0.8, PROUD_MAX + 0.01), EYE_LO - 0.05)
			out.append(s)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return _h(a.key) < _h(b.key))
	return out

## The first slot of `slots` free for a piece high up (nothing tall in front) or at eye height (a closed run, nothing
## standing in front).
func _take(slots: Array[Dictionary], high: bool) -> Dictionary:
	for s in slots:
		if _taken.has(s.key):
			continue
		if high:
			if float(s.top) > HIGH_Y - 0.3:
				continue
		elif not bool(s.closed) or float(s.top) > 0.0 or bool(s.crowds):
			continue
		_taken[s.key] = true
		return s
	return {}

# --- the rooms -------------------------------------------------------------------------------------

func _room(r: Dictionary) -> void:
	var level := int(r.level)
	var cells: Array[Vector2i] = []
	for y in range(int(r.y), int(r.y) + int(r.h)):
		for x in range(int(r.x), int(r.x) + int(r.w)):
			if _region(level, x, y) == int(r.id):
				cells.append(Vector2i(x, y))
	var closed := closed_room(r)
	# High pieces on the lower storey only in a closed room: a line through the atrium's opening rises past 2.6 m.
	var high_ok := closed or level == 1
	var kind := str(r.kind)
	var beds := 0
	if kind == "ward" or kind == "exam":
		for h: PlayroomLib.Hide in lv.hides:
			if h.room == int(r.id) and h.kind == &"bed":
				beds += 1
				_bed_bay(h, high_ok)
		if closed:
			_door_lamps(r)
	_tops(r)
	var slots := _slots_of(level, cells)
	match kind:
		"ward":
			_ward_no += 1
			_board(_take(slots, false), "board%d" % clampi(beds, 1, 6), 1.0)
			_wash(_take(slots, false), true)
			if high_ok:
				_clock(_take(slots, true))
				_ward_sign(r, cells)
		"exam":
			_wash(_take(slots, false), false)
			_chart(_take(slots, false))
			if high_ok:
				_clock(_take(slots, true))
		"station":
			_cork(_take(slots, false))
			_board(_take(slots, false), "rota", 0.62)
			_flat(_take(slots, false), "fire", 0.0, EYE_LO + 0.2, 0.28, 0.012, true, "fire")
			if high_ok:
				_clock(_take(slots, true))
		"closet":
			_flat(_take(slots, false), "stores", 0.0, EYE_LO + 0.15, 0.34, 0.004, true, "notice")
		"lobby":
			_board(_take(slots, false), "directory", 0.9)
			_flat(_take(slots, false), "wait", 0.0, EYE_LO + 0.15, 0.42, 0.004, true, "notice")
			if high_ok:
				_clock(_take(slots, true))
		"atrium":
			_atrium(r, slots, high_ok)

## The atrium: the reception sign and a banner high on its walls, but only where the storey above has a floor over the
## wall and no opening near (nothing looks down along that wall); the directory board and two wall planters at eye
## height on closed runs.
func _atrium(r: Dictionary, slots: Array[Dictionary], high_ok: bool) -> void:
	var level := int(r.level)
	var high: Array[Dictionary] = []
	for s in slots:
		if high_ok or (level == 0 and _no_hole_near(s.cell, 2)):
			high.append(s)
	_flat(_take(high, true), "reception", 0.0, HIGH_Y + 0.03, 1.9, 0.02, false, "reception")
	_flat(_take(high, true), "banner", 0.0, HIGH_Y + 0.02, 1.6, 0.012, false, "banner")
	_board(_take(slots, false), "directory", 0.9)
	for i in 2:
		_planter(_take(slots, false))

## Whether no cell of the upper storey within `reach` cells of c is an opening.
func _no_hole_near(c: Vector2i, reach: int) -> bool:
	for y in range(c.y - reach, c.y + reach + 1):
		for x in range(c.x - reach, c.x + reach + 1):
			var k := lv.kind(1, x, y)
			if k == "atriumOpen" or k == "stair":
				return false
	return true

## The corridors: here and there a plain sign, a fire point or a clock high on the wall; a notice board or a glove
## dispenser at eye height where a corridor's wall runs whole from corner to corner.
func _corridors() -> void:
	for level in 2:
		var cells: Array[Vector2i] = []
		for y in lv.H:
			for x in lv.W:
				if lv.kind(level, x, y) == "corridor":
					cells.append(Vector2i(x, y))
		var used: Array[Vector2i] = []
		var i := 0
		for s in _slots_of(level, cells):
			var c: Vector2i = s.cell
			if _h(s.key + ":corr") > 0.3:
				continue
			var near := false
			for u in used:
				if absi(u.x - c.x) + absi(u.y - c.y) < 3:
					near = true
			if near:
				continue
			# High on the lower storey only well away from the openings (a line from upstairs comes down through them).
			var high_ok := level == 1 or _no_hole_near(c, 8)
			if bool(s.closed) and float(s.top) == 0.0 and not bool(s.crowds):
				_taken[s.key] = true
				if i % 2 == 0:
					_cork(s)
				else:
					_dispenser(s, 0.0, "gloves", Color(0.85, 0.88, 0.9))
			elif high_ok and float(s.top) <= HIGH_Y - 0.3:
				_taken[s.key] = true
				match i % 3:
					0: _flat(s, "plate%d" % (int(_h(s.key + ":plate") * PLATES.size()) % PLATES.size()), 0.0, HIGH_Y + 0.03, 0.9, 0.02, true, "plate")
					1: _flat(s, "fire", 0.0, HIGH_Y + 0.03, 0.3, 0.015, true, "fire")
					2: _clock(s)
			else:
				continue
			used.append(c)
			i += 1

# --- the pieces ------------------------------------------------------------------------------------

## The tint a piece at corruption `t` takes (clean white near the lift, GRIME far from it); its amount is kept for the
## records of the boxes placed next.
func _tint(t: float) -> Color:
	_dirt = smoothstep(0.25, 0.9, t)
	return Color.WHITE.lerp(GRIME, _dirt)

## How worn a piece at corruption `t` is: {tint, tilt (radians about the wall's normal), gone, torn, dirt}.
func _wear(key: String, t: float, can_go := true, can_tilt := true) -> Dictionary:
	var tint := _tint(t)
	var dirt := _dirt
	var tilt := 0.0
	if can_tilt and t > 0.45:
		tilt = (_h(key + ":tilt") * 2.0 - 1.0) * 0.28 * smoothstep(0.45, 1.0, t)
	var gone := can_go and t > 0.55 and _h(key + ":gone") < (t - 0.55) * 1.1
	var torn := t > 0.5 and _h(key + ":torn") < 0.6
	return {"tint": tint, "tilt": tilt, "gone": gone, "torn": torn, "dirt": dirt}

## A flat plate on a wall slot: `region` on its face, `w` wide and as tall as the region's shape, centred `off` along
## the wall with its foot `y0` over the floor, `depth` thick. Far from the lift it may hang crooked, be torn (the
## region's torn copy) or be gone (a pale patch where it hung).
func _flat(s: Dictionary, region: String, off: float, y0: float, w: float, depth: float, can_go: bool, kind: String) -> void:
	_pid += 1
	if s.is_empty():
		return
	var r := uv(region)
	var hgt := w * (r.size.y * ATLAS_H) / (r.size.x * ATLAS_W)
	var wear := _wear(s.key + ":" + region, float(s.corr), can_go, kind != "reception" and kind != "banner")
	if bool(wear.gone):
		_part(s, off, y0 + hgt * 0.5, Vector3(w, hgt, 0.002), uv("white"), GHOST, 0.0, kind, true)
		return
	var rr := r
	if bool(wear.torn) and has_region(region + "_torn"):
		rr = uv(region + "_torn")
	# A crooked plate keeps its lowest corner over its foot (it turns about its middle).
	var tilt := float(wear.tilt)
	var lift := (absf(sin(tilt)) * w * 0.5 + (cos(tilt) - 1.0) * hgt * 0.5) if tilt != 0.0 else 0.0
	_part(s, off, y0 + hgt * 0.5 + maxf(lift, 0.0), Vector3(w, hgt, depth), rr, wear.tint, tilt, kind)
	if float(s.corr) > 0.65 and _h(s.key + ":" + region + ":stain") < 0.5:
		_stain(s, off + w * 0.5 + 0.06, y0, y0 + hgt)

## A whiteboard (the ward's beds, the station's rota, the directory) in a thin frame, `w` wide.
func _board(s: Dictionary, region: String, w: float) -> void:
	_pid += 1
	if s.is_empty():
		return
	var r := uv(region)
	var hgt := w * (r.size.y * ATLAS_H) / (r.size.x * ATLAS_W)
	var y := EYE_LO + 0.06 + hgt * 0.5
	var wear := _wear(s.key + ":board", float(s.corr), false)
	var tint: Color = wear.tint
	var tilt: float = float(wear.tilt) * 0.2
	_part(s, 0.0, y, Vector3(w + 0.05, hgt + 0.05, 0.02), uv("white"), STEEL * tint, tilt, "board")
	_part(s, 0.0, y, Vector3(w, hgt, 0.026), r, tint, tilt, "board")
	if float(s.corr) > 0.6:
		_stain(s, w * 0.5 + 0.1, EYE_LO + 0.06, EYE_LO + 0.06 + hgt)

func _wash(s: Dictionary, towels: bool) -> void:
	if s.is_empty():
		return
	_flat(s, "wash", -0.28, EYE_LO + 0.14, 0.3, 0.004, true, "notice")
	_dispenser(s, 0.24, "towels" if towels else "gloves", Color(0.88, 0.9, 0.92))

## A wall dispenser (paper towels, gloves): a white box with a label.
func _dispenser(s: Dictionary, off: float, label: String, col: Color) -> void:
	_pid += 1
	if s.is_empty():
		return
	var wear := _wear(s.key + ":disp", float(s.corr), true, false)
	var y := EYE_LO + 0.2
	if bool(wear.gone):
		_part(s, off, y, Vector3(0.28, 0.34, 0.002), uv("white"), GHOST, 0.0, "dispenser", true)
		return
	var tint: Color = wear.tint
	_part(s, off, y, Vector3(0.28, 0.34, 0.11), uv("white"), col * tint, 0.0, "dispenser")
	var r := uv(label)
	_part(s, off, y + 0.07, Vector3(0.2, 0.2 * (r.size.y * ATLAS_H) / (r.size.x * ATLAS_W), 0.112), r, tint, 0.0, "dispenser")

## A clipboard on a hook (a chart).
func _chart(s: Dictionary) -> void:
	_pid += 1
	if s.is_empty():
		return
	var wear := _wear(s.key + ":chart", float(s.corr))
	if bool(wear.gone):
		return
	var tilt := float(wear.tilt) * 0.5
	_part(s, 0.0, EYE_LO + 0.24, Vector3(0.24, 0.33, 0.012), uv("white"), Color(0.42, 0.3, 0.2) * (wear.tint as Color), tilt, "chart")
	_part(s, 0.0, EYE_LO + 0.22, Vector3(0.2, 0.275, 0.016), uv("chart"), wear.tint, tilt, "chart")

## A cork notice board with papers pinned on it.
func _cork(s: Dictionary) -> void:
	_pid += 1
	if s.is_empty():
		return
	var wear := _wear(s.key + ":cork", float(s.corr), false)
	var tilt := float(wear.tilt) * 0.2
	_part(s, 0.0, EYE_LO + 0.4, Vector3(0.95, 0.67, 0.025), uv("white"), Color(0.4, 0.32, 0.24) * (wear.tint as Color), tilt, "cork")
	_part(s, 0.0, EYE_LO + 0.4, Vector3(0.9, 0.62, 0.03), uv("cork"), wear.tint, tilt, "cork")

## A wall clock high up (its face round: the atlas leaves the corners clear). Far from the lift it has stopped.
func _clock(s: Dictionary) -> void:
	_pid += 1
	if s.is_empty():
		return
	var y := HIGH_Y + 0.22
	var wear := _wear(s.key + ":clock", float(s.corr))
	if bool(wear.gone):
		_part(s, 0.0, y, Vector3(0.3, 0.3, 0.002), uv("white"), GHOST, 0.0, "clock", true)
		return
	_part(s, 0.0, y, Vector3(0.3, 0.3, 0.03), uv("clock_stopped" if float(s.corr) > 0.6 else "clock"), wear.tint, float(wear.tilt) * 0.5, "clock")

## A planter on the wall: a trough and a few leaves, at most 10 cm proud.
func _planter(s: Dictionary) -> void:
	_pid += 1
	if s.is_empty():
		return
	var wear := _wear(s.key + ":plant", float(s.corr), false, false)
	var dirt: float = wear.dirt
	_part(s, 0.0, EYE_LO + 0.1, Vector3(0.8, 0.18, 0.1), uv("white"), Color(0.45, 0.5, 0.5) * (wear.tint as Color), 0.0, "planter")
	var green := Color(0.25, 0.48, 0.24).lerp(Color(0.45, 0.4, 0.2), dirt)
	for k in 7:
		var off := -0.33 + k * 0.11
		var hh := 0.16 + 0.14 * _h(s.key + ":leaf%d" % k) * (1.0 - dirt * 0.7)
		_part(s, off, EYE_LO + 0.19 + hh * 0.5, Vector3(0.06, hh, 0.06), uv("white"), green * (0.85 + 0.3 * _h(s.key + ":g%d" % k)), (k - 3) * 0.08, "planter", false, 0.02)

## A brown streak down the wall beside a piece far from the lift, from `y1` down to `y0` (never below EYE_LO).
func _stain(s: Dictionary, off: float, y0: float, y1: float) -> void:
	_pid += 1
	y0 = maxf(y0, EYE_LO)
	if y1 - y0 < 0.05:
		return
	_part(s, off, (y0 + y1) * 0.5, Vector3(0.07, y1 - y0, 0.0015), uv("white"), STAIN, 0.0, "stain", true)

## The ward's hanging sign, from the ceiling of a cell with no lamp panel near the ward's middle, its number on both
## faces, its foot above RAIL_Y.
func _ward_sign(r: Dictionary, cells: Array[Vector2i]) -> void:
	var level := int(r.level)
	var best := Vector2i(-1, -1)
	var mid := Vector2(int(r.x) + int(r.w) * 0.5, int(r.y) + int(r.h) * 0.5)
	for c in cells:
		if lv._want_panel(level, c.x, c.y):
			continue
		if best.x < 0 or (Vector2(c) + Vector2(0.5, 0.5)).distance_to(mid) < (Vector2(best) + Vector2(0.5, 0.5)).distance_to(mid):
			best = c
	if best.x < 0:
		return
	_pid += 1
	var key := "%d:%d:%d:wardsign" % [level, best.x, best.y]
	var t := lv.corruption(level, best.x, best.y)
	var wear := _wear(key, t)
	if bool(wear.gone):
		return
	var centre := lv.cell_center(level, best.x, best.y)
	# Across the room's long axis, so it reads from either end.
	var along := Vector3(1, 0, 0) if int(r.h) >= int(r.w) else Vector3(0, 0, 1)
	var n := along.cross(Vector3.UP)
	var reg := uv("ward%d" % clampi(_ward_no, 1, 9))
	var w := 0.7
	var hh := w * (reg.size.y * ATLAS_H) / (reg.size.x * ATLAS_W)
	var tilt: float = float(wear.tilt) * 0.3
	var y := centre.y + RAIL_Y + 0.03 + hh * 0.5 + absf(sin(tilt)) * w * 0.5
	var ceil_y := centre.y + Level.LH
	var tint: Color = wear.tint
	var c3 := Vector3(centre.x, y, centre.z)
	var bx := Basis(along, Vector3.UP, n) * Basis(Vector3(0, 0, 1), tilt)
	var box := _box_at(level, Transform3D(bx, c3 + n * 0.006), Vector3(w, hh, 0.012), Vector3(0, 0, -0.006), reg, tint)
	var back := Basis(-along, Vector3.UP, -n) * Basis(Vector3(0, 0, 1), -tilt)
	box = box.merge(_box_at(level, Transform3D(back, c3 - n * 0.0065), Vector3(w, hh, 0.001), Vector3(0, 0, -0.0005), reg, tint))
	for k: float in [-0.3, 0.3]:
		var top := c3 + bx * Vector3(k, hh * 0.5, 0)
		box = box.merge(_box_at(level, Transform3D(Basis(), Vector3(top.x, (top.y + ceil_y) * 0.5, top.z)), Vector3(0.008, ceil_y - top.y, 0.008), Vector3.ZERO, uv("white"), STEEL))
	_record("ward_sign", level, best, box, Vector3.ZERO, Vector3.ZERO, t, tilt, tint, true, -1)

## Over each doorway of a closed ward or exam room, on the room's side: the nurse-call lamp (a dome; no light).
func _door_lamps(r: Dictionary) -> void:
	var level := int(r.level)
	for y in range(int(r.y), int(r.y) + int(r.h)):
		for x in range(int(r.x), int(r.x) + int(r.w)):
			if _region(level, x, y) != int(r.id):
				continue
			for v: Vector2i in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
				if _edge(level, x, y, v) != "door":
					continue
				var s := _slot(level, Vector2i(x, y), v)
				_pid += 1
				var tint := _tint(float(s.corr))
				_part(s, 0.0, HIGH_Y + 0.07, Vector3(0.16, 0.1, 0.03), uv("white"), CREAM * tint, 0.0, "call_lamp")
				_part(s, 0.0, HIGH_Y + 0.07, Vector3(0.1, 0.07, 0.07), uv("white"), Color(0.85, 0.75, 0.55) * tint, 0.0, "call_lamp")

## A bed bay: the service panel on the wall behind the bed (sockets, the gas outlet, the call button, a rail for the
## clipboards, a reading lamp's hood: not a light), the bay's curtain drawn back and bunched flat on the wall beside the
## bed, and the curtain's rail round the bay on the ceiling.
func _bed_bay(h: PlayroomLib.Hide, high_ok: bool) -> void:
	var xf := ANNEX_VIEW.hide_xf(h)
	var level := h.level
	# The hide's frame: x along the bed (its head at -x), +z toward the wall; the bed's back is on the wall line.
	var inset := ANNEX_VIEW.hide_half(&"bed").y
	var along := (xf.basis * Vector3(1, 0, 0)).normalized()
	var n := (xf.basis * Vector3(0, 0, -1)).normalized()
	var line := xf.origin - n * inset
	var wv := Vector2i(roundi(-n.x), roundi(-n.z))
	var cell := Vector2i(floori(xf.origin.x / Level.S), floori(xf.origin.z / Level.S))
	var at := Vector3(line.x, level * Level.LH, line.z) + n * FACE
	var s := {"level": level, "cell": cell, "v": wv, "at": at, "along": along, "n": n, "key": "bed%d" % h.id, "corr": lv.corruption(level, cell.x, cell.y)}
	_taken["%d:%d:%d:%d:%d" % [level, cell.x, cell.y, wv.x, wv.y]] = true
	var t := float(s.corr)
	var tint := _tint(t)
	var own := -1
	for pc in lv.pieces:
		if pc.hide == h.id:
			own = pc.id
	s["own"] = own
	if closed_run(level, cell, wv) and not _crowds(level, _strip(s, 0.9, 0.12), 1.38, own):
		_pid += 1
		_part(s, 0.0, 1.5, Vector3(1.7, 0.22, 0.04), uv("white"), CREAM * tint, 0.0, "bed_panel")
		for k: float in [-0.62, -0.5]:
			_part(s, k, 1.5, Vector3(0.08, 0.08, 0.05), uv("white"), Color(0.96, 0.96, 0.94) * tint, 0.0, "bed_panel")
		_part(s, -0.28, 1.5, Vector3(0.07, 0.07, 0.06), uv("white"), Color(0.25, 0.6, 0.35) * tint, 0.0, "bed_panel")
		_part(s, -0.12, 1.5, Vector3(0.05, 0.05, 0.055), uv("white"), Color(0.8, 0.15, 0.12) * tint, 0.0, "bed_panel")
		_part(s, 0.45, 1.5, Vector3(0.5, 0.05, 0.05), uv("white"), Color(0.6, 0.62, 0.62) * tint, 0.0, "bed_panel")
		_part(s, 0.45, 1.67, Vector3(0.2, 0.28, 0.012), uv("chart"), tint, 0.0, "bed_panel")
		_part(s, -0.55, 1.7, Vector3(0.3, 0.07, 0.1), uv("white"), Color(0.8, 0.8, 0.76) * tint, 0.0, "bed_panel")
		if t > 0.6:
			_stain(s, -0.2, 1.4, 1.39 + 0.3 * _h(str(s.key) + ":stain"))
		_curtain(s)
	if high_ok:
		_bay_rail(s)

## The bay's curtain, bunched flat on the wall beyond one end of the bed (the head where it is free). Far from the
## lift it hangs torn short and ragged.
func _curtain(s: Dictionary) -> void:
	var level := int(s.level)
	var along: Vector3 = s.along
	var n: Vector3 = s.n
	var at: Vector3 = s.at
	var cell0: Vector2i = s.cell
	var wv: Vector2i = s.v
	for end: float in [-1.0, 1.0]:
		var off := end * CURTAIN_AT
		var c := at + along * off
		var cell := Vector2i(floori(c.x / Level.S), floori(c.z / Level.S))
		if _region(level, cell.x, cell.y) != _region(level, cell0.x, cell0.y) or not closed_run(level, cell, wv):
			continue
		var a := c - along * 0.17
		var b := c + along * 0.17 + n * 0.13
		var foot := Rect2(Vector2(minf(a.x, b.x), minf(a.z, b.z)), Vector2(absf(b.x - a.x), absf(b.z - a.z))).grow(0.02)
		var clear := not _crowds(level, foot, 0.3, int(s.get("own", -1)))
		for f: Dictionary in _furniture[level]:
			if (f.rect as Rect2).intersects(foot):
				clear = false
		if not clear:
			continue
		_pid += 1
		var t := float(s.corr)
		var col := CURTAIN * _tint(t)
		var bottom := 0.32 + (0.45 * _h(str(s.key) + ":rag") if t > 0.55 else 0.0)
		for k in 4:
			var fo := off - 0.12 + k * 0.08
			var d := 0.08 + 0.04 * float(k % 2)
			var bk := bottom + (0.12 * _h(str(s.key) + ":rag%d" % k) if t > 0.55 else 0.0)
			_part(s, fo, (RAIL_Y + bk) * 0.5, Vector3(0.085, RAIL_Y - bk, d), uv("white"), col * (0.92 + 0.08 * float(k % 2)), 0.0, "curtain")
		return

## The curtain's rail round the bay, on the ceiling: out from the wall beyond each end of the bed and across its front.
func _bay_rail(s: Dictionary) -> void:
	var level := int(s.level)
	var along: Vector3 = s.along
	var n: Vector3 = s.n
	var at: Vector3 = s.at
	var cell0: Vector2i = s.cell
	var region := _region(level, cell0.x, cell0.y)
	var pts: Array[Vector3] = [at - along * CURTAIN_AT, at - along * CURTAIN_AT + n * BAY_DEPTH, at + along * CURTAIN_AT + n * BAY_DEPTH, at + along * CURTAIN_AT]
	for p in pts:
		var q := p + n * 0.01
		if _region(level, floori(q.x / Level.S), floori(q.z / Level.S)) != region:
			return
	_pid += 1
	var y := level * Level.LH + RAIL_Y
	var ceil_y := (level + 1) * Level.LH
	var col := STEEL * _tint(float(s.corr))
	var box := AABB(Vector3(pts[0].x, y, pts[0].z), Vector3.ZERO)
	for i in 3:
		var a := pts[i]
		var b := pts[i + 1]
		var dir := (b - a).normalized()
		var bx := Basis(dir, Vector3.UP, dir.cross(Vector3.UP))
		var mid := (a + b) * 0.5
		box = box.merge(_box_at(level, Transform3D(bx, Vector3(mid.x, y, mid.z)), Vector3(a.distance_to(b) + 0.03, 0.03, 0.03), Vector3.ZERO, uv("white"), col))
	for p: Vector3 in [pts[1], pts[2]]:
		box = box.merge(_box_at(level, Transform3D(Basis(), Vector3(p.x, (y + ceil_y) * 0.5, p.z)), Vector3(0.012, ceil_y - y, 0.012), Vector3.ZERO, uv("white"), col))
	_record("bay_rail", level, cell0, box, Vector3.ZERO, Vector3.ZERO, float(s.corr), 0.0, col, true, -1)

## The things on top of the lockers, drawers and cabinets the rules place in a room: at the back, against the wall,
## where that wall is a closed run. Every piece of those kinds gets them alike (searchable or not).
func _tops(r: Dictionary) -> void:
	var level := int(r.level)
	for f: Dictionary in _furniture[level]:
		if int(f.hide) >= 0:
			continue
		var kind := str(f.kind)
		if not kind in ["side_table", "drawers_low", "cabinet_tall"]:
			continue
		var rect: Rect2 = f.rect
		var c := rect.get_center()
		var cell := Vector2i(floori(c.x / Level.S), floori(c.y / Level.S))
		var wall: StringName = f.wall
		if wall == &"":
			continue
		var wv := Vector2i(FloorLib.dir_dx(wall), FloorLib.dir_dy(wall))
		if wv.x != 0:
			cell.x = floori((int(f.wall_at) - wv.x * 100) / 200.0)
		else:
			cell.y = floori((int(f.wall_at) - wv.y * 100) / 200.0)
		if _region(level, cell.x, cell.y) != int(r.id) or not closed_run(level, cell, wv):
			continue
		# Clear of the floor in front of every hide and findable nearby (their fronts reach 70 cm and more).
		var crowded := false
		for g: Dictionary in _furniture[level]:
			if int(g.piece) != int(f.piece) and (int(g.hide) >= 0 or bool(g.searchable)) and (g.rect as Rect2).grow(1.0).intersects(rect):
				crowded = true
		if crowded:
			continue
		var s := _slot(level, cell, wv)
		s["key"] = "top%d" % int(f.piece)
		var along: Vector3 = s.along
		var n: Vector3 = s.n
		var face_pt: Vector3 = s.at
		# How far off the wall face the piece's back stands, and the room left behind TOP_REACH.
		var back := INF
		for k in 4:
			var q := rect.position + Vector2(rect.size.x * float(k % 2), rect.size.y * float(k / 2))
			back = minf(back, (Vector3(q.x, face_pt.y, q.y) - face_pt).dot(n))
		var fo := maxf(back, 0.0) + 0.01
		var room := TOP_REACH - fo
		if room < 0.05:
			continue
		var off := (Vector3(c.x, face_pt.y, c.y) - face_pt).dot(along)
		var top := float(f.top)
		var wear := _wear(str(s.key), float(s.corr), true, false)
		if bool(wear.gone):
			continue
		var tint: Color = wear.tint
		var p := int(f.piece)
		_pid += 1
		if kind == "side_table":
			# A water jug and a cup.
			_part(s, off - 0.1, top + 0.11, Vector3(0.09, 0.22, minf(0.09, room)), uv("white"), Color(0.82, 0.86, 0.9) * tint, 0.0, "top", false, fo, p)
			_part(s, off + 0.06, top + 0.05, Vector3(0.06, 0.1, minf(0.06, room)), uv("white"), Color(0.93, 0.93, 0.9) * tint, 0.0, "top", false, fo, p)
		elif kind == "drawers_low":
			# A kidney dish and a folded blanket.
			_part(s, off - 0.15, top + 0.02, Vector3(0.24, 0.04, minf(0.1, room)), uv("white"), STEEL * tint, 0.0, "top", false, fo, p)
			_part(s, off + 0.15, top + 0.05, Vector3(0.3, 0.1, minf(0.12, room)), uv("white"), Color(0.7, 0.78, 0.82).lerp(Color(0.62, 0.58, 0.42), float(wear.dirt)), 0.0, "top", false, fo, p)
		else:
			# Two boxes of supplies.
			_part(s, off - 0.12, top + 0.09, Vector3(0.3, 0.18, minf(0.14, room)), uv("white"), Color(0.62, 0.5, 0.34) * tint, 0.0, "top", false, fo, p)
			_part(s, off + 0.2, top + 0.06, Vector3(0.22, 0.12, minf(0.12, room)), uv("white"), Color(0.72, 0.62, 0.45) * tint, 0.0, "top", false, fo, p)

# --- geometry --------------------------------------------------------------------------------------

## One box on a wall slot: centred `off` along the wall and `y` over the floor, `size` (along, up, out of the wall),
## its back `gap` off the wall face, turned `tilt` about the wall's normal. `region` on its front face.
func _part(s: Dictionary, off: float, y: float, size: Vector3, region: Rect2, col: Color, tilt: float, kind: String, ghost := false, gap := 0.001, on := -1) -> void:
	var level := int(s.level)
	var at: Vector3 = s.at
	var along: Vector3 = s.along
	var n: Vector3 = s.n
	var b := Basis(along, Vector3.UP, n) * Basis(Vector3(0, 0, 1), tilt)
	var origin := Vector3(at.x, level * Level.LH + y, at.z) + along * off + n * (gap + size.z * 0.5)
	var box := _box_at(level, Transform3D(b, origin), size, Vector3.ZERO, region, col)
	_record(kind, level, s.cell, box, at, n, float(s.corr), tilt, col, false, on, ghost)

## A box into the dressing's chunk meshes: `xf` its frame, `size` its edges, `c` its middle in that frame. The region
## goes on its +z face; the other faces take the white block. Returns its bounding box in level space.
func _box_at(level: int, xf: Transform3D, size: Vector3, c: Vector3, region: Rect2, col: Color) -> AABB:
	var key := "%d_%d_%d_ldress" % [level, floori(xf.origin.x / (Level.S * GROUP)), floori(xf.origin.z / (Level.S * GROUP))]
	if not _sts.has(key):
		var st0 := SurfaceTool.new()
		st0.begin(Mesh.PRIMITIVE_TRIANGLES)
		_sts[key] = st0
	var st: SurfaceTool = _sts[key]
	var h := size * 0.5
	var white := uv("white").get_center()
	var out := AABB(xf * c, Vector3.ZERO)
	for f: Array in [[Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)], [Vector3(0, 0, -1), Vector3(-1, 0, 0), Vector3(0, 1, 0)],
			[Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)], [Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)],
			[Vector3(0, 1, 0), Vector3(1, 0, 0), Vector3(0, 0, -1)], [Vector3(0, -1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)]]:
		var fn: Vector3 = f[0]
		var u: Vector3 = f[1]
		var v: Vector3 = f[2]
		var fc := c + fn * h
		var eu := u * h
		var ev := v * h
		var p: Array[Vector3] = [fc - eu - ev, fc + eu - ev, fc + eu + ev, fc - eu + ev]
		var uvs: Array[Vector2] = [white, white, white, white]
		if fn.z > 0.5:
			uvs = [Vector2(region.position.x, region.end.y), region.end, Vector2(region.end.x, region.position.y), region.position]
		var nw := (xf.basis * fn).normalized()
		# Wound so the face looks along its normal.
		var order: Array[int] = [0, 1, 2, 0, 2, 3]
		if (xf * p[1] - xf * p[0]).cross(xf * p[3] - xf * p[0]).dot(nw) > 0.0:
			order = [0, 2, 1, 0, 3, 2]
		for i in order:
			st.set_normal(nw)
			st.set_color(col)
			st.set_uv(uvs[i])
			var q := xf * p[i]
			st.add_vertex(q)
			out = out.expand(q)
	return out

func _record(kind: String, level: int, cell: Vector2i, box: AABB, face: Vector3, n: Vector3, corr: float, tilt: float, col: Color, high: bool, on: int, ghost := false) -> void:
	records.append({"kind": kind, "piece": _pid, "level": level, "cell": cell, "aabb": box, "face": face, "n": n, "corr": corr,
		"dirt": _dirt, "tilt": tilt, "tint": col, "high": high, "on": on, "ghost": ghost})

func _commit() -> void:
	if _sts.is_empty():
		return
	var mat := Level.prop_material(Color.WHITE, atlas(), true, 0.5)
	for key: String in _sts:
		var st: SurfaceTool = _sts[key]
		st.index()
		var mi := MeshInstance3D.new()
		mi.name = key
		mi.mesh = st.commit()
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		lv.add_child(mi)
	_sts.clear()
