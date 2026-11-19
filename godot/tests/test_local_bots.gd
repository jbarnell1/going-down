extends RefCounted

const T = preload("res://tests/t.gd")
const Client = preload("res://net/client.gd")
const Host = preload("res://net/host.gd")
const LocalRoom = preload("res://net/local_room.gd")
const Move = preload("res://sim/move.gd")
const Places = preload("res://sim/places.gd")
const Run = preload("res://sim/run.gd")
const Session = preload("res://net/session.gd")

func test_local_crew_is_opt_in(t: T) -> void:
	var room := LocalRoom.new()
	room.open_local("bots-b", "Player", true)
	room.set_ready(true)
	t.eq(room.host.state.players.size(), 1, "the default local game has just the human")
	t.eq(room.people.size(), 1, "the default Ready-up roster has just the human")
	room.leave()
	room = LocalRoom.new()
	room.open_local("bots-b", "Player", true, "", 3)
	t.eq(room.people.size(), 4, "the opt-in Ready-up roster has a full crew")
	room.set_ready(true)
	room.poll(0.05)
	t.eq(room.host.state.players.size(), 4, "the host gives all three companions a real seat")
	t.check(room._crew_bots.all(func(bot: RefCounted) -> bool: return bot.peer != null),
		"every companion has its own in-process client")
	room.leave()
	t.check(room.host == null and room._crew_bots.is_empty(), "leaving closes the local crew")

func test_local_companions_walk_and_take_a_real_reading(t: T) -> void:
	var old_deck := Session.deck
	Session.deck = Places.FULL
	var room := LocalRoom.new()
	room.open_local("bots-b", "Player", true, "", 3)
	room.days = true
	room.quota = false
	room.set_ready(true)
	var local: Move.Body = room.host.state.players[0].body
	var walking := false
	var closed := false
	var seen_events := 0
	for tick in 1260:
		var now := tick * Session.TICK
		room.poll(now)
		var state := room.host.state
		var input := Client.LocalFrame.new()
		if state.phase == &"unloading" and Run.in_car(state.car, local):
			var spot := Run.car_local(state.car, local.x, local.z)
			var target := Run.car_body(state.car, 0.33 if spot[0] > 0.43 else -0.8, 0.0)
			var direction := Vector2(target.x - local.x, target.z - local.z).limit_length(0.16)
			local = Run.move_in_run(state, local, direction.x, direction.y, 0.30)
		input.body = local
		var frame := room.frame(now, input)
		if frame != null and frame.placed != null:
			local = frame.placed
		walking = walking or (state.phase == &"away" and state.players.slice(1).all(
			func(player: Run.RunPlayer) -> bool: return not player.aboard))
		for event: Host.LoggedEvent in room.host.event_log.slice(seen_events):
			if event.e.get("type") == "readingClosed" and str(event.e["playerId"]).begins_with("bot-") and float(event.e["value"]) > 0.0:
				closed = true
		seen_events = room.host.event_log.size()
		if walking and closed:
			break
	t.check(walking, "all three bot bodies walk out of the real lift")
	t.check(closed, "the ordinary host credits a reading taken by a bot with its own instrument")
	room.leave()
	Session.deck = old_deck
