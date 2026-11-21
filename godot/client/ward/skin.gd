# AW1: the Hanging Ward's surfaces and sky, around what client/ward/view.gd and client/ward/dress.gd build. The owner,
# 21 Nov: "the houses in the ward don't make sense ... It's currently very rough and blocky. Textures will help ...
# free resources for packs that are cc0 will help". The art judge's report (J2): one world scale for brick and plaster
# on every box, CC0 photo maps, thin rails, fewer hangers, a visible cavern roof with lamps and mist below, a timber
# shaft round the lift car.
#   - materials: CC0 photographs from Poly Haven (godot/assets/ward/surfaces/SOURCES.md), each laid in world metres
#     (ward_tri.gdshader), so a brick is the same size on every box;
#   - house_box: a house's wall, slab or partition as a box whose faces say what they are (ward_house.gdshader): brick
#     outside, inside a plaster room with skirting, a dado and rail, plaster or wallpaper above, a floor stained by room
#     and whitewashed ceiling boards;
#   - dress_house: corner boards, string courses, window lintels, a door hood and number, gables under the roof, a ridge,
#     gutters and a downpipe, the chimney's pots or cowl; all inside the Rigger's box for the house
#     (sim/ward/rigger_graph.gd _solids: 0.2 m past the walls, 0.24 m past front and back, up to the roof's top);
#   - lift_shaft: a timber-and-iron shaft round the car, from the dark below up to a head frame under the cavern's roof;
#   - rock_ceiling and depths: the cavern's roof in rock with lamps hung from it, mist below the decks and the faint
#     lights of houses far down.
# Nothing here is a body: no rule, sight line or Rigger pose reads any of it. Everything comes from the layout and the
# floor's seed, the same on every screen.
extends RefCounted

const House = preload("res://sim/ward/house.gd")
const Layout = preload("res://sim/ward/layout.gd")
const TriShader = preload("res://client/ward/ward_tri.gdshader")
const HouseShader = preload("res://client/ward/ward_house.gdshader")
const MistShader = preload("res://client/ward/ward_mist.gdshader")

const DIR := "res://assets/ward/surfaces/"
## The photographs (CC0, Poly Haven; assets_src/ward_textures.py makes them from the 1k colour maps).
const TEXTURES := ["brick.webp", "plaster.webp", "planks.webp", "floorboards.webp", "slates.webp", "rock.webp",
	"iron.webp", "doorwood.webp", "paper.webp"]
## Metres one picture covers: each is the photograph's own real size (Poly Haven's), rounded.
const BRICK_TILE := 1.0
const PLASTER_TILE := 1.0
const FLOOR_TILE := 2.0
const BOARD_TILE := 1.5
const PAPER_TILE := 1.25
const WOOD_TILE := 1.0
const PLANK_TILE := 2.0
const SLATE_TILE := 3.0
const ROCK_TILE := 11.0
const IRON_TILE := 1.0
## The cavern's rock is built in pieces this many cells (2.5 m) square.
const ROCK_PIECE := 6
## The group every node the skin adds is in (tests/test_ward_skin.gd).
const GROUP := &"ward_skin"
## Materials that are flat colours on purpose: light itself, glass, the Rigger's own arm.
const FLAT_ON_PURPOSE := ["light", "glass", "arm", "arm_v2", "bulb", "far_light", "mist"]
## A house's outside finish by its style (ward_house.gdshader: sooted red, red, limewashed, soot-black).
const FINISH := {"parlour_cottage": 1, "weavers_terrace": 0, "laundry_maisonette": 2, "lampkeepers_cottage": 2,
	"underbridge_bedsits": 3, "boarders_flat": 0, "hoist_rowhouse": 1, "attic_workshop": 3}
## What stands on a style's chimney: 0 two pots, 1 an iron cowl, 2 a tall vent pipe.
const CHIMNEY := {"parlour_cottage": 0, "weavers_terrace": 0, "laundry_maisonette": 2, "lampkeepers_cottage": 1,
	"underbridge_bedsits": 2, "boarders_flat": 1, "hoist_rowhouse": 1, "attic_workshop": 0}

static func _texture(name: String) -> Texture2D:
	return load(DIR + name) as Texture2D

static func _tri(texture: String, tile: float, tint: Color, roughness := 0.9, metal := 0.0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = TriShader
	m.set_shader_parameter("albedo_tex", _texture(texture))
	m.set_shader_parameter("tile", tile)
	m.set_shader_parameter("tint", tint)
	m.set_shader_parameter("roughness_value", roughness)
	m.set_shader_parameter("metal", metal)
	return m

## The Ward's materials, by the names view.gd's boxes use (and the skin's own), into `colors`.
static func materials(colors: Dictionary) -> void:
	var house := ShaderMaterial.new()
	house.shader = HouseShader
	for pair: Array in [["brick_tex", "brick.webp"], ["plaster_tex", "plaster.webp"], ["floor_tex", "floorboards.webp"],
			["board_tex", "planks.webp"], ["paper_tex", "paper.webp"], ["wood_tex", "doorwood.webp"]]:
		house.set_shader_parameter(pair[0], _texture(pair[1]))
	for pair: Array in [["brick_tile", BRICK_TILE], ["plaster_tile", PLASTER_TILE], ["floor_tile", FLOOR_TILE],
			["board_tile", BOARD_TILE], ["paper_tile", PAPER_TILE], ["wood_tile", WOOD_TILE]]:
		house.set_shader_parameter(pair[0], pair[1])
	colors["house"] = house
	colors["brick"] = _tri("brick.webp", BRICK_TILE, Color(0.78, 0.7, 0.66))
	colors["plaster"] = _tri("plaster.webp", PLASTER_TILE, Color(0.85, 0.8, 0.7))
	colors["wood"] = _tri("planks.webp", PLANK_TILE, Color(0.72, 0.56, 0.42))
	colors["timber"] = _tri("planks.webp", PLANK_TILE, Color(0.45, 0.36, 0.28))
	colors["rope"] = _tri("planks.webp", 0.4, Color(0.92, 0.78, 0.64))
	colors["iron"] = _tri("iron.webp", IRON_TILE, Color(0.62, 0.62, 0.62), 0.7, 0.3)
	colors["cable"] = _tri("iron.webp", IRON_TILE, Color(0.38, 0.38, 0.38), 0.6, 0.4)
	colors["door"] = _tri("doorwood.webp", WOOD_TILE, Color(0.62, 0.5, 0.44))
	colors["panel"] = _tri("doorwood.webp", WOOD_TILE, Color(0.74, 0.6, 0.5))
	colors["trim"] = _tri("doorwood.webp", WOOD_TILE, Color(0.36, 0.3, 0.27))
	colors["brass"] = _tri("iron.webp", IRON_TILE, Color(1.0, 0.8, 0.42), 0.4, 0.8)
	colors["slate"] = _tri("slates.webp", SLATE_TILE, Color(0.5, 0.52, 0.56))
	colors["rock"] = _tri("rock.webp", ROCK_TILE, Color(0.36, 0.34, 0.33), 1.0)
	var bulb := StandardMaterial3D.new()
	bulb.albedo_color = Color("#ffcf8a")
	bulb.emission_enabled = true
	bulb.emission = Color("#ffb865")
	bulb.emission_energy_multiplier = 2.0
	colors["bulb"] = bulb
	var far := StandardMaterial3D.new()
	far.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	far.albedo_color = Color("#8a6a3e")
	# Far below the height fog would swallow them whole: they keep their own dim colour instead.
	far.disable_fog = true
	colors["far_light"] = far
	var mist := ShaderMaterial.new()
	mist.shader = MistShader
	colors["mist"] = mist

## Whether a material is one of the skin's textured ones (a photograph on it).
static func textured(material: Material) -> bool:
	if material is ShaderMaterial:
		var shader := (material as ShaderMaterial).shader
		if shader == TriShader:
			return (material as ShaderMaterial).get_shader_parameter("albedo_tex") is Texture2D
		if shader == HouseShader:
			return (material as ShaderMaterial).get_shader_parameter("brick_tex") is Texture2D
	if material is BaseMaterial3D:
		return (material as BaseMaterial3D).albedo_texture != null
	return false

# ------------------------------------------------------------------------------------------------
# Faces.

# ------------------------------------------------------------------------------------------------
# A house's walls.

## What view.gd's house root carries for its boxes (house_box): the floor's bounds, the walls' top, the outside finish,
## where each storey's rooms divide (local z), and a number from the floor's seed and the house.
static func house_info(fixture: House, site: Dictionary, seed_value: int) -> Dictionary:
	var splits := {}
	var ground := PackedFloat32Array()
	for door: Vector3 in fixture.room_doors:
		ground.append(door.z)
	splits[0] = ground
	for k in range(1, int(site.floors)):
		splits[k] = PackedFloat32Array([fixture.floor_bounds.size.y * 0.5])
	return {"bounds": fixture.floor_bounds, "top": House.HEIGHT * float(site.floors), "finish": int(FINISH.get(str(site.style), 0)),
		"splits": splits, "mix": seed_value * 31 + int(site.id) * 997}

## A room's variant (0 to 3) from the house's number, the storey and the room.
static func room_variant(info: Dictionary, storey: int, room: int) -> int:
	var x: int = (int(info.mix) * 73856093) ^ (storey * 19349663) ^ (room * 83492791)
	return posmod(x >> 4, 4)

static func _room(info: Dictionary, storey: int, z: float) -> int:
	var count := 0
	for split: float in (info.splits as Dictionary).get(storey, PackedFloat32Array()):
		count += 1 if split < z else 0
	return count

## A house box's mesh for view.gd _box("house"): `at` in `parent`'s frame, which is the house's root or a node under it
## (only moved, never turned). Each face is told whether it is outside, its variant, and its heights (ward_house).
static func house_box(parent: Node3D, at: Vector3, size: Vector3) -> ArrayMesh:
	var local := at
	var node: Node = parent
	while node != null and not node.has_meta(&"ward_house"):
		local = (node as Node3D).transform * local
		node = node.get_parent()
	var info: Dictionary = node.get_meta(&"ward_house") if node != null else {"bounds": Rect2(-INF, -INF, INF, INF), "top": INF, "finish": 0, "splits": {}, "mix": 0}
	var bounds: Rect2 = info.bounds
	var e := size * 0.5
	var bottom := local.y - e.y
	var storey := maxi(0, floori((bottom + 0.02) / House.HEIGHT))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for axis in 3:
		for s: float in [-1.0, 1.0]:
			var n := Vector3.ZERO
			n[axis] = s
			var centre := local + n * e
			var outside := centre.x < bounds.position.x - 0.005 or centre.x > bounds.end.x + 0.005 \
				or centre.z < bounds.position.y - 0.005 or centre.z > bounds.end.y + 0.005 or centre.y > float(info.top) + 0.005
			var u := Vector3.ZERO
			u[(axis + 1) % 3] = e[(axis + 1) % 3]
			var v := Vector3.ZERO
			v[(axis + 2) % 3] = e[(axis + 2) % 3]
			var c := n * e
			if outside:
				var color := Color(1.0, 0.0, (float(info.finish) + 0.5) / 4.0)
				var corners: Array[Vector3] = [c - u - v, c + u - v, c + u + v, c - u + v]
				var h := Vector4(local.y + corners[0].y, local.y + corners[1].y, local.y + corners[2].y, local.y + corners[3].y)
				Batch.quad(st, corners[0], corners[1], corners[2], corners[3], n, color, h)
				continue
			if axis == 1 and s > 0.0:
				# A floor: split where the storey's rooms divide, each strip its room's stain.
				var level := roundi(centre.y / House.HEIGHT)
				var cuts: Array[float] = [local.z - e.z]
				for split: float in (info.splits as Dictionary).get(level, PackedFloat32Array()):
					if split > local.z - e.z + 0.01 and split < local.z + e.z - 0.01:
						cuts.append(split)
				cuts.append(local.z + e.z)
				for i in cuts.size() - 1:
					var z0 := cuts[i] - local.z
					var z1 := cuts[i + 1] - local.z
					var room := _room(info, level, (cuts[i] + cuts[i + 1]) * 0.5)
					var color := Color(0.0, 0.0, (float(room_variant(info, level, room)) + 0.5) / 4.0)
					Batch.quad(st, Vector3(-e.x, e.y, z0), Vector3(e.x, e.y, z0), Vector3(e.x, e.y, z1), Vector3(-e.x, e.y, z1), n, color)
				continue
			var room := _room(info, storey, centre.z)
			var color := Color(0.0, 0.0, (float(room_variant(info, storey, room)) + 0.5) / 4.0)
			var base := float(storey) * House.HEIGHT
			var corners: Array[Vector3] = [c - u - v, c + u - v, c + u + v, c - u + v]
			var h := Vector4(local.y + corners[0].y - base, local.y + corners[1].y - base, local.y + corners[2].y - base, local.y + corners[3].y - base)
			Batch.quad(st, corners[0], corners[1], corners[2], corners[3], n, color, h)
	return st.commit()

# ------------------------------------------------------------------------------------------------
# Batches: many small boxes of the skin drawn as one mesh per material.

class Batch:
	## Appends the quad a, b, c, d (in order round it) to `st`, facing `normal` (Godot's front faces wind clockwise).
	static func quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, normal: Vector3, color := Color.WHITE,
			heights := Vector4.ZERO) -> void:
		var points := [a, b, c, d]
		var h := [heights.x, heights.y, heights.z, heights.w]
		var order := [0, 1, 2, 0, 2, 3]
		if (b - a).cross(c - a).dot(normal) > 0.0:
			order = [0, 2, 1, 0, 3, 2]
		for i: int in order:
			st.set_normal(normal)
			st.set_color(color)
			st.set_uv(Vector2.ZERO)
			st.set_uv2(Vector2(float(h[i]), 0.0))
			st.add_vertex(points[i])

	static func triangle(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, normal: Vector3, color := Color.WHITE) -> void:
		var order := [a, b, c] if (b - a).cross(c - a).dot(normal) < 0.0 else [a, c, b]
		for p: Vector3 in order:
			st.set_normal(normal)
			st.set_color(color)
			st.set_uv(Vector2.ZERO)
			st.set_uv2(Vector2(5.0, 0.0))
			st.add_vertex(p)

	## The six faces of a box `size` under `xf` (its middle at xf.origin).
	static func box_faces(st: SurfaceTool, xf: Transform3D, size: Vector3, color := Color.WHITE) -> void:
		var e := size * 0.5
		for axis in 3:
			for s: float in [-1.0, 1.0]:
				var n := Vector3.ZERO
				n[axis] = s
				var u := Vector3.ZERO
				u[(axis + 1) % 3] = e[(axis + 1) % 3]
				var v := Vector3.ZERO
				v[(axis + 2) % 3] = e[(axis + 2) % 3]
				var c := n * e
				quad(st, xf * (c - u - v), xf * (c + u - v), xf * (c + u + v), xf * (c - u + v), (xf.basis * n).normalized(), color)

	var tools := {}
	## Each part, by material: [transform, box] in the batch's frame, for the tests.
	var parts := {}

	func box(key: String, xf: Transform3D, size: Vector3, color := Color.WHITE) -> void:
		_tool(key)
		box_faces(tools[key], xf, size, color)
		(parts[key] as Array).append([xf, AABB(-size * 0.5, size)])

	## A box from `a` to `b` (its long axis), `width` by `height` across.
	func beam(key: String, a: Vector3, b: Vector3, width: float, height: float) -> void:
		var along := b - a
		var z := along.normalized()
		var up := Vector3.UP if absf(z.dot(Vector3.UP)) < 0.99 else Vector3.FORWARD
		var x := up.cross(z).normalized()
		var y := z.cross(x)
		box(key, Transform3D(Basis(x, y, z), (a + b) * 0.5), Vector3(width, height, along.length()))

	## A prism: the triangle a, b, c pushed `depth` along `out` (house-material gables, outside).
	func prism(key: String, a: Vector3, b: Vector3, c: Vector3, out: Vector3, depth: float, color: Color) -> void:
		var st := _tool(key)
		var o := out.normalized() * depth
		triangle(st, a, b, c, -out.normalized(), color)
		triangle(st, a + o, b + o, c + o, out.normalized(), color)
		for edge: Array in [[a, b], [b, c], [c, a]]:
			var p: Vector3 = edge[0]
			var q: Vector3 = edge[1]
			var n := (q - p).cross(out).normalized()
			if n.dot(p - (a + b + c) / 3.0) < 0.0:
				n = -n
			quad(st, p, q, q + o, p + o, n, color, Vector4(5, 5, 5, 5))
		var lo := a.min(b).min(c).min(a + o)
		var hi := a.max(b).max(c).max(c + o).max(b + o)
		(parts[key] as Array).append([Transform3D.IDENTITY, AABB(lo, hi - lo)])

	func _tool(key: String) -> SurfaceTool:
		if not tools.has(key):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			tools[key] = st
			parts[key] = []
		return tools[key]

	## The batch as one node under `parent`: a mesh per material, each in the skin's group with its parts.
	func commit(parent: Node3D, name: String, colors: Dictionary) -> Node3D:
		var node := Node3D.new()
		node.name = name
		node.add_to_group(&"ward_skin")
		parent.add_child(node)
		var keys := tools.keys()
		keys.sort()
		for key: String in keys:
			var mesh := MeshInstance3D.new()
			mesh.name = key
			mesh.mesh = (tools[key] as SurfaceTool).commit()
			mesh.material_override = colors[key]
			mesh.set_meta(&"parts", parts[key])
			mesh.add_to_group(&"ward_skin")
			node.add_child(mesh)
		return node

# ------------------------------------------------------------------------------------------------
# A house's outside.

## The roof's pitch for a house of `floors` (view.gd _dress_house).
static func pitch(floors: int) -> float:
	return deg_to_rad(11.0 if floors == 1 else 7.0)

## Corner boards, string courses, window lintels, the door's hood and number, gables and ridge, gutters, a downpipe and
## the chimney's top, in the house's own frame (its root).
static func dress_house(view: Node3D, root: Node3D, site: Dictionary, fixture: House, seed_value: int) -> Node3D:
	var colors: Dictionary = view.get("colors")
	var batch := Batch.new()
	var bounds := fixture.floor_bounds
	var width := bounds.size.x
	var depth := bounds.size.y
	var half := width * 0.5
	var floors := int(site.floors)
	var top := House.HEIGHT * floors
	var wall := House.WALL_THICKNESS
	var lift_house := int(site.id) == 0
	# Corner boards: they close the notch where the front wall meets the sides, and frame the back corners.
	for s: float in [-1.0, 1.0]:
		batch.box("trim", Transform3D(Basis.IDENTITY, Vector3(s * (half + 0.085), (top - 0.14) * 0.5, -0.035)), Vector3(0.17, top + 0.14, 0.13))
		batch.box("trim", Transform3D(Basis.IDENTITY, Vector3(s * (half + 0.105), (top - 0.14) * 0.5, depth + 0.105)), Vector3(0.13, top + 0.14, 0.13))
	# A string course at every storey above the ground, all round.
	for level in range(1, floors):
		var y := float(level) * House.HEIGHT
		batch.box("trim", Transform3D(Basis.IDENTITY, Vector3(0, y, -0.09)), Vector3(width + 0.3, 0.14, 0.04))
		batch.box("trim", Transform3D(Basis.IDENTITY, Vector3(0, y, depth + 0.16)), Vector3(width + 0.3, 0.14, 0.04))
		for s: float in [-1.0, 1.0]:
			batch.box("trim", Transform3D(Basis.IDENTITY, Vector3(s * (half + wall + 0.02), y, depth * 0.5)), Vector3(0.04, 0.14, depth + 0.3))
	# A lintel over every side window (view.gd _window_wall: 1.42 wide, sill 0.82, 1.25 high, the wall's middle).
	for level in floors:
		for s: float in [-1.0, 1.0]:
			if lift_house and level == 0 and s < 0.0:
				continue
			var y := float(level) * House.HEIGHT + 0.82 + 1.25 + 0.1
			batch.box("trim", Transform3D(Basis.IDENTITY, Vector3(s * (half + wall + 0.02), y, depth * 0.5)), Vector3(0.04, 0.16, 1.72))
	# The front door: a hood on two brackets, and the house's number on a plate beside it.
	var door := fixture.door
	var hood_w := door.size.x + 0.5
	batch.box("slate", Transform3D(Basis.IDENTITY, Vector3(door.get_center().x, 2.47, -0.15)), Vector3(hood_w, 0.06, 0.16))
	for s: float in [-1.0, 1.0]:
		batch.box("trim", Transform3D(Basis.IDENTITY, Vector3(door.get_center().x + s * (hood_w * 0.5 - 0.06), 2.36, -0.13)), Vector3(0.06, 0.16, 0.12))
	var plate_x := door.end.x + 0.36
	batch.box("trim", Transform3D(Basis.IDENTITY, Vector3(plate_x, 1.62, -0.08)), Vector3(0.26, 0.2, 0.02))
	# The roof: a gable under each end of the two pitched panels, a ridge board, gutters and a downpipe.
	var p := pitch(floors)
	var ridge := top + 0.24 + tan(p) * 0.26 * width
	var reach := minf(0.26 * width + 0.07 / tan(p), half + wall)
	var finish := Color(1.0, 0.0, (float(FINISH.get(str(site.style), 0)) + 0.5) / 4.0)
	for end: Array in [[0.065, Vector3.FORWARD], [depth, Vector3.BACK]]:
		var z: float = end[0]
		batch.prism("house", Vector3(-reach, top + 0.09, z), Vector3(reach, top + 0.09, z), Vector3(0, ridge - 0.09, z), end[1], 0.14, finish)
	batch.box("trim", Transform3D(Basis.IDENTITY, Vector3(0, ridge + 0.02, depth * 0.5)), Vector3(0.16, 0.1, depth + 0.5))
	var eave_x := 0.26 * width + 0.28 * width * cos(p) - 0.04
	var eave_y := top + 0.24 - 0.28 * width * sin(p) - 0.1
	var pipe_side := -1.0 if posmod(int(site.id) + seed_value, 2) == 0 else 1.0
	if lift_house:
		pipe_side = 1.0
	for s: float in [-1.0, 1.0]:
		if lift_house and s < 0.0:
			continue
		batch.box("iron", Transform3D(Basis.IDENTITY, Vector3(s * eave_x, eave_y, depth * 0.5)), Vector3(0.11, 0.09, depth + 0.4))
	batch.box("iron", Transform3D(Basis.IDENTITY, Vector3(pipe_side * (half + 0.1), eave_y * 0.5, depth + 0.2)), Vector3(0.07, eave_y, 0.07))
	batch.beam("iron", Vector3(pipe_side * (half + 0.1), eave_y, depth + 0.2), Vector3(pipe_side * eave_x, eave_y, depth + 0.12), 0.06, 0.06)
	# The chimney's top (view.gd _dress_house: the stack at x -0.28 width, its cap at the roof + 1.03).
	var stack := Vector3(-width * 0.28, top + 1.105, depth * 0.5 - 0.61)
	match int(CHIMNEY.get(str(site.style), 0)):
		0:
			for dx: float in [-0.1, 0.1]:
				batch.box("brick", Transform3D(Basis.IDENTITY, stack + Vector3(dx, 0.1, 0)), Vector3(0.11, 0.2, 0.11))
		1:
			batch.box("iron", Transform3D(Basis.IDENTITY, stack + Vector3(0, 0.08, 0)), Vector3(0.14, 0.16, 0.14))
			batch.box("iron", Transform3D(Basis.IDENTITY, stack + Vector3(0, 0.2, 0)), Vector3(0.3, 0.05, 0.3))
		_:
			batch.box("iron", Transform3D(Basis.IDENTITY, stack + Vector3(0.08, 0.22, 0.05)), Vector3(0.06, 0.44, 0.06))
	var node := batch.commit(root, "HouseSkin", colors)
	# The number: one to ninety-nine, from the floor's seed and the house, the same on every screen.
	var number := Label3D.new()
	number.name = "HouseNumber"
	number.text = str(1 + posmod((seed_value >> 3) + int(site.id) * 7, 98))
	number.font_size = 48
	number.pixel_size = 0.003
	number.modulate = Color("#d8c9a8")
	number.outline_size = 0
	number.position = Vector3(plate_x, 1.62, -0.095)
	number.rotation.y = PI
	node.add_child(number)
	return node

# ------------------------------------------------------------------------------------------------
# The lift's shaft.

## The shaft round the Ward's car (client/lift.gd, built by dress.gd build_lift): four timber posts at its corners from
## far below up to the cavern's roof at `roof` (world y), iron rings and cross braces, timber boards over the car's
## outside, and a head frame with its sheave wheel under the roof. In the car's own frame (x right walking in, z out
## of the car, the car from z 0 back to -depth). The near posts stand off the house's wall, past its roof's eave.
static func lift_shaft(view: Node3D, car: Lift, roof: float) -> Node3D:
	var colors: Dictionary = view.get("colors")
	var holder := Node3D.new()
	holder.name = "LiftShaft"
	holder.add_to_group(GROUP)
	view.add_child(holder)
	holder.global_transform = car.global_transform
	var top := roof - car.global_position.y
	var x := car.half + 0.13
	var near := -0.42
	var far := -car.depth - 0.13
	var bottom := -9.0
	var batch := Batch.new()
	for sx: float in [-1.0, 1.0]:
		# The far posts run unbroken from the dark below; the near ones stand on the gallery and go on under it.
		batch.box("timber", Transform3D(Basis.IDENTITY, Vector3(sx * x, (bottom + top) * 0.5, far)), Vector3(0.14, top - bottom, 0.14))
		batch.box("timber", Transform3D(Basis.IDENTITY, Vector3(sx * x, top * 0.5, near)), Vector3(0.14, top, 0.14))
		batch.box("timber", Transform3D(Basis.IDENTITY, Vector3(sx * x, (bottom - 0.3) * 0.5, near)), Vector3(0.14, -0.3 - bottom, 0.14))
		# Timber boards over the car's outside (its steel side wall is at half + 0.04).
		batch.box("timber", Transform3D(Basis.IDENTITY, Vector3(sx * (car.half + 0.055), Lift.CAR_H * 0.5, -car.depth * 0.5 - 0.1)), Vector3(0.02, Lift.CAR_H, car.depth - 0.2))
	batch.box("timber", Transform3D(Basis.IDENTITY, Vector3(0, Lift.CAR_H * 0.5, -car.depth - 0.055)), Vector3(car.half * 2.0 + 0.13, Lift.CAR_H, 0.02))
	batch.box("iron", Transform3D(Basis.IDENTITY, Vector3(0, Lift.CAR_H + 0.05, -car.depth * 0.5 - 0.05)), Vector3(car.half * 2.0 + 0.13, 0.03, car.depth))
	# Rings every 2.6 m, above the car and below the gallery; the front one only clear of the parlour's roof.
	var levels: Array[float] = []
	var y := -2.6
	while y > bottom + 0.5:
		levels.append(y)
		y -= 2.6
	y = Lift.CAR_H + 0.35
	while y < top - 2.5:
		levels.append(y)
		y += 2.6
	for ring: float in levels:
		var corners := [Vector3(-x, ring, near), Vector3(x, ring, near), Vector3(x, ring, far), Vector3(-x, ring, far)]
		for i in 4:
			if i == 0 and ring > -0.5 and ring < 4.6:
				continue
			batch.beam("iron", corners[i], corners[(i + 1) % 4], 0.07, 0.09)
	# Cross braces on the two sides and the back between rings.
	levels.sort()
	for i in levels.size() - 1:
		var lo := levels[i]
		var hi := levels[i + 1]
		if hi - lo > 2.7 or (lo < 0.0 and hi > 0.0):
			continue
		for side: Array in [[Vector3(-x, 0, near), Vector3(-x, 0, far)], [Vector3(x, 0, near), Vector3(x, 0, far)], [Vector3(-x, 0, far), Vector3(x, 0, far)]]:
			var a: Vector3 = side[0]
			var b: Vector3 = side[1]
			batch.beam("cable", a + Vector3.UP * lo, b + Vector3.UP * hi, 0.035, 0.035)
			batch.beam("cable", b + Vector3.UP * lo, a + Vector3.UP * hi, 0.035, 0.035)
	# The head frame: two heavy beams across the posts' tops, struts down to the posts, the sheave's axle between them.
	var head := top - 1.2
	for z: float in [near, far]:
		batch.box("timber", Transform3D(Basis.IDENTITY, Vector3(0, head, z)), Vector3(x * 2.0 + 0.3, 0.26, 0.2))
	for sx: float in [-1.0, 1.0]:
		batch.box("timber", Transform3D(Basis.IDENTITY, Vector3(sx * x, head, (near + far) * 0.5)), Vector3(0.2, 0.26, far - near))
		for z: float in [near, far]:
			batch.beam("timber", Vector3(sx * x, head - 2.4, z), Vector3(sx * 0.25, head - 0.1, z), 0.12, 0.12)
	batch.box("iron", Transform3D(Basis.IDENTITY, Vector3(0, head + 0.55, (near + far) * 0.5)), Vector3(x * 2.0, 0.08, 0.08))
	var node := batch.commit(holder, "Frame", colors)
	var wheel := MeshInstance3D.new()
	wheel.name = "Sheave"
	var disk := CylinderMesh.new()
	disk.top_radius = 0.75
	disk.bottom_radius = 0.75
	disk.height = 0.1
	disk.radial_segments = 20
	wheel.mesh = disk
	wheel.material_override = colors["iron"]
	wheel.position = Vector3(0, head + 0.55, (near + far) * 0.5)
	wheel.rotation.z = PI * 0.5
	wheel.add_to_group(GROUP)
	node.add_child(wheel)
	# A caged lamp on the shaft's side over the gallery, so it is seen from the walkways.
	var lamp_at := Vector3(x + 0.1, Lift.CAR_H + 0.25, (near + far) * 0.5)
	var cage := Batch.new()
	cage.box("bulb", Transform3D(Basis.IDENTITY, lamp_at), Vector3(0.12, 0.16, 0.12))
	cage.box("iron", Transform3D(Basis.IDENTITY, lamp_at + Vector3(0, 0.11, 0)), Vector3(0.18, 0.04, 0.18))
	cage.commit(holder, "ShaftLamp", colors)
	var light := OmniLight3D.new()
	light.name = "ShaftLight"
	light.light_color = Color("#ffc381")
	light.light_energy = 0.9
	light.omni_range = 6.0
	light.position = lamp_at + Vector3(0.15, 0, 0)
	holder.add_child(light)
	return holder

## The shaft's four corners on the roof (world), where the rock must meet them.
static func shaft_corners(car: Lift) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for sx: float in [-1.0, 1.0]:
		for z: float in [-0.42, -car.depth - 0.13]:
			out.append(car.global_transform * Vector3(sx * (car.half + 0.13), 0, z))
	return out

# ------------------------------------------------------------------------------------------------
# The cavern's roof and the depths.

## The rock's height above `roof` at (x, z): broad swells and smaller lumps, flat where a line is fixed (`anchors`),
## and bending down at the edges into walls. From the floor's seed: the same on every screen.
static func rock_height(x: float, z: float, seed_value: int, anchors: Array[Vector2], lo: Vector2, hi: Vector2) -> float:
	var phase := float(posmod(seed_value, 997)) * 0.37
	var swell := sin(x * 0.11 + phase) * cos(z * 0.09 - phase * 0.5) * 2.2 + sin((x + z) * 0.23 + phase * 1.3) * 0.9 \
		+ sin(x * 0.61 - z * 0.47 + phase) * 0.35
	var near := INF
	for a: Vector2 in anchors:
		near = minf(near, Vector2(x, z).distance_to(a))
	# Flat for a whole cell (2.5 m) round each: the rock is drawn on a 2.5 m grid, so every corner of the cell a line
	# meets is at the roof's height and the face between them is too.
	var flat := clampf((near - 3.6) / 4.0, 0.0, 1.0)
	var edge := minf(minf(x - lo.x, hi.x - x), minf(z - lo.y, hi.y - z))
	var wall := 1.0 - clampf(edge / 14.0, 0.0, 1.0)
	return swell * flat - wall * wall * 22.0 * clampf(near / 8.0, 0.0, 1.0)

## The rock over the Ward at `roof`: a lumpy surface from `lo` to `hi` (world x, z), its faces down.
static func rock_ceiling(view: Node3D, parent: Node3D, roof: float, lo: Vector2, hi: Vector2, anchors: Array[Vector2]) -> MeshInstance3D:
	var colors: Dictionary = view.get("colors")
	var seed_value := int(view.get("seed_value"))
	var step := 2.5
	var nx := ceili((hi.x - lo.x) / step)
	var nz := ceili((hi.y - lo.y) / step)
	var heights := PackedFloat32Array()
	for i in nx + 1:
		for j in nz + 1:
			var x := lo.x + (hi.x - lo.x) * i / nx
			var z := lo.y + (hi.y - lo.y) * j / nz
			heights.append(rock_height(x, z, seed_value, anchors, lo, hi))
	var point := func(i: int, j: int) -> Vector3:
		return Vector3(lo.x + (hi.x - lo.x) * i / nx, roof + heights[i * (nz + 1) + j], lo.y + (hi.y - lo.y) * j / nz)
	# In pieces of ROCK_PIECE cells: the browser's renderer lights each mesh by its nearest few lamps only, so one
	# mesh over the whole Ward would take the roof's lamps from most of it. Each cell's box is kept for the tests (the
	# whole rock's box reaches down its walls).
	var last: MeshInstance3D = null
	for ci in range(0, nx, ROCK_PIECE):
		for cj in range(0, nz, ROCK_PIECE):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			var parts := []
			for i in range(ci, mini(ci + ROCK_PIECE, nx)):
				for j in range(cj, mini(cj + ROCK_PIECE, nz)):
					var a: Vector3 = point.call(i, j)
					var b: Vector3 = point.call(i + 1, j)
					var c: Vector3 = point.call(i + 1, j + 1)
					var d: Vector3 = point.call(i, j + 1)
					var n := (b - a).cross(d - a).normalized()
					if n.y > 0.0:
						n = -n
					Batch.quad(st, a, b, c, d, n)
					var low := a.min(b).min(c).min(d)
					parts.append([Transform3D.IDENTITY, AABB(low, a.max(b).max(c).max(d) - low)])
			var mesh := MeshInstance3D.new()
			mesh.name = "RockCeiling"
			mesh.mesh = st.commit()
			mesh.material_override = colors["rock"]
			mesh.set_meta(&"parts", parts)
			mesh.add_to_group(GROUP)
			parent.add_child(mesh, true)
			last = mesh
	return last

## Lamps hung from the rock over each house on a chain, lighting the roof above the Ward; mist in two layers under the
## lowest deck; and the faint lit windows of houses far below. `anchors` where the rock is flat.
static func depths(view: Node3D, layout: Dictionary, roof: float, lo: Vector2, hi: Vector2, anchors: Array[Vector2]) -> Node3D:
	var colors: Dictionary = view.get("colors")
	var seed_value := int(view.get("seed_value"))
	var node := Node3D.new()
	node.name = "Depths"
	node.add_to_group(GROUP)
	view.add_child(node)
	var batch := Batch.new()
	var lowest := INF
	for site: Dictionary in layout.houses:
		lowest = minf(lowest, float(site.z))
		var x := float(site.x)
		var z := float(site.y)
		var rock := roof + rock_height(x, z, seed_value, anchors, lo, hi)
		var drop := 5.0 + float(posmod(int(site.id) * 3 + seed_value, 4))
		var bulb := Vector3(x, rock - drop, z)
		batch.beam("cable", bulb + Vector3.UP * 0.2, Vector3(x, rock + 0.3, z), 0.03, 0.03)
		# A wide iron shade over a big lamp, lit, so it reads from the decks below as a lamp and not a star.
		batch.box("iron", Transform3D(Basis.IDENTITY, bulb + Vector3.UP * 0.32), Vector3(0.7, 0.08, 0.7))
		batch.box("iron", Transform3D(Basis.IDENTITY, bulb + Vector3.UP * 0.24), Vector3(0.5, 0.1, 0.5))
		batch.box("bulb", Transform3D(Basis.IDENTITY, bulb), Vector3(0.3, 0.36, 0.3))
		batch.box("iron", Transform3D(Basis.IDENTITY, Vector3(x, rock + 0.02, z)), Vector3(0.5, 0.1, 0.5))
		var light := OmniLight3D.new()
		light.name = "RoofLamp%d" % int(site.id)
		light.light_color = Color("#ffbf7a")
		light.light_energy = 3.0
		light.omni_range = 14.0
		light.omni_attenuation = 1.4
		light.position = bulb - Vector3.UP * 0.2
		node.add_child(light)
	# Far below: small warm windows of houses nobody reaches, scattered by the seed.
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value * 7 + 101
	var centre := (lo + hi) * 0.5
	for k in 26:
		var at := Vector3(rng.randf_range(lo.x + 6.0, hi.x - 6.0), lowest - rng.randf_range(24.0, 60.0), rng.randf_range(lo.y + 6.0, hi.y - 6.0))
		var panes := 1 + rng.randi_range(0, 2)
		for w in panes:
			batch.box("far_light", Transform3D(Basis.IDENTITY, at + Vector3(w * 0.9, 0, 0)), Vector3(0.45, 0.6, 0.45))
	batch.commit(node, "Fixtures", colors)
	var radius := maxf(hi.x - lo.x, hi.y - lo.y) * 0.5
	for layer: Array in [[lowest - 7.0, 0.32], [lowest - 15.0, 0.45]]:
		var mist := MeshInstance3D.new()
		mist.name = "Mist"
		var plane := PlaneMesh.new()
		plane.size = hi - lo
		mist.mesh = plane
		var material := (colors["mist"] as ShaderMaterial).duplicate() as ShaderMaterial
		material.set_shader_parameter("strength", layer[1])
		material.set_shader_parameter("centre", centre)
		material.set_shader_parameter("radius", radius)
		mist.material_override = material
		mist.position = Vector3(centre.x, float(layer[0]), centre.y)
		mist.add_to_group(GROUP)
		node.add_child(mist)
	return node
