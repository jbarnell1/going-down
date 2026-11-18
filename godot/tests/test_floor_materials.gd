extends RefCounted

const T = preload("res://tests/t.gd")
const Annex = preload("res://client/annex_view.gd")
const Clinic = preload("res://sim/clinic.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const Playroom = preload("res://client/playroom_view.gd")
const PrisonView = preload("res://client/prison_view.gd")
const Run = preload("res://sim/run.gd")

func test_clinic_tile_wear_is_floor_only(t: T) -> void:
	var level := Level.new()
	level._make_materials()
	t.eq(level.mat_floor.get_shader_parameter("tile_wear"), 1.0, "the Clinic's tiles use the wear pass")
	t.eq(level.mat_wall.get_shader_parameter("tile_wear"), null, "wall paint keeps the material's default")
	t.eq(level.mat_ceiling.get_shader_parameter("tile_wear"), null, "ceiling tiles keep the material's default")
	level.free()

func test_clinic_bumper_returns_to_the_wall_at_the_opening(t: T) -> void:
	var level := Level.new()
	level._clinic_bumper(0, Vector3.ZERO, Vector3(1.0, 0, 0), Vector3.BACK, true, true, 0.0)
	var mesh := level._st(0, 0.5, 0.0, "bumper").commit_to_arrays()
	var points: PackedVector3Array = mesh[Mesh.ARRAY_VERTEX]
	var deepest := -INF
	var inside := true
	var flush := true
	for p in points:
		inside = inside and p.x >= 0.0 and p.x <= 1.0
		if is_zero_approx(p.x) or is_equal_approx(p.x, 1.0):
			flush = flush and p.z < 0.074
		deepest = maxf(deepest, p.z)
	t.check(inside, "the bumper never crosses the edge of the solid wall")
	t.check(flush, "the rail returns flush at its rounded end")
	t.check(deepest > 0.10, "the middle of the bumper has actual relief")
	level.free()

func test_clinic_bumpers_are_only_drawn_in_the_clinic(t: T) -> void:
	var plan := Clinic.generate_clinic("bumper-dressing", 1)
	var clinic := Level.new()
	clinic.build(PlanDump.dump(plan, Run.car_geometry(plan)), "bumper-dressing")
	var prison := Level.new()
	prison.build(PrisonView.plain_plan(), "prison")
	t.check(_has_bumpers(clinic), "the Clinic draws bed bumpers on its walls")
	t.check(not _has_bumpers(prison), "the prison keeps its painted concrete walls")
	clinic.free()
	prison.free()

func _has_bumpers(level: Level) -> bool:
	for child in level.get_children():
		if child is MeshInstance3D and String(child.name).ends_with("_bumper"):
			return true
	return false

func test_annex_carpet_has_the_same_pile_on_floor_and_stairs(t: T) -> void:
	var level := Level.new()
	var annex := Annex.new()
	annex.lv = level
	annex._materials()
	var carpet: Texture2D = annex.mat_floor.get_shader_parameter("albedo_tex")
	t.check(carpet == annex.mat_stair.get_shader_parameter("albedo_tex"), "every Annex floor and stair shares one carpet")
	var img := carpet.get_image()
	t.check(img.has_mipmaps(), "the carpet filters to its base colour in the distance")
	var root := 0.0
	var crown := 0.0
	for row in range(0, img.get_height(), 4):
		for x in img.get_width():
			root += img.get_pixel(x, row).r
			crown += img.get_pixel(x, row + 2).r
	t.check((crown - root) / (img.get_width() * img.get_height() / 4.0) > 0.045, "raised loops read above their roots")
	level.free()

func test_playroom_padding_has_rounded_seams(t: T) -> void:
	var mats := Playroom.mat_tex().get_image()
	t.check(mats.has_mipmaps(), "the mats filter their edges in the distance")
	if not t.check(mats.get_size() == Vector2i(128, 128), "one repeating texture shows four pads"):
		return
	var corner := mats.get_pixel(2, 2).r
	var seam := mats.get_pixel(32, 2).r
	var inside := mats.get_pixel(32, 32).r
	t.check(seam - corner > 0.12, "the rounded corner leaves more gap than a straight seam")
	t.check(inside - seam > 0.24, "the raised vinyl top stays clear of the joint")

func test_party_drape_folds_inside_the_existing_skirt(t: T) -> void:
	var level := Level.new()
	var view := Playroom.new()
	view.lv = level
	view._tablecloth_edge(0, Transform3D.IDENTITY, Vector3.BACK, 1.3, 0.55, 0.56, 0.1)
	var st := level._st(0, 0.0, 0.0, "pprops")
	var arrays := st.commit_to_arrays()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var inset := INF
	var outset := -INF
	var bottom := INF
	for p in vertices:
		bottom = minf(bottom, p.y)
		if p.y < 0.2:
			inset = minf(inset, p.z)
			outset = maxf(outset, p.z)
	t.check(inset >= 0.55 and outset <= 0.59, "the hem keeps the original tabletop footprint")
	t.check(outset - inset > 0.027, "the hem folds instead of dropping straight down")
	t.check(bottom >= 0.0999, "the raised hem preserves the view from the hide")
	view.free()
	level.free()

func test_downloaded_surfaces_are_mipmapped_at_tape_resolution(t: T) -> void:
	var level := Level.new()
	level._make_materials()
	var clinic: Texture2D = level.mat_floor.get_shader_parameter("albedo_tex")
	var prison := PrisonView.new()
	var concrete: Texture2D = prison._surface(1.0).get_shader_parameter("concrete_tex")
	_check_surface(t, clinic, "clinic_linoleum", Vector2i(128, 128))
	_check_surface(t, Annex.carpet_tex(), "annex_carpet", Vector2i(128, 128))
	_check_surface(t, Playroom.wall_tex(), "playroom_padding", Vector2i(64, 128))
	_check_surface(t, Playroom.mat_tex(), "playroom_mats", Vector2i(128, 128))
	_check_surface(t, concrete, "prison_concrete", Vector2i(128, 128))
	level.free()

func _check_surface(t: T, tex: Texture2D, name: String, size: Vector2i) -> void:
	if not t.check(tex != null, name + " is assigned"):
		return
	t.eq(tex.resource_path, "res://assets/textures/" + name + ".png", name + " uses the baked texture")
	t.eq(tex.get_image().get_size(), size, name + " stays within its texture budget")
	t.check(tex.get_image().has_mipmaps(), name + " filters at a distance")
