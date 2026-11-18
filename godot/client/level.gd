# Builds one Clinic floor from the plan the rules hand over (rules_bridge.gd plan): floors, walls with
# door openings, ceilings, both levels, the stair, the opening for the lift, the ceiling lights (clean
# near the lift, corrupt far from it: corruption is the walking distance from the lift, which the
# rules compute), the emergency strips and red door glows, signs, stains and props.
# Nothing here is a rule: no collision (the rules move the player), no sight, no timing.
class_name Level
extends Node3D

const S := 2.0            # cell size, metres (plan.cellSize)
const LH := 3.2           # storey height (src/sim/move.ts LEVEL_HEIGHT)
const DOOR_W := 1.1       # src/sim/walls.ts DOOR_WIDTH
const DOOR_H := 2.1       # src/sim/sight.ts DOOR_HEIGHT
## Half the lift's doorway in the landing wall: half the rules' door (plan.car.doorWidth, run.gd
## CAR_DOOR_WIDTH), set by build().
var lift_half := 0.9
const LIFT_H := 2.25      # src/render/structure.ts LIFT_DOOR_HEIGHT
## How far short of a crossing wall's far face a wall's end stops (m), so no two faces share a plane.
const CORNER_TUCK := 0.002
const WALL_T := 0.14    # drawn wall thickness (the rules' walls are lines; bodies keep 0.3 m off them)
const PROP_MARGIN := 0.06 # gap between a prop's footprint and a wall face
const CHUNK := 4         # cells per mesh chunk side (keeps per-object light counts low)
const STRIP_Y0 := 0.06    # src/render/structure.ts EMERGENCY
const STRIP_Y1 := 0.2
const SIGN_HALF := 0.28
const SIGN_GAP := 0.06
const SIGN_H := 0.16
const STRIP_COLOR := Color(1.0, 0.36, 0.05)
const SIGN_COLOR := Color(0.95, 0.08, 0.03)
## How many lights nearest the camera cast shadows at the "full" quality level.
const SHADOW_LIGHTS := 4
const PRISON_VIEW := preload("res://client/prison_view.gd")
const ANNEX_VIEW := preload("res://client/annex_view.gd")
const Hides = preload("res://sim/hides.gd")
const ClinicPlan = preload("res://sim/clinic.gd")
const PlayroomLib = preload("res://sim/playroom.gd")
const Furniture = preload("res://sim/furniture.gd")
const FloorLib = preload("res://sim/floor.gd")

var plan: Dictionary
var W: int
var H: int
var cells := [[], []]
var edges := [{}, {}]
var dist := PackedInt32Array()
var max_dist := 1
var room_at := [PackedInt32Array(), PackedInt32Array()]
var landing := Vector3i.ZERO   # (level, x, y)
var lift_dir := "n"
var shadows := false
var props_on := true

var mat_wall: ShaderMaterial
var mat_floor: ShaderMaterial
var mat_ceiling: ShaderMaterial
var mat_rail: ShaderMaterial
var mat_glow: ShaderMaterial
var _chunks := {}
var main_lights: Array[Light3D] = []
var _base_energy: Array[float] = []
var panels: Array = []           # [{mat, col, dead}]
var flickers: Array = []         # [{light, i, panel, phase, rate}]
var emergency_lights: Array[Light3D] = []
var emergency_nodes: Array[Node3D] = []
## The ambient colour as lit, and in the dark with the emergency lighting on (see ambient_color).
const AMBIENT_LIT := Color(0.55, 0.6, 0.6)
var ambient_dark := Color(0.5, 0.08, 0.03)
var _rng := RandomNumberGenerator.new()
var _t := 0.0
var _level := 1.0
var _emergency := 0.0
var _shadow_clock := 0.0
var props_placed := 0
var props_overturned := 0
## Where each prop went (tests): room, cell, the wall it stands against, its floor footprint (x, z, w, d).
var prop_spots: Array[Dictionary] = []
## The Clinic's hiding places (sim/hides.gd, T19b): beds in the wards and exam rooms, cabinets in the
## closets and the nurses' station (and wherever the rules topped one up), drawn from the rules' list.
var hides: Array[PlayroomLib.Hide] = []
var mat_hide: ShaderMaterial
## The floor's furniture (sim/furniture.gd, FD7) on the Clinic and the Annex, and what was drawn for each piece
## (tests: {piece, kind, rect}: the mesh's floor footprint, world x, z, measured from what was drawn).
var pieces: Array = []
var furniture_drawn: Array[Dictionary] = []

static var _shared := {}

static func prop_material(albedo := Color.WHITE, tex: Texture2D = null, vcol := false, scissor := 0.0, emit := 0.0, triplanar := false) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _shader("res://client/prop.gdshader")
	m.set_shader_parameter("albedo", albedo)
	if tex:
		m.set_shader_parameter("tex", tex)
	m.set_shader_parameter("use_vcol", 1.0 if vcol else 0.0)
	m.set_shader_parameter("scissor", scissor)
	m.set_shader_parameter("emit", emit)
	m.set_shader_parameter("triplanar", 1.0 if triplanar else 0.0)
	return m

static func glow_material(col := Color.WHITE, energy := 1.0, tex: Texture2D = null) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _shader("res://client/glow.gdshader")
	m.set_shader_parameter("color", col)
	m.set_shader_parameter("energy", energy)
	if tex:
		m.set_shader_parameter("tex", tex)
	return m

static func _shader(path: String) -> Shader:
	if not _shared.has(path):
		_shared[path] = load(path)
	return _shared[path]

func build(p: Dictionary, seed_text: String) -> void:
	plan = p
	W = int(p.width)
	H = int(p.height)
	_rng.seed = hash(seed_text + ":" + str(p.depth))
	for l in 2:
		cells[l] = p.cells[l]
		edges[l] = p.edges[l]
	landing = Vector3i(int(p.landing.level), int(p.landing.x), int(p.landing.y))
	lift_dir = str(p.elevatorWall)
	if p.has("car"):
		lift_half = float(p.car.doorWidth) * 0.5
	dist = PackedInt32Array(p.liftDist)
	max_dist = 1
	for d in dist:
		max_dist = maxi(max_dist, d)
	_index_rooms()
	# The Prison hub and the Annex have their own looks (client/prison_view.gd, client/annex_view.gd);
	# everything below is the Clinic's.
	if str(p.get("place", "")) == "prison":
		PRISON_VIEW.new().dress(self)
		return
	if str(p.get("place", "clinic")) == "annex":
		preload("res://client/annex_view.gd").dress(self)
		return
	if str(p.get("place", "clinic")) == "playroom":  # the Playroom's look (client/playroom_view.gd)
		preload("res://client/playroom_view.gd").dress(self)
		return
	_make_materials()
	_build_floors_and_ceilings()
	_build_walls()
	_build_stairs()
	_build_furniture()
	_commit_chunks()
	_build_lights()
	_build_signs_and_decals()

# --- data helpers ---------------------------------------------------------------------------

func kind(level: int, x: int, y: int) -> String:
	if x < 0 or y < 0 or x >= W or y >= H:
		return "void"
	return cells[level][y * W + x]

func walkable(level: int, x: int, y: int) -> bool:
	var k := kind(level, x, y)
	return k == "corridor" or k == "room" or k == "landing" or (k == "stair" and level == 0)

func pidx(level: int, x: int, y: int) -> int:
	return level * W * H + y * W + x

## 0 at the lift, 1 at the farthest walkable place (walking distance, from the rules).
func corruption(level: int, x: int, y: int) -> float:
	if x < 0 or y < 0 or x >= W or y >= H:
		return 0.0
	var d := dist[pidx(level, x, y)]
	if d < 0:
		for o: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nx: int = x + o.x
			var ny: int = y + o.y
			if nx >= 0 and ny >= 0 and nx < W and ny < H and dist[pidx(level, nx, ny)] >= 0:
				d = dist[pidx(level, nx, ny)]
				break
	if d < 0:
		return 0.5
	return clampf(float(d) / float(max_dist), 0.0, 1.0)

func corruption_at(pos: Vector3) -> float:
	var lv := 1 if pos.y > LH - 0.5 else 0
	return corruption(lv, int(floor(pos.x / S)), int(floor(pos.z / S)))

func cell_center(level: int, x: int, y: int) -> Vector3:
	return Vector3((x + 0.5) * S, level * LH, (y + 0.5) * S)

func _index_rooms() -> void:
	for l in 2:
		var a := PackedInt32Array()
		a.resize(W * H)
		a.fill(-1)
		room_at[l] = a
	for r: Dictionary in plan.rooms:
		for yy in range(int(r.y), int(r.y) + int(r.h)):
			for xx in range(int(r.x), int(r.x) + int(r.w)):
				room_at[int(r.level)][yy * W + xx] = int(r.id)

# --- materials --------------------------------------------------------------------------------

func _tex(name: String) -> Texture2D:
	return load("res://assets/textures/%s.png" % name)

func _make_materials() -> void:
	var sh := _shader("res://client/surface.gdshader")
	mat_wall = ShaderMaterial.new()
	mat_wall.shader = sh
	mat_wall.set_shader_parameter("albedo_tex", _tex("wall_paint"))
	mat_wall.set_shader_parameter("stain_tex", _tex("decal_rust_stain"))
	mat_wall.set_shader_parameter("stain_amount", 1.0)
	mat_floor = ShaderMaterial.new()
	mat_floor.shader = sh
	mat_floor.set_shader_parameter("albedo_tex", _tex("floor_tile"))
	mat_floor.set_shader_parameter("stain_tex", _tex("decal_rust_stain"))
	mat_floor.set_shader_parameter("stain_amount", 0.6)
	mat_ceiling = ShaderMaterial.new()
	mat_ceiling.shader = sh
	mat_ceiling.set_shader_parameter("albedo_tex", _tex("ceiling_tile"))
	mat_ceiling.set_shader_parameter("stain_tex", _tex("decal_rust_stain"))
	mat_ceiling.set_shader_parameter("stain_amount", 0.8)
	mat_ceiling.set_shader_parameter("self_light", 0.22)
	mat_rail = prop_material(Color(0.55, 0.6, 0.58))
	mat_hide = prop_material(Color.WHITE, null, true)
	mat_glow = glow_material(Color.WHITE, 1.0)

# --- geometry accumulation --------------------------------------------------------------------

func _st(level: int, x: float, z: float, what: String) -> SurfaceTool:
	var key := "%d_%d_%d_%s" % [level, int(floor(x / (S * CHUNK))), int(floor(z / (S * CHUNK))), what]
	if not _chunks.has(key):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_chunks[key] = st
	return _chunks[key]

func _quad(st: SurfaceTool, v: Array, uv: Array, n: Vector3, c: Color) -> void:
	for i: int in [0, 1, 2, 0, 2, 3]:
		st.set_normal(n)
		st.set_color(c)
		st.set_uv(uv[i])
		st.add_vertex(v[i])

func _floor_quad(level: int, x: int, y: int, h: float, up: bool, what: String) -> void:
	var x0 := x * S
	var z0 := y * S
	var c := Color(corruption(level, x, y), _rng.randf(), 0.0)
	var st := _st(level, x0 + 1, z0 + 1, what)
	var a := Vector3(x0, h, z0)
	var b := Vector3(x0 + S, h, z0)
	var cc := Vector3(x0 + S, h, z0 + S)
	var d := Vector3(x0, h, z0 + S)
	var uv := [Vector2(x0, z0) / S, Vector2(x0 + S, z0) / S, Vector2(x0 + S, z0 + S) / S, Vector2(x0, z0 + S) / S]
	if up:
		_quad(st, [a, b, cc, d], uv, Vector3.UP, c)
	else:
		_quad(st, [a, d, cc, b], [uv[0], uv[3], uv[2], uv[1]], Vector3.DOWN, c)

func _build_floors_and_ceilings() -> void:
	for y in H:
		for x in W:
			if walkable(0, x, y):
				if kind(0, x, y) != "stair":
					_floor_quad(0, x, y, 0.0, true, "floor")
				var above := kind(1, x, y)
				if above != "atriumOpen" and above != "stair":
					_floor_quad(0, x, y, LH - 0.001, false, "ceiling")
			var k1 := kind(1, x, y)
			if k1 == "corridor" or k1 == "room" or k1 == "landing":
				_floor_quad(1, x, y, LH, true, "floor")
			if k1 == "corridor" or k1 == "room" or k1 == "atriumOpen" or k1 == "stair" or k1 == "landing":
				_floor_quad(1, x, y, 2 * LH - 0.001, false, "ceiling")

func _wall_face(level: int, ax: float, az: float, bx: float, bz: float, y0: float, y1: float, n: Vector3, cx: int, cy: int, what := "wall") -> void:
	var base := level * LH
	var st := _st(level, (ax + bx) * 0.5 + n.x * 0.5, (az + bz) * 0.5 + n.z * 0.5, what)
	var c := Color(corruption(level, cx, cy), _rng.randf(), 0.0)
	var p0 := Vector3(ax, base + y0, az)
	var p1 := Vector3(bx, base + y0, bz)
	var p2 := Vector3(bx, base + y1, bz)
	var p3 := Vector3(ax, base + y1, az)
	var ua := (ax + az) / S
	var ub := (bx + bz) / S
	var uv := [Vector2(ua, 1.0 - y0 / LH), Vector2(ub, 1.0 - y0 / LH), Vector2(ub, 1.0 - y1 / LH), Vector2(ua, 1.0 - y1 / LH)]
	var cross := (p1 - p0).cross(p3 - p0)
	if cross.dot(n) > 0:
		_quad(st, [p0, p3, p2, p1], [uv[0], uv[3], uv[2], uv[1]], n, c)
	else:
		_quad(st, [p0, p1, p2, p3], uv, n, c)

# A flat glowing band on a wall face (emergency strips and signs), in the "glow" chunk.
func _glow_piece(level: int, a: Vector3, b: Vector3, n: Vector3, y0: float, y1: float, col: Color) -> void:
	var off := n * (WALL_T * 0.5 + 0.012)
	var st := _st(level, (a.x + b.x) * 0.5 + n.x, (a.z + b.z) * 0.5 + n.z, "glow")
	var base := level * LH
	var p0 := Vector3(a.x, base + y0, a.z) + off
	var p1 := Vector3(b.x, base + y0, b.z) + off
	var p2 := Vector3(b.x, base + y1, b.z) + off
	var p3 := Vector3(a.x, base + y1, a.z) + off
	var uv0 := [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]
	if (p1 - p0).cross(p3 - p0).dot(n) > 0:
		_quad(st, [p0, p3, p2, p1], uv0, n, col)
	else:
		_quad(st, [p0, p1, p2, p3], uv0, n, col)

# A wall along an edge, as a solid slab WALL_T thick centred on the edge line: a face toward each
# cell, end caps (door jambs and free ends), the underside of a lintel, the top of a low wall. Ends at
# a cell corner reach half a thickness past it (`ext0` / `ext1`) when the wall does not carry straight
# on there, so corners close. Only the drawing has thickness: where a body may stand is the rules'.
func _wall_edge(level: int, x0: float, z0: float, x1: float, z1: float, cellA: Vector2i, cellB: Vector2i, parts: Array, y0: float, y1: float, what := "wall", ext0 := true, ext1 := true) -> void:
	var dirv := Vector3(x1 - x0, 0, z1 - z0).normalized()
	var nA := Vector3(-dirv.z, 0, dirv.x)
	var mid := Vector3((x0 + x1) * 0.5, 0, (z0 + z1) * 0.5)
	var ca := Vector3((cellA.x + 0.5) * S, 0, (cellA.y + 0.5) * S)
	if (ca - mid).dot(nA) < 0:
		nA = -nA
	var h := WALL_T * 0.5
	var start := Vector3(x0, 0, z0)
	var showA := kind(level, cellA.x, cellA.y) != "void" or level == 0
	var showB := kind(level, cellB.x, cellB.y) != "void" or level == 0
	var capcell := cellA if showA else cellB
	for part: Array in parts:
		var f: float = part[0]
		var t: float = part[1]
		var a := start + dirv * f
		var b := start + dirv * t
		# The reach past a corner stops CORNER_TUCK short of the other wall's far face: reaching all the
		# way put this end's cap in the same plane as that face, and the two flickered (z-fighting).
		var ea := start + dirv * (f - (h - CORNER_TUCK if f <= 0.001 and ext0 else 0.0))
		var eb := start + dirv * (t + (h - CORNER_TUCK if t >= S - 0.001 and ext1 else 0.0))
		if showA:
			_wall_face(level, ea.x + nA.x * h, ea.z + nA.z * h, eb.x + nA.x * h, eb.z + nA.z * h, y0, y1, nA, cellA.x, cellA.y, what)
		if showB:
			_wall_face(level, ea.x - nA.x * h, ea.z - nA.z * h, eb.x - nA.x * h, eb.z - nA.z * h, y0, y1, -nA, cellB.x, cellB.y, what)
		if showA or showB:
			_wall_face(level, ea.x - nA.x * h, ea.z - nA.z * h, ea.x + nA.x * h, ea.z + nA.z * h, y0, y1, -dirv, capcell.x, capcell.y, what)
			_wall_face(level, eb.x - nA.x * h, eb.z - nA.z * h, eb.x + nA.x * h, eb.z + nA.z * h, y0, y1, dirv, capcell.x, capcell.y, what)
			if y0 > 0.001:
				_flat_face(level, ea, eb, nA, h, y0, Vector3.DOWN, capcell, what)
			if y1 < LH - 0.06:
				_flat_face(level, ea, eb, nA, h, y1, Vector3.UP, capcell, what)
		if y0 == 0.0 and what == "wall":
			for side: Array in [[cellA, nA], [cellB, -nA]]:
				var cell: Vector2i = side[0]
				if _strip_area(level, cell.x, cell.y):
					_glow_piece(level, a, b, side[1], STRIP_Y0, STRIP_Y1, STRIP_COLOR)

# The horizontal face of a wall slab at height y (the underside of a lintel, the top of a rail).
func _flat_face(level: int, a: Vector3, b: Vector3, n: Vector3, h: float, y: float, up: Vector3, cell: Vector2i, what: String) -> void:
	var base := level * LH + y
	var st := _st(level, (a.x + b.x) * 0.5 + n.x * 0.5, (a.z + b.z) * 0.5 + n.z * 0.5, what)
	var c := Color(corruption(level, cell.x, cell.y), _rng.randf(), 0.0)
	var p0 := Vector3(a.x, base, a.z) + n * h
	var p1 := Vector3(b.x, base, b.z) + n * h
	var p2 := Vector3(b.x, base, b.z) - n * h
	var p3 := Vector3(a.x, base, a.z) - n * h
	var uv := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 0.05), Vector2(0, 0.05)]
	if (p1 - p0).cross(p3 - p0).dot(up) > 0:
		_quad(st, [p0, p3, p2, p1], [uv[0], uv[3], uv[2], uv[1]], up, c)
	else:
		_quad(st, [p0, p1, p2, p3], uv, up, c)

func _solid(k: String) -> bool:
	return k == "wall" or k == "door"

# Whether a wall end at a cell corner reaches past it: only where the wall does not carry straight on.
func _ext(k: String, neighbour: String) -> bool:
	if k == "rail":
		return neighbour != "rail"
	return not _solid(neighbour)

func _strip_area(level: int, x: int, y: int) -> bool:
	var k := kind(level, x, y)
	if k == "corridor" or k == "landing":
		return true
	if k == "room":
		var r: int = room_at[level][y * W + x]
		if r >= 0:
			var rk: String = plan.rooms[r].kind
			return rk == "lobby" or rk == "atrium"
	return false

func _edge_parts(level: int, k: String, is_lift: bool) -> Array:
	var gap0 := (S - DOOR_W) * 0.5
	var gap1 := (S + DOOR_W) * 0.5
	if is_lift:
		return [[[[0.0, S * 0.5 - lift_half], [S * 0.5 + lift_half, S]], 0.0, LH], [[[S * 0.5 - lift_half, S * 0.5 + lift_half]], LIFT_H, LH]]
	match k:
		"wall":
			return [[[[0.0, S]], 0.0, LH]]
		"stairTop":
			return [[[[0.0, S]], 0.0, LH - 0.05]] if level == 0 else []
		"rail":
			return [[[[0.0, S]], 0.0, 1.0, "rail"]]
		"door":
			return [[[[0.0, gap0], [gap1, S]], 0.0, LH], [[[gap0, gap1]], DOOR_H, LH]]
	return []

func _build_walls() -> void:
	var lift_edge := _lift_edge()
	for level in 2:
		var vert: Array = edges[level].vertical
		var hor: Array = edges[level].horizontal
		for y in H:
			for x in W + 1:
				var k: String = vert[y * (W + 1) + x]
				var is_lift := level == landing.x and lift_edge == Vector4i(0, x, y, 1)
				var before_v: String = vert[(y - 1) * (W + 1) + x] if y > 0 else "none"
				var after_v: String = vert[(y + 1) * (W + 1) + x] if y + 1 < H else "none"
				for piece: Array in _edge_parts(level, k, is_lift):
					var what: String = piece[3] if piece.size() > 3 else "wall"
					_wall_edge(level, x * S, y * S, x * S, (y + 1) * S, Vector2i(x - 1, y), Vector2i(x, y), piece[0], piece[1], piece[2], what, _ext(k, before_v), _ext(k, after_v))
				if k == "door" and not is_lift:
					_door_glow(level, Vector2(x * S, y * S), Vector2(x * S, (y + 1) * S), Vector2i(x - 1, y), Vector2i(x, y))
		for y in H + 1:
			for x in W:
				var k: String = hor[y * W + x]
				var is_lift := level == landing.x and lift_edge == Vector4i(1, x, y, 1)
				var before_h: String = hor[y * W + x - 1] if x > 0 else "none"
				var after_h: String = hor[y * W + x + 1] if x + 1 < W else "none"
				for piece: Array in _edge_parts(level, k, is_lift):
					var what: String = piece[3] if piece.size() > 3 else "wall"
					_wall_edge(level, x * S, y * S, (x + 1) * S, y * S, Vector2i(x, y - 1), Vector2i(x, y), piece[0], piece[1], piece[2], what, _ext(k, before_h), _ext(k, after_h))
				if k == "door" and not is_lift:
					_door_glow(level, Vector2(x * S, y * S), Vector2((x + 1) * S, y * S), Vector2i(x, y - 1), Vector2i(x, y))
	# The larger red glow over the lift, on the landing side.
	var v := _dir_vec(lift_dir)
	var c := cell_center(landing.x, landing.y, landing.z) + Vector3(v.x, 0, v.y) * (S * 0.5)
	var along := Vector3(-v.y, 0, v.x)
	_glow_piece(landing.x, c - along * 0.5, c + along * 0.5, -Vector3(v.x, 0, v.y), LIFT_H + SIGN_GAP, LIFT_H + SIGN_GAP + 0.22, SIGN_COLOR)

# A red glow over a doorway, on each side that is a way through.
func _door_glow(level: int, a2: Vector2, b2: Vector2, cellA: Vector2i, cellB: Vector2i) -> void:
	var a := Vector3(a2.x, 0, a2.y)
	var b := Vector3(b2.x, 0, b2.y)
	var mid := (a + b) * 0.5
	var along := (b - a).normalized()
	for cell: Vector2i in [cellA, cellB]:
		if not _strip_area(level, cell.x, cell.y):
			continue
		var n := (Vector3((cell.x + 0.5) * S, 0, (cell.y + 0.5) * S) - mid)
		n = Vector3(signf(n.x) if absf(n.x) > absf(n.z) else 0.0, 0, signf(n.z) if absf(n.z) >= absf(n.x) else 0.0)
		_glow_piece(level, mid - along * SIGN_HALF, mid + along * SIGN_HALF, n, DOOR_H + SIGN_GAP, DOOR_H + SIGN_GAP + SIGN_H, SIGN_COLOR)

## Whether the landing cell has a wall on its left as you face the lift (the side the call button goes):
## a one-cell lobby does (the Prison); a landing in a wider lobby does not (the Clinic, the Annex).
func lift_left_wall() -> bool:
	var v := _dir_vec(lift_dir)
	# Facing the lift along v, the left is (v.y, -v.x) in plan cells (x east, y south).
	var left := Vector2i(v.y, -v.x)
	var lx := landing.y
	var ly := landing.z
	var vert: Array = edges[landing.x].vertical
	var hor: Array = edges[landing.x].horizontal
	var k := ""
	if left == Vector2i(-1, 0):
		k = vert[ly * (W + 1) + lx]
	elif left == Vector2i(1, 0):
		k = vert[ly * (W + 1) + lx + 1]
	elif left == Vector2i(0, -1):
		k = hor[ly * W + lx]
	else:
		k = hor[(ly + 1) * W + lx]
	return k == "wall"

func _lift_edge() -> Vector4i:
	var lx := landing.y
	var ly := landing.z
	match lift_dir:
		"n": return Vector4i(1, lx, ly, 1)
		"s": return Vector4i(1, lx, ly + 1, 1)
		"w": return Vector4i(0, lx, ly, 1)
		"e": return Vector4i(0, lx + 1, ly, 1)
	return Vector4i(-1, 0, 0, 0)

func _dir_vec(d: String) -> Vector2i:
	match d:
		"n": return Vector2i(0, -1)
		"s": return Vector2i(0, 1)
		"e": return Vector2i(1, 0)
		"w": return Vector2i(-1, 0)
	return Vector2i.ZERO

func _commit_chunks() -> void:
	for key: String in _chunks:
		var st: SurfaceTool = _chunks[key]
		var what: String = key.get_slice("_", 3)
		st.index()
		var mesh := st.commit()
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.name = key
		match what:
			"wall": mi.material_override = mat_wall
			"floor": mi.material_override = mat_floor
			"ceiling": mi.material_override = mat_ceiling
			"rail": mi.material_override = mat_rail
			"hidef": mi.material_override = mat_hide
			"glow":
				mi.material_override = mat_glow
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				mi.visible = false
				emergency_nodes.append(mi)
		add_child(mi)
	_chunks.clear()

# --- stair ------------------------------------------------------------------------------------

func _build_stairs() -> void:
	var step_mat := prop_material(Color(0.85, 0.86, 0.82), _tex("floor_tile"), false, 0.0, 0.0, true)
	for s: Dictionary in plan.stairs:
		var v := _dir_vec(str(s.dir))
		var length := int(s.length)
		var fwd := Vector3(v.x, 0, v.y)
		var c0 := Vector3((int(s.x) + 0.5) * S, 0, (int(s.y) + 0.5) * S) - fwd * (S * 0.5)
		var run := length * S
		var n := int(round(LH / 0.2))
		var depth := run / n
		for i in n:
			var box := BoxMesh.new()
			var top := (i + 1) * 0.2
			box.size = Vector3(S if v.x == 0 else depth, top, depth if v.x == 0 else S)
			var mi := MeshInstance3D.new()
			mi.mesh = box
			mi.material_override = step_mat
			mi.position = c0 + fwd * (depth * (i + 0.5)) + Vector3(0, top * 0.5, 0)
			add_child(mi)

# --- lights -----------------------------------------------------------------------------------

func _want_panel(level: int, x: int, y: int) -> bool:
	var k := kind(level, x, y)
	if k == "corridor":
		return (x + y) % 2 == 0
	if k == "landing":
		return true
	if k == "room":
		var r: Dictionary = plan.rooms[room_at[level][y * W + x]]
		var rx := x - int(r.x)
		var ry := y - int(r.y)
		var step := 3 if int(r.w) * int(r.h) > 12 else 99
		var cx := int(r.w) / 2 if step == 99 else 1
		var cy := int(r.h) / 2 if step == 99 else 1
		return (rx - cx) % step == 0 and (ry - cy) % step == 0 and rx >= cx and ry >= cy
	return false

func _build_lights() -> void:
	var panel_mesh := BoxMesh.new()
	panel_mesh.size = Vector3(0.6, 0.03, 1.2)
	for level in 2:
		for y in H:
			for x in W:
				if not _want_panel(level, x, y):
					continue
				var t := corruption(level, x, y)
				var pos := cell_center(level, x, y)
				pos.y = level * LH + LH - 0.02
				# Under an opening to the floor above there is no ceiling at this height: the panel
				# hangs on the real ceiling, the upper floor's, and throws further.
				var open_above := level == 0 and (kind(1, x, y) == "atriumOpen" or kind(1, x, y) == "stair")
				if open_above:
					pos.y = 2 * LH - 0.02
				var dead := t > 0.55 and _rng.randf() < (t - 0.45) * 1.4
				var flicker := not dead and t > 0.45 and _rng.randf() < 0.55
				var clean := Color(0.86, 0.93, 1.0)
				var sick := Color(0.86, 0.88, 0.55)
				var col := clean.lerp(sick, smoothstep(0.25, 0.8, t))
				var energy := lerpf(1.0, 0.4, smoothstep(0.2, 0.85, t))
				var pm := glow_material(col, 0.15 if dead else 1.0)
				var panel := MeshInstance3D.new()
				panel.mesh = panel_mesh
				panel.material_override = pm
				panel.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				panel.position = pos
				add_child(panel)
				panels.append({"mat": pm, "dead": dead, "k": 1.0})
				if dead:
					continue
				var light := SpotLight3D.new()
				light.position = pos - Vector3(0, 0.05, 0)
				light.rotation_degrees = Vector3(-90, 0, 0)
				light.spot_angle = 78.0
				light.spot_angle_attenuation = 0.6
				light.spot_range = 10.5 if open_above else 7.5
				light.light_color = col
				if open_above:
					energy *= 1.4
				light.light_energy = energy
				light.shadow_enabled = false
				light.shadow_bias = 0.04
				light.distance_fade_enabled = true
				light.distance_fade_begin = 16.0
				light.distance_fade_length = 6.0
				light.distance_fade_shadow = 12.0
				add_child(light)
				main_lights.append(light)
				_base_energy.append(energy)
				if flicker:
					flickers.append({"i": main_lights.size() - 1, "panel": panels.size() - 1, "phase": _rng.randf() * 100.0, "rate": _rng.randf_range(0.6, 2.2)})
	# Emergency: low amber lights along the ways through, no shadows.
	for level in 2:
		for y in H:
			for x in W:
				if _strip_area(level, x, y) and (x * 3 + y) % 4 == 0:
					var o := OmniLight3D.new()
					o.position = cell_center(level, x, y) + Vector3(0, 0.3, 0)
					o.light_color = Color(1.0, 0.38, 0.08)
					o.light_energy = 0.0
					o.omni_range = 4.5
					o.omni_attenuation = 1.4
					o.distance_fade_enabled = true
					o.distance_fade_begin = 20.0
					o.distance_fade_length = 5.0
					o.visible = false
					add_child(o)
					emergency_lights.append(o)
	# Shadows on the nearest few from the start, so the browser compiles those variants while loading.
	if shadows:
		for i in mini(SHADOW_LIGHTS, main_lights.size()):
			main_lights[i].shadow_enabled = true

## The lights as one dial: 1 every light as built; lower is the lights failing (blink warnings, the
## dark). Panels die faster than the room, as in src/render/lighting.ts.
func set_light_level(k: float) -> void:
	_level = clampf(k, 0.0, 1.0)

## The ambient light's colour, lit (emergency 0) to the dark with the emergency lighting on (1). The
## Clinic's dark is red; a place's dressing may set its own (the Annex: green, never red).
func ambient_color(emergency: float) -> Color:
	return AMBIENT_LIT.lerp(ambient_dark, emergency)

## The emergency lighting, 0 (off) to 1 (fully on).
func set_emergency(k: float) -> void:
	if is_equal_approx(k, _emergency):
		return
	_emergency = k
	var on := k > 0.001
	for n in emergency_nodes:
		n.visible = on
		(n as MeshInstance3D).material_override.set_shader_parameter("energy", k)
	for o in emergency_lights:
		o.visible = on
		o.light_energy = 0.55 * k

func update_lights(delta: float, cam_pos: Vector3) -> void:
	_t += delta
	var pk := 1.0 if _level >= 1.0 else _level * _level
	var lit := _level > 0.02
	for i in main_lights.size():
		var l := main_lights[i]
		l.visible = lit
		l.light_energy = _base_energy[i] * _level
	for p: Dictionary in panels:
		p.k = 1.0
	for f: Dictionary in flickers:
		var ph: float = f.phase + _t * f.rate
		var burst := sin(ph * 0.7) > 0.55
		var k := 1.0
		if burst:
			k = 1.0 if fmod(ph * 23.0, 1.0) > 0.45 else 0.08
		elif fmod(ph * 0.31, 1.0) > 0.97:
			k = 0.0
		main_lights[f.i].light_energy = _base_energy[f.i] * k * _level
		panels[f.panel].k = maxf(k, 0.12)
	for p: Dictionary in panels:
		var e: float = (0.15 if p.dead else p.k) * pk
		if not is_equal_approx(p.mat.get_shader_parameter("energy"), e):
			p.mat.set_shader_parameter("energy", e)
	if shadows:
		_shadow_clock -= delta
		if _shadow_clock <= 0.0:
			_shadow_clock = 0.25
			_pick_shadow_lights(cam_pos)

# Shadows only from the few lights nearest the player.
func _pick_shadow_lights(cam_pos: Vector3) -> void:
	var order := []
	for i in main_lights.size():
		order.append([main_lights[i].global_position.distance_squared_to(cam_pos), i])
	order.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var want := {}
	for j in mini(SHADOW_LIGHTS, order.size()):
		want[order[j][1]] = true
	for i in main_lights.size():
		var on := want.has(i)
		if main_lights[i].shadow_enabled != on:
			main_lights[i].shadow_enabled = on

# --- signs and stains -------------------------------------------------------------------------

func _build_signs_and_decals() -> void:
	var signs := ["sign_ward4", "sign_staff", "sign_quiet", "sign_wash"]
	var sign_mats := []
	for s: String in signs:
		sign_mats.append(prop_material(Color.WHITE, _tex(s)))
	var hand := prop_material(Color.WHITE, _tex("decal_handprint"), false, 0.4)
	var rust := prop_material(Color.WHITE, _tex("decal_rust_stain"), false, 0.3)
	var i := 0
	for d: Dictionary in plan.doors:
		var level := int(d.level)
		var a := Vector2i(int(d.ax), int(d.ay))
		var b := Vector2i(int(d.bx), int(d.by))
		var corr := a if kind(level, a.x, a.y) == "corridor" else b
		var other := b if corr == a else a
		if kind(level, corr.x, corr.y) != "corridor":
			continue
		var n := Vector3(corr.x - other.x, 0, corr.y - other.y)
		var edge_mid := (cell_center(level, a.x, a.y) + cell_center(level, b.x, b.y)) * 0.5
		var along := Vector3(-n.z, 0, n.x)
		i += 1
		if i % 2 == 0:
			var q := QuadMesh.new()
			q.size = Vector2(0.64, 0.36)
			var mi := MeshInstance3D.new()
			mi.mesh = q
			mi.material_override = sign_mats[i / 2 % sign_mats.size()]
			mi.position = edge_mid + n * (WALL_T * 0.5 + 0.015) + along * 0.95 + Vector3(0, 1.6, 0)
			mi.basis = Basis.looking_at(n, Vector3.UP)
			mi.rotate_object_local(Vector3.UP, PI)
			add_child(mi)
		var t := corruption(level, corr.x, corr.y)
		if t > 0.5:
			var q2 := QuadMesh.new()
			var is_hand := _rng.randf() < 0.5
			q2.size = Vector2(0.35, 0.35) if is_hand else Vector2(0.42, 1.5)
			var m2 := MeshInstance3D.new()
			m2.mesh = q2
			m2.material_override = hand if is_hand else rust
			m2.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			# On the strip of wall beside the doorway (0.55 to 1.0 m from its middle), never across it.
			var off := along * (0.78 if _rng.randf() < 0.5 else -0.78)
			m2.position = edge_mid + n * (WALL_T * 0.5 + 0.02) + off + Vector3(0, _rng.randf_range(0.9, 1.6) if is_hand else 1.4, 0)
			m2.basis = Basis.looking_at(n, Vector3.UP)
			m2.rotate_object_local(Vector3.UP, PI)
			m2.rotate_object_local(Vector3.FORWARD, _rng.randf_range(-0.5, 0.5) if is_hand else 0.0)
			add_child(m2)

# --- furniture -------------------------------------------------------------------------------

## The rules' furniture for this Clinic (sim/furniture.gd, FD7): the one list of floor-standing pieces, which is
## also what blocks a player (sim/move.gd Solids) and what hides them. The hides (sim/hides.gd) are drawn in the
## Clinic's white and steel (client/annex_view.gd hide_boxes), the plain pieces as their glb models, each centred
## on its footprint and turned to its facing. Nothing floor-standing is placed here by itself any more.
func _build_furniture() -> void:
	var fp := ClinicPlan.generate_clinic(str(plan.seed), int(plan.depth))
	if fp.width != W or fp.height != H:
		push_error("level: the Clinic plan for %s/%d does not match the one being drawn" % [plan.seed, plan.depth])
		return
	hides = Hides.hides_for(fp, str(plan.seed))
	pieces = Furniture.pieces_for(fp, str(plan.seed), int(plan.depth))
	for pc: Furniture.Piece in pieces:
		if pc.hide >= 0:
			var h: PlayroomLib.Hide = hides[pc.hide]
			ANNEX_VIEW.draw_hide_into(self, h, true, "hidef")
			furniture_drawn.append({"piece": pc.id, "kind": String(pc.kind), "rect": ANNEX_VIEW.boxes_rect(ANNEX_VIEW.hide_xf(h), ANNEX_VIEW.hide_boxes(h.kind, true))})
			continue
		var f := Vector2(FloorLib.dir_dx(pc.facing), FloorLib.dir_dy(pc.facing))
		# The glb's front faces +z: turn it to the piece's facing.
		var n := _make_prop(String(pc.kind), atan2(f.x, f.y), 0.0)
		var box := _prop_box(n)
		var cx := pc.x / 100.0
		var cz := pc.y / 100.0
		n.position = Vector3(cx - (box.position.x + box.size.x * 0.5), pc.level * LH - box.position.y, cz - (box.position.z + box.size.z * 0.5))
		add_child(n)
		var foot := Rect2(n.position.x + box.position.x, n.position.z + box.position.z, box.size.x, box.size.z)
		furniture_drawn.append({"piece": pc.id, "kind": String(pc.kind), "rect": foot})
		# The cell it stands in against its wall, and that wall's side (the scripted playthroughs look at a prop
		# from inside its room and from beyond that wall: the `props` test command).
		var wv := Vector2i(FloorLib.dir_dx(pc.wall), FloorLib.dir_dy(pc.wall)) if pc.wall != &"" else Vector2i.ZERO
		var cell := Vector2i(floori(pc.x / 200.0), floori(pc.y / 200.0))
		if wv.x != 0:
			cell.x = floori((pc.wall_at - wv.x * 100) / 200.0)
		elif wv.y != 0:
			cell.y = floori((pc.wall_at - wv.y * 100) / 200.0)
		prop_spots.append({"room": pc.room, "level": pc.level, "piece": pc.id, "kind": String(pc.kind), "cx": cell.x, "cy": cell.y,
			"wall": [wv.x, wv.y], "foot": [foot.position.x, foot.position.y, foot.size.x, foot.size.y], "tipped": false})
		props_placed += 1

static var _prop_scenes := {}
static var _prop_mat_cache := {}

func _prop_scene(name: String) -> PackedScene:
	if not _prop_scenes.has(name):
		_prop_scenes[name] = load("res://assets/props/%s.glb" % name)
	return _prop_scenes[name]

# One shared shader for every prop: the glb's own colours come from its vertex colours.
func _make_prop(name: String, yaw: float, tip: float) -> Node3D:
	var n: Node3D = _prop_scene(name).instantiate()
	n.rotation = Vector3(0, yaw, 0)
	if tip != 0.0:
		n.rotate_object_local(Vector3.FORWARD, tip)
	for mi: MeshInstance3D in n.find_children("*", "MeshInstance3D", true, false):
		var m: Mesh = mi.mesh
		for i in m.get_surface_count():
			var src := m.surface_get_material(i) as BaseMaterial3D
			var key: Variant = src if src else "none"
			if not _prop_mat_cache.has(key):
				var col := src.albedo_color if src else Color.WHITE
				var tex: Texture2D = src.albedo_texture if src else null
				_prop_mat_cache[key] = prop_material(col, tex, true)
			mi.set_surface_override_material(i, _prop_mat_cache[key])
	return n

# The prop's bounding box in its parent's space, as it is turned now (position ignored).
func _prop_box(n: Node3D) -> AABB:
	var box := AABB()
	var first := true
	var turn := Transform3D(n.basis, Vector3.ZERO)
	for mi: MeshInstance3D in n.find_children("*", "MeshInstance3D", true, false):
		var rel := Transform3D.IDENTITY
		var c: Node = mi
		while c != n and c is Node3D:
			rel = (c as Node3D).transform * rel
			c = c.get_parent()
		var b: AABB = (turn * rel) * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box

# A solid wall side of a room cell (not a door), as a unit vector, or zero.
func _wall_side(level: int, x: int, y: int) -> Vector2i:
	var opts := []
	var vert: Array = edges[level].vertical
	var hor: Array = edges[level].horizontal
	if hor[y * W + x] == "wall": opts.append(Vector2i(0, -1))
	if hor[(y + 1) * W + x] == "wall": opts.append(Vector2i(0, 1))
	if vert[y * (W + 1) + x] == "wall": opts.append(Vector2i(-1, 0))
	if vert[y * (W + 1) + x + 1] == "wall": opts.append(Vector2i(1, 0))
	if opts.is_empty():
		return Vector2i.ZERO
	return opts[_rng.randi_range(0, opts.size() - 1)]
