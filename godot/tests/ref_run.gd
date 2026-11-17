# The run (sim/run.gd): the call plans and dark schedules (blinks and blackout) of 200 seeded waits,
# the depth pay, a whole scripted run from the first floor to the bank (every tick's full state and
# every event in order), the vote / hold / left-behind / wipe / repeated-call scenes, and 24 whole
# waits for the car with wait bots (tests/waits.gd), against tests/golden/run.json, exactly (first
# proved equal to src/sim/run.ts, pay within 1e-9; the historical dumpRun).
extends RefCounted

const T = preload("res://tests/t.gd")
const Snap = preload("res://tests/snap.gd")
const Golden = preload("res://tests/golden.gd")
const Trace = preload("res://tests/trace.gd")
const Waits = preload("res://tests/waits.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Entity = preload("res://sim/entity.gd")
const Instr = preload("res://sim/instrument.gd")
const TapeLib = preload("res://sim/tape.gd")
const Run = preload("res://sim/run.gd")
const Bot = preload("res://sim/bot.gd")
const Rng = preload("res://sim/rng.gd")
const M = preload("res://sim/jsmath.gd")

const DT := 0.05

func test_call_plans_and_depth_pay(t: T) -> void:
	var got: Array = []
	for i in 200:
		var prev: Variant = null if i % 5 == 0 else 6 + (i % 7)
		var depth := 1 + (i % 4)
		var plan := Run.call_plan("sched-%d" % i, i % 3, -1 if prev == null else int(prev), depth)
		got.append({"seed": "sched-%d" % i, "index": i % 3, "prev": prev, "depth": depth, "plan": Snap.call_plan(plan)})
	var d := t.expect("run.json", "plans", got, "call plans")
	var blinks := 0
	var false_stops := 0
	for g: Dictionary in got:
		blinks += (g["plan"]["darks"] as Array).size()
		if g["plan"]["falseStop"]:
			false_stops += 1
	var mult: Array = []
	for depth in 12:
		mult.append(Run.depth_multiplier(depth))
	var md := t.expect("run.json", "mult", mult, "depthMultiplier")
	t.note("200 call plans (%d dark stretches, %d false stops): %s" % [blinks, false_stops, d.summary()])
	t.note("depth pay 0..11: %s" % md.summary())

# ---------------------------------------------------------------------------------------------
# The scripted run (run.test.ts), as a closed loop.

class Actor:
	var id: String
	var body: Move.Body
	var yaw := 0.0
	var pitch := 0.0
	var raised: Variant = null
	var call := false
	var hold := false

	static func make(id_: String, body_: Move.Body) -> Actor:
		var a := Actor.new()
		a.id = id_
		a.body = body_
		return a

static func input_of(a: Actor) -> Run.PlayerInput:
	var p := Run.PlayerInput.make(a.id, a.body, Bot.BOT_EYE, a.yaw, a.pitch, Bot.BOT_HFOV_DEG, Bot.BOT_VFOV_DEG)
	p.call = a.call
	p.hold_doors = a.hold
	p.raised = a.raised
	return p

static func inputs_of(actors: Array[Actor]) -> Array[Run.PlayerInput]:
	var out: Array[Run.PlayerInput] = []
	for a in actors:
		out.append(input_of(a))
	return out

static func walk_actor(st: Run.RunState, a: Actor, waypoints: Array[Move.Body], speed: float) -> bool:
	var budget := speed * DT
	while budget > 1e-9 and not waypoints.is_empty():
		var w := waypoints[0]
		var d := M.hypot2(w.x - a.body.x, w.z - a.body.z)
		if d < 0.02:
			waypoints.pop_front()
			continue
		var step := minf(budget, d)
		var before := a.body
		a.body = Run.move_in_run(st, a.body, ((w.x - a.body.x) / d) * step, ((w.z - a.body.z) / d) * step, Bot.BOT_RADIUS)
		budget -= step
		if M.hypot2(a.body.x - before.x, a.body.z - before.z) < 1e-6:
			break
	return waypoints.is_empty()

static func out_of_car(st: Run.RunState, u: float, v: float) -> Array[Move.Body]:
	return [Run.car_body(st.car, 0.45, 0.0), Run.car_body(st.car, -0.6, 0.0), Run.car_body(st.car, u, v)]

static func look_at(a: Actor, target: Move.Body) -> void:
	a.yaw = Entity.yaw_toward(target.x - a.body.x, target.z - a.body.z)
	var d := M.hypot2(target.x - a.body.x, target.z - a.body.z)
	a.pitch = M.atan2_js(target.y + 1.7 - (a.body.y + Bot.BOT_EYE), maxf(d, 0.1))

static func look_away(a: Actor, target: Move.Body) -> void:
	a.yaw = Entity.yaw_toward(a.body.x - target.x, a.body.z - target.z)
	a.pitch = 0.0

static func has(events: Array[Dictionary], type: String) -> bool:
	for e in events:
		if e["type"] == type:
			return true
	return false

## Drives a run: one tick, moving actors the run placed, recording into the trace.
class Driver:
	var st: Run.RunState
	var actors: Array[Actor] = []
	var tr: Trace

	func tick() -> Array[Dictionary]:
		var r := Run.step_run(st, ref_run_inputs(), DT)
		st = r.state
		for e in r.events:
			if e["type"] == "rodeDown":
				var bodies: Dictionary = e["bodies"]
				for a in actors:
					if bodies.has(a.id):
						a.body = bodies[a.id]
			if e["type"] == "doorsClosed":
				var pushed: Dictionary = e["pushedOut"]
				for a in actors:
					if pushed.has(a.id):
						a.body = pushed[a.id]
		tr.tick(Snap.run(st), r.events)
		for a in actors:
			a.call = false
		return r.events

	func ref_run_inputs() -> Array[Run.PlayerInput]:
		var out: Array[Run.PlayerInput] = []
		for a in actors:
			var p := Run.PlayerInput.make(a.id, a.body, Bot.BOT_EYE, a.yaw, a.pitch, Bot.BOT_HFOV_DEG, Bot.BOT_VFOV_DEG)
			p.call = a.call
			p.hold_doors = a.hold
			p.raised = a.raised
			out.append(p)
		return out

	## Ticks until `stop(events)` is true; `each` runs before each tick. False on timing out.
	func until(stop: Callable, max_seconds: float, each: Callable = Callable()) -> bool:
		var k := 0
		while k < max_seconds / 0.05:
			if each.is_valid():
				each.call()
			if stop.call(tick()):
				return true
			k += 1
		push_error("scripted run timed out in %s" % st.phase)
		return false

func _scripted_floor(dr: Driver, bank_at_end: bool) -> void:
	var A := dr.actors[0]
	var B := dr.actors[1]
	A.raised = true
	dr.until(func(ev: Array[Dictionary]) -> bool: return has(ev, "doorsOpened"), 3.0)
	var out_a := out_of_car(dr.st, -1.0, -0.45)
	var out_b := out_of_car(dr.st, -1.0, 0.45)
	var step_out := func() -> void:
		walk_actor(dr.st, A, out_a, 2.5)
		walk_actor(dr.st, B, out_b, 2.5)
	dr.until(func(ev: Array[Dictionary]) -> bool: return has(ev, "carLeft"), 20.0, step_out)
	var state := {"turned": false}
	var reading_closed := func(ev: Array[Dictionary]) -> bool:
		if not state["turned"]:
			return false
		for e in ev:
			if e["type"] == "readingClosed" and e["playerId"] == "A":
				return true
		return false
	var routine := func() -> void:
		var o := dr.st.orderly.body
		if not state["turned"] and minf(M.hypot2(A.body.x - o.x, A.body.z - o.z), M.hypot2(B.body.x - o.x, B.body.z - o.z)) <= 2.0:
			state["turned"] = true
		for a in dr.actors:
			if state["turned"]:
				look_at(a, o)
			else:
				look_away(a, o)
	dr.until(reading_closed, 240.0, routine)
	A.raised = false
	A.call = true
	var crew: Array[Bot.WaitBot] = []
	for k in dr.actors.size():
		var b := Bot.create_wait_bot(dr.st, dr.actors[k].id, k, &"flee")
		b.body = dr.actors[k].body
		b.seat_u = 0.8 + 0.5 * k
		b.seat_v = -0.5 if bank_at_end else 0.5
		crew.append(b)
	var flags := {"first": true}
	var wait := func() -> void:
		var r := dr.st.car.rect
		var waiting := false
		for b in crew:
			if not (b.body.x > r.x0 and b.body.x < r.x1 and b.body.z > r.z0 and b.body.z < r.z1):
				waiting = true
		for k in crew.size():
			var b := crew[k]
			if not flags["first"]:
				Bot.step_wait_bot(dr.st, b, DT)
			var a := dr.actors[k]
			a.body = b.body
			a.yaw = b.yaw
			a.pitch = b.pitch
			a.hold = b.mode == &"aboard" and waiting
		flags["first"] = false
	dr.until(func(ev: Array[Dictionary]) -> bool: return has(ev, "bell"), 80.0 + Run.BOARD_TIME + Run.HOLD_LIMIT, wait)

func test_scripted_run_to_the_bank(t: T) -> void:
	var dr := Driver.new()
	var ids: Array[String] = ["A", "B"]
	dr.st = Run.create_run("script-1", ids)
	dr.actors = [Actor.make("A", dr.st.players[0].body), Actor.make("B", dr.st.players[1].body)]
	dr.tr = Trace.new("scripted-run", 150, t.golden("run.json", "scripted"))
	_scripted_floor(dr, false)
	dr.until(func(ev: Array[Dictionary]) -> bool: return has(ev, "rodeDown"), 10.0)
	_scripted_floor(dr, true)
	var d := dr.tr.finish(t)
	if t.recording:
		Golden.put("run.json", "scripted", dr.tr.to_golden())
	var kinds := PackedStringArray()
	var banked := 0.0
	for e: Array in dr.tr.events:
		var type: String = e[1]["type"]
		if type in ["doorsOpened", "carLeft", "called", "carArrived", "bell", "rodeDown", "banked"]:
			kinds.append(type)
		if type == "banked":
			banked = e[1]["summary"]["total"]
	t.note("%d ticks (%s s of run time), %d events; every tick's state compared, first difference: %s" % [dr.tr.ticks, M.to_fixed(dr.st.t, 0), dr.tr.events.size(), dr.tr.first_difference()])
	t.note("events, snapshots: %s; banked %s (shown %d)" % [d.summary(), M.to_fixed(banked, 2), int(floor(banked))])
	t.note("order: " + " ".join(kinds))

# ---------------------------------------------------------------------------------------------
# Scenes.

static func boarding_run(seed: String, ids: Array[String]) -> Run.RunState:
	var st := Run.create_run(seed, ids)
	var s := st.copy()
	s.phase = &"boarding"
	s.bell_left = Run.BOARD_TIME
	s.hold_left = Run.HOLD_LIMIT
	s.players = []
	for i in st.players.size():
		var p := st.players[i].copy()
		p.body = Run.car_body(st.car, -0.8, 0.5 if i % 2 != 0 else -0.5)
		p.aboard = false
		s.players.append(p)
	var o := st.orderly.copy()
	o.mode = &"dormant"
	o.dormant_left = 1e9
	s.orderly = o
	return s

static func bank_spot(st: Run.RunState, k: int = 0) -> Move.Body:
	return Run.car_body(st.car, 0.8 + 0.5 * (k % 2), -0.5)

static func down_spot(st: Run.RunState, k: int = 0) -> Move.Body:
	return Run.car_body(st.car, 0.8 + 0.5 * (k % 2), 0.5)

func _scene(name: String, want: Variant, st0: Run.RunState, actors: Array[Actor], seconds: float, each: Callable, stop_on: String) -> Trace:
	var st := st0
	var tr := Trace.new(name, 100, want)
	var k := 0
	while k < seconds / DT:
		if each.is_valid():
			each.call(st, k)
		var r := Run.step_run(st, inputs_of(actors), DT)
		st = r.state
		for e in r.events:
			if e["type"] == "rodeDown":
				var bodies: Dictionary = e["bodies"]
				for a in actors:
					if bodies.has(a.id):
						a.body = bodies[a.id]
		tr.tick(Snap.run(st), r.events)
		for a in actors:
			a.call = false
		if has(r.events, stop_on):
			break
		k += 1
	return tr

static func _tape_with(id: String, owner: String, values: Array[float]) -> TapeLib.Tape:
	var t := TapeLib.empty_tape(id, owner)
	for i in values.size():
		var r := TapeLib.Reading.new()
		r.id = "%s-r%d" % [id, i]
		r.player_id = owner
		r.entity_id = "test"
		r.trait_name = &"stillness"
		r.value = values[i]
		r.duration = 2.0
		r.peak_rate = 50.0
		r.closed_at = 0.0
		t = TapeLib.add_reading(t, r)
	return t

func test_scenes(t: T) -> void:
	var wants: Variant = t.golden("run.json", "scenes")
	var traces: Array[Trace] = []
	var none := Callable()
	var votes: Array = [
		["vote-1", [[&"bank", 0], [&"bank", 1], [&"down", 0]]],
		["vote-tie-2", [[&"bank", 0], [&"down", 0]]],
		["vote-tie-4", [[&"bank", 0], [&"bank", 1], [&"down", 0], [&"down", 1]]],
		["vote-down-3", [[&"down", 0], [&"down", 1], [&"bank", 0]]],
		["vote-empty", [[&"outside", 0]]],
	]
	for v: Array in votes:
		var spots: Array = v[1]
		var ids: Array[String] = []
		for k in spots.size():
			ids.append("v%d" % k)
		var st := boarding_run(v[0], ids)
		var actors: Array[Actor] = []
		for k in spots.size():
			var spot: Array = spots[k]
			var body: Move.Body
			if spot[0] == &"bank":
				body = bank_spot(st, spot[1])
			elif spot[0] == &"down":
				body = down_spot(st, spot[1])
			else:
				body = Run.car_body(st.car, -1.0, 0.0)
			actors.append(Actor.make(ids[k], body))
		traces.append(_scene(v[0], Golden.item(wants, traces.size()), st, actors, Run.BOARD_TIME + 8.0, none, "rodeDown"))
	if true:
		var ids: Array[String] = ["v0", "v1"]
		var st := boarding_run("vote-switch", ids)
		var a := Actor.make("v0", bank_spot(st, 0))
		var b := Actor.make("v1", down_spot(st, 0))
		var switch := func(s: Run.RunState, _k: int) -> void:
			if s.t >= Run.BOARD_TIME - 2.0:
				b.body = bank_spot(s, 1)
		traces.append(_scene("vote-switch", Golden.item(wants, traces.size()), st, [a, b], Run.BOARD_TIME + 1.0, switch, "bell"))
	if true:
		var ids: Array[String] = ["in", "out"]
		var st := boarding_run("hold-1", ids)
		var inside := Actor.make("in", down_spot(st))
		var outside := Actor.make("out", Run.car_body(st.car, -1.0, 0.0))
		outside.hold = true
		var hold := func(s: Run.RunState, _k: int) -> void:
			inside.hold = s.t >= 5.0 and s.t < 12.0
		traces.append(_scene("hold-1", Golden.item(wants, traces.size()), st, [inside, outside], 60.0, hold, "bell"))
	if true:
		var ids: Array[String] = ["in", "late"]
		var st := boarding_run("hold-2", ids)
		var inside := Actor.make("in", down_spot(st))
		inside.hold = true
		var late := Actor.make("late", Run.car_body(st.car, -1.2, 0.3))
		var route: Array[Move.Body] = [Run.car_body(st.car, -0.6, 0.0), Run.car_body(st.car, 0.45, 0.0), Run.car_body(st.car, 1.3, 0.5)]
		var straggle := func(s: Run.RunState, _k: int) -> void:
			if s.t >= 28.0:
				walk_actor(s, late, route, 2.5)
		traces.append(_scene("hold-2", Golden.item(wants, traces.size()), st, [inside, late], 60.0, straggle, "rodeDown"))
	if true:
		var ids: Array[String] = ["aboard", "behind", "caught"]
		var st := boarding_run("behind-1", ids)
		var s := st.copy()
		s.players = []
		for p in st.players:
			var np := p.copy()
			if p.id == "caught":
				np.status = &"caught"
			s.players.append(np)
		var c := st.crew.copy()
		c.members = []
		for m in st.crew.members:
			var nm := m.copy()
			if m.id == "aboard":
				nm.tape = _tape_with(m.tape.id, m.id, [30.0, 12.0])
			elif m.id == "behind":
				nm.tape = _tape_with(m.tape.id, m.id, [50.0])
				nm.carrying = [_tape_with("tape-x", "someone", [20.0])]
			c.members.append(nm)
		c.floor = [Instr.FloorTape.make(_tape_with("tape-floor", "caught", [40.0]), Run.car_body(st.car, -3.0, 0.0))]
		s.crew = c
		var a := Actor.make("aboard", down_spot(s))
		var b := Actor.make("behind", Run.car_body(s.car, -1.5, 0.0))
		b.raised = true
		var cc := Actor.make("caught", Run.car_body(s.car, -3.0, 0.0))
		traces.append(_scene("behind-1", Golden.item(wants, traces.size()), s, [a, b, cc], Run.BOARD_TIME + 12.0, none, "doorsOpened"))
	if true:
		var ids: Array[String] = ["solo"]
		var st := Run.create_run("wipe-1", ids)
		var spot := Run.car_body(st.car, -1.0, 0.0)
		var dist := Floor.distances_from(st.plan, st.plan.landing)
		var cands: Array = []
		for i in dist.size():
			var d := dist[i]
			if d < 3 or d > 8:
				continue
			var p := Floor.pos_from_index(st.plan, i)
			if p.level != 0 or not Floor.is_walkable(st.plan, 0, p.x, p.y) or Floor.cell_at(st.plan, 0, p.x, p.y) == Floor.STAIR:
				continue
			cands.append(p)
		var start: Floor.Pos = Rng.make_rng("wipe").fork("o").pick(cands)
		var s := st.copy()
		s.phase = &"away"
		s.players = []
		for p in st.players:
			var np := p.copy()
			np.body = spot
			np.aboard = false
			s.players.append(np)
		var o := Entity.create_orderly(st.plan)
		o.body = Move.body_at_cell(st.plan, start)
		o.mode = &"hunting"
		s.orderly = o
		var solo := Actor.make("solo", spot)
		var away := func(ss: Run.RunState, _k: int) -> void:
			look_away(solo, ss.orderly.body)
		traces.append(_scene("wipe-1", Golden.item(wants, traces.size()), s, [solo], 120.0, away, "wiped"))
	for r in 2:
		var ids: Array[String] = ["caller"]
		var st := Run.create_run("wait-%d" % r, ids)
		var spot := Run.car_body(st.car, -1.0, 0.0)
		var s := st.copy()
		s.phase = &"away"
		s.players = []
		for p in st.players:
			var np := p.copy()
			np.body = spot
			np.aboard = false
			s.players.append(np)
		var o := st.orderly.copy()
		o.mode = &"dormant"
		o.dormant_left = 1e9
		s.orderly = o
		var caller := Actor.make("caller", spot)
		var count := {"calls": 0}
		var press := func(ss: Run.RunState, _k: int) -> void:
			if ss.phase == &"away" and count["calls"] < 3:
				caller.call = true
				count["calls"] += 1
		traces.append(_scene("calls-%d" % r, Golden.item(wants, traces.size()), s, [caller], 200.0, press, "never"))
	var total := Trace.finish_all(t, "run.json", "scenes", traces, wants)
	var ticks := 0
	var firsts := PackedStringArray()
	for tr in traces:
		ticks += tr.ticks
		firsts.append("%s: %s" % [tr.name, tr.first_difference()])
	t.note("%d scenes (votes and ties, switching sides, holds, left behind, a wipe, repeated calls with false stops), %d ticks: %s" % [traces.size(), ticks, total.summary()])
	t.note("first differing tick: " + ", ".join(firsts))

func test_whole_waits_with_wait_bots(t: T) -> void:
	var waits: Variant = t.golden("run.json", "waits")
	var total := Snap.Diff.new()
	var n := 0
	var cases: Array = []
	for style: String in ["stay", "flee"]:
		for depth: int in [1, 2, 3]:
			for i: int in [0, 1, 2, 5]:
				cases.append([style, depth, i])
	var out: Array = []
	for wi in cases.size():
		# The quick set: every sixth wait (stay and flee, each depth).
		if t.quick and wi % 6 != 0:
			continue
		var c: Array = cases[wi]
		var r := Waits.run_wait(StringName(c[0]), c[1], c[2])
		var got := {
			"style": c[0], "depth": c[1], "i": c[2], "caught": r.caught, "boarded": r.boarded,
			"caughtInBlackout": r.caught_in_blackout, "caughtAfter": r.caught_after, "darks": Array(r.darks), "closest": r.closest,
			"farthest": r.farthest, "boardedAfter": r.boarded_after, "events": Snap.events(r.events),
		}
		out.append(got)
		n += 1
		if t.recording:
			continue
		var d := Snap.compare(got, Golden.item(waits, wi), "%s d%d #%d" % c)
		total.add(d)
		t.check(d.ok(), "wait %s d%d #%d differs from the golden: %s" % [c[0], c[1], c[2], d.summary()])
	if t.recording:
		Golden.put("run.json", "waits", out)
	elif not t.quick:
		t.eq(cases.size(), (waits as Array).size() if waits is Array else -1, "waits in the golden")
	t.note("%d whole waits (stay and flee, depths 1-3), every event: %s" % [n, total.summary()])
