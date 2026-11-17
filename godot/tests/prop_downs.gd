# Down first, then out (North Star B6; loop/NIGHT-PLAN.md A5, T8a). Proved here:
#   1. In the run (pure rules), over 200 seeded bot runs on the Clinic, with crews of one to four: the Orderly
#      catches a player, who goes down where they stood and crawls; a crewmate may walk over and hold F beside
#      them (sometimes letting go and starting again), may hold F too far away, or nobody comes. Checked every
#      tick against the test's own oracle (its own reach, hold and timer, not the run's constants):
#        - a heal happens only after one crewmate held F within 1.5 m for 3 s without letting go, and always
#          by then; a healed player is on their feet, and stays on them;
#        - not healed, the player is out exactly 10 s after going down: status out, a red spot where they lie,
#          their tape on the floor there;
#        - while it has someone the Orderly targets nobody else: it never moves, turns, reaches or catches, its
#          bend goes on even on ticks it is watched (the one exception), and it lets go only on the heal or
#          the out;
#        - the crawl is never faster than 0.6 m/s.
#   2. The rule is off unless asked: without it a catch is "caught", as every stored result has it.
#   3. The Playroom: health at 0 is the same down; a heal puts the player back in the seek with health, and
#      an unhealed one is out with their tape dropped (and heard).
#   4. Over the network: three bots, each on its own lossy link (tests/net_harness.gd LOSSY) and its own clock,
#      through the real NetHost (net/host_rules.gd, the down rule on) and NetClient, sending only what a player
#      sends: p0 is caught and healed by p1 holding F beside them, then p1 is caught and nobody comes. Every
#      client gets the same down, heal and out events as the host, every snapshot's downs block and statuses
#      are the host's at that tick, and the host's player row says "down" then "out".
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Follow = preload("res://sim/follow.gd")
const Entity = preload("res://sim/entity.gd")
const Places = preload("res://sim/places.gd")
const Seek = preload("res://sim/seek.gd")
const Instr = preload("res://sim/instrument.gd")
const Rng = preload("res://sim/rng.gd")
const M = preload("res://sim/jsmath.gd")
const Session = preload("res://net/session.gd")
const Transport = preload("res://net/transport.gd")
const Protocol = preload("res://net/protocol.gd")
const Host = preload("res://net/host.gd")
const Client = preload("res://net/client.gd")
const HostRules = preload("res://net/host_rules.gd")
const Harness = preload("res://tests/net_harness.gd")
const DayNet = preload("res://tests/prop_day_net.gd")
const DayRigLib = preload("res://tests/day_rig.gd")
const CountRun = preload("res://tests/prop_count_run.gd")
const JsJson = preload("res://net/jsjson.gd")

const DT := 0.05
## The oracle's own numbers (North Star B6), on purpose not the run's constants.
const O_DOWN := 10.0
const O_HOLD := 3.0
const O_REACH := 1.5
const O_CRAWL := 0.6
const RUNS := 200

# ---------------------------------------------------------------------------------------------
# Helpers.

static func of_type(evs: Array[Dictionary], type: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in evs:
		if e["type"] == type:
			out.append(e)
	return out

static func player(s: Run.RunState, id: String) -> Run.RunPlayer:
	for p in s.players:
		if p.id == id:
			return p
	return null

static func flat(a: Move.Body, b: Move.Body) -> float:
	return M.hypot2(a.x - b.x, a.z - b.z)

## Walkable cells on the landing's level at least `d` steps from the landing, in index order.
static func cells_from(plan: Floor.FloorPlan, d: int) -> Array[Floor.Pos]:
	var dist := Floor.distances_from(plan, plan.landing)
	var out: Array[Floor.Pos] = []
	for i in dist.size():
		var p := Floor.pos_from_index(plan, i)
		if dist[i] >= d and p.level == plan.landing.level:
			out.append(p)
	return out

## A spot `d` metres from `at` along the first of eight ways (from `k`) that is open that far, else the
## furthest one found.
static func spot_from(plan: Floor.FloorPlan, at: Move.Body, d: float, k: int, radius: float = 0.3) -> Move.Body:
	var best := at
	var best_d := -1.0
	for j in 8:
		var a := (k + j) * PI / 4.0
		var b := Move.move_with_collision(plan, at, cos(a) * d, sin(a) * d, radius)
		var got := flat(b, at)
		if got >= d * 0.97:
			return b
		if got > best_d:
			best_d = got
			best = b
	return best

## A body for a message: where, and where in the car's frame.
static func _b(s: Run.RunState, b: Move.Body) -> String:
	var l := Run.car_local(s.car, b.x, b.z)
	return "(%.2f, %.2f, L%d; car u %.2f v %.2f L%d)" % [b.x, b.z, b.level, l[0], l[1], s.car.level]

static func view(id: String, body: Move.Body, yaw: float) -> Run.PlayerInput:
	return Run.PlayerInput.make(id, body, 1.65, yaw, 0.0, 90.0, 70.0)

static func step_toward(plan: Floor.FloorPlan, from: Move.Body, to: Move.Body, speed: float, dt: float = DT) -> Move.Body:
	var d := flat(from, to)
	if d < 1e-6:
		return from
	var stp := minf(speed * dt, d)
	return Move.move_with_collision(plan, from, (to.x - from.x) / d * stp, (to.z - from.z) / d * stp, 0.3)

static func _same_cell(a: Floor.Pos, b: Floor.Pos) -> bool:
	return a.level == b.level and a.x == b.x and a.y == b.y

## One step toward `to` along the floor's route (walks[key] keeps the route), straight in its last cell.
static func walk_to(plan: Floor.FloorPlan, walks: Dictionary, key: String, from: Move.Body, to: Move.Body, speed: float, dt: float = DT) -> Move.Body:
	var here := Move.cell_of(plan, from)
	var there := Move.cell_of(plan, to)
	if _same_cell(here, there):
		walks.erase(key)
		return step_toward(plan, from, to, speed, dt)
	var w: Follow.PathWalk = walks.get(key)
	if w == null or w.path.is_empty() or not _same_cell(w.path[w.path.size() - 1], there):
		w = Follow.start_path_walk(Floor.find_path(plan, here, there))
		walks[key] = w
	if w.path.is_empty() or Follow.path_done(plan, w, from):
		return step_toward(plan, from, to, speed, dt)
	return Follow.step_path_walk(plan, w, from, speed * dt, 0.3)

# ---------------------------------------------------------------------------------------------
# 1. Over 200 bot runs.

class Tally:
	var runs := 0
	var caught := 0
	var heals := 0
	var outs := 0
	var alone_outs := 0
	var interrupted := 0
	var far_holds := 0
	var watched_bend := 0
	var near_others := 0
	var crawled := 0.0
	var failures := 0

func _fail(t: T, tl: Tally, ok: bool, msg: String) -> bool:
	if not ok:
		tl.failures += 1
		if tl.failures <= 12:
			t.check(false, msg)
	return ok

func _one_run(t: T, tl: Tally, i: int) -> void:
	var rng := Rng.make_rng("prop_downs:%d" % i)
	var n := 1 + i % 4
	var ids: Array[String] = []
	for k in n:
		ids.append("p%d" % k)
	var s := Run.create_run("downs-%d" % i, ids, [], false, false, true)
	var plan := s.plan
	var cells := cells_from(plan, 3)
	if cells.is_empty():
		return
	tl.runs += 1
	# The victim, facing away from the Orderly a little over a metre behind them; the others further off.
	var vb := Move.body_at_cell(plan, cells[rng.int_in(0, cells.size() - 1)])
	var ob := spot_from(plan, vb, 1.2, rng.int_in(0, 7), Entity.ORDERLY_RADIUS)
	var bodies := {"p0": vb}
	var yaws := {"p0": Entity.yaw_toward(vb.x - ob.x, vb.z - ob.z)}
	for k in range(1, n):
		var far := spot_from(plan, vb, 6.0 + 2.0 * k, rng.int_in(0, 7))
		bodies[ids[k]] = far
		yaws[ids[k]] = Entity.yaw_toward(far.x - ob.x, far.z - ob.z)
	s = s.copy()
	s.phase = &"away"
	s.call = null
	s.blink = null
	s.lure = false
	var o := s.orderly.copy()
	o.body = ob
	o.yaw = Entity.yaw_toward(vb.x - ob.x, vb.z - ob.z)
	o.mode = &"hunting"
	o.replan_in = 0.0
	o.ever_seen = true
	s.orderly = o
	var players: Array[Run.RunPlayer] = []
	for p in s.players:
		var np := p.copy()
		np.body = bodies[p.id]
		np.aboard = false
		players.append(np)
	s.players = players
	s = DayRigLib.give(s, "p0", 40.0, "downs-%d-r" % i)
	var use := {}
	var inputs := func() -> Array[Run.PlayerInput]:
		var out: Array[Run.PlayerInput] = []
		for id: String in ids:
			var x := view(id, bodies[id], yaws[id])
			x.use = bool(use.get(id, false))
			out.append(x)
		return out

	# Caught.
	var downed := {}
	for _k in roundi(4.0 / DT):
		var r := Run.step_run(s, inputs.call(), DT)
		s = r.state
		var d := of_type(r.events, "downed")
		if not d.is_empty():
			downed = d[0]
			_fail(t, tl, of_type(r.events, "caught").size() == 1 and str(of_type(r.events, "caught")[0]["playerId"]) == "p0", "run %d: a down without its catch" % i)
			break
	if downed.is_empty() or str(downed["playerId"]) != "p0":
		return
	tl.caught += 1
	var t0 := s.t
	var fell: Move.Body = player(s, "p0").body
	_fail(t, tl, flat(downed["at"], vb) < 1e-9, "run %d: went down at %s, stood at %s" % [i, str(downed["at"]), str(vb)])
	_fail(t, tl, absf(float(downed["until"]) - t0 - O_DOWN) < 1e-6, "run %d: out at %.3f for a down at %.3f" % [i, float(downed["until"]), t0])
	_fail(t, tl, player(s, "p0").status == &"down", "run %d: status %s after the catch" % [i, player(s, "p0").status])
	_fail(t, tl, s.orderly.mode == &"bending" and str(s.orderly.bend_target) == "p0", "run %d: the Orderly does not have p0 (%s)" % [i, s.orderly.mode])
	var bend_at := s.orderly.body
	var bend_yaw := s.orderly.yaw

	# What happens next: a crewmate heals (or lets go once and starts again), holds F too far away, or nobody comes.
	var kind := "none"
	if n >= 2:
		var kinds: Array[String] = ["heal", "interrupted", "far", "none", "heal"]
		kind = kinds[rng.int_in(0, 4)]
	var crawl_dir := rng.next() * TAU
	var crawl_for := rng.next() * 1.5
	var start_at := t0 + 1.5 + rng.next() * 4.0
	var hold_first := 0.5 + rng.next() * 2.0
	var reach := 0.3 + rng.next() * 1.0 if kind != "far" else 1.8 + rng.next() * 3.2
	var healer_spot: Move.Body = null
	var hold_from := -1.0
	var let_go := -1.0
	# Others: one walks to stand near the Orderly facing away from it (the easiest prey), one watches it.
	var near_spot: Move.Body = spot_from(plan, bend_at, 1.6 + rng.next() * 1.4, rng.int_in(0, 7)) if n >= 3 else null
	var oracle := {}
	var walks := {}
	var resolved := ""
	var resolved_t := -1.0
	var last_victim := fell
	for _k in roundi(13.0 / DT):
		var tn := s.t + DT
		var vbody: Move.Body = player(s, "p0").body
		# The victim crawls: they claim to be much further than a crawl goes.
		if resolved == "" and tn - t0 <= crawl_for:
			bodies["p0"] = Move.move_with_collision(plan, vbody, cos(crawl_dir) * 3.0 * DT, sin(crawl_dir) * 3.0 * DT, 0.3)
		else:
			bodies["p0"] = vbody
		if n >= 2:
			var h := "p1"
			var hb: Move.Body = bodies[h]
			if tn >= start_at and resolved == "":
				if healer_spot == null:
					healer_spot = spot_from(plan, vbody, reach, rng.int_in(0, 7))
				hb = walk_to(plan, walks, h, hb, healer_spot, 3.0)
				bodies[h] = hb
				var there := flat(hb, healer_spot) < 0.05
				if there and hold_from < 0.0:
					hold_from = tn
				var holding := there
				if kind == "interrupted" and hold_from >= 0.0:
					if tn - hold_from >= hold_first and let_go < 0.0:
						let_go = tn
						tl.interrupted += 1
					if let_go >= 0.0 and tn - let_go < 0.3:
						holding = false
				use[h] = holding
				yaws[h] = Entity.yaw_toward(vbody.x - hb.x, vbody.z - hb.z)
			else:
				use[h] = false
		if near_spot != null and resolved == "":
			bodies["p2"] = walk_to(plan, walks, "p2", bodies["p2"], near_spot, 3.0)
			yaws["p2"] = Entity.yaw_toward(bodies["p2"].x - bend_at.x, bodies["p2"].z - bend_at.z)
		if n >= 4:
			# p3 watches it from where it stands.
			var b3: Move.Body = bodies["p3"]
			yaws["p3"] = Entity.yaw_toward(bend_at.x - b3.x, bend_at.z - b3.z)
		var prev := s
		var r := Run.step_run(s, inputs.call(), DT)
		s = r.state
		var evs := r.events
		var p0 := player(s, "p0")
		if resolved != "":
			if resolved == "healed":
				_fail(t, tl, p0.status == &"ok", "run %d: healed but %s %.2f s later" % [i, p0.status, s.t - resolved_t])
			if s.t - resolved_t >= 1.0:
				break
			continue
		# The crawl.
		var moved := flat(p0.body, last_victim)
		_fail(t, tl, moved <= O_CRAWL * DT + 1e-6, "run %d: crawled %.3f m in a tick, from %s to %s (status %s, %.2f s after going down)" % [i, moved, _b(s, last_victim), _b(s, p0.body), p0.status, s.t - t0])
		tl.crawled += moved
		last_victim = p0.body
		# The oracle's hold: one crewmate on their feet, F held, within reach of where p0 lies, unbroken.
		var full := ""
		for q in s.players:
			if q.id == "p0":
				continue
			var held: bool = bool(use.get(q.id, false)) and q.status == &"ok" and q.body.level == p0.body.level and flat(q.body, p0.body) <= O_REACH + 1e-9
			oracle[q.id] = float(oracle.get(q.id, 0.0)) + DT if held else 0.0
			if float(oracle[q.id]) >= O_HOLD - 1e-6:
				full = q.id
			if bool(use.get(q.id, false)) and q.status == &"ok" and flat(q.body, p0.body) > O_REACH + 0.2:
				tl.far_holds += 1
		var healed := of_type(evs, "healed")
		var out := of_type(evs, "out")
		if not healed.is_empty():
			var by := str(healed[0]["by"])
			_fail(t, tl, full == by, "run %d: healed by %s after %.2f s of holding F within %.1f m (oracle: %s)" % [i, by, float(oracle.get(by, 0.0)), O_REACH, str(oracle)])
			_fail(t, tl, p0.status == &"ok", "run %d: healed but %s" % [i, p0.status])
			_fail(t, tl, s.t - t0 < O_DOWN + 1e-6, "run %d: healed %.2f s after going down" % [i, s.t - t0])
			_fail(t, tl, s.orderly.mode == &"dormant", "run %d: the Orderly is %s after the heal" % [i, s.orderly.mode])
			resolved = "healed"
			resolved_t = s.t
			tl.heals += 1
			continue
		_fail(t, tl, full == "" or float(oracle[full]) < O_HOLD + DT - 1e-6, "run %d: %s held F beside p0 for %.2f s and nothing happened" % [i, full, float(oracle.get(full, 0.0))])
		if not out.is_empty():
			_fail(t, tl, absf(s.t - t0 - O_DOWN) < DT / 2.0, "run %d: out %.3f s after going down" % [i, s.t - t0])
			_fail(t, tl, p0.status == &"out", "run %d: out but %s" % [i, p0.status])
			var spot: Dictionary = out[0]["spot"]
			_fail(t, tl, s.spots.size() == 1 and absf(float(spot["x"]) - p0.body.x) < 0.006 and absf(float(spot["z"]) - p0.body.z) < 0.006, "run %d: the red spot %s is not where p0 lies %s" % [i, str(spot), str(p0.body)])
			var on_floor := false
			for f in s.crew.floor:
				on_floor = on_floor or (f.tape.owner_id == "p0" and flat(f.at, p0.body) < 1e-6)
			_fail(t, tl, on_floor, "run %d: p0's tape is not on the floor where they went out" % i)
			_fail(t, tl, s.orderly.mode == &"dormant", "run %d: the Orderly is %s on the out" % [i, s.orderly.mode])
			resolved = "out"
			resolved_t = s.t
			tl.outs += 1
			if n == 1:
				tl.alone_outs += 1
			continue
		# Still down: the Orderly has them, and nobody else.
		_fail(t, tl, p0.status == &"down", "run %d: p0 is %s %.2f s after going down" % [i, p0.status, s.t - t0])
		_fail(t, tl, s.t - t0 < O_DOWN + 1e-6, "run %d: still down %.2f s after going down" % [i, s.t - t0])
		var od := s.orderly
		_fail(t, tl, od.mode == &"bending" and str(od.bend_target) == "p0", "run %d: the Orderly is %s while p0 is down" % [i, od.mode])
		_fail(t, tl, flat(od.body, bend_at) < 1e-9 and od.body.level == bend_at.level and absf(od.yaw - bend_yaw) < 1e-9, "run %d: the Orderly moved %.3f m while it had p0" % [i, flat(od.body, bend_at)])
		_fail(t, tl, od.target_id == null and od.wind_up_target == null, "run %d: the Orderly targets %s while it has p0" % [i, str(od.target_id if od.target_id != null else od.wind_up_target)])
		_fail(t, tl, of_type(evs, "windUp").is_empty() and of_type(evs, "caught").is_empty(), "run %d: it reached for someone while it had p0" % i)
		if od.seen and prev.orderly.mode == &"bending":
			# The exception: its bend goes on while it is watched.
			_fail(t, tl, od.anim == &"bend" and absf(od.anim_time - prev.orderly.anim_time - DT) < 1e-9, "run %d: the bend stopped while watched" % i)
			tl.watched_bend += 1
		for q in s.players:
			if q.id != "p0" and q.status == &"ok" and flat(q.body, od.body) < 2.0:
				tl.near_others += 1
	if resolved == "":
		_fail(t, tl, false, "run %d: p0 neither healed nor out (%s)" % [i, player(s, "p0").status])

func test_down_then_healed_or_out_over_200_bot_runs(t: T) -> void:
	var tl := Tally.new()
	var t0 := Time.get_ticks_msec()
	for i in RUNS:
		_one_run(t, tl, i)
	var secs := (Time.get_ticks_msec() - t0) / 1000.0
	t.eq(tl.failures, 0, "rule failures over %d runs" % tl.runs)
	t.check(tl.runs >= RUNS, "runs: %d" % tl.runs)
	t.check(tl.caught >= RUNS * 9 / 10, "runs with a catch: %d of %d" % [tl.caught, tl.runs])
	t.check(tl.heals > 0 and tl.outs > 0 and tl.alone_outs > 0, "heals %d, outs %d (%d alone): vacuous" % [tl.heals, tl.outs, tl.alone_outs])
	t.check(tl.interrupted > 0 and tl.far_holds > 0, "interrupted holds %d, ticks of F held too far %d: vacuous" % [tl.interrupted, tl.far_holds])
	t.check(tl.watched_bend > 0 and tl.near_others > 0, "ticks the bend was watched %d, ticks a crewmate stood within 2 m of it %d: vacuous" % [tl.watched_bend, tl.near_others])
	t.note("%d runs in %.1f s: %d caught, %d healed, %d out (%d alone); %d holds let go and started again, %d ticks of F held out of reach; bend watched on %d ticks, a crewmate within 2 m of it on %d; crawled %.1f m" % [
		tl.runs, secs, tl.caught, tl.heals, tl.outs, tl.alone_outs, tl.interrupted, tl.far_holds, tl.watched_bend, tl.near_others, tl.crawled])

# ---------------------------------------------------------------------------------------------
# 2. Off unless asked.

func test_the_down_rule_is_off_unless_asked(t: T) -> void:
	var ids: Array[String] = ["p0", "p1"]
	for downs: bool in [false, true]:
		var s := Run.create_run("downs-off", ids, [], false, false, downs)
		t.eq(s.downs, downs, "create_run's downs")
		t.eq(HostRules.new(true, 1).prepare(Run.create_run("downs-off", ids)).downs, false, "the rules' default")
		t.eq(HostRules.new(true, 1, [], false, false, true).prepare(Run.create_run("downs-off", ids)).downs, true, "the rules, asked")
		var plan := s.plan
		var vb := Move.body_at_cell(plan, cells_from(plan, 3)[0])
		var ob := spot_from(plan, vb, 1.2, 0, Entity.ORDERLY_RADIUS)
		s = s.copy()
		s.phase = &"away"
		s.call = null
		s.blink = null
		var o := s.orderly.copy()
		o.body = ob
		o.mode = &"hunting"
		s.orderly = o
		var away := spot_from(plan, vb, 8.0, 3)
		var evs: Array[Dictionary] = []
		for _k in 60:
			var ins: Array[Run.PlayerInput] = [view("p0", vb, Entity.yaw_toward(vb.x - ob.x, vb.z - ob.z)), view("p1", away, Entity.yaw_toward(away.x - ob.x, away.z - ob.z))]
			var r := Run.step_run(s, ins, DT)
			s = r.state
			evs.append_array(r.events)
		t.eq(of_type(evs, "caught").size(), 1, "downs %s: the catch" % downs)
		t.eq(of_type(evs, "downed").size(), 1 if downs else 0, "downs %s: downed events" % downs)
		t.eq(player(s, "p0").status, &"down" if downs else &"caught", "downs %s: the status after a catch" % downs)
		t.eq(s.orderly.mode, &"bending" if downs else &"dormant", "downs %s: the Orderly after a catch" % downs)

# ---------------------------------------------------------------------------------------------
# 3. The Playroom: down from health.

func test_down_from_health_on_the_playroom(t: T) -> void:
	for heal: bool in [true, false]:
		var r: CountRun.Rig = CountRun.Rig.new("downs-health-%s" % heal)
		r.st = Run.with_downs(r.st)
		r.run(0.1)
		CountRun.to_away(t, r)
		r.st = DayRigLib.give(r.st, "p1", 80.0, "downs-health-p1")
		var spot: Move.Body = r.bodies["p1"]
		var other := CountRun.nudge(r.plan(), spot, 0.05)
		# A count, waited out with nobody on the floor; then p1 walks on the spot until health runs out.
		r.gait["p0"] = &"sprint"
		r.bodies["p0"] = CountRun.nudge(r.plan(), r.bodies["p0"], 0.25)
		r.step()
		for id in CountRun.IDS:
			r.off[id] = true
		r.until_event("countEnd", 40.0)
		r.off.erase("p1")
		r.gait["p1"] = &"walk"
		var downed := {}
		for k in roundi(40.0 / DT):
			r.bodies["p1"] = other if k % 2 == 0 else spot
			for e in r.step().events:
				if e["type"] == "downed":
					downed = e
			if not downed.is_empty():
				break
		if not t.check(not downed.is_empty() and str(downed["playerId"]) == "p1" and str(downed["by"]) == "health", "%s: p1 never went down from health (%s)" % [r.st.seed, str(downed)]):
			continue
		t.eq(r.rp("p1").status, &"down", "%s: down from health is down" % r.st.seed)
		t.eq(CountRun.of_type(r.events, "tapeDropped").size(), 0, "%s: the tape stays with them while down" % r.st.seed)
		var t0: float = r.st.t
		var lies: Move.Body = r.rp("p1").body
		if heal:
			# p0 comes over and holds F beside them.
			r.off.erase("p0")
			r.bodies["p0"] = spot_from(r.plan(), lies, 0.8, 0)
			var healed := {}
			for _k in roundi(4.0 / DT):
				var res: Run.RunStep = _rig_step_use(r, "p0")
				for e in res.events:
					if e["type"] == "healed":
						healed = e
				if not healed.is_empty():
					break
			if t.check(not healed.is_empty() and str(healed["by"]) == "p0", "%s: p0 did not heal p1" % r.st.seed):
				t.check(absf(r.st.t - t0 - O_HOLD) < DT * 1.5, "%s: healed %.2f s after the hold began" % [r.st.seed, r.st.t - t0])
				t.eq(r.rp("p1").status, &"ok", "%s: healed is on their feet" % r.st.seed)
				var sp: Seek.SeekPlayer = r.sp("p1")
				t.check(sp.status == &"ok" and sp.health == Run.HEAL_HEALTH and sp.phase == &"out", "%s: back in the seek with health (%s %.0f)" % [r.st.seed, sp.status, sp.health])
		else:
			var out := {}
			for _k in roundi(11.0 / DT):
				for e in r.step().events:
					if e["type"] == "out":
						out = e
				if not out.is_empty():
					break
			if t.check(not out.is_empty(), "%s: p1 never went out" % r.st.seed):
				t.check(absf(r.st.t - t0 - O_DOWN) < DT / 2.0, "%s: out %.2f s after going down" % [r.st.seed, r.st.t - t0])
				t.eq(r.rp("p1").status, &"out", "%s: status out" % r.st.seed)
				t.eq(CountRun.of_type(r.events, "tapeDropped").size(), 1, "%s: the tape dropped on the out" % r.st.seed)
				var heard := CountRun.of_type(r.step().events, "count")
				t.check(heard.size() == 1 and str(heard[0]["why"]) == "tape" and str(heard[0]["by"]) == "p1", "%s: the dropped tape is heard the next tick (%s)" % [r.st.seed, str(heard)])

## One rig tick with F held by `id`.
static func _rig_step_use(r: CountRun.Rig, id: String) -> Run.RunStep:
	var ins: Array[Run.PlayerInput] = r.inputs()
	for x in ins:
		if x.id == id:
			x.use = true
	var res := Run.step_run(r.st, ins, DT)
	r.st = res.state
	r.events.append_array(res.events)
	return res

# ---------------------------------------------------------------------------------------------
# 4. Over the network.

class NBot:
	var id: String
	var index: int
	var client: Client
	var offset: float
	var next_frame: float
	var body: Move.Body = null
	var use := false
	## Where to stand (null: stay), and where to face (null: away from the Orderly).
	var goal: Move.Body = null
	var face: Move.Body = null
	var walks := {}

class NSess:
	var net: Transport.MemoryNetwork
	var host: Host
	var rules: HostRules
	var bots: Array[NBot] = []
	var g := 0.0
	var rng: Rng
	var ids: Array[String] = ["p0", "p1", "p2"]
	var compared := 0
	var mismatches: Array[String] = []
	var host_rows := {}

	func _init(seed: String) -> void:
		rng = Rng.make_rng("%s:session" % seed)
		net = Transport.MemoryNetwork.new("%s:net" % seed)
		var ht := net.connect_peer("host")
		rules = HostRules.new(true, 1, [], false, false, true)
		host = Host.new(ht, seed, ids, 0.0, Callable(rules, "prepare"), Callable(rules, "step"))
		for i in ids.size():
			var n := Harness.lossy()
			var tr := net.connect_peer(ids[i])
			for pair: Array in [["host", ids[i]], [ids[i], "host"]]:
				var delay := n.delay_min + rng.next() * (n.delay_max - n.delay_min)
				net.set_link(pair[0], pair[1], Transport.LinkConfig.make(delay, n.jitter, n.loss, n.reorder, n.reorder_delay, n.duplicate))
			var b := NBot.new()
			b.id = ids[i]
			b.index = i
			b.offset = (rng.next() - 0.5) * 200.0
			b.next_frame = rng.next() * 0.05
			b.client = Client.new(tr, "host", ids[i], b.offset)
			bots.append(b)

func _nframe(s: NSess, b: NBot) -> void:
	var c := b.client
	var lf := Client.LocalFrame.new()
	lf.body = b.body if b.body != null else Move.Body.make(0.0, 0.0, 0, 0.0)
	if c.seed != null and c.latest != null and b.body != null:
		var plan := Session.plan_for(str(c.seed), c.local_depth)
		var car := Session.car_for(plan)
		var phase := str(c.latest["phase"])
		var body := b.body
		var me: Variant = null
		for p: Dictionary in c.latest["players"]:
			if p["id"] == b.id:
				me = p
		var status := str(me["status"]) if me != null else "ok"
		if b.goal != null and status == "ok" and phase != "arriving":
			if Run.in_car(car, body) or Run.car_local(car, body.x, body.z)[0] > -0.9:
				body = DayNet.walk_toward(plan, phase, car, body, Run.car_body(car, -1.0, -0.5 + 0.5 * b.index))
			else:
				body = walk_to(plan, b.walks, "goal", body, b.goal, 2.0, 0.05)
		var o: Dictionary = c.latest["orderly"]
		var ob := Move.Body.make(float(o["x"]), float(o["z"]), int(o["level"]), float(o["y"]))
		if b.face != null:
			lf.yaw = Entity.yaw_toward(b.face.x - body.x, b.face.z - body.z)
		else:
			lf.yaw = Entity.yaw_toward(body.x - ob.x, body.z - ob.z)
		lf.use = b.use
		b.body = body
		lf.body = body
	var f := c.frame(s.g + b.offset, lf)
	if f.placed != null:
		b.body = f.placed
	_ncheck(s, b)

## The client's newest snapshot against the host's run at that tick: the downs block and every status.
func _ncheck(s: NSess, b: NBot) -> void:
	var c := b.client
	if c.latest == null:
		return
	var latest: Dictionary = c.latest
	var hs := s.host.state_at(int(latest["tick"]))
	if hs == null:
		return
	s.compared += 1
	# The host's block as the wire carries it (quantised), read back as a client reads it.
	var want := Protocol.dec_downs(Protocol._V.new(), JsJson.parse(JsJson.stringify(Protocol.enc_downs(Host.downs_block(hs)))).value)
	var got: Variant = latest.get("downs")
	var statuses := {}
	for p in hs.players:
		statuses[p.id] = String(p.status)
	var seen := {}
	for p: Dictionary in latest["players"]:
		seen[p["id"]] = p["status"]
	if got != want or seen != statuses:
		s.mismatches.append("%s at tick %d: downs %s statuses %s, the host's %s %s" % [b.id, int(latest["tick"]), str(got), str(seen), str(want), str(statuses)])

static func _downs_events(evs: Array) -> Array:
	var out: Array = []
	for e: Dictionary in evs:
		if e["type"] in ["caught", "downed", "healStart", "healStop", "healed", "out"]:
			out.append(e)
	return out

func _nplay(s: NSess, until: Callable, limit: float) -> bool:
	while s.g < limit:
		s.g += 0.025
		s.net.now = s.g
		s.host.update(s.g)
		for b in s.bots:
			b.client.receive(s.g + b.offset)
		for b in s.bots:
			while b.next_frame <= s.g + 1e-9:
				b.next_frame += 0.05
				_nframe(s, b)
		if until.call():
			return true
	return false

static func _host_events(s: NSess) -> Array:
	var out: Array = []
	for le in s.host.event_log:
		out.append(le.e)
	return out

## Puts the Orderly a little over a metre behind `victim` (as the run has them), hunting.
static func _orderly_behind(s: NSess, victim: String) -> void:
	var st := s.host.state
	var vb := player(st, victim).body
	# Straight behind them, as they face on the host (the way that is open nearest to it otherwise).
	var hp: Host.HostPlayer = s.host._players[victim]
	var yaw: float = hp.input["yaw"] if hp.input != null else 0.0
	var k := posmod(roundi((atan2(cos(yaw), sin(yaw))) / (PI / 4.0)), 8)
	var ob := spot_from(st.plan, vb, 1.3, k, Entity.ORDERLY_RADIUS)
	var o := st.orderly.copy()
	o.body = ob
	o.mode = &"hunting"
	o.replan_in = 0.0
	o.dormant_left = 0.0
	o.wind_up_target = null
	o.bend_target = null
	o.last_seen_at = null
	s.host.replace_orderly(o)

## Where everyone is on the host (for a failure's message).
static func _where(s: NSess) -> String:
	var st := s.host.state
	var o := st.orderly
	var out := "t %.2f phase %s; orderly %s at (%.2f, %.2f, L%d) target %s" % [st.t, st.phase, o.mode, o.body.x, o.body.z, o.body.level, str(o.target_id)]
	for p in st.players:
		out += "; %s %s%s at (%.2f, %.2f, L%d) %.2f m" % [p.id, p.status, " aboard" if p.aboard else "", p.body.x, p.body.z, p.body.level, flat(p.body, o.body)]
	return out

static func _park(s: NSess) -> void:
	var o := s.host.state.orderly.copy()
	o.mode = &"dormant"
	o.dormant_left = INF
	o.wind_up_target = null
	o.bend_target = null
	s.host.replace_orderly(o)

func test_three_clients_on_a_lossy_link_agree_on_down_heal_and_out(t: T) -> void:
	var s := NSess.new("downs-net")
	var plan := s.host.state.plan
	var cells: Array[Floor.Pos] = []
	var dist := Floor.distances_from(plan, plan.landing)
	for c in cells_from(plan, 4):
		if dist[Floor.pos_index(plan, c)] <= 9:
			cells.append(c)
	# The Orderly waits, parked, until the test puts it behind someone.
	_park(s)
	# Out of the car to three spots well apart; the car goes once everyone is out.
	var goals: Array[Move.Body] = []
	for c in cells:
		var b := Move.body_at_cell(plan, c)
		var ok := true
		for g in goals:
			ok = ok and flat(g, b) >= 8.0
		if ok:
			goals.append(b)
		if goals.size() == 3:
			break
	for b in s.bots:
		b.goal = goals[b.index % goals.size()]
		b.body = player(s.host.state, b.id).body
	var away := func() -> bool:
		return s.host.state.phase == &"away"
	if not t.check(_nplay(s, away, 30.0), "the car never left (%s)" % s.host.state.phase):
		return
	var settled := func() -> bool:
		for b in s.bots:
			if flat(player(s.host.state, b.id).body, b.goal) > 0.3:
				return false
		return true
	if not t.check(_nplay(s, settled, s.g + 60.0), "the bots never reached their spots: %s" % _where(s)):
		return
	# 1. p0 is caught; p1 walks over and holds F beside them until they are up.
	_orderly_behind(s, "p0")
	var down0 := func() -> bool:
		return player(s.host.state, "p0").status == &"down"
	if not t.check(_nplay(s, down0, s.g + 10.0), "p0 was never caught: %s" % _where(s)):
		return
	var lies := player(s.host.state, "p0").body
	s.bots[1].goal = spot_from(plan, lies, 0.9, 0)
	s.bots[1].face = lies
	var near := func() -> bool:
		var b1 := s.bots[1]
		if b1.body != null and flat(b1.body, b1.goal) < 0.1:
			b1.use = true
		return player(s.host.state, "p0").status == &"ok"
	var healed_ok := _nplay(s, near, s.g + 12.0)
	t.check(healed_ok, "p0 was never healed (%s)" % player(s.host.state, "p0").status)
	s.bots[1].use = false
	s.bots[1].face = null
	# 2. p0 walks off; p1 is caught (the Orderly put behind them), and nobody comes.
	var far_cell := cells[0]
	var best := 0.0
	for c in cells:
		var d := flat(Move.body_at_cell(plan, c), s.bots[1].goal)
		if d > best:
			best = d
			far_cell = c
	s.bots[0].goal = Move.body_at_cell(plan, far_cell)
	var apart := func() -> bool:
		return flat(player(s.host.state, "p0").body, player(s.host.state, "p1").body) > 6.0
	t.check(_nplay(s, apart, s.g + 4.0), "p0 did not walk off")
	_orderly_behind(s, "p1")
	var down1 := func() -> bool:
		return player(s.host.state, "p1").status == &"down"
	t.check(_nplay(s, down1, s.g + 10.0), "p1 was never caught: %s" % _where(s))
	var out1 := func() -> bool:
		return player(s.host.state, "p1").status == &"out"
	t.check(_nplay(s, out1, s.g + 12.0), "p1 was never out (%s)" % player(s.host.state, "p1").status)
	_park(s)
	var tail := s.g + 4.0
	_nplay(s, func() -> bool: return s.g >= tail, s.g + 5.0)

	var host_evs := _downs_events(_host_events(s))
	var types: Array = host_evs.map(func(e: Dictionary) -> String: return "%s:%s" % [e["type"], e["playerId"]])
	t.check(of_type_plain(host_evs, "downed").size() == 2 and of_type_plain(host_evs, "healed").size() == 1 and of_type_plain(host_evs, "out").size() == 1, "the host's down, heal and out: %s" % str(types))
	var host_texts: Array = host_evs.map(func(e: Dictionary) -> String: return JsJson.stringify(e))
	for b in s.bots:
		var got: Array = _downs_events(b.client.events).map(func(e: Dictionary) -> String: return JsJson.stringify(e))
		t.eq(got, host_texts, "%s's down, heal and out events" % b.id)
	for m: String in s.mismatches.slice(0, 6):
		t.check(false, m)
	t.eq(s.mismatches.size(), 0, "snapshots whose downs or statuses differ from the host's")
	t.check(s.compared > 500, "snapshots compared: %d" % s.compared)
	var lost := 0
	for k: String in s.net.stats:
		lost += (s.net.stats[k] as Transport.LinkStats).lost
	t.note("%.0f s of play: %s; %d snapshots compared; %d messages lost" % [s.g, ", ".join(PackedStringArray(types)), s.compared, lost])

static func of_type_plain(evs: Array, type: String) -> Array:
	return evs.filter(func(e: Dictionary) -> bool: return e["type"] == type)
