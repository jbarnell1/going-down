# OR2, the owner's 20 Nov playtest of the Clinic: where the Orderlies start. Only for a run made with the Orderly fix
# (sim/run.gd with_orderly_fix; net/host_rules.gd orderly_fix, the last parameter). Off, nothing here is called.
#
# The owner: "Seems like the orderlies have spawned in the same place the past couple of times I have played the
# hospital and are spawning in the clean part of the hospital, not the dirty part."
#
# The Clinic's two sides (North Star A2, V5) are the walking distance from the lift: the client draws a cell clean at
# 0 and fully corrupted at the farthest walkable cell (client/level.gd corruption, from Floor.distances_from the
# landing). The dirty part here is every walkable cell at least `dirty_from` of that farthest distance (the live
# setting orderly.dirty_from, in 100; today's DIRTY_FROM). The starts are:
#   - walkable, in the dirty part, never a barred cell (sim/relocate.gd barred: hide spots, the lobby, the landing,
#     the car's zone, stairs), and out of view of the landing (sim/relocate.gd out_of_view);
#   - picked by a seeded shuffle, Rng "orderly_fix:<seed>:<depth>", so every screen agrees and another seed starts
#     them elsewhere;
#   - the second at least SECOND_APART metres by walking from the first (relaxed to SECOND_APART_MIN, then any
#     other cell), never the first's cell.
# Nothing passes (a floor without a dirty part out of view): the dirty part without the view test; still nothing:
# null, and the caller keeps today's start.
extends RefCounted

const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Entity = preload("res://sim/entity.gd")
const Relocate = preload("res://sim/relocate.gd")
const Rng = preload("res://sim/rng.gd")

## Today's dirty part: from 60 in 100 of the walk from the lift to the farthest cell.
const DIRTY_FROM := 60
## The second Orderly's start, metres by walking from the first's (then relaxed).
const SECOND_APART := 16.0
const SECOND_APART_MIN := 8.0
const EPS := 1e-9

## How dirty a cell is, 0 at the lift to 1 at the farthest walkable cell (the client's corruption), or -1 off the walk.
static func dirt(plan: Floor.FloorPlan, p: Floor.Pos) -> float:
	var dist := Floor.distances_from(plan, plan.landing)
	var far := 0
	for d in dist:
		far = maxi(far, d)
	var d := dist[Floor.pos_index(plan, p)]
	return -1.0 if d < 0 or far <= 0 else float(d) / float(far)

## The starts of `count` (1 or 2) Orderlies on `plan` (see the header), or [] for none. `car`: the car's floor as
## [x0, z0, x1, z1] on `car_level`; `dirty_from`: in 100.
static func starts(plan: Floor.FloorPlan, seed: String, depth: int, car: PackedFloat64Array, car_level: int, count: int, dirty_from: float) -> Array[Floor.Pos]:
	var out: Array[Floor.Pos] = []
	var dist := Floor.distances_from(plan, plan.landing)
	var far := 0
	for d in dist:
		far = maxi(far, d)
	if far <= 0:
		return out
	var bars := Relocate.barred(plan, seed, car, car_level)
	var cands: Array[int] = []
	for i in dist.size():
		if dist[i] < 0 or float(dist[i]) < dirty_from / 100.0 * float(far) - EPS or bars.has(i):
			continue
		var p := Floor.pos_from_index(plan, i)
		if Floor.is_walkable(plan, p.level, p.x, p.y):
			cands.append(i)
	if cands.is_empty():
		return out
	var rng := Rng.make_rng("orderly_fix:%s:%d" % [seed, depth])
	for n in cands.size():
		var j := rng.int_in(n, cands.size() - 1)
		var c := cands[j]
		cands[j] = cands[n]
		cands[n] = c
	var at := Move.body_at_cell(plan, plan.landing)
	var eyes: Array[Relocate.Eye] = [Relocate.Eye.make("#landing", at, 1.65, plan.landing, false)]
	var k := Entity.orderly_body()
	var unseen: Array[int] = []
	for c in cands:
		if Relocate.out_of_view(plan, eyes, Move.body_at_cell(plan, Floor.pos_from_index(plan, c)), k):
			unseen.append(c)
	var pool := unseen if not unseen.is_empty() else cands
	var first := pool[0]
	out.append(Floor.pos_from_index(plan, first))
	if count < 2:
		return out
	var from_first := Floor.distances_from(plan, Floor.pos_from_index(plan, first))
	var cs := float(plan.cell_size)
	for apart: float in [SECOND_APART, SECOND_APART_MIN, cs]:
		for c in pool:
			if c != first and from_first[c] >= 0 and float(from_first[c]) * cs >= apart - EPS:
				out.append(Floor.pos_from_index(plan, c))
				return out
	return out
