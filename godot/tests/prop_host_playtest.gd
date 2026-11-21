extends RefCounted

const T = preload("res://tests/t.gd")
const LocalRoom = preload("res://net/local_room.gd")
const Places = preload("res://sim/places.gd")
const Run = preload("res://sim/run.gd")
const Session = preload("res://net/session.gd")

func test_start_and_restart(t: T) -> void:
	var original_deck := Session.deck
	Session.deck = Places.FULL
	var room := LocalRoom.new()
	room.open_local("host-playtest", "Tester", true)
	t.check(not room.start_playtest(-1), "reject an unavailable destination")
	t.check(not room.run_on, "invalid selection must not start a run")
	var destinations := LocalRoom.playtest_destinations(room.seed, Session.deck)
	var depths: Array[int] = []
	var seen: Array[StringName] = []
	for destination in destinations:
		var depth := int(destination["depth"])
		var place := StringName(destination["place"])
		depths.append(depth)
		seen.append(place)
		t.check(room.start_playtest(depth), "start a local run at depth %d" % depth)
		var state := room.host.state
		t.eq(state.depth, depth, "host is on selected depth")
		if place == &"ward" or place == &"reactor":
			# The late floors (FL1): an overlay on that depth's own plan, running before the first tick.
			t.check(room.host.world().has(String(place)), "host runs the %s on floor %d" % [place, depth])
		else:
			t.eq(state.plan.place, place, "host generated selected area")
		t.check(state.days and state.day_state != null, "real day rules stay enabled")
		t.check(Run.in_car(state.car, state.players[0].body), "player starts inside the lift")
		if depth == 0:
			t.check(Run.at_home(state) and state.bed != null, "prison has real bedtime state")
		else:
			t.eq(state.floor_needed, Run.floor_quota(depth, 1, state.tuning, Run.pressure_quota_mult(state, state.tuning), state.economy_fix), "quota computed for selected floor (with floor 8 onward's pressure, DF1, and PY1's cycle rule when the room has it)")
		t.eq(room.run_seed, room.seed, "switching and restarting reproduce the run seed")
		state.floor_earned = 5.0
		t.check(room.start_playtest(depth), "restart selected depth")
		t.eq(room.host.state.floor_earned, 0.0, "restart clears prior playtest progress")
		t.eq(room.host.state.seed, state.seed, "restart keeps the selected floor seed")
	t.eq(depths.slice(0, Places.FIXED.size()), range(Places.FIXED.size()), "all fixed floors listed")
	for place in Session.deck:
		t.check(seen.has(place), "deck includes a jump to %s" % place)
	room.leave()

	var normal := LocalRoom.new()
	normal.open_local("ordinary-solo", "Tester", true)
	normal.start_run()
	t.eq(normal.host.state.depth, 1, "ordinary solo still starts at floor one")
	normal.start_run()
	t.eq(normal.run_seed, "ordinary-solo-1", "ordinary restarts still use the run counter")
	normal.leave()
	Session.deck = original_deck
