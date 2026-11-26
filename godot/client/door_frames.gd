# LA1: the shared door-frame kit (looks only). A frame on each face of every plain doorway of a floor: two jambs and
# a head standing PROUD off the wall face round the opening, tinted to the place (white enamel steel in the Clinic,
# cream-painted wood in the Annex, grey steel in the Reactor and the Prison). The frame sits on the wall face AROUND
# the opening: its inner edges are the opening's own edges (the rules' DOOR_W by DOOR_H), so the way through is
# exactly as wide and as high as before, and nothing of it reaches into the opening. It has no collision: the client
# draws no solids at all (the rules move every body), and the residents' sight and hearing read the rules' own plan
# (godot/sim), never a mesh. Where a place already frames a doorway itself (the Prison's cells and bank room, with
# their steel doors), the place leaves it out of this kit.
#
# The doorways are the plan's own "door" edges, so every screen draws the same frames from the same plan; nothing
# here is random. The frames are merged into one mesh per GROUP cells square and storey (named like the walls' chunks,
# so the lower storey's go on its own layer): a few dozen meshes on the biggest floor, each still meeting few enough
# lamps for the renderer's per-mesh limit (tests/test_light_pairs.gd).
extends RefCounted

## How far the frame stands off the wall face, the jambs' width along the wall, the head's height over the opening.
const PROUD := 0.045
const JAMB_W := 0.065
const HEAD_H := 0.04
## The frame's back stands this far off the wall face, and its foot this far over the floor (no shared planes).
const BACK_GAP := 0.001
const FOOT := 0.002
## The places' tints.
const CLINIC := Color(0.88, 0.89, 0.86)
const CLINIC_GRIME := Color(0.62, 0.58, 0.42)
const ANNEX := Color(0.84, 0.77, 0.58)
const STEEL := Color(0.46, 0.48, 0.49)
## The frames are merged into one mesh per GROUP cells square per storey.
const GROUP := 8
const STEEL_TEX := preload("res://assets/reactor/steel_plate.webp")

## Frames every plain doorway of `lv` (built up to its walls), in `tint`; `grime` (if not transparent) is mixed in by
## the doorway's corruption (the Clinic's walk from clean to corrupt); `tex` a texture laid on in world space (steel).
## `skip(level, a, b)` true leaves the doorway between cells a and b to the place. Returns what was framed, also kept
## as the level's "door_frames" meta: [{level, a, b, mid, along, faces: [normal, ...]}].
static func build(lv: Level, tint: Color, grime := Color(0, 0, 0, 0), tex: Texture2D = null, skip := Callable()) -> Array[Dictionary]:
	var framed: Array[Dictionary] = []
	var sts := {}
	# The rules' furniture beside a doorway (drawn by now): a jamb never runs into it (see _frame).
	var level_of := {}
	for pc in lv.pieces:
		level_of[pc.id] = pc.level
	var keep_off: Array = [[], []]
	for d: Dictionary in lv.furniture_drawn:
		(keep_off[int(level_of.get(d.piece, 0))] as Array).append(d.rect)
	var lift_edge := lv._lift_edge()
	var s := Level.S
	for level in 2:
		var vert: Array = lv.edges[level].vertical
		var hor: Array = lv.edges[level].horizontal
		for y in lv.H:
			for x in lv.W + 1:
				if vert[y * (lv.W + 1) + x] == "door" and not (level == lv.landing.x and lift_edge == Vector4i(0, x, y, 1)):
					_doorway(lv, level, Vector2i(x - 1, y), Vector2i(x, y), Vector3(x * s, 0, (y + 0.5) * s), Vector3(0, 0, 1), tint, grime, skip, sts, framed, keep_off[level])
		for y in lv.H + 1:
			for x in lv.W:
				if hor[y * lv.W + x] == "door" and not (level == lv.landing.x and lift_edge == Vector4i(1, x, y, 1)):
					_doorway(lv, level, Vector2i(x, y - 1), Vector2i(x, y), Vector3((x + 0.5) * s, 0, y * s), Vector3(1, 0, 0), tint, grime, skip, sts, framed, keep_off[level])
	var mat := Level.prop_material(Color.WHITE, tex, true, 0.0, 0.0, tex != null)
	for key: String in sts:
		var st: SurfaceTool = sts[key]
		st.index()
		var mi := MeshInstance3D.new()
		mi.name = key
		mi.mesh = st.commit()
		mi.material_override = mat
		lv.add_child(mi)
	lv.set_meta(&"door_frames", framed)
	return framed

static func _doorway(lv: Level, level: int, a: Vector2i, b: Vector2i, mid: Vector3, along: Vector3, tint: Color, grime: Color, skip: Callable,
		sts: Dictionary, framed: Array[Dictionary], keep_off: Array) -> void:
	if skip.is_valid() and bool(skip.call(level, a, b)):
		return
	var faces: Array[Vector3] = []
	for c: Vector2i in [a, b]:
		if lv.kind(level, c.x, c.y) == "void":
			continue
		var n := Vector3(c.x + 0.5, 0, c.y + 0.5) * Level.S - mid
		n = (n - along * n.dot(along)).normalized()
		var col := tint
		if grime.a > 0.0:
			col = tint.lerp(grime, smoothstep(0.25, 0.9, lv.corruption(level, c.x, c.y)) * 0.8)
		var centre := mid + n * 0.5
		var key := "%d_%d_%d_dframe" % [level, int(floor(centre.x / (Level.S * GROUP))), int(floor(centre.z / (Level.S * GROUP)))]
		if not sts.has(key):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			sts[key] = st
		_frame(sts[key], mid + Vector3(0, level * Level.LH, 0), along, n, col, keep_off)
		faces.append(n)
	if not faces.is_empty():
		framed.append({"level": level, "a": a, "b": b, "mid": mid, "along": along, "faces": faces})

## One face's frame: `mid` the opening's middle on the wall line at its floor, `along` the wall, `n` out of this face.
## `keep_off`: floor rectangles (world x, z) of furniture standing against this wall; a jamb beside one stands only as
## proud as the gap left to it, and is left out where there is no gap (the piece hides that foot of the frame).
static func _frame(st: SurfaceTool, mid: Vector3, along: Vector3, n: Vector3, col: Color, keep_off: Array = []) -> void:
	var h := Level.DOOR_W * 0.5
	var f0 := Level.WALL_T * 0.5 + BACK_GAP
	var f1 := Level.WALL_T * 0.5 + PROUD
	for sgn: float in [-1.0, 1.0]:
		var reach := f1
		for r: Rect2 in keep_off:
			# The jamb's footprint at full depth, and how far out from the wall line the piece starts.
			var p0 := mid + along * (sgn * h) + n * f0
			var p1 := mid + along * (sgn * (h + JAMB_W)) + n * f1
			var foot := Rect2(Vector2(minf(p0.x, p1.x), minf(p0.z, p1.z)), Vector2(absf(p1.x - p0.x), absf(p1.z - p0.z)))
			if not foot.intersects(r.grow(0.004)):
				continue
			var lo := INF
			for k in 4:
				var c := r.position + Vector2(r.size.x * float(k % 2), r.size.y * float(k / 2))
				lo = minf(lo, (Vector3(c.x, 0, c.y) - mid).dot(n))
			reach = minf(reach, lo - 0.005)
		if reach - f0 >= 0.01:
			_box(st, mid, along, n, sgn * h, sgn * (h + JAMB_W), f0, reach, FOOT, Level.DOOR_H, col)
	_box(st, mid, along, n, -(h + JAMB_W), h + JAMB_W, f0, f1, Level.DOOR_H, Level.DOOR_H + HEAD_H, col)

## A box in a doorway's frame: from s0 to s1 along the wall, f0 to f1 out of it, y0 to y1 up.
static func _box(st: SurfaceTool, mid: Vector3, along: Vector3, n: Vector3, s0: float, s1: float, f0: float, f1: float, y0: float, y1: float, col: Color) -> void:
	var lo := mid + along * minf(s0, s1) + n * f0 + Vector3(0, y0, 0)
	var size := along * absf(s1 - s0) + n * (f1 - f0) + Vector3(0, y1 - y0, 0)
	var a := Vector3(minf(lo.x, lo.x + size.x), lo.y, minf(lo.z, lo.z + size.z))
	var sz := size.abs()
	var c := a + sz * 0.5
	var hh := sz * 0.5
	for f: Array in [[Vector3.RIGHT, Vector3.BACK, Vector3.UP], [Vector3.LEFT, Vector3.BACK, Vector3.UP], [Vector3.UP, Vector3.RIGHT, Vector3.BACK],
			[Vector3.DOWN, Vector3.RIGHT, Vector3.BACK], [Vector3.BACK, Vector3.RIGHT, Vector3.UP], [Vector3.FORWARD, Vector3.RIGHT, Vector3.UP]]:
		var fn: Vector3 = f[0]
		var u: Vector3 = (f[1] as Vector3) * hh
		var v: Vector3 = (f[2] as Vector3) * hh
		var fc := c + fn * hh
		var p := [fc - u - v, fc + u - v, fc + u + v, fc - u + v]
		var order: Array[int] = [0, 1, 2, 0, 2, 3]
		if ((p[1] as Vector3) - (p[0] as Vector3)).cross((p[3] as Vector3) - (p[0] as Vector3)).dot(fn) > 0.0:
			order = [0, 3, 2, 0, 2, 1]
		# A little darker low down, where feet and trolleys knock it.
		for i in order:
			var q: Vector3 = p[i]
			st.set_normal(fn)
			st.set_color(col.darkened(0.12 if fmod(q.y, Level.LH) < 0.15 else 0.0))
			st.set_uv(Vector2(q.x + q.z, q.y) * 0.5)
			st.add_vertex(q)
