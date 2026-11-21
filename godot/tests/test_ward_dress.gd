# WL1: the Hanging Ward's look (client/ward/dress.gd, client/ward/view.gd). The owner, 20 Nov, on the 11:38 build:
# "the elevator looks completely different (not like an elevator at all), doors open are invisible and a flat brown
# when closed ... just boxes and squares everywhere, that don't connect". Checked here on the view as built, for
# today's Ward and generated ones (WG1):
#   1. every walkway's deck ends on a house's gallery or on another span's joint, at its height: nothing floats;
#   2. the Ward's lift is the game's own car (client/lift.gd) with the same door parts as an ordinary floor's, sized
#      to the Ward's gate, its doors open while the lift waits and shut while it is away;
#   3. a house's door is seen shut and seen open (a leaf on its hinge, never hidden);
#   4. every gallery has its railing, open where a walkway docks; the lines and hangers run up to the cavern's roof.
extends RefCounted

const T = preload("res://tests/t.gd")
const View = preload("res://client/ward/view.gd")
const Dress = preload("res://client/ward/dress.gd")
const Layout = preload("res://sim/ward/layout.gd")
const Footing = preload("res://sim/ward/footing.gd")

## Today's Ward and two generated ones.
const CASES := [[8143, []], [11, [2, 110, 150]], [302, [2, 110, 150]]]

static func _view(seed_value: int, layout: Array) -> View:
	var view := View.new(seed_value, Vector3.ZERO, layout)
	view.own_hud = false
	view.own_camera = false
	view.own_environment = false
	(Engine.get_main_loop() as SceneTree).root.add_child(view)
	return view

## The world box of a solid box part (a StaticBody3D with a BoxShape3D), or an empty AABB.
static func _solid_box(node: Node) -> AABB:
	if not node is StaticBody3D:
		return AABB()
	var shape := (node as Node).get_node_or_null("CollisionShape3D") as CollisionShape3D
	if shape == null or not shape.shape is BoxShape3D:
		return AABB()
	var size := (shape.shape as BoxShape3D).size
	return (node as Node3D).global_transform * AABB(-size * 0.5, size)

## Every deck span of every walkway (the bridge's too): [start of its top, end of its top, the node].
static func _spans(view: View) -> Array:
	var out := []
	var roots: Array[Node3D] = view.walkways.duplicate()
	roots.append(view.bridge)
	for root: Node3D in roots:
		for child: Node in root.get_children():
			var shape := child.get_node_or_null("CollisionShape3D") as CollisionShape3D
			if shape == null or not shape.shape is BoxShape3D:
				continue
			var size := (shape.shape as BoxShape3D).size
			if not is_equal_approx(size.x, Footing.DECK_WIDTH) or size.z < 0.5:
				continue
			var xf := (child as Node3D).global_transform
			out.append([xf * Vector3(0, size.y * 0.5, -size.z * 0.5), xf * Vector3(0, size.y * 0.5, size.z * 0.5), child])
	return out

## Whether a deck end sits on a box: inside its footprint (2 cm slack) with the box's top within 3 cm of it.
static func _rests_on(end: Vector3, box: AABB) -> bool:
	var flat := Rect2(Vector2(box.position.x, box.position.z), Vector2(box.size.x, box.size.z)).grow(0.02)
	return flat.has_point(Vector2(end.x, end.z)) and absf(box.end.y - end.y) < 0.03

func test_every_walkway_end_rests_on_a_gallery_or_a_joint(t: T) -> void:
	for case: Array in CASES:
		var view := _view(int(case[0]), case[1])
		var floors: Array[AABB] = []
		for house: Dictionary in view.houses:
			for part: Node in (house.deck as Node3D).get_children():
				var box := _solid_box(part)
				if box.has_volume():
					floors.append(box)
		var spans := _spans(view)
		var joints: Array[AABB] = []
		for root: Node3D in view.walkways + [view.bridge]:
			for part: Node in root.get_children():
				var box := _solid_box(part)
				if box.has_volume() and is_equal_approx(box.size.x, Footing.JOINT_WIDTH) and is_equal_approx(box.size.z, Footing.JOINT_WIDTH):
					joints.append(box)
		var loose: Array[String] = []
		for span: Array in spans:
			for end: Vector3 in [span[0], span[1]]:
				var held := false
				for box: AABB in floors + joints:
					held = held or _rests_on(end, box)
				if not held:
					loose.append(str(end.snappedf(0.01)))
		t.check(spans.size() >= view.walk_model.layout.bridges.size(), "seed %d: every walkway has its deck (%d spans)" % [case[0], spans.size()])
		t.check(loose.is_empty(), "seed %d: every walkway end rests on a gallery or a joint at its height (%d loose: %s)" % [case[0], loose.size(), ", ".join(loose.slice(0, 4))])
		view.free()

## The door parts of a lift: its two door holders with their panels, the frame's named fronts, the sill, the lamp.
static func _door_parts(lift: Lift) -> Dictionary:
	var panels := 0
	for holder: Node3D in [lift.get("_left"), lift.get("_right")]:
		for part: Node in holder.get_children():
			panels += 1 if part is MeshInstance3D else 0
	return {"panels": panels, "front": lift.find_child("FrontLeft", false, false) != null and lift.find_child("FrontRight", false, false) != null,
		"sill": lift.find_child("MetalSill", false, false) != null, "lamp": lift.get("_lamp") != null,
		"call": lift.call_at != Vector3.ZERO}

func test_the_wards_lift_is_the_games_lift(t: T) -> void:
	var ordinary := Lift.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(ordinary)
	ordinary.build({"width": 4.0, "depth": 4.0, "doorWidth": 1.8, "doorX": 0.0, "floorY": 0.0, "doorZ": 0.0,
		"rightX": 1.0, "rightZ": 0.0, "inX": 0.0, "inZ": -1.0})
	for case: Array in CASES:
		var view := _view(int(case[0]), case[1])
		var car: Lift = view.lift_car
		if not t.check(car != null and car.get_parent() == view, "seed %d: the Ward draws a lift car (client/lift.gd)" % case[0]):
			view.free()
			continue
		t.eq(_door_parts(car), _door_parts(ordinary), "seed %d: the same door parts as an ordinary floor's lift" % case[0])
		var drawn := car.drawn_car()
		t.check(absf(float(drawn.doorway) - 1.24) < 0.01 and absf(float(drawn.panels) - 1.24) < 0.01,
			"seed %d: its doorway and shut doors are the Ward's gate, 1.24 m (%.2f, %.2f)" % [case[0], float(drawn.doorway), float(drawn.panels)])
		var door := view.walk_model.lift_door()
		t.check(car.global_position.distance_to(door + Vector3(0, -0.01, Dress.WALL_LINE)) < 0.01 and car.global_basis.z.is_equal_approx(Vector3.BACK),
			"seed %d: at the walk model's lift door, the car behind it (%s)" % [case[0], str(car.global_position)])
		# The doors follow the lift: open while it waits (unloading), shut while it is away, open when it is back.
		var block := view.walk_model.snapshot()
		for step: Array in [["unloading", 1.0], ["away", 0.0], ["boarding", 1.0], ["departed", 0.0]]:
			block.phase = step[0]
			view.show_host(block, 0.0, "nobody", [])
			for k in 30:
				view._process(0.1)
			t.check(is_equal_approx(car.doors, float(step[1])), "seed %d %s: the car's doors are %s (%.2f)" % [case[0], step[0], "open" if step[1] > 0.5 else "shut", car.doors])
		view.free()
	ordinary.free()

func test_a_house_door_is_seen_shut_and_open(t: T) -> void:
	for case: Array in CASES:
		var view := _view(int(case[0]), case[1])
		t.eq(view.door_hinges.size(), 8, "seed %d: a hinged door on every house" % case[0])
		var block := view.walk_model.snapshot()
		for open: bool in [false, true]:
			var doors := []
			for i in 8:
				doors.append(open)
			block.doors = doors
			view.show_host(block, 0.0, "nobody", [])
			for k in 30:
				view._process(0.1)
			var right := true
			for hinge: Node3D in view.door_hinges:
				right = right and hinge.is_visible_in_tree() and is_equal_approx(hinge.rotation.y, Dress.DOOR_SWING if open else 0.0)
				var parts := 0
				# Each part is a node holding its box (view.gd _box).
				for part: Node in hinge.get_children():
					var mesh := part.get_child(0) as MeshInstance3D if part.get_child_count() > 0 else null
					parts += 1 if mesh != null and mesh.is_visible_in_tree() else 0
				right = right and parts >= 3
			t.check(right, "seed %d: every door is drawn %s (a leaf with its panels and knob, on its hinge)" % [case[0], "open" if open else "shut"])
		view.free()

## FX2: generated Wards (WG1, today's live options) on this many seeds, and today's Ward, for the lift's doorway.
const DOORWAY_SEEDS := 20

## Whether the box `box` under `xf` (a mesh's world transform and its local box) overlaps `region` (a box in the
## frame `frame`) by more than a few millimetres, by separating axes: the region's three, the box's three, and the
## nine crossings.
static func _overlaps(xf: Transform3D, box: AABB, frame: Transform3D, region: AABB) -> bool:
	var rel := frame.affine_inverse() * xf
	var corners: Array[Vector3] = []
	for i in 8:
		corners.append(rel * box.get_endpoint(i))
	var mine: Array[Vector3] = []
	for i in 8:
		mine.append(region.get_endpoint(i))
	var axes: Array[Vector3] = [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
	var own: Array[Vector3] = [rel.basis.x, rel.basis.y, rel.basis.z]
	for a: Vector3 in own:
		if a.length() > 1e-6:
			axes.append(a.normalized())
	for a: Vector3 in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
		for b: Vector3 in own:
			var c := a.cross(b)
			if c.length() > 1e-4:
				axes.append(c.normalized())
	for axis: Vector3 in axes:
		var lo_a := INF
		var hi_a := -INF
		var lo_b := INF
		var hi_b := -INF
		for p: Vector3 in corners:
			lo_a = minf(lo_a, p.dot(axis))
			hi_a = maxf(hi_a, p.dot(axis))
		for p: Vector3 in mine:
			lo_b = minf(lo_b, p.dot(axis))
			hi_b = maxf(hi_b, p.dot(axis))
		if minf(hi_a, hi_b) - maxf(lo_a, lo_b) < 0.005:
			return false
	return true

## Every drawn mesh of the view that is not part of the lift car, with its world transform and box: [node, xf, box].
static func _drawn_meshes(view: View) -> Array:
	var out := []
	for node: Node in view.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if mesh.mesh == null or not mesh.is_visible_in_tree() or view.lift_car.is_ancestor_of(mesh):
			continue
		if mesh.has_meta(&"parts"):
			# AW1: a batch of the skin's boxes (client/ward/skin.gd Batch) is checked box by box, not by its whole extent.
			for part: Array in mesh.get_meta(&"parts"):
				out.append([mesh, mesh.global_transform * (part[0] as Transform3D), part[1]])
			continue
		out.append([mesh, mesh.global_transform, mesh.mesh.get_aabb()])
	return out

## FX2: the owner, 20 Nov, on floor 6: a dark beam ran across the lift's doorway at head height. In the car's frame
## (client/lift.gd: x right walking in, z out of the car), the car's inside and its door opening out to a step past
## the landing's wall face must hold nothing drawn but the car's own parts, on today's Ward and generated ones.
func test_nothing_crosses_the_lifts_doorway_or_car(t: T) -> void:
	var cases: Array = [[8143, []]]
	for k in DOORWAY_SEEDS:
		cases.append([1000 + k * 7919, Layout.to_wire({"version": 2, "spread": Layout.SPREAD, "rise": Layout.RISE})])
	for case: Array in cases:
		var view := _view(int(case[0]), case[1])
		var car: Lift = view.lift_car
		var frame := car.global_transform
		var inside := AABB(Vector3(-car.half + 0.04, 0.04, -car.depth + 0.06), Vector3(car.half * 2.0 - 0.08, Lift.CAR_H - 0.1, car.depth - 0.06 - Lift.FRONT - 0.03))
		var doorway := AABB(Vector3(-car.door_half + 0.02, 0.04, -Lift.FRONT), Vector3(car.door_half * 2.0 - 0.04, Lift.DOOR_H - 0.06, Lift.FRONT + Lift.LAND + 0.4))
		var crossing: Array[String] = []
		for part: Array in _drawn_meshes(view):
			if _overlaps(part[1], part[2], frame, inside) or _overlaps(part[1], part[2], frame, doorway):
				var middle := frame.affine_inverse() * (part[1] as Transform3D) * (part[2] as AABB).get_center()
				crossing.append("a part %s big at %s" % [str((part[2] as AABB).size.snappedf(0.01)), str(middle.snappedf(0.01))])
		t.check(crossing.is_empty(), "seed %d: nothing but the car crosses its doorway or stands in it (%d: %s)" % [case[0], crossing.size(), ", ".join(crossing.slice(0, 4))])
		# The call button and the indicator are on the landing's wall beside and over the door: a drawn wall stands
		# right behind each, within 2 cm of its back.
		var walls := _drawn_meshes(view)
		for spot: Array in [["call button", car.call_at - Vector3(0, 0, 0.04)], ["indicator", Vector3(0, Lift.DOOR_H + 0.38, Lift.LAND + 0.02)]]:
			var behind: Vector3 = spot[1] - Vector3(0, 0, 0.03)
			var backed := false
			for part: Array in walls:
				var local: Vector3 = (part[1] as Transform3D).affine_inverse() * (frame * behind)
				backed = backed or (part[2] as AABB).grow(0.001).has_point(local)
			t.check(backed, "seed %d: the lift's %s is on the wall, not floating" % [case[0], spot[0]])
		view.free()

func test_galleries_have_railings_and_the_lines_reach_the_roof(t: T) -> void:
	for case: Array in CASES:
		var view := _view(int(case[0]), case[1])
		var rails := view.find_children("GalleryRail*", "Node3D", false, false)
		t.eq(rails.size(), 8, "seed %d: a railing round every gallery" % case[0])
		var roof := view.find_child("CavernRoof", false, false) as Node3D
		t.check(roof != null and absf(view.roof_y - Dress.roof_y(view.walk_model.layout)) < 1e-6, "seed %d: the cavern's roof is drawn" % case[0])
		# Every plain deck line (not the loaded one the Rigger climbs, which the view poses) ends at the roof.
		var short := 0
		for house: Dictionary in view.houses:
			for line: Node3D in house.lines:
				if line == house.support:
					continue
				var mesh := line.get_child(0) as MeshInstance3D
				var top := (line.global_transform * (mesh.mesh as BoxMesh).get_aabb()).end.y
				short += 1 if absf(top - view.roof_y) > 0.2 else 0
		t.eq(short, 0, "seed %d: every deck line runs up to the roof" % case[0])
		view.free()
