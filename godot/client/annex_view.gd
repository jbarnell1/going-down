# The Annex dressed: what Level draws when plan.place is "annex" (the design, sections 1, 2 and 5;
# the plan comes from sim/annex.gd). An endless yellow office under humming lights: yellowed cream
# walls, mustard carpet, grey ceiling tiles, every panel on, a flat pale green-white light and a pale
# haze where the Clinic has dark fog. Nothing dark, nothing red, and no clean or dirty side: the
# Clinic's gradient is a compass, and the Annex gives no directions.
#
# - Rooms repeat, truly: a room's dressing (props, posters, clock, its lights and panels) is chosen from
#   its shape alone, never its position. The shape is the room's kind, its size and every opening in its
#   walls, read in the one of its eight turnings and mirrorings that gives the smallest key (`shape_of`).
#   The props are laid out in that canonical frame, from a generator seeded by the key, and carried into
#   the world by the room's own symmetry. `same_shape_problems` is the check.
# - The building's LIFT signs loop by a fixed rule (`lift_arrow`): at every junction of three or more
#   ways, a sign hangs on each way in and points along the way that turns furthest clockwise round the
#   middle of the lattice. Following them walks you round in a circle; they never point into the lobby.
#   They are the same for everyone (they come from the plan) and roll nothing.
# - Door numbers repeat: a door's number comes from its room's shape.
# - Emergency lighting (Level.set_emergency, driven by the run's blackout as for the Clinic): green
#   running-man signs over every door, green arrows under the LIFT signs (the same looping rule) and a
#   pale green spotlight over every junction.
# - Furniture (sim/furniture.gd, FD7): every floor-standing piece is drawn from the rules' one list, which is
#   also what blocks a player and what hides them; the list is the same for same-shaped rooms. Only the
#   pictures (posters, clocks, maps, whiteboards) are still laid out here, by the shape, kept off the walls
#   behind tall pieces.
# - Hiding places (sim/hides.gd, T19b; docs/floors/traits-and-hiding.md section 4): a desk in every office
#   (it is the office's desk), four in the cubicles, one in the break room; a tall slatted cabinet in every
#   closet and store (and wherever the rules topped one up); the meeting room's table is its hide. They
#   come from the rules' list, which is the same for same-shaped rooms, so the dressing stays alike; the
#   other props are laid out round them.
# Not here yet: the Temp's light sag (needs the Temp), sound.
#
# Everything reuses Level's geometry helpers (its chunked SurfaceTools, wall slabs, door openings) and
# its light dials (main_lights, panels, emergency_nodes, emergency_lights), so Level.update_lights,
# set_light_level and set_emergency drive the Annex unchanged. The lit materials register as panels,
# so their baked-in light falls with the real lights in a blink or a blackout.
extends RefCounted

const S := 2.0
const LH := 3.2
const WALL_T := 0.14
const DOOR_H := 2.1
## Where a prop's back stands: the wall face (half the drawn wall) plus a margin.
const INSET := WALL_T * 0.5 + 0.06
const PANEL_COL := Color(0.92, 1.0, 0.9)
const LIGHT_COL := Color(0.9, 1.0, 0.86)
## The real lights (see _panels_and_lights). A corridor run's lights stand about CORRIDOR_SPACING
## apart: wide downward spots reaching CORRIDOR_REACH, falling off gently (decay 1 is Godot's default,
## lower is flatter). A big room's one light is an omni. FLAT lifts the baked-in light to make up for
## the fewer real lights.
const CORRIDOR_SPACING := 12.0
const CORRIDOR_REACH := 11.0
const CORRIDOR_ENERGY := 0.45
const LIGHT_DECAY := 0.5
const ROOM_ENERGY := 0.13
const SPOT_ENERGY := 0.25
const FLAT := 1.2
## The renderer's limit on lights a frame (project.godot limits/opengl/max_renderable_lights).
const LIGHT_LIMIT := 256
## Brighter than white: Level sets every emergency light to the same low energy.
const EMERGENCY_COL := Color(1.2, 1.7, 1.25)
## The ambient light in the dark with the emergency lighting on (Level.ambient_color): green like the
## emergency lights, where the Clinic's goes red. Nothing red in the Annex.
const AMBIENT_DARK := Color(0.15, 0.45, 0.2)
const HAZE := Color(0.64, 0.58, 0.36)
const HAZE_DENSITY := 0.016
## n, e, s, w as plan steps (x right, y down the map).
const DIRS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
const PLAQUES: Array[String] = ["301", "302", "304", "307", "311", "312", "315", "318"]
const Playroom = preload("res://sim/playroom.gd")
const Hides = preload("res://sim/hides.gd")
const AnnexPlan = preload("res://sim/annex.gd")
const FloorLib = preload("res://sim/floor.gd")
const Furniture = preload("res://sim/furniture.gd")

var lv: Level
var W := 0
var H := 0
## room id -> Shape.
var shapes := {}
## Every prop and wall picture placed in a room: {room, type, xf (Transform3D in the world)}.
var records: Array[Dictionary] = []
## Hanging LIFT signs: {level, pos (Vector3, the sign's face), facing (Vector3, toward its reader), arrow}.
var signs: Array[Dictionary] = []
## Junctions of three or more ways: {level, cell (Vector2i), exits (Array[Vector2i]), arrow (Vector2i)}.
var junctions: Array[Dictionary] = []
var centre := Vector2.ZERO
## The floor's hiding places (sim/hides.gd), and the furniture drawn for them: {hide, kind, level, xf}.
var hides: Array[Playroom.Hide] = []
var hide_pieces: Array[Dictionary] = []

var mat_wall: ShaderMaterial
var mat_floor: ShaderMaterial
var mat_ceiling: ShaderMaterial
var mat_props: ShaderMaterial
var mat_stair: ShaderMaterial
var mat_decal: ShaderMaterial
var mat_panel: ShaderMaterial
var mat_exit: ShaderMaterial

static var _tex := {}
static var _catalogue_cache := {}

## Dresses `level` (built up to its room index by Level.build) as the Annex. Returns the view, also kept
## as the level's "annex" meta for tests and the demo.
static func dress(level: Level, source_plan: FloorLib.FloorPlan = null, source_hides: Array[Playroom.Hide] = []) -> RefCounted:
	var v := new()
	v.lv = level
	v.W = level.W
	v.H = level.H
	level.set_meta("annex", v)
	# Flat, even light: no hard shadows from the panels.
	level.shadows = false
	level.ambient_dark = AMBIENT_DARK
	v._materials()
	v._floors_and_ceilings()
	v._walls()
	v._stairs()
	v._find_junctions()
	for r: Dictionary in level.plan.rooms:
		v.shapes[int(r.id)] = shape_of(level, r)
	v._panels_and_lights()
	v._signs()
	if source_plan == null:
		source_plan = AnnexPlan.generate_annex(str(level.plan.seed), int(level.plan.depth))
	if source_hides.is_empty():
		source_hides = Hides.hides_for(source_plan, str(level.plan.seed))
	v.hides = source_hides
	# The furniture is the rules' (sim/furniture.gd): drawn whatever props_on says, since it blocks you.
	v._furniture(source_plan)
	if level.props_on:
		v._pictures()
	v._commit()
	return v

# --- textures ----------------------------------------------------------------

static func _finish(img: Image) -> Texture2D:
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

## The same mustard loop pile in every room, with the nap running along the same axis.
static func carpet_tex() -> Texture2D:
	return preload("res://assets/textures/annex_carpet.png")

## Wallpaper: 2 m across, the whole storey high (Level's wall UVs), skirting at the bottom.
static func wall_tex() -> Texture2D:
	if _tex.has("wall"):
		return _tex["wall"]
	var rng := RandomNumberGenerator.new()
	rng.seed = 3102
	var img := Image.create(64, 128, false, Image.FORMAT_RGB8)
	var base := Color(0.88, 0.8, 0.5)
	for y in 128:
		for x in 64:
			var c := base * (1.0 + rng.randf_range(-0.018, 0.018))
			if x % 16 == 0:
				c = c * 0.95
			if y >= 100:
				c = c * (1.0 - (y - 100) * 0.0025)
			if y >= 123:
				c = Color(0.46, 0.4, 0.3)
			elif y == 122:
				c = Color(0.36, 0.32, 0.24)
			img.set_pixel(x, y, c)
	_tex["wall"] = _finish(img)
	return _tex["wall"]

## Suspended ceiling: three by three grey tiles to a 2 m cell.
static func ceiling_tex() -> Texture2D:
	if _tex.has("ceiling"):
		return _tex["ceiling"]
	var rng := RandomNumberGenerator.new()
	rng.seed = 3103
	var img := Image.create(64, 64, false, Image.FORMAT_RGB8)
	var base := Color(0.72, 0.72, 0.68)
	for y in 64:
		for x in 64:
			var c := base * (1.0 + rng.randf_range(-0.02, 0.02))
			if rng.randf() < 0.06:
				c = c * 0.88
			if x % 21 == 0 or y % 21 == 0:
				c = Color(0.55, 0.55, 0.52)
			img.set_pixel(x, y, c)
	_tex["ceiling"] = _finish(img)
	return _tex["ceiling"]

## The signs and pictures, one 256 x 256 atlas. Rects in pixels (ATLAS).
const ATLAS := {
	"lift_straight": Rect2i(0, 0, 64, 32), "lift_left": Rect2i(64, 0, 64, 32), "lift_right": Rect2i(128, 0, 64, 32),
	"exit_straight": Rect2i(0, 32, 64, 32), "exit_left": Rect2i(64, 32, 64, 32), "exit_right": Rect2i(128, 32, 64, 32),
	"exit_man": Rect2i(192, 32, 64, 32),
	"poster": Rect2i(0, 96, 48, 64), "map": Rect2i(64, 96, 64, 64), "clock": Rect2i(128, 96, 32, 32),
	"whiteboard": Rect2i(160, 96, 96, 48),
}

static func plaque_rect(i: int) -> Rect2i:
	return Rect2i(32 * i, 64, 32, 16)

static func atlas_uv(r: Rect2i) -> Rect2:
	return Rect2(r.position.x / 256.0, r.position.y / 256.0, r.size.x / 256.0, r.size.y / 256.0)

static func _arrow(img: Image, c: Vector2i, s: int, dir: Vector2i, col: Color) -> void:
	var perp := Vector2i(-dir.y, dir.x)
	for p in range(-s, s + 1):
		for q in range(-s, s + 1):
			var inside := (p >= 0 and absi(q) <= s - p) or (p < 0 and absi(q) <= maxi(1, s / 3))
			if inside:
				var at := c + dir * p + perp * q
				img.set_pixel(at.x, at.y, col)

static func _frame(img: Image, r: Rect2i, edge: Color, fill: Color, t := 1) -> void:
	img.fill_rect(r, edge)
	img.fill_rect(r.grow(-t), fill)

const RUNNER: Array[String] = [
	"....##....", "....##....", "..####....", ".#.###.#..", "#..####...", "...###....",
	"...#..#...", "..#....#..", ".#.....#..", "#.......#.",
]

static func atlas_tex() -> Texture2D:
	if _tex.has("atlas"):
		return _tex["atlas"]
	var img := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.85, 0.82, 0.7))
	var slate := Color(0.16, 0.2, 0.22)
	var cream := Color(0.95, 0.92, 0.8)
	var green := Color(0.08, 0.62, 0.3)
	var white := Color(0.95, 1.0, 0.95)
	for name: String in ["straight", "left", "right"]:
		var dir := Vector2i(0, -1) if name == "straight" else (Vector2i(-1, 0) if name == "left" else Vector2i(1, 0))
		var r: Rect2i = ATLAS["lift_" + name]
		_frame(img, r, cream, slate, 2)
		PixelFont.blit(img, "LIFT", r.position + Vector2i(5, 9), cream, Vector2i(1, 2))
		_arrow(img, r.position + Vector2i(46, 16), 9, dir, cream)
		var e: Rect2i = ATLAS["exit_" + name]
		_frame(img, e, white, green, 2)
		PixelFont.blit(img, "EXIT", e.position + Vector2i(5, 9), white, Vector2i(1, 2))
		_arrow(img, e.position + Vector2i(46, 16), 9, dir, white)
	var m: Rect2i = ATLAS["exit_man"]
	_frame(img, m, white, green, 2)
	for y in RUNNER.size():
		for x in RUNNER[y].length():
			if RUNNER[y][x] == "#":
				img.fill_rect(Rect2i(m.position.x + 6 + x * 2, m.position.y + 6 + y * 2, 2, 2), white)
	img.fill_rect(Rect2i(m.position.x + 30, m.position.y + 5, 3, 22), white)
	PixelFont.blit(img, "EXIT", m.position + Vector2i(36, 12), white)
	for i in PLAQUES.size():
		var p := plaque_rect(i)
		_frame(img, p, Color(0.3, 0.27, 0.2), Color(0.78, 0.68, 0.42))
		PixelFont.blit(img, PLAQUES[i], p.position + Vector2i(8, 4), Color(0.18, 0.15, 0.1))
	# The same motivational poster in every office.
	var po: Rect2i = ATLAS["poster"]
	_frame(img, po, Color(0.12, 0.12, 0.14), Color(0.22, 0.3, 0.4), 3)
	for y in range(po.position.y + 14, po.position.y + 42):
		var half := (y - po.position.y - 14) * 2 / 3
		img.fill_rect(Rect2i(po.position.x + 24 - half, y, half * 2 + 1, 1), Color(0.55, 0.6, 0.62))
	img.fill_rect(Rect2i(po.position.x + 3, po.position.y + 46, 42, 15), Color(0.12, 0.12, 0.14))
	PixelFont.blit(img, "TEAM", po.position + Vector2i(13, 50), cream)
	# The one "you are here" map, its dot always in the same place.
	var mp: Rect2i = ATLAS["map"]
	_frame(img, mp, Color(0.25, 0.25, 0.25), cream, 2)
	for j in 4:
		for i in 4:
			img.fill_rect(Rect2i(mp.position.x + 6 + i * 13, mp.position.y + 6 + j * 11, 10, 8), Color(0.86, 0.74, 0.36))
	img.fill_rect(Rect2i(mp.position.x + 24, mp.position.y + 30, 5, 5), Color(0.1, 0.25, 0.75))
	PixelFont.blit(img, "HERE", mp.position + Vector2i(20, 53), Color(0.1, 0.25, 0.75))
	# The clock: every clock shows ten to five.
	var ck: Rect2i = ATLAS["clock"]
	for y in 32:
		for x in 32:
			var d := Vector2(x - 15.5, y - 15.5).length()
			if d <= 15.5:
				img.set_pixel(ck.position.x + x, ck.position.y + y, Color(0.15, 0.15, 0.15) if d > 13.5 else Color(0.97, 0.96, 0.9))
	for t in 9:
		img.set_pixel(ck.position.x + 16 + int(t * 0.5), ck.position.y + 16 + int(t * 0.3), Color(0.1, 0.1, 0.1))
	for t in 12:
		img.set_pixel(ck.position.x + 16 - int(t * 0.85), ck.position.y + 16 - int(t * 0.5), Color(0.1, 0.1, 0.1))
	var wb: Rect2i = ATLAS["whiteboard"]
	_frame(img, wb, Color(0.6, 0.6, 0.62), Color(0.96, 0.97, 0.96), 2)
	for k in 5:
		var y0 := wb.position.y + 8 + k * 7
		img.fill_rect(Rect2i(wb.position.x + 8, y0, 30 + (k * 17) % 40, 2), Color(0.15, 0.25, 0.6) if k % 2 == 0 else Color(0.15, 0.15, 0.15))
	img.generate_mipmaps()
	_tex["atlas"] = ImageTexture.create_from_image(img)
	return _tex["atlas"]

# --- materials --------------------------------------------------------------------------------

func _shade(tex: Texture2D, self_light: float, vcol := false, triplanar := false) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://client/annex_shade.gdshader")
	if tex:
		m.set_shader_parameter("albedo_tex", tex)
	m.set_shader_parameter("use_vcol", 1.0 if vcol else 0.0)
	m.set_shader_parameter("triplanar", 1.0 if triplanar else 0.0)
	m.set_shader_parameter("self_light", self_light)
	m.set_shader_parameter("energy", 1.0)
	m.set_shader_parameter("haze", HAZE)
	m.set_shader_parameter("haze_density", HAZE_DENSITY)
	# Level.update_lights sets "energy" on every panel material: these fall with the lights.
	lv.panels.append({"mat": m, "dead": false, "k": 1.0})
	return m

func _glow(col: Color, tex: Texture2D, haze: Color) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://client/annex_glow.gdshader")
	m.set_shader_parameter("color", col)
	m.set_shader_parameter("energy", 1.0)
	if tex:
		m.set_shader_parameter("tex", tex)
	m.set_shader_parameter("haze", haze)
	m.set_shader_parameter("haze_density", HAZE_DENSITY)
	return m

func _materials() -> void:
	mat_wall = _shade(wall_tex(), 0.42 * FLAT)
	mat_floor = _shade(carpet_tex(), 0.34 * FLAT)
	mat_ceiling = _shade(ceiling_tex(), 0.62 * FLAT)
	mat_props = _shade(null, 0.36 * FLAT, true)
	mat_stair = _shade(carpet_tex(), 0.34 * FLAT, false, true)
	mat_decal = _shade(atlas_tex(), 0.5 * FLAT)
	mat_panel = _glow(PANEL_COL, null, HAZE)
	lv.panels.append({"mat": mat_panel, "dead": false, "k": 1.0})
	mat_exit = _glow(Color(1.4, 1.4, 1.4), atlas_tex(), Color.BLACK)
	mat_exit.set_shader_parameter("energy", 0.0)

func _commit() -> void:
	for key: String in lv._chunks:
		var st: SurfaceTool = lv._chunks[key]
		var what := key.get_slice("_", 3)
		st.index()
		var mi := MeshInstance3D.new()
		mi.mesh = st.commit()
		mi.name = key
		match what:
			"awall", "arail": mi.material_override = mat_wall
			"afloor": mi.material_override = mat_floor
			"aceil": mi.material_override = mat_ceiling
			"aprops": mi.material_override = mat_props
			"astair": mi.material_override = mat_stair
			"adecal": mi.material_override = mat_decal
			"apanel":
				mi.material_override = mat_panel
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			"aexit":
				mi.material_override = mat_exit
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				mi.visible = false
				lv.emergency_nodes.append(mi)
		lv.add_child(mi)
	lv._chunks.clear()

# --- mesh helpers -------------------------------------------------------------------------------

## A quad, wound to face `n` whatever the order or mirroring of its corners.
static func quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, ua: Vector2, ub: Vector2, uc: Vector2, ud: Vector2, n: Vector3, col: Color) -> void:
	var vs: Array[Vector3] = [a, b, c, d]
	var us: Array[Vector2] = [ua, ub, uc, ud]
	if (b - a).cross(d - a).dot(n) > 0.0:
		vs = [a, d, c, b]
		us = [ua, ud, uc, ub]
	for i: int in [0, 1, 2, 0, 2, 3]:
		st.set_normal(n)
		st.set_color(col)
		st.set_uv(us[i])
		st.add_vertex(vs[i])

const _AXES: Array[Vector3] = [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.BACK, Vector3.FORWARD]

## A box (size, centre in xf's space), vertex coloured.
static func box(st: SurfaceTool, xf: Transform3D, size: Vector3, c: Vector3, col: Color) -> void:
	var h := size * 0.5
	for n: Vector3 in _AXES:
		var t1 := Vector3(n.y, n.z, n.x).abs()
		var t2 := n.abs().cross(t1)
		var f := c + n * h
		var e1 := t1 * h
		var e2 := t2 * h
		var nw := (xf.basis * n).normalized()
		quad(st, xf * (f - e1 - e2), xf * (f + e1 - e2), xf * (f + e1 + e2), xf * (f - e1 + e2),
			Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, nw, col)

## A flat picture facing `n` (toward its reader), upright, never mirrored.
static func picture(st: SurfaceTool, at: Vector3, n: Vector3, w: float, h: float, uv: Rect2, col := Color.WHITE) -> void:
	var r := (-n).cross(Vector3.UP).normalized() * (w * 0.5)
	var u := Vector3.UP * (h * 0.5)
	quad(st, at - r + u, at + r + u, at + r - u, at - r - u,
		uv.position, Vector2(uv.end.x, uv.position.y), uv.end, Vector2(uv.position.x, uv.end.y), n, col)

# --- floors, ceilings, walls, stairs ----------------------------------------------------------------

func _floors_and_ceilings() -> void:
	for y in H:
		for x in W:
			if lv.walkable(0, x, y):
				if lv.kind(0, x, y) != "stair":
					lv._floor_quad(0, x, y, 0.0, true, "afloor")
				var above := lv.kind(1, x, y)
				if above != "atriumOpen" and above != "stair":
					lv._floor_quad(0, x, y, LH - 0.001, false, "aceil")
			var k1 := lv.kind(1, x, y)
			if k1 == "corridor" or k1 == "room" or k1 == "landing":
				lv._floor_quad(1, x, y, LH, true, "afloor")
			if k1 == "corridor" or k1 == "room" or k1 == "atriumOpen" or k1 == "stair" or k1 == "landing":
				lv._floor_quad(1, x, y, 2 * LH - 0.001, false, "aceil")

# As Level._build_walls, without the Clinic's amber strips and red door glows.
func _walls() -> void:
	var lift_edge := lv._lift_edge()
	for level in 2:
		var vert: Array = lv.edges[level].vertical
		var hor: Array = lv.edges[level].horizontal
		for y in H:
			for x in W + 1:
				var k: String = vert[y * (W + 1) + x]
				var is_lift := level == lv.landing.x and lift_edge == Vector4i(0, x, y, 1)
				var before_v: String = vert[(y - 1) * (W + 1) + x] if y > 0 else "none"
				var after_v: String = vert[(y + 1) * (W + 1) + x] if y + 1 < H else "none"
				for piece: Array in lv._edge_parts(level, k, is_lift):
					var what := "arail" if piece.size() > 3 else "awall"
					lv._wall_edge(level, x * S, y * S, x * S, (y + 1) * S, Vector2i(x - 1, y), Vector2i(x, y), piece[0], piece[1], piece[2], what, lv._ext(k, before_v), lv._ext(k, after_v))
		for y in H + 1:
			for x in W:
				var k: String = hor[y * W + x]
				var is_lift := level == lv.landing.x and lift_edge == Vector4i(1, x, y, 1)
				var before_h: String = hor[y * W + x - 1] if x > 0 else "none"
				var after_h: String = hor[y * W + x + 1] if x + 1 < W else "none"
				for piece: Array in lv._edge_parts(level, k, is_lift):
					var what := "arail" if piece.size() > 3 else "awall"
					lv._wall_edge(level, x * S, y * S, (x + 1) * S, y * S, Vector2i(x, y - 1), Vector2i(x, y), piece[0], piece[1], piece[2], what, lv._ext(k, before_h), lv._ext(k, after_h))

func _stairs() -> void:
	var carpet := Color(1, 1, 1)
	var nose := Color(0.5, 0.45, 0.36)
	for s: Dictionary in lv.plan.stairs:
		var v := lv._dir_vec(str(s.dir))
		var fwd := Vector3(v.x, 0, v.y)
		var c0 := Vector3((int(s.x) + 0.5) * S, 0, (int(s.y) + 0.5) * S) - fwd * (S * 0.5)
		var n := int(round(LH / 0.2))
		var depth := int(s.length) * S / n
		var st := lv._st(0, c0.x + fwd.x * S, c0.z + fwd.z * S, "astair")
		var props := lv._st(0, c0.x + fwd.x * S, c0.z + fwd.z * S, "aprops")
		for i in n:
			var top := (i + 1) * 0.2
			var size := Vector3(S if v.x == 0 else depth, top, depth if v.x == 0 else S)
			var at := c0 + fwd * (depth * (i + 0.5)) + Vector3(0, top * 0.5, 0)
			box(st, Transform3D.IDENTITY, size, at, carpet)
			# A metal nosing on each step's front edge.
			var ns := Vector3(S - 0.02 if v.x == 0 else 0.04, 0.025, 0.04 if v.x == 0 else S - 0.02)
			box(props, Transform3D.IDENTITY, ns, c0 + fwd * (depth * i + 0.02) + Vector3(0, top - 0.01, 0), nose)

# --- junctions and the looping LIFT signs -------------------------------------------------------------

func edge_kind(level: int, x: int, y: int, d: Vector2i) -> String:
	var vert: Array = lv.edges[level].vertical
	var hor: Array = lv.edges[level].horizontal
	if d == Vector2i(0, -1): return hor[y * W + x]
	if d == Vector2i(0, 1): return hor[(y + 1) * W + x]
	if d == Vector2i(-1, 0): return vert[y * (W + 1) + x]
	return vert[y * (W + 1) + x + 1]

func exits(level: int, x: int, y: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for d: Vector2i in DIRS:
		if lv.kind(level, x + d.x, y + d.y) == "corridor" and edge_kind(level, x, y, d) == "open":
			out.append(d)
	return out

## The fixed rule the building's LIFT signs follow: of a junction's ways out, the one that turns
## furthest clockwise (on the map) round `mid`, the middle of the lattice; ties go n, e, s, w.
static func lift_arrow(ways: Array[Vector2i], at: Vector2, mid: Vector2) -> Vector2i:
	var t := Vector2(-(at.y - mid.y), at.x - mid.x)
	var best := ways[0]
	var best_dot := -INF
	for d: Vector2i in DIRS:
		if not ways.has(d):
			continue
		var dot := d.x * t.x + d.y * t.y
		if dot > best_dot + 0.0001:
			best_dot = dot
			best = d
	return best

func _find_junctions() -> void:
	var lo := Vector2i(W, H)
	var hi := Vector2i(-1, -1)
	for y in H:
		for x in W:
			if lv.kind(0, x, y) == "corridor":
				lo = Vector2i(mini(lo.x, x), mini(lo.y, y))
				hi = Vector2i(maxi(hi.x, x), maxi(hi.y, y))
	centre = Vector2(lo + hi) * 0.5
	for level in 2:
		for y in H:
			for x in W:
				if lv.kind(level, x, y) != "corridor":
					continue
				var ways := exits(level, x, y)
				if ways.size() >= 3:
					junctions.append({"level": level, "cell": Vector2i(x, y), "exits": ways, "arrow": lift_arrow(ways, Vector2(x, y), centre)})

func _signs() -> void:
	var back_col := Color(0.2, 0.23, 0.25)
	var rod_col := Color(0.55, 0.57, 0.57)
	for j: Dictionary in junctions:
		var level: int = j.level
		var cell: Vector2i = j.cell
		var arrow: Vector2i = j.arrow
		var jc := lv.cell_center(level, cell.x, cell.y)
		for a: Vector2i in j.exits:
			if a == arrow:
				continue  # the way the sign points is behind its reader
			var h := -a
			var right := Vector2i(-h.y, h.x)
			var name := "straight" if arrow == h else ("right" if arrow == right else "left")
			var face := Vector3(a.x, 0, a.y)
			var at := jc + face * (S * 0.5 + 0.15) + Vector3(0, 2.45, 0)
			var st := lv._st(level, at.x, at.z, "aprops")
			var along := Vector3(-face.z, 0, face.x)
			var xf := Transform3D(Basis(along, Vector3.UP, face), at)
			box(st, xf, Vector3(0.92, 0.46, 0.04), Vector3.ZERO, back_col)
			for side: float in [-0.36, 0.36]:
				box(st, xf, Vector3(0.02, LH - 2.68, 0.02), Vector3(side, (LH - 2.68) * 0.5 + 0.23, 0), rod_col)
			picture(lv._st(level, at.x, at.z, "adecal"), at + face * 0.022, face, 0.88, 0.44, atlas_uv(ATLAS["lift_" + name]))
			picture(lv._st(level, at.x, at.z, "aexit"), at + face * 0.022 - Vector3(0, 0.32, 0), face, 0.6, 0.2, atlas_uv(ATLAS["exit_" + name]))
			signs.append({"level": level, "pos": at + face * 0.022, "facing": face, "arrow": name})
		# Battery spotlights for the blackout: a hard pool on every junction.
		var spot := SpotLight3D.new()
		spot.position = jc + Vector3(0, LH - 0.1, 0)
		spot.rotation_degrees = Vector3(-90, 0, 0)
		spot.spot_angle = 34.0
		spot.spot_angle_attenuation = 0.3
		spot.spot_range = 6.0
		spot.light_color = EMERGENCY_COL
		spot.light_energy = 0.0
		spot.distance_fade_enabled = true
		spot.distance_fade_begin = 20.0
		spot.distance_fade_length = 5.0
		spot.visible = false
		lv.add_child(spot)
		lv.emergency_lights.append(spot)
	# Door numbers (from the room's shape, so they repeat) and a green running man over every door,
	# on the corridor side.
	for d: Dictionary in lv.plan.doors:
		var level := int(d.level)
		var a := Vector2i(int(d.ax), int(d.ay))
		var b := Vector2i(int(d.bx), int(d.by))
		var corr := a if lv.kind(level, a.x, a.y) == "corridor" else b
		var other := b if corr == a else a
		if lv.kind(level, corr.x, corr.y) != "corridor":
			continue
		var n := Vector3(corr.x - other.x, 0, corr.y - other.y)
		var mid := (lv.cell_center(level, a.x, a.y) + lv.cell_center(level, b.x, b.y)) * 0.5 + n * (WALL_T * 0.5 + 0.012)
		var along := (-n).cross(Vector3.UP)
		picture(lv._st(level, mid.x, mid.z, "aexit"), mid + Vector3(0, DOOR_H + 0.17, 0), n, 0.5, 0.25, atlas_uv(ATLAS["exit_man"]))
		var rid: int = lv.room_at[level][other.y * W + other.x]
		if rid >= 0 and str(lv.plan.rooms[rid].kind) != "lobby":
			var sh: Shape = shapes[rid]
			var i := absi(sh.key.hash()) % PLAQUES.size()
			picture(lv._st(level, mid.x, mid.z, "adecal"), mid + along * 0.8 + Vector3(0, 1.55, 0), n, 0.3, 0.15, atlas_uv(plaque_rect(i)))
	# Over the lift, on the landing side.
	var v := lv._dir_vec(lv.lift_dir)
	var lc := lv.cell_center(lv.landing.x, lv.landing.y, lv.landing.z)
	var wall := lc + Vector3(v.x, 0, v.y) * (S * 0.5 - WALL_T * 0.5 - 0.012)
	picture(lv._st(lv.landing.x, wall.x, wall.z, "aexit"), wall + Vector3(0, Level.LIFT_H + 0.2, 0), -Vector3(v.x, 0, v.y), 0.6, 0.3, atlas_uv(ATLAS["exit_man"]))

# --- panels and lights ------------------------------------------------------------------------------

## Points spread evenly along `length` metres, about `spacing` apart, centred (so a room's own turns
## and mirrorings map the set onto itself).
static func spread(length: float, spacing: float) -> Array[float]:
	var n := maxi(1, roundi(length / spacing))
	var out: Array[float] = []
	for i in n:
		out.append((i + 0.5) * length / n)
	return out

func _panel(level: int, pos: Vector3, along_x: bool) -> void:
	var st := lv._st(level, pos.x, pos.z, "apanel")
	box(st, Transform3D.IDENTITY, Vector3(1.2, 0.03, 0.6) if along_x else Vector3(0.6, 0.03, 1.2), pos, Color.WHITE)

## A real light. `kind`: "spot", a small room's one fitting (the spot every light used to be, dimmer);
## "corridor", a wide spot reaching far along a corridor run; "room", an omni reaching `reach` metres,
## the one light of a big room.
func _light(pos: Vector3, high: bool, kind := "spot", reach := 0.0) -> void:
	var light: Light3D
	var energy := SPOT_ENERGY * (1.36 if high else 1.0)
	if kind == "room":
		var omni := OmniLight3D.new()
		omni.omni_range = reach
		omni.omni_attenuation = LIGHT_DECAY
		energy = ROOM_ENERGY * (1.3 if high else 1.0)
		light = omni
	else:
		var spot := SpotLight3D.new()
		spot.rotation_degrees = Vector3(-90, 0, 0)
		spot.spot_angle = 80.0
		spot.spot_angle_attenuation = 0.9
		spot.spot_range = 10.0 if high else 6.5
		if kind == "corridor":
			spot.spot_range = CORRIDOR_REACH + (LH if high else 0.0)
			spot.spot_attenuation = LIGHT_DECAY
			energy = CORRIDOR_ENERGY * (1.3 if high else 1.0)
		light = spot
	light.position = pos - Vector3(0, 0.05, 0)
	light.light_color = LIGHT_COL
	light.light_energy = energy
	light.shadow_enabled = false
	light.distance_fade_enabled = true
	light.distance_fade_begin = 16.0
	light.distance_fade_length = 6.0
	lv.add_child(light)
	lv.main_lights.append(light)
	lv._base_energy.append(energy)

func _ceiling_y(level: int, x: int, y: int) -> float:
	var open_above := level == 0 and (lv.kind(1, x, y) == "atriumOpen" or lv.kind(1, x, y) == "stair")
	return (2 * LH if open_above else level * LH + LH) - 0.02

func _is_corridor(level: int, c: Vector2i) -> bool:
	return lv.kind(level, c.x, c.y) == "corridor"

## Every panel is drawn lit, but the real lights are few (the renderer draws at most 256 a frame):
## wide spots along each straight corridor run between junctions, corners and ends (one in the middle
## of a lattice segment, so about every 14 m) and one light per room, with the flat baked-in light
## (`self_light`, lifted by FLAT) carrying the evenness. About 125 on a depth-3 floor, under 180 on
## the biggest; annex_look_check.gd fails a floor over LIGHT_LIMIT.
func _panels_and_lights() -> void:
	# Corridors: a panel on every cell.
	for level in 2:
		for y in H:
			for x in W:
				if lv.kind(level, x, y) != "corridor":
					continue
				var pos := lv.cell_center(level, x, y)
				pos.y = _ceiling_y(level, x, y)
				var ew := int(lv.kind(level, x - 1, y) == "corridor") + int(lv.kind(level, x + 1, y) == "corridor")
				var ns := int(lv.kind(level, x, y - 1) == "corridor") + int(lv.kind(level, x, y + 1) == "corridor")
				_panel(level, pos, ew > ns)
	# Corridor lights: along each straight run of through cells (two corridor neighbours, opposite),
	# spread about CORRIDOR_SPACING apart.
	for level in 2:
		for y in H:
			for x in W:
				var c := Vector2i(x, y)
				if not _is_corridor(level, c) or not _through(level, c):
					continue
				for d: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
					# Start of a run along d: a through cell along d whose cell behind is not one.
					if not (_is_corridor(level, c + d) and _is_corridor(level, c - d)):
						continue
					if _through(level, c - d):
						continue
					var n := 0
					while _is_corridor(level, c + d * n) and _through(level, c + d * n):
						n += 1
					var a := lv.cell_center(level, c.x, c.y) - Vector3(d.x, 0, d.y) * (S * 0.5)
					for t: float in spread(n * S, CORRIDOR_SPACING):
						var p := a + Vector3(d.x, 0, d.y) * t
						var cell := c + d * mini(int(t / S), n - 1)
						p.y = _ceiling_y(level, cell.x, cell.y)
						_light(p, p.y > level * LH + LH, "corridor")
	# Rooms: panels on an even grid about 3.5 m apart; one light in the middle, a downward spot in a
	# room about 6 m across or less, an omni reaching every corner in a bigger one.
	for r: Dictionary in lv.plan.rooms:
		var level := int(r.level)
		var x0 := int(r.x) * S
		var z0 := int(r.y) * S
		var wm := int(r.w) * S
		var hm := int(r.h) * S
		var cx := int(r.x) + int(r.w) / 2
		var cy := int(r.y) + int(r.h) / 2
		var y := _ceiling_y(level, cx, cy)
		var high := y > level * LH + LH
		for u: float in spread(wm, 3.5):
			for v: float in spread(hm, 3.5):
				_panel(level, Vector3(x0 + u, y, z0 + v), wm > hm)
		var small := spread(wm, 6.0).size() == 1 and spread(hm, 6.0).size() == 1
		_light(Vector3(x0 + wm * 0.5, y, z0 + hm * 0.5), high, "spot" if small else "room", Vector2(wm, hm).length() * 0.5 + 2.5)

## A corridor cell that only carries the corridor straight on: exactly two corridor neighbours, opposite.
func _through(level: int, c: Vector2i) -> bool:
	var ew := int(_is_corridor(level, c + Vector2i(1, 0))) + int(_is_corridor(level, c - Vector2i(1, 0)))
	var ns := int(_is_corridor(level, c + Vector2i(0, 1))) + int(_is_corridor(level, c - Vector2i(0, 1)))
	return (ew == 2 and ns == 0) or (ew == 0 and ns == 2)

# --- room shapes ------------------------------------------------------------------------------

## A room's shape: what its dressing may depend on. Rooms with the same key are dressed the same.
class Shape:
	var key := ""
	## The symmetry that carries the canonical frame onto the room (see canon_to_local).
	var sym := 0
	## Every symmetry that gives the same key (more than one when the room is symmetric itself).
	var syms: Array[int] = []
	## Canonical size in cells.
	var cw := 0
	var ch := 0
	## Openings in the canonical frame: {m (Vector2, metres: an edge's midpoint or a cell's centre), kind, cell}.
	var feats: Array[Dictionary] = []

## Canonical metres to room-local metres (x across the room from its west wall, y down from its north
## wall) for symmetry k of a room `wm` by `hm` metres: bit 0 flips across, bit 1 flips down, bit 2
## swaps the axes.
static func canon_to_local(k: int, wm: float, hm: float, p: Vector2) -> Vector2:
	var swap := (k & 4) != 0
	var cwm := hm if swap else wm
	var chm := wm if swap else hm
	var uu := cwm - p.x if (k & 1) != 0 else p.x
	var vv := chm - p.y if (k & 2) != 0 else p.y
	return Vector2(vv, uu) if swap else Vector2(uu, vv)

static func local_to_canon(k: int, wm: float, hm: float, a: Vector2) -> Vector2:
	var swap := (k & 4) != 0
	var cwm := hm if swap else wm
	var chm := wm if swap else hm
	var uu := a.y if swap else a.x
	var vv := a.x if swap else a.y
	return Vector2(cwm - uu if (k & 1) != 0 else uu, chm - vv if (k & 2) != 0 else vv)

## The canonical frame (x = across, z = down, y up from the room's floor) to the world, by symmetry k.
static func room_xf(r: Dictionary, k: int) -> Transform3D:
	var wm := int(r.w) * S
	var hm := int(r.h) * S
	var o := canon_to_local(k, wm, hm, Vector2.ZERO)
	var ex := canon_to_local(k, wm, hm, Vector2(1, 0)) - o
	var ez := canon_to_local(k, wm, hm, Vector2(0, 1)) - o
	return Transform3D(Basis(Vector3(ex.x, 0, ex.y), Vector3.UP, Vector3(ez.x, 0, ez.y)),
		Vector3(int(r.x) * S + o.x, int(r.level) * LH, int(r.y) * S + o.y))

static func shape_of(level: Level, r: Dictionary) -> Shape:
	var lvl := int(r.level)
	var rx := int(r.x)
	var ry := int(r.y)
	var w := int(r.w)
	var h := int(r.h)
	var wm := w * S
	var hm := h * S
	var vert: Array = level.edges[lvl].vertical
	var hor: Array = level.edges[lvl].horizontal
	var Wd := level.W
	var local: Array[Dictionary] = []   # {m, kind, cell}
	for j in h:
		for i in w:
			var x := rx + i
			var y := ry + j
			var ck := level.kind(lvl, x, y)
			if ck != "room":
				local.append({"m": Vector2((i + 0.5) * S, (j + 0.5) * S), "kind": ck, "cell": true})
			var sides: Array = []
			if j == 0: sides.append([hor[y * Wd + x], Vector2((i + 0.5) * S, 0)])
			if j == h - 1: sides.append([hor[(y + 1) * Wd + x], Vector2((i + 0.5) * S, hm)])
			if i == 0: sides.append([vert[y * (Wd + 1) + x], Vector2(0, (j + 0.5) * S)])
			if i == w - 1: sides.append([vert[y * (Wd + 1) + x + 1], Vector2(wm, (j + 0.5) * S)])
			for s: Array in sides:
				if str(s[0]) != "wall":
					local.append({"m": s[1], "kind": str(s[0]), "cell": false})
	var best := Shape.new()
	for k in 8:
		var swap := (k & 4) != 0
		var parts: Array[String] = []
		for f: Dictionary in local:
			var m := local_to_canon(k, wm, hm, f.m)
			parts.append("%s%d,%d:%s" % ["c" if f.cell else "", roundi(m.x), roundi(m.y), f.kind])
		parts.sort()
		var key := "%s|%dx%d|%s" % [str(r.kind), h if swap else w, w if swap else h, ";".join(parts)]
		if best.key == "" or key < best.key:
			best.key = key
			best.sym = k
			best.syms = [k]
			best.cw = h if swap else w
			best.ch = w if swap else h
		elif key == best.key:
			best.syms.append(k)
	for f: Dictionary in local:
		best.feats.append({"m": local_to_canon(best.sym, wm, hm, f.m), "kind": f.kind, "cell": f.cell})
	return best

# --- props ------------------------------------------------------------------------------------

const LAMINATE := Color(0.68, 0.62, 0.5)
const DESK_EDGE := Color(0.47, 0.44, 0.39)
const BEIGE := Color(0.8, 0.77, 0.67)
const BEIGE_DARK := Color(0.62, 0.6, 0.53)
const SCREEN := Color(0.32, 0.48, 0.38, 0.55)
const CHAIR := Color(0.26, 0.28, 0.33)
const METAL := Color(0.58, 0.6, 0.6)
const METAL_DARK := Color(0.3, 0.31, 0.32)
const CABINET := Color(0.68, 0.67, 0.61)
const CABINET_DARK := Color(0.6, 0.59, 0.54)
const FABRIC := Color(0.45, 0.49, 0.56)
const SEAT := Color(0.38, 0.42, 0.5)
const WOOD := Color(0.52, 0.4, 0.27)
const WOOD_DARK := Color(0.4, 0.31, 0.22)
const WHITE := Color(0.88, 0.88, 0.84)
const GREY_MID := Color(0.6, 0.6, 0.58)
const GREY_DARK := Color(0.35, 0.36, 0.36)
const PAPER := Color(0.95, 0.95, 0.9)
const CARD := Color(0.64, 0.51, 0.32)
const CARD_DARK := Color(0.55, 0.43, 0.27)
const LEAF := Color(0.27, 0.44, 0.2)
const LEAF2 := Color(0.34, 0.52, 0.24)
const POT := Color(0.44, 0.41, 0.37)
const WATER := Color(0.55, 0.74, 0.88, 0.8)
const LED := Color(0.35, 1.0, 0.45, 0.2)

## A box by size and the middle of its bottom face.
static func _b(sx: float, sy: float, sz: float, cx: float, y0: float, cz: float, col: Color) -> Array:
	return [Vector3(sx, sy, sz), Vector3(cx, y0 + sy * 0.5, cz), col]

## Boxes turned by `turn` (a multiple of a quarter turn) about the vertical, then moved by `off`.
static func _turned(boxes: Array, turn: float, off: Vector3) -> Array:
	var bs := Basis(Vector3.UP, turn)
	var out: Array = []
	for b: Array in boxes:
		var size: Vector3 = b[0]
		var s := (bs * size).abs()
		out.append([s, bs * (b[1] as Vector3) + off, b[2]])
	return out

## A chair whose sitter faces -z.
static func _chair() -> Array:
	return [_b(0.46, 0.07, 0.44, 0, 0.4, 0, CHAIR), _b(0.42, 0.46, 0.05, 0, 0.49, 0.22, CHAIR),
		_b(0.06, 0.36, 0.06, 0, 0.04, 0, METAL_DARK), _b(0.52, 0.04, 0.06, 0, 0, 0, METAL_DARK), _b(0.06, 0.04, 0.52, 0, 0, 0, METAL_DARK)]

## A desk against the wall behind it (+z), a CRT, a keyboard and its chair in front (-z).
static func _workstation() -> Array:
	var out: Array = [
		_b(1.4, 0.04, 0.7, 0, 0.71, 0.33, LAMINATE), _b(0.04, 0.71, 0.66, -0.68, 0, 0.33, DESK_EDGE),
		_b(0.04, 0.71, 0.66, 0.68, 0, 0.33, DESK_EDGE), _b(1.32, 0.4, 0.03, 0, 0.3, 0.64, DESK_EDGE),
		_b(0.42, 0.36, 0.42, 0.12, 0.75, 0.44, BEIGE), _b(0.34, 0.27, 0.012, 0.12, 0.795, 0.226, SCREEN),
		_b(0.46, 0.025, 0.16, 0.06, 0.75, 0.1, BEIGE_DARK), _b(0.22, 0.02, 0.3, -0.45, 0.75, 0.3, PAPER),
	]
	out.append_array(_turned(_chair(), PI, Vector3(0, 0, -0.38)))
	return out

## Every prop: half width, back (+z) and front (-z) of its footprint, whether it is tall, its boxes.
## Front faces -z, into the room; the back stands against a wall.
static func catalogue() -> Dictionary:
	if not _catalogue_cache.is_empty():
		return _catalogue_cache
	var c := {}
	c["workstation"] = {"hw": 0.71, "zb": 0.69, "zf": -0.66, "tall": false, "boxes": _workstation()}
	var pod: Array = [_b(1.5, 1.2, 0.05, 0, 0, 0, FABRIC), _b(0.05, 1.2, 1.5, -0.76, 0, 0, FABRIC), _b(0.05, 1.2, 1.5, 0.76, 0, 0, FABRIC)]
	pod.append_array(_turned(_workstation(), 0.0, Vector3(0, 0, -0.71)))
	pod.append_array(_turned(_workstation(), PI, Vector3(0, 0, 0.71)))
	c["pod"] = {"hw": 0.8, "zb": 1.4, "zf": -1.4, "tall": false, "boxes": pod}
	var cab: Array = [_b(0.46, 1.32, 0.62, 0, 0, 0, CABINET)]
	for i in 4:
		cab.append(_b(0.4, 0.27, 0.012, 0, 0.05 + i * 0.315, -0.316, CABINET_DARK))
		cab.append(_b(0.12, 0.025, 0.02, 0, 0.25 + i * 0.315, -0.327, METAL_DARK))
	c["cabinet"] = {"hw": 0.23, "zb": 0.31, "zf": -0.34, "tall": true, "boxes": cab}
	var low: Array = [_b(0.9, 0.72, 0.5, 0, 0, 0, CABINET)]
	for i in 2:
		low.append(_b(0.84, 0.3, 0.012, 0, 0.05 + i * 0.34, -0.256, CABINET_DARK))
		low.append(_b(0.2, 0.025, 0.02, 0, 0.27 + i * 0.34, -0.267, METAL_DARK))
	c["cabinet_low"] = {"hw": 0.45, "zb": 0.25, "zf": -0.28, "tall": false, "boxes": low}
	c["plant"] = {"hw": 0.26, "zb": 0.26, "zf": -0.26, "tall": false, "boxes": [
		_b(0.34, 0.34, 0.34, 0, 0, 0, POT), _b(0.38, 0.04, 0.38, 0, 0.32, 0, GREY_DARK),
		_b(0.5, 0.42, 0.5, 0, 0.42, 0, LEAF), _b(0.4, 0.36, 0.4, 0.04, 0.8, -0.03, LEAF2),
		_b(0.26, 0.3, 0.26, -0.03, 1.12, 0.02, LEAF), _b(0.12, 0.2, 0.12, 0.02, 1.38, 0, LEAF2)]}
	c["copier"] = {"hw": 0.81, "zb": 0.33, "zf": -0.33, "tall": false, "boxes": [
		_b(1.0, 0.86, 0.64, 0, 0, 0, WHITE), _b(1.004, 0.3, 0.644, 0, 0.05, 0, GREY_MID),
		_b(0.92, 0.06, 0.58, 0, 0.86, 0.02, GREY_DARK), _b(0.34, 0.07, 0.16, 0.28, 0.86, -0.22, GREY_MID),
		_b(0.05, 0.03, 0.05, 0.38, 0.93, -0.25, LED), _b(0.3, 0.03, 0.4, -0.65, 0.6, 0, WHITE),
		_b(0.21, 0.02, 0.3, -0.65, 0.63, 0, PAPER)]}
	c["cooler"] = {"hw": 0.17, "zb": 0.17, "zf": -0.18, "tall": false, "boxes": [
		_b(0.32, 0.92, 0.32, 0, 0, 0, WHITE), _b(0.2, 0.12, 0.02, 0, 0.7, -0.17, GREY_MID),
		_b(0.26, 0.4, 0.26, 0, 0.92, 0, WATER)]}
	var meet: Array = [_b(4.4, 0.05, 1.3, 0, 0.71, 0, WOOD), _b(0.3, 0.71, 0.8, -1.4, 0, 0, WOOD_DARK), _b(0.3, 0.71, 0.8, 1.4, 0, 0, WOOD_DARK)]
	for x: float in [-1.5, -0.5, 0.5, 1.5]:
		meet.append_array(_turned(_chair(), PI, Vector3(x, 0, -0.95)))
		meet.append_array(_turned(_chair(), 0.0, Vector3(x, 0, 0.95)))
	meet.append_array(_turned(_chair(), -PI * 0.5, Vector3(-2.55, 0, 0)))
	meet.append_array(_turned(_chair(), PI * 0.5, Vector3(2.55, 0, 0)))
	c["table_meeting"] = {"hw": 2.8, "zb": 1.2, "zf": -1.2, "tall": false, "boxes": meet}
	var small: Array = [_b(0.9, 0.04, 0.9, 0, 0.7, 0, LAMINATE), _b(0.08, 0.7, 0.08, 0, 0, 0, METAL_DARK), _b(0.5, 0.03, 0.5, 0, 0, 0, METAL_DARK)]
	small.append_array(_turned(_chair(), PI, Vector3(0, 0, -0.72)))
	small.append_array(_turned(_chair(), 0.0, Vector3(0, 0, 0.72)))
	small.append_array(_turned(_chair(), -PI * 0.5, Vector3(-0.72, 0, 0)))
	c["table_small"] = {"hw": 0.97, "zb": 0.97, "zf": -0.97, "tall": false, "boxes": small}
	# The wall table is shallow. Its chairs are separate pieces with their own footprints.
	c["break_table"] = {"boxes": [
		_b(1.2, 0.04, 0.56, 0, 0.7, 0, LAMINATE), _b(0.06, 0.7, 0.06, -0.45, 0, 0.13, METAL_DARK),
		_b(0.06, 0.7, 0.06, 0.45, 0, 0.13, METAL_DARK), _b(0.06, 0.7, 0.06, -0.45, 0, -0.18, METAL_DARK),
		_b(0.06, 0.7, 0.06, 0.45, 0, -0.18, METAL_DARK)]}
	c["fridge"] = {"hw": 0.36, "zb": 0.34, "zf": -0.37, "tall": true, "boxes": [
		_b(0.7, 1.75, 0.68, 0, 0, 0, WHITE), _b(0.704, 0.015, 0.684, 0, 1.15, 0, GREY_MID),
		_b(0.03, 0.3, 0.03, 0.28, 1.25, -0.355, GREY_DARK)]}
	var counter: Array = [_b(1.8, 0.86, 0.6, 0, 0, 0, WOOD), _b(1.84, 0.04, 0.64, 0, 0.86, 0, BEIGE),
		_b(0.5, 0.3, 0.36, -0.5, 0.9, 0.08, WHITE), _b(0.28, 0.18, 0.01, -0.55, 0.96, -0.105, GREY_DARK),
		_b(0.16, 0.24, 0.16, 0.4, 0.9, 0.05, WHITE)]
	for x: float in [-0.45, 0.0, 0.45]:
		counter.append(_b(0.012, 0.7, 0.01, x, 0.08, -0.305, WOOD_DARK))
	c["counter"] = {"hw": 0.92, "zb": 0.32, "zf": -0.32, "tall": false, "boxes": counter}
	var shelf: Array = []
	for x: float in [-0.88, 0.88]:
		for z: float in [-0.2, 0.2]:
			shelf.append(_b(0.04, 2.0, 0.04, x, 0, z, METAL))
	for k in 4:
		var y := 0.1 + k * 0.5
		shelf.append(_b(1.8, 0.03, 0.45, 0, y, 0, METAL))
		for i in 3:
			var bw := 0.38 + 0.08 * ((k + i) % 3)
			shelf.append(_b(bw, 0.3 - 0.04 * ((k * 2 + i) % 3), 0.36, -0.55 + i * 0.55, y + 0.03, 0, CARD if (k + i) % 2 == 0 else CARD_DARK))
	c["shelf"] = {"hw": 0.9, "zb": 0.23, "zf": -0.23, "tall": true, "boxes": shelf}
	c["boxes"] = {"hw": 0.31, "zb": 0.25, "zf": -0.25, "tall": false, "boxes": [
		_b(0.6, 0.4, 0.45, 0, 0, 0, CARD), _b(0.5, 0.34, 0.4, 0.04, 0.4, -0.02, CARD_DARK), _b(0.36, 0.26, 0.3, -0.04, 0.74, 0.03, CARD)]}
	var row: Array = [_b(1.7, 0.05, 0.06, 0, 0.3, 0, METAL_DARK), _b(0.05, 0.3, 0.4, -0.8, 0, 0, METAL_DARK), _b(0.05, 0.3, 0.4, 0.8, 0, 0, METAL_DARK)]
	for x: float in [-0.55, 0.0, 0.55]:
		row.append(_b(0.5, 0.06, 0.46, x, 0.38, -0.02, SEAT))
		row.append(_b(0.48, 0.44, 0.05, x, 0.44, 0.21, SEAT))
	c["chair_row"] = {"hw": 0.86, "zb": 0.24, "zf": -0.25, "tall": false, "boxes": row}
	c["planter"] = {"hw": 0.5, "zb": 0.5, "zf": -0.5, "tall": false, "boxes": [
		_b(1.0, 0.5, 1.0, 0, 0, 0, Color(0.6, 0.58, 0.52)), _b(0.9, 0.02, 0.9, 0, 0.5, 0, Color(0.3, 0.24, 0.18)),
		_b(0.8, 0.5, 0.8, 0, 0.5, 0, LEAF), _b(0.6, 0.5, 0.6, 0.05, 0.95, -0.05, LEAF2), _b(0.36, 0.4, 0.36, -0.05, 1.4, 0.05, LEAF)]}
	var trough: Array = []
	var flat := Vector3(1.0, 1.0, 0.56)
	for box: Array in c["planter"]["boxes"]:
		trough.append([box[0] * flat, box[1] * flat, box[2]])
	c["wall_planter"] = {"boxes": trough}
	c["bench"] = {"hw": 0.9, "zb": 0.25, "zf": -0.25, "tall": false, "boxes": [
		_b(1.8, 0.08, 0.5, 0, 0.4, 0, WOOD), _b(0.08, 0.4, 0.44, -0.8, 0, 0, METAL_DARK), _b(0.08, 0.4, 0.44, 0.8, 0, 0, METAL_DARK)]}
	_catalogue_cache = c
	return c

## Wall pictures: size and the height of their middle.
const DECALS := {
	"poster": [0.6, 0.8, 1.55], "clock": [0.34, 0.34, 2.3], "map": [0.8, 0.8, 1.5], "whiteboard": [1.8, 0.9, 1.4],
}

## One room being laid out, all in its canonical frame (metres).
class Layout:
	var cwm := 0.0
	var chm := 0.0
	var inner: Rect2
	var zones: Array[Rect2] = []
	var taken: Array[Rect2] = []
	## Wall slots, best first (furthest from any opening): {m (edge midpoint), n (outward), tall, pic}.
	var slots: Array[Dictionary] = []
	var rng := RandomNumberGenerator.new()
	## [type, u, v, facing (Vector2), extra turn]
	var props: Array = []
	## [type, point on the wall line (Vector2), outward normal (Vector2)]
	var pics: Array = []
	## Pictures only (the furniture is the rules'): no prop is put down.
	var pics_only := false

static func _foot(type: String, at: Vector2, f: Vector2) -> Rect2:
	var p: Dictionary = catalogue()[type]
	var hw: float = p.hw
	var zb: float = p.zb
	var zf: float = p.zf
	var right := Vector2(-f.y, f.x)
	var back := -f
	var a := at + right * -hw + back * zf
	var b := at + right * hw + back * zb
	return Rect2(Vector2(minf(a.x, b.x), minf(a.y, b.y)), (b - a).abs())

static func _fits(l: Layout, foot: Rect2) -> bool:
	if not l.inner.encloses(foot):
		return false
	for z: Rect2 in l.zones:
		if z.intersects(foot):
			return false
	for o: Rect2 in l.taken:
		if o.grow(0.05).intersects(foot):
			return false
	return true

static func _put(l: Layout, type: String, at: Vector2, f: Vector2, turn := 0.0) -> bool:
	if l.pics_only:
		return false
	var foot := _foot(type, at, f)
	if not _fits(l, foot):
		return false
	l.taken.append(foot)
	l.props.append([type, at.x, at.y, f, turn])
	return true

## Against the best free wall slot.
static func _wall(l: Layout, type: String, jitter := 0.0) -> bool:
	var p: Dictionary = catalogue()[type]
	var zb: float = p.zb
	var turn := l.rng.randf_range(-jitter, jitter) if jitter > 0.0 else 0.0
	for s: Dictionary in l.slots:
		var n: Vector2 = s.n
		var m: Vector2 = s.m
		if _put(l, type, m - n * (INSET + zb), -n, turn):
			if p.tall:
				s.tall = true
			return true
	return false

## A picture on the best free stretch of wall (`skip` passes over that many candidates first).
static func _pic(l: Layout, type: String, skip := 0) -> bool:
	var high := type == "clock"
	for s: Dictionary in l.slots:
		if s.pic or (s.tall and not high):
			continue
		if skip > 0:
			skip -= 1
			continue
		s.pic = true
		l.pics.append([type, s.m, s.n])
		return true
	return false

## `pics_only`: only the pictures, kept off the wall slots within a metre of `tall` (canonical points on the wall
## behind the rules' tall pieces).
static func layout_for(sh: Shape, kind: String, rng_seed: int, pre: Array[Rect2] = [], desk_hidden := false, pics_only := false, tall: Array[Vector2] = []) -> Layout:
	var l := Layout.new()
	l.pics_only = pics_only
	l.taken.append_array(pre)
	l.rng.seed = rng_seed
	l.cwm = sh.cw * S
	l.chm = sh.ch * S
	l.inner = Rect2(INSET, INSET, l.cwm - 2.0 * INSET, l.chm - 2.0 * INSET)
	var open_mids: Array[Vector2] = []
	for f: Dictionary in sh.feats:
		var m: Vector2 = f.m
		if f.cell:
			l.zones.append(Rect2(m - Vector2(1.6, 1.6), Vector2(3.2, 3.2)))
			open_mids.append(m)
			continue
		var n := _outward(l, m)
		var along := Vector2(-n.y, n.x)
		var a := m - along * 0.75
		var b := m + along * 0.75 - n * 1.3
		l.zones.append(Rect2(Vector2(minf(a.x, b.x), minf(a.y, b.y)), (b - a).abs()))
		open_mids.append(m)
	# Wall slots, one per cell of wall, best first.
	var order: Array = []
	var idx := 0
	for side in 4:
		var count := sh.cw if side % 2 == 0 else sh.ch
		for i in count:
			var m: Vector2
			var n: Vector2
			match side:
				0: m = Vector2((i + 0.5) * S, 0); n = Vector2(0, -1)
				1: m = Vector2(l.cwm, (i + 0.5) * S); n = Vector2(1, 0)
				2: m = Vector2(l.cwm - (i + 0.5) * S, l.chm); n = Vector2(0, 1)
				_: m = Vector2(0, l.chm - (i + 0.5) * S); n = Vector2(-1, 0)
			idx += 1
			var opening := false
			var near := 99.0
			for o: Vector2 in open_mids:
				if o.distance_to(m) < 0.01:
					opening = true
				near = minf(near, o.distance_to(m))
			if opening:
				continue
			order.append([-roundi(near * 100.0) * 1000 + idx, {"m": m, "n": n, "tall": false, "pic": false}])
	order.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) < int(b[0]))
	for o: Array in order:
		l.slots.append(o[1])
	for sl: Dictionary in l.slots:
		for tp: Vector2 in tall:
			if (sl.m as Vector2).distance_to(tp) < 1.0:
				sl.tall = true
	var mid := Vector2(l.cwm, l.chm) * 0.5
	var long_u := l.cwm >= l.chm
	match kind:
		"office":
			if not desk_hidden:
				_wall(l, "workstation")
			_wall(l, "cabinet")
			_wall(l, "plant", 0.3)
			_pic(l, "poster", l.rng.randi_range(0, 1))
			_pic(l, "clock")
		"cubicles":
			for j in sh.ch / 2:
				for i in sh.cw / 2:
					_put(l, "pod", Vector2((2 * i + 1) * S, (2 * j + 1) * S), Vector2(0, -1) if long_u else Vector2(1, 0))
			_wall(l, "cabinet")
			_wall(l, "cabinet")
			_wall(l, "plant", 0.3)
			_wall(l, "cooler")
			_pic(l, "poster", l.rng.randi_range(0, 1))
			_pic(l, "clock")
		"meeting":
			# The meeting table is the room's hide (sim/hides.gd puts it in the middle).
			_put(l, "table_meeting", mid, Vector2(0, -1) if long_u else Vector2(1, 0))
			_wall(l, "plant", 0.3)
			_wall(l, "cabinet_low")
			_wall(l, "plant", 0.3)
			_pic(l, "whiteboard")
			_pic(l, "clock")
			_pic(l, "poster")
		"copy":
			for i in 3:
				_wall(l, "copier")
			_wall(l, "boxes", 0.25)
			_wall(l, "cabinet")
			_pic(l, "poster", l.rng.randi_range(0, 1))
			_pic(l, "clock")
		"store":
			for i in 4:
				_wall(l, "shelf")
			_wall(l, "boxes", 0.25)
			_wall(l, "boxes", 0.25)
		"break":
			_put(l, "table_small", mid, Vector2(0, -1), l.rng.randf_range(-0.3, 0.3))
			_wall(l, "counter")
			_wall(l, "fridge")
			_wall(l, "cooler")
			_pic(l, "poster", l.rng.randi_range(0, 1))
			_pic(l, "map")
			_pic(l, "clock")
		"closet":
			_wall(l, "shelf")
			_wall(l, "boxes", 0.25)
			_wall(l, "cabinet")
			_wall(l, "boxes", 0.25)
		"atrium":
			for d: Vector2 in [Vector2(-3, -3), Vector2(3, -3), Vector2(-3, 3), Vector2(3, 3)]:
				_put(l, "planter", mid + d, Vector2(0, -1), l.rng.randf_range(-0.3, 0.3))
			_put(l, "bench", mid + Vector2(0, -1.0), Vector2(0, 1))
			_put(l, "bench", mid + Vector2(0, 1.0), Vector2(0, -1))
			_wall(l, "chair_row")
			_wall(l, "chair_row")
			_wall(l, "cooler")
			_wall(l, "plant", 0.3)
			_pic(l, "map")
			_pic(l, "clock")
		"lobby":
			_wall(l, "chair_row")
			_wall(l, "plant", 0.3)
			_wall(l, "chair_row")
			_wall(l, "plant", 0.3)
			_pic(l, "map")
			_pic(l, "clock")
	return l

static func _outward(l: Layout, m: Vector2) -> Vector2:
	if m.y < 0.01: return Vector2(0, -1)
	if m.y > l.chm - 0.01: return Vector2(0, 1)
	if m.x < 0.01: return Vector2(-1, 0)
	return Vector2(1, 0)

## The rules' furniture (sim/furniture.gd): each piece drawn from the list. The hides in the Annex's colours
## (the meeting table at its full 4.4 m), the plain pieces from the catalogue, each centred on its footprint and
## turned to its facing.
func _furniture(floor_plan: FloorLib.FloorPlan) -> void:
	var cat := catalogue()
	var list := Furniture.pieces_for(floor_plan, str(lv.plan.seed), int(lv.plan.depth),
		bool(lv.plan.get("furnitureLayout", false)), hides)
	lv.pieces = list
	for pc: Furniture.Piece in list:
		var xf: Transform3D
		var boxes: Array
		var type := String(pc.kind)
		if pc.hide >= 0:
			var h: Playroom.Hide = hides[pc.hide]
			xf = hide_xf(h)
			boxes = meeting_table_boxes() if h.kind == &"table" else hide_boxes(h.kind, false)
			draw_hide_into_boxes(lv, h.level, xf, boxes, "aprops")
			hide_pieces.append({"hide": h.id, "kind": String(h.kind), "level": h.level, "xf": xf})
			type = "hide:" + type
			lv.furniture_drawn.append({"piece": pc.id, "kind": String(pc.kind), "rect": boxes_rect(xf, boxes)})
		else:
			var f := Vector2(FloorLib.dir_dx(pc.facing), FloorLib.dir_dy(pc.facing))
			var centre := Vector2(pc.x / 100.0, pc.y / 100.0)
			boxes = _chair() if pc.kind == &"chair" else (cat[catalogue_name(pc.kind)] as Dictionary).boxes
			var basis := Basis(Vector3.UP, atan2(-f.x, -f.y))
			# The record is the piece itself (its centre and facing), as the rules have it.
			xf = Transform3D(basis, Vector3(centre.x, pc.level * LH, centre.y))
			# Drawn mirrored in a room whose canonical frame is a mirror image, so same-shaped rooms look
			# alike to the last copier tray; the middle of what is drawn on the piece's centre.
			if pc.room >= 0 and shapes.has(pc.room):
				var rr: Dictionary = {}
				for r: Dictionary in lv.plan.rooms:
					if int(r.id) == pc.room:
						rr = r
				if not rr.is_empty() and room_xf(rr, (shapes[pc.room] as Shape).sym).basis.determinant() < 0.0:
					basis = basis * Basis.from_scale(Vector3(-1, 1, 1))
			var r0 := boxes_rect(Transform3D.IDENTITY, boxes)
			var off := basis * Vector3(r0.get_center().x, 0, r0.get_center().y)
			var dxf := Transform3D(basis, Vector3(centre.x - off.x, pc.level * LH, centre.y - off.z))
			draw_hide_into_boxes(lv, pc.level, dxf, boxes, "aprops")
			lv.furniture_drawn.append({"piece": pc.id, "kind": String(pc.kind), "rect": boxes_rect(dxf, boxes)})
			lv.prop_spots.append({"room": pc.room, "level": pc.level, "type": type, "pos": [xf.origin.x, xf.origin.z]})
			lv.props_placed += 1
		records.append({"room": pc.room, "type": type, "xf": xf})

## The catalogue's name for a piece's kind.
static func catalogue_name(kind: StringName) -> String:
	match kind:
		&"filing":
			return "cabinet"
		&"planter":
			return "wall_planter"
	return String(kind)

## The pictures, laid out by each room's shape, off the walls behind its tall pieces.
func _pictures() -> void:
	for r: Dictionary in lv.plan.rooms:
		var rid := int(r.id)
		var sh: Shape = shapes[rid]
		var wm := int(r.w) * S
		var hm := int(r.h) * S
		var o := Vector2(int(r.x) * S, int(r.y) * S)
		var tall: Array[Vector2] = []
		for pc: Furniture.Piece in lv.pieces:
			if pc.room != rid or not pc.tall:
				continue
			tall.append(local_to_canon(sh.sym, wm, hm, Vector2(pc.x / 100.0, pc.y / 100.0) - o))
		var l := layout_for(sh, str(r.kind), sh.key.hash(), [], false, true, tall)
		var rxf := room_xf(r, sh.sym)
		var level := int(r.level)
		for p: Array in l.pics:
			var type: String = p[0]
			var m: Vector2 = p[1]
			var n: Vector2 = p[2]
			var dims: Array = DECALS[type]
			var at3 := Vector3(m.x - n.x * (WALL_T * 0.5 + 0.012), float(dims[2]), m.y - n.y * (WALL_T * 0.5 + 0.012))
			var at := rxf * at3
			var into := (rxf.basis * Vector3(-n.x, 0, -n.y)).normalized()
			picture(lv._st(level, at.x, at.z, "adecal"), at, into, float(dims[0]), float(dims[1]), atlas_uv(ATLAS[type]))
			records.append({"room": rid, "type": "picture:" + type, "xf": Transform3D(Basis.looking_at(-into, Vector3.UP), at)})

# --- the hiding places -----------------------------------------------------------------------------

## A hide's own frame: the inside spot at the origin on its floor, the gap towards -z (into the room), the
## wall behind it +z.
static func hide_xf(h: Playroom.Hide) -> Transform3D:
	var gx := float(FloorLib.dir_dx(h.gap))
	var gz := float(FloorLib.dir_dy(h.gap))
	return Transform3D(Basis(Vector3.UP, atan2(-gx, -gz)), Vector3(h.inside.x / 100.0, h.level * LH, h.inside.y / 100.0))

## Half the footprint of a hide's furniture: across its gap (x) and from the gap to the wall (z).
static func hide_half(kind: StringName) -> Vector2:
	match kind:
		&"bed":
			return Vector2(1.0, 0.45)
		&"cabinet":
			return Vector2(0.45, 0.3)
		&"desk":
			return Vector2(0.8, 0.4)
	return Vector2(0.9, 0.5)

## The footprint on the floor (world x, z).
static func hide_foot(h: Playroom.Hide) -> Rect2:
	var xf := hide_xf(h)
	var hh := hide_half(h.kind)
	var a := xf * Vector3(-hh.x, 0, -hh.y)
	var b := xf * Vector3(hh.x, 0, hh.y)
	return Rect2(Vector2(minf(a.x, b.x), minf(a.z, b.z)), Vector2(absf(b.x - a.x), absf(b.z - a.z)))

## The boxes of a hide's furniture in its own frame (hide_xf): a bed on legs with room under it, a tall
## cabinet with slatted doors (you see out between the slats), a desk with a solid back panel and an
## open kneehole, a table. `clinic`: the Clinic's colours (white and steel), else the Annex's.
static func hide_boxes(kind: StringName, clinic: bool) -> Array:
	var steel := Color(0.56, 0.6, 0.62)
	var dark := Color(0.28, 0.3, 0.32)
	match kind:
		&"bed":
			var out: Array = []
			for x: float in [-0.95, 0.95]:
				for z: float in [-0.4, 0.4]:
					out.append(_b(0.05, 0.47, 0.05, x, 0, z, steel))
					out.append(_b(0.1, 0.06, 0.1, x, 0, z, dark))
			out.append(_b(2.0, 0.06, 0.9, 0, 0.45, 0, steel))
			out.append(_b(1.96, 0.16, 0.86, 0, 0.51, 0, Color(0.9, 0.92, 0.9)))
			out.append(_b(1.3, 0.03, 0.88, 0.3, 0.67, 0, Color(0.62, 0.76, 0.72)))
			out.append(_b(0.45, 0.1, 0.6, -0.7, 0.67, 0.05, Color(0.95, 0.95, 0.93)))
			out.append(_b(0.05, 0.55, 0.9, -1.0, 0.45, 0, steel))
			out.append(_b(0.05, 0.4, 0.9, 1.0, 0.45, 0, steel))
			out.append(_b(1.4, 0.04, 0.03, 0.2, 0.85, -0.44, steel))
			return out
		&"cabinet":
			var body := Color(0.55, 0.62, 0.58) if clinic else CABINET
			var trim := Color(0.42, 0.48, 0.45) if clinic else CABINET_DARK
			var out: Array = [
				_b(0.9, 2.0, 0.03, 0, 0, 0.285, body), _b(0.03, 2.0, 0.6, -0.435, 0, 0, body), _b(0.03, 2.0, 0.6, 0.435, 0, 0, body),
				_b(0.9, 0.04, 0.6, 0, 1.96, 0, body), _b(0.9, 0.08, 0.6, 0, 0, 0, trim),
				_b(0.03, 1.9, 0.03, 0, 0.08, -0.285, trim),
				_b(0.84, 0.5, 0.02, 0, 0.08, -0.29, body),
			]
			# The doors' slats from the knees up: gaps you can see out of.
			for i in 13:
				out.append(_b(0.84, 0.05, 0.02, 0, 0.62 + i * 0.1, -0.29, body))
			out.append(_b(0.84, 0.06, 0.02, 0, 1.92, -0.29, body))
			out.append(_b(0.03, 0.14, 0.03, -0.06, 1.05, -0.31, dark))
			out.append(_b(0.03, 0.14, 0.03, 0.06, 1.05, -0.31, dark))
			return out
		&"desk":
			var out: Array = [
				_b(1.6, 0.04, 0.8, 0, 0.72, 0, LAMINATE), _b(0.04, 0.72, 0.76, -0.78, 0, 0, DESK_EDGE),
				_b(0.04, 0.72, 0.76, 0.78, 0, 0, DESK_EDGE), _b(1.52, 0.66, 0.03, 0, 0.04, 0.37, DESK_EDGE),
				_b(0.42, 0.36, 0.42, 0.35, 0.76, 0.12, BEIGE), _b(0.34, 0.27, 0.012, 0.35, 0.805, -0.094, SCREEN),
				_b(0.46, 0.025, 0.16, 0.3, 0.76, -0.25, BEIGE_DARK), _b(0.22, 0.02, 0.3, -0.5, 0.76, -0.05, PAPER),
			]
			# Its chair is a piece of its own (sim/furniture.gd), pushed back to one side of the kneehole.
			return out
	var out: Array = [_b(1.8, 0.05, 1.0, 0, 0.71, 0, WOOD), _b(0.12, 0.71, 0.12, -0.8, 0, -0.4, WOOD_DARK),
		_b(0.12, 0.71, 0.12, 0.8, 0, -0.4, WOOD_DARK), _b(0.12, 0.71, 0.12, -0.8, 0, 0.4, WOOD_DARK), _b(0.12, 0.71, 0.12, 0.8, 0, 0.4, WOOD_DARK)]
	return out

## The Annex meeting room's table, the room's hide: 4.4 by 1.3 m on two wide legs (its chairs are pieces).
static func meeting_table_boxes() -> Array:
	return [_b(4.4, 0.05, 1.3, 0, 0.71, 0, WOOD), _b(0.3, 0.71, 0.8, -1.4, 0, 0, WOOD_DARK), _b(0.3, 0.71, 0.8, 1.4, 0, 0, WOOD_DARK)]

## Boxes (in `xf`'s frame) drawn into the level's `what` chunks.
static func draw_hide_into_boxes(level: Level, lvl: int, xf: Transform3D, boxes: Array, what: String) -> void:
	var st := level._st(lvl, xf.origin.x, xf.origin.z, what)
	for b: Array in boxes:
		box(st, xf, b[0], b[1], b[2])

## The floor footprint (world x, z) of boxes in `xf`'s frame.
static func boxes_rect(xf: Transform3D, boxes: Array) -> Rect2:
	var out := Rect2()
	var first := true
	for b: Array in boxes:
		var size: Vector3 = b[0]
		var c: Vector3 = b[1]
		for sx: float in [-0.5, 0.5]:
			for sz: float in [-0.5, 0.5]:
				var p := xf * (c + Vector3(size.x * sx, 0, size.z * sz))
				if first:
					out = Rect2(p.x, p.z, 0, 0)
					first = false
				else:
					out = out.expand(Vector2(p.x, p.z))
	return out

## Draws one hide's furniture into the level's `what` chunks.
static func draw_hide_into(level: Level, h: Playroom.Hide, clinic: bool, what: String) -> void:
	var xf := hide_xf(h)
	var st := level._st(h.level, xf.origin.x, xf.origin.z, what)
	for b: Array in hide_boxes(h.kind, clinic):
		box(st, xf, b[0], b[1], b[2])

func _draw_hide(h: Playroom.Hide) -> void:
	draw_hide_into(lv, h, false, "aprops")
	hide_pieces.append({"hide": h.id, "kind": String(h.kind), "level": h.level, "xf": hide_xf(h)})

# --- the check: same-shaped rooms are dressed the same ---------------------------------------------

## The room's props and pictures in its canonical frame by symmetry k, as sorted text lines.
func canonical_list(r: Dictionary, k: int) -> Array[String]:
	var inv := room_xf(r, k).affine_inverse()
	var out: Array[String] = []
	for rec: Dictionary in records:
		if int(rec.room) != int(r.id):
			continue
		var c: Transform3D = inv * (rec.xf as Transform3D)
		var f := c.basis * Vector3.FORWARD
		var ang := posmod(roundi(rad_to_deg(atan2(f.x, f.z))), 360)
		out.append("%s %.2f %.2f %.2f %d" % [rec.type, c.origin.x, c.origin.y, c.origin.z, ang])
	out.sort()
	return out

## Groups the floor's rooms by shape and compares their dressing, in the canonical frame. Returns the
## problems (empty: every pair of same-shaped rooms is dressed alike) and fills `stats` with
## {groups, rooms_compared, props}.
func same_shape_problems(stats: Dictionary) -> Array[String]:
	var groups := {}
	for r: Dictionary in lv.plan.rooms:
		var sh: Shape = shapes[int(r.id)]
		if not groups.has(sh.key):
			groups[sh.key] = []
		(groups[sh.key] as Array).append(r)
	var problems: Array[String] = []
	var compared := 0
	var multi := 0
	for key: String in groups:
		var rooms: Array = groups[key]
		if rooms.size() < 2:
			continue
		multi += 1
		var first: Dictionary = rooms[0]
		var want := canonical_list(first, (shapes[int(first.id)] as Shape).sym)
		for i in range(1, rooms.size()):
			var r: Dictionary = rooms[i]
			var sh: Shape = shapes[int(r.id)]
			var ok := false
			for k: int in sh.syms:
				if canonical_list(r, k) == want:
					ok = true
					break
			compared += 1
			if not ok:
				problems.append("room %d (%s at %d,%d level %d) is dressed unlike room %d (%s at %d,%d) of the same shape" % [
					int(r.id), str(r.kind), int(r.x), int(r.y), int(r.level), int(first.id), str(first.kind), int(first.x), int(first.y)])
	stats["groups"] = multi
	stats["rooms_compared"] = compared
	stats["props"] = records.size()
	return problems
