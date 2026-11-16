# Line of sight and "could they see it" against src/sim/sight.ts: 6000 seeded queries on ten floors
# (random pairs, through doors, up and down stairs, near pairs), each asked seven ways: the default
# figure, the Orderly's three outlines, no margin, the bare line of sight to the chest, and the
# view cone. Mirrors sightCase in godot/tools/dump_reference.ts.
extends RefCounted

const T = preload("res://tests/t.gd")
const Snap = preload("res://tests/snap.gd")
const Plans = preload("res://tests/plans.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Sight = preload("res://sim/sight.gd")
const Rng = preload("res://sim/rng.gd")
const Bot = preload("res://sim/bot.gd")
const M = preload("res://sim/jsmath.gd")

static func _jitter(plan: Floor.FloorPlan, rng: Rng, p: Floor.Pos) -> Move.Body:
	var cs := plan.cell_size
	var x := (p.x + 0.2 + rng.next() * 0.6) * cs
	var z := (p.y + 0.2 + rng.next() * 0.6) * cs
	return Move.Body.make(x, z, p.level, Move.feet_height(plan, p.level, x, z))

## One query: returns [inputs, bits].
static func sight_case(plan: Floor.FloorPlan, rng: Rng, cells: PackedInt32Array) -> Array:
	var kind := rng.int_in(0, 4)
	var vp: Floor.Pos
	var fp: Floor.Pos
	if kind == 1 and not plan.doors.is_empty():
		var d: Floor.Door = rng.pick(plan.doors)
		var flip := rng.chance(0.5)
		var ax := d.bx if flip else d.ax
		var ay := d.by if flip else d.ay
		var bx := d.ax if flip else d.bx
		var by := d.ay if flip else d.by
		var back := rng.int_in(0, 2)
		var vx := ax - (bx - ax) * back
		var vy := ay - (by - ay) * back
		vp = Floor.Pos.make(d.level, vx, vy) if Floor.is_walkable(plan, d.level, vx, vy) else Floor.Pos.make(d.level, ax, ay)
		var fwd := rng.int_in(0, 2)
		var fx := bx + (bx - ax) * fwd
		var fy := by + (by - ay) * fwd
		fp = Floor.Pos.make(d.level, fx, fy) if Floor.is_walkable(plan, d.level, fx, fy) else Floor.Pos.make(d.level, bx, by)
	elif kind == 2:
		var s: Floor.Stair = rng.pick(plan.stairs)
		var top := Floor.stair_top(s)
		var bottom := Floor.stair_bottom(s)
		var on := Floor.stair_cells(s)
		var p1 := top if rng.chance(0.5) else bottom
		var p2: Floor.Pos
		if rng.chance(0.7):
			var c: Floor.Pos = rng.pick(on)
			p2 = Floor.Pos.make(0, c.x, c.y)
		else:
			p2 = top if rng.chance(0.5) else bottom
		if rng.chance(0.5):
			vp = p1
			fp = p2
		else:
			vp = p2
			fp = p1
	elif kind == 3:
		vp = Floor.pos_from_index(plan, rng.pick_int(cells))
		var tries := 0
		while true:
			fp = Floor.Pos.make(vp.level, vp.x + rng.int_in(-4, 4), vp.y + rng.int_in(-4, 4))
			tries += 1
			if Floor.is_walkable(plan, fp.level, fp.x, fp.y) or tries >= 20:
				break
		if not Floor.is_walkable(plan, fp.level, fp.x, fp.y):
			fp = vp
	else:
		vp = Floor.pos_from_index(plan, rng.pick_int(cells))
		fp = Floor.pos_from_index(plan, rng.pick_int(cells))
	var v := _jitter(plan, rng, vp)
	var f := _jitter(plan, rng, fp)
	var eye_y := v.y + Bot.BOT_EYE
	var dx := f.x - v.x
	var dz := f.z - v.z
	var yaw := M.atan2_js(-dx, -dz) + (rng.next() - 0.5) * 2.4
	var pitch := M.atan2_js(f.y + 1.7 - eye_y, M.hypot2(dx, dz)) + (rng.next() - 0.5) * 0.8
	var viewer := Sight.Viewer.new()
	viewer.body = v
	viewer.eye = Bot.BOT_EYE
	viewer.yaw = yaw
	viewer.pitch = pitch
	viewer.h_fov_deg = Bot.BOT_HFOV_DEG
	viewer.v_fov_deg = Bot.BOT_VFOV_DEG
	var chest := Sight.Point3.make(f.x, f.y + 1.7, f.z, f.level)
	var eye := Sight.Point3.make(v.x, eye_y, v.z, v.level)
	var bits: Array[bool] = [
		Sight.can_see(plan, viewer, f),
		Sight.can_see(plan, viewer, f, Sight.SIGHT_MARGIN_DEG, Sight.SIGHT_FAR, 2.6, 0.35),
		Sight.can_see(plan, viewer, f, Sight.SIGHT_MARGIN_DEG, Sight.SIGHT_FAR, 2.6, 1.1),
		Sight.can_see(plan, viewer, f, Sight.SIGHT_MARGIN_DEG, Sight.SIGHT_FAR, 2.9, 2.1),
		Sight.can_see(plan, viewer, f, 0.0),
		Sight.has_line_of_sight(plan, eye, chest),
		Sight.in_view_cone(viewer, chest.x, chest.y, chest.z),
	]
	var text := ""
	for b in bits:
		text += "1" if b else "0"
	return [[kind, v.x, v.z, v.y, v.level, f.x, f.z, f.y, f.level, yaw, pitch], text]

func test_six_thousand_queries(t: T) -> void:
	var ref: Array = Snap.load_ref("sight.json")
	var queries := 0
	var answers := 0
	var differ := 0
	var seen := 0
	for want: Dictionary in ref:
		var plan := Plans.plan(want["seed"], want["depth"])
		var cells := Floor.reachable_from(plan, plan.landing)
		var rng := Rng.make_rng("sight:%s:%d" % [want["seed"], want["depth"]])
		var bits := ""
		var inputs := PackedStringArray()
		for i in int(want["n"]):
			var c := sight_case(plan, rng, cells)
			bits += c[1]
			inputs.append(JSON.stringify(Snap.hexify(c[0], false), "", true))
		t.eq("".join(inputs).md5_text().substr(0, 8), want["inputs"], "%s d%d: the generated queries differ" % [want["seed"], want["depth"]])
		var wbits: String = want["bits"]
		queries += int(want["n"])
		for i in wbits.length():
			answers += 1
			if bits[i] == "1":
				seen += 1
			if i >= bits.length() or bits[i] != wbits[i]:
				differ += 1
				if differ <= 10:
					t.check(false, "%s d%d query %d answer %d: got %s want %s" % [want["seed"], want["depth"], i / 7, i % 7, bits[i] if i < bits.length() else "?", wbits[i]])
	t.check(differ == 0, "%d answers differ" % differ)
	t.note("%d queries, %d answers (%d yes), %d differ" % [queries, answers, seen, differ])
