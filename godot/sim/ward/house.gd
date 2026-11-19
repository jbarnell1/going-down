extends RefCounted

const ArmSearch = preload("res://sim/ward/arm.gd")
const HEIGHT := 3.05
const ARM_HEIGHT := 1.25
const WALL_THICKNESS := 0.14
const OPENING_HEIGHT := 2.19

var floor_bounds: Rect2
var walls: Array[AABB] = []
var door: AABB
var shoulder := Vector3(0.0, ARM_HEIGHT, -0.6)
var areas: Dictionary = {}
var room_doors := PackedVector3Array()
var _guides := PackedVector3Array()
var _seed: int
var _transform: Transform3D

func _init(house: Dictionary, ward_seed: int) -> void:
	_seed = ward_seed * 31 + int(house.id) * 997
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed
	var parlour: bool = house.id == 0
	var width := float(house.d) if parlour else float(house.w)
	var depth := float(house.w) if parlour else float(house.d)
	var origin := Vector3(house.x, house.z, house.y)
	if parlour:
		origin.x += depth * 0.5
		_transform = Transform3D(Basis(Vector3.UP, -PI * 0.5), origin)
	else:
		origin.z -= depth * 0.5
		_transform = Transform3D(Basis.IDENTITY, origin)
	var half := width * 0.5
	var wall := WALL_THICKNESS
	floor_bounds = Rect2(-half, 0.0, width, depth)

	var entry_width := 1.24 if parlour else 1.06
	_partition(0.0, half, 0.0, entry_width)
	door = AABB(
		Vector3(-entry_width * 0.5, 0.0, -wall * 0.5),
		Vector3(entry_width, OPENING_HEIGHT, wall))
	walls.append(AABB(Vector3(-half - wall, 0.0, 0.0), Vector3(wall, HEIGHT, depth)))
	walls.append(AABB(Vector3(half, 0.0, 0.0), Vector3(wall, HEIGHT, depth)))
	walls.append(AABB(Vector3(-half - wall, 0.0, depth), Vector3(width + wall * 2.0, HEIGHT, wall)))
	walls.append(AABB(Vector3(-half, -wall, 0.0), Vector3(width, wall, depth)))
	walls.append(AABB(Vector3(-half, HEIGHT - wall, 0.0), Vector3(width, wall, depth)))

	# Each floor has offset room doors. Their orientation and precise offsets
	# depend on the floor seed, while both turns remain possible in every home.
	var side := 1.0 if rng.randi_range(0, 1) == 0 else -1.0
	var first_x := side * rng.randf_range(0.95, 1.05)
	var second_x := -side * rng.randf_range(0.95, 1.05)
	var first_z := rng.randf_range(1.02, 1.26)
	var second_z := rng.randf_range(2.29, 2.56)
	_partition(first_z, half, first_x, 1.07)
	_partition(second_z, half, second_x, 1.07)
	_guides.append(Vector3(0.0, ARM_HEIGHT, 0.30))
	areas[&"entry"] = Vector3(-side * 0.65, 1.12, 0.55)
	areas[&"middle"] = Vector3(side * 0.55, 1.39, (first_z + second_z) * 0.5)
	areas[&"rear"] = Vector3(second_x, 1.19, minf(depth - 0.40, 4.77))

func _partition(z: float, half_width: float, opening_x: float, opening_width: float) -> void:
	var face_z := z - WALL_THICKNESS * 0.5
	var left := opening_x - opening_width * 0.5
	var right := opening_x + opening_width * 0.5
	walls.append(AABB(Vector3(-half_width, 0.0, face_z),
		Vector3(left + half_width, HEIGHT, WALL_THICKNESS)))
	walls.append(AABB(Vector3(right, 0.0, face_z),
		Vector3(half_width - right, HEIGHT, WALL_THICKNESS)))
	walls.append(AABB(Vector3(left, OPENING_HEIGHT, face_z),
		Vector3(opening_width, HEIGHT - OPENING_HEIGHT, WALL_THICKNESS)))
	if z > 0.0:
		room_doors.append(Vector3(opening_x, 0.0, z))
		# Four guide points around a narrow threshold keep the palm parallel
		# to its jambs even when the section before or after it is diagonal.
		for edge: float in [-1.0, 1.0]:
			for clearance: float in [-1.0, 1.0]:
				_guides.append(Vector3(opening_x + edge * 0.26, ARM_HEIGHT, z + clearance * 0.29))

func make_arm(extra_walls: Array[AABB] = []) -> ArmSearch:
	var blockers := walls.duplicate()
	blockers.append_array(extra_walls)
	return ArmSearch.new(shoulder, door, blockers, _guides, areas, _seed)

func to_world(point: Vector3) -> Vector3:
	return _transform * point

func to_local(point: Vector3) -> Vector3:
	return _transform.affine_inverse() * point

func area_at(point: Vector3) -> StringName:
	if not floor_bounds.has_point(Vector2(point.x, point.z)) or point.y < 0.0 or point.y >= HEIGHT:
		return &""
	# Rooms are bounded by the two partitions, even away from their probe points.
	if point.z < room_doors[0].z:
		return &"entry"
	if point.z < room_doors[1].z:
		return &"middle"
	return &"rear"

## Sweep the waist of a walking capsule through the same wall and leaf geometry as the view.
func walk_clear(from: Vector3, to: Vector3, door_open: bool, parlour: bool) -> bool:
	var a := to_local(from) + Vector3.UP * 0.84
	var b := to_local(to) + Vector3.UP * 0.84
	if not Rect2(Vector2(minf(a.x, b.x), minf(a.z, b.z)), Vector2(absf(a.x - b.x), absf(a.z - b.z))).grow(0.5).intersects(floor_bounds.grow(0.5)):
		return true
	const RADIUS := 0.15 # Quantised movement leaves 6 cm tolerance against the local 21 cm capsule.
	if not door_open and ArmSearch._hits_box(a, b, door, RADIUS):
		return false
	for wall in walls:
		if parlour and wall.position.x < floor_bounds.position.x and wall.size.x < 0.20 and wall.size.z >= floor_bounds.size.y - 0.01:
			var middle := wall.get_center().z
			var span := (wall.size.z - 1.24) * 0.5
			var left := AABB(wall.position, Vector3(wall.size.x, wall.size.y, span))
			var right := AABB(Vector3(wall.position.x, 0, middle + 0.62), left.size)
			if ArmSearch._hits_box(a, b, left, RADIUS) or ArmSearch._hits_box(a, b, right, RADIUS):
				return false
		elif ArmSearch._hits_box(a, b, wall, RADIUS):
			return false
	return true
