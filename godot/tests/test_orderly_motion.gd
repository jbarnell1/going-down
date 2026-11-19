# The rendered resident follows the shared catch clock and needs no client frame history.
extends RefCounted

const T = preload("res://tests/t.gd")
const View = preload("res://client/orderly_view.gd")
const Sfx = preload("res://client/sfx.gd")
const Move = preload("res://sim/move.gd")

func _pose(anim: String, t: float, catching: bool = false, x: float = 0.0) -> Dictionary:
	return {"anim": anim, "animTime": t, "catch_active": catching, "x": x, "y": 0.0, "z": 0.0, "yaw": 0.0}

func _view() -> View:
	var view := View.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(view)
	return view

func _bone(view: View, name: String) -> Transform3D:
	view.skel.force_update_all_bone_transforms()
	return view.skel.get_bone_global_pose(view.skel.find_bone(name))

func test_imported_motion_moves_original_rig(t: T) -> void:
	var view := _view()
	for clip: String in ["mixamo_idle", "mixamo_walk", "mixamo_reach", "mixamo_roar", "bellydance"]:
		t.check(view.ap.has_animation(clip), "import includes " + clip)
	view.show_pose(_pose("idle", 0.25), true)
	var idle_head := _bone(view, "head")
	view.show_pose(_pose("idle", 1.25), true)
	t.eq(str(view.ap.assigned_animation), "mixamo_idle", "idle uses the delivered performance")
	t.check(not _bone(view, "head").is_equal_approx(idle_head), "idle animates the head")
	view.show_pose(_pose("walk", 0.0), true)
	var foot := _bone(view, "foot.L")
	view.show_pose(_pose("walk", 0.0, false, 0.45), true)
	t.eq(str(view.ap.assigned_animation), "mixamo_walk", "walk uses the delivered performance")
	t.check(not _bone(view, "foot.L").is_equal_approx(foot), "distance walked advances the foot")
	view.show_pose(_pose("walk", 0.3, false, 0.45), true)
	var held := _bone(view, "foot.L")
	view.show_pose(_pose("walk", 0.7, false, 0.45), true)
	t.eq(_bone(view, "foot.L"), held, "without travel the walk holds its pose")
	view.show_pose(_pose("reach", 0.25), true)
	t.eq(str(view.ap.assigned_animation), "mixamo_reach", "the original reach includes the downloaded attack")
	var reach_hand := _bone(view, "hand.R")
	view.show_pose(_pose("reach", View.WIND_UP_TIME), true)
	t.check(_bone(view, "hand.R").origin.distance_to(reach_hand.origin) > 0.1, "the reach extends toward the player")
	view.show_pose(_pose("duck", 0.4), true)
	t.eq(str(view.ap.assigned_animation), "duck", "the authored door pose still clears the frame")
	view.free()

func test_dance_follows_bend_and_stops_on_rescue_or_exit(t: T) -> void:
	var view := _view()
	var fresh := _view()
	t.check(not view.bellydance_on_catch, "dance is off by default")
	view.show_pose(_pose("bend", 3.0, true), true)
	t.eq(str(view.ap.assigned_animation), "mixamo_reach", "the default stays bent")
	t.eq(view.bend, 1.0, "the default finishes the bend")
	view.bellydance_on_catch = true
	view.show_pose(_pose("reach", 0.6), true)
	t.eq(str(view.ap.assigned_animation), "mixamo_reach", "wind-up precedes the dance")
	view.show_pose(_pose("bend", 0.45), true)
	var head_without_roar := _bone(view, "head")
	view.show_pose(_pose("bend", 0.45, true), true)
	t.check(view.bend > 0.0 and view.bend < 1.0, "the bend is partway through")
	t.check(not _bone(view, "head").is_equal_approx(head_without_roar), "the roar changes the early head pose")
	t.eq(str(view.ap.assigned_animation), "mixamo_reach", "the roar and bend finish before the dance")
	view.show_pose(_pose("bend", View.DANCE_AFTER, true), true)
	t.eq(view.bend, 1.0, "the full bend happens first")
	t.eq(str(view.ap.assigned_animation), "mixamo_reach", "the transition starts from the bend")
	view.show_pose(_pose("bend", 2.0, true), true)
	var first := _bone(view, "hand.L")
	t.eq(str(view.ap.assigned_animation), "bellydance", "the optional bellydance starts during the catch")
	view.show_pose(_pose("bend", 3.0, true), true)
	var second := _bone(view, "hand.L")
	t.check(not first.is_equal_approx(second), "the dance changes the pose")
	fresh.bellydance_on_catch = true
	fresh.show_pose(_pose("bend", 3.0, true), true)
	t.eq(_bone(fresh, "hand.L"), second, "clients agree when arriving on the same catch frame")
	t.eq(view.position, Vector3.ZERO, "the dance leaves the resident's game position alone")
	view.bellydance_on_catch = false
	view.show_pose(_pose("bend", 3.0, true), true)
	t.eq(str(view.ap.assigned_animation), "mixamo_reach", "switching the setting off stops the dance")
	view.bellydance_on_catch = true
	view.show_pose(_pose("bend", 3.0, true), true)
	view.show_pose(_pose("bend", 3.0), true)
	t.eq(str(view.ap.assigned_animation), "mixamo_reach", "rescue stops the dance even while Stillness holds the bend")
	fresh.show_pose(_pose("idle", 0.25), true)
	t.eq(str(fresh.ap.assigned_animation), "mixamo_idle", "leaving the catch exits the dance")
	view.show_pose(_pose("bend", 5.0, true), true)
	view.reset()
	t.check(not view.visible and view.bend == 0.0 and not view.ap.is_playing(), "floor reset clears the dance")
	view.show_pose(_pose("bend", 0.1, true), true)
	t.eq(str(view.ap.assigned_animation), "mixamo_reach", "the next catch starts its own bend")
	view.show_pose(null, false)
	t.check(not view.visible and view.bend == 0.0 and not view.ap.is_playing(), "a removed resident clears its catch playback")
	view.free()
	fresh.free()

func test_fold_lowers_head_to_prone_crew_and_keeps_both_feet_planted(t: T) -> void:
	var view := _view()
	view.show_pose(_pose("bend", 0.0, true), true)
	var foot := _bone(view, "foot.R").origin.y
	view.show_pose(_pose("bend", 0.9, true), true)
	var head := _bone(view, "head").origin
	t.check(head.y > 0.32 and head.y < 0.68, "head reaches prone crew height")
	t.check(absf(_bone(view, "foot.R").origin.y - foot) < 0.06, "catch keeps the planted foot at floor level")
	var left := _bone(view, "hand.L").origin.y
	var right := _bone(view, "hand.R").origin.y
	t.check(minf(left,right) > 0.12, "hands stay above the floor while bracing")
	view.show_pose(_pose("bend", 1.10, true), true)
	t.check(head.distance_to(_bone(view, "head").origin) > 0.015, "head works over the crew after the fold")
	view.free()

func test_door_pose_holds_still_and_keeps_approved_walk(t: T) -> void:
	var view := _view()
	var plan := preload("res://sim/clinic.gd").generate_clinic("av4-clinic", 1)
	view.floor_plan = plan
	var frame := _pose("walk", 0.0)
	frame.x = 60.355
	frame.z = 39.80
	frame.level = 0
	view.show_pose(frame, true)
	var bones: Array[Transform3D] = []
	for i in view.skel.get_bone_count():
		bones.append(view.skel.get_bone_global_pose(i))
	var placement := view.model.transform
	view.show_pose(frame, true)
	t.eq(view.model.transform, placement, "wall clearance is stationary on a held frame")
	for i in bones.size():
		t.check(view.skel.get_bone_global_pose(i).is_equal_approx(bones[i]), "held bone stays still: " + view.skel.get_bone_name(i))
	t.eq(str(view.ap.assigned_animation), "mixamo_walk", "jamb clearance retains the approved walk")
	t.check((view.global_position - Vector3(frame.x, 0, frame.z)).length() < 0.0001, "replicated root stays at the host position")
	view.free()

func test_clinic_door_clears_head_and_hands_from_either_side(t: T) -> void:
	var view := _view()
	var plan := preload("res://sim/clinic.gd").generate_clinic("av4-clinic", 1)
	var door := plan.doors[0]
	view.floor_plan = plan
	var centre := Vector2(door.ax + door.bx + 1, door.ay + door.by + 1) * (0.5 * plan.cell_size)
	var forward := Vector2(door.bx - door.ax, door.by - door.ay)
	var across := Vector2(-forward.y, forward.x)
	for direction: float in [-1.0, 1.0]:
		var location := centre + direction * (0.18 * across + 0.08 * forward)
		var pose := _pose("duck", 0.0)
		pose.x = location.x
		pose.z = location.y
		pose.yaw = atan2(-forward.x * direction, -forward.y * direction)
		pose.level = door.level
		view.show_pose(pose, true)
		var head := view.skel.to_global(_bone(view, "head").origin)
		t.check(head.y < 1.96, "head and cap pass below the Clinic lintel")
		for hand: String in ["hand.L", "hand.R"]:
			var wrist := view.skel.to_global(_bone(view, hand).origin)
			t.check(absf((Vector2(wrist.x, wrist.z) - centre).dot(across)) < 0.49,
				"wrist has room inside the jamb from direction %s" % direction)
	view.free()

func test_early_catch_keeps_reaching_hands_on_the_room_side_of_a_wall(t: T) -> void:
	var view := _view()
	var plan := preload("res://sim/clinic.gd").generate_clinic("clinic-thursday", 1)
	view.floor_plan = plan
	for door in plan.doors:
		if door.ay == door.by:
			continue
		var centre := Vector2(door.ax + door.bx + 1, door.ay + door.by + 1) * (0.5 * plan.cell_size)
		var forward := Vector2(door.bx - door.ax, door.by - door.ay)
		var along := Vector2(-forward.y, forward.x)
		for side: float in [1.0, -1.0]:
			var at := centre + along * 0.85 + forward * 0.42 * side
			var aim := along * 0.8 - forward * 0.08 * side
			var pose := _pose("bend", 0.0, true)
			pose.x = at.x
			pose.z = at.y
			pose.yaw = atan2(-aim.x, -aim.y)
			pose.level = door.level
			for clock: float in [0.0, 0.1, 0.3, 0.5, 0.8, 1.3, 2.2]:
				pose.animTime = clock
				view.show_pose(pose, true)
				for name: String in ["hand.L", "hand.R"]:
					var bone := view.skel.find_bone(name)
					var wrist := view.skel.to_global(view.skel.get_bone_global_pose(bone).origin)
					var inside := (Vector2(wrist.x, wrist.z) - centre).dot(forward) * side
					t.check(inside >= 0.06, "%s crosses the room-side wall face at %.2f s" % [name, clock])
		view.free()
		return
	view.free()
	t.check(false, "the seed contains a doorway with a north/south normal")

func test_small_arm_tuck_moves_the_forearm_during_the_catch_fold(t: T) -> void:
	var view := _view()
	# First rejected pose from a linked witness in the seeded Clinic.
	view.floor_plan = preload("res://sim/clinic.gd").generate_clinic("down-1", 1)
	var pose := _pose("bend", 0.411, true, 51.1541217241805)
	pose.z = 5.84372882721202
	pose.yaw = 0.1806753890036
	pose.level = 0
	var tuck := Vector3(0.0, -0.95, -0.20).normalized()
	view._show_bend(pose.animTime, true)
	var untucked := (_bone(view, "forearm.R").origin - _bone(view, "upperarm.R").origin).normalized()
	view.show_pose(pose, true)
	var tucked := (_bone(view, "forearm.R").origin - _bone(view, "upperarm.R").origin).normalized()
	t.check(tucked.distance_to(tuck) < untucked.distance_to(tuck) - 0.0005,
		"the forearm turns toward its wall-clearance direction while the catch is still folding")
	view.free()

func test_the_trolley_contacts_the_floor_and_clears_the_jamb(t: T) -> void:
	var view := _view()
	var plan := preload("res://sim/clinic.gd").generate_clinic("av4-clinic", 1)
	view.floor_plan = plan
	var door := plan.doors[0]
	var centre := Vector2(door.ax + door.bx + 1, door.ay + door.by + 1) * (0.5 * plan.cell_size)
	var forward := Vector2(door.bx - door.ax, door.by - door.ay)
	var across := Vector2(-forward.y, forward.x)
	var wheels := 0
	var failures := 0
	for direction: float in [-1.0, 1.0]:
		for step in 22:
			var at := centre + direction * (0.18 * across + lerpf(-1.70, 1.40, step / 21.0) * forward)
			var pose := _pose("duck", 0.0)
			pose.x = at.x
			pose.z = at.y
			pose.yaw = atan2(-forward.x * direction, -forward.y * direction)
			pose.level = door.level
			view.show_pose(pose, true)
			var cart := view.trolley.global_position
			var floor_y := Move.feet_height(plan, door.level, cart.x, cart.z)
			wheels = 0
			for mesh: MeshInstance3D in view.trolley.find_children("*", "MeshInstance3D", true, false):
				var bounds := mesh.global_transform * mesh.get_aabb()
				if str(mesh.name).begins_with("Caster tire"):
					wheels += 1
					var low := INF
					for vertex: Vector3 in mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
						low = minf(low, (mesh.global_transform * vertex).y)
					if absf(low - floor_y) > 0.012:
						failures += 1
				var near := INF
				var far := -INF
				var side := 0.0
				for corner in 8:
					var p := bounds.get_endpoint(corner)
					var off := Vector2(p.x, p.z) - centre
					near = minf(near, off.dot(forward))
					far = maxf(far, off.dot(forward))
					side = maxf(side, absf(off.dot(across)))
				if near <= 0.075 and far >= -0.075 and (side > 0.55 or bounds.end.y > 2.10):
					failures += 1
	t.eq(wheels, 4, "four modeled tires touch the floor")
	t.eq(failures, 0, "the cart clears floor, jamb and lintel over 44 offsets")
	view.free()

func test_the_orderly_pushes_and_then_releases_the_trolley(t: T) -> void:
	var view := _view()
	view.show_pose(_pose("walk", 0.25), true)
	var grip := view.trolley.find_child("GripRight", true, false) as Node3D
	var wrist := view.skel.to_global(_bone(view, "hand.R").origin)
	t.check(wrist.distance_to(grip.global_position) < 0.04, "the walking right hand grips the physical bar")
	view.set_watched(Vector3(2, 1.65, -3))
	view.show_pose(_pose("walk", 0.25), true)
	wrist = view.skel.to_global(_bone(view, "hand.R").origin)
	var left := view.skel.to_global(_bone(view, "hand.L").origin)
	t.check(wrist.distance_to(grip.global_position) < 0.04 and left.distance_to(grip.global_position) > 0.25,
		"the watched walk pushes with its right hand alone")
	var pushing := view.trolley.global_position
	view.show_pose(_pose("reach", View.WIND_UP_TIME), true)
	var parked := view.trolley.global_position
	t.check(parked.distance_to(pushing) > 0.5, "the released cart rolls clear before the fold")
	view.show_pose(_pose("bend", 0.9, true), true)
	t.eq(view.trolley.global_position, parked, "the cart remains where it stopped during the meal")
	view.free()

func test_the_recorded_trolley_audio_follows_its_wheel_while_unseen(t: T) -> void:
	var view := _view()
	var world := Node3D.new()
	view.add_child(world)
	var audio := Sfx.new()
	world.add_child(audio)
	audio.setup(world)
	var pose := _pose("walk", 0.20, false, 4.0)
	view.show_pose(pose, false)
	var source := view.trolley_squeak_at()
	t.check(not view.visible and source.distance_to(Vector3(4.0, 0.4, 0.0)) > 0.5, "the unseen cart has a current wheel position off the resident")
	audio.update(0.016, {"gain": 0.8}, pose, 0.0, 0.0, 0.0, false, 0.0, Vector3.ZERO, 2.0, source)
	t.eq(audio.squeak.stream.resource_path, "res://assets/sfx/orderly/trolley_squeak.ogg", "the original recorded squeak plays")
	t.eq(audio.roll.stream.resource_path, "res://assets/sfx/orderly/trolley_roll.ogg", "the original recorded roll plays")
	t.check(audio.squeak is AudioStreamPlayer3D and audio.roll is AudioStreamPlayer3D,
		"both sounds come from world-space emitters")
	t.eq(audio.squeak.global_position, source, "the squeak co-locates with the wheel")
	t.eq(audio.roll.global_position, source, "the roll co-locates with the wheel")
	t.check(audio.squeak.playing and audio.roll.playing, "the cart remains audible while off-camera")
	view.free()

func test_prison_empty_furniture_can_be_passed_to_the_trolley(t: T) -> void:
	var level := preload("res://client/level.gd").new()
	const Furniture = preload("res://sim/furniture.gd")
	var empty: Array[Furniture.Piece] = []
	t.check(level.pieces.is_same_typed(empty), "a floor with no props supplies a typed empty piece list")
	level.free()
