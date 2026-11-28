# The Clinic's failing lights: a run of ceiling strips on the far side with a bad ballast. Rules only.
#
# What it is. A circuit is one straight stretch of corridor (`length` cells along, or one or two fewer where
# furniture or a hide leaves no full stretch; the hall's whole width across), far from the lift, with no doorway, stair or balcony opening onto its sides. It runs on host time
# from the moment the arrival doors open, the same for every player:
#   lit  (`lit` seconds in all, its last `warn` of them the wind-down, sent as its own state) -> dark (`dark`
#   seconds) -> lit again, round and round. Nothing sets it off. The lift's blink or
#   blackout holds it lit (no wind-down starts while the floor is dark); it carries on from the first lit tick after.
# The one thing it does: while a circuit is dark, its core is a dark region (Asks.dark): a Stillness resident
# standing in it is unseen by everyone, exactly as in the lift's blink. The core is the stretch less
# MARGIN metres at each open end, so a resident still half in the light beside the run is never counted as
# in the dark. It makes no noise the rules hear, holds nobody and never takes anyone down.
#
# Heard first: the wind-down (`warn`, never under 1 s) always comes before the dark, and the strip hums
# where it hangs the whole time it is lit.
# Careful players: the dark blocks nothing; every circuit lies on a loop (with all its cells shut, every
# other cell is still reachable from the landing), so going round always exists; and its lit beat leaves a
# walker time to cross it with a second to spare.
#
# Timings are stamped at the start of each cycle (a host's change takes hold at the next cycle); the place
# and count settings are read once, at placement.
extends "res://sim/dangers/kind.gd"

const Floor = preload("res://sim/floor.gd")
const Walls = preload("res://sim/walls.gd")
const Settings = preload("res://sim/settings.gd")
const Move = preload("res://sim/move.gd")

const LIT := &"lit"
const WARN := &"warn"
const DARK := &"dark"

## The live settings' today values (the fallbacks the rules read with).
const LIT_S := 9.0
const WARN_S := 1.5
const DARK_S := 2.5
const LENGTH := 5
const COUNT := 2
const FIRST_COUNT := 1
const APART_M := 16.0
const FROM := 60.0
## How far the dark core stops short of each open end of the stretch (m): a resident's centre must stand
## this far in before it counts as in the dark (Entity.SEEN_RADIUS_WALK, 1.1 m). Fairness, so never a setting.
const MARGIN := 1.1
## The warning is never shorter than this (the heard-first rule), whatever a host asks.
const WARN_MIN := 1.0
## The first wind-down of a floor comes no sooner than this after the doors open (s), and its offset in the
## cycle is drawn from the kind's own generator.
const FIRST_AFTER := 4.0
## How far the corridor must run straight on past at least one end of a circuit (cells): the first meeting is
## down a hall, seen and heard from a distance.
const APPROACH := 3
## A walker's speed for the lit-beat check (m/s: a walk; Move's walk is faster) and the spare second.
const CROSS_SPEED := 3.0
const CROSS_SPARE := 1.0
## Keep this far from other kinds' records (m).
const OTHERS_M := 8.0
const LH := 3.2

func kind_name() -> StringName:
	return &"failing_lights"

func states() -> Array[StringName]:
	return [LIT, WARN, DARK]

# --- the settings, clamped where a rule needs it ------------------------------------------------------

static func timings(tuning: Settings.Values) -> Vector3:
	var dark_max := Settings.f(tuning, &"danger.dark_max", 10.0)
	var warn := maxf(WARN_MIN, Settings.f(tuning, &"danger.failing_lights.warn", WARN_S))
	var lit := maxf(warn + 1.0, Settings.f(tuning, &"danger.failing_lights.lit", LIT_S))
	var dark := clampf(Settings.f(tuning, &"danger.failing_lights.dark", DARK_S), 0.5, dark_max)
	return Vector3(lit, warn, dark)

# --- placement ---------------------------------------------------------------------------------------

func place(p: Api.Place) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if p.plan == null or p.place != &"clinic":
		return out
	var plan := p.plan
	var length := clampi(Settings.i(p.tuning, &"danger.failing_lights.length", LENGTH), 3, 8)
	var want := Settings.i(p.tuning, &"danger.failing_lights.first_count" if p.depth <= 1 else &"danger.failing_lights.count",
		FIRST_COUNT if p.depth <= 1 else COUNT)
	if want <= 0:
		return out
	var apart := Settings.f(p.tuning, &"danger.failing_lights.apart", APART_M)
	var from := Settings.f(p.tuning, &"danger.failing_lights.from", FROM) / 100.0
	var t := timings(p.tuning)
	var far := 0
	for d in p.lift_steps:
		far = maxi(far, d)
	# The full length first; where furniture, a hide or a doorway leaves no such stretch, a cell or two shorter (never
	# under 3 cells), so nearly every floor gets its run.
	var chosen: Array[Dictionary] = []
	for l in range(length, maxi(3, length - 2) - 1, -1):
		if chosen.size() >= want:
			break
		var cands := candidates(plan, p.lift_steps, ceili(from * far), l)
		# The kind's own generator orders them; nothing else is drawn.
		for i in range(cands.size() - 1, 0, -1):
			var j := p.rng.int_in(0, i)
			var tmp: Variant = cands[i]
			cands[i] = cands[j]
			cands[j] = tmp
		for c: Dictionary in cands:
			if chosen.size() >= want:
				break
			if not _clear(p, c) or not _apart(plan, c, chosen, apart) or not _far_from_others(p, c):
				continue
			if not on_loop(plan, c["cells"]):
				continue
			chosen.append(c)
	var cs := float(plan.cell_size)
	for c: Dictionary in chosen:
		var along_x: bool = c["axis"] == &"h"
		var x0: float = c["x0"] * cs
		var z0: float = c["y0"] * cs
		var x1: float = (c["x1"] + 1) * cs
		var z1: float = (c["y1"] + 1) * cs
		var len_m := (x1 - x0) if along_x else (z1 - z0)
		var wid_m := (z1 - z0) if along_x else (x1 - x0)
		# The dark core: the stretch less MARGIN at each open end (the sides are walls).
		var core: Array = [x0 + MARGIN, z0, x1 - MARGIN, z1] if along_x else [x0, z0 + MARGIN, x1, z1 - MARGIN]
		var period := t.x + t.z
		var offset := p.rng.next() * period
		out.append({
			"x": (x0 + x1) / 2.0, "y": c["level"] * LH, "z": (z0 + z1) / 2.0, "level": int(c["level"]),
			"yaw": 0.0 if along_x else PI / 2.0, "state": LIT,
			# n (sent): length and width (m), the core's half length (m), this cycle's lit, warn and dark (s).
			"n": [len_m, wid_m, len_m / 2.0 - MARGIN, t.x, t.y, t.z],
			"k": {"core": core, "cells": c["cells"], "offset": offset, "next": -1.0,
				"lit": t.x, "warn": t.y, "dark": t.z},
		})
	return out

## Every straight stretch that may hold a circuit, in a fixed order: {axis, level, x0, y0, x1, y1, cells}.
## `cells` are [level, x, y] of the whole band (every row across). The rules for a stretch:
##   - `length` positions along, each a band of corridor cells of the same 1 or 2 across;
##   - every cell at least `min_steps` from the landing by walking;
##   - nothing walkable opens onto it except along its own line past its two ends: no doorway, no stair foot,
##     no balcony rail on its sides (a lit room or the lit atrium would light its middle);
##   - the corridor runs on straight for APPROACH cells past at least one end.
static func candidates(plan: Floor.FloorPlan, lift_steps: PackedInt32Array, min_steps: int, length: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for level in 2:
		for axis: StringName in [&"h", &"v"]:
			var lines := plan.height if axis == &"h" else plan.width
			var alongs := plan.width if axis == &"h" else plan.height
			for line in lines:
				for a0 in range(0, alongs - length + 1):
					var c := _stretch(plan, lift_steps, min_steps, level, axis, line, a0, length)
					if not c.is_empty():
						out.append(c)
	return out

static func _xy(axis: StringName, along: int, across: int) -> Vector2i:
	return Vector2i(along, across) if axis == &"h" else Vector2i(across, along)

static func _corridor(plan: Floor.FloorPlan, level: int, v: Vector2i) -> bool:
	return Floor.cell_at(plan, level, v.x, v.y) == Floor.CORRIDOR

static func _stretch(plan: Floor.FloorPlan, lift_steps: PackedInt32Array, min_steps: int, level: int, axis: StringName,
		line: int, a0: int, length: int) -> Dictionary:
	# The band across at the first position: `line` must be its first row, 1 or 2 rows.
	if not _corridor(plan, level, _xy(axis, a0, line)) or _corridor(plan, level, _xy(axis, a0, line - 1)):
		return {}
	var width := 2 if _corridor(plan, level, _xy(axis, a0, line + 1)) else 1
	if width == 2 and _corridor(plan, level, _xy(axis, a0, line + 2)):
		return {}
	var band := {}
	var cells: Array = []
	for a in range(a0, a0 + length):
		# The same band at every position: corridor across `width` rows, not corridor just outside.
		if _corridor(plan, level, _xy(axis, a, line - 1)) or _corridor(plan, level, _xy(axis, a, line + width)):
			return {}
		for w in width:
			var v := _xy(axis, a, line + w)
			if not _corridor(plan, level, v):
				return {}
			var pi := Floor.pos_index(plan, Floor.Pos.make(level, v.x, v.y))
			if lift_steps[pi] < min_steps:
				return {}
			band[pi] = true
			cells.append([level, v.x, v.y])
	# Nothing opens onto its sides; past its ends only along its own line.
	for cell: Array in cells:
		var here := Floor.Pos.make(level, cell[1], cell[2])
		var al: int = cell[1] if axis == &"h" else cell[2]
		for st in Floor.STEPS:
			var nx: int = cell[1] + st.x
			var ny: int = cell[2] + st.y
			if Walls.edge_kind(plan, level, cell[1], cell[2], nx, ny) == Walls.RAIL:
				return {}
		for nb in Floor.neighbours(plan, here):
			if band.has(Floor.pos_index(plan, nb)):
				continue
			var nal := nb.x if axis == &"h" else nb.y
			var nac := nb.y if axis == &"h" else nb.x
			var past_end: bool = nb.level == level and nac == (cell[2] if axis == &"h" else cell[1]) \
				and ((al == a0 and nal == a0 - 1) or (al == a0 + length - 1 and nal == a0 + length))
			if not past_end:
				return {}
	# The approach: the hall runs straight on for APPROACH cells past one end (its first row at least).
	var ok := false
	for dirn: int in [-1, 1]:
		var run := 0
		var a := a0 - 1 if dirn < 0 else a0 + length
		while run < APPROACH and _corridor(plan, level, _xy(axis, a, line)):
			run += 1
			a += dirn
		if run >= APPROACH:
			ok = true
	if not ok:
		return {}
	var first := _xy(axis, a0, line)
	var last := _xy(axis, a0 + length - 1, line + width - 1)
	return {"axis": axis, "level": level, "x0": mini(first.x, last.x), "y0": mini(first.y, last.y),
		"x1": maxi(first.x, last.x), "y1": maxi(first.y, last.y), "cells": cells}

## With every cell of the stretch shut, every other walkable cell is still reachable from the landing.
static func on_loop(plan: Floor.FloorPlan, cells: Array) -> bool:
	var shut := {}
	for c: Array in cells:
		shut[Floor.pos_index(plan, Floor.Pos.make(c[0], c[1], c[2]))] = true
	var all := Floor.distances_from(plan, plan.landing)
	var adj := Floor.adjacency_of(plan)
	var seen := PackedByteArray()
	seen.resize(all.size())
	var queue := PackedInt32Array()
	var first := Floor.pos_index(plan, plan.landing)
	queue.append(first)
	seen[first] = 1
	var head := 0
	while head < queue.size():
		var pi := queue[head]
		head += 1
		for k in range(adj.start[pi], adj.start[pi + 1]):
			var qi := adj.list[k]
			if seen[qi] == 1 or shut.has(qi):
				continue
			seen[qi] = 1
			queue.append(qi)
	for i in all.size():
		if all[i] >= 0 and not shut.has(i) and seen[i] == 0:
			return false
	return true

func _clear(p: Api.Place, c: Dictionary) -> bool:
	var cs := float(p.plan.cell_size)
	for cell: Array in c["cells"]:
		if not p.clear(int(cell[0]), (cell[1] + 0.5) * cs, (cell[2] + 0.5) * cs, 0.3):
			return false
	return true

static func _centre_cell(c: Dictionary) -> Floor.Pos:
	var cells: Array = c["cells"]
	var mid: Array = cells[cells.size() / 2]
	return Floor.Pos.make(mid[0], mid[1], mid[2])

func _apart(plan: Floor.FloorPlan, c: Dictionary, chosen: Array[Dictionary], apart: float) -> bool:
	if chosen.is_empty():
		return true
	var d := Floor.distances_from(plan, _centre_cell(c))
	for o: Dictionary in chosen:
		for cell: Array in o["cells"]:
			var steps := d[Floor.pos_index(plan, Floor.Pos.make(cell[0], cell[1], cell[2]))]
			if steps >= 0 and steps * plan.cell_size < apart:
				return false
	return true

func _far_from_others(p: Api.Place, c: Dictionary) -> bool:
	var cs := float(p.plan.cell_size)
	var mid := _centre_cell(c)
	for o: Dictionary in p.taken:
		if int(o["level"]) == mid.level and Vector2(float(o["x"]) - (mid.x + 0.5) * cs, float(o["z"]) - (mid.y + 0.5) * cs).length() < OTHERS_M:
			return false
	return true

# --- each tick ---------------------------------------------------------------------------------------

func step(rec: Dictionary, k: Api.Tick, ask: Api.Asks) -> void:
	var kk: Dictionary = rec["k"]
	if k.floor_t < 0.0:
		return
	if float(kk["next"]) < 0.0:
		# The floor's first cycle: lit, then the first wind-down at the circuit's own offset in the cycle,
		# never sooner than FIRST_AFTER after the doors open.
		var lead := float(kk["lit"]) - float(kk["warn"])
		var period := float(kk["lit"]) + float(kk["dark"])
		var first := fposmod(lead - float(kk["offset"]), period)
		while first < FIRST_AFTER:
			first += period
		kk["next"] = k.t - k.floor_t + first
	if k.t + 1e-6 < float(kk["next"]):
		return
	var state: StringName = rec["state"]
	if state == LIT:
		# The lift's blink or blackout holds the beat: no wind-down starts while the floor is dark, so a warning is
		# never half lost in the blink; it starts, whole, at the first lit tick after it (the beat shifts by that).
		if not k.lit(int(rec["level"]), float(rec["x"]), float(rec["z"])):
			kk["next"] = k.t + k.dt
			return
		ask.set_state(rec, WARN)
		kk["next"] = float(kk["next"]) + float(kk["warn"])
		# The dark is announced now, from the warning's end, so every screen darkens at the same host time.
		var core: Array = kk["core"]
		ask.dark(rec, int(rec["level"]), core[0], core[1], core[2], core[3], float(kk["next"]) + float(kk["dark"]), float(kk["next"]))
	elif state == WARN:
		ask.set_state(rec, DARK)
		kk["next"] = float(kk["next"]) + float(kk["dark"])
	else:
		# Lit again: this cycle's numbers are stamped now (a host's change holds from here).
		var t := timings(k.tuning)
		kk["lit"] = t.x
		kk["warn"] = t.y
		kk["dark"] = t.z
		var n: Array = rec["n"]
		n[3] = t.x
		n[4] = t.y
		n[5] = t.z
		ask.set_state(rec, LIT)
		kk["next"] = float(kk["next"]) + t.x - t.y

## The test channel: forcing a state starts that state's clock now, from this cycle's numbers.
func force(rec: Dictionary, state: StringName, k: Api.Tick, ask: Api.Asks) -> void:
	var kk: Dictionary = rec["k"]
	ask.set_state(rec, state)
	if state == LIT:
		kk["next"] = k.t + float(kk["lit"]) - float(kk["warn"])
	elif state == WARN:
		kk["next"] = k.t + float(kk["warn"])
		var c: Array = kk["core"]
		ask.dark(rec, int(rec["level"]), c[0], c[1], c[2], c[3], float(kk["next"]) + float(kk["dark"]), float(kk["next"]))
	elif state == DARK:
		var core: Array = kk["core"]
		kk["next"] = k.t + float(kk["dark"])
		ask.dark(rec, int(rec["level"]), core[0], core[1], core[2], core[3], kk["next"])
