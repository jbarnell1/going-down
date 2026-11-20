# IV1 item 1: the Reactor's cassette in the prison after the native Reactor (RN1, the default). The prison's tape deck
# (client/reactor_station.gd) used to be added only by the old swapped-in Reactor scene (reactor_screening.gd
# _open_prison sets main's reactor_prison); a crew coming home from the generated Reactor found no deck. Checked here
# in the real game scene, headless: the sandbox's floor 7 is the native station; the player takes the tape off its
# table with F, the power is back (set on the host: the fuse walk is prop_station's), the car is called, the player
# rides up holding the tape; in the prison the deck is there, its prompt shows at the deck, E opens it, E plays it
# (the host's archive logs this player playing), and while it plays the announcer's chatter waits (item 7).
extends RefCounted

const T = preload("res://tests/t.gd")
const Game = preload("res://client/main.gd")
const GameScene = preload("res://main.tscn")
const LocalRoom = preload("res://net/local_room.gd")
const Session = preload("res://net/session.gd")
const Places = preload("res://sim/places.gd")
const Run = preload("res://sim/run.gd")
const Move = preload("res://sim/move.gd")
const SR = preload("res://sim/station_floor.gd")
const Review = preload("res://net/reactor_review.gd")

static func _key(code: Key, down: bool) -> void:
	var k := InputEventKey.new()
	k.pressed = down
	k.keycode = code
	k.physical_keycode = code
	Input.parse_input_event(k)
	Input.flush_buffered_events()

static func _press(game: Node, code: Key) -> void:
	_key(code, true)
	_frames(game, 4)
	_key(code, false)
	_frames(game, 4)

## The test drives the game's frame itself (nothing else steps the tree here): the game, then the deck (its own node).
static func _frames(game: Node, n: int) -> void:
	for i in n:
		game._process(1.0 / 60.0)
		var deck: Node = game.get_node_or_null("ReactorStation")
		if deck != null:
			deck._process(1.0 / 60.0)
		OS.delay_usec(16667)

## Frames until `ok` holds (at most `n`); whether it did.
static func _until(game: Node, n: int, ok: Callable) -> bool:
	for i in n:
		if ok.call():
			return true
		_frames(game, 1)
	return ok.call()

func test_the_tape_from_the_native_reactor_plays_in_the_prison(t: T) -> void:
	var original := Session.deck
	Session.deck = Places.FULL
	var tree := Engine.get_main_loop() as SceneTree
	var game := GameScene.instantiate() as Game
	game.automated = true
	tree.root.add_child(game)
	game.start.playtest_available = true
	_frames(game, 30)
	game._open_playtest()
	game.start.press("7")
	var lr := game.link.rc as LocalRoom
	var host: Variant = lr.host
	t.check(lr.rules.reactor_place and host._reactor_review == null, "the sandbox's floor 7 is the native Reactor (no old overlay)")
	_frames(game, 30)
	var sf: SR.StationFloor = host.state.station
	if not t.check(sf != null and host.state.plan.place == Places.REACTOR, "the station's rules run"):
		game.free()
		Session.deck = original
		return
	var depth: int = host.state.depth
	# The tape: F at its table.
	host._place(LocalRoom.ME, Move.Body.make(sf.tape.x, sf.tape.z, 0, 0.0), depth, host.state)
	_frames(game, 20)
	_press(game, KEY_F)
	var held := _until(game, 120, func() -> bool: return host.state.station.cassette_holder == LocalRoom.ME)
	t.check(held, "F at the table takes the tape")
	# The power back (prop_station walks the fuse), then the call from beside the doors.
	var st: SR.StationFloor = host.state.station
	st.power = SR.Power.RESTORED
	st.restored_at = host.state.t
	var car: Run.CarGeometry = host.state.car
	host._place(LocalRoom.ME, Run.car_body(car, -1.0, 0.0), depth, host.state)
	t.check(_until(game, 900, func() -> bool: return str(host.state.phase) == "away"), "the car leaves the crew (phase %s)" % host.state.phase)
	var called := false
	for k in 30:
		game._command("call")
		_frames(game, 10)
		if str(host.state.phase) != "away":
			called = true
			break
	t.check(called, "the car is called (phase %s, events %s)" % [host.state.phase, str(game.event_counts)])
	var seen := []
	var opened := _until(game, 900, func() -> bool:
		if seen.is_empty() or seen[-1] != str(host.state.phase):
			seen.append(str(host.state.phase))
		return str(host.state.phase) == "boarding")
	t.check(opened, "the car opens (phases %s)" % str(seen))
	lr.time_scale = 8.0
	host._place(LocalRoom.ME, Run.car_body(car, Run.CAR_DEPTH - 0.8, 0.0), depth, host.state)
	var home := _until(game, 3000, func() -> bool: return int(host.state.depth) == 0 and host.state.plan.place == Places.PRISON)
	lr.time_scale = 1.0
	if not t.check(home, "the car rides up to the prison with the player and the tape (depth %d, phase %s)" % [host.state.depth, host.state.phase]):
		game.free()
		Session.deck = original
		return
	t.check(bool(host.world().reactor.archive.recovered), "the host banked the tape in the archive")
	t.check(_until(game, 600, func() -> bool: return game.level != null and game.level.has_meta(&"prison")), "the prison is drawn")
	var deck: Node = game.get_node_or_null("ReactorStation")
	if not t.check(deck != null, "the prison's cassette deck is in the game after the native Reactor"):
		game.free()
		Session.deck = original
		return
	t.check(_until(game, 120, func() -> bool: return deck.hint.visible and deck.hint.text.begins_with("Recovered cassette")),
		"its line shows in the prison: \"%s\"" % deck.hint.text)
	t.check(is_instance_valid(deck.station) and deck.station.get_parent() == game.level, "the deck stands in the prison")
	var at := Review.STATION_POSITION
	host._place(LocalRoom.ME, Move.Body.make(at.x, at.z + 0.8, 0, 0.0), 0, host.state)
	t.check(_until(game, 240, func() -> bool: return deck.nearby), "at the deck the player is in reach")
	t.eq(deck.hint.text, "E  USE PRISON CASSETTE DECK", "the prompt at the deck")
	_press(game, KEY_E)
	t.check(deck.open, "E opens the deck")
	_press(game, KEY_E)
	var playing := _until(game, 120, func() -> bool: return int((host.world().reactor.archive.playing as Dictionary).get(LocalRoom.ME, 0)) != 0)
	t.check(playing, "E plays the tape: the host logs this player watching (%s)" % str(host.world().reactor.archive))
	if playing:
		t.check(_until(game, 60, func() -> bool: return deck.playing() and game.announcer.hold_chatter), "while it plays the announcer's chatter waits")
	game.free()
	Session.deck = original
