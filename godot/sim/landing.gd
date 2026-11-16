# Where the elevator is at the landing, and which way a player faces stepping out of it.
# Port of src/sim/landing.ts.
extends RefCounted

const Floor = preload("res://sim/floor.gd")
const Walls = preload("res://sim/walls.gd")

const DIRS: Array[StringName] = [&"n", &"e", &"s", &"w"]

## The side of the landing cell the elevator doors are on: a walled side whose opposite side opens
## into the floor, so stepping out of the elevator walks you straight in. &"" if no side is walled
## (TypeScript: null).
static func elevator_wall(plan: Floor.FloorPlan) -> StringName:
	var level := plan.landing.level
	var x := plan.landing.x
	var y := plan.landing.y
	var fallback := &""
	for d in DIRS:
		var dx := Floor.dir_dx(d)
		var dy := Floor.dir_dy(d)
		if Walls.edge_kind(plan, level, x, y, x + dx, y + dy) != Walls.WALL:
			continue
		if fallback == &"":
			fallback = d
		if Floor.is_walkable(plan, level, x - dx, y - dy):
			return d
	return fallback

## The direction a player faces stepping out of the elevator.
static func landing_facing(plan: Floor.FloorPlan) -> StringName:
	var wall := elevator_wall(plan)
	var opposite := {&"n": &"s", &"e": &"w", &"s": &"n", &"w": &"e"}
	return opposite[wall] if wall != &"" else &"n"
