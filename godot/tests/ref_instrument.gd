# Stamina, the instrument and tapes (sim/stamina.gd, instrument.gd, tape.gd): stamina traces for
# seeded inputs, the rate curve, the repeat factors, and three scripted scenes tick by tick (the
# recording routine, tapes dropped / picked up / carried / lost, staring earns nothing), with the pay
# the game shows (whole units, and two decimals), against tests/golden/instrument.json, pay included,
# exactly. (First proved equal to src/sim: everything but the pay exactly, the pay within 1e-9, as
# JavaScript's pow differs from fdlibm's in the last bit; the historical dumpInstrument.)
extends RefCounted

const T = preload("res://tests/t.gd")
const Snap = preload("res://tests/snap.gd")
const Golden = preload("res://tests/golden.gd")
const Trace = preload("res://tests/trace.gd")
const Plans = preload("res://tests/plans.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Entity = preload("res://sim/entity.gd")
const Instr = preload("res://sim/instrument.gd")
const TapeLib = preload("res://sim/tape.gd")
const Stamina = preload("res://sim/stamina.gd")
const Rng = preload("res://sim/rng.gd")
const Bot = preload("res://sim/bot.gd")
const M = preload("res://sim/jsmath.gd")

const DT := 0.05

static func shown(v: float) -> Array:
	return [int(floor(v)), M.to_fixed(v, 2)]

func test_stamina(t: T) -> void:
	var r := Rng.make_rng("stamina")
	var traces: Array = []
	for n in 6:
		var st: Stamina.Stamina
		if n == 0:
			st = Stamina.fresh_stamina()
		else:
			var level := r.next()
			st = Stamina.Stamina.make(level, r.chance(0.5))
		var rows: Array = []
		for i in 400:
			var sprint := r.chance(0.6)
			var creep := r.chance(0.15)
			var moving := r.chance(0.9)
			var cap := 2.2 if r.chance(0.2) else INF
			var gait := Stamina.gait_for(st, sprint, creep, moving, cap)
			var ground := 0.0 if r.chance(0.15) else Stamina.speed_for(gait, cap) * (0.5 + r.next() * 0.5)
			st = Stamina.step_stamina(st, gait, ground, 1.0 / 20.0)
			rows.append([String(gait), ground, st.level, st.winded, Stamina.exertion(st)])
		traces.append(rows)
	var d := t.expect("instrument.json", "stamina", {"traces": traces, "flee": Stamina.sustained_flee_speed()}, "stamina")
	t.note("6 traces x 400 steps: %s" % d.summary())

func test_rate_and_repeat(t: T) -> void:
	var rates: Array = []
	for i in 201:
		var d := i * 0.05
		rates.append([d, Instr.rate_at(d)])
	var rd := t.expect("instrument.json", "rates", rates, "rateAt")
	var rep: Array = []
	for c: int in [0, 1, 2, 3, 7]:
		rep.append(Instr.repeat_factor(c))
	t.expect("instrument.json", "repeat", rep, "repeatFactor")
	t.note("rateAt at 201 distances: %s" % rd.summary())

class Corridor:
	var p: Floor.FloorPlan
	var o: Move.Body
	var dx: int
	var dz: int
	var level: int
	var toward: float
	var away: float

	func at(d: float) -> Move.Body:
		var x := o.x + dx * d
		var z := o.z + dz * d
		return Move.Body.make(x, z, level, Move.feet_height(p, level, x, z))

static func corridor(min_cells: int) -> Corridor:
	for i in 300:
		var p := Plans.plan("corridor-%d" % i, 1 + (i % 4))
		var e := p.entity_start
		var s: Floor.Sightline = null
		for l in p.sightlines:
			if l.level == e.level and l.length >= min_cells and ((l.x1 == e.x and l.y1 == e.y) or (l.x2 == e.x and l.y2 == e.y)):
				s = l
				break
		if s == null:
			continue
		var at_start := s.x1 == e.x and s.y1 == e.y
		var c := Corridor.new()
		c.p = p
		c.dx = signi(s.x2 - s.x1) * (1 if at_start else -1)
		c.dz = signi(s.y2 - s.y1) * (1 if at_start else -1)
		c.o = Move.body_at_cell(p, e)
		c.level = e.level
		c.toward = M.atan2_js(c.dx, c.dz)
		c.away = M.atan2_js(-c.dx, -c.dz)
		return c
	return null

static func view(b: Move.Body, yaw: float) -> Array[Entity.PlayerView]:
	return [Entity.PlayerView.make("me", b, Bot.BOT_EYE, yaw, 0.0, Bot.BOT_HFOV_DEG, Bot.BOT_VFOV_DEG, true)]

static func me_player(b: Move.Body) -> Array[Instr.CrewPlayer]:
	return [Instr.CrewPlayer.make("me", b, true)]

static func one_entity(prev: Entity.OrderlyState, next: Entity.OrderlyState, events: Array[Dictionary]) -> Array[Instr.EntityTick]:
	return [Instr.EntityTick.make("orderly", &"stillness", prev, next, events)]

static func crew_of(ids: Array[String]) -> Instr.CrewState:
	return Instr.create_crew(ids)

func test_scenes_and_pay(t: T) -> void:
	var traces: Variant = t.golden("instrument.json", "traces")
	var pay: Array = []
	var results: Array[Trace] = []

	# The routine.
	if true:
		var c := corridor(9)
		var orderly := Entity.create_orderly(c.p)
		var me_ids: Array[String] = ["me"]
		var crew := Instr.set_raised(crew_of(me_ids), "me", true)
		var tr := Trace.new("routine", 10, Golden.item(traces, 0))
		results.append(tr)
		var me := c.at(8.0)
		var stage := 0
		var s := 8.0
		var wait_ticks := 0
		var k := 0
		while k < 3000 and stage < 6:
			var yaw := c.away
			if stage == 1 or stage == 2 or stage == 4:
				yaw = c.toward
			if stage == 2:
				s += 2.2 * DT
				me = c.at(s)
			var before := orderly
			var res := Entity.step_entity(c.p, before, view(me, yaw), DT)
			orderly = res.state
			var out := Instr.step_crew(c.p, crew, me_player(me), one_entity(before, orderly, res.events), DT)
			crew = out.crew
			tr.tick({"orderly": Snap.orderly(orderly), "crew": Snap.crew(crew)}, res.events + out.events)
			var dist := M.hypot2(me.x - orderly.body.x, me.z - orderly.body.z)
			if stage == 0 and dist <= 2.0:
				stage = 1
			elif stage == 1:
				wait_ticks += 1
				if wait_ticks >= 60:
					stage = 2
			elif stage == 2 and dist >= 8.0:
				stage = 3
			elif stage == 3 and dist <= 1.25:
				stage = 4
				wait_ticks = 0
			elif stage == 4:
				wait_ticks += 1
				if wait_ticks >= 60:
					stage = 6
			k += 1
		var tape := Instr.member(crew, "me").tape
		var readings: Array = []
		for r in tape.readings:
			readings.append([r.value] + shown(r.value) + [r.peak_rate, r.duration])
		pay.append({"scene": "routine", "readings": readings, "total": [tape.total] + shown(tape.total)})

	# Tapes.
	if true:
		var p := Plans.plan("tapes", 1)
		var base := Entity.create_orderly(p)
		var ids: Array[String] = ["a", "b", "c", "d"]
		var crew := crew_of(ids)
		for id: String in ["a", "c", "d"]:
			crew = Instr.set_raised(crew, id, true)
		var pos := {"a": Move.Body.make(10, 10, 0, 0), "b": Move.Body.make(11, 10, 0, 0), "c": Move.Body.make(12, 10, 0, 0), "d": Move.Body.make(60, 60, 0, 0)}
		var tr := Trace.new("tapes", 10, Golden.item(traces, 1))
		results.append(tr)
		var ctx := {"e": _ent(base, Move.Body.make(14, 10, 0, 0)), "crew": crew}
		var step := func(move: bool, caught: Array) -> void:
			var prev: Entity.OrderlyState = ctx["e"]
			if move:
				ctx["e"] = _ent(base, Move.Body.make(prev.body.x + 0.05, prev.body.z, 0, 0))
			var events: Array[Dictionary] = []
			for id: String in caught:
				events.append({"type": "caught", "t": 0.0, "playerId": id})
			var players: Array[Instr.CrewPlayer] = []
			for id: String in ["a", "b", "c", "d"]:
				players.append(Instr.CrewPlayer.make(id, pos[id], true))
			var out := Instr.step_crew(p, ctx["crew"], players, one_entity(prev, ctx["e"], events), DT)
			ctx["crew"] = out.crew
			tr.tick(Snap.crew(out.crew), out.events)
		for k in 20:
			step.call(true, [])
		for k in 40:
			step.call(false, [])
		ctx["e"] = _ent(base, Move.Body.make(64, 60, 0, 0))
		for k in 20:
			step.call(true, [])
		for k in 40:
			step.call(false, [])
		step.call(false, ["a"])
		step.call(false, ["c"])
		crew = ctx["crew"]
		var picks: Array = []
		var ta := crew.floor[0].tape.id
		var tc := crew.floor[1].tape.id
		picks.append(String(Instr.pick_up_tape(crew, "d", ta).reason))
		var up := Instr.pick_up_tape(crew, "b", ta)
		picks.append(String(up.reason))
		picks.append(Snap.plain(up.event))
		crew = up.crew
		up = Instr.pick_up_tape(crew, "b", tc)
		picks.append(String(up.reason))
		crew = up.crew
		picks.append(String(Instr.pick_up_tape(crew, "b", ta).reason))
		ctx["crew"] = crew
		step.call(false, ["d"])
		crew = ctx["crew"]
		var dep := Instr.leave_floor(crew)
		var ac: Array[String] = ["a", "c"]
		var dep2 := Instr.leave_floor(crew, ac)
		var players2: Array[Instr.CrewPlayer] = []
		for id: String in ["a", "c", "d"]:
			players2.append(Instr.CrewPlayer.make(id, pos[id], true))
		players2.append(Instr.CrewPlayer.make("b", pos["d"], false))
		var no_entities: Array[Instr.EntityTick] = []
		var out2 := Instr.step_crew(p, crew, players2, no_entities, DT)
		picks.append(String(Instr.pick_up_tape(out2.crew, "b", crew.floor[0].tape.id).reason))
		pay.append({
			"scene": "tapes", "picks": picks, "carried": _ids(dep.carried), "lost": _ids(dep.lost),
			"carriedValue": [dep.carried_value] + shown(dep.carried_value), "lostValue": [dep.lost_value] + shown(dep.lost_value),
			"carried2": _ids(dep2.carried), "tapeValue": TapeLib.tape_value(dep.carried),
		})

	# Staring earns nothing.
	if true:
		var c := corridor(4)
		var orderly := Entity.create_orderly(c.p)
		var me_ids: Array[String] = ["me"]
		var crew := Instr.set_raised(crew_of(me_ids), "me", true)
		var me := c.at(5.0)
		var tr := Trace.new("stare-earns-nothing", 20, Golden.item(traces, 2))
		results.append(tr)
		for k in 600:
			var before := orderly
			var res := Entity.step_entity(c.p, before, view(me, c.toward), DT)
			orderly = res.state
			var out := Instr.step_crew(c.p, crew, me_player(me), one_entity(before, orderly, res.events), DT)
			crew = out.crew
			tr.tick({"orderly": Snap.orderly(orderly), "crew": Snap.crew(crew)}, res.events + out.events)

	var total := Trace.finish_all(t, "instrument.json", "traces", results, traces)
	var ticks := 0
	var firsts := PackedStringArray()
	for tr in results:
		ticks += tr.ticks
		firsts.append("%s: %s" % [tr.name, tr.first_difference()])
	var pd := t.expect("instrument.json", "pay", pay, "pay")
	var tape := TapeLib.empty_tape("t", "o")
	var i := 0
	for v: float in [12.5, 0.1, 0.2, 99.99, 1.0 / 3.0]:
		var r := TapeLib.Reading.new()
		r.id = "r%d" % i
		r.player_id = "o"
		r.entity_id = "e"
		r.trait_name = &"stillness"
		r.value = v
		r.duration = 1.0
		r.peak_rate = 2.0
		r.closed_at = 0.0
		tape = TapeLib.add_reading(tape, r)
		i += 1
	var one: Array[TapeLib.Tape] = [tape]
	t.expect("instrument.json", "tapeOps", {"total": tape.total, "value": TapeLib.tape_value(one), "shown": shown(tape.total)}, "tape sums")
	t.note("3 scenes, %d ticks; every tick's state (pay included) compared; events, snapshots: %s" % [ticks, total.summary()])
	t.note("first differing tick: " + ", ".join(firsts))
	t.note("pay as shown (whole units and two decimals): %s" % pd.summary())

static func _ent(base: Entity.OrderlyState, b: Move.Body) -> Entity.OrderlyState:
	var e := base.copy()
	e.mode = &"hunting"
	e.body = b
	return e

static func _ids(tapes: Array[TapeLib.Tape]) -> Array:
	var out: Array = []
	for tp in tapes:
		out.append(tp.id)
	return out
