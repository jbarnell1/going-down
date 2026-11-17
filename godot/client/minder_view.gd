# The Minder on screen (docs/floors/playarea.md section 2): the Playroom's resident, the Blender model
# (assets/entities/minder.glb, built by assets_src/blender/minder/build_minder.py) with its ten clips.
# Gaunt and too long, about 2.3 m upright, a card mask on the FRONT of its skull only that glows faintly
# in the dark; it walks upright and drops to all fours to search and run, and crouches with both hands
# over the mask while it counts.
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
# The pose name picks the clip (CLIPS: every pose the rules set, and the interim rules' names). Like
# client/orderly_view.gd the model is loaded once and posed every frame, but the clips are sampled here
# and written to the skeleton, so that:
#  - the gaits (walk, prowl, run) run on the distance walked over the clip's own ground speed (GAIT_SPEED),
#    so the feet do not slide at any speed;
#  - every clip is timed from the moment its pose began (sim/seek.gd does not reset anim_time when the
#    pose changes), so a one-shot (straighten, look, slump, catch) plays from its start and ends held;
#  - a new pose fades in over BLEND seconds from the last one.
# The materials are the model's own maps (colour, normal, roughness; the mask's print and glow map; alpha
# cut-outs for the eye holes and rags) on the Playroom's light: client/minder_skin.gdshader and
# client/minder_mask.gdshader. In count dark the mask's glow goes up to MASK_DARK_E, and from far off the
# light it sheds (client/minder_halo.gdshader) keeps the face reading alone in the dark at 10 m.
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

const MODEL := "res://assets/entities/minder.glb"
## Not a Stillness resident: the pose hold is off (see the header).
const STILLNESS := false
const NOTE_STEP := 0.5          # metres walked per note: three per 1.5 m
const HEAR_RANGE := 30.0
const MUFFLED_GAIN := 0.45
const NOTE_DB := -2.0
const BOX_HEIGHT := 1.55        # where the music box hangs, standing
## The floor's tune, our own: semitones above the box's note, one per note played, round and round.
const TUNE: Array[int] = [7, 4, 0, 4, 7, 7, 9, 7, 4, 2, 4, 0, 2, 4, 2, -1, 0]
const BASE_HZ := 1046.5

## Every pose name the rules can set (sim/seek.gd, MinderState.anim) and the interim rules' names
## (idle, walk, duck, reach), and the clip in the model that draws it.
const CLIPS := {
	"stand": "stand", "walk": "walk", "straighten": "straighten", "cover": "cover", "prowl": "prowl",
	"sweep": "sweep", "look": "look", "slump": "slump", "run": "run", "catch": "catch",
	"idle": "stand", "duck": "walk", "reach": "catch",
}
## The rules' poses (sim/seek.gd's documented list).
const RULE_POSES: Array[String] = ["stand", "walk", "straighten", "cover", "prowl", "sweep", "look", "slump", "run", "catch"]
## The gaits' own ground speed in the model, m/s: these clips run on the distance walked.
const GAIT_SPEED := {"walk": 1.0, "prowl": 2.1, "run": 5.2}
## Seconds a new pose takes to fade in from the last.
const BLEND := 0.2

## The body's own light: a figure under strip lights, a little darker than the walls.
const BODY_LIGHT := 0.75
## The mask's glow (its glow map times this colour and energy): as the model has it under the strip
## lights (the energy is read from the model, 0.26 when built), and raised in count dark so the bare card
## glows green-white with the ink and the eye holes dark (above about 2 the card blows out white and
## the face is lost).
const MASK_LIT := Color(1.0, 1.0, 1.0)
const MASK_DARK := Color(1.0, 1.0, 1.0)
const MASK_LIT_E := 0.26
const MASK_DARK_E := 1.0
## The light the mask sheds in the dark, seen from far off (client/minder_halo.gdshader): a soft round
## glow HALO_SIZE metres across in front of the card, from nothing at 3 m to HALO_E at 9 m and beyond.
## The card is 11 cm across, under three pixels at 10 m: without it the face is a speck.
const HALO_SIZE := 0.5
const HALO_E := 1.6

## Tests: a deliberate break. "clip" maps the look pose to a clip the model does not have (the clips
## check must go red); "hold" draws the held pose handed in (the hold check must go red); "clip+hold"
## both.
static var test_break := ""

## Every note so far (tests): {semi, gain, muffled, at}.
var notes: Array[Dictionary] = []
## The pose drawn last (tests), and which body it used: "upright", "fours" or "cover".
var drawn: Variant = null
var body_kind := "upright"
## Frames whose pose came from the snapshots rather than from the (held) pose handed in (tests).
var unheld_frames := 0
## The clip drawn, its time, and how far the fade from the last clip is (tests).
var clip := ""
var clip_time := 0.0
var fade := 1.0

var model: Node3D
var skel: Skeleton3D
var mesh: MeshInstance3D
## Clip name -> Animation, from the model.
var anims := {}
var _tracks := {}
var _rest_pos := PackedVector3Array()
var _rest_rot: Array[Quaternion] = []
var _rest_scl := PackedVector3Array()
var _body_mat: ShaderMaterial
var _mask_mat: ShaderMaterial
var _halo_mat: ShaderMaterial = null
var _mask_lit_e := MASK_LIT_E
var _mask_surface := -1
var _player: AudioStreamPlayer3D
var _plan: Floor.FloorPlan = null
var _link: Object = null
var _dist := 0.0
var _last := Vector3.INF
var _note_k := 0
var _last_us := 0
var _prev := ""
var _prev_t := 0.0
var _fade_t := 0.0

func _init() -> void:
	_load_model()
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

## The card is lit as the body is: it follows the body's energy, which the Playroom's view sets.
func _process(_delta: float) -> void:
	var lit := float(_body_mat.get_shader_parameter("energy"))
	_mask_mat.set_shader_parameter("lit", lit)
	if _halo_mat:
		_halo_mat.set_shader_parameter("lit", lit)

## The bus its music box plays on: "Entity" when the layout has one, otherwise "Sfx".
static func bus_name() -> StringName:
	return &"Entity" if AudioServer.get_bus_index(&"Entity") != -1 else &"Sfx"

func reset() -> void:
	_dist = 0.0
	_last = Vector3.INF
	_note_k = 0
	drawn = null
	clip = ""
	clip_time = 0.0
	fade = 1.0
	_prev = ""
	visible = false

# --- the model ------------------------------------------------------------------------------------

func _load_model() -> void:
	var ps: PackedScene = load(MODEL)
	model = ps.instantiate()
	model.name = "Model"
	add_child(model)
	var ap: AnimationPlayer = model.find_child("AnimationPlayer", true, false)
	if ap:
		# The clips are sampled here (see the header), never played by the player.
		ap.active = false
		for n: StringName in ap.get_animation_list():
			anims[String(n)] = ap.get_animation(n)
	skel = model.find_child("Skeleton3D", true, false)
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		mesh = mi
		break
	for b in skel.get_bone_count():
		var rest := skel.get_bone_rest(b)
		_rest_pos.append(rest.origin)
		_rest_rot.append(rest.basis.get_rotation_quaternion())
		_rest_scl.append(rest.basis.get_scale())
	for c: String in anims:
		var a: Animation = anims[c]
		var rows: Array[PackedInt32Array] = []
		for i in a.get_track_count():
			var tp := a.track_get_type(i)
			if tp != Animation.TYPE_POSITION_3D and tp != Animation.TYPE_ROTATION_3D and tp != Animation.TYPE_SCALE_3D:
				continue
			var b := skel.find_bone(String(a.track_get_path(i).get_concatenated_subnames()))
			if b >= 0:
				rows.append(PackedInt32Array([i, b, tp]))
		_tracks[c] = rows
	_body_mat = ShaderMaterial.new()
	_body_mat.shader = load("res://client/minder_skin.gdshader")
	_mask_mat = ShaderMaterial.new()
	_mask_mat.shader = load("res://client/minder_mask.gdshader")
	for s in mesh.mesh.get_surface_count():
		var src := mesh.mesh.surface_get_material(s) as StandardMaterial3D
		var is_mask := src != null and src.resource_name.to_lower().contains("mask")
		if is_mask:
			_mask_surface = s
			_mask_mat.set_shader_parameter("albedo_tex", src.albedo_texture)
			_mask_mat.set_shader_parameter("glow_tex", src.emission_texture)
			_mask_mat.set_shader_parameter("scissor", src.alpha_scissor_threshold)
			_mask_mat.set_shader_parameter("roughness", src.roughness)
			_mask_lit_e = src.emission.srgb_to_linear().r * src.emission_energy_multiplier
		elif src != null:
			_body_mat.set_shader_parameter("albedo_tex", src.albedo_texture)
			_body_mat.set_shader_parameter("normal_tex", src.normal_texture)
			_body_mat.set_shader_parameter("rough_tex", src.roughness_texture)
			_body_mat.set_shader_parameter("normal_depth", src.normal_scale)
			_body_mat.set_shader_parameter("scissor", src.alpha_scissor_threshold)
		mesh.set_surface_override_material(s, _mask_mat if is_mask else _body_mat)
	_body_mat.set_shader_parameter("self_light", BODY_LIGHT)
	_body_mat.set_shader_parameter("energy", 1.0)
	_mask_mat.set_shader_parameter("self_light", BODY_LIGHT)
	_mask_mat.set_shader_parameter("lit", 1.0)
	_mask_mat.set_shader_parameter("color", MASK_LIT)
	_mask_mat.set_shader_parameter("energy", _mask_lit_e)
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_make_halo()
	_set_clip_pose("stand", 0.0, "", 0.0, 1.0)

## A bone's rest pose in the skeleton's frame.
func _rest_global(b: int) -> Transform3D:
	var x := skel.get_bone_rest(b)
	var p := skel.get_bone_parent(b)
	while p >= 0:
		x = skel.get_bone_rest(p) * x
		p = skel.get_bone_parent(p)
	return x

## The halo (client/minder_halo.gdshader), carried by the head bone a few centimetres in front of the
## middle of the card, its +z the way the card faces (both from the mask's own vertices as built).
func _make_halo() -> void:
	var head := skel.find_bone("head")
	if _mask_surface < 0 or head < 0:
		return
	var arr := mesh.mesh.surface_get_arrays(_mask_surface)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var mid := Vector3.ZERO
	for v in verts:
		mid += v
	mid /= maxi(verts.size(), 1)
	var face := Vector3.ZERO
	for i in range(0, idx.size(), 3):
		face += (verts[idx[i + 2]] - verts[idx[i]]).cross(verts[idx[i + 1]] - verts[idx[i]])
	face = face.normalized()
	var att := BoneAttachment3D.new()
	att.name = "MaskHalo"
	skel.add_child(att)
	att.bone_name = "head"
	_halo_mat = ShaderMaterial.new()
	_halo_mat.shader = load("res://client/minder_halo.gdshader")
	_halo_mat.set_shader_parameter("energy", HALO_E)
	_halo_mat.set_shader_parameter("lit", 1.0)
	var q := QuadMesh.new()
	q.size = Vector2(HALO_SIZE, HALO_SIZE)
	var mi := MeshInstance3D.new()
	mi.name = "Halo"
	mi.mesh = q
	mi.material_override = _halo_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.custom_aabb = AABB(Vector3.ONE * -HALO_SIZE, Vector3.ONE * HALO_SIZE * 2.0)
	var at_rest := Transform3D(Basis.looking_at(-face, Vector3.UP), mid + face * 0.04)
	mi.transform = _rest_global(head).affine_inverse() * at_rest
	att.add_child(mi)

## The floor it walks: its plan (heard duller through walls) and the Level drawing it. On the
## Playroom the body dims with the strip lights and the mask glows brighter in count dark.
func set_floor(plan: Floor.FloorPlan, lv: Level = null) -> void:
	_plan = plan
	if lv != null and lv.has_meta("playroom"):
		var view: Object = lv.get_meta("playroom")
		view.call(&"add_lit", _body_mat)
		view.call(&"add_glow", _mask_mat, MASK_LIT, MASK_DARK, _mask_lit_e, MASK_DARK_E)

## The mask's glow energy under the strip lights (the model's own) and in count dark.
func mask_glow() -> Dictionary:
	return {"lit": _mask_lit_e, "dark": MASK_DARK_E, "halo": HALO_E}

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
	if raw != null and pose != null and not test_break.contains("hold"):
		pose = raw
		unheld_frames += 1
	if pose == null:
		visible = false
		return
	var pd: Dictionary = pose
	var p := Vector3(float(pd["x"]), float(pd["y"]), float(pd["z"]))
	var anim := str(pd["anim"])
	var now := Time.get_ticks_usec()
	var dt := 0.0
	if _last_us > 0:
		dt = minf((now - _last_us) / 1e6, 0.1)
	_last_us = now
	var step := 0.0
	if _last != Vector3.INF:
		var d := Vector2(p.x - _last.x, p.z - _last.z).length()
		if d < 1.0:
			step = d
	_last = p
	_dist += step
	body_kind = family(anim)
	var k := floori(_dist / NOTE_STEP)
	if k > _note_k:
		_note(p, k)
	_note_k = k
	# The clocks run whether or not it is drawn, so a pose comes back where it would be.
	_advance(anim, dt, step)
	visible = show
	if not show:
		return
	drawn = pd.duplicate()
	position = p
	rotation = Vector3(0, float(pd["yaw"]) + PI, 0)
	_set_clip_pose(clip, clip_time, _prev, _prev_t, fade)

## The body a pose name asks for.
static func family(anim: String) -> String:
	match anim:
		"prowl", "run", "sweep", "look", "catch", "reach":
			return "fours"
		"cover":
			return "cover"
	return "upright"

## The clip that draws a pose name ("" when there is none).
static func clip_for(anim: String) -> String:
	if test_break.contains("clip") and anim == "look":
		return "peer"
	return str(CLIPS.get(anim, ""))

## Moves the clocks on: a new pose starts its clip from its first frame and fades in from the last one.
func _advance(anim: String, dt: float, step: float) -> void:
	var want := clip_for(anim)
	if not anims.has(want):
		want = "stand"
	if want != clip:
		_prev = clip
		_prev_t = clip_time
		clip = want
		clip_time = 0.0
		_fade_t = 0.0 if _prev != "" else BLEND
	else:
		clip_time += _rate(clip, dt, step)
		_fade_t += dt
	if _prev != "":
		_prev_t += _rate(_prev, dt, step)
	fade = clampf(_fade_t / BLEND, 0.0, 1.0)
	if fade >= 1.0:
		_prev = ""

## How far a clip's clock moves this frame: a gait by the distance walked over its own ground speed,
## anything else by the time.
static func _rate(c: String, dt: float, step: float) -> float:
	if GAIT_SPEED.has(c):
		return step / float(GAIT_SPEED[c])
	return dt

## The clip's own time for a clock: round and round for a loop, held at the end for a one-shot.
func _clip_t(c: String, t: float) -> float:
	var a: Animation = anims[c]
	if a.loop_mode != Animation.LOOP_NONE:
		return fposmod(t, a.length) if a.length > 0.0 else 0.0
	return clampf(t, 0.0, a.length)

## Samples a clip at its time into per-bone arrays (the rest pose where it has no track).
func _sample(c: String, t: float, pos: PackedVector3Array, rot: Array[Quaternion], scl: PackedVector3Array) -> void:
	var a: Animation = anims[c]
	var ct := _clip_t(c, t)
	var rows: Array[PackedInt32Array] = _tracks[c]
	for r in rows:
		match r[2]:
			Animation.TYPE_ROTATION_3D:
				rot[r[1]] = a.rotation_track_interpolate(r[0], ct)
			Animation.TYPE_POSITION_3D:
				pos[r[1]] = a.position_track_interpolate(r[0], ct)
			Animation.TYPE_SCALE_3D:
				scl[r[1]] = a.scale_track_interpolate(r[0], ct)

## Poses the skeleton: clip `c` at `t`, faded in by `w` (smoothed) over `pc` at `pt`.
func _set_clip_pose(c: String, t: float, pc: String, pt: float, w: float) -> void:
	if not anims.has(c):
		return
	var pos := _rest_pos.duplicate()
	var rot: Array[Quaternion] = _rest_rot.duplicate()
	var scl := _rest_scl.duplicate()
	_sample(c, t, pos, rot, scl)
	if pc != "" and anims.has(pc) and w < 1.0:
		var pp := _rest_pos.duplicate()
		var pr: Array[Quaternion] = _rest_rot.duplicate()
		var ps := _rest_scl.duplicate()
		_sample(pc, pt, pp, pr, ps)
		var k := smoothstep(0.0, 1.0, w)
		for b in pos.size():
			pos[b] = pp[b].lerp(pos[b], k)
			rot[b] = pr[b].slerp(rot[b], k)
			scl[b] = ps[b].lerp(scl[b], k)
	for b in pos.size():
		skel.set_bone_pose_position(b, pos[b])
		skel.set_bone_pose_rotation(b, rot[b])
		skel.set_bone_pose_scale(b, scl[b])

## Tests: draws a pose's clip at exactly `t` seconds into it, no fade.
func hold_clip(anim: String, t: float) -> void:
	clip = clip_for(anim)
	if not anims.has(clip):
		clip = "stand"
	clip_time = t
	_prev = ""
	fade = 1.0
	body_kind = family(anim)
	_set_clip_pose(clip, t, "", 0.0, 1.0)

## Tests: the model as built (every bone at rest, upright). The next show_pose poses it again.
func rest_pose() -> void:
	for b in skel.get_bone_count():
		skel.set_bone_pose_position(b, _rest_pos[b])
		skel.set_bone_pose_rotation(b, _rest_rot[b])
		skel.set_bone_pose_scale(b, _rest_scl[b])

## Tests: a short hash of everything drawn about the figure right now.
func drawn_signature() -> String:
	var f := PackedFloat32Array()
	f.append(1.0 if visible else 0.0)
	var xs: Array[Transform3D] = [transform]
	for b in skel.get_bone_count():
		xs.append(skel.get_bone_pose(b))
	for x in xs:
		for v: Vector3 in [x.basis.x, x.basis.y, x.basis.z, x.origin]:
			f.append(v.x)
			f.append(v.y)
			f.append(v.z)
	return f.to_byte_array().hex_encode().md5_text().substr(0, 12)

# --- tests: the posed figure, skinned here on the CPU, in its own frame (feet at y 0, facing +z) ----

var _arrays := {}

func _surface(s: int) -> Array:
	if not _arrays.has(s):
		_arrays[s] = mesh.mesh.surface_get_arrays(s)
	return _arrays[s]

## A bone's pose in the skeleton's frame, composed from the local poses just set (the skeleton's own
## global poses are only brought up to date when it next draws).
func _bone_global(b: int) -> Transform3D:
	var x := skel.get_bone_pose(b)
	var p := skel.get_bone_parent(b)
	while p >= 0:
		x = skel.get_bone_pose(p) * x
		p = skel.get_bone_parent(p)
	return x

## The skeleton's frame in the figure's own frame.
func _skel_xf() -> Transform3D:
	var x := Transform3D()
	var n: Node3D = skel
	while n != self and n != null:
		x = n.transform * x
		n = n.get_parent() as Node3D
	return x

## Every vertex of a surface as posed now, in the figure's own frame.
func posed_vertices(s: int) -> PackedVector3Array:
	var arr := _surface(s)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
	var skin := mesh.skin
	var to_fig := _skel_xf()
	var mats: Array[Transform3D] = []
	for i in skin.get_bind_count():
		var bone := skin.get_bind_bone(i)
		if bone < 0:
			bone = skel.find_bone(skin.get_bind_name(i))
		mats.append(to_fig * _bone_global(bone) * skin.get_bind_pose(i))
	var per := bones.size() / maxi(verts.size(), 1)
	var out := PackedVector3Array()
	out.resize(verts.size())
	for v in verts.size():
		var p := Vector3.ZERO
		for j in per:
			var w := weights[v * per + j]
			if w > 0.0:
				p += (mats[bones[v * per + j]] * verts[v]) * w
		out[v] = p
	return out

## The bone each vertex of a surface follows most.
func _main_bone(s: int) -> PackedStringArray:
	var key := "main%d" % s
	if _arrays.has(key):
		return _arrays[key]
	var arr := _surface(s)
	var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
	var n := (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var per := bones.size() / maxi(n, 1)
	var out := PackedStringArray()
	for v in n:
		var best := 0
		for j in per:
			if weights[v * per + j] > weights[v * per + best]:
				best = j
		out.append(mesh.skin.get_bind_name(bones[v * per + best]))
	_arrays[key] = out
	return out

static func _in_hand(bone: String, side: String) -> bool:
	if not bone.ends_with("." + side):
		return false
	for p: String in ["hand", "index", "middle", "ring", "thumb"]:
		if bone.begins_with(p):
			return true
	return false

static func _side(n: String) -> String:
	return "R" if n.ends_with("_r") or n.ends_with(".R") else "L"

## Tests: the figure's extent in its own frame, from its skin as posed.
func extent() -> AABB:
	var box := AABB()
	var first := true
	for s in mesh.mesh.get_surface_count():
		for p in posed_vertices(s):
			if first:
				box = AABB(p, Vector3.ZERO)
				first = false
			else:
				box = box.expand(p)
	return box

## Tests: the lowest point of either hand (its fingertips), in the figure's own frame.
func fingertip_y() -> float:
	var low := INF
	var main := _main_bone(0)
	var vs := posed_vertices(0)
	for v in vs.size():
		if _in_hand(main[v], "L") or _in_hand(main[v], "R"):
			low = minf(low, vs[v].y)
	return low

## Tests: the middle of a hand, palm to fingertips ("hand_l" or "hand_r"), in the figure's own frame.
func hand_middle(n: String) -> Vector3:
	var side := _side(n)
	var main := _main_bone(0)
	var vs := posed_vertices(0)
	var sum := Vector3.ZERO
	var cnt := 0
	for v in vs.size():
		if _in_hand(main[v], side):
			sum += vs[v]
			cnt += 1
	return sum / maxi(cnt, 1)

## Tests: where a bone is in the figure's own frame (a bone name, or the old names head, knee_l,
## knee_r, hand_l, hand_r).
func joint_point(n: String) -> Vector3:
	var names := {"knee_l": "shin.L", "knee_r": "shin.R", "hand_l": "hand.L", "hand_r": "hand.R"}
	var b := skel.find_bone(str(names.get(n, n)))
	return _skel_xf() * _bone_global(b).origin

## Tests: the mask's middle and its facing (its faces' summed normals) in the figure's own frame, the
## head bone, and how many surfaces carry the mask's material (one: the face is on the front only).
func mask_info() -> Dictionary:
	var count := 0
	for s in mesh.mesh.get_surface_count():
		if mesh.get_surface_override_material(s) == _mask_mat:
			count += 1
	var at := Vector3.ZERO
	var facing := Vector3.ZERO
	if _mask_surface >= 0:
		var vs := posed_vertices(_mask_surface)
		for p in vs:
			at += p
		at /= maxi(vs.size(), 1)
		var idx: PackedInt32Array = _surface(_mask_surface)[Mesh.ARRAY_INDEX]
		for i in range(0, idx.size(), 3):
			var a := vs[idx[i]]
			# Godot's front faces wind clockwise: the outward normal is (c - a) x (b - a).
			facing += (vs[idx[i + 2]] - a).cross(vs[idx[i + 1]] - a)
	return {"count": count, "at": at, "facing": facing.normalized(), "head": joint_point("head")}

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
