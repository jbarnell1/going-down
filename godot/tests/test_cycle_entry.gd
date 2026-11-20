# FL2 (cycles): the Hanging Ward's lift rides down, so its screen hands the room on to the Reactor's instead of the
# prison (client/ward/review.gd handback_due; client/main.gd floor_handover, _enter_floor).
#   - Always: alone with the game's deck (cycles on), the Ward at floor 6 departs with the player aboard, the room
#     arrives at floor 7 with a Reactor block and no Ward block, the Ward's screen is due to hand back, and the main
#     game it hands to picks the Reactor's scene.
#   - The same through the real scenes: the Ward's scene (on the game's own files, IP1) on screen first; the
#     Reactor's old compiled room is not in the game, so the main game it hands to keeps the same room and says so.
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

static func _main_for(room: Variant) -> Main:
	var main := Main.new()
	main.hud = Hud.new()
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

func test_ward_scene_then_the_same_room_on_the_reactor(t: T) -> void:
	var original := Session.deck
	Session.deck = Places.FULL
	var tree := Engine.get_main_loop() as SceneTree
	var before := tree.current_scene
	var room := _ward_room()
	var main := _main_for(room)
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
	# IP1: the Reactor's old compiled room is not in the game. The main game the Ward hands to keeps the same room
	# and says so, instead of a blank screen.
	var next := _main_for(room)
	var link := next.link
	next._enter_floor("reactor", room)
	t.check(tree.current_scene == before, "no swap to a Reactor scene that is not in the game")
	t.check(next.link == link and room.status != "closed", "the main game keeps playing the same room the Ward played")
	t.check(next.hud.note.contains("not in this build"), "with a plain line: " + next.hud.note)
	_drop(next)
	room.leave()
	Session.deck = original
