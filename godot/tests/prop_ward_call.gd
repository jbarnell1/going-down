# WC1: the Hanging Ward's lift called from a far house, and the web (net/host_rules.gd ward_call, ward_web). The owner,
# 20 Nov: "There should be nothing special mechanically about the reactor in the ward except that in the ward the
# button for the elevator is on the other side", "the button being in one of the houses at random, just not one of
# the first two that the players come across", "pressing the buttons brings the rigger up to aggro", and "Caught
# player on ward should be hung wrapped in web from the ceiling. A loud cut can free them. But it might bring the
# rigger." Proved here, with the real Host and two real Clients over lossy in-memory links:
#   1. The station's house is never the lift's nor the first two a crew walks to, from the seed, the same for a seed;
#      the button stands where a walker stands, in that house, reached on foot from the lift.
#   2. The hang points: at least three, in different houses, each reached on foot from the lift with the drawbridge
#      raised and lowered.
#   3. The lift is every floor's: it leaves once the crew is out; the call is refused below the quota (callRefused,
#      nothing heard); at the lift's doors it does nothing; met, the call at the station calls the car (called, the
#      call plan's floors) and is heard (the Rigger's line loads at the station's house); the car comes when its plan
#      says, boards for the boarding time, and BANK goes up and home, DOWN rides to the next floor.
#   4. The clock fallback (ward.lift_clock): the old ten minutes, no station.
#   5. The web: the hand's catch carries the player to the nearest free hang point and hangs them after ward.carry_time;
#      a crewmate holding F under them for ward.cut_time cuts them down (loud: the Rigger's line loads); let go early,
#      nothing; freed, they stand as a healed player and record again; never freed, they are left behind with their tape.
#      Both clients agree on the catch, the point, the hang and the cut.
#   6. With both flags off nothing changes: no extras, the wire's old fields, the clock, the station does nothing.
extends RefCounted

const T = preload("res://tests/t.gd")
const Host = preload("res://net/host.gd")
const HostRules = preload("res://net/host_rules.gd")
const Client = preload("res://net/client.gd")
const Transport = preload("res://net/transport.gd")
const Move = preload("res://sim/move.gd")
const Run = preload("res://sim/run.gd")
const Ward = preload("res://sim/ward/state.gd")
const House = preload("res://sim/ward/house.gd")
const Wire = preload("res://net/ward_wire.gd")
const Route = preload("res://client/ward/route.gd")

const SEED := 8143

class Rig:
	var net: Transport.MemoryNetwork
	var host: Host
	var rules: HostRules
	var clients: Array[Client] = []
	var names: Array[String] = ["one", "two"]
	var bodies: Array[Vector3] = [Vector3(7.0, 0, 7.0), Vector3(7.0, 0, 7.0)]
	var held: Array[bool] = [false, false]
	var calling: Array[bool] = [false, false]
	var now := 0.0

	func _init(call_on: bool, web_on: bool, tuning := {}, ward_seed := SEED) -> void:
		net = Transport.MemoryNetwork.new("ward-call", Transport.LinkConfig.make(0.023, 0.069, 0.12, 0.22, 0.08, 0.17))
		# The resident on (so the floor quota), days and the quota, as the game's rooms have them.
		rules = HostRules.new(true, 1, [], true, true)
		rules.ward_call = call_on
		rules.ward_web = web_on
		host = Host.new(net.connect_peer("host"), "ward-call", names, now, Callable(rules, "prepare"), Callable(rules, "step"), names)
		for id in names:
			clients.append(Client.new(net.connect_peer(id), "host", id, now))
		if not tuning.is_empty():
			host.state = Run.with_tuning(host.state, tuning)
		host.start_ward_review(ward_seed)

	func ward() -> Ward:
		return host._ward_review

	func tick_for(seconds: float) -> void:
		for frame in ceili(seconds / 0.025 - 1e-6):
			now += 0.025
			net.now = now
			for i in clients.size():
				var c := clients[i]
				c.receive(now)
				var local := Client.LocalFrame.new()
				local.body = Move.Body.make(bodies[i].x, bodies[i].z, 0, bodies[i].y)
				local.use = held[i]
				local.call = calling[i]
				calling[i] = false
				var f := c.frame(now, local)
				if f != null and f.placed != null:
					bodies[i] = Vector3(f.placed.x, f.placed.y, f.placed.z)
			host.update(now)

	## Ticks until `done` is true or `limit` seconds have gone; returns whether it came.
	func until(done: Callable, limit: float) -> bool:
		var spent := 0.0
		while spent < limit:
			if done.call():
				return true
			tick_for(0.1)
			spent += 0.1
		return done.call()

	func events(type: String) -> Array:
		var out := []
		for row in host.event_log:
			var e: Dictionary = JSON.parse_string(row.text)
			if str(e.get("type", "")) == type:
				out.append(e)
		return out

	func meet_quota() -> void:
		var s := host.state.copy()
		s.floor_earned = float(s.floor_needed) + 1.0
		host.state = s

	## Feet in the Ward's car: BANK on the left walking in (x below the door), DOWN on the right.
	func in_car(side: String, slot := 0) -> Vector3:
		var door := ward().lift_door()
		return door + Vector3(-0.35 if side == "bank" else 0.35, 0.0, -1.0 - 0.6 * float(slot))

	func player(id: String) -> Run.RunPlayer:
		for p in host.state.players:
			if p.id == id:
				return p
		return null

# ---------------------------------------------------------------------------------------------
# 1 and 2. Where things are, from the seed.

func test_station_house_from_the_seed(t: T) -> void:
	var seeds := 60 if t.quick else 300
	var bad := 0
	var used := {}
	for k in seeds:
		var s := 1000 + k * 7919
		var w := Ward.new(s)
		var again := Ward.new(s)
		var order := w.walking_order()
		var first: Array = order.slice(0, 3)
		if first.has(w.station_house) or w.station_house < 0 or order[0] != 0:
			bad += 1
		if again.station_house != w.station_house or again.station != w.station:
			bad += 1
		if not w.walk_clear(w.station, w.station) or w.houses[w.station_house].area_at(w.houses[w.station_house].to_local(w.station + Vector3.UP * 1.25)) == &"":
			bad += 1
		used[w.station_house] = true
	t.eq(bad, 0, "%d seeds: the station is never in the lift's house or the first two, the same for a seed, where a walker stands inside its house" % seeds)
	t.check(used.size() >= 3, "the station's house varies with the seed (%d houses used)" % used.size())

func test_station_and_hang_points_reached_on_foot(t: T) -> void:
	var seeds := 2 if t.quick else 8
	for k in seeds:
		var s := 1000 + k * 7919
		var w := Ward.new(s)
		var start := w.lift_door() + Vector3(0, 0, 0.9)
		var houses := {}
		for p: Dictionary in w.hang_points:
			houses[int(p.house)] = true
		t.check(w.hang_points.size() >= 3 and houses.size() == w.hang_points.size(), "seed %d: %d hang points in different houses" % [s, w.hang_points.size()])
		for lowered: bool in [false, true]:
			w.bridge_lowered = lowered
			var goals: Array[Vector3] = [w.station]
			for p: Dictionary in w.hang_points:
				goals.append(p.at)
			for g in goals:
				var route := Route.find(w, start, Vector2(g.x, g.z), Ward.CUT_REACH * 0.8, 60000)
				t.check(not route.is_empty(), "seed %d, bridge %s: (%.2f, %.2f) is reached on foot from the lift" % [s, "lowered" if lowered else "raised", g.x, g.z])

# ---------------------------------------------------------------------------------------------
# 3. The lift is every floor's.

func test_call_locked_until_quota_then_called_and_heard(t: T) -> void:
	# The rig moves its players by placing them, which the Ward hears as walking: walks are not heard here
	# (rigger.steps_reach 0), so the only noise is the button's.
	var rig := Rig.new(true, false, {&"rigger.steps_reach": 0.0})
	var w := rig.ward()
	t.check(w.called and not w.web, "the call on, the web off")
	rig.tick_for(1.5)
	t.eq(String(rig.host.state.phase), "away", "the car leaves once the crew is out, as on every floor")
	t.eq(rig.events("carLeft").size(), 1, "carLeft once")
	t.check(w.collection_at < 0.0 and rig.events("ward_departed").is_empty(), "no clock: no return time, no 'returns in ten minutes'")
	# At the lift's doors the call does nothing on the Ward.
	rig.bodies[0] = w.lift_door() + Vector3(0, 0, 0.6)
	rig.tick_for(0.3)
	rig.calling[0] = true
	rig.tick_for(0.5)
	t.check(rig.events("called").is_empty() and rig.events("callRefused").is_empty(), "the lift's own doors have no button here")
	# At the station, below the quota: refused, and nobody hears it.
	rig.bodies[0] = w.station
	rig.tick_for(0.3)
	rig.calling[0] = true
	rig.tick_for(0.5)
	t.eq(rig.events("callRefused").size(), 1, "below the quota the call is refused (the ordinary floors' callRefused)")
	t.check(w.encounter == &"idle" and rig.events("ward_line_loaded").is_empty(), "a refused press is silent, as on every floor")
	t.eq(String(rig.host.state.phase), "away", "still away")
	rig.meet_quota()
	rig.tick_for(0.3)
	rig.calling[0] = true
	rig.tick_for(0.3)
	var called := rig.events("called")
	t.check(called.size() == 1 and String(rig.host.state.phase) == "coming", "met, the press calls the car (%s)" % str(called))
	var loaded := rig.events("ward_line_loaded")
	t.check(loaded.size() == 1 and int(loaded[0]["house"]) == w.station_house, "the call is heard: his line loads at the station's house (%s, station %d)" % [str(loaded), w.station_house])
	for c in rig.clients:
		var e: Variant = c.latest.ward.get("extras")
		t.check(e is Dictionary and e.get("called") == true and int(e["stationHouse"]) == w.station_house, "both clients have the station")

func test_car_comes_on_its_plan_and_bank_goes_home(t: T) -> void:
	var rig := _called_rig()
	var w := rig.ward()
	var s := rig.host.state
	var plan := Run.call_plan(s.seed, 0, 0, s.depth, s.long_dark, s.tuning)
	var at := float(rig.events("called")[0]["t"])
	t.check(rig.until(func() -> bool: return String(rig.host.state.phase) == "boarding", plan.wait + 5.0), "the car arrives")
	var arrived := rig.events("carArrived")
	t.check(arrived.size() == 1 and absf(float(arrived[0]["t"]) - at - plan.wait) < 0.06, "it comes when its call plan says (%.2f s after the call, the plan %.2f)" % [float(arrived[0]["t"]) - at if not arrived.is_empty() else -1.0, plan.wait])
	t.eq(String(w.phase), "boarding", "the Ward's gate is open while it boards")
	t.check(absf(rig.host.state.bell_left - Run.board_time(rig.host.state)) < 0.2, "the boarding time is every floor's")
	rig.bodies[0] = rig.in_car("bank")
	rig.bodies[1] = rig.in_car("bank", 1)
	rig.tick_for(1.0)
	t.check(rig.until(func() -> bool: return not rig.events("bell").is_empty(), Run.board_time(rig.host.state) + 3.0), "the bell")
	var bell: Dictionary = rig.events("bell")[0]
	t.check(str(bell["outcome"]) == "bank" and int(bell["bank"]) == 2, "two on BANK: the car banks (%s)" % str(bell))
	t.check(rig.events("banked").size() == 1 and rig.host.state.going_up, "banked, and the car goes up")
	t.check(rig.until(func() -> bool: return Run.at_home(rig.host.state), 40.0), "home: the prison")
	t.check(rig.host._ward_review == null, "the Ward is over")

func test_down_rides_to_the_next_floor(t: T) -> void:
	var rig := _called_rig()
	t.check(rig.until(func() -> bool: return String(rig.host.state.phase) == "boarding", 120.0), "the car arrives")
	rig.bodies[0] = rig.in_car("down")
	rig.tick_for(0.5)
	t.check(rig.until(func() -> bool: return not rig.events("bell").is_empty(), 60.0), "the bell")
	var bell: Dictionary = rig.events("bell")[0]
	t.check(str(bell["outcome"]) == "ride", "one on DOWN: the car rides down (%s)" % str(bell))
	t.eq(rig.ward().boarded, ["one"] as Array[String], "the Ward says who rode")
	t.eq(String(rig.player("two").status), "leftBehind", "the other is left behind, as on every floor")
	t.check(rig.until(func() -> bool: return not rig.events("rodeDown").is_empty(), 30.0), "the ride arrives")
	t.eq(int(rig.events("rodeDown")[0]["depth"]), 2, "on the floor below")
	t.check(rig.host._ward_review == null, "the Ward is over")

## A rig with the crew out, the quota met and the car called from the station by "one".
func _called_rig(web := false, tuning := {}) -> Rig:
	var rig := Rig.new(true, web, tuning)
	rig.tick_for(1.5)
	rig.meet_quota()
	rig.bodies[0] = rig.ward().station
	rig.tick_for(0.3)
	rig.calling[0] = true
	rig.tick_for(0.3)
	return rig

# ---------------------------------------------------------------------------------------------
# 4. The clock fallback.

func test_clock_fallback(t: T) -> void:
	var rig := Rig.new(true, false, {&"ward.lift_clock": 1.0})
	var w := rig.ward()
	t.check(not w.called, "ward.lift_clock on: no call")
	rig.tick_for(1.5)
	t.check(w.phase == &"away" and w.collection_at > 590.0, "the clock: the lift returns in ten minutes (%.1f)" % w.collection_at)
	t.eq(rig.events("ward_departed").size(), 1, "the clock's departure line")
	t.check(not (rig.clients[0].latest.ward as Dictionary).has("extras"), "no station on screen")
	rig.meet_quota()
	rig.bodies[0] = w.station
	rig.tick_for(0.3)
	rig.calling[0] = true
	rig.tick_for(0.5)
	t.check(rig.events("called").is_empty(), "the station does nothing on the clock")

# ---------------------------------------------------------------------------------------------
# 5. The web.

## Brings the hand to player "two" standing in `house`'s entry; returns once they are caught (or not).
func _catch_two(rig: Rig, house: int) -> bool:
	var w := rig.ward()
	var fixture: House = w.houses[house]
	rig.bodies[1] = fixture.to_world(Vector3(fixture.areas[&"entry"].x, 0.0, fixture.areas[&"entry"].z))
	rig.tick_for(0.3)
	rig.host.test_ward_noise(rig.bodies[1])
	return rig.until(func() -> bool: return w.caught.has("two"), 20.0)

func test_web_hangs_and_a_held_cut_frees(t: T) -> void:
	var rig := Rig.new(false, true)
	var w := rig.ward()
	rig.tick_for(1.5)
	# Caught in a house with no hang point, so the cocoon is carried to another house (and its cutter is not in the
	# house the hand is searching).
	var house := -1
	for i in w.houses.size():
		if i != 0 and not w.hang_points.any(func(p: Dictionary) -> bool: return int(p.house) == i):
			house = i
			break
	t.check(_catch_two(rig, house), "the hand catches the player")
	var contact: Dictionary = rig.events("ward_contact")[0]
	var point := int(contact["point"])
	var where: Vector3 = rig.bodies[1]
	t.eq(point, w.hang_point_for(where) if not w.webbed.has("two") else int(w.webbed["two"].point), "the nearest free hang point")
	t.check(absf(float(contact["hangAt"]) - float(contact["t"]) - Ward.CARRY_TIME) < 1e-6, "hung after the carry time")
	t.check(rig.events("ward_hung").is_empty(), "not hung yet: carried")
	t.check(rig.until(func() -> bool: return not rig.events("ward_hung").is_empty(), Ward.CARRY_TIME + 1.0), "then hung")
	var hung: Dictionary = rig.events("ward_hung")[0]
	t.check(absf(float(hung["t"]) - float(contact["hangAt"])) < 1e-6 and int(hung["point"]) == point, "at the carry's end, at that point")
	rig.tick_for(0.5)
	var hang: Vector3 = w.hang_points[point].hang
	var held_at: Move.Body = rig.player("two").body
	t.check(Vector3(held_at.x, held_at.y, held_at.z).distance_to(hang) < 0.02, "the host holds them at the hang point")
	t.eq(String(rig.player("two").status), "caught", "caught while hung")
	var pinned := rig.player("two").body
	rig.bodies[1] = hang + Vector3(2, 0, 0)
	rig.tick_for(0.3)
	t.check(rig.player("two").body.x == pinned.x, "a hung player cannot move")
	for c in rig.clients:
		var e: Dictionary = c.latest.ward.extras
		t.check(e.web.has("two") and int(e.web.two.point) == point and float(e.web.two.hangAt) == float(contact["hangAt"]), "both clients have the catch, its point and its hang time")
	# Wait for the hand to go (a cut right under a searching hand is the players' risk, not this test's).
	t.check(rig.until(func() -> bool: return w.encounter == &"idle", 40.0), "the hand has gone")
	# A short hold does nothing.
	rig.bodies[0] = w.hang_points[point].at + Vector3(0.3, 0, 0)
	rig.tick_for(0.4)
	rig.held[0] = true
	rig.tick_for(Ward.CUT_TIME * 0.5)
	rig.held[0] = false
	rig.tick_for(0.3)
	t.check(rig.events("ward_cut").is_empty() and rig.events("ward_cut_stop").size() == 1, "let go early: no cut")
	var loaded_before := rig.events("ward_line_loaded").size()
	rig.held[0] = true
	rig.tick_for(Ward.CUT_TIME + 0.4)
	rig.held[0] = false
	var cut := rig.events("ward_cut")
	t.check(cut.size() == 1 and str(cut[0]["by"]) == "one" and str(cut[0]["id"]) == "two", "held for the cut time: cut down (%s; caught %s, cuts %s)" % [str(cut), str(w.caught), str(w.cuts)])
	var start: Dictionary = rig.events("ward_cut_start")[-1]
	t.check(not cut.is_empty() and absf(float(cut[0]["t"]) - float(start["t"]) - Ward.CUT_TIME) < 0.06, "the cut took the cut time")
	t.check(rig.events("ward_line_loaded").size() == loaded_before + 1, "the cut is loud: his line loads")
	var healed := rig.events("healed")
	t.check(healed.size() == 1 and healed[0].get("cut") == true, "freed as a healed player is (healed)")
	t.eq(String(rig.player("two").status), "ok", "on their feet")
	var b := rig.player("two").body
	t.check(Vector3(b.x, b.y, b.z).distance_to(w.hang_points[point].at) < 0.02, "standing under where they hung")
	t.check(not w.caught.has("two") and not w.webbed.has("two"), "no longer caught")
	for c in rig.clients:
		t.check(not c.latest.ward.caught.has("two") and not (c.latest.ward.extras.web as Dictionary).has("two"), "both clients see them free")
	var rec := false
	for m in rig.host.state.crew.members:
		if m.id == "two":
			rec = m.active
	t.check(rec, "they record again")

func test_web_never_freed_is_left_behind(t: T) -> void:
	var rig := Rig.new(false, true)
	var w := rig.ward()
	rig.tick_for(1.5)
	var tape_id := _tape_of(rig, "two")
	t.check(_catch_two(rig, int(w.hang_points[0].house)), "caught")
	rig.tick_for(Ward.CARRY_TIME + 0.5)
	# A catch the instrument hears takes the player's tape off them (dropped if it holds readings) and gives them a
	# fresh one; in the web the instrument does not hear it, so the tape they were caught with still hangs with them.
	t.check(tape_id != "" and _tape_of(rig, "two") == tape_id, "the tape is not taken: it hangs with them (%s, now %s)" % [tape_id, _tape_of(rig, "two")])
	t.check(rig.host.state.crew.floor.is_empty(), "and nothing was dropped on the floor")
	w.collection_at = rig.host.state.t + 0.3
	rig.bodies[0] = rig.in_car("bank")
	rig.tick_for(0.8)
	w.depart_at = rig.host.state.t + 0.3
	rig.tick_for(1.0)
	t.eq(w.left_behind, ["two"] as Array[String], "the lift leaves without them")
	t.eq(String(rig.player("two").status), "caught", "left on the floor, caught, as a caught player always was")

static func _tape_of(rig: Rig, id: String) -> String:
	for m in rig.host.state.crew.members:
		if m.id == id:
			return m.tape.id
	return ""

# ---------------------------------------------------------------------------------------------
# 6. Off: nothing changes.

func test_flags_off_change_nothing(t: T) -> void:
	var rig := Rig.new(false, false)
	var w := rig.ward()
	t.check(not w.called and not w.web, "both off")
	t.check(w.extras().is_empty(), "no extras")
	rig.tick_for(1.5)
	t.check(w.phase == &"away" and w.collection_at > 590.0, "the clock as before")
	var block: Dictionary = rig.host.world()["ward"]
	t.check(not block.has("extras"), "the snapshot's block as before")
	t.eq(Wire.encode(block).size(), 13, "the wire's thirteen fields")
	for c in rig.clients:
		t.check(not (c.latest.ward as Dictionary).has("extras"), "clients see no extras")
	rig.meet_quota()
	rig.bodies[0] = w.station
	rig.tick_for(0.3)
	rig.calling[0] = true
	rig.tick_for(0.5)
	t.check(rig.events("called").is_empty() and rig.events("callRefused").is_empty(), "the station does nothing")
	# And HostRules: off unless asked, and only with the late floors.
	t.check(not HostRules.new(true, 1).ward_call and not HostRules.new(true, 1).ward_web, "off by default")
	var args := []
	for k in 48:
		args.append(false)
	args[0] = true
	args[1] = 1
	args[2] = []
	args[46] = true
	args[47] = true
	var script: Variant = HostRules
	var no_late: HostRules = script.callv("new", args)
	t.check(not no_late.ward_call and not no_late.ward_web, "asked without the late floors: still off")
	args[38] = true
	var old_ward: HostRules = script.callv("new", args)
	t.check(not old_ward.ward_call and not old_ward.ward_web, "with the old swapped-in Ward (ward_place off): still off")
	args[43] = true
	var late: HostRules = script.callv("new", args)
	t.check(late.ward_call and late.ward_web, "asked with the late floors and the Ward as a normal level: on (parameters 47 and 48)")

func test_wire_round_trip(t: T) -> void:
	var rig := _called_rig(true)
	var block: Dictionary = rig.host.world()["ward"]
	var raw := Wire.encode(block)
	t.eq(raw.size(), 15, "fifteen fields with extras")
	var back := Wire.decode(JSON.parse_string(JSON.stringify(raw)))
	t.check(back.has("extras") and back.extras.called == true and back.extras.has("hangPoints"), "the extras arrive")
	var tampered := raw.duplicate(true)
	tampered[14]["web"] = {"x": {"point": 99, "caughtAt": 0, "hangAt": 0}}
	t.check(Wire.decode(JSON.parse_string(JSON.stringify(tampered))).is_empty(), "a bad hang point is refused")
