extends RefCounted
## LA3: the Clinic's wall, ceiling and furniture-top dressing (client/clinic_dress.gd), looks only. Nothing it adds hides
## what the plan's own sight check says a player sees, at standing or creeping eye height or from inside a hide; nothing
## stands in the walkable space below 2.2 m but within 15 cm of a wall or on top of the rules' furniture; nothing
## touches a hide, a findable, a doorway or the floor marks go on; nothing is a light; the same floor seed gives the same
## dressing; and far from the lift the pieces are worn where near it they are clean and straight.

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Clinic = preload("res://sim/clinic.gd")
const Floor = preload("res://sim/floor.gd")
const Sight = preload("res://sim/sight.gd")
const Move = preload("res://sim/move.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const Dress = preload("res://client/clinic_dress.gd")
const EyeHeight = preload("res://client/eye_height.gd")
const ANNEX_VIEW = preload("res://client/annex_view.gd")
const PixelFont = preload("res://client/pixel_font.gd")

const S := 2.0
const LH := 3.2
## A body's radius (net/session.gd PLAYER_RADIUS): no spot closer to a wall line.
const BODY := 0.3
## The heights of a figure's points the rules look at, over its feet (sim/sight.gd FIGURE_LEVELS).
const FIGURE: Array[float] = [0.05, 0.52, 1.1, 1.7, 2.6]
## The quick run's points of a figure: its feet, its waist, the top of its head.
const FIGURE_QUICK: Array[float] = [0.05, 1.1, 2.6]
## Beyond a piece, the distances along a line where its far end is tried (m).
const BEYOND_QUICK: Array[float] = [0.15, 0.8, 3.0, 12.0]
const BEYOND: Array[float] = [0.15, 0.4, 0.8, 1.5, 3.0, 6.0, 12.0, 24.0]

static func _built(fp: Floor.FloorPlan) -> Level:
	var level := Level.new()
	level.build(PlanDump.dump(fp, Run.car_geometry(fp)), fp.seed, fp)
	return level

## The floors checked: [name, plan, level]. Floors 1 and 2 are the Clinic's.
static func _floors(quick: bool) -> Array:
	var out: Array = []
	for i in (1 if quick else 3):
		for depth: int in [1, 2]:
			var fp := Clinic.generate_clinic("la3-%d" % i, depth)
			out.append(["the Clinic la3-%d/%d" % [i, depth], fp, _built(fp)])
	return out

static func _free(floors: Array) -> void:
	for f: Array in floors:
		(f[2] as Node).free()

static func records(lv: Level) -> Array:
	return lv.get_meta(&"dressing", [])

## Every placement as one box: {piece, kinds, level, aabb, high, on, wall (n), face}.
static func pieces(lv: Level) -> Array[Dictionary]:
	var by := {}
	var order: Array[int] = []
	for r: Dictionary in records(lv):
		var id := int(r.piece)
		if not by.has(id):
			by[id] = {"piece": id, "kinds": {}, "level": int(r.level), "aabb": r.aabb, "high": bool(r.high), "on": int(r.on), "n": r.n, "face": r.face, "cell": r.cell}
			order.append(id)
		var p: Dictionary = by[id]
		p.aabb = (p.aabb as AABB).merge(r.aabb)
		(p.kinds as Dictionary)[r.kind] = true
	var out: Array[Dictionary] = []
	for id in order:
		out.append(by[id])
	return out

# --- where a body can be -------------------------------------------------------------------------

## The edge on side v of cell (x, y) (the drawn plan's copy of the rules' walls).
static func edge(lv: Level, level: int, x: int, y: int, v: Vector2i) -> String:
	if x < 0 or y < 0 or x >= lv.W or y >= lv.H:
		return "wall"
	var vert: Array = lv.edges[level].vertical
	var hor: Array = lv.edges[level].horizontal
	if v == Vector2i(0, -1): return hor[y * lv.W + x]
	if v == Vector2i(0, 1): return hor[(y + 1) * lv.W + x]
	if v == Vector2i(-1, 0): return vert[y * (lv.W + 1) + x]
	return vert[y * (lv.W + 1) + x + 1]

const SIDES: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]

## Whether a body (radius BODY) can stand with its feet at (x, z) on `level`: a walkable cell, clear of the solid walls
## (a doorway's wall either side of the opening included) and of the rules' furniture.
static func body_ok(lv: Level, foot: Array, level: int, x: float, z: float) -> bool:
	var cx := floori(x / S)
	var cy := floori(z / S)
	var k := lv.kind(level, cx, cy)
	if k != "room" and k != "corridor" and k != "landing":
		return false
	var lx := x - cx * S
	var lz := z - cy * S
	for v in SIDES:
		var d := (lz if v.y < 0 else S - lz) if v.y != 0 else (lx if v.x < 0 else S - lx)
		if d >= BODY:
			continue
		var e := edge(lv, level, cx, cy, v)
		if e == "none" or e == "open":
			continue
		if e == "door":
			var along := (lx - 1.0) if v.y != 0 else (lz - 1.0)
			var half := Level.DOOR_W * 0.5
			if absf(along) < half and Vector2(absf(along) - half, d).length() >= BODY:
				continue
			if absf(along) < half - BODY:
				continue
		return false
	# The far corners of the cell: a wall end of a neighbour.
	for f: Rect2 in (foot[level] as Dictionary).get(Vector2i(cx, cy), []):
		if f.has_point(Vector2(x, z)):
			return false
	return true

## A spread of spots where a body can stand: each walkable cell's middle, a spot 31 cm off each solid side, the
## corners between two solid sides, three spots in each doorway's opening and three along each open side.
static func spots(lv: Level, foot: Array) -> Array:
	var out: Array = [[], []]
	var o := BODY + 0.01
	for level in 2:
		var seen := {}
		for y in lv.H:
			for x in lv.W:
				var k := lv.kind(level, x, y)
				if k != "room" and k != "corridor" and k != "landing":
					continue
				var c := Vector2((x + 0.5) * S, (y + 0.5) * S)
				var cand: Array[Vector2] = [c]
				for v in SIDES:
					var vv := Vector2(v)
					var side := Vector2(-vv.y, vv.x)
					var e := edge(lv, level, x, y, v)
					if e == "door":
						for a: float in [-0.25, 0.0, 0.25]:
							cand.append(c + vv * S * 0.5 + side * a)
					elif e == "none" or e == "open":
						for a: float in [-(S * 0.5 - o), 0.0, S * 0.5 - o]:
							cand.append(c + vv * (S * 0.5) + side * a)
					else:
						cand.append(c + vv * (S * 0.5 - o))
						cand.append(c + vv * (S * 0.5 - o) + side * (S * 0.5 - o))
				for p in cand:
					var key := Vector2i(roundi(p.x * 100.0), roundi(p.y * 100.0))
					if not seen.has(key) and body_ok(lv, foot, level, p.x, p.y):
						seen[key] = true
						(out[level] as Array).append(p)
	return out

## Per level, by cell: the rules' furniture's footprints as drawn, grown by a body's radius (where no body's feet go).
static func furniture_feet(lv: Level) -> Array:
	var foot: Array = [{}, {}]
	var level_of := {}
	for pc in lv.pieces:
		level_of[pc.id] = pc.level
	for d: Dictionary in lv.furniture_drawn:
		var g := (d.rect as Rect2).grow(BODY)
		var grid: Dictionary = foot[int(level_of.get(d.piece, 0))]
		for cy in range(floori(g.position.y / S), floori(g.end.y / S) + 1):
			for cx in range(floori(g.position.x / S), floori(g.end.x / S) + 1):
				if not grid.has(Vector2i(cx, cy)):
					grid[Vector2i(cx, cy)] = []
				(grid[Vector2i(cx, cy)] as Array).append(g)
	return foot

## The drawn walls as boxes (the rules' walls are lines; the drawing gives them Level.WALL_T): a line the drawing
## already hides is not one a piece can newly hide.
static func wall_boxes(lv: Level) -> Array[AABB]:
	var out: Array[AABB] = []
	var h := Level.WALL_T * 0.5
	var lift := lv._lift_edge()
	for level in 2:
		var vert: Array = lv.edges[level].vertical
		var hor: Array = lv.edges[level].horizontal
		for y in lv.H:
			for x in lv.W + 1:
				var is_lift := level == lv.landing.x and lift == Vector4i(0, x, y, 1)
				for part: Array in lv._edge_parts(level, vert[y * (lv.W + 1) + x], is_lift):
					for r: Array in part[0]:
						out.append(AABB(Vector3(x * S - h, level * LH + float(part[1]), y * S + float(r[0])), Vector3(2 * h, float(part[2]) - float(part[1]), float(r[1]) - float(r[0]))))
		for y in lv.H + 1:
			for x in lv.W:
				var is_lift := level == lv.landing.x and lift == Vector4i(1, x, y, 1)
				for part: Array in lv._edge_parts(level, hor[y * lv.W + x], is_lift):
					for r: Array in part[0]:
						out.append(AABB(Vector3(x * S + float(r[0]), level * LH + float(part[1]), y * S - h), Vector3(float(r[1]) - float(r[0]), float(part[2]) - float(part[1]), 2 * h)))
	return out

## Whether the segment a-b passes through the box (its ends excluded by a hair).
static func seg_hits(a: Vector3, b: Vector3, box: AABB) -> bool:
	var d := b - a
	var t0 := 0.001
	var t1 := 0.999
	for i in 3:
		if absf(d[i]) < 1e-9:
			if a[i] <= box.position[i] or a[i] >= box.end[i]:
				return false
		else:
			var ta := (box.position[i] - a[i]) / d[i]
			var tb := (box.end[i] - a[i]) / d[i]
			t0 = maxf(t0, minf(ta, tb))
			t1 = minf(t1, maxf(ta, tb))
			if t0 >= t1:
				return false
	return true

static func _pt(p: Vector3) -> Sight.Point3:
	return Sight.Point3.make(p.x, p.y, p.z, 1 if p.y >= LH else 0)

static func _level_of(y: float) -> int:
	return 1 if y >= LH - 0.001 else 0

# --- sight ---------------------------------------------------------------------------------------

## For one floor: every line from a spot near a piece (as an eye, standing or creeping, or as a point of a figure) through
## a point of the piece to a spot beyond it, that the plan's sight check lets through and the drawn walls do not already
## stop. Returns the faults (a piece of the dressing in the way) and how many lines were tried.
static func sight_faults(lv: Level, fp: Floor.FloorPlan, quick: bool) -> Dictionary:
	var foot := furniture_feet(lv)
	var sp := spots(lv, foot)
	var walls := wall_boxes(lv)
	var faults := PackedStringArray()
	var tried := 0
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(fp.seed + ":%d" % fp.depth)
	var eyes: Array[float] = [EyeHeight.STAND, EyeHeight.CREEP]
	var reach := 14.0
	for p: Dictionary in pieces(lv):
		var box: AABB = p.aabb
		var level := int(p.level)
		var floor_y := level * LH
		var n: Vector3 = p.n
		var mid := box.get_center()
		# The lines that can meet a piece on a wall start (or end) within its reach of the wall line, or behind it; any
		# piece may meet a line between the storeys.
		var near: Array = []
		if n != Vector3.ZERO and box.position.y - floor_y < 2.6:
			var face: Vector3 = p.face
			var deep := 0.0
			for k in 8:
				deep = maxf(deep, (_corner(box, k) - face).dot(n))
			# In front within reach of the wall line; behind it (a line through a doorway or round a corner) only near the
			# line or near the piece: a line from further behind crosses the wall line too steeply to come near the piece
			# unless the gap it crosses is right beside it.
			var front: Array = []
			var behind: Array = []
			for q: Vector2 in sp[level]:
				var dist := Vector2(q.x - mid.x, q.y - mid.z).length()
				var d := (Vector3(q.x, face.y, q.y) - face).dot(n)
				if dist >= reach:
					continue
				if d >= 0.0 and d < deep + 0.1:
					front.append(Vector3(q.x, floor_y, q.y))
				elif d < 0.0 and (d > -4.0 or dist < 3.0):
					behind.append(Vector3(q.x, floor_y, q.y))
			var cap_b := 12 if quick else 90
			while behind.size() > cap_b:
				behind.remove_at(rng.randi_range(0, behind.size() - 1))
			near.append_array(front)
			near.append_array(behind)
		var other: Array = []
		if _hole_within(lv, Vector2i(floori(mid.x / S), floori(mid.z / S)), 10):
			for q: Vector2 in sp[1 - level]:
				if Vector2(q.x - mid.x, q.y - mid.z).length() < reach * 1.5:
					other.append(Vector3(q.x, (1 - level) * LH, q.y))
		var cap := 5 if quick else 30
		while other.size() > cap:
			other.remove_at(rng.randi_range(0, other.size() - 1))
		near.append_array(other)
		var qs: Array[Vector3] = [mid]
		for k: int in ([0, 6] if quick else [0, 3, 5, 6]):
			qs.append(mid.lerp(_corner(box, k), 0.7))
		for x_feet: Vector3 in near:
			for role in 2:
				# role 0: x is an eye and the far end a point of a figure; role 1 the other way round.
				var hs: Array[float] = eyes if role == 0 else (FIGURE_QUICK if quick else FIGURE)
				for hx: float in hs:
					var xp := x_feet + Vector3(0, hx, 0)
					for qp in qs:
						var dir := qp - xp
						if dir.length() < 0.05:
							continue
						dir = dir.normalized()
						var ends: Array[Vector3] = []
						if role == 0:
							# A point of a figure: anywhere on the line beyond, from its feet to the top of its head.
							for s: float in (BEYOND_QUICK if quick else BEYOND):
								var e0 := qp + dir * s
								var h0 := e0.y - _level_of(e0.y) * LH
								if h0 >= 0.05 and h0 <= 2.6:
									ends.append(e0)
						elif absf(dir.y) > 1e-6:
							# An eye: where the line beyond is at a standing or a creeping eye's height over a floor.
							for he: float in eyes:
								for lvl in 2:
									var tt := (lvl * LH + he - qp.y) / dir.y
									if tt > 0.0 and tt < 40.0:
										ends.append(qp + dir * tt)
						for yp in ends:
							var yl := _level_of(yp.y)
							if not body_ok(lv, foot, yl, yp.x, yp.z):
								continue
							tried += 1
							var eye := xp if role == 0 else yp
							var fig := yp if role == 0 else xp
							if not Sight.has_line_of_sight(fp, _pt(eye), _pt(fig)):
								continue
							var hidden := false
							for w in walls:
								if seg_hits(eye, fig, w):
									hidden = true
									break
							if not hidden:
								faults.append("%s (piece %d, %s) cuts %s -> %s" % [",".join(PackedStringArray((p.kinds as Dictionary).keys())), int(p.piece), box, eye, fig])
	# And the views out of the hides: from each hide's eye (sim/hides.gd) to the spots in its room.
	var all_pieces := pieces(lv)
	for h in lv.hides:
		var e := Vector3(h.inside.x / 100.0, h.level * LH + h.eye / 100.0, h.inside.y / 100.0)
		var close: Array[Dictionary] = []
		for p: Dictionary in all_pieces:
			if int(p.level) == h.level and (p.aabb as AABB).grow(9.0).has_point(e):
				close.append(p)
		for q: Vector2 in sp[h.level]:
			if Vector2(q.x - e.x, q.y - e.z).length() > 8.0:
				continue
			for hf: float in FIGURE:
				var fig := Vector3(q.x, h.level * LH + hf, q.y)
				var cut := ""
				for p: Dictionary in close:
					if seg_hits(e, fig, p.aabb):
						cut = str((p.kinds as Dictionary).keys())
						break
				if cut == "":
					continue
				tried += 1
				if Sight.has_line_of_sight(fp, _pt(e), _pt(fig)):
					faults.append("%s cuts the view out of hide %d: %s -> %s" % [cut, h.id, e, fig])
	return {"faults": faults, "tried": tried}

## Whether an opening in the upper storey's floor (the atrium's, a stair's) is within `reach` cells of c.
static func _hole_within(lv: Level, c: Vector2i, reach: int) -> bool:
	for y in range(c.y - reach, c.y + reach + 1):
		for x in range(c.x - reach, c.x + reach + 1):
			var k := lv.kind(1, x, y)
			if k == "atriumOpen" or k == "stair":
				return true
	return false

static func _corner(b: AABB, k: int) -> Vector3:
	return b.position + Vector3(b.size.x * float(k & 1), b.size.y * float((k >> 1) & 1), b.size.z * float((k >> 2) & 1))

func test_nothing_added_hides_what_the_plan_sees(t: T) -> void:
	var floors := _floors(t.quick)
	for f: Array in floors:
		var lv: Level = f[2]
		var t0 := Time.get_ticks_msec()
		if t.quick and f != floors[0]:
			continue
		var r := sight_faults(lv, f[1], t.quick)
		var faults: PackedStringArray = r.faults
		t.check(int(r.tried) > 1000, "%s: lines tried past the dressing (%d)" % [f[0], int(r.tried)])
		t.check(faults.is_empty(), "%s: %d lines the plan sees are cut by the dressing: %s" % [f[0], faults.size(), "; ".join(faults.slice(0, 4))])
		t.note("%s: %d pieces, %d lines tried, %d ms" % [f[0], pieces(lv).size(), int(r.tried), Time.get_ticks_msec() - t0])
	_free(floors)

## A random spread of pairs of spots (standing and creeping eyes, every point of a figure) the plan's sight check lets
## see each other: no piece of the dressing between them.
func test_a_spread_of_lines_the_plan_sees_is_never_cut(t: T) -> void:
	var floors := _floors(t.quick)
	for f: Array in floors:
		var lv: Level = f[2]
		var fp: Floor.FloorPlan = f[1]
		var foot := furniture_feet(lv)
		var sp := spots(lv, foot)
		var all: Array[Vector3] = []
		for level in 2:
			for q: Vector2 in sp[level]:
				all.append(Vector3(q.x, level * LH, q.y))
		var ps := pieces(lv)
		var rng := RandomNumberGenerator.new()
		rng.seed = hash("spread:" + fp.seed)
		var seen := 0
		var cut := PackedStringArray()
		for i in (6000 if t.quick else 20000):
			var a := all[rng.randi_range(0, all.size() - 1)]
			var b := all[rng.randi_range(0, all.size() - 1)]
			if a.distance_to(b) > 30.0:
				continue
			var eye := a + Vector3(0, EyeHeight.STAND if i % 2 == 0 else EyeHeight.CREEP, 0)
			var fig := b + Vector3(0, FIGURE[i % FIGURE.size()], 0)
			if not Sight.has_line_of_sight(fp, _pt(eye), _pt(fig)):
				continue
			seen += 1
			for p: Dictionary in ps:
				if seg_hits(eye, fig, p.aabb):
					cut.append("%s %s -> %s" % [(p.kinds as Dictionary).keys(), eye, fig])
		t.check(seen > 300, "%s: lines the plan sees (%d)" % [f[0], seen])
		t.check(cut.is_empty(), "%s: %d of them cut by the dressing: %s" % [f[0], cut.size(), "; ".join(cut.slice(0, 4))])
	_free(floors)

# --- where the pieces are ------------------------------------------------------------------------

## The kind of the wall edge just behind a point on a wall face with normal n (into the room).
static func _edge_behind(lv: Level, level: int, p: Vector3, n: Vector3) -> String:
	var c := p + n * 0.3
	var v := Vector2i(roundi(-n.x), roundi(-n.z))
	return edge(lv, level, floori(c.x / S), floori(c.z / S), v)

## Below 2.2 m nothing stands out from a wall by more than 15 cm or off the top of the rules' furniture; what is hung
## from the ceiling, and every "high" piece, is above every point the rules look at; every wall piece has its wall
## behind it (a call lamp the wall over a doorway); nothing lies low enough to meet the marks laid on the floor.
func test_nothing_stands_in_the_walkable_space(t: T) -> void:
	var floors := _floors(t.quick)
	for f: Array in floors:
		var lv: Level = f[2]
		var tops := {}
		for d: Dictionary in lv.furniture_drawn:
			tops[d.piece] = d
		var bad := PackedStringArray()
		var on_top := 0
		for r: Dictionary in records(lv):
			var box: AABB = r.aabb
			var level := int(r.level)
			var lo := box.position.y - level * LH
			var n: Vector3 = r.n
			if bool(r.high) or n == Vector3.ZERO:
				if lo < Dress.HIGH_Y - 0.001:
					bad.append("%s hung at %.3f m" % [r.kind, lo])
				continue
			if int(r.on) >= 0:
				on_top += 1
				var d: Dictionary = tops.get(int(r.on), {})
				var rect: Rect2 = d.get("rect", Rect2())
				if not rect.grow(0.01).encloses(Rect2(box.position.x, box.position.z, box.size.x, box.size.z)) or lo < float(d.get("top", 0.0)) - 0.01:
					bad.append("%s not on top of piece %d" % [r.kind, int(r.on)])
			if lo < 0.3:
				bad.append("%s reaches the floor (%.3f m)" % [r.kind, lo])
			var face: Vector3 = r.face
			var deep := -INF
			var shallow := INF
			for k in 8:
				var q := (_corner(box, k) - face).dot(n)
				deep = maxf(deep, q)
				shallow = minf(shallow, q)
			if lo < 2.2 and deep > Dress.PROUD_MAX + 0.001:
				bad.append("%s stands %.3f m off its wall" % [r.kind, deep])
			if shallow < -0.002:
				bad.append("%s goes into its wall (%.3f m)" % [r.kind, shallow])
			var along := Vector3(absf(n.z), 0, absf(n.x))
			var c := box.get_center()
			for s: float in [-0.5, 0.0, 0.5]:
				var p := c + along * (box.size.dot(along) - 0.02) * s
				p = p - n * (p - face).dot(n)
				var e := _edge_behind(lv, level, p, n)
				if not (e == "wall" or (e == "door" and lo > Level.DOOR_H + 0.1)):
					bad.append("%s at %s has no wall behind it (%s)" % [r.kind, p, e])
					break
		t.check(on_top > 0, "%s: things on the furniture (%d boxes)" % [f[0], on_top])
		t.check(bad.is_empty(), "%s: %d pieces out of place: %s" % [f[0], bad.size(), "; ".join(bad.slice(0, 5))])
	_free(floors)

## Nothing touches a hide's body or the floor in front of its open side, a findable's body or the floor in front of
## it, a doorway's opening, or the cells by the landing (the call button).
func test_nothing_crowds_a_hide_a_findable_or_a_doorway(t: T) -> void:
	var floors := _floors(t.quick)
	for f: Array in floors:
		var r := crowd_faults(f[2] as Level)
		var bad: PackedStringArray = r.bad
		t.check(int(r.tested) > 1000, "%s: pieces against hides, findables and doorways (%d)" % [f[0], int(r.tested)])
		t.check(bad.is_empty(), "%s: %d: %s" % [f[0], bad.size(), "; ".join(bad.slice(0, 5))])
	_free(floors)

## The pieces of one floor that touch a hide's or a findable's body or the floor in front of it, a doorway's opening,
## or a cell by the landing: {bad, tested}.
static func crowd_faults(lv: Level) -> Dictionary:
	var keep: Array = [[], []]
	var named: Array = [[], []]
	var by_id := {}
	for pc in lv.pieces:
		by_id[pc.id] = pc
	for d: Dictionary in lv.furniture_drawn:
		var pc: Variant = by_id.get(d.piece)
		if pc == null or (int(pc.hide) < 0 and not bool(pc.searchable)):
			continue
		var level := int(pc.level)
		var rect: Rect2 = d.rect
		var top := float(d.get("top", 2.0))
		var base := level * LH
		(keep[level] as Array).append(AABB(Vector3(rect.position.x, base, rect.position.y), Vector3(rect.size.x, top - 0.005, rect.size.y)))
		(named[level] as Array).append("%s %d" % [pc.kind, pc.id])
		# The floor in front: a hide's open side out past its front spot, a findable's front out 70 cm, to 2.2 m.
		var fr: Rect2
		if int(pc.hide) >= 0:
			var h: Variant = lv.hides[int(pc.hide)]
			var xf := ANNEX_VIEW.hide_xf(h)
			var hh := ANNEX_VIEW.hide_half(h.kind)
			var zf := (xf.affine_inverse() * Vector3(h.front.x / 100.0, base, h.front.y / 100.0)).z - BODY
			var a := xf * Vector3(-hh.x, 0, zf)
			var b := xf * Vector3(hh.x, 0, -hh.y)
			fr = Rect2(Vector2(minf(a.x, b.x), minf(a.z, b.z)), Vector2(absf(b.x - a.x), absf(b.z - a.z)))
		else:
			var fv := Vector2i(Floor.dir_dx(pc.facing), Floor.dir_dy(pc.facing))
			if fv.x > 0: fr = Rect2(rect.end.x, rect.position.y, 0.7, rect.size.y)
			elif fv.x < 0: fr = Rect2(rect.position.x - 0.7, rect.position.y, 0.7, rect.size.y)
			elif fv.y > 0: fr = Rect2(rect.position.x, rect.end.y, rect.size.x, 0.7)
			else: fr = Rect2(rect.position.x, rect.position.y - 0.7, rect.size.x, 0.7)
		(keep[level] as Array).append(AABB(Vector3(fr.position.x, base, fr.position.y), Vector3(fr.size.x, 2.2, fr.size.y)))
		(named[level] as Array).append("the front of %s %d" % [pc.kind, pc.id])
	for d: Dictionary in lv.plan.doors:
		var level := int(d.level)
		var a := lv.cell_center(level, int(d.ax), int(d.ay))
		var b := lv.cell_center(level, int(d.bx), int(d.by))
		var m := (a + b) * 0.5
		var across := Vector3(absf(b.z - a.z), 0, absf(b.x - a.x)).normalized()
		var thru := (b - a).normalized().abs()
		var lo := m - across * (Level.DOOR_W * 0.5) - thru * 0.5
		(keep[level] as Array).append(AABB(lo, across * Level.DOOR_W + thru * 1.0 + Vector3(0, Level.DOOR_H, 0)))
		(named[level] as Array).append("a doorway at %s" % m)
	var bad := PackedStringArray()
	var tested := 0
	for r: Dictionary in records(lv):
		var level := int(r.level)
		var box: AABB = r.aabb
		var c: Vector2i = r.cell
		var dl := lv.dist[lv.pidx(level, c.x, c.y)]
		if dl >= 0 and dl <= Dress.LIFT_CLEAR:
			bad.append("%s by the landing" % r.kind)
		for i in (keep[level] as Array).size():
			tested += 1
			if box.intersects(keep[level][i]):
				bad.append("%s meets %s" % [r.kind, named[level][i]])
	return {"bad": bad, "tested": tested}

# --- nothing else ---------------------------------------------------------------------------------

## The dressing adds no light and changes nothing else on the floor: built without it, every other mesh and light is
## the same. Its own meshes are few, one material, casting no shadow and not glowing, with nothing under them.
func test_the_dressing_adds_no_light_and_changes_nothing_else(t: T) -> void:
	for sd: String in ["la3-0", "alpha"]:
		var fp := Clinic.generate_clinic(sd, 1)
		var on := _built(fp)
		Dress.off = true
		var bare := _built(fp)
		Dress.off = false
		var lights: Array[int] = [0, 0]
		var others: Array[Dictionary] = [{}, {}]
		var dress: Array[MeshInstance3D] = []
		for i in 2:
			var lv: Level = on if i == 0 else bare
			for c in lv.get_children():
				if c is Light3D:
					lights[i] += 1
					var l := c as Light3D
					others[i]["L%d" % lights[i]] = "%s %s %.3f %s" % [l.get_class(), l.position, l.light_energy, l.light_color]
				elif c is MeshInstance3D and String(c.name).ends_with("_ldress"):
					dress.append(c)
				elif c is MeshInstance3D:
					var mi := c as MeshInstance3D
					var nm := String(mi.name)
					others[i][("mesh" if nm.begins_with("@") else nm) + str(mi.position)] = "%s %d" % [mi.get_aabb(), mi.layers]
		t.eq(lights[0], lights[1], "the Clinic %s: lights with and without the dressing" % sd)
		var diff := PackedStringArray()
		for k: String in others[0]:
			if str(others[0][k]) != str(others[1].get(k, "")):
				diff.append("%s: %s / %s" % [k, others[0][k], others[1].get(k, "missing")])
		for k: String in others[1]:
			if not others[0].has(k):
				diff.append("%s missing with the dressing" % k)
		t.check(diff.is_empty(), "the Clinic %s: every other mesh and light is the same with and without it: %s" % [sd, "; ".join(diff.slice(0, 4))])
		var mats := {}
		var ok := true
		for mi in dress:
			mats[mi.material_override] = true
			ok = ok and mi.get_child_count() == 0 and mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			ok = ok and float((mi.material_override as ShaderMaterial).get_shader_parameter("emit")) == 0.0
			ok = ok and (String(mi.name).begins_with("1_") or mi.layers == Level.LOWER_LAYER)
		t.check(not dress.is_empty() and ok, "the Clinic %s: %d dressing meshes, drawing only, no shadow, no glow, on their storey's layer" % [sd, dress.size()])
		t.eq(mats.size(), 1, "the Clinic %s: one material for the dressing" % sd)
		t.check(dress.size() <= 2 * ceili(on.W / float(Dress.GROUP)) * ceili(on.H / float(Dress.GROUP)), "the Clinic %s: merged into few meshes (%d)" % [sd, dress.size()])
		t.note("the Clinic %s: %d dressing meshes, %d material, %d boxes" % [sd, dress.size(), mats.size(), records(on).size()])
		on.free()
		bare.free()

## The same floor seed dresses the same, on every screen.
func test_the_same_floor_dresses_the_same(t: T) -> void:
	var a := _built(Clinic.generate_clinic("la3-same", 2))
	var b := _built(Clinic.generate_clinic("la3-same", 2))
	var hs: Array[PackedStringArray] = [PackedStringArray(), PackedStringArray()]
	for i in 2:
		var lv: Level = a if i == 0 else b
		for c in lv.get_children():
			if c is MeshInstance3D and String(c.name).ends_with("_ldress"):
				hs[i].append("%s:%s" % [c.name, str((c as MeshInstance3D).mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]).md5_text()])
		hs[i].append(str(records(lv)).md5_text())
	t.check(hs[0].size() > 2 and hs[0] == hs[1], "two builds of one floor seed draw identical dressing")
	var other := _built(Clinic.generate_clinic("la3-other", 2))
	t.check(str(records(other)) != str(records(a)), "another seed dresses differently")
	a.free()
	b.free()
	other.free()

## Near the lift every piece is clean and straight; far from it the same pieces are yellowed, and some hang crooked
## or are gone.
func test_far_from_the_lift_the_pieces_are_worn(t: T) -> void:
	var floors := _floors(t.quick)
	var tilted := 0
	var gone := 0
	var far := 0
	var near := 0
	var bad := PackedStringArray()
	for f: Array in floors:
		for r: Dictionary in records(f[2] as Level):
			var c := float(r.corr)
			var lost := bool(r.ghost) and str(r.kind) != "stain"
			if c < 0.25:
				near += 1
				if float(r.dirt) != 0.0 or float(r.tilt) != 0.0 or lost:
					bad.append("%s near the lift (%.2f) is worn" % [r.kind, c])
			elif c > 0.7:
				far += 1
				if float(r.dirt) < 0.6:
					bad.append("%s far from the lift (%.2f) is clean" % [r.kind, c])
				if float(r.tilt) != 0.0:
					tilted += 1
				if lost:
					gone += 1
	t.check(near > 20 and far > 20, "pieces near the lift (%d) and far from it (%d)" % [near, far])
	t.check(bad.is_empty(), "%d: %s" % [bad.size(), "; ".join(bad.slice(0, 5))])
	t.check(tilted > 0 and gone > 0, "far from the lift some hang crooked (%d) and some are gone (%d)" % [tilted, gone])
	_free(floors)

## The Clinic's wall paint mirrors its panels here and there and mixes in a second mark (surface.gdshader wall_vary);
## no other surface of it does, and the shader leaves every other material as it was.
func test_the_clinic_wall_paint_varies(t: T) -> void:
	var lv := _built(Clinic.generate_clinic("la3-paint", 1))
	t.eq(lv.mat_wall.get_shader_parameter("wall_vary"), 1.0, "the Clinic's walls vary their paint")
	t.eq(lv.mat_floor.get_shader_parameter("wall_vary"), null, "its floor keeps the default")
	t.eq(lv.mat_ceiling.get_shader_parameter("wall_vary"), null, "its ceiling keeps the default")
	lv.free()
	var code := (load("res://client/surface.gdshader") as Shader).code
	t.check(code.contains("uniform float wall_vary = 0.0;"), "the shader's default leaves a material as it was")

## The signs say nothing about looking or about what lives here, and every letter is one the font has.
func test_the_signs_say_nothing_about_the_rules(t: T) -> void:
	var words: Array[String] = ["LOOK", "WATCH", "SEE", "SEEN", "EYE", "EYES", "STARE", "BLINK", "TURN", "BEHIND", "MOVE", "MOVES", "STILL", "SIGHT", "GAZE", "BACK", "AWAY", "DARK"]
	var bad := PackedStringArray()
	for s: String in Dress.texts():
		for w in s.replace(".", " ").split(" ", false):
			if w in words:
				bad.append(s)
		for i in s.length():
			if not PixelFont.known(s[i]):
				bad.append("%s (%s)" % [s, s[i]])
	t.check(bad.is_empty(), "signs: %s" % ", ".join(bad))
