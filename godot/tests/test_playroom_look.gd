extends RefCounted
## The Playroom's look pass (PR1, 21 Nov 2026): the Meshy slide and soft-play tower and the CC0 photographs.
## Dressing only: the scene builds with them, the same seed draws the same pieces, and no piece stands on a
## hide, a hide's front, a squeaker or a door, or changes a walkable cell, a hide or a sign.

const T = preload("res://tests/t.gd")
const Playroom = preload("res://sim/playroom.gd")
const Floor = preload("res://sim/floor.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const Run = preload("res://sim/run.gd")
const View = preload("res://client/playroom_view.gd")

const SEEDS: Array[String] = ["arrival-a", "arrival-b", "look-1", "look-2", "look-3", "look-4"]

func _build(seed: String, props: bool) -> Level:
	var plan := Playroom.generate_playroom(seed, 4)
	var level := Level.new()
	level.props_on = props
	level.build(PlanDump.dump(plan, Run.car_geometry(plan)), seed, plan)
	return level

func _walk(level: Level) -> PackedByteArray:
	var out := PackedByteArray()
	for l in 2:
		for y in level.H:
			for x in level.W:
				out.append(1 if level.walkable(l, x, y) else 0)
	return out

func test_pieces_are_dressing_only(t: T) -> void:
	var total := 0
	var total_murals := 0
	for seed in SEEDS:
		var with := _build(seed, true)
		var bare := _build(seed, false)
		var v: Node = with.get_meta("playroom")
		var b: Node = bare.get_meta("playroom")
		var stats := {}
		t.eq(v.call("check", stats), [] as Array[String], "%s: every hide, squeaker and sign is as the rules say with the pieces in" % seed)
		t.eq(_walk(with), _walk(bare), "%s: the pieces change no walkable cell" % seed)
		t.eq(v.get("furniture"), b.get("furniture"), "%s: the hides' furniture is the same with and without the pieces" % seed)
		var hides: Array = v.get("hides")
		var blocked := {}
		for h: Playroom.Hide in hides:
			blocked[Vector3i(h.level, h.inside.x / 200, h.inside.y / 200)] = "hide %d" % h.id
			blocked[Vector3i(h.level, h.front.x / 200, h.front.y / 200)] = "the front of hide %d" % h.id
		var fp: Floor.FloorPlan = v.get("fp")
		for idx: int in v.get("squeak"):
			var c: Vector3i = v.call("_cell_of", idx)
			blocked[c] = "a squeaker"
		for d: Floor.Door in fp.doors:
			blocked[Vector3i(d.level, d.ax, d.ay)] = "a door"
			blocked[Vector3i(d.level, d.bx, d.by)] = "a door"
		var pieces: Array = v.get("pieces")
		total += pieces.size()
		t.check(pieces.size() <= View.MAX_PIECES, "%s: %d pieces, at most %d (frame rate)" % [seed, pieces.size(), View.MAX_PIECES])
		var cells := {}
		for p: Dictionary in pieces:
			var under: Array = p.cells
			t.check(under.has(p.cell), "%s: a %s's footprint holds its own cell" % [seed, p.kind])
			var pos: Vector3 = p.pos
			var inside := false
			for cell: Vector2i in under:
				var key := Vector3i(int(p.level), cell.x, cell.y)
				t.check(not blocked.has(key), "%s: a %s stands on %s at %s" % [seed, p.kind, blocked.get(key, ""), key])
				t.check(not cells.has(key), "%s: two pieces over cell %s" % [seed, key])
				cells[key] = true
				t.check(with.walkable(int(p.level), cell.x, cell.y), "%s: a %s stands over walkable cells only" % [seed, p.kind])
				var mid := with.cell_center(int(p.level), cell.x, cell.y)
				inside = inside or (absf(pos.x - mid.x) <= 1.0 and absf(pos.z - mid.z) <= 1.0)
			t.check(inside, "%s: a %s's middle is over its footprint" % [seed, p.kind])
			# Its drawn size fits the cells it was given (the footprint is whole cells around the piece).
			var spec: Array = View.PIECES[StringName(p.kind)]
			var long := float(spec[3])
			var deep := float(spec[2])
			var xs: Array = under.map(func(c: Vector2i) -> int: return c.x)
			var zs: Array = under.map(func(c: Vector2i) -> int: return c.y)
			var span := Vector2((xs.max() - xs.min() + 1) * 2.0, (zs.max() - zs.min() + 1) * 2.0)
			var f: Vector3 = p.facing
			var need := Vector2(deep if absf(f.x) > 0.5 else long, long if absf(f.x) > 0.5 else deep)
			t.check(span.x + 0.11 >= need.x and span.y + 0.11 >= need.y, "%s: a %s (%.2f by %.2f m) fits the %s m of cells under it" % [seed, p.kind, need.x, need.y, span])
			t.check(float(spec[1]) * (2.3 if p.kind == "frame" else 2.0) >= 2.6, "%s: a %s stands at least 2.6 m tall" % [seed, p.kind])
		# The same seed draws the same pieces, every time.
		var again := _build(seed, true)
		t.eq(str((again.get_meta("playroom") as Node).get("pieces")), str(pieces), "%s: the pieces come from the seed" % seed)
		var murals: Array = v.get("murals")
		t.eq(str((again.get_meta("playroom") as Node).get("murals")), str(murals), "%s: the murals come from the seed" % seed)
		total_murals += murals.size()
		for m: Dictionary in murals:
			var mp: Vector3 = m.pos
			t.check(mp.y - int(m.level) * View.LH - View.MURAL_H * 0.5 >= 1.15, "%s: a mural starts above the padding" % seed)
		var children := 0
		for c in with.get_children():
			if String(c.name).begins_with("Piece_"):
				children += 1
		t.eq(children, pieces.size(), "%s: every piece is drawn" % seed)
		with.free()
		bare.free()
		again.free()
	t.check(total >= SEEDS.size() * 2, "%d pieces over %d floors: the slides and towers are there" % [total, SEEDS.size()])
	t.check(total_murals >= SEEDS.size() * 2, "%d murals over %d floors" % [total_murals, SEEDS.size()])
	t.note("%d pieces and %d murals over %d floors" % [total, total_murals, SEEDS.size()])

func test_pieces_fit_the_budget(t: T) -> void:
	for kind: StringName in [&"slide", &"frame"]:
		var got := View.piece_mesh(kind)
		var mesh: Mesh = got[0]
		var tex: Texture2D = got[1]
		if not t.check(mesh != null and tex != null, "the %s loads with its colour map" % kind):
			continue
		var tris := 0
		for s in mesh.get_surface_count():
			tris += (mesh.surface_get_arrays(s)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		t.check(tris > 1000 and tris <= 15000, "the %s has %d triangles (at most 15,000)" % [kind, tris])
		t.eq(mesh.get_surface_count(), 1, "the %s is one material" % kind)
		t.check(tex.get_width() <= 1024 and tex.get_height() <= 1024, "the %s's map is at most 1024 px" % kind)

func test_photographs_are_on_the_surfaces(t: T) -> void:
	var level := _build("arrival-a", true)
	var v: Node = level.get_meta("playroom")
	var ceil: ShaderMaterial = v.get("mat_ceil")
	var wall: ShaderMaterial = v.get("mat_wall")
	t.eq(ceil.get_shader_parameter("photo"), 1.0, "the ceiling draws its CC0 tiles")
	t.check(ceil.get_shader_parameter("photo_tex") == View.CEILING_PHOTO, "the ceiling's photograph is the shipped one")
	t.check(float(wall.get_shader_parameter("detail_amt")) > 0.0 and float(wall.get_shader_parameter("grime_amt")) > 0.0, "the walls carry plaster and dirt")
	t.check(wall.get_shader_parameter("detail_tex") == View.PLASTER_PHOTO, "the walls' plaster is the shipped photograph")
	var lifted := 0
	for c in level.get_children():
		if String(c.name).begins_with("Piece_"):
			var m := (c as MeshInstance3D).material_override as ShaderMaterial
			if float(m.get_shader_parameter("photo_gain")) >= 2.0 and m.get_shader_parameter("photo_tex") != null:
				lifted += 1
	t.check(lifted > 0 and lifted == (v.get("pieces") as Array).size(), "every Meshy piece draws its colour map lifted to the floor's paint (%d)" % lifted)
	level.free()

## Lead C, 21 Nov: the Hanging Ward's second wallpaper read as a strong pink; it is pulled toward a dirty, faded
## rose (client/ward/ward_house.gdshader WARD_PAPER_ROSE): its channels within 0.1 of each other, none above 0.55.
func test_ward_rose_paper_is_faded(t: T) -> void:
	var text := FileAccess.get_file_as_string("res://client/ward/ward_house.gdshader")
	var at := text.find("const vec3 WARD_PAPER_ROSE = vec3(")
	if not t.check(at >= 0, "the Ward's rose paper colour is named in its shader"):
		return
	var inside := text.substr(at).get_slice("vec3(", 1).get_slice(")", 0)
	var c := Vector3(float(inside.get_slice(",", 0)), float(inside.get_slice(",", 1)), float(inside.get_slice(",", 2)))
	var spread := maxf(c.x, maxf(c.y, c.z)) - minf(c.x, minf(c.y, c.z))
	t.check(spread <= 0.1 and maxf(c.x, maxf(c.y, c.z)) <= 0.55, "the rose paper is faded: %s, spread %.2f" % [c, spread])
	t.check(text.contains("vec3(0.0), WARD_PAPER_ROSE)"), "the second wallpaper uses the faded rose")
