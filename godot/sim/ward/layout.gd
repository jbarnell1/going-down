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

## The Ward's layout from the floor seed. `options` empty (the run flag `ward_layout` off, net/host_rules.gd): today's
## Ward, exactly. With options {"version": 2, "spread": times, "rise": metres} (WG1; Layout.options builds them from the
## host's live settings and the host sends them in the Ward block, so every screen builds the same): generate_v2.
static func generate(seed_value: int, options: Dictionary = {}) -> Dictionary:
	if int(options.get("version", 1)) == 2:
		return generate_v2(seed_value, float(options.get("spread", SPREAD)), float(options.get("rise", RISE)),
			options.get("lift_clear", false) == true, int(options.get("homes", 0)) == 1)
	return _generate_v1(seed_value)

static func _generate_v1(seed_value: int) -> Dictionary:
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

# ------------------------------------------------------------------------------------------------
# WG1: more of the Ward from the floor seed (the run flag `ward_layout`, net/host_rules.gd). The design: "Exactly eight
# homes are laid out from the floor seed. The lift opens into the parlour cottage. Permanent walkways connect all
# eight homes in both directions. A powered drawbridge cuts across one loop." What the seed now chooses:
#   - the shape: eight cells of a COLS x ROWS lattice, grown from the parlour's cell one neighbour at a time until the
#     walkways between neighbours hold a loop (so the parlour can sit at an end, a corner or the middle);
#   - which style hangs in which cell, each house's facing (its front door towards any of the four sides; the
#     parlour keeps today's, because the lift's car is built on its south wall) and whether its stair runs the other
#     way (`mirror`); where each hangs within its cell;
#   - which neighbours are joined: a random tree of fixed walkways (every house reachable with the bridge raised),
#     the drawbridge on a spare one (so it always cuts across a loop; `loop` names the houses round it), and up to
#     two more fixed walkways;
#   - heights: a walk along the tree from the parlour, each walkway rising or falling up to SLOPE of its length,
#     within +/- rise of the parlour.
# Every draw is made whatever the settings say (they only scale lengths), so a setting never adds or removes a random
# draw (sim/settings.gd). The data has today's shape (houses: id, style, floors, w, d, x, y, z, with w and d the
# footprint east-west and north-south as today; bridges: a, b, a_side, b_side, kind, path) plus new fields: each
# house's facing (0 door south, 1 east, 2 north, 3 west), mirror and cell; the layout's loop, spread and rise.

const Settings = preload("res://sim/settings.gd")
const Homes = preload("res://sim/ward/homes.gd")
const PARLOUR := ["parlour_cottage", 1, 6.8, 6.2]
## The lattice: COLS x ROWS cells, CELL metres apart times the live setting ward.spread (today's SPREAD).
const COLS := 4
const ROWS := 4
const CELL := 15.0
const SPREAD := 1.1
## Heights within +/- the live setting ward.rise metres of the parlour (today's RISE).
const RISE := 1.5
## The steepest a walkway may be (rise over run); the footing walks far steeper (sim/ward/footing.gd MAX_STEP_UP).
const SLOPE := 0.18
## How far a house may hang from the middle of its cell, each way.
const JITTER := 1.0
const DIRS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

## The options the host's live settings make (sim/settings.gd ward.spread, ward.rise), on the wire's hundredth.
## RL1: `lift_clear` (the run flag ward_lift_clear, net/host_rules.gd) adds "lift_clear": true; off, the options are
## exactly what they were.
static func options(tuning: Settings.Values, lift_clear := false) -> Dictionary:
	var out := {"version": 2, "spread": snappedf(Settings.f(tuning, &"ward.spread", SPREAD), 0.01),
		"rise": snappedf(Settings.f(tuning, &"ward.rise", RISE), 0.01)}
	if lift_clear:
		out["lift_clear"] = true
	return out

## The options as the Ward block carries them (net/ward_wire.gd): [version, spread in hundredths, rise in cm], and a
## fourth element 1 only with RL1's lift_clear (without it, the three they always were). WH1: the homes (the run flag
## ward_homes) ride as a fifth element 1, after a fourth that is then always there (1 with lift_clear, else 0); with
## the homes off the wire is exactly RL1's.
static func to_wire(opts: Dictionary) -> Array:
	var out := [int(opts.get("version", 2)), roundi(float(opts.get("spread", SPREAD)) * 100.0), roundi(float(opts.get("rise", RISE)) * 100.0)]
	var lift_clear: bool = opts.get("lift_clear", false) == true
	var homes := int(opts.get("homes", 0)) == 1
	if lift_clear or homes:
		out.append(1 if lift_clear else 0)
	if homes:
		out.append(1)
	return out

## Back from the wire; {} (today's Ward) for anything else. Three fields; four with the fourth 1 (lift_clear); or five
## with the fourth 0 or 1 (lift_clear) and the fifth 1 (WH1's homes).
static func from_wire(raw: Variant) -> Dictionary:
	if not raw is Array or (raw as Array).size() < 3 or (raw as Array).size() > 5:
		return {}
	var size := (raw as Array).size()
	if size == 4 and int(raw[3]) != 1:
		return {}
	if size == 5 and ((int(raw[3]) != 0 and int(raw[3]) != 1) or int(raw[4]) != 1):
		return {}
	var out := {"version": int(raw[0]), "spread": float(raw[1]) / 100.0, "rise": float(raw[2]) / 100.0}
	if size >= 4 and int(raw[3]) == 1:
		out["lift_clear"] = true
	if size == 5:
		out["homes"] = 1
	return out

static func _cell_links(cells: Array[Vector2i]) -> Array[Dictionary]:
	const SIDES := {Vector2i(1, 0): ["east", "west"], Vector2i(-1, 0): ["west", "east"],
		Vector2i(0, 1): ["north", "south"], Vector2i(0, -1): ["south", "north"]}
	var out: Array[Dictionary] = []
	for i in cells.size():
		for j in range(i + 1, cells.size()):
			var delta: Vector2i = cells[j] - cells[i]
			if absi(delta.x) + absi(delta.y) != 1:
				continue
			# The lift's car stands on the parlour's south wall: no walkway docks there.
			if i == 0 and delta == Vector2i(0, -1):
				continue
			out.append({"a": i, "b": j, "a_side": SIDES[delta][0], "b_side": SIDES[delta][1], "kind": "fixed"})
	return out

static func _spans_all(count: int, links: Array[Dictionary]) -> bool:
	var groups := range(count)
	var joined := 1
	for link: Dictionary in links:
		var left := _component(groups, link.a)
		var right := _component(groups, link.b)
		if left != right:
			groups[left] = right
			joined += 1
	return joined == count

static func _rise_ok(edge: Dictionary) -> bool:
	var p: Array = edge.path[0]
	var q: Array = edge.path[1]
	return absf(p[2] - q[2]) <= SLOPE * Vector2(p[0], p[1]).distance_to(Vector2(q[0], q[1])) + 1e-6

## RL1 (the owner, 21 Nov: "I'm ok with making the lift never the lowest house"): the Rigger lives below the lowest
## house, and on about one seed in eleven that was the lift's own, so a crew walking out of the car was heard at once.
## With `lift_clear` (the run flag ward_lift_clear), when no other house's height came out below the parlour's, one
## other house is put LIFT_CLEAR below the parlour: the lowest of them whose fixed walkways stay within SLOPE at that
## height (the lowest first, ties by id), or, when none can, the lowest of all (the Ward is then flattened to fit, as
## any too steep Ward is, which keeps the order of the heights). Nothing is drawn or redrawn, so a seed where another
## house was already lower is the same Ward bit for bit; the walkways, the drawbridge and the flattening that follow
## are worked out from the heights as always. LIFT_CLEAR is more than a step up the footing takes in one stride
## (sim/ward/footing.gd MAX_STEP_UP 0.22 m), so the two decks are plainly at two levels.
const LIFT_CLEAR := 0.3

## The flat length of a walkway between two docks (as the heights' walk measures it).
static func _flat_run(houses: Array, link: Dictionary) -> float:
	var p := _dock(houses[link.a], link.a_side)
	var q := _dock(houses[link.b], link.b_side)
	return Vector2(p[0], p[1]).distance_to(Vector2(q[0], q[1]))

static func _clear_the_lift(houses: Array, links: Array[Dictionary], tree: Array[int]) -> void:
	var order: Array[int] = []
	for i in range(1, houses.size()):
		if float(houses[i].z) < float(houses[0].z):
			return
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		return float(houses[a].z) < float(houses[b].z) or (float(houses[a].z) == float(houses[b].z) and a < b))
	var target := float(houses[0].z) - LIFT_CLEAR
	for i: int in order:
		var fits := true
		for k: int in tree:
			var link: Dictionary = links[k]
			if link.a != i and link.b != i:
				continue
			var other: int = link.b if link.a == i else link.a
			if absf(float(houses[other].z) - target) > SLOPE * _flat_run(houses, link) - 1e-6:
				fits = false
				break
		if fits:
			houses[i].z = target
			return
	houses[order[0]].z = target

## WH1: `homes` (the run flag ward_homes, layout option "homes": 1): each house gets its type's footprint and storeys
## (sim/ward/homes.gd, data/ward_homes.json) and a "plan" field naming the type; no random draw is added or moved.
static func generate_v2(seed_value: int, spread: float, rise: float, lift_clear := false, homes := false) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var styles := STYLES.duplicate()
	_shuffle(styles, rng)
	var start := Vector2i(rng.randi_range(0, COLS - 1), rng.randi_range(0, ROWS - 1))
	var cells: Array[Vector2i] = []
	var links: Array[Dictionary] = []
	var shaped := false
	for attempt in 64:
		cells = [start]
		while cells.size() < 8:
			var frontier: Array[Vector2i] = []
			for c: Vector2i in cells:
				for d: Vector2i in DIRS:
					var n := c + d
					if n.x >= 0 and n.x < COLS and n.y >= 0 and n.y < ROWS and not cells.has(n) and not frontier.has(n):
						frontier.append(n)
			cells.append(frontier[rng.randi_range(0, frontier.size() - 1)])
		links = _cell_links(cells)
		if links.size() >= cells.size() and _spans_all(cells.size(), links):
			shaped = true
			break
	if not shaped:
		# A two-row block always has loops (tests/prop_ward_layout.gd counts how often this is needed: never so far).
		var r0 := mini(start.y, ROWS - 2)
		cells = [start]
		for r: int in [r0, r0 + 1]:
			for c: int in COLS:
				if Vector2i(c, r) != start:
					cells.append(Vector2i(c, r))
		links = _cell_links(cells)
	var pitch := CELL * spread
	var houses := []
	for i in cells.size():
		var cell: Vector2i = cells[i]
		var style: Array = PARLOUR if i == 0 else styles[i - 1]
		var facing := rng.randi_range(0, 3)
		var mirror := rng.randi_range(0, 1) == 1
		var jx := rng.randf_range(-JITTER, JITTER)
		var jy := rng.randf_range(-JITTER, JITTER)
		if i == 0:
			facing = 1
			mirror = false
			jx = 0.0
			jy = 0.0
		var w := float(style[2])
		var d := float(style[3])
		var floors := int(style[1])
		if i > 0 and facing % 2 == 1:
			w = float(style[3])
			d = float(style[2])
		# WH1: the type's footprint (width along the front wall, depth), turned as the house faces; the parlour's is
		# today's (its plan is drawn as the house stands, 6.2 m along its front and 6.8 m deep).
		if homes and i > 0:
			var size := Homes.size_for_style(str(style[0]))
			w = size.y if facing % 2 == 1 else size.x
			d = size.x if facing % 2 == 1 else size.y
		if homes:
			floors = Homes.floors_for_style(str(style[0]))
		houses.append({"id": i, "style": style[0], "floors": floors, "w": w, "d": d,
			"x": float(cell.x - start.x) * pitch + jx, "y": -3.1 + float(cell.y - start.y) * pitch + jy, "z": 0.0,
			"facing": facing, "mirror": mirror, "cell": [cell.x, cell.y]})
		if homes:
			houses[-1]["plan"] = Homes.type_for_style(str(style[0])).id
	_shuffle(links, rng)
	var tilts: Array[float] = []
	for link: Dictionary in links:
		tilts.append(rng.randf_range(-1.0, 1.0))
	var extra := rng.randi_range(0, 2)
	# The fixed walkways: a tree over the links in their shuffled order.
	var groups := range(houses.size())
	var tree: Array[int] = []
	var spare: Array[int] = []
	for k in links.size():
		var left := _component(groups, links[k].a)
		var right := _component(groups, links[k].b)
		if left == right:
			spare.append(k)
		else:
			groups[left] = right
			tree.append(k)
	# Heights: out from the parlour along the tree.
	var placed := {0: true}
	var todo: Array[int] = [0]
	while not todo.is_empty():
		var at: int = todo.pop_front()
		for k: int in tree:
			var link: Dictionary = links[k]
			if link.a != at and link.b != at:
				continue
			var other: int = link.b if link.a == at else link.a
			if placed.has(other):
				continue
			placed[other] = true
			var here: Dictionary = houses[at]
			var there: Dictionary = houses[other]
			var near := _dock(here, link.a_side if link.a == at else link.b_side)
			var far := _dock(there, link.b_side if link.a == at else link.a_side)
			var run := Vector2(near[0], near[1]).distance_to(Vector2(far[0], far[1]))
			there.z = clampf(float(here.z) + tilts[k] * minf(SLOPE * run, 2.0 * rise), -rise, rise)
			todo.append(other)
	if lift_clear:
		_clear_the_lift(houses, links, tree)
	for link: Dictionary in links:
		link.path = [_dock(houses[link.a], link.a_side), _dock(houses[link.b], link.b_side)]
	var bridges: Array = []
	for k: int in tree:
		bridges.append(links[k])
	var winch := -1
	for k: int in spare:
		if _rise_ok(links[k]):
			winch = k
			break
	if winch < 0:
		winch = spare[0]
	spare.erase(winch)
	links[winch].kind = "winch"
	bridges.append(links[winch])
	for k: int in spare:
		if extra <= 0:
			break
		if _rise_ok(links[k]):
			bridges.append(links[k])
			extra -= 1
	# A clamped height can leave a walkway steeper than SLOPE: then the whole Ward is flattened to fit, as today's is.
	var vertical_scale := 1.0
	for edge: Dictionary in bridges:
		var p: Array = edge.path[0]
		var q: Array = edge.path[1]
		var lift_by := absf(p[2] - q[2])
		var run_length := Vector2(p[0], p[1]).distance_to(Vector2(q[0], q[1]))
		if lift_by > SLOPE * run_length:
			vertical_scale = minf(vertical_scale, SLOPE * run_length / lift_by)
	if vertical_scale < 1.0:
		for h: Dictionary in houses:
			h.z *= vertical_scale
		for edge: Dictionary in links:
			edge.path = [_dock(houses[edge.a], edge.a_side), _dock(houses[edge.b], edge.b_side)]
	# The houses round the drawbridge's loop: the tree's way from one of its ends to the other.
	var ends: Dictionary = links[winch]
	var parent := {int(ends.a): -1}
	var queue: Array[int] = [int(ends.a)]
	while not queue.is_empty():
		var at: int = queue.pop_front()
		for k: int in tree:
			var other := -1
			if links[k].a == at:
				other = links[k].b
			elif links[k].b == at:
				other = links[k].a
			if other >= 0 and not parent.has(other):
				parent[other] = at
				queue.append(other)
	var loop: Array = []
	var walk := int(ends.b)
	while walk >= 0:
		loop.push_front(walk)
		walk = int(parent[walk])
	var out := {"version": 2, "seed": seed_value, "houses": houses, "bridges": bridges, "loop": loop,
		"spread": spread, "rise": rise}
	if homes:
		out["homes"] = 1
	return out
