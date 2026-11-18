# Hiding places on every floor with a resident (docs/floors/traits-and-hiding.md section 4, T19b).
# hides_for(plan, seed) is THE list of a floor's hides: the Playroom's own (Playroom.hides, unchanged),
# none in the prison, and for the Clinic and the Annex the lists made here. Pure functions of the plan
# and the seed, so the host and every client hold the same list with nothing new on the plan or the
# wire. playroom.gd, clinic.gd and annex.gd are not edited; the Playroom.Hide class is used as it is
# (its `zone` is the room's id off the Playroom).
#
# The kinds (section 4's table), each against a wall with its gap facing into the room, the inside spot
# INSET from the wall and the front spot FRONT_REACH further in (the Playroom's 70 cm):
#   bed      Clinic wards and exam rooms. Holds 1, eye 20 cm, the open side 70 degrees each side, 6 m far.
#   cabinet  Clinic closets and the nurses' station; Annex stores and closets. Holds 1, eye 1.5 m, 20 degrees.
#   desk     Annex offices, cubicles and the break room. Holds 1, eye 50 cm, the kneehole 45 degrees.
#   table    Annex meeting rooms: in the middle of the room. Holds 2, eye 30 cm, 60 degrees.
#
# The Clinic, by room kind, the seed (Rng "hides:clinic:<seed>:<depth>", one fork per room) choosing
# which wall slots: a ward one bed per 3 cells of its long walls (at least one), an exam room one bed, a
# closet one cabinet, the nurses' station two cabinets.
# The Annex, by room shape only, with no seed: every room is read in its canonical frame (the frame
# client/annex_view.gd dresses it in: the least of its eight symmetries by its openings), and the hides
# go on the canonical wall slots furthest from the openings, so same-shaped rooms get identical hides:
# an office one desk, the cubicles four, the break room one, a meeting room the table, every closet and
# store one cabinet.
# Rules for both: no hide in the lobby or the atrium, none on a cell within LANDING_STEPS of the landing
# (the car's zone is void, outside every room); the inside and front spots on a room cell that is not a
# door cell. Then, until they hold: each level's hides hold at least MIN_CAPACITY; from every corridor cell
# a hide's front cell is within REACH_STEPS steps (else a cabinet goes in the room nearest the first cell
# that fails, by walking: on the Annex at that room's best free canonical slot within reach, and at the
# same slot in every room of its shape, so repeated rooms stay identical; where no room's wall is within
# reach, a cupboard against the corridor's own wall, its room -1). Whole-number maths (centimetres); no
# engine randomness.
extends RefCounted

@warning_ignore_start("integer_division")

const Rng = preload("res://sim/rng.gd")
const Floor = preload("res://sim/floor.gd")
const Walls = preload("res://sim/walls.gd")
const Playroom = preload("res://sim/playroom.gd")
const Arboretum = preload("res://sim/arboretum.gd")

const CM := 200
## [capacity, eye height cm, gap half-angle degrees, gap range cm (0: no limit but the room), inset cm].
const SPEC := {
	&"bed": [1, 20, 70, 600, 45],
	&"cabinet": [1, 150, 20, 0, 30],
	&"desk": [1, 50, 45, 0, 40],
	&"table": [2, 30, 60, 0, 0],
}
const FRONT_REACH := 70
## From every corridor cell a hide is within this many steps (the Playroom's number).
const REACH_STEPS := 14
## Each level's hides hold at least this many players.
const MIN_CAPACITY := 8
## No hide on a cell this many steps or fewer from the landing.
const LANDING_STEPS := 3
## Top-ups never run away.
const MAX_TOP_UPS := 64
## Rooms that never hold a hide (the atrium has none of its own, but may take a top-up).
const NO_HIDES: Array[StringName] = [&"lobby"]

## The tests' deliberate breaks (tests/prop_hides.gd): "position" seeds the Annex's hides by the room's
## position; "no_top_up" skips the top-up cabinets.
static var test_break := ""

## Every hiding place on the floor, in id order. `floor_seed` "" means plan.seed.
static func hides_for(plan: Floor.FloorPlan, floor_seed: String = "") -> Array[Playroom.Hide]:
	var sd := floor_seed if floor_seed != "" else plan.seed
	match plan.place:
		&"playroom":
			return Playroom.hides(plan, sd)
		&"clinic":
			return _clinic(plan, sd)
		&"annex":
			return _annex(plan)
		&"arboretum":
			# The garden's own: sheds, benches, the bandstand's underside, hollow logs (sim/arboretum.gd).
			return Arboretum.hides(plan)
	var none: Array[Playroom.Hide] = []
	return none

# ---------------------------------------------------------------------------------------------
# Building one hide.

class Ctx:
	var plan: Floor.FloorPlan
	var out: Array[Playroom.Hide] = []
	## Cells (pos_index) holding a hide's inside or front spot.
	var used := {}
	var doors := {}
	var landing_dist: PackedInt32Array
	## Top-ups made (cabinets added by the rules for both places).
	var top_ups := 0

static func _ctx(plan: Floor.FloorPlan) -> Ctx:
	var c := Ctx.new()
	c.plan = plan
	c.doors = Playroom._door_cells(plan)
	c.landing_dist = Floor.distances_from(plan, plan.landing)
	return c

## Whether a hide may stand against the wall of this room cell.
static func _cell_ok(c: Ctx, room: Floor.Room, x: int, y: int) -> bool:
	if NO_HIDES.has(room.kind):
		return false
	var k := Floor.pos_index(c.plan, Floor.Pos.make(room.level, x, y))
	if c.doors.has(k) or c.used.has(k):
		return false
	if Floor.room_id_at(c.plan, room.level, x, y) != room.id:
		return false
	var d := c.landing_dist[k]
	return d < 0 or d > LANDING_STEPS

## A hide of `kind` against the `wall` side of cell (x, y) of `room`, its gap facing into the room.
static func _add_at(c: Ctx, kind: StringName, room: Floor.Room, x: int, y: int, wall: StringName) -> void:
	var spec: Array = SPEC[kind]
	var centre := Vector2i(x * CM + CM / 2, y * CM + CM / 2)
	var inside := centre + Vector2i(Floor.dir_dx(wall), Floor.dir_dy(wall)) * (CM / 2 - int(spec[4]))
	_add(c, kind, room, inside, Playroom.opposite(wall))

static func _add(c: Ctx, kind: StringName, room: Floor.Room, inside: Vector2i, gap: StringName) -> void:
	var spec: Array = SPEC[kind]
	var h := Playroom.Hide.new()
	h.id = c.out.size()
	h.zone = room.id
	h.room = room.id
	h.level = room.level
	h.kind = kind
	h.capacity = spec[0]
	h.eye = spec[1]
	h.gap_half = spec[2]
	h.gap_range = spec[3]
	h.inside = inside
	h.gap = gap
	h.front = inside + Vector2i(Floor.dir_dx(gap), Floor.dir_dy(gap)) * FRONT_REACH
	c.out.append(h)
	for p: Vector2i in [h.inside, h.front]:
		c.used[Floor.pos_index(c.plan, Floor.Pos.make(room.level, p.x / CM, p.y / CM))] = true

## Whether a cell of `room` beside (x, y) already holds a hide's spot (the room's own cells only, so a
## neighbour's hides never move this room's).
static func _adjacent_used(c: Ctx, room: Floor.Room, x: int, y: int) -> bool:
	for st in Floor.STEPS:
		var nx := x + st.x
		var ny := y + st.y
		if nx < room.x or ny < room.y or nx >= room.x + room.w or ny >= room.y + room.h:
			continue
		if c.used.has(Floor.pos_index(c.plan, Floor.Pos.make(room.level, nx, ny))):
			return true
	return false

## Up to `count` hides of `kind` on the room's slots, in the order given (Vector3i(x, y, wall index)),
## each on a free cell; cells beside one already used only when nothing else is left. Returns how many.
static func _fill(c: Ctx, kind: StringName, room: Floor.Room, slots: Array, count: int) -> int:
	var placed := 0
	for pass_ in 2:
		for s: Vector3i in slots:
			if placed >= count:
				return placed
			if not _cell_ok(c, room, s.x, s.y):
				continue
			if pass_ == 0 and _adjacent_used(c, room, s.x, s.y):
				continue
			_add_at(c, kind, room, s.x, s.y, Playroom.DIRS[s.z])
			placed += 1
	return placed

# ---------------------------------------------------------------------------------------------
# The Clinic.

static func _clinic(plan: Floor.FloorPlan, floor_seed: String) -> Array[Playroom.Hide]:
	var c := _ctx(plan)
	var root := Rng.make_rng("hides:clinic:%s:%d" % [floor_seed, plan.depth])
	for room in plan.rooms:
		var rr := root.fork("room:%d" % room.id)
		var slots: Array = []
		for s in Playroom._slots(plan, room, c.doors):
			slots.append(s)
		match room.kind:
			&"ward":
				# Beds along the long walls, one per three cells of them.
				var long_ns := room.w >= room.h
				var along: Array = []
				for s: Vector3i in slots:
					if (s.z % 2 == 0) == long_ns:
						along.append(s)
				var n := maxi(1, 2 * maxi(room.w, room.h) / 3)
				var got := _fill(c, &"bed", room, _shuffled(rr, along), n)
				if got == 0:
					_fill(c, &"bed", room, _shuffled(rr, slots), 1)
			&"exam":
				_fill(c, &"bed", room, _shuffled(rr, slots), 1)
			&"closet":
				_fill(c, &"cabinet", room, _shuffled(rr, slots), 1)
			&"station":
				_fill(c, &"cabinet", room, _shuffled(rr, slots), 2)
	_rules(c, root.fork("top-up"))
	return c.out

## clinic.gd's _shuffled, the same draws (hides.gd does not load the Clinic's generator).
static func _shuffled(rng: Rng, items: Array) -> Array:
	var out := items.duplicate()
	for i in range(out.size() - 1, 0, -1):
		var j := rng.int_in(0, i)
		var tmp: Variant = out[i]
		out[i] = out[j]
		out[j] = tmp
	return out

# ---------------------------------------------------------------------------------------------
# The Annex: by shape, in each room's canonical frame.

## A room read in its canonical frame: the key (the same text client/annex_view.gd's Shape builds), the
## symmetry that carries the canonical frame onto the room, its canonical size in centimetres, and its
## openings there (centimetres: an edge's middle, or a cell's centre).
class Shape:
	var key := ""
	var sym := 0
	var cw := 0
	var ch := 0
	var opens: Array[Vector2i] = []

## Canonical cm to room-local cm (x from the west wall, y from the north wall), symmetry k: bit 0 flips
## across, bit 1 flips down, bit 2 swaps the axes (client/annex_view.gd canon_to_local).
static func canon_to_local(k: int, wcm: int, hcm: int, p: Vector2i) -> Vector2i:
	var swap := (k & 4) != 0
	var cwm := hcm if swap else wcm
	var chm := wcm if swap else hcm
	var uu := cwm - p.x if (k & 1) != 0 else p.x
	var vv := chm - p.y if (k & 2) != 0 else p.y
	return Vector2i(vv, uu) if swap else Vector2i(uu, vv)

static func local_to_canon(k: int, wcm: int, hcm: int, a: Vector2i) -> Vector2i:
	var swap := (k & 4) != 0
	var cwm := hcm if swap else wcm
	var chm := wcm if swap else hcm
	var uu := a.y if swap else a.x
	var vv := a.x if swap else a.y
	return Vector2i(cwm - uu if (k & 1) != 0 else uu, chm - vv if (k & 2) != 0 else vv)

static func shape_of(plan: Floor.FloorPlan, room: Floor.Room) -> Shape:
	var wcm := room.w * CM
	var hcm := room.h * CM
	var local: Array = []  # [Vector2i m, kind String, cell bool]
	for j in room.h:
		for i in room.w:
			var x := room.x + i
			var y := room.y + j
			var ck := Floor.cell_at(plan, room.level, x, y)
			if ck != Floor.ROOM:
				local.append([Vector2i(i * CM + CM / 2, j * CM + CM / 2), String(ck), true])
			var sides: Array = []
			if j == 0:
				sides.append([Walls.north_edge(plan, room.level, x, y), Vector2i(i * CM + CM / 2, 0)])
			if j == room.h - 1:
				sides.append([Walls.north_edge(plan, room.level, x, y + 1), Vector2i(i * CM + CM / 2, hcm)])
			if i == 0:
				sides.append([Walls.west_edge(plan, room.level, x, y), Vector2i(0, j * CM + CM / 2)])
			if i == room.w - 1:
				sides.append([Walls.west_edge(plan, room.level, x + 1, y), Vector2i(wcm, j * CM + CM / 2)])
			for s: Array in sides:
				if s[0] != Walls.WALL:
					local.append([s[1], String(s[0]), false])
	var best := Shape.new()
	for k in 8:
		var swap := (k & 4) != 0
		var parts: Array[String] = []
		for f: Array in local:
			var m := local_to_canon(k, wcm, hcm, f[0])
			parts.append("%s%d,%d:%s" % ["c" if f[2] else "", _round_m(m.x), _round_m(m.y), f[1]])
		parts.sort()
		var key := "%s|%dx%d|%s" % [String(room.kind), room.h if swap else room.w, room.w if swap else room.h, ";".join(parts)]
		if best.key == "" or key < best.key:
			best.key = key
			best.sym = k
			best.cw = hcm if swap else wcm
			best.ch = wcm if swap else hcm
	for f: Array in local:
		best.opens.append(local_to_canon(best.sym, wcm, hcm, f[0]))
	return best

## Whole metres from centimetres, rounded half away from zero (roundi of the drawn metres).
static func _round_m(cm: int) -> int:
	return (cm + 50) / 100 if cm >= 0 else -((-cm + 50) / 100)

## The canonical wall slots of a shape, best first (furthest from any opening; then round the walls
## from the north-west corner clockwise), as [cell (canonical, cells), outward normal]. Slots at an
## opening are left out.
static func _canon_slots(sh: Shape) -> Array:
	var order: Array = []
	var idx := 0
	var cwc := sh.cw / CM
	var chc := sh.ch / CM
	for side in 4:
		var count := cwc if side % 2 == 0 else chc
		for i in count:
			var m: Vector2i
			var n: Vector2i
			match side:
				0:
					m = Vector2i(i * CM + CM / 2, 0)
					n = Vector2i(0, -1)
				1:
					m = Vector2i(sh.cw, i * CM + CM / 2)
					n = Vector2i(1, 0)
				2:
					m = Vector2i(sh.cw - i * CM - CM / 2, sh.ch)
					n = Vector2i(0, 1)
				_:
					m = Vector2i(0, sh.ch - i * CM - CM / 2)
					n = Vector2i(-1, 0)
			idx += 1
			var near := 1 << 30
			var opening := false
			for o in sh.opens:
				var dx := o.x - m.x
				var dy := o.y - m.y
				var d2 := dx * dx + dy * dy
				if d2 == 0:
					opening = true
				near = mini(near, d2)
			if opening:
				continue
			order.append([near, idx, m, n])
	# Best first: the largest distance to an opening, then the lower index (an insertion sort, so the
	# order never depends on the engine's sort).
	var out: Array = []
	for o: Array in order:
		var at := out.size()
		for i in out.size():
			var q: Array = out[i]
			if int(o[0]) > int(q[0]) or (int(o[0]) == int(q[0]) and int(o[1]) < int(q[1])):
				at = i
				break
		out.insert(at, o)
	var slots: Array = []
	for o: Array in out:
		var m: Vector2i = o[2]
		var n: Vector2i = o[3]
		slots.append([Vector2i((m.x - n.x * CM / 2) / CM, (m.y - n.y * CM / 2) / CM), n])
	return slots

## A canonical slot as an absolute one, Vector3i(x, y, wall index).
static func _slot_abs(room: Floor.Room, sh: Shape, cell: Vector2i, n: Vector2i) -> Vector3i:
	var wcm := room.w * CM
	var hcm := room.h * CM
	var centre := canon_to_local(sh.sym, wcm, hcm, cell * CM + Vector2i(CM / 2, CM / 2))
	var wall := canon_to_local(sh.sym, wcm, hcm, cell * CM + Vector2i(CM / 2, CM / 2) + n * (CM / 2)) - centre
	var d := Floor.dir_from_vec(signi(wall.x), signi(wall.y))
	return Vector3i(room.x + centre.x / CM, room.y + centre.y / CM, Playroom.DIRS.find(d))

## The Annex's hides by shape alone, before the rules' top-ups (for the tests).
static func by_shape(plan: Floor.FloorPlan) -> Array[Playroom.Hide]:
	return _annex(plan, false)

static func _annex(plan: Floor.FloorPlan, rules: bool = true) -> Array[Playroom.Hide]:
	var c := _ctx(plan)
	for room in plan.rooms:
		var count := 0
		var kind := &"desk"
		match room.kind:
			&"office", &"break":
				count = 1
			&"cubicles":
				count = 4
			&"closet", &"store":
				kind = &"cabinet"
				count = 1
			&"meeting":
				_meeting_table(c, plan, room)
		if count == 0:
			continue
		var sh := shape_of(plan, room)
		var slots: Array = []
		for s: Array in _canon_slots(sh):
			slots.append(_slot_abs(room, sh, s[0], s[1]))
		if test_break == "position":
			# The deliberate break: the slots dealt by the room's position, not its shape.
			slots = _shuffled(Rng.make_rng("hides:annex:%d,%d" % [room.x, room.y]), slots)
		_fill(c, kind, room, slots, count)
	if rules:
		_rules(c, null)
	return c.out

## The meeting room's table: in the middle of the room, its gap towards the long side with the most
## openings (in the canonical frame: the first of north, south, or west, east, on a tie).
static func _meeting_table(c: Ctx, plan: Floor.FloorPlan, room: Floor.Room) -> void:
	var sh := shape_of(plan, room)
	var long_x := sh.cw >= sh.ch
	var a := 0
	var b := 0
	for o in sh.opens:
		if long_x:
			a += 1 if o.y == 0 else 0
			b += 1 if o.y == sh.ch else 0
		else:
			a += 1 if o.x == 0 else 0
			b += 1 if o.x == sh.cw else 0
	var n := (Vector2i(0, -1) if a >= b else Vector2i(0, 1)) if long_x else (Vector2i(-1, 0) if a >= b else Vector2i(1, 0))
	var wcm := room.w * CM
	var hcm := room.h * CM
	var mid := Vector2i(sh.cw / 2, sh.ch / 2)
	var centre := canon_to_local(sh.sym, wcm, hcm, mid)
	var toward := canon_to_local(sh.sym, wcm, hcm, mid + n * 100) - centre
	var gap := Floor.dir_from_vec(signi(toward.x), signi(toward.y))
	var inside := Vector2i(room.x * CM, room.y * CM) + centre
	var front := inside + Vector2i(Floor.dir_dx(gap), Floor.dir_dy(gap)) * FRONT_REACH
	for p: Vector2i in [inside, front]:
		var k := Floor.pos_index(plan, Floor.Pos.make(room.level, p.x / CM, p.y / CM))
		if c.doors.has(k) or c.used.has(k):
			return
	_add(c, &"table", room, inside, gap)

# ---------------------------------------------------------------------------------------------
# The rules for both places: capacity per level, then the reach from every corridor cell.

static func _rules(c: Ctx, rng: Rng) -> void:
	var plan := c.plan
	for level in 2:
		for _i in MAX_TOP_UPS:
			var cap := 0
			for h in c.out:
				if h.level == level:
					cap += h.capacity
			if cap >= MIN_CAPACITY or not _top_up_level(c, level, rng):
				break
	if test_break == "no_top_up":
		return
	for _i in MAX_TOP_UPS:
		var bad := first_far_corridor(plan, c.out)
		if bad < 0:
			return
		if not _top_up_near(c, Floor.pos_from_index(plan, bad)):
			push_error("hides %s/%d: no room near corridor cell %d for a cabinet" % [plan.seed, plan.depth, bad])
			return

## A cabinet on the level, in the first room (plan order, or seeded) with a free slot.
static func _top_up_level(c: Ctx, level: int, rng: Rng) -> bool:
	var rooms: Array = []
	for room in c.plan.rooms:
		if room.level == level and not NO_HIDES.has(room.kind):
			rooms.append(room)
	if rng != null:
		rooms = _shuffled(rng, rooms)
	for room: Floor.Room in rooms:
		var slots: Array = []
		for s in Playroom._slots(c.plan, room, c.doors):
			slots.append(s)
		if _fill(c, &"cabinet", room, slots, 1) == 1:
			c.top_ups += 1
			return true
	return false

## A cabinet on the free wall slot nearest `from` by walking (the lowest cell index, then n e s w, on a tie).
static func _top_up_near(c: Ctx, from: Floor.Pos) -> bool:
	var plan := c.plan
	var dist := Floor.distances_from(plan, from)
	var best := Vector3i(-1, -1, -1)
	var best_room: Floor.Room = null
	var best_d := 1 << 30
	for room in plan.rooms:
		if NO_HIDES.has(room.kind):
			continue
		for s in Playroom._slots(plan, room, c.doors):
			if not _cell_ok(c, room, s.x, s.y):
				continue
			var d := dist[Floor.pos_index(plan, Floor.Pos.make(room.level, s.x, s.y))]
			if d >= 0 and d < best_d:
				best_d = d
				best = s
				best_room = room
	if best_room != null and best_d <= REACH_STEPS and c.plan.place == &"annex":
		# The Annex: by shape. In the nearest room, its best canonical free slot within reach; and the same
		# slot in every room of that shape on the floor, so repeated rooms stay identical.
		var sh := shape_of(plan, best_room)
		for cs: Array in _canon_slots(sh):
			var a := _slot_abs(best_room, sh, cs[0], cs[1])
			var d := dist[Floor.pos_index(plan, Floor.Pos.make(best_room.level, a.x, a.y))]
			if not _cell_ok(c, best_room, a.x, a.y) or d < 0 or d > REACH_STEPS:
				continue
			for room in plan.rooms:
				if room.kind != best_room.kind or room.w * room.h != best_room.w * best_room.h:
					continue
				var rs := sh if room == best_room else shape_of(plan, room)
				if rs.key != sh.key:
					continue
				var b := _slot_abs(room, rs, cs[0], cs[1])
				if _cell_ok(c, room, b.x, b.y):
					_add_at(c, &"cabinet", room, b.x, b.y, Playroom.DIRS[b.z])
					c.top_ups += 1
			return true
	if best_room != null and best_d <= REACH_STEPS:
		_add_at(c, &"cabinet", best_room, best.x, best.y, Playroom.DIRS[best.z])
		c.top_ups += 1
		return true
	# No room's wall is near enough (a gallery or a corridor past rooms with no wall to spare): a cupboard
	# against the corridor's own wall, on the corridor cell nearest `from` by walking that has one.
	var n := plan.width * plan.height
	var best_k := -1
	var best_wall := -1
	best_d = 1 << 30
	for k in 2 * n:
		var d := dist[k]
		if d < 0 or d >= best_d or d > REACH_STEPS:
			continue
		var level := 1 if k >= n else 0
		var x := (k - level * n) % plan.width
		var y := (k - level * n) / plan.width
		if Floor.cell_at(plan, level, x, y) != Floor.CORRIDOR or c.doors.has(k) or c.used.has(k):
			continue
		if c.landing_dist[k] >= 0 and c.landing_dist[k] <= LANDING_STEPS:
			continue
		var wall := _solid_side(plan, level, x, y)
		if wall < 0:
			continue
		best_k = k
		best_wall = wall
		best_d = d
	if best_k < 0:
		return false
	var lv := 1 if best_k >= n else 0
	var cx := (best_k - lv * n) % plan.width
	var cy := (best_k - lv * n) / plan.width
	var corridor := Floor.Room.new()
	corridor.id = -1
	corridor.level = lv
	corridor.kind = Floor.CORRIDOR
	_add_at(c, &"cabinet", corridor, cx, cy, Playroom.DIRS[best_wall])
	c.top_ups += 1
	return true

## The first side (n, e, s, w) of a cell that is a solid wall, as a Playroom.DIRS index, or -1.
static func _solid_side(plan: Floor.FloorPlan, level: int, x: int, y: int) -> int:
	if Walls.north_edge(plan, level, x, y) == Walls.WALL:
		return 0
	if Walls.west_edge(plan, level, x + 1, y) == Walls.WALL:
		return 1
	if Walls.north_edge(plan, level, x, y + 1) == Walls.WALL:
		return 2
	if Walls.west_edge(plan, level, x, y) == Walls.WALL:
		return 3
	return -1

## Steps from every position to the nearest hide's front cell (-1: none reached), walking backwards from
## the fronts over Floor.can_step_xy.
static func steps_to_hides(plan: Floor.FloorPlan, list: Array[Playroom.Hide]) -> PackedInt32Array:
	var w := plan.width
	var n := plan.width * plan.height
	var dist := PackedInt32Array()
	dist.resize(2 * n)
	dist.fill(-1)
	var queue := PackedInt32Array()
	queue.resize(2 * n)
	var tail := 0
	for h in list:
		var k := h.level * n + (h.front.y / CM) * w + h.front.x / CM
		if dist[k] == -1:
			dist[k] = 0
			queue[tail] = k
			tail += 1
	var head := 0
	while head < tail:
		var ci := queue[head]
		head += 1
		var cl := 1 if ci >= n else 0
		var rest := ci - cl * n
		var cx := rest % w
		var cy := rest / w
		for level: int in [cl, 1 - cl]:
			for d in Floor.STEPS:
				var nx := cx + d.x
				var ny := cy + d.y
				if nx < 0 or ny < 0 or nx >= w or ny >= plan.height:
					continue
				var key := level * n + ny * w + nx
				if dist[key] != -1 or not Floor.can_step_xy(plan, level, nx, ny, cl, cx, cy):
					continue
				dist[key] = dist[ci] + 1
				queue[tail] = key
				tail += 1
	return dist

## The first corridor cell (pos_index order) more than REACH_STEPS from every hide, or -1.
static func first_far_corridor(plan: Floor.FloorPlan, list: Array[Playroom.Hide]) -> int:
	var dist := steps_to_hides(plan, list)
	var n := plan.width * plan.height
	for k in 2 * n:
		var level := 1 if k >= n else 0
		var rest := k - level * n
		if plan.cells[level][rest] != Floor.CORRIDOR:
			continue
		if dist[k] < 0 or dist[k] > REACH_STEPS:
			return k
	return -1

# ---------------------------------------------------------------------------------------------
# Plain data and hashes (tests/reference/hides_hashes.json).

static func hash_of(list: Array[Playroom.Hide]) -> String:
	return Playroom.hash_plain(Playroom.hides_plain(list))
