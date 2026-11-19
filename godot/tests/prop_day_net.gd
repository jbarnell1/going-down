# The day loop over the network (loop/NIGHT-PLAN.md A2, docs/floors/prison.md P7): three bots, each on
# its own lossy link to the host (tests/net_harness.gd's LOSSY: up to 250 ms delay, 60 ms jitter, 5%
# loss, reordering and duplicates), each with its own clock, play two whole days through the real NetHost
# (net/host.gd with net/host_rules.gd, days on, the resident parked) and the real NetClient: day 1 rides
# DOWN from floor 1 and banks on floor 2, everyone walks to their bunk and holds F, day 2 banks on floor
# 1, bed again, and day 3 opens. Proved:
#   - at every stop (each floor, the prison, each morning) every client, once it is there, agrees with
#     the host on the day index and number, the quota, the streak and misses, the settled day's banked
#     total, and the plan (same hash, and the same as Places.generate from the day's seed:
#     "<seed>:day<n>");
#   - every client gets each day's "dayEnded" once, with the host's banked total and shares;
#   - every client's snapshot shows all three in bed before the lights go out;
#   - no tape is banked twice, every banked tape was held by the crew at the bell, and the tape left
#     lying on each floor (a fixture) is never banked.
# Tapes get their readings by fixture (host.act), so the totals are not vacuous with the resident parked.
# The same again with the day quota's lock (FD2, sim/run.gd day_lock; the fixtures record by hand): every
# floor's vote is BANK, floor 1's is refused and the car rides down, floor 2's banks; at every bell every
# client's day block agrees with the host's on earned, quota and locked, and every client gets the host's
# "bankRefused" and "dayMet" events.
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Follow = preload("res://sim/follow.gd")
const Places = preload("res://sim/places.gd")
const Day = preload("res://sim/day.gd")
const Rng = preload("res://sim/rng.gd")
const M = preload("res://sim/jsmath.gd")
const Session = preload("res://net/session.gd")
const Protocol = preload("res://net/protocol.gd")
const Transport = preload("res://net/transport.gd")
const Host = preload("res://net/host.gd")
const Client = preload("res://net/client.gd")
const HostRules = preload("res://net/host_rules.gd")
const Harness = preload("res://tests/net_harness.gd")
const DayRigLib = preload("res://tests/day_rig.gd")
const DayView = preload("res://client/day_view.gd")

## The session's clock step, and how often each bot draws a frame (and so sends an input).
const STEP := 0.025
const FRAME := 0.05
## Walking pace (the host refuses bodies faster than the walk).
const SPEED := 2.0
const RADIUS := 0.3
## The days played: the session ends when day DAYS + 1 opens.
const DAYS := 2

class Bot:
	var id: String
	var index: int
	var client: Client
	var offset: float
	var next_frame: float
	var body: Move.Body = null
	var walk: Follow.PathWalk = null
	var frames := 0
	## Stops this bot has checked (key -> true), and the nights it saw everyone in bed in a snapshot.
	var checked := {}
	var saw_all_in := {}
	## The day lock: the host bells (by tick) this bot has compared its day block at.
	var bells_checked := {}
	## FD3: this bot's screen (client/day_view.gd), fed every frame like the game's; the frames compared
	## with the host's own block at the same tick, and the client events it has passed on.
	var view := DayView.new()
	var view_frames := 0
	var view_locked := 0
	var events_seen := 0

class Stop:
	var key: String
	var tick: int
	var index: int
	var day: int
	var depth: int
	var seed: String
	var hash: String
	var place: String

class Sess:
	var net: Transport.MemoryNetwork
	var host: Host
	var rules: HostRules
	var bots: Array[Bot] = []
	var g := 0.0
	var seed: String
	var stops: Array[Stop] = []
	var stop_keys := {}
	## Fixtures given at each bank stop (day/depth key -> true), the floor fixtures' tape ids.
	var fixed := {}
	var floor_fixtures := {}
	## Per "banked" event (by its seq): [tapes held by the crew, tapes on the floor] the tick before.
	var at_bell := {}
	var mismatches: Array[String] = []
	var ids: Array[String] = ["p0", "p1", "p2"]
	## The day quota's lock (FD2): the whole crew votes BANK on every floor; the host's ticks of each "bell".
	var lock := false
	var bells: Array[int] = []
	## Ticks whose stored state a fixture rewrote after their snapshot went out (host.act): not compared.
	var acted := {}

	func _init(seed_: String, lock_: bool = false) -> void:
		seed = seed_
		lock = lock_
		var n := Harness.lossy()
		var rng := Rng.make_rng("%s:session" % seed)
		net = Transport.MemoryNetwork.new("%s:net" % seed)
		var ht := net.connect_peer("host")
		rules = HostRules.new(false, 1, [], true)
		var prep := Callable(rules, "prepare")
		if lock:
			# With the resident parked the rules keep the lock off (nothing could be recorded); the fixtures
			# below record by hand, so it is turned on here.
			var r := rules
			prep = func(s0: Run.RunState) -> Run.RunState: return Run.with_day_lock(r.prepare(s0))
		host = Host.new(ht, seed, ids, 0.0, prep, Callable(rules, "step"))
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

## The day index of a snapshot (1 without a day block).
static func day_of(w: Dictionary) -> int:
	var d: Variant = w.get("day")
	return int(d["index"]) if d != null else 1

## Where a bot heads between two points in and out of the car: through the middle of the doorway.
static func car_route(car: Run.CarGeometry, from: Move.Body, to: Move.Body) -> Array[Move.Body]:
	var a := Run.in_car(car, from)
	var b := Run.in_car(car, to)
	var out: Array[Move.Body] = []
	if a and not b:
		out = [Run.car_body(car, 0.6, 0.0), Run.car_body(car, -0.6, 0.0)]
	elif b and not a and Run.car_local(car, from.x, from.z)[0] < -0.55:
		out = [Run.car_body(car, -0.6, 0.0), Run.car_body(car, 0.6, 0.0)]
	out.append(to)
	while out.size() > 1 and M.hypot2(out[0].x - from.x, out[0].z - from.z) < 0.05:
		out.pop_front()
	return out

## One step of at most SPEED * FRAME towards `to` (through the doorway when it must), with the rules' walls.
static func walk_toward(plan: Floor.FloorPlan, phase: String, car: Run.CarGeometry, body: Move.Body, to: Move.Body) -> Move.Body:
	var route := car_route(car, body, to)
	var w := route[0]
	var d := M.hypot2(w.x - body.x, w.z - body.z)
	if d < 1e-6:
		return body
	var stp := minf(SPEED * FRAME, d)
	return Session.move_local(plan, phase, body, (w.x - body.x) / d * stp, (w.z - body.z) / d * stp, RADIUS)

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
		var here := int(latest["depth"]) == c.local_depth and day_of(latest) == c.day_index
		var phase := str(latest["phase"]) if here else ""
		var body := b.body
		if c.local_depth > 0:
			var to: Move.Body = null
			match phase:
				"unloading", "away", "coming":
					to = Run.car_body(car, -1.0, -0.5 + 0.5 * b.index)
				"boarding":
					var down := c.day_index == 1 and c.local_depth == 1 and not s.lock
					to = Run.car_body(car, 1.0 + 0.9 * b.index, 1.0 if down else -1.0)
			if to != null:
				body = walk_toward(plan, phase, car, body, to)
			lf.call = phase == "away" and b.index == 0 and b.frames % 20 == 0 and M.hypot2(body.x - car.door_x, body.z - car.door_z) <= Run.CALL_REACH - 0.3
		elif phase == "unloading" or phase == "night":
			# Home: out of the car to the landing, then along the rules' own path to this bot's bunk, F held there.
			var crew: Array[String] = []
			for p: Dictionary in latest["players"]:
				crew.append(str(p["id"]))
			var bunk := Day.bunk_of(crew, b.id)
			if Run.car_local(car, body.x, body.z)[0] > -0.9:
				body = walk_toward(plan, phase, car, body, Run.car_body(car, -1.0, 0.0))
			else:
				if b.walk == null:
					b.walk = Follow.start_path_walk(Floor.find_path(plan, Move.cell_of(plan, body), Floor.Pos.make(0, bunk.x, bunk.y)))
				if not Follow.path_done(plan, b.walk, body):
					body = Follow.step_path_walk(plan, b.walk, body, SPEED * FRAME, RADIUS)
				else:
					lf.use = true
		b.body = body
		lf.body = body
	var f := c.frame(local, lf)
	if f.placed != null:
		b.body = f.placed
		b.walk = null
	_check_stops(s, b)
	if s.lock:
		_check_view(s, b)

## FD3: what this client's screen shows (the HUD's corner line, the lift monitor's rows, the BANK paint)
## equals what the host's own day block at the snapshot's tick makes it show, on every frame.
func _check_view(s: Sess, b: Bot) -> void:
	var c := b.client
	if c.latest == null:
		return
	var latest: Dictionary = c.latest
	var fresh: Array = c.events.slice(b.events_seen)
	b.events_seen = c.events.size()
	# As client/play_link.gd makes the game's frame: riding up once the day is settled.
	var dv: Variant = latest.get("day")
	var up: bool = str(latest["phase"]) == "riding" and dv is Dictionary and (dv as Dictionary)["result"] != null
	var frame := {"day": dv, "depth": latest["depth"], "phase": latest["phase"], "goingUp": up, "events": fresh}
	b.view.update(frame)
	if s.acted.has(int(latest["tick"])):
		return
	var hs := s.host.state_at(int(latest["tick"]))
	if hs == null:
		return
	# The design's words from the host's own block at that tick (not the view's code): the corner line, the
	# monitor's rows (the third while boarding), LOCKED; nothing at home but CLOSED UNTIL MORNING for the night.
	var hb := Host.day_block(hs)
	var on_floor := int(latest["depth"]) >= 1 or up
	var w_hud := ""
	var w_rows: Array = []
	var w_locked := false
	if on_floor:
		w_locked = int(hb["earned"]) < int(hb["quota"])
		w_hud = "DAY EARNED %d/%d%s" % [int(hb["earned"]), int(hb["quota"]), "" if w_locked else " MET"]
		w_rows = ["DAY %d. EARNED %d OF %d." % [int(hb["day"]), int(hb["earned"]), int(hb["quota"])],
			("BANK LOCKED. %d TO GO." % (int(hb["quota"]) - int(hb["earned"]))) if w_locked else ("BANK OPEN. ABOARD %d. EACH GETS %d." % [int(hb["aboard"]), int(hb["each"])])]
		if str(latest["phase"]) == "boarding":
			w_rows.append(str(hb["stakes"]))
	var w_closed := "CLOSED UNTIL MORNING" if not on_floor and str(latest["phase"]) == "night" else ""
	b.view_frames += 1
	if w_locked:
		b.view_locked += 1
	var v := b.view
	if v.hud_line != w_hud or Array(v.rows) != w_rows or v.locked != w_locked or v.closed != w_closed:
		s.mismatches.append("%s at tick %d: the screen %s, the host's block says %s / %s / locked %s / %s" % [b.id, int(latest["tick"]), str(v.describe()), w_hud, str(w_rows), w_locked, w_closed])

## Compares what this bot's client has with the host, for every stop it has reached and not yet checked.
func _check_stops(s: Sess, b: Bot) -> void:
	var c := b.client
	if c.latest == null or c.seed == null:
		return
	var latest: Dictionary = c.latest
	var day: Variant = latest.get("day")
	if day != null and (day["inBed"] as Array).size() == s.ids.size():
		b.saw_all_in[int(day["index"])] = true
	# The day lock: at every bell, the first snapshot this client has from that tick on agrees with the
	# host's day block of the same tick on earned, quota and locked.
	if s.lock:
		var tick := int(latest["tick"])
		for bt in s.bells:
			if b.bells_checked.has(bt) or tick < bt:
				continue
			b.bells_checked[bt] = true
			var tag := "%s at the bell of tick %d (snapshot %d)" % [b.id, bt, tick]
			var hs := s.host.state_at(tick)
			if hs == null:
				s.mismatches.append("%s: the host no longer has tick %d" % [tag, tick])
				continue
			var want := Host.day_block(hs)
			if day == null or not (day as Dictionary).has("earned"):
				s.mismatches.append("%s: no day lock in the snapshot's day block" % tag)
				continue
			if int(day["earned"]) != int(want["earned"]) or int(day["quota"]) != int(want["quota"]) or bool(day["locked"]) != bool(want["locked"]):
				s.mismatches.append("%s: earned %s of %s locked %s, the host's %s of %s locked %s" % [tag, day["earned"], day["quota"], day["locked"], want["earned"], want["quota"], want["locked"]])
			var dl: Variant = b.client.day_lock()
			if dl == null or int(dl["earned"]) != int(want["earned"]) or bool(dl["locked"]) != bool(want["locked"]) or str(dl["stakes"]) != str(want["stakes"]):
				s.mismatches.append("%s: day_lock() is %s, the host's block %s" % [tag, str(dl), str(want)])
	for st in s.stops:
		if b.checked.has(st.key):
			continue
		if c.local_depth != st.depth or c.day_index != st.index or int(latest["tick"]) < st.tick or int(latest["depth"]) != st.depth or day_of(latest) != st.index:
			continue
		b.checked[st.key] = true
		var tag := "%s at %s" % [b.id, st.key]
		var hash := Floor.hash_plan(Session.plan_for(str(c.seed), c.local_depth))
		if hash != st.hash:
			s.mismatches.append("%s: the client's plan %s (seed %s) is not the host's %s (seed %s)" % [tag, hash, c.seed, st.hash, st.seed])
		var hs := s.host.state_at(int(latest["tick"]))
		if hs == null:
			s.mismatches.append("%s: the host no longer has tick %d" % [tag, int(latest["tick"])])
			continue
		var want := Host.day_block(hs)
		if day == null:
			s.mismatches.append("%s: no day block in the snapshot" % tag)
			continue
		var keys: Array[String] = ["index", "day", "quota", "streak", "misses", "crew"]
		if s.lock:
			keys.append_array(["earned", "locked", "aboard", "each"] as Array[String])
		elif day.has("earned"):
			s.mismatches.append("%s: a day lock in a run without one" % tag)
		for k: String in keys:
			if int(day[k]) != int(want[k]):
				s.mismatches.append("%s: %s is %s, the host's %s" % [tag, k, str(day[k]), str(want[k])])
		var got_banked: Variant = null if day["result"] == null else int(day["result"]["banked"])
		var want_banked: Variant = null if want["result"] == null else int(want["result"]["banked"])
		if got_banked != want_banked:
			s.mismatches.append("%s: banked %s, the host's %s" % [tag, str(got_banked), str(want_banked)])

## The host side of a tick: new stops, and the fixtures (readings on every tape, a tape on the floor) at
## each floor the crew leaves.
func _on_tick(s: Sess) -> void:
	var st := s.host.state
	var key := "day%d/depth%d" % [st.day_index, st.depth]
	if st.phase == &"arriving" and not s.stop_keys.has(key):
		s.stop_keys[key] = true
		var stop := Stop.new()
		stop.key = key
		stop.tick = s.host.tick
		stop.index = st.day_index
		stop.day = st.day_state.day
		stop.depth = st.depth
		stop.seed = st.seed
		stop.hash = Floor.hash_plan(st.plan)
		stop.place = String(st.plan.place)
		s.stops.append(stop)
	if st.phase == &"boarding" and st.depth > 0 and not s.fixed.has(key):
		s.fixed[key] = true
		var k := s.fixed.size()
		var tape_id := "floor-fixture-%d" % k
		s.floor_fixtures[tape_id] = true
		var lock := s.lock
		var depth := st.depth
		s.acted[s.host.tick] = true
		s.host.act(func(rs: Run.RunState) -> Run.RunStep:
			var x := rs
			for i in s.ids.size():
				x = DayRigLib.give(x, s.ids[i], 40.0 + 13.5 * i + 7.25 * k, "fx-%d-%d" % [k, i])
				if lock:
					x.day_earned += 40.0 + 13.5 * i + 7.25 * k
			x = DayRigLib.drop(x, tape_id, 300.0, Run.car_body(x.car, -1.6, 1.2))
			if lock:
				# The tape on the floor was recorded too; and on the second floor, enough more (as if recorded
				# and lost) to meet the day quota: floor 1's BANK is refused, floor 2's is not.
				x.day_earned += 300.0
				if depth >= 2:
					x.day_earned += float(Run.day_quota_now(x))
			var out := Run.RunStep.new()
			out.state = x
			return out)

## Runs the session until day DAYS + 1 has opened and every bot has checked it, or `limit` seconds.
func _play(s: Sess, limit: float) -> void:
	var last_tick := -1
	var logged := 0
	while s.g < limit:
		s.g += STEP
		s.net.now = s.g
		var before := s.host.state
		s.host.update(s.g)
		if s.host.tick != last_tick:
			last_tick = s.host.tick
			# What the crew held and what lay on the floor at the bell: the tick before each bank.
			for i in range(logged, s.host.event_log.size()):
				var le: Host.LoggedEvent = s.host.event_log[i]
				if le.e["type"] == "banked":
					s.at_bell[le.seq] = [DayRigLib.held(before), DayRigLib.on_floor(before)]
				if le.e["type"] == "bell":
					s.bells.append(le.tick)
			logged = s.host.event_log.size()
			_on_tick(s)
		for b in s.bots:
			b.client.receive(s.g + b.offset)
		for b in s.bots:
			while b.next_frame <= s.g + 1e-9:
				b.next_frame += FRAME
				_bot_frame(s, b)
		var last_key := "day%d/depth1" % (DAYS + 1)
		if s.stop_keys.has(last_key):
			var all := true
			for b in s.bots:
				all = all and b.checked.has(last_key)
			if all:
				return

func test_three_bots_on_a_lossy_link_play_two_days(t: T) -> void:
	_two_days(t, "days-net", false)

## FD2: the same with the day quota's lock. Everyone votes BANK on every floor; floor 1's BANK is refused
## (the crew has not earned the day quota) and the car rides down; floor 2's is not. At every bell every
## client agrees with the host on earned, quota and locked; every client gets each "bankRefused" and each
## day's one "dayMet", the host's, and both days are made.
func test_three_bots_on_a_lossy_link_agree_on_the_day_lock(t: T) -> void:
	var s := _two_days(t, "days-lock-net", true)
	var host_lock: Array = []
	var refused := 0
	var met := {}
	for le in s.host.event_log:
		var ty := String(le.e["type"])
		if ty == "bankRefused" or ty == "dayMet":
			host_lock.append([ty, int(le.e["day"]), int(le.e["earned"]), int(le.e["quota"])])
		if ty == "bankRefused":
			refused += 1
			t.check(int(le.e["earned"]) < int(le.e["quota"]), "a refused BANK had earned %d of %d" % [int(le.e["earned"]), int(le.e["quota"])])
		if ty == "dayMet":
			met[int(le.e["day"])] = int(met.get(int(le.e["day"]), 0)) + 1
		if ty == "dayEnded":
			t.eq(String(le.e["result"]["kind"]), "made", "day %d: a BANK the lock let through is made" % int(le.e["result"]["day"]))
	t.eq(refused, DAYS, "one refused BANK a day (floor 1's)")
	for d in range(1, DAYS + 1):
		t.eq(int(met.get(d, 0)), 1, "day %d: dayMet once" % d)
	for b in s.bots:
		var got: Array = []
		for e in b.client.events:
			if e["type"] == "bankRefused" or e["type"] == "dayMet":
				got.append([String(e["type"]), int(e["day"]), int(e["earned"]), int(e["quota"])])
		t.eq(got, host_lock, "%s's refused votes and met days" % b.id)
		t.eq(b.bells_checked.size(), s.bells.size(), "%s compared its day block at every bell" % b.id)
		# FD3: the screen matched the host on every frame (the mismatches above), and not vacuously.
		t.check(b.view_frames > 1000 and b.view_locked > 100 and b.view_locked < b.view_frames,
			"%s: %d frames compared, %d of them locked" % [b.id, b.view_frames, b.view_locked])
	t.check(s.bells.size() >= 2 * DAYS, "bells: %d" % s.bells.size())

func _two_days(t: T, seed: String, lock: bool) -> Sess:
	var s := Sess.new(seed, lock)
	var t0 := Time.get_ticks_msec()
	_play(s, 900.0)
	var secs := (Time.get_ticks_msec() - t0) / 1000.0
	var want_keys: Array[String] = []
	for d in range(1, DAYS + 1):
		want_keys.append("day%d/depth1" % d)
		if d == 1 or lock:
			want_keys.append("day%d/depth2" % d)
		want_keys.append("day%d/depth0" % d)
	want_keys.append("day%d/depth1" % (DAYS + 1))
	var got_keys: Array[String] = []
	for st in s.stops:
		got_keys.append(st.key)
	t.eq(got_keys, want_keys, "the stops, in order")
	# Every stop: the host's plan is the day's own, and every client checked it and agreed.
	for st in s.stops:
		t.eq(st.seed, Run.day_seed(seed, st.index), "%s: the host's seed" % st.key)
		t.eq(st.hash, Floor.hash_plan(Places.generate(Run.day_seed(seed, st.index), st.depth, Places.CLINIC_ONLY)), "%s: the host's plan is the day seed's" % st.key)
		for b in s.bots:
			t.check(b.checked.has(st.key), "%s never reached %s" % [b.id, st.key])
	for m: String in s.mismatches.slice(0, 8):
		t.check(false, m)
	t.eq(s.mismatches.size(), 0, "disagreements with the host")
	var day1 := ""
	var day2 := ""
	for st in s.stops:
		if st.key == "day1/depth1":
			day1 = st.hash
		if st.key == "day2/depth1":
			day2 = st.hash
	t.check(day1 != "" and day1 != day2, "day 2's first floor is day 1's")
	# Who is in bed: every client saw all three in bed each night.
	for b in s.bots:
		for d in range(1, DAYS + 1):
			t.check(b.saw_all_in.has(d), "%s never saw everyone in bed on day %d" % [b.id, d])
	# The days settled: the host's and every client's "dayEnded", once each and the same.
	var host_ended: Array = []
	var banked_ids := {}
	var banked_total := 0
	for le in s.host.event_log:
		if le.e["type"] == "dayEnded":
			var r: Dictionary = le.e["result"]
			host_ended.append([int(r["day"]), int(r["banked"]), String(r["kind"]), _ints(r["shares"])])
			banked_total += int(r["banked"])
		if le.e["type"] == "banked":
			var bell: Array = s.at_bell.get(le.seq, [{}, {}])
			var held: Dictionary = bell[0]
			var lying: Dictionary = bell[1]
			t.check(s.at_bell.has(le.seq), "the bell of the bank at tick %d was not seen" % le.tick)
			t.check(not lying.is_empty(), "no tape lay on the floor at the bell (the fixture is missing)")
			for id: Variant in le.e["summary"]["tapes"]:
				var tid := str(id)
				t.check(not banked_ids.has(tid), "tape %s banked twice" % tid)
				t.check(not s.floor_fixtures.has(tid) and not lying.has(tid), "tape %s banked from the floor" % tid)
				t.check(held.has(tid), "tape %s was not held by anyone at the bell" % tid)
				banked_ids[tid] = true
			t.eq(int(floorf(float(le.e["summary"]["total"]))), _banked_after(s, le.seq), "the bank's floored total is the day's banked")
	t.eq(host_ended.size(), DAYS, "days settled")
	t.check(banked_total > 0, "nothing banked (vacuous)")
	for b in s.bots:
		var got: Array = []
		for e in b.client.events:
			if e["type"] == "dayEnded":
				var r: Dictionary = e["result"]
				got.append([int(r["day"]), int(r["banked"]), String(r["kind"]), _ints(r["shares"])])
		t.eq(got, host_ended, "%s's settled days" % b.id)
	var links := 0
	var lost := 0
	for k: String in s.net.stats:
		links += 1
		lost += (s.net.stats[k] as Transport.LinkStats).lost
	t.note("%.0f s of play in %.1f s: stops %s; banked %s; %d tapes banked, %d floor tapes never; %d messages lost on %d links" % [
		s.g, secs, ", ".join(got_keys), str(host_ended), banked_ids.size(), s.floor_fixtures.size(), lost, links])
	return s

## The banked total of the first "dayEnded" after event `seq`.
static func _banked_after(s: Sess, seq: int) -> int:
	for le in s.host.event_log:
		if le.seq > seq and le.e["type"] == "dayEnded":
			return int(le.e["result"]["banked"])
	return -1

static func _ints(d: Dictionary) -> Dictionary:
	var out := {}
	var keys := d.keys()
	keys.sort()
	for k: Variant in keys:
		out[str(k)] = int(d[k])
	return out
