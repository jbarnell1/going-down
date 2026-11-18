# Going Down, the Godot client. Draws and plays what the host says; computes no rule itself. It talks
# to ONE thing, alone or with friends: the network client, through play_link.gd. Playing alone is a
# room on this machine (net/local_room.gd: the server's host code over in-memory pipes); playing
# together is the same client over a WebSocket to the server (net/room_client.gd). Per frame:
#   input -> link.step (moves your own body with the rules, the client's frame with the real camera)
#   -> events (doors, chimes, the announcer, the slip, being taken, the end) -> the picture, the
#   other players, their emotes and footsteps.
# Before the game: the start screen (start_screen.gd): Play alone, Join friends, draw your face, the
# orientation tape (the first time on this PC), Ready-up (the controls card and the crew; findables-and-day.md
# section 2, FD6). Nobody is in the car until their own READY is pressed and the room has put them in the run
# (run_view_on): with friends the run starts for everyone at once; alone READY starts it at once. On entering,
# the desktop captures the mouse (so the Esc menu does not show; in the browser one line, CLICK TO LOOK), and
# the announcer's welcome is held WELCOME_HOLD seconds, so the car and the crew come first, then the voice.
# The face drawn goes in the join (net/protocol.gd); every crewmate wears the face their player
# drew on their mask (others_view.gd), and the lift's monitor shows the whole crew's (lift.gd). In the
# prison, F at the face kiosk (client/face_kiosk.gd) opens the same editor on your face; Done sends the
# new face to everyone in the run (net/room_client.gd set_face).
# Caught means down, not out (client/down_view.gd): down, your view is on the floor, you crawl, your timer
# counts down and a crewmate can hold F beside you to get you up; out, the screen goes dark until the car
# next moves; everyone sees the downed lying, the resident bent over them, and a red spot where one went out.
# The 3D is drawn at 480x270 in a SubViewport and shown through the tape shader; the on-screen
# display, name tags, subtitles, menus and end screen are drawn crisp on top.
#
# URL parameters (browser) / user args after `--` (desktop):
#   seed=<text> (default alpha; playing alone)  quality=light|full (browser default light, desktop full)
#   auto=1 (never capture the mouse; also when navigator.webdriver or testport=)  props=0  entity=0
#     Under automation the orientation tape never plays unless tape=1; playing alone READY is pressed at once
#     (ready=0: wait on the card for `ui ready`); with friends a test presses READY with the `ready` command.
#   join=<address> name=<text>: open the join form filled in (quick joining)
#   delay=<seconds>: FOR LOCAL TESTS ONLY. Every message to and from the server waits this long (a slow
#     link; play_hide runs one client at 0.3). hidebreak=arrival: play_hide's deliberate break (the count
#     timed from when its event arrived on this screen, client/hide_view.gd).
#   pass=<text>: FOR LOCAL TESTS ONLY. With join= and name= it joins at once, through the form's own
#     Join. It shows in the address bar, the browser history and the process list: never put a real
#     passphrase there.
#   server port=N ...: the Windows build starts the dedicated server instead (server/server.gd).
# Test hook (browser): window.gdCmd("<command>") -> window.gdResult; desktop: testport=N; see _command().
extends Node

const PlayLink = preload("res://client/play_link.gd")
const Session = preload("res://net/session.gd")
const Places = preload("res://sim/places.gd")
const EyeHeight = preload("res://client/eye_height.gd")
const RoomClient = preload("res://net/room_client.gd")
const LocalRoom = preload("res://net/local_room.gd")
const Protocol = preload("res://net/protocol.gd")
const Move = preload("res://sim/move.gd")
const Prison = preload("res://sim/prison.gd")
const PrisonView = preload("res://client/prison_view.gd")
const FaceKiosk = preload("res://client/face_kiosk.gd")
const Run = preload("res://sim/run.gd")
const Day = preload("res://sim/day.gd")
const HideView = preload("res://client/hide_view.gd")
const QuotaView = preload("res://client/quota_view.gd")
const DownView = preload("res://client/down_view.gd")
const HintCues = preload("res://client/hint_cues.gd")
const DayView = preload("res://client/day_view.gd")
## Logs, crash and F9 reports for game night (client/telemetry.gd): read-only on this node.
const Telemetry = preload("res://client/telemetry.gd")
const BuildInfo = preload("res://net/build_info.gd")

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
## The car waits (FD4): "CAR WAITING FOR: ..." shows once the arrival doors have stood open this long (ms),
## so the ordinary step out of the car never flashes it.
const CAR_WAIT_SHOW_MS := 4000
## The car waits (FD4): the dark screen of a player the car left out for the day.
const LEFT_OUT_LINES: Array = ["LEFT BEHIND", "", "YOU WAKE IN THE PRISON", "NO PAY TODAY"]
## The emote wheel, clockwise from the top (Protocol.EMOTES order).
const EMOTE_LABELS: Array[String] = ["WAVE", "LOOK BEHIND", "PRAY", "DANCE SPIN", "DANCE SNAKE", "BUTTON"]
## The wheel's dead zone (window pixels of mouse travel): letting go inside it cancels.
const WHEEL_DEAD := 40.0
## Name tags show only this close (m, body to body; 0 = never). Not knowing who is who further off is
## part of the fear (a teammate may wear the wrong face): ask, or walk up to them.
const TAG_RANGE := 2.0
## Giving up on a connection that never opens (seconds).
const CONNECT_TIMEOUT := 10.0
## The announcer's welcome waits this long after the run appears on screen (findables-and-day.md section 2).
const WELCOME_HOLD := 2.0

var link: PlayLink = null
var sub: SubViewport
var env: Environment
var cam: Camera3D
var world: Node3D
var level: Level
var lift: Lift
## The resident's view on this floor: an OrderlyView, or a TempView in the Annex (_use_resident).
var orderly: Node3D
var _resident_kind := "orderly"
var others: OthersView
var sfx: Sfx
var announcer: Announcer
var hud: Hud
var start: StartScreen
## The face kiosk's editor over the game (client/face_kiosk.gd): opened by F at the prison's kiosk, or
## by the test hook. Done changes the face for everyone in the run.
var kiosk: FaceKiosk
var inst_view: InstrumentView
## The Playroom's count and hiding on screen (client/hide_view.gd).
var hide_view: HideView
## The floor quota on screen: the call panel, a refused press, the line under the prompt (client/quota_view.gd).
var quota_view := QuotaView.new()
## Down first, then out on screen: your timer, the help prompt, the out screen, the red spots (client/down_view.gd).
var down_view := DownView.new()
## The hints this screen triggers itself (client/hint_cues.gd; the gate is client/hints.gd, AH1).
var hint_cues := HintCues.new()
## The day quota on screen (FD3): the HUD's corner line, the lift's day monitor and BANK paint, CLOSED UNTIL MORNING (client/day_view.gd).
var day_view := DayView.new()
## Tests: the host tick of the snapshot the day view was last drawn from.
var _day_view_tick := -1
## The floor's red spots are drawn under this (rebuilt with each floor).
var spots_root: Node3D = null
## Caught and down: until when (msec) the camera turns to the resident bent over you (B6: "turns you
## round to face it").
var _turn_until := -1
## Seconds the camera takes to settle on the resident, and how long it is held there.
const TURN_RATE := 5.0
const TURN_MS := 3500
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
## "title", "join", "connecting", "lobby", "game".
var mode := "title"
var join_arg := ""
var name_arg := ""
var pass_arg := ""
## Tests: tape=1 plays the orientation tape under automation; ready=0 keeps an automated lone player on the card.
var tape_arg := false
var ready_arg := true
## Ready-up: whether the tape has been decided for this room (once per join); the welcome waiting for its
## hold (armed at a new run), and when (seconds, _now) it is due: WELCOME_HOLD after the first frame of the car.
var _tape_decided := false
var _welcome_armed := false
var _welcome_due := -1.0
## Esc pressed in the game: the controls menu shows until the mouse is captured again.
var _esc_menu := false
## Tests (FD6): when this screen entered the run (unix ms), first drew the car, and the welcome started; whether
## the controls menu or a voice line showed in the first WELCOME_HOLD seconds.
var _entry := {}
var _t0_us := 0
var _connect_at := 0.0
var _ever_connected := false
var _leaving := false
var _client_seen: Object = null

# Test overrides (empty / null = from the keyboard and mouse).
var t_move: Array = []     # [f, r, sprint, creep]
var t_raise: Variant = null
## Tests: show the menu although the mouse is never captured under automation.
var t_menu := false
var t_hold: Variant = null
## Tests: F held (the bunk), or null for the keyboard.
var t_use: Variant = null
var pending_call := false
var pending_pick := false
## F pressed for a hide (the Playroom); tests: W held in a hide (peek), or null for the keyboard.
var pending_hide := false
var pending_hide_fast := false
## Whether S was held in a desk last frame (a new press of S crawls out).
var _desk_back := false
var t_peek: Variant = null
## Tests: seconds of delay on the link to the server (delay=); bus peaks logged every frame (peaklog).
var delay_arg := 0.0
var _peaklog_on := false
var _peaklog: Array = []
## Tests: the seek block's health of every player in the last snapshots ([t, {id: health}]), so a test
## can compare one screen's bar with another screen's copy of the same host tick.
var _seek_hist: Array = []
## The instrument is out: E toggles it (the right mouse button still raises it while held).
var raise_latch := false
## The emote wheel (hold R): open, the aim (window pixels from the middle).
var wheel_open := false
var wheel_vec := Vector2.ZERO
var _note_until := 0
## The controls over the start screen (Esc).
var menu_overlay := false

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
## The car waits (FD4): what the call panel says while the car waits for someone aboard ("" for nothing),
## and when (msec) the arrival doors were first seen open (-1 while they are not).
var car_waiting := ""
var _unload_since := -1
var lifetime := 0.0
var tick_acc := 0.0
var event_counts: Dictionary = {}
var event_log: Array = []
var emotes_seen: Array = []
## The camera's eye against the client's (main.gd _eye_check), for the tests.
var eye_stats: Dictionary = {}
var frames := 0
var game_frames := 0
var _ft_sum := 0.0
var _ft_n := 0
var _ft_max := 0.0
var rules_ms_sum := 0.0
var rules_ms_max := 0.0
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
var _stats_t0 := 0.0
var _stats_bytes := [0, 0]
# The day loop on screen (_show_day): the prison has no resident; the morning's note until this time;
# the report board's lines as shown; whether it is lights out on this screen.
var _no_resident := false
var _day_note_until := -1
var _board: Array[String] = []
var _lights_out := false

func _ready() -> void:
	if OS.get_cmdline_user_args().has("scene=annex_demo"):
		process_mode = Node.PROCESS_MODE_DISABLED
		get_tree().change_scene_to_file.call_deferred("res://client/annex_demo.tscn")
		return
	if OS.get_cmdline_user_args().has("scene=playroom_demo"):  # the Playroom's look and the Minder (client/playroom_demo.gd)
		process_mode = Node.PROCESS_MODE_DISABLED
		get_tree().change_scene_to_file.call_deferred("res://client/playroom_demo.tscn")
		return
	# The Windows build doubles as the dedicated server: `GoingDown.exe --headless -- server port=N`.
	if "server" in OS.get_cmdline_user_args():
		get_tree().change_scene_to_file.call_deferred("res://server/server.tscn")
		return
	if OS.get_cmdline_user_args().has("scene=prison_demo"):  # the Prison hub look, no day loop (client/prison_demo.gd)
		process_mode = Node.PROCESS_MODE_DISABLED
		get_tree().change_scene_to_file.call_deferred("res://client/prison_demo.tscn")
		return
	if OS.get_cmdline_user_args().has("scene=tape"):  # the orientation tape on its own (client/tape_demo.gd)
		process_mode = Node.PROCESS_MODE_DISABLED
		get_tree().change_scene_to_file.call_deferred("res://client/tape_demo.tscn")
		return
	var t0 := Time.get_ticks_msec()
	_t0_us = Time.get_ticks_usec()
	# Where the client makes its plans: every floor from the game's deck (the third floor down is the
	# Annex, the fourth the Playroom), the same deck the room it plays in gives the run (sim/places.gd).
	Session.deck = Places.FULL
	_reset_eye_stats()
	_read_options()
	_add_actions()
	_build_view()
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
	add_child(Telemetry.new(self))
	start.remember = not automated
	# A test never reads or writes the player's tape record (user://tape.cfg), like the hints' record.
	start.persist_tape = not automated
	if automated:
		start.tape_seen = false
		# A test starts with no hint record and never writes the player's (user://hints.cfg).
		announcer.persist = false
		announcer.hints.from_save({})
		# A test draws its own faces and must never change the player's saved one.
		FaceCodec.save_path = "user://face/test_last_face.txt"
	if not join_arg.is_empty():
		start.address = join_arg
	if not name_arg.is_empty():
		start.player_name = name_arg.left(StartScreen.MAX_NAME)
	if not join_arg.is_empty():
		start.passphrase = pass_arg
		pass_arg = ""
		# Quick joining: the face step first, then the form (pressed at once when it is filled in).
		_show_start("join")
		var filled := not start.address.is_empty() and not start.player_name.is_empty() and not start.passphrase.is_empty()
		start.open_face("join_submit" if filled else "join")
	else:
		_show_start("title")
	load_ms = Time.get_ticks_msec() - t0
	print("client ready in %d ms; quality %s" % [load_ms, quality])
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--bench="):
			_bench(float(a.substr(8)))

# Desktop measurement: play alone, stand in the clean corridor nearest the lift for `secs`, print frame
# times (and the in-process room's cost per frame), quit.
func _bench(secs: float) -> void:
	automated = true
	_play_alone()
	await get_tree().create_timer(1.5).timeout
	var pl := link.plan_dict
	var best: Dictionary = {}
	var best_d := INF
	var lift_dist: Array = pl["liftDist"]
	var w := int(pl["width"])
	for sl: Dictionary in pl["sightlines"]:
		if int(sl["level"]) != 0 or int(sl["length"]) < 6:
			continue
		var d := float(lift_dist[int(sl["y1"]) * w + int(sl["x1"])]) + float(lift_dist[int(sl["y2"]) * w + int(sl["x2"])])
		if d < best_d and d >= 0.0:
			best_d = d
			best = sl
	if not best.is_empty():
		link.teleport(0, int(best["x1"]), int(best["y1"]))
		yaw = atan2(-(float(best["x2"]) - float(best["x1"])), -(float(best["y2"]) - float(best["y1"])))
	await get_tree().create_timer(1.5).timeout
	_reset_stats()
	var f0 := game_frames
	await get_tree().create_timer(secs).timeout
	print("bench (%s): %d frames, mean %.2f ms, max %.2f ms, rules (in-process room) %.3f ms/frame, draw calls %d" % [quality, _ft_n, 1000.0 * _ft_sum / maxi(_ft_n, 1), 1000.0 * _ft_max,
		rules_ms_sum / maxi(game_frames - f0, 1), RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)])
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
	return str(JavaScriptBridge.eval("new URLSearchParams(location.search).get('%s') ?? '%s'" % [key, fallback.replace("\\", "").replace("'", "")], true))

func _read_options() -> void:
	var args := OS.get_cmdline_user_args()
	quality = "light" if OS.has_feature("web") else "full"
	# Desktop: `-- seed=x quality=full auto=1 props=0 entity=0 testport=4460 join=... name=...` (a leading -- is fine too).
	for raw in args:
		var a := raw.trim_prefix("--")
		var key := a.get_slice("=", 0)
		var val := a.substr(key.length() + 1) if a.contains("=") else "1"
		match key:
			"seed": seed = val
			"quality": quality = val
			"auto": automated = val != "0"
			"props": props_on = val != "0"
			"entity": entity_on = val != "0"
			"testport": _test_port = int(val)
			"join": join_arg = val
			"name": name_arg = val
			"pass": pass_arg = val
			"delay": delay_arg = clampf(float(val), 0.0, 2.0)
			"hidebreak": HideView.test_break = val
			"tape": tape_arg = val != "0"
			"ready": ready_arg = val != "0"
	if OS.has_feature("web"):
		seed = _url("seed", seed)
		quality = _url("quality", quality)
		props_on = _url("props", "1") != "0"
		entity_on = _url("entity", "1") != "0"
		join_arg = _url("join", "")
		name_arg = _url("name", "")
		pass_arg = _url("pass", "")
		tape_arg = _url("tape", "0") == "1"
		ready_arg = _url("ready", "1") != "0"
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
	others = OthersView.new()
	others.name = "Others"
	sub.add_child(others)
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
	hide_view = HideView.new()
	hide_view.name = "HideView"
	add_child(hide_view)
	hide_view.setup(self, sub)
	hud = Hud.new()
	add_child(hud)
	start = StartScreen.new()
	start.name = "StartScreen"
	add_child(start)
	start.alone_pressed.connect(_play_alone)
	start.join_pressed.connect(_join)
	start.back_pressed.connect(_back_to_title)
	start.start_pressed.connect(_lobby_start)
	start.leave_pressed.connect(_leave_room)
	start.screen_shown.connect(_on_screen_shown)
	start.ready_pressed.connect(_on_ready_pressed)
	start.watch_tape_pressed.connect(_watch_tape)
	start.tape_finished.connect(_on_tape_finished)
	kiosk = FaceKiosk.new()
	kiosk.name = "FaceKiosk"
	kiosk.remember = true
	add_child(kiosk)
	kiosk.changed.connect(_kiosk_changed)
	sfx = Sfx.new()
	add_child(sfx)
	var audio3d := Node3D.new()
	audio3d.name = "Audio3D"
	sub.add_child(audio3d)
	sfx.setup(audio3d)
	others.sfx = sfx
	announcer = Announcer.new()
	add_child(announcer)

func _now() -> float:
	return (Time.get_ticks_usec() - _t0_us) / 1000000.0

# --- the start screen and the room ----------------------------------------------------------------

func _show_start(which: String) -> void:
	mode = which
	start.show_screen(which)
	hud.end_lines = []
	hud.tags = []
	hud.prompt = ""
	hud.subtitle = ""
	hud.osd_on = false
	hud.wheel_on = false
	hud.click_to_look = false
	wheel_open = false
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

## The start screen moved on by itself (the face step to the form): keep the mode in step.
func _on_screen_shown(which: String) -> void:
	if which != "" and mode != "game":
		mode = which

## "Play alone": a room on this machine, a run at once.
func _play_alone() -> void:
	var lr := LocalRoom.new()
	var nm := start.player_name if not start.player_name.is_empty() else "YOU"
	lr.open_local(seed, nm, entity_on, start.face_code)
	# The game's run is a run of days: BANK rides up to the prison, bed starts the next day.
	lr.days = true
	link = PlayLink.new(lr, true)
	start.error = ""
	_tape_decided = false
	if automated and ready_arg and not tape_arg:
		# Under automation READY is pressed at once (the scripted playthroughs start in the car as before).
		lr.set_ready(true)
		_enter_game()

## "Join friends": the form's Join.
func _join(address: String, player_name: String, passphrase: String) -> void:
	var url := ws_url(address)
	var rc := RoomClient.new()
	var err := rc.connect_to(url, passphrase, player_name, start.face_code)
	if err != OK:
		start.error = "THAT ADDRESS DOES NOT LOOK RIGHT: " + url.to_upper()
		_show_start("join")
		return
	print("joining %s as %s" % [url, player_name])
	rc.delay = delay_arg
	link = PlayLink.new(rc, false)
	_tape_decided = false
	_connect_at = _now()
	_ever_connected = false
	_leaving = false
	_show_start("connecting")

## An address as a friend types it: ws:// or wss:// kept; http(s):// turned into ws(s)://; a bare host
## gets ws:// on a home network (localhost, 127.x, 10.x, 192.168.x, 172.16-31.x, a name with no dot)
## and wss:// otherwise.
static func ws_url(address: String) -> String:
	var a := address.strip_edges()
	if a.begins_with("http://"):
		return "ws://" + a.substr(7)
	if a.begins_with("https://"):
		return "wss://" + a.substr(8)
	if a.contains("://"):
		return a
	var host := a.get_slice("/", 0).get_slice(":", 0)
	var home := host == "localhost" or host.begins_with("127.") or host.begins_with("10.") or host.begins_with("192.168.") or not host.contains(".")
	if host.begins_with("172.") and host.get_slice(".", 1).is_valid_int():
		var b := int(host.get_slice(".", 1))
		home = home or (b >= 16 and b <= 31)
	return ("ws://" if home else "wss://") + a

func _back_to_title() -> void:
	if link != null:
		_leaving = true
		link.rc.leave()
		link = null
	_clear_world()
	start.error = ""   # the error belonged to the join form the player just left
	_show_start("title")

## The host's START WITHOUT (the room ignores it from anyone else, or before 30 s).
func _lobby_start() -> void:
	if link != null:
		link.rc.start_run()

## I'M READY (or undone) on the card.
func _on_ready_pressed(on: bool) -> void:
	if link != null:
		link.rc.set_ready(on)

## WATCH THE TAPE on Ready-up: not ready while it plays (the others see WATCHING THE TAPE).
func _watch_tape() -> void:
	if link == null:
		return
	start.my_ready = false
	link.rc.set_ready(false, true)
	mode = "tape"
	start.play_tape()

func _on_tape_finished(_skipped: bool) -> void:
	if link != null:
		link.rc.set_ready(false)
		start.my_ready = false
		_show_start("lobby")

## FD6: whether this screen shows the run: only after this player's own READY, and once the room has put
## them in it (a late joiner waits on Ready-up for the next stop). Never on the room's running flag alone.
static func run_view_on(my_ready: bool, _run_on: bool, playing: bool) -> bool:
	return my_ready and playing

## Before the run: the tape the first time, then Ready-up, kept in step with the room.
func _pre_run(rc: RoomClient, now: float) -> void:
	if not _tape_decided:
		_tape_decided = true
		if StartScreen.wants_tape(start.tape_seen, automated, tape_arg):
			rc.set_ready(false, true)
			_clear_world()
			menu_overlay = false
			mode = "tape"
			start.play_tape()
			return
	if mode == "tape":
		return
	if mode != "lobby":
		_clear_world()
		menu_overlay = false
		_show_start("lobby")
	start.people = rc.people
	start.my_id = rc.my_id
	start.run_on = rc.run_on
	start.host_id = rc.host_id
	start.my_ready = rc.my_ready
	start.count_left = rc.start_at - now if rc.start_at >= 0.0 and not rc.run_on else -1.0
	start.without_ok = rc.host_id == rc.my_id and rc.without_at >= 0.0 and now >= rc.without_at and not rc.run_on
	start.run_depth = rc.run_depth if rc.run_on else -1

func _leave_room() -> void:
	_back_to_title()

func _enter_game() -> void:
	# The tape and the controls card came before this (_pre_run, start_screen.gd); the run is on for this player.
	mode = "game"
	start.show_screen("")
	menu_overlay = false
	hud.osd_on = true
	snap = {}
	_client_seen = null
	_esc_menu = false
	_entry = {"enteredUnix": Time.get_unix_time_from_system() * 1000.0, "enteredAt": _now(), "menuEarly": false, "voiceEarly": false}
	# The desktop takes the mouse on entering, so the controls menu does not cover the car (it stays on Esc).
	# The browser needs a click for that: CLICK TO LOOK shows instead. Never under automation.
	if not automated and not OS.has_feature("web"):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

## Plain words for why the connection closed.
func _close_words(code: int) -> String:
	match code:
		4001:
			return "WRONG PASSPHRASE. ASK WHOEVER RUNS THE SERVER FOR TONIGHT'S."
		4002:
			return "THE ROOM IS FULL: 8 PLAYERS ARE IN."
		4003, 4004, 4005, 4006:
			return "THE SERVER DROPPED THIS GAME: CODE %d." % code
		4007:
			return BuildInfo.OUT_OF_DATE.to_upper()
	if not _ever_connected:
		return "CANNOT REACH THE SERVER. CHECK THE ADDRESS. AFTER WRONG PASSPHRASES IT REFUSES THIS PC FOR UP TO A MINUTE."
	if code == 1001:
		return "THE SERVER STOPPED."
	return "CONNECTION LOST."

func _clear_world() -> void:
	kiosk.close()
	for c: Node in world.get_children():
		c.queue_free()
	level = null
	lift = null
	built_depth = -1
	orderly.call(&"reset")
	others.clear()
	snap = {}
	sfx.ride(false)
	sfx.set_hum(0.0)
	sfx.update(0.0, {}, null, 0.0, 0.0, 0.0, false, 0.0, Vector3.ZERO)
	sfx.clear_floor()
	hide_view.reset()
	down_view.reset()
	spots_root = null

# --- runs and floors ----------------------------------------------------------------------------

## A run has begun on this screen (alone or with friends): the presentation starts fresh.
func _on_new_run() -> void:
	hint_cues.reset()
	pitch = 0.0
	raise_latch = false
	ending = {}
	end_shown_at = -1
	hud.end_lines = []
	caught_at = -1
	left_at = -1
	ride_started = -1
	prev_bell_left = BOARD_TIME
	built_depth = -1
	others.clear()
	sfx.ride(false)
	hud.set_seed(str(link.client().seed) if link.client().seed != null else seed)
	quota_view.reset()
	down_view.reset()
	_turn_until = -1
	# The welcome is held WELCOME_HOLD seconds (the car and the crew first, then the voice). In a browser
	# nothing is heard before the first click or key (autoplay rules): it also waits for one.
	_welcome_armed = true
	_welcome_due = -1.0
	_welcome_pending = not _gesture and OS.has_feature("web")

## Alone: a new run (the end screen's key, the test hook).
func _new_run() -> void:
	if link == null or not link.local:
		return
	link.rc.start_run()

func _build_floor(plan: Dictionary) -> void:
	for c: Node in world.get_children():
		c.queue_free()
	level = Level.new()
	level.name = "Level"
	level.shadows = quality == "full"
	level.props_on = props_on
	world.add_child(level)
	level.build(plan, str(snap.get("seed", seed)))
	sfx.set_floor(plan, str(snap.get("seed", seed)))
	lift = Lift.new()
	lift.name = "Lift"
	world.add_child(lift)
	lift.build(plan["car"], level.lift_left_wall())
	lift.set_doors(false, true)
	lift.set_faces(link.crew_faces())
	_use_resident(plan)
	hide_view.reset()
	spots_root = Node3D.new()
	spots_root.name = "RedSpots"
	world.add_child(spots_root)
	built_depth = int(plan["depth"])
	level.set_emergency(0.0)
	level.set_light_level(1.0)
	print("floor %d built: %d lights, %d flickering, %d emergency, %d props (%d overturned)" % [built_depth, level.main_lights.size(), level.flickers.size(), level.emergency_lights.size(), level.props_placed, level.props_overturned])

## THE one place the resident's view is chosen, by the plan's place: the Annex's is the Temp
## (client/temp_view.gd, with its own stapler click, so the trolley squeak stays the Orderly's), anywhere
## else the Orderly. The Playroom's Minder gets its own line here.
func _use_resident(plan: Dictionary) -> void:
	var kind := "orderly"
	match str(plan.get("place", "")):
		"annex":
			kind = "temp"
		"playroom":  # the Minder (client/minder_view.gd): not Stillness, so it follows the un-held pose
			kind = "minder"
	# The prison has no resident (Places.resident names none): nothing is drawn there.
	_no_resident = Places.resident(StringName(str(plan.get("place", "")))).name == ""
	if kind != _resident_kind:
		var view: Node3D = TempView.new() if kind == "temp" else (MinderView.new() if kind == "minder" else OrderlyView.new())
		view.name = kind.capitalize()
		orderly.queue_free()
		orderly = view
		sub.add_child(view)
		_resident_kind = kind
	orderly.call(&"reset")
	if orderly is TempView:
		(orderly as TempView).set_crew(str(snap.get("seed", seed)), link.crew_faces())
		(orderly as TempView).set_floor(link.plan, level)
	if orderly is MinderView:
		(orderly as MinderView).set_floor(link.plan, level)
		(orderly as MinderView).follow(link)

# --- input --------------------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if (event is InputEventMouseButton or event is InputEventKey) and event.is_pressed() and not _gesture:
		_gesture = true
		_welcome_pending = false
	if mode != "game":
		# The start screen: Esc shows the controls (not on the face step, the tape or Ready-up, whose card is
		# the controls); everything else is the screen's.
		if event is InputEventKey:
			var k0 := event as InputEventKey
			if k0.pressed and not k0.echo and k0.physical_keycode == KEY_ESCAPE and not start.screen in ["face", "tape", "lobby"]:
				menu_overlay = not menu_overlay
			elif menu_overlay and k0.pressed and not k0.echo and k0.physical_keycode == KEY_H:
				_set_hints(not announcer.hints.enabled)
			elif not menu_overlay:
				start.key(k0)
			get_viewport().set_input_as_handled()
		return
	if kiosk.is_open():
		# The kiosk's editor has the keys (Enter done, Esc cancel) and its own mouse.
		if event is InputEventKey:
			kiosk.key(event as InputEventKey)
			get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		# The mouse is captured only after a real click, never under automation.
		if mb.pressed and not automated and mb.button_index == MOUSE_BUTTON_LEFT and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not wheel_open:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			_esc_menu = false
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if wheel_open:
			# The wheel takes the mouse: captured, its travel; free, where it points from the middle.
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
				wheel_vec = (wheel_vec + mm.relative).limit_length(300.0)
			else:
				wheel_vec = mm.position - get_viewport().get_visible_rect().size * 0.5
		elif Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			yaw -= mm.relative.x * SENS
			pitch = clampf(pitch - mm.relative.y * SENS, -MAX_PITCH, MAX_PITCH)
	elif event is InputEventKey:
		var k := event as InputEventKey
		if k.physical_keycode == KEY_R and not k.echo:
			if k.pressed:
				_wheel_open()
			else:
				_wheel_release()
			return
		if not k.pressed or k.echo:
			return
		if k.physical_keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			wheel_open = false
			_esc_menu = true
		elif not hud.end_lines.is_empty() and Time.get_ticks_msec() - end_shown_at > 1200:
			_new_run()
		elif k.physical_keycode == KEY_E:
			raise_latch = not raise_latch
		elif k.physical_keycode == KEY_F and _station() == "kiosk":
			_open_kiosk()
		elif k.physical_keycode == KEY_F:
			pending_call = true
			pending_pick = true
			pending_hide = true
			pending_hide_fast = Input.is_action_pressed("sprint")
		elif k.physical_keycode == KEY_H:
			_set_hints(not announcer.hints.enabled)
		elif k.physical_keycode == KEY_T:
			var st: float = tape_mat.get_shader_parameter("strength")
			tape_mat.set_shader_parameter("strength", 0.0 if st > 0.5 else 1.0)

## HINTS: ON / OFF (the Esc menu's H): the announcer's hints, kept for this player in user://hints.cfg.
func _set_hints(on: bool) -> void:
	announcer.set_hints_on(on)
	hud.hints_on = on
	hud.note = "HINTS ON" if on else "HINTS OFF"
	_note_until = Time.get_ticks_msec() + 1500

func _wheel_open() -> void:
	if mode != "game" or snap.is_empty() or snap.has("waiting"):
		return
	wheel_open = true
	wheel_vec = Vector2.ZERO

## The emote aimed at (-1 inside the dead zone).
func _wheel_sel() -> int:
	if wheel_vec.length() < WHEEL_DEAD:
		return -1
	var n := EMOTE_LABELS.size()
	var a := atan2(wheel_vec.y, wheel_vec.x) + PI / 2.0
	return posmod(int(roundf(a / (TAU / n))), n)

## Letting go of R: the emote aimed at, or nothing (a tap closes the wheel).
func _wheel_release() -> String:
	if not wheel_open:
		return ""
	wheel_open = false
	var sel := _wheel_sel()
	if sel < 0:
		return ""
	var which: String = Protocol.EMOTES[sel]
	_send_emote(which)
	return which

func _send_emote(which: String) -> void:
	if link == null or link.client() == null:
		return
	link.client().emote(which)
	hud.note = "> " + EMOTE_LABELS[Protocol.EMOTES.find(which)]
	_note_until = Time.get_ticks_msec() + 1500

## What the player stands at in the prison (Prison.station_at: "shop", "skills", "kiosk"), "" elsewhere
## or on any other floor.
func _station() -> String:
	if link == null or str(link.plan_dict.get("place", "")) != String(Prison.PLACE) or snap.is_empty() or not snap.has("me"):
		return ""
	var me: Dictionary = snap["me"]
	if int(me["level"]) != 0:
		return ""
	return String(Prison.station_at(Vector2i(floori(float(me["x"]) / Prison.CELL_SIZE), floori(float(me["z"]) / Prison.CELL_SIZE))))

## The face kiosk: the editor over the game, on this player's current face. False when not in a run.
func _open_kiosk() -> bool:
	if mode != "game" or link == null or link.client() == null:
		return false
	wheel_open = false
	kiosk.open(start.face_code)
	return true

## The kiosk's Done: the new face is this player's from now on, on every screen in the run (the host
## passes it on) and in every later run's join.
func _kiosk_changed(code: String) -> void:
	start.face_code = code
	if link != null:
		link.rc.set_face(code)
	hud.note = "> FACE CHANGED"
	_note_until = Time.get_ticks_msec() + 1500

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
	hud.menu_foot = "CLICK TO PLAY" if mode == "game" else "ESC TO GO BACK"
	hud.hints_on = announcer.hints.enabled
	if Time.get_ticks_msec() > _note_until:
		hud.note = ""
	if link == null:
		hud.menu_on = menu_overlay
		return
	var now := _now()
	if _peaklog_on and _peaklog.size() < 20000:
		var pk := _bus_peaks()
		_peaklog.append([now, snap.get("hostNow", 0.0), pk.get("Voice", -200.0), pk.get("Master", -200.0)])
	var dt := minf(delta, 0.1)
	var s := link.step(now, _game_input(dt))
	if link == null:
		return
	var rc := link.rc
	if rc.status == "closed":
		var words := "" if _leaving else _close_words(rc.close_code)
		print("connection closed (code %d)" % rc.close_code)
		link = null
		_clear_world()
		start.error = words
		_show_start("join" if words != "" else "title")
		return
	if s.is_empty():
		# No run: connecting, or the lobby.
		if rc.status == "connecting":
			if mode != "connecting":
				_show_start("connecting")
			if now - _connect_at > CONNECT_TIMEOUT:
				rc.leave()
				link = null
				start.error = _close_words(-1)
				_show_start("join")
			return
		_ever_connected = true
		_pre_run(rc, now)
		hud.menu_on = menu_overlay
		return
	_ever_connected = true
	if mode != "game" and not run_view_on(rc.my_ready, rc.run_on, not s.has("waiting") and bool(s.get("playing", false))):
		# A run is on that this player is not in yet (still reading, watching the tape, or ready and waiting
		# for the next stop): Ready-up stays, with the late joiner's line.
		_pre_run(rc, now)
		hud.menu_on = menu_overlay
		return
	if mode != "game":
		_enter_game()
	if link.client() != _client_seen:
		_client_seen = link.client()
		_on_new_run()
	if s.has("waiting"):
		hud.center_note = "JOINING THE RUN..."
		return
	_game_frame(s, dt)
	game_frames += 1
	var ms := link.last_ms
	rules_ms_sum += ms
	rules_ms_max = maxf(rules_ms_max, ms)

## The player's intents this frame (keyboard and mouse, or the test's overrides).
func _game_input(dt: float) -> Dictionary:
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
	elif mode == "game" and not kiosk.is_open():
		f = Input.get_action_strength("forward") - Input.get_action_strength("back")
		r = Input.get_action_strength("right") - Input.get_action_strength("left")
		sprint = Input.is_action_pressed("sprint")
		creep = Input.is_action_pressed("creep")
	var raised: bool = t_raise if t_raise != null else (raise_latch or (mode == "game" and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)))
	var me: Dictionary = snap.get("me", {})
	var hold: bool = t_hold if t_hold != null else (mode == "game" and Input.is_action_pressed("use") and bool(me.get("nearHold", false)))
	var use: bool = t_use if t_use != null else (mode == "game" and not kiosk.is_open() and Input.is_action_pressed("use"))
	var call: bool = pending_call and bool(me.get("canCall", false))
	# The Playroom: F at a hide's front, or in a hide, is for the hide (the call wins at the lift).
	var my_seek: Variant = snap.get("mySeek")
	var in_hide := my_seek is Dictionary and str((my_seek as Dictionary)["phase"]) == "inside"
	var hide: bool = pending_hide and not call and (int(snap.get("nearHide", -1)) >= 0 or in_hide)
	var hide_fast: bool = pending_hide_fast or sprint
	# A desk (the Annex, sim/hiding.gd): no key press. Ctrl held and walking forward at its kneehole crawls
	# under; inside one, S (a new press of it) or F crawls back out. Never fast: Ctrl is a creep.
	var hcam: Dictionary = snap.get("hideCam", {})
	var desk_out := in_hide and str(hcam.get("kind", "")) == "desk" and f < 0.0 and not _desk_back
	_desk_back = in_hide and f < 0.0
	if not in_hide and creep and f > 0.0 and str(snap.get("nearHideKind", "")) == "desk" and not (my_seek is Dictionary and str((my_seek as Dictionary)["phase"]) != "out"):
		hide = true
		hide_fast = false
	elif desk_out:
		hide = true
		hide_fast = false
		f = 0.0
	var pick: bool = pending_pick and not call and not hide
	pending_call = false
	pending_pick = false
	pending_hide = false
	pending_hide_fast = false
	var peek: bool = t_peek if t_peek != null else (in_hide and f > 0.0)
	var aspect := 480.0 / 270.0
	var hfov := rad_to_deg(2.0 * atan(tan(deg_to_rad(VFOV) * 0.5) * aspect))
	return {"dt": dt, "f": f, "r": r, "sprint": sprint, "creep": creep, "yaw": yaw, "pitch": pitch,
		"hfov": hfov, "vfov": VFOV, "raised": raised and not still, "call": call, "hold": hold, "pickUp": pick, "still": still, "use": use,
		"hide": hide, "hideFast": hide_fast, "peek": peek}

func _game_frame(s: Dictionary, dt: float) -> void:
	var now := Time.get_ticks_msec()
	snap = s
	if s.get("autoYaw") != null:
		yaw = float(s["autoYaw"])
	var placed: Variant = s.get("placed")
	if placed is Dictionary and (placed as Dictionary).has("yaw"):
		yaw = float((placed as Dictionary)["yaw"])
		pitch = 0.0
	if s.has("plan"):
		_build_floor(s["plan"])
	if level == null:
		return
	announcer.place = str(link.plan_dict.get("place", ""))
	announcer.days_on = s.get("day") != null
	announcer.day_lock_on = DayView.lock_of(s.get("day")) != null
	announcer.my_id = link.my_id()
	_present(s.get("events", []), now)
	for em: Dictionary in s.get("emotes", []):
		others.play_emote(str(em["player"]), str(em["emote"]))
		emotes_seen.append({"player": em["player"], "emote": em["emote"]})
		if emotes_seen.size() > 40:
			emotes_seen.pop_front()
	var me: Dictionary = s["me"]
	var ended := not hud.end_lines.is_empty() or str(s.get("phase", "")) == "ended"
	var still := _noise_on() or ended

	# The camera: at this frame's eye height (standing, creeping, down; play_link.gd `eye`).
	cam.position = PlayLink.camera_point(me)
	# The Playroom: in a hide the camera sits back in it or leans to the gap, turned only within the gap.
	var hc: Dictionary = s.get("hideCam", {})
	if not hc.is_empty():
		cam.position = Vector3(float(hc["x"]), float(me["y"]) + float(me["eye"]), float(hc["z"]))
		yaw = float(hc["yaw"])
		pitch = float(hc["pitch"])
	var my_seek: Variant = s.get("mySeek")
	var held := my_seek is Dictionary and (str((my_seek as Dictionary)["phase"]) != "out" or str((my_seek as Dictionary)["status"]) != "ok")
	cam.rotation = Vector3(pitch, yaw, 0)
	if not held:
		_eye_check(me)

	# The Orderly: drawn exactly as the frame says (in the dark too, with nothing added: T20a), never while taken.
	var o: Dictionary = s["orderly"]
	# Two-watcher Stillness (T19a): the watched walk (set before the pose), and the eye marks. A run without a
	# count (solo, the rules bridge) has one mark, lit while it is seen.
	if orderly.has_method(&"set_watched"):
		orderly.call(&"set_watched", o.get("watchedAt"))
	orderly.call(&"show_pose", o.get("pose"), bool(o.get("visible", false)) and not _noise_on() and not _no_resident)
	var seen := bool(o.get("seeing", false)) and _resident_kind != "minder"
	hud.eyes = o.get("eyes", {"on": seen, "need": 1, "lit": 1, "all": true}) if not _noise_on() and not _no_resident else {}

	# Everyone else, and their name tags (not through walls, fading with distance, not in the dark).
	var dark: bool = s["dark"]
	others.update(dt, s["others"], cam.position)
	_name_tags(s, dark)

	# The lights: a blink's warning flickers, the dark is deep, the emergency lighting comes up.
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
	_lights_out = _is_lights_out(s)
	if _lights_out:
		light = 0.0   # the prison at lights out: only the cells' night lights
	level.set_light_level(light)
	sfx.set_hum(light, dark)
	sfx.world(dt, s, emergency)
	level.set_emergency(emergency)
	level.update_lights(dt, cam.global_position)
	env.ambient_light_color = level.ambient_color(emergency)
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
	lift.set_faces(link.crew_faces())
	lift.update(dt)
	if level.has_meta(&"prison"):
		# The face kiosk's screen shows this player's own face.
		var pv: Object = level.get_meta(&"prison")
		if str(pv.get("kiosk_face")) != start.face_code:
			pv.call("set_kiosk_face", start.face_code)
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
	var car: Dictionary = link.plan_dict["car"]
	sfx.update(dt, o["squeak"] if _resident_kind == "orderly" and not _no_resident else {}, o.get("pose"), tick_hz, loud, float(me["exertion"]) if not still else 0.0, bool(me["winded"]), machine,
		Vector3(float(car["doorX"]), float(car["floorY"]) + 1.5, float(car["doorZ"])), float(o.get("speed", 0.0)))
	if not _entry.has("carUnix"):
		_entry["carUnix"] = Time.get_unix_time_from_system() * 1000.0
	# The welcome's hold runs from the first frame of the car on this screen.
	if _welcome_armed and _welcome_due < 0.0:
		_welcome_due = _now() + WELCOME_HOLD
	if _welcome_armed and _now() >= _welcome_due and not _welcome_pending:
		_welcome_armed = false
		_welcome_due = -1.0
		_entry["welcomeUnix"] = Time.get_unix_time_from_system() * 1000.0
		announcer.start_run()
	# Nothing is said before the welcome (findables-and-day.md section 2: the car and the crew come first).
	if not _welcome_armed:
		announcer.update()
	if _now() - float(_entry.get("enteredAt", -INF)) < WELCOME_HOLD and announcer.speaking():
		_entry["voiceEarly"] = true
	sfx.duck(announcer.speaking(), dt)

	# The picture and the display.
	var noise := _noise_on()
	var black := caught_at >= 0 and now - caught_at < BLACK_MS
	tape_mat.set_shader_parameter("darkness", 1.0 if dark else 0.0)
	tape_mat.set_shader_parameter("tired", 0.85 * pow(float(me["exertion"]), 1.4) if not still else 0.0)
	tape_mat.set_shader_parameter("snow", 1.0 if (noise and not black) else 0.0)
	tape_mat.set_shader_parameter("glitch", 1.0 if noise else 0.0)
	hud.black = black
	# With the down rule the timer says it instead (client/down_view.gd).
	hud.went_down = caught_at >= 0 and now - caught_at >= BLACK_MS + NOISE_MS and now - caught_at < BLACK_MS + NOISE_MS + LINE_MS and ending.is_empty() and s.get("downs") == null
	var tapes: Dictionary = s["tapes"]
	hud.set_tapes(int(tapes["count"]), float(tapes["value"]))
	hud.subtitle = announcer.shown()
	hud.center_note = error_text if error_text != "" else ("WATCHING: YOU JOIN AT THE NEXT STOP" if not bool(s.get("playing", true)) else "")
	hud.wheel_on = wheel_open
	hud.wheel_labels = EMOTE_LABELS
	hud.wheel_sel = _wheel_sel() if wheel_open else -1
	# The menu (the controls) shows after Esc, while the mouse is free. Free without Esc (the browser on
	# entering, or the window lost the mouse): one line, CLICK TO LOOK, instead (findables-and-day.md section 2).
	var free := error_text == "" and not automated and not wheel_open and not kiosk.is_open() and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and hud.end_lines.is_empty()
	hud.menu_on = t_menu or (free and _esc_menu)
	hud.click_to_look = free and not _esc_menu and not t_menu
	if _now() - float(_entry.get("enteredAt", -INF)) < WELCOME_HOLD and hud.menu_on:
		_entry["menuEarly"] = true
	var prompt := ""
	var station := _station()
	var bed: Variant = s.get("bed")
	var home := s.get("day") != null and int(s["depth"]) == 0 and bed is Dictionary
	hud.prompt_fill = -1.0
	# Down first, then out (client/down_view.gd): your own timer or the out screen, or a crewmate to help.
	var holding: bool = t_use if t_use != null else (mode == "game" and not kiosk.is_open() and Input.is_action_pressed("use"))
	down_view.update(s, link.my_id(), link.names(), holding)
	var me_down := str(me["status"]) == "down" or str(me["status"]) == "out" or _left_out(s)
	if not ended and not noise and not kiosk.is_open() and not _lights_out and not me_down:
		if down_view.prompt != "":
			prompt = down_view.prompt
			hud.prompt_fill = down_view.fill
		elif home and bool((bed as Dictionary)["inBed"]):
			prompt = "F TO GET UP"
		elif home and bool((bed as Dictionary)["atBunk"]):
			prompt = "HOLD F TO SLEEP"
			hud.prompt_fill = float((bed as Dictionary)["hold"])
		elif station != "":
			prompt = PrisonView.tonight_prompt_for(Vector2i(floori(float(me["x"]) / Prison.CELL_SIZE), floori(float(me["z"]) / Prison.CELL_SIZE)))
		elif phase == "night":
			pass   # home for the night: the car cannot be called
		elif bool(me.get("canCall", false)):
			prompt = "F  ▼ CALL"
		elif bool(me.get("nearHold", false)):
			prompt = "F  <|> HOLD"
		elif _tape_in_reach(me):
			prompt = "F  PICK UP"
	hud.prompt = prompt
	_show_day_lock(s)
	_show_quota(now)
	if me_down:
		hud.quota_line = ""
	_show_day(s, now)
	_show_count(s, dt)
	var lc := link.client()
	hint_cues.update(announcer, s, lc.latest if lc != null else null, lc.quota() if lc != null else null, car_waiting, now)
	_show_down(s, now, dt, noise)
	var sk: Variant = s.get("seek")
	if sk is Dictionary and (_seek_hist.is_empty() or _seek_hist[-1][0] != s["t"]):
		var hs := {}
		for sp: Dictionary in (sk as Dictionary)["players"]:
			hs[str(sp["id"])] = sp["health"]
		# The tuned Playroom (T15m): the host's anger in that snapshot too, or null.
		_seek_hist.append([s["t"], hs, (sk as Dictionary).get("anger")])
		if _seek_hist.size() > 80:
			_seek_hist.pop_front()
	_show_end(now)

## The floor quota (client/quota_view.gd): the call panel shows the host's quota block, and its words go
## under the prompt while the call button is in reach or a refused press flashes.
func _show_quota(now: int) -> void:
	var c := link.client()
	hud.quota_line = quota_view.update(c.quota() if c != null else null, lift, hud.prompt == "F  ▼ CALL", now)
	hud.quota_tone = quota_view.tone
	# The car waits (FD4): standing open on arrival for whoever is still aboard, the panel says who.
	car_waiting = car_waiting_text(c.latest if c != null else null, link.names(), now)
	if car_waiting != "":
		lift.show_quota(car_waiting, "count", true)
		hud.quota_line = car_waiting
		hud.quota_tone = "count"
	# Home for the night (FD3): the shut car's panel says so, with no voice.
	if day_view.closed != "":
		lift.show_quota(day_view.closed, "refused", true)

## The day quota (client/day_view.gd, FD3): the HUD's corner line, the lift's day monitor and its BANK
## paint, all from the host's day block in this frame's snapshot.
func _show_day_lock(s: Dictionary) -> void:
	day_view.update(s)
	var dc := link.client()
	_day_view_tick = int((dc.latest as Dictionary)["tick"]) if dc != null and dc.latest is Dictionary else -1
	hud.day_line = day_view.hud_line
	hud.day_met = day_view.met
	if lift != null:
		lift.show_day(day_view.rows)
		lift.set_bank_locked(day_view.locked)

## The car waits (FD4; sim/run.gd car_waits): once the arrival doors have stood open CAR_WAIT_SHOW_MS, the
## words for the call panel and the HUD, "CAR WAITING FOR: DAVE" (everyone active still aboard, by name),
## or "" when nobody keeps it. From the host's newest snapshot only.
func car_waiting_text(latest: Variant, names: Dictionary, now: int) -> String:
	if not latest is Dictionary or str((latest as Dictionary).get("phase", "")) != "unloading":
		_unload_since = -1
		return ""
	if _unload_since < 0:
		_unload_since = now
	if now - _unload_since < CAR_WAIT_SHOW_MS:
		return ""
	var who: Array[String] = []
	for p: Dictionary in (latest as Dictionary)["players"]:
		if bool(p["aboard"]) and bool(p["active"]) and str(p["status"]) == "ok":
			who.append(str(names.get(str(p["id"]), str(p["id"]))).to_upper())
	if who.is_empty():
		return ""
	return "CAR WAITING FOR: " + ", ".join(who)

## The car waits (FD4): this player was left out by the car today (status "leftBehind" in a run with days):
## out of the run until the crew gets home.
func _left_out(s: Dictionary) -> bool:
	return s.get("day") != null and str((s["me"] as Dictionary)["status"]) == "leftBehind"

## Down first, then out (client/down_view.gd, already updated this frame): your timer and its lines (once
## the catch's noise has passed), the out screen, the red spots for everyone. Caught and down, the camera
## turns to the resident bent over you for the first moments (B6: it turns you round to face it).
func _show_down(s: Dictionary, now: int, dt: float, noise: bool) -> void:
	var shown := not noise and hud.end_lines.is_empty()
	hud.down_head = down_view.head if shown else ""
	hud.down_left = down_view.left
	hud.down_line = down_view.line
	hud.down_line2 = down_view.line2
	hud.down_heal = down_view.heal
	hud.out_on = down_view.out and hud.end_lines.is_empty()
	hud.out_lines = down_view.out_lines
	if _left_out(s) and hud.end_lines.is_empty():
		# The car waits (FD4): left out, the screen goes dark until the crew gets home.
		hud.out_on = true
		hud.out_lines = LEFT_OUT_LINES
	var block: Variant = s.get("downs")
	down_view.show_spots(spots_root, (block as Dictionary)["spots"] if block is Dictionary else [])
	if now < _turn_until and str((s["me"] as Dictionary)["status"]) == "down":
		var op: Variant = (s["orderly"] as Dictionary).get("pose")
		if op is Dictionary:
			var lv := Vector3(float(op["x"]), float(op["y"]) + 1.2, float(op["z"]))
			var want_yaw := atan2(-(lv.x - cam.position.x), -(lv.z - cam.position.z))
			var want_pitch := clampf(atan2(lv.y - cam.position.y, Vector2(lv.x - cam.position.x, lv.z - cam.position.z).length()), -MAX_PITCH, MAX_PITCH)
			var k := 1.0 - exp(-dt * TURN_RATE)
			yaw = yaw + wrapf(want_yaw - yaw, -PI, PI) * k
			pitch = lerpf(pitch, want_pitch, k)
			cam.rotation = Vector3(pitch, yaw, 0)

## The Playroom's count and hiding (client/hide_view.gd): the count dark, the bell, the tune, the
## captions, the hide prompts, the health bar; found, the camera turns to the Minder as it comes.
func _show_count(s: Dictionary, dt: float) -> void:
	hud.count_by = ""
	hud.seek_note = ""
	hud.health = -1.0
	var r := hide_view.update(s, dt, _now(), link.names(), link.my_id(), sfx, announcer, hud, level, s.get("others", []))
	# The count as this screen has it, for the hints' gate (client/hints.gd number_in).
	var cev: Dictionary = s.get("countEvent", {})
	announcer.count_ctx = {} if cev.is_empty() else {"phase": hide_view.count_phase, "left": hide_view.count_left,
		"len": int(roundf(float(cev.get("len", 0.0)))), "last": bool(cev.get("last", false))}
	if not bool(r.get("on", false)):
		return
	var dk := float(r["dark"])
	if dk > 0.0:
		tape_mat.set_shader_parameter("darkness", maxf(dk, 1.0 if bool(s["dark"]) else 0.0))
		env.background_color = Color(0.02, 0.025, 0.025) * (1.0 - dk)
	var nz := float(r["noise"])
	if nz > 0.0 and not _noise_on():
		tape_mat.set_shader_parameter("glitch", clampf(nz, 0.0, 1.0))
		tape_mat.set_shader_parameter("snow", clampf(float(r["catch"]) * 0.6, 0.0, 0.6))
	var look: Variant = r.get("look")
	if look is Vector3:
		var lv: Vector3 = look
		var want_yaw := atan2(-(lv.x - cam.position.x), -(lv.z - cam.position.z))
		var want_pitch := clampf(atan2(lv.y - cam.position.y, Vector2(lv.x - cam.position.x, lv.z - cam.position.z).length()), -MAX_PITCH, MAX_PITCH)
		var k := 1.0 - exp(-dt * 6.0)
		yaw = yaw + wrapf(want_yaw - yaw, -PI, PI) * k
		pitch = lerpf(pitch, want_pitch, k)
		cam.rotation = Vector3(pitch, yaw, 0)

## Tests: on every frame, the camera as drawn against the client's own camera for that frame (the eye
## sight was judged from) and, on frames an input went, the eye in the input as sent; counted by state
## (stand, creep, down), with the lowest and highest eye drawn in each.
func _eye_check(me: Dictionary) -> void:
	var c := link.client()
	if c == null or c.last_camera == null:
		return
	var lc := c.last_camera
	var want := Vector3(lc.body.x, lc.body.y + lc.eye, lc.body.z)
	var drawn := cam.position.y - float(me["y"])
	var st := "down" if EyeHeight.target(str(me["status"]), "walk") == EyeHeight.DOWN else ("creep" if str(me["gait"]) == "creep" else "stand")
	var e: Dictionary = eye_stats[st]
	e["frames"] = int(e["frames"]) + 1
	e["min"] = minf(float(e["min"]), drawn)
	e["max"] = maxf(float(e["max"]), drawn)
	var diff := cam.position.distance_to(want)
	eye_stats["maxDiff"] = maxf(float(eye_stats["maxDiff"]), diff)
	if diff > 0.001:
		eye_stats["mismatch"] = int(eye_stats["mismatch"]) + 1
	if c.last_input_frame == c.stats.frames:
		var m: Variant = Protocol.decode(c.last_input)
		if m is Dictionary:
			var sent := float((m as Dictionary)["eye"])
			eye_stats["sent"] = int(eye_stats["sent"]) + 1
			eye_stats["maxSentDiff"] = maxf(float(eye_stats["maxSentDiff"]), absf(sent - drawn))
			if absf(sent - drawn) > 0.001:
				eye_stats["sentMismatch"] = int(eye_stats["sentMismatch"]) + 1

func _reset_eye_stats() -> void:
	eye_stats = {"mismatch": 0, "maxDiff": 0.0, "sent": 0, "sentMismatch": 0, "maxSentDiff": 0.0}
	for st: String in ["stand", "creep", "down"]:
		eye_stats[st] = {"frames": 0, "min": 99.0, "max": -99.0}

## Name tags over the other players: projected from the head into the window, only within TAG_RANGE,
## never through walls (the rules' line of sight), not in the dark.
func _name_tags(s: Dictionary, dark: bool) -> void:
	var tags: Array = []
	var win := get_viewport().get_visible_rect().size
	var k := Vector2(win.x / 480.0, win.y / 270.0)
	var vb := link.view_body()
	var open: bool = s["doorsOpen"]
	for o: Dictionary in s["others"]:
		# Over the head, wherever their eyes are: standing, creeping lower, down near the floor.
		var eye_h := EyeHeight.target(str(o["status"]), str(o["gait"]))
		var head := Vector3(float(o["x"]), float(o["y"]) + eye_h + 0.4, float(o["z"]))
		var d := head.distance_to(cam.position)
		# Full within the nearer 85 % of TAG_RANGE, fading out over the rest (no pop at the edge).
		var near := Vector2(head.x - cam.position.x, head.z - cam.position.z).length()
		var a := clampf((TAG_RANGE - near) / (0.15 * TAG_RANGE), 0.0, 1.0) if TAG_RANGE > 0.0 else 0.0
		var shown := not dark and a > 0.0 and not cam.is_position_behind(head) and d > 0.4 and str(o["status"]) != "out"
		if shown:
			shown = link.can_see_point(vb, Vector3(head.x, float(o["y"]) + eye_h - 0.05, head.z), int(o["level"]), open)
		var p := cam.unproject_position(head) * k
		# Whole tags only: one cut by the edge of the picture reads as a glitch.
		var tag_size := 1.5   # half as big again as the HUD's text: it is only ever seen up close
		var hp := maxf(2.0, floorf(win.y / 320.0)) * tag_size   # the tag's pixel (hud.gd _scale, _draw_tags)
		var half := (PixelFont.width(str(o["name"]).to_upper()) * 0.5 + 2.0) * hp
		if shown and (p.x < half or p.y < 11.0 * hp or p.x > win.x - half or p.y > win.y):
			shown = false
		o["tagAlpha"] = a if shown else 0.0
		o["tagPos"] = [p.x, p.y]
		if shown:
			tags.append({"text": str(o["name"]).to_upper(), "pos": p, "alpha": a, "size": tag_size})
	hud.tags = tags

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
			if bool(snap.get("goingUp", false)):
				# Up to the prison: the floors count up to G.
				var k := 0.0 if ride_started < 0 else clampf((now - ride_started) / (Run.RIDE_UP_TIME * 1000.0), 0.0, 1.0)
				lift.show_indicator(_floor_label(maxi(0, depth - int(floorf(k * (depth + 1))))), true, 1)
			else:
				var half := ride_started >= 0 and now - ride_started > RIDE_TIME * 1000.0 / 2.0
				lift.show_indicator(_floor_label(depth + (1 if half else 0)), true, -1)
		_:
			lift.show_indicator("", false, 0)

# Events that change what is seen and heard (src/main.ts present).
func _present(events: Array, now: int) -> void:
	if events.is_empty():
		return
	announcer.on_events(events, 1)
	var my := link.my_id()
	quota_view.on_events(events, my, sfx, now)
	for e: Dictionary in events:
		var ty := str(e["type"])
		event_counts[ty] = int(event_counts.get(ty, 0)) + 1
		event_log.append({"type": ty, "t": e.get("t", 0.0)})
		if event_log.size() > 80:
			event_log.pop_front()
		var mine := str(e.get("playerId", "")) == my
		match ty:
			"doorsOpened", "doorsClosed":
				sfx.play("doors")
			"carLeft":
				if str(e["reason"]) == "ride" or str(e["reason"]) == "up":
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
				# The blackout: a tube pops; a blink: the relay's thump. The warning's flicker stops with the lights.
				sfx.stop("blink_warn")
				sfx.stop("blackout_warn")
				sfx.play("pop" if bool(e.get("blackout", false)) and sfx.recorded.has("pop") else "blink")
			"blinkEnd":
				sfx.play("blink", -8.0)
			"carArrived":
				prev_bell_left = BOARD_TIME
			"bell":
				sfx.play("bell")
			"rodeDown":
				sfx.ride(false)
				ride_started = -1
			"rodeUp":
				# Home: the ride is over; whoever was taken or left behind wakes on their bunk.
				sfx.ride(false)
				ride_started = -1
				caught_at = -1
				raise_latch = false
			"newDay":
				# The morning: in the car at floor 1 of the next day.
				ride_started = -1
				caught_at = -1
				left_at = -1
				prev_bell_left = BOARD_TIME
				pitch = 0.0
				raise_latch = false
				_day_note_until = now + 4000
				announcer.start_run(false)
			"banked":
				var summary: Dictionary = e["summary"]
				var shares: Dictionary = summary["shares"]
				lifetime += float(shares.get(my, 0.0))
				# With days there is no end screen: the car rides up to the prison (carLeft "up").
				if snap.get("day") == null:
					ending = {"kind": "banked", "at": now, "summary": summary}
				sfx.ride(true)
			"wiped":
				if snap.get("day") == null:
					ending = {"kind": "wiped", "at": now, "summary": e["summary"]}
			"leftBehind":
				if mine and snap.get("day") == null:
					ending = {"kind": "leftBehind", "at": now}
			"down":
				# The Playroom: health ran out. Down where you stand (the run's caught rule).
				if mine:
					caught_at = now
					raise_latch = false
					sfx.caught(true, null)
			"found":
				if mine:
					raise_latch = false
					sfx.caught(true, null)
			"downed":
				# Down first, then out: caught by the resident, the camera turns to it as it bends over you.
				if mine:
					raise_latch = false
					if str(e.get("by", "")) == "catch":
						_turn_until = now + TURN_MS
			"healed":
				if mine:
					_turn_until = -1
					hud.note = "> BACK ON YOUR FEET"
					_note_until = now + 2000
				elif str(e.get("by", "")) == my:
					hud.note = "> YOU GOT %s UP" % str(link.names().get(str(e["playerId"]), "THEM")).to_upper()
					_note_until = now + 2000
			"out":
				if mine:
					_turn_until = -1
					raise_latch = false
			"caught":
				var op: Variant = (snap.get("orderly", {}) as Dictionary).get("pose")
				sfx.caught(mine, Vector3(float(op["x"]), float(op["y"]) + 2.0, float(op["z"])) if op is Dictionary else null)
				if mine:
					caught_at = now
					raise_latch = false
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
	var again := {"text": "PRESS A KEY FOR A NEW RUN" if link.local else "BACK TO THE ROOM IN A MOMENT"}
	var my := link.my_id()
	if kind == "banked":
		var sm: Dictionary = ending["summary"]
		var shares: Dictionary = sm["shares"]
		hud.end_lines = [{"text": "BANKED", "strong": true}, {"text": ""}, {"text": "FLOORS %d" % int(sm["depth"])},
			{"text": "READINGS %d" % int(sm["readings"])}, {"text": "TOTAL " + _n4(float(sm["total"])), "strong": true},
			{"text": "YOUR SHARE " + _n4(float(shares.get(my, 0.0))), "strong": true}, {"text": ""},
			{"text": "LIFETIME " + _n4(lifetime)}, {"text": ""}, again]
	elif kind == "wiped":
		hud.end_lines = [{"text": "NOBODY CAME BACK UP", "strong": true}, {"text": ""}, {"text": "FLOORS %d" % int(snap["depth"])},
			{"text": "NOTHING BANKED"}, {"text": ""}, {"text": "LIFETIME " + _n4(lifetime)}, {"text": ""}, again]
	else:
		hud.end_lines = [{"text": "THE CAR WENT DOWN WITHOUT YOU", "strong": true}, {"text": ""}, again]
	end_shown_at = now
	if not automated:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

## Whether the prison's lights are out on this screen: the host's lights-out time has come by the host
## clock as estimated here (never by when the news arrived).
func _is_lights_out(s: Dictionary) -> bool:
	var dv: Variant = s.get("day")
	if not dv is Dictionary or int(s["depth"]) != 0 or bool(s.get("goingUp", false)):
		return false
	var lo: Variant = (dv as Dictionary)["lightsOutAt"]
	return lo != null and float(s["hostNow"]) >= float(lo)

## The day loop on screen (a run with days; prison.md sections 3 and 6): the ride up's headline; at home
## the bed count, the lights-out countdown and lights out, the day board by the lift and the report board
## in the bank room (read crisp on the screen while standing in the bank room); the morning's note. Every
## number is the host's (the day block), and every time is host time against the host clock.
func _show_day(s: Dictionary, now: int) -> void:
	hud.count_text = ""
	hud.big_note = ""
	hud.fade = 0.0
	hud.board_lines = []
	var dv: Variant = s.get("day")
	if not dv is Dictionary:
		return
	var day: Dictionary = dv
	var result: Variant = day["result"]
	var going_up := bool(s.get("goingUp", false))
	var pv: Object = level.get_meta(&"prison") if level.has_meta(&"prison") else null
	if pv != null:
		pv.call("set_lights_out", _lights_out)
	if going_up and result is Dictionary:
		hud.center_note = _headline(result as Dictionary, s)
	if now < _day_note_until and int(s["depth"]) >= 1:
		hud.big_note = "DAY %d  OWED %d" % [int(day["day"]), int(day["quota"])]
	if int(s["depth"]) != 0 or going_up:
		return
	var hn := float(s["hostNow"])
	var count := "IN BED %d OF %d" % [(day["inBed"] as Array).size(), int(day["crew"])]
	var lo: Variant = day["lightsOutAt"]
	var left := ""
	if _lights_out:
		hud.big_note = "LIGHTS OUT"
		# A moment of the dark cell block, then black until the morning.
		hud.fade = clampf((hn - float(lo) - 1.5) / (Day.LIGHTS_OUT_SECONDS - 2.0), 0.0, 1.0)
		left = "LIGHTS OUT"
	elif lo != null and day["countFrom"] != null:
		left = "LIGHTS OUT %d" % ceili(maxf(0.0, float(lo) - hn))
	hud.count_text = count + ("  " + left if left != "" and not _lights_out else "")
	_board = PrisonView.report_text(result, link.names())
	if pv != null:
		pv.call("show_report", _board)
		var lines := PrisonView.day_text(day, count)
		if left != "":
			lines.append(left)
		pv.call("show_day_board", lines)
	var me: Dictionary = s["me"]
	var cell := Vector2i(floori(float(me["x"]) / Prison.CELL_SIZE), floori(float(me["z"]) / Prison.CELL_SIZE))
	# Anywhere in the bank room but right in front of the board itself (there the board is read on the wall).
	if int(me["level"]) == 0 and Prison.BANK_ROOM.has_point(cell) and cell != Prison.REPORT_BOARD and not _lights_out:
		hud.board_lines = _board

## The ride up's headline from the settled day (the host's facts).
func _headline(r: Dictionary, s: Dictionary) -> String:
	var sm: Variant = s.get("summary")
	if bool(r.get("wiped", false)) or (sm is Dictionary and bool((sm as Dictionary).get("wiped", false))):
		return "GOING UP.  NOBODY CAME BACK.  NOTHING BANKED"
	# The day lock (FD3): BANK only opens once the day is earned, so the day is made whatever came back.
	if DayView.lock_of(s.get("day")) != null:
		return "GOING UP.  DAY MADE.  BANKED %d" % int(r["banked"])
	var head := "GOING UP.  BANKED %d OF %d" % [int(r["banked"]), int(r["quota"])]
	return head + ("  MADE" if str(r["kind"]) == "made" else "  SHORT %d" % int(r["short_by"]))

## Tests: what a prison board shows now ("day" or "report"), or [] off the prison.
func _prison_lines(which: String) -> Array:
	if level == null or not level.has_meta(&"prison"):
		return []
	var pv: Object = level.get_meta(&"prison")
	return pv.get("day_board_lines" if which == "day" else "report_lines")

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

func _reset_stats() -> void:
	_reset_eye_stats()
	_ft_sum = 0.0
	_ft_n = 0
	_ft_max = 0.0
	rules_ms_sum = 0.0
	rules_ms_max = 0.0
	frames = 6
	game_frames = 0
	_stats_t0 = _now()
	if link != null:
		_stats_bytes = [link.rc.bytes_in, link.rc.bytes_out]
		if link.local:
			(link.rc as LocalRoom).host_us = 0

# --- the test hook ------------------------------------------------------------------------------

func _on_js(args: Array) -> void:
	var res := _command(str(args[0]))
	var window: JavaScriptObject = JavaScriptBridge.get_interface("window")
	window.set("gdResult", res)

## Commands (space separated): state | stats | resetstats | move f r sprint creep | stopmove |
## look yawDeg pitchDeg | face x z [y] | raise 0|1|- | hold 0|1|- | call | pick | teleport level x y |
## walkto level x y [pace] [walk|creep|sprint] | stopwalk | timescale k | newrun | tape 0|1 | debug | floortapes | plan |
## use 0|1|- (F held: the bunk) | down 0|1 (alone: put the player down or up) | eyestats (the camera's eye against the client's, every frame)
## The start screen and the room: alone (PLAY ALONE, then Enter on the face) | ui <alone|join|go|back|start|leave> |
## type <address|name> <text> | start | leave | emote <name> | wheel open | wheel aim dx dy | wheel release | screen
## The face step: draw done | draw cancel | draw press <editor control id> | draw line x0 y0 x1 y1 (cells, with
## the mouse events a player's drag sends) | faces (what is on every mask and on the monitor)
## The face kiosk, mid-run: kiosk open | kiosk press <editor control id> | kiosk line x0 y0 x1 y1 |
## kiosk done | kiosk cancel
## The Playroom: hide [fast] (F for a hide) | peek 0|1|- (W held in a hide) | hides (the floor's hides) |
## peaklog on|off|get (every frame's Voice and Master peaks)
func _command(c: String) -> String:
	var p := c.split(" ", false)
	if p.is_empty():
		return "empty"
	var in_game := link != null and not snap.is_empty() and not snap.has("waiting") and level != null
	match p[0]:
		"state":
			return JSON.stringify(_test_state())
		"screen":
			return JSON.stringify(_screen_state())
		"stats":
			var secs := maxf(0.001, _now() - _stats_t0)
			var host_ms := 0.0
			if link != null and link.local:
				host_ms = (link.rc as LocalRoom).host_us / 1000.0 / maxi(game_frames, 1)
			return JSON.stringify({"frames": frames, "avg_ms": 1000.0 * _ft_sum / maxi(_ft_n, 1), "max_ms": 1000.0 * _ft_max,
				"fps": Engine.get_frames_per_second(), "load_ms": load_ms, "rules_ms_avg": rules_ms_sum / maxi(game_frames, 1),
				"bridge_ms_avg": rules_ms_sum / maxi(game_frames, 1), "rules_ms_max": rules_ms_max, "host_ms_avg": host_ms, "game_frames": game_frames,
				"bytes_in_per_s": (link.rc.bytes_in - int(_stats_bytes[0])) / secs if link != null else 0.0,
				"bytes_out_per_s": (link.rc.bytes_out - int(_stats_bytes[1])) / secs if link != null else 0.0, "seconds": secs,
				"draw_calls": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
				"objects": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME),
				"prims": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
				"quality": quality, "renderer": RenderingServer.get_current_rendering_method(),
				"rules": ("local room" if link != null and link.local else "network") if link != null else "none", "peaks": _bus_peaks()})
		"peaks":
			return JSON.stringify(_bus_peaks())
		"resetstats":
			_reset_stats()
		"alone":
			if mode == "game":
				return "already playing"
			start.press("alone")
			if start.screen == "face" and start.editor != null:
				start.editor.key(_enter_key())   # a returning player's Enter keeps the face
		"draw":
			if start.screen != "face" or start.editor == null:
				return "no face step"
			if p.size() < 2:
				return "draw what"
			var ed := start.editor
			match p[1]:
				"done":
					ed.key(_enter_key())
				"cancel":
					ed.press("cancel")
				"press":
					if p.size() < 3:
						return "press what"
					ed.press(p[2])
				"line":
					if p.size() < 6:
						return "line x0 y0 x1 y1"
					_drag_on_editor(ed, Vector2(float(p[2]), float(p[3])), Vector2(float(p[4]), float(p[5])))
				_:
					return "unknown draw command"
		"faces":
			return JSON.stringify(_faces_state())
		"kiosk":
			# The face kiosk's editor during a run, as F at the prison's kiosk opens it.
			if p.size() < 2:
				return "kiosk what"
			if p[1] == "open":
				return "ok" if _open_kiosk() else "not in a run"
			if not kiosk.is_open():
				return "the kiosk is not open"
			var ked := kiosk.editor
			match p[1]:
				"done":
					ked.key(_enter_key())
				"cancel":
					ked.press("cancel")
				"press":
					if p.size() < 3:
						return "press what"
					ked.press(p[2])
				"line":
					if p.size() < 6:
						return "line x0 y0 x1 y1"
					_drag_on_editor(ked, Vector2(float(p[2]), float(p[3])), Vector2(float(p[4]), float(p[5])))
				_:
					return "unknown kiosk command"
		"ui":
			if p.size() < 2:
				return "ui what"
			start.press(p[1])
		"type":
			if p.size() < 2:
				return "type what"
			var text := c.substr(c.find(p[1]) + p[1].length() + 1) if p.size() > 2 else ""
			if p[1] == "address":
				start.address = text
			elif p[1] == "name":
				start.player_name = text
			else:
				return "only address or name"
		"start":
			_lobby_start()
		"ready":
			# Ready-up: press I'M READY (ready 0: undo it). Alone, READY starts the run.
			if start.screen != "lobby":
				return "not on Ready-up (%s)" % start.screen
			var want := p.size() < 2 or p[1] != "0"
			if start.my_ready != want:
				start.press("ready")
		"tapeskip":
			# The orientation tape: skip it (as a held Space would).
			if start.tape == null or not start.tape.playing:
				return "no tape playing"
			start.tape.skip()
		"leave":
			_back_to_title()
		"emote":
			if p.size() < 2 or not p[1] in Protocol.EMOTES:
				return "unknown emote"
			_send_emote(p[1])
		"wheel":
			if p.size() < 2:
				return "wheel what"
			match p[1]:
				"open":
					_wheel_open()
				"aim":
					wheel_vec = Vector2(float(p[2]), float(p[3]))
				"release":
					return JSON.stringify({"sent": _wheel_release()})
				"cancel":
					wheel_open = false
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
		"use":
			t_use = null if p[1] == "-" else p[1] == "1"
		"hide":
			# F for a hide (into the one in reach, or out); `hide fast`: with sprint held.
			pending_hide = true
			pending_hide_fast = p.size() > 1 and p[1] == "fast"
		"peek":
			t_peek = null if p[1] == "-" else p[1] == "1"
		"hides":
			if link == null:
				return "[]"
			var hl: Array = []
			for h in link.hides:
				hl.append({"id": h.id, "kind": String(h.kind), "zone": h.zone, "level": h.level, "inside": [h.inside.x / 100.0, h.inside.y / 100.0],
					"front": [h.front.x / 100.0, h.front.y / 100.0], "gap": String(h.gap), "capacity": h.capacity, "eye": h.eye / 100.0})
			return JSON.stringify(hl)
		"peaklog":
			# peaklog on | off | get: every frame's bus peaks (dB) with this screen's clock and the host's.
			if p.size() > 1 and p[1] == "on":
				_peaklog = []
				_peaklog_on = true
			elif p.size() > 1 and p[1] == "off":
				_peaklog_on = false
			else:
				return JSON.stringify(_peaklog)
		"call":
			pending_call = true
		"pick":
			pending_pick = true
		"teleport":
			if not in_game:
				return JSON.stringify({"ok": false, "error": "no run"})
			return JSON.stringify(link.teleport(int(p[1]), int(p[2]), int(p[3])))
		"walkto":
			if not in_game:
				return JSON.stringify({"ok": false, "error": "no run"})
			return JSON.stringify(link.walk_to(int(p[1]), int(p[2]), int(p[3]), float(p[4]) if p.size() > 4 else 3.0, StringName(p[5]) if p.size() > 5 else &"walk"))
		"stopwalk":
			if link == null:
				return JSON.stringify({"ok": false})
			return JSON.stringify(link.stop_walk())
		"timescale":
			if link == null or not link.local:
				return "timescale is for playing alone"
			(link.rc as LocalRoom).time_scale = float(p[1])
		"newrun":
			if link == null or not link.local:
				return "newrun is for playing alone (with friends: start, from the room)"
			_new_run()
		"tape":
			tape_mat.set_shader_parameter("strength", float(p[1]))
		"debug":
			if link == null:
				return JSON.stringify({"error": "no run"})
			return JSON.stringify(link.debug_info())
		"shot":
			# The whole window as drawn (tape, display, subtitles), to a PNG path.
			var img := get_viewport().get_texture().get_image()
			return "ok" if img.save_png(c.substr(5).strip_edges()) == OK else "save failed"
		"click":
			# A stand-in for the first real click or key (the browser's audio and the welcome wait for one).
			_gesture = true
			_welcome_pending = false
		"quit":
			get_tree().quit(0)
		"sfx":
			# sfx <name> | sfx solo <group|-> (only that group sounds; the announcer is hushed) |
			# sfx duck <0|1|-> (force the duck, or follow the voice) | sfx state
			if p.size() < 2:
				return "sfx what"
			match p[1]:
				"solo":
					sfx.solo = "" if p.size() < 3 or p[2] == "-" else p[2]
					announcer.player.volume_db = -80.0 if sfx.solo != "" else -5.0
				"duck":
					sfx.duck_forced = -1 if p.size() < 3 or p[2] == "-" else int(p[2])
				"state":
					return JSON.stringify(sfx.describe())
				_:
					sfx.play(p[1])
		"say":
			announcer.request(p[1], 9000)
		"clock":
			# The engine's ms, the clock the announcer's history and hint log are stamped with.
			return JSON.stringify({"ms": Time.get_ticks_msec()})
		"hints":
			# hints on | off: the Esc menu's H.
			if p.size() >= 2:
				_set_hints(p[1] == "on")
			return JSON.stringify({"on": announcer.hints.enabled})
		"props":
			return JSON.stringify(level.prop_spots if level != null else [])
		"down":
			if not in_game:
				return JSON.stringify({"ok": false, "error": "no run"})
			return JSON.stringify(link.set_down(p.size() > 1 and p[1] == "1"))
		"eyestats":
			return JSON.stringify(eye_stats)
		"nudge":
			if not in_game:
				return JSON.stringify({"ok": false, "error": "no run"})
			return JSON.stringify(link.nudge(float(p[1]), float(p[2])))
		"floortapes":
			return JSON.stringify(snap.get("floorTapes", []))
		"plan":
			if link == null or link.plan_dict.is_empty():
				return JSON.stringify({"error": "no run"})
			var pl := link.plan_dict
			return JSON.stringify({"width": pl["width"], "height": pl["height"], "landing": pl["landing"], "entityStart": pl["entityStart"],
				"sightlines": pl["sightlines"], "car": pl["car"], "elevatorWall": pl["elevatorWall"], "landingFacing": pl["landingFacing"],
				"cells": pl["cells"], "liftDist": pl["liftDist"], "rooms": pl["rooms"], "doors": pl["doors"], "depth": pl["depth"], "edges": pl["edges"]})
		_:
			return "unknown command"
	return "ok"

static func _enter_key() -> InputEventKey:
	var k := InputEventKey.new()
	k.pressed = true
	k.keycode = KEY_ENTER
	k.physical_keycode = KEY_ENTER
	return k

## A drag across the face editor's canvas from cell `a` to cell `b`, as the mouse sends it.
func _drag_on_editor(ed: FaceEditor, a: Vector2, b: Vector2) -> void:
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

## Faces as a test sees them: a hash of this player's own face (the picture decoded from what it
## sends), of the picture on each other crewmate's mask, and of each face on the lift's monitor. The
## face itself is never in it.
func _faces_state() -> Dictionary:
	var mine := FaceCodec.decode(start.face_code)
	var masks := {}
	for id: String in others.figures:
		masks[id] = (others.figures[id]["view"] as CrewView).face_hash()
	return {"own": CrewView.texture_hash(mine) if mine != null else "", "hasFace": start.face_code != "",
		"default": CrewView.texture_hash(CrewView.default_face()), "masks": masks,
		"monitor": lift.monitor_hashes() if lift != null else [],
		"received": link.client().faces.size() if link != null and link.client() != null else 0,
		"kioskOpen": kiosk.is_open(), "changeWaiting": link.client().face_change_waiting() if link != null and link.client() != null else false}

## The start screen as a test sees it (the passphrase is never in it).
## Tests: the lift as drawn on this screen (lift.gd drawn_car, measured from its meshes), in metres: the
## car's width and depth inside its walls, the doorway, and the widths of the BANK and DOWN paint.
func _lift_drawn() -> Dictionary:
	if lift == null:
		return {}
	var d := lift.drawn_car()
	var box: AABB = d["box"]
	return {"width": box.size.x - 0.08, "depth": -box.position.z - 0.04, "doorway": d["doorway"],
		"bank": (d["bank"] as AABB).size.x, "down": (d["down"] as AABB).size.x}

func _screen_state() -> Dictionary:
	return {"screen": mode, "error": start.error, "address": start.address, "name": start.player_name, "passTyped": not start.passphrase.is_empty(),
		"people": start.people, "me": start.my_id, "runOn": start.run_on, "focus": start.focused_id(), "menu": menu_overlay,
		"status": link.rc.status if link != null else "none", "closeCode": link.rc.close_code if link != null else 0,
		"ready": start.my_ready, "host": start.host_id, "line": start.status_line() if mode == "lobby" else "", "countLeft": start.count_left,
		"withoutOk": start.without_ok, "tapePlaying": start.tape != null and start.tape.playing, "tapeSeen": start.tape_seen,
		"card": StartScreen.card_lines(), "entry": _entry}

func _test_state() -> Dictionary:
	var s := snap
	if mode != "game" or s.is_empty() or s.has("waiting") or level == null:
		return {"screen": _screen_state(), "client": {"menu": hud.menu_on}}
	var o: Dictionary = s["orderly"]
	var oth: Array = []
	for x: Dictionary in s["others"]:
		var d := x.duplicate()
		d.merge(others.describe(str(x["id"])))
		oth.append(d)
	return {
		"screen": _screen_state(),
		"phase": s.get("phase"), "depth": s.get("depth"), "t": s.get("t"), "dark": s.get("dark"), "warn": s.get("warn"),
		"blackout": s.get("blackout"), "blink": s.get("blink"), "call": s.get("call"), "doorsOpen": s.get("doorsOpen"),
		"bellLeft": s.get("bellLeft"), "votes": s.get("votes"), "summary": s.get("summary"), "playing": s.get("playing"),
		"me": s.get("me"), "inst": s.get("inst"), "tapes": s.get("tapes"), "auto": s.get("auto"),
		"orderly": {"mode": o["mode"], "held": o["held"], "seeing": o["seeing"], "visible": o["visible"],
			"moving": o["moving"], "frozen": o["frozen"], "distance": o["distance"], "x": o["x"], "z": o["z"],
			"level": o["level"], "drawn": orderly.visible, "pose": o.get("pose"), "squeak": o["squeak"], "taken": o["taken"],
			"look": orderly.call(&"look") if orderly.has_method(&"look") else {}},
		"others": oth,
		"emotesSeen": emotes_seen,
		"net": {"local": link.local, "id": link.my_id(), "bytesIn": link.rc.bytes_in, "bytesOut": link.rc.bytes_out, "now": _now(),
			"watchedPairs": link.watched_pairs, "watchedMoves": link.watched_moves},
		"client": {"yaw": yaw, "pitch": pitch, "emergency": emergency, "light": light, "doors": lift.doors if lift else 0.0,
			"indicator": lift.indicator_text if lift else "", "slip": inst_view.slip_text, "slipShown": inst_view.slip_shown(),
			"raise": inst_view.raise, "needle": inst_view.needle, "needleAngle": inst_view.angle, "subtitle": announcer.subtitle,
			"spoken": announcer.history.map(func(h: Dictionary) -> String: return str(h["id"])), "history": announcer.history, "hintsOn": announcer.hints.enabled,
			"hintLog": announcer.hint_log.slice(maxi(0, announcer.hint_log.size() - 60)), "caught": caught_at >= 0, "noise": _noise_on(),
			"wentDown": hud.went_down, "end": hud.end_lines.map(func(l: Dictionary) -> String: return str(l["text"])), "tapeText": hud.tape_text,
			"prompt": hud.prompt, "menu": hud.menu_on, "built": built_depth, "hudSize": [hud.size.x, hud.size.y], "lift": _lift_drawn(),
			"wheel": wheel_open, "wheelSel": hud.wheel_sel, "note": hud.note, "tags": hud.tags.map(func(t: Dictionary) -> String: return str(t["text"])), "tagRange": TAG_RANGE,
			"camY": cam.position.y, "board": _board, "count": hud.count_text, "bigNote": hud.big_note,
			"fade": hud.fade, "lightsOut": _lights_out, "goingUp": s.get("goingUp", false), "centerNote": hud.center_note,
			"hudBoard": hud.board_lines, "dayBoard": _prison_lines("day"), "reportBoard": _prison_lines("report"), "residentDrawn": orderly.visible},
		"day": s.get("day"), "hostNow": s.get("hostNow"), "bed": s.get("bed"), "seed": s.get("seed"),
		"seek": s.get("seek"), "mySeek": s.get("mySeek"), "countEvent": s.get("countEvent"), "nearHide": s.get("nearHide"), "hideCam": s.get("hideCam"),
		"place": link.plan_dict.get("place", ""),
		"hide": hide_view.describe(), "hud": {"health": hud.health, "rates": hud.health_rates, "countText": hud.count_text, "countBy": hud.count_by,
			"seekNote": hud.seek_note, "subtitle": hud.subtitle, "bigNote": hud.big_note, "centerNote": hud.center_note,
			"anger": hud.anger, "angerRates": hud.anger_rates},
		"quota": {"host": link.client().quota() if link.client() != null else null, "panel": lift.quota_text, "tone": lift.quota_tone,
			"hud": hud.quota_line, "carWaiting": car_waiting, "view": quota_view.describe(), "at": [lift.quota_point().x, lift.quota_point().y, lift.quota_point().z]},
		"dayLock": {"host": link.client().day_lock() if link.client() != null else null, "tick": int((link.client().latest as Dictionary)["tick"]) if link.client() != null and link.client().latest is Dictionary else -1,
			"view": day_view.describe(), "viewTick": _day_view_tick, "hudLine": hud.day_line, "hudMet": hud.day_met, "monitor": lift.day_rows, "bankLocked": lift.bank_locked,
			"monitorAt": [lift.day_point().x, lift.day_point().y, lift.day_point().z], "subtitle": announcer.shown(),
			"said": announcer.history.filter(func(h: Dictionary) -> bool: return str(h.moment) in ["bank_refused", "day_met", "ride", "hint_day", "hint_bank_locked", "hint_floor_not_day", "hint_stakes"])},
		"downs": {"host": s.get("downs"), "view": down_view.describe(), "hud": {"head": hud.down_head, "left": hud.down_left, "line": hud.down_line,
			"line2": hud.down_line2, "heal": hud.down_heal, "out": hud.out_on, "outLines": hud.out_lines, "prompt": hud.prompt, "fill": hud.prompt_fill},
			"turning": _turn_until > Time.get_ticks_msec(), "bend": orderly.get("bend") if orderly != null else null},
		"captions": announcer.said_count.map(func(c: Dictionary) -> String: return str(c["text"])),
		"bells": sfx.bells.duplicate(), "seekHist": _seek_hist.duplicate(), "camPos": [cam.position.x, cam.position.y, cam.position.z],
		"events": event_counts,
	}
