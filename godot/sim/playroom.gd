# The Playroom: an empty indoor soft-play centre, floor 4, where you hide.
# Design: docs/floors/playarea.md section 6. No TypeScript twin: its tests (tests/prop_playroom.gd)
# and its stored hashes (tests/playroom_hashes.json) are its proof. Notes: sim/PLAYROOM.md.
#
# Constructive, cannot fail. In a canonical orientation (the lattice against the north margin), it:
#   1. lays the Annex's lattice of one-cell padded walkways, a line every 7 cells, 6 by 6 blocks between;
#   2. picks two stair blocks at least two blocks apart, then gives every other block a template:
#      one party room on the row farthest from the lift, one each of ball pit, frame, toddler corner
#      and cloakroom, the rest dealt from a reshuffled deck of the five, never a ball pit beside a
#      ball pit or a stair block; a nook (a small den) sits beside each stair on both levels;
#   3. hangs the lift lobby (the shoe room) off the south line;
#   4. prunes 15% of the walkway segments on each level, never one on the outer ring, never one that is
#      protected, never one that leaves a block with walkway on fewer than two sides, and never one whose
#      removal leaves a junction whose loss would split the walkway (so blocking any one walkway cell
#      leaves the rest of that level's walkway connected);
#   5. stamps every block from its template; level 1 gets a netted deck over every block that is not a
#      stair or a ball pit (the ball pit is an opening with balconies, the Annex's atrium), and four
#      crawl dens over frames while the room budget lasts;
# then turns or mirrors the whole plan by a seeded symmetry, as the Clinic does.
#
# Hides, squeakers, zones and the party-table seats are pure functions of the plan and the seed: they
# read the lattice and the blocks back from the plan, so the host and every client hold the same lists
# with no new field on the plan or the wire.
#
# Reused by preload, unedited: annex.gd's lattice, bridge check, block stamp, atrium opening and stair
# block; clinic.gd's builder, carving, rooms, doors, shuffle and symmetry. Whole-number maths only (the
# floats are inside Rng); no engine randomness; no sorts.
extends RefCounted

# Whole-number maths throughout: integer division is meant.
@warning_ignore_start("integer_division")

const Rng = preload("res://sim/rng.gd")
const Floor = preload("res://sim/floor.gd")
const Clinic = preload("res://sim/clinic.gd")
const Annex = preload("res://sim/annex.gd")
const M = preload("res://sim/jsmath.gd")

const PLACE := &"playroom"
const CELL_SIZE := 2
## Centimetres per cell. Hide and seat positions are whole centimetres in world x and z (cell x, y).
const CM := 100 * CELL_SIZE
const MARGIN := 1
const PITCH := 7
const BLOCK := 6
const STAIR_LENGTH := 4
const PRUNE_PERCENT := 15
const MAX_ROOMS := 80
const MIN_SIGHTLINE := 8
const ENTITY_MIN_STEPS := 12
const LOBBY_W := 5
const LOBBY_D := 3
const SHAFT_W := 3
const SHAFT_D := 2
## Seats at the party table: one per player the server admits (net/ws_server.gd MAX_PLAYERS).
const SEATS := 8

## Block templates. STAIRS is a block with the soft steps and nothing else.
const STAIRS := 0
const BALLPIT := 1
const FRAME := 2
const PARTY := 3
const TODDLER := 4
const CLOAK := 5
## Level 1 only: a netted deck (one room) or the frame's upper storey (four crawl dens).
const DECK := 6
const UPPER := 7
const KINDS: Array[int] = [BALLPIT, FRAME, PARTY, TODDLER, CLOAK]

const DIRS: Array[StringName] = [&"n", &"e", &"s", &"w"]

## Hide kinds: [capacity, eye height cm, gap half-angle degrees, gap range cm (0: no limit)].
const HIDE_SPEC := {
	&"pit": [3, 30, 180, 400],
	&"slide": [2, 60, 20, 0],
	&"den": [1, 70, 40, 0],
	&"playhouse": [1, 100, 25, 0],
	&"table": [2, 30, 60, 0],
	&"chest": [1, 50, 30, 0],
	&"cubby": [1, 140, 15, 0],
}
## A hide against a wall: its inside spot is WALL_INSET from the wall, its front FRONT_REACH further in.
const WALL_INSET := 50
const FRONT_REACH := 70
## Seats: this far either side of the table's long centre line, at these offsets along it.
const SEAT_ACROSS := 100
const SEAT_ALONG: Array[int] = [-135, -45, 45, 135]

# ---------------------------------------------------------------------------------------------
# What the floor's lists hold.

## A hiding place. Positions are whole centimetres: x is world x, y is world z (cell * 200 + offset).
class Hide:
	var id: int
	var zone: int
	var room: int
	var level: int
	## &"pit" | &"slide" | &"den" | &"playhouse" | &"table" | &"chest" | &"cubby"
	var kind: StringName
	var capacity: int
	## Where a body inside is.
	var inside: Vector2i
	## Where the Minder must stand to look in: a walkable spot in the same room, FRONT_REACH from inside.
	var front: Vector2i
	## Eye height when peeking, cm.
	var eye: int
	## Which way the gap faces (into the room), and how far it opens either side.
	var gap: StringName
	var gap_half: int
	## How far a peeker sees through the gap, cm; 0 for no limit but the room.
	var gap_range: int

## A zone: one block on one level (the party room and its stores are one block). Zone ids are block
## ids: level * n * n + row * n + column, row-major in the plan as generated (after the symmetry).
class Zone:
	var id: int
	var level: int
	var c: int
	var r: int
	## &"ballpit" | &"frame" | &"party" | &"toddler" | &"cloak" | &"nook" | &"deck" | &"upper"
	var kind: StringName
	## The block's cells.
	var rect: Rect2i
	var rooms: PackedInt32Array
	## Indices into plan.doors of the doors joining the zone to a walkway: its ways in.
	var doors: PackedInt32Array
	## The number on the zone's sign: its hide count.
	var hides: int

## A seat at the party table, where a taken player wakes.
class Seat:
	var index: int
	var level: int
	var at: Vector2i
	## Which way the seated player faces: towards the table and across the party room.
	var facing: StringName

## The lattice and blocks read back from a plan.
class Layout:
	var lat: Annex.Lattice
	## Per level, per segment: 1 if the segment's cells are walkway.
	var present: Array[PackedByteArray] = []
	var zone_ids: PackedInt32Array = PackedInt32Array()
	## zone id -> PackedInt32Array of room ids, ascending.
	var zone_rooms: Dictionary = {}
	## room id -> zone id, or -1 (the lobby).
	var room_zone: PackedInt32Array = PackedInt32Array()

static func opposite(d: StringName) -> StringName:
	match d:
		&"n":
			return &"s"
		&"e":
			return &"w"
		&"s":
			return &"n"
		_:
			return &"e"

static func playroom_size(depth: int) -> Vector2i:
	return Clinic.clinic_size(depth)

static func _root(floor_seed: String, depth: int) -> Rng:
	return Rng.make_rng("playroom:%s:%d" % [floor_seed, depth])

# ---------------------------------------------------------------------------------------------
# Pruning: 15% of the segments, and the walkway stays free of cut junctions and cut segments.

## Whether the present segments join every junction into one piece with no bridge and no junction
## whose removal splits the rest (Tarjan, iterative).
static func _biconnected(lat: Annex.Lattice, present: PackedByteArray) -> bool:
	var nj := (lat.n + 1) * (lat.n + 1)
	var disc := PackedInt32Array()
	disc.resize(nj)
	disc.fill(-1)
	var low := PackedInt32Array()
	low.resize(nj)
	var st_node := PackedInt32Array([0])
	var st_edge := PackedInt32Array([-1])
	var st_next := PackedInt32Array([0])
	disc[0] = 0
	low[0] = 0
	var timer := 1
	var root_children := 0
	while not st_node.is_empty():
		var top := st_node.size() - 1
		var u := st_node[top]
		var segs: PackedInt32Array = lat.junction_segs[u]
		var k := st_next[top]
		if k < segs.size():
			st_next[top] = k + 1
			var e := segs[k]
			if present[e] == 0 or e == st_edge[top]:
				continue
			var w := lat.seg_a[e] if lat.seg_b[e] == u else lat.seg_b[e]
			if disc[w] == -1:
				disc[w] = timer
				low[w] = timer
				timer += 1
				if top == 0:
					root_children += 1
				st_node.append(w)
				st_edge.append(e)
				st_next.append(0)
			else:
				low[u] = mini(low[u], disc[w])
		else:
			st_node.resize(top)
			st_edge.resize(top)
			st_next.resize(top)
			if top > 0:
				var p := st_node[top - 1]
				low[p] = mini(low[p], low[u])
				if low[u] > disc[p]:
					return false  # a bridge
				if top - 1 > 0 and low[u] >= disc[p]:
					return false  # p is a cut junction
	if root_children > 1:
		return false
	for i in nj:
		if disc[i] == -1:
			return false
	return true

static func _ring(lat: Annex.Lattice) -> PackedByteArray:
	var keep := PackedByteArray()
	keep.resize(lat.count)
	for i in lat.n:
		keep[lat.h(i, 0)] = 1
		keep[lat.h(i, lat.n)] = 1
		keep[lat.v(0, i)] = 1
		keep[lat.v(lat.n, i)] = 1
	return keep

## Removes segments in a seeded order until PRUNE_PERCENT are gone (one pass, as the Annex does).
static func _prune(lat: Annex.Lattice, rng: Rng, protected: PackedByteArray) -> PackedByteArray:
	var present := PackedByteArray()
	present.resize(lat.count)
	present.fill(1)
	var order: Array = []
	for s in lat.count:
		order.append(s)
	var target := lat.count * PRUNE_PERCENT / 100
	var removed := 0
	for s: int in Clinic._shuffled(rng, order):
		if removed >= target:
			break
		if protected[s] == 1:
			continue
		var blocks_ok := true
		for bl in lat.blocks_of(s):
			if Annex._sides_left(lat, present, bl.x, bl.y) <= 2:
				blocks_ok = false
		if not blocks_ok:
			continue
		present[s] = 0
		if not _biconnected(lat, present):
			present[s] = 1
			continue
		removed += 1
	return present

# ---------------------------------------------------------------------------------------------
# Block templates, in the Annex's local frame (front to the south, local row 6 is the front walkway,
# row -1 the back walkway), turned to face the first side of south, north, east, west with walkway.

static func _stamp(b: Clinic.Builder, lat: Annex.Lattice, present: PackedByteArray, level: int, c: int, r: int, t: int) -> void:
	var s := Annex.Stamp.new()
	s.b = b
	s.level = level
	s.origin = lat.block_origin(c, r)
	s.front = Annex._front_for(lat, present, c, r)
	var back := Annex._local_side(lat, present, c, r, s.front, 0, -1)
	var west := Annex._local_side(lat, present, c, r, s.front, -1, 3)
	var east := Annex._local_side(lat, present, c, r, s.front, 6, 2)
	match t:
		BALLPIT, TODDLER, DECK:
			# One open 6 by 6 room with a way in on every side that has walkway.
			var kind := &"ballpit" if t == BALLPIT else (&"toddler" if t == TODDLER else &"deck")
			s.room(kind, 0, 0, 6, 6)
			s.door(2, 5, 2, 6)
			if back:
				s.door(3, 0, 3, -1)
			if west:
				s.door(0, 3, -1, 3)
			if east:
				s.door(5, 2, 6, 2)
		FRAME, UPPER:
			# Four 3 by 3 crawl dens, linked in a ring by low doors; each den also opens on the walkway
			# beside it: the front two on the front, the others on the back and sides that have walkway.
			s.room(&"den", 0, 0, 3, 3)
			s.room(&"den", 3, 0, 3, 3)
			s.room(&"den", 0, 3, 3, 3)
			s.room(&"den", 3, 3, 3, 3)
			s.door(1, 5, 1, 6)
			s.door(4, 5, 4, 6)
			if back:
				s.door(1, 0, 1, -1)
				s.door(4, 0, 4, -1)
			if west:
				s.door(0, 1, -1, 1)
				s.door(0, 4, -1, 4)
			if east:
				s.door(5, 1, 6, 1)
				s.door(5, 4, 6, 4)
			s.door(2, 1, 3, 1)
			s.door(2, 4, 3, 4)
			s.door(1, 2, 1, 3)
			s.door(4, 2, 4, 3)
		PARTY:
			# A 6 by 4 party room with two front doors, two 3 by 2 stores behind it; each store has a back
			# door onto the back walkway when there is one.
			s.room(&"party", 0, 2, 6, 4)
			s.door(1, 5, 1, 6)
			s.door(4, 5, 4, 6)
			s.room(&"store", 0, 0, 3, 2)
			s.door(1, 1, 1, 2)
			s.room(&"store", 3, 0, 3, 2)
			s.door(4, 1, 4, 2)
			if back:
				s.door(1, 0, 1, -1)
				s.door(4, 0, 4, -1)
		CLOAK:
			# A 4 by 6 cloakroom with front and back doors (the back when it has walkway), and a 2 by 6
			# store off it, with its own door onto the east walkway when there is one. The west wall has
			# no door: the six coat cubbies stand along it.
			s.room(&"cloak", 0, 0, 4, 6)
			s.door(2, 5, 2, 6)
			if back:
				s.door(1, 0, 1, -1)
			s.room(&"store", 4, 0, 2, 6)
			s.door(3, 3, 4, 3)
			if east:
				s.door(5, 2, 6, 2)

## Whether a block has a ball pit or a stair block on any side (where a ball pit may not go).
static func _pit_beside(kind_of: Dictionary, bl: Vector2i) -> bool:
	for st in Floor.STEPS:
		var k: int = kind_of.get(bl + st, -1)
		if k == BALLPIT or k == STAIRS:
			return true
	return false

static func _template_rooms(t: int) -> int:
	match t:
		FRAME, UPPER:
			return 4
		PARTY:
			return 3
		CLOAK:
			return 2
		STAIRS:
			return 0
		_:
			return 1

# ---------------------------------------------------------------------------------------------
# Layout.

static func _lay_out(floor_seed: String, depth: int, W: int, H: int) -> Clinic.Canonical:
	var root := _root(floor_seed, depth)
	var shape := root.fork("shape")
	var b := Clinic._new_builder(W, H)
	b.budget = Clinic.UNLIMITED

	# --- The lattice, against the north margin; seeded across.
	var n := Annex.blocks_per_side(W)
	var L := PITCH * n + 1
	var lat := Annex._make_lattice(n, shape.int_in(MARGIN, W - MARGIN - L), MARGIN)
	var spine_y := lat.y0 + PITCH * n
	var all_blocks: Array = []
	for r in n:
		for c in n:
			all_blocks.append(Vector2i(c, r))

	# --- Two stair blocks, at least two blocks apart.
	var stairs_rng := root.fork("stairs")
	var stair_blocks: Array[Annex.StairBlock] = []
	var kind_of := {}  # Vector2i -> template
	for bl: Vector2i in Clinic._shuffled(stairs_rng, all_blocks):
		if stair_blocks.size() >= 2:
			break
		var apart := true
		for sb in stair_blocks:
			if maxi(absi(sb.c - bl.x), absi(sb.r - bl.y)) < 2:
				apart = false
		if not apart:
			continue
		var sb := Annex.StairBlock.new()
		sb.c = bl.x
		sb.r = bl.y
		sb.front = DIRS[stairs_rng.int_in(0, 3)]
		sb.column = Annex.STAIR_COLUMNS[stairs_rng.int_in(0, Annex.STAIR_COLUMNS.size() - 1)]
		stair_blocks.append(sb)
		kind_of[bl] = STAIRS

	# --- Templates. A party room on the far row (the Minder's start, far from the lift), one each of
	# the other four kinds, then the rest dealt from a deck of the five, reshuffled when it runs out.
	var br := root.fork("blocks")
	var far_row: Array = []
	for c in n:
		if not kind_of.has(Vector2i(c, 0)):
			far_row.append(Vector2i(c, 0))
	var party_at: Vector2i = br.pick(far_row)
	kind_of[party_at] = PARTY
	var free: Array = []
	for bl: Vector2i in all_blocks:
		if not kind_of.has(bl):
			free.append(bl)
	var must: Array[int] = [BALLPIT, FRAME, TODDLER, CLOAK]
	var dealt: Array = Clinic._shuffled(br, free)
	for k in must:
		for bl: Vector2i in dealt:
			if not kind_of.has(bl) and (k != BALLPIT or not _pit_beside(kind_of, bl)):
				kind_of[bl] = k
				break
	# No ball pit beside another or beside a stair block: two holes in a row on level 1 leave a long
	# balcony with no hide near it. A ball pit dealt there waits in the deck for a later block.
	var deck: Array = []
	for bl: Vector2i in all_blocks:
		if kind_of.has(bl):
			continue
		if deck.is_empty():
			deck = Clinic._shuffled(br, KINDS)
		var at := deck.size() - 1
		if _pit_beside(kind_of, bl):
			while at >= 0 and (deck[at] as int) == BALLPIT:
				at -= 1
			if at < 0:
				deck = Clinic._shuffled(br, KINDS) + deck
				at = deck.size() - 1
				while (deck[at] as int) == BALLPIT:
					at -= 1
		kind_of[bl] = deck.pop_at(at)

	# --- Protected segments: the outer ring on both levels, each stair's foot (level 0) and head
	# (level 1) segment, the balcony round each ball pit (level 1).
	var keep0 := _ring(lat)
	var keep1 := _ring(lat)
	for sb in stair_blocks:
		keep0[lat.side(sb.c, sb.r, Annex._side_of(Annex._map(sb.front, 0, BLOCK)))] = 1
		keep1[lat.side(sb.c, sb.r, Annex._side_of(Annex._map(sb.front, 0, -1)))] = 1
	for bl: Vector2i in all_blocks:
		if (kind_of[bl] as int) == BALLPIT:
			for d in DIRS:
				keep1[lat.side(bl.x, bl.y, d)] = 1

	var present0 := _prune(lat, root.fork("prune0"), keep0)
	var present1 := _prune(lat, root.fork("prune1"), keep1)

	# --- Walkways: every junction, and every segment still present.
	var presents: Array[PackedByteArray] = [present0, present1]
	for level in 2:
		for j in n + 1:
			for i in n + 1:
				Clinic._set_cell(b, level, lat.x0 + PITCH * i, lat.y0 + PITCH * j, Floor.CORRIDOR)
		for s in lat.count:
			if presents[level][s] == 1:
				for cell in lat.cells(s):
					Clinic._set_cell(b, level, cell.x, cell.y, Floor.CORRIDOR)

	# --- The lift lobby (the shoe room) off the south line: 5 wide, 3 deep, two doors. The landing,
	# the shaft and the car zone as in the Annex.
	var lx := shape.int_in(lat.x0 + 2, lat.x0 + L - 3 - (LOBBY_W - 1))
	var lobby := Clinic._add_room(b, 0, &"lobby", lx, spine_y + 1, LOBBY_W, LOBBY_D)
	Clinic._add_door(b, 0, lx, spine_y, lx, spine_y + 1)
	Clinic._add_door(b, 0, lx + LOBBY_W - 1, spine_y, lx + LOBBY_W - 1, spine_y + 1)
	var landing := Floor.Pos.make(0, lx + LOBBY_W / 2, lobby.y + lobby.h - 1)
	Clinic._set_cell(b, 0, landing.x, landing.y, Floor.LANDING)
	b.reserved[1][landing.y * W + landing.x] = 1
	for level in 2:
		for dy in range(1, SHAFT_D + 1):
			for dx in range(-(SHAFT_W / 2), SHAFT_W / 2 + 1):
				b.reserved[level][(landing.y + dy) * W + landing.x + dx] = 1

	# --- The soft steps: the Annex's stair block (4 cells climbing from the front edge, a two-cell
	# stub on level 1 joining the head to the back walkway).
	for sb in stair_blocks:
		var o := lat.block_origin(sb.c, sb.r)
		var start := o + Annex._map(sb.front, sb.column, BLOCK - 1)
		var next := o + Annex._map(sb.front, sb.column, BLOCK - 2)
		var stair := Floor.Stair.make(start.x, start.y, Floor.dir_from_vec(next.x - start.x, next.y - start.y), STAIR_LENGTH)
		b.stairs.append(stair)
		for cell in Floor.stair_cells(stair):
			Clinic._set_cell(b, 0, cell.x, cell.y, Floor.STAIR)
			Clinic._set_cell(b, 1, cell.x, cell.y, Floor.STAIR)
		for ly: int in [0, 1]:
			var p := o + Annex._map(sb.front, sb.column, ly)
			Clinic._set_cell(b, 1, p.x, p.y, Floor.CORRIDOR)
		# The nook beside the steps, on both levels: a 4 by 6 den across the block from the stair's
		# column, a way in on every side that has walkway (the stair's side has none).
		var nx := 2 if sb.column <= 1 else 0
		for level in 2:
			var st := Annex.Stamp.new()
			st.b = b
			st.level = level
			st.origin = o
			st.front = sb.front
			st.room(&"nook", nx, 0, 4, 6)
			if Annex._local_side(lat, presents[level], sb.c, sb.r, sb.front, 0, BLOCK):
				st.door(nx + 1, 5, nx + 1, 6)
			if Annex._local_side(lat, presents[level], sb.c, sb.r, sb.front, 0, -1):
				st.door(nx + 2, 0, nx + 2, -1)
			if sb.column <= 1 and Annex._local_side(lat, presents[level], sb.c, sb.r, sb.front, BLOCK, 3):
				st.door(5, 3, 6, 3)
			if sb.column > 1 and Annex._local_side(lat, presents[level], sb.c, sb.r, sb.front, -1, 2):
				st.door(0, 2, -1, 2)

	# --- Level 0: every block from its template; a ball pit is an opening on level 1.
	for bl: Vector2i in all_blocks:
		var t: int = kind_of[bl]
		if t == STAIRS:
			continue
		_stamp(b, lat, present0, 0, bl.x, bl.y, t)
		if t == BALLPIT:
			Annex._stamp_atrium(b, lat, present1, 1, bl.x, bl.y)

	# --- Level 1: a deck over every other block while the budget lasts, then the frames' upper
	# storeys (four dens) in the same seeded order while it still lasts.
	var candidates: Array = []
	for bl: Vector2i in all_blocks:
		var t: int = kind_of[bl]
		if t != STAIRS and t != BALLPIT:
			candidates.append(bl)
	var upper_order: Array = Clinic._shuffled(br, candidates)
	var budget := MAX_ROOMS - b.rooms.size()
	var upper := {}
	for bl: Vector2i in upper_order:
		if budget < _template_rooms(DECK):
			break
		upper[bl] = DECK
		budget -= _template_rooms(DECK)
	for bl: Vector2i in upper_order:
		var extra := _template_rooms(UPPER) - _template_rooms(DECK)
		if upper.has(bl) and (kind_of[bl] as int) == FRAME and budget >= extra:
			upper[bl] = UPPER
			budget -= extra
	for bl: Vector2i in all_blocks:
		if upper.has(bl):
			_stamp(b, lat, present1, 1, bl.x, bl.y, upper[bl] as int)

	var out := Clinic.Canonical.new()
	out.b = b
	out.landing = landing
	return out

# ---------------------------------------------------------------------------------------------

## generate_playroom(seed, depth): the Playroom floor for this seed and depth, at the Clinic's size.
static func generate_playroom(floor_seed: String, depth: int) -> Floor.FloorPlan:
	var size := playroom_size(depth)
	var W := size.x
	var H := size.y
	var root := _root(floor_seed, depth)
	var canon := _lay_out(floor_seed, depth, W, H)
	var pick := root.fork("orient").int_in(0, Clinic._symmetry_count(W, H) - 1)
	var t := Clinic._transform(canon.b, canon.landing, pick)
	var b := t.b

	var plan := Floor.FloorPlan.new()
	plan.place = PLACE
	plan.seed = floor_seed
	plan.depth = depth
	plan.width = W
	plan.height = H
	plan.cell_size = CELL_SIZE
	plan.cells = b.cells
	plan.rooms = b.rooms
	plan.doors = b.doors
	plan.stairs = b.stairs
	plan.landing = t.landing
	plan.entity_start = t.landing
	plan.sightlines = []

	# Side branches (repeated from clinic.gd generate_clinic, where it is inline).
	var room_at := func(d: Floor.Door, end: String) -> int:
		var x := d.ax if end == "a" else d.bx
		var y := d.ay if end == "a" else d.by
		for rr in b.rooms:
			if rr.level == d.level and x >= rr.x and x < rr.x + rr.w and y >= rr.y and y < rr.y + rr.h:
				return rr.id
		return -1
	for group in Floor.side_branches(b.rooms, b.doors, room_at):
		for id in group:
			if id >= 0 and id < b.rooms.size():
				b.rooms[id].branch = &"side"

	plan.sightlines = Floor.find_sightlines(plan, MIN_SIGHTLINE)
	plan.entity_start = _choose_entity_start(plan, root.fork("entity"))
	return plan

# ---------------------------------------------------------------------------------------------
# The party room and the entity start.

## The side of a party room its stores are on (the back wall), or &"".
static func _back_of(plan: Floor.FloorPlan, room: Floor.Room) -> StringName:
	for d in plan.doors:
		if d.level != room.level:
			continue
		var ra := Floor.room_id_at(plan, d.level, d.ax, d.ay)
		var rb := Floor.room_id_at(plan, d.level, d.bx, d.by)
		if ra == room.id and rb >= 0 and plan.rooms[rb].kind == &"store":
			return Floor.dir_from_vec(d.bx - d.ax, d.by - d.ay)
		if rb == room.id and ra >= 0 and plan.rooms[ra].kind == &"store":
			return Floor.dir_from_vec(d.ax - d.bx, d.ay - d.by)
	return &""

## The two middle cells of a room's row against its `back` wall.
static func _back_middle(room: Floor.Room, back: StringName) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if back == &"n" or back == &"s":
		var y := room.y if back == &"n" else room.y + room.h - 1
		out.append(Vector2i(room.x + room.w / 2 - 1, y))
		out.append(Vector2i(room.x + room.w / 2, y))
	else:
		var x := room.x if back == &"w" else room.x + room.w - 1
		out.append(Vector2i(x, room.y + room.h / 2 - 1))
		out.append(Vector2i(x, room.y + room.h / 2))
	return out

## The party room farthest from the landing by walking (steps to its nearest cell; the lowest room id
## on a tie), standing at one of the two middle cells between the table and the back wall (seeded),
## facing the wall.
static func _choose_entity_start(plan: Floor.FloorPlan, rng: Rng) -> Floor.Pos:
	var dist := Floor.distances_from(plan, plan.landing)
	var best := -1
	var best_cells: Array[Vector2i] = []
	var best_level := 0
	for room in plan.rooms:
		if room.kind != &"party":
			continue
		var back := _back_of(plan, room)
		if back == &"":
			continue
		var d := 1 << 30
		for y in range(room.y, room.y + room.h):
			for x in range(room.x, room.x + room.w):
				var k := dist[Floor.pos_index(plan, Floor.Pos.make(room.level, x, y))]
				if k >= 0:
					d = mini(d, k)
		if d < (1 << 30) and d > best:
			best = d
			best_cells = _back_middle(room, back)
			best_level = room.level
	if best_cells.is_empty():
		push_error("playroom %s/%d: no party room" % [plan.seed, plan.depth])
		return plan.landing
	var c := best_cells[rng.int_in(0, 1)]
	return Floor.Pos.make(best_level, c.x, c.y)

## The room the Minder starts in, where taken players sit: the far-end party room.
static func party_room(plan: Floor.FloorPlan) -> Floor.Room:
	var id := Floor.room_id_at(plan, plan.entity_start.level, plan.entity_start.x, plan.entity_start.y)
	return plan.rooms[id] if id >= 0 else null

## Which way the Minder faces at its start: the back wall of its party room.
static func entity_facing(plan: Floor.FloorPlan) -> StringName:
	var room := party_room(plan)
	return _back_of(plan, room) if room != null else &"n"

# ---------------------------------------------------------------------------------------------
# Reading the lattice and blocks back from a plan.

## The lattice from the plan: the outer ring is never pruned, so the bounding box of level 0's
## walkway is the lattice. Null if the plan has no square lattice.
static func layout_of(plan: Floor.FloorPlan) -> Layout:
	var x0 := plan.width
	var y0 := plan.height
	var x1 := -1
	var y1 := -1
	for y in plan.height:
		for x in plan.width:
			if Floor.cell_at(plan, 0, x, y) == Floor.CORRIDOR:
				x0 = mini(x0, x)
				y0 = mini(y0, y)
				x1 = maxi(x1, x)
				y1 = maxi(y1, y)
	var w := x1 - x0 + 1
	if w != y1 - y0 + 1 or w < 1 or (w - 1) % PITCH != 0:
		push_error("playroom %s/%d: no square lattice" % [plan.seed, plan.depth])
		return null
	var n := (w - 1) / PITCH
	var lay := Layout.new()
	lay.lat = Annex._make_lattice(n, x0, y0)
	for level in 2:
		var pr := PackedByteArray()
		pr.resize(lay.lat.count)
		for s in lay.lat.count:
			var all := 1
			for cell in lay.lat.cells(s):
				if Floor.cell_at(plan, level, cell.x, cell.y) != Floor.CORRIDOR:
					all = 0
			pr[s] = all
		lay.present.append(pr)
	lay.room_zone.resize(plan.rooms.size())
	lay.room_zone.fill(-1)
	for room in plan.rooms:
		var c := (room.x - x0 - 1) / PITCH
		var r := (room.y - y0 - 1) / PITCH
		if room.x <= x0 or room.y <= y0 or c >= n or r >= n:
			continue
		var o := lay.lat.block_origin(c, r)
		if room.x + room.w > o.x + BLOCK or room.y + room.h > o.y + BLOCK:
			continue
		var zid := room.level * n * n + r * n + c
		lay.room_zone[room.id] = zid
		if not lay.zone_rooms.has(zid):
			lay.zone_rooms[zid] = PackedInt32Array()
		var list: PackedInt32Array = lay.zone_rooms[zid]
		list.append(room.id)
		lay.zone_rooms[zid] = list
	for zid in 2 * n * n:
		if lay.zone_rooms.has(zid):
			lay.zone_ids.append(zid)
	return lay

static func _zone_kind(plan: Floor.FloorPlan, rooms: PackedInt32Array) -> StringName:
	var has := {}
	for id in rooms:
		has[plan.rooms[id].kind] = true
	if has.has(&"party"):
		return &"party"
	if has.has(&"cloak"):
		return &"cloak"
	if has.has(&"ballpit"):
		return &"ballpit"
	if has.has(&"toddler"):
		return &"toddler"
	if has.has(&"deck"):
		return &"deck"
	if has.has(&"nook"):
		return &"nook"
	return &"frame" if plan.rooms[rooms[0]].level == 0 else &"upper"

## Every cell at either end of a door, as pos_index values.
static func _door_cells(plan: Floor.FloorPlan) -> Dictionary:
	var out := {}
	for d in plan.doors:
		out[Floor.pos_index(plan, Floor.Pos.make(d.level, d.ax, d.ay))] = true
		out[Floor.pos_index(plan, Floor.Pos.make(d.level, d.bx, d.by))] = true
	return out

static func cell_of(p: Vector2i) -> Vector2i:
	return Vector2i(p.x / CM, p.y / CM)

# ---------------------------------------------------------------------------------------------
# Hides.

## Wall slots of a room: Vector3i(x, y, wall direction index), for every edge cell that is not a
## door cell, on every side where the room ends; rows top to bottom, cells left to right, n e s w.
static func _slots(plan: Floor.FloorPlan, room: Floor.Room, doors: Dictionary) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for y in range(room.y, room.y + room.h):
		for x in range(room.x, room.x + room.w):
			if doors.has(Floor.pos_index(plan, Floor.Pos.make(room.level, x, y))):
				continue
			for k in 4:
				var nx := x + Floor.dir_dx(DIRS[k])
				var ny := y + Floor.dir_dy(DIRS[k])
				if nx < room.x or ny < room.y or nx >= room.x + room.w or ny >= room.y + room.h:
					out.append(Vector3i(x, y, k))
	return out

## A seeded free wall slot of the room (its cell not yet used), or Vector3i(-1, -1, -1).
static func _take(rng: Rng, plan: Floor.FloorPlan, room: Floor.Room, doors: Dictionary, used: Dictionary) -> Vector3i:
	var slots: Array = []
	for s in _slots(plan, room, doors):
		slots.append(s)
	for s: Vector3i in Clinic._shuffled(rng, slots):
		if not used.has(Vector2i(s.x, s.y)):
			return s
	return Vector3i(-1, -1, -1)

static func _add(out: Array[Hide], used: Dictionary, kind: StringName, zone: int, room: Floor.Room, inside: Vector2i, gap: StringName) -> void:
	var spec: Array = HIDE_SPEC[kind]
	var h := Hide.new()
	h.id = out.size()
	h.zone = zone
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
	out.append(h)
	used[cell_of(h.inside)] = true
	used[cell_of(h.front)] = true

## A hide against the wall of a slot: inside WALL_INSET from the wall, the gap facing into the room.
static func _add_at_wall(out: Array[Hide], used: Dictionary, kind: StringName, zone: int, room: Floor.Room, slot: Vector3i) -> void:
	if slot.x < 0:
		push_error("playroom: no free wall slot in room %d for a %s" % [room.id, kind])
		return
	var wall := DIRS[slot.z]
	var centre := Vector2i(slot.x * CM + CM / 2, slot.y * CM + CM / 2)
	var inside := centre + Vector2i(Floor.dir_dx(wall), Floor.dir_dy(wall)) * (CM / 2 - WALL_INSET)
	_add(out, used, kind, zone, room, inside, opposite(wall))

static func _centre(room: Floor.Room) -> Vector2i:
	return Vector2i(room.x * CM + room.w * CM / 2, room.y * CM + room.h * CM / 2)

## hides(plan, seed): every hiding place on the floor, zone by zone (ascending zone id), from each
## room's shape and doors, the seed choosing which optional ones exist and where. `floor_seed` "" means
## plan.seed. Rng fork "hides", one sub-fork per zone.
static func hides(plan: Floor.FloorPlan, floor_seed: String = "") -> Array[Hide]:
	var out: Array[Hide] = []
	var lay := layout_of(plan)
	if lay == null:
		return out
	var root := _root(floor_seed if floor_seed != "" else plan.seed, plan.depth).fork("hides")
	var doors := _door_cells(plan)
	for zid in lay.zone_ids:
		var ids: PackedInt32Array = lay.zone_rooms[zid]
		var rooms: Array[Floor.Room] = []
		for id in ids:
			rooms.append(plan.rooms[id])
		var kind := _zone_kind(plan, ids)
		var zr := root.fork("zone:%d" % zid)
		var used := {}
		match kind:
			&"ballpit":
				# The pit (holds 3) in the middle, two tube-slide mouths that end in it.
				var pit := rooms[0]
				_add(out, used, &"pit", zid, pit, _centre(pit), DIRS[zr.int_in(0, 3)])
				for i in 2:
					_add_at_wall(out, used, &"slide", zid, pit, _take(zr, plan, pit, doors, used))
			&"deck":
				# A crawl den beside every way in (two to four), then a tube slide's top anywhere.
				var deck := rooms[0]
				for d in plan.doors:
					var inner := _way_in_cell(plan, deck, d)
					if inner.x < 0:
						continue
					var near: Array = []
					for s in _slots(plan, deck, doors):
						if absi(s.x - inner.x) + absi(s.y - inner.y) == 1 and not used.has(Vector2i(s.x, s.y)):
							near.append(s)
					var slot: Vector3i = zr.pick(near) if not near.is_empty() else _take(zr, plan, deck, doors, used)
					_add_at_wall(out, used, &"den", zid, deck, slot)
				_add_at_wall(out, used, &"slide", zid, deck, _take(zr, plan, deck, doors, used))
			&"frame", &"upper":
				# Two or three crawl dens, each in a different den where there are four; then a playhouse
				# (frame) or a tube slide's top (upper storey, deck) in a seeded den.
				var k := zr.int_in(2, 3)
				var order: Array = []
				for i in rooms.size():
					order.append(i)
				var picks: Array = Clinic._shuffled(zr, order)
				for i in k:
					var room := rooms[(picks[i] as int) if rooms.size() > 1 else 0]
					_add_at_wall(out, used, &"den", zid, room, _take(zr, plan, room, doors, used))
				var last := rooms[zr.int_in(0, rooms.size() - 1)]
				_add_at_wall(out, used, &"playhouse" if kind == &"frame" else &"slide", zid, last, _take(zr, plan, last, doors, used))
			&"nook":
				# The nook beside the soft steps: a crawl den and a toy chest.
				_add_at_wall(out, used, &"den", zid, rooms[0], _take(zr, plan, rooms[0], doors, used))
				_add_at_wall(out, used, &"chest", zid, rooms[0], _take(zr, plan, rooms[0], doors, used))
			&"toddler":
				for i in 2:
					_add_at_wall(out, used, &"playhouse", zid, rooms[0], _take(zr, plan, rooms[0], doors, used))
			&"party":
				# The party table (holds 2) in the middle of the party room, its hem's gap towards one long
				# side; a toy chest in each store.
				for room in rooms:
					if room.kind == &"party":
						var pick := zr.int_in(0, 1)
						var gap := (&"n" if pick == 0 else &"s") if room.w > room.h else (&"e" if pick == 0 else &"w")
						_add(out, used, &"table", zid, room, _centre(room), gap)
				for room in rooms:
					if room.kind == &"store":
						_add_at_wall(out, used, &"chest", zid, room, _take(zr, plan, room, doors, used))
			&"cloak":
				# Six coat cubbies along the long wall with no door; the seed says which three or four are
				# deep enough to hide in. A toy chest in the store, or not.
				for room in rooms:
					if room.kind != &"cloak":
						continue
					var wall := _cubby_wall(plan, room, doors)
					var k := zr.int_in(3, 4)
					var idx: Array = []
					for i in wall.size():
						idx.append(i)
					var chosen := {}
					var shuffled: Array = Clinic._shuffled(zr, idx)
					for i in k:
						chosen[shuffled[i]] = true
					for i in wall.size():
						if chosen.has(i):
							_add_at_wall(out, used, &"cubby", zid, room, wall[i])
				for room in rooms:
					if room.kind == &"store" and zr.int_in(0, 1) == 1:
						_add_at_wall(out, used, &"chest", zid, room, _take(zr, plan, room, doors, used))
	return out

## The room's cell of a door from a walkway into `room`, or Vector2i(-1, -1) if `d` is not one.
static func _way_in_cell(plan: Floor.FloorPlan, room: Floor.Room, d: Floor.Door) -> Vector2i:
	if d.level != room.level:
		return Vector2i(-1, -1)
	var a_in := Floor.room_id_at(plan, d.level, d.ax, d.ay) == room.id
	var b_in := Floor.room_id_at(plan, d.level, d.bx, d.by) == room.id
	if a_in and Floor.cell_at(plan, d.level, d.bx, d.by) == Floor.CORRIDOR:
		return Vector2i(d.ax, d.ay)
	if b_in and Floor.cell_at(plan, d.level, d.ax, d.ay) == Floor.CORRIDOR:
		return Vector2i(d.bx, d.by)
	return Vector2i(-1, -1)

## The cubby wall: the first side (n, e, s, w) of the room's long dimension whose every cell has a wall
## slot facing that side; its slots in order along it.
static func _cubby_wall(plan: Floor.FloorPlan, room: Floor.Room, doors: Dictionary) -> Array[Vector3i]:
	var slots := _slots(plan, room, doors)
	var long := maxi(room.w, room.h)
	for k in 4:
		var along: Array[Vector3i] = []
		for s in slots:
			if s.z == k:
				along.append(s)
		if along.size() == long:
			return along
	var none: Array[Vector3i] = []
	push_error("playroom: cloakroom %d has no cubby wall" % room.id)
	return none

# ---------------------------------------------------------------------------------------------
# Squeaker tiles.

## squeakers(plan, seed): the squeaker tiles, as pos_index values, ascending. A seeded third of the
## cells of every toddler corner, keeping its quiet cells joined; and one walkway cell in six of those
## at least half the farthest walking distance from the lift, a squeaker only where the walkway still
## has a quiet loop without that segment. Never in the lobby, on a door's cells, on a hide's inside or
## front spot, on a junction or at a stair's ends. `floor_seed` "" means plan.seed. Rng fork "squeak".
static func squeakers(plan: Floor.FloorPlan, floor_seed: String = "") -> PackedInt32Array:
	var out := PackedInt32Array()
	var lay := layout_of(plan)
	if lay == null:
		return out
	var sd := floor_seed if floor_seed != "" else plan.seed
	var rng := _root(sd, plan.depth).fork("squeak")
	var n_cells := plan.width * plan.height
	var forbidden := _door_cells(plan)
	for h in hides(plan, sd):
		for p: Vector2i in [cell_of(h.inside), cell_of(h.front)]:
			forbidden[h.level * n_cells + p.y * plan.width + p.x] = true
	for room in plan.rooms:
		if room.kind == &"lobby":
			for y in range(room.y, room.y + room.h):
				for x in range(room.x, room.x + room.w):
					forbidden[Floor.pos_index(plan, Floor.Pos.make(room.level, x, y))] = true
	for s in plan.stairs:
		# The foot's walkway cell; the head, its stub and the walkway cell the stub joins.
		forbidden[Floor.pos_index(plan, Floor.stair_bottom(s))] = true
		var top := Floor.stair_top(s)
		for i in 3:
			forbidden[Floor.pos_index(plan, Floor.Pos.make(1, top.x + Floor.dir_dx(s.dir) * i, top.y + Floor.dir_dy(s.dir) * i))] = true
	var lat := lay.lat
	for level in 2:
		for j in lat.n + 1:
			for i in lat.n + 1:
				forbidden[level * n_cells + (lat.y0 + PITCH * j) * plan.width + lat.x0 + PITCH * i] = true
	var mask := PackedByteArray()
	mask.resize(2 * n_cells)

	# --- Toddler corners, in room order.
	for room in plan.rooms:
		if room.kind != &"toddler":
			continue
		var room_cands: Array = []
		for y in range(room.y, room.y + room.h):
			for x in range(room.x, room.x + room.w):
				var k := Floor.pos_index(plan, Floor.Pos.make(room.level, x, y))
				if not forbidden.has(k):
					room_cands.append(k)
		var room_target := room.w * room.h / 3
		var room_placed := 0
		for k: int in Clinic._shuffled(rng, room_cands):
			if room_placed >= room_target:
				break
			mask[k] = 1
			if _room_quiet_joined(plan, room, mask):
				room_placed += 1
			else:
				mask[k] = 0

	# --- Walkways far from the lift.
	var dist := Floor.distances_from(plan, plan.landing)
	var seg_of := {}  # pos_index -> segment
	var far := 0
	for level in 2:
		for s in lat.count:
			if lay.present[level][s] == 0:
				continue
			for cell in lat.cells(s):
				var k := level * n_cells + cell.y * plan.width + cell.x
				seg_of[k] = s
				far = maxi(far, dist[k])
	var cands: Array = []
	for k in 2 * n_cells:
		if seg_of.has(k) and not forbidden.has(k) and dist[k] * 2 >= far:
			cands.append(k)
	var target := cands.size() / 6
	var quiet: Array[PackedByteArray] = [lay.present[0].duplicate(), lay.present[1].duplicate()]
	var placed := 0
	for k: int in Clinic._shuffled(rng, cands):
		if placed >= target:
			break
		var level := 1 if k >= n_cells else 0
		var s: int = seg_of[k]
		if quiet[level][s] == 1:
			# The segment's first squeaker: only if the quiet walkway keeps a loop without it.
			var trial := quiet[level].duplicate()
			trial[s] = 0
			if not Annex._sound(lat, trial, true):
				continue
			quiet[level] = trial
		else:
			# More on a squeaky segment only beside one already there, so the squeakers on a segment
			# are one run and every quiet cell of it still reaches a junction.
			var beside := false
			for st in Floor.STEPS:
				var nk := k + st.y * plan.width + st.x
				if (seg_of.get(nk, -1) as int) == s and mask[nk] == 1:
					beside = true
			if not beside:
				continue
		mask[k] = 1
		placed += 1

	for k in 2 * n_cells:
		if mask[k] == 1:
			out.append(k)
	return out

## Whether a room's cells without a squeaker are all joined to each other.
static func _room_quiet_joined(plan: Floor.FloorPlan, room: Floor.Room, mask: PackedByteArray) -> bool:
	var base := room.level * plan.width * plan.height
	var quiet := 0
	var start := -1
	for y in range(room.y, room.y + room.h):
		for x in range(room.x, room.x + room.w):
			if mask[base + y * plan.width + x] == 0:
				quiet += 1
				if start < 0:
					start = y * plan.width + x
	if quiet == 0:
		return false
	var seen := {start: true}
	var stack: Array[int] = [start]
	while not stack.is_empty():
		var i: int = stack.pop_back()
		var x := i % plan.width
		var y := i / plan.width
		for st in Floor.STEPS:
			var nx := x + st.x
			var ny := y + st.y
			if nx < room.x or ny < room.y or nx >= room.x + room.w or ny >= room.y + room.h:
				continue
			var ni := ny * plan.width + nx
			if seen.has(ni) or mask[base + ni] == 1:
				continue
			seen[ni] = true
			stack.append(ni)
	return seen.size() == quiet

# ---------------------------------------------------------------------------------------------
# Zones and seats.

## zones(plan): every zone with at least one room, ascending id, with its ways in and its sign's
## number (its hide count from hides(plan, plan.seed)).
static func zones(plan: Floor.FloorPlan) -> Array[Zone]:
	var out: Array[Zone] = []
	var lay := layout_of(plan)
	if lay == null:
		return out
	var count := {}
	for h in hides(plan, plan.seed):
		count[h.zone] = (count.get(h.zone, 0) as int) + 1
	var n := lay.lat.n
	for zid in lay.zone_ids:
		var z := Zone.new()
		z.id = zid
		z.level = zid / (n * n)
		z.r = (zid % (n * n)) / n
		z.c = zid % n
		z.rooms = lay.zone_rooms[zid]
		z.kind = _zone_kind(plan, z.rooms)
		z.rect = Rect2i(lay.lat.block_origin(z.c, z.r), Vector2i(BLOCK, BLOCK))
		z.hides = count.get(zid, 0) as int
		for i in plan.doors.size():
			var d := plan.doors[i]
			if d.level != z.level:
				continue
			var ra := Floor.room_id_at(plan, d.level, d.ax, d.ay)
			var rb := Floor.room_id_at(plan, d.level, d.bx, d.by)
			var a_in := ra >= 0 and lay.room_zone[ra] == zid
			var b_in := rb >= 0 and lay.room_zone[rb] == zid
			if (a_in and Floor.cell_at(plan, d.level, d.bx, d.by) == Floor.CORRIDOR) or (b_in and Floor.cell_at(plan, d.level, d.ax, d.ay) == Floor.CORRIDOR):
				z.doors.append(i)
		out.append(z)
	return out

## The words on a zone's sign.
static func sign_text(z: Zone) -> String:
	return "HIDING PLACES HERE: %d. IT LOOKS IN 1." % z.hides

## seats(plan): the SEATS seats at the far-end party room's table, four along each long side, each
## facing the table. In order: the side nearer the back wall first, along the table from its low end.
static func seats(plan: Floor.FloorPlan) -> Array[Seat]:
	var out: Array[Seat] = []
	var room := party_room(plan)
	if room == null or room.kind != &"party":
		push_error("playroom %s/%d: the entity does not start in a party room" % [plan.seed, plan.depth])
		return out
	var back := _back_of(plan, room)
	var c := _centre(room)
	var bx := Floor.dir_dx(back)
	var by := Floor.dir_dy(back)
	for side: int in [1, -1]:  # the back side, then the front side
		for along in SEAT_ALONG:
			var s := Seat.new()
			s.index = out.size()
			s.level = room.level
			# across: towards the back wall (side 1) or away from it; along: perpendicular to it.
			s.at = c + Vector2i(bx, by) * (SEAT_ACROSS * side) + Vector2i(absi(by), absi(bx)) * along
			s.facing = opposite(back) if side == 1 else back
			out.append(s)
	return out

# ---------------------------------------------------------------------------------------------
# Plain data and hashes (for the stored list and the network's sameness checks).

static func hides_plain(list: Array[Hide]) -> Array:
	var out: Array = []
	for h in list:
		out.append({"id": h.id, "zone": h.zone, "room": h.room, "level": h.level, "kind": String(h.kind), "capacity": h.capacity,
			"inside": [h.inside.x, h.inside.y], "front": [h.front.x, h.front.y], "eye": h.eye, "gap": String(h.gap),
			"gapHalf": h.gap_half, "gapRange": h.gap_range})
	return out

static func zones_plain(list: Array[Zone]) -> Array:
	var out: Array = []
	for z in list:
		out.append({"id": z.id, "level": z.level, "c": z.c, "r": z.r, "kind": String(z.kind), "rect": [z.rect.position.x, z.rect.position.y, z.rect.size.x, z.rect.size.y],
			"rooms": Array(z.rooms), "doors": Array(z.doors), "hides": z.hides})
	return out

static func seats_plain(list: Array[Seat]) -> Array:
	var out: Array = []
	for s in list:
		out.append({"index": s.index, "level": s.level, "at": [s.at.x, s.at.y], "facing": String(s.facing)})
	return out

## The same 64-bit string hash as Floor.hash_plan, of any plain value.
static func hash_plain(v: Variant) -> String:
	var text := Floor.stable_stringify(v)
	var h1 := 0x811c9dc5
	var h2 := 0x01000193 ^ text.length()
	for i in text.length():
		var c := text.unicode_at(i)
		h1 = M.imul(h1 ^ c, 16777619)
		h2 = (M.imul(h2 ^ c, 2246822519) + ((h2 & M.MASK32) >> 13)) & M.MASK32
	return "%08x%08x" % [h1 & M.MASK32, h2 & M.MASK32]

## [plan, hides, squeakers, zones, seats] hashes: what tests/playroom_hashes.json stores per floor.
static func floor_hashes(plan: Floor.FloorPlan) -> Array[String]:
	var out: Array[String] = []
	out.append(Floor.hash_plan(plan))
	out.append(hash_plain(hides_plain(hides(plan, plan.seed))))
	out.append(hash_plain(Array(squeakers(plan, plan.seed))))
	out.append(hash_plain(zones_plain(zones(plan))))
	out.append(hash_plain(seats_plain(seats(plan))))
	return out

# ---------------------------------------------------------------------------------------------
# Text maps.

const ROOM_CHAR := {
	&"ballpit": "B", &"den": "D", &"party": "P", &"store": "S", &"toddler": "T", &"cloak": "C", &"deck": "K", &"nook": "N", &"lobby": "L",
}
const HIDE_CHAR := {
	&"pit": "*", &"slide": "=", &"den": "%", &"playhouse": "&", &"table": "$", &"chest": "[", &"cubby": "|",
}

const ASCII_LEGEND := "# void  . walkway  ^>v< soft steps (point uphill)  o ball-pit opening  E landing  X Minder start  " \
	+ "+ door (on the room side)  B ball pit  D den  P party  S store  T toddler  C cloak  K deck  N nook  L lobby  " \
	+ "(neighbouring rooms of the same kind alternate upper/lower case)\n" \
	+ "hides: * pit  = tube slide  % crawl den  & playhouse  $ party table  [ toy chest  | coat cubby   " \
	+ "! squeaker tile   : party-table seat"

## A text map of one level with the hides, squeakers and seats drawn over the rooms.
static func render_ascii(plan: Floor.FloorPlan, level: int) -> String:
	var w := plan.width
	var grid := PackedStringArray()
	grid.resize(w * plan.height)
	grid.fill("#")
	var rooms: Array[Floor.Room] = []
	for r in plan.rooms:
		if r.level == level:
			rooms.append(r)
	var lower := {}
	for r in rooms:
		var used_false := false
		var used_true := false
		for o in rooms:
			if o.id == r.id or o.kind != r.kind or not lower.has(o.id):
				continue
			if o.x <= r.x + r.w and r.x <= o.x + o.w and o.y <= r.y + r.h and r.y <= o.y + o.h:
				if lower[o.id] == true:
					used_true = true
				else:
					used_false = true
		lower[r.id] = used_false and not used_true
	for i in w * plan.height:
		var k: StringName = plan.cells[level][i]
		if k == Floor.CORRIDOR:
			grid[i] = "."
		elif k == Floor.ATRIUM_OPEN:
			grid[i] = "o"
	for r in rooms:
		var ch: String = ROOM_CHAR[r.kind]
		if lower[r.id]:
			ch = ch.to_lower()
		for y in range(r.y, r.y + r.h):
			for x in range(r.x, r.x + r.w):
				grid[y * w + x] = ch
	var arrow := {&"n": "^", &"e": ">", &"s": "v", &"w": "<"}
	for s in plan.stairs:
		for c in Floor.stair_cells(s):
			grid[c.y * w + c.x] = arrow[s.dir]
	var n_cells := w * plan.height
	for k in squeakers(plan, plan.seed):
		if k / n_cells == level:
			grid[k % n_cells] = "!"
	if plan.entity_start.level == level:
		for s in seats(plan):
			var c := cell_of(s.at)
			grid[c.y * w + c.x] = ":"
	for h in hides(plan, plan.seed):
		if h.level == level:
			var c := cell_of(h.inside)
			grid[c.y * w + c.x] = HIDE_CHAR[h.kind]
	for d in plan.doors:
		if d.level != level:
			continue
		var ra := Floor.room_id_at(plan, level, d.ax, d.ay)
		var rb := Floor.room_id_at(plan, level, d.bx, d.by)
		var use_b := rb > ra
		grid[(d.by if use_b else d.ay) * w + (d.bx if use_b else d.ax)] = "+"
	if plan.landing.level == level:
		grid[plan.landing.y * w + plan.landing.x] = "E"
	if plan.entity_start.level == level:
		grid[plan.entity_start.y * w + plan.entity_start.x] = "X"
	var rows := PackedStringArray()
	for y in plan.height:
		rows.append("".join(grid.slice(y * w, (y + 1) * w)))
	return "\n".join(rows)

## The zones of one level as a grid of blocks, north up: id, kind and the sign's number, "-" for a
## block with no zone (stairs, a ball-pit opening).
static func render_zones(plan: Floor.FloorPlan, level: int) -> String:
	var lay := layout_of(plan)
	if lay == null:
		return ""
	var n := lay.lat.n
	var by_id := {}
	for z in zones(plan):
		by_id[z.id] = z
	var rows := PackedStringArray()
	for r in n:
		var parts := PackedStringArray()
		for c in n:
			var zid := level * n * n + r * n + c
			if by_id.has(zid):
				var z: Zone = by_id[zid]
				parts.append(("%2d %-7s %d" % [zid, z.kind, z.hides]))
			else:
				parts.append("%2d %-7s -" % [zid, "-"])
		rows.append(" | ".join(parts))
	return "\n".join(rows)
