# Measures how smoothly the Temp's figure (client/temp_view.gd) is drawn, frame by frame (PT4: the owner saw
# it "jank around when he moves. A LOT of flickering"). Feed it the view after every show_pose; it records the
# clip the mixer samples, the drawn root and yaw, visibility, and the rotation of a few joints, and sums up:
#   clip_switches   times the sampled clip changed while the pose stayed a walk (walk <-> chase)
#   flips           of those, switches within FLIP_WINDOW s of host time after the previous one (back and forth)
#   bone_snaps      frames on which a tracked joint turned more than SNAP_DEG in one frame (a pose that jumps)
#   max_bone_deg    the largest such per-frame turn, degrees
#   reversals       frames whose drawn step points back against the previous step (both over 1 mm)
#   yaw_jumps       frames on which the drawn yaw changed by more than YAW_JUMP radians
#   vis_toggles     changes of visibility
# Host time comes from the pose's own clock (animTime) plus a running offset across anim changes.
# Used by tools/temp_jitter.gd (the numbers for a report) and tests/test_temp_motion.gd (the guard).
extends RefCounted

const FLIP_WINDOW := 0.5
const SNAP_DEG := 25.0
const YAW_JUMP := 0.35
const JOINTS: Array[String] = ["Hips", "LeftUpLeg", "RightUpLeg", "LeftLeg", "RightLeg", "Spine1", "LeftArm", "RightArm"]

var frames := 0
var walk_frames := 0
var clip_switches := 0
var flips := 0
var bone_snaps := 0
var max_bone_deg := 0.0
var worst_joint := ""
var reversals := 0
var yaw_jumps := 0
var vis_toggles := 0
var clips := {}   # clip name -> frames sampled
## What happened, one line per clip switch and per snap (for reading, not for checks).
var log := PackedStringArray()
var _prev_clip := &""

var _skel: Skeleton3D
var _ap: AnimationPlayer
var _idx: Array[int] = []
var _last_rot: Array[Quaternion] = []
var _last_clip := &""
var _last_switch_t := -INF
var _last_pos := Vector3.INF
var _last_step := Vector3.ZERO
var _last_yaw := INF
var _last_vis: Variant = null
var _t := 0.0
var _last_anim_t := 0.0

func _init(view: Node3D) -> void:
	_skel = view.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	_ap = view.find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer
	for want in JOINTS:
		for i in _skel.get_bone_count():
			var n := _skel.get_bone_name(i)
			if n.ends_with(want):
				_idx.append(i)
				break

## After view.show_pose(pose, show).
func feed(view: Node3D, pose: Variant) -> void:
	frames += 1
	if view.visible != _last_vis and _last_vis != null:
		vis_toggles += 1
	_last_vis = view.visible
	if pose == null:
		return
	var pd: Dictionary = pose
	var at := float(pd["animTime"])
	_t += maxf(0.0, at - _last_anim_t) if at >= _last_anim_t else 0.0
	_last_anim_t = at
	var anim := str(pd["anim"])
	var walking := anim == "walk" or anim == "duck"
	var clip: StringName = _ap.assigned_animation
	_prev_clip = _last_clip
	clips[clip] = int(clips.get(clip, 0)) + 1
	if walking:
		walk_frames += 1
		if _last_clip != &"" and clip != _last_clip and (_last_clip == &"walk" or _last_clip == &"chase"):
			clip_switches += 1
			log.append("t=%.2f switch %s->%s anim %s at %.3f pos %.2f,%.2f mix %s" % [_t, _last_clip, clip, anim, at, float(pd["x"]), float(pd["z"]), str(view.get("_chase_w"))])
			if _t - _last_switch_t < FLIP_WINDOW:
				flips += 1
			_last_switch_t = _t
	_last_clip = clip
	var rots: Array[Quaternion] = []
	for i in _idx:
		rots.append(_skel.get_bone_global_pose(i).basis.get_rotation_quaternion())
	if _last_rot.size() == rots.size():
		var worst := 0.0
		var which := ""
		for j in rots.size():
			var turn := rad_to_deg(_last_rot[j].angle_to(rots[j]))
			if turn > worst:
				worst = turn
				which = _skel.get_bone_name(_idx[j])
		if worst > max_bone_deg:
			max_bone_deg = worst
			worst_joint = "%s (%s)" % [which, clip]
		if worst > SNAP_DEG:
			bone_snaps += 1
			log.append("t=%.2f snap %.1f deg %s anim %s at %.3f clip %s (was %s) step %.3f m" % [_t, worst, which, anim, at, clip, _prev_clip,
				Vector2(view.position.x - _last_pos.x, view.position.z - _last_pos.z).length() if _last_pos != Vector3.INF else 0.0])
	_last_rot = rots
	var p := view.position
	if _last_pos != Vector3.INF:
		var step := Vector3(p.x - _last_pos.x, 0.0, p.z - _last_pos.z)
		if step.length() > 0.001 and _last_step.length() > 0.001 and step.dot(_last_step) < 0.0:
			reversals += 1
		if step.length() > 0.001:
			_last_step = step
	_last_pos = p
	var yaw := view.rotation.y
	if _last_yaw != INF and absf(angle_difference(_last_yaw, yaw)) > YAW_JUMP:
		yaw_jumps += 1
	_last_yaw = yaw

## Host seconds walked (approximately), for rates.
func seconds() -> float:
	return _t

func line(what: String) -> String:
	var s := maxf(_t, 0.001)
	return "%s: frames %d (walking %d) over %.1f s; clip switches %d (%.2f/s), flips %d; bone snaps %d, max joint turn %.1f deg/frame %s; reversals %d; yaw jumps %d; visibility toggles %d; clips %s" % [
		what, frames, walk_frames, _t, clip_switches, clip_switches / s, flips, bone_snaps, max_bone_deg, worst_joint, reversals, yaw_jumps, vis_toggles, str(clips)]
