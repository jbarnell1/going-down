# Relocation: losing track of it (docs/floors/traits-and-hiding.md section 5 and the T19e piece of section 6).
# Proved here:
#   1. Over seeded bot runs on 40 Clinics and 40 Annexes (6 of each in the quick set): three wandering bots,
#      every one holding its instrument up, with relocation, two-watcher Stillness and the down rule on, the
#      resident hunting from the start. At every relocation, by the test's own oracle and numbers (not the
#      rules' constants):
#        - no eye (a player on their feet or down) has a clear line to the old spot or the new one, from their
#          own eyes or from eye height over their own cell or any of the eight round it (as if they had stepped
#          sideways), whichever way they face;
#        - the arrival is 12 to 20 m by walking from the player it went to and 12 m or more from every other,
#          on a walkable cell that is never a hide's inside or front spot (sim/hides.gd's list once it exists,
#          the Playroom's own on a Playroom, none before), the lobby, the landing, the car's zone or a stair;
#        - no watcher was counted on that tick;
#        - its arrival cue (the "relocated" event) comes on every arrival and is audible to at least one player
#          by Entity.audibility;
#        - no instrument records on the relocation tick or for 3 s after it (and holders were in reach then);
#        - never two within 20 s.
#      The same seeds and inputs give the same relocations (the pick is the floor's seeded draw).
#   2. The Stillness trigger in a run: no watcher for 12 s and more than 30 m by walking from its target, it
#      leaves within a second or two out of view; not before 12 s, not with a watcher, not while the lift is
#      boarding or a blink is on.
#   3. The rule is off unless asked: without it nothing ever relocates.
#   4. Over the network: three wandering bots on lossy, delayed links through the real NetHost (net/host_rules.gd
#      with relocation on) and NetClient. A client never draws the figure between the two poses: on every frame
#      drawn between the last tick before a relocation and its tick, the figure is at the new pose (the snap) or
#      still at the old one, never on the way.
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Entity = preload("res://sim/entity.gd")
const Instr = preload("res://sim/instrument.gd")
const Sight = preload("res://sim/sight.gd")
const Rng = preload("res://sim/rng.gd")
const M = preload("res://sim/jsmath.gd")
const Bot = preload("res://sim/bot.gd")
const Places = preload("res://sim/places.gd")
const Playroom = preload("res://sim/playroom.gd")
const Session = preload("res://net/session.gd")
const Transport = preload("res://net/transport.gd")
const Host = preload("res://net/host.gd")
const Client = preload("res://net/client.gd")
const HostRules = preload("res://net/host_rules.gd")
const Harness = preload("res://tests/net_harness.gd")
const DayNet = preload("res://tests/prop_day_net.gd")
const Downs = preload("res://tests/prop_downs.gd")

const DT := 0.05
const EPS := 1e-6
## The design's numbers (section 5), restated on purpose rather than read from the rules.
const O_NEAR_MIN := 12.0
const O_NEAR_MAX := 20.0
const O_STAND := 3.0
const O_REST := 20.0
const O_CAR_ZONE := 2.0
const O_UNWATCHED := 12.0
const O_FAR := 30.0
const O_RECORD_RANGE := 9.0
const IDS: Array[String] = ["b0", "b1", "b2"]
const PLACES: Array[StringName] = [&"clinic", &"annex"]

static func of_type(evs: Array[Dictionary], type: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in evs:
		if e["type"] == type:
			out.append(e)
	return out

static func flat(a: Move.Body, b: Move.Body) -> float:
	return M.hypot2(a.x - b.x, a.z - b.z)

static func body_of(v: Variant) -> Move.Body:
	if v is Move.Body:
		return v
	var d: Dictionary = v
	return Move.Body.make(float(d["x"]), float(d["z"]), int(d["level"]), float(d["y"]))

# ---------------------------------------------------------------------------------------------
# The oracle.

## A clear line from the player standing at `at` (eyes `eye` above their feet) to the figure (body `k`) standing
## at `fig`: from their own eyes, or from eye height over the centre of their cell or any of the eight round it
## that can be stood on; to its feet, knees, waist, chest, head or shoulders, at its own size or the larger
## outline its walk reaches. Facing is ignored.
static func o_line(plan: Floor.FloorPlan, at: Move.Body, eye: float, fig: Move.Body, k: Entity.BodySettings) -> bool:
	var cs := float(plan.cell_size)
	var from: Array[Sight.Point3] = [Sight.Point3.make(at.x, at.y + eye, at.z, at.level)]
	var cx := floori(at.x / cs)
	var cz := floori(at.z / cs)
	var level := Move.cell_of(plan, at).level
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			if Floor.is_walkable(plan, level, cx + dx, cz + dz):
				from.append(Sight.Point3.make((cx + dx + 0.5) * cs, at.y + eye, (cz + dz + 0.5) * cs, level))
	for v in from:
		var pts := Sight.figure_points(fig, v.x, v.z, k.height, k.radius)
		pts.append_array(Sight.figure_points(fig, v.x, v.z, k.seen_height, k.seen_radius_walk))
		for p in pts:
			if Sight.has_line_of_sight(plan, v, p):
				return true
	return false

## Every hide on the floor, Playroom.Hide-shaped: sim/hides.gd's hides_for once T19b has built it, else the
## Playroom's own on a Playroom, else none.
static func o_hides(plan: Floor.FloorPlan) -> Array:
	if ResourceLoader.exists("res://sim/hides.gd"):
		var script: Script = load("res://sim/hides.gd")
		return script.call("hides_for", plan, plan.seed)
	return Playroom.hides(plan, plan.seed) if plan.place == &"playroom" else []

## Why a cell may not take an arrival, or "" if it may.
static func o_barred(plan: Floor.FloorPlan, car: Run.CarGeometry, c: Floor.Pos, hides: Array) -> String:
	if not Floor.is_walkable(plan, c.level, c.x, c.y):
		return "not walkable"
	if Floor.cell_at(plan, c.level, c.x, c.y) == Floor.STAIR:
		return "a stair"
	if c.level == plan.landing.level and c.x == plan.landing.x and c.y == plan.landing.y:
		return "the landing"
	for r in plan.rooms:
		if r.kind == &"lobby" and r.level == c.level and c.x >= r.x and c.x < r.x + r.w and c.y >= r.y and c.y < r.y + r.h:
			return "the lobby"
	var cs := float(plan.cell_size)
	var gx := maxf(0.0, maxf(car.rect.x0 - (c.x + 1) * cs, c.x * cs - car.rect.x1))
	var gz := maxf(0.0, maxf(car.rect.z0 - (c.y + 1) * cs, c.y * cs - car.rect.z1))
	if c.level == car.level and M.hypot2(gx, gz) <= O_CAR_ZONE + EPS:
		return "the car's zone"
	for h: Variant in hides:
		for spot: Vector2i in [h.inside, h.front]:
			if int(h.level) == c.level and floori(spot.x / (cs * 100.0)) == c.x and floori(spot.y / (cs * 100.0)) == c.y:
				return "hide %d's spot" % int(h.id)
	return ""

## Where a player's walking is measured from: the landing from the car, else their cell.
static func walk_cell(s: Run.RunState, b: Move.Body) -> Floor.Pos:
	return s.plan.landing if Run.in_car(s.car, b) else Move.cell_of(s.plan, b)

# ---------------------------------------------------------------------------------------------
# 1. Bot runs.

class Tally:
	var runs := 0
	var ticks := 0
	var relocations := 0
	var by_why := {}
	var quiet_ticks := 0
	var exposed := 0
	var catches := 0
	var failures := 0
	var hides := 0
	var gaps: Array[float] = []

func _fail(t: T, tl: Tally, ok: bool, msg: String) -> bool:
	if not ok:
		tl.failures += 1
		if tl.failures <= 12:
			t.check(false, msg)
	return ok

## One bot run; returns its relocations as [t, x, z, level, near, k] rows (the sameness check).
func _bot_run(t: T, tl: Tally, place: StringName, i: int, secs: float) -> Array:
	var seed := "reloc-%s-%d" % [place, i]
	var s := Run.create_run(seed, IDS, [place], false, false, true)
	s = Run.with_relocation(Run.with_two_watchers(s))
	var plan := s.plan
	var sig: Array = []
	if plan.place != place:
		_fail(t, tl, false, "%s: the floor is a %s" % [seed, plan.place])
		return sig
	tl.runs += 1
	var hides := o_hides(plan)
	tl.hides += hides.size()
	var k := Entity.kind_of(s.orderly)
	# Out on the floor: the car gone, each bot on its own reachable cell, the resident hunting.
	s = s.copy()
	s.phase = &"away"
	s.call = null
	s.blink = null
	s.lure = false
	var bots: Array[Bot.Bot] = []
	var players: Array[Run.RunPlayer] = []
	for n in IDS.size():
		var b := Bot.create_bot(plan, IDS[n], "%s:bots" % seed, 0.25 + 0.25 * n)
		bots.append(b)
		var np := s.players[n].copy()
		np.body = b.body
		np.aboard = false
		players.append(np)
	s.players = players
	var o := s.orderly.copy()
	o.mode = &"hunting"
	o.replan_in = 0.0
	s.orderly = o
	var last_arrival := -INF
	var quiet_until := -INF
	for _n in roundi(secs / DT):
		var ins: Array[Run.PlayerInput] = []
		for n in IDS.size():
			var p := Downs.player(s, IDS[n])
			var b := bots[n]
			if p.status == &"ok":
				Bot.step_bot(plan, b, DT, s.orderly.body, Instr.RAISED_SPEED_CAP if n == 0 else INF)
				var inp := Run.PlayerInput.make(p.id, b.body, Bot.BOT_EYE, b.yaw, b.pitch, Bot.BOT_HFOV_DEG, Bot.BOT_VFOV_DEG)
				inp.raised = true
				ins.append(inp)
			elif p.status == &"down":
				var dn := Run.PlayerInput.make(p.id, p.body, Bot.BOT_EYE, b.yaw, b.pitch, Bot.BOT_HFOV_DEG, Bot.BOT_VFOV_DEG)
				dn.blind = true
				ins.append(dn)
		var before := s
		var r := Run.step_run(s, ins, DT)
		s = r.state
		tl.ticks += 1
		tl.catches += of_type(r.events, "caught").size()
		var moved := of_type(r.events, "relocated")
		var counted := s.orderly.relocations - before.orderly.relocations if s.depth == before.depth else 0
		_fail(t, tl, moved.size() == counted, "%s t %.2f: %d relocation(s) and %d arrival cue(s)" % [seed, s.t, counted, moved.size()])
		for e in moved:
			tl.relocations += 1
			var why := str(e.get("why", "?"))
			tl.by_why[why] = int(tl.by_why.get(why, 0)) + 1
			var from := body_of(e["from"])
			var to := body_of(e["to"])
			var near := str(e["near"])
			sig.append([s.t, to.x, to.z, to.level, near, int(e["k"])])
			var tag := "%s t %.2f relocation %d (%s)" % [seed, s.t, int(e["k"]), why]
			# Never two within 20 s.
			if last_arrival > -INF:
				tl.gaps.append(s.t - last_arrival)
			_fail(t, tl, s.t - last_arrival >= O_REST - EPS, "%s: %.2f s after the last arrival" % [tag, s.t - last_arrival])
			last_arrival = s.t
			quiet_until = s.t + O_STAND
			_fail(t, tl, flat(s.orderly.body, to) < 1e-9 and s.orderly.body.level == to.level, "%s: the event's spot is not where it stands" % tag)
			_fail(t, tl, s.orderly.watchers.is_empty(), "%s: relocated with watchers %s counted" % [tag, str(s.orderly.watchers)])
			# Out of every line, old spot and new, from every eye and the cells round it.
			var heard := false
			var near_cell: Floor.Pos = null
			for p in s.players:
				if p.status != &"ok" and p.status != &"down":
					continue
				_fail(t, tl, not o_line(plan, p.body, Bot.BOT_EYE, from, k), "%s: %s (%s) had a clear line to where it left" % [tag, p.id, p.status])
				_fail(t, tl, not o_line(plan, p.body, Bot.BOT_EYE, to, k), "%s: %s (%s) had a clear line to where it arrived" % [tag, p.id, p.status])
				heard = heard or Entity.audibility(plan, s.orderly, p.body, Bot.BOT_EYE).gain > 0.0
				if p.id == near:
					near_cell = walk_cell(s, p.body)
			_fail(t, tl, heard, "%s: nobody could hear it arrive" % tag)
			# Where it arrived.
			var tc := Move.cell_of(plan, to)
			var bar := o_barred(plan, s.car, tc, hides)
			_fail(t, tl, bar == "", "%s: arrived on %s" % [tag, bar])
			if not _fail(t, tl, near_cell != null, "%s: went to %s, who is not on the floor" % [tag, near]):
				continue
			var cs := float(plan.cell_size)
			var dn := Floor.distances_from(plan, near_cell)[Floor.pos_index(plan, tc)]
			_fail(t, tl, dn >= 0 and dn * cs >= O_NEAR_MIN - EPS and dn * cs <= O_NEAR_MAX + EPS, "%s: %.0f m by walking from %s" % [tag, dn * cs, near])
			for p in s.players:
				if p.id == near or (p.status != &"ok" and p.status != &"down"):
					continue
				var d := Floor.distances_from(plan, walk_cell(s, p.body))[Floor.pos_index(plan, tc)]
				_fail(t, tl, d < 0 or d * cs >= O_NEAR_MIN - EPS, "%s: %.0f m by walking from %s" % [tag, d * cs, p.id])
		# No recording on the relocation tick or for 3 s after.
		if s.t <= quiet_until + EPS:
			tl.quiet_ticks += 1
			var reach := false
			for m in s.crew.members:
				_fail(t, tl, m.instrument.needle != &"recording", "%s t %.2f: %s recording %.2f s after an arrival" % [seed, s.t, m.id, s.t - (quiet_until - O_STAND)])
				if m.instrument.raised and m.body != null and M.hypot3(m.body.x - s.orderly.body.x, m.body.y - s.orderly.body.y, m.body.z - s.orderly.body.z) <= O_RECORD_RANGE:
					reach = true
			if reach:
				tl.exposed += 1
		if s.phase == &"ended":
			break
	return sig

func test_bot_runs_lose_track_of_it_fairly(t: T) -> void:
	var tl := Tally.new()
	var n := 6 if t.quick else 40
	# Seconds of play a floor: longer on the few quick floors, so both sets see enough relocations.
	var secs := 120.0 if t.quick else 75.0
	var sigs := {}
	for place in PLACES:
		for i in n:
			sigs["%s-%d" % [place, i]] = _bot_run(t, tl, place, i, secs)
	t.eq(tl.failures, 0, "rule failures")
	# The same seeds and inputs, the same relocations.
	var again := 0
	for place in PLACES:
		for i in mini(n, 3):
			var key := "%s-%d" % [place, i]
			var tl2 := Tally.new()
			var sig := _bot_run(t, tl2, place, i, secs)
			again += sig.size()
			t.check(str(sig) == str(sigs[key]), "%s: run again, the relocations differ: %s then %s" % [key, str(sigs[key]), str(sig)])
	t.check(tl.relocations >= (12 if t.quick else 60), "not vacuous: relocations %d" % tl.relocations)
	t.check(again > 0, "not vacuous: relocations compared on the reruns %d" % again)
	t.check(tl.exposed > (5 if t.quick else 40), "not vacuous: ticks within 3 s of an arrival with a raised instrument in reach %d" % tl.exposed)
	var closest := INF
	for g in tl.gaps:
		closest = minf(closest, g)
	t.note("%d floors, %d ticks: %d relocations (%s), %d catches; %d quiet ticks after arrivals (%d with an instrument up in reach); closest two %.2f s apart; %d hides on these floors; %d relocations rerun the same" % [
		tl.runs, tl.ticks, tl.relocations, str(tl.by_why), tl.catches, tl.quiet_ticks, tl.exposed, closest, tl.hides, again])

# ---------------------------------------------------------------------------------------------
# 2. The Stillness trigger.

## A floor with the resident hunting at a spot out of the player's sight, `far` m or more by walking from them;
## the player stands facing away. [state, the resident's spot] or [].
func _far_stage(seed: String, far: float) -> Array:
	var s := Run.with_relocation(Run.create_run(seed, ["p"]))
	var plan := s.plan
	var cs := float(plan.cell_size)
	var cells := Downs.cells_from(plan, 3)
	if cells.is_empty():
		return []
	var pb := Move.body_at_cell(plan, cells[0])
	var dist := Floor.distances_from(plan, cells[0])
	var k := Entity.kind_of(s.orderly)
	var spot: Move.Body = null
	for i in dist.size():
		if dist[i] < 0 or dist[i] * cs < far:
			continue
		var c := Floor.pos_from_index(plan, i)
		var b := Move.body_at_cell(plan, c)
		if not o_line(plan, pb, 1.65, b, k):
			spot = b
			break
	if spot == null:
		return []
	s = s.copy()
	s.phase = &"away"
	s.call = null
	s.blink = null
	s.lure = false
	var np := s.players[0].copy()
	np.body = pb
	np.aboard = false
	var one: Array[Run.RunPlayer] = [np]
	s.players = one
	var o := s.orderly.copy()
	o.body = spot
	o.mode = &"hunting"
	o.replan_in = 0.0
	o.target_id = "p"
	s.orderly = o
	return [s, spot]

## Steps the stage `secs` seconds, the player facing away from it (or at it: `look`); the host time of the first
## relocation, or -1.
func _far_run(s0: Run.RunState, secs: float, look: bool = false) -> float:
	var s := s0
	var pb := s.players[0].body
	for _n in roundi(secs / DT):
		var ob := s.orderly.body
		var yaw := Entity.yaw_toward(ob.x - pb.x, ob.z - pb.z) + (0.0 if look else PI)
		var ins: Array[Run.PlayerInput] = [Run.PlayerInput.make("p", pb, 1.65, yaw, 0.0, 90.0, 70.0)]
		var r := Run.step_run(s, ins, DT)
		s = r.state
		if not of_type(r.events, "relocated").is_empty():
			return s.t
	return -1.0

func test_stillness_leaves_when_long_unwatched_and_far(t: T) -> void:
	var staged := 0
	var left := 0
	for i in 30:
		var st := _far_stage("reloc-far-%d" % i, 46.0)
		if st.is_empty():
			continue
		staged += 1
		var s: Run.RunState = st[0]
		# Unwatched for 11 s already: the 12 s pass a second in, then a second out of view, and it is gone.
		var o := s.orderly.copy()
		o.unwatched_for = O_UNWATCHED - 1.0
		var ready := s.copy()
		ready.orderly = o
		var at := _far_run(ready, 4.0)
		if t.check(at > 0.0, "seed %d: never left, unwatched past 12 s and far from its target" % i):
			left += 1
			t.check(at >= ready.t + 1.0 + 1.0 - DT - EPS, "seed %d: left %.2f s in, before 12 s unwatched and 1 s out of view" % [i, at - ready.t])
		# Not before 12 s: just woken, in four seconds it does not go.
		t.check(_far_run(s, 4.0) < 0.0, "seed %d: left with no watcher for only a few seconds" % i)
		# Not while the lift boards, nor in a blink's warning.
		var boarding := ready.copy()
		boarding.phase = &"boarding"
		boarding.bell_left = 60.0
		boarding.hold_left = 15.0
		t.check(_far_run(boarding, 4.0) < 0.0, "seed %d: left while the lift was boarding" % i)
		var blink := Run.BlinkState.new()
		blink.at = ready.t + 100.0
		blink.len = 1.0
		blink.warn = 1.0
		blink.announced = true
		var warned := ready.copy()
		warned.phase = &"coming"
		warned.blink = blink
		t.check(not Run.relocation_free(warned), "seed %d: free to leave in a blink's warning" % i)
		# Not off: the same run without the rule never relocates.
		var off := ready.copy()
		off.relocation = false
		t.check(_far_run(off, 4.0) < 0.0, "seed %d: relocated with the rule off" % i)
		if staged >= (4 if t.quick else 12):
			break
	t.check(staged >= 3, "staged floors %d" % staged)
	t.note("%d floors staged: it left in %d" % [staged, left])

func test_never_with_a_watcher(t: T) -> void:
	var staged := 0
	for i in 30:
		var st := _far_stage("reloc-watch-%d" % i, 30.0)
		if st.is_empty():
			continue
		var s: Run.RunState = st[0]
		var o := s.orderly.copy()
		o.reloc_wish = true
		s = s.copy()
		s.orderly = o
		# Its wish is up, but a player stands where they see it and watches it: it never goes.
		var plan := s.plan
		var spot: Move.Body = st[1]
		var watcher: Move.Body = null
		for d: float in [6.0, 8.0, 4.0]:
			for j in 8:
				var c := Downs.spot_from(plan, spot, d, j)
				var v := Entity.PlayerView.make("p", c, 1.65, Entity.yaw_toward(spot.x - c.x, spot.z - c.z), 0.0, 90.0, 70.0, true)
				var vs: Array[Entity.PlayerView] = [v]
				if flat(c, spot) > 3.0 and Entity.seen_by(plan, spot, vs) != null:
					watcher = c
					break
			if watcher != null:
				break
		if watcher == null:
			continue
		staged += 1
		var np := s.players[0].copy()
		np.body = watcher
		var one: Array[Run.RunPlayer] = [np]
		s.players = one
		t.check(_far_run(s, 6.0, true) < 0.0, "seed %d: relocated while watched" % i)
		if staged >= (3 if t.quick else 10):
			break
	t.check(staged >= 3, "staged floors %d" % staged)

# ---------------------------------------------------------------------------------------------
# 4. Over the network.

class NBot:
	var id: String
	var index: int
	var client: Client
	var offset: float
	var next_frame: float
	var body: Move.Body = null
	var bot: Bot.Bot = null

class NSess:
	var net: Transport.MemoryNetwork
	var host: Host
	var rules: HostRules
	var bots: Array[NBot] = []
	var g := 0.0
	var rng: Rng
	var plan: Floor.FloorPlan
	var name := ""
	## Host tick -> [t, x, z, level, relocations, depth], and the ticks a relocation happened on.
	var poses := {}
	var last_tick := -1
	var relocs: Array[int] = []
	var frames := 0
	var straddles := 0
	var short := 0
	var failures := 0

	func _init(seed: String, place: StringName) -> void:
		name = seed
		rng = Rng.make_rng("%s:session" % seed)
		net = Transport.MemoryNetwork.new("%s:net" % seed)
		var ht := net.connect_peer("host")
		rules = HostRules.new(true, 1, [place], false, false, true, true, true)
		var ids: Array[String] = ["p0", "p1", "p2"]
		host = Host.new(ht, seed, ids, 0.0, Callable(rules, "prepare"), Callable(rules, "step"))
		plan = host.state.plan
		for i in ids.size():
			var n := Harness.lossy()
			var tr := net.connect_peer(ids[i])
			for pair: Array in [["host", ids[i]], [ids[i], "host"]]:
				net.set_link(pair[0], pair[1], Transport.LinkConfig.make(0.03 + rng.next() * (n.delay_max - 0.03), n.jitter, n.loss, n.reorder, n.reorder_delay, n.duplicate))
			var b := NBot.new()
			b.id = ids[i]
			b.index = i
			b.offset = (rng.next() - 0.5) * 200.0
			b.next_frame = rng.next() * 0.05
			b.client = Client.new(tr, "host", ids[i], b.offset)
			bots.append(b)

func _nfail(s: NSess, t: T, ok: bool, msg: String) -> void:
	if not ok:
		s.failures += 1
		if s.failures <= 12:
			t.check(false, msg)

## Every host tick since the last look: its pose and relocation count.
func _record(s: NSess) -> void:
	for k in range(s.last_tick + 1, s.host.tick + 1):
		var st := s.host.state_at(k)
		if st == null:
			continue
		var o := st.orderly
		s.poses[k] = [st.t, o.body.x, o.body.z, o.body.level, o.relocations, st.depth]
		var p: Variant = s.poses.get(k - 1)
		if p != null and int(p[5]) == st.depth and int(p[4]) != o.relocations:
			s.relocs.append(k)
	s.last_tick = s.host.tick

## The test's hand on the host, between ticks: the resident hunts from the start, and every 20 s it wants to leave
## (its Stillness trigger's dormant end) so that relocations come often; where and when is still the rules'.
func _nudge(s: NSess) -> void:
	var st := s.host.state
	var o := st.orderly
	if st.phase == &"riding" or st.phase == &"ended":
		return
	if o.mode == &"waiting" and st.phase == &"away":
		o = o.copy()
		o.mode = &"hunting"
		o.replan_in = 0.0
	elif o.mode == &"hunting" and not o.reloc_wish and o.stand_left <= 0.0 and st.t - o.arrived_at >= O_REST:
		o = o.copy()
		o.reloc_wish = true
	if o != st.orderly:
		var ns := st.copy()
		ns.orderly = o
		s.host.state = ns

func _nframe(s: NSess, t: T, b: NBot) -> void:
	var c := b.client
	var lf := Client.LocalFrame.new()
	lf.eye = Bot.BOT_EYE
	lf.h_fov_deg = Bot.BOT_HFOV_DEG
	lf.v_fov_deg = Bot.BOT_VFOV_DEG
	lf.body = b.body if b.body != null else Move.Body.make(0.0, 0.0, 0, 0.0)
	if c.seed != null and c.latest != null and b.body != null and int(c.latest["depth"]) == c.local_depth:
		var car := Session.car_for(s.plan)
		var phase := str(c.latest["phase"])
		var status := "ok"
		for p: Dictionary in c.latest["players"]:
			if p["id"] == b.id:
				status = str(p["status"])
		if b.bot == null:
			if phase != "arriving" and (Run.in_car(car, b.body) or Run.car_local(car, b.body.x, b.body.z)[0] > -1.4):
				b.body = DayNet.walk_toward(s.plan, phase, car, b.body, Run.car_body(car, -1.6, -0.6 + 0.6 * b.index))
			elif phase != "arriving" and Floor.is_walkable(s.plan, Move.cell_of(s.plan, b.body).level, Move.cell_of(s.plan, b.body).x, Move.cell_of(s.plan, b.body).y):
				b.bot = Bot.create_bot(s.plan, b.id, "%s:%s" % [s.name, b.id], 0.5, false, Move.cell_of(s.plan, b.body))
				b.bot.body = b.body
		elif status == "ok":
			var o: Dictionary = c.latest["orderly"]
			Bot.step_bot(s.plan, b.bot, 0.05, Move.Body.make(float(o["x"]), float(o["z"]), int(o["level"]), float(o["y"])))
			b.body = b.bot.body
		lf.body = b.body
		if b.bot != null:
			lf.yaw = b.bot.yaw
			lf.pitch = b.bot.pitch
			lf.gait = String(b.bot.move_gait)
	var f := c.frame(s.g + b.offset, lf)
	if f.placed != null:
		b.body = f.placed
		if b.bot != null:
			b.bot.body = f.placed
			b.bot.walk = null
	if f.orderly == null or f.render_time < 0.0:
		return
	s.frames += 1
	var rt := f.render_time
	var d: Dictionary = f.orderly
	for k in s.relocs:
		var po: Array = s.poses[k - 1]
		var pn: Array = s.poses[k]
		if rt <= float(po[0]) + EPS or rt >= float(pn[0]) - EPS or int(pn[5]) != f.depth:
			continue
		var gap := M.hypot2(float(pn[1]) - float(po[1]), float(pn[2]) - float(po[2]))
		if gap < 4.0:
			s.short += 1
			continue
		s.straddles += 1
		var to_new := M.hypot2(float(d["x"]) - float(pn[1]), float(d["z"]) - float(pn[2]))
		var to_old := M.hypot2(float(d["x"]) - float(po[1]), float(d["z"]) - float(po[2]))
		var at_new := to_new <= 0.03 and int(d["level"]) == int(pn[3])
		var at_old := to_old <= 0.3 and int(d["level"]) == int(po[3])
		_nfail(s, t, at_new or at_old, "%s %s at %.2f: drawn %.2f m from where it left and %.2f m from where it arrived (%.1f m apart): between the two" % [s.name, b.id, rt, to_old, to_new, gap])

func _nplay(s: NSess, t: T, secs: float) -> void:
	var end := s.g + secs
	while s.g < end:
		s.g += 0.025
		s.net.now = s.g
		_nudge(s)
		s.host.update(s.g)
		_record(s)
		for b in s.bots:
			b.client.receive(s.g + b.offset)
		for b in s.bots:
			while b.next_frame <= s.g + 1e-9:
				b.next_frame += 0.05
				_nframe(s, t, b)

func test_a_client_never_draws_it_between_the_two_poses(t: T) -> void:
	var sessions := 1 if t.quick else 3
	var frames := 0
	var straddles := 0
	var relocs := 0
	var short := 0
	var failures := 0
	for place in PLACES:
		for i in sessions:
			var s := NSess.new("reloc-net-%s-%d" % [place, i], place)
			for b in s.bots:
				b.body = Downs.player(s.host.state, b.id).body
			_nplay(s, t, 80.0 if t.quick else 110.0)
			frames += s.frames
			straddles += s.straddles
			relocs += s.relocs.size()
			short += s.short
			failures += s.failures
	t.eq(failures, 0, "frames drawn between the two poses")
	t.check(relocs >= (2 if t.quick else 8), "not vacuous: relocations on the host %d" % relocs)
	t.check(straddles >= (3 if t.quick else 12), "not vacuous: frames drawn across a relocation %d" % straddles)
	t.note("%d sessions: %d relocations on the host; %d client frames, %d of them drawn across a relocation (%d more across one shorter than 4 m)" % [
		sessions * PLACES.size(), relocs, frames, straddles, short])
