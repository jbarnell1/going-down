# Walking a find_path route with real collision: aim at the centre of the next cell, move, repeat.
# Used by bots and entities. Port of src/sim/follow.ts.
#
# With solid furniture (`solids`, sim/move.gd Solids), the walk first plans a route round the boxes through the path's cells
# (Move.fine_path) and follows that instead of the cell centres; `next` still moves along the path's cells as
# they are entered, and the walk is done at the end of that route.
extends RefCounted

const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const M = preload("res://sim/jsmath.gd")

class PathWalk:
	var path: Array[Floor.Pos] = []
	## Index of the waypoint being walked to.
	var next: int = 0
	## With solid furniture: the planned route (Vector3(x, z, level)), whether it was planned, and the point
	## being walked to.
	var fine: Array[Vector3] = []
	var fine_on := false
	var fine_next := 0

	static func make(path_: Array[Floor.Pos], next_: int) -> PathWalk:
		var w := PathWalk.new()
		w.path = path_
		w.next = next_
		return w

	func copy() -> PathWalk:
		var w := make(path, next)
		w.fine = fine
		w.fine_on = fine_on
		w.fine_next = fine_next
		return w

## How close to a waypoint's centre counts as reached. Small, so corners are turned square.
const REACHED := 0.08
## Long routes are solved a few cells at a time. The floor graph gives the long-distance route;
## only the current leg needs the finer geometry of every chair and cabinet.
const RESIDENT_LEG_CELLS := 4

## The precise route a resident is following. A route is replaced when its destination moves far
## enough to need it, including an empty route to an unreachable point. This keeps chase ticks from
## running a search every frame against a goal behind a cabinet or near a wall.
class ResidentWalk:
	var goal: Move.Body = null
	var points: Array[Vector3] = []
	var next := 0
	var more := false

	func copy() -> ResidentWalk:
		var w := ResidentWalk.new()
		w.goal = goal
		w.points = points
		w.next = next
		w.more = more
		return w

static func step_resident_walk(plan: Floor.FloorPlan, walk: ResidentWalk, body: Move.Body, goal: Move.Body, max_dist: float, radius: float, solids: Move.Solids, stop: float = 0.0) -> Move.Body:
	var here := Move.cell_of(plan, body)
	var there := Move.cell_of(plan, goal)
	var dx := goal.x - body.x
	var dz := goal.z - body.z
	var gap := M.hypot2(dx, dz)
	# Finish directly when there is a clear approach to the point. Some legal player or hide positions
	# have too little clearance for the resident to stand on them. The route below approaches those.
	if here.equals(there) and (walk.next >= walk.points.size() or walk.goal == null):
		if gap <= stop + 1e-6:
			return body
		var leg := (gap - stop) / gap
		var end := Move.Body.make(body.x + dx * leg, body.z + dz * leg, goal.level, 0.0)
		if Move.straight_to(plan, solids, body, end, radius):
			var step := minf(max_dist, gap - stop) / gap
			return Move.move_with_collision(plan, body, dx * step, dz * step, radius, solids)
	var new_goal := walk.goal == null or not there.equals(Move.cell_of(plan, walk.goal)) \
			or (not walk.more and M.hypot2(goal.x - walk.goal.x, goal.z - walk.goal.z) >= Move.FINE_STEP * 2.0)
	var next_leg := walk.more and not walk.points.is_empty() and walk.next >= walk.points.size()
	if new_goal or next_leg:
		walk.goal = goal
		walk.next = 0
		var cells := Floor.find_path(plan, here, there)
		walk.more = cells.size() > RESIDENT_LEG_CELLS
		var end := goal
		if walk.more:
			cells.resize(RESIDENT_LEG_CELLS)
			end = Move.body_at_cell(plan, cells.back())
		walk.points = _resident_leg(plan, solids, body, cells, end, radius, walk.more)
	while walk.next < walk.points.size():
		var w := walk.points[walk.next]
		var d := M.hypot2(w.x - body.x, w.y - body.z)
		if d <= 1e-6 and body.level == int(w.z):
			walk.next += 1
			continue
		if d <= 1e-6:
			break
		var step := minf(max_dist, d) / d
		# Keep a turn at a waypoint on its own tick so the client does not interpolate across the corner.
		var moved := Move.move_with_collision(plan, body, (w.x - body.x) * step, (w.y - body.z) * step, radius, solids)
		if step == 1.0 and int(w.z) == moved.level and M.hypot2(w.x - moved.x, w.y - moved.z) <= 1e-6:
			walk.next += 1
		return moved
	return body

static func _resident_leg(plan: Floor.FloorPlan, solids: Move.Solids, body: Move.Body, cells: Array[Floor.Pos], end: Move.Body, radius: float, partial: bool) -> Array[Vector3]:
	while not cells.is_empty():
		if Move.straight_to(plan, solids, body, end, radius):
			return [Vector3(end.x, end.z, end.level)]
		var points := Move.fine_path(plan, solids, body, cells, radius, end)
		if not points.is_empty() or not partial or cells.size() <= 2 \
				or Move.clear_at(plan, solids, end.level, end.x, end.z, radius):
			return points
		# Furniture may occupy a whole intermediate coarse cell. Try the preceding cell, where we
		# can choose the next leg from an actual standing spot beside the furniture.
		cells.pop_back()
		end = Move.body_at_cell(plan, cells.back())
	return []

static func start_path_walk(path: Array[Floor.Pos]) -> PathWalk:
	return PathWalk.make(path, 1 if path.size() > 1 else 0)

## True once the body stands at the centre of the last cell of the path (with furniture: at the end of the
## route round it, or, when none was found, anywhere in the last cell).
static func path_done(plan: Floor.FloorPlan, walk: PathWalk, body: Move.Body) -> bool:
	if walk.path.is_empty():
		return false
	var last := walk.path[walk.path.size() - 1]
	var c := Move.cell_of(plan, body)
	var in_last := c.level == last.level and c.x == last.x and c.y == last.y
	if walk.fine_on:
		if walk.fine.is_empty():
			return in_last
		return walk.fine_next >= walk.fine.size() and in_last
	if walk.next < walk.path.size() - 1:
		return false
	var s := plan.cell_size
	return in_last and M.hypot2(body.x - (last.x + 0.5) * s, body.z - (last.y + 0.5) * s) <= REACHED

## Moves the body up to `max_dist` metres along the path. Returns the new body.
static func step_path_walk(plan: Floor.FloorPlan, walk: PathWalk, body: Move.Body, max_dist: float, radius: float, solids: Move.Solids = null) -> Move.Body:
	if solids != null:
		return _step_fine(plan, walk, body, max_dist, radius, solids)
	var s := plan.cell_size
	var cur := body
	var budget := max_dist
	while budget > 1e-9:
		if walk.next < 0 or walk.next >= walk.path.size():
			break
		var wp := walk.path[walk.next]
		var tx := (wp.x + 0.5) * s
		var tz := (wp.y + 0.5) * s
		var d := M.hypot2(tx - cur.x, tz - cur.z)
		var c := Move.cell_of(plan, cur)
		if d <= REACHED and c.x == wp.x and c.y == wp.y and c.level == wp.level:
			if walk.next >= walk.path.size() - 1:
				break
			walk.next += 1
			continue
		var step := minf(budget, d)
		var moved := Move.move_with_collision(plan, cur, ((tx - cur.x) / d) * step, ((tz - cur.z) / d) * step, radius)
		var progress := M.hypot2(moved.x - cur.x, moved.z - cur.z)
		cur = moved
		budget -= step
		if progress < 1e-6:
			break  # blocked; the caller decides when to give up
	return cur

static func _step_fine(plan: Floor.FloorPlan, walk: PathWalk, body: Move.Body, max_dist: float, radius: float, solids: Move.Solids) -> Move.Body:
	if not walk.fine_on:
		walk.fine_on = true
		var cells: Array[Floor.Pos] = []
		for i in range(maxi(0, walk.next - 1), walk.path.size()):
			cells.append(walk.path[i])
		walk.fine = Move.fine_path(plan, solids, body, cells, radius)
		walk.fine_next = 0
	var cur := body
	var budget := max_dist
	if walk.fine.is_empty():
		# No route round the furniture: the cell centres, sliding along it.
		var s := plan.cell_size
		while budget > 1e-9 and walk.next >= 0 and walk.next < walk.path.size():
			var wp := walk.path[walk.next]
			var tx := (wp.x + 0.5) * s
			var tz := (wp.y + 0.5) * s
			var d0 := M.hypot2(tx - cur.x, tz - cur.z)
			if d0 <= REACHED:
				if walk.next >= walk.path.size() - 1:
					break
				walk.next += 1
				continue
			var st := minf(budget, d0)
			var mv := Move.move_with_collision(plan, cur, ((tx - cur.x) / d0) * st, ((tz - cur.z) / d0) * st, radius, solids)
			var pr := M.hypot2(mv.x - cur.x, mv.z - cur.z)
			cur = mv
			budget -= st
			if pr < 1e-6:
				break
		return cur
	while budget > 1e-9 and walk.fine_next < walk.fine.size():
		var w := walk.fine[walk.fine_next]
		var d := M.hypot2(w.x - cur.x, w.y - cur.z)
		if d <= REACHED:
			walk.fine_next += 1
			_advance(plan, walk, cur)
			continue
		var step := minf(budget, d)
		var moved := Move.move_with_collision(plan, cur, ((w.x - cur.x) / d) * step, ((w.y - cur.z) / d) * step, radius, solids)
		var progress := M.hypot2(moved.x - cur.x, moved.z - cur.z)
		cur = moved
		budget -= step
		_advance(plan, walk, cur)
		if progress < 1e-6:
			break
	return cur

## Moves `next` past the path's cells the body has reached.
static func _advance(plan: Floor.FloorPlan, walk: PathWalk, body: Move.Body) -> void:
	var c := Move.cell_of(plan, body)
	for i in range(walk.next, walk.path.size()):
		var p := walk.path[i]
		if p.level == c.level and p.x == c.x and p.y == c.y:
			walk.next = mini(i + 1, walk.path.size() - 1)
			return
