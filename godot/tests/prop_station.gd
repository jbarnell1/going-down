# RN1, the Reactor as a generated place (sim/station.gd, sim/station_floor.gd, sim/run.gd "The Reactor",
# net/host_rules.gd reactor_place, net/host.gd's station block; docs/floors/native-late-floors.md). Checked here:
#   - the plan over many seeds: every named room, all of it walkable from the landing (nobody stranded), the loop
#     hall -> gallery -> crawl -> hall, the sightline from the lift door to the rotor clear and at least the hall's
#     length, the crawl creep-only (the four never route through it), at least five fuse spots, each reachable, a
#     walk from the cabinet and out of every look from the hall's centreline, the tape's table beside the lift door,
#     the four placed on seats 1 to 4 away from the lift, the car's zone void, the same seed the same plan;
#   - the deck: the Reactor at floor 7 (14, 21 with cycles) only with the flag; never drawn; floors 1 to 6 as before;
#   - the flag off: the deck is the old one, and a run is the old run tick for tick; the host starts the old overlay;
#   - the rules in a run: the lights hold power_hold after the first player passes the landing, then cut on host
#     time; the four never move while the power is on (players walking among them); the stir comes before anything
#     can reach anyone; the call is refused until the power is back; a standing body that reaches a player puts them
#     down by the run's down rules, and what they carried drops;
#   - crews of 1, 2 and 4 scripted bots fetch the fuse, restore the power, call the car and board on most seeds,
#     and the tape carried out is extracted; the station's block keeps every old field and crosses the wire.
extends RefCounted

const T = preload("res://tests/t.gd")
const Station = preload("res://sim/station.gd")
const SR = preload("res://sim/station_floor.gd")
const Floor = preload("res://sim/floor.gd")
const Places = preload("res://sim/places.gd")
const Run = preload("res://sim/run.gd")
const Move = preload("res://sim/move.gd")
const Sight = preload("res://sim/sight.gd")
const Follow = preload("res://sim/follow.gd")
const HostRules = preload("res://net/host_rules.gd")
const Review = preload("res://net/reactor_review.gd")
const Wire = preload("res://net/reactor_wire.gd")
const M = preload("res://sim/jsmath.gd")
const Session = preload("res://net/session.gd")
const LocalRoom = preload("res://net/local_room.gd")
const Room = preload("res://server/room.gd")
const RoomClient = preload("res://net/room_client.gd")
const WsServer = preload("res://net/ws_server.gd")
const Client = preload("res://net/client.gd")
const SECRET := "station-test-passphrase"
const TestPorts = preload("res://tests/test_ports.gd")
## Two ports of this process's test block (tests/test_ports.gd): the rule on, and the rule off.
static var PORT: int = TestPorts.port(TestPorts.STATION)
static var PORT_OFF: int = TestPorts.port(TestPorts.STATION_OFF)

const DT := 0.05
## Prints every event of crew_run (a debugging aid; tests leave it off).
static var trace := false

static func rules(depth: int, reactor: Variant, cycles := true, late := true) -> HostRules:
	var a: Array = [true, depth, Places.FULL, true, true, true, false, false, true, true, true]
	for _i in 8 + 9 + 7:
		a.append(false)
	a.append_array([false, false, false, late, false, false, false, cycles])
	if reactor != null:
		a.append_array([false, bool(reactor)])
	var script: GDScript = HostRules
	return script.callv("new", a)

static func _ids(n: int) -> Array[String]:
	var out: Array[String] = []
	for i in n:
		out.append("p%d" % i)
	return out

# ---------------------------------------------------------------------------------------------
# The plan.

func test_plan_properties(t: T) -> void:
	var n := 60 if t.quick else 300
	var hashes := {}
	for i in n:
		var seed := "station-%d" % i
		var depth := Places.REACTOR_FLOOR * (1 + i % 3)
		var plan := Station.generate_station(seed, depth)
		var a := plan.station
		var tag := "%s/%d" % [seed, depth]
		hashes[Floor.hash_plan(plan)] = true
		t.check(plan.place == Places.REACTOR, "%s: the place" % tag)
		var names: Dictionary = a["rooms"]
		for key: String in ["hall", "gallery", "crawl_v", "crawl_h", "switch", "west_0", "closet_0"]:
			t.check(names.has(key), "%s: room %s" % [tag, key])
		for key: String in ["lift_door", "sill", "plinth", "lockers", "time_cards", "rotor", "hall", "landing", "gallery",
				"glass", "crawl", "crawl_mouths", "fuse_spots", "cabinet", "bodies", "growths", "lamps"]:
			t.check(a.has(key), "%s: anchor %s" % [tag, key])
		# Nobody stranded: every walkable cell is reachable from the landing.
		var dist := Floor.distances_from(plan, plan.landing)
		var cut_off := 0
		for cy in plan.height:
			for cx in plan.width:
				if Floor.is_walkable(plan, 0, cx, cy) and dist[cy * plan.width + cx] < 0:
					cut_off += 1
		t.check(cut_off == 0, "%s: %d walkable cells cut off from the landing" % [tag, cut_off])
		# The loop: hall-gallery, gallery-crawl, crawl-crawl, crawl-hall, each a door.
		var links := {}
		for d in plan.doors:
			var ra := Floor.room_id_at(plan, 0, d.ax, d.ay)
			var rb := Floor.room_id_at(plan, 0, d.bx, d.by)
			links["%d-%d" % [mini(ra, rb), maxi(ra, rb)]] = true
		var pairs := [["hall", "gallery"], ["gallery", "crawl_v"], ["crawl_v", "crawl_h"], ["crawl_h", "hall"]]
		for p: Array in pairs:
			var x := int(names[p[0]])
			var y := int(names[p[1]])
			t.check(links.has("%d-%d" % [mini(x, y), maxi(x, y)]), "%s: the loop's link %s-%s" % [tag, p[0], p[1]])
		# The sightline: from the lift door up the hall to the rotor, clear, at least the hall's length.
		var line: Floor.Sightline = plan.sightlines[0]
		var hall: Rect2 = a["hall"]
		var rotor: Vector3 = (a["rotor"] as Dictionary)["at"]
		var door: Vector3 = a["lift_door"]
		t.check(line.length * plan.cell_size >= int(hall.size.y), "%s: sightline %d cells, hall %.0f m" % [tag, line.length, hall.size.y])
		t.check(Sight.has_line_of_sight(plan, Sight.Point3.make(door.x, 1.6, door.z - 0.4, 0), Sight.Point3.make(rotor.x, 1.6, rotor.z, 0)),
			"%s: the lift door sees the rotor" % tag)
		t.check(absf(door.z - 0.4 - rotor.z) >= hall.size.y, "%s: the sightline is as long as the hall" % tag)
		# The crawl: creep only, and the four's route never enters it.
		var crawl: Array = a["crawl"]
		t.check(crawl.size() >= 6, "%s: the crawl has cells" % tag)
		for c: Vector2i in crawl:
			t.check(Station.creep_only(plan, c.x, c.y) and Floor.is_walkable(plan, 0, c.x, c.y), "%s: crawl cell %s" % [tag, c])
		var mid: Vector2i = crawl[crawl.size() / 4]
		var hidden: Array[SR.Crew] = [SR.Crew.make("x", Move.Body.make(Station.wc(mid.x), Station.wc(mid.y), 0, 0.0), &"ok", &"creep", false, true)]
		var body4: Dictionary = (a["bodies"] as Array)[0]
		var b4: Vector3 = body4["at"]
		t.check(SR._route(plan, Move.Body.make(b4.x, b4.z, 0, 0.0), hidden).is_empty(), "%s: no route into the crawl" % tag)
		var around: Array[SR.Crew] = [SR.Crew.make("y", Move.Body.make(door.x, door.z - 1.0, 0, 0.0), &"ok", &"walk", false, true)]
		for b: Dictionary in a["bodies"]:
			var bat: Vector3 = b["at"]
			var route := SR._route(plan, Move.Body.make(bat.x, bat.z, 0, 0.0), around)
			t.check(not route.is_empty(), "%s: seat %d reaches the landing" % [tag, int(b["seat"])])
			for c in route:
				t.check(not Station.creep_only(plan, c.x, c.y), "%s: seat %d routes through the crawl" % [tag, int(b["seat"])])
		# The fuse spots.
		var spots: Array = a["fuse_spots"]
		t.check(spots.size() >= Station.MIN_FUSE_SPOTS, "%s: %d fuse spots" % [tag, spots.size()])
		var cab: Vector3 = (a["cabinet"] as Dictionary)["at"]
		var cab_cell := Station.cell_of(cab.x - (0.5 if cab.x > hall.get_center().x else -0.5), cab.z)
		var from_cab := Floor.distances_from(plan, Floor.Pos.make(0, cab_cell.x, cab_cell.y))
		for f: Vector3 in spots:
			var fc := Station.cell_of(f.x, f.z)
			t.check(Floor.is_walkable(plan, 0, fc.x, fc.y) and dist[fc.y * plan.width + fc.x] >= 0, "%s: fuse spot %s reachable" % [tag, f])
			t.check(from_cab[fc.y * plan.width + fc.x] >= Station.FUSE_WALK_MIN, "%s: fuse spot %s a walk from the cabinet" % [tag, f])
			t.check(not Station.seen_from_centreline(plan, f), "%s: fuse spot %s seen from the hall" % [tag, f])
		t.check(SR.fuse_index(plan) >= 0 and SR.fuse_index(plan) < spots.size(), "%s: the seed picks a spot" % tag)
		# The tape's table beside the lift door, on the landing.
		var plinth: Vector3 = a["plinth"]
		var land: Rect2 = a["landing"]
		t.check(Vector2(plinth.x - door.x, plinth.z - door.z).length() <= 3.5 and land.has_point(Vector2(plinth.x, plinth.z)), "%s: the table beside the lift door" % tag)
		# The four.
		var seats := []
		for b: Dictionary in a["bodies"]:
			var bat: Vector3 = b["at"]
			var bc := Station.cell_of(bat.x, bat.z)
			seats.append(int(b["seat"]))
			t.check(Floor.is_walkable(plan, 0, bc.x, bc.y) and not Station.creep_only(plan, bc.x, bc.y), "%s: seat %d on the floor" % [tag, int(b["seat"])])
			t.check(Vector2(bat.x - door.x, bat.z - door.z).length() >= 10.0, "%s: seat %d away from the lift" % [tag, int(b["seat"])])
		t.eq(seats, [1, 2, 3, 4], "%s: four seats" % tag)
		# The car's zone beyond the landing is void.
		var car := Run.car_geometry(plan)
		for u: float in [0.5, 1.5, 2.5, 3.5]:
			for v: float in [-1.5, 0.0, 1.5]:
				var cb := Run.car_body(car, u, v)
				var cc := Station.cell_of(cb.x, cb.z)
				t.check(Floor.cell_at(plan, 0, cc.x, cc.y) == Floor.VOID, "%s: the car's zone at %.1f,%.1f" % [tag, u, v])
		t.check(car.wall == &"s", "%s: the car opens north into the landing" % tag)
		# The same seed, the same plan and anchors.
		var again := Station.generate_station(seed, depth)
		t.check(Floor.hash_plan(again) == Floor.hash_plan(plan) and var_to_str(again.station) == var_to_str(plan.station), "%s: the same plan twice" % tag)
	t.check(hashes.size() >= n * 9 / 10, "the seeds give different stations: %d of %d" % [hashes.size(), n])

func test_the_deck(t: T) -> void:
	var with := Places.with_reactor(Places.FULL)
	var cyc := Places.with_reactor(Places.with_cycles(Places.FULL))
	for i in 100:
		var seed := "deck-r-%d" % i
		for d in range(0, 7):
			t.check(Places.place_at(seed, d, with) == Places.place_at(seed, d, Places.FULL), "%s d%d unchanged above the Reactor" % [seed, d])
		t.eq(Places.place_at(seed, 7, with), Places.REACTOR, "%s: floor 7" % seed)
		t.eq(Places.place_at(seed, 7, Places.FULL), Places.place_at(seed, 7, Places.FULL), "%s: same twice" % seed)
		t.check(Places.place_at(seed, 7, Places.FULL) != Places.REACTOR, "%s: no Reactor without the marker" % seed)
		for d in range(8, 30):
			var p := Places.place_at(seed, d, with)
			t.check(p != Places.REACTOR and Places.FULL.has(p), "%s d%d drew %s" % [seed, d, p])
			var c := Places.place_at(seed, d, cyc)
			t.check((c == Places.REACTOR) == (Places.local_depth(d, cyc) == 7), "%s d%d with cycles is %s" % [seed, d, c])
		t.eq(Places.generate(seed, 7, with).place, Places.REACTOR, "%s: the generator" % seed)
	t.eq(rules(7, null).deck, rules(7, false).deck, "the flag off: the old deck")
	t.check(not rules(7, false).deck.has(Places.REACTOR), "the flag off: no Reactor in the deck")
	t.check(rules(7, true).deck.has(Places.REACTOR) and rules(7, true).reactor_place, "the flag on: the Reactor in the deck")
	t.check(not rules(7, true, false, false).deck.has(Places.REACTOR), "the flag needs the late floors")

## The flag off: a run started at floor 7 (and one from floor 1) is the run without the new parameters, tick by tick.
func test_flag_off_is_the_old_run(t: T) -> void:
	for depth: int in [1, 7]:
		var a := rules(depth, null)
		var b := rules(depth, false)
		var sa := a.prepare(Run.create_run("off-%d" % depth, _ids(2), a.deck, true, true, true))
		var sb := b.prepare(Run.create_run("off-%d" % depth, _ids(2), b.deck, true, true, true))
		var same := true
		for k in 900:
			var ia := _walk_inputs(sa, k)
			var ib := _walk_inputs(sb, k)
			var ra := a.step(sa, ia, DT)
			var rb := b.step(sb, ib, DT)
			sa = ra.state
			sb = rb.state
			if var_to_str(ra.events) != var_to_str(rb.events) or sa.phase != sb.phase or sa.station != null or sb.station != null:
				same = false
				t.check(false, "depth %d tick %d: the runs part" % [depth, k])
				break
			for i in sa.players.size():
				if not sa.players[i].body.same(sb.players[i].body) or sa.players[i].status != sb.players[i].status:
					same = false
			if not same:
				t.check(false, "depth %d tick %d: the players part" % [depth, k])
				break
		t.check(same and Floor.hash_plan(sa.plan) == Floor.hash_plan(sb.plan) and sa.plan.place != Places.REACTOR, "depth %d: the same run, no station" % depth)

## Everyone walks out of the car and up the floor (the same inputs for any two runs given the same state).
static func _walk_inputs(s: Run.RunState, k: int) -> Array[Run.PlayerInput]:
	var out: Array[Run.PlayerInput] = []
	for i in s.players.size():
		var p := s.players[i]
		var b := p.body
		if k > 40 and (p.status == &"ok"):
			b = Run.move_in_run(s, b, -s.car.in_x * 2.5 * DT, -s.car.in_z * 2.5 * DT + (0.3 * DT if i == 1 else 0.0), 0.3)
		out.append(Run.PlayerInput.make(p.id, b, 1.65, 0.0, 0.0, 90.0, 70.0))
	return out

# ---------------------------------------------------------------------------------------------
# The rules in a run.

## The lights hold, then cut; the four never move under power; the stir before any stand; the call refused until
## the power is back.
func test_power_and_the_four(t: T) -> void:
	var seeds := 6 if t.quick else 20
	for i in seeds:
		var r := rules(7, true)
		var s := r.prepare(Run.create_run("power-%d" % i, _ids(2), r.deck, true, true, true))
		var tag := "power-%d" % i
		var hold_at := -1.0
		var cut_at := -1.0
		var stir_at := -1.0
		var stand_at := -1.0
		var refused_power := 0
		var moved_lit := false
		var bodies0: Array = []
		var targets: Array = []
		for k in 3000:
			# p0 walks among the four; p1 stands by the car door pressing the call.
			var inputs: Array[Run.PlayerInput] = []
			for p in s.players:
				var b := p.body
				var inp: Run.PlayerInput
				if s.station == null:
					inp = Run.PlayerInput.make(p.id, b, 1.65, 0.0, 0.0, 90.0, 70.0)
				else:
					var st: SR.StationFloor = s.station
					if bodies0.is_empty():
						for bd in st.bodies:
							bodies0.append(bd.body)
							targets.append(bd.body)
					var goal: Move.Body = targets[(k / 200) % targets.size()] if p.id == "p0" else Run.car_body(s.car, -1.0, 0.0)
					b = _toward(s, b, goal, 3.0 * DT)
					inp = Run.PlayerInput.make(p.id, b, 1.65, 0.0, 0.0, 90.0, 70.0)
					inp.call = p.id == "p1" and k % 2 == 0
				inputs.append(inp)
			var step := r.step(s, inputs, DT)
			s = step.state
			for e in step.events:
				match str(e["type"]):
					"powerHold": hold_at = s.t
					"powerCut": cut_at = s.t
					"stationStir": stir_at = s.t
					"bodyStands":
						if stand_at < 0.0:
							stand_at = s.t
					"callRefused":
						if str(e.get("reason", "")) == "power":
							refused_power += 1
					"caught":
						t.check(stand_at >= 0.0, "%s: a catch before any body stood" % tag)
			if s.station != null and cut_at < 0.0 and not bodies0.is_empty():
				var st2: SR.StationFloor = s.station
				for j in 4:
					if not st2.bodies[j].body.same(bodies0[j]) or st2.bodies[j].phase != "still":
						moved_lit = true
			if stand_at >= 0.0 and s.t > stand_at + 3.0:
				break
		t.check(hold_at > 0.0 and cut_at > 0.0 and absf(cut_at - hold_at - SR.POWER_HOLD) <= DT + 1e-6, "%s: the cut %.2f s after the hold" % [tag, cut_at - hold_at])
		t.check(not moved_lit, "%s: a body moved while the power was on" % tag)
		t.check(stir_at > cut_at and stand_at > stir_at + 1.0, "%s: the stir (%.2f) before anything stands (%.2f)" % [tag, stir_at, stand_at])
		t.check(refused_power > 0, "%s: the call refused without power" % tag)
		t.check(s.phase == &"away", "%s: the car never came without power" % tag)

## A standing body reaching a player puts them down by the run's down rules, and the fuse they carried drops.
func test_caught_goes_down_and_drops(t: T) -> void:
	var r := rules(7, true)
	var s := r.prepare(Run.create_run("catch-0", _ids(2), r.deck, true, true, true))
	var downed := false
	var dropped := false
	for k in 4000:
		var inputs: Array[Run.PlayerInput] = []
		for p in s.players:
			var b := p.body
			var use := false
			if s.station != null and p.status == &"ok":
				var st: SR.StationFloor = s.station
				if p.id == "p0":
					# Take the fuse, then walk straight to seat 1 and stand there.
					var goal := Move.Body.make(st.fuse.x, st.fuse.z, 0, 0.0) if st.holder != "p0" else st.bodies[0].body
					b = _toward(s, b, goal, 3.0 * DT)
					use = k % 2 == 0
				else:
					b = _toward(s, b, Move.Body.make(b.x, (st.plan.station["hall"] as Rect2).end.y - 1.0, 0, 0.0), 3.0 * DT)
			var inp := Run.PlayerInput.make(p.id, b, 1.65, 0.0, 0.0, 90.0, 70.0)
			inp.use = use
			inputs.append(inp)
		var step := r.step(s, inputs, DT)
		s = step.state
		for e in step.events:
			if str(e["type"]) == "downed" or (str(e["type"]) == "caught" and str(e.get("by", "")) == "station"):
				downed = downed or s.players[0].status == &"down"
			if str(e["type"]) == "fuseDropped":
				dropped = true
		if downed and dropped:
			break
	t.check(downed, "the player went down")
	t.check(dropped and s.station != null and (s.station as SR.StationFloor).holder == "", "the fuse dropped")
	t.check(s.down.has("p0"), "down by the run's own rules (a Downed with its timer)")

# ---------------------------------------------------------------------------------------------
# Crews of scripted bots.

func test_crews_finish(t: T) -> void:
	var seeds := 6 if t.quick else 24
	for size: int in [1, 2, 4]:
		var done := 0
		var extracted := 0
		var fails := PackedStringArray()
		for i in seeds:
			var res := crew_run("crew-%d-%d" % [size, i], size)
			if bool(res["banked"]) and bool(res["restored"]):
				done += 1
			else:
				fails.append("%s:%s" % [i, res["why"]])
			if bool(res["extracted"]):
				extracted += 1
		t.note("crew of %d: %d of %d finished, tape out %d (%s)" % [size, done, seeds, extracted, ", ".join(fails)])
		# The quick set leaves statistical thresholds to the default and full runs (tests/t.gd).
		t.check(done * 2 > seeds if not t.quick else done > 0, "crew of %d: most seeds finish (%d of %d)" % [size, done, seeds])
		t.check(extracted > 0, "crew of %d: the tape gets out" % size)

## One run: bot 0 takes the tape, waits by the fuse for the cut, installs it, calls the car and hides in the crawl;
## the others hide in the crawl at once; everyone boards when the doors open.
static func crew_run(seed: String, size: int) -> Dictionary:
	var r := rules(7, true)
	var s := r.prepare(Run.create_run(seed, _ids(size), r.deck, true, true, true))
	var tanks := {}
	var out := {"banked": false, "restored": false, "extracted": false, "why": "time"}
	for k in int(400.0 / DT):
		var inputs: Array[Run.PlayerInput] = []
		var st: SR.StationFloor = s.station
		# The fetcher: the first bot on its feet (another takes over when it is down).
		var lead := -1
		for j in s.players.size():
			if s.players[j].status == &"ok":
				lead = j
				break
		for n in s.players.size():
			var p := s.players[n]
			var i := 0 if n == lead else n + 1
			var b := p.body
			var inp: Run.PlayerInput
			if st == null or p.status != &"ok":
				inp = Run.PlayerInput.make(p.id, b, 1.65, 0.0, 0.0, 90.0, 70.0)
				inputs.append(inp)
				continue
			var goal: Move.Body
			var use := false
			var call := false
			var hide := _hideout(st.plan)
			var boarding := s.phase == &"boarding"
			var fallen: Run.RunPlayer = null
			for q in s.players:
				if q.status == &"down" and q.id != p.id:
					fallen = q
			if fallen != null and i != 0 and not boarding:
				# A crewmate is down: go and hold F beside them.
				goal = fallen.body
				use = M.hypot2(fallen.body.x - b.x, fallen.body.z - b.z) < 1.2
			elif boarding:
				goal = Run.car_body(s.car, Run.CAR_DEPTH - 0.6, -1.2 + 0.8 * float(i))
			elif i == 0 and not st.collected and st.cassette_holder == "":
				goal = Move.Body.make(st.tape.x, st.tape.z, 0, 0.0)
				use = k % 2 == 0
			elif i == 0 and st.power == SR.Power.NORMAL:
				goal = Move.Body.make(st.fuse.x, st.fuse.z, 0, 0.0)
			elif i == 0 and st.power == SR.Power.EMERGENCY and st.holder != p.id:
				goal = Move.Body.make(st.fuse.x, st.fuse.z, 0, 0.0)
				use = k % 2 == 0
			elif i == 0 and st.power == SR.Power.EMERGENCY:
				goal = Move.Body.make(st.cabinet.x - 0.4 * signf(st.cabinet.x - b.x), st.cabinet.z, 0, 0.0)
				use = k % 2 == 0
			elif st.power == SR.Power.RESTORED:
				# The power is back: everyone to the car; the first there calls it.
				goal = Run.car_body(s.car, -1.0, -0.8 + 0.5 * float(i % 4))
				call = s.phase == &"away"
			elif i != 0 and st.hold_left < 0.0 and st.power == SR.Power.NORMAL:
				# Somebody has to pass the landing for the lights to go.
				goal = Move.Body.make(b.x, (st.plan.station["landing"] as Rect2).position.y - 2.0, 0, 0.0)
			else:
				goal = hide
			var in_crawl := _in_crawl(st.plan, b)
			var tank: float = tanks.get(p.id, 7.0)
			var sprint := st.power != SR.Power.NORMAL and not in_crawl and tank > 0.0 and not (i == 0 and st.power == SR.Power.EMERGENCY and st.holder != p.id and M.hypot2(goal.x - b.x, goal.z - b.z) < 1.0)
			var speed := 1.2 if in_crawl else (5.0 if sprint else 3.0)
			tanks[p.id] = maxf(0.0, tank - DT) if sprint else minf(7.0, tank + DT * 7.0 / 8.0)
			b = _toward(s, b, goal, speed * DT)
			inp = Run.PlayerInput.make(p.id, b, 1.65, 0.0, 0.0, 90.0, 70.0)
			inp.gait = &"creep" if in_crawl else (&"sprint" if sprint else &"walk")
			inp.use = use
			inp.call = call
			inputs.append(inp)
		var step := r.step(s, inputs, DT)
		s = step.state
		for e in step.events:
			if trace and str(e["type"]) not in ["voteChanged", "indicator", "holdChanged"]:
				print("%.2f %s" % [s.t, str(e).left(160)])
			match str(e["type"]):
				"powerRestored": out["restored"] = true
				"tapeExtracted": out["extracted"] = true
				"banked":
					out["banked"] = true
					out["why"] = ""
				"wiped": out["why"] = "wiped"
		if bool(out["banked"]) or str(out["why"]) == "wiped":
			break
	if str(out["why"]) == "time":
		var st: SR.StationFloor = s.station
		out["why"] = "time/%s/%s" % [s.phase, st.power if st != null else -1]
	return out

static func _hideout(plan: Floor.FloorPlan) -> Move.Body:
	var crawl: Array = plan.station["crawl"]
	var c: Vector2i = crawl[(crawl.size() - 3) / 2]
	return Move.Body.make(Station.wc(c.x), Station.wc(c.y), 0, 0.0)

static func _in_crawl(plan: Floor.FloorPlan, b: Move.Body) -> bool:
	var c := Station.cell_of(b.x, b.z)
	return Station.creep_only(plan, c.x, c.y)

## Moves a body up to `dist` toward `goal` through the plan and the car (the way a player walks it).
static func _toward(s: Run.RunState, b: Move.Body, goal: Move.Body, dist: float) -> Move.Body:
	var plan := s.plan
	var car := s.car
	var b_in := Run.in_car(car, b)
	var g_in := Run.in_car(car, goal)
	var aim: Move.Body = goal
	if b_in and not g_in:
		var l := Run.car_local(car, b.x, b.z)
		aim = Run.car_body(car, -0.8, 0.0) if absf(l[1]) < 0.4 else Run.car_body(car, l[0], 0.0)
	elif not b_in:
		var here := Move.cell_of(plan, b)
		var there := plan.landing if g_in else Move.cell_of(plan, goal)
		if here.x == there.x and here.y == there.y:
			if g_in:
				var l2 := Run.car_local(car, b.x, b.z)
				aim = goal if absf(l2[1]) < 0.3 else Run.car_body(car, -0.5, 0.0)
		else:
			var path := Floor.find_path(plan, here, there)
			if path.size() >= 2:
				var walk := Follow.PathWalk.make(path, 1)
				return Follow.step_path_walk(plan, walk, b, dist, 0.3)
	var dx := aim.x - b.x
	var dz := aim.z - b.z
	var d := M.hypot2(dx, dz)
	if d < 1e-6:
		return b
	var step := minf(dist, d)
	return Run.move_in_run(s, b, dx / d * step, dz / d * step, 0.3)

# ---------------------------------------------------------------------------------------------
# The rooms.

## The solo room: floor 7 from the picker is the station with the flag on (no overlay, the block native from the
## first snapshot, the client's plan the host's, the tape on its table on every sandbox visit), and the old overlay
## with reactor_place off.
func test_solo_room_on_and_off(t: T) -> void:
	var original := Session.deck
	Session.deck = Places.FULL
	for on: bool in [true, false]:
		var room := LocalRoom.new()
		room.open_local("station-solo", "Tester", true)
		room.late_archive_root = ""
		room.reactor_place = on
		for visit in 2:
			t.check(room.start_playtest(7), "%s visit %d: floor 7 starts" % [on, visit])
			var world: Dictionary = room.host.world()
			t.check(world.has("reactor"), "%s visit %d: the block from the first snapshot" % [on, visit])
			if on:
				t.check(room.host._reactor_review == null and room.host.state.plan.place == Places.REACTOR, "on: no overlay, the place is the station")
				t.check(world["reactor"].get("native", false) == true and world["reactor"]["cassette"] == false, "on visit %d: native, the tape on its table" % visit)
			else:
				t.check(room.host._reactor_review != null and room.host.state.plan.place != Places.REACTOR and not world["reactor"].has("native"), "off: today's overlay")
			for i in 10:
				room.poll(visit * 2.0 + i * 0.05)
			var l: Variant = room.client.latest
			t.check(l != null and l.has("reactor") and bool(l["reactor"].get("native", false)) == on and int(l.depth) == 7, "%s visit %d: the client has the block" % [on, visit])
			var plan := Session.plan_for(room.host.state.seed, 7, room.client.floor_deck)
			t.check(Floor.hash_plan(plan) == Floor.hash_plan(room.host.state.plan), "%s visit %d: the client's floor is the host's" % [on, visit])
		room.leave()
	Session.deck = original

## The server's room: the station at floor 7 for two clients over the network, the same plan on both, and the lobby
## flag; `reactor_place=0` gives today's overlay.
func test_server_room_two_clients(t: T) -> void:
	for on: bool in [true, false]:
		var say := func(_l: String) -> void: pass
		var ws := WsServer.new(SECRET, false, say)
		var port := PORT if on else PORT_OFF
		ws.listen(port, "127.0.0.1")
		var room := Room.new(ws, say)
		room.fixed_seed = "station-net"
		room.quota = false
		room.configure_campaign_trades({} if on else {"reactor_place": "0"})
		room.first_depth = 7
		var clients: Array[RoomClient] = []
		for name: String in ["Ana", "Bo"]:
			var rc := RoomClient.new()
			rc.connect_to("ws://127.0.0.1:%d" % port, SECRET, name)
			clients.append(rc)
		var now := 0.0
		var readied := false
		var seen := false
		while now < 25.0 and not seen:
			now += 0.02
			ws.poll(now)
			room.update(now)
			var all_lobby := true
			seen = true
			for rc in clients:
				rc.poll(now)
				all_lobby = all_lobby and rc.status == "lobby"
				var l: Variant = rc.client.latest if rc.client != null else null
				seen = seen and l != null and l.has("reactor") and int(l.depth) == 7
			if all_lobby and not readied:
				readied = true
				for rc in clients:
					rc.set_ready(true)
			OS.delay_msec(2)
		t.check(seen, "%s: both clients have the Reactor's block at floor 7" % on)
		if seen:
			t.check(room.rules.reactor_place == on and (room.host.state.plan.place == Places.REACTOR) == on, "%s: the room's flag and the place" % on)
			for rc in clients:
				t.check(bool(rc.client.latest.reactor.get("native", false)) == on, "%s: native on the wire" % on)
				var plan := Session.plan_for(room.host.state.seed, 7, rc.client.floor_deck)
				t.check(Floor.hash_plan(plan) == Floor.hash_plan(room.host.state.plan), "%s: the client's floor is the host's" % on)
		for rc in clients:
			if rc.status != "closed":
				rc.leave()
		for k in 10:
			ws.poll(now + k * 0.02)
			room.update(now + k * 0.02)
		ws.stop()

# ---------------------------------------------------------------------------------------------
# The block.

func test_block_fields_and_wire(t: T) -> void:
	var plan := Station.generate_station("block-0", 7)
	var st := SR.make(plan)
	var rp := Run.RunPlayer.new()
	rp.id = "p0"
	rp.body = Move.Body.make(10.0, 20.0, 0, 0.0)
	var block := Review.native_snapshot(st, {"p0": rp}, null)
	block["archive"] = {"recovered": false, "discovered": false, "playing": {}}
	for key: String in ["power", "time", "holder", "fuseUses", "cassette", "lift", "crew", "status", "cassetteHolder",
			"extracted", "fuseAt", "tapeAt", "seed", "seq", "rev", "players", "low"]:
		t.check(block.has(key), "the block keeps %s" % key)
	t.check(block["native"] == true and float(block["holdLeft"]) == -1.0, "the block says native, and no hold yet")
	var back: Variant = Wire.decode(Wire.encode(block))
	t.check(back is Dictionary, "the block crosses the wire")
	if back is Dictionary:
		var d: Dictionary = back
		t.check(d["native"] == true and d["seats"] == [1, 2, 3, 4] and float(d["holdLeft"]) == -1.0 and d["crew"].size() == 4, "native, seats and the hold back")
		t.check(d["fuseAt"] == block["fuseAt"] and d["tapeAt"] == block["tapeAt"] and d["status"]["p0"] == "up", "positions and status back")
	# The old block (no native) still encodes to 15 slots.
	var old := block.duplicate()
	old.erase("native")
	t.eq(Wire.encode(old).size(), 15, "the old block's size")
