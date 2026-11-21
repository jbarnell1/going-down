extends RefCounted
## LT1: the floors' lamps hold steady as the player walks. The Compatibility renderer lights each
## mesh with at most `rendering/limits/opengl/max_lights_per_object` lights of each type, the first ones
## paired with it, in no useful order; a mesh that meets more loses some of them, and which ones
## changes as lights change (a carried lamp moving each frame). That was the Clinic's dark circles.

const T = preload("res://tests/t.gd")
const Clinic = preload("res://sim/clinic.gd")
const AnnexPlan = preload("res://sim/annex.gd")
const Playroom = preload("res://sim/playroom.gd")
const Arboretum = preload("res://sim/arboretum.gd")
const Station = preload("res://sim/station.gd")
const PrisonView = preload("res://client/prison_view.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const Run = preload("res://sim/run.gd")

## Slots kept free on every mesh for the crew's carried lamps (spots) and the Flare/glow sticks (omnis).
const HEADROOM := 4

func _cap() -> int:
	return int(ProjectSettings.get_setting("rendering/limits/opengl/max_lights_per_object"))

func _built(fp: Variant, shadows := true) -> Level:
	var level := Level.new()
	level.shadows = shadows
	level.build(PlanDump.dump(fp, Run.car_geometry(fp)), fp.seed, fp)
	return level

func _check_pairs(t: T, what: String, level: Level) -> void:
	var r := pair_counts(level)
	var room := _cap() - HEADROOM
	t.check(r.worst_spot <= room and r.worst_omni <= room,
		"%s: every mesh meets at most %d lamps of a kind (worst %d spots on %s, %d omnis on %s; %d lamps)" % [what, room, r.worst_spot, r.spot_mesh, r.worst_omni, r.omni_mesh, r.spots + r.omnis])
	level.free()

func test_clinic_meshes_meet_few_enough_lamps(t: T) -> void:
	for sd: String in ["alpha", "beta", "night-1", "lt1-4"]:
		for depth: int in [1, 3]:
			_check_pairs(t, "the Clinic %s/%d" % [sd, depth], _built(Clinic.generate_clinic(sd, depth)))

func test_other_floors_meet_few_enough_lamps(t: T) -> void:
	for sd: String in ["alpha", "beta"]:
		_check_pairs(t, "the Annex " + sd, _built(AnnexPlan.generate_annex(sd, 3)))
		_check_pairs(t, "the Playroom " + sd, _built(Playroom.generate_playroom(sd, 4)))
		_check_pairs(t, "the Arboretum " + sd, _built(Arboretum.generate_arboretum(sd, 5)))
		_check_pairs(t, "the Reactor " + sd, _built(Station.generate_station(sd, 7)))
	var prison := Level.new()
	prison.shadows = true
	prison.build(PrisonView.plain_plan(), "prison")
	_check_pairs(t, "the Prison", prison)

func test_upper_lamps_leave_the_storey_below_alone(t: T) -> void:
	var level := _built(Clinic.generate_clinic("alpha", 3))
	var upper := 0
	var over_opening := 0
	var ok := true
	for l: Light3D in level.main_lights:
		if l.position.y < Level.LH:
			ok = ok and (l.light_cull_mask & Level.LOWER_LAYER) != 0
			continue
		var k := level.kind(1, int(floor(l.position.x / Level.S)), int(floor(l.position.z / Level.S)))
		if k == "atriumOpen" or k == "stair":
			over_opening += 1
			ok = ok and (l.light_cull_mask & Level.LOWER_LAYER) != 0
		else:
			upper += 1
			ok = ok and (l.light_cull_mask & Level.LOWER_LAYER) == 0
	t.check(upper > 10 and over_opening > 0, "the floor has upper lamps (%d) and lamps over the atrium (%d)" % [upper, over_opening])
	t.check(ok, "an upper lamp skips the storey below; a lamp over an opening and a lower lamp light it")
	var lower_chunks := 0
	var lower_ok := true
	for c in level.get_children():
		if c is MeshInstance3D and String(c.name).begins_with("0_"):
			lower_chunks += 1
			lower_ok = lower_ok and (c as MeshInstance3D).layers == Level.LOWER_LAYER
	t.check(lower_chunks > 10 and lower_ok, "the lower storey's %d chunks are on their own layer" % lower_chunks)
	level.free()

## A walk through the Clinic's main room (the cells under the atrium): no lamp near the camera fades,
## goes dark or gains or loses a shadow, except the lamps built to flicker.
func test_clinic_lamps_hold_steady_on_a_walk(t: T) -> void:
	var level := _built(Clinic.generate_clinic("alpha", 3))
	var path: Array[Vector3] = []
	for y in level.H:
		for x in level.W:
			if level.kind(1, x, y) == "atriumOpen":
				path.append(level.cell_center(0, x, y) + Vector3(0, 1.6, 0))
	t.check(path.size() >= 6, "the Clinic has a main room under an open atrium (%d cells)" % path.size())
	var flicker := {}
	for f: Dictionary in level.flickers:
		flicker[int(f.i)] = true
	var steady := true
	var faded := true
	var why := ""
	var flicker_moved := false
	var first := {}
	for step in path.size() * 3:
		var cam: Vector3 = path[step % path.size()]
		level.update_lights(0.1, cam)
		for i in level.main_lights.size():
			var l := level.main_lights[i]
			if flicker.has(i):
				if first.has(i) and not is_equal_approx(float(first[i]), l.light_energy):
					flicker_moved = true
				first[i] = l.light_energy
				continue
			if not l.visible or l.shadow_enabled or not is_equal_approx(l.light_energy, level._base_energy[i]):
				steady = false
				why = "lamp %d at %s" % [i, l.position]
			if l.position.distance_to(cam) < 25.0 and l.distance_fade_enabled and l.distance_fade_begin < 25.0:
				faded = false
	t.check(steady, "every steady lamp stays on, unshadowed, at its energy on the walk " + why)
	t.check(faded, "no lamp within 25 m of the camera has begun to fade")
	t.check(level.flickers.is_empty() or flicker_moved, "the lamps built to flicker still flicker")
	level.free()

## The renderer's pairing, as Godot 4's scene cull does it: a light pairs with a geometry instance when
## both are visible, the light's world AABB meets the instance's, and the light's cull mask meets the
## instance's layers. Counted per type (spot, omni), as the Compatibility renderer caps them.
static func pair_counts(level: Node3D) -> Dictionary:
	var lights: Array[Light3D] = []
	var lboxes: Array[AABB] = []
	var boxes: Array[AABB] = []
	var geoms: Array[GeometryInstance3D] = []
	_collect(level, Transform3D.IDENTITY, lights, lboxes, boxes, geoms)
	var out := {"spots": 0, "omnis": 0, "meshes": geoms.size(), "worst_spot": 0, "worst_omni": 0, "spot_mesh": "", "omni_mesh": ""}
	for l in lights:
		if l is SpotLight3D:
			out.spots += 1
		elif l is OmniLight3D:
			out.omnis += 1
	for gi in geoms.size():
		var g := geoms[gi]
		var ns := 0
		var no := 0
		for li in lights.size():
			var l := lights[li]
			if (l.light_cull_mask & g.layers) == 0 or not lboxes[li].intersects(boxes[gi]):
				continue
			if l is SpotLight3D:
				ns += 1
			elif l is OmniLight3D:
				no += 1
		if ns > out.worst_spot:
			out.worst_spot = ns
			out.spot_mesh = g.name
		if no > out.worst_omni:
			out.worst_omni = no
			out.omni_mesh = g.name
	return out

static func _collect(n: Node, xf: Transform3D, lights: Array[Light3D], lboxes: Array[AABB], boxes: Array[AABB], geoms: Array[GeometryInstance3D]) -> void:
	for c in n.get_children():
		var cx := xf
		if c is Node3D:
			if not (c as Node3D).visible:
				continue
			cx = xf * (c as Node3D).transform
		if c is Light3D:
			lights.append(c)
			lboxes.append(cx * (c as Light3D).get_aabb())
		elif c is GeometryInstance3D:
			var aabb := (c as VisualInstance3D).get_aabb()
			if aabb.size != Vector3.ZERO:
				geoms.append(c)
				boxes.append(cx * aabb)
		_collect(c, cx, lights, lboxes, boxes, geoms)
