# Authoritative Hanging Ward encounter. Each tick receives accepted crew positions and input edges.
extends RefCounted

const Footing = preload("res://sim/ward/footing.gd")
const Layout = preload("res://sim/ward/layout.gd")
const House = preload("res://sim/ward/house.gd")
const Arm = preload("res://sim/ward/arm.gd")
const Settings = preload("res://sim/settings.gd")
const Roam = preload("res://sim/ward/roam.gd")
const RETURN_SECONDS := 600.0
const WARN_SECONDS := 0.85
const CLIMB_SECONDS := 2.5
const WINCH_REACH := 1.25

var layout: Dictionary
var footing: Footing
var houses: Array[House] = []
var switches: Array[Dictionary] = []
var collection_at := -1.0
var depart_at := -1.0
var phase := &"unloading"
var encounter := &"idle"
var bridge_lowered := false
var resident_house := -1
var alert_area := &""
var encounter_at := -1.0
var arm: Arm
var requested_doors := {}
var final_call_sent := false
var last_minute_sent := false
var boarded: Array[String] = []
var caught: Array[String] = []
var left_behind: Array[String] = []
var _sprint_at := {}

# WD1: what the Rigger senses and how he searches, each a live setting ("THE RIGGER (THE WARD)", sim/settings.gd). The
# host hands over the run's tuning and the crew's size every tick (net/host.gd _step_ward_review); null is today's.
#   - Sprinting is heard on a house's floors as before, and now upstairs, on its gallery and on the walkways too (the
#     lines carry it): a gallery is its house's, a walkway the nearer house's (rigger.open_heard).
#   - Walking (not creeping) is heard within rigger.steps_reach metres (flat) of where he is: under the lowest house
#     until he first climbs, then at the house he last went to. Inside the house he is searching it turns the arm to
#     that room, as a sprint does. Creeping is never heard.
#   - The instrument ticking while it records within rigger.click_reach of the hand turns the arm to that room.
#   - A door worked is heard at its house's entry (rigger.door_heard).
#   - A noise at another house while he is busy is kept; when this search ends he moves on to it, with the loaded line
#     again (rigger.move_on).
#   - While he searches a house, only those on its ground floor record his arm (rigger.record_inside); his climb is
#     recorded from anywhere near as before. Every catch still follows a loaded line.
var tuning: Settings.Values = null
var crew_size := 4
var lair := -1
var _step_at := {}
var _last_pos := {}
var _queued_house := -1
var _queued_area := &""
const STEP_EVERY := 0.65
const MOVING_SPEED := 0.6
## Today's values of the settings above (tests/prop_settings.gd names them).
const STEPS_REACH := 9.0
const CLICK_REACH := 2.5
const OPEN_HEARD := 1
const DOOR_HEARD := 1
const MOVE_ON := 1
const RECORD_INSIDE := 1
## The hand, as tuned by bot crews (tools/ward_hunt.gd, WD1): it pays out at ARM_SPEED (a walk is 3 m/s, a creep
## 1.2), ALONE_ARM_SPEED with a crew of one (a lone player has nobody to watch the doorway), waits ROOM_WARN at the
## sill before each room and feels the end of its reach for PROBE. The old numbers are arm.gd's constants.
const ARM_SPEED := 2.2
const ALONE_ARM_SPEED := 1.8
const ROOM_WARN := 0.9
const PROBE := 1.0
const ARM_BACK := 2.6
## RR1: the Rigger as a solid creature crawling the Ward's surfaces (sim/ward/roam.gd), the run flag rigger_roam
## (net/host_rules.gd). Null: today's Rigger, exactly as before. Today's values of its rows (tests/prop_settings.gd).
var roam: Roam = null
const CLIMB_SPEED := Roam.CLIMB_SPEED
const CRAWL_SPEED := Roam.CRAWL_SPEED
const LAIR_SPEED := Roam.LAIR_SPEED
const LINGER := Roam.LINGER
const OPENING_TIME := Roam.OPENING_TIME
const OPENINGS := Roam.OPENINGS
const LOUD := Roam.LOUD
const CHASE_TIME := Roam.CHASE_TIME
const CHASE_GAP := Roam.CHASE_GAP
const CHASE_GAIN := Roam.CHASE_GAIN
const CHASE_TOP := Roam.CHASE_TOP
const REACH_PAUSE := Roam.REACH_PAUSE
const FEEL := Roam.FEEL
## RR1: the crew's speeds this tick (flat metres a second, by id), for the chase.
var _speeds := {}

## RR1: turns the solid, crawling Rigger on (builds his surface graph from this Ward's layout). `shown`: a screen's
## walk model, which never steps him and only places his body where the host says (no graph is built).
func enable_roam(shown := false) -> void:
	if roam == null:
		roam = Roam.new(self, not shown)

## WC1, the lift called from a far house (net/host_rules.gd ward_call; the owner, 20 Nov: "There should be nothing
## special mechanically ... except that in the ward the button for the elevator is on the other side"). With `called`
## on, the host steps the Ward's lift by every floor's rules (sim/run.gd _step_lift, called at `station`) and sets
## `phase` from the run's each tick; step never runs the clock below. The station is in a house of the seed's choosing,
## never the lift's house nor the two a crew comes to first walking from it (the owner: "in one of the houses at random,
## just not one of the first two that the players come across"). A call is a noise there, heard through the same
## hearing every noise uses (hear_loud), within rigger.call_heard metres of where he is (the owner: "pressing the
## buttons brings the rigger up to aggro").
var called := false
var station_house := -1
var station := Vector3.INF
const CALL_HEARD := 80.0
## WC1, the web (net/host_rules.gd ward_web; the owner, 20 Nov: "Caught player on ward should be hung wrapped in web
## from the ceiling. A loud cut can free them. But it might bring the rigger."). With `web` on, the hand's catch carries
## the player for ward.carry_time and hangs them at the nearest free hang point (hang_points: set from the seed, in the
## entry rooms of HANG_POINTS houses, reached on foot whatever the drawbridge's state). A crewmate standing under them
## holding F for ward.cut_time cuts them down: a noise there, heard within rigger.cut_heard metres of him.
var web := false
var hang_points: Array[Dictionary] = []
## Caught and hung, by id: {"point": hang point, "caughtAt", "hangAt"} (host time).
var webbed := {}
## Cuts going on, by the cutter's id: {"id": who, "from", "done"} (host time).
var cuts := {}
const HANG_POINTS := 4
const CARRY_TIME := 2.0
const CUT_TIME := 4.0
const CUT_HEARD := 80.0
## How near a cutter's feet must be to the spot under the cocoon (flat), and the most their feet are above or below it.
const CUT_REACH := 1.3
const CUT_RISE := 1.2
## How high a hung player's feet are above the floor (their head under the ceiling, House.HEIGHT).
const HANG_LIFT := 1.0

func _f(id: StringName, fallback: float) -> float:
	return Settings.f(tuning, id, fallback)

## WG1: the layout's options (sim/ward/layout.gd generate): {} today's Ward; the host's run flag `ward_layout` gives
## Layout.options(tuning), and the snapshot carries them (layout_wire) so every screen builds the same.
var layout_options := {}

## WG1: the options as the Ward block carries them (sim/ward/layout.gd to_wire; net/host.gd adds them to the block),
## or [] for today's Ward.
func layout_wire() -> Array:
	return [] if layout_options.is_empty() else Layout.to_wire(layout_options)

func _init(seed_value: int, options: Dictionary = {}) -> void:
	layout_options = options.duplicate()
	layout = Layout.generate(seed_value, options)
	for site: Dictionary in layout.houses:
		houses.append(House.new(site, seed_value))
	footing = Footing.new(layout, lift_door(), houses)
	_place_station(seed_value)
	_place_hang_points(seed_value)
	# He lives below the lowest house.
	var low := INF
	for i in houses.size():
		if float(layout.houses[i].z) < low:
			low = float(layout.houses[i].z)
			lair = i
	for edge: Dictionary in layout.bridges:
		if edge.kind != "winch":
			continue
		var path: Array = edge.path
		_add_switch(path[0], path[1], int(edge.a))
		_add_switch(path[-1], path[-2], int(edge.b))

## WC1: the houses in the order a crew comes to them walking from the lift: by the length of the shortest way along the
## fixed walkways (never the drawbridge, which may be up), from house to house through their docks; ties by number.
## The lift's house is first.
func walking_order() -> Array[int]:
	var n := houses.size()
	var dist: Array[float] = []
	dist.resize(n)
	dist.fill(INF)
	dist[0] = 0.0
	var done: Array[bool] = []
	done.resize(n)
	done.fill(false)
	for _k in n:
		var best := -1
		for i in n:
			if not done[i] and is_finite(dist[i]) and (best < 0 or dist[i] < dist[best]):
				best = i
		if best < 0:
			break
		done[best] = true
		for edge: Dictionary in layout.bridges:
			if edge.kind == "winch" or (int(edge.a) != best and int(edge.b) != best):
				continue
			var other := int(edge.b) if int(edge.a) == best else int(edge.a)
			var d: float = dist[best] + _walkway_length(edge)
			if d < dist[other] - 1e-9:
				dist[other] = d
	var order: Array[int] = []
	for i in n:
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool: return dist[a] < dist[b] - 1e-9 or (absf(dist[a] - dist[b]) <= 1e-9 and a < b))
	return order

## A walkway's walking length: from house a's middle to its dock, along the path, to house b's middle.
func _walkway_length(edge: Dictionary) -> float:
	var path: Array = edge.path
	var a: Dictionary = layout.houses[int(edge.a)]
	var b: Dictionary = layout.houses[int(edge.b)]
	var total := Vector2(float(a.x), float(a.y)).distance_to(Vector2(float(path[0][0]), float(path[0][1])))
	for k in range(1, path.size()):
		total += Vector3(path[k - 1][0], path[k - 1][1], path[k - 1][2]).distance_to(Vector3(path[k][0], path[k][1], path[k][2]))
	total += Vector2(float(b.x), float(b.y)).distance_to(Vector2(float(path[-1][0]), float(path[-1][1])))
	return total

## WC1: the station's house, from the seed, among the houses after the lift's and the first two a crew comes to; and
## the button (feet) in its rear room, just through the room's door, where a walker stands clear of every wall.
func _place_station(seed_value: int) -> void:
	var order := walking_order()
	var pool: Array[int] = order.slice(3)
	if pool.is_empty():
		pool = order.slice(maxi(0, order.size() - 1))
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value * 7919 + 4721
	station_house = pool[rng.randi_range(0, pool.size() - 1)]
	var fixture := houses[station_house]
	var door := fixture.room_doors[1]
	var rear: Vector3 = fixture.areas[&"rear"]
	var tries: Array[Vector3] = [Vector3(door.x * 0.35, 0.0, door.z + 0.8), Vector3(door.x, 0.0, door.z + 0.7), Vector3(rear.x, 0.0, rear.z)]
	for local in tries:
		var at := fixture.to_world(local)
		if walk_clear(at, at):
			station = at
			return
	station = fixture.to_world(tries[-1])

## WC1: the web's hang points, from the seed: the middle of the entry room (ground floor, just inside its door, the
## ceiling HANG_LIFT above a hung player's feet) of HANG_POINTS different houses. Each a dict {"house", "at": the spot
## under the cocoon (feet), "hang": a hung player's feet}.
func _place_hang_points(seed_value: int) -> void:
	var pick: Array[int] = []
	for i in houses.size():
		pick.append(i)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value * 104729 + 1291
	for i in range(pick.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var old := pick[i]
		pick[i] = pick[j]
		pick[j] = old
	for i in pick:
		if hang_points.size() >= HANG_POINTS:
			break
		var fixture := houses[i]
		var entry: Vector3 = fixture.areas[&"entry"]
		var spot := fixture.to_world(Vector3(entry.x, 0.0, fixture.room_doors[0].z * 0.5))
		if not walk_clear(spot, spot):
			spot = fixture.to_world(Vector3(entry.x, 0.0, entry.z))
		hang_points.append({"house": i, "at": spot, "hang": spot + Vector3.UP * HANG_LIFT})

## WC1: a loud noise at a point (the call at the station, a cut), heard exactly as a flare's burst is (hear_at) when it
## is within `reach` metres (flat) of the house he is at, or under the lowest house before he first climbs.
func hear_loud(at: Vector3, now: float, reach: float) -> Array[Dictionary]:
	if reach <= 0.0 or _flat(at, lair) > reach:
		return []
	return hear_at(at, now)

## RR1: a catch by the crawling Rigger (sim/ward/roam.gd: his search's hand, or the grab after a chase) takes the player
## into the web exactly as the hand's catch does (_pursue): carried to the nearest free hang point and hung there after
## ward.carry_time. `contact` is the event, given the point and the time it hangs.
func web_catch(id: String, where: Vector3, now: float, contact: Dictionary) -> void:
	if not web or webbed.has(id):
		return
	var point := hang_point_for(where)
	var hang_at := now + maxf(0.0, _f(&"ward.carry_time", CARRY_TIME))
	webbed[id] = {"point": point, "caughtAt": now, "hangAt": hang_at, "said": false}
	contact["point"] = point
	contact["hangAt"] = hang_at

## WC1: the hang point nearest `at` that nobody hangs from (the nearest of all when every one is in use).
func hang_point_for(at: Vector3) -> int:
	var used := {}
	for row: Dictionary in webbed.values():
		used[int(row.point)] = true
	var best := -1
	var best_free := -1
	for k in hang_points.size():
		var d := Vector2(at.x - hang_points[k].at.x, at.z - hang_points[k].at.z).length() + absf(at.y - hang_points[k].at.y)
		if best < 0 or d < _hang_gap(at, best):
			best = k
		if not used.has(k) and (best_free < 0 or d < _hang_gap(at, best_free)):
			best_free = k
	return best_free if best_free >= 0 else best

func _hang_gap(at: Vector3, k: int) -> float:
	var p: Vector3 = hang_points[k].at
	return Vector2(at.x - p.x, at.z - p.z).length() + absf(at.y - p.y)

## WC1: whether a webbed player is hanging now (their carry over).
func hung(id: String, now: float) -> bool:
	return webbed.has(id) and now >= float(webbed[id].hangAt) - 1e-9

## WC1: where a webbed player's body is: their hang point's (feet), or INF for nobody webbed.
func web_body(id: String) -> Vector3:
	if not webbed.has(id):
		return Vector3.INF
	return hang_points[int(webbed[id].point)].hang

## WC1: cuts, one tick. Each active crewmate on foot holding F (`hold`) under a hung player (CUT_REACH) works at them;
## held for ward.cut_time they are cut down. Returns the ids of those who were near a cocoon (their F is the cut's).
func _step_cuts(now: float, crew: Dictionary, events: Array[Dictionary]) -> Dictionary:
	var at_web := {}
	if not web:
		return at_web
	var length := _f(&"ward.cut_time", CUT_TIME)
	var ids: Array = crew.keys()
	ids.sort()
	var taken := {}
	for id: String in ids:
		var member: Dictionary = crew[id]
		var target := ""
		if member.get("active", true) and not member.get("aboard", false):
			var feet: Vector3 = member.position
			var targets: Array = webbed.keys()
			targets.sort()
			for wid: String in targets:
				var under: Vector3 = hang_points[int(webbed[wid].point)].at
				if wid != id and hung(wid, now) and Vector2(feet.x - under.x, feet.z - under.z).length() <= CUT_REACH and absf(feet.y - under.y) <= CUT_RISE:
					at_web[id] = true
					if member.get("hold", false) and not taken.has(wid):
						target = wid
					break
		var going: Variant = cuts.get(id)
		if going is Dictionary and str(going.id) != target:
			cuts.erase(id)
			events.append({"kind": &"cut_stop", "at": now, "by": id, "id": str(going.id)})
			going = null
		if target == "":
			continue
		taken[target] = true
		if going == null:
			cuts[id] = {"id": target, "from": now, "done": now + length}
			events.append({"kind": &"cut_start", "at": now, "by": id, "id": target, "done": now + length})
			continue
		if now >= float(going.done) - 1e-9:
			cuts.erase(id)
			var point := int(webbed[target].point)
			webbed.erase(target)
			caught.erase(target)
			var spot: Vector3 = hang_points[point].at
			events.append({"kind": &"cut", "at": now, "by": id, "id": target, "point": point, "x": spot.x, "y": spot.y, "z": spot.z})
			events.append_array(hear_loud(spot, now, _f(&"rigger.cut_heard", CUT_HEARD)))
	return at_web

func _add_switch(raw: Array, adjacent: Array, house: int) -> void:
	var point := Vector3(raw[0], raw[2], raw[1])
	var next := Vector3(adjacent[0], adjacent[2], adjacent[1])
	var offset := (next - point).cross(Vector3.UP).normalized()
	switches.append({"house": house, "position": point + offset * 0.59})

## The lift cabin is south of the parlour. The same geometry drives the client view.
func lift_door() -> Vector3:
	var foyer := houses[0]
	return foyer.to_world(Vector3(foyer.floor_bounds.position.x - 0.12, 0.15, foyer.floor_bounds.get_center().y))

func in_lift(feet: Vector3) -> bool:
	var offset := feet - lift_door()
	return absf(offset.x) <= 0.67 and offset.z <= -0.22 and offset.z >= -2.93 and absf(offset.y) <= 0.45

## The lift's gate (walk_clear's leaf across the car's mouth while it is away) and a walker's clearance from it.
const GATE := Vector3(1.24, 2.18, 0.08)
const WALK_CLEARANCE := 0.15

## Out of the car and out of its doorway: the gate, shut, can no longer stand across this walker (WF1). Between
## the car's floor (in_lift) and here a walker is in the doorway; the lift must not leave on them, or the shut
## gate holds them where they stand, neither in nor out.
func clear_of_lift(feet: Vector3) -> bool:
	var offset := feet - lift_door()
	var reach := WALK_CLEARANCE + 0.06
	var in_mouth := absf(offset.x) <= GATE.x * 0.5 + reach and offset.z <= GATE.z * 0.5 + reach and offset.z >= -3.1
	return not (in_mouth and absf(offset.y) <= 0.45)

## Begin collection once the normal lift has left the crew in the Ward. `return_seconds` is the lift's return time,
## the live setting ward.lift_minutes (PL2) stamped here as the lift leaves; today's is RETURN_SECONDS. A return of a
## minute or less has no "one minute" reminder: the departure's own announcement is the schedule then.
func leave(now: float, return_seconds := RETURN_SECONDS) -> Array[Dictionary]:
	if phase != &"unloading":
		return []
	phase = &"away"
	collection_at = now + return_seconds
	if return_seconds <= 60.0:
		last_minute_sent = true
	return [{"kind": &"departed", "at": now}]

## Each accepted crew row has position (feet), aboard and optional use (rising edge) and sprint.
## Boarding duration is sampled when the lift arrives. Call this at consecutive host ticks.
func step(now: float, delta: float, boarding_seconds: float, crew: Dictionary) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	if phase == &"unloading" or phase == &"departed":
		return events
	if phase == &"away" and not called:
		if not last_minute_sent and now >= collection_at - 60.0:
			last_minute_sent = true
			events.append({"kind": &"last_minute", "at": collection_at - 60.0})
		if now >= collection_at:
			phase = &"boarding"
			depart_at = collection_at + maxf(boarding_seconds, 0.0)
			events.append({"kind": &"returned", "at": collection_at})
	if phase == &"boarding" and not called:
		var final_at := maxf(collection_at, depart_at - 10.0)
		if not final_call_sent and now >= final_at and final_at < depart_at:
			final_call_sent = true
			events.append({"kind": &"final_call", "at": final_at})
		if now >= depart_at:
			phase = &"departed"
			for id: String in crew:
				if crew[id].get("aboard", false) and crew[id].get("active", true):
					boarded.append(id)
				else:
					left_behind.append(id)
			events.append({"kind": &"closed", "at": depart_at, "boarded": boarded.duplicate(), "leftBehind": left_behind.duplicate()})
			return events

	# WC1: the web. A carried player hangs at their point once the carry is over; then the cuts.
	if web:
		var hanging: Array = webbed.keys()
		hanging.sort()
		for wid: String in hanging:
			var row: Dictionary = webbed[wid]
			if not bool(row.get("said", false)) and now >= float(row.hangAt) - 1e-9:
				row["said"] = true
				var hang: Vector3 = hang_points[int(row.point)].hang
				events.append({"kind": &"hung", "at": float(row.hangAt), "id": wid, "point": int(row.point), "x": hang.x, "y": hang.y, "z": hang.z})
	var at_web := _step_cuts(now, crew, events)
	for id: String in crew:
		var member: Dictionary = crew[id]
		if not member.get("active", true) or member.get("aboard", false):
			continue
		var at: Vector3 = member.position
		if member.get("use", false) and not at_web.has(id):
			_use_near(at, now, crew, events)
		var was: Vector3 = _last_pos.get(id, at)
		_last_pos[id] = at
		var moving := delta > 0.0 and Vector2(at.x - was.x, at.z - was.z).length() / delta >= MOVING_SPEED
		if roam != null and delta > 0.0:
			_speeds[id] = Vector2(at.x - was.x, at.z - was.z).length() / delta
		if member.get("sprint", false) and now >= float(_sprint_at.get(id, -INF)):
			_sprint_at[id] = now + 0.65
			_hear_point(at, now, events, true, id)
		elif moving and not member.get("creep", false) and not member.get("sprint", false) and now >= float(_step_at.get(id, -INF)):
			_step_at[id] = now + STEP_EVERY
			var reach := _f(&"rigger.steps_reach", STEPS_REACH)
			if reach > 0.0 and _flat(at, lair) <= reach:
				_hear_point(at, now, events, false)
		if member.get("recording", false) and encounter == &"searching" and arm != null and arm.points.size() > 1:
			var reach := _f(&"rigger.click_reach", CLICK_REACH)
			if reach > 0.0 and (at + Vector3.UP * 1.25).distance_to(houses[resident_house].to_world(arm.points[-1])) <= reach:
				var room := _room_at(houses[resident_house], at)
				if room != &"":
					arm.hear(room)
	if encounter == &"idle" and _queued_house >= 0 and roam == null:
		var house := _queued_house
		_queued_house = -1
		_hear(house, _queued_area, now, events)
	if roam != null:
		if encounter == &"idle" and _queued_house >= 0:
			var queued := _queued_house
			_queued_house = -1
			_hear(queued, _queued_area, now, events)
		roam.step(now, delta, crew, _speeds, events)
		return events
	_pursue(now, delta, crew, events)
	return events

## The room of a house a player (feet) is in: the ground floor's (today), or with the crawling Rigger any storey's
## (stage 2: he can reach upstairs through the upper windows).
func _room_at(house: House, feet: Vector3) -> StringName:
	var local := house.to_local(feet + Vector3.UP * 1.25)
	return house.area_at_any(local) if roam != null else house.area_at(local)

## Flat distance from a point to a house's middle.
func _flat(at: Vector3, house: int) -> float:
	if house < 0:
		return INF
	var site: Dictionary = layout.houses[house]
	return Vector2(at.x - float(site.x), at.z - float(site.y)).length()

## A disturbance at a point (feet): the room of the house it is in, if any, is heard as a sprint there is.
func _hear_point(at: Vector3, now: float, events: Array[Dictionary], _loud := true, who := "") -> void:
	for i in houses.size():
		var area := _room_at(houses[i], at)
		if area != &"":
			_hear(i, area, now, events, at)
			return
	# WD1: upstairs, on a gallery or on a walkway: the nearest house (its own, for upstairs and a gallery).
	if _f(&"rigger.open_heard", OPEN_HEARD) < 0.5:
		return
	# RR1: a player out of doors this loud is chased (sim/ward/roam.gd heard_loud); upstairs is in a house.
	if roam != null and who != "" and roam.house_holding(at) < 0 and roam.heard_loud(who, now, events):
		return
	var best := -1
	var near := INF
	for i in houses.size():
		var site: Dictionary = layout.houses[i]
		var off := Vector2(absf(at.x - float(site.x)), absf(at.z - float(site.y)))
		var half := Vector2(float(site.w), float(site.d)) * 0.5 + Vector2.ONE * Layout.GALLERY
		var gap := (off - half).max(Vector2.ZERO).length()
		if gap < near:
			near = gap
			best = i
	if best >= 0:
		_hear(best, &"entry", now, events, at)

## WN2: a noise the run made at a point (a flare's burst, a toy's rattle; sim/run.gd step_ward_kit) is heard the same
## way, at the same times step hears a sprint (the lift gone and not yet left again). Returns the cues it raised.
func hear_at(at: Vector3, now: float) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	if phase != &"away" and phase != &"boarding":
		return events
	_hear_point(at, now, events)
	return events

## WN2: where a thrown thing comes down from `from` (feet) along `motion`: the walk model's own footing and walls.
func throw_landing(from: Vector3, motion: Vector2) -> Vector3:
	return walk(from, motion)

func _use_near(at: Vector3, now: float, crew: Dictionary, events: Array[Dictionary]) -> void:
	for button in switches:
		if at.distance_to(button.position) <= WINCH_REACH:
			if bridge_lowered and _shortcut_occupied(crew):
				return
			bridge_lowered = not bridge_lowered
			events.append({"kind": &"bridge", "at": now, "house": button.house, "lowered": bridge_lowered})
			_hear(button.house, &"entry", now, events)
			return
	for i in houses.size():
		var near := houses[i].to_local(at)
		if Vector2(near.x, near.z).length() < 1.12 and absf(near.y) < 0.6:
			requested_doors[i] = not bool(requested_doors.get(i, true))
			if _f(&"rigger.door_heard", DOOR_HEARD) >= 0.5:
				_hear(i, &"entry", now, events)
			return

func _shortcut_occupied(crew: Dictionary) -> bool:
	for row: Dictionary in crew.values():
		if not row.get("active", true):
			continue
		var position: Vector3 = row.position
		var feet := Vector2(position.x, position.z)
		if is_finite(footing.height_at(feet, true)) and not is_finite(footing.height_at(feet, false)):
			return true
	return false

func _hear(house: int, area: StringName, now: float, events: Array[Dictionary], point := Vector3.INF) -> void:
	if roam != null:
		roam.hear(house, area, point, now, events)
		return
	if encounter == &"idle":
		resident_house = house
		lair = house
		encounter = &"warning"
		encounter_at = now
		alert_area = area
		events.append({"kind": &"line_loaded", "at": now, "house": house})
	elif resident_house == house and encounter == &"searching":
		arm.hear(area)
	elif resident_house != house and _f(&"rigger.move_on", MOVE_ON) >= 0.5:
		# WD1: busy elsewhere; he comes here next.
		_queued_house = house
		_queued_area = area

func _pursue(now: float, delta: float, crew: Dictionary, events: Array[Dictionary]) -> void:
	if encounter == &"idle":
		return
	var elapsed := now - encounter_at
	if encounter == &"warning" and elapsed >= WARN_SECONDS:
		encounter = &"climbing"
	if encounter == &"climbing" and elapsed >= WARN_SECONDS + CLIMB_SECONDS:
		encounter = &"searching"
		arm = houses[resident_house].make_arm()
		arm.warning_seconds = _f(&"rigger.room_warn", ROOM_WARN)
		arm.probe_seconds = _f(&"rigger.probe", PROBE)
		arm.out_speed = _f(&"rigger.arm_speed", ARM_SPEED) if crew_size > 1 else _f(&"rigger.alone_arm_speed", ALONE_ARM_SPEED)
		arm.in_speed = _f(&"rigger.arm_back", ARM_BACK)
		arm.hear(alert_area)
	if encounter != &"searching":
		return
	var contacts := {}
	var house := houses[resident_house]
	for id: String in crew:
		var member: Dictionary = crew[id]
		if not member.get("active", true) or member.get("aboard", false):
			continue
		var local := house.to_local(member.position + Vector3.UP * 1.25)
		if house.area_at(local) != &"":
			contacts[id] = local
	arm.step(delta, contacts, bool(requested_doors.get(resident_house, true)))
	for id: String in arm.contacts:
		if not caught.has(id):
			caught.append(id)
			var contact := {"kind": &"contact", "at": now, "house": resident_house, "id": id}
			if web and not webbed.has(id):
				# WC1: carried to the nearest free hang point and hung there after the carry.
				var where: Vector3 = crew[id].position if crew.has(id) else houses[resident_house].to_world(Vector3.ZERO)
				var point := hang_point_for(where)
				var hang_at := now + maxf(0.0, _f(&"ward.carry_time", CARRY_TIME))
				webbed[id] = {"point": point, "caughtAt": now, "hangAt": hang_at, "said": false}
				contact["point"] = point
				contact["hangAt"] = hang_at
			events.append(contact)
	if arm.phase == &"idle":
		encounter = &"idle"
		resident_house = -1
		encounter_at = -1.0
		arm = null

## WD1: who may record his arm this tick: while he searches a house, those on its ground floor; else everyone (null).
func recorders(crew: Dictionary, _now := 0.0) -> Variant:
	if encounter != &"searching" or resident_house < 0 or _f(&"rigger.record_inside", RECORD_INSIDE) < 0.5:
		return null
	var out := {}
	var house := houses[resident_house]
	for id: String in crew:
		var p: Vector3 = crew[id].position
		if _room_at(house, p) != &"":
			out[id] = true
	return out

## The same support and grip that the view draws. Empty outside an active physical reach.
func posed_limb(now: float) -> PackedVector3Array:
	var points := PackedVector3Array()
	if roam != null and phase != &"departed":
		if encounter == &"searching" and arm != null and arm.points.size() > 1 and resident_house >= 0:
			for local in arm.points:
				points.append(houses[resident_house].to_world(local))
			return points
		return roam.posed_limb(now)
	if resident_house < 0 or phase == &"departed":
		return points
	var house := houses[resident_house]
	if encounter == &"climbing":
		var site: Dictionary = layout.houses[resident_house]
		var anchor := Vector3(float(site.x) + (1.0 if house.window_side > 0 else -1.0) * (float(site.w) * 0.5 + Layout.GALLERY - 0.13),
			float(site.z) + 0.17, float(site.y) - float(site.d) * 0.5 - Layout.GALLERY + 0.13)
		if house.generated():
			# WG1: a turned house's loaded line is at the corner the view draws it at (House.support_corner).
			anchor = house.support_corner(site)
		var shoulder := house.to_world(house.shoulder)
		var climb := clampf((now - encounter_at - WARN_SECONDS) / CLIMB_SECONDS, 0.0, 1.0)
		anchor.y = shoulder.y
		var body := (anchor - Vector3.UP * 10.0).lerp(anchor, minf(1.0, climb * 1.18))
		body = body.lerp(shoulder, smoothstep(0.78, 1.0, climb))
		points.append(body + Vector3.UP * 0.45)
		points.append(Vector3(anchor.x, body.y + 0.78, anchor.z))
	elif arm != null and arm.points.size() > 1:
		for local in arm.points:
			points.append(house.to_world(local))
	return points

## Authoritative door leaves and the same interior wall clearance as the moving player.
func walk_clear(from: Vector3, to: Vector3) -> bool:
	if not footing.route_supported(from, to, bridge_lowered):
		return false
	# RR1: his body is solid; a walker cannot step into it.
	if roam != null and roam.blocks(from, to):
		return false
	# The creature already owns the swing-space decision for a door held by its arm.
	for id in houses.size():
		var house := houses[id]
		var door_open := arm.door_open if resident_house == id and arm != null else bool(requested_doors.get(id, true))
		if not house.walk_clear(from, to, door_open, id == 0):
			return false
	var at := lift_door()
	var walls: Array[AABB] = [
		AABB(at + Vector3(-0.775, 0.0, -3.0), Vector3(0.11, 2.2, 3.0)),
		AABB(at + Vector3(0.665, 0.0, -3.0), Vector3(0.11, 2.2, 3.0)),
		AABB(at + Vector3(-0.775, 0.0, -3.06), Vector3(1.55, 2.2, 0.12)),
	]
	if phase in [&"away", &"departed"]:
		walls.append(AABB(at + Vector3(-GATE.x * 0.5, 0.0, -GATE.z * 0.5), GATE))
	for wall in walls:
		if Arm._hits_box(from + Vector3.UP * 0.84, to + Vector3.UP * 0.84, wall, WALK_CLEARANCE):
			return false
	return true

func walk(from: Vector3, motion: Vector2) -> Vector3:
	var at := from
	var substeps := maxi(1, ceili(motion.length() / Footing.WALK_STEP))
	var part := motion / substeps
	for i in substeps:
		var wanted := _walk_piece(at, part)
		if wanted == at and not is_zero_approx(part.x) and not is_zero_approx(part.y):
			wanted = _walk_piece(at, Vector2(part.x, 0.0))
			wanted = _walk_piece(wanted, Vector2(0.0, part.y))
		at = wanted
	return at

func _walk_piece(from: Vector3, motion: Vector2) -> Vector3:
	var to := Vector2(from.x, from.z) + motion
	var height := footing.walking_height(to, from.y, bridge_lowered)
	if is_finite(height):
		var candidate := Vector3(to.x, height, to.y)
		if walk_clear(from, candidate):
			return candidate
	return from

## WC1: the block's extras, only with the call or the web on (empty with both off, so the block is what it was).
func extras() -> Dictionary:
	var out := {}
	if called:
		out["called"] = true
		out["station"] = [snappedf(station.x, 0.01), snappedf(station.y, 0.01), snappedf(station.z, 0.01)]
		out["stationHouse"] = station_house
	if web:
		var points: Array = []
		for p: Dictionary in hang_points:
			points.append([snappedf(p.at.x, 0.01), snappedf(p.at.y, 0.01), snappedf(p.at.z, 0.01)])
		out["hangPoints"] = points
		var rows := {}
		for id: String in webbed:
			rows[id] = {"point": int(webbed[id].point), "caughtAt": float(webbed[id].caughtAt), "hangAt": float(webbed[id].hangAt)}
		out["web"] = rows
		var going := {}
		for id: String in cuts:
			going[id] = {"id": str(cuts[id].id), "from": float(cuts[id].from), "done": float(cuts[id].done)}
		out["cuts"] = going
	return out

func snapshot(clock := 0.0) -> Dictionary:
	var out := _snapshot(clock)
	# RR1: his pose from the host, with the flag on only.
	if roam != null:
		out["rigger"] = roam.snapshot()
	return out

func _snapshot(clock := 0.0) -> Dictionary:
	var points: Array = []
	var doors := []
	for id in houses.size():
		doors.append(arm.door_open if resident_house == id and arm != null else bool(requested_doors.get(id, true)))
	for point: Vector3 in posed_limb(clock):
		points.append([snappedf(point.x, 0.01), snappedf(point.y, 0.01), snappedf(point.z, 0.01)])
	return {"collectionAt": collection_at, "departAt": depart_at, "bridgeLowered": bridge_lowered,
		"phase": String(phase), "house": resident_house, "startedAt": encounter_at, "encounter": String(encounter),
		"armPoints": points, "doors": doors, "boarded": boarded.duplicate(), "leftBehind": left_behind.duplicate(),
		"seed": int(layout.seed), "caught": caught.duplicate()}