# The Arboretum: a forest indoors, under a painted sky (North Star A2: "There are no walls to funnel anything,
# so the crew steers by landmarks and by sound, and sight lines break every few steps"). The first place that is
# not a building: there are no rooms and no corridors, only ground. Its resident, the Groundskeeper, hears
# (sim/hearing.gd), so every cell of ground has a surface with a voice (sim/noise.gd). Piece AR2.
#
# generate_arboretum(seed, depth) is a pure function of the seed and the depth, like the other places': the same
# floor on every machine. The plan is the usual grid (2 m cells, one level), read differently:
#   - thicket is wall: solid, opaque, never crossed (void cells inside the garden). It stands in clumps, each
#     at most 5 cells long either way and each with open ground all the way round it (a clump never touches
#     another clump, the hall's wall, the lift pavilion or a landmark's building, even at a corner). So nothing
#     is ever sealed and there is no corridor and no chokepoint: the open ground has no cell whose loss would
#     cut it in two, which is the same as saying every cell reaches the landing by two routes that share no
#     cell (tests/prop_arboretum.gd proves it floor by floor);
#   - everything else is open ground, every cell with one surface (the plan's `ground`, a Garden):
#       gravel  the main walk, a loop from the lift pavilion's apron past at least half the landmarks (each at
#               its gate, the cell beside its clearing on the side away from the middle) and back, the apron
#               and the pavilion's brick floor: the loud, straight way, and the only ground that shows in the dark;
#       moss    worn ground: every landmark's clearing, a desire line from every landmark on the walk to the
#               next (each 1.2 to 1.6 times the walk between the same two, so the quiet way always costs time),
#               and spurs to the landmarks off the walk. Where a spur crosses the walk the crossing is moss (a
#               dark gap in the pale line: `crossings`);
#       twig    a twig fall: 3 to 6 cells of litter round one of the floor's 4 to 7 dead trees, never within 3
#               cells of the landing;
#       litter  the rest. Two to four trunks stand in most litter cells (props(), drawn and made solid through
#               sim/furniture.gd), in the cells' corners, so a body always passes between any two open cells.
#   - landmarks: the lift pavilion (a brick room with one doorway, its lamp and a gravel apron) and 5 to 8
#     others drawn without repeats from nine kinds, at least 6 cells apart, each with one lamp post. The big
#     ones (greenhouse, bandstand, shed row, aviary, gate lodge) are a 3 x 3 clearing round a building cell;
#     the small ones (dry fountain, fallen statue, rose arch, sundial) a 2 x 2 clearing round a piece where its
#     four cells meet.
#   - hides (hides(), listed through sim/hides.gd): sheds, the greenhouse's benches, the bandstand's underside
#     against their buildings, and hollow logs against the thicket, 8 to 14 a floor, spread out.
#   - one level, no stairs. The Groundskeeper starts at the landmark farthest from the landing by walking.
# A floor is made in tries: the sites, the walk and the moss are laid on bare ground first (with their length
# rules checked), then the thicket is grown in what is left. A try that cannot meet a rule is thrown away and
# the next try's draws are used (Rng "arboretum:<seed>:<depth>:<try>"), so every floor returned keeps every rule.
# Whole-number maths on cells and centimetres; no engine randomness.
extends RefCounted

@warning_ignore_start("integer_division")

const Floor = preload("res://sim/floor.gd")
const Noises = preload("res://sim/noise.gd")
const Playroom = preload("res://sim/playroom.gd")
const Rng = preload("res://sim/rng.gd")

const PLACE := &"arboretum"
## The grid, in cells, and the garden inside the hall's wall (rows 0 and 1 are behind the lift pavilion).
const W := 34
const H := 34
const X0 := 1
const X1 := W - 2
const Y0 := 2
const Y1 := H - 2
const CM := 200
## Landmarks besides the pavilion, their least spacing (cells between clearings), thicket's share of the garden.
const LANDMARKS_MIN := 5
const LANDMARKS_MAX := 8
const SPACING := 6
const THICKET_SHARE := 0.35
## A clump is at most this long either way.
const CLUMP_MAX := 5
## The moss way between two neighbours on the walk is this many times the walk between them.
const MOSS_MIN := 1.2
const MOSS_MAX := 1.6
## What a desire line is lengthened to: about this many times the walk's leg beside it (the low end of the band:
## the worn lines take enough of the garden as it is).
const MOSS_AIM := 1.25
const DEAD_MIN := 4
const DEAD_MAX := 7
const FALL_MIN := 3
const FALL_MAX := 6
## No twig fall, hide or dead tree within this many cells of the landing.
const LANDING_CLEAR := 3
const HIDES_MIN := 8
const HIDES_MAX := 14
const TRIES := 240
## Trunks: a litter cell has some with this chance, 2 to 4 of them, each this far from the cell's middle on
## both axes (cm), TRUNK across.
const TRUNK_CHANCE := 0.8
const TRUNK_OFF_MIN := 56
const TRUNK_OFF_MAX := 82
const TRUNK := 30

## The kinds: [kind, the name on the lift's map plate, clearing size]. Big ones stand round a building cell.
const KINDS: Array = [
	[&"greenhouse", "THE GREENHOUSE", 3], [&"bandstand", "THE BANDSTAND", 3], [&"sheds", "THE SHED ROW", 3],
	[&"aviary", "THE AVIARY", 3], [&"lodge", "THE GATE LODGE", 3],
	[&"fountain", "THE DRY FOUNTAIN", 2], [&"statue", "THE FALLEN STATUE", 2], [&"arch", "THE ROSE ARCH", 2],
	[&"sundial", "THE SUNDIAL", 2],
]
## Hide kinds: [holds, eye height cm, the gap's half-angle degrees, the inside spot's distance from the wall
## or thicket edge it stands against cm].
const HIDE_SPEC := {
	&"shed": [1, 150, 20, 32],
	&"bench": [1, 30, 60, 32],
	&"under": [2, 30, 60, 27],
	&"log": [1, 25, 35, 35],
}
const FRONT_REACH := 70
const DIRS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
const DIR_NAMES: Array[StringName] = [&"n", &"e", &"s", &"w"]

## The tests' deliberate breaks (tests/prop_arboretum.gd): "any_thicket" lets clumps touch each other and the
## wall, in lines of any length; "twig_on_moss" puts a twig fall on the moss.
static var test_break := ""

class Landmark extends RefCounted:
	var id: int
	var kind: StringName
	var name: String
	## Its clearing, in cells (the pavilion's is its apron).
	var x: int
	var y: int
	var w: int
	var h: int
	## The main walk passes it, at its gate: the walk's one cell beside its clearing (-1 off the walk).
	var on_walk: bool = false
	var gate: int = -1
	## Its building's cell (a big landmark's middle), or -1.
	var building: int = -1
	## Its lamp, cm (x world x, y world z), and whether the lamp is a post standing on the ground.
	var lamp: Vector2i
	var lamp_post: bool = true
	## A landmark on the walk: its doorstep, the moss cell beside its clearing (the pavilion's apron) where its
	## worn lines start and end, as the walk's legs do at its gate. Else -1.
	var step: int = -1

	func cells() -> PackedInt32Array:
		var out := PackedInt32Array()
		for cy in range(y, y + h):
			for cx in range(x, x + w):
				if cy * W + cx != building:
					out.append(cy * W + cx)
		return out

class DeadTree extends RefCounted:
	var id: int
	## The cell it stands in, where (cm), and its twig fall's cells (its own first).
	var cell: int
	var at: Vector2i
	var fall: PackedInt32Array

## The floor's ground (a Noises.Ground: one surface a cell) and everything the garden is made of.
class Garden extends Noises.Ground:
	var landmarks: Array[Landmark] = []
	var dead: Array[DeadTree] = []
	## The main walk, cell by cell in order round the loop (crossings included; clearings not).
	var walk: PackedInt32Array = PackedInt32Array()
	## Where a moss spur crosses the walk.
	var crossings: PackedInt32Array = PackedInt32Array()
	## 1 where a cell is thicket.
	var thicket: PackedByteArray = PackedByteArray()
	## 1 where a worn line runs: the desire lines, the spurs, the doorsteps and the moss clearings.
	var worn: PackedByteArray = PackedByteArray()
	## Which try made it.
	var attempt: int = 0
	## The pavilion's doorway: the room cell inside it and the apron cell outside.
	var door_in: int = -1
	var door_out: int = -1

	func plain() -> Dictionary:
		var lm: Array = []
		for l in landmarks:
			lm.append({"id": l.id, "kind": String(l.kind), "x": l.x, "y": l.y, "w": l.w, "h": l.h, "onWalk": l.on_walk,
				"building": l.building, "lamp": [l.lamp.x, l.lamp.y], "step": l.step, "gate": l.gate})
		var dt: Array = []
		for d in dead:
			dt.append({"id": d.id, "cell": d.cell, "at": [d.at.x, d.at.y], "fall": Array(d.fall)})
		return {"cells": Array(cells), "falls": Array(falls), "landmarks": lm, "dead": dt, "walk": Array(walk),
			"crossings": Array(crossings), "thicket": Array(thicket), "worn": Array(worn), "attempt": attempt}

## The garden of an Arboretum plan (null for any other).
static func garden_of(plan: Floor.FloorPlan) -> Garden:
	return plan.ground as Garden if plan != null else null

## What tests/reference/arboretum_hashes.json stores for a floor: the plan and its garden.
static func floor_hash(plan: Floor.FloorPlan) -> String:
	return Playroom.hash_plain({"plan": Floor.plan_to_plain(plan), "garden": garden_of(plan).plain()})

# ---------------------------------------------------------------------------------------------
# The generator.

## One try's working state.
class Build extends RefCounted:
	var rng: Rng
	var g: Garden
	var lx: int
	## 1: outside the garden, the pavilion's room, or a building.
	var blocked: PackedByteArray
	## The landmark whose clearing a cell is in, and whose clearing or ring (one cell round it), else -1.
	var clear_id: PackedInt32Array
	var zone_id: PackedInt32Array

	## Whether cell `c` is beside (four ways) the clearing of landmark `id`.
	func clear_id_beside(c: int, id: int) -> bool:
		for d: Vector2i in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
			if clear_id[(c / W + d.y) * W + c % W + d.x] == id:
				return true
		return false
	var walk: PackedByteArray
	var moss: PackedByteArray
	## The walk's stops in loop order (landmark ids, the pavilion first), and the steps of each leg.
	var stops: PackedInt32Array
	var legs: PackedInt32Array
	## Per stop, the two ways on from its gate and from its doorstep: [kept for the leg from the stop before,
	## kept for the leg to the stop after].
	var keep_walk: PackedInt32Array
	var keep_moss: PackedInt32Array

## Twice the middle of the garden (a little below centre: the pavilion is at the top), in cells.
const MID2 := Vector2i(X0 + X1 + 1, Y0 + Y1 + 3)

## A number that grows with the angle of (dx, dy) round the circle, made with one division (no libm, so it is
## the same on every machine).
static func _turn(dx: int, dy: int) -> float:
	var s := absi(dx) + absi(dy)
	if s == 0:
		return 0.0
	var a := float(dx) / float(s)
	return 3.0 + a if dy < 0 else 1.0 - a

static func _in_garden(x: int, y: int) -> bool:
	return x >= X0 and x <= X1 and y >= Y0 and y <= Y1

## THE Arboretum of a seed and a depth.
static func generate_arboretum(seed: String, depth: int) -> Floor.FloorPlan:
	for attempt in TRIES:
		var b := _try(seed, depth, attempt)
		if b != null:
			return _plan(seed, depth, b)
	push_error("arboretum %s/%d: no try kept every rule" % [seed, depth])
	return null

static func _try(seed: String, depth: int, attempt: int) -> Build:
	var b := Build.new()
	b.rng = Rng.make_rng("arboretum:%s:%d:%d" % [seed, depth, attempt])
	b.g = Garden.new()
	b.g.width = W
	b.g.height = H
	b.g.cell_size = 2.0
	b.g.cells.resize(W * H)
	b.g.falls.resize(W * H)
	b.g.falls.fill(-1)
	b.g.thicket.resize(W * H)
	b.g.attempt = attempt
	b.blocked = PackedByteArray()
	b.blocked.resize(W * H)
	b.clear_id = PackedInt32Array()
	b.clear_id.resize(W * H)
	b.clear_id.fill(-1)
	b.zone_id = PackedInt32Array()
	b.zone_id.resize(W * H)
	b.zone_id.fill(-1)
	b.walk = PackedByteArray()
	b.walk.resize(W * H)
	b.moss = PackedByteArray()
	b.moss.resize(W * H)
	for y in H:
		for x in W:
			if not _in_garden(x, y):
				b.blocked[y * W + x] = 1
	if not _sites(b):
		return _fail("sites")
	if not _lay_walk(b):
		return _fail("walk")
	if not _lay_moss(b):
		return _fail("moss")
	if not _spurs(b):
		return _fail("spurs")
	if not _lengths_hold(b):
		return _fail("lengths")
	_grow_thicket(b)
	_surfaces(b)
	if not _dead_trees(b):
		return _fail("dead trees")
	return b

## Why tries were thrown away, {stage: count}, since the program started (for the tests' notes).
static var thrown := {}

static func _fail(stage: String) -> Build:
	thrown[stage] = int(thrown.get(stage, 0)) + 1
	return null

# ---- Sites.

static func _claim(b: Build, l: Landmark) -> void:
	for cy in range(l.y - 1, l.y + l.h + 1):
		for cx in range(l.x - 1, l.x + l.w + 1):
			if cx < 0 or cy < 0 or cx >= W or cy >= H:
				continue
			var i := cy * W + cx
			if b.zone_id[i] < 0:
				b.zone_id[i] = l.id
			if cx >= l.x and cx < l.x + l.w and cy >= l.y and cy < l.y + l.h:
				b.clear_id[i] = l.id
	if l.building >= 0:
		b.blocked[l.building] = 1
		b.clear_id[l.building] = -1

## Cells between two clearings (0 when they touch or overlap).
static func _gap(a: Landmark, x: int, y: int, w: int, h: int) -> int:
	var dx := maxi(0, maxi(a.x - (x + w), x - (a.x + a.w)))
	var dy := maxi(0, maxi(a.y - (y + h), y - (a.y + a.h)))
	return maxi(dx, dy)

static func _sites(b: Build) -> bool:
	var rng := b.rng
	# The pavilion: a room three cells wide and two deep at the top, the landing in its middle back cell, one
	# doorway in the middle of its front; its apron three by two in front of that.
	b.lx = W / 2 + rng.int_in(-5, 5)
	var pav := Landmark.new()
	pav.id = 0
	pav.kind = &"pavilion"
	pav.name = "THE LIFT"
	pav.x = b.lx - 1
	pav.y = Y0 + 2
	pav.w = 3
	pav.h = 2
	pav.on_walk = true
	pav.lamp = Vector2i(b.lx * CM + CM / 2, (Y0 + 2) * CM)
	pav.lamp_post = false
	b.g.landmarks.append(pav)
	for cy in range(Y0, Y0 + 2):
		for cx in range(b.lx - 1, b.lx + 2):
			b.blocked[cy * W + cx] = 1
	b.g.door_in = (Y0 + 1) * W + b.lx
	b.g.door_out = (Y0 + 2) * W + b.lx
	_claim(b, pav)
	# The room's own ring belongs to the pavilion too.
	for cy in range(Y0, Y0 + 2):
		for cx in range(b.lx - 2, b.lx + 3):
			if b.zone_id[cy * W + cx] < 0:
				b.zone_id[cy * W + cx] = 0
	# The others: kinds without repeats, sites by rejection.
	var kinds: Array = KINDS.duplicate()
	for i in range(kinds.size() - 1, 0, -1):
		var j := rng.int_in(0, i)
		var tmp: Variant = kinds[i]
		kinds[i] = kinds[j]
		kinds[j] = tmp
	var n := rng.int_in(LANDMARKS_MIN, LANDMARKS_MAX)
	for k in n:
		var spec: Array = kinds[k]
		var size: int = spec[2]
		var placed := false
		for _t in 300:
			var x := rng.int_in(X0 + 2, X1 - size - 1)
			var y := rng.int_in(Y0 + 2, Y1 - size - 1)
			var ok := true
			for a in b.g.landmarks:
				# (The pavilion counts with its room.)
				var ay := a.y - 2 if a.id == 0 else a.y
				var ah := a.h + 2 if a.id == 0 else a.h
				var probe := Landmark.new()
				probe.x = a.x
				probe.y = ay
				probe.w = a.w
				probe.h = ah
				if _gap(probe, x, y, size, size) < SPACING:
					ok = false
					break
			if not ok:
				continue
			var l := Landmark.new()
			l.id = b.g.landmarks.size()
			l.kind = spec[0]
			l.name = spec[1]
			l.x = x
			l.y = y
			l.w = size
			l.h = size
			if size == 3:
				l.building = (y + 1) * W + x + 1
				# The lamp post stands off a corner of the building, by the seed.
				var cx := rng.int_in(0, 1)
				var cz := rng.int_in(0, 1)
				l.lamp = Vector2i((x + 1 + cx) * CM + (30 if cx == 1 else -30), (y + 1 + cz) * CM + (30 if cz == 1 else -30))
			else:
				var cx := rng.int_in(0, 1)
				var cz := rng.int_in(0, 1)
				l.lamp = Vector2i((x + cx * 2) * CM + (-30 if cx == 1 else 30), (y + cz * 2) * CM + (-30 if cz == 1 else 30))
			b.g.landmarks.append(l)
			_claim(b, l)
			placed = true
			break
		if not placed:
			# No room for this one: the floor has those placed so far, if they are enough.
			return b.g.landmarks.size() - 1 >= LANDMARKS_MIN
	return true

# ---- Breadth-first walks over cells.

## The shortest way from any of `from` to the first cell with `goal` set, through cells with `ok` set (the goal
## cells too), trying the four ways in `order`. With `cross` (the walk's cells that may be stepped over in a
## straight line: 1), a step may jump one such cell. The cells in order, `from`'s first; empty when there is none.
static func _bfs(from: PackedInt32Array, ok: PackedByteArray, goal: PackedByteArray, order: Array, cross: PackedByteArray = PackedByteArray()) -> PackedInt32Array:
	var prev := PackedInt32Array()
	prev.resize(W * H)
	prev.fill(-2)
	var queue := PackedInt32Array()
	queue.resize(W * H)
	var tail := 0
	for f in from:
		if prev[f] == -2:
			prev[f] = -1
			queue[tail] = f
			tail += 1
	var head := 0
	var found := -1
	while head < tail and found < 0:
		var cur := queue[head]
		head += 1
		if goal[cur] == 1:
			found = cur
			break
		var cx := cur % W
		var cy := cur / W
		for d: Vector2i in order:
			var nx := cx + d.x
			var ny := cy + d.y
			if nx < 0 or ny < 0 or nx >= W or ny >= H:
				continue
			var ni := ny * W + nx
			if not cross.is_empty() and cross[ni] == 1:
				# Straight over the walk: the cell beyond.
				var jx := nx + d.x
				var jy := ny + d.y
				if jx < 0 or jy < 0 or jx >= W or jy >= H:
					continue
				var ji := jy * W + jx
				if prev[ji] == -2 and ok[ji] == 1:
					prev[ji] = cur
					queue[tail] = ji
					tail += 1
				continue
			if prev[ni] != -2 or ok[ni] == 0:
				continue
			prev[ni] = cur
			queue[tail] = ni
			tail += 1
	var out := PackedInt32Array()
	if found < 0:
		return out
	var at := found
	while at >= 0:
		out.append(at)
		var p := prev[at]
		if p >= 0 and absi(p % W - at % W) + absi(p / W - at / W) == 2:
			# A jump: the walk cell between.
			out.append((p + at) / 2)
		at = p
	out.reverse()
	return out

static func _shuffled_dirs(rng: Rng) -> Array:
	var order: Array = DIRS.duplicate()
	for i in range(order.size() - 1, 0, -1):
		var j := rng.int_in(0, i)
		var tmp: Variant = order[i]
		order[i] = order[j]
		order[j] = tmp
	return order

## Steps from any of `from` to every cell through cells with `ok` set (-1: not reached).
static func _dist(from: PackedInt32Array, ok: PackedByteArray) -> PackedInt32Array:
	var dist := PackedInt32Array()
	dist.resize(W * H)
	dist.fill(-1)
	var queue := PackedInt32Array()
	queue.resize(W * H)
	var tail := 0
	for f in from:
		if dist[f] < 0:
			dist[f] = 0
			queue[tail] = f
			tail += 1
	var head := 0
	while head < tail:
		var cur := queue[head]
		head += 1
		var cx := cur % W
		var cy := cur / W
		for d in DIRS:
			var nx := cx + d.x
			var ny := cy + d.y
			if nx < 0 or ny < 0 or nx >= W or ny >= H:
				continue
			var ni := ny * W + nx
			if dist[ni] >= 0 or ok[ni] == 0:
				continue
			dist[ni] = dist[cur] + 1
			queue[tail] = ni
			tail += 1
	return dist

# ---- The main walk.

static func _lay_walk(b: Build) -> bool:
	var rng := b.rng
	var lms := b.g.landmarks
	var total := lms.size()
	# The stops: the pavilion and at least half the landmarks, the ones furthest from the middle (so the walk
	# runs round the garden and the rest lie inside it where they can), in order round the middle.
	var others: Array = []
	for i in range(1, total):
		var l := lms[i]
		var dx := 2 * l.x + l.w - MID2.x
		var dy := 2 * l.y + l.h - MID2.y
		others.append([-(dx * dx + dy * dy), i])
	others.sort()
	var want := (total + 1) / 2
	var chosen: Array = [0]
	for k in want:
		chosen.append(others[k][1])
		lms[int(others[k][1])].on_walk = true
	var by_angle: Array = []
	for id: int in chosen:
		var l := lms[id]
		by_angle.append([_turn(2 * l.x + l.w - MID2.x, 2 * l.y + l.h - MID2.y), id])
	by_angle.sort()
	var start := 0
	for k in by_angle.size():
		if int(by_angle[k][1]) == 0:
			start = k
	b.stops = PackedInt32Array()
	for k in by_angle.size():
		b.stops.append(int(by_angle[(start + k) % by_angle.size()][1]))
	# Each stop has a gate and a doorstep, both cells beside its clearing at the end of one of its sides: the
	# gate off the corner furthest from the middle of the garden (the walk passes it there, on the outside),
	# the doorstep off the corner nearest the middle (the worn lines start there, on the inside). The pavilion's
	# are in front of the two ends of its apron. No other cell of the walk, and no other cell of a worn line, is
	# beside any clearing: so the way between two landmarks is always one step onto a gate (or a doorstep), the
	# legs (or lines) between, and one step off.
	var beside := _beside(b)
	for id in b.stops:
		var l := lms[id]
		if id == 0:
			# Beside the two ends of the apron's front row: the gate to the left, the doorstep to the right.
			l.gate = (l.y + l.h - 1) * W + l.x - 1
			l.step = (l.y + l.h - 1) * W + l.x + l.w
		else:
			l.gate = _corner_cell(b, l, beside, true, -1)
			l.step = _corner_cell(b, l, beside, false, l.gate)
		if l.gate < 0 or l.step < 0 or b.blocked[l.gate] == 1 or b.blocked[l.step] == 1:
			_fail("walk: no gate")
			return false
	for id in b.stops:
		b.walk[lms[id].gate] = 1
	# Each gate and doorstep has two ways on. One is kept for the leg (or line) from the stop before and one for
	# the leg to the stop after, whichever pairing is the shorter, so legs and lines never have to cross.
	var n_stops := b.stops.size()
	b.keep_walk = PackedInt32Array()
	b.keep_moss = PackedInt32Array()
	for k in n_stops:
		var l := lms[b.stops[k]]
		var before := lms[b.stops[(k + n_stops - 1) % n_stops]]
		var after := lms[b.stops[(k + 1) % n_stops]]
		for moss_side: bool in [false, true]:
			var cell := l.step if moss_side else l.gate
			var ways := PackedInt32Array()
			for d in DIRS:
				var nx := cell % W + d.x
				var ny := cell / W + d.y
				var ni := ny * W + nx
				if _in_garden(nx, ny) and b.blocked[ni] == 0 and b.clear_id[ni] < 0 and beside[ni] == 0:
					ways.append(ni)
			if ways.size() < 2:
				_fail("walk: no gate")
				return false
			var to_before := before.step if moss_side else before.gate
			var to_after := after.step if moss_side else after.gate
			# (Each way goes to the stop it points at more: the sum of the two ways' steps toward their stops.)
			var straight := _toward(cell, ways[0], to_before) + _toward(cell, ways[1], to_after)
			var swapped := _toward(cell, ways[1], to_before) + _toward(cell, ways[0], to_after)
			var w_before := ways[0] if straight >= swapped else ways[1]
			var w_after := ways[1] if straight >= swapped else ways[0]
			# [the way kept for the leg from the stop before, the way kept for the leg to the stop after]
			if moss_side:
				b.keep_moss.append(w_before)
				b.keep_moss.append(w_after)
			else:
				b.keep_walk.append(w_before)
				b.keep_walk.append(w_after)
	# A leg from each gate to the next, never side by side with the walk already laid (so it has no short cuts).
	b.legs = PackedInt32Array()
	b.g.walk.append(lms[0].gate)
	for k in b.stops.size():
		var a := lms[b.stops[k]]
		var z := lms[b.stops[(k + 1) % b.stops.size()]]
		var ok := PackedByteArray()
		ok.resize(W * H)
		var goal := PackedByteArray()
		goal.resize(W * H)
		var gates := PackedInt32Array()
		for id in b.stops:
			gates.append(lms[id].gate)
		var guard := _guard(gates, b.keep_walk, b.keep_walk[k * 2 + 1], b.keep_walk[((k + 1) % n_stops) * 2])
		for i in W * H:
			if b.blocked[i] == 1 or b.clear_id[i] >= 0 or b.walk[i] == 1 or beside[i] == 1 or guard[i] == 1:
				continue
			# (The ground round every doorstep, two cells each way, is kept for the worn lines: the walk passes a
			# landmark on its far side and never cuts its doorstep off from the middle of the garden.)
			var kept := false
			for id in b.stops:
				var st := lms[id].step
				kept = kept or maxi(absi(i % W - st % W), absi(i / W - st / W)) <= 2
			if kept or _touches(b.walk, i, a.gate, z.gate):
				continue
			ok[i] = 1
		ok[z.gate] = 1
		goal[z.gate] = 1
		var path := _bfs(PackedInt32Array([a.gate]), ok, goal, _shuffled_dirs(rng))
		if path.size() < 3:
			_fail("walk: leg %d of %d" % [k, b.stops.size()])
			return false
		b.legs.append(path.size() - 1)
		for c in path:
			if b.g.walk.find(c) < 0:
				b.g.walk.append(c)
			b.walk[c] = 1
	return true

## A landmark's gate (`far`) or doorstep: a cell beside its clearing at the end of a side, off the corner
## furthest from (or nearest) the middle of the garden that has one whose two ways on are open ground beside
## nothing. Not `but`. -1 for none.
static func _corner_cell(b: Build, l: Landmark, beside: PackedByteArray, far: bool, but: int) -> int:
	var options: Array = []   # [key, cell]
	for cx: int in [l.x, l.x + l.w - 1]:
		for cy: int in [l.y, l.y + l.h - 1]:
			var sx := -1 if cx == l.x else 1
			var sy := -1 if cy == l.y else 1
			for cell: Vector2i in [Vector2i(cx, cy + sy), Vector2i(cx + sx, cy)]:
				var i := cell.y * W + cell.x
				if i == but or not _in_garden(cell.x, cell.y) or b.blocked[i] == 1 or b.clear_id[i] >= 0:
					continue
				var ways := 0
				for d in DIRS:
					var nx := cell.x + d.x
					var ny := cell.y + d.y
					var ni := ny * W + nx
					if _in_garden(nx, ny) and b.blocked[ni] == 0 and b.clear_id[ni] < 0 and beside[ni] == 0:
						ways += 1
				if ways < 2:
					continue
				var dx := 2 * cell.x + 1 - MID2.x
				var dy := 2 * cell.y + 1 - MID2.y
				var dd := dx * dx + dy * dy
				options.append([-dd if far else dd, i])
	if options.is_empty():
		return -1
	options.sort()
	return int(options[0][1])

## The ground kept clear round the ways on from the stops' gates (or doorsteps): every cell touching a way,
## even at a corner, and every cell touching the cell beyond it. `mine_a` and `mine_z`, the two ways the leg
## being laid uses, are left out, so a leg leaves and arrives straight and never shuts another leg's way.
static func _guard(cells: PackedInt32Array, keep: PackedInt32Array, mine_a: int, mine_z: int) -> PackedByteArray:
	var guard := PackedByteArray()
	guard.resize(W * H)
	for j in cells.size():
		for side in 2:
			var way := keep[j * 2 + side]
			if way == mine_a or way == mine_z:
				continue
			var beyond := way + (way - cells[j])
			for c: int in [way, beyond]:
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						var nx := c % W + dx
						var ny := c / W + dy
						if nx >= 0 and ny >= 0 and nx < W and ny < H:
							guard[ny * W + nx] = 1
	guard[mine_a] = 0
	guard[mine_z] = 0
	return guard

## How far the step from `cell` to `way` goes toward `target`: the step's direction times the cells to go.
static func _toward(cell: int, way: int, target: int) -> int:
	return (way % W - cell % W) * (target % W - cell % W) + (way / W - cell / W) * (target / W - cell / W)

## 1 where a cell is beside a clearing (four ways) and not in one.
static func _beside(b: Build) -> PackedByteArray:
	var beside := PackedByteArray()
	beside.resize(W * H)
	for l in b.g.landmarks:
		for c in l.cells():
			for d in DIRS:
				var ni := (c / W + d.y) * W + c % W + d.x
				if b.clear_id[ni] < 0:
					beside[ni] = 1
	return beside

## Whether cell `c` has a neighbour (four ways) with `mask` set, other than `but_a` and `but_b`.
static func _touches(mask: PackedByteArray, c: int, but_a: int = -1, but_b: int = -1) -> bool:
	for d in DIRS:
		var nx := c % W + d.x
		var ny := c / W + d.y
		if nx < 0 or ny < 0 or nx >= W or ny >= H:
			continue
		var ni := ny * W + nx
		if mask[ni] == 1 and ni != but_a and ni != but_b:
			return true
	return false

# ---- The moss.

## The walk's cells a worn line may step straight over: where the walk runs straight, clear of every clearing's
## ring, and is not a crossing already.
static func _crossable(b: Build) -> PackedByteArray:
	var cross := PackedByteArray()
	cross.resize(W * H)
	for i in W * H:
		if b.walk[i] == 0 or b.zone_id[i] >= 0 or b.g.crossings.find(i) >= 0:
			continue
		var ew := b.walk[i - 1] == 1 and b.walk[i + 1] == 1 and b.walk[i - W] == 0 and b.walk[i + W] == 0
		var ns := b.walk[i - W] == 1 and b.walk[i + W] == 1 and b.walk[i - 1] == 0 and b.walk[i + 1] == 0
		if ew or ns:
			cross[i] = 1
	return cross

static func _near_mask(mask: PackedByteArray) -> PackedByteArray:
	var near := PackedByteArray()
	near.resize(W * H)
	for i in W * H:
		if mask[i] == 0:
			continue
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var nx := i % W + dx
				var ny := i / W + dy
				if nx >= 0 and ny >= 0 and nx < W and ny < H:
					near[ny * W + nx] = 1
	return near

static func _lay_moss(b: Build) -> bool:
	var rng := b.rng
	var lms := b.g.landmarks
	# Every landmark's clearing but the pavilion's apron is worn ground.
	for l in lms:
		if l.id != 0:
			for c in l.cells():
				b.moss[c] = 1
	var free := PackedByteArray()
	free.resize(W * H)
	for i in W * H:
		if b.blocked[i] == 0 and b.walk[i] == 0 and b.clear_id[i] < 0:
			free[i] = 1
	var beside := _beside(b)
	for id in b.stops:
		b.moss[lms[id].step] = 1
	# A desire line from each stop's doorstep to the next's: first every line by its shortest way, then each
	# lengthened with bows to about 1.4 times the walk's leg beside it.
	var n_stops := b.stops.size()
	var lines: Array = []
	for k in n_stops:
		var a := lms[b.stops[k]]
		var z := lms[b.stops[(k + 1) % n_stops]]
		var ok := PackedByteArray()
		ok.resize(W * H)
		var goal := PackedByteArray()
		goal.resize(W * H)
		var doorsteps := PackedInt32Array()
		for id in b.stops:
			doorsteps.append(lms[id].step)
		# This line leaves by the way kept for it and arrives by the way kept for it, clear of every other.
		var guard := _guard(doorsteps, b.keep_moss, b.keep_moss[k * 2 + 1], b.keep_moss[((k + 1) % n_stops) * 2])
		for i in W * H:
			if free[i] == 0 or beside[i] == 1 or guard[i] == 1:
				continue
			# Never side by side with worn ground already there, but the two doorsteps (corner to corner it may be).
			if _touches(b.moss, i, a.step, z.step):
				continue
			ok[i] = 1
		ok[a.step] = 1
		ok[z.step] = 1
		goal[z.step] = 1
		# Where the two doorsteps lie on different sides of the walk, the line steps straight over it (a crossing).
		var path := _bfs(PackedInt32Array([a.step]), ok, goal, _shuffled_dirs(rng), _crossable(b))
		if path.is_empty():
			_fail("moss: no way")
			return false
		if path.size() - 1 > int(floor(MOSS_MAX * b.legs[k] + 1e-9)):
			_fail("moss: too long")
			return false
		for c in path:
			b.moss[c] = 1
			if b.walk[c] == 1:
				b.g.crossings.append(c)
		lines.append(Array(path))
	var every := PackedInt32Array()
	for id in b.stops:
		every.append(lms[id].step)
	var all_ways := _guard(every, b.keep_moss, 0, 0)
	for k in n_stops:
		var leg := b.legs[k]
		# The line's band: with these, every pair of stops keeps the 1.2 to 1.6 rule (each way is one step onto
		# a doorstep or a gate at either end, and the legs or lines between).
		var lo := int(ceil(MOSS_MIN * leg + 0.4 - 1e-9))
		var hi := int(floor(MOSS_MAX * leg + 1e-9))
		var cells: Array = lines[k]
		var have := cells.size() - 1
		var aim := clampi(int(round(MOSS_AIM * leg)), lo, hi)
		# Lengthening: a cell in a straight run is taken out and the line bows round it on one side (two steps
		# more). The bow touches worn ground only where it leaves and rejoins its line, so there is no short cut
		# and the line's length is the moss way's length.
		var tries := 0
		while have < aim and tries < 900:
			tries += 1
			if cells.size() < 3:
				break
			var n := rng.int_in(1, cells.size() - 2)
			var u: int = cells[n - 1]
			var m: int = cells[n]
			var v: int = cells[n + 1]
			if b.walk[u] == 1 or b.walk[m] == 1 or b.walk[v] == 1 or v - m != m - u:
				continue
			var d := Vector2i(v % W - m % W, v / W - m / W)
			if absi(d.x) + absi(d.y) != 1:
				continue
			var side := Vector2i(-d.y, d.x) if rng.chance(0.5) else Vector2i(d.y, -d.x)
			var bow: Array[int] = []
			var fits := true
			for c: int in [u, m, v]:
				var nx := c % W + side.x
				var ny := c / W + side.y
				var ni := ny * W + nx
				if not _in_garden(nx, ny) or free[ni] == 0 or beside[ni] == 1 or b.moss[ni] == 1 or all_ways[ni] == 1:
					fits = false
					break
				bow.append(ni)
			if not fits:
				continue
			var friends: Array = [[u, bow[1]], [bow[0], bow[2]], [v, bow[1]]]
			for k2 in 3:
				for dd in DIRS:
					var q := (bow[k2] / W + dd.y) * W + bow[k2] % W + dd.x
					if q == m:
						continue
					if b.moss[q] == 1 and q != int(friends[k2][0]) and q != int(friends[k2][1]):
						fits = false
			if not fits:
				continue
			b.moss[m] = 0
			cells.remove_at(n)
			for k2 in 3:
				cells.insert(n + k2, bow[k2])
				b.moss[bow[k2]] = 1
			have += 2
		if have < lo:
			_fail("moss: too short")
			return false
	return true

## The landmarks off the walk: a moss clearing each, and a spur to the nearest moss, straight over the walk
## where it must.
static func _spurs(b: Build) -> bool:
	var lms := b.g.landmarks
	for l in lms:
		if l.on_walk:
			continue
		var ok := PackedByteArray()
		ok.resize(W * H)
		var goal := PackedByteArray()
		goal.resize(W * H)
		var cross := _crossable(b)
		var mine := {}
		for c in l.cells():
			mine[c] = true
		for i in W * H:
			if b.blocked[i] == 1:
				continue
			var zone := b.zone_id[i]
			if b.walk[i] == 1:
				continue
			if b.clear_id[i] >= 0 and b.clear_id[i] != l.id:
				continue
			if zone >= 0 and zone != l.id:
				continue
			ok[i] = 1
			# The spur ends at the first free cell that touches moss which is not its own clearing.
			if not mine.has(i) and b.moss[i] == 0:
				for d in DIRS:
					var ni := (i / W + d.y) * W + i % W + d.x
					if b.moss[ni] == 1 and not mine.has(ni):
						goal[i] = 1
		var path := _bfs(l.cells(), ok, goal, DIRS, cross)
		if path.is_empty():
			return false
		for c in path:
			if b.walk[c] == 1:
				b.g.crossings.append(c)
			b.moss[c] = 1
	return true

# ---- The length rules, checked on what was laid.

## Steps of the moss way between the clearings of landmarks a and z (the step onto each apron counted), or -1.
static func moss_steps(g: Garden, a: Landmark, z: Landmark) -> int:
	var ok := PackedByteArray()
	ok.resize(W * H)
	for i in W * H:
		if g.cells[i] == Noises.MOSS:
			ok[i] = 1
	return _between(a, z, ok)

## Steps of the walk between the clearings of landmarks a and z (crossings are part of the walk), or -1.
static func walk_steps(g: Garden, a: Landmark, z: Landmark) -> int:
	var ok := PackedByteArray()
	ok.resize(W * H)
	for i in W * H:
		if g.cells[i] == Noises.GRAVEL:
			ok[i] = 1
	for c in g.crossings:
		ok[c] = 1
	return _between(a, z, ok)

## Steps from clearing a to clearing z through cells with `ok` set; a clearing that is not itself `ok` is
## entered and left by one step each.
static func _between(a: Landmark, z: Landmark, ok: PackedByteArray) -> int:
	var from := PackedInt32Array()
	var extra := 0
	var ac := a.cells()
	if ok[ac[0]] == 1:
		from = ac
	else:
		extra += 1
		for c in ac:
			for d in DIRS:
				var ni := (c / W + d.y) * W + c % W + d.x
				if ok[ni] == 1 and from.find(ni) < 0:
					from.append(ni)
	if from.is_empty():
		return -1
	var dist := _dist(from, ok)
	var best := -1
	var zc := z.cells()
	var inside := ok[zc[0]] == 1
	for c in zc:
		if inside:
			if dist[c] >= 0 and (best < 0 or dist[c] < best):
				best = dist[c]
			continue
		for d in DIRS:
			var ni := (c / W + d.y) * W + c % W + d.x
			if ok[ni] == 1 and dist[ni] >= 0 and (best < 0 or dist[ni] + 1 < best):
				best = dist[ni] + 1
	return best + extra if best >= 0 else -1

static func _lengths_hold(b: Build) -> bool:
	_surfaces(b)
	var g := b.g
	for i in g.landmarks.size():
		for j in range(i + 1, g.landmarks.size()):
			var a := g.landmarks[i]
			var z := g.landmarks[j]
			var m := moss_steps(g, a, z)
			if m < 0:
				_fail("lengths: no moss way")
				return false
			if not (a.on_walk and z.on_walk):
				continue
			var w := walk_steps(g, a, z)
			if w <= 0 or m < MOSS_MIN * w - 1e-9 or m > MOSS_MAX * w + 1e-9:
				_fail("lengths: %s" % ("no walk" if w <= 0 else ("moss too short" if m < MOSS_MIN * w else "moss too long")))
				return false
	return true

# ---- Thicket.

static func _grow_thicket(b: Build) -> void:
	var rng := b.rng
	var g := b.g
	var garden_cells := (X1 - X0 + 1) * (Y1 - Y0 + 1)
	var want := int(THICKET_SHARE * garden_cells)
	var have := 0
	var loose := test_break == "any_thicket"
	# Big clumps first, then smaller ones into what is left.
	var passes: Array = [
		[[5, 4], [4, 5], [4, 4], [5, 3], [3, 5], [5, 5]], 500,
		[[4, 3], [3, 4], [3, 3], [4, 2], [2, 4]], 700,
		[[3, 2], [2, 3], [2, 2]], 900,
		[[2, 1], [1, 2], [1, 1]], 900,
	]
	for p in passes.size() / 2:
		var shapes: Array = passes[p * 2]
		var tries: int = passes[p * 2 + 1]
		for _t in tries:
			if have >= want:
				return
			var shape: Array = shapes[rng.int_in(0, shapes.size() - 1)]
			var w: int = shape[0]
			var h: int = shape[1]
			var x := rng.int_in(X0, X1 - w + 1)
			var y := rng.int_in(Y0, Y1 - h + 1)
			# An irregular clump: a rectangle with some corners bitten off.
			var cut := {}
			if w >= 2 and h >= 2:
				for corner: Vector2i in [Vector2i(0, 0), Vector2i(w - 1, 0), Vector2i(0, h - 1), Vector2i(w - 1, h - 1)]:
					if rng.chance(0.35):
						cut[corner] = true
			var cells := PackedInt32Array()
			for cy in h:
				for cx in w:
					if not cut.has(Vector2i(cx, cy)):
						cells.append((y + cy) * W + x + cx)
			if cells.is_empty():
				continue
			var fits := true
			var inside := {}
			for c in cells:
				inside[c] = true
				if b.blocked[c] == 1 or b.walk[c] == 1 or b.moss[c] == 1 or b.zone_id[c] >= 0 or g.thicket[c] == 1:
					fits = false
					break
			if not fits:
				continue
			if not loose:
				# Open ground all the way round it: no cell beside it, even at a corner, is thicket, wall or a building.
				for c in cells:
					for dy in range(-1, 2):
						for dx in range(-1, 2):
							var nx := c % W + dx
							var ny := c / W + dy
							var ni := ny * W + nx
							if inside.has(ni):
								continue
							if not _in_garden(nx, ny) or b.blocked[ni] == 1 or g.thicket[ni] == 1:
								fits = false
					if not fits:
						break
			if not fits:
				continue
			for c in cells:
				g.thicket[c] = 1
			have += cells.size()

# ---- Surfaces.

static func _surfaces(b: Build) -> void:
	var g := b.g
	g.worn = b.moss.duplicate()
	for i in W * H:
		var s := Noises.LITTER
		if b.blocked[i] == 1 or g.thicket[i] == 1:
			s = Noises.NONE
		elif b.moss[i] == 1:
			s = Noises.MOSS
		elif b.walk[i] == 1 or b.clear_id[i] == 0:
			s = Noises.GRAVEL
		g.cells[i] = s
		g.falls[i] = -1
	# The pavilion's brick floor is as loud as gravel.
	for cy in range(Y0, Y0 + 2):
		for cx in range(b.lx - 1, b.lx + 2):
			g.cells[cy * W + cx] = Noises.GRAVEL

# ---- Dead trees and their twig falls.

static func _dead_trees(b: Build) -> bool:
	var rng := b.rng
	var g := b.g
	var landing := Vector2i(b.lx, Y0)
	var want := rng.int_in(DEAD_MIN, DEAD_MAX)
	var on_moss := test_break == "twig_on_moss"
	var free := PackedByteArray()
	free.resize(W * H)
	var sites := PackedInt32Array()
	for i in W * H:
		var want_s := Noises.MOSS if on_moss else Noises.LITTER
		if g.cells[i] != want_s or (not on_moss and b.zone_id[i] >= 0):
			continue
		if maxi(absi(i % W - landing.x), absi(i / W - landing.y)) <= LANDING_CLEAR:
			continue
		free[i] = 1
		sites.append(i)
	var taken := PackedByteArray()
	taken.resize(W * H)
	for _t in 400:
		if g.dead.size() >= want or sites.is_empty():
			break
		var c := sites[rng.int_in(0, sites.size() - 1)]
		var far := true
		for d in g.dead:
			if maxi(absi(c % W - d.cell % W), absi(c / W - d.cell / W)) < 5:
				far = false
		if not far or taken[c] == 1:
			continue
		# The fall: the tree's own cell and litter beside it, never touching another fall.
		var size := rng.int_in(FALL_MIN, FALL_MAX)
		var fall := PackedInt32Array([c])
		var guard := 0
		while fall.size() < size and guard < 60:
			guard += 1
			var base := fall[rng.int_in(0, fall.size() - 1)]
			var d: Vector2i = DIRS[rng.int_in(0, 3)]
			var ni := (base / W + d.y) * W + base % W + d.x
			if free[ni] == 0 or taken[ni] == 1 or fall.find(ni) >= 0:
				continue
			fall.append(ni)
		if fall.size() < FALL_MIN:
			continue
		var dt := DeadTree.new()
		dt.id = g.dead.size()
		dt.cell = c
		# It stands in a corner of its cell, like any trunk.
		var ox := (1 if rng.chance(0.5) else -1) * 66
		var oz := (1 if rng.chance(0.5) else -1) * 66
		dt.at = Vector2i((c % W) * CM + CM / 2 + ox, (c / W) * CM + CM / 2 + oz)
		dt.fall = fall
		g.dead.append(dt)
		for f in fall:
			g.put(f % W, f / W, Noises.TWIG, dt.id)
			# No fall touches another.
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					taken[(f / W + dy) * W + f % W + dx] = 1
	return g.dead.size() >= DEAD_MIN

# ---- The plan.

static func _plan(seed: String, depth: int, b: Build) -> Floor.FloorPlan:
	var g := b.g
	var p := Floor.FloorPlan.new()
	p.place = PLACE
	p.seed = seed
	p.depth = depth
	p.width = W
	p.height = H
	p.cell_size = 2
	var l0: Array = []
	var l1: Array = []
	for i in W * H:
		l1.append(Floor.VOID)
		l0.append(Floor.VOID if (b.blocked[i] == 1 or g.thicket[i] == 1) else Floor.CORRIDOR)
	for cy in range(Y0, Y0 + 2):
		for cx in range(b.lx - 1, b.lx + 2):
			l0[cy * W + cx] = Floor.ROOM
	l0[Y0 * W + b.lx] = Floor.LANDING
	p.cells = [l0, l1]
	var room := Floor.Room.new()
	room.id = 0
	room.level = 0
	room.kind = &"lobby"
	room.x = b.lx - 1
	room.y = Y0
	room.w = 3
	room.h = 2
	p.rooms.append(room)
	p.doors.append(Floor.Door.make(0, b.lx, Y0 + 1, b.lx, Y0 + 2))
	p.landing = Floor.Pos.make(0, b.lx, Y0)
	p.ground = g
	# The Groundskeeper: at the landmark farthest from the landing by walking, on its cell nearest the lift.
	var dist := Floor.distances_from(p, p.landing)
	var far_cell := -1
	var far_d := -1
	for l in g.landmarks:
		if l.id == 0:
			continue
		var best := -1
		var best_d := 1 << 30
		for c in l.cells():
			var d := dist[c]
			if d >= 0 and d < best_d:
				best_d = d
				best = c
		if best >= 0 and best_d > far_d:
			far_d = best_d
			far_cell = best
	p.entity_start = Floor.Pos.make(0, far_cell % W, far_cell / W)
	return p

# ---------------------------------------------------------------------------------------------
# Hides (sim/hides.gd lists them).

static func _hide(list: Array[Playroom.Hide], kind: StringName, zone: int, edge_x: int, edge_y: int, gap: int) -> void:
	var spec: Array = HIDE_SPEC[kind]
	var d: Vector2i = DIRS[gap]
	var h := Playroom.Hide.new()
	h.id = list.size()
	h.zone = zone
	h.room = -1
	h.level = 0
	h.kind = kind
	h.capacity = spec[0]
	h.eye = spec[1]
	h.gap = DIR_NAMES[gap]
	h.gap_half = spec[2]
	h.gap_range = 0
	h.inside = Vector2i(edge_x + d.x * int(spec[3]), edge_y + d.y * int(spec[3]))
	h.front = Vector2i(h.inside.x + d.x * FRONT_REACH, h.inside.y + d.y * FRONT_REACH)
	list.append(h)

## Every hide on the floor, in id order: the landmarks' own (by landmark), then hollow logs against the
## thicket, spread out, to between HIDES_MIN and HIDES_MAX in all. A pure function of the plan.
static func hides(plan: Floor.FloorPlan) -> Array[Playroom.Hide]:
	var out: Array[Playroom.Hide] = []
	var g := garden_of(plan)
	if g == null:
		return out
	var rng := Rng.make_rng("arboretum-hides:%s:%d" % [plan.seed, plan.depth])
	var used := PackedInt32Array()
	for l in g.landmarks:
		if l.building < 0:
			continue
		var bx := l.building % W
		var by := l.building / W
		# Against the building's sides: [kind, how many sides].
		var kind := &""
		var count := 0
		match l.kind:
			&"greenhouse":
				kind = &"bench"
				count = 2
			&"bandstand":
				kind = &"under"
				count = 1
			&"sheds":
				kind = &"shed"
				count = 3
			&"lodge":
				kind = &"shed"
				count = 1
		var sides: Array = [0, 1, 2, 3]
		for i in range(3, 0, -1):
			var j := rng.int_in(0, i)
			var tmp: Variant = sides[i]
			sides[i] = sides[j]
			sides[j] = tmp
		for k in count:
			var side: int = sides[k]
			var d: Vector2i = DIRS[side]
			# The middle of that side's wall line.
			var ex := bx * CM + CM / 2 + d.x * (CM / 2)
			var ey := by * CM + CM / 2 + d.y * (CM / 2)
			_hide(out, kind, l.id, ex, ey, side)
			used.append((by + d.y) * W + bx + d.x)
	# Hollow logs: litter cells with thicket beside them, not near the landing, furthest from the hides so far.
	var want := clampi(rng.int_in(9, 12), HIDES_MIN, HIDES_MAX)
	var spots: Array = []   # [cell, side the thicket is on]
	for y in range(Y0, Y1 + 1):
		for x in range(X0, X1 + 1):
			var i := y * W + x
			if g.cells[i] != Noises.LITTER:
				continue
			if maxi(absi(x - plan.landing.x), absi(y - plan.landing.y)) <= LANDING_CLEAR:
				continue
			var near_mark := false
			for l in g.landmarks:
				if x >= l.x - 1 and x <= l.x + l.w and y >= l.y - 1 and y <= l.y + l.h:
					near_mark = true
			if near_mark:
				continue
			for side in 4:
				var d: Vector2i = DIRS[side]
				if g.thicket[(y + d.y) * W + x + d.x] == 1:
					spots.append([i, side])
					break
	while out.size() < want and not spots.is_empty():
		var best := -1
		var best_d := -1
		for n in spots.size():
			var c: int = spots[n][0]
			var nearest := 1 << 30
			for u in used:
				nearest = mini(nearest, absi(c % W - u % W) + absi(c / W - u / W))
			if nearest > best_d:
				best_d = nearest
				best = n
		if best_d < 3:
			break
		var cell: int = spots[best][0]
		var side: int = spots[best][1]
		var d: Vector2i = DIRS[side]
		# Against the thicket's edge, its gap facing away from it.
		var ex := (cell % W) * CM + CM / 2 + d.x * (CM / 2)
		var ey := (cell / W) * CM + CM / 2 + d.y * (CM / 2)
		_hide(out, &"log", -1, ex, ey, (side + 2) % 4)
		used.append(cell)
		spots.remove_at(best)
	return out

# ---------------------------------------------------------------------------------------------
# Props: what stands on the ground besides the hides (sim/furniture.gd makes them pieces).

## [kind, x cm, y cm, facing] for every prop, in order: each landmark's piece and lamp post, the dead trees, then
## the trunks cell by cell. A pure function of the plan.
static func props(plan: Floor.FloorPlan) -> Array:
	var out: Array = []
	var g := garden_of(plan)
	if g == null:
		return out
	for l in g.landmarks:
		if l.building < 0 and l.id != 0:
			# A small landmark's piece stands where its four cells meet.
			out.append([l.kind, (l.x + 1) * CM, (l.y + 1) * CM, &"s"])
		if l.lamp_post:
			out.append([&"lamp", l.lamp.x, l.lamp.y, &"s"])
	for d in g.dead:
		out.append([&"dead_tree", d.at.x, d.at.y, &"s"])
	var busy := {}
	for h in hides(plan):
		busy[(h.inside.y / CM) * W + h.inside.x / CM] = true
		busy[(h.front.y / CM) * W + h.front.x / CM] = true
	var rng := Rng.make_rng("arboretum-trunks:%s:%d" % [plan.seed, plan.depth])
	for y in range(Y0, Y1 + 1):
		for x in range(X0, X1 + 1):
			var i := y * W + x
			if g.cells[i] != Noises.LITTER:
				continue
			# Every litter cell draws the same numbers, so one cell's trunks never depend on another's.
			var has := rng.chance(TRUNK_CHANCE)
			var n := rng.int_in(2, 4)
			var first := rng.int_in(0, 3)
			var offs: Array = []
			for _k in 4:
				offs.append(Vector2i(rng.int_in(TRUNK_OFF_MIN, TRUNK_OFF_MAX), rng.int_in(TRUNK_OFF_MIN, TRUNK_OFF_MAX)))
			if not has or busy.has(i):
				continue
			for k in n:
				var corner := (first + k) % 4
				var sx := 1 if (corner == 1 or corner == 2) else -1
				var sz := 1 if corner >= 2 else -1
				var off: Vector2i = offs[k]
				out.append([&"trunk", x * CM + CM / 2 + sx * off.x, y * CM + CM / 2 + sz * off.y, &"s"])
	return out
