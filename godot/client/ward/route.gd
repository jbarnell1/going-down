# PL3: the test channel's route through the Ward (main.gd `wardroute`, tools/play_late.mjs). A search over the Ward's
# own walk model (sim/ward/state.gd walk, the one the screen walks with and the host checks against) in steps of STEP
# metres, eight ways, nearest-to-the-goal first (A*: the steps walked so far plus GREED times the straight line still
# to go).
# PL2's plain breadth-first search spread over the whole Ward before it found a long way home: from the far side of
# a lowered bridge (seed 183025961) it needed some 6500 spots, about 13 s headless, and gave up at its 12 s cap, so
# the tool reported "no route" for a player who had one (tests/test_ward_route.gd).
extends RefCounted

const Bots = preload("res://sim/ward/bots.gd")
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
	# WG1: a generated Ward (sim/ward/layout.gd generate_v2) is larger and winds more; the search is guided along the
	# layout's own graph of galleries, doors, rooms and walkways (sim/ward/bots.gd build_graph), a short search from
	# each of its points to the next, then the plain search with what is left. Today's Ward: the plain search alone.
	# Every search here keeps off walls (`wide`). A short way is found by the plain search first.
	if model.layout.get("version", 1) == 2:
		var near := {}
		var route := _search(model, from, goal, radius, mini(GUIDE_LEG, max_nodes), deadline_ms, near, true)
		var used := int(near.get("expanded", 0))
		if route.is_empty() and used < max_nodes:
			var guided := {}
			route = _guided(model, from, goal, radius, max_nodes - used, deadline_ms, guided)
			used += int(guided.get("expanded", 0))
		if route.is_empty() and used < max_nodes:
			var rest := {}
			route = _search(model, from, goal, radius, max_nodes - used, deadline_ms, rest, true)
			used += int(rest.get("expanded", 0))
		if stats is Dictionary:
			stats["expanded"] = used
			stats["found"] = not route.is_empty()
		return route
	return _search(model, from, goal, radius, max_nodes, deadline_ms, stats)

## The waypoints of the layout's graph from the node nearest `from` to the one nearest `goal` (flat), with the
## bridge as it is; each reached in turn by a short search (one it cannot reach is passed by), then the goal itself.
static func _guided(model: Variant, from: Vector3, goal: Vector2, radius: float, max_nodes: int, deadline_ms: int, stats: Dictionary) -> Array:
	var g: Bots.Graph = Bots.build_graph(model)
	var a := g.nearest(from)
	var b := -1
	var near := INF
	for i in g.pts.size():
		var d := Vector2(g.pts[i].x, g.pts[i].z).distance_to(goal)
		if d < near:
			near = d
			b = i
	var marks: Array[Vector2] = []
	for node: int in g.route(a, b, bool(model.bridge_lowered)):
		marks.append(Vector2(g.pts[node].x, g.pts[node].z))
	var used := 0
	var at := from
	var out: Array = [from]
	for mark: Vector2 in marks:
		if used >= max_nodes:
			break
		if Vector2(at.x, at.z).distance_to(mark) < 0.45:
			continue
		var s := {}
		var leg := _search(model, at, mark, 0.45, mini(GUIDE_LEG, max_nodes - used), deadline_ms, s, true)
		used += int(s.get("expanded", 0))
		if leg.size() > 1:
			out.append_array(leg.slice(1))
			at = leg[-1]
	var last := {}
	var tail := _search(model, at, goal, radius, max_nodes - used, deadline_ms, last, true) if used < max_nodes else []
	used += int(last.get("expanded", 0))
	stats["expanded"] = used
	if tail.is_empty():
		return []
	out.append_array(tail.slice(1))
	return out

## The most spots one leg of a guided search may search before it is passed by.
const GUIDE_LEG := 1500

## What each blocked push from a spot adds to the cost of walking on from it, in a `wide` search (metres).
const WALL_COST := 0.25

static func _search(model: Variant, from: Vector3, goal: Vector2, radius := 0.45, max_nodes := 40000, deadline_ms := 0, stats: Variant = null, wide := false) -> Array:
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
		var pushes: Array[Vector3] = []
		var blocked := 0
		for d in 8:
			var dir := Vector2.from_angle(d * PI / 4.0) * STEP
			pushes.append(model.walk(q, dir))
			if Vector2(pushes[d].x - q.x, pushes[d].z - q.z).length() < STEP * 0.8:
				blocked += 1
		# WG1 (`wide`): a spot beside a wall costs more to walk on from, so the way keeps off corners a walker's
		# straight steps would catch on.
		var penalty := WALL_COST * blocked if wide else 0.0
		for d in 8:
			var nq: Vector3 = pushes[d]
			var moved := Vector2(nq.x - q.x, nq.z - q.z).length()
			if moved < STEP * 0.8:
				continue
			var nk: Vector3i = _key(nq)
			var g := float(cost[k]) + moved + penalty
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
