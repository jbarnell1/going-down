# LA2: the Annex dressed as an office people left (looks only; client/annex_view.gd calls it). An art judge, 21 Nov:
# rooms were "mostly empty carpet", walls "plain panels with no skirting detail, sockets, posters", "the atrium is a
# big empty box". This adds, with no collision and no light:
#   - skirting board along the foot of every wall, power sockets, a light switch beside every room's doorways;
#   - things on top of the furniture the rules already place (sim/furniture.gd): phones, in-trays, mugs, an unlit
#     desk lamp, paper; nothing new stands on the floor (furniture is solid, and solids are the rules');
#   - hanging department signs and cable trays in the rooms, 2.3 m up or more;
#   - the atrium: a long company banner and wall planters high on its walls, hanging signs, and planters hung on
#     the void side of its balcony rails.
# The Annex's own law is sameness. Everything in a room is laid out in the room's canonical frame (annex_view.gd
# Shape, room_xf), from its shape and kind alone, never its position or a random draw, so same-shaped rooms are
# dressed identically down to the mug; it is recorded in the view's `records`, which same_shape_problems compares.
# A corridor cell gets only what its own walls decide (skirting, sockets on every fourth straight cell, a planter
# on a balcony rail), so every junction looks like every other junction of its make (tests/test_annex_dress.gd).
# Wall pieces stand at most PROUD off the wall face where the Temp's sticky notes go (annex_notes_view.gd draws them
# 1.8 cm off it), so a note always draws in front; crew marks lie on the floor, where only the skirting reaches.
extends RefCounted

const AV = preload("res://client/annex_view.gd")
const Furniture = preload("res://sim/furniture.gd")

## Off for the tests that compare the Annex with and without the dressing (the Annex as it was before LA2).
static var enabled := true

const S := 2.0
const LH := 3.2
const FACE := 0.07
const SKIRT_H := 0.15
const SKIRT_T := 0.014
## How far a wall-hung piece below 2.2 m stands off the wall face, at most (a note draws 1.8 cm off it).
const PROUD := 0.014
const SOCKET_Y := 0.3
const SWITCH_Y := 1.15
const SIGN_Y := 2.55
const TRAY_Y := 2.85
const PLANTER_Y := 2.32

const SKIRT := Color(0.4, 0.34, 0.25)
const SKIRT_TOP := Color(0.46, 0.4, 0.3)
const SLATE := Color(0.2, 0.23, 0.25)
const ROD := Color(0.55, 0.57, 0.57)
const TRAY := Color(0.5, 0.52, 0.52)
const CABLE := Color(0.24, 0.25, 0.27)
const CONCRETE := Color(0.62, 0.6, 0.54)
const MUG := Color(0.86, 0.85, 0.79)
const MUG2 := Color(0.32, 0.43, 0.6)
const MUG3 := Color(0.46, 0.56, 0.34)
const SHADE := Color(0.24, 0.38, 0.3)
const REAM := Color(0.86, 0.84, 0.72)
const REAM2 := Color(0.76, 0.8, 0.86)
const TIN := Color(0.3, 0.45, 0.55)
const NEWS := Color(0.8, 0.8, 0.76)
const GLASS := Color(0.72, 0.8, 0.82)

## A hanging department sign's name by room kind (the atlas has one board each); the closet has none.
const DEPARTMENTS := {
	"lobby": "RECEPTION", "office": "ACCOUNTS", "cubicles": "RECORDS", "meeting": "MEETING", "copy": "REPRO",
	"store": "STORES", "break": "STAFF ROOM", "atrium": "ENQUIRIES",
}
## Room kinds with a cable tray along the ceiling.
const TRAYS: Array[String] = ["office", "cubicles", "copy", "store"]

static var _tops := {}

## The view's dressing, after its furniture and pictures.
static func dress(v: AV) -> void:
	# Where the hides stand (as drawn), per storey: no skirting, socket or switch inside one.
	v.hide_rects = [[], []]
	var level_of := {}
	for pc: Furniture.Piece in v.lv.pieces:
		if pc.hide >= 0:
			level_of[pc.id] = pc.level
	for d: Dictionary in v.lv.furniture_drawn:
		if level_of.has(int(d.piece)):
			(v.hide_rects[int(level_of[int(d.piece)])] as Array).append((d.rect as Rect2).grow(0.01))
	_skirting(v)
	_corridors(v)
	for r: Dictionary in v.lv.plan.rooms:
		_room(v, r)
	_balconies(v)

# --- drawing and recording ---------------------------------------------------------------------

## Boxes ([size, centre, colour] in xf's frame) drawn into the props chunks, and recorded: the piece in `dressing`
## (its boxes kept for the tests, see world_boxes), and in `records` when it belongs to a room. `hidden`: the one face
## of every box that is never seen (a wall piece's back, wall_xf -z), left out.
static func put(v: AV, level: int, room: int, cell: Vector2i, type: String, xf: Transform3D, boxes: Array, hidden := Vector3.ZERO) -> void:
	var st := v.lv._st(level, xf.origin.x, xf.origin.z, "aprops")
	for b: Array in boxes:
		AV.box(st, xf, b[0], b[1], b[2], hidden)
	v.dressing.append({"level": level, "room": room, "cell": cell, "type": type, "xf": xf, "boxes": boxes})
	if room >= 0:
		v.records.append({"room": room, "type": "dress:" + type, "xf": xf})

## A flat atlas picture at `at` facing `n`, recorded as a box of no depth.
static func pic(v: AV, level: int, room: int, cell: Vector2i, type: String, at: Vector3, n: Vector3, w: float, h: float, rect: Rect2i) -> void:
	AV.picture(v.lv._st(level, at.x, at.z, "adecal"), at, n, w, h, AV.atlas_uv(rect))
	var xf := Transform3D(Basis(Vector3(n.z, 0, -n.x), Vector3.UP, n), at)
	v.dressing.append({"level": level, "room": room, "cell": cell, "type": type, "xf": xf, "boxes": [[Vector3(w, h, 0.0), Vector3.ZERO, Color.WHITE]]})
	if room >= 0:
		v.records.append({"room": room, "type": "dress:" + type, "xf": xf})

static func aabb_of(xf: Transform3D, size: Vector3, c: Vector3) -> AABB:
	var out := AABB(xf * c, Vector3.ZERO)
	for sx: float in [-0.5, 0.5]:
		for sy: float in [-0.5, 0.5]:
			for sz: float in [-0.5, 0.5]:
				out = out.expand(xf * (c + Vector3(size.x * sx, size.y * sy, size.z * sz)))
	return out

## Every box of the dressing in the world (tests): {level, room, cell, type, aabb}.
static func world_boxes(v: AV) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for d: Dictionary in v.dressing:
		for b: Array in d.boxes:
			out.append({"level": d.level, "room": d.room, "cell": d.cell, "type": d.type, "aabb": aabb_of(d.xf, b[0], b[1])})
	return out

## A frame on a wall: origin on the wall face at height y over the floor of `level`, x along the wall, z into the
## cell (n), y up.
static func wall_xf(level: int, line_pt: Vector3, n: Vector3, y: float) -> Transform3D:
	var along := Vector3(n.z, 0, -n.x)
	return Transform3D(Basis(along, Vector3.UP, n), Vector3(line_pt.x, level * LH + y, line_pt.z) + n * FACE)

# --- skirting -------------------------------------------------------------------------------------

## Along the foot of every solid wall part, on each side whose cell is walked on (not a stair's slope): a front and
## a top face, reaching past a free wall end as the wall itself does. Merged into one run along a straight wall for
## as long as it faces the same room (or corridor).
static func _skirting(v: AV) -> void:
	var lv := v.lv
	var lift_edge := lv._lift_edge()
	for level in 2:
		var vert: Array = lv.edges[level].vertical
		var hor: Array = lv.edges[level].horizontal
		for x in v.W + 1:
			var runs := [null, null]
			for y in v.H:
				var k: String = vert[y * (v.W + 1) + x]
				var is_lift := level == lv.landing.x and lift_edge == Vector4i(0, x, y, 1)
				if k != "wall" and k != "door" and not is_lift:
					_flush(v, level, runs, 0)
					_flush(v, level, runs, 1)
					continue
				var before: String = vert[(y - 1) * (v.W + 1) + x] if y > 0 else "none"
				var after: String = vert[(y + 1) * (v.W + 1) + x] if y + 1 < v.H else "none"
				_skirt_edge(v, level, k, is_lift, Vector3(x * S, 0, y * S), Vector3(0, 0, 1), Vector2i(x - 1, y), Vector2i(x, y), lv._ext(k, before), lv._ext(k, after), runs)
			_flush(v, level, runs, 0)
			_flush(v, level, runs, 1)
		for y in v.H + 1:
			var runs := [null, null]
			for x in v.W:
				var k: String = hor[y * v.W + x]
				var is_lift := level == lv.landing.x and lift_edge == Vector4i(1, x, y, 1)
				if k != "wall" and k != "door" and not is_lift:
					_flush(v, level, runs, 0)
					_flush(v, level, runs, 1)
					continue
				var before: String = hor[y * v.W + x - 1] if x > 0 else "none"
				var after: String = hor[y * v.W + x + 1] if x + 1 < v.W else "none"
				_skirt_edge(v, level, k, is_lift, Vector3(x * S, 0, y * S), Vector3(1, 0, 0), Vector2i(x, y - 1), Vector2i(x, y), lv._ext(k, before), lv._ext(k, after), runs)
			_flush(v, level, runs, 0)
			_flush(v, level, runs, 1)

## One edge's solid foot, added to the open run on each side ([a side, b side]: {p0, p1, n, room, cell}) or
## starting a new one.
static func _skirt_edge(v: AV, level: int, k: String, is_lift: bool, start: Vector3, dir: Vector3, a: Vector2i, b: Vector2i, ext0: bool, ext1: bool, runs: Array) -> void:
	var solid := k == "wall" or k == "door" or is_lift
	var lv := v.lv
	var na := -Vector3(dir.z, 0, dir.x)
	var parts: Array = lv._edge_parts(level, k, is_lift) if solid else []
	for si in 2:
		var cell: Vector2i = a if si == 0 else b
		var n: Vector3 = na if si == 0 else -na
		if not solid or not lv.walkable(level, cell.x, cell.y) or lv.kind(level, cell.x, cell.y) == "stair":
			_flush(v, level, runs, si)
			continue
		var room: int = lv.room_at[level][cell.y * v.W + cell.x]
		for part: Array in parts:
			if part.size() > 3 or float(part[1]) > 0.001:
				continue
			for seg: Array in part[0]:
				var f: float = seg[0]
				var t: float = seg[1]
				if f <= 0.001 and ext0:
					f -= FACE
				if t >= S - 0.001 and ext1:
					t += FACE
				var p0 := start + dir * f
				var p1 := start + dir * t
				var run: Variant = runs[si]
				if run != null and int(run.room) == room and (run.p1 as Vector3).distance_to(p0) < 0.001:
					run.p1 = p1
				else:
					_flush(v, level, runs, si)
					runs[si] = {"p0": p0, "p1": p1, "n": n, "room": room, "cell": cell}

static func _flush(v: AV, level: int, runs: Array, si: int) -> void:
	var run: Variant = runs[si]
	runs[si] = null
	if run == null:
		return
	var a: Vector3 = run.p0
	var b: Vector3 = run.p1
	var room: int = run.room
	var n: Vector3 = run.n
	var dir := (b - a).normalized()
	var ax := 0 if absf(dir.x) > 0.5 else 2
	var lo := minf(a[ax], b[ax])
	var hi := maxf(a[ax], b[ax])
	if room >= 0:
		# In a room, from wall face to wall face: what reached past a corner was inside the crossing wall, and the
		# room's runs then depend on nothing outside it.
		var r: Dictionary = v.lv.plan.rooms[room]
		var r0 := (int(r.x) if ax == 0 else int(r.y)) * S
		var r1 := r0 + (int(r.w) if ax == 0 else int(r.h)) * S
		lo = maxf(lo, r0 + FACE)
		hi = minf(hi, r1 - FACE)
	# Cut where a hide stands against the wall (its back reaches the wall): the skirting meets its sides.
	var pieces: Array[Vector2] = [Vector2(lo, hi)]
	var line := a[2 - ax]
	for hr: Rect2 in v.hide_rects[level]:
		var h0 := hr.position.x if ax == 0 else hr.position.y
		var h1 := hr.end.x if ax == 0 else hr.end.y
		var d0 := hr.position.y if ax == 0 else hr.position.x
		var d1 := hr.end.y if ax == 0 else hr.end.x
		var face := line + n[2 - ax] * (FACE + SKIRT_T * 0.5)
		if face < d0 or face > d1:
			continue
		var kept: Array[Vector2] = []
		for p: Vector2 in pieces:
			if h1 <= p.x or h0 >= p.y:
				kept.append(p)
				continue
			if h0 > p.x:
				kept.append(Vector2(p.x, h0))
			if h1 < p.y:
				kept.append(Vector2(h1, p.y))
		pieces = kept
	for p: Vector2 in pieces:
		if p.y - p.x < 0.02:
			continue
		var p0 := a
		var p1 := a
		p0[ax] = p.x
		p1[ax] = p.y
		var xf := wall_xf(level, (p0 + p1) * 0.5, n, 0.0)
		var len := p.y - p.x
		_skirt_faces(v, level, xf, len)
		v.dressing.append({"level": level, "room": room, "cell": run.cell, "type": "skirting", "xf": xf, "len": len,
			"p0": p0, "p1": p1, "boxes": [[Vector3(len, SKIRT_H, SKIRT_T), Vector3(0, SKIRT_H * 0.5, SKIRT_T * 0.5), SKIRT]]})
		if room >= 0:
			v.records.append({"room": room, "type": "dress:skirting%.2f" % len, "xf": xf})

## The two faces of a skirting run that can be seen: its front and its top (in xf's wall frame, centred along x).
static func _skirt_faces(v: AV, level: int, xf: Transform3D, len: float) -> void:
	var st := v.lv._st(level, xf.origin.x, xf.origin.z, "aprops")
	var h := len * 0.5
	var n := xf.basis.z.normalized()
	var z := Vector2.ZERO
	AV.quad(st, xf * Vector3(-h, 0, SKIRT_T), xf * Vector3(h, 0, SKIRT_T), xf * Vector3(h, SKIRT_H, SKIRT_T), xf * Vector3(-h, SKIRT_H, SKIRT_T), z, z, z, z, n, SKIRT)
	AV.quad(st, xf * Vector3(-h, SKIRT_H, 0), xf * Vector3(h, SKIRT_H, 0), xf * Vector3(h, SKIRT_H, SKIRT_T), xf * Vector3(-h, SKIRT_H, SKIRT_T), z, z, z, z, Vector3.UP, SKIRT_TOP)

# --- wall fittings ----------------------------------------------------------------------------------

## Sockets and switches are flat plates (atlas pictures, PLATES: width, height) 1 cm off the wall face: at their size a
## box's sides could not be seen, and a picture is a tenth of the vertices.
const PLATES := {"socket": Vector2(0.15, 0.085), "switch": Vector2(0.085, 0.085)}

static func plate(v: AV, level: int, room: int, cell: Vector2i, type: String, xf: Transform3D) -> void:
	var n := xf.basis.z.normalized()
	var size: Vector2 = PLATES[type]
	var half := xf.basis.x.normalized() * (size.x * 0.5 + 0.02)
	var a := xf.origin + half + n * 0.03
	var b := xf.origin - half + n * 0.03
	var foot := Rect2(Vector2(minf(a.x, b.x), minf(a.z, b.z)), Vector2(absf(a.x - b.x), absf(a.z - b.z))).grow(0.005)
	for hr: Rect2 in v.hide_rects[level]:
		if hr.intersects(foot):
			return  # behind a hide: left out wherever that hide stands (hides are the same in same-shaped rooms)
	pic(v, level, room, cell, type, xf.origin + n * 0.01, n, size.x, size.y, AV.ATLAS[type])

## Corridor cells: on a straight one whose x + y is a multiple of four, a double socket on each solid wall at the cell's middle.
## Junctions, corners and ends keep their skirting only.
static func _corridors(v: AV) -> void:
	var lv := v.lv
	for level in 2:
		for y in v.H:
			for x in v.W:
				var c := Vector2i(x, y)
				if lv.kind(level, x, y) != "corridor" or not v._through(level, c) or (x + y) % 4 != 0:
					continue
				var cc := lv.cell_center(level, x, y)
				for d: Vector2i in AV.DIRS:
					if v.edge_kind(level, x, y, d) != "wall":
						continue
					var out := Vector3(d.x, 0, d.y)
					var line := Vector3(cc.x, 0, cc.z) + out * (S * 0.5)
					plate(v, level, -1, c, "socket", wall_xf(level, line, -out, SOCKET_Y))

## One room, in its canonical frame: sockets on every other wall slot, a switch beside each doorway, a hanging
## department sign, a cable tray, and the atrium's banner, planters and signs.
static func _room(v: AV, r: Dictionary) -> void:
	var rid := int(r.id)
	var sh: AV.Shape = v.shapes[rid]
	var level := int(r.level)
	var kind := str(r.kind)
	var rxf := AV.room_xf(r, sh.sym)
	var cwm := sh.cw * S
	var chm := sh.ch * S
	var cells: Array[Vector2] = []
	var doors: Array[Vector2] = []
	var opens: Array[Vector2] = []
	for f: Dictionary in sh.feats:
		if f.cell:
			cells.append(f.m)
		else:
			opens.append(f.m)
			if str(f.kind) == "door":
				doors.append(f.m)
	doors.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x or (a.x == b.x and a.y < b.y))
	var clocks: Array[Vector2] = []
	var lay: AV.Layout = v.layouts.get(rid)
	if lay != null:
		for p: Array in lay.pics:
			if str(p[0]) == "clock":
				clocks.append(p[1])
	# Wall slots, one per cell of wall, in the canonical order (annex_view.gd layout_for's).
	for side in 4:
		var count := sh.cw if side % 2 == 0 else sh.ch
		for i in count:
			var m: Vector2
			var n: Vector2
			match side:
				0: m = Vector2((i + 0.5) * S, 0); n = Vector2(0, -1)
				1: m = Vector2(cwm, (i + 0.5) * S); n = Vector2(1, 0)
				2: m = Vector2(cwm - (i + 0.5) * S, chm); n = Vector2(0, 1)
				_: m = Vector2(0, chm - (i + 0.5) * S); n = Vector2(-1, 0)
			if _near(opens, m, 0.01) or _near(cells, m, S * 0.5 + 0.01):
				continue
			var along := Vector2(-n.y, n.x)
			if i % 2 == 0:
				_wall_piece(v, r, rxf, rid, level, "socket", m + along * 0.55, n, SOCKET_Y, [])
			if kind == "atrium" and side > 0 and i % 2 == 1 and not _near(clocks, m, 0.01):
				_wall_piece(v, r, rxf, rid, level, "wall_planter", m, n, PLANTER_Y, planter_boxes(1.3, 0.22))
	for m: Vector2 in doors:
		var n := _outward(cwm, chm, m)
		var p := m + Vector2(-n.y, n.x) * 0.8
		if not _near(cells, p, S * 0.5 + 0.01):
			_wall_piece(v, r, rxf, rid, level, "switch", p, n, SWITCH_Y, [])
	if kind == "atrium":
		_atrium(v, r, rxf, rid, level, cwm, chm)
		return
	if DEPARTMENTS.has(kind) and not doors.is_empty():
		var m := doors[0]
		var n := _outward(cwm, chm, m)
		_hanging_sign(v, rxf, rid, level, m - n * 1.4, n, SIGN_Y, LH - 0.02, kind)
	if TRAYS.has(kind):
		_tray(v, rxf, rid, level, cwm, 0.35)

static func _near(points: Array[Vector2], p: Vector2, d: float) -> bool:
	for q: Vector2 in points:
		if absf(q.x - p.x) <= d and absf(q.y - p.y) <= d:
			return true
	return false

static func _outward(cwm: float, chm: float, m: Vector2) -> Vector2:
	if m.y < 0.01: return Vector2(0, -1)
	if m.y > chm - 0.01: return Vector2(0, 1)
	if m.x < 0.01: return Vector2(-1, 0)
	return Vector2(1, 0)

## A piece on a room's wall at canonical point `m` (on the wall line, outward normal `n`), `y` over the floor: its boxes,
## or a plate when it has none.
static func _wall_piece(v: AV, r: Dictionary, rxf: Transform3D, rid: int, level: int, type: String, m: Vector2, n: Vector2, y: float, boxes: Array) -> void:
	var world := rxf * Vector3(m.x, 0, m.y)
	var into := (rxf.basis * Vector3(-n.x, 0, -n.y)).normalized()
	var xf := wall_xf(level, Vector3(world.x, 0, world.z), into, y)
	if boxes.is_empty():
		plate(v, level, rid, _cell_of(world), type, xf)
	else:
		put(v, level, rid, _cell_of(world), type, xf, boxes, Vector3.FORWARD)

static func _cell_of(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / S), floori(p.z / S))

## A trough on brackets hung on a wall, its bottom at the frame's origin: concrete, a mound of leaves, trailing ends.
static func planter_boxes(w: float, d: float) -> Array:
	var out: Array = [AV._b(w, 0.18, d, 0, 0.02, d * 0.5, CONCRETE), AV._b(w - 0.08, 0.16, d - 0.05, 0, 0.18, d * 0.5, AV.LEAF),
		AV._b(w * 0.55, 0.1, d * 0.6, -w * 0.12, 0.3, d * 0.5, AV.LEAF2)]
	for k in 4:
		var x := -w * 0.4 + k * w * 0.27
		out.append(AV._b(0.12, 0.2 - 0.04 * (k % 2), 0.04, x, 0.0, d + 0.01, AV.LEAF if k % 2 == 0 else AV.LEAF2))
	for x: float in [-w * 0.35, w * 0.35]:
		out.append(AV._b(0.03, 0.12, d, x, 0.0, d * 0.5, AV.METAL_DARK))
	return out

## A two-sided board hung on rods from the ceiling at `top`: at canonical point `p`, facing `n` (and its back).
static func _hanging_sign(v: AV, rxf: Transform3D, rid: int, level: int, p: Vector2, n: Vector2, y: float, top: float, kind: String) -> void:
	var at := rxf * Vector3(p.x, y, p.y)
	var face := (rxf.basis * Vector3(n.x, 0, n.y)).normalized()
	var xf := Transform3D(Basis(Vector3(face.z, 0, -face.x), Vector3.UP, face), at)
	var rod := top - y - 0.13
	var boxes: Array = [AV._b(0.94, 0.26, 0.03, 0, -0.13, 0, SLATE)]
	for side: float in [-0.36, 0.36]:
		boxes.append(AV._b(0.015, rod, 0.015, side, 0.13, 0, ROD))
	put(v, level, rid, _cell_of(at), "hanging_sign", xf, boxes)
	var rect: Rect2i = AV.ATLAS["dept_" + kind]
	for s: float in [1.0, -1.0]:
		pic(v, level, rid, _cell_of(at), "hanging_sign_face", at + face * (0.016 * s), face * s, 0.88, 0.22, rect)

## A cable tray across the room along its canonical x, `z` in from its first wall, hung on rods.
static func _tray(v: AV, rxf: Transform3D, rid: int, level: int, cwm: float, z: float) -> void:
	var len := cwm - 2.0 * FACE
	var c := Vector3(cwm * 0.5, TRAY_Y, z)
	var boxes: Array = [AV._b(len, 0.012, 0.3, 0, 0, 0, TRAY), AV._b(len, 0.06, 0.012, 0, 0, -0.144, TRAY),
		AV._b(len, 0.06, 0.012, 0, 0, 0.144, TRAY), AV._b(len, 0.035, 0.2, 0, 0.012, 0.02, CABLE)]
	for u: float in AV.spread(len, 1.8):
		boxes.append(AV._b(0.012, LH - 0.02 - TRAY_Y, 0.012, u - len * 0.5, 0.0, 0, ROD))
	var xf := rxf * Transform3D(Basis.IDENTITY, c)
	put(v, level, rid, _cell_of(xf.origin), "cable_tray", xf, boxes)

## The atrium, in its canonical frame: the company's banner high on its first wall (above the clock's height) on a
## rod, and two hanging signs at the balcony's height.
static func _atrium(v: AV, r: Dictionary, rxf: Transform3D, rid: int, level: int, cwm: float, chm: float) -> void:
	var w := minf(cwm - 1.6, 6.4)
	var at := rxf * Vector3(cwm * 0.5, 2.84, FACE + 0.012)
	var into := (rxf.basis * Vector3(0, 0, 1)).normalized()
	pic(v, level, rid, _cell_of(at), "banner", at, into, w, w / 16.0, AV.ATLAS["banner"])
	var rod_xf := Transform3D(Basis(Vector3(into.z, 0, -into.x), Vector3.UP, into), at)
	put(v, level, rid, _cell_of(at), "banner_rod", rod_xf, [AV._b(w + 0.16, 0.025, 0.012, 0, w / 32.0 + 0.005, -0.006, AV.METAL_DARK)])
	for u: float in [0.3, 0.7]:
		_hanging_sign(v, rxf, rid, level, Vector2(cwm * u, chm * 0.5), Vector2(0, -1), LH + 0.6, 2.0 * LH - 0.02, "atrium")

## Planters hung on the void side of every balcony rail over an atrium (level 1, a corridor on the other side): the
## dressing of that corridor cell, the same at every rail.
static func _balconies(v: AV) -> void:
	var lv := v.lv
	for y in v.H:
		for x in v.W:
			if lv.kind(1, x, y) != "corridor":
				continue
			var cc := lv.cell_center(1, x, y)
			for d: Vector2i in AV.DIRS:
				if lv.kind(1, x + d.x, y + d.y) != "atriumOpen" or v.edge_kind(1, x, y, d) != "rail":
					continue
				var out := Vector3(d.x, 0, d.y)
				var line := Vector3(cc.x, 0, cc.z) + out * (S * 0.5)
				put(v, 1, -1, Vector2i(x, y), "rail_planter", wall_xf(1, line, out, 0.5), planter_boxes(1.6, 0.2), Vector3.FORWARD)

# --- on top of the furniture ------------------------------------------------------------------------

## What stands on top of a piece of the rules' furniture, in the piece's own drawn frame (annex_view.gd piece_boxes,
## front towards -z): by its kind ("hide:desk" for a hide), the same on every piece of the kind.
static func tops(kind: String) -> Array:
	if _tops.is_empty():
		_tops = _make_tops()
	return _tops.get(kind, [])

static func _phone(x: float, y: float, z: float) -> Array:
	return [AV._b(0.2, 0.06, 0.17, x, y, z, AV.BEIGE_DARK), AV._b(0.22, 0.045, 0.06, x, y + 0.06, z - 0.045, AV.BEIGE),
		AV._b(0.1, 0.006, 0.06, x, y + 0.06, z + 0.04, AV.GREY_DARK)]

static func _mug(x: float, y: float, z: float, col: Color) -> Array:
	return [AV._b(0.08, 0.1, 0.08, x, y, z, col), AV._b(0.02, 0.05, 0.03, x + 0.05, y + 0.025, z, col)]

static func _make_tops() -> Dictionary:
	var t := {}
	var desk: Array = []
	desk.append_array(_phone(-0.12, 0.76, 0.2))
	desk.append_array([AV._b(0.26, 0.045, 0.3, -0.62, 0.76, 0.25, AV.GREY_MID), AV._b(0.21, 0.03, 0.25, -0.62, 0.775, 0.25, AV.PAPER),
		AV._b(0.24, 0.08, 0.012, -0.62, 0.805, 0.394, AV.GREY_MID), AV._b(0.26, 0.012, 0.3, -0.62, 0.885, 0.25, AV.GREY_MID)])
	desk.append_array(_mug(0.66, 0.76, -0.24, MUG2))
	desk.append_array([AV._b(0.14, 0.03, 0.14, -0.3, 0.76, 0.31, AV.GREY_DARK), AV._b(0.025, 0.4, 0.025, -0.3, 0.79, 0.31, AV.GREY_DARK),
		AV._b(0.025, 0.025, 0.22, -0.3, 1.165, 0.2, AV.GREY_DARK), AV._b(0.16, 0.1, 0.14, -0.3, 1.07, 0.1, SHADE)])
	t["hide:desk"] = desk
	t["hide:cabinet"] = [AV._b(0.38, 0.26, 0.32, -0.2, 2.0, 0.05, AV.CARD), AV._b(0.38, 0.22, 0.32, 0.21, 2.0, 0.04, AV.CARD_DARK)]
	var table: Array = []
	for x: float in [-1.5, -0.5, 0.5, 1.5]:
		for z: float in [-0.42, 0.42]:
			table.append(AV._b(0.21, 0.01, 0.28, x, 0.76, z, AV.PAPER))
	table.append(AV._b(0.12, 0.24, 0.12, 0.0, 0.76, 0.0, AV.WHITE))
	for x: float in [-0.18, 0.18]:
		table.append(AV._b(0.06, 0.1, 0.06, x, 0.76, 0.04, GLASS))
	t["hide:table"] = table
	var filing: Array = [AV._b(0.28, 0.045, 0.34, -0.07, 1.32, 0.04, AV.GREY_MID), AV._b(0.22, 0.03, 0.28, -0.07, 1.335, 0.04, AV.PAPER)]
	filing.append_array(_mug(0.13, 1.32, -0.18, MUG))
	t["filing"] = filing
	var low: Array = _phone(0.22, 0.72, 0.02)
	low.append_array([AV._b(0.32, 0.06, 0.25, -0.2, 0.72, 0.0, AV.FABRIC), AV._b(0.3, 0.05, 0.24, -0.2, 0.78, 0.0, AV.CARD)])
	t["cabinet_low"] = low
	t["copier"] = [AV._b(0.3, 0.1, 0.21, -0.25, 0.92, 0.1, REAM), AV._b(0.3, 0.1, 0.21, -0.25, 1.02, 0.1, REAM2)]
	var counter: Array = []
	counter.append_array(_mug(-0.02, 0.9, -0.12, MUG))
	counter.append_array(_mug(0.13, 0.9, -0.14, MUG3))
	counter.append(AV._b(0.12, 0.16, 0.12, 0.72, 0.9, 0.12, TIN))
	t["counter"] = counter
	t["fridge"] = [AV._b(0.42, 0.22, 0.34, 0.0, 1.75, 0.05, AV.CARD)]
	var brk: Array = [AV._b(0.34, 0.012, 0.26, 0.0, 0.74, 0.05, NEWS)]
	brk.append_array(_mug(-0.34, 0.74, -0.08, MUG2))
	brk.append_array(_mug(0.3, 0.74, -0.1, MUG))
	t["break_table"] = brk
	return t

## Draws the tops of one piece (its record type in `records`: "hide:desk", "filing", ...) in its drawn frame `dxf`.
static func draw_tops(v: AV, room: int, level: int, type: String, dxf: Transform3D) -> void:
	var boxes := tops(type)
	if boxes.is_empty():
		return
	var at := dxf.origin
	var cell := _cell_of(at)
	var st := v.lv._st(level, at.x, at.z, "aprops")
	for i in boxes.size():
		var b: Array = boxes[i]
		AV.box(st, dxf, b[0], b[1], b[2], Vector3.DOWN)
		var bxf := dxf * Transform3D(Basis.IDENTITY, b[1])
		if room >= 0:
			v.records.append({"room": room, "type": "top:%s:%d" % [type, i], "xf": bxf})
	v.dressing.append({"level": level, "room": room, "cell": cell, "type": "top:" + type, "xf": dxf, "boxes": boxes})
