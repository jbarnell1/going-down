extends RefCounted
## LA6: the Playroom's walls, upper deck and soft shapes dressed (client/playroom_dress.gd), looks only. Nothing added
## hides what the plan's own sight check says a player sees, at standing or creeping eye height, as any point of a
## figure, or from inside a hide; nothing stands in the walkable space below 2.2 m but within 15 cm of a wall face, and
## the soft shapes stay inside the boxes the view drew them in; nothing touches a hide, the floor in front of it, a
## squeaker tile, a glowing mat line, a zone sign, the landing or the floor the crew's marks lie on; nothing is a light
## or lit by itself, and it all goes dark with the strip lights; the same floor seed gives the same dressing; and far
## from the lift the pieces are bleached and worn where near it they are clean and straight.

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Playroom = preload("res://sim/playroom.gd")
const Floor = preload("res://sim/floor.gd")
const Sight = preload("res://sim/sight.gd")
const Findables = preload("res://sim/findables.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const Dress = preload("res://client/playroom_dress.gd")
const View = preload("res://client/playroom_view.gd")
const EyeHeight = preload("res://client/eye_height.gd")
const PixelFont = preload("res://client/pixel_font.gd")

const S := 2.0
const LH := 3.2
## A body's radius (net/session.gd PLAYER_RADIUS): no spot closer to a wall line.
const BODY := 0.3
## The heights of a figure's points the rules look at, over its feet (sim/sight.gd FIGURE_LEVELS).
const FIGURE: Array[float] = [0.05, 0.52, 1.1, 1.7, 2.6]
const FIGURE_QUICK: Array[float] = [0.05, 1.1, 2.6]
const BEYOND_QUICK: Array[float] = [0.15, 0.8, 3.0, 12.0]
const BEYOND: Array[float] = [0.15, 0.4, 0.8, 1.5, 3.0, 6.0, 12.0, 24.0]
const SEEDS: Array[String] = ["la6-a", "la6-b", "la6-c", "la6-d"]
const SIDES: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]

static func _built(fp: Floor.FloorPlan) -> Level:
	var level := Level.new()
	level.build(PlanDump.dump(fp, Run.car_geometry(fp)), fp.seed, fp)
	return level

static func _floors(quick: bool) -> Array:
	var out: Array = []
	for i in (1 if quick else SEEDS.size()):
		var fp := Playroom.generate_playroom(SEEDS[i], 4)
		out.append(["the Playroom %s" % SEEDS[i], fp, _built(fp)])
	return out

static func _free(floors: Array) -> void:
	for f: Array in floors:
		(f[2] as Node).free()

static func records(lv: Level) -> Array:
	return lv.get_meta(&"playroom_dress", [])

static func soft(lv: Level) -> Array:
	return lv.get_meta(&"playroom_soft", [])

static func view(lv: Level) -> Node:
	return lv.get_meta("playroom")

## The pieces that can stand in a line of sight: every record but the netting (see-through, as the rails').
static func pieces(lv: Level) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var hides: Array = view(lv).get("hides")
	for r: Dictionary in records(lv):
		if bool(r.see):
			continue
		if str(r.kind) == "playhouse_paint":
			# Paint on the playhouse's own front: a line through it goes on through the playhouse.
			var h: Playroom.Hide = hides[int(r.hide)]
			var g := Vector3(Floor.dir_dx(h.gap), 0, Floor.dir_dy(h.gap))
			var xf := Transform3D(Basis(Vector3.UP.cross(g).normalized(), Vector3.UP, g), Vector3(h.inside.x / 100.0, h.level * LH, h.inside.y / 100.0))
			var r2 := r.duplicate()
			r2["old"] = AABB(xf * Vector3(-0.6, 0, -0.42), Vector3.ZERO).expand(xf * Vector3(0.6, 1.3, 0.425))
			out.append(r2)
			continue
		out.append(r)
	for r: Dictionary in soft(lv):
		out.append({"kind": "soft", "level": r.level, "aabb": r.aabb, "n": Vector3.ZERO, "face": (r.aabb as AABB).get_center(), "old": r.old})
	return out

# --- where a body can be -------------------------------------------------------------------------

static func edge(lv: Level, level: int, x: int, y: int, v: Vector2i) -> String:
	if x < 0 or y < 0 or x >= lv.W or y >= lv.H:
		return "wall"
	var vert: Array = lv.edges[level].vertical
	var hor: Array = lv.edges[level].horizontal
	if v == Vector2i(0, -1): return hor[y * lv.W + x]
	if v == Vector2i(0, 1): return hor[(y + 1) * lv.W + x]
	if v == Vector2i(-1, 0): return vert[y * (lv.W + 1) + x]
	return vert[y * (lv.W + 1) + x + 1]

## Whether a body can stand with its feet at (x, z) on `level`: a walkable cell, clear of the solid walls (a doorway's
## jambs included). The Playroom has no floor-standing solids in the rules (sim/furniture.gd).
static func body_ok(lv: Level, level: int, x: float, z: float) -> bool:
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
	return true

## A spread of spots where a body can stand: each walkable cell's middle, spots 31 cm off each solid side and in its
## corners, three in each doorway and three along each open side.
static func spots(lv: Level) -> Array:
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
					elif e == "none" or e == "open" or e == "rail":
						for a: float in [-(S * 0.5 - o), 0.0, S * 0.5 - o]:
							cand.append(c + vv * (S * 0.5 - (o if e == "rail" else 0.0)) + side * a)
					else:
						cand.append(c + vv * (S * 0.5 - o))
						cand.append(c + vv * (S * 0.5 - o) + side * (S * 0.5 - o))
				for p in cand:
					var key := Vector2i(roundi(p.x * 100.0), roundi(p.y * 100.0))
					if not seen.has(key) and body_ok(lv, level, p.x, p.y):
						seen[key] = true
						(out[level] as Array).append(p)
	return out

## The drawn walls as boxes: a line the drawing already hides is not one a piece can newly hide.
static func wall_boxes(lv: Level) -> Array[AABB]:
	var out: Array[AABB] = []
	var h := Level.WALL_T * 0.5
	var lift := lv._lift_edge()
	for level in 2:
		var vert: Array = lv.edges[level].vertical
		var hor: Array = lv.edges[level].horizontal
		for y in lv.H:
			for x in lv.W + 1:
				var k: String = vert[y * (lv.W + 1) + x]
				if k == "rail":
					continue
				var is_lift := level == lv.landing.x and lift == Vector4i(0, x, y, 1)
				for part: Array in lv._edge_parts(level, k, is_lift):
					for r: Array in part[0]:
						out.append(AABB(Vector3(x * S - h, level * LH + float(part[1]), y * S + float(r[0])), Vector3(2 * h, float(part[2]) - float(part[1]), float(r[1]) - float(r[0]))))
		for y in lv.H + 1:
			for x in lv.W:
				var k: String = hor[y * lv.W + x]
				if k == "rail":
					continue
				var is_lift := level == lv.landing.x and lift == Vector4i(1, x, y, 1)
				for part: Array in lv._edge_parts(level, k, is_lift):
					for r: Array in part[0]:
						out.append(AABB(Vector3(x * S + float(r[0]), level * LH + float(part[1]), y * S - h), Vector3(float(r[1]) - float(r[0]), float(part[2]) - float(part[1]), 2 * h)))
	return out

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

## Whether a drawn wall already stops the segment.
static func _walled(walls: Array[AABB], a: Vector3, b: Vector3) -> bool:
	for w in walls:
		if seg_hits(a, b, w):
			return true
	return false

static func _corner(b: AABB, k: int) -> Vector3:
	return b.position + Vector3(b.size.x * float(k & 1), b.size.y * float((k >> 1) & 1), b.size.z * float((k >> 2) & 1))

static func _hole_within(lv: Level, c: Vector2i, reach: int) -> bool:
	for y in range(c.y - reach, c.y + reach + 1):
		for x in range(c.x - reach, c.x + reach + 1):
			var k := lv.kind(1, x, y)
			if k == "atriumOpen" or k == "stair":
				return true
	return false

# --- sight ---------------------------------------------------------------------------------------

## For one floor: every line from a spot near a piece (an eye standing or creeping, or a point of a figure) through a
## point of the piece to a spot beyond it, that the plan's sight check lets through and the drawn walls do not already
## stop; and from every hide's eye to the spots in reach. Returns {faults, tried}.
static func sight_faults(lv: Level, fp: Floor.FloorPlan, quick: bool) -> Dictionary:
	var sp := spots(lv)
	var walls := wall_boxes(lv)
	var faults := PackedStringArray()
	var tried := 0
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(fp.seed + ":%d" % fp.depth)
	var eyes: Array[float] = [EyeHeight.STAND, EyeHeight.CREEP]
	var reach := 14.0
	var all := pieces(lv)
	for p: Dictionary in all:
		var box: AABB = p.aabb
		var level := int(p.level)
		var floor_y := level * LH
		var n: Vector3 = p.n
		var mid := box.get_center()
		var near: Array = []
		if box.position.y - floor_y < 2.6:
			if n != Vector3.ZERO:
				var face: Vector3 = p.face
				var deep := 0.0
				for k in 8:
					deep = maxf(deep, (_corner(box, k) - face).dot(n))
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
			else:
				# A free-standing piece (a soft shape): the spots round it.
				var round: Array = []
				for q: Vector2 in sp[level]:
					if Vector2(q.x - mid.x, q.y - mid.z).length() < 4.0:
						round.append(Vector3(q.x, floor_y, q.y))
				var cap_r := 8 if quick else 40
				while round.size() > cap_r:
					round.remove_at(rng.randi_range(0, round.size() - 1))
				near.append_array(round)
		var other: Array = []
		if _hole_within(lv, Vector2i(floori(mid.x / S), floori(mid.z / S)), 10):
			for q: Vector2 in sp[1 - level]:
				if Vector2(q.x - mid.x, q.y - mid.z).length() < reach * 1.5:
					other.append(Vector3(q.x, (1 - level) * LH, q.y))
		# The other storey's spots nearest the piece first (a line between the storeys comes steeply past a wall right under
		# or over the slab's edge), then a random spread of the rest.
		var cap := 6 if quick else 30
		other.sort_custom(func(a: Vector3, b: Vector3) -> bool: return Vector2(a.x - mid.x, a.z - mid.z).length() < Vector2(b.x - mid.x, b.z - mid.z).length())
		var nearest := other.slice(0, cap / 2)
		var rest := other.slice(cap / 2)
		while rest.size() > cap - nearest.size():
			rest.remove_at(rng.randi_range(0, rest.size() - 1))
		other = nearest + rest
		near.append_array(other)
		var qs: Array[Vector3] = [mid]
		for k: int in ([0, 6] if quick else [0, 3, 5, 6]):
			qs.append(mid.lerp(_corner(box, k), 0.7))
		for x_feet: Vector3 in near:
			for role in 2:
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
							for s: float in (BEYOND_QUICK if quick else BEYOND):
								var e0 := qp + dir * s
								var h0 := e0.y - _level_of(e0.y) * LH
								if h0 >= 0.05 and h0 <= 2.6:
									ends.append(e0)
						elif absf(dir.y) > 1e-6:
							for he: float in eyes:
								for lvl in 2:
									var tt := (lvl * LH + he - qp.y) / dir.y
									if tt > 0.0 and tt < 40.0:
										ends.append(qp + dir * tt)
						for yp in ends:
							var yl := _level_of(yp.y)
							if not body_ok(lv, yl, yp.x, yp.z):
								continue
							tried += 1
							var eye := xp if role == 0 else yp
							var fig := yp if role == 0 else xp
							if not Sight.has_line_of_sight(fp, _pt(eye), _pt(fig)):
								continue
							if not seg_hits(eye, fig, box):
								continue
							var hidden := false
							for w in walls:
								if seg_hits(eye, fig, w):
									hidden = true
									break
							if not hidden and p.has("old") and seg_hits(eye, fig, p.old):
								# A soft shape's line was cut by the shape the view drew there before.
								hidden = true
							if not hidden:
								faults.append("%s at %s (cell %s, n %s) cuts %s -> %s" % [p.kind, box, p.get("cell"), p.n, eye, fig])
	# The views out of the hides: from each hide's eye to the spots in reach.
	var v := view(lv)
	for h: Playroom.Hide in v.get("hides"):
		var e := Vector3(h.inside.x / 100.0, h.level * LH + h.eye / 100.0, h.inside.y / 100.0)
		var close: Array[Dictionary] = []
		for p: Dictionary in all:
			if int(p.level) == h.level and (p.aabb as AABB).grow(9.0).has_point(e):
				close.append(p)
		for q: Vector2 in sp[h.level]:
			if Vector2(q.x - e.x, q.y - e.z).length() > 8.0:
				continue
			for hf: float in FIGURE:
				var fig := Vector3(q.x, h.level * LH + hf, q.y)
				var cut := ""
				for p: Dictionary in close:
					if seg_hits(e, fig, p.aabb) and not (p.has("old") and seg_hits(e, fig, p.old)):
						cut = "%s at %s (cell %s, n %s)" % [p.kind, p.aabb, p.get("cell"), p.n]
						break
				tried += 1
				if cut != "" and Sight.has_line_of_sight(fp, _pt(e), _pt(fig)) and not _walled(walls, e, fig):
					faults.append("%s cuts the view out of hide %d (%s): %s -> %s" % [cut, h.id, h.kind, e, fig])
	return {"faults": faults, "tried": tried}

func test_nothing_added_hides_what_the_plan_sees(t: T) -> void:
	var floors := _floors(t.quick)
	for f: Array in floors:
		var lv: Level = f[2]
		var t0 := Time.get_ticks_msec()
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
		var sp := spots(lv)
		var all: Array[Vector3] = []
		for level in 2:
			for q: Vector2 in sp[level]:
				all.append(Vector3(q.x, level * LH, q.y))
		var ps := pieces(lv)
		var walls := wall_boxes(lv)
		var rng := RandomNumberGenerator.new()
		rng.seed = hash("spread:" + fp.seed)
		var seen := 0
		var cut := PackedStringArray()
		for i in (30000 if t.quick else 90000):
			var a := all[rng.randi_range(0, all.size() - 1)]
			var b := all[rng.randi_range(0, all.size() - 1)]
			if a.distance_to(b) > 24.0:
				continue
			var eye := a + Vector3(0, EyeHeight.STAND if i % 2 == 0 else EyeHeight.CREEP, 0)
			var fig := b + Vector3(0, FIGURE[i % FIGURE.size()], 0)
			if not Sight.has_line_of_sight(fp, _pt(eye), _pt(fig)):
				continue
			seen += 1
			var hit := ""
			for p: Dictionary in ps:
				if seg_hits(eye, fig, p.aabb) and not (p.has("old") and seg_hits(eye, fig, p.old)):
					hit = "%s at %s (cell %s, n %s)" % [p.kind, p.aabb, p.get("cell"), p.n]
					break
			if hit != "" and not _walled(walls, eye, fig):
				cut.append(hit + " %s -> %s" % [eye, fig])
		t.check(seen > 300, "%s: lines the plan sees (%d)" % [f[0], seen])
		t.check(cut.is_empty(), "%s: %d of them cut by the dressing: %s" % [f[0], cut.size(), "; ".join(cut.slice(0, 4))])
	_free(floors)

# --- where the pieces are ------------------------------------------------------------------------

static func _edge_behind(lv: Level, level: int, p: Vector3, n: Vector3) -> String:
	var c := p + n * 0.3
	var v := Vector2i(roundi(-n.x), roundi(-n.z))
	return edge(lv, level, floori(c.x / S), floori(c.z / S), v)

## Below 2.2 m nothing stands out from its wall face by more than 15 cm; every wall piece has its wall behind it and is
## off the floor the crew's marks lie on; every high piece is above every point the rules look at; every soft shape is
## inside the box the view drew it in before and still fills most of its footprint; the playhouses' paint is flat on
## their fronts, clear of the shutter.
func test_nothing_stands_in_the_walkable_space(t: T) -> void:
	var floors := _floors(t.quick)
	for f: Array in floors:
		var lv: Level = f[2]
		var bad := PackedStringArray()
		var walls := 0
		var highs := 0
		for r: Dictionary in records(lv):
			var box: AABB = r.aabb
			var level := int(r.level)
			var lo := box.position.y - level * LH
			var n: Vector3 = r.n
			if str(r.kind) == "playhouse_paint":
				continue
			if bool(r.high) or n == Vector3.ZERO:
				highs += 1
				if lo < Dress.HIGH_Y - 0.001:
					bad.append("%s hung at %.3f m" % [r.kind, lo])
				continue
			walls += 1
			# On its own storey's wall: between that storey's floor and its ceiling.
			if lo < -0.001 or box.end.y > level * LH + LH + 0.001:
				bad.append("%s on level %d spans %.2f to %.2f m, off its storey" % [r.kind, level, box.position.y, box.end.y])
			if lo < Dress.FLOOR_CLEAR - 0.001:
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
				# Beside a doorway: the jamb, the door's wall either side of its opening (DOOR_W in the middle of the side).
				var off := (p.x - (floorf(p.x / S) + 0.5) * S) if along.x > 0.5 else (p.z - (floorf(p.z / S) + 0.5) * S)
				if e == "door" and absf(off) >= Level.DOOR_W * 0.5 + 0.01:
					continue
				if e != "wall":
					bad.append("%s at %s has no wall behind it (%s)" % [r.kind, p, e])
					break
		var softs := 0
		for r: Dictionary in soft(lv):
			softs += 1
			var box: AABB = r.aabb
			var old: AABB = r.old
			if not old.grow(0.011).encloses(box):
				bad.append("a soft shape %s is drawn outside its old box %s" % [box, old])
			var fill := (box.size.x * box.size.z) / maxf(old.size.x * old.size.z, 0.0001)
			if fill < 0.55 or box.size.y < old.size.y * 0.7:
				bad.append("a soft shape %s fills too little of its old box %s" % [box, old])
		var v := view(lv)
		for r: Dictionary in records(lv):
			if str(r.kind) != "playhouse_paint":
				continue
			var h: Playroom.Hide = (v.get("hides") as Array)[int(r.hide)]
			var g := Vector3(Floor.dir_dx(h.gap), 0, Floor.dir_dy(h.gap))
			var at := Vector3(h.inside.x / 100.0, h.level * LH, h.inside.y / 100.0)
			var box: AABB = r.aabb
			for k in 8:
				var off := (_corner(box, k) - at).dot(g)
				if off < 0.419 or off > 0.432:
					bad.append("playhouse %d's paint is %.3f m out, not on its front" % [h.id, off])
					break
			# The shutter: 0.84 to 1.16 m up, 0.5 m wide in the middle of the front, and the view out of it.
			var xf := Transform3D(Basis(Vector3.UP.cross(g).normalized(), Vector3.UP, g), at)
			var shutter := AABB(xf * Vector3(-0.25, 0.84, 0.3), Vector3.ZERO).expand(xf * Vector3(0.25, 1.16, 1.5))
			if box.intersects(shutter):
				bad.append("playhouse %d's paint covers its shutter" % h.id)
		t.check(walls > 100 and highs > 10 and softs > 0, "%s: wall pieces (%d), high pieces (%d), soft shapes (%d)" % [f[0], walls, highs, softs])
		t.check(bad.is_empty(), "%s: %d pieces out of place: %s" % [f[0], bad.size(), "; ".join(bad.slice(0, 5))])
	_free(floors)

## Nothing touches a hide's body, the floor in front of its open side out to the Minder's front spot, a squeaker tile, a
## glowing mat line, a zone sign or the wall in front of it, a findable, a doorway, the landing.
func test_nothing_crowds_a_hide_a_tile_a_line_or_a_sign(t: T) -> void:
	var floors := _floors(t.quick)
	for f: Array in floors:
		var lv: Level = f[2]
		var r := crowd_faults(lv, f[1])
		var bad: PackedStringArray = r.bad
		t.check(int(r.tested) > 1000, "%s: pieces against hides, tiles, lines and signs (%d)" % [f[0], int(r.tested)])
		t.check(bad.is_empty(), "%s: %d: %s" % [f[0], bad.size(), "; ".join(bad.slice(0, 5))])
	_free(floors)

## A hide's body as the view draws it (client/playroom_view.gd), its half size across and its height.
const HIDE_BODY := {&"pit": Vector2(2.85, 0.5), &"slide": Vector2(0.55, 2.0), &"den": Vector2(0.6, 1.2), &"playhouse": Vector2(0.7, 2.0),
	&"table": Vector2(1.45, 0.75), &"chest": Vector2(0.55, 0.7), &"cubby": Vector2(0.5, 1.95)}

static func crowd_faults(lv: Level, fp: Floor.FloorPlan) -> Dictionary:
	var v := view(lv)
	var keep: Array = [[], []]
	var named: Array = [[], []]
	for h: Playroom.Hide in v.get("hides"):
		var base := h.level * LH
		var c := Vector3(h.inside.x / 100.0, base, h.inside.y / 100.0)
		var hb: Vector2 = HIDE_BODY[h.kind]
		# The slide's climb runs up its wall to the ceiling. A hide stands inside its room: its body ends at the room's walls.
		var top := LH if h.kind == &"slide" and h.level == 0 else hb.y
		var rm: Dictionary = (lv.plan.rooms as Array).filter(func(q: Dictionary) -> bool: return int(q.id) == h.room)[0]
		var rbox := AABB(Vector3(int(rm.x) * S, int(rm.level) * LH, int(rm.y) * S), Vector3(int(rm.w) * S, LH, int(rm.h) * S))
		(keep[h.level] as Array).append(AABB(c - Vector3(hb.x, 0, hb.x), Vector3(hb.x * 2.0, top, hb.x * 2.0)).intersection(rbox))
		(named[h.level] as Array).append("hide %d (%s)" % [h.id, h.kind])
		var fr := Vector3(h.front.x / 100.0, base, h.front.y / 100.0)
		var lo := Vector3(minf(c.x, fr.x), base, minf(c.z, fr.z)) - Vector3(BODY, 0, BODY)
		var hi := Vector3(maxf(c.x, fr.x), base + 2.2, maxf(c.z, fr.z)) + Vector3(BODY, 0, BODY)
		(keep[h.level] as Array).append(AABB(lo, hi - lo))
		(named[h.level] as Array).append("the front of hide %d" % h.id)
	for idx: int in v.get("squeak"):
		var c: Vector3i = v.call("_cell_of", idx)
		var p := lv.cell_center(c.x, c.y, c.z)
		(keep[c.x] as Array).append(AABB(p - Vector3(0.85, 0, 0.85), Vector3(1.7, 0.3, 1.7)))
		(named[c.x] as Array).append("a squeaker tile")
	for r: Dictionary in lv.plan.rooms:
		if str(r.kind) == "lobby":
			continue
		var level := int(r.level)
		var x0 := int(r.x) * S + 0.4
		var z0 := int(r.y) * S + 0.4
		var x1 := (int(r.x) + int(r.w)) * S - 0.4
		var z1 := (int(r.y) + int(r.h)) * S - 0.4
		var y := level * LH
		for b: AABB in [AABB(Vector3(x0, y, z0 - 0.05), Vector3(x1 - x0, 0.3, 0.1)), AABB(Vector3(x0, y, z1 - 0.05), Vector3(x1 - x0, 0.3, 0.1)),
				AABB(Vector3(x0 - 0.05, y, z0), Vector3(0.1, 0.3, z1 - z0)), AABB(Vector3(x1 - 0.05, y, z0), Vector3(0.1, 0.3, z1 - z0))]:
			(keep[level] as Array).append(b)
			(named[level] as Array).append("a mat line")
	for s: Dictionary in v.get("signs"):
		var p: Vector3 = s.pos
		var n: Vector3 = s.facing
		var across := Vector3(absf(n.z), 0, absf(n.x))
		var a := p - across * 0.6 - Vector3(0, 0.15, 0)
		var b := p + across * 0.6 + Vector3(0, 0.15, 0) + n * 1.7
		(keep[int(s.level)] as Array).append(AABB(Vector3(minf(a.x, b.x), a.y, minf(a.z, b.z)), (b - a).abs()))
		(named[int(s.level)] as Array).append("zone sign %d and the way to read it" % int(s.zone))
	for pc in Findables.spots_for(fp, fp.seed, fp.depth):
		var ft := Rect2(pc.foot.position.x / 100.0, pc.foot.position.y / 100.0, pc.foot.size.x / 100.0, pc.foot.size.y / 100.0).grow(0.7)
		(keep[pc.level] as Array).append(AABB(Vector3(ft.position.x, pc.level * LH, ft.position.y), Vector3(ft.size.x, 2.2, ft.size.y)))
		(named[pc.level] as Array).append("a findable")
	for d: Floor.Door in fp.doors:
		var a := lv.cell_center(d.level, d.ax, d.ay)
		var b := lv.cell_center(d.level, d.bx, d.by)
		var m := (a + b) * 0.5
		var across := Vector3(absf(b.z - a.z), 0, absf(b.x - a.x)).normalized()
		var thru := (b - a).normalized().abs()
		var lo := m - across * (Level.DOOR_W * 0.5) - thru * 0.5
		(keep[d.level] as Array).append(AABB(lo, across * Level.DOOR_W + thru * 1.0 + Vector3(0, Level.DOOR_H, 0)))
		(named[d.level] as Array).append("a doorway")
	for pc: Dictionary in v.get("pieces"):
		for c: Vector2i in pc.cells:
			var p := lv.cell_center(int(pc.level), c.x, c.y)
			(keep[int(pc.level)] as Array).append(AABB(p - Vector3(1.0, 0, 1.0), Vector3(2.0, 2.6, 2.0)))
			(named[int(pc.level)] as Array).append("a ready-made %s" % pc.kind)
	var lc := lv.cell_center(lv.landing.x, lv.landing.y, lv.landing.z)
	(keep[lv.landing.x] as Array).append(AABB(lc - Vector3(1.0, 0, 1.0), Vector3(2.0, LH, 2.0)))
	(named[lv.landing.x] as Array).append("the landing")
	var bad := PackedStringArray()
	var tested := 0
	for r: Dictionary in records(lv):
		var level := int(r.level)
		var box: AABB = r.aabb
		for i in (keep[level] as Array).size():
			if str(r.kind) == "playhouse_paint" and str(named[level][i]).begins_with("hide %d " % int(r.hide)):
				continue
			if str(r.kind) == "playhouse_paint" and str(named[level][i]) == "the front of hide %d" % int(r.hide):
				continue
			# The paint is upright on the playhouse's own front, over the floor the playhouse already stands on.
			if str(r.kind) == "playhouse_paint" and str(named[level][i]) == "a mat line":
				continue
			tested += 1
			if box.intersects(keep[level][i]):
				bad.append("%s %s meets %s" % [r.kind, box, named[level][i]])
	return {"bad": bad, "tested": tested}

# --- nothing else ---------------------------------------------------------------------------------

## The dressing adds no light and changes no other mesh (the soft shapes move from the view's prop meshes to the
## dressing's). Its meshes use the dressing's material (mode 0, no glow), the view's netting or the view's props; none
## casts a shadow; every vertex is opaque; at count dark its material is out with the strip lights.
func test_the_dressing_adds_no_light_glows_not_and_goes_dark(t: T) -> void:
	for sd: String in ["la6-a", "alpha"]:
		var fp := Playroom.generate_playroom(sd, 4)
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
				elif c is MeshInstance3D:
					var mi := c as MeshInstance3D
					var nm := String(mi.name)
					if i == 0 and nm.contains("_pld") and mi.mesh.get_surface_count() > 0:
						dress.append(mi)
					elif not nm.ends_with("_pprops") and not nm.ends_with("_pnet") and not nm.begins_with("@"):
						others[i][nm] = "%s %s" % [mi.get_aabb(), mi.layers]
		t.eq(lights[0], lights[1], "the Playroom %s: lights with and without the dressing" % sd)
		var diff := PackedStringArray()
		for k: String in others[0]:
			if str(others[0][k]) != str(others[1].get(k, "")):
				diff.append("%s: %s / %s" % [k, others[0][k], others[1].get(k, "missing")])
		for k: String in others[1]:
			if not others[0].has(k):
				diff.append("%s missing with the dressing" % k)
		t.check(diff.is_empty(), "the Playroom %s: every other mesh is the same with and without it: %s" % [sd, "; ".join(diff.slice(0, 4))])
		var v := view(on)
		var md: ShaderMaterial = v.get("mat_dress")
		var mats := {}
		var ok := true
		var verts := 0
		var opaque := true
		for mi in dress:
			mats[mi.material_override] = true
			ok = ok and mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and mi.get_child_count() == 0
			var nm := String(mi.name)
			ok = ok and mi.material_override == md
			var arr := mi.mesh.surface_get_arrays(0)
			verts += (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			for col: Color in (arr[Mesh.ARRAY_COLOR] as PackedColorArray):
				if col.a < 0.999:
					opaque = false
		t.check(not dress.is_empty() and ok, "the Playroom %s: %d dressing meshes with the dressing's material, casting no shadow" % [sd, dress.size()])
		# The netting and the soft shapes go into the view's own netting and prop meshes: no vertex of theirs glows more
		# with the dressing than without it.
		var glowing: Array[int] = [0, 0]
		for i in 2:
			for c in (on if i == 0 else bare).get_children():
				var nm := String(c.name)
				if c is MeshInstance3D and (nm.ends_with("_pprops") or nm.ends_with("_pnet")) and (c as MeshInstance3D).mesh.get_surface_count() > 0:
					for col: Color in ((c as MeshInstance3D).mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR] as PackedColorArray):
						if col.a < 0.999:
							glowing[i] += 1
		t.eq(glowing[0], glowing[1], "the Playroom %s: the props and nets glow no more with the dressing (vertices)" % sd)
		t.check(opaque, "the Playroom %s: every vertex of the dressing is opaque (the shader's self-lit path never taken)" % sd)
		t.eq(float(md.get_shader_parameter("mode")), 0.0, "the Playroom %s: the dressing's material takes its colour from the atlas alone" % sd)
		t.check((v.get("_lit_mats") as Array).has(md), "the Playroom %s: the dressing's material is one the strip lights dim" % sd)
		v.call("set_count_dark", 1.0)
		v.call("_apply", 1.0, 0.0)
		t.eq(float(md.get_shader_parameter("energy")), 0.0, "the Playroom %s: in count dark the dressing is dark" % sd)
		t.eq(v.call("check_dark"), [] as Array[String], "the Playroom %s: the count dark's own check holds with the dressing" % sd)
		v.call("set_count_dark", 0.0)
		v.call("_apply", 1.0, 0.0)
		t.note("the Playroom %s: %d dressing meshes, %d materials (1 new), %d vertices, %d records" % [sd, dress.size(), mats.size(), verts, records(on).size() + soft(on).size()])
		on.free()
		bare.free()

## The same floor seed dresses the same, on every screen.
func test_the_same_floor_dresses_the_same(t: T) -> void:
	var a := _built(Playroom.generate_playroom("la6-same", 4))
	var b := _built(Playroom.generate_playroom("la6-same", 4))
	var hs: Array[PackedStringArray] = [PackedStringArray(), PackedStringArray()]
	for i in 2:
		var lv: Level = a if i == 0 else b
		for c in lv.get_children():
			if c is MeshInstance3D and String(c.name).contains("_pld") and (c as MeshInstance3D).mesh.get_surface_count() > 0:
				hs[i].append("%s:%s" % [c.name, str((c as MeshInstance3D).mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]).md5_text()])
		hs[i].append(str(records(lv)).md5_text())
		hs[i].append(str(soft(lv)).md5_text())
	t.check(hs[0].size() > 3 and hs[0] == hs[1], "two builds of one floor seed draw identical dressing")
	var other := _built(Playroom.generate_playroom("la6-other", 4))
	t.check(str(records(other)) != str(records(a)), "another seed dresses differently")
	a.free()
	b.free()
	other.free()

## Near the lift every piece is whole and straight; far from it some panels are gone (a pale patch left) and some
## letters hang crooked or are missing; the paint carries its walk from the lift to the shader, which bleaches by it.
func test_far_from_the_lift_the_pieces_bleach_and_wear(t: T) -> void:
	var floors := _floors(t.quick)
	var near := 0
	var far := 0
	var gone := 0
	var tilted := 0
	var bad := PackedStringArray()
	var reds_near := 0
	var reds_far := 0
	for f: Array in floors:
		var lv: Level = f[2]
		for r: Dictionary in records(lv):
			var c := float(r.corr)
			if c < 0.25:
				near += 1
				if bool(r.ghost) or float(r.tilt) != 0.0:
					bad.append("%s near the lift (%.2f) is worn" % [r.kind, c])
				if str(r.kind) == "letter" and str(r.text) != "PLAY NICELY":
					bad.append("near the lift the letters say %s" % r.text)
			elif c > Dress.FAR:
				far += 1
				if bool(r.ghost):
					gone += 1
				if float(r.tilt) != 0.0:
					tilted += 1
		for ch in lv.get_children():
			if ch is MeshInstance3D and String(ch.name).ends_with("_pldress") and (ch as MeshInstance3D).mesh.get_surface_count() > 0:
				for col: Color in ((ch as MeshInstance3D).mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR] as PackedColorArray):
					if col.r < 0.2:
						reds_near += 1
					elif col.r > 0.8:
						reds_far += 1
	t.check(near > 30 and far > 30, "pieces near the lift (%d) and far from it (%d)" % [near, far])
	t.check(bad.is_empty(), "%d: %s" % [bad.size(), "; ".join(bad.slice(0, 5))])
	t.check(gone > 0 and tilted > 0, "far from the lift some panels or letters are gone (%d) and some hang crooked (%d)" % [gone, tilted])
	t.check(reds_near > 100 and reds_far > 100, "the walk from the lift reaches the shader in the vertex colour (near %d, far %d vertices)" % [reds_near, reds_far])
	var code := (load("res://client/playroom_shade.gdshader") as Shader).code
	t.check(code.contains("if (mode < 0.5) {\n\t\tcorr = COLOR.r;"), "the shader bleaches mode 0 by the vertex colour's red")
	_free(floors)

## Near the lift at least this share of the walkways' wall faces carries something (a panel, a painted band or picture,
## letters, netting or a post, or the pale patch a gone panel leaves); far from it no more than this many bare faces
## run on along one wall.
const WALK_NEAR_SHARE := 0.85
const WALK_FAR_RUN := 2

## Every wall face of a walkway cell (corridor or landing; a door's jambs count, the lift's own wall and the landing do
## not): {key "level:cell:side" -> [level, cell, side, corruption]}.
static func walk_faces(lv: Level) -> Dictionary:
	var out := {}
	var lift := lv._lift_edge()
	for level in 2:
		for y in lv.H:
			for x in lv.W:
				var k := lv.kind(level, x, y)
				if k != "corridor" and k != "landing":
					continue
				if level == lv.landing.x and Vector2i(x, y) == Vector2i(lv.landing.y, lv.landing.z):
					continue
				for side in 4:
					var d := SIDES[side]
					var e := edge(lv, level, x, y, d)
					if e != "wall" and e != "door":
						continue
					var eid := Vector4i(0, x + 1 if d.x > 0 else x, y, 1) if d.x != 0 else Vector4i(1, x, y + 1 if d.y > 0 else y, 1)
					if level == lv.landing.x and eid == lift:
						continue
					out["%d:%s:%d" % [level, Vector2i(x, y), side]] = [level, Vector2i(x, y), side, lv.corruption(level, x, y)]
	return out

## What can be seen on a wall: panels, the painted band, pictures, letters, posts. A net in front of a bare wall is not.
const SEEN := ["band", "flatband", "paint", "letter", "post"]

## The faces that carry a piece of the dressing a player can see on the wall: the same keys. A pale patch where a panel
## is gone counts only beside a face along the same wall that has panels or the painted band.
static func dressed_faces(lv: Level) -> Dictionary:
	var out := {}
	var ghosts := {}
	var banded := {}
	for r: Dictionary in records(lv):
		var n: Vector3 = r.n
		if n == Vector3.ZERO:
			continue
		var side := SIDES.find(Vector2i(roundi(-n.x), roundi(-n.z)))
		var key := "%d:%s:%d" % [int(r.level), r.cell, side]
		var kind := str(r.kind)
		if kind in SEEN:
			out[key] = true
		if kind == "band" or kind == "flatband":
			banded[key] = true
		if kind == "ghost":
			ghosts[key] = [int(r.level), r.cell, side]
	for key: String in ghosts:
		var g: Array = ghosts[key]
		var step := Vector2i(absi(SIDES[g[2]].y), absi(SIDES[g[2]].x))
		for s: int in [-1, 0, 1]:
			if banded.has("%d:%s:%d" % [g[0], (g[1] as Vector2i) + step * s, g[2]]):
				out[key] = true
	return out

func test_the_walkways_are_dressed(t: T) -> void:
	var floors := _floors(t.quick)
	for f: Array in floors:
		var lv: Level = f[2]
		var walls := walk_faces(lv)
		var dressed := dressed_faces(lv)
		var near := 0
		var near_dressed := 0
		var far := 0
		var far_dressed := 0
		for key: String in walls:
			var c := float(walls[key][3])
			if c < 0.35:
				near += 1
				near_dressed += int(dressed.has(key))
			elif c > 0.5:
				far += 1
				far_dressed += int(dressed.has(key))
		# Far from the lift: the longest run of bare faces along one wall line (cells next to each other, the same side).
		var worst := 0
		var where := ""
		for key: String in walls:
			var w: Array = walls[key]
			if float(w[3]) <= 0.5 or dressed.has(key):
				continue
			var side: int = w[2]
			var step := Vector2i(absi(SIDES[side].y), absi(SIDES[side].x))
			var back := "%d:%s:%d" % [int(w[0]), (w[1] as Vector2i) - step, side]
			if walls.has(back) and not dressed.has(back) and float(walls[back][3]) > 0.5:
				continue
			var run := 0
			var c: Vector2i = w[1]
			while true:
				var k2 := "%d:%s:%d" % [int(w[0]), c, side]
				if not walls.has(k2) or dressed.has(k2) or float(walls[k2][3]) <= 0.5:
					break
				run += 1
				c += step
			if run > worst:
				worst = run
				where = key
		var share := float(near_dressed) / maxf(near, 1)
		# The upper storey's walkways on their own, with the same two limits.
		var up_near := 0
		var up_dressed := 0
		for key: String in walls:
			if int(walls[key][0]) == 1 and float(walls[key][3]) < 0.35:
				up_near += 1
				up_dressed += int(dressed.has(key))
		if up_near > 0:
			t.check(float(up_dressed) / up_near >= WALK_NEAR_SHARE, "%s: %d of %d upper walkway faces near the lift are dressed (at least %.0f%%)" % [f[0], up_dressed, up_near, WALK_NEAR_SHARE * 100.0])
		t.check(near > 50 and far > 50, "%s: walkway faces near the lift (%d) and far from it (%d)" % [f[0], near, far])
		t.check(share >= WALK_NEAR_SHARE, "%s: %d of %d walkway faces near the lift are dressed (%.0f%%, at least %.0f%%)" % [f[0], near_dressed, near, share * 100.0, WALK_NEAR_SHARE * 100.0])
		t.check(worst <= WALK_FAR_RUN, "%s: far from the lift the longest run of bare walkway faces is %d (at most %d), from %s" % [f[0], worst, WALK_FAR_RUN, where])
		var up_far := 0
		var up_far_dressed := 0
		for key: String in walls:
			if int(walls[key][0]) == 1 and float(walls[key][3]) > 0.5:
				up_far += 1
				up_far_dressed += int(dressed.has(key))
		# The upper storey's walkways mostly lie far from the lift: there too at least the near share of them carries
		# something a player can see (the longest bare run above already counts both storeys).
		t.check(up_far == 0 or float(up_far_dressed) / up_far >= WALK_NEAR_SHARE, "%s: %d of %d upper walkway faces far from the lift are dressed (at least %.0f%%)" % [f[0], up_far_dressed, up_far, WALK_NEAR_SHARE * 100.0])
		t.check(up_near + up_far > 50, "%s: upper walkway faces (%d)" % [f[0], up_near + up_far])
		t.note("%s: near %d/%d dressed, far %d/%d, longest bare run far %d; upper storey near %d/%d, far %d/%d" % [f[0], near_dressed, near, far_dressed, far, worst, up_dressed, up_near, up_far_dressed, up_far])
	_free(floors)

## The words in cut-out letters: every letter the font has, the word's own space kept, and from PLAY NICELY only letters
## gone or swapped; never a word about looking, hiding, counting, hearing or keeping quiet.
func test_the_words_say_nothing_about_the_rules(t: T) -> void:
	var banned: Array[String] = ["LOOK", "SEE", "EYE", "WATCH", "HIDE", "SEEK", "FIND", "COUNT", "QUIET", "HUSH", "HEAR", "STILL", "DARK", "TURN", "BEHIND", "RUN", "NOISE", "SH"]
	var bad := PackedStringArray()
	var right := "PLAY NICELY"
	for w: String in Dress.WORDS:
		if w.length() != right.length() or w[Dress.WORD_GAP] != " ":
			bad.append("%s: not the word's length or its space" % w)
		for word in w.split(" ", false):
			if word in banned:
				bad.append(w)
		for b in banned:
			if w.replace(" ", "").contains(b) and b.length() > 2:
				bad.append("%s holds %s" % [w, b])
		var have := Array(w.replace(" ", "").split(""))
		var want := Array(right.replace(" ", "").split(""))
		for ch: String in have:
			if not PixelFont.known(ch):
				bad.append("%s (%s)" % [w, ch])
			if not want.has(ch):
				bad.append("%s has a letter PLAY NICELY has not (%s)" % [w, ch])
			want.erase(ch)
	t.check(bad.is_empty(), "the words: %s" % ", ".join(bad))
	t.eq(Dress.WORDS[0], right, "near the lift the word is right")

## The atlas and the pieces fit the browser build: one 512 px texture drawn by code, and few meshes and vertices.
func test_the_dressing_fits_the_budget(t: T) -> void:
	var tex := Dress.atlas()
	t.check(tex.get_width() == 512 and tex.get_height() == 512, "one 512 px atlas")
	var lv := _built(Playroom.generate_playroom("la6-a", 4))
	var meshes := 0
	var verts := 0
	var empty := 0
	for c in lv.get_children():
		if c is MeshInstance3D and String(c.name).contains("_pld") and (c as MeshInstance3D).mesh.get_surface_count() == 0:
			empty += 1
		if c is MeshInstance3D and String(c.name).contains("_pld"):
			meshes += 1
			verts += ((c as MeshInstance3D).mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	# One mesh per 8 cells square and storey: at most 2 * ceil(W / 8) * ceil(H / 8), one draw call each.
	t.check(meshes > 0 and meshes <= 2 * ceili(lv.W / 8.0) * ceili(lv.H / 8.0), "merged into few meshes (%d, at most %d)" % [meshes, 2 * ceili(lv.W / 8.0) * ceili(lv.H / 8.0)])
	t.check(verts < 160000, "%d vertices added" % verts)
	t.eq(empty, 0, "no empty dressing meshes")
	t.note("la6-a: %d meshes, %d vertices" % [meshes, verts])
	lv.free()
