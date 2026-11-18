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
static func _try_step(plan: Floor.FloorPlan, cur: Body, sx: float, sz: float, r: float, solids: Solids = null) -> Body:
	if sx == 0.0 and sz == 0.0:
		return null
	var from := cell_of(plan, cur)
	var p := _push_out(plan, cur.level, cur.x + sx, cur.z + sz, r, cur.x, cur.z)
	if solids != null:
		# Furniture: out of the boxes, then the walls again (twice settles a box beside a wall).
		for _k in 2:
			p = _push_boxes(solids, cur.level, p[0], p[1], r)
			p = _push_out(plan, cur.level, p[0], p[1], r, cur.x, cur.z)
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
	if solids != null and box_clearance(solids, level, x, z) < r - CLEARANCE_SLACK:
		return null
	return Body.make(x, z, level, feet_height(plan, level, x, z))

## Moves a body by (dx, dz) metres, sliding along walls, climbing stairs and changing level at the
## top. Never ends inside a wall or outside walkable space: a step that would is dropped, then
## retried along each axis alone, so a walker pressed into a corner still slides where it can.
## `solids` (players only: solid furniture, see Solids below) are boxes it slides along the same way;
## null, as for every resident and every run without furniture, reads none.
static func move_with_collision(plan: Floor.FloorPlan, body: Body, dx: float, dz: float, radius: float, solids: Solids = null) -> Body:
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
		var next := _try_step(plan, cur, sx, sz, radius, solids)
		if next == null:
			next = _try_step(plan, cur, sx, 0.0, radius, solids)
		if next == null:
			next = _try_step(plan, cur, 0.0, sz, radius, solids)
		if next == null:
			break
		cur = next
	return cur

# ---------------------------------------------------------------------------------------------
# Solid furniture (docs/floors/findables-and-day.md section 4, FD7): boxes players slide along like walls.
# sim/furniture.gd builds them from the floor's one list (Furniture.solids_of); only players move with them
# (Run.move_in_run on a run with `furniture`, the bots and the client's walks): the residents never do.

## A floor's solid footprints, metres: axis-aligned boxes per level, each listed in the cells it is within
## one cell of, so a body (radius under a cell) only meets the boxes listed in its own cell.
class Solids:
	var cell_size := 2.0
	var boxes: Array = [PackedFloat64Array(), PackedFloat64Array()]
	var near: Array = [{}, {}]

	func add(level: int, x0: float, z0: float, x1: float, z1: float) -> void:
		var b: PackedFloat64Array = boxes[level]
		var i := b.size() / 4
		b.append_array([x0, z0, x1, z1])
		boxes[level] = b
		var cells: Dictionary = near[level]
		for cy in range(int(floor(z0 / cell_size)) - 1, int(floor(z1 / cell_size)) + 2):
			for cx in range(int(floor(x0 / cell_size)) - 1, int(floor(x1 / cell_size)) + 2):
				var k := Vector2i(cx, cy)
				if not cells.has(k):
					cells[k] = PackedInt32Array()
				var l: PackedInt32Array = cells[k]
				l.append(i)
				cells[k] = l

	## The boxes near a point, by number.
	func around(level: int, x: float, z: float) -> PackedInt32Array:
		var cells: Dictionary = near[level]
		var k := Vector2i(int(floor(x / cell_size)), int(floor(z / cell_size)))
		return cells[k] if cells.has(k) else PackedInt32Array()

	func count() -> int:
		return (boxes[0] as PackedFloat64Array).size() / 4 + (boxes[1] as PackedFloat64Array).size() / 4

## Distance from a point to the nearest solid box on a level (0 inside one; INF if none is near).
static func box_clearance(solids: Solids, level: int, x: float, z: float) -> float:
	if solids == null or level < 0 or level > 1:
		return INF
	var best := INF
	var b: PackedFloat64Array = solids.boxes[level]
	for i in solids.around(level, x, z):
		var j := i * 4
		var qx := clampf(x, b[j], b[j + 2])
		var qz := clampf(z, b[j + 1], b[j + 3])
		best = minf(best, M.hypot2(x - qx, z - qz))
	return best

## Pushes a circle out of every box it overlaps (out of the nearest side when its centre is inside one).
static func _push_boxes(solids: Solids, level: int, x: float, z: float, r: float) -> PackedFloat64Array:
	var b: PackedFloat64Array = solids.boxes[level]
	for _pass in 3:
		var moved := false
		for i in solids.around(level, x, z):
			var j := i * 4
			var x0 := b[j]
			var z0 := b[j + 1]
			var x1 := b[j + 2]
			var z1 := b[j + 3]
			if x > x0 and x < x1 and z > z0 and z < z1:
				var dl := x - x0
				var dr := x1 - x
				var dt := z - z0
				var db := z1 - z
				var m := minf(minf(dl, dr), minf(dt, db))
				if m == dl:
					x = x0 - r
				elif m == dr:
					x = x1 + r
				elif m == dt:
					z = z0 - r
				else:
					z = z1 + r
				moved = true
				continue
			var qx := clampf(x, x0, x1)
			var qz := clampf(z, z0, z1)
			var nx := x - qx
			var nz := z - qz
			var d := M.hypot2(nx, nz)
			if d >= r:
				continue
			x = qx + (nx / d) * r
			z = qz + (nz / d) * r
			moved = true
		if not moved:
			break
	return PackedFloat64Array([x, z])

## Whether a body of radius r may stand at (x, z) on `level`: a walkable cell, clear of walls and boxes.
static func clear_at(plan: Floor.FloorPlan, solids: Solids, level: int, x: float, z: float, r: float) -> bool:
	var s := float(plan.cell_size)
	if not Floor.is_walkable(plan, level, int(floor(x / s)), int(floor(z / s))):
		return false
	return wall_clearance(plan, level, x, z) >= r - CLEARANCE_SLACK and box_clearance(solids, level, x, z) >= r - CLEARANCE_SLACK

## Where a body standing in a solid box (put there by a drag, a grab, a relocation, or furniture turning on
## under it) is pushed out to: the nearest spot (5 cm rings, out to SETTLE_REACH) in its own cell or one it
## could step to, clear of walls and boxes. The body itself when it is clear, or when no spot is found.
const SETTLE_REACH := 2.0
const SETTLE_STEP := 0.05

static func settle(plan: Floor.FloorPlan, solids: Solids, body: Body, r: float) -> Body:
	if solids == null or box_clearance(solids, body.level, body.x, body.z) >= r - CLEARANCE_SLACK:
		return body
	var s := float(plan.cell_size)
	var from := cell_of(plan, body)
	var best_d := INF
	var best := Vector3.ZERO
	var rings := int(round(SETTLE_REACH / SETTLE_STEP))
	for k in range(1, rings + 1):
		if float(k) * SETTLE_STEP > best_d:
			break
		for i in range(-k, k + 1):
			for side in 4:
				var ox := 0
				var oz := 0
				match side:
					0:
						ox = i
						oz = -k
					1:
						ox = k
						oz = i
					2:
						ox = -i
						oz = k
					_:
						ox = -k
						oz = -i
				if (side == 1 or side == 3) and absi(i) == k:
					continue  # the corners belong to the top and bottom rows
				var x := body.x + ox * SETTLE_STEP
				var z := body.z + oz * SETTLE_STEP
				var d := M.hypot2(x - body.x, z - body.z)
				if d >= best_d:
					continue
				var cx := int(floor(x / s))
				var cy := int(floor(z / s))
				var level := body.level
				if cx != from.x or cy != from.y:
					level = _level_after_step(plan, from, cx, cy)
					if level < 0:
						continue
				if not clear_at(plan, solids, level, x, z, r):
					continue
				best_d = d
				best = Vector3(x, z, level)
	if best_d == INF:
		return body
	return Body.make(best.x, best.y, int(best.z), feet_height(plan, int(best.z), best.x, best.y))

## A walk round the solid boxes for a body of radius r along a find_path route (`cells`, from the body's cell;
## the walk may also use the cells beside them): grid points FINE_STEP apart, each clear of walls and boxes by
## r and FINE_SPARE, straight runs merged, ending at the clear point nearest the last cell's centre, as
## Vector3(x, z, level). Empty when no such walk exists. For the bots and the client's test walks (sim/follow.gd).
const FINE_STEP := 0.25
const FINE_SPARE := 0.03
const _FINE_DIRS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]

static func fine_path(plan: Floor.FloorPlan, solids: Solids, from: Body, cells: Array[Floor.Pos], r: float) -> Array[Vector3]:
	var out: Array[Vector3] = []
	if cells.is_empty():
		return out
	var s := float(plan.cell_size)
	var sub := int(round(s / FINE_STEP))
	var gw := plan.width * sub
	var gh := plan.height * sub
	var per := gw * gh
	var allowed := {}
	for c in cells:
		allowed[Floor.pos_index(plan, c)] = true
		for st in Floor.STEPS:
			var nx := c.x + st.x
			var ny := c.y + st.y
			if Floor.is_walkable(plan, c.level, nx, ny):
				allowed[Floor.pos_index(plan, Floor.Pos.make(c.level, nx, ny))] = true
	var valid := {}
	var rr := r + FINE_SPARE
	# The goal: the clear point nearest the last cell's centre.
	var last := cells[cells.size() - 1]
	var goal := -1
	var goal_d := INF
	for j in sub:
		for i in sub:
			var gx := last.x * sub + i
			var gz := last.y * sub + j
			var x := gx * FINE_STEP
			var z := gz * FINE_STEP
			if not clear_at(plan, solids, last.level, x, z, rr):
				continue
			var d := M.hypot2(x - (last.x + 0.5) * s, z - (last.y + 0.5) * s)
			if d < goal_d:
				goal_d = d
				goal = last.level * per + gz * gw + gx
	if goal < 0:
		return out
	# Dijkstra from the clear points within half a metre of the body (costs in centimetres).
	var cost := {}
	var prev := {}
	var heap := PackedInt64Array()
	var bx := int(floor(from.x / FINE_STEP))
	var bz := int(floor(from.z / FINE_STEP))
	for dz in range(-2, 4):
		for dx in range(-2, 4):
			var gx := bx + dx
			var gz := bz + dz
			if gx < 0 or gz < 0 or gx >= gw or gz >= gh:
				continue
			var x := gx * FINE_STEP
			var z := gz * FINE_STEP
			var d := M.hypot2(x - from.x, z - from.z)
			if d > 0.5:
				continue
			var lv := from.level
			var fc := cell_of(plan, from)
			var cx := int(floor(x / s))
			var cz := int(floor(z / s))
			if cx != fc.x or cz != fc.y:
				lv = _level_after_step(plan, fc, cx, cz)
				if lv < 0:
					continue
			var n := lv * per + gz * gw + gx
			if not _fine_ok(plan, solids, allowed, valid, n, per, gw, sub, rr):
				continue
			var cc := int(round(d * 100.0))
			if not cost.has(n) or cost[n] > cc:
				cost[n] = cc
				_heap_push(heap, cc, n)
	while not heap.is_empty():
		var top := _heap_pop(heap)
		var cn := int(top & 0xffffffff)
		var cc := int(top >> 32)
		if cc > int(cost[cn]):
			continue
		if cn == goal:
			break
		var lv := cn / per
		var rest := cn - lv * per
		var gx := rest % gw
		var gz := rest / gw
		var here := Floor.Pos.make(lv, gx / sub, gz / sub)
		for k in 8:
			var dv := _FINE_DIRS[k]
			var nx := gx + dv.x
			var nz := gz + dv.y
			if nx < 0 or nz < 0 or nx >= gw or nz >= gh:
				continue
			var nl := lv
			if nx / sub != here.x or nz / sub != here.y:
				# Across a cell edge: straight steps only, as can_step allows them.
				if k >= 4:
					continue
				nl = _level_after_step(plan, here, nx / sub, nz / sub)
				if nl < 0:
					continue
			elif k >= 4:
				# A diagonal inside a cell: only when both straight ways are clear too.
				var a2 := lv * per + gz * gw + nx
				var b2 := lv * per + nz * gw + gx
				if not _fine_ok(plan, solids, allowed, valid, a2, per, gw, sub, rr) or not _fine_ok(plan, solids, allowed, valid, b2, per, gw, sub, rr):
					continue
			var nn := nl * per + nz * gw + nx
			if not _fine_ok(plan, solids, allowed, valid, nn, per, gw, sub, rr):
				continue
			var nc := cc + (35 if k >= 4 else 25)
			if not cost.has(nn) or int(cost[nn]) > nc:
				cost[nn] = nc
				prev[nn] = cn
				_heap_push(heap, nc, nn)
	if not cost.has(goal):
		return out
	var chain: Array[int] = []
	var at := goal
	while true:
		chain.append(at)
		if not prev.has(at):
			break
		at = int(prev[at])
	chain.reverse()
	var last_dir := Vector3.INF
	for i in chain.size():
		var n := chain[i]
		var lv := n / per
		var rest := n - lv * per
		var p := Vector3((rest % gw) * FINE_STEP, (rest / gw) * FINE_STEP, lv)
		if i > 0 and i < chain.size() - 1:
			var q := chain[i + 1]
			var ql := q / per
			var qr := q - ql * per
			var dir := Vector3((qr % gw) * FINE_STEP - p.x, (qr / gw) * FINE_STEP - p.y, ql - lv)
			if dir.is_equal_approx(last_dir) and ql == lv:
				out[out.size() - 1] = p
				continue
			last_dir = dir
		out.append(p)
	return out

static func _fine_ok(plan: Floor.FloorPlan, solids: Solids, allowed: Dictionary, valid: Dictionary, n: int, per: int, gw: int, sub: int, rr: float) -> bool:
	if valid.has(n):
		return valid[n]
	var lv := n / per
	var rest := n - lv * per
	var gx := rest % gw
	var gz := rest / gw
	var ok := allowed.has(lv * plan.width * plan.height + (gz / sub) * plan.width + gx / sub) \
		and clear_at(plan, solids, lv, gx * FINE_STEP, gz * FINE_STEP, rr)
	valid[n] = ok
	return ok

static func _heap_push(h: PackedInt64Array, c: int, n: int) -> void:
	h.append((c << 32) | n)
	var i := h.size() - 1
	while i > 0:
		var p := (i - 1) / 2
		if h[p] <= h[i]:
			break
		var t := h[p]
		h[p] = h[i]
		h[i] = t
		i = p

static func _heap_pop(h: PackedInt64Array) -> int:
	var top := h[0]
	var last := h[h.size() - 1]
	h.resize(h.size() - 1)
	if h.is_empty():
		return top
	h[0] = last
	var i := 0
	while true:
		var l := 2 * i + 1
		var r := l + 1
		var m := i
		if l < h.size() and h[l] < h[m]:
			m = l
		if r < h.size() and h[r] < h[m]:
			m = r
		if m == i:
			break
		var t := h[m]
		h[m] = h[i]
		h[i] = t
		i = m
	return top
