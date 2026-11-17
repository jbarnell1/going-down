# The Annex: an endless yellow office. Rooms repeat and corridors loop back on themselves.
# Design: docs/floors/annex.md section 3 (kept off the public repository). No TypeScript twin: its
# tests (tests/prop_annex.gd) and its stored hashes (tests/annex_hashes.json) are its proof.
#
# Constructive, cannot fail. In a canonical orientation (the lattice against the north margin), it:
#   1. lays a lattice of one-cell corridors, a line every 7 cells, with 6 by 6 blocks between them
#      (4 blocks a side below 42 cells, 5 from 42), the same on both levels;
#   2. picks the stair blocks and the atrium block(s);
#   3. hangs the elevator lobby off the south line, the spine;
#   4. prunes a quarter of the corridor segments on each level, never one that is protected, never one
#      that would leave a block with corridor on fewer than two sides, and never one whose removal
#      would leave the corridors in two pieces or make another segment a bridge, so every corridor is
#      on a loop and there are no corridor dead ends;
#   5. stamps every other block from one of three templates, chosen by a regular pattern, so the same
#      block comes round again and again;
# then turns or mirrors the whole plan by a seeded symmetry, as the Clinic does.
#
# Helpers reused from clinic.gd by preload (static functions; GDScript has no private, the leading
# underscore is a convention): the builder and its cells, carving, rooms, doors, the shuffle, the
# symmetry transform and the entity start. The lobby and the side-branch marking are written inline
# in clinic.gd (not functions), so they are repeated here. clinic.gd is not edited: if one of those
# helpers ever changes, the stored Annex hashes go red.
#
# Each stage draws from its own named fork of one seed. Whole-number maths only (the only floats are
# inside Rng and inside the Clinic's entity-start rule); no engine randomness; no sorts.
extends RefCounted

const Rng = preload("res://sim/rng.gd")
const Floor = preload("res://sim/floor.gd")
const Clinic = preload("res://sim/clinic.gd")

const CELL_SIZE := 2
const MARGIN := 1
## Corridor lines sit every PITCH cells; a block is the BLOCK by BLOCK square between four lines.
const PITCH := 7
const BLOCK := 6
const STAIR_LENGTH := 4
const MIN_SIGHTLINE := 8
const MAX_ROOMS := 80
const LOBBY_W := 5
const LOBBY_D := 3
## The car zone kept void beyond the lobby's outer wall, on both levels: SHAFT_W cells along the wall,
## centred on the landing, by SHAFT_D cells away from it. The car today is one cell (run.gd CAR_WIDTH,
## CAR_DEPTH = 2 m); the planned car is about 4 m square, which a centred 3 by 2 cell zone holds.
const SHAFT_W := 3
const SHAFT_D := 2

## Templates. The copy suite is always one of a floor's three; level 1 uses only cubicles and meeting.
const OFFICES := 0
const CUBICLES := 1
const MEETING := 2
const COPY := 3
const BREAK := 4

const DIRS: Array[StringName] = [&"n", &"e", &"s", &"w"]
## Which side becomes a template's front: the first of these that still has corridor.
const FRONT_ORDER: Array[StringName] = [&"s", &"n", &"e", &"w"]
## Columns (across the stair block, from its left as you face the stair) a stair may use. Never the
## middle two, so the head's stub never joins its corridor at a segment's middle cell.
const STAIR_COLUMNS: Array[int] = [0, 1, 4, 5]

## Grid size for a depth: the same as the Clinic's (36 at depth 1, up to 44).
static func annex_size(depth: int) -> Vector2i:
	return Clinic.clinic_size(depth)

static func blocks_per_side(size: int) -> int:
	return 4 if size < 42 else 5

# ---------------------------------------------------------------------------------------------
# The lattice: junctions where corridor lines cross, segments of 6 cells between them.

class Lattice:
	var n: int  # blocks a side
	var x0: int  # canonical position of the north-west junction
	var y0: int
	var nh: int  # horizontal segments, n * (n + 1); vertical ones follow
	var count: int  # all segments, 2 n (n + 1)
	var seg_a: PackedInt32Array  # junction ids at each end
	var seg_b: PackedInt32Array
	var junction_segs: Array[PackedInt32Array] = []

	func junction(i: int, j: int) -> int:
		return j * (n + 1) + i

	## Horizontal segment on line j, between junction columns i and i + 1.
	func h(i: int, j: int) -> int:
		return j * n + i

	## Vertical segment on line i, between junction rows j and j + 1.
	func v(i: int, j: int) -> int:
		return nh + j * (n + 1) + i

	## The segment on side `dir` of block (c, r).
	func side(c: int, r: int, dir: StringName) -> int:
		match dir:
			&"n":
				return h(c, r)
			&"s":
				return h(c, r + 1)
			&"w":
				return v(c, r)
			_:
				return v(c + 1, r)

	## Canonical cells of a segment, in order.
	func cells(s: int) -> Array[Vector2i]:
		var out: Array[Vector2i] = []
		if s < nh:
			var i := s % n
			var j := s / n
			for k in BLOCK:
				out.append(Vector2i(x0 + PITCH * i + 1 + k, y0 + PITCH * j))
		else:
			var t := s - nh
			var i := t % (n + 1)
			var j := t / (n + 1)
			for k in BLOCK:
				out.append(Vector2i(x0 + PITCH * i, y0 + PITCH * j + 1 + k))
		return out

	## The blocks a segment borders (one or two), as Vector2i(c, r).
	func blocks_of(s: int) -> Array[Vector2i]:
		var out: Array[Vector2i] = []
		if s < nh:
			var i := s % n
			var j := s / n
			if j > 0:
				out.append(Vector2i(i, j - 1))
			if j < n:
				out.append(Vector2i(i, j))
		else:
			var t := s - nh
			var i := t % (n + 1)
			var j := t / (n + 1)
			if i > 0:
				out.append(Vector2i(i - 1, j))
			if i < n:
				out.append(Vector2i(i, j))
		return out

	## Canonical top-left cell of block (c, r)'s interior.
	func block_origin(c: int, r: int) -> Vector2i:
		return Vector2i(x0 + PITCH * c + 1, y0 + PITCH * r + 1)

static func _make_lattice(n: int, x0: int, y0: int) -> Lattice:
	var lat := Lattice.new()
	lat.n = n
	lat.x0 = x0
	lat.y0 = y0
	lat.nh = n * (n + 1)
	lat.count = 2 * n * (n + 1)
	lat.seg_a.resize(lat.count)
	lat.seg_b.resize(lat.count)
	for j in n + 1:
		for i in n:
			var s := lat.h(i, j)
			lat.seg_a[s] = lat.junction(i, j)
			lat.seg_b[s] = lat.junction(i + 1, j)
	for j in n:
		for i in n + 1:
			var s := lat.v(i, j)
			lat.seg_a[s] = lat.junction(i, j)
			lat.seg_b[s] = lat.junction(i, j + 1)
	var lists: Array[PackedInt32Array] = []
	for k in (n + 1) * (n + 1):
		lists.append(PackedInt32Array())
	for s in lat.count:
		for jn: int in [lat.seg_a[s], lat.seg_b[s]]:
			var list: PackedInt32Array = lists[jn]
			list.append(s)
			lists[jn] = list  # packed arrays are values: write the grown copy back
	lat.junction_segs = lists
	return lat

## Whether the present segments join every junction into one piece, and (when `no_bridges`) whether
## none of them is a bridge, the only link between two parts. Tarjan's bridge search, iterative.
static func _sound(lat: Lattice, present: PackedByteArray, no_bridges: bool) -> bool:
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
	var bridges := 0
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
					bridges += 1
	for i in nj:
		if disc[i] == -1:
			return false
	return bridges == 0 or not no_bridges

static func _sides_left(lat: Lattice, present: PackedByteArray, c: int, r: int) -> int:
	var k := 0
	for d in DIRS:
		if present[lat.side(c, r, d)] == 1:
			k += 1
	return k

## Removes segments in a seeded order until a quarter are gone (one pass: a segment refused once is
## refused for good, since removing more only makes the rules harder to keep).
static func _prune(lat: Lattice, rng: Rng, protected: PackedByteArray) -> PackedByteArray:
	var present := PackedByteArray()
	present.resize(lat.count)
	present.fill(1)
	var order: Array = []
	for s in lat.count:
		order.append(s)
	var target := lat.count / 4
	var removed := 0
	for s: int in Clinic._shuffled(rng, order):
		if removed >= target:
			break
		if protected[s] == 1:
			continue
		var blocks_ok := true
		for bl in lat.blocks_of(s):
			if _sides_left(lat, present, bl.x, bl.y) <= 2:
				blocks_ok = false
		if not blocks_ok:
			continue
		present[s] = 0
		if not _sound(lat, present, true):
			present[s] = 1
			continue
		removed += 1
	return present

# ---------------------------------------------------------------------------------------------
# Blocks: a local frame with the front to the south (local row 5 faces the front corridor at row 6,
# the back corridor is row -1), turned so its front faces `front`.

static func _map(front: StringName, x: int, y: int) -> Vector2i:
	return Stamp.map_local(front, x, y)

## The absolute side a block-relative outside cell lies on.
static func _side_of(rel: Vector2i) -> StringName:
	if rel.y < 0:
		return &"n"
	if rel.y >= BLOCK:
		return &"s"
	if rel.x < 0:
		return &"w"
	return &"e"

class Stamp:
	var b: Clinic.Builder
	var level: int
	var origin: Vector2i
	var front: StringName

	func at(x: int, y: int) -> Vector2i:
		return origin + map_local(front, x, y)

	## A local cell (-1..6) to block-relative cells (add the block origin for the canonical cell).
	static func map_local(f: StringName, x: int, y: int) -> Vector2i:
		match f:
			&"s":
				return Vector2i(x, y)
			&"n":
				return Vector2i(BLOCK - 1 - x, BLOCK - 1 - y)
			&"e":
				return Vector2i(y, BLOCK - 1 - x)
			_:
				return Vector2i(BLOCK - 1 - y, x)

	func room(kind: StringName, x: int, y: int, w: int, h: int) -> void:
		var a := at(x, y)
		var c := at(x + w - 1, y + h - 1)
		Clinic._add_room(b, level, kind, mini(a.x, c.x), mini(a.y, c.y), absi(c.x - a.x) + 1, absi(c.y - a.y) + 1)

	func door(ax: int, ay: int, bx: int, by: int) -> void:
		var p := at(ax, ay)
		var q := at(bx, by)
		Clinic._add_door(b, level, p.x, p.y, q.x, q.y)

## Whether the local side (outside cell lx, ly) of a block has corridor.
static func _local_side(lat: Lattice, present: PackedByteArray, c: int, r: int, front: StringName, lx: int, ly: int) -> bool:
	return present[lat.side(c, r, _side_of(_map(front, lx, ly)))] == 1

static func _front_for(lat: Lattice, present: PackedByteArray, c: int, r: int) -> StringName:
	for d in FRONT_ORDER:
		if present[lat.side(c, r, d)] == 1:
			return d
	return &"s"  # not reached: every block keeps corridor on two sides

## Rooms a template adds.
static func _template_rooms(t: int) -> int:
	match t:
		OFFICES:
			return 4
		CUBICLES:
			return 1
		BREAK:
			return 2
		_:
			return 3

static func _stamp(b: Clinic.Builder, lat: Lattice, present: PackedByteArray, level: int, c: int, r: int, t: int) -> void:
	var s := Stamp.new()
	s.b = b
	s.level = level
	s.origin = lat.block_origin(c, r)
	s.front = _front_for(lat, present, c, r)
	var back := _local_side(lat, present, c, r, s.front, 0, -1)
	match t:
		OFFICES:
			# Four 3 by 3 offices. The front two open on the front; the back two on the back if it has
			# corridor, otherwise through the office in front of them.
			s.room(&"office", 0, 0, 3, 3)
			s.room(&"office", 3, 0, 3, 3)
			s.room(&"office", 0, 3, 3, 3)
			s.room(&"office", 3, 3, 3, 3)
			s.door(1, 5, 1, 6)
			s.door(4, 5, 4, 6)
			if back:
				s.door(1, 0, 1, -1)
				s.door(4, 0, 4, -1)
			else:
				s.door(1, 2, 1, 3)
				s.door(4, 2, 4, 3)
		CUBICLES:
			# One 6 by 6 walk-through room with a door on every side that has corridor.
			s.room(&"cubicles", 0, 0, 6, 6)
			if _local_side(lat, present, c, r, s.front, 2, 6):
				s.door(2, 5, 2, 6)
			if back:
				s.door(3, 0, 3, -1)
			if _local_side(lat, present, c, r, s.front, -1, 3):
				s.door(0, 3, -1, 3)
			if _local_side(lat, present, c, r, s.front, 6, 2):
				s.door(5, 2, 6, 2)
		MEETING:
			# A 6 by 4 meeting room with two front doors, and two 3 by 2 closets behind it.
			s.room(&"meeting", 0, 2, 6, 4)
			s.door(1, 5, 1, 6)
			s.door(4, 5, 4, 6)
			s.room(&"closet", 0, 0, 3, 2)
			s.door(1, 1, 1, 2)
			s.room(&"closet", 3, 0, 3, 2)
			s.door(4, 1, 4, 2)
		COPY:
			# A 6 by 2 copy room with one door, and two 3 by 4 stores reached only through it: the side branch.
			s.room(&"copy", 0, 4, 6, 2)
			s.door(2, 5, 2, 6)
			s.room(&"store", 0, 0, 3, 4)
			s.door(1, 3, 1, 4)
			s.room(&"store", 3, 0, 3, 4)
			s.door(4, 3, 4, 4)
		BREAK:
			# A 4 by 6 break room with front and back doors (the back only if it has corridor), and a
			# 2 by 6 closet off it.
			s.room(&"break", 0, 0, 4, 6)
			s.door(2, 5, 2, 6)
			if back:
				s.door(1, 0, 1, -1)
			s.room(&"closet", 4, 0, 2, 6)
			s.door(3, 3, 4, 3)

## Level 0: one open room with a door on every side that has corridor. Level 1: an opening.
static func _stamp_atrium(b: Clinic.Builder, lat: Lattice, present: PackedByteArray, level: int, c: int, r: int) -> void:
	var o := lat.block_origin(c, r)
	if level == 1:
		Clinic._carve(b, 1, o.x, o.y, BLOCK, BLOCK, Floor.ATRIUM_OPEN)
		return
	Clinic._add_room(b, 0, &"atrium", o.x, o.y, BLOCK, BLOCK)
	if present[lat.side(c, r, &"n")] == 1:
		Clinic._add_door(b, 0, o.x + 2, o.y - 1, o.x + 2, o.y)
	if present[lat.side(c, r, &"s")] == 1:
		Clinic._add_door(b, 0, o.x + 3, o.y + BLOCK, o.x + 3, o.y + BLOCK - 1)
	if present[lat.side(c, r, &"w")] == 1:
		Clinic._add_door(b, 0, o.x - 1, o.y + 3, o.x, o.y + 3)
	if present[lat.side(c, r, &"e")] == 1:
		Clinic._add_door(b, 0, o.x + BLOCK, o.y + 2, o.x + BLOCK - 1, o.y + 2)

class StairBlock:
	var c: int
	var r: int
	## The side the foot is on (level 0); the head's stub joins the opposite side on level 1.
	var front: StringName
	var column: int

# ---------------------------------------------------------------------------------------------
# Layout.

static func _lay_out(seed: String, depth: int, W: int, H: int) -> Clinic.Canonical:
	var root := Rng.make_rng("annex:%s:%d" % [seed, depth])
	var shape := root.fork("shape")
	var b := Clinic._new_builder(W, H)
	b.budget = Clinic.UNLIMITED

	# --- The lattice, against the north margin; seeded across.
	var n := blocks_per_side(W)
	var L := PITCH * n + 1
	var lat := _make_lattice(n, shape.int_in(MARGIN, W - MARGIN - L), MARGIN)
	var spine_y := lat.y0 + PITCH * n

	# --- Stair blocks, at least two blocks apart; then the atrium block(s).
	var stairs_rng := root.fork("stairs")
	var all_blocks: Array = []
	for r in n:
		for c in n:
			all_blocks.append(Vector2i(c, r))
	var stair_count := 3 if depth >= 4 else 2
	var atrium_count := 2 if depth >= 4 else 1
	var stair_blocks: Array[StairBlock] = []
	var used := {}
	for bl: Vector2i in Clinic._shuffled(stairs_rng, all_blocks):
		if stair_blocks.size() >= stair_count:
			break
		var apart := true
		for sb in stair_blocks:
			if maxi(absi(sb.c - bl.x), absi(sb.r - bl.y)) < 2:
				apart = false
		if not apart:
			continue
		var sb := StairBlock.new()
		sb.c = bl.x
		sb.r = bl.y
		sb.front = DIRS[stairs_rng.int_in(0, 3)]
		sb.column = STAIR_COLUMNS[stairs_rng.int_in(0, STAIR_COLUMNS.size() - 1)]
		stair_blocks.append(sb)
		used[bl] = true
	var atria: Array[Vector2i] = []
	for bl: Vector2i in Clinic._shuffled(stairs_rng, all_blocks):
		if atria.size() >= atrium_count:
			break
		if not used.has(bl):
			atria.append(bl)
			used[bl] = true

	# --- Protected segments.
	var keep0 := PackedByteArray()
	keep0.resize(lat.count)
	var keep1 := PackedByteArray()
	keep1.resize(lat.count)
	for i in n:
		keep0[lat.h(i, n)] = 1  # the spine
	for sb in stair_blocks:
		keep0[lat.side(sb.c, sb.r, _side_of(_map(sb.front, 0, BLOCK)))] = 1  # the foot's corridor
		keep1[lat.side(sb.c, sb.r, _side_of(_map(sb.front, 0, -1)))] = 1  # the head's corridor
	for a in atria:
		for d in DIRS:
			keep1[lat.side(a.x, a.y, d)] = 1  # the balcony

	var present0 := _prune(lat, root.fork("prune0"), keep0)
	var present1 := _prune(lat, root.fork("prune1"), keep1)

	# --- Corridors: every junction, and every segment still present.
	var presents: Array[PackedByteArray] = [present0, present1]
	for level in 2:
		for j in n + 1:
			for i in n + 1:
				Clinic._set_cell(b, level, lat.x0 + PITCH * i, lat.y0 + PITCH * j, Floor.CORRIDOR)
		for s in lat.count:
			if presents[level][s] == 1:
				for cell in lat.cells(s):
					Clinic._set_cell(b, level, cell.x, cell.y, Floor.CORRIDOR)

	# --- Elevator lobby off the spine: 5 wide, 3 deep, two doors so it is not a dead end.
	var lx := shape.int_in(lat.x0 + 2, lat.x0 + L - 3 - (LOBBY_W - 1))
	var lobby := Clinic._add_room(b, 0, &"lobby", lx, spine_y + 1, LOBBY_W, LOBBY_D)
	Clinic._add_door(b, 0, lx, spine_y, lx, spine_y + 1)
	Clinic._add_door(b, 0, lx + LOBBY_W - 1, spine_y, lx + LOBBY_W - 1, spine_y + 1)
	var landing := Floor.Pos.make(0, lx + LOBBY_W / 2, lobby.y + lobby.h - 1)
	Clinic._set_cell(b, 0, landing.x, landing.y, Floor.LANDING)
	b.reserved[1][landing.y * W + landing.x] = 1  # the shaft above the landing
	# The car zone beyond the lobby's outer wall stays void on both levels (nothing is ever built
	# south of the spine but the lobby, so this only records it).
	for level in 2:
		for dy in range(1, SHAFT_D + 1):
			for dx in range(-(SHAFT_W / 2), SHAFT_W / 2 + 1):
				b.reserved[level][(landing.y + dy) * W + landing.x + dx] = 1

	# --- Stairs: 4 cells climbing from the front edge of the block; a two-cell stub on level 1 joins
	# the head to the back corridor.
	for sb in stair_blocks:
		var o := lat.block_origin(sb.c, sb.r)
		var start := o + _map(sb.front, sb.column, BLOCK - 1)
		var next := o + _map(sb.front, sb.column, BLOCK - 2)
		var stair := Floor.Stair.make(start.x, start.y, Floor.dir_from_vec(next.x - start.x, next.y - start.y), STAIR_LENGTH)
		b.stairs.append(stair)
		for cell in Floor.stair_cells(stair):
			Clinic._set_cell(b, 0, cell.x, cell.y, Floor.STAIR)
			Clinic._set_cell(b, 1, cell.x, cell.y, Floor.STAIR)
		for ly: int in [0, 1]:
			var p := o + _map(sb.front, sb.column, ly)
			Clinic._set_cell(b, 1, p.x, p.y, Floor.CORRIDOR)

	# --- Atria.
	for a in atria:
		_stamp_atrium(b, lat, present0, 0, a.x, a.y)
		_stamp_atrium(b, lat, present1, 1, a.x, a.y)

	# --- Templates. Three per floor, the copy suite always one; block (c, r) gets number
	# (c + 2r + offset) mod 3. Level 1: cubicles and meeting only, while the room budget lasts.
	var tr := root.fork("templates")
	var others: Array = [OFFICES, CUBICLES, MEETING, BREAK]
	var picked: Array = Clinic._shuffled(tr, others).slice(0, 2)
	picked.append(COPY)
	var floor_templates: Array = Clinic._shuffled(tr, picked)
	var offset0 := tr.int_in(0, 2)
	var offset1 := tr.int_in(0, 1)
	# The copy suite takes the template number with the most free blocks (the lowest number on a tie),
	# so it fills at least a third of them: at least 5 blocks with four a side, 7 with five. Its shape
	# depends only on which way it faces, so the floor always has one block shape at least that often.
	var per_number := [0, 0, 0]
	for r in n:
		for c in n:
			if not used.has(Vector2i(c, r)):
				per_number[(c + 2 * r + offset0) % 3] += 1
	var most := 0
	for k in 3:
		if per_number[k] > per_number[most]:
			most = k
	var copy_at := floor_templates.find(COPY)
	floor_templates[copy_at] = floor_templates[most]
	floor_templates[most] = COPY
	for r in n:
		for c in n:
			if used.has(Vector2i(c, r)):
				continue
			_stamp(b, lat, present0, 0, c, r, floor_templates[(c + 2 * r + offset0) % 3])
	var upper: Array = [CUBICLES, MEETING]
	var budget := MAX_ROOMS - b.rooms.size()
	var free_upper: Array = []
	for bl: Vector2i in all_blocks:
		if not used.has(bl):
			free_upper.append(bl)
	for bl: Vector2i in Clinic._shuffled(tr, free_upper):
		var t: int = upper[(bl.x + 2 * bl.y + offset1) % 2]
		if _template_rooms(t) > budget:
			continue  # over budget: the block stays solid
		budget -= _template_rooms(t)
		_stamp(b, lat, present1, 1, bl.x, bl.y, t)

	var out := Clinic.Canonical.new()
	out.b = b
	out.landing = landing
	return out

# ---------------------------------------------------------------------------------------------

## generate_annex(seed, depth): the Annex floor for this seed and depth, at the Clinic's size.
static func generate_annex(seed: String, depth: int) -> Floor.FloorPlan:
	var size := annex_size(depth)
	var W := size.x
	var H := size.y
	var root := Rng.make_rng("annex:%s:%d" % [seed, depth])
	var canon := _lay_out(seed, depth, W, H)
	var pick := root.fork("orient").int_in(0, Clinic._symmetry_count(W, H) - 1)
	var t := Clinic._transform(canon.b, canon.landing, pick)
	var b := t.b

	var plan := Floor.FloorPlan.new()
	plan.place = &"annex"
	plan.seed = seed
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

	# Side branches: mark every room in a dead-end group. (Repeated from clinic.gd generate_clinic,
	# where it is inline.)
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
	plan.entity_start = Clinic._choose_entity_start(plan, root.fork("entity"))
	return plan

# ---------------------------------------------------------------------------------------------
# Text maps (floor.gd's render_ascii knows only the Clinic's room kinds).

const ROOM_CHAR := {
	&"office": "O", &"cubicles": "U", &"meeting": "M", &"copy": "P", &"store": "S", &"break": "B",
	&"closet": "C", &"lobby": "L", &"atrium": "A",
}

const ASCII_LEGEND := "# void  . corridor  ^>v< stair (points uphill)  o atrium opening  E landing  X entity start  " \
	+ "+ door (on the room side)  O office  U cubicles  M meeting  P copy  S store  B break  C closet  A atrium  " \
	+ "L lobby  (neighbouring rooms of the same kind alternate upper/lower case)"

## A text map of one level, one character per cell. Same drawing rules as Floor.render_ascii.
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
