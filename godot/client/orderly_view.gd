# The Orderly on screen: the model (assets/entities/orderly.glb, from Blender) posed every frame
# exactly as rules_bridge says to draw it: feet position, facing, clip and clip time. Never drawn in
# the dark. Like src/render/entityView.ts: walking clips run on the distance walked (so a creep is a
# slow stride), the reach is stretched over the wind-up. It casts shadows and stands on the floor.
class_name OrderlyView
extends Node3D

const WALK_RATE := 1.7          # src/render/entityView.ts
const WIND_UP_TIME := 0.6       # src/sim/entity.ts (the reach clip is drawn out over it)
const HUNT_SPEED := 3.7         # src/sim/entity.ts (stride clock)

var model: Node3D
var ap: AnimationPlayer
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
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	visible = false

func reset() -> void:
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
