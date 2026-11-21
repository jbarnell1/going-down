# WL1: the Hanging Ward's look, around what client/ward/view.gd builds from the layout (no rule reads any of it; the
# walk model, sim/ward/state.gd, is still the only ground). The owner, 20 Nov, on the 11:38 build: "the elevator looks
# completely different (not like an elevator at all), doors open are invisible and a flat brown when closed ... The
# whole level looks pretty terrible stylistically with just boxes and squares everywhere, that don't connect".
#   - the lift: the same car every other floor draws (client/lift.gd: its frame, sliding doors, indicator, call
#     button, sill, lamp), sized to the Ward's car (the walk model's walls and gate), its doors open while the lift
#     waits (unloading, boarding) and shut while it is away;
#   - a house's front door: a panelled leaf on a hinge in a cased frame, swung into the entry room when open;
#   - every gallery: a railing round its outer edge with a gap at each walkway that docks there (and at the lift);
#   - every walkway: stringers under its deck's edges, a threshold plate where it meets a gallery, posts on its rails
#     and hangers from the posts up to the cavern's roof; every rope from a deck corner runs up to that roof;
#   - the cavern's roof over the whole Ward, with an iron plate where each line is fixed.
# Everything here is built from the layout data the view already holds, the same on every screen.
extends RefCounted

const Layout = preload("res://sim/ward/layout.gd")
const House = preload("res://sim/ward/house.gd")
const Footing = preload("res://sim/ward/footing.gd")

## How far above the highest deck the cavern's roof is (the deck lines' length up, view.gd).
const ROOF_ABOVE := 25.0
## Railing: post spacing, height of the top and middle ropes.
const POST_EVERY := 1.6
const RAIL_TOP := 0.95
const RAIL_MID := 0.52
## Hangers along a walkway: one pair every HANG_EVERY metres.
const HANG_EVERY := 3.2
## The house door's swing when open (into the entry room) and how fast it moves (radians a second).
const DOOR_SWING := -PI * 0.5
const DOOR_SPEED := 3.0

## The roof's height (world y) for a layout: ROOF_ABOVE over its highest deck.
static func roof_y(layout: Dictionary) -> float:
	var top := -INF
	for site: Dictionary in layout.houses:
		top = maxf(top, float(site.z) + 0.15)
	return top + ROOF_ABOVE

## The sides of each house a walkway docks on: {house id: [side, ...]}.
static func docked_sides(layout: Dictionary) -> Dictionary:
	var out := {}
	for edge: Dictionary in layout.bridges:
		for end: Array in [[int(edge.a), str(edge.a_side)], [int(edge.b), str(edge.b_side)]]:
			if not out.has(end[0]):
				out[end[0]] = []
			(out[end[0]] as Array).append(end[1])
	return out

# ------------------------------------------------------------------------------------------------
# The lift.

## The car as client/lift.gd builds it (plan.car's fields), for the Ward's car: its door at `door` (the walk
## model's lift_door, sim/ward/state.gd), the car running back along -z, inside 2 * half wide (the walk model's
## walls) and `depth` deep, its gate `gate` wide.
## The car's wall line (client/lift.gd's frame) is the middle of the parlour's wall: the walk model's door is 0.12 m
## inside the wall's outer face of 0.14, so the middle is WALL_LINE further in, and the landing's frame, indicator
## and call button sit on the parlour's inside face (Lift.LAND, half the game's wall).
const WALL_LINE := 0.05

static func lift_car(door: Vector3, half := 0.665, depth := 2.99, gate := 1.24) -> Dictionary:
	return {"width": half * 2.0, "depth": depth, "doorWidth": gate, "doorX": door.x, "floorY": door.y - 0.01,
		"doorZ": door.z + WALL_LINE, "rightX": 1.0, "rightZ": 0.0, "inX": 0.0, "inZ": -1.0}

## Builds the game's lift car in `parent` for the Ward's car at `door`. Its BANK and DOWN paint is not shown: the
## Ward's car is not voted in.
static func build_lift(parent: Node3D, door: Vector3, roof := INF) -> Lift:
	var car := Lift.new()
	car.name = "WardLift"
	parent.add_child(car)
	var spec := lift_car(door)
	car.build(spec)
	if is_finite(roof):
		# The car hangs from its crosshead on four cables up to the cavern's roof, as everything here hangs.
		var middle := Vector3(door.x, door.y + Lift.CAR_H + 0.1, float(spec.doorZ) - float(spec.depth) * 0.5)
		parent.call("_box", parent, middle, Vector3(float(spec.width) + 0.2, 0.2, 0.3), "iron")
		for dx: float in [-0.35, -0.12, 0.12, 0.35]:
			parent.call("_beam", parent, middle + Vector3(dx, 0.1, 0), Vector3(middle.x + dx, roof, middle.z), 0.03, 0.03, "iron")
	for paint: String in ["FloorBank", "FloorDown"]:
		var half := car.find_child(paint, false, false) as Node3D
		if half != null:
			half.visible = false
	return car

## FX2: the owner saw a dark beam across the lift's doorway at head height (and a brick strip and a kerb across it):
## the lift's house's interior tie (view.gd _interior_ties) at 2.12 m, the lift wall's brick lintel hanging to 2.18 m
## over doors 2.25 m high, and the wall's skirting running under the doors. The doorway and the car stay clear:
##   - the tie in the lift's house runs at LIFT_HOUSE_TIE, under the ceiling, over the doorway's top;
##   - the lintel seen starts at the car's door height (its body for sight lines is unchanged);
##   - the skirting along the lift's wall leaves LIFT_GAP open round the doorway.
const LIFT_HOUSE_TIE := 2.66
const LIFT_GAP := 1.24 + 0.3
## The lift car's floor in the lift house's frame (the walk model's door is 0.15 up; the car 0.01 under it).
const CAR_FLOOR := 0.14

## The brick seen over the lift's doorway in the lift wall `wall` (the house's local box), from the car's door top up.
static func lift_lintel(view: Node3D, root: Node3D, wall: AABB) -> Node3D:
	var bottom := CAR_FLOOR + Lift.DOOR_H
	var middle := wall.get_center()
	var node := view.call("_box", root, Vector3(middle.x, (bottom + wall.end.y) * 0.5, middle.z),
		Vector3(wall.size.x, wall.end.y - bottom, 1.24), "brick") as Node3D
	node.name = "LiftLintel"
	return node

## A skirting board at `at` (its middle) running `length` along z, leaving `gap` open round its middle (0: whole).
static func skirting(view: Node3D, root: Node3D, at: Vector3, length: float, gap := 0.0) -> void:
	const SIZE := Vector2(0.085, 0.23)
	if gap <= 0.0:
		view.call("_box", root, at, Vector3(SIZE.x, SIZE.y, length), "wood")
		return
	var piece := (length - gap) * 0.5
	for flip: float in [-1.0, 1.0]:
		view.call("_box", root, at + Vector3(0, 0, flip * (gap + piece) * 0.5), Vector3(SIZE.x, SIZE.y, piece), "wood")

# ------------------------------------------------------------------------------------------------
# A house's door.

## A panelled leaf hung on the left jamb of `door` (the house's local door box) in `root` (the house's node), with a
## cased frame round the opening. Returns the hinge (rotation.y 0 shut, DOOR_SWING open).
static func door_leaf(view: Node3D, root: Node3D, door: AABB) -> Node3D:
	var width := door.size.x
	var height := door.size.y
	var hinge := Node3D.new()
	hinge.name = "DoorHinge"
	root.add_child(hinge)
	hinge.position = Vector3(door.position.x + 0.01, 0.0, door.get_center().z)
	var leaf_w := width - 0.02
	view.call("_box", hinge, Vector3(leaf_w * 0.5, height * 0.5, 0), Vector3(leaf_w, height - 0.02, 0.05), "door")
	# Two raised panels each side and a brass knob, so the leaf reads as a door from either side.
	for face: float in [-1.0, 1.0]:
		for row: Array in [[0.62, 0.78], [1.52, 0.86]]:
			view.call("_box", hinge, Vector3(leaf_w * 0.5, float(row[0]), face * 0.03), Vector3(leaf_w - 0.26, float(row[1]), 0.012), "panel")
		view.call("_box", hinge, Vector3(leaf_w - 0.12, 1.0, face * 0.045), Vector3(0.06, 0.06, 0.05), "brass")
	# The casing round the opening, on both faces of the wall.
	for face: float in [-1.0, 1.0]:
		var z := door.get_center().z + face * (House.WALL_THICKNESS * 0.5 + 0.015)
		for x: float in [door.position.x - 0.05, door.end.x + 0.05]:
			view.call("_box", root, Vector3(x, height * 0.5, z), Vector3(0.1, height + 0.05, 0.03), "trim")
		view.call("_box", root, Vector3(door.get_center().x, height + 0.07, z), Vector3(width + 0.2, 0.12, 0.03), "trim")
	return hinge

# ------------------------------------------------------------------------------------------------
# Galleries, walkways, the roof.

## A railing round a house's gallery, at its outer edge, with a gap where each walkway docks (`sides`) and, for the
## lift's house, where the car stands.
static func gallery_rail(view: Node3D, site: Dictionary, sides: Array, lift_x := INF) -> void:
	var root := Node3D.new()
	root.name = "GalleryRail%d" % int(site.id)
	view.add_child(root)
	var hw := float(site.w) * 0.5 + Layout.GALLERY - 0.04
	var hd := float(site.d) * 0.5 + Layout.GALLERY - 0.04
	var y := float(site.z) + 0.15
	var cx := float(site.x)
	var cz := float(site.y)
	var corners := {"sw": Vector3(cx - hw, y, cz - hd), "se": Vector3(cx + hw, y, cz - hd),
		"ne": Vector3(cx + hw, y, cz + hd), "nw": Vector3(cx - hw, y, cz + hd)}
	var runs := {"south": ["sw", "se"], "east": ["se", "ne"], "north": ["ne", "nw"], "west": ["nw", "sw"]}
	for side: String in runs:
		var a: Vector3 = corners[runs[side][0]]
		var b: Vector3 = corners[runs[side][1]]
		var gaps: Array[Vector2] = []
		var middle := a.distance_to(b) * 0.5
		if sides.has(side):
			gaps.append(Vector2(middle - Footing.DECK_WIDTH * 0.5 - 0.12, middle + Footing.DECK_WIDTH * 0.5 + 0.12))
		if side == "south" and is_finite(lift_x):
			var at := absf(lift_x - a.x)
			gaps.append(Vector2(at - 0.9, at + 0.9))
		_rail_run(view, root, a, b, gaps)

## Posts and two ropes from `a` to `b` (deck level), leaving out the stretches in `gaps` (metres along).
static func _rail_run(view: Node3D, root: Node3D, a: Vector3, b: Vector3, gaps: Array[Vector2]) -> void:
	var length := a.distance_to(b)
	var pieces: Array[Vector2] = [Vector2(0.0, length)]
	for gap: Vector2 in gaps:
		var next: Array[Vector2] = []
		for piece: Vector2 in pieces:
			if gap.y <= piece.x or gap.x >= piece.y:
				next.append(piece)
				continue
			if gap.x > piece.x + 0.05:
				next.append(Vector2(piece.x, gap.x))
			if gap.y < piece.y - 0.05:
				next.append(Vector2(gap.y, piece.y))
		pieces = next
	var along := (b - a) / length
	for piece: Vector2 in pieces:
		var p := a + along * piece.x
		var q := a + along * piece.y
		var posts := maxi(1, ceili((piece.y - piece.x) / POST_EVERY))
		for k in posts + 1:
			view.call("_box", root, p.lerp(q, float(k) / posts) + Vector3.UP * RAIL_TOP * 0.5, Vector3(0.07, RAIL_TOP, 0.07), "iron")
		for h: float in [RAIL_TOP, RAIL_MID]:
			view.call("_beam", root, p + Vector3.UP * h, q + Vector3.UP * h, 0.05, 0.05, "rope")

## Under a walkway: stringers along both edges of every span, a threshold plate at each end where it meets a gallery,
## posts along its rails and a pair of hangers every HANG_EVERY metres up to the roof at `roof`.
static func walkway(view: Node3D, root: Node3D, path: Array, roof: float) -> void:
	for i in range(1, path.size()):
		var from := Footing.path_point(path[i - 1])
		var to := Footing.path_point(path[i])
		var heading := (to - from).normalized()
		var side := heading.cross(Vector3.UP).normalized()
		for flip: float in [-1.0, 1.0]:
			var edge := side * flip * (Footing.DECK_WIDTH * 0.5 - 0.05)
			view.call("_beam", root, from + edge - Vector3.UP * 0.27, to + edge - Vector3.UP * 0.27, 0.1, 0.12, "iron")
		var length := from.distance_to(to)
		var count := maxi(1, floori(length / HANG_EVERY))
		for k in count + 1:
			var at := from.lerp(to, (float(k) + 0.5) / (count + 1))
			for flip: float in [-1.0, 1.0]:
				var post := at + side * flip * 0.73
				view.call("_box", root, post + Vector3.UP * 0.47, Vector3(0.06, 0.94, 0.06), "iron")
				view.call("_beam", root, post + Vector3.UP * 0.94, Vector3(post.x, roof, post.z), 0.035, 0.035, "rope")
	for end: int in [0, path.size() - 1]:
		var at := Footing.path_point(path[end])
		var other := Footing.path_point(path[1 if end == 0 else path.size() - 2])
		var heading := (other - at).normalized()
		var plate := view.call("_beam", root, at - heading * 0.25 - Vector3.UP * 0.005, at + heading * 0.25 - Vector3.UP * 0.005,
			Footing.DECK_WIDTH + 0.06, 0.03, "iron") as Node3D
		plate.name = "Threshold"

## The cavern's roof over the layout, at `roof`, rough rock, with an iron plate where each line of each deck is fixed.
static func cavern_roof(view: Node3D, layout: Dictionary, roof: float) -> Node3D:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for site: Dictionary in layout.houses:
		lo = lo.min(Vector2(float(site.x) - float(site.w), float(site.y) - float(site.d)))
		hi = hi.max(Vector2(float(site.x) + float(site.w), float(site.y) + float(site.d)))
	lo -= Vector2.ONE * 30.0
	hi += Vector2.ONE * 30.0
	var node := Node3D.new()
	node.name = "CavernRoof"
	view.add_child(node)
	var middle := (lo + hi) * 0.5
	view.call("_box", node, Vector3(middle.x, roof + 1.5, middle.y), Vector3(hi.x - lo.x, 3.0, hi.y - lo.y), "rock")
	for site: Dictionary in layout.houses:
		for x: float in [-1.0, 1.0]:
			for z: float in [-1.0, 1.0]:
				var at := Vector3(float(site.x) + x * (float(site.w) * 0.5 + Layout.GALLERY - 0.13), roof - 0.05,
					float(site.y) + z * (float(site.d) * 0.5 + Layout.GALLERY - 0.13))
				view.call("_box", node, at, Vector3(0.4, 0.1, 0.4), "iron")
	return node
