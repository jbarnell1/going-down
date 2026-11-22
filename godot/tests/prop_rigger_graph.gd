# RR1: the Rigger's surface graph (sim/ward/rigger_graph.gd) and his openings (sim/ward/house.gd openings). Proved:
#   1. The same for a seed: built twice, the poses, their kinds and their edges are the same.
#   2. Never through anything: at every pose, and along every edge to a reach pose and a seeded spread of the others,
#      checked by dense sampling (independently of the build's
#      clearance bound: every sphere is placed at steps of at most SAMPLE metres of its own travel and measured against
#      every solid), no sphere of his body touches a solid. Over 40 seeds (2 in the quick set).
#   3. Joined: every house has at least one opening with a reach pose joined to his lair, and every opening counted as
#      reachable has its reach pose's wrist at that opening's shoulder (or within the arm's short slack of it).
#   4. The safe room, per opening: from every opening of every house (40 seeds), at least one ground-floor room is out of
#      the arm's reach; and a full search from that opening, hearing every room, never touches a player standing at
#      that room's middle (a few seeds; the house is reported if not).
# Each on today's fixed layout and on the layouts made from the seed (WG1, sim/ward/layout.gd generate_v2: houses facing
# any way), which the game's rooms play with the late floors.
extends RefCounted

const T = preload("res://tests/t.gd")
const Ward = preload("res://sim/ward/state.gd")
const G = preload("res://sim/ward/rigger_graph.gd")
const Roam = preload("res://sim/ward/roam.gd")
const House = preload("res://sim/ward/house.gd")
const SAMPLE := 0.15
const Layout = preload("res://sim/ward/layout.gd")
## The two layouts: today's fixed one, and one made from the seed (WG1) with the host's options as today's settings make them.
## WH1: and the homes (the run flag ward_homes) on the seeded layout.
## IN1: and the homes with RL1's lift_clear (both on in a game room started with ward_homes=1), on the seeds where
## lift_clear lowers a house (tests/prop_ward_homes.gd lift_clear_seeds), so the two flags are checked where they meet.
const LAYOUTS := ["fixed", "generated", "homes", "homes_lift_clear"]
const HomesProps = preload("res://tests/prop_ward_homes.gd")

static func _options(layout: String) -> Dictionary:
	if layout == "homes" or layout == "homes_lift_clear":
		var o := Layout.options(null, layout == "homes_lift_clear")
		o["homes"] = 1
		return o
	return Layout.options(null) if layout == "generated" else {}

## The seeds a check walks for a layout: 1 to `count`, or for homes_lift_clear the first `count` where it matters.
static func _seed_list(layout: String, count: int) -> Array[int]:
	if layout == "homes_lift_clear":
		return HomesProps.lift_clear_seeds(count)
	var out: Array[int] = []
	for k in count:
		out.append(1 + k)
	return out

static func _ward(seed_value: int, layout: String) -> Ward:
	return Ward.new(seed_value, _options(layout))

static func _graph(seed_value: int, layout := "fixed") -> G:
	return Roam.graph_for(_ward(seed_value, layout))

func test_the_graph_is_the_same_for_a_seed(t: T) -> void:
	for layout: String in LAYOUTS:
		for seed_value: int in (HomesProps.lift_clear_seeds(2) if layout == "homes_lift_clear" else [8143, 2]):
			var w := _ward(seed_value, layout)
			var a := G.build(w.layout, w.houses, w.lift_door()) as G
			var again := _ward(seed_value, layout)
			var b := G.build(again.layout, again.houses, again.lift_door()) as G
			t.check(a.pos.size() > 500 and a.digest() == b.digest(), "%s seed %d: built twice, the same (%d poses)" % [layout, seed_value, a.pos.size()])
			t.note("%s seed %d: %d poses, built in %d ms" % [layout, seed_value, a.pos.size(), a.build_ms])

## The smallest clearance of any sphere along an edge, sampled densely (negative: touching).
static func _edge_worst(g: G, i: int, j: int) -> float:
	var move := g.pos[i].distance_to(g.pos[j])
	var turn := g.rot[i].angle_to(g.rot[j])
	var steps := maxi(1, ceili((move + turn * G.BODY_REACH) / SAMPLE))
	var worst := INF
	# Every solid within the body's reach of any point of the edge (the rest are farther than any sphere can come).
	var among := PackedInt32Array()
	for k in g.ob_o.size():
		if g.box_distance(k, g.pos[i]) <= G.BODY_REACH + move + 0.5:
			among.append(k)
	for k in steps + 1:
		var u := float(k) / steps
		var c := g.pos[i].lerp(g.pos[j], u)
		var q := g.rot[i].slerp(g.rot[j], u)
		worst = minf(worst, _pose_worst(g, c, q, among))
	return worst

static func _pose_worst(g: G, c: Vector3, q: Quaternion, among := PackedInt32Array()) -> float:
	var worst := INF
	var list: Array = range(g.ob_o.size()) if among.is_empty() else Array(among)
	for s: Array in G.spheres(c, q):
		var p: Vector3 = s[0]
		for k: int in list:
			worst = minf(worst, g.box_distance(k, p) - float(s[1]))
	return worst

func test_never_through_anything(t: T) -> void:
	for layout: String in LAYOUTS:
		_never_through(t, layout)

func _never_through(t: T, layout: String) -> void:
	var seeds := 2 if t.quick else 40
	var per_seed := 60 if t.quick else 80
	var poses := 0
	var edges := 0
	var worst := INF
	var bad: Array[String] = []
	var kinds := {}
	for seed_value: int in _seed_list(layout, seeds):
		var g := _graph(seed_value, layout)
		for i in g.pos.size():
			if not g.joined(i):
				continue
			poses += 1
			var d := _pose_worst(g, g.pos[i], g.rot[i])
			worst = minf(worst, d)
			if d <= 0.0:
				bad.append("seed %d pose %d (%s) touches by %.3f" % [seed_value, i, G.KIND_NAMES[g.kind[i]], d])
		# Every edge from a reach pose and a line, and a seeded spread of the rest.
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_value
		var picked := 0
		for i in g.pos.size():
			if not g.joined(i):
				continue
			for j in g.adj[i]:
				if j < i:
					continue
				var special := g.kind[i] == G.REACH or g.kind[j] == G.REACH
				if not special and rng.randf() > float(per_seed) / 6000.0:
					continue
				picked += 1
				edges += 1
				var key := "%s-%s" % [G.KIND_NAMES[mini(g.kind[i], g.kind[j])], G.KIND_NAMES[maxi(g.kind[i], g.kind[j])]]
				kinds[key] = int(kinds.get(key, 0)) + 1
				var e := _edge_worst(g, i, j)
				worst = minf(worst, e)
				if e <= 0.0:
					bad.append("seed %d edge %d-%d (%s) touches by %.3f" % [seed_value, i, j, key, e])
	t.check(bad.is_empty(), "%s: no pose and no edge touches a solid: %s" % [layout, str(bad.slice(0, 6))])
	t.note("%s, %d seeds: %d joined poses and %d edges sampled every %.2f m of travel, nearest any sphere came %.3f m; edges by kind %s" % [layout, seeds, poses, edges, SAMPLE, worst, str(kinds)])

func test_every_house_is_joined_to_his_lair(t: T) -> void:
	for layout: String in LAYOUTS:
		_joined(t, layout)

func _joined(t: T, layout: String) -> void:
	var seeds := 3 if t.quick else 40
	var missing: Array[String] = []
	var openings := 0
	var joined := 0
	var slack := 0.0
	var unjoined := {}
	for seed_value: int in _seed_list(layout, seeds):
		var w := _ward(seed_value, layout)
		var g := _graph(seed_value, layout)
		for h in w.houses.size():
			var ours := g.openings_of(h)
			openings += w.houses[h].openings().size()
			joined += ours.size()
			if ours.is_empty():
				missing.append("seed %d house %d (%s)" % [seed_value, h, w.layout.houses[h].style])
			for o: Dictionary in w.houses[h].openings():
				if not ours.has(int(o.index)):
					var why := "%s%s" % [o.kind, " upstairs" if int(o.get("storey", 0)) > 0 else ""]
					var valid := 0
					for r: Dictionary in g._reach_candidates[h]:
						if int(r.opening.index) == int(o.index):
							valid += 1
					why += " (no reach pose fits)" if valid == 0 else " (reach poses, none joined)"
					unjoined[why] = int(unjoined.get(why, 0)) + 1
			for r: Dictionary in g.reach[h]:
				var wrist := G.wrist_at(g.pos[int(r.node)], g.rot[int(r.node)])
				slack = maxf(slack, wrist.distance_to(r.shoulder))
				if not g.joined(int(r.node)):
					missing.append("seed %d house %d: an unjoined reach pose listed" % [seed_value, h])
	t.check(missing.is_empty(), "%s: every house has an opening he can reach from his lair: %s" % [layout, str(missing.slice(0, 8))])
	t.check(slack <= 1.01, "%s: every reach pose has his wrist at its opening (furthest %.2f m, the arm's slack 1.0)" % [layout, slack])
	t.note("%s, %d seeds: %d of %d openings reachable (%.0f%%); not reachable, by cause: %s" % [layout, seeds, joined, openings, 100.0 * joined / maxf(1, openings), str(unjoined)])

func test_from_every_opening_one_room_is_safe(t: T) -> void:
	for layout: String in LAYOUTS:
		_safe_room(t, layout)

func _safe_room(t: T, layout: String) -> void:
	var seeds := 3 if t.quick else 40
	var failing: Array[String] = []
	var shortened := 0
	var checked := 0
	for seed_value: int in _seed_list(layout, seeds):
		var w := _ward(seed_value, layout)
		for h in w.houses.size():
			var fixture := w.houses[h]
			for o: Dictionary in fixture.openings():
				checked += 1
				var reach := fixture.reachable_areas(o)
				if fixture.opening_reach(o) < House.ArmSearch.REACH:
					shortened += 1
				if reach.size() >= fixture.probes_for(o).size():
					failing.append("seed %d house %d (%s) %s %d" % [seed_value, h, w.layout.houses[h].style, o.kind, int(o.side)])
	t.check(failing.is_empty(), "%s: from every opening at least one room is out of reach: %s" % [layout, str(failing.slice(0, 8))])
	# Behaviour: a full search from each opening, every room heard, never touches a player in the safe room.
	var touched: Array[String] = []
	var searches := 0
	var searched: Array = [8143] if t.quick else [8143, 1, 2, 3]
	if layout == "homes_lift_clear":
		searched = HomesProps.lift_clear_seeds(searched.size())
	for seed_value: int in searched:
		var w := _ward(seed_value, layout)
		for h in w.houses.size():
			var fixture := w.houses[h]
			for o: Dictionary in fixture.openings():
				var reach := fixture.reachable_areas(o)
				var probes := fixture.probes_for(o)
				for area: StringName in probes:
					if reach.has(area):
						continue
					searches += 1
					var arm := fixture.make_arm_at(o)
					var torso: Vector3 = probes[area]
					for heard: StringName in probes:
						arm.hear(heard)
					var steps := 0
					while steps < 1200:
						steps += 1
						arm.step(0.05, {"p": torso}, true)
						if not arm.contacts.is_empty():
							touched.append("seed %d house %d %s %d: %s" % [seed_value, h, o.kind, int(o.side), area])
							break
						if arm.phase == &"idle":
							break
	t.check(touched.is_empty() and searches > 0, "%s: a full search from an opening never touches a player in its safe room (%d searches): %s" % [layout, searches, str(touched)])
	t.note("%s: %d openings over %d seeds; %d had the arm shortened so that one room is safe" % [layout, checked, seeds, shortened])
