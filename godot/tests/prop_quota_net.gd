# The floor quota (North Star C9; T5q): the call button does nothing until the crew has recorded enough on
# this floor. Proved here:
#   1. The rule's numbers: floor_quota grows with depth and with the crew, the day loop's unit is floor 1's
#      quota per player, and the quota is off unless asked (and never with the resident off).
#   2. Over the network: three bots, each on its own lossy link to the host (tests/net_harness.gd's LOSSY:
#      up to 250 ms delay, 60 ms jitter, 5% loss, reordering and duplicates) and its own clock, play floor
#      1 and 2 through the real NetHost (net/host.gd with net/host_rules.gd, the resident on, the quota on)
#      and the real NetClient, sending only what a player sends (a body, a view, the instrument, the call):
#        - p0 stands at the call button and presses it every CALL_EVERY frames while the car is away; it
#          never looks out at the floor or raises its instrument;
#        - p2 walks out onto the floor; the Orderly is woken a few cells beyond it. p2 reads it (Reader:
#          its back to it while it comes, a look when it is close) until its tape holds P2_SHARE of the
#          quota, then stops looking: it is caught and its tape drops to the floor;
#        - p1 then goes out and reads the Orderly until its screen shows the quota met; the Orderly is
#          parked, everyone rides DOWN, and on floor 2 p2 leaves the game.
#      Proved: every press below the quota is a "callRefused" and the first press at it is the "called",
#      on the host and on every client alike (the same events, in the same order); "quotaMet" comes once
#      per floor; at that moment the quota is what the crew holds plus the tape on the floor, and what it
#      holds is under the quota; earned never fell while on the floor and is every reading closed there;
#      every client's quota block is the host's at that tick; floor 2 asks for more than floor 1, and less
#      once p2 has left the game.
#   3. Reading bots (pure rules, no network) on floor 1: how long a crew of 1 to 4 that reads well takes to
#      meet the quota (noted; the default run checks each crew's median is 60 to 240 s).
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Follow = preload("res://sim/follow.gd")
const Entity = preload("res://sim/entity.gd")
const Instr = preload("res://sim/instrument.gd")
const Places = preload("res://sim/places.gd")
const Day = preload("res://sim/day.gd")
const Rng = preload("res://sim/rng.gd")
const M = preload("res://sim/jsmath.gd")
const Session = preload("res://net/session.gd")
const Transport = preload("res://net/transport.gd")
const Host = preload("res://net/host.gd")
const Client = preload("res://net/client.gd")
const HostRules = preload("res://net/host_rules.gd")
const Harness = preload("res://tests/net_harness.gd")
const NetLib = preload("res://tests/net_lib.gd")
const DayNet = preload("res://tests/prop_day_net.gd")

## The session's clock step, and how often each bot draws a frame (and so sends an input).
const STEP := 0.025
const FRAME := 0.05
## Walking pace (the host refuses bodies faster than the walk), and backing off while watching.
const SPEED := 2.0
const BACK_SPEED := 1.5
const RADIUS := 0.3
## p0 presses the call button every this many frames (1.5 s) while the car is away.
const CALL_EVERY := 30
## Where p2 waits: this many cells' walk from the landing; the Orderly is woken this many cells beyond it.
const OUT_CELLS := 5
const BEYOND_CELLS := 4
## Those waiting at the lift look at the Orderly once it is this close (metres); readers keep their
## repositioning at least AVOID metres from the doors, so they do not lead it there.
const GUARD := 7.0
const AVOID := 12.0
## p2 stops looking once its tape holds this share of the quota.
const P2_SHARE := 0.5
## The quota's events, as every machine lists them.
const QUOTA_EVENTS: Array[String] = ["callRefused", "quotaMet", "called"]

## A player reading a Stillness resident, as a careful person does: walk to it, then turn your back so it
## moves (and records) while it comes, look at it when it is NEAR, back off while looking until BACK
## away, and turn your back again. Cornered, walk (still looking) to a spot further off. `careless`: never
## looks (it will be caught).
class Reader:
	const FAR := 7.0
	const NEAR := 3.0
	const BACK := 5.5
	var mode := "approach"
	var watched := 0.0
	var replan := 0.0
	var walk: Follow.PathWalk = null
	var careless := false
	## Somewhere a cornered reader does not retreat towards (within AVOID metres), or null.
	var avoid: Move.Body = null

	## One step: the new body, where it looks (yaw) and whether the instrument is up. `mover(body, dx, dz)`
	## moves a body with the walls.
	func step(plan: Floor.FloorPlan, b: Move.Body, o: Move.Body, dt: float, mover: Callable) -> Dictionary:
		var d := M.hypot2(o.x - b.x, o.z - b.z)
		var to_o := Entity.yaw_toward(o.x - b.x, o.z - b.z)
		var yaw := to_o + PI
		if o.level != b.level or d > FAR:
			mode = "approach"
		elif mode == "approach":
			mode = "record"
		if careless and mode != "approach":
			mode = "record"
		if mode == "record" and d <= NEAR and not careless:
			mode = "watch"
			watched = 0.0
		if mode == "watch" and watched >= 2.0 and d >= BACK:
			mode = "record"
		elif mode == "watch" and watched >= 4.0:
			mode = "move"
			walk = Follow.start_path_walk(Floor.find_path(plan, Move.cell_of(plan, b), Reader.away_cell(plan, b, o, avoid)))
		if mode == "move" and (walk == null or Follow.path_done(plan, walk, b)):
			mode = "record"
		var nb := b
		match mode:
			"approach":
				replan -= dt
				if walk == null or replan <= 0.0:
					walk = Follow.start_path_walk(Floor.find_path(plan, Move.cell_of(plan, b), Move.cell_of(plan, o)))
					replan = 1.0
				if not Follow.path_done(plan, walk, b):
					nb = Follow.step_path_walk(plan, walk, b, SPEED * dt, RADIUS)
					if M.hypot2(nb.x - b.x, nb.z - b.z) > 1e-6:
						yaw = Entity.yaw_toward(nb.x - b.x, nb.z - b.z)
			"move":
				nb = Follow.step_path_walk(plan, walk, b, SPEED * dt, RADIUS)
				yaw = to_o
			"record":
				walk = null
			"watch":
				walk = null
				watched += dt
				yaw = to_o
				if d < BACK:
					nb = mover.call(b, (b.x - o.x) / maxf(d, 1e-6) * BACK_SPEED * dt, (b.z - o.z) / maxf(d, 1e-6) * BACK_SPEED * dt)
		return {"body": nb, "yaw": yaw, "raised": true}

	## A walkable cell on the same level, at most 10 cells' walk away, at least 7 m from the resident and
	## AVOID from `avoid` (if any).
	static func away_cell(plan: Floor.FloorPlan, b: Move.Body, o: Move.Body, avoid: Move.Body = null) -> Floor.Pos:
		var from := Move.cell_of(plan, b)
		var dist := Floor.distances_from(plan, from)
		var best: Floor.Pos = from
		var best_score := -INF
		for i in dist.size():
			if dist[i] < 0 or dist[i] > 10:
				continue
			var p := Floor.pos_from_index(plan, i)
			if p.level != b.level:
				continue
			var away := M.hypot2((p.x + 0.5) * plan.cell_size - o.x, (p.y + 0.5) * plan.cell_size - o.z)
			if away < 7.0:
				continue
			if avoid != null and M.hypot2((p.x + 0.5) * plan.cell_size - avoid.x, (p.y + 0.5) * plan.cell_size - avoid.z) < AVOID:
				continue
			var score := -float(dist[i]) - absf(away - 8.0)
			if score > best_score:
				best_score = score
				best = p
		return best

class Bot:
	var id: String
	var index: int
	var client: Client
	var offset: float
	var next_frame: float
	var body: Move.Body = null
	var walk: Follow.PathWalk = null
	var reader := Reader.new()
	var frames := 0
	var gone := false
	## The Orderly as this machine last drew it (a body), or null.
	var drawn: Move.Body = null

class Sess:
	var net: Transport.MemoryNetwork
	var host: Host
	var rules: HostRules
	var bots: Array[Bot] = []
	var g := 0.0
	var seed: String
	var ids: Array[String] = ["p0", "p1", "p2"]
	## "wait" (p2 walks out), "hunt" (p2 reads it), "second" (p1 reads it), "parked" (the quota met), "deep"
	## (floor 2).
	var stage := "wait"
	## Where p2 waits, and where the Orderly is woken (floor 1).
	var out_cell: Floor.Pos
	var wake_cell: Floor.Pos
	## The host's earned on floor 1, tick by tick; ticks it fell; the readings closed on floor 1.
	var earned_trace: Array[float] = []
	var fell := 0
	var readings_d1 := 0.0
	## At the quotaMet tick: what the crew held, what lay on the floor, what was earned.
	var held_at_met := -1.0
	var floor_at_met := -1.0
	var earned_at_met := -1.0
	var earned_at_call := -1
	var dropped: Array[String] = []
	var p2_left_tick := -1
	## Client snapshots compared with the host's quota block, and the disagreements.
	var compared := 0
	var mismatches: Array[String] = []
	## Each bot's quota block on floor 2 with p2 still in, and after p2 left.
	var deep_needed := {}
	var deep_after := {}

	func _init(seed_: String) -> void:
		seed = seed_
		var n := Harness.lossy()
		var rng := Rng.make_rng("%s:session" % seed)
		net = Transport.MemoryNetwork.new("%s:net" % seed)
		var ht := net.connect_peer("host")
		rules = HostRules.new(true, 1, [], false, true)
		var r := rules
		var prepare := func(s0: Run.RunState) -> Run.RunState:
			# The crew on the landing, the car away, the Orderly parked until the test wakes it.
			var s := NetLib.hunt_setup(r.prepare(s0))
			s.orderly = HostRules.parked_orderly(s)
			return s
		host = Host.new(ht, seed, ids, 0.0, prepare, Callable(rules, "step"))
		var plan := host.state.plan
		# Where p2 waits: the cell on the landing's level, OUT_CELLS to 2 x OUT_CELLS cells' walk away, that
		# is furthest from the doors as the crow flies and has a cell BEYOND_CELLS further on.
		var door := Run.car_geometry(plan)
		var from_landing := Floor.distances_from(plan, plan.landing)
		var best := -1.0
		for i in from_landing.size():
			if from_landing[i] < OUT_CELLS or from_landing[i] > 2 * OUT_CELLS:
				continue
			var p := Floor.pos_from_index(plan, i)
			var far := M.hypot2((p.x + 0.5) * plan.cell_size - door.door_x, (p.y + 0.5) * plan.cell_size - door.door_z)
			if p.level != plan.landing.level or far <= best:
				continue
			var from_out := Floor.distances_from(plan, p)
			for j in from_out.size():
				var q := Floor.pos_from_index(plan, j)
				if from_out[j] == BEYOND_CELLS and from_landing[j] == from_landing[i] + BEYOND_CELLS and q.level == p.level:
					out_cell = p
					wake_cell = q
					best = far
					break
		for i in ids.size():
			var id := ids[i]
			var tr := net.connect_peer(id)
			for pair: Array in [["host", id], [id, "host"]]:
				var delay := n.delay_min + rng.next() * (n.delay_max - n.delay_min)
				net.set_link(pair[0], pair[1], Transport.LinkConfig.make(delay, n.jitter, n.loss, n.reorder, n.reorder_delay, n.duplicate))
			var b := Bot.new()
			b.id = id
			b.index = i
			b.offset = (rng.next() - 0.5) * 200.0
			b.next_frame = rng.next() * FRAME
			b.client = Client.new(tr, "host", id, g + b.offset)
			bots.append(b)

# ---------------------------------------------------------------------------------------------
# The rule's numbers.

func test_the_quota_grows_with_depth_and_crew(t: T) -> void:
	for n in range(1, 7):
		for d in range(1, 13):
			var q := Run.floor_quota(d, n)
			t.check(q > 0 and q % Run.QUOTA_ROUND == 0, "floor %d crew %d: %d is a whole number of %d" % [d, n, q, Run.QUOTA_ROUND])
			t.check(Run.floor_quota(d + 1, n) > q, "floor %d crew %d: the next floor asks for more (%d, %d)" % [d, n, q, Run.floor_quota(d + 1, n)])
			t.check(Run.floor_quota(d, n + 1) > q, "floor %d crew %d: a bigger crew is asked for more (%d, %d)" % [d, n, q, Run.floor_quota(d, n + 1)])
		t.eq(Run.floor_quota(1, n), Run.QUOTA_PER_PLAYER * n, "floor 1 for %d: the per-player quota each" % n)
		# The day loop's unit is floor 1's quota per player: the day quota is counted in floor 1 quotas.
		t.eq(Day.first_floor_quota(Run.DAY_FLOOR_QUOTA, n), Run.floor_quota(1, n), "crew %d: the day's floor quota is floor 1's" % n)
		t.eq(Day.quota_for(0, n, Run.DAY_FLOOR_QUOTA), (3 * Run.floor_quota(1, n) + 1) / 2, "crew %d: day 1 owes one and a half of floor 1's quota" % n)
	t.eq(Run.floor_quota(0, 3), 0, "nothing is owed at home")
	var ids: Array[String] = ["a", "b", "c"]
	t.check(not Run.create_run("q", ids).quota, "a run made as before has no quota")
	t.check(not HostRules.new(true, 1).prepare(Run.create_run("q", ids)).quota, "host rules made as before add no quota")
	t.check(not HostRules.new(false, 1, [], true, true).prepare(Run.create_run("q", ids)).quota, "with the resident off the quota stays off")
	var on := HostRules.new(true, 3, [], true, true).prepare(Run.create_run("q", ids))
	t.check(on.quota and on.days, "host rules asked for the quota (and days) turn it on")
	t.eq(on.floor_needed, Run.floor_quota(3, 3), "prepared at depth 3: floor 3's quota for three")
	t.check(on.floor_earned == 0.0 and not on.quota_met, "nothing recorded yet")
	var by_crew: Array = []
	for n in range(1, 7):
		by_crew.append(Run.floor_quota(1, n))
	var by_depth: Array = []
	for d in range(1, 9):
		by_depth.append(Run.floor_quota(d, 3))
	t.note("floor_quota(depth, crew) = %d x crew x %.2f^(depth-1), to the nearest %d: floor 1 by crew %s; a crew of 3 by depth %s" % [
		Run.QUOTA_PER_PLAYER, Run.QUOTA_DEPTH_STEP, Run.QUOTA_ROUND, str(by_crew), str(by_depth)])

# ---------------------------------------------------------------------------------------------
# Over the network.

## The tape total of player `id` as a snapshot shows it (closed readings only), or 0.
static func _tape_total(latest: Dictionary, id: String) -> float:
	for m: Dictionary in latest["crew"]:
		if m["id"] == id:
			return float(m["tape"]["total"])
	return 0.0

func _bot_frame(s: Sess, b: Bot) -> void:
	var c := b.client
	b.frames += 1
	var local := s.g + b.offset
	var lf := Client.LocalFrame.new()
	lf.body = b.body if b.body != null else Move.Body.make(0.0, 0.0, 0, 0.0)
	if c.seed != null and c.latest != null and b.body != null:
		var latest: Dictionary = c.latest
		var plan := Session.plan_for(str(c.seed), c.local_depth)
		var car := Session.car_for(plan)
		var here := int(latest["depth"]) == c.local_depth
		var phase := str(latest["phase"]) if here else ""
		var body := b.body
		lf.yaw = Entity.yaw_toward(car.in_x, car.in_z)  # facing the doors, away from the floor
		var mover := func(from: Move.Body, dx: float, dz: float) -> Move.Body:
			return Session.move_local(plan, phase, from, dx, dz, RADIUS)
		var q: Variant = c.quota()
		var met: bool = q != null and int(q["earned"]) >= int(q["needed"]) and int(q["needed"]) > 0
		var out_reading := c.local_depth == 1 and phase != "boarding" and phase != "riding" and b.drawn != null and (
			(b.id == "p2" and s.stage != "wait") or (b.id == "p1" and s.stage == "second" and not met))
		if out_reading:
			# Reading: p2 stops looking once its tape holds its share (and is caught).
			b.reader.careless = b.id == "p2" and _tape_total(latest, "p2") >= P2_SHARE * Run.floor_quota(1, 3)
			b.reader.avoid = Run.car_body(car, -0.8, 0.0)
			var r := b.reader.step(plan, body, b.drawn, FRAME, mover)
			body = r["body"]
			lf.yaw = r["yaw"]
			lf.raised = r["raised"]
		elif b.id == "p2" and c.local_depth == 1 and phase != "boarding" and phase != "riding":
			# Out to where it waits for the Orderly.
			if b.walk == null:
				b.walk = Follow.start_path_walk(Floor.find_path(plan, Move.cell_of(plan, body), s.out_cell))
			if not Follow.path_done(plan, b.walk, body):
				body = Follow.step_path_walk(plan, b.walk, body, SPEED * FRAME, RADIUS)
		else:
			var to: Move.Body = null
			match phase:
				"unloading", "away", "coming":
					to = Run.car_body(car, -0.8, -0.5 + 0.5 * b.index)
				"boarding":
					to = Run.car_body(car, 1.0 + 0.9 * b.index, 1.0)
			# Waiting at the lift: watch the Orderly if it comes close, as anyone would.
			var o := b.drawn
			if o != null and o.level == body.level and M.hypot2(o.x - body.x, o.z - body.z) <= GUARD:
				lf.yaw = Entity.yaw_toward(o.x - body.x, o.z - body.z)
			if to != null:
				if M.hypot2(body.x - car.door_x, body.z - car.door_z) > 3.0:
					# Back from the floor: along the plan's path to the landing first.
					if b.walk == null:
						b.walk = Follow.start_path_walk(Floor.find_path(plan, Move.cell_of(plan, body), plan.landing))
					body = Follow.step_path_walk(plan, b.walk, body, SPEED * FRAME, RADIUS)
				else:
					b.walk = null
					body = DayNet.walk_toward(plan, phase, car, body, to)
			lf.call = b.id == "p0" and phase == "away" and b.frames % CALL_EVERY == 0 \
				and M.hypot2(body.x - car.door_x, body.z - car.door_z) <= Run.CALL_REACH - 0.3
		b.body = body
		lf.body = body
	var f := c.frame(local, lf)
	if f.orderly != null:
		var o: Dictionary = f.orderly
		b.drawn = Move.Body.make(float(o["x"]), float(o["z"]), int(o["level"]), float(o["y"]))
	if f.placed != null:
		b.body = f.placed
		b.walk = null
		b.reader = Reader.new()
	_check_snapshot(s, b)

## The client's quota block against the host's at the snapshot's tick.
func _check_snapshot(s: Sess, b: Bot) -> void:
	var c := b.client
	if c.latest == null:
		return
	var latest: Dictionary = c.latest
	var q: Variant = c.quota()
	if q == null:
		s.mismatches.append("%s: no quota block at tick %d" % [b.id, int(latest["tick"])])
		return
	var hs := s.host.state_at(int(latest["tick"]))
	if hs == null:
		return
	s.compared += 1
	var want := Host.quota_block(hs)
	if int(q["earned"]) != int(want["earned"]) or int(q["needed"]) != int(want["needed"]):
		s.mismatches.append("%s at tick %d: quota %s, the host's %s" % [b.id, int(latest["tick"]), str(q), str(want)])
	if int(latest["depth"]) == 2 and c.local_depth == 2:
		if s.p2_left_tick < 0:
			s.deep_needed[b.id] = int(q["needed"])
		elif int(latest["tick"]) > s.p2_left_tick + 2:
			s.deep_after[b.id] = int(q["needed"])

## The host side of a tick: the stages, and what the test keeps of the host's run.
func _on_tick(s: Sess, from_event: int) -> void:
	var st := s.host.state
	var new_events: Array[Dictionary] = []
	for i in range(from_event, s.host.event_log.size()):
		new_events.append(s.host.event_log[i].e)
	if st.depth == 1:
		if not s.earned_trace.is_empty() and st.floor_earned < s.earned_trace[-1] - 1e-9:
			s.fell += 1
		s.earned_trace.append(st.floor_earned)
	for e in new_events:
		match str(e["type"]):
			"readingClosed":
				if st.depth == 1:
					s.readings_d1 += float(e["value"])
			"tapeDropped":
				s.dropped.append(str(e["tapeId"]))
			"quotaMet":
				if int(e["depth"]) == 1:
					var held := 0.0
					for m in st.crew.members:
						held += m.tape.total
						for tp in m.carrying:
							held += tp.total
					var lying := 0.0
					for f in st.crew.floor:
						lying += f.tape.total
					s.held_at_met = held
					s.floor_at_met = lying
					s.earned_at_met = st.floor_earned
			"called":
				s.earned_at_call = floori(st.floor_earned)
	match s.stage:
		"wait":
			# p2 is where it waits and p0 has been refused a few times: wake the Orderly beyond p2.
			var at := Move.body_at_cell(st.plan, s.out_cell)
			var refused := 0
			for le in s.host.event_log:
				if le.e["type"] == "callRefused":
					refused += 1
			for p in st.players:
				if p.id == "p2" and refused >= 2 and M.hypot2(p.body.x - at.x, p.body.z - at.z) < 0.5:
					var o := Places.create_resident(st.plan)
					o.body = Move.body_at_cell(st.plan, s.wake_cell)
					o.mode = &"hunting"
					o.replan_in = 0.0
					s.host.replace_orderly(o)
					s.stage = "hunt"
		"hunt":
			for e in new_events:
				if e["type"] == "caught" and e["playerId"] == "p2":
					s.stage = "second"
		"second":
			for e in new_events:
				if e["type"] == "quotaMet":
					# Parked where it stands: the crew can wait for the car in peace.
					var o := s.host.state.orderly.copy()
					o.mode = &"dormant"
					o.dormant_left = INF
					o.wind_up_target = null
					o.wind_up_left = 0.0
					s.host.replace_orderly(o)
					s.stage = "parked"
		"parked":
			if st.depth == 2:
				s.stage = "deep"
				s.host.replace_orderly(HostRules.parked_orderly(st))
		"deep":
			if s.p2_left_tick < 0 and st.phase == &"away":
				var all_there := true
				for b in s.bots:
					all_there = all_there and b.client.local_depth == 2 and s.deep_needed.has(b.id)
				if all_there:
					for b in s.bots:
						if b.id == "p2":
							b.client.leave()
							b.gone = true
					s.p2_left_tick = s.host.tick

## Runs the session until floor 2 has refused a call from the smaller crew on both remaining clients, or
## `limit` seconds.
func _play(s: Sess, limit: float) -> void:
	var last_tick := -1
	var seen := 0
	while s.g < limit:
		s.g += STEP
		s.net.now = s.g
		s.host.update(s.g)
		if s.host.tick != last_tick:
			last_tick = s.host.tick
			_on_tick(s, seen)
			seen = s.host.event_log.size()
		for b in s.bots:
			if not b.gone:
				b.client.receive(s.g + b.offset)
		for b in s.bots:
			while not b.gone and b.next_frame <= s.g + 1e-9:
				b.next_frame += FRAME
				_bot_frame(s, b)
		if s.p2_left_tick >= 0 and s.deep_after.size() == 2 and _deep_refusals(s.bots[0].client.events) > 0 and _deep_refusals(s.bots[1].client.events) > 0:
			return

## Floor 2 refusals with the smaller crew's quota, in a list of events.
static func _deep_refusals(events: Array) -> int:
	var n := 0
	for e: Dictionary in events:
		if e.get("type") == "callRefused" and int(e["needed"]) == Run.floor_quota(2, 2):
			n += 1
	return n

## The quota's events of a list, as every machine lists them.
static func _quota_list(events: Array) -> Array:
	var out: Array = []
	for e: Dictionary in events:
		var ty := str(e.get("type"))
		if not QUOTA_EVENTS.has(ty):
			continue
		match ty:
			"called":
				out.append([ty, str(e["playerId"]), float(e["t"])])
			"quotaMet":
				out.append([ty, int(e["depth"]), int(e["earned"]), int(e["needed"]), str(e["top"]), float(e["t"])])
			_:
				out.append([ty, str(e["playerId"]), int(e["earned"]), int(e["needed"]), float(e["t"])])
	return out

func test_three_bots_on_a_lossy_link_meet_the_quota(t: T) -> void:
	var s := Sess.new("quota-net")
	if not t.check(s.out_cell != null, "no spot %d cells out with a cell %d beyond it" % [OUT_CELLS, BEYOND_CELLS]):
		return
	var t0 := Time.get_ticks_msec()
	_play(s, 900.0)
	var secs := (Time.get_ticks_msec() - t0) / 1000.0
	var host_events: Array = []
	for le in s.host.event_log:
		host_events.append(le.e)
	var host_list := _quota_list(host_events)
	var need1 := Run.floor_quota(1, 3)
	t.check(s.stage == "deep", "the session got only as far as the stage %s" % s.stage)
	# The host: every press below the quota refused, the first at it taken.
	var refused1 := 0
	var met: Array = []
	var called: Array = []
	var after_met := false
	var depth := 1
	for le in s.host.event_log:
		var e: Dictionary = le.e
		match str(e["type"]):
			"rodeDown":
				depth = int(e["depth"])
				after_met = false
			"callRefused":
				t.check(int(e["earned"]) < int(e["needed"]), "a call refused at %d of %d" % [int(e["earned"]), int(e["needed"])])
				t.check(not after_met, "a call refused on floor %d after the quota was met" % depth)
				if depth == 1:
					refused1 += 1
					t.eq(int(e["needed"]), need1, "floor 1's quota for three")
			"quotaMet":
				met.append([depth, le.tick, str(e["top"])])
				after_met = true
				t.check(int(e["earned"]) >= int(e["needed"]), "met at %d of %d" % [int(e["earned"]), int(e["needed"])])
			"called":
				called.append([depth, le.tick])
				t.check(after_met, "the car was called on floor %d below the quota" % depth)
	t.check(refused1 >= 2, "presses refused on floor 1: %d" % refused1)
	t.check(met.size() == 1, "quotaMet on the host once, floor 1 only (floor 2 is never met): %s" % str(met))
	if not t.check(met.size() > 0 and int(met[0][0]) == 1, "quotaMet on floor 1: %s" % str(met)):
		return
	t.check(called.size() == 1, "calls taken, floor 1 only: %s" % str(called))
	if not t.check(called.size() > 0 and int(called[0][0]) == 1, "the car called on floor 1: %s" % str(called)):
		return
	t.check(s.earned_at_call >= need1, "the call taken at %d of %d" % [s.earned_at_call, need1])
	# The press taken is the first after the quota was met: none was refused in between.
	var refused_after_met := 0
	for le in s.host.event_log:
		if le.e["type"] == "callRefused" and le.tick >= int(met[0][1]) and le.tick <= int(called[0][1]):
			refused_after_met += 1
	t.eq(refused_after_met, 0, "presses refused between the quota met and the call taken")
	# The dropped tape: met with what the crew held plus what lay on the floor, what it held under the quota.
	t.check(not s.dropped.is_empty(), "p2's tape never dropped")
	t.check(s.floor_at_met > 0.0, "nothing lay on the floor when the quota was met")
	t.check(absf(s.earned_at_met - s.held_at_met - s.floor_at_met) < 1e-6,
		"earned at the quota %.4f is what was held %.4f plus what lay on the floor %.4f" % [s.earned_at_met, s.held_at_met, s.floor_at_met])
	t.check(s.held_at_met < need1, "the quota was met with %.2f held: the tape on the floor was needed (quota %d)" % [s.held_at_met, need1])
	t.eq(s.fell, 0, "ticks where floor 1's earned fell")
	var top: float = s.earned_trace.max() if s.earned_trace.size() > 0 else -1.0
	t.check(absf(top - s.readings_d1) < 1e-6, "floor 1's earned %.4f is every reading closed there %.4f" % [top, s.readings_d1])
	# Floor 2: more for the same crew, less once p2 has left.
	var need2 := Run.floor_quota(2, 3)
	t.check(need2 > need1, "floor 2 asks for more than floor 1")
	for b in s.bots:
		t.eq(int(s.deep_needed.get(b.id, -1)), need2, "%s on floor 2 with three: floor 2's quota for three" % b.id)
		if b.id != "p2":
			t.eq(int(s.deep_after.get(b.id, -1)), Run.floor_quota(2, 2), "%s on floor 2 after p2 left: floor 2's quota for two" % b.id)
	# Every client: the same quota events in the same order as the host (p2 up to where it left).
	for b in s.bots:
		var got := _quota_list(b.client.events)
		var want := host_list.slice(0, got.size()) if b.id == "p2" else host_list
		t.eq(got, want, "%s's quota events" % b.id)
		var n_met := 0
		for x: Array in got:
			if x[0] == "quotaMet":
				n_met += 1
		t.eq(n_met, 1, "%s heard quotaMet once" % b.id)
	for m: String in s.mismatches.slice(0, 8):
		t.check(false, m)
	t.eq(s.mismatches.size(), 0, "quota blocks that differ from the host's")
	t.check(s.compared > 1000, "snapshots compared: %d" % s.compared)
	var lost := 0
	for k: String in s.net.stats:
		lost += (s.net.stats[k] as Transport.LinkStats).lost
	t.note("%.0f s of play in %.1f s: floor 1 asks %d of three; %d presses refused there, then met at %.1f s (%.0f recorded: %.0f held, %.0f on the floor; most by %s) and called at %.1f s; floor 2 asks %d of three, %d of two; %d snapshots compared; %d messages lost" % [
		s.g, secs, need1, refused1, int(met[0][1]) * Session.TICK, s.earned_at_met, s.held_at_met, s.floor_at_met, met[0][2], int(called[0][1]) * Session.TICK,
		need2, Run.floor_quota(2, 2), s.compared, lost])

# ---------------------------------------------------------------------------------------------
# How long reading takes (pure rules).

## Seconds a crew of `n` reading bots takes to meet floor `depth`'s quota on `seed` (INF if not in `limit`).
static func _time_to_quota(seed: String, n: int, depth: int, limit: float) -> float:
	var ids: Array[String] = []
	for i in n:
		ids.append("r%d" % i)
	var rules := HostRules.new(true, depth, [], false, true)
	var s := NetLib.hunt_setup(rules.prepare(Run.create_run(seed, ids)))
	var readers: Array[Reader] = []
	for i in n:
		readers.append(Reader.new())
	var dt := Session.TICK
	var tt := 0.0
	while tt < limit:
		var inputs: Array[Run.PlayerInput] = []
		for i in n:
			var p := s.players[i]
			if p.status != &"ok":
				continue
			var st := s
			var mover := func(from: Move.Body, dx: float, dz: float) -> Move.Body:
				return Run.move_in_run(st, from, dx, dz, RADIUS)
			var r := readers[i].step(s.plan, p.body, s.orderly.body, dt, mover)
			var inp := Run.PlayerInput.make(p.id, r["body"], 1.65, r["yaw"], 0.0, 90.0, 70.0)
			inp.raised = r["raised"]
			inputs.append(inp)
		var step := rules.step(s, inputs, dt)
		s = step.state
		tt += dt
		for e in step.events:
			if e["type"] == "quotaMet":
				return tt
		if s.phase == &"ended":
			break
	return INF

func test_reading_bots_meet_floor_1_in_about_two_minutes(t: T) -> void:
	var seeds := 1 if t.quick else 3
	var parts: Array[String] = []
	for n in range(1, 5):
		var times: Array[float] = []
		for k in seeds:
			times.append(_time_to_quota("quota-read-%d-%d" % [k, n], n, 1, 360.0))
		times.sort()
		var med := times[times.size() / 2]
		var shown := PackedStringArray()
		for x in times:
			shown.append("never" if is_inf(x) else "%d:%02d" % [int(x) / 60, int(x) % 60])
		parts.append("crew %d (%d): %s" % [n, Run.floor_quota(1, n), ", ".join(shown)])
		if not t.quick:
			t.check(med >= 60.0 and med <= 240.0, "crew %d: median %.0f s to meet floor 1's quota (want 60 to 240)" % [n, med])
	t.note("reading bots from a hunting Orderly to the quota on floor 1: " + "; ".join(parts))
