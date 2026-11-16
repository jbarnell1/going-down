# One wait for the car, start to bell, with a crew of waiting bots (sim/bot.gd) of one style, on a
# floor of a given depth. Port of tests/sim/waits.ts (shared by the blackout tests and ref_run).
extends RefCounted

const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Entity = preload("res://sim/entity.gd")
const Run = preload("res://sim/run.gd")
const Bot = preload("res://sim/bot.gd")
const Clinic = preload("res://sim/clinic.gd")
const Rng = preload("res://sim/rng.gd")
const M = preload("res://sim/jsmath.gd")

const WAIT_DT := 0.05
## Where the Orderly starts, hunting: this many cells' walk from the landing (drawn per wait).
const ORDERLY_FROM_CELLS: Array[int] = [6, 14]

class WaitResult:
	var label: String
	var crew: int
	var caught := 0
	## Every crew member not caught was aboard when the doors closed.
	var boarded := false
	## Caught during the blackout (from its start to the doors opening).
	var caught_in_blackout := 0
	## Caught after the lights came back.
	var caught_after := 0
	var darks: Array[float] = []
	## During the blackout: the Orderly's closest approach to anyone not yet caught (m, same level),
	## and how far anyone got from the car door (m).
	var closest := INF
	var farthest := 0.0
	## Seconds from the doors opening to the last surviving member boarding (null if not all did).
	var boarded_after: Variant = null
	var events: Array[Dictionary] = []

## A floor of `depth` with the car away, the crew on the landing, and the Orderly hunting some way off.
static func wait_start(seed: String, depth: int, n: int) -> Run.RunState:
	var ids: Array[String] = []
	for k in n:
		ids.append("p%d" % k)
	var base := Run.create_run(seed, ids)
	var plan := Clinic.generate_clinic(seed, depth)
	var car := Run.car_geometry(plan)
	var dist := Floor.distances_from(plan, plan.landing)
	var cands: Array = []
	for i in dist.size():
		var d := dist[i]
		if d < ORDERLY_FROM_CELLS[0] or d > ORDERLY_FROM_CELLS[1]:
			continue
		var p := Floor.pos_from_index(plan, i)
		if Floor.is_walkable(plan, p.level, p.x, p.y):
			cands.append(p)
	var at: Floor.Pos = Rng.make_rng(seed).fork("orderly").pick(cands)
	var orderly := Entity.create_orderly(plan)
	orderly.body = Move.body_at_cell(plan, at)
	orderly.mode = &"hunting"
	var st := base.copy()
	st.depth = depth
	st.plan = plan
	st.car = car
	st.orderly = orderly
	st.entity_id = "orderly-%d" % depth
	st.phase = &"away"
	st.players = []
	for p in base.players:
		var np := p.copy()
		np.aboard = false
		st.players.append(np)
	return st

static func run_wait(style: StringName, depth: int, i: int) -> WaitResult:
	var seed := "wait-%d-%d" % [depth, i]
	var n := 1 + (i % 4)
	var st := wait_start(seed, depth, n)
	var bots: Array[Bot.WaitBot] = []
	for k in st.players.size():
		bots.append(Bot.create_wait_bot(st, st.players[k].id, k, style))
	var st2 := st.copy()
	st2.players = []
	for k in st.players.size():
		var np := st.players[k].copy()
		np.body = bots[k].body
		st2.players.append(np)
	st = st2
	var caught := {}
	var res := WaitResult.new()
	res.label = "%s %s x%d" % [seed, style, n]
	res.crew = n
	var blackout := false
	var lit := false
	var opened_at: Variant = null
	var k := 0
	while k < 140.0 / WAIT_DT:
		var live: Array[Bot.WaitBot] = []
		for b in bots:
			if not caught.has(b.id):
				live.append(b)
		if k > 0:
			for b in live:
				Bot.step_wait_bot(st, b, WAIT_DT)
		var waiting := false
		for b in live:
			if not Run.in_car(st.car, b.body):
				waiting = true
		var inputs: Array[Run.PlayerInput] = []
		for j in live.size():
			var b := live[j]
			inputs.append(Bot.wait_bot_input(b, b.mode == &"aboard" and waiting, k == 0 and j == 0))
		var r := Run.step_run(st, inputs, WAIT_DT)
		st = r.state
		res.events.append_array(r.events)
		var bell := false
		var closed: Variant = null
		for e in r.events:
			var type: String = e["type"]
			if type == "blinkStart":
				res.darks.append(e["len"])
				if e["blackout"]:
					blackout = true
			if type == "carArrived":
				lit = true
				opened_at = e["t"]
			if type == "caught":
				caught[e["playerId"]] = true
				res.caught += 1
				if blackout and not lit:
					res.caught_in_blackout += 1
				if lit:
					res.caught_after += 1
			if type == "bell":
				bell = true
			if type == "doorsClosed" and closed == null:
				closed = e
		if blackout and not lit:
			var o := st.orderly.body
			for b in bots:
				if caught.has(b.id):
					continue
				if b.body.level == o.level:
					res.closest = minf(res.closest, M.hypot2(b.body.x - o.x, b.body.z - o.z))
				res.farthest = maxf(res.farthest, M.hypot2(b.body.x - st.car.door_x, b.body.z - st.car.door_z))
		if opened_at != null and res.boarded_after == null:
			var all_in := true
			for b in bots:
				if not (caught.has(b.id) or Run.in_car(st.car, b.body)):
					all_in = false
			if all_in:
				res.boarded_after = st.t - float(opened_at)
		if bell or st.phase == &"ended":
			var aboard := {}
			if closed != null:
				for id: String in closed["aboard"]:
					aboard[id] = true
			res.boarded = true
			for b in bots:
				if not (caught.has(b.id) or aboard.has(b.id)):
					res.boarded = false
			return res
		k += 1
	push_error("%s: no bell after 140 s (phase %s)" % [res.label, st.phase])
	return res

class WaitTable:
	var style: StringName
	var depth: int
	var waits: int
	var lost := 0
	var boarded := 0
	var caught := 0
	var caught_in_blackout := 0
	var caught_after := 0
	## Waits where the Orderly came within 5 m of someone in the blackout (a chase).
	var chased := 0
	## Median of the farthest anyone got from the car in the blackout (m).
	var median_farthest := 0.0

static func wait_table(style: StringName, depth: int, waits: int) -> WaitTable:
	var t := WaitTable.new()
	t.style = style
	t.depth = depth
	t.waits = waits
	var far: Array[float] = []
	for i in waits:
		var r := run_wait(style, depth, i)
		if r.caught > 0:
			t.lost += 1
		if r.boarded:
			t.boarded += 1
		t.caught += r.caught
		t.caught_in_blackout += r.caught_in_blackout
		t.caught_after += r.caught_after
		if r.closest < 5.0:
			t.chased += 1
		far.append(r.farthest)
	far.sort()
	t.median_farthest = far[waits / 2] if waits > 0 else 0.0
	return t

static func table_line(t: WaitTable) -> String:
	var pc := func(x: int) -> String: return "%s%%" % M.to_fixed((100.0 * x) / t.waits, 1)
	return "depth %d %s: %d waits, lost someone %d (%s), all survivors boarded %d (%s), catches %d (in the blackout %d, after the lights %d); chased within 5 m in the blackout %d (%s), median farthest from the car %s m" % [
		t.depth, String(t.style).rpad(4), t.waits, t.lost, pc.call(t.lost), t.boarded, pc.call(t.boarded), t.caught, t.caught_in_blackout,
		t.caught_after, t.chased, pc.call(t.chased), M.to_fixed(t.median_farthest, 1)]
