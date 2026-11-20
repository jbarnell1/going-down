# WD1: "A raised shortcut can never strand someone." Over many floor seeds, for the bridge lowered and raised and for
# every door all open or all shut, every spot a walker can reach from the lift by the Ward's own walk model
# (sim/ward/state.gd walk, the model the screen walks with and the host checks against) has a walk back to the lift.
# The grid: cells of CELL metres on every standing surface, joined where state.walk carries a walker from one cell's
# middle to the next (the screen's own 7 cm sliding steps), both ways tested separately. Also: a raise of the bridge
# under someone is refused, so the lowered-then-raised case starts from the lowered reach.
extends RefCounted

const T = preload("res://tests/t.gd")
const Ward = preload("res://sim/ward/state.gd")
const CELL := 0.5

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

## Spots reached from the lift with no walk back into the car (within 1 m of where the crew stands in it).
static func stranded(seed_value: int, lowered: bool, doors_open: bool, raise_after := false) -> Array[Vector3]:
	var w := Ward.new(seed_value)
	w.bridge_lowered = lowered
	for i in w.houses.size():
		w.requested_doors[i] = doors_open
	# Boarding: the car's gate is open, as when the lift has come back for the crew.
	w.phase = &"boarding"
	var g := _grid(w)
	var car := w.lift_door() + Vector3(0, 0.0, -1.0)
	car.y = w.footing.walking_height(Vector2(car.x, car.z), w.lift_door().y, lowered)
	var spots := _reach(w, car, g.lo)
	if raise_after:
		w.bridge_lowered = false
	# Every walk between reached cells (all of a cell's walks stay in the reached set when nothing changed), then
	# back from the car over them reversed: the cells with a walk home.
	var into := {}
	var dirs: Array[Vector2] = [Vector2(CELL, 0), Vector2(-CELL, 0), Vector2(0, CELL), Vector2(0, -CELL)]
	for k: Vector3i in spots:
		var at: Vector3 = spots[k]
		if raise_after and not is_finite(w.footing.height_at(Vector2(at.x, at.z), false)):
			continue # a raise with someone on the deck is refused (sim/ward/state.gd _shortcut_occupied)
		for d in dirs:
			var to := w.walk(at, d)
			if to.distance_to(at) < CELL * 0.5:
				continue
			var j := _key(to, g.lo)
			if not into.has(j):
				into[j] = []
			(into[j] as Array).append(k)
	var home := {_key(car, g.lo): true}
	var todo: Array = [_key(car, g.lo)]
	while not todo.is_empty():
		var k: Vector3i = todo.pop_back()
		for f: Vector3i in into.get(k, []):
			if not home.has(f):
				home[f] = true
				todo.append(f)
	var bad: Array[Vector3] = []
	for k: Vector3i in spots:
		var spot: Vector3 = spots[k]
		if raise_after and not is_finite(w.footing.height_at(Vector2(spot.x, spot.z), false)):
			continue
		if not home.has(k):
			bad.append(spot)
	return bad

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

## The spot from the two-client run (seed late-1, Ward seed 183025961, bridge lowered, all doors open).
func test_the_reported_spot_walks_back(t: T) -> void:
	var w := Ward.new(183025961)
	w.bridge_lowered = true
	w.phase = &"away"
	var g := _grid(w)
	var spot := Vector3(-0.94, 0.23, 15.32)
	var y := w.footing.walking_height(Vector2(spot.x, spot.z), spot.y, true)
	t.note("the reported spot: footing height %s (reported 0.23), standable by the walk model: %s" % [str(y), str(w.walk_clear(spot, spot))])
	var car := w.lift_door() + Vector3(0, 0.0, -1.0)
	car.y = w.footing.walking_height(Vector2(car.x, car.z), w.lift_door().y, true)
	var back := _reach(w, Vector3(spot.x, y if is_finite(y) else spot.y, spot.z), g.lo)
	# With the lift away its gate is shut: back to the mouth of the car (outside the gate) is home.
	var mouth := w.lift_door() + Vector3(0, 0, 0.5)
	var near := INF
	for k: Vector3i in back:
		near = minf(near, (back[k] as Vector3).distance_to(mouth))
	t.check(near < CELL, "from the reported spot a walk reaches the lift's mouth (nearest %.2f m)" % near)
