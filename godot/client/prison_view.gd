# The Prison hub's look (docs/floors/prison.md, section 4): the plan from sim/prison.gd dressed as
# painted concrete, grey-green below and cream above; steel doors with wire glass; one orange night
# light and a bunk in each of the eight cells, a number over each door; the bank room as the bright
# spot, a white strip light over a brass counter and four teller windows behind glass; the report board
# in the bank room and the day board beside the lift. In the day loop (client/main.gd) the report board
# shows the settled day's facts as the host sent them (report_text), the day board the day, what is owed
# and the bed count; the teller windows carry CLOSED TONIGHT cards; at lights out the ceiling lamps go
# dark and only the cells' orange night lights stay on.
# Level.build hands any plan whose place is "prison" here instead of the Clinic dressing. The walls,
# floors and ceilings are the Level's own geometry (doorways, the lift opening) with this file's
# materials; the rest is added as children of the Level. Nothing here is a rule.
extends RefCounted

const Floor = preload("res://sim/floor.gd")
const Walls = preload("res://sim/walls.gd")
const Landing = preload("res://sim/landing.gd")
const Run = preload("res://sim/run.gd")
const Prison = preload("res://sim/prison.gd")
const Day = preload("res://sim/day.gd")

const S := 2.0                         # Level.S, the cell size
const T := 0.07                        # half of Level.WALL_T: a wall face stands this far off the wall line
const DOOR_HALF := 0.55                # half of Level.DOOR_W
const FRAME_LAP := 0.005             # how far a door frame overlaps the wall's opening (no shared planes)
const LOW_PAINT := Color(0.33, 0.42, 0.37)
const HIGH_PAINT := Color(0.83, 0.79, 0.64)
const STEEL := Color(0.44, 0.48, 0.49)
const STEEL_DARK := Color(0.22, 0.25, 0.26)
const BRASS := Color(0.86, 0.66, 0.3)
const BRASS_DARK := Color(0.5, 0.36, 0.16)
const WOOD_DARK := Color(0.24, 0.2, 0.16)
const NIGHT := Color(1.0, 0.42, 0.1)
const HALL_LAMP := Color(0.95, 0.94, 0.82)
const BANK_LAMP := Color(0.93, 0.97, 1.0)
const SCREEN := Color(0.05, 0.08, 0.065)
const NIGHT_LIGHT_Y := 2.45
const PLATE_Y := 2.48
## The SHOP and SKILLS signs' height (m): their letters are 14 of the plate's 20 texel rows.
const SIGN_H := 0.4
## The teller windows tonight (buying comes with T18l): the card on each, and what F there says.
const CLOSED_TEXT := "CLOSED TONIGHT"
## A board's text: font pixels between lines, the margin, the colours.
const BOARD_LINE := 10
const BOARD_PAD := 4
const BOARD_INK := Color(0.72, 1.0, 0.78)
const BOARD_HEAD := Color(1.0, 0.82, 0.45)

const FACES := [
	[Vector3.RIGHT, Vector3.BACK, Vector3.UP], [Vector3.LEFT, Vector3.BACK, Vector3.UP],
	[Vector3.UP, Vector3.RIGHT, Vector3.BACK], [Vector3.DOWN, Vector3.RIGHT, Vector3.BACK],
	[Vector3.BACK, Vector3.RIGHT, Vector3.UP], [Vector3.FORWARD, Vector3.RIGHT, Vector3.UP],
]

var lv: Level
## The two boards, blank: draw into the image and call update on the texture to show text.
var day_board: MeshInstance3D
var day_board_image: Image
var day_board_texture: ImageTexture
var remission_notice: MeshInstance3D
var report_board: MeshInstance3D
var report_board_image: Image
var report_board_texture: ImageTexture
## The bank room's strip light and the lights it throws (empty if the room is unlit).
var bank_lights: Array[Light3D] = []
var bank_strip: MeshInstance3D
## One per cell, in bunk order 1..8.
var night_lights: Array[OmniLight3D] = []
## One per cell, in bunk order 1..8: the middle of the mattress, in the cell Prison.bunk_positions() names.
var bunk_centres: Array[Vector3] = []
## One per cell, in bunk order 1..8: the middle of the cabinet's door (S2; sim/shop.gd cabinet_cell is its stand cell).
var cabinet_centres: Array[Vector3] = []
## The four teller window panes' middles, in the plan's window order (Prison.WINDOWS: window 1 first,
## left to right for a player facing the counter).
var window_centres: Array[Vector3] = []
## The window signs' middles: "shop" over windows 1-2, "skills" over windows 3-4 (Prison.SHOP_WINDOWS,
## Prison.SKILLS_WINDOWS).
var sign_centres := {}
## The face kiosk in the hall (Prison.KIOSK): the middle of its screen, the screen, and the face on it
## (FaceCodec text, "" for the default face). set_kiosk_face shows another.
var kiosk_centre := Vector3.ZERO
var kiosk_screen: MeshInstance3D
var kiosk_face := ""
var _kiosk_img: Image
var _kiosk_tex: ImageTexture
## The ceiling lamps' glowing fittings (the hall's and the bank room's strip), dark at lights out; the
## cells' orange night lights stay on.
var lamp_meshes: Array[MeshInstance3D] = []
var lights_out := false
## What each board shows now (one string per line), for the tests.
var day_board_lines: Array[String] = []
var report_lines: Array[String] = []

var _sts := {}                         # Material -> SurfaceTool, static boxes merged per material
var _steel: ShaderMaterial
var _steel_dark: ShaderMaterial
var _brass: ShaderMaterial
var _brass_dark: ShaderMaterial
var _wood: ShaderMaterial
var _mattress: ShaderMaterial
var _blanket: ShaderMaterial
var _pillow: ShaderMaterial
var _glass: ShaderMaterial

## The prison plan as the client builds it: the same shape as RulesBridge's plan dump (the plan itself,
## its wall edges, the lift's wall and car, the walking distance from the lift), for showing the hub
## before the day loop hands it over through the bridge.
static func plain_plan() -> Dictionary:
	var p := Prison.prison_plan()
	var edges: Array = []
	for level in 2:
		var vertical: Array = []
		for y in p.height:
			for x in p.width + 1:
				vertical.append(String(Walls.west_edge(p, level, x, y)))
		var horizontal: Array = []
		for y in p.height + 1:
			for x in p.width:
				horizontal.append(String(Walls.north_edge(p, level, x, y)))
		edges.append({"vertical": vertical, "horizontal": horizontal})
	var lift_dist: Array = []
	for v: int in Floor.distances_from(p, p.landing):
		lift_dist.append(v)
	var out := Floor.plan_to_plain(p)
	out["edges"] = edges
	var wall := Landing.elevator_wall(p)
	out["elevatorWall"] = null if wall == &"" else String(wall)
	out["landingFacing"] = String(Landing.landing_facing(p))
	out["car"] = RulesBridge._car_plain(Run.car_geometry(p))
	out["liftDist"] = lift_dist
	return out

func dress(level: Level) -> void:
	lv = level
	_make_materials()
	lv._build_floors_and_ceilings()
	_teller_side_shell()
	lv._commit_chunks()
	# LA1: the doorways the cells and the bank room do not frame themselves (the lobby's onto the hall) get the
	# shared kit's frame, in the cells' dark steel (client/door_frames.gd).
	var frames := preload("res://client/door_frames.gd")
	frames.build(lv, STEEL_DARK, Color(0, 0, 0, 0), frames.STEEL_TEX, _framed_here)
	_hall()
	_kiosk()
	var bunks := Prison.bunk_positions()
	for i in bunks.size():
		bunk_centres.append(Vector3.ZERO)
		cabinet_centres.append(Vector3.ZERO)
		night_lights.append(null)
	for r: Dictionary in lv.plan.rooms:
		match str(r.kind):
			"closet":
				for i in bunks.size():
					if _in_room(r, bunks[i]):
						_cell(r, i + 1, bunks[i])
			"ward":
				_bank_room(r)
	_commit_boxes()
	if lv.shadows:
		for i in mini(Level.SHADOW_LIGHTS, lv.main_lights.size()):
			lv.main_lights[i].shadow_enabled = true
	lv.set_meta(&"prison", self)

# The walls, with the tellers' side behind the counter (Prison.TELLER_SIDE) drawn as part of the bank
# room: in the rules it is void, so the counter line is a wall no one walks through; in the drawing that
# wall is left out (the counter and glass stand there instead) and the void strip gets a floor, a
# ceiling and walls of its own. Only the drawing's copy of the edges changes, and only while walls are
# built.
func _teller_side_shell() -> void:
	var z := Prison.TELLER_SIDE
	var w := lv.W
	var saved: Dictionary = lv.edges[0]
	var vertical: Array = (saved.vertical as Array).duplicate()
	var horizontal: Array = (saved.horizontal as Array).duplicate()
	for x in range(z.position.x, z.end.x):
		horizontal[z.position.y * w + x] = "none"      # the counter line: glass, not wall
		horizontal[z.end.y * w + x] = "wall"           # the tellers' back wall
	for y in range(z.position.y, z.end.y):
		vertical[y * (w + 1) + z.position.x] = "wall"
		vertical[y * (w + 1) + z.end.x] = "wall"
		for x in range(z.position.x, z.end.x):
			lv._floor_quad(0, x, y, 0.0, true, "floor")
			lv._floor_quad(0, x, y, Level.LH - 0.001, false, "ceiling")
	lv.edges[0] = {"vertical": vertical, "horizontal": horizontal}
	lv._build_walls()
	lv.edges[0] = saved

## Whether this file frames the doorway between cells a and b itself (_doorway: a cell's or the bank room's).
func _framed_here(level: int, a: Vector2i, b: Vector2i) -> bool:
	for c: Vector2i in [a, b]:
		var r: int = lv.room_at[level][c.y * lv.W + c.x] if lv.kind(level, c.x, c.y) != "void" else -1
		if r >= 0 and str(lv.plan.rooms[r].kind) in ["closet", "ward"]:
			return true
	return false

# --- materials --------------------------------------------------------------------------------

func _surface(part: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://client/prison_surface.gdshader")
	m.set_shader_parameter("part", part)
	if part == 1.0:
		m.set_shader_parameter("concrete_tex", preload("res://assets/textures/prison_concrete.png"))
	m.set_shader_parameter("low_paint", LOW_PAINT)
	m.set_shader_parameter("high_paint", HIGH_PAINT)
	m.set_shader_parameter("dado", 1.3)
	m.set_shader_parameter("storey", Level.LH)
	return m

func _make_materials() -> void:
	lv.mat_wall = _surface(0.0)
	lv.mat_floor = _surface(1.0)
	lv.mat_ceiling = _surface(2.0)
	lv.mat_ceiling.set_shader_parameter("self_light", 0.1)
	lv.mat_rail = Level.prop_material(STEEL)
	lv.mat_glow = Level.glow_material(Color.WHITE, 1.0)
	_steel = Level.prop_material(STEEL)
	_steel_dark = Level.prop_material(STEEL_DARK)
	_brass = Level.prop_material(BRASS, null, false, 0.0, 0.06)
	_brass_dark = Level.prop_material(BRASS_DARK)
	_wood = Level.prop_material(WOOD_DARK)
	_mattress = Level.prop_material(Color(0.5, 0.52, 0.48))
	_blanket = Level.prop_material(Color(0.22, 0.27, 0.33))
	_pillow = Level.prop_material(Color(0.8, 0.78, 0.71))
	_glass = ShaderMaterial.new()
	_glass.shader = load("res://client/wire_glass.gdshader")

# --- building blocks --------------------------------------------------------------------------

# An axis-aligned box, merged with every other box of the same material.
func _box(mat: Material, centre: Vector3, size: Vector3) -> void:
	var st: SurfaceTool = _sts.get(mat)
	if st == null:
		st = SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_sts[mat] = st
	var h := size * 0.5
	for f: Array in FACES:
		var n: Vector3 = f[0]
		var u: Vector3 = f[1]
		var v: Vector3 = f[2]
		var c := centre + n * h
		var du := u * h
		var dv := v * h
		var p := [c - du - dv, c + du - dv, c + du + dv, c - du + dv]
		var p0: Vector3 = p[0]
		var p1: Vector3 = p[1]
		var p3: Vector3 = p[3]
		var order: Array[int] = [0, 1, 2, 3]
		if (p1 - p0).cross(p3 - p0).dot(n) > 0:
			order = [0, 3, 2, 1]
		for i: int in [0, 1, 2, 0, 2, 3]:
			var q: Vector3 = p[order[i]]
			st.set_normal(n)
			st.set_color(Color.WHITE)
			st.set_uv(Vector2(q.dot(u), q.dot(v)) * 0.5)
			st.add_vertex(q)

func _commit_boxes() -> void:
	for mat: Material in _sts:
		var st: SurfaceTool = _sts[mat]
		st.index()
		var mi := MeshInstance3D.new()
		mi.mesh = st.commit()
		mi.material_override = mat
		mi.name = "Prison_%s" % _mat_name(mat)
		if mat == _glass:
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		lv.add_child(mi)
	_sts.clear()

func _mat_name(mat: Material) -> String:
	if mat == _steel: return "steel"
	if mat == _steel_dark: return "steel_dark"
	if mat == _brass: return "brass"
	if mat == _brass_dark: return "brass_dark"
	if mat == _wood: return "wood"
	if mat == _glass: return "glass"
	return "cloth"

# A point in a doorway's frame: `mid` the middle of the opening on the wall line, `side` along the wall,
# `fwd` into the room beyond, `y` up from the floor.
static func _w(mid: Vector3, side: Vector3, fwd: Vector3, s: float, f: float, y: float) -> Vector3:
	return mid + side * s + fwd * f + Vector3(0, y, 0)

# A box size in the same frame (side and fwd are axis-aligned).
static func _sz(side: Vector3, fwd: Vector3, ss: float, ff: float, hh: float) -> Vector3:
	return side.abs() * ss + fwd.abs() * ff + Vector3(0, hh, 0)

# A glowing fixture (its own mesh: unshaded, casts no shadow).
func _lamp(name: String, centre: Vector3, size: Vector3, col: Color, energy: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = Level.glow_material(col, energy)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = centre
	mi.name = name
	lv.add_child(mi)
	return mi

# A downward spot that the Level's light dial and shadow picker look after.
func _spot(name: String, pos: Vector3, col: Color, energy: float, reach: float, angle: float) -> SpotLight3D:
	var light := SpotLight3D.new()
	light.name = name
	light.position = pos
	light.rotation_degrees = Vector3(-90, 0, 0)
	light.spot_angle = angle
	light.spot_angle_attenuation = 0.6
	light.spot_range = reach
	light.light_color = col
	light.light_energy = energy
	light.shadow_enabled = false
	light.shadow_bias = 0.04
	light.distance_fade_enabled = true
	light.distance_fade_begin = 16.0
	light.distance_fade_length = 6.0
	light.distance_fade_shadow = 12.0
	lv.add_child(light)
	lv.main_lights.append(light)
	lv._base_energy.append(energy)
	return light

# A small enamel plate with text in the camcorder font, on a wall face, facing `n`.
func _plate(name: String, text: String, centre: Vector3, n: Vector3, height: float, bg: Color, ink: Color, emit := 0.0) -> MeshInstance3D:
	var sc := 2
	var pad := 3
	var w := PixelFont.width(text) * sc + pad * 2
	var h := 7 * sc + pad * 2
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(bg)
	var edge := bg.darkened(0.45)
	for x in w:
		img.set_pixel(x, 0, edge)
		img.set_pixel(x, h - 1, edge)
	for y in h:
		img.set_pixel(0, y, edge)
		img.set_pixel(w - 1, y, edge)
	PixelFont.blit(img, text, Vector2i(pad, pad), ink, Vector2i(sc, sc))
	img.generate_mipmaps()
	var q := QuadMesh.new()
	q.size = Vector2(height * float(w) / float(h), height)
	var mi := MeshInstance3D.new()
	mi.name = name
	mi.mesh = q
	mi.material_override = Level.prop_material(Color.WHITE, ImageTexture.create_from_image(img), false, 0.0, emit)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_face(mi, centre, n)
	lv.add_child(mi)
	return mi

# Places a quad at `centre` with its front toward `n`.
static func _face(mi: Node3D, centre: Vector3, n: Vector3) -> void:
	mi.position = centre
	mi.basis = Basis.looking_at(n, Vector3.UP)
	mi.rotate_object_local(Vector3.UP, PI)

# A blank board: a frame on the wall and a dark screen in it, ready for text. Returns [mesh, image, texture].
func _board(name: String, centre: Vector3, n: Vector3, size: Vector2, frame_mat: Material) -> Array:
	var along := Vector3(-n.z, 0, n.x)
	_box(frame_mat, centre - n * 0.02, along.abs() * (size.x + 0.1) + n.abs() * 0.04 + Vector3(0, size.y + 0.1, 0))
	var img := Image.create(192, int(192.0 * size.y / size.x), false, Image.FORMAT_RGBA8)
	img.fill(SCREEN)
	var tex := ImageTexture.create_from_image(img)
	var q := QuadMesh.new()
	q.size = size
	var mi := MeshInstance3D.new()
	mi.name = name
	mi.mesh = q
	mi.material_override = Level.glow_material(Color.WHITE, 1.0, tex)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_face(mi, centre + n * 0.002, n)
	lv.add_child(mi)
	return [mi, img, tex]

# A steel door frame round an opening, and the steel door swung open into the room beyond, with a
# wire-glass window. `hinge` is -1 or 1: which jamb carries the door (the room must have wall there).
func _doorway(mid: Vector3, side: Vector3, fwd: Vector3, hinge: float) -> void:
	# No face of the frame may lie in the plane of a wall face or of another frame face, or the two
	# flicker as the camera moves (z-fighting). So the jambs stand FRAME_LAP into the opening (covering
	# the wall's reveal instead of sharing its plane) and stop at the header's underside; the header
	# hangs FRAME_LAP below the lintel, reaches past the jambs and stands prouder than they do.
	var dh := Level.DOOR_H
	var depth := Level.WALL_T + 0.04
	var j0 := DOOR_HALF - FRAME_LAP
	var j1 := DOOR_HALF + 0.06
	var top := dh - FRAME_LAP
	for sgn: float in [-1.0, 1.0]:
		_box(_steel_dark, _w(mid, side, fwd, sgn * (j0 + j1) * 0.5, 0.0, top * 0.5), _sz(side, fwd, j1 - j0, depth, top))
	_box(_steel_dark, _w(mid, side, fwd, 0.0, 0.0, (top + dh + 0.06) * 0.5), _sz(side, fwd, (j1 + 0.005) * 2.0, depth + 0.01, dh + 0.06 - top))
	# The leaf, swung all the way open and standing flat against the inside of the wall, so the
	# doorway shows the room beyond: steel, with a wire-glass window.
	var f := T + 0.035
	var a := hinge * DOOR_HALF
	var b := hinge * (DOOR_HALF + Level.DOOR_W - 0.04)
	var s0 := minf(a, b)
	var s1 := maxf(a, b)
	var g0 := s0 + 0.3
	var g1 := s0 + 0.76
	var y0 := 1.25
	var y1 := 1.8
	top = dh - 0.03
	var th := 0.05
	_box(_steel, _w(mid, side, fwd, (s0 + s1) * 0.5, f, (0.02 + y0) * 0.5), _sz(side, fwd, s1 - s0, th, y0 - 0.02))
	_box(_steel, _w(mid, side, fwd, (s0 + s1) * 0.5, f, (y1 + top) * 0.5), _sz(side, fwd, s1 - s0, th, top - y1))
	_box(_steel, _w(mid, side, fwd, (s0 + g0) * 0.5, f, (y0 + y1) * 0.5), _sz(side, fwd, g0 - s0, th, y1 - y0))
	_box(_steel, _w(mid, side, fwd, (g1 + s1) * 0.5, f, (y0 + y1) * 0.5), _sz(side, fwd, s1 - g1, th, y1 - y0))
	_box(_glass, _w(mid, side, fwd, (g0 + g1) * 0.5, f, (y0 + y1) * 0.5), _sz(side, fwd, g1 - g0, 0.012, y1 - y0))
	# A handle near the free edge, on the room side.
	_box(_steel_dark, _w(mid, side, fwd, b - hinge * 0.1, f + 0.045, 1.0), _sz(side, fwd, 0.04, 0.04, 0.16))

# The doorway of a room: [cell inside the room, cell outside], or [] if it has none.
func _door_of(r: Dictionary) -> Array:
	for d: Dictionary in lv.plan.doors:
		var a := Vector2i(int(d.ax), int(d.ay))
		var b := Vector2i(int(d.bx), int(d.by))
		if _in_room(r, a):
			return [a, b]
		if _in_room(r, b):
			return [b, a]
	return []

static func _in_room(r: Dictionary, c: Vector2i) -> bool:
	return c.x >= int(r.x) and c.y >= int(r.y) and c.x < int(r.x) + int(r.w) and c.y < int(r.y) + int(r.h)

# A doorway's frame: [mid, side, fwd, room width along side, room depth along fwd, centre offset along side].
func _frame_of(r: Dictionary) -> Array:
	var dd := _door_of(r)
	var inside: Vector2i = dd[0]
	var outside: Vector2i = dd[1]
	var fwd := Vector3(inside.x - outside.x, 0, inside.y - outside.y)
	var mid := (lv.cell_center(0, inside.x, inside.y) + lv.cell_center(0, outside.x, outside.y)) * 0.5
	var side := Vector3(-fwd.z, 0, fwd.x)
	var centre := Vector3((int(r.x) + int(r.w) * 0.5) * S, 0, (int(r.y) + int(r.h) * 0.5) * S)
	var sc := (centre - mid).dot(side)
	if sc < 0.0:
		side = -side
		sc = -sc
	var width := float(int(r.w) if absf(fwd.z) > 0.5 else int(r.h)) * S
	var depth := float(int(r.h) if absf(fwd.z) > 0.5 else int(r.w)) * S
	return [mid, side, fwd, width, depth, sc]

# --- the hall ---------------------------------------------------------------------------------

func _hall() -> void:
	var lamps: Array[Vector2i] = [Prison.LANDING_CELL]
	for x in range(Prison.HALL_X0, Prison.HALL_X1 + 1, 2):
		lamps.append(Vector2i(x, Prison.HALL_ROW))
	for c in lamps:
		var p := lv.cell_center(0, c.x, c.y)
		var top := Level.LH
		_box(_steel_dark, Vector3(p.x, top - 0.02, p.z), Vector3(0.46, 0.04, 0.32))
		lamp_meshes.append(_lamp("HallLamp_%d" % c.x, Vector3(p.x, top - 0.065, p.z), Vector3(0.36, 0.05, 0.22), HALL_LAMP, 1.15))
		# A wire cage over the lens.
		for k: float in [-0.12, 0.0, 0.12]:
			_box(_steel_dark, Vector3(p.x + k, top - 0.1, p.z), Vector3(0.012, 0.012, 0.26))
		var energy := 0.45 if c == Prison.LANDING_CELL else 0.7
		_spot("HallLight_%d" % c.x, Vector3(p.x, top - 0.12, p.z), HALL_LAMP, energy, 7.0, 80.0)
	# The day board, beside the lift doors: on the hall wall across from the first cell, facing the hall.
	var db := lv.cell_center(0, Prison.DAY_BOARD.x, Prison.DAY_BOARD.y)
	var n := Vector3(0, 0, -1)
	var wall_z := (Prison.DAY_BOARD.y + 1) * S - T
	var b := _board("DayBoard", Vector3(db.x, 1.62, wall_z - 0.045), n, Vector2(1.3, 0.85), _steel_dark)
	day_board = b[0]
	day_board_image = b[1]
	day_board_texture = b[2]
	_plate("DayBoardTitle", "TODAY", Vector3(db.x, 2.2, wall_z - 0.012), n, 0.14, Color(0.82, 0.8, 0.7), Color(0.1, 0.1, 0.1))

# --- the face kiosk ---------------------------------------------------------------------------

## What F does where a player stands (Prison.station_at), as the prompt line says it; "" for nothing.
static func prompt_for(cell: Vector2i) -> String:
	match Prison.station_at(cell):
		&"shop":
			return "F  SHOP"
		&"skills":
			return "F  SKILL TREE"
		&"kiosk":
			return "F  CHANGE YOUR FACE"
	return ""

## The fallback when a window is unavailable. The face kiosk remains open.
static func tonight_prompt_for(cell: Vector2i) -> String:
	match Prison.station_at(cell):
		&"shop":
			return "SHOP  " + CLOSED_TEXT
		&"skills":
			return "SKILL TREE  " + CLOSED_TEXT
	return prompt_for(cell)

# The face kiosk against the hall wall on Prison.KIOSK_FACING's side of its stand cell: a steel cabinet
# with a brass ledge, an upper housing with a lit screen showing your face and a camera lens over it,
# and a plate on the wall above. Stands Prison.KIOSK_DEPTH_M out from the wall.
func _kiosk() -> void:
	var k := Prison.KIOSK
	var c := lv.cell_center(0, k.x, k.y)
	var f := Vector3(Prison.KIOSK_FACING.x, 0, Prison.KIOSK_FACING.y)
	var out := -f
	var along := Vector3(-f.z, 0, f.x)
	var wall := Vector3(c.x, 0, c.z) + f * (S * 0.5 - T)
	var d := Prison.KIOSK_DEPTH_M
	var wd := 0.72
	_box(_steel_dark, wall + out * (d * 0.5) + Vector3(0, 0.5, 0), _sz(along, f, wd, d, 1.0))
	_box(_brass, wall + out * (d * 0.5 + 0.01) + Vector3(0, 1.02, 0), _sz(along, f, wd + 0.04, d + 0.02, 0.04))
	_box(_steel, wall + out * 0.08 + Vector3(0, 1.48, 0), _sz(along, f, wd, 0.16, 0.88))
	# The screen's bezel, the screen, and the camera lens over it.
	_box(_steel_dark, wall + out * 0.165 + Vector3(0, 1.47, 0), _sz(along, f, 0.52, 0.012, 0.52))
	_box(_steel_dark, wall + out * 0.17 + Vector3(0, 1.82, 0), _sz(along, f, 0.07, 0.03, 0.07))
	_kiosk_img = Image.create(FaceCodec.SIZE, FaceCodec.SIZE, false, Image.FORMAT_RGB8)
	_kiosk_tex = ImageTexture.create_from_image(_kiosk_img)
	var q := QuadMesh.new()
	q.size = Vector2(0.44, 0.44)
	kiosk_screen = MeshInstance3D.new()
	kiosk_screen.name = "KioskScreen"
	kiosk_screen.mesh = q
	kiosk_screen.material_override = Level.glow_material(Color.WHITE, 0.95, _kiosk_tex)
	kiosk_screen.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	kiosk_centre = wall + out * 0.173 + Vector3(0, 1.47, 0)
	_face(kiosk_screen, kiosk_centre, out)
	lv.add_child(kiosk_screen)
	set_kiosk_face("")
	_plate("KioskSign", "YOUR FACE", wall + out * 0.012 + Vector3(0, 2.12, 0), out, 0.16, Color(0.86, 0.84, 0.74), Color(0.08, 0.08, 0.08), 0.15)

## LS1 (North Star B7): the standee of the last player caught at the night's latest wipe, in the lift lobby's far corner
## by the hall, turned to the car's doors so the crew meets it as they step out. `code` that player's face (FaceCodec
## text, "" the default), `who` their name; an empty `who` with an empty `code` takes it away. Called every frame:
## rebuilt only when the face or the name changes.
var standee: Node3D = null

func show_standee(code: String, who: String) -> void:
	if standee != null and is_instance_valid(standee) and str(standee.get("face_code")) == code and str(standee.get("player_name")) == who:
		return
	if standee != null and is_instance_valid(standee):
		standee.queue_free()
	standee = null
	if who == "" and code == "":
		return
	var s: Node3D = (load("res://client/standee.gd") as GDScript).new()
	s.name = "Standee"
	s.call(&"build", code, who)
	var c := lv.cell_center(0, Prison.LANDING_CELL.x, Prison.LANDING_CELL.y)
	var at := Vector3(c.x + S * 0.3, 0.0, c.z - S * 0.3)
	var door := Vector3(c.x - S * 0.5, 0.0, c.z)
	s.position = at
	s.rotation.y = atan2(door.x - at.x, door.z - at.z)
	lv.add_child(s)
	standee = s

## Display each service's current hours on the cards behind the glass.
func set_shop_open(on: bool, skills_open := false) -> void:
	_set_window_cards(Prison.SHOP_WINDOWS, on)
	_set_window_cards(Prison.SKILLS_WINDOWS, skills_open)

func _set_window_cards(windows: Array[int], on: bool) -> void:
	for n in windows:
		var card := lv.get_node_or_null("WindowClosed_%d" % n) as Node3D
		if card != null and card.visible == on:
			card.visible = not on

## Shows `code` (FaceCodec text) on the kiosk's screen; "" or a face that does not decode shows the
## default face.
func set_kiosk_face(code: String) -> void:
	if _kiosk_tex == null:
		return
	var px := FaceCodec.decode_indices(code)
	kiosk_face = code if not px.is_empty() else ""
	var img: Image
	if px.is_empty():
		img = CrewView.default_face().get_image()
		img.resize(FaceCodec.SIZE, FaceCodec.SIZE, Image.INTERPOLATE_NEAREST)
	else:
		img = FaceCodec.to_image(px)
	img.convert(Image.FORMAT_RGB8)
	_kiosk_img = img
	_kiosk_tex.set_image(img)

## Tests: a short hash of the picture on the kiosk's screen (comparable with CrewView.texture_hash of
## the decoded face).
func kiosk_face_hash() -> String:
	return CrewView.image_hash(_kiosk_img) if _kiosk_img != null else ""

# A sign over a group of teller windows (numbers as in Prison.WINDOWS), on the fascia's front.
func _window_sign(key: String, text: String, numbers: Array[int], gz: float, bg: Color, ink: Color) -> void:
	var sx := 0.0
	for n in numbers:
		sx += window_centres[n - 1].x
	var centre := Vector3(sx / numbers.size(), 2.98, gz + 0.3 - 0.062)
	_plate("WindowSign_%s" % key, text, centre, Vector3(0, 0, -1), SIGN_H, bg, ink, 0.3)
	sign_centres[key] = centre

# --- the cells --------------------------------------------------------------------------------

# One cell: its door, its number, and its bunk in `bunk` (the plan's bunk cell), against the far wall
# of that cell from the door and along the cell's wall on the door side.
func _cell(r: Dictionary, number: int, bunk: Vector2i) -> void:
	var fr := _frame_of(r)
	var mid: Vector3 = fr[0]
	var side: Vector3 = fr[1]
	var fwd: Vector3 = fr[2]
	var width: float = fr[3]
	var depth: float = fr[4]
	var sc: float = fr[5]
	var s_hi := sc + width * 0.5 - T     # the inner face of the side wall away from the door
	var back := depth - T                # the inner face of the back wall
	# The bunk's cell in this frame: its middle along the wall and into the room.
	var bc := lv.cell_center(0, bunk.x, bunk.y) - mid
	var b_side := bc.dot(side)
	var b_fwd := bc.dot(fwd)
	var s_lo := b_side - S * 0.5 + T     # the bunk cell's edge on the door side, less the wall face
	var b_back := b_fwd + S * 0.5 - T    # the bunk cell's far edge from the door, less the wall face
	_doorway(mid, side, fwd, 1.0)
	# The number over the door, on the hall side.
	_plate("CellNumber_%d" % number, str(number), _w(mid, side, fwd, 0.0, -T - 0.012, PLATE_Y), -fwd, 0.28,
		Color(0.86, 0.84, 0.74), Color(0.08, 0.08, 0.08), 0.1)
	# The bunk along the back wall, in line with the door so it shows from the hall.
	var bl := 2.0
	var bd := 0.8
	var bs := s_lo + 0.04 + bl * 0.5
	var bf := b_back - 0.02 - bd * 0.5
	for ls: float in [-1.0, 1.0]:
		for lf: float in [-1.0, 1.0]:
			_box(_steel, _w(mid, side, fwd, bs + ls * (bl * 0.5 - 0.04), bf + lf * (bd * 0.5 - 0.04), 0.19), _sz(side, fwd, 0.05, 0.05, 0.38))
	_box(_steel, _w(mid, side, fwd, bs, bf, 0.42), _sz(side, fwd, bl, bd, 0.08))
	_box(_mattress, _w(mid, side, fwd, bs, bf, 0.52), _sz(side, fwd, bl - 0.08, bd - 0.08, 0.12))
	_box(_pillow, _w(mid, side, fwd, s_lo + 0.32, bf, 0.62), _sz(side, fwd, 0.42, bd - 0.2, 0.09))
	_box(_blanket, _w(mid, side, fwd, bs + 0.3, bf + 0.02, 0.595), _sz(side, fwd, bl - 0.65, bd - 0.04, 0.03))
	bunk_centres[number - 1] = _w(mid, side, fwd, bs, bf, 0.5)
	# The night light on the back wall over the bunk: a caged orange lamp, and its light.
	var lp := _w(mid, side, fwd, bs, b_back - 0.07, NIGHT_LIGHT_Y)
	_box(_steel_dark, _w(mid, side, fwd, bs, b_back - 0.015, NIGHT_LIGHT_Y), _sz(side, fwd, 0.34, 0.03, 0.24))
	_lamp("NightLamp_%d" % number, lp, _sz(side, fwd, 0.24, 0.1, 0.14), NIGHT, 3.0)
	for k: float in [-0.08, 0.0, 0.08]:
		_box(_steel_dark, _w(mid, side, fwd, bs + k, b_back - 0.13, NIGHT_LIGHT_Y), _sz(side, fwd, 0.012, 0.012, 0.18))
	var o := OmniLight3D.new()
	o.name = "NightLight_%d" % number
	o.position = _w(mid, side, fwd, bs, b_back - 0.45, NIGHT_LIGHT_Y - 0.1)
	o.light_color = NIGHT
	o.light_energy = 1.8
	# Reach the cell's far corner and not much more: the light has no shadow, so a longer reach
	# shines through the front wall and turns the hall orange.
	o.omni_range = 2.9
	o.omni_attenuation = 1.1
	o.distance_fade_enabled = true
	o.distance_fade_begin = 20.0
	o.distance_fade_length = 5.0
	lv.add_child(o)
	night_lights[number - 1] = o
	# A steel toilet and basin in the other back corner.
	var ts := s_hi - 0.3
	_box(_steel, _w(mid, side, fwd, ts, back - 0.3, 0.21), _sz(side, fwd, 0.42, 0.55, 0.42))
	_box(_steel, _w(mid, side, fwd, ts, back - 0.17, 0.86), _sz(side, fwd, 0.4, 0.3, 0.12))
	_box(_steel_dark, _w(mid, side, fwd, ts, back - 0.04, 0.6), _sz(side, fwd, 0.36, 0.06, 0.6))
	# The cabinet (S2, T29; sim/shop.gd cabinet_cell): a steel locker against the back wall beside the bunk's foot, in
	# the cell's other column, where its player stands to open it. The plate says whose cell it is.
	var cs := s_lo + bl + 0.5
	var cd := 0.45
	_box(_steel, _w(mid, side, fwd, cs, back - cd * 0.5, 0.9), _sz(side, fwd, 0.62, cd, 1.8))
	_box(_steel_dark, _w(mid, side, fwd, cs, back - cd - 0.006, 0.95), _sz(side, fwd, 0.54, 0.012, 1.6))
	for k: float in [1.55, 1.62, 1.69]:
		_box(_steel, _w(mid, side, fwd, cs, back - cd - 0.014, k), _sz(side, fwd, 0.36, 0.008, 0.02))
	_box(_brass, _w(mid, side, fwd, cs + 0.2, back - cd - 0.02, 1.0), _sz(side, fwd, 0.03, 0.02, 0.14))
	cabinet_centres[number - 1] = _w(mid, side, fwd, cs, back - cd, 1.0)

# --- the bank room ----------------------------------------------------------------------------

func _bank_room(r: Dictionary) -> void:
	var x0 := int(r.x) * S + T
	var x1 := (int(r.x) + int(r.w)) * S - T
	var z_back := Prison.TELLER_SIDE.end.y * S - T   # the tellers' back wall, behind the glass
	var cx := (x0 + x1) * 0.5
	# The glass line: the far edge of the window stand cells (the plan's window row).
	var gz := (Prison.WINDOWS[0].y + 1) * S
	var fr := _frame_of(r)
	var mid: Vector3 = fr[0]
	var side: Vector3 = fr[1]
	var fwd: Vector3 = fr[2]
	_doorway(mid, side, fwd, 1.0)
	_plate("BankSign", "BANK", _w(mid, side, fwd, 0.0, -T - 0.012, PLATE_Y), -fwd, 0.2, BRASS, Color(0.12, 0.08, 0.03), 0.15)
	# The brass counter, its customer face on the glass line.
	var ch := 1.0
	_box(_brass_dark, Vector3(cx, ch * 0.5, gz + 0.3), Vector3(x1 - x0, ch, 0.6))
	_box(_brass, Vector3(cx, ch + 0.03, gz + 0.26), Vector3(x1 - x0, 0.06, 0.72))
	# The rail and the kick plate stop short of the counter's ends and the kick plate clears the floor,
	# so none of their faces shares a plane with the counter's (z-fighting).
	_box(_brass, Vector3(cx, 0.55, gz - 0.005), Vector3(x1 - x0 - 0.02, 0.04, 0.02))
	_box(_steel_dark, Vector3(cx, 0.063, gz - 0.005), Vector3(x1 - x0 - 0.02, 0.12, 0.02))
	# Four windows: brass mullions, glass with a slot at the bottom, a fascia over them with numbers.
	var gy0 := ch + 0.06
	var gy1 := 2.42
	var n_win := Prison.WINDOWS.size()
	var pane := (x1 - x0) / n_win
	for i in n_win + 1:
		var mx := x0 + pane * i
		_box(_brass, Vector3(mx, (gy0 + gy1) * 0.5, gz + 0.3), Vector3(0.07, gy1 - gy0, 0.07))
	for i in n_win:
		# Window i (number i + 1) is the pane in front of its stand cell, Prison.WINDOWS[i].
		var px := x0 + pane * (Prison.WINDOWS[i].x - int(r.x) + 0.5)
		_box(_glass, Vector3(px, (gy0 + 0.09 + gy1) * 0.5, gz + 0.3), Vector3(pane - 0.07, gy1 - gy0 - 0.09, 0.012))
		# The speaking grille, a steel disc in the glass.
		_box(_steel_dark, Vector3(px, 1.58, gz + 0.3), Vector3(0.16, 0.16, 0.02))
		window_centres.append(Vector3(px, 1.6, gz + 0.3))
		_plate("WindowNumber_%d" % (i + 1), str(i + 1), Vector3(px, 2.64, gz + 0.3 - 0.06), Vector3(0, 0, -1), 0.24, BRASS, Color(0.12, 0.08, 0.03), 0.2)
		# This card is removed while the service is open.
		_plate("WindowClosed_%d" % (i + 1), CLOSED_TEXT, Vector3(px, 1.92, gz + 0.3 - 0.015), Vector3(0, 0, -1), 0.11, Color(0.86, 0.84, 0.74), Color(0.55, 0.08, 0.05), 0.2)
	_box(_brass, Vector3(cx, gy1 + 0.03, gz + 0.3), Vector3(x1 - x0, 0.06, 0.08))
	_box(_wood, Vector3(cx, (gy1 + 0.06 + Level.LH) * 0.5, gz + 0.3), Vector3(x1 - x0, Level.LH - gy1 - 0.06, 0.1))
	# What the windows are for, on the fascia over them: SHOP over windows 1-2, SKILLS over 3-4.
	_window_sign("shop", "SHOP", Prison.SHOP_WINDOWS, gz, BRASS, Color(0.12, 0.08, 0.03))
	_window_sign("skills", "SKILLS", Prison.SKILLS_WINDOWS, gz, Color(0.86, 0.84, 0.74), Color(0.1, 0.12, 0.1))
	# Behind the glass: the tellers' side, booths parted by dark wood, a stool in each, a dim lamp.
	for i in range(1, n_win):
		var bx := x0 + pane * i
		_box(_wood, Vector3(bx, 0.9, (gz + 0.6 + z_back) * 0.5), Vector3(0.06, 1.8, z_back - gz - 0.6))
	for i in n_win:
		var px := x0 + pane * (i + 0.5)
		_box(_steel_dark, Vector3(px, 0.35, gz + 1.15), Vector3(0.05, 0.7, 0.05))
		_box(_wood, Vector3(px, 0.72, gz + 1.15), Vector3(0.36, 0.05, 0.36))
	var back_lamp := OmniLight3D.new()
	back_lamp.name = "TellerLamp"
	back_lamp.position = Vector3(cx, 2.6, (gz + z_back) * 0.5 + 0.3)
	back_lamp.light_color = Color(1.0, 0.92, 0.75)
	back_lamp.light_energy = 0.35
	back_lamp.omni_range = 5.0
	lv.add_child(back_lamp)
	# The report board on the east wall, in front of its stand cell.
	var rb := lv.cell_center(0, Prison.REPORT_BOARD.x, Prison.REPORT_BOARD.y)
	var b := _board("ReportBoard", Vector3(x1 - 0.045, 1.62, rb.z), Vector3(-1, 0, 0), Vector2(1.6, 1.0), _brass)
	report_board = b[0]
	report_board_image = b[1]
	report_board_texture = b[2]
	_plate("ReportBoardTitle", "REPORT", Vector3(x1 - 0.012, 2.27, rb.z), Vector3(-1, 0, 0), 0.14, BRASS, Color(0.12, 0.08, 0.03), 0.15)
	remission_notice = _plate("RemissionNotice", "REMISSION TABLE", Vector3(x1 - 0.017, 1.65, rb.z + 1.77),
		Vector3(-1, 0, 0), 0.16, Color("#c4b994"), Color("#292316"), 0.15)
	remission_notice.hide()
	_strip_light(x0, x1, gz)

# The bank room's white strip light across the room in front of the counter, and the light it throws.
func _strip_light(x0: float, x1: float, gz: float) -> void:
	var cx := (x0 + x1) * 0.5
	var z := gz - 1.2
	var top := Level.LH
	var length := (x1 - x0) - 1.6
	_box(_steel, Vector3(cx, top - 0.015, z), Vector3(length + 0.12, 0.03, 0.22))
	bank_strip = _lamp("BankStrip", Vector3(cx, top - 0.05, z), Vector3(length, 0.05, 0.13), BANK_LAMP, 3.0)
	lamp_meshes.append(bank_strip)
	for k: float in [-0.36, 0.0, 0.36]:
		bank_lights.append(_spot("BankLight_%d" % bank_lights.size(), Vector3(cx + k * length, top - 0.1, z), BANK_LAMP, 2.4, 8.0, 88.0))
	var fill := OmniLight3D.new()
	fill.name = "BankFill"
	fill.position = Vector3(cx, 2.4, z - 2.0)
	fill.light_color = BANK_LAMP
	fill.light_energy = 1.0
	fill.omni_range = 6.5
	lv.add_child(fill)
	bank_lights.append(fill)

## The notice shares the bank room with the report, one wall section toward the shop.
func show_remission_notice(on: bool) -> void:
	if remission_notice != null:
		remission_notice.visible = on

func remission_in_reach(eye: Vector3, look: Vector3) -> bool:
	if remission_notice == null or not remission_notice.visible:
		return false
	var offset := remission_notice.global_position - eye
	return offset.length() <= 1.7 and look.dot(offset.normalized()) >= 0.72

# --- the boards and the night (the day loop on screen) -------------------------------------------

## The report board's lines from the settled day's facts (the host's day block "result": sim/day.gd
## _facts plus "shares" and "credits"), every number as the host settled it. `names`: id -> name.
static func report_text(result: Variant, names: Dictionary) -> Array[String]:
	var out: Array[String] = []
	if not result is Dictionary:
		out.append("NO REPORT YET")
		return out
	var r: Dictionary = result
	var kind := str(r.get("kind", ""))
	# A wipe is the missed day whatever was earned (FD1): it is never "short", and "SHORT BY 0" (a wipe after
	# the quota was met) would read as a mistake.
	var wiped := bool(r.get("wiped", false))
	var verdict := "MADE" if kind == "made" else ("GAME OVER" if kind == "game_over" else ("NOBODY CAME BACK" if wiped else "SHORT"))
	out.append("DAY %d  %s" % [int(r["day"]), verdict])
	out.append("OWED %d  BANKED %d" % [int(r["quota"]), int(r["banked"])])
	if wiped:
		out.append("EARNED %d: NOTHING CAME BACK" % int(r.get("earned", 0)))
	else:
		out.append("SHORT BY %d" % int(r["short_by"]))
	out.append("STREAK %d  MISSES LEFT %d" % [int(r["streak"]), int(r["misses_left"])])
	# The odds of the roll a miss makes, always printed (promise 2): the rules' own words, with names.
	var odds := str(r.get("odds", ""))
	if kind == "made":
		out.append("NO ROLL: THE DAY WAS MADE")
	elif kind == "game_over":
		# PY1: the third miss keeps the credits (sim/day.gd keep_credits); the facts say so.
		out.append("THIRD MISS: UPGRADES RESET, CREDITS KEPT" if bool(r.get("credits_kept", false)) else "THIRD MISS: ALL RESET")
	else:
		out.append("ROLL ODDS " + _named(odds, names).to_upper())
	var taken: Array = r.get("taken", [])
	if taken.is_empty():
		out.append("TAKEN BY ROLL: NOTHING")
	else:
		for k: Dictionary in taken:
			out.append("TAKEN: %s %s" % [_name(str(k["player"]), names), str(k.get("name", k["node"])).to_upper()])
	out.append("SHARE  CREDITS")
	var shares: Dictionary = r.get("shares", {})
	var credits: Dictionary = r.get("credits", {})
	var ids: Array = shares.keys()
	ids.sort()
	for id: Variant in ids:
		out.append("%s %d  %d" % [_name(str(id), names).rpad(8).left(8), int(shares[id]), int(credits.get(id, 0))])
	return out

## The day board by the lift (FD3, findables-and-day.md "Where it is shown"): today's result, tomorrow's
## quota, the misses this night, and bed. Before a day is settled: the day and what is owed.
static func day_text(day: Dictionary, count: String) -> Array[String]:
	var out: Array[String] = ["DAY %d" % int(day["day"])]
	var r: Variant = day.get("result")
	if r is Dictionary and (r as Dictionary).has("next_quota"):
		var rd: Dictionary = r
		var kind := str(rd.get("kind", ""))
		var today := "MADE" if kind == "made" else ("GAME OVER" if kind == "game_over" else ("NOBODY CAME BACK" if bool(rd.get("wiped", false)) else "SHORT"))
		out.append("TODAY " + today)
		out.append("TOMORROW OWES %d" % int(rd["next_quota"]))
		out.append("MISSES %d OF %d" % [0 if kind == "game_over" else int(rd.get("misses", 0)), Day.MISSES_FOR_GAME_OVER])
	else:
		out.append("OWED %d" % int(day["quota"]))
	if count != "":
		out.append(count)
	return out

static func _name(id: String, names: Dictionary) -> String:
	return str(names.get(id, id)).to_upper()

static func _named(text: String, names: Dictionary) -> String:
	var t := text
	for id: Variant in names:
		t = t.replace("%s 1 in" % id, "%s 1 in" % str(names[id]))
	return t.replace(",", " /")

## Writes `lines` on the report board (in the bank room).
func show_report(lines: Array[String], practice_paid := false) -> void:
	if lines == report_lines or report_board_image == null:
		return
	report_lines = lines.duplicate()
	_write(report_board_image, report_board_texture, lines, 1, practice_paid)

## Writes `lines` on the day board (in the hall, by the lift).
func show_day_board(lines: Array[String]) -> void:
	if lines == day_board_lines or day_board_image == null:
		return
	day_board_lines = lines.duplicate()
	_write(day_board_image, day_board_texture, lines, 2 if lines.size() <= 4 else 1)

func _write(img: Image, tex: ImageTexture, lines: Array[String], sc := 1, compact := false) -> void:
	img.fill(SCREEN)
	var stride := BOARD_LINE * sc
	var top := BOARD_PAD
	if compact and lines.size() > 1:
		var rows := lines.size() - 1
		stride = clampi(floori(float(img.get_height() - 7 - BOARD_PAD) / rows), 7, stride)
		top = clampi(img.get_height() - 7 - rows * stride, 0, BOARD_PAD)
	for i in lines.size():
		var y := top + i * stride
		if y + 7 * sc > img.get_height():
			break
		PixelFont.blit(img, lines[i], Vector2i(BOARD_PAD, y), BOARD_HEAD if i == 0 else BOARD_INK, Vector2i(sc, sc))
	tex.update(img)

## Lights out: the hall's and the bank room's lamps go dark (their lights follow the Level's light
## level); the cells' orange night lights stay on.
func set_lights_out(on: bool) -> void:
	if on == lights_out:
		return
	lights_out = on
	for m in lamp_meshes:
		m.visible = not on
	for l in bank_lights:
		if l is OmniLight3D:
			l.visible = not on
	var teller := lv.get_node_or_null("TellerLamp")
	if teller != null:
		(teller as Node3D).visible = not on
