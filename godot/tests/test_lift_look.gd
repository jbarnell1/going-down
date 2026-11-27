extends RefCounted
## LA1: the lift car as a worn service lift, looks only. Everything a player reads or uses in the car stays where
## it was and as it was; the new pieces (named Look_*) sit inside the car's walls and off every readable thing.

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Clinic = preload("res://sim/clinic.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const WardDress = preload("res://client/ward/dress.gd")

## The meshes of the car before LA1 (every one of them, rounded to the millimetre), for the game's 4 m car and
## the Ward's narrow car: recorded from the car as it was, so nothing the player already saw has moved.
const BEFORE_GAME := "36:1fa2743373920e6d8c22e10bb2601b90"
const BEFORE_WARD := "36:d970a2ba47abeee529c4c97ec0315d24"

static func _game_car() -> Lift:
	var lift := Lift.new()
	lift.build(PlanDump.car_plain(Run.car_geometry(Clinic.generate_clinic("la1-car", 1))))
	return lift

static func _ward_car() -> Lift:
	var lift := Lift.new()
	lift.build(WardDress.lift_car(Vector3.ZERO))
	return lift

## Every mesh under the car in the car's frame: [node, box].
static func meshes(lift: Lift) -> Array:
	var out: Array = []
	_walk(lift, Transform3D.IDENTITY, out)
	return out

static func _walk(n: Node, xf: Transform3D, out: Array) -> void:
	for c in n.get_children():
		if not c is Node3D:
			continue
		var cx := xf * (c as Node3D).transform
		if c is MeshInstance3D and (c as MeshInstance3D).mesh != null:
			out.append([c, cx * (c as MeshInstance3D).mesh.get_aabb()])
		_walk(c, cx, out)

static func _is_look(n: Node) -> bool:
	var up: Node = n
	while up != null and not up is Lift:
		if String(up.name).begins_with("Look_"):
			return true
		up = up.get_parent()
	return false

## The old car's meshes as one line: each box to the millimetre, sorted.
static func fingerprint(lift: Lift) -> String:
	var rows := PackedStringArray()
	for m: Array in meshes(lift):
		if _is_look(m[0]):
			continue
		# HU2: the Tenant's STAIRS lamp row (client/stairs_lamps.gd) is new since the record too, on the landing wall over
		# the doors (tests/test_settings_tabs.gd places it); every mesh the old car had is still counted here.
		if (m[0] as Node).get_parent() != null and String((m[0] as Node).get_parent().name) == "StairsLamps":
			continue
		var b: AABB = m[1]
		rows.append("%d,%d,%d/%d,%d,%d" % [roundi(b.position.x * 1000), roundi(b.position.y * 1000), roundi(b.position.z * 1000),
			roundi(b.size.x * 1000), roundi(b.size.y * 1000), roundi(b.size.z * 1000)])
	rows.sort()
	return "%d:%s" % [rows.size(), ";".join(rows).md5_text()]

func test_the_old_car_is_untouched(t: T) -> void:
	for c: Array in [["the game's car", _game_car(), BEFORE_GAME], ["the Ward's car", _ward_car(), BEFORE_WARD]]:
		var lift: Lift = c[1]
		t.note("%s: %s" % [c[0], fingerprint(lift)])
		t.eq(fingerprint(lift), c[2], "%s: every mesh it had is where it was" % c[0])
		lift.free()

## The new pieces are there: steel lining, steel ceiling, checker plate under the paint, a handrail on each side wall,
## the ceiling light framed and louvred, and (in the game's car) the button panel and the inspection card.
func test_the_car_is_a_service_lift(t: T) -> void:
	for c: Array in [["the game's car", _game_car(), true], ["the Ward's car", _ward_car(), false]]:
		var lift: Lift = c[1]
		var what: String = c[0]
		var names := ["Look_Lining", "Look_Ceiling", "Look_FloorPlate", "Look_RailLeft", "Look_RailRight", "Look_Parts"]
		if c[2]:
			names.append("Look_Card")
		for n: String in names:
			var mi := lift.get_node_or_null(n) as MeshInstance3D
			t.check(mi != null and mi.mesh != null, "%s has %s" % [what, n])
		var lining := lift.get_node("Look_Lining") as MeshInstance3D
		var tex: Variant = (lining.material_override as ShaderMaterial).get_shader_parameter("tex")
		t.check(tex is Texture2D, "%s: the lining is a textured steel" % what)
		for n: String in ["Look_RailLeft", "Look_RailRight"]:
			var r := lift.get_node(n) as Node3D
			var side := -1.0 if n.ends_with("Left") else 1.0
			t.check(absf(r.position.y - Lift.RAIL_Y) < 1e-6 and signf(r.position.x) == side and absf(absf(r.position.x) - (lift.half - Lift.RAIL_OFF)) < 1e-6,
				"%s: %s along its side wall at %.2f m" % [what, n, Lift.RAIL_Y])
		var plate := lift.get_node("Look_FloorPlate") as MeshInstance3D
		var pb := plate.transform * plate.mesh.get_aabb()
		t.check(pb.size.x >= lift.half * 2.0 - 0.01 and pb.size.z >= lift.depth - Lift.FRONT - 0.04 and pb.position.y < 0.006,
			"%s: the checker plate covers the floor under the paint (%s)" % [what, pb])
		# The light fitting: frame bars round the old diffuser panel (1.4 m square) and louvres under it.
		var frame_reach := 0.0
		var louvres := 0
		var parts := lift.get_node("Look_Parts") as MeshInstance3D
		var verts: PackedVector3Array = parts.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		for v in verts:
			if v.y > Lift.CAR_H - 0.07 and absf(v.z + lift.depth * 0.5) < 0.85 and absf(v.x) < 0.85:
				frame_reach = maxf(frame_reach, absf(v.x))
				if v.y < Lift.CAR_H - 0.055:
					louvres += 1
		var want := minf(0.7, lift.half - 0.1) - 0.005
		t.check(frame_reach >= want and louvres >= 8, "%s: the ceiling light has a frame (to %.2f m from its middle, want %.2f) and louvres (%d corners under it)" % [what, frame_reach, want, louvres])
		lift.free()

## Every new piece is inside the car: within its walls, floor and ceiling, behind the front wall's inside face.
func test_the_new_pieces_stay_inside_the_car(t: T) -> void:
	for c: Array in [["the game's car", _game_car()], ["the Ward's car", _ward_car()]]:
		var lift: Lift = c[1]
		var inside := AABB(Vector3(-lift.half - 1e-4, -1e-4, -lift.depth - 1e-4), Vector3(lift.half * 2.0 + 2e-4, Lift.CAR_H + 2e-4, lift.depth - Lift.FRONT - 0.02 + 2e-4))
		var n := 0
		for m: Array in meshes(lift):
			if not _is_look(m[0]):
				continue
			n += 1
			t.check(inside.encloses(m[1]), "%s: %s (%s) stays in the car %s" % [c[0], (m[0] as Node).name, m[1], inside])
		t.check(n >= 6, "%s: %d new pieces" % [c[0], n])
		# And the car as tests/prop_lift.gd measures it (everything drawn inside it) is the old pieces' box.
		var old := AABB()
		var first := true
		for m: Array in meshes(lift):
			var b: AABB = m[1]
			if _is_look(m[0]) or b.get_center().z >= -Lift.FRONT or (m[0] as Node).get_parent() != lift:
				continue
			old = b if first else old.merge(b)
			first = false
		var box: AABB = lift.drawn_car()["box"]
		t.check(box.is_equal_approx(old), "%s: the drawn car's box %s is the old pieces' %s" % [c[0], box, old])
		lift.free()

## The space in front of everything a player reads or uses in the car, as boxes in the car's frame: [name, box].
static func readables(lift: Lift) -> Array:
	var out: Array = []
	var reach := 0.6
	for n: String in ["TenantNotice", "RateSheet1", "RateSheet2"]:
		var mi := lift.get_node(n) as MeshInstance3D
		var p := mi.position
		var s := Lift.NOTICE_SIZE
		# From just off the paper into the car, `reach` deep.
		var near := absf(p.x) - 0.001
		var x0 := -near if p.x < 0.0 else near - reach
		out.append([n, AABB(Vector3(x0, p.y - s.y * 0.5, p.z - s.x * 0.5), Vector3(reach, s.y, s.x))])
	for n: String in ["Monitor", "DayMonitor", "LossOddsMonitor"]:
		var mi := lift.get_node(n) as MeshInstance3D
		var s: Vector2 = (mi.mesh as QuadMesh).size
		var x0 := maxf(-s.x * 0.5, -lift.half + 0.01)
		var x1 := minf(s.x * 0.5, lift.half - 0.01)
		out.append([n, AABB(Vector3(x0, mi.position.y - s.y * 0.5, mi.position.z + 0.001), Vector3(x1 - x0, s.y, reach))])
	# The hold button's plate (0.14 by 0.2, its face 0.045 m inside the front wall line) and the indicator inside.
	var hb := Lift.HOLD_BUTTON
	out.append(["hold button", AABB(Vector3(hb.x - 0.07, hb.y - 0.1, -Lift.FRONT - 0.045 - reach), Vector3(0.14, 0.2, reach - 0.001))])
	out.append(["indicator", AABB(Vector3(-0.21, Lift.DOOR_H + 0.12 - 0.09, -Lift.FRONT - 0.03 - reach), Vector3(0.42, 0.18, reach - 0.001))])
	for n: String in ["FloorBank", "FloorDown"]:
		var fm := lift.get_node(n) as MeshInstance3D
		var b: AABB = fm.transform * fm.mesh.get_aabb()
		# The paint runs on under the front wall: what is read is the part inside the car.
		var z1 := minf(b.end.z, -Lift.FRONT - 0.03)
		out.append([n, AABB(b.position + Vector3(0.01, 0.001, 0.01), Vector3(b.size.x - 0.02, 0.5, z1 - b.position.z - 0.01))])
	return out

## Points spread over a triangle (its corners, edges and inside).
static func _samples(a: Vector3, b: Vector3, c: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var k := 6
	for i in k + 1:
		for j in k + 1 - i:
			out.append(a + (b - a) * (float(i) / k) + (c - a) * (float(j) / k))
	return out

## No new piece enters the space in front of a notice, a screen, the hold button, the indicator or the floor paint.
func test_nothing_new_covers_what_a_player_reads(t: T) -> void:
	for c: Array in [["the game's car", _game_car()], ["the Ward's car", _ward_car()]]:
		var lift: Lift = c[1]
		var spaces := readables(lift)
		var hits := PackedStringArray()
		for m: Array in meshes(lift):
			var mi: MeshInstance3D = m[0]
			if not _is_look(mi):
				continue
			var xf := Transform3D.IDENTITY
			var up: Node = mi
			while up != lift:
				xf = (up as Node3D).transform * xf
				up = up.get_parent()
			for s in mi.mesh.get_surface_count():
				var arr := mi.mesh.surface_get_arrays(s)
				var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
				var idx: Variant = arr[Mesh.ARRAY_INDEX]
				var ids := PackedInt32Array()
				if idx is PackedInt32Array and (idx as PackedInt32Array).size() > 0:
					ids = idx
				else:
					for i in v.size():
						ids.append(i)
				for k in range(0, ids.size() - 2, 3):
					for p in _samples(xf * v[ids[k]], xf * v[ids[k + 1]], xf * v[ids[k + 2]]):
						for sp: Array in spaces:
							if (sp[1] as AABB).has_point(p):
								hits.append("%s in front of the %s at %s" % [mi.name, sp[0], p])
		t.check(hits.is_empty(), "%s: %d points of new pieces in front of what a player reads, e.g. %s" % [c[0], hits.size(), "; ".join(hits.slice(0, 3))])
		# The steel lining is behind the notices, never in front.
		for n: String in ["TenantNotice", "RateSheet1", "RateSheet2"]:
			var p := (lift.get_node(n) as Node3D).position
			t.check(absf(p.x) < lift.half - Lift.LINE_OFF, "%s: the lining stands behind the %s" % [c[0], n])
		lift.free()

## The floor paint's words, hazard edge and dividing line are exactly as before; only the paint's own field wears.
func test_the_floor_paint_reads_as_before(t: T) -> void:
	var lift := _game_car()
	for c: Array in [["BANK", Color("#e8a21c"), Color("#2a1a05"), false, false], ["LOCKED", Color("#6d6f6c"), Color("#151515"), false, true],
			["DOWN", Color("#b8231c"), Color("#f6efe6"), true, false]]:
		var plain: Image = (lift.call("_paint", c[0], c[1], c[2], c[3], c[4], false) as ImageTexture).get_image()
		var worn: Image = (lift.call("_paint", c[0], c[1], c[2], c[3], c[4], true) as ImageTexture).get_image()
		var fill: Color = c[1]
		var stripe := fill.darkened(0.35)
		var changed := 0
		var bad := 0
		for y in plain.get_height():
			for x in plain.get_width():
				var a := plain.get_pixel(x, y).to_rgba32()
				if a == worn.get_pixel(x, y).to_rgba32():
					continue
				changed += 1
				var ac := plain.get_pixel(x, y)
				if not (_close(ac, fill) or _close(ac, stripe)):
					if bad == 0:
						t.note("%s: first changed pixel %d,%d was %s (fill %s, stripe %s)" % [c[0], x, y, ac, fill, stripe])
					bad += 1
		t.check(changed > 100, "%s: the paint is worn (%d pixels)" % [c[0], changed])
		t.eq(bad, 0, "%s: pixels of the word, the hazard edge or the line that changed" % c[0])
	lift.free()

static func _close(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 1.5 / 255.0 and absf(a.g - b.g) < 1.5 / 255.0 and absf(a.b - b.b) < 1.5 / 255.0
