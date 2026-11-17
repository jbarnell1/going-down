# The Orderly on screen: the model (assets/entities/orderly.glb, from Blender) posed every frame
# exactly as rules_bridge says to draw it: feet position, facing, clip and clip time. Never drawn in
# the dark. Like src/render/entityView.ts: walking clips run on the distance walked (so a creep is a
# slow stride), the reach is stretched over the wind-up. It casts shadows and stands on the floor.
#
# The watched walk (two-watcher Stillness, docs/floors/traits-and-hiding.md section 1; T19a): while it needs
# two watchers and has one, set_watched gives that watcher's eye point (null otherwise), and its walk has its
# head locked on them and only its right hand on the trolley, the left hanging at its side. Only while it
# walks, and never while it is held (the frame gives no watcher then), so a held figure is drawn exactly the
# same on every frame.
class_name OrderlyView
extends Node3D

const WALK_RATE := 1.7          # src/render/entityView.ts
const WIND_UP_TIME := 0.6       # src/sim/entity.ts (the reach clip is drawn out over it)
const HUNT_SPEED := 3.7         # src/sim/entity.ts (stride clock)
## The watched walk: how far the head may turn from the body (radians), shared neck / head; the left
## upper arm's twist (radians about its own length) that swings the bent forearm down off the trolley
## handle to hang by its hip (measured on the model: the hand drops from the handle to hip height).
const WATCH_TURN_MAX := 1.4
const WATCH_NECK_SHARE := 0.4
const WATCH_ARM_DROP := 1.15

var model: Node3D
var ap: AnimationPlayer
var clips := []
var drawn := {}
## The one watcher's eye point it walks at (world [x, y, z] or Vector3), or null.
var watched_at: Variant = null
var _stride := 0.0
var _last := Vector3.INF
var _skel: Skeleton3D = null
var _twist := {}  # bone index -> [the rotation set, the change made]

func _ready() -> void:
	var ps: PackedScene = load("res://assets/entities/orderly.glb")
	model = ps.instantiate()
	add_child(model)
	ap = model.find_child("AnimationPlayer", true, false)
	if ap:
		clips = Array(ap.get_animation_list())
		for n: String in clips:
			# Import quirk: every clip comes in non-looping.
			if n != "reach":
				ap.get_animation(n).loop_mode = Animation.LOOP_LINEAR
		ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	var sks := model.find_children("*", "Skeleton3D", true, false)
	_skel = sks[0] if not sks.is_empty() else null
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	visible = false

func reset() -> void:
	_stride = 0.0
	_last = Vector3.INF
	drawn = {}
	watched_at = null
	visible = false

## The watched walk: the one watcher's eye point ([x, y, z]), or null for none. Call before show_pose.
func set_watched(at: Variant) -> void:
	if at is Array and (at as Array).size() == 3:
		watched_at = Vector3(float(at[0]), float(at[1]), float(at[2]))
	elif at is Vector3:
		watched_at = at
	else:
		watched_at = null

## pose: {x, y, z, level, yaw, anim, animTime} or null; show: may it be drawn this frame.
func show_pose(pose: Variant, show: bool) -> void:
	if pose == null:
		visible = false
		return
	var p := Vector3(float(pose.x), float(pose.y), float(pose.z))
	if _last != Vector3.INF:
		var d := Vector2(p.x - _last.x, p.z - _last.z).length()
		if d < 1.0:
			_stride += d / HUNT_SPEED
	_last = p
	visible = show
	if not show:
		return
	drawn = pose
	position = p
	rotation = Vector3(0, float(pose.yaw) + PI, 0)
	var anim: String = pose.anim
	var t := float(pose.animTime)
	if anim == "walk" or anim == "duck":
		t = _stride
	if not ap:
		return
	var name := anim if ap.has_animation(anim) else "idle"
	if not ap.has_animation(name):
		return
	var dur := ap.get_animation(name).length
	var ct := t
	if name == "walk":
		ct = t * WALK_RATE
	elif name == "reach":
		ct = clampf(t / WIND_UP_TIME, 0.0, 1.0) * dur
	if name != "reach" and dur > 0.0:
		ct = fmod(ct, dur)
	if ap.current_animation != name:
		ap.play(name)
	ap.seek(ct, true)
	_watched_walk(anim == "walk" or anim == "duck")

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
	_twist_bone("neck1", Vector3.UP, turn * WATCH_NECK_SHARE)
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
