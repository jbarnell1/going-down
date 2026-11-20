# The four on the Reactor's floor (the-intact-crew.md: "Each has a wasted human body, a bloody, loose uniform,
# and its own drawn face on a damaged TV screen"; "Film the same crewmate bodies and rigs the players use").
# Each is the players' own figure (client/crew_view.gd, assets/entities/crewmate.glb, built by
# assets_src/blender/convict/build_crewmate.py), dressed here: the skin drained grey, the suit darkened and
# blood-soaked from a pattern seeded by seat, the limbs and trunk drawn thinner (a skeleton modifier, so the
# suit hangs on a wasted frame), the screen cracked with a dead band across it and lit pale so the drawing reads
# in the dark, and the seat number 1 to 4 on the patches.
#
# The host's `reactor` block says where each is and what it does (crew: [x, y, z, yaw, tilt, phase, clock] per
# seat, or {at, yaw, phase/state, clock, seat}); this draws it at the client's render time, between the two
# snapshots every other resident is interpolated between (client/station_view.gd hands both blocks over), so a
# late packet never shows one further on than the host has it. States: lying still while the station has power,
# crawling, standing, pursuing. Clips: the crew rig's own "taken" (its last frame lies on the floor), "crawl",
# "get_up" and "run"; the two downloaded Mixamo takes "zombie_crawl" and "zombie_run", retargeted onto this same
# rig and baked into the game model assets/station/crew_zombie.glb (assets_src/blender/convict/build_zombie_clips.py
# and zombie_clips.mjs), are played instead, at the host's clock, when every track resolves on this skeleton.
# Without that file the rig's own crawl and run are played.
#
# Heard before seen: the scrape (the library's bed roll, assets/sfx/clinic/bed_roll.ogg) plays from the four the
# moment the power cuts, before any of them moves (the host starts the first crawl 1.1 s after the cut); a
# figure the block already shows moving is held in its last still pose until that cue has been heard for
# HEARD_LEAD seconds. While they crawl, the library's crawl drag (player/crawl.ogg) comes from each; standing,
# the crew's winded breath (player/breath_winded.ogg) and the crew's footsteps (Sfx.step_at).
extends Node3D

const FaceImage = preload("res://client/station_faces.gd")
const Point = preload("res://client/station_point.gd")
const ZOMBIE_MOTION := "res://assets/station/crew_zombie.glb"
const ZOMBIE_CLIPS: Array[String] = ["zombie_crawl", "zombie_run"]
const SEATS := 4
const HEARD_LEAD := 0.25
const SCREEN_GLOW := 0.95
const SKIN_TINT := Color(0.70, 0.72, 0.64)
const THIN := 0.78
## Thinned across: the trunk (so the neck, shoulders and arms under it follow) and both legs. The head is scaled
## back so the mask keeps its size.
const THIN_BONES: Array[String] = ["Spine", "LeftUpLeg", "RightUpLeg"]
const STEP_LEN := 1.0
const CRAWL_SND := "res://assets/sfx/player/crawl.ogg"
const BREATH_SND := "res://assets/sfx/player/breath_winded.ogg"
const CUE_SND := "res://assets/sfx/clinic/bed_roll.ogg"
## Tests only. "face": every seat wears seat 1's face; "smooth": draw the newer snapshot only (no interpolation);
## "state": every figure is drawn lying whatever the block says.
static var test_break := ""
## Off: play the rig's own crawl and run, as without assets/station/crew_zombie.glb (tests of that fallback).
static var zombie_motion := true

var figures: Array[CrewView] = []
var sfx: Node = null
var power := 0
var zombie_clips := false
## Per seat: the state drawn, the clip, the seat number, how far it has gone (for the stride-matched clips).
var states: Array[String] = []
var seats: Array[int] = []
var _dist: Array[float] = []
var _last: Array[Vector3] = []
var _steps: Array[float] = []
var _crawl: Array[AudioStreamPlayer3D] = []
var _breath: Array[AudioStreamPlayer3D] = []
var _cue: AudioStreamPlayer3D
var _cue_at := -1.0          # seconds (Time) the scrape started; -1 not yet
var _bodies: Array = []
var _built := false

static var _suits := {}
static var _zombie_lib: AnimationLibrary = null
static var _zombie_tried := false

func _ready() -> void:
	_build()

func _build() -> void:
	if _built:
		return
	_built = true
	for i in SEATS:
		var v := CrewView.new()
		v.name = "Seat%d" % (i + 1)
		add_child(v)
		figures.append(v)
		states.append("lying")
		seats.append(i + 1)
		_dist.append(0.0)
		_last.append(Vector3.INF)
		_steps.append(0.0)
		_crawl.append(_audio(CRAWL_SND, &"Entity", 2.0, 14.0, true))
		_breath.append(_audio(BREATH_SND, &"Entity", 1.5, 8.0, true))
		v.add_child(_crawl[i])
		v.add_child(_breath[i])
		_dress(v, i + 1)
	_cue = _audio(CUE_SND, &"Entity", 6.0, 45.0, false)
	add_child(_cue)
	zombie_clips = _add_zombie_clips()
	set_bodies(_bodies)

func _audio(path: String, bus: StringName, unit: float, far: float, loop: bool) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.bus = bus
	p.unit_size = unit
	p.max_distance = far
	p.volume_db = Sfx.BASE_DB
	p.position = Vector3(0, 0.5, 0)
	if ResourceLoader.exists(path):
		var st: AudioStream = load(path)
		if loop and st is AudioStreamOggVorbis:
			st = (st as AudioStreamOggVorbis).duplicate()
			(st as AudioStreamOggVorbis).loop = true
		p.stream = st
	return p

## The look for seat n (1 to 4) on the players' own figure.
func _dress(v: CrewView, n: int) -> void:
	v.set_number(n)
	v.set_skin((n - 1) % 4)
	v.set_headwear(&"none")
	var skin: ShaderMaterial = v._mats.get("convict_skin")
	if skin != null:
		skin.set_shader_parameter("albedo", SKIN_TINT)
	var suit: ShaderMaterial = v._mats.get("convict_suit")
	if suit != null:
		var base: Texture2D = suit.get_shader_parameter("tex")
		suit.set_shader_parameter("tex", bloodied_suit(base, n))
	v.set_face(face_for(n))
	var screen: ShaderMaterial = v._mats.get("face_screen")
	if screen != null:
		screen.set_shader_parameter("emit", SCREEN_GLOW)
	var thin := Thin.new()
	for b: String in THIN_BONES:
		var id := v.skel.find_bone(b)
		if id >= 0:
			thin.bones.append(id)
	thin.head = v.skel.find_bone("Head")
	v.skel.add_child(thin)

## The face on seat n's screen: the game's drawing for that seat (assets/station/faces, the same four the
## recovered tape shows), else station_faces.gd's own drawing for the seat; cracked either way.
static func face_for(n: int) -> Texture2D:
	if test_break == "face":
		n = 1
	return FaceImage.damaged(n)

## The suit darkened, stained and soaked from the collar and the hem, a pattern seeded by seat.
static func bloodied_suit(base: Texture2D, n: int) -> Texture2D:
	if _suits.has(n):
		return _suits[n]
	var img: Image = base.get_image().duplicate() if base != null else Image.create(64, 64, false, Image.FORMAT_RGB8)
	if img.is_compressed():
		img.decompress()
	img.clear_mipmaps()
	img.convert(Image.FORMAT_RGB8)
	var w := img.get_width()
	var h := img.get_height()
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("station-suit-%d" % n)
	var blots: Array[Vector3] = []
	for k in 26:
		blots.append(Vector3(rng.randf() * w, rng.randf() * h, rng.randf_range(0.03, 0.11) * w))
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			var g := (c.r + c.g + c.b) / 3.0
			c = c.lerp(Color(g, g, g), 0.35) * 0.72
			var soak := 0.0
			for b in blots:
				var d := Vector2(x - b.x, (y - b.y) * 1.6).length()
				soak = maxf(soak, 1.0 - smoothstep(b.z * 0.55, b.z, d))
			if soak > 0.0:
				c = c.lerp(Color(0.25, 0.03, 0.02), soak * 0.85)
			img.set_pixel(x, y, c)
	img.generate_mipmaps()
	var t := ImageTexture.create_from_image(img)
	_suits[n] = t
	return t

## The downloaded crawl and run for this rig, added to each figure's player as "station/zombie_crawl" and
## "station/zombie_run", only when every track of both resolves on the crew skeleton. False otherwise.
func _add_zombie_clips() -> bool:
	if not zombie_motion or figures.is_empty():
		return false
	if not _zombie_tried:
		_zombie_tried = true
		_zombie_lib = zombie_library(figures[0])
	if _zombie_lib == null:
		return false
	for v in figures:
		v.ap.add_animation_library(&"station", _zombie_lib)
	return true

## The two clips from the game model at `path`, checked against a crew figure's skeleton: null when the file is
## not there or any track would not resolve. Read once per process by the view.
static func zombie_library(probe: CrewView, path := ZOMBIE_MOTION) -> AnimationLibrary:
	if not ResourceLoader.exists(path):
		return null
	var scene := load(path) as PackedScene
	if scene == null:
		return null
	var src := scene.instantiate()
	var sap := src.find_child("AnimationPlayer", true, false) as AnimationPlayer
	var ok := sap != null
	var lib := AnimationLibrary.new()
	if ok:
		for name: String in ZOMBIE_CLIPS:
			if not sap.has_animation(name):
				ok = false
				break
			var a: Animation = sap.get_animation(name).duplicate()
			a.loop_mode = Animation.LOOP_LINEAR
			lib.add_animation(name, a)
	if ok:
		var ap := probe.ap
		var root := ap.get_node(ap.root_node)
		for name: String in ZOMBIE_CLIPS:
			var a := lib.get_animation(name)
			for tr in a.get_track_count():
				var track := a.track_get_path(tr)
				var node := root.get_node_or_null(NodePath(str(track.get_concatenated_names())))
				if node == null:
					ok = false
					break
				if node is Skeleton3D and track.get_subname_count() > 0 and (node as Skeleton3D).find_bone(str(track.get_subname(0))) < 0:
					ok = false
					break
	src.free()
	return lib if ok else null

## Where the four lie before any block has come (the plan's `bodies` anchors: {at, yaw / facing, seat}).
func set_bodies(bodies: Array) -> void:
	_bodies = bodies
	if figures.is_empty():
		return
	for i in mini(SEATS, bodies.size()):
		var b: Variant = bodies[i]
		var at := Point.v3(b)
		if at == Vector3.INF:
			continue
		# The anchors' yaw, as the block's crew yaw, is the camera's convention (sim/entity.gd yaw_toward).
		var yaw := float((b as Dictionary).get("yaw", 0.0)) if b is Dictionary else 0.0
		if b is Dictionary and (b as Dictionary).has("seat"):
			_set_seat(i, int((b as Dictionary)["seat"]))
		_draw(i, {"at": at, "yaw": yaw, "phase": "still", "clock": 0.0})

func _set_seat(i: int, n: int) -> void:
	if n >= 1 and n <= 4 and seats[i] != n:
		seats[i] = n
		_dress(figures[i], n)

func set_power(p: int) -> void:
	if p == 1 and power != 1:
		_scrape()
	power = p

func _scrape() -> void:
	if _cue_at >= 0.0 or _cue == null:
		return
	_cue_at = Time.get_ticks_msec() / 1000.0
	var c := Vector3.ZERO
	for v in figures:
		c += v.position
	if not figures.is_empty():
		_cue.position = c / figures.size() + Vector3(0, 0.3, 0)
	if _cue.stream != null and _cue.is_inside_tree():
		_cue.play()

## Whether the scrape has been heard long enough for a moving figure to be drawn moving.
func heard() -> bool:
	return _cue_at >= 0.0 and Time.get_ticks_msec() / 1000.0 - _cue_at >= HEARD_LEAD

# --- the block --------------------------------------------------------------------------------------

## One seat's entry in either shape, as {at, yaw, phase, clock, seat}; {} when there is none.
static func pose_of(e: Variant) -> Dictionary:
	if e is Array and (e as Array).size() >= 3:
		var r: Array = e
		return {"at": Vector3(float(r[0]), float(r[1]), float(r[2])), "yaw": float(r[3]) if r.size() > 3 else 0.0,
			"phase": str(r[5]) if r.size() > 5 else "still", "clock": float(r[6]) if r.size() > 6 else 0.0, "seat": 0}
	if e is Dictionary:
		var d: Dictionary = e
		var at := Point.v3(d)
		if at == Vector3.INF:
			return {}
		return {"at": at, "yaw": float(d.get("yaw", 0.0)), "phase": str(d.get("phase", d.get("state", "still"))),
			"clock": float(d.get("clock", d.get("t", 0.0))), "seat": int(d.get("seat", 0))}
	return {}

## Between two snapshots' entries for one seat at `alpha`: the position and facing interpolated, the newer's
## state and clock (its clock interpolated only within one state, never back across a loop).
static func lerp_pose(a: Dictionary, b: Dictionary, alpha: float) -> Dictionary:
	if a.is_empty() or test_break == "smooth":
		return b
	if b.is_empty():
		return a
	var pa: Vector3 = a["at"]
	var pb: Vector3 = b["at"]
	if pa.distance_to(pb) > 2.0:
		return b
	var out := b.duplicate()
	out["at"] = pa.lerp(pb, alpha)
	out["yaw"] = lerp_angle(float(a["yaw"]), float(b["yaw"]), alpha)
	if str(a["phase"]) == str(b["phase"]) and float(b["clock"]) >= float(a["clock"]):
		out["clock"] = lerpf(float(a["clock"]), float(b["clock"]), alpha)
	return out

## The four states from the host's phase names (today's "still", "zombie_crawl", "zombie_run", and plain ones).
static func state_of(phase: String) -> String:
	if test_break == "state":
		return "lying"
	match phase:
		"zombie_crawl", "crawl", "crawling":
			return "crawling"
		"stand", "standing", "rise", "rising", "zombie_stand", "get_up":
			return "standing"
		"zombie_run", "run", "pursue", "pursuing", "chase", "zombie_walk", "hunt":
			return "pursuing"
	return "lying"

func clip_for(state: String) -> String:
	match state:
		"crawling":
			return "station/zombie_crawl" if zombie_clips else "crawl"
		"standing":
			return "get_up"
		"pursuing":
			return "station/zombie_run" if zombie_clips else "run"
	return "taken"

## Draws the four between two blocks (the older, the newer, how far between: client/net/client.gd's bracket).
func show_blocks(a: Variant, b: Variant, alpha: float) -> void:
	if figures.is_empty():
		return
	var ca: Array = (a as Dictionary).get("crew", []) if a is Dictionary else []
	var cb: Array = (b as Dictionary).get("crew", []) if b is Dictionary else []
	var seat_list: Array = (b as Dictionary).get("seats", []) if b is Dictionary else []
	for i in mini(SEATS, cb.size()):
		var pb := pose_of(cb[i])
		if pb.is_empty():
			continue
		var pa := pose_of(ca[i]) if i < ca.size() else {}
		var p := lerp_pose(pa, pb, alpha)
		if int(p.get("seat", 0)) > 0:
			_set_seat(i, int(p["seat"]))
		elif i < seat_list.size():
			_set_seat(i, int(seat_list[i]))
		_draw(i, p)

func _draw(i: int, p: Dictionary) -> void:
	var v := figures[i]
	var at: Vector3 = p["at"]
	var state := state_of(str(p["phase"]))
	if state != "lying" and not heard():
		_scrape()
		if not heard():
			state = "lying"
			at = _last[i] if _last[i] != Vector3.INF else at
	var d := 0.0
	if _last[i] != Vector3.INF:
		d = Vector2(at.x - _last[i].x, at.z - _last[i].z).length()
		if d > 2.0:
			d = 0.0
	_last[i] = at
	_dist[i] += d
	states[i] = state
	var clip := clip_for(state)
	var length := v.ap.get_animation(clip).length if v.ap.has_animation(clip) else 1.0
	var t := 0.0
	match state:
		"lying":
			t = maxf(0.0, length - 0.02)
		"standing":
			t = clampf(float(p["clock"]), 0.0, length)
		_:
			if zombie_clips:
				t = fposmod(float(p["clock"]), length)
			else:
				t = fposmod(_dist[i] / maxf(0.05, CrewView.stride(clip)), length)
	v.debug_pose(clip, t)
	# The block lifts a resting body a little (the old pack's lying pose); the crew rig's clips stand on the floor.
	at.y = floorf((at.y + 0.5) / Level.LH) * Level.LH
	v.set_body(at, float(p["yaw"]))
	v.visible = true
	_sound(i, state, d, at)

func _sound(i: int, state: String, d: float, at: Vector3) -> void:
	var crawl := _crawl[i]
	var breath := _breath[i]
	var crawling := state == "crawling"
	var up := state == "standing" or state == "pursuing"
	if crawl.stream != null and crawl.is_inside_tree():
		if crawling and not crawl.playing:
			crawl.play()
		elif not crawling and crawl.playing:
			crawl.stop()
	if breath.stream != null and breath.is_inside_tree():
		if up and not breath.playing:
			breath.play()
		elif not up and breath.playing:
			breath.stop()
	if state == "pursuing" and sfx != null:
		_steps[i] += d / STEP_LEN
		if _steps[i] >= 1.0:
			_steps[i] -= floorf(_steps[i])
			sfx.call(&"step_at", at + Vector3(0, 0.05, 0), -6.0)

## What a test reads of seat index i: the state drawn, the clip, the seat on the patch, the face on the screen.
func describe(i: int) -> Dictionary:
	if i < 0 or i >= figures.size():
		return {}
	var v := figures[i]
	var patch: ShaderMaterial = v._mats.get("number_patch")
	var screen: ShaderMaterial = v._mats.get("face_screen")
	return {"state": states[i], "clip": v.clip, "seat": seats[i], "visible": v.visible, "at": v.position,
		"faceHash": v.face_hash(), "numberHash": CrewView.texture_hash(patch.get_shader_parameter("tex") as Texture2D) if patch != null else "",
		"glow": float(screen.get_shader_parameter("emit")) if screen != null else 0.0,
		"crawlSound": _crawl[i].playing, "breath": _breath[i].playing}

## The wasted frame: limbs and trunk drawn thinner across, after the clip and the crew rig's own modifiers.
class Thin extends SkeletonModifier3D:
	var bones := PackedInt32Array()
	var head := -1
	var k := THIN

	func _process_modification() -> void:
		var sk := get_skeleton()
		if sk == null:
			return
		for b in bones:
			sk.set_bone_pose_scale(b, sk.get_bone_pose_scale(b) * Vector3(k, 1.0, k))
		if head >= 0:
			sk.set_bone_pose_scale(head, sk.get_bone_pose_scale(head) * Vector3(1.0 / k, 1.0, 1.0 / k))
