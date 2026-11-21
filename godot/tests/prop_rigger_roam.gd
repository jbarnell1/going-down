# RR1: the Rigger as a solid creature crawling the Hanging Ward (sim/ward/roam.gd on his surface graph,
# sim/ward/rigger_graph.gd; the run flag rigger_roam). Proved here:
#   1. With the flag off nothing changes: the host's Ward with the flag given false is the same, tick by tick, as one
#      never told of it, and its snapshot carries no "rigger" block.
#   2. A noise in a house brings him along the graph to a reach pose of that house's chosen opening, where his arm
#      searches from that opening; never through anything (every pose he passes is a graph pose or between two joined).
#   3. After a search a noise at another house brings him there straight, not through his lair.
#   4. Heard before seen: over many seeds, the hand never enters a room sooner than 3.35 s (today's warning and climb)
#      after the loaded line, and every walkway and house he goes onto is heard taking his weight at least 0.85 s (today's
#      warning before he is drawn) before he is on it.
#   5. The chase: he never moves to within the gap of the player he chases; when it ends he rears and, after the pause,
#      takes a player who is still out of doors and never one who is in a house; a player who gets into a house during
#      the pause is not taken.
#   6. His body is solid: a step into it is refused, a step out of it is not; and from any chase a way into some house
#      stays open to the player he chases.
#   7. Two screens agree with the host on where he is (through the real room, a lossy link), and on the chase's times.
#   8. settings_proof (tests/prop_settings.gd test_rigger_roam_numbers): every new rigger.* row moves what it names.
extends RefCounted

const T = preload("res://tests/t.gd")
const Ward = preload("res://sim/ward/state.gd")
const Roam = preload("res://sim/ward/roam.gd")
const G = preload("res://sim/ward/rigger_graph.gd")
const House = preload("res://sim/ward/house.gd")
const Settings = preload("res://sim/settings.gd")
const Bots = preload("res://sim/ward/bots.gd")
const Host = preload("res://net/host.gd")
const HostRules = preload("res://net/host_rules.gd")
const Client = preload("res://net/client.gd")
const Transport = preload("res://net/transport.gd")
const Move = preload("res://sim/move.gd")
const Run = preload("res://sim/run.gd")
const SEED := 8143
const DT := 0.05

static func _ward(given: Dictionary = {}, seed_value := SEED, roam := true) -> Ward:
	var w := Ward.new(seed_value)
	w.tuning = Settings.make(given) if not given.is_empty() else null
	w.crew_size = 4
	if roam:
		w.enable_roam()
	w.leave(0.0)
	return w

static func _room(w: Ward, h: int, area: StringName) -> Vector3:
	var a: Vector3 = w.houses[h].areas[area]
	return w.houses[h].to_world(Vector3(a.x, 0.0, a.z))

## A house with an opening joined to his lair, other than `not_this`.
static func _house(w: Ward, not_this := -1) -> int:
	for i in range(1, w.houses.size()):
		if i != not_this and not w.roam.g.openings_of(i).is_empty():
			return i
	return 0

## Steps from `from` for `seconds`; `rows.call(now)` gives the crew. All events.
static func _run(w: Ward, from: float, seconds: float, rows: Callable, watch := Callable()) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var now := from
	while now < from + seconds - 1e-6:
		now += DT
		out.append_array(w.step(now, DT, 30.0, rows.call(now)))
		if watch.is_valid():
			watch.call(now)
	return out

static func _kinds(events: Array[Dictionary], kind: StringName) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in events:
		if e.kind == kind:
			out.append(e)
	return out

static var _nobody := func(_n: float) -> Dictionary: return {}

## Waits until he searches (or `limit` s); returns the time, or -1.
static func _until(w: Ward, from: float, limit: float, encounter: StringName, rows := _nobody) -> float:
	var now := from
	while now < from + limit:
		now += DT
		w.step(now, DT, 30.0, rows.call(now))
		if w.encounter == encounter:
			return now
	return -1.0

# ---------------------------------------------------------------------------------------------
# 1. Flag off.

func test_flag_off_changes_nothing(t: T) -> void:
	var lines: Array[String] = []
	for pass_ in 2:
		var rules := HostRules.new(false, 1, []) if pass_ == 0 else HostRules.new(false, 1, [], false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false)
		t.check(not rules.rigger_roam, "the flag is off (%d)" % pass_)
		var names: Array[String] = ["one"]
		var net := Transport.MemoryNetwork.new("rr1-off", Transport.LinkConfig.make(0.0, 0.0, 0.0, 0.0, 0.0, 0.0))
		var host := Host.new(net.connect_peer("host"), "rr1-off", names, 0.0, Callable(rules, "prepare"), Callable(rules, "step"), names)
		host.start_ward_review(SEED)
		t.check(host._ward_review.roam == null, "no crawling Rigger with the flag off")
		var w := host._ward_review
		w.leave(0.0)
		var h := 1
		var at := _room(w, h, &"entry")
		var digest := PackedStringArray()
		var now := 0.0
		for k in 400:
			now += DT
			var rows := {"one": {"position": at, "sprint": k < 3}}
			var evs := w.step(now, DT, 30.0, rows)
			var snap := w.snapshot(now)
			t.check(not snap.has("rigger"), "no rigger block with the flag off") if k == 0 else null
			digest.append("%s|%s" % [JSON.stringify(snap), JSON.stringify(evs)])
		lines.append("|".join(digest))
	t.check(lines[0] == lines[1], "the Ward is the same, tick by tick, with the flag given false and not given")

# ---------------------------------------------------------------------------------------------
# 2-3. To the right house; house to house.

func test_he_comes_along_the_graph_to_the_house_heard(t: T) -> void:
	var w := _ward()
	var h := _house(w)
	var at := _room(w, h, &"entry")
	var evs := _run(w, 0.0, 0.1, func(n: float) -> Dictionary: return {"p1": {"position": at, "sprint": n < 0.1}})
	var loaded := _kinds(evs, &"line_loaded")
	t.check(loaded.size() == 1 and int(loaded[0].house) == h, "a sprint in house %d loads the line and sends him there: %s" % [h, str(loaded)])
	var started := _until(w, 0.1, 60.0, &"searching")
	t.check(started > 0.0 and w.resident_house == h, "he reaches house %d and searches it (%.2f s)" % [h, started])
	var node := w.roam.from_node
	var reach := w.roam.g.reach_nodes(h, w.roam.opening)
	t.check(reach.has(node) and w.roam.to_node < 0, "he is on a reach pose of the opening he chose (%d in %s)" % [node, str(reach)])
	var fixture: House = w.houses[h]
	var o: Dictionary = fixture.openings()[w.roam.opening]
	t.check(w.arm != null and w.arm.points[0].is_equal_approx(o.shoulder), "his arm leaves from that opening's shoulder")
	t.check(G.wrist_at(w.roam.at, w.roam.turn).distance_to(fixture.to_world(o.shoulder)) < 1.1, "his wrist is at the opening (%.2f m)" % G.wrist_at(w.roam.at, w.roam.turn).distance_to(fixture.to_world(o.shoulder)))
	t.note("house %d: %s %d; line loaded at 0.05, searching at %.2f" % [h, o.kind, int(o.side), started])

func test_he_goes_house_to_house_without_the_lair(t: T) -> void:
	var w := _ward({&"rigger.linger": 30.0})
	var a := _house(w)
	var b := _house(w, a)
	_run(w, 0.0, 0.1, func(n: float) -> Dictionary: return {"p1": {"position": _room(w, a, &"entry"), "sprint": n < 0.1}})
	var at := _until(w, 0.1, 60.0, &"searching")
	t.check(at > 0.0 and w.resident_house == a, "first at house %d" % a)
	var done := _until(w, at, 60.0, &"lingering")
	t.check(done > 0.0, "the search ends and he stays (%.2f)" % done)
	var lair_seen := false
	var off_graph := 0
	var evs := _run(w, done, 0.1, func(n: float) -> Dictionary: return {"p1": {"position": _room(w, b, &"entry"), "sprint": n < done + 0.1}})
	t.check(_kinds(evs, &"line_loaded").size() == 1, "a noise at house %d is heard" % b)
	var now := done + 0.1
	var reached := -1.0
	while now < done + 90.0 and reached < 0.0:
		now += DT
		w.step(now, DT, 30.0, {})
		var g := w.roam.g
		if g.kind[w.roam.from_node] == G.LAIR:
			lair_seen = true
		if w.roam.to_node >= 0 and not g.adj[w.roam.from_node].has(w.roam.to_node):
			off_graph += 1
		if w.encounter == &"searching" and w.resident_house == b:
			reached = now
	t.check(reached > 0.0, "he reaches house %d (%.2f)" % [b, reached])
	t.check(not lair_seen, "and never goes through his lair on the way")
	t.check(off_graph == 0, "every move is along a joined edge of his graph (%d ticks off it)" % off_graph)

# ---------------------------------------------------------------------------------------------
# 4. Heard before seen.

func test_every_approach_is_heard_first(t: T) -> void:
	var seeds := 4 if t.quick else 40
	var shortest_reach := INF
	var shortest_surface := INF
	var trips := 0
	var surfaces := 0
	var bad: Array[String] = []
	for k in seeds:
		var seed_value := 1 + k
		var w := _ward({}, seed_value)
		var clock := 1.0
		for target: int in [_house(w), _house(w, _house(w))]:
			var at := _room(w, target, &"middle")
			var loaded_at := -1.0
			var cues := {}
			var entered := {}
			var now := clock
			var start := now
			var evs := w.step(now + DT, DT, 30.0, {"p1": {"position": at, "sprint": true}})
			now += DT
			for e in evs:
				if e.kind == &"line_loaded":
					loaded_at = float(e.at)
			if loaded_at < 0.0:
				continue
			var searching_at := -1.0
			while now < start + 90.0:
				now += DT
				for e in w.step(now, DT, 30.0, {}):
					if e.kind == &"weight":
						var key := "walkway:%d" % int(e.bridge) if e.surface == &"walkway" else ("house:%d" % int(e.house) if e.surface == &"house" else "")
						if key != "" and not cues.has(key):
							cues[key] = float(e.at)
				var n := w.roam.from_node
				var g := w.roam.g
				var key2 := ""
				if g.bridge_of[n] >= 0:
					key2 = "walkway:%d" % g.bridge_of[n]
				elif g.house_of[n] >= 0 and g.kind[n] != G.LINE and g.kind[n] != G.LAIR:
					key2 = "house:%d" % g.house_of[n]
				if key2 != "" and not entered.has(key2):
					entered[key2] = now
				if w.encounter == &"searching":
					searching_at = now
					break
			if searching_at < 0.0:
				bad.append("seed %d house %d: never searched" % [seed_value, target])
				continue
			trips += 1
			shortest_reach = minf(shortest_reach, searching_at - loaded_at)
			for key: String in entered:
				surfaces += 1
				var cue: float = float(cues.get(key, INF))
				var lead: float = float(entered[key]) - minf(cue, loaded_at if key == "house:%d" % target else INF)
				shortest_surface = minf(shortest_surface, lead)
				if lead < Ward.WARN_SECONDS - 1e-6:
					bad.append("seed %d: %s entered %.2f s after its cue" % [seed_value, key, lead])
			clock = now + 1.0
			# Home again for the next trip.
			w.roam.from_node = w.roam.g.lair
			w.roam.to_node = -1
			w.roam.trip = &""
			w.roam.at = w.roam.g.pos[w.roam.g.lair]
			w.encounter = &"idle"
			w.arm = null
			w.resident_house = -1
	t.check(bad.is_empty(), "every approach heard first: %s" % str(bad.slice(0, 6)))
	t.check(shortest_reach >= Roam.REACH_LEAD - 1e-6, "the hand never in a room sooner than %.2f s after the loaded line (shortest %.2f)" % [Roam.REACH_LEAD, shortest_reach])
	t.note("%d trips over %d seeds: line to search at least %.2f s; %d surfaces entered, each heard at least %.2f s first" % [trips, seeds, shortest_reach, surfaces, shortest_surface])

## A noise in a room his arm cannot reach from the opening he searches from moves him to an opening that reaches it,
## heard first, the hand in no sooner than REACH_LEAD after that cue.
func test_he_changes_opening_for_a_room_he_cannot_reach(t: T) -> void:
	var found := false
	for seed_value: int in [8143, 1, 2, 3, 4, 5, 6, 7]:
		for h in range(1, 8):
			var w := _ward({}, seed_value)
			var fixture: House = w.houses[h]
			var joined := w.roam.g.openings_of(h)
			if joined.size() < 2:
				continue
			w.hear_at(fixture.to_world(fixture.areas[&"entry"]), 0.05)
			var at := _until(w, 0.05, 60.0, &"searching")
			if at < 0.0 or w.resident_house != h:
				continue
			var first: Dictionary = fixture.openings()[w.roam.opening]
			var target: StringName = &""
			var second := -1
			for index in joined:
				if index == int(first.index):
					continue
				for area in fixture.reachable_areas(fixture.openings()[index]):
					if not fixture.reachable_areas(first).has(area):
						target = area
						second = index
			if second < 0:
				continue
			found = true
			var cue_at := -1.0
			var moved_at := -1.0
			var now := at
			var probe: Vector3 = fixture.probes_for(fixture.openings()[second])[target]
			w.hear_at(fixture.to_world(probe - Vector3.UP * House.ARM_HEIGHT), now)
			while now < at + 60.0:
				now += DT
				for e in w.step(now, DT, 30.0, {}):
					if e.kind == &"weight" and cue_at < 0.0:
						cue_at = float(e.at)
				if w.encounter == &"searching" and w.roam.opening != int(first.index):
					moved_at = now
					break
			t.check(cue_at > 0.0 and moved_at > 0.0, "seed %d house %d: he moves from the %s %d to another opening for the %s (cue %.2f, searching %.2f)" % [seed_value, h, first.kind, int(first.side), target, cue_at, moved_at])
			t.check(fixture.reachable_areas(fixture.openings()[w.roam.opening]).has(target), "and its arm reaches the %s" % target)
			t.check(moved_at - cue_at >= Roam.REACH_LEAD - 1e-6, "the hand is in no sooner than %.2f s after his weight shifts (%.2f)" % [Roam.REACH_LEAD, moved_at - cue_at])
			t.note("seed %d house %d: %s %d to opening %d for the %s; weight %.2f, searching %.2f" % [seed_value, h, first.kind, int(first.side), w.roam.opening, target, cue_at, moved_at])
			break
		if found:
			break
	t.check(found, "a house with two joined openings reaching different rooms was found")

## Stage 2: the hand follows the player it hears: a noise at a point in a room it reaches sends the hand to that point
## (not the room's middle), and a player standing there is taken.
func test_the_hand_goes_where_the_player_was_heard(t: T) -> void:
	var w := _ward()
	var h := _house(w)
	var fixture: House = w.houses[h]
	w.hear_at(fixture.to_world(fixture.areas[&"entry"]), 0.05)
	var at := _until(w, 0.05, 60.0, &"searching")
	var o: Dictionary = fixture.openings()[w.roam.opening]
	var reach := fixture.reachable_areas(o)
	var room: StringName = reach[-1]
	var probe: Vector3 = fixture.probes_for(o)[room]
	# A point in that room 0.6 m from its middle, across the room, where the player stands.
	var aside := Vector3(0.6 if probe.x < 0.0 else -0.6, 0.0, 0.0)
	var feet := fixture.to_world(Vector3(probe.x, probe.y - House.ARM_HEIGHT, probe.z) + aside)
	t.check(fixture.area_at_any(fixture.to_local(feet + Vector3.UP * 1.25)) == room, "the player's spot is in the %s" % room)
	var now := at
	var ends := PackedVector3Array()
	var caught := false
	w.hear_at(feet, now)
	while now < at + 40.0 and not caught:
		now += DT
		for e in w.step(now, DT, 30.0, {"p1": {"position": feet, "creep": true}}):
			if e.kind == &"contact":
				caught = true
		if w.arm != null and w.arm.phase == &"probing" and w.arm.search_area == room:
			ends.append(fixture.to_world(w.arm.points[-1]))
	var nearest := INF
	for p in ends:
		nearest = minf(nearest, p.distance_to(feet + Vector3.UP * House.ARM_HEIGHT))
	t.check(caught or nearest < 0.3, "the hand went to the player where they were heard (nearest %.2f m; taken %s)" % [nearest, caught])

## Stage 2: a player upstairs is heard in their room there; he comes to an upper window whose arm reaches that room,
## heard first, and the hand reaches upstairs.
func test_he_reaches_upstairs_through_an_upper_window(t: T) -> void:
	var found := false
	for seed_value: int in [8143, 1, 2, 3, 4, 5, 6, 7, 8, 9]:
		var w := _ward({}, seed_value)
		for h in range(1, w.houses.size()):
			var fixture: House = w.houses[h]
			var target := -1
			var room: StringName = &""
			for index in w.roam.g.openings_of(h):
				var o: Dictionary = fixture.openings()[index]
				if int(o.get("storey", 0)) > 0 and not fixture.reachable_areas(o).is_empty():
					target = index
					room = fixture.reachable_areas(o)[0]
					break
			if target < 0:
				continue
			var probe: Vector3 = fixture.probes_for(fixture.openings()[target])[room]
			var feet := fixture.to_world(Vector3(probe.x, probe.y - House.ARM_HEIGHT, probe.z))
			t.check(fixture.area_at_any(fixture.to_local(feet + Vector3.UP * 1.25)) == room, "upstairs spot in %s" % room)
			var loaded := -1.0
			var searching := -1.0
			var caught := false
			var now := 0.0
			while now < 90.0 and not caught:
				now += DT
				for e in w.step(now, DT, 30.0, {"p1": {"position": feet, "sprint": now < 0.2}}):
					if e.kind == &"line_loaded" and loaded < 0.0:
						loaded = float(e.at)
					if e.kind == &"contact":
						caught = true
				if w.encounter == &"searching" and searching < 0.0:
					searching = now
			var used: Dictionary = fixture.openings()[w.roam.opening] if w.roam.opening >= 0 else {}
			t.check(loaded > 0.0 and searching - loaded >= Roam.REACH_LEAD - 1e-6, "seed %d house %d: heard upstairs, the hand in no sooner than %.2f s (%.2f)" % [seed_value, h, Roam.REACH_LEAD, searching - loaded])
			t.check(int(used.get("storey", 0)) > 0, "he searches from an upper window (%s)" % str(used.get("storey", -1)))
			t.check(caught, "and his hand reaches the player upstairs in the %s" % room)
			t.note("seed %d house %d: upstairs %s through upper window %d; loaded %.2f, searching %.2f" % [seed_value, h, room, w.roam.opening, loaded, searching])
			found = true
			break
		if found:
			break
	t.check(found, "a house with a reachable upper window was found")

# ---------------------------------------------------------------------------------------------
# 5. The chase.

## A chase near him: a noise (a flare's burst) in house h brings him to it while the player waits quietly on the
## gallery behind it; once he has searched and stays, the player sprints away out of doors for 3 s and stops (or goes
## into the house at `goes_in_at` seconds after the sprint began).
static func _chase_scene(w: Ward, h: int, goes_in_at := -1.0) -> Dictionary:
	var fixture: House = w.houses[h]
	var depth := fixture.floor_bounds.size.y
	var back := fixture.to_world(Vector3(0, 0.15, depth + 0.8))
	# Away from the Ward's middle, out over the void (never towards another house).
	var middle := Vector3.ZERO
	for site: Dictionary in w.layout.houses:
		middle += Vector3(float(site.x), 0.0, float(site.y)) / float(w.layout.houses.size())
	var away := Vector3(back.x - middle.x, 0.0, back.z - middle.z).normalized()
	var inside := fixture.to_world(Vector3(0, 0, depth * 0.5))
	var out := {"min_gap": INF, "moved_inside_gap": false, "caught": false, "rear": -1.0, "contact": -1.0, "chase": -1.0, "reach_at": -1.0}
	var now := 0.05
	w.hear_at(fixture.to_world(fixture.areas[&"entry"]), now)
	var quiet := {"p1": {"position": back, "creep": true}}
	while now < 90.0 and w.encounter != &"lingering":
		now += DT
		w.step(now, DT, 30.0, quiet)
	out["near_start"] = now
	var t0 := now
	var prev := w.roam.at
	var target := back
	while now < t0 + 40.0:
		now += DT
		var k := now - t0
		var sprint := k < 3.0
		var run := back + away * 5.0 * clampf(k, 0.0, 3.0)
		target = run if goes_in_at < 0.0 or k < goes_in_at else inside
		var evs := w.step(now, DT, 30.0, {"p1": {"position": target, "sprint": sprint}})
		for e in evs:
			if e.kind == &"chase" and out.chase < 0.0:
				out.chase = now
			if e.kind == &"rear":
				out.rear = float(e.at)
				out.reach_at = float(e.reach_at)
			if e.kind == &"contact":
				out.contact = float(e.at)
				out.caught = true
		if w.encounter == &"chasing":
			var torso := target + Vector3.UP * 1.25
			var d := w.roam.at.distance_to(torso)
			out.min_gap = minf(out.min_gap, d)
			if d < Settings.f(w.tuning, &"rigger.chase_gap", Roam.CHASE_GAP) - 1e-6 and d < prev.distance_to(torso) - 1e-6:
				out.moved_inside_gap = true
		prev = w.roam.at
		if out.contact > 0.0 or (out.rear > 0.0 and now > float(out.reach_at) + 0.5):
			break
	out["t0"] = t0
	return out

## A loud player who stays put (fidgeting, so never still) right beside a pose he can reach: he comes up to the gap
## and no nearer, over many seeds.
func test_the_chase_never_closes_inside_the_gap(t: T) -> void:
	var nearest := INF
	var closed := 0
	var chases := 0
	for seed_value: int in ([8143, 1] if t.quick else [8143, 1, 2, 3, 4, 5, 6, 7]):
		var w := _ward({}, seed_value)
		var h := _house(w)
		var fixture: House = w.houses[h]
		var quiet := {"p1": {"position": fixture.to_world(Vector3(0, 0.15, -0.8)), "creep": true}}
		w.hear_at(fixture.to_world(fixture.areas[&"entry"]), 0.05)
		var now := _until(w, 0.05, 90.0, &"lingering", func(_n: float) -> Dictionary: return quiet)
		var g := w.roam.g
		# A pose of his graph 10 to 20 m away, out of doors; the player stands with their middle on it.
		var spot := Vector3.INF
		for i in g.pos.size():
			var d := g.pos[i].distance_to(w.roam.at)
			if g.joined(i) and d > 10.0 and d < 20.0 and g.kind[i] != G.LAIR and w.roam.house_holding(g.pos[i] - Vector3.UP * 1.25) < 0:
				spot = g.pos[i] - Vector3.UP * 1.25
				break
		if spot == Vector3.INF:
			continue
		var gap := Roam.CHASE_GAP
		var t0 := now
		var was := w.roam.at
		while now < t0 + 12.0:
			now += DT
			var feet := spot + Vector3(0.2 * sin(now * 9.0), 0, 0)
			w.step(now, DT, 30.0, {"p1": {"position": feet, "sprint": true}})
			if w.encounter == &"chasing":
				chases += 1
				var torso := feet + Vector3.UP * 1.25
				var d := w.roam.at.distance_to(torso)
				nearest = minf(nearest, d)
				# His own move this tick brought him inside the gap (the player's fidget may bring them nearer him).
				if d < gap - 1e-6 and d < was.distance_to(torso) - 1e-6:
					closed += 1
			was = w.roam.at
	t.check(chases > 0 and closed == 0, "he never moves within the gap of a player he chases (%d ticks that did; nearest %.2f m with their fidget, the gap %.1f; %d ticks)" % [closed, nearest, Roam.CHASE_GAP, chases])
	t.check(nearest <= Roam.CHASE_GAP + 1.5, "and he does come up to it (nearest %.2f m)" % nearest)

## With the web on (WC1), a player he takes, by his search's hand or by the grab after a chase, is carried and hung at a
## hang point like any catch; and the lift's call at the far house still brings him (rigger.call_heard), on his graph.
func test_his_catches_go_to_the_web_and_the_call_brings_him(t: T) -> void:
	var w := _ward()
	w.web = true
	var h := _house(w)
	var r := _chase_scene(w, h)
	t.check(r.caught and w.webbed.has("p1"), "taken after a chase, the player is carried into the web")
	t.check(int(w.webbed.get("p1", {}).get("point", -1)) >= 0 and float(w.webbed.get("p1", {}).get("hangAt", -1.0)) >= float(r.contact), "at a hang point, hung after the carry")
	var w2 := _ward()
	w2.web = true
	var h2 := _house(w2)
	var caught := false
	var now := 0.0
	var spot := _room(w2, h2, &"entry")
	while now < 60.0 and not caught:
		now += DT
		for e in w2.step(now, DT, 30.0, {"p1": {"position": spot, "sprint": now < 0.2}}):
			if e.kind == &"contact":
				caught = true
				t.check(e.has("point") and w2.webbed.has("p1"), "taken by his search's hand, the player goes to the web too")
	t.check(caught, "his search took the player who stayed")
	var w3 := _ward()
	var evs := w3.hear_loud(w3.station, 1.0, Settings.f(null, &"rigger.call_heard", Ward.CALL_HEARD))
	t.check(_kinds(evs, &"line_loaded").size() == 1 and w3.resident_house == w3.station_house and w3.roam.trip == &"house", "the lift's call at house %d brings him there along his graph" % w3.station_house)

func test_the_chase_keeps_its_gap_and_the_reach_takes_only_those_outside(t: T) -> void:
	var w := _ward()
	var h := _house(w)
	var r := _chase_scene(w, h)
	t.check(r.chase > 0.0, "sprinting out of doors starts a chase (%.2f)" % r.chase)
	t.check(not r.moved_inside_gap, "he never moves to within the gap (nearest %.2f m)" % r.min_gap)
	t.check(r.rear > 0.0 and r.caught and absf(r.contact - r.reach_at) < DT + 1e-6, "he rears, and after the pause takes the player out of doors (rear %.2f, reach %.2f, taken %.2f)" % [r.rear, float(r.get("reach_at", -1.0)), r.contact])
	t.check(absf(float(r.get("reach_at", 0.0)) - r.rear - Roam.REACH_PAUSE) < 1e-6, "the pause is REARS BEFORE HE GRABS FOR")
	# Into the house during the pause: not taken.
	var w2 := _ward()
	var probe := _chase_scene(_ward(), h)
	var r2 := _chase_scene(w2, h, float(probe.rear) - float(probe.t0) + 0.3)
	t.check(r2.rear > 0.0 and not w2.caught.has("p1"), "a player who gets into the house during the pause is not taken by the reach")
	t.check(w2.encounter in [&"warning", &"climbing", &"searching"] and w2.resident_house == h, "and he comes to that house to search it (%s at %d)" % [w2.encounter, w2.resident_house])
	t.check(r.min_gap <= Roam.CHASE_GAP + 3.0, "he presses the chase (nearest %.2f m, the gap %.1f)" % [r.min_gap, Roam.CHASE_GAP])
	t.note("he stays at house %d from %.2f; chase from %.2f, rear %.2f, taken %.2f, nearest %.2f m" % [h, r.near_start, r.chase, r.rear, r.contact, r.min_gap])

# ---------------------------------------------------------------------------------------------
# 6. Solid.

func test_his_body_is_solid_and_never_seals_a_player_in(t: T) -> void:
	var w := _ward()
	var h := _house(w)
	_run(w, 0.0, 0.1, func(n: float) -> Dictionary: return {"p1": {"position": _room(w, h, &"entry"), "sprint": n < 0.1}})
	_until(w, 0.1, 60.0, &"searching")
	var c := w.roam.at
	var into := c + Vector3(0, -1.0, 0)
	var outside := c + (Vector3(1, 0, 0) * 10.0)
	t.check(w.roam.blocks(outside, c - Vector3.UP * 1.0), "a step that ends in his body is refused")
	t.check(not w.roam.blocks(c - Vector3.UP * 1.0, c - Vector3.UP * 1.0 + Vector3(4, 0, 0)), "a step out of it is not")
	# From chase states: some house stays reachable on the crew's walk graph with his body in the way.
	var g := Bots.build_graph(w)
	var states := 0
	var sealed := 0
	for seed_value: int in ([1, 2] if t.quick else [1, 2, 3, 4, 5, 6, 7, 8]):
		var wc := _ward({}, seed_value)
		var hc := _house(wc)
		var gc := Bots.build_graph(wc)
		var fixture: House = wc.houses[hc]
		var gallery := fixture.to_world(Vector3(0, 0.15, -0.8))
		var now := 0.0
		while now < 12.0:
			now += DT
			wc.step(now, DT, 30.0, {"p1": {"position": gallery, "sprint": now < 2.5}})
			if wc.encounter == &"chasing" and int(now / DT) % 10 == 0:
				states += 1
				if not _a_house_open(wc, gc, gallery):
					sealed += 1
	t.check(states > 0 and sealed == 0, "from %d chase states a house is always open to the chased player (%d sealed)" % [states, sealed])

## Whether from `at` some house's room is reachable on the bots' walk graph, his body blocking.
static func _a_house_open(w: Ward, g: Bots.Graph, at: Vector3) -> bool:
	var start := g.nearest(at)
	var seen := {start: true}
	var stack := [start]
	while not stack.is_empty():
		var i: int = stack.pop_back()
		if g.room.has(i):
			return true
		for e: Array in g.adj[i]:
			var j: int = e[0]
			if seen.has(j) or bool(e[2]) and not w.bridge_lowered:
				continue
			if w.roam.blocks(g.pts[i], g.pts[j]):
				continue
			seen[j] = true
			stack.append(j)
	return false

# ---------------------------------------------------------------------------------------------
# 7. Two screens through the real room.

func test_two_screens_agree_on_him(t: T) -> void:
	var names: Array[String] = ["one", "two"]
	var net := Transport.MemoryNetwork.new("rr1", Transport.LinkConfig.make(0.023, 0.069, 0.12, 0.22, 0.08, 0.17))
	var rules := HostRules.new(false, 1, [], true)
	rules.rigger_roam = true
	var now := 0.0
	var host := Host.new(net.connect_peer("host"), "rr1-net", names, now, Callable(rules, "prepare"), Callable(rules, "step"), names)
	var clients: Array[Client] = []
	for id in names:
		clients.append(Client.new(net.connect_peer(id), "host", id, now))
	host.start_ward_review(SEED)
	var w := host._ward_review
	t.check(w.roam != null, "the host's Ward has the crawling Rigger with the flag on")
	var h := _house(w)
	var fixture: House = w.houses[h]
	var gallery := fixture.to_world(Vector3(0, 0.15, -0.8))
	var bodies: Array[Vector3] = [w.lift_door() + Vector3(0, 0, 1.2), gallery]
	var history := {}
	var worst := 0.0
	var compared := 0
	for frame in ceili(30.0 / 0.025):
		now += 0.025
		net.now = now
		for i in clients.size():
			var c := clients[i]
			c.receive(now)
			var local := Client.LocalFrame.new()
			var b := bodies[i]
			if i == 1 and now < 9.0 and now > 6.0:
				# Sprinting back and forth along the gallery (a sprint is only a sprint on the move).
				local.gait = &"sprint"
				b = fixture.to_world(Vector3(1.5 * sin(now * 3.0), 0.15, -0.8))
			local.body = Move.Body.make(b.x, b.z, 0, b.y)
			c.frame(now, local)
		host.update(now)
		var block: Variant = host.world().get("ward")
		if block is Dictionary and (block as Dictionary).has("rigger"):
			history[snappedf(float(host.state.t), 0.001)] = Vector3(w.roam.at)
		for c in clients:
			var latest: Variant = c.latest
			if latest is Dictionary and latest.get("ward") is Dictionary and (latest.ward as Dictionary).has("rigger"):
				var key := snappedf(float(latest.ht), 0.001)
				if history.has(key):
					var shown: Array = latest.ward.rigger.at
					worst = maxf(worst, Vector3(shown[0], shown[1], shown[2]).distance_to(history[key]))
					compared += 1
	t.check(compared > 100 and worst <= 0.011, "both screens show him where the host had him at that tick (%d frames, worst %.3f m)" % [compared, worst])
	var times := []
	for c in clients:
		var mine := []
		for e: Dictionary in c.events:
			if str(e.get("type", "")) in ["ward_chase", "ward_rear", "ward_contact", "ward_line_loaded"]:
				mine.append("%s@%.3f" % [e.type, float(e.get("at", -1.0))])
		times.append(mine)
	t.check(times[0] == times[1] and not (times[0] as Array).is_empty(), "both screens have the same cues at the same host times: %s" % str(times[0]))
	var types := {}
	for e: Dictionary in clients[0].events:
		types[str(e.get("type", ""))] = true
	t.note("host: %s %s caught %s; client event types %s" % [w.phase, w.encounter, str(w.caught), str(types.keys())])

## Stage 2: his feet. Placed at poses of each kind of surface (a roof, a wall, an underside, a deck), most of his legs
## find a hold on a real solid and their ankles are solved onto it (two-bone IK), the knees bending away from it.
func test_his_feet_land_on_the_surface_he_crawls(t: T) -> void:
	var View: GDScript = load("res://client/ward/view.gd")
	var view: Node3D = View.new(SEED, Vector3.ZERO)
	view.own_hud = false
	view.figures_new = true
	(Engine.get_main_loop() as SceneTree).root.add_child(view)
	if not t.check(view.feet != null, "the new figure has its feet modifier"):
		view.queue_free()
		return
	var w := _ward()
	var g := w.roam.g
	var sk: Skeleton3D = view.feet.get_skeleton()
	var lines: Array[String] = []
	for kind: int in [G.ROOF, G.WALL, G.UNDER, G.DECK, G.REACH]:
		var node := -1
		for i in g.pos.size():
			if g.joined(i) and g.kind[i] == kind:
				node = i
				break
		if node < 0:
			continue
		view.rigger.visible = true
		view.rigger.global_transform = Transform3D(Basis(g.rot[node]), g.pos[node])
		view.feet.active = true
		view.feet.reset()
		var held := 0
		var worst := 0.0
		for k in 3:
			view.feet.now = float(k) * 0.05
			view.feet._process_modification()
		for i: int in view.feet.chains.size():
			var foot: Vector3 = view.feet.feet[i]
			if foot == Vector3.INF:
				continue
			held += 1
			var ids: PackedInt32Array = view.feet.chains[i]
			var lens: Array = view.feet.lengths[i]
			var hip: Vector3 = sk.global_transform * sk.get_bone_global_pose(ids[1]).origin
			var want: Vector3 = foot + view.rigger.global_transform.basis.y.normalized() * float(view.feet.TARSUS)
			var ankle: Vector3 = sk.global_transform * sk.get_bone_global_pose(ids[3]).origin
			if hip.distance_to(want) < float(lens[0]) + float(lens[1]) - 0.01 and hip.distance_to(want) > absf(float(lens[0]) - float(lens[1])) + 0.01:
				worst = maxf(worst, ankle.distance_to(want))
		lines.append("%s: %d legs held, worst ankle %.3f m" % [G.KIND_NAMES[kind], held, worst])
		t.check(held >= 4, "on a %s at least four legs find a hold (%d)" % [G.KIND_NAMES[kind], held])
		t.check(worst < 0.05, "and every leg that can reach its hold is solved onto it (worst %.3f m)" % worst)
	t.note("; ".join(lines))
	view.queue_free()

# ---------------------------------------------------------------------------------------------
# 8. The settings (tests/prop_settings.gd test_rigger_roam_numbers).

static func settings_proof(t: T) -> void:
	# The three speeds set the path's time on their surfaces.
	var w := _ward()
	var base := w.roam.speeds()
	for pair: Array in [[&"rigger.lair_speed", G.LAIR], [&"rigger.climb_speed", G.LINE], [&"rigger.crawl_speed", G.ROOF]]:
		var tuned := _ward({pair[0]: 2.0}).roam.speeds()
		t.check(is_equal_approx(base[pair[1]], Settings.today(pair[0])) and is_equal_approx(tuned[pair[1]], 2.0), "%s sets his speed on %s" % [pair[0], G.KIND_NAMES[pair[1]]])
	# Linger: he stays after a search that long before going home.
	for linger: float in [0.0, 12.0]:
		var wl := _ward({&"rigger.linger": linger})
		var h := _house(wl)
		_run(wl, 0.0, 0.1, func(n: float) -> Dictionary: return {"p1": {"position": _room(wl, h, &"entry"), "sprint": n < 0.1}})
		var at := _until(wl, 0.1, 60.0, &"searching")
		var done := _until(wl, at, 60.0, &"lingering")
		var home := _until(wl, done, 60.0, &"returning")
		t.check(done > 0.0 and absf(home - done - linger) <= DT + 1e-6, "rigger.linger %.0f: he stays %.2f s" % [linger, home - done])
	# Feel: his hand's stay at the end of each reach.
	for feel: float in [Roam.FEEL, 1.5]:
		var wf := _ward({} if feel == Roam.FEEL else {&"rigger.feel": feel})
		var hf := _house(wf)
		_run(wf, 0.0, 0.1, func(n: float) -> Dictionary: return {"p1": {"position": _room(wf, hf, &"entry"), "sprint": n < 0.1}})
		_until(wf, 0.1, 60.0, &"searching")
		t.check(wf.arm != null and is_equal_approx(wf.arm.probe_seconds, feel), "rigger.feel %.1f sets his hand's stay (%.2f)" % [feel, wf.arm.probe_seconds if wf.arm != null else -1.0])
	# Openings and opening time: a long search from one opening is cut at OPENING_TIME.
	t.eq(Settings.today(&"rigger.openings"), float(Roam.OPENINGS), "rigger.openings today")
	var wo := _ward({&"rigger.opening_time": 5.0, &"rigger.feel": 4.0, &"rigger.room_warn": 4.0, &"rigger.openings": 1.0})
	var ho := _house(wo)
	_run(wo, 0.0, 0.1, func(n: float) -> Dictionary: return {"p1": {"position": _room(wo, ho, &"entry"), "sprint": n < 0.1}})
	var s0 := _until(wo, 0.1, 60.0, &"searching")
	var s1 := _until(wo, s0, 60.0, &"lingering")
	# Cut at 5 s, then the hand draws back (at most its reach at HAND DRAWS BACK AT).
	t.check(s1 - s0 <= 5.0 + House.ArmSearch.REACH / Settings.today(&"rigger.arm_back") + DT, "rigger.opening_time cuts the search (%.2f s)" % (s1 - s0))
	# The chase's numbers.
	var r := _chase_scene(_ward(), _house(_ward()))
	var never := _chase_scene(_ward({&"rigger.loud": 0.0}), _house(_ward()))
	t.check(r.chase > 0.0 and never.chase < 0.0, "rigger.loud: at 0 there is never a chase")
	var long := _chase_scene(_ward({&"rigger.chase_time": 1.0}), _house(_ward()))
	t.check(long.rear > 0.0 and long.rear - long.chase <= 1.0 + Ward.WARN_SECONDS + DT, "rigger.chase_time: he rears after it (%.2f s)" % (long.rear - long.chase))
	var gap := _chase_scene(_ward({&"rigger.chase_gap": 10.0}), _house(_ward()))
	t.check(not gap.moved_inside_gap and gap.min_gap >= 0.0, "rigger.chase_gap: he keeps 10 m (nearest %.2f)" % gap.min_gap)
	var pause := _chase_scene(_ward({&"rigger.reach_pause": 3.0}), _house(_ward()))
	t.check(absf(float(pause.get("reach_at", 0.0)) - pause.rear - 3.0) < 1e-6, "rigger.reach_pause sets the pause")
	for id: StringName in [&"rigger.chase_gain", &"rigger.chase_top"]:
		t.check(is_equal_approx(Settings.f(null, id, -1.0), -1.0) and Settings.today(id) > 0.0, "%s has today's value" % id)
	var slow := _chase_scene(_ward({&"rigger.chase_top": 1.0, &"rigger.chase_gain": 0.0}), _house(_ward()))
	t.check(slow.min_gap >= r.min_gap - 1e-6, "rigger.chase_top and rigger.chase_gain slow him (nearest %.2f against %.2f)" % [slow.min_gap, r.min_gap])

# ---------------------------------------------------------------------------------------------
# 9. The view: drawn at the host's pose, only while out of his lair, his arm from his wrist, his lamp only while drawn.

func test_the_view_draws_him_where_the_host_has_him(t: T) -> void:
	var View: GDScript = load("res://client/ward/view.gd")
	var view: Node3D = View.new(SEED, Vector3.ZERO)
	view.own_hud = false
	view.figures_new = true
	(Engine.get_main_loop() as SceneTree).root.add_child(view)
	var w := _ward()
	var h := _house(w)
	var crew := []
	view.show_host(w.snapshot(0.0), 0.0, "me", crew)
	t.check(not view.rigger.visible and not view.lamp_light.is_visible_in_tree() and not view.rim_light.is_visible_in_tree(), "in his lair he is not drawn and his lamp and belly light are dark")
	_run(w, 0.0, 0.1, func(n: float) -> Dictionary: return {"p1": {"position": _room(w, h, &"entry"), "sprint": n < 0.1}})
	view.show_host(w.snapshot(0.1), 0.1, "me", crew)
	t.check(not view.rigger.visible, "while the line is only loaded he is not drawn")
	var now := 0.1
	var worst := 0.0
	var drawn := 0
	while now < 40.0 and w.encounter != &"searching":
		now += DT
		w.step(now, DT, 30.0, {})
		view.show_host(w.snapshot(now), now, "me", crew)
		if w.roam.out() and w.encounter == &"climbing":
			drawn += 1
			worst = maxf(worst, view.rigger.global_position.distance_to(w.roam.at))
			if not view.rigger.visible or not view.lamp_light.is_visible_in_tree() or not view.rim_light.is_visible_in_tree():
				worst = INF
	t.check(drawn > 10 and worst <= 0.011, "crawling, he is drawn at the host's pose with his lamp lit (%d frames, worst %.3f m)" % [drawn, worst])
	for k in 60:
		now += DT
		w.step(now, DT, 30.0, {})
	view.show_host(w.snapshot(now), now, "me", crew)
	var limb := w.posed_limb(now)
	var tip: Vector3 = limb[-1] if limb.size() > 1 else Vector3.INF
	var wrist: Vector3 = view.rigger.global_transform * view.rigger_wrist
	var shoulder: Vector3 = limb[0] if limb.size() > 1 else Vector3.INF
	t.check(w.encounter == &"searching" and view.hand.visible and view.hand.global_position.distance_to(tip) < 0.02, "searching: the hand at the host's arm's end")
	t.check(wrist.distance_to(shoulder) <= 1.01, "his own wrist is at the arm's shoulder outside the opening (%.2f m)" % wrist.distance_to(shoulder))
	t.check(view.animation == null or view.animation.assigned_animation == View.HOLD_CLIP, "he holds on (the hang clip) while he searches")
	view.queue_free()
