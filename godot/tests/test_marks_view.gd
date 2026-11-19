extends RefCounted

const T = preload("res://tests/t.gd")
const MarksView = preload("res://client/marks_view.gd")
const MarkPeel = preload("res://client/mark_peel.gd")
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

func test_a_peel_requires_a_fresh_continuous_second_on_one_mark(t: T) -> void:
	var hold := MarkPeel.new()
	t.eq(hold.advance(4, true, 500), -1, "arriving with F already held cannot start a peel")
	hold.begin(4, 500)
	t.eq(hold.advance(4, true, 1499), -1, "one millisecond short cannot peel")
	t.check(hold.fill > 0.9, "the progress follows the current hold")
	t.eq(hold.advance(4, true, 1500), 4, "the full authored second submits its exact mark once")
	t.eq(hold.advance(4, true, 3500), -1, "continuing to hold does not submit again")
	for cancelled: Array in [[4, false], [5, true], [-1, true]]:
		hold.begin(4, 4100)
		t.eq(hold.advance(int(cancelled[0]), bool(cancelled[1]), 4300), -1, "releasing, looking off or losing priority cancels")
		t.eq(hold.advance(4, true, 5600), -1, "returning to that arrow while still holding never restarts")
	t.eq(hold.fill, -1.0, "cancel clears the bar")

func test_a_peel_needs_nearby_visible_host_paper_on_this_storey(t: T) -> void:
	var view := MarksView.new()
	var plan := Places.generate("annex-peel-view", 3, Places.FULL)
	var at := Move.body_at_cell(plan, plan.landing)
	var mark := {"id": 7, "x": at.x, "z": at.z, "level": at.level, "dir": 2, "player": "c1"}
	view.show_marks([mark], plan, {})
	var feet := Vector3(at.x + 0.55, at.y, at.z)
	var eye := feet + Vector3.UP * 1.65
	var toward := (Vector3(at.x, at.y + 0.025, at.z) - eye).normalized()
	t.eq(view.peel_target([mark], plan, feet, eye, toward, at.level), 7, "facing a near host arrow selects its ID")
	t.eq(view.peel_target([mark], plan, feet, eye, -toward, at.level), -1, "facing away selects nothing")
	t.eq(view.peel_target([mark], plan, feet + Vector3.RIGHT * 1.6, eye, toward, at.level), -1, "the camera cannot pick a mark outside feet reach")
	t.eq(view.peel_target([mark], plan, feet, eye, toward, 1 - at.level), -1, "another storey selects nothing")
	view.show_marks([], plan, {})
	t.eq(view.peel_target([mark], plan, feet, eye, toward, at.level), -1, "a removed arrow is gone, even for a stale held target")
	view.free()
