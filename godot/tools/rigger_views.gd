# RW1: the Rigger as the Ward's view draws him, from the player's own viewpoints, written out for the Blender renders
# (assets_src/blender/rigger/render_rigger_views.py). The Ward's own rules run (sim/ward/state.gd): one player stands
# at a house's hide spot (client/ward/view.gd house_spot), a noise is heard there (hear_at, as a flare's burst is), and
# the snapshot at chosen moments is shown by client/ward/view.gd. Every box and lamp near the camera, the figure's
# place, clip and time, the search hand and the arm's tube are written with the camera, one JSON file per run.
#   "$GODOT" --headless --path godot --script res://tools/rigger_views.gd -- out=<file.json> [seed=8143] [roam=1]
# RR1, roam=1: the solid, crawling Rigger (sim/ward/roam.gd) instead: a noise in a house brings him over the Ward's
# surfaces; the shots are from inside the house he searches (at the opening, then the hand), from a walkway he crawls
# on or under (above him), and from a neighbouring house's gallery while he is on a house's wall or roof.
extends SceneTree

const View = preload("res://client/ward/view.gd")
const Ward = preload("res://sim/ward/state.gd")
const House = preload("res://sim/ward/house.gd")
const Layout = preload("res://sim/ward/layout.gd")
const Footing = preload("res://sim/ward/footing.gd")
const TICK := 0.05
const EYE := 1.56

var out_path := ""
var seed_value := 8143
var roam := false
const G = preload("res://sim/ward/rigger_graph.gd")

func _initialize() -> void:
	# The views need the tree running (their _ready); the first frame has it.
	_run.call_deferred()

func _run() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2 and kv[0] == "out":
			out_path = kv[1]
		elif kv.size() == 2 and kv[0] == "seed":
			seed_value = int(kv[1])
		elif kv.size() == 2 and kv[0] == "roam":
			roam = kv[1] == "1"
	if out_path == "":
		push_error("out=<file.json>")
		quit(2)
		return
	var shots := []
	if roam:
		shots = await _roam_stays()
		var rf := FileAccess.open(out_path, FileAccess.WRITE)
		rf.store_string(JSON.stringify({"seed": seed_value, "shots": shots}, " "))
		rf.close()
		print("RR1 wrote %d shots to %s" % [shots.size(), out_path])
		quit(0)
		return
	var model := Ward.new(seed_value)
	var window_house := -1
	for site: Dictionary in model.layout.houses:
		if site.style == "laundry_maisonette":
			window_house = int(site.id)
	# A house he reaches by its front door, and the one with the sash window.
	for house: int in [1, window_house]:
		if house < 0:
			continue
		shots.append_array(await _stay(house))
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"seed": seed_value, "shots": shots}, " "))
	f.close()
	print("RW1 wrote %d shots to %s" % [shots.size(), out_path])
	quit(0)

## One stay: the player at the house's hide spot, a noise there, and pictures through the climb and the search.
func _stay(house: int) -> Array:
	var view := View.new(seed_value, Vector3.ZERO)
	view.own_hud = false
	root.add_child(view)
	var ward := Ward.new(seed_value)
	ward.crew_size = 1
	var fixture: House = ward.houses[house]
	# The sash is in the middle room: there the player can watch it; else the entry corner by the door.
	var spot := View.house_spot(fixture, "middle" if fixture.search_window.has_volume() else "corner")
	var crew := {"p": {"position": spot, "aboard": false, "active": true}}
	ward.leave(0.0)
	var now := 1.0
	ward.hear_at(spot, now)
	var started := now
	var shots := []
	var walkways := _walkway_eyes(ward, house)
	var walkway := walkways[0] if not walkways.is_empty() else spot + Vector3(0, 6, -10)
	# Where he comes in: the sash's middle, or the front doorway's.
	var opening := fixture.to_world(fixture.search_window.get_center() if fixture.search_window.has_volume() else Vector3(0, 1.2, 0))
	# The walkway eye that sees where he ends up: hanging at the house, his head about a metre over the arm's shoulder.
	await physics_frame
	await physics_frame
	walkway = _clear_eye(view, walkways, fixture.to_world(fixture.shoulder) + Vector3.UP * 1.0, walkway)
	var climb_at := [0.35, 0.7, 0.95]
	var taken := {}
	var reach_shots := 0
	while now < started + 40.0 and reach_shots < 3:
		now += TICK
		ward.step(now, TICK, 15.0, crew)
		var snap := ward.snapshot(now)
		if ward.caught.size() > 0:
			break
		var climb := (now - started - Ward.WARN_SECONDS) / Ward.CLIMB_SECONDS
		for k in climb_at.size():
			if not taken.has(k) and ward.encounter == &"climbing" and climb >= climb_at[k]:
				taken[k] = true
				view.show_host(snap, now, "p", [])
				var head := _rigger_head(view)
				shots.append(_shot(view, "h%d-climb%d-walkway" % [house, k], walkway, view.rigger.global_position.lerp(head, 0.5), now))
				if k == 1:
					shots.append(_close(view, "h%d-climb%d-close" % [house, k], now))
				if k == 2:
					shots.append(_shot(view, "h%d-climb%d-inside" % [house, k], spot + Vector3.UP * EYE, opening, now))
		if ward.encounter == &"searching" and ward.arm != null and ward.arm.points.size() > 1:
			# The hand at a few lengths along its route: through the doorway or sill, halfway, near the player.
			var hand := fixture.to_world(ward.arm.points[-1])
			var length := 0.0
			for i in range(1, ward.arm.points.size()):
				length += ward.arm.points[i - 1].distance_to(ward.arm.points[i])
			var want := [1.2, 2.6, 4.0]
			if reach_shots < want.size() and length >= want[reach_shots]:
				view.show_host(snap, now, "p", [])
				var eye := spot + Vector3.UP * EYE
				shots.append(_shot(view, "h%d-reach%d-inside" % [house, reach_shots], eye, opening if reach_shots == 0 else hand, now))
				if reach_shots == 1:
					shots.append(_shot(view, "h%d-reach%d-walkway" % [house, reach_shots], walkway, view.rigger.global_position.lerp(_rigger_head(view), 0.5), now))
					shots.append(_close(view, "h%d-reach%d-close" % [house, reach_shots], now))
				reach_shots += 1
	view.free()
	return shots

## RR1: trips of the crawling Rigger to two houses in turn (a noise in each), with the shots named in the header.
func _roam_stays() -> Array:
	var view := View.new(seed_value, Vector3.ZERO)
	view.own_hud = false
	root.add_child(view)
	await physics_frame
	await physics_frame
	var ward := Ward.new(seed_value)
	ward.crew_size = 1
	ward.enable_roam()
	ward.leave(0.0)
	var g := ward.roam.g
	var targets: Array[int] = []
	for h in range(1, ward.houses.size()):
		if not g.openings_of(h).is_empty():
			targets.append(h)
	var shots := []
	var now := 0.5
	var taken := {}
	for trip in mini(4, targets.size()):
		var house: int = targets[(trip * 3) % targets.size()]
		var fixture: House = ward.houses[house]
		var spot := View.house_spot(fixture, "corner")
		var crew := {"p": {"position": spot, "aboard": false, "active": true, "creep": true}}
		now += 1.0
		ward.hear_at(fixture.to_world(fixture.areas[&"entry"]), now)
		var reach_shots := 0
		var until := now + 60.0
		while now < until:
			now += TICK
			ward.step(now, TICK, 15.0, crew)
			var snap := ward.snapshot(now)
			if ward.caught.size() > 0:
				break
			var n := ward.roam.from_node
			var body := ward.roam.at
			if ward.roam.out() and g.bridge_of[n] >= 0 and not taken.has("walkway"):
				# From the walkway he is on or under: a player on its deck above, looking down at him.
				var eye := _deck_eye(ward, g.bridge_of[n], body)
				if eye != Vector3.INF:
					taken["walkway"] = true
					view.show_host(snap, now, "p", [])
					shots.append(_shot(view, "after-walkway-%s" % G.KIND_NAMES[g.kind[n]], eye, view.rigger.global_position, now))
			if ward.roam.out() and g.kind[n] in [G.ROOF, G.WALL] and not taken.has("roof") and g.house_of[n] >= 0:
				var eye2 := _neighbour_eye(ward, g.house_of[n], body)
				if eye2 != Vector3.INF:
					taken["roof"] = true
					view.show_host(snap, now, "p", [])
					shots.append(_shot(view, "after-neighbour-%s" % G.KIND_NAMES[g.kind[n]], eye2, view.rigger.global_position, now))
			if ward.encounter == &"searching" and ward.arm != null and ward.arm.points.size() > 1 and not taken.has("inside"):
				var hand := fixture.to_world(ward.arm.points[-1])
				var length := 0.0
				for i in range(1, ward.arm.points.size()):
					length += ward.arm.points[i - 1].distance_to(ward.arm.points[i])
				var want := [1.0, 2.6]
				if reach_shots < want.size() and length >= want[reach_shots]:
					view.show_host(snap, now, "p", [])
					var o: Dictionary = fixture.openings()[ward.roam.opening]
					var look := fixture.to_world(o.shoulder) if reach_shots == 0 else hand
					shots.append(_shot(view, "after-inside-%s%d-%d" % [o.kind, int(o.side) + 1, reach_shots], spot + Vector3.UP * EYE, look, now))
					reach_shots += 1
					if reach_shots >= want.size():
						taken["inside"] = true
			if ward.encounter == &"lingering":
				break
	shots.append_array(await _stage2_shots(view, ward))
	view.free()
	return shots

## RR1 stage 2: him on a roof seen from the next house, across a wall over a window seen from inside, under a walkway
## seen from its deck, and rearing then grabbing a loud player out of doors. Each surface is taken from his own graph's
## poses (the same the host puts him on), the clip as the view plays it, his feet solved.
func _stage2_shots(view: View, ward: Ward) -> Array:
	var g := ward.roam.g
	var shots := []
	var now := 200.0
	var want := {"roof": G.ROOF, "wall": G.WALL, "under": G.UNDER}
	for name: String in want:
		var best := -1
		var best_gap := INF
		for i in g.pos.size():
			if not g.joined(i) or g.kind[i] != want[name]:
				continue
			if name == "under" and g.bridge_of[i] < 0:
				continue
			if name == "wall":
				# Crossing a ground-floor window: the wall pose nearest where his middle is when he is right across it.
				var h := g.house_of[i]
				if h < 0:
					continue
				var fixture: House = ward.houses[h]
				var gap := INF
				for o: Dictionary in fixture.openings():
					if o.kind == &"window" and int(o.get("storey", 0)) == 0:
						var across: Vector3 = fixture.to_world((o.hole as AABB).get_center()) + (G.house_axes(fixture) * Vector3(float(o.side), 0, 0)).normalized() * G.STAND
						gap = minf(gap, across.distance_to(g.pos[i]))
				# The wall pose nearest a ground-floor window's middle.
				if best < 0 or gap < best_gap:
					best = i
					best_gap = gap
				continue
			best = i
			break
		if best < 0:
			continue
		# Pose him there as the snapshot would carry him, crawling. Across a window: half way along his edge to the
		# next pose up the wall, so the window frames part of him passing.
		ward.roam.from_node = best
		ward.roam.to_node = -1
		ward.roam.at = g.pos[best]
		ward.roam.turn = g.rot[best]
		if name == "wall":
			for j in g.adj[best]:
				if g.kind[j] == G.WALL and g.pos[j].y > g.pos[best].y + 1.0:
					ward.roam.to_node = j
					ward.roam.frac = 0.5
					ward.roam.at = g.pos[best].lerp(g.pos[j], 0.5)
					ward.roam.turn = g.rot[best].slerp(g.rot[j], 0.5)
					break
		ward.roam.trip = &"house"
		ward.encounter = &"climbing"
		now += 1.0
		view.show_host(ward.snapshot(now), now, "p", [])
		var body := view.rigger.global_position
		var eye := Vector3.INF
		var look := Vector3.INF
		if name == "roof":
			eye = _neighbour_eye(ward, g.house_of[best], body)
		elif name == "under":
			# From the nearest house's gallery, across the gap at him under the walkway.
			eye = _neighbour_eye(ward, _nearest_house(ward, body), body)
		else:
			var fixture: House = ward.houses[g.house_of[best]]
			for o: Dictionary in fixture.openings():
				if o.kind == &"window" and int(o.get("storey", 0)) == 0:
					var hole := fixture.to_world((o.hole as AABB).get_center())
					if eye == Vector3.INF or hole.distance_to(g.pos[best]) < 6.0:
						# In the room the window opens into, square to it 1.8 m in, clear of the room's partitions.
						var local_hole := fixture.to_local(hole)
						var room_z := local_hole.z
						var room := fixture.area_at(local_hole + Vector3(-float(o.side) * 1.0, 0.0, 0.0))
						if room != &"":
							room_z = (fixture.areas[room] as Vector3).z
						eye = fixture.to_world(Vector3(local_hole.x - float(o.side) * 1.8, local_hole.y + 0.4, lerpf(local_hole.z, room_z, 0.6)))
						look = hole
		if eye != Vector3.INF:
			shots.append(_shot(view, "s2-%s" % name, eye, look if look != Vector3.INF else body, now))
	# The rear-up and the grab: a player sprints out of doors near him and stops; he chases, rears, then reaches.
	var h0 := g.house_of[ward.roam.from_node] if g.house_of[ward.roam.from_node] >= 0 else 1
	var fixture0: House = ward.houses[h0]
	# The player on the gallery on his side of the house.
	var site0: Dictionary = ward.layout.houses[h0]
	var centre0 := Vector3(float(site0.x), float(site0.z) + 0.15, float(site0.y))
	var toward0 := Vector3(ward.roam.at.x - centre0.x, 0.0, ward.roam.at.z - centre0.z).normalized()
	var spot := centre0 + toward0 * (maxf(float(site0.w), float(site0.d)) * 0.5 + 0.8)
	ward.roam.trip = &""
	ward.encounter = &"lingering"
	ward.roam.linger_until = now + 60.0
	var reared := false
	while now < 260.0:
		now += TICK
		var evs := ward.step(now, TICK, 15.0, {"p": {"position": spot, "aboard": false, "active": true, "sprint": true}})
		for e in evs:
			if e.kind == &"rear" and not reared:
				reared = true
				for k in 10:
					now += TICK
					ward.step(now, TICK, 15.0, {"p": {"position": spot, "aboard": false, "active": true}})
				view.show_host(ward.snapshot(now), now, "p", [])
				shots.append(_shot(view, "s2-rear", spot + Vector3.UP * EYE, view.rigger.global_position, now))
			if e.kind == &"contact":
				view.show_host(ward.snapshot(now), now, "p", [])
				shots.append(_shot(view, "s2-grab", spot + Vector3.UP * EYE + (view.rigger.global_position - spot).normalized() * -1.5, view.rigger.global_position, now))
				return shots
	return shots

## An eye on walkway `b`'s deck above (or beside) a body at `at`: the nearest point of its path, at eye height.
static func _deck_eye(ward: Ward, b: int, at: Vector3) -> Vector3:
	var path: Array = ward.layout.bridges[b].path
	var best := Vector3.INF
	for i in range(1, path.size()):
		var p := Geometry3D.get_closest_point_to_segment(at, Footing.path_point(path[i - 1]), Footing.path_point(path[i]))
		if best == Vector3.INF or p.distance_to(at) < best.distance_to(at):
			best = p
	if best == Vector3.INF:
		return best
	# A step along the deck from right over him, so he is in the frame.
	var along := (Footing.path_point(path[-1]) - Footing.path_point(path[0])).normalized()
	return best + along * 3.0 + Vector3.UP * EYE

## The house whose middle is nearest a point.
static func _nearest_house(ward: Ward, at: Vector3) -> int:
	var best := 0
	var d := INF
	for i in ward.houses.size():
		var site: Dictionary = ward.layout.houses[i]
		var e := Vector2(float(site.x) - at.x, float(site.y) - at.z).length()
		if e < d:
			d = e
			best = i
	return best

## An eye on the gallery of the house nearest house `h` (not h), facing him.
static func _neighbour_eye(ward: Ward, h: int, at: Vector3) -> Vector3:
	var best := -1
	var d := INF
	for i in ward.houses.size():
		if i == h:
			continue
		var site: Dictionary = ward.layout.houses[i]
		var e := Vector2(float(site.x) - at.x, float(site.y) - at.z).length()
		if e < d:
			d = e
			best = i
	if best < 0:
		return Vector3.INF
	var site: Dictionary = ward.layout.houses[best]
	var centre := Vector3(float(site.x), float(site.z) + 0.15, float(site.y))
	var toward := Vector3(at.x - centre.x, 0.0, at.z - centre.z).normalized()
	var half := maxf(float(site.w), float(site.d)) * 0.5 + 0.8
	return centre + toward * half + Vector3.UP * EYE

## The figure's head (the skeleton's head bone), or his place when there is no skeleton.
static func _rigger_head(view: View) -> Vector3:
	var found := view.rigger.find_children("*", "Skeleton3D", true, false)
	if found.is_empty():
		return view.rigger.global_position
	var skeleton := found[0] as Skeleton3D
	var bone := skeleton.find_bone("head")
	if bone < 0:
		return view.rigger.global_position + Vector3.UP
	return skeleton.global_transform * skeleton.get_bone_global_pose(bone).origin

## The first walkway eye with nothing solid between it and `at` (the view's own walls), else `fallback`.
static func _clear_eye(view: View, eyes: Array[Vector3], at: Vector3, fallback: Vector3) -> Vector3:
	var space := view.get_world_3d().direct_space_state
	for eye in eyes:
		if space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, at)).is_empty():
			return eye
	return fallback

## Walkway eyes 6 to 15 m from the house's loaded line, on the fixed bridges, nearest 10 m first: where somebody
## across the gap stands.
static func _walkway_eyes(ward: Ward, house: int) -> Array[Vector3]:
	var site: Dictionary = ward.layout.houses[house]
	var fixture: House = ward.houses[house]
	var line := Vector3(float(site.x) + (1.0 if fixture.window_side > 0 else -1.0) * (float(site.w) * 0.5 + Layout.GALLERY - 0.13),
		float(site.z), float(site.y) - float(site.d) * 0.5 - Layout.GALLERY + 0.13)
	var found := []
	for edge: Dictionary in ward.layout.bridges:
		if edge.kind != "fixed":
			continue
		var path: Array = edge.path
		for i in range(1, path.size()):
			var a := Footing.path_point(path[i - 1])
			var b := Footing.path_point(path[i])
			for s in 11:
				var p := a.lerp(b, float(s) / 10.0)
				var d := Vector2(p.x - line.x, p.z - line.z).length()
				if d >= 6.0 and d <= 15.0:
					found.append([absf(d - 10.0), p + Vector3.UP * EYE])
	found.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0])
	var out: Array[Vector3] = []
	for row: Array in found:
		out.append(row[1])
	return out

## Not a player's view: a close look from his side, 5 m off, at his wrist and body (the joins, the arm's end).
func _close(view: View, name: String, now: float) -> Dictionary:
	var basis := view.rigger.global_transform.basis.orthonormalized()
	var wrist := view.rigger.global_transform * view.rigger_wrist
	var middle := wrist.lerp(view.rigger.global_position, 0.45)
	return _shot(view, name, middle + basis.x * 5.5 + Vector3.UP * 1.2 + basis.z * 1.5, middle, now)

func _shot(view: View, name: String, eye: Vector3, target: Vector3, now: float) -> Dictionary:
	# A looping clip (the hang while he searches) runs on the engine's clock; here, on the host's.
	if view.animation != null and view.animation.is_playing():
		view.animation.seek(fmod(now, view.animation.current_animation_length), true)
	var boxes := []
	for node: Node in view.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if not mi.is_visible_in_tree() or not mi.mesh is BoxMesh:
			continue
		var at := mi.global_position
		if at.distance_to(eye) > 34.0 and at.distance_to(target) > 20.0:
			continue
		var colour := Color(0.5, 0.5, 0.5)
		var glow := false
		var m := mi.material_override
		if m is StandardMaterial3D:
			colour = (m as StandardMaterial3D).albedo_color
			glow = (m as StandardMaterial3D).emission_enabled
		elif m is ShaderMaterial:
			colour = (m as ShaderMaterial).get_shader_parameter("base_color")
		boxes.append({"m": _xf(mi.global_transform), "size": _v((mi.mesh as BoxMesh).size), "c": [colour.r, colour.g, colour.b, colour.a], "glow": glow})
	var lights := []
	for node: Node in view.find_children("*", "OmniLight3D", true, false):
		var l := node as OmniLight3D
		if not l.is_visible_in_tree() or l.global_position.distance_to(eye) > 30.0:
			continue
		lights.append({"at": _v(l.global_position), "c": [l.light_color.r, l.light_color.g, l.light_color.b],
			"energy": l.light_energy, "range": l.omni_range, "rigger": l == view.lamp_light})
	var tube := []
	if view.ribbon.get_surface_count() > 0:
		var arrays := view.ribbon.surface_get_arrays(0)
		for p: Vector3 in arrays[Mesh.ARRAY_VERTEX]:
			tube.append(_v(p))
	var player := view.animation
	# RR1 stage 2: his legs as the feet modifier solved them (client/ward/rigger_feet.gd): each held leg's knee, ankle
	# and foot (world), for the render to pose the same.
	var legs := {}
	if view.feet != null and view.feet.active:
		for k in 3:
			view.feet.now = now + float(k) * 0.02
			view.feet._process_modification()
		var sk: Skeleton3D = view.feet.get_skeleton()
		for i: int in view.feet.chains.size():
			var foot: Vector3 = view.feet.feet[i]
			if foot == Vector3.INF:
				continue
			var ids: PackedInt32Array = view.feet.chains[i]
			legs[view.feet.LEGS[i]] = [_v(sk.global_transform * sk.get_bone_global_pose(ids[2]).origin),
				_v(sk.global_transform * sk.get_bone_global_pose(ids[3]).origin), _v(foot)]
	return {"name": name, "now": now, "eye": _v(eye), "target": _v(target), "fov": View.Main.VFOV,
		"rigger": {"drawn": view.rigger.visible, "m": _xf(view.rigger.global_transform), "path": view.rigger.scene_file_path, "legs": legs,
			"clip": str(player.assigned_animation) if player != null else "", "time": player.current_animation_position if player != null and player.assigned_animation != &"" else 0.0},
		"hand": {"drawn": view.hand.visible, "m": _xf(view.hand.global_transform)},
		"tube": tube, "boxes": boxes, "lights": lights, "state": view.describe_rigger()}

static func _v(p: Vector3) -> Array:
	return [p.x, p.y, p.z]

static func _xf(t: Transform3D) -> Array:
	return [_v(t.basis.x), _v(t.basis.y), _v(t.basis.z), _v(t.origin)]
