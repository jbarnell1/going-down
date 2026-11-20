# The Temp on screen (docs/floors/annex.md section 4): the Annex's resident. An office worker about
# 1.8 m tall in a short-sleeved shirt, tie and lanyard, a stapler in its right hand and a pad of
# yellow notes in its left, and over its face an A4 sheet stapled on at the corners. The sheet shows a
# bad photocopy of one crewmate's drawn face, picked by the seed. The Blender figure is
# posed from the resident state, like OrderlyView:
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
# on the pose's own clock (animTime), its walk on the distance walked. Its gait (slow or fast walk, and the
# blend between) follows its pace over the last few tenths of a metre, and a change of what it does fades in
# over CARRY_S of its own clock; neither moves while the pose is held (PT4, tests/test_temp_motion.gd).
#
# The stapler: one click per 1.2 m walked, and one each time its own clock passes a multiple of 4 s
# while it stands (the clock stops while it is held, so a watched Temp is silent). Heard at its hand
# out to 30 m, quieter and duller through walls. Its own player; the click is one of the owner's four
# recorded staples (assets/sfx/annex/staple_*.ogg, dealt in turn, never the same twice running), or the
# one made here when they are missing; on the "Entity" bus when the bus layout has one, otherwise on
# "Sfx". Its shuffling steps on the carpet (annex/temp_steps.ogg) are heard only within STEPS_RANGE while
# it walks: from further off the Annex's sound stays dots.
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
const CLICK_DB := 3.0           # the made-in-code click
## The recorded staples are normalised to the voice -9 LU (momentary max; MIX.md) and played here at
## Sfx.BASE_DB + this: the voice -4 LU right at its hand, as the made-in-code click was.
const CLICK_REC_DB := 5.0
const STAPLES: Array[String] = ["res://assets/sfx/annex/staple_1.ogg", "res://assets/sfx/annex/staple_2.ogg",
	"res://assets/sfx/annex/staple_3.ogg", "res://assets/sfx/annex/staple_4.ogg"]
const STEPS_FILE := "res://assets/sfx/annex/temp_steps.ogg"
const STEPS_RANGE := 8.0
const WALK_CYCLE := 0.95        # metres travelled in one original slow cycle
const CHASE_CYCLE := 3.06       # metres travelled in one original fast cycle
## The gait, by its pace (m/s): the slow walk below CHASE_STOP, the fast one above CHASE_START. The slow walk
## was made for 0.57 m/s and the fast one for 1.43, so from a standstill the creep (1.3, 1.6 at prey) walks
## slowly and Lonely's approach (2.0) and everything faster uses the fast walk (at 2.0 the slow one would run
## 3.5 times too fast). Between the two it keeps the gait it has: the band is wide, either clip passing in it,
## so a pace that dips at a corner (the rules slow it to about 1.0 for a tick or two) or wobbles in measuring
## never flips it back and forth (PT4). (Build 9bf81be had 2.2 and 1.7, with 2.0 inside the band.)
const CHASE_START := 1.8
const CHASE_STOP := 1.2
## Its pace is judged over the last SPEED_SPAN_M metres it walked (or SPEED_SPAN_S seconds of its clock, if
## that comes first), from points at least TRAIL_STEP apart: never from one frame to the next. The poses come
## to the centimetre and the millisecond, so a frame's own step at 60 to 144 frames a second could read
## anything from half to twice its true pace, and a Temp walking at 2.0 m/s (Lonely's approach, between
## CHASE_STOP and CHASE_START) or 2.6 (alone, its chase) flipped clip on most frames (PT4).
const SPEED_SPAN_M := 0.3
const SPEED_SPAN_S := 0.5
const TRAIL_STEP := 0.05
## Between the walk and the fast walk it blends over this many metres walked (a distance, so a held pose
## never moves it), rather than snapping from one clip's pose to the other's.
const BLEND_M := 0.4
## When what it does changes (it starts or stops walking, or its standing fidget moves on from one clip to
## the next) the last drawn pose fades into the new one over this many seconds of its own clock (never the
## local clock: a held pose stays exactly as drawn). Not into the jab or the bend: the catch reads at once.
const CARRY_S := 0.25
const BEND_IN := 0.8
const MODEL := preload("res://assets/entities/temp.glb")
## The new figure (MT1: the owner's Meshy model with today's six clips, assets_src/blender/temp/build_temp_v2.py),
## drawn only when the game was started with `figures=new` (on the web, `?figures=new`). Same clip names, bone
## names, hands for the stapler and notes, and the same A4 sheet (material temp_face_sheet) over its face.
const MODEL_V2 := "res://assets/entities/temp_v2.glb"
## Tests only: true or false picks the figure regardless of how the game was started; null reads the start.
static var force_new_figure: Variant = null
const Entity = preload("res://sim/entity.gd")
const SQUEEZE_M := 0.22         # metres of walk one squeeze of the stapler lasts
const SQUEEZE_S := 0.2          # seconds one idle squeeze lasts
## The break (tests only): the walk cycle also runs on the local clock at this speed, held or not.
const BREAK_RATE := 1.5
## The watched walk: how far the head turns from the body at most (radians), and the stapler arm held up
## before the face (shoulder and elbow, radians about x).
const WATCH_TURN_MAX := 1.3
## The photocopy.
const PAPER := Color(0.93, 0.92, 0.88)
const TONER := Color(0.07, 0.07, 0.08)
const PAGE := Vector2i(120, 170)                  # A4's shape
const FACE_RECT := Rect2i(9, 26, 102, 102)        # where the face sits on the page
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

var _model: Node3D
var _skel: Skeleton3D
var _ap: AnimationPlayer
var _bones := {}
var _attachments: Array[BoneAttachment3D] = []
var _stapler: Node3D
var _body_mats: Array[ShaderMaterial] = []
var _paper_mat: ShaderMaterial
var _gait_phase := 0.0
var _fast := false
## Tests only: judge the pace from one frame to the next, as the view did before PT4 (the jitter check must catch it).
var break_frame_speed := false
## How far the drawn gait is from the walk (0) to the fast walk (1).
var _chase_w := 0.0
## Recent walking points, newest last: Vector3(x, z, animTime), each at least TRAIL_STEP from the one before.
var _trail: Array[Vector3] = []
## The carry-over (CARRY_S): what the last pose was ("gait" for either walk), its joints before the
## overlays, the joints being faded from, and the seconds of fade left.
var _base_key := ""
var _base_rot: Array[Quaternion] = []
var _base_pos: Array[Vector3] = []
var _carry_rot: Array[Quaternion] = []
var _carry_pos: Array[Vector3] = []
var _carry_left := 0.0
var _posed_last := false
var _held_watch: Variant = null
var _player: AudioStreamPlayer3D
var _staples: Array[AudioStream] = []   # the recorded clicks (empty: the made-in-code one)
var _staple_next := 0
var _steps: AudioStreamPlayer3D          # its shuffle on the carpet (null without the file)
var _walking_until := 0
var _plan: Floor.FloorPlan = null
var _rng := RandomNumberGenerator.new()
var _dist := 0.0                # metres the drawn pose has walked
var _last := Vector3.INF
var _last_pose: Variant = null
var _walk_k := 0
var _stand_k := -1
var _last_us := 0

func _init() -> void:
	_paper_mat = _shade(PAPER_LIGHT)
	_build_model()
	_player = AudioStreamPlayer3D.new()
	_player.name = "Stapler"
	_player.stream = click_stream()
	_player.top_level = true
	_player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
	_player.max_distance = HEAR_RANGE
	_player.max_polyphony = 3
	_player.attenuation_filter_cutoff_hz = 20500.0
	add_child(_player)
	for f in STAPLES:
		if ResourceLoader.exists(f):
			_staples.append(load(f))
	if ResourceLoader.exists(STEPS_FILE):
		var st := load(STEPS_FILE) as AudioStreamOggVorbis
		st.loop = true
		_steps = AudioStreamPlayer3D.new()
		_steps.name = "Steps"
		_steps.stream = st
		_steps.top_level = true
		_steps.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
		_steps.max_distance = STEPS_RANGE
		_steps.attenuation_filter_cutoff_hz = 20500.0
		add_child(_steps)
	set_crew("", [])
	_rng.seed = 7
	visible = false

func _ready() -> void:
	_player.bus = &"Entity" if AudioServer.get_bus_index(&"Entity") != -1 else &"Sfx"
	if _steps != null:
		_steps.bus = _player.bus

func reset() -> void:
	if _steps != null:
		_steps.stop()
	_dist = 0.0
	_gait_phase = 0.0
	_fast = false
	_chase_w = 0.0
	_trail.clear()
	_base_key = ""
	_carry_left = 0.0
	_posed_last = false
	_held_watch = null
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

static func _shade(self_light: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://client/annex_shade.gdshader")
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
		for m: ShaderMaterial in _body_mats + [_paper_mat]:
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
		_posed_last = false
		_carry_left = 0.0
		if _steps != null and _steps.playing:
			_steps.stop()
		return
	var pd: Dictionary = pose
	var p := Vector3(float(pd["x"]), float(pd["y"]), float(pd["z"]))
	var anim := str(pd["anim"])
	var t := float(pd["animTime"])
	var held := _last_pose != null and _same(pd, _last_pose)
	if not held:
		_held_watch = watched_at
	var walking := anim == "walk" or anim == "duck"
	var step := 0.0
	var jumped := false
	if _last != Vector3.INF:
		var d := Vector2(p.x - _last.x, p.z - _last.z).length()
		if d < 1.0:
			step = d
		else:
			jumped = true
	# Seconds of its own clock since the last pose, for the carry-over (none across a change of anim, a jump
	# or a held pose).
	var clock_step := 0.0
	if not held and not jumped and _last_pose != null and _last_pose["anim"] == anim:
		clock_step = maxf(0.0, t - float(_last_pose["animTime"]))
	_carry_left = maxf(0.0, _carry_left - clock_step)
	if break_frame_speed:
		if walking and step > 0.0 and _last_pose != null and _last_pose["anim"] == anim:
			var dt := t - float(_last_pose["animTime"])
			if dt > 0.0:
				# As build 9bf81be did it, thresholds and all.
				_fast = step / dt > (1.7 if _fast else 2.2)
	elif walking and not held:
		# A new walk, a jump (relocation) or a clock that went back starts the trail again.
		var go_on: bool = _last_pose != null and _last_pose["anim"] == anim and _last != Vector3.INF \
			and Vector2(p.x - _last.x, p.z - _last.z).length() < 1.0
		if not go_on or (not _trail.is_empty() and t < _trail.back().z):
			_trail.clear()
		if _trail.is_empty() or Vector2(p.x - _trail.back().x, p.z - _trail.back().y).length() >= TRAIL_STEP:
			_trail.append(Vector3(p.x, p.z, t))
		var speed := _trail_speed()
		if speed >= 0.0:
			_fast = speed > (CHASE_STOP if _fast else CHASE_START)
	if not walking:
		_fast = false
		_chase_w = 0.0
		_trail.clear()
	_last = p
	_last_pose = pd.duplicate()
	var now := Time.get_ticks_usec()
	if break_walk_while_seen and (anim == "walk" or anim == "duck") and _last_us > 0:
		step += BREAK_RATE * minf((now - _last_us) / 1e6, 0.1)
	_last_us = now
	_dist += step
	if walking:
		if break_frame_speed:
			_chase_w = 1.0 if _fast else 0.0
		else:
			_chase_w = move_toward(_chase_w, 1.0 if _fast else 0.0, step / BLEND_M)
		_gait_phase = fposmod(_gait_phase + step / lerpf(WALK_CYCLE, CHASE_CYCLE, _chase_w), 1.0)
	# The clicks: per 1.2 m walked; standing, each 4 s of its own clock (stopped while held).
	var k := floori(_dist / CLICK_STEP)
	var click_reason := "walk" if k > _walk_k else ""
	_walk_k = k
	if anim == "idle" and step == 0.0:
		if not held:
			var sk := floori(t / STAND_CLICK)
			if _stand_k >= 0 and sk > _stand_k:
				click_reason = "stand"
			_stand_k = sk
	else:
		_stand_k = -1
	# A click must follow the posed hand even when the listener cannot see the Temp.
	if show or click_reason != "":
		position = p
		rotation = Vector3(0, float(pd["yaw"]) + PI, 0)
		_pose_figure(anim, t, _dist, clock_step, jumped)
		_posed_last = true
	else:
		_posed_last = false
	if click_reason != "":
		_click(click_reason, _stapler.global_position)
	_shuffle(p, step)
	visible = show
	if show:
		drawn = pd

## Its pace (m/s) along the trail over the last SPEED_SPAN_M metres or SPEED_SPAN_S seconds, whichever comes
## first, or -1 while the trail is too short to say (the gait it has is kept). Drops points no longer needed.
func _trail_speed() -> float:
	var n := _trail.size()
	var walked := 0.0
	for i in range(n - 2, -1, -1):
		var a := _trail[i]
		var b := _trail[i + 1]
		walked += Vector2(b.x - a.x, b.y - a.y).length()
		var span := _trail[n - 1].z - a.z
		if walked >= SPEED_SPAN_M or span >= SPEED_SPAN_S:
			if i > 0:
				_trail = _trail.slice(i)
			return walked / span if span > 0.0 else -1.0
	return -1.0

static func _same(a: Dictionary, b: Dictionary) -> bool:
	for k: String in ["x", "y", "z", "level", "yaw", "anim", "animTime"]:
		if a.get(k) != b.get(k):
			return false
	return true

static func _pulse(x: float) -> float:
	return sin(x * PI) if x >= 0.0 and x < 1.0 else 0.0

## Sample only the supplied pose clock or distance. The mixer never advances on its own.
## `clock_step` and `jumped` (show_pose) say how a carry-over starting now is cut short, or that none starts.
func _pose_figure(anim: String, t: float, dist: float, clock_step := 0.0, jumped := false) -> void:
	var clip := &"idle"
	var at := t
	var squeeze := 0.0
	# Between the two gaits: the other clip, sampled first, and how much of it is mixed in.
	var other := &""
	var other_w := 0.0
	match anim:
		"walk", "duck":
			clip = &"chase" if _chase_w >= 0.5 else &"walk"
			at = _gait_phase * _length(clip)
			other = &"walk" if clip == &"chase" else &"chase"
			other_w = 1.0 - _chase_w if clip == &"chase" else _chase_w
			squeeze = _pulse(fposmod(dist, CLICK_STEP) / SQUEEZE_M)
		"reach":
			clip = &"reach"
			at = clampf(t / Entity.WIND_UP_TIME, 0.0, 1.0) * _length(clip)
		"bend":
			clip = &"bend"
			at = clampf(t / BEND_IN, 0.0, 1.0) * _length(clip)
		_:
			var idle_len := _length(&"idle")
			var look_len := _length(&"look")
			at = fposmod(t, idle_len + look_len)
			if at >= idle_len:
				clip = &"look"
				at -= idle_len
			squeeze = _pulse(fposmod(t, STAND_CLICK) / SQUEEZE_S)
	# Restore unkeyed joints too: every pose starts with the imported rest and the authored sample.
	var mix_rot: Array[Quaternion] = []
	var mix_pos: Array[Vector3] = []
	if other_w > 0.0001:
		_sample_clip(other, _gait_phase * _length(other))
		for i in _skel.get_bone_count():
			mix_rot.append(_skel.get_bone_pose_rotation(i))
			mix_pos.append(_skel.get_bone_pose_position(i))
	_sample_clip(clip, at)
	for i in mix_rot.size():
		_skel.set_bone_pose_rotation(i, _skel.get_bone_pose_rotation(i).slerp(mix_rot[i], other_w))
		_skel.set_bone_pose_position(i, _skel.get_bone_pose_position(i).lerp(mix_pos[i], other_w))
	# The carry-over: a new kind of pose fades in from the last one drawn (both before the overlays).
	var key := "gait" if anim == "walk" or anim == "duck" else String(clip)
	if key == "reach" or key == "bend" or jumped or not _posed_last:
		_carry_left = 0.0
	elif key != _base_key and not _base_rot.is_empty() and not break_frame_speed:
		_carry_rot = _base_rot.duplicate()
		_carry_pos = _base_pos.duplicate()
		# The change came somewhere within the clock's last step: a long step leaves less (or nothing) to fade.
		_carry_left = maxf(0.0, CARRY_S - clock_step)
	_base_key = key
	if _carry_left > 0.0 and _carry_rot.size() == _skel.get_bone_count():
		var keep := smoothstep(0.0, 1.0, _carry_left / CARRY_S)
		for i in _carry_rot.size():
			_skel.set_bone_pose_rotation(i, _skel.get_bone_pose_rotation(i).slerp(_carry_rot[i], keep))
			_skel.set_bone_pose_position(i, _skel.get_bone_pose_position(i).lerp(_carry_pos[i], keep))
	_base_rot.resize(_skel.get_bone_count())
	_base_pos.resize(_skel.get_bone_count())
	for i in _skel.get_bone_count():
		_base_rot[i] = _skel.get_bone_pose_rotation(i)
		_base_pos[i] = _skel.get_bone_pose_position(i)
	if anim == "bend":
		var e := smoothstep(0.0, BEND_IN, t)
		var chew := 0.5 - 0.5 * cos(t * TAU * 1.4)
		_turn("Spine1", Vector3.RIGHT, 0.38 * e)
		_turn("Spine2", Vector3.RIGHT, 0.40 * e)
		_turn("Neck", Vector3.RIGHT, (0.12 + 0.12 * chew) * e)
		_turn("Head", Vector3.RIGHT, (0.10 + 0.15 * chew) * e)
	if (anim == "walk" or anim == "duck") and _held_watch is Vector3:
		_watched_walk(transform.affine_inverse() * (_held_watch as Vector3))
	if squeeze > 0.0:
		_turn("RightHand", Vector3.RIGHT, -0.14 * squeeze)
	# Update the props after the overlays so their grips stay with the visible hands.
	for attachment: BoneAttachment3D in _attachments:
		attachment.on_skeleton_update()

## The imported rest, then one clip's authored sample at `at` seconds.
func _sample_clip(clip: StringName, at: float) -> void:
	_skel.reset_bone_poses()
	if _ap.assigned_animation != clip:
		_ap.play(clip, 0.0)
		_ap.pause()
	_ap.seek(at, true, true)

func _length(clip: StringName) -> float:
	return _ap.get_animation(clip).length

func _pose_bone(which: String) -> Transform3D:
	return _skel.get_bone_global_pose(int(_bones[which]))

func _turn(which: String, axis: Vector3, angle: float) -> void:
	_spin(which, Quaternion(_model_basis().inverse() * axis, angle))

func _model_basis() -> Basis:
	return (global_transform.basis.inverse() * _skel.global_transform.basis).orthonormalized()

func _spin(which: String, spin: Quaternion) -> void:
	var idx := int(_bones[which])
	var parent := _skel.get_bone_parent(idx)
	var parent_basis := _skel.get_bone_global_pose(parent).basis.orthonormalized()
	var local := parent_basis.inverse() * Basis(spin) * parent_basis
	_skel.set_bone_pose_rotation(idx, (local * Basis(_skel.get_bone_pose_rotation(idx))).get_rotation_quaternion())

## Turn the photocopy directly toward the sole watcher and raise the stapler in front of it.
func _watched_walk(target: Vector3) -> void:
	var axes := _model_basis()
	var head := int(_bones["Head"])
	var rest_forward := _skel.get_bone_global_rest(head).basis.inverse() * axes.inverse() * Vector3.BACK
	var forward := axes * _pose_bone("Head").basis * rest_forward
	var turn := clampf(atan2(target.x, target.z), -WATCH_TURN_MAX, WATCH_TURN_MAX)
	var change := angle_difference(atan2(forward.x, forward.z), turn)
	_turn("Neck", Vector3.UP, change * 0.35)
	_turn("Head", Vector3.UP, change * 0.65)
	_aim("RightArm", "RightForeArm", Vector3(-0.16, 0.04, 0.28))
	_aim("RightForeArm", "RightHand", Vector3(0.15, 0.28, 0.08))

func _aim(which: String, next: String, direction: Vector3) -> void:
	var current := (_pose_bone(next).origin - _pose_bone(which).origin).normalized()
	var goal := (_model_basis().inverse() * direction.normalized()).normalized()
	_spin(which, Quaternion(current, goal))

## Was the game started with `figures=new` (or, on the web, `?figures=new`)?
static func new_figure() -> bool:
	if force_new_figure != null:
		return bool(force_new_figure)
	for raw: String in OS.get_cmdline_user_args():
		if raw == "figures=new" or raw == "--figures=new":
			return true
	if OS.has_feature("web"):
		return str(JavaScriptBridge.eval("new URLSearchParams(location.search).get('figures') ?? ''", true)) == "new"
	return false

## Which figure file this view draws.
static func model_path() -> String:
	return MODEL_V2 if new_figure() and ResourceLoader.exists(MODEL_V2) else MODEL.resource_path

func _build_model() -> void:
	var scene: PackedScene = MODEL
	if model_path() == MODEL_V2:
		scene = load(MODEL_V2) as PackedScene
	_model = scene.instantiate() as Node3D
	add_child(_model)
	_skel = _model.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	_ap = _model.find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer
	_ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	for idx in _skel.get_bone_count():
		var full := _skel.get_bone_name(idx)
		# Godot can sanitize the Mixamo namespace at import.
		for short: String in ["Head", "Neck", "Spine1", "Spine2", "RightArm", "RightForeArm", "RightHand"]:
			if full.ends_with(short):
				_bones[short] = idx
	for child: Node in _model.find_children("*", "BoneAttachment3D", true, false):
		_attachments.append(child as BoneAttachment3D)
	_stapler = _model.find_child("temp_stapler", true, false) as Node3D
	for mesh: MeshInstance3D in _model.find_children("*", "MeshInstance3D", true, false):
		for i in mesh.mesh.get_surface_count():
			var source := mesh.get_active_material(i) as BaseMaterial3D
			var mat := _paper_mat
			if not source.resource_name.begins_with("temp_face_sheet"):
				mat = _shade(BODY_LIGHT)
				mat.set_shader_parameter("albedo_tex", source.albedo_texture)
				_body_mats.append(mat)
			mesh.set_surface_override_material(i, mat)

## A short hash of the root and every joint as drawn, including the bones the hand props follow.
func drawn_signature() -> String:
	var f := PackedFloat32Array()
	f.append(1.0 if visible else 0.0)
	var transforms: Array[Transform3D] = [transform]
	for idx in _skel.get_bone_count():
		transforms.append(_skel.get_bone_pose(idx))
	for x: Transform3D in transforms:
		for v: Vector3 in [x.basis.x, x.basis.y, x.basis.z, x.origin]:
			f.append(v.x)
			f.append(v.y)
			f.append(v.z)
	return f.to_byte_array().hex_encode().md5_text().substr(0, 12)
## Tests: a hash of the picture on the paper as its material holds it.
func paper_hash() -> String:
	return CrewView.texture_hash(_paper_mat.get_shader_parameter("albedo_tex") as Texture2D)

## Tests: the height of the posed paper's tip above the feet.
func standing_height() -> float:
	var axes := _model_basis()
	var head := int(_bones["Head"])
	var tip := _skel.get_bone_global_rest(head).affine_inverse() * (axes.inverse() * Vector3(0.0, 1.7906, 0.10))
	return (axes * (_pose_bone("Head") * tip)).y
# --- the click ----------------------------------------------------------------------------------

func _click(why: String, at: Vector3) -> void:
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
	_player.attenuation_filter_cutoff_hz = 1300.0 if muffled else 20500.0
	if _staples.is_empty():
		_player.volume_db = linear_to_db(gain) + CLICK_DB
		_player.pitch_scale = 0.94 + 0.12 * _rng.randf()
	else:
		# The takes in turn from a random step, so the same take never comes twice running.
		_player.stream = _staples[_staple_next % _staples.size()]
		_staple_next += 1 + _rng.randi_range(0, _staples.size() - 2)
		_player.volume_db = linear_to_db(gain) + Sfx.BASE_DB + CLICK_REC_DB
		_player.pitch_scale = 0.97 + 0.06 * _rng.randf()
	_player.play()

## Its shuffle on the carpet: on while the drawn pose walks (and a moment after), only within
## STEPS_RANGE of the ear, quieter through walls (checked a few times a second).
var _steps_check := 0
func _shuffle(feet: Vector3, step: float) -> void:
	if _steps == null or not is_inside_tree():
		return
	var now := Time.get_ticks_msec()
	if step > 0.0:
		_walking_until = now + 300
	var cam: Camera3D = get_viewport().get_camera_3d()
	var on := now < _walking_until and cam != null
	var d := cam.global_position.distance_to(feet) if cam != null else 99.0
	on = on and d < STEPS_RANGE
	if not on:
		if _steps.playing:
			_steps.stop()
		return
	var g := pow(1.0 - d / STEPS_RANGE, 2.0)
	if now >= _steps_check:
		_steps_check = now + 250
		var muffled := false
		if _plan != null:
			var ear := cam.global_position
			var e := Sight.Point3.make(ear.x, ear.y, ear.z, 1 if ear.y >= Move.LEVEL_HEIGHT else 0)
			var s := Sight.Point3.make(feet.x, feet.y + 0.2, feet.z, 1 if feet.y + 0.2 >= Move.LEVEL_HEIGHT else 0)
			muffled = not Sight.has_line_of_sight(_plan, e, s)
		_steps.attenuation_filter_cutoff_hz = 1300.0 if muffled else 20500.0
		_steps.set_meta(&"muffled", muffled)
	if bool(_steps.get_meta(&"muffled", false)):
		g *= MUFFLED_GAIN
	_steps.global_position = feet + Vector3(0, 0.1, 0)
	_steps.volume_db = linear_to_db(maxf(g, 0.001)) + Sfx.BASE_DB
	if not _steps.playing:
		_steps.play()

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
