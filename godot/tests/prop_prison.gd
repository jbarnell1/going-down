# The Prison hub plan (docs/floors/prison.md, section 4 and task P4): a fixed plan, place "prison",
# no entity; every walkable cell reachable from the lift; eight bunks, one per cell; four teller
# windows in the bank room; no bunk more than 20 m of walking from the lift; the same plan on every
# call; the lift's shaft zone clear; the tellers' side of the counter out of reach; the windows
# numbered left to right as you face them; each bunk standing where the look draws it; the face kiosk in
# the hall by the cells, on the way to bed, blocking no door or walk, its screen showing the face it is
# given; SHOP over windows 1-2 and SKILLS over windows 3-4, readable from the bank door. Oracles are
# written here from floor.gd's step rule only, and the look is built from the same plan to check it.
extends RefCounted

const T = preload("res://tests/t.gd")
const Floor = preload("res://sim/floor.gd")
const Prison = preload("res://sim/prison.gd")
const PrisonView = preload("res://client/prison_view.gd")
const LevelScript = preload("res://client/level.gd")
const Walls = preload("res://sim/walls.gd")
const Run = preload("res://sim/run.gd")

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
	var k := Prison.kiosk_position()
	grid[k.y] = _put(grid[k.y], k.x, "K")
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
	t.note("map (B bunk, w teller window stand cell, K face kiosk stand cell, X lift landing, + door, . hall, # void):")
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
	t.check(z.size.x >= 2 and z.size.y >= 3, "shaft zone smaller than 2 deep by 3 along the wall")
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
	# It holds the rules' car (run.gd car_geometry: 4 m by 4 m, centred on the landing cell's wall).
	var c := Run.car_geometry(p)
	var s := float(p.cell_size)
	var zone := Rect2(Vector2(z.position) * s, Vector2(z.size) * s)
	t.check(zone.encloses(Rect2(c.rect.x0, c.rect.z0, c.rect.x1 - c.rect.x0, c.rect.z1 - c.rect.z0)),
		"the shaft zone %s (m) does not hold the car %s..%s, %s..%s" % [zone, c.rect.x0, c.rect.x1, c.rect.z0, c.rect.z1])

## The prison as the client draws it: a Level built from the plan, and its dressing. Free the Level after.
func _drawn() -> Array:
	var lv: Node3D = LevelScript.new()
	lv.call("build", PrisonView.plain_plan(), "prison")
	return [lv, lv.get_meta(&"prison")]

## A cell's door: [the cell inside the room, the cell outside], or [] if it has none.
func _door_of(p: Floor.FloorPlan, room: Floor.Room) -> Array:
	var rect := Rect2i(room.x, room.y, room.w, room.h)
	for d in p.doors:
		var a := Vector2i(d.ax, d.ay)
		var b := Vector2i(d.bx, d.by)
		if rect.has_point(a) and not rect.has_point(b):
			return [a, b]
		if rect.has_point(b) and not rect.has_point(a):
			return [b, a]
	return []

func test_the_counter_keeps_players_on_the_hall_side(t: T) -> void:
	var p := Prison.prison_plan()
	var seen := _flood(p)
	var f := Prison.COUNTER_FACING
	var z := Prison.TELLER_SIDE
	t.eq(absi(f.x) + absi(f.y), 1, "the counter faces one of the four ways")
	# Behind the glass is void: not walkable, and nothing reaches it.
	for y in range(z.position.y, z.end.y):
		for x in range(z.position.x, z.end.x):
			t.check(not Floor.is_walkable(p, 0, x, y), "the tellers' side %d,%d is walkable" % [x, y])
			t.check(not seen.has(Floor.pos_index(p, Floor.Pos.make(0, x, y))), "the tellers' side %d,%d is reachable from the lift" % [x, y])
	# Each window looks across the counter onto the tellers' side.
	var line := -1
	for w in Prison.window_positions():
		t.check(z.has_point(w + f), "window %s does not face the tellers' side across the counter" % str(w))
		var d := w.x * f.x + w.y * f.y
		t.check(line < 0 or d == line, "window %s is not on the counter line" % str(w))
		line = d
	# No reachable cell lies past the counter line within the bank room's span along it.
	var bank := Prison.BANK_ROOM
	var past := PackedStringArray()
	for y in p.height:
		for x in p.width:
			var c := Vector2i(x, y)
			var along := c.x if f.x == 0 else c.y
			var lo := bank.position.x if f.x == 0 else bank.position.y
			var hi := bank.end.x if f.x == 0 else bank.end.y
			if along >= lo and along < hi and c.x * f.x + c.y * f.y > line and seen.has(Floor.pos_index(p, Floor.Pos.make(0, x, y))):
				past.append(str(c))
	t.check(past.is_empty(), "reachable cells behind the counter: " + ", ".join(past))

func test_window_numbers_read_left_to_right_facing_the_counter(t: T) -> void:
	var f := Prison.COUNTER_FACING
	# A player facing (fx, fy) on the plan (x east, y south) has their right hand toward (-fy, fx).
	var right := Vector2i(-f.y, f.x)
	var w := Prison.window_positions()
	for i in range(1, w.size()):
		var step := w[i] - w[i - 1]
		t.check(step.x * right.x + step.y * right.y > 0, "window %d at %s is not right of window %d at %s, facing %s" % [i + 1, str(w[i]), i, str(w[i - 1]), str(f)])
	# The look numbers the panes in that order: pane i stands in front of window i, across the counter.
	var built := _drawn()
	var view: Object = built[1]
	var centres: Array[Vector3] = view.get("window_centres")
	t.eq(centres.size(), w.size(), "drawn panes")
	for i in mini(centres.size(), w.size()):
		var c := Vector2i(int(floor(centres[i].x / 2.0)), int(floor(centres[i].z / 2.0)))
		t.eq(c, w[i] + f, "pane %d is not across the counter from window %d's stand cell" % [i + 1, i + 1])
	(built[0] as Node).free()
	t.note("windows 1..4 left to right facing %s: %s" % [str(f), str(w)])

func test_each_bunk_stands_where_it_is_drawn(t: T) -> void:
	var p := Prison.prison_plan()
	var bunks := Prison.bunk_positions()
	var walls: Array[Vector2i] = []
	# The rules: each bunk cell is in its cell's door column, against the back wall (the next cell on
	# from the door is outside the room).
	for b in bunks:
		var id := Floor.room_id_at(p, 0, b.x, b.y)
		if id < 0:
			t.check(false, "bunk %s is not in a room" % str(b))
			walls.append(Vector2i.ZERO)
			continue
		var r := p.rooms[id]
		var rect := Rect2i(r.x, r.y, r.w, r.h)
		var dd := _door_of(p, r)
		t.check(not dd.is_empty(), "the cell holding bunk %s has no door" % str(b))
		if dd.is_empty():
			walls.append(Vector2i.ZERO)
			continue
		var inside: Vector2i = dd[0]
		var fwd: Vector2i = inside - (dd[1] as Vector2i)
		var off := b - inside
		t.eq(off.x * fwd.y - off.y * fwd.x, 0, "bunk %s is not in line with its door at %s" % [str(b), str(inside)])
		t.check(not rect.has_point(b + fwd), "bunk %s is not against its cell's back wall (the cell goes on to %s)" % [str(b), str(b + fwd)])
		walls.append(fwd)
	# The look: the mattress is drawn in that cell, against the far side of it from the door.
	var built := _drawn()
	var view: Object = built[1]
	var centres: Array[Vector3] = view.get("bunk_centres")
	t.eq(centres.size(), bunks.size(), "drawn bunks")
	for i in mini(centres.size(), bunks.size()):
		var c := centres[i]
		var cell := Vector2i(int(floor(c.x / 2.0)), int(floor(c.z / 2.0)))
		t.eq(cell, bunks[i], "bunk %d is drawn in another cell" % (i + 1))
		var fwd := walls[i]
		var far_edge := Vector2((bunks[i].x + 0.5 + fwd.x * 0.5) * 2.0, (bunks[i].y + 0.5 + fwd.y * 0.5) * 2.0)
		var gap := absf((far_edge - Vector2(c.x, c.z)).dot(Vector2(fwd)))
		t.check(gap < 0.6, "bunk %d is %.2f m off its back wall" % [i + 1, gap])
	(built[0] as Node).free()

## Every triangle drawn under `root` (Level space): [a, b, c, normal, plane offset, mesh name].
static func _triangles(root: Node3D) -> Array:
	var out: Array = []
	for n: Node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or not mi.visible:
			continue
		var xf := Transform3D.IDENTITY
		var up: Node = mi
		while up != null and up != root:
			if up is Node3D:
				xf = (up as Node3D).transform * xf
			up = up.get_parent()
		for s in mi.mesh.get_surface_count():
			var arrays := mi.mesh.surface_get_arrays(s)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var count := idx.size() if idx.size() > 0 else verts.size()
			for i in range(0, count - 2, 3):
				var a := xf * verts[idx[i] if idx.size() > 0 else i]
				var b := xf * verts[idx[i + 1] if idx.size() > 0 else i + 1]
				var c := xf * verts[idx[i + 2] if idx.size() > 0 else i + 2]
				var nn := (b - a).cross(c - a)
				if nn.length() < 1e-8:
					continue
				nn = nn.normalized()
				out.append([a, b, c, nn, nn.dot(a), String(mi.name)])
	return out

## How far two triangles in one plane overlap: the smallest overlap of their shadows on the six edge
## normals (separating axes). Zero or less: apart or only touching along an edge or at a corner.
static func _overlap_in_plane(p: Array, q: Array, n: Vector3) -> float:
	var u := n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()
	var v := n.cross(u)
	var pa: Array[Vector2] = []
	var qa: Array[Vector2] = []
	for i in 3:
		pa.append(Vector2((p[i] as Vector3).dot(u), (p[i] as Vector3).dot(v)))
		qa.append(Vector2((q[i] as Vector3).dot(u), (q[i] as Vector3).dot(v)))
	var least := INF
	for tri: Array[Vector2] in [pa, qa]:
		for i in 3:
			var e := tri[(i + 1) % 3] - tri[i]
			var ax := Vector2(-e.y, e.x).normalized()
			var lo1 := INF
			var hi1 := -INF
			var lo2 := INF
			var hi2 := -INF
			for w in pa:
				lo1 = minf(lo1, w.dot(ax))
				hi1 = maxf(hi1, w.dot(ax))
			for w in qa:
				lo2 = minf(lo2, w.dot(ax))
				hi2 = maxf(hi2, w.dot(ax))
			least = minf(least, minf(hi1, hi2) - maxf(lo1, lo2))
	return least

## Pairs of faces drawn in the same plane (within `tol` metres), facing the same way and overlapping by
## more than 2 mm: these fight for the same pixels and flicker as the camera moves (z-fighting).
static func _fighting_faces(root: Node3D, tol: float) -> Array[String]:
	var buckets := {}
	var tris := _triangles(root)
	for tr: Array in tris:
		var nn: Vector3 = tr[3]
		var key := "%d,%d,%d|%d" % [roundi(nn.x * 1000), roundi(nn.y * 1000), roundi(nn.z * 1000), roundi(float(tr[4]) * 1000.0)]
		if not buckets.has(key):
			buckets[key] = []
		(buckets[key] as Array).append(tr)
	var out: Array[String] = []
	var keys := buckets.keys()
	for key: String in keys:
		var nk := key.get_slice("|", 0)
		var d := int(key.get_slice("|", 1))
		var mine: Array = buckets[key]
		# The same bucket (each pair once), then the buckets up to `tol` above it.
		var others: Array = []
		for dd in range(d + 1, d + roundi(tol * 1000.0) + 1):
			others.append_array(buckets.get("%s|%d" % [nk, dd], []))
		for i in mine.size():
			var p: Array = mine[i]
			var cands: Array = mine.slice(i + 1)
			cands.append_array(others)
			for q: Array in cands:
				if absf(float(p[4]) - float(q[4])) > tol or (p[3] as Vector3).dot(q[3]) < 0.999:
					continue
				# Undersides at floor level face down into the floor and are never seen. (Godot's front
				# faces wind clockwise, so the face looks along minus the winding normal computed here.)
				if (p[3] as Vector3).y > 0.999 and absf(float(p[4])) < 0.002:
					continue
				var ov := _overlap_in_plane(p, q, p[3])
				if ov > 0.002:
					var cp := ((p[0] as Vector3) + (p[1] as Vector3) + (p[2] as Vector3)) / 3.0
					out.append("%s / %s near (%.2f, %.2f, %.2f), plane normal %s" % [p[5], q[5], cp.x, cp.y, cp.z, str(-(p[3] as Vector3))])
	return out

func test_no_two_faces_share_a_plane(t: T) -> void:
	# The owner: "the doorframes in the prison are incredibly janky, flickering like crazy". Faces in one
	# plane facing the same way flicker; none may be drawn within 1 mm of another and overlap it: walls,
	# the cell and bank door frames, every prop, and the lift in the lobby's opening.
	var built := _drawn()
	var lv: Node3D = built[0]
	var lift := Lift.new()
	lv.add_child(lift)
	lift.build(PrisonView.plain_plan()["car"], lv.call("lift_left_wall"))
	lift.set_doors(true, true)
	lift.update(0.1)
	var tris := _triangles(lv).size()
	var fights := _fighting_faces(lv, 0.001)
	t.check(fights.is_empty(), "%d pairs of faces drawn in one plane, e.g. %s" % [fights.size(), "; ".join(PackedStringArray(fights.slice(0, 4)))])
	t.note("%d triangles in the drawn prison, %d pairs in one plane" % [tris, fights.size()])
	for f: String in fights.slice(0, 80):
		t.note("  " + f)
	lv.free()

## The edge between two neighbouring cells, as Walls has it.
static func _edge_between(p: Floor.FloorPlan, a: Vector2i, b: Vector2i) -> StringName:
	var d := b - a
	if d == Vector2i(0, -1):
		return Walls.north_edge(p, 0, a.x, a.y)
	if d == Vector2i(0, 1):
		return Walls.north_edge(p, 0, b.x, b.y)
	if d == Vector2i(-1, 0):
		return Walls.west_edge(p, 0, a.x, a.y)
	return Walls.west_edge(p, 0, b.x, b.y)

func test_the_face_kiosk_stands_in_the_hall_by_the_cells(t: T) -> void:
	var p := Prison.prison_plan()
	var k := Prison.kiosk_position()
	var f := Prison.KIOSK_FACING
	t.eq(absi(f.x) + absi(f.y), 1, "the kiosk faces one of the four ways")
	# Walkable, reachable, on the hall.
	t.check(Floor.is_walkable(p, 0, k.x, k.y), "the kiosk's stand cell %s is not walkable" % str(k))
	t.check(_flood(p).has(Floor.pos_index(p, Floor.Pos.make(0, k.x, k.y))), "the kiosk's stand cell is not reachable from the lift")
	t.check(k.y == Prison.HALL_ROW and k.x >= Prison.HALL_X0 and k.x <= Prison.HALL_X1, "the kiosk %s is not on the hall" % str(k))
	t.eq(Floor.room_id_at(p, 0, k.x, k.y), -1, "the kiosk's stand cell is in a room, not the hall")
	# Beside the cells: it stands against a solid wall with a cell behind it.
	var behind := k + f
	var rid := Floor.room_id_at(p, 0, behind.x, behind.y)
	t.check(rid >= 0 and p.rooms[rid].kind == &"closet", "the wall the kiosk stands against (%s) is not a cell's" % str(behind))
	t.eq(_edge_between(p, k, behind), Walls.WALL, "the kiosk's wall")
	# It blocks no doorway: no door opens from or onto its stand cell, so whoever stands at it is not in a
	# cell's doorway; and the lift, boards, mugshot wall, windows and bunks are elsewhere.
	for d in p.doors:
		for e: Vector2i in [Vector2i(d.ax, d.ay), Vector2i(d.bx, d.by)]:
			t.check(e != k, "a door opens at the kiosk's stand cell %s" % str(k))
	for other: Vector2i in [Prison.LANDING_CELL, Prison.DAY_BOARD, Prison.MUGSHOT_WALL, Prison.REPORT_BOARD]:
		t.check(other != k, "the kiosk shares its stand cell with another station at %s" % str(other))
	t.check(not Prison.window_positions().has(k), "the kiosk stands at a teller window")
	t.check(not Prison.bunk_positions().has(k), "the kiosk stands at a bunk")
	# On the way to bed: the walk from the lift to the farthest bunk goes past it.
	var dist := Floor.distances_from(p, p.landing)
	var far := Prison.bunk_positions()[0]
	for b in Prison.bunk_positions():
		if dist[Floor.pos_index(p, Floor.Pos.make(0, b.x, b.y))] > dist[Floor.pos_index(p, Floor.Pos.make(0, far.x, far.y))]:
			far = b
	var path := Floor.find_path(p, p.landing, Floor.Pos.make(0, far.x, far.y))
	var on_path := false
	for q in path:
		on_path = on_path or (q.level == 0 and q.x == k.x and q.y == k.y)
	t.check(on_path, "the walk from the lift to the farthest bunk %s does not pass the kiosk" % str(far))
	# It does not block that walk: a body walking down the middle of the hall clears the prop (it stands
	# KIOSK_DEPTH_M out from the wall's face), with room to spare.
	var half := p.cell_size * 0.5
	var gap := half - RulesBridge.PLAYER_RADIUS - (Prison.KIOSK_DEPTH_M + LevelScript.WALL_T * 0.5)
	t.check(gap >= 0.2, "a body down the middle of the hall passes the kiosk %.2f m clear (needs 0.2)" % gap)
	var free := p.cell_size - LevelScript.WALL_T - Prison.KIOSK_DEPTH_M
	t.check(free >= 2.0 * RulesBridge.PLAYER_RADIUS + 0.5, "the hall beside the kiosk is %.2f m wide" % free)
	# The look stands it there: the screen in the stand cell, against its wall, facing the hall.
	var built := _drawn()
	var view: Object = built[1]
	var kc: Vector3 = view.get("kiosk_centre")
	t.eq(Vector2i(int(floor(kc.x / 2.0)), int(floor(kc.z / 2.0))), k, "the kiosk is drawn in another cell")
	var wall_line := Vector2((k.x + 0.5 + f.x * 0.5) * 2.0, (k.y + 0.5 + f.y * 0.5) * 2.0)
	var off := absf((wall_line - Vector2(kc.x, kc.z)).dot(Vector2(f)))
	t.check(off <= Prison.KIOSK_DEPTH_M, "the kiosk's screen is %.2f m off its wall (deeper than the kiosk)" % off)
	t.check(kc.y > 1.2 and kc.y < 1.8, "the kiosk's screen is at %.2f m, not about eye height" % kc.y)
	(built[0] as Node).free()
	t.note("face kiosk at %s, against the wall of the cell at %s; on the walk to bunk %s; %.2f m clear of a body in the hall" % [str(k), str(behind), str(far), gap])

func test_the_kiosk_screen_shows_the_face_it_is_given(t: T) -> void:
	var built := _drawn()
	var view: Object = built[1]
	var smile := FaceCodec.encode(FacePaint.starter("smile"))
	var shock := FaceCodec.encode(FacePaint.starter("shock"))
	var def_img := CrewView.default_face().get_image()
	def_img.resize(FaceCodec.SIZE, FaceCodec.SIZE, Image.INTERPOLATE_NEAREST)
	var def_hash := CrewView.image_hash(def_img)
	t.eq(view.call("kiosk_face_hash"), def_hash, "with no face the kiosk shows the default face")
	view.call("set_kiosk_face", smile)
	t.eq(view.call("kiosk_face_hash"), CrewView.texture_hash(FaceCodec.decode(smile)), "the kiosk shows the smile")
	view.call("set_kiosk_face", shock)
	t.eq(view.call("kiosk_face_hash"), CrewView.texture_hash(FaceCodec.decode(shock)), "then the shock")
	view.call("set_kiosk_face", "F1Rnot-a-face")
	t.eq(view.call("kiosk_face_hash"), def_hash, "a face that does not decode shows the default face")
	t.eq(view.get("kiosk_face"), "", "and is not kept")
	(built[0] as Node).free()

func test_shop_over_windows_one_and_two_skills_over_three_and_four(t: T) -> void:
	var p := Prison.prison_plan()
	t.eq(Prison.SHOP_WINDOWS, [1, 2] as Array[int], "shop windows")
	t.eq(Prison.SKILLS_WINDOWS, [3, 4] as Array[int], "skill tree windows")
	var w := Prison.window_positions()
	var want: Array[StringName] = [&"shop", &"shop", &"skills", &"skills"]
	for i in w.size():
		t.eq(Prison.station_at(w[i]), want[i], "window %d" % (i + 1))
	t.eq(Prison.station_at(Prison.kiosk_position()), &"kiosk", "the kiosk")
	# Nowhere else has anything to press F at.
	var stations := 0
	for y in p.height:
		for x in p.width:
			if Prison.station_at(Vector2i(x, y)) != &"":
				stations += 1
	t.eq(stations, 5, "cells with something to use")
	t.eq(PrisonView.prompt_for(w[0]), "F  SHOP", "the prompt at window 1")
	t.eq(PrisonView.prompt_for(w[3]), "F  SKILL TREE", "the prompt at window 4")
	t.eq(PrisonView.prompt_for(Prison.kiosk_position()), "F  CHANGE YOUR FACE", "the prompt at the kiosk")
	t.eq(PrisonView.prompt_for(Prison.LANDING_CELL), "", "no prompt on the landing")
	# The look: each sign over its two panes, above the glass, on the hall side, readable from the bank
	# room's doorway (its letters at least 7 of the game's 270 picture rows tall from there).
	var built := _drawn()
	var view: Object = built[1]
	var centres: Array[Vector3] = view.get("window_centres")
	var signs: Dictionary = view.get("sign_centres")
	var door := Vector3((Prison.BANK_DOOR_X + 0.5) * 2.0, 1.65, Prison.BANK_ROOM.position.y * 2.0)
	for key: String in ["shop", "skills"]:
		t.check(signs.has(key), "no %s sign" % key)
		if not signs.has(key) or centres.size() < 4:
			continue
		var c: Vector3 = signs[key]
		var nums := Prison.SHOP_WINDOWS if key == "shop" else Prison.SKILLS_WINDOWS
		var a := centres[nums[0] - 1]
		var b := centres[nums[1] - 1]
		t.check(c.x >= minf(a.x, b.x) and c.x <= maxf(a.x, b.x), "the %s sign (x %.2f) is not over windows %s (x %.2f, %.2f)" % [key, c.x, str(nums), a.x, b.x])
		t.check(c.y > 2.45 and c.y < LevelScript.LH, "the %s sign is at %.2f m, not over the glass" % [key, c.y])
		t.check(c.z < a.z, "the %s sign is behind the glass" % key)
		# The plate is 20 texels tall with 14 of them letters (prison_view.gd _plate).
		var dd := door.distance_to(c)
		var rows := PrisonView.SIGN_H * (14.0 / 20.0) / (2.0 * dd * tan(deg_to_rad(35.0))) * 270.0
		t.check(rows >= 7.0, "the %s sign's letters are %.1f picture rows tall from the bank door (%.1f m)" % [key, rows, dd])
		t.note("%s sign over windows %s: letters %.1f rows tall from the bank doorway, %.1f m away" % [key, str(nums), rows, dd])
	(built[0] as Node).free()
