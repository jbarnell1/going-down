# WH2: the clear approaches of a Hanging Ward home's openings (the run flag ward_homes, sim/ward/house.gd), worked out
# again from the built house (not from sim/ward/homes.gd's own rectangles), for the tests and for measuring. Every
# opening a walker uses keeps, on each side of its wall, a clear rectangle the opening's own width and Homes.APPROACH
# deep: each inner doorway (both sides), the front door (inside), the lift's doorway into the lift's house (inside), and
# each stair's foot and head (the stair's width, beyond its ends). Nothing solid stands in one: no furniture, hide or
# cupboard under a stair, and not the front door's leaf where the screen draws it open (client/ward/dress.gd door_leaf).
# Run on its own it measures seeds 1 + k * 7919 (the homes tests' series):
#   godot --headless --path godot --script res://tests/ward_home_clear.gd -- [--depth=0.6] [first k] [count]
extends SceneTree

const Ward = preload("res://sim/ward/state.gd")
const House = preload("res://sim/ward/house.gd")
const Homes = preload("res://sim/ward/homes.gd")
const Layout = preload("res://sim/ward/layout.gd")

## Rectangles that overlap by less than this only touch.
const EPS := 0.001

## The openings of a home, each {"kind", "level", "name", "rect": Rect2 (local x, z)}: one rectangle per side.
static func approaches(h: House, depth: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var t := House.WALL_THICKNESS
	for k in h.inner_doors.size():
		var d: Dictionary = h.inner_doors[k]
		var leaf: AABB = d.leaf
		var name := "%s/%s" % [d.rooms[0], d.rooms[1]]
		if leaf.size.x > leaf.size.z:
			# A wall along x at z = at.z: the doorway spans leaf.x.
			var z := float(d.at.z)
			out.append({"kind": &"inner", "level": int(d.level), "name": name, "rect": Rect2(leaf.position.x, z - t * 0.5 - depth, leaf.size.x, depth)})
			out.append({"kind": &"inner", "level": int(d.level), "name": name, "rect": Rect2(leaf.position.x, z + t * 0.5, leaf.size.x, depth)})
		else:
			var x := float(d.at.x)
			out.append({"kind": &"inner", "level": int(d.level), "name": name, "rect": Rect2(x - t * 0.5 - depth, leaf.position.z, depth, leaf.size.z)})
			out.append({"kind": &"inner", "level": int(d.level), "name": name, "rect": Rect2(x + t * 0.5, leaf.position.z, depth, leaf.size.z)})
	out.append({"kind": &"front", "level": 0, "name": "front", "rect": Rect2(h.door.position.x, t * 0.5, h.door.size.x, depth)})
	if h._parlour:
		# The lift's doorway (sim/ward/state.gd lift_door and GATE): in the left wall, at the house's middle.
		var gate := Ward.GATE.x
		out.append({"kind": &"lift", "level": 0, "name": "lift", "rect": Rect2(h.floor_bounds.position.x, h.floor_bounds.get_center().y - gate * 0.5, depth, gate)})
	for stair: House.Stair in h.stairs:
		var along_x := stair.from.x != stair.to.x
		var lane := stair.from.z if along_x else stair.from.x
		var s0 := stair.from.x if along_x else stair.from.z
		var s1 := stair.to.x if along_x else stair.to.z
		var dir := signf(s1 - s0)
		var low := int(roundf(stair.from.y / House.HEIGHT))
		for end: Array in [[&"stair_foot", low, s0, -dir], [&"stair_head", low + 1, s1, dir]]:
			var a: float = end[2]
			var b: float = a + float(end[3]) * depth
			var lo := minf(a, b)
			var r := Rect2(lo, lane - House.STAIR_WIDTH * 0.5, depth, House.STAIR_WIDTH) if along_x \
				else Rect2(lane - House.STAIR_WIDTH * 0.5, lo, House.STAIR_WIDTH, depth)
			out.append({"kind": end[0], "level": end[1], "name": str(end[0]), "rect": r.intersection(h.floor_bounds)})
	return out

## The front door's leaf as the screen draws it (client/ward/dress.gd door_leaf, sim/ward/homes.gd front_leaf), on the
## jamb the plan names (a plan without one: the low-x jamb, as every house before WH2).
static func front_leaf(h: House) -> Dictionary:
	var side := int(h.plan.door.get("hinge", -1)) if h.homes() else -1
	return Homes.front_leaf(h.door.get_center().x, h.door.size.x, side)

## Every solid thing of a home on a storey, {"kind", "rect": Rect2 (local x, z), "hide"}: its furniture (hides and the
## cupboards under the stairs too).
static func solids(h: House, level: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for f: Dictionary in h.furniture:
		if int(f.level) == level:
			var b: AABB = f.box
			out.append({"kind": f.kind, "rect": Rect2(b.position.x, b.position.z, b.size.x, b.size.z), "hide": f.hide})
	return out

static func _meets(a: Rect2, b: Rect2) -> bool:
	return a.grow(-EPS).intersects(b.grow(-EPS))

## Every blocked approach of a home: [{"opening", "name", "level", "piece"}]. A piece, or the front door's leaf where it
## stands open, inside an opening's clear approach (the leaf swinging past one is not counted: it is gone in a second).
static func blocked(h: House, depth := Homes.APPROACH) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var leaf := front_leaf(h)
	for a: Dictionary in approaches(h, depth):
		var r: Rect2 = a.rect
		for s: Dictionary in solids(h, int(a.level)):
			if _meets(r, s.rect):
				out.append({"opening": a.kind, "name": a.name, "level": a.level, "piece": s.kind})
		if int(a.level) == 0 and a.kind != &"front" and _meets(r, leaf.rest):
			out.append({"opening": a.kind, "name": a.name, "level": a.level, "piece": &"front_leaf"})
	return out

## Furniture where the front door's leaf stands open or swings: [kind].
static func in_leaf(h: House) -> Array[StringName]:
	var out: Array[StringName] = []
	var leaf := front_leaf(h)
	for s: Dictionary in solids(h, 0):
		if Homes.meets_leaf(s.rect, leaf):
			out.append(s.kind)
	return out

## The homes' layout options at today's settings.
static func options() -> Dictionary:
	var o := Layout.options(null)
	o["homes"] = 1
	return o

func _init() -> void:
	var depth := Homes.APPROACH
	var nums: Array[int] = []
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--depth="):
			depth = float(a.substr(8))
		elif a.is_valid_int():
			nums.append(int(a))
	var first := nums[0] if nums.size() > 0 else 0
	var count := nums[1] if nums.size() > 1 else 500
	var by := {}
	var houses := 0
	var bad_houses := 0
	var bad_seeds: Array[int] = []
	var leaf_pieces := {}
	var moved := {}
	var dropped := {}
	for k in range(first, first + count):
		var s := 1 + k * 7919
		var w := Ward.new(s, options())
		var seed_bad := false
		for i in w.houses.size():
			var h := w.houses[i]
			houses += 1
			var list := blocked(h, depth)
			for b: Dictionary in list:
				var key := "%s | %s %s (storey %d) | %s" % [h.plan.type, b.opening, b.name, b.level, b.piece]
				by[key] = int(by.get(key, 0)) + 1
			if not list.is_empty():
				bad_houses += 1
				seed_bad = true
			for kind in in_leaf(h):
				var key := "%s | %s" % [h.plan.type, kind]
				leaf_pieces[key] = int(leaf_pieces.get(key, 0)) + 1
			for m: Dictionary in h.plan.get("moved", []):
				var key := "%s | %s in %s (storey %d)" % [h.plan.type, m.kind, m.room, m.level]
				moved[key] = int(moved.get(key, 0)) + 1
			for m: Dictionary in h.plan.get("dropped", []):
				var key := "%s | %s in %s (storey %d)" % [h.plan.type, m.kind, m.room, m.level]
				dropped[key] = int(dropped.get(key, 0)) + 1
			if int(h.plan.door.get("hinge", -1)) > 0:
				moved["%s | front door leaf hung on the other jamb" % h.plan.type] = int(moved.get("%s | front door leaf hung on the other jamb" % h.plan.type, 0)) + 1
		if seed_bad:
			bad_seeds.append(s)
	print("depth %.2f, %d seeds (1 + k * 7919, k from %d), %d houses; houses with a blocked opening %d; seeds with one %d" % [depth, count, first, houses, bad_houses, bad_seeds.size()])
	for table: Array in [["blocked (house type | opening (storey) | piece)", by], ["furniture in the front door leaf's place", leaf_pieces], ["moved by WH2", moved], ["dropped by WH2", dropped]]:
		print(table[0] + ":")
		var keys: Array = (table[1] as Dictionary).keys()
		keys.sort()
		for key: String in keys:
			print("  %5d  %s" % [table[1][key], key])
	print("seeds with a blocked opening (first 12): %s" % str(bad_seeds.slice(0, 12)))
	quit()
