# FL1 piece B: a normal run's snapshot with a `ward` or `reactor` block takes the main game's screen to that
# floor's own scene with the room it already plays in (client/main.gd floor_handover, _enter_floor), and the
# floor's end brings that same room back to the main game's prison (client/ward/review.gd handback_due,
# prison_for; the Reactor's compiled scene hands back through client/reactor_screening.gd).
#
# The two floors' media live in private packs (WardGroundMedia.pck, ReactorCampaign.pck), never in the
# repository. The tests that need them read the folder from GD_PACKS_DIR and SKIP (pass, printing
# "skipped: pack not found") when it is unset or the file is not there, as on CI.
# The missing-pack test runs first in this file: once a pack is mounted it stays mounted for the process.
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

static func _packs(file: String) -> String:
	var dir := OS.get_environment("GD_PACKS_DIR")
	if dir.is_empty() or not FileAccess.file_exists(dir.path_join(file)):
		return ""
	return dir

static func _ward_room() -> LocalRoom:
	var room := LocalRoom.new()
	room.open_local("fl1-ward", "Tester", true)
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

static func _main_for(room: Variant, local: bool, packs: String) -> Main:
	var main := Main.new()
	main.hud = Hud.new()
	main.pack_dir = packs
	main.link = PlayLink.new(room, local)
	return main

static func _drop(main: Main) -> void:
	if is_instance_valid(main):
		if is_instance_valid(main.hud):
			main.hud.free()
		main.free()

func test_missing_pack_explains_the_file_and_keeps_the_room(t: T) -> void:
	if ResourceLoader.exists("res://assets/ward/rigger.glb") or ResourceLoader.exists("res://reactor_campaign.tscn"):
		t.note("skipped: a pack is already mounted in this process")
		return
	var tree := Engine.get_main_loop() as SceneTree
	var before := tree.current_scene
	var nowhere := OS.get_user_data_dir().path_join("fl1-no-packs-here")
	# Alone, on the Ward.
	var room := _ward_room()
	t.eq(Main.floor_handover(room.client.latest), "ward", "the review start gives the same ward block")
	var main := _main_for(room, true, nowhere)
	var link := main.link
	main._enter_floor("ward", room)
	t.check(main.link == link, "the player keeps playing in the room (not sent to the title or Join)")
	t.check(room.status != "closed", "the room is not left")
	t.eq(main._floor_media_missing, "ward", "the missing floor is remembered, so the swap is not retried every frame")
	t.check(main.hud.note.contains("WardGroundMedia.pck") and main.hud.note.contains("beside the game"), "the screen names the file to put beside the game: " + main.hud.note)
	t.check(tree.current_scene == before, "no scene swap")
	_drop(main)
	room.leave()
	# Joined, on the Reactor (a room client; its connection is not touched).
	var joined := RoomClient.new()
	main = _main_for(joined, false, nowhere)
	link = main.link
	main._enter_floor("reactor", joined)
	t.check(main.link == link and joined.status != "closed", "a joined player without the Reactor pack stays in the room")
	t.check(main.hud.note.contains("ReactorCampaign.pck"), "the screen names the Reactor's file: " + main.hud.note)
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
	var packs := _packs("WardGroundMedia.pck")
	if packs.is_empty():
		t.note("skipped: pack not found (set GD_PACKS_DIR to the folder holding WardGroundMedia.pck)")
		return
	var tree := Engine.get_main_loop() as SceneTree
	var before := tree.current_scene
	var room := _ward_room()
	var main := _main_for(room, true, packs)
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
	room.time_scale = 60.0
	var due := false
	# The lift's boarding and the ride home take well under 90 s of host time; past that the hand-back is late.
	var give_up := room.host.state.t + 90.0
	var steps := 0
	while room.host.state.t < give_up and steps < 4000:
		steps += 1
		scene._process(0.016)
		if not scene.is_processing():
			due = Review.handback_due(room.client.latest)
			break
		OS.delay_usec(2000)
	t.note("ward hand-back after %d frames, host time %.1f s" % [steps, room.host.state.t])
	t.check(due, "the Ward's day ends with the crew home and this scene handing back (depth %d)" % room.client.latest.depth)
	t.check(scene.get("view").get("local_phase") == "departed", "after the lift departed")
	var prison := Review.prison_for(room)
	t.check(prison.get("ward_room") == room, "the prison gets the same room")
	prison.free()
	tree.current_scene = before
	scene.set("room", null)
	scene.get_parent().remove_child(scene)
	scene.free()
	_drop(main)
	room.leave()

func test_reactor_block_enters_the_pack_scene_with_the_same_room(t: T) -> void:
	var packs := _packs("ReactorCampaign.pck")
	if packs.is_empty():
		t.note("skipped: pack not found (set GD_PACKS_DIR to the folder holding ReactorCampaign.pck)")
		return
	var tree := Engine.get_main_loop() as SceneTree
	var before := tree.current_scene
	var room := _reactor_room()
	t.eq(Main.floor_handover(room.client.latest), "reactor", "the review start gives the same reactor block")
	var main := _main_for(room, true, packs)
	# The private pack's resources carry stale UIDs, and the engine warns once per load of each. Those warnings
	# are the pack's: load them here, quietly and held for the whole test, so the cached copies are what the code
	# under test uses and every error it raises still counts. Nothing but loads runs while quiet.
	t.check(main._mount_floor_pack("reactor"), "the Reactor pack mounts")
	var printing := Engine.print_error_messages
	Engine.print_error_messages = false
	var held: Array[Resource] = [load("res://reactor_campaign.tscn"), load("res://crew23_motion.glb")]
	Engine.print_error_messages = printing
	t.check(held.all(func(r: Resource) -> bool: return r != null), "the pack's scene and crew model load")
	main._enter_floor("reactor", room)
	var scene := tree.current_scene
	if not t.check(scene != before and scene != null and scene.scene_file_path == "res://reactor_campaign.tscn", "the Reactor's scene is on screen"):
		_drop(main)
		room.leave()
		return
	t.check(scene.get("game") == room, "the compiled Reactor scene plays this LocalRoom (alone)")
	t.check(str(scene.get("view_id")) == str(room.client.id), "as this player")
	t.check(main.link == null, "the main game let go of the room")
	for i in 30:
		scene._physics_process(1.0 / 60.0)
		OS.delay_usec(2000)
	var frame: Variant = scene.get("frame")
	t.check(frame is Dictionary and frame.has("power") and int(frame.get("seed", -1)) == REACTOR_SEED, "the scene draws this room's reactor block")
	# The floor's end: the host takes the crew home and the scene asks to hand the room back.
	room.host._reactor_review.rules.returned = true
	var handing := false
	for i in 200:
		scene._physics_process(1.0 / 60.0)
		if scene.has_method("_process"):
			scene._process(1.0 / 60.0)
		var screen: Variant = scene.get("screen")
		if screen != null and screen.get("handing_off"):
			handing = true
			break
		OS.delay_usec(2000)
	t.check(room.client.latest.depth == 0, "the crew is home")
	t.check(handing, "the Reactor scene hands the room back to the prison")
	tree.current_scene = before
	# Its queued hand-back (a deferred call on the screen) must not open a main game after this test.
	var screen_node: Variant = scene.get("screen")
	scene.set("game", null)
	scene.get_parent().remove_child(scene)
	scene.free()
	if is_instance_valid(screen_node):
		t.note("the Reactor screen outlived its scene; freeing it")
		(screen_node as Node).free()
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
	var packs := _packs("WardGroundMedia.pck")
	if packs.is_empty():
		t.note("skipped: pack not found (set GD_PACKS_DIR to the folder holding WardGroundMedia.pck)")
		return
	if not Review.media_ready():
		ProjectSettings.load_resource_pack(packs.path_join("WardGroundMedia.pck"), false)
	t.check(Review.media_ready(), "the Ward pack mounts")
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

# --- RX1: inside the real compiled Reactor (the private pack): the tape on its plinth, glowing, with its prompt;
# the fuse where the host hid it. Skips without the pack, like the tests above.
func test_rx1_reactor_pack_scene_shows_the_tape_and_the_hidden_fuse(t: T) -> void:
	var packs := _packs("ReactorCampaign.pck")
	if packs.is_empty():
		t.note("skipped: pack not found (set GD_PACKS_DIR to the folder holding ReactorCampaign.pck)")
		return
	var tree := Engine.get_main_loop() as SceneTree
	var before := tree.current_scene
	var room := _reactor_room()
	var main := _main_for(room, true, packs)
	t.check(main._mount_floor_pack("reactor"), "the Reactor pack mounts")
	var printing := Engine.print_error_messages
	Engine.print_error_messages = false
	var held: Array[Resource] = [load("res://reactor_campaign.tscn"), load("res://crew23_motion.glb")]
	Engine.print_error_messages = printing
	t.check(held.all(func(r: Resource) -> bool: return r != null), "the pack's scene loads")
	main._enter_floor("reactor", room)
	var scene := tree.current_scene
	if not t.check(scene != before and scene != null and scene.scene_file_path == "res://reactor_campaign.tscn", "the Reactor's scene is on screen"):
		_drop(main)
		room.leave()
		return
	for i in 20:
		scene._physics_process(1.0 / 60.0)
		OS.delay_usec(2000)
	var rules: Variant = room.host._reactor_review.rules
	var marks: Variant = scene.get_node_or_null("ReactorMarks")
	t.check(marks != null, "the repository's marks are in the compiled scene (added by client/reactor_screening.gd)")
	var tape: Node3D = scene.get("cassette")
	var body := tape.get_child(0) as Node3D
	# The pack's plinth: the 0.66 x 0.84 x 0.5 box.
	var plinth: MeshInstance3D = null
	for c: Node in scene.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).mesh is BoxMesh and ((c as MeshInstance3D).mesh as BoxMesh).size.is_equal_approx(Vector3(0.66, 0.84, 0.5)):
			plinth = c
	t.check(plinth != null, "the pack draws the tape's plinth")
	if plinth != null:
		var off := body.global_position - plinth.global_position
		t.check(absf(off.x) < 0.1 and absf(off.z) < 0.1 and absf(off.y - 0.59) < 0.03, "the tape lies on the plinth top (offset %s)" % off)
	t.check(tape.is_visible_in_tree(), "the tape is drawn")
	t.check((scene.get("fuse") as Node3D).global_position.is_equal_approx(rules.fuse), "the fuse is drawn where the host hid it")
	if marks != null:
		marks._process(0.016)
		t.check(marks.glow.visible and marks.glow.global_position.distance_to(body.global_position) < 0.5, "a warm light over the tape")
		scene.walker.position = Vector3(rules.cassette_at.x, 0.04, rules.cassette_at.z + 0.8)
		for i in 10:
			scene._physics_process(1.0 / 60.0)
			marks._process(0.016)
			OS.delay_usec(2000)
		t.check(str(scene.hud.text).ends_with(Marks.TAPE_PROMPT), "beside it the HUD says E picks it up: " + str(scene.hud.text).replace("\n", " / "))
	tree.current_scene = before
	var screen_node: Variant = scene.get("screen")
	scene.set("game", null)
	scene.get_parent().remove_child(scene)
	scene.free()
	if is_instance_valid(screen_node):
		(screen_node as Node).free()
	_drop(main)
	room.leave()
