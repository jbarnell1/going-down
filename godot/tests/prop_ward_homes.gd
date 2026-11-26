# WH1: real homes for the Hanging Ward (the run flag `ward_homes`, net/host_rules.gd; data/ward_homes.json,
# sim/ward/homes.gd, sim/ward/house.gd). The approved design (21 Nov, the owner: "Good with these defaults."): six
# house types, each a real plan of kitchen, table, bedrooms, bathroom and hall, chosen with its variant, mirror, door
# places and furniture places from the floor seed. The North Star: "Everything about a floor comes from one seed,
# identical for every player"; "Every floor has places to hide"; "With the flag off, nothing may change."
#   1. flag off: the flag is off by default and without the Ward's seeded layout, and a Ward built without it is today's
#      (the digests recorded from the code before WH1);
#   2. every house of a homes Ward is one of the six types; its rooms tile each storey; it has a kitchen, a table, a
#      bedroom and (but for the parlour cottage, whose washstand is its bathroom) a bathroom; doorways 0.9 m or wider;
#   3. at least two hiding places in every house and one on every storey;
#   4. one room with a single doorway big enough to crowd round (the design's fight doorway);
#   5. every room of every house is walked to from the lift by the Ward's own walk model, and no spot is stranded;
#   6. from every opening one room is out of the arm's reach (the owner's rule), and the arm never enters a wall;
#   7. one seed, one set of homes: built twice the same, and as recorded;
#   8. the options ride the wire, and the flag reaches the rules as the last parameter.
extends RefCounted

const T = preload("res://tests/t.gd")
const Ward = preload("res://sim/ward/state.gd")
const Layout = preload("res://sim/ward/layout.gd")
const House = preload("res://sim/ward/house.gd")
const Homes = preload("res://sim/ward/homes.gd")
const Digest = preload("res://tests/ward_digest.gd")
const Reach = preload("res://tests/prop_ward_reach.gd")
const HostRules = preload("res://net/host_rules.gd")
const WardWire = preload("res://net/ward_wire.gd")
const Bots = preload("res://sim/ward/bots.gd")
const Route = preload("res://client/ward/route.gd")

## True while the homes' properties run again on RL1's lift_clear Wards (test_the_homes_hold_with_the_lift_clear).
static var _lift_clear := false

## The homes' layout options as the host makes them at today's settings (with RL1's lift_clear while _lift_clear).
static func homes_options() -> Dictionary:
	var o := Layout.options(null, _lift_clear)
	o["homes"] = 1
	return o

## The first `count` seeds of the series 1 + k * 7919 whose homes Ward RL1's lift_clear changes (the lift's house came
## out the lowest, so another house is lowered): the seeds where the two flags meet.
static func lift_clear_seeds(count: int) -> Array[int]:
	var out: Array[int] = []
	var plain := Layout.options(null)
	plain["homes"] = 1
	var clear := Layout.options(null, true)
	clear["homes"] = 1
	var k := 0
	# About one seed in nine qualifies (48 of the first 400); the cap stops a search that finds none.
	while out.size() < count and k < 4000:
		var s := 1 + k * 7919
		if JSON.stringify(Layout.generate(s, plain).houses) != JSON.stringify(Layout.generate(s, clear).houses):
			out.append(s)
		k += 1
	return out

## Recorded from commit 14657db (before WH1) by ward_digest.gd: today's fixed Ward and the seeded layout (WG1).
const BEFORE_FIXED := {
	0: "WARD 0 4df912f0ef54e384 71f83242 1c202214 65f6099a 909e1415",
	26: "WARD 26 2f993b4791d33859 845b2066 a50b4c9a 2f4cf4fa 3c592413",
	8143: "WARD 8143 6a9f8e32fdf6a7f7 8a86c967 7167a5ed a1d9249f 600000f7",
	31827: "WARD 31827 6564d3be450372bf bddaa2d7 7e14e671 c703c9b3 23aada87",
}
const BEFORE_GENERATED := {
	0: "WARD 0 4457bcaacde5853c a14ebae8 092ee980 e42d34c0 bc9d7e84",
	26: "WARD 26 16b468e82f224b2d 8c15da6b d6dba85a da6b1ed9 ab527bef",
	8143: "WARD 8143 87643ed8bcbb422a 61b29984 1a528042 d652f423 b9a928dd",
	31827: "WARD 31827 1a683066436c8100 4043a166 6eb5aab0 34950359 174df3cf",
}
## Recorded with WH1 (the homes' Ward) by `ward_digest.gd -- --homes <seeds>`.
const HOMES_GOLDEN := {
	0: "WARD 0 79b7159dee007a39 75f6f862 d843cbf4 e42d34c0 48d883af",
	26: "WARD 26 46af0d5b0f64ff2b dab8372b 37099357 71250a5d 591f5e48",
	8143: "WARD 8143 e75e12c0ad58d6d3 a9cb15bb 94286b06 9c96b265 65f13c95",
	31827: "WARD 31827 4cce25cbd45a1c60 5b041a61 7720482d a309736b 07c21822",
}
const SEEDS: Array[int] = [0, 26, 8143, 31827]

func _seeds(t: T, quick: int, full: int) -> Array[int]:
	if _lift_clear:
		return lift_clear_seeds(quick if t.quick else mini(full, 100))
	var out: Array[int] = []
	for k in (quick if t.quick else full):
		out.append(1 + k * 7919)
	return out

func test_flag_off_is_todays_ward(t: T) -> void:
	t.check(not HostRules.new(true, 1).ward_homes, "the run flag ward_homes is off by default")
	for s in SEEDS:
		if BEFORE_FIXED.has(s):
			t.eq(Digest.line(s), BEFORE_FIXED[s], "seed %d: today's fixed Ward is unchanged" % s)
		if BEFORE_GENERATED.has(s):
			t.eq(Digest.line(s, Layout.options(null)), BEFORE_GENERATED[s], "seed %d: the seeded layout without the homes is unchanged" % s)
		var w := Ward.new(s, Layout.options(null))
		var planned := 0
		for h in w.houses:
			planned += 1 if h.homes() else 0
		t.eq(planned, 0, "seed %d: no house is a home without the flag" % s)
	t.eq(BEFORE_FIXED.size() + BEFORE_GENERATED.size(), SEEDS.size() * 2, "every seed has both recorded lines")

func test_every_house_is_a_home(t: T) -> void:
	var bad: Array[String] = []
	var types := {}
	var variants := {}
	for s in _seeds(t, 6, 100):
		var w := Ward.new(s, homes_options())
		for i in w.houses.size():
			var h := w.houses[i]
			var site: Dictionary = w.layout.houses[i]
			if not h.homes():
				bad.append("seed %d house %d: not a home" % [s, i])
				continue
			types[h.plan.type] = true
			variants["%s/%s" % [h.plan.type, h.plan.variant]] = true
			var kinds := {}
			for level in h.rooms_by_level.size():
				var area := 0.0
				var rects: Array = []
				for room: Dictionary in h.rooms_by_level[level]:
					var r: Rect2 = room.rect
					area += r.get_area()
					kinds[room.kind] = true
					for other: Rect2 in rects:
						if r.intersection(other).get_area() > 0.0001:
							bad.append("seed %d house %d storey %d: %s overlaps another room" % [s, i, level, room.name])
					rects.append(r)
					if not h.floor_bounds.grow(0.001).encloses(r):
						bad.append("seed %d house %d: %s outside the house" % [s, i, room.name])
				if absf(area - h.floor_bounds.get_area()) > 0.01:
					bad.append("seed %d house %d storey %d: rooms cover %.2f of %.2f m2" % [s, i, level, area, h.floor_bounds.get_area()])
			var tables := 0
			for f: Dictionary in h.furniture:
				if f.hide == &"table":
					tables += 1
			if not kinds.has(&"kitchen") or not kinds.has(&"bedroom") and not kinds.has(&"bedsit") or tables == 0:
				bad.append("seed %d house %d (%s): kitchen %s, bedroom %s, table %d" % [s, i, h.plan.type, kinds.has(&"kitchen"), kinds.has(&"bedroom"), tables])
			if not kinds.has(&"bathroom") and h.plan.type != "parlour":
				bad.append("seed %d house %d (%s): no bathroom" % [s, i, h.plan.type])
			for d: Dictionary in h.inner_doors:
				var leaf: AABB = d.leaf
				if maxf(leaf.size.x, leaf.size.z) < 0.9 - 0.001:
					bad.append("seed %d house %d: a doorway %.2f m wide" % [s, i, maxf(leaf.size.x, leaf.size.z)])
			if int(site.floors) != h.rooms_by_level.size() or h.storeys.size() != h.rooms_by_level.size() + 1:
				bad.append("seed %d house %d: %d storeys in the layout, %d planned" % [s, i, int(site.floors), h.rooms_by_level.size()])
	t.check(bad.is_empty(), "every house is a real home: %s" % str(bad.slice(0, 8)))
	t.eq(types.size(), 6, "all six types appear (%s)" % str(types.keys()))
	t.note("types %s; variants %s" % [str(types.keys()), str(variants.keys())])

func test_every_house_has_hides(t: T) -> void:
	var bad: Array[String] = []
	var total := 0
	for s in _seeds(t, 6, 100):
		var w := Ward.new(s, homes_options())
		for i in w.houses.size():
			var h := w.houses[i]
			var per := {}
			var count := 0
			for f: Dictionary in h.furniture:
				if f.hide != &"":
					count += 1
					per[int(f.level)] = true
			total += count
			if count < 2 or per.size() < h.rooms_by_level.size():
				bad.append("seed %d house %d (%s): %d hides on %d of %d storeys" % [s, i, h.plan.type, count, per.size(), h.rooms_by_level.size()])
	t.check(bad.is_empty(), "at least two hides in every house and one on every storey: %s" % str(bad.slice(0, 8)))
	t.note("%d hides" % total)

func test_every_house_has_a_room_to_crowd_round(t: T) -> void:
	var bad: Array[String] = []
	for s in _seeds(t, 4, 50):
		var w := Ward.new(s, homes_options())
		for i in w.houses.size():
			var h := w.houses[i]
			var found := false
			for level in h.rooms_by_level.size():
				for room: Dictionary in h.rooms_by_level[level]:
					var r: Rect2 = room.rect
					var doors := 0
					for d: Dictionary in h.inner_doors:
						if int(d.level) == level and (d.rooms as Array).has(room.name):
							doors += 1
					if level == 0 and h.openings()[0].room == room.name:
						doors += 1
					if doors == 1 and minf(r.size.x, r.size.y) >= 2.0 and r.get_area() >= 7.0:
						found = true
			if not found:
				bad.append("seed %d house %d (%s)" % [s, i, h.plan.type])
	t.check(bad.is_empty(), "every house has a room of 7 m2 or more with one doorway: %s" % str(bad.slice(0, 8)))

## Every house's front door is walked to from the lift by the screen's own way-finder over the game's walk model
## (client/ward/route.gd Route.find, the walk the screen and host check), and every room of every house from just
## inside its front door (steps of 0.15 m, inside the house, heights in 25 cm bands). The lift is boarding and the
## bridge down, as prop_ward_reach walks the Ward; that test's own stranded check runs here on the homes too.
func test_every_room_is_walked_to(t: T) -> void:
	var missing: Array[String] = []
	var rooms := 0
	for s in _seeds(t, 2, 12):
		var w := Ward.new(s, homes_options())
		w.bridge_lowered = true
		w.phase = &"boarding"
		var car := w.lift_door() + Vector3(0, 0.0, -1.0)
		car.y = w.footing.walking_height(Vector2(car.x, car.z), w.lift_door().y, true)
		var seen := {}
		for i in w.houses.size():
			var h := w.houses[i]
			var inside := h.to_world(Vector3(h.door.get_center().x, 0.0, 0.45))
			inside.y = w.footing.walking_height(Vector2(inside.x, inside.z), h.to_world(Vector3.ZERO).y, true)
			if Route.find(w, car, Vector2(inside.x, inside.z), 0.45, 120000).is_empty():
				missing.append("seed %d house %d (%s): its front door from the lift" % [s, i, h.plan.type])
			for at: Vector3 in _reach(w, inside, 0.15, i).values():
				var room := h.area_at_any(h.to_local(at + Vector3.UP * 1.25))
				if room != &"":
					seen["%d:%s" % [i, room]] = true
			for level in h.rooms_by_level.size():
				for room: Dictionary in h.rooms_by_level[level]:
					rooms += 1
					if not seen.has("%d:%s" % [i, room.name]):
						missing.append("seed %d house %d (%s) %s" % [s, i, h.plan.type, room.name])
		var bad := Reach.stranded(s, true, true, false, homes_options())
		t.check(bad.is_empty(), "seed %d: no reachable spot is cut off from the lift (%d)" % [s, bad.size()])
	t.check(missing.is_empty(), "every room is walked to from the lift: %s" % str(missing.slice(0, 10)))
	t.note("%d rooms walked to" % (rooms - missing.size()))

## Every doorway of every home (the front door and each inner door) is walked straight through, both ways, from 0.6 m
## before it to 0.6 m past it: no furniture the seed places stands across a door.
func test_every_doorway_is_walked_through(t: T) -> void:
	var blocked: Array[String] = []
	var walks := 0
	for s in _seeds(t, 40, 400):
		var w := Ward.new(s, homes_options())
		w.bridge_lowered = true
		for i in w.houses.size():
			var h := w.houses[i]
			var doors: Array = h.inner_doors.duplicate()
			doors.append({"at": Vector3(h.door.get_center().x, 0, 0), "leaf": h.door, "rooms": [&"gallery", h.front_room()]})
			for d: Dictionary in doors:
				var at: Vector3 = d.at
				var leaf: AABB = d.leaf
				var across := Vector3(0, 0, 1) if leaf.size.x > leaf.size.z else Vector3(1, 0, 0)
				for way: float in [1.0, -1.0]:
					var a := h.to_world(at - across * 0.6 * way)
					var b := h.to_world(at + across * 0.6 * way)
					var from_gallery: bool = d.rooms[0] == &"gallery" and way > 0.0
					a.y = w.footing.walking_height(Vector2(a.x, a.z), h.to_world(at).y + (0.15 if from_gallery else 0.0), true)
					walks += 1
					var end := w.walk(a, Vector2(b.x - a.x, b.z - a.z))
					if Vector2(end.x - b.x, end.z - b.z).length() > 0.1:
						blocked.append("seed %d house %d (%s) %s %s" % [s, i, h.plan.type, str(d.rooms), "in" if way > 0.0 else "out"])
	t.check(walks > 0 and blocked.is_empty(), "every doorway is walked through both ways (%d walks): %s" % [walks, str(blocked.slice(0, 8))])
## Breadth-first over the Ward's walk from `start` in steps of `step`: every spot reached, by cell (heights in 25 cm
## bands, so a stair's treads are not the floor beneath them). `house` >= 0 keeps to that house's footprint.
static func _reach(w: Ward, start: Vector3, step: float, house: int) -> Dictionary:
	# Cells centred on the start's own steps (rounded, not floored), so a walk that lands exactly on a cell's edge is
	# never mistaken for the cell it came from.
	var key := func(p: Vector3) -> Vector3i: return Vector3i(roundi((p.x - start.x) / step), roundi((p.z - start.z) / step), roundi(p.y * 4.0))
	var seen := {key.call(start): start}
	var todo: Array[Vector3] = [start]
	var dirs: Array[Vector2] = [Vector2(step, 0), Vector2(-step, 0), Vector2(0, step), Vector2(0, -step)]
	while not todo.is_empty():
		var at: Vector3 = todo.pop_back()
		for d in dirs:
			var to := w.walk(at, d)
			if to.distance_to(at) < step * 0.5:
				continue
			if house >= 0:
				var local := w.houses[house].to_local(to)
				if not w.houses[house].floor_bounds.has_point(Vector2(local.x, local.z)):
					continue
			var k: Vector3i = key.call(to)
			if not seen.has(k):
				seen[k] = to
				todo.append(to)
	return seen
func test_from_every_opening_one_room_is_safe_and_the_arm_keeps_to_clear_space(t: T) -> void:
	var failing: Array[String] = []
	var through: Array[String] = []
	var openings := 0
	var routed := 0
	for s in _seeds(t, 2, 20):
		var w := Ward.new(s, homes_options())
		for i in w.houses.size():
			var h := w.houses[i]
			var solid := h.solid_boxes()
			for o: Dictionary in h.openings():
				openings += 1
				var probes := h.probes_for(o)
				var reach := h.reachable_areas(o)
				if reach.size() >= probes.size():
					failing.append("seed %d house %d (%s) %s %s" % [s, i, h.plan.type, o.kind, o.wall])
				var arm := h.make_arm_at(o)
				for room: StringName in reach:
					var route := arm._find_route(probes[room])
					if route.is_empty():
						continue
					routed += 1
					for k in range(1, route.size()):
						for b in solid:
							var hole: AABB = o.hole
							if hole.has_volume() and b.intersects(hole):
								continue
							if House.ArmSearch._hits_box(route[k - 1], route[k], b, House.ArmSearch.ARM_RADIUS):
								through.append("seed %d house %d %s %s to %s" % [s, i, o.kind, o.wall, room])
								break
	t.check(failing.is_empty(), "from every opening at least one room is out of reach: %s" % str(failing.slice(0, 8)))
	t.check(through.is_empty() and routed > 0, "the arm's %d routes never pass through a wall or tall furniture: %s" % [routed, str(through.slice(0, 8))])
	t.note("%d openings" % openings)

## RL1 (ward_lift_clear, on in the game's rooms) and the homes together: on the seeds where RL1 lowers a house of a
## homes Ward, every property above still holds, and the lift's house is never the lowest. The same tests, with the
## options and seeds switched (at most 100 seeds a test at default size; the homes inside a house do not depend on
## its height, so the seeds where heights move are the ones that matter).
func test_the_homes_hold_with_the_lift_clear(t: T) -> void:
	var seeds := lift_clear_seeds(4 if t.quick else 40)
	t.eq(seeds.size(), 4 if t.quick else 40, "enough seeds where RL1 lowers a house of a homes Ward")
	var lowest: Array[int] = []
	for s in seeds:
		var opts := Layout.options(null, true)
		opts["homes"] = 1
		var lay := Layout.generate(s, opts)
		var low := true
		for i in range(1, lay.houses.size()):
			if float(lay.houses[i].z) < float(lay.houses[0].z):
				low = false
		if low:
			lowest.append(s)
		t.check(Ward.new(s, opts).houses[1].homes(), "seed %d: the lift_clear Ward is built of homes" % s)
	t.check(lowest.is_empty(), "with the homes and lift_clear the lift's house is never the lowest: %s" % str(lowest))
	_lift_clear = true
	test_every_house_is_a_home(t)
	test_every_house_has_hides(t)
	test_every_house_has_a_room_to_crowd_round(t)
	test_every_room_is_walked_to(t)
	test_every_doorway_is_walked_through(t)
	test_from_every_opening_one_room_is_safe_and_the_arm_keeps_to_clear_space(t)
	_lift_clear = false
	t.note("lift_clear seeds %s" % str(seeds.slice(0, 8)))

func test_one_seed_one_set_of_homes(t: T) -> void:
	for s in SEEDS:
		var line := Digest.line(s, homes_options())
		t.eq(Digest.line(s, homes_options()), line, "seed %d: built twice here, the same homes" % s)
		if HOMES_GOLDEN.has(s):
			t.eq(line, HOMES_GOLDEN[s], "seed %d: the same homes as recorded" % s)
		var a := Homes.resolve({"id": 3, "style": "boarders_flat", "mirror": true}, s)
		t.eq(JSON.stringify(a), JSON.stringify(Homes.resolve({"id": 3, "style": "boarders_flat", "mirror": true}, s)), "seed %d: a plan resolves the same twice" % s)
	t.eq(HOMES_GOLDEN.size(), SEEDS.size(), "every seed has a recorded homes line")
	# And in a fresh process (tests/ward_digest.gd --homes), as every screen builds it.
	var args: Array[String] = ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", "res://tests/ward_digest.gd", "--", "--homes"]
	for s in SEEDS:
		args.append(str(s))
	var out: Array = []
	var code := OS.execute(OS.get_executable_path(), args, out, true)
	t.check(code == 0, "a fresh process ran the digest (exit %d)" % code)
	var text := "".join(out)
	for s in SEEDS:
		t.check(text.contains(Digest.line(s, homes_options())), "seed %d: a fresh process builds the same homes" % s)
	var differ := false
	for s in range(1, 12):
		if JSON.stringify(Homes.resolve({"id": 2, "style": "weavers_terrace"}, s)) != JSON.stringify(Homes.resolve({"id": 2, "style": "weavers_terrace"}, 0)):
			differ = true
	t.check(differ, "the seed moves a house's doors and furniture")

func test_the_options_on_the_wire(t: T) -> void:
	# The fourth field is RL1's lift_clear (merged first); the homes ride as a fifth, after a fourth of 0 or 1.
	var wire := Layout.to_wire(homes_options())
	t.eq(wire, [2, 110, 150, 0, 1], "the homes ride as a fifth field, after a fourth 0 (no lift_clear)")
	t.eq(Layout.from_wire(wire), homes_options(), "and come back the same")
	t.eq(Layout.to_wire(Layout.options(null)).size(), 3, "without them the three fields of today")
	t.eq(Layout.from_wire([2, 110, 150, 2]), {}, "a fourth field that is not 1 is refused")
	t.eq(Layout.from_wire([2, 110, 150, 0]), {}, "a fourth field 0 with no fifth is refused")
	# ST1's stairs ride as a sixth field 1 (tests/prop_ward_stairs.gd), so a sixth that is not 1, or a seventh, is refused.
	for wrong: Array in [[2, 110, 150, 0, 0], [2, 110, 150, 1, 2], [2, 110, 150, 2, 1], [2, 110, 150, 0, 1, 0], [2, 110, 150, 0, 1, 1, 1]]:
		t.eq(Layout.from_wire(wrong), {}, "from_wire refuses %s" % str(wrong))
	var block := {"collectionAt": 1.0, "departAt": 2.0, "bridgeLowered": false, "phase": "away", "house": -1, "startedAt": 0.0,
		"encounter": "idle", "armPoints": [], "doors": [true, true, true, true, true, true, true, true], "boarded": [], "leftBehind": [],
		"seed": 8143, "caught": [], "native": true, "layout": wire}
	var back := WardWire.decode(WardWire.encode(block))
	t.check(not back.is_empty(), "the Ward block carries the homes' layout")
	t.eq(Ward.new(8143, Layout.from_wire(back.get("layout", []))).houses[1].homes(), true, "and a screen builds the homes from it")
	for wrong: Array in [[2, 110, 150, 0, 0], [2, 110, 150, 1, 2], [2, 110, 150, 2, 1], [2, 110, 150, 0, 1, 0], [2, 110, 150, 0, 1, 1, 1], [2, 110, 150, 0]]:
		var raw := WardWire.encode(block)
		raw[14] = wrong
		t.eq(WardWire.decode(raw), {}, "a Ward block with options %s is refused" % str(wrong))

## RL1's lift_clear and WH1's homes together on the wire: each of the four combinations goes through the Ward block
## (and JSON, as the network sends it) and comes back as the host's options, and a screen builds the host's Ward.
func test_the_four_wire_combinations(t: T) -> void:
	var cases := [[false, false, [2, 110, 150]], [true, false, [2, 110, 150, 1]], [false, true, [2, 110, 150, 0, 1]],
		[true, true, [2, 110, 150, 1, 1]]]
	var digests := {}
	for c: Array in cases:
		var opts := Layout.options(null, bool(c[0]))
		if bool(c[1]):
			opts["homes"] = 1
		var name := "lift_clear %s, homes %s" % [c[0], c[1]]
		var w := Ward.new(183025962, opts)
		var block := w.snapshot()
		block["layout"] = w.layout_wire()
		t.eq(block.layout, c[2], "%s: the block's options" % name)
		var back := WardWire.decode(JSON.parse_string(JSON.stringify(WardWire.encode(block))))
		t.eq(back.get("layout"), c[2], "%s: back through JSON" % name)
		t.eq(Layout.from_wire(back.get("layout")), opts, "%s: the host's options" % name)
		t.eq(Digest.line(183025962, Layout.from_wire(back.get("layout"))), Digest.line(183025962, opts), "%s: a screen builds the host's Ward" % name)
		t.eq(Ward.new(183025962, Layout.from_wire(back.get("layout"))).houses[1].homes(), bool(c[1]), "%s: homes exactly when asked" % name)
		digests[Digest.line(183025962, opts)] = true
	t.eq(Layout.options(null, false), Layout.options(null), "options without either flag are today's")
	t.eq(digests.size(), 4, "the four combinations are four different Wards on seed 183025962 (late-2, where RL1 lowers a house)")

func test_the_flag_reaches_the_rules(t: T) -> void:
	var count := 0
	var names: Array[String] = []
	for m: Dictionary in (HostRules as Script).get_script_method_list():
		if m.name == "_init":
			count = (m.args as Array).size()
			for a: Dictionary in m.args:
				names.append(str(a.name))
	# The agreed tail (RL1 merged first): ..., voice_, ward_lift_clear_, ward_homes_, then ST1's ward_stairs_.
	t.eq(names.slice(names.size() - 4), ["voice_", "ward_lift_clear_", "ward_homes_", "ward_stairs_"] as Array[String], "ward_homes_ comes after RL1's ward_lift_clear_, followed only by ST1's ward_stairs_")
	var args: Array = [true, 1, []]
	while args.size() < count:
		args.append(false)
	args[38] = true # late_floors
	args[49] = true # ward_layout
	args[names.find("ward_homes_")] = true # ward_homes (ST1's ward_stairs_ follows it)
	t.check((HostRules.new.callv(args) as HostRules).ward_homes, "on with the seeded layout and the late floors")
	args[49] = false
	t.check(not (HostRules.new.callv(args) as HostRules).ward_homes, "never without the seeded layout")
	args[49] = true
	args[names.find("ward_homes_")] = false
	t.check(not (HostRules.new.callv(args) as HostRules).ward_homes, "off when not asked")
	t.check(not HostRules.ward_homes_on_by_arg(), "the game's rooms ask for it only with ward_homes=1")

## The screen's way-to-the-lift helper (client/ward/route.gd) and the Ward's bots (sim/ward/bots.gd) know the homes:
## from every home's farthest room a way leads to the lift, along the graph and by the walk model.
func test_the_way_to_the_lift_knows_the_homes(t: T) -> void:
	var w := Ward.new(8143, homes_options())
	w.bridge_lowered = true
	var g := Bots.build_graph(w)
	var lost: Array[String] = []
	for i in w.houses.size():
		if g.route(g.rooms[i][&"rear"], g.lift_car, true).is_empty():
			lost.append("house %d: no way on the graph" % i)
	t.check(lost.is_empty(), "every home's farthest room has a way to the lift on the graph: %s" % str(lost))
	var h := w.houses[3]
	var probe: Vector3 = h.areas[g.room[g.rooms[3][&"rear"]][1]]
	var from := h.to_world(Vector3(probe.x, 0.0, probe.z))
	from.y = w.footing.walking_height(Vector2(from.x, from.z), from.y, true)
	var ld := w.lift_door()
	var way := Route.find(w, from, Vector2(ld.x, ld.z + 0.45))
	t.check(not way.is_empty(), "the screen's helper finds a walk from a home's back room to the lift (%d points)" % way.size())
