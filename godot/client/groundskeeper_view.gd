# The Blender Groundskeeper follows the host's pose and uses the garden's actual light.
# Recordings follow the animated figure. Nothing here decides who the keeper hears or catches.
extends Node3D

const GardenSound = preload("res://client/garden_sound.gd")
const MODEL := "res://assets/entities/groundskeeper.glb"
## The Meshy figure (MG1), drawn unless the game was started with `figures=old` (client/figures.gd), or its
## file is missing. Same clips, bones and timings.
const MODEL_NEW := "res://assets/entities/groundskeeper_v2.glb"
const CLIPS := {"idle": &"listen", "tilt": &"tilt", "walk": &"walk", "lean": &"lean",
	"sweep": &"sweep", "catch": &"snatch"}

# A complete two-step walk cycle covers twice this distance.
const STEP := 1.3
const NEAR_SNATCH := 4.0
const BLADE_CONTACT := 0.20
const SNATCH_IMPACT := 0.085   # Seconds from the decoded start to the impact in both takes.
const SHEARS_IMPACT := 0.149
const LEAN_HOLD := 2.5
## The environmental warning leads the first sight of this resident on each floor.
const HUSH_LEAD := 0.20
const HUSH_AUDIBLE := 0.75

var drawn := {}
var _last := Vector3.INF
var _dist := 0.0
var _step_k := 0
var _last_us := 0
var _anim := ""
var _struck := false
var _recovering := false
var _hush_lead := 0.0

var _model: Node3D
var _player: AnimationPlayer
var _rig: Skeleton3D
var _head := -1
var _shears := -1
var _badges := -1
var _clinks: Array[AudioStreamPlayer3D] = []
var _clink_next := 0
var _breath: AudioStreamPlayer3D
var _swing_snd: AudioStreamPlayer3D
var _sniff: AudioStreamPlayer3D
var _snatch: AudioStreamPlayer3D
var _strike_impact := 0.0
var _garden_audio := GardenSound.new()
## Which figure _build loads. Empty: whatever the switch says.
var figure_model := ""

## The figure the shared switch (client/figures.gd) picks from the user arguments and the address's query string.
static func model_for(args: PackedStringArray, query: String) -> String:
	return MODEL_NEW if Figures.new_for(args, query) else MODEL

## The figure this run draws: the new one unless Figures says old, or today's when the new file is missing.
static func model_path() -> String:
	return MODEL_NEW if Figures.use_new() and ResourceLoader.exists(MODEL_NEW) else MODEL

func _ready() -> void:
	_build()
	visible = false

func _build() -> void:
	var path := figure_model if figure_model != "" else model_path()
	if not ResourceLoader.exists(path):
		path = MODEL
	var scene := load(path) as PackedScene if ResourceLoader.exists(path) else null
	if scene != null:
		_model = scene.instantiate() as Node3D
		add_child(_model)
		_player = _model.find_child("AnimationPlayer", true, false) as AnimationPlayer
		if _player != null:
			_player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		for skeleton in _model.find_children("*", "Skeleton3D", true, false):
			_rig = skeleton as Skeleton3D
			break
		if _rig != null:
			_head = _rig.find_bone("Head")
			_shears = _rig.find_bone("Shears")
			_badges = _rig.find_bone("Badges")
	# Its sounds.
	for k in 4:
		var c := _audio_player(&"Entity", 5.0, 34.0, Sfx.BASE_DB + 6.0)
		_clinks.append(c)
	# Heard half as far again (was 1.6 m full, 5.5 m cut-off): the owner's playtest, 19 Nov.
	_breath = _audio_player(&"Entity", 2.4, 8.25, Sfx.BASE_DB + 3.0)
	_breath.stream = _garden_audio.next("breath")
	_swing_snd = _audio_player(&"Entity", 3.0, 12.0, -60.0)
	_swing_snd.stream = _garden_audio.next("badges_swing")
	_sniff = _audio_player(&"Entity", 2.0, 5.5, Sfx.BASE_DB)
	_snatch = _audio_player(&"Scare", 8.0, 40.0, Sfx.BASE_DB)

func _audio_player(bus: StringName, unit: float, far: float, db: float) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.bus = bus
	p.unit_size = unit
	p.max_distance = far
	p.max_db = 0.0
	p.volume_db = db
	p.position = Vector3(0, 1.8, 0.2)
	add_child(p)
	return p

func reset() -> void:
	_last = Vector3.INF
	_dist = 0.0
	_step_k = 0
	_anim = ""
	_recovering = false
	_last_us = 0
	drawn = {}
	_hush_lead = 0.0
	_struck = false
	visible = false
	_quiet()
	for clink in _clinks:
		clink.stop()
	if _snatch != null:
		_snatch.stop()

func _quiet() -> void:
	if _breath != null and _breath.playing:
		_breath.stop()
	if _swing_snd != null and _swing_snd.playing:
		_swing_snd.stop()
		_swing_snd.volume_db = -60.0
	if _sniff != null and _sniff.playing:
		_sniff.stop()

## (Every resident's view has it; looking does nothing to this one.)
func set_watched(_at: Variant) -> void:
	pass

## The floor it stands on: the Arboretum's view hushes the garden round it (the ring of silence).
func set_floor(level: Node) -> void:
	if level != null and level.has_meta(&"arboretum"):
		level.get_meta(&"arboretum").set(&"keeper", self)

## What a test reads of how it is drawn.
func look() -> Dictionary:
	var assets := {"glow": false, "unshaded": false, "passes": 0, "overlays": 0, "lights": 0}
	if _model != null:
		assets["lights"] = _model.find_children("*", "Light3D", true, false).size()
		for mesh: MeshInstance3D in _model.find_children("*", "MeshInstance3D", true, false):
			assets["overlays"] += int(mesh.material_overlay != null)
			for surface in mesh.mesh.get_surface_count():
				var material := mesh.get_active_material(surface) as BaseMaterial3D
				if material != null:
					assets["glow"] = assets["glow"] or material.emission_enabled
					assets["unshaded"] = assets["unshaded"] or material.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED
					assets["passes"] += int(material.next_pass != null)
	assets["sig"] = "groundskeeper-blender"
	assets["anim"] = _anim
	return assets

## Acoustics use the host pose even before there is a visible model.
func has_acoustic_pose() -> bool:
	return _last != Vector3.INF

func heard_hush(gain: float, dt: float) -> void:
	if _hush_lead >= HUSH_LEAD:
		return
	_hush_lead = _hush_lead + dt if gain <= HUSH_AUDIBLE and has_acoustic_pose() else 0.0

func show_pose(pose: Variant, show: bool) -> void:
	if pose == null:
		visible = false
		_last = Vector3.INF
		_last_us = 0
		_quiet()
		return
	var pd: Dictionary = pose
	var p := Vector3(float(pd["x"]), float(pd["y"]), float(pd["z"]))
	var anim := str(pd["anim"])
	var t := float(pd["animTime"])
	var now := Time.get_ticks_usec()
	var dt := 0.016
	if _last_us > 0:
		dt = clampf((now - _last_us) / 1e6, 0.001, 0.1)
	_last_us = now
	var step := 0.0
	if _last != Vector3.INF:
		var d := Vector2(p.x - _last.x, p.z - _last.z).length()
		if anim == "walk" and d < 1.5:
			step = d
	_last = p
	_dist += step
	drawn = pd
	position = p
	rotation = Vector3(0, float(pd["yaw"]) + PI, 0)
	visible = show and _model != null and _hush_lead >= HUSH_LEAD
	var changed := anim != _anim
	if changed:
		_recovering = anim == "idle" and _anim == "lean"
		_anim = anim
		_struck = false
	_pose(anim, t)
	if changed and anim == "lean":
		_sniff.stream = _garden_audio.next("sniff")
		if _sniff.stream != null:
			_sniff.play()
	elif changed and anim == "catch":
		_prepare_strike_sound()
	# A clink at each animated stride. When it stands, lean has its own badge recording.
	var k := floori(_dist / STEP)
	if k != _step_k:
		_step_k = k
		_clink()
	_sounds(anim, t, dt)

func _clink() -> void:
	# The first environmental warning has to come ahead of a badge sound as well as the rig.
	if _hush_lead <= 0.0:
		return
	var recording := _garden_audio.next("badge")
	if recording == null:
		return
	var c := _clinks[_clink_next]
	_clink_next = (_clink_next + 1) % _clinks.size()
	c.stream = recording
	c.play()

func _sounds(anim: String, t: float, dt: float) -> void:
	if _breath.stream != null and not _breath.playing:
		_breath.play()
	var want := Sfx.BASE_DB if anim == "lean" else -60.0
	_swing_snd.volume_db = move_toward(_swing_snd.volume_db, want, 90.0 * dt)
	if _swing_snd.stream != null and _swing_snd.volume_db > -55.0 and not _swing_snd.playing:
		_swing_snd.play()
	elif _swing_snd.volume_db <= -55.0 and _swing_snd.playing:
		_swing_snd.stop()
	if anim == "catch" and not _struck and _snatch.stream != null:
		var from := strike_playhead(t, _strike_impact)
		if from >= 0.0:
			_struck = true
			_snatch.play(from)

func _prepare_strike_sound() -> void:
	var cam := get_viewport().get_camera_3d()
	var near := cam != null and Vector2(cam.global_position.x - global_position.x,
		cam.global_position.z - global_position.z).length_squared() < NEAR_SNATCH * NEAR_SNATCH
	var recording := _garden_audio.next("snatch") if near else null
	var scare := recording != null
	if recording == null:
		recording = _garden_audio.next("shears")
	_snatch.bus = &"Scare" if scare else &"Entity"
	# Near snatches are short transients. Give them gain for the 3D pan loss.
	_snatch.volume_db = Sfx.BASE_DB + (9.0 if scare else 0.0)
	_snatch.stream = recording
	_strike_impact = SNATCH_IMPACT if scare else SHEARS_IMPACT

## Start early enough for the decoded transient to land when the blades close. A late
## snapshot can skip the lead-in, keeping enough of the attack to play the impact once.
static func strike_playhead(pose_time: float, impact: float) -> float:
	var late := pose_time - (BLADE_CONTACT - impact)
	return -1.0 if late < 0.0 else minf(late, impact - 0.015)

## Sample the rig at the host playhead. The extra beat after a safe lean uses the same pose.
func _pose(anim: String, t: float) -> void:
	if _player == null:
		return
	var clip: StringName = CLIPS.get(anim, &"listen")
	if _recovering and _player.has_animation(&"recover"):
		if t < _player.get_animation(&"recover").length:
			clip = &"recover"
		else:
			t -= _player.get_animation(&"recover").length
	if not _player.has_animation(clip):
		return
	var length := _player.get_animation(clip).length
	if _player.assigned_animation != clip or not _player.is_playing():
		_player.play(clip, 0.0)
	_player.seek(_clip_time(clip, t, length, _dist), true, true)
	if _rig == null:
		return
	_rig.force_update_all_bone_transforms()
	var head := _sound_position(_head, Vector3(0, 0, 0.07))
	var badges := _sound_position(_badges, Vector3.ZERO) if _badges >= 0 else head - Vector3(0, 0.28, 0)
	_breath.position = head
	_sniff.position = head
	_swing_snd.position = badges
	_snatch.position = _sound_position(_shears, Vector3.ZERO)
	for clink in _clinks:
		clink.position = badges

func _sound_position(bone: int, offset: Vector3) -> Vector3:
	if bone < 0:
		return Vector3(0, 1.8, 0.2)
	return to_local(_rig.to_global(_rig.get_bone_global_pose(bone).origin)) + offset

static func _clip_time(clip: StringName, t: float, length: float, distance: float) -> float:
	match clip:
		&"walk":
			return fposmod(distance / (STEP * 2.0), 1.0) * length
		&"listen":
			return fposmod(t, length)
		&"lean":
			return clampf(t, 0.0, minf(length, LEAN_HOLD))
		_:
			return clampf(t, 0.0, length)
