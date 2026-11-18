extends SceneTree

const LiftScript = preload("res://client/lift.gd")

func _initialize() -> void:
	var car := {
		"width": 4.0, "depth": 4.0, "doorWidth": 1.8, "doorX": 1.0, "floorY": 0.0,
		"doorZ": 1.0, "rightX": 1.0, "rightZ": 0.0, "inX": 0.0, "inZ": -1.0,
	}
	var lift := LiftScript.new()
	lift.build(car)
	var sill := lift.get_node_or_null("MetalSill") as MeshInstance3D
	if not sill:
		push_error("lift is missing MetalSill")
		lift.free()
		quit(1)
		return
	var plate := sill.mesh as PlaneMesh
	var mat := sill.material_override as StandardMaterial3D
	var dims := is_equal_approx(plate.size.x, 1.8) and is_equal_approx(plate.size.y, LiftScript.LAND + LiftScript.FRONT)
	var spans_door := is_equal_approx(sill.position.z + plate.size.y * 0.5, LiftScript.LAND)
	var mats := mat.normal_enabled and mat.normal_texture.get_image().has_mipmaps() and mat.albedo_texture.get_image().has_mipmaps()
	var drawn: Dictionary = lift.drawn_car()
	var bank: AABB = drawn.bank
	var down: AABB = drawn.down
	var vote_panels := is_equal_approx(bank.size.x, 2.0) and is_equal_approx(down.size.x, 2.0)
	var clear := sill.get_child_count() == 0 and mat.albedo_texture.get_width() <= 256
	var tris := plate.get_faces().size() / 3.0
	print("sill dims=%s landing=%s mipmaps=%s vote panels=%s visual only=%s triangles=%s" % [dims, spans_door, mats, vote_panels, clear, tris])
	lift.free()
	quit(0 if dims and spans_door and mats and vote_panels and clear and tris == 2 else 1)
