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
					_route = _find_route(_probes[search_area]) if door_open or not _enters_by_door else PackedVector3Array()
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
			if visited[next] == 0 and proposed <= REACH and proposed < costs[next] and segment_clear(graph[current], graph[next], PALM_RADIUS):
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
	return rounded if length <= REACH else route

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
	return door_open or not _hits_box(from, to, _door, radius)

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
