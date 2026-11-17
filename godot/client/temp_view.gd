# The Temp on screen (docs/floors/annex.md section 4): the Annex's resident. An office worker about
# 1.8 m tall in a short-sleeved shirt, tie and lanyard, a stapler in its right hand and a pad of
# yellow notes in its left, and over its face an A4 sheet stapled on at the corners. The sheet shows a
# bad photocopy of one crewmate's drawn face, picked by the seed. Built from meshes in code (a Blender
# figure can replace it later) and posed every frame from the resident state, like OrderlyView:
#
#   show_pose(pose, show)       pose {x, y, z, level, yaw, anim, animTime} or null; show: may it be drawn
#   set_crew(seed, faces)       the run's seed, every crewmate's face in join order (FaceCodec text, ""
#                               for none)
#   set_floor(plan, level)      the floor (to be heard duller through walls) and its Level (so the
#                               figure dims with the lights, as the Annex's own surfaces do)
#   set_watched(at)             the watched walk (two-watcher Stillness, T19a): the eye point [x, y, z] of
#                               the one watcher it walks at while it needs two, or null. Call before
#                               show_pose. Walking, its head turns to them and the stapler comes up to face
#                               height. Never while it is held (the frame gives no watcher then).
#   reset()
#
# The pose-hold rule (a Stillness resident): what is drawn is a pure function of the pose and of the
# distance the drawn pose has walked. A pose held while seen (net/client.gd) has the same numbers on
# every frame, so the figure is drawn exactly the same; no local clock moves it. Its idle fidget runs
# on the pose's own clock (animTime), its walk on the distance walked.
#
# The stapler: one click per 1.2 m walked, and one each time its own clock passes a multiple of 4 s
# while it stands (the clock stops while it is held, so a watched Temp is silent). Heard at its hand
# out to 30 m, quieter and duller through walls. Its own player and its own click, made here; on the
# "Entity" bus when the bus layout has one, otherwise on "Sfx".
class_name TempView
extends Node3D

const Rng = preload("res://sim/rng.gd")
const Floor = preload("res://sim/floor.gd")
const Sight = preload("res://sim/sight.gd")
const Move = preload("res://sim/move.gd")
const AnnexView = preload("res://client/annex_view.gd")

const CLICK_STEP := 1.2         # metres walked per click
const STAND_CLICK := 4.0        # seconds of its own clock per click while standing
const HEAR_RANGE := 30.0
const MUFFLED_GAIN := 0.45      # through a wall (Entity.MUFFLED_GAIN)
const CLICK_DB := 3.0
const HAND_HEIGHT := 1.0        # where the click comes from
const CYCLE := 1.5              # metres per full walk cycle (two steps)
const WIND_UP_TIME := 0.6       # src/sim/entity.ts: the reach is drawn out over it
const SQUEEZE_M := 0.22         # metres of walk one squeeze of the stapler lasts
const SQUEEZE_S := 0.2          # seconds one idle squeeze lasts
## The break (tests only): the walk cycle also runs on the local clock at this speed, held or not.
const BREAK_RATE := 1.5
## The watched walk: how far the head turns from the body at most (radians), and the stapler arm held up
## before the face (shoulder and elbow, radians about x).
const WATCH_TURN_MAX := 1.3
const WATCH_SHOULDER := -1.75
const WATCH_ELBOW := -1.45

## sRGB, as vertex colours.
const SKIN := Color(0.88, 0.81, 0.74)
const SHIRT := Color(0.82, 0.85, 0.88)
const POCKET := Color(0.76, 0.79, 0.83)
const TIE := Color(0.42, 0.10, 0.13)
const TROUSERS := Color(0.34, 0.34, 0.37)
const SOCK := Color(0.10, 0.10, 0.12)
const SHOE := Color(0.11, 0.08, 0.07)
const BELT := Color(0.12, 0.10, 0.09)
const METAL := Color(0.78, 0.79, 0.81)
const STAPLE := Color(0.40, 0.41, 0.44)    # darker than the paper, so the staples read on it
const HAIR := Color(0.21, 0.17, 0.14)
const LANYARD := Color(0.14, 0.26, 0.62)
const CARD := Color(0.94, 0.94, 0.91)
const PAD := Color(0.98, 0.86, 0.22)
const PAD_TOP := Color(1.0, 0.92, 0.42)
const STAPLER := Color(0.14, 0.14, 0.15)
const PEN := Color(0.12, 0.20, 0.55)
const WATCH := Color(0.08, 0.08, 0.08)
## The photocopy.
const PAPER := Color(0.93, 0.92, 0.88)
const TONER := Color(0.07, 0.07, 0.08)
const PAGE := Vector2i(120, 170)                  # A4's shape
const FACE_RECT := Rect2i(9, 26, 102, 102)        # where the face sits on the page
const SHEET := Vector2(0.21, 0.297)               # A4, metres
const SHEET_BEND := 0.15                          # radius it curves round the head with
## Light it gives off itself, as the Annex's surfaces do (annex_shade.gdshader `self_light`): the
## Annex's light is flat and even, mostly baked in. The paper is brighter, a sheet under strip lights.
const BODY_LIGHT := 0.42
const PAPER_LIGHT := 0.62

## Which crewmate's face is on the paper (index in join order), -1 for the blank face.
var picked := -1
## The face picture that went in (decoded from what the player sent, or the blank face), and the page made from it.
var face_source: Image = null
var paper_image: Image = null
## Every click so far (tests): {why: "walk"|"stand", gain, muffled, at}.
var clicks: Array[Dictionary] = []
## Tests only: advance the walk on the local clock, as a broken view would (the pose-hold check must catch it).
var break_walk_while_seen := false
## The watched walk: the one watcher's eye point (world), or null (set_watched).
var watched_at: Variant = null
var drawn: Variant = null

var _joints := {}               # name -> Node3D
var _sig_nodes: Array[Node3D] = []
var _parts := {}                # joint name -> SurfaceTool
var _body_mat: ShaderMaterial
var _paper_mat: ShaderMaterial
var _player: AudioStreamPlayer3D
var _plan: Floor.FloorPlan = null
var _rng := RandomNumberGenerator.new()
var _dist := 0.0                # metres the drawn pose has walked
var _last := Vector3.INF
var _last_pose: Variant = null
var _walk_k := 0
var _stand_k := -1
var _last_us := 0

func _init() -> void:
	_body_mat = _shade(BODY_LIGHT, true)
	_paper_mat = _shade(PAPER_LIGHT, false)
	_build()
	_player = AudioStreamPlayer3D.new()
	_player.name = "Stapler"
	_player.stream = click_stream()
	_player.top_level = true
	_player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
	_player.max_distance = HEAR_RANGE
	_player.max_polyphony = 3
	_player.attenuation_filter_cutoff_hz = 20500.0
	add_child(_player)
	set_crew("", [])
	_rng.seed = 7
	visible = false

func _ready() -> void:
	_player.bus = &"Entity" if AudioServer.get_bus_index(&"Entity") != -1 else &"Sfx"

func reset() -> void:
	_dist = 0.0
	_last = Vector3.INF
	_last_pose = null
	_walk_k = 0
	_stand_k = -1
	drawn = null
	watched_at = null
	visible = false

## The watched walk: the one watcher's eye point ([x, y, z]), or null for none.
func set_watched(at: Variant) -> void:
	if at is Array and (at as Array).size() == 3:
		watched_at = Vector3(float(at[0]), float(at[1]), float(at[2]))
	elif at is Vector3:
		watched_at = at
	else:
		watched_at = null

static func _shade(self_light: float, vcol: bool) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://client/annex_shade.gdshader")
	m.set_shader_parameter("use_vcol", 1.0 if vcol else 0.0)
	m.set_shader_parameter("self_light", self_light)
	m.set_shader_parameter("energy", 1.0)
	m.set_shader_parameter("haze", AnnexView.HAZE)
	m.set_shader_parameter("haze_density", AnnexView.HAZE_DENSITY)
	return m

## The floor it walks: its plan (heard duller through walls) and the Level drawing it, whose lights
## its materials then follow (Level.update_lights sets "energy" on every entry of `panels`).
func set_floor(plan: Floor.FloorPlan, lv: Level = null) -> void:
	_plan = plan
	if lv != null:
		for m: ShaderMaterial in [_body_mat, _paper_mat]:
			lv.panels.append({"mat": m, "dead": false, "k": 1.0})

## The run's seed and every crewmate's face in join order: the paper shows the face of crewmate
## hash(seed + ":temp") mod the crew's size, photocopied; the blank face if that one drew none or
## there is nobody.
func set_crew(seed: String, faces: Array[String]) -> void:
	picked = pick_index(seed, faces.size())
	var src: Image = null
	if picked >= 0:
		var px := FaceCodec.decode_indices(faces[picked])
		if not px.is_empty():
			src = FaceCodec.to_image(px)
	if src == null:
		src = blank_face()
	face_source = src
	paper_image = photocopy(src, seed)
	var img := paper_image.duplicate() as Image
	img.generate_mipmaps()
	_paper_mat.set_shader_parameter("albedo_tex", ImageTexture.create_from_image(img))

static func pick_index(seed: String, count: int) -> int:
	if count <= 0:
		return -1
	return Rng.hash_seed(seed + ":temp") % count

## The plain face photocopied when there is no drawing to copy (the masks' own default face).
static func blank_face() -> Image:
	return CrewView.default_face().get_image()

# --- drawing ------------------------------------------------------------------------------------

## pose: {x, y, z, level, yaw, anim, animTime} or null; show: may it be drawn this frame.
func show_pose(pose: Variant, show: bool) -> void:
	if pose == null:
		visible = false
		_last_pose = null
		return
	var pd: Dictionary = pose
	var p := Vector3(float(pd["x"]), float(pd["y"]), float(pd["z"]))
	var anim := str(pd["anim"])
	var t := float(pd["animTime"])
	var held := _last_pose != null and _same(pd, _last_pose)
	var step := 0.0
	if _last != Vector3.INF:
		var d := Vector2(p.x - _last.x, p.z - _last.z).length()
		if d < 1.0:
			step = d
	_last = p
	_last_pose = pd.duplicate()
	var now := Time.get_ticks_usec()
	if break_walk_while_seen and (anim == "walk" or anim == "duck") and _last_us > 0:
		step += BREAK_RATE * minf((now - _last_us) / 1e6, 0.1)
	_last_us = now
	_dist += step
	# The clicks: per 1.2 m walked; standing, each 4 s of its own clock (stopped while held).
	var k := floori(_dist / CLICK_STEP)
	if k > _walk_k:
		_click("walk", p)
	_walk_k = k
	if anim == "idle" and step == 0.0:
		if not held:
			var sk := floori(t / STAND_CLICK)
			if _stand_k >= 0 and sk > _stand_k:
				_click("stand", p)
			_stand_k = sk
	else:
		_stand_k = -1
	visible = show
	if not show:
		return
	drawn = pd
	position = p
	rotation = Vector3(0, float(pd["yaw"]) + PI, 0)
	_pose_figure(anim, t, _dist)

static func _same(a: Dictionary, b: Dictionary) -> bool:
	for k: String in ["x", "y", "z", "level", "yaw", "anim", "animTime"]:
		if a.get(k) != b.get(k):
			return false
	return true

static func _pulse(x: float) -> float:
	return sin(x * PI) if x >= 0.0 and x < 1.0 else 0.0

## Sets every joint from the animation hint, its clock and the distance walked (nothing else).
func _pose_figure(anim: String, t: float, dist: float) -> void:
	var hips_y := 0.95
	var hips := Vector3.ZERO
	var spine := Vector3(0.07, 0, 0)
	var neck := Vector3(0.16, 0, 0)
	var head := Vector3(-0.14, 0, 0.11)
	var sh_r := Vector3(-0.32, 0, -0.10)
	var el_r := Vector3(-1.18, 0, 0)
	var sh_l := Vector3(-0.24, 0, 0.12)
	var el_l := Vector3(-1.30, 0, 0)
	var pad := Vector3(PI * 0.5 - 0.55, 0, 0)
	var leg_l := Vector3(0, 0, 0.025)
	var leg_r := Vector3(0, 0, -0.025)
	var knee_l := 0.03
	var knee_r := 0.03
	var top := -0.12
	var squeeze := 0.0
	match anim:
		"walk", "duck":
			var ph := dist / CYCLE * TAU
			var s := sin(ph)
			leg_l.x = -0.40 * s
			leg_r.x = 0.40 * s
			knee_l = 0.05 + 0.75 * pow(maxf(0.0, cos(ph)), 1.5)
			knee_r = 0.05 + 0.75 * pow(maxf(0.0, -cos(ph)), 1.5)
			hips_y = 0.95 - 0.016 + 0.016 * cos(2.0 * ph)
			hips.y = 0.09 * s
			spine.y = -0.07 * s
			spine.x += 0.05
			head.x -= 0.04
			sh_r.x -= 0.09 * s
			sh_l.x += 0.09 * s
			el_r.x -= 0.05 * s
			el_l.x += 0.05 * s
			squeeze = _pulse(fmod(dist, CLICK_STEP) / SQUEEZE_M)
			if watched_at is Vector3:
				# The watched walk: head locked on its one watcher, the stapler up at face height.
				var local := transform.affine_inverse() * (watched_at as Vector3)
				var turn := clampf(atan2(local.x, local.z), -WATCH_TURN_MAX, WATCH_TURN_MAX)
				neck.y = turn * 0.35
				head.y = turn * 0.65 - hips.y - spine.y
				head.x += 0.04
				sh_r = Vector3(WATCH_SHOULDER, 0, -0.18)
				el_r = Vector3(WATCH_ELBOW, 0, 0)
		"reach":
			var k := clampf(t / WIND_UP_TIME, 0.0, 1.0)
			var e := k * k * (3.0 - 2.0 * k)
			spine.x += 0.32 * e
			neck.x += 0.06 * e
			head.x -= 0.26 * e
			head.z *= 1.0 - e
			sh_r = sh_r.lerp(Vector3(-1.62, 0, -0.02), e)
			el_r = el_r.lerp(Vector3(-0.50, 0, 0), e)
			sh_l = sh_l.lerp(Vector3(-0.05, 0, 0.18), e)
			el_l = el_l.lerp(Vector3(-0.85, 0, 0), e)
			top = lerpf(top, -0.55, e)
		"bend":
			# Bent over a downed player (sim/entity.gd "bending"): folded down over them, the stapler held
			# out, the head working down and up on the pose's own clock.
			var k := clampf(t / 0.8, 0.0, 1.0)
			var e := k * k * (3.0 - 2.0 * k)
			var chew := 0.5 - 0.5 * cos(t * TAU * 1.4)
			spine.x += (0.95 + 0.06 * chew) * e
			neck.x += (0.25 + 0.12 * chew) * e
			head.x += (0.10 + 0.20 * chew) * e
			head.z *= 1.0 - e
			sh_r = sh_r.lerp(Vector3(-1.35, 0, -0.05), e)
			el_r = el_r.lerp(Vector3(-0.40, 0, 0), e)
			sh_l = sh_l.lerp(Vector3(-1.20, 0, 0.12), e)
			el_l = el_l.lerp(Vector3(-0.50, 0, 0), e)
		_:
			# Idle: it squeezes the stapler as its clock passes each 4 s (when it clicks), looks down at
			# it in between, breathes, and its head lolls a little.
			var p := fmod(t, STAND_CLICK)
			squeeze = _pulse(p / SQUEEZE_S)
			var look := smoothstep(1.3, 1.9, p) * (1.0 - smoothstep(3.0, 3.8, p))
			head.x += 0.22 * look
			neck.x += 0.04 * look
			el_r.x -= 0.16 * look
			sh_r.x -= 0.05 * look
			spine.x += 0.012 * sin(t * 1.7)
			head.z += 0.035 * sin(t * 0.45)
			el_l.x += 0.03 * sin(t * 1.1 + 0.7)
	el_r.x -= 0.07 * squeeze
	top += 0.14 * squeeze
	_j("hips").position.y = hips_y
	_j("hips").rotation = hips
	_j("spine").rotation = spine
	_j("neck").rotation = neck
	_j("head").rotation = head
	_j("shoulder_r").rotation = sh_r
	_j("elbow_r").rotation = el_r
	_j("shoulder_l").rotation = sh_l
	_j("elbow_l").rotation = el_l
	_j("pad").rotation = pad
	_j("leg_l").rotation = leg_l
	_j("leg_r").rotation = leg_r
	_j("knee_l").rotation = Vector3(knee_l, 0, 0)
	_j("knee_r").rotation = Vector3(knee_r, 0, 0)
	# The feet stay near flat on the floor.
	_j("ankle_l").rotation = Vector3(-(leg_l.x + knee_l) * 0.75, 0, -leg_l.z)
	_j("ankle_r").rotation = Vector3(-(leg_r.x + knee_r) * 0.75, 0, -leg_r.z)
	_j("stapler_top").rotation = Vector3(top, 0, 0)

func _j(n: String) -> Node3D:
	return _joints[n]

## Tests: a short hash of everything drawn about the figure right now (visibility, where it stands
## and every joint), to show it never changes on a frame the camera sees it.
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

## Tests: a hash of the picture on the paper as its material holds it.
func paper_hash() -> String:
	return CrewView.texture_hash(_paper_mat.get_shader_parameter("albedo_tex") as Texture2D)

## Tests: the top of the figure above its feet when standing idle (metres), from its meshes.
func standing_height() -> float:
	var top := 0.0
	for mi: MeshInstance3D in find_children("*", "MeshInstance3D", true, false):
		var bb := mi.get_aabb()
		var xf := global_transform.affine_inverse() * mi.global_transform
		for i in 8:
			top = maxf(top, (xf * bb.get_endpoint(i)).y)
	return top

# --- the click ----------------------------------------------------------------------------------

func _click(why: String, feet: Vector3) -> void:
	var at := feet + Vector3(0, HAND_HEIGHT, 0)
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
	clicks.append({"why": why, "gain": gain, "muffled": muffled, "at": at})
	if gain <= 0.0 or not is_inside_tree():
		return
	_player.global_position = at
	_player.volume_db = linear_to_db(gain) + CLICK_DB
	_player.attenuation_filter_cutoff_hz = 1300.0 if muffled else 20500.0
	_player.pitch_scale = 0.94 + 0.12 * _rng.randf()
	_player.play()

static var _click_cache: AudioStreamWAV = null

## A stapler, made from arithmetic: the clack of the arm striking (a noise tick, the plastic body's
## knock and three bright metal modes), then 26 ms later the smaller crunch of the staple's legs
## folding. Short and dry: no tail, no room.
static func click_stream() -> AudioStreamWAV:
	if _click_cache != null:
		return _click_cache
	var rate := 44100
	var n := int(rate * 0.075)
	var buf := PackedFloat32Array()
	buf.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var peak := 0.0
	for i in n:
		var t := float(i) / rate
		var v := 0.0
		v += rng.randf_range(-1.0, 1.0) * exp(-t / 0.0012) * 0.9
		v += sin(TAU * 190.0 * t) * exp(-t / 0.009) * 0.35
		v += sin(TAU * 2950.0 * t) * exp(-t / 0.011) * 0.42
		v += sin(TAU * 4720.0 * t + 0.6) * exp(-t / 0.007) * 0.30
		v += sin(TAU * 7310.0 * t + 1.1) * exp(-t / 0.004) * 0.22
		var t2 := t - 0.026
		if t2 >= 0.0:
			v += rng.randf_range(-1.0, 1.0) * exp(-t2 / 0.0009) * 0.45
			v += sin(TAU * 3820.0 * t2) * exp(-t2 / 0.006) * 0.25
		# A click's own fade-in of a few samples so it never pops.
		v *= minf(1.0, i / 12.0)
		buf[i] = v
		peak = maxf(peak, absf(v))
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		data.encode_s16(i * 2, int(clampf(buf[i] / peak * 0.9, -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = false
	w.data = data
	_click_cache = w
	return w

# --- the photocopy ------------------------------------------------------------------------------

## A bad photocopy of a face on an A4 page: grey, high contrast, a little skewed and wobbly, smeared
## down the page, toner fog and specks, a drum streak, dark where the lid let light in. The same face
## and seed always give the same page (every screen shows the same Temp).
static func photocopy(src: Image, seed: String) -> Image:
	var rng := RandomNumberGenerator.new()
	rng.seed = Rng.hash_seed(seed + ":copy")
	var img := src.duplicate() as Image
	img.clear_mipmaps()
	img.convert(Image.FORMAT_RGB8)
	var sw := img.get_width()
	var sh := img.get_height()
	var lum := PackedFloat32Array()
	lum.resize(sw * sh)
	for y in sh:
		for x in sw:
			lum[y * sw + x] = img.get_pixel(x, y).get_luminance()
	var w := PAGE.x
	var h := PAGE.y
	var dens := PackedFloat32Array()
	dens.resize(w * h)
	var ang := deg_to_rad(rng.randf_range(-3.5, 3.5))
	var wob := rng.randf() * TAU
	var centre := Vector2(FACE_RECT.position) + Vector2(FACE_RECT.size) * 0.5
	var size := Vector2(FACE_RECT.size)
	for y in h:
		for x in w:
			var q := (Vector2(x + 0.5, y + 0.5) - centre).rotated(ang)
			q.x += 1.4 * sin(y * 0.42 + wob)
			var uv := q / size + Vector2(0.5, 0.5)
			var d := 0.0
			if uv.x >= 0.0 and uv.x <= 1.0 and uv.y >= 0.0 and uv.y <= 1.0:
				d = 1.0 - smoothstep(0.30, 0.70, _sample(lum, sw, sh, uv))
				# The lit screen it was copied from comes out as a grey plate with a darker rim.
				var edge := minf(minf(uv.x, 1.0 - uv.x), minf(uv.y, 1.0 - uv.y))
				d = maxf(d, 0.07 + 0.4 * (1.0 - smoothstep(0.0, 0.03, edge)))
			dens[y * w + x] = d
	# Smeared down the page as it fed, heavier toward one side.
	var right := rng.randf() < 0.5
	for x in w:
		var f := float(x) / (w - 1)
		var k := lerpf(0.50, 0.88, f if right else 1.0 - f)
		var carry := 0.0
		for y in h:
			var i := y * w + x
			carry = maxf(dens[i], carry * k)
			dens[i] = maxf(dens[i], carry * 0.78)
	var streak := rng.randi_range(14, w - 14)
	var lid := rng.randf_range(3.0, 7.0)
	var out := Image.create(w, h, false, Image.FORMAT_RGB8)
	for y in h:
		for x in w:
			var v := dens[y * w + x]
			v = smoothstep(0.26, 0.60, v) * 0.9 + v * 0.1
			v += rng.randf() * 0.06
			if rng.randf() < 0.012:
				v += 0.65
			if x == streak and fmod(y * 0.11, 1.0) < 0.85:
				v += 0.3
			# The lid's shadow along the left and top edges.
			v += 0.55 * (1.0 - smoothstep(0.0, lid, float(x)))
			v += 0.35 * (1.0 - smoothstep(0.0, lid * 0.6, float(y)))
			out.set_pixel(x, y, PAPER.lerp(TONER, clampf(v, 0.0, 1.0)))
	return out

static func _sample(lum: PackedFloat32Array, sw: int, sh: int, uv: Vector2) -> float:
	var fx := uv.x * sw - 0.5
	var fy := uv.y * sh - 0.5
	var x0 := clampi(floori(fx), 0, sw - 1)
	var y0 := clampi(floori(fy), 0, sh - 1)
	var x1 := clampi(x0 + 1, 0, sw - 1)
	var y1 := clampi(y0 + 1, 0, sh - 1)
	var tx := clampf(fx - floorf(fx), 0.0, 1.0)
	var ty := clampf(fy - floorf(fy), 0.0, 1.0)
	var a := lerpf(lum[y0 * sw + x0], lum[y0 * sw + x1], tx)
	var b := lerpf(lum[y1 * sw + x0], lum[y1 * sw + x1], tx)
	return lerpf(a, b, ty)

# --- the figure ---------------------------------------------------------------------------------

func _joint(n: String, parent: Node3D, at: Vector3) -> Node3D:
	var j := Node3D.new()
	j.name = n
	j.position = at
	parent.add_child(j)
	_joints[n] = j
	_sig_nodes.append(j)
	return j

## One part, its colour baked into the joint's single mesh (one draw per joint).
func _add(joint: String, mesh: PrimitiveMesh, at: Vector3, col: Color, rot := Vector3.ZERO, scl := Vector3.ONE) -> void:
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
	st.append_from(tmp, 0, Transform3D(Basis.from_euler(rot) * Basis.from_scale(scl), at))

## A box from a to b (its long side), w wide and t thick, facing roughly `face`.
func _strip(joint: String, a: Vector3, b: Vector3, w: float, t: float, col: Color, face := Vector3(0, 0, 1)) -> void:
	var y := (b - a).normalized()
	var x := y.cross(face).normalized()
	var z := x.cross(y)
	var bm := BoxMesh.new()
	bm.size = Vector3(w, a.distance_to(b), t)
	_add_xf(joint, bm, Transform3D(Basis(x, y, z), (a + b) * 0.5), col)

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

static func _box(sx: float, sy: float, sz: float) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = Vector3(sx, sy, sz)
	return b

static func _cyl(top: float, bottom: float, h: float, seg := 14) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = top
	c.bottom_radius = bottom
	c.height = h
	c.radial_segments = seg
	c.rings = 1
	return c

static func _ball(r: float, h: float, seg := 16) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = h
	s.radial_segments = seg
	s.rings = seg / 2
	return s

## The figure faces +Z in its own space (show_pose turns it by yaw + PI, as OrderlyView); its right
## hand is on -X. Feet at y = 0, top of the paper at about 1.81 m.
func _build() -> void:
	_sig_nodes.append(self)
	var hips := _joint("hips", self, Vector3(0, 0.95, 0))
	# Trousers and belt.
	_add("hips", _cyl(0.172, 0.165, 0.16), Vector3(0, -0.03, 0), TROUSERS, Vector3.ZERO, Vector3(1, 1, 0.66))
	_add("hips", _ball(0.13, 0.18), Vector3(0, -0.09, 0), TROUSERS, Vector3.ZERO, Vector3(1.05, 1, 0.75))
	_add("hips", _cyl(0.176, 0.176, 0.036), Vector3(0, 0.045, 0), BELT, Vector3.ZERO, Vector3(1, 1, 0.67))
	_add("hips", _box(0.042, 0.03, 0.012), Vector3(0, 0.045, 0.118), METAL)
	for side: float in [1.0, -1.0]:
		var sfx := "_l" if side > 0.0 else "_r"
		var leg := _joint("leg" + sfx, hips, Vector3(0.092 * side, -0.02, 0))
		_add("leg" + sfx, _cyl(0.078, 0.062, 0.44), Vector3(0, -0.22, 0), TROUSERS)
		var knee := _joint("knee" + sfx, leg, Vector3(0, -0.43, 0))
		_add("knee" + sfx, _ball(0.062, 0.12), Vector3.ZERO, TROUSERS)
		_add("knee" + sfx, _cyl(0.061, 0.056, 0.40), Vector3(0, -0.20, 0), TROUSERS)
		_add("knee" + sfx, _cyl(0.04, 0.04, 0.05), Vector3(0, -0.41, 0), SOCK)
		var ankle := _joint("ankle" + sfx, knee, Vector3(0, -0.43, 0))
		_add("ankle" + sfx, _box(0.098, 0.072, 0.21), Vector3(0, -0.035, 0.035), SHOE)
		_add("ankle" + sfx, _ball(0.05, 0.072), Vector3(0, -0.035, 0.14), SHOE, Vector3.ZERO, Vector3(0.98, 1, 1.15))
		_add("ankle" + sfx, _box(0.1, 0.012, 0.25), Vector3(0, -0.066, 0.055), Color(0.05, 0.04, 0.04))
	# The shirt: a soft body with a small belly, rounded shoulders, a collar and a breast pocket.
	var spine := _joint("spine", hips, Vector3(0, 0.05, 0))
	_add("spine", _cyl(0.19, 0.172, 0.46), Vector3(0, 0.23, 0), SHIRT, Vector3.ZERO, Vector3(1, 1, 0.62))
	_add("spine", _ball(0.16, 0.30), Vector3(0, 0.12, 0.03), SHIRT, Vector3.ZERO, Vector3(1, 1, 0.56))
	var yoke := CapsuleMesh.new()
	yoke.radius = 0.072
	yoke.height = 0.48
	_add("spine", yoke, Vector3(0, 0.40, -0.005), SHIRT, Vector3(0, 0, PI * 0.5), Vector3(1, 1, 0.95))
	_add("spine", _cyl(0.058, 0.075, 0.05), Vector3(0, 0.475, 0), SHIRT)
	for side: float in [1.0, -1.0]:
		_add("spine", _box(0.05, 0.012, 0.045), Vector3(0.028 * side, 0.478, 0.07), SHIRT, Vector3(0.5, 0, -0.55 * side))
	_add("spine", _box(0.075, 0.085, 0.006), Vector3(0.085, 0.31, 0.104), POCKET, Vector3(0, 0.42, 0))
	_add("spine", _cyl(0.0055, 0.0055, 0.07, 6), Vector3(0.10, 0.345, 0.106), PEN)
	_add("spine", _cyl(0.0055, 0.0055, 0.06, 6), Vector3(0.078, 0.34, 0.108), Color(0.6, 0.12, 0.10))
	# The tie: knot, blade and its point, lying on the shirt.
	_add("spine", _box(0.036, 0.034, 0.022), Vector3(0, 0.445, 0.112), TIE)
	_add("spine", _box(0.05, 0.30, 0.008), Vector3(0, 0.275, 0.122), TIE, Vector3(0.06, 0, 0.02))
	_add("spine", _box(0.036, 0.036, 0.008), Vector3(0.003, 0.125, 0.131), TIE, Vector3(0.06, 0, PI * 0.25))
	# The lanyard round the neck and its ID card.
	var card := Vector3(-0.06, 0.20, 0.125)
	_strip("spine", Vector3(-0.045, 0.47, 0.055), card + Vector3(-0.012, 0.045, -0.004), 0.011, 0.003, LANYARD)
	_strip("spine", Vector3(0.04, 0.47, 0.06), card + Vector3(0.012, 0.045, -0.004), 0.011, 0.003, LANYARD)
	_add("spine", _box(0.056, 0.084, 0.004), card, CARD, Vector3(0.12, 0, 0))
	_add("spine", _box(0.056, 0.018, 0.005), card + Vector3(0, 0.032, 0.002), LANYARD, Vector3(0.12, 0, 0))
	_add("spine", _box(0.02, 0.024, 0.005), card + Vector3(-0.013, -0.002, 0.002), Color(0.45, 0.45, 0.45), Vector3(0.12, 0, 0))
	# Neck, head, ears, hair.
	var neck := _joint("neck", spine, Vector3(0, 0.47, 0))
	_add("neck", _cyl(0.05, 0.053, 0.12), Vector3(0, 0.03, 0), SKIN)
	var head := _joint("head", neck, Vector3(0, 0.09, 0))
	_add("head", _ball(0.103, 0.236), Vector3(0, 0.10, 0), SKIN)
	_add("head", _ball(0.108, 0.20), Vector3(0, 0.138, -0.014), HAIR, Vector3(-0.15, 0, 0))
	for side: float in [1.0, -1.0]:
		_add("head", _ball(0.024, 0.052, 8), Vector3(0.101 * side, 0.095, -0.006), SKIN, Vector3.ZERO, Vector3(0.45, 1, 1))
	# The sheet over the face and its four staples.
	_paper(head)
	# Arms: short sleeves, bare forearms, a watch on the left wrist.
	for side: float in [1.0, -1.0]:
		var sfx := "_l" if side > 0.0 else "_r"
		var sh := _joint("shoulder" + sfx, spine, Vector3(0.205 * side, 0.41, 0))
		_add("shoulder" + sfx, _cyl(0.066, 0.06, 0.16), Vector3(0, -0.06, 0), SHIRT)
		_add("shoulder" + sfx, _cyl(0.045, 0.042, 0.14), Vector3(0, -0.19, 0), SKIN)
		var el := _joint("elbow" + sfx, sh, Vector3(0, -0.27, 0))
		_add("elbow" + sfx, _ball(0.043, 0.086, 10), Vector3.ZERO, SKIN)
		_add("elbow" + sfx, _cyl(0.041, 0.033, 0.23), Vector3(0, -0.115, 0), SKIN)
		_add("elbow" + sfx, _ball(0.042, 0.10, 10), Vector3(0, -0.285, 0), SKIN, Vector3.ZERO, Vector3(1, 1, 0.62))
		if side > 0.0:
			_add("elbow" + sfx, _cyl(0.037, 0.037, 0.022, 10), Vector3(0, -0.215, 0), WATCH)
	# The stapler in the right fist: front along the forearm, top up; its arm hinged at the back.
	var st := _joint("stapler", _j("elbow_r"), Vector3(0, -0.29, 0.0))
	st.rotation = Vector3(PI * 0.5, 0, 0)
	_add("stapler", _box(0.036, 0.016, 0.16), Vector3(0, -0.02, 0.035), STAPLER)
	_add("stapler", _box(0.03, 0.006, 0.05), Vector3(0, -0.009, 0.10), METAL)
	var top := _joint("stapler_top", st, Vector3(0, -0.006, -0.04))
	_add("stapler_top", _box(0.034, 0.022, 0.15), Vector3(0, 0.014, 0.075), STAPLER)
	_add("stapler_top", _box(0.022, 0.004, 0.125), Vector3(0, 0.026, 0.078), METAL)
	_add("stapler_top", _box(0.03, 0.014, 0.012), Vector3(0, 0.008, 0.148), METAL)
	top.rotation = Vector3(-0.12, 0, 0)
	# The pad of yellow notes in the left hand, tilted up to be read.
	var pad := _joint("pad", _j("elbow_l"), Vector3(0, -0.29, 0.0))
	_add("pad", _box(0.078, 0.014, 0.078), Vector3(0, 0.0, 0.025), PAD)
	_add("pad", _box(0.076, 0.002, 0.07), Vector3(0, 0.0085, 0.021), PAD_TOP, Vector3(-0.10, 0, 0.02))
	for n: String in _parts:
		var mi := MeshInstance3D.new()
		mi.name = n + "_mesh"
		mi.mesh = (_parts[n] as SurfaceTool).commit()
		mi.material_override = _body_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		_j(n).add_child(mi)
	_parts.clear()
	_pose_figure("idle", 0.5, 0.0)

## An A4 sheet bent round the front of the head (its middle at the head's centre), the bottom
## curling off the chin, with a staple across each corner.
func _paper(head: Node3D) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var nu := 10
	var nv := 12
	var zc := 0.118
	var cy := 0.10
	var pts: Array[Vector3] = []
	for j in nv + 1:
		for i in nu + 1:
			var u := float(i) / nu
			var v := float(j) / nv
			var a := (u - 0.5) * SHEET.x / SHEET_BEND
			var x := SHEET_BEND * sin(a)
			var z := zc - SHEET_BEND * (1.0 - cos(a))
			var y := cy + (0.5 - v) * SHEET.y
			if v > 0.78:
				z += 0.05 * pow((v - 0.78) / 0.22, 2.0)
			if v < 0.12:
				z += 0.012 * pow((0.12 - v) / 0.12, 2.0)
			# A slight ripple, as paper does.
			z += 0.003 * sin(u * 7.0 + v * 3.0)
			var p := Vector3(x, y, z)
			pts.append(p)
			st.set_uv(Vector2(u, v))
			st.set_normal(Vector3(sin(a), 0, cos(a)))
			st.add_vertex(p)
	# The back of the sheet: the same points wound the other way, plain paper.
	var back := SurfaceTool.new()
	back.begin(Mesh.PRIMITIVE_TRIANGLES)
	for j in nv + 1:
		for i in nu + 1:
			var a := (float(i) / nu - 0.5) * SHEET.x / SHEET_BEND
			back.set_color((PAPER * 0.8).srgb_to_linear())
			back.set_normal(-Vector3(sin(a), 0, cos(a)))
			back.add_vertex(pts[j * (nu + 1) + i] - Vector3(sin(a), 0, cos(a)) * 0.0008)
	for j in nv:
		for i in nu:
			var a := j * (nu + 1) + i
			var b := a + 1
			var c := a + nu + 1
			var d := c + 1
			for k: int in [a, b, c, b, d, c]:
				st.add_index(k)
			for k: int in [a, c, b, b, c, d]:
				back.add_index(k)
	for pair: Array in [[st, _paper_mat, "paper_mesh"], [back, _body_mat, "paper_back_mesh"]]:
		var mi := MeshInstance3D.new()
		mi.name = pair[2]
		mi.mesh = (pair[0] as SurfaceTool).commit()
		mi.material_override = pair[1]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		head.add_child(mi)
	# Staples: inset 1.4 cm from each corner, across it diagonally, standing just off the paper.
	for corner: Vector2i in [Vector2i(0, 0), Vector2i(nu, 0), Vector2i(0, nv), Vector2i(nu, nv)]:
		var ci := corner.x
		var cj := corner.y
		var ii := ci + (1 if ci == 0 else -1)
		var jj := cj + (1 if cj == 0 else -1)
		var p0 := pts[cj * (nu + 1) + ci]
		var p1 := pts[jj * (nu + 1) + ii]
		var at := p0.lerp(p1, 0.72)
		var dir := (p1 - p0).normalized()
		var n := (pts[cj * (nu + 1) + ii] - p0).cross(pts[jj * (nu + 1) + ci] - p0).normalized()
		if n.z < 0.0:
			n = -n
		var across := dir.cross(n).normalized()
		_strip("head", at - across * 0.011 + n * 0.0015, at + across * 0.011 + n * 0.0015, 0.004, 0.003, STAPLE, n)
