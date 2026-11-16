# Continuous movement through a floor plan: a circle sliding along walls, climbing stairs and
# changing level exactly where can_step allows. Shared by the local player, bots and entities, so
# it knows nothing about rendering. Port of src/sim/move.ts.
#
# A body is a point on the floor with a radius. Its cell is the 2 m cell under its centre and its
# level follows floor.gd: a body on a stair is on level 0 until its centre crosses the top edge.
extends RefCounted

const Floor = preload("res://sim/floor.gd")
const Walls = preload("res://sim/walls.gd")
const M = preload("res://sim/jsmath.gd")

## Height of one storey in metres: level 1's floor is this far above level 0's.
const LEVEL_HEIGHT := 3.2

## Treated as immutable: every move makes a new Body, so states may share them.
class Body:
	## Horizontal position in metres: cell (cx, cy) covers x in [cx*2, cx*2+2), z in [cy*2, cy*2+2).
	var x: float
	var z: float
	var level: int
	## Height of the feet in metres.
	var y: float

	static func make(x_: float, z_: float, level_: int, y_: float) -> Body:
		var b := Body.new()
		b.x = x_
		b.z = z_
		b.level = level_
		b.y = y_
		return b

	func same(o: Body) -> bool:
		return x == o.x and z == o.z and level == o.level and y == o.y

## The plan cell under a body's centre.
static func cell_of(plan: Floor.FloorPlan, b: Body) -> Floor.Pos:
	return Floor.Pos.make(b.level, int(floor(b.x / plan.cell_size)), int(floor(b.z / plan.cell_size)))

## A body standing in the centre of a cell.
static func body_at_cell(plan: Floor.FloorPlan, pos: Floor.Pos) -> Body:
	var x := (pos.x + 0.5) * plan.cell_size
	var z := (pos.y + 0.5) * plan.cell_size
	return Body.make(x, z, pos.level, feet_height(plan, pos.level, x, z))

static func _stair_under(plan: Floor.FloorPlan, cx: int, cy: int) -> Floor.Stair:
	for s in plan.stairs:
		var vx := Floor.dir_dx(s.dir)
		var vy := Floor.dir_dy(s.dir)
		for i in s.length:
			if s.x + vx * i == cx and s.y + vy * i == cy:
				return s
	return null

## Height of the feet at a point: a straight ramp from the stair's bottom edge to its top edge.
static func feet_height(plan: Floor.FloorPlan, level: int, x: float, z: float) -> float:
	if level == 1:
		return LEVEL_HEIGHT
	var s := float(plan.cell_size)
	var cx := int(floor(x / s))
	var cy := int(floor(z / s))
	if Floor.cell_at(plan, 0, cx, cy) != Floor.STAIR:
		return 0.0
	var stair := _stair_under(plan, cx, cy)
	if stair == null:
		return 0.0
	var vx := Floor.dir_dx(stair.dir)
	var vy := Floor.dir_dy(stair.dir)
	var bx := (stair.x + 0.5) * s - (vx * s) / 2.0
	var bz := (stair.y + 0.5) * s - (vy * s) / 2.0
	var along := (x - bx) * vx + (z - bz) * vy
	var t := minf(1.0, maxf(0.0, along / (stair.length * s)))
	return t * LEVEL_HEIGHT

## The level a walker ends up on after moving from cell `from` into the adjacent (or diagonal) cell
## (cx, cy), or -1 if can_step forbids it (TypeScript: null). A diagonal move is allowed when it
## could be made as two legal orthogonal steps through either corner cell.
static func _level_after_step(plan: Floor.FloorPlan, from: Floor.Pos, cx: int, cy: int) -> int:
	var dx := cx - from.x
	var dy := cy - from.y
	if absi(dx) + absi(dy) == 1:
		for l: int in [from.level, 1 if from.level == 0 else 0]:
			if Floor.can_step_xy(plan, from.level, from.x, from.y, l, cx, cy):
				return l
		return -1
	if absi(dx) == 1 and absi(dy) == 1:
		for m: Vector2i in [Vector2i(cx, from.y), Vector2i(from.x, cy)]:
			for lm: int in [from.level, 1 if from.level == 0 else 0]:
				if not Floor.can_step_xy(plan, from.level, from.x, from.y, lm, m.x, m.y):
					continue
				for ln: int in [lm, 1 if lm == 0 else 0]:
					if Floor.can_step_xy(plan, lm, m.x, m.y, ln, cx, cy):
						return ln
	return -1

## Distance from a point to the nearest solid segment on a level (INF if none is near).
static func wall_clearance(plan: Floor.FloorPlan, level: int, x: float, z: float) -> float:
	var s := float(plan.cell_size)
	var best := INF
	var segs := Walls.segments_near(plan, level, int(floor(x / s)), int(floor(z / s)))
	var i := 0
	while i < segs.size():
		var ax := segs[i]
		var az := segs[i + 1]
		var ex := segs[i + 2] - ax
		var ez := segs[i + 3] - az
		var len2 := ex * ex + ez * ez
		var t := minf(1.0, maxf(0.0, ((x - ax) * ex + (z - az) * ez) / len2)) if len2 > 0.0 else 0.0
		var qx := ax + ex * t
		var qz := az + ez * t
		best = minf(best, M.hypot2(x - qx, z - qz))
		i += 4
	return best

## Pushes a circle out of every segment it overlaps. A few passes settle corners.
## Returns Vector of two floats as a PackedFloat64Array [x, z].
static func _push_out(plan: Floor.FloorPlan, level: int, x: float, z: float, r: float, from_x: float, from_z: float) -> PackedFloat64Array:
	var s := float(plan.cell_size)
	for _pass in 4:
		var moved := false
		var segs := Walls.segments_near(plan, level, int(floor(x / s)), int(floor(z / s)))
		var i := 0
		while i < segs.size():
			var ax := segs[i]
			var az := segs[i + 1]
			var ex := segs[i + 2] - ax
			var ez := segs[i + 3] - az
			i += 4
			var len2 := ex * ex + ez * ez
			var t := minf(1.0, maxf(0.0, ((x - ax) * ex + (z - az) * ez) / len2)) if len2 > 0.0 else 0.0
			var qx := ax + ex * t
			var qz := az + ez * t
			var nx := x - qx
			var nz := z - qz
			var d := M.hypot2(nx, nz)
			if d >= r:
				continue
			if d < 1e-9:
				# Exactly on the line: push back towards where we came from.
				nx = from_x - qx
				nz = from_z - qz
				d = M.hypot2(nx, nz)
				if d < 1e-9:
					return PackedFloat64Array([from_x, from_z])
			x = qx + (nx / d) * r
			z = qz + (nz / d) * r
			moved = true
		if not moved:
			break
	return PackedFloat64Array([x, z])

const CLEARANCE_SLACK := 1e-6

## One small step, or null if it would end somewhere illegal.
static func _try_step(plan: Floor.FloorPlan, cur: Body, sx: float, sz: float, r: float) -> Body:
	if sx == 0.0 and sz == 0.0:
		return null
	var from := cell_of(plan, cur)
	var p := _push_out(plan, cur.level, cur.x + sx, cur.z + sz, r, cur.x, cur.z)
	var x := p[0]
	var z := p[1]
	var s := float(plan.cell_size)
	var cx := int(floor(x / s))
	var cy := int(floor(z / s))
	var level := cur.level
	if cx != from.x or cy != from.y:
		var l := _level_after_step(plan, from, cx, cy)
		if l < 0:
			return null
		level = l
		if level != cur.level:
			# Crossing the top of a stair: settle against the new level's walls too.
			p = _push_out(plan, level, x, z, r, cur.x, cur.z)
			x = p[0]
			z = p[1]
			if int(floor(x / s)) != cx or int(floor(z / s)) != cy:
				return null
	cx = int(floor(x / s))
	cy = int(floor(z / s))
	if not Floor.is_walkable(plan, level, cx, cy):
		return null
	if wall_clearance(plan, level, x, z) < r - CLEARANCE_SLACK:
		return null
	return Body.make(x, z, level, feet_height(plan, level, x, z))

## Moves a body by (dx, dz) metres, sliding along walls, climbing stairs and changing level at the
## top. Never ends inside a wall or outside walkable space: a step that would is dropped, then
## retried along each axis alone, so a walker pressed into a corner still slides where it can.
static func move_with_collision(plan: Floor.FloorPlan, body: Body, dx: float, dz: float, radius: float) -> Body:
	var dist := M.hypot2(dx, dz)
	if dist == 0.0:
		return body
	# Steps shorter than half the radius cannot tunnel through a zero-thickness wall.
	var max_step := minf(0.1, radius * 0.5)
	var n := maxi(1, int(ceil(dist / max_step)))
	var sx := dx / n
	var sz := dz / n
	var cur := body
	for _i in n:
		var next := _try_step(plan, cur, sx, sz, radius)
		if next == null:
			next = _try_step(plan, cur, sx, 0.0, radius)
		if next == null:
			next = _try_step(plan, cur, 0.0, sz, radius)
		if next == null:
			break
		cur = next
	return cur
