# The Minder on screen (docs/floors/playarea.md section 2, the body as rewritten on the owner's note):
# the Playroom's resident, a stand-in made in code until the Blender figure (T15g) replaces it. Gaunt,
# hairless and too long, about 2.3 m upright, in the dull grey-brown of old wet rubber, ribs and spine
# showing; arms past its knees ending in long splayed fingers; legs that bend the wrong way when it
# crouches. A long narrow eyeless head like a greyhound's skull, a slack jaw with small uneven teeth,
# and strapped over the FRONT only a cheap card party mask printed with a smiley (two dots and a
# curve) that glows faintly in the dark: the back of the head is bare, so you can always tell which
# way it faces. Rags of a play attendant's tabard in faded red, yellow and blue, a staff lanyard with
# a laminated badge, and a wind-up music box clipped to it. Our own figure: no other game's creature.
#
#   show_pose(pose, show)   pose {x, y, z, level, yaw, anim, animTime} or null; show: may it be drawn
#   follow(link)            the PlayLink whose network client it reads the un-held pose from
#   set_floor(plan, level)  the floor (heard duller through walls) and its Level (the Playroom's view
#                           then dims its body with the strip lights and keeps the mask glowing)
#   reset()
#
# It is NOT a Stillness resident: looking at it does nothing, so the client's pose hold must not apply.
# net/client.gd freezes the drawn resident while the camera sees it (the Orderly's and the Temp's
# rule); this view does not draw that held pose. Given follow(link), every frame it takes the
# resident's pose straight from the two snapshots being drawn at the frame's render time (the same
# interpolation the client uses, without the hold), so it keeps moving while you watch it.
#
# The pose name picks the body: upright and stooped (stand, walk, straighten, slump; the interim
# rules' idle, walk, duck), on all fours (prowl, run, sweep, look, catch; the interim reach), or
# crouched to the wall with both hands over the mask (cover). Walking runs on the distance walked.
#
# The music box: two or three notes of the floor's tune for every 1.5 m it walks (one per NOTE_STEP),
# so slower when it walks slowly. Its own player, heard to 30 m, quieter and duller through walls, on
# the "Entity" bus when the layout has one, otherwise "Sfx". The notes are made here, in code.
class_name MinderView
extends Node3D

const Floor = preload("res://sim/floor.gd")
const Sight = preload("res://sim/sight.gd")
const Move = preload("res://sim/move.gd")
const Pose = preload("res://net/pose.gd")

## Not a Stillness resident: the pose hold is off (see the header).
const STILLNESS := false
const NOTE_STEP := 0.5          # metres walked per note: three per 1.5 m
const HEAR_RANGE := 30.0
const MUFFLED_GAIN := 0.45
const NOTE_DB := -2.0
const BOX_HEIGHT := 1.55        # where the music box hangs, standing
const CYCLE_UP := 1.7           # metres per walk cycle upright
const CYCLE_FOURS := 2.2        # metres per gait cycle on all fours
const HIP_Y := 1.2
## The floor's tune, our own: semitones above the box's note, one per note played, round and round.
const TUNE: Array[int] = [7, 4, 0, 4, 7, 7, 9, 7, 4, 2, 4, 0, 2, 4, 2, -1, 0]
const BASE_HZ := 1046.5

## sRGB, as vertex colours.
const SKIN := Color(0.56, 0.5, 0.45)
const SKIN_DARK := Color(0.42, 0.37, 0.34)
const MOUTH := Color(0.12, 0.08, 0.08)
const TOOTH := Color(0.86, 0.82, 0.7)
const RAG_RED := Color(0.72, 0.4, 0.36)
const RAG_YELLOW := Color(0.84, 0.74, 0.44)
const RAG_BLUE := Color(0.42, 0.54, 0.68)
const LANYARD := Color(0.24, 0.42, 0.72)
const CARD := Color(0.95, 0.95, 0.9)
const BOX := Color(0.92, 0.6, 0.68)
const BRASS := Color(0.85, 0.7, 0.32)
const STRAP := Color(0.08, 0.08, 0.08)
## The body's own light: a figure under strip lights, a little darker than the walls.
const BODY_LIGHT := 0.75
## The mask under the lights, and glowing faintly in count dark.
const MASK_LIT := Color(1.0, 0.99, 0.94)
const MASK_DARK := Color(0.62, 0.86, 0.6)
const MASK_LIT_E := 0.95
const MASK_DARK_E := 0.55

## Every note so far (tests): {semi, gain, muffled, at}.
var notes: Array[Dictionary] = []
## The pose drawn last (tests), and which body it used: "upright", "fours" or "cover".
var drawn: Variant = null
var body_kind := "upright"
## Frames whose pose came from the snapshots rather than from the (held) pose handed in (tests).
var unheld_frames := 0

var _joints := {}
var _sig_nodes: Array[Node3D] = []
var _parts := {}
var _body_mat: ShaderMaterial
var _mask_mat: ShaderMaterial
var _player: AudioStreamPlayer3D
var _plan: Floor.FloorPlan = null
var _link: Object = null
var _dist := 0.0
var _last := Vector3.INF
var _note_k := 0
var _t := 0.0
var _last_us := 0

func _init() -> void:
	_body_mat = _make_body_mat()
	_mask_mat = _make_mask_mat()
	_build()
	_player = AudioStreamPlayer3D.new()
	_player.name = "MusicBox"
	_player.stream = note_stream()
	_player.top_level = true
	_player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
	_player.max_distance = HEAR_RANGE
	_player.max_polyphony = 4
	_player.attenuation_filter_cutoff_hz = 20500.0
	add_child(_player)
	visible = false

func _ready() -> void:
	_player.bus = bus_name()

## The bus its music box plays on: "Entity" when the layout has one, otherwise "Sfx".
static func bus_name() -> StringName:
	return &"Entity" if AudioServer.get_bus_index(&"Entity") != -1 else &"Sfx"

func reset() -> void:
	_dist = 0.0
	_last = Vector3.INF
	_note_k = 0
	drawn = null
	visible = false

static func _make_body_mat() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://client/playroom_shade.gdshader")
	m.set_shader_parameter("mode", 1.0)
	m.set_shader_parameter("self_light", BODY_LIGHT)
	m.set_shader_parameter("energy", 1.0)
	m.set_shader_parameter("bleach", 0.0)
	return m

static func _make_mask_mat() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://client/playroom_glow.gdshader")
	m.set_shader_parameter("color", MASK_LIT)
	m.set_shader_parameter("energy", MASK_LIT_E)
	m.set_shader_parameter("scissor", 0.5)
	m.set_shader_parameter("tex", mask_tex())
	m.set_shader_parameter("haze_density", 0.018)
	return m

## The floor it walks: its plan (heard duller through walls) and the Level drawing it. On the
## Playroom the body dims with the strip lights and the mask keeps glowing in count dark.
func set_floor(plan: Floor.FloorPlan, lv: Level = null) -> void:
	_plan = plan
	if lv != null and lv.has_meta("playroom"):
		var view: Object = lv.get_meta("playroom")
		view.call(&"add_lit", _body_mat)
		view.call(&"add_glow", _mask_mat, MASK_LIT, MASK_DARK, MASK_LIT_E, MASK_DARK_E)

## Reads the un-held pose from this PlayLink's network client every frame (see the header).
func follow(link: Object) -> void:
	_link = link

## The resident's pose from the two snapshots the client is drawing at its render time, blended as
## the client blends them but never held; null when there is nothing to draw from.
func _unheld() -> Variant:
	if _link == null:
		return null
	var c: Object = _link.call(&"client")
	if c == null:
		return null
	var rt: Variant = c.get("_rt")
	if rt == null:
		return null
	var br: Array = c.call(&"_bracket", float(rt))
	if br.is_empty():
		return null
	var a: Dictionary = br[0]
	var b: Dictionary = br[1]
	if a.get("orderly") == null or b.get("orderly") == null or int(a.get("depth", -1)) != int(c.get("local_depth")):
		return null
	return Pose.lerp_pose(a["orderly"], b["orderly"], float(br[2]))

# --- drawing ------------------------------------------------------------------------------------

## pose: {x, y, z, level, yaw, anim, animTime} or null; show: may it be drawn this frame. With a link
## to follow, the pose drawn is the snapshots' own, never the held one handed in.
func show_pose(pose: Variant, show: bool) -> void:
	var raw: Variant = _unheld()
	if raw != null and pose != null:
		pose = raw
		unheld_frames += 1
	if pose == null:
		visible = false
		return
	var pd: Dictionary = pose
	var p := Vector3(float(pd["x"]), float(pd["y"]), float(pd["z"]))
	var anim := str(pd["anim"])
	var now := Time.get_ticks_usec()
	if _last_us > 0:
		_t += minf((now - _last_us) / 1e6, 0.1)
	_last_us = now
	var step := 0.0
	if _last != Vector3.INF:
		var d := Vector2(p.x - _last.x, p.z - _last.z).length()
		if d < 1.0:
			step = d
	_last = p
	_dist += step
	var k := floori(_dist / NOTE_STEP)
	if k > _note_k:
		_note(p, k)
	_note_k = k
	visible = show
	if not show:
		return
	drawn = pd.duplicate()
	position = p
	rotation = Vector3(0, float(pd["yaw"]) + PI, 0)
	_pose_figure(anim, _t, _dist, step > 0.0)

## The body a pose name asks for.
static func family(anim: String) -> String:
	match anim:
		"prowl", "run", "sweep", "look", "catch", "reach":
			return "fours"
		"cover":
			return "cover"
	return "upright"

## Sets every joint from the pose name, the local clock (idle sways, the head's sweep) and the distance
## walked (the gait). Nothing here holds or waits: it is not a Stillness resident.
func _pose_figure(anim: String, t: float, dist: float, moving: bool) -> void:
	body_kind = family(anim)
	var hips_y := HIP_Y
	var hips := Vector3.ZERO
	var spine := Vector3(0.18, 0, 0)
	var chest := Vector3(0.12, 0, 0)
	var neck := Vector3(0.28, 0, 0)
	var head := Vector3(-0.52, 0, 0)
	var jaw := 0.3
	var sh := [Vector3(-0.3, 0, 0.07), Vector3(-0.3, 0, -0.07)]   # left, right
	var el := [Vector3(-0.18, 0, 0), Vector3(-0.18, 0, 0)]
	var hand := [Vector3(-0.1, 0, 0), Vector3(-0.1, 0, 0)]
	var leg := [Vector3(-0.04, 0, 0.03), Vector3(-0.04, 0, -0.03)]
	var knee := [0.09, 0.09]
	var foot := [0.0, 0.0]
	match body_kind:
		"fours":
			var run := anim == "run" or anim == "catch"
			var ph := dist / (CYCLE_FOURS * (1.25 if run else 1.0)) * TAU
			var s := sin(ph)
			var amp := 0.48 if run else 0.32
			hips_y = 0.9 if run else 0.94
			spine = Vector3(1.22 if run else 1.16, 0, 0)
			chest = Vector3(0.16, 0, 0)
			neck = Vector3(-0.45, 0, 0)
			head = Vector3(-0.85, 0, 0)
			jaw = 0.45
			hips.y = 0.06 * s
			chest.y = -0.08 * s
			hips_y += 0.03 * cos(2.0 * ph)
			# Diagonal pairs: the left hand with the right foot.
			leg[0] = Vector3(0.62 + amp * s, 0, 0.12)
			leg[1] = Vector3(0.62 - amp * s, 0, -0.12)
			knee[0] = -1.22 - 0.25 * maxf(0.0, cos(ph))
			knee[1] = -1.22 - 0.25 * maxf(0.0, -cos(ph))
			foot[0] = 0.62
			foot[1] = 0.62
			sh[0] = Vector3(-1.5 + amp * s, 0, 0.2)
			sh[1] = Vector3(-1.5 - amp * s, 0, -0.2)
			el[0] = Vector3(0.62 + 0.2 * maxf(0.0, -cos(ph)), 0, 0)
			el[1] = Vector3(0.62 + 0.2 * maxf(0.0, cos(ph)), 0, 0)
			hand[0] = Vector3(-0.85, 0, 0)
			hand[1] = Vector3(-0.85, 0, 0)
			match anim:
				"sweep":
					neck.y = 0.7 * sin(t * 2.1)
				"look":
					neck.y = 0.35 * sin(t * 0.9)
					head.x -= 0.12
				"catch":
					spine.x = 0.9
					sh[0] = Vector3(-2.3, 0, 0.25)
					sh[1] = Vector3(-2.3, 0, -0.25)
					el[0] = Vector3(-0.3, 0, 0)
					el[1] = Vector3(-0.3, 0, 0)
					neck.x = -0.2
					head.x = -0.6
					jaw = 0.65
				_:
					neck.y = 0.25 * sin(dist * 1.1)
		"cover":
			# Crouched to the wall, knees bent the wrong way, both long hands over the mask.
			hips_y = 0.74
			leg[0] = Vector3(0.95, 0, 0.18)
			leg[1] = Vector3(0.95, 0, -0.18)
			knee[0] = -1.85
			knee[1] = -1.85
			foot[0] = 0.9
			foot[1] = 0.9
			spine = Vector3(0.62, 0, 0)
			chest = Vector3(0.3, 0, 0)
			neck = Vector3(0.1, 0, 0)
			head = Vector3(-0.1 + 0.03 * sin(t * 1.4), 0, 0)
			# Two-link reach to the mask: elbows down and forward, forearms folded up over the face.
			sh[0] = Vector3(-0.8, 0, -0.6)
			sh[1] = Vector3(-0.8, 0, 0.6)
			el[0] = Vector3(-2.2, 0, 0)
			el[1] = Vector3(-2.2, 0, 0)
			hand[0] = Vector3(-0.35, 0, 0)
			hand[1] = Vector3(-0.35, 0, 0)
		_:
			match anim:
				"straighten":
					spine.x = 0.38
					sh[0] = Vector3(-1.05 + 0.12 * sin(t * 2.6), 0, 0.12)
					sh[1] = Vector3(-0.95 - 0.12 * sin(t * 2.6), 0, -0.12)
					el[0] = Vector3(-0.35, 0, 0)
					el[1] = Vector3(-0.35, 0, 0)
					neck.x = 0.4
				"slump":
					hips_y = 1.12
					spine.x = 0.5
					chest.x = 0.25
					neck.x = 0.55
					head.x = -0.25
					sh[0] = Vector3(-0.78, 0, 0.05)
					sh[1] = Vector3(-0.78, 0, -0.05)
					knee[0] = 0.22
					knee[1] = 0.22
					leg[0].x = -0.12
					leg[1].x = -0.12
			if moving or anim == "walk" or anim == "duck":
				var ph := dist / CYCLE_UP * TAU
				var s := sin(ph)
				leg[0].x += -0.36 * s
				leg[1].x += 0.36 * s
				knee[0] += 0.62 * pow(maxf(0.0, cos(ph)), 1.5)
				knee[1] += 0.62 * pow(maxf(0.0, -cos(ph)), 1.5)
				hips_y += -0.025 + 0.025 * cos(2.0 * ph)
				hips.y = 0.08 * s
				chest.y = -0.06 * s
				sh[0].x += 0.22 * s
				sh[1].x -= 0.22 * s
				neck.z = 0.06 * sin(ph * 0.5)
			else:
				chest.x += 0.02 * sin(t * 1.3)
				head.z = 0.05 * sin(t * 0.5)
				jaw += 0.05 * sin(t * 0.8)
	_j("hips").position.y = hips_y
	_j("hips").rotation = hips
	_j("spine").rotation = spine
	_j("chest").rotation = chest
	_j("neck").rotation = neck
	_j("head").rotation = head
	_j("jaw").rotation = Vector3(jaw, 0, 0)
	for i in 2:
		var sfx := "_l" if i == 0 else "_r"
		_j("shoulder" + sfx).rotation = sh[i]
		_j("elbow" + sfx).rotation = el[i]
		_j("hand" + sfx).rotation = hand[i]
		_j("leg" + sfx).rotation = leg[i]
		_j("knee" + sfx).rotation = Vector3(knee[i], 0, 0)
		var lx: float = (leg[i] as Vector3).x
		_j("ankle" + sfx).rotation = Vector3(-(lx + knee[i]) + float(foot[i]) * 0.0, 0, 0)
	# The rags hang down, whatever the body does.
	var pitch := spine.x + chest.x
	_j("rag_f").rotation = Vector3(-pitch * 0.92, 0, 0)
	_j("rag_b").rotation = Vector3(-pitch * 0.92, 0, 0)
	_j("lanyard").rotation = Vector3(-pitch * 0.85, 0, 0)

func _j(n: String) -> Node3D:
	return _joints[n]

## Tests: a short hash of everything drawn about the figure right now.
func drawn_signature() -> String:
	var f := PackedFloat32Array()
	f.append(1.0 if visible else 0.0)
	for n: Node3D in _sig_nodes:
		var x := n.transform
		for v: Vector3 in [x.basis.x, x.basis.y, x.basis.z, x.origin]:
			f.append(v.x)
			f.append(v.y)
			f.append(v.z)
	return f.to_byte_array().hex_encode().md5_text().substr(0, 12)

## Tests: the figure's extent in its own frame (feet at y 0, facing +z), from its meshes as posed.
func extent() -> AABB:
	var box := AABB()
	var first := true
	for mi: MeshInstance3D in find_children("*", "MeshInstance3D", true, false):
		var bb := mi.get_aabb()
		var xf := global_transform.affine_inverse() * mi.global_transform
		for i in 8:
			var p := xf * bb.get_endpoint(i)
			if first:
				box = AABB(p, Vector3.ZERO)
				first = false
			else:
				box = box.expand(p)
	return box

## Tests: the lowest point of either hand (its fingertips), in the figure's own frame.
func fingertip_y() -> float:
	var low := INF
	for n: String in ["hand_l", "hand_r"]:
		for mi: MeshInstance3D in _j(n).find_children("*", "MeshInstance3D", true, false):
			var bb := mi.get_aabb()
			var xf := global_transform.affine_inverse() * mi.global_transform
			for i in 8:
				low = minf(low, (xf * bb.get_endpoint(i)).y)
	return low

## Tests: the middle of a hand, palm to fingertips ("hand_l" or "hand_r"), in the figure's own frame.
func hand_middle(n: String) -> Vector3:
	return global_transform.affine_inverse() * _j(n).to_global(Vector3(0, -0.18, 0))

## Tests: where a joint is in the figure's own frame.
func joint_point(n: String) -> Vector3:
	return global_transform.affine_inverse() * _j(n).global_position

## Tests: the mask's middle and its facing in the figure's own frame (the head's +z), and how many
## meshes carry the mask's material (one: the face is on the front only).
func mask_info() -> Dictionary:
	var count := 0
	var at := Vector3.ZERO
	var facing := Vector3.ZERO
	for mi: MeshInstance3D in find_children("*", "MeshInstance3D", true, false):
		if mi.material_override == _mask_mat:
			count += 1
			var xf := global_transform.affine_inverse() * mi.global_transform
			at = xf * mi.get_aabb().get_center()
			facing = (xf.basis * Vector3.BACK).normalized()
	return {"count": count, "at": at, "facing": facing, "head": joint_point("head")}

# --- the music box --------------------------------------------------------------------------------

func _note(feet: Vector3, k: int) -> void:
	var semi := TUNE[k % TUNE.size()]
	var at := feet + Vector3(0, BOX_HEIGHT if body_kind == "upright" else 0.7, 0)
	var gain := 1.0
	var muffled := false
	var cam: Camera3D = get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam != null:
		var ear := cam.global_position
		var d := ear.distance_to(at)
		gain = pow(maxf(0.0, 1.0 - d / HEAR_RANGE), 2.0)
		if gain > 0.0 and _plan != null:
			var e := Sight.Point3.make(ear.x, ear.y, ear.z, 1 if ear.y >= Move.LEVEL_HEIGHT else 0)
			var s := Sight.Point3.make(at.x, at.y, at.z, 1 if at.y >= Move.LEVEL_HEIGHT else 0)
			if not Sight.has_line_of_sight(_plan, e, s):
				muffled = true
				gain *= MUFFLED_GAIN
	notes.append({"semi": semi, "gain": gain, "muffled": muffled, "at": at})
	if gain <= 0.0 or not is_inside_tree():
		return
	_player.global_position = at
	_player.volume_db = linear_to_db(gain) + NOTE_DB
	_player.attenuation_filter_cutoff_hz = 1500.0 if muffled else 20500.0
	_player.pitch_scale = pow(2.0, semi / 12.0)
	_player.play()

static var _note_cache: AudioStreamWAV = null

## One music-box note, made from arithmetic: a steel tine's fundamental ringing down over about a
## second, its bright inharmonic overtones gone in a tenth of that, and the pin's tiny pluck. Played at
## other pitches by pitch_scale.
static func note_stream() -> AudioStreamWAV:
	if _note_cache != null:
		return _note_cache
	var rate := 44100
	var n := int(rate * 1.1)
	var buf := PackedFloat32Array()
	buf.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5150
	var peak := 0.0
	for i in n:
		var t := float(i) / rate
		var v := 0.0
		v += sin(TAU * BASE_HZ * t) * exp(-t / 0.42)
		v += sin(TAU * BASE_HZ * 2.0 * t + 0.3) * exp(-t / 0.12) * 0.18
		v += sin(TAU * BASE_HZ * 5.4 * t + 1.1) * exp(-t / 0.03) * 0.3
		v += sin(TAU * BASE_HZ * 8.9 * t + 0.4) * exp(-t / 0.012) * 0.16
		v += rng.randf_range(-1.0, 1.0) * exp(-t / 0.0015) * 0.25
		v *= minf(1.0, i / 40.0)
		# A clean end.
		v *= minf(1.0, (n - i) / 2000.0)
		buf[i] = v
		peak = maxf(peak, absf(v))
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		data.encode_s16(i * 2, int(clampf(buf[i] / peak * 0.85, -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = false
	w.data = data
	_note_cache = w
	return w

# --- the mask -----------------------------------------------------------------------------------

static var _mask_tex: Texture2D = null

## The card party mask: an off-white oval with a printed smiley, two dots and a curve, and a faint
## pink blush; cut out round the oval (alpha).
static func mask_tex() -> Texture2D:
	if _mask_tex != null:
		return _mask_tex
	var s := 64
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var ink := Color(0.12, 0.11, 0.12, 1)
	for y in s:
		for x in s:
			var u := (x + 0.5) / s * 2.0 - 1.0
			var v := (y + 0.5) / s * 2.0 - 1.0
			var r := Vector2(u / 0.94, v / 0.98).length()
			if r > 1.0:
				continue
			var c := Color(0.97, 0.95, 0.88, 1)
			if r > 0.92:
				c = Color(0.78, 0.76, 0.7, 1)
			# Two round dots.
			for ex: float in [-0.34, 0.34]:
				if Vector2(u - ex, (v + 0.2) * 0.9).length() < 0.11:
					c = ink
			# The curve: part of a ring under them.
			var ring := Vector2(u, v + 0.02).length()
			if absf(ring - 0.52) < 0.055 and v > 0.18 and absf(u) < 0.52:
				c = ink
			for bx: float in [-0.58, 0.58]:
				if Vector2(u - bx, v - 0.18).length() < 0.13 and c != ink:
					c = c.lerp(Color(0.95, 0.62, 0.62, 1), 0.45)
			img.set_pixel(x, y, c)
	img.generate_mipmaps()
	_mask_tex = ImageTexture.create_from_image(img)
	return _mask_tex

# --- the figure ---------------------------------------------------------------------------------

func _joint(n: String, parent: Node3D, at: Vector3) -> Node3D:
	var j := Node3D.new()
	j.name = n
	j.position = at
	parent.add_child(j)
	_joints[n] = j
	_sig_nodes.append(j)
	return j

func _add(joint: String, mesh: PrimitiveMesh, at: Vector3, col: Color, rot := Vector3.ZERO, scl := Vector3.ONE) -> void:
	_add_xf(joint, mesh, Transform3D(Basis.from_euler(rot) * Basis.from_scale(scl), at), col)

func _add_xf(joint: String, mesh: PrimitiveMesh, xf: Transform3D, col: Color) -> void:
	var st: SurfaceTool = _parts.get(joint)
	if st == null:
		st = SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_parts[joint] = st
	var arr := mesh.get_mesh_arrays()
	var cols := PackedColorArray()
	cols.resize((arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size())
	cols.fill(col.srgb_to_linear())
	arr[Mesh.ARRAY_COLOR] = cols
	var tmp := ArrayMesh.new()
	tmp.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	st.append_from(tmp, 0, xf)

## A limb segment from a to b (in the joint's frame), tapering from ra to rb.
func _limb(joint: String, a: Vector3, b: Vector3, ra: float, rb: float, col: Color, seg := 10) -> void:
	var y := (b - a).normalized()
	var x := y.cross(Vector3.FORWARD if absf(y.z) < 0.9 else Vector3.RIGHT).normalized()
	var z := x.cross(y)
	_add_xf(joint, _cyl(rb, ra, a.distance_to(b), seg), Transform3D(Basis(x, y, z), (a + b) * 0.5), col)

## A flat strip from a to b, w wide and t thick, facing roughly `face`.
func _strip(joint: String, a: Vector3, b: Vector3, w: float, t: float, col: Color, face := Vector3(0, 0, 1)) -> void:
	var y := (b - a).normalized()
	var x := y.cross(face).normalized()
	var z := x.cross(y)
	var bm := BoxMesh.new()
	bm.size = Vector3(w, a.distance_to(b), t)
	_add_xf(joint, bm, Transform3D(Basis(x, y, z), (a + b) * 0.5), col)

static func _box(sx: float, sy: float, sz: float) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = Vector3(sx, sy, sz)
	return b

static func _cyl(top: float, bottom: float, h: float, seg := 10) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = top
	c.bottom_radius = bottom
	c.height = h
	c.radial_segments = seg
	c.rings = 1
	return c

static func _ball(r: float, h: float, seg := 12) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = h
	s.radial_segments = seg
	s.rings = seg / 2
	return s

## The figure faces +Z in its own space (show_pose turns it by yaw + PI, as the other residents); its
## left side is +X. Feet at y = 0.
func _build() -> void:
	_sig_nodes.append(self)
	var hips := _joint("hips", self, Vector3(0, HIP_Y, 0))
	# A narrow pelvis, the hip bones showing.
	_add("hips", _ball(0.13, 0.2), Vector3(0, 0.0, -0.01), SKIN, Vector3.ZERO, Vector3(1.05, 1, 0.7))
	for side: float in [1.0, -1.0]:
		_add("hips", _ball(0.035, 0.07, 8), Vector3(0.11 * side, 0.04, 0.06), SKIN_DARK)
	# Legs: long thin thighs and shins, knobbly knees, long splayed feet.
	for side: float in [1.0, -1.0]:
		var sfx := "_l" if side > 0.0 else "_r"
		var leg := _joint("leg" + sfx, hips, Vector3(0.12 * side, -0.04, 0))
		_limb("leg" + sfx, Vector3.ZERO, Vector3(0, -0.58, 0), 0.08, 0.056, SKIN)
		var knee := _joint("knee" + sfx, leg, Vector3(0, -0.58, 0))
		_add("knee" + sfx, _ball(0.058, 0.12, 10), Vector3(0, 0, 0.012), SKIN_DARK)
		_limb("knee" + sfx, Vector3.ZERO, Vector3(0, -0.56, 0), 0.054, 0.036, SKIN)
		var ankle := _joint("ankle" + sfx, knee, Vector3(0, -0.56, 0))
		_add("ankle" + sfx, _ball(0.04, 0.08, 8), Vector3.ZERO, SKIN_DARK)
		_add("ankle" + sfx, _box(0.09, 0.035, 0.24), Vector3(0, -0.012, 0.1), SKIN)
		for k in 3:
			var a := Vector3((k - 1) * 0.034, -0.02, 0.2)
			_limb("ankle" + sfx, a, a + Vector3((k - 1) * 0.03, -0.01, 0.12), 0.013, 0.008, SKIN_DARK, 6)
	# The waist, thin; the ribcage over it; ribs and a spine showing through the skin.
	var spine := _joint("spine", hips, Vector3(0, 0.04, 0))
	_add("spine", _cyl(0.1, 0.11, 0.34, 10), Vector3(0, 0.16, -0.02), SKIN, Vector3.ZERO, Vector3(1, 1, 0.78))
	var chest := _joint("chest", spine, Vector3(0, 0.32, 0))
	_add("chest", _ball(0.18, 0.44, 14), Vector3(0, 0.18, 0.0), SKIN, Vector3.ZERO, Vector3(1, 1, 0.72))
	for k in 5:
		var y := 0.06 + k * 0.055
		var w := 0.13 - absf(k - 1.5) * 0.012
		for side: float in [1.0, -1.0]:
			_strip("chest", Vector3(0.02 * side, y + 0.02, 0.118), Vector3(w * side, y - 0.03, 0.08), 0.022, 0.016, SKIN_DARK, Vector3(0.4 * side, 0, 1))
	for k in 8:
		_add("chest" if k < 5 else "spine", _ball(0.022, 0.04, 8), Vector3(0, (0.34 - k * 0.07) if k < 5 else (0.32 - (k - 5) * 0.09), -0.115 if k < 5 else -0.085), SKIN_DARK)
	# Collar bones and the shoulder bar.
	_limb("chest", Vector3(-0.22, 0.36, 0.01), Vector3(0.22, 0.36, 0.01), 0.045, 0.045, SKIN)
	# The tabard's rags, front and back, hanging from the shoulders (posed to hang down).
	var rag_f := _joint("rag_f", chest, Vector3(0, 0.36, 0.115))
	var rag_b := _joint("rag_b", chest, Vector3(0, 0.36, -0.115))
	var rag_cols: Array[Color] = [RAG_RED, RAG_YELLOW, RAG_BLUE]
	var lens: Array[float] = [0.62, 0.48, 0.74, 0.4, 0.66, 0.55, 0.36]
	for k in 7:
		var x := (k - 3) * 0.052
		var len := lens[k]
		_strip("rag_f", Vector3(x, 0.0, 0.02 + absf(x) * 0.1), Vector3(x + 0.02 * sin(k * 2.3), -len, 0.05), 0.05, 0.008, rag_cols[k % 3])
		_strip("rag_b", Vector3(x, 0.0, -0.02 - absf(x) * 0.1), Vector3(x - 0.02 * sin(k * 1.7), -lens[(k + 3) % 7], -0.05), 0.05, 0.008, rag_cols[(k + 1) % 3], Vector3(0, 0, -1))
	# Over the shoulders: what is left of the yoke.
	for side: float in [1.0, -1.0]:
		_add("chest", _box(0.11, 0.02, 0.26), Vector3(0.12 * side, 0.385, 0), RAG_RED if side > 0 else RAG_BLUE, Vector3(0, 0, -0.25 * side))
	# The lanyard, its badge and the wind-up music box clipped to it (posed to hang down).
	var lan := _joint("lanyard", chest, Vector3(0, 0.38, 0.06))
	_strip("lanyard", Vector3(-0.07, 0.0, 0.0), Vector3(-0.02, -0.26, 0.07), 0.016, 0.004, LANYARD)
	_strip("lanyard", Vector3(0.07, 0.0, 0.0), Vector3(0.02, -0.26, 0.07), 0.016, 0.004, LANYARD)
	_add("lanyard", _box(0.075, 0.1, 0.006), Vector3(0, -0.31, 0.075), CARD)
	_add("lanyard", _box(0.06, 0.02, 0.008), Vector3(0, -0.28, 0.078), LANYARD)
	_add("lanyard", _box(0.07, 0.06, 0.055), Vector3(0, -0.41, 0.08), BOX)
	_add("lanyard", _cyl(0.006, 0.006, 0.05, 6), Vector3(0.05, -0.41, 0.08), BRASS, Vector3(0, 0, PI * 0.5))
	_add("lanyard", _box(0.012, 0.035, 0.008), Vector3(0.075, -0.4, 0.08), BRASS)
	# The neck, long; the head: a long narrow eyeless skull, a slack jaw, and the mask on the front.
	var neck := _joint("neck", chest, Vector3(0, 0.38, 0.02))
	_limb("neck", Vector3.ZERO, Vector3(0, 0.22, 0.0), 0.05, 0.042, SKIN)
	var head := _joint("head", neck, Vector3(0, 0.22, 0))
	_add("head", _ball(0.1, 0.2, 14), Vector3(0, 0.06, 0.12), SKIN, Vector3.ZERO, Vector3(0.86, 0.95, 2.4))
	_add("head", _ball(0.07, 0.14, 12), Vector3(0, 0.03, 0.3), SKIN, Vector3.ZERO, Vector3(0.95, 0.9, 1.6))
	_add("head", _ball(0.04, 0.08, 8), Vector3(0, 0.13, 0.02), SKIN_DARK, Vector3.ZERO, Vector3(0.7, 0.6, 2.2))
	var jaw := _joint("jaw", head, Vector3(0, -0.01, 0.0))
	_add("jaw", _box(0.09, 0.026, 0.36), Vector3(0, -0.02, 0.2), SKIN)
	_add("jaw", _box(0.07, 0.006, 0.3), Vector3(0, -0.005, 0.2), MOUTH)
	for k in 9:
		var side := -1.0 if k % 2 == 0 else 1.0
		var tz := 0.1 + k * 0.028
		_add("jaw", _box(0.012, 0.016 + 0.01 * ((k * 7) % 3), 0.012), Vector3(0.033 * side, 0.008, tz), TOOTH)
	# The card mask, strapped over the front: one flat oval facing +z, nothing on the back of the head.
	var card := QuadMesh.new()
	card.size = Vector2(0.3, 0.32)
	var mask_mi := MeshInstance3D.new()
	mask_mi.name = "mask_mesh"
	mask_mi.mesh = card
	mask_mi.material_override = _mask_mat
	mask_mi.position = Vector3(0, 0.05, 0.41)
	mask_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	head.add_child(mask_mi)
	for side: float in [1.0, -1.0]:
		_strip("head", Vector3(0.12 * side, 0.06, 0.4), Vector3(0.085 * side, 0.09, -0.06), 0.012, 0.004, STRAP, Vector3(side, 0, 0))
	# Arms: long and thin, past the knees, long splayed fingers.
	for side: float in [1.0, -1.0]:
		var sfx := "_l" if side > 0.0 else "_r"
		var sh := _joint("shoulder" + sfx, chest, Vector3(0.24 * side, 0.34, 0))
		_add("shoulder" + sfx, _ball(0.055, 0.11, 10), Vector3.ZERO, SKIN_DARK)
		_limb("shoulder" + sfx, Vector3.ZERO, Vector3(0, -0.63, 0), 0.054, 0.042, SKIN)
		var el := _joint("elbow" + sfx, sh, Vector3(0, -0.63, 0))
		_add("elbow" + sfx, _ball(0.04, 0.08, 8), Vector3.ZERO, SKIN_DARK)
		_limb("elbow" + sfx, Vector3.ZERO, Vector3(0, -0.6, 0), 0.042, 0.03, SKIN)
		var hand := _joint("hand" + sfx, el, Vector3(0, -0.6, 0))
		_add("hand" + sfx, _box(0.075, 0.12, 0.03), Vector3(0, -0.06, 0), SKIN)
		for k in 4:
			var fx := (k - 1.5) * 0.022
			_limb("hand" + sfx, Vector3(fx, -0.11, 0), Vector3(fx * 2.4, -0.33 + absf(k - 1.5) * 0.03, 0.02), 0.011, 0.007, SKIN_DARK, 6)
		_limb("hand" + sfx, Vector3(-0.035 * side, -0.05, 0.01), Vector3(-0.09 * side, -0.2, 0.05), 0.011, 0.007, SKIN_DARK, 6)
	for n: String in _parts:
		var mi := MeshInstance3D.new()
		mi.name = n + "_mesh"
		mi.mesh = (_parts[n] as SurfaceTool).commit()
		mi.material_override = _body_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		_j(n).add_child(mi)
	_parts.clear()
	_pose_figure("stand", 0.0, 0.0, false)
