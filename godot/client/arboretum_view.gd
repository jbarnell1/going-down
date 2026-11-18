# The Arboretum as drawn (North Star A2: "A forest indoors, under a painted sky"; piece AR3). Dresses a Level
# whose plan is an Arboretum (Level.build hands over here): the ground by surface, thicket, trunks under a dark
# canopy, the landmarks each with its old park lamp, the brick lift pavilion, the painted sky with its panel
# seams, and the dark. Everything is made here from simple meshes and textures drawn in code (no files).
#
# The dark. The owner, 18 Nov: "the whole level should be pretty darn dark." The sky gives a deep blue dusk and
# almost no light; under the canopy it is close to black. The only real light is a lamp at each landmark (a
# pool about 6 m across) and the pavilion's. In the dark only the gravel shows (it keeps a faint pale glow of
# its own, as wet stone does under a night sky), so the walk is a pale line and a crew that learned where the
# moss ran can still find it. In the blackout the lamps and the sky go out; the gravel's glow and the fireflies
# by the fountain and the greenhouse stay. The near light (client/main.gd) is the player's own.
#
# Ground has a voice: moss is dark green and smooth, litter brown and mottled, gravel pale, a twig fall litter
# with pale sticks on it under its dead tree. surface_at() says what is under a point, from the same garden
# the host made (sim/arboretum.gd from the plan's seed and depth), and the footsteps are played from it.
#
# Sound, all stand-ins (client/garden_sound.gd lists them for the owner's recordings): wind, crickets and a
# sprinkler; footsteps by surface for this player and the others; a twig's crack. The ring of silence: within
# 10 m of the Groundskeeper the wind, the crickets and the sprinkler fall away (gone by 5 m), so the garden
# goes quiet round a player before they hear its badges.
# Nothing here is a rule: no collision, no noise (sim/noise.gd is the host's), no timing.
extends Node3D

const Arboretum = preload("res://sim/arboretum.gd")
const Noises = preload("res://sim/noise.gd")
const Floor = preload("res://sim/floor.gd")
const Furniture = preload("res://sim/furniture.gd")
const Hides = preload("res://sim/hides.gd")
const GardenSound = preload("res://client/garden_sound.gd")

const S := 2.0
const SKY_H := 12.0
const CHUNK := 4
const WALL_H := 3.0
const DOOR_W := 1.1
const DOOR_H := 2.1
## The ambient light, lit and in the blackout, and the fog (client/main.gd reads the level's).
const AMBIENT_LIT := Color(0.42, 0.6, 1.35)
const AMBIENT_DARK := Color(0.03, 0.04, 0.09)
const FOG := Color(0.004, 0.006, 0.014)
const FOG_DENSITY := 0.02
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

const C_MOSS := Color(0.16, 0.34, 0.11)
const C_LITTER := Color(0.36, 0.24, 0.13)
const C_GRAVEL := Color(0.8, 0.78, 0.72)
const C_BRICK := Color(0.5, 0.27, 0.2)
const C_THICKET := Color(0.1, 0.19, 0.1)
const C_BARK := Color(0.3, 0.23, 0.17)
const C_DEAD := Color(0.62, 0.6, 0.55)
const C_STICK := Color(0.72, 0.68, 0.58)
const C_IRON := Color(0.1, 0.12, 0.11)
const C_WOOD := Color(0.4, 0.3, 0.2)
const C_STONE := Color(0.55, 0.55, 0.52)
const C_GLASS := Color(0.5, 0.62, 0.55, 0.22)

var lv: Level
var fp: Floor.FloorPlan
var g: Arboretum.Garden
## The Groundskeeper's view, once the game has made it (client/groundskeeper_view.gd set_floor).
var keeper: Node3D = null
## What was drawn, for checks: counts by kind.
var drawn := {}

var _tools := {}          # [material key, chunk] -> SurfaceTool
var _mats := {}
var _glows: Array = []    # [ShaderMaterial, energy lit, energy in the blackout]
var _moths: Array = []    # [node, centre, radius, phase, speed]
var _flies: Array = []    # [node, centre, phase]
var _t := 0.0
var _rng := RandomNumberGenerator.new()
var _amb: Array[AudioStreamPlayer] = []
var _amb_db: Array[float] = []
var _steps: Array[AudioStreamPlayer3D] = []
var _step_next := 0
var _own: AudioStreamPlayer
var _walked := 0.0
var _last_cam := Vector3.INF
var _hush := 1.0

static var _tex := {}

## Dresses `level` as the Arboretum. Returns the view, kept as the level's "arboretum" meta and its child.
static func dress(level: Level) -> Node3D:
	var v: Node3D = new()
	v.name = "ArboretumView"
	v.process_priority = 1000
	v.call(&"_dress", level)
	return v

func _dress(level: Level) -> void:
	lv = level
	level.set_meta(&"arboretum", self)
	level.set_meta(&"near_light", NEAR_LIGHT)
	level.set_meta(&"near_light_gain", 1.7)
	level.set_meta(&"fog_color", FOG)
	level.set_meta(&"fog_density", FOG_DENSITY)
	level.add_child(self)
	level.shadows = false
	level.ambient_lit = AMBIENT_LIT
	level.ambient_dark = AMBIENT_DARK
	fp = Arboretum.generate_arboretum(str(level.plan.seed), int(level.plan.depth))
	g = Arboretum.garden_of(fp)
	_rng.seed = hash("arboretum-view:%s:%d" % [fp.seed, fp.depth])
	_ground()
	_thicket_and_walls()
	_pieces()
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
	return {"hash": Arboretum.floor_hash(fp), "lamps": lv.main_lights.size(), "landmarks": g.landmarks.size(), "drawn": drawn.duplicate(),
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

## A leaf card: blotches of leaf with gaps (alpha), for the canopy.
static func _leaf_tex() -> Texture2D:
	if _tex.has("leaf"):
		return _tex["leaf"]
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for k in 46:
		var c := Vector2(rng.randf_range(6, n - 6), rng.randf_range(6, n - 6))
		var r := rng.randf_range(4.0, 10.0)
		var shade := rng.randf_range(0.55, 1.0)
		for y in range(maxi(0, int(c.y - r)), mini(n, int(c.y + r) + 1)):
			for x in range(maxi(0, int(c.x - r)), mini(n, int(c.x + r) + 1)):
				if Vector2(x, y).distance_to(c) <= r and c.distance_to(Vector2(n / 2.0, n / 2.0)) < n * 0.47:
					img.set_pixel(x, y, Color(shade, shade, shade, 1.0))
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

func _tool(mat: String, at: Vector3) -> SurfaceTool:
	var key := [mat, int(floor(at.x / (S * CHUNK))), int(floor(at.z / (S * CHUNK)))]
	if not _tools.has(key):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_tools[key] = st
	return _tools[key]

func _quad(mat: String, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, col: Color, uvs := 1.0) -> void:
	var st := _tool(mat, (a + c) * 0.5)
	var pts := [a, b, c, a, c, d]
	var uv := [Vector2(0, 0), Vector2(uvs, 0), Vector2(uvs, uvs), Vector2(0, 0), Vector2(uvs, uvs), Vector2(0, uvs)]
	for i in 6:
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
		_quad(mat, mid + basis * (o - du - dv), mid + basis * (o + du - dv), mid + basis * (o + du + dv), mid + basis * (o - du + dv), basis * n, col)

func _commit() -> void:
	for key: Array in _tools:
		var st: SurfaceTool = _tools[key]
		var mi := MeshInstance3D.new()
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
	_lit("moss", _noise_tex("moss", 0.82, 0.3, 8, 11), 1.0, 0.85)
	_lit("litter", _noise_tex("litter", 0.7, 0.9, 2, 12), 2.0)
	# Gravel keeps a faint pale light of its own: the one thing that shows in the dark.
	_lit("gravel", _noise_tex("gravel", 0.8, 0.5, 1, 13), 3.0, 1.0, Color(0.12, 0.125, 0.14))
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
			col = col * (0.86 + 0.28 * _hash01(x, y, 3))
			col.a = 1.0
			var x0 := x * S
			var z0 := y * S
			_quad(mat, Vector3(x0, 0, z0), Vector3(x0 + S, 0, z0), Vector3(x0 + S, 0, z0 + S), Vector3(x0, 0, z0 + S), Vector3.UP, col)
			drawn[Noises.SURFACE_NAMES[s]] = int(drawn.get(Noises.SURFACE_NAMES[s], 0)) + 1
			if s == Noises.TWIG:
				# Pale sticks on the litter.
				for k in 9:
					var p := Vector3(x0 + S * _hash01(x, y, 10 + k), 0.012, z0 + S * _hash01(x, y, 30 + k))
					_box("stick", Vector3(0.28 + 0.4 * _hash01(x, y, 50 + k), 0.022, 0.03), p, C_STICK * (0.75 + 0.25 * _hash01(x, y, 70 + k)), true, TAU * _hash01(x, y, 90 + k))

# --- thicket, and the hall's wall behind its hedge -----------------------------------------------------

func _thicket_and_walls() -> void:
	_lit("thicket", _noise_tex("thicket", 0.7, 0.9, 2, 21), 2.0)
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
			var cx := (x + 0.5) * S
			var cz := (y + 0.5) * S
			var top := 2.5 + 1.1 * _hash01(x, y, 1)
			var col := C_THICKET * (0.7 + 0.6 * _hash01(x, y, 2))
			col.a = 1.0
			_box("thicket", Vector3(S, top, S), Vector3(cx, 0, cz), col)
			# Lumps and sprays breaking the top and the faces: a mass, not a wall.
			for k in 4:
				var off := Vector3((_hash01(x, y, 20 + k) - 0.5) * 1.5, 0, (_hash01(x, y, 30 + k) - 0.5) * 1.5)
				var sz := Vector3(0.7 + 0.6 * _hash01(x, y, 40 + k), 0.5 + 0.9 * _hash01(x, y, 50 + k), 0.7 + 0.6 * _hash01(x, y, 60 + k))
				_box("thicket", sz, Vector3(cx, top - 0.2, cz) + off, col * 1.25, true, TAU * _hash01(x, y, 70 + k))
			drawn["thicket"] = int(drawn.get("thicket", 0)) + 1

# --- what stands on the ground: trunks, dead trees, lamp posts, the small landmarks' pieces, the hides -----

func _pieces() -> void:
	_lit("bark", _noise_tex("bark", 0.75, 0.5, 2, 31), 1.0)
	_lit("leaf", _leaf_tex(), 1.0, 1.0, Color.BLACK, true, true)
	_lit("iron", null, 1.0, 0.6)
	_lit("wood", _noise_tex("wood", 0.8, 0.4, 4, 32), 1.0)
	_lit("stone", _noise_tex("stone", 0.8, 0.4, 2, 33), 1.0)
	for p in Furniture.pieces_for(fp):
		var at := Vector3(p.x / 100.0, 0, p.y / 100.0)
		var r := _hash01(p.x, p.y, 5)
		match p.kind:
			&"trunk":
				var tall := 6.5 + 3.0 * r
				var thick := 0.2 + 0.1 * _hash01(p.x, p.y, 6)
				var col := C_BARK * (0.7 + 0.6 * r)
				col.a = 1.0
				_box("bark", Vector3(thick, tall, thick), at, col, true, TAU * r)
				# The canopy: dark cards of leaf above eye level, and a higher one.
				var lc := Color(0.07, 0.13, 0.07) * (0.6 + 0.8 * _hash01(p.x, p.y, 7))
				lc.a = 1.0
				for k in 2:
					var hy := 3.6 + 1.6 * _hash01(p.x, p.y, 8 + k) + k * 1.4
					var half := 1.5 + 0.9 * _hash01(p.x, p.y, 10 + k)
					var c := at + Vector3((_hash01(p.x, p.y, 12 + k) - 0.5) * 0.8, hy, (_hash01(p.x, p.y, 14 + k) - 0.5) * 0.8)
					_quad("leaf", c + Vector3(-half, 0, -half), c + Vector3(half, 0, -half), c + Vector3(half, 0.3 * (r - 0.5), half), c + Vector3(-half, 0.25, half), Vector3.DOWN, lc)
				drawn["trunk"] = int(drawn.get("trunk", 0)) + 1
			&"dead_tree":
				# Bare and pale, taller than its neighbours, a few broken limbs.
				_box("bark", Vector3(0.42, 8.5, 0.42), at, C_DEAD, true, 0.4)
				for k in 4:
					var hy := 3.0 + 1.3 * k
					_box("bark", Vector3(1.6 + 0.5 * _hash01(p.x, p.y, 20 + k), 0.12, 0.12), at + Vector3(0, hy, 0), C_DEAD * 0.9, false, TAU * _hash01(p.x, p.y, 30 + k), Vector3(0, 0, 0.5))
				drawn["dead_tree"] = int(drawn.get("dead_tree", 0)) + 1
			&"lamp":
				_lamp(at, true)
			&"fountain":
				for k in 4:
					var a := k * PI * 0.5
					_box("stone", Vector3(1.2, 0.42, 0.16), at + Vector3(sin(a), 0, cos(a)) * 0.52, C_STONE, true, a)
				_box("stone", Vector3(0.3, 0.95, 0.3), at, C_STONE * 0.9)
				_box("stone", Vector3(0.62, 0.1, 0.62), at + Vector3(0, 0.95, 0), C_STONE)
				_fireflies(at + Vector3(0, 0.9, 0))
			&"statue":
				_box("stone", Vector3(0.62, 0.5, 0.56), at + Vector3(-0.26, 0, 0), C_STONE * 0.85)
				_box("stone", Vector3(1.05, 0.3, 0.34), at + Vector3(0.12, 0.12, 0.06), C_STONE, true, 0.25, Vector3(0, 0, 0.12))
				_box("stone", Vector3(0.24, 0.24, 0.24), at + Vector3(0.52, 0.02, -0.2), C_STONE * 1.1, true, 0.7)
			&"arch":
				for sx: float in [-0.5, 0.5]:
					_box("iron", Vector3(0.09, 2.2, 0.09), at + Vector3(sx, 0, 0), C_IRON * 1.6)
				_box("iron", Vector3(1.1, 0.08, 0.3), at + Vector3(0, 2.2, 0), C_IRON * 1.6)
				for k in 7:
					_box("thicket", Vector3(0.16, 0.22, 0.34), at + Vector3(-0.5 + k * 0.165, 2.1 + 0.22 * sin(k * 0.52), 0), Color(0.05, 0.03, 0.03), true, r + k)
			&"sundial":
				_box("stone", Vector3(0.36, 0.95, 0.36), at, C_STONE)
				_box("stone", Vector3(0.74, 0.07, 0.74), at + Vector3(0, 0.95, 0), C_STONE * 1.1)
				_box("iron", Vector3(0.03, 0.26, 0.3), at + Vector3(0, 1.02, 0), C_IRON * 2.5, true, 0, Vector3(0.5, 0, 0))
			&"shed":
				var f := _facing(p.facing)
				_box("wood", Vector3(0.9, 1.9, 0.58), at, C_WOOD, true, atan2(f.x, f.z))
				_box("wood", Vector3(0.74, 1.7, 0.04), at + f * 0.3 + Vector3(0, 0.06, 0), C_WOOD * 0.55, true, atan2(f.x, f.z) + 0.16)
				_box("wood", Vector3(1.0, 0.07, 0.72), at + Vector3(0, 1.9, 0), C_WOOD * 0.7, true, atan2(f.x, f.z), Vector3(0.12, 0, 0))
			&"bench":
				var f := _facing(p.facing)
				var yaw := atan2(f.x, f.z)
				_box("wood", Vector3(1.8, 0.07, 0.6), at + Vector3(0, 0.78, 0), C_WOOD * 1.1, true, yaw)
				for sx: float in [-0.84, 0.84]:
					_box("wood", Vector3(0.07, 0.78, 0.56), at + Basis.from_euler(Vector3(0, yaw, 0)) * Vector3(sx, 0, 0), C_WOOD * 0.8, true, yaw)
				_box("wood", Vector3(1.8, 0.4, 0.03), at + f * 0.29 + Vector3(0, 0.38, 0), Color(0.16, 0.17, 0.13), true, yaw)   # sacking hung across the front
			&"under":
				var f := _facing(p.facing)
				_box("wood", Vector3(1.2, 0.5, 0.06), at + f * 0.24, Color(0.015, 0.012, 0.01), true, atan2(f.x, f.z))
			&"log":
				# A hollow log lying along the thicket: a ring of bark round a dark mouth.
				var f := _facing(p.facing)
				var yaw := atan2(f.x, f.z)
				var b := Basis.from_euler(Vector3(0, yaw, 0))
				for k in 8:
					var a := k * TAU / 8.0
					_box("bark", Vector3(1.6, 0.11, 0.22), at + Vector3(0, 0.27, 0) + b * Vector3(0, sin(a) * 0.22, cos(a) * 0.2), C_BARK * 1.5, false, yaw, Vector3(a, 0, 0))
				_box("bark", Vector3(1.5, 0.3, 0.3), at + Vector3(0, 0.12, 0), Color(0.012, 0.01, 0.008), true, yaw)

static func _facing(f: StringName) -> Vector3:
	return Vector3(float(Floor.dir_dx(f)), 0, float(Floor.dir_dy(f)))

## An old park lamp: a post with a lantern (or, on the pavilion, the lantern on its wall), its warm pool, moths.
func _lamp(at: Vector3, post: bool) -> void:
	var head := at + Vector3(0, 2.75 if post else 2.45, 0)
	if post:
		_box("iron", Vector3(0.09, 2.7, 0.09), at, C_IRON * 1.5)
		_box("iron", Vector3(0.2, 0.12, 0.2), at, C_IRON * 1.5)
		_box("iron", Vector3(0.34, 0.05, 0.34), head + Vector3(0, 0.16, 0), C_IRON * 1.5, false)
	var lantern := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.2, 0.26, 0.2)
	lantern.mesh = bm
	lantern.position = head
	lantern.material_override = _glow(LAMP, 2.4, 0.0)
	add_child(lantern)
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
	_lit("glass", null, 1.0, 0.1, Color(0.01, 0.014, 0.012), true, true)
	var W := Arboretum.W
	for l in g.landmarks:
		drawn["landmark"] = int(drawn.get("landmark", 0)) + 1
		if l.building < 0:
			continue
		var at := Vector3((l.building % W + 0.5) * S, 0, (l.building / W + 0.5) * S)
		match l.kind:
			&"greenhouse":
				_box("stone", Vector3(S, 0.5, S), at, C_BRICK)
				for k in 4:
					var a := k * PI * 0.5
					_box("glass", Vector3(S - 0.1, 1.7, 0.03), at + Vector3(sin(a), 0, cos(a)) * 0.97 + Vector3(0, 0.5, 0), C_GLASS, true, a)
					_box("iron", Vector3(0.06, 2.2, 0.06), at + Vector3(sin(a + 0.785), 0, cos(a + 0.785)) * 1.38, Color(0.5, 0.52, 0.48))
				for sx: float in [-1.0, 1.0]:
					_box("glass", Vector3(1.12, 0.03, S), at + Vector3(sx * 0.5, 2.5, 0), C_GLASS, false, 0, Vector3(0, 0, sx * 0.5))
				_box("iron", Vector3(0.06, 0.06, S), at + Vector3(0, 2.76, 0), Color(0.5, 0.52, 0.48), false)
				_fireflies(at + Vector3(0, 1.0, 0))
			&"bandstand":
				_box("wood", Vector3(S, 0.55, S), at, C_WOOD * 0.8)
				for k in 4:
					var a := k * PI * 0.5 + 0.785
					_box("wood", Vector3(0.1, 2.2, 0.1), at + Vector3(sin(a), 0, cos(a)) * 1.3 + Vector3(0, 0.55, 0), Color(0.5, 0.48, 0.42))
				for k in 4:
					_box("wood", Vector3(2.5 - k * 0.6, 0.16, 2.5 - k * 0.6), at + Vector3(0, 2.75 + k * 0.16, 0), Color(0.1, 0.14, 0.12))
			&"sheds":
				_box("wood", Vector3(S, 2.3, S), at, C_WOOD * 0.9)
				_box("wood", Vector3(2.3, 0.1, 2.3), at + Vector3(0, 2.3, 0), C_WOOD * 0.55, true, 0, Vector3(0.1, 0, 0))
			&"aviary":
				for k in 12:
					var a := k * TAU / 12.0
					_box("iron", Vector3(0.035, 3.0, 0.035), at + Vector3(sin(a), 0, cos(a)) * 0.95, C_IRON * 2.2)
				for hy: float in [0.05, 1.5, 3.0]:
					for k in 12:
						var a := (k + 0.5) * TAU / 12.0
						_box("iron", Vector3(0.52, 0.035, 0.035), at + Vector3(sin(a), 0, cos(a)) * 0.92 + Vector3(0, hy, 0), C_IRON * 2.2, false, a)
				_box("iron", Vector3(0.03, 1.6, 0.03), at, C_IRON * 2.0)
				_box("iron", Vector3(0.7, 0.03, 0.03), at + Vector3(0, 1.6, 0), C_IRON * 2.0, false)
			&"lodge":
				_box("stone", Vector3(S, 2.4, S), at, C_BRICK * 0.9)
				for sx: float in [-1.0, 1.0]:
					_box("wood", Vector3(1.25, 0.08, 2.3), at + Vector3(sx * 0.52, 2.72, 0), Color(0.1, 0.1, 0.11), false, 0, Vector3(0, 0, sx * 0.55))
				_box("wood", Vector3(0.6, 0.7, 0.04), at + Vector3(0.3, 1.1, 1.0), Color(0.01, 0.012, 0.016))

# --- the lift pavilion ----------------------------------------------------------------------------------

func _pavilion() -> void:
	var lx := fp.landing.x
	var x0 := (lx - 1) * S
	var x1 := (lx + 2) * S
	var z0 := Arboretum.Y0 * S
	var z1 := (Arboretum.Y0 + 2) * S
	var t := 0.16
	var col := C_BRICK
	# The back wall, with the lift's doorway in it; the two sides; the front, with the one doorway.
	var half := lv.lift_half
	var mid := (lx + 0.5) * S
	_box("stone", Vector3(mid - half - x0, WALL_H, t), Vector3((x0 + mid - half) * 0.5, 0, z0), col)
	_box("stone", Vector3(x1 - mid - half, WALL_H, t), Vector3((x1 + mid + half) * 0.5, 0, z0), col)
	_box("stone", Vector3(half * 2.0, WALL_H - Level.LIFT_H, t), Vector3(mid, Level.LIFT_H, z0), col)
	_box("stone", Vector3(t, WALL_H, z1 - z0), Vector3(x0, 0, (z0 + z1) * 0.5), col)
	_box("stone", Vector3(t, WALL_H, z1 - z0), Vector3(x1, 0, (z0 + z1) * 0.5), col)
	_box("stone", Vector3(mid - DOOR_W * 0.5 - x0, WALL_H, t), Vector3((x0 + mid - DOOR_W * 0.5) * 0.5, 0, z1), col)
	_box("stone", Vector3(x1 - mid - DOOR_W * 0.5, WALL_H, t), Vector3((x1 + mid + DOOR_W * 0.5) * 0.5, 0, z1), col)
	_box("stone", Vector3(DOOR_W, WALL_H - DOOR_H, t), Vector3(mid, DOOR_H, z1), col)
	# A flat roof with a lip, and the lantern over the door.
	_box("stone", Vector3(x1 - x0 + 0.5, 0.18, z1 - z0 + 0.5), Vector3((x0 + x1) * 0.5, WALL_H, (z0 + z1) * 0.5), col * 0.6)
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
	var sky := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(w, h)
	pm.flip_faces = true
	sky.mesh = pm
	sky.position = Vector3(w * 0.5, SKY_H, h * 0.5)
	sky.material_override = _glow(Color(0.5, 0.62, 1.0), 0.42, 0.0, _sky_tex())
	add_child(sky)
	# The hall's walls: the same painted dusk coming down to a dark horizon behind the hedge.
	var x0 := (Arboretum.X0 - 1) * S
	var x1 := (Arboretum.X1 + 2) * S
	var z0 := (Arboretum.Y0 - 1) * S
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
		wall.material_override = _glow(Color(0.42, 0.55, 1.0), 0.26, 0.0, _sky_tex())
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
	for spec: Array in [["wind", -15.0], ["crickets", -20.0], ["sprinkler", -27.0]]:
		var p := AudioStreamPlayer.new()
		p.bus = &"Ambience"
		p.stream = GardenSound.stream(spec[0])
		p.volume_db = spec[1]
		add_child(p)
		_amb.append(p)
		_amb_db.append(spec[1])
	for k in 6:
		var sp := AudioStreamPlayer3D.new()
		sp.bus = &"Effects"
		sp.unit_size = 4.0
		sp.max_distance = 30.0
		add_child(sp)
		_steps.append(sp)
	_own = AudioStreamPlayer.new()
	_own.bus = &"Effects"
	add_child(_own)

static func _step_name(surface: String, k: int) -> String:
	var kind := "gravel" if (surface == "gravel" or surface == "none") else ("moss" if surface == "moss" else "leaves")
	return "step_%s_%d" % [kind, 1 + k % 4]

## One footstep of another player at `pos` (client/sfx.gd hands them over on this floor). True: played here.
func step_at(pos: Vector3, gain_db: float) -> bool:
	var surface := surface_at(pos.x, pos.z)
	if surface == "moss" and gain_db < -3.0:
		return true   # a creep on moss is silent
	var sp := _steps[_step_next]
	_step_next = (_step_next + 1) % _steps.size()
	sp.stream = GardenSound.stream(_step_name(surface, _rng.randi()))
	sp.volume_db = -6.0 + gain_db + (-8.0 if surface == "moss" else 0.0)
	sp.pitch_scale = 0.92 + _rng.randf() * 0.16
	sp.global_position = pos
	sp.play()
	return true

## A twig cracked at (x, z) (the host's "twigCrack" event): everyone hears it.
func crack(x: float, z: float) -> void:
	var sp := _steps[_step_next]
	_step_next = (_step_next + 1) % _steps.size()
	sp.stream = GardenSound.stream("twig_%d" % _rng.randi_range(1, 3))
	sp.volume_db = 4.0
	sp.pitch_scale = 0.95 + _rng.randf() * 0.1
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
				if not (surface == "moss" and gait == "creep"):
					_own.stream = GardenSound.stream(_step_name(surface, _rng.randi()))
					_own.volume_db = (-13.0 if gait == "creep" else (-5.0 if gait == "walk" else -1.0)) + (-9.0 if surface == "moss" else 0.0)
					_own.pitch_scale = 0.92 + _rng.randf() * 0.16
					_own.play()
		elif speed <= 0.4:
			_walked = minf(_walked, 0.3)
	_last_cam = p
	# The ring of silence.
	var want := 1.0
	if keeper != null and is_instance_valid(keeper) and keeper.visible:
		want = smoothstep(HUSH_NEAR, HUSH_FAR, Vector2(p.x - keeper.global_position.x, p.z - keeper.global_position.z).length())
	_hush = move_toward(_hush, want, delta * 0.9)
	for i in _amb.size():
		if not _amb[i].playing:
			_amb[i].play()
		_amb[i].volume_db = _amb_db[i] + linear_to_db(maxf(_hush, 0.0005))
