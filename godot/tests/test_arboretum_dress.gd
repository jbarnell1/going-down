# LA4: the Arboretum's landmarks drawn as things a player names, and the thicket's edges broken
# (client/arboretum_dress.gd). Looks only; on real gardens built as a client builds them (client/level.gd):
#   1. "Furniture is solid" (North Star A2/V33): for every landmark, nothing drawn below BODY_H lies more than REACH
#      outside its solid (a building's whole cell, a small landmark's piece; a hide shed's roof over its own piece),
#      and every solid has a body drawn over it (no invisible wall);
#   2. thicket is wall: the cards stay within REACH of their cell below BODY_H, and every open face of a thicket cell
#      stays shut (rays at it from the garden meet the thicket's own mass);
#   3. every hide's prompt spot, the line from it into the hide, and the view out of it are clear of what was added;
#   4. no light added and none changed; no new material; nothing drawn brighter than the old landmarks' stone;
#   5. one seed, the same shapes; 6. every kind the generator can place has its own shape, not a box.
extends RefCounted

const T = preload("res://tests/t.gd")
const Arboretum = preload("res://sim/arboretum.gd")
const ArbView = preload("res://client/arboretum_view.gd")
const Dress = preload("res://client/arboretum_dress.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const Run = preload("res://sim/run.gd")
const Furniture = preload("res://sim/furniture.gd")
const Hides = preload("res://sim/hides.gd")
const Seek = preload("res://sim/seek.gd")
const Floor = preload("res://sim/floor.gd")
const PlayLink = preload("res://client/play_link.gd")
const Playroom = preload("res://sim/playroom.gd")

const SEEDS: Array[String] = ["lk1", "alpha", "garden-1", "night", "seed-3", "la4-a", "la4-b", "la4-c"]
const QUICK_SEEDS := 4
const BODY_H := 2.2
const REACH := 0.15
## Slack for float rounding (m).
const EPS := 0.003
## What client/arboretum_dress.gd adds (the tags it sets round what it draws).
const ADDED: Array[String] = ["mark:", "shedroof:", "tcard:"]
## The brightest the old landmarks were drawn: their stone at 1.1 times C_STONE, on the stone material.
const OLD_BRIGHTEST := Color(0.605, 0.605, 0.572)

static var _cache := {}

## The garden of `seed_` as drawn, with the view's records grouped by tag: {plan, groups, lights, mats, view_lights}.
static func _drawn(seed_: String, off := false) -> Dictionary:
	var key := "%s/%s" % [seed_, off]
	if _cache.has(key):
		return _cache[key]
	var plan := Arboretum.generate_arboretum(seed_, 5)
	ArbView.recording = true
	Dress.off = off
	var level := Level.new()
	level.build(PlanDump.dump(plan, Run.car_geometry(plan)), plan.seed, plan)
	ArbView.recording = false
	Dress.off = false
	var view: Node = level.get_meta(&"arboretum")
	var groups := {}
	for r: Array in view.get(&"records"):
		var tag: String = r[0]
		if tag == "":
			continue
		if not groups.has(tag):
			groups[tag] = []
		(groups[tag] as Array).append(r)
	var lights: Array = []
	var stack: Array[Node] = [view]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		if n is Light3D:
			var l := n as Light3D
			lights.append([l.get_class(), l.position.snapped(Vector3.ONE * 0.001), l.light_color, snappedf(l.light_energy, 0.001),
				snappedf(float(l.get(&"omni_range")) if l is OmniLight3D else 0.0, 0.001), l.rotation.snapped(Vector3.ONE * 0.001)])
	var level_lights: Array = []
	for l: Light3D in level.main_lights:
		level_lights.append([l.get_class(), l.position.snapped(Vector3.ONE * 0.001), snappedf(l.light_energy, 0.001)])
	var all_mats: Dictionary = view.get(&"_mats")
	var mats: Array = all_mats.keys()
	mats.sort()
	# How bright each plain material draws a white vertex: its map's mean brightness times its own colour.
	var gain := {}
	for k: String in all_mats:
		var m := all_mats[k] as StandardMaterial3D
		if m == null:
			continue
		var mean := 1.0
		if m.albedo_texture != null:
			var img := m.albedo_texture.get_image()
			if img.is_compressed():
				img.decompress()
			img.convert(Image.FORMAT_RGBA8)
			img.resize(8, 8, Image.INTERPOLATE_BILINEAR)
			var sum := 0.0
			for y in 8:
				for x in 8:
					sum += _lum(img.get_pixel(x, y))
			mean = sum / 64.0
		gain[k] = mean * _lum(m.albedo_color)
	var out := {"plan": plan, "groups": groups, "lights": lights, "level_lights": level_lights, "mats": mats, "gain": gain}
	level.free()
	_cache[key] = out
	return out

static func _lum(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b

static func _seeds(t: T) -> Array[String]:
	return SEEDS.slice(0, QUICK_SEEDS) if t.quick else SEEDS

# --- geometry -----------------------------------------------------------------------------------------

## The part of a triangle at or below BODY_H.
static func _below(r: Array) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for i in 3:
		var p: Vector3 = r[2 + i]
		var q: Vector3 = r[2 + (i + 1) % 3]
		var pin := p.y <= BODY_H
		if pin:
			out.append(p)
		if pin != (q.y <= BODY_H):
			out.append(p.lerp(q, (BODY_H - p.y) / (q.y - p.y)))
	return out

## The height of a triangle over (x, z), or NAN when the point is not under it (or the triangle stands on edge).
static func _height_at(r: Array, x: float, z: float) -> float:
	var a: Vector3 = r[2]
	var b: Vector3 = r[3]
	var c: Vector3 = r[4]
	var d := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
	if absf(d) < 1e-6:
		return NAN
	var l1 := ((b.z - c.z) * (x - c.x) + (c.x - b.x) * (z - c.z)) / d
	var l2 := ((c.z - a.z) * (x - c.x) + (a.x - c.x) * (z - c.z)) / d
	var l3 := 1.0 - l1 - l2
	if l1 < -1e-4 or l2 < -1e-4 or l3 < -1e-4:
		return NAN
	return l1 * a.y + l2 * b.y + l3 * c.y

static func _in_xz(p: Vector3, rect: Rect2) -> bool:
	return p.x >= rect.position.x - EPS and p.x <= rect.end.x + EPS and p.z >= rect.position.y - EPS and p.z <= rect.end.y + EPS

## "" when nothing of `rows` below BODY_H lies more than REACH outside `rects` (in x, z), else the first offence.
static func _outside(rows: Array, rects: Array[Rect2]) -> String:
	for r: Array in rows:
		for p: Vector3 in _below(r):
			var ok := false
			for rect: Rect2 in rects:
				ok = ok or _in_xz(p, rect.grow(REACH))
			if not ok:
				return "%s drawn at %s, below %.1f m and %.2f m or more outside %s" % [r[1], p, BODY_H, REACH, rects]
	return ""

## The points of `rect` (inset 0.1 m, every 0.2 m) with nothing of `rows` over them between 0.03 and 2.6 m up.
static func _uncovered(rows: Array, rect: Rect2) -> Array[Vector2]:
	var flat: Array = []
	for r: Array in rows:
		var lo := minf((r[2] as Vector3).y, minf((r[3] as Vector3).y, (r[4] as Vector3).y))
		if lo <= 2.6:
			flat.append(r)
	var out: Array[Vector2] = []
	var x := rect.position.x + 0.1
	while x < rect.end.x - 0.05:
		var z := rect.position.y + 0.1
		while z < rect.end.y - 0.05:
			var covered := false
			for r: Array in flat:
				var y := _height_at(r, x, z)
				if not is_nan(y) and y >= 0.03 and y <= 2.6:
					covered = true
					break
			if not covered:
				out.append(Vector2(x, z))
			z += 0.2
		x += 0.2
	return out

static func _added(groups: Dictionary) -> Array:
	var out: Array = []
	for tag: String in groups:
		for prefix in ADDED:
			if tag.begins_with(prefix):
				out.append_array(groups[tag])
				break
	return out

## The nearest hit of a segment on `rows`, or -1.
static func _hit(rows: Array, from: Vector3, to: Vector3) -> float:
	var best := -1.0
	for r: Array in rows:
		var p: Variant = Geometry3D.segment_intersects_triangle(from, to, r[2], r[3], r[4])
		if p != null:
			var d := from.distance_to(p as Vector3)
			if best < 0.0 or d < best:
				best = d
	return best

static func _near(rows: Array, p: Vector3, reach: float) -> Array:
	var out: Array = []
	var box := AABB(p - Vector3.ONE * reach, Vector3.ONE * reach * 2.0)
	for r: Array in rows:
		var b := AABB(r[2], Vector3.ZERO).expand(r[3]).expand(r[4])
		if b.intersects(box):
			out.append(r)
	return out

# --- 1. the landmarks stand on their solids ------------------------------------------------------------

func test_landmarks_stand_on_their_solids(t: T) -> void:
	for seed_ in _seeds(t):
		var d := _drawn(seed_)
		var plan: Floor.FloorPlan = d["plan"]
		var groups: Dictionary = d["groups"]
		var g := Arboretum.garden_of(plan)
		var pieces := Furniture.pieces_for(plan)
		for l in g.landmarks:
			if l.id == 0:
				continue
			var tag := "mark:" + String(l.kind)
			var rows: Array = groups.get(tag, [])
			if not t.check(rows.size() > 0, "%s %s: drawn" % [seed_, l.kind]):
				continue
			var solid := Rect2()
			if l.building >= 0:
				solid = Rect2((l.building % Arboretum.W) * 2.0, (l.building / Arboretum.W) * 2.0, 2.0, 2.0)
			else:
				for p in pieces:
					if p.kind == l.kind:
						solid = Rect2(p.foot.position.x / 100.0, p.foot.position.y / 100.0, p.foot.size.x / 100.0, p.foot.size.y / 100.0)
			if not t.check(solid.size.x > 0.0, "%s %s: its solid is found" % [seed_, l.kind]):
				continue
			var bad := _outside(rows, [solid])
			t.check(bad == "", "%s %s: nothing below %.1f m more than %.2f m outside its solid: %s" % [seed_, l.kind, BODY_H, REACH, bad])
			var open := _uncovered(rows, solid)
			t.check(open.is_empty(), "%s %s: a body over all of its solid %s (open ground at %s)" % [seed_, l.kind, solid, open.slice(0, 4)])
		# The hide sheds' felt roofs keep over their own pieces.
		var roofs := 0
		for p in pieces:
			var rows: Array = groups.get("shedroof:%d" % p.id, [])
			if rows.is_empty():
				continue
			roofs += 1
			var foot := Rect2(p.foot.position.x / 100.0, p.foot.position.y / 100.0, p.foot.size.x / 100.0, p.foot.size.y / 100.0)
			var bad := _outside(rows, [foot])
			t.check(bad == "", "%s hide shed %d: its roof keeps over its piece: %s" % [seed_, p.id, bad])
		var sheds := pieces.filter(func(p: Furniture.Piece) -> bool: return p.kind == &"shed").size()
		t.eq(roofs, sheds, "%s: every hide shed has its felt roof" % seed_)

# --- 2. thicket is wall --------------------------------------------------------------------------------

func test_thicket_cards_keep_to_the_cell_and_its_faces_stay_shut(t: T) -> void:
	for seed_: String in _seeds(t).slice(0, 2):
		var d := _drawn(seed_)
		var plan: Floor.FloorPlan = d["plan"]
		var groups: Dictionary = d["groups"]
		var cells := 0
		var carded := 0
		var bad_cards: Array[String] = []
		var gaps: Array[String] = []
		for tag: String in groups:
			if not tag.begins_with("tbody:"):
				continue
			cells += 1
			var xy := tag.split(":")
			var x := int(xy[1])
			var y := int(xy[2])
			var cell := Rect2(x * 2.0, y * 2.0, 2.0, 2.0)
			var cards: Array = groups.get("tcard:%d:%d" % [x, y], [])
			if not cards.is_empty():
				carded += 1
				var bad := _outside(cards, [cell])
				if bad != "":
					bad_cards.append("(%d, %d) %s" % [x, y, bad])
			# Rays from the garden at each open face meet the thicket's own mass.
			var body: Array = groups[tag]
			var c := Vector3((x + 0.5) * 2.0, 0, (y + 0.5) * 2.0)
			for side in 4:
				var dv: Vector3 = Dress.SIDES[side]
				var nx := x + int(dv.x)
				var ny := y + int(dv.z)
				if nx < 0 or ny < 0 or nx >= Arboretum.W or ny >= Arboretum.H or Floor.cell_at(plan, 0, nx, ny) == Floor.VOID:
					continue
				var along := Vector3(-dv.z, 0, dv.x)
				# Straight through the cell, square to the face, from 0.4 m off each corner in.
				for s: float in [0.2, 0.35, 0.5, 0.65, 0.8]:
					for h: float in [0.3, 1.0, 1.6]:
						var from := c + dv * 1.3 + along * (s - 0.5) * 2.0 + Vector3.UP * h
						if _hit(body, from, from - dv * 2.6) < 0.0:
							gaps.append("(%d, %d) side %d at %.1f, %.1f m" % [x, y, side, s, h])
		t.check(cells > 50 and carded > 20, "%s: %d thicket cells drawn, %d with cards" % [seed_, cells, carded])
		t.check(bad_cards.is_empty(), "%s: thicket cards keep within %.2f m of their cell below %.1f m: %s" % [seed_, REACH, BODY_H, bad_cards.slice(0, 3)])
		t.check(gaps.is_empty(), "%s: no gap in a thicket face (%d): %s" % [seed_, gaps.size(), gaps.slice(0, 4)])

# --- 3. the hides ---------------------------------------------------------------------------------------

func test_hides_prompt_and_view_out_stay_clear(t: T) -> void:
	var kinds := {}
	for seed_: String in _seeds(t).slice(0, 3):
		var d := _drawn(seed_)
		var plan: Floor.FloorPlan = d["plan"]
		var added := _added(d["groups"] as Dictionary)
		for h in Hides.hides_for(plan):
			kinds[h.kind] = true
			var g := Vector3(float(Floor.dir_dx(h.gap)), 0, float(Floor.dir_dy(h.gap)))
			var right := Vector3.UP.cross(g).normalized()
			var ins := Seek.hide_inside_body(plan, h)
			var front := Vector3(h.front.x / 100.0, 0, h.front.y / 100.0)
			var near := _near(added, front, 3.5)
			var tag := "%s %s hide %d" % [seed_, h.kind, h.id]
			# The prompt spot: a body (0.3 m round) stands there clear of anything added below BODY_H.
			var crowd := ""
			for r: Array in near:
				for p: Vector3 in _below(r):
					if Vector2(p.x - front.x, p.z - front.z).length() < 0.3:
						crowd = "%s at %s" % [r[1], p]
			t.check(crowd == "", "%s: its prompt spot is clear (%s)" % [tag, crowd])
			var half := minf(deg_to_rad(float(h.gap_half)), PI * 0.75)
			for peek: bool in [false, true]:
				var e := PlayLink.eye_local(h.kind, h.eye, peek)
				var cam := Vector3(ins.x, ins.y, ins.z) + Vector3(0, e.y, 0) + g * e.z
				# The line from the prompt spot to the eye, and the view out through the gap.
				var blocked := _hit(near, front + Vector3.UP * minf(1.5, e.y + 0.2), cam)
				var shut := 0
				for i in 9:
					var a := lerpf(-half, half, i / 8.0) * 0.9
					for pitch: float in [-0.12, 0.0, 0.12]:
						var dir := (g * cos(a) + right * sin(a)).normalized()
						dir = (dir * cos(pitch) + Vector3.UP * sin(pitch)).normalized()
						if _hit(near, cam, cam + dir * 1.4) >= 0.0:
							shut += 1
				t.check(blocked < 0.0 and shut == 0, "%s (%s): the eye line and the view out are clear of what was added (%d rays met it%s)" % [tag, "peeking" if peek else "sat back", shut, ", the prompt line too" if blocked >= 0.0 else ""])
	t.check(kinds.has(&"shed") and kinds.has(&"under") and kinds.has(&"bench") and kinds.has(&"log"), "every kind of the garden's hides was checked: %s" % str(kinds.keys()))

# --- 4. no light, nothing brighter ------------------------------------------------------------------------

func test_no_light_added_or_changed_and_nothing_brighter(t: T) -> void:
	for seed_: String in ["lk1", "garden-1"]:
		var bare := _drawn(seed_, true)
		var d := _drawn(seed_)
		t.eq(d["lights"], bare["lights"], "%s: the same lights, in the same places, at the same strength, with the shapes as without" % seed_)
		t.eq(d["level_lights"], bare["level_lights"], "%s: the floor's light list is the same" % seed_)
		t.eq(d["mats"], bare["mats"], "%s: no new material" % seed_)
		var allowed := ["wood", "stone", "iron", "pavilion", "thicket", "leaf", "bark", "glass"]
		var odd := {}
		var gain: Dictionary = d["gain"]
		var most := _lum(OLD_BRIGHTEST) * float(gain["stone"])
		var bright := 0.0
		var brightest := ""
		for r: Array in _added(d["groups"] as Dictionary):
			if not String(r[1]) in allowed:
				odd[r[1]] = true
			if not gain.has(r[1]):
				continue
			var lum := _lum(r[5] as Color) * float(gain[r[1]])
			if lum > bright:
				bright = lum
				brightest = "%s %s %s" % [r[0], r[1], r[5]]
		t.check(odd.is_empty(), "%s: drawn only in the floor's own dark materials (odd: %s)" % [seed_, odd.keys()])
		t.check(bright <= most + 0.001, "%s: nothing drawn brighter than the old landmarks' stone (%.3f, at most %.3f: %s)" % [seed_, bright, most, brightest])

# --- 5. one seed, the same shapes; 6. every kind its own shape ---------------------------------------------------

static func _fingerprint(groups: Dictionary) -> String:
	var tags := groups.keys()
	tags.sort()
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for tag: String in tags:
		var ok := false
		for prefix in ADDED:
			ok = ok or tag.begins_with(prefix)
		if not ok:
			continue
		for r: Array in groups[tag]:
			ctx.update(("%s|%s|%s|%s|%s" % [tag, r[1], (r[2] as Vector3).snapped(Vector3.ONE * 0.001), (r[3] as Vector3).snapped(Vector3.ONE * 0.001),
				(r[4] as Vector3).snapped(Vector3.ONE * 0.001)]).to_utf8_buffer())
	return ctx.finish().hex_encode()

func test_one_seed_the_same_shapes(t: T) -> void:
	var a := _fingerprint(_drawn("lk1")["groups"])
	_cache.erase("lk1/false")
	var b := _fingerprint(_drawn("lk1")["groups"])
	t.eq(a, b, "lk1 twice: the same shapes")
	t.check(a != _fingerprint(_drawn("alpha")["groups"]), "another seed draws another garden")

func test_every_kind_has_its_own_shape(t: T) -> void:
	var seen := {}
	var seeds: Array[String] = _seeds(t)
	var extra := 0
	while true:
		for seed_ in seeds:
			var groups: Dictionary = _drawn(seed_)["groups"]
			for row: Array in Arboretum.KINDS:
				var kind: StringName = row[0]
				var rows: Array = groups.get("mark:" + String(kind), [])
				if rows.is_empty() or seen.has(kind):
					continue
				var heights := {}
				var mats := {}
				for r: Array in rows:
					mats[r[1]] = true
					for i in 3:
						heights[snappedf((r[2 + i] as Vector3).y, 0.01)] = true
				seen[kind] = [rows.size(), heights.size(), mats.size()]
		if seen.size() == Arboretum.KINDS.size() or extra >= 12:
			break
		seeds = ["kinds-%d" % extra]
		extra += 1
	for row: Array in Arboretum.KINDS:
		var kind: StringName = row[0]
		t.check(Dress.SHAPES.has(kind), "%s has a shape in client/arboretum_dress.gd" % kind)
		if not t.check(seen.has(kind), "%s was drawn on one of the gardens" % kind):
			continue
		var s: Array = seen[kind]
		t.check(int(s[0]) >= 100 and int(s[1]) >= 8, "%s is a shape, not a box: %d triangles at %d heights in %d materials" % [kind, s[0], s[1], s[2]])
	t.note("shapes: %s" % str(seen))
