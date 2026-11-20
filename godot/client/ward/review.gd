# The main client's local Ward review route. Uses the normal room and snapshot client.
extends Node3D

const LocalRoom = preload("res://net/local_room.gd")
const RoomClient = preload("res://net/room_client.gd")
const Client = preload("res://net/client.gd")
const Instrument = preload("res://sim/instrument.gd")
const Move = preload("res://sim/move.gd")
const House = preload("res://sim/ward/house.gd")
const Ward = preload("res://sim/ward/state.gd")
const View = preload("res://client/ward/view.gd")
const Main = preload("res://client/main.gd")
const Stamina = preload("res://sim/stamina.gd")
const Brightness = preload("res://client/brightness.gd")
const EyeHeight = preload("res://client/eye_height.gd")

var room: Variant = null
var view: View
var event_index := 0
var status := Label.new()
var automate := false
var test_role := ""
var test_leg := 0
var stair_route: Array[Vector3] = []
var test_edge := false
var test_at_edge := false
var last_caught := false
var automated_start := -1.0
var last_report := ""
var last_room_status := ""
## FL1: true when the main game handed this scene the room it already plays in (a normal run arriving on
## the Ward, alone or joined). Then no room is opened here and the Ward's day ends back in the main game.
var handed := false
## Esc: a small card (RESUME, LEAVE TO TITLE). Open, it frees the mouse and the player does not move.
var card := PanelContainer.new()
var card_open := false
## Going back to the title: the line the title shows (the start screen's error line), once the title is up.
var title_reason := ""
## WF2: the same body as on every other floor. The instrument on E (a toggle, right mouse held as well), the main
## game's keys (client/main.gd _add_actions: arrows as well as WASD, Shift sprint, Ctrl or C creep, F use), and
## its walk, sprint, creep and tank (sim/stamina.gd, the way client/play_link.gd steps them).
var raise_latch := false
var tank: Stamina.Stamina = Stamina.fresh_stamina()
var gait: StringName = &"walk"
## The player's brightness (client/brightness.gd, read from their settings file, never written here) on the picture,
## as tape.gdshader's last step does it on the other floors.
var brightness := Brightness.new()
## WF3: the same game on screen. The Ward is drawn at the picture every floor is drawn at, through the tape look
## (client/main.gd make_picture, make_screen; the brightness is the tape's last step, as on every floor), with
## the main game's HUD (client/hud.gd), its instrument (client/instrument_view.gd) and its crew figures with their
## drawn faces and name tags (client/others_view.gd, main.gd name_tag), and its eyes (client/eye_height.gd: the
## camera drops when you creep). The Ward's own lines (the lift's clock, STEP OUT OF THE LIFT, the prompts) are
## the HUD's, in the HUD's words and places.
var picture: SubViewport = Main.make_picture()
var screen: TextureRect = Main.make_screen(picture)
var tape_mat: ShaderMaterial = screen.material as ShaderMaterial
var hud := Hud.new()
var inst_view := InstrumentView.new()
var others := OthersView.new()
var eye := EyeHeight.new()
var tick_acc := 0.0
var walk_speed := 0.0
## Tests: the window size the name tags are placed for (a headless window is 64 pixels square); zero: the real one.
var tag_window := Vector2.ZERO

func _ready() -> void:
	Main._add_actions()
	_build_screen()
	_build_card()
	if handed and room != null:
		# PL2, tests only (tools/play_late.mjs fallback A): a headless client handed a room walks as the review's
		# "boarder" (out of the lift, back in when it returns) when automated (auto=1) and asked to.
		var user_args := OS.get_cmdline_user_args()
		if user_args.has("auto=1") and user_args.has("ward_handed_walk=1"):
			test_role = "boarder"
			print("WARD REVIEW TEST WALK boarder")
		var overlay := CanvasLayer.new()
		add_child(overlay)
		overlay.add_child(status)
		status.position = Vector2(30, 40)
		status.text = "THE LIFT OPENS ON THE HANGING WARD"
		if not media_ready():
			# Everything the Ward draws ships in the game (godot/assets/ward); a message, never a crash.
			status.text = "THE WARD'S FILES ARE MISSING FROM THIS BUILD."
		return
	var address := ""
	var who := "Ward reviewer"
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("ward_review_url="):
			address = arg.trim_prefix("ward_review_url=")
		elif arg.begins_with("ward_review_name="):
			who = arg.trim_prefix("ward_review_name=")
		elif arg == "ward_review_walk=1":
			automate = true
		elif arg == "ward_review_test_edge=1":
			test_edge = true
		elif arg.begins_with("ward_review_test_role="):
			test_role = arg.trim_prefix("ward_review_test_role=")
	var layer := CanvasLayer.new()
	add_child(layer)
	layer.add_child(status)
	status.position = Vector2(30, 40)
	status.text = "CONNECTING TO THE WARD REVIEW"
	if not media_ready():
		status.text = "THE WARD'S FILES ARE MISSING FROM THIS BUILD."
		set_process(false)
		return
	if address.is_empty() and OS.get_cmdline_user_args().has("owner_review=ward_ground"):
		var solo := LocalRoom.new()
		solo.open_local("ward-ground-review",who,false)
		solo.start_playtest(1)
		solo.host.start_ward_review(8143,true)
		if test_role == "stairs":
			var house: House = solo.host._ward_review.houses[1]
			var stair: House.Stair = house.stairs[0]
			var foot := house.to_world(stair.from)
			var top := house.to_world(stair.to)
			var landing := house.to_world(stair.to + Vector3(0, 0, -0.69))
			stair_route.assign([top, landing, top, foot])
			solo.host._place(LocalRoom.ME, Move.Body.make(foot.x, foot.z, 0, foot.y), solo.host.state.depth, solo.host.state)
		room = solo
		return
	room = RoomClient.new()
	if not address.begins_with("ws://127.0.0.1:"):
		status.text = "THE WARD REVIEW REQUIRES A LOCAL ROOM."
		return
	var err: Error = room.connect_to(address, "", who)
	if err != OK:
		status.text = "WARD REVIEW COULD NOT CONNECT (%d)" % err
		print(status.text)
	else:
		print("WARD REVIEW CONNECTING")

## Names by player id from the room's people rows ([id, name, ...]).
static func names_of(people: Array) -> Dictionary:
	var out := {}
	for row: Variant in people:
		if row is Array and row.size() >= 2:
			out[str(row[0])] = str(row[1])
	return out

static func media_ready() -> bool:
	return ResourceLoader.exists(View.RIGGER_PATH) and ResourceLoader.exists(View.HAND_PATH) and ResourceLoader.exists(View.WARNING_PATH)

## The Ward is over for this screen: the host has dropped the Ward's block, with the crew home, or (cycles, FL2: the
## Ward's lift rides down) on the Reactor's floor below. The main game takes the room back and, on the Reactor's
## floor, hands it on to the Reactor's scene (client/main.gd floor_handover).
static func handback_due(latest: Variant) -> bool:
	if not latest is Dictionary or latest.get("ward") != null:
		return false
	var depth := int(latest.get("depth", -1))
	return depth == 0 or (depth > 0 and latest.get("reactor") is Dictionary)

func _process(_delta: float) -> void:
	if view == null:
		hud.center_note = status.text
	if room == null:
		return
	var now := Time.get_ticks_usec() / 1000000.0
	room.poll(now)
	if room.status != last_room_status:
		last_room_status = room.status
		print("WARD REVIEW ROOM %s" % room.status)
	if room.status == "closed":
		status.text = "WARD REVIEW DISCONNECTED"
		if handed:
			# A normal run's connection dropped: back to the title with the reason, never a still screen.
			status.show()
			status.text = "DISCONNECTED FROM THE ROOM"
			_to_title(close_reason(int(room.close_code)))
		return
	if room.status == "lobby" and not room.my_ready and not room.run_on:
		room.set_ready(true)
		status.text = "WAITING FOR THE CREW"
	var c: Client = room.client
	if c == null:
		return
	if c.latest != null and handback_due(c.latest):
		set_process(false)
		set_physics_process(false)
		_open_prison.call_deferred()
		return
	if handed and not media_ready():
		return
	var local := Client.LocalFrame.new()
	local.body = Move.Body.make(0.0, 0.0, 0, 0.0)
	local.eye = EyeHeight.STAND
	if view != null:
		view.camera.position.y = eye.update(EyeHeight.target("ok", String(gait)), _delta)
		local.eye = view.camera.position.y
		var feet := view.player.position
		local.body = Move.Body.make(feet.x, feet.z, 0, feet.y)
		local.yaw = view.player.rotation.y
		local.pitch = view.camera.rotation.x
		local.gait = String(gait)
		local.stamina = tank
		local.use = Input.is_action_pressed("use")
		local.raised = _raised()
		if view.caught or card_open:
			# A watcher (or a player at the Esc card) sends nothing of their own: no use, no raise, no run.
			raise_latch = false
			gait = &"walk"
			local.gait = "walk"
			local.use = false
			local.raised = false
	var frame: Client.Frame = room.frame(now, local)
	if c.latest == null or c.latest.get("ward") == null:
		return
	var world: Dictionary = c.latest
	var snapshot: Dictionary = world.ward
	if view == null:
		var fixture := Ward.new(int(snapshot.seed)).lift_door()
		var spawn := fixture + Vector3(0, 0.06, -1.5)
		for index: int in world.players.size():
			var row: Dictionary = world.players[index]
			if row.id == str(c.id):
				spawn = fixture + Vector3(-0.28 + float(index % 2) * 0.56, 0.02, -0.55 - 0.59 * float(index / 2))
				break
		if frame.placed != null:
			spawn = Vector3(frame.placed.x, frame.placed.y, frame.placed.z)
		view = View.new(int(snapshot.seed), spawn)
		view.own_hud = false
		view.capsules = false
		picture.add_child(view)
		hud.set_seed(str(c.seed))
		status.hide()
		automated_start = now
		print("WARD REVIEW READY id=%s seed=%s playing=%s" % [c.id, snapshot.seed, c.playing])
	elif frame.placed != null:
		view.player.position = Vector3(frame.placed.x, frame.placed.y, frame.placed.z)
	view.names = names_of(room.people)
	view.show_host(snapshot, c.clock.host_time(room._now), str(c.id), world.players)
	if c.playing and snapshot.phase != "departed":
		for row: Dictionary in world.players:
			if row.id == str(c.id):
				# WN4: by input number, so a step the host refused brings this screen back to the host.
				view.reconcile(row.body, c._seq, c._host_tank_seq, frame.placed != null)
				break
	_show_hud(world, snapshot, c, frame, now, _delta)
	if snapshot.phase == "departed" and world.summary is Dictionary:
		var total := float(world.summary.total)
		var share := float(world.summary.shares.get(str(c.id), 0.0))
		hud.note = "BANK %d   YOUR SHARE %d" % [floori(total), floori(share)]
		if last_report != "departed":
			print("WARD REVIEW BANK id=%s total=%s share=%s" % [c.id, total, share])
	while event_index < c.events.size():
		view.play_event(c.events[event_index])
		event_index += 1
	if last_report != snapshot.phase:
		last_report = snapshot.phase
		print("WARD REVIEW STATE id=%s phase=%s collectionAt=%s departAt=%s" % [c.id, snapshot.phase, snapshot.collectionAt, snapshot.departAt])
		if snapshot.phase == "departed":
			var terminal := "spectating"
			if snapshot.boarded.has(str(c.id)):
				terminal = "aboard"
			elif snapshot.leftBehind.has(str(c.id)):
				terminal = "leftBehind"
			print("WARD REVIEW RESULT id=%s outcome=%s" % [c.id, terminal])
	if view.caught and not last_caught:
		last_caught = true
		print("WARD REVIEW CONTACT id=%s" % c.id)

func _physics_process(delta: float) -> void:
	if view == null or room == null or card_open or view.caught or view.local_phase == "departed" or room.client == null or not room.client.playing:
		return
	tank = room.client.correct_stamina(tank)
	var input := move_axes()
	if automate and Time.get_ticks_usec() / 1000000.0 - automated_start < 2.0:
		input.y = -1
	var vector := view.player.basis * Vector3(input.x, 0, input.y).normalized()
	if test_role in ["probe", "boarder"]:
		vector = _test_walk()
	var moving := not vector.is_zero_approx() or not stair_route.is_empty()
	var cap := Instrument.max_walk_speed(true, Stamina.WALK_SPEED) if _raised() else INF
	gait = Stamina.gait_for(tank, _running(), _creeping(), moving, cap)
	var speed := minf(cap, Stamina.speed_for(gait))
	if not stair_route.is_empty():
		var destination := stair_route[test_leg]
		var offset := destination - view.player.position
		var horizontal := Vector3(offset.x, 0, offset.z)
		vector = horizontal.normalized()
		if offset.length() < 0.045:
			var accepted := false
			for row: Dictionary in room.client.latest.players:
				if row.id == LocalRoom.ME:
					var body: Move.Body = row.body
					accepted = Vector3(body.x, body.y, body.z).distance_to(destination) < 0.065
			if accepted:
				print("WARD STAIR CHECKPOINT %d height %.3f" % [test_leg, view.player.position.y])
				test_leg += 1
				if test_leg == stair_route.size():
					stair_route.clear()
					print("WARD UPPER LANDING AND RETURN PASSED")
					get_tree().quit()
			return
	var before := view.player.position
	view._move(vector * speed, delta)
	var after := view.player.position
	walk_speed = Vector2(after.x - before.x, after.z - before.z).length() / delta if delta > 0.0 else 0.0
	tank = Stamina.step_stamina(tank, gait, Vector2(after.x - before.x, after.z - before.z).length() / delta if delta > 0.0 else 0.0, delta)

## The main game's movement keys: x to the right, y backwards (client/main.gd _add_actions).
static func move_axes() -> Vector2:
	return Vector2(Input.get_action_strength("right") - Input.get_action_strength("left"),
		Input.get_action_strength("back") - Input.get_action_strength("forward"))

func _raised() -> bool:
	return test_role == "boarder" or (test_role == "probe" and test_leg > 0) or raise_latch or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)

func _running() -> bool:
	return test_role == "probe" or Input.is_action_pressed("sprint")

func _creeping() -> bool:
	return test_role == "" and Input.is_action_pressed("creep")

func _test_walk() -> Vector3:
	var house: House = view.houses[0].fixture
	if test_role == "boarder" and test_edge and view.local_phase == "away":
		var site: Dictionary = view.walk_model.layout.houses[0]
		var edge := float(site.y) + float(site.d) * 0.5 + 1.6
		if view.player.position.z >= edge - 0.5:
			if not test_at_edge:
				test_at_edge = true
				print("WARD EDGE FORWARD INPUT")
			return Vector3.BACK
	var target := Vector3.ZERO
	if test_role == "probe":
		var rear: Vector3 = house.areas[&"rear"]
		target = house.to_world(Vector3(rear.x, 0, house.floor_bounds.get_center().y if test_leg == 0 else rear.z))
	else:
		var cabin := view.lift_spot
		target = cabin + Vector3.BACK * 2.05
		if view.local_phase == "boarding":
			target = cabin
	var direction := target - view.player.position
	direction.y = 0.0
	if direction.length() < 0.095:
		if test_role == "probe":
			test_leg = 1
		return Vector3.ZERO
	return direction.normalized()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_ESCAPE:
		if card_open:
			resume()
		else:
			open_card()
		get_viewport().set_input_as_handled()
		return
	if card_open:
		return
	if view != null and not view.caught and event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_E:
		# The instrument on E, as on every floor (client/main.gd): a press raises it, the next lowers it.
		raise_latch = not raise_latch
		get_viewport().set_input_as_handled()
		return
	if view != null:
		view.look_input(event)

## The picture and the screen showing it through the tape (under everything), the instrument drawn into the
## picture (so the tape lies over it), the crew figures in the Ward's world, and the HUD crisp over the tape.
func _build_screen() -> void:
	add_child(picture)
	var back := CanvasLayer.new()
	back.layer = -1
	add_child(back)
	back.add_child(screen)
	var in_picture := CanvasLayer.new()
	picture.add_child(in_picture)
	inst_view.size = Vector2(picture.size)
	in_picture.add_child(inst_view)
	others.name = "Others"
	picture.add_child(others)
	var front := CanvasLayer.new()
	add_child(front)
	front.add_child(hud)
	status.visible = false
	brightness.load_saved()
	apply_brightness(brightness.level)

## The player's brightness on the tape, as on every floor (client/main.gd brightness_on).
func apply_brightness(lv: int) -> void:
	Main.brightness_on(tape_mat, lv)

## The camera the screen is drawn from: the player's, or a caught player's watching camera.
func view_camera() -> Camera3D:
	return view.watch_camera if view.watching else view.camera

## The HUD from the Ward's snapshot: the lift's clock under PLAY (the Tenant clock's place; the Ward has none of
## its own), the prompt line, the tapes held on the counter, the instrument as the host reads it, the crew
## figures and their name tags, and how out of breath the player is on the tape (the main game's sum).
func _show_hud(world: Dictionary, ward: Dictionary, c: Client, frame: Client.Frame, now: float, delta: float) -> void:
	var phase := str(ward.phase)
	var line: String = view.hud.text
	hud.tenant_line = "" if phase == "unloading" else line
	hud.tenant_warn = phase == "boarding" or (phase == "away" and float(ward.collectionAt) - c.clock.host_time(room._now) <= 60.0)
	hud.prompt = view.prompt.text if view.prompt.text != "" else (line if phase == "unloading" else "")
	var count := 0
	var value := 0.0
	var me: Variant = c.me()
	if me is Dictionary:
		var md: Dictionary = me
		var all: Array = [md["tape"]]
		all.append_array(md.get("carrying", []))
		for t: Dictionary in all:
			if int(t["readings"]) > 0:
				count += 1
			value += float(t["total"])
		var tick_hz := float(md.get("tickHz", 0.0))
		tick_acc += tick_hz * delta
		var ticks := int(floorf(tick_acc))
		tick_acc -= ticks
		inst_view.update_view(delta, _raised() and not view.caught, str(md.get("needle", "off")), float(md.get("open", 0.0)), null, tick_hz, ticks, walk_speed)
	hud.set_tapes(count, value)
	tape_mat.set_shader_parameter("tired", 0.85 * pow(Stamina.exertion(tank), 1.4))
	var cam := view_camera()
	var list := crew_rows(world, ward, frame, c, names_of(room.people))
	others.update(delta, list, cam.global_position)
	var tags: Array = []
	var win := tag_window if tag_window != Vector2.ZERO else get_viewport().get_visible_rect().size
	var space := view.get_world_3d().direct_space_state
	var from := cam.global_position
	var sees := func(at: Vector3, _level: int) -> bool:
		return space.intersect_ray(PhysicsRayQueryParameters3D.create(from, at)).is_empty()
	for o: Dictionary in list:
		var tag := Main.name_tag(o, cam, win, false, sees)
		if not tag.is_empty():
			tags.append(tag)
	hud.tags = tags

## The other players as the main game's crew view takes them (client/play_link.gd _others): the frame's
## interpolated bodies, their place in the crew (dress and number), raised or not, their drawn faces; a player
## the hand caught lies as a caught player does on every floor.
static func crew_rows(world: Dictionary, ward: Dictionary, frame: Client.Frame, c: Client, names: Dictionary) -> Array:
	var order := {}
	for i: int in world.players.size():
		order[str(world.players[i].id)] = i
	var raised := {}
	for m: Dictionary in world.crew:
		raised[str(m.id)] = bool(m.get("raised", false))
	var caught: Array = ward.get("caught", [])
	var out: Array = []
	for p: Dictionary in frame.players:
		var id := str(p["id"])
		var b: Move.Body = p["body"]
		out.append({"id": id, "name": str(names.get(id, id)), "index": int(order.get(id, 0)), "x": b.x, "y": b.y, "z": b.z, "level": b.level,
			"yaw": float(p["yaw"]), "pitch": float(p.get("pitch", 0.0)), "gait": str(p.get("gait", "walk")),
			"status": "caught" if caught.has(id) else str(p.get("status", "ok")), "active": bool(p.get("active", true)),
			"raised": bool(raised.get(id, false)), "face": str(c.faces.get(id, ""))})
	return out

func _build_card() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 20
	add_child(layer)
	layer.add_child(card)
	card.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	card.grow_vertical = Control.GROW_DIRECTION_BOTH
	var rows := VBoxContainer.new()
	card.add_child(rows)
	for pair: Array in [["RESUME", resume], ["LEAVE TO TITLE", leave_to_title]]:
		var button := Button.new()
		button.text = pair[0]
		button.custom_minimum_size = Vector2(260, 44)
		button.pressed.connect(pair[1])
		rows.add_child(button)
	card.hide()

func open_card() -> void:
	card_open = true
	card.show()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func resume() -> void:
	card_open = false
	card.hide()
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

## Leaves the room cleanly (the host sees this player go) and returns to the title.
func leave_to_title() -> void:
	if room != null:
		room.leave()
	_to_title("YOU LEFT THE HANGING WARD.")

## The title's line for a dropped connection (the main game's words for these codes).
static func close_reason(code: int) -> String:
	match code:
		4001:
			return "WRONG PASSPHRASE. ASK WHOEVER RUNS THE SERVER FOR TONIGHT'S."
		4002:
			return "THE ROOM IS FULL: 8 PLAYERS ARE IN."
		4003, 4004, 4005, 4006:
			return "THE SERVER DROPPED THIS GAME: CODE %d." % code
		1001:
			return "THE SERVER STOPPED."
		1000:
			return "THE ROOM CLOSED."
	return "CONNECTION LOST IN THE HANGING WARD."

func _to_title(reason: String) -> void:
	title_reason = reason
	room = null
	card_open = false
	card.hide()
	set_process(false)
	set_physics_process(false)
	_open_title.call_deferred()

func _open_title() -> void:
	var main := (load("res://main.tscn") as PackedScene).instantiate()
	var tree := get_tree()
	tree.root.add_child(main)
	tree.current_scene = main
	# The main game's _ready has put up the title; its start screen's error line carries the reason.
	var start: Variant = main.get("start")
	if start != null:
		start.error = title_reason
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	queue_free()

## The main game, holding this scene's room, ready to enter the prison (main.gd _ready takes `ward_room`).
static func prison_for(handing: Variant) -> Node:
	var main := (load("res://main.tscn") as PackedScene).instantiate()
	main.set("ward_room", handing)
	return main

func _open_prison() -> void:
	var main := prison_for(room)
	room = null
	var tree := get_tree()
	tree.root.add_child(main)
	tree.current_scene = main
	queue_free()

func _exit_tree() -> void:
	if room != null:
		room.leave()