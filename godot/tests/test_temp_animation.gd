extends RefCounted

const T = preload("res://tests/t.gd")
const View = preload("res://client/temp_view.gd")


func _view() -> TempView:
	var v := View.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(v)
	return v


func _pose(x: float, anim: String, at: float) -> Dictionary:
	return {"x": x, "y": 0.0, "z": 0.0, "level": 0, "yaw": PI, "anim": anim, "animTime": at}


func test_animated_staging(t: T) -> void:
	var v := _view()
	var player := v.find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer
	for name: StringName in [&"idle", &"walk", &"chase", &"look", &"reach", &"bend"]:
		t.check(player.has_animation(name), "the skinned Temp carries %s" % name)
	v.show_pose(_pose(0.0, "idle", 0.5), true)
	var height := v.standing_height()
	t.check(height >= 1.7 and height <= 1.9, "Temp stands at desk-worker height (%.2f m)" % height)
	var player_names: Array[String] = []
	for name: String in ["temp_stapler", "temp_notes"]:
		var item := v.find_child(name, true, false)
		t.check(item is MeshInstance3D and item.get_parent() is BoneAttachment3D, "%s follows a hand bone" % name)
		if item != null and item.get_parent() is BoneAttachment3D:
			player_names.append((item.get_parent() as BoneAttachment3D).bone_name)
	t.check(player_names.size() == 2 and player_names[0].ends_with("RightHand")
		and player_names[1].ends_with("LeftHand"), "stapler and notes are on the correct hands")
	var old_hash := v.paper_hash()
	v.set_crew("annex", [FaceCodec.encode(FacePaint.starter(FacePaint.STARTERS[0]))])
	t.check(v.paper_hash() != old_hash, "the skinned paper uses the seed-selected photocopy")
	v.show_pose(_pose(0.0, "idle", 15.0), true)
	t.eq(player.assigned_animation, &"look", "standing long enough samples the waiting clip")
	v.show_pose(_pose(0.0, "walk", 0.1), true)
	v.show_pose(_pose(0.13, "walk", 0.2), true)
	t.eq(player.assigned_animation, &"walk", "a slow move samples the shuffling walk")
	v.show_pose(_pose(0.5, "walk", 0.3), true)
	t.eq(player.assigned_animation, &"chase", "a fast move samples the fast walk")
	v.show_pose(_pose(0.5, "reach", 0.6), true)
	t.eq(player.assigned_animation, &"reach", "the catch samples the right-arm jab")
	t.check(absf(player.current_animation_position - player.current_animation_length) < 0.001,
		"the jab hits by the rules' catch deadline")
	v.show_pose(_pose(0.5, "bend", 0.8), true)
	t.eq(player.assigned_animation, &"bend", "the caught pose uses the attack's downward motion")
	t.check(v.standing_height() < height - 0.25, "the Temp folds down toward the victim")
	v.free()


func test_held_frame_freezes_skin_and_props(t: T) -> void:
	var v := _view()
	v.show_pose(_pose(0.0, "walk", 0.1), true)
	var straight := v.drawn_signature()
	v.set_watched(Vector3(2.0, 1.8, 1.0))
	var pose := _pose(0.13, "walk", 0.2)
	v.show_pose(pose, true)
	var watched := v.drawn_signature()
	t.check(straight != watched, "motion and the one-watcher gesture affect the imported bones")
	var prop := v.find_child("temp_stapler", true, false) as MeshInstance3D
	var height := prop.global_position.y
	t.check(height > 1.4, "the stapler rises to face height (%.2f m)" % height)
	# The receiver omits the watched eye point when Stillness holds the last visible frame.
	v.set_watched(null)
	v.show_pose(pose, true)
	t.eq(v.drawn_signature(), watched, "the same held snapshot preserves the complete bone pose")
	t.eq(prop.global_position.y, height, "the held stapler stays exactly where the frozen hand put it")
	t.eq(v.clicks.size(), 0, "holding a pose emits no extra click")
	v.show_pose(_pose(0.26, "walk", 0.3), true)
	t.check(v.drawn_signature() != watched, "new motion releases the held pose")
	t.check(prop.global_position.y < height - 0.25, "the arm drops after the watch ends")
	v.free()
