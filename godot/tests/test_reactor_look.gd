# AR1 (21 Nov): the Reactor's look (client/station_view.gd, client/station_dress.gd). The owner: "Reactor
# specifically is pretty weak ... The growths in reactor look terrible ... It's currently very rough and blocky."
# Held here, headless:
#   - every wall, floor and ceiling of the station is drawn with a photo map from godot/assets/reactor (no flat
#     colour and no code-drawn picture), and the pipes, frames and kerbs carry maps too;
#   - over 20 seeds, no triangle of the dressing (pipes, growths, frames, kerbs, trays, beams, marks) enters the
#     space a body can stand in below head height, a doorway, the lift's opening or the wired glass; worked out
#     from the plan alone, not from the dressing's own notes;
#   - every growth anchor has its cluster, rooted on a drawn pipe run (or the crawl's tray);
#   - the same seed draws the same dressing, another seed a different one;
#   - the rotor stays inside the old rotor's box;
#   - the floor stays under its node and triangle budget (the numbers are noted).
extends RefCounted

const T = preload("res://tests/t.gd")
const Station = preload("res://sim/station.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const Run = preload("res://sim/run.gd")
const View = preload("res://client/station_view.gd")
const Dress = preload("res://client/station_dress.gd")
const Floor = preload("res://sim/floor.gd")

## Bodies keep 0.3 m off a wall line (client/level.gd WALL_T note); the space a body can stand in starts 0.28 m off.
const BODY_OFF := 0.28
const HEAD := 2.05
const SEEDS := 20
## The floor's budget (before AR1: 253 to 282 nodes, 58,292 to 60,816 triangles on the ar1-budget seeds).
const NODE_BUDGET := 330
const TRI_BUDGET := 230000

static func _level(plan: RefCounted) -> Level:
	var level := Level.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(level)
	var fp: Floor.FloorPlan = plan
	level.build(PlanDump.dump(fp, Run.car_geometry(fp)), fp.seed, fp)
	return level

static func _dress(level: Level) -> Node3D:
	var view: Node3D = level.get_meta(&"station")
	return view.get(&"dresser")

# --- 1. surfaces -----------------------------------------------------------------------------------------

func test_every_station_surface_has_a_photo_map(t: T) -> void:
	var level := _level(Station.generate_station("ar1-maps", 7))
	var n := 0
	for c in level.get_children():
		if not c is MeshInstance3D:
			continue
		var what := String(c.name).get_slice("_", 3)
		if not what in ["swallc", "swallg", "sfloor", "sceil", "srail"]:
			continue
		n += 1
		var m: Material = (c as MeshInstance3D).material_override
		var tex: Variant = (m as ShaderMaterial).get_shader_parameter("albedo_tex") if m is ShaderMaterial else null
		var path := (tex as Texture2D).resource_path if tex is Texture2D else ""
		t.check(path.begins_with("res://assets/reactor/"), "%s is drawn with a map from assets/reactor (%s)" % [c.name, path])
		if what == "swallg":
			var paint: Variant = (m as ShaderMaterial).get_shader_parameter("paint_tex")
			t.check(paint is Texture2D and (paint as Texture2D).resource_path.ends_with("wall_paint.webp"), "%s: the dado is the worn paint map" % c.name)
	t.check(n >= 8, "the walls, floors and ceilings were found (%d meshes)" % n)
	var d := _dress(level)
	var seen := {}
	for c in d.get_children():
		if c is MeshInstance3D and String(c.name).begins_with("Dress_"):
			var mat := String(c.name).get_slice("_", 1)
			if mat in ["paint", "steel", "concrete", "line"]:
				var m: ShaderMaterial = (c as MeshInstance3D).material_override
				seen[mat] = m.get_shader_parameter("tex") is Texture2D
	for mat: String in ["paint", "steel", "concrete", "line"]:
		t.check(bool(seen.get(mat, false)), "the dressing's %s is drawn with a map" % mat)
	level.free()

# --- 2. clear of bodies, doorways, the lift and the glass ---------------------------------------------------

## The boxes nothing may enter, from the plan: each walkable cell's standing space below head height; each
## doorway and the lift's opening (their width and height, either side of the wall); each wired-glass pane.
static func _keep_out(level: Level, fp: Floor.FloorPlan) -> Array[AABB]:
	var out: Array[AABB] = []
	var S := Level.S
	for y in level.H:
		for x in level.W:
			if level.walkable(0, x, y):
				out.append(AABB(Vector3(x * S + BODY_OFF, 0.02, y * S + BODY_OFF), Vector3(S - 2 * BODY_OFF, HEAD - 0.02, S - 2 * BODY_OFF)))
	var lift := level._lift_edge()
	var vert: Array = level.edges[0].vertical
	var hor: Array = level.edges[0].horizontal
	for y in level.H:
		for x in level.W + 1:
			var k: String = vert[y * (level.W + 1) + x]
			var is_lift := lift == Vector4i(0, x, y, 1)
			if k == "door" or is_lift:
				var half := level.lift_half if is_lift else Level.DOOR_W * 0.5
				var top := Level.LIFT_H if is_lift else Level.DOOR_H
				out.append(AABB(Vector3(x * S - 0.35, 0.02, (y + 0.5) * S - half), Vector3(0.7, top - 0.02, half * 2.0)))
	for y in level.H + 1:
		for x in level.W:
			var k: String = hor[y * level.W + x]
			var is_lift := lift == Vector4i(1, x, y, 1)
			if k == "door" or is_lift:
				var half := level.lift_half if is_lift else Level.DOOR_W * 0.5
				var top := Level.LIFT_H if is_lift else Level.DOOR_H
				out.append(AABB(Vector3((x + 0.5) * S - half, 0.02, y * S - 0.35), Vector3(half * 2.0, top - 0.02, 0.7)))
	for e: Array in fp.station["glass"]:
		var ax: int = e[0]
		var ay: int = e[1]
		var bx: int = e[2]
		var by: int = e[3]
		if ax != bx:
			var xl := maxf(ax, bx) * S
			out.append(AABB(Vector3(xl - 0.2, 1.02, ay * S + 0.02), Vector3(0.4, 1.8, S - 0.04)))
		else:
			var zl := maxf(ay, by) * S
			out.append(AABB(Vector3(ax * S + 0.02, 1.02, zl - 0.2), Vector3(S - 0.04, 1.8, 0.4)))
	return out

## Whether triangle (a, b, c) overlaps box (separating axis test, Akenine-Moller).
static func tri_box(a: Vector3, b: Vector3, c: Vector3, box: AABB) -> bool:
	var ctr := box.get_center()
	var h := box.size * 0.5
	var v0 := a - ctr
	var v1 := b - ctr
	var v2 := c - ctr
	for i in 3:
		if minf(v0[i], minf(v1[i], v2[i])) > h[i] or maxf(v0[i], maxf(v1[i], v2[i])) < -h[i]:
			return false
	var e: Array[Vector3] = [v1 - v0, v2 - v1, v0 - v2]
	var axes: Array[Vector3] = [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
	for ed in e:
		for ax in axes:
			var l := ax.cross(ed)
			if l.length_squared() < 1e-12:
				continue
			var p0 := v0.dot(l)
			var p1 := v1.dot(l)
			var p2 := v2.dot(l)
			var r := h.x * absf(l.x) + h.y * absf(l.y) + h.z * absf(l.z)
			if minf(p0, minf(p1, p2)) > r or maxf(p0, maxf(p1, p2)) < -r:
				return false
	var n := (v1 - v0).cross(v2 - v0)
	var rn := h.x * absf(n.x) + h.y * absf(n.y) + h.z * absf(n.z)
	return absf(n.dot(v0)) <= rn

## The triangles of every drawn mesh of the dressing except the rotor (which keeps to its own old box), in world space.
static func dress_tris(d: Node3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	var stack: Array[Node] = [d]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.name == &"Rotor":
			continue
		for c in n.get_children():
			stack.append(c)
		if not n is MeshInstance3D:
			continue
		var mi := n as MeshInstance3D
		var xf := mi.global_transform
		for s in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(s)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx: Variant = arr[Mesh.ARRAY_INDEX]
			if idx is PackedInt32Array and (idx as PackedInt32Array).size() > 0:
				for k in (idx as PackedInt32Array):
					out.append(xf * v[k])
			else:
				for p in v:
					out.append(xf * p)
	return out

## How many dressing triangles enter a keep-out box, with the first few named.
static func intrusions(level: Level, fp: Floor.FloorPlan, d: Node3D) -> Array:
	var boxes := _keep_out(level, fp)
	var grid := {}
	for i in boxes.size():
		var b := boxes[i]
		for cz in range(floori(b.position.z / 2.0), floori(b.end.z / 2.0) + 1):
			for cx in range(floori(b.position.x / 2.0), floori(b.end.x / 2.0) + 1):
				var key := Vector2i(cx, cz)
				if not grid.has(key):
					grid[key] = []
				grid[key].append(i)
	var tris := dress_tris(d)
	var bad := 0
	var first: Array = []
	for k in range(0, tris.size(), 3):
		var a := tris[k]
		var b := tris[k + 1]
		var c := tris[k + 2]
		if minf(a.y, minf(b.y, c.y)) > 2.86:
			continue
		var lo := Vector2(minf(a.x, minf(b.x, c.x)), minf(a.z, minf(b.z, c.z)))
		var hi := Vector2(maxf(a.x, maxf(b.x, c.x)), maxf(a.z, maxf(b.z, c.z)))
		var hit := false
		for cz in range(floori(lo.y / 2.0), floori(hi.y / 2.0) + 1):
			for cx in range(floori(lo.x / 2.0), floori(hi.x / 2.0) + 1):
				for i: int in grid.get(Vector2i(cx, cz), []):
					if not hit and tri_box(a, b, c, boxes[i]):
						hit = true
						if first.size() < 3:
							first.append("%s in %s" % [(a + b + c) / 3.0, boxes[i]])
		bad += int(hit)
	return [bad, tris.size() / 3, first]

func test_the_dressing_keeps_out_of_bodies_doorways_and_the_glass(t: T) -> void:
	# The check itself: a triangle in the middle of a cell is caught, one against a wall is not.
	var probe := AABB(Vector3(BODY_OFF, 0.02, BODY_OFF), Vector3(2.0 - 2 * BODY_OFF, HEAD, 2.0 - 2 * BODY_OFF))
	t.check(tri_box(Vector3(1, 1, 1), Vector3(1.1, 1, 1), Vector3(1, 1.1, 1), probe), "the check catches a triangle in the open")
	t.check(not tri_box(Vector3(0.05, 1, 0.5), Vector3(0.2, 1, 1.5), Vector3(0.1, 1.8, 1.0), probe), "and passes one against the wall")
	t.check(tri_box(Vector3(-0.5, 1, 1), Vector3(2.5, 1, 1), Vector3(-0.5, 1.05, 1), probe), "and catches a long thin one passing through")
	for i in SEEDS:
		var fp := Station.generate_station("ar1-clear-%d" % i, 7)
		var level := _level(fp)
		var res := intrusions(level, fp, _dress(level))
		t.check(int(res[0]) == 0, "seed %d: none of the %d dressing triangles enters a body's space, a doorway, the lift or the glass (%d do: %s)" % [i, res[1], res[0], res[2]])
		t.check(int(res[1]) > 5000, "seed %d: the dressing was drawn (%d triangles)" % [i, res[1]])
		level.free()

# --- 3. growths on pipes ----------------------------------------------------------------------------------

func test_every_growth_anchor_has_a_cluster_rooted_on_a_pipe(t: T) -> void:
	for i in 8:
		var fp := Station.generate_station("ar1-roots-%d" % i, 7)
		var level := _level(fp)
		var d := _dress(level)
		var clusters: Array = d.get(&"clusters")
		var anchored := clusters.filter(func(c: Dictionary) -> bool: return c["anchor"] != Vector3.INF)
		t.eq(anchored.size(), (fp.station["growths"] as Array).size(), "seed %d: one cluster per growth anchor" % i)
		var north := 0
		var south := 0
		var hall: Rect2 = fp.station["hall"]
		for c: Dictionary in clusters:
			var at: Vector3 = c["at"]
			var on := false
			for seg: Dictionary in d.get(&"segments"):
				var side: Dictionary = d.get(&"sides")[seg["side"]]
				var p := Dress.at_side(side, clampf((at - (side["origin"] as Vector3)).dot(side["dir"]), seg["s0"], seg["s1"]), seg["h"], seg["d"])
				on = on or p.distance_to(at) < 0.01
			t.check(on, "seed %d: the %s cluster at %s sits on a laid run" % [i, c["kind"], at])
			# A drawn pipe there: some pipe or tray triangle within reach of the root.
			t.check(_pipe_near(d, at, float(c.get("scale", 1.0))), "seed %d: a drawn pipe or tray passes through the %s root at %s" % [i, c["kind"], at])
			if hall.grow(0.5).has_point(Vector2(at.x, at.z)):
				north += int(at.z < hall.get_center().y)
				south += int(at.z >= hall.get_center().y)
		t.check(north > south, "seed %d: the hall's half by the rotor has more growths than the half by the lift (%d to %d)" % [i, north, south])
		level.free()

## Whether a drawn pipe, lagging or tray (the dressing's, or the crawl's own trays) passes within 0.2 m of `at`.
static func _pipe_near(d: Node3D, at: Vector3, _scale: float) -> bool:
	var meshes: Array[MeshInstance3D] = []
	for c in d.get_children():
		if c is MeshInstance3D and String(c.name).begins_with("Dress_") and String(c.name).get_slice("_", 1) in ["paint", "steel", "concrete"]:
			meshes.append(c)
	for c in d.get_parent().get_parent().get_children():
		if c is MeshInstance3D and String(c.name).ends_with("_sprops"):
			meshes.append(c)
	for mi in meshes:
		var arr := mi.mesh.surface_get_arrays(0)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var idx: Variant = arr[Mesh.ARRAY_INDEX]
		var list: PackedInt32Array = idx if idx is PackedInt32Array else PackedInt32Array(range(v.size()))
		for k in range(0, list.size(), 3):
			var a := v[list[k]]
			var b := v[list[k + 1]]
			var c := v[list[k + 2]]
			var lo := a.min(b).min(c) - Vector3.ONE * 0.2
			var hi := a.max(b).max(c) + Vector3.ONE * 0.2
			if at.x < lo.x or at.y < lo.y or at.z < lo.z or at.x > hi.x or at.y > hi.y or at.z > hi.z:
				continue
			if _closest_on_tri(at, a, b, c).distance_to(at) < 0.2:
				return true
	return false

## The closest point on triangle abc to p (Ericson, Real-Time Collision Detection 5.1.5).
static func _closest_on_tri(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var ab := b - a
	var ac := c - a
	var ap := p - a
	var d1 := ab.dot(ap)
	var d2 := ac.dot(ap)
	if d1 <= 0.0 and d2 <= 0.0:
		return a
	var bp := p - b
	var d3 := ab.dot(bp)
	var d4 := ac.dot(bp)
	if d3 >= 0.0 and d4 <= d3:
		return b
	var vc := d1 * d4 - d3 * d2
	if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
		return a + ab * (d1 / (d1 - d3))
	var cp := p - c
	var d5 := ab.dot(cp)
	var d6 := ac.dot(cp)
	if d6 >= 0.0 and d5 <= d6:
		return c
	var vb := d5 * d2 - d1 * d6
	if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
		return a + ac * (d2 / (d2 - d6))
	var va := d3 * d6 - d5 * d4
	if va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0:
		return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
	var denom := 1.0 / (va + vb + vc)
	return a + ab * (vb * denom) + ac * (vc * denom)
# --- 4. the same from the seed ----------------------------------------------------------------------------

static func _signature(d: Node3D) -> int:
	var tris := dress_tris(d)
	var h := hash(tris.size())
	for k in range(0, tris.size(), 7):
		h = hash([h, snappedf(tris[k].x, 0.0001), snappedf(tris[k].y, 0.0001), snappedf(tris[k].z, 0.0001)])
	return h

func test_the_same_seed_draws_the_same_dressing(t: T) -> void:
	var a := _level(Station.generate_station("ar1-same", 7))
	var b := _level(Station.generate_station("ar1-same", 7))
	var c := _level(Station.generate_station("ar1-other", 7))
	var sa := _signature(_dress(a))
	t.eq(_signature(_dress(b)), sa, "two builds of one seed draw the same dressing")
	t.check(_signature(_dress(c)) != sa, "another seed draws another")
	t.eq(str((_dress(a).get(&"clusters") as Array).map(func(x: Dictionary) -> Vector3: return x["at"])),
		str((_dress(b).get(&"clusters") as Array).map(func(x: Dictionary) -> Vector3: return x["at"])), "and the same growths in the same places")
	for l: Level in [a, b, c]:
		l.free()

# --- 4b. the growths in both power states -----------------------------------------------------------------

func test_the_growths_glow_with_the_mains_and_dim_but_stay_in_the_cut(t: T) -> void:
	var level := _level(Station.generate_station("ar1-glow", 7))
	var view: Node3D = level.get_meta(&"station")
	var mats: Array = _dress(level).get(&"growth_mats")
	t.check(mats.size() >= 2, "the growths' materials are known (%d)" % mats.size())
	var lit := {}
	for power: int in [0, 1, 2]:
		view.call(&"set_power", power)
		view.call(&"_apply")
		for m: ShaderMaterial in mats:
			var g := float(m.get_shader_parameter("self_glow"))
			var r := float(m.get_shader_parameter("rim_glow"))
			if power == 1:
				t.check(g > 0.0 and r > 0.0 and g < float(lit["g"]), "in the cut a growth dims (%.2f) but never goes black" % g)
			else:
				t.check(g >= 0.25 and r >= 0.4, "with the mains a growth glows enough to read (%.2f, rim %.2f)" % [g, r])
				lit = {"g": g}
	level.free()

# --- 5. the rotor, the budget --------------------------------------------------------------------------------

func test_the_rotor_keeps_to_the_old_rotors_box(t: T) -> void:
	for i in 6:
		var fp := Station.generate_station("ar1-rotor-%d" % i, 7)
		var level := _level(fp)
		var rotor: Node3D = _dress(level).get(&"rotor_node")
		var at := View.v3(fp.station["rotor"])
		# The old rotor: a 2.7 m by 3.8 m bedplate and casing about its anchor, 2.95 m high (the hall runs north-south).
		var old := AABB(Vector3(at.x - 1.36, -0.01, at.z - 1.91), Vector3(2.72, 2.97, 3.82))
		var box: AABB = rotor.get_meta(&"bounds")
		t.check(old.encloses(box), "seed %d: the rotor %s stays in the old one's box %s" % [i, box, old])
		t.check(box.size.y > 1.5, "seed %d: and it is a machine, not a disc (%.2f m high)" % [i, box.size.y])
		level.free()

static func _count(n: Node, acc: Dictionary) -> void:
	acc["nodes"] += 1
	if n is MeshInstance3D and (n as MeshInstance3D).visible and (n as MeshInstance3D).mesh != null:
		var m: Mesh = (n as MeshInstance3D).mesh
		for s in m.get_surface_count():
			var arr := m.surface_get_arrays(s)
			var idx: Variant = arr[Mesh.ARRAY_INDEX]
			acc["tris"] += (idx as PackedInt32Array).size() / 3 if idx is PackedInt32Array and (idx as PackedInt32Array).size() > 0 else (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	for c in n.get_children():
		_count(c, acc)

func test_the_floor_stays_in_its_budget(t: T) -> void:
	for i in 3:
		var fp := Station.generate_station("ar1-budget-%d" % i, 7)
		var t0 := Time.get_ticks_msec()
		var level := _level(fp)
		var ms := Time.get_ticks_msec() - t0
		var acc := {"nodes": 0, "tris": 0}
		_count(level, acc)
		t.note("seed %d: %d nodes, %d triangles, built in %d ms" % [i, acc["nodes"], acc["tris"], ms])
		t.check(int(acc["nodes"]) <= NODE_BUDGET, "seed %d: %d nodes <= %d" % [i, acc["nodes"], NODE_BUDGET])
		t.check(int(acc["tris"]) <= TRI_BUDGET, "seed %d: %d triangles <= %d" % [i, acc["tris"], TRI_BUDGET])
		level.free()
