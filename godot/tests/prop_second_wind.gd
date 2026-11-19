extends RefCounted

const T = preload("res://tests/t.gd")
const Host = preload("res://net/host.gd")
const HostRules = preload("res://net/host_rules.gd")
const Transport = preload("res://net/transport.gd")
const Profiles = preload("res://net/profiles.gd")
const Save = preload("res://net/save_slip.gd")
const Run = preload("res://sim/run.gd")
const Noises = preload("res://sim/noise.gd")
const Move = preload("res://sim/move.gd")
const Stamina = preload("res://sim/stamina.gd")
const Shop = preload("res://sim/shop.gd")
const Upgrades = preload("res://sim/upgrades.gd")
const Places = preload("res://sim/places.gd")
const Cabinet = preload("res://tests/prop_cabinet.gd")
const ShopTest = preload("res://tests/prop_shop.gd")

func test_purchase_has_fixed_price_and_undo_only_latest(t: T) -> void:
	var ids := Cabinet.ids_of(1)
	var home := Cabinet.home_run("second-wind-buy", ids)
	home = Run.with_deep_pockets(ShopTest.with_credits(home, {"p0": 1500}))
	var window := {"p0": ShopTest.window(home, 3)}
	var off := Cabinet.tick(home, window, {"p0": ["skill", 2]})
	t.eq(ShopTest.credits_of(off.state, "p0"), 1500, "off cannot buy Second Wind")
	var hands := Cabinet.tick(Run.with_second_wind(home), window, {"p0": ["skill", 0]}).state
	var wind := Cabinet.tick(hands, window, {"p0": ["skill", 2]}).state
	var wallet: Upgrades.UpgradeState = wind.wallets["p0"]
	t.eq(wallet.credits, 300, "one share for each induction even when another is owned")
	t.eq(wallet.owned, ["deep_pockets", "second_wind"], "two different first-layer branches allowed")
	var fields := Profiles.collect(wind, "p0", Save.fresh("0123456789abcdef"), "Ana", false)
	var key := PackedByteArray()
	key.resize(32)
	var opened := Save.open(Save.seal(fields, key), key)
	t.check(opened.ok and opened.fields.training_node == "second_wind", "the pending node and one-share refund are signed")
	var restored := Profiles.restore(wind, "p0", opened.fields)
	var undo := Cabinet.tick(restored, window, {"p0": ["skill", 1]}).state
	t.eq((undo.wallets["p0"] as Upgrades.UpgradeState).owned, ["deep_pockets"], "undo only refunds the latest node")

func test_host_spends_only_winded_owner_and_resets_on_next_floor(t: T) -> void:
	var ids := Cabinet.ids_of(2)
	var net := Transport.MemoryNetwork.new("second-wind-tank")
	var host := Host.new(net.connect_peer("host"), "second-wind-tank", ids, 0.0)
	var s := Run.with_second_wind(host.state)
	s.phase = &"away"
	var fields := Save.fresh("0123456789abcdef")
	fields.nodes = ["second_wind"]
	var key := PackedByteArray()
	key.resize(32)
	var stamp := Save.seal(fields, key)
	var profiles := Profiles.new(key)
	profiles.join("p0", "Ana", stamp)
	host.state = profiles.apply_for(s, "p0", "Ana")
	var a: Host.HostPlayer = host._players["p0"]
	var b: Host.HostPlayer = host._players["p1"]
	_ready(a)
	_ready(b)
	b.stamina = Stamina.Stamina.make(0.0, true)
	a.inv_pending = [&"skill", 3]
	b.inv_pending = [&"skill", 3]
	host._step(Host.TICK)
	t.eq(_gasps(host), 0, "full owner and winded non-owner cannot activate")
	a.stamina = Stamina.Stamina.make(0.05, true)
	a.inv_pending = [&"skill", 3]
	host._step(2 * Host.TICK)
	t.check(a.stamina.level == 1.0 and not a.stamina.winded, "accepted winded owner instantly refills")
	t.eq(_gasps(host), 1, "accepted use makes one host event")
	a.stamina = Stamina.Stamina.make(0.05, true)
	a.inv_pending = [&"skill", 3]
	host._step(3 * Host.TICK)
	t.check(a.stamina.winded and a.stamina.level == 0.05, "a second request on that floor cannot refill")
	t.eq(_gasps(host), 1, "no duplicated gasp")
	profiles.leave("p0")
	profiles.join("new-peer", "Ana", stamp)
	var rejoined := profiles.apply_for(host.state, "new-peer", "Ana")
	t.check(not Run.can_second_wind(rejoined, "new-peer"), "same signed profile cannot reset charge by reconnecting")
	host.state.depth += 1
	t.check(Run.can_second_wind(host.state, "p0"), "a new floor gives the charge back")

func test_gasp_uses_the_live_vocal_radius_and_keeps_one_noise(t: T) -> void:
	var body := Move.Body.make(15.0, 0.0, 0, 0.0)
	var prior := Move.Body.make(14.7, 0.0, 0, 0.0)
	var act := Noises.Act.make("p0", body, prior, &"sprint")
	act.gasp_radius = 20.0
	var gasp := Noises.of(null, act, Host.TICK, {})
	t.check(gasp.kind == &"emote" and gasp.r == 20.0, "gasp participates in the existing one-noise vocal class")
	t.check(Noises.heard_at(gasp, 0.0, 0.0, 0) and not Noises.heard_at(gasp, 0.0, 0.0, 1), "same-level hearing boundary")

func test_groundskeeper_applies_the_live_vocal_radius(t: T) -> void:
	var ids := Cabinet.ids_of(1)
	var rules := HostRules.new(true, 5, Places.FULL)
	var garden := rules.prepare(Run.create_run("second-wind-hearing", ids))
	Run._sync_garden(garden)
	if not t.check(garden.garden != null, "generated a normal Arboretum resident"):
		return
	var keeper := garden.garden.keeper.body
	var body := Move.Body.make(keeper.x + 16.0, keeper.z, keeper.level, keeper.y)
	var inp := Cabinet.inp("p0", body)
	inp.wind_gasp = true
	var players: Array[Run.RunPlayer] = [garden.players[0].copy()]
	players[0].body = body
	var events: Array[Dictionary] = []
	var quiet := Run.with_tuning(garden, {"noise.emote": 15.0})
	Run._step_garden(quiet, players, {"p0": inp}, quiet.t, quiet.t + Host.TICK, Host.TICK, events, 0)
	t.check(Cabinet.of_type(events, "keeperTilt").is_empty(), "sixteen metres lies outside the tuned fifteen")
	events.clear()
	var loud := Run.with_tuning(garden, {"noise.emote": 19.0})
	Run._step_garden(loud, players, {"p0": inp}, loud.t, loud.t + Host.TICK, Host.TICK, events, 0)
	t.check(Cabinet.of_type(events, "keeperTilt").size() == 1, "same gasp is heard at the tuned nineteen")

static func _ready(p: Host.HostPlayer) -> void:
	p.connected = true
	p.input = {"seeing": false, "eye": 1.65, "yaw": 0.0, "pitch": 0.0, "hFovDeg": 90.0,
		"vFovDeg": 70.0, "raised": false, "holdDoors": false, "renderTime": 0.0}

static func _gasps(host: Host) -> int:
	var n := 0
	for event: Host.LoggedEvent in host.event_log:
		if event.e.type == "secondWind":
			n += 1
	return n
