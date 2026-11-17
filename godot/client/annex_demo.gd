# A look at the Annex (annex_view.gd) in the game's own picture: seeded Annex floors built by Level
# from sim/annex.gd's plan, the 480x270 view through the tape shader, in a window. It checks that
# same-shaped rooms are dressed alike (on several floors), takes pictures with a scripted camera, then
# walks the camera down the same kind of route on the Annex and on a Clinic floor of the same seed and
# prints frame times for both. Never captures the mouse. Prints "annex demo json: {...}" last.
# The release build loads it with `GoingDown.exe -- scene=annex_demo` (main.gd); tools/annex_walk.mjs
# runs it. Arguments after `--`: shots=DIR seed=annex-1 depth=3 bench=6 (seconds per walk, 0 = none)
# rounds=2 (Annex and Clinic walks, alternating).
extends Node

const Annex = preload("res://sim/annex.gd")
const Clinic = preload("res://sim/clinic.gd")
const Run = preload("res://sim/run.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const AnnexView = preload("res://client/annex_view.gd")
const VFOV := 70.0
const EYE := 1.65
const S := 2.0
const LH := 3.2

var sub: SubViewport
var cam: Camera3D
var world: Node3D
var env: Environment
var level: Level
var lift: Lift
var view: AnnexView
var shots_dir := "user://annex_shots"
var seed_text := "annex-1"
var depth := 3
var bench := 6.0
var rounds := 2
var light := 1.0
var emergency := 0.0
var report := {}
var shot_lines: Array[String] = []

func _ready() -> void:
	for raw in OS.get_cmdline_user_args():
		var a := raw.trim_prefix("--")
		var key := a.get_slice("=", 0)
		var val := a.substr(key.length() + 1)
		match key:
			"shots": shots_dir = val
			"seed": seed_text = val
			"depth": depth = int(val)
			"bench": bench = float(val)
			"rounds": rounds = int(val)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_build_view()
	_run.call_deferred()

func _build_view() -> void:
	sub = SubViewport.new()
	sub.size = Vector2i(480, 270)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sub.msaa_3d = Viewport.MSAA_DISABLED
	sub.positional_shadow_atlas_size = 2048
	add_child(sub)
	get_viewport().disable_3d = true
	# The game's own environment (main.gd _build_view), dark fog and all.
	var we := WorldEnvironment.new()
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.025, 0.025)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.6, 0.6)
	env.ambient_light_energy = 0.12
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_light_color = Color(0.05, 0.06, 0.06)
	env.fog_density = 0.035
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_hdr_threshold = 0.9
	we.environment = env
	sub.add_child(we)
	world = Node3D.new()
	sub.add_child(world)
	cam = Camera3D.new()
	cam.fov = VFOV
	cam.near = 0.05
	cam.far = 60.0
	sub.add_child(cam)
	cam.current = true
	var screen := TextureRect.new()
	screen.texture = sub.get_texture()
	screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	screen.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	screen.stretch_mode = TextureRect.STRETCH_SCALE
	screen.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var tape := ShaderMaterial.new()
	tape.shader = load("res://client/tape.gdshader")
	screen.material = tape
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(screen)

static func annex_plan(s: String, d: int) -> Dictionary:
	var fp := Annex.generate_annex(s, d)
	return PlanDump.dump(fp, Run.car_geometry(fp))

static func clinic_plan(s: String, d: int) -> Dictionary:
	var fp := Clinic.generate_clinic(s, d)
	return PlanDump.dump(fp, Run.car_geometry(fp))

func _build(plan: Dictionary) -> void:
	if level:
		level.free()
		lift.free()
	level = Level.new()
	level.shadows = true
	world.add_child(level)
	level.build(plan, seed_text)
	lift = Lift.new()
	world.add_child(lift)
	lift.build(plan["car"], level.lift_left_wall())
	lift.set_doors(true, true)
	view = level.get_meta("annex") if level.has_meta("annex") else null
	light = 1.0
	emergency = 0.0
	level.set_light_level(1.0)
	level.set_emergency(0.0)

func _process(delta: float) -> void:
	if level:
		level.set_light_level(light)
		level.set_emergency(emergency)
		level.update_lights(delta, cam.global_position)
		# As main.gd does every frame.
		env.ambient_light_color = level.ambient_color(emergency)
	env.ambient_light_energy = lerpf(0.12, 0.05, emergency) * maxf(light, emergency)
	env.background_color = Color(0.02, 0.025, 0.025) * light

# --- the same-shape check -------------------------------------------------------------------------

## Builds each floor (not drawn), dresses it and compares same-shaped rooms. Also: every floor's real
## lights (main and emergency) within the renderer's limit, and the blackout's ambient light never red
## in the Annex (red no higher than green at any emergency level) while the Clinic's stays red.
## Returns the problems.
static func check_floors(floors: Array) -> Dictionary:
	var problems: Array[String] = []
	var groups := 0
	var compared := 0
	var props := 0
	var max_lights := 0
	for f: Array in floors:
		var lv := Level.new()
		lv.build(annex_plan(str(f[0]), int(f[1])), str(f[0]))
		var v: AnnexView = lv.get_meta("annex")
		var stats := {}
		for p: String in v.same_shape_problems(stats):
			problems.append("%s/%d: %s" % [f[0], f[1], p])
		groups += int(stats.groups)
		compared += int(stats.rooms_compared)
		props += int(stats.props)
		var lights := lv.main_lights.size() + lv.emergency_lights.size()
		max_lights = maxi(max_lights, lights)
		if lights > AnnexView.LIGHT_LIMIT:
			problems.append("%s/%d: %d lights (%d main, %d emergency), over the limit of %d" % [f[0], f[1], lights, lv.main_lights.size(), lv.emergency_lights.size(), AnnexView.LIGHT_LIMIT])
		for k: float in [0.25, 0.5, 0.75, 1.0]:
			var c := lv.ambient_color(k)
			if c.r > c.g:
				problems.append("%s/%d: the blackout ambient is red at emergency %.2f (%s)" % [f[0], f[1], k, c])
				break
		lv.free()
	var clinic := Level.new()
	clinic.props_on = false
	clinic.build(clinic_plan("look-0", 1), "look-0")
	var cc := clinic.ambient_color(1.0)
	if not cc.is_equal_approx(Color(0.5, 0.08, 0.03)) or not clinic.ambient_color(0.0).is_equal_approx(Color(0.55, 0.6, 0.6)):
		problems.append("the Clinic's ambient changed: %s lit, %s in the blackout" % [clinic.ambient_color(0.0), cc])
	clinic.free()
	return {"floors": floors.size(), "groups": groups, "rooms_compared": compared, "props": props, "max_lights": max_lights, "problems": problems}

# --- pictures -------------------------------------------------------------------------------------

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _look(from: Vector3, to: Vector3) -> void:
	cam.position = from
	cam.look_at(to, Vector3.UP)

func _grab() -> Image:
	await _frames(4)
	return get_viewport().get_texture().get_image()

func _save(img: Image, shot_name: String, what: String) -> void:
	var path := shots_dir.path_join(shot_name + ".png")
	var err := img.save_png(path)
	shot_lines.append("%s.png %s: %s" % [shot_name, "ok" if err == OK else "FAILED", what])

func _shot(shot_name: String, what: String) -> void:
	var img: Image = await _grab()
	_save(img, shot_name, what)

func _junction_view() -> Dictionary:
	var best: Dictionary = {}
	var best_d := INF
	for j: Dictionary in view.junctions:
		if int(j.level) != 0:
			continue
		var cell: Vector2i = j.cell
		var arrow: Vector2i = j.arrow
		for a: Vector2i in j.exits:
			if a == arrow:
				continue
			var ok := true
			for i in range(1, 4):
				if level.kind(0, cell.x + a.x * i, cell.y + a.y * i) != "corridor":
					ok = false
			# Four ways before three, then nearest the middle.
			var d := Vector2(cell).distance_to(view.centre) + (0.0 if (j.exits as Array).size() >= 4 else 100.0)
			if ok and d < best_d:
				best_d = d
				# Look a little toward a side way, the sign's way if it is one.
				var side := Vector2i(-a.y, a.x)
				if arrow != -a:
					side = arrow
				elif not (j.exits as Array).has(side):
					side = -side
				best = {"cell": cell, "a": a, "side": side}
	return best

func _room_view(r: Dictionary, sh: AnnexView.Shape) -> Array[Vector3]:
	var xf := AnnexView.room_xf(r, sh.sym)
	var door := Vector2(sh.cw * S * 0.5, sh.ch * S)
	for f: Dictionary in sh.feats:
		if str(f.kind) == "door" and not f.cell:
			door = f.m
			break
	var cwm := sh.cw * S
	var chm := sh.ch * S
	var inward := Vector2(cwm, chm) * 0.5 - door
	inward = inward.normalized()
	var from := door + inward * 0.5
	var to := Vector2(cwm, chm) * 0.5 + inward * 1.0
	return [xf * Vector3(from.x, EYE, from.y), xf * Vector3(to.x, 0.8, to.y)]

func _pictures() -> void:
	DirAccess.make_dir_recursive_absolute(shots_dir)
	await _frames(10)
	# 1. A corridor junction, its LIFT sign facing us.
	var jv := _junction_view()
	if not jv.is_empty():
		var jc := level.cell_center(0, (jv.cell as Vector2i).x, (jv.cell as Vector2i).y)
		var a: Vector2i = jv.a
		var side: Vector2i = jv.side
		_look(jc + Vector3(a.x, 0, a.y) * S * 2.2 + Vector3(0, EYE, 0), jc + Vector3(side.x, 0, side.y) * S * 1.2 + Vector3(0, EYE - 0.1, 0))
		await _shot("junction", "a junction near the middle, from two cells up one way, looking toward a side way")
	# 2. A LIFT sign close up.
	for s: Dictionary in view.signs:
		if int(s.level) == 0:
			var p: Vector3 = s.pos
			var f: Vector3 = s.facing
			_look(p + f * 2.2 + Vector3(0, EYE - p.y, 0), p)
			await _shot("sign", "a hanging LIFT sign (%s), 2.2 m away" % s.arrow)
			break
	# 3. Two rooms of the same shape in different places, side by side.
	var pair := _same_shape_pair()
	if not pair.is_empty():
		var imgs: Array[Image] = []
		for r: Dictionary in pair.rooms:
			var sh: AnnexView.Shape = view.shapes[int(r.id)]
			var v := _room_view(r, sh)
			_look(v[0], v[1])
			var img: Image = await _grab()
			imgs.append(img)
			_save(img, "same_shape_%d" % imgs.size(), "%s room %d at cells %d,%d level %d" % [r.kind, int(r.id), int(r.x), int(r.y), int(r.level)])
		var w := imgs[0].get_width()
		var h := imgs[0].get_height()
		var both := Image.create(w * 2 + 8, h, false, imgs[0].get_format())
		both.fill(Color.BLACK)
		both.blit_rect(imgs[0], Rect2i(0, 0, w, h), Vector2i(0, 0))
		both.blit_rect(imgs[1], Rect2i(0, 0, w, h), Vector2i(w + 8, 0))
		_save(both, "same_shape_pair", "the two %s rooms side by side, the same view in each room's own frame" % (pair.rooms as Array)[0].kind)
	# 4. An office: a desk, its CRT and chair.
	for rec: Dictionary in view.records:
		if str(rec.type) == "workstation":
			var r: Dictionary = level.plan.rooms[int(rec.room)]
			if str(r.kind) != "office":
				continue
			var xf: Transform3D = rec.xf
			var front := xf.basis * Vector3.FORWARD
			_look(xf.origin + front * 2.1 + xf.basis.x * 0.6 + Vector3(0, EYE, 0), xf.origin + Vector3(0, 0.8, 0) - front * 0.3)
			await _shot("office", "an office desk with its monitor, keyboard and chair")
			break
	# 5. Other rooms from their doors.
	for kind: String in ["cubicles", "meeting", "copy", "break", "lobby"]:
		for r: Dictionary in level.plan.rooms:
			if str(r.kind) == kind:
				var v := _room_view(r, view.shapes[int(r.id)])
				_look(v[0], v[1])
				await _shot("room_" + kind, "a %s room from its door" % kind)
				break
	# 6. The atrium from the balcony above.
	var at := _balcony_view()
	if not at.is_empty():
		_look(at.from, at.to)
		await _shot("atrium_from_upper", "the atrium seen from the level-1 balcony")
	# 7. A stair, from below and from the top.
	if (level.plan.stairs as Array).size() > 0:
		var s: Dictionary = level.plan.stairs[0]
		var d := level._dir_vec(str(s.dir))
		var fwd := Vector3(d.x, 0, d.y)
		var c0 := level.cell_center(0, int(s.x), int(s.y)) - fwd * (S * 0.5)
		var top := c0 + fwd * (int(s.length) * S)
		_look(c0 - fwd * 3.2 + Vector3(0, EYE, 0), top + Vector3(0, LH + 0.8, 0))
		await _shot("stair_up", "a stair from the corridor at its foot")
		_look(top + fwd * 1.6 + Vector3(0, LH + EYE, 0), c0 + Vector3(0, 0.6, 0))
		await _shot("stair_down", "the same stair from its head on level 1")
	# 8. The longest straight corridor.
	var best: Dictionary = {}
	for sl: Dictionary in level.plan.sightlines:
		if int(sl.level) == 0 and (best.is_empty() or int(sl.length) > int(best.length)):
			best = sl
	if not best.is_empty():
		var p1 := level.cell_center(0, int(best.x1), int(best.y1))
		var p2 := level.cell_center(0, int(best.x2), int(best.y2))
		_look(p1 + Vector3(0, EYE, 0), p2 + Vector3(0, EYE, 0))
		await _shot("corridor_long", "the longest straight view on level 0 (%d cells)" % int(best.length))
	# 9. The blackout: every panel off, the green emergency lighting on.
	if not jv.is_empty():
		var jc := level.cell_center(0, (jv.cell as Vector2i).x, (jv.cell as Vector2i).y)
		var a: Vector2i = jv.a
		var side: Vector2i = jv.side
		_look(jc + Vector3(a.x, 0, a.y) * S * 2.2 + Vector3(0, EYE, 0), jc + Vector3(side.x, 0, side.y) * S * 1.2 + Vector3(0, EYE - 0.1, 0))
		light = 0.0
		emergency = 1.0
		await _frames(6)
		await _shot("blackout_junction", "the same junction in the blackout: green signs, battery spotlight")
		light = 1.0
		emergency = 0.0
		await _frames(4)

func _same_shape_pair() -> Dictionary:
	var by_key := {}
	for r: Dictionary in level.plan.rooms:
		var sh: AnnexView.Shape = view.shapes[int(r.id)]
		if not by_key.has(sh.key):
			by_key[sh.key] = []
		(by_key[sh.key] as Array).append(r)
	var best: Dictionary = {}
	var best_score := -1.0
	for key: String in by_key:
		var rooms: Array = by_key[key]
		for i in rooms.size():
			for j in range(i + 1, rooms.size()):
				var a: Dictionary = rooms[i]
				var b: Dictionary = rooms[j]
				var sa: AnnexView.Shape = view.shapes[int(a.id)]
				var sb: AnnexView.Shape = view.shapes[int(b.id)]
				# The same handedness, so the two pictures match without a mirror.
				var same_hand := (AnnexView.room_xf(a, sa.sym).basis.determinant() > 0) == (AnnexView.room_xf(b, sb.sym).basis.determinant() > 0)
				if not same_hand or int(a.level) != int(b.level):
					continue
				var score := Vector2(int(a.x), int(a.y)).distance_to(Vector2(int(b.x), int(b.y)))
				if str(a.kind) == "office":
					score += 100.0
				if score > best_score:
					best_score = score
					best = {"rooms": [a, b]}
	return best

func _balcony_view() -> Dictionary:
	for r: Dictionary in level.plan.rooms:
		if str(r.kind) != "atrium":
			continue
		var c := Vector3((int(r.x) + int(r.w) * 0.5) * S, 0, (int(r.y) + int(r.h) * 0.5) * S)
		# The level-1 corridor cell beside the middle of the opening's side, furthest from the lift.
		var best := Vector2i(-1, -1)
		var best_d := INF
		for y in range(int(r.y) - 1, int(r.y) + int(r.h) + 1):
			for x in range(int(r.x) - 1, int(r.x) + int(r.w) + 1):
				if level.kind(1, x, y) != "corridor":
					continue
				var d := Vector2(x + 0.5, y + 0.5).distance_to(Vector2(c.x, c.z) / S)
				if d < best_d:
					best_d = d
					best = Vector2i(x, y)
		if best.x < 0:
			continue
		var p := level.cell_center(1, best.x, best.y)
		var out := Vector3(p.x - c.x, 0, p.z - c.z).normalized()
		return {"from": p - out * 0.45 + Vector3(0, EYE, 0), "to": c - out * 1.5}
	return {}

# --- frame times ------------------------------------------------------------------------------

## A walk on level 0 from the landing to the farthest corridor cell (breadth first over open edges
## and doors), as cell centres.
func _route() -> Array[Vector3]:
	var w := level.W
	var h := level.H
	var start := Vector2i(level.landing.y, level.landing.z)
	var prev := {start: start}
	var queue: Array[Vector2i] = [start]
	var last := start
	var qi := 0
	while qi < queue.size():
		var c := queue[qi]
		qi += 1
		if level.kind(0, c.x, c.y) == "corridor":
			last = c
		for d: Vector2i in AnnexView.DIRS:
			var n := c + d
			if n.x < 0 or n.y < 0 or n.x >= w or n.y >= h or prev.has(n):
				continue
			if not level.walkable(0, n.x, n.y) or level.kind(0, n.x, n.y) == "stair":
				continue
			var e := _edge(c, d)
			if e != "open" and e != "door":
				continue
			prev[n] = c
			queue.append(n)
	var path: Array[Vector3] = []
	var at := last
	while at != start:
		path.push_front(level.cell_center(0, at.x, at.y) + Vector3(0, EYE, 0))
		at = prev[at]
	path.push_front(level.cell_center(0, start.x, start.y) + Vector3(0, EYE, 0))
	return path

func _edge(c: Vector2i, d: Vector2i) -> String:
	var vert: Array = level.edges[0].vertical
	var hor: Array = level.edges[0].horizontal
	var w := level.W
	if d == Vector2i(0, -1): return hor[c.y * w + c.x]
	if d == Vector2i(0, 1): return hor[(c.y + 1) * w + c.x]
	if d == Vector2i(-1, 0): return vert[c.y * (w + 1) + c.x]
	return vert[c.y * (w + 1) + c.x + 1]

## Walks the route for `secs` at 3 m/s (back again at the end) and returns the frame times in ms.
func _walk(secs: float) -> PackedFloat64Array:
	var path := _route()
	var times := PackedFloat64Array()
	var dist := 0.0
	var total := 0.0
	for i in range(1, path.size()):
		total += path[i].distance_to(path[i - 1])
	var t_end := Time.get_ticks_usec() + int((secs + 1.0) * 1e6)
	var t_warm := Time.get_ticks_usec() + 1000000
	var last := Time.get_ticks_usec()
	var yaw := 0.0
	var first := true
	while Time.get_ticks_usec() < t_end:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var dt := (now - last) / 1e6
		last = now
		if now > t_warm:
			times.append(dt * 1000.0)
		dist += 3.0 * minf(dt, 0.1)
		var along := fmod(dist, 2.0 * total)
		if along > total:
			along = 2.0 * total - along
		var pos := path[0]
		var ahead := path[path.size() - 1]
		var acc := 0.0
		for i in range(1, path.size()):
			var seg := path[i].distance_to(path[i - 1])
			if acc + seg >= along:
				var k := (along - acc) / maxf(seg, 0.001)
				pos = path[i - 1].lerp(path[i], k)
				ahead = path[mini(i + 1, path.size() - 1)]
				break
			acc += seg
		var dir := ahead - pos
		var want := atan2(-dir.x, -dir.z) if dir.length() > 0.01 else yaw
		yaw = want if first else lerp_angle(yaw, want, minf(1.0, dt * 4.0))
		first = false
		cam.position = pos
		cam.rotation = Vector3(-0.05, yaw, 0)
	return times

static func summary(times: PackedFloat64Array) -> Dictionary:
	var sorted := times.duplicate()
	sorted.sort()
	var sum := 0.0
	for t in times:
		sum += t
	var n := maxi(times.size(), 1)
	return {"frames": times.size(), "mean_ms": sum / n, "p95_ms": sorted[mini(int(n * 0.95), sorted.size() - 1)] if sorted.size() > 0 else 0.0,
		"max_ms": sorted[sorted.size() - 1] if sorted.size() > 0 else 0.0}

func _bench() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var all := {"annex": PackedFloat64Array(), "clinic": PackedFloat64Array()}
	var info := {}
	for r in rounds:
		for place: String in ["annex", "clinic"]:
			_build(annex_plan(seed_text, depth) if place == "annex" else clinic_plan(seed_text, depth))
			await _frames(5)
			var times: PackedFloat64Array = await _walk(bench)
			var sofar: PackedFloat64Array = all[place]
			sofar.append_array(times)
			all[place] = sofar
			info[place] = {"lights": level.main_lights.size(), "emergency_lights": level.emergency_lights.size(), "props": level.props_placed,
				"draw_calls": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
				"primitives": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)}
			var s := summary(times)
			print("annex demo: bench round %d %s: %d frames, mean %.2f ms, p95 %.2f ms" % [r + 1, place, s.frames, s.mean_ms, s.p95_ms])
	for place: String in ["annex", "clinic"]:
		var s := summary(all[place])
		s.merge(info[place])
		report["bench_" + place] = s
		print("annex demo: bench %s: %d frames, mean %.2f ms, p95 %.2f ms, max %.2f ms; %d lights, %d draw calls, %d primitives" % [place, s.frames, s.mean_ms, s.p95_ms, s.max_ms, s.lights, s.draw_calls, s.primitives])

func _run() -> void:
	var t0 := Time.get_ticks_msec()
	_build(annex_plan(seed_text, depth))
	report["build_ms"] = Time.get_ticks_msec() - t0
	report["seed"] = seed_text
	report["depth"] = depth
	print("annex demo: floor %s depth %d built in %d ms: %d lights, %d emergency lights, %d props, %d signs, %d junctions" % [
		seed_text, depth, report.build_ms, level.main_lights.size(), level.emergency_lights.size(), level.props_placed, view.signs.size(), view.junctions.size()])
	# The check: same-shaped rooms dressed alike, on this floor and twelve more.
	var floors: Array = [[seed_text, depth]]
	for i in 3:
		for d in range(1, 5):
			floors.append(["look-%d" % i, d])
	var chk := check_floors(floors)
	report["check"] = chk
	var problems: Array = chk.problems
	print("annex demo: same-shape check %s: %d floors, %d shapes seen more than once, %d rooms compared, %d props and pictures" % [
		"PASS" if problems.is_empty() else "FAIL", chk.floors, chk.groups, chk.rooms_compared, chk.props])
	for p: String in problems.slice(0, 12):
		print("annex demo:   ", p)
	await _pictures()
	report["shots"] = shot_lines
	for l in shot_lines:
		print("annex demo: shot ", l)
	if bench > 0.0:
		await _bench()
	print("annex demo json: ", JSON.stringify(report))
	get_tree().quit(0 if problems.is_empty() else 1)
