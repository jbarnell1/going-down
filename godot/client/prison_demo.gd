# A look at the Prison hub without the day loop: the prison plan (sim/prison.gd) built by Level, which
# hands it to prison_view.gd, with the lift, in the game's own picture (480x270 through the tape shader,
# the desktop "full" quality: glow and shadows), in a window. It walks the rules' body from the lift to
# every bunk at walking pace and prints the times, takes pictures from fixed spots and checks them, and
# can measure frame times on a walk. `place=clinic` builds a Clinic floor instead, for comparison.
# Never captures the mouse. Run by godot/tools/prison_walk.mjs, or by hand from the repository root:
#   Godot --path godot --resolution 960x540 --position 40,40 -- scene=prison_demo [place=prison|clinic]
#     [shots=DIR] [bench=SECONDS] [seed=TEXT]
# `scene=prison_demo` makes main.gd change to this scene, so the exported game takes it too (a release
# build refuses a scene path): GoingDown.exe -- scene=prison_demo ...
# Prints one line per result, each starting "prison_demo:", and quits 1 if a picture check fails.
extends Node

const Floor = preload("res://sim/floor.gd")
const Follow = preload("res://sim/follow.gd")
const Move = preload("res://sim/move.gd")
const Run = preload("res://sim/run.gd")
const Stamina = preload("res://sim/stamina.gd")
const Prison = preload("res://sim/prison.gd")
const PrisonView = preload("res://client/prison_view.gd")
const FaceKiosk = preload("res://client/face_kiosk.gd")

const VFOV := 70.0
const EYE := 1.65
const DT := 1.0 / 60.0
## The picture checks. Mean brightness (0..1, Rec. 601 luma of the window as drawn) of the bank room
## facing the windows must reach BANK_MIN and be BANK_OVER_HALL times the corridor's; the cell picture
## must have at least ORANGE_MIN of its pixels night-light orange.
const BANK_MIN := 0.30
const BANK_OVER_HALL := 1.6
const ORANGE_MIN := 0.02

var place := "prison"
var seed_text := "alpha"
var shots_dir := ""
var bench_secs := 0.0
var sub: SubViewport
var cam: Camera3D
var world: Node3D
var level: Level
var lift: Lift
var fp: Floor.FloorPlan
var car: Run.CarGeometry
var failed := false
var hud: Hud
var kiosk: FaceKiosk
## The face "you" wear in the demo (it never reads or writes the player's saved face).
var my_face := ""
var _bench_on := false
var _bench_route: PackedVector3Array = PackedVector3Array()
var _bench_t := 0.0
var _bench_last_us := 0
var _frame_ms: PackedFloat32Array = PackedFloat32Array()

func _ready() -> void:
	shots_dir = ProjectSettings.globalize_path("res://").path_join("export/shots/prison")
	if OS.has_feature("template"):
		shots_dir = OS.get_executable_path().get_base_dir().path_join("../shots/prison").simplify_path()
	for raw in OS.get_cmdline_user_args():
		var a := raw.trim_prefix("--")
		var kv := a.split("=", true, 1)
		if kv.size() != 2:
			continue
		match kv[0]:
			"place": place = kv[1]
			"seed": seed_text = kv[1]
			"shots": shots_dir = kv[1]
			"bench": bench_secs = float(kv[1])
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if bench_secs > 0.0:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
	_build_view()
	if not _build_place():
		get_tree().quit(2)
		return
	_run.call_deferred()

func _build_view() -> void:
	sub = SubViewport.new()
	sub.size = Vector2i(480, 270)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sub.msaa_3d = Viewport.MSAA_DISABLED
	sub.positional_shadow_atlas_size = 2048
	add_child(sub)
	get_viewport().disable_3d = true
	# The same environment as main.gd at the desktop's "full" quality.
	var we := WorldEnvironment.new()
	var env := Environment.new()
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
	var tape_mat := ShaderMaterial.new()
	tape_mat.shader = load("res://client/tape.gdshader")
	screen.material = tape_mat
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(screen)
	# The prompt line (the game's HUD, its display off) and the face kiosk's editor over the picture.
	hud = Hud.new()
	hud.osd_on = false
	add_child(hud)
	kiosk = FaceKiosk.new()
	kiosk.name = "FaceKiosk"
	kiosk.remember = false
	add_child(kiosk)
	kiosk.changed.connect(_kiosk_changed)

func _build_place() -> bool:
	var plan: Dictionary
	if place == "prison":
		fp = Prison.prison_plan()
		plan = PrisonView.plain_plan()
		seed_text = "prison"
	else:
		var bridge := RulesBridge.new()
		add_child(bridge)
		if not bridge.open():
			push_error("rules not connected: " + bridge.error)
			return false
		bridge.start(seed_text, 1, false)
		plan = bridge.plan
		fp = bridge._run.plan
		bridge.close()
	car = Run.car_geometry(fp)
	level = Level.new()
	level.name = "Level"
	level.shadows = true
	level.props_on = true
	world.add_child(level)
	var t0 := Time.get_ticks_usec()
	level.build(plan, seed_text)
	var build_ms := (Time.get_ticks_usec() - t0) / 1000.0
	lift = Lift.new()
	lift.name = "Lift"
	world.add_child(lift)
	lift.build(plan["car"], level.lift_left_wall())
	lift.set_doors(true, true)
	level.set_emergency(0.0)
	level.set_light_level(1.0)
	_say("built %s ('%s') in %.1f ms: %d lights" % [place, seed_text, build_ms, level.main_lights.size()])
	return true

func _say(s: String) -> void:
	print("prison_demo: " + s)

# --- the stations: prompts and the face kiosk ---------------------------------------------------

func _view() -> PrisonView:
	if level == null or not level.has_meta(&"prison"):
		return null
	return level.get_meta(&"prison") as PrisonView

## The cell the camera stands in.
func _cam_cell() -> Vector2i:
	return Vector2i(floori(cam.position.x / Level.S), floori(cam.position.z / Level.S))

## The prompt line for where the camera stands (as the game shows it), hidden while the kiosk is open.
func _update_prompt() -> void:
	hud.prompt = "" if kiosk.is_open() or place != "prison" else PrisonView.prompt_for(_cam_cell())

## F: at the face kiosk, its editor opens on your face. The windows do nothing yet.
func _use() -> bool:
	if place != "prison" or kiosk.is_open() or Prison.station_at(_cam_cell()) != &"kiosk":
		return false
	kiosk.open(my_face)
	_update_prompt()
	return true

func _kiosk_changed(code: String) -> void:
	my_face = code
	var v := _view()
	if v != null:
		v.set_kiosk_face(code)

func _input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return
	var k := event as InputEventKey
	if kiosk.is_open():
		kiosk.key(k)
		get_viewport().set_input_as_handled()
	elif k.pressed and not k.echo and k.physical_keycode == KEY_F:
		_use()

func _process(delta: float) -> void:
	if level:
		level.update_lights(delta, cam.global_position)
	if lift:
		lift.update(delta)
	if _bench_on:
		var now := Time.get_ticks_usec()
		if _bench_last_us > 0:
			_frame_ms.append((now - _bench_last_us) / 1000.0)
		_bench_last_us = now
		_bench_t += delta
		_walk_cam(_bench_route, _bench_t)

# --- the rules' walk --------------------------------------------------------------------------

## The rules' body walking at walking pace from the middle of the lift car, out of the doors, to the
## middle of `target` (find_path and Follow, with the rules' collision), sampled every DT. Empty if stuck.
func _walk_route(target: Floor.Pos) -> PackedVector3Array:
	var out := PackedVector3Array()
	var body := Run.car_body(car, car.depth * 0.5, 0.0)
	var step := Stamina.WALK_SPEED * DT
	var land := fp.landing
	var lx := (land.x + 0.5) * fp.cell_size
	var lz := (land.y + 0.5) * fp.cell_size
	out.append(Vector3(body.x, body.y, body.z))
	for i in 600:
		var d := Vector2(lx - body.x, lz - body.z).length()
		if d <= 0.01:
			break
		var k := minf(step, d) / d
		body = Run._move_step(fp, car, true, body, (lx - body.x) * k, (lz - body.z) * k, RulesBridge.PLAYER_RADIUS)
		out.append(Vector3(body.x, body.y, body.z))
	var path := Floor.find_path(fp, land, target)
	if path.is_empty() and not (target.x == land.x and target.y == land.y):
		return PackedVector3Array()
	var walk := Follow.start_path_walk(path)
	var still := 0
	for i in 6000:
		if Follow.path_done(fp, walk, body):
			return out
		var before := Vector2(body.x, body.z)
		body = Follow.step_path_walk(fp, walk, body, step, RulesBridge.PLAYER_RADIUS)
		out.append(Vector3(body.x, body.y, body.z))
		still = still + 1 if Vector2(body.x, body.z).distance_to(before) < 1e-4 else 0
		if still > 60:
			break
	return PackedVector3Array()

func _seconds(route: PackedVector3Array) -> float:
	return (route.size() - 1) * DT

# The camera on a route at time t (walking pace, DT per sample), looking the way it walks; the route
# runs out and back.
func _walk_cam(route: PackedVector3Array, t: float) -> void:
	if route.size() < 2:
		return
	var n := route.size()
	var i := int(t / DT) % (2 * n - 2)
	var j := i if i < n else 2 * n - 2 - i
	var ahead := j + 20 if i < n else j - 20
	ahead = clampi(ahead, 0, n - 1)
	var p := route[j]
	var q := route[ahead]
	if p.distance_to(q) < 0.05:
		q = p + (-cam.global_basis.z)
	cam.position = p + Vector3(0, EYE, 0)
	cam.look_at(Vector3(q.x, p.y + EYE - 0.15, q.z), Vector3.UP)

func _walk_times() -> Array:
	var worst := 0.0
	var worst_n := 0
	var times: Array[String] = []
	var bunks := Prison.bunk_positions()
	for i in bunks.size():
		var b := bunks[i]
		var route := _walk_route(Floor.Pos.make(0, b.x, b.y))
		if route.is_empty():
			_say("walk to bunk %d: STUCK" % (i + 1))
			failed = true
			continue
		var s := _seconds(route)
		times.append("%d:%.2f" % [i + 1, s])
		if s > worst:
			worst = s
			worst_n = i + 1
	_say("walk from the middle of the lift car at %.1f m/s to each bunk's stand cell (s): %s" % [Stamina.WALK_SPEED, " ".join(times)])
	# The farthest bunk's own side: the back cell of its room, beside the bunk as drawn.
	var b := bunks[worst_n - 1]
	var back_y := b.y - (Prison.NORTH_ROWS.y - 1) if b.y == Prison.NORTH_ROWS.x + Prison.NORTH_ROWS.y - 1 else b.y + (Prison.SOUTH_ROWS.y - 1)
	var to_bed := _walk_route(Floor.Pos.make(0, b.x, back_y))
	var bed_s := _seconds(to_bed) if not to_bed.is_empty() else -1.0
	var verdict := "PASS" if worst < 10.0 and bed_s >= 0.0 and bed_s < 10.0 else "FAIL"
	if verdict == "FAIL":
		failed = true
	_say("walk lift to farthest bunk (bunk %d): %.2f s to its stand cell, %.2f s to the bunk as drawn; limit 10 s: %s" % [worst_n, worst, bed_s, verdict])
	return [worst_n, Floor.Pos.make(0, b.x, b.y)]

# --- pictures ---------------------------------------------------------------------------------

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _look(from: Vector3, to: Vector3) -> void:
	cam.position = from
	cam.look_at(to, Vector3.UP)

func _shot(shot_name: String) -> Image:
	await _frames(4)
	var img := get_viewport().get_texture().get_image()
	var path := shots_dir.path_join(shot_name + ".png")
	var err := img.save_png(path)
	_say("picture %s %s" % [path, "saved" if err == OK else "NOT SAVED"])
	return img

static func _mean_luma(img: Image) -> float:
	var sum := 0.0
	var n := 0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var c := img.get_pixel(x, y)
			sum += 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
			n += 1
	return sum / maxf(1.0, float(n))

static func _orange_share(img: Image) -> float:
	var hit := 0
	var n := 0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var c := img.get_pixel(x, y)
			if c.r > 0.35 and c.r > c.g * 1.35 and c.g > c.b * 1.1:
				hit += 1
			n += 1
	return float(hit) / maxf(1.0, float(n))

func _check(what: String, ok: bool, detail: String) -> void:
	_say("check %s: %s (%s)" % [what, "PASS" if ok else "FAIL", detail])
	if not ok:
		failed = true

func _prison_pictures() -> void:
	DirAccess.make_dir_recursive_absolute(shots_dir)
	var hall_z := (Prison.HALL_ROW + 0.5) * Level.S
	var far_x := (Prison.HALL_X1 + 0.5) * Level.S
	var door_x := car.door_x
	# 1. From the lift doors down the corridor.
	_look(Vector3(door_x + 0.35, EYE, hall_z), Vector3(far_x + 4.0, EYE - 0.2, hall_z))
	var hall := await _shot("01_lift_doors_down_corridor")
	# 2. Inside the bank room, facing the four windows.
	var bank_mid := lv_bank_centre()
	var gz := (Prison.WINDOWS[0].y + 1) * Level.S
	_look(Vector3(bank_mid.x, EYE, Prison.BANK_ROOM.position.y * Level.S + 0.9), Vector3(bank_mid.x, 1.45, gz + 1.0))
	var bank := await _shot("02_bank_room_windows")
	# 3. One cell from the hall: its number, its bunk, its orange light (bunk 3, on the left).
	var dx := (Prison.CELL_DOOR_X_NORTH[2] + 0.5) * Level.S
	var wall_z := Prison.HALL_ROW * Level.S
	_look(Vector3(dx + 0.15, 1.5, wall_z + 1.8), Vector3(dx + 0.05, 1.75, wall_z - 6.0))
	var cell := await _shot("03_cell_from_hall")
	# 4. Inside that cell, just in from the door, looking at the bunk in its bunk cell.
	var bunk := Prison.bunk_positions()[2]
	var bc := Vector3((bunk.x + 0.5) * Level.S, 0, (bunk.y + 0.5) * Level.S)
	_look(Vector3(dx + 1.7, EYE, wall_z - 0.4), Vector3(bc.x + 0.1, 0.55, bc.z - 0.45))
	await _shot("04_cell_inside")
	# 5. From the far end of the corridor back to the lift.
	_look(Vector3(far_x + 0.6, EYE, hall_z), Vector3(door_x - 2.0, EYE - 0.2, hall_z))
	var back := await _shot("05_far_end_back_to_lift")
	# 6. The bank doorway from the hall: the bright spot.
	var bdx := (Prison.BANK_DOOR_X + 0.5) * Level.S
	_look(Vector3(bdx - 1.2, EYE, wall_z + 0.35), Vector3(bdx + 0.4, 1.3, wall_z + 6.0))
	await _shot("06_bank_door_from_hall")
	# 7. The report board on the bank room's side wall.
	var rbz := (Prison.REPORT_BOARD.y + 0.5) * Level.S
	_look(Vector3(bank_mid.x - 2.6, EYE, rbz + 2.2), Vector3(bank_mid.x + 4.0, 1.5, rbz - 0.3))
	await _shot("07_bank_report_board")
	var lb := _mean_luma(bank)
	var lh := (_mean_luma(hall) + _mean_luma(back)) * 0.5
	_check("bank room bright", lb >= BANK_MIN, "mean luma %.3f, needs >= %.2f" % [lb, BANK_MIN])
	_check("bank room brighter than the corridor", lb >= lh * BANK_OVER_HALL, "%.3f vs corridor (pictures 1 and 5) %.3f, needs x%.2f" % [lb, lh, BANK_OVER_HALL])
	var orange := _orange_share(cell)
	_check("cell night light orange", orange >= ORANGE_MIN, "%.1f%% orange pixels, needs >= %.1f%%" % [orange * 100.0, ORANGE_MIN * 100.0])
	await _station_pictures()

# The signs, a window's prompt, and the face kiosk: your face on its screen, F opens the editor on it,
# Done keeps the new face, Cancel keeps the old.
func _station_pictures() -> void:
	var view := _view()
	var gz := (Prison.WINDOWS[0].y + 1) * Level.S
	# 8. From the hall in front of the bank door: SHOP over windows 1-2, SKILLS over 3-4.
	var bdx := (Prison.BANK_DOOR_X + 0.5) * Level.S
	var door_z := Prison.BANK_ROOM.position.y * Level.S
	_look(Vector3(bdx, EYE, door_z - 0.6), Vector3(bdx + 0.6, 2.6, gz))
	_update_prompt()
	await _shot("08_bank_signs_from_door")
	_check("no prompt in the hall", hud.prompt == "", "\"%s\"" % hud.prompt)
	# 9. At window 1, facing the counter: the prompt.
	var w1 := Prison.WINDOWS[0]
	var wc := Vector3((w1.x + 0.5) * Level.S, EYE, (w1.y + 0.5) * Level.S)
	_look(wc, Vector3(wc.x, 1.5, gz + 0.3))
	_update_prompt()
	await _shot("09_window_1_prompt")
	_check("the prompt at window 1", hud.prompt == "F  SHOP", "\"%s\"" % hud.prompt)
	var w4 := Prison.WINDOWS[3]
	cam.position = Vector3((w4.x + 0.5) * Level.S, EYE, (w4.y + 0.5) * Level.S)
	_update_prompt()
	_check("the prompt at window 4", hud.prompt == "F  SKILL TREE", "\"%s\"" % hud.prompt)
	# 10. At the kiosk: your face on its screen, and the prompt.
	my_face = FaceCodec.encode(FacePaint.starter("frown"))
	view.set_kiosk_face(my_face)
	var k := Prison.kiosk_position()
	var kc := view.kiosk_centre
	var stand := Vector3((k.x + 0.5) * Level.S, EYE, (k.y + 0.5) * Level.S)
	_look(stand + Vector3(-0.35, 0, 0.25), Vector3(kc.x, kc.y - 0.1, kc.z))
	_update_prompt()
	await _shot("10_kiosk_your_face")
	_check("the prompt at the kiosk", hud.prompt == "F  CHANGE YOUR FACE", "\"%s\"" % hud.prompt)
	_check("the kiosk shows your face", view.kiosk_face_hash() == CrewView.texture_hash(FaceCodec.decode(my_face)), "screen %s, face %s" % [view.kiosk_face_hash(), CrewView.texture_hash(FaceCodec.decode(my_face))])
	# 11. F: the editor opens on your face; draw on it.
	var opened := _use()
	await _frames(2)
	_check("F at the kiosk opens the face editor on your face", opened and kiosk.is_open() and kiosk.editor.get_code() == my_face and hud.prompt == "", "open %s, starts on your face %s" % [kiosk.is_open(), kiosk.editor.get_code() == my_face if kiosk.editor != null else false])
	var old := my_face
	kiosk.editor.press("starter:shock")
	kiosk.editor.press("colour:2")
	kiosk.editor.press("brush:2")
	_drag(kiosk.editor, Vector2(4, 20), Vector2(7, 20))
	_drag(kiosk.editor, Vector2(25, 20), Vector2(28, 20))
	await _shot("11_kiosk_editor_open")
	var drawn := kiosk.editor.get_code()
	# 12. Done: the kiosk shows the new face.
	kiosk.editor.key(_key(KEY_ENTER))
	await _frames(2)
	_update_prompt()
	await _shot("12_kiosk_new_face")
	_check("Done keeps the new face", not kiosk.is_open() and my_face == drawn and my_face != old and view.kiosk_face_hash() == CrewView.texture_hash(FaceCodec.decode(drawn)), "closed %s, face changed %s" % [not kiosk.is_open(), my_face != old])
	# Cancel keeps the old one.
	_use()
	await _frames(2)
	kiosk.editor.press("clear")
	kiosk.editor.key(_key(KEY_ESCAPE))
	await _frames(2)
	_check("Cancel keeps the face you had", not kiosk.is_open() and my_face == drawn and view.kiosk_face_hash() == CrewView.texture_hash(FaceCodec.decode(drawn)), "closed %s, face kept %s" % [not kiosk.is_open(), my_face == drawn])
	# F anywhere else opens nothing.
	cam.position = Vector3((Prison.HALL_X0 + 0.5) * Level.S, EYE, (Prison.HALL_ROW + 0.5) * Level.S)
	_check("F away from the kiosk opens nothing", not _use() and not kiosk.is_open(), "")
	_update_prompt()
	# 13. The cell doors at a grazing angle, walking slowly down the hall close to the cells' wall: three
	# frames 3 cm apart. Faces sharing a plane (z-fighting) show as frame edges that change from frame
	# to frame; drawn right, only the small step of the view changes.
	var hz := Prison.HALL_ROW * Level.S + 0.45
	for i in 3:
		var x := (Prison.HALL_X0 + 1.2) * Level.S + i * 0.03
		_look(Vector3(x, EYE, hz), Vector3(x + 8.0, 1.2, hz - 0.9))
		_update_prompt()
		await _shot("13_cell_doors_grazing_%d" % (i + 1))

static func _key(code: Key) -> InputEventKey:
	var k := InputEventKey.new()
	k.pressed = true
	k.keycode = code
	k.physical_keycode = code
	return k

## A drag across the face editor's canvas from cell `a` to cell `b`, as the mouse sends it.
func _drag(ed: FaceEditor, a: Vector2, b: Vector2) -> void:
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = ed.cell_to_screen(a)
	ed._gui_input(down)
	for i in range(1, 9):
		var mv := InputEventMouseMotion.new()
		mv.position = ed.cell_to_screen(a.lerp(b, i / 8.0))
		ed._gui_input(mv)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = ed.cell_to_screen(b)
	ed._gui_input(up)

func lv_bank_centre() -> Vector3:
	var r := Prison.BANK_ROOM
	return Vector3((r.position.x + r.size.x * 0.5) * Level.S, 0, (r.position.y + r.size.y * 0.5) * Level.S)

# --- the frame-time walk ----------------------------------------------------------------------

# A spot on the lift's level about as far from the lift as the farthest bunk is, by a path on that level.
func _clinic_target(cells: int) -> Floor.Pos:
	var dist := Floor.distances_from(fp, fp.landing)
	var lvl := fp.landing.level
	var best: Floor.Pos = fp.landing
	var best_gap := 1 << 30
	for y in fp.height:
		for x in fp.width:
			var here := Floor.Pos.make(lvl, x, y)
			var d := dist[Floor.pos_index(fp, here)]
			if d < 0 or absi(d - cells) >= best_gap:
				continue
			var path := Floor.find_path(fp, fp.landing, here)
			var flat := not path.is_empty()
			for q in path:
				flat = flat and q.level == lvl
			if flat:
				best_gap = absi(d - cells)
				best = here
	return best

func _bench(target: Floor.Pos) -> void:
	_bench_route = _walk_route(target)
	if _bench_route.is_empty():
		_say("bench: no route")
		failed = true
		return
	_walk_cam(_bench_route, 0.0)
	await get_tree().create_timer(1.5).timeout
	_frame_ms = PackedFloat32Array()
	_bench_t = 0.0
	_bench_last_us = 0
	_bench_on = true
	await get_tree().create_timer(bench_secs).timeout
	_bench_on = false
	var a := _frame_ms.duplicate()
	a.sort()
	var sum := 0.0
	for v in a:
		sum += v
	var n := a.size()
	var mean := sum / maxf(1.0, float(n))
	var p95 := a[clampi(int(n * 0.95), 0, n - 1)] if n > 0 else 0.0
	var mx := a[n - 1] if n > 0 else 0.0
	_say("bench place=%s target=%d,%d route=%.1fs frames=%d mean_ms=%.3f p95_ms=%.3f max_ms=%.3f draw_calls=%d renderer=%s" % [
		place, target.x, target.y, _seconds(_bench_route), n, mean, p95, mx,
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		RenderingServer.get_current_rendering_method()])

func _run() -> void:
	await _frames(10)
	var bunk_cells := 0
	if place == "prison":
		var w := _walk_times()
		var bp: Floor.Pos = w[1]
		bunk_cells = Floor.distances_from(fp, fp.landing)[Floor.pos_index(fp, bp)]
		if bench_secs <= 0.0:
			await _prison_pictures()
		else:
			await _bench(bp)
	else:
		# As far as the prison's farthest bunk (10 cells from the landing).
		var target := _clinic_target(10)
		_say("clinic target %d,%d" % [target.x, target.y])
		if bench_secs > 0.0:
			await _bench(target)
	if bunk_cells > 0:
		_say("farthest bunk is %d cells (%d m) of path from the landing" % [bunk_cells, bunk_cells * int(Level.S)])
	_say("result %s" % ("FAIL" if failed else "PASS"))
	get_tree().quit(1 if failed else 0)
