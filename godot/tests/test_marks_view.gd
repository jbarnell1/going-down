extends RefCounted

const T = preload("res://tests/t.gd")
const MarksView = preload("res://client/marks_view.gd")
const Places = preload("res://sim/places.gd")
const Move = preload("res://sim/move.gd")

func test_only_host_marks_are_drawn_at_the_recorded_pose(t: T) -> void:
	var view := MarksView.new()
	var plan := Places.generate("annex-mark-view", 3, Places.FULL)
	var at := Move.body_at_cell(plan, plan.landing)
	var owners := {"c1": "ANN", "c2": "BOB"}
	view.show_marks([], plan, owners)
	t.check(view.arrows.is_empty(), "an empty host snapshot draws no mark")
	var rows := [{"id": 1, "x": at.x, "z": at.z, "level": at.level, "dir": 2, "player": "c1"},
		{"id": 2, "x": at.x + 0.5, "z": at.z, "level": at.level, "dir": 4, "player": "c2"}]
	view.show_marks(rows, plan, owners)
	t.eq(view.arrows.size(), 2, "both host stamps draw on the floor")
	if view.arrows.size() == 2:
		var first := view.arrows[1] as MeshInstance3D
		var second := view.arrows[2] as MeshInstance3D
		t.check(first.position.is_equal_approx(Vector3(at.x, at.y + 0.025, at.z)), "the paper rests just above the exact host position")
		t.check(first.basis.y.is_equal_approx(Vector3.LEFT) and second.basis.y.is_equal_approx(Vector3.BACK), "the two tips follow exactly the host's snapped directions")
		var mat_a := first.material_override as StandardMaterial3D
		var mat_b := second.material_override as StandardMaterial3D
		t.check(mat_a.albedo_texture.get_image().get_pixel(32, 30) != mat_b.albedo_texture.get_image().get_pixel(32, 30), "the placers get separate visible inks")
		t.check(mat_a.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED, "the physical arrow can still be read in a blackout")
	view.show_marks([rows[1]], plan, owners)
	t.check(not view.arrows.has(1) and view.arrows.has(2), "the arrow disappears when the authoritative row is removed")
	view.free()
