extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Cabinet = preload("res://tests/prop_cabinet.gd")
const Shop = preload("res://tests/prop_shop.gd")
const Upgrades = preload("res://sim/upgrades.gd")
const Inventory = preload("res://sim/inventory.gd")
const Save = preload("res://net/save_slip.gd")
const Profiles = preload("res://net/profiles.gd")
const Protocol = preload("res://net/protocol.gd")
const Host = preload("res://net/host.gd")
const Transport = preload("res://net/transport.gd")
const Move = preload("res://sim/move.gd")
const Rng = preload("res://sim/rng.gd")
const Watch = preload("res://tests/prop_watchers.gd")
const Entity = preload("res://sim/entity.gd")
const Floor = preload("res://sim/floor.gd")

func test_ordinary_campaign_admits_steady_gaze_and_rollback_is_independent(t: T) -> void:
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
	t.check(local.steady_gaze and room.steady_gaze, "normal full deck admits Steady Gaze")
	room.configure_campaign_trades({"steady_gaze": "0"})
	game._steady_gaze = false
	game._configure_campaign_trades(local)
	t.check(not local.steady_gaze and not room.steady_gaze, "explicit rollback disables only Steady Gaze")
	t.check(local.field_dressing and room.field_dressing and local.long_burn and room.long_burn
		and local.quick_fingers and room.quick_fingers and local.badge_search and room.badge_search,
		"Medic, Porter, Long Burn and badges stay available")
	game._steady_gaze = true
	Session.deck = Places.CLINIC_ONLY
	game._configure_campaign_trades(local)
	t.check(not local.steady_gaze and not HostRules.new(true, 1).steady_gaze, "reference deck and direct host rule stay off")
	Session.deck = original
	game.free()

func test_signed_lamplighter_trade_spends_badges_and_locks_other_branches(t: T) -> void:
	var home := Shop.with_credits(Cabinet.home_run("steady-window", ["p0", "p1"]), {"p0": 2000, "p1": 2000})
	home = Run.with_steady_gaze(Run.with_long_burn(Run.with_deep_pockets(home)))
	var positions := {"p0": Shop.window(home, 3), "p1": Shop.window(home, 4)}
	home = Cabinet.with_bags(home, {"p0": [["badge", 1], ["badge", 1]], "p1": [["badge", 1], ["badge", 1]]})
	var trade := {"p0": ["skill", 8], "p1": ["skill", 8]}
	var refused := Cabinet.of_type(Cabinet.tick(home, positions, trade).events, "invRefused")
	t.eq(refused.map(func(e: Dictionary) -> String: return str(e.why)), ["needs", "needs"], "both players need Long Burn")
	home = Cabinet.tick(home, positions, {"p0": ["skill", 6], "p1": ["skill", 6]}).state
	home.wallets.p1.owned.append("field_dressing")
	var trade_result := Cabinet.tick(home, positions, trade)
	var bought := trade_result.state
	var locked := Cabinet.of_type(trade_result.events, "invRefused")
	t.eq(locked.map(func(e: Dictionary) -> String: return str(e.why)), ["trade"], "the existing Medic cannot become a Lamplighter")
	t.eq(Inventory.bag_of(bought.bags, "p1").totals().get("badge"), 2, "refused crewmate retains both badges")
	t.eq(Shop.credits_of(bought, "p0"), 1400, "paid only 600 credits for Long Burn")
	t.eq(Inventory.bag_of(bought.bags, "p0").totals().get("badge", 0), 0, "Steady Gaze itself paid two badges")
	t.eq(Upgrades.trade_of(bought.wallets.p0.owned), "Lamplighter", "the trade identity is durable")
	var secret := PackedByteArray()
	secret.resize(32)
	var profile := Profiles.collect(bought, "p0", Save.fresh("984560123456abcd"), "Lamp", false)
	var signed := Save.open(Save.seal(profile, secret), secret)
	t.check(signed.ok and signed.fields.nodes.has("steady_gaze") and signed.fields.training_refund == 0,
		"the signed profile retains the refundable badge trade")
	var undone := Cabinet.tick(bought, positions, {"p0": ["skill", 1]}).state
	t.eq(Inventory.bag_of(undone.bags, "p0").totals().get("badge"), 2, "undo returns both badges atomically")
	t.eq(Upgrades.trade_of(undone.wallets.p0.owned), "", "undo releases that branch lock")
	var writable := Transport.MemoryNetwork.new("steady-wire")
	var host := Host.new(writable.connect_peer("host"), "steady-wire", ["p0", "p1"], 0.0)
	t.check(not host.world().has("steady"), "legacy reference has no Steady Gaze map")
	host.state = bought
	var wire: Variant = Protocol.decode(Protocol.encode({"type": "welcome", "you": "p0", "seed": "steady-wire", "playing": true, "evFrom": 0, "world": host.world()}))
	t.check(wire != null and wire.world.steady == {"p0": 2, "p1": 3}, "each peer sees the authoritative trade offer")

static func _stage() -> Run.RunState:
	for index in 40:
		var seed := "steady-%d" % index
		var staged := Watch.stage(seed, 1, Rng.make_rng(seed), 3, 4.0, 10.0)
		if staged.is_empty():
			continue
		var s := Run.create_run(seed, ["p0", "p1", "p2"])
		s = Run.with_steady_gaze(Run.with_long_burn(Run.with_shop(Run.with_inventory(Run.with_two_watchers(Run.with_lamp(s))))))
		s.plan = staged[0]
		s.orderly = staged[1]
		for i in s.players.size():
			s.players[i].body = staged[2][i]
		var wallet := Upgrades.UpgradeState.make()
		wallet.owned.assign(["long_burn", "steady_gaze"])
		s.wallets.p0 = wallet
		s.phase = &"away"
		return s
	return null

static func _inputs(s: Run.RunState, turn := false, move := false) -> Array[Run.PlayerInput]:
	var a: Array[Run.PlayerInput] = []
	var target := s.orderly.body
	for p in s.players:
		var yaw := Entity.yaw_toward(target.x - p.body.x, target.z - p.body.z)
		var body := Move.Body.make(p.body.x + 0.05, p.body.z, p.body.level, p.body.y) if p.id == "p0" and move else p.body
		var i := Run.PlayerInput.make(p.id, body, 1.65, yaw + (PI if p.id != "p0" or turn else 0.0), 0.0, 90.0, 70.0)
		if p.id == "p0":
			i.inv_op = &"lamp"
			i.inv_arg = 1
		a.append(i)
	return a

func test_steady_gaze_counts_twice_only_from_stationary_aimed_light(t: T) -> void:
	var staged := _stage()
	if not t.check(staged != null, "a seeded, three-player Clinic has valid nonoverlapping light positions"):
		return
	var sight := Run.step_run(staged, _inputs(staged), Cabinet.DT).state
	t.eq(sight.orderly.need, 2, "real three-player threshold")
	t.eq(sight.orderly.watchers, ["p0", "p0"], "the directed lamp from a stationary Lamplighter counts twice")
	t.check(sight.orderly.held and not sight.orderly.moving, "host genuinely holds the resident")
	for fixture: String in ["rollback", "movement", "look-away", "lamp off", "different owner", "out of range"]:
		var base := _stage()
		var input := _inputs(base, fixture == "look-away", fixture == "movement")
		match fixture:
			"rollback": base.steady_gaze = false
			"lamp off": input[0].inv_arg = 0
			"different owner":
				input[0].inv_arg = 0
				input[1].inv_op = &"lamp"
				input[1].inv_arg = 1
			"out of range":
				base.orderly = base.orderly.copy()
				base.orderly.body = Move.Body.make(base.players[0].body.x + 18.0, base.players[0].body.z, base.players[0].body.level, base.players[0].body.y)
				input = _inputs(base)
		var r := Run.step_run(base, input, Cabinet.DT).state
		t.check(r.orderly.watchers.count("p0") <= 1 and not r.orderly.held, "%s has no doubled watch or freeze" % fixture)
	var walled := _stage()
	var eye := walled.players[0].body
	var wall_found := false
	var distances := Floor.distances_from(walled.plan, Move.cell_of(walled.plan, eye))
	for cell in distances.size():
		if distances[cell] < 0:
			continue
		var body := Move.body_at_cell(walled.plan, Floor.pos_from_index(walled.plan, cell))
		var meters := Watch.flat(eye, body)
		if body.level != eye.level or meters < 4.0 or meters > 10.0 or Watch.sees(walled.plan, Watch.facing("p0", eye, body), body):
			continue
		wall_found = true
		walled.orderly = walled.orderly.copy()
		walled.orderly.body = body
		break
	if t.check(wall_found, "a walkable cell behind a wall lies within the beam's range"):
		var blocked := Run.step_run(walled, _inputs(walled), Cabinet.DT).state
		t.check(not blocked.orderly.held and blocked.orderly.watchers.count("p0") == 0, "the wall prevents even one watch")
	var no_lamp := _stage()
	no_lamp.lamp = false
	no_lamp.shop_state.flashes.p0 = 1.0
	var flash := Run.step_run(no_lamp, _inputs(no_lamp), Cabinet.DT).state
	t.eq(flash.orderly.watchers, ["p0", "p0"], "the active shop flash qualifies without ambient or carried lamp")
	var release_at := sight.t
	while sight.t < release_at + Entity.GRACE + 0.1:
		var looking_away := _inputs(sight, true)
		sight = Run.step_run(sight, looking_away, Cabinet.DT).state
	t.check(not sight.orderly.held and sight.orderly.watchers.count("p0") == 0, "turning away releases the hold after normal grace")
