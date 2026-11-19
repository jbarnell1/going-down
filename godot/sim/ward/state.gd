# Authoritative Hanging Ward encounter. Each tick receives accepted crew positions and input edges.
extends RefCounted

const Footing = preload("res://sim/ward/footing.gd")
const Layout = preload("res://sim/ward/layout.gd")
const House = preload("res://sim/ward/house.gd")
const Arm = preload("res://sim/ward/arm.gd")
const RETURN_SECONDS := 600.0
const WARN_SECONDS := 0.85
const CLIMB_SECONDS := 2.5
const WINCH_REACH := 1.25

var layout: Dictionary
var footing: Footing
var houses: Array[House] = []
var switches: Array[Dictionary] = []
var collection_at := -1.0
var depart_at := -1.0
var phase := &"unloading"
var encounter := &"idle"
var bridge_lowered := false
var resident_house := -1
var alert_area := &""
var encounter_at := -1.0
var arm: Arm
var requested_doors := {}
var final_call_sent := false
var last_minute_sent := false
var boarded: Array[String] = []
var caught: Array[String] = []
var left_behind: Array[String] = []
var _sprint_at := {}

func _init(seed_value: int) -> void:
	layout = Layout.generate(seed_value)
	for site: Dictionary in layout.houses:
		houses.append(House.new(site, seed_value))
	footing = Footing.new(layout, lift_door(), houses)
	for edge: Dictionary in layout.bridges:
		if edge.kind != "winch":
			continue
		var path: Array = edge.path
		_add_switch(path[0], path[1], int(edge.a))
		_add_switch(path[-1], path[-2], int(edge.b))

func _add_switch(raw: Array, adjacent: Array, house: int) -> void:
	var point := Vector3(raw[0], raw[2], raw[1])
	var next := Vector3(adjacent[0], adjacent[2], adjacent[1])
	var offset := (next - point).cross(Vector3.UP).normalized()
	switches.append({"house": house, "position": point + offset * 0.59})

## The lift cabin is south of the parlour. The same geometry drives the client view.
func lift_door() -> Vector3:
	var foyer := houses[0]
	return foyer.to_world(Vector3(foyer.floor_bounds.position.x - 0.12, 0.15, foyer.floor_bounds.get_center().y))

func in_lift(feet: Vector3) -> bool:
	var offset := feet - lift_door()
	return absf(offset.x) <= 0.67 and offset.z <= -0.22 and offset.z >= -2.93 and absf(offset.y) <= 0.45

## Begin collection once the normal lift has left the crew in the Ward.
func leave(now: float) -> Array[Dictionary]:
	if phase != &"unloading":
		return []
	phase = &"away"
	collection_at = now + RETURN_SECONDS
	return [{"kind": &"departed", "at": now}]

## Each accepted crew row has position (feet), aboard and optional use (rising edge) and sprint.
## Boarding duration is sampled when the lift arrives. Call this at consecutive host ticks.
func step(now: float, delta: float, boarding_seconds: float, crew: Dictionary) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	if phase == &"unloading" or phase == &"departed":
		return events
	if phase == &"away":
		if not last_minute_sent and now >= collection_at - 60.0:
			last_minute_sent = true
			events.append({"kind": &"last_minute", "at": collection_at - 60.0})
		if now >= collection_at:
			phase = &"boarding"
			depart_at = collection_at + maxf(boarding_seconds, 0.0)
			events.append({"kind": &"returned", "at": collection_at})
	if phase == &"boarding":
		var final_at := maxf(collection_at, depart_at - 10.0)
		if not final_call_sent and now >= final_at and final_at < depart_at:
			final_call_sent = true
			events.append({"kind": &"final_call", "at": final_at})
		if now >= depart_at:
			phase = &"departed"
			for id: String in crew:
				if crew[id].get("aboard", false) and crew[id].get("active", true):
					boarded.append(id)
				else:
					left_behind.append(id)
			events.append({"kind": &"closed", "at": depart_at, "boarded": boarded.duplicate(), "leftBehind": left_behind.duplicate()})
			return events

	for id: String in crew:
		var member: Dictionary = crew[id]
		if not member.get("active", true) or member.get("aboard", false):
			continue
		var at: Vector3 = member.position
		if member.get("use", false):
			_use_near(at, now, crew, events)
		if member.get("sprint", false) and now >= float(_sprint_at.get(id, -INF)):
			_sprint_at[id] = now + 0.65
			for i in houses.size():
				var area := houses[i].area_at(houses[i].to_local(at + Vector3.UP * 1.25))
				if area != &"":
					_hear(i, area, now, events)
					break
	_pursue(now, delta, crew, events)
	return events

func _use_near(at: Vector3, now: float, crew: Dictionary, events: Array[Dictionary]) -> void:
	for button in switches:
		if at.distance_to(button.position) <= WINCH_REACH:
			if bridge_lowered and _shortcut_occupied(crew):
				return
			bridge_lowered = not bridge_lowered
			events.append({"kind": &"bridge", "at": now, "house": button.house, "lowered": bridge_lowered})
			_hear(button.house, &"entry", now, events)
			return
	for i in houses.size():
		var near := houses[i].to_local(at)
		if Vector2(near.x, near.z).length() < 1.12 and absf(near.y) < 0.6:
			requested_doors[i] = not bool(requested_doors.get(i, true))
			return

func _shortcut_occupied(crew: Dictionary) -> bool:
	for row: Dictionary in crew.values():
		if not row.get("active", true):
			continue
		var position: Vector3 = row.position
		var feet := Vector2(position.x, position.z)
		if is_finite(footing.height_at(feet, true)) and not is_finite(footing.height_at(feet, false)):
			return true
	return false

func _hear(house: int, area: StringName, now: float, events: Array[Dictionary]) -> void:
	if encounter == &"idle":
		resident_house = house
		encounter = &"warning"
		encounter_at = now
		alert_area = area
		events.append({"kind": &"line_loaded", "at": now, "house": house})
	elif resident_house == house and encounter == &"searching":
		arm.hear(area)

func _pursue(now: float, delta: float, crew: Dictionary, events: Array[Dictionary]) -> void:
	if encounter == &"idle":
		return
	var elapsed := now - encounter_at
	if encounter == &"warning" and elapsed >= WARN_SECONDS:
		encounter = &"climbing"
	if encounter == &"climbing" and elapsed >= WARN_SECONDS + CLIMB_SECONDS:
		encounter = &"searching"
		arm = houses[resident_house].make_arm()
		arm.hear(alert_area)
	if encounter != &"searching":
		return
	var contacts := {}
	var house := houses[resident_house]
	for id: String in crew:
		var member: Dictionary = crew[id]
		if not member.get("active", true) or member.get("aboard", false):
			continue
		var local := house.to_local(member.position + Vector3.UP * 1.25)
		if house.area_at(local) != &"":
			contacts[id] = local
	arm.step(delta, contacts, bool(requested_doors.get(resident_house, true)))
	for id: String in arm.contacts:
		if not caught.has(id):
			caught.append(id)
			events.append({"kind": &"contact", "at": now, "house": resident_house, "id": id})
	if arm.phase == &"idle":
		encounter = &"idle"
		resident_house = -1
		encounter_at = -1.0
		arm = null

## The same support and grip that the view draws. Empty outside an active physical reach.
func posed_limb(now: float) -> PackedVector3Array:
	var points := PackedVector3Array()
	if resident_house < 0 or phase == &"departed":
		return points
	var house := houses[resident_house]
	if encounter == &"climbing":
		var site: Dictionary = layout.houses[resident_house]
		var anchor := Vector3(float(site.x) - float(site.w) * 0.5 - Layout.GALLERY + 0.13,
			float(site.z) + 0.17, float(site.y) - float(site.d) * 0.5 - Layout.GALLERY + 0.13)
		var shoulder := house.to_world(house.shoulder)
		var climb := clampf((now - encounter_at - WARN_SECONDS) / CLIMB_SECONDS, 0.0, 1.0)
		anchor.y = shoulder.y
		var body := (anchor - Vector3.UP * 10.0).lerp(anchor, minf(1.0, climb * 1.18))
		body = body.lerp(shoulder, smoothstep(0.78, 1.0, climb))
		points.append(body + Vector3.UP * 0.45)
		points.append(Vector3(anchor.x, body.y + 0.78, anchor.z))
	elif arm != null and arm.points.size() > 1:
		for local in arm.points:
			points.append(house.to_world(local))
	return points

## Authoritative door leaves and the same interior wall clearance as the moving player.
func walk_clear(from: Vector3, to: Vector3) -> bool:
	if not footing.route_supported(from, to, bridge_lowered):
		return false
	# The creature already owns the swing-space decision for a door held by its arm.
	for id in houses.size():
		var house := houses[id]
		var door_open := arm.door_open if resident_house == id and arm != null else bool(requested_doors.get(id, true))
		if not house.walk_clear(from, to, door_open, id == 0):
			return false
	var at := lift_door()
	var walls: Array[AABB] = [
		AABB(at + Vector3(-0.775, 0.0, -3.0), Vector3(0.11, 2.2, 3.0)),
		AABB(at + Vector3(0.665, 0.0, -3.0), Vector3(0.11, 2.2, 3.0)),
		AABB(at + Vector3(-0.775, 0.0, -3.06), Vector3(1.55, 2.2, 0.12)),
	]
	if phase in [&"away", &"departed"]:
		walls.append(AABB(at + Vector3(-0.62, 0.0, -0.04), Vector3(1.24, 2.18, 0.08)))
	for wall in walls:
		if Arm._hits_box(from + Vector3.UP * 0.84, to + Vector3.UP * 0.84, wall, 0.15):
			return false
	return true

func walk(from: Vector3, motion: Vector2) -> Vector3:
	var at := from
	var substeps := maxi(1, ceili(motion.length() / Footing.WALK_STEP))
	var part := motion / substeps
	for i in substeps:
		var wanted := _walk_piece(at, part)
		if wanted == at and not is_zero_approx(part.x) and not is_zero_approx(part.y):
			wanted = _walk_piece(at, Vector2(part.x, 0.0))
			wanted = _walk_piece(wanted, Vector2(0.0, part.y))
		at = wanted
	return at

func _walk_piece(from: Vector3, motion: Vector2) -> Vector3:
	var to := Vector2(from.x, from.z) + motion
	var height := footing.walking_height(to, from.y, bridge_lowered)
	if is_finite(height):
		var candidate := Vector3(to.x, height, to.y)
		if walk_clear(from, candidate):
			return candidate
	return from

func snapshot(clock := 0.0) -> Dictionary:
	var points: Array = []
	var doors := []
	for id in houses.size():
		doors.append(arm.door_open if resident_house == id and arm != null else bool(requested_doors.get(id, true)))
	for point: Vector3 in posed_limb(clock):
		points.append([snappedf(point.x, 0.01), snappedf(point.y, 0.01), snappedf(point.z, 0.01)])
	return {"collectionAt": collection_at, "departAt": depart_at, "bridgeLowered": bridge_lowered,
		"phase": String(phase), "house": resident_house, "startedAt": encounter_at, "encounter": String(encounter),
		"armPoints": points, "doors": doors, "boarded": boarded.duplicate(), "leftBehind": left_behind.duplicate(),
		"seed": int(layout.seed), "caught": caught.duplicate()}