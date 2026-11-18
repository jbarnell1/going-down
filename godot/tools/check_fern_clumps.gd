extends SceneTree

const Arboretum = preload("res://sim/arboretum.gd")
const Ferns = preload("res://client/arboretum_ferns.gd")
const Noises = preload("res://sim/noise.gd")
const LevelScript = preload("res://client/level.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const Run = preload("res://sim/run.gd")

func _initialize() -> void:
	var ok := true
	for seed_: String in ["night", "seed-19", "fern-support", "23489"]:
		var plan := Arboretum.generate_arboretum(seed_, 5)
		var garden := Arboretum.garden_of(plan)
		var first := Node3D.new()
		var second := Node3D.new()
		var count := Ferns.dress(first, plan, garden)
		var count_again := Ferns.dress(second, plan, garden)
		var batch := first.get_node_or_null("FernClumps") as MultiMeshInstance3D
		var other := second.get_node_or_null("FernClumps") as MultiMeshInstance3D
		if batch == null or other == null:
			first.free()
			second.free()
			push_error("%s: no fern batch (%d clumps)" % [seed_, count])
			quit(1)
			return
		var shared := batch.multimesh.mesh
		var tris := shared.get_faces().size() / 3.0
		var sizes_ok := batch.multimesh.instance_count == count and count > 0 and count <= 40 and count == count_again and tris == 48
		var mat := shared.surface_get_material(0) as StandardMaterial3D
		var atlas_ok := mat.albedo_texture.get_size() == Vector2(128, 256) and mat.albedo_texture.get_image().has_mipmaps()
		var deterministic := true
		var moss := true
		var sites := Ferns._placements(plan, garden)
		var repeated := Ferns._placements(plan, garden)
		for i in count:
			var site := sites[i]
			deterministic = deterministic and site.is_equal_approx(repeated[i])
			moss = moss and garden.surface(floori(site.origin.x / plan.cell_size), floori(site.origin.z / plan.cell_size)) == Noises.MOSS
		var visual_only := first.get_child_count() == 1 and batch.get_child_count() == 0
		print("%s clumps=%d total tris=%d atlas=%s deterministic=%s moss=%s visual only=%s" % [seed_, count, count * tris, atlas_ok, deterministic, moss, visual_only])
		ok = ok and sizes_ok and atlas_ok and deterministic and moss and visual_only
		first.free()
		second.free()
	var plan := Arboretum.generate_arboretum("night", 5)
	var level := LevelScript.new()
	level.build(PlanDump.dump(plan, Run.car_geometry(plan)), plan.seed)
	var view := level.get_meta(&"arboretum") as Node3D
	var integrated := view != null and view.has_node("FernClumps")
	print("normal Level.build integrates fern clumps=%s" % integrated)
	level.free()
	quit(0 if ok and integrated else 1)
