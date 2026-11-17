# The floor as the client builds and the test hook shows it: the plan itself (Floor.plan_to_plain)
# plus what drawing needs and must not compute itself: the wall edges, the elevator wall, the landing's
# facing, the car, and the walking distance from the lift (the clean-to-corrupted gradient). The same
# dictionary rules_bridge.gd's planDump makes (that copy now serves only the bridge's own test).
extends RefCounted

const Run = preload("res://sim/run.gd")
const Floor = preload("res://sim/floor.gd")
const Landing = preload("res://sim/landing.gd")
const Walls = preload("res://sim/walls.gd")

static func dump(p: Floor.FloorPlan, car: Run.CarGeometry) -> Dictionary:
	var w := p.width
	var h := p.height
	var edges: Array = []
	for level in 2:
		var vertical: Array = []
		for y in h:
			for x in w + 1:
				vertical.append(String(Walls.west_edge(p, level, x, y)))
		var horizontal: Array = []
		for y in h + 1:
			for x in w:
				horizontal.append(String(Walls.north_edge(p, level, x, y)))
		edges.append({"vertical": vertical, "horizontal": horizontal})
	var lift_dist: Array = []
	for v: int in Floor.distances_from(p, p.landing):
		lift_dist.append(v)
	var out := Floor.plan_to_plain(p)
	out["edges"] = edges
	var wall := Landing.elevator_wall(p)
	out["elevatorWall"] = null if wall == &"" else String(wall)
	out["landingFacing"] = String(Landing.landing_facing(p))
	out["car"] = car_plain(car)
	out["liftDist"] = lift_dist
	return out

static func rect_plain(r: Run.Rect) -> Dictionary:
	return {"x0": r.x0, "z0": r.z0, "x1": r.x1, "z1": r.z1}

static func car_plain(c: Run.CarGeometry) -> Dictionary:
	return {"wall": String(c.wall), "level": c.level, "floorY": c.floor_y, "doorX": c.door_x, "doorZ": c.door_z, "inX": c.in_x, "inZ": c.in_z,
		"rightX": c.right_x, "rightZ": c.right_z, "width": c.width, "depth": c.depth, "doorWidth": c.door_width,
		"rect": rect_plain(c.rect), "bank": rect_plain(c.bank), "down": rect_plain(c.down)}
