# FL2 (cycles): the Hanging Ward's lift rides down, so its screen hands the room on to the Reactor's instead of the
# prison (client/ward/review.gd handback_due; client/main.gd floor_handover, _enter_floor).
#   - Always: alone with the game's deck (cycles on), the Ward at floor 6 departs with the player aboard, the room
#     arrives at floor 7 with a Reactor block and no Ward block, the Ward's screen is due to hand back, and the main
#     game it hands to picks the Reactor's scene.
#   - With the private packs (GD_PACKS_DIR holding WardGroundMedia.pck and ReactorCampaign.pck): the same through the
#     real scenes, the Ward's scene on screen first and the Reactor's compiled scene after it, with the same room.
#     SKIPPED (passes, printing why) when a pack is not there, as on CI.
# Run after test_floor_entry (its first test needs no pack mounted in the process).
extends RefCounted

const T = preload("res://tests/t.gd")
const Main = preload("res://client/main.gd")
const Review = preload("res://client/ward/review.gd")
const PlayLink = preload("res://client/play_link.gd")
const LocalRoom = preload("res://net/local_room.gd")
const Session = preload("res://net/session.gd")
const Client = preload("res://net/client.gd")
const Move = preload("res://sim/move.gd")
const Places = preload("res://sim/places.gd")

static func _packs(file: String) -> String:
	var dir := OS.get_environment("GD_PACKS_DIR")
	if dir.is_empty() or not FileAccess.file_exists(dir.path_join(file)):
		return ""
	return dir

## A solo room with the game's deck, on the Ward at floor 6, the player standing where the Ward put them (its lift).
static func _ward_room() -> LocalRoom:
	var room := LocalRoom.new()
	room.open_local("fl2-ward", "Tester", true)
	# This file checks FL1's scene swap: the Ward as a normal level (WN1, net/host_rules.gd ward_place) off.
	room.ward_place = false
	room.reactor_place = false   # and the Reactor as a place (RN1) off: this file checks the old hand-over
	room.late_archive_root = ""
	room.start_playtest(6)
	for i in 6:
		room.poll(0.05 * i)
	return room

static func _main_for(room: Variant, packs: String) -> Main:
	var main := Main.new()
	main.hud = Hud.new()
	main.pack_dir = packs
	main.link = PlayLink.new(room, true)
	return main

static func _drop(main: Main) -> void:
	if is_instance_valid(main):
		if is_instance_valid(main.hud):
			main.hud.free()
		main.free()

## Brings the Ward's lift back at once and runs the room's clock quickly.
static func _hurry_ward(room: LocalRoom) -> void:
	var ward: Variant = room.host._ward_review
	ward.phase = &"away"
	ward.collection_at = room.host.state.t + 0.5
	room.time_scale = 60.0

func test_ward_departure_hands_on_to_the_reactor(t: T) -> void:
	var original := Session.deck
	Session.deck = Places.FULL
	var room := _ward_room()
	t.check(room.rules.cycles and room.host._ward_review != null and room.host.state.depth == 6, "a solo floor 6 with cycles has the Ward")
	t.eq(Main.floor_handover(room.client.latest), "ward", "the main game would show the Ward")
	# Where the Ward placed the player (in its lift): the host's accepted body, not yet the run's.
	var body: Move.Body = room.host._players[LocalRoom.ME].body
	t.check(room.host._ward_review.in_lift(Vector3(body.x, body.y, body.z)), "the player stands in the Ward's lift")
	_hurry_ward(room)
	var now := 0.3
	var at_seven := false
	var due_at_six := false
	for step in 4000:
		now += 0.016
		room.poll(now)
		var local := Client.LocalFrame.new()
		local.body = Move.Body.make(body.x, body.z, 0, body.y)
		room.frame(now, local)
		var latest: Variant = room.client.latest
		if latest != null and int(latest.depth) == 6 and Review.handback_due(latest):
			due_at_six = true
		if latest != null and int(latest.depth) == 7:
			at_seven = true
			break
		if room.host.state.depth == 0:
			break
	t.check(at_seven, "the Ward's lift took the player down to floor 7 (host depth %d)" % room.host.state.depth)
	t.check(not due_at_six, "the Ward's screen never hands back while still on floor 6")
	var latest: Dictionary = room.client.latest
	t.check(latest.has("reactor") and not latest.has("ward"), "floor 7 has the Reactor block and no Ward block")
	t.check(Review.handback_due(latest), "the Ward's screen hands the room back")
	t.eq(Main.floor_handover(latest), "reactor", "and the main game it hands to goes on to the Reactor")
	room.leave()
	Session.deck = original

func test_handback_rules(t: T) -> void:
	t.check(Review.handback_due({"depth": 7, "reactor": {"lift": false}}), "on the Reactor's floor with the Ward gone")
	t.check(not Review.handback_due({"depth": 7}), "not on another floor without a Reactor")
	t.check(not Review.handback_due({"depth": 6, "ward": {"phase": "departed"}, "reactor": {"lift": false}}), "never while the Ward's block is sent")
	t.check(Review.handback_due({"depth": 0}), "home, as before")

func test_ward_scene_then_reactor_scene_with_the_same_room(t: T) -> void:
	var ward_packs := _packs("WardGroundMedia.pck")
	var reactor_packs := _packs("ReactorCampaign.pck")
	if ward_packs.is_empty() or reactor_packs.is_empty():
		t.note("skipped: pack not found (set GD_PACKS_DIR to the folder holding WardGroundMedia.pck and ReactorCampaign.pck)")
		return
	var original := Session.deck
	Session.deck = Places.FULL
	var tree := Engine.get_main_loop() as SceneTree
	var before := tree.current_scene
	var room := _ward_room()
	var main := _main_for(room, ward_packs)
	main._enter_floor("ward", room)
	var scene := tree.current_scene
	if not t.check(scene != before and scene != null and scene.scene_file_path == "res://client/ward/review.tscn", "the Ward's scene is on screen"):
		_drop(main)
		room.leave()
		Session.deck = original
		return
	for i in 4:
		scene._process(0.016)
	t.check(scene.get("view") != null, "the Ward is drawn")
	_hurry_ward(room)
	var due := false
	var steps := 0
	while steps < 6000:
		steps += 1
		scene._process(0.016)
		if not scene.is_processing():
			due = Review.handback_due(room.client.latest)
			break
		OS.delay_usec(2000)
	t.note("ward hand-on after %d frames, host time %.1f s" % [steps, room.host.state.t])
	t.check(due and int(room.client.latest.depth) == 7, "the Ward's scene hands back on floor 7 (depth %d)" % int(room.client.latest.depth))
	t.eq(Main.floor_handover(room.client.latest), "reactor", "with the Reactor's block")
	var handed := Review.prison_for(room)
	t.check(handed.get("ward_room") == room, "the main game gets the same room")
	handed.free()
	# Free the Ward scene now (its queued hand-back must not run after this test), then the main game's swap.
	tree.current_scene = before
	scene.set("room", null)
	scene.get_parent().remove_child(scene)
	scene.free()
	_drop(main)
	room.time_scale = 1.0
	var next := _main_for(room, reactor_packs)
	t.check(next._mount_floor_pack("reactor"), "the Reactor pack mounts")
	var printing := Engine.print_error_messages
	Engine.print_error_messages = false
	var held: Array[Resource] = [load("res://reactor_campaign.tscn"), load("res://crew23_motion.glb")]
	Engine.print_error_messages = printing
	t.check(held.all(func(r: Resource) -> bool: return r != null), "the pack's scene loads")
	next._enter_floor("reactor", room)
	var reactor := tree.current_scene
	if t.check(reactor != before and reactor != null and reactor.scene_file_path == "res://reactor_campaign.tscn", "the Reactor's scene is on screen"):
		t.check(reactor.get("game") == room, "playing the same room the Ward played")
		for i in 20:
			reactor._physics_process(1.0 / 60.0)
			OS.delay_usec(2000)
		var frame: Variant = reactor.get("frame")
		t.check(frame is Dictionary and frame.has("power"), "drawing the room's Reactor block")
		var screen_node: Variant = reactor.get("screen")
		tree.current_scene = before
		reactor.set("game", null)
		reactor.get_parent().remove_child(reactor)
		reactor.free()
		if is_instance_valid(screen_node):
			(screen_node as Node).free()
	_drop(next)
	room.leave()
	Session.deck = original
