extends RefCounted

const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Sight = preload("res://sim/sight.gd")

const ITEM := "flare"
const THROW := 4.0
const REACH := 6.0
const STUN := 1.5
const BLIND := 1.0
const NOISE := 24.0
const BURST_SECONDS := 1.0
const TEAMMATE_WIDTH := 0.55

static func within(a: Move.Body, b: Move.Body, radius: float) -> bool:
	return a.level == b.level and Vector2(a.x, a.z).distance_squared_to(Vector2(b.x, b.z)) <= radius * radius

static func clear(plan: Floor.FloorPlan, a: Move.Body, b: Move.Body) -> bool:
	return Sight.has_line_of_sight(plan, Sight.Point3.make(a.x, a.y + 1.0, a.z, a.level),
		Sight.Point3.make(b.x, b.y + 1.0, b.z, b.level))

static func forward(yaw: float) -> Vector2:
	return Vector2(-sin(yaw), -cos(yaw))

static func aim(origin: Move.Body, body: Move.Body, direction: Vector2) -> float:
	var delta := Vector2(body.x - origin.x, body.z - origin.z)
	var along := delta.dot(direction)
	if along <= 0.0 or absf(delta.cross(direction)) > TEAMMATE_WIDTH:
		return INF
	return along
