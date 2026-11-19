# A second Orderly on deeper Clinic floors (T9b; sim/run.gd "A second Orderly", net/host.gd, net/client.gd). Proved:
#   1. Off unless asked: a run made without it never has a second Orderly, through rides to depth 4; and with it
#      on, the first floor (depth 1, one Orderly) plays tick for tick exactly as with it off (every pose, player
#      and event), so the first floor a crew sees stays the gentle one.
#   2. Depth 1 has one Orderly, a Clinic at depth 2 or deeper has two: when the run starts there and when the car
#      arrives there.
#   3. The start rule (sim/relocate.gd second_start), over a set of seeds and depths: at least SECOND_FROM_LANDING
#      metres by walking from the landing and SECOND_FROM_FIRST (or, relaxed, SECOND_FROM_FIRST_MIN) from the first
#      Orderly's start; never seen by the test's own oracle (tests/prop_entity.gd oracle_sees: the true frustum, its
#      own line of sight) from the landing or any walkable cell round it, facing any of 16 ways; the same twice.
#   4. With wandering, glancing bots and both Orderlies hunting near them, every tick, for EACH Orderly: it never
#      moves or turns on a tick its oracle eyes reach the number of watchers needed; watching one does not hold the
#      other (ticks with enough eyes on one and none on the other, the other moving); and the instrument never
#      records outside the rule: a recording instrument's reading is of an Orderly that moved this tick, within
#      Instr.RECORD_RANGE, one at a time, and repeat readings count per Orderly.
#   5. A catch by the second Orderly downs the player ("caught" and "downed" with "n": 2), it bends over them, a
#      crewmate's heal gets them up, and it stands off.
#   6. Over the network (the real NetHost and NetClient on the in-memory network, two clients on lossy, delayed
#      links): every snapshot's second Orderly is the host's at that tick; both clients draw both; a client
#      watching only the second never sees it move on two frames running that both show it seen (the first
#      keeps walking meanwhile); and a catch by the second is confirmed by its victim's screen (its own taken
#      latch fires) and downs them.
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Entity = preload("res://sim/entity.gd")
const Instr = preload("res://sim/instrument.gd")
const Relocate = preload("res://sim/relocate.gd")
const Places = preload("res://sim/places.gd")
const Rng = preload("res://sim/rng.gd")
const M = preload("res://sim/jsmath.gd")
const Bot = preload("res://sim/bot.gd")
const PropEntity = preload("res://tests/prop_entity.gd")
const Downs = preload("res://tests/prop_downs.gd")
const DayNet = preload("res://tests/prop_day_net.gd")
const HostRules = preload("res://net/host_rules.gd")
const Host = preload("res://net/host.gd")
const Client = preload("res://net/client.gd")
const Session = preload("res://net/session.gd")
const Transport = preload("res://net/transport.gd")
const Protocol = preload("res://net/protocol.gd")
const Pose = preload("res://net/pose.gd")
const JsJson = preload("res://net/jsjson.gd")
const Harness = preload("res://tests/net_harness.gd")

const DT := 0.05
const EPS := 1e-9
## The start rule's numbers, restated (sim/relocate.gd second_start): walking metres from the landing, and from
## the first Orderly's start (relaxed).
const O_FROM_LANDING := 24.0
const O_FROM_FIRST := 16.0
const O_FROM_FIRST_MIN := 8.0

## The rules as the game's rooms make them, with the down rule, two watchers and relocation as asked, and the
## second Orderly on or off (HostRules' last parameter).
static func rules(depth: int, second: bool, downs := true, watchers := true, relocation := false) -> HostRules:
	return HostRules.new(true, depth, [], false, false, downs, watchers, relocation,
		false, false, false, false, false, false, false, false, false, false, false, false, false, false, false,
		false, false, false, false, false, false, false, false, false, false, false, false, false, false,
		false, false, false, false, second)

static func start(seed: String, ids: Array[String], depth: int, second: bool, downs := true, watchers := true, relocation := false) -> Array:
	var r := rules(depth, second, downs, watchers, relocation)
	return [r, r.prepare(Run.create_run(seed, ids))]

static func input(id: String, body: Move.Body, yaw: float) -> Run.PlayerInput:
	return Run.PlayerInput.make(id, body, Bot.BOT_EYE, yaw, 0.0, Bot.BOT_HFOV_DEG, Bot.BOT_VFOV_DEG)

static func flat(a: Move.Body, b: Move.Body) -> float:
	return M.hypot2(a.x - b.x, a.z - b.z)

static func pose_of(o: Entity.OrderlyState) -> String:
	return JsJson.stringify(Protocol.orderly_snap(o)) if o != null else "null"

## Everything a tick decides that the screens and the pay read: both Orderlies, the players, the crew, the events.
static func digest(s: Run.RunState, events: Array[Dictionary]) -> String:
	var parts: Array[String] = [s.phase, "%.4f" % s.t, str(s.depth), pose_of(s.orderly), pose_of(s.orderly2), s.entity_id, s.entity_id2]
	for p in s.players:
		parts.append("%s %s %.4f %.4f %d" % [p.id, p.status, p.body.x, p.body.z, p.body.level])
	for m in s.crew.members:
		parts.append("%s %s %.4f %.4f" % [m.id, m.instrument.needle, m.instrument.rate, m.tape.total])
	parts.append(JsJson.stringify(Protocol.plain(events)))
	return " | ".join(parts)

# ---------------------------------------------------------------------------------------------
# 1. Off unless asked; the first floor unchanged with it on.

## Bots that walk out of the car and wander, calling the car after a while: inputs for this tick.
static func wander_inputs(s: Run.RunState, bots: Array[Bot.Bot], k: int) -> Array[Run.PlayerInput]:
	var out: Array[Run.PlayerInput] = []
	for b in bots:
		var p: Run.RunPlayer = null
		for q in s.players:
			if q.id == b.id:
				p = q
		if p == null or (p.status != &"ok" and p.status != &"down"):
			continue
		if p.aboard and s.phase != &"boarding":
			# Out of the car first, onto the landing.
			b.body = DayNet.walk_toward(s.plan, str(s.phase), s.car, p.body, Run.car_body(s.car, -1.5, 0.0)) if Run.doors_open(s) else p.body
		elif not p.aboard:
			b.body = p.body
			Bot.step_bot(s.plan, b, DT, Run.nearest_orderly(s, b.body).body)
		var v := Bot.bot_view(b)
		var i := input(b.id, b.body, v.yaw)
		i.raised = (k / 40) % 2 == 0
		i.call = k % 300 == 299
		out.append(i)
	return out

func _play(seed: String, depth: int, second: bool, ticks: int) -> Array[String]:
	var ids: Array[String] = ["p0", "p1", "p2"]
	var st := start(seed, ids, depth, second)
	var r: HostRules = st[0]
	var s: Run.RunState = st[1]
	var bots: Array[Bot.Bot] = []
	for id in ids:
		bots.append(Bot.create_bot(s.plan, id, "%s:%s" % [seed, id], 0.5))
	var out: Array[String] = []
	var plan := s.plan
	for k in ticks:
		if s.plan != plan:
			plan = s.plan
			bots = []
			for id in ids:
				bots.append(Bot.create_bot(s.plan, id, "%s:%s:%d" % [seed, id, s.depth], 0.5))
		var step := r.step(s, wander_inputs(s, bots, k), DT)
		s = step.state
		out.append(digest(s, step.events))
	return out

func test_off_unless_asked_and_the_first_floor_is_unchanged(t: T) -> void:
	var seeds := 2 if t.quick else 6
	var compared := 0
	var poses := {}
	var never := 0
	for i in seeds:
		var seed := "o2-off-%d" % i
		var off := _play(seed, 1, false, 1800)
		var on := _play(seed, 1, true, 1800)
		# On the first floor (depth 1) the two runs are the same tick for tick.
		for k in off.size():
			var d_off := off[k].split(" | ")[2]
			if d_off != "1":
				break
			compared += 1
			poses[off[k].split(" | ")[3]] = true
			if not t.check(off[k] == on[k], "%s tick %d: with the second Orderly on, depth 1 differs:\n off %s\n on  %s" % [seed, k, off[k].left(300), on[k].left(300)]):
				break
		# Off: never a second one, whatever depth the crew reaches.
		var ids: Array[String] = ["p0", "p1"]
		var st := start(seed, ids, 1, false)
		var r: HostRules = st[0]
		var s: Run.RunState = st[1]
		for depth in range(2, 5):
			s = s.copy()
			s.phase = &"riding"
			s.timer = DT / 2.0
			var none: Array[Run.PlayerInput] = []
			s = r.step(s, none, DT).state
			t.eq(s.depth, depth, "%s: rode down" % seed)
			if t.check(s.orderly2 == null and s.entity_id2 == "", "%s depth %d: a second Orderly with the flag off" % [seed, depth]):
				never += 1
	t.check(compared > 200 * seeds, "not vacuous: depth-1 ticks compared %d" % compared)
	t.check(poses.size() > 100, "not vacuous: the first Orderly's poses on those ticks %d" % poses.size())
	t.note("%d depth-1 ticks identical with it on and off (%d poses of the Orderly); %d deeper floors with it off have no second" % [compared, poses.size(), never])

# ---------------------------------------------------------------------------------------------
# 2. One at depth 1, two from depth 2.

func test_one_at_depth_one_two_from_depth_two(t: T) -> void:
	var ids: Array[String] = ["p0", "p1", "p2"]
	var seeds := 6 if t.quick else 20
	var twos := 0
	for i in seeds:
		var seed := "o2-count-%d" % i
		var one: Run.RunState = start(seed, ids, 1, true)[1]
		t.check(one.orderly2 == null, "%s: depth 1 has a second Orderly" % seed)
		var st := start(seed, ids, 2, true)
		var two: Run.RunState = st[1]
		if t.check(two.orderly2 != null and two.entity_id2 == "orderly2-2", "%s: depth 2 (a Clinic) has no second Orderly" % seed):
			twos += 1
			t.check(two.orderly2.mode == &"waiting" and not two.orderly2.body.same(two.orderly.body), "%s: the second starts waiting, apart" % seed)
		# Arriving by car: depth 1 -> 2 gets its second as the floor is made, depth 2 -> 3 a new one.
		var r: HostRules = start(seed, ids, 1, true)[0]
		var s := one.copy()
		s.phase = &"riding"
		s.timer = DT / 2.0
		var none: Array[Run.PlayerInput] = []
		s = r.step(s, none, DT).state
		t.check(s.depth == 2 and s.orderly2 != null and s.entity_id2 == "orderly2-2", "%s: arriving at depth 2 brought no second" % seed)
		var s3 := s.copy()
		s3.phase = &"riding"
		s3.timer = DT / 2.0
		s3 = r.step(s3, none, DT).state
		t.check(s3.depth == 3 and s3.orderly2 != null and s3.entity_id2 == "orderly2-3" and s3.orderly2 != s.orderly2, "%s: depth 3 has no new second" % seed)
	t.eq(twos, seeds, "depth-2 floors with two Orderlies")

# ---------------------------------------------------------------------------------------------
# 3. The start rule.

func test_the_second_starts_far_and_out_of_sight_of_the_landing(t: T) -> void:
	var seeds := 8 if t.quick else 30
	var checked := 0
	var relaxed := 0
	var none := 0
	var min_land := INF
	var min_first := INF
	var yaws := 16
	for i in seeds:
		for depth: int in [2, 3, 5]:
			var seed := "o2-start-%d" % i
			var ids: Array[String] = ["p0"]
			var s: Run.RunState = start(seed, ids, depth, true, false, false)[1]
			if s.orderly2 == null:
				none += 1
				continue
			checked += 1
			var plan := s.plan
			var cs := float(plan.cell_size)
			var c2 := Move.cell_of(plan, s.orderly2.body)
			var first := Move.cell_of(plan, Places.create_resident(plan).body)
			var dl := Floor.distances_from(plan, plan.landing)[Floor.pos_index(plan, c2)] * cs
			var df := Floor.distances_from(plan, first)[Floor.pos_index(plan, c2)] * cs
			min_land = minf(min_land, dl)
			min_first = minf(min_first, df)
			t.check(dl >= O_FROM_LANDING - EPS, "%s d%d: %.0f m by walking from the landing" % [seed, depth, dl])
			t.check(df >= O_FROM_FIRST_MIN - EPS, "%s d%d: %.0f m by walking from the first" % [seed, depth, df])
			if df < O_FROM_FIRST - EPS:
				relaxed += 1
			# The oracle: nobody on the landing or round it, facing any way, sees it as the doors open.
			var seen := false
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var x := plan.landing.x + dx
					var y := plan.landing.y + dy
					if not Floor.is_walkable(plan, plan.landing.level, x, y):
						continue
					var at := Move.body_at_cell(plan, Floor.Pos.make(plan.landing.level, x, y))
					for k in yaws:
						var v := Entity.PlayerView.make("o", at, 1.65, k * TAU / yaws, 0.0, 100.0, 70.0, true)
						if PropEntity.oracle_sees(plan, v, s.orderly2.body):
							seen = true
			t.check(not seen, "%s d%d: the second is in sight of the landing at arrival" % [seed, depth])
			# The same twice (one seed, the same for everyone).
			var again: Run.RunState = start(seed, ids, depth, true, false, false)[1]
			t.check(again.orderly2 != null and again.orderly2.body.same(s.orderly2.body) and again.orderly2.yaw == s.orderly2.yaw, "%s d%d: not the same start twice" % [seed, depth])
	t.check(checked >= seeds * 3 - 1, "floors with a second: %d of %d (none: %d)" % [checked, seeds * 3, none])
	t.note("%d floors: nearest to the landing %.0f m, to the first %.0f m by walking; %d relaxed to %.0f m; %d with none" % [checked, min_land, min_first, relaxed, O_FROM_FIRST_MIN, none])

# ---------------------------------------------------------------------------------------------
# 4. Each obeys Stillness on its own; the instrument.

class Tally:
	var ticks := 0
	var held := [0, 0]
	var other_moved := [0, 0]
	var moved := [0, 0]
	var recordings := [0, 0]
	var catches := 0
	var failures := 0
	var repeats_both := 0

func _fail(t: T, tl: Tally, ok: bool, msg: String) -> bool:
	if not ok:
		tl.failures += 1
		if tl.failures <= 12:
			t.check(false, msg)
	return ok

static func _orderly_k(s: Run.RunState, k: int) -> Entity.OrderlyState:
	return s.orderly if k == 0 else s.orderly2

## A hunting resident on a cell `d0` to `d1` cells by walking from `from`, apart from `avoid` by 3 cells.
static func _near(plan: Floor.FloorPlan, rng: Rng, from: Floor.Pos, d0: int, d1: int, avoid: Floor.Pos = null) -> Floor.Pos:
	var dist := Floor.distances_from(plan, from)
	var dav := Floor.distances_from(plan, avoid) if avoid != null else PackedInt32Array()
	var cands: Array[int] = []
	for i in dist.size():
		var p := Floor.pos_from_index(plan, i)
		if dist[i] >= d0 and dist[i] <= d1 and Floor.is_walkable(plan, p.level, p.x, p.y) and (avoid == null or dav[i] >= 3):
			cands.append(i)
	return Floor.pos_from_index(plan, cands[rng.int_in(0, cands.size() - 1)]) if not cands.is_empty() else null

func _stillness_run(t: T, tl: Tally, i: int) -> void:
	var seed := "o2-still-%d" % i
	var rng := Rng.make_rng("%s:test" % seed)
	var ids: Array[String] = ["p0", "p1", "p2"]
	var st := start(seed, ids, 2 + (i % 3), true, true, true, i % 2 == 1)
	var r: HostRules = st[0]
	var s: Run.RunState = (st[1] as Run.RunState).copy()
	if s.orderly2 == null:
		return
	var plan := s.plan
	# The crew out on the floor, round one cell; both Orderlies hunting a few cells off, apart.
	var home := _near(plan, rng, plan.landing, 4, 10)
	var c1 := _near(plan, rng, home, 3, 6)
	var c2 := _near(plan, rng, home, 3, 6, c1)
	if home == null or c1 == null or c2 == null:
		return
	s.phase = &"away"
	var players: Array[Run.RunPlayer] = []
	var bots: Array[Bot.Bot] = []
	for id in ids:
		var b := Bot.create_bot(plan, id, "%s:%s" % [seed, id], 0.5, false, home)
		bots.append(b)
		var p := Downs.player(s, id).copy()
		p.body = b.body
		p.aboard = false
		players.append(p)
	s.players = players
	for k in 2:
		var o := _orderly_k(s, k).copy()
		o.body = Move.body_at_cell(plan, c1 if k == 0 else c2)
		o.mode = &"hunting"
		o.replan_in = 0.0
		if k == 0:
			s.orderly = o
		else:
			s.orderly2 = o
	# Each bot looks at one of the two, or away, on its own seeded clock.
	var look := [0, 1, 2]
	var until := [0.0, 0.0, 0.0]
	for tick in roundi(30.0 / DT):
		var inputs: Array[Run.PlayerInput] = []
		var views: Array[Entity.PlayerView] = []
		var up := 0
		for j in bots.size():
			var b := bots[j]
			var p := Downs.player(s, b.id)
			if p.status != &"ok" and p.status != &"down":
				continue
			if s.t >= until[j]:
				look[j] = rng.int_in(0, 2)
				until[j] = s.t + 0.1 + rng.next() * 1.4
			b.body = p.body
			if p.status == &"ok":
				Bot.step_bot(plan, b, DT, null, Instr.RAISED_SPEED_CAP)
			var target: Variant = _orderly_k(s, look[j]).body if look[j] < 2 else null
			var yaw := b.yaw if target == null else Entity.yaw_toward((target as Move.Body).x - b.body.x, (target as Move.Body).z - b.body.z) + (rng.next() - 0.5) * 0.3
			if target == null:
				yaw = Entity.yaw_toward(s.orderly.body.x - b.body.x, s.orderly.body.z - b.body.z) + PI
			var inp := input(b.id, b.body, yaw)
			inp.raised = true
			inputs.append(inp)
			if p.status == &"ok":
				up += 1
				views.append(Entity.PlayerView.make(b.id, b.body, Bot.BOT_EYE, yaw, 0.0, Bot.BOT_HFOV_DEG, Bot.BOT_VFOV_DEG, true))
		var need := Entity.watch_need(up)
		var before := s
		var step := r.step(s, inputs, DT)
		s = step.state
		tl.ticks += 1
		var eyes := [0, 0]
		var moved := [false, false]
		for k in 2:
			var b0 := _orderly_k(before, k)
			var b1 := _orderly_k(s, k)
			if b0 == null or b1 == null:
				return
			for v in views:
				if PropEntity.oracle_sees(plan, v, b0.body):
					eyes[k] += 1
			moved[k] = (flat(b0.body, b1.body) > 0.0 or b0.body.level != b1.body.level or b0.yaw != b1.yaw) and b1.mode != &"bending" and not b1.relocated
			if moved[k]:
				tl.moved[k] += 1
			if eyes[k] >= need:
				tl.held[k] += 1
				_fail(t, tl, not moved[k], "%s t %.2f: Orderly %d moved %.3f m with %d true screens on it (need %d)" % [seed, s.t, k + 1, flat(b0.body, b1.body), eyes[k], need])
		for k in 2:
			if eyes[k] >= need and eyes[1 - k] == 0 and moved[1 - k]:
				tl.other_moved[k] += 1
		# The instrument: recording only of an Orderly that moved this tick, within range, one at a time.
		for m in s.crew.members:
			if m.instrument.rate <= 0.0 or m.instrument.current == null:
				continue
			var id := m.instrument.current.entity_id
			var k := 0 if id == s.entity_id else (1 if id == s.entity_id2 else -1)
			if not _fail(t, tl, k >= 0, "%s t %.2f: %s records %s, neither Orderly" % [seed, s.t, m.id, id]):
				continue
			tl.recordings[k] += 1
			var b0 := _orderly_k(before, k)
			var b1 := _orderly_k(s, k)
			_fail(t, tl, Instr.stillness_acting(b0, b1), "%s t %.2f: %s records Orderly %d while its rule is not tested" % [seed, s.t, m.id, k + 1])
			var d := Instr.feet_distance(m.body, b1.body)
			_fail(t, tl, d <= Instr.RECORD_RANGE + 1e-6, "%s t %.2f: %s records Orderly %d from %.1f m" % [seed, s.t, m.id, k + 1, d])
		for e in step.events:
			if e["type"] == "caught":
				tl.catches += 1
	var keys := s.crew.repeats.keys()
	if keys.has("%s/stillness" % s.entity_id) and keys.has("%s/stillness" % s.entity_id2):
		tl.repeats_both += 1

func test_each_obeys_stillness_alone_and_the_instrument_reads_one(t: T) -> void:
	var tl := Tally.new()
	var runs := 4 if t.quick else 16
	for i in runs:
		_stillness_run(t, tl, i)
	t.eq(tl.failures, 0, "rule failures")
	t.check(tl.held[0] > 20 and tl.held[1] > 20, "not vacuous: ticks with enough eyes on each %s" % str(tl.held))
	t.check(tl.other_moved[0] > 5 and tl.other_moved[1] > 5, "not vacuous: ticks one was held while the other walked %s" % str(tl.other_moved))
	t.check(tl.recordings[0] > 5 and tl.recordings[1] > 5, "not vacuous: instrument ticks recording each %s" % str(tl.recordings))
	t.check(tl.repeats_both > 0, "repeat readings counted per Orderly (both subjects in the crew's memory) in %d runs" % tl.repeats_both)
	t.note("%d ticks; held by enough eyes %s; the other walked meanwhile %s; moved %s; recording ticks %s; catches %d; runs with repeat counts for both %d" % [
		tl.ticks, str(tl.held), str(tl.other_moved), str(tl.moved), str(tl.recordings), tl.catches, tl.repeats_both])

# ---------------------------------------------------------------------------------------------
# 5. A catch by the second; the heal.

func test_a_catch_by_the_second_downs_and_the_heal_gets_them_up(t: T) -> void:
	var seeds := 2 if t.quick else 6
	var done := 0
	for i in seeds:
		var seed := "o2-catch-%d" % i
		var rng := Rng.make_rng(seed)
		var ids: Array[String] = ["p0", "p1"]
		var st := start(seed, ids, 2, true, true, false)
		var r: HostRules = st[0]
		var s: Run.RunState = (st[1] as Run.RunState).copy()
		var plan := s.plan
		var home := _near(plan, rng, plan.landing, 5, 10)
		var spot := _near(plan, rng, home, 2, 3)
		if home == null or spot == null:
			continue
		s.phase = &"away"
		var players: Array[Run.RunPlayer] = []
		for id in ids:
			var p := Downs.player(s, id).copy()
			p.body = Move.body_at_cell(plan, home)
			p.aboard = false
			players.append(p)
		s.players = players
		var first := s.orderly.copy()
		first.mode = &"dormant"
		first.dormant_left = INF
		s.orderly = first
		var o2 := s.orderly2.copy()
		o2.body = Move.body_at_cell(plan, spot)
		o2.mode = &"hunting"
		o2.replan_in = 0.0
		s.orderly2 = o2
		var victim := Move.body_at_cell(plan, home)
		var downed := false
		var healed := false
		var stood_off := false
		var caught_by_2 := false
		for k in roundi(40.0 / DT):
			var inputs: Array[Run.PlayerInput] = []
			# p0 faces away from it; p1 stands off, looking away, until p0 is down, then heals them.
			var p0 := Downs.player(s, "p0")
			inputs.append(input("p0", p0.body, Entity.yaw_toward(s.orderly2.body.x - p0.body.x, s.orderly2.body.z - p0.body.z) + PI))
			var p1 := Downs.player(s, "p1")
			var b1 := p1.body
			if downed and not healed:
				b1 = Downs.walk_to(plan, {}, "h", p1.body, p0.body, 2.0)
			var i1 := input("p1", b1, Entity.yaw_toward(s.orderly2.body.x - b1.x, s.orderly2.body.z - b1.z) + PI)
			i1.use = downed and not healed and flat(b1, p0.body) < 1.0
			inputs.append(i1)
			var step := r.step(s, inputs, DT)
			s = step.state
			for e in step.events:
				if e["type"] == "caught" and e["playerId"] == "p0":
					caught_by_2 = int(e.get("n", 1)) == 2
				if e["type"] == "downed" and e["playerId"] == "p0":
					downed = true
					t.check(s.orderly2.mode == &"bending" and str(s.orderly2.bend_target) == "p0", "%s: the second does not bend over its catch" % seed)
					t.check(s.orderly.mode == &"dormant", "%s: the first moved" % seed)
				if e["type"] == "healed" and e["playerId"] == "p0":
					healed = true
					stood_off = s.orderly2.mode == &"dormant" and s.orderly2.bend_target == null
			if healed:
				break
		t.check(caught_by_2, "%s: no catch by the second (\"n\": 2)" % seed)
		t.check(downed, "%s: not downed" % seed)
		t.check(healed, "%s: not healed" % seed)
		t.check(stood_off, "%s: the second did not stand off after the heal" % seed)
		t.eq(str(Downs.player(s, "p0").status), "ok", "%s: p0 back on their feet" % seed)
		if caught_by_2 and downed and healed:
			done += 1
	t.eq(done, seeds, "catches by the second, downed and healed")

# ---------------------------------------------------------------------------------------------
# 6. Over the network.

class NBot:
	var id: String
	var client: Client
	var offset: float
	var next_frame: float
	var body: Move.Body
	## 0: face the first; 1: the second; 2: away from the first; 3: away from the second.
	var look := 2
	var prev_seen2 := false
	var prev_pose2: Variant = null
	var drew := [0, 0]
	var latched := false

class NSess:
	var net: Transport.MemoryNetwork
	var host: Host
	var rules: HostRules
	var bots: Array[NBot] = []
	var g := 0.0
	var plan: Floor.FloorPlan
	var failures := 0
	var held_pairs := 0
	var block_checks := 0
	var first_walked := 0
	## Ticks the test itself changed the host's state after that tick's snapshots went (replace_orderly).
	var replaced := {}

	func _init(seed: String, ids: Array[String]) -> void:
		var rng := Rng.make_rng("%s:session" % seed)
		net = Transport.MemoryNetwork.new("%s:net" % seed)
		var ht := net.connect_peer("host")
		rules = HostRules.new(true, 2, [], false, false, true, false, false,
			false, false, false, false, false, false, false, false, false, false, false, false, false, false, false,
			false, false, false, false, false, false, false, false, false, false, false, false, false, false,
			false, false, false, false, true)
		host = Host.new(ht, seed, ids, 0.0, Callable(rules, "prepare"), Callable(rules, "step"))
		plan = host.state.plan
		for i in ids.size():
			var n := Harness.lossy()
			var tr := net.connect_peer(ids[i])
			for pair: Array in [["host", ids[i]], [ids[i], "host"]]:
				net.set_link(pair[0], pair[1], Transport.LinkConfig.make(0.05 + rng.next() * 0.15, n.jitter, n.loss, n.reorder, n.reorder_delay, n.duplicate))
			var b := NBot.new()
			b.id = ids[i]
			b.offset = (rng.next() - 0.5) * 100.0
			b.next_frame = rng.next() * 0.05
			b.client = Client.new(tr, "host", ids[i], b.offset)
			bots.append(b)

func _nframe(s: NSess, t: T, b: NBot) -> void:
	var c := b.client
	var lf := Client.LocalFrame.new()
	lf.body = b.body if b.body != null else Move.Body.make(0.0, 0.0, 0, 0.0)
	lf.h_fov_deg = Bot.BOT_HFOV_DEG
	lf.v_fov_deg = Bot.BOT_VFOV_DEG
	if c.latest != null and b.body != null:
		var key := "orderly2" if b.look == 1 or b.look == 3 else "orderly"
		var o: Variant = c.latest.get(key, c.latest["orderly"])
		lf.yaw = Entity.yaw_toward(float(o["x"]) - b.body.x, float(o["z"]) - b.body.z) + (PI if b.look >= 2 else 0.0)
	var f := c.frame(s.g + b.offset, lf)
	if f.placed != null:
		b.body = f.placed
	if f.orderly != null:
		b.drew[0] += 1
	if f.orderly2 != null:
		b.drew[1] += 1
	if f.taken:
		b.latched = true
	# The promise, for the second: two frames running that both show it seen (held), the same pose.
	if f.seeing2 and f.held2 and b.prev_seen2 and f.orderly2 != null and b.prev_pose2 != null and str((f.orderly2 as Dictionary)["anim"]) != "bend":
		s.held_pairs += 1
		if not Pose.same_pose(f.orderly2, b.prev_pose2):
			s.failures += 1
			if s.failures <= 8:
				t.check(false, "%s at %.2f: the second moved on two frames running that both show it seen" % [b.id, s.g])
	b.prev_seen2 = f.seeing2 and f.held2
	b.prev_pose2 = f.orderly2
	# Every snapshot's second Orderly is the host's at that tick.
	if c.latest != null and c.latest.has("orderly2"):
		var hs := s.host.state_at(int(c.latest["tick"]))
		if hs != null and hs.orderly2 != null and not s.replaced.has(int(c.latest["tick"])):
			s.block_checks += 1
			var want := Protocol.orderly_snap(hs.orderly2)
			var got: Dictionary = c.latest["orderly2"]
			if not Pose.same_pose(got, want) or str(got["mode"]) != str(want["mode"]) or float(got["speed"]) != float(want["speed"]) or bool(got["frozen"]) != bool(want["frozen"]):
				s.failures += 1
				if s.failures <= 8:
					t.check(false, "%s tick %d: the second's block differs from the host's" % [b.id, int(c.latest["tick"])])

func _nplay(s: NSess, t: T, until: Callable, limit: float) -> bool:
	while s.g < limit:
		s.g += 0.025
		s.net.now = s.g
		var before := s.host.state.orderly.body
		s.host.update(s.g)
		if flat(before, s.host.state.orderly.body) > 0.0:
			s.first_walked += 1
		for b in s.bots:
			b.client.receive(s.g + b.offset)
		for b in s.bots:
			while b.next_frame <= s.g + 1e-9:
				b.next_frame += 0.05
				_nframe(s, t, b)
		if until.call():
			return true
	return false

## Two clients out on the floor at one cell: the first Orderly hunting a few cells off, the second another few.
func _nsession(t: T, seed: String) -> NSess:
	var ids: Array[String] = ["p0", "p1"]
	var s := NSess.new(seed, ids)
	var rng := Rng.make_rng("%s:spots" % seed)
	if s.host.state.orderly2 == null:
		return null
	var home := _near(s.plan, rng, s.plan.landing, 5, 9)
	var c1 := _near(s.plan, rng, home, 6, 9)
	var c2 := _near(s.plan, rng, home, 3, 5, c1)
	if home == null or c1 == null or c2 == null:
		return null
	var p1 := s.host.state.orderly.copy()
	p1.mode = &"dormant"
	p1.dormant_left = INF
	s.host.replace_orderly(p1)
	var p2 := s.host.state.orderly2.copy()
	p2.mode = &"dormant"
	p2.dormant_left = INF
	s.host.replace_orderly2(p2)
	s.replaced[s.host.tick] = true
	for b in s.bots:
		b.body = Downs.player(s.host.state, b.id).body
	var goal := Move.body_at_cell(s.plan, home)
	var walks := {}
	var away := func() -> bool:
		return s.host.state.phase == &"away"
	if not _nplay(s, t, away, 30.0):
		return null
	# Walk out to the spot (the clients' own bodies).
	var there := func() -> bool:
		var car := Session.car_for(s.plan)
		var all := true
		for b in s.bots:
			if Run.in_car(car, b.body) or Run.car_local(car, b.body.x, b.body.z)[0] > -0.9:
				b.body = DayNet.walk_toward(s.plan, "away", car, b.body, Run.car_body(car, -1.0, 0.0))
			else:
				b.body = Downs.walk_to(s.plan, walks, b.id, b.body, goal, 2.0, 0.025)
			all = all and flat(Downs.player(s.host.state, b.id).body, goal) < 0.5
		return all
	if not _nplay(s, t, there, s.g + 60.0):
		return null
	var o1 := s.host.state.orderly.copy()
	o1.body = Move.body_at_cell(s.plan, c1)
	o1.mode = &"hunting"
	o1.dormant_left = 0.0
	o1.replan_in = 0.0
	o1.last_seen_at = null
	s.host.replace_orderly(o1)
	var o2 := s.host.state.orderly2.copy()
	o2.body = Move.body_at_cell(s.plan, c2)
	o2.mode = &"hunting"
	o2.dormant_left = 0.0
	o2.replan_in = 0.0
	o2.last_seen_at = null
	s.host.replace_orderly2(o2)
	s.replaced[s.host.tick] = true
	for b in s.bots:
		b.client.forget_orderly()
	return s

func test_two_clients_over_the_network_see_both_and_the_second_keeps_its_rule(t: T) -> void:
	var sessions := 2 if t.quick else 5
	var played := 0
	var pairs := 0
	var checks := 0
	var catches := 0
	var latched := 0
	var walked := 0
	for i in sessions:
		var s := _nsession(t, "o2-net-%d" % i)
		if s == null:
			t.check(false, "session %d could not be staged" % i)
			continue
		played += 1
		# Both watch only the second: it holds on their screens, while the first walks at them.
		for b in s.bots:
			b.look = 1
		var caught := func() -> bool:
			for p in s.host.state.players:
				if p.status != &"ok":
					return true
			return false
		var w0 := s.first_walked
		_nplay(s, t, caught, s.g + 2.5)
		walked += s.first_walked - w0
		if Downs.player(s.host.state, "p0").status != &"ok":
			t.note("session %d: p0 was caught by the first while watching the second; no catch by the second tried" % i)
			continue
		# Then p0 turns away from both, p1 keeps watching the first only: the second comes for p0.
		var o1 := s.host.state.orderly.copy()
		o1.mode = &"dormant"
		o1.dormant_left = INF
		s.host.replace_orderly(o1)
		s.bots[0].look = 3
		s.bots[1].look = 3
		var ev_from := s.host.event_log.size()
		var p0_down := func() -> bool:
			return Downs.player(s.host.state, "p0").status != &"ok"
		_nplay(s, t, p0_down, s.g + 30.0)
		# The victim's screen catches up with the catch (its latch is let go once drawn past it).
		var t2 := s.g + 1.0
		_nplay(s, t, func() -> bool: return false, t2)
		var by2 := false
		var downed := false
		for k in range(ev_from, s.host.event_log.size()):
			var e: Dictionary = s.host.event_log[k].e
			if e["type"] == "caught" and e["playerId"] == "p0" and int(e.get("n", 1)) == 2:
				by2 = true
			if e["type"] == "downed" and e["playerId"] == "p0":
				downed = true
		var o2s := s.host.state.orderly2
		t.check(by2 and downed, "session %d: p0 not caught and downed by the second (by2 %s, downed %s; p0 %s; the second %s at %.1f m)" % [i, by2, downed,
			Downs.player(s.host.state, "p0").status, o2s.mode, flat(o2s.body, Downs.player(s.host.state, "p0").body)])
		if by2:
			catches += 1
		if s.bots[0].latched or s.bots[0].client.stats.latches > 0:
			latched += 1
		for b in s.bots:
			t.check(b.drew[0] > 50 and b.drew[1] > 50, "session %d: %s drew the first %d frames, the second %d" % [i, b.id, b.drew[0], b.drew[1]])
		t.eq(s.failures, 0, "session %d: failures" % i)
		pairs += s.held_pairs
		checks += s.block_checks
	t.check(played == sessions, "sessions played %d of %d" % [played, sessions])
	t.check(pairs > 40, "not vacuous: frame pairs with the second held and seen %d" % pairs)
	t.check(walked > 10, "not vacuous: ticks the first walked while both watched the second %d" % walked)
	t.check(checks > 500, "second's blocks compared with the host %d" % checks)
	t.check(latched == catches, "the victim's taken latch fired for %d of %d catches by the second" % [latched, catches])
	t.note("%d sessions: %d held-and-seen frame pairs of the second; %d snapshot blocks compared; the first walked %d ticks meanwhile; %d catches by the second, latched on the victim's screen in %d" % [played, pairs, checks, walked, catches, latched])

# ---------------------------------------------------------------------------------------------
# 7. The second looks like a different individual (the owner, 19 Nov): its own tinted material; the first's untouched.

const View = preload("res://client/orderly_view.gd")

static func _mats(view: View) -> Array[Material]:
	var out: Array[Material] = []
	for mi: MeshInstance3D in view.model.find_children("*", "MeshInstance3D", true, false):
		for i in mi.mesh.get_surface_count():
			out.append(mi.get_active_material(i))
	return out

## The mean colour of one atlas patch (Godot UV rectangle) of a texture.
static func _mean(tex: Texture2D, r: Array) -> Color:
	var img := tex.get_image().duplicate() as Image
	if img.is_compressed():
		img.decompress()
	var w := img.get_width()
	var h := img.get_height()
	var sum := Color(0, 0, 0, 0)
	var n := 0
	for y in range(int(r[1] * h), int(r[3] * h), 4):
		for x in range(int(r[0] * w), int(r[2] * w), 4):
			sum += img.get_pixel(x, y)
			n += 1
	return sum / float(n)

func test_the_second_wears_its_own_darker_gown_and_paler_skin(t: T) -> void:
	var root := (Engine.get_main_loop() as SceneTree).root
	var first := View.new()
	root.add_child(first)
	var before := _mats(first)
	var shared: StandardMaterial3D = before[0]
	var shared_tex := shared.albedo_texture
	var shared_color := shared.albedo_color
	var second := View.new()
	root.add_child(second)
	second.use_second_look()
	var m1 := _mats(first)
	var m2 := _mats(second)
	t.eq(m1.size(), m2.size(), "surfaces")
	for i in m1.size():
		t.check(m1[i] == before[i], "the first view's material %d was replaced" % i)
		t.check(m2[i] != m1[i], "the second view shares material %d with the first" % i)
	t.check(shared.albedo_texture == shared_tex and shared.albedo_color == shared_color, "the shared material was edited")
	var tex1 := (m1[0] as StandardMaterial3D).albedo_texture
	var tex2 := (m2[0] as StandardMaterial3D).albedo_texture
	t.check(tex2 != tex1, "the second has no atlas of its own")
	var gown1 := _mean(tex1, View.SECOND_GOWN_UV[0])
	var gown2 := _mean(tex2, View.SECOND_GOWN_UV[0])
	var skin1 := _mean(tex1, View.SECOND_SKIN_UV[0])
	var skin2 := _mean(tex2, View.SECOND_SKIN_UV[0])
	var mask1 := _mean(tex1, [0.0, 0.0, 0.5, 0.5])
	var mask2 := _mean(tex2, [0.0, 0.0, 0.5, 0.5])
	t.check(gown2.get_luminance() < gown1.get_luminance() * 0.75, "the second's gown is not darker: %s vs %s" % [gown2, gown1])
	var sat := func(c: Color) -> float: return c.s
	t.check(sat.call(skin2) < sat.call(skin1) * 0.7, "the second's skin is not greyer: %s vs %s" % [skin2, skin1])
	t.check(mask2.is_equal_approx(mask1), "the mask and its printed face changed: %s vs %s" % [mask2, mask1])
	t.note("gown luminance %.3f -> %.3f; skin saturation %.3f -> %.3f; mask unchanged" % [gown1.get_luminance(), gown2.get_luminance(), skin1.s, skin2.s])
	first.queue_free()
	second.queue_free()
