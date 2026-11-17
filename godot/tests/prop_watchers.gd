# Two-watcher Stillness (docs/floors/traits-and-hiding.md section 1 and the T19a piece of section 6). Proved here:
#   1. The table: with the rule on, the number needed is 1 with one or two up players and 2 with three or more,
#      at every crew size from one to six, tick by tick; with it off it is always 1.
#   2. Two glances that overlap by less than a frame still hold it (each watcher keeps counting for GRACE), and
#      a lone watcher of two does not.
#   3. Three (and four) bots round a hunting resident, each looking at it and away on its own seeded clock,
#      checked every tick: it never moves, turns, advances its clip or its wind-up in a tick with the number
#      needed counted, nor within GRACE of the last tick the count was met; never when the test's own oracle
#      (prop_entity.gd: the true camera frustum, its own line of sight) sees enough eyes on it; nobody is
#      caught who could see it with enough others; and it does move with one watcher.
#   4. A player going down: in a crew of three, the number needed follows the up players with no lag (2, then 1
#      the first tick the victim is down), and the last two standing stop it alone.
#   5. Over the network: three bots, each on its own lossy, delayed link (tests/net_harness.gd LOSSY) and its own
#      clock, through the real NetHost (net/host_rules.gd with the rule on) and NetClient, looking at it and away
#      on their own clocks. On every client's every frame:
#        - the promise: the pose never changes between two frames that both show every eye mark lit;
#        - a hold shown with every mark lit is the host's: when the marks drop with the figure still in view,
#          it walks on from where it was held, never further along its walk (its own clock), and never
#          jumps ahead on that clock by more than a frame's walk afterwards (a seen report is honoured against what its player
#          had acknowledged: net/host.gd). Scripted late glances make that case: p0 watches over a slow link
#          while the others glance for 150 ms on quick ones;
#        - a lone watcher of two sees it walk: on a frame with one mark of two lit the drawing is not held, and
#          the figure is seen to move on such frames;
#      and every snapshot's watch block is the host's count at that tick.
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Entity = preload("res://sim/entity.gd")
const Rng = preload("res://sim/rng.gd")
const M = preload("res://sim/jsmath.gd")
const Bot = preload("res://sim/bot.gd")
const Plans = preload("res://tests/plans.gd")
const PropEntity = preload("res://tests/prop_entity.gd")
const Downs = preload("res://tests/prop_downs.gd")
const DayNet = preload("res://tests/prop_day_net.gd")
const Session = preload("res://net/session.gd")
const Transport = preload("res://net/transport.gd")
const Protocol = preload("res://net/protocol.gd")
const Host = preload("res://net/host.gd")
const Client = preload("res://net/client.gd")
const HostRules = preload("res://net/host_rules.gd")
const Harness = preload("res://tests/net_harness.gd")
const JsJson = preload("res://net/jsjson.gd")
const Pose = preload("res://net/pose.gd")

const DT := 0.05
const EPS := 1e-9
## The oracle's numbers (the design's table, restated): up players -> watchers needed.
const O_NEED := {1: 1, 2: 1, 3: 2, 4: 2, 5: 2, 6: 2}
## Measured on its own clock (the pose's animTime, which runs only while it is free to act), so a pose the host
## put back to (another player's report: an earlier moment of its walk) never counts, only a jump ahead.
## A hold let go in view may be followed by a pose at most this much later on that clock (seconds): the frame.
const RELEASE_TOL := 0.08
## Walking at a lone watcher of two, its clock moves on at most this much from one frame (50 ms) to the next,
## with room for the drawing clock's catching up. A hold the host never made (a seen report it refused) shows
## as a jump ahead well past it once the drawing follows the host again.
const LONE_STEP := 0.15

static func of_type(evs: Array[Dictionary], type: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in evs:
		if e["type"] == type:
			out.append(e)
	return out

static func flat(a: Move.Body, b: Move.Body) -> float:
	return M.hypot2(a.x - b.x, a.z - b.z)

static func view(id: String, body: Move.Body, yaw: float, active: bool = true) -> Entity.PlayerView:
	return Entity.PlayerView.make(id, body, Bot.BOT_EYE, yaw, 0.0, Bot.BOT_HFOV_DEG, Bot.BOT_VFOV_DEG, active)

## A view from `body` facing `at`.
static func facing(id: String, body: Move.Body, at: Move.Body, active: bool = true) -> Entity.PlayerView:
	return view(id, body, Entity.yaw_toward(at.x - body.x, at.z - body.z), active)

static func sees(plan: Floor.FloorPlan, v: Entity.PlayerView, o: Move.Body) -> bool:
	var one: Array[Entity.PlayerView] = [v]
	return Entity.seen_by(plan, o, one) != null

# ---------------------------------------------------------------------------------------------
# 1. The table.

func test_the_number_needed_follows_the_up_players(t: T) -> void:
	for n in range(0, 7):
		t.eq(Entity.watch_need(n), int(O_NEED.get(n, 1)), "watch_need(%d)" % n)
	for on: bool in [true, false]:
		for n in range(1, 7):
			var ids: Array[String] = []
			for k in n:
				ids.append("p%d" % k)
			var s := Run.create_run("watch-table-%d" % n, ids)
			if on:
				s = Run.with_two_watchers(s)
			var ins: Array[Run.PlayerInput] = []
			for p in s.players:
				ins.append(Run.PlayerInput.make(p.id, p.body, 1.65, 0.0, 0.0, 90.0, 70.0))
			var r := Run.step_run(s, ins, DT)
			t.eq(r.state.orderly.need, int(O_NEED[n]) if on else 1, "%d players, the rule %s: watchers needed" % [n, "on" if on else "off"])
			# An input missing is a player not up this tick.
			if n >= 3 and on:
				var fewer: Array[Run.PlayerInput] = ins.slice(0, n - 1)
				t.eq(Run.step_run(s, fewer, DT).state.orderly.need, int(O_NEED[n - 1]), "%d players, one without an input: watchers needed" % n)

# ---------------------------------------------------------------------------------------------
# 2. Glances and grace, on a straight corridor.

## A floor, a hunting resident on it, and three spots that can all see it: [plan, orderly, [bodies]], or [].
static func stage(seed: String, depth: int, rng: Rng, n: int = 3, near: float = 7.0, far: float = 12.0) -> Array:
	var plan := Plans.plan(seed, depth)
	var o := Entity.create_orderly(plan)
	var ob := o.body
	var dist := Floor.distances_from(plan, Move.cell_of(plan, ob))
	var cand: Array[Move.Body] = []
	for i in dist.size():
		if dist[i] < 0:
			continue
		var c := Floor.pos_from_index(plan, i)
		if c.level != ob.level:
			continue
		var b := Move.body_at_cell(plan, c)
		var d := flat(b, ob)
		if d < near or d > far:
			continue
		if sees(plan, facing("x", b, ob), ob):
			cand.append(b)
	if cand.size() < n:
		return []
	var picked: Array[Move.Body] = []
	var order := range(cand.size())
	for k in order.size():
		var j := rng.int_in(k, order.size() - 1)
		var tmp: int = order[k]
		order[k] = order[j]
		order[j] = tmp
	for k: int in order:
		var b := cand[k]
		var ok := true
		for q in picked:
			ok = ok and flat(q, b) >= 2.5
		if ok:
			picked.append(b)
		if picked.size() == n:
			break
	if picked.size() < n:
		return []
	o.mode = &"hunting"
	o.replan_in = 0.0
	o.ever_seen = true
	return [plan, o, picked]

func test_overlapping_glances_hold_it_and_a_lone_watcher_does_not(t: T) -> void:
	var tried := 0
	for i in 40:
		var st := stage("watch-glance-%d" % i, 1, Rng.make_rng("glance:%d" % i))
		if st.is_empty():
			continue
		tried += 1
		var plan: Floor.FloorPlan = st[0]
		var o: Entity.OrderlyState = st[1]
		var bodies: Array = st[2]
		# A looks for ten ticks; B from the tick after A stops, on and on; C never. Need 2 (three up).
		var held_with_overlap := true
		var moved_alone := false
		for k in 40:
			var ob := o.body
			var views: Array[Entity.PlayerView] = []
			views.append(facing("A", bodies[0], ob) if k < 10 else view("A", bodies[0], Entity.yaw_toward(bodies[0].x - ob.x, bodies[0].z - ob.z)))
			views.append(facing("B", bodies[1], ob) if k >= 10 else view("B", bodies[1], Entity.yaw_toward(bodies[1].x - ob.x, bodies[1].z - ob.z)))
			views.append(view("C", bodies[2], Entity.yaw_toward(bodies[2].x - ob.x, bodies[2].z - ob.z)))
			var r := Entity.step_entity(plan, o, views, DT, -1.0, true, 2)
			var moved := flat(r.state.body, o.body) > 0.0 or r.state.yaw != o.yaw
			if k >= 10 and k < 15:
				# B looks while A's last look is within GRACE: two counted, held.
				held_with_overlap = held_with_overlap and r.state.held and not moved and r.state.watchers.size() == 2
			if k >= 24 and moved and sees(plan, views[1], ob):
				moved_alone = true  # B alone (A's grace and the release grace run out): it walks, watched
			o = r.state
		t.check(held_with_overlap, "seed %d: glances overlapping by less than a frame did not hold it" % i)
		t.check(moved_alone, "seed %d: it never moved under one watcher of two" % i)
		if tried >= 6:
			break
	t.check(tried >= 3, "staged floors: %d" % tried)

# ---------------------------------------------------------------------------------------------
# 3. Bots round a hunting resident.

class Tally:
	var runs := 0
	var ticks := 0
	var met_ticks := 0
	var lone_moves := 0
	var oracle_met := 0
	var catches := 0
	var failures := 0

func _fail(t: T, tl: Tally, ok: bool, msg: String) -> bool:
	if not ok:
		tl.failures += 1
		if tl.failures <= 12:
			t.check(false, msg)
	return ok

func _bots_run(t: T, tl: Tally, i: int) -> void:
	var rng := Rng.make_rng("prop_watchers:%d" % i)
	var n := 3 + (i % 2)
	var st := stage("watchers-%d" % i, 1 + (i % 3), rng, n, 6.0, 13.0)
	if st.is_empty():
		return
	tl.runs += 1
	var plan: Floor.FloorPlan = st[0]
	var o: Entity.OrderlyState = st[1]
	var bodies: Array = st[2]
	var looking: Array[bool] = []
	var until: Array[float] = []
	var active: Array[bool] = []
	for k in n:
		looking.append(rng.next() < 0.5)
		until.append(rng.next() * 1.2)
		active.append(true)
	var last_met := -INF
	var wind_up_eyes := {}
	for _k in roundi(30.0 / DT):
		var tn := o.t + DT
		for k in n:
			if tn >= until[k]:
				looking[k] = not looking[k]
				until[k] = tn + (0.05 + rng.next() * 1.1 if looking[k] else 0.15 + rng.next() * 1.4)
		var views: Array[Entity.PlayerView] = []
		var up := 0
		for k in n:
			var b: Move.Body = bodies[k]
			var yaw := Entity.yaw_toward(o.body.x - b.x, o.body.z - b.z) + (rng.next() - 0.5) * 0.3
			if not looking[k]:
				yaw += PI
			views.append(view("b%d" % k, b, yaw, active[k]))
			if active[k]:
				up += 1
		var need := Entity.watch_need(up)
		var before := o
		var r := Entity.step_entity(plan, before, views, DT, -1.0, true, need)
		o = r.state
		tl.ticks += 1
		_fail(t, tl, o.need == int(O_NEED.get(up, 1)), "run %d t %.2f: need %d with %d up" % [i, o.t, o.need, up])
		var moved := flat(o.body, before.body) > 0.0 or o.body.level != before.body.level or o.yaw != before.yaw
		# Still: not moved or turned, its clip's clock stopped, its wind-up not progressed (cancelled is fine).
		var still := not moved and (o.mode == &"bending" or o.anim_time == before.anim_time) 			and (o.mode != &"windUp" or o.wind_up_left == before.wind_up_left)
		# The count.
		var counted := 0
		for id: String in o.watchers:
			for v in views:
				if v.id == id and v.active:
					counted += 1
		if counted >= need:
			tl.met_ticks += 1
			_fail(t, tl, still, "run %d t %.2f: moved %.3f m with %d of %d watchers counted (%s)" % [i, o.t, flat(o.body, before.body), counted, need, str(o.watchers)])
		elif need == 2 and before.t - last_met < Entity.GRACE - EPS:
			# Two needed: held for GRACE after the last tick the count was met. (With one needed the old
			# rule stands, GRACE after the last look: prop_entity.)
			_fail(t, tl, still, "run %d t %.2f: moved %.3f s after the count was last met" % [i, o.t, before.t - last_met])
		elif counted == 1 and need == 2 and moved:
			tl.lone_moves += 1
		if counted >= need:
			last_met = o.t
		# The oracle: enough true screens on it where it stood.
		var eyes := 0
		for v in views:
			if v.active and PropEntity.oracle_sees(plan, v, before.body):
				eyes += 1
		if eyes >= need:
			tl.oracle_met += 1
			_fail(t, tl, not moved, "run %d t %.2f: moved with %d true screens on it (need %d)" % [i, o.t, eyes, need])
		# Looking saves you, with enough eyes: nobody caught who, with others, held it during the wind-up.
		for e in of_type(r.events, "windUp"):
			wind_up_eyes[e["playerId"]] = false
		if before.mode == &"windUp" and eyes >= need:
			wind_up_eyes[before.wind_up_target] = true
		for e in of_type(r.events, "caught"):
			tl.catches += 1
			_fail(t, tl, not bool(wind_up_eyes.get(e["playerId"], false)), "run %d: %s caught though %d screens held it in the wind-up" % [i, e["playerId"], need])
			for k in n:
				if "b%d" % k == e["playerId"]:
					active[k] = false
		for e in of_type(r.events, "windUpCancelled"):
			wind_up_eyes.erase(e["playerId"])

func test_bots_never_move_it_with_enough_eyes_and_one_does_not_stop_it(t: T) -> void:
	var tl := Tally.new()
	var runs := 8 if t.quick else 30
	for i in runs:
		_bots_run(t, tl, i)
	t.eq(tl.failures, 0, "rule failures")
	t.check(tl.runs >= runs / 2, "staged runs: %d of %d" % [tl.runs, runs])
	t.check(tl.met_ticks > 50, "not vacuous: ticks with enough watchers counted %d" % tl.met_ticks)
	t.check(tl.oracle_met > 20, "not vacuous: ticks with enough true screens on it %d" % tl.oracle_met)
	t.check(tl.lone_moves > 50, "not vacuous: ticks it moved with one watcher of two %d" % tl.lone_moves)
	t.note("%d runs, %d ticks: count met %d, oracle met %d, moved under one of two %d, catches %d" % [tl.runs, tl.ticks, tl.met_ticks, tl.oracle_met, tl.lone_moves, tl.catches])

# ---------------------------------------------------------------------------------------------
# 4. A player going down.

func test_need_drops_the_tick_a_player_is_down_and_the_last_two_stop_it(t: T) -> void:
	var done := 0
	var drops := 0
	var held_ticks := 0
	for i in 12:
		var rng := Rng.make_rng("watch-down:%d" % i)
		var ids: Array[String] = ["p0", "p1", "p2"]
		var s := Run.with_two_watchers(Run.create_run("watch-down-%d" % i, ids, [], false, false, true))
		var plan := s.plan
		var cells := Downs.cells_from(plan, 3)
		if cells.is_empty():
			continue
		# p0 with its back to the resident 1.2 m behind; p1 watches it from a spot that sees it; p2 looks away.
		var vb := Move.body_at_cell(plan, cells[rng.int_in(0, cells.size() - 1)])
		var ob := Downs.spot_from(plan, vb, 1.2, rng.int_in(0, 7), Entity.ORDERLY_RADIUS)
		var wb: Move.Body = null
		for d: float in [4.0, 5.0, 3.0, 6.0]:
			for k in 8:
				var c := Downs.spot_from(plan, ob, d, k)
				if flat(c, ob) > 2.5 and flat(c, vb) > 2.0 and sees(plan, facing("p1", c, ob), ob):
					wb = c
					break
			if wb != null:
				break
		if wb == null:
			continue
		var fb := Downs.spot_from(plan, vb, 8.0, rng.int_in(0, 7))
		var bodies := {"p0": vb, "p1": wb, "p2": fb}
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
		var downed_at := -1.0
		var ok := true
		for _k in roundi(18.0 / DT):
			var ins: Array[Run.PlayerInput] = []
			var od := s.orderly.body
			for id: String in ids:
				var b: Move.Body = Downs.player(s, id).body
				var yaw := Entity.yaw_toward(od.x - b.x, od.z - b.z)
				if id != "p1":
					yaw += PI
				ins.append(Run.PlayerInput.make(id, b, 1.65, yaw, 0.0, Bot.BOT_HFOV_DEG, Bot.BOT_VFOV_DEG))
			var up := 0
			for p in s.players:
				if p.status == &"ok":
					up += 1
			var before := s
			var r := Run.step_run(s, ins, DT)
			s = r.state
			ok = t.eq(s.orderly.need, int(O_NEED[up]), "run %d t %.2f: watchers needed with %d up" % [i, s.t, up]) and ok
			if downed_at < 0.0 and not of_type(r.events, "downed").is_empty():
				downed_at = s.t
			elif downed_at >= 0.0 and up == 2 and before.orderly.mode != &"bending" and s.orderly.mode != &"bending":
				# The last two standing: p1 alone holds it (its look is the one it needs).
				var moved := flat(s.orderly.body, before.orderly.body) > 0.0 or s.orderly.yaw != before.orderly.yaw
				if s.orderly.seen:
					held_ticks += 1
					ok = t.check(not moved, "run %d t %.2f: moved with the one watcher the last two need" % [i, s.t]) and ok
			if downed_at >= 0.0 and up == 2 and s.orderly.need == 1 and before.orderly.need == 2:
				drops += 1
			if not ok:
				break
		if downed_at >= 0.0:
			done += 1
	t.check(done >= 4, "runs with p0 down: %d" % done)
	t.check(drops >= 4, "need fell from 2 to 1 on the first tick with p0 down: %d runs" % drops)
	t.check(held_ticks > 20, "not vacuous: ticks the last two held it with one watcher %d" % held_ticks)
	t.note("%d runs with a down; need fell 2 -> 1 on the first down tick in %d; held by the lone survivor-watcher %d ticks" % [done, drops, held_ticks])

# ---------------------------------------------------------------------------------------------
# 5. Over the network.

class NBot:
	var id: String
	var index: int
	var client: Client
	var offset: float
	var next_frame: float
	var body: Move.Body = null
	var goal: Move.Body = null
	var walks := {}
	## Looking at it (else away), and until when (session time).
	var looking := false
	var until := 0.0
	var on := false
	## A script instead of the clock: [[from, to], ...] seconds after the looking starts, looking in each.
	var looks: Array = []
	## The previous frame: every mark lit, shown, the pose drawn, bent.
	var prev_all := false
	var prev_on := false
	var prev_pose: Variant = null
	var prev_bent := false

class NTally:
	var frames := 0
	var all_pairs := 0
	var lone_frames := 0
	var lone_moves := 0
	var releases := 0
	var max_advance := 0.0
	var max_step := 0.0
	var block_checks := 0
	var failures := 0

class NSess:
	var net: Transport.MemoryNetwork
	var host: Host
	var rules: HostRules
	var bots: Array[NBot] = []
	var g := 0.0
	var rng: Rng
	var ids: Array[String] = ["p0", "p1", "p2"]
	var tl := NTally.new()
	var plan: Floor.FloorPlan
	## Session time the looking started.
	var t_on := INF
	var name := ""

	## `delays`: each player's one-way delay (seconds), or [] for a random 50 to 250 ms each way.
	func _init(seed: String, delays: Array = []) -> void:
		rng = Rng.make_rng("%s:session" % seed)
		net = Transport.MemoryNetwork.new("%s:net" % seed)
		var ht := net.connect_peer("host")
		rules = HostRules.new(true, 1, [], false, false, false, true)
		host = Host.new(ht, seed, ids, 0.0, Callable(rules, "prepare"), Callable(rules, "step"))
		plan = host.state.plan
		for i in ids.size():
			var n := Harness.lossy()
			var tr := net.connect_peer(ids[i])
			for pair: Array in [["host", ids[i]], [ids[i], "host"]]:
				# Delayed: at least 50 ms each way, up to the lossy link's own 250, with its jitter and loss.
				var delay: float = 0.05 + rng.next() * (n.delay_max - 0.05) if delays.is_empty() else float(delays[i])
				net.set_link(pair[0], pair[1], Transport.LinkConfig.make(delay, n.jitter, n.loss, n.reorder, n.reorder_delay, n.duplicate))
			var b := NBot.new()
			b.id = ids[i]
			b.index = i
			b.offset = (rng.next() - 0.5) * 200.0
			b.next_frame = rng.next() * 0.05
			b.client = Client.new(tr, "host", ids[i], b.offset)
			bots.append(b)

func _nfail(s: NSess, t: T, ok: bool, msg: String) -> void:
	if not ok:
		s.tl.failures += 1
		if s.tl.failures <= 12:
			t.check(false, msg)

func _nframe(s: NSess, t: T, b: NBot) -> void:
	var c := b.client
	var lf := Client.LocalFrame.new()
	lf.body = b.body if b.body != null else Move.Body.make(0.0, 0.0, 0, 0.0)
	lf.h_fov_deg = Bot.BOT_HFOV_DEG
	lf.v_fov_deg = Bot.BOT_VFOV_DEG
	if c.seed != null and c.latest != null and b.body != null:
		var car := Session.car_for(s.plan)
		var phase := str(c.latest["phase"])
		var body := b.body
		if b.goal != null and phase != "arriving":
			if Run.in_car(car, body) or Run.car_local(car, body.x, body.z)[0] > -0.9:
				body = DayNet.walk_toward(s.plan, phase, car, body, Run.car_body(car, -1.0, -0.5 + 0.5 * b.index))
			else:
				body = Downs.walk_to(s.plan, b.walks, "goal", body, b.goal, 2.0, 0.05)
		var o: Dictionary = c.latest["orderly"]
		var ob := Move.Body.make(float(o["x"]), float(o["z"]), int(o["level"]), float(o["y"]))
		lf.yaw = Entity.yaw_toward(ob.x - body.x, ob.z - body.z)
		if b.on and not b.looks.is_empty():
			b.looking = false
			for w: Array in b.looks:
				b.looking = b.looking or (s.g - s.t_on >= float(w[0]) and s.g - s.t_on < float(w[1]))
		elif b.on and s.g >= b.until:
			b.looking = not b.looking
			b.until = s.g + (0.08 + s.rng.next() * 1.1 if b.looking else 0.15 + s.rng.next() * 1.3)
		if not (b.on and b.looking):
			lf.yaw += PI
		b.body = body
		lf.body = body
	var f := c.frame(s.g + b.offset, lf)
	if f.placed != null:
		b.body = f.placed
	if not b.on:
		b.prev_all = false
		b.prev_on = false
		b.prev_pose = f.orderly
		return
	s.tl.frames += 1
	var bent: bool = c.latest != null and str(c.latest["orderly"]["mode"]) == "bending"
	var me := lf.body
	# The promise: two frames running with every mark lit, the same pose.
	if f.eyes_all and b.prev_all and f.orderly != null and b.prev_pose != null and not bent and not b.prev_bent:
		s.tl.all_pairs += 1
		_nfail(s, t, Pose.same_pose(f.orderly, b.prev_pose), "%s at %.2f: moved %.3f m on a frame showing every mark lit (%d of %d)" % [b.id, s.g, _gap(f.orderly, b.prev_pose), f.eyes_lit, f.eyes_need])
	if f.eyes_all and not bent:
		_nfail(s, t, f.held, "%s at %.2f: every mark lit but the drawing not held" % [b.id, s.g])
	# A lone watcher of two: the drawing follows the host, and it walks.
	if f.eyes_on and f.eyes_need == 2 and f.eyes_lit == 1:
		s.tl.lone_frames += 1
		_nfail(s, t, not f.held, "%s at %.2f: held on one mark of two" % [b.id, s.g])
		if b.prev_on and f.orderly != null and b.prev_pose != null and not Pose.same_pose(f.orderly, b.prev_pose):
			s.tl.lone_moves += 1
			var step := _ahead(f.orderly, b.prev_pose)
			s.tl.max_step = maxf(s.tl.max_step, step)
			_nfail(s, t, step <= LONE_STEP, "%s at %.2f: jumped %.2f s along its walk (%.2f m nearer) in one frame on one mark of two (a hold the host never made)" % [b.id, s.g, step, _to(b.prev_pose, me) - _to(f.orderly, me)])
	# A hold with every mark lit let go in view: it walks on from where it was held, never nearer.
	if b.prev_all and f.eyes_on and not f.eyes_all and f.orderly != null and b.prev_pose != null and not bent:
		s.tl.releases += 1
		var advance := _ahead(f.orderly, b.prev_pose)
		s.tl.max_advance = maxf(s.tl.max_advance, advance)
		_nfail(s, t, advance <= RELEASE_TOL, "%s at %.2f: let go in view %.2f s further along its walk than it was held (%.2f m nearer; the host never held it there)" % [b.id, s.g, advance, _to(b.prev_pose, me) - _to(f.orderly, me)])
	# The watch block is the host's count at that tick.
	if c.latest != null:
		var hs := s.host.state_at(int(c.latest["tick"]))
		if hs != null:
			s.tl.block_checks += 1
			var want: Variant = Host.watch_block(hs)
			var got: Variant = c.latest.get("watch")
			_nfail(s, t, JsJson.stringify(got) == JsJson.stringify(want), "%s tick %d: watch block %s, the host's %s" % [b.id, int(c.latest["tick"]), JsJson.stringify(got), JsJson.stringify(want)])
	b.prev_all = f.eyes_all
	b.prev_on = f.eyes_on
	b.prev_pose = f.orderly
	b.prev_bent = bent

static func _gap(p: Dictionary, q: Dictionary) -> float:
	return M.hypot3(float(p["x"]) - float(q["x"]), float(p["y"]) - float(q["y"]), float(p["z"]) - float(q["z"]))

## How much further on its own clock pose `p` is than `q` (seconds; 0 across a change of clip).
static func _ahead(p: Dictionary, q: Dictionary) -> float:
	if str(p["anim"]) == "reach" or str(q["anim"]) == "reach":
		return 0.0
	return float(p["animTime"]) - float(q["animTime"])

static func _to(p: Dictionary, b: Move.Body) -> float:
	return M.hypot2(float(p["x"]) - b.x, float(p["z"]) - b.z)

func _nplay(s: NSess, t: T, until: Callable, limit: float) -> bool:
	while s.g < limit:
		s.g += 0.025
		s.net.now = s.g
		s.host.update(s.g)
		for b in s.bots:
			b.client.receive(s.g + b.offset)
		for b in s.bots:
			while b.next_frame <= s.g + 1e-9:
				b.next_frame += 0.05
				_nframe(s, t, b)
		if until.call():
			return true
	return false

## One session: out of the car to three spots that can all see a spot the resident is then put at, hunting;
## then 24 s of the three looking at it and away on their own clocks, until someone is caught. With
## `scripts` (one per player, see NBot.looks) they look as scripted instead, p0 from the spot furthest off.
func _session(t: T, seed: String, delays: Array = [], scripts: Array = []) -> NSess:
	var s := NSess.new(seed, delays)
	s.name = seed
	var plan := s.plan
	var dist := Floor.distances_from(plan, plan.landing)
	var cells: Array[Floor.Pos] = []
	for c in Downs.cells_from(plan, 4):
		if dist[Floor.pos_index(plan, c)] <= 10:
			cells.append(c)
	var parked := s.host.state.orderly.copy()
	parked.mode = &"dormant"
	parked.dormant_left = INF
	s.host.replace_orderly(parked)
	# The resident's spot: one that three spots 7 to 12 m off it, apart from each other, can all see.
	var spot: Move.Body = null
	var goals: Array[Move.Body] = []
	for c in cells:
		var ob := Move.body_at_cell(plan, c)
		var found: Array[Move.Body] = []
		for d in cells:
			var b := Move.body_at_cell(plan, d)
			var r := flat(b, ob)
			if r < 7.0 or r > 12.0 or not sees(plan, facing("x", b, ob), ob):
				continue
			var ok := true
			for q in found:
				ok = ok and flat(q, b) >= 3.0
			if ok:
				found.append(b)
			if found.size() == 3:
				break
		if found.size() == 3:
			spot = ob
			goals = found
			if not scripts.is_empty():
				goals.sort_custom(func(a: Move.Body, b: Move.Body) -> bool: return flat(a, ob) > flat(b, ob))
			break
	if spot == null:
		return null
	for b in s.bots:
		b.goal = goals[b.index]
		b.body = Downs.player(s.host.state, b.id).body
	var away := func() -> bool:
		return s.host.state.phase == &"away"
	if not _nplay(s, t, away, 30.0):
		return null
	var settled := func() -> bool:
		for b in s.bots:
			if flat(Downs.player(s.host.state, b.id).body, b.goal) > 0.3:
				return false
		return true
	if not _nplay(s, t, settled, s.g + 60.0):
		return null
	var o := s.host.state.orderly.copy()
	o.body = spot
	o.mode = &"hunting"
	o.replan_in = 0.0
	o.dormant_left = 0.0
	o.wind_up_target = null
	o.last_seen_at = null
	o.last_met_at = null
	o.looked_at = {}
	s.host.replace_orderly(o)
	for b in s.bots:
		b.client.forget_orderly()
	# A second to settle (everyone facing away), then the looking starts.
	var t1 := s.g + 1.0
	_nplay(s, t, func() -> bool: return s.g >= t1, t1 + 1.0)
	s.t_on = s.g
	for b in s.bots:
		b.on = true
		b.looking = s.rng.next() < 0.5
		b.until = s.g + s.rng.next() * 0.8
		if not scripts.is_empty():
			b.looks = scripts[b.index]
	var caught := func() -> bool:
		for p in s.host.state.players:
			if p.status != &"ok":
				return true
		return false
	_nplay(s, t, caught, s.g + (24.0 if scripts.is_empty() else 8.0))
	return s

func test_three_clients_on_a_lossy_delayed_link_never_see_it_move_with_every_mark_lit(t: T) -> void:
	var sessions := 2 if t.quick else 6
	var all := NTally.new()
	var lost := 0
	var unheld := 0
	var played := 0
	# Random looks; then the late glance: p0 watches it walk at them over a slow link (240 ms each way)
	# while p1 and p2, on quick links, glance at it for 150 ms now and then, so p0's screen holds on a
	# count the host has already let go by the time p0's report arrives.
	var late: Array = [[[0.0, 30.0]], [[0.5, 0.65], [2.6, 2.75], [4.7, 4.85]], [[1.55, 1.7], [3.65, 3.8]]]
	var runs: Array = []
	for i in sessions:
		runs.append(["watch-net-%d" % i, [], []])
	for i in sessions:
		runs.append(["watch-late-%d" % i, [0.24, 0.03, 0.03], late])
	for run: Array in runs:
		var s := _session(t, run[0], run[1], run[2])
		if s == null:
			t.check(false, "session %s: could not be staged" % run[0])
			continue
		played += 1
		for k: String in s.net.stats:
			lost += (s.net.stats[k] as Transport.LinkStats).lost
		unheld += s.host.reports_unheld
		all.frames += s.tl.frames
		all.all_pairs += s.tl.all_pairs
		all.lone_frames += s.tl.lone_frames
		all.lone_moves += s.tl.lone_moves
		all.releases += s.tl.releases
		all.max_advance = maxf(all.max_advance, s.tl.max_advance)
		all.max_step = maxf(all.max_step, s.tl.max_step)
		all.block_checks += s.tl.block_checks
		all.failures += s.tl.failures
	t.eq(all.failures, 0, "failures on the clients' frames")
	t.check(all.all_pairs > 100, "not vacuous: frame pairs with every mark lit %d" % all.all_pairs)
	t.check(all.lone_moves > 20, "not vacuous: frames it walked at a lone watcher of two %d" % all.lone_moves)
	t.check(all.releases > 3, "not vacuous: holds let go in view %d" % all.releases)
	t.check(all.block_checks > 1000, "watch blocks compared %d" % all.block_checks)
	t.note("%d sessions: %d client frames; %d pairs with every mark lit; %d frames with one of two lit (%d moving); %d holds let go in view (at most %.3f s further on); biggest jump on a lone frame %.3f s; %d reports not honoured; %d messages lost" % [
		played, all.frames, all.all_pairs, all.lone_frames, all.lone_moves, all.releases, all.max_advance, all.max_step, unheld, lost])
