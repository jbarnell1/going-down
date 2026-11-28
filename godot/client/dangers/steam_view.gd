# Dangers, the Reactor's steam (DG6): one jet on screen. The rules are sim/dangers/steam.gd; this only draws and
# plays what the record says, from its state and `since` (host time), never from this screen's own clock.
#
# The hall's jet: a steel line crossing the hall under the ceiling at the steam main's height, a split seam along
# its underside, a valve with a handwheel and two round pressure lamps (one facing each way down the hall), a
# stencilled plate under it, a scald-dark stain and drip marks on the floor beneath. The crawl's jet: a short bare
# section of line along the crawl's wall under the soffit, split along its side, a small lamp on the soffit, and a
# stencil on the crawl's hatch.
# The beat: at rest the lamps are dark glass; in the build the line knocks two or three times, the hiss rises and the
# lamps blink amber; in the jet the lamps burn red and steam bursts from the seam: a bright narrow root opening
# downward from the split (above head height) into two curtains over the whole depth that scalds, down to chest height
# in the hall (clear air under it to crouch through; floor to soffit in the crawl), roaring.
# The jet is drawn from the schedule: once a build has run its length by host time the steam shows, before the
# snapshot that says "jet" arrives, so steam.grace only has to cover the way up.
# The curtains are kept thin (SHEET_ALPHA, PUFF_ALPHA; tests/test_danger_steam.gd bounds what they hide; the root and
# the seam's puffs stay above 1.8 m): a body behind always shows through. The tint follows the power: grey-white lit,
# amber in the emergency light, reddened by the lamp while a jet runs there. A scalded player bursts a puff of steam.
# Sounds are made here from arithmetic (assets/sfx/dangers/steam/SOURCES.md lists them): the knock, the rising hiss,
# the roar (a loop), the purge's groan under it, the cry of whoever walks into it, and a ring in your own ears.
# No collision, no light: the lamps are glow materials and never dim with the room (in the dark they are the warning).
extends "res://client/dangers/kind_view.gd"

const Steam = preload("res://sim/dangers/steam.gd")
const Level = preload("res://client/level.gd")

const RATE := 22050
## The steam main's height (client/station_dress.gd RUNS "steam") and its radius.
const PIPE_Y := 2.36
const PIPE_R := 0.11
## The hall's sheet: from just under the seam down to waist height, over a creeping player's eyes (1.13 m), so a
## creeper sees under it.
const SHEET_TOP := 2.24
const SHEET_LOW := 1.25
## The drawn steam covers exactly what scalds (sim/dangers/steam.gd HAZARD_HALF either side of the line): each sheet
## layer this far in from the hazard's edge, the puffs out to it, the stain its full depth.
const SHEET_IN := 0.1
## The most the scald stain darkens the floor (the concrete's own colour, darker).
const STAIN_MOST := 0.5
## The crawl's soffit (client/station_view.gd _crawl_trays) and its section of line.
const CRAWL_TOP := 1.2
const CRAWL_PIPE_Y := 1.08
const CRAWL_PIPE_X := 0.5
## What the drawn steam may hide: each of the two sheet layers at most SHEET_ALPHA, each puff at most PUFF_ALPHA.
const SHEET_ALPHA := 0.16
const PUFF_ALPHA := 0.055
const PUFF_SIZE := 0.75
const PUFFS_PER_M := 14
const PUFF_LIFE := 0.6
## The seam's own puffs: small, quick, dense, only in the top 0.4 m under the split (above head height in the hall).
const SEAM_SIZE := 0.28
const SEAM_PER_M := 26
const SEAM_LIFE := 0.22
const SEAM_ALPHA := 0.27
const SEAM_V := Vector2(0.9, 1.3)
## In the crawl the seam's puffs are in the way, so they stay faint (and most_hidden() counts them there).
const SEAM_ALPHA_CRAWL := 0.05
## The root: a narrow bright V from the split down to ROOT_LOW, opening into the curtains (hall only).
const ROOT_ALPHA := 0.4
const ROOT_TOP_Z := 0.06
const ROOT_LOW := 1.86
const ROOT_LOW_Z := 0.35
## Nothing of the root or the seam's puffs comes lower than this in the hall (a standing head is under it).
const HIGH_ONLY := 1.8
## Knocks in the build, as fractions of it.
const KNOCKS: Array[float] = [0.0, 0.38, 0.7]
const TINT_LIT := Color(0.86, 0.88, 0.9)
const TINT_DARK := Color(1.0, 0.72, 0.42)
const LAMP_AMBER := Color(1.0, 0.5, 0.05)
const AMBER_ENERGY := 2.2
## The curtains in the cut while a jet runs: the amber light reddened by the lamp, at this brightness.
const CUT_JET_RED := 0.35
const CUT_JET_BRIGHT := 0.6
const LAMP_RED := Color(1.0, 0.12, 0.06)
const LAMP_OFF := Color(0.16, 0.1, 0.08)
## The pressure lamp's lens (big enough to read down the long hall) and its halo.
const LAMP_R := 0.16
const HALO := 6.0
## The mix (godot/assets/sfx/MIX.md, the base's play_cue/play_loop): every sound plays at Sfx.BASE_DB plus a trim that
## only lowers it, and its loudness is set in the stream: each is scaled to its loudness (the base's measure(), dBFS)
## inside its category's band (kind_view.gd BANDS), peak under -1 dBFS (tests/test_danger_steam.gd measures each).
## Stream -> [category, loudness in the stream, trim at play].
const MIX := {
	"knock": [&"effect", -22.0, 0.0], "build": [&"effect", -23.5, -4.0], "jet": [&"effect", -21.5, 0.0],
	"groan": [&"effect", -22.5, -2.0], "cry": [&"player", -25.5, -3.0], "ring": [&"player", -25.0, -6.0],
}

static var _streams := {}

var which := Steam.WHICH_HALL
var width := 2.0
var lamps: Array[ShaderMaterial] = []
var sheets: Array[MeshInstance3D] = []
var roots: Array[MeshInstance3D] = []
## How many scald bursts this view has made (tests read it).
var bursts := 0
var halos: Array[MeshInstance3D] = []
var stain: MeshInstance3D
var seam: CPUParticles3D
var sheet_mat: ShaderMaterial
var puffs: CPUParticles3D
var puff_mat: StandardMaterial3D
## The roar's emitters (two across the hall) while it plays, and the build's hiss.
var roar: Array[AudioStreamPlayer3D] = []
var hiss: AudioStreamPlayer3D
## Where the sounds come from, in this node's frame: the valve, and the roar's emitters.
var hiss_at := Vector3.ZERO
var roar_at: Array[Vector3] = []
var knocked := -1
var _state := &"rest"
var _since := 0.0
var _len := 0.0
var _purge := false
var _power := 0
## Seconds since the steam last stopped, for the roar's tail (screen time; sound only).
var _tail := -1.0
## The steam's colour now (a scald's burst takes it).
var _tint := TINT_LIT

# --- building -------------------------------------------------------------------------------------------------

func build(rec: Dictionary, ctx: Dictionary) -> void:
	var n: Array = rec["n"]
	which = int(n[Steam.N_WHICH])
	width = float(n[Steam.N_X1]) - float(n[Steam.N_X0])
	name = "Steam%d" % int(rec.get("id", 0))
	_make_streams()
	if which == Steam.WHICH_HALL:
		_hall_line(ctx)
	else:
		_crawl_line(ctx)
	_steam()
	hiss_at = Vector3(0, PIPE_Y if which == Steam.WHICH_HALL else CRAWL_PIPE_Y, 0)
	for x: float in ([-width * 0.25, width * 0.25] if which == Steam.WHICH_HALL else [0.0]):
		roar_at.append(Vector3(x, 1.6 if which == Steam.WHICH_HALL else 0.6, 0))
	_take(rec)
	_apply(0.0, true)

## The dress's own maps (client/station_dress.gd: steel plate, painted iron), one material per map and tint.
const STEEL_MAP := "res://assets/reactor/steel_plate.webp"
const PAINT_MAP := "res://assets/arboretum/painted_iron.webp"
var _mats := {}

func _steel() -> String:
	return STEEL_MAP

func _paint() -> String:
	return PAINT_MAP

func _mat(map: String, col: Color) -> ShaderMaterial:
	var key := "%s|%s" % [map, col.to_html()]
	if not _mats.has(key):
		_mats[key] = Level.prop_material(col, load(map), true, 0.0, 0.0, true)
	return _mats[key]

func _mesh(mesh: Mesh, xf: Transform3D, mat: Variant, col := Color(0.9, 0.9, 0.88)) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.transform = xf
	mi.material_override = _mat(mat, col) if mat is String else mat
	# No shadow: under a ceiling batten the line would throw a hard black bar a metre wide across the floor, which
	# reads as the scalding ground and is not where it is.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi

static func _cyl(r: float, h: float, seg := 14) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = r
	c.bottom_radius = r
	c.height = h
	c.radial_segments = seg
	c.rings = 1
	return c

static func _box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b

## A pipe along local x (or z) through `at`.
func _pipe(at: Vector3, length: float, r: float, along_x: bool, mat: Variant) -> void:
	var basis := Basis(Vector3(0, 0, 1), PI * 0.5) if along_x else Basis(Vector3(1, 0, 0), PI * 0.5)
	_mesh(_cyl(r, length), Transform3D(basis, at), mat)

## A round pressure lamp facing +z or -z: a domed glass lens (a glow material) in a steel bezel.
func _lamp(at: Vector3, facing: Vector3, r: float) -> void:
	var m := Level.glow_material(LAMP_OFF, 1.0)
	lamps.append(m)
	var basis := Basis(Vector3.RIGHT, PI * 0.5 * signf(facing.z))
	var lens := SphereMesh.new()
	lens.radius = r
	lens.height = r * 2.0
	lens.radial_segments = 12
	lens.rings = 6
	_mesh(lens, Transform3D(basis.scaled_local(Vector3(1.0, 0.55, 1.0)), at), m)
	var ring := TorusMesh.new()
	ring.inner_radius = r * 0.95
	ring.outer_radius = r * 1.3
	ring.rings = 12
	ring.ring_segments = 6
	_mesh(ring, Transform3D(basis, at - facing.normalized() * 0.01), _steel(), Color(0.55, 0.55, 0.52))
	# A soft halo round it (added light, a billboard, no light of its own), lit with the lamp.
	var hm := StandardMaterial3D.new()
	hm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	hm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	hm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	hm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	hm.albedo_texture = _soft()
	hm.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	hm.albedo_color = Color(0, 0, 0, 0)
	var hq := QuadMesh.new()
	hq.size = Vector2(r * HALO, r * HALO)
	var h := _mesh(hq, Transform3D(Basis(), at + facing.normalized() * 0.03), hm)
	h.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	halos.append(h)

static var _soft_tex: GradientTexture2D

## A soft round spot (puffs, halos).
static func _soft() -> GradientTexture2D:
	if _soft_tex == null:
		var grad := Gradient.new()
		grad.set_color(0, Color(1, 1, 1, 1))
		grad.set_color(1, Color(1, 1, 1, 0))
		_soft_tex = GradientTexture2D.new()
		_soft_tex.gradient = grad
		_soft_tex.fill = GradientTexture2D.FILL_RADIAL
		_soft_tex.fill_from = Vector2(0.5, 0.5)
		_soft_tex.fill_to = Vector2(0.5, 0.0)
		_soft_tex.width = 64
		_soft_tex.height = 64
	return _soft_tex

## The hall's wall-to-wall span in this node's frame (from the station's anchors), else the band's own.
func _hall_span(ctx: Dictionary) -> Vector2:
	var anchors := _anchors(ctx)
	if anchors.has("hall") and anchors["hall"] is Rect2:
		var h: Rect2 = anchors["hall"]
		var gx := global_position.x if is_inside_tree() else position.x
		return Vector2(h.position.x - gx, h.end.x - gx)
	return Vector2(-width * 0.5, width * 0.5)

static func _anchors(ctx: Dictionary) -> Dictionary:
	var lv: Variant = ctx.get("level")
	if lv is Node and (lv as Node).has_meta(&"station"):
		var station: Variant = (lv as Node).get_meta(&"station")
		var a: Variant = station.get("anchors") if station is Object else null
		if a is Dictionary:
			return a
	return {}

func _hall_line(ctx: Dictionary) -> void:
	var steel := _steel()
	var y := PIPE_Y
	var span := _hall_span(ctx)
	var lo := span.x + 0.05
	var hi := span.y - 0.05
	# The line itself, wall to wall, with a collar where it tees into each wall's run.
	_pipe(Vector3((lo + hi) * 0.5, y, 0), hi - lo, PIPE_R, true, steel)
	for e: float in [lo, hi]:
		var inward := 1.0 if e == lo else -1.0
		_pipe(Vector3(e + inward * 0.12, y, 0), 0.07, PIPE_R + 0.05, true, steel)
		_pipe(Vector3(e + inward * 0.55, y, 0), 0.05, PIPE_R + 0.035, true, steel)
		# A hanger up to the ceiling.
		_mesh(_box(Vector3(0.03, 0.62, 0.03)), Transform3D(Basis(), Vector3(e + inward * 1.4, y + 0.42, 0)), steel, Color(0.5, 0.5, 0.48))
		_mesh(_box(Vector3(0.05, 0.03, 0.3)), Transform3D(Basis(), Vector3(e + inward * 1.4, y - PIPE_R - 0.015, 0)), steel, Color(0.5, 0.5, 0.48))
	# The split seam along its underside: dark, with rust either side.
	_mesh(_box(Vector3(width - 1.6, 0.025, 0.035)), Transform3D(Basis(), Vector3(0, y - PIPE_R + 0.004, 0)), steel, Color(0.07, 0.06, 0.05))
	for sz: float in [-1.0, 1.0]:
		_mesh(_box(Vector3(width - 1.9, 0.02, 0.04)), Transform3D(Basis(), Vector3(0, y - PIPE_R + 0.018, sz * 0.04)), steel, Color(0.62, 0.34, 0.2))
	# The valve: a flanged body, its stem and a red handwheel, the two lamps facing down the hall both ways.
	_pipe(Vector3(0, y, 0), 0.36, PIPE_R + 0.06, true, steel)
	for sx: float in [-0.2, 0.2]:
		_pipe(Vector3(sx, y, 0), 0.05, PIPE_R + 0.1, true, steel)
	_mesh(_cyl(0.025, 0.28), Transform3D(Basis(), Vector3(0, y + 0.28, 0)), steel, Color(0.6, 0.6, 0.58))
	var wheel := TorusMesh.new()
	wheel.inner_radius = 0.13
	wheel.outer_radius = 0.16
	wheel.rings = 16
	wheel.ring_segments = 6
	_mesh(wheel, Transform3D(Basis(), Vector3(0, y + 0.42, 0)), _paint(), Color(0.8, 0.2, 0.1))
	for sz: float in [-1.0, 1.0]:
		var box_at := Vector3(0.0, y + 0.02, sz * (PIPE_R + 0.09))
		_mesh(_box(Vector3(0.4, 0.4, 0.08)), Transform3D(Basis(), box_at), steel, Color(0.35, 0.36, 0.34))
		_lamp(box_at + Vector3(0, 0, sz * 0.045), Vector3(0, 0, sz), LAMP_R)
		# The stencilled plate hanging under the line beside the valve, facing down the hall.
		var plate_at := Vector3(sz * -1.15, y - PIPE_R - 0.17, sz * 0.02)
		_mesh(_box(Vector3(1.5, 0.22, 0.012)), Transform3D(Basis(), plate_at), _paint(), Color(0.86, 0.78, 0.36))
		for hx: float in [-0.6, 0.6]:
			_mesh(_box(Vector3(0.012, 0.1, 0.012)), Transform3D(Basis(), plate_at + Vector3(hx, 0.15, 0)), steel, Color(0.4, 0.4, 0.4))
		_stencil("SCALDING IS NOT COVERED\nBY YOUR CONTRACT.", plate_at + Vector3(0, 0, sz * 0.008), Vector3(0, 0, sz), 0.0017, Color(0.1, 0.09, 0.07))
	# On the floor: the scald stain and the drip marks.
	_stain(Vector3(0, 0.012, 0), Vector2(width - 0.4, stain_depth()), 7)
	_drips(width)

func _crawl_line(ctx: Dictionary) -> void:
	var steel := _steel()
	var x := CRAWL_PIPE_X
	var y := CRAWL_PIPE_Y
	_pipe(Vector3(x, y, 0), 2.0, 0.075, false, steel)
	for sz: float in [-0.95, 0.95]:
		_pipe(Vector3(x, y, sz), 0.05, 0.11, false, steel)
	# Split along its inner side, toward the passage.
	_mesh(_box(Vector3(0.02, 0.03, 1.2)), Transform3D(Basis(), Vector3(x - 0.07, y, 0)), steel, Color(0.07, 0.06, 0.05))
	_mesh(_box(Vector3(0.02, 0.05, 1.3)), Transform3D(Basis(), Vector3(x - 0.064, y - 0.03, 0)), steel, Color(0.62, 0.34, 0.2))
	# The small lamp on the soffit, facing down the passage both ways.
	_mesh(_box(Vector3(0.1, 0.06, 0.12)), Transform3D(Basis(), Vector3(x - 0.1, CRAWL_TOP - 0.03, 0)), steel, Color(0.35, 0.36, 0.34))
	_lamp(Vector3(x - 0.1, CRAWL_TOP - 0.03, 0.065), Vector3(0, 0, 1), 0.03)
	_lamp(Vector3(x - 0.1, CRAWL_TOP - 0.03, -0.065), Vector3(0, 0, -1), 0.03)
	_stain(Vector3(0.0, 0.012, 0), Vector2(1.8, stain_depth()), 11)
	# The stencil on the crawl's hatch (the gallery side), from the station's anchors.
	var anchors := _anchors(ctx)
	if anchors.has("crawl_mouths") and not (anchors["crawl_mouths"] as Array).is_empty():
		var m: Array = (anchors["crawl_mouths"] as Array)[0]
		var outside := Vector3((float(m[0]) + 0.5) * 2.0, 0, (float(m[1]) + 0.5) * 2.0)
		var inside := Vector3((float(m[2]) + 0.5) * 2.0, 0, (float(m[3]) + 0.5) * 2.0)
		var face := (outside - inside).normalized()
		var at := (outside + inside) * 0.5 + face * 0.08 + Vector3(0, 1.42, 0)
		_stencil("MIND THE LINES.", to_local_flat(at), face, 0.0024, Color(0.93, 0.76, 0.18))

## A world point to this node's frame (the view sits at the record, yaw 0).
func to_local_flat(world: Vector3) -> Vector3:
	var g := global_position if is_inside_tree() else position
	return world - Vector3(g.x, 0.0, g.z)

func _stencil(text: String, at: Vector3, facing: Vector3, px: float, col: Color) -> void:
	var label := Label3D.new()
	label.text = text
	label.font_size = 64
	label.pixel_size = px
	label.modulate = col
	label.outline_size = 0
	label.shaded = true
	label.double_sided = false
	label.alpha_cut = Label3D.ALPHA_CUT_DISCARD
	var nv := facing.normalized()
	label.transform = Transform3D(Basis(Vector3.UP.cross(nv).normalized(), Vector3.UP, nv), at)
	add_child(label)

const STAIN_SHADER := """
shader_type spatial;
render_mode blend_mix, unshaded, depth_draw_never, cull_disabled, shadows_disabled;
uniform sampler2D tex : filter_linear;
uniform vec3 damp = vec3(0.08, 0.07, 0.06);
uniform float most = 0.5;
void fragment() {
	// Drawn with the transparent things (ALPHA), so it only darkens what is under it, by at most `most`.
	ALBEDO = damp;
	ALPHA = texture(tex, UV).r * most;
}
"""

## The stain's depth: where a player's own point is scalded (the hazard plus the body's radius either side), since a
## floor mark is read from where you stand, not from your body's edge. Off the patch during a jet, you are never hit.
static func stain_depth() -> float:
	return 2.0 * (Steam.HAZARD_HALF + Steam.RADIUS)

## Damp scalded concrete under the jet, its image (r = how much it darkens, times STAIN_MOST): dark almost to its edge
## across its depth (a steep, ragged fall-off in the last few centimetres), fading at the ends, a few drip spots; made
## from a few lines of arithmetic seeded by `salt` (looks only). v runs across the depth, -1..1 = the patch's edges.
static func stain_image(salt: int) -> Image:
	var w := 256
	var h := 192
	var img := Image.create(w, h, false, Image.FORMAT_L8)
	var noise := FastNoiseLite.new()
	noise.seed = salt
	noise.frequency = 0.022
	noise.fractal_octaves = 4
	# The outline: scallops a few centimetres deep, finer at the edge, different on each side.
	var edge := FastNoiseLite.new()
	edge.seed = salt + 31
	edge.frequency = 0.09
	edge.fractal_octaves = 3
	var spots: Array[Vector3] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = salt * 977
	for i in 14:
		spots.append(Vector3(rng.randf_range(0.08, 0.92) * w, rng.randf_range(0.3, 0.7) * h, rng.randf_range(2.0, 6.0)))
	# A few darker blotches inside (where it pools), and drip runs reaching the edge.
	var blots: Array[Vector3] = []
	for i in 7:
		blots.append(Vector3(rng.randf_range(0.05, 0.95) * w, rng.randf_range(0.15, 0.85) * h, rng.randf_range(10.0, 26.0)))
	for y in h:
		for x in w:
			var u := (float(x) / float(w - 1) - 0.5) * 2.0
			var v := (float(y) / float(h - 1) - 0.5) * 2.0
			var n := noise.get_noise_2d(x, y)
			# Which side of the line: each side's edge wanders on its own.
			var side := 0.0 if v < 0.0 else 400.0
			var scallop := edge.get_noise_2d(x + side, 0.0) * 0.07 + edge.get_noise_2d(x * 3.0 + side, 9.0) * 0.025
			var across := 1.0 - smoothstep(0.925, 0.985, absf(v) + scallop + n * 0.02)
			var along := 1.0 - smoothstep(0.86, 1.0, absf(u) + n * 0.06)
			# Wetter and drier stretches along the length, and the fine grain of the concrete.
			var wet := 0.45 + 0.55 * clampf(noise.get_noise_2d(x * 0.35, 77.0) * 1.6 + 0.5, 0.0, 1.0)
			var a := across * along * wet * (0.8 + 0.2 * noise.get_noise_2d(x * 4.0 + 50.0, y * 4.0))
			for bl in blots:
				var db := Vector2(x - bl.x, (y - bl.y) * 1.6).length()
				a = maxf(a, across * along * clampf(1.15 - db / bl.z, 0.0, 1.0))
			for sp in spots:
				var d := Vector2(x - sp.x, y - sp.y).length()
				a = maxf(a, clampf(1.0 - d / sp.z, 0.0, 1.0) * 0.9)
			img.set_pixel(x, y, Color(a, a, a))
	return img

func _stain(at: Vector3, size: Vector2, salt: int) -> void:
	var img := stain_image(salt)
	var mat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = STAIN_SHADER
	mat.shader = sh
	mat.set_shader_parameter("tex", ImageTexture.create_from_image(img))
	mat.set_shader_parameter("most", STAIN_MOST)
	var q := QuadMesh.new()
	q.size = size
	stain = _mesh(q, Transform3D(Basis(Vector3(1, 0, 0), -PI * 0.5), at), mat)
	stain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func _drips(w: float) -> void:
	var steel := _steel()
	for i in 9:
		var x := (float(i) / 8.0 - 0.5) * (w - 2.2) + sin(float(i) * 7.3) * 0.25
		var z := sin(float(i) * 3.1) * 0.08
		_mesh(_box(Vector3(0.02, 0.05 + 0.04 * absf(sin(float(i) * 1.7)), 0.02)), Transform3D(Basis(), Vector3(x, PIPE_Y - PIPE_R - 0.03, z)), steel, Color(0.5, 0.36, 0.26))

# --- the steam ---------------------------------------------------------------------------------------------------

const SHEET_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;
uniform vec4 tint : source_color = vec4(1.0);
uniform float strength = 0.0;
uniform float most = 0.16;
uniform float seed = 0.0;
uniform float top_fade = 0.12;
uniform float low_fade = 0.9;
uniform float rag = 0.0;
// The record's host time (set each frame), so the steam moves alike on every screen.
uniform float clock = 0.0;
// 0 for the curtains; 1 for the root: denser clumps where the seam splits, thinner stretches between, that drift.
uniform float clumps = 0.0;
float h(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float n2(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p); f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h(i), h(i + vec2(1.0, 0.0)), f.x), mix(h(i + vec2(0.0, 1.0)), h(i + vec2(1.0, 1.0)), f.x), f.y);
}
void fragment() {
	vec2 p = vec2(UV.x * 9.0 + seed, UV.y * 3.0 - clock * 4.5);
	float c = n2(p) * 0.6 + n2(p * 2.3 + 17.0) * 0.4;
	// A ragged lower edge: the bottom fade moves with a slow noise across the width.
	float r = (n2(vec2(UV.x * 14.0 + seed * 3.0, clock * 0.8)) - 0.5) * rag;
	// The root's clumps: a slow noise along the seam picks the split points; between them the root thins.
	float k = n2(vec2(UV.x * 7.0 + seed * 2.0 + clock * 0.35, 3.0)) * 0.7 + n2(vec2(UV.x * 19.0 + seed, clock * 0.9)) * 0.3;
	float clump = mix(1.0, 0.18 + 0.82 * smoothstep(0.38, 0.72, k), clumps);
	// A clump also pours lower than the thin stretches: its lower edge follows the clump.
	r += clumps * (0.5 - k) * 0.5;
	float edge = smoothstep(0.0, top_fade, UV.y) * smoothstep(1.0, low_fade, UV.y + r) * smoothstep(0.0, 0.14, UV.x) * smoothstep(1.0, 0.86, UV.x);
	ALBEDO = tint.rgb;
	ALPHA = clamp(strength * edge * clump * (0.45 + 0.55 * c), 0.0, 1.0) * most;
}
"""

func _steam() -> void:
	var sh := Shader.new()
	sh.code = SHEET_SHADER
	sheet_mat = ShaderMaterial.new()
	sheet_mat.shader = sh
	sheet_mat.set_shader_parameter("most", SHEET_ALPHA)
	var hall := which == Steam.WHICH_HALL
	var top := SHEET_TOP if hall else CRAWL_TOP - 0.04
	var low := SHEET_LOW if hall else 0.02
	var w := width - 0.2 if hall else 1.9
	for layer in 2:
		var q := QuadMesh.new()
		q.size = Vector2(w, top - low)
		var dz := (Steam.HAZARD_HALF - SHEET_IN) * (-1.0 if layer == 0 else 1.0)
		var mi := MeshInstance3D.new()
		mi.mesh = q
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.transform = Transform3D(Basis(), Vector3(0, (top + low) * 0.5, dz))
		var m := sheet_mat.duplicate() as ShaderMaterial
		m.set_shader_parameter("seed", float(layer) * 5.7)
		m.set_shader_parameter("rag", 0.12 if hall else 0.0)
		mi.material_override = m
		mi.visible = false
		add_child(mi)
		sheets.append(mi)
	# The root (hall): two bright narrow planes from the split down and out into the curtains, above head height.
	if hall:
		var slope := Vector2(ROOT_LOW_Z - ROOT_TOP_Z, (PIPE_Y - PIPE_R - 0.02) - ROOT_LOW)
		var length := slope.length()
		for side: float in [-1.0, 1.0]:
			var q := QuadMesh.new()
			q.size = Vector2(w, length)
			var mi := MeshInstance3D.new()
			mi.mesh = q
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			# Local y runs up the slope: from (z = side * ROOT_LOW_Z, ROOT_LOW) to (z = side * ROOT_TOP_Z, the seam).
			var up := Vector3(0, slope.y, -side * slope.x).normalized()
			var basis := Basis(Vector3.RIGHT, up, Vector3.RIGHT.cross(up))
			var mid := Vector3(0, ROOT_LOW + slope.y * 0.5, side * (ROOT_TOP_Z + slope.x * 0.5))
			mi.transform = Transform3D(basis, mid)
			var m := sheet_mat.duplicate() as ShaderMaterial
			m.set_shader_parameter("most", ROOT_ALPHA)
			m.set_shader_parameter("seed", 11.0 + side)
			m.set_shader_parameter("top_fade", 0.03)
			m.set_shader_parameter("low_fade", 0.45)
			m.set_shader_parameter("rag", 0.3)
			m.set_shader_parameter("clumps", 1.0)
			mi.material_override = m
			mi.visible = false
			add_child(mi)
			roots.append(mi)
	# The puffs: soft quads pouring from the seam and rolling out where the sheet ends.
	var soft := _soft()
	puff_mat = StandardMaterial3D.new()
	puff_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	puff_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	puff_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	puff_mat.vertex_color_use_as_albedo = true
	puff_mat.albedo_texture = soft
	puff_mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	puff_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	puffs = CPUParticles3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(PUFF_SIZE, PUFF_SIZE)
	quad.material = puff_mat
	puffs.mesh = quad
	puffs.amount = int(maxf(1.0, w * PUFFS_PER_M))
	puffs.lifetime = PUFF_LIFE
	puffs.emitting = false
	puffs.local_coords = true
	puffs.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	if hall:
		puffs.position = Vector3(0, PIPE_Y - PIPE_R - 0.04, 0)
		puffs.emission_box_extents = Vector3(w * 0.5 - 0.2, 0.02, Steam.HAZARD_HALF - SHEET_IN)
		puffs.direction = Vector3(0, -1, 0)
		puffs.initial_velocity_min = 2.2
		puffs.initial_velocity_max = 3.2
		puffs.damping_min = 2.6
		puffs.damping_max = 3.6
		puffs.gravity = Vector3(0, -0.4, 0)
	else:
		puffs.position = Vector3(CRAWL_PIPE_X - 0.08, CRAWL_PIPE_Y, 0)
		puffs.emission_box_extents = Vector3(0.02, 0.03, Steam.HAZARD_HALF - SHEET_IN)
		puffs.direction = Vector3(-1, -0.25, 0)
		puffs.initial_velocity_min = 2.4
		puffs.initial_velocity_max = 3.4
		puffs.damping_min = 2.0
		puffs.damping_max = 3.0
		puffs.gravity = Vector3(0, 0.3, 0)
	puffs.spread = 14.0
	puffs.angular_velocity_min = -90.0
	puffs.angular_velocity_max = 90.0
	puffs.scale_amount_min = 0.45
	puffs.scale_amount_max = 1.0
	var grow := Curve.new()
	grow.add_point(Vector2(0, 0.35))
	grow.add_point(Vector2(1, 1.0))
	puffs.scale_amount_curve = grow
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, 0))
	ramp.add_point(0.2, Color(1, 1, 1, PUFF_ALPHA))
	ramp.set_color(ramp.get_point_count() - 1, Color(1, 1, 1, 0))
	puffs.color_ramp = ramp
	puffs.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(puffs)
	# Denser at the seam: small quick puffs in the top SEAM_DEPTH under the split, so a jet plainly leaves the pipe
	# (above head height: they hide nothing of a body behind).
	seam = puffs.duplicate() as CPUParticles3D
	var sq := QuadMesh.new()
	sq.size = Vector2(SEAM_SIZE, SEAM_SIZE)
	sq.material = puff_mat
	seam.mesh = sq
	seam.amount = int(maxf(1.0, w * SEAM_PER_M))
	seam.lifetime = SEAM_LIFE
	seam.initial_velocity_min = SEAM_V.x
	seam.initial_velocity_max = SEAM_V.y
	seam.emission_box_extents = Vector3(puffs.emission_box_extents.x, 0.02, 0.06) if hall else Vector3(0.02, 0.03, 0.5)
	var sramp := Gradient.new()
	sramp.set_color(0, Color(1, 1, 1, 0))
	sramp.add_point(0.15, Color(1, 1, 1, SEAM_ALPHA if hall else SEAM_ALPHA_CRAWL))
	sramp.set_color(sramp.get_point_count() - 1, Color(1, 1, 1, 0))
	seam.color_ramp = sramp
	seam.emitting = false
	add_child(seam)

## The most a ray through the middle of the live sheet is hidden (0 clear, 1 opaque), from what is built: both
## sheet layers at their most, and the puffs' expected overlap along the ray at their most. Tests read it.
func most_hidden() -> float:
	var clear := 1.0
	for mi in sheets:
		clear *= 1.0 - float((mi.material_override as ShaderMaterial).get_shader_parameter("most"))
	var w := width - 0.2 if which == Steam.WHICH_HALL else 1.9
	var h := (SHEET_TOP - SHEET_LOW) if which == Steam.WHICH_HALL else CRAWL_TOP
	var size := PUFF_SIZE * float(puffs.scale_amount_max)
	var overlap := float(puffs.amount) * size * size / (w * h)
	clear *= pow(1.0 - PUFF_ALPHA, overlap)
	if which != Steam.WHICH_HALL:
		# In the crawl the seam's puffs are in the way too (in the hall they stay above 1.8 m: lowest_high()).
		var ss := SEAM_SIZE * float(seam.scale_amount_max)
		clear *= pow(1.0 - SEAM_ALPHA_CRAWL, float(seam.amount) * ss * ss / (w * h))
	return 1.0 - clear

## The lowest point the hall's root or seam puffs reach (m above the floor), from what is built: the root planes'
## corners, and the seam puffs' fall in their life (velocity less damping, plus gravity) less half their size.
func lowest_high() -> float:
	var low := INF
	for mi in roots:
		var aabb := mi.get_aabb()
		for i in 8:
			low = minf(low, (mi.transform * aabb.get_endpoint(i)).y)
	var life := seam.lifetime
	var fall := seam.initial_velocity_max * life - 0.5 * seam.damping_min * life * life - 0.5 * seam.gravity.y * life * life
	var half := SEAM_SIZE * float(seam.scale_amount_max) * 0.5
	low = minf(low, seam.position.y - seam.emission_box_extents.y - maxf(0.0, fall) - half)
	return low

## The jet's level shared over its emitters (two across the hall): together they make one jet's loudness.
func roar_trim() -> float:
	return linear_to_db(1.0 / float(maxi(1, roar_at.size())))

## A world point from this node's frame.
func _world(local: Vector3) -> Vector3:
	return (global_position if is_inside_tree() else position) + local

## A one-off stream through the base's mix: its category, its trim (plus `extra`, never above 0), `from` s in.
func _cue(sound: String, at: Vector3, extra := 0.0, from := 0.0) -> AudioStreamPlayer3D:
	var m: Array = MIX[sound]
	return play_cue(_streams[sound], at, m[0], minf(0.0, float(m[2]) + extra), from)

func _stop_roar() -> void:
	for p in roar:
		if is_instance_valid(p):
			p.queue_free()
	roar.clear()
	_tail = -1.0

# --- the record ------------------------------------------------------------------------------------------------

func _take(rec: Dictionary) -> void:
	var n: Array = rec["n"]
	_state = StringName(rec.get("state", &"rest"))
	_since = float(rec.get("since", 0.0))
	_len = float(n[Steam.N_LEN])
	if _len <= 0.0:
		_len = Steam.BUILD_S if _state == Steam.BUILD else Steam.JET_S
	_purge = float(n[Steam.N_PURGE]) > 0.5
	_power = int(n[Steam.N_POWER])

func changed(rec: Dictionary, before: Dictionary, ht: float) -> void:
	var was := _state
	_take(rec)
	var into := seconds_in(rec, ht)
	if _state == Steam.BUILD and was != Steam.BUILD:
		knocked = -1
		_stop_roar()
		if is_instance_valid(hiss):
			hiss.queue_free()
		hiss = null
		if into < (_streams["build"] as AudioStreamWAV).get_length():
			hiss = _cue("build", _world(hiss_at), 0.0, into)
	elif _state == Steam.JET and was != Steam.JET:
		if is_instance_valid(hiss):
			hiss.queue_free()
		hiss = null
		_stop_roar()
		var m: Array = MIX["jet"]
		for at in roar_at:
			# A loop, started `into` seconds in (play_loop wraps it by the stream's own length).
			roar.append(play_loop(_streams["jet"], _world(at), m[0], float(m[2]) + roar_trim(), into))
		if _purge:
			_cue("groan", _world(Vector3(0, PIPE_Y, 0)), 0.0, into)
	elif _state == Steam.REST and was == Steam.JET:
		_tail = 0.0
	_apply(ht, false)

func frame(rec: Dictionary, ht: float, delta: float) -> void:
	if StringName(rec.get("state", &"")) != _state or float(rec.get("since", 0.0)) != _since:
		_take(rec)
	var into := ht - _since
	if _state == Steam.BUILD:
		# The knocks, each once, at its moment in the build (late screens skip ones long past).
		for i in KNOCKS.size():
			var at := KNOCKS[i] * _len
			if i > knocked and into >= at:
				knocked = i
				if into - at < 0.25:
					_cue("knock", _world(hiss_at), -float(i))
	if _tail >= 0.0:
		_tail += delta
		var g := clampf(1.0 - _tail / 0.25, 0.0, 1.0)
		var m: Array = MIX["jet"]
		for p in roar:
			if is_instance_valid(p):
				p.volume_db = Sfx.BASE_DB + float(m[2]) + roar_trim() + linear_to_db(maxf(g, 0.001))
		if g <= 0.0:
			_stop_roar()
	_apply(ht, false)

func event(e: Dictionary, _ht: float) -> void:
	match str(e.get("type", "")):
		"dangerCue":
			if StringName(e.get("cue", &"")) == &"steam_cry":
				var at := Vector3(float(e["x"]), float(e.get("y", 0.0)), float(e["z"]))
				_cue("cry", at + Vector3(0, 1.5, 0))
				_burst(at + Vector3(0, 1.2, 0))
		"dangerBlind":
			if str(e.get("playerId", "")) == my_id():
				# In your own ears: not placed, on the player category's bus at BASE_DB plus its trim.
				var m: Array = MIX["ring"]
				var p := AudioStreamPlayer.new()
				p.bus = (CATS[m[0]] as Array)[0]
				p.stream = _streams["ring"]
				p.volume_db = Sfx.BASE_DB + float(m[2])
				add_child(p)
				p.play()
				p.finished.connect(p.queue_free)

## A short burst of steam off a scalded player's chest, so a bystander sees a scald and not a jump (looks only).
func _burst(at: Vector3) -> void:
	var b := CPUParticles3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(0.6, 0.6)
	q.material = puff_mat
	b.mesh = q
	b.amount = 14
	b.lifetime = 0.9
	b.one_shot = true
	b.explosiveness = 0.85
	b.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	b.emission_sphere_radius = 0.2
	b.direction = Vector3(0, 1, 0)
	b.spread = 70.0
	b.initial_velocity_min = 0.6
	b.initial_velocity_max = 1.4
	b.damping_min = 2.0
	b.damping_max = 3.0
	b.scale_amount_min = 0.6
	b.scale_amount_max = 1.0
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, 0.4))
	ramp.set_color(ramp.get_point_count() - 1, Color(1, 1, 1, 0))
	b.color_ramp = ramp
	b.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	b.top_level = true
	add_child(b)
	b.global_position = at
	b.emitting = true
	b.finished.connect(b.queue_free)
	bursts += 1

## Lamps, sheet and puffs from the record's state and its host time.
func _apply(ht: float, _first: bool) -> void:
	var into := ht - _since
	var room_lit := lit(global_position + Vector3(0, 1.5, 0))
	var dark := _power == Steam.POWER_EMERGENCY
	var tint := TINT_DARK if dark else TINT_LIT
	# Bright in the lights (it must read down the long hall), dim in the amber emergency light (it must not glow).
	var bright := (0.5 if dark else 1.45) * (1.0 if room_lit else 0.6)
	var lamp := LAMP_OFF
	var lamp_e := 1.0
	var steam := 0.0
	var jetting := false
	match _state:
		Steam.BUILD:
			if scheduled({"state": _state, "since": _since}, ht, Steam.BUILD, _len, Steam.JET) == Steam.JET:
				# The build has run its length by host time (the base's scheduled()): a build only ends in its jet, so
				# draw the jet now, from the schedule, rather than when the snapshot that says so arrives.
				jetting = true
				lamp = LAMP_RED
				lamp_e = 3.0
				steam = clampf((into - _len) / 0.12, 0.0, 1.0)
			else:
				lamp = LAMP_AMBER if fmod(into, 0.4) < 0.34 else LAMP_OFF
				lamp_e = AMBER_ENERGY
				# A few wisps leak in the build's last half.
				steam = clampf((into / maxf(_len, 0.01) - 0.5) * 0.5, 0.0, 0.25)
		Steam.JET:
			jetting = true
			lamp = LAMP_RED
			lamp_e = 3.0
			steam = clampf(into / 0.12, 0.0, 1.0) * clampf((_len - into) / 0.25, 0.0, 1.0)
	if dark and jetting:
		# In the cut the red lamp colours the curtain, so its edge reads (no light added, no opacity added).
		tint = TINT_DARK.lerp(LAMP_RED, CUT_JET_RED)
		bright = CUT_JET_BRIGHT
	for m in lamps:
		m.set_shader_parameter("color", lamp)
		# A warning lamp is never dimmed with the room: in the dark it is the thing to see.
		m.set_shader_parameter("energy", lamp_e)
	var glow := Color(0, 0, 0, 0) if lamp == LAMP_OFF else Color(lamp.r, lamp.g, lamp.b, 0.8)
	for h in halos:
		h.visible = lamp != LAMP_OFF
		(h.material_override as StandardMaterial3D).albedo_color = glow
	var col := Color(tint.r * bright, tint.g * bright, tint.b * bright)
	for mi in sheets + roots:
		mi.visible = steam > 0.001
		var sm := mi.material_override as ShaderMaterial
		sm.set_shader_parameter("clock", ht)
		sm.set_shader_parameter("strength", steam)
		sm.set_shader_parameter("tint", col)
	_tint = col
	var pour := jetting and steam > 0.3
	if puffs.emitting != pour:
		puffs.emitting = pour
	if seam.emitting != pour:
		seam.emitting = pour
	puff_mat.albedo_color = Color(tint.r * bright, tint.g * bright, tint.b * bright)

# --- sounds, made from arithmetic --------------------------------------------------------------------------------

func _make_streams() -> void:
	if not _streams.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 7106
	_streams["knock"] = _wav(_knock(rng), false, float(MIX["knock"][1]))
	_streams["build"] = _wav(_build_hiss(rng), false, float(MIX["build"][1]))
	_streams["jet"] = _wav(_jet(rng), true, float(MIX["jet"][1]))
	_streams["groan"] = _wav(_groan(rng), false, float(MIX["groan"][1]))
	_streams["cry"] = _wav(_cry(rng), false, float(MIX["cry"][1]))
	_streams["ring"] = _wav(_ring(), false, float(MIX["ring"][1]))

## The base's loudness figure (kind_view.gd measure(): the RMS in dBFS of the samples above -50 dBFS) of raw samples.
static func _loud(a: PackedFloat32Array) -> float:
	var floor_lin := pow(10.0, -50.0 / 20.0)
	var sum := 0.0
	var n := 0
	for v in a:
		if absf(v) >= floor_lin:
			sum += v * v
			n += 1
	return 10.0 * log(sum / n) / log(10.0) if n > 0 else -INF

## 16-bit samples whose loudness is `loud` dBFS (the level is in the stream; the mix plays it at Sfx.BASE_DB).
static func _wav(raw: PackedFloat32Array, loop: bool, loud: float) -> AudioStreamWAV:
	var samples := raw
	# A few passes: scaling moves which quiet samples count.
	for _pass in 4:
		var now := _loud(samples)
		if is_inf(now):
			break
		var k := db_to_linear(loud - now)
		for i in samples.size():
			samples[i] *= k
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = samples.size()
	return w

static func _buf(seconds: float) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(int(seconds * RATE))
	return a

## A deep metallic knock in the line: a damped thump, a ringing overtone, a hard click.
static func _knock(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var a := _buf(0.32)
	for i in a.size():
		var t := float(i) / RATE
		var thump := sin(TAU * 110.0 * t + 2.0 * exp(-t * 40.0)) * exp(-t * 18.0)
		var ring := (sin(TAU * 1400.0 * t) * 0.6 + sin(TAU * 2310.0 * t) * 0.3) * exp(-t * 12.0)
		var click := (rng.randf() - 0.5) * exp(-t * 400.0)
		a[i] = thump * 0.7 + ring * 0.22 + click * 0.8
	return a

## Two one-pole filters make band-limited noise: high-passed above `lo`'s pole.
static func _hiss_sample(state: Array, x: float, k_lo: float, k_hi: float) -> float:
	state[0] = float(state[0]) + (x - float(state[0])) * k_hi
	state[1] = float(state[1]) + (float(state[0]) - float(state[1])) * k_lo
	return float(state[0]) - float(state[1])

## The pressure building: hiss rising 15 dB, its cutoff climbing.
static func _build_hiss(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var a := _buf(1.5)
	var st: Array = [0.0, 0.0]
	for i in a.size():
		var t := float(i) / RATE
		var u := t / 1.5
		var k_lo := 1.0 - exp(-TAU * lerpf(2000.0, 5000.0, u) / RATE)
		var x := _hiss_sample(st, rng.randf() * 2.0 - 1.0, k_lo, 0.95)
		var gain := db_to_linear(lerpf(-15.0, 0.0, u * u)) * minf(1.0, t / 0.05)
		# A faint whistle as the valve strains.
		var whistle := sin(TAU * lerpf(1800.0, 2600.0, u) * t) * 0.06 * u
		a[i] = (x * 0.55 + whistle) * gain
	return a

## The jet: roaring broadband hiss over a low rumble; 2 s that loops (the ends crossfaded).
static func _jet(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var a := _buf(2.0)
	var lp := 0.0
	var lp2 := 0.0
	var st: Array = [0.0, 0.0]
	for i in a.size():
		var t := float(i) / RATE
		var w := rng.randf() * 2.0 - 1.0
		var hi := _hiss_sample(st, w, 1.0 - exp(-TAU * 900.0 / RATE), 0.9)
		lp += (w - lp) * 0.03
		lp2 += (lp - lp2) * 0.05
		var flutter := 1.0 + 0.12 * sin(TAU * 7.0 * t) + 0.08 * sin(TAU * 13.0 * t + 1.0)
		a[i] = hi * 0.5 * flutter + lp2 * 3.2 + sin(TAU * 55.0 * t) * 0.05
	# Crossfade the last 0.15 s into the start so the loop has no seam.
	var fade := int(0.15 * RATE)
	for i in fade:
		var g := float(i) / fade
		a[i] = a[i] * g + a[a.size() - fade + i] * (1.0 - g)
	a.resize(a.size() - fade)
	return a

## The lines groaning in a purge: a deep bending tone with beats, rising then sagging.
static func _groan(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var a := _buf(2.6)
	var ph1 := 0.0
	var ph2 := 0.0
	var lp := 0.0
	for i in a.size():
		var t := float(i) / RATE
		var f := 42.0 + 14.0 * sin(PI * t / 2.6) + 3.0 * sin(TAU * 0.9 * t)
		ph1 += TAU * f / RATE
		ph2 += TAU * f * 1.51 / RATE
		lp += ((rng.randf() - 0.5) - lp) * 0.01
		var env := minf(1.0, t / 0.3) * minf(1.0, (2.6 - t) / 0.5)
		a[i] = (sin(ph1) * 0.45 + sin(ph2) * 0.2 + sign(sin(ph1)) * 0.06 + lp * 2.0) * env
	return a

## A sharp pained gasp: mostly breath, a low voiced pulse train under it (about 190 Hz falling to 130, a little
## unsteady), through three vowel formants. A stand-in for a recorded take.
static func _cry(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var a := _buf(0.62)
	var formants: Array = [[750.0, 90.0, 1.0], [1220.0, 110.0, 0.55], [2650.0, 160.0, 0.25]]
	var bq: Array = []
	for f: Array in formants:
		bq.append(_bp(float(f[0]), float(f[1])))
	var states: Array = []
	for _f: Array in formants:
		states.append([0.0, 0.0, 0.0, 0.0])
	var phase := 0.0
	var jitter := 1.0
	for i in a.size():
		var t := float(i) / RATE
		var f0 := lerpf(190.0, 130.0, t / 0.62) * jitter
		phase += f0 / RATE
		var pulse := 0.0
		if phase >= 1.0:
			phase -= 1.0
			pulse = 1.0
			jitter = 1.0 + rng.randf_range(-0.025, 0.025)
		var breath := (rng.randf() - 0.5) * (0.8 + 0.9 * exp(-t * 9.0))
		var src := pulse * 1.6 + breath * 2.2
		var y := 0.0
		for k in formants.size():
			y += _bq_step(bq[k], states[k], src) * float(formants[k][2])
		var env := minf(1.0, t / 0.012) * exp(-maxf(0.0, t - 0.08) * 6.5)
		a[i] = clampf(y * 0.9 * env, -1.0, 1.0)
	return a

## A ring in your own ears: a high tone, slightly unsteady, fading over a second.
static func _ring() -> PackedFloat32Array:
	var a := _buf(1.1)
	for i in a.size():
		var t := float(i) / RATE
		a[i] = (sin(TAU * 3150.0 * t) * 0.18 + sin(TAU * 3185.0 * t) * 0.1) * exp(-t * 2.6) * minf(1.0, t / 0.05)
	return a

## A band-pass biquad's coefficients (RBJ, constant peak gain) for centre `f`, bandwidth `bw` Hz.
static func _bp(f: float, bw: float) -> PackedFloat32Array:
	var w0 := TAU * f / RATE
	var q := f / bw
	var alpha := sin(w0) / (2.0 * q)
	var a0 := 1.0 + alpha
	return PackedFloat32Array([alpha / a0, 0.0, -alpha / a0, -2.0 * cos(w0) / a0, (1.0 - alpha) / a0])

static func _bq_step(c: PackedFloat32Array, s: Array, x: float) -> float:
	var y: float = c[0] * x + c[1] * s[0] + c[2] * s[1] - c[3] * s[2] - c[4] * s[3]
	s[1] = s[0]
	s[0] = x
	s[3] = s[2]
	s[2] = y
	return y
