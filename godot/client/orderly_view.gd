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

const WALK_RATE := 1.7          # src/render/entityView.ts
const WIND_UP_TIME := 0.6       # src/sim/entity.ts (the reach clip is drawn out over it)
const HUNT_SPEED := 3.7         # src/sim/entity.ts (stride clock)
## The bend over a downed player: seconds to fold down, and how often the head works down and up.
const BEND_IN := 0.8
const CHEW_HZ := 1.4
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
var _bent := false
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
	if not sks.is_empty():
		skel = sks[0] as Skeleton3D
	_skel = sks[0] if not sks.is_empty() else null
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	visible = false

func reset() -> void:
	bend = 0.0
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
	if _bent:
		# Back from the bend: the bones it bent go back to rest before a clip poses them again.
		_bent = false
		bend = 0.0
		if skel != null:
			skel.reset_bone_poses()
	if anim == "bend":
		_show_bend(t)
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
func _show_bend(t: float) -> void:
	if not ap.has_animation("reach"):
		return
	if ap.current_animation != "reach":
		ap.play("reach")
	ap.seek(ap.get_animation("reach").length, true)
	if skel == null:
		return
	var k := clampf(t / BEND_IN, 0.0, 1.0)
	var e := k * k * (3.0 - 2.0 * k)
	var chew := 0.5 - 0.5 * cos(t * TAU * CHEW_HZ)
	for b: Array in [["spine", 0.34], ["spine1", 0.36], ["spine2", 0.30 + 0.06 * chew], ["neck", 0.22 + 0.12 * chew], ["head", 0.10 + 0.22 * chew]]:
		var i := skel.find_bone(str(b[0]))
		if i >= 0:
			# Positive about the bone's own x folds it forward (the model faces +z; its bones run up y).
			skel.set_bone_pose_rotation(i, skel.get_bone_pose_rotation(i) * Quaternion(Vector3.RIGHT, float(b[1]) * e))
	_bent = true
	bend = e

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
