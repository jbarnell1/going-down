# Going Down, the Godot client. Draws and plays what the rules say (rules_bridge.gd); computes no
# rule itself. Per frame, like src/main.ts for the host's own player:
#   input -> bridge.step (the rules move the body, tick the run, decide what Orderly to draw)
#   -> events (doors, chimes, the announcer, the slip, being taken, the end) -> the picture.
# The 3D is drawn at 480x270 in a SubViewport and shown through the tape shader; the on-screen
# display, subtitles and end screen are drawn crisp on top.
#
# URL parameters (browser) / user args after `--` (desktop):
#   seed=<text> (default alpha)  quality=light|full (browser default light, desktop full)
#   auto=1 (never capture the mouse; also when navigator.webdriver)  props=0  entity=0
# Test hook (browser): window.gdCmd("<command>") -> window.gdResult; see _command().
extends Node

const VFOV := 70.0
const SENS := 0.0022
const MAX_PITCH := 1.45
const NOISE_MS := 2000          # src/render/caughtFx.ts
const LINE_MS := 3200
const BLACK_MS := 250
const BELL_WARNINGS: Array[float] = [5.0, 3.0]
const ANNOUNCE_BELL_AT := 7.0
const EMERGENCY_DELAY := 0.8    # src/render/lighting.ts
const EMERGENCY_RISE := 0.8
const LEAVE_FLOORS := 5
const LEAVE_FLOOR_MS := 1300
const RIDE_TIME := 6.0
const BOARD_TIME := 20.0

var bridge: RulesBridge
var sub: SubViewport
var env: Environment
var cam: Camera3D
var world: Node3D
var level: Level
var lift: Lift
var orderly: OrderlyView
var sfx: Sfx
var announcer: Announcer
var hud: Hud
var inst_view: InstrumentView
var screen: TextureRect
var tape_mat: ShaderMaterial

var seed := "alpha"
var quality := "light"
var props_on := true
var entity_on := true
var automated := false
var yaw := 0.0
var pitch := 0.0
var snap: Dictionary = {}
var built_depth := -1
var runs := 0

# Test overrides (empty / null = from the keyboard and mouse).
var t_move: Array = []     # [f, r, sprint, creep]
var t_raise: Variant = null
## Tests: show the menu although the mouse is never captured under automation.
var t_menu := false
var t_hold: Variant = null
var time_scale := 1.0
var pending_call := false
var pending_pick := false
## The instrument is out: E toggles it (the right mouse button still raises it while held).
var raise_latch := false

# Presentation state.
var dark_since := -1
var emergency := 0.0
var light := 1.0
var caught_at := -1
var ending: Dictionary = {}
var end_shown_at := -1
var left_at := -1
var ride_started := -1
var prev_bell_left := BOARD_TIME
var lifetime := 0.0
var tick_acc := 0.0
var event_counts: Dictionary = {}
var event_log: Array = []
var frames := 0
var _ft_sum := 0.0
var _ft_n := 0
var _ft_max := 0.0
var bridge_ms_sum := 0.0
var load_ms := 0
var _js_cb: JavaScriptObject
var error_text := ""
var _gesture := false
# Desktop test channel: commands as for window.gdCmd, one per line over TCP on 127.0.0.1.
var _test_port := 0
var _test_server: TCPServer
var _test_peers: Array[StreamPeerTCP] = []
var _test_bufs: Array[String] = []
var _welcome_pending := false

func _ready() -> void:
	if OS.get_cmdline_user_args().has("scene=prison_demo"):  # the Prison hub look, no day loop (client/prison_demo.gd)
		process_mode = Node.PROCESS_MODE_DISABLED
		get_tree().change_scene_to_file.call_deferred("res://client/prison_demo.tscn")
		return
	var t0 := Time.get_ticks_msec()
	_read_options()
	_add_actions()
	_build_view()
	bridge = RulesBridge.new()
	bridge.name = "RulesBridge"
	add_child(bridge)
	if not bridge.open():
		error_text = "RULES NOT CONNECTED: " + bridge.error.to_upper()
		push_error(error_text)
	else:
		_new_run()
	if OS.has_feature("web"):
		_js_cb = JavaScriptBridge.create_callback(_on_js)
		var window: JavaScriptObject = JavaScriptBridge.get_interface("window")
		window.set("gdCmd", _js_cb)
	_audio_options()
	if _test_port > 0 and not OS.has_feature("web"):
		automated = true
		_test_server = TCPServer.new()
		var err := _test_server.listen(_test_port, "127.0.0.1")
		print("test channel on 127.0.0.1:%d %s" % [_test_port, "ready" if err == OK else "FAILED %d" % err])
	load_ms = Time.get_ticks_msec() - t0
	print("client ready in %d ms; rules via %s; quality %s" % [load_ms, bridge.mode, quality])
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--bench="):
			_bench(float(a.substr(8)))

# Desktop measurement: stand in the clean corridor nearest the lift for `secs`, print frame times, quit.
func _bench(secs: float) -> void:
	automated = true
	await get_tree().create_timer(1.0).timeout
	var pl := bridge.plan
	var best: Dictionary = {}
	var best_d := INF
	var lift_dist: Array = pl["liftDist"]
	var w := int(pl["width"])
	var h := int(pl["height"])
	for sl: Dictionary in pl["sightlines"]:
		if int(sl["level"]) != 0 or int(sl["length"]) < 6:
			continue
		var d := float(lift_dist[int(sl["y1"]) * w + int(sl["x1"])]) + float(lift_dist[int(sl["y2"]) * w + int(sl["x2"])])
		if d < best_d and d >= 0.0:
			best_d = d
			best = sl
	if not best.is_empty():
		bridge.teleport(0, int(best["x1"]), int(best["y1"]))
		yaw = atan2(-(float(best["x2"]) - float(best["x1"])), -(float(best["y2"]) - float(best["y1"])))
	await get_tree().create_timer(1.5).timeout
	_ft_sum = 0.0
	_ft_n = 0
	_ft_max = 0.0
	bridge_ms_sum = 0.0
	var f0 := frames
	await get_tree().create_timer(secs).timeout
	print("bench (%s): %d frames, mean %.2f ms, max %.2f ms, rules %.3f ms/frame, draw calls %d" % [quality, _ft_n, 1000.0 * _ft_sum / maxi(_ft_n, 1), 1000.0 * _ft_max,
		bridge_ms_sum / maxi(frames - f0, 1), RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)])
	get_tree().quit(0)

# Sound diagnostics (URL parameters / user args): playback=stream|sample forces every player's
# playback type, bus=master sends everything to Master, mute=1 mutes Master (the sound check must
# then fail).
func _audio_options() -> void:
	var playback := ""
	var bus := ""
	var mute := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--playback=") or a.begins_with("playback="): playback = a.get_slice("=", 1)
		if a.begins_with("--bus=") or a.begins_with("bus="): bus = a.get_slice("=", 1)
		if a == "--mute=1" or a == "mute=1": mute = true
	if OS.has_feature("web"):
		playback = _url("playback", playback)
		bus = _url("bus", bus)
		mute = _url("mute", "0") == "1"
	for n: Node in find_children("*", "", true, false):
		if n is AudioStreamPlayer or n is AudioStreamPlayer3D:
			if playback == "stream":
				n.set("playback_type", AudioServer.PLAYBACK_TYPE_STREAM)
			elif playback == "sample":
				n.set("playback_type", AudioServer.PLAYBACK_TYPE_SAMPLE)
			if bus == "master":
				n.set("bus", "Master")
	AudioServer.set_bus_mute(0, mute)

func _url(key: String, fallback: String) -> String:
	return str(JavaScriptBridge.eval("new URLSearchParams(location.search).get('%s') ?? '%s'" % [key, fallback], true))

func _read_options() -> void:
	var args := OS.get_cmdline_user_args()
	quality = "light" if OS.has_feature("web") else "full"
	# Desktop: `-- seed=x quality=full auto=1 props=0 entity=0 testport=4460` (a leading -- is fine too).
	for raw in args:
		var a := raw.trim_prefix("--")
		var key := a.get_slice("=", 0)
		var val := a.get_slice("=", 1) if a.contains("=") else "1"
		match key:
			"seed": seed = val
			"quality": quality = val
			"auto": automated = val != "0"
			"props": props_on = val != "0"
			"entity": entity_on = val != "0"
			"testport": _test_port = int(val)
	if OS.has_feature("web"):
		seed = _url("seed", seed)
		quality = _url("quality", quality)
		props_on = _url("props", "1") != "0"
		entity_on = _url("entity", "1") != "0"
		automated = str(JavaScriptBridge.eval("(navigator.webdriver || /[?&]auto=1/.test(location.search)) ? 'y' : 'n'", true)) == "y"

func _add_actions() -> void:
	var keys := {"forward": [KEY_W, KEY_UP], "back": [KEY_S, KEY_DOWN], "left": [KEY_A, KEY_LEFT], "right": [KEY_D, KEY_RIGHT],
		"sprint": [KEY_SHIFT], "creep": [KEY_CTRL, KEY_C], "use": [KEY_F]}
	for action: String in keys:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		for k: Key in keys[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = k
			InputMap.action_add_event(action, ev)

func _build_view() -> void:
	sub = SubViewport.new()
	sub.size = Vector2i(480, 270)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sub.msaa_3d = Viewport.MSAA_DISABLED
	sub.positional_shadow_atlas_size = 2048
	sub.audio_listener_enable_3d = true
	add_child(sub)
	get_viewport().disable_3d = true
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
	env.glow_enabled = quality == "full"
	env.glow_intensity = 0.6
	env.glow_hdr_threshold = 0.9
	we.environment = env
	sub.add_child(we)
	world = Node3D.new()
	world.name = "World"
	sub.add_child(world)
	cam = Camera3D.new()
	cam.fov = VFOV
	cam.near = 0.05
	cam.far = 60.0
	sub.add_child(cam)
	cam.current = true
	orderly = OrderlyView.new()
	orderly.name = "Orderly"
	sub.add_child(orderly)
	# The instrument, drawn into the picture so the tape lies over it.
	var layer := CanvasLayer.new()
	sub.add_child(layer)
	inst_view = InstrumentView.new()
	inst_view.size = Vector2(480, 270)
	layer.add_child(inst_view)
	screen = TextureRect.new()
	screen.texture = sub.get_texture()
	screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	screen.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	screen.stretch_mode = TextureRect.STRETCH_SCALE
	screen.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	tape_mat = ShaderMaterial.new()
	tape_mat.shader = load("res://client/tape.gdshader")
	screen.material = tape_mat
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(screen)
	hud = Hud.new()
	add_child(hud)
	sfx = Sfx.new()
	add_child(sfx)
	var audio3d := Node3D.new()
	audio3d.name = "Audio3D"
	sub.add_child(audio3d)
	sfx.setup(audio3d)
	announcer = Announcer.new()
	add_child(announcer)

# --- runs and floors ----------------------------------------------------------------------------

func _new_run() -> void:
	var run_seed := seed if runs == 0 else "%s-%d" % [seed, runs]
	runs += 1
	snap = bridge.start(run_seed, 1, entity_on)
	if snap.has("error"):
		error_text = "RULES: " + str(snap["error"]).left(60).to_upper()
		return
	hud.set_seed(run_seed)
	_build_floor(bridge.plan)
	var placed: Variant = snap.get("placed")
	if placed is Dictionary:
		yaw = float((placed as Dictionary).get("yaw", 0.0))
	pitch = 0.0
	raise_latch = false
	ending = {}
	end_shown_at = -1
	hud.end_lines = []
	caught_at = -1
	left_at = -1
	ride_started = -1
	prev_bell_left = BOARD_TIME
	lift.set_doors(false, true)
	sfx.ride(false)
	# In a browser nothing is heard before the first click or key (autoplay rules): the welcome
	# waits for it rather than being spoken to a muted page.
	if _gesture or not OS.has_feature("web"):
		announcer.start_run()
	else:
		_welcome_pending = true

func _build_floor(plan: Dictionary) -> void:
	for c: Node in world.get_children():
		c.queue_free()
	level = Level.new()
	level.name = "Level"
	level.shadows = quality == "full"
	level.props_on = props_on
	world.add_child(level)
	level.build(plan, str(snap.get("seed", seed)))
	lift = Lift.new()
	lift.name = "Lift"
	world.add_child(lift)
	lift.build(plan["car"])
	orderly.reset()
	built_depth = int(plan["depth"])
	level.set_emergency(0.0)
	level.set_light_level(1.0)
	print("floor %d built: %d lights, %d flickering, %d emergency, %d props (%d overturned)" % [built_depth, level.main_lights.size(), level.flickers.size(), level.emergency_lights.size(), level.props_placed, level.props_overturned])

# --- input --------------------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if (event is InputEventMouseButton or event is InputEventKey) and event.is_pressed() and not _gesture:
		_gesture = true
		if _welcome_pending:
			_welcome_pending = false
			announcer.start_run()
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		# The mouse is captured only after a real click, never under automation.
		if mb.pressed and not automated and mb.button_index == MOUSE_BUTTON_LEFT and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var mm := event as InputEventMouseMotion
		yaw -= mm.relative.x * SENS
		pitch = clampf(pitch - mm.relative.y * SENS, -MAX_PITCH, MAX_PITCH)
	elif event is InputEventKey:
		var k := event as InputEventKey
		if not k.pressed or k.echo:
			return
		if k.physical_keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif not hud.end_lines.is_empty() and Time.get_ticks_msec() - end_shown_at > 1200:
			_new_run()
		elif k.physical_keycode == KEY_E:
			raise_latch = not raise_latch
		elif k.physical_keycode == KEY_F:
			pending_call = true
			pending_pick = true
		elif k.physical_keycode == KEY_T:
			var st: float = tape_mat.get_shader_parameter("strength")
			tape_mat.set_shader_parameter("strength", 0.0 if st > 0.5 else 1.0)

func _noise_on() -> bool:
	var now := Time.get_ticks_msec()
	return caught_at >= 0 and now - caught_at < BLACK_MS + NOISE_MS

# --- the frame ----------------------------------------------------------------------------------

func _poll_test() -> void:
	if _test_server == null:
		return
	while _test_server.is_connection_available():
		_test_peers.append(_test_server.take_connection())
		_test_bufs.append("")
	for i in _test_peers.size():
		var peer := _test_peers[i]
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			continue
		var n := peer.get_available_bytes()
		if n > 0:
			_test_bufs[i] += peer.get_utf8_string(n)
		while _test_bufs[i].contains("\n"):
			var line := _test_bufs[i].get_slice("\n", 0)
			_test_bufs[i] = _test_bufs[i].substr(line.length() + 1)
			var reply := _command(line.strip_edges())
			peer.put_data((reply + "\n").to_utf8_buffer())

func _process(delta: float) -> void:
	_poll_test()
	frames += 1
	if frames > 5:
		_ft_sum += delta
		_ft_n += 1
		_ft_max = maxf(_ft_max, delta)
	if OS.has_feature("web") and frames == 3:
		JavaScriptBridge.eval("window.gdReady = true; window.gdFirstFrameMs = performance.now();", true)
	if bridge.mode == "" or snap.is_empty() or snap.has("error"):
		hud.center_note = error_text
		return
	var dt := minf(delta, 0.1)
	var now := Time.get_ticks_msec()
	var ended := not hud.end_lines.is_empty() or str(snap.get("phase", "")) == "ended"
	var still := _noise_on() or ended
	var f := 0.0
	var r := 0.0
	var sprint := false
	var creep := false
	if not t_move.is_empty():
		f = t_move[0]
		r = t_move[1]
		sprint = t_move[2]
		creep = t_move[3]
	else:
		f = Input.get_action_strength("forward") - Input.get_action_strength("back")
		r = Input.get_action_strength("right") - Input.get_action_strength("left")
		sprint = Input.is_action_pressed("sprint")
		creep = Input.is_action_pressed("creep")
	var raised: bool = t_raise if t_raise != null else (raise_latch or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT))
	var me: Dictionary = snap.get("me", {})
	var hold: bool = t_hold if t_hold != null else (Input.is_action_pressed("use") and bool(me.get("nearHold", false)))
	var call: bool = pending_call and bool(me.get("canCall", false))
	var pick: bool = pending_pick and not call
	pending_call = false
	pending_pick = false
	var aspect := 480.0 / 270.0
	var hfov := rad_to_deg(2.0 * atan(tan(deg_to_rad(VFOV) * 0.5) * aspect))
	var s := bridge.step({"dt": dt, "f": f, "r": r, "sprint": sprint, "creep": creep, "yaw": yaw, "pitch": pitch,
		"hfov": hfov, "vfov": VFOV, "raised": raised and not still, "call": call, "hold": hold, "pickUp": pick,
		"still": still, "timeScale": time_scale})
	bridge_ms_sum += bridge.last_ms
	if s.has("error"):
		hud.center_note = "RULES ERROR"
		return
	snap = s
	if s.get("autoYaw") != null:
		yaw = float(s["autoYaw"])
	var placed: Variant = s.get("placed")
	if placed is Dictionary and (placed as Dictionary).has("yaw"):
		yaw = float((placed as Dictionary)["yaw"])
		pitch = 0.0
	if s.has("plan"):
		var plan: Dictionary = s["plan"]
		if int(plan["depth"]) != built_depth:
			_build_floor(plan)
			lift.set_doors(false, true)
	_present(s.get("events", []), now)
	me = s["me"]

	# The camera.
	cam.position = Vector3(float(me["x"]), float(me["y"]) + float(me["eye"]), float(me["z"]))
	cam.rotation = Vector3(pitch, yaw, 0)

	# The Orderly: drawn exactly as the rules say, never in the dark, never while taken.
	var o: Dictionary = s["orderly"]
	orderly.show_pose(o.get("pose"), bool(o.get("visible", false)) and not _noise_on())

	# The lights: a blink's warning flickers, the dark is deep, the emergency lighting comes up.
	var dark: bool = s["dark"]
	var warn: bool = s["warn"]
	if not dark:
		dark_since = -1
	elif dark_since < 0:
		dark_since = now
	emergency = _emergency_level((now - dark_since) / 1000.0) if dark else 0.0
	light = 1.0
	var blink: Variant = s.get("blink")
	if dark:
		light = 0.07 * (1.0 - 0.7 * emergency)
	elif warn and blink is Dictionary and bool((blink as Dictionary)["blackout"]):
		var left := maxf(0.0, float((blink as Dictionary)["at"]) - float(s["t"]))
		var period := 260 if left > 2.0 else (150 if left > 1.0 else 70)
		var sag := 0.55 if left > 2.0 else (0.4 if left > 1.0 else 0.28)
		light = 0.1 if ((now / period) % 2 == 0 or (now / 37) % 7 == 3) else sag
	elif warn:
		light = 0.18 if ((now / 55) % 4 == 1 or (now / 140) % 3 == 2) else 0.6
	level.set_light_level(light)
	sfx.set_hum(light)
	level.set_emergency(emergency)
	level.update_lights(dt, cam.global_position)
	env.ambient_light_color = Color(0.55, 0.6, 0.6).lerp(Color(0.5, 0.08, 0.03), emergency)
	env.ambient_light_energy = lerpf(0.12, 0.05, emergency) * maxf(light, emergency)
	env.background_color = Color(0.02, 0.025, 0.025) * light

	# The lift: doors, indicator, votes, buttons.
	var phase := str(s["phase"])
	lift.set_doors(bool(s["doorsOpen"]))
	_show_indicator(now)
	lift.set_vote(str(me["side"]) if me.get("side") != null else "")
	lift.set_call_lit(phase == "coming")
	lift.set_hold_lit(bool(s["held"]))
	lift.set_light(1.0 if not dark else 0.1)
	lift.update(dt)
	if phase == "boarding":
		var bell_left := float(s["bellLeft"])
		for w: float in BELL_WARNINGS:
			if prev_bell_left > w and bell_left <= w:
				sfx.play("bell_warn")
		if prev_bell_left > ANNOUNCE_BELL_AT and bell_left <= ANNOUNCE_BELL_AT:
			announcer.bell_soon()
		prev_bell_left = bell_left

	# The instrument and the sounds.
	var inst: Variant = s.get("inst")
	var tick_hz := 0.0
	var loud := 0.0
	if inst is Dictionary:
		var id: Dictionary = inst
		tick_hz = float(id["tickHz"])
		loud = float(id["loudness"])
		tick_acc += tick_hz * dt
		var ticks := int(floorf(tick_acc))
		tick_acc -= ticks
		inst_view.update_view(dt, bool(id["raised"]), str(id["needle"]), float(id["value"]), id["distance"], tick_hz, ticks, float(me["speed"]))
	var cl: Variant = s.get("call")
	var machine := 0.0
	if phase == "coming" and cl is Dictionary:
		var cd: Dictionary = cl
		machine = (1.0 - float(cd["floorsAway"]) / maxf(1.0, float(cd["floors"]))) * (0.5 if bool(cd["falseStop"]) else 1.0) + 0.05
	var car: Dictionary = bridge.plan["car"]
	sfx.update(dt, o["squeak"], o.get("pose"), tick_hz, loud, float(me["exertion"]) if not still else 0.0, bool(me["winded"]), machine,
		Vector3(float(car["doorX"]), float(car["floorY"]) + 1.5, float(car["doorZ"])))
	announcer.update()

	# The picture and the display.
	var noise := _noise_on()
	var black := caught_at >= 0 and now - caught_at < BLACK_MS
	tape_mat.set_shader_parameter("darkness", 1.0 if dark else 0.0)
	tape_mat.set_shader_parameter("tired", 0.85 * pow(float(me["exertion"]), 1.4) if not still else 0.0)
	tape_mat.set_shader_parameter("snow", 1.0 if (noise and not black) else 0.0)
	tape_mat.set_shader_parameter("glitch", 1.0 if noise else 0.0)
	hud.black = black
	hud.went_down = caught_at >= 0 and now - caught_at >= BLACK_MS + NOISE_MS and now - caught_at < BLACK_MS + NOISE_MS + LINE_MS and ending.is_empty()
	var tapes: Dictionary = s["tapes"]
	hud.set_tapes(int(tapes["count"]), float(tapes["value"]))
	hud.subtitle = announcer.subtitle
	hud.center_note = error_text
	# The menu (the controls) shows whenever the mouse is free: after Esc, and before the first click.
	hud.menu_on = t_menu or (error_text == "" and not automated and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and hud.end_lines.is_empty())
	var prompt := ""
	if not ended and not noise:
		if bool(me.get("canCall", false)):
			prompt = "F  ▼ CALL"
		elif bool(me.get("nearHold", false)):
			prompt = "F  <|> HOLD"
		elif _tape_in_reach(me):
			prompt = "F  PICK UP"
	hud.prompt = prompt
	_show_end(now)

func _emergency_level(seconds: float) -> float:
	if seconds < EMERGENCY_DELAY:
		return 0.0
	var k := minf(1.0, (seconds - EMERGENCY_DELAY) / EMERGENCY_RISE)
	if k >= 1.0:
		return 1.0
	return k * 0.25 if int(floorf(seconds * 12.0)) % 3 == 0 else k

func _tape_in_reach(me: Dictionary) -> bool:
	for ft: Dictionary in snap.get("floorTapes", []):
		var at: Dictionary = ft["at"]
		if int(at["level"]) == int(me["level"]) and Vector3(float(at["x"]) - float(me["x"]), float(at["y"]) - float(me["y"]), float(at["z"]) - float(me["z"])).length() <= 1.3:
			return true
	return false

func _floor_label(floor_n: int) -> String:
	if floor_n >= 1:
		return "B%d" % floor_n if floor_n < 10 else str(floor_n)
	return "G" if floor_n == 0 else str(-floor_n)

# The indicator over the doors (src/main.ts showIndicator).
func _show_indicator(now: int) -> void:
	var depth := int(snap["depth"])
	match str(snap["phase"]):
		"arriving", "unloading", "boarding":
			lift.show_indicator(_floor_label(depth), true, 0)
		"coming":
			var c: Variant = snap.get("call")
			var away := 0
			var false_stop := false
			if c is Dictionary:
				away = int((c as Dictionary)["floorsAway"])
				false_stop = bool((c as Dictionary)["falseStop"])
			lift.show_indicator(_floor_label(depth - away), true, 0 if false_stop else -1)
		"away":
			var k := LEAVE_FLOORS if left_at < 0 else mini(LEAVE_FLOORS, (now - left_at) / LEAVE_FLOOR_MS + 1)
			lift.show_indicator(_floor_label(depth - k), k < LEAVE_FLOORS, 1 if k < LEAVE_FLOORS else 0)
		"riding":
			var half := ride_started >= 0 and now - ride_started > RIDE_TIME * 1000.0 / 2.0
			lift.show_indicator(_floor_label(depth + (1 if half else 0)), true, -1)
		_:
			lift.show_indicator("", false, 0)

# Events that change what is seen and heard (src/main.ts present).
func _present(events: Array, now: int) -> void:
	if events.is_empty():
		return
	announcer.on_events(events, 1)
	for e: Dictionary in events:
		var ty := str(e["type"])
		event_counts[ty] = int(event_counts.get(ty, 0)) + 1
		event_log.append({"type": ty, "t": e.get("t", 0.0)})
		if event_log.size() > 80:
			event_log.pop_front()
		var mine := str(e.get("playerId", "")) == "me"
		match ty:
			"doorsOpened", "doorsClosed":
				sfx.play("doors")
			"carLeft":
				if str(e["reason"]) == "ride":
					ride_started = now
					sfx.ride(true)
				else:
					left_at = now
			"called":
				sfx.play("chime")
			"indicator":
				sfx.play("ding", -4.0)
			"falseStop":
				sfx.play("chime_far")
			"falseStopDoors":
				sfx.play("doors_far")
			"blinkSoon":
				sfx.play("blackout_warn" if bool(e["blackout"]) else "blink_warn")
			"blinkStart":
				sfx.play("blink")
			"blinkEnd":
				sfx.play("blink", -8.0)
			"carArrived":
				prev_bell_left = BOARD_TIME
			"bell":
				sfx.play("bell")
			"rodeDown":
				sfx.ride(false)
				ride_started = -1
			"banked":
				var summary: Dictionary = e["summary"]
				var shares: Dictionary = summary["shares"]
				lifetime += float(shares.get("me", 0.0))
				ending = {"kind": "banked", "at": now, "summary": summary}
				sfx.ride(true)
			"wiped":
				ending = {"kind": "wiped", "at": now, "summary": e["summary"]}
			"leftBehind":
				if mine:
					ending = {"kind": "leftBehind", "at": now}
			"caught":
				if mine:
					caught_at = now
					raise_latch = false
					sfx.play("caught")
			"slip":
				if mine:
					inst_view.print_slip(str(e["text"]))
					sfx.play("slip")
			"readingClosed":
				if mine:
					sfx.play("closed")

func _show_end(now: int) -> void:
	if ending.is_empty() or not hud.end_lines.is_empty():
		return
	var kind := str(ending["kind"])
	var wait := 2600 if kind == "banked" else (NOISE_MS + 200 if kind == "wiped" else 1500)
	if now - int(ending["at"]) < wait:
		return
	sfx.ride(false)
	var again := {"text": "PRESS A KEY FOR A NEW RUN"}
	if kind == "banked":
		var sm: Dictionary = ending["summary"]
		var shares: Dictionary = sm["shares"]
		hud.end_lines = [{"text": "BANKED", "strong": true}, {"text": ""}, {"text": "FLOORS %d" % int(sm["depth"])},
			{"text": "READINGS %d" % int(sm["readings"])}, {"text": "TOTAL " + _n4(float(sm["total"])), "strong": true},
			{"text": "YOUR SHARE " + _n4(float(shares.get("me", 0.0))), "strong": true}, {"text": ""},
			{"text": "LIFETIME " + _n4(lifetime)}, {"text": ""}, again]
	elif kind == "wiped":
		hud.end_lines = [{"text": "NOBODY CAME BACK UP", "strong": true}, {"text": ""}, {"text": "FLOORS %d" % int(snap["depth"])},
			{"text": "NOTHING BANKED"}, {"text": ""}, {"text": "LIFETIME " + _n4(lifetime)}, {"text": ""}, again]
	else:
		hud.end_lines = [{"text": "THE CAR WENT DOWN WITHOUT YOU", "strong": true}, {"text": ""}, again]
	end_shown_at = now
	if not automated:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

## Each bus's level right now (dB, the louder channel; -200 for silence). On the desktop this is
## what reaches the speakers; in the browser's Sample mode the buses are bypassed and read silent.
func _bus_peaks() -> Dictionary:
	var out := {}
	for i in AudioServer.bus_count:
		var db := maxf(AudioServer.get_bus_peak_volume_left_db(i, 0), AudioServer.get_bus_peak_volume_right_db(i, 0))
		out[AudioServer.get_bus_name(i)] = maxf(-200.0, db)
	return out

func _n4(v: float) -> String:
	return "%04d" % int(floorf(v))

# --- the test hook ------------------------------------------------------------------------------

func _on_js(args: Array) -> void:
	var res := _command(str(args[0]))
	var window: JavaScriptObject = JavaScriptBridge.get_interface("window")
	window.set("gdResult", res)

## Commands (space separated): state | stats | resetstats | move f r sprint creep | stopmove |
## look yawDeg pitchDeg | face x z [y] | raise 0|1|- | hold 0|1|- | call | pick | teleport level x y |
## walkto level x y [pace] | stopwalk | timescale k | newrun | tape 0|1 | debug | floortapes | plan
func _command(c: String) -> String:
	var p := c.split(" ", false)
	if p.is_empty():
		return "empty"
	match p[0]:
		"state":
			return JSON.stringify(_test_state())
		"stats":
			return JSON.stringify({"frames": frames, "avg_ms": 1000.0 * _ft_sum / maxi(_ft_n, 1), "max_ms": 1000.0 * _ft_max,
				"fps": Engine.get_frames_per_second(), "load_ms": load_ms, "bridge_ms_avg": bridge_ms_sum / maxi(frames, 1),
				"draw_calls": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
				"objects": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME),
				"prims": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
				"quality": quality, "renderer": RenderingServer.get_current_rendering_method(), "rules": bridge.mode, "peaks": _bus_peaks()})
		"peaks":
			return JSON.stringify(_bus_peaks())
		"resetstats":
			_ft_sum = 0.0
			_ft_n = 0
			_ft_max = 0.0
			bridge_ms_sum = 0.0
			frames = 6
		"move":
			t_move = [float(p[1]), float(p[2]), p.size() > 3 and p[3] == "1", p.size() > 4 and p[4] == "1"]
		"menu":
			t_menu = p.size() > 1 and p[1] == "1"
		"stopmove":
			t_move = []
		"look":
			yaw = deg_to_rad(float(p[1]))
			pitch = deg_to_rad(float(p[2])) if p.size() > 2 else 0.0
		"face":
			var tx := float(p[1])
			var tz := float(p[2])
			yaw = atan2(-(tx - cam.position.x), -(tz - cam.position.z))
			pitch = 0.0
			if p.size() > 3:
				var dy := float(p[3]) - cam.position.y
				pitch = atan2(dy, Vector2(tx - cam.position.x, tz - cam.position.z).length())
		"raise":
			t_raise = null if p[1] == "-" else p[1] == "1"
		"hold":
			t_hold = null if p[1] == "-" else p[1] == "1"
		"call":
			pending_call = true
		"pick":
			pending_pick = true
		"teleport":
			return JSON.stringify(bridge.teleport(int(p[1]), int(p[2]), int(p[3])))
		"walkto":
			return JSON.stringify(bridge.walk_to(int(p[1]), int(p[2]), int(p[3]), float(p[4]) if p.size() > 4 else 3.0))
		"stopwalk":
			return JSON.stringify(bridge.stop_walk())
		"timescale":
			time_scale = float(p[1])
		"newrun":
			_new_run()
		"tape":
			tape_mat.set_shader_parameter("strength", float(p[1]))
		"debug":
			return JSON.stringify(bridge.debug_info())
		"shot":
			# The whole window as drawn (tape, display, subtitles), to a PNG path.
			var img := get_viewport().get_texture().get_image()
			return "ok" if img.save_png(c.substr(5).strip_edges()) == OK else "save failed"
		"click":
			# A stand-in for the first real click or key (the browser's audio and the welcome wait for one).
			_gesture = true
			if _welcome_pending:
				_welcome_pending = false
				announcer.start_run()
		"quit":
			get_tree().quit(0)
		"sfx":
			sfx.play(p[1])
		"say":
			announcer.request(p[1], 9000)
		"props":
			return JSON.stringify(level.prop_spots)
		"nudge":
			return JSON.stringify(bridge.nudge(float(p[1]), float(p[2])))
		"floortapes":
			return JSON.stringify(snap.get("floorTapes", []))
		"plan":
			var pl := bridge.plan
			return JSON.stringify({"width": pl["width"], "height": pl["height"], "landing": pl["landing"], "entityStart": pl["entityStart"],
				"sightlines": pl["sightlines"], "car": pl["car"], "elevatorWall": pl["elevatorWall"], "landingFacing": pl["landingFacing"],
				"cells": pl["cells"], "liftDist": pl["liftDist"], "rooms": pl["rooms"], "doors": pl["doors"]})
		_:
			return "unknown command"
	return "ok"

func _test_state() -> Dictionary:
	var s := snap
	var o: Dictionary = s["orderly"]
	return {
		"phase": s.get("phase"), "depth": s.get("depth"), "t": s.get("t"), "dark": s.get("dark"), "warn": s.get("warn"),
		"blackout": s.get("blackout"), "blink": s.get("blink"), "call": s.get("call"), "doorsOpen": s.get("doorsOpen"),
		"bellLeft": s.get("bellLeft"), "votes": s.get("votes"), "summary": s.get("summary"),
		"me": s.get("me"), "inst": s.get("inst"), "tapes": s.get("tapes"), "auto": s.get("auto"),
		"orderly": {"mode": o["mode"], "held": o["held"], "seeing": o["seeing"], "visible": o["visible"],
			"moving": o["moving"], "frozen": o["frozen"], "distance": o["distance"], "x": o["x"], "z": o["z"],
			"level": o["level"], "drawn": orderly.visible, "pose": o.get("pose"), "squeak": o["squeak"]},
		"client": {"yaw": yaw, "pitch": pitch, "emergency": emergency, "light": light, "doors": lift.doors if lift else 0.0,
			"indicator": lift.indicator_text if lift else "", "slip": inst_view.slip_text, "slipShown": inst_view.slip_shown(),
			"raise": inst_view.raise, "needle": inst_view.needle, "needleAngle": inst_view.angle, "subtitle": announcer.subtitle,
			"spoken": announcer.history.map(func(h: Dictionary) -> String: return str(h["id"])), "caught": caught_at >= 0, "noise": _noise_on(),
			"wentDown": hud.went_down, "end": hud.end_lines.map(func(l: Dictionary) -> String: return str(l["text"])), "tapeText": hud.tape_text,
			"prompt": hud.prompt, "menu": hud.menu_on, "built": built_depth, "timeScale": time_scale, "hudSize": [hud.size.x, hud.size.y]},
		"events": event_counts,
	}
