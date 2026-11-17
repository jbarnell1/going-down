# The Minder model's check, headless: loads assets/entities/minder.glb (built by
# assets_src/blender/minder/build_minder.py) the way the game would, and checks that
#  - every pose the rules can set (every `.anim = &"..."` in sim/seek.gd, plus the documented list)
#    has an animation of that exact name;
#  - the loops loop and the one-shots do not (they end held), and each one-shot lasts exactly as long
#    as the rules hold that pose (STRAIGHTEN_TIME, LOOK_TIME, SLUMP_TIME, CATCH_TIME);
#  - the triangle and bone counts are within the Orderly's (assets/entities/orderly.glb);
#  - the glowing mask is on the front of the head only: every vertex of the mask surface is at least
#    3 cm in front of the skull's middle and no face of it turns sideways or back (each face's normal
#    is within about 78 degrees of +Z, the way the model faces; the plate's rim curls back, so not 0).
# Exit code 0 when all of it holds. Run after an import pass (node godot/tools/godot.mjs import):
#   "$GODOT" --headless --path godot --script res://tools/minder_check.gd
# The break: build_minder.py -- --drop cover, import, and this goes red (cover missing).
extends SceneTree

const Seek = preload("res://sim/seek.gd")
const POSES := ["stand", "walk", "straighten", "cover", "prowl", "sweep", "look", "slump", "run", "catch"]
const LOOPS := ["stand", "walk", "cover", "prowl", "sweep", "run"]

var problems: Array[String] = []

func _init() -> void:
	var minder := _load("res://assets/entities/minder.glb")
	var orderly := _load("res://assets/entities/orderly.glb")
	if minder == null or orderly == null:
		print("minder check: FAIL (could not load the models)")
		quit(1)
		return
	var ap: AnimationPlayer = minder.find_child("AnimationPlayer", true, false)
	var have: Array = Array(ap.get_animation_list()) if ap else []
	var names := PackedStringArray()
	for n: StringName in have:
		names.append(String(n))
	print("animations: ", ", ".join(names))

	# 1. Every pose the rules can set has an animation.
	var wanted: Array = POSES.duplicate()
	for name: String in _rule_poses():
		if not wanted.has(name):
			wanted.append(name)
	for name: String in wanted:
		if not have.has(StringName(name)) and not have.has(name):
			problems.append("no animation for the rules' pose \"%s\"" % name)

	# 2. Loops loop, one-shots end held and last as long as the rules hold them.
	var lengths := {"straighten": Seek.STRAIGHTEN_TIME, "look": Seek.LOOK_TIME, "slump": Seek.SLUMP_TIME,
		"catch": Seek.CATCH_TIME}
	for name: String in POSES:
		if not have.has(StringName(name)) and not have.has(name):
			continue
		var a: Animation = ap.get_animation(name)
		var loops := a.loop_mode != Animation.LOOP_NONE
		if LOOPS.has(name) != loops:
			problems.append("%s should %s" % [name, "loop" if LOOPS.has(name) else "play once and hold"])
		if lengths.has(name) and absf(a.length - float(lengths[name])) > 0.02:
			problems.append("%s lasts %.2f s, the rules hold it %.2f s" % [name, a.length, lengths[name]])
		print("  %-10s %5.2f s  %s" % [name, a.length, "loop" if loops else "once, held"])

	# 3. Counts within the Orderly's.
	var mt := _tris(minder)
	var ot := _tris(orderly)
	var mb := _bones(minder)
	var ob := _bones(orderly)
	print("triangles: minder %d, orderly %d; bones: minder %d, orderly %d" % [mt, ot, mb, ob])
	if mt > ot:
		problems.append("%d triangles, more than the Orderly's %d" % [mt, ot])
	if mb > ob:
		problems.append("%d bones, more than the Orderly's %d" % [mb, ob])

	# 4. The face is on the front only.
	_check_mask(minder)

	print("minder check: %s" % ("PASS" if problems.is_empty() else "FAIL (%d problems)" % problems.size()))
	for p in problems:
		print("  ", p)
	minder.free()
	orderly.free()
	quit(0 if problems.is_empty() else 1)

func _load(path: String) -> Node:
	var ps: PackedScene = load(path)
	return ps.instantiate() if ps else null

## Every pose name the rules assign in sim/seek.gd.
func _rule_poses() -> Array:
	var src := FileAccess.get_file_as_string("res://sim/seek.gd")
	var re := RegEx.new()
	re.compile("\\.anim = &\"(\\w+)\"")
	var out := []
	for m: RegExMatch in re.search_all(src):
		if not out.has(m.get_string(1)):
			out.append(m.get_string(1))
	return out

func _tris(root: Node) -> int:
	var n := 0
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		for s in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(s)
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			n += idx.size() / 3 if idx.size() > 0 else (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return n

func _bones(root: Node) -> int:
	var n := 0
	for sk: Skeleton3D in root.find_children("*", "Skeleton3D", true, false):
		n += sk.get_bone_count()
	return n

func _check_mask(root: Node) -> void:
	var found := false
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		var all_z := []
		var mask_surface := -1
		for s in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(s)
			if m and m.resource_name.to_lower().contains("mask"):
				mask_surface = s
		if mask_surface < 0:
			continue
		found = true
		# the skull's middle: the average of every vertex above the shoulders, head bone or not
		var head_mid := Vector3.ZERO
		var cnt := 0
		for s in mi.mesh.get_surface_count():
			for v: Vector3 in mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]:
				if v.y > 2.08:
					head_mid += v
					cnt += 1
		head_mid /= maxi(cnt, 1)
		var arr := mi.mesh.surface_get_arrays(mask_surface)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		var behind := 0
		for v in verts:
			if v.z <= head_mid.z + 0.03:
				behind += 1
		var backward := 0
		var min_nz := 1.0
		for i in range(0, idx.size(), 3):
			var a := verts[idx[i]]
			var b := verts[idx[i + 1]]
			var c := verts[idx[i + 2]]
			# Godot's front faces wind clockwise: the outward normal is (c - a) x (b - a)
			var n := (c - a).cross(b - a).normalized()
			min_nz = minf(min_nz, n.z)
			if n.z < 0.2:
				backward += 1
		print("mask: %d vertices, %d faces; nearest to the back %.3f m in front of the skull's middle; most sideways face normal z %.2f; %d faces turned sideways or back" % [
			verts.size(), idx.size() / 3, _min_z(verts) - head_mid.z, min_nz, backward])
		if behind > 0:
			problems.append("%d mask vertices are not on the front of the head" % behind)
		if backward > 0:
			problems.append("%d mask faces turn sideways or back" % backward)
	if not found:
		problems.append("no mask surface (a material named *mask*)")

func _min_z(verts: PackedVector3Array) -> float:
	var m := INF
	for v in verts:
		m = minf(m, v.z)
	return m
