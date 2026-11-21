# Split reality on this screen only (SR1; sim/split.gd, North Star E1 and E2). Everything here is drawn from the
# host's "split" block in this player's own world (net/host.gd _world_for): nobody else's screen has it.
#   - The tells (E1): a heartbeat in the headphones (assets/sfx/shop/low_nerve.ogg, a heartbeat loop), faster and
#     louder as exposure climbs; a faint dark-red pulse in time with it at the picture's left, top and right edges,
#     never over the instrument's corner; and this player's own lamp (the carried beam and the near light) turning
#     slightly warmer. None of it touches the instrument. False calm: at the top the heartbeat stops, the pulse
#     goes and the lamp is its own colour again.
#   - Phantom figure: the floor's own resident figure (the same view, model and clips as the real one), heard first
#     (its own sound for split.gd HEARD_FIRST seconds as it comes up to the spot), then standing there facing you.
#   - Wrong face: one crewmate's figure is hidden and the floor's resident is drawn where they are, as they move;
#     their name tag goes (main.gd asks masked()). A breath where they stand.
#   - Phantom exit: a lift door with a lit car inside on a plain wall, with the lift's bell.
#   - The touch test (E4): when the host marks a sight gone, it flickers between false and true for split.gd
#     REVEAL_SECONDS, then it is gone.
# Not drawn for anyone else, never on the Ward or the Reactor (the host sends none there). A player out and watching
# a crewmate (crew_watch.gd) sees the true world: they are sent no sights, and the tells stop.
extends Node3D

const Split = preload("res://sim/split.gd")
const Floor = preload("res://sim/floor.gd")
const Furniture = preload("res://sim/furniture.gd")
const GroundskeeperView = preload("res://client/groundskeeper_view.gd")
const SFX_DIR := "res://assets/sfx/"
const HEART := "shop/low_nerve"
## The tells start at this exposure (below it the heart is your own, unheard).
const TELL_FROM := 0.15
const WARM := Color(1.0, 0.62, 0.32)
const WARMEST := 0.28
## The sound each floor's phantom makes as it comes (looped), and while it stands.
const COMING := {"orderly": "orderly/trolley_squeak", "temp": "annex/temp_walk", "minder": "playroom/wheeze", "groundskeeper": "arboretum/badges_swing"}
const STANDING := {"orderly": "orderly/breath_slow", "temp": "annex/staple_soft", "minder": "playroom/huff", "groundskeeper": "arboretum/breath"}
const BELL := "annex/lift_bell"

var heart: AudioStreamPlayer
var pulse: ColorRect
var _pulse_mat: ShaderMaterial
var _beat := 0.0
var _kind := ""
var figure: Node3D = null
var _figure_plan: Floor.FloorPlan = null
var exit_door: Node3D = null
var cue: AudioStreamPlayer3D
var _cue_file := ""
var _bell_for := -1
var _anim_t := 0.0
## What this screen draws now (check()).
var exposure := 0.0
var calm := false
var masked_id := ""
var drawn := {}

func setup(hud: Node) -> void:
	heart = AudioStreamPlayer.new()
	heart.name = "SplitHeart"
	heart.bus = &"Sfx" if AudioServer.get_bus_index(&"Sfx") != -1 else &"Master"
	var st := _stream(HEART, true)
	heart.stream = st
	add_child(heart)
	cue = AudioStreamPlayer3D.new()
	cue.name = "SplitCue"
	cue.bus = &"Entity" if AudioServer.get_bus_index(&"Entity") != -1 else &"Sfx"
	cue.unit_size = 6.0
	cue.max_distance = 40.0
	add_child(cue)
	pulse = ColorRect.new()
	pulse.name = "SplitPulse"
	pulse.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pulse.set_anchors_preset(Control.PRESET_FULL_RECT)
	var sh := Shader.new()
	sh.code = """shader_type canvas_item;
uniform float strength = 0.0;
void fragment() {
	vec2 uv = UV;
	float edge = min(min(uv.x, 1.0 - uv.x) * 1.6, uv.y);
	float a = (1.0 - smoothstep(0.0, 0.16, edge)) * strength;
	// Never over the instrument: it sits in the picture's lower right (client/instrument_view.gd).
	if (uv.x > 0.6 && uv.y > 0.5) { a = 0.0; }
	COLOR = vec4(0.32, 0.0, 0.02, a);
}"""
	_pulse_mat = ShaderMaterial.new()
	_pulse_mat.shader = sh
	pulse.material = _pulse_mat
	hud.add_child(pulse)

static func _stream(path: String, loop: bool) -> AudioStream:
	var file := SFX_DIR + path + ".ogg"
	if not ResourceLoader.exists(file):
		return null
	var st := load(file) as AudioStreamOggVorbis
	if st == null:
		return null
	st = st.duplicate() as AudioStreamOggVorbis
	st.loop = loop
	return st

func clear() -> void:
	if figure != null:
		figure.queue_free()
		figure = null
	_kind = ""
	_figure_plan = null
	if exit_door != null:
		exit_door.visible = false
	if cue != null:
		cue.stop()
	_cue_file = ""
	masked_id = ""
	drawn = {}

## The crewmate wearing the resident's face on this screen ("" for none): main.gd hides their name tag.
func masked() -> String:
	return masked_id

## Per frame. `block`: this world's "split" (or null); `now`: host time; `kind`: main.gd's resident kind; `others`: the
## frame's others rows; `crew`: the OthersView; `lamp_lights`: [near light, own carried beam or null] to warm; `me_ok`:
## this player is on their feet (not out watching someone).
func update(dt: float, block: Variant, now: float, kind: String, plan: Floor.FloorPlan, seed: String, faces: Array[String],
		others: Array, crew: Node3D, lamp_lights: Array, base_near: Color, base_beam: Color, me_ok: bool, ear: Vector3) -> void:
	masked_id = ""
	drawn = {}
	var sights: Array = []
	if block is Dictionary and me_ok:
		exposure = float(block.get("e", 0.0))
		calm = bool(block.get("calm", false))
		sights = block.get("sights", [])
	else:
		exposure = 0.0
		calm = false
	_tells(dt, lamp_lights, base_near, base_beam)
	var phantom: Dictionary = {}
	var face: Dictionary = {}
	var exit: Dictionary = {}
	for g: Dictionary in sights:
		match str(g.get("kind", "")):
			"phantom": phantom = g
			"face": face = g
			"exit": exit = g
	_anim_t += dt
	_show_exit(exit, now)
	var body := phantom if not phantom.is_empty() else face
	if body.is_empty() or kind in ["", "orientation"]:
		if figure != null:
			figure.call(&"show_pose", null, false)
		if exit.is_empty():
			_cue(null, "")
		return
	_ensure_figure(kind, plan, seed, faces)
	if figure == null:
		return
	var gone := float(body.get("gone", -1.0))
	var flick := gone >= 0.0 and int(floorf((now - gone) / 0.08)) % 2 == 0
	if not phantom.is_empty():
		var at := Vector3(float(phantom.x), float(phantom.y), float(phantom.z))
		var yaw := float(phantom.yaw)
		var from := float(phantom.from)
		if now < from:
			# Heard first: it comes up the last metres to its spot, unseen, making its sound.
			var back := Vector3(-sin(yaw), 0.0, -cos(yaw))
			var k := clampf(1.0 - (from - now) / Split.HEARD_FIRST, 0.0, 1.0)
			var p := at - back * 2.5 * (1.0 - k)
			figure.call(&"show_pose", _pose(p, int(phantom.level), yaw, "walk"), false)
			_cue(p + Vector3(0, 0.6, 0), str(COMING.get(kind, "")))
			drawn = {"kind": "phantom", "id": int(phantom.id), "heard": true, "seen": false}
		else:
			figure.call(&"show_pose", _pose(at, int(phantom.level), yaw, "idle"), not flick)
			_cue(at + Vector3(0, 1.6, 0), str(STANDING.get(kind, "")) if gone < 0.0 else "")
			drawn = {"kind": "phantom", "id": int(phantom.id), "heard": true, "seen": not flick, "at": [at.x, at.y, at.z]}
		return
	# A wrong face: the crewmate as they are drawn, wearing the resident.
	var who := str(face.who)
	var row: Dictionary = {}
	for o: Dictionary in others:
		if str(o.get("id", "")) == who:
			row = o
	var fig: Dictionary = crew.get("figures").get(who, {}) if crew != null else {}
	if row.is_empty() or fig.is_empty():
		figure.call(&"show_pose", null, false)
		return
	var view: Node3D = fig["view"]
	var at := Vector3(float(row.x), float(row.y), float(row.z))
	var moving := float(fig.get("speed", 0.0)) > 0.3
	if not flick:
		view.visible = false
		masked_id = who
	figure.call(&"show_pose", _pose(at, int(face.level), float(row.get("yaw", 0.0)), "walk" if moving else "idle"), not flick)
	_cue(at + Vector3(0, 1.6, 0), str(STANDING.get(kind, "")) if gone < 0.0 else "")
	drawn = {"kind": "face", "id": int(face.id), "who": who, "seen": not flick}

func _pose(p: Vector3, level: int, yaw: float, anim: String) -> Dictionary:
	return {"x": p.x, "y": p.y, "z": p.z, "level": level, "yaw": yaw, "anim": anim, "animTime": _anim_t, "mode": "waiting"}

func _ensure_figure(kind: String, plan: Floor.FloorPlan, seed: String, faces: Array[String]) -> void:
	if figure != null and kind == _kind and plan == _figure_plan:
		return
	if figure != null and kind != _kind:
		figure.queue_free()
		figure = null
	if figure == null:
		match kind:
			"temp": figure = TempView.new()
			"minder": figure = MinderView.new()
			"groundskeeper": figure = GroundskeeperView.new()
			_: figure = OrderlyView.new()
		figure.name = "SplitPhantom"
		add_child(figure)
		_kind = kind
	figure.call(&"reset")
	_figure_plan = plan
	# Its own floor, never the real one's hooks: no hush ring, no lit panels registered (they are the real resident's).
	if figure is OrderlyView:
		(figure as OrderlyView).set_floor(plan, [] as Array[Furniture.Piece])
	elif figure is TempView:
		(figure as TempView).set_crew(seed, faces)
		(figure as TempView).set_floor(plan, null)
	elif figure is MinderView:
		(figure as MinderView).set_floor(plan, null)
	elif figure is GroundskeeperView:
		figure.set(&"_hush_lead", GroundskeeperView.HUSH_LEAD)

func _cue(at: Variant, file: String) -> void:
	if at == null or file.is_empty():
		if cue.playing:
			cue.stop()
		_cue_file = ""
		return
	cue.global_position = at
	if file != _cue_file:
		_cue_file = file
		cue.stream = _stream(file, true)
		if cue.stream != null:
			cue.volume_db = -6.0
			cue.play()

func _show_exit(exit: Dictionary, now: float) -> void:
	if exit.is_empty():
		if exit_door != null:
			exit_door.visible = false
		return
	if exit_door == null:
		exit_door = _build_door()
		add_child(exit_door)
	var yaw := float(exit.yaw)
	var side := Vector3(sin(yaw), 0.0, cos(yaw))
	exit_door.position = Vector3(float(exit.x), float(exit.y), float(exit.z)) - side * 0.13
	exit_door.rotation = Vector3(0.0, yaw, 0.0)
	var gone := float(exit.get("gone", -1.0))
	exit_door.visible = not (gone >= 0.0 and int(floorf((now - gone) / 0.08)) % 2 == 0)
	if _bell_for != int(exit.id):
		_bell_for = int(exit.id)
		var bell := AudioStreamPlayer3D.new()
		bell.bus = cue.bus
		bell.stream = _stream(BELL, false)
		bell.unit_size = 8.0
		add_child(bell)
		bell.global_position = exit_door.global_position + Vector3(0, 2.0, 0)
		if bell.stream != null:
			bell.play()
		bell.finished.connect(bell.queue_free)
	drawn["exit"] = {"id": int(exit.id), "seen": exit_door.visible}

## A lift door in its frame with the lit car behind: local -z faces into the corridor, +z is the wall.
static func _build_door() -> Node3D:
	var door := Node3D.new()
	door.name = "SplitExit"
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.36, 0.37, 0.36)
	steel.metallic = 0.6
	steel.roughness = 0.45
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.03, 0.03, 0.03)
	var lit := StandardMaterial3D.new()
	lit.albedo_color = Color(0.95, 0.86, 0.62)
	lit.emission_enabled = true
	lit.emission = Color(0.95, 0.82, 0.55)
	lit.emission_energy_multiplier = 0.9
	var parts := [[Vector3(-0.9, 1.2, 0.0), Vector3(0.16, 2.4, 0.1), steel], [Vector3(0.9, 1.2, 0.0), Vector3(0.16, 2.4, 0.1), steel],
		[Vector3(0.0, 2.45, 0.0), Vector3(1.96, 0.2, 0.1), steel], [Vector3(0.0, 1.17, 0.04), Vector3(1.64, 2.34, 0.02), dark],
		[Vector3(0.0, 1.17, 0.02), Vector3(0.9, 2.2, 0.01), lit], [Vector3(-0.62, 1.17, 0.0), Vector3(0.4, 2.34, 0.04), steel],
		[Vector3(0.62, 1.17, 0.0), Vector3(0.4, 2.34, 0.04), steel], [Vector3(1.15, 1.25, -0.02), Vector3(0.12, 0.2, 0.04), lit]]
	for part: Array in parts:
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = part[1]
		mi.mesh = box
		mi.material_override = part[2]
		mi.position = part[0]
		door.add_child(mi)
	var glow := OmniLight3D.new()
	glow.light_color = Color(1.0, 0.85, 0.6)
	glow.light_energy = 0.6
	glow.omni_range = 3.0
	glow.position = Vector3(0, 1.4, -0.4)
	door.add_child(glow)
	return door

## The heartbeat, the pulse at the edges and the warm lamp, from this player's exposure; none in false calm.
func _tells(dt: float, lamp_lights: Array, base_near: Color, base_beam: Color) -> void:
	var on := exposure >= TELL_FROM and not calm
	var w := clampf((exposure - TELL_FROM) / (1.0 - TELL_FROM), 0.0, 1.0) if on else 0.0
	if heart != null and heart.stream != null:
		if on:
			heart.pitch_scale = lerpf(0.85, 1.6, w)
			heart.volume_db = lerpf(-24.0, -6.0, w)
			if not heart.playing:
				heart.play()
		elif heart.playing:
			heart.stop()
	var bpm := lerpf(60.0, 130.0, w)
	_beat = fmod(_beat + dt * bpm / 60.0, 1.0)
	var thump := exp(-_beat * 9.0) + 0.6 * exp(-absf(_beat - 0.22) * 14.0)
	if _pulse_mat != null:
		_pulse_mat.set_shader_parameter("strength", 0.35 * w * clampf(thump, 0.0, 1.0) if on else 0.0)
	var warmth := WARMEST * w
	if lamp_lights.size() > 0 and lamp_lights[0] is Light3D:
		(lamp_lights[0] as Light3D).light_color = base_near.lerp(WARM, warmth)
	if lamp_lights.size() > 1 and lamp_lights[1] is Light3D:
		(lamp_lights[1] as Light3D).light_color = base_beam.lerp(WARM, warmth)

## What a check reads of this screen's split reality.
func check() -> Dictionary:
	return {"exposure": exposure, "calm": calm, "heart": heart != null and heart.playing, "pulse": float(_pulse_mat.get_shader_parameter("strength")) if _pulse_mat != null else 0.0,
		"masked": masked_id, "drawn": drawn, "figure": figure != null and figure.visible}
