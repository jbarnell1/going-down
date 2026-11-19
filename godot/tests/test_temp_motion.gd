# The Temp drawn in motion (PT4). The owner, on build 9bf81be: "Annex - the temp really really janks around when
# he moves. A LOT of flickering." The cause: client/temp_view.gd chose between its slow and fast walk from one
# frame's step over one frame's clock, both rounded (to the centimetre and the millisecond, net/pose.gd), so at
# Lonely's approach pace (2.0 m/s, between the two thresholds) and alone at its chase (2.6) the clip flipped on
# most frames, each flip a joint jump of up to 90 degrees. Here the client's own pipeline (tools/temp_jitter.gd:
# 20 Hz snapshots through Pose.lerp_pose, drawn at 60 and 144 frames a second) is measured by tools/temp_meter.gd.
#
# The deliberate break: in temp_view.gd show_pose, judge the pace from the frame's own step again
# (`var speed := step / maxf(clock_step, 0.001)` for `var speed := _trail_speed()`): steady_pace_keeps_one_gait
# goes red. test_the_meter_sees_the_old_flicker proves the measure itself is not vacuous.
extends RefCounted

const T = preload("res://tests/t.gd")
const View = preload("res://client/temp_view.gd")
const Jitter = preload("res://tools/temp_jitter.gd")
const Meter = preload("res://tools/temp_meter.gd")

func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree

func _pose(x: float, z: float, anim: String, at: float) -> Dictionary:
	return {"x": x, "y": 0.0, "z": z, "level": 0, "yaw": PI, "anim": anim, "animTime": at}

func test_steady_pace_keeps_one_gait(t: T) -> void:
	for fps: float in [60.0, 144.0]:
		for pace: float in [2.0, 2.6, 3.9]:
			var m := Jitter.run_line(_tree(), pace, fps, 8.0)
			var what := "%.1f m/s at %d fps" % [pace, int(fps)]
			t.check(m.walk_frames > 400, "%s: it walked (%d frames)" % [what, m.walk_frames])
			t.check(m.clip_switches <= 1 and m.flips == 0, "%s: one gait, no flicker (%d switches, %d back and forth)" % [what, m.clip_switches, m.flips])
			t.eq(m.bone_snaps, 0, "%s: no joint jumps more than %d degrees in a frame (worst %.1f, %s)" % [what, int(Meter.SNAP_DEG), m.max_bone_deg, m.worst_joint])
			t.eq(m.reversals, 0, "%s: the drawn position never steps backwards" % what)

func test_the_meter_sees_the_old_flicker(t: T) -> void:
	var m := Jitter.run_line(_tree(), 2.0, 144.0, 4.0, 11, func(v: TempView) -> void: v.break_frame_speed = true)
	t.check(m.flips > 50 and m.bone_snaps > 50, "judged per frame, the gait flickers (%d flips, %d joint jumps)" % [m.flips, m.bone_snaps])

func test_change_of_pace_blends(t: T) -> void:
	# A creep, its chase, then the slow walk again (the rules' paces: 1.3, 2.6, 1.0 at a corner and after).
	var m := Jitter.run_line(_tree(), [[0.0, 1.3], [3.0, 2.6], [6.0, 1.0]], 60.0, 9.0)
	t.eq(m.clip_switches, 2, "slow, fast, slow: two changes of gait")
	t.eq(m.flips, 0, "no change undone within half a second")
	t.eq(m.bone_snaps, 0, "each change blends (worst joint turn %.1f deg/frame, %s)" % [m.max_bone_deg, m.worst_joint])

func test_starting_stopping_and_fidgeting_fade(t: T) -> void:
	var v := View.new()
	_tree().root.add_child(v)
	var m := Meter.new(v)
	var clock := 12.5
	var x := 0.0
	var dt := 1.0 / 60.0
	# Stands across the idle clip's end (13.97 s: the look clip starts), walks off at 2.0 m/s, stops.
	for i in 150:
		clock += dt
		var p := _pose(x, 0.0, "idle", snappedf(clock, 0.001))
		v.show_pose(p, true)
		m.feed(v, p)
	for i in 90:
		clock += dt
		x += 2.0 * dt
		var p := _pose(snappedf(x, 0.01), 0.0, "walk", snappedf(clock, 0.001))
		v.show_pose(p, true)
		m.feed(v, p)
	for i in 60:
		clock += dt
		var p := _pose(snappedf(x, 0.01), 0.0, "idle", snappedf(clock, 0.001))
		v.show_pose(p, true)
		m.feed(v, p)
	t.check(m.clips.has(&"look") and m.clips.has(&"walk"), "it fidgeted and walked (%s)" % str(m.clips))
	t.eq(m.bone_snaps, 0, "no joint jumps at the fidget's change, the start or the stop (worst %.1f deg/frame, %s)" % [m.max_bone_deg, m.worst_joint])
	v.free()

func test_a_held_pose_mid_fade_is_drawn_still(t: T) -> void:
	var v := View.new()
	_tree().root.add_child(v)
	var clock := 1.0
	var x := 0.0
	var p := {}
	# Walk at 2.6 m/s until the gaits are part way blended, then the same pose again and again.
	for i in 200:
		clock += 0.01
		x += 0.026
		p = _pose(snappedf(x, 0.01), 0.0, "walk", snappedf(clock, 0.001))
		v.show_pose(p, true)
		if v._chase_w > 0.2 and v._chase_w < 0.8:
			break
	t.check(v._chase_w > 0.2 and v._chase_w < 0.8, "caught between the gaits (%.2f)" % v._chase_w)
	var mid := v.drawn_signature()
	for i in 20:
		v.show_pose(p.duplicate(), true)
	t.eq(v.drawn_signature(), mid, "held between the gaits: drawn exactly the same")
	# It stops: hold the first standing pose while the walk is still fading out.
	p = _pose(snappedf(x, 0.01), 0.0, "idle", snappedf(clock + 0.05, 0.001))
	v.show_pose(p, true)
	t.check(v._carry_left > 0.0, "the stop is fading in")
	var stopping := v.drawn_signature()
	for i in 20:
		v.show_pose(p.duplicate(), true)
	t.eq(v.drawn_signature(), stopping, "held while it stops: drawn exactly the same")
	v.free()
