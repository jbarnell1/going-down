# Shared continuous footing for the Ward. Horizontal coordinates match the rendered decks in metres.
extends RefCounted

const Layout = preload("res://sim/ward/layout.gd")
const DECK_WIDTH := 1.40
const JOINT_WIDTH := 1.44
const END_OVERHANG := 0.06
const EDGE_CLEARANCE := 0.14
const HEIGHT_TOLERANCE := 0.21
const WALK_STEP := 0.07
const MAX_STEP_UP := 0.22

var layout: Dictionary
var lift_door: Vector3
var spans: Array[Dictionary] = []

func _init(floor_layout: Dictionary, door: Vector3) -> void:
	layout = floor_layout
	lift_door = door
	for edge: Dictionary in layout.bridges:
		var path: Array = edge.path
		for i in range(1, path.size()):
			spans.append({"from": path_point(path[i - 1]), "to": path_point(path[i]),
				"joint": i < path.size() - 1, "shortcut": edge.kind == "winch"})

static func path_point(raw: Array) -> Vector3:
	return Vector3(raw[0], raw[2], raw[1])

## Infinity means there is no standing surface. Joins keep the actual deck height.
func height_at(at: Vector2, shortcut_lowered: bool) -> float:
	var best := -INF
	var lift := Vector2(lift_door.x, lift_door.z)
	if absf(at.x - lift.x) <= 0.675 - EDGE_CLEARANCE and at.y >= lift.y - 3.0 + EDGE_CLEARANCE and at.y <= lift.y + 0.04:
		best = lift_door.y - 0.01
	for house: Dictionary in layout.houses:
		var relative := (at - Vector2(house.x, house.y)).abs()
		var half := Vector2(float(house.w), float(house.d)) * 0.5
		if relative.x <= half.x and relative.y <= half.y:
			best = maxf(best, float(house.z))
		elif relative.x <= half.x + Layout.GALLERY - EDGE_CLEARANCE and relative.y <= half.y + Layout.GALLERY - EDGE_CLEARANCE:
			best = maxf(best, float(house.z) + 0.15)
	for span in spans:
		if span.shortcut and not shortcut_lowered:
			continue
		var p: Vector3 = span.from
		var q: Vector3 = span.to
		var from := Vector2(p.x, p.z)
		var to := Vector2(q.x, q.z)
		var direction := (to - from).normalized()
		var along := (at - from).dot(direction)
		var length := from.distance_to(to)
		var side := absf((at - from).cross(direction))
		if along >= -END_OVERHANG - EDGE_CLEARANCE and along <= length + END_OVERHANG + EDGE_CLEARANCE and side <= DECK_WIDTH * 0.5 - EDGE_CLEARANCE:
			best = maxf(best, lerpf(p.y, q.y, clampf(along / length, 0.0, 1.0)))
		if span.joint:
			var delta := (at - to).abs()
			if delta.x <= JOINT_WIDTH * 0.5 - EDGE_CLEARANCE and delta.y <= JOINT_WIDTH * 0.5 - EDGE_CLEARANCE:
				best = maxf(best, q.y - 0.005)
	return best if best != -INF else INF

func route_supported(from: Vector3, to: Vector3, shortcut_lowered: bool) -> bool:
	var begin := Vector2(from.x, from.z)
	var end := Vector2(to.x, to.z)
	var steps := maxi(1, ceili(begin.distance_to(end) / WALK_STEP))
	var previous := height_at(begin, shortcut_lowered)
	if not is_finite(previous) or absf(previous - from.y) > HEIGHT_TOLERANCE:
		return false
	for i in range(1, steps + 1):
		var next := height_at(begin.lerp(end, float(i) / steps), shortcut_lowered)
		if not is_finite(next) or absf(next - previous) > MAX_STEP_UP:
			return false
		previous = next
	return absf(previous - to.y) <= HEIGHT_TOLERANCE