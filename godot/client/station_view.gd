# The Reactor's generating station as the main game draws it (docs/floors/native-late-floors.md, "On screen";
# the place is the-intact-crew.md "The generating station"). What Level draws when plan.place is "reactor":
# the plan is an ordinary floor plan (sim/station.gd) and its anchors (`station`: lift_door, sill, plinth,
# lockers, rotor, hall, gallery, crawl, fuse_spots, cabinet, bodies, growths, lamps) say where the named
# things stand. Nothing here is a rule: the host's `reactor` block says the power, where the fuse and the
# cassette are and who carries them, and where the four are; this only draws it.
#
# The look: long stretches of ordinary board-marked concrete in the corridors; old green paint to dado height
# in the rooms; amber caged service lamps; warm battens on the ceiling while the mains are on; the stopped
# rotor at the far end of the turbine hall; wired glass where the control gallery looks back over the hall;
# four locker hooks, four time-card slots and the striped sill on the landing; cable trays over the crawl;
# the seeded growths (pipe collar, cracked insulation, split cable tray) placed from the anchors.
#
# The power (the block's `power`: 0 the mains, 1 the cut, 2 restored): every batten and every amber lamp is
# on while the mains are; on the cut they all go out together on the frame that carries the host's cut, and
# only the lamps the anchors mark as emergency stay, dim, so the spaces players saw on arrival can still be
# found by torch (the main game's near light comes up: the level's "near_light" meta). Restored brings
# everything back. The tape filter sees green, amber and the pale screen drawings as different colours.
#
# The props, with the main game's own use key (F, the "use" action the host reads): the fuse at `fuseAt`
# (drawn where the rules hid it, out of plain sight), the marked service cabinet and its socket, the glowing
# cassette on its table beside the lift. `prompt` says what F would do now, only in the rules' own reach and
# only when the rules would accept it (sim/reactor.gd use(): the same order and reach, client/reactor_marks.gd).
extends Node3D

const AnnexView = preload("res://client/annex_view.gd")
const Marks = preload("res://client/reactor_marks.gd")
const CrewFour = preload("res://client/station_crew_view.gd")
const Point = preload("res://client/station_point.gd")
const Dress = preload("res://client/station_dress.gd")

const S := 2.0
const LH := 3.2
const WALL_T := 0.14
const DOOR_W := 1.1
const DOOR_H := 2.1
const EMERGENCY := 1
const RESTORED := 2
## Prompts (the main game's use key).
const FUSE_PROMPT := "F  TAKE FUSE"
const INSTALL_PROMPT := "F  INSTALL FUSE"
const TAPE_PROMPT := "F  PICK UP CASSETTE"
## Paint and light.
const C_GREEN := Color(0.31, 0.5, 0.37)
const C_GREEN_DARK := Color(0.17, 0.29, 0.22)
const C_CONCRETE := Color(0.56, 0.55, 0.52)
const C_STEEL := Color(0.42, 0.44, 0.45)
const C_RUST := Color(0.42, 0.24, 0.14)
const C_YELLOW := Color(0.86, 0.68, 0.12)
const C_BLACK := Color(0.07, 0.07, 0.07)
const C_CARD := Color(0.86, 0.84, 0.74)
const C_WOOD := Color(0.42, 0.30, 0.19)
const C_GROWTH := Color(0.64, 0.47, 0.44)
const C_GROWTH_DARK := Color(0.38, 0.22, 0.24)
const AMBER := Color(1.0, 0.62, 0.22)
const BATTEN := Color(1.0, 0.92, 0.78)
const AMBIENT_LIT := Color(0.52, 0.52, 0.44)
const AMBIENT_CUT := Color(0.07, 0.05, 0.03)
const LAMP_ENERGY := 1.6
const LAMP_REACH := 7.0
const EM_ENERGY := 0.42
const EM_REACH := 5.5
## RN3: the battens are the Clinic's ceiling panels' numbers (client/level.gd _build_lights: the same placement,
## spot angle, cone softness and reach), a little stronger because board-marked concrete and green paint reflect
## less than the Clinic's cream paint and linoleum; tests/test_station_look.gd holds the hall's floor light at
## least as bright as a Clinic's through the same numbers.
const BATTEN_ENERGY := 1.25
const BATTEN_ANGLE := 78.0
const BATTEN_SOFT := 0.6
const BATTEN_REACH := 7.5
const BATTEN_LIMIT := 120
## The baked-in light of the architecture (surface.gdshader self_light), with the mains and in the cut (the
## Clinic's ceiling has 0.22).
const SELF_LIT := 0.22
const SELF_CUT := 0.0
## The player's near light share in the cut (client/main.gd reads the level's meta).
const NEAR_CUT := 0.95
## The concrete's greys (sRGB): pale enough that the mains read as a lit, safe place (RN3).
const WALL_GREY := 0.64
const FLOOR_GREY := 0.6
const CEIL_GREY := 0.56
const CASSETTE_GLOW := Color("#ffb347")
## The cassette's own glow (RN3: "A glowing VHS cassette lies near the elevator door"): its whole shell lit, its
## label brighter, a soft halo that still reads as a few pixels through the 480x270 tape picture, and a small warm
## light that reaches the table top but not across the landing. None of it is on the mains: the cut leaves it lit.
const TAPE_SHELL_GLOW := 1.0
const TAPE_FACE_GLOW := 1.8
const TAPE_LIGHT_ENERGY := 1.4
const TAPE_LIGHT_REACH := 1.8
const TAPE_HALO := 0.5
## The cassette table's top above its foot (sim/station.gd PLINTH_TOP).
const PLINTH_TOP := 0.9
## Tests only: one-line breaks the tests prove themselves with. "lights": the cut leaves the battens on;
## "anchor": every anchored prop is drawn at the landing instead; "reach": prompts ignore the reach.
static var test_break := ""

var lv: Level
var fp: RefCounted
var anchors := {}
## What was drawn, for checks: counts by kind, and each anchored prop with where it went (world).
var drawn := {}
var placed: Array[Dictionary] = []
## The block's power as drawn now (0 the mains, 1 the cut, 2 restored).
var power := 0
## What F would do now: "" or one of the prompts above.
var prompt := ""
var crew: Node3D
## AR1: the pipes, growths, frames, signs and rotor (client/station_dress.gd).
var dresser: Dress
var sfx: Node = null
var link: Object = null

var _hall := Rect2()
var _gallery := Rect2()
var _crawl := {}            # Vector3i(level, x, y) -> true
var _glass := {}            # "ax,ay,bx,by" (both orders) -> true: the anchors' wired-glass cell edges
var mat_wall_c: ShaderMaterial
var mat_wall_g: ShaderMaterial
var mat_floor: ShaderMaterial
var mat_ceil: ShaderMaterial
var mat_props: ShaderMaterial
var mat_glass: ShaderMaterial
var mat_sill: ShaderMaterial
## Amber lamps: {light: OmniLight3D, globe: ShaderMaterial, emergency: bool}.
var lamps: Array[Dictionary] = []
var _batten_mats: Array[ShaderMaterial] = []
var _applied := -1
## Movable props.
var fuse_node: Node3D
var cassette_node: Node3D
var socket_fuse: Node3D
var socket_lamp: ShaderMaterial
var _tape_light: OmniLight3D
var _tape_halo: MeshInstance3D
## The cassette shell's glow (glow.gdshader `energy`), for checks.
var tape_shell: ShaderMaterial
var _socket := Vector3.INF
var _plinth_top := -INF
var _plinth := Vector3.INF

static var _tex := {}

## Dresses `level` (built up to its room index by Level.build) as the station. Returns the view, also kept as
## the level's "station" meta and added as its child (it sets the lights every frame after Level.update_lights).
static func dress(level: Level, source_plan: RefCounted = null) -> Node3D:
	var v: Node3D = new()
	v.name = "StationView"
	v.process_priority = 1000
	v.call(&"_dress", level, source_plan)
	return v

## The anchors for this plan: the rules plan's `station` (a property or meta of sim/station.gd's plan), else
## the drawn plan's "station" key; {} when neither has one.
static func anchors_of(plan_dict: Dictionary, source_plan: RefCounted) -> Dictionary:
	if source_plan != null:
		var a: Variant = source_plan.get("station")
		if a is Dictionary and not (a as Dictionary).is_empty():
			return a
		if source_plan.has_meta(&"station"):
			var m: Variant = source_plan.get_meta(&"station")
			if m is Dictionary:
				return m
	var d: Variant = plan_dict.get("station")
	return d if d is Dictionary else {}

func _dress(level: Level, source_plan: RefCounted) -> void:
	lv = level
	fp = source_plan
	level.set_meta(&"station", self)
	level.add_child(self)
	level.shadows = false
	level.ambient_lit = AMBIENT_LIT
	level.ambient_dark = AMBIENT_CUT
	level.set_meta(&"fog_color", Color(0.03, 0.03, 0.025))
	level.set_meta(&"fog_density", 0.03)
	anchors = anchors_of(level.plan, source_plan)
	_hall = rect(anchors.get("hall"))
	_gallery = rect(anchors.get("gallery"))
	for c: Variant in anchors.get("crawl", []):
		_crawl[cell3(c)] = true
	for e: Variant in anchors.get("glass", []):
		if e is Array and (e as Array).size() >= 4:
			var g: Array = e
			_glass["%d,%d,%d,%d" % [int(g[0]), int(g[1]), int(g[2]), int(g[3])]] = true
			_glass["%d,%d,%d,%d" % [int(g[2]), int(g[3]), int(g[0]), int(g[1])]] = true
	_materials()
	_floors_and_ceilings()
	_walls()
	# LA1: grey steel frames on the doorways (client/door_frames.gd).
	var frames := preload("res://client/door_frames.gd")
	frames.build(lv, frames.STEEL, Color(0, 0, 0, 0), frames.STEEL_TEX)
	lv._build_stairs()
	_battens()
	_lamps()
	dresser = Dress.new()
	add_child(dresser)
	dresser.prepare(lv, self, anchors)
	_rotor()
	dresser.build()
	_landing()
	_plinth_table()
	_crawl_trays()
	_growths()
	_cabinet()
	_commit()
	_movables()
	crew = CrewFour.new()
	crew.name = "StationCrew"
	add_child(crew)
	crew.call(&"set_bodies", anchors.get("bodies", []))
	level.props_placed = placed.size()
	_apply()

# --- anchors -----------------------------------------------------------------------------------------

## A point in world metres from any of the shapes an anchor may come in: Vector3, Vector2 (x, z), [x, y, z],
## [x, z], {x, y, z} / {x, z}, or {at: ...} / {pos: ...}.
static func v3(a: Variant, y := 0.0) -> Vector3:
	return Point.v3(a, y)

## A floor rectangle (x, z, metres) from Rect2, {x0, z0, x1, z1}, {x, z, w, h} or [x0, z0, x1, z1].
static func rect(a: Variant) -> Rect2:
	if a is Rect2:
		return a
	if a is Array and (a as Array).size() >= 4:
		var r: Array = a
		return Rect2(Vector2(float(r[0]), float(r[1])), Vector2.ZERO).expand(Vector2(float(r[2]), float(r[3])))
	if a is Dictionary:
		var d: Dictionary = a
		if d.has("x0"):
			return Rect2(Vector2(float(d["x0"]), float(d["z0"])), Vector2.ZERO).expand(Vector2(float(d["x1"]), float(d["z1"])))
		if d.has("w"):
			return Rect2(float(d["x"]), float(d.get("z", d.get("y", 0.0))), float(d["w"]), float(d["h"]))
	return Rect2()

## A cell (level, x, y) from Vector3i, Vector2i (level 0), [x, y], [level, x, y] or {level, x, y}.
static func cell3(a: Variant) -> Vector3i:
	if a is Vector3i:
		return a
	if a is Vector2i:
		return Vector3i(0, (a as Vector2i).x, (a as Vector2i).y)
	if a is Array:
		var r: Array = a
		return Vector3i(int(r[0]), int(r[1]), int(r[2])) if r.size() >= 3 else Vector3i(0, int(r[0]), int(r[1]))
	if a is Dictionary:
		var d: Dictionary = a
		return Vector3i(int(d.get("level", 0)), int(d["x"]), int(d["y"]))
	return Vector3i(-1, -1, -1)

## The yaw (radians, the model's +z turned to face this way) an anchor asks for: its `facing` / `dir`
## ("n", "s", "e", "w"), or `yaw`; else facing from the point toward the middle of the cell it stands in.
func _facing(a: Variant, at: Vector3) -> float:
	if a is Dictionary:
		var d: Dictionary = a
		for k: String in ["facing", "dir", "wall"]:
			if d.has(k) and (d[k] is String or d[k] is StringName):
				match str(d[k]):
					"n": return PI
					"s": return 0.0
					"e": return PI * 0.5
					"w": return -PI * 0.5
		if d.has("yaw"):
			return float(d["yaw"]) + PI   # the anchors' yaw faces (-sin, -cos) (sim/entity.gd yaw_toward)
	var cx := (floorf(at.x / S) + 0.5) * S
	var cz := (floorf(at.z / S) + 0.5) * S
	var to := Vector2(cx - at.x, cz - at.z)
	if to.length() < 0.2:
		var v := lv._dir_vec(lv.lift_dir)
		to = -Vector2(v.x, v.y)
	return atan2(to.x, to.y)

func _place(kind: String, at: Vector3) -> void:
	placed.append({"kind": kind, "at": at})
	drawn[kind] = int(drawn.get(kind, 0)) + 1

func _anchor_at(a: Variant) -> Vector3:
	var p := v3(a)
	if test_break == "anchor" and p != Vector3.INF:
		return lv.cell_center(lv.landing.x, lv.landing.y, lv.landing.z)
	return p

# --- textures ------------------------------------------------------------------------------------------

static func _hash01(x: int, y: int, k: int) -> float:
	var h := (x * 374761393 + y * 668265263 + k * 1442695041) & 0x7fffffff
	h = ((h ^ (h >> 13)) * 1274126177) & 0x7fffffff
	return float(h & 0xffff) / 65535.0

static func _finish(key: String, img: Image) -> Texture2D:
	img.generate_mipmaps()
	var t := ImageTexture.create_from_image(img)
	_tex[key] = t
	return t

## AR1: the station's surfaces are CC0 photo maps (godot/assets/reactor, SOURCES.md there; made by
## assets_src/reactor_textures.py at the old greys' brightness), laid in world metres by station_surface.gdshader.
## Board-marked poured concrete above, old green paint worn to the concrete below (`green`: the paint map).
static func wall_tex(green: bool) -> Texture2D:
	return Dress.tex("wall_paint.webp" if green else "wall_concrete.webp")

static func floor_tex() -> Texture2D:
	return Dress.tex("floor_concrete.webp")

static func ceil_tex() -> Texture2D:
	return Dress.tex("ceiling_concrete.webp")

## Yellow and black hazard stripes on the lift sill and the cabinet.
static func stripe_tex() -> Texture2D:
	if _tex.has("stripe"):
		return _tex["stripe"]
	var n := 32
	var img := Image.create(n, n, false, Image.FORMAT_RGB8)
	for y in n:
		for x in n:
			var worn := _hash01(x / 2, y / 2, 31) > 0.85
			var c := C_YELLOW if ((x + y) / 8) % 2 == 0 else C_BLACK
			img.set_pixel(x, y, c.lerp(Color(0.4, 0.4, 0.38), 0.6) if worn else c)
	return _finish("stripe", img)

# --- materials -----------------------------------------------------------------------------------------

## Metres one copy of each map covers (the photographs' own sizes, near enough: Poly Haven gives 2 to 3 m).
const WALL_TILE := 2.3
const PAINT_TILE := 2.0
const FLOOR_TILE := 3.0
const CEIL_TILE := 2.0
const DADO := 1.2

func _surface(tex: Texture2D, stain: float, tile: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = Level._shader("res://client/station_surface.gdshader")
	m.set_shader_parameter("albedo_tex", tex)
	m.set_shader_parameter("stain_tex", load("res://assets/textures/decal_rust_stain.png"))
	m.set_shader_parameter("stain_amount", stain)
	m.set_shader_parameter("self_light", SELF_LIT)
	m.set_shader_parameter("tile_m", tile)
	m.set_shader_parameter("storey", LH)
	return m

func _materials() -> void:
	mat_wall_c = _surface(wall_tex(false), 0.8, WALL_TILE)
	mat_wall_g = _surface(wall_tex(false), 0.8, WALL_TILE)
	mat_wall_g.set_shader_parameter("paint_tex", wall_tex(true))
	mat_wall_g.set_shader_parameter("paint_tile_m", PAINT_TILE)
	mat_wall_g.set_shader_parameter("dado", DADO)
	mat_floor = _surface(floor_tex(), 0.7, FLOOR_TILE)
	mat_ceil = _surface(ceil_tex(), 0.5, CEIL_TILE)
	mat_props = Level.prop_material(Color.WHITE, null, true)
	mat_sill = Level.prop_material(Color.WHITE, stripe_tex())
	mat_glass = ShaderMaterial.new()
	mat_glass.shader = load("res://client/wire_glass.gdshader")

func _commit() -> void:
	for key: String in lv._chunks:
		var st: SurfaceTool = lv._chunks[key]
		var what := key.get_slice("_", 3)
		st.index()
		var mi := MeshInstance3D.new()
		mi.mesh = st.commit()
		mi.name = key
		match what:
			"swallc", "srail": mi.material_override = mat_wall_c
			"swallg": mi.material_override = mat_wall_g
			"sfloor": mi.material_override = mat_floor
			"sceil": mi.material_override = mat_ceil
			"sprops": mi.material_override = mat_props
			"ssill":
				mi.material_override = mat_sill
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			"sglass":
				mi.material_override = mat_glass
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		lv.add_child(mi)
	lv._chunks.clear()

# --- architecture ----------------------------------------------------------------------------------------

func _room_cell(level: int, x: int, y: int) -> bool:
	return lv.kind(level, x, y) == "room"

func _floors_and_ceilings() -> void:
	for y in lv.H:
		for x in lv.W:
			if lv.walkable(0, x, y):
				if lv.kind(0, x, y) != "stair":
					lv._floor_quad(0, x, y, 0.0, true, "sfloor")
				var above := lv.kind(1, x, y)
				if above != "atriumOpen" and above != "stair":
					lv._floor_quad(0, x, y, LH - 0.001, false, "sceil")
			var k1 := lv.kind(1, x, y)
			if k1 == "corridor" or k1 == "room" or k1 == "landing":
				lv._floor_quad(1, x, y, LH, true, "sfloor")
			if k1 == "corridor" or k1 == "room" or k1 == "atriumOpen" or k1 == "stair" or k1 == "landing":
				lv._floor_quad(1, x, y, 2 * LH - 0.001, false, "sceil")

## Green in the rooms, plain concrete along the corridors (a wall between the two takes the room's paint).
func _wall_what(level: int, a: Vector2i, b: Vector2i) -> String:
	return "swallg" if _room_cell(level, a.x, a.y) or _room_cell(level, b.x, b.y) else "swallc"

## A wall between the gallery and the hall: low wall, wired glass, a lintel.
func _glass_edge(level: int, a: Vector2i, b: Vector2i) -> bool:
	if not _glass.is_empty():
		return level == 0 and _glass.has("%d,%d,%d,%d" % [a.x, a.y, b.x, b.y])
	if not _gallery.has_area() or not _hall.has_area():
		return false
	var ga := _gallery.has_point(Vector2((a.x + 0.5) * S, (a.y + 0.5) * S))
	var gb := _gallery.has_point(Vector2((b.x + 0.5) * S, (b.y + 0.5) * S))
	var ha := _hall.has_point(Vector2((a.x + 0.5) * S, (a.y + 0.5) * S))
	var hb := _hall.has_point(Vector2((b.x + 0.5) * S, (b.y + 0.5) * S))
	return level >= 0 and ((ga and hb and not gb) or (gb and ha and not ga))

func _edge(level: int, x0: float, z0: float, x1: float, z1: float, a: Vector2i, b: Vector2i, k: String, is_lift: bool, ext0: bool, ext1: bool) -> void:
	if (k == "wall" or k == "rail") and not is_lift and _glass_edge(level, a, b):
		var low := 1.0
		var top := LH - 0.35
		lv._wall_edge(level, x0, z0, x1, z1, a, b, [[0.0, S]], 0.0, low, "swallg", ext0, ext1)
		lv._wall_edge(level, x0, z0, x1, z1, a, b, [[0.0, S]], top, LH, "swallg", ext0, ext1)
		var st := lv._st(level, (x0 + x1) * 0.5, (z0 + z1) * 0.5, "sglass")
		var base := level * LH
		var n := Vector3(z1 - z0, 0, x0 - x1).normalized()
		AnnexView.quad(st, Vector3(x0, base + low, z0), Vector3(x1, base + low, z1), Vector3(x1, base + top, z1), Vector3(x0, base + top, z0),
			Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, n, Color.WHITE)
		drawn["glass"] = int(drawn.get("glass", 0)) + 1
		return
	for piece: Array in lv._edge_parts(level, k, is_lift):
		var what: String = "srail" if piece.size() > 3 else _wall_what(level, a, b)
		lv._wall_edge(level, x0, z0, x1, z1, a, b, piece[0], piece[1], piece[2], what, ext0, ext1)

func _walls() -> void:
	var lift_edge := lv._lift_edge()
	for level in 2:
		var vert: Array = lv.edges[level].vertical
		var hor: Array = lv.edges[level].horizontal
		for y in lv.H:
			for x in lv.W + 1:
				var k: String = vert[y * (lv.W + 1) + x]
				var is_lift := level == lv.landing.x and lift_edge == Vector4i(0, x, y, 1)
				var before: String = vert[(y - 1) * (lv.W + 1) + x] if y > 0 else "none"
				var after: String = vert[(y + 1) * (lv.W + 1) + x] if y + 1 < lv.H else "none"
				_edge(level, x * S, y * S, x * S, (y + 1) * S, Vector2i(x - 1, y), Vector2i(x, y), k, is_lift, lv._ext(k, before), lv._ext(k, after))
		for y in lv.H + 1:
			for x in lv.W:
				var k: String = hor[y * lv.W + x]
				var is_lift := level == lv.landing.x and lift_edge == Vector4i(1, x, y, 1)
				var before: String = hor[y * lv.W + x - 1] if x > 0 else "none"
				var after: String = hor[y * lv.W + x + 1] if x + 1 < lv.W else "none"
				_edge(level, x * S, y * S, (x + 1) * S, y * S, Vector2i(x, y - 1), Vector2i(x, y), k, is_lift, lv._ext(k, before), lv._ext(k, after))

# --- light -----------------------------------------------------------------------------------------------

## Warm battens on the ceiling with the mains: along the corridors every third cell, in the rooms on a 3-cell
## grid. They are the level's main lights (Level.update_lights dims them in a blink; this view cuts them).
func _battens() -> void:
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.16, 0.08, 1.25)
	for level in 2:
		for y in lv.H:
			for x in lv.W:
				if lv.main_lights.size() >= BATTEN_LIMIT:
					return
				var k := lv.kind(level, x, y)
				var want := (k == "corridor" or k == "room" or k == "landing") and lv._want_panel(level, x, y)
				if not want or _crawl.has(Vector3i(level, x, y)):
					continue
				var pos := lv.cell_center(level, x, y)
				pos.y = level * LH + LH - 0.06
				var gm := Level.glow_material(BATTEN, 1.0)
				var mi := MeshInstance3D.new()
				mi.mesh = mesh
				mi.material_override = gm
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				mi.position = pos
				add_child(mi)
				_batten_mats.append(gm)
				var l := SpotLight3D.new()
				l.position = pos - Vector3(0, 0.06, 0)
				l.rotation_degrees = Vector3(-90, 0, 0)
				l.spot_angle = BATTEN_ANGLE
				l.spot_angle_attenuation = BATTEN_SOFT
				l.spot_range = BATTEN_REACH
				l.light_color = BATTEN
				l.light_energy = BATTEN_ENERGY
				l.distance_fade_enabled = true
				l.distance_fade_begin = 18.0
				l.distance_fade_length = 6.0
				add_child(l)
				lv.main_lights.append(l)
				lv._base_energy.append(BATTEN_ENERGY)
	drawn["batten"] = lv.main_lights.size()

## The amber service lamps from the anchors (each {at, emergency}); the emergency ones stay on, dim, in the cut.
## With no lamp anchors, every fourth landing or corridor cell gets one, the even ones on the emergency circuit.
func _lamps() -> void:
	var list: Array = anchors.get("lamps", [])
	if list.is_empty():
		var i := 0
		for y in lv.H:
			for x in lv.W:
				var k := lv.kind(0, x, y)
				if (k == "corridor" or k == "landing") and (x * 3 + y) % 4 == 0:
					list.append({"at": lv.cell_center(0, x, y) + Vector3(0, LH - 0.35, 0), "emergency": i % 2 == 0})
					i += 1
	var cage := BoxMesh.new()
	cage.size = Vector3(0.22, 0.16, 0.16)
	var globe := SphereMesh.new()
	globe.radius = 0.075
	globe.height = 0.15
	for a: Variant in list:
		var at := _anchor_at(a)
		if at == Vector3.INF:
			continue
		if at.y < 0.5 + floorf(at.y / LH) * LH:
			at.y = floorf(at.y / LH) * LH + LH - 0.35   # a lamp given at floor level hangs under the ceiling
		var em := bool((a as Dictionary).get("emergency", (a as Dictionary).get("em", false))) if a is Dictionary else false
		var housing := MeshInstance3D.new()
		housing.mesh = cage
		housing.material_override = Level.prop_material(Color(0.2, 0.2, 0.18))
		housing.position = at + Vector3(0, 0.1, 0)
		add_child(housing)
		var gm := Level.glow_material(AMBER, 1.4)
		var g := MeshInstance3D.new()
		g.mesh = globe
		g.material_override = gm
		g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		g.position = at
		add_child(g)
		var o := OmniLight3D.new()
		o.position = at - Vector3(0, 0.12, 0)
		o.light_color = AMBER
		o.light_energy = LAMP_ENERGY
		o.omni_range = LAMP_REACH
		o.omni_attenuation = 1.2
		o.distance_fade_enabled = true
		o.distance_fade_begin = 22.0
		o.distance_fade_length = 6.0
		add_child(o)
		lamps.append({"light": o, "globe": gm, "emergency": em, "at": at})
		_place("lamp", at)

## The power from the block: 0 the mains, 1 the cut, 2 restored.
func set_power(p: int) -> void:
	power = p

func lit() -> bool:
	return power != EMERGENCY

func _process(_delta: float) -> void:
	if lv == null:
		return
	if link != null:
		_follow_frame()
	_apply()

## Every light and material for the power now. Runs after Level.update_lights (process_priority) so the cut
## holds whatever the main game's blink dial says.
func _apply() -> void:
	var on := lit() or test_break == "lights"
	var level_k := clampf(lv._level, 0.0, 1.0)
	for i in lv.main_lights.size():
		var l := lv.main_lights[i]
		l.visible = on and level_k > 0.02
		l.light_energy = lv._base_energy[i] * level_k if on else 0.0
	if _applied == power:
		return
	_applied = power
	for m in _batten_mats:
		m.set_shader_parameter("energy", 1.0 if on else 0.05)
	for d: Dictionary in lamps:
		var l: OmniLight3D = d["light"]
		var em := bool(d["emergency"])
		l.visible = on or em
		l.light_energy = LAMP_ENERGY if on else EM_ENERGY
		l.omni_range = LAMP_REACH if on else EM_REACH
		(d["globe"] as ShaderMaterial).set_shader_parameter("energy", 1.4 if on else (0.7 if em else 0.06))
	for m: ShaderMaterial in [mat_wall_c, mat_wall_g, mat_floor, mat_ceil]:
		m.set_shader_parameter("self_light", SELF_LIT if on else SELF_CUT)
	if dresser != null:
		dresser.set_lit(on)
	lv.ambient_lit = AMBIENT_LIT if on else AMBIENT_CUT
	lv.set_meta(&"near_light", 0.0 if on else NEAR_CUT)
	if socket_lamp != null:
		socket_lamp.set_shader_parameter("color", Color(0.3, 1.0, 0.4) if power == RESTORED else Color(1.0, 0.2, 0.1))

## What a test reads of the lights now.
func lights() -> Dictionary:
	var battens_on := 0
	for l in lv.main_lights:
		battens_on += int(l.visible and l.light_energy > 0.01)
	var lamps_on := 0
	var em_on := 0
	for d: Dictionary in lamps:
		var l: OmniLight3D = d["light"]
		if l.visible and l.light_energy > 0.01:
			lamps_on += 1
			em_on += int(bool(d["emergency"]))
	return {"battens": lv.main_lights.size(), "battensOn": battens_on, "lamps": lamps.size(), "lampsOn": lamps_on, "emergencyOn": em_on,
		"near": float(lv.get_meta(&"near_light", 0.0)), "ambient": lv.ambient_lit}

# --- the named places ----------------------------------------------------------------------------------

func _box(level: int, at: Vector3, size: Vector3, yaw: float, centre: Vector3, col: Color, what := "sprops") -> void:
	var xf := Transform3D(Basis(Vector3.UP, yaw), at)
	AnnexView.box(lv._st(level, at.x, at.z, what), xf, size, centre, col)

func _lvl(at: Vector3) -> int:
	return clampi(int(floorf((at.y + 0.5) / LH)), 0, 1)

func _prim(mesh: PrimitiveMesh, xf: Transform3D, col: Color) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = Level.prop_material(col)
	mi.transform = xf
	add_child(mi)

static func _cyl(r_top: float, r_bot: float, h: float, seg := 16) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = r_top
	c.bottom_radius = r_bot
	c.height = h
	c.radial_segments = seg
	c.rings = 1
	return c

## The stopped rotor at the hall's far end, its axis down the hall's long side so the sightline from the landing
## ends on its face (AR1: client/station_dress.gd rotor(): bedplate, pedestals, the open casing, five stages of
## pitched blades, inside the old rotor's box).
func _rotor() -> void:
	var at := _anchor_at(anchors.get("rotor"))
	if at == Vector3.INF:
		return
	at.y = floorf((at.y + 0.5) / LH) * LH
	var along_x := _hall.has_area() and _hall.size.x >= _hall.size.y
	var ra: Variant = anchors.get("rotor")
	var r := minf(float((ra as Dictionary).get("radius", 1.05)) if ra is Dictionary else 1.05, 1.15)
	var wall_z := _hall.position.y if _hall.has_area() and not along_x else -INF
	dresser.rotor(at, along_x, r, wall_z)
	_place("rotor", at)

## The landing at shift change: the striped sill at the lift door, a board of four locker hooks over four
## time-card slots, each slot holding a card.
func _landing() -> void:
	var v := lv._dir_vec(lv.lift_dir)
	var lift_v := Vector3(v.x, 0, v.y)
	var door := lv.cell_center(lv.landing.x, lv.landing.y, lv.landing.z) + lift_v * (S * 0.5)
	var along := Vector3(-v.y, 0, v.x)
	var sill := _anchor_at(anchors.get("sill"))
	if sill == Vector3.INF:
		sill = door - lift_v * 0.2
	sill.y = lv.landing.x * LH + 0.006
	var sa: Variant = anchors.get("sill")
	var half := float((sa as Dictionary).get("width", lv.lift_half * 2.0)) * 0.5 if sa is Dictionary else lv.lift_half
	var st := lv._st(lv.landing.x, sill.x, sill.z, "ssill")
	var a := sill - along * half - lift_v * 0.2
	var b := sill + along * half - lift_v * 0.2
	var c := sill + along * half + lift_v * 0.2
	var d := sill - along * half + lift_v * 0.2
	AnnexView.quad(st, a, b, c, d, Vector2(0, 0), Vector2(half * 2.0 / 0.4, 0), Vector2(half * 2.0 / 0.4, 1), Vector2(0, 1), Vector3.UP, Color.WHITE)
	_place("sill", sill)
	# The four locker hooks (sim/station.gd: four {at, yaw, seat} on the landing's west wall) and the four
	# time-card slots (four on its east wall), each with its card; one point instead draws a row of four hooks.
	var hooks: Variant = anchors.get("lockers")
	if hooks is Array:
		for h: Variant in hooks:
			_hook(h)
	elif hooks != null:
		var at := _anchor_at(hooks)
		if at != Vector3.INF:
			var yaw := _facing(hooks, at)
			for i in 4:
				_hook({"at": at + Basis(Vector3.UP, yaw) * Vector3(-0.54 + i * 0.36, 0, 0), "yaw": yaw - PI})
	for tc: Variant in anchors.get("time_cards", []):
		_card(tc)

## One locker hook on the wall: a wooden plate and a steel peg.
func _hook(h: Variant) -> void:
	var at := _anchor_at(h)
	if at == Vector3.INF:
		return
	var yaw := _facing(h, at)
	var lvl := _lvl(at)
	var base := Vector3(at.x, lvl * LH, at.z)
	_box(lvl, base, Vector3(0.3, 0.3, 0.03), yaw, Vector3(0, 1.72, 0.015), C_WOOD)
	_box(lvl, base, Vector3(0.03, 0.03, 0.12), yaw, Vector3(0, 1.7, 0.08), C_STEEL)
	_box(lvl, base, Vector3(0.03, 0.07, 0.03), yaw, Vector3(0, 1.73, 0.13), C_STEEL)
	_place("locker", at)

## One time-card slot on the wall with its card standing in it (at the anchor's own height).
func _card(c: Variant) -> void:
	var at := _anchor_at(c)
	if at == Vector3.INF:
		return
	var yaw := _facing(c, at)
	var lvl := _lvl(at)
	var y := at.y - lvl * LH
	if y < 0.5:
		y = 1.3
	var base := Vector3(at.x, lvl * LH, at.z)
	_box(lvl, base, Vector3(0.16, 0.3, 0.04), yaw, Vector3(0, y, 0.02), C_STEEL.darkened(0.3))
	_box(lvl, base, Vector3(0.12, 0.05, 0.03), yaw, Vector3(0, y - 0.1, 0.055), C_STEEL)
	_box(lvl, base, Vector3(0.09, 0.2, 0.006), yaw, Vector3(0, y, 0.06), C_CARD)
	_box(lvl, base, Vector3(0.07, 0.01, 0.007), yaw, Vector3(0, y + 0.05, 0.064), C_BLACK)
	_place("time_card", at)

## The cassette's table beside the lift door.
func _plinth_table() -> void:
	var at := _anchor_at(anchors.get("plinth"))
	if at == Vector3.INF:
		return
	var lvl := _lvl(at)
	var base := Vector3(at.x, lvl * LH, at.z)
	var top := PLINTH_TOP
	_box(lvl, base, Vector3(0.66, 0.04, 0.5), 0.0, Vector3(0, top - 0.02, 0), C_WOOD)
	for sx: float in [-0.29, 0.29]:
		for sz: float in [-0.2, 0.2]:
			_box(lvl, base, Vector3(0.04, top - 0.04, 0.04), 0.0, Vector3(sx, (top - 0.04) * 0.5, sz), C_STEEL.darkened(0.3))
	_plinth = base
	_plinth_top = base.y + top
	_place("plinth", at)

## The crawl under the gallery: a low concrete soffit and cable trays both sides, cables sagging in them.
func _crawl_trays() -> void:
	for c: Vector3i in _crawl:
		var level := c.x
		var mid := lv.cell_center(level, c.y, c.z)
		var base := Vector3(mid.x, level * LH, mid.z)
		_box(level, base, Vector3(S, 0.18, S), 0.0, Vector3(0, 1.32, 0), C_CONCRETE)
		for side: float in [-0.78, 0.78]:
			for h: float in [0.42, 1.0]:
				var along_x := lv.walkable(level, c.y + 1, c.z) or lv.walkable(level, c.y - 1, c.z)
				var off := Vector3(0, h, side) if along_x else Vector3(side, h, 0)
				var size := Vector3(S, 0.05, 0.32) if along_x else Vector3(0.32, 0.05, S)
				_box(level, base, size, 0.0, off, C_STEEL.darkened(0.2))
				var cable := Vector3(S, 0.06, 0.24) if along_x else Vector3(0.24, 0.06, S)
				_box(level, base, cable, 0.0, off + Vector3(0, 0.05, 0), Color(0.08, 0.08, 0.09))
		_place("crawl", base)

## The growths from the anchors (each {at, kind}: a warm pipe collar split open, cracked lagging, a split cable
## tray): AR1, client/station_dress.gd roots each on the run of its kind on the nearest wall. One placed record per
## anchor, at the root it was drawn on.
func _growths() -> void:
	for c: Dictionary in dresser.clusters:
		if c["anchor"] == Vector3.INF:
			continue
		placed.append({"kind": "growth", "at": c["at"], "growth": c["kind"], "anchor": c["anchor"]})
		drawn["growth"] = int(drawn.get("growth", 0)) + 1
## The marked service cabinet against its wall: grey steel, hazard stripes, a stencilled label, the fuse socket
## and its lamp (red while the socket is empty and the power is cut, green once restored).
func _cabinet() -> void:
	var ca: Variant = anchors.get("cabinet")
	var at := _anchor_at(ca)
	if at == Vector3.INF:
		return
	_socket = at
	var yaw := _facing(ca, at)
	var lvl := _lvl(at)
	var base := Vector3(at.x, lvl * LH, at.z)
	_box(lvl, base, Vector3(0.8, 1.6, 0.36), yaw, Vector3(0, 0.8, 0.18), C_STEEL)
	_box(lvl, base, Vector3(0.82, 0.1, 0.38), yaw, Vector3(0, 1.62, 0.18), C_YELLOW)
	_box(lvl, base, Vector3(0.18, 0.12, 0.05), yaw, Vector3(0, 1.05, 0.38), C_BLACK)
	var stripe := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(0.78, 0.12)
	stripe.mesh = q
	stripe.material_override = mat_sill
	var b := Basis(Vector3.UP, yaw)
	stripe.transform = Transform3D(b, base + b * Vector3(0, 0.12, 0.365))
	add_child(stripe)
	var label := Label3D.new()
	label.text = "SERVICE\nFUSE"
	label.font_size = 48
	label.pixel_size = 0.004
	label.modulate = Color(0.95, 0.9, 0.8)
	label.outline_size = 0
	label.transform = Transform3D(b, base + b * Vector3(0, 1.34, 0.37))
	add_child(label)
	var lamp := SphereMesh.new()
	lamp.radius = 0.03
	lamp.height = 0.06
	socket_lamp = Level.glow_material(Color(1.0, 0.2, 0.1), 1.2)
	var li := MeshInstance3D.new()
	li.mesh = lamp
	li.material_override = socket_lamp
	li.position = base + b * Vector3(0.2, 1.05, 0.38)
	add_child(li)
	socket_fuse = _fuse_mesh()
	socket_fuse.transform = Transform3D(b * Basis(Vector3.FORWARD, PI * 0.5), base + b * Vector3(0, 1.05, 0.4))
	socket_fuse.visible = false
	add_child(socket_fuse)
	_place("cabinet", at)

# --- props the block moves -------------------------------------------------------------------------------

func _fuse_mesh() -> Node3D:
	var n := Node3D.new()
	var body := MeshInstance3D.new()
	body.mesh = _cyl(0.035, 0.035, 0.16, 10)
	body.material_override = Level.prop_material(Color(0.9, 0.88, 0.82), null, false, 0.0, 0.15)
	n.add_child(body)
	for e: float in [-0.09, 0.09]:
		var cap := MeshInstance3D.new()
		cap.mesh = _cyl(0.04, 0.04, 0.03, 10)
		cap.material_override = Level.prop_material(Color(0.72, 0.58, 0.25))
		cap.position = Vector3(0, e, 0)
		n.add_child(cap)
	return n

func _movables() -> void:
	fuse_node = _fuse_mesh()
	fuse_node.name = "Fuse"
	fuse_node.visible = false
	add_child(fuse_node)
	cassette_node = Node3D.new()
	cassette_node.name = "Cassette"
	var shell := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.19, 0.025, 0.105)
	shell.mesh = bm
	tape_shell = Level.glow_material(CASSETTE_GLOW.darkened(0.45), TAPE_SHELL_GLOW)
	shell.material_override = tape_shell
	shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cassette_node.add_child(shell)
	var face := MeshInstance3D.new()
	var fm := BoxMesh.new()
	fm.size = Vector3(0.12, 0.027, 0.05)
	face.mesh = fm
	face.material_override = Level.glow_material(CASSETTE_GLOW.lightened(0.2), TAPE_FACE_GLOW)
	cassette_node.add_child(face)
	_tape_halo = MeshInstance3D.new()
	_tape_halo.name = "Halo"
	var hq := QuadMesh.new()
	hq.size = Vector2(TAPE_HALO, TAPE_HALO)
	_tape_halo.mesh = hq
	_tape_halo.material_override = _halo_material()
	_tape_halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_tape_halo.position = Vector3(0, 0.03, 0)
	cassette_node.add_child(_tape_halo)
	_tape_light = OmniLight3D.new()
	_tape_light.light_color = CASSETTE_GLOW
	_tape_light.light_energy = TAPE_LIGHT_ENERGY
	_tape_light.omni_range = TAPE_LIGHT_REACH
	_tape_light.omni_attenuation = 1.0
	_tape_light.shadow_enabled = false
	_tape_light.position = Vector3(0, 0.25, 0)
	cassette_node.add_child(_tape_light)
	cassette_node.visible = false
	add_child(cassette_node)

## The halo round the cassette: a soft warm disc, added on top of what is behind it, always facing the camera.
static func _halo_material() -> StandardMaterial3D:
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 1))
	grad.set_color(1, Color(1, 1, 1, 0))
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(0.5, 0.0)
	gt.width = 32
	gt.height = 32
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_texture = gt
	m.albedo_color = Color(CASSETTE_GLOW.r, CASSETTE_GLOW.g, CASSETTE_GLOW.b, 0.55)
	return m

## Where a player's carried thing is drawn: the camera's lower right for this player, at another's hip.
func _carried_at(block: Dictionary, id: String, me: String, side: float) -> Variant:
	if id == me:
		var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
		if cam != null:
			return cam.global_transform * Vector3(0.2 * side, -0.24, -0.42)
	var p := v3(block.get("players", {}).get(id, null))
	if p == Vector3.INF:
		return null
	return p + Vector3(0.22 * side, 0.95, 0.0)

static func _id(v: Variant) -> String:
	var s := str(v)
	return "" if s in ["0", "", "<null>", "null"] else s

## Draws the block's props and works out the prompt for player `me`.
func show_block(block: Variant, me: String) -> void:
	if not block is Dictionary:
		prompt = ""
		return
	var b: Dictionary = block
	set_power(int(b.get("power", 0)))
	var holder := _id(b.get("holder", 0))
	var fuse_at := v3(b.get("fuseAt"))
	if holder.is_empty():
		fuse_node.visible = fuse_at != Vector3.INF and power != RESTORED
		if fuse_node.visible:
			fuse_node.transform = Transform3D(Basis(Vector3.FORWARD, PI * 0.5), fuse_at + Vector3(0, 0.04, 0))
	else:
		var c: Variant = _carried_at(b, holder, me, 1.0)
		fuse_node.visible = c != null
		if c != null:
			fuse_node.position = c
	if socket_fuse != null:
		socket_fuse.visible = power == RESTORED
	var tape_holder := _id(b.get("cassetteHolder", ""))
	var tape_at := v3(b.get("tapeAt"))
	if not bool(b.get("cassette", false)) and tape_at != Vector3.INF:
		var p := tape_at
		if _plinth != Vector3.INF and Vector2(p.x - _plinth.x, p.z - _plinth.z).length() < 0.6 and p.y < _plinth_top:
			p.y = _plinth_top
		cassette_node.position = p + Vector3(0, 0.014, 0)
		cassette_node.visible = true
		_tape_light.visible = true
		_tape_halo.visible = true
	elif not tape_holder.is_empty():
		var c2: Variant = _carried_at(b, tape_holder, me, -1.0)
		cassette_node.visible = c2 != null
		if c2 != null:
			cassette_node.position = c2
		_tape_light.visible = tape_holder != me
		_tape_halo.visible = tape_holder != me   # not a glare in your own hand
	else:
		cassette_node.visible = false
	prompt = prompt_for(b, me, _socket)
	if crew != null:
		crew.call(&"set_power", power)

static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length() if a != Vector3.INF and b != Vector3.INF else INF

## What F would do for `me` now, as sim/reactor.gd use() would take it (its order and its reach): take the fuse,
## install it at the socket, pick up the cassette; "" when the rules would refuse. From the host's own block
## (the body the host accepted), never from the drawing.
static func prompt_for(block: Dictionary, me: String, socket: Vector3) -> String:
	if me.is_empty() or str(block.get("status", {}).get(me, "")) != "up":
		return ""
	var feet := v3(block.get("players", {}).get(me, null))
	if feet == Vector3.INF:
		return ""
	var reach := INF if test_break == "reach" else 1.0
	var holder := _id(block.get("holder", 0))
	var emergency := int(block.get("power", -1)) == EMERGENCY
	# Measured across the floor, as the station's rules measure it (sim/station_floor.gd _flat).
	if emergency and holder.is_empty() and _flat(feet, v3(block.get("fuseAt"))) < Marks.FUSE_REACH * reach:
		return FUSE_PROMPT
	if emergency and holder == me and socket != Vector3.INF and _flat(feet, socket) < Marks.FUSE_REACH * reach:
		return INSTALL_PROMPT
	if not bool(block.get("cassette", true)) and _flat(feet, v3(block.get("tapeAt"))) < Marks.TAPE_REACH * reach:
		return TAPE_PROMPT
	return ""

# --- following the room ------------------------------------------------------------------------------------

## The main game hands over its link (client/play_link.gd) and sound library; from then on each frame reads the
## host's newest `reactor` block for the power, the props and the prompt, and the client's interpolated pair of
## snapshots (the same render time every other resident is drawn at) for where the four are.
func follow(play_link: Object, sound: Node) -> void:
	link = play_link
	sfx = sound
	if crew != null:
		crew.set(&"sfx", sound)

func _follow_frame() -> void:
	var c: Object = link.call(&"client")
	if c == null:
		return
	var latest: Variant = c.get("latest")
	var block: Variant = (latest as Dictionary).get("reactor") if latest is Dictionary else null
	var me := str(link.call(&"my_id"))
	var was := power
	show_block(block, me)
	if was != EMERGENCY and power == EMERGENCY and sfx != null:
		sfx.call(&"play", "pop")
	if power == EMERGENCY and sfx != null:
		sfx.call(&"set_hum", 0.0, true)
	var rt: Variant = c.get("_rt")
	var br: Array = c.call(&"_bracket", rt if rt != null else INF) if c.has_method(&"_bracket") else []
	if br.size() == 3 and crew != null:
		crew.call(&"show_blocks", (br[0] as Dictionary).get("reactor"), (br[1] as Dictionary).get("reactor"), float(br[2]))
	elif crew != null:
		crew.call(&"show_blocks", block, block, 1.0)

## Whether a player standing at (x, z) metres is in the crawl (sim/station.gd creep_only). RN3: the creep itself is
## client/play_link.gd's (in_crawl, crawl_step_ok), and the host refuses a standing step in (net/host.gd).
func crouch_at(x: float, z: float) -> bool:
	return _crawl.has(Vector3i(0, floori(x / S), floori(z / S)))

## What a check reads of the cassette's glow: drawn, its shell's energy, its own light and halo.
func tape_glow() -> Dictionary:
	return {"drawn": cassette_node.visible, "shell": float(tape_shell.get_shader_parameter("energy")),
		"light": _tape_light.visible and cassette_node.visible, "energy": _tape_light.light_energy, "reach": _tape_light.omni_range,
		"halo": _tape_halo.visible and cassette_node.visible}

## What a check reads: counts, the anchors placed, the lights, the prompt.
func check() -> Dictionary:
	return {"drawn": drawn.duplicate(), "placed": placed.size(), "power": power, "prompt": prompt, "lights": lights()}
