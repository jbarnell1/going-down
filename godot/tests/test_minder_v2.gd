# The Minder's second figure (MN1: assets/entities/minder_v2.glb, built by
# assets_src/blender/minder/build_minder_v2.py from Meshy's rigged model), drawn by client/minder_view.gd unless
# the game was started with figures=old (client/figures.gd). Residents "always obey their rule": the figure is only a picture,
# so these hold the picture to what the view needs and leave the old figure exactly as it was:
#   1. v2 has every clip the view plays, at the old model's lengths, loops looping and one-shots held;
#   2. its card mask is its own material ("Minder_mask", one surface, with its glow map), on the front of the
#      head, facing the way the figure faces, and the view hangs the halo on it;
#   3. every bone the clips drive and the view names is in its skeleton;
#   4. its gaits' ground speeds in the view (GAIT_SPEED_V2) are the speeds its planted feet move back in the
#      clips, so the feet do not slide;
#   5. with no argument the view loads the second figure; with figures=old today's model, with today's clips,
#      speeds and body kinds.
# The sizes against today's figure are printed as notes.
extends RefCounted

const T = preload("res://tests/t.gd")
const MinderViewScript = preload("res://client/minder_view.gd")

func _view(which: String) -> MinderView:
	MinderView.figures = which
	var v: MinderView = MinderViewScript.new()
	MinderView.figures = ""
	return v

func test_v2_has_every_clip_the_view_plays_at_the_old_lengths(t: T) -> void:
	var old := _view("old")
	var v := _view("new")
	t.check(v.v2 and not old.v2, "figures=new loads the second figure, old the first")
	var wanted: Array[String] = []
	for p: String in MinderView.CLIPS:
		var c := String(MinderView.CLIPS[p])
		if not wanted.has(c):
			wanted.append(c)
	t.eq(wanted.size(), 10, "the view plays ten clips")
	for c: String in wanted:
		t.check(v.anims.has(c), "v2 has the clip %s" % c)
		if not v.anims.has(c) or not old.anims.has(c):
			continue
		var a: Animation = v.anims[c]
		var o: Animation = old.anims[c]
		t.check(absf(a.length - o.length) < 0.02, "%s lasts %.3f s, as the old model's %.3f s" % [c, a.length, o.length])
		t.eq(a.loop_mode != Animation.LOOP_NONE, o.loop_mode != Animation.LOOP_NONE, "%s loops as the old one does" % c)
	old.free()
	v.free()

func test_v2_mask_is_its_own_material_on_the_front(t: T) -> void:
	var v := _view("new")
	var names: Array[String] = []
	var masks := 0
	for s in v.mesh.mesh.get_surface_count():
		var m := v.mesh.mesh.surface_get_material(s)
		names.append(m.resource_name if m else "")
		if m and m.resource_name == "Minder_mask":
			masks += 1
			var sm := m as StandardMaterial3D
			t.check(sm != null and sm.emission_texture != null, "the mask carries its glow map")
			t.check(absf(v.mask_glow()["lit"] - 0.26) < 0.02, "its glow under the strip lights is the old card's 0.26 (%.3f)" % v.mask_glow()["lit"])
	t.eq(masks, 1, "one surface carries Minder_mask (%s)" % ", ".join(names))
	t.check(v.skel.find_child("MaskHalo", true, false) != null, "the halo hangs on the head")
	for c: String in ["stand", "walk", "prowl", "run", "look", "sweep"]:
		v.hold_clip(c, 0.3)
		var mi := v.mask_info()
		t.eq(int(mi["count"]), 1, "%s: the mask's material is drawn once" % c)
		t.check(Vector3(mi["facing"]).z > 0.3, "%s: the card faces forward (facing %s)" % [c, mi["facing"]])
		t.check(Vector3(mi["at"]).z > Vector3(mi["head"]).z, "%s: the card is in front of the head bone" % c)
	v.free()

## The face plate is a face a player can see: in every searching and walking clip it comes up to within 20
## degrees of level at some point in each play (the run keeps it there throughout), the cover hides it facing
## the floor, and the catch ends with it reared at the player's eyes, level, facing them.
func test_v2_face_comes_up_to_the_player(t: T) -> void:
	var v := _view("new")
	for c: String in ["stand", "walk", "prowl", "sweep", "look", "run"]:
		var a: Animation = v.anims[c]
		var best := 90.0
		var worst := -90.0
		for i in 24:
			v.hold_clip(c, a.length * i / 24.0)
			var down := rad_to_deg(asin(-Vector3(v.mask_info()["facing"]).y))
			best = minf(best, down)
			worst = maxf(worst, down)
		t.check(best <= 20.0, "%s: the face comes up to %.1f degrees below level (want 20 or less)" % [c, best])
		if c == "run":
			t.check(worst <= 25.0, "run: the face stays forward (at most %.1f degrees down)" % worst)
	for i in 6:
		v.hold_clip("cover", 0.5 * i)
		t.check(Vector3(v.mask_info()["facing"]).y < -0.6, "cover at %.1f s: the face is turned to the floor" % (0.5 * i))
	v.hold_clip("catch", 3.0)
	var mi := v.mask_info()
	var at: Vector3 = mi["at"]
	var f: Vector3 = mi["facing"]
	t.check(at.y > 1.35 and at.y < 1.7, "catch end: the face at %.2f m, about the player's 1.6 m eyes" % at.y)
	t.check(f.z > 0.9 and absf(f.y) < 0.3, "catch end: it faces them, level (%s)" % f)
	t.note("catch end: face at %s facing %s" % [at, f])
	v.free()

func test_v2_bones_the_view_drives_exist(t: T) -> void:
	var v := _view("new")
	for b: String in ["head"] + Array(MinderView.JOINTS_V2.values()):
		t.check(v.skel.find_bone(b) >= 0, "bone %s exists" % b)
	for c: String in v.anims:
		var a: Animation = v.anims[c]
		var missing := 0
		for i in a.get_track_count():
			var tp := a.track_get_type(i)
			if tp == Animation.TYPE_POSITION_3D or tp == Animation.TYPE_ROTATION_3D or tp == Animation.TYPE_SCALE_3D:
				if v.skel.find_bone(String(a.track_get_path(i).get_concatenated_subnames())) < 0:
					missing += 1
		t.eq(missing, 0, "%s: every track drives a bone of the skeleton" % c)
	t.check(v.mesh.skin != null and v.mesh.skin.get_bind_count() > 0, "one skinned mesh")
	v.free()

## The feet in stance move back, in the clip's own time, at the speed the view runs the clip on the ground.
func test_v2_gait_speeds_keep_the_feet_still(t: T) -> void:
	var v := _view("new")
	# (gait, foot bone, two clip times inside that foot's stance)
	var cases := [["walk", "rearToe.L", 0.15, 0.6], ["walk", "frontToe.L", 0.5, 0.9], ["prowl", "rearToe.L", 0.02, 0.12],
		["run", "rearToe.L", 0.01, 0.08]]
	for k: Array in cases:
		var c: String = k[0]
		v.hold_clip(c, k[2])
		var a := v.joint_point(k[1])
		v.hold_clip(c, k[3])
		var b := v.joint_point(k[1])
		var speed := (a.z - b.z) / (float(k[3]) - float(k[2]))
		var want := float(MinderView.GAIT_SPEED_V2[c])
		t.check(absf(speed - want) < want * 0.06, "%s: %s moves back at %.3f m/s of clip time, the view's GAIT_SPEED_V2 %.3f" % [c, k[1], speed, want])
		t.check(absf(a.y - b.y) < 0.03, "%s: %s stays on the floor in stance (%.3f, %.3f)" % [c, k[1], a.y, b.y])
	t.eq(v.gait_speed, MinderView.GAIT_SPEED_V2, "the second figure runs its gaits on its own speeds")
	v.free()

func test_with_no_argument_the_view_draws_the_second_figure(t: T) -> void:
	t.eq(MinderView.figures, "", "the tests' switch is clear")
	t.eq(Figures.override, "", "the shared override is clear")
	t.check(MinderView.new_figures(), "no figures=old on this command line: the new figures")
	var v: MinderView = MinderViewScript.new()
	t.check(v.v2, "no argument: the second figure")
	t.eq(v.gait_speed, MinderView.GAIT_SPEED_V2, "its own gait speeds")
	t.eq(v.model.scene_file_path, MinderView.MODEL_V2, "loaded from minder_v2.glb")
	v.free()

func test_with_figures_old_the_view_is_unchanged(t: T) -> void:
	t.eq(MinderView.figures, "", "the tests' switch is clear")
	Figures.override = "old"
	t.check(not MinderView.new_figures(), "figures=old: not the new figures")
	var v: MinderView = MinderViewScript.new()
	Figures.override = ""
	t.check(not v.v2, "figures=old: the first figure")
	t.eq(v.gait_speed, MinderView.GAIT_SPEED, "its gait speeds")
	t.eq(v.skel.get_bone_count(), 43, "today's skeleton (43 bones)")
	t.check(v.skel.find_bone("rearLwr.L") < 0 and v.skel.find_bone("shin.L") >= 0, "today's bone names")
	t.eq(v.model.scene_file_path, MinderView.MODEL, "loaded from minder.glb")
	for p: String in MinderView.RULE_POSES:
		v.hold_clip(p, 0.0)
		t.eq(v.body_kind, MinderView.family(p), "%s: today's body kind" % p)
	v.hold_clip("stand", 0.0)
	t.check(v.extent().size.y > 1.9, "today's figure stands upright (%.2f m)" % v.extent().size.y)
	v.free()

func test_sizes_against_todays_figure(t: T) -> void:
	var old := _view("old")
	var v := _view("new")
	var rows: Array[String] = []
	for c: String in ["stand", "prowl", "run", "cover", "catch"]:
		var tm: float = minf(0.3, (v.anims[c] as Animation).length)
		if c == "catch":
			tm = 3.0
		old.hold_clip(c, tm)
		v.hold_clip(c, tm)
		var eo := old.extent()
		var ev := v.extent()
		var mo := old.mask_info()
		var mv := v.mask_info()
		rows.append("%s: old %.2f h x %.2f long x %.2f wide, mask at %.2f m; new %.2f h x %.2f long x %.2f wide, mask at %.2f m" % [
			c, eo.size.y, eo.size.z, eo.size.x, Vector3(mo["at"]).y, ev.size.y, ev.size.z, ev.size.x, Vector3(mv["at"]).y])
		if c == "prowl":
			t.check(ev.size.y < 2.1, "prowl: under the 2.1 m doorways (%.2f m)" % ev.size.y)
			t.check(Vector3(mv["at"]).y < 1.0, "prowl: the mask is low, searching (%.2f m)" % Vector3(mv["at"]).y)
		if c == "stand":
			t.check(ev.size.y < 1.6 and ev.size.y > 1.0, "stand: on all fours, %.2f m high" % ev.size.y)
	for r in rows:
		t.note(r)
	old.free()
	v.free()

## MO2: the face plate is a worn, handled card with the same drawn smiley (build_minder_v2.py paint_face): an
## edge cut by hand (not a true oval), marker-pen line work that thickens and thins, grime in the lower third.
## The face itself is unchanged: two eye holes cut through, a dark smile, the glow map dark where the ink is.
## Texture coordinates here are the build's: u across, v up (the image's rows run down).
func _plate(v: MinderView) -> Array[Image]:
	for s in v.mesh.mesh.get_surface_count():
		var m := v.mesh.mesh.surface_get_material(s) as StandardMaterial3D
		if m and m.resource_name == "Minder_mask":
			var out: Array[Image] = []
			for tex: Texture2D in [m.albedo_texture, m.emission_texture]:
				var img := tex.get_image()
				if img.is_compressed():
					img.decompress()
				out.append(img)
			return out
	return []

func _at(img: Image, u: float, v: float) -> Color:
	var n := img.get_width()
	return img.get_pixel(clampi(int(u * n), 0, n - 1), clampi(int((1.0 - v) * img.get_height()), 0, img.get_height() - 1))

func _lum(c: Color) -> float:
	return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b

func test_v2_plate_is_a_worn_card_with_the_same_smiley(t: T) -> void:
	var v := _view("new")
	var maps := _plate(v)
	v.free()
	t.check(maps.size() == 2, "the plate has its print and its glow map")
	if maps.size() != 2:
		return
	var img: Image = maps[0]
	var glow: Image = maps[1]
	# The same face: eye holes cut through, the card between them, the smile dark and not glowing.
	for e: Vector2 in [Vector2(0.33, 0.62), Vector2(0.67, 0.62)]:
		t.check(_at(img, e.x, e.y).a < 0.5, "an eye hole is cut through at %s" % e)
	t.check(_at(img, 0.5, 0.62).a > 0.5 and _lum(_at(img, 0.5, 0.62)) > 0.5, "pale card between the eyes")
	t.check(_lum(_at(img, 0.5, 0.31)) < 0.3 and _lum(_at(glow, 0.5, 0.31)) < 0.05, "the smile is drawn in dark ink that does not glow")
	# The edge: where the card ends, walking out from the middle, at 90 angles. A true oval would end at the
	# same radius all round (to within a texel or two).
	var lo := INF
	var hi := -INF
	for k in 90:
		var a := TAU * k / 90.0
		var r := 0.30
		while r < 0.495 and _at(img, 0.5 + r * cos(a), 0.5 + r * sin(a)).a > 0.5:  # (the texture ends at 0.5)
			r += 0.002
		lo = minf(lo, r)
		hi = maxf(hi, r)
	t.note("plate edge: from %.3f to %.3f of the card's width out from its middle" % [lo, hi])
	t.check(hi - lo > 0.02, "the edge is cut by hand, not a true oval (%.3f to %.3f)" % [lo, hi])
	# The smile's stroke, measured straight out from its centre: marker pen, thick and thin.
	var thin := INF
	var thick := -INF
	for k in 15:
		var a := deg_to_rad(-90.0 - 35.0 + 70.0 * k / 14.0)
		var ink := 0
		for j in 60:
			var r := 0.19 + 0.12 * j / 60.0
			var c := _at(img, 0.5 + r * cos(a), 0.56 + r * sin(a))
			if c.a > 0.5 and _lum(c) < 0.3:
				ink += 1
		thin = minf(thin, ink)
		thick = maxf(thick, ink)
	t.note("smile stroke: %d to %d steps of 0.002 thick" % [thin, thick])
	t.check(thin > 0 and thick >= 1.5 * thin, "the smile's line thickens and thins like marker pen (%d to %d)" % [thin, thick])
	# Grime where it is held: the bare card in the lower third darker than across the middle.
	var low := []
	var mid := []
	for i in 40:
		for j in 40:
			var u := 0.2 + 0.6 * i / 39.0
			var w := 0.08 + 0.84 * j / 39.0
			var c := _at(img, u, w)
			if c.a < 0.5 or _lum(_at(glow, u, w)) < 0.05:
				continue  # a hole, the outside, or ink
			if w < 0.28:
				low.append(_lum(c))
			elif w > 0.45 and w < 0.75:
				mid.append(_lum(c))
	var ml := 0.0
	var mm := 0.0
	for x: float in low:
		ml += x / low.size()
	for x: float in mid:
		mm += x / mid.size()
	t.note("card brightness: lower third %.2f, middle %.2f" % [ml, mm])
	t.check(low.size() > 50 and mid.size() > 50 and mm - ml > 0.08, "grime in the lower third (%.2f against %.2f)" % [ml, mm])