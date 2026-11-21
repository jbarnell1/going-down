extends RefCounted

const ArmSearch = preload("res://sim/ward/arm.gd")
const HEIGHT := 3.05
const ARM_HEIGHT := 1.25
const WALL_THICKNESS := 0.14
const OPENING_HEIGHT := 2.19
const STAIR_WIDTH := 1.0
const LANDING_EDGE := 0.34
const SLAB_THICKNESS := 0.14
## The gallery round every house (sim/ward/layout.gd GALLERY).
const GALLERY := 1.6

class Stair:
	var from: Vector3
	var to: Vector3
	var shaft: Rect2

class Storey:
	var height: float
	var slab: Array[AABB] = []
	var partitions: Array[AABB] = []
	var incoming: Stair
	var outgoing: Stair

var floor_bounds: Rect2
var walls: Array[AABB] = []
var storeys: Array[Storey] = []
var stairs: Array[Stair] = []
var upper_envelope: Array[AABB] = []
var door: AABB
## Only the laundry maisonette opens a sash, on the side of the first interior doorway.
## The original full wall stays in the player footing model. The arm uses its sill and jambs.
var search_window := AABB()
var window_side := 0
var shoulder := Vector3(0.0, ARM_HEIGHT, -0.6)
var areas: Dictionary = {}
var room_doors := PackedVector3Array()
var _guides := PackedVector3Array()
var _seed: int
var _transform: Transform3D
## WG1: which way the front door faces (0 south, 1 east, 2 north, 3 west) and whether the stair runs the other way.
var facing := 0
var mirror := false
## WG1: a generated layout's house picks its loaded line by where its corner really is (today's: the fixed pick).
var _corner_by_facing := false

## The turn of the house about the vertical, as the view draws its root (today's parlour -PI/2, the rest 0).
func yaw() -> float:
	return 0.0 if facing == 0 else -PI * 0.5 * facing

func _init(house: Dictionary, ward_seed: int) -> void:
	_seed = ward_seed * 31 + int(house.id) * 997
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed
	var parlour: bool = house.id == 0
	# WG1 (sim/ward/layout.gd generate_v2): a house may face any of four ways and run its stair the other way. Without
	# those fields, today's: the parlour's door east (facing 1), every other door south (facing 0).
	facing = int(house.get("facing", 1 if parlour else 0))
	mirror = bool(house.get("mirror", false))
	_corner_by_facing = house.has("facing")
	var turned := facing % 2 == 1
	var width := float(house.d) if turned else float(house.w)
	var depth := float(house.w) if turned else float(house.d)
	var origin := Vector3(house.x, house.z, house.y)
	match facing:
		1:
			origin.x += depth * 0.5
			_transform = Transform3D(Basis(Vector3.UP, -PI * 0.5), origin)
		2:
			origin.z += depth * 0.5
			_transform = Transform3D(Basis(Vector3.UP, -PI), origin)
		3:
			origin.x -= depth * 0.5
			_transform = Transform3D(Basis(Vector3.UP, -PI * 1.5), origin)
		_:
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
	_build_storeys(int(house.floors), width, depth)

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
	if house.style == "laundry_maisonette":
		window_side = -1 if first_x < 0 else 1
		var outer_x := window_side * (half + wall)
		var face_x := -half-wall if window_side < 0 else half
		search_window = AABB(Vector3(face_x, 0.82, depth*0.5-0.71), Vector3(wall, 1.25, 1.42))
		shoulder = Vector3(outer_x + window_side*0.6, ARM_HEIGHT, depth*0.5)
		for side_of_jamb: float in [-0.50, 0.50]:
			var inside_z := depth*0.5 + side_of_jamb
			_guides.append(Vector3(outer_x + window_side*0.23, ARM_HEIGHT, inside_z))
			_guides.append(Vector3(window_side*(half-0.32), ARM_HEIGHT, inside_z))
	areas[&"entry"] = Vector3(-side * 0.65, 1.12, 0.55)
	areas[&"middle"] = Vector3(side * 0.55, 1.39, (first_z + second_z) * 0.5)
	areas[&"rear"] = Vector3(second_x, 1.19, minf(depth - 0.40, 4.77))

func _build_storeys(count: int, width: float, depth: float) -> void:
	var half := width * 0.5
	for index in count:
		var floor := Storey.new()
		floor.height = float(index) * HEIGHT
		storeys.append(floor)
		if index == 0:
			continue
		var stair := Stair.new()
		var sign_dir := 1.0 if index % 2 == 1 else -1.0
		if mirror:
			sign_dir = -sign_dir
		var lane := depth - 0.61 if index % 2 == 1 else 0.61
		var edge := half - LANDING_EDGE
		stair.from = Vector3(-edge * sign_dir, float(index - 1) * HEIGHT, lane)
		stair.to = Vector3(edge * sign_dir, float(index) * HEIGHT, lane)
		stair.shaft = Rect2(-edge - 0.03, lane - STAIR_WIDTH * 0.53, edge * 2.0 + 0.06, STAIR_WIDTH * 1.06)
		stairs.append(stair)
		floor.incoming = stair
		storeys[index - 1].outgoing = stair
		floor.slab = _slab_around(stair.shaft, floor.height)
		# Full side and end walls at each upper level. The centre jamb has a real walking opening.
		upper_envelope.append(AABB(Vector3(-half - WALL_THICKNESS, floor.height, 0.0), Vector3(WALL_THICKNESS, HEIGHT, depth)))
		upper_envelope.append(AABB(Vector3(half, floor.height, 0.0), Vector3(WALL_THICKNESS, HEIGHT, depth)))
		for end: float in [0.0, depth]:
			upper_envelope.append(AABB(Vector3(-half, floor.height, end - WALL_THICKNESS * 0.5), Vector3(width, HEIGHT, WALL_THICKNESS)))
		var jamb := depth * 0.5 - WALL_THICKNESS * 0.5
		floor.partitions.append(AABB(Vector3(-half, floor.height, jamb), Vector3(half - 0.59, HEIGHT, WALL_THICKNESS)))
		floor.partitions.append(AABB(Vector3(0.59, floor.height, jamb), Vector3(half - 0.59, HEIGHT, WALL_THICKNESS)))
		floor.partitions.append(AABB(Vector3(-0.59, floor.height + OPENING_HEIGHT, jamb), Vector3(1.18, HEIGHT - OPENING_HEIGHT, WALL_THICKNESS)))
	# One roof slab. Intermediate ceilings share the exact opening visible in the client.
	var roof_at := float(count) * HEIGHT
	storeys.append(Storey.new())
	storeys[-1].height = roof_at
	storeys[-1].slab.append(AABB(Vector3(-half, roof_at - SLAB_THICKNESS, 0), Vector3(width, SLAB_THICKNESS, depth)))

func _slab_around(hole: Rect2, elevation: float) -> Array[AABB]:
	var out: Array[AABB] = []
	var strips: Array[Rect2] = [
		Rect2(floor_bounds.position, Vector2(floor_bounds.size.x, hole.position.y - floor_bounds.position.y)),
		Rect2(Vector2(floor_bounds.position.x, hole.end.y), Vector2(floor_bounds.size.x, floor_bounds.end.y - hole.end.y)),
		Rect2(Vector2(floor_bounds.position.x, hole.position.y), Vector2(hole.position.x - floor_bounds.position.x, hole.size.y)),
		Rect2(hole.end - Vector2(0.0, hole.size.y), Vector2(floor_bounds.end.x - hole.end.x, hole.size.y)),
	]
	for strip in strips:
		out.append(AABB(Vector3(strip.position.x, elevation - SLAB_THICKNESS, strip.position.y),
			Vector3(strip.size.x, SLAB_THICKNESS, strip.size.y)))
	return out

## All surfaces near this height, so a floor above never teleports a walker underneath it.
func locally_supported(local: Vector3) -> Array[float]:
	var out: Array[float] = []
	var flat := Vector2(local.x, local.z)
	if not floor_bounds.has_point(flat):
		return out
	for index in storeys.size() - 1:
		var floor := storeys[index]
		if floor.incoming == null or not floor.incoming.shaft.has_point(flat):
			out.append(floor.height)
		if floor.outgoing != null:
			var stair := floor.outgoing
			if stair.shaft.has_point(flat):
				var t := clampf(inverse_lerp(stair.from.x, stair.to.x, local.x), 0.0, 1.0)
				out.append(lerpf(stair.from.y, stair.to.y, t))
	return out

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

## Lines are ordered west-front, west-back, east-front, east-back on each deck.
func loaded_support_index() -> int:
	if not _corner_by_facing:
		return 2 if window_side > 0 else 0
	# WG1: the deck corner at the front of the house on the window's side (the west side for a house without
	# one), wherever the house faces. The same pick as today's for a house facing south.
	var corner := _transform.basis * Vector3(1.0 if window_side > 0 else -1.0, 0.0, -1.0)
	return (2 if corner.x > 0.0 else 0) + (1 if corner.z > 0.0 else 0)

## Whether this house comes from a generated layout (WG1), whose fields say how it faces.
func generated() -> bool:
	return _corner_by_facing

## The loaded line's corner of the deck in world space at deck height (the view's support line, lines ordered as
## loaded_support_index), for a site of the layout (sim/ward/layout.gd houses).
func support_corner(site: Dictionary, inset := 0.13) -> Vector3:
	var index := loaded_support_index()
	var east := 1.0 if index >= 2 else -1.0
	var north := 1.0 if index % 2 == 1 else -1.0
	return Vector3(float(site.x) + east * (float(site.w) * 0.5 + GALLERY - inset), float(site.z) + 0.17,
		float(site.y) + north * (float(site.d) * 0.5 + GALLERY - inset))

func make_arm(extra_walls: Array[AABB] = []) -> ArmSearch:
	var blockers := walls.duplicate()
	if search_window.has_volume():
		var face := AABB(Vector3(search_window.position.x, 0, 0),
			Vector3(WALL_THICKNESS, HEIGHT, floor_bounds.size.y))
		for i in blockers.size():
			if blockers[i].is_equal_approx(face):
				blockers.remove_at(i)
				break
		var start := search_window.position
		var end := search_window.end
		blockers.append(AABB(face.position, Vector3(face.size.x, start.y, face.size.z)))
		blockers.append(AABB(Vector3(start.x, end.y, 0), Vector3(face.size.x, HEIGHT-end.y, face.size.z)))
		blockers.append(AABB(Vector3(start.x, start.y, 0), Vector3(face.size.x, search_window.size.y, start.z)))
		blockers.append(AABB(Vector3(start.x, start.y, end.z), Vector3(face.size.x, search_window.size.y, face.end.z-end.z)))
	blockers.append_array(storeys[1].slab)
	blockers.append_array(extra_walls)
	return ArmSearch.new(shoulder, door, blockers, _guides, areas, _seed, not search_window.has_volume())

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
	for wall in upper_envelope:
		if ArmSearch._hits_box(a, b, wall, RADIUS):
			return false
	for floor in storeys:
		for wall in floor.partitions:
			if ArmSearch._hits_box(a, b, wall, RADIUS):
				return false
	return true
