extends RefCounted
## LA8: how bright a surface of the Reactor's generating station reads, worked out from the lights the view built and
## the station surface shader's own terms (client/station_surface.gdshader), the way the Compatibility renderer adds
## them up with the station's shadows off (no occlusion: a lamp behind a wall lights through it, as on screen): for
## every light on (battens, amber lamps, the cassette's), the Lambert term times the spot cone and the distance
## falloff, plus the game's ambient, plus the surface's own light. Light and ambient colours are taken to linear first,
## as the renderer does. Linear luminance, before fog, tone mapping and the tape. The player's near light and torch are
## left out (they are the same before and after any change here). Used by test_station_walls.gd and the LA8 measuring
## scripts.

## The game's ambient energy with the lights on (client/main.gd env.ambient_light_energy).
const AMBIENT_ENERGY := 0.12
## A lamp's light against the ambient and the surfaces' own light: LA8's real-window pictures put the lit floors far
## brighter against the walls' own light than energy x Lambert alone gives; the punctual lights' pi (Godot's lights are
## given with the 1/pi of the Lambert term already taken out) matches them (client/station_view.gd RENDER_GAIN).
const DIRECT_GAIN := PI
const S := 2.0
const LH := 3.2
const WALL_HALF := 0.07
const HEIGHTS: Array[float] = [0.5, 1.0, 1.5, 2.5, 3.0]

static func lum(c: Color) -> float:
	return c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722

static func lumv(c: Vector3) -> float:
	return c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722

static func _lights(n: Node, out: Array[Light3D]) -> void:
	for c in n.get_children():
		if c is Node3D and not (c as Node3D).visible:
			continue
		if c is Light3D:
			out.append(c)
		_lights(c, out)

## Every light on now under the level (hidden branches skipped).
static func lights_on(level: Level) -> Array[Light3D]:
	var out: Array[Light3D] = []
	_lights(level, out)
	return out.filter(func(l: Light3D) -> bool: return l.light_energy > 0.0)

static func _world(l: Light3D) -> Transform3D:
	if l.is_inside_tree():
		return l.global_transform
	var xf := l.transform
	var p := l.get_parent()
	while p is Node3D:
		xf = (p as Node3D).transform * xf
		p = p.get_parent()
	return xf

## The light arriving at point p on a surface facing n (luminance, before the albedo).
static func light_at(_level: Level, lights: Array[Light3D], p: Vector3, n: Vector3) -> float:
	var sum := 0.0
	var lower := p.y < LH - 0.01
	for l in lights:
		if lower and (l.light_cull_mask & Level.LOWER_LAYER) == 0:
			continue
		var xf := _world(l)
		var rel := xf.origin - p
		var d := rel.length()
		if d < 1e-4:
			continue
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
			var dir := -(xf.basis.z.normalized())
			var cutoff := cos(deg_to_rad(spot.spot_angle))
			var scos := maxf((-rel / d).dot(dir), cutoff)
			var rim := maxf(0.0001, (1.0 - scos) / (1.0 - cutoff))
			att *= 1.0 - pow(rim, spot.spot_angle_attenuation)
		sum += lum(l.light_color.srgb_to_linear()) * l.light_energy * ndl * att * DIRECT_GAIN
	return sum

static var _mean_cache := {}

## A texture's mean linear colour.
static func mean(tex: Texture2D) -> Vector3:
	if _mean_cache.has(tex):
		return _mean_cache[tex]
	var img := tex.get_image()
	if img.is_compressed():
		img.decompress()
	var sum := Vector3.ZERO
	var k := 0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var c := img.get_pixel(x, y).srgb_to_linear()
			sum += Vector3(c.r, c.g, c.b)
			k += 1
	_mean_cache[tex] = sum / maxf(1.0, k)
	return _mean_cache[tex]

static func _param(m: ShaderMaterial, name: String, fallback: float) -> float:
	var v: Variant = m.get_shader_parameter(name)
	return fallback if v == null else float(v)

## The surface's albedo luminance as the station shader colours it at storey height hy, corruption t (the slow
## variation averages to 1; stains aside).
static func albedo(m: ShaderMaterial, wall: bool, hy: float, t: float) -> float:
	var base := mean(m.get_shader_parameter("albedo_tex") as Texture2D)
	var dado := _param(m, "dado", 0.0)
	if wall and dado > 0.0:
		if hy < dado:
			base = mean(m.get_shader_parameter("paint_tex") as Texture2D)
		base *= lerpf(0.62, 1.0, smoothstep(0.0, 0.5, hy))
	var dirt := smoothstep(0.2, 0.85, t)
	return lumv(base.lerp(base * Vector3(0.74, 0.7, 0.52), dirt))

## The shader's own light at this point: self_light, less with the corruption, and the side rooms' fill when the view
## has one (client/station_view.gd fill_at).
static func own(view: Node3D, m: ShaderMaterial, n: Vector3, p: Vector3, t: float) -> float:
	var dirt := smoothstep(0.2, 0.85, t)
	var e := _param(m, "self_light", 0.0) * (1.0 - dirt * 0.85)
	if view.has_method(&"fill_at"):
		e += float(view.call(&"fill_at", m, n, p))
	return e

## [the albedo, the light it gives back: the lights', the ambient and its own] at p facing n.
static func terms(level: Level, lights: Array[Light3D], m: ShaderMaterial, p: Vector3, n: Vector3) -> Vector2:
	var view: Node3D = level.get_meta(&"station")
	var wall := absf(n.y) < 0.5
	var hy := fposmod(p.y + 0.001, LH)
	# The cell the face looks into, on the storey the point is on (Level.corruption_at would take a point near the
	# ceiling for the storey above).
	var q := p + n * 0.3 if wall else p
	var t := level.corruption(clampi(int(floorf(p.y / LH)), 0, 1), int(floorf(q.x / S)), int(floorf(q.z / S)))
	var amb := AMBIENT_ENERGY * lum(level.ambient_lit.srgb_to_linear())
	return Vector2(albedo(m, wall, hy, t), light_at(level, lights, p, n) + amb + own(view, m, n, p, t))

## How bright the station surface m reads at p facing n (linear luminance).
static func seen(level: Level, lights: Array[Light3D], m: ShaderMaterial, p: Vector3, n: Vector3) -> float:
	var v := terms(level, lights, m, p, n)
	return v.x * v.y

## A room's walls: {kind, id, rect (cells), walls: [{x, y, o (step toward the wall), end (bool)}]} for every room on
## level 0 whose kind is in `kinds`. "end": a wall across the room's long way (a square room has none).
static func rooms(level: Level, kinds: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for r: Dictionary in level.plan.rooms:
		if int(r.get("level", 0)) != 0 or not kinds.has(str(r.kind)):
			continue
		var x0 := int(r.x)
		var y0 := int(r.y)
		var w := int(r.w)
		var h := int(r.h)
		var walls: Array[Dictionary] = []
		for y in range(y0, y0 + h):
			for x in range(x0, x0 + w):
				for o: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					if edge(level, x, y, o) != "wall":
						continue
					var across_x := o.x != 0
					walls.append({"x": x, "y": y, "o": o, "end": (across_x and w > h) or (not across_x and h > w)})
		out.append({"kind": str(r.kind), "id": int(r.id), "rect": Rect2i(x0, y0, w, h), "walls": walls})
	return out

## The edge of cell (x, y) on the lower storey in direction o.
static func edge(level: Level, x: int, y: int, o: Vector2i) -> String:
	var vert: Array = level.edges[0].vertical
	var hor: Array = level.edges[0].horizontal
	if o == Vector2i(0, -1):
		return hor[y * level.W + x]
	if o == Vector2i(0, 1):
		return hor[(y + 1) * level.W + x]
	if o == Vector2i(-1, 0):
		return vert[y * (level.W + 1) + x]
	return vert[y * (level.W + 1) + x + 1]

## The wall material drawn on a room-side face (green paint in rooms).
static func wall_mat(level: Level, x: int, y: int) -> ShaderMaterial:
	var view: Node3D = level.get_meta(&"station")
	return view.get(&"mat_wall_g") if level.kind(0, x, y) == "room" else view.get(&"mat_wall_c")

## One wall cell's brightness at height h (or, with `light_only`, the light on it before its albedo), the mean of five
## points along its 2 m.
static func wall_seen(level: Level, lights: Array[Light3D], w: Dictionary, h: float, light_only := false) -> float:
	var o: Vector2i = w.o
	var n := Vector3(-o.x, 0, -o.y)
	var c := level.cell_center(0, int(w.x), int(w.y))
	var along := Vector3(-n.z, 0, n.x)
	var m := wall_mat(level, int(w.x), int(w.y))
	var sum := 0.0
	for i in 5:
		var p := c - n * (S * 0.5 - WALL_HALF) + along * (-0.8 + 0.4 * i)
		p.y = h
		var v := terms(level, lights, m, p, n)
		sum += v.y if light_only else v.x * v.y
	return sum / 5.0

## The floor or the ceiling of one cell, the mean of its middle and four points 0.5 m in from its corners.
static func flat_seen(level: Level, lights: Array[Light3D], x: int, y: int, ceiling: bool) -> float:
	var view: Node3D = level.get_meta(&"station")
	var m: ShaderMaterial = view.get(&"mat_ceil") if ceiling else view.get(&"mat_floor")
	var c := level.cell_center(0, x, y)
	var sum := 0.0
	for d: Vector2 in [Vector2.ZERO, Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(-0.5, 0.5), Vector2(0.5, 0.5)]:
		var p := c + Vector3(d.x, LH - 0.001 if ceiling else 0.0, d.y)
		sum += seen(level, lights, m, p, Vector3.DOWN if ceiling else Vector3.UP)
	return sum / 5.0

static func _hk(h: float) -> String:
	return "h%02d" % int(roundf(h * 10.0))

## One room's measures: {kind, id, side: {n, h05, h10, h15, h25, h30}, end: {...} (n 0 when none), all: {...} (every
## wall), floor, ceiling, worst25 (the darkest wall cell at 2.5 m), worst_ceiling (the darkest ceiling cell), light10 and
## light25 (the light on the walls at 1.0 m and 2.5 m before their albedo: the green paint below 1.2 m is darker than the
## concrete above it, so this is what says whether the light reaches the top)}.
static func measure(level: Level, room: Dictionary) -> Dictionary:
	var lights := lights_on(level)
	var out := {"kind": room.kind, "id": room.id}
	for what: String in ["side", "end", "all"]:
		var r := {"n": 0}
		for h in HEIGHTS:
			r[_hk(h)] = 0.0
		for w: Dictionary in room.walls:
			if what != "all" and bool(w.end) != (what == "end"):
				continue
			r.n += 1
			for h in HEIGHTS:
				r[_hk(h)] += wall_seen(level, lights, w, h)
		if r.n > 0:
			for h in HEIGHTS:
				r[_hk(h)] /= r.n
		out[what] = r
	var worst := INF
	var l10 := 0.0
	var l25 := 0.0
	for w: Dictionary in room.walls:
		worst = minf(worst, wall_seen(level, lights, w, 2.5))
		l10 += wall_seen(level, lights, w, 1.0, true)
		l25 += wall_seen(level, lights, w, 2.5, true)
	out["worst25"] = worst
	out["light10"] = l10 / maxf(1.0, room.walls.size())
	out["light25"] = l25 / maxf(1.0, room.walls.size())
	var rect: Rect2i = room.rect
	var fl := 0.0
	var ce := 0.0
	var worst_ce := INF
	var k := 0
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			fl += flat_seen(level, lights, x, y, false)
			var c := flat_seen(level, lights, x, y, true)
			ce += c
			worst_ce = minf(worst_ce, c)
			k += 1
	out["floor"] = fl / maxf(1.0, k)
	out["ceiling"] = ce / maxf(1.0, k)
	out["worst_ceiling"] = worst_ce
	return out

## The shares the checks read, from one room's measures: up (every wall at 2.5 m over 1.5 m, both bare concrete),
## light_up (the light at 2.5 m over 1.0 m), wall_floor (walls at 2.5 m over the floor), top_floor (at 3.0 m over the
## floor), end_side (end walls over side walls at 2.5 m; 1 when the room is square), ceiling_floor, corner_floor (the
## darkest wall cell at 2.5 m over the floor), ceiling_corner (the darkest ceiling cell over the floor); and the plain
## numbers: wall15, wall25, wall30 (every wall), ceiling, worst25, worst_ceiling, floor.
static func shares(m: Dictionary) -> Dictionary:
	var a: Dictionary = m.all
	var fl: float = maxf(1e-6, float(m.floor))
	var es := 1.0
	if int(m.end.n) > 0 and int(m.side.n) > 0:
		es = float(m.end.h25) / maxf(1e-6, float(m.side.h25))
	return {"up": float(a.h25) / maxf(1e-6, float(a.h15)), "light_up": float(m.light25) / maxf(1e-6, float(m.light10)),
		"wall_floor": float(a.h25) / fl, "top_floor": float(a.h30) / fl, "end_side": es,
		"ceiling_floor": float(m.ceiling) / fl, "corner_floor": float(m.worst25) / fl, "ceiling_corner": float(m.worst_ceiling) / fl,
		"wall15": float(a.h15), "wall25": float(a.h25), "wall30": float(a.h30), "ceiling": float(m.ceiling), "worst25": float(m.worst25),
		"worst_ceiling": float(m.worst_ceiling), "floor": fl}

## A line of numbers for one room's (or one kind's mean) measures.
static func line(k: String, d: Dictionary) -> String:
	var a: Dictionary = d.all
	var e: Dictionary = d.end
	var txt := "%s: wall 0.5 %.4f, 1.0 %.4f, 1.5 %.4f, 2.5 %.4f, 3.0 %.4f; floor %.4f, ceiling %.4f; darkest wall at 2.5 %.4f, darkest ceiling %.4f" % [
		k, a.h05, a.h10, a.h15, a.h25, a.h30, d.floor, d.ceiling, d.worst25, d.worst_ceiling]
	if int(e.n) > 0:
		txt += "; end walls 1.0 %.4f, 2.5 %.4f" % [e.h10, e.h25]
	return txt

## The mean of several rooms' measures (numbers only).
static func mean_of(list: Array) -> Dictionary:
	var out := {}
	for key: String in ["floor", "ceiling", "worst25", "worst_ceiling", "light10", "light25"]:
		var s := 0.0
		for m: Dictionary in list:
			s += float(m[key])
		out[key] = s / maxf(1.0, list.size())
	for what: String in ["side", "end", "all"]:
		var r := {"n": 0}
		for h in HEIGHTS:
			var s := 0.0
			var n := 0
			for m: Dictionary in list:
				if int(m[what].n) > 0:
					s += float(m[what][_hk(h)])
					n += 1
			r[_hk(h)] = s / maxf(1.0, n)
			r.n = n
		out[what] = r
	return out
