# The Prison hub's look (docs/floors/prison.md, section 4): the plan from sim/prison.gd dressed as
# painted concrete, grey-green below and cream above; steel doors with wire glass; one orange night
# light and a bunk in each of the eight cells, a number over each door; the bank room as the bright
# spot, a white strip light over a brass counter and four teller windows behind glass; the report board
# in the bank room and the day board beside the lift, both blank screens ready for text.
# Level.build hands any plan whose place is "prison" here instead of the Clinic dressing. The walls,
# floors and ceilings are the Level's own geometry (doorways, the lift opening) with this file's
# materials; the rest is added as children of the Level. Nothing here is a rule.
extends RefCounted

const Floor = preload("res://sim/floor.gd")
const Walls = preload("res://sim/walls.gd")
const Landing = preload("res://sim/landing.gd")
const Run = preload("res://sim/run.gd")
const Prison = preload("res://sim/prison.gd")

const S := 2.0                         # Level.S, the cell size
const T := 0.07                        # half of Level.WALL_T: a wall face stands this far off the wall line
const DOOR_HALF := 0.55                # half of Level.DOOR_W
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
var report_board: MeshInstance3D
var report_board_image: Image
var report_board_texture: ImageTexture
## The bank room's strip light and the lights it throws (empty if the room is unlit).
var bank_lights: Array[Light3D] = []
var bank_strip: MeshInstance3D
## One per cell, in bunk order 1..8.
var night_lights: Array[OmniLight3D] = []
var bunk_centres: Array[Vector3] = []
## The four teller window panes' middles, in the plan's window order (Prison.WINDOWS, west to east).
var window_centres: Array[Vector3] = []

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
	lv._build_walls()
	lv._commit_chunks()
	_hall()
	var n := 0
	for r: Dictionary in lv.plan.rooms:
		match str(r.kind):
			"closet":
				n += 1
				_cell(r, n)
			"ward":
				_bank_room(r)
	_commit_boxes()
	if lv.shadows:
		for i in mini(Level.SHADOW_LIGHTS, lv.main_lights.size()):
			lv.main_lights[i].shadow_enabled = true
	lv.set_meta(&"prison", self)

# --- materials --------------------------------------------------------------------------------

func _surface(part: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://client/prison_surface.gdshader")
	m.set_shader_parameter("part", part)
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
	var dh := Level.DOOR_H
	var depth := Level.WALL_T + 0.04
	for sgn: float in [-1.0, 1.0]:
		_box(_steel_dark, _w(mid, side, fwd, sgn * (DOOR_HALF + 0.03), 0.0, (dh + 0.06) * 0.5), _sz(side, fwd, 0.06, depth, dh + 0.06))
	_box(_steel_dark, _w(mid, side, fwd, 0.0, 0.0, dh + 0.03), _sz(side, fwd, Level.DOOR_W + 0.12, depth, 0.06))
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
	var top := dh - 0.03
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
		_lamp("HallLamp_%d" % c.x, Vector3(p.x, top - 0.065, p.z), Vector3(0.36, 0.05, 0.22), HALL_LAMP, 1.15)
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

# --- the cells --------------------------------------------------------------------------------

func _cell(r: Dictionary, number: int) -> void:
	var fr := _frame_of(r)
	var mid: Vector3 = fr[0]
	var side: Vector3 = fr[1]
	var fwd: Vector3 = fr[2]
	var width: float = fr[3]
	var depth: float = fr[4]
	var sc: float = fr[5]
	var s_lo := sc - width * 0.5 + T     # the inner face of the side wall nearer the door
	var s_hi := sc + width * 0.5 - T
	var back := depth - T                # the inner face of the back wall
	_doorway(mid, side, fwd, 1.0)
	# The number over the door, on the hall side.
	_plate("CellNumber_%d" % number, str(number), _w(mid, side, fwd, 0.0, -T - 0.012, PLATE_Y), -fwd, 0.28,
		Color(0.86, 0.84, 0.74), Color(0.08, 0.08, 0.08), 0.1)
	# The bunk along the back wall, in line with the door so it shows from the hall.
	var bl := 2.0
	var bd := 0.8
	var bs := s_lo + 0.04 + bl * 0.5
	var bf := back - 0.02 - bd * 0.5
	for ls: float in [-1.0, 1.0]:
		for lf: float in [-1.0, 1.0]:
			_box(_steel, _w(mid, side, fwd, bs + ls * (bl * 0.5 - 0.04), bf + lf * (bd * 0.5 - 0.04), 0.19), _sz(side, fwd, 0.05, 0.05, 0.38))
	_box(_steel, _w(mid, side, fwd, bs, bf, 0.42), _sz(side, fwd, bl, bd, 0.08))
	_box(_mattress, _w(mid, side, fwd, bs, bf, 0.52), _sz(side, fwd, bl - 0.08, bd - 0.08, 0.12))
	_box(_pillow, _w(mid, side, fwd, s_lo + 0.32, bf, 0.62), _sz(side, fwd, 0.42, bd - 0.2, 0.09))
	_box(_blanket, _w(mid, side, fwd, bs + 0.3, bf + 0.02, 0.595), _sz(side, fwd, bl - 0.65, bd - 0.04, 0.03))
	bunk_centres.append(_w(mid, side, fwd, bs, bf, 0.5))
	# The night light on the back wall over the bunk: a caged orange lamp, and its light.
	var lp := _w(mid, side, fwd, bs, back - 0.07, NIGHT_LIGHT_Y)
	_box(_steel_dark, _w(mid, side, fwd, bs, back - 0.015, NIGHT_LIGHT_Y), _sz(side, fwd, 0.34, 0.03, 0.24))
	_lamp("NightLamp_%d" % number, lp, _sz(side, fwd, 0.24, 0.1, 0.14), NIGHT, 3.0)
	for k: float in [-0.08, 0.0, 0.08]:
		_box(_steel_dark, _w(mid, side, fwd, bs + k, back - 0.13, NIGHT_LIGHT_Y), _sz(side, fwd, 0.012, 0.012, 0.18))
	var o := OmniLight3D.new()
	o.name = "NightLight_%d" % number
	o.position = _w(mid, side, fwd, bs, back - 0.45, NIGHT_LIGHT_Y - 0.1)
	o.light_color = NIGHT
	o.light_energy = 1.8
	o.omni_range = 6.5
	o.omni_attenuation = 1.1
	o.distance_fade_enabled = true
	o.distance_fade_begin = 20.0
	o.distance_fade_length = 5.0
	lv.add_child(o)
	night_lights.append(o)
	# A steel toilet and basin in the other back corner.
	var ts := s_hi - 0.3
	_box(_steel, _w(mid, side, fwd, ts, back - 0.3, 0.21), _sz(side, fwd, 0.42, 0.55, 0.42))
	_box(_steel, _w(mid, side, fwd, ts, back - 0.17, 0.86), _sz(side, fwd, 0.4, 0.3, 0.12))
	_box(_steel_dark, _w(mid, side, fwd, ts, back - 0.04, 0.6), _sz(side, fwd, 0.4, 0.06, 0.6))

# --- the bank room ----------------------------------------------------------------------------

func _bank_room(r: Dictionary) -> void:
	var x0 := int(r.x) * S + T
	var x1 := (int(r.x) + int(r.w)) * S - T
	var z_back := (int(r.y) + int(r.h)) * S - T
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
	_box(_brass, Vector3(cx, 0.55, gz - 0.005), Vector3(x1 - x0, 0.04, 0.02))
	_box(_steel_dark, Vector3(cx, 0.06, gz - 0.005), Vector3(x1 - x0, 0.12, 0.02))
	# Four windows: brass mullions, glass with a slot at the bottom, a fascia over them with numbers.
	var gy0 := ch + 0.06
	var gy1 := 2.42
	var n_win := Prison.WINDOWS.size()
	var pane := (x1 - x0) / n_win
	for i in n_win + 1:
		var mx := x0 + pane * i
		_box(_brass, Vector3(mx, (gy0 + gy1) * 0.5, gz + 0.3), Vector3(0.07, gy1 - gy0, 0.07))
	for i in n_win:
		var px := x0 + pane * (i + 0.5)
		_box(_glass, Vector3(px, (gy0 + 0.09 + gy1) * 0.5, gz + 0.3), Vector3(pane - 0.07, gy1 - gy0 - 0.09, 0.012))
		# The speaking grille, a steel disc in the glass.
		_box(_steel_dark, Vector3(px, 1.58, gz + 0.3), Vector3(0.16, 0.16, 0.02))
		window_centres.append(Vector3(px, 1.6, gz + 0.3))
		_plate("WindowNumber_%d" % (i + 1), str(i + 1), Vector3(px, 2.8, gz + 0.3 - 0.06), Vector3(0, 0, -1), 0.34, BRASS, Color(0.12, 0.08, 0.03), 0.2)
	_box(_brass, Vector3(cx, gy1 + 0.03, gz + 0.3), Vector3(x1 - x0, 0.06, 0.08))
	_box(_wood, Vector3(cx, (gy1 + 0.06 + Level.LH) * 0.5, gz + 0.3), Vector3(x1 - x0, Level.LH - gy1 - 0.06, 0.1))
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
	_strip_light(x0, x1, gz)

# The bank room's white strip light across the room in front of the counter, and the light it throws.
func _strip_light(x0: float, x1: float, gz: float) -> void:
	var cx := (x0 + x1) * 0.5
	var z := gz - 1.2
	var top := Level.LH
	var length := (x1 - x0) - 1.6
	_box(_steel, Vector3(cx, top - 0.015, z), Vector3(length + 0.12, 0.03, 0.22))
	bank_strip = _lamp("BankStrip", Vector3(cx, top - 0.05, z), Vector3(length, 0.05, 0.13), BANK_LAMP, 3.0)
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
