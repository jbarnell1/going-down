extends RefCounted

const T = preload("res://tests/t.gd")
const Cabinet = preload("res://tests/prop_cabinet.gd")
const ShopTest = preload("res://tests/prop_shop.gd")
const Run = preload("res://sim/run.gd")
const Shop = preload("res://sim/shop.gd")
const Upgrades = preload("res://sim/upgrades.gd")
const Profiles = preload("res://net/profiles.gd")
const Save = preload("res://net/save_slip.gd")
const Move = preload("res://sim/move.gd")
const Noises = preload("res://sim/noise.gd")
const Hearing = preload("res://sim/hearing.gd")
const HostRules = preload("res://net/host_rules.gd")
const Places = preload("res://sim/places.gd")

func test_ear_induction_costs_one_share_without_prerequisites(t: T) -> void:
	var ids := Cabinet.ids_of(2)
	var home := Run.with_deep_pockets(ShopTest.with_credits(Cabinet.home_run("soft-shoes-buy", ids), {"p0": 1800, "p1": 599}))
	var desks := {"p0": ShopTest.window(home, 3), "p1": ShopTest.window(home, 4)}
	var ask := {"p0": ["skill", 4], "p1": ["skill", 4]}
	var off := Cabinet.tick(home, desks, ask)
	t.eq(ShopTest.credits_of(off.state, "p0"), 1800, "flag off changes no balance")
	var shoes := Cabinet.tick(Run.with_soft_shoes(home), desks, ask)
	t.eq(ShopTest.credits_of(shoes.state, "p0"), 1200, "one share debited")
	t.eq(ShopTest.credits_of(shoes.state, "p1"), 599, "insufficient funds leave the full balance")
	t.eq((shoes.state.wallets["p0"] as Upgrades.UpgradeState).owned, ["soft_shoes"], "Ear induction needs no other skill")
	var replay := Cabinet.tick(shoes.state, desks, ask)
	t.eq(ShopTest.credits_of(replay.state, "p0"), 1200, "repeat purchase never debits again")
	t.eq(Cabinet.of_type(replay.events, "trained").size(), 0, "repeat emits no purchase")
	var other := Cabinet.tick(Run.with_second_wind(replay.state), desks, {"p0": ["skill", 2]})
	t.eq(ShopTest.credits_of(other.state, "p0"), 600, "the next induction still costs exactly one share")
	var fields := Profiles.collect(shoes.state, "p0", Save.fresh("0123456789abcdef"), "Ana", false)
	var key := PackedByteArray()
	key.resize(32)
	var sealed := Save.open(Save.seal(fields, key), key)
	if not t.check(sealed.ok and sealed.fields.training_node == "soft_shoes", "signed pending Ear refund persists"):
		return
	var resumed := Profiles.restore(shoes.state, "p0", sealed.fields)
	var undone := Cabinet.tick(resumed, desks, {"p0": ["skill", 1]})
	t.eq(ShopTest.credits_of(undone.state, "p0"), 1800, "undo refunds precisely one share")

func test_only_walking_and_creeping_footsteps_are_smaller(t: T) -> void:
	var before := Move.Body.make(0.0, 0.0, 0, 0.0)
	var after := Move.Body.make(0.25, 0.0, 0, 0.0)
	var actor := Noises.Act.make("p0", after, before, &"walk")
	var ordinary := Noises.of(null, actor, Cabinet.DT, {})
	actor.soft_shoes = true
	var walk := Noises.of(null, actor, Cabinet.DT, {})
	t.check(is_equal_approx(walk.r, 7.5) and is_equal_approx(walk.r, ordinary.r * 0.75), "gravel walk carries 7.5 m")
	actor.gait = &"creep"
	t.check(is_equal_approx(Noises.of(null, actor, Cabinet.DT, {}).r, 1.875), "gravel creep carries 1.875 m")
	actor.gait = &"sprint"
	t.eq(Noises.of(null, actor, Cabinet.DT, {}).r, Noises.SPRINT, "sprint stays at full range")
	actor.down = true
	t.eq(Noises.of(null, actor, Cabinet.DT, {}).r, Noises.CRAWL, "crawling stays at full range")
	actor.down = false
	actor.gait = &"walk"
	actor.emote = true
	t.eq(Noises.of(null, actor, Cabinet.DT, {}).r, Noises.EMOTE, "an emote wins without being softened")
	actor.emote = false
	actor.gasp_radius = 19.0
	t.eq(Noises.of(null, actor, Cabinet.DT, {}).r, 19.0, "Second Wind keeps its own gasp radius")

func test_groundskeeper_hears_the_same_walker_only_without_the_skill(t: T) -> void:
	var ids := Cabinet.ids_of(1)
	var rules := HostRules.new(true, 5, Places.FULL)
	var s := rules.prepare(Run.create_run("soft-shoes-hearing", ids))
	Run._sync_garden(s)
	var at := _outside_lift(s)
	var ground: Noises.Ground = s.plan.ground
	var walk := Noises.gait_radius(&"walk", ground.surface_at(at.x, at.z))
	var centre := Move.Body.make(at.x + walk * 0.875, at.z, at.level, at.y)
	s.garden.keeper = Hearing.create(centre, 0.0)
	s.garden.keeper.last = {"p0": Move.Body.make(at.x - 0.2, at.z, at.level, at.y)}
	s.wallets = {"p0": Upgrades.buy_induction(Upgrades.UpgradeState.make(1800), "soft_shoes", Shop.SHARE).state}
	var rival: Array[Run.RunPlayer] = [s.players[0].copy()]
	rival[0].body = at
	var input := Cabinet.inp("p0", at)
	input.gait = &"walk"
	var events: Array[Dictionary] = []
	var loud := s.copy()
	Run._step_garden(loud, rival, {"p0": input}, loud.t, loud.t + Cabinet.DT, Cabinet.DT, events, 0)
	t.eq(Cabinet.of_type(events, "keeperTilt").size(), 1, "disabled skill leaves a walking player audible at the test distance")
	events.clear()
	var trained := Run.with_soft_shoes(s)
	Run._step_garden(trained, rival, {"p0": input}, trained.t, trained.t + Cabinet.DT, Cabinet.DT, events, 0)
	t.eq(Cabinet.of_type(events, "keeperTilt").size(), 0, "trained walk at the same distance is outside hearing range")
	var creep := Noises.gait_radius(&"creep", ground.surface_at(at.x, at.z))
	centre = Move.Body.make(at.x + creep * 0.875, at.z, at.level, at.y)
	s.garden.keeper = Hearing.create(centre, 0.0)
	s.garden.keeper.last = {"p0": Move.Body.make(at.x - 0.2, at.z, at.level, at.y)}
	input.gait = &"creep"
	events.clear()
	loud = s.copy()
	Run._step_garden(loud, rival, {"p0": input}, loud.t, loud.t + Cabinet.DT, Cabinet.DT, events, 0)
	t.eq(Cabinet.of_type(events, "keeperTilt").size(), 1, "ordinary creep is still audible just inside its smaller range")
	events.clear()
	trained = Run.with_soft_shoes(s)
	Run._step_garden(trained, rival, {"p0": input}, trained.t, trained.t + Cabinet.DT, Cabinet.DT, events, 0)
	t.eq(Cabinet.of_type(events, "keeperTilt").size(), 0, "trained creep is quieter without becoming generically silent")

static func _outside_lift(s: Run.RunState) -> Move.Body:
	var start := s.players[0].body
	var ground: Noises.Ground = s.plan.ground
	for x in range(-6, 7):
		for z in range(-6, 7):
			var at := Move.Body.make(start.x + x, start.z + z, start.level, start.y)
			if not Run.in_car(s.car, at) and ground.surface_at(at.x, at.z) == Noises.GRAVEL and ground.fall_at(at.x, at.z) < 0:
				return at
	return start
