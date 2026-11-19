extends RefCounted

# Render-space coordinates are in metres. Z is up; positive Y is deeper into the ward.
# A location is the centre of the ground floor. The continuous gallery runs around it.
const GALLERY := 1.6
const STYLES := [
	["weavers_terrace", 2, 7.4, 4.4], ["laundry_maisonette", 2, 8.6, 5.0],
	["lampkeepers_cottage", 1, 5.4, 4.5], ["underbridge_bedsits", 3, 5.8, 4.0],
	["boarders_flat", 2, 7.0, 5.0], ["hoist_rowhouse", 2, 6.2, 5.8],
	["attic_workshop", 2, 6.4, 4.8]]

static func _shuffle(values: Array, rng: RandomNumberGenerator) -> void:
	for i in range(values.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var old: Variant = values[i]
		values[i] = values[j]
		values[j] = old

static func _component(groups: Array, id: int) -> int:
	while groups[id] != id:
		id = groups[id]
	return id

static func _dock(h: Dictionary, side: String) -> Array:
	var x: float = h.x
	var y: float = h.y
	match side:
		"east": x += float(h.w) * 0.5 + GALLERY
		"west": x -= float(h.w) * 0.5 + GALLERY
		"north": y += float(h.d) * 0.5 + GALLERY
		"south": y -= float(h.d) * 0.5 + GALLERY
	return [x, y, float(h.z) + 0.15]

static func generate(seed_value: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var styles := STYLES.duplicate()
	_shuffle(styles, rng)
	var cells := [Vector2i.ZERO]
	for row: int in [1, 2]:
		for col: int in [-1, 0, 1]:
			cells.append(Vector2i(col, row))
	cells.append(Vector2i(rng.randi_range(-1, 1), 3))
	var houses := []
	for i in cells.size():
		var cell: Vector2i = cells[i]
		var style: Array = ["parlour_cottage", 1, 6.8, 6.2] if i == 0 else styles[i - 1]
		var x := 0.0
		var y := -3.1
		var z := 0.0
		if i > 0:
			x = cell.x * 16.0 + rng.randf_range(-1.1, 1.1)
			y += cell.y * 14.5 + rng.randf_range(-1.0, 1.0)
			z = cell.y * 0.32 + cell.x * 0.38 + rng.randf_range(-0.36, 0.36)
		houses.append({"id":i, "style":style[0], "floors":style[1], "w":style[2],
			"d":style[3], "x":x, "y":y, "z":z})
	var candidates := []
	for i in cells.size():
		for j in range(i + 1, cells.size()):
			var delta: Vector2i = cells[j] - cells[i]
			if absi(delta.x) + absi(delta.y) != 1:
				continue
			var side := "east" if delta.x == 1 else "north"
			var other := "west" if delta.x == 1 else "south"
			candidates.append({"a":i, "b":j, "a_side":side, "b_side":other, "kind":"fixed",
				"path":[_dock(houses[i], side), _dock(houses[j], other)]})
	_shuffle(candidates, rng)
	var groups := range(houses.size())
	var bridges := []
	var spare := []
	for edge: Dictionary in candidates:
		var left := _component(groups, edge.a)
		var right := _component(groups, edge.b)
		if left == right:
			spare.append(edge)
		else:
			groups[left] = right
			bridges.append(edge)
	# The only movable bridge is on a cycle; every destination has a fixed way home.
	var winch: Dictionary = spare.pop_front()
	winch.kind = "winch"
	bridges.append(winch)
	if not spare.is_empty() and rng.randi_range(0, 1) == 1:
		bridges.append(spare[0])
	# Close porches on wide buildings shorten the usable span. Fit elevations
	# to the actual decks, after their style, footprint and routes are known.
	var vertical_scale := 1.0
	for edge: Dictionary in bridges:
		var p: Array = edge.path[0]
		var q: Array = edge.path[1]
		var rise := absf(p[2] - q[2])
		var run_length := Vector2(p[0], p[1]).distance_to(Vector2(q[0], q[1]))
		if rise > 0.20 * run_length:
			vertical_scale = minf(vertical_scale, 0.20 * run_length / rise)
	if vertical_scale < 1.0:
		for h: Dictionary in houses:
			h.z *= vertical_scale
		for edge: Dictionary in bridges:
			edge.path = [_dock(houses[edge.a], edge.a_side), _dock(houses[edge.b], edge.b_side)]
	# Route the arrival bridge beside the parlour. Preserve clear air below the
	# north window for the resident, even when its body passes below deck level.
	for edge: Dictionary in bridges:
		if edge.a != 0:
			continue
		edge.a_side = "east"
		var start := _dock(houses[0], "east")
		var end: Array = edge.path[-1]
		var outer_x := maxf(start[0], end[0]) + 3.0
		var first_length := outer_x - float(start[0])
		var second_length := absf(end[1] - start[1])
		var total := first_length + second_length + outer_x - float(end[0])
		edge.path = [start, [outer_x, start[1], lerpf(start[2], end[2], first_length / total)],
			[outer_x,end[1],lerpf(start[2],end[2],(first_length+second_length)/total)], end]
	return {"version":1, "seed":seed_value, "houses":houses, "bridges":bridges}
