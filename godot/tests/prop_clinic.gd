# The Clinic's guarantees on all 800 floors the property tests use (ported from
# tests/sim/clinic.test.ts): every walkable cell and every room reachable from the landing; walls
# implicit (a room beside a corridor joins it only through a door); neighbours symmetric; every
# listed sightline a real straight clear run; the entity starts 12+ steps away on a long sightline;
# two dead-end side branches per floor, each one door in. Oracles written here, from floor.gd's
# step rule only.
extends RefCounted

const T = preload("res://tests/t.gd")
const Snap = preload("res://tests/snap.gd")
const Plans = preload("res://tests/plans.gd")
const Floor = preload("res://sim/floor.gd")

func test_every_walkable_cell_reachable(t: T) -> void:
	var gkey := "clinicQuick" if t.quick else "clinic"
	var g: Variant = t.golden("properties.json", gkey)
	var want: Dictionary = g if g is Dictionary else {}
	var walkable := 0
	var missing := 0
	var unreachable_rooms := 0
	for p in Plans.property_plans(t.quick):
		# The oracle: a flood fill from the landing over can_step, written here.
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
		for level in 2:
			for y in p.height:
				for x in p.width:
					if Floor.is_walkable(p, level, x, y):
						walkable += 1
						if not seen.has(Floor.pos_index(p, Floor.Pos.make(level, x, y))):
							missing += 1
		for r in p.rooms:
			if not seen.has(Floor.pos_index(p, Floor.Pos.make(r.level, r.x, r.y))):
				unreachable_rooms += 1
	t.eq(missing, 0, "walkable cells not reachable from the landing")
	t.eq(unreachable_rooms, 0, "rooms not reachable")
	var got := {"floors": Plans.property_plans(t.quick).size(), "walkable": walkable, "missing": missing, "unreachableRooms": unreachable_rooms}
	t.expect("properties.json", gkey, got, "the counts")
	t.note("%d floors, %d walkable cells, %d unreachable%s" % [got["floors"], walkable, missing,
		"" if want.is_empty() else " (golden: %d cells, %d unreachable)" % [want["walkable"], want["missing"]]])

func test_walls_steps_sightlines_and_the_entity_start(t: T) -> void:
	var plans := Plans.property_plans(t.quick)
	var checked := 0
	var asymmetric := 0
	for pi in plans.size():
		var p := plans[pi]
		var bad := PackedStringArray()
		for level in 2:
			for y in p.height:
				for x in p.width:
					if pi < 50 and Floor.cell_at(p, level, x, y) == &"room":
						for d: Vector2i in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]:
							if Floor.cell_at(p, level, x + d.x, y + d.y) != &"corridor":
								continue
							var door := false
							for dd in p.doors:
								if dd.level == level and ((dd.ax == x and dd.ay == y and dd.bx == x + d.x and dd.by == y + d.y) or (dd.bx == x and dd.by == y and dd.ax == x + d.x and dd.ay == y + d.y)):
									door = true
							if Floor.can_step(p, Floor.Pos.make(level, x, y), Floor.Pos.make(level, x + d.x, y + d.y)) != door:
								bad.append("L%d %d,%d: a room cell next to a corridor steps %s a door" % [level, x, y, "without" if not door else "despite"])
							checked += 1
					if pi < 40 and Floor.is_walkable(p, level, x, y):
						var here := Floor.Pos.make(level, x, y)
						for n in Floor.neighbours(p, here):
							if not Floor.can_step(p, n, here):
								asymmetric += 1
		var longest := 0
		for s in p.sightlines:
			longest = maxi(longest, s.length)
			if not (s.x1 == s.x2 or s.y1 == s.y2) or s.length != absi(s.x2 - s.x1) + absi(s.y2 - s.y1) + 1:
				bad.append("sightline shape")
			var dx := signi(s.x2 - s.x1)
			var dy := signi(s.y2 - s.y1)
			for i in s.length:
				var x := s.x1 + dx * i
				var y := s.y1 + dy * i
				if Floor.cell_at(p, s.level, x, y) != &"corridor":
					bad.append("sightline cell not corridor")
				if i > 0 and not Floor.can_step(p, Floor.Pos.make(s.level, x - dx, y - dy), Floor.Pos.make(s.level, x, y)):
					bad.append("sightline blocked")
		if longest < 8:
			bad.append("no sightline of 8+ cells")
		var dist := Floor.distances_from(p, p.landing)
		if dist[Floor.pos_index(p, p.entity_start)] < 12:
			bad.append("entity start %d steps from the landing" % dist[Floor.pos_index(p, p.entity_start)])
		var on_long := false
		for s in p.sightlines:
			if s.length >= 8 and Floor.on_sightline(s, p.entity_start):
				on_long = true
		if not on_long:
			bad.append("entity start not on a long sightline")
		for b in bad.slice(0, 3):
			t.check(false, "%s d%d: %s" % [p.seed, p.depth, b])
	t.eq(asymmetric, 0, "asymmetric neighbours")
	t.check(checked > (400 if t.quick else 1000), "room-corridor edges checked: %d" % checked)
	t.note("%d floors: sightlines and entity starts checked; %d room-corridor edges, neighbours symmetric on 40 floors" % [plans.size(), checked])

func test_side_branches_are_dead_ends(t: T) -> void:
	var plans := Plans.property_plans(t.quick)
	var groups_total := 0
	for p in plans:
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
		for d in p.doors:
			var a := Floor.room_id_at(p, d.level, d.ax, d.ay)
			var b := Floor.room_id_at(p, d.level, d.bx, d.by)
			if side.has(a) and side.has(b):
				parent[find.call(a)] = find.call(b)
		var exits := {}
		var sizes := {}
		for id: int in side:
			var g: int = find.call(id)
			sizes[g] = int(sizes.get(g, 0)) + 1
			if not exits.has(g):
				exits[g] = 0
		for d in p.doors:
			var a := Floor.room_id_at(p, d.level, d.ax, d.ay)
			var b := Floor.room_id_at(p, d.level, d.bx, d.by)
			for pair: Array in [[a, b], [b, a]]:
				if side.has(pair[0]) and not side.has(pair[1]):
					var g: int = find.call(pair[0])
					exits[g] = int(exits[g]) + 1
		groups_total += exits.size()
		var suites := 0
		for g: int in sizes:
			if int(sizes[g]) >= 2:
				suites += 1
		t.check(exits.size() >= 2 and suites >= 2, "%s d%d: %d side branches, %d of two or more rooms" % [p.seed, p.depth, exits.size(), suites])
		for g: int in exits:
			t.check(int(exits[g]) == 1, "%s d%d: side group %d has %d doors out" % [p.seed, p.depth, g, exits[g]])
	t.note("%d floors, %d side branches, each with exactly one door out" % [plans.size(), groups_total])
