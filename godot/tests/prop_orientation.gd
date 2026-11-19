extends RefCounted

const T = preload("res://tests/t.gd")
const Entity = preload("res://sim/entity.gd")
const Floor = preload("res://sim/floor.gd")
const Instr = preload("res://sim/instrument.gd")
const Move = preload("res://sim/move.gd")
const Orientation = preload("res://sim/orientation.gd")
const OrientationView = preload("res://client/orientation_view.gd")
const Places = preload("res://sim/places.gd")
const Run = preload("res://sim/run.gd")
const LocalRoom = preload("res://net/local_room.gd")
const RoomClient = preload("res://net/room_client.gd")
const Protocol = preload("res://net/protocol.gd")
const Session = preload("res://net/session.gd")
const WsServer = preload("res://net/ws_server.gd")
const Room = preload("res://server/room.gd")
const HostRules = preload("res://net/host_rules.gd")
const Profiles = preload("res://net/profiles.gd")
const Save = preload("res://net/save_slip.gd")
const Shop = preload("res://sim/shop.gd")
const Cabinet = preload("res://tests/prop_cabinet.gd")
const ShopTest = preload("res://tests/prop_shop.gd")
const Inventory = preload("res://sim/inventory.gd")

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

func test_route_sign_faces_the_crew_at_the_first_open_corridor(t: T) -> void:
	var room := Node3D.new()
	OrientationView.dress(room, true)
	var cue: Label3D = null
	for child: Node in room.find_children("*", "Label3D", true, false):
		var label := child as Label3D
		if label.text.begins_with("FOLLOW THE YELLOW TAPE"):
			cue = label
			break
	t.check(cue != null, "the first practice sign directly connects the controls with the floor tape")
	if cue != null:
		var sign := cue.get_parent() as Node3D
		var landing_edge := float(Orientation.LANDING_ROW * Orientation.CELL)
		t.check(sign.position.z > landing_edge - Orientation.CELL and sign.position.z < landing_edge,
			"the cue is in the first visible open bay after the doors")
		t.check(sign.basis.z.dot(Vector3.BACK) > 0.99 and sign.position.y - 0.39 > Orientation.target_body().height,
			"the sign faces the car and leaves the training target and route clear below")
	room.free()

func _input(id: String, body: Move.Body, target: Move.Body, watch: bool, raised := false, call := false) -> Run.PlayerInput:
	var yaw := Entity.yaw_toward(target.x - body.x, target.z - body.z)
	var input := Run.PlayerInput.make(id, body, 1.65, yaw + (0.0 if watch else PI), 0.0, 105.0, 75.0)
	input.raised = raised
	input.call = call
	return input

func test_standees_respond_once_to_walking_and_late_viewers_get_the_fallen_prop(t: T) -> void:
	var dressing := preload("res://client/orientation_view.gd")
	var room := LocalRoom.new()
	room.open_local("standee-walk", "ANN", true)
	room.start_orientation()
	var s := room.host.state
	var id := s.players[0].id
	var start := Run.car_body(s.car, 1.4, 0.0)
	var place_a := Move.Body.make(11.0, Orientation.STANDEE_BAYS[0].y, 0, 0.0)
	var place_b := Move.Body.make(11.0, Orientation.STANDEE_BAYS[1].y, 0, 0.0)
	t.check(not room.host.world().has("orientationStandees"), "unreached practice sends no standee state")
	s = Run.step_run(s, [_input(id, start, s.orderly.body, true)], DT).state
	t.eq(s.orientation_standees, Orientation.STANDEES_UNTRIGGERED, "the crew sees no pop while still aboard")
	s = Run.step_run(s, [_input(id, place_a, s.orderly.body, true)], DT).state
	var first_pop := s.orientation_standees.x
	t.check(is_equal_approx(first_pop, s.t) and s.orientation_standees.y < 0.0, "walking into the first bay only releases its standee")
	s = Run.step_run(s, [_input(id, place_b, s.orderly.body, true)], DT).state
	var second_pop := s.orientation_standees.y
	t.check(is_equal_approx(second_pop, s.t) and second_pop > first_pop, "walking into the second bay releases its own standee")
	for feet: Move.Body in [place_a, place_b, start]:
		s = Run.step_run(s, [_input(id, feet, s.orderly.body, true)], DT).state
	t.eq(s.orientation_standees, Vector2(first_pop, second_pop), "turning back or crossing twice never restarts a prop")
	t.check(s.players[0].status == &"ok" and s.floor_earned == 0.0, "the props do no damage and pay no credits")
	room.host.state = s
	var world := room.host.world(true)
	var welcome: Dictionary = Protocol.decode(Protocol.encode({"type": "welcome", "you": id, "seed": s.seed,
		"playing": true, "evFrom": 1, "world": world}))
	var stamps: Array = welcome.world.orientationStandees
	t.eq(stamps, world.orientationStandees, "a late welcome preserves both shared pop times")
	var first_view := Node3D.new()
	dressing.dress(first_view)
	var props: Array = first_view.get_meta(&"orientation_standees")
	var upright := props[0]["card"] as Node3D
	var falling := props[1]["card"] as Node3D
	t.check(not upright.visible and not falling.visible, "both standees start inside their trays")
	dressing.show_standees(first_view, stamps, second_pop + 0.55)
	t.check(upright.visible and falling.visible and absf(falling.rotation.x) < 0.01,
		"both physical boards pop upright before one falls")
	var late_view := Node3D.new()
	dressing.dress(late_view)
	dressing.show_standees(late_view, stamps, second_pop + 3.0)
	var late_props: Array = late_view.get_meta(&"orientation_standees")
	var settled := late_props[1].card as Node3D
	t.check(settled.visible and absf(settled.rotation.x + PI * 0.5) < 0.01,
		"a late viewer sees the second board lying face-up on the floor")
	t.check(not (late_props[1].latch as AudioStreamPlayer3D).playing, "the late view does not replay the latch")
	var wire := Protocol.enc_world(world)
	t.check(wire[Protocol.WORLD_SHOP_INDEX] == null and wire[Protocol.WORLD_FLOOR_EXTENSIONS_INDEX].has("orientationStandees"),
		"practice uses a named extension and does not take the shop slot")
	room.start_orientation()
	t.check(not room.host.world().has("orientationStandees"), "a new practice run starts with the trays reset")
	room.leave()
	first_view.free()
	late_view.free()

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

func test_optional_campaign_transfers_the_whole_crew_and_pays_once(t: T) -> void:
	var ids: Array[String] = ["a", "b"]
	var rules := HostRules.new(true, 1, Places.BEFORE_ARBORETUM, true, true, true,
		false, false, false, false, true, false, false, true, false, false, true, false, false, true,
		false, false, false, true, true)
	var ordinary := rules.prepare(Run.create_run("orientation-campaign", ids))
	t.eq(ordinary.plan.place, Places.CLINIC, "the default paid campaign opens directly in Clinic")
	rules.enable_orientation_prelude()
	var s := rules.prepare(Run.create_run("orientation-campaign", ids))
	t.eq(s.plan.place, Orientation.PLACE, "the candidate begins in training")
	t.check(not s.days and s.orientation_resume.days and s.depth == Orientation.PRELUDE_DEPTH, "the first paid day is prepared separately")
	var key := PackedByteArray()
	key.resize(32)
	key.fill(11)
	var profiles := Profiles.new(key)
	var saved := Save.fresh("1111111111111111")
	saved.credits = 140
	saved.days = 4
	var cabinet := Shop.empty_cabinet()
	cabinet[0] = ["speed", 1]
	saved.cabinet = Shop.cabinet_text(cabinet)
	var stamped := Save.seal(saved, key)
	profiles.join("a", "ANN", stamped)
	s = profiles.apply_for(s, "a", "ANN")
	s = profiles.apply_for(s, "b", "BOB")
	s.phase = &"away"
	var origin := s.orderly.body
	var near := Move.Body.make(origin.x, origin.z + 3.0, 0, 0.0)
	var far := Move.Body.make(origin.x, origin.z + 6.0, 0, 0.0)
	for _tick in 155:
		s = Run.step_run(s, [_input("a", near, s.orderly.body, false, true), _input("b", far, s.orderly.body, false)], DT).state
	t.check(Run.quota_reached(s), "the preparation earns a real practice tape")
	var bank_a := Run.car_body(s.car, 1.35, -0.55)
	var bank_b := Run.car_body(s.car, 2.35, -0.55)
	s.phase = &"boarding"
	s.bell_left = 0.01
	for _tick in 90:
		s = Run.step_run(s, [_input("a", bank_a, s.orderly.body, true)], DT).state
	t.eq(s.phase, &"boarding", "a missing input cannot let the practice car leave a crew member behind")
	var pay_events: Array[Dictionary] = []
	for _tick in 145:
		var a := bank_a if s.orientation else Run.car_body(s.car, 1.35, -0.55)
		var b := bank_b if s.orientation else Run.car_body(s.car, 2.35, -0.55)
		var step := Run.step_run(s, [_input("a", a, s.orderly.body, true), _input("b", b, s.orderly.body, true)], DT)
		s = step.state
		for event in step.events:
			if event.type == "orientationPaid":
				pay_events.append(event)
	t.eq(pay_events.size(), 1, "the exercise settles exactly once")
	if pay_events.size() != 1:
		return
	var shares: Dictionary = pay_events[0].shares
	t.check(Profiles.changed(pay_events).ids.has("a") and not Profiles.changed(pay_events).served, "practice checkpoints wages without adding a served day")
	t.eq(s.orientation_paid, int(shares["a"]) + int(shares["b"]), "every integer practice credit goes to the crew")
	t.eq(s.plan.place, Places.CLINIC, "the same lift returns the crew to the actual paid Clinic floor")
	t.eq(Floor.hash_plan(s.plan), Floor.hash_plan(ordinary.plan), "the paid Clinic keeps exactly the standard seeded geometry")
	t.check(s.players.all(func(p: Run.RunPlayer) -> bool: return p.aboard), "the entire practice crew arrives in the Clinic car")
	t.check(s.days and s.day_state.day == 1 and s.day_index == 1 and s.day_state.streak == 0, "the Clinic still begins the first real day")
	t.check(s.floor_earned == 0.0 and s.day_earned == 0.0 and s.floor_needed == ordinary.floor_needed
		and Run.day_quota_now(s) == Run.day_quota_now(ordinary) and s.day_lock and Run.day_locked(s),
		"practice pay does not count toward either real quota")
	t.check(Instr.member(s.crew, "a").tape.readings.is_empty() and s.crew.floor.is_empty(), "practice tapes cannot be banked again")
	t.eq(s.wallets["a"].credits, 140 + int(shares["a"]), "the returning profile receives exactly its practice wage")
	t.eq(Shop.cabinet_of((s.shop_state as Shop.ShopState).cabinets, "a")[0], ["speed", 1], "the returning cabinet survives the prelude")
	var receipt := Save.open(profiles.checkpoint(s, "a", "ANN", false), key)
	t.check(receipt.ok and int(receipt.fields.days) == 4, "the practice receipt retains the old count of served days")
	profiles.leave("a")
	profiles.join("rejoined", "ANN", stamped)
	s = profiles.apply_for(s, "rejoined", "ANN")
	t.eq(s.wallets["rejoined"].credits, 140 + int(shares["a"]), "an older stamp on reconnect recovers the single paid balance")
	profiles.leave("rejoined")
	profiles.join("a", "ANN", stamped)
	s = profiles.apply_for(s, "a", "ANN")
	s.day_earned = Run.day_quota_now(s)
	var first_day: Array[Dictionary] = []
	Run._settle_day(s, s.t, floori(s.day_earned), first_day, false)
	t.eq(s.day_result["banked"], floori(s.day_earned), "the first ordinary report banks only the Clinic work")
	var payday: int = 140 + int(shares["a"]) + int(s.day_result["shares"]["a"])
	t.eq(s.day_result["credits"]["a"], payday, "the real wage is added to the wallet once")
	t.check(s.deep_pockets and s.second_wind and s.wind_profiles.has("a"), "Clinic resumes with skills and verified profile identity")
	var home := s.copy()
	Run._arrive_home(home, home.players, home.t, first_day)
	var window := {"a": ShopTest.window(home, 3)}
	var trained := Cabinet.tick(home, window, {"a": ["skill", 0]})
	t.eq(trained.state.wallets["a"].credits, payday - Shop.SHARE, "training spends one share from the combined balance")
	var repeated := Cabinet.tick(trained.state, window, {"a": ["skill", 0]})
	t.eq(repeated.state.wallets["a"].credits, payday - Shop.SHARE, "replayed purchase debits nothing")
	var items := {"a": ShopTest.window(home, 1)}
	var played := Cabinet.tick(repeated.state, items, {"a": ["buy", 0]}).state
	played = Cabinet.tick(played, items, {"a": ["buy", 0]}).state
	t.eq(Inventory.bag_of(played.bags, "a").count(0), 2, "two purchased markers stack through the acquired skill")
	var post := profiles.checkpoint(played, "a", "ANN", false)
	t.check(Save.open(post, key).ok and Save.open(post, key).fields.nodes.has("deep_pockets"), "accepted training is signed")
	profiles.leave("a")
	profiles.join("replay", "ANN", stamped)
	played = profiles.apply_for(played, "replay", "ANN")
	t.eq(played.wallets["replay"].credits, payday - Shop.SHARE - 2 * Shop.base_price("marker"), "stale slip cannot replay practice wage or training debit")
	Run._morning(s, s.players, s.t, first_day)
	t.check(s.day_index == 2 and s.plan.place == Places.CLINIC and not s.orientation, "the same night skips training on day two")
	var new_night := rules.prepare(Run.create_run("orientation-campaign-next", ids))
	t.check(new_night.orientation and new_night.orientation_paid == 0, "a fresh night gets one fresh practice stop")
