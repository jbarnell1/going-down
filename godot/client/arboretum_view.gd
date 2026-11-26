# The Arboretum as drawn (North Star A2: "A forest indoors, under a painted sky"; piece AR3). Dresses a Level
# whose plan is an Arboretum (Level.build hands over here): the ground by surface, thicket, trunks under a dark
# canopy, the landmarks each with its old park lamp, the brick lift pavilion, the painted sky with its panel
# seams, and the dark. Simple batched meshes use procedural and reduced photographic textures.
#
# The dark. The owner, 18 Nov: "the whole level should be pretty darn dark." The sky gives a deep blue dusk and
# almost no light; under the canopy it is close to black. The only real light is a lamp at each landmark (a
# pool about 6 m across) and the pavilion's. In the blackout the lamps and the sky go out. The near light
# (client/main.gd) is the player's own, and picks out the gravel underfoot. Fireflies stay around the water.
#
# Ground has a voice: moss is dark green and smooth, litter brown and mottled, gravel pale, a twig fall litter
# with pale sticks on it under its dead tree. surface_at() says what is under a point, from the same garden
# the host made (sim/arboretum.gd from the plan's seed and depth), and the footsteps are played from it.
#
# Recorded wind, crickets, footsteps for each surface, and the host's twig crack. Within 10 m of the
# Groundskeeper the garden fades to a faint air bed, with the insects gone by 5 m.
# Nothing here is a rule: no collision, no noise (sim/noise.gd is the host's), no timing.
extends Node3D

const Arboretum = preload("res://sim/arboretum.gd")
const Noises = preload("res://sim/noise.gd")
const Floor = preload("res://sim/floor.gd")
const Furniture = preload("res://sim/furniture.gd")
const Hides = preload("res://sim/hides.gd")
const InventoryView = preload("res://client/inventory_view.gd")
const KeeperView = preload("res://client/groundskeeper_view.gd")
const GardenSound = preload("res://client/garden_sound.gd")
const Ferns = preload("res://client/arboretum_ferns.gd")
## LA4: the landmarks' shapes and the thicket's cards (client/arboretum_dress.gd).
const Dress = preload("res://client/arboretum_dress.gd")
const BARK_MAP = preload("res://assets/arboretum/willow_bark.png")
const LITTER_MAP = preload("res://assets/arboretum/leaf_litter.png")
const IRON_MAP = preload("res://assets/arboretum/painted_iron.webp")
const GLASS_GRIME = preload("res://assets/arboretum/glass_grime.png")
const GLASS_SHADER = preload("res://client/shaders/arboretum_glass.gdshader")

const S := 2.0
const SKY_H := 12.0
## JS1: where the hall's painted north wall stands (metres): just behind the lift car's back wall (the car's
## rect starts at z = 0 on this floor's north edge).
const NORTH_WALL_Z := -0.05
const CHUNK := 4
const WALL_H := 3.0
const DOOR_W := 1.1
const DOOR_H := 2.1
## The ambient light, lit and in the blackout, and the fog (client/main.gd reads the level's).
## LK1: the floor was close to black on a darker monitor (a friend "just sees static" on it). The dark stays the mood,
## but it is lit dusk, not nothing: a cool fill from the painted sky (AMBIENT_LIT at AMBIENT_ENERGY, read by
## client/main.gd; it goes out with the lamps), the painted backdrop a little brighter than the ground so trees and
## hedges stand against it (SKY_GLOW, WALL_GLOW), a faint cool light from high in the painted sky so tops read lighter
## than sides (DUSK_*; no shadow, out with the lamps), a small warm practical light at each landmark's building
## (PRACTICAL_*, so from the seed like the landmarks), and fog that lightens with distance towards the painted dusk
## (FOG) and goes dark in the blackout (FOG_DARK). The rules' light (sim/) is not touched; the hides are as dark as
## their walls make them (no practical stands in one).
const AMBIENT_LIT := Color(0.5, 0.62, 1.0)
const AMBIENT_ENERGY := 1.0
const DUSK := Color(0.62, 0.72, 1.0)
const DUSK_ENERGY := 0.42
## Where the dusk comes from: pitch and yaw (degrees), high over the far end of the hall.
const DUSK_FROM := Vector2(-58.0, 205.0)
const AMBIENT_DARK := Color(0.03, 0.04, 0.09)
const FOG := Color(0.085, 0.105, 0.17)
const FOG_DARK := Color(0.004, 0.006, 0.014)
const FOG_DENSITY := 0.02
const SKY_GLOW := 0.7
const WALL_GLOW := 0.6
const PRACTICAL := Color(1.0, 0.68, 0.38)
const PRACTICAL_ENERGY := 1.4
const PRACTICAL_REACH := 2.4
## A hide's half-width at most (a shed): a practical's reach stops this far short of a hide's middle.
const HIDE_HALF := 0.6
## The near light's share on this floor even with the lamps on (it is dark everywhere but under them).
const NEAR_LIGHT := 0.85
const LAMP := Color(1.0, 0.72, 0.42)
const LAMP_ENERGY := 5.5
const LAMP_REACH := 9.0
## The ring of silence: the garden is its full self beyond this of the Groundskeeper, and silent within the other.
const HUSH_FAR := 10.0
const HUSH_NEAR := 5.0
## Metres to a footstep by gait, and the gait a speed means (m/s).
const STRIDE := {"creep": 0.55, "walk": 0.8, "sprint": 1.15}

const C_MOSS := Color(0.27, 0.33, 0.13)
const C_LITTER := Color(0.54, 0.28, 0.13)
const C_GRAVEL := Color(0.74, 0.70, 0.63)
const C_BRICK := Color(0.5, 0.27, 0.2)
const C_THICKET := Color(0.18, 0.22, 0.10)
const C_BARK := Color(0.46, 0.30, 0.16)
const C_DEAD := Color(0.62, 0.6, 0.55)
const C_STICK := Color(0.72, 0.68, 0.58)
const C_IRON := Color(0.1, 0.12, 0.11)
const C_WOOD := Color(0.4, 0.3, 0.2)
## The garden shed hide: across, tall, deep (m).
const SHED := Vector3(0.9, 1.9, 0.58)
## Its two door leaves' width and the crack left between them (m).
const SHED_LEAF := 0.33
const SHED_CRACK := 0.1
## The slit in the dark skirt under the bandstand: its bottom and top (m), round the hide's 30 cm eye.
const UNDER_SLIT := Vector2(0.2, 0.42)
const C_STONE := Color(0.55, 0.55, 0.52)
const C_GLASS := Color(0.5, 0.62, 0.55, 0.22)

var lv: Level
var fp: Floor.FloorPlan
var g: Arboretum.Garden
## The Groundskeeper's view, once the game has made it (client/groundskeeper_view.gd set_floor).
var keeper: KeeperView = null
## What was drawn, for checks: counts by kind.
var drawn := {}

var _tools := {}          # [material key, chunk] -> SurfaceTool
var _mats := {}
var _glows: Array = []    # [ShaderMaterial, energy lit, energy in the blackout]
var _moths: Array = []    # [node, centre, radius, phase, speed]
var _flies: Array = []    # [node, centre, phase]
var _t := 0.0
var _rng := RandomNumberGenerator.new()
var _garden_audio := GardenSound.new()
var _amb: Dictionary = {}
var _steps: Array[AudioStreamPlayer3D] = []
var _step_next := 0
var _own: AudioStreamPlayer
var _walked := 0.0
var _last_cam := Vector3.INF
var _hush := 1.0
## LK1: where the hides stand (the shed, the sacked bench, under the bandstand, the hollow log): no practical light
## is put where it would reach one (unshadowed light goes through boards).
const HIDE_PIECES: Array[StringName] = [&"shed", &"bench", &"under", &"log"]
var _hide_spots: Array[Vector3] = []
## LK1: the practical lights placed: [landmark kind, the light].
var practicals: Array = []
## LA4: the landmarks' shapes and the thicket's cards.
var _dr: Dress
## LA4, tests only (tests/test_arboretum_dress.gd): while `recording` is set, every quad and triangle drawn is kept here
## as [tag, material, a, b, c, colour], with the tag client/arboretum_dress.gd sets round what it draws.
static var recording := false
var record_tag := ""
var records: Array = []

static var _tex := {}

## Dresses `level` as the Arboretum. Returns the view, kept as the level's "arboretum" meta and its child.
static func dress(level: Level, rules_plan: Floor.FloorPlan = null) -> Node3D:
	var v: Node3D = new()
	v.name = "ArboretumView"
	v.process_priority = 1000
	v.call(&"_dress", level, rules_plan)
	return v

func _dress(level: Level, rules_plan: Floor.FloorPlan) -> void:
	lv = level
	level.set_meta(&"arboretum", self)
	level.set_meta(&"near_light", NEAR_LIGHT)
	level.set_meta(&"near_light_gain", 1.7)
	level.set_meta(&"fog_color", FOG)
	level.set_meta(&"fog_color_dark", FOG_DARK)
	level.set_meta(&"fog_density", FOG_DENSITY)
	level.set_meta(&"ambient_energy", AMBIENT_ENERGY)
	level.add_child(self)
	level.shadows = false
	level.ambient_lit = AMBIENT_LIT
	level.ambient_dark = AMBIENT_DARK
	# The game already has the rules plan. Standalone callers with a plan dump can still build the view.
	fp = rules_plan if rules_plan != null else Arboretum.generate_arboretum(str(level.plan.seed), int(level.plan.depth))
	g = Arboretum.garden_of(fp)
	_rng.seed = hash("arboretum-view:%s:%d" % [fp.seed, fp.depth])
	_dr = Dress.new(self, fp)
	_ground()
	_thicket_and_walls()
	_pieces()
	drawn["fern"] = Ferns.dress(self, fp, g)
	_landmarks()
	_pavilion()
	_sky()
	_commit()
	_sounds()
	level.props_placed = int(drawn.get("trunk", 0)) + int(drawn.get("landmark", 0))
	_apply(1.0)

# --- what the game and the checks ask --------------------------------------------------------------

## The surface under a point (metres), as the host's rules have it: "moss", "litter", "gravel", "twig" or "none".
func surface_at(x: float, z: float) -> String:
	return Noises.SURFACE_NAMES[g.surface_at(x, z)] if g != null else "none"

## The landmarks' names for the lift's map plate (names only, no positions).
func landmark_names() -> PackedStringArray:
	var out := PackedStringArray()
	for l in g.landmarks:
		out.append(l.name)
	return out

## The garden as a tool needs it (tools/garden_shots.mjs): each cell's surface as one digit (sim/noise.gd's
## codes), the landmarks with their clearings and lamps (metres), where the pavilion's doorway leads, and where
## the Groundskeeper starts.
func describe() -> Dictionary:
	var cells := ""
	for c in g.cells:
		cells += str(c)
	var marks: Array = []
	for l in g.landmarks:
		marks.append({"kind": String(l.kind), "name": l.name, "x": l.x, "y": l.y, "w": l.w, "h": l.h, "onWalk": l.on_walk,
			"lamp": [l.lamp.x / 100.0, l.lamp.y / 100.0]})
	return {"w": Arboretum.W, "h": Arboretum.H, "cells": cells, "landmarks": marks,
		"door": [(g.door_out % Arboretum.W + 0.5) * S, (g.door_out / Arboretum.W + 0.5) * S],
		"start": [(fp.entity_start.x + 0.5) * S, (fp.entity_start.y + 0.5) * S]}

func check() -> Dictionary:
	# "lamps": the landmarks' lamps and the pavilion's bulb (LK1: the practicals and the dusk are counted apart).
	var lamps := lv.main_lights.filter(func(l: Light3D) -> bool: return l is OmniLight3D).size() - practicals.size()
	return {"hash": Arboretum.floor_hash(fp), "lamps": lamps, "practicals": practicals.size(), "landmarks": g.landmarks.size(), "drawn": drawn.duplicate(),
		"hush": snappedf(_hush, 0.01), "sounds": Array(GardenSound.names())}

# --- materials and meshes ----------------------------------------------------------------------------

static func _noise_tex(key: String, base: float, spread: float, grain: int, seed_: int) -> Texture2D:
	if _tex.has(key):
		return _tex[key]
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_L8)
	var coarse := PackedFloat32Array()
	var cn := n / grain
	coarse.resize(cn * cn)
	for i in coarse.size():
		coarse[i] = rng.randf()
	for y in n:
		for x in n:
			var v := coarse[(y / grain) % cn * cn + (x / grain) % cn]
			var fine := rng.randf()
			var k := clampf(base + spread * (v * 0.65 + fine * 0.35 - 0.5), 0.0, 1.0)
			img.set_pixel(x, y, Color(k, k, k))
	var tex := ImageTexture.create_from_image(img)
	_tex[key] = tex
	return tex

## Small grains and gravel facets sit on one world-aligned tile per surface.
static func _soil_tex(key: String) -> Texture2D:
	if _tex.has(key):
		return _tex[key]
	var n := 96
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(key)
	var img := Image.create(n, n, false, Image.FORMAT_L8)
	var moss := key == "moss"
	for y in n:
		for x in n:
			var shade := (0.55 if moss else 0.52) + 0.12 * rng.randf()
			img.set_pixel(x, y, Color(shade, shade, shade))
	for k in 400:
		var center := Vector2(rng.randi_range(0, n - 1), rng.randi_range(0, n - 1))
		var span := rng.randf_range(1.7, 3.3)
		var half_width := span * rng.randf_range(0.62, 0.95)
		var angle := rng.randf() * TAU
		var tone := rng.randf_range(0.49, 0.84 if moss else 0.94)
		for dy in range(-ceili(span), ceili(span) + 1):
			for dx in range(-ceili(span), ceili(span) + 1):
				var p := Vector2(dx, dy).rotated(angle)
				var edge := absf(p.x) / span + absf(p.y) / half_width * (0.68 if moss else 0.82)
				if edge <= 1.0:
					var shade := tone * (0.78 if edge > 0.74 and p.y > 0 else 1.0)
					img.set_pixel(posmod(int(center.x) + dx, n), posmod(int(center.y) + dy, n), Color(shade, shade, shade))
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_tex[key] = tex
	return tex

static func _brick_tex() -> Texture2D:
	if _tex.has("pavilion"):
		return _tex["pavilion"]
	var n := 96
	var img := Image.create(n, n, false, Image.FORMAT_RGB8)
	for y in n:
		var row := y / 48
		for x in n:
			var u := (x + row * 24) % n
			var mx := u % 48
			var my := y % 48
			var wear := _hash01(x / 3, y / 4, 36)
			var col := Color(0.48, 0.29, 0.22) * (0.75 + 0.28 * wear + 0.23 * _hash01(u / 48, row, 37))
			if mx < 2 or my < 4:
				col = Color(0.28, 0.25, 0.20) * (0.80 + 0.28 * wear)
			elif mx == 3 or my == 5:
				col *= 1.12
			img.set_pixel(x, y, col)
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_tex["pavilion"] = tex
	return tex

## A leaf card: blotches of leaf with gaps (alpha), for the canopy.
static func _leaf_tex() -> Texture2D:
	if _tex.has("leaf"):
		return _tex["leaf"]
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for k in 62:
		var c := Vector2(rng.randf_range(4, n - 4), rng.randf_range(4, n - 4))
		var r := rng.randf_range(3.0, 10.0)
		var a := rng.randf() * TAU
		var shade := rng.randf_range(0.51, 1.0)
		if ((c - Vector2(32, 32)) / Vector2(30, 23)).length_squared() > 1.0:
			continue
		for y in range(maxi(0, int(c.y - r)), mini(n, int(c.y + r) + 1)):
			for x in range(maxi(0, int(c.x - r)), mini(n, int(c.x + r) + 1)):
				var p := (Vector2(x, y) - c).rotated(a) / r
				if absf(p.x) + absf(p.y) * 1.6 < 1.0:
					var v := shade if p.y < 0.0 else shade * 0.81
					img.set_pixel(x, y, Color(v, v, v, 1.0))
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_tex["leaf"] = tex
	return tex

## The painted sky: dusk blue panels with their seams, and a few bulbs for stars (most of them dead).
static func _sky_tex() -> Texture2D:
	if _tex.has("sky"):
		return _tex["sky"]
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var n := 256
	var img := Image.create(n, n, false, Image.FORMAT_RGB8)
	for y in n:
		for x in n:
			var panel := Vector2i(x / 32, y / 32)
			var tone := 0.82 + 0.18 * (float((panel.x * 7 + panel.y * 13) % 5) / 4.0)
			var seam := x % 32 == 0 or y % 32 == 0
			var col := Color(0.16, 0.25, 0.62) * tone
			if seam:
				col = Color(0.02, 0.03, 0.07)
			img.set_pixel(x, y, col)
	for k in 70:
		var p := Vector2i(rng.randi_range(2, n - 3), rng.randi_range(2, n - 3))
		var lit := rng.randf() < 0.35
		img.set_pixel(p.x, p.y, Color(1.0, 0.95, 0.8) * (2.2 if lit else 0.25))
	var tex := ImageTexture.create_from_image(img)
	_tex["sky"] = tex
	return tex

func _lit(key: String, tex: Texture2D = null, uv := 1.0, rough := 1.0, emit := Color.BLACK, alpha := false, two_sided := false) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = rough
	m.metallic_specular = 0.1
	if tex != null:
		m.albedo_texture = tex
		m.uv1_scale = Vector3(uv, uv, uv)
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	if emit != Color.BLACK:
		m.emission_enabled = true
		m.emission = emit
	if alpha:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR if tex != null else BaseMaterial3D.TRANSPARENCY_ALPHA
		m.alpha_scissor_threshold = 0.5
	if two_sided:
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mats[key] = m
	return m

func _photo(key: String, tex: Texture2D, roughness: float) -> StandardMaterial3D:
	var material := _lit(key, tex, 1.0, roughness)
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	return material

func _tool(mat: String, at: Vector3) -> SurfaceTool:
	var key := [mat, int(floor(at.x / (S * CHUNK))), int(floor(at.z / (S * CHUNK)))]
	if not _tools.has(key):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_tools[key] = st
	return _tools[key]

func _quad(mat: String, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, col: Color,
		uv_span := Vector2.ONE, uv_origin := Vector2.ZERO) -> void:
	var st := _tool(mat, (a + c) * 0.5)
	var pts := [a, b, c, a, c, d]
	var uv := [Vector2.ZERO, Vector2(uv_span.x, 0), uv_span, Vector2.ZERO, uv_span, Vector2(0, uv_span.y)]
	if recording:
		records.append([record_tag, mat, a, b, c, col])
		records.append([record_tag, mat, a, c, d, col])
	for i in 6:
		st.set_normal(n)
		st.set_color(col)
		st.set_uv(uv_origin + uv[i])
		st.add_vertex(pts[i])

func _triangle(mat: String, a: Vector3, b: Vector3, c: Vector3, n: Vector3, col: Color, uvs := PackedVector2Array()) -> void:
	var st := _tool(mat, (a + b + c) / 3.0)
	var pts := [a, b, c]
	var uv: Array = Array(uvs) if uvs.size() == 3 else [Vector2.ZERO, Vector2.RIGHT, Vector2.DOWN]
	if recording:
		records.append([record_tag, mat, a, b, c, col])
	for i in 3:
		st.set_normal(n)
		st.set_color(col)
		st.set_uv(uv[i])
		st.add_vertex(pts[i])

## A box of `size` centred at `c` (its base at c.y when `on_floor`), turned `yaw` about the vertical.
func _box(mat: String, size: Vector3, c: Vector3, col: Color, on_floor := true, yaw := 0.0, tilt := Vector3.ZERO) -> void:
	var h := size * 0.5
	var mid := c + (Vector3(0, h.y, 0) if on_floor else Vector3.ZERO)
	var basis := Basis.from_euler(Vector3(tilt.x, yaw, tilt.z))
	var faces := [
		[Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)], [Vector3(0, 0, -1), Vector3(-1, 0, 0), Vector3(0, 1, 0)],
		[Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)], [Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)],
		[Vector3(0, 1, 0), Vector3(1, 0, 0), Vector3(0, 0, -1)], [Vector3(0, -1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)],
	]
	for f: Array in faces:
		var n: Vector3 = f[0]
		var u: Vector3 = f[1]
		var v: Vector3 = f[2]
		var o := n * h
		var du := u * h
		var dv := v * h
		var uv := Vector2(du.length() * 2.0 / 0.54, dv.length() * 2.0 / 0.17) if mat == "pavilion" else Vector2.ONE
		var offset := Vector2.ZERO
		if mat == "iron" or mat == "glass":
			# Keep scratches proportional along long rails and vary which patch each pane samples.
			var repeat_per_m := 1.45 if mat == "iron" else 0.48
			uv = Vector2(du.length(), dv.length()) * 2.0 * repeat_per_m
			offset = Vector2(c.x - c.z, c.y + c.z + c.x) * repeat_per_m
		_quad(mat, mid + basis * (o + du - dv), mid + basis * (o - du - dv),
			mid + basis * (o - du + dv), mid + basis * (o + du + dv), basis * n, col, uv, offset)

## Faceted wood and iron share the same tapered profile. The rings stay perpendicular to the
## supplied axis, so at standing height the leaning trunks still fit their solid footprint.
func _taper(mat: String, points: PackedVector3Array, radii: PackedFloat32Array, axis: Vector3,
		yaw: float, col: Color, sides: int = 5, cap_top := false) -> void:
	var ref := Vector3.FORWARD if absf(axis.dot(Vector3.UP)) > 0.98 else Vector3.UP
	var u := ref.cross(axis).normalized()
	var v := u.cross(axis).normalized()
	var spokes := PackedVector3Array()
	for i in sides:
		var a := yaw + TAU * i / sides
		spokes.append(u * cos(a) + v * sin(a))
	var tex_v := 0.0
	for r in points.size() - 1:
		var len := points[r].distance_to(points[r + 1]) * (0.55 if mat == "bark" else 1.0)
		for i in sides:
			var j := (i + 1) % sides
			var a := points[r] + spokes[i] * radii[r]
			var b := points[r] + spokes[j] * radii[r]
			var c := points[r + 1] + spokes[j] * radii[r + 1]
			var d := points[r + 1] + spokes[i] * radii[r + 1]
			var n := (d - a).cross(b - a).normalized()
			_quad(mat, a, b, c, d, n, col, Vector2(1.0 / sides, len), Vector2(float(i) / sides, tex_v))
		tex_v += len
	if cap_top:
		for i in sides:
			_triangle(mat, points[-1], points[-1] + spokes[i] * radii[-1],
				points[-1] + spokes[(i + 1) % sides] * radii[-1], axis, col)

func _limb(from: Vector3, to: Vector3, radius: float, col: Color) -> void:
	_taper("bark", PackedVector3Array([from, to]), PackedFloat32Array([radius, 0.008]),
		(to - from).normalized(), 0.0, col, 4)

func _leaf_card(at: Vector3, along: Vector3, across: Vector3, col: Color) -> void:
	var n := across.cross(along).normalized()
	_quad("leaf", at - across - along, at + across - along, at + across + along, at - across + along, n, col)

func _commit() -> void:
	for key: Array in _tools:
		var st: SurfaceTool = _tools[key]
		var mi := MeshInstance3D.new()
		mi.name = "%s_%d_%d" % key
		mi.mesh = st.commit()
		mi.material_override = _mats[key[0]]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
	_tools.clear()

func _glow(col: Color, lit_e: float, dark_e: float, tex: Texture2D = null) -> ShaderMaterial:
	var m := Level.glow_material(col, lit_e, tex)
	_glows.append([m, lit_e, dark_e])
	return m

static func _hash01(a: int, b: int, c: int = 0) -> float:
	var h := (a * 73856093) ^ (b * 19349663) ^ (c * 83492791)
	h = (h ^ (h >> 13)) * 1274126177
	return float((h ^ (h >> 16)) & 0xFFFF) / 65535.0

# --- the ground --------------------------------------------------------------------------------------

func _ground() -> void:
	_lit("moss", _soil_tex("moss"), 1.0, 0.85)
	_photo("litter", LITTER_MAP, 1.0)
	_lit("gravel", _soil_tex("gravel"))
	_lit("brick", _noise_tex("brick", 0.8, 0.35, 4, 14), 2.0, 1.0, Color(0.012, 0.008, 0.006))
	_lit("stick", null, 1.0, 0.9)
	var W := Arboretum.W
	for y in Arboretum.H:
		for x in W:
			var s := g.surface(x, y)
			if s == Noises.NONE:
				continue
			var kind := Floor.cell_at(fp, 0, x, y)
			var mat := "litter"
			var col := C_LITTER
			if kind == Floor.ROOM or kind == Floor.LANDING:
				mat = "brick"
				col = C_BRICK
			elif s == Noises.MOSS:
				mat = "moss"
				col = C_MOSS
			elif s == Noises.GRAVEL:
				mat = "gravel"
				col = C_GRAVEL
			# Let the hue carry the surface cue. A single stretch of gravel reads as a trail.
			col *= 0.94 + 0.12 * _hash01(x, y, 3)
			col.a = 1.0
			var x0 := x * S
			var z0 := y * S
			if mat == "gravel":
				_gravel_tile(x, y, col)
			else:
				_quad(mat, Vector3(x0, 0, z0), Vector3(x0 + S, 0, z0), Vector3(x0 + S, 0, z0 + S), Vector3(x0, 0, z0 + S),
					Vector3.UP, col, Vector2.ONE * S * 0.85, Vector2(x0, z0) * 0.85)
			drawn[Noises.SURFACE_NAMES[s]] = int(drawn.get(Noises.SURFACE_NAMES[s], 0)) + 1
			if s == Noises.TWIG:
				# Pale sticks on the litter.
				for k in 9:
					var p := Vector3(x0 + S * _hash01(x, y, 10 + k), 0.012, z0 + S * _hash01(x, y, 30 + k))
					_box("stick", Vector3(0.28 + 0.4 * _hash01(x, y, 50 + k), 0.022, 0.03), p, C_STICK * (0.75 + 0.25 * _hash01(x, y, 70 + k)), true, TAU * _hash01(x, y, 90 + k))

## Gravel thins over the last few centimetres of an exposed edge. Its colour, texture and all
## geometry stay in the host's gravel cell, so the surface where a foot lands still reads honestly.
func _gravel_tile(x: int, z: int, col: Color) -> void:
	var open_w := g.surface(x - 1, z) != Noises.GRAVEL
	var open_e := g.surface(x + 1, z) != Noises.GRAVEL
	var open_n := g.surface(x, z - 1) != Noises.GRAVEL
	var open_s := g.surface(x, z + 1) != Noises.GRAVEL
	var exposed := [open_n, open_e, open_s, open_w]
	var at := Vector3(x * S, 0, z * S)
	var st := _tool("gravel", at + Vector3(1, 0, 1) * S * 0.5)
	var corners := [Vector2(0, 0), Vector2(0.5, 0), Vector2(1, 0), Vector2(1, 0.5),
		Vector2(1, 1), Vector2(0.5, 1), Vector2(0, 1), Vector2(0, 0.5)]
	var edge := PackedVector3Array()
	var inside := PackedVector3Array()
	var tones := PackedColorArray()
	for i in corners.size():
		var p: Vector2 = corners[i]
		var w := 0.07 + _hash01(x, z, 100 + i) * 0.09
		var dx := w if p.x == 0.0 and open_w else (-w if p.x == 1.0 and open_e else 0.0)
		var dz := w if p.y == 0.0 and open_n else (-w if p.y == 1.0 and open_s else 0.0)
		edge.append(at + Vector3(p.x, 0, p.y) * S)
		inside.append(edge[i] + Vector3(dx, 0, dz))
		tones.append(col * (0.40 + 0.20 * _hash01(x, z, 110 + i)) if dx != 0.0 or dz != 0.0 else col)
	var center := at + Vector3(1, 0, 1) * S * 0.5
	for i in edge.size():
		var j := (i + 1) % edge.size()
		_gravel_vertex(st, center, col)
		_gravel_vertex(st, inside[i], col)
		_gravel_vertex(st, inside[j], col)
		if not exposed[i / 2]:
			continue
		_gravel_vertex(st, edge[i], tones[i])
		_gravel_vertex(st, inside[j], col)
		_gravel_vertex(st, inside[i], col)
		_gravel_vertex(st, edge[i], tones[i])
		_gravel_vertex(st, edge[j], tones[j])
		_gravel_vertex(st, inside[j], col)

static func _gravel_vertex(st: SurfaceTool, at: Vector3, tone: Color) -> void:
	st.set_normal(Vector3.UP)
	st.set_color(tone)
	st.set_uv(Vector2(at.x, at.z) * 1.4)
	st.add_vertex(at)

# --- thicket, and the hall's wall behind its hedge -----------------------------------------------------

func _thicket_and_walls() -> void:
	_lit("thicket", _soil_tex("litter"), 1.0)
	_lit("leaf", _leaf_tex(), 1.0, 1.0, Color.BLACK, true, true)
	var W := Arboretum.W
	var H := Arboretum.H
	for y in H:
		for x in W:
			var inside := x >= Arboretum.X0 and x <= Arboretum.X1 and y >= Arboretum.Y0 and y <= Arboretum.Y1
			var hedge := not inside and (x >= Arboretum.X0 - 1 and x <= Arboretum.X1 + 1 and y >= Arboretum.Y0 - 1 and y <= Arboretum.Y1 + 1)
			if Floor.cell_at(fp, 0, x, y) == Floor.ROOM or Floor.cell_at(fp, 0, x, y) == Floor.LANDING:
				continue
			# (Behind the pavilion the hall's wall is bare: the lift's shaft.)
			if hedge and y < Arboretum.Y0 and absi(x - fp.landing.x) <= 2:
				continue
			if not ((inside and g.thicket[y * W + x] == 1) or hedge):
				continue
			_dr.thicket(x, y)
			drawn["thicket"] = int(drawn.get("thicket", 0)) + 1

## The hedge stays solid along the cell edge underfoot. The waist and crown pull in irregularly.
func _bramble(x: int, y: int) -> void:
	var center := Vector3((x + 0.5) * S, 0, (y + 0.5) * S)
	var offsets := [Vector2(-1, -1), Vector2(0, -1), Vector2(1, -1), Vector2(1, 0),
		Vector2(1, 1), Vector2(0, 1), Vector2(-1, 1), Vector2(-1, 0)]
	var top := 2.35 + 0.85 * _hash01(x, y, 1)
	var col := C_THICKET * (0.78 + 0.45 * _hash01(x, y, 2))
	var bottom := PackedVector3Array()
	var waist := PackedVector3Array()
	var crown := PackedVector3Array()
	for i in offsets.size():
		var edge := Vector3(offsets[i].x, 0, offsets[i].y) * S * 0.5
		bottom.append(center + edge)
		var waist_scale := 0.86 + 0.14 * _hash01(x, y, 20 + i)
		waist.append(center + edge * waist_scale + Vector3.UP * (1.2 + 0.36 * _hash01(x, y, 30 + i)))
		var crown_scale := 0.43 + 0.39 * _hash01(x, y, 40 + i)
		crown.append(center + edge * crown_scale + Vector3.UP * (top + 0.42 * _hash01(x, y, 50 + i)))
	for i in offsets.size():
		var j := (i + 1) % offsets.size()
		var tint := col * (0.85 + 0.34 * _hash01(x, y, 60 + i))
		var lower := (waist[i] - bottom[i]).cross(bottom[j] - bottom[i]).normalized()
		var upper := (crown[i] - waist[i]).cross(waist[j] - waist[i]).normalized()
		_quad("thicket", bottom[i], bottom[j], waist[j], waist[i], lower, tint * 0.75)
		_quad("thicket", waist[i], waist[j], crown[j], crown[i], upper, tint)
		_triangle("thicket", center + Vector3.UP * (top + 0.35), crown[i], crown[j], Vector3.UP, tint)
	# Two ragged sprays catch the edge of the near light and break the cap's silhouette.
	for i: int in [1, 5]:
		var a := TAU * _hash01(x, y, 80 + i)
		var side := Vector3(cos(a), 0.08, sin(a))
		var up := Vector3(-sin(a) * 0.22, 0.55, cos(a) * 0.22)
		var at := waist[i].lerp(crown[i], 0.57)
		_leaf_card(at, up, side * 0.52, col * 1.1)

# --- what stands on the ground: trunks, dead trees, lamp posts, the small landmarks' pieces, the hides -----

## The garden shed's boards in its own frame (the inside spot at the origin, the door towards +z):
## [size, bottom middle]. A back, two sides, a floor and a top; the door ajar is its front.
static func shed_walls() -> Array:
	var w := SHED.x
	var ht := SHED.y
	var d := SHED.z
	var t := 0.03
	return [[Vector3(w, ht, t), Vector3(0, 0, -d * 0.5 + t * 0.5)], [Vector3(t, ht, d), Vector3(-w * 0.5 + t * 0.5, 0, 0)],
		[Vector3(t, ht, d), Vector3(w * 0.5 - t * 0.5, 0, 0)], [Vector3(w, t, d), Vector3.ZERO], [Vector3(w, t, d), Vector3(0, ht - t, 0)]]

func _pieces() -> void:
	_photo("bark", BARK_MAP, 1.0)
	_photo("iron", IRON_MAP, 0.72).albedo_color = Color(1.35, 1.35, 1.35)
	_lit("wood", _noise_tex("wood", 0.8, 0.4, 4, 32), 1.0)
	_lit("stone", _noise_tex("stone", 0.8, 0.4, 2, 33), 1.0)
	for p in Furniture.pieces_for(fp):
		var at := Vector3(p.x / 100.0, 0, p.y / 100.0)
		var r := _hash01(p.x, p.y, 5)
		if p.kind in HIDE_PIECES:
			_hide_spots.append(at)
		match p.kind:
			&"trunk":
				_tree(at, p.x, p.y, r, false)
				drawn["trunk"] = int(drawn.get("trunk", 0)) + 1
			&"dead_tree":
				_tree(at, p.x, p.y, r, true)
				drawn["dead_tree"] = int(drawn.get("dead_tree", 0)) + 1
			&"lamp":
				_lamp(at, true)
			&"fountain", &"statue", &"arch", &"sundial":
				# LA4: the small landmarks' shapes (client/arboretum_dress.gd).
				_dr.small(p.kind, at, r)
				if p.kind == &"fountain":
					_fireflies(at + Vector3(0, 0.9, 0))
			&"shed":
				var f := _facing(p.facing)
				# Hollow (MH1b): back, sides, floor and top, so the camera sat in it (play_link.gd hide_camera)
				# has the shed's own boards round it and the door ajar to look out of; nothing is drawn over it.
				var sy := atan2(f.x, f.z)
				var sb := Basis.from_euler(Vector3(0, sy, 0))
				for wall: Array in shed_walls():
					_box("wood", wall[0], at + sb * (wall[1] as Vector3), C_WOOD, true, sy)
				# Its two doors stand ajar with a crack between them: the gap you look out of from inside.
				for side: float in [-1.0, 1.0]:
					_box("wood", Vector3(SHED_LEAF, 1.7, 0.04), at + f * 0.3 + sb * Vector3(side * (SHED_CRACK + SHED_LEAF) * 0.5, 0.06, 0), C_WOOD * 0.55, true, sy - side * 0.12)
				_box("wood", Vector3(1.0, 0.07, 0.72), at + Vector3(0, 1.9, 0), C_WOOD * 0.7, true, atan2(f.x, f.z), Vector3(0.12, 0, 0))
				_dr.shed_roof(at, f, p.id)
			&"bench":
				var f := _facing(p.facing)
				var yaw := atan2(f.x, f.z)
				_box("wood", Vector3(1.8, 0.07, 0.6), at + Vector3(0, 0.78, 0), C_WOOD * 1.1, true, yaw)
				for sx: float in [-0.84, 0.84]:
					_box("wood", Vector3(0.07, 0.78, 0.56), at + Basis.from_euler(Vector3(0, yaw, 0)) * Vector3(sx, 0, 0), C_WOOD * 0.8, true, yaw)
				_box("wood", Vector3(1.8, 0.4, 0.03), at + f * 0.29 + Vector3(0, 0.38, 0), Color(0.16, 0.17, 0.13), true, yaw)   # sacking hung across the front
			&"under":
				var f := _facing(p.facing)
				# The bandstand's deck runs out over the hide (its underside is what is overhead in there), and
				# the dark skirt below it has a slit at the hide's eye (30 cm) to look out of (MH1b).
				_box("wood", Vector3(1.3, 0.06, 0.6), at + f * 0.02 + Vector3(0, 0.49, 0), C_WOOD * 0.8, true, atan2(f.x, f.z))
				_box("wood", Vector3(1.2, UNDER_SLIT.x, 0.06), at + f * 0.24, Color(0.015, 0.012, 0.01), true, atan2(f.x, f.z))
				_box("wood", Vector3(1.2, 0.5 - UNDER_SLIT.y, 0.06), at + f * 0.24 + Vector3(0, UNDER_SLIT.y, 0), Color(0.015, 0.012, 0.01), true, atan2(f.x, f.z))
			&"log":
				# A hollow log lying along the thicket: a ring of bark round a dark mouth.
				var f := _facing(p.facing)
				var yaw := atan2(f.x, f.z)
				var b := Basis.from_euler(Vector3(0, yaw, 0))
				# The stave facing the gap is missing (MH1b): the split you look out of from inside.
				for k in range(1, 8):
					var a := k * TAU / 8.0
					_box("bark", Vector3(1.6, 0.11, 0.22), at + Vector3(0, 0.27, 0) + b * Vector3(0, sin(a) * 0.22, cos(a) * 0.2), C_BARK * 1.5, false, yaw, Vector3(a, 0, 0))
				_box("bark", Vector3(1.5, 0.3, 0.3), at + Vector3(0, 0.12, 0), Color(0.012, 0.01, 0.008), true, yaw)

func _tree(at: Vector3, x: int, z: int, r: float, dead: bool) -> void:
	var a := TAU * r
	var along := Vector3(cos(a), 0, sin(a))
	var tall := (7.6 + 1.5 * r) if dead else (5.5 + 3.5 * r)
	var shoulder := at + Vector3.UP * 2.14
	var fork := shoulder.lerp(at + Vector3.UP * tall, 0.36) + along * (0.13 + 0.26 * r)
	var tip := at + Vector3.UP * tall + along * (0.3 + 0.55 * r)
	var col := (C_DEAD if dead else C_BARK) * (0.79 + 0.40 * r)
	var root := 0.24 if dead else 0.15
	var waist := root * (0.70 + 0.16 * _hash01(x, z, 6))
	_taper("bark", PackedVector3Array([at, at + Vector3.UP * 0.32, shoulder, fork, tip]),
		PackedFloat32Array([root, waist, waist, waist * 0.72, 0.012]), Vector3.UP, a, col, 5)
	for k in (3 if dead else 2):
		var angle := a + (2.1 * k if dead else 2.6 * k) + 0.8
		var spread := Vector3(cos(angle), 0, sin(angle))
		var join := shoulder.lerp(fork, 0.08 + k * (0.40 if dead else 0.64))
		var end := join + spread * (0.9 + 0.8 * _hash01(x, z, 8 + k)) + Vector3.UP * (0.55 + 0.8 * _hash01(x, z, 10 + k))
		_limb(join, end, waist * 0.65, col * 0.90)
		if dead:
			var bend := join.lerp(end, 0.71)
			_limb(bend, bend + (spread + Vector3.UP * 1.9) * 0.35, 0.032, col)
		else:
			var across := Vector3(-spread.z, 0.30, spread.x)
			var lc := Color(0.095, 0.15, 0.07) * (0.82 + 0.45 * _hash01(x, z, 7))
			_leaf_card(end + Vector3.UP * 0.13, spread * 1.08 + Vector3.UP * (0.45 - 0.63 * r), across * 0.66, lc)
	if not dead and Arboretum.is_conifer(x, z):
		for tier in 3:
			var y := tall * (0.39 + 0.16 * tier)
			var width := 1.36 - 0.24 * tier
			_taper("thicket", PackedVector3Array([at + Vector3.UP * y, at + Vector3.UP * (y + tall * 0.27)]),
				PackedFloat32Array([width, 0.03]), Vector3.UP, a, Color(0.07, 0.13, 0.076), 6)
	if not dead:
		_leaf_card(fork.lerp(tip, 0.45), along * 1.52 + Vector3.UP * 0.24,
			Vector3(-along.z, -0.30, along.x) * 1.13, Color(0.075, 0.12, 0.068))

func _rose_arch(at: Vector3, r: float) -> void:
	var iron := Color(0.22, 0.24, 0.19)
	for z: float in [-0.14, 0.14]:
		for x: float in [-0.51, 0.51]:
			_box("iron", Vector3(0.045, 1.94, 0.045), at + Vector3(x, 0, z), iron)
		for k in 8:
			var a := PI * k / 8.0
			var b := PI * (k + 1) / 8.0
			var start := at + Vector3(cos(a) * 0.51, 1.94 + sin(a) * 0.51, z)
			var end := at + Vector3(cos(b) * 0.51, 1.94 + sin(b) * 0.51, z)
			_taper("iron", PackedVector3Array([start, end]), PackedFloat32Array([0.027, 0.027]),
				(end - start).normalized(), 0.0, iron, 4)
	for k in 5:
		var a := 0.24 + k * 0.53
		var at_leaf := at + Vector3(cos(a) * 0.52, 1.94 + sin(a) * 0.54, 0.0)
		_leaf_card(at_leaf, Vector3(0.08, 0.20, 0.07), Vector3(0.12, 0.02, 0.14), Color(0.125, 0.165, 0.088))
		if k % 2 == 0:
			_box("thicket", Vector3(0.09, 0.08, 0.12), at_leaf + Vector3(0.017, 0.08, -0.04),
				Color(0.30, 0.095, 0.095), false, r + k)

static func _facing(f: StringName) -> Vector3:
	return Vector3(float(Floor.dir_dx(f)), 0, float(Floor.dir_dy(f)))

## An old park lamp: a post with a lantern (or, on the pavilion, the lantern on its wall), its warm pool, moths.
func _lamp(at: Vector3, post: bool) -> void:
	var head := at + Vector3(0, 2.75 if post else 2.45, 0)
	var frame := Color(0.15, 0.19, 0.16)
	if post:
		_taper("iron", PackedVector3Array([at, at + Vector3.UP * 0.12, at + Vector3.UP * 0.31, head]),
			PackedFloat32Array([0.10, 0.10, 0.05, 0.035]), Vector3.UP, 0.0, frame, 6)
	var base := head + Vector3.DOWN * 0.14
	var rim := head + Vector3.UP * 0.14
	if not _mats.has("lantern"):
		_mats["lantern"] = _glow(Color(1.0, 0.66, 0.29), 1.38, 0.0)
	_taper("lantern", PackedVector3Array([base, rim]), PackedFloat32Array([0.081, 0.129]),
		Vector3.UP, 0.0, Color.WHITE, 6)
	_taper("iron", PackedVector3Array([rim, rim + Vector3.UP * 0.03, rim + Vector3.UP * 0.14]),
		PackedFloat32Array([0.184, 0.184, 0.018]), Vector3.UP, 0.0, frame * 1.2, 6, true)
	for k in 6:
		var a := TAU * k / 6.0
		var side := Vector3(cos(a), 0, sin(a))
		var low := base + side * 0.084
		var high := rim + side * 0.132
		_taper("iron", PackedVector3Array([low, high]), PackedFloat32Array([0.014, 0.014]),
			(high - low).normalized(), 0.0, frame, 4)
	var o := OmniLight3D.new()
	o.position = head + Vector3(0, -0.1, 0)
	o.light_color = LAMP
	o.light_energy = LAMP_ENERGY
	o.omni_range = LAMP_REACH
	o.omni_attenuation = 1.35
	o.shadow_enabled = false
	o.distance_fade_enabled = true
	o.distance_fade_begin = 34.0
	o.distance_fade_length = 8.0
	add_child(o)
	lv.main_lights.append(o)
	lv._base_energy.append(LAMP_ENERGY)
	for k in 3:
		var moth := MeshInstance3D.new()
		var sm := BoxMesh.new()
		sm.size = Vector3(0.025, 0.012, 0.025)
		moth.mesh = sm
		moth.material_override = _glow(Color(1.0, 0.9, 0.7), 0.9, 0.0)
		add_child(moth)
		_moths.append([moth, head, 0.22 + 0.14 * k, _rng.randf() * TAU, 2.2 + _rng.randf() * 2.0])
	drawn["lamp"] = int(drawn.get("lamp", 0)) + 1

func _fireflies(at: Vector3) -> void:
	for k in 7:
		var fly := MeshInstance3D.new()
		var sm := BoxMesh.new()
		sm.size = Vector3(0.022, 0.022, 0.022)
		fly.mesh = sm
		fly.material_override = _glow(Color(0.75, 1.0, 0.35), 1.4, 1.4)
		add_child(fly)
		_flies.append([fly, at + Vector3(_rng.randf_range(-1.6, 1.6), _rng.randf_range(-0.4, 0.9), _rng.randf_range(-1.6, 1.6)), _rng.randf() * TAU])

# --- the big landmarks' buildings ---------------------------------------------------------------------

func _landmarks() -> void:
	var glass := ShaderMaterial.new()
	glass.shader = GLASS_SHADER
	glass.set_shader_parameter(&"grime_mask", GLASS_GRIME)
	_mats["glass"] = glass
	var W := Arboretum.W
	for l in g.landmarks:
		drawn["landmark"] = int(drawn.get("landmark", 0)) + 1
		if l.building < 0:
			continue
		var at := Vector3((l.building % W + 0.5) * S, 0, (l.building / W + 0.5) * S)
		# LA4: each building's shape (client/arboretum_dress.gd; the greenhouse is still _greenhouse below).
		_dr.building(l, at)
		_practical(l.kind, at)

## LK1: a landmark building's own warm practical, so from the seed like the landmark: a lantern on the building (in
## the glasshouse, under the bandstand's roof, on the shed row's and the gate lodge's walls) that reads from across the
## garden, and a small pool of light off the building's far side from its hide. Every building has a hide beside it,
## so the lantern hangs on the side away from it and its light reaches no hide (unshadowed light passes through
## boards); a light that would is left out and only the lantern glows. The aviary stays empty and dark.
const PRACTICAL_H := {&"greenhouse": 1.7, &"bandstand": 2.55, &"sheds": 2.0, &"lodge": 1.9}
## How far out from the building's middle the lantern hangs and its light stands (m).
const PRACTICAL_LANTERN_OUT := 1.07
const PRACTICAL_LIGHT_OUT := 2.1

func _practical(kind: StringName, at: Vector3) -> void:
	if not PRACTICAL_H.has(kind):
		return
	var h := float(PRACTICAL_H[kind])
	# Away from the nearest hide (towards +z when there is none near).
	var away := Vector3(0, 0, 1)
	var best := INF
	for spot: Vector3 in _hide_spots:
		var d := Vector2(spot.x - at.x, spot.z - at.z)
		if d.length() < best and d.length() > 0.01:
			best = d.length()
			away = -Vector3(d.x, 0, d.y).normalized()
	var inside := kind in [&"greenhouse", &"bandstand"]
	var lantern := at + Vector3.UP * h + (Vector3.ZERO if inside else away * PRACTICAL_LANTERN_OUT)
	if not _mats.has("practical"):
		_mats["practical"] = _glow(PRACTICAL, 1.6, 0.0)
	_box("practical", Vector3(0.14, 0.18, 0.14), lantern + Vector3.DOWN * 0.09, Color.WHITE)
	drawn["lantern"] = int(drawn.get("lantern", 0)) + 1
	var pos := at + Vector3.UP * h + away * PRACTICAL_LIGHT_OUT
	for spot: Vector3 in _hide_spots:
		if Vector2(spot.x - pos.x, spot.z - pos.z).length() < PRACTICAL_REACH + HIDE_HALF:
			drawn["practical_skipped"] = int(drawn.get("practical_skipped", 0)) + 1
			return
	var o := OmniLight3D.new()
	o.position = pos
	o.light_color = PRACTICAL
	o.light_energy = PRACTICAL_ENERGY
	o.omni_range = PRACTICAL_REACH
	o.omni_attenuation = 1.4
	o.shadow_enabled = false
	o.distance_fade_enabled = true
	o.distance_fade_begin = 34.0
	o.distance_fade_length = 8.0
	add_child(o)
	lv.main_lights.append(o)
	lv._base_energy.append(PRACTICAL_ENERGY)
	practicals.append([kind, o])
	drawn["practical"] = int(drawn.get("practical", 0)) + 1

func _greenhouse(at: Vector3) -> void:
	var frame := Color(0.37, 0.43, 0.37)
	_box("stone", Vector3(S, 0.46, S), at, C_BRICK)
	for k in 4:
		var a := k * PI * 0.5
		var out := Vector3(sin(a), 0, cos(a))
		var cross := Vector3(cos(a), 0, -sin(a))
		var wall := at + out * 0.963
		for x: float in [-0.96, -0.33, 0.33]:
			_box("iron", Vector3(0.055, 1.82, 0.05), wall + Vector3.UP * 0.46 + cross * x, frame, true, a)
		for y: float in [0.47, 1.34, 2.20]:
			_box("iron", Vector3(1.97, 0.048, 0.052), wall + Vector3.UP * y, frame, false, a)
		for i in 3:
			var x := float(i - 1) * 0.64
			# Two missing upper panes give the glasshouse an irregular profile when its lamp picks it out.
			var h := 0.88 if (i + k) % 4 == 1 else 1.72
			var tint := C_GLASS * (0.78 + 0.22 * _hash01(i, k, 17))
			tint.a = C_GLASS.a
			_box("glass", Vector3(0.61, h, 0.018), wall + Vector3.UP * 0.48 + cross * x, tint, true, a)
	for sx: float in [-1.0, 1.0]:
		var tilt := Vector3(0, 0, -sx * 0.57)
		var roof := at + Vector3(sx * 0.51, 2.53, 0)
		_box("glass", Vector3(1.19, 0.02, S), roof, C_GLASS, false, 0, tilt)
		for z: float in [-0.97, 0.0, 0.97]:
			_box("iron", Vector3(1.20, 0.054, 0.055), roof + Vector3(0, 0, z), frame, false, 0, tilt)
	_box("iron", Vector3(0.065, 0.065, S), at + Vector3(0, 2.86, 0), frame, false)
	_fireflies(at + Vector3.UP)

# --- the lift pavilion ----------------------------------------------------------------------------------

func _pavilion() -> void:
	_lit("pavilion", _brick_tex())
	var lx := fp.landing.x
	var x0 := (lx - 1) * S
	var x1 := (lx + 2) * S
	var z0 := Arboretum.Y0 * S
	var z1 := (Arboretum.Y0 + 2) * S
	var t := 0.16
	var col := Color(0.87, 0.80, 0.75)
	# The back wall, with the lift's doorway in it; the two sides; the front, with the one doorway.
	var half := lv.lift_half
	var mid := (lx + 0.5) * S
	_box("pavilion", Vector3(mid - half - x0, WALL_H, t), Vector3((x0 + mid - half) * 0.5, 0, z0), col)
	_box("pavilion", Vector3(x1 - mid - half, WALL_H, t), Vector3((x1 + mid + half) * 0.5, 0, z0), col)
	_box("pavilion", Vector3(half * 2.0, WALL_H - Level.LIFT_H, t), Vector3(mid, Level.LIFT_H, z0), col)
	_box("pavilion", Vector3(t, WALL_H, z1 - z0), Vector3(x0, 0, (z0 + z1) * 0.5), col)
	_box("pavilion", Vector3(t, WALL_H, z1 - z0), Vector3(x1, 0, (z0 + z1) * 0.5), col)
	_box("pavilion", Vector3(mid - DOOR_W * 0.5 - x0, WALL_H, t), Vector3((x0 + mid - DOOR_W * 0.5) * 0.5, 0, z1), col)
	_box("pavilion", Vector3(x1 - mid - DOOR_W * 0.5, WALL_H, t), Vector3((x1 + mid + DOOR_W * 0.5) * 0.5, 0, z1), col)
	_box("pavilion", Vector3(DOOR_W, WALL_H - DOOR_H, t), Vector3(mid, DOOR_H, z1), col)
	# Cast-stone door lining sits on the two jambs, clear of the modeled doorway.
	var trim := Color(0.40, 0.36, 0.29)
	for side: float in [-1.0, 1.0]:
		_box("stone", Vector3(0.12, DOOR_H, 0.11), Vector3(mid + side * (DOOR_W * 0.5 + 0.06), 0, z1 + t * 0.5), trim)
	_box("stone", Vector3(DOOR_W + 0.24, 0.12, 0.12), Vector3(mid, DOOR_H, z1 + t * 0.5), trim)
	var roof := Vector3(mid, WALL_H, (z0 + z1) * 0.5)
	_box("stone", Vector3(x1 - x0 + 0.25, 0.12, z1 - z0 + 0.25), roof, trim)
	_box("stone", Vector3(x1 - x0 + 0.50, 0.16, z1 - z0 + 0.50), roof + Vector3.UP * 0.12, trim * 0.72)
	var lamp := g.landmarks[0].lamp
	_lamp(Vector3(lamp.x / 100.0, 0, lamp.y / 100.0 + 0.2), false)
	# A weak bulb inside, so the crew steps out of light into the garden.
	var o := OmniLight3D.new()
	o.position = Vector3(mid, 2.6, (z0 + z1) * 0.5)
	o.light_color = Color(1.0, 0.85, 0.65)
	o.light_energy = 0.8
	o.omni_range = 5.0
	o.omni_attenuation = 1.5
	add_child(o)
	lv.main_lights.append(o)
	lv._base_energy.append(0.8)

# --- the painted sky and the hall --------------------------------------------------------------------

func _sky() -> void:
	var w := Arboretum.W * S
	var h := Arboretum.H * S
	# LK1: the painted dusk's faint light from above (with the lamps: out in the blackout).
	var dusk := DirectionalLight3D.new()
	dusk.name = "Dusk"
	dusk.light_color = DUSK
	dusk.light_energy = DUSK_ENERGY
	dusk.light_specular = 0.15
	dusk.shadow_enabled = false
	dusk.rotation_degrees = Vector3(DUSK_FROM.x, DUSK_FROM.y, 0.0)
	add_child(dusk)
	lv.main_lights.append(dusk)
	lv._base_energy.append(DUSK_ENERGY)
	var sky := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(w, h)
	pm.flip_faces = true
	sky.mesh = pm
	sky.position = Vector3(w * 0.5, SKY_H, h * 0.5)
	sky.material_override = _glow(Color(0.5, 0.62, 1.0), SKY_GLOW, 0.0, _sky_tex())
	add_child(sky)
	# The hall's walls: the same painted dusk coming down to a dark horizon behind the hedge.
	var x0 := (Arboretum.X0 - 1) * S
	var x1 := (Arboretum.X1 + 2) * S
	# JS1: the north wall stands behind the lift's back wall, not across the car (the car fills rows 0 and 1; at
	# row Y0 - 1 the painted wall, drawn from both sides and with nothing to stop a body, cut the car in half).
	var z0 := minf((Arboretum.Y0 - 1) * S, NORTH_WALL_Z)
	var z1 := (Arboretum.Y1 + 2) * S
	for side: Array in [[Vector3(x0, 0, z0), Vector3(x1, 0, z0)], [Vector3(x1, 0, z0), Vector3(x1, 0, z1)], [Vector3(x1, 0, z1), Vector3(x0, 0, z1)], [Vector3(x0, 0, z1), Vector3(x0, 0, z0)]]:
		var a: Vector3 = side[0]
		var b: Vector3 = side[1]
		var wall := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(a.distance_to(b), SKY_H)
		wall.mesh = qm
		wall.position = (a + b) * 0.5 + Vector3(0, SKY_H * 0.5, 0)
		var inward := Vector3(w * 0.5, 0, h * 0.5) - (a + b) * 0.5
		wall.rotation.y = atan2(inward.x, inward.z)
		wall.material_override = _glow(Color(0.42, 0.55, 1.0), WALL_GLOW, 0.0, _sky_tex())
		add_child(wall)

# --- the dark ------------------------------------------------------------------------------------------

func _process(delta: float) -> void:
	if lv == null:
		return
	_t += delta
	_apply(lv._level)
	for m: Array in _moths:
		var a: float = m[3] + _t * float(m[4])
		var c: Vector3 = m[1]
		(m[0] as Node3D).position = c + Vector3(cos(a) * float(m[2]), 0.1 * sin(a * 2.3), sin(a) * float(m[2]))
	for f: Array in _flies:
		var a: float = f[2] + _t * 0.6
		var c: Vector3 = f[1]
		(f[0] as Node3D).position = c + Vector3(sin(a) * 0.5, 0.25 * sin(a * 1.7), cos(a * 0.8) * 0.5)
		(f[0] as Node3D).visible = sin(a * 3.1) > -0.3
	_listen(delta)

var _last_k := -1.0

## The lamps and the sky by the light level (Level.set_light_level): out in the blackout, flickering in its warning.
func _apply(light: float) -> void:
	var k := smoothstep(0.1, 0.9, clampf(light, 0.0, 1.0))
	for i in lv.main_lights.size():
		lv.main_lights[i].light_energy = lv._base_energy[i] * k
		lv.main_lights[i].visible = k > 0.01
	if is_equal_approx(k, _last_k):
		return
	_last_k = k
	for gl: Array in _glows:
		(gl[0] as ShaderMaterial).set_shader_parameter("energy", lerpf(float(gl[2]), float(gl[1]), k))

# --- sound -----------------------------------------------------------------------------------------------

func _sounds() -> void:
	for cue: String in GardenSound.BED_CUES:
		var recording := _garden_audio.next(cue)
		if recording == null:
			continue
		var p := AudioStreamPlayer.new()
		p.bus = &"Ambience"
		p.stream = recording
		p.volume_db = -80.0
		add_child(p)
		_amb[cue] = p
	for k in 6:
		var sp := AudioStreamPlayer3D.new()
		sp.bus = &"Effects"
		sp.unit_size = 4.0
		sp.max_distance = 30.0
		sp.max_db = 0.0
		add_child(sp)
		_steps.append(sp)
	_own = AudioStreamPlayer.new()
	_own.bus = &"Effects"
	add_child(_own)

func _step_take(surface: String, creeping: bool) -> AudioStreamOggVorbis:
	if surface == "moss":
		return null if creeping else _garden_audio.next("step_moss")
	if surface == "gravel" or surface == "none":
		return _garden_audio.next("step_gravel")
	if creeping:
		var quiet_step := _garden_audio.next("step_creep")
		if quiet_step != null:
			return quiet_step
	return _garden_audio.next("step_leaves")

## One footstep of another player at `pos` (client/sfx.gd hands them over on this floor). True: played here.
func step_at(pos: Vector3, gain_db: float) -> bool:
	var surface := surface_at(pos.x, pos.z)
	var recording := _step_take(surface, gain_db < float(OthersView.STEP_DB["walk"]))
	if recording == null:
		return true
	var sp := _steps[_step_next]
	_step_next = (_step_next + 1) % _steps.size()
	sp.stream = recording
	sp.volume_db = Sfx.BASE_DB + gain_db
	sp.global_position = pos
	sp.play()
	return true

## A twig cracked at (x, z) (the host's "twigCrack" event): everyone hears it.
func crack(x: float, z: float) -> void:
	_ground_hit("twig", x, z)

func cone_landed(x: float, z: float) -> void:
	_ground_hit("pinecone_gravel" if surface_at(x, z) == "gravel" else "pinecone_leaves", x, z)

func cone_thrown(event: Dictionary) -> void:
	var from: Dictionary = event["from"]
	var at: Dictionary = event["at"]
	var start := Vector3(float(from["x"]), float(from["y"]) + 1.2, float(from["z"]))
	var end := Vector3(float(at["x"]), float(at["y"]) + 0.07, float(at["z"]))
	var cone := InventoryView.cone_mesh()
	cone.position = start
	add_child(cone)
	var flight := create_tween()
	flight.tween_method(func(alpha: float) -> void:
		cone.position = start.lerp(end, alpha) + Vector3.UP * (sin(PI * alpha) * minf(1.2, start.distance_to(end) * 0.15))
		cone.rotation.x = TAU * alpha
	, 0.0, 1.0, float(event["flight"]))
	flight.tween_callback(cone.queue_free)

func _ground_hit(cue: String, x: float, z: float) -> void:
	var recording := _garden_audio.next(cue)
	if recording == null:
		return
	var sp := _steps[_step_next]
	_step_next = (_step_next + 1) % _steps.size()
	sp.stream = recording
	sp.volume_db = Sfx.BASE_DB + 3.0
	sp.global_position = Vector3(x, 0.1, z)
	sp.play()

## This player's own footsteps, from how their eyes move over the ground, and the ring of silence.
func _listen(delta: float) -> void:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return
	var p := cam.global_position
	if _last_cam != Vector3.INF and delta > 0.0:
		var d := Vector2(p.x - _last_cam.x, p.z - _last_cam.z).length()
		var speed := d / delta
		if speed > 0.4 and speed < 9.0 and p.y > 0.9 and p.y < 2.2:
			var gait := "creep" if speed < 1.7 else ("walk" if speed < 3.9 else "sprint")
			_walked += d
			if _walked >= float(STRIDE[gait]):
				_walked = 0.0
				var surface := surface_at(p.x, p.z)
				var recording := _step_take(surface, gait == "creep")
				if recording != null:
					_own.stream = recording
					var creep_trim := -3.0 if recording.resource_path.get_file().begins_with("step_creep_") else -8.0
					_own.volume_db = Sfx.BASE_DB + (creep_trim if gait == "creep" else (0.0 if gait == "walk" else 4.0))
					_own.play()
		elif speed <= 0.4:
			_walked = minf(_walked, 0.3)
	_last_cam = p
	# The ring of silence.
	var want := 1.0
	if keeper != null and is_instance_valid(keeper) and keeper.has_acoustic_pose():
		want = smoothstep(HUSH_NEAR, HUSH_FAR, Vector2(p.x - keeper.global_position.x, p.z - keeper.global_position.z).length())
	_hush = move_toward(_hush, want, delta * 0.9)
	if keeper != null and is_instance_valid(keeper):
		keeper.heard_hush(_hush, delta)
	for cue: String in _amb:
		var bed: AudioStreamPlayer = _amb[cue]
		var share := 1.0 - _hush if cue == "quiet" else _hush
		var trim := -3.0 if cue == "crickets" or cue == "sprinkler" else 0.0
		bed.volume_db = Sfx.BASE_DB + trim + linear_to_db(maxf(share, 0.0001))
		if not bed.playing:
			bed.play()
