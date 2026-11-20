# The Reactor: the generating station (docs/floors/the-intact-crew.md "The generating station"; build plan
# docs/floors/native-late-floors.md, RN1). Laid out from the floor seed and returned as the ordinary floor plan
# (the type every place's generator returns), so movement, sight, navigation and the level view work on it unchanged,
# plus the anchors in plan.station. Pure and deterministic: the host and every client make the same plan.
#
# The rooms (canonical frame: x east, y south, 2 m cells; the whole plan may be mirrored east-west by the seed):
#   - the turbine hall: 5 cells wide, L = 12 to 15 long (seeded), the stopped rotor at its north end;
#   - the lift landing at shift change: the hall's south end, 3 cells deep, one room with the hall, so the long
#     sightline runs straight from the lift door up the hall to the rotor (plan.sightlines[0], L + 3 cells);
#   - the control gallery: beside the hall to the east, looking back across it through wired glass (the glass is
#     the wall between them, `glass` below); one door at its south end;
#   - the cable crawl: a hatch in the gallery's far corner, a passage along the gallery's far side and round its
#     north end, out into the hall through a second opening. Hall, gallery and crawl make a loop. Creep-only: the
#     four never enter it (sim/station_floor.gd), and a client keeps a standing player out (`creep_only`);
#   - the switch room with the marked service cabinet (the fuse socket), off the hall's south-east corner, near
#     the lift;
#   - the west wing: side rooms off the hall (fuse stores among them) with dead-end closets behind them, and a
#     store north of the crawl when there is room. The fuse lies at one of `fuse_spots`, all in these rooms, out of
#     line of sight from the hall's centreline and a walk from the cabinet.
#
# plan.station, the anchors (world metres: x and z on the floor, y up; yaw three.js style, Entity.yaw_toward):
#   "lift_door":  Vector3              the car's door centre (Run.car_geometry door_x, 0, door_z)
#   "sill":       {"at": Vector3, "yaw": float, "width": float}   the striped sill across the car's door
#   "plinth":     Vector3              the cassette's table beside the lift door (its foot; top at PLINTH_TOP)
#   "lockers":    Array of 4 {"at": Vector3, "yaw": float, "seat": int}    hooks on the landing's west wall
#   "time_cards": Array of 4 {"at": Vector3, "yaw": float, "seat": int}    card slots on the landing's east wall
#   "rotor":      {"at": Vector3, "yaw": float, "radius": float}  the stopped rotor, the sightline's far end
#   "hall":       Rect2 (x, z, w, d)   the turbine hall, landing excluded
#   "landing":    Rect2                the landing at shift change
#   "gallery":    Rect2                the control gallery
#   "glass":      Array of [ax, ay, bx, by] cell edges between gallery and hall drawn as wired glass
#   "crawl":      Array[Vector2i]      the crawl's cells
#   "crawl_mouths": Array of [ax, ay, bx, by]  its two openings (the gallery's hatch, the hall's opening)
#   "fuse_spots": Array[Vector3]       at least five candidates; the rules pick one by the seed (fuse_index)
#   "cabinet":    {"at": Vector3, "yaw": float}  the socket, on the switch room's wall, yaw facing into the room
#   "bodies":     Array of 4 {"at": Vector3, "yaw": float, "seat": int}  where the four lie, seats 1 to 4
#   "growths":    Array of {"at": Vector3, "yaw": float, "kind": StringName}  kind: &"pipe_collar",
#                 &"cracked_insulation" or &"split_cable_tray"
#   "lamps":      Array of {"at": Vector3, "emergency": bool}  amber service lamps; emergency ones stay lit
#   "rooms":      {name: room id}      "hall", "gallery", "crawl_v", "crawl_h", "switch", "store_ne" (when made),
#                 and the west wing's ("west_0", "closet_0", ...)
#   "mirrored":   bool
#
# The snapshot's "reactor" block on this place (net/reactor_review.gd native_snapshot; the old floor's fields, kept):
#   seed int, seq int, rev int, power int (0 lit, 1 emergency, 2 restored), time float (seconds since the cut),
#   holder (player id, or 0), fuseUses int, cassette bool (taken), lift bool (the crew has gone up with it),
#   players {id: [x,y,z]}, crew Array of 4 [x, y, z, yaw, roll, phase, clock] (phase "still", "zombie_crawl" or
#   "zombie_run"), status {id: "up"|"down"|"out"}, low {id: bool}, cassetteHolder (id or ""), extracted bool,
#   fuseAt [x,y,z], tapeAt [x,y,z], archive {recovered, discovered, playing}, and new on this place:
#   native true, holdLeft float (seconds of light left, -1 before anyone passes the landing), seats [1,2,3,4].
extends RefCounted

const Floor = preload("res://sim/floor.gd")
const Rng = preload("res://sim/rng.gd")
const Sight = preload("res://sim/sight.gd")
const Entity = preload("res://sim/entity.gd")

const PLACE := &"reactor"
const CELL := 2
const HALL_X := 6
const HALL_W := 5
const HALL_TOP := 2
const LANDING_D := 3
const GALLERY_X := 11
const GALLERY_W := 3
const CRAWL_X := 14
const WEST_X := 3
const WEST_W := 3
const CLOSET_X := 1
const CLOSET_W := 2
const WIDTH := 16
const HALL_MIN := 12
const HALL_MAX := 15
## The table's top, metres above the floor (the tape lies on it).
const PLINTH_TOP := 0.9
## A fuse lies on the floor.
const FUSE_Y := 0.07
## The eye a centreline look is checked from.
const EYE := 1.6
## The least walk, in cells, from the cabinet's cell to a fuse spot's.
const FUSE_WALK_MIN := 7
const MIN_FUSE_SPOTS := 5
const GROWTH_KINDS: Array[StringName] = [&"pipe_collar", &"cracked_insulation", &"split_cable_tray"]

static func wc(c: int) -> float:
	return (float(c) + 0.5) * CELL

## The plan of the station for this floor seed and depth.
static func generate_station(seed: String, depth: int) -> Floor.FloorPlan:
	var rng := Rng.make_rng("station:%s:%d" % [seed, depth])
	var shape := rng.fork("shape")
	var hall_l := shape.int_in(HALL_MIN, HALL_MAX)
	var gallery_h := shape.int_in(5, 7)
	var g0 := shape.int_in(3, hall_l - gallery_h)
	var mirrored := shape.chance(0.5)
	var height := HALL_TOP + hall_l + LANDING_D + 2
	var plan := Floor.FloorPlan.new()
	plan.place = PLACE
	plan.seed = seed
	plan.depth = depth
	plan.width = WIDTH
	plan.height = height
	plan.cell_size = CELL
	for level in 2:
		plan.cells[level].resize(WIDTH * height)
		plan.cells[level].fill(Floor.VOID)
	var names := {}
	var hall_bottom := HALL_TOP + hall_l - 1
	var land_y := hall_bottom + 1
	# The hall and the landing: one room, so the landing opens straight into the hall.
	names["hall"] = _room(plan, &"hall", HALL_X, HALL_TOP, HALL_W, hall_l + LANDING_D, &"main")
	var g_bottom := g0 + gallery_h - 1
	names["gallery"] = _room(plan, &"gallery", GALLERY_X, g0, GALLERY_W, gallery_h, &"main")
	names["crawl_v"] = _room(plan, &"crawl", CRAWL_X, g0 - 1, 1, gallery_h + 1, &"main")
	names["crawl_h"] = _room(plan, &"crawl", GALLERY_X, g0 - 1, GALLERY_W, 1, &"main")
	var switch_y := g_bottom + 1
	names["switch"] = _room(plan, &"switch", GALLERY_X, switch_y, GALLERY_W + 1, hall_bottom - switch_y + 1, &"side")
	# The loop: the gallery's door into the hall, the hatch into the crawl, the crawl's own way out.
	_door(plan, HALL_X + HALL_W - 1, g_bottom, GALLERY_X, g_bottom)
	_door(plan, GALLERY_X + GALLERY_W - 1, g_bottom, CRAWL_X, g_bottom)
	_door(plan, GALLERY_X + GALLERY_W - 1, g0 - 1, CRAWL_X, g0 - 1)
	_door(plan, HALL_X + HALL_W - 1, g0 - 1, GALLERY_X, g0 - 1)
	_door(plan, HALL_X + HALL_W - 1, hall_bottom, GALLERY_X, hall_bottom)
	var stores: Array[Rect2i] = []
	if g0 - 1 > HALL_TOP:
		names["store_ne"] = _room(plan, &"stores", GALLERY_X, HALL_TOP, GALLERY_W + 1, g0 - 1 - HALL_TOP, &"side")
		_door(plan, HALL_X + HALL_W - 1, HALL_TOP, GALLERY_X, HALL_TOP)
		stores.append(Rect2i(GALLERY_X, HALL_TOP, GALLERY_W + 1, g0 - 1 - HALL_TOP))
	# The west wing: side rooms down the hall's west wall, a dead-end closet behind each.
	var wing := rng.fork("wing")
	var y := HALL_TOP
	var n := 0
	var stores_at := wing.int_in(0, 1)
	while y <= hall_bottom:
		var left := hall_bottom - y + 1
		var h := wing.int_in(3, 5)
		if left - h < 3:
			h = left
		var kind: StringName = &"stores" if n == stores_at or n == stores_at + 2 else (wing.pick([&"lockers", &"office", &"pumps"]) as StringName)
		names["west_%d" % n] = _room(plan, kind, WEST_X, y, WEST_W, h, &"side")
		_door(plan, WEST_X + WEST_W - 1, y + wing.int_in(0, h - 1), HALL_X, 0)
		names["closet_%d" % n] = _room(plan, &"closet", CLOSET_X, y, CLOSET_W, h, &"side")
		_door(plan, CLOSET_X + CLOSET_W - 1, y + wing.int_in(0, h - 1), WEST_X, 0)
		stores.append(Rect2i(WEST_X, y, WEST_W, h))
		stores.append(Rect2i(CLOSET_X, y, CLOSET_W, h))
		y += h
		n += 1
	var mid := HALL_X + HALL_W / 2
	plan.landing = Floor.Pos.make(0, mid, land_y + LANDING_D - 1)
	plan.entity_start = Floor.Pos.make(0, mid, HALL_TOP)
	var line := Floor._sightline(0, mid, HALL_TOP, mid, plan.landing.y, plan.landing.y - HALL_TOP + 1)
	plan.sightlines.append(line)

	# Anchors, canonical first.
	var a := {}
	var door_z := float(plan.landing.y + 1) * CELL
	a["lift_door"] = Vector3(wc(mid), 0.0, door_z)
	a["sill"] = {"at": Vector3(wc(mid), 0.0, door_z), "yaw": 0.0, "width": 2.0}
	var table_side := 1.0 if rng.fork("plinth").chance(0.5) else -1.0
	a["plinth"] = Vector3(wc(mid) + table_side * 2.6, 0.0, door_z - 0.75)
	var lockers: Array = []
	var cards: Array = []
	for i in 4:
		var z := float(land_y) * CELL + 0.9 + 1.2 * i
		lockers.append({"at": Vector3(float(HALL_X) * CELL + 0.25, 0.0, z), "yaw": Entity.yaw_toward(1.0, 0.0), "seat": i + 1})
		cards.append({"at": Vector3(float(HALL_X + HALL_W) * CELL - 0.25, 1.3, z), "yaw": Entity.yaw_toward(-1.0, 0.0), "seat": i + 1})
	a["lockers"] = lockers
	a["time_cards"] = cards
	a["rotor"] = {"at": Vector3(wc(mid), 0.0, float(HALL_TOP) * CELL + 1.4), "yaw": Entity.yaw_toward(0.0, 1.0), "radius": 1.8}
	a["hall"] = Rect2(float(HALL_X) * CELL, float(HALL_TOP) * CELL, HALL_W * CELL, hall_l * CELL)
	a["landing"] = Rect2(float(HALL_X) * CELL, float(land_y) * CELL, HALL_W * CELL, LANDING_D * CELL)
	a["gallery"] = Rect2(float(GALLERY_X) * CELL, float(g0) * CELL, GALLERY_W * CELL, gallery_h * CELL)
	var glass: Array = []
	for gy in range(g0, g_bottom):
		glass.append([HALL_X + HALL_W - 1, gy, GALLERY_X, gy])
	a["glass"] = glass
	var crawl: Array[Vector2i] = []
	for cy in range(g0 - 1, g_bottom + 1):
		crawl.append(Vector2i(CRAWL_X, cy))
	for cx in range(GALLERY_X, GALLERY_X + GALLERY_W):
		crawl.append(Vector2i(cx, g0 - 1))
	a["crawl"] = crawl
	a["crawl_mouths"] = [[GALLERY_X + GALLERY_W - 1, g_bottom, CRAWL_X, g_bottom], [HALL_X + HALL_W - 1, g0 - 1, GALLERY_X, g0 - 1]]
	var cab_cell := Vector2i(CRAWL_X, hall_bottom)
	a["cabinet"] = {"at": Vector3(float(CRAWL_X + 1) * CELL - 0.3, 1.05, wc(hall_bottom)), "yaw": Entity.yaw_toward(-1.0, 0.0)}
	# The four: two in the hall's north half, one in the gallery, one at the crawl's hall-side mouth.
	var br := rng.fork("bodies")
	var north := HALL_TOP + 2 + br.int_in(0, maxi(0, hall_l / 2 - 3))
	var bodies: Array = []
	bodies.append({"at": Vector3(wc(HALL_X + 1) + br.next() - 0.5, 0.0, wc(north) + br.next() - 0.5), "yaw": br.next() * TAU - PI, "seat": 1})
	bodies.append({"at": Vector3(wc(HALL_X + 3) + br.next() - 0.5, 0.0, wc(north + 1) + br.next() - 0.5), "yaw": br.next() * TAU - PI, "seat": 2})
	bodies.append({"at": Vector3(wc(GALLERY_X + 1) + br.next() * 0.6 - 0.3, 0.0, wc(g0 + br.int_in(1, gallery_h - 2))), "yaw": br.next() * TAU - PI, "seat": 3})
	bodies.append({"at": Vector3(wc(HALL_X + HALL_W - 1) - 0.2, 0.0, wc(g0 - 1)), "yaw": Entity.yaw_toward(1.0, 0.0), "seat": 4})
	a["bodies"] = bodies
	a["lamps"] = _lamps(hall_l, g0, gallery_h, switch_y, hall_bottom)
	a["growths"] = _growths(rng.fork("growths"), hall_l, g0, gallery_h)
	a["rooms"] = names
	a["mirrored"] = mirrored
	if mirrored:
		_mirror(plan, a)
		cab_cell = Vector2i(WIDTH - 1 - cab_cell.x, cab_cell.y)
	plan.station = a
	a["fuse_spots"] = _fuse_spots(plan, rng.fork("fuses"), stores, mirrored, cab_cell)
	return plan

static func _room(plan: Floor.FloorPlan, kind: StringName, x: int, y: int, w: int, h: int, branch: StringName) -> int:
	var r := Floor.Room.new()
	r.id = plan.rooms.size()
	r.level = 0
	r.kind = kind
	r.x = x
	r.y = y
	r.w = w
	r.h = h
	r.branch = branch
	plan.rooms.append(r)
	for cy in range(y, y + h):
		for cx in range(x, x + w):
			plan.cells[0][cy * plan.width + cx] = Floor.ROOM
	return r.id

## A door between (ax, ay) and (bx, by); by 0 means "the same row as ay".
static func _door(plan: Floor.FloorPlan, ax: int, ay: int, bx: int, by: int) -> void:
	plan.doors.append(Floor.Door.make(0, ax, ay, bx, ay if by == 0 and bx != ax else by))

static func _lamps(hall_l: int, g0: int, gallery_h: int, switch_y: int, hall_bottom: int) -> Array:
	var out: Array = []
	var k := 0
	for cy in range(HALL_TOP, HALL_TOP + hall_l + LANDING_D, 3):
		out.append({"at": Vector3(float(HALL_X) * CELL + 0.15, 2.6, wc(cy)), "emergency": k % 2 == 0})
		k += 1
	out.append({"at": Vector3(wc(GALLERY_X + 1), 2.4, wc(g0 + gallery_h / 2)), "emergency": true})
	out.append({"at": Vector3(wc(CRAWL_X), 0.6, wc(g0 + gallery_h / 2)), "emergency": true})
	out.append({"at": Vector3(wc(GALLERY_X + 2), 2.4, wc((switch_y + hall_bottom) / 2)), "emergency": true})
	out.append({"at": Vector3(wc(HALL_X + HALL_W / 2), 2.8, float(HALL_TOP + hall_l + LANDING_D) * CELL - 0.3), "emergency": true})
	return out

static func _growths(r: Rng, hall_l: int, g0: int, gallery_h: int) -> Array:
	var out: Array = []
	var count := r.int_in(6, 9)
	for i in count:
		var kind: StringName = GROWTH_KINDS[i % GROWTH_KINDS.size()]
		var at: Vector3
		var yaw := 0.0
		if kind == &"split_cable_tray":
			at = Vector3(wc(CRAWL_X), 0.5, wc(g0 + r.int_in(0, gallery_h - 1)) + r.next() - 0.5)
			yaw = Entity.yaw_toward(0.0, 1.0)
		elif kind == &"pipe_collar":
			at = Vector3(float(HALL_X + HALL_W) * CELL - 0.2, 2.2, wc(HALL_TOP + r.int_in(0, hall_l - 1)) + r.next() - 0.5)
			yaw = Entity.yaw_toward(-1.0, 0.0)
		else:
			at = Vector3(float(HALL_X) * CELL + 0.2, 1.0 + r.next(), wc(HALL_TOP + r.int_in(0, hall_l - 1)) + r.next() - 0.5)
			yaw = Entity.yaw_toward(1.0, 0.0)
		out.append({"at": at, "yaw": yaw, "kind": kind})
	return out

## Mirrors the plan and the anchors east to west.
static func _mirror(plan: Floor.FloorPlan, a: Dictionary) -> void:
	var w := plan.width
	var wm := float(w * CELL)
	for level in 2:
		var row: Array = plan.cells[level]
		var flipped: Array[StringName] = []
		flipped.resize(row.size())
		for cy in plan.height:
			for cx in w:
				flipped[cy * w + cx] = row[cy * w + (w - 1 - cx)]
		plan.cells[level] = flipped
	for r in plan.rooms:
		r.x = w - r.x - r.w
	for d in plan.doors:
		d.ax = w - 1 - d.ax
		d.bx = w - 1 - d.bx
	plan.landing = Floor.Pos.make(0, w - 1 - plan.landing.x, plan.landing.y)
	plan.entity_start = Floor.Pos.make(0, w - 1 - plan.entity_start.x, plan.entity_start.y)
	for s in plan.sightlines:
		s.x1 = w - 1 - s.x1
		s.x2 = w - 1 - s.x2
	var fx := func(v: Vector3) -> Vector3: return Vector3(wm - v.x, v.y, v.z)
	a["lift_door"] = fx.call(a["lift_door"])
	a["plinth"] = fx.call(a["plinth"])
	for key: String in ["sill", "rotor", "cabinet"]:
		var d: Dictionary = a[key]
		d["at"] = fx.call(d["at"])
		d["yaw"] = -float(d["yaw"])
	for key: String in ["lockers", "time_cards", "bodies", "growths"]:
		for d: Dictionary in a[key]:
			d["at"] = fx.call(d["at"])
			d["yaw"] = -float(d["yaw"])
	for d: Dictionary in a["lamps"]:
		d["at"] = fx.call(d["at"])
	for key: String in ["hall", "landing", "gallery"]:
		var r: Rect2 = a[key]
		a[key] = Rect2(wm - r.position.x - r.size.x, r.position.y, r.size.x, r.size.y)
	for key: String in ["glass", "crawl_mouths"]:
		for e: Array in a[key]:
			e[0] = w - 1 - int(e[0])
			e[2] = w - 1 - int(e[2])
	var crawl: Array[Vector2i] = []
	for c: Vector2i in a["crawl"]:
		crawl.append(Vector2i(w - 1 - c.x, c.y))
	a["crawl"] = crawl

## Candidate fuse spots: the corners of the side rooms that no look from the hall's centreline reaches and that are
## a walk from the cabinet; up to eight, in a seeded order.
static func _fuse_spots(plan: Floor.FloorPlan, r: Rng, rooms: Array[Rect2i], mirrored: bool, cab_cell: Vector2i) -> Array:
	var dist := Floor.distances_from(plan, Floor.Pos.make(0, cab_cell.x, cab_cell.y))
	var found: Array = []
	for rect in rooms:
		var x0 := plan.width - rect.position.x - rect.size.x if mirrored else rect.position.x
		var corners: Array[Vector3] = [
			Vector3(float(x0) * CELL + 0.45, FUSE_Y, float(rect.position.y) * CELL + 0.45),
			Vector3(float(x0 + rect.size.x) * CELL - 0.45, FUSE_Y, float(rect.position.y) * CELL + 0.45),
			Vector3(float(x0) * CELL + 0.45, FUSE_Y, float(rect.position.y + rect.size.y) * CELL - 0.45),
			Vector3(float(x0 + rect.size.x) * CELL - 0.45, FUSE_Y, float(rect.position.y + rect.size.y) * CELL - 0.45),
		]
		for c in corners:
			var cell := Floor.Pos.make(0, int(floor(c.x / CELL)), int(floor(c.z / CELL)))
			var d := dist[Floor.pos_index(plan, cell)]
			if d < FUSE_WALK_MIN:
				continue
			if seen_from_centreline(plan, c):
				continue
			found.append(c)
	var out: Array = []
	while not found.is_empty() and out.size() < 8:
		out.append(found.pop_at(r.int_in(0, found.size() - 1)))
	return out

## Whether a point can be seen from anywhere on the hall's centreline (eye height), landing included.
static func seen_from_centreline(plan: Floor.FloorPlan, at: Vector3) -> bool:
	var line: Floor.Sightline = plan.sightlines[0]
	var x := wc(line.x1)
	var to := Sight.Point3.make(at.x, at.y + 0.05, at.z, 0)
	var z := float(mini(line.y1, line.y2)) * CELL + 0.3
	var end := float(maxi(line.y1, line.y2) + 1) * CELL - 0.3
	while z <= end:
		if Sight.has_line_of_sight(plan, Sight.Point3.make(x, EYE, z, 0), to):
			return true
		z += 0.5
	return false

## Whether a cell is the crawl's (creep only: the four never enter it; a standing player is kept out by the client).
static func creep_only(plan: Floor.FloorPlan, cx: int, cy: int) -> bool:
	if plan.station.is_empty():
		return false
	return (plan.station["crawl"] as Array).has(Vector2i(cx, cy))

## Whether a step from (fx, fz) to (tx, tz) on `level` keeps the crawl creep-only (RN3: "a player can crawl between
## the cable trays"): stepping into a crawl cell from outside it needs a creep (a downed player's crawl counts);
## every step inside it, out of it or nowhere near it is fine. The client stops its own body with this and the host
## refuses an input that breaks it (net/host.gd _on_input), both from the plan alone.
static func crawl_step_ok(plan: Floor.FloorPlan, level: int, fx: float, fz: float, tx: float, tz: float, creeping: bool) -> bool:
	if creeping or level != 0 or plan.station.is_empty():
		return true
	var to := cell_of(tx, tz)
	if not creep_only(plan, to.x, to.y):
		return true
	var from := cell_of(fx, fz)
	return creep_only(plan, from.x, from.y)

## Whether a body at (x, z) on `level` is in the crawl, so it creeps whatever is asked (it cannot stand under the
## trays until it is out).
static func in_crawl(plan: Floor.FloorPlan, level: int, x: float, z: float) -> bool:
	if level != 0 or plan.station.is_empty():
		return false
	var c := cell_of(x, z)
	return creep_only(plan, c.x, c.y)

## The cell a world point lies in.
static func cell_of(x: float, z: float) -> Vector2i:
	return Vector2i(int(floor(x / CELL)), int(floor(z / CELL)))

const ROOM_CHAR := {&"hall": "H", &"gallery": "G", &"crawl": "c", &"switch": "S", &"stores": "F", &"lockers": "K",
	&"office": "O", &"pumps": "P", &"closet": "C"}

## A text map (tests and notes): rooms by letter, + doors, E the landing, R the rotor's cell, f fuse spots, 1-4 the four.
static func render_ascii(plan: Floor.FloorPlan) -> String:
	var w := plan.width
	var grid := PackedStringArray()
	grid.resize(w * plan.height)
	grid.fill("#")
	for r in plan.rooms:
		for cy in range(r.y, r.y + r.h):
			for cx in range(r.x, r.x + r.w):
				grid[cy * w + cx] = str(ROOM_CHAR.get(r.kind, "?"))
	for d in plan.doors:
		grid[d.by * w + d.bx] = "+"
	var a := plan.station
	for f: Vector3 in a.get("fuse_spots", []):
		var c := cell_of(f.x, f.z)
		grid[c.y * w + c.x] = "f"
	for b: Dictionary in a.get("bodies", []):
		var at: Vector3 = b["at"]
		var c := cell_of(at.x, at.z)
		grid[c.y * w + c.x] = str(b["seat"])
	grid[plan.landing.y * w + plan.landing.x] = "E"
	grid[plan.entity_start.y * w + plan.entity_start.x] = "R"
	var rows := PackedStringArray()
	for y in plan.height:
		rows.append("".join(grid.slice(y * w, (y + 1) * w)))
	return "\n".join(rows)
