extends RefCounted

signal warned(area: StringName)

const REACH := 7.4 # Includes the 0.6 m from the shoulder to the sill.
const ARM_RADIUS := 0.09
const PALM_RADIUS := 0.18
const PLAYER_RADIUS := 0.28
const WARNING_SECONDS := 1.15
const PROBE_SECONDS := 0.6
const OUT_SPEED := 1.45
const IN_SPEED := 2.6
const EPSILON := 0.0001
const CORNER_TRIM := 0.38
const CURVE_STEPS := 6

## WD1: the host's live settings (sim/ward/state.gd make_arm sets them; today's are the constants above).
var warning_seconds := WARNING_SECONDS
var probe_seconds := PROBE_SECONDS
var out_speed := OUT_SPEED
var in_speed := IN_SPEED
## RR1: how far this arm pays out from its shoulder (sim/ward/house.gd opening_reach may shorten it for an opening so
## that one room stays out of reach); today's is REACH.
var reach := REACH

var points := PackedVector3Array()
var phase: StringName = &"idle"
var search_area: StringName = &""
var last_heard_area: StringName = &""
var contacts: Array = []
var door_open := true
var door_held_open := false

var _shoulder: Vector3
var _enters_by_door: bool
var _door: AABB
var _walls: Array[AABB]
var _probes: Dictionary
var _guides: PackedVector3Array
var _order: Array[StringName] = []
var _pending: Array[StringName] = []
var _caught: Dictionary = {}
var _route := PackedVector3Array()
var _distances := PackedFloat64Array()
var _travel := 0.0
var _timer := 0.0

func _init(shoulder: Vector3, door: AABB, walls: Array[AABB],
		guides: PackedVector3Array, probes: Dictionary, seed_value: int, enters_by_door := true) -> void:
	_enters_by_door = enters_by_door
	_shoulder = shoulder
	_door = door
	_walls = walls.duplicate()
	_guides = guides.duplicate()
	_probes = probes.duplicate()
	for area: StringName in probes:
		_order.append(area)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	for i in range(_order.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var saved := _order[i]
		_order[i] = _order[j]
		_order[j] = saved
	points.append(_shoulder)

## RR1 stage 2: hear a room at a point in it (local): the hand goes to that point rather than the room's middle, so it
## follows the player it heard (the middle when no route reaches the point). Only the crawling Rigger calls this.
func hear_at(area: StringName, point: Vector3) -> void:
	if not _probes.has(area):
		return
	_aim[area] = point
	hear(area)

var _aim := {}

func hear(area: StringName) -> void:
	if not _probes.has(area):
		return
	last_heard_area = area
	if phase == &"idle":
		_pending = _order.duplicate()
		_caught.clear()
		_pending.erase(area)
		_pending.push_front(area)
		_begin_next()
	elif area != search_area:
		_pending.erase(area)
		_pending.push_front(area)

## RR1: draw the arm back out and search no further from here (he is moving to another opening, or has searched from
## this one long enough). Nothing is touched on the way out that would not be touched retracting today.
func withdraw() -> void:
	_pending.clear()
	if phase == &"warning":
		_begin_next()
	elif phase == &"extending" or phase == &"probing":
		phase = &"retracting"

func step(delta: float, player_contacts: Dictionary, requested_door_open: bool = true) -> void:
	contacts.clear()
	door_held_open = false
	door_open = requested_door_open
	if not requested_door_open and _travel > EPSILON and (_enters_by_door or _touches_door()):
		# A closing door forces withdrawal. The leaf can close once the arm clears
		# its swept volume, so it never appears through an extended limb.
		door_held_open = _touches_door()
		door_open = door_held_open
		phase = &"retracting"
	var remaining := maxf(delta, 0.0)
	while phase != &"idle" and remaining > EPSILON:
		match phase:
			&"warning":
				remaining = _consume_timer(remaining)
				if _timer <= EPSILON:
					_route = PackedVector3Array()
					if door_open or not _enters_by_door:
						if _aim.has(search_area):
							_route = _find_route(_aim[search_area])
							_aim.erase(search_area)
						if _route.is_empty():
							_route = _find_route(_probes[search_area])
					if _route.is_empty():
						_begin_next()
					else:
						_distances = PackedFloat64Array([0.0])
						for i in range(1, _route.size()):
							_distances.append(_distances[-1] + _route[i - 1].distance_to(_route[i]))
						phase = &"extending"
			&"extending":
				var used := minf((_distances[-1] - _travel) / out_speed, remaining)
				var old_travel := _travel
				_travel = minf(_travel + used * out_speed, _distances[-1])
				_check_sweep(old_travel, _travel, player_contacts)
				_update_points()
				remaining -= used
				if _distances[-1] - _travel <= EPSILON:
					phase = &"probing"
					_timer = probe_seconds
			&"probing":
				_check_sweep(_travel, _travel, player_contacts)
				remaining = _consume_timer(remaining)
				if _timer <= EPSILON:
					phase = &"retracting"
			&"retracting":
				var used := minf(_travel / in_speed, remaining)
				_travel = maxf(_travel - used * in_speed, 0.0)
				_update_points()
				remaining -= used
				if not requested_door_open:
					door_held_open = _touches_door()
					door_open = door_held_open
				if _travel <= EPSILON:
					_begin_next()

func _begin_next() -> void:
	_travel = 0.0
	_route.clear()
	_distances.clear()
	points = PackedVector3Array([_shoulder])
	if _pending.is_empty():
		phase = &"idle"
		search_area = &""
		return
	search_area = _pending.pop_front()
	phase = &"warning"
	_timer = warning_seconds
	warned.emit(search_area)

func _consume_timer(remaining: float) -> float:
	var used := minf(remaining, _timer)
	_timer -= used
	return remaining - used

func _touches_door() -> bool:
	if points.size() == 1:
		return _hits_box(points[0], points[0], _door, PALM_RADIUS)
	for i in range(1, points.size()):
		var radius := PALM_RADIUS if i == points.size() - 1 else ARM_RADIUS
		if _hits_box(points[i - 1], points[i], _door, radius):
			return true
	return false

func _find_route(target: Vector3) -> PackedVector3Array:
	var graph := PackedVector3Array([_shoulder])
	graph.append_array(_guides)
	graph.append(target)
	var end := graph.size() - 1
	var costs := PackedFloat64Array()
	var parents := PackedInt32Array()
	var visited := PackedByteArray()
	costs.resize(graph.size())
	costs.fill(INF)
	parents.resize(graph.size())
	parents.fill(-1)
	visited.resize(graph.size())
	costs[0] = 0.0
	for _iteration in graph.size():
		var current := -1
		var best := INF
		for i in graph.size():
			if visited[i] == 0 and costs[i] < best:
				best = costs[i]
				current = i
		if current == -1:
			break
		if current == end:
			var result := PackedVector3Array()
			while current >= 0:
				result.append(graph[current])
				current = parents[current]
			result.reverse()
			return _round_route(result)
		visited[current] = 1
		for next in graph.size():
			var proposed := best + graph[current].distance_to(graph[next])
			if visited[next] == 0 and proposed <= reach and proposed < costs[next] and (_graph_clear(current, next) if not _graph.is_empty() and next != end and current != end else segment_clear(graph[current], graph[next], PALM_RADIUS)):
				costs[next] = proposed
				parents[next] = current
	return PackedVector3Array()

func _round_route(route: PackedVector3Array) -> PackedVector3Array:
	var rounded := PackedVector3Array([route[0]])
	for i in range(1, route.size() - 1):
		var before := route[i - 1]
		var corner := route[i]
		var after := route[i + 1]
		var incoming := corner - before
		var outgoing := after - corner
		var trim := minf(CORNER_TRIM, minf(incoming.length(), outgoing.length()) * 0.4)
		var curve := PackedVector3Array()
		if incoming.normalized().dot(outgoing.normalized()) < 0.995:
			for reduction: float in [1.0, 0.5, 0.25]:
				var offset: float = trim * reduction
				curve = _corner_curve(corner - incoming.normalized() * offset,
					corner, corner + outgoing.normalized() * offset)
				if not curve.is_empty():
					break
		if curve.is_empty():
			rounded.append(corner)
		else:
			rounded.append_array(curve)
	rounded.append(route[-1])
	var length := 0.0
	for i in range(1, rounded.size()):
		if not segment_clear(rounded[i - 1], rounded[i]):
			return route
		length += rounded[i - 1].distance_to(rounded[i])
	return rounded if length <= reach else route

func _corner_curve(entry: Vector3, corner: Vector3, exit: Vector3) -> PackedVector3Array:
	var curve := PackedVector3Array([entry])
	for i in range(1, CURVE_STEPS + 1):
		var t := float(i) / float(CURVE_STEPS)
		var next := entry.lerp(corner, t).lerp(corner.lerp(exit, t), t)
		if not segment_clear(curve[-1], next):
			return PackedVector3Array()
		curve.append(next)
	return curve

func segment_clear(from: Vector3, to: Vector3, radius: float = PALM_RADIUS) -> bool:
	for wall in _walls:
		if _hits_box(from, to, wall, radius):
			return false
	# WH1: a Ward home's inner doors stop the arm while shut (none in today's houses).
	for k in _inner.size():
		if _inner_open[k] == 0 and _hits_box(from, to, _inner[k], radius):
			return false
	return door_open or not _hits_box(from, to, _door, radius)

# ------------------------------------------------------------------------------------------------
# WH1: a Ward home's arm (sim/ward/house.gd _homes_arm). Its bend points are worked out from the walls and furniture
# (corner_guides), not placed by hand; its inner doors stop it while shut; and the clear lines between its shoulder
# and its bend points are worked out once (build_graph) so a search costs no more than today's. Today's arms use none
# of this: no inner doors, no graph, and every route found exactly as before.

## How far past the palm's own size a bend point stands off a corner (today's hand-placed ones stand 0.26-0.29 m off).
const GUIDE_GAP := 0.08

var _inner: Array[AABB] = []
var _inner_open := PackedByteArray()
## For each pair of graph points (the shoulder, then the guides), 0 when walls stand between them, else 1 plus bit 1
## when the front door's leaf is in the way and bit 2+k when inner door k is.
var _graph := PackedInt32Array()

## The bend points round a set of boxes at a height: each corner of every box the palm meets there, stood off by the
## palm's size and GUIDE_GAP, kept where `keep` says, clear of every box and not within 10 cm of one already kept.
static func corner_guides(boxes: Array[AABB], y: float, keep: Callable) -> PackedVector3Array:
	var plane: Array[AABB] = []
	for b in boxes:
		if b.position.y - PALM_RADIUS <= y and b.end.y + PALM_RADIUS >= y:
			plane.append(b)
	var r := PALM_RADIUS + GUIDE_GAP
	var out := PackedVector3Array()
	for b in plane:
		for cx: float in [b.position.x - r, b.end.x + r]:
			for cz: float in [b.position.z - r, b.end.z + r]:
				var p := Vector3(cx, y, cz)
				if not keep.call(p):
					continue
				var free := true
				for o in plane:
					if _hits_box(p, p, o, PALM_RADIUS + 0.01):
						free = false
						break
				if not free:
					continue
				var near := false
				for q in out:
					if q.distance_squared_to(p) < 0.01:
						near = true
						break
				if not near:
					out.append(p)
	return out

## The inner doors' openings (local) and which stand open (shared with the house, so a shut door is seen at once).
func set_inner_doors(leaves: Array[AABB], open: PackedByteArray) -> void:
	_inner = leaves.duplicate()
	_inner_open = open

func inner_doors_open(open: PackedByteArray) -> void:
	_inner_open = open

## The clear lines between the shoulder and every bend point (see _graph).
func build_graph() -> PackedInt32Array:
	var nodes := PackedVector3Array([_shoulder])
	nodes.append_array(_guides)
	var n := nodes.size()
	var out := PackedInt32Array()
	out.resize(n * n)
	for i in n:
		for j in range(i + 1, n):
			var v := 1
			for wall in _walls:
				if _hits_box(nodes[i], nodes[j], wall, PALM_RADIUS):
					v = 0
					break
			if v != 0:
				if _hits_box(nodes[i], nodes[j], _door, PALM_RADIUS):
					v |= 2
				for k in _inner.size():
					if _hits_box(nodes[i], nodes[j], _inner[k], PALM_RADIUS):
						v |= 4 << k
			out[i * n + j] = v
			out[j * n + i] = v
	return out

func use_graph(graph: PackedInt32Array) -> void:
	var n := _guides.size() + 1
	_graph = graph if graph.size() == n * n else PackedInt32Array()

## segment_clear for two graph points, from the graph.
func _graph_clear(i: int, j: int) -> bool:
	var v := _graph[i * (_guides.size() + 1) + j]
	if v == 0:
		return false
	if (v & 2) != 0 and not door_open:
		return false
	for k in _inner.size():
		if (v & (4 << k)) != 0 and _inner_open[k] == 0:
			return false
	return true

# Expanding the obstacle on all axes is conservative for a finite-radius sweep,
# including at corners. The slab test covers the whole segment in one step.
static func _hits_box(from: Vector3, to: Vector3, box: AABB, radius: float) -> bool:
	var bounds := box.grow(radius)
	var displacement := to - from
	var low := 0.0
	var high := 1.0
	for axis in 3:
		if absf(displacement[axis]) < EPSILON:
			if from[axis] < bounds.position[axis] or from[axis] > bounds.end[axis]:
				return false
			continue
		var enter := (bounds.position[axis] - from[axis]) / displacement[axis]
		var leave := (bounds.end[axis] - from[axis]) / displacement[axis]
		low = maxf(low, minf(enter, leave))
		high = minf(high, maxf(enter, leave))
		if low > high:
			return false
	return true

func _point_on_leg(leg: int, distance: float) -> Vector3:
	var length := _distances[leg] - _distances[leg - 1]
	if length <= EPSILON:
		return _route[leg]
	return _route[leg - 1].lerp(_route[leg], clampf((distance - _distances[leg - 1]) / length, 0.0, 1.0))

func _update_points() -> void:
	points = PackedVector3Array([_shoulder])
	if _travel <= EPSILON:
		return
	for leg in range(1, _route.size()):
		points.append(_point_on_leg(leg, _travel))
		if _distances[leg] >= _travel:
			break

func _check_sweep(start: float, finish: float, player_contacts: Dictionary) -> void:
	for leg in range(1, _route.size()):
		if finish < _distances[leg - 1] or start > _distances[leg]:
			continue
		var from := _point_on_leg(leg, start)
		var to := _point_on_leg(leg, finish)
		# Clip the palm sweep at the inside edge of the entrance before
		# testing its closest point to a player.
		if from.z < PALM_RADIUS and to.z < PALM_RADIUS:
			continue
		if from.z < PALM_RADIUS:
			from = from.lerp(to, inverse_lerp(from.z, to.z, PALM_RADIUS))
		elif to.z < PALM_RADIUS:
			to = to.lerp(from, inverse_lerp(to.z, from.z, PALM_RADIUS))
		for id: Variant in player_contacts:
			if _caught.has(id):
				continue
			var torso: Vector3 = player_contacts[id]
			var nearest := Geometry3D.get_closest_point_to_segment(torso, from, to) if not from.is_equal_approx(to) else from
			var touch_radius := PALM_RADIUS + PLAYER_RADIUS
			# Only an interior palm may capture, and it cannot touch around a solid corner.
			if nearest.distance_squared_to(torso) <= touch_radius * touch_radius and segment_clear(nearest, torso, 0.0):
				contacts.append(id)
				_caught[id] = true
