# The Clinic: a sterile, brightly lit hospital floor on two levels. Port of src/sim/clinic.ts.
#
# Constructive, cannot fail. In a canonical orientation (stair band to the north), it:
#   1. lays a rectangular ring of long straight corridors on level 0, with a cross corridor through
#      the middle, so the corridor graph has loops and long sight lines;
#   2. fills one half of the ring's interior with the atrium (two storeys tall) and puts the nurses'
#      station in the other half;
#   3. places the elevator lobby off the south side of the ring, and one or two stairs climbing north
#      out of the ring to an upper hall on level 1;
#   4. copies the ring onto level 1 as a gallery round the atrium opening (the balcony), joined to
#      the upper hall by two connectors;
#   5. hangs rooms off every corridor run, packed side by side, including a few two- or three-room
#      suites that are reached through one door (the side branches);
# then rotates or mirrors the whole plan by a seeded symmetry so floors do not all face one way.
#
# Each stage draws from its own fork of the seed, so adding a draw in one stage does not reshuffle
# the others.
extends RefCounted

const Rng = preload("res://sim/rng.gd")
const Floor = preload("res://sim/floor.gd")

const CELL_SIZE := 2
const MARGIN := 1
const STAIR_LENGTH := 4
## North band: stair, then the upper hall on level 1, then a row of 3-deep rooms beyond it.
const NORTH_BAND := STAIR_LENGTH + 4
const MIN_SIGHTLINE := 8
const ENTITY_MIN_STEPS := 12
## The car's space beyond the landing's elevator wall, in cells: along the wall (centred on the landing)
## and away from it. Holds run.gd's 4 m by 4 m car centred on the landing cell.
const CAR_ZONE_W := 3
const CAR_ZONE_D := 2
const BASE_SIZE := 36
## TypeScript starts the room budget at Infinity; any number larger than a floor can hold will do.
const UNLIMITED := 1 << 40

## Default grid size grows with depth, so deeper floors are larger. Returns Vector2i(width, height).
static func clinic_size(depth: int) -> Vector2i:
	var s := BASE_SIZE + 2 * mini(maxi(depth, 1) - 1, 4)
	return Vector2i(s, s)

# ---------------------------------------------------------------------------------------------
# Building state.

class Builder:
	var w: int
	var h: int
	var cells: Array[Array] = [[], []]
	var reserved: Array[PackedByteArray] = []
	var rooms: Array[Floor.Room] = []
	## Rooms the fillers may still add. Fixed rooms (atrium, lobby, ...) do not draw on it.
	var budget: int = UNLIMITED
	var doors: Array[Floor.Door] = []
	var stairs: Array[Floor.Stair] = []

static func _shuffled(rng: Rng, items: Array) -> Array:
	var out := items.duplicate()
	for i in range(out.size() - 1, 0, -1):
		var j := rng.int_in(0, i)
		var tmp: Variant = out[i]
		out[i] = out[j]
		out[j] = tmp
	return out

static func _new_builder(w: int, h: int) -> Builder:
	var b := Builder.new()
	b.w = w
	b.h = h
	for level in 2:
		var c: Array = []
		c.resize(w * h)
		c.fill(Floor.VOID)
		b.cells[level] = c
		var r := PackedByteArray()
		r.resize(w * h)
		b.reserved.append(r)
	return b

static func _is_free(b: Builder, level: int, x: int, y: int) -> bool:
	if x < MARGIN or y < MARGIN or x >= b.w - MARGIN or y >= b.h - MARGIN:
		return false
	var i := y * b.w + x
	return b.cells[level][i] == Floor.VOID and b.reserved[level][i] == 0

static func _kind_at(b: Builder, level: int, x: int, y: int) -> StringName:
	if x < 0 or y < 0 or x >= b.w or y >= b.h:
		return Floor.VOID
	return b.cells[level][y * b.w + x]

static func _set_cell(b: Builder, level: int, x: int, y: int, k: StringName) -> void:
	b.cells[level][y * b.w + x] = k

static func _carve(b: Builder, level: int, x: int, y: int, w: int, h: int, k: StringName) -> void:
	for yy in range(y, y + h):
		for xx in range(x, x + w):
			_set_cell(b, level, xx, yy, k)

static func _add_room(b: Builder, level: int, kind: StringName, x: int, y: int, w: int, h: int) -> Floor.Room:
	var room := Floor.Room.new()
	room.id = b.rooms.size()
	room.level = level
	room.kind = kind
	room.x = x
	room.y = y
	room.w = w
	room.h = h
	room.branch = &"main"
	b.budget -= 1
	b.rooms.append(room)
	_carve(b, level, x, y, w, h, Floor.ROOM)
	return room

static func _add_door(b: Builder, level: int, ax: int, ay: int, bx: int, by: int) -> void:
	b.doors.append(Floor.Door.make(level, ax, ay, bx, by))

# ---------------------------------------------------------------------------------------------
# Hanging rooms off a corridor run.

## A straight run of corridor cells: along `line` (a row for 'h', a column for 'v'), from `from` to
## `to` inclusive. Rooms go on one side of it; layer 0 is the corridor, layer k is k cells out.
class Run:
	var axis: StringName
	var line: int
	var from: int
	var to: int
	var side: int

	static func make(axis_: StringName, line_: int, from_: int, to_: int, side_: int) -> Run:
		var r := Run.new()
		r.axis = axis_
		r.line = line_
		r.from = from_
		r.to = to_
		r.side = side_
		return r

static func _run_cell(run: Run, along: int, layer: int) -> Vector2i:
	var across := run.line + run.side * layer
	return Vector2i(along, across) if run.axis == &"h" else Vector2i(across, along)

## Rect covering `width` cells along the run and layers [layer0+1, layer0+depth]: (x, y, w, h).
static func _run_rect(run: Run, along: int, width: int, layer0: int, depth: int) -> Rect2i:
	var a := _run_cell(run, along, layer0 + 1)
	var c := _run_cell(run, along + width - 1, layer0 + depth)
	return Rect2i(mini(a.x, c.x), mini(a.y, c.y), absi(c.x - a.x) + 1, absi(c.y - a.y) + 1)

static func _layer_free(b: Builder, level: int, run: Run, along: int, width: int, layer: int) -> bool:
	for i in width:
		var c := _run_cell(run, along + i, layer)
		if not _is_free(b, level, c.x, c.y):
			return false
	return true

static func _room_kind_for(w: int, d: int) -> StringName:
	if mini(w, d) >= 4 and w * d >= 24:
		return &"ward"
	if w * d <= 6:
		return &"closet"
	return &"exam"

class FillOptions:
	var max_depth: int
	## Suites that must be placed as soon as there is room for one.
	var force_suites: int = 0
	var suite_chance: float = 0.0
	## Chance of leaving a stretch of blank wall instead of the next room.
	var gap_chance: float = 0.0

	static func make(gap: float, max_depth_: int, suite: float = 0.0, force: int = 0) -> FillOptions:
		var o := FillOptions.new()
		o.gap_chance = gap
		o.max_depth = max_depth_
		o.suite_chance = suite
		o.force_suites = force
		return o

## Packs rooms along one side of a run, each with a door onto the corridor. Some stretches are left
## as blank wall: long featureless walls are part of the place, and they keep the room count sane.
## Returns the number of suites placed.
static func _fill_along(b: Builder, rng: Rng, level: int, run: Run, opts: FillOptions) -> int:
	var suites_to_force := opts.force_suites
	var suites := 0
	var pos := run.from
	while pos <= run.to:
		# How wide a room could start here (it needs at least two free layers).
		var span := 0
		while pos + span <= run.to and span < 12 and _layer_free(b, level, run, pos + span, 1, 1) and _layer_free(b, level, run, pos + span, 1, 2):
			span += 1
		if span < 2:
			pos += 1
			continue
		if suites_to_force == 0 and rng.chance(opts.gap_chance):
			pos += rng.int_in(3, 8)
			continue
		var dmax := 0
		while dmax < opts.max_depth and _layer_free(b, level, run, pos, mini(span, 3), dmax + 1):
			dmax += 1

		# Choose what goes here, then how wide it is. (|| short-circuits: draws only when reached.)
		var want_suite := suites_to_force > 0 or rng.chance(opts.suite_chance) or (dmax >= 6 and rng.chance(0.4))
		var kind: StringName
		if suites_to_force == 0 and span >= 6 and dmax >= 4 and rng.chance(0.25):
			kind = &"ward"
		elif want_suite and dmax >= 5 and span >= 3:
			kind = &"suite"
		else:
			kind = &"small"
		var w: int
		if kind == &"ward":
			w = rng.int_in(6, mini(12, span))
		elif kind == &"suite":
			w = rng.int_in(3, mini(6, span))
		else:
			w = rng.int_in(mini(3, span), mini(6, span))
		if span - w == 1:
			w = w - 1 if w >= 4 else w + 1  # never strand a 1-cell gap
		w = mini(w, span)
		var d := 0
		while d < opts.max_depth and _layer_free(b, level, run, pos, w, d + 1):
			d += 1
		if d < 2:
			pos += 1
			continue

		if suites_to_force == 0 and b.budget < (3 if kind == &"suite" else 1):
			return suites
		if kind == &"suite" and d >= 5:
			_place_suite(b, rng, level, run, pos, w, d)
			suites_to_force = maxi(0, suites_to_force - 1)
			suites += 1
			pos += w
			continue

		# Small rooms stay small; wards take the full depth.
		var depth: int = mini(d, 8) if kind == &"ward" else mini(mini(d, rng.int_in(3, 5)), 2 * w)
		var r := _run_rect(run, pos, w, 0, depth)
		var room_kind := &"ward" if (kind == &"ward" and depth >= 4) else _room_kind_for(mini(w, 5), mini(depth, 4))
		_add_room(b, level, room_kind, r.position.x, r.position.y, r.size.x, r.size.y)
		# Wards are walk-through: two doors, so they sit on the main route rather than off it.
		var offsets: Array[int] = []
		if room_kind == &"ward":
			offsets.append_array([1, w - 2])
		else:
			offsets.append(rng.int_in(0, w - 1))
		for o in offsets:
			var inner := _run_cell(run, pos + o, 1)
			var outer := _run_cell(run, pos + o, 0)
			_add_door(b, level, outer.x, outer.y, inner.x, inner.y)
		pos += w
	return suites

static func _not_ward(k: StringName) -> StringName:
	return &"exam" if k == &"ward" else k

## A front room on the corridor with one or two rooms behind it, reached only through it.
static func _place_suite(b: Builder, rng: Rng, level: int, run: Run, pos: int, w: int, dmax: int) -> void:
	var df := rng.int_in(2, mini(4, dmax - 2))
	var db := mini(dmax - df, 4)
	var fr := _run_rect(run, pos, w, 0, df)
	# Suites are consulting rooms with stores or offices behind; never wards, which are walk-through.
	_add_room(b, level, _not_ward(_room_kind_for(w, df)), fr.position.x, fr.position.y, fr.size.x, fr.size.y)
	var along := pos + rng.int_in(0, w - 1)
	var inner := _run_cell(run, along, 1)
	var outer := _run_cell(run, along, 0)
	_add_door(b, level, outer.x, outer.y, inner.x, inner.y)

	var half := w / 2
	var backs: Array[Vector2i] = []
	if w >= 5 and rng.chance(0.5):
		backs.append_array([Vector2i(0, half), Vector2i(half, w - half)])
	else:
		backs.append(Vector2i(0, w))
	for bk in backs:
		var off := bk.x
		var bw := bk.y
		var br := _run_rect(run, pos + off, bw, df, db)
		_add_room(b, level, _not_ward(_room_kind_for(bw, db)), br.position.x, br.position.y, br.size.x, br.size.y)
		var o := pos + off + rng.int_in(0, bw - 1)
		var front := _run_cell(run, o, df)
		var back := _run_cell(run, o, df + 1)
		_add_door(b, level, front.x, front.y, back.x, back.y)

## Fills the block between two north-south halls (columns xl and xr), rows y0..y1. One full-width
## ward cuts across it with a door onto each hall (a walk-through room on the main route, the kind
## you take as a shortcut); the rest is smaller rooms backing onto each other from either hall.
static func _fill_block(b: Builder, rng: Rng, level: int, xl: int, xr: int, y0: int, y1: int, gap: float) -> void:
	var bw := xr - xl - 1
	var span := y1 - y0 + 1
	if span >= 4 and bw >= 4 and b.budget >= 1:
		var hgt := rng.int_in(4, mini(7, span))
		var y: int = rng.pick([y0, y1 - hgt + 1, y0 + (span - hgt) / 2])
		_add_room(b, level, &"ward" if bw * hgt >= 24 else &"exam", xl + 1, y, bw, hgt)
		var wy := y + rng.int_in(0, hgt - 1)
		var ey := y + rng.int_in(0, hgt - 1)
		_add_door(b, level, xl, wy, xl + 1, wy)
		_add_door(b, level, xr, ey, xr - 1, ey)
	var half := ceili(bw / 2.0)
	_fill_along(b, rng, level, Run.make(&"v", xl, y0, y1, 1), FillOptions.make(gap, half if rng.chance(0.5) else bw))
	_fill_along(b, rng, level, Run.make(&"v", xr, y0, y1, -1), FillOptions.make(gap, bw))

# ---------------------------------------------------------------------------------------------
# Layout.

class Ring:
	var x0: int
	var x1: int
	var y0: int
	var y1: int
	var wN: int
	var wS: int
	var wW: int
	var wE: int

	func ix0() -> int:
		return x0 + wW

	func ix1() -> int:
		return x1 - wE

	func iy0() -> int:
		return y0 + wN

	func iy1() -> int:
		return y1 - wS

static func _carve_ring(b: Builder, level: int, r: Ring) -> void:
	_carve(b, level, r.x0, r.y0, r.x1 - r.x0 + 1, r.wN, Floor.CORRIDOR)
	_carve(b, level, r.x0, r.y1 - r.wS + 1, r.x1 - r.x0 + 1, r.wS, Floor.CORRIDOR)
	_carve(b, level, r.x0, r.y0, r.wW, r.y1 - r.y0 + 1, Floor.CORRIDOR)
	_carve(b, level, r.x1 - r.wE + 1, r.y0, r.wE, r.y1 - r.y0 + 1, Floor.CORRIDOR)

class Canonical:
	var b: Builder
	var landing: Floor.Pos

static func _lay_out(seed: String, depth: int, W: int, H: int) -> Canonical:
	var root := Rng.make_rng("clinic:%s:%d" % [seed, depth])
	var shape := root.fork("shape")
	var b := _new_builder(W, H)

	# --- Ring of main halls. Bands outside the ring hold rooms; the north band also holds the stairs.
	var usable_w := W - 2 * MARGIN
	var usable_h := H - 2 * MARGIN
	var band_sum_max := usable_w - 19  # keeps the ring at least 19 wide, its interior at least 15
	var bW := shape.int_in(4, mini(8, band_sum_max - 4))
	var bE := shape.int_in(4, mini(8, band_sum_max - bW))
	var bS := shape.int_in(4, mini(8, usable_h - NORTH_BAND - 17))
	var ring := Ring.new()
	ring.x0 = MARGIN + bW
	ring.x1 = W - 1 - MARGIN - bE
	ring.y0 = MARGIN + NORTH_BAND
	ring.y1 = H - 1 - MARGIN - bS
	ring.wN = 2 if shape.chance(0.5) else 1
	ring.wS = 2 if shape.chance(0.5) else 1
	ring.wW = 2 if shape.chance(0.4) else 1
	ring.wE = 2 if shape.chance(0.4) else 1
	var ix0 := ring.ix0()
	var ix1 := ring.ix1()
	var iy0 := ring.iy0()
	var iy1 := ring.iy1()
	var iw := ix1 - ix0 + 1
	var ih := iy1 - iy0 + 1

	# --- Cross corridor splits the interior: atrium on one side, station and rooms on the other.
	var aw := shape.int_in(8, mini(12, iw - 6))
	var cx := ix0 + aw
	var strip := shape.int_in(3, mini(5, ih - 10)) if (ih >= 13 and shape.chance(0.5)) else 0
	# A wide far half gets a second cross corridor: another loop, and blocks no deeper than a ward.
	var far := ix1 - cx
	var cx2 := cx + 1 + shape.int_in(6, far - 7) if far >= 13 else 0

	for level in 2:
		_carve_ring(b, level, ring)
		_carve(b, level, cx, iy0, 1, ih, Floor.CORRIDOR)
		if cx2 > 0:
			_carve(b, level, cx2, iy0, 1, ih, Floor.CORRIDOR)

	# Atrium: a room on level 0, an opening on level 1 with the gallery running round it.
	var atrium := _add_room(b, 0, &"atrium", ix0, iy0, aw, ih - strip)
	_carve(b, 1, atrium.x, atrium.y, atrium.w, atrium.h, Floor.ATRIUM_OPEN)
	var door_rows: Array[int] = []
	door_rows.append(atrium.y + 1 + shape.int_in(0, atrium.h / 3))
	door_rows.append(atrium.y + atrium.h - 2 - shape.int_in(0, atrium.h / 3))
	for y in door_rows:
		_add_door(b, 0, ix0 - 1, y, ix0, y)
	_add_door(b, 0, cx, atrium.y + atrium.h / 2, cx - 1, atrium.y + atrium.h / 2)
	var nx := atrium.x + shape.int_in(1, atrium.w - 2)
	_add_door(b, 0, nx, iy0 - 1, nx, iy0)

	# Nurses' station: at the head of the other half, opening onto both the north hall and the cross.
	var bw := (cx2 if cx2 > 0 else ix1 + 1) - cx - 1
	var sw := mini(bw, shape.int_in(4, 6))
	var sh := shape.int_in(3, 4)
	_add_room(b, 0, &"station", cx + 1, iy0, sw, sh)
	var stx := cx + 1 + shape.int_in(0, sw - 1)
	_add_door(b, 0, stx, iy0 - 1, stx, iy0)
	var sy := iy0 + shape.int_in(0, sh - 1)
	_add_door(b, 0, cx, sy, cx + 1, sy)

	# --- Elevator lobby off the south hall. Two doors, so it is not a dead end.
	var lw := 5
	var ld := mini(bS, 4)
	var lx := shape.int_in(ring.x0 + 2, ring.x1 - 2 - lw)
	var lobby := _add_room(b, 0, &"lobby", lx, ring.y1 + 1, lw, ld)
	_add_door(b, 0, lx, ring.y1, lx, ring.y1 + 1)
	_add_door(b, 0, lx + lw - 1, ring.y1, lx + lw - 1, ring.y1 + 1)
	var landing := Floor.Pos.make(0, lx + lw / 2, lobby.y + lobby.h - 1)
	_set_cell(b, 0, landing.x, landing.y, Floor.LANDING)
	b.reserved[1][landing.y * W + landing.x] = 1  # elevator shaft
	# The car's space beyond the lobby's outer wall (run.gd CAR_WIDTH by CAR_DEPTH, 4 m square, centred
	# on the landing: three cells along the wall, two away from it) and the shaft above it stay void on
	# both levels. Level 0 is clear anyway (the lobby holds those columns); this keeps level-1 rooms off it.
	# Cells past the grid's edge are void already.
	for level in 2:
		for dy in range(1, CAR_ZONE_D + 1):
			for dx in range(-(CAR_ZONE_W / 2), CAR_ZONE_W / 2 + 1):
				var zx := landing.x + dx
				var zy := landing.y + dy
				if zx >= 0 and zx < W and zy >= 0 and zy < H:
					b.reserved[level][zy * W + zx] = 1

	# --- Stairs climb north out of the ring to the upper hall on level 1.
	var stair_rng := root.fork("stairs")
	var two_stairs := stair_rng.chance(minf(0.9, 0.35 + 0.2 * depth)) and ring.x1 - ring.x0 >= 18
	var span := ring.x1 - ring.x0
	var stair_xs: Array[int] = []
	if two_stairs:
		stair_xs.append(stair_rng.int_in(ring.x0 + 3, ring.x0 + span / 2 - 3))
		stair_xs.append(stair_rng.int_in(ring.x0 + span / 2 + 3, ring.x1 - 3))
	else:
		stair_xs.append(stair_rng.int_in(ring.x0 + 3, ring.x1 - 3))
	for sx in stair_xs:
		var stair := Floor.Stair.make(sx, ring.y0 - 1, &"n", STAIR_LENGTH)
		b.stairs.append(stair)
		for c in Floor.stair_cells(stair):
			_set_cell(b, 0, c.x, c.y, Floor.STAIR)
			_set_cell(b, 1, c.x, c.y, Floor.STAIR)
	var hall_y := ring.y0 - STAIR_LENGTH - 1
	_carve(b, 1, ring.x0, hall_y, ring.x1 - ring.x0 + 1, 1, Floor.CORRIDOR)
	_carve(b, 1, ring.x0, hall_y, 1, ring.y0 - hall_y, Floor.CORRIDOR)
	_carve(b, 1, ring.x1, hall_y, 1, ring.y0 - hall_y, Floor.CORRIDOR)

	# --- Rooms. Level 0 first, then level 1, each from its own fork.
	var deeper := maxi(0, depth - 1)
	var gap := 0.35 + 0.03 * deeper
	# A room budget keeps every floor in a sane range however big the grid gets: runs filled later
	# run out and are left as blank wall. Run order is shuffled so it is not always the same side.
	var max_rooms := mini(40, 32 + 3 * depth)
	var r0 := root.fork("rooms0")
	b.budget = int(floor(max_rooms * 0.6)) - b.rooms.size()
	var north_out := Run.make(&"h", ring.y0, ring.x0, ring.x1, -1)
	var south_out := Run.make(&"h", ring.y1, ring.x0, ring.x1, 1)
	var west_out := Run.make(&"v", ring.x0, ring.y0, ring.y1, -1)
	var east_out := Run.make(&"v", ring.x1, ring.y0, ring.y1, 1)
	_fill_along(b, r0, 0, north_out, FillOptions.make(gap, NORTH_BAND, 0.3 + 0.1 * deeper, 2))
	_fill_block(b, r0, 0, cx, cx2 if cx2 > 0 else ix1 + 1, iy0 + sh, iy1, gap)
	if cx2 > 0:
		_fill_block(b, r0, 0, cx2, ix1 + 1, iy0, iy1, gap)
	var lower: Array = [
		[south_out, FillOptions.make(gap, bS, 0.15 * deeper)],
		[west_out, FillOptions.make(gap, bW, 0.2 + 0.1 * deeper)],
		[east_out, FillOptions.make(gap, bE, 0.2 + 0.1 * deeper)],
	]
	if strip > 0:
		lower.append([Run.make(&"h", iy1 + 1, ix0, cx - 1, -1), FillOptions.make(gap, strip)])
	for pair: Array in _shuffled(r0, lower):
		_fill_along(b, r0, 0, pair[0], pair[1])

	var r1 := root.fork("rooms1")
	b.budget = max_rooms - b.rooms.size()
	_fill_block(b, r1, 1, cx, cx2 if cx2 > 0 else ix1 + 1, iy0, iy1, gap)
	if cx2 > 0:
		_fill_block(b, r1, 1, cx2, ix1 + 1, iy0, iy1, gap)
	var hall_run := Run.make(&"h", hall_y, ring.x0, ring.x1, -1)
	_fill_along(b, r1, 1, Run.make(&"h", hall_y, ring.x0 + 1, ring.x1 - 1, 1), FillOptions.make(gap, STAIR_LENGTH))
	var upper: Array = [[hall_run, FillOptions.make(gap, hall_y - MARGIN)]]
	if strip > 0:
		upper.append([Run.make(&"h", iy1 + 1, ix0, cx - 1, -1), FillOptions.make(gap, strip)])
	# The upper storey is smaller than the lower: each outer wing is built only some of the time.
	var wings := root.fork("wings")
	var west_up := wings.chance(0.6)
	var east_up := wings.chance(0.5 if west_up else 1.0)
	if west_up:
		upper.append([Run.make(&"v", ring.x0, hall_y, ring.y1, -1), FillOptions.make(gap, bW, 0.25)])
	if east_up:
		upper.append([Run.make(&"v", ring.x1, hall_y, ring.y1, 1), FillOptions.make(gap, bE, 0.25)])
	if wings.chance(0.25 + 0.1 * deeper):
		upper.append([south_out, FillOptions.make(gap, bS)])
	for pair: Array in _shuffled(r1, upper):
		_fill_along(b, r1, 1, pair[0], pair[1])

	var out := Canonical.new()
	out.b = b
	out.landing = landing
	return out

# ---------------------------------------------------------------------------------------------
# Orientation: one of the grid's symmetries, applied to everything.

## Symmetry number k of a W x H grid (TypeScript: symmetries(W, H)[k]).
static func _xf(k: int, W: int, H: int, x: int, y: int) -> Vector2i:
	match k:
		0:
			return Vector2i(x, y)
		1:
			return Vector2i(W - 1 - x, y)
		2:
			return Vector2i(x, H - 1 - y)
		3:
			return Vector2i(W - 1 - x, H - 1 - y)
		4:
			return Vector2i(y, x)
		5:
			return Vector2i(W - 1 - y, x)
		6:
			return Vector2i(y, H - 1 - x)
		_:
			return Vector2i(W - 1 - y, H - 1 - x)

static func _symmetry_count(W: int, H: int) -> int:
	return 4 if W != H else 8

static func _transform(b: Builder, landing: Floor.Pos, k: int) -> Canonical:
	var out := _new_builder(b.w, b.h)
	for level in 2:
		for y in b.h:
			for x in b.w:
				var n := _xf(k, b.w, b.h, x, y)
				_set_cell(out, level, n.x, n.y, _kind_at(b, level, x, y))
	for r in b.rooms:
		var a := _xf(k, b.w, b.h, r.x, r.y)
		var c := _xf(k, b.w, b.h, r.x + r.w - 1, r.y + r.h - 1)
		var nr := r.copy()
		nr.x = mini(a.x, c.x)
		nr.y = mini(a.y, c.y)
		nr.w = absi(c.x - a.x) + 1
		nr.h = absi(c.y - a.y) + 1
		out.rooms.append(nr)
	for d in b.doors:
		var a := _xf(k, b.w, b.h, d.ax, d.ay)
		var bb := _xf(k, b.w, b.h, d.bx, d.by)
		out.doors.append(Floor.Door.make(d.level, a.x, a.y, bb.x, bb.y))
	for s in b.stairs:
		var p := _xf(k, b.w, b.h, s.x, s.y)
		var p2 := _xf(k, b.w, b.h, s.x + Floor.dir_dx(s.dir), s.y + Floor.dir_dy(s.dir))
		out.stairs.append(Floor.Stair.make(p.x, p.y, Floor.dir_from_vec(p2.x - p.x, p2.y - p.y), s.length))
	var l := _xf(k, b.w, b.h, landing.x, landing.y)
	var res := Canonical.new()
	res.b = out
	res.landing = Floor.Pos.make(landing.level, l.x, l.y)
	return res

# ---------------------------------------------------------------------------------------------

## generateClinic(seed, depth, { width, height }); width/height 0 mean the default for the depth.
static func generate_clinic(seed: String, depth: int, width: int = 0, height: int = 0) -> Floor.FloorPlan:
	var size := clinic_size(depth)
	var W := width if width != 0 else size.x
	var H := height if height != 0 else size.y
	if W < 32 or H < 32:
		push_error("clinic needs at least 32x32 cells, got %dx%d" % [W, H])
		return null

	var canon := _lay_out(seed, depth, W, H)
	var pick := Rng.make_rng("clinic:%s:%d" % [seed, depth]).fork("orient").int_in(0, _symmetry_count(W, H) - 1)
	var t := _transform(canon.b, canon.landing, pick)
	var b := t.b

	var plan := Floor.FloorPlan.new()
	plan.place = &"clinic"
	plan.seed = seed
	plan.depth = depth
	plan.width = W
	plan.height = H
	plan.cell_size = CELL_SIZE
	plan.cells = b.cells
	plan.rooms = b.rooms
	plan.doors = b.doors
	plan.stairs = b.stairs
	plan.landing = t.landing
	plan.entity_start = t.landing
	plan.sightlines = []

	# Side branches: mark every room in a dead-end group.
	var room_at := func(d: Floor.Door, end: String) -> int:
		var x := d.ax if end == "a" else d.bx
		var y := d.ay if end == "a" else d.by
		for rr in b.rooms:
			if rr.level == d.level and x >= rr.x and x < rr.x + rr.w and y >= rr.y and y < rr.y + rr.h:
				return rr.id
		return -1
	for group in Floor.side_branches(b.rooms, b.doors, room_at):
		for id in group:
			if id >= 0 and id < b.rooms.size():
				b.rooms[id].branch = &"side"

	plan.sightlines = Floor.find_sightlines(plan, MIN_SIGHTLINE)
	plan.entity_start = _choose_entity_start(plan, Rng.make_rng("clinic:%s:%d" % [seed, depth]).fork("entity"))
	return plan

## The entity starts at the far end of a long hall, at least ENTITY_MIN_STEPS from the landing, so
## the crew can see it down the corridor before it can reach them. Ends of sightlines are preferred;
## among them, one of the farthest from the landing.
static func _choose_entity_start(plan: Floor.FloorPlan, rng: Rng) -> Floor.Pos:
	var dist := Floor.distances_from(plan, plan.landing)
	var candidates: Array[Floor.Pos] = []
	for s in plan.sightlines:
		candidates.append(Floor.Pos.make(s.level, s.x1, s.y1))
		candidates.append(Floor.Pos.make(s.level, s.x2, s.y2))
	var kept: Array[Floor.Pos] = []
	for p in candidates:
		if dist[Floor.pos_index(plan, p)] >= ENTITY_MIN_STEPS:
			kept.append(p)
	candidates = kept
	if candidates.is_empty():
		# Not expected with this layout; fall back to the farthest point on any sightline.
		for s in plan.sightlines:
			for x in range(mini(s.x1, s.x2), maxi(s.x1, s.x2) + 1):
				for y in range(mini(s.y1, s.y2), maxi(s.y1, s.y2) + 1):
					candidates.append(Floor.Pos.make(s.level, x, y))
	if candidates.is_empty():
		return plan.landing
	var far := -1
	for p in candidates:
		far = maxi(far, dist[Floor.pos_index(plan, p)])
	var pool: Array = []
	for p in candidates:
		if float(dist[Floor.pos_index(plan, p)]) >= far * 0.8:
			pool.append(p)
	return rng.pick(pool)
