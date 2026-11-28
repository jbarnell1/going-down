# CAM1 (North Star F3: "A downed player watches the building's security cameras. Only some rooms have one, the feeds
# cycle, and the picture is too grainy to read a sign or a face."): where a floor's security cameras hang. Pure and
# read-only over the floor plan: the same list on the host, on every screen and in every test, from the plan alone
# (its seed and depth). It takes no draw from any generator a floor already uses: the one choice it makes (which rooms)
# comes from its own generator, Rng "cameras:<seed>:<depth>". Nothing here is a rule: no resident, no sight rule and no
# recorded result reads it.
#
# A camera: {"n" its number on the floor (1 up), "kind" (landing, room, corridor, garden, ward), "level", "pos" the
# lens (world metres), "anchor" where its arm meets the wall or post, "aim" the point it looks at, "yaw" and "pitch"
# (the scene camera's: yaw 0 faces -z, positive pitch looks up), "area" its plain name ("EAST CORRIDOR")}.
#
# Where they hang (plans with cells: the Clinic, the Annex, the Playroom, the Arboretum, the Reactor):
#  - The lift landing, always, CAM 1: high on the far wall of the space the car opens into, looking back at the car's
#    doors; where that wall is out of reach or blocked, high over the car's doors, looking out.
#  - Some rooms (a share of the floor's rooms, at least one a level, the bigger ones likelier): high in one corner of
#    the room whose two walls are both solid, looking across the room to its middle.
#  - A few of the longest corridors: high on the wall at one end, looking down the run.
#  - The Arboretum's garden: on some of its landmarks' lamp posts, a little below the lamp, looking at the landmark.
#  - Every spot is MOUNT_H over its floor, at least INSET from every wall face, outside every piece of furniture and
#    every hide (sim/furniture.gd, sim/hides.gd footprints, with SPARE), and on a cell that is floor.
# The Hanging Ward (no cells; sim/ward/state.gd's houses): for_ward. The lift, CAM 1, in the parlour looking at the
# lift's door; then some houses, each high on its front wall outside, looking along its front and its door.
extends RefCounted

@warning_ignore_start("integer_division")

const Floor = preload("res://sim/floor.gd")
const Walls = preload("res://sim/walls.gd")
const Landing = preload("res://sim/landing.gd")
const Sight = preload("res://sim/sight.gd")
const Rng = preload("res://sim/rng.gd")
const Furniture = preload("res://sim/furniture.gd")
const Hides = preload("res://sim/hides.gd")
const Playroom = preload("res://sim/playroom.gd")
const Arboretum = preload("res://sim/arboretum.gd")

## The storey height (sim/move.gd LEVEL_HEIGHT) and how high a camera hangs over its floor.
const LH := 3.2
const MOUNT_H := 2.7
## On a lamp post (the Arboretum): below the lamp's head (2.75 m, client/arboretum_view.gd), out from the post.
const POST_H := 2.3
const POST_OUT := 0.24
## From a cell's middle to the lens: the wall face is 0.93 m out (walls are drawn 0.14 m thick), the lens 0.25 m in.
const CORNER := 0.68
## The least gap from the lens to a wall line (metres), and around furniture and hides (cm).
const INSET := 0.2
const SPARE := 12
## The Playroom's hides have no footprint on the plan: this far round their inside spot is kept clear (cm).
const PLAYROOM_HIDE_R := 120
## Rooms that get no camera: too small or too low to hang one.
const NO_CAMERA: Array[StringName] = [&"closet", &"crawl", &"cloak"]
## The share of the floor's other rooms that have a camera, and the bounds on how many.
const ROOM_SHARE := 0.3
const MIN_ROOMS := 2
const MAX_ROOMS := 9
## Corridors: one per this many sightlines, between these.
const PER_SIGHTLINES := 6
const MAX_CORRIDORS := 3
## The Arboretum's lamp posts with a camera.
const MAX_POSTS := 5
## Two cameras are at least this far apart (metres), so no room has two.
const APART := 3.0
## Where a camera looks: this high over the floor at the place it looks at.
const AIM_H := 0.9

## The plain names of the rooms, by place and kind (never a resident's name or rule).
const ROOM_NAMES := {
	&"lobby": "LIFT LOBBY", &"atrium": "ATRIUM", &"ward": "WARD", &"exam": "EXAM ROOM", &"station": "NURSES' STATION",
	&"office": "OFFICE", &"cubicles": "OPEN PLAN", &"copy": "COPY ROOM", &"store": "STORE ROOM", &"meeting": "MEETING ROOM",
	&"break": "BREAK ROOM", &"party": "PARTY ROOM", &"den": "PLAY DEN", &"ballpit": "BALL PIT", &"toddler": "TODDLER ROOM",
	&"deck": "PLAY DECK", &"nook": "NOOK", &"hall": "MACHINE HALL", &"gallery": "GALLERY", &"switch": "SWITCH ROOM",
	&"stores": "STORES", &"greenhouse": "GREENHOUSE", &"bandstand": "BANDSTAND", &"sheds": "POTTING SHEDS",
	&"lodge": "KEEPER'S LODGE", &"fountain": "FOUNTAIN", &"statue": "STATUE", &"arch": "ARCH", &"sundial": "SUNDIAL",
	&"pond": "POND",
}

## The tests' deliberate breaks (tests/test_cameras.gd): "inset" hangs room cameras on the wall line itself;
## "engine" chooses rooms with the engine's own randomness.
static var test_break := ""

## THE cameras of a floor plan (see the header). `pieces`: the floor's furniture (sim/furniture.gd pieces_for) when the
## caller holds it; [] to make it here. The prison and the practice floor have none.
static func for_plan(plan: Floor.FloorPlan, pieces: Array = []) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if plan == null or plan.place == &"prison" or plan.place == &"orientation":
		return out
	var blocks := _blocks(plan, pieces)
	var rng := Rng.make_rng("cameras:%s:%d" % [plan.seed, plan.depth])
	var land := _landing(plan, blocks)
	if not land.is_empty():
		out.append(land)
	if plan.place == &"arboretum":
		for c in _posts(plan, blocks, rng):
			_take(out, c)
	for c in _rooms(plan, blocks, rng, out):
		_take(out, c)
	for c in _corridors(plan, blocks):
		_take(out, c, true)
	if out.size() < 2:
		for c in _any_corners(plan, blocks):
			_take(out, c)
			if out.size() >= 2:
				break
	# Numbered: the landing first, then by level, row and column.
	var rest := out.slice(1)
	rest.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var pa: Vector3 = a["pos"]
		var pb: Vector3 = b["pos"]
		if int(a["level"]) != int(b["level"]):
			return int(a["level"]) < int(b["level"])
		if absf(pa.z - pb.z) > 0.01:
			return pa.z < pb.z
		return pa.x < pb.x)
	var numbered: Array[Dictionary] = []
	if not out.is_empty():
		numbered.append(out[0])
	numbered.append_array(rest)
	for i in numbered.size():
		numbered[i]["n"] = i + 1
	return numbered

## The caption's camera words: "CAM 3  FLOOR 2  EAST CORRIDOR".
static func caption(cam: Dictionary, depth: int) -> String:
	return "CAM %d  FLOOR %d  %s" % [int(cam["n"]), depth, str(cam["area"])]

## Whether camera `cam` shows a point `at` (feet, world metres) on `level` of `plan`: within FAR, inside the picture
## (H_HALF and V_HALF degrees either side of its aim), and in plain view of the lens past the plan's walls (the rules'
## own line of sight, sim/sight.gd). The Ward has no plan: `plan` null and `ray` a Callable(from, to) -> bool that says
## the way is clear.
const FAR := 12.0
## Inside the feed's picture (client/cam_feed.gd FOV 62 degrees high, 16:9), a little in from its edges.
const H_HALF := 44.0
const V_HALF := 29.0
## A figure is shown when its head (this high over its feet) is in plain view: past the plan's walls and past every
## floor-standing piece of furniture and hide (sim/furniture.gd footprints, TALL_H high when the piece is tall, LOW_H
## otherwise; the Playroom's hides PLAYROOM_HIDE_H), the floor's dressing that stands between a lens and the floor.
const HEAD := 1.55
const TALL_H := 2.1
const LOW_H := 1.05
const PLAYROOM_HIDE_H := 2.3
static func shows(plan: Floor.FloorPlan, cam: Dictionary, at: Vector3, level: int, ray: Callable = Callable()) -> bool:
	if plan != null and int(cam["level"]) != level and absf(at.y - float(cam["pos"].y)) > LH:
		return false
	var pos: Vector3 = cam["pos"]
	var chest := at + Vector3(0, 1.1, 0)
	var d := chest - pos
	if d.length() > FAR or d.length() < 0.3:
		return false
	var fwd := _dir(float(cam["yaw"]), float(cam["pitch"]))
	var flat_f := Vector2(fwd.x, fwd.z).normalized()
	var flat_d := Vector2(d.x, d.z)
	if flat_d.length() < 0.01:
		return false
	var h := rad_to_deg(absf(flat_f.angle_to(flat_d.normalized())))
	if h > H_HALF:
		return false
	var v := rad_to_deg(absf(atan2(d.y, flat_d.length()) - float(cam["pitch"])))
	if v > V_HALF:
		return false
	if plan != null:
		var head := at + Vector3(0, HEAD, 0)
		if not Sight.has_line_of_sight(plan, Sight.Point3.make(pos.x, pos.y, pos.z, int(cam["level"])), Sight.Point3.make(head.x, head.y, head.z, level)):
			return false
		return test_break == "dressing" or not dressing_blocks(plan, level, pos, head)
	return not ray.is_valid() or bool(ray.call(pos, chest))

## Whether the floor's furniture (see HEAD) stands across the straight line from `a` to `b` on `level`.
static func dressing_blocks(plan: Floor.FloorPlan, level: int, a: Vector3, b: Vector3) -> bool:
	for box: AABB in solids(plan)[clampi(level, 0, 1)]:
		if box.intersects_segment(a, b):
			return true
	return false

## The floor's furniture as boxes (world metres), by level; made once per plan (the last plan asked).
static var _solids_plan: Floor.FloorPlan = null
static var _solids: Array = [[], []]
static func solids(plan: Floor.FloorPlan) -> Array:
	if plan == _solids_plan:
		return _solids
	var out: Array = [[], []]
	if plan.place != &"prison" and plan.place != &"orientation":
		for p in Furniture.pieces_for(plan, plan.seed, plan.depth, true):
			var f: Rect2i = p.foot
			var h := TALL_H if p.tall else LOW_H
			out[clampi(p.level, 0, 1)].append(AABB(Vector3(f.position.x / 100.0, p.level * LH, f.position.y / 100.0), Vector3(f.size.x / 100.0, h, f.size.y / 100.0)))
		if plan.place == &"playroom":
			for hd: Playroom.Hide in Hides.hides_for(plan, plan.seed):
				var r := PLAYROOM_HIDE_R / 100.0
				out[clampi(hd.level, 0, 1)].append(AABB(Vector3(hd.inside.x / 100.0 - r, hd.level * LH, hd.inside.y / 100.0 - r), Vector3(r * 2.0, PLAYROOM_HIDE_H, r * 2.0)))
	_solids_plan = plan
	_solids = out
	return out

## The way a yaw and pitch look (yaw 0 faces -z; the scene camera's rotation).
static func _dir(yaw: float, pitch: float) -> Vector3:
	return Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))

static func _look(from: Vector3, to: Vector3) -> Vector2:
	var d := to - from
	return Vector2(atan2(-d.x, -d.z), atan2(d.y, Vector2(d.x, d.z).length()))

static func _make(kind: StringName, level: int, pos: Vector3, anchor: Vector3, aim: Vector3, area: String) -> Dictionary:
	var l := _look(pos, aim)
	return {"n": 0, "kind": kind, "level": level, "pos": pos, "anchor": anchor, "aim": aim, "yaw": l.x, "pitch": l.y, "area": area}

## Adds `c` unless one already hangs within APART of it (or `c` is empty).
static func _take(out: Array[Dictionary], c: Dictionary, corridor := false) -> void:
	if c.is_empty():
		return
	for o in out:
		if int(o["level"]) == int(c["level"]) and (o["pos"] as Vector3).distance_to(c["pos"]) < (APART * 2.0 if corridor else APART):
			return
	out.append(c)

# --- what a lens must keep clear of -----------------------------------------------------------------

## The footprints (cm, by level) of the floor's furniture and hides, grown by SPARE.
static func _blocks(plan: Floor.FloorPlan, pieces: Array) -> Array:
	var by_level: Array = [[], []]
	var list: Array = pieces if not pieces.is_empty() else Furniture.pieces_for(plan, plan.seed, plan.depth, true)
	for p: Variant in list:
		var f: Rect2i = p.foot
		by_level[clampi(int(p.level), 0, 1)].append(f.grow(SPARE))
	if plan.place == &"playroom":
		for h: Playroom.Hide in Hides.hides_for(plan, plan.seed):
			var r := PLAYROOM_HIDE_R
			by_level[clampi(h.level, 0, 1)].append(Rect2i(h.inside.x - r, h.inside.y - r, r * 2, r * 2))
	return by_level

## Whether a lens at `pos` on `level` is clear: on a floor cell, INSET from every wall line, outside every footprint.
static func lens_clear(plan: Floor.FloorPlan, blocks: Array, level: int, pos: Vector3) -> bool:
	var cs := float(plan.cell_size)
	var cx := int(floor(pos.x / cs))
	var cy := int(floor(pos.z / cs))
	var k := Floor.cell_at(plan, level, cx, cy)
	if k != Floor.ROOM and k != Floor.CORRIDOR and k != Floor.LANDING:
		return false
	var segs := Walls.segments_near(plan, level, cx, cy)
	var p := Vector2(pos.x, pos.z)
	for i in range(0, segs.size(), 4):
		if Geometry2D.get_closest_point_to_segment(p, Vector2(segs[i], segs[i + 1]), Vector2(segs[i + 2], segs[i + 3])).distance_to(p) < INSET:
			return false
	var cm := Vector2i(roundi(pos.x * 100.0), roundi(pos.z * 100.0))
	for r: Rect2i in blocks[clampi(level, 0, 1)]:
		if r.has_point(cm):
			return false
	return true

static func _centre(plan: Floor.FloorPlan, level: int, x: int, y: int) -> Vector3:
	var cs := float(plan.cell_size)
	return Vector3((x + 0.5) * cs, level * LH, (y + 0.5) * cs)

static func _solid(plan: Floor.FloorPlan, level: int, x: int, y: int, dx: int, dy: int) -> bool:
	return Walls.edge_kind(plan, level, x, y, x + dx, y + dy) == Walls.WALL

# --- names ----------------------------------------------------------------------------------------------

## "EAST", "NORTH", ... : where a point is on the floor, by the larger way from its middle (north is -z).
static func compass(plan: Floor.FloorPlan, pos: Vector3) -> String:
	var mx := plan.width * plan.cell_size * 0.5
	var mz := plan.height * plan.cell_size * 0.5
	var dx := pos.x - mx
	var dz := pos.z - mz
	if absf(dx) >= absf(dz):
		return "EAST" if dx > 0.0 else "WEST"
	return "SOUTH" if dz > 0.0 else "NORTH"

static func _area(plan: Floor.FloorPlan, level: int, pos: Vector3, what: String) -> String:
	return "%s%s %s" % ["UPPER " if level == 1 else "", compass(plan, pos), what]

# --- the landing ------------------------------------------------------------------------------------------

static func _landing(plan: Floor.FloorPlan, blocks: Array) -> Dictionary:
	var l := plan.landing
	var e := Landing.elevator_wall(plan)
	if e == &"":
		e = &"n"
	var ex := Floor.dir_dx(e)
	var ey := Floor.dir_dy(e)
	var doors := _centre(plan, l.level, l.x, l.y) + Vector3(ex, 0, ey) * 0.9 + Vector3(0, 1.3, 0)
	# Across the space the car opens into, to its far wall.
	var fx := -ex
	var fy := -ey
	var x := l.x
	var y := l.y
	var steps := 0
	while steps < 6 and Walls.edge_kind(plan, l.level, x, y, x + fx, y + fy) == Walls.OPEN and Floor.is_walkable(plan, l.level, x + fx, y + fy):
		x += fx
		y += fy
		steps += 1
	var beyond := Walls.edge_kind(plan, l.level, x, y, x + fx, y + fy)
	if steps >= 2 and (beyond == Walls.WALL or beyond == Walls.DOOR):
		var side := Vector3(-fy, 0, fx)
		for shift: float in [0.0, 0.5, -0.5]:
			var pos := _centre(plan, l.level, x, y) + Vector3(fx, 0, fy) * CORNER + side * shift + Vector3(0, MOUNT_H, 0)
			if lens_clear(plan, blocks, l.level, pos) and Sight.has_line_of_sight(plan, Sight.Point3.make(pos.x, pos.y, pos.z, l.level), Sight.Point3.make(doors.x, doors.y, doors.z, l.level)):
				return _make(&"landing", l.level, pos, pos + Vector3(fx, 0, fy) * 0.25, doors, "LIFT LANDING")
	# High over the car's doors, looking out.
	var over := _centre(plan, l.level, l.x, l.y) + Vector3(ex, 0, ey) * CORNER + Vector3(0, MOUNT_H, 0)
	var out_at := _centre(plan, l.level, l.x, l.y) + Vector3(fx, 0, fy) * 4.0 + Vector3(0, AIM_H, 0)
	return _make(&"landing", l.level, over, over + Vector3(ex, 0, ey) * 0.25, out_at, "LIFT LANDING")

# --- rooms --------------------------------------------------------------------------------------------------

static func _rooms(plan: Floor.FloorPlan, blocks: Array, rng: Rng, taken: Array[Dictionary]) -> Array[Dictionary]:
	var land_room := Floor.room_id_at(plan, plan.landing.level, plan.landing.x, plan.landing.y)
	var cands: Array = []
	for r in plan.rooms:
		if NO_CAMERA.has(r.kind) or r.id == land_room or r.kind == &"lobby" or r.w * r.h < 2:
			continue
		var cam := _room_camera(plan, blocks, r, rng)
		# Every room draws its number, chosen or not, so one room never changes another's.
		var key := float(r.w * r.h) * (0.35 + (randf() if test_break == "engine" else rng.next()))
		if not cam.is_empty():
			cands.append([key, r.id, r.level, cam])
	cands.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0] if a[0] != b[0] else a[1] < b[1])
	var want := clampi(roundi(cands.size() * ROOM_SHARE), MIN_ROOMS, MAX_ROOMS)
	var out: Array[Dictionary] = []
	# At least one a level first (the biggest by its key), then the rest by key.
	for lv in 2:
		for c: Array in cands:
			if int(c[2]) == lv:
				out.append(c[3])
				break
	for c: Array in cands:
		if out.size() >= want:
			break
		if not out.has(c[3]):
			out.append(c[3])
	return out

## A room's camera: the corner (both its walls solid) with the longest look to the room's middle, or {}.
static func _room_camera(plan: Floor.FloorPlan, blocks: Array, r: Floor.Room, rng: Rng) -> Dictionary:
	var cs := float(plan.cell_size)
	# Low in the room's middle, so the picture is mostly floor where people walk.
	var mid := Vector3((r.x + r.w * 0.5) * cs, r.level * LH + 0.3, (r.y + r.h * 0.5) * cs)
	var best := {}
	var best_d := -1.0
	var best_seen := -1
	var inset := 0.93 if test_break == "inset" else CORNER
	for corner: Vector2i in [Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)]:
		var cx := r.x if corner.x < 0 else r.x + r.w - 1
		var cy := r.y if corner.y < 0 else r.y + r.h - 1
		if not _solid(plan, r.level, cx, cy, corner.x, 0) or not _solid(plan, r.level, cx, cy, 0, corner.y):
			continue
		var pos := _centre(plan, r.level, cx, cy) + Vector3(corner.x * inset, MOUNT_H, corner.y * inset)
		if test_break != "inset" and not lens_clear(plan, blocks, r.level, pos):
			continue
		var d := Vector2(pos.x - mid.x, pos.z - mid.z).length()
		var anchor := pos + Vector3(corner.x, 0, corner.y) * 0.24
		var cam := _make(&"room", r.level, pos, anchor, mid, _area(plan, r.level, pos, str(ROOM_NAMES.get(r.kind, String(r.kind).to_upper()))))
		# The corner whose picture shows most of the room's floor clearly (a figure's head past the furniture), then the
		# longest look across it.
		var seen := 0
		for y in range(r.y, r.y + r.h):
			for x in range(r.x, r.x + r.w):
				if shows(plan, cam, _centre(plan, r.level, x, y), r.level):
					seen += 1
		if seen > best_seen or (seen == best_seen and d > best_d + 0.01):
			best_seen = seen
			best_d = d
			best = cam
	return best

# --- corridors ------------------------------------------------------------------------------------------------

static func _corridors(plan: Floor.FloorPlan, blocks: Array) -> Array[Dictionary]:
	var lines := plan.sightlines.duplicate()
	lines.sort_custom(func(a: Floor.Sightline, b: Floor.Sightline) -> bool:
		if a.length != b.length:
			return a.length > b.length
		if a.level != b.level:
			return a.level < b.level
		return a.y1 * plan.width + a.x1 < b.y1 * plan.width + b.x1)
	var want := clampi(lines.size() / PER_SIGHTLINES, 1 if not lines.is_empty() else 0, MAX_CORRIDORS)
	var out: Array[Dictionary] = []
	for sl: Floor.Sightline in lines:
		if out.size() >= want:
			break
		if sl.length < 4:
			continue
		for end in 2:
			var ex := sl.x2 if end == 0 else sl.x1
			var ey := sl.y2 if end == 0 else sl.y1
			var ox := sl.x1 if end == 0 else sl.x2
			var oy := sl.y1 if end == 0 else sl.y2
			var dx := signi(ex - ox)
			var dy := signi(ey - oy)
			if Floor.cell_at(plan, sl.level, ex, ey) != Floor.CORRIDOR:
				continue
			var beyond := Walls.edge_kind(plan, sl.level, ex, ey, ex + dx, ey + dy)
			if beyond != Walls.WALL and beyond != Walls.DOOR:
				continue
			var pos := _centre(plan, sl.level, ex, ey) + Vector3(dx, 0, dy) * CORNER + Vector3(0, MOUNT_H, 0)
			if not lens_clear(plan, blocks, sl.level, pos):
				continue
			var aim := _centre(plan, sl.level, ox, oy) + Vector3(0, AIM_H, 0)
			var mid := (pos + aim) * 0.5
			out.append(_make(&"corridor", sl.level, pos, pos + Vector3(dx, 0, dy) * 0.25, aim, _area(plan, sl.level, Vector3(mid.x, 0, mid.z), "CORRIDOR")))
			break
	return out

# --- the Arboretum's lamp posts ---------------------------------------------------------------------------------

static func _posts(plan: Floor.FloorPlan, blocks: Array, rng: Rng) -> Array[Dictionary]:
	var g := Arboretum.garden_of(plan)
	var out: Array[Dictionary] = []
	if g == null:
		return out
	var cands: Array = []
	for l in g.landmarks:
		var key := rng.next()
		if l.id == 0 or not l.lamp_post:
			continue
		var post := Vector3(l.lamp.x / 100.0, 0.0, l.lamp.y / 100.0)
		var mid := Vector3((l.x + l.w * 0.5) * plan.cell_size, AIM_H, (l.y + l.h * 0.5) * plan.cell_size)
		var way := Vector3(mid.x - post.x, 0, mid.z - post.z)
		if way.length() < 0.5:
			way = Vector3(0, 0, 1)
		way = way.normalized()
		# Hung on the side of the post away from what it watches, so the post is not in its picture.
		for turn: float in [0.0, 0.6, -0.6, 1.2, -1.2, PI]:
			var out_way := way.rotated(Vector3.UP, PI + turn)
			var pos := post + out_way * POST_OUT + Vector3(0, POST_H, 0)
			if lens_clear(plan, blocks, 0, pos):
				var name := str(ROOM_NAMES.get(l.kind, String(l.kind).to_upper()))
				cands.append([key, l.id, _make(&"garden", 0, pos, post + Vector3(0, POST_H, 0), mid, "%s %s" % [compass(plan, pos), name])])
				break
	cands.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0] if a[0] != b[0] else a[1] < b[1])
	for c: Array in cands:
		if out.size() >= MAX_POSTS:
			break
		out.append(c[2])
	return out

# --- the last resort: any solid corner, spread out --------------------------------------------------------------

static func _any_corners(plan: Floor.FloorPlan, blocks: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for lv in 2:
		for y in plan.height:
			for x in plan.width:
				var k := Floor.cell_at(plan, lv, x, y)
				if k != Floor.ROOM and k != Floor.CORRIDOR:
					continue
				for corner: Vector2i in [Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)]:
					if not _solid(plan, lv, x, y, corner.x, 0) or not _solid(plan, lv, x, y, 0, corner.y):
						continue
					var pos := _centre(plan, lv, x, y) + Vector3(corner.x * CORNER, MOUNT_H, corner.y * CORNER)
					if lens_clear(plan, blocks, lv, pos):
						var aim := _centre(plan, lv, x, y) + Vector3(-corner.x * 4.0, AIM_H, -corner.y * 4.0)
						out.append(_make(&"room", lv, pos, pos + Vector3(corner.x, 0, corner.y) * 0.24, aim, _area(plan, lv, pos, "HALL")))
	# Farthest first from the landing: spread over the floor.
	var land := _centre(plan, plan.landing.level, plan.landing.x, plan.landing.y)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return (a["pos"] as Vector3).distance_to(land) > (b["pos"] as Vector3).distance_to(land))
	return out

# --- the Hanging Ward -----------------------------------------------------------------------------------------------

## The Ward's cameras from its walk model (sim/ward/state.gd: houses, the lift's door). `depth` the floor's number.
## A lens is kept clear of every wall, partition and slab of every house (their boxes grown by INSET), and the lift's
## camera has a clear line to the lift's door through them. The houses with a camera come from the Ward's seed.
const WARD_HOUSES := 4
static func for_ward(model: Object, ward_seed: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if model == null or not "houses" in model or (model.get("houses") as Array).is_empty():
		return out
	var houses: Array = model.get("houses")
	var rng := Rng.make_rng("cameras:ward:%d" % ward_seed)
	var lift := _ward_lift(model, houses)
	if not lift.is_empty():
		out.append(lift)
	var order: Array = []
	for i in houses.size():
		order.append([rng.next(), i])
	order.sort()
	for pair: Array in order:
		if out.size() >= WARD_HOUSES + 1:
			break
		var i := int(pair[1])
		if i == 0:
			continue
		var c := _ward_front(model, houses, i, rng)
		if not c.is_empty():
			out.append(c)
	if out.size() < 2:
		var c := _ward_front(model, houses, 0, rng)
		if not c.is_empty():
			out.append(c)
	for i in out.size():
		out[i]["n"] = i + 1
	return out

## The boxes (house local) a Ward lens keeps clear of.
static func _ward_boxes(h: Object) -> Array[AABB]:
	var boxes: Array[AABB] = []
	for b: AABB in h.get("walls"):
		boxes.append(b)
	for b: AABB in h.get("upper_envelope"):
		boxes.append(b)
	for st: Variant in h.get("storeys"):
		for b: AABB in st.partitions:
			boxes.append(b)
		for b: AABB in st.slab:
			boxes.append(b)
	return boxes

static func ward_clear(h: Object, local: Vector3) -> bool:
	for b in _ward_boxes(h):
		if b.grow(INSET).has_point(local):
			return false
	return true

static func _ward_line(h: Object, a: Vector3, b: Vector3) -> bool:
	for box in _ward_boxes(h):
		if box.intersects_segment(a, b):
			return false
	return true

static func _ward_lift(model: Object, houses: Array) -> Dictionary:
	var h: Object = houses[0]
	var fb: Rect2 = h.get("floor_bounds")
	var door_local := Vector3(fb.position.x + 0.3, 1.2, fb.get_center().y)
	# Across the parlour from the lift's door, as far as a clear line to it allows: the far side first, then nearer.
	var spots: Array[Vector3] = []
	var x_in := 0.35
	while fb.end.x - x_in > door_local.x + 1.0:
		for dz: float in [0.0, 0.5, -0.5, 1.0, -1.0, 1.5, -1.5, 2.0, -2.0]:
			spots.append(Vector3(fb.end.x - x_in, MOUNT_H, fb.get_center().y + dz))
		x_in += 0.4
	for lens in spots:
		if lens.z < fb.position.y + 0.3 or lens.z > fb.end.y - 0.3 or not ward_clear(h, lens) or not _ward_line(h, lens, door_local):
			continue
		var pos: Vector3 = h.call(&"to_world", lens)
		var aim: Vector3 = model.call(&"lift_door") + Vector3(0, 1.2, 0)
		return _make(&"landing", 0, pos, h.call(&"to_world", lens + Vector3(0.2, 0.05, 0)), aim, "LIFT")
	return {}

static func _ward_front(model: Object, houses: Array, i: int, rng: Rng) -> Dictionary:
	var h: Object = houses[i]
	var fb: Rect2 = h.get("floor_bounds")
	var half := fb.size.x * 0.5
	var side := 1.0 if rng.next() < 0.5 else -1.0
	var layout: Variant = model.get("layout")
	var sites: Array = (layout as Dictionary).get("houses", []) if layout is Dictionary else []
	var style := str((sites[i] as Dictionary).get("style", "")) if i < sites.size() and sites[i] is Dictionary else ""
	for s: float in [side, -side]:
		var lens := Vector3(s * (half - 0.45), MOUNT_H, -0.28)
		if not ward_clear(h, lens):
			continue
		var aim := Vector3(-s * half * 0.4, 0.8, -1.1)
		var pos: Vector3 = h.call(&"to_world", lens)
		var name := "HOUSE %d" % i if style == "" else style.replace("_", " ").to_upper()
		return _make(&"ward", 0, pos, h.call(&"to_world", Vector3(lens.x, lens.y, -0.07)), h.call(&"to_world", aim), "%s FRONT" % name)
	return {}
