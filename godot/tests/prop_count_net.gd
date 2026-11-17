# The count over the network (loop/NIGHT-PLAN.md A3, T15d; docs/floors/playarea.md sections 3, 7, 8):
# three bots, on links of 0, 100 and 300 ms one way (each with tests/net_harness.gd's LOSSY jitter, 5%
# loss, reordering and duplicates), each with its own clock, play the Playroom (floor 4 of the game's
# deck) through the real NetHost (net/host.gd with net/host_rules.gd, the Minder awake) and the real
# NetClient, sending only what a player sends: a body, a gait, the hide key, the call.
#   1. Five minutes of walking and creeping (creeping over squeaker tiles and into ball pits, keeping
#      clear of the Minder): no count starts, and nobody loses any health.
#   2. One bot sprints for one frame: one count starts, started by it, "sprint".
#   3. Everyone hides (F at the nearest free hide); the count runs its course.
#   4. After the 15 s, one bot climbs out, creeps to the lift and calls: the last count, and the doors
#      open only when it ends.
# Proved: every client agrees with the host on every count (number, start in host time, length, whether
# it is the last, who and why) and on who was found in each; the seek block in the snapshots agrees with
# the host's state at that tick (each player's hide, peek, phase, status, health); the call ends in open
# doors only after a last count, on every client.
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Follow = preload("res://sim/follow.gd")
const Places = preload("res://sim/places.gd")
const Playroom = preload("res://sim/playroom.gd")
const Seek = preload("res://sim/seek.gd")
const Rng = preload("res://sim/rng.gd")
const M = preload("res://sim/jsmath.gd")
const Session = preload("res://net/session.gd")
const Protocol = preload("res://net/protocol.gd")
const Transport = preload("res://net/transport.gd")
const Host = preload("res://net/host.gd")
const Client = preload("res://net/client.gd")
const HostRules = preload("res://net/host_rules.gd")
const Harness = preload("res://tests/net_harness.gd")
const JsJson = preload("res://net/jsjson.gd")

## The session's clock step, and how often each bot draws a frame (and so sends an input).
const STEP := 0.025
const FRAME := 0.05
## Paces, under the host's limits (it refuses bodies faster than the walk).
const WALK := 2.6
const CREEP := Seek.WANDER_SPEED - 0.1
const RADIUS := 0.3
## Five minutes of walking and creeping before anyone sprints.
const QUIET := 300.0
## One-way delay of each bot's link (seconds).
const DELAYS: Array[float] = [0.0, 0.1, 0.3]
## A bot keeps this far from the Minder as it draws it (metres).
const KEEP_CLEAR := 6.0

class Bot:
	var id: String
	var index: int
	var client: Client
	var offset: float
	var next_frame: float
	var body: Move.Body = null
	var frames := 0
	var path: Array[Floor.Pos] = []
	var next := 0
	var rng: Rng
	## Where the Minder was drawn on the last frame, or null.
	var minder: Move.Body = null
	## "roam" (five quiet minutes), "hide" (to a hide and in), "call" (out, to the lift, call, hide again).
	var mode := "roam"
	var goal_hide := -1
	var pressed_at := -INF
	var sprint_frames := 0
	var called := false
	var gaits: Dictionary = {}

class Sess:
	var net: Transport.MemoryNetwork
	var host: Host
	var rules: HostRules
	var bots: Array[Bot] = []
	var g := 0.0
	var seed: String
	var ids: Array[String] = ["p0", "p1", "p2"]
	## Hides the bots have set off for: hide id -> how many.
	var claims := {}
	## Host ticks on which p0's gait was sprint.
	var sprint_ticks: Array[int] = []
	var sprint_times: Array[float] = []
	var sprints_sent := 0
	var stage := "quiet"
	var mismatches: Array[String] = []
	var health_lost_early := 0.0
	var snaps_checked := 0

	func _init(seed_: String) -> void:
		seed = seed_
		var n := Harness.lossy()
		net = Transport.MemoryNetwork.new("%s:net" % seed)
		var ht := net.connect_peer("host")
		rules = HostRules.new(true, 4, Places.FULL)
		host = Host.new(ht, seed, ids, 0.0, Callable(rules, "prepare"), Callable(rules, "step"))
		var rng := Rng.make_rng("%s:session" % seed)
		for i in ids.size():
			var id := ids[i]
			var tr := net.connect_peer(id)
			for pair: Array in [["host", id], [id, "host"]]:
				net.set_link(pair[0], pair[1], Transport.LinkConfig.make(DELAYS[i], n.jitter, n.loss, n.reorder, n.reorder_delay, n.duplicate))
			var b := Bot.new()
			b.id = id
			b.index = i
			b.offset = (rng.next() - 0.5) * 200.0
			b.next_frame = rng.next() * FRAME
			b.rng = Rng.make_rng("%s:bot:%s" % [seed, id])
			b.client = Client.new(tr, "host", id, g + b.offset)
			bots.append(b)

# ---------------------------------------------------------------------------------------------
# The floor as a bot reads it.

## The floor's lists, worked out once per plan (they are pure functions of it): squeakers, safe cells,
## hides.
static var _lists := {}

static func _list(plan: Floor.FloorPlan, what: String) -> Variant:
	if not _lists.has(plan):
		var squeak := {}
		for k in Playroom.squeakers(plan, plan.seed):
			squeak[k] = true
		_lists[plan] = {"squeak": squeak, "safe": safe_cells(plan, squeak), "hides": Playroom.hides(plan, plan.seed)}
	return _lists[plan][what]

static func _squeak(plan: Floor.FloorPlan) -> Dictionary:
	return _list(plan, "squeak")

static func _hides(plan: Floor.FloorPlan) -> Array[Playroom.Hide]:
	return _list(plan, "hides")

## Walking here is a noise: a squeaker tile, or the ball pit.
static func risky(plan: Floor.FloorPlan, squeak: Dictionary, b: Move.Body) -> bool:
	var c := Move.cell_of(plan, b)
	if squeak.has(Floor.pos_index(plan, c)):
		return true
	var r := Floor.room_id_at(plan, c.level, c.x, c.y)
	return r >= 0 and plan.rooms[r].kind == &"ballpit"

## Walkway cells of level 0 that are not squeakers.
static func safe_cells(plan: Floor.FloorPlan, squeak: Dictionary) -> Array[Floor.Pos]:
	var out: Array[Floor.Pos] = []
	for y in plan.height:
		for x in plan.width:
			var c := Floor.Pos.make(0, x, y)
			if Floor.cell_at(plan, 0, x, y) == Floor.CORRIDOR and not squeak.has(Floor.pos_index(plan, c)):
				out.append(c)
	return out

static func horiz(a: Move.Body, b: Move.Body) -> float:
	return M.hypot2(a.x - b.x, a.z - b.z)

## One step along the bot's path at `speed`; true when the path is done.
static func path_step(plan: Floor.FloorPlan, b: Bot, speed: float) -> Move.Body:
	if b.path.is_empty():
		return b.body
	var w := Follow.PathWalk.make(b.path, b.next)
	var out := Follow.step_path_walk(plan, w, b.body, speed * FRAME, RADIUS)
	return out

static func path_advance(plan: Floor.FloorPlan, b: Bot, speed: float) -> void:
	var w := Follow.PathWalk.make(b.path, b.next)
	b.body = Follow.step_path_walk(plan, w, b.body, speed * FRAME, RADIUS)
	b.next = w.next

static func path_done(plan: Floor.FloorPlan, b: Bot) -> bool:
	return b.path.is_empty() or Follow.path_done(plan, Follow.PathWalk.make(b.path, b.next), b.body)

static func set_path(plan: Floor.FloorPlan, b: Bot, to: Floor.Pos) -> void:
	b.path = Floor.find_path(plan, Move.cell_of(plan, b.body), to)
	b.next = 1 if b.path.size() > 1 else 0

## Straight at a point (the last metre to a hide's front, the doorway), with the run's walls.
static func walk_to(plan: Floor.FloorPlan, phase: String, b: Move.Body, to: Move.Body, speed: float) -> Move.Body:
	var d := horiz(b, to)
	if d < 1e-6:
		return b
	var stp := minf(speed * FRAME, d)
	return Session.move_local(plan, phase, b, (to.x - b.x) / d * stp, (to.z - b.z) / d * stp, RADIUS)

# ---------------------------------------------------------------------------------------------
# What a client knows.

## The count events and countEnds this client has, and the found players of each count, as
## [[n, t0, len, last, by, why, [found ids in order]], ...].
static func counts_of(events: Array) -> Array:
	var out: Array = []
	var cur: Array = []
	for e: Dictionary in events:
		match String(e.get("type", "")):
			"count":
				cur = [int(e["n"]), float(e["t0"]), float(e["len"]), bool(e["last"]), String(e["by"]), String(e["why"]), []]
				out.append(cur)
			"found":
				if not cur.is_empty():
					(cur[6] as Array).append("%s:%s" % [e["playerId"], e["cause"]])
	return out

## This client's own seek record in its newest snapshot, or {}.
static func my_seek(c: Client) -> Dictionary:
	if c.latest == null or c.latest.get("seek") == null:
		return {}
	for p: Dictionary in c.latest["seek"]["players"]:
		if p["id"] == c.id:
			return p
	return {}

## The first event of a type (with `key` equal to `val` when given) in a client's events, or {}.
static func first_event(events: Array, type: String, key: String = "", val: Variant = null) -> Dictionary:
	for e: Dictionary in events:
		if e.get("type") == type and (key == "" or e.get(key) == val):
			return e
	return {}

static func index_of_event(events: Array, type: String, key: String, val: Variant) -> int:
	for i in events.size():
		var e: Dictionary = events[i]
		if e.get("type") == type and e.get(key) == val:
			return i
	return -1

# ---------------------------------------------------------------------------------------------
# A bot's frame.

## The nearest hide with room that no bot has set off for (by walking), or -1.
static func choose_hide(s: Sess, plan: Floor.FloorPlan, b: Bot) -> int:
	var dist := Floor.distances_from(plan, Move.cell_of(plan, b.body))
	var best := -1
	var best_d := 1 << 30
	for h in _hides(plan):
		if int(s.claims.get(h.id, 0)) >= mini(h.capacity, 1):
			continue
		var fc := Move.cell_of(plan, Seek.hide_front_body(plan, h))
		var d := dist[Floor.pos_index(plan, fc)]
		if d >= 0 and d < best_d:
			best = h.id
			best_d = d
	return best

func _bot_frame(s: Sess, b: Bot) -> void:
	var c := b.client
	b.frames += 1
	var local := s.g + b.offset
	var lf := Client.LocalFrame.new()
	lf.body = b.body if b.body != null else Move.Body.make(0.0, 0.0, 0, 0.0)
	lf.gait = "walk"
	if c.seed != null and c.latest != null and b.body != null and int(c.latest["depth"]) == c.local_depth:
		var plan := Session.plan_for(str(c.seed), c.local_depth)
		var car := Session.car_for(plan)
		var squeak := _squeak(plan)
		var phase := str(c.latest["phase"])
		var mine := my_seek(c)
		var status := str(mine.get("status", "ok"))
		var where := str(mine.get("phase", "out"))
		var count := c.count_event()
		var host_now := c.clock.host_time(local)
		var counting: bool = not count.is_empty() and Client.count_clock(count, host_now)["phase"] != "over" and first_event(c.events, "countEnd", "n", count["n"]).is_empty()
		if not count.is_empty() and b.mode == "roam":
			b.mode = "hide"
			b.path = []
		if status != "ok":
			pass  # found, taken or down: the host holds the body; nothing to do.
		elif Run.in_car(car, b.body):
			if phase == "unloading":
				b.body = walk_to(plan, phase, b.body, Run.car_body(car, 0.6, 0.0) if Run.car_local(car, b.body.x, b.body.z)[0] > 0.7 else Run.car_body(car, -1.2, -0.6 + 0.6 * b.index), WALK)
		elif b.mode == "roam":
			_roam(s, b, plan, squeak, lf)
		elif b.mode == "hide":
			_hide(s, b, plan, phase, where, local, lf)
		elif b.mode == "call":
			_call(s, b, plan, car, phase, where, local, lf, counting, count, host_now)
		if b.sprint_frames > 0 and where == "out" and status == "ok":
			b.sprint_frames -= 1
			lf.gait = "sprint"
			b.body = Session.move_local(plan, phase, b.body, 0.2, 0.0, RADIUS) if b.frames % 2 == 0 else Session.move_local(plan, phase, b.body, -0.2, 0.0, RADIUS)
			s.sprints_sent += 1
		lf.body = b.body
	b.gaits[lf.gait] = int(b.gaits.get(lf.gait, 0)) + 1
	var f := c.frame(local, lf)
	if f.placed != null:
		b.body = f.placed
		b.path = []
	b.minder = null
	if f.orderly != null:
		var o: Dictionary = f.orderly
		b.minder = Move.Body.make(float(o["x"]), float(o["z"]), int(o["level"]), float(o["y"]))
	if b.frames % 20 == b.index:
		_check_snapshot(s, b)

## Five quiet minutes: walk the walkways, creep over squeakers and into the ball pit, keep clear of it.
func _roam(s: Sess, b: Bot, plan: Floor.FloorPlan, squeak: Dictionary, lf: Client.LocalFrame) -> void:
	var cells: Array[Floor.Pos] = _list(plan, "safe")
	var near := b.minder != null and b.minder.level == b.body.level and horiz(b.minder, b.body) < KEEP_CLEAR
	if near or path_done(plan, b):
		var best: Floor.Pos = null
		var best_d := -1.0
		for _k in 12:
			var cand := cells[b.rng.int_in(0, cells.size() - 1)]
			var cb := Move.body_at_cell(plan, cand)
			var d := 50.0 if b.minder == null else horiz(cb, b.minder)
			if horiz(cb, b.body) > 4.0 and d > best_d and (not near or d > horiz(b.body, b.minder)):
				best = cand
				best_d = d
		if best != null and (near or best_d >= KEEP_CLEAR + 2.0):
			set_path(plan, b, best)
		elif best != null and path_done(plan, b):
			set_path(plan, b, best)
	var ahead := path_step(plan, b, WALK)
	if risky(plan, squeak, b.body) or risky(plan, squeak, ahead) or (not b.path.is_empty() and b.next < b.path.size() and risky(plan, squeak, Move.body_at_cell(plan, b.path[b.next]))):
		lf.gait = "creep"
		path_advance(plan, b, CREEP)
	else:
		lf.gait = "walk"
		path_advance(plan, b, WALK)

## To the nearest free hide and in. Inside: sit there.
func _hide(s: Sess, b: Bot, plan: Floor.FloorPlan, phase: String, where: String, local: float, lf: Client.LocalFrame) -> void:
	if where != "out":
		return
	if b.goal_hide < 0:
		b.goal_hide = choose_hide(s, plan, b)
		if b.goal_hide < 0:
			return
		s.claims[b.goal_hide] = int(s.claims.get(b.goal_hide, 0)) + 1
		b.path = []
	var h: Playroom.Hide = null
	for x in _hides(plan):
		if x.id == b.goal_hide:
			h = x
	var front := Seek.hide_front_body(plan, h)
	var d := horiz(b.body, front)
	if b.body.level == front.level and d <= 0.8:
		if local - b.pressed_at > 3.0:
			lf.hide = true
			b.pressed_at = local
		return
	var fc := Move.cell_of(plan, front)
	if Move.cell_of(plan, b.body).equals(fc):
		b.body = walk_to(plan, phase, b.body, front, WALK)
		return
	if b.path.is_empty():
		set_path(plan, b, fc)
	path_advance(plan, b, WALK)

## The caller: after the 15 s, out of the hide, creep to the lift, call; then hide again.
func _call(s: Sess, b: Bot, plan: Floor.FloorPlan, car: Run.CarGeometry, phase: String, where: String, local: float, lf: Client.LocalFrame, counting: bool, count: Dictionary, host_now: float) -> void:
	if b.called or not first_event(b.client.events, "called").is_empty():
		if not b.called:
			b.called = true
			b.goal_hide = -1
			b.path = []
		_hide(s, b, plan, phase, where, local, lf)
		return
	if where == "inside":
		if local - b.pressed_at > 3.0:
			lf.hide = true
			b.pressed_at = local
		return
	if where != "out":
		return
	var door := Run.car_body(car, -0.9, 0.0)
	lf.gait = "creep"
	if horiz(b.body, door) <= Run.CALL_REACH - 0.4 and b.body.level == car.level:
		lf.call = phase == "away" and b.frames % 10 == 0
		return
	var dc := Move.cell_of(plan, door)
	if Move.cell_of(plan, b.body).equals(dc):
		b.body = walk_to(plan, phase, b.body, door, CREEP)
		return
	if b.path.is_empty():
		set_path(plan, b, dc)
	path_advance(plan, b, CREEP)

## The seek block this bot's client holds against the host's state at that tick.
func _check_snapshot(s: Sess, b: Bot) -> void:
	var c := b.client
	if c.latest == null or c.latest.get("seek") == null:
		return
	var tick := int(c.latest["tick"])
	var hs := s.host.state_at(tick)
	if hs == null or hs.seek == null:
		return
	var v := Protocol._V.new()
	var want := Protocol.dec_seek(v, JsJson.parse(JsJson.stringify(Protocol.enc_seek(Host.seek_block(hs)))).value)
	var got: Dictionary = c.latest["seek"]
	s.snaps_checked += 1
	for k: String in ["noise", "counting", "last", "called", "done", "n", "t0", "len", "by", "why", "ended"]:
		if got[k] != want[k]:
			s.mismatches.append("%s at tick %d: seek %s is %s, the host's %s" % [b.id, tick, k, str(got[k]), str(want[k])])
	if str(got["players"]) != str(want["players"]):
		s.mismatches.append("%s at tick %d: seek players %s, the host's %s" % [b.id, tick, str(got["players"]), str(want["players"])])

# ---------------------------------------------------------------------------------------------
# The session.

func _on_tick(s: Sess) -> void:
	var st := s.host.state
	if s.host.gait_of("p0") == "sprint":
		s.sprint_ticks.append(s.host.tick)
		s.sprint_times.append(st.t)
	if st.seek != null and (st.seek as Seek.SeekState).counts == 0:
		for sp in (st.seek as Seek.SeekState).players:
			s.health_lost_early = maxf(s.health_lost_early, Seek.HEALTH_MAX - sp.health)
	var n := 0 if st.seek == null else (st.seek as Seek.SeekState).counts
	match s.stage:
		"quiet":
			if s.g >= QUIET:
				s.stage = "sprint"
				s.bots[0].sprint_frames = 1
		"sprint":
			if n > 0:
				s.stage = "count"
			elif s.bots[0].sprint_frames == 0 and s.host.tick % 60 == 0:
				# The frame was lost on the way: one more.
				s.bots[0].sprint_frames = 1
		"count":
			var ss: Seek.SeekState = st.seek
			if ss != null and not ss.counting and ss.ended >= 1 and st.t >= ss.calm_until + 3.0:
				# The caller: the first bot still on the floor.
				for b in s.bots:
					var sp := Seek.player_of(ss, b.id)
					if sp != null and sp.status == &"ok":
						b.mode = "call"
						s.stage = "call"
						break

## Runs until every client has seen the doors open after the last count (or a wipe), or `limit`.
func _play(s: Sess, limit: float) -> void:
	var last_tick := -1
	while s.g < limit:
		s.g += STEP
		s.net.now = s.g
		s.host.update(s.g)
		if s.host.tick != last_tick:
			last_tick = s.host.tick
			_on_tick(s)
		for b in s.bots:
			b.client.receive(s.g + b.offset)
		for b in s.bots:
			while b.next_frame <= s.g + 1e-9:
				b.next_frame += FRAME
				_bot_frame(s, b)
		var all := true
		for b in s.bots:
			var ev := b.client.events
			all = all and (index_of_event(ev, "doorsOpened", "reason", "boarding") >= 0 or not first_event(ev, "wiped").is_empty())
		if all:
			return

func test_three_bots_agree_on_every_count(t: T) -> void:
	var saved := Session.deck
	Session.deck = Places.FULL
	var seed := "count-net"
	var s := Sess.new(seed)
	var t0 := Time.get_ticks_msec()
	_play(s, QUIET + 400.0)
	var secs := (Time.get_ticks_msec() - t0) / 1000.0
	Session.deck = saved
	_lists = {}
	t.eq(s.host.state.plan.place, &"playroom", "the session is on the Playroom")
	var host_events: Array = []
	for le in s.host.event_log:
		host_events.append(le.e)
	var want := counts_of(host_events)
	t.check(want.size() >= 2, "only %d counts on the host (the sprint's and the last one wanted)" % want.size())
	# 1. Five minutes of walking and creeping: no count, no health lost.
	var first: Array = want[0] if not want.is_empty() else []
	t.check(not first.is_empty() and float(first[1]) >= QUIET, "a count started in the five quiet minutes (%s)" % str(first))
	t.eq(s.health_lost_early, 0.0, "health lost before the first count")
	for b in s.bots:
		t.check(int(b.gaits.get("walk", 0)) > 1000 and int(b.gaits.get("creep", 0)) > 0, "%s did not both walk and creep (%s)" % [b.id, str(b.gaits)])
	# 2. One sprint tick, one count, by it, for that.
	t.check(not s.sprint_ticks.is_empty(), "the host never had p0 sprinting")
	if not first.is_empty() and not s.sprint_ticks.is_empty():
		t.eq([first[0], first[4], first[5], first[3]], [1, "p0", "sprint", false], "the first count")
		t.eq(float(first[1]), s.sprint_times[0], "the first count began on the first sprint tick (%d), in host time" % s.sprint_ticks[0])
		var sprint_counts := 0
		for c: Array in want:
			if c[5] == "sprint":
				sprint_counts += 1
		t.eq(sprint_counts, 1, "counts started by the sprint")
	# 3. Every client: the same counts, at the same host times, with the same found.
	for b in s.bots:
		t.eq(counts_of(b.client.events), want, "%s's counts (n, t0, len, last, by, why, found)" % b.id)
	for m: String in s.mismatches.slice(0, 8):
		t.check(false, m)
	t.eq(s.mismatches.size(), 0, "snapshot disagreements with the host")
	t.check(s.snaps_checked > 100, "only %d snapshots checked" % s.snaps_checked)
	# 4. The call: the last count, then the doors, on the host and every client.
	var last: Array = want[want.size() - 1] if not want.is_empty() else []
	t.check(not last.is_empty() and last[3] == true and last[5] == "call", "the last count (%s)" % str(last))
	var wiped := not first_event(host_events, "wiped").is_empty()
	t.check(not wiped, "the crew was wiped in the last count (no doors to check)")
	for evs: Array in [host_events] + s.bots.map(func(b: Bot) -> Array: return b.client.events):
		var called := index_of_event(evs, "called", "last", true)
		var end := index_of_event(evs, "countEnd", "last", true)
		var doors := index_of_event(evs, "doorsOpened", "reason", "boarding")
		t.check(called >= 0 and end > called and doors > end, "the call, the last count's end, then the doors (indices %d, %d, %d)" % [called, end, doors])
		if doors >= 0 and end >= 0:
			t.eq(float((evs[doors] as Dictionary)["t"]), float((evs[end] as Dictionary)["t"]), "the doors open on the last count's end")
	var lost := 0
	for k: String in s.net.stats:
		lost += (s.net.stats[k] as Transport.LinkStats).lost
	var found_all: Array = []
	for c: Array in want:
		found_all.append(c[6])
	t.note("%.0f s of play in %.1f s: %d counts %s, found %s; p0 sent %d sprint frames, sprinting on host ticks %s; %d snapshots checked; %d messages lost" % [
		s.g, secs, want.size(), str(want.map(func(c: Array) -> String: return "%d@%.2f+6+%.0f %s/%s" % [c[0], c[1], c[2], c[4], c[5]])), str(found_all),
		s.sprints_sent, str(s.sprint_ticks), s.snaps_checked, lost])
