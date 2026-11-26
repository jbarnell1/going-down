# RR1: the Rigger as a solid creature that crawls the Hanging Ward (the run flag rigger_roam, net/host_rules.gd). The
# host's Ward (sim/ward/state.gd) owns one of these when the flag is on and hands it what it hears; this decides where
# his body is, along the surface graph (sim/ward/rigger_graph.gd), and the host's snapshot carries that pose to every
# screen. Nothing here runs with the flag off.
#
# His rule, from the design (docs/floors/hanging-ward.md): he lives below the lowest house and climbs only when he
# senses prey; the lines take his weight before he is seen; at a house he hangs outside and searches it room by room
# with his one long arm. With the flag:
#   - He hears by the same rule and the same rigger.* settings as without it (sim/ward/state.gd _hear_point).
#   - A noise at a house sends him along the graph to the opening of that house that is quickest for him and nearest
#     the noise (a window or the door, sim/ward/house.gd openings; one whose arm reaches the room heard if any can), at
#     rigger.climb_speed on lines, rigger.crawl_speed on walls, roofs, decks and undersides, rigger.lair_speed in his lair.
#   - Before he moves the loaded line is heard (line_loaded, where his weight is) and he holds still WARN_SECONDS; he
#     holds longer when the trip is short, so the hand never comes into a room sooner after the line loads than today's
#     climb gives (REACH_LEAD). Every surface he goes onto (a house's line, a house, a walkway or the bridge) is heard
#     taking his weight (a `weight` cue) SURFACE_LEAD before he is on it, never later than the trip starts.
#   - At the opening his arm searches as today (sim/ward/arm.gd), from that opening, with that opening's reach: from
#     every opening one room stays out of reach (house.gd opening_reach). A noise in a room his arm cannot reach from
#     here sends him, once the arm is out, to another opening that reaches it (at most rigger.openings a visit), heard
#     shifting his weight on the house before he goes (REACH_LEAD again before the hand is back in). He searches from
#     one opening rigger.opening_time at most.
#   - After a search a noise elsewhere brings him straight there (over roofs, along walls, under or over walkways);
#     with none he stays rigger.linger, then crawls home to his lair.
#   - The chase (the owner, 20 Nov): a player out of doors heard rigger.loud times within LOUD_WINDOW is chased: he
#     follows along the surfaces at a speed that tracks theirs (rigger.chase_gain per metre beyond rigger.chase_gap, at
#     most rigger.chase_top) and never moves closer than rigger.chase_gap. After rigger.chase_time, or once they stop
#     fleeing for CHASE_STILL, he stops and rears (a `rear` cue: the loaded line's creak and his arm drawn up) and
#     holds rigger.reach_pause; then the arm goes out and takes them unless they are inside a house by then (no roll:
#     the same every time). In a house they are hunted as any house is: he comes to it and searches.
#   - His body is solid to the crew: a walker cannot step into it (sim/ward/state.gd walk_clear).
extends RefCounted

const G = preload("res://sim/ward/rigger_graph.gd")
const Settings = preload("res://sim/settings.gd")
const House = preload("res://sim/ward/house.gd")

## Today's numbers of the rigger.* rows this reads (sim/settings.gd; tests/prop_settings.gd names them through
## sim/ward/state.gd).
const CLIMB_SPEED := 6.0
const CRAWL_SPEED := 3.0
const LAIR_SPEED := 16.0
const LINGER := 8.0
const OPENING_TIME := 20.0
const OPENINGS := 2
const LOUD := 3
const CHASE_TIME := 8.0
const CHASE_GAP := 6.0
const CHASE_GAIN := 0.8
const CHASE_TOP := 5.5
const REACH_PAUSE := 1.5
const FEEL := 4.5
## After searching from one opening, go on unheard to another for the rooms not yet searched. Off: measured with the
## bot crews (tools/ward_hunt.gd, 40 seeds, stage 2) it cut what crews of four could record (quota met 35% with it,
## 60% without); he still moves to another opening for a room he hears and cannot reach (hear).
const ROOM_BY_ROOM := false
## Choosing an opening: seconds of his own travel a metre between the opening and the noise is worth (he prefers the
## opening nearest where he heard the prey, unless another is much quicker to reach).
const NEAR_NOISE := 3.0
## Fixed parts of the rule.
## The hand never comes into a room sooner after the trip's first cue than today's climb (WARN 0.85 + CLIMB 2.5).
const REACH_LEAD := 3.35
## A surface is heard taking his weight this long before he goes onto it.
const SURFACE_LEAD := 2.0
## The chase: loud noises count within this window; a target slower than STILL_SPEED for CHASE_STILL has stopped.
const LOUD_WINDOW := 5.0
const CHASE_STILL := 2.0
const STILL_SPEED := 0.3
const REPLAN := 0.5
## How long the arm is drawn out to a player he takes at the end of a chase.
const GRAB_SHOW := 0.6

var ward: Variant
var g: G
## Where his body is: on the edge from `from_node` to `to_node`, `frac` of the way (to_node -1: at from_node).
var from_node := -1
var to_node := -1
var frac := 0.0
var path := PackedInt32Array()
var at := Vector3.ZERO
var turn := Quaternion.IDENTITY
## The trip: &"house" (to an opening), &"home", &"chase" or &"" (none). Where it goes and what was heard.
var trip: StringName = &""
var hold_until := -INF
var target_house := -1
var target_opening := -1
var heard_area: StringName = &""
var heard_point := Vector3.INF
var opening := -1
var openings_used := 0
var opening_since := 0.0
var move_to := -1
## The rooms searched on this visit (by every opening he has searched from).
var searched := {}
var linger_until := -INF
## Cues still to come on this trip: [seconds of travel into the trip when he goes onto it, cue].
var _ahead: Array = []
var _travelled := 0.0
## The chase.
var chase_id := ""
var chase_since := 0.0
var still_since := -1.0
var rear_at := -1.0
var reach_at := -1.0
var grab_until := -1.0
var grab := PackedVector3Array()
var _replan_at := -INF
var _pending_chase := ""
var _chase_group := ""
## Loud noises by player (times), for the chase.
var loud := {}
## The last catch by the chase, for the caught player's sequence (WC1): the hand, his wrist and his body then.
var last_catch := {}

func _init(ward_: RefCounted, build := true) -> void:
	ward = ward_
	if not build:
		# A screen's copy: his pose is set from the host's snapshot (client/ward/view.gd walk_model_rigger).
		return
	g = graph_for(ward)
	from_node = g.lair
	at = g.pos[g.lair]
	turn = g.rot[g.lair]

## The graph of a Ward's layout, built once per seed in this process (it depends on nothing else) and shared.
static var _graphs := {}
static var _lock := Mutex.new()

## The cache's key for a Ward: its seed and its layout's options (WG1).
static func key_for(w: Variant) -> String:
	return "%d|%s" % [int(w.layout.seed), JSON.stringify(w.get("layout_options") if w.get("layout_options") != null else {})]

## A build of a Ward's graph to do in pieces (net/host.gd _prebuild_roam): advance() it; once it is done, `keep` it
## and graph_for finds it.
static func begin_graph(w: Variant) -> G:
	var g := G.new()
	g.begin(w.layout, w.houses, w.lift_door())
	return g

static func keep(w: Variant, g: G) -> void:
	_lock.lock()
	_graphs[key_for(w)] = g
	_lock.unlock()

static func graph_for(w: Variant) -> G:
	var key := key_for(w)
	_lock.lock()
	var found: Variant = _graphs.get(key)
	_lock.unlock()
	if found != null:
		return found
	var built := G.build(w.layout, w.houses, w.lift_door()) as G
	_lock.lock()
	if _graphs.size() > 64:
		_graphs.clear()
	_graphs[key] = built
	_lock.unlock()
	return built

func _f(id: StringName, fallback: float) -> float:
	return Settings.f(ward.tuning, id, fallback)

func speeds() -> PackedFloat32Array:
	var crawl := _f(&"rigger.crawl_speed", CRAWL_SPEED)
	var climb := _f(&"rigger.climb_speed", CLIMB_SPEED)
	# By kind: lair, line, wall, roof, under, deck, reach.
	return PackedFloat32Array([_f(&"rigger.lair_speed", LAIR_SPEED), climb, crawl, crawl, crawl, crawl, crawl])

## Whether he is out of his lair (drawn): not while he is anywhere in it, far below the houses, nor crossing it.
func out() -> bool:
	if g == null:
		return trip == &"shown"
	return not (g.kind[from_node] == G.LAIR and (to_node < 0 or g.kind[to_node] == G.LAIR))

## The node a new trip starts from: the end of the edge he is on (he finishes it), or where he is.
func _start_node() -> int:
	return to_node if to_node >= 0 else from_node

# ---------------------------------------------------------------------------------------------
# Hearing (sim/ward/state.gd _hear with the flag on).

## A noise at house `house`, room `area`, at `point` (INF unknown). Returns whether it was taken (the Ward's own
## encounter fields are set here).
func hear(house: int, area: StringName, point: Vector3, now: float, events: Array[Dictionary]) -> void:
	var w: Variant = ward
	if w.encounter == &"searching" and w.resident_house == house:
		var here: Dictionary = w.houses[house].openings()[opening]
		if w.houses[house].reachable_areas(here).has(area):
			# The hand goes to where the player was heard, not only to the room's middle (stage 2: it follows them).
			_hear_arm(w.houses[house], area, point)
		elif openings_used < int(_f(&"rigger.openings", OPENINGS)) and move_to < 0:
			var better := _best_opening(house, area, point, _start_node())
			if better >= 0 and better != opening and w.houses[house].reachable_areas(w.houses[house].openings()[better]).has(area):
				move_to = better
				heard_area = area
				heard_point = point
				w.arm.withdraw()
		return
	if w.encounter in [&"warning", &"climbing"] and w.resident_house == house and trip == &"house":
		heard_area = area
		heard_point = point
		return
	if w.encounter in [&"idle", &"lingering", &"returning"]:
		_go_to_house(house, area, point, now, events, true)
		return
	if w.resident_house != house and _f(&"rigger.move_on", 1.0) >= 0.5:
		w._queued_house = house
		w._queued_area = area

## The opening of `house` he goes to from node `start`: the quickest for him plus the walk from it to the noise, an
## opening whose arm reaches the room heard first. -1: none joined.
func _best_opening(house: int, area: StringName, point: Vector3, start: int) -> int:
	var cost := _costs(start)
	var best := -1
	var score := INF
	var crawl := _f(&"rigger.crawl_speed", CRAWL_SPEED)
	var fixture: House = ward.houses[house]
	for index in g.openings_of(house):
		var o: Dictionary = fixture.openings()[index]
		var t := INF
		for n in g.reach_nodes(house, index):
			t = minf(t, cost[n])
		if not is_finite(t):
			continue
		var s := t
		if point != Vector3.INF:
			s += fixture.to_world(o.shoulder).distance_to(point) * NEAR_NOISE
		if not fixture.reachable_areas(o).has(area):
			s += 1000.0
		if s < score - 1e-9:
			score = s
			best = index
	return best

## Seconds from `start` to every node.
func _costs(start: int) -> PackedFloat64Array:
	var n := g.pos.size()
	var cost := PackedFloat64Array()
	cost.resize(n)
	cost.fill(INF)
	cost[start] = 0.0
	var heap: Array = [[0.0, start]]
	var sp := speeds()
	while not heap.is_empty():
		var top: Array = G._pop(heap)
		var i: int = top[1]
		if float(top[0]) > cost[i]:
			continue
		for j in g.adj[i]:
			var c := cost[i] + g.edge_time(i, j, sp)
			if c < cost[j] - 1e-9:
				cost[j] = c
				G._push(heap, [c, j])
	return cost

func _go_to_house(house: int, area: StringName, point: Vector3, now: float, events: Array[Dictionary], first: bool) -> void:
	var w: Variant = ward
	var start := _start_node()
	var index := _best_opening(house, area, point, start)
	if index < 0:
		return
	var route := g.path(start, g.reach_nodes(house, index), speeds())
	if route.is_empty():
		return
	_end_chase()
	w.resident_house = house
	w.lair = house
	w.encounter = &"warning"
	w.encounter_at = now
	w.alert_area = area
	target_house = house
	target_opening = index
	heard_area = area
	heard_point = point
	if first:
		openings_used = 0
		searched.clear()
	trip = &"house"
	var weight := at
	events.append({"kind": &"line_loaded", "at": now, "house": house, "x": snappedf(weight.x, 0.01), "y": snappedf(weight.y, 0.01), "z": snappedf(weight.z, 0.01)})
	_begin(route, now, REACH_LEAD)

func _go_home(now: float) -> void:
	var route := g.path(_start_node(), PackedInt32Array([g.lair]), speeds())
	ward.encounter = &"returning"
	ward.resident_house = -1
	trip = &"home"
	_begin(route, now, 0.0)

## Starts along `route` (from the start node): holds still at least WARN_SECONDS (none going home), and long enough
## that the trip lasts `lead` seconds at least; schedules the cue of every surface he goes onto.
func _begin(route: PackedInt32Array, now: float, lead: float) -> void:
	var sp := speeds()
	path = route.slice(1) if route.size() > 0 and route[0] == _start_node() else route
	if to_node < 0:
		# At a node: the first step of the path is the next edge.
		pass
	var travel := 0.0
	_ahead.clear()
	_travelled = 0.0
	var group := _group(_start_node())
	var prev := _start_node()
	if to_node >= 0:
		travel += (1.0 - frac) * g.edge_time(from_node, to_node, sp)
	for n in path:
		travel += g.edge_time(prev, n, sp)
		var k := _group(n)
		if k != group and k != "":
			_ahead.append([travel - g.edge_time(prev, n, sp), _cue_for(n)])
			group = k
		prev = n
	var hold := 0.0
	if lead > 0.0:
		hold = maxf(ward.WARN_SECONDS, lead - travel)
	hold_until = now + hold

## What surface a pose is on, for its cue: "line:h:corner", "walkway:b", "house:h", or "" (his lair).
func _group(n: int) -> String:
	match g.kind[n]:
		G.LAIR:
			return ""
		G.LINE:
			return "line:%d:%d" % [g.house_of[n], g.corner_of[n]]
	if g.bridge_of[n] >= 0:
		return "walkway:%d" % g.bridge_of[n]
	return "house:%d" % g.house_of[n] if g.house_of[n] >= 0 else ""

func _cue_for(n: int) -> Dictionary:
	var c := {"kind": &"weight", "surface": &"house", "house": int(g.house_of[n]), "bridge": int(g.bridge_of[n]), "corner": -1,
		"x": snappedf(g.pos[n].x, 0.01), "y": snappedf(g.pos[n].y, 0.01), "z": snappedf(g.pos[n].z, 0.01)}
	if g.kind[n] == G.LINE:
		c.surface = &"line"
		c.corner = int(g.corner_of[n])
	elif g.bridge_of[n] >= 0:
		c.surface = &"walkway"
	return c

# ---------------------------------------------------------------------------------------------
# Each tick (sim/ward/state.gd _pursue with the flag on).

func step(now: float, delta: float, crew: Dictionary, speeds_by_id: Dictionary, events: Array[Dictionary]) -> void:
	var w: Variant = ward
	if grab_until >= 0.0 and now >= grab_until:
		grab_until = -1.0
		grab = PackedVector3Array()
	if trip == &"chase":
		_chase_step(now, delta, crew, speeds_by_id, events)
		return
	if w.encounter == &"rearing":
		_rear_step(now, crew, events)
		return
	if w.encounter in [&"warning", &"climbing", &"returning"]:
		if now >= hold_until:
			if w.encounter == &"warning":
				w.encounter = &"climbing"
			_travel(now, delta, events)
		if path.is_empty() and to_node < 0 and now >= hold_until:
			_arrive(now, events)
		return
	if w.encounter == &"searching":
		_search_step(now, delta, crew, events)
		return
	if w.encounter == &"lingering" and w._queued_house >= 0:
		var next: int = w._queued_house
		w._queued_house = -1
		_go_to_house(next, w._queued_area, Vector3.INF, now, events, true)
		return
	if w.encounter == &"lingering" and now >= linger_until:
		_go_home(now)

func _travel(now: float, delta: float, events: Array[Dictionary], speed := -1.0, guard := Callable()) -> void:
	var sp := speeds()
	var remaining := delta
	while remaining > 1e-9:
		if to_node < 0:
			if path.is_empty():
				break
			to_node = path[0]
			path = path.slice(1)
			frac = 0.0
		var length := g.pos[from_node].distance_to(g.pos[to_node])
		var e := g.edge_time(from_node, to_node, sp) if speed < 0.0 else length / maxf(speed, 1e-6)
		if speed == 0.0:
			break
		var used := minf(remaining, (1.0 - frac) * e) if e > 1e-9 else 0.0
		var next_frac := 1.0 if e <= 1e-9 else frac + used / e
		var next_at := g.pos[from_node].lerp(g.pos[to_node], next_frac)
		if guard.is_valid() and not guard.call(next_at):
			break
		frac = next_frac
		remaining -= used
		_travelled += used
		at = next_at
		turn = g.rot[from_node].slerp(g.rot[to_node], frac)
		if frac >= 1.0 - 1e-9:
			from_node = to_node
			to_node = -1
			frac = 0.0
			at = g.pos[from_node]
			turn = g.rot[from_node]
	while not _ahead.is_empty() and _travelled + SURFACE_LEAD >= float(_ahead[0][0]):
		var cue: Dictionary = (_ahead.pop_front()[1] as Dictionary).duplicate()
		cue["at"] = now
		events.append(cue)

func _arrive(now: float, events: Array[Dictionary]) -> void:
	var w: Variant = ward
	if trip == &"home":
		trip = &""
		w.encounter = &"idle"
		w.resident_house = -1
		w.encounter_at = -1.0
		return
	if trip == &"house":
		trip = &""
		opening = target_opening
		openings_used += 1
		opening_since = now
		move_to = -1
		var fixture: House = w.houses[target_house]
		w.encounter = &"searching"
		w.arm = fixture.make_arm_at(fixture.openings()[opening])
		w.arm.warning_seconds = _f(&"rigger.room_warn", w.ROOM_WARN)
		# He feels each room longer than the clinging Rigger did (rigger.feel): each visit's one safe room leaves his hand
		# fewer rooms, and the crew's reading of his search must stay as long as today's (tools/ward_hunt.gd, stage 2).
		w.arm.probe_seconds = _f(&"rigger.feel", FEEL)
		w.arm.out_speed = _f(&"rigger.arm_speed", w.ARM_SPEED) if w.crew_size > 1 else _f(&"rigger.alone_arm_speed", w.ALONE_ARM_SPEED)
		w.arm.in_speed = _f(&"rigger.arm_back", w.ARM_BACK)
		for room in fixture.reachable_areas(fixture.openings()[opening]):
			searched[room] = true
		var area := heard_area
		var point := heard_point
		if not fixture.reachable_areas(fixture.openings()[opening]).has(area):
			area = _nearest_reachable(fixture, opening, heard_point)
			point = Vector3.INF
		_hear_arm(fixture, area, point)

## The arm hears a room at a point (feet, world; INF: the room's middle).
func _hear_arm(fixture: House, area: StringName, point: Vector3) -> void:
	if point == Vector3.INF:
		ward.arm.hear(area)
		return
	ward.arm.hear_at(area, fixture.to_local(point) + Vector3.UP * House.ARM_HEIGHT)

static func _nearest_reachable(fixture: House, index: int, point: Vector3) -> StringName:
	var o: Dictionary = fixture.openings()[index]
	var best: StringName = &""
	var d := INF
	for area in fixture.reachable_areas(o):
		var e: float = fixture.to_world(fixture.probes_for(o)[area]).distance_to(point) if point != Vector3.INF else 0.0
		if best == &"" or e < d:
			best = area
			d = e
	return best if best != &"" else fixture.front_room()

func _search_step(now: float, delta: float, crew: Dictionary, events: Array[Dictionary]) -> void:
	var w: Variant = ward
	var house: House = w.houses[w.resident_house]
	if now - opening_since >= _f(&"rigger.opening_time", OPENING_TIME):
		w.arm.withdraw()
	var contacts := {}
	for id: String in crew:
		var member: Dictionary = crew[id]
		if not member.get("active", true) or member.get("aboard", false):
			continue
		# WH1c: a player in a home's hide is touched only as the hide's rule allows (sim/ward/state.gd arm_contact).
		var local: Variant = w.arm_contact(id, member, w.resident_house)
		if local != null and house.area_at_any(local) != &"":
			contacts[id] = local
	w.sync_inner_doors()
	w.arm.step(delta, contacts, bool(w.requested_doors.get(w.resident_house, true)))
	w.door_rattle(now, events)
	for id: String in w.arm.contacts:
		if not w.caught.has(id):
			w.caught.append(id)
			var hand: Vector3 = house.to_world(w.arm.points[-1])
			var contact := {"kind": &"contact", "at": now, "house": w.resident_house, "id": id, "hand": _plain(hand), "body": _plain(at)}
			w.web_catch(id, crew[id].position if crew.has(id) else hand, now, contact)
			events.append(contact)
	if w.arm.phase != &"idle":
		return
	var h: int = w.resident_house
	w.arm = null
	# Room by room: a room of this house no opening he has searched from reaches sends him on to an opening that
	# does (at most rigger.openings a visit), so the whole house is searched, its safe room changing with the opening.
	if ROOM_BY_ROOM and move_to < 0 and openings_used < int(_f(&"rigger.openings", OPENINGS)):
		var fixture: House = w.houses[h]
		var cost := _costs(_start_node())
		var best_time := INF
		for index in g.openings_of(h):
			if index == opening:
				continue
			for room in fixture.reachable_areas(fixture.openings()[index]):
				# Room by room on the ground floor; upstairs only when a noise there calls him (hear).
				if searched.has(room) or String(room).begins_with("up"):
					continue
				for n in g.reach_nodes(h, index):
					if cost[n] < best_time:
						best_time = cost[n]
						move_to = index
						heard_area = room
	if move_to >= 0:
		# The weight shifting on the house, then to the other opening.
		var index := move_to
		move_to = -1
		var route := g.path(_start_node(), g.reach_nodes(h, index), speeds())
		if not route.is_empty():
			target_house = h
			target_opening = index
			trip = &"house"
			w.encounter = &"warning"
			w.encounter_at = now
			var cue := _cue_for(_start_node())
			cue["at"] = now
			cue["house"] = h
			events.append(cue)
			_begin(route, now, REACH_LEAD)
			return
	w.resident_house = -1
	w.encounter_at = -1.0
	if w._queued_house >= 0:
		var next: int = w._queued_house
		w._queued_house = -1
		w.encounter = &"idle"
		_go_to_house(next, w._queued_area, Vector3.INF, now, events, true)
		return
	if _pending_chase != "" and crew.has(_pending_chase):
		var who := _pending_chase
		_pending_chase = ""
		w.encounter = &"lingering"
		start_chase(who, now, events)
		return
	w.encounter = &"lingering"
	linger_until = now + _f(&"rigger.linger", LINGER)

static func _plain(p: Vector3) -> Array:
	return [snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01)]

# ---------------------------------------------------------------------------------------------
# The chase.

## A loud noise by player `id` out of doors at `now`; true when it starts (or keeps) a chase.
func heard_loud(id: String, now: float, events: Array[Dictionary]) -> bool:
	var need := int(_f(&"rigger.loud", LOUD))
	if need <= 0 or id == "":
		return false
	var times: Array = loud.get(id, [])
	times.append(now)
	while not times.is_empty() and now - float(times[0]) > LOUD_WINDOW:
		times.pop_front()
	loud[id] = times
	if times.size() < need:
		return false
	if trip == &"chase" or ward.encounter == &"rearing":
		return true
	if ward.encounter == &"searching":
		_pending_chase = id
		return true
	start_chase(id, now, events)
	return true

func start_chase(id: String, now: float, events: Array[Dictionary]) -> void:
	var w: Variant = ward
	trip = &"chase"
	chase_id = id
	chase_since = now
	still_since = -1.0
	_replan_at = -INF
	path = PackedInt32Array()
	_ahead.clear()
	_travelled = 0.0
	_chase_group = _group(_start_node())
	w.encounter = &"chasing"
	w.resident_house = -1
	w.encounter_at = now
	hold_until = now + w.WARN_SECONDS
	events.append({"kind": &"chase", "at": now, "id": id, "x": snappedf(at.x, 0.01), "y": snappedf(at.y, 0.01), "z": snappedf(at.z, 0.01)})
	events.append({"kind": &"line_loaded", "at": now, "house": -1, "x": snappedf(at.x, 0.01), "y": snappedf(at.y, 0.01), "z": snappedf(at.z, 0.01)})

func _end_chase() -> void:
	if trip == &"chase":
		trip = &""
	chase_id = ""
	rear_at = -1.0
	reach_at = -1.0

## Where a player is in a house (any storey): the house, or -1 out of doors.
func house_holding(feet: Vector3) -> int:
	for i: int in ward.houses.size():
		var h: House = ward.houses[i]
		var local := h.to_local(feet + Vector3.UP * 0.5)
		if h.floor_bounds.has_point(Vector2(local.x, local.z)) and local.y >= -0.3 and local.y <= House.HEIGHT * float(h.storeys.size() - 1):
			return i
	return -1

func _target(crew: Dictionary) -> Variant:
	if not crew.has(chase_id):
		return null
	var row: Dictionary = crew[chase_id]
	if not row.get("active", true) or row.get("aboard", false) or ward.caught.has(chase_id):
		return null
	return row

func _chase_step(now: float, delta: float, crew: Dictionary, speeds_by_id: Dictionary, events: Array[Dictionary]) -> void:
	var w: Variant = ward
	var row: Variant = _target(crew)
	if row == null:
		_end_chase()
		w.encounter = &"lingering"
		linger_until = now + _f(&"rigger.linger", LINGER)
		return
	var feet: Vector3 = row.position
	var inside := house_holding(feet)
	if inside >= 0:
		# In a house: hunted as any house is.
		_end_chase()
		w.encounter = &"lingering"
		var h: House = w.houses[inside]
		var area := h.area_at_any(h.to_local(feet + Vector3.UP * 1.25))
		_go_to_house(inside, area if area != &"" else h.front_room(), feet, now, events, true)
		return
	var torso := feet + Vector3.UP * 1.25
	var speed_t := float(speeds_by_id.get(chase_id, 0.0))
	if speed_t < STILL_SPEED:
		if still_since < 0.0:
			still_since = now
	else:
		still_since = -1.0
	if now - chase_since >= _f(&"rigger.chase_time", CHASE_TIME) or (still_since >= 0.0 and now - still_since >= CHASE_STILL):
		trip = &""
		w.encounter = &"rearing"
		rear_at = now
		reach_at = now + _f(&"rigger.reach_pause", REACH_PAUSE)
		events.append({"kind": &"rear", "at": now, "id": chase_id, "reach_at": reach_at,
			"x": snappedf(at.x, 0.01), "y": snappedf(at.y, 0.01), "z": snappedf(at.z, 0.01)})
		return
	if now < hold_until:
		return
	if now >= _replan_at:
		_replan_at = now + REPLAN
		var goal := g.nearest(feet)
		if goal >= 0:
			var route := g.path(_start_node(), PackedInt32Array([goal]), speeds())
			path = route.slice(1) if route.size() > 0 else route
	var gap := _f(&"rigger.chase_gap", CHASE_GAP)
	var d := at.distance_to(torso)
	var v := 0.0
	if d > gap:
		v = clampf(speed_t + _f(&"rigger.chase_gain", CHASE_GAIN) * (d - gap), 0.0, _f(&"rigger.chase_top", CHASE_TOP))
	# He never moves to within the gap of the player he chases.
	var guard := func(next: Vector3) -> bool:
		var e := next.distance_to(torso)
		return e >= gap or e >= d
	_travel(now, delta, events, v, guard)
	# Each surface he goes onto in a chase is heard taking his weight as he does (the chase's own cue, its line and
	# the hold before he moves, came first).
	var group := _group(from_node)
	if group != "" and group != _chase_group:
		_chase_group = group
		var cue := _cue_for(from_node)
		cue["at"] = now
		events.append(cue)

func _rear_step(now: float, crew: Dictionary, events: Array[Dictionary]) -> void:
	var w: Variant = ward
	if now < reach_at:
		return
	var row: Variant = _target(crew)
	var id := chase_id
	_end_chase()
	if row == null:
		w.encounter = &"lingering"
		linger_until = now + _f(&"rigger.linger", LINGER)
		return
	var feet: Vector3 = row.position
	var inside := house_holding(feet)
	if inside >= 0:
		var h: House = w.houses[inside]
		var area := h.area_at_any(h.to_local(feet + Vector3.UP * 1.25))
		w.encounter = &"lingering"
		_go_to_house(inside, area if area != &"" else h.front_room(), feet, now, events, true)
		return
	# The arm is always fast enough out of doors.
	var hand := feet + Vector3.UP * 1.25
	var wrist := G.wrist_at(at, turn)
	if not w.caught.has(id):
		w.caught.append(id)
	last_catch = {"id": id, "at": now, "hand": _plain(hand), "wrist": _plain(wrist), "body": _plain(at)}
	var contact := {"kind": &"contact", "at": now, "house": -1, "id": id, "hand": _plain(hand), "wrist": _plain(wrist), "body": _plain(at)}
	# Into the web as any catch (WC1), from where they were taken.
	w.web_catch(id, feet, now, contact)
	events.append(contact)
	grab = PackedVector3Array([wrist, hand])
	grab_until = now + GRAB_SHOW
	w.encounter = &"lingering"
	linger_until = now + _f(&"rigger.linger", LINGER)

# ---------------------------------------------------------------------------------------------
# What the rest of the Ward reads.

## The limb the instrument records (sim/run.gd step_ward): the arm while he searches (sim/ward/state.gd), his body to
## his head while he comes for prey or chases, the drawn grab; nothing while he waits, lingers or goes home.
func posed_limb(now := 0.0) -> PackedVector3Array:
	var w: Variant = ward
	if not grab.is_empty():
		return grab
	# Already out of his lair, he holds on the house taking his weight before the hand goes in: he is there, on the
	# loaded line, so that is his loaded limb, recordable as the climb is (today's warning is not recordable because he
	# is still below, unseen).
	var loaded: bool = w.encounter == &"warning" and out()
	if loaded or w.encounter in [&"climbing", &"chasing", &"rearing"]:
		return PackedVector3Array([at, G.head_at(at, turn)])
	return PackedVector3Array()

## Whether his body stops a walker going from `from` to `to` (feet): only a step that ends in his body and nearer its
## middle than it started (so nobody is ever held inside him). While he is in his lair, never.
func blocks(from: Vector3, to: Vector3) -> bool:
	if not out():
		return false
	if at.distance_to(to) > G.BODY_REACH + 1.0:
		return false
	for s: Array in G.spheres(at, turn):
		var c: Vector3 = s[0]
		var r: float = float(s[1]) + 0.21
		var near_to := _segment_distance(c, to + Vector3.UP * 0.3, to + Vector3.UP * 1.6)
		if near_to < r and near_to < _segment_distance(c, from + Vector3.UP * 0.3, from + Vector3.UP * 1.6) - 1e-6:
			return true
	return false

static func _segment_distance(p: Vector3, a: Vector3, b: Vector3) -> float:
	return p.distance_to(Geometry3D.get_closest_point_to_segment(p, a, b))

## The snapshot's block (sim/ward/state.gd snapshot): his pose, what he is on, the opening and the chase.
func snapshot() -> Dictionary:
	var q := turn.normalized()
	var on := from_node if to_node < 0 or frac < 0.5 else to_node
	return {"at": _plain(at), "rot": [snappedf(q.x, 0.001), snappedf(q.y, 0.001), snappedf(q.z, 0.001), snappedf(q.w, 0.001)],
		"on": G.KIND_NAMES[g.kind[on]], "out": out(), "opening": opening if ward.encounter == &"searching" else -1,
		"chase": chase_id, "reachAt": reach_at, "rearAt": rear_at}
