# The Arboretum's roosting birds (sim/dangers/roost.gd, client/dangers/roost_view.gd). A passive danger: walk or
# sprint under a roost and it goes up, one loud noise at the tree made by nobody; creep, stand, hide or go round and
# nothing happens; a pinecone landing under it sends it up from afar. These tests hold it to that and to the
# dangers' common rules: off changes nothing, the same seed makes the same roosts (here and in a fresh process), a
# careful way round always exists, it is heard before it costs anything, it never takes anyone down, the
# Groundskeeper's own rule is untouched, and every number is a live setting.
#
# Breaks used to prove each check can fail: the rules' test_break names (sim/dangers/roost.gd), listed by each test.
extends RefCounted

const T = preload("res://tests/t.gd")
const Roost = preload("res://sim/dangers/roost.gd")
const Api = preload("res://sim/dangers/api.gd")
const Dangers = preload("res://sim/dangers.gd")
const Arboretum = preload("res://sim/arboretum.gd")
const Floor = preload("res://sim/floor.gd")
const Furniture = preload("res://sim/furniture.gd")
const GardenCones = preload("res://sim/garden_cones.gd")
const HostRules = preload("res://net/host_rules.gd")
const Hearing = preload("res://sim/hearing.gd")
const Move = preload("res://sim/move.gd")
const Noises = preload("res://sim/noise.gd")
const Places = preload("res://sim/places.gd")
const Rng = preload("res://sim/rng.gd")
const Run = preload("res://sim/run.gd")
const Settings = preload("res://sim/settings.gd")
const RoostView = preload("res://client/dangers/roost_view.gd")
const KindView = preload("res://client/dangers/kind_view.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const LevelScript = preload("res://client/level.gd")

const DT := 0.05
const W := Arboretum.W
const CHILD_ENV := "GOING_DOWN_ROOST_DIGEST"
const NAMES: Array[String] = ["count", "trigger", "stir", "walk_floor", "loud", "cone", "burst", "away", "settle",
	"calm", "lift_clear", "spacing"]

## In the fresh process the digest test asks for, only the digest runs.
static func _child() -> bool:
	return OS.get_environment(CHILD_ENV) == "1"

static func _break(name: String) -> void:
	Roost.test_break = name

# ---------------------------------------------------------------------------------------------
# Helpers: placement and stepping the kind by itself.

static func plan_of(i: int) -> Floor.FloorPlan:
	return Arboretum.generate_arboretum("roost-%d" % i, 5 + i % 4)

static func tuning_of(given: Dictionary) -> Settings.Values:
	var g := {}
	for k: String in given:
		g[StringName("danger.roost." + k)] = given[k]
	return Settings.make(g)

## The Place the base would hand the kind on this plan (its keep_clear from the base's own function).
static func place_for(plan: Floor.FloorPlan, tuning: Settings.Values = null) -> Api.Place:
	var s := Run.RunState.new()
	s.plan = plan
	var p := Api.Place.new()
	p.plan = plan
	p.place = plan.place
	p.depth = plan.depth
	p.floor_seed = "%s:%d" % [plan.seed, plan.depth]
	p.tuning = tuning
	p.rng = Rng.make_rng(p.floor_seed + ":danger:roost")
	p.lift_steps = Floor.distances_from(plan, plan.landing)
	p.keep_clear = Dangers.keep_clear_of(s, null)
	return p

static func placed(plan: Floor.FloorPlan, tuning: Settings.Values = null) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for r in Roost.new().place(place_for(plan, tuning)):
		var rec := r.duplicate(true)
		rec["since"] = 0.0
		rec["id"] = out.size()
		rec["kind"] = &"roost"
		out.append(rec)
	return out

static func who(id: String, x: float, z: float, gait: StringName) -> Api.Who:
	var w := Api.Who.new()
	w.id = id
	w.body = Move.Body.make(x, z, 0, 0.0)
	w.speed = gait
	w.up = true
	return w

## A bare roost record at (10, 10), settled since 0.
static func bare(trigger := Roost.TRIGGER, cone := Roost.CONE) -> Dictionary:
	return {"id": 0, "kind": &"roost", "x": 10.0, "y": 0.0, "z": 10.0, "level": 0, "yaw": 0.0, "state": Roost.SETTLED,
		"since": 0.0, "n": [0, 1, trigger, 3.0, 3.0, cone], "k": {"prev": {}, "stir_at": -1.0}}

class Drive:
	extends RefCounted
	var rec: Dictionary
	var asks: Array = []          # [t, op, args]
	var states: Array = []        # [t, state]
	var t := 0.0
	var tuning: Settings.Values = null
	var kind := Roost.new()

	func _init(r: Dictionary, tu: Settings.Values = null) -> void:
		rec = r
		tuning = tu

	## One host tick with these players and events.
	func tick(players: Array[Api.Who], events: Array[Dictionary] = []) -> void:
		t += DT
		var k := Api.Tick.new()
		k.t = t
		k.dt = DT
		k.tuning = tuning
		k.place = &"arboretum"
		k.players = players
		k.events = events
		var ask := Api.Asks.new()
		ask.t = t
		var log := asks
		var now := t
		ask._do = func(op: StringName, _r: Dictionary, args: Array) -> bool:
			log.append([now, op, args])
			return true
		var copy := rec.duplicate(true)
		var before := StringName(copy["state"])
		kind.step(copy, k, ask)
		rec = copy
		if StringName(rec["state"]) != before:
			states.append([t, StringName(rec["state"])])

	## A walker from (x0, z0) to (x1, z1) at `speed` m/s with `gait`; returns when there.
	func walk(x0: float, z0: float, x1: float, z1: float, speed: float, gait: StringName, id := "a") -> void:
		var d := Vector2(x1 - x0, z1 - z0)
		var n := maxi(1, int(ceil(d.length() / (speed * DT))))
		for i in n + 1:
			var p := Vector2(x0, z0) + d * (float(i) / n)
			var ws: Array[Api.Who] = [Drive.walker(id, p.x, p.y, gait)]
			tick(ws)

	static func walker(id: String, x: float, z: float, gait: StringName) -> Api.Who:
		var w := Api.Who.new()
		w.id = id
		w.body = Move.Body.make(x, z, 0, 0.0)
		w.speed = gait
		w.up = true
		return w

	func wait(secs: float) -> void:
		for i in int(round(secs / DT)):
			var none: Array[Api.Who] = []
			tick(none)

	func noises() -> Array:
		return asks.filter(func(a: Array) -> bool: return a[1] == &"noise")

	func first(state: StringName) -> float:
		for s: Array in states:
			if s[1] == state:
				return float(s[0])
		return -1.0

# ---------------------------------------------------------------------------------------------
# Helpers: the real run.

## HostRules made by parameter name (so the test does not depend on the order): `on` names flags to turn on.
static func rules(on: Array, dangers: Variant) -> HostRules:
	var info: Dictionary = {}
	var script: Script = load("res://net/host_rules.gd")
	for m: Dictionary in script.get_script_method_list():
		if m["name"] == "_init":
			info = m
	var args: Array = []
	var params: Array = info.get("args", [])
	var defaults: Array = info.get("default_args", [])
	var first_default := params.size() - defaults.size()
	for i in params.size():
		var name: String = String(params[i]["name"]).trim_suffix("_")
		if name == "entity_on":
			args.append(true)
		elif name == "depth":
			args.append(5)
		elif name == "deck":
			args.append(Places.FULL)
		elif name == "dangers":
			args.append(dangers)
		elif on.has(name):
			args.append(true)
		else:
			args.append(defaults[i - first_default] if i >= first_default else false)
	return HostRules.new.callv(args)

static func input(id: String, body: Move.Body, gait := &"walk") -> Run.PlayerInput:
	var i := Run.PlayerInput.make(id, body, 1.65, 0.0, 0.0, 90.0, 70.0)
	i.gait = gait
	return i

## A run on floor 5 (the Arboretum) with the doors open and the crew on the apron.
static func start(seed: String, hr: HostRules, ids: Array[String], tuning_given: Dictionary = {}) -> Run.RunState:
	var s := hr.prepare(Run.create_run(seed, ids, Places.FULL))
	if not tuning_given.is_empty():
		s = Run.with_tuning(s, tuning_given)
	s = s.copy()
	s.phase = &"away"
	return s

static func roosts(s: Run.RunState) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if s.dangers == null:
		return out
	for r: Dictionary in s.dangers.records:
		if StringName(r["kind"]) == &"roost":
			out.append(r)
	return out

static func toward(s: Run.RunState, body: Move.Body, x: float, z: float, speed: float) -> Move.Body:
	var dx := x - body.x
	var dz := z - body.z
	var d := sqrt(dx * dx + dz * dz)
	if d < 1e-6:
		return body
	var go := minf(d, speed * DT)
	return Run.move_in_run(s, body, dx / d * go, dz / d * go, 0.3)

static func place_at(s: Run.RunState, id: String, b: Move.Body) -> Run.RunState:
	var s2 := s.copy()
	var ps := s2.players.duplicate()
	for i in ps.size():
		if ps[i].id == id:
			var np: Run.RunPlayer = ps[i].copy()
			np.body = b
			ps[i] = np
	s2.players = ps
	return s2

## An open spot `dist` m from (x, z) in direction `a` (radians), on open ground the run can stand on, or null.
static func spot(s: Run.RunState, x: float, z: float, dist: float) -> Move.Body:
	for k in 16:
		var a := k * TAU / 16.0
		var b := Move.Body.make(x + cos(a) * dist, z + sin(a) * dist, 0, 0.0)
		var moved := Run.move_in_run(s, b, 0.0, 0.0, 0.3)
		var cell := Move.cell_of(s.plan, b)
		if cell != null and Floor.is_walkable(s.plan, 0, cell.x, cell.y) and absf(moved.x - b.x) < 1e-3 and absf(moved.z - b.z) < 1e-3:
			return b
	return null

# ---------------------------------------------------------------------------------------------
# 1. Off changes nothing.

## Break: test_break "garden_touch" (the kind's placement writes into the floor's garden).
func test_off_changes_nothing(t: T) -> void:
	if _child():
		return
	var ids: Array[String] = ["a"]
	for i in (2 if t.quick else 6):
		var seed := "roost-off-%d" % i
		var off := start(seed, rules(["downs", "garden_cones"], []), ids)
		var on := start(seed, rules(["downs", "garden_cones"], [&"roost"]), ids)
		var hr_off := rules(["downs", "garden_cones"], [])
		var hr_on := rules(["downs", "garden_cones"], [&"roost"])
		var h_off := Arboretum.floor_hash(off.plan)
		var body := off.players[0].body
		var a := off
		var b := on
		var same := true
		for step in int(20.0 / DT):
			var tx := (Arboretum.W * 0.5) * 2.0
			body = toward(a, body, tx, 30.0, 1.0)
			var inp: Array[Run.PlayerInput] = [input("a", body, &"creep")]
			a = hr_off.step(a, inp, DT).state
			b = hr_on.step(b, inp, DT).state
			if a.players[0].body.x != b.players[0].body.x or a.orderly.body.x != b.orderly.body.x or a.orderly.body.z != b.orderly.body.z:
				same = false
		t.check(same, "%s: a creeping crew and the Groundskeeper move the same with the roosts on as off" % seed)
		t.eq(Arboretum.floor_hash(b.plan), h_off, "%s: the garden with the roosts on is the floor as made with them off" % seed)
		t.check(a.dangers == null, "%s: with no kind enabled the run has no dangers at all" % seed)
	_break("")
	# The kind on, on a floor that is not the Arboretum: no roost.
	var hr1 := HostRules.new(true, 1, Places.FULL)
	var c := hr1.prepare(Run.create_run("roost-clinic", ids, Places.FULL))
	t.check(c.plan.place != Arboretum.PLACE, "floor 1 is not the Arboretum")
	t.check(Roost.new().place(place_for(c.plan)).is_empty(), "no roost is placed on a floor that is not the Arboretum")

## The garden's floor data are untouched by placement (the break writes into it).
func test_placement_leaves_the_floor_alone(t: T) -> void:
	if _child():
		return
	for i in (4 if t.quick else 30):
		var plan := plan_of(i)
		var before := Arboretum.floor_hash(plan)
		var cones := str(GardenCones.placements(plan).map(func(b: Move.Body) -> Array: return [b.x, b.z]))
		placed(plan)
		t.eq(Arboretum.floor_hash(plan), before, "roost-%d: the garden after placing the roosts" % i)
		t.eq(str(GardenCones.placements(plan).map(func(b: Move.Body) -> Array: return [b.x, b.z])), cones, "roost-%d: the pinecones" % i)

# ---------------------------------------------------------------------------------------------
# 2. The same seed, the same roosts.

static func digest(i: int) -> String:
	var recs := placed(plan_of(i))
	var parts: Array = []
	for r in recs:
		parts.append("%d@%.2f,%.2f" % [int(r["n"][0]), float(r["x"]), float(r["z"])])
	return "ROOST %d %s" % [i, " ".join(parts)]

## Break: test_break "time_seed" (the order drawn from the engine's generator, not the kind's own).
func test_same_seed_same_roosts(t: T) -> void:
	if _child():
		return
	var n := 6 if t.quick else 40
	for i in n:
		t.eq(digest(i), digest(i), "roost-%d: placed twice in one process" % i)

## A fresh process places the same roosts: it runs this file alone with only test_digest_for_parent printing.
func test_same_roosts_in_a_fresh_process(t: T) -> void:
	if _child():
		return
	var n := 4 if t.quick else 12
	OS.set_environment(CHILD_ENV, "1")
	var args: Array[String] = ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", "res://tests/run_tests.gd", "--", "test_danger_roost"]
	var out: Array = []
	var code := OS.execute(OS.get_executable_path(), args, out, true)
	OS.set_environment(CHILD_ENV, "")
	if not t.check(code == 0, "a fresh process ran (exit %d)" % code):
		return
	var lines := {}
	for chunk: String in out:
		for l: String in chunk.split("\n"):
			var s := l.strip_edges()
			if s.begins_with("ROOST "):
				lines[int(s.split(" ")[1])] = s
	for i in n:
		t.eq(lines.get(i, "missing"), digest(i), "roost-%d: a fresh process places the same roosts as this one" % i)

func test_digest_for_parent(t: T) -> void:
	if not _child():
		return
	for i in 12:
		t.note(digest(i))

# ---------------------------------------------------------------------------------------------
# 3. Where they go: keep-clears and the way round (checked here with the test's own rules and search).

## The test's own search: from the landing, cell to cell (the plan's steps), never onto a cell whose middle is
## inside a roost's trigger disc.
static func reach_without(plan: Floor.FloorPlan, discs: Array) -> PackedByteArray:
	var n := plan.width * plan.height
	var seen := PackedByteArray()
	seen.resize(n)
	var blocked := func(c: int) -> bool:
		var mx := (c % plan.width) * 2.0 + 1.0
		var mz := (c / plan.width) * 2.0 + 1.0
		for d: Array in discs:
			if Vector2(mx - float(d[0]), mz - float(d[1])).length() < float(d[2]):
				return true
		return false
	var first := plan.landing.y * plan.width + plan.landing.x
	if blocked.call(first):
		return seen
	var queue: Array[Floor.Pos] = [plan.landing]
	seen[first] = 1
	var head := 0
	while head < queue.size():
		var p := queue[head]
		head += 1
		for q in Floor.neighbours(plan, p):
			if q.level != 0:
				continue
			var c := q.y * plan.width + q.x
			if seen[c] == 1 or blocked.call(c):
				continue
			seen[c] = 1
			queue.append(q)
	return seen

## Breaks: test_break "no_own_clear" (the landmark, hide, cone and twig keep-clears dropped) and "no_way_round".
func test_where_they_go(t: T) -> void:
	if _child():
		return
	var n := 40 if t.quick else 400
	var total := 0
	var none := 0
	var short := 0
	var bad := 0
	var nearest_steps := 1 << 30
	for i in n:
		var plan := plan_of(i)
		var g := Arboretum.garden_of(plan)
		var p := place_for(plan)
		var recs := Roost.new().place(p)
		total += recs.size()
		if recs.is_empty():
			none += 1
		if recs.size() < Roost.COUNT:
			short += 1
		var discs: Array = []
		var trunks := {}
		var conifer := {}
		for piece in Furniture.pieces_for(plan):
			if piece.kind == &"trunk":
				var c: int = (piece.y / 200) * W + piece.x / 200
				trunks[c] = int(trunks.get(c, 0)) + 1
				if Arboretum.is_conifer(piece.x, piece.y):
					conifer[c] = true
		var dead := {}
		for d in g.dead:
			dead[d.cell] = true
		var why: Array[String] = []
		var hides := Arboretum.hides(plan)
		var cones := GardenCones.placements(plan)
		for r in recs:
			var cell: int = int(r["n"][0])
			var x := float(r["x"])
			var z := float(r["z"])
			var tr := Roost.TRIGGER
			discs.append([x, z, tr])
			if g.cells[cell] != Noises.LITTER or conifer.has(cell) or dead.has(cell) or int(trunks.get(cell, 0)) < 2:
				why.append("cell %d is not a broad-leaved tree on litter" % cell)
			nearest_steps = mini(nearest_steps, p.lift_steps[cell])
			if p.lift_steps[cell] < Roost.LIFT_CLEAR:
				why.append("cell %d is %d steps from the landing" % [cell, p.lift_steps[cell]])
			if not p.clear(0, x, z, tr):
				why.append("cell %d touches the base's keep-clear" % cell)
			for h in hides:
				for spot2: Vector2i in [h.inside, h.front]:
					if Vector2(spot2.x / 100.0 - x, spot2.y / 100.0 - z).length() < tr + 0.5:
						why.append("cell %d covers hide %d" % [cell, h.id])
			for c in cones:
				if Vector2(c.x - x, c.z - z).length() < tr + 0.4:
					why.append("cell %d covers a pinecone" % cell)
			for l in g.landmarks:
				for cy in range(l.y - 1, l.y + l.h + 1):
					for cx in range(l.x - 1, l.x + l.w + 1):
						if Vector2(cx * 2.0 + 1.0 - x, cy * 2.0 + 1.0 - z).length() < tr:
							why.append("cell %d covers landmark %d's ground" % [cell, l.id])
			for d in g.dead:
				for fc: int in d.fall:
					if maxi(absi(fc % W - cell % W), absi(fc / W - cell / W)) <= 1:
						why.append("cell %d is beside twig fall %d" % [cell, d.id])
			# The pale ground never lies on the pale gravel (sampled every 25 cm over the trigger's disc).
			var on_gravel := false
			for sx in range(-10, 11):
				for sz in range(-10, 11):
					var px := x + sx * 0.25
					var pz := z + sz * 0.25
					if Vector2(px - x, pz - z).length() >= tr:
						continue
					if g.surface(int(floor(px / 2.0)), int(floor(pz / 2.0))) == Noises.GRAVEL:
						on_gravel = true
			if on_gravel:
				why.append("cell %d's ground touches gravel" % cell)
			for o in recs:
				var oc: int = int(o["n"][0])
				if oc != cell and maxi(absi(oc % W - cell % W), absi(oc / W - cell / W)) < Roost.SPACING:
					why.append("cells %d and %d are too close" % [cell, oc])
		var seen := reach_without(plan, discs)
		for l in g.landmarks:
			var any := false
			for c in l.cells():
				if seen[c] == 1:
					any = true
			if not any:
				why.append("landmark %d cut off" % l.id)
		for h in hides:
			if seen[(h.front.y / 200) * W + h.front.x / 200] != 1:
				why.append("hide %d cut off" % h.id)
		for c in cones:
			if seen[int(c.z / 2.0) * W + int(c.x / 2.0)] != 1:
				why.append("a pinecone cut off")
		if not why.is_empty():
			bad += 1
			t.check(bad > 6, "roost-%d: %s" % [i, ", ".join(why.slice(0, 4))])
	t.eq(bad, 0, "floors breaking a placement rule")
	t.check(float(total) / n >= 2.5, "roosts per floor on average: %.2f (want at least 2.5)" % (float(total) / n))
	t.eq(none, 0, "floors with no roost at all")
	t.eq(short, 0, "floors with fewer than %d roosts" % Roost.COUNT)
	t.note("%d floors: %.2f roosts each; the nearest is %d steps' walk from the landing" % [n, float(total) / n, nearest_steps])

## The placement's own search sees a cut where there is one: ground taken away across the pavilion's doorway (or
## round a landmark) cuts the landing off, and both the placement's search and this file's say so.
## Break: test_break "no_way_round" (the placement's search always says there is a way).
func test_the_way_round_search_sees_a_cut(t: T) -> void:
	if _child():
		return
	for i in (4 if t.quick else 20):
		var plan := plan_of(i)
		var g := Arboretum.garden_of(plan)
		var door := [(g.door_out % W) * 2.0 + 1.0, (g.door_out / W) * 2.0 + 1.0, 3.2]
		t.check(not Roost.way_round(plan, [door]), "roost-%d: ground taken from the pavilion's doorway cuts the landing off" % i)
		var seen := reach_without(plan, [door])
		var any := false
		for c in g.landmarks[1].cells():
			any = any or seen[c] == 1
		t.check(not any, "roost-%d: this file's search agrees" % i)
		var l := g.landmarks[1]
		var ring := [(l.x + l.w * 0.5) * 2.0, (l.y + l.h * 0.5) * 2.0, (maxi(l.w, l.h) + 2) * 2.0]
		t.check(not Roost.way_round(plan, [ring]), "roost-%d: ground taken all round landmark %d cuts it off" % [i, l.id])
		t.check(Roost.way_round(plan, []), "roost-%d: with nothing taken every place is reached" % i)

## For the record (a note, not a rule): how many floors got a different tree because the pale ground keeps off the
## gravel. Every floor still has its four (test_where_they_go).
func test_gravel_rule_moved_trees(t: T) -> void:
	if _child():
		return
	var was := Roost.test_break
	var n := 10 if t.quick else 40
	var moved := 0
	for i in n:
		Roost.test_break = "gravel_ok"
		var before := digest(i)
		Roost.test_break = was
		if digest(i) != before:
			moved += 1
	Roost.test_break = was
	t.note("%d of %d floors placed at least one roost on a different tree to keep its ground off the gravel" % [moved, n])

## The first meeting: every roost is at least LIFT_CLEAR steps from the landing, and its murmur carries well past
## the ground that sets it off, so the first one is heard and its spatter seen before anyone can set it off.
func test_first_meeting_is_from_a_distance(t: T) -> void:
	if _child():
		return
	var idle: Array = RoostView.SOUNDS[&"idle"]
	t.check(float(idle[3]) >= Roost.STIR + 6.0, "the murmur is heard from %.0f m, the ground it guards is %.1f m" % [float(idle[3]), Roost.TRIGGER])
	var worst := 1e9
	for i in (10 if t.quick else 100):
		var plan := plan_of(i)
		var p := place_for(plan)
		for r in Roost.new().place(p):
			# Walking steps are 2 m cells; the disc's edge is TRIGGER nearer than its middle.
			worst = minf(worst, p.lift_steps[int(r["n"][0])] * 2.0 - Roost.TRIGGER)
	t.check(worst >= 9.0, "the nearest roost's ground is %.1f m' walk from the landing (want at least 9)" % worst)

# ---------------------------------------------------------------------------------------------
# 4. Who sets it off.

## Break: test_break "creep_flushes".
func test_walkers_flush_creepers_never(t: T) -> void:
	if _child():
		return
	# A walker straight through the middle at a walk (3 m/s): it goes up on the tick they are inside the trigger.
	var d := Drive.new(bare())
	d.walk(0.0, 10.0, 20.0, 10.0, 3.0, &"walk")
	var nz := d.noises()
	t.eq(nz.size(), 1, "a walk through the middle: noises")
	if nz.size() == 1:
		var at: Move.Body = nz[0][2][0]
		t.check(absf(at.x - 10.0) < 1e-6 and absf(at.z - 10.0) < 1e-6, "the noise is at the roost's middle (%.2f, %.2f), not at the walker" % [at.x, at.z])
		t.eq(float(nz[0][2][1]), Roost.LOUD, "its reach")
		t.eq(str(nz[0][2][2]), "", "it is made by nobody (a thing's noise, like a landed cone)")
		var flushed_at := d.first(Roost.FLUSHED)
		var x_then := float(flushed_at / DT) * 3.0 * DT
		t.check(absf(x_then - 10.0) <= Roost.TRIGGER + 3.0 * DT + 1e-6, "it went up as they came within %.1f m (at x %.2f)" % [Roost.TRIGGER, x_then])
	# A sprint flushes too.
	var sp := Drive.new(bare())
	sp.walk(0.0, 10.0, 20.0, 10.0, 5.5, &"sprint")
	t.eq(sp.noises().size(), 1, "a sprint through the middle flushes it")
	# A creep never flushes or stirs it, even at a walker's speed (the host's gait decides, so delay cannot).
	for speed: float in [1.2, 3.0]:
		var c := Drive.new(bare())
		c.walk(0.0, 10.0, 20.0, 10.0, speed, &"creep")
		c.walk(20.0, 10.0, 10.0, 10.2, speed, &"creep")
		t.eq(c.noises().size(), 0, "a creep at %.1f m/s through the middle: noises" % speed)
		t.eq(c.states.size(), 0, "a creep at %.1f m/s: the roost did not even stir (%s)" % [speed, str(c.states)])
	# Walking gait but pressed into a trunk (barely moving): no flush.
	var slow := Drive.new(bare())
	slow.walk(9.0, 10.0, 11.0, 10.0, 1.0, &"walk")
	t.eq(slow.noises().size(), 0, "a walk at 1 m/s (under the floor) does not flush it")
	# A downed player crawling, one in a hide, one in the car, one pinned: never.
	for what: String in ["down", "hidden", "aboard", "pinned"]:
		var dd := Drive.new(bare())
		for i in 100:
			var w := Drive.walker("a", 4.0 + i * 0.15, 10.0, &"walk")
			match what:
				"down":
					w.down = true
					w.up = false
					w.stance = &"crawl"
				"hidden":
					w.hidden = true
				"aboard":
					w.aboard = true
				"pinned":
					w.pinned = true
					w.up = false
			var ws: Array[Api.Who] = [w]
			dd.tick(ws)
		t.eq(dd.noises().size(), 0, "a player %s passing under it: noises" % what)
	# Standing still under it: nothing.
	var still := Drive.new(bare())
	for i in 100:
		var ws: Array[Api.Who] = [Drive.walker("a", 10.0, 10.0, &"still")]
		still.tick(ws)
	t.eq(still.noises().size(), 0, "standing still under it")

## On the real floor, all four surfaces: a creeper across every roost's ground never sets one off; a walker does.
func test_on_the_floor_creep_passes_walk_flushes(t: T) -> void:
	if _child():
		return
	var ids: Array[String] = ["a"]
	var crept := 0
	var walked := 0
	var flushes_walk := 0
	var flushes_creep := 0
	var surfaces := {}
	for i in (2 if t.quick else 10):
		for gait: StringName in [&"creep", &"walk"]:
			var hr := rules(["downs", "garden_cones"], [&"roost"])
			var s := start("roost-floor-%d" % i, hr, ids, {&"groundskeeper.speed": 0.0, &"groundskeeper.dark_speed": 0.0})
			# One step so the base places the floor's roosts.
			s = hr.step(s, [input("a", s.players[0].body, &"creep")] as Array[Run.PlayerInput], DT).state
			var rs := roosts(s)
			for r in rs:
				var cx := float(r["x"])
				var cz := float(r["z"])
				var from := spot(s, cx, cz, 4.0)
				if from == null:
					continue
				s = place_at(s, "a", from)
				var body := from
				var to := Vector2(cx - (from.x - cx), cz - (from.z - cz))
				var closest := 1e9
				var mine := 0
				for step in int(8.0 / DT):
					closest = minf(closest, Vector2(body.x - cx, body.z - cz).length())
					body = toward(s, body, to.x, to.y, 1.2 if gait == &"creep" else 3.0)
					var g := Arboretum.garden_of(s.plan)
					var cell := Move.cell_of(s.plan, body)
					if cell != null:
						surfaces[Noises.SURFACE_NAMES[g.surface(cell.x, cell.y)]] = true
					var res := hr.step(s, [input("a", body, gait)] as Array[Run.PlayerInput], DT)
					s = res.state
					body = s.players[0].body
					for e in res.events:
						if e["type"] == "dangerNoise" and e["kind"] == "roost":
							mine += 1
							if gait == &"creep":
								flushes_creep += 1
					if s.players[0].status != &"ok":
						break
				# Only walks that really came onto its ground (thicket and trunks can turn a walker aside).
				if closest > Roost.TRIGGER - 0.3:
					continue
				if gait == &"creep":
					crept += 1
				else:
					walked += 1
					flushes_walk += mini(mine, 1)
				# Let it settle again before the next one (and let the Groundskeeper go back to listening).
				for step in int(1.0 / DT):
					s = hr.step(s, [input("a", s.players[0].body, &"creep")] as Array[Run.PlayerInput], DT).state
	t.check(crept >= 4, "roosts crept under: %d" % crept)
	t.eq(flushes_creep, 0, "flushes by a creeper")
	t.check(flushes_walk == walked and walked >= 4,"a walker under a roost set it off %d times in %d walks" % [flushes_walk, walked])
	t.note("surfaces crossed: %s" % str(surfaces.keys()))

## Break: test_break "cone_double" (the cone's radius doubled: one landing 3.5 m out flushes).
func test_a_cone_sends_it_up(t: T) -> void:
	if _child():
		return
	var near := Drive.new(bare())
	var none: Array[Api.Who] = []
	near.tick(none, [{"type": "coneLanded", "t": 0.05, "x": 10.8, "z": 10.6}] as Array[Dictionary])
	t.eq(near.noises().size(), 1, "a cone landing 1 m from the middle sends it up")
	t.eq(StringName(near.rec["state"]), Roost.FLUSHED, "flushed")
	var far := Drive.new(bare())
	far.tick(none, [{"type": "coneLanded", "t": 0.05, "x": 13.5, "z": 10.0}] as Array[Dictionary])
	t.eq(far.noises().size(), 0, "a cone 3.5 m out does not")
	# On the real floor: a cone the run lands at the tree (as a throw at its trunks would) sends the roost up and
	# brings the Groundskeeper to the tree, far from the thrower.
	var ids: Array[String] = ["a"]
	var tried := 0
	var came := 0
	for i in (2 if t.quick else 6):
		var hr := rules(["downs", "garden_cones"], [&"roost"])
		var s := start("roost-cone-%d" % i, hr, ids)
		s = hr.step(s, [input("a", s.players[0].body, &"creep")] as Array[Run.PlayerInput], DT).state
		var rs := roosts(s)
		if rs.is_empty():
			continue
		var r := rs[0]
		var cx := float(r["x"])
		var cz := float(r["z"])
		# Bring the Groundskeeper within 18 m of the tree, listening.
		# Out in the garden (not in or behind the lift's pavilion, where his own walk would start from its room).
		var near_k: Move.Body = null
		for d: float in [14.0, 12.0, 16.0, 10.0]:
			var b := spot(s, cx, cz, d)
			if b != null and b.z > (Arboretum.Y0 + 3) * 2.0:
				near_k = b
				break
		if near_k == null:
			continue
		tried += 1
		s = s.copy()
		var g: Run.GardenFloor = s.garden.copy()
		var k: Hearing.Keeper = g.keeper.copy()
		k.body = near_k
		k.mode = &"listening"
		g.keeper = k
		var at := Move.Body.make(cx + 0.7, cz + 0.5, 0, 0.0)
		g.cones_in_flight = g.cones_in_flight.duplicate()
		g.cones_in_flight.append({"lands": s.t + DT, "at": at})
		s.garden = g
		var target_ok := false
		for step in int(12.0 / DT):
			var res := hr.step(s, [input("a", s.players[0].body, &"creep")] as Array[Run.PlayerInput], DT)
			s = res.state
			var kk: Hearing.Keeper = s.garden.keeper
			if kk.target != null and kk.target.r >= Roost.LOUD - 1e-6 and Vector2(kk.target.x - cx, kk.target.z - cz).length() < 1e-3:
				target_ok = true
			if target_ok and Vector2(kk.body.x - cx, kk.body.z - cz).length() < 2.5:
				came += 1
				break
			if step >= int(12.0 / DT) - 2:
				t.check(false,"roost-cone-%d: he did not come: %s at %.1f, %.1f (%.1f m off), target %s, heard the roost %s, started %.1f m off" % [i, kk.mode,
					kk.body.x, kk.body.z, Vector2(kk.body.x - cx, kk.body.z - cz).length(),
					str([kk.target.x, kk.target.z, kk.target.r, kk.target.kind]) if kk.target != null else "none", target_ok,
					Vector2(near_k.x - cx, near_k.z - cz).length()])
	t.check(tried >= 1 and came == tried, "a cone landed at a roost brought the Groundskeeper to the tree on %d of %d floors" % [came, tried])

# ---------------------------------------------------------------------------------------------
# 5. Heard first.

## Break: test_break "stir_is_trigger" (no restless warning before the flush).
func test_heard_before_it_costs_anything(t: T) -> void:
	if _child():
		return
	# Settled (its murmur playing) from the floor's first tick.
	for r in placed(plan_of(3)):
		t.eq(StringName(r["state"]), Roost.SETTLED, "a roost starts settled (murmuring)")
	# A walker coming in at a walk hears it turn restless at least a second before it goes up.
	for a: float in [0.0, 0.7, 1.9, 3.1, 4.4]:
		var d := Drive.new(bare())
		d.walk(10.0 + cos(a) * 9.0, 10.0 + sin(a) * 9.0, 10.0, 10.0, 3.0, &"walk")
		var stir := d.first(Roost.STIRRING)
		var flush := d.first(Roost.FLUSHED)
		t.check(stir >= 0.0 and flush >= 0.0 and flush - stir >= 1.0 - 1e-6,
			"from angle %.1f at a walk: restless at %.2f s, up at %.2f s (want a second's warning)" % [a, stir, flush])
	# The stir cue carries further than the stir ring, and the murmur further still.
	t.check(float(RoostView.SOUNDS[&"stir"][3]) > Roost.STIR and float(RoostView.SOUNDS[&"idle"][3]) > Roost.STIR, "the cues carry beyond the ring")

# ---------------------------------------------------------------------------------------------
# 6. The Groundskeeper hears it by his own rule.

## Break: test_break "noise_at_flusher" (the noise made at the walker, not at the tree).
func test_the_groundskeeper_comes_to_the_tree(t: T) -> void:
	if _child():
		return
	var ids: Array[String] = ["a"]
	var tried := 0
	var good := 0
	for i in (2 if t.quick else 8):
		var hr := rules(["downs", "garden_cones"], [&"roost"])
		var s := start("roost-keeper-%d" % i, hr, ids)
		s = hr.step(s, [input("a", s.players[0].body, &"creep")] as Array[Run.PlayerInput], DT).state
		var rs := roosts(s)
		if rs.is_empty():
			continue
		var r := rs[0]
		var cx := float(r["x"])
		var cz := float(r["z"])
		var from := spot(s, cx, cz, 2.0)
		var kat := spot(s, cx, cz, 18.0)
		if from == null or kat == null:
			continue
		tried += 1
		s = place_at(s, "a", from)
		s = s.copy()
		var g: Run.GardenFloor = s.garden.copy()
		var k: Hearing.Keeper = g.keeper.copy()
		k.body = kat
		k.mode = &"listening"
		g.keeper = k
		s.garden = g
		# Walking in under the tree from 2 m out.
		var body := from
		var flushed := false
		var heard := false
		var arrived := false
		for step in int(8.0 / DT):
			# Walk in until it goes up, then freeze (no noise of their own to draw him elsewhere).
			var gait := &"walk" if not flushed else &"creep"
			if not flushed:
				body = toward(s, body, cx, cz, 3.0)
			var res := hr.step(s, [input("a", body, gait)] as Array[Run.PlayerInput], DT)
			s = res.state
			body = s.players[0].body
			for e in res.events:
				if e["type"] == "dangerNoise":
					flushed = true
			var kk: Hearing.Keeper = s.garden.keeper
			if flushed and kk.target != null and kk.target.by == "" and absf(kk.target.x - cx) < 1e-3 and absf(kk.target.z - cz) < 1e-3:
				heard = true
			if heard and Vector2(kk.body.x - cx, kk.body.z - cz).length() < 2.0:
				arrived = true
		if flushed and heard and arrived:
			good += 1
		else:
			var kf: Hearing.Keeper = s.garden.keeper
			t.check(false, "roost-keeper-%d: flushed %s, he heard it at the tree %s, came to the tree %s (he is %s at %.1f, %.1f, %.1f m from the tree, target %s)" % [i, flushed, heard, arrived, kf.mode, kf.body.x, kf.body.z, Vector2(kf.body.x - cx, kf.body.z - cz).length(), str([kf.target.x, kf.target.z, kf.target.r, kf.target.by]) if kf.target != null else "none"])
	t.check(tried >= 1 and good == tried, "the Groundskeeper came to the tree on %d of %d floors" % [good, tried])

## His rule untouched: with every roost held settled, his whole walk over the floor is the walk with the kind off;
## with them free, his walk departs from it only after a roost's noise, and then toward that tree.
func test_his_rule_is_unchanged(t: T) -> void:
	if _child():
		return
	var ids: Array[String] = ["a"]
	var n := 3 if t.quick else 30
	var diverged_ok := 0
	var diverged := 0
	for i in n:
		var seed := "roost-trace-%d" % i
		for held: bool in [true, false]:
			var hr_off := rules(["downs", "garden_cones"], [])
			var hr_on := rules(["downs", "garden_cones"], [&"roost"])
			var a := start(seed, hr_off, ids)
			var b := start(seed, hr_on, ids)
			# The walker goes from 6 m out straight in under each roost in turn, 4 s each (the same moves on both runs).
			var goals: Array[Vector2] = []
			var starts: Array[Move.Body] = []
			for r in placed(a.plan):
				var st := spot(a, float(r["x"]), float(r["z"]), 6.0)
				if st != null:
					goals.append(Vector2(float(r["x"]), float(r["z"])))
					starts.append(st)
			if goals.is_empty():
				continue
			var body := a.players[0].body
			var first_noise := -1.0
			var split := false
			var leg_ticks := int(4.0 / DT)
			for step in leg_ticks * goals.size():
				var goal := step / leg_ticks
				if step % leg_ticks == 0:
					body = starts[goal]
					a = place_at(a, "a", body)
					b = place_at(b, "a", body)
				var tg := goals[goal]
				body = toward(a, body, tg.x, tg.y, 3.0)
				var inp: Array[Run.PlayerInput] = [input("a", body, &"walk")]
				if held and b.dangers != null:
					for r in roosts(b):
						Dangers.force_state(b, int(r["id"]), Roost.SETTLED)
				a = hr_off.step(a, inp, DT).state
				var rb := hr_on.step(b, inp, DT)
				b = rb.state
				for e in rb.events:
					if e["type"] == "dangerNoise" and first_noise < 0.0:
						first_noise = b.t
				var ka: Hearing.Keeper = a.garden.keeper
				var kb: Hearing.Keeper = b.garden.keeper
				# His target counts too: a louder noise can move it while he is still walking the same way.
				var ta := [ka.target.x, ka.target.z] if ka.target != null else []
				var tb := [kb.target.x, kb.target.z] if kb.target != null else []
				if not split and (ka.body.x != kb.body.x or ka.body.z != kb.body.z or ka.mode != kb.mode or ta != tb):
					split = true
					if held:
						t.check(false, "%s, roosts held settled: his walk departed at %.2f s" % [seed, b.t])
					else:
						diverged += 1
						var to_tree := false
						for r in roosts(b):
							if kb.target != null and absf(kb.target.x - float(r["x"])) < 1e-3 and absf(kb.target.z - float(r["z"])) < 1e-3:
								to_tree = true
						if first_noise >= 0.0 and to_tree:
							diverged_ok += 1
						else:
							t.check(false, "%s: his walk departed at %.2f s (first roost noise %.2f s), heading to a tree: %s" % [seed, b.t, first_noise, to_tree])
				if a.players[0].status != &"ok" or b.players[0].status != &"ok":
					break
	t.eq(diverged_ok, diverged, "every departure follows a roost's noise and heads to its tree")
	t.check(t.quick or diverged >= 1, "not vacuous: on some floor the walk crossed a roost and he came to it (%d)" % diverged)
	t.note("%d floors: his walk departed from the kind-off walk after a roost's noise on %d" % [n, diverged])

# ---------------------------------------------------------------------------------------------
# 7. Passive: never takes anyone down.

## Break: test_break "stumble_flusher" (the flush also trips the walker).
func test_never_takes_anyone_down(t: T) -> void:
	if _child():
		return
	# The kind itself asks for nothing but its noise, whatever players do.
	var rng := Rng.make_rng("roost-random-walk")
	var ops := {}
	for run in (20 if t.quick else 200):
		var d := Drive.new(bare())
		var p := Vector2(rng.next() * 20.0, rng.next() * 20.0)
		for step in 600:
			var a := rng.next() * TAU
			var gait: StringName = [&"creep", &"walk", &"sprint", &"still"][rng.int_in(0, 3)]
			var sp := {"creep": 1.2, "walk": 3.0, "sprint": 5.5, "still": 0.0}[String(gait)] as float
			p += Vector2(cos(a), sin(a)) * sp * DT
			p = p.clamp(Vector2(0, 0), Vector2(20, 20))
			var ws: Array[Api.Who] = [Drive.walker("a", p.x, p.y, gait)]
			d.tick(ws)
		for x: Array in d.asks:
			ops[x[1]] = true
	t.eq(ops.keys().filter(func(o: StringName) -> bool: return o != &"noise"), [], "asks other than a noise")
	# On the real floor with the Groundskeeper held still (speed 0): walking through every roost, nobody goes down.
	var ids: Array[String] = ["a", "b"]
	var flushes := 0
	var downs := 0
	for i in (3 if t.quick else 30):
		var hr := rules(["downs", "garden_cones"], [&"roost"])
		var s := start("roost-down-%d" % i, hr, ids, {&"groundskeeper.speed": 0.0, &"groundskeeper.dark_speed": 0.0})
		s = hr.step(s, [input("a", s.players[0].body, &"creep"), input("b", s.players[1].body, &"creep")] as Array[Run.PlayerInput], DT).state
		for r in roosts(s):
			var cx := float(r["x"])
			var cz := float(r["z"])
			var from := spot(s, cx, cz, 4.0)
			if from == null:
				continue
			s = place_at(place_at(s, "a", from), "b", from)
			var ba := from
			for step in int(6.0 / DT):
				ba = toward(s, ba, cx * 2.0 - from.x, cz * 2.0 - from.z, 3.0)
				var res := hr.step(s, [input("a", ba, &"walk"), input("b", ba, &"walk")] as Array[Run.PlayerInput], DT)
				s = res.state
				ba = s.players[0].body
				for e in res.events:
					if e["type"] == "dangerNoise":
						flushes += 1
					if e["type"] == "downed" or e["type"] == "caught":
						downs += 1
	t.eq(downs, 0, "players downed or caught while walking through roosts with the Groundskeeper held still")
	t.check(flushes >= 3, "flushes on the way: %d" % flushes)

# ---------------------------------------------------------------------------------------------
# 8. The cycle.

## Break: test_break "away_zero".
func test_away_then_settles_then_live_again(t: T) -> void:
	if _child():
		return
	var d := Drive.new(bare())
	d.walk(0.0, 10.0, 10.0, 10.0, 3.0, &"walk")
	var up := d.first(Roost.FLUSHED)
	# Stand walking on the spot under it (pacing) for the whole time away: it cannot go up again.
	var whole := Roost.BURST + Roost.AWAY_SECS + Roost.SETTLE
	var pace := 0.0
	var steps := int((whole - 1.5) / DT)
	for i in steps:
		pace += 1.0
		var ws: Array[Api.Who] = [Drive.walker("a", 10.0 + 0.15 * (int(pace) % 2), 10.0, &"walk")]
		d.tick(ws)
	t.eq(d.noises().size(), 1, "pacing under it while it is away and settling: noises")
	t.check(absf(d.first(Roost.AWAY) - up - Roost.BURST) < DT + 1e-6, "away %.2f s after it went up" % (d.first(Roost.AWAY) - up))
	t.check(absf(d.first(Roost.SETTLING) - d.first(Roost.AWAY) - Roost.AWAY_SECS) < DT + 1e-6, "settling after %.2f s away" % (d.first(Roost.SETTLING) - d.first(Roost.AWAY)))
	d.wait(1.0)
	t.eq(StringName(d.rec["state"]), Roost.SETTLED, "settled again")
	d.walk(0.0, 10.0, 10.0, 10.0, 3.0, &"walk")
	t.eq(d.noises().size(), 2, "live again: a second walk under it sends it up")
	# The test channel's forced flush costs the same noise.
	var f := Drive.new(bare())
	var k := Api.Tick.new()
	k.t = 1.0
	var ask := Api.Asks.new()
	ask.t = 1.0
	var log: Array = []
	ask._do = func(op: StringName, _r: Dictionary, args: Array) -> bool:
		log.append([op, args])
		return true
	var rec := bare()
	Roost.new().force(rec, Roost.FLUSHED, k, ask)
	t.check(log.size() == 1 and log[0][0] == &"noise" and str(log[0][1][2]) == "", "a forced flush is the same noise, made by nobody")

# ---------------------------------------------------------------------------------------------
# 9. The figures and the sounds.

func test_the_birds_are_figures_and_the_sounds_exist(t: T) -> void:
	if _child():
		return
	# Perched the bird is a dark lump; with its wings open it is pale with dark tips (the lead's look), drawn unshaded.
	var pale_share := func(m: ArrayMesh) -> float:
		var cols: PackedColorArray = m.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
		var pale := 0
		for c in cols:
			if c.get_luminance() >= 0.3:
				pale += 1
		return float(pale) / maxf(cols.size(), 1)
	t.check(float(pale_share.call(RoostView.bird_mesh(0))) == 0.0, "perched: no pale face (%.2f)" % float(pale_share.call(RoostView.bird_mesh(0))))
	for w: int in [1, -1, 2]:
		var share: float = pale_share.call(RoostView.bird_mesh(w))
		t.check(share >= 0.5, "wings open (%d): %.2f of the corners pale (more than half)" % [w, share])
	var made := view_on(0)
	var mms: Array = (made[1] as Node3D).get("_mm")
	t.check(((mms[0] as MultiMeshInstance3D).material_override as BaseMaterial3D).shading_mode != BaseMaterial3D.SHADING_MODE_UNSHADED, "perched birds are shaded by the floor's light")
	for k in range(1, mms.size()):
		t.check(((mms[k] as MultiMeshInstance3D).material_override as BaseMaterial3D).shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED, "open-winged pose %d is drawn unshaded" % k)
	(made[0] as Node).free()
	var glide := RoostView.bird_mesh(2).get_aabb()
	t.check(glide.size.x > 1.0 and glide.size.y < 0.35, "the glide pose holds its wings out flat (%s)" % str(glide.size))
	for pose: int in [0, 1, -1, 2]:
		var m := RoostView.bird_mesh(pose)
		var box := m.get_aabb()
		t.check(box.size.x > 0.1 and box.size.y > 0.1 and box.size.z > 0.3, "pose %d: a solid figure in all three axes (%s)" % [pose, str(box.size)])
		var tris := RoostView.triangles(m)
		t.check(tris >= 30 and tris <= 80, "pose %d: %d triangles (a low-poly figure, not a card)" % [pose, tris])
	for name: StringName in RoostView.SOUNDS:
		var st := RoostView.stream(name)
		t.check(st != null and st.get_length() > 0.5, "sound %s is there (%s)" % [name, str(st)])
		if st is AudioStreamOggVorbis:
			t.eq((st as AudioStreamOggVorbis).loop, bool(RoostView.SOUNDS[name][1]), "sound %s loops as it should" % name)
	t.check(RoostView.loop_of(Roost.SETTLED) == &"idle" and RoostView.loop_of(Roost.STIRRING) == &"stir" and RoostView.loop_of(Roost.AWAY) == &"", "the loops follow the state")

## The whole of an Ogg stream as 16-bit mono samples (decoded headless by the engine's own player), to measure it.
static func as_wav(st: AudioStream) -> AudioStreamWAV:
	var rate := 44100
	var pb := st.instantiate_playback()
	pb.start(0.0)
	var want := int(ceil(st.get_length() * rate))
	var data := PackedByteArray()
	data.resize(want * 2)
	var at := 0
	while at < want:
		var frames: PackedVector2Array = pb.call(&"mix_audio", 1.0, mini(4096, want - at))
		if frames.is_empty():
			break
		for f in frames:
			data.encode_s16(at * 2, clampi(int(round(f.x * 32768.0)), -32768, 32767))
			at += 1
	data.resize(at * 2)
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.data = data
	return w

## Every stream sits in its category's loudness band in the game's mix (client/dangers/kind_view.gd BANDS): no clipped
## sample, the peak at most -1 dBFS, and its loudness inside the band of the category the view plays it as.
## Break: the flush made 6 dB louder in assets_src/sfx/dangers/roost.mjs (or its category set to effect).
func test_its_sounds_sit_in_the_mix(t: T) -> void:
	if _child():
		return
	for name: StringName in RoostView.SOUNDS:
		var st := RoostView.stream(name)
		if not t.check(st != null, "sound %s is there" % name):
			continue
		var cat := RoostView.category_of(name)
		var m := KindView.measure(as_wav(st))
		t.check(KindView.in_band(m, cat), "%s as %s: peak %.1f dBFS, loudness %.1f dBFS, clipped %d (band %s)" % [name, cat,
			float(m["peak_db"]), float(m["loud_db"]), int(m["clipped"]), str(KindView.BANDS[cat])])
		t.note("%s (%s): peak %.1f, loudness %.1f" % [name, cat, float(m["peak_db"]), float(m["loud_db"])])

## The view on a real Arboretum level: birds on the roost's own trees, eyes, pale ground covering the trigger, the
## notice on the first roost only, and every state drawn from host time without an error.
func test_the_view_on_a_real_floor(t: T) -> void:
	if _child():
		return
	var main := Engine.get_main_loop() as SceneTree
	for i in (1 if t.quick else 3):
		var plan := plan_of(i)
		var level: Node3D = LevelScript.new()
		main.root.add_child(level)
		level.call(&"build", PlanDump.dump(plan, Run.car_geometry(plan)), plan.seed, plan)
		var recs := placed(plan)
		var views: Array = []
		for r in recs:
			var v: Node3D = RoostView.new()
			level.add_child(v)
			v.position = Vector3(float(r["x"]), 0.0, float(r["z"]))
			v.build(r, {"plan": plan, "place": &"arboretum", "depth": plan.depth, "level": level, "floor_seed": plan.seed})
			views.append(v)
			var drawn: Dictionary = v.get("drawn")
			t.check(int(drawn.get("birds", 0)) >= RoostView.BIRDS_MIN, "roost-%d cell %d: %s birds" % [i, int(r["n"][0]), str(drawn.get("birds"))])
			t.check(int(drawn.get("spatter", 0)) >= 150, "roost-%d cell %d: %s spatters on its ground" % [i, int(r["n"][0]), str(drawn.get("spatter"))])
			t.eq(drawn.has("notice"), int(r["n"][1]) == 1, "roost-%d cell %d: the notice only on the first" % [i, int(r["n"][0])])
			# Every state, part way in, by host time.
			var ht := 100.0
			for st: StringName in Roost.new().states():
				var before: Dictionary = r.duplicate(true)
				r["state"] = st
				r["since"] = ht
				v.changed(r, before, ht + 0.4)
				for f in 6:
					v.frame(r, ht + 0.4 + f * 0.35, 0.016)
				ht += 10.0
		level.free()

## A level of floor `i` with a view for its first roost (free the level after).
static func view_on(i: int) -> Array:
	var main := Engine.get_main_loop() as SceneTree
	var plan := plan_of(i)
	var level: Node3D = LevelScript.new()
	main.root.add_child(level)
	level.call(&"build", PlanDump.dump(plan, Run.car_geometry(plan)), plan.seed, plan)
	var r: Dictionary = placed(plan)[0]
	var v: Node3D = RoostView.new()
	level.add_child(v)
	v.position = Vector3(float(r["x"]), 0.0, float(r["z"]))
	v.build(r, {"plan": plan, "place": &"arboretum", "depth": plan.depth, "level": level, "floor_seed": plan.seed})
	return [level, v, r]

static func into(v: Node3D, r: Dictionary, state: StringName, since: float, ht: float) -> void:
	var before: Dictionary = r.duplicate(true)
	r["state"] = state
	r["since"] = since
	v.changed(r, before, ht)

## The view's sounds keep the mix's rules: on Effects, never louder than the file (max_db 0, at most Sfx.BASE_DB), and
## the Groundskeeper's hush fades the settled murmur only, never the restless warning.
## Breaks: max_db 6 on a player; the hush on every loop.
func test_the_view_keeps_the_mix(t: T) -> void:
	if _child():
		return
	var made := view_on(1)
	var level: Node3D = made[0]
	var v: Node3D = made[1]
	var r: Dictionary = made[2]
	var garden: Object = level.get_meta(&"arboretum") if level.has_meta(&"arboretum") else null
	t.check(garden != null, "the level carries the Arboretum's view (its hush)")
	var ht := 10.0
	for st: StringName in [Roost.SETTLED, Roost.STIRRING, Roost.FLUSHED, Roost.AWAY, Roost.SETTLING]:
		into(v, r, st, ht, ht + 0.2)
		v.frame(r, ht + 0.2, 0.016)
		for p: AudioStreamPlayer3D in v.call(&"players"):
			t.check(p.max_db <= 0.0 and p.bus == &"Effects", "%s: a player on %s with max_db %.1f" % [st, p.bus, p.max_db])
			if p.playing:
				t.check(p.volume_db <= -5.0 + 1e-6, "%s: a player at %.1f dB, over the voice's own level" % [st, p.volume_db])
		ht += 10.0
	if garden != null:
		garden.set("_hush", 0.0)
		into(v, r, Roost.SETTLED, ht, ht + 0.1)
		v.frame(r, ht + 0.1, 0.016)
		var loop: AudioStreamPlayer3D = v.get("_loop")
		t.check(loop.volume_db < -40.0, "settled, he near: the murmur is hushed (%.1f dB)" % loop.volume_db)
		into(v, r, Roost.STIRRING, ht + 1.0, ht + 1.1)
		v.frame(r, ht + 1.1, 0.016)
		loop = v.get("_loop")
		t.check(absf(loop.volume_db - float(v.call(&"_db", &"stir"))) < 1e-3, "restless, he near: the warning is at its full level (%.1f dB)" % loop.volume_db)
	level.free()

## The trunks are plain bark: no stain is drawn on them (the lead's ruling; the pale ground spatter carries the tell).
## Break: the spatter's node named "Stains".
func test_no_trunk_stains(t: T) -> void:
	if _child():
		return
	var made := view_on(1)
	var v: Node3D = made[1]
	t.check(v.get_node_or_null("Stains") == null, "no stain node under the roost")
	t.check(not (v.get("drawn") as Dictionary).has("stains"), "nothing drawn as stains")
	t.check(v.get_node_or_null("Spatter") != null, "the ground spatter is still drawn")
	(made[0] as Node).free()

## Every bird's burst route on every roost keeps clear of every trunk (0.3 m from its axis at the bird's height) and
## stays on the floor, over many floors.
## Breaks: TRUNK_CLEAR 0.0 (the first direction is always taken); the old sharp start of the burst (too fast).
func test_burst_routes_keep_clear(t: T) -> void:
	if _child():
		return
	var main := Engine.get_main_loop() as SceneTree
	var worst := 1e9
	var routes := 0
	var bad := 0
	var fastest := 0.0
	for i in (3 if t.quick else 12):
		var plan := plan_of(i)
		var level: Node3D = LevelScript.new()
		main.root.add_child(level)
		level.call(&"build", PlanDump.dump(plan, Run.car_geometry(plan)), plan.seed, plan)
		for r in placed(plan):
			var v: Node3D = RoostView.new()
			level.add_child(v)
			v.position = Vector3(float(r["x"]), 0.0, float(r["z"]))
			v.build(r, {"plan": plan, "place": &"arboretum", "depth": plan.depth, "level": level, "floor_seed": plan.seed})
			var lo := Vector2(-v.position.x, -v.position.z)
			var hi := lo + Vector2(plan.width, plan.height) * 2.0
			for b: Dictionary in v.get("_birds"):
				var c: float = v.call(&"route_clearance", b, lo, hi)
				worst = minf(worst, c)
				routes += 1
				if c < 0.3:
					bad += 1
				var was: Vector3 = RoostView.route_at(b, 0.0)[0]
				var tt := 0.05
				while tt < RoostView.FLIGHT:
					var got: Array = RoostView.route_at(b, tt)
					if float(got[1]) > 0.5:
						fastest = maxf(fastest, (got[0] as Vector3).distance_to(was))
					was = got[0]
					tt += 0.05
		level.free()
	t.eq(bad, 0, "burst routes within 0.3 m of a trunk or off the floor (of %d; nearest %.2f m)" % [routes, worst])
	t.check(fastest <= 1.0, "the fastest bird moves %.2f m in 1/20 s (want at most 1)" % fastest)
	t.note("%d routes, nearest trunk %.2f m, fastest %.2f m a frame" % [routes, worst, fastest])

## Flushed birds never pop out of being: from frame to frame (1/20 s) none goes from more than half size to nothing,
## none rises to the painted sky (12 m), and the leaves come down through eye height for at least two seconds.
## Breaks: no dwindling (scale 1 to the end); the old climb to 11.4 m.
func test_the_flush_never_pops(t: T) -> void:
	if _child():
		return
	var made := view_on(2)
	var level: Node3D = made[0]
	var v: Node3D = made[1]
	var r: Dictionary = made[2]
	# Read from the view's own arithmetic (a headless MultiMesh keeps no transforms to read back).
	var n: int = v.call(&"bird_count")
	var last := PackedFloat32Array()
	last.resize(n)
	var pops := 0
	var highest := 0.0
	var flying := 0
	var eye_level := 0.0
	var burst := float(r["n"][4])
	var settle := float(r["n"][3])
	var away := 20.0
	# The burst, by the lead's look: below the crown and past whoever is under the tree first, then up and away.
	var trunks: Array = v.get("near_trunks")
	var low_burst := 0          # bird-frames in 0.25 to 0.6 s at 2.2 to 4.8 m and at least 1.5 m out
	var close := {}             # birds that passed within 3 m of the tree's middle below 4.8 m in the first 0.6 s
	var risen := 0              # birds drawn above 6 m at 1.5 s
	var too_low := 0
	var in_trunk := 0
	var least_trunk := 1e9
	# Nor does a full-size bird jump: from frame to frame none moves further than a bird can fly in 1/20 s.
	var where: Array[Vector3] = []
	where.resize(n)
	var jumps := 0
	# Through the flush, the whole time away and the settling, as a screen draws it (1/20 s frames).
	var frames := int((burst + away + settle + 0.5) / 0.05)
	for f in frames:
		var tau := f * 0.05
		var state := Roost.FLUSHED
		var into_state := tau
		if tau >= burst + away:
			state = Roost.SETTLING
			into_state = tau - burst - away
		elif tau >= burst:
			state = Roost.AWAY
			into_state = tau - burst
		var ht := 50.0 + tau
		for i in n:
			var got: Array = v.call(&"bird_at", i, state, into_state, ht)
			var xf: Transform3D = got[0]
			var size := xf.basis.get_scale().x
			if size > 1e-4:
				highest = maxf(highest, xf.origin.y)
				if xf.origin.y > 7.0:
					flying += 1
				var o := xf.origin
				var out_h := Vector2(o.x, o.z).length()
				if size > 0.5 and o.y < 2.2:
					too_low += 1
				if state == Roost.FLUSHED and size > 0.5:
					for tr: Array in trunks:
						if o.y <= float(tr[2]):
							var c := RoostView.trunk_at(tr[0], tr[1], tr[2], o.y)
							var dd := Vector2(o.x - c.x, o.z - c.z).length()
							least_trunk = minf(least_trunk, dd)
							if dd < 0.3:
								in_trunk += 1
					if tau >= 0.25 and tau <= 0.6 and o.y <= 4.8 and out_h >= 1.5:
						low_burst += 1
					if tau <= 0.6 and o.y <= 4.8 and out_h <= 3.0 and out_h >= 1.5:
						close[i] = true
					if absf(tau - 1.5) < 0.026 and o.y > 6.0:
						risen += 1
			if f > 0 and last[i] > 0.5 and size > 0.5 and xf.origin.distance_to(where[i]) > 1.0:
				jumps += 1
				if jumps <= 3:
					t.note("jump: bird %d at %.2f s (%s, %.2f s in), %.2f m" % [i, tau, state, into_state, xf.origin.distance_to(where[i])])
			where[i] = xf.origin
			if f > 0 and last[i] > 0.5 and size <= 1e-4:
				pops += 1
				if pops <= 3:
					t.note("pop: bird %d at %.2f s (%s, %.2f s in)" % [i, tau, state, into_state])
			last[i] = size
		var falling := 0
		var ft := tau
		for k in int(v.call(&"leaf_count")):
			var lx: Transform3D = v.call(&"leaf_at", k, ft)
			if lx.basis.get_scale().x > 1e-4 and lx.origin.y > 1.2 and lx.origin.y < 2.0:
				falling += 1
		if falling >= 4 and tau < 4.0:
			eye_level += 0.05
	t.check(flying > 0, "not vacuous: birds were drawn flying above 7 m (%d bird-frames)" % flying)
	t.eq(too_low, 0, "bird-frames below 2.2 m (a standing head)")
	t.eq(in_trunk, 0, "bird-frames within 0.3 m of a trunk's axis (nearest %.2f m)" % least_trunk)
	t.check(low_burst >= n * 5, "the burst fans out below the crown (2.2 to 4.8 m, 1.5 m or more out) from 0.25 to 0.6 s: %d bird-frames of %d birds" % [low_burst, n])
	t.check(close.size() >= 3, "at least three birds pass 1.5 to 3 m from the tree's middle below the crown: %d" % close.size())
	t.check(risen * 2 >= n, "at 1.5 s at least half the birds are up over 6 m: %d of %d" % [risen, n])
	t.eq(pops, 0, "birds that went from more than half size to nothing in one frame")
	t.eq(jumps, 0, "full-size birds that jumped more than 1 m in one frame (through flushed, away and settling)")
	t.check(highest < 11.0, "the highest a flying bird got: %.2f m (the sky is at 12)" % highest)
	t.check(eye_level >= 2.0, "leaves falling through eye height for %.2f s of the first four (want 2)" % eye_level)
	# The frame draws exactly what bird_at says (the MultiMesh is fed from it).
	into(v, r, Roost.FLUSHED, 50.0, 50.0)
	v.frame(r, 50.8, 0.05)
	t.check(int((v.get("drawn") as Dictionary).get("falling", 0)) > 0, "the frame drew the shower 0.8 s in")
	level.free()

# ---------------------------------------------------------------------------------------------
# 10. Every number is a live setting (tests/prop_settings.gd looks for one method per wired row).

func test_every_number_is_a_live_setting(t: T) -> void:
	if _child():
		return
	for name in NAMES:
		var id := StringName("danger.roost." + name)
		t.check(Settings.has(id), "%s is a live setting" % id)
		t.check(has_method("test_setting_roost_" + name), "%s has its proof here" % id)

func test_setting_roost_count(t: T) -> void:
	if _child():
		return
	var few := 0
	var many := 0
	for i in (6 if t.quick else 30):
		few += placed(plan_of(i), tuning_of({"count": 2})).size()
		many += placed(plan_of(i), tuning_of({"count": 6})).size()
		t.check(placed(plan_of(i), tuning_of({"count": 2})).size() <= 2, "roost-%d: at most 2 with count 2" % i)
	t.check(many > few, "count 6 places more (%d) than count 2 (%d)" % [many, few])
	t.eq(placed(plan_of(1), tuning_of({"count": 0})).size(), 0, "count 0 places none")

## The trigger's radius is fixed into each record when the floor is placed (the pale ground is drawn to it), and the
## rules read it from there: a host's change takes hold on the next floor.
func test_setting_roost_trigger(t: T) -> void:
	if _child():
		return
	for tr: float in [2.5, 3.5]:
		var recs := placed(plan_of(2), tuning_of({"trigger": tr}))
		t.check(not recs.is_empty() and float(recs[0]["n"][2]) == tr, "placed with the trigger at %.1f m, the record keeps it" % tr)
		var d := Drive.new(bare(tr))
		d.walk(0.0, 13.0, 20.0, 13.0, 3.0, &"walk")
		t.eq(d.noises().size(), 1 if tr > 3.0 else 0, "a walk passing 3 m from the middle with the trigger at %.1f m" % tr)
	# Tuned mid-floor: the record's radius holds, so the pale ground never lies.
	var mid := Drive.new(bare(2.5), tuning_of({"trigger": 3.5}))
	mid.walk(0.0, 13.0, 20.0, 13.0, 3.0, &"walk")
	t.eq(mid.noises().size(), 0, "a host's trigger of 3.5 m mid-floor does not widen this floor's ground (2.5 m)")

func test_setting_roost_stir(t: T) -> void:
	if _child():
		return
	for st: float in [9.0, 7.5]:
		var d := Drive.new(bare(), tuning_of({"stir": st}))
		d.walk(0.0, 18.5, 20.0, 18.5, 3.0, &"walk")
		t.eq(d.first(Roost.STIRRING) >= 0.0, st > 8.6, "a walk passing 8.5 m off stirs it with the ring at %.1f m" % st)
	# Never less than the trigger plus 5.6 m (so no host tuning leaves a sprinter under a second's warning): a ring set
	# to 3 m still stirs at 7 m.
	var low := Drive.new(bare(), tuning_of({"stir": 3.0}))
	low.walk(0.0, 17.0, 20.0, 17.0, 3.0, &"walk")
	t.check(low.first(Roost.STIRRING) >= 0.0, "a ring set to 3 m is held at the trigger plus 5.6 m: a walk 7 m off stirs it")
	# At the least tuning a walker and a sprinter (5.5 m/s) both still get a full second of the restless sound.
	for g: Array in [[3.0, &"walk", 1.0], [5.5, &"sprint", 1.0]]:
		var sp := Drive.new(bare(), tuning_of({"stir": 3.0}))
		sp.walk(10.0, 0.0, 10.0, 10.0, float(g[0]), g[1])
		var lead := sp.first(Roost.FLUSHED) - sp.first(Roost.STIRRING)
		t.check(sp.first(Roost.STIRRING) >= 0.0 and lead >= float(g[2]) - 1e-6, "%s at the least ring: restless %.2f s before it went up (want %.2f)" % [g[1], lead, float(g[2])])

func test_setting_roost_walk_floor(t: T) -> void:
	if _child():
		return
	for wf: float in [1.7, 2.4]:
		var d := Drive.new(bare(), tuning_of({"walk_floor": wf}))
		d.walk(0.0, 10.0, 20.0, 10.0, 2.0, &"walk")
		t.eq(d.noises().size(), 1 if wf < 2.0 else 0, "a walk at 2 m/s with the floor at %.1f m/s" % wf)

func test_setting_roost_loud(t: T) -> void:
	if _child():
		return
	var d := Drive.new(bare(), tuning_of({"loud": 30.0}))
	d.walk(0.0, 10.0, 20.0, 10.0, 3.0, &"walk")
	t.check(d.noises().size() == 1 and float(d.noises()[0][2][1]) == 30.0, "the noise's reach is the setting (%s)" % str(d.noises()))

func test_setting_roost_cone(t: T) -> void:
	if _child():
		return
	var none: Array[Api.Who] = []
	for c: float in [2.5, 3.5]:
		var recs := placed(plan_of(2), tuning_of({"cone": c}))
		t.check(not recs.is_empty() and float(recs[0]["n"][5]) == c, "placed with the cone radius at %.1f m, the record keeps it" % c)
		var d := Drive.new(bare(Roost.TRIGGER, c))
		d.tick(none, [{"type": "coneLanded", "t": 0.05, "x": 13.0, "z": 10.0}] as Array[Dictionary])
		t.eq(d.noises().size(), 1 if c > 3.0 else 0, "a cone 3 m out with the radius at %.1f m" % c)

func _cycle(given: Dictionary) -> Drive:
	var d := Drive.new(bare(), tuning_of(given))
	d.walk(0.0, 10.0, 10.0, 10.0, 3.0, &"walk")
	d.wait(200.0)
	return d

func test_setting_roost_burst(t: T) -> void:
	if _child():
		return
	var d := _cycle({"burst": 5.0})
	t.check(absf(d.first(Roost.AWAY) - d.first(Roost.FLUSHED) - 5.0) < DT + 1e-6, "away 5 s after going up (%.2f)" % (d.first(Roost.AWAY) - d.first(Roost.FLUSHED)))

func test_setting_roost_away(t: T) -> void:
	if _child():
		return
	var d := _cycle({"away": 30.0})
	t.check(absf(d.first(Roost.SETTLING) - d.first(Roost.AWAY) - 30.0) < DT + 1e-6, "settling after 30 s away (%.2f)" % (d.first(Roost.SETTLING) - d.first(Roost.AWAY)))

func test_setting_roost_settle(t: T) -> void:
	if _child():
		return
	var d := _cycle({"settle": 5.0})
	var settled := -1.0
	for s: Array in d.states:
		if s[1] == Roost.SETTLED and float(s[0]) > d.first(Roost.SETTLING):
			settled = float(s[0])
	t.check(absf(settled - d.first(Roost.SETTLING) - 5.0) < DT + 1e-6, "settled 5 s after settling began (%.2f)" % (settled - d.first(Roost.SETTLING)))

func test_setting_roost_calm(t: T) -> void:
	if _child():
		return
	for c: float in [1.5, 4.0]:
		var d := Drive.new(bare(), tuning_of({"calm": c}))
		d.walk(4.0, 10.0, 4.5, 10.0, 3.0, &"walk")
		d.wait(6.0)
		var calm := -1.0
		for s: Array in d.states:
			if s[1] == Roost.SETTLED:
				calm = float(s[0])
		t.check(absf(calm - d.first(Roost.STIRRING) - c) < 0.3, "calm %.1f s: settled %.2f s after it stirred" % [c, calm - d.first(Roost.STIRRING)])

func test_setting_roost_lift_clear(t: T) -> void:
	if _child():
		return
	for i in (6 if t.quick else 30):
		var plan := plan_of(i)
		var p := place_for(plan, tuning_of({"lift_clear": 10}))
		for r in Roost.new().place(p):
			t.check(p.lift_steps[int(r["n"][0])] >= 10, "roost-%d: a roost %d steps from the landing with lift_clear 10" % [i, p.lift_steps[int(r["n"][0])]])

func test_setting_roost_spacing(t: T) -> void:
	if _child():
		return
	var closest := 1 << 30
	for i in (6 if t.quick else 30):
		var recs := placed(plan_of(i), tuning_of({"spacing": 9}))
		for a in recs:
			for b in recs:
				var ca: int = int(a["n"][0])
				var cb: int = int(b["n"][0])
				if ca != cb:
					closest = mini(closest, maxi(absi(ca % W - cb % W), absi(ca / W - cb / W)))
	t.check(closest >= 9, "the closest two roosts are %d cells apart with spacing 9" % closest)
