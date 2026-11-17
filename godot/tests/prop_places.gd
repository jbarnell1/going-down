# The place deck (sim/places.gd; North Star A2 and B11, owner decisions of 17 Nov): the prison at depth 0,
# Clinic at 1 and 2, the Annex at 3, the Playroom at 4, then a seeded draw that never repeats the floor
# above; one way to make a plan, used by the host's run and by every client; the resident each place
# brings. Checked here:
#   - the order over many seeds, and no place twice running from 5 on;
#   - Places.generate makes each place with its own generator, the same plan every time, and every
#     place's car zone (Annex and Playroom included) is void where the 4 m car stands;
#   - a run takes a deck: none given is Clinic only (the run every stored result was recorded from), and
#     a run made without one, ridden to depth 4, stands on the stored Clinic floors (floors.json);
#   - the game's room (net/local_room.gd, the room a server runs, with Session.deck as the game sets it)
#     rides a run down to depth 4: at every floor the host's plan and the client's plan are the same plan
#     (same hash) and say clinic, clinic, annex, playroom;
#   - the Temp keeps the Orderly's Stillness for now; the Minder (not a Stillness resident) wanders in
#     plain sight and never takes anyone; the Playroom is walkable from its landing.
extends RefCounted

const T = preload("res://tests/t.gd")
const Places = preload("res://sim/places.gd")
const Run = preload("res://sim/run.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Entity = preload("res://sim/entity.gd")
const Clinic = preload("res://sim/clinic.gd")
const Annex = preload("res://sim/annex.gd")
const Playroom = preload("res://sim/playroom.gd")
const Prison = preload("res://sim/prison.gd")
const Session = preload("res://net/session.gd")
const HostRules = preload("res://net/host_rules.gd")
const LocalRoom = preload("res://net/local_room.gd")
const Client = preload("res://net/client.gd")
const Golden = preload("res://tests/golden.gd")
const Host = preload("res://net/host.gd")
const Transport = preload("res://net/transport.gd")
const Protocol = preload("res://net/protocol.gd")
const Pose = preload("res://net/pose.gd")

const ORDER: Array[StringName] = [&"prison", &"clinic", &"clinic", &"annex", &"playroom"]

func test_the_order_and_no_repeats(t: T) -> void:
	var seeds := 200
	var deepest := 30
	var counts := {}
	var bad := PackedStringArray()
	for i in seeds:
		var seed := "deck-%d" % i
		var prev := &""
		for depth in range(0, deepest + 1):
			var p := Places.place_at(seed, depth)
			if depth < ORDER.size():
				if p != ORDER[depth]:
					bad.append("%s d%d is %s" % [seed, depth, p])
			else:
				counts[p] = int(counts.get(p, 0)) + 1
				if p == prev:
					bad.append("%s d%d repeats %s" % [seed, depth, p])
				if not Places.FULL.has(p):
					bad.append("%s d%d drew %s, not in the deck" % [seed, depth, p])
			if Places.place_at(seed, depth) != p:
				bad.append("%s d%d differs on a second call" % [seed, depth])
			prev = p
	t.check(bad.is_empty(), "the order: %s" % ", ".join(bad.slice(0, 6)))
	# Not vacuous: the draw from 5 uses all three places, roughly evenly.
	var drawn := seeds * (deepest - 4)
	for p: StringName in Places.FULL:
		var n := int(counts.get(p, 0))
		t.check(n > drawn / 5, "%s drawn only %d times of %d" % [p, n, drawn])
	t.note("%d seeds: prison, clinic, clinic, annex, playroom at depths 0 to 4; depths 5 to %d drew %s with no place twice running" % [seeds, deepest, str(counts)])
	# Other decks: Clinic only is every floor a Clinic (the prison stays at 0).
	for depth in range(1, 12):
		t.eq(Places.place_at("x", depth, Places.CLINIC_ONLY), &"clinic", "Clinic only at depth %d" % depth)
	t.eq(Places.place_at("x", 0, Places.CLINIC_ONLY), &"prison", "the prison is depth 0 in any deck")

func test_generate_is_each_places_own_generator(t: T) -> void:
	var n := 3 if t.quick else 12
	for i in n:
		var seed := "gen-%d" % i
		t.eq(Floor.hash_plan(Places.generate(seed, 0)), Floor.hash_plan(Prison.prison_plan()), "%s d0 is the prison" % seed)
		for depth: int in [1, 2]:
			t.eq(Floor.hash_plan(Places.generate(seed, depth)), Floor.hash_plan(Clinic.generate_clinic(seed, depth)), "%s d%d is the Clinic" % [seed, depth])
		t.eq(Floor.hash_plan(Places.generate(seed, 3)), Floor.hash_plan(Annex.generate_annex(seed, 3)), "%s d3 is the Annex" % seed)
		t.eq(Floor.hash_plan(Places.generate(seed, 4)), Floor.hash_plan(Playroom.generate_playroom(seed, 4)), "%s d4 is the Playroom" % seed)
		for depth in range(0, 8):
			var p := Places.generate(seed, depth)
			t.eq(p.place, Places.place_at(seed, depth), "%s d%d: the plan says its place" % [seed, depth])
			t.eq(Floor.hash_plan(p), Floor.hash_plan(Places.generate(seed, depth)), "%s d%d: the same plan twice" % [seed, depth])
		# Clinic only makes the Clinic at every depth.
		for depth: int in [3, 4, 6]:
			t.eq(Floor.hash_plan(Places.generate(seed, depth, Places.CLINIC_ONLY)), Floor.hash_plan(Clinic.generate_clinic(seed, depth)), "%s d%d Clinic only" % [seed, depth])
	t.note("%d seeds: depth 0 the prison, 1 and 2 the Clinic, 3 the Annex, 4 the Playroom, each from its own generator" % n)

func test_every_places_car_zone_fits_the_car(t: T) -> void:
	var n := 4 if t.quick else 20
	var checked := {}
	var cells := 0
	for i in n:
		for depth in range(0, 9):
			var p := Places.generate("car-%d" % i, depth)
			if depth == 0 and i > 0:
				continue
			checked[p.place] = int(checked.get(p.place, 0)) + 1
			var c := Run.car_geometry(p)
			var s := float(p.cell_size)
			t.check(absf((c.rect.x1 - c.rect.x0) * (c.rect.z1 - c.rect.z0) - Run.CAR_WIDTH * Run.CAR_DEPTH) < 1e-6, "%s d%d: the car is not 4 m by 4 m" % [p.place, depth])
			var x0 := floori((c.rect.x0 + 1e-6) / s)
			var x1 := floori((c.rect.x1 - 1e-6) / s)
			var z0 := floori((c.rect.z0 + 1e-6) / s)
			var z1 := floori((c.rect.z1 - 1e-6) / s)
			var bad := PackedStringArray()
			for y in range(z0, z1 + 1):
				for x in range(x0, x1 + 1):
					if not Floor.in_bounds(p, x, y):
						continue
					for level in 2:
						cells += 1
						if Floor.cell_at(p, level, x, y) != Floor.VOID or Floor.room_id_at(p, level, x, y) != -1:
							bad.append("L%d %d,%d" % [level, x, y])
			t.check(bad.is_empty(), "%s %s d%d: the car's space is not clear: %s" % [p.place, p.seed, depth, ", ".join(bad.slice(0, 4))])
			t.check(Floor.is_walkable(p, p.landing.level, p.landing.x, p.landing.y), "%s d%d: the landing is not walkable" % [p.place, depth])
	for place: StringName in [&"prison", &"clinic", &"annex", &"playroom"]:
		t.check(checked.has(place), "no %s floor checked" % place)
	t.note("floors checked %s: %d cells under or over the 4 m car, all void" % [str(checked), cells])

func test_the_playroom_is_walkable_from_its_landing(t: T) -> void:
	var n := 3 if t.quick else 20
	var walk := 0
	for i in n:
		var p := Places.generate("walk-%d" % i, 4)
		t.eq(p.place, &"playroom", "depth 4 is the Playroom")
		var dist := Floor.distances_from(p, p.landing)
		var unreached := 0
		for idx in dist.size():
			var q := Floor.pos_from_index(p, idx)
			if Floor.is_walkable(p, q.level, q.x, q.y):
				walk += 1
				if dist[idx] < 0:
					unreached += 1
		t.eq(unreached, 0, "walk-%d: walkable cells the landing cannot reach" % i)
		var e := p.entity_start
		t.check(Floor.is_walkable(p, e.level, e.x, e.y) and dist[Floor.pos_index(p, e)] > 0, "walk-%d: the Minder starts somewhere reachable" % i)
	t.note("%d Playrooms: %d walkable cells, all reached from the landing" % [n, walk])

func test_residents(t: T) -> void:
	var o := Places.resident(&"clinic")
	t.check(o.name == "Orderly" and o.stillness, "the Clinic's resident is the Orderly, a Stillness one")
	var tp := Places.resident(&"annex")
	t.check(tp.name == "Temp" and tp.stillness, "the Annex's resident is the Temp, a Stillness one")
	var mi := Places.resident(&"playroom")
	t.check(mi.name == "Minder" and not mi.stillness, "the Playroom's resident is the Minder, not a Stillness one")
	t.eq(Places.resident(&"prison").name, "", "the prison has no resident")
	t.eq(Places.entity_id(&"clinic", 2), "orderly-2", "the Clinic's entity id is as recorded")
	t.eq(Places.entity_id(&"annex", 3), "temp-3", "the Annex's entity id")

func test_a_run_takes_a_deck(t: T) -> void:
	var ids: Array[String] = ["a", "b"]
	var st := Run.create_run("deck-run", ids)
	t.eq(st.deck, Places.CLINIC_ONLY, "a run made without a deck is Clinic only")
	t.eq(HostRules.new(true, 1).deck, Places.CLINIC_ONLY, "host rules made without a deck are Clinic only")
	t.eq(Session.deck, Places.CLINIC_ONLY, "outside the game the clients' deck is Clinic only")
	var full := Run.create_run("deck-run", ids, Places.FULL)
	t.eq(full.deck, Places.FULL, "a run keeps the deck it is given")
	t.eq(full.plan.place, &"clinic", "floor 1 is the Clinic")
	t.eq(full.copy().deck, Places.FULL, "a copied run keeps its deck")
	for depth: int in [3, 4]:
		var r := HostRules.new(true, depth, Places.FULL)
		var s := r.prepare(Run.create_run("deck-run", ids))
		t.eq(s.deck, Places.FULL, "the rules put their deck on the run")
		t.eq(s.plan.place, ORDER[depth], "the rules' depth %d is the %s" % [depth, ORDER[depth]])
		var c := HostRules.new(true, depth).prepare(Run.create_run("deck-run", ids))
		t.eq(c.plan.place, &"clinic", "Clinic-only rules at depth %d" % depth)

# ---------------------------------------------------------------------------------------------
# A run made without a deck is the run every result was recorded from: ridden down from floor 1 to 4,
# every floor is the stored Clinic floor of that seed and depth (tests/golden/floors.json, "alpha" d1-4).

## Rides `st` down (the one player out on the landing, calling, then on the DOWN half), the resident
## parked so nobody is taken. Returns the state at each floor, floor 1 first.
static func _ride_run(st0: Run.RunState, to_depth: int) -> Array[Run.RunState]:
	var st := st0.copy()
	st.orderly = HostRules.parked_orderly(st)
	var id := st.players[0].id
	var body := st.players[0].body
	var out: Array[Run.RunState] = [st]
	for _k in roundi(400.0 * (to_depth - st.depth) / STEP):
		var call := false
		match st.phase:
			&"unloading":
				body = Run.car_body(st.car, -1.0, 0.0)
			&"away":
				body = Run.car_body(st.car, -1.0, 0.0)
				call = true
			&"boarding":
				body = Run.car_body(st.car, 2.0, 1.0)
		var inp := Run.PlayerInput.make(id, body, 1.65, 0.0, 0.0, 90.0, 70.0)
		inp.call = call
		var inputs: Array[Run.PlayerInput] = [inp]
		var r := Run.step_run(st, inputs, STEP)
		st = r.state
		for e in r.events:
			if e["type"] == "doorsClosed" and (e["pushedOut"] as Dictionary).has(id):
				body = e["pushedOut"][id]
			if e["type"] == "rodeDown":
				body = e["bodies"][id]
				st = st.copy()
				st.orderly = HostRules.parked_orderly(st)
				out.append(st)
		if st.depth >= to_depth or st.phase == &"ended":
			break
	return out

func test_a_run_without_a_deck_is_the_recorded_run(t: T) -> void:
	var wants: Variant = t.golden("floors.json", "floors")
	var ids: Array[String] = ["a"]
	var floors := _ride_run(Run.create_run("alpha", ids), 4)
	t.eq(floors.size(), 4, "floors ridden")
	for i in floors.size():
		var st := floors[i]
		var want: Variant = Golden.item(wants, i)
		if not t.check(want is Dictionary and want["seed"] == "alpha" and int(want["depth"]) == st.depth, "the golden's floor %d is not alpha d%d" % [i, st.depth]):
			continue
		t.eq(String(st.plan.place), str(want["place"]), "alpha d%d: the run's floor is the stored one's place" % st.depth)
		t.eq(Floor.hash_plan(st.plan), str(want["hash"]), "alpha d%d: the run's floor is the stored floor (floors.json)" % st.depth)
		t.eq(st.entity_id, "orderly-%d" % st.depth, "alpha d%d: the stored entity id" % st.depth)
	t.note("a run with no deck ridden to depth %d: every floor the stored Clinic floor of alpha" % floors[floors.size() - 1].depth)

# ---------------------------------------------------------------------------------------------
# A headless run down to depth 4 in the game's own room, host and client.

class Ride:
	var room: LocalRoom
	var t := 0.0
	var body: Move.Body = null
	var floors: Array[Dictionary] = []

const STEP := 0.05

static func _frame(r: Ride, call: bool) -> void:
	r.t += STEP
	r.room.poll(r.t)
	var lf := Client.LocalFrame.new()
	lf.body = r.body if r.body != null else Move.Body.make(0.0, 0.0, 0, 0.0)
	lf.call = call
	var f := r.room.frame(r.t, lf)
	if f != null and f.placed != null:
		r.body = f.placed

## Rides the room's run from where it stands to the next floor. False if it gets stuck.
static func _ride_one(r: Ride) -> bool:
	var host := r.room.host
	var from := host.state.depth
	for _k in roundi(300.0 / STEP):
		var st := host.state
		if st.phase == &"ended":
			return false
		if st.depth != from and st.phase == &"arriving" and r.room.client.local_depth == st.depth:
			return true
		var call := false
		match st.phase:
			&"unloading":
				r.body = Run.car_body(st.car, -1.0, 0.0)  # out on the landing: the car leaves when empty
			&"away":
				r.body = Run.car_body(st.car, -1.0, 0.0)
				call = true
			&"boarding":
				r.body = Run.car_body(st.car, 2.0, 1.0)  # the DOWN half
		_frame(r, call)
	return false

static func _stop(r: Ride) -> Dictionary:
	var host_plan := r.room.host.state.plan
	var c := r.room.client
	var client_plan := Session.plan_for(str(c.seed), c.local_depth)
	return {"depth": r.room.host.state.depth, "clientDepth": c.local_depth, "hostPlace": String(host_plan.place), "clientPlace": String(client_plan.place),
		"host": Floor.hash_plan(host_plan), "client": Floor.hash_plan(client_plan), "entity": r.room.host.state.entity_id}

func test_host_and_client_ride_to_the_annex_and_the_playroom(t: T) -> void:
	var was := Session.deck
	Session.deck = Places.FULL  # as the game sets it (client/main.gd)
	var r := Ride.new()
	r.room = LocalRoom.new()
	r.room.open_local("deck-ride", "rider", false)
	r.room.start_run()
	for _k in 40:
		_frame(r, false)
	r.floors.append(_stop(r))
	for depth in range(2, 5):
		if not t.check(_ride_one(r), "the run did not reach depth %d (phase %s)" % [depth, r.room.host.state.phase]):
			break
		for _k in 4:
			_frame(r, false)
		r.floors.append(_stop(r))
	r.room.leave()
	Session.deck = was
	t.eq(r.floors.size(), 4, "stops recorded")
	for f: Dictionary in r.floors:
		var d: int = f["depth"]
		t.eq(f["clientDepth"], d, "depth %d: the client is on the host's floor" % d)
		t.eq(f["client"], f["host"], "depth %d: the client's plan hash is the host's" % d)
		if d < ORDER.size():
			t.eq(f["hostPlace"], String(ORDER[d]), "depth %d: the host's plan is the %s" % [d, ORDER[d]])
			t.eq(f["clientPlace"], String(ORDER[d]), "depth %d: the client's plan is the %s" % [d, ORDER[d]])
		t.note("depth %d: host %s %s, client %s %s, resident %s" % [d, f["hostPlace"], f["host"], f["clientPlace"], f["client"], f["entity"]])

# ---------------------------------------------------------------------------------------------
# The residents in the run.

## A run on floor `depth` of the full deck, its resident awake, one player standing `gap` cells from it
## and watching it.
static func _floor_run(seed: String, depth: int) -> Run.RunState:
	var ids: Array[String] = ["w"]
	var s := HostRules.new(true, depth, Places.FULL).prepare(Run.create_run(seed, ids))
	s = s.copy()
	s.phase = &"away"
	var o := s.orderly.copy()
	o.mode = &"hunting"
	s.orderly = o
	return s

static func _watcher(s: Run.RunState, body: Move.Body) -> Run.PlayerInput:
	var o := s.orderly.body
	var yaw := Entity.yaw_toward(o.x - body.x, o.z - body.z)
	return Run.PlayerInput.make("w", body, 1.65, yaw, 0.0, 90.0, 70.0)

## The cell next to the resident's start that is walkable, nearest the landing.
static func _beside(plan: Floor.FloorPlan, at: Floor.Pos) -> Move.Body:
	var dist := Floor.distances_from(plan, plan.landing)
	var best: Floor.Pos = null
	for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var q := Floor.Pos.make(at.level, at.x + d.x, at.y + d.y)
		if Floor.in_bounds(plan, q.x, q.y) and Floor.is_walkable(plan, q.level, q.x, q.y):
			if best == null or dist[Floor.pos_index(plan, q)] < dist[Floor.pos_index(plan, best)]:
				best = q
	return Move.body_at_cell(plan, best if best != null else at)

func test_the_minder_wanders_and_never_takes_anyone(t: T) -> void:
	var n := 3 if t.quick else 12
	var moved_seen := 0
	var ticks := 0
	for i in n:
		var s := _floor_run("minder-%d" % i, 4)
		t.eq(s.plan.place, &"playroom", "depth 4 is the Playroom")
		t.eq(s.entity_id, "minder-4", "the Minder's entity id")
		# A player standing right beside where it starts, staring at it: a Stillness resident would freeze
		# and then reach for them; the Minder strolls off and takes nobody.
		var me := _beside(s.plan, s.plan.entity_start)
		var caught := 0
		var path := 0.0
		for _k in roundi(60.0 / STEP):
			var before := s.orderly.body
			var inp := _watcher(s, me)
			var inputs: Array[Run.PlayerInput] = [inp]
			var r := Run.step_run(s, inputs, STEP)
			for e in r.events:
				if e["type"] in ["caught", "windUp", "froze"]:
					caught += 1
			s = r.state
			ticks += 1
			var step := Vector2(s.orderly.body.x - before.x, s.orderly.body.z - before.z).length()
			path += step
			if step > 1e-6 and Entity.seen_by(s.plan, before, [Entity.PlayerView.make("w", me, 1.65, inp.yaw, 0.0, 90.0, 70.0, true, false)] as Array[Entity.PlayerView]) != null:
				moved_seen += 1
			t.check(step <= Places.WANDER_SPEED * STEP + 1e-6, "minder-%d: it moved %.3f m in a tick" % [i, step])
		t.eq(caught, 0, "minder-%d: it froze, reached or caught" % i)
		t.eq(s.players[0].status, &"ok", "minder-%d: the watcher is still ok" % i)
		t.check(path > 10.0, "minder-%d: it only walked %.1f m in a minute" % [i, path])
	t.check(moved_seen > 0, "it never moved while watched (it is not a Stillness resident)")
	t.note("%d Playrooms, %d ticks beside it: it moved in %d ticks while watched, never froze, reached or caught" % [n, ticks, moved_seen])

func test_the_temp_keeps_the_orderlys_stillness(t: T) -> void:
	var n := 2 if t.quick else 8
	var seen_ticks := 0
	for i in n:
		var s := _floor_run("temp-%d" % i, 3)
		t.eq(s.plan.place, &"annex", "depth 3 is the Annex")
		t.eq(s.entity_id, "temp-3", "the Temp's entity id")
		var me := _beside(s.plan, s.plan.entity_start)
		for _k in roundi(10.0 / STEP):
			var before := s.orderly
			var inputs: Array[Run.PlayerInput] = [_watcher(s, me)]
			var r := Run.step_run(s, inputs, STEP)
			s = r.state
			if s.orderly.seen:
				seen_ticks += 1
				t.check(s.orderly.body.x == before.body.x and s.orderly.body.z == before.body.z, "temp-%d: it moved in a tick it was seen" % i)
	t.check(seen_ticks > 0, "the Temp was never seen (vacuous)")
	t.note("%d Annexes: %d ticks seen, never moved while seen (the Orderly's rules until T16f)" % [n, seen_ticks])

# ---------------------------------------------------------------------------------------------
# The host never freezes the Minder: a client saying it sees it, with seen reports of the pose it drew,
# changes nothing on the Playroom (looking does nothing to a Hearing resident). On the Annex the same
# messages hold the Temp, as they hold the Orderly.

## The host and one player over the in-memory network (tests/prop_net.gd Rig, cut down), on floor
## `depth` of the full deck with the resident awake.
class HostRig:
	var net: Transport.MemoryNetwork
	var host: Host
	var me: Transport.Transport
	var now := 0.0
	var ct := 0.0
	var seq := 0
	var snaps := {}
	var latest: Variant = null
	var place_ack := 0
	var body := Move.Body.make(0.0, 0.0, 0, 0.0)
	var rules: HostRules

	func _init(seed: String, depth: int) -> void:
		rules = HostRules.new(true, depth, Places.FULL)
		net = Transport.MemoryNetwork.new("places-rig")
		var ht := net.connect_peer("host")
		me = net.connect_peer("p0")
		var roster: Array[String] = ["p0"]
		host = Host.new(ht, seed, roster, 0.0, Callable(self, "_prepare"), Callable(rules, "step"))
		me.send("host", Protocol.encode({"type": "join", "name": "p0", "ct": 0.0}))
		tick()

	func _prepare(s0: Run.RunState) -> Run.RunState:
		var s := rules.prepare(s0)
		s = s.copy()
		var o := s.orderly.copy()
		o.mode = &"hunting"
		s.orderly = o
		return s

	func input(seeing: bool, seen: Array) -> void:
		ct += Session.TICK
		seq += 1
		var lh: float = float(latest["ht"]) if latest != null else -1.0
		me.send("host", Protocol.encode({"type": "input", "seq": seq, "ct": ct, "body": body, "eye": 1.65, "yaw": 0.0, "pitch": PI / 2.0,
			"hFovDeg": 1.0, "vFovDeg": 1.0, "raised": false, "holdDoors": false, "gait": "walk", "seeing": seeing, "calls": 0, "pickUps": 0,
			"ackEvent": 0, "ackHt": lh, "renderTime": lh, "placeAck": place_ack, "seen": seen}))

	func tick() -> void:
		now += Session.TICK
		net.now = now
		host.update(now)
		for d: Dictionary in me.receive():
			var m: Variant = Protocol.decode(d["data"])
			if m == null or m["type"] != "snap":
				continue
			snaps[int(m["tick"])] = m
			latest = m
			if m["place"] != null and int(m["place"]["seq"]) > place_ack:
				place_ack = m["place"]["seq"]
				body = m["place"]["body"]

	## A seen report of the pose drawn half way from snapshot `a` to `a + 1`.
	func report(id: int, a: int) -> Dictionary:
		var sa: Dictionary = snaps[a]
		var sb: Dictionary = snaps[a + 1]
		return {"id": id, "depth": host.state.depth, "a": a, "b": a + 1, "alpha": 0.5, "pose": Pose.lerp_pose(sa["orderly"], sb["orderly"], 0.5)}

## 40 quiet ticks, then 60 ticks of "I see it" with a seen report of a pose 10 ticks old on every one.
## Returns [metres walked while seen, put-backs, whether the host marked it seen].
static func _stare(seed: String, depth: int) -> Array:
	var r := HostRig.new(seed, depth)
	for _k in 40:
		r.input(false, [])
		r.tick()
	var path := 0.0
	for i in 60:
		r.input(true, [r.report(i + 1, r.host.tick - 10)])
		var before := r.host.state.orderly.body
		r.tick()
		var after := r.host.state.orderly.body
		path += Vector2(after.x - before.x, after.z - before.z).length()
	return [path, r.host.stats.put_backs, r.host.state.orderly.last_seen_at != null]

func test_the_host_never_freezes_the_minder(t: T) -> void:
	var minder := _stare("host-minder", 4)
	t.eq(r_int(minder[1]), 0, "the host put the Minder back to a pose a client reported")
	t.check(not minder[2], "the host marked the Minder seen")
	t.check(float(minder[0]) > 2.0, "the Minder walked only %.2f m in 3 s of being stared at and reported" % float(minder[0]))
	var temp := _stare("host-temp", 3)
	t.check(temp[2], "the control: the host never held the Temp it was told was seen")
	t.note("3 s of seen reports and seeing=true: the Minder walked %.2f m, %d put-backs, never marked seen; the Temp was held (marked seen %s, %d put-backs, walked %.2f m)" % [minder[0], minder[1], str(temp[2]), temp[1], temp[0]])

static func r_int(v: Variant) -> int:
	return int(v)
