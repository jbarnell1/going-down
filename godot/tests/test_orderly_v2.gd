# MO1: the Orderly's second model (assets/entities/orderly_v2.glb, from the Meshy figure; built by
# assets_src/blender/orderly/build_orderly_v2.py) stands in for today's. It is drawn unless the game is
# started with `figures=old` (client/figures.gd). These checks hold it to what the view needs: every clip today's
# model has, the same lengths; the bones the view drives; the same height and feet; today's motion checks
# (test_orderly_motion, among them the rule that no bone stretches); with no argument the new model is drawn, and
# with figures=old today's, unchanged.
extends RefCounted

const T = preload("res://tests/t.gd")
const View = preload("res://client/orderly_view.gd")
const Motion = preload("res://tests/test_orderly_motion.gd")

## Every bone the view turns, aims, folds or reads (orderly_view.gd), on both models.
const DRIVEN: Array[String] = ["hips", "spine", "spine1", "spine2", "neck", "head",
	"clavicle.L", "upperarm.L", "forearm.L", "hand.L", "thigh.L", "shin.L", "foot.L",
	"clavicle.R", "upperarm.R", "forearm.R", "hand.R", "thigh.R", "shin.R", "foot.R",
	"skirt.F.L", "skirt.F.R", "skirt.B.L", "skirt.B.R"]

func _view(figures: String) -> View:
	View.figures_override = figures
	var view := View.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(view)
	View.figures_override = ""
	return view

func test_the_new_model_has_every_clip_with_todays_lengths(t: T) -> void:
	var old_scene: Node = (load(View.MODEL) as PackedScene).instantiate()
	var new_scene: Node = (load(View.MODEL_V2) as PackedScene).instantiate()
	var old := old_scene.find_child("AnimationPlayer", true, false) as AnimationPlayer
	var new := new_scene.find_child("AnimationPlayer", true, false) as AnimationPlayer
	t.check(old != null and new != null, "both models carry clips")
	if old == null or new == null:
		old_scene.free()
		new_scene.free()
		return
	var names := Array(old.get_animation_list())
	t.check(names.size() >= 10, "today's model has its ten clips (%d)" % names.size())
	for n: String in names:
		t.check(new.has_animation(n), "the new model has the clip " + n)
		if new.has_animation(n):
			var a := old.get_animation(n).length
			var b := new.get_animation(n).length
			t.check(absf(a - b) < 0.05, "%s is %.3f s long, today's %.3f s" % [n, b, a])
	old_scene.free()
	new_scene.free()

func test_the_new_skeleton_has_the_bones_the_view_drives(t: T) -> void:
	var view := _view("new")
	t.check(view.figure_v2, "figures=new draws the new model")
	for bone: String in DRIVEN:
		t.check(view.skel.find_bone(bone) >= 0, "the new skeleton has " + bone)
	view.free()

## The skinned mesh's highest and lowest points in the view's own space, posed as the frame says.
func _extent(view: View, pose: Dictionary) -> Vector2:
	view.show_pose(pose, true)
	var sk := view.skel
	sk.force_update_all_bone_transforms()
	var top := -INF
	var low := INF
	for mi: MeshInstance3D in view.model.find_children("*", "MeshInstance3D", true, false):
		var skin := mi.skin
		var to_view := view.global_transform.affine_inverse() * sk.global_transform
		var arrays := mi.mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		var per := bones.size() / verts.size()
		var mats: Array[Transform3D] = []
		for b in skin.get_bind_count():
			var bone := skin.get_bind_bone(b)
			if bone < 0:
				bone = sk.find_bone(skin.get_bind_name(b))
			mats.append(sk.get_bone_global_pose(bone) * skin.get_bind_pose(b))
		for i in verts.size():
			var p := Vector3.ZERO
			for k in per:
				var w := weights[i * per + k]
				if w > 0.0:
					p += w * (mats[bones[i * per + k]] * verts[i])
			var y := (to_view * p).y
			top = maxf(top, y)
			low = minf(low, y)
	return Vector2(top, low)

func _pose(anim: String, t: float) -> Dictionary:
	return {"anim": anim, "animTime": t, "x": 0.0, "y": 0.0, "z": 0.0, "yaw": 0.0}

func test_the_new_model_stands_as_tall_as_todays_with_its_feet_on_the_floor(t: T) -> void:
	var old := _view("old")
	var new := _view("new")
	for frame: Dictionary in [_pose("idle", 0.0), _pose("walk", 0.0)]:
		var a := _extent(old, frame)
		var b := _extent(new, frame)
		t.note("%s: top %.3f / %.3f, lowest %.3f / %.3f (today's / new)" % [frame.anim, a.x, b.x, a.y, b.y])
		t.check(absf(a.x - b.x) < 0.02, "%s: the head is as high as today's (%.3f, today's %.3f)" % [frame.anim, b.x, a.x])
		t.check(absf(a.y - b.y) < 0.02, "%s: the feet are on the floor like today's (%.3f, today's %.3f)" % [frame.anim, b.y, a.y])
	for view: View in [old, new]:
		var bend := _pose("bend", 0.9)
		bend.catch_active = true
		view.show_pose(bend, true)
		view.skel.force_update_all_bone_transforms()
		var head := view.skel.get_bone_global_pose(view.skel.find_bone("head")).origin
		var top := _extent(view, bend).x
		t.note("%s bend at 0.9 s: head joint %s, top of the figure %.3f" % ["new" if view.figure_v2 else "today's", head, top])
	old.free()
	new.free()

## Today's motion checks, run again on the new model: the clips it plays, the bend over a crewmate with the
## head at a prone face and the feet planted, the door clearance, the trolley grip, and the arms and every
## bone keeping their length however long it walks or stands.
func test_todays_motion_checks_hold_on_the_new_model(t: T) -> void:
	var m := Motion.new()
	var ran := 0
	View.figures_override = "new"
	for method: Dictionary in m.get_method_list():
		var name: String = method.name
		if name.begins_with("test_") and not name.contains("breathing") and not name.contains("heard") \
				and not name.contains("prison_empty"):
			var before := t.failures.size()
			m.call(name, t)
			for i in range(before, t.failures.size()):
				t.failures[i] = "new model, %s: %s" % [name, t.failures[i]]
			ran += 1
	View.figures_override = ""
	t.check(ran >= 9, "today's motion checks ran on the new model (%d)" % ran)

## The same motion checks on the old model (figures=old), now that test_orderly_motion runs on the new default.
func test_todays_motion_checks_still_hold_on_the_old_model(t: T) -> void:
	var m := Motion.new()
	var ran := 0
	View.figures_override = "old"
	for method: Dictionary in m.get_method_list():
		var name: String = method.name
		if name.begins_with("test_") and not name.contains("breathing") and not name.contains("heard") \
				and not name.contains("prison_empty"):
			var before := t.failures.size()
			m.call(name, t)
			for i in range(before, t.failures.size()):
				t.failures[i] = "old model, %s: %s" % [name, t.failures[i]]
			ran += 1
	View.figures_override = ""
	t.check(ran >= 9, "today's motion checks ran on the old model (%d)" % ran)

func test_with_no_argument_the_view_draws_the_new_model(t: T) -> void:
	View.figures_override = ""
	t.eq(Figures.override, "", "the shared override is clear")
	t.check(not OS.get_cmdline_user_args().has("figures=old"), "the test run was not started with figures=old")
	t.check(View.new_figures(), "no argument: the new figures")
	var view := _view("")
	t.check(view.figure_v2, "the view draws the new model")
	t.eq(view.model.scene_file_path, View.MODEL_V2, "the view loaded orderly_v2.glb")
	t.check(view.skel.find_bone("neck1") < 0, "the new skeleton, not today's")
	view.free()
	var new := _view("new")
	t.eq(new.model.scene_file_path, View.MODEL_V2, "figures=new loads orderly_v2.glb")
	new.free()

## MO2: the face is printed on the mask (North Star B11: "a paper gown whose face is printed on its mask"),
## and the Meshy figure's real eyes are sewn shut above it. The mask is pale paper printed in near-black ink: the
## grin and two printed eyes. The places are build_orderly_v2.py's FACE_U, EYES, EYE_HALF, GRIN, PRINT_EYES and
## PRINT_EYE_HALF, in its head coordinates: v up the head bone's axis from the head joint, u across the face along its
## surface (the angle round the axis from straight ahead, times 0.10 m). Each triangle of the head is sampled
## at a few points; each point's texel is read from the albedo the game draws.
const FACE_U := -0.013
const EYES := [Vector2(-0.062, 0.257), Vector2(0.035, 0.257)]
const EYE_HALF := Vector2(0.036, 0.029)
const GRIN := {"v": 0.112, "depth": 0.040, "half": 0.118, "lift": 0.010, "width": 0.027}
const PRINT_EYES := [Vector2(-0.054, 0.182), Vector2(0.028, 0.182)]
const PRINT_EYE_HALF := Vector2(0.019, 0.014)

## Where the grin's middle line runs at u (the build's curve, with its jog at the pleats and its wobble).
func _grin_v(u: float, v: float) -> float:
	var jog := 0.003 if v < 0.085 else (-0.002 if v < 0.130 else (0.002 if v < 0.170 else -0.003))
	var qx := u - FACE_U + jog
	var tx := clampf(qx / float(GRIN.half), -1.25, 1.25)
	var end := maxf(absf(tx) - 0.72, 0.0)
	return float(GRIN.v) + float(GRIN.depth) * tx * tx + float(GRIN.lift) * end * end / 0.08 \
		+ 0.0007 * sin(qx * 140.0) + 0.0012 * sin(qx * 41.0 + 1.0)

func _lum(c: Color) -> float:
	return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b

func test_the_face_is_printed_on_the_mask_and_the_eyes_are_sewn_shut(t: T) -> void:
	var scene: Node = (load(View.MODEL_V2) as PackedScene).instantiate()
	var mi := scene.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var mat := mi.mesh.surface_get_material(0) as StandardMaterial3D
	var img := mat.albedo_texture.get_image()
	if img.is_compressed():
		img.decompress()
	var skin := mi.skin
	var head_pose := Transform3D()
	for b in skin.get_bind_count():
		if skin.get_bind_name(b) == "head":
			head_pose = skin.get_bind_pose(b).affine_inverse()  # the head joint in the mesh's space
	var h0 := head_pose.origin
	var ax := head_pose.basis.y.normalized()
	var arrays := mi.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var w := img.get_width()
	var h := img.get_height()
	var bary := [Vector3(1, 1, 1) / 3.0, Vector3(0.6, 0.2, 0.2), Vector3(0.2, 0.6, 0.2), Vector3(0.2, 0.2, 0.6),
		Vector3(0.45, 0.45, 0.1), Vector3(0.1, 0.45, 0.45), Vector3(0.45, 0.1, 0.45)]
	var grin: Array[float] = []
	var printed: Array[float] = []
	var ground: Array[float] = []
	var socket: Array[Color] = []
	for i in range(0, idx.size(), 3):
		var a := idx[i]
		var b := idx[i + 1]
		var c := idx[i + 2]
		for l: Vector3 in bary:
			var p := verts[a] * l.x + verts[b] * l.y + verts[c] * l.z
			var v := (p - h0).dot(ax)
			var d := p - h0 - ax * v
			if v < -0.05 or v > 0.45 or d.length() > 0.2:
				continue
			var az := atan2(d.x, d.z)  # the figure faces +z
			if absf(az) > 1.4:
				continue
			var u := az * 0.10
			var uv := uvs[a] * l.x + uvs[b] * l.y + uvs[c] * l.z
			var col := img.get_pixel(clampi(int(uv.x * w), 0, w - 1), clampi(int(uv.y * h), 0, h - 1))
			var tx := (u - FACE_U) / float(GRIN.half)
			if absf(tx) < 0.85:
				var gap := absf(v - _grin_v(u, v))
				if gap < 0.15 * float(GRIN.width):  # (so the texel's own middle is on the line too)
					grin.append(_lum(col))
			var near_eye := 9.0
			for e: Vector2 in PRINT_EYES:
				near_eye = minf(near_eye, Vector2((u - e.x) / PRINT_EYE_HALF.x, (v - e.y) / PRINT_EYE_HALF.y).length())
			if near_eye < 0.6:
				printed.append(_lum(col))
			elif near_eye > 1.6 and absf(u - FACE_U) < 0.08 and v > _grin_v(u, v) + 0.025 and v < 0.205:
				ground.append(_lum(col))  # bare paper between the grin and the eyes
			for e: Vector2 in EYES:
				var q := Vector2((u - e.x) / EYE_HALF.x, (v - e.y) / EYE_HALF.y)
				if q.length() < 0.85:
					socket.append(col)
	scene.free()
	grin.sort()
	printed.sort()
	ground.sort()
	t.check(grin.size() >= 20 and printed.size() >= 20 and ground.size() >= 50 and socket.size() >= 30,
		"the head was sampled (%d on the grin, %d on the printed eyes, %d on the bare mask, %d in the sockets)" % [
			grin.size(), printed.size(), ground.size(), socket.size()])
	if grin.is_empty() or printed.is_empty() or ground.is_empty() or socket.is_empty():
		return
	var grin_mid := grin[grin.size() / 2]
	var ground_mid := ground[ground.size() / 2]
	# (the texture is about 4 mm a texel and the line about 3 texels, softened by the WebP the build writes)
	var dark := grin.filter(func(x: float) -> bool: return x < 0.2).size()
	t.note("grin: median brightness %.2f, %d of %d under 0.2; mask around it: median %.2f" % [grin_mid, dark, grin.size(), ground_mid])
	t.check(grin_mid < 0.15 and dark >= 0.7 * grin.size(),
		"the grin is printed in dark ink (median %.2f, %d of %d samples under 0.2)" % [grin_mid, dark, grin.size()])
	var eyes_mid := printed[printed.size() / 2]
	var eyes_dark := printed.filter(func(x: float) -> bool: return x < 0.2).size()
	t.note("printed eyes: median %.2f, %d of %d under 0.2" % [eyes_mid, eyes_dark, printed.size()])
	t.check(eyes_mid < 0.15 and eyes_dark >= 0.7 * printed.size(),
		"two eyes are printed on the mask in dark ink (median %.2f, %d of %d under 0.2)" % [eyes_mid, eyes_dark, printed.size()])
	t.check(ground_mid > 0.6, "on pale paper, about 0.65-0.75 bright (median %.2f)" % ground_mid)
	# No looking eye: nothing near-white (a white of the eye or a glint), nothing coloured like an iris (a
	# saturated colour that is not the skin's warm tone), and the socket all one skin: lids and bruise.
	var white := 0
	var iris := 0
	var lo := INF
	var hi := -INF
	for col: Color in socket:
		if minf(col.r, minf(col.g, col.b)) > 0.7:
			white += 1
		if col.s > 0.25 and not (col.r >= col.g and col.g >= col.b * 0.9):
			iris += 1
		lo = minf(lo, _lum(col))
		hi = maxf(hi, _lum(col))
	t.note("sockets: %d samples, brightness %.2f..%.2f, %d near-white, %d iris-coloured" % [socket.size(), lo, hi, white, iris])
	t.check(white == 0, "no near-white in the eye sockets (%d samples)" % white)
	t.check(iris == 0, "nothing iris-coloured in the eye sockets (%d samples)" % iris)
	t.check(hi < 0.55, "the sockets are lid and shadow, no bright eye (brightest %.2f)" % hi)

func test_with_figures_old_the_view_draws_todays_model(t: T) -> void:
	View.figures_override = ""
	Figures.override = "old"
	t.check(not View.new_figures(), "figures=old: not the new figures")
	var view := _view("")
	Figures.override = ""
	t.check(not view.figure_v2, "the view keeps today's model")
	t.eq(view.model.scene_file_path, View.MODEL, "the view loaded orderly.glb")
	t.check(view.skel.find_bone("neck1") >= 0 and view.skel.find_bone("index1.L") >= 0, "today's skeleton, fingers and all")
	view.free()
