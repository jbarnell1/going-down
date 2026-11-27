# Dangers (DG0): the floor's danger state and the questions the run asks of it. Pure data and queries, no stepping
# (that is sim/dangers.gd) and no reference to sim/run.gd, so the run can load this file without a cycle.
#
# A run made without dangers has RunState.dangers == null, and every hook in sim/run.gd, net/host.gd and the
# screens is skipped: nothing changes. With dangers on, `dangers` is a DangerFloor: replaced, never edited, like
# every other part of the run's state (copy() first; sim/dangers.gd is the only writer).
extends RefCounted

const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")

const EPS := 1e-9
## Half the thickness of the box a closed door edge puts across its doorway (metres).
const DOOR_HALF := 0.15

class DangerFloor:
	extends RefCounted
	## The enabled kind names (sorted). Never empty: with none enabled the run has no DangerFloor.
	var kinds: Array[StringName] = []
	## Which floor the records belong to: "<day index>:<depth>:<ward 0/1>", "" before the first floor.
	var floor_key := ""
	## The floor's records ({id, kind, x, y, z, level, yaw, state, since, n, k}), in id order.
	var records: Array[Dictionary] = []
	var next_id := 0
	## Host time this floor's doors opened (-1 before).
	var opened_at := -1.0
	## Dark regions: [level, x0, z0, x1, z1, until, record id, from] (dark from host time `from` until `until`).
	var dark: Array = []
	## Closed door edges: [level, ax, ay, bx, by, until, record id].
	var doors: Array = []
	## Kinds' own solid boxes: "<record id>:<key>" -> [level, x0, z0, x1, z1].
	var solids: Dictionary = {}
	## Player effects: id -> {"kind": &"hold" | &"stumble" | &"blind", "until": t, "body": Move.Body (held there, or null)}.
	var fx: Dictionary = {}
	## Pinned players (hung or on a ledge): id -> {"style": &"hang" | &"ledge", "at": Move.Body, "stand": Move.Body, "rec": id}.
	var pins: Dictionary = {}
	## Noises made on the last danger step, heard by the residents on the next run tick: [x, y, z, level, loud, by].
	var heard: Array = []
	## Prompts: [record id, text, reach].
	var prompts: Array = []
	## Test channel: record id -> state to force at the next step.
	var forced: Dictionary = {}
	## Where each player stood at the last step (a kind's "still"): id -> Move.Body.
	var last: Dictionary = {}
	var _solid_base: Move.Solids = null
	var _solid_has_base := false
	var _solid_cache: Move.Solids = null

	func copy() -> DangerFloor:
		var d := DangerFloor.new()
		d.kinds = kinds
		d.floor_key = floor_key
		d.records = records
		d.next_id = next_id
		d.opened_at = opened_at
		d.dark = dark
		d.doors = doors
		d.solids = solids
		d.fx = fx
		d.pins = pins
		d.heard = heard
		d.prompts = prompts
		d.forced = forced
		d.last = last
		# The walk model's boxes stay valid until a writer changes doors or solids (it calls dirty()).
		d._solid_base = _solid_base
		d._solid_has_base = _solid_has_base
		d._solid_cache = _solid_cache
		return d

	func dirty() -> void:
		_solid_cache = null
		_solid_has_base = false
		_solid_base = null

	## Whether there is anything a screen must be told on this floor.
	func showing() -> bool:
		return not (records.is_empty() and dark.is_empty() and doors.is_empty() and solids.is_empty() and fx.is_empty() and pins.is_empty())

## The body the rules hold player `id` at this tick (a pin, or a hold or stumble still running), or null.
static func held_body(d: DangerFloor, id: String, t: float) -> Move.Body:
	if d == null:
		return null
	if d.pins.has(id):
		return (d.pins[id] as Dictionary)["at"]
	var f: Variant = d.fx.get(id)
	if f is Dictionary and (f["kind"] == &"hold" or f["kind"] == &"stumble") and t < float(f["until"]) - EPS and f["body"] != null:
		return f["body"]
	return null

## Whether player `id` is blinded by a danger at host time `t`.
static func blinded(d: DangerFloor, id: String, t: float) -> bool:
	if d == null:
		return false
	var f: Variant = d.fx.get(id)
	return f is Dictionary and f["kind"] == &"blind" and t < float(f["until"]) - EPS

## Whether (level, x, z) is inside a danger dark region at host time `t`.
static func dark_at(d: DangerFloor, level: int, x: float, z: float, t: float) -> bool:
	if d == null:
		return false
	for r: Array in d.dark:
		if int(r[0]) == level and t < float(r[5]) - EPS and t >= float(r[7]) - EPS and x >= float(r[1]) - EPS and x <= float(r[3]) + EPS and z >= float(r[2]) - EPS and z <= float(r[4]) + EPS:
			return true
	return false

## The box a closed edge puts across its doorway: [x0, z0, x1, z1] (metres).
static func edge_box(cell_size: float, ax: int, ay: int, bx: int, by: int) -> PackedFloat64Array:
	if ay == by:
		# Side by side: the wall line is x = max(ax, bx) * cell, along z over the row.
		var wx := float(maxi(ax, bx)) * cell_size
		return PackedFloat64Array([wx - DOOR_HALF, float(ay) * cell_size, wx + DOOR_HALF, float(ay + 1) * cell_size])
	var wz := float(maxi(ay, by)) * cell_size
	return PackedFloat64Array([float(ax) * cell_size, wz - DOOR_HALF, float(ax + 1) * cell_size, wz + DOOR_HALF])

## Whether a straight line from (ax, az) to (bx, bz) on `level` crosses a closed door edge (sight, company).
static func line_blocked(d: DangerFloor, level: int, ax: float, az: float, bx: float, bz: float, cell_size: float) -> bool:
	if d == null or d.doors.is_empty():
		return false
	for e: Array in d.doors:
		if int(e[0]) != level:
			continue
		var box := edge_box(cell_size, int(e[1]), int(e[2]), int(e[3]), int(e[4]))
		if _segment_hits_box(ax, az, bx, bz, box):
			return true
	return false

## Whether a Stillness resident at `res` is unseen by an eye at `eye` because of a danger: it stands in a dark
## region (as in a blink), or a closed door edge is between them.
static func hides_resident(d: DangerFloor, res: Move.Body, eye: Move.Body, t: float, cell_size: float) -> bool:
	if d == null or res == null:
		return false
	if dark_at(d, res.level, res.x, res.z, t):
		return true
	return eye != null and eye.level == res.level and line_blocked(d, res.level, eye.x, eye.z, res.x, res.z, cell_size)

## The walk model's boxes: `base` (the floor's furniture, or null) plus every closed door and kind solid. Returns
## `base` itself when there are none, so a floor without danger solids walks exactly as before.
static func solids_with(d: DangerFloor, plan: Floor.FloorPlan, base: Move.Solids) -> Move.Solids:
	if d == null or plan == null or (d.doors.is_empty() and d.solids.is_empty()):
		return base
	if d._solid_cache != null and d._solid_has_base and d._solid_base == base:
		return d._solid_cache
	var s := Move.Solids.new()
	s.cell_size = float(plan.cell_size)
	if base != null:
		for level in 2:
			var b: PackedFloat64Array = base.boxes[level]
			for i in b.size() / 4:
				s.add(level, b[i * 4], b[i * 4 + 1], b[i * 4 + 2], b[i * 4 + 3])
	for e: Array in d.doors:
		var box := edge_box(float(plan.cell_size), int(e[1]), int(e[2]), int(e[3]), int(e[4]))
		s.add(int(e[0]), box[0], box[1], box[2], box[3])
	var keys: Array = d.solids.keys()
	keys.sort()
	for key: String in keys:
		var r: Array = d.solids[key]
		s.add(int(r[0]), float(r[1]), float(r[2]), float(r[3]), float(r[4]))
	d._solid_base = base
	d._solid_has_base = true
	d._solid_cache = s
	return s

static func _segment_hits_box(ax: float, az: float, bx: float, bz: float, box: PackedFloat64Array) -> bool:
	# Liang-Barsky clip of the segment against the box.
	var t0 := 0.0
	var t1 := 1.0
	var dx := bx - ax
	var dz := bz - az
	var p := [-dx, dx, -dz, dz]
	var q := [ax - box[0], box[2] - ax, az - box[1], box[3] - az]
	for i in 4:
		if absf(p[i]) < EPS:
			if q[i] < 0.0:
				return false
		else:
			var r: float = q[i] / p[i]
			if p[i] < 0.0:
				t0 = maxf(t0, r)
			else:
				t1 = minf(t1, r)
			if t0 > t1:
				return false
	return true

# ---------------------------------------------------------------------------------------------
# The screens: a DangerFloor holding only what the walk model needs, from the world's "dangers" block.

## A DangerFloor for a screen's walk model (net/session.gd move_local): the closed doors and solids of the block.
static func from_block(block: Variant) -> DangerFloor:
	if not block is Dictionary:
		return null
	var d := DangerFloor.new()
	var doors: Array = []
	for e: Variant in (block as Dictionary).get("doors", []):
		doors.append([int(e[0]), int(e[1]), int(e[2]), int(e[3]), int(e[4]), float(e[5]), -1])
	d.doors = doors
	var solids := {}
	var k := 0
	for e: Variant in (block as Dictionary).get("solids", []):
		solids["s:%d" % k] = [int(e[0]), float(e[1]), float(e[2]), float(e[3]), float(e[4])]
		k += 1
	d.solids = solids
	return d
