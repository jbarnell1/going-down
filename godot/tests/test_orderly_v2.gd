# MO1: the Orderly's second model (assets/entities/orderly_v2.glb, from the Meshy figure; built by
# assets_src/blender/orderly/build_orderly_v2.py) can stand in for today's. It is drawn only when the game is
# started with `figures=new`. These checks hold it to what the view needs: every clip today's model has, the
# same lengths; the bones the view drives; the same height and feet; today's motion checks (test_orderly_motion,
# among them the rule that no bone stretches); and with no argument nothing changes.
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

func test_with_no_argument_the_view_draws_todays_model(t: T) -> void:
	View.figures_override = ""
	t.check(not OS.get_cmdline_user_args().has("figures=new"), "the test run was not started with figures=new")
	t.check(not View.new_figures(), "no argument: not the new figures")
	var view := _view("")
	t.check(not view.figure_v2, "the view keeps today's model")
	t.eq(view.model.scene_file_path, View.MODEL, "the view loaded orderly.glb")
	t.check(view.skel.find_bone("neck1") >= 0 and view.skel.find_bone("index1.L") >= 0, "today's skeleton, fingers and all")
	view.free()
	var new := _view("new")
	t.eq(new.model.scene_file_path, View.MODEL_V2, "figures=new loads orderly_v2.glb")
	new.free()
