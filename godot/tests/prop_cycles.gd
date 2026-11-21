# Cycles (FL2; net/host_rules.gd cycles, sim/places.gd "Cycles", sim/run.gd "Cycles"; docs/floors/difficulty.md
# section 1, the owner's words of 19 Nov):
#   - the flag is the last parameter, after the three other branches' flags, off by default, and only with the late
#     floors; with it off, a seeded run through floors 5, 6 (the Ward and its ride home, the next morning) and 7 (the
#     Reactor and its ride home) is, tick for tick and event for event, what commit 1013e52 did (BASE_DIGEST was
#     recorded by running tests/cycles_rig.gd flag_off_digest on that commit's sources);
#   - with the flag off, place_at is the old function at every depth for every deck;
#   - with it on, floors 8 to 14 repeat 1 to 7 (the places), with their own layouts; the Ward and the Reactor start
#     at 13 and 14;
#   - the Ward's lift rides down to the Reactor with the crew's tapes, a player left behind stays out for the day;
#   - the Reactor's return banks and settles the day, pays the crew aboard, and finishes the cycle;
#   - the next morning starts at floor 8; a day that ends before the Reactor leaves the next at floor 1; a game over
#     goes back to floor 1;
#   - the snapshot's "cycle" (from cycle 2), the solo picker's floor 8, and two clients over the real server.
# The server test listens on 127.0.0.1, on its own port of this process's test block (tests/test_ports.gd).
# Run alone: npm run godot:test -- prop_cycles
extends RefCounted

const T = preload("res://tests/t.gd")
const Rig = preload("res://tests/cycles_rig.gd")
const Host = preload("res://net/host.gd")
const HostRules = preload("res://net/host_rules.gd")
const Client = preload("res://net/client.gd")
const Protocol = preload("res://net/protocol.gd")
const Session = preload("res://net/session.gd")
const LocalRoom = preload("res://net/local_room.gd")
const Room = preload("res://server/room.gd")
const RoomClient = preload("res://net/room_client.gd")
const WsServer = preload("res://net/ws_server.gd")
const Review = preload("res://client/ward/review.gd")
const Places = preload("res://sim/places.gd")
const Run = preload("res://sim/run.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Rng = preload("res://sim/rng.gd")
const Day = preload("res://sim/day.gd")
const TapeLib = preload("res://sim/tape.gd")
const Instr = preload("res://sim/instrument.gd")
const Upgrades = preload("res://sim/upgrades.gd")

## tests/cycles_rig.gd flag_off_digest() on commit 1013e52 (ticks of the Ward run / of the Reactor run, then the hash).
const BASE_DIGEST := "796/139 ed169093d8e0423d465dec3212529edcd7f8cad2fb9b0cd39f7e5bae81d6248a"
const SECRET := "cycles-test-passphrase"
const TestPorts = preload("res://tests/test_ports.gd")
static var PORT: int = TestPorts.port(TestPorts.CYCLES)

## HostRules with the named parameters on (by name, so the test does not count positions).
static func rules_with(depth: int, on: Array[String]) -> HostRules:
	var init: Dictionary = {}
	for m: Dictionary in (HostRules as Script).get_script_method_list():
		if m["name"] == "_init":
			init = m
	var args: Array = []
	for a: Dictionary in init["args"]:
		var name := str(a["name"])
		if name == "entity_on":
			args.append(true)
		elif name == "depth":
			args.append(depth)
		elif name == "deck_":
			args.append(Places.FULL)
		else:
			args.append(on.has(name))
	return Callable(HostRules, "new").callv(args)

static func cycle_rules(depth: int, extra: Array[String] = []) -> HostRules:
	var on: Array[String] = ["days_", "late_floors_", "cycles_", "car_waits_"]
	on.append_array(extra)
	return rules_with(depth, on)

static func types(events: Array) -> Array[String]:
	var out: Array[String] = []
	for e: Variant in events:
		out.append(str((e as Dictionary).get("type", "")))
	return out

static func logged(host: Host, from := 0) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in range(from, host.event_log.size()):
		out.append(JSON.parse_string(host.event_log[i].text))
	return out

## Puts a reading worth `value` on player `id`'s own tape.
static func give_reading(host: Host, id: String, value: float) -> void:
	var s := host.state.copy()
	var c := s.crew.copy()
	c.members = []
	for m in host.state.crew.members:
		var nm := m.copy()
		if m.id == id:
			var r := TapeLib.Reading.new()
			r.id = "fl2-%s" % id
			r.player_id = id
			r.entity_id = "test-1"
			r.trait_name = &"stillness"
			r.value = value
			r.duration = 1.0
			nm.tape = TapeLib.add_reading(m.tape, r)
		c.members.append(nm)
	s.crew = c
	host.state = s

## The place function as it was at 1013e52 (sim/places.gd place_at), copied here to prove the flag-off path.
static func old_place_at(seed: String, depth: int, deck: Array) -> StringName:
	if depth <= 0:
		return Places.PRISON
	var d: Array[StringName] = []
	for p: Variant in deck:
		var sp := StringName(p)
		if sp != Places.PRISON and not d.has(sp):
			d.append(sp)
	if d.is_empty():
		d.append(Places.CLINIC)
	var prev := Places.PRISON
	var here := Places.CLINIC
	for k in range(1, depth + 1):
		if k < Places.FIXED.size() and d.has(Places.FIXED[k]):
			here = Places.FIXED[k]
		else:
			var choices: Array = []
			for p in d:
				if p != prev:
					choices.append(p)
			if choices.is_empty():
				choices = d.duplicate()
			here = Rng.make_rng("place:%s:%d" % [seed, k]).pick(choices)
		prev = here
	return here

# ---- the parameter and flag off ---------------------------------------------------------------------------

func test_the_flag_is_last_off_by_default_and_needs_the_late_floors(t: T) -> void:
	var init: Dictionary = {}
	for m: Dictionary in (HostRules as Script).get_script_method_list():
		if m["name"] == "_init":
			init = m
	var names: Array[String] = []
	for a: Dictionary in init["args"]:
		names.append(str(a["name"]))
	# RN1 added ward_place_ and reactor_place_ after cycles_, in the order agreed for the three workers.
	# DF1 added pressures_ after reactor_place_.
	t.eq(names.slice(names.size() - 19), ["late_floors_", "party_table_", "tenant_timer_", "second_orderly_", "cycles_", "ward_place_", "reactor_place_", "pressures_", "ward_call_", "ward_web_", "rigger_roam_", "ward_layout_", "orderly_fix_", "minder_calm_", "down_ring_", "pn_fixes_", "last_stand_", "deal_", "split_"] as Array[String], "the last nineteen parameters, in the agreed order (WC1 added ward_call_ and ward_web_, RR1 rigger_roam_, WG1 ward_layout_, OR2 orderly_fix_, MA1 minder_calm_, down_ring_ and pn_fixes_, LS1 last_stand_, ED1 deal_, SR1 split_)")
	var plain := HostRules.new(true, 1, Places.FULL, true)
	t.check(not plain.cycles and not plain.party_table and not plain.tenant_timer and not plain.second_orderly, "all off by default")
	t.eq(plain.deck, Places.FULL, "the deck without the flag is the deck given")
	t.check(not rules_with(1, ["cycles_"] as Array[String]).cycles, "cycles without the late floors stays off")
	var on := cycle_rules(1)
	t.check(on.cycles and Places.cycles_in(on.deck), "with the late floors it is on and the deck carries the marker")
	var stored := rules_with(1, ["party_table_", "tenant_timer_", "second_orderly_"] as Array[String])
	t.check(stored.party_table and stored.tenant_timer and stored.second_orderly and not stored.cycles, "the other branches' flags are stored as given")

func test_flag_off_is_tick_for_tick_the_base_commit(t: T) -> void:
	t.eq(Rig.flag_off_digest(), BASE_DIGEST, "a seeded run through floors 5, 6 and 7 and home, as 1013e52 ran it")

func test_flag_off_digest_run_reaches_every_floor(t: T) -> void:
	# The digest above only means something if its runs did go where they say.
	var a := Rig.Crew.new("cycles-off-ward", HostRules.new(true, 5, Places.FULL, true), ["one", "two"] as Array[String], true)
	a.tick_for(1.0)
	Rig.ride_down(a.host)
	a.tick_for(0.5)
	t.check(a.host.state.depth == 6 and a.host._ward_review != null, "the Ward started at floor 6")
	Rig.ward_round(a)
	t.check(a.tick_for(15.0, func() -> bool: return a.host.state.depth == 0), "the Ward rode home (flag off)")
	t.check(types(logged(a.host)).has("dayEnded"), "and the day was settled")
	a.to_bed()
	t.check(a.tick_for(90.0, func() -> bool: return a.host.state.depth >= 1) and a.host.state.depth == 1, "the morning is floor 1")

func test_flag_off_place_at_is_the_old_function(t: T) -> void:
	var bad := 0
	for i in 12:
		var seed := "cyc-place-%d" % i
		for deck: Array in [Places.FULL, Places.BEFORE_ARBORETUM, Places.CLINIC_ONLY]:
			for depth in range(0, 31):
				if Places.place_at(seed, depth, deck) != old_place_at(seed, depth, deck) or Places.local_depth(depth, deck) != depth:
					bad += 1
	t.eq(bad, 0, "decks without the marker: the same place as before at every depth 0 to 30")
	t.eq(Floor.hash_plan(Places.generate("cyc-gen", 9, Places.FULL)), Floor.hash_plan(Places.generate("cyc-gen", 9, Places.FULL)), "generation unchanged in shape (same plan twice)")
	t.eq(Places.generate("cyc-gen", 9, Places.FULL).place, old_place_at("cyc-gen", 9, Places.FULL), "and depth 9 without the marker is still the seeded draw")

# ---- the shape of a descent -------------------------------------------------------------------------------

func test_floors_repeat_in_sevens_with_their_own_layouts(t: T) -> void:
	var deck := Places.with_cycles(Places.FULL)
	t.eq(deck.size(), Places.FULL.size() + 1, "the marker is one more entry")
	t.eq(Places.with_cycles(deck), deck, "and only once")
	var want := {8: &"clinic", 9: &"clinic", 10: &"annex", 11: &"playroom", 12: &"arboretum"}
	for i in 6:
		var seed := "cyc-%d" % i
		for depth in range(1, 8):
			t.eq(Places.place_at(seed, depth, deck), Places.place_at(seed, depth, Places.FULL), "%s floor %d: cycle one is as without the marker" % [seed, depth])
		for depth in range(8, 22):
			var local := 1 + (depth - 1) % 7
			t.eq(Places.local_depth(depth, deck), local, "floor %d repeats floor %d" % [depth, local])
			t.eq(Places.place_at(seed, depth, deck), Places.place_at(seed, local, deck), "%s floor %d is floor %d's place" % [seed, depth, local])
			if want.has(depth):
				t.eq(Places.place_at(seed, depth, deck), want[depth], "%s floor %d is the %s" % [seed, depth, want[depth]])
		var one := Places.generate(seed, 1, deck)
		var eight := Places.generate(seed, 8, deck)
		t.check(eight.place == Places.CLINIC and eight.depth == 8, "%s floor 8 is a Clinic generated at depth 8" % seed)
		t.check(Floor.hash_plan(one) != Floor.hash_plan(eight), "%s floor 8 is a different Clinic from floor 1" % seed)
		t.eq(Floor.hash_plan(Places.generate(seed, 8, deck)), Floor.hash_plan(eight), "%s and the same one every time" % seed)
	for d: int in [1, 7, 8, 14, 15, 21, 22]:
		t.eq(Places.cycle_of(d), 1 + (d - 1) / 7, "floor %d is in cycle %d" % [d, 1 + (d - 1) / 7])
	t.eq([Places.cycle_start(0), Places.cycle_start(1), Places.cycle_start(2)], [1, 8, 15], "cycles start at 1, 8, 15")

func test_ward_and_reactor_start_at_13_and_14(t: T) -> void:
	for depth: int in [13, 14]:
		var crew := Rig.Crew.new("cyc-late-%d" % depth, cycle_rules(depth), ["one"] as Array[String], true)
		crew.tick_for(0.3)
		var w := crew.host.world()
		t.eq(int(w["depth"]), depth, "the run is on floor %d" % depth)
		t.eq(w.has("ward"), depth == 13, "floor %d has the Ward block: %s" % [depth, w.has("ward")])
		t.eq(w.has("reactor"), depth == 14, "floor %d has the Reactor block: %s" % [depth, w.has("reactor")])
		t.eq(int(w.get("cycle", 1)), 2, "the snapshot says cycle 2")
		t.eq(crew.host.state.cycles_done, 1, "a run made to start in cycle 2 counts cycle 1 as done")

# ---- the Ward's lift goes down, the Reactor ends the cycle ---------------------------------------------------

func test_ward_rides_down_and_the_reactor_settles_the_day(t: T) -> void:
	var crew := Rig.Crew.new("cyc-down-1", cycle_rules(6), ["one", "two", "three"] as Array[String], true)
	crew.tick_for(0.3)
	t.check(crew.host._ward_review != null and crew.host.state.depth == 6, "the Ward at floor 6")
	t.check(not crew.host.world().has("cycle"), "cycle 1 sends no cycle field")
	give_reading(crew.host, "one", 1500.0)
	give_reading(crew.host, "two", 700.0)
	give_reading(crew.host, "three", 400.0)
	var day := crew.host.state.day_index
	var from := crew.host.event_log.size()
	Rig.ward_round(crew, [2] as Array[int])
	var gone := crew.tick_for(10.0, func() -> bool: return crew.host.state.phase == &"riding")
	t.check(gone and crew.host.state.depth == 6 and not crew.host.state.going_up, "the Ward's lift leaves downward")
	var ward: Variant = crew.host._ward_review
	t.check(ward != null and ward.boarded.has("one") and ward.boarded.has("two") and not ward.boarded.has("three"), "one and two aboard, three not: %s" % str(ward.boarded if ward != null else []))
	var down := crew.tick_for(20.0, func() -> bool: return crew.host.state.depth == 7)
	t.check(down, "the crew rode down to floor 7")
	var w := crew.host.world()
	t.check(w.has("reactor") and not w.has("ward"), "the Reactor block from the arrival tick, the Ward's gone")
	var ev := logged(crew.host, from)
	var ty := types(ev)
	t.check(not ty.has("banked") and not ty.has("dayEnded") and not ty.has("rodeUp") and not ty.has("ward_tapes_lost"), "nothing banked or settled at the Ward: %s" % str(ty))
	t.eq(crew.host.state.day_index, day, "the same day")
	t.check(ty.has("rodeDown") and ty.has("carLeft"), "an ordinary ride down")
	t.eq(TapeLib.tape_value([Instr.member(crew.host.state.crew, "one").tape] as Array[TapeLib.Tape]), 1500.0, "one's tape rode down intact")
	t.eq(TapeLib.tape_value([Instr.member(crew.host.state.crew, "two").tape] as Array[TapeLib.Tape]), 700.0, "two's tape too")
	t.eq(Instr.member(crew.host.state.crew, "three").tape.readings.size(), 0, "three's tape stayed behind")
	var left: Array[String] = []
	for e in ev:
		if e["type"] == "leftBehind":
			left.append(str(e["playerId"]))
	t.eq(left, ["three"] as Array[String], "three was left behind, with the tape's loss reported")
	var three: Run.RunPlayer = null
	for p in crew.host.state.players:
		if p.id == "three":
			three = p
	t.check(three != null and three.status in [&"leftBehind", &"caught"] and crew.host.state.left_out.has("three"), "and is out of the run for the day (%s)" % (three.status if three != null else "?"))
	t.check(crew.host._reactor_review.seats.has("one") and crew.host._reactor_review.seats.has("two") and not crew.host._reactor_review.seats.has("three"), "the Reactor seats only the crew that rode down")
	# The clients' snapshots arrive a moment later.
	for c in crew.clients:
		crew.tick_for(0.5, func() -> bool: return c.latest != null and int(c.latest.depth) == 7)
		t.check(c.latest != null and c.latest.has("reactor") and not c.latest.has("ward") and int(c.latest.depth) == 7, "%s is on floor 7 with the Reactor" % c.id)
		t.check(Review.handback_due(c.latest), "%s's Ward screen hands the room on at floor 7" % c.id)
	# The Reactor: done and the lift up. The day is settled as a BANK settles it.
	var before := crew.host.event_log.size()
	Rig.reactor_round(crew)
	var home := crew.tick_for(3.0, func() -> bool: return crew.host.state.depth == 0)
	t.check(home, "the crew is home")
	ev = logged(crew.host, before)
	ty = types(ev)
	t.check(ty.has("banked") and ty.has("dayEnded") and ty.has("rodeUp"), "banked, the day ended, home: %s" % str(ty))
	var result: Dictionary = {}
	for e in ev:
		if e["type"] == "dayEnded":
			result = e["result"]
	var quota := Day.quota_for(0, 3, Run.DAY_FLOOR_QUOTA)
	t.eq(int(result.get("banked", -1)), 2200, "what rode up from the Reactor is banked (one's and two's tapes)")
	t.eq(int(result.get("quota", -1)), quota, "against the day quota of the morning's crew of three")
	t.eq(str(result.get("kind", "")), "made", "2200 of %d: a made day" % quota)
	t.eq(result.get("shares", {}), {"one": 1100.0, "two": 1100.0}, "paid to the two who rode; the one left behind is not in today's crew")
	t.eq((crew.host.state.wallets["one"] as Upgrades.UpgradeState).credits, 1100, "into their wallets")
	var three_wallet: Variant = crew.host.state.wallets.get("three")
	t.check(three_wallet == null or (three_wallet as Upgrades.UpgradeState).credits == 0, "and nothing to three")
	t.eq(crew.host.state.cycles_done, 1, "the campaign has finished cycle 1")
	t.eq(int(crew.host.world().get("cycle", 1)), 2, "the prison's snapshot says the next descent is cycle 2")
	# Bed: the next day starts at floor 8, the Clinic again, its own.
	crew.to_bed()
	var morning := crew.tick_for(90.0, func() -> bool: return crew.host.state.day_index == day + 1 and crew.host.state.depth >= 1)
	t.check(morning, "the next morning came")
	t.eq(crew.host.state.depth, 8, "and starts at floor 8")
	t.eq(crew.host.state.plan.place, Places.CLINIC, "a Clinic")
	t.check(Floor.hash_plan(crew.host.state.plan) != Floor.hash_plan(Places.generate(crew.host.state.seed, 1, crew.host.state.deck)), "not floor 1's Clinic of the same day")
	t.eq(int(crew.host.world().get("cycle", 1)), 2, "cycle 2")
	crew.tick_for(0.5)
	for c in crew.clients:
		t.eq(Floor.hash_plan(Session.plan_for(str(c.seed), int(c.latest.depth), crew.rules.deck)), Floor.hash_plan(crew.host.state.plan), "%s's seed and the run's deck give the host's floor 8" % c.id)

func test_an_unfinished_descent_starts_the_next_day_at_floor_1(t: T) -> void:
	var crew := Rig.Crew.new("cyc-short-1", cycle_rules(3), ["one", "two"] as Array[String], true)
	crew.tick_for(0.3)
	# BANK at floor 3: the car rides up with both.
	var s := crew.host.state.copy()
	var events: Array[Dictionary] = []
	var players: Array[Run.RunPlayer] = s.players.duplicate()
	Run._bank(s, players, ["one", "two"] as Array[String], s.t, events)
	crew.host.state = s
	t.check(crew.tick_for(30.0, func() -> bool: return crew.host.state.depth == 0), "home from floor 3")
	t.eq(crew.host.state.cycles_done, 0, "no cycle finished")
	crew.to_bed()
	t.check(crew.tick_for(90.0, func() -> bool: return crew.host.state.depth >= 1), "the next morning")
	t.eq(crew.host.state.depth, 1, "starts at floor 1 until the Reactor is done")

func test_mornings_after_a_wipe_and_a_game_over(t: T) -> void:
	var rules := cycle_rules(8)
	var ids: Array[String] = ["one"]
	var base := rules.prepare(Run.create_run("cyc-morning", ids))
	t.eq(base.cycles_done, 1, "started in cycle 2")
	for kind: String in ["missed", "game_over", "made"]:
		var s := base.copy()
		var players: Array[Run.RunPlayer] = s.players.duplicate()
		s.day_result = {"kind": kind}
		var events: Array[Dictionary] = []
		Run._morning(s, players, s.t, events)
		var want := 1 if kind == "game_over" else 8
		t.eq(s.depth, want, "after a %s day the morning is floor %d" % [kind, want])
		t.eq(int(events[-1]["depth"]), want, "and the newDay event says so")
		t.eq(s.cycles_done, 0 if kind == "game_over" else 1, "cycles done after a %s day" % kind)
	# Flag off: every morning is floor 1, whatever cycles_done says.
	var off := HostRules.new(true, 1, Places.FULL, true).prepare(Run.create_run("cyc-morning", ids))
	off.cycles_done = 3
	var off_players: Array[Run.RunPlayer] = off.players.duplicate()
	var off_events: Array[Dictionary] = []
	Run._morning(off, off_players, off.t, off_events)
	t.eq(off.depth, 1, "without the flag the morning is floor 1")

# ---- the wire, the picker, the server ------------------------------------------------------------------------

func test_cycle_field_round_trips_and_is_absent_in_cycle_one(t: T) -> void:
	var crew := Rig.Crew.new("cyc-wire-1", cycle_rules(9), ["one"] as Array[String], true)
	crew.tick_for(0.5)
	var w := crew.host.world()
	t.eq(int(w.get("cycle", 0)), 2, "floor 9 is cycle 2")
	t.eq(int(crew.clients[0].latest.get("cycle", 0)), 2, "the client decoded it")
	var one := Rig.Crew.new("cyc-wire-2", cycle_rules(2), ["one"] as Array[String], true)
	one.tick_for(0.5)
	t.check(not one.host.world().has("cycle") and not one.clients[0].latest.has("cycle"), "cycle 1: no field (the snapshot is as before)")
	t.check(Protocol.world_json(w).contains('"cycle":2'), "the field rides in the world's floor extensions")
	t.check(not Protocol.world_json(one.host.world()).contains('"cycle"'), "and not in cycle 1's")

func test_solo_picker_lists_floor_8_once(t: T) -> void:
	var original := Session.deck
	Session.deck = Places.FULL
	var room := LocalRoom.new()
	room.open_local("cyc-picker", "Tester", true)
	room.late_archive_root = ""
	var list := LocalRoom.playtest_destinations(room.seed, Session.deck)
	t.check(list.has({"depth": 8, "place": &"clinic"}), "the picker lists floor 8, the Clinic")
	t.check(not list.any(func(d: Dictionary) -> bool: return int(d["depth"]) > 8), "and nothing deeper")
	t.eq(list.filter(func(d: Dictionary) -> bool: return int(d["depth"]) == 8).size(), 1, "floor 8 once")
	t.check(room.start_playtest(8), "floor 8 starts")
	t.check(room.rules.cycles and Places.cycles_in(room.client.floor_deck), "with cycles, and the solo client draws with the same deck")
	t.check(room.host.state.depth == 8 and room.host.state.plan.place == Places.CLINIC and room.host.state.cycles_done == 1, "on floor 8, a Clinic, cycle 1 done")
	for i in 10: room.poll(i * 0.05)
	t.eq(int(room.client.latest.get("cycle", 0)), 2, "the solo client sees cycle 2")
	t.eq(Floor.hash_plan(Session.plan_for(str(room.client.seed), 8, room.client.floor_deck)), Floor.hash_plan(room.host.state.plan), "and draws the host's floor 8")
	room.leave()
	Session.deck = Places.CLINIC_ONLY
	t.check(not LocalRoom.playtest_destinations("x", Session.deck).any(func(d: Dictionary) -> bool: return int(d["depth"]) >= 6), "a Clinic-only picker lists no late floor and no floor 8")
	var solo := LocalRoom.new()
	solo.open_local("cyc-clinic", "Tester", true)
	solo.start_run()
	t.check(not solo.rules.cycles and not Places.cycles_in(solo.rules.deck), "a Clinic-only solo run has no cycles")
	solo.leave()
	Session.deck = original

class Net:
	var ws: WsServer
	var room: Room
	var now := 0.0
	var clients: Array = []

	func _init(port: int) -> void:
		var say := func(_l: String) -> void: pass
		ws = WsServer.new(SECRET, false, say)
		ws.listen(port, "127.0.0.1")
		room = Room.new(ws, say)
		room.fixed_seed = "cyc-net"
		room.quota = false

	func join(port: int, name: String) -> RoomClient:
		var rc := RoomClient.new()
		rc.connect_to("ws://127.0.0.1:%d" % port, SECRET, name)
		clients.append(rc)
		return rc

	func run(secs: float, until: Callable = Callable()) -> bool:
		var end := now + secs
		while now < end:
			now += 0.02
			ws.poll(now)
			room.update(now)
			for rc: RoomClient in clients:
				rc.poll(now)
				if rc.client != null and rc.status == "running":
					var lf := Client.LocalFrame.new()
					lf.body = Move.Body.make(0.0, 9.3, 0, 0.0)
					rc.frame(now, lf)
			if until.is_valid() and until.call():
				return true
			OS.delay_msec(2)
		return false

	func both_at(depth: int) -> bool:
		for rc: RoomClient in clients:
			if rc.client == null or rc.client.latest == null or int(rc.client.latest.depth) != depth:
				return false
		return true

	func stop() -> void:
		for rc: RoomClient in clients:
			if rc.status != "closed":
				rc.leave()
		run(0.2)
		ws.stop()

func test_server_room_two_clients_draw_the_same_cycle_two(t: T) -> void:
	var original := Session.deck
	Session.deck = Places.FULL
	var net := Net.new(PORT)
	t.check(net.room.cycles, "the server room's default is on")
	net.room.first_depth = 8
	var a := net.join(PORT, "Ana")
	var b := net.join(PORT, "Bo")
	t.check(net.run(5.0, func() -> bool: return a.status == "lobby" and b.status == "lobby"), "both in the lobby")
	a.set_ready(true)
	b.set_ready(true)
	t.check(net.run(12.0, func() -> bool: return net.room.host != null and net.both_at(8)), "both clients on floor 8")
	t.check(net.room.rules.cycles and Places.cycles_in(net.room.rules.deck), "the server's normal room has cycles")
	var host_hash := Floor.hash_plan(net.room.host.state.plan)
	for rc: RoomClient in [a, b]:
		t.check(Places.cycles_in(rc.client.floor_deck), "%s's client draws with the cycles deck" % rc.my_id)
		t.eq(Floor.hash_plan(Session.plan_for(str(rc.client.seed), 8, rc.client.floor_deck, rc.client.garden_dense)), host_hash, "%s draws the host's floor 8" % rc.my_id)
		t.eq(int(rc.client.latest.get("cycle", 0)), 2, "%s sees cycle 2" % rc.my_id)
	t.check(net.room._lobby_text(net.now).contains('"cycles":true'), "the lobby says so")
	# The next run starts on floor 13: the Ward of cycle 2 on both.
	net.room._end_run()
	net.room.first_depth = 13
	t.check(net.run(5.0, func() -> bool: return a.status == "lobby" and b.status == "lobby"), "back in the lobby")
	a.set_ready(true)
	b.set_ready(true)
	t.check(net.run(12.0, func() -> bool: return net.both_at(13) and a.client.latest.has("ward") and b.client.latest.has("ward")), "both clients see the Ward at floor 13")
	t.check(a.client.latest.ward.seed == b.client.latest.ward.seed, "the same seeded Ward on both")
	# cycles=0 turns it off.
	net.room._end_run()
	net.room.configure_campaign_trades({"cycles": "0"})
	t.check(not net.room.cycles, "cycles=0 turns it off")
	net.stop()
	Session.deck = original
