# The Playroom's eight guarantees (docs/floors/playarea.md section 6) on 800 floors (seed-0..199 at
# depths 1 to 4; 40 in the quick set, seed-0..9 at each depth). The Playroom has no TypeScript twin,
# so these oracles and the stored hash list (tests/playroom_hashes.json) are its proof. Oracles are
# written here from floor.gd's step rule only; the lattice is found from the plan itself (the outer
# ring is never pruned, so the bounding box of level 0's walkway is the lattice).
extends RefCounted

@warning_ignore_start("integer_division")

const T = preload("res://tests/t.gd")
const Playroom = preload("res://sim/playroom.gd")
const Floor = preload("res://sim/floor.gd")
const Landing = preload("res://sim/landing.gd")

const QUICK_SEEDS := 10
const PITCH := 7
const HASHES_PATH := "res://tests/playroom_hashes.json"
const STEPS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
## The design's table of hiding places (section 4): [holds, eye cm, gap half-angle degrees].
const HIDE_TABLE := {
	&"pit": [3, 30, 180], &"slide": [2, 60, 20], &"den": [1, 70, 40], &"playhouse": [1, 100, 25],
	&"table": [2, 30, 60], &"chest": [1, 50, 30], &"cubby": [1, 140, 15],
}
## Brute force (block every walkway cell, flood the rest) on this many floors; Tarjan on all of them.
const BRUTE_FLOORS := 40

static var _cache := {}

class Fl:
	var plan: Floor.FloorPlan
	var hides: Array[Playroom.Hide]
	var squeak: Dictionary  # pos_index -> true
	var zones: Array[Playroom.Zone]

static func floor_of(floor_seed: String, depth: int) -> Fl:
	var key := "%s/%d" % [floor_seed, depth]
	if not _cache.has(key):
		var f := Fl.new()
		f.plan = Playroom.generate_playroom(floor_seed, depth)
		f.hides = Playroom.hides(f.plan, floor_seed)
		f.squeak = {}
		for k in Playroom.squeakers(f.plan, floor_seed):
			f.squeak[k] = true
		f.zones = Playroom.zones(f.plan)
		_cache[key] = f
	return _cache[key]

## Depth-major, like tests/plans.gd property_plans.
static func floors(quick: bool) -> Array[Fl]:
	var out: Array[Fl] = []
	for depth: int in [1, 2, 3, 4]:
		for i in (QUICK_SEEDS if quick else 200):
			out.append(floor_of("seed-%d" % i, depth))
	return out

static func _key(p: Floor.FloorPlan) -> String:
	return "%s d%d" % [p.seed, p.depth]

## Steps from the nearest source to every position (pos_index), -1 if not reached, over
## Floor.can_step_xy. `blocked` cells are never entered; `reverse` follows steps backwards.
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
		if dist[k] == -1 and not blocked.has(k):
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

static func _walkable_count(p: Floor.FloorPlan, dist: PackedInt32Array, blocked: Dictionary) -> int:
	var missing := 0
	for level in 2:
		for y in p.height:
			for x in p.width:
				var k := Floor.pos_index(p, Floor.Pos.make(level, x, y))
				if Floor.is_walkable(p, level, x, y) and not blocked.has(k) and dist[k] < 0:
					missing += 1
	return missing

## The lattice, from the plan: [x0, y0, blocks a side] (0 blocks if level 0's walkway is not a lattice).
static func _lattice(p: Floor.FloorPlan) -> Array[int]:
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

## Walkway cells of a level: walkway on the lattice's lines, as row-major cell indices, ascending.
static func _walkway(p: Floor.FloorPlan, lat: Array[int], level: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var size := PITCH * lat[2] + 1
	for y in p.height:
		for x in p.width:
			var lx := x - lat[0]
			var ly := y - lat[1]
			if lx < 0 or ly < 0 or lx >= size or ly >= size:
				continue
			if (lx % PITCH == 0 or ly % PITCH == 0) and Floor.cell_at(p, level, x, y) == Floor.CORRIDOR:
				out.append(y * p.width + x)
	return out

# ---------------------------------------------------------------------------------------------

## 1. Every walkable cell is reachable from the landing, and can walk back to it.
func test_every_walkable_cell_reachable_and_back(t: T) -> void:
	var fs := floors(t.quick)
	var there := 0
	var back := 0
	var walkable := 0
	for f in fs:
		var p := f.plan
		var a := _walkable_count(p, _search(p, [p.landing] as Array[Floor.Pos], {}, false), {})
		var b := _walkable_count(p, _search(p, [p.landing] as Array[Floor.Pos], {}, true), {})
		for level in 2:
			for y in p.height:
				for x in p.width:
					if Floor.is_walkable(p, level, x, y):
						walkable += 1
		there += a
		back += b
		t.check(a == 0, "%s: %d walkable cells not reachable from the landing" % [_key(p), a])
		t.check(b == 0, "%s: %d walkable cells cannot walk back to the landing" % [_key(p), b])
	t.eq(there, 0, "walkable cells not reachable from the landing")
	t.eq(back, 0, "walkable cells that cannot walk back")
	t.note("%d floors, %d walkable cells, all reached from the landing and all walk back" % [fs.size(), walkable])

## Cut cells of a graph (Tarjan, iterative): cells whose removal splits the rest. `nbrs[i]` lists i's
## neighbours. Also returns -1 in the first slot if the graph is not connected.
static func _cut_cells(nbrs: Array[PackedInt32Array]) -> PackedInt32Array:
	var cut := PackedInt32Array()
	var count := nbrs.size()
	if count == 0:
		return cut
	var disc := PackedInt32Array()
	disc.resize(count)
	disc.fill(-1)
	var low := PackedInt32Array()
	low.resize(count)
	var is_cut := PackedByteArray()
	is_cut.resize(count)
	var st := PackedInt32Array([0])
	var parent := PackedInt32Array([-1])
	var nxt := PackedInt32Array([0])
	disc[0] = 0
	low[0] = 0
	var timer := 1
	var root_kids := 0
	while not st.is_empty():
		var top := st.size() - 1
		var u := st[top]
		var k := nxt[top]
		if k < nbrs[u].size():
			nxt[top] = k + 1
			var v := nbrs[u][k]
			if v == parent[top]:
				continue
			if disc[v] == -1:
				disc[v] = timer
				low[v] = timer
				timer += 1
				if top == 0:
					root_kids += 1
				st.append(v)
				parent.append(u)
				nxt.append(0)
			else:
				low[u] = mini(low[u], disc[v])
		else:
			st.resize(top)
			parent.resize(top)
			nxt.resize(top)
			if top > 0:
				var pu := st[top - 1]
				low[pu] = mini(low[pu], low[u])
				if top - 1 > 0 and low[u] >= disc[pu]:
					is_cut[pu] = 1
	if root_kids > 1:
		is_cut[0] = 1
	for i in count:
		if disc[i] == -1:
			return PackedInt32Array([-1])
	for i in count:
		if is_cut[i] == 1:
			cut.append(i)
	return cut

## 2. The outer ring is whole on both levels; block any one walkway cell and the rest of that level's
## walkway is still connected (through walkway); block one stair and everything else, level 1
## included, is still reachable. Exactly two stairs.
func test_walkway_survives_any_one_block(t: T) -> void:
	var fs := floors(t.quick)
	var cells_checked := 0
	var brute_checked := 0
	var stairs_checked := 0
	for fi in fs.size():
		var p := fs[fi].plan
		var lat := _lattice(p)
		var n := lat[2]
		if not t.check(n >= 4, "%s: level 0's walkway is not a square lattice" % _key(p)):
			continue
		var size := PITCH * n + 1
		for level in 2:
			var gaps := 0
			for i in size:
				for c: Vector2i in [Vector2i(lat[0] + i, lat[1]), Vector2i(lat[0] + i, lat[1] + size - 1), Vector2i(lat[0], lat[1] + i), Vector2i(lat[0] + size - 1, lat[1] + i)]:
					if Floor.cell_at(p, level, c.x, c.y) != Floor.CORRIDOR:
						gaps += 1
			t.check(gaps == 0, "%s L%d: the outer ring is missing %d cells" % [_key(p), level, gaps])
			var cells := _walkway(p, lat, level)
			var ids := {}
			for i in cells.size():
				ids[cells[i]] = i
			var nbrs: Array[PackedInt32Array] = []
			for c in cells:
				var cx := c % p.width
				var cy := c / p.width
				var list := PackedInt32Array()
				for d in STEPS:
					var k: int = ids.get((cy + d.y) * p.width + cx + d.x, -1)
					if k >= 0 and Floor.can_step_xy(p, level, cx, cy, level, cx + d.x, cy + d.y):
						list.append(k)
				nbrs.append(list)
			cells_checked += cells.size()
			var cut := _cut_cells(nbrs)
			if cut.size() > 0 and cut[0] == -1:
				t.check(false, "%s L%d: the walkway is in pieces" % [_key(p), level])
			elif cut.size() > 0:
				var c0 := cells[cut[0]]
				t.check(false, "%s L%d: blocking walkway cell %d,%d cuts the walkway (%d such cells)" % [_key(p), level, c0 % p.width, c0 / p.width, cut.size()])
			if fi < BRUTE_FLOORS:
				# The same by brute force: block each cell, flood the rest.
				var bad := 0
				for blocked in cells.size():
					brute_checked += 1
					var start := 0 if blocked != 0 else 1
					var seen := PackedByteArray()
					seen.resize(cells.size())
					seen[blocked] = 1
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
							var cb := cells[blocked]
							t.check(false, "%s L%d: blocking walkway cell %d,%d cuts off %d walkway cells" % [_key(p), level, cb % p.width, cb / p.width, cells.size() - 1 - count])
		t.check(p.stairs.size() == 2, "%s: %d stairs" % [_key(p), p.stairs.size()])
		for si in p.stairs.size():
			stairs_checked += 1
			var blocked := {}
			for c in Floor.stair_cells(p.stairs[si]):
				blocked[Floor.pos_index(p, c)] = true
			var lost := _walkable_count(p, _search(p, [p.landing] as Array[Floor.Pos], blocked, false), blocked)
			t.check(lost == 0, "%s: with stair %d blocked, %d cells cannot be reached" % [_key(p), si, lost])
	t.note("%d floors: %d walkway cells, none a cut cell (Tarjan); %d blocked one at a time on the first %d floors; %d stairs blocked one at a time" % [fs.size(), cells_checked, brute_checked, mini(fs.size(), BRUTE_FLOORS), stairs_checked])

## 3. Same seed, same plan, hides, squeakers, zones and seats: generating twice gives the same five
## hashes, and every floor's hashes match the stored list (tools/playroom_tool.gd -- hashes).
func test_same_floor_for_everyone(t: T) -> void:
	var text := FileAccess.get_file_as_string(HASHES_PATH)
	var stored: Variant = JSON.parse_string(text)
	if not t.check(stored is Dictionary, "cannot read %s" % HASHES_PATH):
		return
	var want: Dictionary = stored
	var fs := floors(t.quick)
	var differ := 0
	var mismatched := 0
	var names: Array[String] = ["plan", "hides", "squeakers", "zones", "seats"]
	for f in fs:
		var p := f.plan
		t.check(p.place == &"playroom", "%s: place %s" % [_key(p), p.place])
		var h := Playroom.floor_hashes(p)
		var again := Playroom.floor_hashes(Playroom.generate_playroom(p.seed, p.depth))
		var key := "%s/%d" % [p.seed, p.depth]
		var got_stored: Variant = want.get(key, [])
		var stored_list: Array = got_stored if got_stored is Array else []
		for i in names.size():
			if h[i] != again[i]:
				differ += 1
				if differ <= 3:
					t.check(false, "%s: %s generated twice, hashes %s and %s" % [_key(p), names[i], h[i], again[i]])
			var s := str(stored_list[i]) if i < stored_list.size() else "(none)"
			if s != h[i]:
				mismatched += 1
				if mismatched <= 3:
					t.check(false, "%s: %s hash %s, stored %s" % [_key(p), names[i], h[i], s])
	t.eq(differ, 0, "lists whose two generations differ")
	t.eq(mismatched, 0, "lists whose hash differs from the stored list")
	t.note("%d floors generated twice, same five hashes; all match %s (%d stored)" % [fs.size(), HASHES_PATH.get_file(), want.size()])

## 4. Every kind of block is on level 0 (ball pit, frame, party room, toddler corner, cloakroom, two
## stair blocks). Each level's hides hold at least 16 players. From every walkway cell a hide's front
## spot is within 14 steps.
func test_kinds_capacity_and_reach(t: T) -> void:
	var fs := floors(t.quick)
	var least_cap := 1 << 30
	var farthest := 0
	for f in fs:
		var p := f.plan
		var lat := _lattice(p)
		var n := lat[2]
		if not t.check(n >= 4, "%s: not a lattice" % _key(p)):
			continue
		var kinds := {}
		var stair_blocks := 0
		var stair_cells := {}
		for s in p.stairs:
			for c in Floor.stair_cells(s):
				stair_cells[Vector2i(c.x, c.y)] = true
		for r in n:
			for c in n:
				var ox: int = lat[0] + PITCH * c + 1
				var oy: int = lat[1] + PITCH * r + 1
				var has_stair := false
				for y in range(oy, oy + 6):
					for x in range(ox, ox + 6):
						if stair_cells.has(Vector2i(x, y)):
							has_stair = true
				if has_stair:
					stair_blocks += 1
				for room in p.rooms:
					if room.level == 0 and room.x >= ox and room.y >= oy and room.x + room.w <= ox + 6 and room.y + room.h <= oy + 6:
						kinds[room.kind] = true
		for k: StringName in [&"ballpit", &"den", &"party", &"toddler", &"cloak"]:
			t.check(kinds.has(k), "%s: no %s block on level 0" % [_key(p), k])
		t.check(stair_blocks == 2, "%s: %d stair blocks" % [_key(p), stair_blocks])
		var cap: Array[int] = [0, 0]
		var fronts: Array[Floor.Pos] = []
		for h in f.hides:
			cap[h.level] += h.capacity
			fronts.append(Floor.Pos.make(h.level, h.front.x / 200, h.front.y / 200))
		for level in 2:
			least_cap = mini(least_cap, cap[level])
			t.check(cap[level] >= 16, "%s: level %d's hides hold %d" % [_key(p), level, cap[level]])
		var dist := _search(p, fronts, {}, true)  # steps from each cell to the nearest hide front
		for level in 2:
			for c in _walkway(p, lat, level):
				var k := level * p.width * p.height + c
				var d := dist[k] if dist[k] >= 0 else 999
				farthest = maxi(farthest, d)
				if d > 14:
					t.check(false, "%s L%d: walkway cell %d,%d is %d steps from a hide" % [_key(p), level, c % p.width, c / p.width, d])
	t.note("%d floors: every block kind on level 0; least hide capacity on a level %d; farthest walkway cell %d steps from a hide" % [fs.size(), least_cap, farthest])

## 5. Every hide's front and inside spots are inside its room and clear of its walls by 0.3 m, the front
## a walkable spot in the same room within 0.8 m of the inside, the gap facing into the room; each kind
## as the design's table; every zone has 1 to 5 hides and its sign's number is its hide count.
func test_hide_geometry_and_signs(t: T) -> void:
	var fs := floors(t.quick)
	var total := 0
	var zones_total := 0
	for f in fs:
		var p := f.plan
		var count := {}
		var bad := 0
		for h in f.hides:
			total += 1
			count[h.zone] = (count.get(h.zone, 0) as int) + 1
			var room := p.rooms[h.room]
			var x0 := room.x * 200
			var y0 := room.y * 200
			var x1 := (room.x + room.w) * 200
			var y1 := (room.y + room.h) * 200
			var ok := room.level == h.level
			for q: Vector2i in [h.inside, h.front]:
				ok = ok and q.x >= x0 + 30 and q.x <= x1 - 30 and q.y >= y0 + 30 and q.y <= y1 - 30
				ok = ok and Floor.room_id_at(p, h.level, q.x / 200, q.y / 200) == h.room and Floor.is_walkable(p, h.level, q.x / 200, q.y / 200)
			var dv := h.front - h.inside
			ok = ok and dv.x * dv.x + dv.y * dv.y <= 80 * 80
			var into := h.inside + Vector2i(Floor.dir_dx(h.gap), Floor.dir_dy(h.gap)) * 50
			ok = ok and into.x > x0 and into.x < x1 and into.y > y0 and into.y < y1
			var row: Array = HIDE_TABLE.get(h.kind, [])
			ok = ok and row.size() == 3 and h.capacity == (row[0] as int) and h.eye == (row[1] as int) and h.gap_half == (row[2] as int)
			if not ok:
				bad += 1
				if bad <= 3:
					t.check(false, "%s: hide %d (%s in room %d) breaks the geometry: inside %s front %s gap %s" % [_key(p), h.id, h.kind, h.room, h.inside, h.front, h.gap])
		var zone_ids := {}
		for z in f.zones:
			zones_total += 1
			zone_ids[z.id] = true
			var n: int = count.get(z.id, 0)
			t.check(n >= 1 and n <= 5, "%s: zone %d (%s) has %d hides" % [_key(p), z.id, z.kind, n])
			t.check(z.hides == n, "%s: zone %d's sign says %d, it has %d hides" % [_key(p), z.id, z.hides, n])
			t.check(Playroom.sign_text(z) == "HIDING PLACES HERE: %d. IT LOOKS IN 1." % n, "%s: zone %d's sign reads %s" % [_key(p), z.id, Playroom.sign_text(z)])
			t.check(z.doors.size() >= 1, "%s: zone %d has no way in" % [_key(p), z.id])
		for h in f.hides:
			if not zone_ids.has(h.zone):
				t.check(false, "%s: hide %d is in zone %d, which is not listed" % [_key(p), h.id, h.zone])
				break
	t.note("%d floors: %d hides, %d zones; every spot inside its room, every sign right" % [fs.size(), total, zones_total])

## 6. Between any two walkway cells there is a path that crosses no squeaker tile; more, every walkable
## cell that is not a squeaker is reached from the landing without crossing one. No squeaker in the
## lobby, on a door's cells or on a hide's spots; every squeaker is on the walkway or in a toddler corner.
func test_quiet_way_through(t: T) -> void:
	var fs := floors(t.quick)
	var on_walkway := 0
	var in_toddler := 0
	for f in fs:
		var p := f.plan
		var nc := p.width * p.height
		var lat := _lattice(p)
		var doors := {}
		for d in p.doors:
			doors[d.level * nc + d.ay * p.width + d.ax] = true
			doors[d.level * nc + d.by * p.width + d.bx] = true
		var spots := {}
		for h in f.hides:
			spots[h.level * nc + (h.inside.y / 200) * p.width + h.inside.x / 200] = true
			spots[h.level * nc + (h.front.y / 200) * p.width + h.front.x / 200] = true
		var walkway := {}
		for level in 2:
			for c in _walkway(p, lat, level):
				walkway[level * nc + c] = true
		var misplaced := 0
		for k: int in f.squeak:
			var level := k / nc
			var c := k % nc
			var room := Floor.room_id_at(p, level, c % p.width, c / p.width)
			if walkway.has(k):
				on_walkway += 1
			elif room >= 0 and p.rooms[room].kind == &"toddler":
				in_toddler += 1
			else:
				misplaced += 1
			if doors.has(k) or spots.has(k) or (room >= 0 and p.rooms[room].kind == &"lobby"):
				misplaced += 1
		t.check(misplaced == 0, "%s: %d squeakers where none may be" % [_key(p), misplaced])
		# Walkway to walkway, quietly.
		var first := Floor.Pos.make(0, lat[0], lat[1])
		var quiet := _search(p, [first] as Array[Floor.Pos], f.squeak, false)
		var cut := 0
		for k: int in walkway:
			if not f.squeak.has(k) and quiet[k] < 0:
				cut += 1
		t.check(cut == 0, "%s: %d walkway cells cannot be reached from another without crossing a squeaker" % [_key(p), cut])
		# Every quiet cell from the landing.
		var lost := _walkable_count(p, _search(p, [p.landing] as Array[Floor.Pos], f.squeak, false), f.squeak)
		t.check(lost == 0, "%s: %d quiet cells cannot be reached from the landing without crossing a squeaker" % [_key(p), lost])
	if not t.quick:
		t.check(on_walkway > 0 and in_toddler > 0, "squeakers on walkways %d, in toddler corners %d" % [on_walkway, in_toddler])
	t.note("%d floors: %d squeakers on walkways, %d in toddler corners; always a quiet way through" % [fs.size(), on_walkway, in_toddler])

## 7. The entity starts in the party room farthest from the landing, 12 or more steps away, against the
## wall it faces; the eight seats are in that room, clear of its walls, facing the table. One lobby
## with two doors, the landing, no hides and no squeakers; the shaft and the car zone are clear.
func test_entity_seats_lobby_and_car(t: T) -> void:
	var fs := floors(t.quick)
	var nearest := 1 << 30
	for f in fs:
		var p := f.plan
		var dist := _search(p, [p.landing] as Array[Floor.Pos], {}, false)
		var start_room := Floor.room_id_at(p, p.entity_start.level, p.entity_start.x, p.entity_start.y)
		if not t.check(start_room >= 0 and p.rooms[start_room].kind == &"party", "%s: the entity does not start in a party room" % _key(p)):
			continue
		var steps := dist[Floor.pos_index(p, p.entity_start)]
		nearest = mini(nearest, steps)
		t.check(steps >= 12, "%s: entity start %d steps from the landing" % [_key(p), steps])
		# Farthest party room: steps to its nearest cell.
		var room_steps := {}
		for room in p.rooms:
			if room.kind != &"party":
				continue
			var d := 1 << 30
			for y in range(room.y, room.y + room.h):
				for x in range(room.x, room.x + room.w):
					var k := dist[Floor.pos_index(p, Floor.Pos.make(room.level, x, y))]
					if k >= 0:
						d = mini(d, k)
			room_steps[room.id] = d
		for id: int in room_steps:
			t.check((room_steps[start_room] as int) >= (room_steps[id] as int), "%s: party room %d is farther than the start's" % [_key(p), id])
		var face := Playroom.entity_facing(p)
		var ahead := Floor.room_id_at(p, p.entity_start.level, p.entity_start.x + Floor.dir_dx(face), p.entity_start.y + Floor.dir_dy(face))
		t.check(ahead != start_room, "%s: the entity faces %s, not a wall" % [_key(p), face])
		# Seats.
		var room := p.rooms[start_room]
		var seats := Playroom.seats(p)
		t.check(seats.size() == 8, "%s: %d seats" % [_key(p), seats.size()])
		var centre := Vector2i(room.x * 200 + room.w * 100, room.y * 200 + room.h * 100)
		var taken := {}
		for s in seats:
			var ok := s.level == room.level and s.at.x >= room.x * 200 + 30 and s.at.x <= (room.x + room.w) * 200 - 30 \
				and s.at.y >= room.y * 200 + 30 and s.at.y <= (room.y + room.h) * 200 - 30 \
				and Floor.room_id_at(p, s.level, s.at.x / 200, s.at.y / 200) == start_room and not taken.has(s.at)
			var to_table := centre - s.at
			ok = ok and Floor.dir_dx(s.facing) * to_table.x + Floor.dir_dy(s.facing) * to_table.y > 0
			taken[s.at] = true
			t.check(ok, "%s: seat %d at %s facing %s is not a seat at the table" % [_key(p), s.index, s.at, s.facing])
		# Lobby.
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
			t.check(Floor.room_id_at(p, p.landing.level, p.landing.x, p.landing.y) == r.id, "%s: the landing is not in the lobby" % _key(p))
			for h in f.hides:
				t.check(h.room != r.id, "%s: hide %d is in the lobby" % [_key(p), h.id])
			for y in range(r.y, r.y + r.h):
				for x in range(r.x, r.x + r.w):
					t.check(not f.squeak.has(Floor.pos_index(p, Floor.Pos.make(r.level, x, y))), "%s: a squeaker in the lobby at %d,%d" % [_key(p), x, y])
		t.check(lobbies == 1, "%s: %d lobbies" % [_key(p), lobbies])
		# Shaft and car zone.
		var l := p.landing
		t.check(Floor.cell_at(p, 1, l.x, l.y) == Floor.VOID, "%s: the cell above the landing is %s" % [_key(p), Floor.cell_at(p, 1, l.x, l.y)])
		var wall := Landing.elevator_wall(p)
		if not t.check(wall != &"", "%s: the landing has no elevator wall" % _key(p)):
			continue
		var bad := 0
		for away in range(1, 3):
			for along in range(-1, 2):
				var x := l.x + Floor.dir_dx(wall) * away + Floor.dir_dy(wall) * along
				var y := l.y + Floor.dir_dy(wall) * away + Floor.dir_dx(wall) * along
				for level in 2:
					if not Floor.in_bounds(p, x, y) or Floor.cell_at(p, level, x, y) != Floor.VOID:
						bad += 1
		t.check(bad == 0, "%s: %d car-zone cells are not empty grid" % [_key(p), bad])
	t.note("%d floors: the entity in the farthest party room, at least %d steps away; eight seats; one lobby, two doors; car zone clear" % [fs.size(), nearest])

## 8. At most 80 rooms.
func test_room_count(t: T) -> void:
	var fs := floors(t.quick)
	var most := 0
	var least := 1 << 30
	for f in fs:
		most = maxi(most, f.plan.rooms.size())
		least = mini(least, f.plan.rooms.size())
		t.check(f.plan.rooms.size() <= 80, "%s: %d rooms" % [_key(f.plan), f.plan.rooms.size()])
	t.note("%d floors: %d to %d rooms" % [fs.size(), least, most])

func test_playroom_view_uses_the_floor_and_hides_already_on_the_client(t: T) -> void:
	var plan := Playroom.generate_playroom("arrival-a", 4)
	var hides := Playroom.hides(plan, plan.seed)
	var level := preload("res://client/level.gd").new()
	var car := preload("res://sim/run.gd").car_geometry(plan)
	level.build(preload("res://client/plan_dump.gd").dump(plan, car), plan.seed, plan, hides)
	var view: Node = level.get_meta("playroom")
	t.check(is_same(view.get("fp"), plan), "the Playroom draws the same floor plan that the client accepted")
	t.check(is_same(view.get("hides"), hides), "the Playroom draws the client's ordered hiding places")
	level.free()
