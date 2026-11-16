# Floor plans: the shared shape every place generator produces, and the pure helpers that bots,
# entities and the renderer use to move around one. A plan is a grid of 2 m cells on two levels.
# Port of src/sim/floor.ts.
#
# Walls are implicit. Two edge-adjacent walkable cells on the same level are connected when they
# are in the same room, when both are corridor, or when a Door joins them. Everything else is
# walled off, so rooms packed side by side are separate rooms with a wall between them.
#
# Stairs: a stair occupies the same cells on both levels (kind 'stair' in both grids). A walker on
# a stair counts as being on level 0 until they step off the top. Concretely:
#   - the bottom end is entered from the cell just behind the start, on level 0;
#   - stair cells connect to each other along the stair's axis only (it has side walls);
#   - the last stair cell (level 0) connects to the cell just beyond it on level 1.
# So on level 1 the stair cells are a hole in the floor you look down into, not floor you stand on.
#
# Plans are treated as immutable once generated: lookup indexes are cached on the plan object.
#
# Data: cell kinds, directions, room kinds and branches are StringNames with the TypeScript
# spellings (&"corridor", &"n", &"atrium", &"side"). Field names are the TypeScript ones in
# snake_case (cellSize -> cell_size, entityStart -> entity_start).
extends RefCounted

const M = preload("res://sim/jsmath.gd")

# CellKind: 'void' | 'corridor' | 'room' | 'stair' | 'landing' | 'atriumOpen'
const VOID := &"void"
const CORRIDOR := &"corridor"
const ROOM := &"room"
const STAIR := &"stair"
const LANDING := &"landing"
const ATRIUM_OPEN := &"atriumOpen"

class Room:
	var id: int
	var level: int
	## 'ward' | 'exam' | 'station' | 'closet' | 'atrium' | 'lobby'
	var kind: StringName
	var x: int
	var y: int
	var w: int
	var h: int
	## 'side' rooms form dead-end groups off the main route; see side_branches().
	var branch: StringName = &"main"

	func copy() -> Room:
		var r := Room.new()
		r.id = id
		r.level = level
		r.kind = kind
		r.x = x
		r.y = y
		r.w = w
		r.h = h
		r.branch = branch
		return r

## An opening between two edge-adjacent cells on the same level.
class Door:
	var level: int
	var ax: int
	var ay: int
	var bx: int
	var by: int

	static func make(level_: int, ax_: int, ay_: int, bx_: int, by_: int) -> Door:
		var d := Door.new()
		d.level = level_
		d.ax = ax_
		d.ay = ay_
		d.bx = bx_
		d.by = by_
		return d

## Starts at (x, y) on the bottom and climbs `length` cells in direction `dir`.
class Stair:
	var x: int
	var y: int
	var dir: StringName
	var length: int

	static func make(x_: int, y_: int, dir_: StringName, length_: int) -> Stair:
		var s := Stair.new()
		s.x = x_
		s.y = y_
		s.dir = dir_
		s.length = length_
		return s

class Sightline:
	var level: int
	var x1: int
	var y1: int
	var x2: int
	var y2: int
	## In cells (multiply by cell_size for metres). Both ends included.
	var length: int

class Pos:
	var level: int
	var x: int
	var y: int

	static func make(level_: int, x_: int, y_: int) -> Pos:
		var p := Pos.new()
		p.level = level_
		p.x = x_
		p.y = y_
		return p

	func equals(o: Pos) -> bool:
		return level == o.level and x == o.x and y == o.y

class FloorPlan:
	var place: StringName = &"clinic"
	var seed: String
	var depth: int
	var width: int
	var height: int
	var cell_size: int  # TypeScript: cellSize
	## Per level, row-major, length width*height.
	var cells: Array[Array] = [[], []]
	var rooms: Array[Room] = []
	var doors: Array[Door] = []
	var stairs: Array[Stair] = []
	## Where the elevator opens. The elevator is the only safe place.
	var landing: Pos
	## Where the entity begins: far from the landing, on or at the end of a long sightline.
	var entity_start: Pos  # TypeScript: entityStart
	## Long straight runs of corridor, so threats can be seen from far away.
	var sightlines: Array[Sightline] = []

	# Caches (TypeScript keeps these in WeakMaps keyed by the plan object).
	var _index: PlanIndex = null
	var _adjacency: Adjacency = null
	var _edges: Array = []  # walls.gd edge tables, per level
	var _field_index := -1  # entity.gd distancesCached
	var _field: PackedInt32Array = PackedInt32Array()
	var _reachable: PackedInt32Array = PackedInt32Array()  # bot.gd reachableCells
	var _has_reachable := false

	## A shallow copy with fresh caches (TypeScript: { ...plan }). Arrays are copied, items shared.
	func copy() -> FloorPlan:
		var p := FloorPlan.new()
		p.place = place
		p.seed = seed
		p.depth = depth
		p.width = width
		p.height = height
		p.cell_size = cell_size
		p.cells = [cells[0], cells[1]]
		p.rooms = rooms.duplicate()
		p.doors = doors.duplicate()
		p.stairs = stairs.duplicate()
		p.landing = landing
		p.entity_start = entity_start
		p.sightlines = sightlines.duplicate()
		return p

class PlanIndex:
	var room_at: Array[PackedInt32Array] = []
	var doors: Dictionary = {}
	## level-0 cell -> stair index, or -1
	var stair_at: PackedInt32Array

class Adjacency:
	var start: PackedInt32Array
	var list: PackedInt32Array

# DIR_VEC
const DIR_DX := {&"n": 0, &"e": 1, &"s": 0, &"w": -1}
const DIR_DY := {&"n": -1, &"e": 0, &"s": 1, &"w": 0}

static func dir_dx(d: StringName) -> int:
	return DIR_DX[d]

static func dir_dy(d: StringName) -> int:
	return DIR_DY[d]

static func dir_from_vec(dx: int, dy: int) -> StringName:
	if dx == 0 and dy == -1:
		return &"n"
	if dx == 1 and dy == 0:
		return &"e"
	if dx == 0 and dy == 1:
		return &"s"
	if dx == -1 and dy == 0:
		return &"w"
	push_error("not a unit direction: %d,%d" % [dx, dy])
	return &"n"

static func in_bounds(plan: FloorPlan, x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < plan.width and y < plan.height

## Out-of-grid cells read as 'void'.
static func cell_at(plan: FloorPlan, level: int, x: int, y: int) -> StringName:
	if x < 0 or y < 0 or x >= plan.width or y >= plan.height:
		return VOID
	return plan.cells[level][y * plan.width + x]

## Whether someone can stand here. Stair cells count as level 0 only (see the header).
static func is_walkable(plan: FloorPlan, level: int, x: int, y: int) -> bool:
	var k := cell_at(plan, level, x, y)
	if k == CORRIDOR or k == ROOM or k == LANDING:
		return true
	return k == STAIR and level == 0

## The cells a stair occupies, bottom first.
static func stair_cells(stair: Stair) -> Array[Pos]:
	var dx := dir_dx(stair.dir)
	var dy := dir_dy(stair.dir)
	var out: Array[Pos] = []
	for i in stair.length:
		out.append(Pos.make(0, stair.x + dx * i, stair.y + dy * i))
	return out

## Level-0 cell you step onto the stair from (TypeScript: stairEnds().bottom).
static func stair_bottom(stair: Stair) -> Pos:
	return Pos.make(0, stair.x - dir_dx(stair.dir), stair.y - dir_dy(stair.dir))

## The level-1 cell you step off onto (TypeScript: stairEnds().top).
static func stair_top(stair: Stair) -> Pos:
	return Pos.make(1, stair.x + dir_dx(stair.dir) * stair.length, stair.y + dir_dy(stair.dir) * stair.length)

# ---------------------------------------------------------------------------------------------
# Lookup index, built once per plan.

static func _door_key(plan: FloorPlan, level: int, a: int, b: int) -> int:
	var n := plan.width * plan.height
	var lo := mini(a, b)
	var hi := maxi(a, b)
	return (level * n + lo) * n + hi

static func index_of(plan: FloorPlan) -> PlanIndex:
	if plan._index != null:
		return plan._index
	var n := plan.width * plan.height
	var idx := PlanIndex.new()
	for level in 2:
		var arr := PackedInt32Array()
		arr.resize(n)
		arr.fill(-1)
		idx.room_at.append(arr)
	for r in plan.rooms:
		var arr: PackedInt32Array = idx.room_at[r.level]
		for y in range(r.y, r.y + r.h):
			for x in range(r.x, r.x + r.w):
				if in_bounds(plan, x, y):
					arr[y * plan.width + x] = r.id
		idx.room_at[r.level] = arr
	for d in plan.doors:
		idx.doors[_door_key(plan, d.level, d.ay * plan.width + d.ax, d.by * plan.width + d.bx)] = true
	idx.stair_at = PackedInt32Array()
	idx.stair_at.resize(n)
	idx.stair_at.fill(-1)
	for i in plan.stairs.size():
		for c in stair_cells(plan.stairs[i]):
			if in_bounds(plan, c.x, c.y):
				idx.stair_at[c.y * plan.width + c.x] = i
	plan._index = idx
	return idx

## Room id at a cell, or -1.
static func room_id_at(plan: FloorPlan, level: int, x: int, y: int) -> int:
	if not in_bounds(plan, x, y):
		return -1
	return index_of(plan).room_at[level][y * plan.width + x]

static func has_door(plan: FloorPlan, level: int, ax: int, ay: int, bx: int, by: int) -> bool:
	if not in_bounds(plan, ax, ay) or not in_bounds(plan, bx, by):
		return false
	return index_of(plan).doors.has(_door_key(plan, level, ay * plan.width + ax, by * plan.width + bx))

# ---------------------------------------------------------------------------------------------
# Movement.

## Whether a walker may move from one cell to an edge-adjacent cell (possibly changing level on a stair).
static func can_step(plan: FloorPlan, from: Pos, to: Pos) -> bool:
	return can_step_xy(plan, from.level, from.x, from.y, to.level, to.x, to.y)

## can_step on bare coordinates (no Pos objects), for the hot paths.
static func can_step_xy(plan: FloorPlan, fl: int, fx: int, fy: int, tl: int, tx: int, ty: int) -> bool:
	var dx := tx - fx
	var dy := ty - fy
	if absi(dx) + absi(dy) != 1:
		return false
	if not is_walkable(plan, fl, fx, fy) or not is_walkable(plan, tl, tx, ty):
		return false
	var idx := index_of(plan)
	var w := plan.width

	if fl != tl:
		var lox := fx if fl == 0 else tx
		var loy := fy if fl == 0 else ty
		var hix := tx if fl == 0 else fx
		var hiy := ty if fl == 0 else fy
		var si := idx.stair_at[loy * w + lox]
		if si < 0:
			return false
		var s := plan.stairs[si]
		var vx := dir_dx(s.dir)
		var vy := dir_dy(s.dir)
		var end_x := s.x + vx * (s.length - 1)
		var end_y := s.y + vy * (s.length - 1)
		return lox == end_x and loy == end_y and hix == end_x + vx and hiy == end_y + vy

	var level := fl
	var a := fy * w + fx
	var b := ty * w + tx
	var sa := idx.stair_at[a] if level == 0 else -1
	var sb := idx.stair_at[b] if level == 0 else -1
	if sa >= 0 or sb >= 0:
		# Two cells of the same straight stair are adjacent only along its axis.
		if sa >= 0 and sb >= 0:
			return sa == sb
		var s := plan.stairs[sa if sa >= 0 else sb]
		var on_x := fx if sa >= 0 else tx
		var on_y := fy if sa >= 0 else ty
		var off_x := tx if sa >= 0 else fx
		var off_y := ty if sa >= 0 else fy
		return on_x == s.x and on_y == s.y and off_x == s.x - dir_dx(s.dir) and off_y == s.y - dir_dy(s.dir)

	var ra := idx.room_at[level][a]
	var rb := idx.room_at[level][b]
	if ra >= 0 and ra == rb:
		return true
	var cl: Array = plan.cells[level]
	if cl[a] == CORRIDOR and cl[b] == CORRIDOR:
		return true
	return idx.doors.has(_door_key(plan, level, a, b))

const STEPS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]

## Every position reachable in one step, including the level change at a stair.
static func neighbours(plan: FloorPlan, pos: Pos) -> Array[Pos]:
	var out: Array[Pos] = []
	for level: int in [pos.level, 1 if pos.level == 0 else 0]:
		for st in STEPS:
			if can_step_xy(plan, pos.level, pos.x, pos.y, level, pos.x + st.x, pos.y + st.y):
				out.append(Pos.make(level, pos.x + st.x, pos.y + st.y))
	return out

## A position packed into one integer, for sets and arrays.
static func pos_index(plan: FloorPlan, pos: Pos) -> int:
	return pos.level * plan.width * plan.height + pos.y * plan.width + pos.x

## neighbours() for every position, packed (CSR), in the same order neighbours() returns them, so
## searches over it visit cells in the same order. Built once per plan.
static func adjacency_of(plan: FloorPlan) -> Adjacency:
	if plan._adjacency != null:
		return plan._adjacency
	var total := plan.width * plan.height * 2
	var start := PackedInt32Array()
	start.resize(total + 1)
	var list := PackedInt32Array()
	var n := plan.width * plan.height
	for i in total:
		start[i] = list.size()
		var level := 1 if i >= n else 0
		var rest := i - level * n
		var x := rest % plan.width
		var y := rest / plan.width
		if not is_walkable(plan, level, x, y):
			continue
		for to_level: int in [level, 1 if level == 0 else 0]:
			for st in STEPS:
				if can_step_xy(plan, level, x, y, to_level, x + st.x, y + st.y):
					list.append(to_level * n + (y + st.y) * plan.width + x + st.x)
	start[total] = list.size()
	var adj := Adjacency.new()
	adj.start = start
	adj.list = list
	plan._adjacency = adj
	return adj

static func pos_from_index(plan: FloorPlan, index: int) -> Pos:
	var n := plan.width * plan.height
	var level := 1 if index >= n else 0
	var rest := index - level * n
	return Pos.make(level, rest % plan.width, rest / plan.width)

## Path-step distance from `from` to every position (indexed by pos_index), -1 if unreachable.
static func distances_from(plan: FloorPlan, from: Pos) -> PackedInt32Array:
	var total := plan.width * plan.height * 2
	var dist := PackedInt32Array()
	dist.resize(total)
	dist.fill(-1)
	if not is_walkable(plan, from.level, from.x, from.y):
		return dist
	var adj := adjacency_of(plan)
	var start := adj.start
	var list := adj.list
	var queue := PackedInt32Array()
	queue.resize(total)
	var tail := 0
	var first := pos_index(plan, from)
	queue[tail] = first
	tail += 1
	dist[first] = 0
	var head := 0
	while head < tail:
		var pi := queue[head]
		head += 1
		var d := dist[pi]
		var end := start[pi + 1]
		for k in range(start[pi], end):
			var qi := list[k]
			if dist[qi] != -1:
				continue
			dist[qi] = d + 1
			queue[tail] = qi
			tail += 1
	return dist

## Shortest path (BFS), from and to included, or an empty list if there is none (TypeScript: null).
static func find_path(plan: FloorPlan, from: Pos, to: Pos) -> Array[Pos]:
	var none: Array[Pos] = []
	if not is_walkable(plan, from.level, from.x, from.y) or not is_walkable(plan, to.level, to.x, to.y):
		return none
	var goal := pos_index(plan, to)
	var total := plan.width * plan.height * 2
	var prev := PackedInt32Array()
	prev.resize(total)
	prev.fill(-2)
	var adj := adjacency_of(plan)
	var start := adj.start
	var list := adj.list
	var first := pos_index(plan, from)
	prev[first] = -1
	var queue := PackedInt32Array()
	queue.resize(total)
	var tail := 0
	queue[tail] = first
	tail += 1
	var head := 0
	while head < tail and prev[goal] == -2:
		var pi := queue[head]
		head += 1
		var end := start[pi + 1]
		for k in range(start[pi], end):
			var qi := list[k]
			if prev[qi] != -2:
				continue
			prev[qi] = pi
			queue[tail] = qi
			tail += 1
	if prev[goal] == -2:
		return none
	var path: Array[Pos] = []
	var i := goal
	while i != -1:
		path.append(pos_from_index(plan, i))
		i = prev[i]
	path.reverse()
	return path

## All positions reachable from `pos`, as pos_index values, ascending (TypeScript: a Set, in
## insertion order; only membership and the sorted list are ever used).
static func reachable_from(plan: FloorPlan, pos: Pos) -> PackedInt32Array:
	var dist := distances_from(plan, pos)
	var out := PackedInt32Array()
	for i in dist.size():
		if dist[i] >= 0:
			out.append(i)
	return out

# ---------------------------------------------------------------------------------------------
# Analysis shared by generators and tests.

## Maximal straight runs of corridor cells at least `min_length` long, per level. Corridor cells are
## always connected to each other, so a straight run is a clear line of sight down a hall.
static func find_sightlines(plan: FloorPlan, min_length: int) -> Array[Sightline]:
	var out: Array[Sightline] = []
	for level in 2:
		for y in plan.height:
			var x := 0
			while x < plan.width:
				if cell_at(plan, level, x, y) != CORRIDOR:
					x += 1
					continue
				var e := x
				while cell_at(plan, level, e + 1, y) == CORRIDOR:
					e += 1
				if e - x + 1 >= min_length:
					out.append(_sightline(level, x, y, e, y, e - x + 1))
				x = e + 1
		for x in plan.width:
			var y := 0
			while y < plan.height:
				if cell_at(plan, level, x, y) != CORRIDOR:
					y += 1
					continue
				var e := y
				while cell_at(plan, level, x, e + 1) == CORRIDOR:
					e += 1
				if e - y + 1 >= min_length:
					out.append(_sightline(level, x, y, x, e, e - y + 1))
				y = e + 1
	return out

static func _sightline(level: int, x1: int, y1: int, x2: int, y2: int, length: int) -> Sightline:
	var s := Sightline.new()
	s.level = level
	s.x1 = x1
	s.y1 = y1
	s.x2 = x2
	s.y2 = y2
	s.length = length
	return s

static func on_sightline(s: Sightline, pos: Pos) -> bool:
	return s.level == pos.level and pos.x >= mini(s.x1, s.x2) and pos.x <= maxi(s.x1, s.x2) \
		and pos.y >= mini(s.y1, s.y2) and pos.y <= maxi(s.y1, s.y2)

## Side branches. Definition: treat each room as a node and each door as an edge, with all corridors
## (and stairs) on both levels merged into one "hall" node. Repeatedly remove any room, other than
## the lobby and the atrium, that has exactly one door left. The removed rooms are the side rooms; a
## side branch is a group of side rooms joined to each other by doors. Each group is joined to the
## rest of the floor by exactly one door, so whoever explores it leaves the way they came in.
## Returns groups of room ids, each sorted, in order of their smallest id.
## `room_at` is called as room_at.call(door, "a" or "b") and returns a room id or -1.
static func side_branches(rooms: Array[Room], doors: Array[Door], room_at: Callable) -> Array[PackedInt32Array]:
	var HALL := -1
	var edges: Array[Vector2i] = []
	for d in doors:
		var ra: int = room_at.call(d, "a")
		var rb: int = room_at.call(d, "b")
		if ra == rb:
			continue
		edges.append(Vector2i(ra, rb))
	var degree := {}
	for e in edges:
		degree[e.x] = int(degree.get(e.x, 0)) + 1
		degree[e.y] = int(degree.get(e.y, 0)) + 1
	var protected_room := {}
	for r in rooms:
		if r.kind == &"lobby" or r.kind == &"atrium":
			protected_room[r.id] = true
	var removed := {}  # insertion-ordered, like a JavaScript Set
	var alive: Array[bool] = []
	alive.resize(edges.size())
	alive.fill(true)
	var queue: Array[int] = []
	for r in rooms:
		if int(degree.get(r.id, 0)) == 1 and not protected_room.has(r.id):
			queue.append(r.id)
	while queue.size() > 0:
		var r: int = queue.pop_front()
		if removed.has(r) or int(degree.get(r, 0)) != 1:
			continue
		removed[r] = true
		for i in edges.size():
			var a := edges[i].x
			var b := edges[i].y
			if not alive[i] or (a != r and b != r):
				continue
			alive[i] = false
			var other := b if a == r else a
			degree[r] = 0
			degree[other] = int(degree.get(other, 0)) - 1
			if other != HALL and not removed.has(other) and not protected_room.has(other) and int(degree[other]) == 1:
				queue.append(other)
	# Group removed rooms by doors between two removed rooms.
	var parent := {}
	for r: int in removed:
		parent[r] = r
	for e in edges:
		if removed.has(e.x) and removed.has(e.y):
			parent[_find(parent, e.x)] = _find(parent, e.y)
	var sorted_removed: Array[int] = []
	for r: int in removed:
		sorted_removed.append(r)
	sorted_removed.sort()
	var groups := {}  # insertion-ordered
	for r in sorted_removed:
		var g := _find(parent, r)
		if not groups.has(g):
			groups[g] = PackedInt32Array()
		var list: PackedInt32Array = groups[g]
		list.append(r)
		groups[g] = list
	var out: Array[PackedInt32Array] = []
	for g: int in groups:
		out.append(groups[g])
	# Stable sort by first id (the first ids are distinct).
	out.sort_custom(func(p: PackedInt32Array, q: PackedInt32Array) -> bool: return p[0] < q[0])
	return out

static func _find(parent: Dictionary, x: int) -> int:
	var p: int = parent.get(x, x)
	while p != int(parent.get(p, p)):
		p = parent.get(p, p)
	parent[x] = p
	return p

# ---------------------------------------------------------------------------------------------
# Hashing and debug output.

## The plan as plain data with the TypeScript field names (what hashPlan and the reference files see).
static func plan_to_plain(plan: FloorPlan) -> Dictionary:
	var rooms: Array = []
	for r in plan.rooms:
		rooms.append({"id": r.id, "level": r.level, "kind": String(r.kind), "x": r.x, "y": r.y, "w": r.w, "h": r.h, "branch": String(r.branch)})
	var doors: Array = []
	for d in plan.doors:
		doors.append({"level": d.level, "ax": d.ax, "ay": d.ay, "bx": d.bx, "by": d.by})
	var stairs: Array = []
	for s in plan.stairs:
		stairs.append({"x": s.x, "y": s.y, "dir": String(s.dir), "length": s.length})
	var sl: Array = []
	for s in plan.sightlines:
		sl.append({"level": s.level, "x1": s.x1, "y1": s.y1, "x2": s.x2, "y2": s.y2, "length": s.length})
	var cells: Array = []
	for level in 2:
		var row: Array = []
		for k: StringName in plan.cells[level]:
			row.append(String(k))
		cells.append(row)
	return {
		"place": String(plan.place), "seed": plan.seed, "depth": plan.depth, "width": plan.width, "height": plan.height,
		"cellSize": plan.cell_size, "cells": cells, "rooms": rooms, "doors": doors, "stairs": stairs,
		"landing": pos_plain(plan.landing), "entityStart": pos_plain(plan.entity_start), "sightlines": sl,
	}

static func pos_plain(p: Pos) -> Dictionary:
	return {"level": p.level, "x": p.x, "y": p.y}

## JSON.stringify with object keys sorted, for plain data of strings, integers, booleans, null,
## arrays and dictionaries (all a plan holds).
static func stable_stringify(v: Variant) -> String:
	if v == null:
		return "null"
	if v is bool:
		return "true" if v else "false"
	if v is int:
		return str(v)
	if v is float:
		var f: float = v
		assert(f == floorf(f) and absf(f) < 9007199254740992.0, "stable_stringify: only integers")
		return str(int(f))
	if v is String or v is StringName:
		return JSON.stringify(String(v))
	if v is Array:
		var parts := PackedStringArray()
		for x: Variant in v:
			parts.append(stable_stringify(x))
		return "[" + ",".join(parts) + "]"
	if v is Dictionary:
		var d: Dictionary = v
		var keys: Array = d.keys()
		keys.sort()
		var parts := PackedStringArray()
		for k: String in keys:
			parts.append(JSON.stringify(k) + ":" + stable_stringify(d[k]))
		return "{" + ",".join(parts) + "}"
	push_error("stable_stringify: unexpected value")
	return "null"

## A short stable string that changes if anything in the plan changes.
static func hash_plan(plan: FloorPlan) -> String:
	var text := stable_stringify(plan_to_plain(plan))
	var h1 := 0x811c9dc5
	var h2 := 0x01000193 ^ text.length()
	for i in text.length():
		var c := text.unicode_at(i)
		h1 = M.imul(h1 ^ c, 16777619)
		h2 = (M.imul(h2 ^ c, 2246822519) + ((h2 & M.MASK32) >> 13)) & M.MASK32
	return "%08x%08x" % [h1 & M.MASK32, h2 & M.MASK32]

const ROOM_CHAR := {&"ward": "W", &"exam": "R", &"station": "N", &"closet": "C", &"atrium": "A", &"lobby": "L"}

const ASCII_LEGEND := "# void  . corridor  ^>v< stair (points uphill)  o atrium opening  E elevator landing  X entity start  " \
	+ "+ door (drawn on the room side)  W ward  R exam  N nurses station  C closet  A atrium  L lobby  " \
	+ "(neighbouring rooms of the same kind alternate upper/lower case)"

## A text map of one level, one character per cell, rows separated by newlines.
static func render_ascii(plan: FloorPlan, level: int) -> String:
	var w := plan.width
	var grid := PackedStringArray()
	grid.resize(w * plan.height)
	grid.fill("#")
	var rooms: Array[Room] = []
	for r in plan.rooms:
		if r.level == level:
			rooms.append(r)
	# Same-kind neighbours get opposite case, so packed rooms read as separate rooms.
	var lower := {}
	for r in rooms:
		var used_false := false
		var used_true := false
		for o in rooms:
			if o.id == r.id or o.kind != r.kind or not lower.has(o.id):
				continue
			var touch := o.x <= r.x + r.w and r.x <= o.x + o.w and o.y <= r.y + r.h and r.y <= o.y + o.h
			if touch:
				if lower[o.id] == true:
					used_true = true
				else:
					used_false = true
		lower[r.id] = used_false and not used_true
	for i in w * plan.height:
		var k: StringName = plan.cells[level][i]
		if k == CORRIDOR:
			grid[i] = "."
		elif k == ATRIUM_OPEN:
			grid[i] = "o"
	for r in rooms:
		var c: String = ROOM_CHAR[r.kind]
		if lower[r.id]:
			c = c.to_lower()
		for y in range(r.y, r.y + r.h):
			for x in range(r.x, r.x + r.w):
				grid[y * w + x] = c
	var arrow := {&"n": "^", &"e": ">", &"s": "v", &"w": "<"}
	for s in plan.stairs:
		for c in stair_cells(s):
			grid[c.y * w + c.x] = arrow[s.dir]
	for d in plan.doors:
		if d.level != level:
			continue
		# Draw on the room side; for room-to-room doors, on the later (inner) room.
		var ra := room_id_at(plan, level, d.ax, d.ay)
		var rb := room_id_at(plan, level, d.bx, d.by)
		var use_b := rb > ra
		grid[(d.by if use_b else d.ay) * w + (d.bx if use_b else d.ax)] = "+"
	if plan.landing.level == level:
		grid[plan.landing.y * w + plan.landing.x] = "E"
	if plan.entity_start.level == level:
		grid[plan.entity_start.y * w + plan.entity_start.x] = "X"
	var rows := PackedStringArray()
	for y in plan.height:
		rows.append("".join(grid.slice(y * w, (y + 1) * w)))
	return "\n".join(rows)
