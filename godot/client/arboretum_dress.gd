# LA4 (26 Nov): the Arboretum's landmarks drawn as things a player names without being told, and the thicket's
# straight, tiled edges broken. Looks only. client/arboretum_view.gd calls this while it dresses the floor, and
# everything here goes into the view's own batches (its chunked meshes and its materials: wood, stone, iron, the
# pavilion's brick, thicket, leaf, bark): no mesh, material, light, glow or sound of its own.
#
# The North Star (A2): "A forest indoors, under a painted sky. There are no walls to funnel anything, so the crew
# steers by landmarks and by sound." It says nothing more of what a landmark looks like; the shapes are LA4's choice:
#   - the shed row: two plank sheds side by side in the building's cell, each with its own pitched felt roof, a small
#     dark window, a plank door that is plainly shut (one boarded across, one padlocked), a spade leaning by the doors;
#     the row's hide sheds (the real doors, unchanged) get the same felt roof;
#   - the gate lodge: brick walls on a stone plinth with stone quoins, a pitched slate roof with a chimney, a door
#     under a hood (boarded shut), dark sash windows;
#   - the bandstand: a brick base with an octagonal deck, eight iron posts, a railing all round, a pointed roof with a
#     finial;
#   - the aviary: a round cage of thin bars on a stone base, a domed top with a finial, its door standing open, empty
#     perches;
#   - the dry fountain: an octagonal basin on a kerb, dead leaves in it, a centre stem and bowl;
#   - the fallen statue: a plinth with only the feet left on it, and a plain robed figure lying broken beside it;
#   - the sundial: a stone pillar on two steps, a dial plate with its hour marks and gnomon;
#   - the rose arch: what it lacked, a body over its solid footprint: a raised bed of roses grown through the arch;
#   - the greenhouse and the lift pavilion: unchanged (the judge did not fault them).
#
# What holds (tests/test_arboretum_dress.gd checks it on many gardens):
#   - "Furniture is solid" (A2/V33): below BODY_H nothing is drawn more than REACH outside the solid it stands for
#     (a building's whole cell, a small landmark's piece, a hide shed's piece), and each solid has a body over it;
#   - thicket is wall: the cards keep within REACH of their cell below BODY_H, and the thicket's own faces stay shut;
#   - every hide's prompt spot and view out stay clear of what is drawn here;
#   - all from the floor's seed: hashes of cells and positions (never the view's random stream, so the moths and
#     fireflies stay where they were); nothing stands like a figure (the statue lies down, in pieces).
extends RefCounted

const Arboretum = preload("res://sim/arboretum.gd")
const Floor = preload("res://sim/floor.gd")

const S := 2.0
## Below this height a drawn piece stays within REACH (m) of its solid; above it roofs, eaves and finials may overhang.
const BODY_H := 2.2
const REACH := 0.15
## The four sides, n e s w, as the rules have them (sim/arboretum.gd DIRS), in metres on the ground.
const SIDES: Array[Vector3] = [Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(-1, 0, 0)]
## Every landmark kind the generator places, and what draws it (tests/test_arboretum_dress.gd: none falls back to a box).
const SHAPES := {
	&"greenhouse": "client/arboretum_view.gd _greenhouse", &"bandstand": "_bandstand", &"sheds": "_shed_row",
	&"aviary": "_aviary", &"lodge": "_lodge", &"fountain": "_fountain", &"statue": "_statue", &"arch": "_rose_arch",
	&"sundial": "_sundial",
}

const C_WOOD := Color(0.4, 0.3, 0.2)
const C_FELT := Color(0.075, 0.075, 0.08)
const C_SLATE := Color(0.13, 0.14, 0.16)
const C_STONE := Color(0.55, 0.55, 0.52)
const C_IRON := Color(0.22, 0.26, 0.24)
const C_PANE := Color(0.012, 0.014, 0.02)
## The lodge's and the bandstand's brick (the pavilion's brick map, a little darker than the pavilion's own wall).
const C_BRICKWORK := Color(0.72, 0.66, 0.6)
const C_THICKET := Color(0.18, 0.22, 0.10)
const C_DEAD_LEAF := Color(0.32, 0.18, 0.08)
const C_ROSE := Color(0.30, 0.095, 0.095)
const C_SOIL := Color(0.08, 0.06, 0.045)

## Tests only: draw nothing here (the view without its dressing), to compare lights and materials with and without.
static var off := false

var v: Node3D
var fp: Floor.FloorPlan
## What was drawn, by shape (for checks and the counts).
var shapes := {}

func _init(view: Node3D, plan: Floor.FloorPlan) -> void:
	v = view
	fp = plan

# --- the entry points the view calls ---------------------------------------------------------------------

## A big landmark's building, its cell's middle at `at`.
func building(l: Arboretum.Landmark, at: Vector3) -> void:
	if off:
		return
	_tag("mark:" + String(l.kind))
	var hides := _hide_sides(at)
	match l.kind:
		&"greenhouse":
			v.call(&"_greenhouse", at)
		&"bandstand":
			_bandstand(at)
		&"sheds":
			_shed_row(at, hides, l.building)
		&"aviary":
			_aviary(at, l.building)
		&"lodge":
			_lodge(at, hides)
	shapes[l.kind] = true
	_tag("")

## A small landmark's piece (where its four cells meet), `r` the view's hash of its spot.
func small(kind: StringName, at: Vector3, r: float) -> void:
	if off:
		return
	_tag("mark:" + String(kind))
	match kind:
		&"fountain":
			_fountain(at)
		&"statue":
			_statue(at)
		&"arch":
			v.call(&"_rose_arch", at, r)
			_rose_arch(at, r)
		&"sundial":
			_sundial(at)
	shapes[kind] = true
	_tag("")

## A hide shed (the real door, drawn by the view): the shed row's felt roof over it.
func shed_roof(at: Vector3, f: Vector3, piece_id: int) -> void:
	if off:
		return
	_tag("shedroof:%d" % piece_id)
	var r := _right(f)
	var half_w := 0.55
	var eave := 0.38
	var low := 1.99
	var ridge := 2.2
	var top: Array[Vector3] = []
	for s: float in [-1.0, 1.0]:
		var slope: Array[Vector3] = [at + r * -half_w + Vector3.UP * ridge, at + r * half_w + Vector3.UP * ridge,
			at + r * half_w + f * s * eave + Vector3.UP * low, at + r * -half_w + f * s * eave + Vector3.UP * low]
		_slab("wood", slope, 0.035, C_FELT)
	for s: float in [-1.0, 1.0]:
		var e := at + r * s * 0.45
		top = [e + f * -0.3 + Vector3.UP * 1.93, e + f * 0.3 + Vector3.UP * 1.93, e + Vector3.UP * 2.17]
		_face3("wood", top[0], top[1], top[2], r * s, C_WOOD * 0.6)
	_tag("")

## One thicket cell: the view's own mass (client/arboretum_view.gd _bramble), then leaf cards over its open faces and a
## ragged crown of cards and twigs above BODY_H.
func thicket(x: int, y: int) -> void:
	_tag("tbody:%d:%d" % [x, y])
	v.call(&"_bramble", x, y)
	if off:
		_tag("")
		return
	_tag("tcard:%d:%d" % [x, y])
	var c := Vector3((x + 0.5) * S, 0, (y + 0.5) * S)
	var col := C_THICKET * (0.78 + 0.45 * _h(x, y, 2))
	col.a = 1.0
	var top := 2.35 + 0.85 * _h(x, y, 1)
	# The faces: a broad card just off each side that opens onto the garden (overlapping its neighbours' at the
	# corners), never more than REACH out, its top edge ragged against the mass behind it.
	var faces := 0
	for side in 4:
		var d := SIDES[side]
		if not _open(x + int(d.x), y + int(d.z)):
			continue
		faces += 1
		var along := Vector3(-d.z, 0, d.x)
		var t := 0.5 + (_h(x, y, 200 + side) - 0.5) * 0.3
		var half_w := minf(0.62 + 0.2 * _h(x, y, 210 + side), minf(t, 1.0 - t) * S + 0.1)
		var half_h := 0.42 + 0.22 * _h(x, y, 220 + side)
		var mid_y := clampf(0.5 + 1.2 * _h(x, y, 230 + side), half_h + 0.02, BODY_H - half_h - 0.06)
		var out := 0.03 + 0.05 * _h(x, y, 240 + side)
		var lean := 0.04 * (_h(x, y, 250 + side) - 0.5)
		var at := c + d * (S * 0.5 + out) + along * (t - 0.5) * S + Vector3.UP * mid_y
		var tint := col * (0.82 + 0.3 * _h(x, y, 260 + side))
		tint.a = 1.0
		_card(at, Vector3.UP * half_h + d * lean, along * half_w, tint)
	if faces == 0:
		_tag("")
		return
	# The crown: cards standing up out of the top at the clump's edge, all above BODY_H, so the skyline is ragged.
	for k in (2 if faces > 2 else 1):
		var a := TAU * (k * 0.5 + 0.5 * _h(x, y, 300 + k))
		var out := Vector3(cos(a), 0, sin(a))
		var spread := 0.2 + 0.4 * _h(x, y, 310 + k)
		var half_h := 0.35 + 0.3 * _h(x, y, 320 + k)
		var base := top + 0.1 * _h(x, y, 330 + k)
		var at := c + out * spread + Vector3.UP * (base + half_h + 0.05)
		var tint := col * (0.9 + 0.3 * _h(x, y, 340 + k))
		tint.a = 1.0
		_card(at, Vector3.UP * half_h + out * 0.15, Vector3(-out.z, 0.05, out.x) * (0.4 + 0.25 * _h(x, y, 350 + k)), tint)
	_tag("")

# --- the big landmarks -------------------------------------------------------------------------------------

## A brick base, an octagonal deck, eight iron posts with a railing all round, a pointed roof with a finial. The
## deck's height is the under-hide's (client/arboretum_view.gd draws its deck edge and skirt at 0.49 to 0.55 m).
func _bandstand(at: Vector3) -> void:
	_box("pavilion", Vector3(S, 0.44, S), at, C_BRICKWORK * 0.8)
	_box("stone", Vector3(S + 0.04, 0.05, S + 0.04), at + Vector3.UP * 0.44, C_STONE * 0.5)
	var oct := PI / 8.0
	var deck_r := 1.04 / cos(oct)
	_taper("wood", [at + Vector3.UP * 0.49, at + Vector3.UP * 0.55], [deck_r, deck_r], Vector3.UP, oct, C_WOOD * 0.75, 8, true)
	var post_r := 0.98
	var posts: Array[Vector3] = []
	for k in 8:
		var a := oct + k * PI / 4.0
		posts.append(at + Vector3(cos(a), 0, sin(a)) * post_r)
	var dark := Color(0.1, 0.13, 0.12)
	for k in 8:
		var p := posts[k]
		var q := posts[(k + 1) % 8]
		_taper("iron", [p + Vector3.UP * 0.55, p + Vector3.UP * 2.62], [0.045, 0.035], Vector3.UP, PI * 0.25, C_IRON, 4, false)
		# The railing: a top and a bottom rail and two balusters in each bay.
		for hy: float in [0.62, 1.42]:
			_rod("iron", p + Vector3.UP * hy, q + Vector3.UP * hy, 0.022, C_IRON)
		for b in 2:
			var m := p.lerp(q, (b + 1) / 3.0)
			_rod("iron", m + Vector3.UP * 0.62, m + Vector3.UP * 1.42, 0.012, C_IRON * 0.9)
		# The valance under the eaves.
		_rod("wood", p + Vector3.UP * 2.55, q + Vector3.UP * 2.55, 0.05, dark)
	# The roof: a fascia, an octagonal cone with its underside, and a finial.
	var eave_r := 1.55
	_taper("wood", [at + Vector3.UP * 2.66, at + Vector3.UP * 2.76], [eave_r, eave_r], Vector3.UP, oct, dark, 8, false)
	_taper("wood", [at + Vector3.UP * 2.76, at + Vector3.UP * 3.8], [eave_r, 0.05], Vector3.UP, oct, dark * 0.9, 8, false)
	var soffit: Array[Vector3] = []
	for k in 8:
		var a := oct + k * PI / 4.0
		soffit.append(at + Vector3(cos(a), 0, sin(a)) * eave_r + Vector3.UP * 2.66)
	_poly("wood", soffit, Vector3.DOWN, dark * 0.7)
	_taper("iron", [at + Vector3.UP * 3.78, at + Vector3.UP * 3.92, at + Vector3.UP * 4.0, at + Vector3.UP * 4.35],
		[0.05, 0.08, 0.05, 0.0], Vector3.UP, 0.0, C_IRON, 5, false)

## Two plank sheds side by side across the building's cell, each with its own pitched felt roof, a small dark window on
## its outer side and a plank door on the open side: one boarded across, one padlocked (only the row's hide sheds are
## real doors). A spade leans between the doors.
func _shed_row(at: Vector3, hides: Array[bool], cell: int) -> void:
	var f := _free_side(hides, cell)
	var r := _right(f)
	var yf := atan2(f.x, f.z)
	for s: float in [-1.0, 1.0]:
		var u := s * 0.5
		var wall := 2.08 if s < 0.0 else 2.16
		var ridge := wall + (0.34 if s < 0.0 else 0.3)
		var body := C_WOOD * (0.85 if s < 0.0 else 0.68)
		var mid := at + r * u
		_box("wood", Vector3(1.0, wall, S), mid, body, yf)
		# Gables, front and back, and the felt roof over them.
		for e: float in [-1.0, 1.0]:
			var g := mid + f * e
			_face3("wood", g + r * -0.5 + Vector3.UP * wall, g + r * 0.5 + Vector3.UP * wall, g + Vector3.UP * ridge, f * e, body * 0.9)
		for side: float in [-1.0, 1.0]:
			# No eave over the neighbour: the inner slopes stop at the wall between the two.
			var reach := 0.0 if side == -s else 0.12
			var eave_y := ridge - (0.5 + reach) * (ridge - wall) / 0.5 + 0.02
			var slope: Array[Vector3] = [mid + f * -1.12 + Vector3.UP * ridge, mid + f * 1.12 + Vector3.UP * ridge,
				mid + f * 1.12 + r * side * (0.5 + reach) + Vector3.UP * eave_y, mid + f * -1.12 + r * side * (0.5 + reach) + Vector3.UP * eave_y]
			_slab("wood", slope, 0.04, C_FELT)
		_box("wood", Vector3(0.07, 0.05, S + 0.26), mid + Vector3.UP * (ridge - 0.01), C_FELT * 0.8, yf)
		# The door: frame, ledges, latch.
		var door := mid + f * 1.0
		_box("wood", Vector3(0.62, 1.72, 0.03), door + Vector3.UP * 0.04, C_WOOD * 0.42, yf)
		for jamb: float in [-0.34, 0.34]:
			_box("wood", Vector3(0.05, 1.8, 0.045), door + r * jamb, C_WOOD * 0.55, yf)
		for ly: float in [0.3, 1.4]:
			_box("wood", Vector3(0.56, 0.08, 0.04), door + Vector3.UP * ly, C_WOOD * 0.5, yf)
		_box("iron", Vector3(0.2, 0.025, 0.05), door + r * 0.17 + Vector3.UP * 1.02, C_IRON * 0.7, yf)
		if s < 0.0:
			# Boarded across.
			for tz: float in [-0.85, 0.85]:
				_box("wood", Vector3(0.82, 0.1, 0.03), door + f * 0.04 + Vector3.UP * 0.95, C_WOOD * 0.62, false, yf, Vector3(0, 0, tz))
		else:
			# A hasp and a padlock.
			_box("iron", Vector3(0.05, 0.16, 0.05), door + r * 0.3 + Vector3.UP * 1.0, C_IRON * 0.8, yf)
			_box("iron", Vector3(0.065, 0.075, 0.035), door + r * 0.3 + f * 0.04 + Vector3.UP * 0.9, C_IRON, yf)
		# A small dark window on the outer side, towards the front (clear of a hide shed against that side's middle).
		var n := r * s
		var w := at + n * 1.0 + f * 0.66 + Vector3.UP * 1.2
		var yn := atan2(n.x, n.z)
		_box("wood", Vector3(0.44, 0.4, 0.03), w + Vector3.UP * -0.04, C_WOOD * 0.6, yn)
		_box("wood", Vector3(0.36, 0.32, 0.05), w, C_PANE, yn)
		_box("wood", Vector3(0.025, 0.32, 0.07), w, C_WOOD * 0.6, yn)
		_box("wood", Vector3(0.36, 0.025, 0.07), w + Vector3.UP * 0.15, C_WOOD * 0.6, yn)
	# A spade leaning against the wall between the two doors.
	var foot := at + f * 1.12 + r * -0.02
	var head := at + f * 1.01 + r * 0.04 + Vector3.UP * 1.22
	_rod("wood", foot + Vector3.UP * 0.26, head, 0.016, C_WOOD * 0.7)
	_rod("wood", head + r * -0.06, head + r * 0.06, 0.014, C_WOOD * 0.7)
	var up := (head - foot).normalized()
	_slab("iron", [foot + r * -0.085 + up * 0.27, foot + r * 0.085 + up * 0.27, foot + r * 0.08, foot + r * -0.08], 0.012, C_IRON * 0.8)

## Brick walls on a stone plinth with stone quoins, a pitched slate roof with a chimney, a door (boarded shut) under a
## hood, dark sash windows. The door faces away from the lodge's hide shed.
func _lodge(at: Vector3, hides: Array[bool]) -> void:
	var f := SIDES[2]
	for side in 4:
		if hides[side]:
			f = -SIDES[side]
	var r := _right(f)
	var yf := atan2(f.x, f.z)
	var wall := 2.4
	_box("pavilion", Vector3(S, wall, S), at, C_BRICKWORK * 0.92)
	_box("stone", Vector3(S + 0.04, 0.3, S + 0.04), at, C_STONE * 0.5)
	# Quoins: long and short stones in turn up each corner, their faces 1.5 cm proud of the brick.
	for sr: float in [-1.0, 1.0]:
		for sf: float in [-1.0, 1.0]:
			var corner := at + r * sr * 1.015 + f * sf * 1.015
			for k in 7:
				var y := 0.34 + k * 0.29
				var long_r := 0.34 if k % 2 == 0 else 0.18
				var long_f := 0.52 - long_r
				_face4("stone", corner + Vector3.UP * y, corner - r * sr * long_r + Vector3.UP * y,
					corner - r * sr * long_r + Vector3.UP * (y + 0.24), corner + Vector3.UP * (y + 0.24), f * sf, C_STONE * 0.6)
				_face4("stone", corner + Vector3.UP * y, corner - f * sf * long_f + Vector3.UP * y,
					corner - f * sf * long_f + Vector3.UP * (y + 0.24), corner + Vector3.UP * (y + 0.24), r * sr, C_STONE * 0.6)
	# The roof: two slate slopes, the ridge parallel to the front, the gables in brick, eaves above BODY_H.
	var ridge := 3.3
	var out := 1.2
	var eave_y := 2.32
	for s: float in [-1.0, 1.0]:
		var slope: Array[Vector3] = [at + r * -out + Vector3.UP * ridge, at + r * out + Vector3.UP * ridge,
			at + r * out + f * s * out + Vector3.UP * eave_y, at + r * -out + f * s * out + Vector3.UP * eave_y]
		_slab("stone", slope, 0.08, C_SLATE)
		# Slate courses.
		for k in 2:
			var t := (k + 0.5) / 2.0
			var y := lerpf(ridge, eave_y, t) + 0.012
			_rod("stone", at + r * -out + f * s * out * t + Vector3.UP * y, at + r * out + f * s * out * t + Vector3.UP * y, 0.012, C_SLATE * 0.6)
	_box("stone", Vector3(2.0 * out + 0.04, 0.09, 0.14), at + Vector3.UP * (ridge - 0.02), C_SLATE * 0.7, yf)
	for s: float in [-1.0, 1.0]:
		var g := at + r * s * 1.0
		var tri: Array[Vector3] = [g + f * -1.0 + Vector3.UP * wall, g + f * 1.0 + Vector3.UP * wall, g + Vector3.UP * (ridge - 0.08)]
		_face3("pavilion", tri[0], tri[1], tri[2], r * s, C_BRICKWORK * 0.92, _brick_uv(tri, f))
	# The chimney, on one gable towards the back.
	var cs := -1.0 if _hp(at, 3) < 0.5 else 1.0
	var chim := at + r * cs * 0.75 + f * -0.42
	_box("pavilion", Vector3(0.48, 2.0, 0.46), chim + Vector3.UP * 2.0, C_BRICKWORK * 0.85, yf)
	_box("stone", Vector3(0.56, 0.08, 0.54), chim + Vector3.UP * 4.0, C_STONE * 0.45, yf)
	_taper("stone", [chim + Vector3.UP * 4.08, chim + Vector3.UP * 4.32], [0.09, 0.07], Vector3.UP, 0.0, Color(0.3, 0.17, 0.12), 6, false)
	# The door, boarded shut, on the other gable side in a stone surround, under a hood on two brackets. (The front
	# keeps its middle for the lodge's lantern: client/arboretum_view.gd _practical hangs it there.)
	var n := r * -cs
	var dr := _right(n)
	var yn := atan2(n.x, n.z)
	var door := at + n * 1.0 + f * 0.1
	_box("wood", Vector3(0.72, 1.9, 0.04), door, C_WOOD * 0.38, yn)
	for jamb: float in [-0.4, 0.4]:
		_box("stone", Vector3(0.08, 1.96, 0.07), door + dr * jamb, C_STONE * 0.55, yn)
	_box("stone", Vector3(0.9, 0.14, 0.07), door + Vector3.UP * 1.96, C_STONE * 0.55, yn)
	for tz: float in [-0.32, 0.32]:
		_box("wood", Vector3(0.84, 0.12, 0.03), door + n * 0.04 + Vector3.UP * (1.0 + tz * 0.9), C_WOOD * 0.5, false, yn, Vector3(0, 0, tz))
	_box("iron", Vector3(0.05, 0.05, 0.05), door + dr * 0.25 + n * 0.03 + Vector3.UP * 1.0, C_IRON * 0.7, yn)
	for jamb: float in [-0.4, 0.4]:
		_box("stone", Vector3(0.07, 0.18, 0.13), door + dr * jamb + n * 0.06 + Vector3.UP * 2.02, C_STONE * 0.5, yn)
	var hood: Array[Vector3] = [door + dr * -0.52 + Vector3.UP * 2.52, door + dr * 0.52 + Vector3.UP * 2.52,
		door + dr * 0.52 + n * 0.4 + Vector3.UP * 2.3, door + dr * -0.52 + n * 0.4 + Vector3.UP * 2.3]
	_slab("stone", hood, 0.06, C_SLATE)
	# Sash windows: two on the front either side of the lantern, one on the chimney's side.
	for s: float in [-1.0, 1.0]:
		_sash(at + f * 1.0 + r * s * 0.38, f)
	_sash(at + r * cs * 1.0 + f * 0.3, r * cs)

## A dark sash window on a wall at `at` (its middle at the wall line), the wall facing `n`.
func _sash(at: Vector3, n: Vector3) -> void:
	var y := atan2(n.x, n.z)
	var paint := C_STONE * 0.42
	_box("wood", Vector3(0.5, 0.96, 0.03), at + Vector3.UP * 0.9, paint, y)
	_box("wood", Vector3(0.42, 0.86, 0.05), at + Vector3.UP * 0.95, C_PANE, y)
	_box("wood", Vector3(0.44, 0.045, 0.07), at + Vector3.UP * 1.36, paint, y)
	_box("wood", Vector3(0.025, 0.86, 0.065), at + Vector3.UP * 0.95, paint, y)
	_box("stone", Vector3(0.56, 0.05, 0.12), at + Vector3.UP * 0.86, C_STONE * 0.55, y)

## A round cage of thin bars on a stone base, a domed top with a finial, the door standing open, empty perches.
func _aviary(at: Vector3, cell: int) -> void:
	_box("stone", Vector3(S, 0.3, S), at, C_STONE * 0.5)
	var base := 0.3
	var top := 2.5
	# The door: between the bars either side of a corner, so the open leaf swings into the base's corner.
	var door_k := 1 + 3 * int(_h(cell, 7, 1) * 4.0)
	var door_top := 1.95
	for k in BARS:
		var low := door_top if k == door_k else base
		_rod("iron", _bar(at, k, low), _bar(at, k, top), 0.016, C_IRON)
	for hy: float in [base + 0.04, top]:
		for k in BARS:
			if hy < door_top and (k == door_k or k == door_k - 1):
				continue
			_rod("iron", _bar(at, k, hy), _bar(at, k + 1, hy), 0.02, C_IRON)
	var j0 := _bar(at, door_k - 1, 0.0)
	var j1 := _bar(at, door_k + 1, 0.0)
	_rod("iron", j0 + Vector3.UP * door_top, j1 + Vector3.UP * door_top, 0.022, C_IRON)
	# The leaf, hinged at one jamb, standing open at 45 degrees outwards.
	var shut := j1 - j0
	var outward := (j0 + j1) * 0.5 - at
	var open_dir := shut.rotated(Vector3.UP, 0.785)
	if shut.rotated(Vector3.UP, -0.785).dot(outward) > open_dir.dot(outward):
		open_dir = shut.rotated(Vector3.UP, -0.785)
	var leaf_lo := 0.36
	var leaf_hi := door_top - 0.04
	var far := j0 + open_dir * 0.92
	for hy: float in [leaf_lo, leaf_hi]:
		_rod("iron", j0 + Vector3.UP * hy, far + Vector3.UP * hy, 0.016, C_IRON)
	for t: float in [0.5, 0.97]:
		var p := j0.lerp(far, t)
		_rod("iron", p + Vector3.UP * leaf_lo, p + Vector3.UP * leaf_hi, 0.014, C_IRON)
	# The dome: six ribs and a finial.
	var steps := 3
	for m in 6:
		var prev := _bar(at, m * 2, top)
		for i in range(1, steps + 1):
			var th := PI * 0.5 * i / float(steps)
			var p := _bar(at, m * 2, top + DOME * sin(th), CAGE_R * cos(th))
			_rod("iron", prev, p, 0.018, C_IRON)
			prev = p
	_taper("iron", [at + Vector3.UP * (top + 0.83), at + Vector3.UP * (top + 0.92), at + Vector3.UP * (top + 1.0), at + Vector3.UP * (top + 1.25)],
		[0.04, 0.08, 0.04, 0.0], Vector3.UP, 0.0, C_IRON, 6, false)
	# Empty perches: a dead branch on a stand in the middle, a swing hung from the dome, a seed tray.
	var dead := Color(0.32, 0.27, 0.2)
	_rod("bark", at + Vector3.UP * base, at + Vector3.UP * 1.85, 0.03, dead)
	for i in 2:
		var a := 0.6 + i * 2.1
		var hy := 0.95 + i * 0.32
		var dir := Vector3(cos(a), 0, sin(a))
		_rod("bark", at + Vector3.UP * hy - dir * 0.28, at + Vector3.UP * (hy + 0.06) + dir * 0.32, 0.016, dead)
	var swing := at + Vector3(cos(2.6), 0, sin(2.6)) * 0.45
	var sr := Vector3(-sin(2.6), 0, cos(2.6)) * 0.18
	for e: float in [-1.0, 1.0]:
		_rod("iron", swing + sr * e + Vector3.UP * 1.62, swing + sr * e + Vector3.UP * (top + 0.5), 0.006, C_IRON)
	_rod("wood", swing - sr + Vector3.UP * 1.62, swing + sr + Vector3.UP * 1.62, 0.015, dead)
	_box("wood", Vector3(0.3, 0.05, 0.2), at + Vector3(0.38, base, -0.3), C_WOOD * 0.5, 0.4)

## The aviary's bars: how many, the cage's radius and the dome's rise (m).
const BARS := 12
const CAGE_R := 0.9
const DOME := 0.85

## Bar `k` of the cage round `at` at height `y` (radius `rr`).
static func _bar(at: Vector3, k: int, y: float, rr: float = CAGE_R) -> Vector3:
	var a := TAU * (posmod(k, BARS) + 0.5) / float(BARS)
	return at + Vector3(cos(a), 0, sin(a)) * rr + Vector3.UP * y

# --- the small landmarks ------------------------------------------------------------------------------------

## A kerb, an octagonal basin with a rim, dead leaves in it, a centre stem and bowl with a finial. Dry.
func _fountain(at: Vector3) -> void:
	var oct := PI / 8.0
	_box("stone", Vector3(1.26, 0.1, 1.26), at, C_STONE * 0.62)
	var outer := 0.64
	var inner := 0.53
	var rim := 0.68
	_taper("stone", [at + Vector3.UP * 0.1, at + Vector3.UP * 0.47], [outer, outer], Vector3.UP, oct, C_STONE * 0.85, 8, false)
	_taper("stone", [at + Vector3.UP * 0.47, at + Vector3.UP * 0.53], [rim, rim], Vector3.UP, oct, C_STONE * 0.95, 8, false)
	for k in 8:
		var a0 := oct + k * PI / 4.0
		var a1 := oct + (k + 1) * PI / 4.0
		var d0 := Vector3(cos(a0), 0, sin(a0))
		var d1 := Vector3(cos(a1), 0, sin(a1))
		var mid := (d0 + d1).normalized()
		_face4("stone", at + d0 * inner + Vector3.UP * 0.53, at + d1 * inner + Vector3.UP * 0.53,
			at + d1 * rim + Vector3.UP * 0.53, at + d0 * rim + Vector3.UP * 0.53, Vector3.UP, C_STONE * 0.95)
		_face4("stone", at + d0 * inner + Vector3.UP * 0.14, at + d1 * inner + Vector3.UP * 0.14,
			at + d1 * inner + Vector3.UP * 0.53, at + d0 * inner + Vector3.UP * 0.53, -mid, C_STONE * 0.6)
	var floor_pts: Array[Vector3] = []
	for k in 8:
		var a := oct + k * PI / 4.0
		floor_pts.append(at + Vector3(cos(a), 0, sin(a)) * inner + Vector3.UP * 0.14)
	_poly("stone", floor_pts, Vector3.UP, C_STONE * 0.32)
	# Dead leaves on the floor of the basin, a few drifted against its wall.
	for k in 10:
		var a := TAU * _hp(at, 40 + k)
		var d := 0.08 + 0.38 * _hp(at, 60 + k)
		var p := at + Vector3(cos(a), 0, sin(a)) * d + Vector3.UP * (0.15 + 0.004 * k)
		var spin := TAU * _hp(at, 80 + k)
		var size := 0.04 + 0.04 * _hp(at, 100 + k)
		var tint := C_DEAD_LEAF * (0.7 + 0.5 * _hp(at, 120 + k))
		tint.a = 1.0
		var rise := 0.0 if d < 0.38 else 0.6
		_card(p, Vector3(cos(spin), rise, sin(spin)).normalized() * size, Vector3(-sin(spin), 0, cos(spin)) * size * 0.7, tint)
	# The stem, the bowl and its finial.
	_taper("stone", [at + Vector3.UP * 0.14, at + Vector3.UP * 0.3, at + Vector3.UP * 0.36, at + Vector3.UP * 0.8],
		[0.18, 0.15, 0.09, 0.07], Vector3.UP, oct, C_STONE * 0.85, 8, false)
	_taper("stone", [at + Vector3.UP * 0.8, at + Vector3.UP * 0.9, at + Vector3.UP * 0.97], [0.07, 0.3, 0.36], Vector3.UP, oct, C_STONE * 0.9, 8, false)
	var bowl: Array[Vector3] = []
	for k in 8:
		var a := oct + k * PI / 4.0
		bowl.append(at + Vector3(cos(a), 0, sin(a)) * 0.36 + Vector3.UP * 0.97)
	_poly("stone", bowl, Vector3.UP, C_STONE * 0.35)
	_taper("stone", [at + Vector3.UP * 0.94, at + Vector3.UP * 1.04, at + Vector3.UP * 1.18, at + Vector3.UP * 1.27],
		[0.06, 0.05, 0.04, 0.0], Vector3.UP, oct, C_STONE * 0.9, 8, false)

## A plinth with only the feet left on it, and a plain robed figure lying broken beside it on the old base: lying down,
## in pieces, nothing standing. (The piece is 1.2 m by 0.6 m, east-west.)
func _statue(at: Vector3) -> void:
	var stone := C_STONE * 0.85
	_box("stone", Vector3(1.24, 0.18, 0.64), at, C_STONE * 0.62)
	_box("stone", Vector3(0.4, 0.06, 0.3), at + Vector3(0.36, 0.18, 0.12), C_STONE * 0.55, 0.3)
	var plinth := at + Vector3(-0.36, 0.18, 0)
	_box("stone", Vector3(0.52, 0.09, 0.52), plinth, stone * 0.9)
	_box("stone", Vector3(0.44, 0.74, 0.44), plinth + Vector3.UP * 0.09, stone)
	_box("stone", Vector3(0.52, 0.07, 0.52), plinth + Vector3.UP * 0.83, stone * 0.95)
	# What is left on top: two feet and the stump of the robe's hem, broken off at a slant.
	_box("stone", Vector3(0.09, 0.08, 0.17), plinth + Vector3(-0.07, 0.9, 0.04), stone * 1.05)
	_box("stone", Vector3(0.09, 0.08, 0.17), plinth + Vector3(0.07, 0.9, 0.02), stone * 1.05)
	_taper("stone", [plinth + Vector3.UP * 0.9, plinth + Vector3(0.0, 1.03, -0.03)], [0.15, 0.13], Vector3.UP, 0.4, stone, 7, true)
	# The figure, lying along the base: the robe from hem to waist, then (broken, turned a little) the chest and
	# shoulders, the head rolled off to the side, a fragment of an arm.
	var lie := Vector3(cos(0.12), 0, sin(0.12))
	var y0 := 0.18 + 0.15
	var hem := at + Vector3(-0.08, y0, 0.02)
	_taper("stone", [hem, hem + lie * 0.14, hem + lie * 0.4], [0.17, 0.16, 0.13], lie, 0.3, stone, 7, true)
	_poly("stone", _ring(hem, lie, 0.17, 7, 0.3), -lie, stone * 0.8)
	var chest_dir := Vector3(cos(-0.22), 0, sin(-0.22))
	var waist := hem + lie * 0.45 + Vector3(0, -0.01, -0.02)
	_taper("stone", [waist, waist + chest_dir * 0.12, waist + chest_dir * 0.22, waist + chest_dir * 0.26],
		[0.12, 0.15, 0.15, 0.06], chest_dir, 0.5, stone * 0.95, 7, true)
	_poly("stone", _ring(waist, chest_dir, 0.12, 7, 0.5), -chest_dir, stone * 0.75)
	var head := at + Vector3(0.52, 0.18 + 0.09, -0.19)
	var hd := Vector3(cos(1.1), 0, sin(1.1))
	_taper("stone", [head - hd * 0.1, head - hd * 0.04, head + hd * 0.05, head + hd * 0.1], [0.0, 0.08, 0.085, 0.0], hd, 0.0, stone, 6, false)
	var arm := at + Vector3(0.18, 0.18 + 0.05, 0.22)
	_taper("stone", [arm, arm + Vector3(0.24, 0.0, 0.03)], [0.05, 0.04], Vector3(1, 0, 0.12).normalized(), 0.0, stone * 0.9, 5, true)
	for k in 2:
		_box("stone", Vector3.ONE * (0.04 + 0.03 * _hp(at, 10 + k)), at + Vector3(-0.05 + 0.18 * k, 0.18, -0.24 + 0.03 * k), stone * 0.85, TAU * _hp(at, 20 + k))

## A stone pillar on two steps, a dial plate with twelve hour marks and its gnomon.
func _sundial(at: Vector3) -> void:
	var oct := PI / 8.0
	_box("stone", Vector3(0.84, 0.12, 0.84), at, C_STONE * 0.6)
	_box("stone", Vector3(0.6, 0.12, 0.6), at + Vector3.UP * 0.12, C_STONE * 0.7)
	_taper("stone", [at + Vector3.UP * 0.24, at + Vector3.UP * 0.32, at + Vector3.UP * 0.4, at + Vector3.UP * 0.84, at + Vector3.UP * 0.92, at + Vector3.UP * 0.96],
		[0.19, 0.16, 0.12, 0.11, 0.18, 0.2], Vector3.UP, oct, C_STONE * 0.85, 8, false)
	var plate := C_IRON * 1.15
	_taper("iron", [at + Vector3.UP * 0.96, at + Vector3.UP * 0.99], [0.27, 0.27], Vector3.UP, 0.0, plate, 12, true)
	for k in 12:
		var a := TAU * k / 12.0
		var dir := Vector3(cos(a), 0, sin(a))
		var side := Vector3(-dir.z, 0, dir.x) * 0.008
		var y := Vector3.UP * 0.993
		_face4("iron", at + dir * 0.19 - side + y, at + dir * 0.19 + side + y, at + dir * 0.245 + side + y, at + dir * 0.245 - side + y, Vector3.UP, plate * 0.4)
	# The gnomon: a triangle stood on the plate, its slope towards the north edge, drawn on both faces.
	var tip := at + Vector3(0, 0.99, -0.21)
	var foot := at + Vector3(0, 0.99, 0.08)
	var high := at + Vector3(0, 1.19, 0.08)
	for e: float in [-1.0, 1.0]:
		var d := Vector3(e * 0.005, 0, 0)
		_face3("iron", tip + d, foot + d, high + d, Vector3(e, 0, 0), plate * 0.9)

## The rose arch (the view draws its iron arch and the roses at its top): a raised bed across its foot, the roses
## grown thick through it to head height, so its solid footprint reads as a body and not a way through.
func _rose_arch(at: Vector3, r: float) -> void:
	_box("stone", Vector3(1.24, 0.22, 0.44), at, C_STONE * 0.5)
	_box("stone", Vector3(1.14, 0.02, 0.34), at + Vector3.UP * 0.22, C_SOIL)
	var green := Color(0.125, 0.165, 0.088)
	for i in 3:
		var x := -0.42 + i * 0.42
		var c := at + Vector3(x, 0.22, 0)
		var tall := 1.05 + 0.4 * _hp(at, 400 + i)
		_taper("thicket", [c, c + Vector3.UP * 0.35, c + Vector3.UP * tall * 0.75, c + Vector3.UP * tall],
			[0.13, 0.18, 0.15, 0.0], Vector3.UP, r + i, C_THICKET * 0.85, 6, false)
	for k in 8:
		var s := -1.0 if k % 2 == 0 else 1.0
		var x := -0.5 + 1.0 * _hp(at, 420 + k)
		var y := 0.45 + 1.45 * _hp(at, 440 + k)
		var p := at + Vector3(x, y, s * (0.16 + 0.05 * _hp(at, 460 + k)))
		var tint := green * (0.8 + 0.4 * _hp(at, 480 + k))
		tint.a = 1.0
		_card(p, Vector3(0.04 * (_hp(at, 500 + k) - 0.5), 0.2, 0.0), Vector3(0.16, 0.0, 0.03 * s), tint)
		if k % 3 == 0:
			_box("thicket", Vector3(0.08, 0.07, 0.08), p + Vector3(0.03, 0.05, s * 0.03), C_ROSE, false, r + k)

# --- helpers ---------------------------------------------------------------------------------------------------

## Sets the tag the view keeps with what it draws while it records (tests only; see client/arboretum_view.gd).
func _tag(t: String) -> void:
	v.set(&"record_tag", t)

## Which of the four sides (n e s w) of a building's cell at `at` has a hide piece against it.
func _hide_sides(at: Vector3) -> Array[bool]:
	var out: Array[bool] = [false, false, false, false]
	var spots: Array[Vector3] = v.get(&"_hide_spots")
	for side in 4:
		var want := at + SIDES[side] * (S * 0.5 + float(Arboretum.HIDE_SPEC[&"shed"][3]) / 100.0)
		for p: Vector3 in spots:
			if Vector2(p.x - want.x, p.z - want.z).length() < 0.3:
				out[side] = true
	return out

## A side with no hide against it (the first, from the seed's cell when several are free).
func _free_side(hides: Array[bool], cell: int) -> Vector3:
	var free: Array[int] = []
	for side in 4:
		if not hides[side]:
			free.append(side)
	if free.is_empty():
		return SIDES[2]
	return SIDES[free[cell % free.size()]]

## The box's own +x for a box turned to face `f` (client/arboretum_view.gd _box: yaw atan2(f.x, f.z)).
static func _right(f: Vector3) -> Vector3:
	return Vector3(f.z, 0, -f.x)

## A cell is open garden ground (not thicket, the hall's wall, a building or off the floor).
func _open(x: int, y: int) -> bool:
	if x < 0 or y < 0 or x >= Arboretum.W or y >= Arboretum.H:
		return false
	return Floor.cell_at(fp, 0, x, y) != Floor.VOID

static func _h(a: int, b: int, c: int) -> float:
	var h := (a * 73856093) ^ (b * 19349663) ^ ((c + 7919) * 83492791)
	h = (h ^ (h >> 13)) * 1274126177
	return float((h ^ (h >> 16)) & 0xFFFF) / 65535.0

## A hash of a spot (cm) and a number.
static func _hp(at: Vector3, k: int) -> float:
	return _h(roundi(at.x * 100.0), roundi(at.z * 100.0), k)

func _box(mat: String, size: Vector3, c: Vector3, col: Color, on_floor_or_yaw: Variant = 0.0, yaw := 0.0, tilt := Vector3.ZERO) -> void:
	# _box(mat, size, c, col, yaw) stands on the floor; _box(mat, size, c, col, false, yaw, tilt) is centred at c.
	if on_floor_or_yaw is bool:
		v.call(&"_box", mat, size, c, col, on_floor_or_yaw, yaw, tilt)
	else:
		v.call(&"_box", mat, size, c, col, true, float(on_floor_or_yaw), Vector3.ZERO)

func _taper(mat: String, points: Array, radii: Array, axis: Vector3, yaw: float, col: Color, sides: int, cap: bool) -> void:
	v.call(&"_taper", mat, PackedVector3Array(points), PackedFloat32Array(radii), axis, yaw, col, sides, cap)

func _rod(mat: String, a: Vector3, b: Vector3, r: float, col: Color) -> void:
	v.call(&"_taper", mat, PackedVector3Array([a, b]), PackedFloat32Array([r, r]), (b - a).normalized(), 0.0, col, 3, false)

func _card(at: Vector3, along: Vector3, across: Vector3, col: Color) -> void:
	v.call(&"_leaf_card", at, along, across, col)

## The ring of a taper's end (as client/arboretum_view.gd _taper places its spokes), for a cap.
static func _ring(at: Vector3, axis: Vector3, r: float, sides: int, yaw: float) -> Array[Vector3]:
	var ref := Vector3.FORWARD if absf(axis.dot(Vector3.UP)) > 0.98 else Vector3.UP
	var u := ref.cross(axis).normalized()
	var w := u.cross(axis).normalized()
	var out: Array[Vector3] = []
	for i in sides:
		var a := yaw + TAU * i / sides
		out.append(at + (u * cos(a) + w * sin(a)) * r)
	return out

## A triangle facing `out` (the view's faces wind so that (b - a) x (c - a) points into the body).
func _face3(mat: String, a: Vector3, b: Vector3, c: Vector3, out: Vector3, col: Color, uvs := PackedVector2Array()) -> void:
	var n := (b - a).cross(c - a).normalized()
	if n.dot(out) > 0.0:
		var t := b
		b = c
		c = t
		if uvs.size() == 3:
			uvs = PackedVector2Array([uvs[0], uvs[2], uvs[1]])
		n = -n
	v.call(&"_triangle", mat, a, b, c, -n, col, uvs)

## A flat quad facing `out`.
func _face4(mat: String, a: Vector3, b: Vector3, c: Vector3, d: Vector3, out: Vector3, col: Color) -> void:
	var n := (b - a).cross(c - a).normalized()
	if n.dot(out) > 0.0:
		v.call(&"_quad", mat, a, d, c, b, n, col)
	else:
		v.call(&"_quad", mat, a, b, c, d, n * -1.0, col)

## A convex flat polygon facing `out`.
func _poly(mat: String, pts: Array[Vector3], out: Vector3, col: Color) -> void:
	for i in range(1, pts.size() - 1):
		_face3(mat, pts[0], pts[i], pts[i + 1], out, col)

## A board under four top corners (in order round it), `thick` deep: its top, underside and edges.
func _slab(mat: String, top: Array[Vector3], thick: float, col: Color) -> void:
	var n := (top[1] - top[0]).cross(top[3] - top[0]).normalized()
	if n.y < 0.0:
		n = -n
	var low: Array[Vector3] = []
	var mid := Vector3.ZERO
	for p in top:
		low.append(p - n * thick)
		mid += p * 0.25
	_face4(mat, top[0], top[1], top[2], top[3], n, col)
	_face4(mat, low[0], low[1], low[2], low[3], -n, col * 0.7)
	for i in 4:
		var j := (i + 1) % 4
		var side := (top[i] + top[j]) * 0.5 - mid
		_face4(mat, top[i], top[j], low[j], low[i], side, col * 0.8)

## Brick map coordinates on a gable (the pavilion's brick tile is 0.54 m by 0.17 m, as client/arboretum_view.gd _box).
static func _brick_uv(pts: Array, along: Vector3) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p: Vector3 in pts:
		out.append(Vector2(p.dot(along) / 0.54, -p.y / 0.17))
	return out
