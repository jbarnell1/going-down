# The Orderly on screen: the model (assets/entities/orderly.glb, from Blender) posed every frame
# exactly as the frame says to draw it: feet position, facing, clip and clip time. In the dark it is
# drawn as it is, with nothing added (net/client.gd draw_in_dark, T20a): the dark lighting hides it.
# Like src/render/entityView.ts: walking clips run on the distance walked (so a creep is a slow stride),
# the reach is stretched over the wind-up. It casts shadows and stands on the floor. Bent
# over a downed player (pose "bend") it folds down over them, arms out, its head working (_show_bend).
#
# The watched walk (two-watcher Stillness, docs/floors/traits-and-hiding.md section 1; T19a): while it needs
# two watchers and has one, set_watched gives that watcher's eye point (null otherwise), and its walk has its
# head locked on them and only its right hand on the trolley, the left hanging at its side. Only while it
# walks, and never while it is held (the frame gives no watcher then), so a held figure is drawn exactly the
# same on every frame.
class_name OrderlyView
extends Node3D

const Floor = preload("res://sim/floor.gd")
const Furniture = preload("res://sim/furniture.gd")
const Move = preload("res://sim/move.gd")
const TROLLEY = preload("res://assets/props/orderly_trolley.glb")
## Covers the cart's horizontal corners and a margin for the drawn wall thickness.
const TROLLEY_RADIUS := 0.48
const TROLLEY_PUSH := 0.84
const TROLLEY_PARK := 1.52
var floor_plan: Floor.FloorPlan

const WALK_RATE := 1.7          # src/render/entityView.ts
const WIND_UP_TIME := 0.6       # src/sim/entity.ts (the reach clip is drawn out over it)
const HUNT_SPEED := 3.7         # src/sim/entity.ts (stride clock)
## The bend over a downed player: seconds to fold down, and how often the head works down and up.
const BEND_IN := 0.8
const CHEW_HZ := 1.4
const DANCE_AFTER := BEND_IN + 0.35  # let the full bend read before starting the optional gag
const DANCE_BLEND := 0.45
## The second model (figures=new) folds its spine this much further over a downed player (measured: its head
## then comes as low over the face as today's does).
const BEND_GAIN_V2 := 1.2
const BEND_KNEE_V2 := 1.25
const ROAR_BONES := ["spine", "spine1", "spine2", "neck", "head"]
## The watched walk: how far the head may turn from the body (radians), shared neck / head; the left
## upper arm's twist (radians about its own length) that swings the bent forearm down off the trolley
## handle to hang by its hip (measured on the model: the hand drops from the handle to hip height).
const WATCH_TURN_MAX := 1.4
const WATCH_NECK_SHARE := 0.4
const WATCH_ARM_DROP := 1.15

var model: Node3D
var ap: AnimationPlayer
var skel: Skeleton3D = null
## How far into the bend it is drawn now (0..1; tests).
var bend := 0.0
var bellydance_on_catch: bool = false
var _bent := false
var clips := []
var drawn := {}
## The one watcher's eye point it walks at (world [x, y, z] or Vector3), or null.
var watched_at: Variant = null
var _stride := 0.0
var _last := Vector3.INF
var _skel: Skeleton3D = null
var _twist := {}  # bone index -> [the rotation set, the change made]
var trolley: Node3D
var _squeak_wheel: Node3D
var _grip_left: Node3D
var _grip_right: Node3D
var _trolley_solids: Move.Solids

## Today's model and the second one, made from the Meshy figure (assets_src/blender/orderly/build_orderly_v2.py):
## the same bone names, skirt bones, clip names and clip lengths, the same height and feet. The second is drawn
## unless the game was started with `figures=old` (client/figures.gd), or its file is missing.
const MODEL := "res://assets/entities/orderly.glb"
const MODEL_V2 := "res://assets/entities/orderly_v2.glb"
## Tests: "new" or "old" overrides the shared choice (Figures); "" follows it.
static var figures_override := ""
## This view draws the second model.
var figure_v2 := false

## Whether this run draws the new resident figures (client/figures.gd).
static func new_figures() -> bool:
	if figures_override != "":
		return figures_override == "new"
	return Figures.use_new()

func _ready() -> void:
	figure_v2 = new_figures() and ResourceLoader.exists(MODEL_V2)
	var ps: PackedScene = load(MODEL_V2 if figure_v2 else MODEL)
	model = ps.instantiate()
	add_child(model)
	ap = model.find_child("AnimationPlayer", true, false)
	if ap:
		clips = Array(ap.get_animation_list())
		for n: String in clips:
			# Import quirk: every clip comes in non-looping.
			if n not in ["reach", "mixamo_reach", "mixamo_roar", "bellydance"]:
				ap.get_animation(n).loop_mode = Animation.LOOP_LINEAR
		ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	var sks := model.find_children("*", "Skeleton3D", true, false)
	if not sks.is_empty():
		skel = sks[0] as Skeleton3D
	_skel = sks[0] if not sks.is_empty() else null
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	trolley = TROLLEY.instantiate()
	trolley.name = "Trolley"
	add_child(trolley)
	_squeak_wheel = trolley.find_child("SqueakWheel", true, false)
	_grip_left = trolley.find_child("GripLeft", true, false)
	_grip_right = trolley.find_child("GripRight", true, false)
	visible = false

func reset() -> void:
	_clear_bend()
	_twist.clear()
	_stride = 0.0
	_last = Vector3.INF
	drawn = {}
	watched_at = null
	visible = false

func set_floor(plan: Floor.FloorPlan, pieces: Array[Furniture.Piece]) -> void:
	floor_plan = plan
	_trolley_solids = Furniture.solids_from(plan, pieces) if plan != null else null

## The watched walk: the one watcher's eye point ([x, y, z]), or null for none. Call before show_pose.
func set_watched(at: Variant) -> void:
	if at is Array and (at as Array).size() == 3:
		watched_at = Vector3(float(at[0]), float(at[1]), float(at[2]))
	elif at is Vector3:
		watched_at = at
	else:
		watched_at = null

## Optional catch_active distinguishes an active catch from a held bend after release.
func show_pose(pose: Variant, show: bool) -> void:
	_show_pose(pose, show)
	_pin_lengths()

## Below the hips a bone only turns: its offset from its parent and its scale are the model's own. Hand
## aiming writes global poses through the scaled Mixamo parents, and while the figure stood still the same
## frame was posed again and again, so the error compounded and the arm and fingers grew as you watched
## (the owner's playtest, 19 Nov). The hips keep their pose: the clips move them and the feet are planted on them.
func _pin_lengths() -> void:
	if skel == null:
		return
	for i in skel.get_bone_count():
		if skel.get_bone_parent(i) < 0 or skel.get_bone_name(i) == "hips":
			continue
		var rest := skel.get_bone_rest(i)
		skel.set_bone_pose_position(i, rest.origin)
		skel.set_bone_pose_scale(i, rest.basis.get_scale())

func _show_pose(pose: Variant, show: bool) -> void:
	if pose == null:
		_clear_bend()
		visible = false
		return
	var p := Vector3(float(pose.x), float(pose.y), float(pose.z))
	if _last != Vector3.INF:
		var d := Vector2(p.x - _last.x, p.z - _last.z).length()
		if d < 1.0:
			_stride += d / HUNT_SPEED
	_last = p
	position = p
	rotation = Vector3(0, float(pose.yaw) + PI, 0)
	var level := int(pose.get("level", 0))
	var anim: String = pose.anim
	var t := float(pose.animTime)
	_place_trolley(p, level, anim, t)
	visible = show
	if not show:
		return
	drawn = pose
	model.position = Vector3.ZERO
	var clearance := _wall_pose(p, level)
	if anim == "walk" or anim == "duck":
		t = _stride
	if not ap:
		return
	if anim == "bend":
		var catch_active := bool(pose.get("catch_active", false))
		_show_bend(t, catch_active)
		# Keep the reaching elbows clear until the fold brings them in beside the victim.
		_tuck_arms(clearance.y * (1.0 - smoothstep(BEND_IN * 0.6, BEND_IN, t)))
		if catch_active and bellydance_on_catch and t > DANCE_AFTER and ap.has_animation("bellydance"):
			_show_dance(t - DANCE_AFTER)
		return
	_clear_bend()
	var clip := _clip_for(anim if ap.has_animation(anim) else "idle")
	if not ap.has_animation(clip):
		return
	var dur := ap.get_animation(clip).length
	var ct := t
	if anim == "walk":
		ct = t * WALK_RATE
	elif anim == "reach":
		ct = clampf(t / WIND_UP_TIME, 0.0, 1.0) * dur
	if anim != "reach" and dur > 0.0:
		ct = fmod(ct, dur)
	_seek(clip, ct)
	_watched_walk(anim == "walk" or anim == "duck")
	if clearance.x > 0.0:
		_fold_knees(0.87 * clearance.x)
	_tuck_arms(clearance.y)
	if anim in ["idle", "walk", "duck"] and skel != null:
		var elbow := Vector3(0, -1, -0.55)
		_aim_hand(".R", skel.to_local(_grip_right.global_position), elbow, 1.0)
		if watched_at == null or anim == "idle":
			_aim_hand(".L", skel.to_local(_grip_left.global_position), elbow, 1.0)

## The cart is cosmetic. Fit it through the same walls without changing the
## resident's authoritative position, radius, sight or catch. On release it
## rolls clear ahead of the reach and stays parked through the bend.
func _place_trolley(at: Vector3, level: int, anim: String, time: float) -> void:
	var release := 1.0 if anim == "bend" else (smoothstep(0.0, WIND_UP_TIME, time) if anim == "reach" else 0.0)
	var offset := transform.basis.z * lerpf(TROLLEY_PUSH, TROLLEY_PARK, release)
	if floor_plan == null:
		trolley.position = Vector3(0, 0, offset.length())
	else:
		var from := Move.Body.make(at.x, at.z, level, at.y)
		var cart := Move.move_with_collision(floor_plan, from, offset.x, offset.z, TROLLEY_RADIUS, _trolley_solids)
		trolley.global_position = Vector3(cart.x, cart.y, cart.z)

## Even while the pose is outside the player's view, audio follows its wheel.
func trolley_squeak_at() -> Vector3:
	return _squeak_wheel.global_position

## The x component folds the knees beneath a lintel. The y component brings
## the elbows inside the jamb or wall. Only the child mesh shifts; the host
## position, sight checks and navigation root keep their original coordinates.
func _wall_pose(p: Vector3, level: int) -> Vector2:
	var near_door := 0.0
	var near_wall := 0.0
	var opening := 0.0
	if floor_plan != null:
		var wall_distance := Move.wall_clearance(floor_plan, level, p.x, p.z)
		near_wall = 1.0 - smoothstep(0.55, 1.25, wall_distance)
		for door in floor_plan.doors:
			if door.level != level:
				continue
			var centre := Vector2(door.ax + door.bx + 1, door.ay + door.by + 1) * (0.5 * floor_plan.cell_size)
			var delta := Vector2(p.x, p.z) - centre
			var across := absf(delta.x if door.ax == door.bx else delta.y)
			var proximity := 1.0 - smoothstep(1.15, 1.90, delta.length())
			near_door = maxf(near_door, proximity * (1.0 - smoothstep(0.55, 1.2, across)))
			opening = maxf(opening, proximity * (1.0 - smoothstep(0.26, 0.62, across)))
		var clearance_radius := lerpf(0.65, 0.49, opening)
		if wall_distance < clearance_radius:
			var clear := Move._push_out(floor_plan, level, p.x, p.z, clearance_radius, p.x, p.z)
			model.position = transform.basis.inverse() * Vector3(clear[0] - p.x, 0, clear[1] - p.z)
	return Vector2(near_door, maxf(near_wall, near_door))

func _clip_for(anim: String) -> String:
	var mixed := "mixamo_" + anim
	return mixed if ap.has_animation(mixed) else anim

func _seek(clip: String, t: float) -> void:
	if ap.current_animation != clip:
		ap.play(clip)
	ap.seek(t, true, true)

func _clear_bend() -> void:
	if _bent and skel != null:
		skel.reset_bone_poses()
		ap.stop()
	_bent = false
	bend = 0.0

## Tests: everything about how the figure is drawn that could make it stand out in the dark (T20a: drawn
## as it is, nothing added: no glow, no outline). Per mesh its overrides, overlay, transparency and shadow;
## per surface material whether it glows (emission), ignores the lights (unshaded) or draws a second pass
## (an outline); and any light under the figure. `sig` is all of it in one string: a tools/playthrough.mjs
## check compares it lit and dark, and wants no glow, unshaded surface, outline pass, overlay or light.
func look() -> Dictionary:
	var parts: Array[String] = []
	var glow := 0
	var unshaded := 0
	var passes := 0
	var overlays := 0
	var meshes := 0
	for mi: MeshInstance3D in find_children("*", "MeshInstance3D", true, false):
		meshes += 1
		if mi.material_overlay != null:
			overlays += 1
		parts.append("%s o%s v%s t%.3f s%d" % [mi.name, str(mi.material_override), str(mi.material_overlay), mi.transparency, mi.cast_shadow])
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var m := mi.get_active_material(i)
			parts.append("  %d %s" % [i, str(m)])
			while m != null:
				if m is BaseMaterial3D:
					var bm := m as BaseMaterial3D
					if bm.emission_enabled:
						glow += 1
					if bm.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED:
						unshaded += 1
					parts.append("    e%s %s u%d" % [bm.emission_enabled, str(bm.emission), bm.shading_mode])
				if m.next_pass != null:
					passes += 1
				m = m.next_pass
	var lights := find_children("*", "Light3D", true, false).size()
	return {"meshes": meshes, "glow": glow, "unshaded": unshaded, "passes": passes, "overlays": overlays, "lights": lights,
		"sig": "\n".join(parts).sha256_text().substr(0, 16)}

## Bent over a downed player (sim/entity.gd "bending", pose "bend"; North Star B6: "bends down to your
## face as if it is eating you"). The model has no bend clip: the reach held at its end (the arms out), the
## spine folded forward over BEND_IN seconds of the pose's clock, and the neck and head working down and up
## (the eating) on the same clock, so every screen draws the same bend at the same time.
func _show_bend(t: float, catch_active: bool) -> void:
	var reach := _clip_for("reach")
	if skel == null or not ap.has_animation(reach):
		return
	skel.reset_bone_poses()
	var roar_rotations: Array[Quaternion] = []
	var roar_weight := sin(PI * t / BEND_IN) if catch_active and t > 0.0 and t < BEND_IN else 0.0
	if roar_weight > 0.0 and ap.has_animation("mixamo_roar"):
		_seek("mixamo_roar", t / BEND_IN * ap.get_animation("mixamo_roar").length)
		for bone: String in ROAR_BONES:
			var i := skel.find_bone(bone)
			var rest := skel.get_bone_rest(i).basis.get_rotation_quaternion()
			roar_rotations.append(rest.inverse() * skel.get_bone_pose_rotation(i))
		skel.reset_bone_poses()
	_seek(reach, ap.get_animation(reach).length)
	var k := clampf(t / BEND_IN, 0.0, 1.0)
	var e := k * k * (3.0 - 2.0 * k)
	var chew := 0.5 - 0.5 * cos(t * TAU * CHEW_HZ)
	var angles := [0.34, 0.36, 0.30 + 0.06 * chew, 0.22 + 0.12 * chew, 0.10 + 0.22 * chew]
	# The second model's body is shorter on longer legs: it folds further to bring its face as low.
	var gain := BEND_GAIN_V2 if figure_v2 else 1.0
	for j in ROAR_BONES.size():
		var i := skel.find_bone(ROAR_BONES[j])
		# Positive about the bone's own x folds it forward (the model faces +z; its bones run up y).
		var q := skel.get_bone_pose_rotation(i) * Quaternion(Vector3.RIGHT, float(angles[j]) * e * gain)
		if not roar_rotations.is_empty():
			q *= Quaternion.IDENTITY.slerp(roar_rotations[j], roar_weight * 0.55)
		skel.set_bone_pose_rotation(i, q)
	_rotate_bone("spine", Vector3.RIGHT, 0.55 * e * gain)
	_fold_knees((BEND_KNEE_V2 if figure_v2 else 1.00) * e)
	_brace_hand(".L", e)
	_brace_hand(".R", e)
	_bent = true
	bend = e

## Fold the thighs towards the chest and the shins back under them. Compensate at
## the hips for the change in ankle height so the feet keep the clip's floor contact.
func _fold_knees(angle: float) -> void:
	var lowest := INF
	for side: String in [".L", ".R"]:
		var foot := skel.find_bone("foot" + side)
		lowest = minf(lowest, skel.get_bone_global_pose(foot).origin.y)
	for side: String in [".L", ".R"]:
		_rotate_bone("skirt.F" + side, Vector3.RIGHT, -angle)
		_rotate_bone("skirt.B" + side, Vector3.RIGHT, angle)
		_rotate_bone("thigh" + side, Vector3.RIGHT, -angle)
		_rotate_bone("shin" + side, Vector3.RIGHT, 2.0 * angle)
		_rotate_bone("foot" + side, Vector3.RIGHT, -angle)
	var feet_y := minf(skel.get_bone_global_pose(skel.find_bone("foot.L")).origin.y,
		skel.get_bone_global_pose(skel.find_bone("foot.R")).origin.y)
	var hips := skel.find_bone("hips")
	skel.set_bone_pose_position(hips, skel.get_bone_pose_position(hips) + Vector3.UP * (lowest - feet_y))

func _rotate_bone(bone: String, axis: Vector3, angle: float) -> void:
	var index := skel.find_bone(bone)
	var pose := skel.get_bone_global_pose(index)
	pose.basis = Basis(axis, angle) * pose.basis
	skel.set_bone_global_pose(index, pose)
	# Writing a global pose through the scaled Mixamo parents leaves a little scale in the local pose,
	# and the clips do not key scale, so it compounded every frame: the arm and fingers grew without
	# end (the owner's playtest, 19 Nov). Only a rotation is meant here; keep the bone's rest scale.
	skel.set_bone_pose_scale(index, skel.get_bone_rest(index).basis.get_scale())

## Brace the hands to either side of the prone face. Solve the two bones using
## their lengths in the approved reach, blending from that reach as the knees fold.
func _brace_hand(side: String, weight: float) -> void:
	if weight <= 0.0:
		return
	var shoulder := skel.get_bone_global_pose(skel.find_bone("upperarm" + side)).origin
	_aim_hand(side, Vector3(shoulder.x, 0.46, 0.76), Vector3(0, 0.65, -1), weight)

func _aim_hand(side: String, target: Vector3, elbow_hint: Vector3, weight: float) -> void:
	var shoulder := skel.get_bone_global_pose(skel.find_bone("upperarm" + side)).origin
	var elbow := skel.get_bone_global_pose(skel.find_bone("forearm" + side)).origin
	var wrist := skel.get_bone_global_pose(skel.find_bone("hand" + side)).origin
	var axis := (target - shoulder).normalized()
	var upper := shoulder.distance_to(elbow)
	var lower := elbow.distance_to(wrist)
	var reach := clampf(shoulder.distance_to(target), absf(upper-lower)+0.001, upper+lower-0.001)
	var along := (upper*upper - lower*lower + reach*reach) / (2.0*reach)
	var pole := elbow_hint.slide(axis).normalized()
	var desired_elbow := axis * along + pole * sqrt(maxf(0.0, upper*upper-along*along))
	_aim_limb("upperarm" + side, "forearm" + side, desired_elbow, weight)
	elbow = skel.get_bone_global_pose(skel.find_bone("forearm" + side)).origin
	_aim_limb("forearm" + side, "hand" + side, target-elbow, weight)

## Draw elbows in near a jamb, with the clip's original arm lengths.
func _tuck_arms(weight: float) -> void:
	if weight <= 0.0:
		return
	for side: String in [".L", ".R"]:
		_aim_limb("upperarm" + side, "forearm" + side, Vector3(0, -0.95, -0.20), weight)
		_aim_limb("forearm" + side, "hand" + side, Vector3(0, 0.12, 0.99), weight)

func _aim_limb(parent: String, child: String, direction: Vector3, weight: float) -> void:
	var a := skel.get_bone_global_pose(skel.find_bone(parent)).origin
	var b := skel.get_bone_global_pose(skel.find_bone(child)).origin
	var turn := Quaternion((b-a).normalized(), direction.normalized())
	var angle := turn.get_angle()
	if angle > 0.00001:
		# Extracting the axis from a small turn can lose precision near the identity.
		var axis := turn.get_axis().normalized()
		if not axis.is_zero_approx():
			_rotate_bone(parent, axis, angle * weight)

## The shared catch clock advances the dance. Blend up from the already completed bend.
func _show_dance(t: float) -> void:
	if skel == null:
		return
	var folded: Array[Transform3D] = []
	for i in skel.get_bone_count():
		folded.append(skel.get_bone_pose(i))
	skel.reset_bone_poses()
	_seek("bellydance", minf(t, ap.get_animation("bellydance").length))
	var blend := smoothstep(0.0, DANCE_BLEND, t)
	for i in skel.get_bone_count():
		skel.set_bone_pose(i, folded[i].interpolate_with(skel.get_bone_pose(i), blend))

## The watched walk on top of the clip just posed: the head turned to the watcher, the left arm down. With
## no watcher (or not walking) every bone is as the clip left it.
func _watched_walk(walking: bool) -> void:
	if _skel == null:
		return
	var on := walking and watched_at is Vector3
	var turn := 0.0
	if on:
		# Its own frame (it stands straight in the world: a SubViewport child).
		var local := transform.affine_inverse() * (watched_at as Vector3)
		turn = clampf(atan2(local.x, local.z), -WATCH_TURN_MAX, WATCH_TURN_MAX)
	# The second model's neck is one bone (Mixamo's): it takes the neck's share itself.
	_twist_bone("neck1" if _skel.find_bone("neck1") >= 0 else "neck", Vector3.UP, turn * WATCH_NECK_SHARE)
	_twist_bone("head", Vector3.UP, turn * (1.0 - WATCH_NECK_SHARE))
	_twist_bone("upperarm.L", Vector3.UP, WATCH_ARM_DROP if on else 0.0)

## Turns one bone by `angle` about its own `axis`, on top of what the clip set this frame (a bone the
## clip does not key would otherwise keep last frame's turn: that is taken off first).
func _twist_bone(bone_name: String, axis: Vector3, angle: float) -> void:
	var b := _skel.find_bone(bone_name)
	if b < 0:
		return
	var cur := _skel.get_bone_pose_rotation(b)
	if _twist.has(b) and cur.is_equal_approx(_twist[b][0]):
		cur = cur * (_twist[b][1] as Quaternion).inverse()
	var delta := Quaternion(axis, angle) if absf(angle) > 1e-6 else Quaternion.IDENTITY
	var out := cur * delta
	_skel.set_bone_pose_rotation(b, out)
	_twist[b] = [out, delta]

# --- A second Orderly's own sounds (T9b) ------------------------------------------------------------------
# The first Orderly's sounds are client/sfx.gd's. A second Orderly (sim/run.gd second_orderly) carries its own
# here, on the Entity bus, from the same recordings and on the same curves (Sfx's): the trolley's squeak and roll
# from the rules' audibility (only while it moves unseen; through a wall duller and MUFFLED_DB louder, by its own
# low-pass rather than the Trolley bus the first one switches), its slow breath and its throat rattle only on the
# listener's storey and near (breath_db), never while it is held, and the quick breath as a wind-up starts.

var _voice_on := false
var _v_wheel: AudioStreamPlayer3D
var _v_roll: AudioStreamPlayer3D
var _v_breath: AudioStreamPlayer3D
var _v_rattle: AudioStreamPlayer3D
var _v_quick: AudioStreamPlayer3D
var _v_rattle_in := 10.0
var _v_prev_mode := ""
var _v_rng := RandomNumberGenerator.new()

func _voice_player(path: String, loop: bool) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	var file := Sfx.DIR + path + ".ogg"
	if ResourceLoader.exists(file):
		var st := load(file) as AudioStreamOggVorbis
		if st != null:
			st.loop = loop
			p.stream = st
	p.bus = "Entity"
	p.max_db = 0.0
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
	add_child(p)
	return p

func _voice_loop(p: AudioStreamPlayer3D, on: bool, db: float) -> void:
	if p.stream == null:
		return
	if on:
		p.volume_db = db
		if not p.playing:
			p.play()
	elif p.playing:
		p.stop()

## Whether the voice's loops are playing now (tests): [wheels, breath].
func voice_playing() -> Array:
	return [_v_wheel != null and _v_wheel.playing, _v_breath != null and _v_breath.playing]

## Per frame, for a second Orderly only. `o`: {pose (as drawn, or null), held (frozen or seen on this screen), taken,
## mode, moving, speed, squeak {gain, muffled}}; `ear`: the camera. An empty `o` silences it.
func voice(delta: float, o: Dictionary, ear: Vector3) -> void:
	if not _voice_on:
		_voice_on = true
		_v_wheel = _voice_player("orderly/trolley_squeak", true)
		_v_roll = _voice_player("orderly/trolley_roll", true)
		_v_breath = _voice_player("orderly/breath_slow", true)
		_v_rattle = _voice_player("orderly/rattle", false)
		_v_quick = _voice_player("orderly/breath_quick", false)
	var pose: Variant = o.get("pose")
	if pose == null:
		for p: AudioStreamPlayer3D in [_v_wheel, _v_roll, _v_breath]:
			_voice_loop(p, false, 0.0)
		_v_prev_mode = ""
		return
	var pd: Dictionary = pose
	var feet := Vector3(float(pd["x"]), float(pd["y"]), float(pd["z"]))
	var held := bool(o.get("held", false)) or bool(o.get("taken", false))
	var sq: Dictionary = o.get("squeak", {})
	var g := clampf(float(sq.get("gain", 0.0)), 0.0, 1.0)
	var wheels := g > 0.0 and not held
	var muffled := wheels and bool(sq.get("muffled", false))
	var at: Vector3 = trolley_squeak_at() if _squeak_wheel != null and trolley != null and trolley.visible else feet + Vector3(0.0, 0.4, 0.0)
	_v_wheel.global_position = at
	_v_roll.global_position = at
	var cut := 1500.0 if muffled else 20500.0
	_v_wheel.attenuation_filter_cutoff_hz = cut
	_v_roll.attenuation_filter_cutoff_hz = cut
	var wdb := Sfx.BASE_DB + Sfx.APPROACH_DB - 3.0 * (1.0 - g) + (Sfx.MUFFLED_DB if muffled else 0.0)
	var pitch := clampf(0.75 + 0.25 * float(o.get("speed", Sfx.HUNT_SPEED)) / Sfx.HUNT_SPEED, 0.8, 1.05)
	_v_wheel.pitch_scale = pitch
	_v_roll.pitch_scale = pitch
	_voice_loop(_v_wheel, wheels, wdb)
	_voice_loop(_v_roll, wheels, wdb - 4.0)
	# Breath and rattle: on the listener's storey only, near, never while held.
	var head := feet + Vector3(0.0, 2.2, 0.0)
	var same_storey := Sfx.storey_of_eye(ear.y) == Sfx.storey_of_feet(feet.y)
	var d := ear.distance_to(head)
	var bdb := Sfx.breath_db(d, wheels) if same_storey else Sfx.SILENT_DB - 1.0
	_v_breath.global_position = head
	_v_breath.attenuation_filter_cutoff_hz = Sfx._far_cutoff(d)
	_voice_loop(_v_breath, not held and bdb > Sfx.SILENT_DB, Sfx.BASE_DB + bdb)
	var mode := str(o.get("mode", ""))
	if mode == "windUp" and _v_prev_mode != "windUp" and not held and _v_quick.stream != null:
		_v_quick.global_position = head
		_v_quick.volume_db = Sfx.BASE_DB
		_v_quick.play()
	_v_prev_mode = mode
	if not held and same_storey and d < Sfx.RATTLE_FAR and _v_rattle.stream != null:
		_v_rattle_in -= delta
		if _v_rattle_in <= 0.0:
			var rdb := Sfx.breath_db(d, wheels, "rattle")
			if rdb > Sfx.SILENT_DB:
				_v_rattle.global_position = head
				_v_rattle.volume_db = Sfx.BASE_DB + rdb
				_v_rattle.play()
			_v_rattle_in = _v_rng.randf_range(Sfx.RATTLE_EVERY.x, Sfx.RATTLE_EVERY.y)

# --- A second Orderly's look (T9b) ------------------------------------------------------------------------
# The owner (19 Nov): "the second resident should look slightly different (same skeleton is fine, but features
# darker/lighter, different colors, etc)". Same model, skeleton and clips; only its own copy of the material, with
# its own copy of the atlas (sim-free, never the shared resource, the .glb or the Blender source): the gown's
# patches of the atlas (assets_src/blender/orderly/build_orderly.py REG: gown, gown_top, gown_in, the torn strips,
# holes and dirty edges) multiplied by SECOND_GOWN, darker and browner, a dirtier gown; the skin's patches (skin,
# skin_lo, skin_hi, bruise, skin_dk and the sewn lids' socket) turned SECOND_SKIN_GREY of the way to their own grey
# and then SECOND_SKIN_PALE of the way to SECOND_SKIN_TO, paler and greyer. The mask and its printed face, the cap,
# the band, the ink, the tie and the nails stay exactly as they are. Alpha is never touched (the torn cloth keeps its
# holes). The tinted atlas is made once per run of the game and shared by every second view.

const SECOND_GOWN := Color(0.55, 0.5, 0.42)
const SECOND_SKIN_GREY := 0.6
const SECOND_SKIN_PALE := 0.3
const SECOND_SKIN_TO := Color(0.86, 0.86, 0.84)
## The patches, as Godot's UV rectangles [u0, v0, u1, v1] (v down: Blender's v flipped by the glTF export).
const SECOND_GOWN_UV: Array = [[0.5, 0.0, 1.0, 0.5], [0.75, 0.5, 1.0, 0.625], [0.375, 0.75, 0.875, 1.0],
	[0.0, 0.75, 0.25, 0.875], [0.875, 0.875, 1.0, 1.0]]
const SECOND_SKIN_UV: Array = [[0.0, 0.5, 0.25, 0.75], [0.25, 0.5, 0.5, 0.75], [0.875, 0.75, 1.0, 0.875]]

static var _second_atlas: Texture2D = null
static var _second_from: Texture2D = null
## This view wears the second Orderly's look (use_second_look).
var second_look := false

## The second Orderly's look on this view only (see above). Call once it is in the tree.
func use_second_look() -> void:
	second_look = true
	if model == null:
		return
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		for i in mi.mesh.get_surface_count():
			var base := mi.get_active_material(i) as StandardMaterial3D
			if base == null:
				continue
			var m := base.duplicate() as StandardMaterial3D
			m.resource_name = base.resource_name + "_second"
			if figure_v2:
				# The Meshy texture has no atlas patches to tint: the whole figure darker and browner instead.
				m.albedo_color = base.albedo_color * SECOND_GOWN.lerp(Color.WHITE, 0.35)
				mi.set_surface_override_material(i, m)
				continue
			var tex := second_atlas(base.albedo_texture)
			if tex != null:
				m.albedo_texture = tex
			else:
				m.albedo_color = base.albedo_color * SECOND_GOWN
			mi.set_surface_override_material(i, m)

## The atlas `from` with the second Orderly's tint (see above), made once; null when its pixels cannot be read.
static func second_atlas(from: Texture2D) -> Texture2D:
	if from == null:
		return null
	if _second_atlas != null and _second_from == from:
		return _second_atlas
	var img := from.get_image()
	if img == null:
		return null
	img = img.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	img.clear_mipmaps()
	img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	for r: Array in SECOND_GOWN_UV:
		for y in range(int(r[1] * h), int(r[3] * h)):
			for x in range(int(r[0] * w), int(r[2] * w)):
				var c := img.get_pixel(x, y)
				img.set_pixel(x, y, Color(c.r * SECOND_GOWN.r, c.g * SECOND_GOWN.g, c.b * SECOND_GOWN.b, c.a))
	for r: Array in SECOND_SKIN_UV:
		for y in range(int(r[1] * h), int(r[3] * h)):
			for x in range(int(r[0] * w), int(r[2] * w)):
				var c := img.get_pixel(x, y)
				var g := c.r * 0.299 + c.g * 0.587 + c.b * 0.114
				var grey := Color(c.r, c.g, c.b).lerp(Color(g, g, g), SECOND_SKIN_GREY).lerp(SECOND_SKIN_TO, SECOND_SKIN_PALE)
				img.set_pixel(x, y, Color(grey.r, grey.g, grey.b, c.a))
	img.generate_mipmaps()
	_second_atlas = ImageTexture.create_from_image(img)
	_second_from = from
	return _second_atlas
