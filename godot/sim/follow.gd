# Walking a find_path route with real collision: aim at the centre of the next cell, move, repeat.
# Used by bots and entities. Port of src/sim/follow.ts.
extends RefCounted

const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const M = preload("res://sim/jsmath.gd")

class PathWalk:
	var path: Array[Floor.Pos] = []
	## Index of the waypoint being walked to.
	var next: int = 0

	static func make(path_: Array[Floor.Pos], next_: int) -> PathWalk:
		var w := PathWalk.new()
		w.path = path_
		w.next = next_
		return w

	func copy() -> PathWalk:
		return make(path, next)

## How close to a waypoint's centre counts as reached. Small, so corners are turned square.
const REACHED := 0.08

static func start_path_walk(path: Array[Floor.Pos]) -> PathWalk:
	return PathWalk.make(path, 1 if path.size() > 1 else 0)

## True once the body stands at the centre of the last cell of the path.
static func path_done(plan: Floor.FloorPlan, walk: PathWalk, body: Move.Body) -> bool:
	if walk.path.is_empty() or walk.next < walk.path.size() - 1:
		return false
	var last := walk.path[walk.path.size() - 1]
	var c := Move.cell_of(plan, body)
	var s := plan.cell_size
	return c.level == last.level and c.x == last.x and c.y == last.y \
		and M.hypot2(body.x - (last.x + 0.5) * s, body.z - (last.y + 0.5) * s) <= REACHED

## Moves the body up to `max_dist` metres along the path. Returns the new body.
static func step_path_walk(plan: Floor.FloorPlan, walk: PathWalk, body: Move.Body, max_dist: float, radius: float) -> Move.Body:
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
