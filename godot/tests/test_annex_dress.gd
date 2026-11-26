# LA2: the Annex dressed as an office people left, looks only (client/annex_dress.gd). Over several generated Annex
# floors, as the game draws them (Level.build):
#   1. same-shaped rooms of the same kind are dressed identically: every sign, socket, tray and thing on a desk in
#      the same place of the room's own frame (annex_view.gd same_shape_problems, which now holds the dressing too);
#   2. every corridor junction is dressed like every other junction of the same make (its four sides), and every
#      corridor cell like every other of its make and its place in the sockets' rhythm: corridors give no directions;
#   3. nothing added stands in the walkable space below 2.2 m more than a few centimetres off a wall, except what
#      stands on top of a piece of the rules' furniture, inside its footprint;
#   4. nothing added covers a hide, its front, or the place a findable is searched from; nothing on a hide reaches
#      below its top or makes a piece look more (or less) like a place to hide; where the Temp's sticky notes go on
#      a wall nothing stands out further than a note, and on the floor only the skirting, at the wall;
#   5. the dressing adds no light, and with it off the Annex is drawn as before.
extends RefCounted

const T = preload("res://tests/t.gd")
const AnnexPlan = preload("res://sim/annex.gd")
const AV = preload("res://client/annex_view.gd")
const Dress = preload("res://client/annex_dress.gd")
const Lookalikes = preload("res://tests/test_annex_lookalikes.gd")
const Furniture = preload("res://sim/furniture.gd")
const Playroom = preload("res://sim/playroom.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const Run = preload("res://sim/run.gd")

const S := 2.0
const LH := 3.2
## Walkable space starts at the floor and ends here (a body and a raised arm).
const CLEAR_H := 2.2
## A wall piece stands within this of its wall's line (the drawn wall's half thickness, 7 cm, and 3).
const NEAR_WALL := 0.1
## Where a sticky note goes (annex_notes_view.gd: 1.49 m up, 31 cm tall, 1.8 cm off the wall face).
const NOTE_LO := 1.33
const NOTE_HI := 1.65
const NOTE_OFF := 0.07 + 0.018

const SEEDS: Array[String] = ["la2-a", "la2-b", "la2-c", "alpha", "beta"]
const QUICK_SEEDS: Array[String] = ["la2-a", "alpha"]

static var _built := {}

## The game's Annex for a seed and depth, drawn as Level.build draws it, and its view.
static func view_of(sd: String, depth: int) -> AV:
	var key := "%s/%d/%s" % [sd, depth, str(Dress.enabled)]
	if _built.has(key):
		return _built[key]
	var fp := AnnexPlan.generate_annex(sd, depth)
	var level := Level.new()
	level.build(PlanDump.dump(fp, Run.car_geometry(fp)), fp.seed, fp)
	var v: AV = level.get_meta("annex")
	_built[key] = v
	return v

static func floors(t: T) -> Array[AV]:
	var out: Array[AV] = []
	var i := 0
	for sd: String in (QUICK_SEEDS if t.quick else SEEDS):
		out.append(view_of(sd, 3 + i % 2))
		i += 1
	return out

static func release() -> void:
	for v: AV in _built.values():
		v.lv.free()
	_built.clear()

# --- 1 -------------------------------------------------------------------------------------------

func test_same_shaped_rooms_are_dressed_alike(t: T) -> void:
	var groups := 0
	var compared := 0
	var dressed := 0
	var tops := 0
	var problems: Array[String] = []
	for v: AV in floors(t):
		var stats := {}
		problems.append_array(v.same_shape_problems(stats))
		groups += int(stats.groups)
		compared += int(stats.rooms_compared)
		for rec: Dictionary in v.records:
			if str(rec.type).begins_with("dress:"):
				dressed += 1
			elif str(rec.type).begins_with("top:"):
				tops += 1
	t.check(groups > 0 and compared > 0, "the floors have rooms of the same shape to compare (%d groups, %d rooms)" % [groups, compared])
	t.check(dressed > 100 and tops > 100, "the comparison holds the dressing (%d wall and ceiling pieces, %d things on furniture)" % [dressed, tops])
	t.check(problems.is_empty(), "every room is dressed like every other room of its shape and kind (%d problems: %s)" % [problems.size(), "; ".join(problems.slice(0, 4))])

# --- 2 -------------------------------------------------------------------------------------------

## The eight turnings and mirrorings of a cell's local square (x across, z down): bit 0 flips x, bit 1 flips z, bit 2
## swaps them.
static func _sym(k: int, p: Vector2) -> Vector2:
	var q := Vector2(-p.x if (k & 1) != 0 else p.x, -p.y if (k & 2) != 0 else p.y)
	return Vector2(q.y, q.x) if (k & 4) != 0 else q

## A corridor cell's make: each side's edge and the cell beyond it, read in symmetry k.
static func _make(v: AV, level: int, c: Vector2i, k: int) -> String:
	var parts: Array[String] = []
	for d: Vector2i in AV.DIRS:
		var e := _sym(k, Vector2(d))
		parts.append("%d,%d:%s:%s" % [roundi(e.x), roundi(e.y), v.edge_kind(level, c.x, c.y, d), v.lv.kind(level, c.x + d.x, c.y + d.y)])
	parts.sort()
	return ";".join(parts)

## What a corridor cell is dressed with, in symmetry k: every piece of the dressing that belongs to it (by its cell),
## and every skirting run along one of its sides, cut to the side, as sorted lines in the cell's own frame.
static func _cell_dressing(v: AV, level: int, c: Vector2i, k: int, own: Array) -> Array[String]:
	var cc := v.lv.cell_center(level, c.x, c.y)
	var out: Array[String] = []
	for d: Dictionary in own:
		var xf: Transform3D = d.xf
		var p := _sym(k, Vector2(xf.origin.x - cc.x, xf.origin.z - cc.z))
		var f := _sym(k, Vector2(xf.basis.z.x, xf.basis.z.z))
		out.append("%s %.2f %.2f %.2f %d,%d" % [d.type, p.x, xf.origin.y - level * LH, p.y, roundi(f.x), roundi(f.y)])
	for run: Dictionary in v.dressing:
		if str(run.type) != "skirting" or int(run.level) != level or int(run.room) >= 0:
			continue
		var p0: Vector3 = run.p0
		var p1: Vector3 = run.p1
		var n: Vector3 = (run.xf as Transform3D).basis.z
		var a := Vector2(p0.x - cc.x, p0.z - cc.z)
		var b := Vector2(p1.x - cc.x, p1.z - cc.z)
		# On one of the cell's sides, facing into it: the run's line is the side's, its normal points in.
		var side := Vector2(-n.x, -n.z)
		if absf(a.dot(side) - 1.0) > 0.01:
			continue
		var tang := Vector2(-side.y, side.x)
		# Cut to the cell's own side between the crossing walls' faces: past them it is inside a wall or the next cell's.
		var lo := maxf(minf(a.dot(tang), b.dot(tang)), -1.0 + 0.07)
		var hi := minf(maxf(a.dot(tang), b.dot(tang)), 1.0 - 0.07)
		if hi - lo < 0.01:
			continue
		var e0 := _sym(k, side + tang * lo)
		var e1 := _sym(k, side + tang * hi)
		var pts: Array[String] = ["%.2f,%.2f" % [e0.x, e0.y], "%.2f,%.2f" % [e1.x, e1.y]]
		pts.sort()
		out.append("skirting %s %s" % [pts[0], pts[1]])
	out.sort()
	return out

func test_every_junction_is_dressed_like_every_other(t: T) -> void:
	var problems: Array[String] = []
	var junction_groups := {}
	var cells := 0
	for v: AV in floors(t):
		var own := {}
		for d: Dictionary in v.dressing:
			if int(d.room) < 0 and str(d.type) != "skirting" and not str(d.type).begins_with("top:"):
				var key := "%d:%d,%d" % [int(d.level), (d.cell as Vector2i).x, (d.cell as Vector2i).y]
				if not own.has(key):
					own[key] = []
				(own[key] as Array).append(d)
		# A corridor cupboard (a hide of the rules' with no room) makes its cell unlike others: such cells are left out.
		var held := {}
		for pc: Furniture.Piece in v.lv.pieces:
			if pc.room < 0:
				for cy in range(pc.foot.position.y / 200, (pc.foot.end.y - 1) / 200 + 1):
					for cx in range(pc.foot.position.x / 200, (pc.foot.end.x - 1) / 200 + 1):
						held["%d:%d,%d" % [pc.level, cx, cy]] = true
		var groups := {}
		for level in 2:
			for y in v.H:
				for x in v.W:
					if v.lv.kind(level, x, y) != "corridor" or held.has("%d:%d,%d" % [level, x, y]):
						continue
					var c := Vector2i(x, y)
					var best := ""
					var syms: Array[int] = []
					for k in 8:
						var m := _make(v, level, c, k)
						if best == "" or m < best:
							best = m
							syms = [k]
						elif m == best:
							syms.append(k)
					var junction := v.exits(level, x, y).size() >= 3
					var rhythm := v._through(level, c) and (x + y) % 4 == 0
					var gkey := "%s|%s|%s" % [best, "J" if junction else "", "R" if rhythm else ""]
					var mine: Array = own.get("%d:%d,%d" % [level, x, y], [])
					var lists: Array = []
					for k: int in syms:
						lists.append(_cell_dressing(v, level, c, k, mine))
					cells += 1
					if junction:
						junction_groups[gkey] = int(junction_groups.get(gkey, 0)) + 1
					if not groups.has(gkey):
						groups[gkey] = [lists[0], "%d:%d,%d" % [level, x, y]]
						continue
					var want: Array = groups[gkey][0]
					var ok := false
					for l: Array in lists:
						if l == want:
							ok = true
							break
					if not ok:
						problems.append("corridor %d:%d,%d is dressed unlike %s of its make (%s against %s)" % [level, x, y, groups[gkey][1], str(lists[0]), str(want)])
	var junctions := 0
	for g: String in junction_groups:
		junctions += int(junction_groups[g])
	t.check(junctions > 10, "the floors have junctions to compare (%d, %d makes)" % [junctions, junction_groups.size()])
	t.check(problems.is_empty(), "every corridor cell and junction is dressed like every other of its make (%d of %d differ: %s)" % [problems.size(), cells, "; ".join(problems.slice(0, 3))])

# --- 3 and 4 --------------------------------------------------------------------------------------

## Whether a box lies within NEAR_WALL of a solid wall line on `level` (a wall or the solid part of a doorway's
## edge, or the lift's), and if so how far its far side stands from the line.
static func _off_wall(v: AV, level: int, box: AABB) -> float:
	var best := INF
	var c := box.get_center()
	var lv := v.lv
	for axis in 2:
		var lo := box.position.x if axis == 0 else box.position.z
		var hi := box.end.x if axis == 0 else box.end.z
		var line := roundf((lo + hi) * 0.5 / S) * S
		var off := maxf(absf(lo - line), absf(hi - line))
		if off > NEAR_WALL:
			continue
		# The edge on that line under the box's middle.
		var along := c.z if axis == 0 else c.x
		var i := floori(along / S)
		var j := roundi(line / S)
		var k: String
		if axis == 0:
			if i < 0 or i >= v.H or j < 0 or j > v.W:
				continue
			k = lv.edges[level].vertical[i * (v.W + 1) + j]
		else:
			if i < 0 or i >= v.W or j < 0 or j > v.H:
				continue
			k = lv.edges[level].horizontal[j * v.W + i]
		var in_edge := along - i * S
		var solid := k == "wall" or k == "rail" or (k == "door" and absf(in_edge - S * 0.5) > Level.DOOR_W * 0.5)
		if not solid:
			var lift := lv._lift_edge()
			solid = level == lv.landing.x and lift == (Vector4i(0, j, i, 1) if axis == 0 else Vector4i(1, i, j, 1))
		if solid:
			best = minf(best, off)
	return best

static func _rect_m(r: Rect2i) -> Rect2:
	return Rect2(r.position.x / 100.0, r.position.y / 100.0, r.size.x / 100.0, r.size.y / 100.0)

static func _hits(box: AABB, r: Rect2) -> bool:
	return box.position.x < r.end.x and r.position.x < box.end.x and box.position.z < r.end.y and r.position.y < box.end.z

static func _covers_walkable(v: AV, level: int, box: AABB) -> bool:
	for z in range(floori(box.position.z / S), floori((box.end.z - 0.001) / S) + 1):
		for x in range(floori(box.position.x / S), floori((box.end.x - 0.001) / S) + 1):
			if v.lv.walkable(level, x, z):
				return true
	return false

func test_nothing_new_to_walk_into(t: T) -> void:
	var problems: Array[String] = []
	var boxes := 0
	for v: AV in floors(t):
		var drawn := {}
		for d: Dictionary in v.lv.furniture_drawn:
			drawn[int(d.piece)] = d.rect
		for b: Dictionary in Dress.world_boxes(v):
			boxes += 1
			var level := int(b.level)
			var box: AABB = b.aabb
			var y0 := box.position.y - level * LH
			if y0 >= CLEAR_H:
				continue
			var what := "%s at %s (level %d)" % [b.type, str(box.position), level]
			if str(b.type).begins_with("top:"):
				# On a piece: inside some drawn piece's footprint, standing on it.
				var on := false
				for r: Rect2 in drawn.values():
					if r.grow(0.01).encloses(Rect2(box.position.x, box.position.z, box.size.x, box.size.z)):
						on = true
				if not on or y0 < 0.5:
					problems.append(what + " is not on top of a piece")
				continue
			if _off_wall(v, level, box) <= NEAR_WALL:
				continue
			if _covers_walkable(v, level, box):
				problems.append(what + " stands in the walkable space")
	t.check(boxes > 1000, "the floors are dressed (%d boxes)" % boxes)
	t.check(problems.is_empty(), "nothing added stands in the walkable space below %.1f m off a wall or a furniture top (%d: %s)" % [CLEAR_H, problems.size(), "; ".join(problems.slice(0, 4))])

func test_nothing_covers_a_hide_a_findable_or_a_note(t: T) -> void:
	var problems: Array[String] = []
	var near_hides := 0
	var in_band := 0
	for v: AV in floors(t):
		var keep_off := [[], []]
		var hide_rects := [[], []]
		var drawn := {}
		for d: Dictionary in v.lv.furniture_drawn:
			drawn[int(d.piece)] = d.rect
		for pc: Furniture.Piece in v.lv.pieces:
			if pc.hide >= 0:
				var h: Playroom.Hide = v.hides[pc.hide]
				(hide_rects[pc.level] as Array).append(_rect_m(pc.foot).merge(drawn[pc.id]) if drawn.has(pc.id) else _rect_m(pc.foot))
				var f := Vector2(h.front.x / 100.0, h.front.y / 100.0)
				(keep_off[pc.level] as Array).append(Rect2(f - Vector2(0.4, 0.4), Vector2(0.8, 0.8)))
			if pc.searchable:
				var s := Furniture.search_stand_cm(pc)
				(keep_off[pc.level] as Array).append(Rect2(s.x / 100.0 - 0.35, s.y / 100.0 - 0.35, 0.7, 0.7))
		for b: Dictionary in Dress.world_boxes(v):
			var level := int(b.level)
			var box: AABB = b.aabb
			var y0 := box.position.y - level * LH
			var y1 := box.end.y - level * LH
			var what := "%s at %s (level %d)" % [b.type, str(box.position), level]
			if str(b.type).begins_with("top:"):
				continue
			if y0 < CLEAR_H:
				for r: Rect2 in hide_rects[level]:
					if _hits(box, r):
						near_hides += 1
						problems.append(what + " runs into a hide")
				for r: Rect2 in keep_off[level]:
					if _hits(box, r):
						problems.append(what + " stands where a hide is entered or a findable searched")
			var off := _off_wall(v, level, box)
			if y1 > NOTE_LO and y0 < NOTE_HI and off <= NEAR_WALL:
				in_band += 1
				if off > NOTE_OFF - 0.002:
					problems.append("%s stands %.3f m off its wall where a note goes" % [what, off])
			if y0 < 0.05 and str(b.type) != "skirting":
				problems.append(what + " lies on the floor where a crew mark goes")
		# The pictures on the walls (posters, notices, pin boards): flat, no further off the wall than a note.
		for rec: Dictionary in v.records:
			if not str(rec.type).contains("picture:"):
				continue
			var o: Vector3 = (rec.xf as Transform3D).origin
			var off := minf(absf(o.x - roundf(o.x / S) * S), absf(o.z - roundf(o.z / S) * S))
			in_band += 1
			if off > NOTE_OFF - 0.002:
				problems.append("%s stands %.3f m off its wall where a note goes" % [rec.type, off])
		# On a hide, nothing reaches below its top (its top slab: the widest boxes').
		for d: Dictionary in v.dressing:
			if not str(d.type).begins_with("top:hide:"):
				continue
			var kind := StringName(str(d.type).substr(9))
			var top := 0.0
			for hb: Array in (AV.meeting_table_boxes() if kind == &"table" else AV.hide_boxes(kind, false)):
				if (hb[0] as Vector3).x >= 0.8:
					top = maxf(top, (hb[1] as Vector3).y + (hb[0] as Vector3).y * 0.5)
			for tb: Array in d.boxes:
				if (tb[1] as Vector3).y - (tb[0] as Vector3).y * 0.5 < top - 0.001:
					problems.append("a thing on a %s reaches below its top" % kind)
	# Nothing on top changes whether a piece looks like a place to hide (test_annex_lookalikes.gd's eye).
	var kinds: Array[String] = ["hide:desk", "hide:cabinet", "hide:table", "filing", "cabinet_low", "copier", "counter", "fridge", "break_table"]
	for type: String in kinds:
		var base: Array
		if type.begins_with("hide:"):
			var k := StringName(type.substr(5))
			base = AV.meeting_table_boxes() if k == &"table" else AV.hide_boxes(k, false)
		else:
			base = (AV.catalogue()[AV.catalogue_name(StringName(type))] as Dictionary).boxes
		var with := base.duplicate()
		with.append_array(Dress.tops(type))
		if not t.check(not Dress.tops(type).is_empty(), type + " has things on top"):
			continue
		t.check(Lookalikes.looks_enterable(with) == Lookalikes.looks_enterable(base), "%s looks %s with its things on top as without" % [type, "enterable" if Lookalikes.looks_enterable(base) else "closed"])
	t.check(in_band > 100, "wall pieces in the notes' band were checked (%d)" % in_band)
	t.check(problems.is_empty(), "nothing added covers a hide, a findable, a note's or a mark's place (%d: %s)" % [problems.size(), "; ".join(problems.slice(0, 4))])
	t.note("%d boxes near hides" % near_hides)

# --- 5 -------------------------------------------------------------------------------------------

static func _lights(v: AV) -> Array[String]:
	var out: Array[String] = []
	for c in v.lv.get_children():
		if c is Light3D:
			var l := c as Light3D
			out.append("%s %s %.3f %s" % [l.get_class(), str(l.position), l.light_energy, str(l.visible)])
	out.sort()
	return out

static func _not_dressing(v: AV) -> Array[String]:
	var out: Array[String] = []
	for rec: Dictionary in v.records:
		var type := str(rec.type)
		if type.begins_with("dress:") or type.begins_with("top:"):
			continue
		var o: Vector3 = (rec.xf as Transform3D).origin
		out.append("%d %s %.3f %.3f %.3f" % [int(rec.room), type, o.x, o.y, o.z])
	out.sort()
	return out

func test_no_light_added_and_nothing_else_changes(t: T) -> void:
	for sd: String in ["la2-a", "beta"]:
		var on := view_of(sd, 3)
		Dress.enabled = false
		var off := view_of(sd, 3)
		Dress.enabled = true
		t.check(off.dressing.is_empty() and not on.dressing.is_empty(), "%s: the dressing is drawn only when on (%d pieces)" % [sd, on.dressing.size()])
		t.check(_lights(on) == _lights(off) and not _lights(on).is_empty(), "%s: the same %d lights with the dressing as without" % [sd, _lights(on).size()])
		t.check(on.lv.main_lights.size() == off.lv.main_lights.size() and on.lv.emergency_lights.size() == off.lv.emergency_lights.size(), "%s: the same light dials" % sd)
		t.check(_not_dressing(on) == _not_dressing(off), "%s: every piece of furniture and every old picture stays where it was" % sd)
		var same := on.lv.furniture_drawn.size() == off.lv.furniture_drawn.size()
		for i in mini(on.lv.furniture_drawn.size(), off.lv.furniture_drawn.size()):
			var a: Rect2 = on.lv.furniture_drawn[i].rect
			var b: Rect2 = off.lv.furniture_drawn[i].rect
			same = same and a.position.distance_to(b.position) < 0.001 and a.size.distance_to(b.size) < 0.001
		t.check(same, "%s: every piece of furniture covers the same floor" % sd)
	release()
