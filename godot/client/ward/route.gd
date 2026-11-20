# PL3: the test channel's route through the Ward (main.gd `wardroute`, tools/play_late.mjs). A search over the Ward's
# own walk model (sim/ward/state.gd walk, the one the screen walks with and the host checks against) in steps of STEP
# metres, eight ways, nearest-to-the-goal first (A*: the steps walked so far plus GREED times the straight line still
# to go).
# PL2's plain breadth-first search spread over the whole Ward before it found a long way home: from the far side of
# a lowered bridge (seed 183025961) it needed some 6500 spots, about 13 s headless, and gave up at its 12 s cap, so
# the tool reported "no route" for a player who had one (tests/test_ward_route.gd).
extends RefCounted

const STEP := 0.3
## How much more the straight line still to go counts than the steps walked (1: the shortest route; more: fewer spots
## searched for a route a little longer). The tool only needs a walkable way, not the shortest.
const GREED := 2.0

static func _key(v: Vector3) -> Vector3i:
	return Vector3i(roundi(v.x / STEP), roundi(v.z / STEP), roundi(v.y / 0.5))

## Waypoints [x, y, z] from `from` to within `radius` of `goal` (flat), `from` first; empty when none was found within
## `max_nodes` spots searched or before `deadline_ms` (Time.get_ticks_msec; 0: none). `stats`, when given, gets
## "expanded" (spots searched) and "found".
static func find(model: Variant, from: Vector3, goal: Vector2, radius := 0.45, max_nodes := 40000, deadline_ms := 0, stats: Variant = null) -> Array:
	var start: Vector3i = _key(from)
	var came := {start: null}
	var at := {start: from}
	var cost := {start: 0.0}
	# A binary heap of [priority, order, key]; the order keeps ties first-in first-out.
	var heap: Array = [[Vector2(from.x, from.z).distance_to(goal), 0, start]]
	var order := 1
	var done := {}
	var expanded := 0
	var found: Variant = null
	while not heap.is_empty() and expanded < max_nodes and (deadline_ms <= 0 or Time.get_ticks_msec() < deadline_ms):
		var top: Array = _pop(heap)
		var k: Vector3i = top[2]
		if done.has(k):
			continue
		done[k] = true
		expanded += 1
		var q: Vector3 = at[k]
		if Vector2(q.x, q.z).distance_to(goal) < radius:
			found = k
			break
		for d in 8:
			var dir := Vector2.from_angle(d * PI / 4.0) * STEP
			var nq: Vector3 = model.walk(q, dir)
			var moved := Vector2(nq.x - q.x, nq.z - q.z).length()
			if moved < STEP * 0.8:
				continue
			var nk: Vector3i = _key(nq)
			var g := float(cost[k]) + moved
			if done.has(nk) or (cost.has(nk) and float(cost[nk]) <= g):
				continue
			cost[nk] = g
			came[nk] = k
			at[nk] = nq
			_push(heap, [g + GREED * Vector2(nq.x, nq.z).distance_to(goal), order, nk])
			order += 1
	if stats is Dictionary:
		stats["expanded"] = expanded
		stats["found"] = found != null
	var route: Array = []
	var ck: Variant = found
	while ck != null:
		route.push_front(at[ck])
		ck = came[ck]
	return route

static func _less(a: Array, b: Array) -> bool:
	return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1])

static func _push(heap: Array, item: Array) -> void:
	heap.append(item)
	var i := heap.size() - 1
	while i > 0:
		var p := (i - 1) >> 1
		if not _less(heap[i], heap[p]):
			break
		var tmp: Variant = heap[i]
		heap[i] = heap[p]
		heap[p] = tmp
		i = p

static func _pop(heap: Array) -> Array:
	var top: Array = heap[0]
	var last: Array = heap.pop_back()
	if not heap.is_empty():
		heap[0] = last
		var i := 0
		var n := heap.size()
		while true:
			var l := i * 2 + 1
			var r := l + 1
			var m := i
			if l < n and _less(heap[l], heap[m]):
				m = l
			if r < n and _less(heap[r], heap[m]):
				m = r
			if m == i:
				break
			var tmp: Variant = heap[i]
			heap[i] = heap[m]
			heap[m] = tmp
			i = m
	return top
