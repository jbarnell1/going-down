# Fern 02 (Poly Haven, CC0). Three cropped fronds from the source atlas on a shared low-poly clump.
extends RefCounted

const Arboretum = preload("res://sim/arboretum.gd")
const Floor = preload("res://sim/floor.gd")
const Noises = preload("res://sim/noise.gd")
const ATLAS = preload("res://assets/arboretum/fern_02.webp")
const MAX_CLUMPS := 40
const EDGE_DIRS: Array[Vector2i] = [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]
const FRONDS := 8
const SEGMENTS := 3

static func dress(parent: Node3D, plan: Floor.FloorPlan, garden: Arboretum.Garden) -> int:
	var sites := _placements(plan, garden)
	if sites.is_empty():
		return 0
	var batch := MultiMesh.new()
	batch.transform_format = MultiMesh.TRANSFORM_3D
	batch.mesh = _clump()
	batch.instance_count = sites.size()
	for i in sites.size():
		batch.set_instance_transform(i, sites[i])
	var view := MultiMeshInstance3D.new()
	view.name = "FernClumps"
	view.multimesh = batch
	view.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(view)
	return sites.size()

static func _placements(plan: Floor.FloorPlan, garden: Arboretum.Garden) -> Array[Transform3D]:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("fern_02:%s:%s" % [plan.seed, plan.depth])
	var sites: Array[Transform3D] = []
	var cell_size := float(plan.cell_size)
	for z in range(1, Arboretum.H - 1):
		for x in range(1, Arboretum.W - 1):
			if garden.surface(x, z) != Noises.MOSS or Floor.cell_at(plan, 0, x, z) != Floor.CORRIDOR:
				continue
			for edge: Vector2i in EDGE_DIRS:
				if garden.thicket[(z + edge.y) * Arboretum.W + x + edge.x] == 0:
					continue
				var center := Vector2(x + 0.5, z + 0.5) * cell_size
				center += Vector2(edge) * (cell_size * 0.28)
				center += Vector2(-edge.y, edge.x) * rng.randf_range(-0.4, 0.4)
				var size := rng.randf_range(0.8, 1.25)
				var turn := Basis(Vector3.UP, rng.randf_range(0.0, TAU)).scaled(Vector3.ONE * size)
				sites.append(Transform3D(turn, Vector3(center.x, 0.012, center.y)))
				break

	# Shuffle with the floor's seeded RNG so the budget is spread over the floor.
	var count := mini(MAX_CLUMPS, sites.size())
	for i in count:
		var j := rng.randi_range(i, sites.size() - 1)
		var site := sites[i]
		sites[i] = sites[j]
		sites[j] = site
	sites.resize(count)
	return sites

static func _clump() -> ArrayMesh:
	var material := StandardMaterial3D.new()
	material.albedo_texture = ATLAS
	material.albedo_color = Color(0.77, 0.88, 0.66)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	material.alpha_scissor_threshold = 0.36
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	material.roughness = 0.9

	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_material(material)
	for frond in FRONDS:
		var angle := TAU * float(frond) / FRONDS
		var along := Vector3(cos(angle), 0, sin(angle))
		var across := Vector3(-along.z, 0, along.x)
		var length := 0.44 + 0.17 * float(frond % 3) / 2.0
		var height := 0.21 + 0.16 * float((frond + 1) % 3) / 2.0
		var width := length * 0.12
		var u0 := float((frond % 3) * 42 + 2) / 128.0
		var u1 := u0 + 38.0 / 128.0
		for seg in SEGMENTS:
			var t0 := float(seg) / SEGMENTS
			var t1 := float(seg + 1) / SEGMENTS
			var p0 := along * length * t0 + Vector3.UP * height * sin(t0 * 2.1)
			var p1 := along * length * t1 + Vector3.UP * height * sin(t1 * 2.1)
			var v0 := lerpf(254.0 / 256.0, 2.0 / 256.0, t0)
			var v1 := lerpf(254.0 / 256.0, 2.0 / 256.0, t1)
			var positions: Array[Vector3] = [p0 - across * width, p1 - across * width, p1 + across * width, p0 + across * width]
			var uv: Array[Vector2] = [Vector2(u0, v0), Vector2(u0, v1), Vector2(u1, v1), Vector2(u1, v0)]
			for index: int in [0, 1, 2, 0, 2, 3]:
				surface.set_normal(Vector3.UP)
				surface.set_uv(uv[index])
				surface.add_vertex(positions[index])
	surface.index()
	return surface.commit()
