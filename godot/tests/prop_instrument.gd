# The recording rule, by an independent oracle (ported from tests/sim/instrument.test.ts; it shares
# nothing with instrument.gd): a reading only grows on a tick where the holder's instrument was
# raised, the holder active, the Orderly moved (or its wind-up advanced), within 9 m. Plus the slip
# prints once, readings close and tapes drop, and greed costs. Counts must equal TypeScript's.
extends RefCounted

const T = preload("res://tests/t.gd")
const Snap = preload("res://tests/snap.gd")
const Plans = preload("res://tests/plans.gd")
const Move = preload("res://sim/move.gd")
const Entity = preload("res://sim/entity.gd")
const Instr = preload("res://sim/instrument.gd")
const Bot = preload("res://sim/bot.gd")
const Rng = preload("res://sim/rng.gd")
const M = preload("res://sim/jsmath.gd")

const DT := 0.05
const RUN_SECONDS := 60.0
const ORACLE_RANGE := 9.0

static func oracle_moved(before: Entity.OrderlyState, after: Entity.OrderlyState, events: Array[Dictionary]) -> bool:
	var b := before.body
	var a := after.body
	if b.x != a.x or b.z != a.z or b.y != a.y or b.level != a.level:
		return true
	var started := before.mode != &"windUp" and after.mode == &"windUp"
	var ran_down := before.mode == &"windUp" and after.mode == &"windUp" and after.wind_up_left < before.wind_up_left
	var completed := false
	if before.mode == &"windUp":
		for e in events:
			if e["type"] == "caught":
				completed = true
	return started or ran_down or completed

static func oracle_distance(p: Move.Body, o: Move.Body) -> float:
	var dx := p.x - o.x
	var dy := p.y - o.y
	var dz := p.z - o.z
	return sqrt(dx * dx + dy * dy + dz * dz)

class BotStat:
	var earned_before := 0.0
	var recorded_all := 0.0
	var caught := false

class RunResult:
	var growth_ticks := 0
	var violations := 0
	var lowered := 0
	var inactive_raised_ticks := 0
	var closed_readings := 0
	var slips := 0
	var slip_ok := true
	var tapes_dropped := 0
	var pickups := 0
	var carried_value := 0.0
	var lost_value := 0.0
	var bots: Array[BotStat] = []

static func run_one(i: int) -> RunResult:
	var seed := "earn-%d" % i
	var depth := 1 + (i % 4)
	var n_bots := 1 + ((i / 4) % 4)
	var p := Plans.plan(seed, depth)
	var rng := Rng.make_rng(seed).fork("setup")
	var toggles := Rng.make_rng(seed).fork("toggles")
	var bots: Array[Bot.Bot] = []
	for b in n_bots:
		var oblivious := b == 0 and i % 3 == 0
		var w := rng.next()
		bots.append(Bot.create_bot(p, "bot%d" % b, "%s:%d" % [seed, b], w, oblivious, p.landing if b == 0 else null))
	var ids: Array[String] = []
	for b in bots:
		ids.append(b.id)
	var active := {}
	for id in ids:
		active[id] = true
	var crew := Instr.create_crew(ids)
	for id in ids:
		crew = Instr.set_raised(crew, id, true)
	var toggle_in := 2.0 + toggles.next() * 6.0
	var orderly := Entity.create_orderly(p)
	var r := RunResult.new()
	for id in ids:
		r.bots.append(BotStat.new())
	var any_growth := false
	var ticks := int(round(RUN_SECONDS / DT))
	for tick in ticks:
		toggle_in -= DT
		if toggle_in <= 0.0 and n_bots > 1:
			toggle_in = 1.0 + toggles.next() * 6.0
			var m := Instr.member(crew, "bot1")
			if m != null:
				crew = Instr.set_raised(crew, "bot1", not m.instrument.raised)
		if i % 2 == 1:
			for id in ids:
				if not active[id]:
					crew = Instr.set_raised(crew, id, true)
		for b in bots:
			if active[b.id]:
				Bot.step_bot(p, b, DT, null if Instr.member(crew, b.id).instrument.raised else orderly.body)
		var views: Array[Entity.PlayerView] = []
		for b in bots:
			var v := Bot.bot_view(b)
			v.active = active[b.id]
			views.append(v)
		var before := orderly
		var res := Entity.step_entity(p, before, views, DT)
		orderly = res.state
		var players: Array[Instr.CrewPlayer] = []
		for v in views:
			players.append(Instr.CrewPlayer.make(v.id, v.body, v.active))
		var entity: Array[Instr.EntityTick] = [Instr.EntityTick.make("orderly", &"stillness", before, orderly, res.events)]
		var crew_before := crew
		var out := Instr.step_crew(p, crew, players, entity, DT)
		crew = out.crew

		# 1. The earning rule, by the oracle.
		var moved := oracle_moved(before, orderly, res.events)
		var grew_this_tick := false
		for k in ids.size():
			var id := ids[k]
			var was := Instr.member(crew_before, id)
			var now := Instr.member(crew, id)
			var pl := players[k]
			if not was.instrument.raised:
				r.lowered += 1
			if not pl.active and was.instrument.raised:
				r.inactive_raised_ticks += 1
			var grew := now.instrument.recorded > was.instrument.recorded
			if not grew:
				continue
			grew_this_tick = true
			r.growth_ticks += 1
			r.bots[k].recorded_all += now.instrument.recorded - was.instrument.recorded
			var d := oracle_distance(pl.body, orderly.body)
			if not was.instrument.raised or not pl.active or not moved or d > ORACLE_RANGE + 1e-9:
				r.violations += 1

		# The slip: once per run, on the first tick anything was recorded.
		var slips := 0
		for e in out.events:
			if e["type"] == "slip":
				slips += 1
		r.slips += slips
		if slips > 0 and (any_growth or not grew_this_tick):
			r.slip_ok = false
		if grew_this_tick and not any_growth and slips != 1:
			r.slip_ok = false
		if grew_this_tick:
			any_growth = true

		var caught_now := {}
		for e in res.events:
			if e["type"] == "caught":
				caught_now[e["playerId"]] = true
		for e in out.events:
			var k := ids.find(e["playerId"])
			if k < 0:
				continue
			var stat := r.bots[k]
			if e["type"] == "readingClosed":
				r.closed_readings += 1
				if not stat.caught and not caught_now.has(e["playerId"]):
					stat.earned_before += e["value"]
			if e["type"] == "tapeDropped":
				r.tapes_dropped += 1
		for id: String in caught_now:
			active[id] = false
			r.bots[ids.find(id)].caught = true

		# Active bots pick up any tape within reach of where they stand (distance measured here).
		for f: Instr.FloorTape in crew.floor.duplicate():
			for k in ids.size():
				var id := ids[k]
				var pl := players[k]
				if not active[id] or not pl.active or oracle_distance(pl.body, f.at) > 1.3:
					continue
				var up := Instr.pick_up_tape(crew, id, f.tape.id)
				if up.ok:
					crew = up.crew
					r.pickups += 1
					break
	var aboard: Array[String] = []
	for id in ids:
		if active[id]:
			aboard.append(id)
	var dep := Instr.leave_floor(crew, aboard)
	r.carried_value = dep.carried_value
	r.lost_value = dep.lost_value
	if any_growth and r.slips != 1:
		r.slip_ok = false
	if not any_growth and r.slips != 0:
		r.slip_ok = false
	return r

static func counts(n: int) -> Dictionary:
	var rs: Array[RunResult] = []
	for i in n:
		rs.append(run_one(i))
	var c := {"runs": n, "growthTicks": 0, "lowered": 0, "inactiveRaisedTicks": 0, "withReading": 0, "closedReadings": 0, "dropRuns": 0,
		"tapesDropped": 0, "pickups": 0, "carried": 0.0, "lost": 0.0, "earners": 0, "earnersCaught": 0, "nonEarners": 0, "nonEarnersCaught": 0,
		"violations": 0, "slipNotOk": 0}
	var values: Array[float] = []
	for r in rs:
		c["growthTicks"] += r.growth_ticks
		c["lowered"] += r.lowered
		c["inactiveRaisedTicks"] += r.inactive_raised_ticks
		c["withReading"] += 1 if r.closed_readings > 0 else 0
		c["closedReadings"] += r.closed_readings
		c["dropRuns"] += 1 if r.tapes_dropped > 0 else 0
		c["tapesDropped"] += r.tapes_dropped
		c["pickups"] += r.pickups
		c["carried"] += r.carried_value
		c["lost"] += r.lost_value
		c["violations"] += r.violations
		c["slipNotOk"] += 0 if r.slip_ok else 1
		var v := r.carried_value + r.lost_value
		if v > 0.0:
			values.append(v)
		for b in r.bots:
			if b.earned_before > 0.0:
				c["earners"] += 1
				c["earnersCaught"] += 1 if b.caught else 0
			if b.recorded_all == 0.0:
				c["nonEarners"] += 1
				c["nonEarnersCaught"] += 1 if b.caught else 0
	values.sort()
	c["medianValue"] = values[values.size() / 2] if not values.is_empty() else 0.0
	c["maxValue"] = values.max() if not values.is_empty() else 0.0
	return c

func test_recording_rule_by_the_oracle(t: T) -> void:
	var ref: Dictionary = Snap.load_ref("properties.json")
	var want: Dictionary = ref["full" if t.full else "sub"]["instrument"]
	var n: int = want["runs"]
	var frac := float(n) / 500.0
	var c := counts(n)
	t.eq(c["violations"], 0, "a reading grew when the rule says it may not")
	t.eq(c["slipNotOk"], 0, "runs where the slip did not print exactly once, on the first recording tick")
	t.check(c["growthTicks"] > 5000 * frac and c["lowered"] > 1000 * frac and c["inactiveRaisedTicks"] > 1000 * frac, "not vacuous: %s" % str(c))
	t.check(float(c["withReading"]) / n > 0.3, "readings close in many runs: %d of %d" % [c["withReading"], n])
	var rate_e := float(c["earnersCaught"]) / maxi(1, c["earners"])
	var rate_n := float(c["nonEarnersCaught"]) / maxi(1, c["nonEarners"])
	t.check(rate_e > rate_n, "greed costs: earners caught %s, non-earners %s" % [rate_e, rate_n])
	var d := Snap.compare(c, want, "instrument")
	t.check(d.ok(), "counts differ from TypeScript's: " + d.summary())
	t.note("%d runs x 60 s: growth-ticks %d, lowered %d, inactive-raised %d, runs with a reading %d (%d readings), tapes dropped %d in %d runs, picked up %d" % [
		n, c["growthTicks"], c["lowered"], c["inactiveRaisedTicks"], c["withReading"], c["closedReadings"], c["tapesDropped"], c["dropRuns"], c["pickups"]])
	t.note("carried out %s, lost %s, median earning run %s, max %s; earners caught %d of %d, non-earners %d of %d" % [
		M.to_fixed(c["carried"], 0), M.to_fixed(c["lost"], 0), M.to_fixed(c["medianValue"], 1), M.to_fixed(c["maxValue"], 1),
		c["earnersCaught"], c["earners"], c["nonEarnersCaught"], c["nonEarners"]])
	t.note("TypeScript, same seeds: growth-ticks %d, lowered %d, inactive-raised %d, with a reading %d (%d), dropped %d, carried %s, lost %s" % [
		want["growthTicks"], want["lowered"], want["inactiveRaisedTicks"], want["withReading"], want["closedReadings"], want["tapesDropped"],
		M.to_fixed(want["carried"], 0), M.to_fixed(want["lost"], 0)])
