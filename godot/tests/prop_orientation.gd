extends RefCounted

const T = preload("res://tests/t.gd")
const Entity = preload("res://sim/entity.gd")
const Floor = preload("res://sim/floor.gd")
const Instr = preload("res://sim/instrument.gd")
const Move = preload("res://sim/move.gd")
const Orientation = preload("res://sim/orientation.gd")
const Places = preload("res://sim/places.gd")
const Run = preload("res://sim/run.gd")
const LocalRoom = preload("res://net/local_room.gd")
const RoomClient = preload("res://net/room_client.gd")
const Session = preload("res://net/session.gd")
const WsServer = preload("res://net/ws_server.gd")
const Room = preload("res://server/room.gd")

const DT := 0.05

func test_explicit_local_and_hosted_routes_use_the_same_plan(t: T) -> void:
	var local := LocalRoom.new()
	local.open_local("practice", "ANN", true)
	local.start_orientation()
	var quiet := func(_line: String) -> void: pass
	var room := Room.new(WsServer.new("", true, quiet), quiet)
	room.orientation_review = true
	room.fixed_seed = "practice"
	room.people = {"c1": "ANN", "c2": "BOB"}
	room.ready = {"c1": 0.0, "c2": 0.0}
	room._start(0.0)
	var peer := RoomClient.new()
	peer.my_id = "c2"
	peer._on_text(room._lobby_text(0.0), 0.0)
	var local_plan := Session.plan_for("practice", 1, local.client.floor_deck)
	var peer_plan := Session.plan_for("practice", 1, peer.client.floor_deck)
	var expected := Floor.hash_plan(local.host.state.plan)
	t.eq(local_plan.place, Orientation.PLACE, "local player gets the practice floor")
	t.eq(peer_plan.place, Orientation.PLACE, "dedicated peer reads the named room setup")
	t.check(Floor.find_path(local_plan, local_plan.landing, local_plan.entity_start).size() > 2,
		"players can walk from the lift to the practice target")
	t.eq(Floor.hash_plan(local_plan), expected, "the local player sees its host's floor")
	t.eq(Floor.hash_plan(room.host.state.plan), expected, "both hosts use identical seed geometry")
	t.eq(Floor.hash_plan(peer_plan), expected, "the dedicated peer sees exactly the same floor")
	t.check(local.host.state.orientation and room.host.state.orientation, "both hosts enable the practice rules")
	t.check(not local.host.state.days and not room.host.state.days, "neither practice has a paid campaign day")
	var normal := Room.new(WsServer.new("", true, quiet), quiet)
	normal.fixed_seed = "practice"
	normal.people = {"c1": "ANN"}
	normal.ready = {"c1": 0.0}
	normal._start(0.0)
	t.check(not normal._lobby_text(0.0).contains('"orientation"'), "ordinary lobby metadata is unchanged")
	t.eq(normal.host.state.plan.place, Places.CLINIC, "ordinary hosted Day 1 still starts in Clinic")
	t.check(not normal.host.state.orientation, "the ordinary run leaves practice off")
	local.leave()
	peer.leave()
	room.host.close()
	normal.host.close()

func _input(id: String, body: Move.Body, target: Move.Body, watch: bool, raised := false, call := false) -> Run.PlayerInput:
	var yaw := Entity.yaw_toward(target.x - body.x, target.z - body.z)
	var input := Run.PlayerInput.make(id, body, 1.65, yaw + (0.0 if watch else PI), 0.0, 105.0, 75.0)
	input.raised = raised
	input.call = call
	return input

func test_one_watcher_stops_the_target_and_contact_is_harmless(t: T) -> void:
	var s := Run.with_orientation(Run.create_run("watch", ["a", "b", "c"]))
	s.phase = &"away"
	var start := s.orderly.body
	var position := Move.Body.make(start.x, start.z + 2.5, 0, 0.0)
	var second := Move.Body.make(start.x, start.z + 3.0, 0, 0.0)
	for _tick in 20:
		var inputs: Array[Run.PlayerInput] = [_input("a", position, start, false, true),
			_input("b", second, start, true), _input("c", second, start, false)]
		s = Run.step_run(s, inputs, DT).state
	t.eq(s.orderly.body.z, start.z, "one watcher holds the target even in a crew of three")
	t.eq(Instr.member(s.crew, "a").tape.total, 0.0, "being nearby with the instrument raised does not earn a reading")
	var honks := 0
	var needle_recorded := false
	for _tick in 150:
		var target := s.orderly.body
		var inputs: Array[Run.PlayerInput] = [_input("a", position, target, false, true),
			_input("b", second, target, false), _input("c", second, target, false)]
		var result := Run.step_run(s, inputs, DT)
		s = result.state
		for event in result.events:
			if event["type"] == "orientationHonk":
				honks += 1
			t.check(event["type"] not in ["caught", "downed", "out", "wiped"], "contact emits no injury")
		needle_recorded = needle_recorded or Instr.member(s.crew, "a").instrument.needle == &"recording"
	t.check(s.orderly.body.z > start.z + 1.0, "it rolls toward the players when nobody watches")
	t.check(needle_recorded, "the real instrument records the moving target")
	t.eq(honks, 1, "contact honks once until the crew moves away")
	t.check(s.players.all(func(p: Run.RunPlayer) -> bool: return p.status == &"ok"), "the whole crew stays unharmed")
	t.check(s.floor_earned >= Orientation.QUOTA and s.floor_earned < 100.0, "the genuine sample pays token practice earnings")

func test_a_real_sample_opens_the_lift_and_the_whole_crew_can_bank(t: T) -> void:
	var s := Run.with_orientation(Run.create_run("practice-bank", ["a", "b"]))
	var landing := Run.car_body(s.car, -0.8, 0.0)
	var bank_a := Run.car_body(s.car, 1.3, -0.6)
	var bank_b := Run.car_body(s.car, 2.3, -0.6)
	var down := Run.car_body(s.car, 1.3, 0.6)
	for _tick in 25:
		s = Run.step_run(s, [_input("a", bank_a, s.orderly.body, true), _input("b", bank_b, s.orderly.body, true)], DT).state
	t.eq(s.phase, &"unloading", "the practice floor starts in an ordinary open car")
	for _tick in 45:
		s = Run.step_run(s, [_input("a", landing, s.orderly.body, true), _input("b", landing, s.orderly.body, true)], DT).state
	t.eq(s.phase, &"away", "the lift leaves when both people step out")
	var below := Run.step_run(s, [_input("a", landing, s.orderly.body, true, false, true), _input("b", landing, s.orderly.body, true)], DT)
	t.check(below.events.any(func(e: Dictionary) -> bool: return e["type"] == "callRefused"), "the real panel rejects a call before recording")
	s = below.state
	var target := s.orderly.body
	var station := Move.Body.make(target.x, target.z + 3.0, 0, 0.0)
	var saw_slip := false
	for _tick in 130:
		var read := Run.step_run(s, [_input("a", station, s.orderly.body, false, true), _input("b", landing, s.orderly.body, false)], DT)
		s = read.state
		saw_slip = saw_slip or read.events.any(func(e: Dictionary) -> bool: return e["type"] == "slip")
	t.check(saw_slip, "the real first-reading slip describes the recorded movement")
	t.check(Run.quota_reached(s), "the tape earns enough to call the car (%.2f of %d)" % [s.floor_earned, s.floor_needed])
	var accepted := Run.step_run(s, [_input("a", landing, s.orderly.body, true, false, true), _input("b", landing, s.orderly.body, true)], DT)
	t.check(accepted.events.any(func(e: Dictionary) -> bool: return e["type"] == "called"), "the same button opens the return route")
	s = accepted.state
	for _tick in 80:
		s = Run.step_run(s, [_input("a", landing, s.orderly.body, true), _input("b", landing, s.orderly.body, true)], DT).state
	t.eq(s.phase, &"boarding", "the practice lift arrives promptly")
	for _tick in 90:
		s = Run.step_run(s, [_input("a", bank_a, s.orderly.body, true), _input("b", down, s.orderly.body, true)], DT).state
	t.eq(s.phase, &"boarding", "one player still on DOWN cannot depart or leave anybody behind")
	for _tick in 65:
		s = Run.step_run(s, [_input("a", bank_a, s.orderly.body, true), _input("b", bank_b, s.orderly.body, true)], DT).state
	t.eq(s.phase, &"ended", "all players on BANK finish the exercise")
	t.check(s.summary != null and s.summary.total >= Orientation.QUOTA, "practice credits came home on real tapes")
	t.check(not s.days and s.wallets.is_empty() and s.left_out.is_empty(), "practice pays no campaign wallet and leaves nobody behind")
