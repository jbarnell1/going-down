# WH3: the Hanging Ward's homes dressed with real furniture (stage 2 of the homes; the run flag ward_homes). The owner
# approved the homes' defaults on 21 Nov ("Good with these defaults."): soot-stained brick staff housing, lived in and
# left, with eight modelled pieces (the range, the kitchen table, the dresser, the iron bed, the claw-foot bath, the
# long-case clock, the wash copper with its mangle, and a pram). This file only draws; no rule reads it.
#   - Every piece of furniture the rules place (sim/ward/house.gd furniture, solid to walkers and the arm) is drawn
#     inside its own rules box: one of the modelled pieces fitted to the box where there is one (assets_src/blender/
#     ward/build_ward_meshy.py made them small), else a piece built of textured boxes (a hearth, an armchair, coat
#     hooks, a stone sink, a chest of drawers, a shelf of tins, a toilet, lockers ...). A hide's piece (a bed, a table,
#     a bath) is drawn under its hide node (client/ward/view.gd _hide_piece), so the camera inside sees out of it.
#   - Besides, a few things that are not solid, so they change no rule: pictures and a crockery shelf high on the
#     walls, rugs flat on the floor, and a pram stood against a hall wall. They keep out of every doorway's clear
#     approach (sim/ward/homes.gd approaches), the front door's leaf, the stairs, the windows, every piece of furniture,
#     every hide and the space in front of it (tests/prop_ward_homes_dress.gd also checks the arm's routes).
# All of it comes from the house's plan and one random stream of its own, "ward_homes_dress:<floor seed>:<house id>",
# which no rule draws from: the same on every screen, and the floor's own streams are untouched.
extends RefCounted

const House = preload("res://sim/ward/house.gd")
const Homes = preload("res://sim/ward/homes.gd")
const Hides = preload("res://sim/hides.gd")
const HidesView = preload("res://client/ward/hides_view.gd")
const WardSkin = preload("res://client/ward/skin.gd")

const DIR := "res://assets/ward/homes/"
## The modelled pieces: [file, size as built (x along its front, y up, z front to back; tests check the files agree),
## how it is fitted]. The front of every model faces +z. "fit": scaled alike on every axis to fit the box, each axis
## then allowed `stretch` times further towards the box; "fill": scaled to fill the box's floor, `top` metres tall.
const MODELS := {
	&"range": ["range.glb", Vector3(1.633, 1.902, 1.124), "fit"],
	&"table": ["table.glb", Vector3(1.903, 0.73, 0.921), "fill"],
	&"dresser": ["dresser.glb", Vector3(1.185, 1.903, 0.527), "fit"],
	&"bed": ["bed.glb", Vector3(1.178, 1.292, 1.908), "fill"],
	&"bath": ["bath.glb", Vector3(1.894, 0.863, 0.91), "fill"],
	&"clock": ["clock.glb", Vector3(0.646, 1.905, 0.458), "fit"],
	&"copper": ["copper.glb", Vector3(0.881, 1.161, 0.893), "fit"],
	&"mangle": ["mangle.glb", Vector3(1.016, 1.581, 0.606), "fit"],
	&"pram": ["pram.glb", Vector3(1.895, 1.883, 0.915), "fit"],
}
## Which model draws each kind of furniture, and how: [model, top (fill: metres; fit: the most it may stand above its
## box's floor), stretch (fit), long axis of the model (fill: &"x" or &"z", laid along the box's longer side)].
## The bed's head and foot rails rise above its rules box (0.55 m, the mattress); the range's flue above its top, but
## not into the arm's path through a room (sim/ward/house.gd ARM_HEIGHT less sim/ward/arm.gd PALM_RADIUS, 1.07 m).
const DRAWN_BY := {
	&"range": [&"range", 1.0, 1.2, &""],
	&"stove": [&"range", 0.95, 1.2, &""],
	&"table": [&"table", 0.0, 0.0, &"x"],
	&"long_table": [&"table", 0.0, 0.0, &"x"],
	&"dresser": [&"dresser", 2.0, 1.2, &""],
	&"bed": [&"bed", 0.95, 0.0, &"z"],
	&"bath": [&"bath", 0.6, 0.0, &"x"],
	&"clock": [&"clock", 2.0, 1.6, &""],
	&"copper": [&"copper", 1.15, 1.2, &""],
	&"mangle": [&"mangle", 1.3, 1.2, &""],
}
## A pram stands this tall (metres), against a hall wall: below the arm's path through a room (sim/ward/house.gd
## ARM_HEIGHT less the palm, sim/ward/arm.gd PALM_RADIUS).
const PRAM_TOP := 1.0
## The colour maps of the modelled pieces are darker than the Ward's photographs; drawn this much brighter.
const MODEL_GAIN := 1.15
## Inside pieces are not drawn from farther than this (metres; the homes design's frame-rate budget).
const FAR := 25.0
## The group every node this file adds is in.
const GROUP := &"ward_homes_dress"

## Wall things: pictures hang with their bottom at least this high (above the arm's path through a room, and above a
## walker's shoulders); the crockery shelf at this height.
const PICTURE_LOW := 1.5
const SHELF_Y := 1.98
## Floor things keep this far off every piece of furniture and every wall they are not stood against.
const GAP := 0.05
## A hide's view is kept clear of anything extra this far out from its eyes (metres).
const VIEW_REACH := 2.0
## Room kinds that get a rug, a crockery shelf, a pram.
const RUG_ROOMS := [&"parlour", &"bedroom", &"dining", &"bedsit", &"hall", &"landing"]
const SHELF_ROOMS := [&"kitchen"]
const PRAM_ROOMS := [&"hall"]
## How many places a thing is tried at before the room goes without it.
const TRIES := 40

static var _mesh_cache := {}

# ------------------------------------------------------------------------------------------------
# The plan: what stands where, from the house and its own stream. No node is made here.

## Every dressed thing of a home (house.gd with the homes): [{"kind", "what" (&"model" | &"built" | &"extra"),
## "piece" (index in fixture.furniture, or -1), "level", "room", "box" (AABB, local: where it is drawn), "yaw"
## (its front faces (sin yaw, 0, cos yaw)), and for a model "model", "at" (local: its base's middle), "scale"}].
## [] for a house without the homes.
static func plan(fixture: House, seed_value: int, house_id: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not fixture.homes():
		return out
	var rng := RandomNumberGenerator.new()
	rng.seed = ("ward_homes_dress:%d:%d" % [seed_value, house_id]).hash()
	for i in fixture.furniture.size():
		out.append(_piece(fixture, i))
	for level in fixture.rooms_by_level.size():
		var keep := keep_out(fixture, level)
		var placed: Array[AABB] = []
		for room: Dictionary in fixture.rooms_by_level[level]:
			_extras(fixture, level, room, keep, placed, rng, out)
	return out

## Whether a row is a hide's piece, drawn under its hide's node (client/ward/view.gd _hide_piece) rather than by build():
## a bed, table or bath as its model, a wardrobe hollow with the crack in its doors.
static func in_hide(row: Dictionary) -> bool:
	return int(row.piece) >= 0 and Hides.WARD_SPEC.has(StringName(row.get("hide", "")))

## One piece of furniture, drawn inside its rules box. A hide's model is turned (of the ways its box allows) so that
## the camera inside it sees out of its open side (a bath's tap end, a bed's hanging sheet away from it).
static func _piece(fixture: House, i: int) -> Dictionary:
	var piece: Dictionary = fixture.furniture[i]
	var box: AABB = piece.box
	var kind := StringName(piece.kind)
	var room := _room_rect(fixture, int(piece.level), StringName(piece.room))
	var row := {"kind": kind, "piece": i, "level": int(piece.level), "room": StringName(piece.room),
		"hide": StringName(piece.get("hide", "")), "box": box}
	if DRAWN_BY.has(kind):
		var how: Array = DRAWN_BY[kind]
		var yaws := _facings(box, room, StringName(how[3]), kind == &"bed")
		var fitted := _fit(row, box, how, yaws[0])
		if Hides.WARD_SPEC.has(StringName(row.hide)):
			var hide := 0
			for j in i:
				if Hides.WARD_SPEC.has(StringName(fixture.furniture[j].get("hide", ""))):
					hide += 1
			for yaw: float in yaws:
				var maybe := _fit(row, box, how, yaw)
				if view_clear(fixture, hide, model_faces(maybe)):
					fitted = maybe
					break
		return fitted
	row.merge({"what": &"built", "yaw": _facings(box, room, &"", false)[0]})
	return row

## A modelled piece fitted to its box, facing `yaw`.
static func _fit(row: Dictionary, box: AABB, how: Array, yaw: float) -> Dictionary:
	var model := StringName(how[0])
	var spec: Array = MODELS[model]
	var size: Vector3 = spec[1]
	var along_x := is_zero_approx(sin(yaw))
	# The box's extent across the model's front (its x) and front to back (its z).
	var w := box.size.x if along_x else box.size.z
	var d := box.size.z if along_x else box.size.x
	var s := Vector3.ONE
	if spec[2] == "fill":
		s = Vector3(w / size.x, float(how[1]) / size.y if float(how[1]) > 0.0 else box.size.y / size.y, d / size.z)
	else:
		var top := float(how[1])
		var even := minf(minf(w / size.x, d / size.z), top / size.y)
		var most := even * float(how[2])
		s = Vector3(minf(w / size.x, most), minf(top / size.y, most), minf(d / size.z, most))
	# Its back against the box's back (the wall side), its middle across the box's middle.
	var front := Vector3(sin(yaw), 0.0, cos(yaw))
	var centre := box.get_center()
	var back_gap := (d - size.z * s.z) * 0.5
	var at := Vector3(centre.x, box.position.y, centre.z) - front * back_gap * (0.0 if spec[2] == "fill" else 1.0)
	var drawn := Vector3(size.x * s.x, size.y * s.y, size.z * s.z)
	var extent := Vector3(drawn.x if along_x else drawn.z, drawn.y, drawn.z if along_x else drawn.x)
	var out := row.duplicate()
	out.merge({"what": &"model", "model": model, "yaw": yaw, "at": at, "scale": s,
		"box": AABB(Vector3(at.x - extent.x * 0.5, at.y, at.z - extent.z * 0.5), extent)}, true)
	return out

## The ways a piece may face (yaws), nearest wall first: out of a room wall, into the room. `long` (&"x" or &"z") is the
## model's axis to lay along the box's longer side; `along` true faces along that side (a bed's foot), false across it.
static func _facings(box: AABB, room: Rect2, long: StringName, along: bool) -> Array[float]:
	var x_longer := box.size.x >= box.size.z
	# [facing (x, z), how far its back is from a wall of the room]
	var options := [
		[Vector2(1, 0), box.position.x - room.position.x],
		[Vector2(-1, 0), room.end.x - box.end.x],
		[Vector2(0, 1), box.position.z - room.position.y],
		[Vector2(0, -1), room.end.y - box.end.z],
	]
	var kept: Array = []
	for o: Array in options:
		var f: Vector2 = o[0]
		if long != &"":
			# The model's long axis (x or z) must lie along the box's longer side.
			var faces_x := f.x != 0.0
			var model_long_on_x := (long == &"x") != faces_x
			if model_long_on_x != x_longer:
				continue
			if along != (faces_x == x_longer):
				continue
		kept.append(o)
	# Nearest wall first; a stable order for ties (the list's own).
	var out: Array[float] = []
	while not kept.is_empty():
		var best := 0
		for k in kept.size():
			if float(kept[k][1]) < float(kept[best][1]) - 1e-6:
				best = k
		var f: Vector2 = kept[best][0]
		out.append(atan2(f.x, f.y))
		kept.remove_at(best)
	if out.is_empty():
		out.append(0.0)
	return out

## A model's triangles where its row puts them (local to its house).
static func model_faces(row: Dictionary) -> PackedVector3Array:
	var mesh: Mesh = model_mesh(StringName(row.model))[0]
	var xf := Transform3D(Basis(Vector3.UP, float(row.yaw)).scaled_local(row.scale), row.at)
	var out := mesh.get_faces()
	for n in out.size():
		out[n] = xf * out[n]
	return out

## Whether the camera in a hide (client/ward/hides_view.gd eye_local) sees out of its open side past `faces`: straight
## out, and half way to each limit of its view, as far as its eyes are in from that side and a quarter metre more.
static func view_clear(fixture: House, hide: int, faces: PackedVector3Array) -> bool:
	var kind := StringName(fixture.hides[hide].kind)
	var eye := HidesView.eye_local(fixture, hide)
	var d := HidesView.out_local(fixture, hide)
	var half := float(HidesView.VIEW_HALF[kind])
	var far := float(HidesView.INSET[kind]) + 0.25
	for a: float in [-half * 0.5, 0.0, half * 0.5]:
		var dir := d.rotated(Vector3.UP, deg_to_rad(a))
		if segment_hits(faces, eye, eye + dir * far / maxf(0.2, cos(deg_to_rad(a)))):
			return false
	return true

static func segment_hits(faces: PackedVector3Array, a: Vector3, b: Vector3) -> bool:
	var seg := AABB(a, Vector3.ZERO).expand(b).grow(0.01)
	for n in range(0, faces.size(), 3):
		var tri := AABB(faces[n], Vector3.ZERO).expand(faces[n + 1]).expand(faces[n + 2])
		if not tri.intersects(seg):
			continue
		if Geometry3D.segment_intersects_triangle(a, b, faces[n], faces[n + 1], faces[n + 2]) != null:
			return true
	return false

static func _room_rect(fixture: House, level: int, name: StringName) -> Rect2:
	for r: Dictionary in fixture.rooms_by_level[level]:
		if r.name == name:
			return r.rect
	return Rect2()

## Where nothing extra may stand on a storey, as boxes (local): each doorway's clear approach (both sides), the
## stairs' ends and shafts, the front door's approach and its leaf open and swinging, the lift's doorway, each window's
## front and every piece of furniture (the hides' views are kept clear by in_view).
static func keep_out(fixture: House, level: int) -> Array[AABB]:
	var base := float(level) * House.HEIGHT
	var top := base + House.HEIGHT
	var plan_storeys: Array = fixture.plan.storeys
	var storey: Dictionary = plan_storeys[level]
	var next: Dictionary = (plan_storeys[level + 1] as Dictionary).stair if level + 1 < plan_storeys.size() else {}
	var bounds := Rect2(fixture.floor_bounds.position.x, 0.0, fixture.floor_bounds.size.x, fixture.floor_bounds.size.y)
	var flat: Array[Rect2] = Homes.approaches(storey.doors, storey.stair, next, bounds)
	for st: Dictionary in [storey.stair, next]:
		if not st.is_empty():
			flat.append(Homes.shaft(st))
	for win: Dictionary in storey.windows:
		flat.append(Homes._window_front(win, bounds))
	if level == 0:
		var door_x := float(fixture.plan.door.x)
		var door_w := float(fixture.plan.door.w)
		flat.append(Rect2(door_x - door_w * 0.5, 0.0, door_w, Homes.APPROACH + Homes.WALL))
		var leaf := Homes.front_leaf(door_x, door_w, int(fixture.plan.door.hinge))
		flat.append(leaf.rest)
		var length := float(leaf.length)
		var hinge: Vector2 = leaf.hinge
		flat.append(Rect2(hinge.x if int(leaf.side) < 0 else hinge.x - length, 0.0, length, length))
		if fixture.plan.type == "parlour":
			flat.append(Rect2(bounds.position.x, bounds.size.y * 0.5 - Homes.LIFT_GATE * 0.5 - 0.1, Homes.APPROACH, Homes.LIFT_GATE + 0.2))
	var out: Array[AABB] = []
	for r in flat:
		if r.has_area():
			out.append(AABB(Vector3(r.position.x, base, r.position.y), Vector3(r.size.x, top - base, r.size.y)))
	for piece: Dictionary in fixture.furniture:
		if int(piece.level) == level:
			out.append((piece.box as AABB).grow(GAP))
	return out

## The hides of a storey as their views: [eye (local), out (local), half the view's width in degrees].
static func views(fixture: House, level: int) -> Array:
	var out := []
	for k in fixture.hides.size():
		if int(fixture.hides[k].level) == level:
			out.append([HidesView.eye_local(fixture, k), HidesView.out_local(fixture, k), float(HidesView.VIEW_HALF[StringName(fixture.hides[k].kind)])])
	return out

## Whether a box stands across a hide's view: any ray from its eyes out of its open side, every 10 degrees within its
## limits, level and turned up or down as far as the view turns, VIEW_REACH long.
static func in_view(box: AABB, views_: Array) -> bool:
	for v: Array in views_:
		var eye: Vector3 = v[0]
		var d: Vector3 = v[1]
		var half: float = v[2]
		var a := -half
		while a <= half + 0.01:
			var ray := d.rotated(Vector3.UP, deg_to_rad(a))
			for pitch: float in [-HidesView.PITCH, 0.0, HidesView.PITCH]:
				var dir := (ray * cos(pitch) + Vector3.UP * sin(pitch)).normalized()
				if box.intersects_segment(eye, eye + dir * VIEW_REACH) != null:
					return true
			a += 10.0
	return false

## Every wall of the house as boxes (local), the rules' own (window holes are not cut in them).
static func _walls(fixture: House) -> Array[AABB]:
	var out: Array[AABB] = fixture.walls.duplicate()
	out.append_array(fixture.upper_envelope)
	for storey: House.Storey in fixture.storeys:
		out.append_array(storey.partitions)
	return out

static func _in_any(p: Vector3, boxes: Array[AABB]) -> bool:
	for b in boxes:
		if b.has_point(p):
			return true
	return false

## Whether a box meets any in a list (by more than a hair).
static func meets_any(box: AABB, list: Array[AABB]) -> bool:
	var a := box.grow(-0.002)
	for b in list:
		if a.intersects(b):
			return true
	return false

## Pictures, a crockery shelf, a rug and a pram for one room, where they keep out of `keep` and of each other.
static func _extras(fixture: House, level: int, room: Dictionary, keep: Array[AABB], placed: Array[AABB],
		rng: RandomNumberGenerator, out: Array[Dictionary]) -> void:
	var r: Rect2 = room.rect
	var kind := StringName(room.kind)
	var name := StringName(room.name)
	var base := float(level) * House.HEIGHT
	var walls := _walls(fixture)
	var seen := views(fixture, level)
	var holes: Array[AABB] = []
	for o: Dictionary in fixture.openings():
		if (o.hole as AABB).has_volume():
			holes.append((o.hole as AABB).grow(0.08))
	# The lift's doorway in the parlour cottage's left wall.
	if fixture.plan.type == "parlour" and level == 0:
		var mid := fixture.floor_bounds.size.y * 0.5
		holes.append(AABB(Vector3(fixture.floor_bounds.position.x - 0.5, 0.0, mid - Homes.LIFT_GATE * 0.5 - 0.1), Vector3(1.0, House.HEIGHT, Homes.LIFT_GATE + 0.2)))
	# Pictures: one, or two in a room of more than 9 square metres.
	var pictures := 1 + (1 if r.get_area() > 9.0 and rng.randf() < 0.7 else 0)
	for n in pictures:
		var w := rng.randf_range(0.32, 0.6)
		var h := rng.randf_range(0.28, 0.5)
		var y := base + PICTURE_LOW + rng.randf_range(0.0, 0.3)
		var spot := _wall_spot(fixture, level, r, w, h, 0.035, y, walls, holes, keep, placed, seen, rng)
		if not spot.is_empty():
			spot.merge({"kind": &"picture", "what": &"extra", "piece": -1, "level": level, "room": name,
				"tone": rng.randi_range(0, 3)})
			placed.append(spot.box)
			out.append(spot)
	# A shelf of crockery high on a kitchen wall.
	if SHELF_ROOMS.has(kind):
		var w := rng.randf_range(0.8, 1.2)
		var spot := _wall_spot(fixture, level, r, w, 0.36, 0.2, base + SHELF_Y - 0.12, walls, holes, keep, placed, seen, rng)
		if not spot.is_empty():
			spot.merge({"kind": &"crockery", "what": &"extra", "piece": -1, "level": level, "room": name})
			placed.append(spot.box)
			out.append(spot)
	# A rug on the floor, or a runner in a hall or on a landing.
	if RUG_ROOMS.has(kind):
		var runner := kind == &"hall" or kind == &"landing"
		for t in TRIES:
			var a := rng.randf_range(1.2, 2.2) if not runner else rng.randf_range(1.6, 2.8)
			var b := rng.randf_range(0.8, 1.4) if not runner else rng.randf_range(0.6, 0.75)
			var turned := rng.randf() < 0.5
			var size := Vector3(b if turned else a, 0.012, a if turned else b)
			var inner := r.grow(-0.25)
			if size.x > inner.size.x or size.z > inner.size.y:
				continue
			var p := Vector3(rng.randf_range(inner.position.x, inner.end.x - size.x), base, rng.randf_range(inner.position.y, inner.end.y - size.z))
			var box := AABB(p, size)
			if meets_any(box, keep) or meets_any(box, placed) or in_view(box, seen):
				continue
			out.append({"kind": &"rug", "what": &"extra", "piece": -1, "level": level, "room": name, "box": box,
				"yaw": 0.0, "tone": rng.randi_range(0, 2)})
			placed.append(box)
			break
	# A pram left against a hall wall, one a house.
	if PRAM_ROOMS.has(kind) and level == 0:
		var spec: Array = MODELS[&"pram"]
		var size: Vector3 = spec[1]
		var s := PRAM_TOP / size.y
		for t in TRIES:
			var side := rng.randi_range(0, 3)
			var turned := side >= 2
			var along := size.x * s
			var deep := size.z * s
			var ext := Vector3(deep if not turned else along, PRAM_TOP, along if not turned else deep)
			var inner := r.grow(-(Homes.WALL * 0.5 + GAP))
			if ext.x > inner.size.x or ext.z > inner.size.y:
				continue
			var p := Vector3(rng.randf_range(inner.position.x, inner.end.x - ext.x), base, rng.randf_range(inner.position.y, inner.end.y - ext.z))
			# Against the wall its side picks: 0 low x, 1 high x, 2 low z, 3 high z.
			match side:
				0: p.x = inner.position.x
				1: p.x = inner.end.x - ext.x
				2: p.z = inner.position.y
				3: p.z = inner.end.y - ext.z
			var box := AABB(p, ext)
			if meets_any(box, keep) or meets_any(box, placed) or in_view(box, seen):
				continue
			var front := [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)][side] as Vector2
			# Its long side to the wall, its front (model +z) into the room.
			var yaw := atan2(front.x, front.y)
			out.append({"kind": &"pram", "what": &"model", "model": &"pram", "piece": -1, "level": level, "room": name,
				"box": box, "yaw": yaw, "at": Vector3(box.get_center().x, base, box.get_center().z), "scale": Vector3.ONE * s})
			placed.append(box)
			break

## A place on a wall of the room for a flat thing `w` wide, `h` tall and `deep` off the wall, its bottom at `y`:
## {"box", "yaw" (facing into the room), "wall_at" (local: its back's middle)}; {} if none of TRIES places is clear.
## Clear: the wall is solid behind the whole of it (no doorway, window or the lift's doorway), and it meets nothing in
## `keep` or `placed`.
static func _wall_spot(fixture: House, level: int, r: Rect2, w: float, h: float, deep: float, y: float,
		walls: Array[AABB], holes: Array[AABB], keep: Array[AABB], placed: Array[AABB], seen: Array, rng: RandomNumberGenerator) -> Dictionary:
	for t in TRIES:
		var side := rng.randi_range(0, 3)
		var into: Vector3 = [Vector3.RIGHT, Vector3.LEFT, Vector3.BACK, Vector3.FORWARD][side]
		var length := r.size.y if side < 2 else r.size.x
		if length < w + 0.4:
			continue
		var along := rng.randf_range(0.2 + w * 0.5, length - 0.2 - w * 0.5)
		var edge := Vector3(r.position.x if side == 0 else r.end.x, y, r.position.y + along) if side < 2 \
			else Vector3(r.position.x + along, y, r.position.y if side == 2 else r.end.y)
		# The wall's face: step into the room from inside the wall until out of it.
		var face := edge - into * 0.2
		var steps := 0
		while _in_any(face + Vector3.UP * h * 0.5, walls) == false and steps < 40:
			face += into * 0.01
			steps += 1
		while _in_any(face + Vector3.UP * h * 0.5, walls) and steps < 80:
			face += into * 0.01
			steps += 1
		if steps >= 80 or (face - edge).dot(into) > 0.2:
			continue
		var across := Vector3(-into.z, 0.0, into.x)
		var solid := true
		for u: float in [-0.5, 0.0, 0.5]:
			for v: float in [0.05, 0.95]:
				if not _in_any(face - into * 0.03 + across * (u * w) + Vector3.UP * (v * h), walls):
					solid = false
		if not solid:
			continue
		var c := face + into * deep * 0.5 + Vector3.UP * h * 0.5
		var ext := Vector3(absf(across.x) * w + absf(into.x) * deep, h, absf(across.z) * w + absf(into.z) * deep)
		var box := AABB(c - ext * 0.5, ext)
		if meets_any(box, holes) or meets_any(box, keep) or meets_any(box, placed) or in_view(box, seen):
			continue
		return {"box": box, "yaw": atan2(into.x, into.z), "wall_at": face}
	return {}

# ------------------------------------------------------------------------------------------------
# Drawing.

## A modelled piece's mesh and material, loaded once: [ArrayMesh, Material].
static func model_mesh(model: StringName) -> Array:
	if _mesh_cache.has(model):
		return _mesh_cache[model]
	var scene: PackedScene = load(DIR + str((MODELS[model] as Array)[0]))
	var root := scene.instantiate()
	var found: Array = [null, null]
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mi := n as MeshInstance3D
			found[0] = mi.mesh
			var m := mi.get_active_material(0)
			if m is BaseMaterial3D:
				var lit := (m as BaseMaterial3D).duplicate() as BaseMaterial3D
				lit.albedo_color = Color(MODEL_GAIN, MODEL_GAIN, MODEL_GAIN)
				found[1] = lit
			break
		stack.append_array(n.get_children())
	root.free()
	_mesh_cache[model] = found
	return found

## A modelled thing's node under `parent` (a house's root or a hide's node), placed as its plan row says.
static func add_model(parent: Node3D, row: Dictionary) -> MeshInstance3D:
	var found := model_mesh(StringName(row.model))
	var mi := MeshInstance3D.new()
	mi.name = "Model_%s" % str(row.kind)
	mi.mesh = found[0]
	if found[1] != null:
		mi.material_override = found[1]
	mi.transform = Transform3D(Basis(Vector3.UP, float(row.yaw)).scaled_local(row.scale), row.at)
	mi.visibility_range_end = FAR
	mi.add_to_group(GROUP)
	parent.add_child(mi)
	return mi

## Everything of a home's plan but the pieces drawn in their hides, under the house's root. `colors` are the Ward's
## materials (client/ward/view.gd colors, client/ward/skin.gd materials).
static func build(root: Node3D, rows: Array[Dictionary], colors: Dictionary, seed_value: int, house_id: int) -> Node3D:
	var node := Node3D.new()
	node.name = "HomeDress"
	node.add_to_group(GROUP)
	root.add_child(node)
	var mats := _materials(colors)
	for row: Dictionary in rows:
		if in_hide(row):
			continue
		if row.what == &"model":
			add_model(node, row)
		elif row.what == &"built":
			_built(node, row, mats, seed_value, house_id)
		else:
			_extra(node, row, mats)
	return node

## The materials the built pieces use: the Ward's own (client/ward/skin.gd materials), and a few more made from the same
## photographs: linen, stone, soot, worn upholstery (the wallpaper photograph, darkened) and a dark coat.
static func _materials(colors: Dictionary) -> Dictionary:
	var out := colors.duplicate()
	if _extra_mats.is_empty():
		_extra_mats = {
			"linen": WardSkin._tri("plaster.webp", WardSkin.PLASTER_TILE, Color(0.95, 0.92, 0.84)),
			"stone": WardSkin._tri("plaster.webp", WardSkin.PLASTER_TILE, Color(0.6, 0.58, 0.54)),
			"soot": WardSkin._tri("rock.webp", 1.0, Color(0.16, 0.14, 0.13), 1.0),
			"fabric": WardSkin._tri("paper.webp", 0.7, Color(0.55, 0.26, 0.22)),
			"fabric_b": WardSkin._tri("paper.webp", 0.7, Color(0.3, 0.34, 0.27)),
			"fabric_c": WardSkin._tri("paper.webp", 0.7, Color(0.42, 0.34, 0.45)),
			"coat": WardSkin._tri("planks.webp", 0.6, Color(0.24, 0.22, 0.21), 1.0),
		}
	out.merge(_extra_mats)
	return out

static var _extra_mats := {}

## One box of a built piece, in the piece's frame: x along its wall (centred), y up from its floor, z out from its back.
static func _part(node: Node3D, mats: Dictionary, key: String, lo: Vector3, hi: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = (hi - lo).abs()
	mi.mesh = mesh
	mi.material_override = mats.get(key)
	mi.position = (lo + hi) * 0.5
	mi.visibility_range_end = FAR
	node.add_child(mi)

## A piece built of boxes inside its rules box, facing its room.
static func _built(parent: Node3D, row: Dictionary, mats: Dictionary, seed_value: int, house_id: int) -> void:
	var box: AABB = row.box
	var yaw := float(row.yaw)
	var along_x := is_zero_approx(sin(yaw))
	var w := box.size.x if along_x else box.size.z
	var d := box.size.z if along_x else box.size.x
	var h := box.size.y
	var front := Vector3(sin(yaw), 0.0, cos(yaw))
	var node := Node3D.new()
	node.name = "Built_%s" % str(row.kind)
	parent.add_child(node)
	# The piece's frame: origin at the middle of its back, on its floor.
	var back := box.get_center() - front * d * 0.5
	node.transform = Transform3D(Basis(Vector3.UP, yaw), Vector3(back.x, box.position.y, back.z))
	# A few things vary by the piece (which coat hangs, what stands on a shelf): the same on every screen.
	var vary := ("%d:%d:%d" % [seed_value, house_id, int(row.piece)]).hash()
	var hw := w * 0.5
	var p := func(key: String, lo: Vector3, hi: Vector3) -> void:
		_part(node, mats, key, lo, hi)
	match StringName(row.kind):
		&"hearth":
			p.call("stone", Vector3(-hw, 0, 0), Vector3(hw, 0.04, d))
			p.call("brick", Vector3(-hw, 0, 0), Vector3(-hw + 0.16, h - 0.08, d * 0.75))
			p.call("brick", Vector3(hw - 0.16, 0, 0), Vector3(hw, h - 0.08, d * 0.75))
			p.call("brick", Vector3(-hw, h - 0.34, 0), Vector3(hw, h - 0.08, d * 0.75))
			p.call("soot", Vector3(-hw + 0.16, 0.04, 0), Vector3(hw - 0.16, h - 0.34, 0.06))
			p.call("iron", Vector3(-hw + 0.24, 0.04, 0.1), Vector3(hw - 0.24, 0.36, d * 0.6))
			p.call("trim", Vector3(-hw, h - 0.08, 0), Vector3(hw, h, d))
		&"armchair":
			p.call("trim", Vector3(-hw + 0.04, 0, 0.06), Vector3(hw - 0.04, 0.12, d - 0.06))
			p.call("fabric", Vector3(-hw + 0.06, 0.12, 0.06), Vector3(hw - 0.06, 0.42, d - 0.04))
			p.call("fabric", Vector3(-hw + 0.06, 0.12, 0.02), Vector3(hw - 0.06, h, 0.2))
			p.call("fabric", Vector3(-hw + 0.02, 0.12, 0.06), Vector3(-hw + 0.14, 0.62, d - 0.02))
			p.call("fabric", Vector3(hw - 0.14, 0.12, 0.06), Vector3(hw - 0.02, 0.62, d - 0.02))
		&"hooks":
			p.call("trim", Vector3(-hw, 1.6, 0), Vector3(hw, 1.72, 0.03))
			var coats := 2 + vary % 2
			for k in coats:
				var x := lerpf(-hw + 0.25, hw - 0.25, (float(k) + 0.5) / float(coats))
				p.call("brass", Vector3(x - 0.015, 1.62, 0.03), Vector3(x + 0.015, 1.66, 0.09))
				var long := 0.85 + 0.15 * float((vary >> k) % 2)
				p.call("coat", Vector3(x - 0.17, 1.64 - long, 0.03), Vector3(x + 0.17, 1.64, minf(d, 0.2)))
			p.call("iron", Vector3(-hw + 0.1, 0, 0.02), Vector3(-hw + 0.38, 0.14, minf(d, 0.26)))
		&"sink":
			p.call("brick", Vector3(-hw + 0.02, 0, 0.04), Vector3(-hw + 0.14, h - 0.2, d - 0.06))
			p.call("brick", Vector3(hw - 0.14, 0, 0.04), Vector3(hw - 0.02, h - 0.2, d - 0.06))
			p.call("stone", Vector3(-hw, h - 0.2, 0), Vector3(hw, h - 0.17, d))
			p.call("stone", Vector3(-hw, h - 0.17, 0), Vector3(-hw + 0.05, h, d))
			p.call("stone", Vector3(hw - 0.05, h - 0.17, 0), Vector3(hw, h, d))
			p.call("stone", Vector3(-hw, h - 0.17, d - 0.05), Vector3(hw, h, d))
			p.call("stone", Vector3(-hw, h - 0.17, 0), Vector3(hw, h, 0.05))
			p.call("brass", Vector3(-0.02, h - 0.17, 0.0), Vector3(0.02, h + 0.1, 0.05))
		&"drawers", &"sideboard", &"cabinet":
			p.call("trim", Vector3(-hw, 0, 0), Vector3(hw, 0.08, d - 0.02))
			p.call("panel", Vector3(-hw, 0.08, 0), Vector3(hw, h - 0.04, d - 0.04))
			p.call("trim", Vector3(-hw - 0.0, h - 0.04, 0), Vector3(hw, h, d))
			if row.kind == &"drawers":
				var rows := 3 if h < 1.0 else 4
				var step := (h - 0.16) / float(rows)
				for k in rows:
					var y0 := 0.1 + float(k) * step
					p.call("door", Vector3(-hw + 0.04, y0, d - 0.04), Vector3(hw - 0.04, y0 + step - 0.03, d - 0.02))
					p.call("brass", Vector3(-0.04, y0 + step * 0.45, d - 0.02), Vector3(0.04, y0 + step * 0.45 + 0.03, d))
			else:
				var doors := 2 if w < 1.1 else 3
				for k in doors:
					var x0 := -hw + 0.04 + float(k) * (w - 0.08) / float(doors)
					var x1 := x0 + (w - 0.08) / float(doors) - 0.03
					p.call("door", Vector3(x0, 0.12, d - 0.02), Vector3(x1, h - 0.1, d))
		&"shelf":
			p.call("trim", Vector3(-hw, 0, 0), Vector3(-hw + 0.04, h, d))
			p.call("trim", Vector3(hw - 0.04, 0, 0), Vector3(hw, h, d))
			p.call("timber", Vector3(-hw, 0, 0), Vector3(hw, h, 0.02))
			var boards := 3 if h < 1.4 else 4
			for k in boards:
				var y := 0.06 + float(k) * (h - 0.1) / float(boards - 1) - (0.03 if k == boards - 1 else 0.0)
				p.call("timber", Vector3(-hw + 0.04, y, 0.02), Vector3(hw - 0.04, y + 0.03, d))
				var things := 2 + (vary >> (k * 2)) % 3
				for j in things:
					var x := lerpf(-hw + 0.12, hw - 0.12, (float(j) + 0.5) / float(things))
					var tall := 0.1 + 0.05 * float((vary >> (k + j)) % 3)
					var key := ["iron", "brass", "stone", "panel"][(vary >> (j + k * 3)) % 4] as String
					if y + 0.03 + tall < h:
						p.call(key, Vector3(x - 0.05, y + 0.03, 0.06), Vector3(x + 0.05, y + 0.03 + tall, minf(d - 0.02, 0.18)))
		&"toilet":
			var cx := 0.0
			p.call("stone", Vector3(cx - 0.13, 0, 0.12), Vector3(cx + 0.13, 0.36, minf(d, 0.5) - 0.04))
			p.call("trim", Vector3(cx - 0.19, 0.36, 0.08), Vector3(cx + 0.19, 0.4, minf(d, 0.5)))
			p.call("iron", Vector3(cx - 0.2, 0.48, 0.0), Vector3(cx + 0.2, h, 0.17))
			p.call("iron", Vector3(cx - 0.02, 0.36, 0.08), Vector3(cx + 0.02, 0.48, 0.12))
		&"drying_rack":
			p.call("timber", Vector3(-hw, 0, 0), Vector3(-hw + 0.05, h, d))
			p.call("timber", Vector3(hw - 0.05, 0, 0), Vector3(hw, h, d))
			for z: float in [0.04, d - 0.04]:
				p.call("timber", Vector3(-hw, h - 0.06, z - 0.02), Vector3(hw, h - 0.02, z + 0.02))
				p.call("timber", Vector3(-hw, h * 0.5 - 0.02, z - 0.02), Vector3(hw, h * 0.5 + 0.02, z + 0.02))
			var sheets := 2 + vary % 2
			for k in sheets:
				var x0 := -hw + 0.08 + float(k) * (w - 0.16) / float(sheets)
				var x1 := x0 + (w - 0.16) / float(sheets) - 0.06
				var z := 0.04 if k % 2 == 0 else d - 0.04
				var drop := 0.6 + 0.3 * float((vary >> k) % 3) * 0.5
				p.call("linen", Vector3(x0, h - 0.06 - drop, z - 0.006), Vector3(x1, h - 0.04, z + 0.006))
		&"coal_bin":
			p.call("iron", Vector3(-hw, 0, 0), Vector3(hw, h, 0.04))
			p.call("iron", Vector3(-hw, 0, 0), Vector3(-hw + 0.04, h, d))
			p.call("iron", Vector3(hw - 0.04, 0, 0), Vector3(hw, h, d))
			p.call("iron", Vector3(-hw, 0, d - 0.04), Vector3(hw, h * 0.6, d))
			p.call("iron", Vector3(-hw, 0, 0), Vector3(hw, 0.04, d))
			p.call("rock", Vector3(-hw + 0.04, 0.04, 0.04), Vector3(hw - 0.04, h * 0.7, d - 0.04))
		&"desk":
			p.call("trim", Vector3(-hw, h - 0.05, 0), Vector3(hw, h, d))
			p.call("panel", Vector3(-hw + 0.02, 0, 0.02), Vector3(-hw + 0.4, h - 0.05, d - 0.02))
			for k in 3:
				var y0 := 0.06 + float(k) * (h - 0.13) / 3.0
				p.call("door", Vector3(-hw + 0.05, y0, d - 0.02), Vector3(-hw + 0.37, y0 + (h - 0.13) / 3.0 - 0.03, d))
			p.call("trim", Vector3(hw - 0.06, 0, d - 0.08), Vector3(hw - 0.02, h - 0.05, d - 0.04))
			p.call("trim", Vector3(hw - 0.06, 0, 0.04), Vector3(hw - 0.02, h - 0.05, 0.08))
			p.call("panel", Vector3(-0.15, h, d * 0.3), Vector3(0.15, h + 0.04, d * 0.3 + 0.22))
		&"lockers":
			var n := maxi(1, int(round(w / 0.42)))
			p.call("iron", Vector3(-hw, 0, 0), Vector3(hw, h, d - 0.03))
			for k in n:
				var x0 := -hw + float(k) * w / float(n) + 0.02
				var x1 := -hw + float(k + 1) * w / float(n) - 0.02
				p.call("cable", Vector3(x0, 0.08, d - 0.03), Vector3(x1, h - 0.06, d - 0.01))
				p.call("brass", Vector3(x1 - 0.06, h * 0.5, d - 0.01), Vector3(x1 - 0.03, h * 0.5 + 0.06, d))
		&"bench":
			p.call("timber", Vector3(-hw, h - 0.07, 0), Vector3(hw, h, d))
			for x: float in [-hw + 0.03, hw - 0.09]:
				for z: float in [0.03, d - 0.09]:
					p.call("trim", Vector3(x, 0, z), Vector3(x + 0.06, h - 0.07, z + 0.06))
			p.call("timber", Vector3(-hw + 0.03, 0.18, 0.03), Vector3(hw - 0.03, 0.21, d - 0.03))
			p.call("iron", Vector3(hw - 0.3, h - 0.2, d - 0.12), Vector3(hw - 0.08, h - 0.07, d))
		&"tool_wall":
			p.call("timber", Vector3(-hw, 0.8, 0), Vector3(hw, h, 0.03))
			var tools := 3 + vary % 3
			for k in tools:
				var x := lerpf(-hw + 0.15, hw - 0.15, (float(k) + 0.5) / float(tools))
				var long := 0.3 + 0.1 * float((vary >> k) % 4)
				p.call("iron", Vector3(x - 0.025, h - 0.15 - long, 0.03), Vector3(x + 0.025, h - 0.15, 0.06))
		&"under_stair":
			p.call("panel", Vector3(-hw, 0, 0), Vector3(hw, h, d))
		_:
			p.call("panel", Vector3(-hw, 0, 0), Vector3(hw, h, d))
	for child: Node in node.get_children():
		(child as Node3D).add_to_group(GROUP)

## A thing that is not furniture: a picture, a crockery shelf, a rug.
static func _extra(parent: Node3D, row: Dictionary, mats: Dictionary) -> void:
	var box: AABB = row.box
	var node := Node3D.new()
	node.name = "Extra_%s" % str(row.kind)
	parent.add_child(node)
	match StringName(row.kind):
		&"picture":
			var yaw := float(row.yaw)
			var into := Vector3(sin(yaw), 0.0, cos(yaw))
			var across := Vector3(-into.z, 0.0, into.x)
			var w := absf(box.size.x * across.x) + absf(box.size.z * across.z)
			node.transform = Transform3D(Basis(Vector3.UP, yaw), Vector3(box.get_center().x, box.position.y, box.get_center().z) - into * box.size.dot(into.abs()) * 0.5)
			var h := box.size.y
			_part(node, mats, "trim", Vector3(-w * 0.5, 0, 0), Vector3(w * 0.5, h, 0.03))
			var inside := ["fabric_b", "stone", "fabric_c", "soot"][int(row.get("tone", 0)) % 4] as String
			_part(node, mats, inside, Vector3(-w * 0.5 + 0.04, 0.04, 0.03), Vector3(w * 0.5 - 0.04, h - 0.04, 0.035))
		&"crockery":
			var yaw := float(row.yaw)
			var into := Vector3(sin(yaw), 0.0, cos(yaw))
			var across := Vector3(-into.z, 0.0, into.x)
			var w := absf(box.size.x * across.x) + absf(box.size.z * across.z)
			var deep := box.size.dot(into.abs())
			node.transform = Transform3D(Basis(Vector3.UP, yaw), Vector3(box.get_center().x, box.position.y, box.get_center().z) - into * deep * 0.5)
			_part(node, mats, "timber", Vector3(-w * 0.5, 0.12, 0), Vector3(w * 0.5, 0.15, deep))
			for x: float in [-w * 0.5 + 0.1, w * 0.5 - 0.1]:
				_part(node, mats, "trim", Vector3(x - 0.015, 0.0, 0), Vector3(x + 0.015, 0.12, deep * 0.8))
			var n := int(w / 0.14)
			for k in n:
				var x := -w * 0.5 + 0.08 + float(k) * (w - 0.16) / maxf(1.0, float(n - 1))
				if k % 3 == 2:
					_part(node, mats, "stone", Vector3(x - 0.04, 0.15, deep * 0.4), Vector3(x + 0.04, 0.24, deep * 0.4 + 0.08))
				else:
					_part(node, mats, "linen", Vector3(x - 0.09, 0.15, 0.02), Vector3(x + 0.09, 0.33, 0.04))
		&"rug":
			var key := ["fabric", "fabric_b", "fabric_c"][int(row.get("tone", 0)) % 3] as String
			_part(node, mats, key, box.position, box.end)
	for child: Node in node.get_children():
		(child as Node3D).add_to_group(GROUP)
