# The Clinic's failing lights on screen (rules: sim/dangers/failing_lights.gd). One view per circuit: a run
# of old twin-tube fittings down the middle of a stretch of far-side corridor, a grey ballast box between each
# pair with a scorched label, the tubes' ends gone black, and a laminated notice at each end. It decides nothing.
#
# Everything it shows and plays comes from the record's state and `since` (host time), never this screen's own
# clock, so every player sees and hears the same moment:
#   lit   the tubes burn a little yellow with a hum (buzz.wav, a room tone); the first moments of a lit state are
#         the strike (strike.wav): two ticks with a soft flash each, then the tubes catch;
#   warn  the hum goes rough and sags (wind.wav, with the Clinic's own flicker under it); on screen the whole
#         stretch, its light and the lamps just past its ends sag in three slow steps (1, 0.55, 0.25: two changes a
#         second) while the tube ends start to glow orange, so the warning reads from down the hall with sound low;
#   dark  every tube and the circuit's light out, the lamps past each end sagging with it (the same circuit), the
#         room over the dark core shaded (thin dark films on its floor, ceiling and walls, easing out over RAMP past
#         each end; the resident is lit only by what light is left, as in the blackout), a low amber strip at the skirting along
#         exactly that core (the Clinic's emergency strip), the starter ticking (dark.wav).
# Early dark, late light: the screen goes dark GUARD seconds before the rules do (by the host clock), and it lights
# again only once the snapshots being DRAWN (the client's render time, behind the host clock by the delay) are
# GUARD seconds past the dark's end, so the moves the dark allows are never drawn lit, whatever the delay.
# Nothing flashes more than three times a second.
#
# The floor's own lamps over the stretch are the level's (client/level.gd): this view takes them over at build
# (their lights freed, their panels hidden, a stand-in left in the level's lists) and lights the stretch with
# its ONE OmniLight3D instead, so the floor's light count only goes down. The lamps just past each end stay the
# level's; their strength is scaled through the level's own table while the circuit sags or is dark.
extends "res://client/dangers/kind_view.gd"

const PixelFont = preload("res://client/pixel_font.gd")
const Floor = preload("res://sim/floor.gd")

const S := 2.0
const LH := 3.2
const WALL_T := 0.14
const STRIP_Y0 := 0.06
const STRIP_Y1 := 0.2
const STRIP_COLOR := Color(1.0, 0.36, 0.05)
const TUBE_COLOR := Color(0.95, 0.88, 0.62)
const END_GLOW := Color(1.0, 0.45, 0.15)
## How much sooner the screen goes dark, and how much later it relights, than the rules (s).
const GUARD := 0.15
## The strike, as offsets into a lit state by the drawn time (s): two soft flashes 0.35 s apart (with strike.wav's
## two ticks), then on with its plink. Under three flashes a second.
const FLASHES: Array[Vector2] = [Vector2(0.15, 0.21), Vector2(0.50, 0.56)]
const FLASH_K := 0.6
const CATCH := 0.85
## The warning's sag on screen: the tubes' strength in each third of the warning.
const SAG_STEPS: Array[float] = [1.0, 0.55, 0.15]
## A shallow flutter over the sag (fraction of the strength, at FLUTTER_HZ): the tube looks unwell, never a flash.
const FLUTTER := 0.06
const FLUTTER_HZ := 9.0
## The tube ends' orange in each third of the warning (they go on pulsing slowly in the dark).
const END_STEPS: Array[float] = [0.15, 0.3, 0.45]
## The panels just past each end sag to this while the circuit is dark (their spill would light the run).
const NEIGHBOUR_SAG := 0.3
const NEIGHBOUR_REACH := 3.0
const LIGHT_ENERGY := 1.25
## How much of the light the shade films leave on the core's floor, ceiling and walls while it is dark.
const DIM := 0.45
## Past each end of the core the dimming eases back to none over this (m): a falloff, not a black slab. Inside the
## core it is full; only the rules' core is ever counted dark, so the ease is on the held side.
const RAMP := 3.0
## The shade films are cut in pieces this long (m), so each piece can stop at an opening.
const SHADE_STEP := 0.5
## How far behind the host clock the drawn snapshots are taken to be when the screen has no client to ask (s).
const FALLBACK_BEHIND := 0.35
const SND := "res://assets/sfx/dangers/failing_lights/"
## The notice, in the Clinic's pixel lettering: a heading at 3 texels a font pixel, the rest at 2.
const NOTICE_HEAD: Array[String] = ["LIGHTING", "FAULT"]
const NOTICE_BODY: Array[String] = ["REPORTED.", "", "ENGINEER", "BOOKED.", "", "PLEASE DO", "NOT DWELL", "IN THIS", "CORRIDOR."]
const NOTICE_SIZE := Vector2(0.4, 0.56)
## The notice's centre over the floor (m): its foot (1.39 m) clears the bumper rail, as the Clinic's eye-height pieces do.
const NOTICE_Y := 1.67
const PAPER := Color(0.95, 0.94, 0.89)
const INK := Color(0.1, 0.1, 0.12)

## The dark's shade: thin films just inside the stretch's floor, ceiling and walls (never across an opening), black
## with the alpha that leaves DIM of the light behind them, full over the core and easing to none over RAMP past each
## end. Plain geometry, so it needs nothing of the renderer (an earlier depth-texture volume blacked out its whole
## screen box under the Compatibility renderer). It shades the room, not anything standing in it.
const SHADE_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
uniform float dim = 1.0;
uniform float core = 1.0;
uniform float ramp = 1.0;
// The player's near light (the base's, kind_view.gd near_light_at/near_light_reach): no shade within half its reach of
// the camera, full shade from its reach out, so the near light and a carried lamp are never crushed.
uniform vec3 cam;
uniform float reach = 0.0;
varying float along;
varying vec3 wpos;
void vertex() {
	along = VERTEX.x;
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	float ease = 1.0 - smoothstep(0.0, 1.0, clamp((abs(along) - core) / ramp, 0.0, 1.0));
	float near = reach > 0.0 ? smoothstep(reach * 0.5, reach, distance(wpos, cam)) : 1.0;
	ALBEDO = vec3(0.0);
	ALPHA = (1.0 - dim) * ease * near;
}
"""

var _len := 10.0
var _wid := 2.0
var _core_half := 3.9
var _rec: Dictionary = {}
var _level: Node = null
var _light: OmniLight3D
var _tube_mats: Array[ShaderMaterial] = []
var _end_mats: Array[ShaderMaterial] = []
var _strip_mats: Array[ShaderMaterial] = []
var _strips: Array[MeshInstance3D] = []
var _dim_box: MeshInstance3D = null
var _dim_mat: ShaderMaterial = null
var _plan: Variant = null
var _buzz_stream: AudioStream = null
var _dark_stream: AudioStream = null
var _buzz: AudioStreamPlayer3D = null
var _dark_loop: AudioStreamPlayer3D = null
var _played := {}
## The level's lamps just past each end: [index into main_lights, its own strength].
var _neighbours: Array = []
var _taken := 0
## Tests: when 0 or more, the drawn snapshots' host time (else the client's render time is asked for).
var drawn_override := -1.0
## What the screen drew last frame (tests and the look script): the tubes' strength 0..1, whether dark, the
## neighbours' scale, the shade's strength, and the drawn time used.
var shown_k := 1.0
var shown_dark := false
var shown_neighbour := 1.0
var shown_dim := 1.0
var shown_drawn := 0.0

func build(rec: Dictionary, ctx: Dictionary) -> void:
	_rec = rec
	var n: Array = rec.get("n", [])
	if n.size() >= 3:
		_len = float(n[0])
		_wid = float(n[1])
		_core_half = float(n[2])
	_level = ctx.get("level")
	_plan = ctx.get("plan")
	_build_fittings()
	_build_strips()
	_build_dim()
	_build_notices()
	_light = OmniLight3D.new()
	_light.position = Vector3(0, LH - 0.35, 0)
	_light.light_color = TUBE_COLOR
	_light.light_energy = LIGHT_ENERGY
	_light.omni_range = _len * 0.5 + 2.2
	_light.omni_attenuation = 0.9
	_light.shadow_enabled = false
	add_child(_light)
	_buzz_stream = looped(load(SND + "buzz.wav"))
	_dark_stream = looped(load(SND + "dark.wav"))
	_take_over_lamps(rec)

func _local_to_world(p: Vector3) -> Vector3:
	var yaw := float(_rec.get("yaw", 0.0))
	return Vector3(float(_rec["x"]), float(_rec["y"]), float(_rec["z"])) + Basis(Vector3.UP, yaw) * p

## A looping copy of a 16-bit WAV (the files are imported without a loop).
static func looped(st: AudioStream) -> AudioStream:
	var w := st as AudioStreamWAV
	if w == null:
		return st
	var c := w.duplicate() as AudioStreamWAV
	c.loop_mode = AudioStreamWAV.LOOP_FORWARD
	c.loop_begin = 0
	c.loop_end = c.data.size() / (2 * (2 if c.stereo else 1))
	return c

# --- looks ---------------------------------------------------------------------------------------------------

static func _mat(col: Color, emit := 0.0, tex: Texture2D = null) -> ShaderMaterial:
	return Level.prop_material(col, tex, false, 0.0, emit)

func _box(size: Vector3, at: Vector3, m: Material) -> MeshInstance3D:
	var b := BoxMesh.new()
	b.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = b
	mi.material_override = m
	mi.position = at
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi

func _tube(at: Vector3, length: float, m: Material) -> void:
	var c := CylinderMesh.new()
	c.top_radius = 0.016
	c.bottom_radius = 0.016
	c.height = length
	c.radial_segments = 8
	c.rings = 1
	var mi := MeshInstance3D.new()
	mi.mesh = c
	mi.material_override = m
	mi.position = at
	mi.rotation = Vector3(0, 0, PI / 2)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

## One fitting per cell along, down the middle of the hall: a shallow steel trough with its diffuser gone, two
## bare tubes with blackened ends; a grey ballast box between each pair, its label scorched.
func _build_fittings() -> void:
	var cells := maxi(1, int(round(_len / S)))
	var trough := _mat(Color(0.62, 0.64, 0.6))
	var inner := _mat(Color(0.82, 0.82, 0.76))
	var plate := _mat(Color(0.44, 0.46, 0.45))
	var scorch := _mat(Color(0.16, 0.11, 0.07))
	var label := _mat(Color(0.78, 0.74, 0.55))
	var y := LH - 0.05
	for i in cells:
		var x := -_len / 2.0 + S * (i + 0.5)
		_box(Vector3(1.32, 0.05, 0.3), Vector3(x, y, 0), trough)
		_box(Vector3(1.28, 0.004, 0.24), Vector3(x, y - 0.027, 0), inner)
		for side: float in [-0.065, 0.065]:
			var tm := Level.glow_material(TUBE_COLOR, 1.0)
			_tube_mats.append(tm)
			_tube(Vector3(x, y - 0.06, side), 1.12, tm)
			# The ends: black where the cathodes have burned, glowing orange while the ballast fails and the starter tries.
			for e: float in [-0.59, 0.59]:
				var em := Level.glow_material(END_GLOW, 0.0)
				em.set_shader_parameter("color", Color(0.05, 0.04, 0.03))
				_end_mats.append(em)
				_tube(Vector3(x + e, y - 0.06, side), 0.07, em)
			# Lamp holders.
			for e: float in [-0.64, 0.64]:
				_box(Vector3(0.04, 0.05, 0.04), Vector3(x + e, y - 0.045, side), trough)
		if i < cells - 1:
			var bx := x + S * 0.5
			_box(Vector3(0.36, 0.06, 0.14), Vector3(bx, y + 0.005, 0), plate)
			_box(Vector3(0.12, 0.002, 0.08), Vector3(bx - 0.05, y - 0.026, 0), label)
			_box(Vector3(0.09, 0.0025, 0.06), Vector3(bx - 0.03, y - 0.0265, 0.01), scorch)
			# The cable between fittings, slack.
			_box(Vector3(S - 1.36, 0.012, 0.012), Vector3(bx, y - 0.01, 0.1), plate)

## The strip's length: exactly the rules' dark core, so the amber line is where the dark is.
func strip_length() -> float:
	return 2.0 * _core_half

## A low amber strip at the skirting along both walls over the dark core, lit only while the circuit is dark.
func _build_strips() -> void:
	for side: float in [-1.0, 1.0]:
		var m := Level.glow_material(STRIP_COLOR, 0.0)
		_strip_mats.append(m)
		var z := side * (_wid / 2.0 - WALL_T / 2.0 - 0.012)
		var mi := _box(Vector3(strip_length(), STRIP_Y1 - STRIP_Y0, 0.02), Vector3(0, (STRIP_Y0 + STRIP_Y1) / 2.0, z), m)
		mi.visible = false
		_strips.append(mi)

## The shade films over the dark core (see SHADE_SHADER), shown only while the circuit is drawn dark. Near-light ready:
## when the base gives kind views the near light's reach, ease ALPHA to 0 within that reach of CAMERA_POSITION_WORLD here.
func _build_dim() -> void:
	var sh := Shader.new()
	sh.code = SHADE_SHADER
	_dim_mat = ShaderMaterial.new()
	_dim_mat.shader = sh
	_dim_mat.set_shader_parameter("dim", 1.0)
	_dim_mat.set_shader_parameter("core", _core_half)
	_dim_mat.set_shader_parameter("ramp", RAMP)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var face := _wid / 2.0 - WALL_T / 2.0
	var reach := _core_half + RAMP
	var x := -reach
	while x < reach - 1e-4:
		var x1 := minf(reach, x + SHADE_STEP)
		var mx := (x + x1) / 2.0
		# Only where the hall itself goes on (beyond the stretch it may turn or open): floor and ceiling; each wall only
		# where it is a wall.
		if _walkable_at(mx, 0.0):
			_quad(st, Vector3(x, 0.01, -face), Vector3(x1, 0.01, -face), Vector3(x1, 0.01, face), Vector3(x, 0.01, face))
			_quad(st, Vector3(x, LH - 0.12, -face), Vector3(x1, LH - 0.12, -face), Vector3(x1, LH - 0.12, face), Vector3(x, LH - 0.12, face))
			for side: float in [-1.0, 1.0]:
				if not _walkable_at(mx, side * (_wid / 2.0 + 0.6)):
					var z := side * (face - 0.006)
					_quad(st, Vector3(x, 0.0, z), Vector3(x1, 0.0, z), Vector3(x1, LH, z), Vector3(x, LH, z))
		x = x1
	_dim_box = MeshInstance3D.new()
	_dim_box.mesh = st.commit()
	_dim_box.material_override = _dim_mat
	_dim_box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_dim_box.visible = false
	add_child(_dim_box)

## What the shade leaves of the light at a point (the shader's sum, for tests): `along` m from the stretch's middle,
## `dist` m from the camera, the near light's `reach` (0: none).
static func shade_left(along: float, dist: float, core: float, reach: float) -> float:
	var ease := 1.0 - smoothstep(0.0, 1.0, clampf((absf(along) - core) / RAMP, 0.0, 1.0))
	var near := smoothstep(reach * 0.5, reach, dist) if reach > 0.0 else 1.0
	return 1.0 - (1.0 - DIM) * ease * near

static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	for v: Vector3 in [a, b, c, a, c, d]:
		st.add_vertex(v)

## Whether the floor plan is walkable at view-local (x along the stretch, z across); true without a plan (tests).
func _walkable_at(lx: float, lz: float) -> bool:
	if _plan == null:
		return true
	var w := _local_to_world(Vector3(lx, 0.0, lz))
	var cs := float(_plan.cell_size)
	return Floor.is_walkable(_plan, int(_rec.get("level", 0)), int(floor(w.x / cs)), int(floor(w.z / cs)))

## The notice's picture: the Clinic's pixel lettering on paper (as client/clinic_dress.gd draws its notices).
static func notice_image() -> Image:
	var w := 0
	for s: String in NOTICE_HEAD:
		w = maxi(w, PixelFont.width(s) * 3)
	for s: String in NOTICE_BODY:
		w = maxi(w, PixelFont.width(s) * 2)
	var pad := 6
	var h := NOTICE_HEAD.size() * 24 + 6 + NOTICE_BODY.size() * 17
	var img := Image.create(w + pad * 2, h + pad * 2, false, Image.FORMAT_RGBA8)
	img.fill(PAPER)
	var y := pad
	for s: String in NOTICE_HEAD:
		PixelFont.blit(img, s, Vector2i(pad + (w - PixelFont.width(s) * 3) / 2, y), INK, Vector2i(3, 3))
		y += 24
	y += 6
	for s: String in NOTICE_BODY:
		PixelFont.blit(img, s, Vector2i(pad, y), INK, Vector2i(2, 2))
		y += 17
	return img

## A laminated notice taped to the wall at each end of the stretch, at eye height, in the company's words.
func _build_notices() -> void:
	var img := notice_image()
	var tex := ImageTexture.create_from_image(img)
	# A sheet of the image's own shape, a large poster (about 0.39 x 0.56 m): a lettering row about 4.5 cm, the heading's 6.5 cm.
	var size := Vector2(NOTICE_SIZE.y * float(img.get_width()) / float(img.get_height()), NOTICE_SIZE.y)
	# Fresh paper on a grimy wall, a little yellowed.
	var paper := _mat(Color(1.0, 0.98, 0.9), 0.0, tex)
	var tape := _mat(Color(0.86, 0.84, 0.66))
	var i := 0
	for end: float in [-1.0, 1.0]:
		var side := -1.0 if i == 0 else 1.0
		var z := side * (_wid / 2.0 - WALL_T / 2.0 - 0.004)
		var at := Vector3(end * (_len / 2.0 - 0.7), NOTICE_Y, z)
		var holder := Node3D.new()
		holder.position = at
		# Facing into the hall, a little crooked.
		holder.rotation = Vector3(0, 0 if side < 0 else PI, 0.03 * end)
		add_child(holder)
		var sheet := MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = size
		sheet.mesh = q
		sheet.material_override = paper
		sheet.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(sheet)
		for c: Vector2 in [Vector2(-1, 1), Vector2(1, 1), Vector2(-1, -1), Vector2(1, -1)]:
			var t := MeshInstance3D.new()
			var tq := QuadMesh.new()
			tq.size = Vector2(0.06, 0.022)
			t.mesh = tq
			t.material_override = tape
			t.position = Vector3(c.x * (size.x / 2.0 - 0.01), c.y * (size.y / 2.0 - 0.01), 0.001)
			t.rotation = Vector3(0, 0, 0.6 if c.x * c.y > 0 else -0.6)
			holder.add_child(t)
		i += 1

# --- the level's lamps ---------------------------------------------------------------------------------------

## The level's lamps over the stretch become this view's (freed and hidden; stand-ins keep the level's lists
## the same length); the lamps just past each end are remembered, to sag with the circuit.
func _take_over_lamps(rec: Dictionary) -> void:
	if _level == null or not ("main_lights" in _level):
		return
	var yaw := float(rec.get("yaw", 0.0))
	var origin := Vector3(float(rec["x"]), float(rec["y"]), float(rec["z"]))
	var inv := Basis(Vector3.UP, yaw).inverse()
	var lights: Array = _level.get("main_lights")
	var energy: Array = _level.get("_base_energy")
	# The stand-ins live under a hidden node of the level's own, so they are freed with it and never light anything
	# (the level still sets their strength and visibility every frame).
	var holder := Node3D.new()
	holder.name = "FailingLightsStandIns"
	holder.visible = false
	_level.add_child(holder)
	for i in lights.size():
		var l: Light3D = lights[i]
		if l == null or not is_instance_valid(l) or l.get_parent() != _level:
			continue
		var p := inv * (l.position - origin)
		if p.y < 0.0 or p.y > LH + 0.2:
			continue
		if absf(p.z) <= _wid / 2.0 and absf(p.x) <= _len / 2.0:
			var stand_in := SpotLight3D.new()
			stand_in.light_energy = 0.0
			holder.add_child(stand_in)
			lights[i] = stand_in
			l.queue_free()
			_taken += 1
		elif absf(p.z) <= _wid / 2.0 + 0.5 and absf(p.x) <= _len / 2.0 + NEIGHBOUR_REACH:
			_neighbours.append([i, float(energy[i])])
	# The panels over the stretch: hidden; their table entries get a throwaway material.
	var panels: Array = _level.get("panels")
	for c in _level.get_children():
		var mi := c as MeshInstance3D
		if mi == null or not (mi.mesh is BoxMesh) or mi.material_override == null:
			continue
		var p := inv * (mi.position - origin)
		if p.y < LH - 0.3 or p.y > LH + 0.1 or absf(p.z) > _wid / 2.0 or absf(p.x) > _len / 2.0:
			continue
		for e: Dictionary in panels:
			if e.get("mat") == mi.material_override:
				e["mat"] = (mi.material_override as Material).duplicate()
				mi.visible = false
				break

## The panels past each end at `scale` of their own strength.
func _sag_neighbours(scale: float) -> void:
	shown_neighbour = scale
	if _neighbours.is_empty():
		return
	var energy: Array = _level.get("_base_energy")
	for e: Array in _neighbours:
		energy[int(e[0])] = float(e[1]) * scale

# --- each frame ----------------------------------------------------------------------------------------------

## The tubes' strength 0..1 and whether the screen draws the circuit dark, `secs` into `state` (static, so tests
## can call it with any moment). For a lit state `secs` is counted by the DRAWN time (see frame()).
static func look_at_time(state: StringName, secs: float, warn: float) -> Vector2:
	match state:
		&"warn":
			if secs >= warn - GUARD:
				return Vector2(0.0, 1.0)
			# The sag: three slow steps, with a shallow flutter that never reads as a flash.
			var step := clampi(int(secs / maxf(warn / 3.0, 0.01)), 0, 2)
			var flutter := 1.0 - FLUTTER * (1.0 if fmod(secs * FLUTTER_HZ, 1.0) < 0.5 else 0.0)
			return Vector2(SAG_STEPS[step] * flutter, 0.0)
		&"dark":
			return Vector2(0.0, 1.0)
		_:
			if secs < FLASHES[0].x:
				return Vector2(0.0, 1.0)
			if secs < CATCH:
				for f in FLASHES:
					if secs >= f.x and secs < f.y:
						return Vector2(FLASH_K, 0.0)
				return Vector2(0.0, 0.0)
			# Caught: a brief overshoot, then a steady burn with the odd small dip (from host time, the same on
			# every screen).
			var k := 1.0 + 0.25 * exp(-(secs - CATCH) / 0.2)
			if posmod(int(secs * 13.0) * 7919, 97) == 3:
				k *= 0.88
			return Vector2(k, 0.0)

## The tube ends' orange glow at `secs` into `state`: rising in steps through the warning, a slow pulse (0.7 s)
## while dark, black when lit.
static func end_glow_at(state: StringName, secs: float, warn: float) -> float:
	match state:
		&"warn":
			return END_STEPS[clampi(int(secs / maxf(warn / 3.0, 0.01)), 0, 2)]
		&"dark":
			return 0.6 * maxf(0.0, sin(fmod(secs, 0.7) / 0.7 * PI)) * (1.0 if fmod(secs, 1.4) < 0.7 else 0.4)
	return 0.0

## The host time of the snapshots this screen is drawing now (never ahead of `ht`).
func drawn_time(ht: float) -> float:
	if drawn_override >= 0.0:
		return minf(ht, drawn_override)
	var n: Node = get_parent()
	while n != null:
		var link: Variant = n.get("link")
		if link is Object and (link as Object).has_method("client"):
			var c: Variant = (link as Object).call("client")
			if c is Object:
				var rt: Variant = (c as Object).get("_rt")
				if rt is float:
					return minf(ht, float(rt))
			break
		n = n.get_parent()
	return ht - FALLBACK_BEHIND

func frame(rec: Dictionary, ht: float, _delta: float) -> void:
	_rec = rec
	var state := StringName(rec.get("state", &"lit"))
	var since := float(rec.get("since", ht))
	# Into the warning and the dark by the host clock (early dark); out of the dark only by what is being drawn
	# (late light): a lit state's moment is counted by the drawn snapshots' time.
	var drawn := drawn_time(ht)
	shown_drawn = drawn
	var secs := seconds_in(rec, ht)
	var look_secs := maxf(0.0, drawn - since) if state == &"lit" else secs
	var n: Array = rec.get("n", [])
	var warn := float(n[4]) if n.size() > 4 else 1.5
	var look := look_at_time(state, look_secs, warn)
	var dark := look.y > 0.5
	var k := look.x
	# The room's own light: the lift's blink or blackout takes this circuit with it.
	# (Only the lift's: this circuit's own dark region is the state above, and lit() would count it too.)
	var blink := not dark and base != null and bool(base.get("blink_dark"))
	if blink:
		k = 0.0
	var room: float = float(_level.get("_level")) if _level != null and ("_level" in _level) else 1.0
	k *= clampf(room, 0.0, 1.0)
	shown_k = k
	shown_dark = dark
	_light.light_energy = LIGHT_ENERGY * k
	_light.visible = k > 0.01
	for m in _tube_mats:
		m.set_shader_parameter("energy", 0.05 + 1.15 * k)
	var glow := end_glow_at(state, look_secs, warn) if not blink else 0.0
	for m in _end_mats:
		m.set_shader_parameter("color", END_GLOW if glow > 0.01 else Color(0.05, 0.04, 0.03))
		m.set_shader_parameter("energy", glow)
	for i in _strips.size():
		_strips[i].visible = dark and not blink
		_strip_mats[i].set_shader_parameter("energy", 0.9 if dark else 0.0)
	# The dark core drawn dark: on exactly while this screen draws the circuit dark.
	shown_dim = DIM if dark else 1.0
	_dim_box.visible = dark
	if dark:
		_dim_mat.set_shader_parameter("dim", DIM)
		_dim_mat.set_shader_parameter("cam", near_light_at())
		_dim_mat.set_shader_parameter("reach", near_light_reach())
	# The lamps just past each end: with the sag while it winds down, NEIGHBOUR_SAG while dark.
	var nb := 1.0
	if dark:
		nb = NEIGHBOUR_SAG
	elif state == &"warn":
		nb = lerpf(NEIGHBOUR_SAG, 1.0, SAG_STEPS[clampi(int(secs / maxf(warn / 3.0, 0.01)), 0, 2)])
	_sag_neighbours(nb)
	_sound(state, secs, look_secs, warn, blink)

func _once(key: String, stream: AudioStream, from: float, trim := 0.0) -> void:
	if _played.has(key):
		return
	_played[key] = true
	if stream != null and from >= 0.0 and from < stream.get_length():
		play_cue(stream, _local_to_world(Vector3(0, LH - 0.3, 0)), &"effect", trim, from)

func _stop(p: AudioStreamPlayer3D) -> void:
	if p != null and is_instance_valid(p):
		p.queue_free()

## `secs`: into the state by the host clock; `look_secs`: by the drawn time (the strike follows the light).
func _sound(state: StringName, secs: float, look_secs: float, warn: float, blink: bool) -> void:
	var since := float(_rec.get("since", 0.0))
	var tag := "%s@%.3f" % [state, since]
	var at := _local_to_world(Vector3(0, LH - 0.3, 0))
	match state:
		&"lit":
			if look_secs >= FLASHES[0].x:
				_stop(_dark_loop)
				_dark_loop = null
				_once(tag + "strike", load(SND + "strike.wav"), look_secs - FLASHES[0].x)
			# The hum comes back as the tubes catch; the lift's blink silences it with the light.
			var want := not blink and look_secs >= CATCH + 0.3
			if want and _buzz == null:
				_buzz = play_loop(_buzz_stream, at, &"room", 0.0, look_secs)
			elif not want and _buzz != null:
				_stop(_buzz)
				_buzz = null
		&"warn":
			_stop(_buzz)
			_buzz = null
			# The warning always plays whole, also in a blink (the heard-first rule). wind.wav is 2 s and ends with the
			# warning: started part way in for a shorter one.
			var start := secs - (warn - 2.0)
			if start >= 0.0:
				_once(tag + "wind", load(SND + "wind.wav"), start)
				_once(tag + "flicker", load("res://assets/sfx/clinic/flicker.ogg"), secs, -3.0)
		&"dark":
			_stop(_buzz)
			_buzz = null
			_once(tag + "out", load(SND + "out.wav"), secs)
			if _dark_loop == null and not blink:
				_dark_loop = play_loop(_dark_stream, at, &"ambience", 0.0, secs)

func changed(rec: Dictionary, _before: Dictionary, _ht: float) -> void:
	_rec = rec
	# Old one-shot keys are dropped as each new state starts.
	if _played.size() > 12:
		_played.clear()
