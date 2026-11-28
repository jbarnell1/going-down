# Dangers: the Arboretum's roosting birds (kind `roost`). A passive danger: it never takes anyone down.
#
# A few broad-leaved trees hold a roost of big dark birds. From the floor's first tick a settled roost murmurs and
# shuffles up in its tree (the view's idle loop, heard well beyond the ground it guards), and the litter under it is
# spattered pale, so the ground that sets it off can be seen. The rules, host time only:
#   settled  -> stirring  an up player (on their feet, not hidden, not in the car, not pinned) walking or sprinting
#                         within danger.roost.stir of the roost's middle. Costs nothing; the birds sound restless.
#   stirring -> settled   nobody has qualified for danger.roost.calm seconds.
#   settled / stirring -> flushed, on the tick either happens:
#                         a) an up player whose gait is a walk or a sprint, moving faster than
#                            danger.roost.walk_floor (measured from the record's own last sight of them), is within
#                            danger.roost.trigger of the middle;
#                         b) a thrown pinecone lands (the run's coneLanded event) within danger.roost.cone of it.
#                         Cost: ONE noise at the roost's middle (not at the player), reach danger.roost.loud, made by
#                         nobody (as a landed cone's), so the floor's resident hears a thing in a tree, comes to the
#                         tree by its own rule and finds whoever stayed near it. A creep never flushes or stirs a
#                         roost, on any ground; nor does a downed player crawling, nor one in a hide.
#   flushed  -> away      after danger.roost.burst (the birds going up). Neither flushed nor away can flush again.
#   away     -> settling  after danger.roost.away.
#   settling -> settled   after danger.roost.settle.
# Placement: litter cells whose trunks are all broad-leaved (no conifers, so never a pinecone's tree), far from the
# lift by walking, clear of every landmark's clearing and the ring round it, every hide, every pinecone, every twig
# fall and its neighbours, the walk's crossings and every kind's records, spaced apart; a roost is refused if, with the
# ground under every roost taken away, the landing no longer reaches every landmark, hide and pinecone (a way round
# always exists). Drawn only from this kind's own generator.
extends "res://sim/dangers/kind.gd"

const Arboretum = preload("res://sim/arboretum.gd")
const Floor = preload("res://sim/floor.gd")
const Furniture = preload("res://sim/furniture.gd")
const GardenCones = preload("res://sim/garden_cones.gd")
const Move = preload("res://sim/move.gd")
const Noises = preload("res://sim/noise.gd")
const Settings = preload("res://sim/settings.gd")

const SETTLED := &"settled"
const STIRRING := &"stirring"
const FLUSHED := &"flushed"
const AWAY := &"away"
const SETTLING := &"settling"

## The live settings' game values (sim/settings.gd rows danger.roost.*).
const COUNT := 4
const TRIGGER := 2.5
const STIR := 8.1
## The restless ring is never less than the trigger plus this (metres), whatever a host sets.
const STIR_OVER := 5.6
const WALK_FLOOR := 1.7
const LOUD := 22.0
const CONE := 2.5
const BURST := 3.0
const AWAY_SECS := 60.0
const SETTLE := 3.0
const CALM := 1.5
const LIFT_CLEAR := 6
const SPACING := 6
## Placement tries (each a fresh order of the candidates from this kind's generator).
const TRIES := 6
## The least number of broad-leaved trunks a roost's cell holds.
const TRUNKS_MIN := 2
const EPS := 1e-9

## The tests' deliberate breaks ("" in the game).
static var test_break := ""

func kind_name() -> StringName:
	return &"roost"

func states() -> Array[StringName]:
	return [SETTLED, STIRRING, FLUSHED, AWAY, SETTLING]

static func _f(tuning: Settings.Values, name: String, fallback: float) -> float:
	return Settings.f(tuning, StringName("danger.roost." + name), fallback)

static func _i(tuning: Settings.Values, name: String, fallback: int) -> int:
	return Settings.i(tuning, StringName("danger.roost." + name), fallback)

# ---------------------------------------------------------------------------------------------
# Placement.

## Every cell that could hold a roost, in cell order: [cell, [trunk positions in cm as Vector2i]].
static func candidates(plan: Floor.FloorPlan) -> Array:
	var out: Array = []
	var g := Arboretum.garden_of(plan)
	if g == null:
		return out
	var trunks := {}
	var conifer := {}
	for piece in Furniture.pieces_for(plan):
		if piece.kind != &"trunk":
			continue
		var cell: int = (piece.y / Arboretum.CM) * Arboretum.W + piece.x / Arboretum.CM
		if Arboretum.is_conifer(piece.x, piece.y):
			conifer[cell] = true
		if not trunks.has(cell):
			trunks[cell] = []
		(trunks[cell] as Array).append(Vector2i(piece.x, piece.y))
	var dead := {}
	for d in g.dead:
		dead[d.cell] = true
	var cells: Array = trunks.keys()
	cells.sort()
	for cell: int in cells:
		if conifer.has(cell) or dead.has(cell) or g.cells[cell] != Noises.LITTER:
			continue
		if (trunks[cell] as Array).size() < TRUNKS_MIN:
			continue
		out.append([cell, trunks[cell]])
	return out

## The cells no roost's trigger disc may touch, as discs {x, z, r} (metres), beyond the base's keep_clear.
static func own_clear(plan: Floor.FloorPlan) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var g := Arboretum.garden_of(plan)
	if g == null:
		return out
	var half := Arboretum.CM / 200.0
	# Every landmark's clearing and the ring one cell round it (its lamp, its search sites, its approach).
	for l in g.landmarks:
		for cy in range(l.y - 1, l.y + l.h + 1):
			for cx in range(l.x - 1, l.x + l.w + 1):
				out.append({"x": cx * 2.0 + half, "z": cy * 2.0 + half, "r": half})
	# Every twig fall and the cells beside it: two noise traps never stack.
	for d in g.dead:
		for c: int in d.fall:
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					out.append({"x": (c % Arboretum.W + dx) * 2.0 + half, "z": (c / Arboretum.W + dy) * 2.0 + half, "r": half})
	# Every gravel cell (the main walk, the aprons): pale on pale cannot be read, so the trigger's ground never touches
	# it. A whole cell is kept: the disc stays half a diagonal clear of the cell's middle.
	if test_break != "gravel_ok":
		for c in g.cells.size():
			if g.cells[c] == Noises.GRAVEL:
				out.append({"x": (c % Arboretum.W) * 2.0 + half, "z": (c / Arboretum.W) * 2.0 + half, "r": half * sqrt(2.0)})
	# Where a moss spur crosses the walk.
	for c: int in g.crossings:
		out.append({"x": (c % Arboretum.W) * 2.0 + half, "z": (c / Arboretum.W) * 2.0 + half, "r": half})
	# Every hide's inside and front spot (the base's discs too; these are the trigger's own).
	for h in Arboretum.hides(plan):
		out.append({"x": h.inside.x / 100.0, "z": h.inside.y / 100.0, "r": 0.6})
		out.append({"x": h.front.x / 100.0, "z": h.front.y / 100.0, "r": 0.6})
	# Every pinecone a crew might pick up.
	for c in GardenCones.placements(plan):
		out.append({"x": c.x, "z": c.z, "r": 0.5})
	return out

## Whether a disc touches a cell-sized square disc list entry (a square cell is treated as its inscribed disc plus
## the corner: the disc must keep r + half a cell's diagonal from a cell's middle, the list's own r is the margin).
static func _touches(list: Array[Dictionary], x: float, z: float, r: float) -> bool:
	for c in list:
		var dx := x - float(c["x"])
		var dz := z - float(c["z"])
		var reach := r + float(c["r"])
		if dx * dx + dz * dz < reach * reach - EPS:
			return true
	return false

## The cells whose middle lies inside any of the discs (the ground a careful crew walks round).
static func covered(plan: Floor.FloorPlan, discs: Array) -> Dictionary:
	var out := {}
	for disc: Array in discs:
		var x: float = disc[0]
		var z: float = disc[1]
		var r: float = disc[2]
		var c0 := int(floor((x - r) / 2.0))
		var c1 := int(floor((x + r) / 2.0))
		var r0 := int(floor((z - r) / 2.0))
		var r1 := int(floor((z + r) / 2.0))
		for cy in range(r0, r1 + 1):
			for cx in range(c0, c1 + 1):
				if cx < 0 or cy < 0 or cx >= plan.width or cy >= plan.height:
					continue
				var mx := cx * 2.0 + 1.0
				var mz := cy * 2.0 + 1.0
				if (mx - x) * (mx - x) + (mz - z) * (mz - z) < r * r - EPS:
					out[cy * plan.width + cx] = true
	return out

## Whether, with the cells under every disc taken away, the landing still reaches every landmark's clearing, every
## hide's front spot and every pinecone, walking cell to cell on level 0.
## `goals` (from goals_of(), computed once a floor) may be passed to save the work.
static func way_round(plan: Floor.FloorPlan, discs: Array, goals: Array = []) -> bool:
	var g := Arboretum.garden_of(plan)
	if g == null or test_break == "no_way_round":
		return true
	if goals.is_empty():
		goals = goals_of(plan)
	var blocked := covered(plan, discs)
	var adj := Floor.adjacency_of(plan)
	var n := plan.width * plan.height
	var seen := PackedByteArray()
	seen.resize(n * 2)
	var first := Floor.pos_index(plan, plan.landing)
	if blocked.has(first):
		return false
	var queue := PackedInt32Array([first])
	seen[first] = 1
	var head := 0
	while head < queue.size():
		var pi := queue[head]
		head += 1
		for k in range(adj.start[pi], adj.start[pi + 1]):
			var qi := adj.list[k]
			if seen[qi] == 1 or (qi < n and blocked.has(qi)):
				continue
			seen[qi] = 1
			queue.append(qi)
	for goal: PackedInt32Array in goals:
		var any := false
		for c in goal:
			if seen[c] == 1:
				any = true
				break
		if not any:
			return false
	return true

## What must stay reachable from the landing: each landmark's clearing (any of its cells), each hide's front spot and
## each pinecone, as lists of cells.
static func goals_of(plan: Floor.FloorPlan) -> Array:
	var out: Array = []
	var g := Arboretum.garden_of(plan)
	if g == null:
		return out
	for l in g.landmarks:
		out.append(l.cells())
	for h in Arboretum.hides(plan):
		out.append(PackedInt32Array([(h.front.y / Arboretum.CM) * plan.width + h.front.x / Arboretum.CM]))
	for c in GardenCones.placements(plan):
		out.append(PackedInt32Array([int(c.z / 2.0) * plan.width + int(c.x / 2.0)]))
	return out

func place(p: Api.Place) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var plan := p.plan
	if plan == null or Arboretum.garden_of(plan) == null:
		return out
	var want := clampi(_i(p.tuning, "count", COUNT), 0, 8)
	if want <= 0:
		return out
	var trigger := _f(p.tuning, "trigger", TRIGGER)
	var lift_clear := _i(p.tuning, "lift_clear", LIFT_CLEAR)
	var spacing := _i(p.tuning, "spacing", SPACING)
	var own := own_clear(plan)
	var goals := goals_of(plan)
	if test_break == "garden_touch":
		var g0 := Arboretum.garden_of(plan)
		g0.cells[g0.cells.size() - 1] = Noises.MOSS
	var ok: Array = []
	for cand: Array in candidates(plan):
		var cell: int = cand[0]
		var cx := cell % plan.width
		var cy := cell / plan.width
		var x := cx * 2.0 + 1.0
		var z := cy * 2.0 + 1.0
		var steps := p.lift_steps[cell] if cell < p.lift_steps.size() else -1
		if steps < 0 or steps < lift_clear:
			continue
		if not p.clear(0, x, z, trigger):
			continue
		if test_break != "no_own_clear" and _touches(own, x, z, trigger):
			continue
		var near_taken := false
		for r: Dictionary in p.taken:
			if int(r.get("level", 0)) == 0 and Vector2(float(r["x"]) - x, float(r["z"]) - z).length() < spacing * 2.0:
				near_taken = true
				break
		if near_taken:
			continue
		ok.append(cand)
	var best: Array = []
	for attempt in TRIES:
		var order := ok.duplicate()
		# A fresh order from this kind's own generator (Fisher-Yates).
		for i in range(order.size() - 1, 0, -1):
			var j := int(floor((randf() if test_break == "time_seed" else p.rng.next()) * float(i + 1)))
			var tmp: Variant = order[i]
			order[i] = order[j]
			order[j] = tmp
		var chosen: Array = []
		var discs: Array = []
		for cand: Array in order:
			if chosen.size() >= want:
				break
			var cell: int = cand[0]
			var cx := cell % plan.width
			var cy := cell / plan.width
			var spaced := true
			for o: Array in chosen:
				var oc: int = o[0]
				if maxi(absi(oc % plan.width - cx), absi(oc / plan.width - cy)) < spacing:
					spaced = false
					break
			if not spaced:
				continue
			var trial := discs.duplicate()
			trial.append([cx * 2.0 + 1.0, cy * 2.0 + 1.0, trigger])
			if not way_round(plan, trial, goals):
				continue
			chosen.append(cand)
			discs = trial
		if chosen.size() > best.size():
			best = chosen
		if best.size() >= want:
			break
	best.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) < int(b[0]))
	# What the screens need, and the radii the record keeps for the whole floor: the cell (its trunks), whether it
	# carries the floor's one notice, the trigger's radius (the spatter covers exactly it, and step() reads it from here,
	# so a host's tuning mid-floor cannot make the pale ground lie), the settle and burst lengths (the birds' timing) and
	# the cone's radius.
	var settle := _f(p.tuning, "settle", SETTLE)
	var burst := _f(p.tuning, "burst", BURST)
	var cone := _f(p.tuning, "cone", CONE)
	for cand: Array in best:
		var cell: int = cand[0]
		var x := (cell % plan.width) * 2.0 + 1.0
		var z := (cell / plan.width) * 2.0 + 1.0
		out.append({"x": x, "y": 0.0, "z": z, "level": 0, "yaw": 0.0, "state": SETTLED,
			"n": [cell, 1 if out.is_empty() else 0, trigger, settle, burst, cone], "k": {"prev": {}, "stir_at": -1.0}})
	return out

# ---------------------------------------------------------------------------------------------
# The step.

## Whether this player can disturb a roost at all: on their feet, out of a hide, out of the car, not pinned.
static func can_disturb(w: Api.Who) -> bool:
	return w.up and not w.down and not w.hidden and not w.aboard and not w.pinned and w.stance == &"stand" and w.body != null

static func _walking(w: Api.Who) -> bool:
	if test_break == "creep_flushes":
		return w.speed != &"still"
	return w.speed == &"walk" or w.speed == &"sprint"

func step(rec: Dictionary, k: Api.Tick, ask: Api.Asks) -> void:
	var state := StringName(rec["state"])
	var kk: Dictionary = rec["k"]
	var prev: Dictionary = kk.get("prev", {})
	var since := float(rec["since"])
	var x := float(rec["x"])
	var z := float(rec["z"])
	var level := int(rec["level"])
	var tuning := k.tuning
	var n: Array = rec.get("n", [])
	var trigger := float(n[2]) if n.size() > 2 else _f(tuning, "trigger", TRIGGER)
	var stir := maxf(_f(tuning, "stir", STIR), trigger + STIR_OVER)
	if test_break == "stir_is_trigger":
		stir = trigger
	var floor_speed := _f(tuning, "walk_floor", WALK_FLOOR)
	var now_prev := {}
	var flusher := ""
	var stirred := false
	for w in k.players:
		if w.body == null:
			continue
		now_prev[w.id] = [w.body.x, w.body.z, w.body.level]
		if not can_disturb(w) or w.body.level != level or not _walking(w):
			continue
		var d := Vector2(w.body.x - x, w.body.z - z).length()
		if d < stir:
			stirred = true
		var was: Variant = prev.get(w.id)
		var moved := 0.0
		if was is Array and int((was as Array)[2]) == w.body.level:
			moved = Vector2(w.body.x - float(was[0]), w.body.z - float(was[1])).length() / maxf(k.dt, EPS)
		if d < trigger and moved > floor_speed and flusher == "":
			flusher = w.id
	var coned := false
	var cone_r := float(n[5]) if n.size() > 5 else _f(tuning, "cone", CONE)
	if test_break == "cone_double":
		cone_r *= 2.0
	for e in k.events:
		if str(e.get("type", "")) == "coneLanded" and int(e.get("level", level)) == level:
			if Vector2(float(e["x"]) - x, float(e["z"]) - z).length() < cone_r:
				coned = true
	kk["prev"] = now_prev
	if stirred:
		kk["stir_at"] = k.t
	var at := Move.Body.make(x, z, level, 0.0)
	match state:
		SETTLED, STIRRING:
			if flusher != "" or coned:
				kk["by"] = flusher if flusher != "" else "cone"
				ask.set_state(rec, FLUSHED)
				var noise_at := at
				if test_break == "noise_at_flusher" and flusher != "":
					var fw := k.who(flusher)
					noise_at = Move.Body.make(fw.body.x, fw.body.z, fw.body.level, 0.0)
				ask.noise(rec, noise_at, LOUD if test_break == "hard_loud" else _f(tuning, "loud", LOUD), flusher if test_break == "blame_flusher" else "")
				if test_break == "stumble_flusher" and flusher != "":
					ask.stumble(rec, flusher, 1.0, 4.0)
			elif state == SETTLED and stirred:
				ask.set_state(rec, STIRRING)
			elif state == STIRRING and not stirred and k.t - float(kk.get("stir_at", -1.0)) >= _f(tuning, "calm", CALM) - EPS:
				ask.set_state(rec, SETTLED)
		FLUSHED:
			if k.t - since >= _f(tuning, "burst", BURST) - EPS:
				ask.set_state(rec, AWAY)
		AWAY:
			var away := 0.0 if test_break == "away_zero" else _f(tuning, "away", AWAY_SECS)
			if k.t - since >= away - EPS:
				ask.set_state(rec, SETTLING)
		SETTLING:
			if k.t - since >= _f(tuning, "settle", SETTLE) - EPS:
				ask.set_state(rec, SETTLED)
	rec["k"] = kk

func force(rec: Dictionary, state: StringName, k: Api.Tick, ask: Api.Asks) -> void:
	# Forced flush (the test channel): the same cost as a real one, made by nobody.
	var was := StringName(rec["state"])
	ask.set_state(rec, state)
	if state == FLUSHED and was != FLUSHED:
		ask.noise(rec, Move.Body.make(float(rec["x"]), float(rec["z"]), int(rec["level"]), 0.0), _f(k.tuning, "loud", LOUD), "")
