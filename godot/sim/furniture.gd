# Furniture: one list (docs/floors/findables-and-day.md section 4, FD7). pieces_for(plan, seed, depth) is THE
# list of a floor's floor-standing furniture, a pure function of the plan and the seed like the hide list, so
# the host and every client hold the same list with nothing new on the plan or the wire. Each piece has a kind,
# a level, a position (its footprint's centre, whole centimetres: x is world x, y is world z), a facing (the way
# its front looks), a footprint and three flags: solid, hide, searchable.
#
# It is built from two lists and adds a third:
#  - the hides stay owned by sim/hides.gd (Hides.hides_for): one piece per hide, at its inside spot, its front
#    towards the gap. A hide is solid except at its open side: its collision footprint (`block`) is its
#    footprint cut back on the gap side so a player's body (PLAYER_R) fits on the front spot with 2 cm to
#    spare (a bed loses 7 cm, a desk 2 cm, the meeting table 27 cm of its 65; a cabinet nothing). A desk's
#    chair and the meeting table's chairs come with their hide (`group`), wherever they fit;
#  - the searchable pieces are owned by sim/findables.gd (FD8): pieces_for asks it (Findables.mark_searchable)
#    which of the plain pieces below can be searched, and sets their `searchable` flag;
#  - the rest are plain solid pieces added here: chairs, wheelchairs, gurneys, cabinets and drawers in the
#    Clinic (the glb models the client had placed by itself), and in the Annex the filing cabinets, plants,
#    water coolers, copiers, shelves, boxes, the break room's counter and fridge, the atrium's chair rows.
# Collision reads this list and nothing else (solids_of: every solid piece's `block` is a box players slide
# along, sim/move.gd Solids). The client draws every piece from this list and nothing else floor-standing
# (client/level.gd, client/annex_view.gd); posters, clocks, things on desks and ceiling lights stay its own.
#
# Residents keep walking by the plan alone (they never read this list), so plain pieces stand against walls
# (their back INSET from the wall line), never on a door cell or over the middle of a cell. T20j restores
# waiting chairs to the lobby side walls away from the landing, benches and planters to atriums, and a
# break-room table with two chairs to a free wall. Other furniture stays beyond LANDING_STEPS. Two pieces
# in a room that do not share a wall line stand at least CLEAR apart (a player's body and 10 cm to spare),
# neighbours along one wall at least SPARE apart, and nothing stands within FRONT_SPARE of a body on a
# hide's front spot.
#
# The Clinic's plain pieces are dealt by the seed (Rng "furniture:clinic:<seed>:<depth>", one fork per room,
# on its wall slots as the client dealt its props); the Annex's by room shape alone, with no seed: every room
# is read in its canonical frame (Hides.shape_of) and each kind goes on the best free canonical wall slot
# (Hides._canon_slots, furthest from the openings first), so same-shaped rooms get identical pieces. The
# Playroom and the prison have none here (the Playroom's soft play stays client/playroom_view.gd's).
# Whole-number maths (centimetres); no engine randomness.
extends RefCounted

@warning_ignore_start("integer_division")

const Rng = preload("res://sim/rng.gd")
const Floor = preload("res://sim/floor.gd")
const Walls = preload("res://sim/walls.gd")
const Move = preload("res://sim/move.gd")
const Playroom = preload("res://sim/playroom.gd")
const Hides = preload("res://sim/hides.gd")
const Arboretum = preload("res://sim/arboretum.gd")
const Landing = preload("res://sim/landing.gd")

const CM := 200
## A player's body radius, cm (net/session.gd PLAYER_RADIUS).
const PLAYER_R := 30
## A wall piece's back stands this far from the wall line (the drawn wall's half thickness, 7 cm, and 6).
const INSET := 13
## Two pieces in a room that do not share a wall line stand at least this far apart (a body, 60, and 10).
const CLEAR := 70
## Neighbours along one wall stand at least this far apart.
const SPARE := 5
## Nothing stands within this of a body on a hide's front spot.
const FRONT_SPARE := 10
## A hide's block ends this far short of a body on its front spot.
const HIDE_SPARE := 2
## No piece on a cell this many steps or fewer from the landing.
const LANDING_STEPS := 3
## Lobby chairs are flank pieces only, at least two cells from the landing.
const LOBBY_LANDING_STEPS := 2
## Rooms that hold no furniture in the baseline layout.
const NO_PIECES: Array[StringName] = [&"lobby"]
## The Clinic's plain pieces' slide along their wall, cm either way.
const SLIDE := 40

## Every kind: [width across its front, depth front to back, tall], in whole even centimetres (so a footprint
## is exactly symmetric about its centre, whichever way a room's canonical frame turns it). A "turned" kind
## (TURNED) stands side-on to its wall, its front looking along it. Clinic kinds are the glb models' bounding
## boxes (assets/props/manifest.json); Annex kinds client/annex_view.gd's catalogue (the copier as its boxes
## are drawn); hide kinds client/annex_view.gd hide_half (the meeting table's own size is MEETING_TABLE).
const KINDS := {
	&"side_table": [64, 52, false],
	&"wheelchair": [72, 94, false],
	&"cabinet_tall": [90, 56, true],
	&"chair_waiting": [46, 44, false],
	&"gurney": [74, 196, false],
	&"drawers_low": [116, 46, false],
	&"chair_desk": [56, 52, false],
	&"filing": [46, 66, true],
	&"cabinet_low": [90, 54, false],
	&"plant": [52, 52, false],
	&"copier": [130, 64, false],
	&"cooler": [34, 36, false],
	&"fridge": [72, 72, true],
	&"counter": [184, 64, false],
	&"shelf": [180, 46, true],
	&"boxes": [62, 50, false],
	&"chair_row": [172, 50, false],
	&"chair": [52, 52, false],
	&"bed": [200, 90, false],
	&"cabinet": [90, 60, true],
	&"desk": [160, 80, false],
	&"table": [180, 100, false],
	# The Arboretum (sim/arboretum.gd): trunks, the dead trees, lamp posts, the small landmarks' pieces, its hides.
	&"trunk": [30, 30, true],
	&"dead_tree": [50, 50, true],
	&"lamp": [20, 20, true],
	&"fountain": [120, 120, false],
	&"statue": [120, 60, false],
	&"arch": [120, 40, true],
	&"sundial": [80, 80, false],
	&"shed": [90, 60, true],
	&"bench": [180, 50, false],
	&"under": [120, 50, false],
	&"log": [160, 50, false],
	&"break_table": [120, 56, false],
	&"planter": [100, 56, false],
}
const TURNED: Array[StringName] = [&"wheelchair", &"gurney"]
## The Annex meeting room's table (client/annex_view.gd draws it): 4.4 by 1.3 m.
const MEETING_TABLE := Vector2i(440, 130)
const CHAIRS: Array[StringName] = [&"chair", &"chair_waiting", &"chair_desk", &"chair_row"]

## Plain pieces by Clinic room kind (client/level.gd's old ROOM_PROPS, less the lobby), and how many a room
## tries for: one per three cells and one, at most six.
const CLINIC_PROPS := {
	&"ward": [&"side_table", &"wheelchair", &"cabinet_tall", &"chair_waiting", &"side_table"],
	&"exam": [&"gurney", &"drawers_low", &"chair_desk", &"cabinet_tall", &"side_table"],
	&"station": [&"chair_desk", &"drawers_low", &"cabinet_tall", &"chair_waiting"],
	&"closet": [&"cabinet_tall", &"drawers_low"],
	&"atrium": [&"chair_waiting", &"wheelchair", &"gurney"],
}
## Plain pieces by Annex room kind, each on the best free canonical wall slot (client/annex_view.gd
## layout_for's wall props; the ones it stood in the middle of a room are gone: pieces stand against walls).
const ANNEX_PROPS := {
	&"office": [&"filing", &"plant"],
	&"cubicles": [&"filing", &"filing", &"plant", &"cooler"],
	&"meeting": [&"plant", &"cabinet_low", &"plant"],
	&"copy": [&"copier", &"copier", &"copier", &"boxes", &"filing"],
	&"store": [&"shelf", &"shelf", &"shelf", &"shelf", &"boxes", &"boxes"],
	&"break": [&"counter", &"fridge", &"cooler"],
	&"closet": [&"shelf", &"boxes", &"filing", &"boxes"],
	&"atrium": [&"chair_row", &"chair_row", &"cooler", &"plant"],
}

## The tests' deliberate breaks (tests/prop_furniture.gd): "chairs_soft" leaves the chairs out of the solid
## set; "randi" slides the Clinic's pieces with randi().
static var test_break := ""

class Piece:
	var id := 0
	var kind: StringName
	## The room's id (-1: a corridor cupboard).
	var room := -1
	var level := 0
	## The footprint's centre, cm (x world x, y world z).
	var x := 0
	var y := 0
	## The way its front looks: n e s w.
	var facing: StringName = &"s"
	## Width across its front and depth front to back, cm (KINDS, or the meeting table's).
	var w := 0
	var d := 0
	var solid := true
	## The hide's id (sim/hides.gd), or -1.
	var hide := -1
	var searchable := false
	var tall := false
	## The piece this one belongs to (a chair at its desk or table), or -1.
	var group := -1
	## The wall it stands against (n e s w, its outward side) and that wall line's coordinate (cm), or "".
	var wall: StringName = &""
	var wall_at := 0
	## The footprint on the floor, and the part that blocks a player (the footprint, less a hide's open side).
	var foot: Rect2i
	var block: Rect2i

## Every floor-standing piece on the floor, in id order: the hides first (in hide id order, each followed by
## its chairs), then the plain pieces room by room. `floor_seed` "" means plan.seed; `depth` -1 means plan.depth.
## The Annex view can supply the hides it already resolved for this plan.
static func pieces_for(plan: Floor.FloorPlan, floor_seed: String = "", depth: int = -1, furniture_layout: bool = false, source_hides: Array[Playroom.Hide] = []) -> Array[Piece]:
	var sd := floor_seed if floor_seed != "" else plan.seed
	var dp := depth if depth >= 0 else plan.depth
	var c := _ctx(plan)
	if plan.place == &"arboretum":
		# The Arboretum: its hides, then the garden's props where the generator stood them (sim/arboretum.gd:
		# landmark pieces, lamp posts, dead trees, trunks), every one solid.
		for h in Hides.hides_for(plan, sd):
			_add_hide(c, h)
		for pr: Array in Arboretum.props(plan):
			_commit(c, _piece(c, pr[0], -1, 0, pr[1], pr[2], pr[3]))
		return c.out
	if plan.place != &"clinic" and plan.place != &"annex":
		return c.out
	for h in (Hides.hides_for(plan, sd) if source_hides.is_empty() else source_hides):
		_add_hide(c, h)
	if plan.place == &"clinic":
		_clinic(c, sd, dp)
	else:
		_annex(c)
	# The searchable flag: sim/findables.gd decides (FD8). Loaded, not preloaded: findables.gd reads this file.
	if _findables == null:
		_findables = load("res://sim/findables.gd")
	_findables.mark_searchable(plan, c.out, sd, dp, c.hides)
	# Append after marking searches so every existing piece keeps its id, position and contents.
	if furniture_layout:
		_restore_wall_furniture(c)
	return c.out

static var _findables: GDScript = null

# ---------------------------------------------------------------------------------------------
# Building pieces.

class Ctx:
	var plan: Floor.FloorPlan
	var out: Array[Piece] = []
	var doors := {}
	var landing_dist: PackedInt32Array
	var hides: Array[Playroom.Hide] = []
	## Room id -> the room, and -> its pieces so far.
	var rooms := {}
	var by_room := {}

static func _ctx(plan: Floor.FloorPlan) -> Ctx:
	var c := Ctx.new()
	c.plan = plan
	for r in plan.rooms:
		c.rooms[r.id] = r
	c.doors = Playroom._door_cells(plan)
	c.landing_dist = Floor.distances_from(plan, plan.landing)
	return c

static func dir_vec(d: StringName) -> Vector2i:
	return Vector2i(Floor.dir_dx(d), Floor.dir_dy(d))

## The footprint of a piece `w` across by `d` deep, centred on (x, y), its front facing `f`.
static func foot_of(x: int, y: int, f: StringName, w: int, d: int) -> Rect2i:
	var across_x := f == &"n" or f == &"s"
	var sx := w if across_x else d
	var sy := d if across_x else w
	return Rect2i(x - sx / 2, y - sy / 2, sx, sy)

static func _piece(c: Ctx, kind: StringName, room: int, level: int, x: int, y: int, facing: StringName) -> Piece:
	var p := Piece.new()
	p.kind = kind
	p.room = room
	p.level = level
	p.x = x
	p.y = y
	p.facing = facing
	var spec: Array = KINDS[kind]
	p.w = spec[0]
	p.d = 60 if kind == &"bench" and c.plan.place == &"arboretum" else spec[1]
	p.tall = spec[2]
	p.solid = not (test_break == "chairs_soft" and CHAIRS.has(kind))
	p.foot = foot_of(x, y, facing, p.w, p.d)
	p.block = p.foot
	return p

static func _commit(c: Ctx, p: Piece) -> void:
	p.id = c.out.size()
	c.out.append(p)
	if not c.by_room.has(p.room):
		c.by_room[p.room] = []
	(c.by_room[p.room] as Array).append(p)

## A hide's piece, then its chairs.
static func _add_hide(c: Ctx, h: Playroom.Hide) -> void:
	c.hides.append(h)
	var p := _piece(c, h.kind, h.room, h.level, h.inside.x, h.inside.y, h.gap)
	p.hide = h.id
	if h.kind == &"table" and c.plan.place == &"annex":
		p.w = MEETING_TABLE.x
		p.d = MEETING_TABLE.y
		p.foot = foot_of(p.x, p.y, p.facing, p.w, p.d)
	var g := dir_vec(h.gap)
	if h.kind != &"table":
		p.wall = Playroom.opposite(h.gap)
		var wv := -g
		var cell := Vector2i(h.inside.x / CM, h.inside.y / CM)
		p.wall_at = (cell.x * CM + (CM if wv.x > 0 else 0)) if wv.x != 0 else (cell.y * CM + (CM if wv.y > 0 else 0))
	# Solid except at its open side: the gap side ends where a body on the front spot begins (less HIDE_SPARE).
	var reach := Hides.FRONT_REACH - PLAYER_R - HIDE_SPARE
	var half := p.d / 2
	if half > reach:
		var r := p.foot
		var cut := half - reach
		if g.x > 0:
			r.size.x -= cut
		elif g.x < 0:
			r.position.x += cut
			r.size.x -= cut
		elif g.y > 0:
			r.size.y -= cut
		else:
			r.position.y += cut
			r.size.y -= cut
		p.block = r
	_commit(c, p)
	var a := Vector2i(-g.y, g.x)
	var host := p.id
	var chairs: Array = []  # [along, toward the gap, facing]
	if h.kind == &"desk":
		# Pushed back to one side of the kneehole: on the Annex the same side in every room of the shape (the
		# room's canonical frame may be a mirror image of the world's).
		var side := 1
		if c.plan.place == &"annex" and c.rooms.has(h.room):
			var room: Floor.Room = c.rooms[h.room]
			var sh := Hides.shape_of(c.plan, room)
			var o := Vector2i(room.x * CM, room.y * CM)
			var at0 := Hides.local_to_canon(sh.sym, room.w * CM, room.h * CM, h.inside - o)
			var gc := Hides.local_to_canon(sh.sym, room.w * CM, room.h * CM, h.inside - o + g * 10) - at0
			var ac := Hides.local_to_canon(sh.sym, room.w * CM, room.h * CM, h.inside - o + a * 10) - at0
			side = 1 if ac == Vector2i(-gc.y, gc.x) else -1
		chairs.append([-105 * side, 55, Playroom.opposite(h.gap)])
	elif h.kind == &"table" and c.plan.place == &"annex":
		for along: int in [-150, -50, 50, 150]:
			chairs.append([along, 95, Playroom.opposite(h.gap)])
			chairs.append([along, -95, h.gap])
		chairs.append([-255, 0, Floor.dir_from_vec(a.x, a.y)])
		chairs.append([255, 0, Floor.dir_from_vec(-a.x, -a.y)])
	for ch: Array in chairs:
		var at := h.inside + a * int(ch[0]) + g * int(ch[1])
		var q := _piece(c, &"chair", h.room, h.level, at.x, at.y, ch[2])
		q.group = host
		if _fits(c, q):
			_commit(c, q)

## A plain piece against the `wall` side (Playroom.DIRS index) of cell (x, y), slid `slide` cm along it.
static func _wall_piece(c: Ctx, kind: StringName, room: Floor.Room, x: int, y: int, wall: int, slide: int) -> Piece:
	var out_d: StringName = Playroom.DIRS[wall]
	var ov := dir_vec(out_d)
	var inward := -ov
	var facing := Playroom.opposite(out_d)
	if TURNED.has(kind):
		# Side-on: its front looks along the wall (a quarter turn clockwise from into the room).
		facing = Floor.dir_from_vec(-inward.y, inward.x)
	var spec: Array = KINDS[kind]
	var deep: int = spec[0] if TURNED.has(kind) else spec[1]
	var centre := Vector2i(x * CM + CM / 2, y * CM + CM / 2)
	var line := centre + ov * (CM / 2)
	var along := Vector2i(-ov.y, ov.x)
	var at := line + inward * (INSET + deep / 2) + along * slide
	var p := _piece(c, kind, room.id, room.level, at.x, at.y, facing)
	p.wall = out_d
	p.wall_at = line.x if ov.x != 0 else line.y
	return p

## Whether a cell may be under a piece of `room`.
static func _cell_ok(c: Ctx, room_id: int, level: int, x: int, y: int, lobby: bool) -> bool:
	var plan := c.plan
	if x < 0 or y < 0 or x >= plan.width or y >= plan.height:
		return false
	if Floor.room_id_at(plan, level, x, y) != room_id:
		return false
	var k := Floor.cell_at(plan, level, x, y)
	if k != Floor.ROOM:
		return false
	var i := Floor.pos_index(plan, Floor.Pos.make(level, x, y))
	if c.doors.has(i):
		return false
	var d := c.landing_dist[i]
	if lobby:
		return d >= LOBBY_LANDING_STEPS
	return d < 0 or d > LANDING_STEPS

## Distance squared between two rectangles (0 when they touch or overlap).
static func gap2(a: Rect2i, b: Rect2i) -> int:
	var dx := maxi(0, maxi(a.position.x - b.end.x, b.position.x - a.end.x))
	var dy := maxi(0, maxi(a.position.y - b.end.y, b.position.y - a.end.y))
	return dx * dx + dy * dy

static func overlaps(a: Rect2i, b: Rect2i) -> bool:
	return a.position.x < b.end.x and b.position.x < a.end.x and a.position.y < b.end.y and b.position.y < a.end.y

## Whether a piece may stand where it is (the rules in the header).
static func _fits(c: Ctx, p: Piece, restored: bool = false) -> bool:
	var plan := c.plan
	var room: Floor.Room = c.rooms.get(p.room)
	if room == null or (NO_PIECES.has(room.kind) and not restored):
		return false
	var f := p.foot
	var inner := Rect2i(room.x * CM + INSET, room.y * CM + INSET, room.w * CM - 2 * INSET, room.h * CM - 2 * INSET)
	if not inner.encloses(f):
		return false
	# Every cell under it, and never over a cell's middle.
	for cy in range(f.position.y / CM, (f.end.y - 1) / CM + 1):
		for cx in range(f.position.x / CM, (f.end.x - 1) / CM + 1):
			if not _cell_ok(c, room.id, p.level, cx, cy, room.kind == &"lobby"):
				return false
			var mx := cx * CM + CM / 2
			var my := cy * CM + CM / 2
			if p.block.position.x < mx and mx < p.block.end.x and p.block.position.y < my and my < p.block.end.y:
				return false
			if restored and gap2(Rect2i(mx, my, 0, 0), p.block) < PLAYER_R * PLAYER_R:
				return false
	for q: Piece in c.by_room.get(p.room, []):
		if q.level != p.level:
			continue
		if restored and q.searchable:
			var at := search_stand_cm(q)
			var reach := PLAYER_R + FRONT_SPARE
			if gap2(Rect2i(at, Vector2i.ZERO), f) < reach * reach:
				return false
		if p.group >= 0 and (q.id == p.group or q.group == p.group):
			# A chair at its own desk or table (or beside another of its chairs): only never inside it.
			if overlaps(q.foot, f):
				return false
			continue
		if p.wall != &"" and q.wall == p.wall and q.wall_at == p.wall_at:
			if gap2(q.foot, f) < SPARE * SPARE:
				return false
		elif gap2(q.foot, f) < CLEAR * CLEAR:
			return false
	for h in c.hides:
		if h.level != p.level or h.room != p.room or h.id == p.hide:
			continue
		var reach := PLAYER_R + FRONT_SPARE
		if gap2(Rect2i(h.front.x, h.front.y, 0, 0), f) < reach * reach:
			return false
	return true

## The standard approach to search a piece: 45 cm in front of its side facing into the room.
static func search_stand_cm(p: Piece) -> Vector2i:
	var inward := -dir_vec(p.wall) if p.wall != &"" else dir_vec(p.facing)
	var ext := p.foot.size.x / 2 if inward.x != 0 else p.foot.size.y / 2
	return p.foot.position + p.foot.size / 2 + inward * (ext + 45)

# ---------------------------------------------------------------------------------------------
# The Clinic: by room kind, dealt by the seed.

static func _clinic(c: Ctx, floor_seed: String, depth: int) -> void:
	var root := Rng.make_rng("furniture:clinic:%s:%d" % [floor_seed, depth])
	for room in c.plan.rooms:
		if NO_PIECES.has(room.kind) or not CLINIC_PROPS.has(room.kind):
			continue
		var rr := root.fork("room:%d" % room.id)
		var list: Array = CLINIC_PROPS[room.kind]
		var count := clampi(room.w * room.h / 3 + 1, 1, 6)
		var slots: Array = []
		for s in Playroom._slots(c.plan, room, c.doors):
			if _wall_solid(c.plan, room.level, s):
				slots.append(s)
		slots = Hides._shuffled(rr, slots)
		var si := 0
		for _i in count:
			var kind: StringName = list[rr.int_in(0, list.size() - 1)]
			var slide := rr.int_in(-SLIDE, SLIDE)
			if test_break == "randi":
				# The deliberate break: the engine's own generator, not the seed's.
				slide = randi() % (2 * SLIDE + 1) - SLIDE
			while si < slots.size():
				var s: Vector3i = slots[si]
				si += 1
				var p := _wall_piece(c, kind, room, s.x, s.y, s.z, slide)
				if _fits(c, p):
					_commit(c, p)
					break

## Whether the slot's side is a solid wall.
static func _wall_solid(plan: Floor.FloorPlan, level: int, s: Vector3i) -> bool:
	match s.z:
		0:
			return Walls.north_edge(plan, level, s.x, s.y) == Walls.WALL
		1:
			return Walls.west_edge(plan, level, s.x + 1, s.y) == Walls.WALL
		2:
			return Walls.north_edge(plan, level, s.x, s.y + 1) == Walls.WALL
	return Walls.west_edge(plan, level, s.x, s.y) == Walls.WALL

# ---------------------------------------------------------------------------------------------
# The Annex: by shape, in each room's canonical frame.

static func _canonical_wall_slots(plan: Floor.FloorPlan, room: Floor.Room) -> Array[Vector3i]:
	var sh := Hides.shape_of(plan, room)
	var slots: Array[Vector3i] = []
	for cs: Array in Hides._canon_slots(sh):
		var a := Hides._slot_abs(room, sh, cs[0], cs[1])
		if _wall_solid(plan, room.level, a):
			slots.append(a)
	return slots

static func _annex(c: Ctx) -> void:
	for room in c.plan.rooms:
		if NO_PIECES.has(room.kind) or not ANNEX_PROPS.has(room.kind):
			continue
		var slots := _canonical_wall_slots(c.plan, room)
		for kind: StringName in ANNEX_PROPS[room.kind]:
			for s: Vector3i in slots:
				var p := _wall_piece(c, kind, room, s.x, s.y, s.z, 0)
				if _fits(c, p):
					_commit(c, p)
					break

# ---------------------------------------------------------------------------------------------
# Restored wall furniture (T20j).

static func _restore_wall_furniture(c: Ctx) -> void:
	for room in c.plan.rooms:
		match room.kind:
			&"lobby":
				_restore_lobby(c, room)
			&"atrium":
				var slots := _canonical_wall_slots(c.plan, room)
				for kind: StringName in [&"bench", &"planter", &"bench", &"planter"]:
					for s in slots:
						var p := _wall_piece(c, kind, room, s.x, s.y, s.z, 0)
						if _fits(c, p, true):
							_commit(c, p)
							break
			&"break":
				_restore_break_table(c, room)

static func _restore_lobby(c: Ctx, room: Floor.Room) -> void:
	var side := dir_vec(Landing.elevator_wall(c.plan))
	var kind := &"chair_row" if c.plan.place == &"annex" else &"chair_waiting"
	var used := {}
	for s in _canonical_wall_slots(c.plan, room):
		var wall := Playroom.DIRS[s.z]
		var normal := dir_vec(wall)
		if used.has(wall) or normal.x * side.x + normal.y * side.y != 0:
			continue
		var p := _wall_piece(c, kind, room, s.x, s.y, s.z, 0)
		if _fits(c, p, true):
			_commit(c, p)
			used[wall] = true

## The chairs sit beside the table and face it. They keep the same shallow wall strip clear of the centre.
## Only place the set when the table and both chairs fit.
static func _restore_break_table(c: Ctx, room: Floor.Room) -> void:
	var chair_width: int = KINDS[&"chair"][0]
	for s in _canonical_wall_slots(c.plan, room):
		var table := _wall_piece(c, &"break_table", room, s.x, s.y, s.z, 0)
		if not _fits(c, table, true):
			continue
		var wall := dir_vec(table.wall)
		var across := Vector2i(-wall.y, wall.x)
		var chairs: Array[Piece] = []
		for sign_: int in [-1, 1]:
			var at := Vector2i(table.x, table.y) + across * sign_ * (table.w / 2 + chair_width / 2 + SPARE)
			var toward := -across * sign_
			var chair := _piece(c, &"chair", room.id, room.level, at.x, at.y, Floor.dir_from_vec(toward.x, toward.y))
			chair.wall = table.wall
			chair.wall_at = table.wall_at
			chair.group = c.out.size()
			if not _fits(c, chair, true):
				break
			chairs.append(chair)
		if chairs.size() == 2:
			_commit(c, table)
			for chair in chairs:
				_commit(c, chair)
			return

# ---------------------------------------------------------------------------------------------
# Collision: the solid pieces as boxes for players (sim/move.gd Solids), cached per plan.

static var _solids := {}
static var _restored_solids := {}
static var _solid_order: Array = []

## The layout's solid pieces as Move.Solids (metres), from pieces_for. Keeps the last 16 plans.
static func solids_of(plan: Floor.FloorPlan, furniture_layout: bool = false) -> Move.Solids:
	var cache := _restored_solids if furniture_layout else _solids
	if cache.has(plan):
		return cache[plan]
	var s := solids_from(plan, pieces_for(plan, "", -1, furniture_layout))
	if not _solid_order.has(plan):
		_solid_order.append(plan)
		if _solid_order.size() > 16:
			var first: Floor.FloorPlan = _solid_order.pop_front()
			_solids.erase(first)
			_restored_solids.erase(first)
	cache[plan] = s
	return s

static func solids_from(plan: Floor.FloorPlan, list: Array[Piece]) -> Move.Solids:
	var s := Move.Solids.new()
	s.cell_size = float(plan.cell_size)
	for p in list:
		if p.solid:
			s.add(p.level, p.block.position.x / 100.0, p.block.position.y / 100.0, p.block.end.x / 100.0, p.block.end.y / 100.0)
	return s

# ---------------------------------------------------------------------------------------------
# Plain data and hashes (tests/reference/furniture_hashes.json).

static func plain(list: Array[Piece]) -> Array:
	var out: Array = []
	for p in list:
		out.append({"id": p.id, "kind": String(p.kind), "room": p.room, "level": p.level, "x": p.x, "y": p.y, "facing": String(p.facing),
			"w": p.w, "d": p.d, "solid": p.solid, "hide": p.hide, "searchable": p.searchable, "group": p.group,
			"block": [p.block.position.x, p.block.position.y, p.block.size.x, p.block.size.y]})
	return out

## The list's hash (tests/reference/furniture_hashes.json): every field but `searchable`, which sim/findables.gd
## decides and tests/reference/findables_hashes.json covers, so the furniture's stored hashes stand as recorded.
static func hash_of(list: Array[Piece]) -> String:
	var rows := plain(list)
	for r: Dictionary in rows:
		r["searchable"] = false
	return Playroom.hash_plain(rows)
