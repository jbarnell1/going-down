extends RefCounted

const Arb = preload("res://sim/arboretum.gd")
const Entity = preload("res://sim/entity.gd")
const Findables = preload("res://sim/findables.gd")
const Floor = preload("res://sim/floor.gd")
const Furniture = preload("res://sim/furniture.gd")
const HearingTests = preload("res://tests/prop_hearing.gd")
const Inventory = preload("res://sim/inventory.gd")
const Move = preload("res://sim/move.gd")
const Places = preload("res://sim/places.gd")
const Run = preload("res://sim/run.gd")
const SearchView = preload("res://client/search_view.gd")
const T = preload("res://tests/t.gd")

const CREW: Array[String] = ["solo"]
const DT := 0.05

static func stand(p: Furniture.Piece) -> Move.Body:
	var pt := Furniture.search_stand_cm(p)
	return Move.Body.make(pt.x / 100.0, pt.y / 100.0, p.level, 0.0)

static func facing(p: Furniture.Piece, at: Move.Body) -> float:
	return Entity.yaw_toward(p.x / 100.0 - at.x, p.y / 100.0 - at.z)

static func start(plan: Floor.FloorPlan, at: Move.Body, keeper: Move.Body, enabled := true) -> Run.RunState:
	var state := HearingTests.garden_run(CREW, {"solo": at}, keeper, true, plan)
	state = Run.with_inventory(Run.with_findables(state))
	return Run.with_garden_search(state) if enabled else state

static func step(s: Run.RunState, at: Move.Body, yaw: float, hold: bool, rush: bool) -> Run.RunStep:
	var i := HearingTests.input("solo", at, &"creep")
	i.yaw = yaw
	i.search = hold
	i.search_fast = rush
	return Run.step_run(s, HearingTests.one(i), DT)

func test_storage_seed_reach_and_site_types(t: T) -> void:
	var kinds := {}
	var n := 8 if t.quick else 35
	var minimum := 100
	var maximum := 0
	for k in n:
		var seed := "garden-storage-%s" % k
		var plan := Places.generate(seed, 5, Places.FULL, true)
		var ff := Findables.start_floor(plan, plan.seed, 5, 1770, &"listening", 1, [], true)
		var dist := Floor.distances_from(plan, plan.landing)
		minimum = mini(minimum, ff.pieces.size())
		maximum = maxi(maximum, ff.pieces.size())
		t.check(ff.pieces.size() >= 8 and ff.pieces.size() <= 16, "%s has 8 to 16 reachable storage pieces: %d" % [seed, ff.pieces.size()])
		t.check(Findables.spots_for(plan).is_empty(), "legacy garden has no searchable pieces")
		var repeat := Findables.spots_for(plan, plan.seed, 5, true)
		for p in ff.pieces:
			var at := stand(p)
			var y := facing(p, at)
			var found := Findables.piece_in_reach(ff, at, y)
			var c := Move.cell_of(plan, at)
			kinds[p.kind] = true
			t.check(found != null and found.id == p.id, "%s site %d: the real F reach check finds this storage" % [seed, p.id])
			t.check(Findables.piece_in_reach(ff, at, y + PI) == null, "turning away hides the search prompt")
			t.check(dist[Floor.pos_index(plan, c)] >= 4, "site has a route from the car")
			t.check(Move.clear_at(plan, Furniture.solids_of(plan), at.level, at.x, at.z, 0.30), "search stand is open at player clearance")
			t.check(p.hide == -1 and p.foot == (repeat[ff.pieces.find(p)] as Furniture.Piece).foot, "site has a stable footprint and is not a hide")
		t.check(ff.fill.cartons == 3 and ff.fill.notes == 3 and ff.fill.credits > 0, "real findables populate the garden")
	for kind: StringName in [&"garden_bin", &"garden_chest", &"garden_drawer", &"garden_bench"]:
		t.check(kinds.has(kind), "sample contains %s" % kind)
	t.note("%d floors, %d to %d pieces, four storage kinds" % [n, minimum, maximum])

func test_careful_and_rushed_search_noise(t: T) -> void:
	var plan := Places.generate("garden-storage-0", 5, Places.FULL, true)
	var p := Findables.spots_for(plan, "", -1, true)[0]
	var at := stand(p)
	var yaw := facing(p, at)
	for fast: bool in [false, true]:
		var keeper := Move.Body.make(at.x + 6.0, at.z, 0, 0.0)
		var s := start(plan, at, keeper)
		var r := step(s, at, yaw, true, fast)
		t.check(HearingTests.events_of(r.events, "searchStart").size() == 1, "host begins the requested search")
		t.eq(r.state.garden.keeper.mode, &"tilt" if fast else &"listening", "only rushed search is heard from 6 m at its start")
		if fast and r.state.garden.keeper.target != null:
			t.eq(r.state.garden.keeper.target.r, 8.0, "rushing carries exactly 8 m")
		if not fast:
			keeper = Move.Body.make(at.x + 3.5, at.z, 0, 0.0)
			r = step(start(plan, at, keeper), at, yaw, true, false)
			t.eq(r.state.garden.keeper.mode, &"listening", "careful search stays quiet while held")
			for _i in 52:
				r = step(r.state, at, yaw, true, false)
			t.eq(r.state.garden.keeper.mode, &"tilt", "opening is heard at 3.5 m")
			if r.state.garden.keeper.target != null:
				t.eq(r.state.garden.keeper.target.r, 4.0, "opening carries exactly 4 m")

func test_storage_uses_normal_inventory_and_open_view(t: T) -> void:
	var plan := Places.generate("garden-storage-0", 5, Places.FULL, true)
	var ff := Findables.start_floor(plan, plan.seed, 5, Run.floor_quota(5, 1), &"listening", 1, [], true)
	var carton: Furniture.Piece = null
	for p in ff.pieces:
		if ff.fill.contents[p.id]["what"] == "juice":
			carton = p
			break
	if not t.check(carton != null, "seed contains storage with juice"):
		return
	var at := stand(carton)
	var yaw := facing(carton, at)
	var keeper := Move.Body.make(at.x + 30.0, at.z, 0, 0.0)
	var off := step(start(plan, at, keeper, false), at, yaw, true, false)
	t.check(off.state.find == null and off.events.is_empty(), "garden search flag off leaves no state and events")
	var s := start(plan, at, keeper)
	var r: Run.RunStep
	for _i in 53:
		r = step(s, at, yaw, true, false)
		s = r.state
	var bag := Inventory.bag_of(s.bags, "solo")
	t.eq(bag.item(0), "juice", "the standard inventory carries a garden find from empty hands")
	t.check((s.find as Findables.FindFloor).opened.has(carton.id), "host marks the storage open")
	var view := SearchView.new()
	view.use_plan(plan, true)
	var root := Node3D.new()
	var opened := Findables.opened_rows(s.find as Findables.FindFloor)
	view.show_opened(root, {"opened": opened})
	t.eq(view.open_drawn(), [carton.id], "client draws the host's opened garden piece")
	t.check(root.has_node("Storage%d" % carton.id) and not (root.get_node("Storage%d/Shut" % carton.id) as Node3D).visible,
		"opened storage keeps its body while the closed lid is hidden")
	root.free()
