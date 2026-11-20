# MR1: the Rigger's second figure, the owner's Meshy model rigged by hand (assets_src/blender/rigger/build_rigger_v2.py,
# godot/assets/ward/rigger_v2.glb), shown unless the game was started with `figures=old` (client/figures.gd).
#   1. It has today's climb clip with today's length, and its own clips: climb, hang, reach, search, withdraw.
#   2. Its skeleton has exactly eight leg chains of four bones and one arm (at least six bones shoulder to wrist).
#   3. No vertex of a leg carries weight from another leg; the arm's vertices only from the arm.
#   4. Placed by the Ward's view while he searches, his wrist is at the house's shoulder, his own hand is folded away,
#      and the search hand is at the arm's last point, as for today's figure.
#   5. With no argument the view loads the new figure; with figures=old today's files, wrist and clip, and no lamp.
extends RefCounted

const T = preload("res://tests/t.gd")
const View = preload("res://client/ward/view.gd")
const House = preload("res://sim/ward/house.gd")
const Ward = preload("res://sim/ward/state.gd")

const CLIPS := {"climb": 2.5, "hang": 4.0, "reach": 1.5, "search": 2.0, "withdraw": 1.2}

static func _player(scene: Node) -> AnimationPlayer:
	var players := scene.find_children("*", "AnimationPlayer", true, false)
	return players[0] as AnimationPlayer if not players.is_empty() else null

static func _skeleton(scene: Node) -> Skeleton3D:
	var found := scene.find_children("*", "Skeleton3D", true, false)
	return found[0] as Skeleton3D if not found.is_empty() else null

## The leg a bone belongs to ("L1".."R4"), or "" for any other bone.
static func leg_of(bone: String) -> String:
	return bone.get_slice("_", 1) if bone.begins_with("leg_") else ""

func test_the_clips_are_there_with_their_lengths(t: T) -> void:
	var today := (load(View.RIGGER_PATH) as PackedScene).instantiate()
	var figure := (load(View.RIGGER_V2_PATH) as PackedScene).instantiate()
	var old_player := _player(today)
	var player := _player(figure)
	if not t.check(old_player != null and player != null, "both figures have an animation player"):
		today.free()
		figure.free()
		return
	var old_clip := old_player.get_animation(&"Rigger Climb")
	var clip: Animation = player.get_animation(&"Rigger Climb") if player.has_animation(&"Rigger Climb") else null
	t.check(old_clip != null and clip != null and absf(clip.length - old_clip.length) < 0.02,
		"\"Rigger Climb\" has today's length (%.3f s, today %.3f s)" % [clip.length if clip else -1.0, old_clip.length if old_clip else -1.0])
	for name: String in CLIPS:
		var a: Animation = player.get_animation(name) if player.has_animation(name) else null
		t.check(a != null and absf(a.length - float(CLIPS[name])) < 0.02 and a.get_track_count() >= 40,
			"%s: %.2f s (want %.2f), %d tracks" % [name, a.length if a else -1.0, CLIPS[name], a.get_track_count() if a else 0])
	today.free()
	figure.free()

func test_eight_legs_and_one_arm(t: T) -> void:
	var figure := (load(View.RIGGER_V2_PATH) as PackedScene).instantiate()
	var skeleton := _skeleton(figure)
	if not t.check(skeleton != null, "the figure has a skeleton"):
		figure.free()
		return
	var legs := {}
	for i in skeleton.get_bone_count():
		var leg := leg_of(skeleton.get_bone_name(i))
		if leg != "":
			legs[leg] = int(legs.get(leg, 0)) + 1
	t.eq(legs.size(), 8, "eight legs (%s)" % [legs.keys()])
	for leg: String in legs:
		# Each chain is coxa > femur > tibia > tarsus, each the parent of the next.
		var names := ["coxa", "femur", "tibia", "tarsus"]
		var linked := true
		for k in range(1, 4):
			var child := skeleton.find_bone("leg_%s_%s" % [leg, names[k]])
			var parent := skeleton.find_bone("leg_%s_%s" % [leg, names[k - 1]])
			linked = linked and child >= 0 and parent >= 0 and skeleton.get_bone_parent(child) == parent
		t.check(legs[leg] == 4 and linked, "leg %s is one chain of four bones" % leg)
	var hands := 0
	for i in skeleton.get_bone_count():
		if skeleton.get_bone_name(i) == "hand":
			hands += 1
	t.eq(hands, 1, "one hand")
	var chain := 0
	var at := skeleton.get_bone_parent(skeleton.find_bone("hand"))
	while at >= 0 and skeleton.get_bone_name(at).begins_with("arm_"):
		chain += 1
		at = skeleton.get_bone_parent(at)
	t.check(chain >= 6, "one arm of %d bones from shoulder to wrist (want at least six)" % chain)
	var lamp := figure.find_child("Lamp", true, false) as Node3D
	t.check(lamp != null, "the helmet carries its Lamp marker")
	figure.free()

func test_no_leg_vertex_is_weighted_to_another_leg(t: T) -> void:
	var figure := (load(View.RIGGER_V2_PATH) as PackedScene).instantiate()
	var skeleton := _skeleton(figure)
	var meshes := figure.find_children("*", "MeshInstance3D", true, false)
	if not t.check(skeleton != null and meshes.size() == 1, "one skinned mesh (%d)" % meshes.size()):
		figure.free()
		return
	var instance := meshes[0] as MeshInstance3D
	var skin := instance.skin
	var vertices := 0
	var crossed := 0
	var per_leg := {}
	for s in instance.mesh.get_surface_count():
		var arrays := instance.mesh.surface_get_arrays(s)
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		var count: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		var per := bones.size() / maxi(1, count)
		for v in count:
			vertices += 1
			var seen := {}
			for k in per:
				if weights[v * per + k] <= 0.0:
					continue
				var bind := bones[v * per + k]
				var bone := skin.get_bind_bone(bind)
				var name: String = skin.get_bind_name(bind) if bone < 0 else skeleton.get_bone_name(bone)
				var leg := leg_of(name)
				if leg != "":
					seen[leg] = true
			if seen.size() > 1:
				crossed += 1
			for leg: String in seen:
				per_leg[leg] = int(per_leg.get(leg, 0)) + 1
	t.check(vertices > 15000, "the mesh was read (%d vertices)" % vertices)
	t.eq(per_leg.size(), 8, "every leg moves vertices (%s)" % [per_leg])
	t.eq(crossed, 0, "no vertex carries weight from two legs")
	figure.free()

## A Ward view searching in house 0, as test_floor_media poses today's figure.
## force: 1 asks for the new figures, 0 for today's, -1 leaves the view as it builds itself (the shared switch).
static func _searching(force: int) -> Dictionary:
	var tree := Engine.get_main_loop() as SceneTree
	var view := View.new(8143, Vector3.ZERO)
	view.own_hud = false
	if force >= 0:
		view.figures_new = force == 1
	tree.root.add_child(view)
	var room: Dictionary = view.houses[0]
	var fixture: House = room.fixture
	var shoulder := fixture.to_world(fixture.shoulder)
	var reach := fixture.to_world(fixture.shoulder + Vector3(0, -0.4, 1.0))
	var tip := fixture.to_world(fixture.shoulder + Vector3(0, -0.6, 2.0))
	var ward := {"encounter": "searching", "house": 0, "startedAt": 0.0,
		"armPoints": [[reach.x, reach.y, reach.z], [tip.x, tip.y, tip.z]]}
	view._show_rigger(ward, Ward.WARN_SECONDS + Ward.CLIMB_SECONDS + 5.0)
	return {"view": view, "shoulder": shoulder, "tip": tip}

func test_the_wrist_lands_at_the_house_shoulder(t: T) -> void:
	var r := _searching(1)
	var view: View = r.view
	t.check(view.rigger.scene_file_path == View.RIGGER_V2_PATH, "figures=new loads %s (%s)" % [View.RIGGER_V2_PATH, view.rigger.scene_file_path])
	t.eq(view.climb_animation, &"Rigger Climb", "the view plays today's clip name on the new figure")
	var skeleton := _skeleton(view.rigger)
	var hand := skeleton.find_bone("hand")
	var wrist := skeleton.global_transform * skeleton.get_bone_global_pose(hand).origin
	t.check(wrist.distance_to(r.shoulder) < 0.02, "his wrist (the hand bone, posed) is at the house's shoulder (%.3f m off)" % wrist.distance_to(r.shoulder))
	var placed: Vector3 = view.rigger.position + view.rigger.basis * View.RIGGER_WRIST_V2
	t.check(placed.distance_to(r.shoulder) < 0.01, "RIGGER_WRIST_V2 places him there (%.3f m off)" % placed.distance_to(r.shoulder))
	var folded := skeleton.get_bone_global_pose(hand).basis.get_scale()
	t.check(folded.x < 0.1 and folded.y < 0.1 and folded.z < 0.1, "his own hand is folded away while the search hand works (scale %s)" % folded)
	t.check(view.hand.visible and view.hand.position.distance_to(r.tip) < 0.01, "the search hand is at the end of the arm (%.3f m off)" % view.hand.position.distance_to(r.tip))
	var light: OmniLight3D = view.lamp_light
	t.check(light != null and light.is_inside_tree() and light.omni_range <= 3.5 and light.light_energy <= 1.0 and not light.shadow_enabled,
		"the helmet lamp is weak and short (range %.1f m, energy %.1f)" % [light.omni_range if light else -1.0, light.light_energy if light else -1.0])
	var head := skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone("head")).origin
	t.check(light != null and light.global_position.distance_to(head) < 1.5, "the lamp rides the head (%.2f m from the head bone)" % (light.global_position.distance_to(head) if light else -1.0))
	view.free()

func test_with_no_argument_the_new_figure_loads(t: T) -> void:
	t.eq(Figures.override, "", "the shared override is clear")
	t.check(not OS.get_cmdline_user_args().has("figures=old") and View.new_figures(), "the tests run without figures=old: the new figures")
	var r := _searching(-1)
	var view: View = r.view
	t.check(view.figures_new, "the view asks for the new figures")
	t.check(view.rigger.scene_file_path == View.RIGGER_V2_PATH, "the new figure loads (%s)" % view.rigger.scene_file_path)
	t.eq(view.rigger_wrist, View.RIGGER_WRIST_V2, "the new figure's wrist")
	t.check(view.lamp_light != null, "the helmet lamp is lit while he searches")
	view.free()

func test_with_figures_old_nothing_changes(t: T) -> void:
	Figures.override = "old"
	t.check(not View.new_figures(), "figures=old: not the new figures")
	var r := _searching(-1)
	Figures.override = ""
	var view: View = r.view
	t.check(view.rigger.scene_file_path == View.RIGGER_PATH, "today's figure loads (%s)" % view.rigger.scene_file_path)
	t.eq(view.rigger_wrist, View.RIGGER_WRIST, "today's wrist")
	t.check(str(view.climb_animation).contains("Rigger Climb"), "today's clip (%s)" % view.climb_animation)
	t.check(view.lamp_light == null and view.rigger.find_child("Lamp", true, false) == null, "no lamp")
	var wrist: Vector3 = view.rigger.position + view.rigger.basis * View.RIGGER_WRIST
	t.check(wrist.distance_to(r.shoulder) < 0.01, "today's wrist is at the house's shoulder (%.3f m off)" % wrist.distance_to(r.shoulder))
	view.free()
