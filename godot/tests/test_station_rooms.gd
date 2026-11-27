extends RefCounted
## LA7: the Reactor's side rooms' own dressing (client/station_rooms.gd), looks only. Held here, headless, from the plan
## and the triangles drawn (not only the dressing's own notes):
##   - nothing added hides what the plan's own sight check says a player sees (standing or creeping eyes, every point of
##     a figure), in lines aimed through each piece and in a random spread;
##   - nothing reaches into walkable space: below HIGH_Y nothing stands more than 15 cm out from its wall's face, nothing
##     on the floor stands over 2 cm, and below HIGH_Y nothing on a wall comes near a doorway;
##   - every piece lies between its storey's floor and ceiling, inside its own room, and a room counts as dressed only by
##     pieces a player standing in it can see (the fault where pieces were drawn a storey up and still counted);
##   - every side room of every kind is dressed, rooms of different kinds differ, and each keeps a wall plain;
##   - nothing within 1 m of a fuse spot, the cabinet, the cassette's table, the time cards, the landing's hooks or a
##     body's place, nothing on a growth; a keep-out counts only in its own room (never through a wall);
##   - no light, nothing self-lit: the station's own materials, so the pieces go with its power;
##   - the same floor seed dresses the same, a mirrored plan gets the mirrored dressing, and the station's own dressing
##     is drawn exactly as before with this on or off;
##   - no word on a wall or a floor names the rules or what happened.

const T = preload("res://tests/t.gd")
const Station = preload("res://sim/station.gd")
const Floor = preload("res://sim/floor.gd")
const Sight = preload("res://sim/sight.gd")
const Hides = preload("res://sim/hides.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const Run = preload("res://sim/run.gd")
const Rooms = preload("res://client/station_rooms.gd")
const EyeHeight = preload("res://client/eye_height.gd")
const CD = preload("res://tests/test_clinic_dress.gd")

const S := 2.0
const LH := 3.2
const FIGURE: Array[float] = [0.05, 0.52, 1.1, 1.7, 2.6]
const FIGURE_QUICK: Array[float] = [0.05, 1.1, 2.6]
const BEYOND_QUICK: Array[float] = [0.15, 0.8, 3.0, 12.0]
const BEYOND: Array[float] = [0.15, 0.4, 0.8, 1.5, 3.0, 6.0, 12.0, 24.0]
## Words no sign may carry: the rules, the residents, the power, the fuse, what happened.
const BANNED: Array[String] = ["FUSE", "FUSES", "POWER", "MAINS", "CUT", "OUTAGE", "BODY", "BODIES", "DEAD", "CORPSE", "CRAWL", "CREEP",
	"GROWTH", "GROWTHS", "ROT", "SPORE", "SPORES", "INFECTED", "INFECTION", "TAPE", "CASSETTE", "LIGHT", "LIGHTS", "DARK", "LAMP",
	"EMERGENCY", "CABINET", "SOCKET", "HIDE", "RUN", "LOOK", "SEE", "SEEN", "WATCH", "BEHIND", "STILL", "MOVE", "WAKE", "HUNT", "NOISE",
	"QUIET", "SOUND", "DANGER", "WARNING", "HELP", "ESCAPE"]
## Pieces that are lettering (laid out unreversed in a mirrored plan, so their boxes match a mirror only roughly).
const LETTERING: Array[String] = ["room_name", "bay_letter", "bay_number"]

static func _level(fp: Floor.FloorPlan) -> Level:
	var level := Level.new()
	level.build(PlanDump.dump(fp, Run.car_geometry(fp)), fp.seed, fp)
	return level

static func _rooms(lv: Level) -> Node3D:
	var view: Node3D = lv.get_meta(&"station")
	return (view.get(&"dresser") as Node3D).get_node_or_null("StationRooms")

static func _records(lv: Level) -> Array:
	var r := _rooms(lv)
	return r.get(&"records") if r != null else []

## Floors checked: [name, plan, level]. Both mirror states are among them.
static func _floors(n: int, tag := "la7") -> Array:
	var out: Array = []
	for i in n:
		var fp := Station.generate_station("%s-%d" % [tag, i], 7)
		out.append(["seed %s-%d%s" % [tag, i, " (mirrored)" if bool(fp.station["mirrored"]) else ""], fp, _level(fp)])
	return out

static func _free(floors: Array) -> void:
	for f: Array in floors:
		(f[2] as Node).free()

## The room rectangle (world, metres) of room `id`.
static func _rect(lv: Level, id: int) -> Rect2:
	var r: Dictionary = lv.plan.rooms[id]
	return Rect2(float(r.x) * S, float(r.y) * S, float(r.w) * S, float(r.h) * S)

static func _room_of(lv: Level, x: float, z: float) -> int:
	var cx := floori(x / S)
	var cz := floori(z / S)
	if cx < 0 or cz < 0 or cx >= lv.W or cz >= lv.H:
		return -1
	return int(lv.room_at[0][cz * lv.W + cx])

## Every triangle the dressing drew, world space: [a, b, c, mesh name].
static func _tris(rooms: Node3D) -> Array:
	var out: Array = []
	for c in rooms.get_children():
		if not c is MeshInstance3D:
			continue
		var mi := c as MeshInstance3D
		var v: PackedVector3Array = mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		for k in range(0, v.size(), 3):
			out.append([mi.transform * v[k], mi.transform * v[k + 1], mi.transform * v[k + 2], mi.name])
	return out

## The four walls of a room (world): {n (into the room), line (the coordinate of its line along n), doors: [centre
## along the wall, as a world point]}.
static func _walls(lv: Level, id: int) -> Array[Dictionary]:
	var r: Dictionary = lv.plan.rooms[id]
	var x := int(r.x)
	var y := int(r.y)
	var w := int(r.w)
	var h := int(r.h)
	var vert: Array = lv.edges[0].vertical
	var hor: Array = lv.edges[0].horizontal
	var out: Array[Dictionary] = []
	var defs := [[Vector3.BACK, Vector3(0, 0, y * S)], [Vector3.LEFT, Vector3((x + w) * S, 0, 0)], [Vector3.FORWARD, Vector3(0, 0, (y + h) * S)], [Vector3.RIGHT, Vector3(x * S, 0, 0)]]
	for which in 4:
		var n: Vector3 = defs[which][0]
		var on: Vector3 = defs[which][1]
		var doors: Array[Vector3] = []
		if which == 0 or which == 2:
			var row := y if which == 0 else y + h
			for i in w:
				if hor[row * lv.W + x + i] != "wall":
					doors.append(Vector3((x + i + 0.5) * S, 0, row * S))
		else:
			var col := x + w if which == 1 else x
			for i in h:
				if vert[(y + i) * (lv.W + 1) + col] != "wall":
					doors.append(Vector3(col * S, 0, (y + i + 0.5) * S))
		out.append({"n": n, "line": on.dot(n), "doors": doors, "len": float(w if which % 2 == 0 else h) * S})
	return out

## Which wall of its room a record stands on (-1 for none).
static func _wall_of(walls: Array[Dictionary], rec: Dictionary) -> int:
	var n: Vector3 = rec.n
	if n == Vector3.ZERO:
		return -1
	for i in walls.size():
		if (walls[i].n as Vector3).is_equal_approx(n) and absf((rec.face as Vector3).dot(n) - (float(walls[i].line) + Rooms.WALL_HALF)) < 0.01:
			return i
	return -1

# --- 1. sight ---------------------------------------------------------------------------------------------

## For one floor: every line from a spot near a wall piece (as an eye or as a point of a figure) through a point of the
## piece to a spot beyond it, that the plan's sight check lets through and the drawn walls do not already stop. High
## pieces (wholly over HIGH_Y, above every point a line joins) and floor marks (under every point) are left to the
## spread below.
static func sight_faults(lv: Level, fp: Floor.FloorPlan, quick: bool) -> Dictionary:
	var foot: Array = [{}, {}]
	var sp: Array = CD.spots(lv, foot)
	var walls := CD.wall_boxes(lv)
	var faults := PackedStringArray()
	var tried := 0
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(fp.seed + ":la7")
	var eyes: Array[float] = [EyeHeight.STAND, EyeHeight.CREEP]
	var reach := 14.0
	for p: Dictionary in _records(lv):
		var box: AABB = p.aabb
		var n: Vector3 = p.n
		if n == Vector3.ZERO or box.position.y >= 2.6:
			continue
		var face: Vector3 = p.face
		var mid := box.get_center()
		var deep := 0.0
		for k in 8:
			deep = maxf(deep, (CD._corner(box, k) - face).dot(n))
		var front: Array = []
		var behind: Array = []
		for q: Vector2 in sp[0]:
			var dist := Vector2(q.x - mid.x, q.y - mid.z).length()
			var d := (Vector3(q.x, face.y, q.y) - face).dot(n)
			if dist >= reach:
				continue
			if d >= -0.08 and d < deep + 0.1:
				front.append(Vector3(q.x, 0, q.y))
			elif d < 0.0 and (d > -4.0 or dist < 3.0):
				behind.append(Vector3(q.x, 0, q.y))
		var cap := 10 if quick else 60
		while behind.size() > cap:
			behind.remove_at(rng.randi_range(0, behind.size() - 1))
		var near: Array = front + behind
		var qs: Array[Vector3] = [mid]
		for k: int in ([0, 6] if quick else [0, 3, 5, 6]):
			qs.append(mid.lerp(CD._corner(box, k), 0.7))
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
								if e0.y >= 0.05 and e0.y <= 2.6:
									ends.append(e0)
						elif absf(dir.y) > 1e-6:
							for he: float in eyes:
								var tt := (he - qp.y) / dir.y
								if tt > 0.0 and tt < 40.0:
									ends.append(qp + dir * tt)
						for yp in ends:
							if not CD.body_ok(lv, foot, 0, yp.x, yp.z):
								continue
							tried += 1
							var eye := xp if role == 0 else yp
							var fig := yp if role == 0 else xp
							if not Sight.has_line_of_sight(fp, CD._pt(eye), CD._pt(fig)):
								continue
							if not CD.seg_hits(eye, fig, box):
								continue
							var hidden := false
							for w in walls:
								if CD.seg_hits(eye, fig, w):
									hidden = true
									break
							if not hidden:
								faults.append("%s (room %d) %s cuts %s -> %s" % [p.kind, int(p.room), box, eye, fig])
	return {"faults": faults, "tried": tried}

func test_nothing_added_hides_what_the_plan_sees(t: T) -> void:
	var floors := _floors(1 if t.quick else 6, "la7-sight")
	for f: Array in floors:
		var t0 := Time.get_ticks_msec()
		var r := sight_faults(f[2], f[1], t.quick)
		var faults: PackedStringArray = r.faults
		t.check(int(r.tried) > 2000, "%s: lines tried past the side rooms' dressing (%d)" % [f[0], int(r.tried)])
		t.check(faults.is_empty(), "%s: %d lines the plan sees are cut by the dressing: %s" % [f[0], faults.size(), "; ".join(faults.slice(0, 4))])
		t.note("%s: %d pieces, %d lines tried, %d ms" % [f[0], _records(f[2]).size(), int(r.tried), Time.get_ticks_msec() - t0])
	_free(floors)

## A random spread of pairs of spots, one in a side room, that the plan's sight check lets see each other (standing and
## creeping eyes, every point of a figure): no piece between them, high and floor pieces included.
func test_a_spread_of_lines_the_plan_sees_is_never_cut(t: T) -> void:
	var floors := _floors(2 if t.quick else 8, "la7-spread")
	for f: Array in floors:
		var lv: Level = f[2]
		var fp: Floor.FloorPlan = f[1]
		var sp: Array = CD.spots(lv, [{}, {}])
		var side: Array[Vector3] = []
		var all: Array[Vector3] = []
		for q: Vector2 in sp[0]:
			var p := Vector3(q.x, 0, q.y)
			all.append(p)
			var id := _room_of(lv, q.x, q.y)
			if id >= 0 and Rooms.KINDS.has(str(lv.plan.rooms[id].kind)):
				side.append(p)
		var recs := _records(lv)
		var walls := CD.wall_boxes(lv)
		var rng := RandomNumberGenerator.new()
		rng.seed = hash("la7-spread:" + fp.seed)
		var seen := 0
		var cut := PackedStringArray()
		for i in (5000 if t.quick else 16000):
			var a := side[rng.randi_range(0, side.size() - 1)]
			var b := all[rng.randi_range(0, all.size() - 1)] if i % 3 == 0 else side[rng.randi_range(0, side.size() - 1)]
			if a.distance_to(b) > 30.0:
				continue
			var eye := a + Vector3(0, EyeHeight.STAND if i % 2 == 0 else EyeHeight.CREEP, 0)
			var fig := b + Vector3(0, FIGURE[i % FIGURE.size()], 0)
			if not Sight.has_line_of_sight(fp, CD._pt(eye), CD._pt(fig)):
				continue
			seen += 1
			var lo := eye.min(fig)
			var hi := eye.max(fig)
			for r: Dictionary in recs:
				var box: AABB = r.aabb
				if box.position.x > hi.x or box.end.x < lo.x or box.position.z > hi.z or box.end.z < lo.z or box.position.y > hi.y or box.end.y < lo.y:
					continue
				if CD.seg_hits(eye, fig, box):
					# A line the drawn walls already stop (a grazing line through a doorway meets its jamb) is not one a
					# piece can newly hide.
					var hidden := false
					for w in walls:
						if CD.seg_hits(eye, fig, w):
							hidden = true
							break
					if not hidden:
						cut.append("%s %s -> %s" % [r.kind, eye, fig])
		t.check(seen > 400, "%s: lines the plan sees from the side rooms (%d)" % [f[0], seen])
		t.check(cut.is_empty(), "%s: %d of them cut by the dressing: %s" % [f[0], cut.size(), "; ".join(cut.slice(0, 4))])
	_free(floors)

# --- 2. nothing in the walkable space -------------------------------------------------------------------------

## From the triangles: each is flat on the floor (at most 2 cm up), wholly over HIGH_Y, or within 15 cm of the face of
## a wall of the room it is in (and not buried in it). From the pieces: their kind of place holds, and below HIGH_Y
## nothing on a wall comes within DOOR_CLEAR of a doorway in that wall.
func test_nothing_stands_in_the_walkable_space(t: T) -> void:
	var floors := _floors(3 if t.quick else 10, "la7-space")
	for f: Array in floors:
		var lv: Level = f[2]
		var bad := PackedStringArray()
		var tris := _tris(_rooms(lv))
		var low := 0
		for tr: Array in tris:
			var a: Vector3 = tr[0]
			var b: Vector3 = tr[1]
			var c: Vector3 = tr[2]
			var y0 := minf(a.y, minf(b.y, c.y))
			var y1 := maxf(a.y, maxf(b.y, c.y))
			if y1 <= Rooms.FLOOR_MAX + 1e-4 or y0 >= Rooms.HIGH_Y - 1e-4:
				continue
			low += 1
			var m := (a + b + c) / 3.0
			var id := _room_of(lv, m.x, m.z)
			if id < 0:
				bad.append("a triangle at %s in no room" % m)
				continue
			var rr := _rect(lv, id)
			for p: Vector3 in [a, b, c, m]:
				var d := minf(minf(p.x - rr.position.x, rr.end.x - p.x), minf(p.z - rr.position.y, rr.end.y - p.z))
				if d - Rooms.WALL_HALF > Rooms.PROUD_MAX + 0.001:
					bad.append("a triangle at %s stands %.3f m off its wall at %.2f m" % [m, d - Rooms.WALL_HALF, p.y])
					break
				if d < Rooms.WALL_HALF - 0.003:
					bad.append("a triangle at %s is in its wall (%.3f m)" % [m, d])
					break
		for r: Dictionary in _records(lv):
			var box: AABB = r.aabb
			match str(r.zone):
				"high":
					if box.position.y < Rooms.HIGH_Y - 1e-4:
						bad.append("high %s hangs down to %.3f m" % [r.kind, box.position.y])
				"floor":
					if box.end.y > Rooms.FLOOR_MAX + 1e-4:
						bad.append("floor %s stands %.3f m" % [r.kind, box.end.y])
				"wall", "over_door":
					var walls := _walls(lv, int(r.room))
					var wi := _wall_of(walls, r)
					if wi < 0:
						bad.append("%s is on none of its room's walls" % r.kind)
						continue
					if str(r.zone) == "over_door":
						if box.position.y < Level.DOOR_H + 0.1:
							bad.append("%s over the door comes down to %.2f m" % [r.kind, box.position.y])
						continue
					var w: Dictionary = walls[wi]
					var along := Vector3(absf((w.n as Vector3).z), 0, absf((w.n as Vector3).x))
					for dc: Vector3 in w.doors:
						var lo := (box.position - dc).dot(along)
						var hi := (box.end - dc).dot(along)
						var gap := maxf(0.0, maxf(lo, -hi))
						if gap < Rooms.DOOR_CLEAR - 0.01:
							bad.append("%s is %.2f m along its wall from a doorway" % [r.kind, gap])
		t.check(low > 200, "%s: wall pieces below HIGH_Y were checked (%d triangles)" % [f[0], low])
		t.check(bad.is_empty(), "%s: %d: %s" % [f[0], bad.size(), "; ".join(bad.slice(0, 5))])
	_free(floors)

## The station has no hides, so nothing here may look like one; and nothing hung soft (a towel, a satchel, a helmet)
## comes near a person's size.
func test_no_hides_and_nothing_like_a_figure(t: T) -> void:
	var floors := _floors(3 if t.quick else 10, "la7-fig")
	for f: Array in floors:
		var lv: Level = f[2]
		t.check(Hides.hides_for(f[1]).is_empty() and lv.hides.is_empty(), "%s: the station has no hides" % f[0])
		var bad := PackedStringArray()
		for r: Dictionary in _records(lv):
			var box: AABB = r.aabb
			if str(r.kind) in ["towel", "satchel", "helmet_on_hook", "boots", "kit_bag"] and box.size.y > 0.6:
				bad.append("%s %.2f m tall" % [r.kind, box.size.y])
			for word: String in ["fuse", "cassette", "socket", "cabinet", "card", "body", "figure"]:
				if str(r.kind).contains(word):
					bad.append("a piece called %s" % r.kind)
			if str(r.kind) == "switch_box" and maxf(box.size.x, maxf(box.size.y, box.size.z)) > 0.2:
				bad.append("a switch box %s is larger than a switch box" % box.size)
		t.check(bad.is_empty(), "%s: %s" % [f[0], "; ".join(bad.slice(0, 5))])
	_free(floors)

# --- 3. in its own storey and room, and seen from there -----------------------------------------------------------

## Whether a player standing anywhere in the piece's room sees it: from a cell's middle at standing eye height, the line
## to the piece's middle passes no drawn wall.
static func visible(lv: Level, walls: Array[AABB], rec: Dictionary) -> bool:
	var r: Dictionary = lv.plan.rooms[int(rec.room)]
	var to := (rec.aabb as AABB).get_center() + (rec.n as Vector3) * 0.01
	if to.y < 0.0 or to.y > LH:
		return false
	for cy in range(int(r.y), int(r.y) + int(r.h)):
		for cx in range(int(r.x), int(r.x) + int(r.w)):
			var eye := Vector3((cx + 0.5) * S, EyeHeight.STAND, (cy + 0.5) * S)
			var clear := true
			for w in walls:
				if CD.seg_hits(eye, to, w):
					clear = false
					break
			if clear:
				return true
	return false

func test_every_piece_is_in_its_storey_and_its_room(t: T) -> void:
	var floors := _floors(3 if t.quick else 10, "la7-room")
	for f: Array in floors:
		var lv: Level = f[2]
		var bad := PackedStringArray()
		var recs := _records(lv)
		var by_room := {}
		for r: Dictionary in recs:
			var box: AABB = r.aabb
			var id := int(r.room)
			if not Rooms.KINDS.has(str(lv.plan.rooms[id].kind)) or int(lv.plan.rooms[id].get("level", 0)) != 0:
				bad.append("%s in room %d, not a side room" % [r.kind, id])
			if box.position.y < -0.001 or box.end.y > LH + 0.001:
				bad.append("%s from %.2f to %.2f m, out of its storey (0 to %.1f m)" % [r.kind, box.position.y, box.end.y, LH])
			var rr := _rect(lv, id).grow(0.001)
			if not rr.encloses(Rect2(box.position.x, box.position.z, box.size.x, box.size.z)):
				bad.append("%s at %s is out of its room %s" % [r.kind, box, rr])
			if not by_room.has(id):
				by_room[id] = []
			(by_room[id] as Array).append(r)
		# Every triangle drawn is inside a piece of the room it lies in: nothing drawn that the pieces do not account for.
		var loose := 0
		for tr: Array in _tris(_rooms(lv)):
			var m := ((tr[0] as Vector3) + (tr[1] as Vector3) + (tr[2] as Vector3)) / 3.0
			var id := _room_of(lv, m.x, m.z)
			var inside := false
			for r: Dictionary in by_room.get(id, []):
				var g := (r.aabb as AABB).grow(0.002)
				if g.has_point(tr[0]) and g.has_point(tr[1]) and g.has_point(tr[2]):
					inside = true
					break
			loose += int(not inside)
		t.check(not recs.is_empty(), "%s: pieces drawn (%d)" % [f[0], recs.size()])
		t.eq(loose, 0, "%s: every triangle lies in a piece of its own room" % f[0])
		t.check(bad.is_empty(), "%s: %d: %s" % [f[0], bad.size(), "; ".join(bad.slice(0, 5))])
	_free(floors)

## Every side room of every kind is dressed by pieces a player standing in it can see: high ones, ones on its walls, and
## (stores, office, pumps) marks on its floor; and two rooms of different kinds are dressed with different things.
func test_every_side_room_is_dressed_and_the_kinds_differ(t: T) -> void:
	var floors := _floors(4 if t.quick else 12, "la7-kinds")
	var kinds_seen := {}
	var sets := {}
	for f: Array in floors:
		var lv: Level = f[2]
		var walls := CD.wall_boxes(lv)
		var by_room := {}
		for r: Dictionary in _records(lv):
			if not visible(lv, walls, r):
				continue
			if not by_room.has(int(r.room)):
				by_room[int(r.room)] = {"high": 0, "wall": 0, "floor": 0, "kinds": {}}
			var d: Dictionary = by_room[int(r.room)]
			var z := "wall" if str(r.zone) == "over_door" else str(r.zone)
			d[z] = int(d[z]) + 1
			(d.kinds as Dictionary)[str(r.kind)] = true
		for room: Dictionary in lv.plan.rooms:
			var kind := str(room.kind)
			if not Rooms.KINDS.has(kind):
				continue
			kinds_seen[kind] = int(kinds_seen.get(kind, 0)) + 1
			var d: Dictionary = by_room.get(int(room.id), {"high": 0, "wall": 0, "floor": 0, "kinds": {}})
			var small := int(room.w) * int(room.h) <= 2
			var want := {"high": 1, "wall": 0 if kind == "closet" else 2, "floor": 1 if kind in ["stores", "office", "pumps"] and not small else 0}
			for z: String in want:
				t.check(int(d[z]) >= int(want[z]), "%s: %s room %d (%dx%d) has %d %s pieces seen from inside it (wants %d)" % [f[0], kind, int(room.id), int(room.w), int(room.h), int(d[z]), z, int(want[z])])
			if not sets.has(kind):
				sets[kind] = {}
			for k: String in d.kinds:
				sets[kind][k] = true
	for kind: String in Rooms.KINDS:
		t.check(int(kinds_seen.get(kind, 0)) > 0, "the floors checked have a %s room" % kind)
	# The things that make each kind (all rooms share a switch box, a conduit, a name, a rack).
	var shared := ["switch_box", "conduit", "room_name", "rack", "rack_plate"]
	var ks := sets.keys()
	for i in ks.size():
		for j in range(i + 1, ks.size()):
			var a: Dictionary = sets[ks[i]]
			var b: Dictionary = sets[ks[j]]
			var both := 0
			var either := 0
			for k: String in a.keys() + b.keys():
				if k in shared:
					continue
				either += 1
				both += int(a.has(k) and b.has(k))
			t.check(either > 0 and float(both) / float(either) < 0.25, "%s and %s rooms are dressed differently (%d of %d things shared)" % [ks[i], ks[j], both / 2, either])
	_free(floors)

## Each side room leaves at least one wall with nothing of this dressing on it.
func test_each_side_room_keeps_a_plain_wall(t: T) -> void:
	var floors := _floors(4 if t.quick else 12, "la7-plain")
	for f: Array in floors:
		var lv: Level = f[2]
		var on := {}
		for r: Dictionary in _records(lv):
			var walls := _walls(lv, int(r.room))
			var wi := _wall_of(walls, r)
			if wi >= 0:
				on["%d:%d" % [int(r.room), wi]] = true
		for room: Dictionary in lv.plan.rooms:
			if not Rooms.KINDS.has(str(room.kind)):
				continue
			var plain := 0
			for wi in 4:
				plain += int(not on.has("%d:%d" % [int(room.id), wi]))
			t.check(plain >= 1, "%s: %s room %d keeps a plain wall (%d plain)" % [f[0], room.kind, int(room.id), plain])
	_free(floors)

# --- 4. keep clear -----------------------------------------------------------------------------------------------

## The points nothing comes near: every fuse spot, the cabinet, the cassette's table, the cards, the hooks, the bodies.
static func keep_points(fp: Floor.FloorPlan) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var a := fp.station
	for key: String in ["plinth", "cabinet"]:
		out.append(View3.v3(a.get(key)))
	for key: String in ["fuse_spots", "lockers", "time_cards", "bodies"]:
		for d: Variant in a.get(key, []):
			out.append(View3.v3(d))
	return out

const View3 = preload("res://client/station_point.gd")

func test_nothing_near_a_fuse_spot_or_the_named_places(t: T) -> void:
	var floors := _floors(4 if t.quick else 12, "la7-keep")
	var across := 0
	for f: Array in floors:
		var lv: Level = f[2]
		var fp: Floor.FloorPlan = f[1]
		var keeps := keep_points(fp)
		var rooms := _rooms(lv)
		var dresser: Node3D = (lv.get_meta(&"station") as Node3D).get(&"dresser")
		var roots: Array[Vector3] = []
		for c: Dictionary in dresser.get(&"clusters"):
			roots.append(c["at"])
		var bad := PackedStringArray()
		var tested := 0
		for r: Dictionary in _records(lv):
			var box: AABB = r.aabb
			for p: Vector3 in keeps + roots:
				var dx := maxf(0.0, maxf(box.position.x - p.x, p.x - box.end.x))
				var dz := maxf(0.0, maxf(box.position.z - p.z, p.z - box.end.z))
				var dist := sqrt(dx * dx + dz * dz)
				var same := _room_of(lv, p.x, p.z) == int(r.room)
				tested += 1
				if same and dist < Rooms.KEEP - 0.001:
					bad.append("%s %.2f m from %s" % [r.kind, dist, p])
				elif not same and dist < Rooms.KEEP and (fp.station["fuse_spots"] as Array).has(p):
					across += 1
		# A keep-out is its own room's only: each fuse spot counts in exactly the room it lies in.
		for p: Vector3 in fp.station["fuse_spots"]:
			var in_rooms := 0
			for room: Dictionary in lv.plan.rooms:
				var cx := lv.W - int(room.x) - int(room.w) if bool(fp.station["mirrored"]) else int(room.x)
				var cr := Rect2(float(cx) * S, float(room.y) * S, float(room.w) * S, float(room.h) * S)
				var got: Array = rooms.call(&"_room_keeps", cr)
				var cp := Vector3(lv.W * S - p.x, p.y, p.z) if bool(fp.station["mirrored"]) else p
				in_rooms += int(got.has(cp))
			t.eq(in_rooms, 1, "%s: the fuse spot %s keeps clear only the room it is in" % [f[0], p])
		t.check(tested > 1000, "%s: pieces against the named places (%d)" % [f[0], tested])
		t.check(bad.is_empty(), "%s: %d: %s" % [f[0], bad.size(), "; ".join(bad.slice(0, 5))])
	t.check(across > 0, "pieces stand within 1 m of a fuse spot on the far side of a wall (%d): a keep-out does not reach through a wall" % across)
	_free(floors)

# --- 5. light and power --------------------------------------------------------------------------------------------

func test_no_light_nothing_self_lit_and_the_pieces_go_with_the_power(t: T) -> void:
	for sd: String in ["la7-power-0", "la7-power-1"]:
		var fp := Station.generate_station(sd, 7)
		var lv := _level(fp)
		var view: Node3D = lv.get_meta(&"station")
		var dresser: Node3D = view.get(&"dresser")
		var rooms := _rooms(lv)
		var allowed: Array = [view.get(&"mat_props"), (dresser.get(&"_mats") as Dictionary)["steel"]]
		var lights := 0
		var bad := PackedStringArray()
		var meshes: Array[MeshInstance3D] = []
		var stack: Array[Node] = [rooms]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			for c in n.get_children():
				stack.append(c)
			if n is Light3D:
				lights += 1
			if n is MeshInstance3D:
				meshes.append(n)
			elif n is GeometryInstance3D:
				bad.append("%s is drawn some other way" % n.name)
		for mi in meshes:
			var m: Material = mi.material_override
			if not allowed.has(m):
				bad.append("%s has its own material" % mi.name)
				continue
			var sm := m as ShaderMaterial
			if sm.shader.resource_path != "res://client/prop.gdshader" or float(sm.get_shader_parameter("emit")) != 0.0:
				bad.append("%s glows" % mi.name)
			if mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF or mi.get_child_count() > 0:
				bad.append("%s casts a shadow or has something under it" % mi.name)
		t.eq(lights, 0, "%s: no light added" % sd)
		t.check(not meshes.is_empty() and meshes.size() <= 8, "%s: few meshes (%d)" % [sd, meshes.size()])
		t.check(bad.is_empty(), "%s: %s" % [sd, "; ".join(bad.slice(0, 4))])
		# The landing's props use the same flat material: the pieces are lit by the station's own lamps as they are.
		var shared := false
		for c in lv.get_children():
			if c is MeshInstance3D and String(c.name).ends_with("_sprops"):
				shared = shared or (c as MeshInstance3D).material_override == view.get(&"mat_props")
		t.check(shared, "%s: the flat pieces share the landing props' material" % sd)
		# In the cut the station's lights go out and nothing of this is left lit.
		var before := PackedStringArray()
		for m: ShaderMaterial in allowed:
			before.append("%s %s %s" % [m.get_shader_parameter("albedo"), m.get_shader_parameter("emit"), m.get_shader_parameter("use_vcol")])
		view.call(&"set_power", 1)
		view.call(&"_apply")
		var after := PackedStringArray()
		for m: ShaderMaterial in allowed:
			after.append("%s %s %s" % [m.get_shader_parameter("albedo"), m.get_shader_parameter("emit"), m.get_shader_parameter("use_vcol")])
		t.eq(after, before, "%s: in the cut the pieces' materials are unchanged and still unlit by themselves" % sd)
		t.eq(int((view.call(&"lights") as Dictionary)["battensOn"]), 0, "%s: in the cut the battens are out" % sd)
		lv.free()

# --- 6. the same from the seed, mirrored with the plan, and the station's own dressing untouched ------------------

static func _mesh_sigs(rooms: Node3D) -> PackedStringArray:
	var out := PackedStringArray()
	for c in rooms.get_children():
		if c is MeshInstance3D:
			out.append("%s:%s" % [c.name, str((c as MeshInstance3D).mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]).md5_text()])
	return out

func test_the_same_seed_dresses_the_same_and_a_mirror_mirrors(t: T) -> void:
	var a := _level(Station.generate_station("la7-same", 7))
	var b := _level(Station.generate_station("la7-same", 7))
	var c := _level(Station.generate_station("la7-other", 7))
	t.check(_mesh_sigs(_rooms(a)).size() >= 2 and _mesh_sigs(_rooms(a)) == _mesh_sigs(_rooms(b)), "two builds of one floor seed draw identical dressing")
	t.eq(str(_records(a)), str(_records(b)), "and the same pieces")
	t.check(str(_records(c)) != str(_records(a)), "another seed dresses differently")
	for l: Level in [a, b, c]:
		l.free()
	# A plan and the same plan mirrored by hand: the dressing of one is the mirror of the other's.
	var tried := 0
	var i := 0
	while tried < (2 if t.quick else 5) and i < 40:
		var sd := "la7-mirror-%d" % i
		i += 1
		var fp := Station.generate_station(sd, 7)
		if bool(fp.station["mirrored"]):
			continue
		tried += 1
		var fm := Station.generate_station(sd, 7)
		Station._mirror(fm, fm.station)
		fm = fm.copy()   # fresh caches: the plan keeps its wall tables from before the mirror otherwise
		var wm := float(fm.width) * S
		var spots: Array = []
		for p: Vector3 in fm.station["fuse_spots"]:
			spots.append(Vector3(wm - p.x, p.y, p.z))
		fm.station["fuse_spots"] = spots
		fm.station["mirrored"] = true
		var la := _level(fp)
		var lb := _level(fm)
		var ra := _records(la)
		var rb := _records(lb)
		t.eq(rb.size(), ra.size(), "%s: the mirrored plan has as many pieces" % sd)
		var used := {}
		var missing := PackedStringArray()
		for r: Dictionary in ra:
			var box: AABB = r.aabb
			var want := AABB(Vector3(wm - box.end.x, box.position.y, box.position.z), box.size)
			var tol := 0.08 if str(r.kind) in LETTERING else 0.004
			var found := false
			for k in rb.size():
				if used.has(k):
					continue
				var o: Dictionary = rb[k]
				if o.kind != r.kind or int(o.room) != int(r.room) or int(o.which) != int(r.which):
					continue
				var ob: AABB = o.aabb
				var dp := (ob.position - want.position).abs()
				var de := (ob.end - want.end).abs()
				if maxf(dp.x, maxf(dp.y, dp.z)) <= tol and maxf(de.x, maxf(de.y, de.z)) <= tol:
					used[k] = true
					found = true
					break
			if not found:
				missing.append("%s in room %d at %s" % [r.kind, int(r.room), want])
		t.check(missing.is_empty(), "%s: every piece has its mirror in the mirrored plan (%d missing: %s)" % [sd, missing.size(), "; ".join(missing.slice(0, 3))])
		la.free()
		lb.free()
	t.check(tried > 0, "plans that are not mirrored were found to mirror")

## Every node of the floor but this dressing's, as text, in no particular order.
static func _floor_sigs(lv: Level) -> PackedStringArray:
	var out := PackedStringArray()
	var stack: Array[Node] = [lv]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.name == &"StationRooms":
			continue
		for c in n.get_children():
			stack.append(c)
		var nm := "" if String(n.name).begins_with("@") else String(n.name)
		var s := "%s %s" % [n.get_class(), nm]
		if n is Node3D:
			s += " %s" % (n as Node3D).transform
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var m: Mesh = (n as MeshInstance3D).mesh
			s += " %s %d" % [m.get_aabb(), m.get_surface_count()]
			if m is ArrayMesh and m.get_surface_count() > 0:
				s += " " + str(m.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]).md5_text()
		if n is Label3D:
			s += " " + (n as Label3D).text
		if n is Light3D:
			s += " %.4f %s" % [(n as Light3D).light_energy, (n as Light3D).light_color]
		out.append(s)
	out.sort()
	return out

func test_the_station_dressing_is_drawn_as_before_with_this_on_or_off(t: T) -> void:
	for sd: String in (["la7-same-0"] if t.quick else ["la7-same-0", "la7-same-1", "la7-same-2"]):
		var fp := Station.generate_station(sd, 7)
		Rooms.off = true
		var bare := _level(fp)
		Rooms.off = false
		var on := _level(fp)
		t.check(_rooms(bare) == null and _rooms(on) != null, "%s: the side rooms' dressing is off, then on" % sd)
		var sa := _floor_sigs(bare)
		var sb := _floor_sigs(on)
		var diff := PackedStringArray()
		for s in sb:
			if not sa.has(s):
				diff.append(s)
		t.check(sa == sb, "%s: every other node of the floor is the same with and without it (%d differ: %s)" % [sd, diff.size(), "; ".join(diff.slice(0, 3))])
		var da: Node3D = (bare.get_meta(&"station") as Node3D).get(&"dresser")
		var db: Node3D = (on.get_meta(&"station") as Node3D).get(&"dresser")
		t.eq((db.get(&"_rng") as RandomNumberGenerator).state, (da.get(&"_rng") as RandomNumberGenerator).state, "%s: the station's own generator made the same draws" % sd)
		t.eq(str(db.get(&"clusters")), str(da.get(&"clusters")), "%s: the growths are where they were" % sd)
		t.eq(str(db.get(&"segments")), str(da.get(&"segments")), "%s: the pipe runs are where they were" % sd)
		bare.free()
		on.free()

# --- 7. words ---------------------------------------------------------------------------------------------------

func test_no_word_names_the_rules_or_what_happened(t: T) -> void:
	var bad := PackedStringArray()
	for s: String in Rooms.texts():
		for w in s.split(" ", false):
			if w in BANNED:
				bad.append(s)
		for i in s.length():
			if not PixelFont.known(s[i]):
				bad.append("%s (%s)" % [s, s[i]])
	t.check(bad.is_empty(), "the dressing's words: %s" % ", ".join(bad))
	var floors := _floors(3, "la7-words")
	var drawn := {}
	for f: Array in floors:
		for w: String in (_rooms(f[2]).get(&"words") as PackedStringArray):
			drawn[w] = true
			t.check(Rooms.texts().has(w), "%s: %s is one of the dressing's words" % [f[0], w])
	t.check(drawn.has("STORES") and drawn.size() >= 5, "words are drawn (%s)" % ", ".join(PackedStringArray(drawn.keys())))
	_free(floors)

# --- 8. size ------------------------------------------------------------------------------------------------------

func test_the_dressing_stays_small(t: T) -> void:
	var worst_tris := 0
	var worst_meshes := 0
	for i in (3 if t.quick else 8):
		var fp := Station.generate_station("la7-size-%d" % i, 7)
		Rooms.off = true
		var t0 := Time.get_ticks_usec()
		var bare := _level(fp)
		var t_off := Time.get_ticks_usec() - t0
		Rooms.off = false
		t0 = Time.get_ticks_usec()
		var lv := _level(fp)
		var t_on := Time.get_ticks_usec() - t0
		var ck: Dictionary = _rooms(lv).call(&"check")
		worst_tris = maxi(worst_tris, int(ck.tris))
		worst_meshes = maxi(worst_meshes, int(ck.meshes))
		t.note("%s: %d pieces, %d meshes, %d triangles (%d vertices); built in %.0f ms (%.0f ms without)" % [fp.seed, int(ck.pieces), int(ck.meshes), int(ck.tris), int(ck.tris) * 3, t_on / 1000.0, t_off / 1000.0])
		bare.free()
		lv.free()
	t.check(worst_tris <= 14000, "at most 14,000 triangles added on a floor (%d)" % worst_tris)
	t.check(worst_meshes <= 6, "at most 6 meshes added on a floor (%d)" % worst_meshes)
