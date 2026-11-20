# FL1 piece B: a normal run's snapshot with a `ward` or `reactor` block takes the main game's screen to that
# floor's own scene with the room it already plays in (client/main.gd floor_handover, _enter_floor), and the
# floor's end brings that same room back to the main game's prison (client/ward/review.gd handback_due,
# prison_for).
#
# IP1: the Ward's old room runs on the game's own files (godot/assets/ward), so every test here runs on a plain
# checkout. The Reactor's old room was a compiled scene in a separate file that is no longer shipped: the Reactor
# is always the place the main game draws itself, and a reactor block that still asks for the swap keeps the
# player in the room with a plain line.
extends RefCounted

const T = preload("res://tests/t.gd")
const Main = preload("res://client/main.gd")
const Review = preload("res://client/ward/review.gd")
const PlayLink = preload("res://client/play_link.gd")
const LocalRoom = preload("res://net/local_room.gd")
const RoomClient = preload("res://net/room_client.gd")
const Move = preload("res://sim/move.gd")
const Client = preload("res://net/client.gd")
const View = preload("res://client/ward/view.gd")
const Marks = preload("res://client/reactor_marks.gd")

const WARD_SEED := 8143
const REACTOR_SEED := 23

static func _ward_room() -> LocalRoom:
	var room := LocalRoom.new()
	room.open_local("fl1-ward", "Tester", true)
	# This file checks FL1's scene swap: the Ward as a normal level (WN1, net/host_rules.gd ward_place) off.
	room.ward_place = false
	room.reactor_place = false   # and the Reactor as a place (RN1) off: this file checks the old hand-over
	room.start_playtest(1)
	room.host.start_ward_review(WARD_SEED, true)
	for i in 6:
		room.poll(0.05 * i)
	return room

static func _reactor_room() -> LocalRoom:
	var room := LocalRoom.new()
	room.open_local("fl1-reactor", "Tester", true)
	room.start_reactor_review(REACTOR_SEED)
	for i in 6:
		room.poll(0.05 * i)
	return room

static func _main_for(room: Variant, local: bool) -> Main:
	var main := Main.new()
	main.hud = Hud.new()
	main.link = PlayLink.new(room, local)
	return main

static func _drop(main: Main) -> void:
	if is_instance_valid(main):
		if is_instance_valid(main.hud):
			main.hud.free()
		main.free()

func test_the_wards_old_room_is_in_the_game_and_the_reactors_keeps_the_room(t: T) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var before := tree.current_scene
	var main := Main.new()
	t.check(main._floor_media("ward"), "the Ward's old room and everything it draws ship in the game")
	t.check(not main._floor_media("reactor"), "the Reactor's old room is not in the game")
	main.free()
	# Joined, on a reactor block that still asks for the swap (a room client; its connection is not touched).
	var joined := RoomClient.new()
	main = _main_for(joined, false)
	var link := main.link
	main._enter_floor("reactor", joined)
	t.check(main.link == link and joined.status != "closed", "the player stays in the room (not sent to the title or Join)")
	t.eq(main._floor_media_missing, "reactor", "remembered, so the swap is not retried every frame")
	t.check(main.hud.note.contains("not in this build") and not main.hud.note.contains(".pck"), "the screen says so plainly, naming no file: " + main.hud.note)
	t.check(tree.current_scene == before, "no scene swap")
	_drop(main)

func test_snapshot_blocks_choose_the_floor_scene(t: T) -> void:
	t.eq(Main.floor_handover({"depth": 6, "ward": {"phase": "unloading"}}), "ward", "a ward block below ground is the Ward")
	t.eq(Main.floor_handover({"depth": 6, "ward": {"phase": "boarding"}}), "ward", "until its lift has gone")
	t.eq(Main.floor_handover({"depth": 6, "ward": {"phase": "departed"}}), "", "a departed Ward stays with the main game's ride home")
	t.eq(Main.floor_handover({"depth": 0, "ward": {"phase": "unloading"}}), "", "never in the prison")
	t.eq(Main.floor_handover({"depth": 7, "reactor": {"lift": false}}), "reactor", "a reactor block with the crew below is the Reactor")
	t.eq(Main.floor_handover({"depth": 7, "reactor": {"lift": true}}), "", "not once its crew is in the lift")
	t.eq(Main.floor_handover({"depth": 0, "reactor": {"lift": true}}), "", "the prison keeps its cassette deck in the main game")
	t.eq(Main.floor_handover({"depth": 3}), "", "an ordinary floor stays in the main game")
	t.eq(Main.floor_handover(null), "", "no snapshot yet")
	t.check(Review.handback_due({"depth": 0}), "the Ward hands back once the crew is home and the block is gone")
	t.check(not Review.handback_due({"depth": 6, "ward": {"phase": "departed"}}), "not during the ride up")
	t.check(not Review.handback_due({"depth": 0, "ward": {"phase": "departed"}}), "not while the host still sends the block")

func test_picker_names_the_two_floors(t: T) -> void:
	t.eq(Main.playtest_area(&"ward"), "HANGING WARD", "depth 6's place reads HANGING WARD")
	t.eq(Main.playtest_area(&"reactor"), "REACTOR", "depth 7's place reads REACTOR")
	t.eq(Main.playtest_area(&"playroom"), "PLAYROOM", "other places read as before")
	t.eq(Main.playtest_area(&"some_place"), "SOME PLACE", "underscores still read as spaces")

func test_ward_scene_holds_the_room_it_is_given(t: T) -> void:
	# Needs no pack: client/ward/review.tscn is in the repository. Alone and joined.
	var main := Main.new()
	for room: Variant in [LocalRoom.new(), RoomClient.new()]:
		var scene := main._floor_scene("ward", room)
		t.check(scene.get("room") == room and scene.get("handed") == true, "the Ward scene plays the room it was handed (%s)" % ("alone" if room is LocalRoom else "joined"))
		scene.free()
	var prison := Review.prison_for(main)
	t.check(prison.get("ward_room") == main, "the hand-back gives the main game the Ward's room")
	prison.free()
	main.free()

func test_ward_block_enters_the_ward_and_returns_to_the_prison(t: T) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var before := tree.current_scene
	var room := _ward_room()
	var main := _main_for(room, true)
	main._enter_floor("ward", room)
	var scene := tree.current_scene
	if not t.check(scene != before and scene != null and scene.scene_file_path == "res://client/ward/review.tscn", "the Ward's scene is on screen"):
		_drop(main)
		room.leave()
		return
	t.check(scene.get("room") == room, "with the same room (no second room)")
	t.check(main.link == null, "the main game let go of the room")
	for i in 4:
		scene._process(0.016)
	t.check(scene.get("view") != null, "the Ward is drawn from the room's ward block")
	# Bring the Ward's lift back now and let its clock run quickly: the crew is aboard and rides home.
	var ward: Variant = room.host._ward_review
	ward.phase = &"away"
	ward.collection_at = room.host.state.t + 0.5
	# Thirty times real time (it was sixty): under a loaded machine sixty could carry the client from the boarding
	# snapshot to the prison's in one frame, so this scene never drew the departed one (WN1: steadier, same claims).
	room.time_scale = 30.0
	var due := false
	var saw_departed := false
	# The lift's boarding and the ride home take well under 90 s of host time; past that the hand-back is late.
	var give_up := room.host.state.t + 90.0
	var steps := 0
	while room.host.state.t < give_up and steps < 4000:
		steps += 1
		scene._process(0.016)
		if scene.get("view") != null and scene.get("view").get("local_phase") == "departed":
			saw_departed = true
		if not scene.is_processing():
			due = Review.handback_due(room.client.latest)
			break
		OS.delay_usec(2000)
	t.note("ward hand-back after %d frames, host time %.1f s" % [steps, room.host.state.t])
	t.check(due, "the Ward's day ends with the crew home and this scene handing back (depth %d)" % room.client.latest.depth)
	t.check(saw_departed, "after the lift departed (drawn on this scene before the hand-back)")
	var prison := Review.prison_for(room)
	t.check(prison.get("ward_room") == room, "the prison gets the same room")
	prison.free()
	tree.current_scene = before
	scene.set("room", null)
	scene.get_parent().remove_child(scene)
	scene.free()
	_drop(main)
	room.leave()

# --- FL1-B follow-up: a caught Ward player watches the living crew; the Esc card; a disconnect's reason. ---

static func _row(id: String, x: float, z: float, y: float, yaw := 0.0, pitch := 0.0, connected := true) -> Dictionary:
	return {"id": id, "connected": connected, "body": Move.Body.make(x, z, 0, y), "yaw": yaw, "pitch": pitch}

func test_watch_targets_lines_and_reasons(t: T) -> void:
	var crew := [_row("me", 0, 0, 0), _row("p3", 1, 1, 0), _row("p2", 2, 2, 0), _row("gone", 3, 3, 0, 0, 0, false), _row("held", 4, 4, 0)]
	var ward := {"caught": ["me", "held"]}
	t.eq(View.watch_targets(crew, ward, "me"), ["p2", "p3"] as Array[String], "only connected, uncaught crewmates, in a fixed order")
	t.eq(View.watch_targets([_row("me", 0, 0, 0)], {"caught": ["me"]}, "me"), [] as Array[String], "alone: no one to watch")
	t.check(View.watch_line("Bob").contains("BOB") and View.watch_line("Bob").contains("LEFT CLICK OR E"), "the line says whose eyes and how to switch")
	t.eq(View.watch_line(""), "NO ONE LEFT TO WATCH", "the line with no one to watch")
	t.eq(Review.names_of([["p2", "Bob", true], ["p3"]]), {"p2": "Bob"}, "names from the room's people rows")
	t.eq(Review.close_reason(1001), "THE SERVER STOPPED.", "a stopped server reads as one")
	t.eq(Review.close_reason(4002), "THE ROOM IS FULL: 8 PLAYERS ARE IN.", "the main game's words for a full room")
	t.check(not Review.close_reason(1006).is_empty(), "a lost connection always has a line")

func test_esc_card_and_leaving_carry_a_reason_to_the_title(t: T) -> void:
	# Needs no pack: the card and the way out are built before the Ward is drawn.
	var tree := Engine.get_main_loop() as SceneTree
	for how: String in ["leave", "drop"]:
		var room := _ward_room()
		var scene: Node = (load("res://client/ward/review.tscn") as PackedScene).instantiate()
		scene.set("room", room)
		scene.set("handed", true)
		tree.root.add_child(scene)
		if how == "leave":
			var esc := InputEventKey.new()
			esc.physical_keycode = KEY_ESCAPE
			esc.pressed = true
			scene._unhandled_input(esc)
			t.check(scene.get("card_open") and (scene.get("card") as Control).visible, "Esc opens the card")
			t.eq(Input.mouse_mode, Input.MOUSE_MODE_VISIBLE, "the mouse is free while the card is open")
			scene._unhandled_input(esc)
			t.check(not scene.get("card_open") and not (scene.get("card") as Control).visible, "Esc again resumes")
			scene.open_card()
			scene.leave_to_title()
			t.eq(room.status, "closed", "LEAVE TO TITLE leaves the room cleanly")
			t.eq(scene.get("title_reason"), "YOU LEFT THE HANGING WARD.", "the title says why")
		else:
			room.leave()
			scene._process(0.016)
			t.eq(scene.get("title_reason"), Review.close_reason(room.close_code), "a dropped connection's reason goes to the title")
		t.check(not scene.is_processing() and scene.get("room") == null, "the Ward scene lets go of the room (%s)" % how)
		# Freed now, so its queued switch to the title never runs after this test.
		scene.get_parent().remove_child(scene)
		scene.free()
		room.leave()

func test_caught_player_watches_a_living_crewmate(t: T) -> void:
	t.check(Review.media_ready(), "the Ward's files are in the game")
	var room := _ward_room()
	var ward: Dictionary = (room.client.latest.ward as Dictionary).duplicate(true)
	var tree := Engine.get_main_loop() as SceneTree
	var view := View.new(int(ward.seed), Vector3(0, 0.1, 0))
	tree.root.add_child(view)
	view.names = {"p2": "Bob", "p3": "Cy"}
	ward.caught = ["me"]
	var crew := [_row("me", 0, 0, 0.1), _row("p2", 1.0, 2.0, 0.5, 0.7, -0.1)]
	view.show_host(ward, 10.0, "me", crew)
	t.check(view.caught and view.prompt.text == "THE HAND CAUGHT YOU" and not view.watching, "first the caught line")
	view.show_host(ward, 11.5, "me", crew)
	t.check(not view.watching, "still the caught line before two seconds")
	view.show_host(ward, 12.05, "me", crew)
	t.check(view.watching and view.watch_camera.current, "within two seconds the screen watches")
	t.check(view.watch_camera.position.distance_to(Vector3(1.0, 0.5 + View.WATCH_EYE, 2.0)) < 0.01, "from the crewmate's eyes: %s" % view.watch_camera.position)
	t.check(absf(view.watch_camera.rotation.y - 0.7) < 0.01, "facing their way")
	t.check(view.prompt.text.contains("BOB"), "the line names whose eyes: " + view.prompt.text)
	t.check(not (view.peers["p2"] as Node3D).visible, "the watched crewmate's own figure is hidden from inside it")
	var yaw := view.player.rotation.y
	var look := InputEventMouseMotion.new()
	look.relative = Vector2(300, 0)
	view.look_input(look)
	t.eq(view.player.rotation.y, yaw, "a watcher's mouse does not turn their own body")
	crew.append(_row("p3", -3.0, 4.0, 0.0, 1.2))
	var e := InputEventKey.new()
	e.physical_keycode = KEY_E
	e.pressed = true
	view.look_input(e)
	for i in 30:
		view.show_host(ward, 12.1 + i * 0.016, "me", crew)
	t.eq(view.watch_id, "p3", "E moves on to the next living crewmate")
	t.check(view.watch_camera.position.distance_to(Vector3(-3.0, View.WATCH_EYE, 4.0)) < 0.05, "smoothly to their eyes: %s" % view.watch_camera.position)
	ward.caught = ["me", "p2", "p3"]
	view.show_host(ward, 13.0, "me", crew)
	t.eq(view.prompt.text, "NO ONE LEFT TO WATCH", "with no one living, a plain line")
	t.check(view.watch_camera.position.y > 10.0, "and a fixed view from high above the houses")
	t.check(view.hud.text.begins_with("LIFT") or view.hud.text == "STEP OUT OF THE LIFT", "the lift timer line stays: " + view.hud.text)
	view.get_parent().remove_child(view)
	view.free()
	room.leave()
