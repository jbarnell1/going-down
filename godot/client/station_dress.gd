# AR1 (21 Nov): the Reactor's dressing, drawn over the station's walls (client/station_view.gd builds the walls,
# floors and lights; this adds what makes it a generating station). The owner, 21 Nov: "The growths in reactor
# look terrible ... It's currently very rough and blocky." The design (docs/floors/the-intact-crew.md): "Place the
# bulbous growths from the floor seed at warm pipe collars, cracked insulation and split cable trays. Let long
# stretches of ordinary concrete establish what the building used to look like."
#
# What is drawn, all from the plan and its floor seed (the same on every screen), none of it a rule and none of
# it solid (no collision: nothing here changes where a body may stand or what can be seen through):
#   - pipe runs along the walls of each room: a painted main under the ceiling, a steel line lower down and a
#     lagged line at chest height in the hall and the pump rooms, with hangers, brackets, flanges, elbows at the
#     corners, valves, and a flanged elbow into the wall wherever a run meets an opening;
#   - the growths: one cluster at each seeded anchor (pipe collar, cracked lagging, split cable tray), rooted on
#     the run of its kind on the nearest wall and spilling down the wall, plus extra clusters near the rotor;
#     merged lumpy lobes with a wet dark material and faint veins (station_growth.gdshader), strands between;
#   - steel frames on every doorway, a concrete kerb along every wall foot, ladder cable trays in the gallery,
#     switch room and stores, steel beams across the hall's ceiling, yellow walk lines and drains on its floor,
#     stencilled signs, hazard stripes round the rotor;
#   - the rotor itself: bedplate, pedestals, the open lower casing with its split-line flanges and bolts, the shaft
#     and five stages of pitched blades.
#
# Kept clear (tests/test_reactor_look.gd checks the drawn triangles over many seeds): below CLEAR_H nothing stands
# more than BAND from a wall line (bodies keep 0.3 m off walls), and nothing enters a doorway, the lift's opening
# or the wired glass. The rotor keeps inside the old rotor's own box.
extends Node3D

const AnnexView = preload("res://client/annex_view.gd")
const Point = preload("res://client/station_point.gd")

const S := 2.0
const LH := 3.2
const WALL_HALF := 0.07
## Below this height, nothing here stands more than BAND off a wall line.
const CLEAR_H := 2.05
const BAND := 0.27
## The openings kept clear: a door to DOOR_TOP, the lift to LIFT_TOP, the wired glass between its sill and head.
const DOOR_TOP := 2.2
const LIFT_TOP := 2.35
const GLASS_LOW := 1.0
const GLASS_TOP := 2.85
const GAP0 := (S - 1.1) * 0.5
const GAP1 := (S + 1.1) * 0.5
## Each run: its height, pipe radius, lagging radius (0: bare), what it is drawn in, the rooms it runs in.
const RUNS: Array[Dictionary] = [
	{"name": "high", "h": 2.97, "r": 0.085, "lag": 0.0, "mat": "paint", "rooms": ["hall", "gallery", "switch", "stores", "lockers", "office", "pumps"]},
	{"name": "steam", "h": 2.36, "r": 0.11, "lag": 0.0, "mat": "steel", "rooms": ["hall", "pumps", "switch"]},
	{"name": "lagged", "h": 1.62, "r": 0.045, "lag": 0.082, "mat": "lag", "rooms": ["hall", "pumps"], "long_only": true, "no_landing": true},
	{"name": "tray", "h": 2.62, "r": 0.17, "lag": 0.0, "mat": "tray", "rooms": ["gallery", "switch", "stores"], "long_only": true},
]
## The run each growth kind roots on, best first.
const ROOTS := {"pipe_collar": ["steam", "high"], "cracked_insulation": ["lagged", "steam"], "split_cable_tray": ["crawltray"]}
## The Meshy growth (generated on the owner's paid plan, 21 Nov 2026; assets_src/blender/reactor/build_reactor_meshy.py)
## and the radius of its bare pipe in its own units (that script prints it), the most drawn on one floor.
const HERO_GLB := "res://assets/reactor/growth_c.glb"
const ROTOR_GLB := "res://assets/reactor/rotor_b.glb"
const GROWTH_PIPE_R := 0.135
const HERO_MAX := 9
const C_PAINT := Color(0.86, 0.95, 0.88)
const C_STEEL := Color(0.92, 0.92, 0.9)
const C_LAG := Color(0.92, 0.86, 0.72)
const C_FRAME := Color(0.48, 0.62, 0.52)
const C_KERB := Color(0.62, 0.62, 0.6)
const C_DARK := Color(0.2, 0.2, 0.2)
const C_RUST := Color(0.85, 0.55, 0.38)
const C_VALVE := Color(0.85, 0.22, 0.12)
const C_SIGN := Color(0.88, 0.85, 0.74, 0.82)
const C_WARN := Color(0.93, 0.76, 0.18, 0.88)

var lv: Level
var view: Node3D
var anchors := {}
## Every room side: {room, kind, origin, dir, n (into the room), len, openings: Array[Vector4] (s0, s1, y0, y1)}.
var sides: Array[Dictionary] = []
## Straight pieces of the runs along a side: {side, run, s0, s1, h, d, ro}.
var segments: Array[Dictionary] = []
## The growth clusters drawn: {kind, side, s, h, at (world root), anchor, scale}.
var clusters: Array[Dictionary] = []
## Counts by kind, for checks.
var counts := {}
var rotor_node: Node3D
var hero_count := 0
## Every growth material (the shared one and each hero's), for the power: lit with the mains, dimmer in the cut.
var growth_mats: Array[ShaderMaterial] = []
static var _hero_cache := {}
var _st := {}
var _mats := {}
var _noise := FastNoiseLite.new()
var _rng := RandomNumberGenerator.new()
var _lamps: Array[Vector3] = []

## Reads the station: `view` is client/station_view.gd's node (its anchors, its glass test, its lamps, drawn
## before this). Then `rotor` (optional) and `build`.
func prepare(level: Level, station_view: Node3D, station_anchors: Dictionary) -> void:
	lv = level
	view = station_view
	anchors = station_anchors
	name = "StationDress"
	var seed_text := "%s:%d" % [lv.plan.get("seed", ""), int(lv.plan.get("depth", 0))]
	_rng.seed = hash(seed_text + ":dress")
	_noise.seed = hash(seed_text + ":lumps") & 0x7fffffff
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise.frequency = 1.0
	for d: Dictionary in view.get("lamps"):
		_lamps.append(d["at"])
	_materials()
	_sides()

## Lays and draws everything (after `rotor`, so the runs keep clear of it).
func build() -> void:
	var lines := {}
	for run: Dictionary in RUNS:
		lines[run["name"]] = _lay(run)
	_crawl_trays()
	_growths()
	for run: Dictionary in RUNS:
		_draw_run(run, lines[run["name"]])
	_frames_and_kerbs()
	_beams()
	_floor_marks()
	_signs()
	_commit()

## The growths' own glow for the power: with the mains they never read as black cut-outs; in the cut they dim to
## their veins and a faint rim (worse to see, never gone).
const GLOW_LIT := 0.35
const GLOW_CUT := 0.08
const RIM_LIT := 0.6
const RIM_CUT := 0.25

func set_lit(on: bool) -> void:
	for m in growth_mats:
		m.set_shader_parameter("self_glow", GLOW_LIT if on else GLOW_CUT)
		m.set_shader_parameter("rim_glow", RIM_LIT if on else RIM_CUT)

# --- materials -----------------------------------------------------------------------------------------

static func tex(file: String) -> Texture2D:
	return load("res://assets/reactor/%s" % file)

func _materials() -> void:
	_mats["paint"] = Level.prop_material(Color.WHITE, load("res://assets/arboretum/painted_iron.webp"), true, 0.0, 0.0, true)
	_mats["steel"] = Level.prop_material(Color.WHITE, tex("steel_plate.webp"), true, 0.0, 0.0, true)
	_mats["concrete"] = Level.prop_material(Color.WHITE, tex("wall_concrete.webp"), true, 0.0, 0.0, true)
	_mats["line"] = Level.prop_material(Color(1.25, 0.98, 0.25), tex("floor_concrete.webp"), false, 0.0, 0.0, true)
	_mats["stripe"] = view.get("mat_sill")
	var g := ShaderMaterial.new()
	g.shader = Level._shader("res://client/station_growth.gdshader")
	_mats["growth"] = g
	growth_mats.append(g)

## The surface tool for material `mat` in the level chunk round (x, z): one mesh per chunk and material, so each
## mesh meets few lights (client/level.gd CHUNK).
func _tool(mat: String, at: Vector3) -> SurfaceTool:
	var key := "%s|%d|%d" % [mat, floori(at.x / (S * Level.CHUNK)), floori(at.z / (S * Level.CHUNK))]
	if not _st.has(key):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_st[key] = st
	return _st[key]

func _commit() -> void:
	for key: String in _st:
		var st: SurfaceTool = _st[key]
		var mat := key.get_slice("|", 0)
		var mi := MeshInstance3D.new()
		mi.name = "Dress_" + key.replace("|", "_")
		mi.mesh = st.commit()
		mi.material_override = _mats[mat]
		if mat == "growth" or mat == "line" or mat == "stripe":
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
	_st.clear()

# --- geometry helpers ----------------------------------------------------------------------------------

func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3, ca: Color, cb: Color, cc: Color) -> void:
	if (b - a).cross(c - a).dot(na + nb + nc) > 0.0:
		var t := b
		b = c
		c = t
		var tn := nb
		nb = nc
		nc = tn
		var tc := cb
		cb = cc
		cc = tc
	st.set_normal(na)
	st.set_color(ca)
	st.set_uv(Vector2.ZERO)
	st.add_vertex(a)
	st.set_normal(nb)
	st.set_color(cb)
	st.set_uv(Vector2.ZERO)
	st.add_vertex(b)
	st.set_normal(nc)
	st.set_color(cc)
	st.set_uv(Vector2.ZERO)
	st.add_vertex(c)

## A grid of rings x segments (each ring closed), quads between neighbouring rings.
func _grid(st: SurfaceTool, p: Array, n: Array, c: Array, rings: int, segs: int, closed := true) -> void:
	var cols := segs if closed else segs - 1
	for i in rings - 1:
		for j in cols:
			var j2 := (j + 1) % segs
			var a := i * segs + j
			var b := i * segs + j2
			var cc := (i + 1) * segs + j2
			var d := (i + 1) * segs + j
			_tri(st, p[a], p[b], p[cc], n[a], n[b], n[cc], c[a], c[b], c[cc])
			_tri(st, p[a], p[cc], p[d], n[a], n[cc], n[d], c[a], c[cc], c[d])

static func _frame(axis: Vector3) -> Array[Vector3]:
	var ref := Vector3.UP if absf(axis.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var u := axis.cross(ref).normalized()
	return [u, axis.cross(u).normalized()]

## An open tube from a to b.
func _tube(mat: String, a: Vector3, b: Vector3, r: float, col: Color, segs := 8, inside := false) -> void:
	if a.distance_to(b) < 0.002:
		return
	var axis := (b - a).normalized()
	var f := _frame(axis)
	var p: Array = []
	var n: Array = []
	var c: Array = []
	for end: Vector3 in [a, b]:
		for j in segs:
			var ang := TAU * j / segs
			var radial := f[0] * cos(ang) + f[1] * sin(ang)
			p.append(end + radial * r)
			n.append(-radial if inside else radial)
			c.append(col)
	_grid(_tool(mat, (a + b) * 0.5), p, n, c, 2, segs)

## A short closed cylinder (a flange, a collar, a wheel hub) centred at `at` along `axis`.
func _disc(mat: String, at: Vector3, axis: Vector3, r: float, length: float, col: Color, segs := 10) -> void:
	var a := at - axis * length * 0.5
	var b := at + axis * length * 0.5
	_tube(mat, a, b, r, col, segs)
	var f := _frame(axis)
	var st := _tool(mat, at)
	for end: Array in [[a, -axis], [b, axis]]:
		var o: Vector3 = end[0]
		var nn: Vector3 = end[1]
		for j in segs:
			var a0 := TAU * j / segs
			var a1 := TAU * (j + 1) / segs
			_tri(st, o, o + (f[0] * cos(a0) + f[1] * sin(a0)) * r, o + (f[0] * cos(a1) + f[1] * sin(a1)) * r, nn, nn, nn, col, col, col)

func _ball(mat: String, at: Vector3, r: float, col: Color, segs := 8, rings := 5) -> void:
	var p: Array = []
	var n: Array = []
	var c: Array = []
	for i in rings + 1:
		var lat := PI * i / rings - PI * 0.5
		for j in segs:
			var lon := TAU * j / segs
			var dir := Vector3(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon))
			p.append(at + dir * r)
			n.append(dir)
			c.append(col)
	_grid(_tool(mat, at), p, n, c, rings + 1, segs)

func _box(mat: String, xf: Transform3D, size: Vector3, col: Color) -> void:
	AnnexView.box(_tool(mat, xf.origin), xf, size, Vector3.ZERO, col)

# --- the room sides --------------------------------------------------------------------------------------

## A point on a side from (s along it, y up, d out from its wall line).
static func at_side(side: Dictionary, s: float, y: float, d: float) -> Vector3:
	return (side["origin"] as Vector3) + (side["dir"] as Vector3) * s + Vector3.UP * y + (side["n"] as Vector3) * d

func _sides() -> void:
	var vert: Array = lv.edges[0].vertical
	var hor: Array = lv.edges[0].horizontal
	var lift := lv._lift_edge()
	var W := lv.W
	for r: Dictionary in lv.plan.rooms:
		if int(r.get("level", 0)) != 0:
			continue
		var x := int(r.x)
		var y := int(r.y)
		var w := int(r.w)
		var h := int(r.h)
		var x0 := x * S
		var z0 := y * S
		var x1 := (x + w) * S
		var z1 := (y + h) * S
		var defs := [
			[Vector3(x0, 0, z0), Vector3.RIGHT, Vector3.BACK, w],
			[Vector3(x1, 0, z0), Vector3.BACK, Vector3.LEFT, h],
			[Vector3(x1, 0, z1), Vector3.LEFT, Vector3.FORWARD, w],
			[Vector3(x0, 0, z1), Vector3.FORWARD, Vector3.RIGHT, h],
		]
		for which in 4:
			var df: Array = defs[which]
			var cells: int = df[3]
			var side := {"room": int(r.id), "kind": str(r.kind), "origin": df[0], "dir": df[1], "n": df[2], "len": cells * S,
				"which": which, "openings": [] as Array[Vector4]}
			for i in cells:
				var k := ""
				var inside := Vector2i.ZERO
				var outside := Vector2i.ZERO
				var is_lift := false
				match which:
					0:
						k = hor[y * W + x + i]
						inside = Vector2i(x + i, y)
						outside = Vector2i(x + i, y - 1)
						is_lift = lift == Vector4i(1, x + i, y, 1)
					1:
						k = vert[(y + i) * (W + 1) + x + w]
						inside = Vector2i(x + w - 1, y + i)
						outside = Vector2i(x + w, y + i)
						is_lift = lift == Vector4i(0, x + w, y + i, 1)
					2:
						k = hor[(y + h) * W + x + w - 1 - i]
						inside = Vector2i(x + w - 1 - i, y + h - 1)
						outside = Vector2i(x + w - 1 - i, y + h)
						is_lift = lift == Vector4i(1, x + w - 1 - i, y + h, 1)
					3:
						k = vert[(y + h - 1 - i) * (W + 1) + x]
						inside = Vector2i(x, y + h - 1 - i)
						outside = Vector2i(x - 1, y + h - 1 - i)
						is_lift = lift == Vector4i(0, x, y + h - 1 - i, 1)
				var s := i * S
				var ops: Array[Vector4] = side["openings"]
				if is_lift:
					ops.append(Vector4(s + S * 0.5 - lv.lift_half, s + S * 0.5 + lv.lift_half, 0.0, LIFT_TOP))
				elif k == "door":
					ops.append(Vector4(s + GAP0, s + GAP1, 0.0, DOOR_TOP))
				elif k == "wall" and bool(view.call(&"_glass_edge", 0, inside, outside)):
					ops.append(Vector4(s, s + S, GLASS_LOW, GLASS_TOP))
				elif k != "wall":
					ops.append(Vector4(s, s + S, 0.0, LH))
			side["openings"] = _merged(side["openings"])
			sides.append(side)

## Openings that meet end to end at the same heights (a run of wired glass) as one.
static func _merged(ops: Array[Vector4]) -> Array[Vector4]:
	var out: Array[Vector4] = []
	for o in ops:
		if not out.is_empty() and absf(out[-1].y - o.x) < 0.001 and out[-1].z == o.z and out[-1].w == o.w:
			out[-1] = Vector4(out[-1].x, o.y, o.z, o.w)
		else:
			out.append(o)
	return out

## The parts of [lo, hi] along a side that no opening crossing heights [y0, y1] touches (with `pad` either side).
static func free_spans(side: Dictionary, lo: float, hi: float, y0: float, y1: float, pad: float) -> Array[Vector2]:
	var out: Array[Vector2] = [Vector2(lo, hi)]
	var cut: Array[Vector4] = side["openings"].duplicate()
	for o: Vector4 in side.get("blocks", []):
		cut.append(o)
	for o: Vector4 in cut:
		if o.w < y0 or o.z > y1:
			continue
		var a := o.x - pad
		var b := o.y + pad
		var next: Array[Vector2] = []
		for sp: Vector2 in out:
			if b <= sp.x or a >= sp.y:
				next.append(sp)
				continue
			if a > sp.x:
				next.append(Vector2(sp.x, a))
			if b < sp.y:
				next.append(Vector2(b, sp.y))
		out = next
	return out

## Blocks of a side that are not openings but must stay clear: the rotor's box, and the landing for low runs.
func _block_rotor() -> void:
	if rotor_node == null:
		return
	var box: AABB = rotor_node.get_meta(&"bounds")
	for side in sides:
		var blocks: Array[Vector4] = []
		var o: Vector3 = side["origin"]
		var dirv: Vector3 = side["dir"]
		var nv: Vector3 = side["n"]
		var smin := INF
		var smax := -INF
		var dmin := INF
		for cx: float in [box.position.x, box.end.x]:
			for cz: float in [box.position.z, box.end.z]:
				var p := Vector3(cx, 0, cz) - o
				smin = minf(smin, p.dot(dirv))
				smax = maxf(smax, p.dot(dirv))
				dmin = minf(dmin, p.dot(nv))
		if dmin < 0.8 and smax > 0.0 and smin < float(side["len"]):
			blocks.append(Vector4(smin, smax, 0.0, LH))
		side["blocks"] = blocks

# --- the runs ------------------------------------------------------------------------------------------------

## Lays one run round every room it runs in: polylines of world points, ends that meet an opening turned into
## the wall. Records the straight pieces in `segments`. Returns [[points, ends_into_wall: [bool, bool]], ...].
func _lay(run: Dictionary) -> Array:
	var out: Array = []
	var h: float = run["h"]
	var ro: float = maxf(float(run["r"]), float(run["lag"]))
	var d := WALL_HALF + 0.035 + ro
	var landing := _rect(anchors.get("landing"))
	var by_room := {}
	for i in sides.size():
		var side := sides[i]
		if not (run["rooms"] as Array).has(side["kind"]):
			continue
		if not by_room.has(side["room"]):
			by_room[side["room"]] = []
		by_room[side["room"]].append(i)
	for room: int in by_room:
		var ids: Array = by_room[room]
		var longest := 0.0
		for i: int in ids:
			longest = maxf(longest, float(sides[i]["len"]))
		# The free spans of each side, in order round the room.
		var spans: Array = []
		for i: int in ids:
			var side := sides[i]
			var length: float = side["len"]
			var sp: Array[Vector2] = []
			if not (bool(run.get("long_only", false)) and length < longest - 0.01):
				sp = free_spans(side, d, length - d, h - ro - 0.03, h + ro + 0.03, ro + 0.12)
			if bool(run.get("no_landing", false)) and landing.has_area():
				var cut: Array[Vector2] = []
				for v: Vector2 in sp:
					var a := at_side(side, v.x, 0, d)
					var b := at_side(side, v.y, 0, d)
					var lo := v.x
					var hi := v.y
					var za := landing.position.y - 0.3
					if absf((side["dir"] as Vector3).z) > 0.5:
						# Keep only the part north of the landing.
						var sa := a.z < za
						var sb := b.z < za
						if not sa and not sb:
							continue
						var s_at := lo + (za - a.z) / (b.z - a.z) * (hi - lo)
						if not sa:
							lo = s_at
						if not sb:
							hi = s_at
					elif a.z > za:
						continue
					if hi - lo > 0.6:
						cut.append(Vector2(lo, hi))
				sp = cut
			var kept: Array[Vector2] = []
			for v: Vector2 in sp:
				if v.y - v.x >= 0.6:
					kept.append(v)
			spans.append(kept)
		# Chain spans that meet at a corner into one polyline.
		var n := ids.size()
		var pieces: Array = []   # [side index, Vector2 span]
		for k in n:
			for v: Vector2 in spans[k]:
				pieces.append([k, v])
		var used := {}
		var full_loop := true
		for k in n:
			var length: float = sides[ids[k]]["len"]
			var sp: Array = spans[k]
			full_loop = full_loop and sp.size() == 1 and absf((sp[0] as Vector2).x - d) < 0.001 and absf((sp[0] as Vector2).y - (length - d)) < 0.001
		for pi in pieces.size():
			if used.has(pi):
				continue
			# Walk back to the start of this chain (unless the room is one closed loop).
			var start := pi
			if not full_loop:
				var guard := 0
				while guard < pieces.size():
					guard += 1
					var prev := _prev_piece(pieces, start, spans, ids, d)
					if prev < 0 or prev == pi:
						break
					start = prev
			var chain: Array = []
			var cur := start
			while cur >= 0 and not used.has(cur):
				used[cur] = true
				chain.append(pieces[cur])
				cur = _next_piece(pieces, cur, spans, ids, d)
			var pts: Array[Vector3] = []
			for c: Array in chain:
				var side := sides[ids[c[0]]]
				var v: Vector2 = c[1]
				var a := at_side(side, v.x, h, d)
				var b := at_side(side, v.y, h, d)
				if pts.is_empty() or pts[-1].distance_to(a) > 0.001:
					pts.append(a)
				pts.append(b)
				segments.append({"side": ids[c[0]], "run": run["name"], "s0": v.x, "s1": v.y, "h": h, "d": d, "ro": ro})
			var closed := full_loop and chain.size() == pieces.size()
			if closed:
				pts.append(pts[0])
			out.append([pts, [not closed, not closed], chain.map(func(c: Array) -> int: return ids[c[0]])])
	return out

func _next_piece(pieces: Array, cur: int, spans: Array, ids: Array, d: float) -> int:
	var k: int = pieces[cur][0]
	var v: Vector2 = pieces[cur][1]
	var length: float = sides[ids[k]]["len"]
	if absf(v.y - (length - d)) > 0.001:
		return -1
	var k2 := (k + 1) % ids.size()
	for i in pieces.size():
		if int(pieces[i][0]) == k2 and absf((pieces[i][1] as Vector2).x - d) < 0.001:
			return i
	return -1

func _prev_piece(pieces: Array, cur: int, spans: Array, ids: Array, d: float) -> int:
	var k: int = pieces[cur][0]
	var v: Vector2 = pieces[cur][1]
	if absf(v.x - d) > 0.001:
		return -1
	var k2 := (k - 1 + ids.size()) % ids.size()
	var length: float = sides[ids[k2]]["len"]
	for i in pieces.size():
		if int(pieces[i][0]) == k2 and absf((pieces[i][1] as Vector2).y - (length - d)) < 0.001:
			return i
	return -1

## The crawl's own cable trays as places a split-tray growth can root (client/station_view.gd draws the trays).
func _crawl_trays() -> void:
	for i in sides.size():
		var side := sides[i]
		if side["kind"] != "crawl" or float(side["len"]) < 2.0 * S - 0.01:
			continue
		# A narrow ladder tray on the crawl's wall between its openings, the split-tray growths' root.
		for v: Vector2 in free_spans(side, 0.3, float(side["len"]) - 0.3, 0.9, 1.1, 0.15):
			if v.y - v.x < 0.8:
				continue
			segments.append({"side": i, "run": "crawltray", "s0": v.x, "s1": v.y, "h": 1.0, "d": 0.2, "ro": 0.03})
			_tray(at_side(side, v.x, 1.0, 0.2), at_side(side, v.y, 1.0, 0.2), side, 0.17)

## Draws one laid run: tubes, elbows at corners, flanged elbows into the wall at its ends, brackets or hangers,
## flanges, valves; lagging with straps (broken open at a cracked-lagging growth); a tray as a ladder with cables.
func _draw_run(run: Dictionary, lines: Array) -> void:
	var mat: String = run["mat"]
	var r: float = run["r"]
	var lag: float = run["lag"]
	var h: float = run["h"]
	for line: Array in lines:
		var pts: Array[Vector3] = line[0]
		var ends: Array = line[1]
		var side_ids: Array = line[2]
		var first_side := sides[side_ids[0]]
		var last_side := sides[side_ids[-1]]
		if mat == "tray":
			for i in range(1, pts.size()):
				_tray(pts[i - 1], pts[i], sides[side_ids[mini(i - 1, side_ids.size() - 1)]])
			counts["tray"] = int(counts.get("tray", 0)) + 1
			continue
		var tube_mat := "paint" if mat == "paint" else "steel"
		var col := C_PAINT if mat == "paint" else C_STEEL.lerp(C_RUST, 0.25)
		for i in range(1, pts.size()):
			var a := pts[i - 1]
			var b := pts[i]
			if lag > 0.0:
				_lagged(a, b, r, lag, col)
			else:
				_tube(tube_mat, a, b, r, col)
				_fittings(run, a, b, r, tube_mat, col)
			if i > 1 or (not ends[0] and pts.size() > 2):
				_ball(tube_mat if lag <= 0.0 else "concrete", a, (lag if lag > 0.0 else r) * 1.12, col if lag <= 0.0 else C_LAG)
		for e in 2:
			if not ends[e]:
				continue
			var p: Vector3 = pts[0] if e == 0 else pts[-1]
			var side := first_side if e == 0 else last_side
			var nv: Vector3 = side["n"]
			var wall := p - nv * ((p - (side["origin"] as Vector3)).dot(nv) - WALL_HALF + 0.03)
			_tube(tube_mat, p, wall, r, col)
			_ball(tube_mat, p, r * 1.1, col)
			_disc(tube_mat, wall + nv * 0.045, nv, r * 1.75, 0.03, col.darkened(0.2), 12)
		counts["run"] = int(counts.get("run", 0)) + 1

## Hangers or wall brackets every 1.6 m, flanges every few metres, a valve now and then on the steam line.
func _fittings(run: Dictionary, a: Vector3, b: Vector3, r: float, mat: String, col: Color) -> void:
	var length := a.distance_to(b)
	var axis := (b - a).normalized()
	var nv := _wall_normal(a, b)
	var high := float(run["h"]) > 2.7
	var k := 0.5
	while k < length - 0.3:
		var p := a + axis * k
		if high:
			_box("steel", Transform3D(Basis(axis, Vector3.UP, axis.cross(Vector3.UP)).orthonormalized(), Vector3(p.x, (p.y + r + LH) * 0.5, p.z)), Vector3(0.02, LH - p.y - r, 0.02), C_DARK)
			_disc("steel", p, axis, r * 1.15, 0.035, C_DARK, 10)
		else:
			var wall_d := (p - _line_point(p, nv)).dot(nv)
			var mid := p - nv * (wall_d - WALL_HALF) * 0.5 - Vector3.UP * (r + 0.02)
			_box("steel", Transform3D(Basis(axis, Vector3.UP, nv), mid), Vector3(0.045, 0.03, wall_d - WALL_HALF), C_DARK)
			_box("steel", Transform3D(Basis(axis, Vector3.UP, nv), p - nv * (wall_d - WALL_HALF - 0.006) - Vector3.UP * (r * 0.5)), Vector3(0.07, 0.18, 0.012), C_DARK)
			_disc("steel", p, axis, r * 1.12, 0.03, C_DARK, 10)
		k += 1.6
	var f := 1.1 + _rng.randf() * 1.5
	while f < length - 0.5:
		_disc(mat, a + axis * f, axis, r * 1.5, 0.045, col.darkened(0.12), 12)
		f += 2.8 + _rng.randf() * 1.6
	if run["name"] == "steam" and length > 3.0 and _rng.randf() < 0.55:
		var p := a + axis * _rng.randf_range(1.0, length - 1.0)
		_ball("steel", p, r * 1.7, C_STEEL.darkened(0.25), 8, 5)
		var stem_end := p + nv * (r + 0.16)
		_tube("steel", p, stem_end, 0.012, C_DARK, 5)
		for j in 10:
			var f2 := _frame(nv)
			var a0 := TAU * j / 10.0
			var a1 := TAU * (j + 1) / 10.0
			var q0 := stem_end + (f2[0] * cos(a0) + f2[1] * sin(a0)) * 0.11
			var q1 := stem_end + (f2[0] * cos(a1) + f2[1] * sin(a1)) * 0.11
			_tube("steel", q0, q1, 0.012, C_VALVE, 5)
		_tube("steel", stem_end - (_frame(nv)[0]) * 0.11, stem_end + (_frame(nv)[0]) * 0.11, 0.008, C_VALVE, 4)
		counts["valve"] = int(counts.get("valve", 0)) + 1

## The normal into the room of the side a run piece lies along.
func _wall_normal(a: Vector3, b: Vector3) -> Vector3:
	var best := Vector3.BACK
	var bd := INF
	var mid := (a + b) * 0.5
	var axis := (b - a).normalized()
	for side in sides:
		if absf((side["dir"] as Vector3).dot(axis)) < 0.99:
			continue
		var d := (mid - (side["origin"] as Vector3)).dot(side["n"])
		var s := (mid - (side["origin"] as Vector3)).dot(side["dir"])
		if d > 0.0 and d < bd and s > -0.2 and s < float(side["len"]) + 0.2:
			bd = d
			best = side["n"]
	return best

func _line_point(p: Vector3, nv: Vector3) -> Vector3:
	for side in sides:
		if (side["n"] as Vector3).is_equal_approx(nv):
			var d := (p - (side["origin"] as Vector3)).dot(nv)
			var s := (p - (side["origin"] as Vector3)).dot(side["dir"])
			if d > 0.0 and d < 0.6 and s > -0.2 and s < float(side["len"]) + 0.2:
				return p - nv * d
	return p - nv * 0.2

## Lagged pipe: cream lagging with steel straps; broken open (the bare pipe showing) round a cracked-lagging root.
func _lagged(a: Vector3, b: Vector3, r: float, lag: float, col: Color) -> void:
	var axis := (b - a).normalized()
	var length := a.distance_to(b)
	var cuts: Array[Vector2] = []
	for c: Dictionary in clusters:
		if c["kind"] != "cracked_insulation":
			continue
		var root: Vector3 = c["at"]
		var t := (root - a).dot(axis)
		if t > -0.3 and t < length + 0.3 and (a + axis * t).distance_to(root) < 0.05:
			cuts.append(Vector2(t - 0.22 * float(c["scale"]), t + 0.22 * float(c["scale"])))
	var at := 0.0
	cuts.sort_custom(func(p: Vector2, q: Vector2) -> bool: return p.x < q.x)
	var pieces: Array[Vector2] = []
	for c: Vector2 in cuts:
		if c.x > at:
			pieces.append(Vector2(at, c.x))
		at = maxf(at, c.y)
	if at < length:
		pieces.append(Vector2(at, length))
	_tube("steel", a, b, r, C_STEEL.lerp(C_RUST, 0.6), 6)
	for p: Vector2 in pieces:
		var pa := a + axis * clampf(p.x, 0.0, length)
		var pb := a + axis * clampf(p.y, 0.0, length)
		_tube("concrete", pa, pb, lag, C_LAG, 9)
		var k := p.x + 0.45
		while k < p.y - 0.1:
			_tube("steel", a + axis * k, a + axis * (k + 0.025), lag + 0.006, C_STEEL.darkened(0.3), 9)
			k += 0.9
		# Ragged ends where the lagging is broken.
		for end: Vector3 in [pa, pb]:
			if end.distance_to(a) > 0.01 and end.distance_to(b) > 0.01:
				_disc("concrete", end, axis, lag * 0.97, 0.02, C_LAG.darkened(0.35), 9)

## A ladder cable tray from a to b along its wall: two rails, rungs, three cables.
func _tray(a: Vector3, b: Vector3, side: Dictionary, width := 0.33) -> void:
	var nv: Vector3 = side["n"]
	var axis := (b - a).normalized()
	var length := a.distance_to(b)
	var wall_d := (a - (side["origin"] as Vector3)).dot(nv)
	var inner := a - nv * (wall_d - WALL_HALF - 0.03)
	var outer := a - nv * (wall_d - WALL_HALF - 0.03 - width)
	var basis := Basis(axis, Vector3.UP, axis.cross(Vector3.UP)).orthonormalized()
	for rail: Vector3 in [inner, outer]:
		_box("steel", Transform3D(basis, rail + axis * length * 0.5), Vector3(length, 0.07, 0.015), C_STEEL.darkened(0.15))
	var k := 0.15
	while k < length:
		_box("steel", Transform3D(basis, (inner + outer) * 0.5 + axis * k - Vector3.UP * 0.03), Vector3(0.03, 0.012, width), C_STEEL.darkened(0.25))
		k += 0.3
	for c in 3:
		var off := inner.lerp(outer, 0.25 + c * 0.25) - Vector3.UP * (0.005 - c * 0.004)
		_tube("steel", off, off + axis * length, 0.022, Color(0.12, 0.12, 0.13), 6)

# --- growths ----------------------------------------------------------------------------------------------

## The spans along a side where a growth can spill down from height `h` without reaching an opening.
func _spill_spans(si: int, s0: float, s1: float, h: float) -> Array[Vector2]:
	var side := sides[si]
	var out: Array[Vector2] = []
	var cut := side.duplicate()
	var ops: Array[Vector4] = (side["openings"] as Array[Vector4]).duplicate()
	# Keep growths off the amber lamps on this wall.
	for l: Vector3 in _lamps:
		var rel := l - (side["origin"] as Vector3)
		var d := rel.dot(side["n"])
		if d > -0.1 and d < 0.6:
			var s := rel.dot(side["dir"])
			ops.append(Vector4(s - 0.55, s + 0.55, 0.0, LH))
	cut["openings"] = ops
	for v: Vector2 in free_spans(cut, maxf(s0, WALL_HALF + 0.12), minf(s1, float(side["len"]) - WALL_HALF - 0.12), 0.2, h + 0.5, 0.12):
		if v.y - v.x >= 0.7:
			out.append(v)
	return out

## Where a cluster can root: {side, s, h, d, ro, half, spill} nearest `want` on a run named in `runs` (each later
## name counts 0.5 m farther), in `room` (or anywhere when room < 0), leaving `half` of wall either side. On the
## main under the ceiling it may also sit over a doorway or the wired glass, then without a spill down the wall
## (counted 0.75 m farther). {} when there is none.
func _root_near(want: Vector3, runs: Array, room: int, hw: float) -> Dictionary:
	var best := {}
	var bd := INF
	for rank in runs.size():
		var run_name: String = runs[rank]
		for seg: Dictionary in segments:
			if seg["run"] != run_name:
				continue
			var si: int = seg["side"]
			if room >= 0 and int(sides[si]["room"]) != room:
				continue
			var pieces: Array = []
			for v: Vector2 in _spill_spans(si, seg["s0"], seg["s1"], seg["h"]):
				pieces.append([v, true])
			if run_name == "high":
				for v: Vector2 in free_spans(sides[si], maxf(seg["s0"], WALL_HALF + 0.12), minf(seg["s1"], float(sides[si]["len"]) - WALL_HALF - 0.12), GLASS_TOP + 0.02, LH, 0.12):
					if v.y - v.x >= 0.7:
						pieces.append([v, false])
			for pc: Array in pieces:
				var v: Vector2 = pc[0]
				var half := minf(hw, (v.y - v.x) * 0.5 - 0.02)
				var s := clampf((want - (sides[si]["origin"] as Vector3)).dot(sides[si]["dir"]), v.x + half, v.y - half)
				var p := at_side(sides[si], s, seg["h"], seg["d"])
				var dist := Vector2(p.x - want.x, p.z - want.z).length() + 0.5 * rank + (0.0 if pc[1] else 0.75)
				if dist < bd:
					bd = dist
					best = {"side": si, "s": s, "h": seg["h"], "d": seg["d"], "ro": seg["ro"], "half": half, "spill": pc[1]}
	return best
## The room an anchor lies in (by its cell), or -1.
func _room_at(p: Vector3) -> int:
	var cx := floori(p.x / S)
	var cz := floori(p.z / S)
	if cx < 0 or cz < 0 or cx >= lv.W or cz >= lv.H:
		return -1
	return int(lv.room_at[0][cz * lv.W + cx])

## How near the rotor end of the hall a point is: 1 at the rotor, 0 at the landing.
func _closeness(p: Vector3) -> float:
	var hall := _rect(anchors.get("hall"))
	var rot := Point.v3(anchors.get("rotor"))
	if not hall.has_area() or rot == Vector3.INF:
		return 0.5
	return clampf(1.0 - absf(p.z - rot.z) / maxf(hall.size.y, 1.0), 0.0, 1.0)

func _growths() -> void:
	# One cluster per seeded anchor.
	var i := 0
	for g: Variant in anchors.get("growths", []):
		var at := Point.v3(g)
		if at == Vector3.INF:
			continue
		var kind := str((g as Dictionary).get("kind", "pipe_collar")) if g is Dictionary else "pipe_collar"
		if not ROOTS.has(kind):
			kind = "pipe_collar"
		var rng := RandomNumberGenerator.new()
		rng.seed = hash("%s:%d:growth:%d" % [lv.plan.get("seed", ""), int(lv.plan.get("depth", 0)), i])
		var scale := 0.6 if kind == "split_cable_tray" else lerpf(1.1, 1.7, _closeness(at))
		var root := _root_near(at, ROOTS[kind], _room_at(at), 0.5 * scale)
		if root.is_empty():
			root = _root_near(at, ROOTS[kind] + ["steam", "high"], -1, 0.5 * scale)
		if not root.is_empty():
			_cluster(root, kind, minf(scale, float(root["half"]) / 0.5 + 0.2), rng, at)
		i += 1
	# More near the rotor: the hall's runs, weighted toward the rotor end.
	var hall_room := _room_at(_rect(anchors.get("hall")).get_center().x * Vector3.RIGHT + _rect(anchors.get("hall")).get_center().y * Vector3.BACK)
	var extra := 8 + _rng.randi_range(0, 3)
	var tries := 0
	while extra > 0 and tries < 60:
		tries += 1
		var rot := Point.v3(anchors.get("rotor"))
		var hall := _rect(anchors.get("hall"))
		if rot == Vector3.INF or not hall.has_area():
			break
		var want := Vector3(_rng.randf_range(hall.position.x, hall.end.x), 0.0, rot.z + absf(_rng.randfn(0.0, hall.size.y * 0.25)))
		var root := _root_near(want, ["steam", "high"] if _rng.randf() < 0.6 else ["high", "steam"], hall_room, 0.55)
		if root.is_empty():
			continue
		var p := at_side(sides[root["side"]], root["s"], root["h"], root["d"])
		var clear := true
		for c: Dictionary in clusters:
			clear = clear and (c["at"] as Vector3).distance_to(p) > 1.6
		if not clear:
			continue
		var rng := RandomNumberGenerator.new()
		rng.seed = hash("%s:%d:growth-extra:%d" % [lv.plan.get("seed", ""), int(lv.plan.get("depth", 0)), extra])
		var scale := lerpf(1.0, 1.7, _closeness(p))
		_cluster(root, "spread", minf(scale, float(root["half"]) / 0.5 + 0.2), rng, Vector3.INF)
		extra -= 1

## One cluster. On the steam line and the main (a pipe collar, or one of the spread near the rotor) the hero piece
## sits in the line: the Meshy growth round a flanged spool (growth_c.glb), scaled, turned and tinted from the seed,
## its flanges bolted to the run's own. Round it, or on its own elsewhere: swollen lobes round the pipe (a split
## collar under them), a spill of flattened lobes down the wall, a few creeping up to the ceiling, strands slung
## between and drips hanging from the mass.
func _cluster(root: Dictionary, kind: String, scale: float, rng: RandomNumberGenerator, anchor: Vector3) -> void:
	var si: int = root["side"]
	var side := sides[si]
	var s0: float = root["s"]
	var h: float = root["h"]
	var dp: float = root["d"]
	var ro: float = root["ro"]
	var half: float = root["half"]
	var hero := false
	var spill_ok: bool = root.get("spill", true)
	if spill_ok and (kind == "pipe_collar" or kind == "spread") and hero_count < HERO_MAX and half >= 0.55 and hero_mesh() != null:
		# One to three overlapping along the run, each its own size, roll, mirror and tint from the seed.
		var copies := rng.randi_range(1, 3)
		for k in copies:
			if hero_count >= HERO_MAX:
				break
			var off := 0.0 if k == 0 else clampf(rng.randf_range(-0.55, 0.55) * scale, -half + 0.35, half - 0.35)
			var size := rng.randf_range(0.8, 1.6) if k > 0 else rng.randf_range(1.3, 2.0)
			if absf(off) + 0.5 * ro / GROWTH_PIPE_R * size > half + 0.3:
				continue
			hero = _hero(si, s0 + off, h, dp, ro, rng, size) or hero
	var lobes: Array = []   # [centre (s, y, d), radii (s, y, d), tone, depth]
	var crown := int(round(rng.randi_range(6, 10) * scale * (0.5 if hero else 1.0)))
	for i in crown:
		var r := rng.randf_range(0.1, 0.26) * scale * (0.7 if hero else 1.0)
		var spread := (0.42 if hero else 0.24) * scale
		var c := Vector3(s0 + clampf(rng.randfn(0.0, spread), -half, half), h + rng.randf_range(-0.12, 0.16) * scale, dp + rng.randf_range(-0.03, 0.1))
		lobes.append([c, Vector3(r * rng.randf_range(1.0, 1.5), r * rng.randf_range(0.8, 1.15), r * 0.9), rng.randf(), 0.15])
	# The spill down the wall.
	var cs := Vector3(s0, h - ro, 0.0)
	var rr := 0.2 * scale
	var spill := int(round(rng.randi_range(5, 8) * scale)) if spill_ok else 0
	for i in spill:
		cs.x = clampf(cs.x + rng.randfn(0.0, 0.12 * scale), s0 - half, s0 + half)
		cs.y -= rng.randf_range(0.12, 0.24) * scale
		rr *= rng.randf_range(0.82, 0.96)
		if cs.y < 0.35:
			break
		lobes.append([Vector3(cs.x, cs.y, WALL_HALF + rr * 0.3), Vector3(rr * 1.3, rr * 1.5, rr * 0.55), rng.randf() * 0.6, 0.35])
		if rng.randf() < 0.6:
			var bud := rr * rng.randf_range(0.45, 0.75)
			var bs := clampf(cs.x + rng.randf_range(-0.25, 0.25) * scale, s0 - half, s0 + half)
			lobes.append([Vector3(bs, cs.y + rng.randf_range(-0.08, 0.08), WALL_HALF + bud * 0.3), Vector3(bud, bud * 1.2, bud * 0.6), rng.randf(), 0.3])
	# Creeping up toward the ceiling.
	for i in rng.randi_range(1, 3):
		var r := rng.randf_range(0.06, 0.13) * scale
		var c := Vector3(s0 + clampf(rng.randfn(0.0, 0.3 * scale), -half, half), minf(h + ro + rng.randf_range(0.08, 0.35), LH - 0.06), WALL_HALF + r * 0.3)
		lobes.append([c, Vector3(r * 1.3, r * 1.1, r * 0.6), rng.randf(), 0.2])
	for l: Array in lobes:
		_lobe(si, l, rng)
	# Strands between lobes, sagging, and drips hanging from the mass.
	for i in int(round(rng.randi_range(2, 4) * scale)):
		var a: Array = lobes[rng.randi_range(0, lobes.size() - 1)]
		var b: Array = lobes[rng.randi_range(0, lobes.size() - 1)]
		if a == b:
			continue
		_strand(si, a[0], b[0], rng.randf_range(0.05, 0.25), rng.randf_range(0.008, 0.016))
	for i in int(round(rng.randi_range(3, 6) * scale)) if spill_ok else 0:
		var top := Vector3(s0 + clampf(rng.randfn(0.0, 0.25 * scale), -half, half), h - ro * 0.6, dp + rng.randf_range(-0.04, 0.04))
		_drip(si, top, rng.randf_range(0.25, 0.85) * scale, rng.randf_range(0.012, 0.03), rng)
	# What the lobes burst from: a split collar on the steam line, a torn ring of lagging.
	var root_w := at_side(side, s0, h, dp)
	var axis: Vector3 = side["dir"]
	if kind == "pipe_collar" and not hero:
		_disc("steel", root_w, axis, ro * 1.6, 0.16, C_STEEL.lerp(C_RUST, 0.7), 10)
	var where := {"kind": kind, "side": si, "s": s0, "h": h, "at": root_w, "anchor": anchor, "scale": scale, "hero": hero}
	clusters.append(where)
	counts["growth"] = int(counts.get("growth", 0)) + 1

## A drip: a thin tapered strand hanging from the mass, wavering, kept against the wall.
func _drip(si: int, top: Vector3, length: float, r: float, rng: RandomNumberGenerator) -> void:
	var side := sides[si]
	var steps := 5
	var prev := Vector3.INF
	for i in steps + 1:
		var t := float(i) / steps
		var q := top + Vector3(rng.randf_range(-0.03, 0.03), -length * t, -t * 0.06)
		q.z = maxf(q.z, WALL_HALF + 0.03)
		var w := keep_clear(side, q, top.x)
		var p := at_side(side, w.x, w.y, w.z)
		if prev != Vector3.INF:
			_tube("growth", prev, p, r * (1.0 - t * 0.6), Color(0.35, 0.5, 0.0), 5)
		prev = p
	_ball("growth", prev, r * 0.7, Color(0.4, 0.6, 0.0), 5, 3)

## The Meshy growth (godot/assets/reactor/growth_c.glb, the pipe along +X, 1 m long, centred on its axis), or null.
static func hero_mesh() -> ArrayMesh:
	if _hero_cache.is_empty():
		_hero_cache["mesh"] = null
		if ResourceLoader.exists(HERO_GLB):
			var scene: Node = (load(HERO_GLB) as PackedScene).instantiate()
			var found := _first_mesh(scene)
			if found != null:
				_hero_cache["mesh"] = found.mesh
				_hero_cache["xf"] = _global_xf(found, scene)
				var m: Material = found.get_active_material(0)
				_hero_cache["tex"] = (m as BaseMaterial3D).albedo_texture if m is BaseMaterial3D else null
			scene.free()
	return _hero_cache["mesh"]

static func _first_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var f := _first_mesh(c)
		if f != null:
			return f
	return null

static func _global_xf(n: Node, top: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var cur := n
	while cur != null and cur != top:
		if cur is Node3D:
			xf = (cur as Node3D).transform * xf
		cur = cur.get_parent()
	return xf

## Puts one hero piece in the run at s0 (its pipe on the run's axis), each vertex kept clear like the lobes,
## flanges on the run either side. Returns whether it was drawn.
func _hero(si: int, s0: float, h: float, dp: float, ro: float, rng: RandomNumberGenerator, size: float) -> bool:
	var side := sides[si]
	var src := hero_mesh()
	var base_xf: Transform3D = _hero_cache["xf"]
	# The spool's pipe a little fatter than the run's (it is swollen), its flanges over the run's own.
	var scale := ro / GROWTH_PIPE_R * size
	var flip := -1.0 if rng.randf() < 0.5 else 1.0
	var roll := rng.randf_range(-0.25, 0.25)
	var dirv: Vector3 = side["dir"]
	var nv: Vector3 = side["n"]
	var mesh := ArrayMesh.new()
	for surf in src.get_surface_count():
		var arr := src.surface_get_arrays(surf)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		var out_v := PackedVector3Array()
		var out_n := PackedVector3Array()
		out_v.resize(verts.size())
		out_n.resize(verts.size())
		for i in verts.size():
			var m := base_xf * verts[i]
			# Model: x along the pipe, y up, z across. Roll about the pipe, then into the side's frame.
			var y := m.y * cos(roll) - m.z * sin(roll)
			var z := m.y * sin(roll) + m.z * cos(roll)
			var local := Vector3(s0 + m.x * flip * scale, h + y * scale, dp + z * scale)
			if local.z < dp - ro:
				local.z = dp - ro + (local.z - dp + ro) * 0.35
			var w := keep_clear(side, local, s0)
			out_v[i] = at_side(side, w.x, w.y, w.z)
			var nm := base_xf.basis * (norms[i] if i < norms.size() else Vector3.UP)
			var ny := nm.y * cos(roll) - nm.z * sin(roll)
			var nz := nm.y * sin(roll) + nm.z * cos(roll)
			out_n[i] = (dirv * nm.x * flip + Vector3.UP * ny + nv * nz).normalized()
		arr[Mesh.ARRAY_VERTEX] = out_v
		arr[Mesh.ARRAY_NORMAL] = out_n
		arr[Mesh.ARRAY_TANGENT] = null
		if flip < 0.0 and arr[Mesh.ARRAY_INDEX] != null:
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			for k in range(0, idx.size(), 3):
				var tmp := idx[k + 1]
				idx[k + 1] = idx[k + 2]
				idx[k + 2] = tmp
			arr[Mesh.ARRAY_INDEX] = idx
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mi := MeshInstance3D.new()
	mi.name = "Growth_%d" % hero_count
	mi.mesh = mesh
	var mat := ShaderMaterial.new()
	mat.shader = Level._shader("res://client/station_growth.gdshader")
	mat.set_shader_parameter("tex", _hero_cache.get("tex"))
	mat.set_shader_parameter("use_tex", 1.0)
	mat.set_shader_parameter("self_glow", 0.35)
	growth_mats.append(mat)
	var tints: Array[Color] = [Color(1.3, 1.15, 1.15), Color(1.15, 1.02, 1.3), Color(1.4, 1.12, 1.0)]
	mat.set_shader_parameter("tint", tints[rng.randi_range(0, tints.size() - 1)])
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	# The run's flanges either side of the spool.
	for e: float in [-0.5, 0.5]:
		var p := at_side(side, s0 + e * scale * 0.97, h, dp)
		_disc("steel", p, dirv, ro * 1.75, 0.04, C_STEEL.lerp(C_RUST, 0.6), 12)
	hero_count += 1
	counts["hero"] = hero_count
	return true

## Pulls a point given in a side's frame (s, y, d) inside what is allowed: within the side, below the ceiling,
## out of the wall behind, within BAND of the wall below CLEAR_H (a little farther as it rises), and out of every
## opening (pushed to the side of it that `pref`, the lobe's own centre, is on).
static func keep_clear(side: Dictionary, p: Vector3, pref: float) -> Vector3:
	var length: float = side["len"]
	var s := clampf(p.x, WALL_HALF + 0.04, length - WALL_HALF - 0.04)
	var y := clampf(p.y, 0.04, LH - 0.03)
	var d := maxf(p.z, WALL_HALF * 0.5)
	var lim := BAND if y < CLEAR_H + 0.35 else minf(BAND + (y - CLEAR_H - 0.35) * 1.4, 0.8)
	var knee := lim * 0.7
	if d > knee:
		d = knee + (lim - knee) * (1.0 - exp(-(d - knee) / (lim - knee)))
	var ops: Array[Vector4] = side["openings"]
	for o: Vector4 in ops:
		var glass := o.z > 0.5 and o.w < LH - 0.1 and pref > o.x and pref < o.y
		var reach := 0.35 if glass else 0.08
		if y > o.z - 0.08 and y < o.w + 0.08 and s > o.x - reach and s < o.y + reach:
			if glass:
				y = o.w + 0.08   # over the wired glass: kept above its head
			else:
				s = o.x - 0.08 if pref < (o.x + o.y) * 0.5 else o.y + 0.08
	return Vector3(s, y, d)

## One lobe: a displaced ellipsoid in the side's frame, flattened where it meets the wall.
func _lobe(si: int, l: Array, rng: RandomNumberGenerator) -> void:
	var side := sides[si]
	var c: Vector3 = l[0]
	var rad: Vector3 = l[1]
	var tone: float = l[2]
	var depth: float = l[3]
	var rings := 5
	var segs := 8
	var p: Array = []
	var n: Array = []
	var col: Array = []
	var dirv: Vector3 = side["dir"]
	var nv: Vector3 = side["n"]
	var off := Vector3(rng.randf() * 50.0, rng.randf() * 50.0, rng.randf() * 50.0)
	for i in rings + 1:
		var lat := PI * i / rings - PI * 0.5
		for j in segs:
			var lon := TAU * j / segs
			# Local: x along the wall, y up, z out of the wall.
			var u := Vector3(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon))
			var bump := 1.0 + 0.3 * _noise.get_noise_3dv(u * 1.7 + off) + 0.12 * _noise.get_noise_3dv(u * 4.3 + off * 1.3)
			var q := Vector3(u.x * rad.x, u.y * rad.y, u.z * rad.z) * bump
			if q.z < 0.0:
				q.z *= 0.35
			var w := keep_clear(side, c + q, c.x)
			p.append(at_side(side, w.x, w.y, w.z))
			var nl := Vector3(u.x / rad.x, u.y / rad.y, u.z / rad.z).normalized()
			n.append((dirv * nl.x + Vector3.UP * nl.y + nv * nl.z).normalized())
			var under := clampf(-u.y * 0.5 + 0.5 - u.z * 0.3, 0.0, 1.0)
			col.append(Color(tone, clampf(depth + under * 0.45, 0.0, 1.0), 0.0))
	_grid(_tool("growth", at_side(side, c.x, c.y, c.z)), p, n, col, rings + 1, segs)

## A thin sagging strand between two lobe centres.
func _strand(si: int, a: Vector3, b: Vector3, sag: float, r: float) -> void:
	var side := sides[si]
	var steps := 6
	var pts: Array[Vector3] = []
	for i in steps + 1:
		var t := float(i) / steps
		var q := a.lerp(b, t)
		q.y -= sag * 4.0 * t * (1.0 - t)
		q.z = maxf(q.z, WALL_HALF + 0.02)
		var w := keep_clear(side, q, (a.x + b.x) * 0.5)
		pts.append(at_side(side, w.x, w.y, w.z))
	for i in steps:
		_tube("growth", pts[i], pts[i + 1], r, Color(0.5, 0.6, 0.0), 4)

# --- frames, kerbs, beams, trays, marks, signs --------------------------------------------------------------

func _frames_and_kerbs() -> void:
	for side in sides:
		var nv: Vector3 = side["n"]
		var dirv: Vector3 = side["dir"]
		var basis := Basis(dirv, Vector3.UP, nv)
		var ops: Array[Vector4] = side["openings"]
		for o: Vector4 in ops:
			if o.z > 0.01 or o.w >= LH - 0.01 or o.w > DOOR_TOP + 0.01:
				continue
			# A door: two jambs and a head, steel channel on the wall face round the opening.
			var top := 2.1
			for js: float in [o.x - 0.065, o.y + 0.065]:
				_box("steel", Transform3D(basis, at_side(side, js, (top + 0.1) * 0.5, WALL_HALF + 0.025)), Vector3(0.1, top + 0.1, 0.05), C_FRAME)
			_box("steel", Transform3D(basis, at_side(side, (o.x + o.y) * 0.5, top + 0.065, WALL_HALF + 0.025)), Vector3(o.y - o.x + 0.23, 0.1, 0.05), C_FRAME)
			counts["frame"] = int(counts.get("frame", 0)) + 1
		for v: Vector2 in free_spans(side, WALL_HALF, float(side["len"]) - WALL_HALF, 0.0, 0.12, 0.03):
			if v.y - v.x < 0.05:
				continue
			_box("concrete", Transform3D(basis, at_side(side, (v.x + v.y) * 0.5, 0.06, WALL_HALF + 0.018)), Vector3(v.y - v.x, 0.12, 0.036), C_KERB.darkened(0.35))
			counts["kerb"] = int(counts.get("kerb", 0)) + 1

## Steel beams across the hall's ceiling every 4 m (between the battens), with plates where they meet the walls.
func _beams() -> void:
	var hall := _room_rect("hall")
	if not hall.has_area():
		return
	var z := hall.position.y + 2.0 * S
	var basis := Basis.IDENTITY
	while z < hall.end.y - 0.5:
		var x0 := hall.position.x + WALL_HALF
		var x1 := hall.end.x - WALL_HALF
		var mid := Vector3((x0 + x1) * 0.5, 0.0, z)
		var length := x1 - x0
		_box("steel", Transform3D(basis, mid + Vector3.UP * (LH - 0.125)), Vector3(length, 0.025, 0.2), C_FRAME.darkened(0.1))
		_box("steel", Transform3D(basis, mid + Vector3.UP * (LH - 0.065)), Vector3(length, 0.1, 0.02), C_FRAME.darkened(0.2))
		_box("steel", Transform3D(basis, mid + Vector3.UP * (LH - 0.008)), Vector3(length, 0.016, 0.2), C_FRAME.darkened(0.1))
		for x: float in [x0 + 0.01, x1 - 0.01]:
			_box("steel", Transform3D(basis, Vector3(x, LH - 0.15, z)), Vector3(0.02, 0.3, 0.34), C_DARK)
		counts["beam"] = int(counts.get("beam", 0)) + 1
		z += 2.0 * S

func _rect(a: Variant) -> Rect2:
	return view.call(&"rect", a)

func _room_rect(kind: String) -> Rect2:
	for r: Dictionary in lv.plan.rooms:
		if str(r.kind) == kind and int(r.get("level", 0)) == 0:
			return Rect2(int(r.x) * S, int(r.y) * S, int(r.w) * S, int(r.h) * S)
	return Rect2()

## Yellow walk lines down the hall to the landing, drains on its centre line, hazard stripes round the rotor.
func _floor_marks() -> void:
	var hall := _room_rect("hall")
	if not hall.has_area():
		return
	var start := hall.position.y + 0.6
	if rotor_node != null:
		start = (rotor_node.get_meta(&"bounds") as AABB).end.z + 0.7
	var end := hall.end.y - 0.5
	for x: float in [hall.position.x + 1.4, hall.end.x - 1.4]:
		_decal("line", Vector3(x, 0.004, (start + end) * 0.5), Vector2(0.08, end - start), 0.0)
	var z := start + 2.0
	while z < end - 2.0:
		_decal("steel", Vector3(hall.get_center().x, 0.005, z), Vector2(0.42, 0.42), 0.0, C_DARK.darkened(0.5))
		z += 7.0
	if rotor_node != null:
		var b: AABB = rotor_node.get_meta(&"bounds")
		var x0 := b.position.x - 0.28
		var x1 := b.end.x + 0.28
		var z0 := maxf(b.position.z - 0.28, hall.position.y + WALL_HALF)
		var z1 := b.end.z + 0.28
		for strip: Array in [[Vector3(x0, 0, z0), Vector3(x0, 0, z1)], [Vector3(x1, 0, z0), Vector3(x1, 0, z1)], [Vector3(x0, 0, z1), Vector3(x1, 0, z1)]]:
			_stripe(strip[0], strip[1], 0.24)
	counts["marks"] = 1

func _decal(mat: String, at: Vector3, size: Vector2, yaw: float, col := Color.WHITE) -> void:
	var st := _tool(mat, at)
	var b := Basis(Vector3.UP, yaw)
	var ex := b * Vector3(size.x * 0.5, 0, 0)
	var ez := b * Vector3(0, 0, size.y * 0.5)
	AnnexView.quad(st, at - ex - ez, at + ex - ez, at + ex + ez, at - ex + ez, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector3.UP, col)

func _stripe(a: Vector3, b: Vector3, w: float) -> void:
	var along := (b - a).normalized()
	var across := along.cross(Vector3.UP) * (w * 0.5)
	var length := a.distance_to(b)
	var y := Vector3.UP * 0.006
	AnnexView.quad(_tool("stripe", (a + b) * 0.5), a - across + y, b - across + y, b + across + y, a + across + y,
		Vector2(0, 0), Vector2(length / 0.4, 0), Vector2(length / 0.4, 1), Vector2(0, 1), Vector3.UP, Color.WHITE)

## Stencilled signs in the company's dry tone: on the hall's long walls clear of openings and growths, and over
## each door out of the hall, what is through it.
const HALL_SIGNS := ["TURBINE HALL", "KEEP CLEAR OF THE ROTOR", "HEARING PROTECTION MUST BE WORN",
	"WALK BETWEEN THE YELLOW LINES", "REPORT LEAKS TO THE SHIFT SUPERVISOR"]
const ROOM_SIGNS := {"gallery": "CONTROL GALLERY", "switch": "SWITCH ROOM", "stores": "STORES", "lockers": "LOCKERS",
	"office": "SHIFT OFFICE", "pumps": "PUMP ROOM", "crawl": "CABLE CRAWL"}

func _signs() -> void:
	var hall_id := -1
	for r: Dictionary in lv.plan.rooms:
		if str(r.kind) == "hall":
			hall_id = int(r.id)
	var spots: Array = []
	for si in sides.size():
		var side := sides[si]
		if int(side["room"]) != hall_id:
			continue
		for v: Vector2 in free_spans(side, WALL_HALF + 0.3, float(side["len"]) - WALL_HALF - 0.3, 0.0, 2.2, 0.3):
			var s := v.x + 0.9
			while s < v.y - 0.9:
				spots.append([si, s])
				s += 3.1
		# Over each door: the room beyond.
		for o: Vector4 in side["openings"]:
			if o.z > 0.01 or o.w > DOOR_TOP + 0.01:
				continue
			var mid := (o.x + o.y) * 0.5
			var beyond := at_side(side, mid, 0.0, -0.6)
			var room := _room_at(beyond)
			if room < 0:
				continue
			var kind := str(lv.plan.rooms[room].kind)
			if ROOM_SIGNS.has(kind):
				_sign(side, mid, 2.68, ROOM_SIGNS[kind], C_SIGN, 0.0024)
	var order := range(spots.size())
	for i in range(order.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var t: int = order[i]
		order[i] = order[j]
		order[j] = t
	var placed := 0
	for k: int in order:
		if placed >= HALL_SIGNS.size():
			break
		var si: int = spots[k][0]
		var s: float = spots[k][1]
		var p := at_side(sides[si], s, 1.85, WALL_HALF)
		var clear := true
		for c: Dictionary in clusters:
			clear = clear and (c["at"] as Vector3).distance_to(p) > 1.4
		if not clear:
			continue
		var text: String = HALL_SIGNS[placed]
		_sign(sides[si], s, 1.85, text, C_WARN if text.begins_with("KEEP") or text.begins_with("HEARING") else C_SIGN, 0.003)
		placed += 1

func _sign(side: Dictionary, s: float, y: float, text: String, col: Color, px: float) -> void:
	var p := at_side(side, s, y, WALL_HALF + 0.006)
	for l: Vector3 in _lamps:
		if absf(l.y - y) < 0.4 and l.distance_to(p) < 0.9:
			return
	var label := Label3D.new()
	label.text = text
	label.font_size = 64
	label.pixel_size = px
	label.modulate = col
	label.outline_size = 0
	label.shaded = true
	label.double_sided = false
	label.alpha_cut = Label3D.ALPHA_CUT_DISCARD
	var nv: Vector3 = side["n"]
	label.transform = Transform3D(Basis(Vector3.UP.cross(nv).normalized(), Vector3.UP, nv), p)
	add_child(label)
	counts["sign"] = int(counts.get("sign", 0)) + 1

# --- the rotor ---------------------------------------------------------------------------------------------

## The stopped rotor at `at` (its foot), its axis down the hall (`along_x` false: along z): bedplate and
## pedestals, the open lower casing with flanges and bolts, the shaft and five stages of pitched blades. Kept
## inside the old rotor's box, trimmed to the hall's end wall. Returns its node; its "bounds" meta is its box.
func rotor(at: Vector3, along_x: bool, r: float, wall_z: float) -> Node3D:
	var node := Node3D.new()
	node.name = "Rotor"
	add_child(node)
	var yaw := PI * 0.5 if along_x else 0.0
	var xf := Transform3D(Basis(Vector3.UP, yaw), at)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%s:%d:rotor" % [lv.plan.get("seed", ""), int(lv.plan.get("depth", 0))])
	var steel := SurfaceTool.new()
	steel.begin(Mesh.PRIMITIVE_TRIANGLES)
	var paint := SurfaceTool.new()
	paint.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cy := 0.45 + r
	var z_lo := -1.33
	if not along_x and wall_z > -INF:
		z_lo = maxf(z_lo, wall_z - at.z + 0.06)
	var z_hi := 1.33
	var green := Color(0.95, 1.0, 0.95)
	# Bedplate and the plates and bolts on its top.
	AnnexView.box(paint, xf, Vector3(2.5, 0.45, z_hi - z_lo), Vector3(0, 0.225, (z_lo + z_hi) * 0.5), green.darkened(0.25))
	for sx: float in [-1.12, 1.12]:
		var z := z_lo + 0.15
		while z < z_hi - 0.1:
			AnnexView.box(steel, xf, Vector3(0.06, 0.05, 0.06), Vector3(sx, 0.47, z), C_DARK)
			z += 0.3
	# The Meshy rotor in its open casing when it is there (godot/assets/reactor/rotor_b.glb), else drawn here.
	if not _rotor_model(node, xf, z_lo, z_hi):
		# Pedestals and bearing caps.
		for pz: float in [z_lo + 0.2, z_hi - 0.2]:
			AnnexView.box(paint, xf, Vector3(0.7, cy - 0.45, 0.24), Vector3(0, 0.45 + (cy - 0.45) * 0.5, pz), green.darkened(0.1))
			_rotor_ring(steel, xf, cy, pz - 0.13, pz + 0.13, 0.27, 0.0, C_STEEL.darkened(0.15), 12)
		# The shaft and its couplings.
		_rotor_ring(steel, xf, cy, z_lo + 0.05, z_hi - 0.05, 0.15, 0.0, C_STEEL, 10)
		# The open lower casing: outer and inner shells of the bottom half, end walls, the split-line flanges.
		var rc := r + 0.13
		var cz0 := z_lo + 0.36
		var cz1 := z_hi - 0.36
		_half_shell(paint, xf, cy, cz0, cz1, rc, false, green)
		_half_shell(paint, xf, cy, cz0, cz1, rc - 0.05, true, green.darkened(0.45))
		for end: Array in [[cz0, -1.0], [cz1, 1.0]]:
			_half_annulus(paint, xf, cy, end[0], 0.2, rc, end[1], green.darkened(0.15))
		for sx: float in [-1.0, 1.0]:
			AnnexView.box(paint, xf, Vector3(0.11, 0.07, cz1 - cz0 + 0.1), Vector3(sx * (rc + 0.03), cy - 0.035, (cz0 + cz1) * 0.5), green.darkened(0.05))
			var z := cz0 + 0.1
			while z < cz1:
				AnnexView.box(steel, xf, Vector3(0.05, 0.06, 0.05), Vector3(sx * (rc + 0.035), cy + 0.03, z), C_DARK)
				z += 0.22
		for k in 3:
			var z := lerpf(cz0 + 0.3, cz1 - 0.3, k * 0.5)
			_half_shell(paint, xf, cy, z - 0.03, z + 0.03, rc + 0.035, false, green.darkened(0.1))
		# The rotor: a drum and five stages of pitched blades, each stage with its shroud. Stopped, worn.
		var hub := 0.42
		_rotor_ring(steel, xf, cy, cz0 + 0.12, cz1 - 0.12, hub, 0.0, C_STEEL.darkened(0.1), 16)
		for stage in 5:
			var z := lerpf(cz0 + 0.25, cz1 - 0.25, stage / 4.0)
			var tip := lerpf(0.78, rc - 0.1, stage / 4.0)
			var count := 22 + stage * 2
			var turn := rng.randf() * TAU
			for b in count:
				var ang := turn + TAU * b / count
				var basis_r := Basis(Vector3.BACK, ang)
				var pitch := Basis(Vector3.UP, deg_to_rad(32.0 + stage * 4.0))
				var length := tip - hub
				var wear := C_STEEL.lerp(C_RUST, clampf(rng.randf() * 0.9 - 0.2, 0.0, 1.0))
				var bxf := xf * Transform3D(basis_r * pitch, Vector3(0, cy, z) + basis_r * Vector3(0, hub + length * 0.5, 0))
				AnnexView.box(steel, bxf, Vector3(0.13, length, 0.012), Vector3.ZERO, wear)
			_rotor_ring(steel, xf, cy, z - 0.07, z + 0.07, tip + 0.012, tip, C_STEEL.darkened(0.2), count)
			_rotor_ring(steel, xf, cy, z - 0.05, z + 0.05, hub + 0.05, 0.0, C_STEEL.darkened(0.3), 16)
	for st: Array in [[steel, "steel"], [paint, "paint"]]:
		var mi := MeshInstance3D.new()
		mi.name = "Rotor_" + str(st[1])
		mi.mesh = (st[0] as SurfaceTool).commit()
		mi.material_override = _mats[st[1]]
		node.add_child(mi)
	var box := AABB()
	var first := true
	for mi: MeshInstance3D in node.get_children():
		var bb := mi.transform * mi.get_aabb()
		box = bb if first else box.merge(bb)
		first = false
	node.set_meta(&"bounds", box)
	rotor_node = node
	_block_rotor()
	return node

## The Meshy rotor (generated on the owner's paid plan, 21 Nov 2026; the shaft along +X, centred, its foot at 0),
## its shaft across the hall, scaled to fit the old rotor's box and set on the bedplate. False when the file is missing.
func _rotor_model(node: Node3D, xf: Transform3D, z_lo: float, z_hi: float) -> bool:
	if not ResourceLoader.exists(ROTOR_GLB):
		return false
	var scene: Node = (load(ROTOR_GLB) as PackedScene).instantiate()
	var found := _first_mesh(scene)
	if found == null:
		scene.free()
		return false
	var base := _global_xf(found, scene)
	var box := base * found.mesh.get_aabb()
	# Across the hall, so the long view from the lift ends on the open casing's side and its blades.
	var s := minf(2.5 / box.size.x, minf((z_hi - z_lo - 0.1) / box.size.z, 2.45 / box.size.y))
	var mi := MeshInstance3D.new()
	mi.name = "Rotor_model"
	mi.mesh = found.mesh
	var m: Material = found.get_active_material(0)
	if m is BaseMaterial3D:
		var mat := Level.prop_material(Color(1.35, 1.35, 1.3), (m as BaseMaterial3D).albedo_texture)
		mi.material_override = mat
	mi.transform = xf * Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * s), Vector3(0, 0.45, (z_lo + z_hi) * 0.5)) * base
	node.add_child(mi)
	scene.free()
	counts["rotor_model"] = 1
	return true

## A closed ring (outer radius r, inner radius r_in; r_in 0: a solid cylinder with ends) about the rotor axis.
func _rotor_ring(st: SurfaceTool, xf: Transform3D, cy: float, z0: float, z1: float, r: float, r_in: float, col: Color, segs: int) -> void:
	for j in segs:
		var a0 := TAU * j / segs
		var a1 := TAU * (j + 1) / segs
		var d0 := Vector3(cos(a0), sin(a0), 0)
		var d1 := Vector3(cos(a1), sin(a1), 0)
		var c0 := Vector3(0, cy, z0)
		var c1 := Vector3(0, cy, z1)
		AnnexView.quad(st, xf * (c0 + d0 * r), xf * (c1 + d0 * r), xf * (c1 + d1 * r), xf * (c0 + d1 * r), Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, xf.basis * ((d0 + d1) * 0.5).normalized(), col)
		if r_in > 0.0:
			AnnexView.quad(st, xf * (c0 + d0 * r_in), xf * (c1 + d0 * r_in), xf * (c1 + d1 * r_in), xf * (c0 + d1 * r_in), Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, xf.basis * -((d0 + d1) * 0.5).normalized(), col)
		for end: Array in [[c0, -1.0], [c1, 1.0]]:
			var c: Vector3 = end[0]
			var nn := xf.basis * Vector3(0, 0, float(end[1]))
			AnnexView.quad(st, xf * (c + d0 * r_in), xf * (c + d0 * r), xf * (c + d1 * r), xf * (c + d1 * r_in), Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, nn, col)

## The bottom half of a cylinder shell about the rotor axis, facing out (or in).
func _half_shell(st: SurfaceTool, xf: Transform3D, cy: float, z0: float, z1: float, r: float, inward: bool, col: Color) -> void:
	var segs := 14
	for j in segs:
		var a0 := PI + PI * j / segs
		var a1 := PI + PI * (j + 1) / segs
		var d0 := Vector3(cos(a0), sin(a0), 0)
		var d1 := Vector3(cos(a1), sin(a1), 0)
		var nn := ((d0 + d1) * 0.5).normalized() * (-1.0 if inward else 1.0)
		AnnexView.quad(st, xf * (Vector3(0, cy, z0) + d0 * r), xf * (Vector3(0, cy, z1) + d0 * r), xf * (Vector3(0, cy, z1) + d1 * r), xf * (Vector3(0, cy, z0) + d1 * r),
			Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, xf.basis * nn, col)
		if not inward:
			AnnexView.quad(st, xf * (Vector3(0, cy, z0) + d0 * r), xf * (Vector3(0, cy, z1) + d0 * r), xf * (Vector3(0, cy, z1) + d1 * r), xf * (Vector3(0, cy, z0) + d1 * r),
				Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, xf.basis * -nn, col.darkened(0.4))

## The casing's half-annulus end wall round the shaft.
func _half_annulus(st: SurfaceTool, xf: Transform3D, cy: float, z: float, r_in: float, r: float, facing: float, col: Color) -> void:
	var segs := 14
	for j in segs:
		var a0 := PI + PI * j / segs
		var a1 := PI + PI * (j + 1) / segs
		var d0 := Vector3(cos(a0), sin(a0), 0)
		var d1 := Vector3(cos(a1), sin(a1), 0)
		var c := Vector3(0, cy, z)
		for f: float in [facing, -facing]:
			AnnexView.quad(st, xf * (c + d0 * r_in), xf * (c + d0 * r), xf * (c + d1 * r), xf * (c + d1 * r_in), Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, xf.basis * Vector3(0, 0, f), col)
