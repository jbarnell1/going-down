# The Temp (client/temp_view.gd) in the game's own picture, on a seeded Annex floor built by Level,
# and its checks. It renders, so it runs in a window (it never captures the mouse):
#   Godot --path godot --resolution 960x540 res://client/temp_demo.tscn -- shots=DIR [seed=annex-1]
#   [depth=3] [bench=3] [break=walk]
# tools/temp_check.mjs runs it and reads the result. Every check prints "temp demo: CHECK <name> PASS|FAIL
# ..." and the last line is "temp demo json: {...}"; the exit code is 0 only when all pass.
#   face    the paper shows the seeded crewmate's drawing: the index picked is hash(seed + ":temp") mod
#           the crew in join order, and the picture on the paper hashes to the photocopy of exactly the
#           face that crewmate sent; with no faces (or that one sent none), the blank face.
#   hold    a Stillness resident: on every frame the camera sees it (the Orderly's rule,
#           net/pose.gd camera_sees) and saw it the frame before, the drawn figure is unchanged. Not
#           vacuous: it was seen on many such frames, and it walked and was drawn moving while unseen.
#   clicks  one per 1.2 m walked, one each 4 s standing unseen, none on a frame it is seen.
#   height  about 1.8 m (1.7 to 1.9).
#   frames  frame time with the Temp in view within the same view without it (10 % and 0.5 ms).
# break=walk makes the view advance its walk on the local clock (temp_view.gd break_walk_while_seen):
# the hold check must go red.
extends Node

const Annex = preload("res://sim/annex.gd")
const Run = preload("res://sim/run.gd")
const Move = preload("res://sim/move.gd")
const Floor = preload("res://sim/floor.gd")
const Pose = preload("res://net/pose.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const Rng = preload("res://sim/rng.gd")
const VFOV := 70.0
const EYE := 1.65
const S := 2.0
const WALK_SPEED := 1.5

var sub: SubViewport
var cam: Camera3D
var world: Node3D
var env: Environment
var screen: TextureRect
var tape: ShaderMaterial
var level: Level
var lift: Lift
var temp: TempView
var fp: Floor.FloorPlan
var car: Run.CarGeometry
var shots_dir := "user://temp_shots"
var seed_text := "annex-1"
var depth := 3
var bench := 3.0
var broken := false
var faces: Array[String] = []
var report := {}
var checks := {}
var shot_lines: Array[String] = []
var problems: Array[String] = []

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
			"break": broken = val == "walk"
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	AudioServer.set_bus_volume_db(0, -18.0)
	_build_view()
	_run.call_deferred()

func _build_view() -> void:
	sub = SubViewport.new()
	sub.size = Vector2i(480, 270)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sub.msaa_3d = Viewport.MSAA_DISABLED
	sub.positional_shadow_atlas_size = 2048
	sub.audio_listener_enable_3d = true
	add_child(sub)
	get_viewport().disable_3d = true
	# The game's own environment (main.gd _build_view).
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
	screen = TextureRect.new()
	screen.texture = sub.get_texture()
	screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	screen.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	screen.stretch_mode = TextureRect.STRETCH_SCALE
	screen.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	tape = ShaderMaterial.new()
	tape.shader = load("res://client/tape.gdshader")
	screen.material = tape
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(screen)

func _build() -> void:
	fp = Annex.generate_annex(seed_text, depth)
	car = Run.car_geometry(fp)
	var plan := PlanDump.dump(fp, car)
	level = Level.new()
	level.shadows = true
	world.add_child(level)
	level.build(plan, seed_text)
	lift = Lift.new()
	world.add_child(lift)
	lift.build(plan["car"])
	lift.set_doors(false, true)
	level.set_light_level(1.0)
	level.set_emergency(0.0)
	env.ambient_light_color = level.ambient_color(0.0)
	temp = TempView.new()
	temp.name = "Temp"
	sub.add_child(temp)
	temp.set_crew(seed_text, faces)
	temp.set_floor(fp, level)

func _process(delta: float) -> void:
	if level:
		level.update_lights(delta, cam.global_position)

# --- helpers --------------------------------------------------------------------------------------

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _grab() -> Image:
	await _frames(4)
	return get_viewport().get_texture().get_image()

func _shot(shot_name: String, what: String) -> void:
	var img: Image = await _grab()
	var path := shots_dir.path_join(shot_name + ".png")
	var err := img.save_png(path)
	shot_lines.append("%s.png %s: %s" % [shot_name, "ok" if err == OK else "FAILED", what])

## The same view without the tape, at twice the size, to judge the figure itself.
func _clean_shot(shot_name: String, what: String) -> void:
	sub.size = Vector2i(960, 540)
	screen.material = null
	await _shot(shot_name, what)
	sub.size = Vector2i(480, 270)
	screen.material = tape

func _pose(p: Vector3, yaw: float, anim: String, t: float) -> Dictionary:
	return Pose.quant_pose({"x": p.x, "y": p.y, "z": p.z, "level": 0, "yaw": yaw, "anim": anim, "animTime": t})

static func _yaw_toward(d: Vector3) -> float:
	return atan2(-d.x, -d.z)

func _look(from: Vector3, to: Vector3) -> void:
	cam.position = from
	cam.look_at(to, Vector3.UP)

func _sees(pose: Dictionary) -> bool:
	var aspect := float(sub.size.x) / float(sub.size.y)
	var hfov := rad_to_deg(2.0 * atan(tan(deg_to_rad(VFOV) * 0.5) * aspect))
	var body := Move.Body.make(cam.position.x, cam.position.z, 0, 0.0)
	var c := Pose.Camera.make(body, cam.position.y, cam.rotation.y, cam.rotation.x, hfov, VFOV)
	return Pose.camera_sees(fp, car, c, pose, false)

func _check(name: String, ok: bool, line: String) -> void:
	checks[name] = {"pass": ok, "line": line}
	print("temp demo: CHECK %s %s %s" % [name, "PASS" if ok else "FAIL", line])
	if not ok:
		problems.append(name + ": " + line)

## The longest straight corridor on level 0: its two end cells' centres.
func _corridor() -> Array[Vector3]:
	var best: Dictionary = {}
	for sl: Dictionary in level.plan.sightlines:
		if int(sl.level) == 0 and (best.is_empty() or int(sl.length) > int(best.length)):
			best = sl
	return [level.cell_center(0, int(best.x1), int(best.y1)), level.cell_center(0, int(best.x2), int(best.y2))]

# --- the checks -----------------------------------------------------------------------------------

func _face_check() -> void:
	var want := Rng.hash_seed(seed_text + ":temp") % faces.size()
	var sent := CrewView.image_hash(FaceCodec.to_image(FaceCodec.decode_indices(faces[want])))
	var copy := CrewView.image_hash(TempView.photocopy(FaceCodec.to_image(FaceCodec.decode_indices(faces[want])), seed_text))
	var ok := temp.picked == want and CrewView.image_hash(temp.face_source) == sent and temp.paper_hash() == copy
	# Every other crewmate's copy differs from the one shown (so the hash says whose face it is).
	for i in faces.size():
		if i != want and CrewView.image_hash(TempView.photocopy(FaceCodec.to_image(FaceCodec.decode_indices(faces[i])), seed_text)) == temp.paper_hash():
			ok = false
	# No faces, and a crewmate who drew none: the blank face.
	var blank := CrewView.image_hash(TempView.blank_face())
	var t0 := TempView.new()
	t0.set_crew(seed_text, [] as Array[String])
	var none_ok := t0.picked == -1 and CrewView.image_hash(t0.face_source) == blank
	t0.set_crew(seed_text, ["", "", ""] as Array[String])
	var empty_ok := CrewView.image_hash(t0.face_source) == blank
	t0.free()
	# Other seeds pick across the crew (the pick is the seed's, not a constant).
	var seen := {}
	for i in 30:
		seen[TempView.pick_index("pick-%d" % i, 3)] = true
	report["face"] = {"picked": temp.picked, "want": want, "sent_hash": sent, "paper_hash": temp.paper_hash(), "copy_hash": copy, "picks_over_30_seeds": seen.size()}
	_check("face", ok and none_ok and empty_ok and seen.size() == 3,
		"crewmate %d of %d (want %d): sent %s, on the paper %s (photocopy of it %s); blank with no faces %s, with empty faces %s; 30 seeds pick %d of 3" % [
		temp.picked, faces.size(), want, sent, temp.paper_hash(), copy, none_ok, empty_ok, seen.size()])

## The walk and the stand: the Temp walks the corridor toward the camera and back while the camera
## looks at it and away; when the camera sees the drawn pose the host's resident does not move
## (Stillness) and the screen holds it. Then it stands, unseen and seen.
func _hold_and_clicks() -> void:
	var ends := _corridor()
	var a := ends[0]
	var b := ends[1]
	var dir := (b - a).normalized()
	var length := a.distance_to(b)
	var eye := a - dir * 0.6 + Vector3(0, EYE, 0)
	var look_down := _yaw_toward(dir)
	temp.reset()
	temp.clicks.clear()
	var along := length - 0.5
	var heading := -1.0
	var sim_t := 0.0
	var drawn: Dictionary = {}
	var prev_seen := false
	var prev_sig := ""
	var pairs := 0
	var moves := 0
	var moved_unseen := 0
	var seen_frames := 0
	var clicks_seen := 0
	var walked := 0.0
	var last_p := Vector3.INF
	var t := 0.0
	var phase := "walk"
	var stand_unseen := {"time": 0.0, "clicks": 0}
	var stand_seen := {"time": 0.0, "clicks": 0}
	var walk_clicks := 0
	var walk_stand_clicks := 0
	var walk_len := 22.0
	var stand_len := 9.5
	var seen_len := 5.0
	while t < walk_len + stand_len + seen_len:
		await get_tree().process_frame
		var dt := 1.0 / 60.0
		t += dt
		var anim := "walk"
		var yaw := cam.rotation.y
		if t < walk_len:
			# Look down the corridor for 1.6 s, then away for 1.4 s.
			yaw = look_down if fmod(t, 3.0) < 1.6 else look_down + PI * 0.75
		elif t < walk_len + stand_len:
			phase = "stand_unseen"
			anim = "idle"
			yaw = look_down + PI * 0.75
		else:
			phase = "stand_seen"
			anim = "idle"
			yaw = look_down
		cam.position = eye
		cam.rotation = Vector3(-0.04, yaw, 0)
		var seen := not drawn.is_empty() and _sees(drawn)
		if not seen:
			# The host's resident moves only while nobody sees it.
			if anim == "walk":
				along += heading * WALK_SPEED * dt
				if along < 3.0:
					heading = 1.0
				elif along > length - 0.3:
					heading = -1.0
			sim_t += dt
			var p := a + dir * along
			drawn = _pose(p, _yaw_toward(dir * heading), anim, sim_t)
			seen = _sees(drawn)
		var before := temp.clicks.size()
		temp.show_pose(drawn, true)
		var sig := temp.drawn_signature()
		var p2 := Vector3(float(drawn["x"]), 0, float(drawn["z"]))
		if last_p != Vector3.INF and p2.distance_to(last_p) < 1.0:
			walked += p2.distance_to(last_p)
		last_p = p2
		var new_clicks := temp.clicks.slice(before)
		if seen:
			seen_frames += 1
			clicks_seen += new_clicks.size()
		if seen and prev_seen:
			pairs += 1
			if sig != prev_sig:
				moves += 1
		elif not seen and sig != prev_sig and prev_sig != "":
			moved_unseen += 1
		for c: Dictionary in new_clicks:
			match phase:
				"walk":
					if str(c["why"]) == "walk":
						walk_clicks += 1
					else:
						walk_stand_clicks += 1
				"stand_unseen":
					stand_unseen["clicks"] += 1
				"stand_seen":
					stand_seen["clicks"] += 1
		match phase:
			"stand_unseen":
				stand_unseen["time"] += dt
			"stand_seen":
				stand_seen["time"] += dt
		prev_seen = seen
		prev_sig = sig
	var walk_want := floori(walked / TempView.CLICK_STEP)
	report["hold"] = {"pairs": pairs, "moves": moves, "seen_frames": seen_frames, "moved_unseen": moved_unseen, "broken": broken}
	report["clicks"] = {"walked_m": walked, "walk_clicks": walk_clicks, "walk_want": walk_want, "stand_clicks_while_walking": walk_stand_clicks,
		"stand_unseen": stand_unseen, "stand_seen": stand_seen, "clicks_on_seen_frames": clicks_seen,
		"gains": temp.clicks.map(func(c: Dictionary) -> float: return snappedf(float(c["gain"]), 0.01))}
	_check("hold", moves == 0 and pairs >= 60 and moved_unseen >= 60,
		"%d of %d frames seen twice running changed the drawn figure; drawn moving on %d unseen frames" % [moves, pairs, moved_unseen])
	var stand_want := floori(float(stand_unseen["time"]) / TempView.STAND_CLICK)
	_check("clicks", absi(walk_clicks - walk_want) <= 1 and walk_want >= 5 and walk_stand_clicks == 0
		and absi(int(stand_unseen["clicks"]) - stand_want) <= 1 and int(stand_unseen["clicks"]) >= 1 and int(stand_seen["clicks"]) == 0 and clicks_seen == 0,
		"walked %.1f m: %d walk clicks (want %d); standing unseen %.1f s: %d clicks (want %d); standing seen %.1f s: %d; on seen frames: %d" % [
		walked, walk_clicks, walk_want, stand_unseen["time"], stand_unseen["clicks"], stand_want, stand_seen["time"], stand_seen["clicks"], clicks_seen])

# --- pictures ---------------------------------------------------------------------------------

func _pictures() -> void:
	DirAccess.make_dir_recursive_absolute(shots_dir)
	var ends := _corridor()
	var a := ends[0]
	var b := ends[1]
	var dir := (b - a).normalized()
	var side := Vector3(-dir.z, 0, dir.x)
	var stand := a + dir * 4.5
	temp.reset()
	# Front: standing, facing us, 2.1 m away.
	temp.show_pose(_pose(stand, _yaw_toward(-dir), "idle", 1.0), true)
	_look(stand - dir * 2.1 + Vector3(0, EYE, 0), stand + Vector3(0, 1.3, 0))
	await _shot("front", "front, standing idle, 2.1 m, through the tape")
	await _clean_shot("front_clean", "front, standing idle, 2.1 m, no tape, 960x540")
	# Three-quarter: turned 40 degrees, 2.3 m.
	temp.reset()
	temp.show_pose(_pose(stand, _yaw_toward(-dir.rotated(Vector3.UP, deg_to_rad(40.0))), "idle", 2.4), true)
	_look(stand - dir * 2.3 + side * 0.25 + Vector3(0, EYE, 0), stand + Vector3(0, 1.25, 0))
	await _shot("three_quarter", "three-quarter, turned 40 degrees, looking down at its stapler, 2.3 m, through the tape")
	await _clean_shot("three_quarter_clean", "three-quarter, no tape, 960x540")
	# From behind, turned a little: the hair, the sheet's edges and its plain back.
	temp.reset()
	temp.show_pose(_pose(stand, _yaw_toward(dir.rotated(Vector3.UP, deg_to_rad(-25.0))), "idle", 1.0), true)
	_look(stand - dir * 2.0 + Vector3(0, EYE, 0), stand + Vector3(0, 1.3, 0))
	await _clean_shot("back_clean", "from behind, turned 25 degrees, no tape")
	# Close on the paper.
	temp.reset()
	temp.show_pose(_pose(stand, _yaw_toward(-dir), "idle", 1.0), true)
	_look(stand - dir * 0.75 + Vector3(0, 1.68, 0), stand + Vector3(0, 1.64, 0))
	await _clean_shot("paper_close", "the paper face from 0.75 m, no tape")
	# Mid-stride, side-on.
	temp.reset()
	var w0 := stand - dir * 1.0
	for i in 8:
		temp.show_pose(_pose(w0 + dir * (0.1 * i), _yaw_toward(dir), "walk", 0.1 * i), true)
	temp.show_pose(_pose(w0 + dir * 1.15, _yaw_toward(dir), "walk", 1.0), true)
	_look(stand - dir * 2.6 + side * 0.3 + Vector3(0, EYE, 0), stand + Vector3(0, 1.1, 0))
	await _shot("walk", "walking away from us, mid-stride")
	await _clean_shot("walk_clean", "walking, no tape")
	# The reach.
	temp.reset()
	temp.show_pose(_pose(stand, _yaw_toward(-dir), "reach", 0.55), true)
	_look(stand - dir * 1.5 + Vector3(0, EYE, 0), stand + Vector3(0, 1.4, 0))
	await _shot("reach", "the reach: leaning in with the stapler open, 1.5 m")
	# In the corridor at 6 m.
	temp.reset()
	var far := a + dir * 6.6
	temp.show_pose(_pose(far, _yaw_toward(-dir), "idle", 1.0), true)
	_look(a + dir * 0.6 + Vector3(0, EYE, 0), far + Vector3(0, 1.3, 0))
	await _shot("corridor_6m", "in an Annex corridor, 6 m away, through the tape")

## Frame time with the Temp in view, and the same view with it hidden.
func _bench() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var ends := _corridor()
	var a := ends[0]
	var dir := (ends[1] - a).normalized()
	var at := a + dir * 4.0
	temp.reset()
	temp.show_pose(_pose(at, _yaw_toward(-dir), "idle", 1.0), true)
	_look(a + dir * 0.6 + Vector3(0, EYE, 0), at + Vector3(0, 1.2, 0))
	var res := {}
	for r in 2:
		for which: String in ["with", "without"]:
			temp.visible = which == "with"
			await _frames(10)
			var times := PackedFloat64Array()
			var last := Time.get_ticks_usec()
			var t_end := last + int(bench * 1e6)
			while Time.get_ticks_usec() < t_end:
				await get_tree().process_frame
				var now := Time.get_ticks_usec()
				times.append((now - last) / 1000.0)
				last = now
			var prev: PackedFloat64Array = res.get(which, PackedFloat64Array())
			prev.append_array(times)
			res[which] = prev
	var m := {}
	for which: String in ["with", "without"]:
		var ts: PackedFloat64Array = res[which]
		var sum := 0.0
		for x in ts:
			sum += x
		var sorted := ts.duplicate()
		sorted.sort()
		m[which] = {"frames": ts.size(), "mean_ms": sum / maxi(ts.size(), 1), "p95_ms": sorted[int(sorted.size() * 0.95)] if sorted.size() > 0 else 0.0}
	report["frames"] = m
	var mw: Dictionary = m["with"]
	var mo: Dictionary = m["without"]
	var w: float = mw["mean_ms"]
	var wo: float = mo["mean_ms"]
	_check("frames", w <= wo * 1.10 + 0.5, "mean %.2f ms with the Temp in view, %.2f ms without (p95 %.2f vs %.2f)" % [w, wo, mw["p95_ms"], mo["p95_ms"]])
	temp.visible = true
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)

func _run() -> void:
	for f: String in FacePaint.STARTERS:
		faces.append(FaceCodec.encode(FacePaint.starter(f)))
	_build()
	await _frames(10)
	report["seed"] = seed_text
	report["depth"] = depth
	report["place"] = String(fp.place)
	_face_check()
	temp.reset()
	temp.show_pose(_pose(Vector3.ZERO, 0.0, "idle", 0.5), true)
	var hgt := temp.standing_height()
	report["height"] = hgt
	_check("height", hgt >= 1.7 and hgt <= 1.9, "%.3f m from the soles to the top of the paper" % hgt)
	temp.break_walk_while_seen = broken
	await _hold_and_clicks()
	temp.break_walk_while_seen = false
	if not broken:
		await _pictures()
		if bench > 0.0:
			await _bench()
	report["shots"] = shot_lines
	report["checks"] = checks
	report["problems"] = problems
	for l in shot_lines:
		print("temp demo: shot ", l)
	print("temp demo json: ", JSON.stringify(report))
	get_tree().quit(0 if problems.is_empty() else 1)
