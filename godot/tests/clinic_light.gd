extends RefCounted
## LA5: how bright a Clinic surface reads, worked out from the lights the level built and the surface shader's own
## terms, the way the Compatibility renderer adds them up (no shadows, so no occlusion): for each ceiling lamp the
## Lambert term times the spot cone and the distance falloff, plus the ambient, plus the surface's own light
## (surface.gdshader self_light, less with the corruption). Linear luminance, before fog, tone mapping and the tape.
## Used by test_clinic_walls.gd and by the LA5 measuring script.

## The game's ambient with the lights on (client/main.gd): energy and colour.
const AMBIENT_ENERGY := 0.12
const AMBIENT := Color(0.55, 0.6, 0.6)

static func lum(c: Color) -> float:
	return c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722

## The lamps' light arriving at point p on a surface facing n (luminance, before the albedo).
static func lamp_light(level: Level, p: Vector3, n: Vector3, lower_mesh: bool) -> float:
	var sum := 0.0
	for l: Light3D in level.main_lights:
		if not l.visible or l.light_energy <= 0.0:
			continue
		if lower_mesh and (l.light_cull_mask & Level.LOWER_LAYER) == 0:
			continue
		var rel := l.global_position - p if l.is_inside_tree() else l.position - p
		var d := rel.length()
		var ndl := maxf(n.dot(rel / d), 0.0)
		if ndl <= 0.0:
			continue
		var spot := l as SpotLight3D
		var rng: float = spot.spot_range if spot else (l as OmniLight3D).omni_range
		var decay: float = spot.spot_attenuation if spot else (l as OmniLight3D).omni_attenuation
		var nd := d / rng
		nd = nd * nd
		nd = nd * nd
		nd = maxf(1.0 - nd, 0.0)
		var att := nd * nd * pow(maxf(d, 0.0001), -decay)
		if spot:
			var dir := -(l.basis.z)
			var cutoff := cos(deg_to_rad(spot.spot_angle))
			var scos := maxf((-rel / d).dot(dir), cutoff)
			var rim := maxf(0.0001, (1.0 - scos) / (1.0 - cutoff))
			att *= 1.0 - pow(rim, spot.spot_angle_attenuation)
		sum += lum(l.light_color) * l.light_energy * ndl * att
	return sum

## The texture's mean linear luminance as surface.gdshader colours it at corruption t (whitening and grime; the
## stains, scuffs and grid lines aside).
## Every step is linear in the pixel, so the mean of the texture and the mean of its whitened copy stand for all of it.
static func albedo(m: ShaderMaterial, t: float) -> float:
	var means := _means(m.get_shader_parameter("albedo_tex") as Texture2D)
	var whiten := _param(m, "whiten", 0.0)
	var dirt := smoothstep(0.2, 0.85, t)
	var base: Vector3 = means[0]
	if whiten > 0.0:
		base = base.lerp(means[1], whiten * (1.0 - smoothstep(0.1, 0.7, t)))
	var c := base.lerp(base * Vector3(0.74, 0.7, 0.52), dirt)
	return c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722

static var _mean_cache := {}

## [the texture's mean linear colour, the mean of its clean pale copy (surface.gdshader whiten)].
static func _means(tex: Texture2D) -> Array:
	if _mean_cache.has(tex):
		return _mean_cache[tex]
	var img := tex.get_image()
	if img.is_compressed():
		img.decompress()
	var sum := Vector3.ZERO
	var clean := Vector3.ZERO
	var n := 0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var p := img.get_pixel(x, y).srgb_to_linear()
			sum += Vector3(p.r, p.g, p.b)
			clean += Vector3(0.9, 0.92, 0.93) * (0.82 + 0.18 * lum(p) / 0.6)
			n += 1
	_mean_cache[tex] = [sum / n, clean / n]
	return _mean_cache[tex]

## The surface's own light at corruption t (surface.gdshader: self_light * (1 - dirt * self_dirt)).
static func own_light(m: ShaderMaterial, t: float) -> float:
	var dirt := smoothstep(0.2, 0.85, t)
	return _param(m, "self_light", 0.0) * (1.0 - dirt * _param(m, "self_dirt", 0.85))

static func _param(m: ShaderMaterial, name: String, fallback: float) -> float:
	var v: Variant = m.get_shader_parameter(name)
	return fallback if v == null else float(v)

## How bright surface m reads at point p facing n, at corruption t (linear luminance).
static func seen(level: Level, m: ShaderMaterial, p: Vector3, n: Vector3, t: float, lower_mesh: bool) -> float:
	return albedo(m, t) * (lamp_light(level, p, n, lower_mesh) + AMBIENT_ENERGY * lum(AMBIENT) + own_light(m, t))

## A wall edge of cell (x, y) on storey lv, in direction o (one of the four steps): the edge's kind.
static func edge(level: Level, lv: int, x: int, y: int, o: Vector2i) -> String:
	var vert: Array = level.edges[lv].vertical
	var hor: Array = level.edges[lv].horizontal
	if o == Vector2i(0, -1):
		return hor[y * level.W + x]
	if o == Vector2i(0, 1):
		return hor[(y + 1) * level.W + x]
	if o == Vector2i(-1, 0):
		return vert[y * (level.W + 1) + x]
	return vert[y * (level.W + 1) + x + 1]

const STEPS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

## The walls of the floor worth measuring, near the lift (corruption below `near_t`) or far (above `far_t`):
## [{kind: "side"|"end"|"lift", lv, x, y, o (step toward the wall), t}]. "side": a corridor wall with a wall across the
## cell too (a wall along the way); "end": a corridor or lobby wall with the way open behind it (a wall the way runs
## into); "lift": the first wall straight out from the lift doors.
static func walls(level: Level, near: bool, near_t := 0.25, far_t := 0.75) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for lv in 2:
		for y in level.H:
			for x in level.W:
				var k := level.kind(lv, x, y)
				if k != "corridor" and k != "landing" and k != "room":
					continue
				var t := level.corruption(lv, x, y)
				if (near and t > near_t) or (not near and t < far_t):
					continue
				for o: Vector2i in STEPS:
					if edge(level, lv, x, y, o) != "wall":
						continue
					var back := edge(level, lv, x, y, -o)
					if k == "corridor" and back == "wall":
						out.append({"kind": "side", "lv": lv, "x": x, "y": y, "o": o, "t": t})
					elif back == "open" and level.walkable(lv, x - o.x, y - o.y) and level.walkable(lv, x - 2 * o.x, y - 2 * o.y):
						if edge(level, lv, x - o.x, y - o.y, -o) == "open":
							out.append({"kind": "end", "lv": lv, "x": x, "y": y, "o": o, "t": t})
	if near:
		var v := level._dir_vec(level.lift_dir)
		var lv := level.landing.x
		var cx := level.landing.y
		var cy := level.landing.z
		for i in 12:
			if edge(level, lv, cx, cy, -v) != "open" or not level.walkable(lv, cx - v.x, cy - v.y):
				break
			cx -= v.x
			cy -= v.y
		if edge(level, lv, cx, cy, -v) == "wall":
			out.append({"kind": "lift", "lv": lv, "x": cx, "y": cy, "o": -v, "t": level.corruption(lv, cx, cy)})
	return out

## The wall's brightness at height h over its storey's floor, averaged over five points along the cell's edge.
static func wall_seen(level: Level, w: Dictionary, h: float) -> float:
	var o: Vector2i = w.o
	var n := Vector3(-o.x, 0, -o.y)
	var c := level.cell_center(int(w.lv), int(w.x), int(w.y))
	var along := Vector3(-n.z, 0, n.x)
	var sum := 0.0
	for i in 5:
		var p := c - n * (Level.S * 0.5 - Level.WALL_T * 0.5) + along * (-0.8 + 0.4 * i)
		p.y = int(w.lv) * Level.LH + h
		sum += seen(level, level.mat_wall, p, n, float(w.t), int(w.lv) == 0)
	return sum / 5.0

## The floor (up) or the ceiling (down) 0.5 m out from the wall, averaged the same way.
static func flat_seen(level: Level, w: Dictionary, ceiling: bool) -> float:
	var o: Vector2i = w.o
	var n := Vector3(-o.x, 0, -o.y)
	var c := level.cell_center(int(w.lv), int(w.x), int(w.y))
	var along := Vector3(-n.z, 0, n.x)
	var sum := 0.0
	for i in 5:
		var p := c - n * (Level.S * 0.5 - 0.5) + along * (-0.8 + 0.4 * i)
		p.y = int(w.lv) * Level.LH + (Level.LH - 0.001 if ceiling else 0.0)
		var m := level.mat_ceiling if ceiling else level.mat_floor
		sum += seen(level, m, p, Vector3.DOWN if ceiling else Vector3.UP, float(w.t), int(w.lv) == 0)
	return sum / 5.0

## The mean of each measure over the walls of one kind: {n, h05, h10, h15, h25, h30, floor, ceiling}.
static func summary(level: Level, list: Array[Dictionary], what: String) -> Dictionary:
	var r := {"n": 0, "h05": 0.0, "h10": 0.0, "h15": 0.0, "h25": 0.0, "h30": 0.0, "floor": 0.0, "ceiling": 0.0}
	for w: Dictionary in list:
		if w.kind != what:
			continue
		r.n += 1
		r.h05 += wall_seen(level, w, 0.5)
		r.h10 += wall_seen(level, w, 1.0)
		r.h15 += wall_seen(level, w, 1.5)
		r.h25 += wall_seen(level, w, 2.5)
		r.h30 += wall_seen(level, w, 3.0)
		r.floor += flat_seen(level, w, false)
		r.ceiling += flat_seen(level, w, true)
	if r.n > 0:
		for k: String in ["h05", "h10", "h15", "h25", "h30", "floor", "ceiling"]:
			r[k] /= r.n
	return r
