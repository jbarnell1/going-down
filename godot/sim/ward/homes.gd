# WH1: real homes for the Hanging Ward (the run flag `ward_homes`, net/host_rules.gd; the approved design of 21 Nov,
# owner: "Good with these defaults."). The six house types are data (data/ward_homes.json): rooms (a kitchen, a
# table, bedrooms, a bathroom, a hall), the doors between them, the windows the Rigger's hand can come in by, the stair
# and the furniture. This file reads the data and resolves one house's plan from the floor seed: the variant, the
# mirror (the layout's own, sim/ward/layout.gd generate_v2), each door's place along its wall and each piece of
# furniture's place. One random stream per house, "ward_homes:<floor seed>:<house id>", every draw made in a fixed
# order whatever the plan, so the host and every screen resolve the same house. No engine randomness beyond that
# seeded stream; no chance on a client. sim/ward/house.gd builds the walls, rooms, openings and the arm from it.
extends RefCounted

const PATH := "res://data/ward_homes.json"
## Plan coordinates closer than this are the same line.
const EPS := 0.005
## A door's gap stays this far from the ends of its wall.
const DOOR_MARGIN := 0.2

# WH2: every opening a walker uses keeps a clear approach on each side of its wall: a rectangle the opening's own width
# and APPROACH deep, with no furniture in it and not the front door's leaf where the screen draws it open
# (client/ward/dress.gd door_leaf). The openings: each inner doorway (both sides), the front door and the lift's doorway
# (inside), and each stair's foot and head (the stair's width, beyond its ends). A piece drawn into one is moved to
# another of its listed places, else to the nearest clear place along a wall of its own room; no draw is added, so a
# home with no blocked opening comes out exactly as before. tests/ward_home_clear.gd checks the built houses.
## A walker's body, each side of their middle: sim/ward/state.gd WALK_CLEARANCE (tests/ward_home_clear.gd checks they agree).
const WALKER := 0.15
## How deep a clear approach reaches beyond its wall: two walkers' depths, one to stand clear of the doorway and one
## to step aside in (WH2's own number; the design does not give one).
const APPROACH := WALKER * 4.0
## sim/ward/house.gd WALL_THICKNESS and STAIR_WIDTH, and the lift's doorway (sim/ward/state.gd GATE), checked as above.
const WALL := 0.14
const STAIR := 1.0
const LIFT_GATE := 1.24
## The front door's leaf as drawn open (client/ward/dress.gd door_leaf): it hangs this far in from its jamb and stands
## this thick with its panels and knob.
const LEAF_INSET := 0.01
const LEAF_THICK := 0.14
## A piece moved to a wall stands this far from the room's edge (the wall's middle line), the data's own margin.
const WALL_GAP := 0.1
## The steps along a wall a moved piece is tried at.
const SLIDE := 0.05

static var _data: Dictionary = {}

## The data file, read once.
static func data() -> Dictionary:
	if _data.is_empty():
		var raw := FileAccess.get_file_as_string(PATH)
		var parsed: Variant = JSON.parse_string(raw) if raw != "" else null
		_data = parsed if parsed is Dictionary else {}
	return _data

static func types() -> Array:
	return data().get("types", [])

## The type that houses a layout style ({} for a style no type names).
static func type_for_style(style: String) -> Dictionary:
	for t: Dictionary in types():
		if (t.get("styles", []) as Array).has(style):
			return t
	return {}

## The footprint (width along the front wall, depth) a style gets with the homes, or Vector2.ZERO for none.
static func size_for_style(style: String) -> Vector2:
	var t := type_for_style(style)
	return Vector2(float(t.w), float(t.d)) if not t.is_empty() else Vector2.ZERO

## The storeys a style's type has (0 for none).
static func floors_for_style(style: String) -> int:
	var t := type_for_style(style)
	if t.is_empty():
		return 0
	return (_variant_storeys(t, (t.variants as Array)[0]) as Array).size()

## The variant a `copy` variant is made from (itself for any other).
static func _base_of(t: Dictionary, v: Dictionary) -> Dictionary:
	for other: Dictionary in t.variants:
		if v.has("copy") and other.id == v.copy:
			return other
	return v

## A variant's storeys, with a `copy` variant's changes made (upper windows, upper room names, upper furniture).
static func _variant_storeys(t: Dictionary, v: Dictionary) -> Array:
	if not v.has("copy"):
		return v.storeys
	var base: Dictionary = {}
	for other: Dictionary in t.variants:
		if other.id == v.copy:
			base = other
	var out: Array = (base.storeys as Array).duplicate(true)
	for level in range(1, out.size()):
		var storey: Dictionary = out[level]
		if v.has("upper_windows"):
			storey.windows = (v.upper_windows as Array).duplicate(true)
		if v.has("upper_furniture"):
			storey.furniture = (v.upper_furniture as Array).duplicate(true)
		if v.has("upper_rooms"):
			for room: Dictionary in storey.rooms:
				if (v.upper_rooms as Dictionary).has(room.name):
					room.kind = v.upper_rooms[room.name]
	return out

## The variants a style may be built as.
static func _variants_for(t: Dictionary, style: String) -> Array:
	var out := []
	for v: Dictionary in t.variants:
		if not v.has("styles") or (v.styles as Array).has(style):
			out.append(v)
	return out

## One house's plan, in the house's own frame (sim/ward/house.gd: x from -w/2 to w/2 along the front wall, z from the
## front wall to the back), mirrored when the site says so. {} when the style has no type.
## {"type", "variant", "w", "d", "door": {"x", "w"}, "storeys": [{"rooms": [{"name", "kind", "rect": Rect2 (x, z)}],
## "doors": [{"a", "b", "w", "line": &"x" (a wall along z at x = pos) or &"z" (along x at z = pos), "pos", "at"}],
## "windows": [{"wall": &"left"|&"right"|&"front"|&"back", "at", "room"}], "furniture": [{"kind", "room", "rect", "h",
## "hide"}], "stair": {} or {"axis": &"x"|&"z", "lane", "from", "to"}}]}
static func resolve(site: Dictionary, ward_seed: int) -> Dictionary:
	var t := type_for_style(str(site.style))
	if t.is_empty():
		return {}
	var rng := RandomNumberGenerator.new()
	rng.seed = ("ward_homes:%d:%d" % [ward_seed, int(site.id)]).hash()
	var allowed := _variants_for(t, str(site.style))
	var v: Dictionary = allowed[rng.randi_range(0, allowed.size() - 1)]
	var w := float(t.w)
	var d := float(t.d)
	var mirror := bool(site.get("mirror", false)) and int(site.id) != 0
	var mx := func(x: float) -> float: return (w * 0.5 - x) if mirror else (x - w * 0.5)
	var door_spec: Dictionary = v.door if v.has("door") else _base_of(t, v).door
	var door_at: Array = door_spec.at
	var door_x: float = mx.call(rng.randf_range(float(door_at[0]), float(door_at[1])))
	var out := {"type": t.id, "variant": v.id, "w": w, "d": d, "mirror": mirror,
		"door": {"x": door_x, "w": float(door_spec.w), "hinge": -1}, "storeys": [], "moved": [], "dropped": []}
	var raw_storeys := _variant_storeys(t, v)
	# WH2: every storey's stair first (no draw), so a storey's furniture knows the foot of the stair above it.
	var stairs: Array[Dictionary] = []
	for raw_storey: Dictionary in raw_storeys:
		stairs.append(_stair_of(raw_storey, mx))
	var bounds := Rect2(-w * 0.5, 0.0, w, d)
	var level := -1
	for raw_storey: Dictionary in raw_storeys:
		level += 1
		var rooms := []
		var by_name := {}
		for room: Dictionary in raw_storey.rooms:
			var r: Array = room.rect
			by_name[room.name] = r
			var x0: float = mx.call(float(r[0]))
			var x1: float = mx.call(float(r[2]))
			rooms.append({"name": StringName(room.name), "kind": StringName(room.kind),
				"rect": Rect2(minf(x0, x1), float(r[1]), absf(x1 - x0), float(r[3]) - float(r[1]))})
		var doors := []
		for door: Dictionary in raw_storey.get("doors", []):
			var a: Array = by_name[door.rooms[0]]
			var b: Array = by_name[door.rooms[1]]
			var at := rng.randf_range(float(door.at[0]), float(door.at[1]))
			var entry := {"a": StringName(door.rooms[0]), "b": StringName(door.rooms[1]), "w": float(door.w)}
			if absf(float(a[2]) - float(b[0])) < EPS or absf(float(b[2]) - float(a[0])) < EPS:
				# The rooms side by side: a wall along z at their shared x; the door's place is a z.
				entry.line = &"x"
				entry.pos = mx.call(float(a[2]) if absf(float(a[2]) - float(b[0])) < EPS else float(a[0]))
				entry.at = at
			else:
				entry.line = &"z"
				entry.pos = float(a[3]) if absf(float(a[3]) - float(b[1])) < EPS else float(a[1])
				entry.at = mx.call(at)
			doors.append(entry)
		var windows := []
		for win: Dictionary in raw_storey.get("windows", []):
			var wall := StringName(win.wall)
			var at := float(win.at)
			if wall == &"front" or wall == &"back":
				at = mx.call(at)
			elif mirror:
				wall = &"right" if wall == &"left" else &"left"
			windows.append({"wall": wall, "at": at, "room": StringName(win.room)})
		# WH2: the clear approaches of this storey's openings, and where nothing may be moved to besides.
		var zones := approaches(doors, stairs[level], stairs[level + 1] if level + 1 < stairs.size() else {}, bounds)
		if level == 0:
			if int(site.id) == 0:
				zones.append(Rect2(-w * 0.5, d * 0.5 - LIFT_GATE * 0.5, APPROACH, LIFT_GATE))
			# The front door's leaf hangs on its low-x jamb unless, open, it would stand in another opening's approach
			# and on the other jamb it would not.
			if _meets_any(front_leaf(door_x, float(door_spec.w), -1).rest, zones) and not _meets_any(front_leaf(door_x, float(door_spec.w), 1).rest, zones):
				out.door.hinge = 1
			zones.append(Rect2(door_x - float(door_spec.w) * 0.5, WALL * 0.5, float(door_spec.w), APPROACH))
		var leaf: Dictionary = front_leaf(door_x, float(door_spec.w), int(out.door.hinge)) if level == 0 else {}
		var keep_out := zones.duplicate()
		for st: Dictionary in [stairs[level], stairs[level + 1] if level + 1 < stairs.size() else {}]:
			if not st.is_empty():
				keep_out.append(shaft(st))
		for win: Dictionary in windows:
			keep_out.append(_window_front(win, bounds))
		var furniture := []
		var placed: Array[Rect2] = []
		var moved: Array[Rect2] = []
		for piece: Dictionary in raw_storey.get("furniture", []):
			var spots: Array = piece.at
			var pick := rng.randi_range(0, spots.size() - 1)
			var rect := _spot(spots[pick], mx)
			if _meets_any(rect, zones) or _meets_any(rect, moved) or meets_leaf(rect, leaf):
				var room_rect := Rect2()
				for room: Dictionary in rooms:
					if room.name == StringName(piece.room):
						room_rect = room.rect
				var from := rect
				rect = Rect2()
				for k in range(1, spots.size()):
					var other := _spot(spots[(pick + k) % spots.size()], mx)
					if not _meets_any(other, keep_out) and not _meets_any(other, placed) and not meets_leaf(other, leaf):
						rect = other
						break
				var listed := rect.has_area()
				if not listed:
					rect = _to_a_wall(from, room_rect, keep_out, placed, leaf)
				if not rect.has_area():
					(out.dropped as Array).append({"level": level, "kind": StringName(piece.kind), "room": StringName(piece.room)})
					continue
				(out.moved as Array).append({"level": level, "kind": StringName(piece.kind), "room": StringName(piece.room), "from": from, "to": rect, "listed": listed})
				moved.append(rect)
			placed.append(rect)
			furniture.append({"kind": StringName(piece.kind), "room": StringName(piece.room), "h": float(piece.h),
				"hide": StringName(piece.get("hide", "")), "rect": rect})
		(out.storeys as Array).append({"rooms": rooms, "doors": doors, "windows": windows, "furniture": furniture, "stair": stairs[level]})
	return out

## A storey's stair in the house's frame (mirrored as the house is), {} for none.
static func _stair_of(raw_storey: Dictionary, mx: Callable) -> Dictionary:
	if not raw_storey.has("stair"):
		return {}
	var s: Dictionary = raw_storey.stair
	var stair := {"axis": StringName(s.axis), "lane": float(s.lane), "from": float(s.from), "to": float(s.to)}
	if stair.axis == &"x":
		stair.from = mx.call(float(s.from))
		stair.to = mx.call(float(s.to))
	else:
		stair.lane = mx.call(float(s.lane))
	return stair

## A listed place of a piece in the house's frame.
static func _spot(r: Array, mx: Callable) -> Rect2:
	var x0: float = mx.call(float(r[0]))
	var x1: float = mx.call(float(r[2]))
	return Rect2(minf(x0, x1), float(r[1]), absf(x1 - x0), float(r[3]) - float(r[1]))

## WH2: the clear approaches of a storey's inner doorways (both sides), the head of the stair coming up to it (`up`)
## and the foot of the stair leaving it (`next`), each a Rect2 (x, z) in the house's frame.
static func approaches(doors: Array, up: Dictionary, next: Dictionary, bounds: Rect2) -> Array[Rect2]:
	var out: Array[Rect2] = []
	for door: Dictionary in doors:
		var pos := float(door.pos)
		var at := float(door.at)
		var half := float(door.w) * 0.5
		for side: float in [-1.0, 1.0]:
			var near := pos + side * WALL * 0.5
			var lo := minf(near, near + side * APPROACH)
			if door.line == &"x":
				out.append(Rect2(lo, at - half, APPROACH, half * 2.0))
			else:
				out.append(Rect2(at - half, lo, half * 2.0, APPROACH))
	if not up.is_empty():
		out.append(stair_end(up, false).intersection(bounds))
	if not next.is_empty():
		out.append(stair_end(next, true).intersection(bounds))
	return out

## The clear approach at a stair's foot (before its bottom, on the storey below) or head (beyond its top).
static func stair_end(stair: Dictionary, foot: bool) -> Rect2:
	var dir := signf(float(stair.to) - float(stair.from))
	var a := float(stair.from) if foot else float(stair.to)
	var b := a + (-dir if foot else dir) * APPROACH
	var lane := float(stair.lane)
	if stair.axis == &"x":
		return Rect2(minf(a, b), lane - STAIR * 0.5, APPROACH, STAIR)
	return Rect2(lane - STAIR * 0.5, minf(a, b), STAIR, APPROACH)

## A stair's footprint (sim/ward/house.gd's shaft): its treads on the storey below, its hole on the storey above.
static func shaft(stair: Dictionary) -> Rect2:
	var lo := minf(float(stair.from), float(stair.to))
	var run := absf(float(stair.to) - float(stair.from))
	var lane := float(stair.lane)
	if stair.axis == &"x":
		return Rect2(lo - 0.03, lane - STAIR * 0.53, run + 0.06, STAIR * 1.06)
	return Rect2(lane - STAIR * 0.53, lo - 0.03, STAIR * 1.06, run + 0.06)

## The space inside a window a moved piece keeps clear of (the hole's width, an approach deep).
static func _window_front(win: Dictionary, bounds: Rect2) -> Rect2:
	var at := float(win.at)
	match win.wall:
		&"left":
			return Rect2(bounds.position.x, at - 0.71, APPROACH, 1.42)
		&"right":
			return Rect2(bounds.end.x - APPROACH, at - 0.71, APPROACH, 1.42)
		&"front":
			return Rect2(at - 0.71, 0.0, 1.42, APPROACH)
	return Rect2(at - 0.71, bounds.end.y - APPROACH, 1.42, APPROACH)

## WH2: the front door's leaf as the screen draws it (client/ward/dress.gd door_leaf), in the house's frame: hung on
## its low-x jamb (`side` -1) or its high-x jamb (1), shutting along the front wall and open straight into the house.
## {"side", "hinge": Vector2 (x, z), "length", "rest": Rect2 where it stands open}.
static func front_leaf(door_x: float, door_w: float, side: int) -> Dictionary:
	var length := door_w - LEAF_INSET * 2.0
	var hinge := Vector2(door_x - door_w * 0.5 + LEAF_INSET if side < 0 else door_x + door_w * 0.5 - LEAF_INSET, 0.0)
	return {"side": side, "hinge": hinge, "length": length,
		"rest": Rect2(hinge.x - LEAF_THICK * 0.5, -LEAF_THICK * 0.5, LEAF_THICK, length + LEAF_THICK * 0.5)}

## Whether a rectangle meets where the leaf stands open or the quarter it swings through.
static func meets_leaf(r: Rect2, leaf: Dictionary) -> bool:
	if leaf.is_empty():
		return false
	if _meets(r, leaf.rest):
		return true
	var hinge: Vector2 = leaf.hinge
	var length := float(leaf.length)
	var quarter := Rect2(hinge.x if int(leaf.side) < 0 else hinge.x - length, hinge.y, length, length)
	var part := r.intersection(quarter)
	if part.size.x <= EPS or part.size.y <= EPS:
		return false
	var nearest := Vector2(clampf(hinge.x, part.position.x, part.end.x), clampf(hinge.y, part.position.y, part.end.y))
	return nearest.distance_to(hinge) < length - EPS

## Overlap by more than rounding.
static func _meets(a: Rect2, b: Rect2) -> bool:
	return a.grow(-EPS * 0.2).intersects(b.grow(-EPS * 0.2))

static func _meets_any(r: Rect2, list: Array) -> bool:
	for other: Rect2 in list:
		if other.has_area() and _meets(r, other):
			return true
	return false

## The nearest clear place to `from` against a wall of its room, stepping SLIDE along each wall, the same way round if
## any is clear, else turned; Rect2() when the room has none. Clear: inside the room by WALL_GAP, out of every approach,
## stair and window front, off every piece placed, and out of the front door's leaf.
static func _to_a_wall(from: Rect2, room: Rect2, keep_out: Array, placed: Array, leaf: Dictionary) -> Rect2:
	var inner := room.grow(-WALL_GAP)
	var best := Rect2()
	var best_d := INF
	var centre := from.get_center()
	for size: Vector2 in [from.size, Vector2(from.size.y, from.size.x)]:
		if best.has_area():
			break
		if size.x > inner.size.x + EPS or size.y > inner.size.y + EPS:
			continue
		var spots: Array[Vector2] = []
		var nx := floori((inner.size.x - size.x) / SLIDE + 0.001)
		var nz := floori((inner.size.y - size.y) / SLIDE + 0.001)
		for i in nx + 1:
			var x := inner.position.x + float(i) * SLIDE
			spots.append(Vector2(x, inner.position.y))
			spots.append(Vector2(x, inner.end.y - size.y))
		for j in nz + 1:
			var z := inner.position.y + float(j) * SLIDE
			spots.append(Vector2(inner.position.x, z))
			spots.append(Vector2(inner.end.x - size.x, z))
		for p: Vector2 in spots:
			var r := Rect2(p, size)
			var dist := (r.get_center() - centre).length_squared()
			if dist >= best_d - 0.000001:
				continue
			if _meets_any(r, keep_out) or _meets_any(r, placed) or meets_leaf(r, leaf):
				continue
			best = r
			best_d = dist
	return best
