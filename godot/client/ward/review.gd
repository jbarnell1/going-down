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

func _ready() -> void:
	_build_card()
	if handed and room != null:
		var overlay := CanvasLayer.new()
		add_child(overlay)
		overlay.add_child(status)
		status.position = Vector2(30, 40)
		status.text = "THE LIFT OPENS ON THE HANGING WARD"
		if not media_ready():
			# The main game checks the pack before handing over; this stays a message, never a crash.
			status.text = "Install WardGroundMedia.pck beside the game to open the Ward."
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
	if not ResourceLoader.exists(View.RIGGER_PATH):
		var media := OS.get_executable_path().get_base_dir().path_join("WardGroundMedia.pck")
		if FileAccess.file_exists(media): ProjectSettings.load_resource_pack(media,false)
	if not media_ready():
		status.text = "Install WardGroundMedia.pck beside the game to open the Ward."
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

## The Ward's day is over for this screen: the crew is home and the host has dropped the Ward's block.
static func handback_due(latest: Variant) -> bool:
	return latest is Dictionary and int(latest.get("depth", -1)) == 0 and latest.get("ward") == null

func _process(_delta: float) -> void:
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
	local.eye = 1.56
	if view != null:
		var feet := view.player.position
		local.body = Move.Body.make(feet.x, feet.z, 0, feet.y)
		local.yaw = view.player.rotation.y
		local.pitch = view.camera.rotation.x
		local.gait = "sprint" if _running() else "walk"
		local.use = Input.is_physical_key_pressed(KEY_F)
		local.raised = _raised()
		if view.caught or card_open:
			# A watcher (or a player at the Esc card) sends nothing of their own: no use, no raise, no run.
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
		add_child(view)
		status.hide()
		automated_start = now
		print("WARD REVIEW READY id=%s seed=%s playing=%s" % [c.id, snapshot.seed, c.playing])
	elif frame.placed != null:
		view.player.position = Vector3(frame.placed.x, frame.placed.y, frame.placed.z)
	view.names = names_of(room.people)
	view.show_host(snapshot, c.clock.host_time(now), str(c.id), world.players)
	if c.playing and snapshot.phase != "departed":
		for row: Dictionary in world.players:
			if row.id == str(c.id):
				view.reconcile(row.body)
				break
	for member: Dictionary in world.crew:
		if member.id == str(c.id) and snapshot.phase != "departed":
			var tape: Dictionary = member.tape
			view.hud.text += "\nTAPE %d   %s" % [floori(tape.total), String(member.needle).to_upper()]
			break
	if snapshot.phase == "departed" and world.summary is Dictionary:
		var total := float(world.summary.total)
		var share := float(world.summary.shares.get(str(c.id), 0.0))
		view.hud.text += "\nBANK %d   YOUR SHARE %d" % [floori(total), floori(share)]
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
	var input := Vector2(int(Input.is_physical_key_pressed(KEY_D)) - int(Input.is_physical_key_pressed(KEY_A)),
		int(Input.is_physical_key_pressed(KEY_S)) - int(Input.is_physical_key_pressed(KEY_W)))
	if automate and Time.get_ticks_usec() / 1000000.0 - automated_start < 2.0:
		input.y = -1
	var speed := Instrument.max_walk_speed(_raised(), 3.25 if _running() else 1.85)
	var vector := view.player.basis * Vector3(input.x, 0, input.y).normalized()
	if test_role in ["probe", "boarder"]:
		vector = _test_walk()
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
	view._move(vector * speed, delta)

func _raised() -> bool:
	return test_role == "boarder" or (test_role == "probe" and test_leg > 0) or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)

func _running() -> bool:
	return test_role == "probe" or Input.is_physical_key_pressed(KEY_SHIFT)

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
	if view != null:
		view.look_input(event)

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