# One crewmate on screen: assets/entities/crewmate.glb (built by assets_src/blender/convict/
# build_crewmate.py from Mixamo motion capture). The caller says where the body is, how it moves and
# what it does; this file picks the clip, cross-fades, matches the stride to the speed and dresses the
# figure. Nothing here is a rule, and nothing outside it needs to know about bones.
#
# In motion: the clip plays at ground speed / stride, the stride measured from the clip's own planted
# toe (strides()), so feet do not slide; the body turns to where it really moves (from the placements),
# backwards it walks backwards, and the chest and mask twist back to where the player looks; the creep
# is the sneak with its steps shortened (Stride) so it plays near 0.9x, not at half speed.
# tools/crew_check.gd (headless) and tools/crew_check.mjs (two real clients) measure the slip.
#
#   set_body(position, yaw)      feet position, where the player looks (the camera's yaw convention)
#   set_gait(gait, speed)        &"still" | &"walk" | &"sprint" | &"creep", ground speed in m/s
#   play_emote(name)             a gesture from EMOTES
#   set_downed(on, recover)      fall, then hurt on the floor or crawl; recover plays a rise
#   set_stance(name)             forced help, prone, or sit pose while the host state lasts
#   set_raised(on)               the right arm holds the instrument up (over idle, walk, run and the
#                                upright one-shots; not over the sneak, crouch, crawl, pray or dances)
#   set_face(texture)            the player's drawing on the mask screen; null = a plain default face
#   set_skin(index)              0..3, the four skin tones
#   set_headwear(kind)           &"none" | &"knit" | &"hair"
#   set_number(n)                the prisoner number on the chest and back patches
class_name CrewView
extends Node3D

## Ground speed each moving clip shows at 1x playback, in m/s, as build_crewmate.py measured it from
## the clips' own root motion before taking it out. Only the crawl uses it (it has no planted toes);
## walk, run and sneak are measured again here from the clip itself (strides()): how fast the planted
## toe slides back under the body. Playback rate = ground speed / that.
const STRIDE := {"walk": 1.78, "run": 2.58, "sneak": 2.22, "crawl": 0.51}
## How far the legs swing in each moving clip (1 = the clip's own). Mixamo's sneak is a brisk lunge
## (0.93 m steps); at the creep's 1.2 m/s it would play at about half speed, a sneak in slow motion.
## Swung 60 % as far (Stride below) the steps are about 0.55 m and play near 0.9x: a quick, short sneak.
const SWING := {"walk": 1.0, "run": 1.0, "sneak": 0.6}
## A toe this close to the floor (m), and the lower of the two, is planted (the clips put it at 0-1 cm).
const CONTACT := 0.03
## The ankle's height over the floor with the foot flat (the clips: 8 cm); used to find the lowest point.
const ANKLE := 0.08
## A frame longer than this (s) is a freeze, not motion: the slip meter drops the plant it falls in.
const HITCH := 0.05
const LEGS: Array[String] = ["LeftUpLeg", "LeftLeg", "LeftFoot", "LeftToeBase", "RightUpLeg", "RightLeg", "RightFoot", "RightToeBase"]
const SPINE: Array[String] = ["Spine", "Spine1", "Spine2", "Neck", "Head"]
## The body turns to where it moves (so sideways and backwards steps do not slide); the upper body and
## head twist back toward where the player looks, at most this far (radians).
const TWIST_MAX := 1.3
const TURN_RATE := 9.0          # radians per second the body turns toward the look, standing
## ... and toward its heading while stepping: a quick pivot (about one step for a half turn), so
## turning round and walking off at once does not walk the feet sideways for long.
const TURN_RATE_STEP := 18.0
const VEL_EASE := 10.0          # how fast the measured velocity follows the placements (1/s)
## Moving more than this far from where the player looks (radians) the figure walks backwards instead
## (faces the look and plays the clip in reverse); it turns forward again under REVERSE_OFF.
const REVERSE_ON := deg_to_rad(110.0)
const REVERSE_OFF := deg_to_rad(80.0)
## Tests: "rate" plays every gait at 1x whatever the speed; "swing" keeps the short-sneak stride but
## not the short swing. Also from the command line: crewbreak=rate|swing.
static var test_break := ""
static var _strides := {}       # clip -> m/s at 1x with its SWING (measured once per process)
const GAIT_CLIP := {&"still": "idle", &"walk": "walk", &"sprint": "run", &"creep": "sneak"}
const LOOPING: Array[String] = ["idle", "walk", "run", "sneak", "crouch_idle", "crawl", "dance_spin", "dance_snake", "down_idle", "help", "prone", "sit"]
const EMOTES: Array[StringName] = [&"wave", &"look_behind", &"button", &"pray", &"dance_spin", &"dance_snake", &"point", &"cheer", &"scared"]
const FADE := 0.25              # cross-fade between clips, seconds
const FADE_DOWN := 0.6          # from the fall into the crawl (it rolls the body over)
const MOVING := 0.15            # below this ground speed a gait counts as standing still
const RATE_MIN := 0.35
const RATE_MAX := 2.2
## Clips the raised arm is drawn over: upright ones. Over the sneak's forward lean it looked broken.
const RAISE_OVER: Array[String] = ["idle", "walk", "run", "look_behind", "wave", "button"]
const RAISE_TIME := 0.2         # seconds to lift or lower the instrument arm
const SCREEN_GLOW := 0.55       # the face screen's own light (prop shader `emit`)
const PATCH_COLOR := Color(0.62, 0.60, 0.56)
const INK := Color(0.08, 0.08, 0.07)

var model: Node3D
var ap: AnimationPlayer
var skel: Skeleton3D
var body_mesh: MeshInstance3D
var gait: StringName = &"still"
var speed := 0.0
var emote: StringName = &""
var downed := false
var stance := ""
var _getting_up := false
var raised := false
var clip := ""                  # the clip playing now
var _clip_t := 0.0              # seconds since it started
var _mask_off := Vector3.ZERO   # the mask screen's middle in the Head bone's frame (from the bind pose)
var _head := -1
var _raise_w := 0.0
var _down_t := 0.0
var _mats := {}                 # material name -> ShaderMaterial (this figure's own)
var _headwear := {}             # kind -> Node3D
var _frozen := false
var _raiser: RaiseArm
var _stride: Stride
var _twist: Twist
var _face_default: Texture2D
var _legs := PackedInt32Array()
var _toes := PackedInt32Array()  # LeftToeBase, RightToeBase
var _hips := -1
var _look_yaw := 0.0            # where the player looks (set_body)
var body_yaw := 0.0             # where the body faces (turns toward its heading while moving)
var _placed := false
var _vel := Vector3.ZERO        # measured from the placements, m/s, level
var _last_pos := Vector3.INF
var reverse := false            # walking backwards: the clip plays in reverse
var _dt := 0.0
## Tests: foot slip per clip, measured on the skeleton as drawn (after the stride and twist), summed
## over every plant (_measure_slip): seconds a toe was planted, metres each planted toe ended up from
## where it touched down, metres the body went meanwhile, the number of plants.
## {clip: {"t", "foot", "body", "v2", "plants", "hitches"}} (hitches: plants dropped for a frozen
## frame, HITCH; v2: the body's speed squared, integrated; sqrt(v2 / t)
## against body / t says how unevenly it was placed). A planted toe that does not slide moves 0 m.
var slip := {}
var _slip_prev := {}

func _ready() -> void:
	for raw in OS.get_cmdline_user_args():
		if raw.trim_prefix("--").begins_with("crewbreak="):
			test_break = raw.trim_prefix("--").get_slice("=", 1)
	var ps: PackedScene = load("res://assets/entities/crewmate.glb")
	model = ps.instantiate()
	add_child(model)
	ap = model.find_child("AnimationPlayer", true, false)
	skel = model.find_child("Skeleton3D", true, false)
	for n: String in ap.get_animation_list():
		# Import quirk: every clip comes in non-looping.
		ap.get_animation(n).loop_mode = Animation.LOOP_LINEAR if n in LOOPING else Animation.LOOP_NONE
	ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	_hips = skel.find_bone("Hips")
	for b: String in LEGS:
		_legs.append(skel.find_bone(b))
	_toes = PackedInt32Array([skel.find_bone("LeftToeBase"), skel.find_bone("RightToeBase")])
	if _strides.is_empty():
		_measure_strides()
	# The skeleton modifiers run in child order: the short sneak's legs, the twist back to the look,
	# then the raised instrument arm (which aims where the twisted chest faces).
	_stride = Stride.new()
	_stride.hips = _hips
	_stride.legs = _legs
	_stride.swing = float(SWING["sneak"])
	_stride.active = false
	_stride.influence = 0.0
	skel.add_child(_stride)
	_twist = Twist.new()
	for b: String in SPINE:
		_twist.bones.append(skel.find_bone(b))
	skel.add_child(_twist)
	skel.skeleton_updated.connect(_measure_slip)
	_raiser = RaiseArm.new()
	for b: String in ["RightArm", "RightForeArm", "RightHand"]:
		_raiser.bones.append(skel.find_bone(b))
	_raiser.active = false
	skel.add_child(_raiser)
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		var m: Mesh = mi.mesh
		for i in m.get_surface_count():
			var src := m.surface_get_material(i) as BaseMaterial3D
			var mname := src.resource_name if src else ""
			var tex: Texture2D = src.albedo_texture if src else null
			var mat := Level.prop_material(Color.WHITE, tex)
			_mats[mname] = mat
			mi.set_surface_override_material(i, mat)
		if mi.name.begins_with("headwear_"):
			_headwear[StringName(mi.name.trim_prefix("headwear_"))] = mi
		elif mi.skin != null or mi.skeleton != NodePath():
			body_mesh = mi
	_head = skel.find_bone("Head")
	if body_mesh != null and _head >= 0:
		var m: Mesh = body_mesh.mesh
		for i in m.get_surface_count():
			var src := m.surface_get_material(i)
			if src != null and src.resource_name == "face_screen":
				var verts: PackedVector3Array = m.surface_get_arrays(i)[Mesh.ARRAY_VERTEX]
				var c := Vector3.ZERO
				for v in verts:
					c += v
				c /= maxf(1.0, verts.size())
				_mask_off = skel.get_bone_global_rest(_head).affine_inverse() * (body_mesh.transform * c)
	_face_default = default_face()
	set_face(null)
	set_number(0)
	set_headwear(&"none")
	_play("idle", 0.0)

# --- the API ---------------------------------------------------------------------------------------

func set_body(pos: Vector3, yaw: float) -> void:
	position = pos
	_look_yaw = yaw
	if _frozen or not _placed:
		body_yaw = yaw   # a held pose (tests, the demo) or the first placement: face the look at once
		_last_pos = pos
		_placed = true
	rotation = Vector3(0, body_yaw + PI, 0)

func set_gait(g: StringName, ground_speed: float) -> void:
	gait = g if GAIT_CLIP.has(g) else &"still"
	speed = maxf(ground_speed, 0.0)
	if emote != &"" and speed >= MOVING and gait != &"still":
		emote = &""   # moving off cancels an emote

func play_emote(which: StringName) -> void:
	if downed or _getting_up or stance != "" or not which in EMOTES or not ap.has_animation(which):
		return
	emote = which
	_play(String(which), FADE)
	ap.seek(0.0, true)

func set_downed(on: bool, recover: bool = false) -> void:
	if on == downed:
		return
	downed = on
	emote = &""
	_down_t = 0.0
	_getting_up = not on and recover
	if on:
		_play("taken", FADE)
		ap.seek(0.0, true)
	elif _getting_up:
		_play("get_up", FADE)
		ap.seek(0.0, true)

func set_stance(which: String) -> void:
	if which != "" and stance != which:
		emote = &""
		_getting_up = false
	stance = which

func set_raised(on: bool) -> void:
	raised = on

func set_face(texture: Texture2D) -> void:
	var m: ShaderMaterial = _mats.get("face_screen")
	if m:
		m.set_shader_parameter("tex", texture if texture else _face_default)
		m.set_shader_parameter("emit", SCREEN_GLOW)

## Tests: a short hash of the picture on the mask screen right now (read back from its material), to
## compare with texture_hash() of the face the player drew.
func face_hash() -> String:
	var m: ShaderMaterial = _mats.get("face_screen")
	return texture_hash(m.get_shader_parameter("tex") as Texture2D) if m else ""

## Tests: how high the middle of the mask screen is above the feet in the pose drawn now (metres).
## It should be the eye height the rules use for that player (eye_height.gd), within a few cm.
func mask_height() -> float:
	if _head < 0:
		return 0.0
	var p := skel.global_transform * skel.get_bone_global_pose(_head) * _mask_off
	return p.y - global_position.y

## A short hash of a texture's top-level pixels ("" for none).
static func texture_hash(tex: Texture2D) -> String:
	if tex == null:
		return ""
	return image_hash(tex.get_image())

## A short hash of an image's top-level pixels as RGB ("" for none).
static func image_hash(src: Image) -> String:
	if src == null:
		return ""
	var img := src.duplicate() as Image
	img.clear_mipmaps()
	img.convert(Image.FORMAT_RGB8)
	return img.get_data().hex_encode().md5_text().substr(0, 10)

func set_skin(index: int) -> void:
	var m: ShaderMaterial = _mats.get("convict_skin")
	if m:
		m.set_shader_parameter("tex", load("res://assets/entities/crewmate_skin_%d.png" % (posmod(index, 4) + 1)))

func set_headwear(kind: StringName) -> void:
	for k: StringName in _headwear:
		(_headwear[k] as Node3D).visible = k == kind

func set_number(n: int) -> void:
	var m: ShaderMaterial = _mats.get("number_patch")
	if m:
		m.set_shader_parameter("tex", number_texture(n))

## Tests and the demo: hold one clip at one time, nothing else moves it (null clip lets go).
func debug_pose(which: String, t: float) -> void:
	_frozen = which != ""
	if not _frozen:
		return
	ap.play(which, 0.0)
	clip = which
	ap.seek(t, true)
	_twist.angle = 0.0
	_apply_stride(0.0)
	_apply_raise(0.0)

# --- each frame ------------------------------------------------------------------------------------

func _process(delta: float) -> void:
	_dt = delta
	if _frozen:
		_apply_raise(delta)
		return
	# How the body really moves, from where it is placed each frame (a jump of 2 m is a ride or a
	# placement, not a step).
	if _last_pos != Vector3.INF and delta > 0.0:
		var d := Vector3(position.x - _last_pos.x, 0.0, position.z - _last_pos.z)
		_vel = _vel.lerp(d / delta, minf(1.0, delta * VEL_EASE)) if d.length() < 2.0 else Vector3.ZERO
	_last_pos = position
	_clip_t += delta
	var want := ""
	var rate := 1.0
	var fade := FADE
	if downed:
		_down_t += delta
		var fall := ap.get_animation("taken").length
		if _down_t < fall - 0.1:
			want = "taken"
		else:
			want = "crawl" if speed >= MOVING else "down_idle"
			fade = FADE_DOWN
			if want == "crawl":
				rate = speed / STRIDE["crawl"]
	elif stance != "":
		want = stance
	elif _getting_up:
		var elapsed := ap.current_animation_position
		if elapsed < ap.get_animation("get_up").length - FADE and (speed < MOVING or elapsed < 0.75):
			want = "get_up"
			rate = 1.5
		else:
			_getting_up = false
	elif emote != &"":
		want = String(emote)
		var dur := ap.get_animation(want).length
		if clip == want and ap.current_animation_position >= dur - FADE:
			emote = &""   # hand back to the gait as the one-shot ends
			want = ""
	var stepping := false   # a gait clip that covers ground: the body turns to its heading
	if want == "":
		var moving := speed >= MOVING and gait != &"still"
		if gait == &"creep" and not moving:
			# Creeping in place: the sneak held still, not the deeper crouch_idle (its mask is at 0.75 m),
			# so the head stays where the creeping player's eye is (eye_height.gd CREEP: the sneak's mask).
			# Held only once the cross-fade into it is over: the player's blend time runs at the
			# playback rate, so a fade at rate 0 would never end.
			want = "sneak"
			rate = 0.0 if clip == "sneak" and _clip_t >= FADE else 1.0
		elif not moving:
			want = "idle"
		else:
			want = GAIT_CLIP[gait]
			# The ground speed as drawn: the placements' own velocity (smoothed as a vector, so the
			# network's uneven steps cancel out) once it is placed moving; else the caller's speed.
			var ground := _vel.length() if _vel.length() >= MOVING else speed
			rate = clampf(ground / stride(want), RATE_MIN, RATE_MAX)
			if test_break == "rate":
				rate = 1.0
			stepping = true
	elif want == "crawl" and rate > 0.0:
		stepping = true
	if want != clip:
		_play(want, fade)
	_steer(delta, stepping, not downed and stance == "" and not _getting_up and emote == &"")
	ap.speed_scale = -rate if reverse else rate
	ap.advance(delta)
	_apply_stride(delta)
	_apply_raise(delta)

## m/s of ground the clip covers at 1x, as drawn (with its SWING).
static func stride(which: String) -> float:
	return float(_strides.get(which, STRIDE.get(which, 1.0)))

# Turns the body toward where it really moves (sideways and backward steps then do not slide), walking
# backwards when that is more than REVERSE_ON from the look; the upper body twists back to the look.
func _steer(delta: float, stepping: bool, twist: bool) -> void:
	var target := _look_yaw
	if stepping and _vel.length() > MOVING:
		var heading := atan2(-_vel.x, -_vel.z)
		var rel := absf(wrapf(heading - _look_yaw, -PI, PI))
		reverse = rel > (REVERSE_OFF if reverse else REVERSE_ON) and not downed
		target = heading + (PI if reverse else 0.0)
	elif not stepping:
		reverse = false
	if downed and clip != "crawl":
		target = body_yaw   # falling: where it stood
	body_yaw = rotate_toward(body_yaw, target, (TURN_RATE_STEP if stepping else TURN_RATE) * delta)
	rotation = Vector3(0, body_yaw + PI, 0)
	_twist.angle = clampf(wrapf(_look_yaw - body_yaw, -PI, PI), -TWIST_MAX, TWIST_MAX) if twist else 0.0
	_twist.active = absf(_twist.angle) > 0.001
	_raiser.turn = _twist.angle

# The short sneak's legs come in and out with the sneak clip itself.
func _apply_stride(delta: float) -> void:
	var on := 1.0 if clip == "sneak" and test_break != "swing" else 0.0
	_stride.influence = move_toward(_stride.influence, on, delta / FADE) if delta > 0.0 else on
	_stride.active = _stride.influence > 0.001

func _play(which: String, fade: float) -> void:
	clip = which
	_clip_t = 0.0
	ap.play(which, fade)

# The instrument arm: a skeleton modifier aims the right upper arm forward and the forearm up so the
# hand holds the instrument in front of the chest (below the face screen), over whatever the clip
# does; its influence is the blend in and out.
func _apply_raise(delta: float) -> void:
	var target := 1.0 if raised and not downed and clip in RAISE_OVER else 0.0
	_raise_w = move_toward(_raise_w, target, delta / RAISE_TIME) if delta > 0.0 else target
	if _raiser:
		_raiser.influence = _raise_w * _raise_w * (3.0 - 2.0 * _raise_w)
		_raiser.active = _raise_w > 0.001

class RaiseArm extends SkeletonModifier3D:
	const UPPER := Vector3(0.22, -0.55, 0.80)   # in the figure's own space: +Z forward, +X its left
	const LOWER := Vector3(0.40, 0.42, 0.81)
	var bones := PackedInt32Array()            # RightArm, RightForeArm, RightHand
	var turn := 0.0                            # the chest's twist toward the look (Twist), radians

	func _process_modification() -> void:
		var sk := get_skeleton()
		if sk == null or bones.size() < 3 or bones.has(-1):
			return
		var t := Basis(Vector3.UP, turn)
		_aim(sk, bones[0], bones[1], t * UPPER.normalized())
		_aim(sk, bones[1], bones[2], t * LOWER.normalized())

	func _aim(sk: Skeleton3D, bone: int, child: int, dir: Vector3) -> void:
		var pg := sk.get_bone_global_pose(sk.get_bone_parent(bone))
		var g := pg * Transform3D(Basis(sk.get_bone_pose_rotation(bone)), sk.get_bone_pose_position(bone))
		var cur := (g.basis * sk.get_bone_pose_position(child)).normalized()
		var turn := Quaternion(cur, dir)
		sk.set_bone_pose_rotation(bone, Quaternion((pg.basis.inverse() * Basis(turn) * g.basis).orthonormalized()))

# The upper body and head turned back toward the look (`angle`, radians about the figure's up axis),
# spread evenly over the spine, neck and head, so the mask faces where the player looks while the legs
# go where the body moves.
class Twist extends SkeletonModifier3D:
	var bones := PackedInt32Array()            # Spine, Spine1, Spine2, Neck, Head
	var angle := 0.0

	func _process_modification() -> void:
		var sk := get_skeleton()
		if sk == null or bones.is_empty() or bones.has(-1):
			return
		var step := Basis(Vector3.UP, angle / bones.size())
		for b in bones:
			var pg := sk.get_bone_global_pose(sk.get_bone_parent(b)).basis
			var local := Basis(sk.get_bone_pose_rotation(b))
			sk.set_bone_pose_rotation(b, (pg.inverse() * step * pg * local).orthonormalized().get_rotation_quaternion())

# The short sneak: each foot is pulled in toward the figure's middle along its forward axis, to `swing`
# of how far forward or back the clip puts it (the toe is what is scaled, so a toe planted in the clip
# slides back `swing` as fast, as evenly as the clip's own). The foot keeps the clip's height and its
# angle to the ground (a planted foot stays flat on the floor, a lifted one clears it as high), and the
# hip and knee are solved for it (two-bone IK, the knee bending the way the clip's knee does). Then, if a
# foot could not reach, the hips go down or up so the lowest point of the feet is where the clip had it.
# `influence` is the blend in and out with the sneak clip.
class Stride extends SkeletonModifier3D:
	var hips := -1
	var legs := PackedInt32Array()
	var swing := 1.0

	func _process_modification() -> void:
		var sk := get_skeleton()
		if sk == null or hips < 0 or legs.size() != 8 or legs.has(-1):
			return
		var cur: Array[Quaternion] = []
		for i in legs.size():
			cur.append(sk.get_bone_pose_rotation(legs[i]))
		var hg := sk.get_bone_global_pose(hips)
		var now := CrewView.short_legs(sk, hg, legs, cur, swing)
		var lift := CrewView.lowest(CrewView.leg_points(sk, hg, legs, cur)) - CrewView.lowest(CrewView.leg_points(sk, hg, legs, now))
		for i in legs.size():
			sk.set_bone_pose_rotation(legs[i], now[i])
		if absf(lift) > 0.0001:
			sk.set_bone_pose_position(hips, sk.get_bone_pose_position(hips) + Vector3(0, lift, 0))

## The leg bones' rotations (LEGS order) for the short stride (Stride): given the clip's own `cur`
## under hips pose hg, each foot moved so its toe is at `swing` of its forward distance (model +Z).
static func short_legs(sk: Skeleton3D, hg: Transform3D, legs: PackedInt32Array, cur: Array[Quaternion], swing: float) -> Array[Quaternion]:
	if swing == 1.0:
		return cur.duplicate()
	var now: Array[Quaternion] = []
	for side in 2:
		var o := side * 4
		var p_up := sk.get_bone_pose_position(legs[o])
		var p_knee := sk.get_bone_pose_position(legs[o + 1])
		var p_foot := sk.get_bone_pose_position(legs[o + 2])
		var p_toe := sk.get_bone_pose_position(legs[o + 3])
		var g_up := hg * Transform3D(Basis(cur[o]), p_up)
		var g_knee := g_up * Transform3D(Basis(cur[o + 1]), p_knee)
		var g_foot := g_knee * Transform3D(Basis(cur[o + 2]), p_foot)
		var toe := (g_foot * Transform3D(Basis(cur[o + 3]), p_toe)).origin
		var h := g_up.origin
		var k := g_knee.origin
		var a := g_foot.origin
		var target := a + Vector3(0, 0, (swing - 1.0) * toe.z)
		var l1 := h.distance_to(k)
		var l2 := k.distance_to(a)
		var ht := target - h
		var d := clampf(ht.length(), absf(l1 - l2) + 0.001, l1 + l2 - 0.001)
		var dir := ht.normalized()
		var along := (l1 * l1 - l2 * l2 + d * d) / (2.0 * d)
		var out := sqrt(maxf(0.0, l1 * l1 - along * along))
		var pole := (k - h) - dir * dir.dot(k - h)
		pole = pole.normalized() if pole.length() > 0.0001 else hg.basis.z.normalized()
		var k2 := h + dir * along + pole * out
		var a2 := h + dir * d
		var up_b := Basis(Quaternion((k - h).normalized(), (k2 - h).normalized())) * g_up.basis
		var knee_tmp := Transform3D(up_b, h) * Transform3D(Basis(cur[o + 1]), p_knee)
		var knee_b := Basis(Quaternion((knee_tmp.basis * p_foot).normalized(), (a2 - k2).normalized())) * knee_tmp.basis
		now.append((hg.basis.inverse() * up_b).orthonormalized().get_rotation_quaternion())
		now.append((up_b.inverse() * knee_b).orthonormalized().get_rotation_quaternion())
		now.append((knee_b.inverse() * g_foot.basis).orthonormalized().get_rotation_quaternion())
		now.append(cur[o + 3])
	return now

## The two ankles and toes (model space) with these leg bone rotations (LEGS order) under hips pose hg:
## [left ankle, left toe, right ankle, right toe].
static func leg_points(sk: Skeleton3D, hg: Transform3D, legs: PackedInt32Array, rots: Array[Quaternion]) -> PackedVector3Array:
	var out := PackedVector3Array()
	for side in 2:
		var g := hg
		for k in 4:
			var b := legs[side * 4 + k]
			g = g * Transform3D(Basis(rots[side * 4 + k]), sk.get_bone_pose_position(b))
			if k >= 2:
				out.append(g.origin)
	return out

## The lowest point of the feet: a toe, or a heel (the ankle less its height with the foot flat).
static func lowest(p: PackedVector3Array) -> float:
	return minf(minf(p[1].y, p[3].y), minf(p[0].y, p[2].y) - ANKLE)

# Once per process: how fast the planted toe slides back under the body in each moving clip at 1x,
# drawn as it is drawn (the sneak shortened by Stride). That speed is the clip's stride: a body moving
# at it with the clip at 1x has feet that stay put.
func _measure_strides() -> void:
	var n := 120
	for c: String in SWING:
		var a := ap.get_animation(c)
		ap.play(c, 0.0)
		var toes: Array[PackedVector3Array] = []
		for k in n:
			ap.seek(a.length * k / n, true)
			ap.advance(0.0)
			var cur: Array[Quaternion] = []
			for i in _legs.size():
				cur.append(skel.get_bone_pose_rotation(_legs[i]))
			var hg := skel.get_bone_global_pose(_hips)
			var p := leg_points(skel, hg, _legs, short_legs(skel, hg, _legs, cur, float(SWING[c])))
			var lift := lowest(leg_points(skel, hg, _legs, cur)) - lowest(p)
			toes.append(PackedVector3Array([p[1] + Vector3(0, lift, 0), p[3] + Vector3(0, lift, 0)]))
		var travel := 0.0
		var time := 0.0
		for k in n:
			var p0 := toes[k]
			var p1 := toes[(k + 1) % n]
			var side := 0 if p0[0].y <= p0[1].y else 1
			var side1 := 0 if p1[0].y <= p1[1].y else 1
			if side == side1 and p0[side].y < CONTACT and p1[side].y < CONTACT:
				travel += p0[side].z - p1[side].z   # the figure faces +Z: a planted toe slides toward -Z
				time += a.length / n
		_strides[c] = travel / time if time > 0.0 else float(STRIDE[c])
	ap.stop()

# Every skeleton update (the pose as drawn, after the modifiers): the lower toe, if planted. Each plant
# (one toe down, from touching to lifting) is scored when it ends: how far that toe got from where it
# touched down, against how far the body went meanwhile. That is the slide the eye sees; it is not
# fooled by the millimetre wobble of the network's placements at a high frame rate, which a sum of
# frame-to-frame moves would add up into metres. Counted only once a gait clip is fully in.
func _measure_slip() -> void:
	if _frozen or _dt <= 0.0:
		return
	var xf := skel.global_transform
	var t0 := xf * skel.get_bone_global_pose(_toes[0]).origin
	var t1 := xf * skel.get_bone_global_pose(_toes[1]).origin
	var side := 0 if t0.y <= t1.y else 1
	var toe := t0 if side == 0 else t1
	var planted := toe.y - global_position.y < CONTACT and clip in SWING and _clip_t >= FADE and not downed
	var same := not _slip_prev.is_empty() and int(_slip_prev["side"]) == side and str(_slip_prev["clip"]) == clip
	if _dt > HITCH:
		# A frozen frame (a picture being saved, a load): the eye sees a jump, not a slide. The plant
		# it falls in is not scored, only counted.
		if not _slip_prev.is_empty():
			var s: Dictionary = slip.get(_slip_prev["clip"], {})
			s["hitches"] = int(s.get("hitches", 0)) + 1
			slip[_slip_prev["clip"]] = s
		_slip_prev = {}
		return
	if not _slip_prev.is_empty() and not (planted and same):
		_end_plant()
	if planted:
		if _slip_prev.is_empty():
			_slip_prev = {"side": side, "clip": clip, "toe0": toe, "body0": global_position, "t": 0.0, "v2": 0.0}
		else:
			var pb: Vector3 = _slip_prev.get("body", _slip_prev["body0"])
			var step := Vector2(global_position.x - pb.x, global_position.z - pb.z).length()
			_slip_prev["t"] = float(_slip_prev["t"]) + _dt
			_slip_prev["v2"] = float(_slip_prev["v2"]) + step * step / _dt
		_slip_prev["toe"] = toe
		_slip_prev["body"] = global_position

func _end_plant() -> void:
	var p := _slip_prev
	_slip_prev = {}
	if float(p["t"]) <= 0.0:
		return
	var a: Vector3 = p["toe0"]
	var b: Vector3 = p["toe"]
	var c: Vector3 = p["body0"]
	var d: Vector3 = p["body"]
	var s: Dictionary = slip.get(p["clip"], {})
	s["t"] = float(s.get("t", 0.0)) + float(p["t"])
	s["foot"] = float(s.get("foot", 0.0)) + Vector2(b.x - a.x, b.z - a.z).length()
	s["body"] = float(s.get("body", 0.0)) + Vector2(d.x - c.x, d.z - c.z).length()
	s["v2"] = float(s.get("v2", 0.0)) + float(p["v2"])   # with t: how evenly the body itself was placed
	s["plants"] = int(s.get("plants", 0)) + 1
	slip[p["clip"]] = s

## Tests: how this figure moves now (clip, playback rate, the measured strides, slip so far).
func motion() -> Dictionary:
	return {"clip": clip, "rate": ap.speed_scale, "reverse": reverse, "bodyYaw": body_yaw, "lookYaw": _look_yaw,
		"twist": _twist.angle, "stride": stride(clip) if clip in SWING else 0.0, "slip": slip.duplicate(true)}

# --- textures ----------------------------------------------------------------------------------------

## The face shown until the player has drawn one: two dots and a line, dark on the lit screen.
static func default_face() -> Texture2D:
	var img := Image.create(64, 64, false, Image.FORMAT_RGB8)
	img.fill(Color(0.72, 0.80, 0.74))
	for e: Vector2i in [Vector2i(21, 26), Vector2i(43, 26)]:
		for y in range(-4, 5):
			for x in range(-4, 5):
				if x * x + y * y <= 17:
					img.set_pixel(e.x + x, e.y + y, INK)
	img.fill_rect(Rect2i(20, 43, 25, 4), INK)
	return ImageTexture.create_from_image(img)

## The prisoner number, stencilled dark on the pale patch (both patches use the same 0..1 picture).
static func number_texture(n: int) -> Texture2D:
	var text := "%02d" % clampi(n, 0, 999)
	var img := Image.create(40, 25, false, Image.FORMAT_RGB8)
	img.fill(PATCH_COLOR)
	var w := PixelFont.width(text) * 3
	PixelFont.blit(img, text, Vector2i((40 - w) / 2, 2), INK, Vector2i(3, 3))
	return ImageTexture.create_from_image(img)
