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
		"door": {"x": door_x, "w": float(door_spec.w)}, "storeys": []}
	for raw_storey: Dictionary in _variant_storeys(t, v):
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
		var furniture := []
		for piece: Dictionary in raw_storey.get("furniture", []):
			var spots: Array = piece.at
			var r: Array = spots[rng.randi_range(0, spots.size() - 1)]
			var x0: float = mx.call(float(r[0]))
			var x1: float = mx.call(float(r[2]))
			furniture.append({"kind": StringName(piece.kind), "room": StringName(piece.room), "h": float(piece.h),
				"hide": StringName(piece.get("hide", "")),
				"rect": Rect2(minf(x0, x1), float(r[1]), absf(x1 - x0), float(r[3]) - float(r[1]))})
		var stair := {}
		if raw_storey.has("stair"):
			var s: Dictionary = raw_storey.stair
			stair = {"axis": StringName(s.axis), "lane": float(s.lane), "from": float(s.from), "to": float(s.to)}
			if stair.axis == &"x":
				stair.from = mx.call(float(s.from))
				stair.to = mx.call(float(s.to))
			else:
				stair.lane = mx.call(float(s.lane))
		(out.storeys as Array).append({"rooms": rooms, "doors": doors, "windows": windows, "furniture": furniture, "stair": stair})
	return out
