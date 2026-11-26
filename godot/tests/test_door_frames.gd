extends RefCounted
## LA1: door frames on the plain doorways of the Clinic, the Annex, the Reactor and the Prison (looks only). Every
## plain doorway gets a frame on each face; the frame leaves the opening exactly as wide and high as the rules'; it is
## drawing only (no solids); the same plan draws the same frames.

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Clinic = preload("res://sim/clinic.gd")
const AnnexPlan = preload("res://sim/annex.gd")
const Station = preload("res://sim/station.gd")
const PrisonView = preload("res://client/prison_view.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const Frames = preload("res://client/door_frames.gd")

static func _built(fp: Variant) -> Level:
	var level := Level.new()
	level.build(PlanDump.dump(fp, Run.car_geometry(fp)), fp.seed, fp)
	return level

static func _prison() -> Level:
	var level := Level.new()
	level.build(PrisonView.plain_plan(), "prison")
	return level

## The floors checked: [name, level].
static func _floors(quick: bool) -> Array:
	var out: Array = []
	for i in (2 if quick else 5):
		out.append(["the Clinic la1-%d/1" % i, _built(Clinic.generate_clinic("la1-%d" % i, 1))])
		out.append(["the Clinic la1-%d/3" % i, _built(Clinic.generate_clinic("la1-%d" % i, 3))])
		out.append(["the Annex la1-%d" % i, _built(AnnexPlan.generate_annex("la1-%d" % i, 3))])
		out.append(["the Reactor la1-%d" % i, _built(Station.generate_station("la1-%d" % i, 7))])
	out.append(["the Prison", _prison()])
	return out

static func _free(floors: Array) -> void:
	for f: Array in floors:
		(f[1] as Node).free()

## The plain doorways of a drawn floor: every "door" edge but the lift's, less the Prison's own framed ones.
static func plain_doorways(lv: Level) -> Array[String]:
	var out: Array[String] = []
	var lift := lv._lift_edge()
	var prison: Variant = lv.get_meta(&"prison") if lv.has_meta(&"prison") else null
	for level in 2:
		var vert: Array = lv.edges[level].vertical
		var hor: Array = lv.edges[level].horizontal
		for y in lv.H:
			for x in lv.W + 1:
				if vert[y * (lv.W + 1) + x] == "door" and not (level == lv.landing.x and lift == Vector4i(0, x, y, 1)):
					if prison == null or not bool(prison.call(&"_framed_here", level, Vector2i(x - 1, y), Vector2i(x, y))):
						out.append("%d:%s-%s" % [level, Vector2i(x - 1, y), Vector2i(x, y)])
		for y in lv.H + 1:
			for x in lv.W:
				if hor[y * lv.W + x] == "door" and not (level == lv.landing.x and lift == Vector4i(1, x, y, 1)):
					if prison == null or not bool(prison.call(&"_framed_here", level, Vector2i(x, y - 1), Vector2i(x, y))):
						out.append("%d:%s-%s" % [level, Vector2i(x, y - 1), Vector2i(x, y)])
	return out

## The frame meshes of a floor, with their triangles in level space.
static func frame_meshes(lv: Level) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for c in lv.get_children():
		if c is MeshInstance3D and String(c.name).ends_with("_dframe"):
			out.append(c)
	return out

static func _tris(mi: MeshInstance3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	var arr := mi.mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	for k in idx:
		out.append(mi.transform * v[k])
	return out

func test_every_plain_doorway_has_a_frame(t: T) -> void:
	var floors := _floors(t.quick)
	for f: Array in floors:
		var lv: Level = f[1]
		var want := plain_doorways(lv)
		var got: Array[String] = []
		var faces := 0
		for d: Dictionary in lv.get_meta(&"door_frames", []):
			got.append("%d:%s-%s" % [d.level, d.a, d.b])
			faces += (d.faces as Array).size()
			t.check((d.faces as Array).size() == 2, "%s: the doorway %s-%s is framed on both faces (%d)" % [f[0], d.a, d.b, (d.faces as Array).size()])
		want.sort()
		got.sort()
		t.check(want.size() > 0, "%s has plain doorways" % f[0])
		t.eq(got, want, "%s: the framed doorways are the plain doorways" % f[0])
		var meshes := frame_meshes(lv)
		t.check(meshes.size() > 0 and meshes.size() <= 2 * ceili(lv.W / float(Level.CHUNK)) * ceili(lv.H / float(Level.CHUNK)),
			"%s: the frames are merged into a few meshes (%d)" % [f[0], meshes.size()])
		var mats := {}
		for mi in meshes:
			mats[mi.material_override] = true
			t.check(mi.get_child_count() == 0, "%s: %s is drawing only, nothing under it" % [f[0], mi.name])
		t.eq(mats.size(), 1, "%s: one material for every frame" % f[0])
		t.note("%s: %d doorways, %d faces framed, %d meshes, %d material" % [f[0], got.size(), faces, meshes.size(), mats.size()])
	_free(floors)

## No part of a frame comes into the opening (the rules' DOOR_W wide, DOOR_H high, through the wall and half a metre
## out on each side), and each frame stands on its wall face around the opening.
func test_frames_leave_the_opening_clear(t: T) -> void:
	var floors := _floors(t.quick)
	var h := Level.DOOR_W * 0.5
	for f: Array in floors:
		var lv: Level = f[1]
		var openings: Array = []
		for d: Dictionary in lv.get_meta(&"door_frames", []):
			var along: Vector3 = d.along
			var n := Vector3(along.z, 0, along.x).abs()
			var mid: Vector3 = (d.mid as Vector3) + Vector3(0, int(d.level) * Level.LH, 0)
			var lo := mid - along * h - n * 0.6
			openings.append(AABB(lo + Vector3(0, 0.0, 0), along * (2.0 * h) + n * 1.2 + Vector3(0, Level.DOOR_H, 0)).grow(-1e-4))
		var inside := 0
		var off_wall := 0
		var tris := 0
		for mi in frame_meshes(lv):
			var pts := _tris(mi)
			tris += pts.size() / 3
			for p in pts:
				for o: AABB in openings:
					if o.has_point(p):
						inside += 1
				# Every corner is on a frame: within PROUD of a wall line and at most a jamb's width outside an opening.
			for k in range(0, pts.size(), 3):
				var c := (pts[k] + pts[k + 1] + pts[k + 2]) / 3.0
				var near := false
				for o: AABB in openings:
					if o.grow(Frames.JAMB_W + 0.01).has_point(c):
						near = true
						break
				if not near:
					off_wall += 1
		t.eq(inside, 0, "%s: frame corners inside an opening" % f[0])
		t.eq(off_wall, 0, "%s: frame triangles away from any doorway" % f[0])
		t.note("%s: %d frame triangles" % [f[0], tris])
	_free(floors)

## The frame stands a few centimetres proud of the wall face round the opening: its jambs' inner edges are the
## opening's edges and its head is at the opening's top.
func test_a_frame_is_jambs_and_a_head_round_the_opening(t: T) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	Frames._frame(st, Vector3.ZERO, Vector3(1, 0, 0), Vector3(0, 0, 1), Color.WHITE)
	var v: PackedVector3Array = st.commit_to_arrays()[Mesh.ARRAY_VERTEX]
	var box := AABB(v[0], Vector3.ZERO)
	var inner := INF
	for p in v:
		box = box.expand(p)
		if p.y < Level.DOOR_H - 0.01:
			inner = minf(inner, absf(p.x))
	t.check(is_equal_approx(inner, Level.DOOR_W * 0.5), "the jambs' inner edges are the opening's edges (%.4f, want %.4f)" % [inner, Level.DOOR_W * 0.5])
	t.check(is_equal_approx(box.end.y, Level.DOOR_H + Frames.HEAD_H) and box.position.y > 0.0, "the head sits on the opening's top: %s" % box)
	var proud := box.end.z - Level.WALL_T * 0.5
	t.check(proud >= 0.03 and proud <= 0.06 and box.position.z > Level.WALL_T * 0.5, "it stands %.3f m proud of the wall face, off it" % proud)
	t.check(is_equal_approx(box.size.x, Level.DOOR_W + 2.0 * Frames.JAMB_W), "two jambs and a head across (%.3f m)" % box.size.x)

## A piece of furniture hard against the wall beside a doorway: the jamb on its side stands only as proud as the gap
## left, or is left out where there is none; the other jamb and the head are whole. (No generated floor checked here
## has such a piece today; this keeps a future one from being run through.)
func test_a_jamb_gives_way_to_furniture(t: T) -> void:
	var h := Level.DOOR_W * 0.5
	var face := Level.WALL_T * 0.5
	for c: Array in [["a gap of 3 cm", face + 0.03, 1], ["no gap", face + 0.004, 0]]:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		# Wall along x through the origin, this face toward +z; a cabinet from x = h + 0.02 on, starting c[1] out.
		var cab := Rect2(Vector2(h + 0.02, float(c[1])), Vector2(0.6, 0.5))
		Frames._frame(st, Vector3.ZERO, Vector3(1, 0, 0), Vector3(0, 0, 1), Color.WHITE, [cab])
		var v: PackedVector3Array = st.commit_to_arrays()[Mesh.ARRAY_VERTEX]
		var right_reach := 0.0
		var right_low := 0
		var left_reach := 0.0
		for p in v:
			if p.y < 1.0 and p.x > 0.0:
				right_low += 1
				right_reach = maxf(right_reach, p.z)
			if p.y < 1.0 and p.x < 0.0:
				left_reach = maxf(left_reach, p.z)
		if int(c[2]) == 1:
			t.check(right_low > 0 and right_reach < float(c[1]), "%s: the jamb beside it stays clear of it (to %.3f, the piece at %.3f)" % [c[0], right_reach, c[1]])
		else:
			t.eq(right_low, 0, "%s: the jamb beside it is left out" % c[0])
		t.check(is_equal_approx(left_reach, face + Frames.PROUD), "%s: the other jamb is whole (%.3f)" % [c[0], left_reach])

## The same plan draws the same frames on every screen.
func test_the_same_plan_draws_the_same_frames(t: T) -> void:
	for mk: Callable in [func() -> Level: return _built(Clinic.generate_clinic("la1-same", 2)), func() -> Level: return _built(AnnexPlan.generate_annex("la1-same", 3))]:
		var a: Level = mk.call()
		var b: Level = mk.call()
		var ha := PackedStringArray()
		var hb := PackedStringArray()
		for mi in frame_meshes(a):
			ha.append("%s:%s" % [mi.name, str(_tris(mi)).md5_text()])
		for mi in frame_meshes(b):
			hb.append("%s:%s" % [mi.name, str(_tris(mi)).md5_text()])
		t.check(not ha.is_empty() and ha == hb, "two builds of one plan draw identical frames")
		a.free()
		b.free()

## A frame never runs into a piece of the rules' furniture (a cabinet or a bed beside a doorway).
func test_frames_keep_off_the_furniture(t: T) -> void:
	var floors := _floors(t.quick)
	for f: Array in floors:
		var lv: Level = f[1]
		var clash := PackedStringArray()
		var level_of := {}
		for pc in lv.pieces:
			level_of[pc.id] = pc.level
		for mi in frame_meshes(lv):
			var pts := _tris(mi)
			for p in pts:
				var storey := 1 if p.y > Level.LH - 0.5 else 0
				for d: Dictionary in lv.furniture_drawn:
					var r: Rect2 = d.rect
					if int(level_of.get(d.piece, 0)) == storey and r.grow(-0.005).has_point(Vector2(p.x, p.z)) and p.y - storey * Level.LH < 2.0:
						clash.append("%s at %s" % [d.kind, p])
		t.check(clash.is_empty(), "%s: frame corners inside furniture: %s" % [f[0], ", ".join(clash.slice(0, 4))])
	_free(floors)
