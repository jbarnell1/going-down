extends RefCounted

const T = preload("res://tests/t.gd")
const Sounds = preload("res://client/garden_sound.gd")
const View = preload("res://client/arboretum_view.gd")
const Keeper = preload("res://client/groundskeeper_view.gd")

func test_recorded_resources_and_loops(t: T) -> void:
	var sounds := Sounds.new()
	for cue: String in ["wind", "crickets", "quiet", "badges_swing", "breath"]:
		var stream := sounds.next(cue)
		if t.check(stream != null, "%s recording imported" % cue):
			t.check(stream.loop, "%s loops in the imported asset" % cue)
	for cue: String in ["step_moss", "step_leaves", "step_gravel", "step_creep", "twig", "badge", "sniff", "shears", "snatch"]:
		var stream := sounds.next(cue)
		if t.check(stream != null, "%s recording imported" % cue):
			t.check(not stream.loop, "%s plays just once" % cue)
	t.check(sounds.next("unrecorded") == null, "missing cues stay silent")

func test_available_takes_cycle(t: T) -> void:
	var sounds := Sounds.new()
	var names := Sounds.names()
	for cue: String in ["step_moss", "step_gravel", "step_leaves", "step_creep", "twig", "badge", "snatch"]:
		var expected := PackedStringArray()
		for name: String in names:
			if name.begins_with(cue + "_"):
				expected.append(name)
		if not t.check(not expected.is_empty(), "%s has at least one take" % cue):
			continue
		var separate := Sounds.new()
		for name: String in expected:
			t.eq(_name(sounds.next(cue)), name, "%s take order" % cue)
		t.eq(_name(sounds.next(cue)), expected[0], "%s wraps to its first available take" % cue)
		t.eq(_name(separate.next(cue)), expected[0], "%s has an independent take order" % cue)

func test_garden_uses_recordings_by_surface(t: T) -> void:
	var view := View.new()
	view._sounds()
	t.eq(view._own.bus, &"Effects", "own steps use Effects")
	t.check(view._step_take("moss", true) == null, "creep on moss is silent")
	t.check(_name(view._step_take("moss", false)).begins_with("step_moss_"), "moss walking plays a moss take")
	t.check(_name(view._step_take("litter", true)).begins_with("step_creep_"), "litter creep has a dedicated take")
	t.check(_name(view._step_take("twig", false)).begins_with("step_leaves_"), "litter under twigs plays a leaf step")
	t.check(_name(view._step_take("gravel", true)).begins_with("step_gravel_"), "gravel creep keeps the surface sound")
	for cue: String in ["wind", "crickets", "quiet"]:
		var bed: AudioStreamPlayer = view._amb.get(cue)
		if t.check(bed != null, "%s has a bed player" % cue):
			t.eq(bed.bus, &"Ambience", "%s uses the duckable bus" % cue)
			t.eq(_name(bed.stream), cue, "%s has its own recorded bed" % cue)
	view.free()

func test_keeper_recordings_use_their_effect_buses(t: T) -> void:
	var keeper := Keeper.new()
	keeper._build()
	t.eq(keeper._clinks[0].bus, &"Entity", "moving badges use Entity")
	t.eq(_name(keeper._breath.stream), "breath", "near breath loads the owner's take")
	t.eq(_name(keeper._swing_snd.stream), "badges_swing", "lean uses the keeper's badges")
	t.eq(keeper._sniff.bus, &"Entity", "the lean sniff uses Entity")
	t.eq(keeper._snatch.bus, &"Scare", "the catch uses Scare")
	keeper.free()

func test_strike_playback_meets_blade_contact(t: T) -> void:
	for impact: float in [Keeper.SNATCH_IMPACT, Keeper.SHEARS_IMPACT]:
		var start := 0.20 - impact
		t.check(Keeper.strike_playhead(start - 0.010, impact) < 0.0, "early snapshot waits for the lead-in")
		t.check(is_zero_approx(Keeper.strike_playhead(start, impact)), "on-time snapshot plays the whole lead-in")
		t.check(is_equal_approx(Keeper.strike_playhead(0.15, impact), 0.15 - start), "sparse snapshot skips elapsed lead-in")
		t.check(is_equal_approx(Keeper.strike_playhead(0.29, impact), impact - 0.015), "late snapshot keeps the contact transient")

func _name(stream: AudioStream) -> String:
	return stream.resource_path.get_file().get_basename() if stream != null else ""

func test_keeper_blender_clips_follow_the_host(t: T) -> void:
	var keeper := Keeper.new()
	keeper._build()
	if not t.check(keeper._rig != null and keeper._player != null, "the keeper has its Blender skeleton and animations"):
		keeper.free()
		return
	var clips := Keeper.CLIPS.values()
	clips.append(&"recover")
	for clip: StringName in clips:
		t.check(keeper._player.has_animation(clip), "%s is in the shipped rig" % clip)
	t.check(keeper._head >= 0 and keeper._shears >= 0 and keeper._badges >= 0, "breath, shears and badges have distinct rig anchors")
	var look := keeper.look()
	for key: String in ["glow", "unshaded"]:
		t.eq(look[key], false, "the resident has no %s" % key)
	for key: String in ["passes", "overlays", "lights"]:
		t.eq(look[key], 0, "the resident has no extra %s" % key)
	t.eq(Keeper._clip_time(&"lean", 2.85, 3.0, 0.0), 2.5, "the extra beat holds the same lean pose")
	t.eq(Keeper._clip_time(&"walk", 0.15, 0.48, 1.3), 0.24, "the first step crosses the middle of the walk cycle")
	t.eq(Keeper._clip_time(&"snatch", 0.20, 0.64, 0.0), 0.20, "strike contact is sampled directly at host time")
	t.eq(Keeper.CLIPS["catch"], &"snatch", "the host catch samples the snatch clip")

	if keeper._player.has_animation(&"snatch"):
		var strike := keeper._player.get_animation(&"snatch")
		t.check(keeper._rig.find_bone("Blade.A") >= 0, "one blade stays fixed at the grip")
		var track := _bone_rotation_track(strike, "Blade.B")
		if t.check(track >= 0, "the moving blade has a rotation track"):
			var open := strike.rotation_track_interpolate(track, 0.14)
			var contact := strike.rotation_track_interpolate(track, Keeper.BLADE_CONTACT)
			var recoil := strike.rotation_track_interpolate(track, 0.28)
			t.check(open.angle_to(contact) > 0.15, "the shears close in time for the strike recording")
			t.check(contact.angle_to(recoil) < 0.04, "the shears remain closed during recoil")
	keeper.free()

func _bone_rotation_track(clip: Animation, bone: String) -> int:
	for track in clip.get_track_count():
		if clip.track_get_type(track) == Animation.TYPE_ROTATION_3D and str(clip.track_get_path(track).get_concatenated_subnames()) == bone:
			return track
	return -1
