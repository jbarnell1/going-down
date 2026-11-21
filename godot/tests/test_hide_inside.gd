# No mask over the camera while hiding (MH1b; the owner, 21 Nov: "The camera correctly being placed in the
# hiding spot means you don't need to add stuff as a mask over the camera itself, the objects do it for
# you."). Headless, on real floors built as a client builds them (client/level.gd and its views):
#   1. the overlay (client/hide_view.gd HideOverlay) draws nothing for any hiding state, any kind, on any
#      floor; it still draws the catch's mask and the party hat's brim;
#   2. in every kind of hide on the Playroom, the Clinic, the Annex and the Arboretum, sat back and peeking,
#      the camera (client/play_link.gd hide_camera's eye_local) is inside the hide's own 3D:
#        - nothing drawn is closer to it than the camera's near plane (0.05 m): no clipping through a wall;
#        - something of the hide faces it overhead (a lid, a roof, a top, a tabletop, a frame), except in the
#          open ball pit;
#        - its own geometry is in view round the edge of the gap (the frame), not a picture;
#        - and part of the gap is open: rays out through it at the eye travel at least SEE_OUT clear (the
#          den's netting counts as see-through, like the net it is).
# The hiding rules (sim/hiding.gd, sim/seek.gd) are not touched: where the camera sits is the client's.
extends RefCounted

const T = preload("res://tests/t.gd")
const HideView = preload("res://client/hide_view.gd")
const PlayLink = preload("res://client/play_link.gd")
const LevelScript = preload("res://client/level.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const Run = preload("res://sim/run.gd")
const Seek = preload("res://sim/seek.gd")
const Floor = preload("res://sim/floor.gd")
const Playroom = preload("res://sim/playroom.gd")
const Clinic = preload("res://sim/clinic.gd")
const Annex = preload("res://sim/annex.gd")
const Arboretum = preload("res://sim/arboretum.gd")
const Hides = preload("res://sim/hides.gd")

const NEAR := 0.05
var _next_id := 0
const SEE_OUT := 1.0
const FRAME_NEAR := 1.2
const ALL_KINDS: Array[String] = ["pit", "slide", "den", "playhouse", "table", "chest", "cubby", "bed", "cabinet", "desk", "shed", "bench", "under", "log"]

func test_the_overlay_draws_nothing_while_hiding(t: T) -> void:
	for kind in ALL_KINDS:
		for mode: String in ["sat", "peek"]:
			for out: bool in [true, false]:
				var lay := HideView.HideOverlay.layout(mode, kind, out, 1280, 720)
				var empty := float(lay["dark"]) == 0.0 and lay["hole"] == null and not bool(lay["frame"]) and int(lay["balls"]) == 0
				t.check(empty and not HideView.HideOverlay.draws_anything(mode, 0.0, false), "%s %s (view out %s): nothing drawn over the picture: %s" % [mode, kind, out, lay])
	t.check(HideView.HideOverlay.draws_anything("", 0.5, false), "the catch's mask is still drawn")
	t.check(HideView.HideOverlay.draws_anything("", 0.0, true), "and the party hat's brim")

func test_the_camera_sits_inside_the_real_hide(t: T) -> void:
	var seen := {}
	var floors: Array = [
		["playroom", Playroom.generate_playroom("arrival-a", 4)],
		["playroom", Playroom.generate_playroom("arrival-b", 4)],
		["clinic", Clinic.generate_clinic("hide-inside", 3)],
		["annex", Annex.generate_annex("arrival-a", 3)],
		["arboretum", Arboretum.generate_arboretum("seed-1", 6)],
		["arboretum", Arboretum.generate_arboretum("seed-2", 7)],
		["arboretum", Arboretum.generate_arboretum("seed-3", 5)],
	]
	for f: Array in floors:
		var plan: Floor.FloorPlan = f[1]
		var hides: Array[Playroom.Hide] = Playroom.hides(plan, plan.seed) if f[0] == "playroom" else Hides.hides_for(plan)
		var level: Node3D = LevelScript.new()
		level.build(PlanDump.dump(plan, Run.car_geometry(plan)), plan.seed, plan, hides)
		var tris := _triangles(level)
		var per_kind := {}
		for h in hides:
			# Two of each kind per floor is plenty (and keeps the test quick).
			var k := String(h.kind)
			if int(per_kind.get(k, 0)) >= 2:
				continue
			per_kind[k] = int(per_kind.get(k, 0)) + 1
			seen[k] = true
			for peek: bool in [false, true]:
				var bad := _check_hide(plan, h, peek, tris)
				t.check(bad == "", "%s %s hide %d (%s): the camera is inside the real hide%s" % [f[0], k, h.id, "peeking" if peek else "sat back", bad])
		level.free()
	var missing: Array[String] = []
	for kind in ALL_KINDS:
		if not seen.has(kind):
			missing.append(kind)
	t.check(missing.is_empty(), "every kind of hide was checked (missing: %s)" % str(missing))

## "" when the camera in `h` is inside its own 3D, else what is wrong.
func _check_hide(plan: Floor.FloorPlan, h: Playroom.Hide, peek: bool, tris: Dictionary) -> String:
	var ins := Seek.hide_inside_body(plan, h)
	var g := Vector3(float(Floor.dir_dx(h.gap)), 0, float(Floor.dir_dy(h.gap)))
	var e := PlayLink.eye_local(h.kind, h.eye, peek)
	var cam := Vector3(ins.x, ins.y, ins.z) + Vector3(0, e.y, 0) + g * e.z
	var near: Array = _near(tris, cam, 3.0)
	var out := ""
	# No clipping: nothing within the near plane.
	for tri: Array in near:
		var d := _dist_to_tri(cam, tri[0], tri[1], tri[2])
		if d < NEAR:
			out += " a surface %.3f m from the camera (%s);" % [d, tri[4]]
			break
	# Overhead: the hide itself (none in the open ball pit).
	if h.kind != &"pit":
		var up := _hit(near, cam, Vector3.UP, 2.4, true)
		if up < 0.0:
			out += " nothing of it overhead;"
	# The frame round the gap: rays just outside the gap's angle (or straight back in the pit) meet the hide.
	var half := minf(deg_to_rad(float(h.gap_half)), PI * 0.75)
	var right := Vector3.UP.cross(g).normalized()
	var framed := 0
	var rays := 0
	for side: float in [-1.0, 1.0]:
		for extra: float in [0.35, 0.6, 0.9]:
			var a := half + extra
			var flat := (g * cos(a) + right * side * sin(a)).normalized()
			rays += 1
			# Level with the eye or tilted up to an edge overhead (a tabletop, a lid, a roof).
			for up: float in [0.0, 0.5]:
				if _hit(near, cam, (flat * cos(up) + Vector3.UP * sin(up)).normalized(), FRAME_NEAR, true) >= 0.0:
					framed += 1
					break
	if h.kind != &"pit" and framed < 2:
		out += " none of its own walls in view round the gap (%d of %d rays);" % [framed, rays]
	# The view out: some rays through the gap at the eye go clear.
	var clear := 0
	var total := 0
	for i in 9:
		var a := lerpf(-half, half, i / 8.0) * 0.9
		for pitch: float in [-0.12, 0.0, 0.12]:
			var dir := (g * cos(a) + right * sin(a)).normalized()
			dir = (dir * cos(pitch) + Vector3.UP * sin(pitch)).normalized()
			total += 1
			if _hit(near, cam, dir, SEE_OUT, false) < 0.0:
				clear += 1
	if clear * 10 < total:
		out += " the gap is shut: %d of %d rays out go %.1f m clear;" % [clear, total, SEE_OUT]
	return out

## Every drawn triangle of the level in world space, bucketed by 2 m cells: key -> [[a, b, c, normal, name, see_through]].
func _triangles(level: Node3D) -> Dictionary:
	var out := {}
	_collect(level, Transform3D.IDENTITY, out)
	return out

func _collect(n: Node, xf: Transform3D, out: Dictionary) -> void:
	var here := xf
	if n is Node3D:
		here = xf * (n as Node3D).transform
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null and (n as MeshInstance3D).visible:
		var mesh := (n as MeshInstance3D).mesh
		var nm := str(n.name)
		var see := nm.ends_with("pnet") or nm.ends_with("net")
		for s in mesh.get_surface_count():
			var arr := mesh.surface_get_arrays(s)
			var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var ns: Variant = arr[Mesh.ARRAY_NORMAL]
			var idx: Variant = arr[Mesh.ARRAY_INDEX]
			var ids := PackedInt32Array()
			if idx is PackedInt32Array and (idx as PackedInt32Array).size() > 0:
				ids = idx
			else:
				ids.resize(vs.size())
				for i in vs.size():
					ids[i] = i
			var nb := here.basis.inverse().transposed()
			for k in range(0, ids.size() - 2, 3):
				var i0 := ids[k]
				var i1 := ids[k + 1]
				var i2 := ids[k + 2]
				var a := here * vs[i0]
				var b := here * vs[i1]
				var c := here * vs[i2]
				var nrm := (b - a).cross(c - a).normalized()
				if ns is PackedVector3Array and (ns as PackedVector3Array).size() == vs.size():
					nrm = (nb * ((ns as PackedVector3Array)[i0] + (ns as PackedVector3Array)[i1] + (ns as PackedVector3Array)[i2])).normalized()
				var tri := [a, b, c, nrm, nm, see, _next_id]
				_next_id += 1
				var lo := Vector2i(floori(minf(a.x, minf(b.x, c.x)) / 2.0), floori(minf(a.z, minf(b.z, c.z)) / 2.0))
				var hi := Vector2i(floori(maxf(a.x, maxf(b.x, c.x)) / 2.0), floori(maxf(a.z, maxf(b.z, c.z)) / 2.0))
				if (hi - lo).x > 6 or (hi - lo).y > 6:
					hi = lo + Vector2i(mini((hi - lo).x, 6), mini((hi - lo).y, 6))
				for bx in range(lo.x, hi.x + 1):
					for bz in range(lo.y, hi.y + 1):
						var key := Vector2i(bx, bz)
						if not out.has(key):
							out[key] = []
						(out[key] as Array).append(tri)
	for ch in n.get_children():
		_collect(ch, here, out)

## The triangles in the buckets within `r` of `p` (each once), within 2.5 m up or down.
func _near(tris: Dictionary, p: Vector3, r: float) -> Array:
	var out: Array = []
	var got := {}
	for bx in range(floori((p.x - r) / 2.0), floori((p.x + r) / 2.0) + 1):
		for bz in range(floori((p.z - r) / 2.0), floori((p.z + r) / 2.0) + 1):
			for tri: Array in tris.get(Vector2i(bx, bz), []):
				var id: int = tri[6]
				if got.has(id):
					continue
				got[id] = true
				if absf((tri[0] as Vector3).y - p.y) > 2.5 and absf((tri[1] as Vector3).y - p.y) > 2.5:
					continue
				out.append(tri)
	return out

## The distance along `dir` to the first surface facing the camera within `far` (-1: none). `count_nets`:
## whether a net stops the ray (it frames the view; it does not shut the gap).
func _hit(tris: Array, from: Vector3, dir: Vector3, far: float, count_nets: bool) -> float:
	var best := -1.0
	for tri: Array in tris:
		if bool(tri[5]) and not count_nets:
			continue
		if (tri[3] as Vector3).dot(dir) >= 0.0:
			continue   # turned away: culled, not seen
		var p: Variant = Geometry3D.ray_intersects_triangle(from, dir, tri[0], tri[1], tri[2])
		if p == null:
			continue
		var d := ((p as Vector3) - from).length()
		if d <= far and (best < 0.0 or d < best):
			best = d
	return best

func _dist_to_tri(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> float:
	var n := (b - a).cross(c - a)
	if n.length_squared() < 1e-12:
		return INF
	n = n.normalized()
	var proj := p - n * n.dot(p - a)
	# Inside the triangle: the plane's distance.
	var c0 := (b - a).cross(proj - a).dot(n)
	var c1 := (c - b).cross(proj - b).dot(n)
	var c2 := (a - c).cross(proj - c).dot(n)
	if (c0 >= 0 and c1 >= 0 and c2 >= 0) or (c0 <= 0 and c1 <= 0 and c2 <= 0):
		return absf(n.dot(p - a))
	var d := INF
	for e: Array in [[a, b], [b, c], [c, a]]:
		d = minf(d, p.distance_to(Geometry3D.get_closest_point_to_segment(p, e[0], e[1])))
	return d
