# Walls, collision and movement against src/sim/walls.ts, move.ts, follow.ts and run.ts moveInRun,
# on five floors: every edge on both levels, every collision segment, seeded random walks (the
# body after every step), stair jitter, following a path end to end, and walking through the car
# door while it opens and shuts. Mirrors dumpMove in godot/tools/dump_reference.ts.
extends RefCounted

const T = preload("res://tests/t.gd")
const Snap = preload("res://tests/snap.gd")
const Plans = preload("res://tests/plans.gd")
const Floor = preload("res://sim/floor.gd")
const Walls = preload("res://sim/walls.gd")
const Move = preload("res://sim/move.gd")
const Follow = preload("res://sim/follow.gd")
const Run = preload("res://sim/run.gd")
const Rng = preload("res://sim/rng.gd")
const Bot = preload("res://sim/bot.gd")
const M = preload("res://sim/jsmath.gd")

const EDGE_CHAR := {&"none": "n", &"open": "o", &"door": "d", &"wall": "w", &"rail": "r", &"stairTop": "t"}

static func _row(i: int, values: Array) -> Variant:
	return values if i % 25 == 0 else Snap.digest(values, false)

static func walks(plan: Floor.FloorPlan, seed: String) -> Array:
	var rng := Rng.make_rng("walk:%s" % seed)
	var starts: Array[Floor.Pos] = [plan.landing, plan.entity_start]
	for s in plan.stairs:
		starts.append(Floor.stair_bottom(s))
	var out: Array = []
	for start in starts:
		var b := Move.body_at_cell(plan, start)
		var heading := rng.next() * PI * 2.0
		var steps: Array = []
		for i in 250:
			if rng.chance(0.05):
				heading = rng.next() * PI * 2.0
			heading += (rng.next() - 0.5) * 0.3
			var length := 0.6 if rng.chance(0.1) else 0.05
			b = Move.move_with_collision(plan, b, M.cos_js(heading) * length, M.sin_js(heading) * length, 0.3)
			steps.append(_row(i, [b.x, b.z, b.y, b.level, Move.wall_clearance(plan, b.level, b.x, b.z)]))
		out.append(steps)
	for stair in plan.stairs:
		var vx := Floor.dir_dx(stair.dir)
		var vy := Floor.dir_dy(stair.dir)
		var b := Move.body_at_cell(plan, Floor.stair_bottom(stair))
		var dir := 1
		var steps: Array = []
		for i in 300:
			if rng.chance(0.01):
				dir = -dir
			var c := Move.cell_of(plan, b)
			var top := Floor.stair_top(stair)
			var bottom := Floor.stair_bottom(stair)
			if c.level == top.level and c.x == top.x and c.y == top.y and rng.chance(0.2):
				dir = -1
			if c.level == bottom.level and c.x == bottom.x and c.y == bottom.y and rng.chance(0.2):
				dir = 1
			var wob := (rng.next() - 0.5) * 0.15
			b = Move.move_with_collision(plan, b, vx * 0.06 * dir + vy * wob, vy * 0.06 * dir + vx * wob, 0.3)
			steps.append(_row(i, [b.x, b.z, b.y, b.level, Move.feet_height(plan, b.level, b.x, b.z)]))
		out.append(steps)
	return out

func test_five_floors(t: T) -> void:
	var ref: Array = Snap.load_ref("move.json")
	var total := Snap.Diff.new()
	for want: Dictionary in ref:
		var seed: String = want["seed"]
		var plan := Plans.plan(seed, 2)
		var got := {"seed": seed, "depth": 2}
		var edges: Array = []
		for level in 2:
			var v := PackedStringArray()
			for y in plan.height:
				for x in plan.width + 1:
					v.append(EDGE_CHAR[Walls.west_edge(plan, level, x, y)])
			var h := PackedStringArray()
			for y in plan.height + 1:
				for x in plan.width:
					h.append(EDGE_CHAR[Walls.north_edge(plan, level, x, y)])
			edges.append(["".join(v), "".join(h)])
		got["edges"] = edges
		var seg_text := PackedStringArray()
		for level in 2:
			for y in plan.height:
				for x in plan.width:
					if not Floor.is_walkable(plan, level, x, y):
						continue
					var segs := Walls.segments_near(plan, level, x, y)
					var arr: Array = []
					var i := 0
					while i < segs.size():
						arr.append([segs[i], segs[i + 1], segs[i + 2], segs[i + 3]])
						i += 4
					seg_text.append(JSON.stringify(Snap.hexify(arr, false), "", true))
		got["segments"] = "".join(seg_text).md5_text().substr(0, 8)
		got["walks"] = walks(plan, seed)
		var follows: Array = []
		for pair: Array in [[plan.landing, plan.entity_start], [plan.entity_start, plan.landing]]:
			var path := Floor.find_path(plan, pair[0], pair[1])
			var w := Follow.start_path_walk(path)
			var b := Move.body_at_cell(plan, pair[0])
			var digests := PackedStringArray()
			var steps := 0
			while not Follow.path_done(plan, w, b) and steps < 4000:
				b = Follow.step_path_walk(plan, w, b, 0.05, 0.3)
				digests.append(Snap.digest(Snap.body(b), false))
				steps += 1
			follows.append({"steps": steps, "digests": "".join(digests), "end": Snap.body(b), "next": w.next})
		got["follows"] = follows
		# moveInRun around the car door.
		var ids: Array[String] = ["a"]
		var st := Run.create_run("door:%s" % seed, ids)
		st.plan = plan
		st.car = Run.car_geometry(plan)
		var r2 := Rng.make_rng("door:%s" % seed)
		var body := Run.car_body(st.car, -1.2, 0.0)
		var door: Array = []
		for i in 400:
			var open := (i / 50) % 2 == 0
			var s2 := st.copy()
			s2.phase = &"boarding" if open else &"away"
			var toward := r2.chance(0.6)
			var ang := M.atan2_js(st.car.in_z, st.car.in_x) + (r2.next() - 0.5) * 1.6 if toward else r2.next() * PI * 2.0
			var length := r2.next() * 0.3
			body = Run.move_in_run(s2, body, M.cos_js(ang) * length, M.sin_js(ang) * length, Bot.BOT_RADIUS)
			door.append(_row(i, [body.x, body.z, body.y, body.level]))
		got["door"] = door
		var d := Snap.compare(got, want, seed)
		total.add(d)
		t.check(d.bad == 0 and d.inexact == 0, "%s: %s" % [seed, d.summary()])
	t.note("5 floors, edges + segments + %s" % total.summary())
