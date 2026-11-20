# MT1: the Temp's new figure (assets/entities/temp_v2.glb, built by assets_src/blender/temp/build_temp_v2.py from
# the owner's Meshy model). It is drawn unless the game starts with `figures=old` (client/figures.gd); with that,
# today's figure, unchanged. The new one must give the view everything today's does: the six clips at today's lengths (the rules'
# timings do not move), the bones the view turns, the stapler and notes in the hands, the sheet for the
# photocopy, and today's height with the feet on the floor (where the rules think it is, its size).
extends RefCounted

const T = preload("res://tests/t.gd")
const View = preload("res://client/temp_view.gd")
const Entity = preload("res://sim/entity.gd")
const TODAY := "res://assets/entities/temp.glb"
const NEW := "res://assets/entities/temp_v2.glb"
const CLIPS: Array[StringName] = [&"walk", &"chase", &"idle", &"look", &"reach", &"bend"]
## Bones the view turns or follows by name (temp_view.gd _build_model, the props' hands).
const BONES: Array[String] = ["Head", "Neck", "Spine1", "Spine2", "RightArm", "RightForeArm", "RightHand", "LeftHand"]


func _figure(path: String) -> Node3D:
	return (load(path) as PackedScene).instantiate() as Node3D


func _player(n: Node) -> AnimationPlayer:
	return n.find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer


func _skel(n: Node) -> Skeleton3D:
	return n.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D


## The skinned body: the one mesh with a skin.
func _body(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for m: MeshInstance3D in n.find_children("*", "MeshInstance3D", true, false):
		if m.skin != null:
			out.append(m)
	return out


func _bone(s: Skeleton3D, short: String) -> int:
	for i in s.get_bone_count():
		if s.get_bone_name(i).ends_with(short):
			return i
	return -1


func _view(new: bool) -> TempView:
	View.force_new_figure = new
	var v := View.new()
	View.force_new_figure = null
	(Engine.get_main_loop() as SceneTree).root.add_child(v)
	return v


func _pose(anim: String, at: float) -> Dictionary:
	return {"x": 0.0, "y": 0.0, "z": 0.0, "level": 0, "yaw": PI, "anim": anim, "animTime": at}


func test_every_clip_at_todays_length(t: T) -> void:
	var a := _figure(TODAY)
	var b := _figure(NEW)
	for clip in CLIPS:
		var pa := _player(a)
		var pb := _player(b)
		if not t.check(pb.has_animation(clip), "the new figure carries %s" % clip):
			continue
		var la := pa.get_animation(clip).length
		var lb := pb.get_animation(clip).length
		t.check(absf(la - lb) <= 0.05, "%s lasts %.3f s, today's %.3f s" % [clip, lb, la])
	a.free()
	b.free()


func test_bones_props_and_sheet_the_view_uses(t: T) -> void:
	var n := _figure(NEW)
	var s := _skel(n)
	for short in BONES:
		t.check(_bone(s, short) >= 0, "the new skeleton has a bone ending %s" % short)
	t.eq(_body(n).size(), 1, "one skinned mesh")
	var hands := {"temp_stapler": "RightHand", "temp_notes": "LeftHand"}
	for prop: String in hands:
		var item := n.find_child(prop, true, false)
		t.check(item is MeshInstance3D and item.get_parent() is BoneAttachment3D
			and (item.get_parent() as BoneAttachment3D).bone_name.ends_with(hands[prop]),
			"%s rides the %s bone" % [prop, hands[prop]])
	var sheet := false
	for m: MeshInstance3D in _body(n):
		for i in m.mesh.get_surface_count():
			var mat := m.get_active_material(i) as BaseMaterial3D
			t.check(mat != null and mat.albedo_texture != null, "surface %d has a coloured texture" % i)
			if mat != null and mat.resource_name.begins_with("temp_face_sheet"):
				sheet = true
	t.check(sheet, "the face sheet the photocopy is drawn on is there (material temp_face_sheet)")
	n.free()


func test_height_and_feet_match_today(t: T) -> void:
	var a := _figure(TODAY)
	var b := _figure(NEW)
	var boxes: Array[AABB] = []
	for n: Node3D in [a, b]:
		var body := _body(n)
		var box := AABB()
		if not body.is_empty():
			# The mesh's rest bounds in the figure's own space.
			var to_root := Transform3D()
			var at: Node = body[0]
			while at != n:
				to_root = (at as Node3D).transform * to_root
				at = at.get_parent()
			box = to_root * body[0].mesh.get_aabb()
		boxes.append(box)
	var top_a := boxes[0].end.y
	var top_b := boxes[1].end.y
	t.check(absf(top_a - top_b) <= 0.02, "the new figure is %.3f m tall, today's %.3f m" % [top_b, top_a])
	t.check(absf(boxes[0].position.y - boxes[1].position.y) <= 0.02,
		"the feet are at %.3f m, today's at %.3f m" % [boxes[1].position.y, boxes[0].position.y])
	a.free()
	b.free()


func test_stapler_stays_in_the_hand_through_the_reach(t: T) -> void:
	var v := _view(true)
	var s := _skel(v)
	var hand := _bone(s, "RightHand")
	var stapler := v.find_child("temp_stapler", true, false) as Node3D
	var rel: Variant = null
	var low := INF
	var high := -INF
	for k in 11:
		var at := Entity.WIND_UP_TIME * k / 10.0
		v.show_pose(_pose("reach", at), true)
		var h := s.global_transform * s.get_bone_global_pose(hand)
		var here := h.affine_inverse() * stapler.global_transform
		t.check(stapler.global_position.distance_to(h.origin) < 0.2,
			"at %.2f s the stapler is %.3f m from the wrist" % [at, stapler.global_position.distance_to(h.origin)])
		if rel == null:
			rel = here
		else:
			t.check((rel as Transform3D).origin.distance_to(here.origin) < 0.001, "the grip does not slip at %.2f s" % at)
		low = minf(low, stapler.global_position.y)
		high = maxf(high, stapler.global_position.y)
	t.check(high - low > 0.3, "the reach brings the stapler up (%.2f m to %.2f m)" % [low, high])
	v.free()


## The view built with no override at all, following the shared switch (client/figures.gd).
func _view_default() -> TempView:
	View.force_new_figure = null
	var v := View.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(v)
	return v


func test_without_the_argument_the_view_draws_the_new_figure(t: T) -> void:
	View.force_new_figure = null
	t.eq(Figures.override, "", "the shared override is clear")
	t.check(View.new_figure(), "no figures=old in this run's arguments: the new figure")
	t.eq(View.model_path(), NEW, "the view's figure file without the argument")
	var today := _figure(TODAY)
	var new := _figure(NEW)
	t.check(_skel(today).get_bone_count() != _skel(new).get_bone_count(), "the two skeletons can be told apart")
	var v := _view_default()
	t.eq(_skel(v).get_bone_count(), _skel(new).get_bone_count(), "the drawn skeleton is the new one")
	v.free()
	var w := _view(true)
	t.eq(_skel(w).get_bone_count(), _skel(new).get_bone_count(), "with figures=new the new skeleton is drawn")
	w.free()
	today.free()
	new.free()


func test_with_figures_old_the_view_draws_todays_figure(t: T) -> void:
	Figures.override = "old"
	t.check(not View.new_figure(), "figures=old: not the new figure")
	t.eq(View.model_path(), TODAY, "the view's figure file with figures=old")
	var today := _figure(TODAY)
	var v := _view_default()
	Figures.override = ""
	t.eq(_skel(v).get_bone_count(), _skel(today).get_bone_count(), "the drawn skeleton is today's")
	v.free()
	today.free()


## Every check today's figure passes in test_temp_animation (clips sampled by the view, height, the bend's fold,
## the stapler raised before the face and dropped, held poses, the click at the held prop), on the new figure.
func test_the_new_figure_passes_the_temp_animation_checks(t: T) -> void:
	var suite: RefCounted = load("res://tests/test_temp_animation.gd").new()
	View.force_new_figure = true
	for m: Dictionary in suite.get_method_list():
		var name: String = m["name"]
		if name.begins_with("test_"):
			var before := t.failures.size()
			suite.call(name, t)
			for i in range(before, t.failures.size()):
				t.failures[i] = "new figure, %s: %s" % [name, t.failures[i]]
	View.force_new_figure = null


## The same checks on today's figure (figures=old), now that test_temp_animation runs on the new default.
func test_the_old_figure_still_passes_the_temp_animation_checks(t: T) -> void:
	var suite: RefCounted = load("res://tests/test_temp_animation.gd").new()
	View.force_new_figure = false
	for m: Dictionary in suite.get_method_list():
		var name: String = m["name"]
		if name.begins_with("test_"):
			var before := t.failures.size()
			suite.call(name, t)
			for i in range(before, t.failures.size()):
				t.failures[i] = "old figure, %s: %s" % [name, t.failures[i]]
	View.force_new_figure = null
