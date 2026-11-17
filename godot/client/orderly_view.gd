# The Orderly on screen: the model (assets/entities/orderly.glb, from Blender) posed every frame
# exactly as the frame says to draw it: feet position, facing, clip and clip time. In the dark it is
# drawn as it is, with nothing added (net/client.gd draw_in_dark, T20a): the dark lighting hides it.
# Like src/render/entityView.ts: walking clips run on the distance walked (so a creep is a slow stride),
# the reach is stretched over the wind-up. It casts shadows and stands on the floor. Bent
# over a downed player (pose "bend") it folds down over them, arms out, its head working (_show_bend).
class_name OrderlyView
extends Node3D

const WALK_RATE := 1.7          # src/render/entityView.ts
const WIND_UP_TIME := 0.6       # src/sim/entity.ts (the reach clip is drawn out over it)
const HUNT_SPEED := 3.7         # src/sim/entity.ts (stride clock)
## The bend over a downed player: seconds to fold down, and how often the head works down and up.
const BEND_IN := 0.8
const CHEW_HZ := 1.4

var model: Node3D
var ap: AnimationPlayer
var skel: Skeleton3D = null
## How far into the bend it is drawn now (0..1; tests).
var bend := 0.0
var _bent := false
var clips := []
var drawn := {}
var _stride := 0.0
var _last := Vector3.INF

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
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	visible = false

func reset() -> void:
	bend = 0.0
	_stride = 0.0
	_last = Vector3.INF
	drawn = {}
	visible = false

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
