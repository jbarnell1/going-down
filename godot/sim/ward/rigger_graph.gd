# RR1: the Rigger's surface graph. Where his body can be in the Hanging Ward and how he gets from one place to another,
# built from the floor's layout (sim/ward/layout.gd), its houses (sim/ward/house.gd) and its walkway spans (the same
# path points sim/ward/footing.gd walks), so it is the same on the host and on every screen for a seed, and follows the
# layout whatever the layout generator makes: nothing here names a coordinate of the Ward.
#
# His body is a set of spheres in the figure's own frame (assets/ward/rigger_v2.glb, measured in its "hang" pose):
# origin the abdomen's centre, +Y away from the surface he holds (his back), +Z forward (his torso and arm). His leg tips
# hold a surface STAND metres along -Y; the tips themselves are not in the volume (they touch what he grips).
#
# Nodes are poses (a centre and an orientation) on every surface his body fits against:
#   - the outer walls of every house (across its windows and doors), its roof and its underside, and every edge
#     between those (arcs at 30 and 60 degrees, so he rolls over an eave or under a sill);
#   - the gallery decks around each house: their tops, outer sides and undersides;
#   - the walkways and the drawbridge (always, raised or lowered, so the graph never changes with the winch): their
#     tops, sides and undersides;
#   - the four taut lines at each gallery's corners, from his lair below up past the roof;
#   - his lair, below the lowest house, joined to the foot of every house's lines;
#   - reach poses: for every opening of a house his arm can enter by (the front door and each ground-floor window),
#     the poses whose wrist is exactly at the arm's shoulder outside that opening (sim/ward/house.gd openings).
# A pose is kept only when no sphere of the body touches any solid (house, roof cap, chimney, gallery deck, walkway
# span with its rails, bridge, lift car, line). An edge joins two poses within EDGE_R when the body sweeps clear between
# them: proved without sampling by each sphere's clearance at both ends (a sphere's distance to a box changes by at most
# the distance it moves; when the clearances at both ends add up to at least the length of its path, no point between
# can touch), and halved until it is (or a piece is shorter than a centimetre and still touching, then the edge is not
# made). Only the part of the graph joined to the lair is kept.
#
# Its cost: about a second to build on the host once per Ward (tests/prop_rigger_graph.gd prints it).
extends RefCounted

const House = preload("res://sim/ward/house.gd")
const Layout = preload("res://sim/ward/layout.gd")
const Footing = preload("res://sim/ward/footing.gd")

## The body (figure frame), [offset, radius]: the abdomen; the torso, head and lamp; the folded arm to the wrist; and,
## per leg, the knee (half way out, raised as his legs arch). His lower legs bend to their holds (the view sets each
## foot on the surface), so they are not part of the solid.
const BODY := [
	[Vector3(0.0, 0.15, -0.2), 2.1],
	[Vector3(0.0, 1.0, 2.2), 0.7], [Vector3(0.0, 2.3, 2.4), 0.65], [Vector3(0.0, 3.4, 2.4), 0.55], [Vector3(0.03, 4.1, 3.3), 0.2],
	[Vector3(0.5, 2.55, 3.7), 0.25], [Vector3(0.79, 2.48, 4.97), 0.15],
	[Vector3(2.5, 0.25, 3.7), 0.4], [Vector3(2.4, 0.4, 2.75), 0.4], [Vector3(2.9, 0.4, 1.7), 0.4], [Vector3(2.4, 0.9, -0.95), 0.4],
	[Vector3(-2.5, 0.25, 3.7), 0.4], [Vector3(-2.4, 0.4, 2.75), 0.4], [Vector3(-2.85, 0.4, 1.7), 0.4], [Vector3(-2.3, 0.9, -0.8), 0.4],
]
## His wrist and head in the same frame (client/ward/view.gd RIGGER_WRIST_V2; the rig's head bone).
const WRIST := Vector3(0.788, 2.484, 4.965)
const HEAD := Vector3(0.01, 3.36, 2.25)
## How far his centre stands off a surface his legs hold.
const STAND := 2.8
## Spacing of poses over a face, and the farthest two poses an edge may join.
const GRID := 2.3
const EDGE_R := 3.6
## Edges to and from his lines and his reach poses may be longer and turn more (they stand off the houses).
const EDGE_R_LONG := 5.5
## And to a reach pose, from the surfaces near the opening.
const EDGE_R_REACH := 7.0
const EDGE_TURN_LONG := deg_to_rad(120.0)
## Two poses turned further apart than this are never joined directly (an eave is rounded by the arcs between).
const EDGE_TURN := deg_to_rad(80.0)
## Clearance every sphere keeps from every solid.
const MARGIN := 0.05
## Clearances are kept up to this (a solid farther than this from a sphere does not matter to any edge).
const CLEAR_CAP := 3.0
## The longest the body reaches from its centre (any sphere's offset plus radius).
const BODY_REACH := 5.9
## His lines: how far below and above a gallery's deck they run (client/ward/view.gd draws them 18 m down, 25 up), and
## the spacing of his holds on them.
const LINE_DOWN := 18.0
const LINE_UP := 25.0
const LINE_STEP := 3.0
## His lair: this far below the lowest house's deck (below the end of every line, with his whole body).
const LAIR_DEPTH := 26.0

## What a pose is on. The surfaces' speeds are live settings (sim/ward/state.gd).
enum { LAIR, LINE, WALL, ROOF, UNDER, DECK, REACH }
const KIND_NAMES := ["lair", "line", "wall", "roof", "under", "deck", "reach"]

## Solids: oriented boxes. centre, axes (orthonormal), half extents, bounding radius, and what they are.
var ob_o := PackedVector3Array()
var ob_b: Array[Basis] = []
var ob_h := PackedVector3Array()
## The same axes, packed (the distance test reads these).
var ob_x := PackedVector3Array()
var ob_y := PackedVector3Array()
var ob_z := PackedVector3Array()
var ob_r := PackedFloat32Array()
## [kind, house or bridge index]: kind is "house", "chimney", "gallery", "span", "joint", "lift", "line".
var ob_what: Array = []

## Poses.
var pos := PackedVector3Array()
var rot: Array[Quaternion] = []
var kind := PackedByteArray()
## The house a pose belongs to (-1 none), and the walkway/bridge index of a span pose (-1 none).
var house_of := PackedInt32Array()
var bridge_of := PackedInt32Array()
## The corner of a line pose (its house's line, client/ward/view.gd's order), -1 for others.
var corner_of := PackedInt32Array()
var clear: Array[PackedFloat32Array] = []
var adj: Array[PackedInt32Array] = []
## His home in the lair: the lair pose below the lowest house's first line. Every line has its own lair pose straight
## below it, and the lair poses are joined to one another (his web, far below the houses).
var lair := -1
var lair_nodes := PackedInt32Array()
## Per house: [{opening: Dictionary (house.gd openings), node: int, shoulder: Vector3 (world)}], every opening with a
## reach pose joined to the lair. The opening keeps its index in the house's openings.
var reach: Array = []
## Per house: [corner][holds], the line poses, bottom first.
var lines: Array = []
var build_ms := 0
var layout: Dictionary
var houses: Array[House]

## The Ward's solids only, no poses or edges (a screen's: client/ward/rigger_feet.gd finds his holds on them). Cheap.
static func solids_only(layout_: Dictionary, houses_: Array[House], lift_door: Vector3) -> RefCounted:
	var g: RefCounted = load("res://sim/ward/rigger_graph.gd").new()
	g.layout = layout_
	g.houses = houses_
	g._solids(lift_door)
	return g

static func build(layout_: Dictionary, houses_: Array[House], lift_door: Vector3) -> RefCounted:
	var g: RefCounted = load("res://sim/ward/rigger_graph.gd").new()
	g._build(layout_, houses_, lift_door)
	return g

func _build(layout_: Dictionary, houses_: Array[House], lift_door: Vector3) -> void:
	begin(layout_, houses_, lift_door)
	advance(-1)

## The build in pieces (the host does a few milliseconds of it a tick, net/host.gd _prebuild_roam, so no tick waits for
## it): begin, then advance until it says it is done. The pieces are the same whatever the budget, in the same order, so
## the graph is the same as one built at once.
func begin(layout_: Dictionary, houses_: Array[House], lift_door: Vector3) -> void:
	layout = layout_
	houses = houses_
	_solids(lift_door)
	_stage = 0
	_cursor = 0
	_spent_us = 0

var _stage := -1
var _cursor := 0
var _cells := {}
var _spent_us := 0

## Whether the build is finished.
func done() -> bool:
	return _stage == 6

## Builds pieces for about `budget_usec` microseconds (a negative budget: to the end). True when it is finished.
func advance(budget_usec: int) -> bool:
	var started := Time.get_ticks_usec()
	while _stage < 6 and (budget_usec < 0 or Time.get_ticks_usec() - started < budget_usec):
		match _stage:
			0:
				if _cursor < ob_o.size():
					_solid_poses(_cursor)
					_cursor += 1
				else:
					_stage = 1
			1:
				_line_poses()
				_stage = 2
				_cursor = 0
			2:
				if _cursor < houses.size():
					_reach_house(_cursor)
					_cursor += 1
				else:
					_edges_begin()
					_stage = 3
					_cursor = 0
			3:
				if _cursor < pos.size():
					_edges_from(_cursor)
					_cursor += 1
				else:
					_stage = 4
			4:
				_edges_end()
				_stage = 5
			5:
				_keep_joined()
				_stage = 6
	_spent_us += Time.get_ticks_usec() - started
	build_ms = _spent_us / 1000
	return _stage == 6

## The build's own measure: milliseconds to place the poses, edges tried.
var poses_ms := 0
## Tools: print the build's progress.
static var verbose := false
var tries := 0

# ---------------------------------------------------------------------------------------------
# Solids, from the layout.

func _box(centre: Vector3, axes: Basis, half: Vector3, what: Array) -> int:
	ob_o.append(centre)
	ob_b.append(axes)
	ob_x.append(axes.x)
	ob_y.append(axes.y)
	ob_z.append(axes.z)
	ob_h.append(half)
	ob_r.append(half.length())
	ob_what.append(what)
	return ob_o.size() - 1

## A house's frame (its local x across, y up, z into the house from the front wall) as world axes.
static func house_axes(h: House) -> Basis:
	var o := h.to_world(Vector3.ZERO)
	return Basis(h.to_world(Vector3.RIGHT) - o, h.to_world(Vector3.UP) - o, h.to_world(Vector3.BACK) - o)

## The roof cap's top above the house's floor (client/ward/view.gd _dress_house: the slab and the two pitched panels).
static func roof_top(h: House) -> float:
	return House.HEIGHT * float(h.storeys.size() - 1) + 0.85

## Spans of every walkway and of the bridge: [from, to, joint at to, bridge index].
func spans() -> Array:
	var out := []
	for b: int in layout.bridges.size():
		var path: Array = layout.bridges[b].path
		for i in range(1, path.size()):
			out.append([Footing.path_point(path[i - 1]), Footing.path_point(path[i]), i < path.size() - 1, b])
	return out

static func span_axes(from: Vector3, to: Vector3) -> Basis:
	var z := (to - from).normalized()
	var x := Vector3.UP.cross(z).normalized()
	return Basis(x, z.cross(x), z)

func _solids(lift_door: Vector3) -> void:
	for i in houses.size():
		var h := houses[i]
		var site: Dictionary = layout.houses[i]
		var axes := house_axes(h)
		var half := h.floor_bounds.size.x * 0.5
		var depth := h.floor_bounds.size.y
		var top := roof_top(h)
		# The house with its roof: the cap's footprint (it overhangs the walls), floor slab to the roof's top.
		var hx := half + 0.2
		var z0 := -0.24
		var z1 := depth + 0.24
		var local := Vector3(0.0, (top - 0.14) * 0.5, (z0 + z1) * 0.5)
		_box(h.to_world(local), axes, Vector3(hx, (top + 0.14) * 0.5, (z1 - z0) * 0.5), ["house", i])
		# The chimney (client/ward/view.gd _dress_house).
		var roof_y := House.HEIGHT * float(h.storeys.size() - 1)
		_box(h.to_world(Vector3(-h.floor_bounds.size.x * 0.28, roof_y + 0.6, depth * 0.5 - 0.61)), axes, Vector3(0.25, 0.5, 0.25), ["chimney", i])
		# The gallery deck all round (world axes, as the view lays it).
		var deck_y := float(site.z) + 0.15
		var across := float(site.w) + Layout.GALLERY * 2.0
		var deep := float(site.d) + Layout.GALLERY * 2.0
		_box(Vector3(float(site.x), deck_y - 0.12, float(site.y)), Basis.IDENTITY, Vector3(across * 0.5, 0.12, deep * 0.5), ["gallery", i])
		# The four taut lines at its corners.
		for c in 4:
			var corner := _corner(i, c)
			_box(Vector3(corner.x, deck_y + (LINE_UP - LINE_DOWN) * 0.5, corner.z), Basis.IDENTITY, Vector3(0.05, (LINE_UP + LINE_DOWN) * 0.5, 0.05), ["line", i])
	for s: Array in spans():
		var from: Vector3 = s[0]
		var to: Vector3 = s[1]
		var axes := span_axes(from, to)
		# The deck (0.22 under the walking line) and its rails (to 0.94 over it), as client/ward/view.gd _build_bridge.
		_box((from + to) * 0.5 + axes.y * 0.36, axes, Vector3(0.8, 0.58, from.distance_to(to) * 0.5 + 0.06), ["span", int(s[3])])
		if s[2]:
			_box(to + Vector3.UP * 0.36, Basis.IDENTITY, Vector3(Footing.JOINT_WIDTH * 0.5, 0.58, Footing.JOINT_WIDTH * 0.5), ["joint", int(s[3])])
	# The lift car beside the parlour (client/ward/view.gd _build_lift: it runs back along -z from the doorway).
	_box(lift_door + Vector3(0.0, 1.05, -1.5), Basis.IDENTITY, Vector3(0.8, 1.3, 1.62), ["lift", 0])

## A gallery corner's line (world, at deck height): corner c of house i in the order client/ward/view.gd builds its lines
## (x outer, z inner: 0 is -x -z, 1 -x +z, 2 +x -z, 3 +x +z).
func _corner(i: int, c: int) -> Vector3:
	var site: Dictionary = layout.houses[i]
	var across := float(site.w) + Layout.GALLERY * 2.0
	var deep := float(site.d) + Layout.GALLERY * 2.0
	var sx := -1.0 if c < 2 else 1.0
	var sz := -1.0 if c % 2 == 0 else 1.0
	return Vector3(float(site.x) + sx * (across * 0.5 - 0.13), float(site.z) + 0.15, float(site.y) + sz * (deep * 0.5 - 0.13))

# ---------------------------------------------------------------------------------------------
# Distances.

## Signed distance from a point to solid k (negative inside).
func box_distance(k: int, p: Vector3) -> float:
	var d := p - ob_o[k]
	var local := Vector3(ob_x[k].dot(d), ob_y[k].dot(d), ob_z[k].dot(d))
	var h := ob_h[k]
	var q := Vector3(absf(local.x) - h.x, absf(local.y) - h.y, absf(local.z) - h.z)
	var outside := Vector3(maxf(q.x, 0.0), maxf(q.y, 0.0), maxf(q.z, 0.0)).length()
	return outside + minf(maxf(q.x, maxf(q.y, q.z)), 0.0)

## The solids that can matter to a body centred at `c` or moving up to `extra` from it (within BODY_REACH +
## CLEAR_CAP + `extra` of it; a solid farther off is more than CLEAR_CAP from every sphere, so leaving it out never
## overstates a clearance).
func near_solids(c: Vector3, extra := 0.0) -> PackedInt32Array:
	var out := PackedInt32Array()
	var reach := BODY_REACH + CLEAR_CAP + extra
	for k in ob_o.size():
		if c.distance_to(ob_o[k]) - ob_r[k] <= reach and box_distance(k, c) <= reach:
			out.append(k)
	return out

## Each sphere's clearance (distance to the nearest solid less its radius and MARGIN, at most CLEAR_CAP) for a body
## at `c` turned by `q`. `among` are the solids to consider (near_solids).
func clearances(c: Vector3, q: Quaternion, among: PackedInt32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(BODY.size())
	var b := Basis(q)
	for s in BODY.size():
		var p: Vector3 = c + b * (BODY[s][0] as Vector3)
		var best := CLEAR_CAP
		for k in among:
			best = minf(best, box_distance(k, p) - float(BODY[s][1]) - MARGIN)
		out[s] = best
	return out

## Whether no sphere of a body at `c` turned by `q` touches any of `among` (stops at the first that does).
func quick_clear(c: Vector3, q: Quaternion, among: PackedInt32Array) -> bool:
	var b := Basis(q)
	for s in BODY.size():
		var p: Vector3 = c + b * (BODY[s][0] as Vector3)
		var r := float(BODY[s][1]) + MARGIN
		for k in among:
			if box_distance(k, p) <= r:
				return false
	return true

## Whether a segment of radius `r` touches no solid (sampled every 5 cm; for his arm's short run outside an opening).
func segment_clear(a: Vector3, b: Vector3, r: float) -> bool:
	var among := near_solids(a, a.distance_to(b))
	var steps := maxi(1, ceili(a.distance_to(b) / 0.05))
	for i in steps + 1:
		var p := a.lerp(b, float(i) / steps)
		for k in among:
			if box_distance(k, p) <= r:
				return false
	return true

static func min_of(values: PackedFloat32Array) -> float:
	var m := INF
	for v in values:
		m = minf(m, v)
	return m

## Whether a body at `c` turned by `q` touches nothing (every sphere at least MARGIN clear).
func pose_clear(c: Vector3, q: Quaternion) -> bool:
	return min_of(clearances(c, q, near_solids(c))) > 0.0

## The longest any sphere's centre travels from pose a to pose b (centre's straight move plus the turn).
static func sphere_paths(a: Vector3, qa: Quaternion, b: Vector3, qb: Quaternion) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(BODY.size())
	var move := a.distance_to(b)
	var turn := qa.angle_to(qb)
	for s in BODY.size():
		out[s] = move + turn * (BODY[s][0] as Vector3).length()
	return out

## Whether the body sweeps clear from pose a to pose b (the clearances at both ends given), halving as needed.
func sweep_clear(a: Vector3, qa: Quaternion, ca: PackedFloat32Array, b: Vector3, qb: Quaternion, cb: PackedFloat32Array, among: PackedInt32Array, depth := 0) -> bool:
	if among.is_empty():
		return true
	var all := PackedInt32Array()
	for s in BODY.size():
		all.append(s)
	return _sweep(a, qa, ca, b, qb, cb, among, all, depth)

## The sweep for the spheres `which` only (a sphere whose bound holds over a piece holds over every part of it, so the
## halves need only those that did not).
func _sweep(a: Vector3, qa: Quaternion, ca: PackedFloat32Array, b: Vector3, qb: Quaternion, cb: PackedFloat32Array, among: PackedInt32Array, which: PackedInt32Array, depth: int) -> bool:
	var move := a.distance_to(b)
	var turn := qa.angle_to(qb)
	var failing := PackedInt32Array()
	for s in which:
		if ca[s] + cb[s] < move + turn * float(BODY_LENGTH[s]):
			failing.append(s)
	if failing.is_empty():
		return true
	sweeps += 1
	if depth > 10 or move + turn * BODY_REACH < 0.02:
		return false
	var m := a.lerp(b, 0.5)
	var qm := qa.slerp(qb, 0.5)
	var cm := PackedFloat32Array()
	cm.resize(BODY.size())
	var basis := Basis(qm)
	for s in failing:
		var p: Vector3 = m + basis * (BODY[s][0] as Vector3)
		var best := CLEAR_CAP
		var r := float(BODY[s][1]) + MARGIN
		for k in among:
			best = minf(best, box_distance(k, p) - r)
		if best <= 0.0:
			return false
		cm[s] = best
	return _sweep(a, qa, ca, m, qm, cm, among, failing, depth + 1) and _sweep(m, qm, cm, b, qb, cb, among, failing, depth + 1)

## How far each sphere's centre is from the body's centre.
static var BODY_LENGTH: PackedFloat32Array = _lengths()

static func _lengths() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for s: Array in BODY:
		out.append((s[0] as Vector3).length())
	return out

# ---------------------------------------------------------------------------------------------
# Poses.

## A body pose: back along `up`, facing `forward` (made perpendicular to up).
static func pose_basis(up: Vector3, forward: Vector3) -> Quaternion:
	var y := up.normalized()
	var z := (forward - y * forward.dot(y))
	if z.length() < 1e-4:
		z = Vector3.FORWARD - y * Vector3.FORWARD.dot(y)
		if z.length() < 1e-4:
			z = Vector3.RIGHT
	z = z.normalized()
	var x := y.cross(z)
	return Basis(x, y, z).get_rotation_quaternion()

func _add(c: Vector3, q: Quaternion, k: int, house: int, bridge: int, corner := -1) -> int:
	var among := near_solids(c, EDGE_R_REACH)
	if not quick_clear(c, q, among):
		return -1
	var cl := clearances(c, q, among)
	if min_of(cl) <= 0.0:
		return -1
	pos.append(c)
	rot.append(q)
	kind.append(k)
	house_of.append(house)
	bridge_of.append(bridge)
	corner_of.append(corner)
	clear.append(cl)
	_near.append(among)
	return pos.size() - 1

## Per pose: the solids within reach of any edge from it (near_solids with EDGE_R).
var _near: Array[PackedInt32Array] = []
## Tests and the build's note: how many sweep pieces were checked.
var sweeps := 0

## A forward for a surface of normal n at `at` on a solid centred at `centre`: up the face (and so over an eave or under a
## sill: the way up along the surface) while the face is not flat; on a flat top or underside, towards the solid's
## middle (the way he came over its edge) for a house or a gallery, along `along` (the long axis) for a walkway.
static func surface_forward(n: Vector3, along: Vector3, at: Vector3, centre: Vector3, radial: bool) -> Vector3:
	if absf(n.y) < 0.97:
		return Vector3.UP
	var inward := Vector3(centre.x - at.x, 0.0, centre.z - at.z)
	if radial and inward.length() > 0.5:
		return inward
	return along

func _solid_poses(k: int) -> void:
	var what: Array = ob_what[k]
	match what[0]:
		"house":
			_face_poses(k, [true, true, true, true, true, true], int(what[1]), -1, false)
		"gallery":
			_face_poses(k, [true, true, true, true, true, true], int(what[1]), -1, true)
		"span":
			# Not on its ends: they meet a gallery or a joint.
			_face_poses(k, [true, true, true, true, false, false], -1, int(what[1]), true)

## Poses over the faces of solid k (faces +x -x +y -y +z -z as `faces` allows) and over the edges between two allowed
## faces (arcs at 30 and 60 degrees).
func _face_poses(k: int, faces: Array, house: int, bridge: int, deck: bool) -> void:
	var b := ob_b[k]
	var h := ob_h[k]
	var axes := [b.x, b.y, b.z]
	var halves := [h.x, h.y, h.z]
	var long_axis: Vector3 = b.x if h.x >= h.z else b.z
	for f in 6:
		if not faces[f]:
			continue
		var a := f / 2
		var sign := 1.0 if f % 2 == 0 else -1.0
		var n: Vector3 = axes[a] * sign
		var t1 := (a + 1) % 3
		var t2 := (a + 2) % 3
		var c0: Vector3 = ob_o[k] + n * float(halves[a])
		for u in _grid(float(halves[t1])):
			for v in _grid(float(halves[t2])):
				var p: Vector3 = c0 + axes[t1] * u + axes[t2] * v
				_add(p + n * STAND, pose_basis(n, surface_forward(n, long_axis, p, ob_o[k], bridge < 0)), _surface_kind(n, deck), house, bridge)
	# Edges: two faces on different axes.
	for f in 6:
		for g in range(f + 1, 6):
			if f / 2 == g / 2 or not faces[f] or not faces[g]:
				continue
			var a1 := f / 2
			var a2 := g / 2
			var n1: Vector3 = axes[a1] * (1.0 if f % 2 == 0 else -1.0)
			var n2: Vector3 = axes[a2] * (1.0 if g % 2 == 0 else -1.0)
			var t := 3 - a1 - a2
			var e0: Vector3 = ob_o[k] + n1 * float(halves[a1]) + n2 * float(halves[a2])
			for w in _grid(float(halves[t])):
				var p: Vector3 = e0 + axes[t] * w
				for frac: float in [1.0 / 3.0, 2.0 / 3.0]:
					var n := n1.slerp(n2, frac).normalized()
					_add(p + n * STAND, pose_basis(n, surface_forward(n, long_axis, p, ob_o[k], bridge < 0)), _surface_kind(n, deck), house, bridge)

static func _grid(half: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var count := maxi(1, ceili(half * 2.0 / GRID))
	for i in count:
		out.append(-half + (float(i) + 0.5) * half * 2.0 / count)
	return out

static func _surface_kind(n: Vector3, deck: bool) -> int:
	if n.y < -0.7:
		return UNDER
	if deck:
		return DECK
	return ROOF if n.y > 0.7 else WALL

func _line_poses() -> void:
	var lowest := INF
	var lair_house := 0
	for i in houses.size():
		if float(layout.houses[i].z) < lowest:
			lowest = float(layout.houses[i].z)
			lair_house = i
	var lair_y := lowest + 0.15 - LAIR_DEPTH
	for i in houses.size():
		var per_corner := []
		var deck_y := float(layout.houses[i].z) + 0.15
		var top := houses[i].to_world(Vector3.UP * roof_top(houses[i])).y
		for c in 4:
			var corner := _corner(i, c)
			var centre := Vector3(float(layout.houses[i].x), 0.0, float(layout.houses[i].y))
			var out := Vector3(corner.x - centre.x, 0.0, corner.z - centre.z).normalized()
			var holds := PackedInt32Array()
			var below := _add(Vector3(corner.x, lair_y, corner.z) + out * STAND, pose_basis(out, Vector3.UP), LAIR, i, -1, c)
			if below >= 0:
				lair_nodes.append(below)
				if lair < 0 and i == lair_house:
					lair = below
				holds.append(below)
			var y := deck_y - LINE_DOWN + LINE_STEP
			while y <= top + LINE_STEP:
				var at := Vector3(corner.x, y, corner.z) + out * STAND
				var node := _add(at, pose_basis(out, Vector3.UP), LINE, i, -1, c)
				if node >= 0:
					holds.append(node)
				y += LINE_STEP
			per_corner.append(holds)
		lines.append(per_corner)

## The poses that put his wrist on the arm's shoulder outside an opening: facing the opening, turned up to 60 degrees
## either way and leaning forward or back, as his body fits.
const REACH_YAWS := [0.0, -30.0, 30.0, -60.0, 60.0, -90.0, 90.0]
const REACH_PITCHES := [0.0, 25.0, 40.0, 55.0, 70.0]
const REACH_ROLLS := [0.0, -25.0, 25.0, -50.0, 50.0, -90.0, 90.0]
## His wrist at the arm's shoulder, or this far further out and up (the arm drawn from wrist to shoulder).
const REACH_SLACK := [Vector2(0.0, 0.0), Vector2(0.8, 0.6)]
## How many of an opening's reach poses are kept: the clearest.
const REACH_KEEP := 10
const REACH_SPREAD := 1.2
var _reach_candidates: Array = []

func _reach_house(i: int) -> void:
	if true:
		var h := houses[i]
		var per := []
		var axes := house_axes(h)
		for opening: Dictionary in h.openings():
			var shoulder: Vector3 = h.to_world(opening.shoulder)
			var inward: Vector3 = (axes * (opening.inward as Vector3)).normalized()
			var found := []
			for slack: Vector2 in REACH_SLACK:
				var wrist := shoulder - inward * slack.x + Vector3.UP * slack.y
				if slack != Vector2.ZERO and not segment_clear(wrist, shoulder, 0.1):
					continue
				for yaw: float in REACH_YAWS:
					for pitch: float in REACH_PITCHES:
						for roll: float in REACH_ROLLS:
							var f0 := inward.rotated(Vector3.UP, deg_to_rad(yaw))
							var x0 := Vector3.UP.cross(f0).normalized()
							var turned := Basis(x0, Vector3.UP, f0).rotated(x0, deg_to_rad(pitch))
							var q := turned.rotated(turned.z, deg_to_rad(roll)).get_rotation_quaternion()
							var centre := wrist - Basis(q) * WRIST
							var among := near_solids(centre, EDGE_R_LONG)
							if quick_clear(centre, q, among):
								var room := min_of(clearances(centre, q, among))
								found.append([room, centre, q, wrist])
				# The clearest REACH_KEEP of them (ties: the order tried).
				found.sort_custom(func(x: Array, y: Array) -> bool: return float(x[0]) > float(y[0]))
			# The clearest, each at least REACH_SPREAD from those kept (so they stand in different places).
			var kept := 0
			for f in found.size():
				if kept >= REACH_KEEP:
					break
				var apart := true
				for r: Dictionary in per:
					if int(r.opening.index) == int(opening.index) and pos[int(r.node)].distance_to(found[f][1]) < REACH_SPREAD:
						apart = false
						break
				if not apart:
					continue
				var node := _add(found[f][1], found[f][2], REACH, i, -1)
				if node >= 0:
					kept += 1
					per.append({"opening": opening, "node": node, "shoulder": shoulder, "wrist": found[f][3]})
		_reach_candidates.append(per)

# ---------------------------------------------------------------------------------------------
# Edges.

func _edges_begin() -> void:
	var n := pos.size()
	adj.resize(n)
	for i in n:
		adj[i] = PackedInt32Array()
	# A grid of cells EDGE_R_REACH wide.
	_cells = {}
	for i in n:
		var key := Vector3i((pos[i] / EDGE_R_REACH).floor())
		if not _cells.has(key):
			_cells[key] = PackedInt32Array()
		_cells[key].append(i)

func _edges_from(i: int) -> void:
	var cells := _cells
	if true:
		if kind[i] == LAIR:
			return
		var key := Vector3i((pos[i] / EDGE_R_REACH).floor())
		for dx: int in [-1, 0, 1]:
			for dy: int in [-1, 0, 1]:
				for dz: int in [-1, 0, 1]:
					var other: Variant = cells.get(key + Vector3i(dx, dy, dz))
					if other == null:
						continue
					for j: int in other:
						if j <= i or kind[j] == LAIR:
							continue
						if kind[i] == REACH and kind[j] == REACH:
							continue
						var long := kind[i] == LINE or kind[j] == LINE or kind[i] == REACH or kind[j] == REACH
						var reach_edge := kind[i] == REACH or kind[j] == REACH
						if pos[i].distance_to(pos[j]) > (EDGE_R_REACH if reach_edge else (EDGE_R_LONG if long else EDGE_R)) or rot[i].angle_to(rot[j]) > (EDGE_TURN_LONG if long else EDGE_TURN):
							continue
						if _try(i, j):
							_link(i, j)

func _edges_end() -> void:
	_cells = {}
	# The lair poses to one another, and each line's holds (its lair pose first) to the next.
	for a in lair_nodes.size():
		for b in range(a + 1, lair_nodes.size()):
			if _try(lair_nodes[a], lair_nodes[b]):
				_link(lair_nodes[a], lair_nodes[b])
	for per_corner: Array in lines:
		for holds: PackedInt32Array in per_corner:
			for k in range(1, holds.size()):
				if not adj[holds[k]].has(holds[k - 1]) and _try(holds[k - 1], holds[k]):
					_link(holds[k - 1], holds[k])

func _try(i: int, j: int) -> bool:
	tries += 1
	var among := _near[i] if pos[i].distance_to(pos[j]) <= EDGE_R_REACH else near_solids(pos[i], pos[i].distance_to(pos[j]))
	return sweep_clear(pos[i], rot[i], clear[i], pos[j], rot[j], clear[j], among)

func _link(i: int, j: int) -> void:
	adj[i].append(j)
	adj[j].append(i)

## Keeps the reach poses joined to the lair (the others' edges stay; they are unreachable).
func _keep_joined() -> void:
	var seen := PackedByteArray()
	seen.resize(pos.size())
	var stack := PackedInt32Array([lair])
	seen[lair] = 1
	while not stack.is_empty():
		var i := stack[stack.size() - 1]
		stack.resize(stack.size() - 1)
		for j in adj[i]:
			if seen[j] == 0:
				seen[j] = 1
				stack.append(j)
	_joined = seen
	reach.clear()
	for i in houses.size():
		var per := []
		for r: Dictionary in _reach_candidates[i]:
			if seen[int(r.node)] == 1:
				per.append(r)
		reach.append(per)

var _joined := PackedByteArray()

func joined(node: int) -> bool:
	return node >= 0 and node < _joined.size() and _joined[node] == 1

## Every opening index of house `h` with a reach pose joined to the lair.
func openings_of(h: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for r: Dictionary in reach[h]:
		var index := int(r.opening.index)
		if not out.has(index):
			out.append(index)
	return out

## The reach poses of one opening.
func reach_nodes(h: int, opening: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for r: Dictionary in reach[h]:
		if int(r.opening.index) == opening:
			out.append(int(r.node))
	return out

# ---------------------------------------------------------------------------------------------
# Paths.

## Seconds to cross from pose i to pose j at `speeds` (per kind of the pose arrived at, m/s).
func edge_time(i: int, j: int, speeds: PackedFloat32Array) -> float:
	var k := kind[j] if kind[j] != REACH else kind[i]
	if kind[i] == LAIR or kind[j] == LAIR:
		k = LAIR
	return pos[i].distance_to(pos[j]) / maxf(0.05, speeds[k])

## The fastest path from pose `from` to any of `targets` (nodes, from included), or empty when none is joined.
func path(from: int, targets: PackedInt32Array, speeds: PackedFloat32Array) -> PackedInt32Array:
	var n := pos.size()
	var cost := PackedFloat64Array()
	cost.resize(n)
	cost.fill(INF)
	var parent := PackedInt32Array()
	parent.resize(n)
	parent.fill(-1)
	var goal := {}
	for t in targets:
		goal[t] = true
	cost[from] = 0.0
	# A binary heap of [cost, node].
	var heap: Array = [[0.0, from]]
	var found := -1
	while not heap.is_empty():
		var top: Array = _pop(heap)
		var i: int = top[1]
		if float(top[0]) > cost[i]:
			continue
		if goal.has(i):
			found = i
			break
		for j in adj[i]:
			var c := cost[i] + edge_time(i, j, speeds)
			if c < cost[j] - 1e-9:
				cost[j] = c
				parent[j] = i
				_push(heap, [c, j])
	var out := PackedInt32Array()
	if found < 0:
		return out
	var k := found
	while k >= 0:
		out.append(k)
		k = parent[k]
	out.reverse()
	return out

static func _push(heap: Array, item: Array) -> void:
	heap.append(item)
	var i := heap.size() - 1
	while i > 0:
		var p := (i - 1) / 2
		if float(heap[p][0]) < float(heap[i][0]) or (float(heap[p][0]) == float(heap[i][0]) and int(heap[p][1]) <= int(heap[i][1])):
			break
		var t: Array = heap[p]
		heap[p] = heap[i]
		heap[i] = t
		i = p

static func _pop(heap: Array) -> Array:
	var top: Array = heap[0]
	var last: Array = heap.pop_back()
	if heap.is_empty():
		return top
	heap[0] = last
	var i := 0
	while true:
		var l := i * 2 + 1
		var r := l + 1
		var m := i
		if l < heap.size() and _less(heap[l], heap[m]):
			m = l
		if r < heap.size() and _less(heap[r], heap[m]):
			m = r
		if m == i:
			break
		var t: Array = heap[m]
		heap[m] = heap[i]
		heap[i] = t
		i = m
	return top

static func _less(a: Array, b: Array) -> bool:
	return float(a[0]) < float(b[0]) or (float(a[0]) == float(b[0]) and int(a[1]) < int(b[1]))

## The joined pose nearest a point (ties: the lower index).
func nearest(p: Vector3, kinds: Array = []) -> int:
	var best := -1
	var d := INF
	for i in pos.size():
		if not joined(i) or (not kinds.is_empty() and not kinds.has(int(kind[i]))):
			continue
		var e := pos[i].distance_squared_to(p)
		if e < d:
			d = e
			best = i
	return best

## His wrist and head for a body at `c` turned by `q`.
static func wrist_at(c: Vector3, q: Quaternion) -> Vector3:
	return c + Basis(q) * WRIST

static func head_at(c: Vector3, q: Quaternion) -> Vector3:
	return c + Basis(q) * HEAD

## The body's spheres in the world for a pose: [centre, radius] pairs.
static func spheres(c: Vector3, q: Quaternion) -> Array:
	var out := []
	var b := Basis(q)
	for s: Array in BODY:
		out.append([c + b * (s[0] as Vector3), float(s[1])])
	return out

## A digest of the graph (tests: the same for a seed).
func digest() -> int:
	var parts := PackedStringArray()
	for i in pos.size():
		parts.append("%d:%.3f,%.3f,%.3f:%d:%d" % [i, pos[i].x, pos[i].y, pos[i].z, kind[i], adj[i].size()])
	return "|".join(parts).hash()
