# The Arboretum's floors (sim/arboretum.gd; its place in sim/places.gd; hides through sim/hides.gd, trunks and
# landmark pieces through sim/furniture.gd; piece AR2). Proved here over seeded floors (800, 40 in the quick
# set), by the test's own walks over the plan:
#   1. Two routes, no line: the open ground is one piece with no cell whose loss would cut it (so every walkable
#      cell reaches the landing's apron by two routes that share no cell: Menger), no cell is a dead end, no run
#      of thicket is longer than 5 cells, and thicket is about a third of the garden.
#   2. Surfaces: every open cell has one; the walk is a closed loop of gravel from the pavilion's apron past at
#      least half the landmarks; a moss way joins every pair of landmarks and the landing; and between two
#      landmarks on the walk the moss way is 1.2 to 1.6 times the walk.
#   3. Landmarks: 6 to 9, no kind twice, at least 6 cells apart, each with its lamp at its clearing. Dead trees:
#      4 to 7, each with a twig fall of 3 to 6 cells; a twig fall is only ever on litter (never on a worn line,
#      the walk or a clearing), under its own dead tree, more than 3 cells from the landing.
#   4. Trunks stand only in litter cells, 2 to 4 to a cell, and never trap a body: a body walks the straight line
#      between the middles of any two neighbouring open cells, and stands on every hide's front spot.
#   5. Hides: 8 to 14, listed by sim/hides.gd, each against its building or the thicket with its spots on open
#      ground, none within 3 cells of the landing.
#   6. Same seed, same floor: generated twice it is the same, and every floor's hash (plan, garden, hides and
#      pieces) is the one stored in tests/reference/arboretum_hashes.json.
#   7. The car, the landing and the call work as on every floor: out through the pavilion's one doorway, the
#      call from the landing, the wait, boarding, the ride down.
#   8. The Groundskeeper starts at the landmark farthest from the landing by walking, listening.
#   9. The deck: the Arboretum is the fifth floor of the game's deck and is drawn from floor 6 like the others,
#      never twice running; a deck without it never has one.
#  10. Hiding, read for a blind resident, on a real floor: it comes to a hide it heard and takes whoever is
#      inside; a hide it did not hear is safe.
# Deliberate breaks (PROP_ARBORETUM_BREAK): any_thicket (clumps may touch, in lines of any length: 1 goes red),
# twig_on_moss (a twig fall on the moss: 3 goes red). PROP_ARBORETUM_RECORD=1 writes the hashes file.
extends RefCounted

@warning_ignore_start("integer_division")

const T = preload("res://tests/t.gd")
const Arboretum = preload("res://sim/arboretum.gd")
const Noises = preload("res://sim/noise.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Places = preload("res://sim/places.gd")
const Hides = preload("res://sim/hides.gd")
const Furniture = preload("res://sim/furniture.gd")
const Playroom = preload("res://sim/playroom.gd")
const Run = preload("res://sim/run.gd")
const Landing = preload("res://sim/landing.gd")
const Hearing = preload("res://sim/hearing.gd")
const HostRules = preload("res://net/host_rules.gd")
const M = preload("res://sim/jsmath.gd")

const QUICK_SEEDS := 40
const SEEDS := 800
const HASHES_PATH := "res://tests/reference/arboretum_hashes.json"
const DT := 0.05
const R := 0.3
const W := Arboretum.W
const H := Arboretum.H
const STEPS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]

static var _cache := {}

static func _apply_break() -> void:
	var b := OS.get_environment("PROP_ARBORETUM_BREAK")
	var was := Arboretum.test_break
	Arboretum.test_break = b if (b == "any_thicket" or b == "twig_on_moss") else ""
	if was != Arboretum.test_break:
		_cache = {}

static func key_of(i: int) -> String:
	return "seed-%d/%d" % [i, 5 + i % 4]

static func floor_of(i: int) -> Floor.FloorPlan:
	if not _cache.has(i):
		_cache[i] = Arboretum.generate_arboretum("seed-%d" % i, 5 + i % 4)
	return _cache[i]

static func count(t: T) -> int:
	return QUICK_SEEDS if t.quick else SEEDS

# ---------------------------------------------------------------------------------------------
# The test's own walks.

## Steps from the cells of `from` through cells with `ok` set (-1: not reached).
static func steps_from(from: PackedInt32Array, ok: PackedByteArray) -> PackedInt32Array:
	var dist := PackedInt32Array()
	dist.resize(W * H)
	dist.fill(-1)
	var queue := PackedInt32Array()
	for f in from:
		if dist[f] < 0:
			dist[f] = 0
			queue.append(f)
	var head := 0
	while head < queue.size():
		var cur := queue[head]
		head += 1
		for st in STEPS:
			var nx := cur % W + st.x
			var ny := cur / W + st.y
			if nx < 0 or ny < 0 or nx >= W or ny >= H:
				continue
			var ni := ny * W + nx
			if dist[ni] < 0 and ok[ni] == 1:
				dist[ni] = dist[cur] + 1
				queue.append(ni)
	return dist

## [cut cells (cells whose loss would cut the ground in two), pieces, the fewest open neighbours a cell has].
static func cuts(open: PackedByteArray) -> Array:
	var n := W * H
	var disc := PackedInt32Array()
	disc.resize(n)
	disc.fill(-1)
	var low := PackedInt32Array()
	low.resize(n)
	var parent := PackedInt32Array()
	parent.resize(n)
	parent.fill(-1)
	var it := PackedByteArray()
	it.resize(n)
	var art := PackedByteArray()
	art.resize(n)
	var timer := 0
	var pieces := 0
	var least := 4
	for root in n:
		if open[root] == 0:
			continue
		var deg := 0
		for st in STEPS:
			var nx := root % W + st.x
			var ny := root / W + st.y
			if nx >= 0 and ny >= 0 and nx < W and ny < H and open[ny * W + nx] == 1:
				deg += 1
		least = mini(least, deg)
		if disc[root] >= 0:
			continue
		pieces += 1
		var root_children := 0
		var stack := PackedInt32Array([root])
		disc[root] = timer
		low[root] = timer
		timer += 1
		while not stack.is_empty():
			var v := stack[stack.size() - 1]
			if it[v] < 4:
				var st: Vector2i = STEPS[it[v]]
				it[v] += 1
				var nx := v % W + st.x
				var ny := v / W + st.y
				if nx < 0 or ny < 0 or nx >= W or ny >= H:
					continue
				var u := ny * W + nx
				if open[u] == 0:
					continue
				if disc[u] < 0:
					parent[u] = v
					disc[u] = timer
					low[u] = timer
					timer += 1
					stack.append(u)
					if v == root:
						root_children += 1
				elif u != parent[v]:
					low[v] = mini(low[v], disc[u])
			else:
				stack.resize(stack.size() - 1)
				var p := parent[v]
				if p >= 0:
					low[p] = mini(low[p], low[v])
					if p != root and low[v] >= disc[p]:
						art[p] = 1
		if root_children > 1:
			art[root] = 1
	var cut := 0
	for i in n:
		cut += art[i]
	return [cut, pieces, least]

## The open ground of a floor: its walkable cells outside the pavilion's room.
static func ground_of(plan: Floor.FloorPlan) -> PackedByteArray:
	var open := PackedByteArray()
	open.resize(W * H)
	for y in H:
		for x in W:
			if Floor.cell_at(plan, 0, x, y) == Floor.CORRIDOR:
				open[y * W + x] = 1
	return open

static func mask_of(g: Arboretum.Garden, surface: int) -> PackedByteArray:
	var m := PackedByteArray()
	m.resize(W * H)
	for i in W * H:
		if g.cells[i] == surface:
			m[i] = 1
	return m

## The cells beside a landmark's clearing (four ways) that have `ok` set; its own cells when they do.
static func doorsteps(l: Arboretum.Landmark, ok: PackedByteArray) -> PackedInt32Array:
	var cells := l.cells()
	if ok[cells[0]] == 1:
		return cells
	var out := PackedInt32Array()
	for c in cells:
		for st in STEPS:
			var ni := (c / W + st.y) * W + c % W + st.x
			if ok[ni] == 1 and out.find(ni) < 0:
				out.append(ni)
	return out

## Steps between two landmarks' clearings through cells with `ok` set (a step onto each clearing that is not
## itself `ok`), or -1.
static func way(a: Arboretum.Landmark, z: Arboretum.Landmark, ok: PackedByteArray) -> int:
	var from := doorsteps(a, ok)
	var to := doorsteps(z, ok)
	if from.is_empty() or to.is_empty():
		return -1
	var dist := steps_from(from, ok)
	var best := -1
	for c in to:
		if dist[c] >= 0 and (best < 0 or dist[c] < best):
			best = dist[c]
	if best < 0:
		return -1
	return best + (0 if ok[a.cells()[0]] == 1 else 1) + (0 if ok[z.cells()[0]] == 1 else 1)

# ---------------------------------------------------------------------------------------------
# 1. Two routes, no line.

func test_two_routes_and_no_thicket_line(t: T) -> void:
	_apply_break()
	var n := count(t)
	var bad := 0
	var share_lo := 1.0
	var share_hi := 0.0
	var share_sum := 0.0
	var longest := 0
	var tries := 0
	for i in n:
		var plan := floor_of(i)
		if not t.check(plan != null, "%s: no floor" % key_of(i)):
			continue
		var g := Arboretum.garden_of(plan)
		tries = maxi(tries, g.attempt)
		var open := ground_of(plan)
		var got := cuts(open)
		if got[0] != 0 or got[1] != 1 or got[2] < 2:
			bad += 1
			t.check(bad > 4, "%s: two routes: %d cells whose loss cuts the ground, %d pieces of ground, a cell with %d open neighbours" % [key_of(i), got[0], got[1], got[2]])
		# The apron cell outside the doorway is ground, and the doorway joins it to the landing.
		t.check(open[g.door_out] == 1 and Floor.can_step_xy(plan, 0, g.door_in % W, g.door_in / W, 0, g.door_out % W, g.door_out / W),
			"%s: the doorway does not open onto the apron" % key_of(i))
		# Thicket: runs along rows and columns, and its share of the garden.
		var th := 0
		var cells := 0
		for y in range(Arboretum.Y0, Arboretum.Y1 + 1):
			var run := 0
			for x in range(Arboretum.X0, Arboretum.X1 + 1):
				cells += 1
				th += g.thicket[y * W + x]
				run = run + 1 if g.thicket[y * W + x] == 1 else 0
				longest = maxi(longest, run)
				# Thicket is wall, and only thicket, the pavilion and the buildings are.
				var void_ := Floor.cell_at(plan, 0, x, y) == Floor.VOID
				var building := false
				for l in g.landmarks:
					building = building or l.building == y * W + x
				if void_ != (g.thicket[y * W + x] == 1 or building):
					t.check(false, "%s: cell %d,%d is %s and thicket %d" % [key_of(i), x, y, Floor.cell_at(plan, 0, x, y), g.thicket[y * W + x]])
		for x in range(Arboretum.X0, Arboretum.X1 + 1):
			var run := 0
			for y in range(Arboretum.Y0, Arboretum.Y1 + 1):
				run = run + 1 if g.thicket[y * W + x] == 1 else 0
				longest = maxi(longest, run)
		var share := float(th) / cells
		share_lo = minf(share_lo, share)
		share_hi = maxf(share_hi, share)
		share_sum += share
	t.eq(bad, 0, "floors where some cell has only one route")
	t.check(longest <= 5, "the longest line of thicket is %d cells" % longest)
	t.check(share_lo >= 0.18 and share_hi <= 0.36, "thicket is %.0f to %.0f in 100 of the garden" % [share_lo * 100.0, share_hi * 100.0])
	t.note("%d floors: no cut cell, no dead end; thicket %.1f in 100 of the garden (%.1f to %.1f), its longest line %d cells; at most %d tries a floor" % [n, share_sum / n * 100.0, share_lo * 100.0, share_hi * 100.0, longest, tries + 1])

# ---------------------------------------------------------------------------------------------
# 2. Surfaces: the walk and the moss.

func test_the_walk_and_the_moss(t: T) -> void:
	_apply_break()
	var n := count(t)
	var bad := 0
	var ratio_lo := 9.0
	var ratio_hi := 0.0
	var pairs := 0
	var stops_sum := 0
	for i in n:
		var plan := floor_of(i)
		if plan == null:
			continue
		var g := Arboretum.garden_of(plan)
		var why := ""
		# Every open cell has a surface, nothing else has (the pavilion's brick floor is gravel).
		for c in W * H:
			var kind := Floor.cell_at(plan, 0, c % W, c / W)
			var s := g.cells[c]
			if kind == Floor.CORRIDOR and s == Noises.NONE:
				why = "open cell %d has no surface" % c
			if kind == Floor.VOID and s != Noises.NONE:
				why = "cell %d is not ground and has a surface" % c
		# The walk: gravel (moss at a crossing), a closed loop through the clearings it passes.
		var gravel := mask_of(g, Noises.GRAVEL)
		for c in g.crossings:
			gravel[c] = 1
			if g.cells[c] != Noises.MOSS or g.walk.find(c) < 0:
				why = "crossing %d is not moss on the walk" % c
		for c in g.walk:
			if gravel[c] == 0:
				why = "walk cell %d is not gravel" % c
		var on_walk: Array[Arboretum.Landmark] = []
		for l in g.landmarks:
			# Every clearing is worn ground but the pavilion's apron, which is gravel.
			for c in l.cells():
				if g.cells[c] != (Noises.GRAVEL if l.id == 0 else Noises.MOSS):
					why = "the %s's clearing is %s" % [l.kind, Noises.SURFACE_NAMES[g.cells[c]]]
			if l.on_walk:
				on_walk.append(l)
				# The walk passes it: gravel beside its clearing.
				if l.id != 0 and doorsteps(l, gravel).is_empty():
					why = "the walk does not pass the %s" % l.kind
		stops_sum += on_walk.size()
		if not g.landmarks[0].on_walk or (on_walk.size() - 1) * 2 < g.landmarks.size():
			why = "the walk passes %d of %d landmarks" % [on_walk.size() - 1, g.landmarks.size()]
		# A loop: with any one walk cell taken out, the rest of the walk is still one piece; and it starts at the
		# pavilion's gate, beside the apron.
		var only_walk := PackedByteArray()
		only_walk.resize(W * H)
		for c in g.walk:
			only_walk[c] = 1
		for probe: int in [1, g.walk.size() / 3, g.walk.size() * 2 / 3]:
			var cutm := only_walk.duplicate()
			cutm[g.walk[probe]] = 0
			var reach := steps_from(PackedInt32Array([g.walk[0]]), cutm)
			for c in g.walk:
				if c != g.walk[probe] and reach[c] < 0:
					why = "the walk is not a loop: without cell %d, cell %d is cut off" % [g.walk[probe], c]
		if g.walk[0] != g.landmarks[0].gate or doorsteps(g.landmarks[0], only_walk).size() != 1:
			why = "the walk does not start at the pavilion's gate"
		# Moss joins every pair of landmarks and the landing; on the walk it is 1.2 to 1.6 times the walk.
		var moss := mask_of(g, Noises.MOSS)
		for a in g.landmarks.size():
			for z in range(a + 1, g.landmarks.size()):
				var la := g.landmarks[a]
				var lz := g.landmarks[z]
				var m := way(la, lz, moss)
				if m < 0:
					why = "no moss way from the %s to the %s" % [la.kind, lz.kind]
					continue
				if not (la.on_walk and lz.on_walk):
					continue
				var w := way(la, lz, gravel)
				if w <= 0:
					why = "no walk from the %s to the %s" % [la.kind, lz.kind]
					continue
				var ratio := float(m) / w
				pairs += 1
				ratio_lo = minf(ratio_lo, ratio)
				ratio_hi = maxf(ratio_hi, ratio)
				if ratio < 1.2 - 1e-9 or ratio > 1.6 + 1e-9:
					why = "the moss way from the %s to the %s is %d steps, the walk %d: %.2f times" % [la.kind, lz.kind, m, w, ratio]
		if why != "":
			bad += 1
			t.check(bad > 4, "%s: %s" % [key_of(i), why])
	t.eq(bad, 0, "floors whose walk or moss breaks a rule")
	t.note("%d floors: the walk passes %.1f landmarks a floor besides the pavilion; %d pairs on the walk, the moss way %.2f to %.2f times the walk" % [n, float(stops_sum) / n - 1.0, pairs, ratio_lo, ratio_hi])

# ---------------------------------------------------------------------------------------------
# 3. Landmarks, lamps, dead trees and twig falls.

func test_landmarks_lamps_and_twig_falls(t: T) -> void:
	_apply_break()
	var n := count(t)
	var bad := 0
	var marks := {}
	var kinds := {}
	var dead_sum := 0
	var fall_sum := 0
	for i in n:
		var plan := floor_of(i)
		if plan == null:
			continue
		var g := Arboretum.garden_of(plan)
		var why := ""
		var total := g.landmarks.size()
		marks[total] = int(marks.get(total, 0)) + 1
		if total < 6 or total > 9:
			why = "%d landmarks" % total
		var seen := {}
		var in_clearing := {}
		for l in g.landmarks:
			kinds[l.kind] = int(kinds.get(l.kind, 0)) + 1
			if seen.has(l.kind):
				why = "two of the %s" % l.kind
			seen[l.kind] = true
			# Its lamp stands at its clearing.
			if l.lamp.x < l.x * 200 or l.lamp.x > (l.x + l.w) * 200 or l.lamp.y < l.y * 200 or l.lamp.y > (l.y + l.h) * 200:
				why = "the %s's lamp is not at its clearing" % l.kind
			for cy in range(l.y - 1, l.y + l.h + 1):
				for cx in range(l.x - 1, l.x + l.w + 1):
					in_clearing[cy * W + cx] = true
			for o in g.landmarks:
				if o.id <= l.id:
					continue
				var dx := maxi(0, maxi(l.x - (o.x + o.w), o.x - (l.x + l.w)))
				var dy := maxi(0, maxi(l.y - (o.y + o.h), o.y - (l.y + l.h)))
				if maxi(dx, dy) < 6:
					why = "the %s and the %s are %d cells apart" % [l.kind, o.kind, maxi(dx, dy)]
		if g.landmarks[0].kind != &"pavilion" or g.landmarks[0].x + 1 != plan.landing.x:
			why = "the first landmark is not the lift pavilion"
		# Dead trees and their falls.
		var dn := g.dead.size()
		dead_sum += dn
		if dn < 4 or dn > 7:
			why = "%d dead trees" % dn
		var twig_cells := 0
		var on_walk := {}
		for c in g.walk:
			on_walk[c] = true
		for d in g.dead:
			fall_sum += d.fall.size()
			if d.fall.size() < 3 or d.fall.size() > 6 or d.fall[0] != d.cell:
				why = "dead tree %d has a fall of %d cells" % [d.id, d.fall.size()]
			if d.at.x / 200 != d.cell % W or d.at.y / 200 != d.cell / W:
				why = "dead tree %d does not stand in its own fall" % d.id
			for c in d.fall:
				twig_cells += 1
				if g.cells[c] != Noises.TWIG or g.falls[c] != d.id:
					why = "fall cell %d of dead tree %d is %s" % [c, d.id, Noises.SURFACE_NAMES[g.cells[c]]]
				# The surface check: a fall is only on litter, never on a worn line, the walk or a clearing.
				if g.worn[c] == 1 or on_walk.has(c) or in_clearing.has(c):
					why = "a twig fall on %s (cell %d)" % ["a worn line" if g.worn[c] == 1 else ("the walk" if on_walk.has(c) else "a clearing"), c]
				if maxi(absi(c % W - plan.landing.x), absi(c / W - plan.landing.y)) <= 3:
					why = "a twig fall %d cells from the landing" % maxi(absi(c % W - plan.landing.x), absi(c / W - plan.landing.y))
		var all_twig := 0
		for c in W * H:
			if g.cells[c] == Noises.TWIG:
				all_twig += 1
			# Worn lines stay moss, whatever fell.
			if g.worn[c] == 1 and g.cells[c] != Noises.MOSS:
				why = "a worn line's cell %d is %s" % [c, Noises.SURFACE_NAMES[g.cells[c]]]
		if all_twig != twig_cells:
			why = "%d twig cells, %d under a dead tree" % [all_twig, twig_cells]
		if why != "":
			bad += 1
			t.check(bad > 4, "%s: %s" % [key_of(i), why])
	t.eq(bad, 0, "floors whose landmarks or twig falls break a rule")
	t.check(kinds.size() == 10 or t.quick, "every kind of landmark turns up: %s" % str(kinds.keys()))
	t.note("%d floors: landmarks a floor %s; %.1f dead trees a floor, %.1f cells a fall" % [n, str(marks), float(dead_sum) / n, float(fall_sum) / maxi(1, dead_sum)])

# ---------------------------------------------------------------------------------------------
# 4 and 5. Trunks and hides.

func test_trunks_never_trap_a_body(t: T) -> void:
	_apply_break()
	var n := count(t)
	# The walks between neighbouring cells on a quarter of the floors (each is tens of thousands of points).
	var walked := 0
	var bad := 0
	var trunks := 0
	var lines := 0
	for i in n:
		var plan := floor_of(i)
		if plan == null:
			continue
		var g := Arboretum.garden_of(plan)
		var pieces := Furniture.pieces_for(plan)
		var why := ""
		var per_cell := {}
		for p in pieces:
			var c := (p.y / 200) * W + p.x / 200
			match p.kind:
				&"trunk":
					trunks += 1
					per_cell[c] = int(per_cell.get(c, 0)) + 1
					if g.cells[c] != Noises.LITTER:
						why = "a trunk on %s (cell %d)" % [Noises.SURFACE_NAMES[g.cells[c]], c]
					# In a corner of its cell: clear of the middle both ways.
					if absi(p.x % 200 - 100) - p.w / 2 < 40 or absi(p.y % 200 - 100) - p.d / 2 < 40:
						why = "a trunk over the middle of cell %d" % c
				&"dead_tree":
					if g.cells[c] != Noises.TWIG:
						why = "a dead tree on %s" % Noises.SURFACE_NAMES[g.cells[c]]
			if not p.solid:
				why = "piece %d (%s) is not solid" % [p.id, p.kind]
		for c: int in per_cell:
			if int(per_cell[c]) < 2 or int(per_cell[c]) > 4:
				why = "%d trunks in cell %d" % [per_cell[c], c]
		if i % 4 == 0 and why == "":
			walked += 1
			var solids := Furniture.solids_from(plan, pieces)
			for c in W * H:
				if Floor.cell_at(plan, 0, c % W, c / W) != Floor.CORRIDOR:
					continue
				for st: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
					var nx := c % W + st.x
					var ny := c / W + st.y
					if Floor.cell_at(plan, 0, nx, ny) != Floor.CORRIDOR:
						continue
					lines += 1
					for k in 9:
						var x := (c % W + 0.5 + st.x * k / 8.0) * 2.0
						var z := (c / W + 0.5 + st.y * k / 8.0) * 2.0
						if not Move.clear_at(plan, solids, 0, x, z, R):
							why = "a body cannot walk from cell %d to cell %d (blocked at %.2f, %.2f)" % [c, ny * W + nx, x, z]
							break
			for h in Hides.hides_for(plan):
				if not Move.clear_at(plan, solids, 0, h.front.x / 100.0, h.front.y / 100.0, R):
					why = "a body cannot stand on the front spot of hide %d (%s)" % [h.id, h.kind]
		if why != "":
			bad += 1
			t.check(bad > 4, "%s: %s" % [key_of(i), why])
	t.eq(bad, 0, "floors where a trunk stands wrong")
	t.check(lines > 0 and trunks > n * 300, "not vacuous: %d trunks, %d walks" % [trunks, lines])
	t.note("%d floors: %.0f trunks a floor, all on litter; on %d floors a body walked every one of %d lines between neighbouring cells" % [n, float(trunks) / n, walked, lines])

func test_hides(t: T) -> void:
	_apply_break()
	var n := count(t)
	var bad := 0
	var total := 0
	var kinds := {}
	var lo := 99
	var hi := 0
	for i in n:
		var plan := floor_of(i)
		if plan == null:
			continue
		var g := Arboretum.garden_of(plan)
		var list := Hides.hides_for(plan)
		var why := ""
		total += list.size()
		lo = mini(lo, list.size())
		hi = maxi(hi, list.size())
		if list.size() < 8 or list.size() > 14:
			why = "%d hides" % list.size()
		for k in list.size():
			var h := list[k]
			kinds[h.kind] = int(kinds.get(h.kind, 0)) + 1
			if h.id != k:
				why = "hide ids out of order"
			var ic := (h.inside.y / 200) * W + h.inside.x / 200
			var fc := (h.front.y / 200) * W + h.front.x / 200
			if Floor.cell_at(plan, 0, ic % W, ic / W) != Floor.CORRIDOR or Floor.cell_at(plan, 0, fc % W, fc / W) != Floor.CORRIDOR:
				why = "hide %d (%s) has a spot off the open ground" % [h.id, h.kind]
			if absi(h.front.x - h.inside.x) + absi(h.front.y - h.inside.y) != 70:
				why = "hide %d's front spot is not 70 cm from its inside" % h.id
			# Its back is to a building or the thicket.
			var back := Vector2i(h.inside.x - (h.front.x - h.inside.x), h.inside.y - (h.front.y - h.inside.y))
			if Floor.cell_at(plan, 0, back.x / 200, back.y / 200) != Floor.VOID:
				why = "hide %d (%s) is not against a building or the thicket" % [h.id, h.kind]
			if h.kind == &"log" and g.thicket[(back.y / 200) * W + back.x / 200] != 1:
				why = "a hollow log not against the thicket"
			if maxi(absi(ic % W - plan.landing.x), absi(ic / W - plan.landing.y)) <= 3:
				why = "hide %d is within 3 cells of the landing" % h.id
		if Hides.hash_of(list) != Hides.hash_of(Arboretum.hides(plan)):
			why = "sim/hides.gd lists other hides than the garden's"
		if why != "":
			bad += 1
			t.check(bad > 4, "%s: %s" % [key_of(i), why])
	t.eq(bad, 0, "floors whose hides break a rule")
	t.note("%d floors: %.1f hides a floor (%d to %d): %s" % [n, float(total) / n, lo, hi, str(kinds)])

# ---------------------------------------------------------------------------------------------
# 6. Same seed, same floor.

static func whole_hash(plan: Floor.FloorPlan) -> String:
	return Playroom.hash_plain([Arboretum.floor_hash(plan), Hides.hash_of(Hides.hides_for(plan)), Furniture.hash_of(Furniture.pieces_for(plan))])

func test_same_seed_same_floor(t: T) -> void:
	_apply_break()
	var recording := OS.get_environment("PROP_ARBORETUM_RECORD") == "1"
	var stored := {}
	if not recording:
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(HASHES_PATH))
		if not t.check(parsed is Dictionary, "cannot read %s" % HASHES_PATH):
			return
		stored = parsed
	var n := count(t)
	var got := {}
	var differ := 0
	var mismatched := 0
	for i in n:
		var plan := floor_of(i)
		if plan == null:
			continue
		var h := whole_hash(plan)
		got[key_of(i)] = h
		if i % 10 == 0:
			var again := whole_hash(Arboretum.generate_arboretum("seed-%d" % i, 5 + i % 4))
			if again != h:
				differ += 1
				t.check(differ > 3, "%s: generated twice, hashes %s and %s" % [key_of(i), h, again])
		if not recording and str(stored.get(key_of(i), "(none)")) != h:
			mismatched += 1
			t.check(mismatched > 3, "%s: hash %s, stored %s" % [key_of(i), h, str(stored.get(key_of(i), "(none)"))])
	t.eq(differ, 0, "floors whose two generations differ")
	t.eq(mismatched, 0, "floors whose hash differs from %s" % HASHES_PATH.get_file())
	if recording:
		t.check(not t.quick, "record the hashes at the default size (all %d floors)" % SEEDS)
		var keys: Array = got.keys()
		keys.sort()
		var lines := PackedStringArray()
		for k: String in keys:
			lines.append("  %s: %s" % [JSON.stringify(k), JSON.stringify(got[k])])
		var fa := FileAccess.open(HASHES_PATH, FileAccess.WRITE)
		fa.store_string("{\n" + ",\n".join(lines) + "\n}\n")
		fa.close()
		t.note("wrote %d hashes to %s" % [keys.size(), HASHES_PATH])

# ---------------------------------------------------------------------------------------------
# 7. The car, the landing and the call.

static func input(id: String, body: Move.Body) -> Run.PlayerInput:
	return Run.PlayerInput.make(id, body, 1.65, 0.0, 0.0, 90.0, 70.0)

static func one(i: Run.PlayerInput) -> Array[Run.PlayerInput]:
	var out: Array[Run.PlayerInput] = [i]
	return out

## Walks `body` toward (x, z) for one tick at a walk, with the run's own collision.
static func toward(s: Run.RunState, body: Move.Body, x: float, z: float) -> Move.Body:
	var dx := x - body.x
	var dz := z - body.z
	var d := M.hypot2(dx, dz)
	if d < 1e-6:
		return body
	var go := minf(d, 3.0 * DT)
	return Run.move_in_run(s, body, dx / d * go, dz / d * go, R)

func test_the_car_the_landing_and_the_call(t: T) -> void:
	_apply_break()
	var ids: Array[String] = ["a"]
	for i in (2 if t.quick else 10):
		var seed := "seed-%d" % (i * 7)
		var rules := HostRules.new(false, 5, Places.FULL)
		var s := rules.prepare(Run.create_run(seed, ids, Places.FULL))
		var plan := s.plan
		if not t.check(plan.place == Places.ARBORETUM, "%s: floor 5 of the game's deck is %s" % [seed, plan.place]):
			continue
		var g := Arboretum.garden_of(plan)
		t.check(Landing.elevator_wall(plan) == &"n", "%s: the lift's doors are on the %s wall" % [seed, Landing.elevator_wall(plan)])
		# The car's space is outside the plan: void on the plan, two cells deep behind the landing.
		for cy: int in [plan.landing.y - 1, plan.landing.y - 2]:
			for cx in range(plan.landing.x - 1, plan.landing.x + 2):
				t.check(Floor.cell_at(plan, 0, cx, cy) == Floor.VOID, "%s: the car's space is not void at %d,%d" % [seed, cx, cy])
		var body := s.players[0].body
		var mid_in := Vector2((g.door_in % W + 0.5) * 2.0, (g.door_in / W + 0.5) * 2.0)
		var apron := Vector2((g.door_out % W + 0.5) * 2.0, (g.door_out / W + 0.5) * 2.0 + 1.5)
		var landing := Vector2((plan.landing.x + 0.5) * 2.0, (plan.landing.y + 0.5) * 2.0)
		var seen := {}
		var stage := "out"
		var called_at := -1.0
		var rode := false
		for step in int(200.0 / DT):
			var want := apron
			match stage:
				"out":
					# Out of the car, through the pavilion and its one doorway, onto the apron.
					if Run.in_car(s.car, body) or absf(body.x - landing.x) > 0.3:
						want = landing if body.z < landing.y - 0.2 or absf(body.x - landing.x) > 0.3 else mid_in
					elif body.z < mid_in.y - 0.05:
						want = mid_in
					if M.hypot2(body.x - apron.x, body.z - apron.y) < 0.2 and s.phase == &"away":
						stage = "back"
				"back":
					want = mid_in if body.z > mid_in.y + 0.1 else landing
					if M.hypot2(body.x - landing.x, body.z - landing.y) < 0.2:
						stage = "call"
				"call", "wait":
					want = landing
				"board":
					# Into the car, onto the DOWN half (the right as you walk in).
					var down := Run.car_body(s.car, 2.0, 1.0)
					want = Vector2(down.x, down.z) if body.z < landing.y + 0.5 and absf(body.x - landing.x) < 0.4 or Run.in_car(s.car, body) else landing
					if Run.in_car(s.car, body):
						want = Vector2(down.x, down.z)
			body = toward(s, body, want.x, want.y)
			var inp := input("a", body)
			inp.call = stage == "call"
			var r := rules.step(s, one(inp), DT)
			s = r.state
			for e in r.events:
				seen[e["type"]] = true
				if e["type"] == "called":
					stage = "wait"
					called_at = s.t
				elif e["type"] == "carArrived":
					stage = "board"
				elif e["type"] == "rodeDown":
					rode = true
			if rode:
				break
		t.check(seen.has("doorsOpened") and seen.has("carLeft"), "%s: the doors opened and the car left (%s)" % [seed, str(seen.keys())])
		t.check(seen.has("called") and seen.has("carArrived") and seen.has("bell"), "%s: the call brought the car (%s, stage %s)" % [seed, str(seen.keys()), stage])
		t.check(rode and s.depth == 6, "%s: the car rode down to floor 6 (depth %d, stage %s, body %.2f, %.2f, landing %.1f, %.1f, phase %s)" % [seed, s.depth, stage, body.x, body.z, landing.x, landing.y, s.phase])

# ---------------------------------------------------------------------------------------------
# 8. Where the Groundskeeper starts.

func test_the_groundskeeper_starts_far(t: T) -> void:
	_apply_break()
	var n := count(t)
	var bad := 0
	var far_sum := 0
	for i in n:
		var plan := floor_of(i)
		if plan == null:
			continue
		var g := Arboretum.garden_of(plan)
		var dist := Floor.distances_from(plan, plan.landing)
		var best := -1
		var best_d := -1
		for l in g.landmarks:
			if l.id == 0:
				continue
			var near := 1 << 30
			for c in l.cells():
				if dist[c] >= 0:
					near = mini(near, dist[c])
			if near < (1 << 30) and near > best_d:
				best_d = near
				best = l.id
		var es := plan.entity_start
		var at := es.y * W + es.x
		var here := -1
		for l in g.landmarks:
			if l.cells().find(at) >= 0:
				here = l.id
		far_sum += best_d
		if here != best or dist[at] != best_d:
			bad += 1
			t.check(bad > 4, "%s: it starts at landmark %d (%d steps from the landing), the farthest is %d (%d steps)" % [key_of(i), here, dist[at], best, best_d])
	t.eq(bad, 0, "floors where it does not start at the farthest landmark")
	# In a run it stands there, listening.
	var ids: Array[String] = ["a"]
	var s := HostRules.new(true, 5, Places.FULL).prepare(Run.create_run("seed-3", ids, Places.FULL))
	var r := Run.step_run(s, one(input("a", s.players[0].body)), DT)
	var k := r.state.garden.keeper if r.state.garden != null else null
	var start := Move.body_at_cell(s.plan, s.plan.entity_start)
	t.check(k != null and k.mode == &"listening" and k.body.x == start.x and k.body.z == start.z, "in a run the Groundskeeper stands at its start, listening")
	t.check(r.state.entity_id == "groundskeeper-5" and Run.resident_of(r.state).name == "Groundskeeper" and Run.resident_of(r.state).trait_name == &"listening", "it is the Groundskeeper (%s)" % r.state.entity_id)
	t.note("%d floors: it starts %.0f steps' walk from the landing on average" % [n, float(far_sum) / n])

# ---------------------------------------------------------------------------------------------
# 9. The deck.

func test_the_deck(t: T) -> void:
	t.check(Places.FULL == ([&"clinic", &"annex", &"playroom", &"arboretum"] as Array[StringName]), "the game's deck: %s" % str(Places.FULL))
	t.check(Places.BEFORE_ARBORETUM == ([&"clinic", &"annex", &"playroom"] as Array[StringName]), "the deck before it: %s" % str(Places.BEFORE_ARBORETUM))
	var n := 30 if t.quick else 300
	var drawn := {}
	var repeats := 0
	var fifth := 0
	var old_has := 0
	for i in n:
		var seed := "deck-%d" % i
		for depth in range(1, 5):
			if Places.place_at(seed, depth, Places.FULL) != Places.place_at(seed, depth, Places.BEFORE_ARBORETUM):
				t.check(false, "%s: floor %d changed" % [seed, depth])
		if Places.place_at(seed, 5, Places.FULL) == Places.ARBORETUM:
			fifth += 1
		var prev := Places.ARBORETUM
		for depth in range(6, 14):
			var p := Places.place_at(seed, depth, Places.FULL)
			drawn[p] = int(drawn.get(p, 0)) + 1
			if p == prev:
				repeats += 1
			prev = p
		for depth in range(1, 14):
			if Places.place_at(seed, depth, Places.BEFORE_ARBORETUM) == Places.ARBORETUM or Places.place_at(seed, depth, Places.CLINIC_ONLY) == Places.ARBORETUM:
				old_has += 1
	t.eq(fifth, n, "seeds whose fifth floor is the Arboretum")
	t.eq(repeats, 0, "floors from 6 that repeat the floor above")
	t.eq(old_has, 0, "floors of a deck without it that are an Arboretum")
	t.check(drawn.size() == 4 or t.quick, "from floor 6 every place is drawn: %s" % str(drawn))
	var plan := Places.generate("deck-0", 5, Places.FULL)
	t.check(plan.place == Places.ARBORETUM and plan.ground is Arboretum.Garden and plan.depth == 5, "Places.generate makes the Arboretum on floor 5")
	t.check(Places.generate("deck-0", 5, Places.BEFORE_ARBORETUM).ground == null, "a floor of the old deck has no ground")
	t.note("%d seeds: floor 5 always the Arboretum; floors 6 to 13 drew %s" % [n, str(drawn)])

# ---------------------------------------------------------------------------------------------
# 10. Hiding on a real floor.

func test_hiding_for_a_blind_resident(t: T) -> void:
	_apply_break()
	var ids: Array[String] = ["a"]
	var cases := 0
	for i in (3 if t.quick else 12):
		var seed := "seed-%d" % (i * 5 + 1)
		for near: bool in [true, false]:
			var s := HostRules.new(true, 5, Places.FULL, false, false, true).prepare(Run.create_run(seed, ids, Places.FULL))
			s = s.copy()
			s.phase = &"away"
			var hides := Hides.hides_for(s.plan)
			var h := hides[i % hides.size()]
			var front := Move.Body.make(h.front.x / 100.0, h.front.y / 100.0, 0, 0.0)
			# The Groundskeeper 3 m off (it hears the hide), or 12 m off along the open ground (it does not).
			var dist := Floor.distances_from(s.plan, Move.cell_of(s.plan, front))
			var spot: Move.Body = null
			for c in W * H:
				if dist[c] < 0:
					continue
				var b := Move.body_at_cell(s.plan, Floor.Pos.make(0, c % W, c / W))
				var d := M.hypot2(b.x - front.x, b.z - front.z)
				if (near and d > 2.6 and d < 3.6) or (not near and d > 11.0 and d < 13.0):
					spot = b
					break
			if spot == null:
				continue
			cases += 1
			var o := s.orderly.copy()
			o.body = spot
			s.orderly = o
			var taken := false
			var inside := false
			var leaned := false
			for step in int(12.0 / DT):
				var inp := input("a", front)
				inp.hide_use = step == 3
				var r := Run.step_run(s, one(inp), DT)
				s = r.state
				for e in r.events:
					if e["type"] == "hideIn":
						inside = true
					elif e["type"] == "keeperLean" and int(e["hide"]) == h.id:
						leaned = true
					elif e["type"] == "downed":
						taken = true
			t.check(inside, "%s hide %d: the player got in" % [seed, h.id])
			if near:
				t.check(leaned and taken, "%s hide %d (%s): it heard them get in 3 m off: leaned on the hide %s, took them %s" % [seed, h.id, h.kind, leaned, taken])
			else:
				t.check(not taken and not leaned and s.players[0].status == &"ok", "%s hide %d: a hide it did not hear: leaned %s, taken %s" % [seed, h.id, leaned, taken])
	t.check(cases >= 4, "cases tried: %d" % cases)
	_cache = {}
