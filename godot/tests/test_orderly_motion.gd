# The rendered resident follows the shared catch clock and needs no client frame history.
extends RefCounted

const T = preload("res://tests/t.gd")
const View = preload("res://client/orderly_view.gd")

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
