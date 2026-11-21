# WF1: a player who arrives on the Hanging Ward walks out of the lift. The owner, on build 1013e52:
# "I can't leave the elevator on hanging ward". The Ward is entered the way the game enters it (a solo run's
# floor picker at floor 6, the late floors on: net/local_room.gd start_playtest, net/host.gd _start_late_floor),
# the main game hands the room to client/ward/review.tscn (client/main.gd _enter_floor), and the real
# controller (review.gd _physics_process reading the W key) is driven forward out of the car.
#
# Runs everywhere: the Ward's figures and sounds ship in the game (IP1), so no extra file is needed.
extends RefCounted

const T = preload("res://tests/t.gd")
const Main = preload("res://client/main.gd")
const PlayLink = preload("res://client/play_link.gd")
const LocalRoom = preload("res://net/local_room.gd")
const Ward = preload("res://sim/ward/state.gd")
## WG1: a block's layout options (sim/ward/layout.gd from_wire), so the test builds the host's Ward.
const WardLayout = preload("res://sim/ward/layout.gd")
const Session = preload("res://net/session.gd")
const Places = preload("res://sim/places.gd")
const HostRules = preload("res://net/host_rules.gd")
const Stamina = preload("res://sim/stamina.gd")
const Instrument = preload("res://sim/instrument.gd")
const Brightness = preload("res://client/brightness.gd")

static func _key(code: Key, down: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = down
	Input.parse_input_event(event)
	Input.flush_buffered_events()

## No pack needed: the rules alone. Wherever the lift may leave a walker (clear_of_lift), its shut gate never
## holds them: they can still step on, away from the car. And while anyone is in the doorway the lift waits.
func test_the_shut_gate_never_holds_a_walker_the_lift_left(t: T) -> void:
	for seed_value: int in [8143, 4003398645, 23]:
		var ward := Ward.new(seed_value)
		var door := ward.lift_door()
		ward.phase = &"away"
		var trapped := 0
		var doorway := 0
		for step in range(-40, 120):
			for x: float in [-0.3, 0.0, 0.3]:
				var feet := door + Vector3(x, 0.0, step * 0.01)
				if ward.in_lift(feet):
					continue
				if not ward.clear_of_lift(feet):
					doorway += 1
					continue
				# A step on, away from the car: blocked now but free with the gate open means the gate holds them.
				var on := feet + Vector3(0, 0, 0.05)
				ward.phase = &"unloading"
				var free_open := ward.walk_clear(feet, on)
				ward.phase = &"away"
				if free_open and not ward.walk_clear(feet, on):
					trapped += 1
		t.eq(trapped, 0, "seed %d: no spot the lift may leave from has the shut gate across it" % seed_value)
		t.check(doorway > 0, "seed %d: the doorway between the car and clear ground is counted as still in the lift" % seed_value)

## The Ward entered the way the game enters it: a solo run's floor picker at floor 6, the main game's hand-over.
## Returns {room, main, scene, view, before, deck, door} or {} (the failure already checked).
func _enter(t: T) -> Dictionary:
	var original := Session.deck
	Session.deck = Places.FULL
	var tree := Engine.get_main_loop() as SceneTree
	var before := tree.current_scene
	var room := LocalRoom.new()
	room.open_local("wf1-ward-exit", "Tester", true)
	# This file checks FL1's scene swap: the Ward as a normal level (WN1, net/host_rules.gd ward_place) off.
	room.ward_place = false
	room.reactor_place = false   # and the Reactor as a place (RN1) off: this file checks the old hand-over
	room.late_archive_root = ""
	t.check(room.start_playtest(HostRules.WARD_DEPTH), "the floor picker starts floor 6")
	# On the real clock, the one the Ward's scene polls with: a made-up clock here would jump the host's time by the
	# process's age at the first real poll, and the client's estimate of host time takes a while to catch a jump
	# (under a long suite the lift's clock then read minutes off; WN1: steadier, the same claims).
	for i in 10:
		OS.delay_usec(50000)
		room.poll(Time.get_ticks_usec() / 1000000.0)
	t.eq(Main.floor_handover(room.client.latest), "ward", "floor 6 of a solo run is the Ward")
	var main := Main.new()
	main.hud = Hud.new()
	main.link = PlayLink.new(room, true)
	main._enter_floor("ward", room)
	var scene := tree.current_scene
	var out := {"room": room, "main": main, "scene": scene, "before": before, "deck": original}
	if not t.check(scene != before and scene != null and scene.scene_file_path == "res://client/ward/review.tscn", "the Ward's scene is on screen"):
		out.scene = null
		_leave(out)
		return {}
	for i in 4:
		scene._process(0.016)
		OS.delay_usec(16000)
	var view: Node3D = scene.get("view")
	if not t.check(view != null, "the Ward is drawn"):
		_leave(out)
		return {}
	out["view"] = view
	out["door"] = Ward.new(int(room.client.latest.ward.seed), WardLayout.from_wire(room.client.latest.ward.get("layout"))).lift_door()
	return out

static func _leave(w: Dictionary) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	tree.current_scene = w.before
	var scene: Variant = w.get("scene")
	if scene != null and is_instance_valid(scene):
		scene.set("room", null)
		scene.get_parent().remove_child(scene)
		scene.free()
	var main: Variant = w.main
	if is_instance_valid(main):
		if is_instance_valid(main.hud):
			main.hud.free()
		main.free()
	w.room.leave()
	Session.deck = w.deck

## One frame of the Ward's scene at 60 Hz, as the game runs it.
static func _frame(scene: Node) -> void:
	scene._process(1.0 / 60.0)
	scene._physics_process(1.0 / 60.0)
	OS.delay_usec(16667)

## Walks out of the car with `key` held: the metres past the doors after at most five seconds.
static func _walk_out(w: Dictionary, key: Key) -> float:
	_key(key, true)
	var out := 0.0
	for frames in 300:
		_frame(w.scene)
		out = w.view.player.position.z - w.door.z
		if out > 3.0:
			break
	_key(key, false)
	return out

func test_a_player_walks_out_of_the_lift_on_the_ward(t: T) -> void:
	var w := _enter(t)
	if w.is_empty():
		return
	var room: LocalRoom = w.room
	t.note("spawn %s, lift door %s, phase %s" % [w.view.player.position, w.door, room.client.latest.ward.phase])
	# Five seconds of walking is many metres; three metres past the doors is plenty.
	var out := _walk_out(w, KEY_W)
	var accepted: Variant = null
	for row: Dictionary in room.client.latest.players:
		if row.id == LocalRoom.ME:
			accepted = row.body
	t.note("feet %s (%.2f m past the doors), phase %s" % [w.view.player.position, out, room.client.latest.ward.phase])
	t.check(out > 3.0, "the player gets three metres past the lift doors within five seconds (%.2f m)" % out)
	t.check(accepted != null and float(accepted.z) - w.door.z > 2.0, "and the host accepts the walk out")
	t.eq(str(room.client.latest.ward.phase), "away", "and the lift has left the crew (its clock is running)")
	_leave(w)

# --- WF2: the Ward is the same game as the other floors: keys, pace, instrument, mouse, brightness. ---

## Holds `keys` for `frames` frames: the metres the player's feet moved over the ground.
static func _hold(w: Dictionary, keys: Array, frames: int) -> float:
	for k: Key in keys:
		_key(k, true)
	var from: Vector3 = w.view.player.position
	for i in frames:
		_frame(w.scene)
	var to: Vector3 = w.view.player.position
	for k: Key in keys:
		_key(k, false)
	return Vector2(to.x - from.x, to.z - from.z).length()

static func _press(code: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = true
	return event

func test_the_ward_walks_with_the_main_games_keys_and_pace(t: T) -> void:
	var w := _enter(t)
	if w.is_empty():
		return
	var out := _walk_out(w, KEY_UP)
	t.check(out > 3.0, "the up arrow walks out of the lift, as W does (%.2f m)" % out)
	# A fifth of a second in each gait, back and forth in the parlour (sim/stamina.gd speeds; frames at 60 Hz).
	const FRAMES := 12
	var seconds := FRAMES / 60.0
	var clamped: int = w.room.host.stats.clamped_inputs
	var walk := _hold(w, [KEY_S], FRAMES) / seconds
	var sprint := _hold(w, [KEY_W, KEY_SHIFT], FRAMES) / seconds
	# Sprinting drains the same tank the host keeps (sim/stamina.gd); the screen sends it with the frame.
	var after_sprint: float = (w.scene.get("tank") as Stamina.Stamina).level
	var creep := _hold(w, [KEY_DOWN, KEY_CTRL], FRAMES) / seconds
	t.note("walk %.2f, sprint %.2f, creep %.2f m/s" % [walk, sprint, creep])
	t.check(absf(walk - Stamina.WALK_SPEED) < 0.15, "walking is the main game's %.1f m/s (%.2f)" % [Stamina.WALK_SPEED, walk])
	t.check(absf(sprint - Stamina.SPRINT_SPEED) < 0.25, "sprinting is the main game's %.1f m/s (%.2f)" % [Stamina.SPRINT_SPEED, sprint])
	t.check(absf(creep - Stamina.CREEP_SPEED) < 0.1, "creeping is the main game's %.1f m/s (%.2f)" % [Stamina.CREEP_SPEED, creep])
	for i in 10:
		_frame(w.scene)
	t.eq(int(w.room.host.stats.clamped_inputs), clamped, "the host's move check takes every step at these speeds")
	t.check(after_sprint < 1.0, "the sprint spent some of the tank (%.3f)" % after_sprint)
	# The instrument on E, a toggle: raised, the walk is held to the instrument's cap.
	w.scene._unhandled_input(_press(KEY_E))
	t.check(w.scene._raised(), "E raises the instrument")
	var raised := _hold(w, [KEY_S, KEY_SHIFT], FRAMES) / seconds
	t.check(absf(raised - Instrument.RAISED_SPEED_CAP) < 0.15, "raised, the player moves at the instrument's %.1f m/s even sprinting (%.2f)" % [Instrument.RAISED_SPEED_CAP, raised])
	w.scene._unhandled_input(_press(KEY_E))
	t.check(not w.scene._raised(), "E again lowers it")
	# The main game's mouse and lens (client/main.gd SENS, MAX_PITCH, VFOV).
	var view: Node3D = w.view
	t.check(is_equal_approx(view.camera.fov, Main.VFOV), "the Ward's lens is the main game's %.0f degrees (%.1f)" % [Main.VFOV, view.camera.fov])
	var yaw: float = view.player.rotation.y
	view.turn(Vector2(100, 0))
	t.check(is_equal_approx(angle_difference(yaw, view.player.rotation.y), -100.0 * Main.SENS), "a mouse movement turns as far as in the main game")
	view.turn(Vector2(0, -100000))
	t.check(is_equal_approx(view.camera.rotation.x, Main.MAX_PITCH), "and looks up only as far (%.3f)" % view.camera.rotation.x)
	_leave(w)

## No pack needed: the player's saved brightness reaches the Ward's picture, as tape.gdshader's last step.
func test_the_ward_shows_the_players_brightness(t: T) -> void:
	var path := OS.get_user_data_dir().path_join("wf2-ward-brightness.cfg")
	var saved := Brightness.new()
	saved.save_path = path
	saved.set_level(3)
	saved.save()
	var main := Main.new()
	var room := LocalRoom.new()
	var scene := main._floor_scene("ward", room)
	scene.get("brightness").save_path = path
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(scene)
	var want := Brightness.params(3)
	# WF3: on the tape itself, the same material every floor sets it on (client/main.gd brightness_on).
	var mat: ShaderMaterial = scene.get("tape_mat")
	var lift: Variant = mat.get_shader_parameter("bright_lift")
	var gamma: Variant = mat.get_shader_parameter("bright_gamma")
	t.check(float(want["lift"]) < 0.0, "level 3 lowers the black level (a real change to see)")
	t.check(mat.shader == load("res://client/tape.gdshader"), "the brightness is the tape look's last step")
	t.check(lift != null and gamma != null and is_equal_approx(float(lift), float(want["lift"])) and is_equal_approx(float(gamma), float(want["gamma"])),
		"the Ward's picture takes the saved level's lift and gamma (%s, %s)" % [lift, gamma])
	scene.set("room", null)
	tree.root.remove_child(scene)
	scene.free()
	main.free()
	DirAccess.remove_absolute(path)
