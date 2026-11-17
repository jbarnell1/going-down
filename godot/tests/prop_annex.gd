# The Annex's eight guarantees (docs/floors/annex.md section 3) on 800 floors (seed-0..199 at depths
# 1 to 4; 40 in the quick set, seed-0..9 at each depth). The Annex has no TypeScript twin, so these
# oracles and the golden hash list (tests/golden/annex.json) are its proof. Oracles are written here
# from floor.gd's step rule only; the lattice is found from the plan itself (its corner junctions can
# never be pruned, so the bounding box of level 0's corridors is the lattice).
extends RefCounted

const T = preload("res://tests/t.gd")
const Annex = preload("res://sim/annex.gd")
const Floor = preload("res://sim/floor.gd")
const Landing = preload("res://sim/landing.gd")

const QUICK_SEEDS := 10
const PITCH := 7
const BLOCK := 6
## Property 5's bound on steps from any room cell to a corridor. The design says 8, but its own copy
## suite (a 6 by 2 copy room with one door, two 3 by 4 stores behind it) and break room (4 by 6 with a
## 2 by 6 closet, no back corridor) put their far corners at least 9 steps from the corridor wherever
## the door goes (|5 - door| + 5 + 1 >= 9). So 9, the tightest bound those templates allow.
const ROOM_STEPS_MAX := 9
## The golden file holding every floor's plan hash (key "hashes", then "seed-N/depth").
const HASHES_FILE := "annex.json"
const STEPS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]

static var _cache := {}

static func plan(seed: String, depth: int) -> Floor.FloorPlan:
	var key := "%s/%d" % [seed, depth]
	if not _cache.has(key):
		_cache[key] = Annex.generate_annex(seed, depth)
	return _cache[key]

## Depth-major, like tests/plans.gd property_plans.
static func plans(quick: bool) -> Array[Floor.FloorPlan]:
	var out: Array[Floor.FloorPlan] = []
	for depth: int in [1, 2, 3, 4]:
		for i in (QUICK_SEEDS if quick else 200):
			out.append(plan("seed-%d" % i, depth))
	return out

static func _key(p: Floor.FloorPlan) -> String:
	return "%s d%d" % [p.seed, p.depth]

## Flood fill from `from` over can_step, written here: a set of pos_index values, as a dictionary
## with `has`. `blocked` cells (pos_index) are never entered. `reverse` follows steps backwards (cells
## that can step into the filled set).
static func _flood(p: Floor.FloorPlan, from: Floor.Pos, blocked: Dictionary, reverse: bool) -> Dictionary:
	var dist := _search(p, [from] as Array[Floor.Pos], blocked, reverse)
	var seen := {}
	for i in dist.size():
		if dist[i] >= 0:
			seen[i] = true
	return seen

## Breadth-first step counts from many sources over can_step, written here: a dictionary from
## pos_index to steps, holding only the cells reached.
static func _bfs(p: Floor.FloorPlan, sources: Array[Floor.Pos]) -> Dictionary:
	var dist := _search(p, sources, {}, false)
	var out := {}
	for i in dist.size():
		if dist[i] >= 0:
			out[i] = dist[i]
	return out

## The search behind both: steps from the nearest source to every position (pos_index), -1 if not
## reached. Every step is asked of Floor.can_step_xy, the plan's step rule.
static func _search(p: Floor.FloorPlan, sources: Array[Floor.Pos], blocked: Dictionary, reverse: bool) -> PackedInt32Array:
	var w := p.width
	var n := p.width * p.height
	var dist := PackedInt32Array()
	dist.resize(2 * n)
	dist.fill(-1)
	var queue := PackedInt32Array()
	queue.resize(2 * n)
	var tail := 0
	for s in sources:
		var k := Floor.pos_index(p, s)
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
			for d in STEPS:
				var nx := cx + d.x
				var ny := cy + d.y
				if nx < 0 or ny < 0 or nx >= w or ny >= p.height:
					continue
				var key := level * n + ny * w + nx
				if dist[key] != -1 or blocked.has(key):
					continue
				var ok := Floor.can_step_xy(p, level, nx, ny, cl, cx, cy) if reverse else Floor.can_step_xy(p, cl, cx, cy, level, nx, ny)
				if not ok:
					continue
				dist[key] = dist[ci] + 1
				queue[tail] = key
				tail += 1
	return dist

## The lattice, from the plan: Rect2i of level 0's corridor cells, and blocks a side (0 if not a lattice).
static func _lattice(p: Floor.FloorPlan) -> Array:
	var x0 := p.width
	var y0 := p.height
	var x1 := -1
	var y1 := -1
	for y in p.height:
		for x in p.width:
			if Floor.cell_at(p, 0, x, y) == Floor.CORRIDOR:
				x0 = mini(x0, x)
				y0 = mini(y0, y)
				x1 = maxi(x1, x)
				y1 = maxi(y1, y)
	var w := x1 - x0 + 1
	var n := (w - 1) / PITCH if (w == y1 - y0 + 1 and (w - 1) % PITCH == 0) else 0
	return [x0, y0, n]

## The middle cell (offset 3 of 0..5) of every segment of a lattice, horizontal then vertical.
static func _segment_middles(x0: int, y0: int, n: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for j in n + 1:
		for i in n:
			out.append(Vector2i(x0 + PITCH * i + 4, y0 + PITCH * j))
	for j in n:
		for i in n + 1:
			out.append(Vector2i(x0 + PITCH * i, y0 + PITCH * j + 4))
	return out

# ---------------------------------------------------------------------------------------------

## 1. Every walkable cell is reachable from the landing.
func test_every_walkable_cell_reachable(t: T) -> void:
	var walkable := 0
	var missing := 0
	var unreachable_rooms := 0
	var ps := plans(t.quick)
	for p in ps:
		var seen := _flood(p, p.landing, {}, false)
		var here := 0
		for level in 2:
			for y in p.height:
				for x in p.width:
					if Floor.is_walkable(p, level, x, y):
						walkable += 1
						if not seen.has(Floor.pos_index(p, Floor.Pos.make(level, x, y))):
							missing += 1
							here += 1
		for r in p.rooms:
			if not seen.has(Floor.pos_index(p, Floor.Pos.make(r.level, r.x, r.y))):
				unreachable_rooms += 1
		if here > 0:
			t.check(false, "%s: %d walkable cells not reachable from the landing" % [_key(p), here])
	t.eq(missing, 0, "walkable cells not reachable from the landing")
	t.eq(unreachable_rooms, 0, "rooms not reachable")
	t.note("%d floors, %d walkable cells, %d unreachable" % [ps.size(), walkable, missing])

## 2. Steps work both ways, so the landing is reachable from everywhere.
func test_steps_work_both_ways(t: T) -> void:
	var ps := plans(t.quick)
	var missing := 0
	var asymmetric := 0
	for pi in ps.size():
		var p := ps[pi]
		var back := _flood(p, p.landing, {}, true)  # every cell that can walk to the landing
		for level in 2:
			for y in p.height:
				for x in p.width:
					if not Floor.is_walkable(p, level, x, y):
						continue
					var here := Floor.Pos.make(level, x, y)
					if not back.has(Floor.pos_index(p, here)):
						missing += 1
					if pi < 40:
						for nb in Floor.neighbours(p, here):
							if not Floor.can_step(p, nb, here):
								asymmetric += 1
	t.eq(missing, 0, "walkable cells that cannot walk to the landing")
	t.eq(asymmetric, 0, "one-way steps (first 40 floors)")
	t.note("%d floors: the landing reached from every walkable cell; steps symmetric on the first 40" % ps.size())

## 3. Loops are real: block the middle cell of any one segment and every other corridor cell on that
## level stays connected (through corridor only); block any one stair and level 1 is still reachable.
func test_loops_are_real(t: T) -> void:
	var ps := plans(t.quick)
	var segments_checked := 0
	var stairs_checked := 0
	for p in ps:
		var lat := _lattice(p)
		var n: int = lat[2]
		if not t.check(n >= 4, "%s: level 0's corridors are not a square lattice" % _key(p)):
			continue
		var middles := _segment_middles(lat[0], lat[1], n)
		for level in 2:
			# Corridor cells of this level and their corridor neighbours (by can_step), packed.
			var ids := {}
			var cells: Array[Vector2i] = []
			for y in p.height:
				for x in p.width:
					if Floor.cell_at(p, level, x, y) == Floor.CORRIDOR:
						ids[y * p.width + x] = cells.size()
						cells.append(Vector2i(x, y))
			var nbrs: Array[PackedInt32Array] = []
			for c in cells:
				var list := PackedInt32Array()
				for d in STEPS:
					var k: int = ids.get((c.y + d.y) * p.width + c.x + d.x, -1)
					if k >= 0 and Floor.can_step_xy(p, level, c.x, c.y, level, c.x + d.x, c.y + d.y):
						list.append(k)
				nbrs.append(list)
			var bad := 0
			for m in middles:
				var blocked: int = ids.get(m.y * p.width + m.x, -1)
				if blocked < 0:
					continue  # pruned
				segments_checked += 1
				var seen := PackedByteArray()
				seen.resize(cells.size())
				seen[blocked] = 1
				var start := 0 if blocked != 0 else 1
				seen[start] = 1
				var stack := PackedInt32Array([start])
				var count := 1
				while not stack.is_empty():
					var u := stack[stack.size() - 1]
					stack.resize(stack.size() - 1)
					for v in nbrs[u]:
						if seen[v] == 0:
							seen[v] = 1
							count += 1
							stack.append(v)
				if count != cells.size() - 1:
					bad += 1
					if bad <= 2:
						t.check(false, "%s L%d: blocking segment middle %d,%d cuts off %d corridor cells" % [_key(p), level, m.x, m.y, cells.size() - 1 - count])
		# Block each stair in turn: everything else, level 1 included, is still reachable.
		for si in p.stairs.size():
			stairs_checked += 1
			var blocked := {}
			for c in Floor.stair_cells(p.stairs[si]):
				blocked[Floor.pos_index(p, c)] = true
			var seen := _flood(p, p.landing, blocked, false)
			var lost := 0
			for level in 2:
				for y in p.height:
					for x in p.width:
						var key := Floor.pos_index(p, Floor.Pos.make(level, x, y))
						if Floor.is_walkable(p, level, x, y) and not blocked.has(key) and not seen.has(key):
							lost += 1
			t.check(lost == 0, "%s: with stair %d blocked, %d cells cannot be reached" % [_key(p), si, lost])
		t.check(p.stairs.size() >= (3 if p.depth >= 4 else 2), "%s: %d stairs" % [_key(p), p.stairs.size()])
	t.check(segments_checked > ps.size() * 40, "segments checked: %d" % segments_checked)
	t.note("%d floors: %d segment middles blocked one at a time, %d stairs blocked one at a time" % [ps.size(), segments_checked, stairs_checked])

## 4. Nobody gets a different plan: generating twice gives the same hash, and every hash matches the
## golden list (tests/golden/annex.json "hashes", recorded by npm run godot:golden; the quick set
## compares its 40 floors with the same list).
func test_same_plan_for_everyone(t: T) -> void:
	var want: Variant = t.golden(HASHES_FILE, "hashes")
	var ps := plans(t.quick)
	var differ := 0
	var mismatched := 0
	for p in ps:
		var h := Floor.hash_plan(p)
		var again := Floor.hash_plan(Annex.generate_annex(p.seed, p.depth))
		if h != again:
			differ += 1
			if differ <= 3:
				t.check(false, "%s: generated twice, hashes %s and %s" % [_key(p), h, again])
		var key := "%s/%d" % [p.seed, p.depth]
		if t.recording:
			t.expect(HASHES_FILE, "hashes." + key, h, "")
		elif not (want is Dictionary) or String((want as Dictionary).get(key, "")) != h:
			mismatched += 1
			if mismatched <= 3:
				t.check(false, "%s: hash %s, golden %s" % [_key(p), h, (want as Dictionary).get(key, "(none)") if want is Dictionary else "(no golden)"])
		t.check(p.place == &"annex", "%s: place %s" % [_key(p), p.place])
	t.eq(differ, 0, "floors whose two generations differ")
	t.eq(mismatched, 0, "floors whose hash differs from the golden list")
	t.note("%d floors generated twice, same hash; all match tests/golden/%s" % [ps.size(), HASHES_FILE])

## 5. Dead ends are shallow: every corridor cell has two ways out; at least two side branches per
## floor, each one door in and at most two rooms deep; no room cell more than ROOM_STEPS_MAX steps
## from a corridor.
func test_dead_ends_are_shallow(t: T) -> void:
	var ps := plans(t.quick)
	var groups_total := 0
	var worst := 0
	for p in ps:
		var corridors: Array[Floor.Pos] = []
		var cornered := 0
		for level in 2:
			for y in p.height:
				for x in p.width:
					if Floor.cell_at(p, level, x, y) == Floor.CORRIDOR:
						var here := Floor.Pos.make(level, x, y)
						corridors.append(here)
						if Floor.neighbours(p, here).size() < 2:
							cornered += 1
		t.check(cornered == 0, "%s: %d corridor cells with fewer than two ways out" % [_key(p), cornered])
		# Steps from the nearest corridor to every room cell.
		var dist := _bfs(p, corridors)
		var far := 0
		for r in p.rooms:
			for y in range(r.y, r.y + r.h):
				for x in range(r.x, r.x + r.w):
					far = maxi(far, int(dist.get(Floor.pos_index(p, Floor.Pos.make(r.level, x, y)), 999)))
		worst = maxi(worst, far)
		t.check(far <= ROOM_STEPS_MAX, "%s: a room cell %d steps from a corridor" % [_key(p), far])
		# Side groups from scratch: union side rooms joined by doors; exits are doors leaving a group.
		var side := {}
		for r in p.rooms:
			if r.branch == &"side":
				side[r.id] = true
		var parent := {}
		for id: int in side:
			parent[id] = id
		var find := func(x: int) -> int:
			while int(parent.get(x, x)) != x:
				x = parent.get(x, x)
			return x
		var links := {}  # room id -> side rooms it shares a door with
		for d in p.doors:
			var a := Floor.room_id_at(p, d.level, d.ax, d.ay)
			var b := Floor.room_id_at(p, d.level, d.bx, d.by)
			if side.has(a) and side.has(b):
				parent[find.call(a)] = find.call(b)
				links[a] = links.get(a, []) + [b]
				links[b] = links.get(b, []) + [a]
		var exits := {}
		var entry := {}
		for id: int in side:
			exits[find.call(id)] = 0
		for d in p.doors:
			var a := Floor.room_id_at(p, d.level, d.ax, d.ay)
			var b := Floor.room_id_at(p, d.level, d.bx, d.by)
			for pair: Array in [[a, b], [b, a]]:
				if side.has(pair[0]) and not side.has(pair[1]):
					var g: int = find.call(pair[0])
					exits[g] = int(exits[g]) + 1
					entry[g] = pair[0]
		groups_total += exits.size()
		t.check(exits.size() >= 2, "%s: %d side branches" % [_key(p), exits.size()])
		for g: int in exits:
			t.check(int(exits[g]) == 1, "%s: side group %d has %d doors out" % [_key(p), g, exits[g]])
			if not entry.has(g):
				continue
			# Rooms deep: the entry room is 1.
			var depth_of := {entry[g]: 1}
			var queue: Array = [entry[g]]
			var deepest := 1
			while not queue.is_empty():
				var u: int = queue.pop_front()
				for v: int in links.get(u, []):
					if not depth_of.has(v):
						depth_of[v] = int(depth_of[u]) + 1
						deepest = maxi(deepest, int(depth_of[v]))
						queue.append(v)
			t.check(deepest <= 2, "%s: side group %d is %d rooms deep" % [_key(p), g, deepest])
	t.note("%d floors, %d side branches, each one door in and at most two rooms deep; farthest room cell %d steps from a corridor" % [ps.size(), groups_total, worst])

## 6. A straight corridor of 8 or more cells exists; the entity starts at the end of one, 12 or more
## steps from the landing; the lobby has two doors.
func test_long_views_entity_and_lobby(t: T) -> void:
	var ps := plans(t.quick)
	var longest_min := 1 << 30
	for p in ps:
		# Straight runs of corridor, each step a real step, found here.
		var ends := {}
		var longest := 0
		for level in 2:
			for axis in 2:
				var outer := p.height if axis == 0 else p.width
				var inner := p.width if axis == 0 else p.height
				for a in outer:
					var b := 0
					while b < inner:
						var x := b if axis == 0 else a
						var y := a if axis == 0 else b
						if Floor.cell_at(p, level, x, y) != Floor.CORRIDOR:
							b += 1
							continue
						var e := b
						while true:
							var nx := (e + 1) if axis == 0 else a
							var ny := a if axis == 0 else (e + 1)
							if Floor.cell_at(p, level, nx, ny) != Floor.CORRIDOR:
								break
							var cx := e if axis == 0 else a
							var cy := a if axis == 0 else e
							if not Floor.can_step_xy(p, level, cx, cy, level, nx, ny):
								break
							e += 1
						var length := e - b + 1
						longest = maxi(longest, length)
						if length >= 8:
							ends[Floor.pos_index(p, Floor.Pos.make(level, x, y))] = true
							var ex := e if axis == 0 else a
							var ey := a if axis == 0 else e
							ends[Floor.pos_index(p, Floor.Pos.make(level, ex, ey))] = true
						b = e + 1
		longest_min = mini(longest_min, longest)
		t.check(longest >= 8, "%s: longest straight corridor %d cells" % [_key(p), longest])
		t.check(ends.has(Floor.pos_index(p, p.entity_start)), "%s: the entity does not start at the end of a straight corridor of 8+" % _key(p))
		var dist := _bfs(p, [p.landing] as Array[Floor.Pos])
		var steps := int(dist.get(Floor.pos_index(p, p.entity_start), -1))
		t.check(steps >= 12, "%s: entity start %d steps from the landing" % [_key(p), steps])
		var lobbies := 0
		for r in p.rooms:
			if r.kind != &"lobby":
				continue
			lobbies += 1
			var doors := 0
			for d in p.doors:
				var a := Floor.room_id_at(p, d.level, d.ax, d.ay)
				var b := Floor.room_id_at(p, d.level, d.bx, d.by)
				if (a == r.id) != (b == r.id):
					doors += 1
			t.check(doors == 2, "%s: the lobby has %d doors" % [_key(p), doors])
			t.check(r.level == p.landing.level and Floor.room_id_at(p, p.landing.level, p.landing.x, p.landing.y) == r.id, "%s: the landing is not in the lobby" % _key(p))
		t.check(lobbies == 1, "%s: %d lobbies" % [_key(p), lobbies])
	t.note("%d floors: shortest longest straight corridor %d cells; every entity start at the end of one, 12+ steps away; one lobby, two doors" % [ps.size(), longest_min])

## A block-relative cell (-1..6) turned by `turn` quarter turns.
static func _turn(turn: int, x: int, y: int) -> Vector2i:
	match turn:
		0:
			return Vector2i(x, y)
		1:
			return Vector2i(BLOCK - 1 - y, x)
		2:
			return Vector2i(BLOCK - 1 - x, BLOCK - 1 - y)
		_:
			return Vector2i(y, BLOCK - 1 - x)

## 7. Rooms repeat: the most common block shape (rooms and doors, relative to the block, the same
## arrangement turned counting as the same) appears at least four times on level 0.
func test_rooms_repeat(t: T) -> void:
	var ps := plans(t.quick)
	var fewest := 1 << 30
	for p in ps:
		var lat := _lattice(p)
		var n: int = lat[2]
		if not t.check(n >= 4, "%s: level 0's corridors are not a square lattice" % _key(p)):
			continue
		var shapes := {}
		var most := 0
		for r in n:
			for c in n:
				var ox: int = lat[0] + PITCH * c + 1
				var oy: int = lat[1] + PITCH * r + 1
				var rooms: Array[Floor.Room] = []
				for room in p.rooms:
					if room.level == 0 and room.x >= ox and room.y >= oy and room.x + room.w <= ox + BLOCK and room.y + room.h <= oy + BLOCK:
						rooms.append(room)
				if rooms.is_empty():
					continue  # stair blocks: nothing to repeat
				var doors: Array[Floor.Door] = []
				for d in p.doors:
					var a_in := d.ax >= ox and d.ay >= oy and d.ax < ox + BLOCK and d.ay < oy + BLOCK
					var b_in := d.bx >= ox and d.by >= oy and d.bx < ox + BLOCK and d.by < oy + BLOCK
					if d.level == 0 and (a_in or b_in):
						doors.append(d)
				# The same block turned is the same shape: keep the smallest description of the four turns.
				var shape := ""
				for turn in 4:
					var parts: Array[String] = []
					for room in rooms:
						var a := _turn(turn, room.x - ox, room.y - oy)
						var c2 := _turn(turn, room.x + room.w - 1 - ox, room.y + room.h - 1 - oy)
						parts.append("r:%s:%d,%d,%d,%d" % [room.kind, mini(a.x, c2.x), mini(a.y, c2.y), absi(c2.x - a.x) + 1, absi(c2.y - a.y) + 1])
					for d in doors:
						var e1v := _turn(turn, d.ax - ox, d.ay - oy)
						var e2v := _turn(turn, d.bx - ox, d.by - oy)
						var e1 := "%d,%d" % [e1v.x, e1v.y]
						var e2 := "%d,%d" % [e2v.x, e2v.y]
						parts.append("d:" + (e1 + "|" + e2 if e1 < e2 else e2 + "|" + e1))
					parts.sort()
					var text := ";".join(parts)
					if shape.is_empty() or text < shape:
						shape = text
				shapes[shape] = int(shapes.get(shape, 0)) + 1
				most = maxi(most, int(shapes[shape]))
		fewest = mini(fewest, most)
		t.check(most >= 4, "%s: the most common block shape appears %d times on level 0" % [_key(p), most])
	t.note("%d floors: the most common level-0 block shape appears at least %d times on every floor" % [ps.size(), fewest])

## 8. At most 80 rooms; the cell above the landing is empty; the car zone beyond the elevator wall
## (3 cells along it, 2 away from it) is empty on both levels.
func test_room_count_and_shaft(t: T) -> void:
	var ps := plans(t.quick)
	var most := 0
	for p in ps:
		most = maxi(most, p.rooms.size())
		t.check(p.rooms.size() <= 80, "%s: %d rooms" % [_key(p), p.rooms.size()])
		var l := p.landing
		t.check(Floor.cell_at(p, 1, l.x, l.y) == Floor.VOID, "%s: the cell above the landing is %s" % [_key(p), Floor.cell_at(p, 1, l.x, l.y)])
		var wall := Landing.elevator_wall(p)
		if not t.check(wall != &"", "%s: the landing has no elevator wall" % _key(p)):
			continue
		var dx := Floor.dir_dx(wall)
		var dy := Floor.dir_dy(wall)
		var bad := 0
		for away in range(1, 3):
			for along in range(-1, 2):
				var x := l.x + dx * away + dy * along
				var y := l.y + dy * away + dx * along
				for level in 2:
					if not Floor.in_bounds(p, x, y) or Floor.cell_at(p, level, x, y) != Floor.VOID:
						bad += 1
		t.check(bad == 0, "%s: %d car-zone cells are not empty grid" % [_key(p), bad])
	t.note("%d floors: at most %d rooms; shaft and car zone empty" % [ps.size(), most])
