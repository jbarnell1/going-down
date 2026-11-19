extends RefCounted

const Arboretum = preload("res://sim/arboretum.gd")
const Cones = preload("res://sim/garden_cones.gd")
const Floor = preload("res://sim/floor.gd")
const Furniture = preload("res://sim/furniture.gd")
const HearingTests = preload("res://tests/prop_hearing.gd")
const HostRules = preload("res://net/host_rules.gd")
const Instr = preload("res://sim/instrument.gd")
const Inventory = preload("res://sim/inventory.gd")
const InventoryTests = preload("res://tests/prop_inventory.gd")
const Move = preload("res://sim/move.gd")
const Places = preload("res://sim/places.gd")
const Run = preload("res://sim/run.gd")
const T = preload("res://tests/t.gd")
const CabinetTests = preload("res://tests/prop_cabinet.gd")
const ShopTests = preload("res://tests/prop_shop.gd")
const Shop = preload("res://sim/shop.gd")
const Protocol = preload("res://net/protocol.gd")

const DT := 0.05
const CREW: Array[String] = ["a"]

func test_seeded_placements_are_reachable_under_conifers(t: T) -> void:
	for n in (8 if t.quick else 35):
		var plan := Places.generate("cones-%d" % n, 5, Places.FULL, true)
		var picks := Cones.placements(plan)
		t.check(picks.size() >= 10 and picks.size() <= 16, "10 to 16 cones on floor %d: %d" % [n, picks.size()])
		var d := Floor.distances_from(plan, plan.landing)
		var repeat := Cones.placements(plan)
		var visited := {}
		var trees := {}
		for piece in Furniture.pieces_for(plan):
			if piece.kind == &"trunk" and Arboretum.is_conifer(piece.x, piece.y):
				trees[Vector2i(piece.x / 200, piece.y / 200)] = true
		for j in picks.size():
			var at := picks[j]
			var cell := Move.cell_of(plan, at)
			var xy := Vector2i(cell.x, cell.y)
			t.check(trees.has(xy) and not visited.has(xy), "cone is under a conifer in a distinct cell")
			visited[xy] = true
			t.check(d[cell.y * Arboretum.W + cell.x] >= 0, "cone can be reached")
			t.check(Move.clear_at(plan, Furniture.solids_of(plan), 0, at.x, at.z, 0.28), "cone is clear of solid props")
			t.check(HearingTests.flat(at, repeat[j]) < 0.001, "same seed, same cone")
		if not picks.is_empty():
			var first := Move.cell_of(plan, picks[0])
			t.check(d[first.y * Arboretum.W + first.x] <= 12, "find the first cone near the lift")

func test_solo_throw_is_consumed_at_release_and_heard_at_impact(t: T) -> void:
	var start := HearingTests.at(31.0, 31.0)
	var keeper := HearingTests.at(38.0, 29.0)
	var s := HearingTests.garden_run(CREW, {"a": start}, keeper)
	s = Run.with_garden_cones(Run.with_inventory(s))
	s.pickups_plan = s.plan
	s.pickups = [Inventory.Pickup.make(1, Cones.ITEM, 1, start)]
	var i := HearingTests.input("a", start, &"creep", true)
	i.yaw = -PI * 0.5
	i.inv_op = &"take"
	i.inv_arg = 1
	var r := Run.step_run(s, HearingTests.one(i), DT)
	s = r.state
	t.eq(Inventory.bag_of(s.bags, "a").item(0), Cones.ITEM, "the host lets the solo player pick the cone up")
	t.check(s.pickups.is_empty() and HearingTests.events_of(r.events, "itemTaken").size() == 1, "the pickup leaves the floor once")
	i.inv_op = &"throw"
	i.inv_arg = 90000
	r = Run.step_run(s, HearingTests.one(i), DT)
	s = r.state
	var thrown := HearingTests.events_of(r.events, "coneThrown")
	if not t.check(thrown.size() == 1, "a cone in the selected slot can be thrown"):
		return
	var at: Move.Body = thrown[0]["at"]
	t.check(absf(at.x - 43.0) < 0.001, "open throw follows yaw for 12 m; request argument cannot set destination")
	t.check(absf(at.z - 31.0) < 0.001, "aim stays on the line of the throw")
	t.check(Inventory.bag_of(s.bags, "a").is_empty(), "the selected cone was consumed")
	t.check(s.garden.keeper.mode == &"listening" and HearingTests.events_of(r.events, "coneLanded").is_empty(), "throw is silent before landing")
	# A repeated request with empty hands cannot start or create a second decoy.
	r = Run.step_run(s, HearingTests.one(i), DT)
	s = r.state
	t.check(HearingTests.events_of(r.events, "coneThrown").is_empty() and s.garden.cones_in_flight.size() == 1, "no second throw without a cone")
	i.inv_op = &""
	var count := 0
	var recorded := false
	for step in 60:
		r = Run.step_run(s, HearingTests.one(i), DT)
		s = r.state
		for e in HearingTests.events_of(r.events, "coneLanded"):
			count += 1
			t.check(absf(float(e["x"]) - at.x) < 0.001, "impact is at the authoritative endpoint")
			t.check(s.garden.keeper.mode == &"tilt", "keeper first hears on the impact tick")
			if s.garden.keeper.target != null:
				t.check(absf(s.garden.keeper.target.r - 12.0) < 0.001, "impact radius is 12 m")
				t.check(absf(s.garden.keeper.target.x - at.x) < 0.001, "keeper hears the impact, not the thrower")
				t.eq(s.garden.keeper.target.by, "", "the decoy cannot name a player as the noise source")
		recorded = recorded or (s.garden.keeper.mode == &"coming" and Instr.member(s.crew, "a").instrument.rate > 0)
	t.eq(count, 1, "one landed event per throw")
	t.check(recorded, "solo player records the Groundskeeper while it travels to the impact")
	t.eq(s.players[0].status, &"ok", "solo player is safe away from the landing point")

func test_wall_stops_a_throw_and_a_disabled_run_cannot_throw(t: T) -> void:
	var plan := HearingTests.striped()
	var low := HearingTests.at(10.0, 6.0)
	var at := Cones.landing(plan, null, low, 0.0, 0.0)
	t.check(at.z >= 4.0 and at.z < low.z, "the ground ends at the outer wall")
	var rules := HostRules.new(true, 5, Places.FULL, false, false, false, false, false, false, false, false, false, false, false, true, false, true)
	var s := rules.prepare(Run.create_run("no-cones", CREW))
	t.check(not s.garden_cones, "the appended HostRules flag defaults off with the inventory on")
	s = HearingTests.garden_run(CREW, {"a": HearingTests.at(31.0, 31.0)}, HearingTests.at(45.0, 31.0))
	s = Run.with_inventory(s)
	var i := HearingTests.input("a", s.players[0].body)
	var no_request := Run.step_run(s, HearingTests.one(i), DT)
	i.inv_op = &"throw"
	var forged := Run.step_run(s, HearingTests.one(i), DT)
	t.check(forged.state.pickups.is_empty(), "flag off generates no natural cones")
	t.eq(no_request.state.garden.keeper.mode, forged.state.garden.keeper.mode, "a disabled throw cannot create a noise")
	t.eq(no_request.events, forged.events, "a disabled throw has no events")
	t.check(HearingTests.events_of(forged.events, "coneThrown").is_empty(), "flag off sends no cone events")
	s = InventoryTests.with_bags(forged.state, {"a": [["juice", 1]]})
	var fake := Run.step_run(Run.with_garden_cones(s), HearingTests.one(i), DT)
	t.eq(Inventory.bag_of(fake.state.bags, "a").item(0), "juice", "a throw cannot fabricate a cone from juice")
	t.check(HearingTests.events_of(fake.events, "coneThrown").is_empty(), "fake cone cannot generate a projectile")

func test_shop_uses_its_slot_and_the_garden_hears_its_toy(t: T) -> void:
	t.eq(Inventory.ITEMS, ["juice", "badge", "marker", "glow", "flash", "speed", "toy", "salts", "pinecone"], "shop item wire indexes are stable")
	t.eq(Protocol.INV_OPS, ["", "drop", "take", "give", "stash", "fetch", "buy", "use", "throw", "skill"], "shop operation wire indexes are stable")
	var home := ShopTests.with_credits(CabinetTests.home_run("garden-shop", ["a"] as Array[String]), {"a": 500})
	var counter: Move.Body = ShopTests.window(home, 1)
	var bought := CabinetTests.tick(home, {"a": counter}, {"a": ["buy", Shop.ITEMS.find("toy")]})
	var bag := Inventory.bag_of(bought.state.bags, "a")
	t.eq(bag.item(0), "toy", "buy puts the paid toy in the buyer's selected bag")
	t.eq(ShopTests.credits_of(bought.state, "a"), 500 - Shop.price(home.tuning, "toy"), "buy debits the same wallet")
	var body := HearingTests.at(31.0, 31.0)
	var state := HearingTests.garden_run(CREW, {"a": body}, HearingTests.at(38.0, 31.0))
	state = Run.with_garden_cones(Run.with_shop(Run.with_inventory(state)))
	state.bags = bought.state.bags
	var i := HearingTests.input("a", body, &"creep")
	i.inv_op = &"use"
	var used := Run.step_run(state, HearingTests.one(i), DT)
	t.check(Inventory.bag_of(used.state.bags, "a").is_empty() and HearingTests.events_of(used.events, "itemUsed").size() == 1,
		"use consumes the toy without touching the cone operation")
	t.eq(used.state.garden.keeper.mode, &"listening", "the toy is silent until its rattle")
	i.inv_op = &""
	var r := used
	for _n in ceili(Shop.TOY_WAIT / DT) + 1:
		r = Run.step_run(r.state, HearingTests.one(i), DT)
	var target := r.state.garden.keeper.target
	t.check(target != null and absf(target.x - body.x) < 0.01 and target.r == Shop.TOY_RADIUS and target.by == "",
		"keeper hears the purchased toy's declared radius at where it was set down")

func test_ordinary_shop_run_keeps_garden_features_off(t: T) -> void:
	var rules := HostRules.new(true, 5, Places.BEFORE_ARBORETUM, true, true, true, false, true, true, true,
		true, true, true, true, true, true, true, true, true, true, false, true, true)
	var s := rules.prepare(Run.create_run("ordinary-shop", CREW, Places.BEFORE_ARBORETUM))
	t.check(s.shop and s.inventory and s.findables, "ordinary deck still gets shop, inventory and findables")
	t.check(not s.garden_search and not s.garden_cones and s.plan.place != Places.ARBORETUM,
		"asking for garden support cannot change the ordinary deck")
	var legacy := Places.generate(s.seed, 5, Places.BEFORE_ARBORETUM)
	t.eq(Floor.hash_plan(s.plan), Floor.hash_plan(legacy), "ordinary seeded geometry remains identical")
