# LA3: what is in a Prison cell beyond its bunk, cabinet, toilet and night light (looks only). On the bunk, a thin
# mattress, a pillow at the head and a grey blanket folded at the foot, all inside the bunk's own footprint. On the
# walls, a few centimetres proud: a steel shelf over the bunk's foot with a tin mug and a paperback, tally scratches on
# the side wall by the pillow (more in some cells than others), a small steel mirror over the basin, a pinned notice in
# the company's words with a towel on a hook below it in the gap between the cabinet and the toilet, and the conduit
# from the night light up to the ceiling. Nothing stands in front of the cabinet (it stays easy to find), over the
# bunk's open side or in the doorway; nothing is a light; nothing has collision (the client draws no solids).
#
# prison_view.gd's _cell hands each cell's frame here; the steel and cloth go into the prison's own merged meshes (its
# materials), the notice, the paperback, the towel and the scratches into one mesh of their own, textured from the
# Clinic dressing's atlas. Every cell is drawn from the plan alone, the same on every screen.
extends RefCounted

## A cell's notice, in the company's words.
const RULES: Array[String] = ["CELL RULES", "1 LIGHTS OUT", "  MEANS OUT.", "2 THE BUNK IS", "  FOR SLEEP.", "3 PAY IS PAID", "  ON THE DAY."]
const PAPER := Color(0.93, 0.9, 0.8)
const TOWEL := Color(0.55, 0.62, 0.58)
const SCRATCH := Color(0.62, 0.64, 0.58)
## How far each wall piece stands off its face at most (m).
const PROUD_MAX := 0.15

## Tests only: leaves the cells undressed (to compare the Prison with and without it).
static var off := false
static var _tex: ImageTexture

## The notice's texture (one sheet, shared by every cell).
static func notice_texture() -> ImageTexture:
	if _tex != null:
		return _tex
	var w := 0
	for s in RULES:
		w = maxi(w, PixelFont.width(s))
	var img := Image.create(w + 4, RULES.size() * 9 + 3, false, Image.FORMAT_RGBA8)
	img.fill(PAPER)
	for k in RULES.size():
		PixelFont.blit(img, RULES[k], Vector2i(2, 2 + k * 9), Color(0.12, 0.12, 0.13) if k > 0 else Color(0.55, 0.1, 0.07))
	_tex = ImageTexture.create_from_image(img)
	return _tex

var _st: SurfaceTool
## Every box drawn, for the tests: {kind, cell (1..8), aabb, face (a point on the wall face, or ZERO), n (out of the
## wall, or ZERO for what lies on the bunk)}.
var records: Array[Dictionary] = []
## Per cell: the bunk's footprint (x, z) and the cabinet's box with the floor in front of it, for the tests.
var bunks: Array[Rect2] = []
var cabinets: Array[AABB] = []

## One cell. `pv` the prison view (its _box and materials), `mid` the middle of the doorway on the wall line, `side`
## along the front wall (toward the cell's middle), `fwd` into the cell; along side, s_lo and s_hi the side walls'
## faces, `back` the back wall's face along fwd; the bunk's middle (bs, bf), its length and depth, the cabinet's middle
## along side and its depth, the toilet's middle along side.
func cell(pv: RefCounted, number: int, mid: Vector3, side: Vector3, fwd: Vector3, s_lo: float, s_hi: float, back: float,
		bs: float, bf: float, bl: float, bd: float, cs: float, cd: float, ts: float) -> void:
	if off:
		return
	var w := func(s: float, f: float, y: float) -> Vector3: return mid + side * s + fwd * f + Vector3(0, y, 0)
	var sz := func(ss: float, ff: float, hh: float) -> Vector3: return side.abs() * ss + fwd.abs() * ff + Vector3(0, hh, 0)
	var a := w.call(bs - bl * 0.5, bf - bd * 0.5, 0.0) as Vector3
	var b := w.call(bs + bl * 0.5, bf + bd * 0.5, 0.0) as Vector3
	bunks.append(Rect2(Vector2(minf(a.x, b.x), minf(a.z, b.z)), Vector2(absf(b.x - a.x), absf(b.z - a.z))))
	var c0 := w.call(cs - 0.31, back - cd - 0.7, 0.0) as Vector3
	var c1 := w.call(cs + 0.31, back, 1.8) as Vector3
	cabinets.append(AABB(Vector3(minf(c0.x, c1.x), 0.0, minf(c0.z, c1.z)), Vector3(absf(c1.x - c0.x), 1.8, absf(c1.z - c0.z))))
	# The bedding: a thin mattress on the deck (its top at 0.46 m), the pillow at the head, the blanket folded at the foot.
	_put(pv, pv.get("_mattress"), w.call(bs, bf, 0.505), sz.call(bl - 0.08, bd - 0.08, 0.09), "mattress", number, Vector3.ZERO, Vector3.ZERO)
	_put(pv, pv.get("_pillow"), w.call(s_lo + 0.32, bf, 0.595), sz.call(0.42, bd - 0.2, 0.09), "pillow", number, Vector3.ZERO, Vector3.ZERO)
	_put(pv, pv.get("_blanket"), w.call(bs + bl * 0.5 - 0.3, bf + 0.02, 0.59), sz.call(0.42, bd - 0.16, 0.08), "blanket", number, Vector3.ZERO, Vector3.ZERO)
	var into := -fwd
	var back_face := w.call(0.0, back, 0.0) as Vector3
	var steel: Material = pv.get("_steel")
	var dark: Material = pv.get("_steel_dark")
	# The shelf over the bunk's foot, with its brackets, a tin mug and a paperback.
	var sh := bs + bl * 0.5 - 0.45
	_put(pv, steel, w.call(sh, back - 0.0715, 1.45), sz.call(0.46, 0.14, 0.02), "shelf", number, back_face, into)
	for k: float in [-0.18, 0.18]:
		_put(pv, dark, w.call(sh + k, back - 0.054, 1.39), sz.call(0.02, 0.1, 0.1), "shelf", number, back_face, into)
	_put(pv, dark, w.call(sh - 0.1, back - 0.07, 1.505), sz.call(0.075, 0.075, 0.09), "mug", number, back_face, into)
	_put(pv, dark, w.call(sh - 0.1 + 0.045, back - 0.07, 1.525), sz.call(0.015, 0.012, 0.04), "mug", number, back_face, into)
	_flat(w.call(sh + 0.1, back - 0.06, 1.545), side, fwd, Vector3(0.11, 0.17, 0.025), Color(0.55, 0.22, 0.16).lerp(Color(0.2, 0.32, 0.45), float(number % 3) * 0.5), "book", number, back_face, into)
	# The mirror over the basin.
	_put(pv, steel, w.call(ts, back - 0.012, 1.5), sz.call(0.3, 0.012, 0.36), "mirror", number, back_face, into)
	_put(pv, dark, w.call(ts, back - 0.004, 1.5), sz.call(0.34, 0.006, 0.4), "mirror", number, back_face, into)
	# The notice and the towel on its hook, between the cabinet and the toilet (where there is room).
	var gap0 := cs + 0.31
	var gap1 := ts - 0.21
	if gap1 - gap0 >= 0.36:
		var gs := (gap0 + gap1) * 0.5
		_notice(w.call(gs, back - 0.003, 1.62), side, fwd, number, back_face, into)
		_put(pv, dark, w.call(gs, back - 0.025, 1.3), sz.call(0.03, 0.05, 0.03), "towel", number, back_face, into)
		_flat(w.call(gs, back - 0.03, 1.1), side, fwd, Vector3(0.24, 0.38, 0.03), TOWEL, "towel", number, back_face, into)
	# The conduit from the night light's box to the ceiling.
	_put(pv, dark, w.call(bs, back - 0.012, 2.885), sz.call(0.025, 0.024, 0.63), "conduit", number, back_face, into)
	# Tally scratches on the side wall by the pillow, over the bunk: groups of five, more in some cells.
	var side_face := w.call(s_lo, 0.0, 0.0) as Vector3
	var marks := 3 + (number * 7) % 13
	for i in marks:
		var g := i / 5
		var k := i % 5
		var f := bf - bd * 0.5 + 0.1 + g * 0.14 + k * 0.025
		if k == 4:
			# The fifth across the other four.
			_scratch(w.call(s_lo + 0.0055, bf - bd * 0.5 + 0.1 + g * 0.14 + 0.0375, 0.9), side, fwd, 0.13, 0.9, number, side_face, side)
		else:
			_scratch(w.call(s_lo + 0.0015, f, 0.9), side, fwd, 0.16, 0.0, number, side_face, side)

## A box into the prison's merged mesh of `mat`, recorded.
func _put(pv: RefCounted, mat: Material, centre: Vector3, size: Vector3, kind: String, number: int, face: Vector3, n: Vector3) -> void:
	pv.call("_box", mat, centre, size)
	records.append({"kind": kind, "cell": number, "aabb": AABB(centre - size * 0.5, size), "face": face, "n": n})

## A coloured plate on the back wall (`size`: along side, up, out of the wall), into this file's own mesh.
func _flat(centre: Vector3, side: Vector3, fwd: Vector3, size: Vector3, col: Color, kind: String, number: int, face: Vector3, n: Vector3) -> void:
	_quadbox(Transform3D(Basis(side, Vector3.UP, -fwd) if side.cross(Vector3.UP).dot(-fwd) > 0.0 else Basis(-side, Vector3.UP, -fwd), centre), size, Rect2(0, 0, 0, 0), col)
	var ext := side.abs() * size.x + Vector3(0, size.y, 0) + fwd.abs() * size.z
	records.append({"kind": kind, "cell": number, "aabb": AABB(centre - ext * 0.5, ext), "face": face, "n": n})

func _notice(centre: Vector3, side: Vector3, fwd: Vector3, number: int, face: Vector3, n: Vector3) -> void:
	var tex := notice_texture()
	var wdt := 0.26
	var hgt := wdt * tex.get_height() / float(tex.get_width())
	var b := Basis(side, Vector3.UP, -fwd) if side.cross(Vector3.UP).dot(-fwd) > 0.0 else Basis(-side, Vector3.UP, -fwd)
	# A little crooked, by the cell's number: pinned by someone in a hurry.
	b = b * Basis(Vector3(0, 0, 1), (float(number % 5) - 2.0) * 0.03)
	_quadbox(Transform3D(b, centre), Vector3(wdt, hgt, 0.003), Rect2(0, 0, 1, 1), Color.WHITE, true)
	var ext := side.abs() * (wdt + 0.02) + Vector3(0, hgt + 0.02, 0) + fwd.abs() * 0.003
	records.append({"kind": "notice", "cell": number, "aabb": AABB(centre - ext * 0.5, ext), "face": face, "n": n})

## One scratch: a pale line `len` long, turned `lean` from upright, 1.5 mm proud of the side wall.
func _scratch(centre: Vector3, side: Vector3, fwd: Vector3, len_m: float, lean: float, number: int, face: Vector3, n: Vector3) -> void:
	var b := Basis(fwd, Vector3.UP, side) if fwd.cross(Vector3.UP).dot(side) > 0.0 else Basis(-fwd, Vector3.UP, side)
	b = b * Basis(Vector3(0, 0, 1), lean)
	_quadbox(Transform3D(b, centre + side * 0.0005), Vector3(0.006, len_m, 0.001), Rect2(0, 0, 0, 0), SCRATCH)
	var ext := fwd.abs() * (len_m * absf(sin(lean)) + 0.006) + Vector3(0, len_m, 0) + side.abs() * 0.002
	records.append({"kind": "tally", "cell": number, "aabb": AABB(centre + side * 0.0005 - ext * 0.5, ext), "face": face, "n": n})

var _st_tex: SurfaceTool
## A box into this file's meshes: `textured` ones (the notice) into the notice's mesh, the rest into the plain one.
func _quadbox(xf: Transform3D, size: Vector3, region: Rect2, col: Color, textured := false) -> void:
	if textured:
		if _st_tex == null:
			_st_tex = SurfaceTool.new()
			_st_tex.begin(Mesh.PRIMITIVE_TRIANGLES)
	elif _st == null:
		_st = SurfaceTool.new()
		_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var st: SurfaceTool = _st_tex if textured else _st
	var h := size * 0.5
	for f: Array in [[Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)], [Vector3(0, 0, -1), Vector3(-1, 0, 0), Vector3(0, 1, 0)],
			[Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)], [Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)],
			[Vector3(0, 1, 0), Vector3(1, 0, 0), Vector3(0, 0, -1)], [Vector3(0, -1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)]]:
		var fn: Vector3 = f[0]
		var u: Vector3 = f[1]
		var v: Vector3 = f[2]
		var fc := fn * h
		var p: Array[Vector3] = [fc - u * h - v * h, fc + u * h - v * h, fc + u * h + v * h, fc - u * h + v * h]
		var uvs: Array[Vector2] = [Vector2(0.5, 0.5), Vector2(0.5, 0.5), Vector2(0.5, 0.5), Vector2(0.5, 0.5)]
		if fn.z > 0.5 and region.size != Vector2.ZERO:
			uvs = [Vector2(region.position.x, region.end.y), region.end, Vector2(region.end.x, region.position.y), region.position]
		var nw := (xf.basis * fn).normalized()
		var order: Array[int] = [0, 1, 2, 0, 2, 3]
		if (xf * p[1] - xf * p[0]).cross(xf * p[3] - xf * p[0]).dot(nw) > 0.0:
			order = [0, 2, 1, 0, 3, 2]
		for i in order:
			st.set_normal(nw)
			st.set_color(col)
			st.set_uv(uvs[i])
			st.add_vertex(xf * p[i])

## The meshes, once every cell is in: the plain one (vertex coloured) and the notices' (their sheet).
func commit(lv: Level) -> void:
	for pair: Array in [[_st, Level.prop_material(Color.WHITE, null, true)], [_st_tex, Level.prop_material(Color.WHITE, notice_texture(), false)]]:
		var st: SurfaceTool = pair[0]
		if st == null:
			continue
		st.index()
		var mi := MeshInstance3D.new()
		mi.name = "Prison_cell_dressing" if st == _st else "Prison_cell_notices"
		mi.mesh = st.commit()
		mi.material_override = pair[1]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		lv.add_child(mi)
	_st = null
	_st_tex = null
	lv.set_meta(&"prison_dressing", self)
