# AW1: the Hanging Ward's surfaces and sky (client/ward/skin.gd). The owner, 21 Nov: "the houses in the ward don't make
# sense ... It's currently very rough and blocky. Textures will help ... free resources for packs that are cc0 will
# help". A look change only: nothing any rule, sight line or the Rigger's climb reads may move.
#   1. the bodies (every solid box: walls, slabs, decks, walkways, rails, doors, glass, the lift's shell), the
#      Rigger's lines and the lift car are byte-identical to what they were before AW1, over today's Ward and 20 seeds;
#   2. every house wall, slab and partition is one material at one texture scale (one brick, one plaster);
#   3. no Ward surface is an untextured flat colour, apart from the listed exceptions;
#   4. nothing the skin adds stands in a walkway, on a gallery's walking strip, in a doorway, in a window or in the
#      lift's doorway or car;
#   5. the cavern's roof and the lift's shaft are drawn, the shaft from the car up to the roof;
#   6. the same seed dresses the same, a different seed differently;
#   7. the photographs it uses are in the project (tests/test_export_data.gd checks the export presets).
extends RefCounted

const T = preload("res://tests/t.gd")
const View = preload("res://client/ward/view.gd")
const Layout = preload("res://sim/ward/layout.gd")

## Today's Ward and 20 generated ones (WG1 at today's options), as test_ward_dress.gd's doorway check.
static func cases() -> Array:
	var out: Array = [[8143, []]]
	for k in 20:
		out.append([1000 + k * 7919, Layout.to_wire({"version": 2, "spread": Layout.SPREAD, "rise": Layout.RISE})])
	return out

static func _view(seed_value: int, layout: Array) -> View:
	var view := View.new(seed_value, Vector3.ZERO, layout)
	view.own_hud = false
	view.own_camera = false
	view.own_environment = false
	(Engine.get_main_loop() as SceneTree).root.add_child(view)
	return view

static func _f(x: float) -> String:
	return "%.4f" % x

static func _xf(xf: Transform3D) -> String:
	var out := ""
	for v: Vector3 in [xf.basis.x, xf.basis.y, xf.basis.z, xf.origin]:
		out += "%s,%s,%s;" % [_f(v.x), _f(v.y), _f(v.z)]
	return out

## The view's bodies, the Rigger's lines and the lift as text, sorted (tree order may change), hashed.
static func digest(view: View) -> String:
	var rows: Array[String] = []
	for node: Node in view.find_children("*", "StaticBody3D", true, false):
		var body := node as StaticBody3D
		var shape := body.get_node_or_null("CollisionShape3D") as CollisionShape3D
		var size := (shape.shape as BoxShape3D).size if shape != null and shape.shape is BoxShape3D else Vector3.ZERO
		rows.append("S%s|%s,%s,%s" % [_xf(body.global_transform), _f(size.x), _f(size.y), _f(size.z)])
	for house: Dictionary in view.houses:
		for line: Node3D in house.lines:
			for node: Node in line.find_children("*", "MeshInstance3D", true, false):
				var mesh := node as MeshInstance3D
				var box := mesh.mesh.get_aabb()
				rows.append("L%s|%s,%s,%s" % [_xf(mesh.global_transform), _f(box.size.x), _f(box.size.y), _f(box.size.z)])
	rows.append("C%s|%s" % [_xf(view.lift_car.global_transform), str(view.lift_spot)])
	rows.sort()
	return "\n".join(rows).sha256_text().substr(0, 16)

## Recorded on main at e24ea9c, before AW1 (never re-recorded: a change here is a change to what the rules see).
const DIGESTS := {8143: "bc33ac97ddc8b6f3", 1000: "48a43d8bf7c38547", 8919: "239c3c735f4d5f40", 16838: "357b38de07f1a7c0",
	24757: "06b58284a5dbfb39", 32676: "0d0eb55486b33e34", 40595: "8177bf2622271105", 48514: "28dfc3ff316a3f62",
	56433: "a32294d5daf7b877", 64352: "794bcdf658462187", 72271: "6cfcaa4820bdd4fc", 80190: "14d2624c6118fa5b",
	88109: "5367b2cf39753cba", 96028: "8d8ac54a3543be1d", 103947: "74589ddeb345baef", 111866: "1bc30c605e882b36",
	119785: "6d7d3a31212670d4", 127704: "4960712cdaa1502e", 135623: "59e90ef7a4a0a2dc", 143542: "ac21212eb59d72a4",
	151461: "883ac59f6e2e8976"}

func test_bodies_lines_and_lift_are_unchanged(t: T) -> void:
	for case: Array in cases():
		var view := _view(int(case[0]), case[1])
		var got := digest(view)
		t.eq(got, str(DIGESTS.get(int(case[0]), "")), "seed %d: the bodies, lines and lift are as before AW1" % case[0])
		view.free()

## Today's Ward and two generated ones, for the slower checks.
const FEW := [[8143, []], [11, [2, 110, 150]], [302, [2, 110, 150]]]

func test_every_house_wall_is_one_material_at_one_scale(t: T) -> void:
	for case: Array in FEW:
		var view := _view(int(case[0]), case[1])
		var house: ShaderMaterial = view.colors["house"]
		t.check(house.shader == WardSkin.HouseShader, "seed %d: the house material is ward_house.gdshader" % case[0])
		for pair: Array in [["brick_tile", WardSkin.BRICK_TILE], ["plaster_tile", WardSkin.PLASTER_TILE], ["floor_tile", WardSkin.FLOOR_TILE],
				["board_tile", WardSkin.BOARD_TILE], ["paper_tile", WardSkin.PAPER_TILE], ["wood_tile", WardSkin.WOOD_TILE]]:
			t.check(is_equal_approx(float(house.get_shader_parameter(pair[0])), float(pair[1])), "seed %d: %s is %.2f m" % [case[0], pair[0], pair[1]])
		t.check(is_equal_approx(float((view.colors["brick"] as ShaderMaterial).get_shader_parameter("tile")), WardSkin.BRICK_TILE),
			"seed %d: loose brick (the chimney pots) is the walls' brick size" % case[0])
		var walls := 0
		var odd: Array[String] = []
		for row: Dictionary in view.houses:
			for node: Node in (row.root as Node3D).find_children("*", "StaticBody3D", true, false):
				if view.door_houses.has(node):
					continue
				var mesh := node.get_child(0) as MeshInstance3D
				if mesh.material_override == view.colors["glass"]:
					continue
				walls += 1
				if mesh.material_override != house or not mesh.mesh is ArrayMesh:
					odd.append("%s at %s" % [str((node.get_node("CollisionShape3D").shape as BoxShape3D).size.snappedf(0.01)), str((node as Node3D).position.snappedf(0.01))])
		t.check(walls > 8 * 10, "seed %d: the houses' walls, slabs and partitions were found (%d)" % [case[0], walls])
		t.check(odd.is_empty(), "seed %d: every wall, slab and partition is drawn in the one house material (%d not: %s)" % [case[0], odd.size(), ", ".join(odd.slice(0, 4))])
		view.free()

## What a drawn mesh shows: its override, or its first surface's material.
static func _material(mesh: MeshInstance3D) -> Material:
	if mesh.material_override != null:
		return mesh.material_override
	return mesh.mesh.surface_get_material(0) if mesh.mesh.get_surface_count() > 0 else null

func test_no_ward_surface_is_an_untextured_flat_colour(t: T) -> void:
	for case: Array in FEW:
		var view := _view(int(case[0]), case[1])
		var allowed: Array[Material] = []
		for key: String in WardSkin.FLAT_ON_PURPOSE:
			if view.colors.has(key):
				allowed.append(view.colors[key])
		var flat := {}
		var seen := 0
		for node: Node in view.find_children("*", "MeshInstance3D", true, false):
			var mesh := node as MeshInstance3D
			# The lift car is every floor's (client/lift.gd); the Rigger and his hand are his own models.
			if mesh.mesh == null or mesh.mesh.get_surface_count() == 0 or not mesh.is_visible_in_tree() or view.lift_car.is_ancestor_of(mesh) \
					or view.rigger.is_ancestor_of(mesh) or view.hand.is_ancestor_of(mesh):
				continue
			seen += 1
			var material := _material(mesh)
			if allowed.has(material) or (material is ShaderMaterial and (material as ShaderMaterial).shader == WardSkin.MistShader):
				continue
			if not WardSkin.textured(material):
				var key: Variant = view.colors.find_key(material)
				flat[str(key) if key != null else str(mesh.get_path())] = true
		t.check(seen > 500, "seed %d: the Ward's meshes were looked at (%d)" % [case[0], seen])
		t.check(flat.is_empty(), "seed %d: every surface has a photograph on it but light, glass, the arm and the mist (flat: %s)" % [case[0], ", ".join(flat.keys())])
		view.free()

const Dressing = preload("res://tests/test_ward_dress.gd")
const WardSkin = preload("res://client/ward/skin.gd")
const House = preload("res://sim/ward/house.gd")
const Footing = preload("res://sim/ward/footing.gd")
const Graph = preload("res://sim/ward/rigger_graph.gd")

## Every box the skin added: [what, world transform, local box].
static func skin_parts(view: View) -> Array:
	var out := []
	for node: Node in view.get_tree().get_nodes_in_group(WardSkin.GROUP):
		if not node is MeshInstance3D or not view.is_ancestor_of(node):
			continue
		var mesh := node as MeshInstance3D
		if mesh.has_meta(&"parts"):
			for part: Array in mesh.get_meta(&"parts"):
				out.append([str(mesh.get_parent().name) + "/" + str(mesh.name), mesh.global_transform * (part[0] as Transform3D), part[1]])
		else:
			out.append([str(mesh.name), mesh.global_transform, mesh.mesh.get_aabb()])
	for node: Node in view.get_tree().get_nodes_in_group(WardSkin.GROUP):
		# A thin rail drawn by view.gd _box (its mesh under the group's node).
		if node is Node3D and not node is MeshInstance3D and node.get_child_count() == 1 and node.get_child(0) is MeshInstance3D and view.is_ancestor_of(node):
			var mesh := node.get_child(0) as MeshInstance3D
			out.append(["rail", mesh.global_transform, mesh.mesh.get_aabb()])
	return out

## The places nothing may stand in: [name, frame, box in that frame].
static func keep_clear(view: View) -> Array:
	var out := []
	var layout: Dictionary = view.walk_model.layout
	# Walkways: the walking width between the rails, up to head height, short of the ends.
	for edge: Dictionary in layout.bridges:
		var path: Array = edge.path
		for i in range(1, path.size()):
			var from := Footing.path_point(path[i - 1])
			var to := Footing.path_point(path[i])
			var length := from.distance_to(to)
			var frame := Transform3D(Graph.span_axes(from, to), (from + to) * 0.5)
			out.append(["walkway", frame, AABB(Vector3(-0.6, 0.02, -length * 0.5 + 0.3), Vector3(1.2, 2.08, length - 0.6))])
	for i in view.houses.size():
		var site: Dictionary = layout.houses[i]
		var fixture: House = view.houses[i].fixture
		var root: Node3D = view.houses[i].root
		# The gallery's walking strip all round (a quarter metre off the walls, short of the rail), to head height.
		var y := float(site.z) + 0.15
		var inner := Vector2(float(site.w) * 0.5 + House.WALL_THICKNESS + 0.25, float(site.d) * 0.5 + House.WALL_THICKNESS + 0.25)
		var outer := Vector2(float(site.w) * 0.5 + Layout.GALLERY - 0.15, float(site.d) * 0.5 + Layout.GALLERY - 0.15)
		var c := Vector3(float(site.x), y, float(site.y))
		for s: float in [-1.0, 1.0]:
			out.append(["gallery", Transform3D(Basis.IDENTITY, c), AABB(Vector3(minf(s * inner.x, s * outer.x), 0.02, -outer.y), Vector3(outer.x - inner.x, 2.08, outer.y * 2.0))])
			out.append(["gallery", Transform3D(Basis.IDENTITY, c), AABB(Vector3(-outer.x, 0.02, minf(s * inner.y, s * outer.y)), Vector3(outer.x * 2.0, 2.08, outer.y - inner.y))])
		var frame := root.global_transform
		# The front door, half a metre either side of the wall.
		var door := fixture.door
		out.append(["doorway", frame, AABB(Vector3(door.position.x + 0.02, 0.02, -0.6), Vector3(door.size.x - 0.04, 2.15, 1.2))])
		# The ground floor's room doors and every upper storey's middle opening.
		for opening: Vector3 in fixture.room_doors:
			out.append(["room door", frame, AABB(Vector3(opening.x - 0.5, 0.02, opening.z - 0.5), Vector3(1.0, 2.13, 1.0))])
		for level in range(1, int(site.floors)):
			out.append(["room door", frame, AABB(Vector3(-0.55, level * House.HEIGHT + 0.02, fixture.floor_bounds.size.y * 0.5 - 0.5), Vector3(1.1, 2.13, 1.0))])
		# Every side window, its pane through the wall and a step either side.
		var half := fixture.floor_bounds.size.x * 0.5
		for level in int(site.floors):
			for s: float in [-1.0, 1.0]:
				if int(site.id) == 0 and level == 0 and s < 0.0:
					continue
				var x := s * (half + House.WALL_THICKNESS * 0.5)
				out.append(["window", frame, AABB(Vector3(x - 0.6, level * House.HEIGHT + 0.84, fixture.floor_bounds.size.y * 0.5 - 0.69), Vector3(1.2, 1.21, 1.38))])
	# The lift's car and its doorway (tests/test_ward_dress.gd), in the car's frame.
	var car: Lift = view.lift_car
	out.append(["lift car", car.global_transform, AABB(Vector3(-car.half + 0.04, 0.04, -car.depth + 0.06), Vector3(car.half * 2.0 - 0.08, Lift.CAR_H - 0.1, car.depth - 0.06 - Lift.FRONT - 0.03))])
	out.append(["lift doorway", car.global_transform, AABB(Vector3(-car.door_half + 0.02, 0.04, -Lift.FRONT), Vector3(car.door_half * 2.0 - 0.04, Lift.DOOR_H - 0.06, Lift.FRONT + Lift.LAND + 0.4))])
	return out

func test_nothing_the_skin_adds_stands_where_people_walk_or_look_through(t: T) -> void:
	for case: Array in FEW:
		var view := _view(int(case[0]), case[1])
		var parts := skin_parts(view)
		var regions := keep_clear(view)
		# The lift's shaft stands round the car, where nobody walks: the gallery strips there are the car's.
		var car_box := AABB(Vector3(-view.lift_car.half - 0.25, -20.0, -view.lift_car.depth - 0.3), Vector3(view.lift_car.half * 2.0 + 0.5, 60.0, view.lift_car.depth + 0.3))
		var hits: Array[String] = []
		for part: Array in parts:
			for region: Array in regions:
				if region[0] == "gallery" and part[0] == "rail":
					# A walkway's thin rope is drawn on its old rail's line, which ran onto the gallery already.
					continue
				if region[0] == "gallery":
					var middle: Vector3 = view.lift_car.global_transform.affine_inverse() * ((part[1] as Transform3D) * (part[2] as AABB).get_center())
					if car_box.has_point(middle):
						continue
				if Dressing._overlaps(part[1], part[2], region[1], region[2]):
					var at: Vector3 = (part[1] as Transform3D) * (part[2] as AABB).get_center()
					hits.append("%s in a %s at %s" % [part[0], region[0], str(at.snappedf(0.01))])
		t.check(parts.size() > 200, "seed %d: the skin's parts were found (%d)" % [case[0], parts.size()])
		t.check(hits.is_empty(), "seed %d: nothing the skin adds is in a walkway, gallery, doorway, window or the lift (%d: %s)" % [case[0], hits.size(), ", ".join(hits.slice(0, 4))])
		view.free()

func test_the_roof_meets_every_line_and_the_shaft_reaches_it(t: T) -> void:
	for case: Array in FEW:
		var view := _view(int(case[0]), case[1])
		var roof := view.find_child("CavernRoof", false, false) as Node3D
		var rock := roof.find_children("RockCeiling*", "MeshInstance3D", false, false) if roof != null else []
		t.check(rock.size() > 4, "seed %d: the cavern's roof is rock, in pieces (%d)" % [case[0], rock.size()])
		# Where each deck line is fixed, the rock is at the roof's height: no line ends in the air or inside the rock.
		var gaps: Array[String] = []
		for row: Dictionary in view.houses:
			for line: Node3D in row.lines:
				var top := line.global_position
				var down := Vector3(top.x, view.roof_y + 20.0, top.z)
				var hit := _rock_at(rock, down)
				if absf(hit - view.roof_y) > 0.05:
					gaps.append("%s: rock at %.2f" % [str(Vector2(top.x, top.z).snappedf(0.01)), hit])
		t.check(gaps.is_empty(), "seed %d: the rock meets every line where it is fixed (%s)" % [case[0], ", ".join(gaps.slice(0, 4))])
		var shaft := view.find_child("LiftShaft", false, false) as Node3D
		t.check(shaft != null, "seed %d: the lift has its shaft" % case[0])
		if shaft != null:
			var lo := INF
			var hi := -INF
			for node: Node in shaft.find_children("timber", "MeshInstance3D", true, false):
				for part: Array in node.get_meta(&"parts"):
					var box := (node as MeshInstance3D).global_transform * (part[0] as Transform3D) * (part[1] as AABB)
					lo = minf(lo, box.position.y)
					hi = maxf(hi, box.end.y)
			var floor_y := view.lift_car.global_position.y
			t.check(lo < floor_y - 5.0 and absf(hi - view.roof_y) < 0.3, "seed %d: its posts run from far below the car (%.1f) up to the roof (%.1f, roof %.1f)" % [case[0], lo, hi, view.roof_y])
		view.free()

## The rock's height under a point (a ray straight down through its pieces' faces), or INF.
static func _rock_at(pieces: Array, from: Vector3) -> float:
	for node: Node in pieces:
		var mesh := node as MeshInstance3D
		var faces := mesh.mesh.get_faces()
		for k in range(0, faces.size(), 3):
			var hit: Variant = Geometry3D.ray_intersects_triangle(from, Vector3.DOWN, faces[k], faces[k + 1], faces[k + 2])
			if hit != null:
				return (hit as Vector3).y
	return INF

## Every box the skin adds, as text, hashed (where and how big; node names carry the engine's counters).
static func dressing(view: View) -> String:
	var rows: Array[String] = []
	for part: Array in skin_parts(view):
		var box: AABB = part[2]
		rows.append("%s|%s,%s,%s" % [_xf(part[1]), _f(box.size.x), _f(box.size.y), _f(box.size.z)])
	rows.sort()
	return "\n".join(rows).sha256_text()

func test_the_same_seed_dresses_the_same(t: T) -> void:
	var a := _view(253193259, [2, 110, 150])
	var first := dressing(a)
	a.free()
	var b := _view(253193259, [2, 110, 150])
	t.eq(dressing(b), first, "the same seed and layout: the same dressing, box for box")
	b.free()
	var c := _view(253193260, [2, 110, 150])
	t.check(dressing(c) != first, "another seed: another dressing")
	c.free()

func test_the_photographs_are_in_the_project(t: T) -> void:
	for name: String in WardSkin.TEXTURES:
		var texture := load(WardSkin.DIR + name) as Texture2D
		t.check(texture != null and texture.get_width() <= 512 and texture.get_width() >= 256, "%s is imported, 256 to 512 px (%s)" % [name, str(texture.get_size()) if texture != null else "missing"])
	t.check(FileAccess.file_exists(WardSkin.DIR + "SOURCES.md"), "each photograph's source and licence is written beside them")
