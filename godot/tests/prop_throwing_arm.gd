extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Cabinet = preload("res://tests/prop_cabinet.gd")
const ShopTest = preload("res://tests/prop_shop.gd")
const Upgrades = preload("res://sim/upgrades.gd")
const Inventory = preload("res://sim/inventory.gd")
const Save = preload("res://net/save_slip.gd")
const Profiles = preload("res://net/profiles.gd")
const Protocol = preload("res://net/protocol.gd")
const Host = preload("res://net/host.gd")
const Transport = preload("res://net/transport.gd")
const Move = preload("res://sim/move.gd")
const Floor = preload("res://sim/floor.gd")
const Cone = preload("res://sim/garden_cones.gd")
const Noises = preload("res://sim/noise.gd")
const ShopView = preload("res://client/shop_view.gd")

class RattleSeen extends RefCounted:
	var active := false
	func shop_toy_audio(_node: Node3D, rattling: bool) -> void:
		active = rattling

static func _near(t: T, got: float, want: float, tolerance: float, note: String) -> void:
	t.check(absf(got - want) <= tolerance, "%s: got %.4f, want %.4f" % [note, got, want])

static func _with_trade(s: Run.RunState) -> Run.RunState:
	return Run.with_throwing_arm(Run.with_soft_shoes(Run.with_deep_pockets(Run.with_shop(Run.with_inventory(s)))))

func test_ordinary_campaign_admits_throwing_arm_and_rollback_is_independent(t: T) -> void:
	const Places = preload("res://sim/places.gd")
	const Session = preload("res://net/session.gd")
	const HostRules = preload("res://net/host_rules.gd")
	var room := preload("res://server/room.gd").new(null, func(_s: String) -> void: pass)
	var local := preload("res://net/local_room.gd").new()
	var game := preload("res://client/main.gd").new()
	var original := Session.deck
	Session.deck = Places.FULL
	room.configure_campaign_trades({})
	game._configure_campaign_trades(local)
	t.check(local.throwing_arm and room.throwing_arm, "normal full deck admits Throwing Arm")
	room.configure_campaign_trades({"throwing_arm": "0"})
	game._throwing_arm = false
	game._configure_campaign_trades(local)
	t.check(not local.throwing_arm and not room.throwing_arm, "explicit rollback disables only Throwing Arm")
	t.check(local.steady_gaze and room.steady_gaze and local.field_dressing and room.field_dressing and local.long_burn and room.long_burn
		and local.quick_fingers and room.quick_fingers and local.badge_search and room.badge_search,
		"Lamplighter, Medic, Porter, Long Burn and badges remain available")
	game._throwing_arm = true
	Session.deck = Places.CLINIC_ONLY
	game._configure_campaign_trades(local)
	t.check(not local.throwing_arm and not HostRules.new(true, 1).throwing_arm, "reference deck and direct host defaults stay off")
	Session.deck = original
	game.free()

func test_listener_badge_trade_and_signed_undo(t: T) -> void:
	var home := _with_trade(Cabinet.home_run("listener-window", ["p0", "p1"]))
	home = ShopTest.with_credits(home, {"p0": 2000, "p1": 2000})
	var positions := {"p0": ShopTest.window(home, 3), "p1": ShopTest.window(home, 4)}
	home = Cabinet.with_bags(home, {"p0": [["badge", 1], ["badge", 1]], "p1": [["badge", 1], ["badge", 1]]})
	var trade := {"p0": ["skill", 9], "p1": ["skill", 9]}
	var need := Cabinet.of_type(Cabinet.tick(home, positions, trade).events, "invRefused")
	t.eq(need.map(func(e: Dictionary) -> String: return str(e.why)), ["needs", "needs"], "Soft Shoes precedes the badge trade")
	home = Cabinet.tick(home, positions, {"p0": ["skill", 4], "p1": ["skill", 4]}).state
	home.wallets.p1.owned.append("field_dressing")
	var result := Cabinet.tick(home, positions, trade)
	var conflicts := Cabinet.of_type(result.events, "invRefused")
	t.eq(conflicts.map(func(e: Dictionary) -> String: return str(e.why)), ["trade"], "existing Medic is locked out")
	t.eq(Inventory.bag_of(result.state.bags, "p1").totals().get("badge"), 2, "the refused player keeps both badges")
	t.eq(ShopTest.credits_of(result.state, "p0"), 1400, "only Soft Shoes costs credits")
	t.eq(Inventory.bag_of(result.state.bags, "p0").totals().get("badge", 0), 0, "Throwing Arm consumed two badges")
	t.eq(Upgrades.trade_of(result.state.wallets.p0.owned), "Listener", "the skill fixes the actual branch")
	var key := PackedByteArray()
	key.resize(32)
	var fields := Profiles.collect(result.state, "p0", Save.fresh("a0123456789bcdef"), "Thrower", false)
	var signed := Save.open(Save.seal(fields, key), key)
	t.check(signed.ok and signed.fields.training_node == "throwing_arm" and signed.fields.training_refund == 0, "signed undo keeps the paid badge skill")
	var gone := Cabinet.tick(result.state, positions, {"p0": ["skill", 1]}).state
	t.eq(Inventory.bag_of(gone.bags, "p0").totals().get("badge"), 2, "undo returns both badges")
	t.eq(Upgrades.trade_of(gone.wallets.p0.owned), "", "undo opens other trades again")

static func _stage() -> Dictionary:
	for seed in 10:
		var s := _with_trade(Run.create_run("throwing-range-%d" % seed, ["p0", "p1"]))
		var distance := Floor.distances_from(s.plan, s.plan.landing)
		for n in distance.size():
			if distance[n] < 0:
				continue
			var origin := Move.body_at_cell(s.plan, Floor.pos_from_index(s.plan, n))
			if Run.in_car(s.car, origin):
				continue
			for yaw: float in [0.0, PI / 2.0, PI, -PI / 2.0]:
				var end := Cone.landing(s.plan, Run.solids_in(s), origin, yaw, 0.0, 15.5)
				if not is_equal_approx(_distance(origin, end), 15.5):
					continue
				var wallet := Upgrades.UpgradeState.make()
				wallet.owned.assign(["soft_shoes", "throwing_arm"])
				s.wallets.p0 = wallet
				s.players[0].body = origin
				s.phase = &"away"
				s = Cabinet.with_bags(s, {"p0": [["toy", 1]], "p1": [["toy", 1]]})
				return {"run": s, "yaw": yaw, "origin": origin}
	return {}

static func _distance(a: Move.Body, b: Move.Body) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

static func _stock_action(s: Run.RunState, op: StringName, yaw: float, id := "p0") -> Run.RunStep:
	var inputs: Array[Run.PlayerInput] = []
	for p in s.players:
		var a := Cabinet.inp(p.id, p.body)
		if p.id == id:
			a.inv_op = op
			a.yaw = yaw
		inputs.append(a)
	return Run.step_run(s, inputs, Cabinet.DT)

func test_actual_throw_lands_before_the_twelve_second_rattle(t: T) -> void:
	var fixture := _stage()
	if not t.check(not fixture.is_empty(), "a seeded Clinic has a clear fifteen-metre throw"):
		return
	var base: Run.RunState = fixture.run
	var origin: Move.Body = fixture.origin
	var thrown := _stock_action(base, &"throw", fixture.yaw)
	if not t.check(thrown.state.shop_state.toys.size() == 1, "ordinary inventory throw creates one toy"):
		return
	var toy: Dictionary = thrown.state.shop_state.toys[0]
	_near(t, _distance(origin, toy.at), 15.0, 0.001, "actual throw caps at fifteen metres")
	_near(t, toy.start - toy.land, 3.0, 0.001, "the landed toy winds up for three seconds")
	_near(t, toy.end - toy.start, 12.0, 0.001, "trained rattle doubles the ordinary six seconds")
	t.check(toy.land > toy.launch and toy.at.level == origin.level, "the flight has a positive duration on the same floor")
	t.eq(Inventory.bag_of(thrown.state.bags, "p0").totals().get("toy", 0), 0, "one throw consumes one wind-up toy")
	var local_before := _stock_action(base, &"use", fixture.yaw)
	_near(t, local_before.state.shop_state.toys[0].end - local_before.state.shop_state.toys[0].start, 12.0, 0.001, "normal placement also benefits from training")
	var blocked := false
	for turn: float in [PI / 2.0, -PI / 2.0, PI]:
		var yaw: float = fixture.yaw + turn
		var wall := Cone.landing(base.plan, Run.solids_in(base), origin, yaw, 0.0, 15.5)
		if _distance(origin, wall) >= 14.0:
			continue
		blocked = true
		var stopped: Dictionary = _stock_action(base, &"throw", yaw).state.shop_state.toys[0]
		t.check(_distance(wall, stopped.at) < 0.05, "the toy stops at the first obstruction on the current floor")
		break
	t.check(blocked, "obstruction test uses an actual nearby wall")
	base.throwing_arm = false
	var rollback := _stock_action(base, &"throw", fixture.yaw).state
	t.check(rollback.shop_state.toys.is_empty() and Inventory.bag_of(rollback.bags, "p0").totals().get("toy") == 1, "learned node cannot throw with feature off")
	var legacy := _stock_action(base, &"use", fixture.yaw).state
	var placed: Dictionary = legacy.shop_state.toys[0]
	_near(t, placed.end - placed.start, 6.0, 0.001, "ordinary toy still rattles six seconds")
	t.check(not placed.has("from"), "ordinary toy stays on the four-field snapshot shape")
	var peer := Transport.MemoryNetwork.new("throw-wire")
	var host := Host.new(peer.connect_peer("host"), "throw-wire", ["p0", "p1"], 0.0)
	host.state = thrown.state
	var wire: Variant = Protocol.decode(Protocol.encode({"type": "welcome", "you": "p1", "seed": base.seed, "playing": true,
		"evFrom": 0, "world": host.world()}))
	if not t.check(wire != null and wire.world.shop.toys.size() == 1 and wire.world.get("listener") == {"p0": 1, "p1": 4}, "late peers get both role and current flight"):
		return
	var view := ShopView.new()
	var root := Node3D.new()
	var audio := RattleSeen.new()
	view.show_world(root, null, wire.world.shop, (toy.land + toy.launch) / 2.0, 0, audio)
	var actor: Node3D = root.get_child(0)
	t.check(actor.position.y > origin.y + 0.6 and not audio.active, "the same toy flies visibly without rattling")
	view.show_world(root, null, wire.world.shop, toy.start + 11.7, 0, audio)
	t.check(audio.active and actor.position.y < origin.y + 0.01, "existing rattle stays active on the floor near twelve seconds")
	view.show_world(root, null, wire.world.shop, toy.end + 0.01, 0, audio)
	t.check(not audio.active, "the positional rattle stops when the host timer ends")
	root.free()
	view.free()

func test_listener_footstep_seniority_is_separate_from_soft_shoes(t: T) -> void:
	var before := Move.Body.make(4.0, 4.0, 0, 0.0)
	var after := Move.Body.make(4.1, 4.0, 0, 0.0)
	var actor := Noises.Act.make("p0", after, before, &"walk")
	var ordinary := Noises.of(null, actor, 0.05, {}).r
	actor.soft_shoes = true
	actor.footstep_scale = 0.9
	_near(t, Noises.of(null, actor, 0.05, {}).r, ordinary * 0.75 * 0.9, 0.0001, "the two earned reductions apply to walking")
	actor.gait = &"sprint"
	_near(t, Noises.of(null, actor, 0.05, {}).r, Noises.SPRINT * 0.9, 0.0001, "sprint receives seniority without the Soft Shoes discount")

func test_named_trade_rows_can_share_one_snapshot_and_roll_back_independently(t: T) -> void:
	var rules := _with_trade(Cabinet.home_run("all-trade-rows", ["p0", "p1"]))
	rules = Run.with_steady_gaze(Run.with_long_burn(rules))
	rules = Run.with_quick_fingers(Run.with_findables(rules))
	rules = Run.with_field_dressing(Run.with_second_wind(Run.with_downs(rules)))
	var lamp := Upgrades.UpgradeState.make()
	lamp.owned.assign(["long_burn", "steady_gaze"])
	var ear := Upgrades.UpgradeState.make()
	ear.owned.assign(["soft_shoes", "throwing_arm"])
	rules.wallets = {"p0": lamp, "p1": ear}
	var net := Transport.MemoryNetwork.new("all-trade-rows")
	var host := Host.new(net.connect_peer("host"), rules.seed, ["p0", "p1"], 0.0)
	var names := {"steady": {"p0": 1, "p1": 3}, "listener": {"p0": 3, "p1": 1}, "porter": {"p0": 3, "p1": 3}, "medic": {"p0": 3, "p1": 3}}
	for rollback: String in ["", "steady", "listener"]:
		var configured := rules.copy()
		if rollback == "steady":
			configured.steady_gaze = false
		elif rollback == "listener":
			configured.throwing_arm = false
		host.state = configured
		var world := host.world()
		var encoded := Protocol.enc_world(world)
		var map: Dictionary = encoded[Protocol.WORLD_FLOOR_EXTENSIONS_INDEX]
		t.check(encoded[Protocol.WORLD_SHOP_INDEX] is Array and Protocol.WORLD_FLOOR_EXTENSIONS_INDEX == 28,
			"the four independent feature keys follow the usual shop slot in the same index-28 dictionary")
		for key: String in names:
			t.eq(map.has(key), key != rollback, "encoded visibility of %s under rollback %s" % [key, rollback])
		for id: String in ["p0", "p1"]:
			var packet := Protocol.encode({"type": "welcome", "you": id, "seed": rules.seed, "playing": true, "evFrom": 0, "world": world})
			var received: Variant = Protocol.decode(packet)
			if not t.check(received != null and received.you == id, "the actual decoder accepts the named block for %s" % id):
				continue
			for key: String in names:
				if key == rollback:
					t.check(not received.world.has(key), "%s alone disappears on rollback" % key)
				else:
					t.eq(received.world.get(key), names[key], "%s retains both offers for peer %s under rollback %s" % [key, id, rollback])
