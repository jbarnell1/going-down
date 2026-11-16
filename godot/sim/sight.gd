# Who can see what. Line of sight through a floor plan in 3D, and whether a viewer's screen could
# be showing a figure. Entities that obey "only moves while nobody is looking" ask this every tick
# for every player, so it walks the ray across the 2 m grid edge by edge rather than sampling it.
# Port of src/sim/sight.ts.
#
# Geometry, read straight from walls.gd and floor.gd:
#   - level 0 is the space y in [0, LEVEL_HEIGHT), level 1 is y >= LEVEL_HEIGHT. Which level's walls
#     a ray meets at a cell edge depends on the ray's height where it crosses that edge;
#   - walls are full storey height; a door is an opening DOOR_WIDTH wide (centred on its edge) and
#     DOOR_HEIGHT high, with wall either side and above it;
#   - the slab between the levels is solid except over holes in level 1: atrium openings and stair
#     shafts. A ray may change level only through a hole;
#   - balcony rails are see-through (generous: a real rail would hide a little below its top);
#   - the top of a stair is open on level 1 and closed on level 0, as walls.gd and the renderer say;
#   - the stair ramp itself does not block sight (generous).
#
# Fairness: every judgement that is close is decided as "visible". Door gaps, lintels, the slab
# holes and the height at which a ray changes level all carry a few centimetres of slack, and a ray
# that passes within CORNER_SLACK of a grid corner is let through if either way round the corner
# is open.
extends RefCounted

const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Walls = preload("res://sim/walls.gd")
const M = preload("res://sim/jsmath.gd")

## Height of a door opening above its floor, in metres.
const DOOR_HEIGHT := 2.1
## Slack in metres added in the viewer's favour to door gaps, lintels and the level boundary.
const SIGHT_SLACK := 0.05
## A ray that passes this close (metres along the ray) to a grid corner may go round either side.
const CORNER_SLACK := 0.1
## Slack in metres around the point where a ray passes through the slab between levels.
const SLAB_SLACK := 0.06

## Default widening of the view cone on every side, in degrees.
const SIGHT_MARGIN_DEG := 12.0
## Default far limit of sight, in metres (longer than any floor's diagonal).
const SIGHT_FAR := 130.0
## Default figure: the Orderly.
const FIGURE_HEIGHT := 2.6
const FIGURE_RADIUS := 0.35
## Heights of the sampled points on a FIGURE_HEIGHT figure, metres: feet (just above the floor),
## knees, waist, chest, top of the head. Other heights scale these.
const FIGURE_LEVELS: Array[float] = [0.05, 0.52, 1.1, 1.7, 2.6]
## Shoulder height on a FIGURE_HEIGHT figure; shoulders sit `radius` to each side.
const SHOULDER_LEVEL := 2.1
## Never widen a half-angle past this, so tan() stays finite.
const MAX_HALF_ANGLE := (89.5 * PI) / 180.0

## A point in the world: x and z on the floor plane (metres), y the absolute height.
class Point3:
	var x: float
	var y: float
	var z: float
	var level: int

	static func make(x_: float, y_: float, z_: float, level_: int) -> Point3:
		var p := Point3.new()
		p.x = x_
		p.y = y_
		p.z = z_
		p.level = level_
		return p

## Someone looking: feet at body, eyes `eye` metres above the feet, yaw/pitch three.js style.
## The entity's PlayerView (id, active, blind) extends this.
class Viewer:
	var body: Move.Body
	## Eye height above the feet, in metres.
	var eye: float
	## Radians about +y: 0 faces -z (north), pi/2 faces -x (west).
	var yaw: float
	## Radians, positive looks up.
	var pitch: float
	## Full horizontal and vertical fields of view, degrees.
	var h_fov_deg: float  # TypeScript: hFovDeg
	var v_fov_deg: float  # TypeScript: vFovDeg

# ---------------------------------------------------------------------------------------------
# Line of sight.

static func _edge_passes(kind: StringName, level: int, along: float, y: float) -> bool:
	if kind == Walls.OPEN or kind == Walls.RAIL:
		return true
	if kind == Walls.STAIR_TOP:
		return level == 1
	if kind == Walls.DOOR:
		var floor_y := Move.LEVEL_HEIGHT if level == 1 else 0.0
		return absf(along) <= Walls.DOOR_WIDTH / 2.0 + SIGHT_SLACK and y - floor_y <= DOOR_HEIGHT + SIGHT_SLACK
	return false

## Whether a ray at height y gets through a cell edge; near the level boundary either level will do.
## `vertical` picks west_edge(gx=a, row=b) or north_edge(col=a, gz=b).
static func _crossing(plan: Floor.FloorPlan, vertical: bool, a: int, b: int, along: float, y: float) -> bool:
	if y >= Move.LEVEL_HEIGHT + SIGHT_SLACK:
		return _edge_passes(_kind(plan, vertical, 1, a, b), 1, along, y)
	if y < Move.LEVEL_HEIGHT - SIGHT_SLACK:
		return _edge_passes(_kind(plan, vertical, 0, a, b), 0, along, y)
	return _edge_passes(_kind(plan, vertical, 0, a, b), 0, along, y) or _edge_passes(_kind(plan, vertical, 1, a, b), 1, along, y)

static func _kind(plan: Floor.FloorPlan, vertical: bool, level: int, a: int, b: int) -> StringName:
	return Walls.west_edge(plan, level, a, b) if vertical else Walls.north_edge(plan, level, a, b)

static func _is_hole(plan: Floor.FloorPlan, x: float, z: float) -> bool:
	var k := Floor.cell_at(plan, 1, int(floor(x / plan.cell_size)), int(floor(z / plan.cell_size)))
	return k == Floor.ATRIUM_OPEN or k == Floor.STAIR

## Whether there is a hole in the slab at (or within SLAB_SLACK of) a point.
static func _hole_near(plan: Floor.FloorPlan, x: float, z: float) -> bool:
	var e := SLAB_SLACK
	return _is_hole(plan, x, z) or _is_hole(plan, x - e, z - e) or _is_hole(plan, x + e, z - e) \
		or _is_hole(plan, x - e, z + e) or _is_hole(plan, x + e, z + e)

## Whether nothing solid lies between two points: walls (with door gaps), the slab between levels
## (except through atrium openings and stair shafts). The points' own levels are not used: the
## height y decides which level's walls a ray meets.
static func has_line_of_sight(plan: Floor.FloorPlan, from: Point3, to: Point3) -> bool:
	var cs := float(plan.cell_size)
	var dx := to.x - from.x
	var dy := to.y - from.y
	var dz := to.z - from.z

	# The slab: a straight ray crosses the level boundary at most once.
	if (from.y >= Move.LEVEL_HEIGHT) != (to.y >= Move.LEVEL_HEIGHT):
		var t := (Move.LEVEL_HEIGHT - from.y) / dy
		if not _hole_near(plan, from.x + dx * t, from.z + dz * t):
			return false

	var cx := int(floor(from.x / cs))
	var cz := int(floor(from.z / cs))
	var ex := int(floor(to.x / cs))
	var ez := int(floor(to.z / cs))
	var step_x := 1 if dx > 0.0 else (-1 if dx < 0.0 else 0)
	var step_z := 1 if dz > 0.0 else (-1 if dz < 0.0 else 0)
	var length := M.hypot2(dx, dz)
	var t_max_x := (((cx + 1) if step_x > 0 else cx) * cs - from.x) / dx if step_x != 0 else INF
	var t_max_z := (((cz + 1) if step_z > 0 else cz) * cs - from.z) / dz if step_z != 0 else INF
	var t_delta_x := cs / absf(dx) if step_x != 0 else INF
	var t_delta_z := cs / absf(dz) if step_z != 0 else INF

	var max_steps := 2 * (plan.width + plan.height) + 8
	var i := 0
	while i < max_steps and (cx != ex or cz != ez):
		i += 1
		if minf(t_max_x, t_max_z) > 1.0:
			break  # rounding at the far end: nothing left to cross
		var gx := cx + 1 if step_x > 0 else cx
		var gz := cz + 1 if step_z > 0 else cz
		if t_max_x <= 1.0 and t_max_z <= 1.0 and absf(t_max_x - t_max_z) * length < CORNER_SLACK:
			# Close to a corner: through either neighbour will do.
			var via_x := _x_line(plan, from, dy, dz, gx, cz, t_max_x, cs) and _z_line(plan, from, dx, dy, gz, cx + step_x, t_max_z, cs)
			var via_z := _z_line(plan, from, dx, dy, gz, cx, t_max_z, cs) and _x_line(plan, from, dy, dz, gx, cz + step_z, t_max_x, cs)
			if not via_x and not via_z:
				return false
			cx += step_x
			cz += step_z
			t_max_x += t_delta_x
			t_max_z += t_delta_z
		elif t_max_x < t_max_z:
			if not _x_line(plan, from, dy, dz, gx, cz, t_max_x, cs):
				return false
			cx += step_x
			t_max_x += t_delta_x
		else:
			if not _z_line(plan, from, dx, dy, gz, cx, t_max_z, cs):
				return false
			cz += step_z
			t_max_z += t_delta_z
	return true

## Crossing the vertical grid line gx (between cells gx-1 and gx) in row `row`, at ray parameter t.
static func _x_line(plan: Floor.FloorPlan, from: Point3, dy: float, dz: float, gx: int, row: int, t: float, cs: float) -> bool:
	var z := from.z + dz * t
	return _crossing(plan, true, gx, row, z - (row + 0.5) * cs, from.y + dy * t)

## Crossing the horizontal grid line gz (between rows gz-1 and gz) in column `col`.
static func _z_line(plan: Floor.FloorPlan, from: Point3, dx: float, dy: float, gz: int, col: int, t: float, cs: float) -> bool:
	var x := from.x + dx * t
	return _crossing(plan, false, col, gz, x - (col + 0.5) * cs, from.y + dy * t)

# ---------------------------------------------------------------------------------------------
# Seeing a figure.

## Where a viewer's eyes are.
static func eye_point(body: Move.Body, eye: float) -> Point3:
	return Point3.make(body.x, body.y + eye, body.z, body.level)

## The points sampled on a standing figure: feet, knees, waist, chest, head, and two shoulders set
## `radius` to either side as seen from (from_x, from_z), so the widest silhouette is tested.
static func figure_points(figure: Move.Body, from_x: float, from_z: float, height: float = FIGURE_HEIGHT, radius: float = FIGURE_RADIUS) -> Array[Point3]:
	var k := height / FIGURE_HEIGHT
	var out: Array[Point3] = []
	for h in FIGURE_LEVELS:
		out.append(Point3.make(figure.x, figure.y + h * k, figure.z, figure.level))
	var sx := -(figure.z - from_z)
	var sz := figure.x - from_x
	var n := M.hypot2(sx, sz)
	if n > 1e-9:
		sx = (sx / n) * radius
		sz = (sz / n) * radius
		var y := figure.y + SHOULDER_LEVEL * k
		out.append(Point3.make(figure.x + sx, y, figure.z + sz, figure.level))
		out.append(Point3.make(figure.x - sx, y, figure.z - sz, figure.level))
	return out

## Camera basis for yaw/pitch (three.js 'YXZ' order): forward, right, up, as 9 floats
## [f0, f1, f2, r0, r1, r2, u0, u1, u2].
static func basis(yaw: float, pitch: float) -> PackedFloat64Array:
	var sy := M.sin_js(yaw)
	var cy := M.cos_js(yaw)
	var sp := M.sin_js(pitch)
	var cp := M.cos_js(pitch)
	return PackedFloat64Array([-cp * sy, sp, -cp * cy, cy, 0.0, -sy, sp * sy, cp, sp * cy])

## Whether a point is inside the viewer's frustum widened by `margin_deg` on every side (no walls).
static func in_view_cone(viewer: Viewer, px: float, py: float, pz: float, margin_deg: float = SIGHT_MARGIN_DEG) -> bool:
	return _in_view_cone(viewer, basis(viewer.yaw, viewer.pitch), px, py, pz, margin_deg)

static func _in_view_cone(viewer: Viewer, b: PackedFloat64Array, px: float, py: float, pz: float, margin_deg: float) -> bool:
	var tans := cone_tans(viewer, margin_deg)
	return _in_cone(viewer, b, tans[0], tans[1], px, py, pz)

## tan of the widened horizontal and vertical half-angles: [tan_h, tan_v]. They depend only on the
## viewer and the margin, so callers that test many points work them out once (same values).
static func cone_tans(viewer: Viewer, margin_deg: float) -> PackedFloat64Array:
	var m := (margin_deg * PI) / 180.0
	var h := minf(MAX_HALF_ANGLE, (viewer.h_fov_deg * PI) / 360.0 + m)
	var v := minf(MAX_HALF_ANGLE, (viewer.v_fov_deg * PI) / 360.0 + m)
	return PackedFloat64Array([M.tan_js(h), M.tan_js(v)])

static func _in_cone(viewer: Viewer, b: PackedFloat64Array, tan_h: float, tan_v: float, px: float, py: float, pz: float) -> bool:
	var vx := px - viewer.body.x
	var vy := py - (viewer.body.y + viewer.eye)
	var vz := pz - viewer.body.z
	var d := vx * b[0] + vy * b[1] + vz * b[2]
	if d <= 0.0:
		return false
	var side := vx * b[3] + vz * b[5]
	var up := vx * b[6] + vy * b[7] + vz * b[8]
	return absf(side) <= d * tan_h and absf(up) <= d * tan_v

## Whether the viewer's screen could be showing the figure: any sampled point on it is inside the
## widened view cone, within the far limit, with a clear line of sight from the eyes.
static func can_see(plan: Floor.FloorPlan, viewer: Viewer, figure: Move.Body, margin_deg: float = SIGHT_MARGIN_DEG, far: float = SIGHT_FAR, height: float = FIGURE_HEIGHT, radius: float = FIGURE_RADIUS) -> bool:
	var look := look_of(viewer, margin_deg)
	return can_see_with(plan, look, figure, far, height, radius)

## What can_see works out about a viewer before it looks at any point: eyes, camera basis, cone tans.
class Look:
	var viewer: Viewer
	var eye: Point3
	var b: PackedFloat64Array
	var tan_h: float
	var tan_v: float

static func look_of(v: Viewer, margin_deg: float) -> Look:
	var l := Look.new()
	l.viewer = v
	l.eye = Point3.make(v.body.x, v.body.y + v.eye, v.body.z, v.body.level)
	l.b = basis(v.yaw, v.pitch)
	var tans := cone_tans(v, margin_deg)
	l.tan_h = tans[0]
	l.tan_v = tans[1]
	return l

## can_see for a viewer already worked out (the entity asks three figure sizes per viewer).
static func can_see_with(plan: Floor.FloorPlan, look: Look, figure: Move.Body, far: float = SIGHT_FAR, height: float = FIGURE_HEIGHT, radius: float = FIGURE_RADIUS) -> bool:
	var eye := look.eye
	for p in figure_points(figure, eye.x, eye.z, height, radius):
		if M.hypot3(p.x - eye.x, p.y - eye.y, p.z - eye.z) > far:
			continue
		if not _in_cone(look.viewer, look.b, look.tan_h, look.tan_v, p.x, p.y, p.z):
			continue
		if has_line_of_sight(plan, eye, p):
			return true
	return false
