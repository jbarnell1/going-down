# One crewmate on screen: assets/entities/crewmate.glb (built by assets_src/blender/convict/
# build_crewmate.py from Mixamo motion capture). The caller says where the body is, how it moves and
# what it does; this file picks the clip, cross-fades, matches the stride to the speed and dresses the
# figure. Nothing here is a rule, and nothing outside it needs to know about bones.
#
#   set_body(position, yaw)      feet position, facing (the camera's yaw convention, as OrderlyView)
#   set_gait(gait, speed)        &"still" | &"walk" | &"sprint" | &"creep", ground speed in m/s
#   play_emote(name)             &"wave" | &"look_behind" | &"button" | &"pray" | &"dance_spin" | &"dance_snake"
#   set_downed(on)               taken (falls), then crawl; set_gait's speed drives the crawl
#   set_raised(on)               the right arm holds the instrument up (over idle, walk, run and the
#                                upright one-shots; not over the sneak, crouch, crawl, pray or dances)
#   set_face(texture)            the player's drawing on the mask screen; null = a plain default face
#   set_skin(index)              0..3, the four skin tones
#   set_headwear(kind)           &"none" | &"knit" | &"hair"
#   set_number(n)                the prisoner number on the chest and back patches
class_name CrewView
extends Node3D

## Ground speed each moving clip shows at 1x playback, in m/s (build_crewmate.py measured it from
## the clips' own root motion before taking it out). Playback rate = speed / stride.
const STRIDE := {"walk": 1.78, "run": 2.58, "sneak": 2.22, "crawl": 0.51}
const GAIT_CLIP := {&"still": "idle", &"walk": "walk", &"sprint": "run", &"creep": "sneak"}
const LOOPING: Array[String] = ["idle", "walk", "run", "sneak", "crouch_idle", "crawl", "dance_spin", "dance_snake"]
const EMOTES: Array[StringName] = [&"wave", &"look_behind", &"button", &"pray", &"dance_spin", &"dance_snake"]
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
var raised := false
var clip := ""                  # the clip playing now
var _raise_w := 0.0
var _down_t := 0.0
var _mats := {}                 # material name -> ShaderMaterial (this figure's own)
var _headwear := {}             # kind -> Node3D
var _frozen := false
var _raiser: RaiseArm
var _face_default: Texture2D

func _ready() -> void:
	var ps: PackedScene = load("res://assets/entities/crewmate.glb")
	model = ps.instantiate()
	add_child(model)
	ap = model.find_child("AnimationPlayer", true, false)
	skel = model.find_child("Skeleton3D", true, false)
	for n: String in ap.get_animation_list():
		# Import quirk: every clip comes in non-looping.
		ap.get_animation(n).loop_mode = Animation.LOOP_LINEAR if n in LOOPING else Animation.LOOP_NONE
	ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
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
	_face_default = default_face()
	set_face(null)
	set_number(0)
	set_headwear(&"none")
	_play("idle", 0.0)

# --- the API ---------------------------------------------------------------------------------------

func set_body(pos: Vector3, yaw: float) -> void:
	position = pos
	rotation = Vector3(0, yaw + PI, 0)

func set_gait(g: StringName, ground_speed: float) -> void:
	gait = g if GAIT_CLIP.has(g) else &"still"
	speed = maxf(ground_speed, 0.0)
	if emote != &"" and speed >= MOVING and gait != &"still":
		emote = &""   # moving off cancels an emote

func play_emote(which: StringName) -> void:
	if downed or not which in EMOTES or not ap.has_animation(which):
		return
	emote = which
	_play(String(which), FADE)
	ap.seek(0.0, true)

func set_downed(on: bool) -> void:
	if on == downed:
		return
	downed = on
	emote = &""
	_down_t = 0.0
	if on:
		_play("taken", FADE)
		ap.seek(0.0, true)

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
	_apply_raise(0.0)

# --- each frame ------------------------------------------------------------------------------------

func _process(delta: float) -> void:
	if _frozen:
		_apply_raise(delta)
		return
	var want := ""
	var rate := 1.0
	var fade := FADE
	if downed:
		_down_t += delta
		var fall := ap.get_animation("taken").length
		if _down_t < fall - 0.1:
			want = "taken"
		else:
			want = "crawl"
			fade = FADE_DOWN
			rate = speed / STRIDE["crawl"] if speed >= MOVING else 0.0
	elif emote != &"":
		want = String(emote)
		var dur := ap.get_animation(want).length
		if clip == want and ap.current_animation_position >= dur - FADE:
			emote = &""   # hand back to the gait as the one-shot ends
			want = ""
	if want == "":
		var moving := speed >= MOVING and gait != &"still"
		if gait == &"creep" and not moving:
			want = "crouch_idle"
		elif not moving:
			want = "idle"
		else:
			want = GAIT_CLIP[gait]
			rate = clampf(speed / float(STRIDE[want]), RATE_MIN, RATE_MAX)
	if want != clip:
		_play(want, fade)
	ap.speed_scale = rate
	ap.advance(delta)
	_apply_raise(delta)

func _play(which: String, fade: float) -> void:
	clip = which
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

	func _process_modification() -> void:
		var sk := get_skeleton()
		if sk == null or bones.size() < 3 or bones.has(-1):
			return
		_aim(sk, bones[0], bones[1], UPPER.normalized())
		_aim(sk, bones[1], bones[2], LOWER.normalized())

	func _aim(sk: Skeleton3D, bone: int, child: int, dir: Vector3) -> void:
		var pg := sk.get_bone_global_pose(sk.get_bone_parent(bone))
		var g := pg * Transform3D(Basis(sk.get_bone_pose_rotation(bone)), sk.get_bone_pose_position(bone))
		var cur := (g.basis * sk.get_bone_pose_position(child)).normalized()
		var turn := Quaternion(cur, dir)
		sk.set_bone_pose_rotation(bone, Quaternion((pg.basis.inverse() * Basis(turn) * g.basis).orthonormalized()))

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
