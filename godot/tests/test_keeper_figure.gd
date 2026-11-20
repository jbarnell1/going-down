## MG1: the Groundskeeper's Meshy figure (groundskeeper_v2.glb) sits behind the `figures=new` switch. It must
## carry today's seven clips at today's lengths, the bones the view drives, and stand as tall as today's
## figure. Without the switch the view loads today's figure and nothing else changes.
extends RefCounted

const T = preload("res://tests/t.gd")
const Keeper = preload("res://client/groundskeeper_view.gd")

const LENGTHS := {&"listen": 3.2, &"walk": 0.5, &"tilt": 0.8, &"sweep": 2.0, &"lean": 3.0,
	&"snatch": 19.0 / 30.0, &"recover": 0.6}

func test_the_switch_picks_the_figure(t: T) -> void:
	t.eq(Keeper.model_for(PackedStringArray(), ""), Keeper.MODEL, "no argument: today's figure")
	t.eq(Keeper.model_for(PackedStringArray(["figures=new"]), ""), Keeper.MODEL_NEW, "figures=new: the new figure")
	t.eq(Keeper.model_for(PackedStringArray(["--figures=new"]), ""), Keeper.MODEL_NEW, "--figures=new: the new figure")
	t.eq(Keeper.model_for(PackedStringArray(["figures=old", "x"]), ""), Keeper.MODEL, "another value: today's figure")
	t.eq(Keeper.model_for(PackedStringArray(), "?figures=new"), Keeper.MODEL_NEW, "?figures=new in the address")
	t.eq(Keeper.model_for(PackedStringArray(), "?room=a&figures=new"), Keeper.MODEL_NEW, "among other query fields")
	t.eq(Keeper.model_for(PackedStringArray(), "?figures=newer"), Keeper.MODEL, "only the exact field counts")
	t.eq(Keeper.model_path(), Keeper.MODEL, "this test run has no switch, so the game would load today's figure")
	t.check(ResourceLoader.exists(Keeper.MODEL_NEW), "the new figure is in the project")

func test_with_no_switch_the_view_loads_todays_figure(t: T) -> void:
	var keeper := Keeper.new()
	keeper._build()
	if t.check(keeper._model != null, "today's figure loads"):
		t.eq(keeper._model.scene_file_path, Keeper.MODEL, "the view loaded groundskeeper.glb")
		t.check(keeper._rig.find_bone("Chest") >= 0 and keeper._rig.find_bone("Spine1") < 0, "it is today's skeleton")
	keeper.free()

func _scene(path: String) -> Node3D:
	var scene := load(path) as PackedScene
	return scene.instantiate() as Node3D if scene != null else null

func _player(model: Node) -> AnimationPlayer:
	return model.find_child("AnimationPlayer", true, false) as AnimationPlayer

func _skeleton(model: Node) -> Skeleton3D:
	return model.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D

func test_the_new_figure_has_the_seven_clips(t: T) -> void:
	var fresh := _scene(Keeper.MODEL_NEW)
	var today := _scene(Keeper.MODEL)
	if not t.check(fresh != null and today != null, "both figures load"):
		return
	var player := _player(fresh)
	t.eq(Array(player.get_animation_list()).size(), LENGTHS.size(), "seven clips, no more")
	for clip: StringName in LENGTHS:
		if t.check(player.has_animation(clip), "%s is in the new figure" % clip):
			var length := player.get_animation(clip).length
			t.check(absf(length - LENGTHS[clip]) < 0.002, "%s lasts %.3f s (want %.3f)" % [clip, length, LENGTHS[clip]])
			t.check(absf(length - _player(today).get_animation(clip).length) < 0.002, "%s lasts as long as today's" % clip)
	fresh.free()
	today.free()

func test_the_new_figure_has_the_bones_the_view_drives(t: T) -> void:
	var keeper := Keeper.new()
	keeper.figure_model = Keeper.MODEL_NEW
	keeper._build()
	if not t.check(keeper._model != null and keeper._rig != null and keeper._player != null, "the new figure loads in the view"):
		keeper.free()
		return
	t.eq(keeper._model.scene_file_path, Keeper.MODEL_NEW, "the view loaded groundskeeper_v2.glb")
	t.check(keeper._head >= 0 and keeper._shears >= 0 and keeper._badges >= 0, "Head, Shears and Badges are in the skeleton")
	var rig := keeper._rig
	for bone: String in ["Root", "Blade.A", "Blade.B", "Hand.R"]:
		t.check(rig.find_bone(bone) >= 0, "%s is in the skeleton" % bone)
	t.eq(rig.get_bone_parent(keeper._shears), rig.find_bone("Hand.R"), "the shears ride in the right hand")
	t.eq(rig.get_bone_parent(rig.find_bone("Blade.B")), keeper._shears, "the moving blade hangs from the shears")
	var look := keeper.look()
	for key: String in ["glow", "unshaded"]:
		t.eq(look[key], false, "the new figure has no %s" % key)
	for key: String in ["passes", "overlays", "lights"]:
		t.eq(look[key], 0, "the new figure has no extra %s" % key)
	var textured := false
	for mesh: MeshInstance3D in keeper._model.find_children("*", "MeshInstance3D", true, false):
		var material := mesh.get_active_material(0) as BaseMaterial3D
		textured = textured or (material != null and material.albedo_texture != null)
	t.check(textured, "the body's painted texture loaded")
	var strike := keeper._player.get_animation(&"snatch")
	var track := -1
	for i in strike.get_track_count():
		if strike.track_get_type(i) == Animation.TYPE_ROTATION_3D and str(strike.track_get_path(i).get_concatenated_subnames()) == "Blade.B":
			track = i
	if t.check(track >= 0, "the moving blade has a rotation track"):
		var open := strike.rotation_track_interpolate(track, 0.14)
		var contact := strike.rotation_track_interpolate(track, Keeper.BLADE_CONTACT)
		var recoil := strike.rotation_track_interpolate(track, 0.28)
		t.check(open.angle_to(contact) > 0.15, "the shears close in time for the strike recording")
		t.check(contact.angle_to(recoil) < 0.04, "the shears remain closed during recoil")
	keeper.free()

func test_the_new_figure_stands_as_tall_as_todays(t: T) -> void:
	var fresh := _scene(Keeper.MODEL_NEW)
	var today := _scene(Keeper.MODEL)
	var heights := []
	for model: Node3D in [fresh, today]:
		var rig := _skeleton(model)
		heights.append(rig.get_bone_global_rest(rig.find_bone("Head")).origin.y)
	t.check(absf(heights[0] - heights[1]) < 0.01, "the Head joint stands where today's does (%.3f m against %.3f m)" % heights)
	var top := -INF
	var bottom := INF
	for mesh: MeshInstance3D in fresh.find_children("*", "MeshInstance3D", true, false):
		var box := mesh.mesh.get_aabb()
		top = maxf(top, box.end.y)
		bottom = minf(bottom, box.position.y)
	t.check(top > 2.9 and top < 3.05, "the dead branch stands to about 3 m (%.2f m)" % top)
	t.check(absf(bottom) < 0.02, "the feet stand on the floor (%.3f m)" % bottom)
	fresh.free()
	today.free()

func test_the_new_figure_walks_in_the_view(t: T) -> void:
	var keeper := Keeper.new()
	keeper.figure_model = Keeper.MODEL_NEW
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(keeper)
	var feet: Array[Vector3] = []
	for x: float in [0.0, 0.3, 0.9]:
		keeper.show_pose({"x": x, "y": 0, "z": 0, "yaw": 0, "anim": "walk", "animTime": 0.0}, true)
		feet.append(keeper._rig.get_bone_global_pose(keeper._rig.find_bone("Foot.L")).origin)
	t.eq(keeper._player.assigned_animation, &"walk", "the host's walk plays the walk clip")
	t.check(feet[0].distance_to(feet[1]) > 0.05 and feet[1].distance_to(feet[2]) > 0.05, "the left foot moves as he walks (%s)" % [feet])
	keeper.queue_free()
