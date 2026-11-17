# The Prison hub plan (docs/floors/prison.md, section 4 and task P4): a fixed plan, place "prison",
# no entity; every walkable cell reachable from the lift; eight bunks, one per cell; four teller
# windows in the bank room; no bunk more than 20 m of walking from the lift; the same plan on every
# call; the lift's shaft zone clear. Oracles are written here from floor.gd's step rule only.
extends RefCounted

const T = preload("res://tests/t.gd")
const Floor = preload("res://sim/floor.gd")
const Prison = preload("res://sim/prison.gd")

## Every position reachable from the landing, as pos_index keys (a flood fill over can_step).
func _flood(p: Floor.FloorPlan) -> Dictionary:
	var seen := {}
	var stack: Array[Floor.Pos] = [p.landing]
	seen[Floor.pos_index(p, p.landing)] = true
	while not stack.is_empty():
		var c: Floor.Pos = stack.pop_back()
		for level: int in [c.level, 1 - c.level]:
			for d: Vector2i in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
				var n := Floor.Pos.make(level, c.x + d.x, c.y + d.y)
				if not Floor.in_bounds(p, n.x, n.y):
					continue
				var key := Floor.pos_index(p, n)
				if seen.has(key) or not Floor.can_step(p, c, n):
					continue
				seen[key] = true
				stack.append(n)
	return seen

## The text map from floor.gd, with bunks drawn as B and window stand cells as w.
func _map(p: Floor.FloorPlan) -> String:
	var rows := Floor.render_ascii(p, 0).split("\n")
	var grid: Array = []
	for r in rows:
		grid.append(r)
	for b in Prison.bunk_positions():
		grid[b.y] = _put(grid[b.y], b.x, "B")
	for w in Prison.window_positions():
		grid[w.y] = _put(grid[w.y], w.x, "w")
	return "\n".join(PackedStringArray(grid))

func _put(row: String, x: int, ch: String) -> String:
	return row.substr(0, x) + ch + row.substr(x + 1)

func test_every_walkable_cell_and_room_reachable_from_the_landing(t: T) -> void:
	var p := Prison.prison_plan()
	var seen := _flood(p)
	var walkable := 0
	var missing := PackedStringArray()
	for level in 2:
		for y in p.height:
			for x in p.width:
				if Floor.is_walkable(p, level, x, y):
					walkable += 1
					if not seen.has(Floor.pos_index(p, Floor.Pos.make(level, x, y))):
						missing.append("L%d %d,%d" % [level, x, y])
	t.check(missing.is_empty(), "walkable cells not reachable from the landing: " + ", ".join(missing))
	for r in p.rooms:
		t.check(seen.has(Floor.pos_index(p, Floor.Pos.make(r.level, r.x, r.y))), "room %d (%s) not reachable" % [r.id, r.kind])
	t.check(Floor.is_walkable(p, p.landing.level, p.landing.x, p.landing.y), "the landing is not walkable")
	t.note("%d walkable cells, %d rooms, %d doors" % [walkable, p.rooms.size(), p.doors.size()])
	t.note("map (B bunk, w teller window stand cell, E lift landing, + door, . hall, # void):")
	for line in _map(p).split("\n"):
		t.note("  " + line)

func test_fixed_place_one_level_no_entity(t: T) -> void:
	var p := Prison.prison_plan()
	t.eq(p.place, &"prison", "place")
	t.eq(p.stairs.size(), 0, "stairs")
	var upper := 0
	for k: StringName in p.cells[1]:
		if k != Floor.VOID:
			upper += 1
	t.eq(upper, 0, "non-void cells on level 1")
	t.eq(p.landing.level, 0, "landing level")
	# FloorPlan has no "none" for the entity; the plan parks it on the landing, as the clinic's fallback does.
	t.check(p.entity_start.equals(p.landing), "entity_start is not the landing")
	t.eq(p.cell_size, 2, "cell size")

func test_eight_bunks_and_four_windows(t: T) -> void:
	var p := Prison.prison_plan()
	var bunks := Prison.bunk_positions()
	t.eq(bunks.size(), 8, "bunks")
	var seen_cells := {}
	for b in bunks:
		t.check(Floor.is_walkable(p, 0, b.x, b.y), "bunk %s is not on walkable floor" % str(b))
		var id := Floor.room_id_at(p, 0, b.x, b.y)
		t.check(id >= 0 and p.rooms[id].kind == &"closet", "bunk %s is not inside a cell" % str(b))
		t.check(not seen_cells.has(id), "two bunks in cell room %d" % id)
		seen_cells[id] = true
	t.eq(seen_cells.size(), 8, "distinct cells holding a bunk")
	var closets := 0
	for r in p.rooms:
		if r.kind == &"closet":
			closets += 1
	t.eq(closets, 8, "cell rooms")
	var windows := Prison.window_positions()
	t.eq(windows.size(), 4, "windows")
	var bank_id := -1
	for r in p.rooms:
		if r.kind == &"ward":
			bank_id = r.id
	t.check(bank_id >= 0, "no bank room")
	var distinct := {}
	for w in windows:
		t.eq(Floor.room_id_at(p, 0, w.x, w.y), bank_id, "window %s is not in the bank room" % str(w))
		distinct[w] = true
	t.eq(distinct.size(), 4, "distinct windows")

func test_no_bunk_over_twenty_metres_from_the_lift(t: T) -> void:
	var p := Prison.prison_plan()
	var dist := Floor.distances_from(p, p.landing)
	var worst := 0
	for b in Prison.bunk_positions():
		var steps := dist[Floor.pos_index(p, Floor.Pos.make(0, b.x, b.y))]
		t.check(steps >= 0, "bunk %s unreachable" % str(b))
		var metres := steps * p.cell_size
		worst = maxi(worst, metres)
		t.check(metres <= Prison.MAX_BUNK_WALK_M, "bunk %s is %d m from the lift (limit %d)" % [str(b), metres, Prison.MAX_BUNK_WALK_M])
	# The bank room is on the way: its door is nearer the lift than any bunk.
	var door_steps := dist[Floor.pos_index(p, Floor.Pos.make(0, Prison.BANK_DOOR_X, Prison.HALL_ROW))]
	t.check(door_steps * p.cell_size < worst, "the bank room door is not nearer the lift than the farthest bunk")
	for w in Prison.window_positions():
		t.check(dist[Floor.pos_index(p, Floor.Pos.make(0, w.x, w.y))] * p.cell_size <= Prison.MAX_BUNK_WALK_M, "window %s too far from the lift" % str(w))
	t.note("farthest bunk: %d m of walking" % worst)

func test_same_plan_on_every_call(t: T) -> void:
	var first := Floor.hash_plan(Prison.prison_plan())
	for i in 5:
		t.eq(Floor.hash_plan(Prison.prison_plan()), first, "plan hash on call %d" % i)
	t.note("plan hash " + first)

func test_the_lift_shaft_zone_is_clear(t: T) -> void:
	var p := Prison.prison_plan()
	var z := Prison.SHAFT_ZONE
	t.check(z.size.x >= 2 and z.size.y >= 2, "shaft zone smaller than 2 by 2 cells")
	for level in 2:
		for y in range(z.position.y, z.position.y + z.size.y):
			for x in range(z.position.x, z.position.x + z.size.x):
				t.eq(Floor.cell_at(p, level, x, y), Floor.VOID, "shaft cell L%d %d,%d" % [level, x, y])
				t.eq(Floor.room_id_at(p, level, x, y), -1, "room over shaft cell L%d %d,%d" % [level, x, y])
	for d in p.doors:
		for e: Vector2i in [Vector2i(d.ax, d.ay), Vector2i(d.bx, d.by)]:
			t.check(not z.has_point(e), "a door touches the shaft zone at %s" % str(e))
	# It sits directly behind the landing (the lobby's west wall), and the grid has room around it.
	t.check(z.position.x + z.size.x == p.landing.x, "the shaft zone does not end at the landing's west side")
	t.check(p.landing.y >= z.position.y and p.landing.y < z.position.y + z.size.y, "the shaft zone is not level with the landing")
	t.check(z.position.x >= 1 and z.position.y >= 1, "the shaft zone touches the grid edge")
