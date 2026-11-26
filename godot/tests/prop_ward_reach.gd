# WD1: "A raised shortcut can never strand someone." Over many floor seeds, for the bridge lowered and raised and for
# every door all open or all shut, every spot a walker can reach from the lift by the Ward's own walk model
# (sim/ward/state.gd walk, the model the screen walks with and the host checks against) has a walk back to the lift.
# The grid: cells of CELL metres on every standing surface, joined where state.walk carries a walker from one cell's
# middle to the next (the screen's own 7 cm sliding steps), both ways tested separately. Also: a raise of the bridge
# under someone is refused, so the lowered-then-raised case starts from the lowered reach.
#
# 25 Nov (WH1): the grid alone called spots cut off that a player walks out of. It keeps one pair of feet for each
# half-metre cell and pushes along the two axes only, so a way out narrower than a cell is missed: at the foot of a
# bedsit's stair (seeded Wards 273673180 and 1677347106; the homes Ward 190057) the only way off the landing is 0.3 m
# of floor between the stair's side and the wall, and the cell's kept feet stand on the stair's line, where a push
# back climbs the stair again. So a spot the grid cannot walk home is now put to the game's own way-finder
# (client/ward/route.gd Route.find: the same walk model, 0.3 m steps, eight ways, half-metre heights), and it is cut
# off only when that finds no walk into the car either. A walk the way-finder returns is a row of the walk model's
# own steps, so it proves the way home; the grid still decides which spots are reached at all.
#
# 25 Nov, later (WH1, the 500-seed survey): on two Wards of 500 (run-87 and run-439, homes off, both bridges) the
# way-finder found no walk out of a 3-storey bedsit either. Its search keeps one spot for each 0.3 m of floor, and
# the way from the rear room to the front door is a doorway its kept spots catch on. A search in 0.1 m steps,
# sixteen ways, walks out of both. So a spot the way-finder cannot walk home gets that finer look: from the spot,
# 0.1 m steps of the walk model until one step lands exactly on feet the grid walks home from, and from those feet
# the way-finder must walk into the car. Every link is a walk of the model, so the way home is still proved.
extends RefCounted

const T = preload("res://tests/t.gd")
const Ward = preload("res://sim/ward/state.gd")
const Layout = preload("res://sim/ward/layout.gd")
const Route = preload("res://client/ward/route.gd")
const CELL := 0.5
## The most spots the way-finder may search for one walk home (the longest on the three floors above took 3,322).
const ROUTE_BUDGET := 12000
## After this many spots with no walk home found, the rest are reported as the grid left them: a real strand is a
## whole room, and each search that fails runs to its budget.
const ROUTE_MISSES := 3
## Of the last stranded() or _cut_off(): the spots the grid alone could not walk home, before the way-finder was asked.
static var grid_only := 0
## The finer look: its step, the most spots it may search, and the most landings it may put to the way-finder.
const FINE_STEP := 0.1
const FINE_BUDGET := 8000
const FINE_TRIES := 3
## Of the last stranded() or _cut_off(): the spots the way-finder could not walk home but the finer look did.
static var fine_only := 0

## The cells a walker can stand in, keyed by Vector2i, with their feet; and the walk edges between neighbours.
static func _grid(w: Ward) -> Dictionary:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for h: Dictionary in w.layout.houses:
		lo = lo.min(Vector2(float(h.x) - float(h.w) * 0.5 - 2.0, float(h.y) - float(h.d) * 0.5 - 2.0))
		hi = hi.max(Vector2(float(h.x) + float(h.w) * 0.5 + 2.0, float(h.y) + float(h.d) * 0.5 + 2.0))
	for e: Dictionary in w.layout.bridges:
		for p: Array in e.path:
			lo = lo.min(Vector2(p[0], p[1]) - Vector2.ONE)
			hi = hi.max(Vector2(p[0], p[1]) + Vector2.ONE)
	var ld := w.lift_door()
	lo = lo.min(Vector2(ld.x, ld.z) - Vector2(2, 4))
	return {"lo": lo, "hi": hi}

static func _key(at: Vector3, lo: Vector2) -> Vector3i:
	return Vector3i(floori((at.x - lo.x) / CELL), floori((at.z - lo.y) / CELL), roundi(at.y / 1.5))

## Breadth-first over walks from `start`: every spot reached (by cell), each with the feet it was reached at.
static func _reach(w: Ward, start: Vector3, lo: Vector2) -> Dictionary:
	var seen := {_key(start, lo): start}
	var todo: Array[Vector3] = [start]
	var dirs: Array[Vector2] = [Vector2(CELL, 0), Vector2(-CELL, 0), Vector2(0, CELL), Vector2(0, -CELL)]
	while not todo.is_empty():
		var at: Vector3 = todo.pop_back()
		for d in dirs:
			var to := w.walk(at, d)
			if to.distance_to(at) < CELL * 0.5:
				continue
			var k := _key(to, lo)
			if not seen.has(k):
				seen[k] = to
				todo.append(to)
	return seen

## Where the crew stands in the car: home.
static func _car(w: Ward, lowered: bool) -> Vector3:
	var car := w.lift_door() + Vector3(0, 0.0, -1.0)
	car.y = w.footing.walking_height(Vector2(car.x, car.z), w.lift_door().y, lowered)
	return car

## True when the game's way-finder walks from `from` into the car (to within 0.45 m of where the crew stands, on the
## car's floor), the Ward as it stands.
static func _walks_home(w: Ward, from: Vector3, car: Vector3) -> bool:
	var route := Route.find(w, from, Vector2(car.x, car.z), 0.45, ROUTE_BUDGET)
	return not route.is_empty() and absf((route[-1] as Vector3).y - car.y) < 0.3

## True when FINE_STEP steps of the walk model, sixteen ways, lead from `from` to a spot one walk away from the kept
## feet of a cell the grid walks home from (`home`), that walk lands on those feet, and the way-finder walks from
## them into the car. A landing the way-finder cannot walk home is passed by (FINE_TRIES of them at most).
static func _walks_home_fine(w: Ward, from: Vector3, car: Vector3, spots: Dictionary, home: Dictionary, lo: Vector2) -> bool:
	var seen := {_fine_key(from): true}
	var todo: Array[Vector3] = [from]
	var head := 0
	var tried: Array[Vector3] = []
	while head < todo.size() and head < FINE_BUDGET and tried.size() < FINE_TRIES:
		var q := todo[head]
		head += 1
		var k := _key(q, lo)
		if home.has(k) and spots.has(k):
			var feet: Vector3 = spots[k]
			var fresh := true
			for p in tried:
				fresh = fresh and p.distance_to(feet) > 1.5
			if fresh and w.walk(q, Vector2(feet.x - q.x, feet.z - q.z)).distance_to(feet) < 0.02:
				if _walks_home(w, feet, car):
					return true
				tried.append(feet)
		for d in 16:
			var to := w.walk(q, Vector2.from_angle(d * PI / 8.0) * FINE_STEP)
			if Vector2(to.x - q.x, to.z - q.z).length() < FINE_STEP * 0.5:
				continue
			var fk := _fine_key(to)
			if not seen.has(fk):
				seen[fk] = true
				todo.append(to)
	return false

static func _fine_key(at: Vector3) -> Vector3i:
	return Vector3i(roundi(at.x / FINE_STEP), roundi(at.z / FINE_STEP), roundi(at.y / 0.25))

## Of `spots` (a _reach from the car), those with no walk back into the car, the Ward as it stands now.
static func _cut_off(w: Ward, car: Vector3, spots: Dictionary, lo: Vector2, raise_after := false) -> Array[Vector3]:
	# Every walk between reached cells (all of a cell's walks stay in the reached set when nothing changed), then
	# back from the car over them reversed: the cells with a walk home.
	var into := {}
	var dirs: Array[Vector2] = [Vector2(CELL, 0), Vector2(-CELL, 0), Vector2(0, CELL), Vector2(0, -CELL)]
	var left := {}
	for k: Vector3i in spots:
		var at: Vector3 = spots[k]
		if raise_after and not is_finite(w.footing.height_at(Vector2(at.x, at.z), false)):
			left[k] = true # a raise with someone on the deck is refused (sim/ward/state.gd _shortcut_occupied)
			continue
		for d in dirs:
			var to := w.walk(at, d)
			if to.distance_to(at) < CELL * 0.5:
				continue
			var j := _key(to, lo)
			if not into.has(j):
				into[j] = []
			(into[j] as Array).append(k)
	var home := {}
	_spread_home(_key(car, lo), into, home)
	grid_only = 0
	fine_only = 0
	for k: Vector3i in spots:
		grid_only += int(not home.has(k) and not left.has(k))
	# The grid is coarse (see the top of the file): what it could not walk home, the game's way-finder is asked, and
	# what that cannot walk home gets the finer look. One walk found brings home every cell with a grid walk to
	# that spot.
	var misses := 0
	for k: Vector3i in spots:
		if home.has(k) or left.has(k):
			continue
		if misses >= ROUTE_MISSES:
			break
		if _walks_home(w, spots[k], car):
			_spread_home(k, into, home)
		elif _walks_home_fine(w, spots[k], car, spots, home, lo):
			fine_only += 1
			_spread_home(k, into, home)
		else:
			misses += 1
	var bad: Array[Vector3] = []
	for k: Vector3i in spots:
		if not home.has(k) and not left.has(k):
			bad.append(spots[k])
	return bad

## Marks `from` and every cell with a walk into it (over `into`, the grid's walks reversed) as home.
static func _spread_home(from: Vector3i, into: Dictionary, home: Dictionary) -> void:
	home[from] = true
	var todo: Array = [from]
	while not todo.is_empty():
		var k: Vector3i = todo.pop_back()
		for f: Vector3i in into.get(k, []):
			if not home.has(f):
				home[f] = true
				todo.append(f)

## Spots reached from the lift with no walk back into the car (within 0.45 m of where the crew stands in it).
## `options` a generated layout's (WG1, sim/ward/layout.gd options; tests/prop_ward_layout.gd); {} today's Ward.
static func stranded(seed_value: int, lowered: bool, doors_open: bool, raise_after := false, options: Dictionary = {}) -> Array[Vector3]:
	var w := Ward.new(seed_value, options)
	w.bridge_lowered = lowered
	for i in w.houses.size():
		w.requested_doors[i] = doors_open
	# Boarding: the car's gate is open, as when the lift has come back for the crew.
	w.phase = &"boarding"
	var g := _grid(w)
	var car := _car(w, lowered)
	var spots := _reach(w, car, g.lo)
	if raise_after:
		w.bridge_lowered = false
	return _cut_off(w, car, spots, g.lo, raise_after)

func test_every_reachable_spot_walks_back_to_the_lift(t: T) -> void:
	# The quick set: the reported floor and one more (about a minute); the default run: twenty floors.
	var seeds: Array[int] = [183025961, 8143]
	if t.size_key() != "quick":
		seeds.append_array([0, 26, 31827])
		for k in 15:
			seeds.append(1000 + k * 7919)
	var lines: Array[String] = []
	var total := 0
	for seed_value in seeds:
		for lowered: bool in [true, false]:
			for doors: bool in [true, false]:
				var bad := stranded(seed_value, lowered, doors)
				total += bad.size()
				if not bad.is_empty():
					lines.append("seed %d bridge %s doors %s: %d spots, first %s" % [seed_value, "down" if lowered else "up", "open" if doors else "shut", bad.size(), str(bad[0].snappedf(0.01))])
		var raised := stranded(seed_value, true, true, true)
		total += raised.size()
		if not raised.is_empty():
			lines.append("seed %d lowered then raised: %d spots, first %s" % [seed_value, raised.size(), str(raised[0].snappedf(0.01))])
	t.check(total == 0, "no reachable spot is cut off from the lift: %s" % "; ".join(lines))
	t.note("%d seeds x bridge down/up x doors open/shut, and down-then-raised: %d stranded spots" % [seeds.size(), total])

## WH1: the three floors where the grid alone reported a whole wing cut off (204, 207 and 127 spots) behind a way
## out narrower than its cells. The way-finder walks home from them, so none is cut off; and the grid alone still
## misses the way, so this is the way-finder's check and not the grid's. The quick set: the first.
func test_a_way_out_narrower_than_the_grid_is_not_a_strand(t: T) -> void:
	var homes := Layout.options(null, true)
	homes["homes"] = 1
	var floors: Array = [[273673180, false, Layout.options(null), "seeded Ward, bridge up"]]
	if t.size_key() != "quick":
		floors.append([1677347106, true, Layout.options(null), "seeded Ward, bridge down"])
		floors.append([190057, true, homes, "Ward of homes, bridge down"])
	for f: Array in floors:
		var bad := stranded(int(f[0]), bool(f[1]), true, false, f[2])
		t.check(bad.is_empty(), "seed %d (%s): no reachable spot is cut off from the lift (%d)" % [f[0], f[3], bad.size()])
		t.check(grid_only > 0, "seed %d (%s): the grid alone misses the way home from %d spots, so the way-finder is what is checked here" % [f[0], f[3], grid_only])
		t.note("seed %d (%s): the grid alone could not walk home %d spots; after the way-finder, %d" % [f[0], f[3], grid_only, bad.size()])

## WH1, the 500-seed survey: the two Wards of 500 (homes off, as the game runs today) where the way-finder itself
## found no walk out of a 3-storey bedsit (199 and 204 spots). The finer look walks out, so none is cut off; and
## the way-finder alone still misses the way, so this is the finer look's check. The quick set: the first.
func test_a_way_out_finer_than_the_way_finder_is_not_a_strand(t: T) -> void:
	var floors: Array[int] = [441280502]
	if t.size_key() != "quick":
		floors.append(1677350247)
	for seed_value in floors:
		var bad := stranded(seed_value, true, true, false, Layout.options(null, true))
		t.check(bad.is_empty(), "seed %d (bridge down): no reachable spot is cut off from the lift (%d)" % [seed_value, bad.size()])
		t.check(grid_only > 0 and fine_only > 0, "seed %d: the grid alone misses the way home from %d spots and the way-finder from %d it was asked, so the finer look is what is checked here" % [seed_value, grid_only, fine_only])
		t.note("seed %d: the grid alone could not walk home %d spots; the finer look was needed %d times; after it, %d" % [seed_value, grid_only, fine_only, bad.size()])

## A real strand is still reported: the crew spreads through the Ward with every door open, then every door is
## shut. Those inside a house have no walk out (the grid, the way-finder and the finer look agree); those outside still walk home.
func test_a_room_shut_behind_someone_is_reported(t: T) -> void:
	var w := Ward.new(8143)
	w.bridge_lowered = true
	for i in w.houses.size():
		w.requested_doors[i] = true
	w.phase = &"boarding"
	var g := _grid(w)
	var car := _car(w, true)
	var spots := _reach(w, car, g.lo)
	for i in w.houses.size():
		w.requested_doors[i] = false
	var bad := _cut_off(w, car, spots, g.lo)
	t.check(not bad.is_empty() and bad.size() == grid_only, "with the doors shut behind them, spots are cut off, and the way-finder finds no walk out of them either (%d of the grid's %d)" % [bad.size(), grid_only])
	t.check(bad.size() < spots.size(), "and the spots outside the shut doors still walk home (%d cut off of %d reached)" % [bad.size(), spots.size()])
	t.note("doors shut behind the crew: %d spots cut off of %d reached" % [bad.size(), spots.size()])

## The spot from the two-client run (seed late-1, Ward seed 183025961, bridge lowered, all doors open).
func test_the_reported_spot_walks_back(t: T) -> void:
	var w := Ward.new(183025961)
	w.bridge_lowered = true
	w.phase = &"away"
	var g := _grid(w)
	var spot := Vector3(-0.94, 0.23, 15.32)
	var y := w.footing.walking_height(Vector2(spot.x, spot.z), spot.y, true)
	t.note("the reported spot: footing height %s (reported 0.23), standable by the walk model: %s" % [str(y), str(w.walk_clear(spot, spot))])
	var back := _reach(w, Vector3(spot.x, y if is_finite(y) else spot.y, spot.z), g.lo)
	# With the lift away its gate is shut: back to the mouth of the car (outside the gate) is home.
	var mouth := w.lift_door() + Vector3(0, 0, 0.5)
	var near := INF
	for k: Vector3i in back:
		near = minf(near, (back[k] as Vector3).distance_to(mouth))
	t.check(near < CELL, "from the reported spot a walk reaches the lift's mouth (nearest %.2f m)" % near)
