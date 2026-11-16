# What stands on each cell edge of a floor plan: nothing, an opening, a door, a wall or a rail.
# Collision (move.gd) and the renderer both read this, so what you see is what stops you.
# Port of src/sim/walls.ts.
#
# Derived strictly from can_step in floor.gd:
#   - an edge can_step allows is 'open', or 'door' when only a Door makes it passable;
#   - the top of a stair joins the last stair cell (level 0) to the cell beyond it (level 1). It is
#     'stairTop' on both levels: walkers pass through it, and the renderer closes it on level 0 only
#     (under the upper floor) because the climber is above that wall by the time they reach it;
#   - holes in the upper floor (atrium opening, stair shaft) are 'open' among themselves;
#   - an atrium opening beside upper corridor is a 'rail' (the balcony); everything else is 'wall'.
extends RefCounted

const Floor = preload("res://sim/floor.gd")
const M = preload("res://sim/jsmath.gd")

# EdgeKind: 'none' | 'open' | 'door' | 'wall' | 'rail' | 'stairTop'
const NONE := &"none"
const OPEN := &"open"
const DOOR := &"door"
const WALL := &"wall"
const RAIL := &"rail"
const STAIR_TOP := &"stairTop"

## Width of a door opening in metres, centred on its cell edge. The rest of that edge is wall.
const DOOR_WIDTH := 1.1

## Whether (a, b) is the top of some stair: its last cell and the cell just beyond, either order.
static func is_stair_top(plan: Floor.FloorPlan, ax: int, ay: int, bx: int, by: int) -> bool:
	for s in plan.stairs:
		var vx := Floor.dir_dx(s.dir)
		var vy := Floor.dir_dy(s.dir)
		var ex := s.x + vx * (s.length - 1)
		var ey := s.y + vy * (s.length - 1)
		var tx := ex + vx
		var ty := ey + vy
		if (ax == ex and ay == ey and bx == tx and by == ty) or (bx == ex and by == ey and ax == tx and ay == ty):
			return true
	return false

static func _is_hole(k: StringName, level: int) -> bool:
	return k == Floor.ATRIUM_OPEN or (k == Floor.STAIR and level == 1)

## The edge between two edge-adjacent cells on one level.
static func edge_kind(plan: Floor.FloorPlan, level: int, ax: int, ay: int, bx: int, by: int) -> StringName:
	var ka := Floor.cell_at(plan, level, ax, ay)
	var kb := Floor.cell_at(plan, level, bx, by)
	if ka == Floor.VOID and kb == Floor.VOID:
		return NONE
	if is_stair_top(plan, ax, ay, bx, by):
		return STAIR_TOP
	if Floor.can_step_xy(plan, level, ax, ay, level, bx, by):
		var ra := Floor.room_id_at(plan, level, ax, ay)
		var same_room := ra >= 0 and ra == Floor.room_id_at(plan, level, bx, by)
		var both_corridor := ka == Floor.CORRIDOR and kb == Floor.CORRIDOR
		if not same_room and not both_corridor and Floor.has_door(plan, level, ax, ay, bx, by):
			return DOOR
		return OPEN
	if _is_hole(ka, level) and _is_hole(kb, level):
		return OPEN if ka == kb else WALL
	if (ka == Floor.ATRIUM_OPEN and kb == Floor.CORRIDOR) or (kb == Floor.ATRIUM_OPEN and ka == Floor.CORRIDOR):
		return RAIL
	return WALL

# ---------------------------------------------------------------------------------------------
# Edge tables, cached per plan: collision asks for the same edges many times a second.
# plan._edges[level] = [vertical, horizontal]:
#   vertical: edge between (x-1, y) and (x, y), index y*(w+1)+x, for x in [0, w];
#   horizontal: edge between (x, y-1) and (x, y), index y*w+x, for y in [0, h].

static func _tables(plan: Floor.FloorPlan) -> Array:
	if not plan._edges.is_empty():
		return plan._edges
	var w := plan.width
	var h := plan.height
	var t: Array = []
	for level in 2:
		var vertical: Array[StringName] = []
		for y in h:
			for x in w + 1:
				vertical.append(edge_kind(plan, level, x - 1, y, x, y))
		var horizontal: Array[StringName] = []
		for y in h + 1:
			for x in w:
				horizontal.append(edge_kind(plan, level, x, y - 1, x, y))
		t.append([vertical, horizontal])
	plan._edges = t
	return t

## Edge on the west side of cell (x, y). Out of range reads as 'none'.
static func west_edge(plan: Floor.FloorPlan, level: int, x: int, y: int) -> StringName:
	if y < 0 or y >= plan.height or x < 0 or x > plan.width:
		return NONE
	return _tables(plan)[level][0][y * (plan.width + 1) + x]

## Edge on the north side of cell (x, y). Out of range reads as 'none'.
static func north_edge(plan: Floor.FloorPlan, level: int, x: int, y: int) -> StringName:
	if x < 0 or x >= plan.width or y < 0 or y > plan.height:
		return NONE
	return _tables(plan)[level][1][y * plan.width + x]

# ---------------------------------------------------------------------------------------------
# Collision segments.

## The solid parts of an edge from (x0, z0) to (x1, z1) for a walker, appended to `out` as four
## floats per segment (ax, az, bx, bz). (TypeScript: Segment objects.)
static func _solid_parts(kind: StringName, x0: float, z0: float, x1: float, z1: float, out: PackedFloat64Array) -> void:
	if kind == WALL or kind == RAIL:
		out.append_array([x0, z0, x1, z1])
	elif kind == DOOR:
		var length := M.hypot2(x1 - x0, z1 - z0)
		var f := (length - DOOR_WIDTH) / 2.0 / length
		out.append_array([x0, z0, x0 + (x1 - x0) * f, z0 + (z1 - z0) * f])
		out.append_array([x1 - (x1 - x0) * f, z1 - (z1 - z0) * f, x1, z1])

## Every solid segment on the edges of the 3x3 cells around (cx, cy), four floats per segment.
## That covers anything within one cell of a point inside (cx, cy), more than any walker's radius.
static func segments_near(plan: Floor.FloorPlan, level: int, cx: int, cy: int) -> PackedFloat64Array:
	var s := float(plan.cell_size)
	var out := PackedFloat64Array()
	for y in range(cy - 1, cy + 2):
		for x in range(cx - 1, cx + 3):
			_solid_parts(west_edge(plan, level, x, y), x * s, y * s, x * s, (y + 1) * s, out)
	for y in range(cy - 1, cy + 3):
		for x in range(cx - 1, cx + 2):
			_solid_parts(north_edge(plan, level, x, y), x * s, y * s, (x + 1) * s, y * s, out)
	return out
