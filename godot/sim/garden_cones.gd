extends RefCounted

const Arboretum = preload("res://sim/arboretum.gd")
const Floor = preload("res://sim/floor.gd")
const Furniture = preload("res://sim/furniture.gd")
const Move = preload("res://sim/move.gd")
const Rng = preload("res://sim/rng.gd")

const ITEM := "pinecone"
const RANGE := 12.0
const SPEED := 18.0
const CLEARANCE := 0.08
const TRACE_STEP := 0.04

## One candidate per litter cell with a conifer. Reserve the closest for a crew just off the lift.
static func placements(plan: Floor.FloorPlan) -> Array[Move.Body]:
	var points: Array[Move.Body] = []
	if Arboretum.garden_of(plan) == null:
		return points
	var solids := Furniture.solids_of(plan)
	var reaches := Floor.distances_from(plan, plan.landing)
	var cells := {}
	var closest := -1
	var best := 1 << 30
	for tree in Furniture.pieces_for(plan):
		if tree.kind != &"trunk" or not Arboretum.is_conifer(tree.x, tree.y):
			continue
		var x: int = tree.x / 200
		var z: int = tree.y / 200
		var cell := z * Arboretum.W + x
		var px := x * 2.0 + 1.0
		var pz := z * 2.0 + 1.0
		if cells.has(cell) or reaches[cell] < 0 or not Move.clear_at(plan, solids, 0, px, pz, 0.28):
			continue
		cells[cell] = true
		if reaches[cell] < best:
			best = reaches[cell]
			closest = points.size()
		points.append(Move.Body.make(px, pz, 0, 0.0))
	if closest < 0:
		return points
	var rng := Rng.make_rng("arboretum-cones:%s:%d" % [plan.seed, plan.depth])
	var count := mini(points.size(), rng.int_in(10, 16))
	var chosen: Array[Move.Body] = [points.pop_at(closest)]
	while chosen.size() < count:
		chosen.append(points.pop_at(rng.int_in(0, points.size() - 1)))
	return chosen

## Stop at the first collision along the aim ray. Each open landing is on the same floor as the thrower.
static func landing(plan: Floor.FloorPlan, solids: Move.Solids, start: Move.Body, yaw: float, pitch: float) -> Move.Body:
	var dx := -sin(yaw)
	var dz := -cos(yaw)
	var reach := RANGE * cos(pitch)
	var at := start
	var steps := maxi(1, ceili(reach / TRACE_STEP))
	for step in range(1, steps + 1):
		var d := reach * step / steps
		var x := start.x + d * dx
		var z := start.z + d * dz
		if not Move.clear_at(plan, solids, start.level, x, z, CLEARANCE):
			break
		at = Move.Body.make(x, z, start.level, start.y)
	return at
