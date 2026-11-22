# WH1b: the Rigger's arm finds its own bend points (sim/ward/arm.gd corner_guides: each corner of every wall and tall
# piece of furniture at the arm's height, stood off by the palm's size), in place of points placed by hand at each
# doorway and window; its clear lines are worked out once (build_graph). The approved design (21 Nov): "make the arm's
# bend points automatic from walls and furniture ... do NOT move his rules onto physics". The North Star: "Residents
# always obey their rule"; the design: "The hand must physically travel there and touch a player through clear space.
# Walls, shut doors and the floor obstruct the limb along its full length."
#   1. on today's houses (fixed and seeded layouts), the automatic points find a route to every room the hand-placed
#      ones reach, from every opening;
#   2. on the homes, a route found from the graph is the route found segment by segment (the graph is only a cache);
#   3. on the homes, no route passes through a wall, a slab or tall furniture, and a shut inner door stops it.
extends RefCounted

const T = preload("res://tests/t.gd")
const Ward = preload("res://sim/ward/state.gd")
const Layout = preload("res://sim/ward/layout.gd")
const House = preload("res://sim/ward/house.gd")
const ArmSearch = preload("res://sim/ward/arm.gd")

static func _homes() -> Dictionary:
	var o := Layout.options(null)
	o["homes"] = 1
	return o

## An arm over the same walls, door and rooms as `arm`, with bend points worked out from its walls.
static func _automatic(arm: ArmSearch, fixture: House, opening: Dictionary) -> ArmSearch:
	var hole: AABB = opening.hole
	var mouth: Vector3 = hole.get_center() if hole.has_volume() else fixture.door.get_center()
	var inside := fixture.floor_bounds
	var keep := func(p: Vector3) -> bool:
		return inside.has_point(Vector2(p.x, p.z)) or Vector2(p.x - mouth.x, p.z - mouth.z).length() < 1.0
	var y: float = (opening.shoulder as Vector3).y
	var auto := ArmSearch.new(arm._shoulder, arm._door, arm._walls, ArmSearch.corner_guides(arm._walls, y, keep), arm._probes, 1, arm._enters_by_door)
	return auto

func test_automatic_points_reach_wherever_the_hand_placed_ones_did(t: T) -> void:
	var lost: Array[String] = []
	var routes := 0
	var longer := 0.0
	for layout: Dictionary in [{}, Layout.options(null)]:
		for s: int in ([8143, 26] if t.quick else [8143, 26, 0, 31827, 1, 2, 3, 4]):
			var w := Ward.new(s, layout)
			for i in w.houses.size():
				var h := w.houses[i]
				for o: Dictionary in h.openings():
					var old := h.make_arm_at(o)
					old.reach = 1000.0
					var auto := _automatic(old, h, o)
					auto.reach = 1000.0
					for area: StringName in old._probes:
						var a := old._find_route(old._probes[area])
						if a.is_empty():
							continue
						routes += 1
						var b := auto._find_route(old._probes[area])
						if b.is_empty():
							lost.append("seed %d house %d %s %d: %s" % [s, i, o.kind, int(o.side), area])
						else:
							longer = maxf(longer, _length(b) - _length(a))
	t.check(lost.is_empty() and routes > 0, "the automatic points reach every room the hand-placed ones reach (%d routes): %s" % [routes, str(lost.slice(0, 8))])
	t.note("%d routes; the automatic route is at most %.2f m longer" % [routes, longer])

static func _length(route: PackedVector3Array) -> float:
	var out := 0.0
	for k in range(1, route.size()):
		out += route[k - 1].distance_to(route[k])
	return out

func test_the_graph_finds_the_route_a_full_search_finds(t: T) -> void:
	var differ: Array[String] = []
	var compared := 0
	for s: int in ([8143] if t.quick else [8143, 26, 0, 31827]):
		var w := Ward.new(s, _homes())
		for i in w.houses.size():
			var h := w.houses[i]
			for o: Dictionary in h.openings():
				var cached := h.make_arm_at(o)
				var plain := h.make_arm_at(o)
				plain.use_graph(PackedInt32Array())
				for area: StringName in cached._probes:
					compared += 1
					var a := cached._find_route(cached._probes[area])
					var b := plain._find_route(plain._probes[area])
					if a != b:
						differ.append("seed %d house %d %s %s: %s" % [s, i, o.kind, o.wall, area])
	t.check(differ.is_empty() and compared > 0, "the graph's routes are the full search's (%d compared): %s" % [compared, str(differ.slice(0, 8))])

func test_no_route_through_anything_and_a_shut_door_stops_it(t: T) -> void:
	var through: Array[String] = []
	var stopped := 0
	var tried := 0
	for s: int in ([8143, 26] if t.quick else [8143, 26, 0, 31827, 1, 2, 3, 4, 5, 6]):
		var w := Ward.new(s, _homes())
		for i in w.houses.size():
			var h := w.houses[i]
			var solid := h.solid_boxes()
			for o: Dictionary in h.openings():
				var arm := h.make_arm_at(o)
				arm.reach = 1000.0
				var hole: AABB = o.hole
				for area: StringName in arm._probes:
					var route := arm._find_route(arm._probes[area])
					for k in range(1, route.size()):
						for b in solid:
							if hole.has_volume() and b.intersects(hole):
								continue
							if b.position.y - ArmSearch.PALM_RADIUS > route[k].y or b.end.y + ArmSearch.PALM_RADIUS < route[k].y:
								continue
							if ArmSearch._hits_box(route[k - 1], route[k], b, ArmSearch.ARM_RADIUS):
								through.append("seed %d house %d %s %s to %s" % [s, i, o.kind, o.wall, area])
								break
					# Shut every inner door the route passes: no route then goes that way.
					var shut := PackedByteArray()
					shut.resize(h.inner_doors.size())
					var crossed := false
					for d in h.inner_doors.size():
						var leaf: AABB = h.inner_doors[d].leaf
						var hits := false
						for k in range(1, route.size()):
							if ArmSearch._hits_box(route[k - 1], route[k], leaf, ArmSearch.PALM_RADIUS):
								hits = true
						shut[d] = 0 if hits else 1
						crossed = crossed or hits
					if not crossed:
						continue
					tried += 1
					arm.inner_doors_open(shut)
					var again := arm._find_route(arm._probes[area])
					var leaks := false
					for d in h.inner_doors.size():
						if shut[d] == 0:
							for k in range(1, again.size()):
								if ArmSearch._hits_box(again[k - 1], again[k], h.inner_doors[d].leaf, ArmSearch.PALM_RADIUS):
									leaks = true
					if not leaks:
						stopped += 1
					else:
						through.append("seed %d house %d: through a shut door to %s" % [s, i, area])
					var open := PackedByteArray()
					open.resize(h.inner_doors.size())
					open.fill(1)
					arm.inner_doors_open(open)
	t.check(through.is_empty(), "no route passes through a wall, a slab, tall furniture or a shut door: %s" % str(through.slice(0, 8)))
	t.check(tried > 0 and stopped == tried, "a shut inner door stops every route that went through it (%d of %d)" % [stopped, tried])
