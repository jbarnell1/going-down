# The late floors in normal runs (FL1; net/host_rules.gd late_floors, net/host.gd enable_late_floors):
#   - flag off: a seeded run down to depths 6 and 7 has no Ward or Reactor block, and every tick of its world is
#     the same as a host made without the new parameters;
#   - flag on: arriving at HostRules.WARD_DEPTH starts the Hanging Ward on that very tick, and arriving at
#     HostRules.REACTOR_DEPTH starts the Reactor, both seeded from the day's floor seed and the same for two clients;
#   - the floor underneath is not stepped while an overlay runs (its resident stays the same object);
#   - the Ward ends the day at the prison and bed starts the next day's descent at floor 1;
#   - the Reactor's recovered tape is written to the normal room's archive folder and the crew is taken home;
#   - the solo floor picker lists and starts both floors; the dedicated server room starts both for two clients.
# The server test listens on 127.0.0.1, on its own port of this process's test block (tests/test_ports.gd).
# Run alone: npm run godot:test -- prop_late_floors
extends RefCounted

const T = preload("res://tests/t.gd")
const Host = preload("res://net/host.gd")
const HostRules = preload("res://net/host_rules.gd")
const Client = preload("res://net/client.gd")
const Transport = preload("res://net/transport.gd")
const Protocol = preload("res://net/protocol.gd")
const Session = preload("res://net/session.gd")
const LocalRoom = preload("res://net/local_room.gd")
const Room = preload("res://server/room.gd")
const RoomClient = preload("res://net/room_client.gd")
const WsServer = preload("res://net/ws_server.gd")
const Places = preload("res://sim/places.gd")
const Run = preload("res://sim/run.gd")
const Move = preload("res://sim/move.gd")
const ReactorState = preload("res://sim/reactor.gd")
const ReactorArchive = preload("res://sim/reactor_archive.gd")

const SECRET := "late-floors-test-passphrase"
const TestPorts = preload("res://tests/test_ports.gd")
static var PORT: int = TestPorts.port(TestPorts.LATE_FLOORS)

## The real host and two real clients over an in-memory link (as prop_ward_net). The test moves the bodies.
class Crew:
	var net: Transport.MemoryNetwork
	var host: Host
	var rules: HostRules
	var clients: Array[Client] = []
	var names: Array[String] = ["one", "two"]
	var bodies: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
	var held: Array[bool] = [false, false]
	var now := 0.0
	## Every snapshot depth a client drew without the floor's block ([client, depth]).
	var missing: Array = []

	func _init(seed: String, depth: int, late: bool, archive := "") -> void:
		net = Transport.MemoryNetwork.new(seed)
		rules = HostRules.new(true, depth, Places.FULL, true)
		host = Host.new(net.connect_peer("host"), seed, names, now, Callable(rules, "prepare"), Callable(rules, "step"), names)
		for id in names:
			clients.append(Client.new(net.connect_peer(id), "host", id, now))
		if late:
			host.enable_late_floors(archive)

	func tick_for(seconds: float, until: Callable = Callable()) -> bool:
		for frame in ceili(seconds / 0.025):
			now += 0.025
			net.now = now
			for i in clients.size():
				var c := clients[i]
				c.receive(now)
				var local := Client.LocalFrame.new()
				local.body = Move.Body.make(bodies[i].x, bodies[i].z, 0, bodies[i].y)
				local.use = held[i]
				c.frame(now, local)
				if c.latest != null:
					var d := int(c.latest.get("depth", -1))
					if (d == HostRules.WARD_DEPTH and not c.latest.has("ward")) or (d == HostRules.REACTOR_DEPTH and not c.latest.has("reactor")):
						missing.append([i, d])
			host.update(now)
			if until.is_valid() and until.call():
				return true
		return false

	func everyone_at(at: Vector3) -> void:
		for i in bodies.size():
			bodies[i] = at

## The car leaves for the floor below now (the real arrival code runs on the next tick).
static func ride_down(host: Host) -> void:
	var s := host.state.copy()
	s.phase = &"riding"
	s.going_up = false
	s.timer = 0.0
	host.state = s

# ---- the parameter --------------------------------------------------------------------------------

func test_the_flag_is_the_last_parameter_and_off_by_default(t: T) -> void:
	var init: Dictionary = {}
	for m: Dictionary in (HostRules as Script).get_script_method_list():
		if m["name"] == "_init":
			init = m
	var args: Array = init.get("args", [])
	t.check(args.size() >= 3, "HostRules._init has its parameters")
	var names: Array[String] = []
	for a: Dictionary in args:
		names.append(str(a["name"]))
	var at := names.find("late_floors_")
	# FL2 added the agreed four after it (party_table_, tenant_timer_, second_orderly_, cycles_: tests/prop_cycles.gd).
	# RN1 added ward_place_ and reactor_place_ after cycles_, in the order agreed for the three workers.
	# DF1 added pressures_ after reactor_place_ (the order the lead set: ..., cycles_, ward_place_, reactor_place_, pressures_).
	t.eq(names.slice(at), ["late_floors_", "party_table_", "tenant_timer_", "second_orderly_", "cycles_", "ward_place_", "reactor_place_", "pressures_", "ward_call_", "ward_web_", "ward_layout_", "orderly_fix_", "minder_calm_", "down_ring_", "pn_fixes_"] as Array[String], "late_floors_ is followed only by the fourteen agreed flags (WC1 added ward_call_ and ward_web_, WG1 ward_layout_, OR2 orderly_fix_, MA1 minder_calm_, down_ring_ and pn_fixes_)")
	t.eq(names[at - 1], "minder_hunt_", "minder_hunt_ comes just before it")
	t.eq(names[at - 2], "annex_drag_", "after annex_drag_")
	var plain := HostRules.new(true, 1, Places.FULL, true)
	t.check(not plain.late_floors and not plain.minder_hunt, "both are off by default")
	t.eq(HostRules.WARD_DEPTH, 6, "the Ward is floor 6")
	t.eq(HostRules.REACTOR_DEPTH, 7, "the Reactor is floor 7")

# ---- flag off ---------------------------------------------------------------------------------------

func test_flag_off_changes_nothing(t: T) -> void:
	# The same seeded run three ways: without the new parameters, with them given false, and with the flag off in a
	# host that is never told about the late floors. Down from floor 5 to 6 and 7, tick by tick.
	var hosts: Array[Host] = []
	var rule_sets: Array[HostRules] = [HostRules.new(true, 5, Places.FULL, true), HostRules.new(true, 5, Places.FULL, true)]
	rule_sets[1].late_floors = false
	rule_sets[1].minder_hunt = false
	var roster: Array[String] = ["one"]
	for r in rule_sets:
		var pipe := Transport.Pipe.new("host", func(_to: String, _d: String) -> void: pass, func(_d: String) -> void: pass)
		hosts.append(Host.new(pipe, "late-off-1", roster, 0.0, Callable(r, "prepare"), Callable(r, "step")))
	var bad := 0
	var depths := {}
	for k in 600:
		if k == 40 or k == 300:
			for h in hosts:
				ride_down(h)
		for h in hosts:
			h.update((k + 1) * Host.TICK + 1e-6)
		var a := hosts[0].world()
		var b := hosts[1].world()
		depths[int(a["depth"])] = true
		if a.has("ward") or a.has("reactor") or b.has("ward") or b.has("reactor") or Protocol.world_json(a) != Protocol.world_json(b):
			bad += 1
			if bad <= 2:
				t.check(false, "tick %d: flag off world differs or has a late block" % k)
	t.eq(bad, 0, "ticks where the flag off run differs")
	t.check(depths.has(6) and depths.has(7), "the run reached floors 6 and 7 (%s)" % str(depths.keys()))
	for h in hosts:
		t.check(not h.late_floors and h._ward_review == null and h._reactor_review == null, "no overlay without the flag")

func test_rooms_turn_it_on_only_with_the_full_deck(t: T) -> void:
	var original := Session.deck
	Session.deck = Places.CLINIC_ONLY
	var solo := LocalRoom.new()
	solo.open_local("late-clinic", "Tester", true)
	solo.start_run()
	t.check(not solo.rules.late_floors and not solo.host.late_floors, "a Clinic-only solo run has no late floors")
	t.check(not LocalRoom.playtest_destinations(solo.seed, Session.deck).any(func(d: Dictionary) -> bool: return int(d["depth"]) >= 6), "and its picker lists none")
	solo.leave()
	Session.deck = Places.FULL
	var full := LocalRoom.new()
	full.open_local("late-full", "Tester", true)
	full.start_run()
	t.check(full.rules.late_floors and full.host.late_floors, "a full-deck solo run has them")
	t.eq(full.host.state.depth, 1, "and still starts at floor 1")
	full.leave()
	Session.deck = original
	var room := Room.new(null, func(_s: String) -> void: pass)
	t.check(room.late_floors, "the server room's default is on")
	room.configure_campaign_trades({"late_floors": "0"})
	t.check(not room.late_floors, "late_floors=0 turns it off")
	room.configure_campaign_trades({})
	t.check(room.late_floors, "and the game's arguments leave it on")
	t.eq(room.late_archive_path("abc"), "", "no archive folder without a root (tests)")
	room.late_archive_root = "user://reactor-campaigns"
	t.check(room.late_archive_path("abc").begins_with("user://reactor-campaigns/") and room.late_archive_path("abc") != room.late_archive_path("abd"), "one folder per run seed in the game's user data")

# ---- flag on: the Ward --------------------------------------------------------------------------------

func test_ward_starts_on_arrival_holds_the_floor_and_goes_home(t: T) -> void:
	var crew := Crew.new("late-ward-1", 5, true)
	crew.tick_for(1.0)
	t.check(not crew.host.world().has("ward"), "floor 5 has no Ward")
	ride_down(crew.host)
	crew.host.update(crew.now + Host.TICK)
	var w := crew.host.world()
	t.eq(int(w["depth"]), HostRules.WARD_DEPTH, "the car arrived at floor 6")
	t.check(w.has("ward") and not w.has("reactor"), "the Ward block is there from the arrival tick")
	var ward := crew.host._ward_review
	t.check(ward != null and int(w["ward"]["seed"]) == Host.late_seed(crew.host.state), "seeded from the day's floor seed")
	var underneath := crew.host.state.orderly
	var seek: Variant = crew.host.state.seek
	var garden: Variant = crew.host.state.garden
	# Off the lift: the Ward's lift leaves and its ten minutes start.
	crew.everyone_at(ward.lift_door() + Vector3(0, 0, 1.2))
	crew.tick_for(20.0)
	t.eq(ward.phase, &"away", "the Ward's lift left the crew")
	t.check(crew.host.state.orderly == underneath and crew.host.state.seek == seek and crew.host.state.garden == garden, "the floor's own resident was not stepped")
	for c in crew.clients:
		t.check(c.latest.has("ward") and c.latest.ward.seed == w["ward"]["seed"] and c.latest.ward.collectionAt == ward.collection_at, "both clients have the same Ward")
	t.eq(crew.missing, [], "no client snapshot on floor 6 lacks the Ward")
	# The lift comes back; both aboard; it leaves for the prison.
	ward.collection_at = crew.host.state.t + 0.3
	crew.everyone_at(ward.lift_door() + Vector3(0, 0, -1.0))
	crew.tick_for(1.0)
	t.eq(ward.phase, &"boarding", "the lift is back")
	ward.depart_at = crew.host.state.t + 0.3
	var home := crew.tick_for(15.0, func() -> bool: return crew.host.state.depth == 0)
	t.check(home and crew.host.state.plan.place == Places.PRISON, "the crew rode home to the prison")
	t.eq(ward.boarded.size(), 2, "both rode")
	t.check(crew.host._ward_review == null and not crew.host.world().has("ward"), "the Ward is gone at home")
	# Bed, lights out, morning: the next day starts at floor 1.
	var ids: Array[String] = []
	for p in crew.host.state.players:
		ids.append(p.id)
	for i in crew.names.size():
		var bunk := Run.bunk_body(crew.host.state.plan, ids, crew.names[i])
		crew.bodies[i] = Vector3(bunk.x, bunk.y, bunk.z)
		crew.held[i] = true
	var day := crew.host.state.day_index
	var morning := crew.tick_for(90.0, func() -> bool: return crew.host.state.depth == 1)
	t.check(morning and crew.host.state.day_index == day + 1, "bed brings the next day, at floor 1 (day %d, depth %d)" % [crew.host.state.day_index, crew.host.state.depth])
	t.check(not crew.host.world().has("ward") and not crew.host.world().has("reactor"), "floor 1 has no late block")

# ---- flag on: the Reactor -----------------------------------------------------------------------------

func test_reactor_starts_on_arrival_holds_the_floor_banks_the_tape_and_goes_home(t: T) -> void:
	var dir := "user://test-late-floors/%d" % Time.get_ticks_usec()
	var crew := Crew.new("late-reactor-1", 6, false)
	# Floor 6 counts as done (its Ward ends the day, so a play arrival at 7 needs this), then the flag goes on.
	crew.host.late_floors = true
	crew.host.late_archive_path = dir
	crew.host._late_plan = crew.host.state.plan
	crew.tick_for(0.5)
	t.check(not crew.host.world().has("ward"), "this floor 6 was already handled")
	# Only floor 7 is under test here (this floor 6 has no Ward on purpose).
	crew.missing.clear()
	ride_down(crew.host)
	crew.host.update(crew.now + Host.TICK)
	var w := crew.host.world()
	t.eq(int(w["depth"]), HostRules.REACTOR_DEPTH, "the car arrived at floor 7")
	t.check(w.has("reactor") and not w.has("ward"), "the Reactor block is there from the arrival tick")
	var review := crew.host._reactor_review
	t.eq(int(w["reactor"]["seed"]), Host.late_seed(crew.host.state) & 0x7fffffff, "seeded from the day's floor seed")
	var underneath := crew.host.state.orderly
	var seek: Variant = crew.host.state.seek
	var garden: Variant = crew.host.state.garden
	# Into the dark (past the outage line): the lights hold for POWER_HOLD (RX1), then the corpses wake and hunt.
	# Thirty seconds of it.
	crew.everyone_at(review.rules.fuse)
	crew.tick_for(review.POWER_HOLD + 30.0)
	t.check(review.rules.power != ReactorState.Power.NORMAL, "the outage happened")
	t.check(crew.host.state.orderly == underneath and crew.host.state.seek == seek and crew.host.state.garden == garden, "the floor's own resident was not stepped")
	t.eq(String(crew.host.state.phase), "unloading", "the floor underneath holds still")
	var caught := 0
	for row in crew.host.event_log:
		var ty := str(JSON.parse_string(row.text).get("type", ""))
		if ty in ["caught", "down", "windUp", "carLeft", "rodeDown"]:
			caught += 1
	t.eq(caught, 1, "no catch, wind-up or car of the floor underneath (only the arrival's rodeDown)")
	for c in crew.clients:
		t.check(c.latest.has("reactor") and c.latest.reactor.seed == w["reactor"]["seed"] and c.latest.reactor.power == review.rules.power, "both clients have the same Reactor")
	t.eq(crew.missing, [], "no client snapshot on floor 7 lacks the Reactor")
	# The tape, the power, the lift.
	review.rules.power = ReactorState.Power.RESTORED
	review.rules.down_time.clear()
	for id: int in review.rules.condition:
		review.rules.condition[id] = "up"
	review.rules.recovery.clear()
	crew.held = [false, false]
	crew.everyone_at(review.rules.cassette_at)
	crew.tick_for(0.3)
	crew.held[0] = true
	crew.tick_for(0.3)
	crew.held[0] = false
	t.check(review.rules.collected and review.rules.cassette_holder != 0, "the tape was picked up")
	crew.everyone_at(Vector3(0, 0, 9.3))
	crew.tick_for(0.3)
	crew.held[1] = true
	var home := crew.tick_for(2.0, func() -> bool: return crew.host.state.depth == 0)
	t.check(review.rules.returned and review.rules.extracted, "the lift was called with the tape aboard")
	t.check(home and crew.host.state.plan.place == Places.PRISON, "the crew is at the prison")
	t.check(FileAccess.file_exists(dir.path_join("crew23.recovered")), "the recovered tape is written in the normal room's folder")
	t.check(crew.host.world().has("reactor") and crew.host.world().reactor.archive.recovered, "the prison sees the recovered tape")
	DirAccess.remove_absolute(dir.path_join("crew23.recovered"))
	DirAccess.remove_absolute(dir)

# ---- the solo picker ----------------------------------------------------------------------------------

func test_solo_picker_starts_both(t: T) -> void:
	var original := Session.deck
	Session.deck = Places.FULL
	var room := LocalRoom.new()
	room.open_local("late-picker", "Tester", true)
	room.late_archive_root = ""
	var list := LocalRoom.playtest_destinations(room.seed, Session.deck)
	t.check(list.has({"depth": 6, "place": &"ward"}) and list.has({"depth": 7, "place": &"reactor"}), "the picker lists floor 6 (ward) and 7 (reactor)")
	t.check(room.start_playtest(6), "floor 6 starts")
	t.check(room.host.world().has("ward") and room.host.state.depth == 6, "with the Ward before the first tick")
	var seed6: int = room.host.world().ward.seed
	for i in 10: room.poll(i * 0.05)
	t.check(room.client.latest != null and room.client.latest.has("ward") and room.client.latest.depth == 6, "the solo client has the Ward")
	t.check(room.start_playtest(6) and room.host.world().ward.seed == seed6, "a restart gives the same Ward")
	t.check(room.start_playtest(7), "floor 7 starts")
	t.check(room.host.world().has("reactor") and not room.host.world().has("ward") and room.host.state.depth == 7, "with the Reactor")
	for i in 10: room.poll(1.0 + i * 0.05)
	t.check(room.client.latest != null and room.client.latest.has("reactor") and room.client.latest.depth == 7, "the solo client has the Reactor")
	# A normal descent from floor 5 in the solo room arrives at the Ward too.
	t.check(room.start_playtest(5), "floor 5 starts")
	ride_down(room.host)
	for i in 4: room.poll(2.0 + i * 0.05)
	t.check(room.host.state.depth == 6 and room.host.world().has("ward"), "arriving at floor 6 alone starts the Ward")
	room.leave()
	Session.deck = original

## T22c: the floor picker's sandbox reuses the room's seed on every visit, so it keeps the Reactor's tape in memory:
## after a recovery recorded on disk under that very seed, a fresh sandbox visit to floor 7 still has the cassette on
## its table. A solo campaign run with the same seed still reads the recorded recovery.
func test_sandbox_reactor_always_has_its_tape(t: T) -> void:
	var original := Session.deck
	Session.deck = Places.FULL
	var root := "user://t22c-reactor-%d" % (Time.get_ticks_usec() % 1000000007)
	var sandbox := LocalRoom.new()
	sandbox.open_local("late-tape", "Tester", true)
	sandbox.late_archive_root = root
	# RN1: this checks the old overlay's archive (the fallback, reactor_place=0); tests/prop_station.gd checks the
	# same promise on the Reactor as a place.
	sandbox.reactor_place = false
	# The campaign's folder for this seed, with a recovery recorded in it.
	var campaign := LocalRoom.new()
	campaign.open_local("late-tape", "Tester", true)
	campaign.late_archive_root = root
	var dir := campaign.late_archive_path("late-tape")
	t.check(dir.begins_with(root + "/"), "the campaign keeps its tape on disk under its seed: %s" % dir)
	var recorded := ReactorArchive.new(dir)
	t.check(recorded.bank() and FileAccess.file_exists(dir.path_join("crew23.recovered")), "a recovery recorded under the sandbox's seed")
	for visit in 2:
		t.check(sandbox.start_playtest(HostRules.REACTOR_DEPTH), "visit %d: floor 7 starts" % visit)
		var review: Host.ReactorReview = sandbox.host._reactor_review
		t.eq(sandbox.host.late_archive_path, "", "visit %d: the sandbox keeps the tape in memory" % visit)
		t.check(review != null and not review.archive.recovered and not review.rules.collected, "visit %d: the cassette is on its table" % visit)
		for i in 4: sandbox.poll(visit * 2.0 + i * 0.05)
		t.check(sandbox.client.latest != null and sandbox.client.latest.has("reactor") and not bool(sandbox.client.latest.reactor.get("archive", {}).get("recovered", false)),
			"visit %d: the player's screen agrees, nothing recovered" % visit)
	sandbox.leave()
	# The campaign run: its first run uses the room's seed, and the host is given the folder with the recovery in it.
	campaign.start_run()
	t.eq(campaign.run_seed, "late-tape", "the campaign's first run has the same seed")
	t.eq(campaign.host.late_archive_path, dir, "the campaign host keeps the tape on disk")
	campaign.host.start_reactor_review(Host.late_seed(campaign.host.state), true, campaign.host.late_archive_path)
	t.check(campaign.host._reactor_review.archive.recovered and campaign.host._reactor_review.rules.collected, "the campaign's Reactor remembers the tape as recovered")
	campaign.leave()
	DirAccess.remove_absolute(dir.path_join("crew23.recovered"))
	DirAccess.remove_absolute(dir)
	DirAccess.remove_absolute(root)
	Session.deck = original

# ---- the dedicated server room ----------------------------------------------------------------------

class Net:
	var ws: WsServer
	var room: Room
	var now := 0.0
	var clients: Array = []
	var missing: Array = []

	func _init(port: int) -> void:
		var say := func(_l: String) -> void: pass
		ws = WsServer.new(SECRET, false, say)
		ws.listen(port, "127.0.0.1")
		room = Room.new(ws, say)
		room.fixed_seed = "late-net"
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
					var l: Variant = rc.client.latest
					if l != null:
						var d := int(l.get("depth", -1))
						if (d == HostRules.WARD_DEPTH and not l.has("ward")) or (d == HostRules.REACTOR_DEPTH and not l.has("reactor")):
							missing.append(d)
			if until.is_valid() and until.call():
				return true
			OS.delay_msec(2)
		return false

	func both(key: String, depth: int) -> bool:
		for rc: RoomClient in clients:
			if rc.client == null or rc.client.latest == null or not rc.client.latest.has(key) or int(rc.client.latest.depth) != depth:
				return false
		return true

	func stop() -> void:
		for rc: RoomClient in clients:
			if rc.status != "closed":
				rc.leave()
		run(0.2)
		ws.stop()

func test_server_room_starts_both_for_two_clients(t: T) -> void:
	var net := Net.new(PORT)
	net.room.first_depth = 5
	var a := net.join(PORT, "Ana")
	var b := net.join(PORT, "Bo")
	t.check(net.run(5.0, func() -> bool: return a.status == "lobby" and b.status == "lobby"), "both in the lobby")
	a.set_ready(true)
	b.set_ready(true)
	t.check(net.run(12.0, func() -> bool: return a.status == "running" and b.status == "running" and net.room.host != null), "the run started")
	t.check(net.room.rules.late_floors and net.room.host.late_floors, "the server's normal room has the late floors")
	net.run(1.0)
	ride_down(net.room.host)
	t.check(net.run(5.0, func() -> bool: return net.both("ward", 6)), "both clients see the Ward at floor 6")
	t.check(a.client.latest.ward.seed == b.client.latest.ward.seed and a.client.latest.ward.seed == Host.late_seed(net.room.host.state), "the same seeded Ward on both")
	t.eq(net.missing, [], "no snapshot on floor 6 without the Ward")
	# The next run starts on floor 7.
	net.room._end_run()
	net.room.first_depth = 7
	t.check(net.run(5.0, func() -> bool: return a.status == "lobby" and b.status == "lobby"), "back in the lobby")
	a.set_ready(true)
	b.set_ready(true)
	t.check(net.run(12.0, func() -> bool: return net.both("reactor", 7)), "both clients see the Reactor at floor 7")
	t.check(a.client.latest.reactor.seed == b.client.latest.reactor.seed, "the same seeded Reactor on both")
	t.eq(net.missing, [], "no snapshot on floor 7 without the Reactor")
	net.stop()
