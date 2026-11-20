# RW1: the Rigger as the Ward's view draws him, from the player's own viewpoints, written out for the Blender renders
# (assets_src/blender/rigger/render_rigger_views.py). The Ward's own rules run (sim/ward/state.gd): one player stands
# at a house's hide spot (client/ward/view.gd house_spot), a noise is heard there (hear_at, as a flare's burst is), and
# the snapshot at chosen moments is shown by client/ward/view.gd. Every box and lamp near the camera, the figure's
# place, clip and time, the search hand and the arm's tube are written with the camera, one JSON file per run.
#   "$GODOT" --headless --path godot --script res://tools/rigger_views.gd -- out=<file.json> [seed=8143]
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
	if out_path == "":
		push_error("out=<file.json>")
		quit(2)
		return
	var shots := []
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
	return {"name": name, "now": now, "eye": _v(eye), "target": _v(target), "fov": View.Main.VFOV,
		"rigger": {"drawn": view.rigger.visible, "m": _xf(view.rigger.global_transform), "path": view.rigger.scene_file_path,
			"clip": str(player.assigned_animation) if player != null else "", "time": player.current_animation_position if player != null and player.assigned_animation != &"" else 0.0},
		"hand": {"drawn": view.hand.visible, "m": _xf(view.hand.global_transform)},
		"tube": tube, "boxes": boxes, "lights": lights, "state": view.describe_rigger()}

static func _v(p: Vector3) -> Array:
	return [p.x, p.y, p.z]

static func _xf(t: Transform3D) -> Array:
	return [_v(t.basis.x), _v(t.basis.y), _v(t.basis.z), _v(t.origin)]
