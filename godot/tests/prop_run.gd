# The run's rules by independent oracles (ported from tests/sim/run.test.ts; they share nothing
# with run.gd or sight.gd): while the car comes, a crew staring at the Orderly holds it still except
# in the blinks, every dark is telegraphed and longer than the last, and the last is the blackout
# ending as the car arrives; and the car is safe (the Orderly never ends a tick in it, nobody in it is
# caught), with wandering and oblivious bots. Counts must equal the golden counts.
extends RefCounted

const T = preload("res://tests/t.gd")
const Snap = preload("res://tests/snap.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Follow = preload("res://sim/follow.gd")
const Entity = preload("res://sim/entity.gd")
const Landing = preload("res://sim/landing.gd")
const Run = preload("res://sim/run.gd")
const Bot = preload("res://sim/bot.gd")
const Rng = preload("res://sim/rng.gd")
const M = preload("res://sim/jsmath.gd")

const DT := 0.05

# =============================================================================================
# Oracles.

class Box:
	var x0: float
	var z0: float
	var x1: float
	var z1: float

## The car: the plan cell on the far side of the landing's elevator wall.
static func oracle_car(plan: Floor.FloorPlan) -> Box:
	var w := Landing.elevator_wall(plan)
	var cx := plan.landing.x + Floor.dir_dx(w)
	var cy := plan.landing.y + Floor.dir_dy(w)
	var s := plan.cell_size
	var b := Box.new()
	b.x0 = cx * s
	b.z0 = cy * s
	b.x1 = (cx + 1) * s
	b.z1 = (cy + 1) * s
	return b

static func box_distance(b: Box, x: float, z: float) -> float:
	var dx := maxf(maxf(b.x0 - x, 0.0), x - b.x1)
	var dz := maxf(maxf(b.z0 - z, 0.0), z - b.z1)
	return M.hypot2(dx, dz)

static func oracle_in_car(b: Box, body: Move.Body) -> bool:
	return body.x > b.x0 and body.x < b.x1 and body.z > b.z0 and body.z < b.z1

## A deliberately strict line of sight on level 0 below door height, sampled every 5 cm.
static func surely_clear(plan: Floor.FloorPlan, ax: float, az: float, bx: float, bz: float) -> bool:
	var cs := float(plan.cell_size)
	var n := maxi(1, int(ceil(M.hypot2(bx - ax, bz - az) / 0.05)))
	var pcx := int(floor(ax / cs))
	var pcy := int(floor(az / cs))
	var prev_x := ax
	var prev_z := az
	for i in range(1, n + 1):
		var qx := ax + ((bx - ax) * i) / n
		var qz := az + ((bz - az) * i) / n
		var qcx := int(floor(qx / cs))
		var qcy := int(floor(qz / cs))
		if qcx != pcx or qcy != pcy:
			var mx := (prev_x + qx) / 2.0
			var mz := (prev_z + qz) / 2.0
			var d := absi(qcx - pcx) + absi(qcy - pcy)
			if d == 1:
				if not _edge(plan, pcx, pcy, qcx, qcy, mx, mz, cs):
					return false
			else:
				if not (_edge(plan, pcx, pcy, qcx, pcy, mx, mz, cs) and _edge(plan, qcx, pcy, qcx, qcy, mx, mz, cs) \
					and _edge(plan, pcx, pcy, pcx, qcy, mx, mz, cs) and _edge(plan, pcx, qcy, qcx, qcy, mx, mz, cs)):
					return false
		pcx = qcx
		pcy = qcy
		prev_x = qx
		prev_z = qz
	return true

static func _edge(plan: Floor.FloorPlan, px: int, py: int, qx: int, qy: int, mx: float, mz: float, cs: float) -> bool:
	if not Floor.can_step(plan, Floor.Pos.make(0, px, py), Floor.Pos.make(0, qx, qy)):
		return false
	var ra := Floor.room_id_at(plan, 0, px, py)
	var same := ra >= 0 and ra == Floor.room_id_at(plan, 0, qx, qy)
	var corr := Floor.cell_at(plan, 0, px, py) == &"corridor" and Floor.cell_at(plan, 0, qx, qy) == &"corridor"
	if same or corr or not Floor.has_door(plan, 0, px, py, qx, qy):
		return true
	var lateral := mz - (py + 0.5) * cs if px != qx else mx - (px + 0.5) * cs
	return absf(lateral) <= 0.5

## A staring viewer surely sees the figure: both on level 0's floor, clear sight to its chest, aimed at it.
static func oracle_stare_sees(plan: Floor.FloorPlan, from: Move.Body, yaw: float, fig: Move.Body) -> bool:
	if from.level != 0 or fig.level != 0 or from.y != 0.0 or fig.y != 0.0:
		return false
	var want := M.atan2_js(-(fig.x - from.x), -(fig.z - from.z))
	var d := fmod(absf(want - yaw), 2.0 * PI)
	if d > PI:
		d = 2.0 * PI - d
	if d > (30.0 * PI) / 180.0:
		return false
	return surely_clear(plan, from.x, from.z, fig.x, fig.z)

# =============================================================================================
# Helpers (run.test.ts).

class Actor:
	var id: String
	var body: Move.Body
	var yaw := 0.0
	var pitch := 0.0
	var call := false
	var hold := false

static func make_actor(id: String, body: Move.Body, yaw: float = 0.0) -> Actor:
	var a := Actor.new()
	a.id = id
	a.body = body
	a.yaw = yaw
	return a

static func step(st: Run.RunState, actors: Array[Actor]) -> Run.RunStep:
	var inputs: Array[Run.PlayerInput] = []
	for a in actors:
		var p := Run.PlayerInput.make(a.id, a.body, Bot.BOT_EYE, a.yaw, a.pitch, Bot.BOT_HFOV_DEG, Bot.BOT_VFOV_DEG)
		p.call = a.call
		p.hold_doors = a.hold
		inputs.append(p)
	var r := Run.step_run(st, inputs, DT)
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
	return r

static func look_at(a: Actor, target: Move.Body) -> void:
	a.yaw = Entity.yaw_toward(target.x - a.body.x, target.z - a.body.z)
	var d := M.hypot2(target.x - a.body.x, target.z - a.body.z)
	a.pitch = M.atan2_js(target.y + 1.7 - (a.body.y + Bot.BOT_EYE), maxf(d, 0.1))

static func walk(st: Run.RunState, a: Actor, waypoints: Array[Move.Body], speed: float) -> bool:
	var budget := speed * DT
	while budget > 1e-9 and not waypoints.is_empty():
		var w := waypoints[0]
		var d := M.hypot2(w.x - a.body.x, w.z - a.body.z)
		if d < 0.02:
			waypoints.pop_front()
			continue
		var stp := minf(budget, d)
		var before := a.body
		a.body = Run.move_in_run(st, a.body, ((w.x - a.body.x) / d) * stp, ((w.z - a.body.z) / d) * stp, Bot.BOT_RADIUS)
		budget -= stp
		if M.hypot2(a.body.x - before.x, a.body.z - before.z) < 1e-6:
			break
	return waypoints.is_empty()

static func into_car(st: Run.RunState, u: float, v: float) -> Array[Move.Body]:
	return [Run.car_body(st.car, -0.6, 0.0), Run.car_body(st.car, 0.45, 0.0), Run.car_body(st.car, u, v)]

static func out_of_car(st: Run.RunState, u: float, v: float) -> Array[Move.Body]:
	return [Run.car_body(st.car, 0.45, 0.0), Run.car_body(st.car, -0.6, 0.0), Run.car_body(st.car, u, v)]

static func dist2(a: Move.Body, b: Move.Body) -> float:
	return M.hypot2(a.x - b.x, a.z - b.z)

static func near_landing_cell(plan: Floor.FloorPlan, rng: Rng, from: Move.Body) -> Floor.Pos:
	var dist := Floor.distances_from(plan, plan.landing)
	var cands: Array = []
	var visible: Array = []
	for i in dist.size():
		var d := dist[i]
		if d < 3 or d > 8:
			continue
		var p := Floor.pos_from_index(plan, i)
		if p.level != 0 or not Floor.is_walkable(plan, 0, p.x, p.y) or Floor.cell_at(plan, 0, p.x, p.y) == &"stair":
			continue
		cands.append(p)
		var b := Move.body_at_cell(plan, p)
		if surely_clear(plan, from.x, from.z, b.x, b.z):
			visible.append(p)
	return rng.pick(visible if not visible.is_empty() else cands)

static func _types(events: Array[Dictionary]) -> Array[String]:
	var out: Array[String] = []
	for e in events:
		out.append(e["type"])
	return out

# =============================================================================================
# 2 and 3. The blink rule: a crew staring at the Orderly while the car comes.

class StareResult:
	var violations := 0
	var moved_in_blink := 0
	var blink_advance := 0.0
	var caught := false
	var blinks := 0
	var blackouts := 0
	var telegraph := 0
	var arrived := false

static func stare_run(i: int) -> StareResult:
	var seed := "stare-%d" % i
	var n := 1 + ((i / 4) % 4)
	var ids: Array[String] = []
	for k in n:
		ids.append("p%d" % k)
	var st0 := Run.create_run(seed, ids)
	var plan := st0.plan
	var spots: Array[Move.Body] = []
	for k in n:
		spots.append(Run.car_body(st0.car, -0.7 - 0.5 * floorf(k / 2.0), 0.45 if k % 2 != 0 else -0.45))
	var start := near_landing_cell(plan, Rng.make_rng(seed).fork("orderly"), spots[0])
	var orderly := Entity.create_orderly(plan)
	orderly.body = Move.body_at_cell(plan, start)
	orderly.mode = &"hunting"
	var st := st0.copy()
	st.phase = &"away"
	st.players = []
	for k in st0.players.size():
		var np := st0.players[k].copy()
		np.body = spots[k]
		np.aboard = false
		st.players.append(np)
	st.orderly = orderly
	var actors: Array[Actor] = []
	for k in n:
		var a := make_actor(ids[k], spots[k])
		a.call = k == 0
		actors.append(a)
	var res := StareResult.new()
	var out := {}
	var blind := false
	var last_soon: Variant = null  # [t, len, blackout]
	var last_start: Variant = null
	var last_end: Variant = null
	var last_len := 0.0
	var blackout_on := false
	var k := 0
	while k < 90.0 / DT:
		for a in actors:
			look_at(a, st.orderly.body)
		var before := st.orderly.body
		var r := step(st, actors)
		for a in actors:
			a.call = false
		st = r.state
		var types := _types(r.events)
		var blind_now := types.has("blinkStart") or (blind and not types.has("blinkEnd"))
		blind = blind_now
		for e in r.events:
			var type: String = e["type"]
			if type == "blinkSoon":
				if last_soon != null:
					res.telegraph += 1
				last_soon = [e["t"], e["len"], e["blackout"]]
			if type == "blinkStart":
				res.blinks += 1
				if e["blackout"]:
					res.blackouts += 1
				var warn := Run.BLACKOUT_WARNING if e["blackout"] else Run.BLINK_WARNING
				var lead := -1.0 if last_soon == null else float(e["t"]) - float(last_soon[0])
				if absf(lead - warn) > DT + 1e-9:
					res.telegraph += 1
				if last_soon != null and (last_soon[1] != e["len"] or last_soon[2] != e["blackout"]):
					res.telegraph += 1
				if float(e["len"]) <= last_len:
					res.telegraph += 1
				var min_gap: float = Run.BLINK_GAPS[0][0] + warn
				if last_end != null and float(e["t"]) - float(last_end) < min_gap - DT - 1e-9:
					res.telegraph += 1
				if blackout_on:
					res.telegraph += 1
				blackout_on = e["blackout"]
				last_len = e["len"]
				last_start = e["t"]
				last_soon = null
			if type == "blinkEnd" and last_start != null:
				var length := float(e["t"]) - float(last_start)
				if e["blackout"]:
					if not types.has("carArrived"):
						res.telegraph += 1
					if length < 9.0 - DT - 1e-9:
						res.telegraph += 1
				elif absf(length - last_len) > DT + 1e-9:
					res.telegraph += 1
				last_end = e["t"]
			if type == "carArrived" and not (blackout_on and types.has("blinkEnd")):
				res.telegraph += 1
			if type == "caught":
				res.caught = true
			if e.has("playerId") and e["playerId"] == Run.LURE_ID:
				res.violations += 1
		var after := st.orderly.body
		var moved := after.x != before.x or after.z != before.z or after.level != before.level
		if moved:
			var seers := 0
			for a in actors:
				if not out.has(a.id) and oracle_stare_sees(plan, a.body, a.yaw, before):
					seers += 1
			if seers > 0 and not blind_now:
				res.violations += 1
			if seers > 0 and blind_now:
				res.moved_in_blink += 1
				res.blink_advance += dist2(before, after)
		for e in r.events:
			if e["type"] == "caught":
				out[e["playerId"]] = true
		if types.has("carArrived") or st.phase == &"ended":
			res.arrived = types.has("carArrived")
			break
		k += 1
	if last_soon != null and st.phase == &"coming":
		res.telegraph += 1
	return res

## Runs per size (tools/property_counts.ts QUICK, SUB, FULL: stare and safe).
const SIZES := {"quick": {"stare": 4, "safe": 3}, "sub": {"stare": 24, "safe": 16}, "full": {"stare": 320, "safe": 300}}

static func _golden(t: T, key: String) -> Dictionary:
	var g: Variant = t.golden("properties.json", "%s.%s" % [t.size_key(), key])
	return g if g is Dictionary else {}

func test_staring_while_the_car_comes(t: T) -> void:
	var want := _golden(t, "stare")
	var n: int = SIZES[t.size_key()]["stare"]
	var c := {"runs": n, "violations": 0, "telegraph": 0, "moved": 0, "caught": 0, "blinks": 0, "blackouts": 0, "advance": 0.0, "arrived": 0, "arrivedOneBlackout": 0}
	for i in n:
		var r := stare_run(i)
		c["violations"] += r.violations
		c["telegraph"] += r.telegraph
		c["moved"] += 1 if r.moved_in_blink > 0 else 0
		c["caught"] += 1 if r.caught else 0
		c["blinks"] += r.blinks
		c["blackouts"] += r.blackouts
		c["advance"] += r.blink_advance
		c["arrived"] += 1 if r.arrived else 0
		c["arrivedOneBlackout"] += 1 if (r.arrived and r.blackouts == 1) else 0
	t.eq(c["violations"], 0, "moved while stared at with the lights on (or an event about the call)")
	t.eq(c["telegraph"], 0, "a dark not telegraphed, not longer than the last, or a blackout not ending as the car arrives")
	t.check(t.quick or c["moved"] > n / 2, "staring is not safe: it moved during a blink in %d of %d" % [c["moved"], n])
	# Vitest asks for more than half the waits to reach the car; the first 24 seeds reach it in 11.
	t.check(t.quick or c["blinks"] > n * 2 and c["arrived"] > (n / 2 if t.full else n / 3) and c["arrived"] == c["arrivedOneBlackout"], "not vacuous: %s" % str(c))
	t.expect("properties.json", "%s.stare" % t.size_key(), c, "the counts")
	t.note("%d calls: %d dark stretches (%d blackouts); it moved during a blink in %d, caught while waiting %d, arrived %d%s" % [
		n, c["blinks"], c["blackouts"], c["moved"], c["caught"], c["arrived"],
		"" if want.is_empty() else "; golden: %d darks, moved %d, caught %d" % [want["blinks"], want["moved"], want["caught"]]])

# =============================================================================================
# 4. The car is safe, with wandering and oblivious bots.

class Rider:
	var actor: Actor
	var bot: Bot.Bot
	var mode: StringName
	var timer := 0.0
	var route: Array[Move.Body] = []
	var walk: Follow.PathWalk = null
	var rng: Rng

class SafeResult:
	var violations := 0
	var caught := 0
	var encounters := 0
	var rides := 0
	var events := 0

static func safe_run(i: int, seconds: float = 90.0) -> SafeResult:
	var seed := "safe-%d" % i
	var n := 1 + (i % 4)
	var ids: Array[String] = []
	for k in n:
		ids.append("b%d" % k)
	var st := Run.create_run(seed, ids)
	if i % 4 != 3:
		var start := near_landing_cell(st.plan, Rng.make_rng(seed).fork("orderly"), Run.car_body(st.car, -1.0, 0.0))
		var o := Entity.create_orderly(st.plan)
		o.body = Move.body_at_cell(st.plan, start)
		o.mode = &"hunting"
		st = st.copy()
		st.orderly = o
	var box := oracle_car(st.plan)
	var riders: Array[Rider] = []
	for k in n:
		var id := ids[k]
		var rd := Rider.new()
		rd.rng = Rng.make_rng(seed).fork("rider:%s" % id)
		var body := st.players[k].body
		var w := rd.rng.next()
		var obl := k == 0 or rd.rng.chance(0.4)
		rd.bot = Bot.create_bot(st.plan, id, "%s:%s" % [seed, id], w, obl, st.plan.landing)
		rd.actor = make_actor(id, body, rd.rng.next() * 6.0)
		rd.mode = &"exit"
		rd.timer = 0.0
		rd.route = out_of_car(st, -1.0, (rd.rng.next() - 0.5) * 1.2)
		riders.append(rd)
	var res := SafeResult.new()
	var caught := {}
	var k := 0
	while k < seconds / DT and st.phase != &"ended":
		for r in riders:
			var a := r.actor
			a.call = false
			if caught.has(a.id):
				continue
			r.timer -= DT
			if r.mode != &"wander" and r.rng.chance(DT / 1.5):
				a.yaw += (r.rng.next() - 0.5) * 3.0
			match r.mode:
				&"exit":
					if st.phase == &"riding" or st.phase == &"arriving":
						pass
					elif walk(st, a, r.route, 2.5) or not oracle_in_car(box, a.body):
						if not oracle_in_car(box, a.body):
							r.mode = &"wander"
							r.bot.body = a.body
							r.bot.walk = null
							r.timer = 2.0 + r.rng.next() * 12.0
				&"wander":
					Bot.step_bot(st.plan, r.bot, DT, st.orderly.body)
					a.body = r.bot.body
					a.yaw = r.bot.yaw
					a.pitch = r.bot.pitch
					if r.timer <= 0.0:
						var path := Floor.find_path(st.plan, Move.cell_of(st.plan, a.body), st.plan.landing)
						if not path.is_empty():
							r.walk = Follow.PathWalk.make(path, 1 if path.size() > 1 else 0)
							r.mode = &"toLanding"
							r.timer = 60.0
						else:
							r.timer = 5.0
				&"toLanding":
					var w := r.walk
					if w != null and not Follow.path_done(st.plan, w, a.body):
						var before := a.body
						a.body = Follow.step_path_walk(st.plan, w, a.body, 3.0 * DT, Bot.BOT_RADIUS)
						if dist2(before, a.body) > 1e-4:
							a.yaw = Entity.yaw_toward(a.body.x - before.x, a.body.z - before.z)
					else:
						if st.phase == &"away":
							a.call = true
						if st.phase == &"boarding" or st.phase == &"unloading":
							r.mode = &"enter"
							var u := 0.6 + r.rng.next() * 1.0
							r.route = into_car(st, u, (r.rng.next() - 0.5) * 1.3)
					if r.timer <= 0.0 and r.mode == &"toLanding":
						r.mode = &"wander"
						r.bot.body = a.body
						r.bot.walk = null
						r.timer = 5.0 + r.rng.next() * 20.0
				&"enter":
					if not Run.doors_open(st) and not oracle_in_car(box, a.body):
						r.mode = &"toLanding"
						r.walk = null
					elif walk(st, a, r.route, 2.5):
						r.mode = &"inCar"
						r.timer = 3.0 + r.rng.next() * 25.0
				&"inCar":
					a.hold = r.rng.chance(0.3)
					if r.timer <= 0.0 and Run.doors_open(st):
						r.mode = &"exit"
						r.route = out_of_car(st, -1.0, (r.rng.next() - 0.5) * 1.2)
		var actors: Array[Actor] = []
		var sent := {}
		for r in riders:
			actors.append(r.actor)
			sent[r.actor.id] = r.actor.body
		var tk := step(st, actors)
		st = tk.state
		for e in tk.events:
			res.events += 1
			var type: String = e["type"]
			if type == "caught":
				res.caught += 1
				caught[e["playerId"]] = true
				if sent.has(e["playerId"]) and oracle_in_car(box, sent[e["playerId"]]):
					res.violations += 1
				if e["playerId"] == Run.LURE_ID:
					res.violations += 1
			if type == "rodeDown":
				res.rides += 1
				box = oracle_car(st.plan)
				caught.clear()
				for r in riders:
					r.mode = &"exit"
					r.route = out_of_car(st, -1.0, (r.rng.next() - 0.5) * 1.2)
					r.bot.walk = null
			if type == "doorsClosed":
				var pushed: Dictionary = e["pushedOut"]
				for r in riders:
					if pushed.has(r.actor.id):
						r.mode = &"wander"
						r.bot.body = r.actor.body
						r.bot.walk = null
						r.timer = 5.0 + r.rng.next() * 20.0
		var o := st.orderly.body
		var gap := box_distance(box, o.x, o.z)
		if st.phase != &"riding" and o.level == 0 and gap < Entity.ORDERLY_RADIUS - 1e-3:
			res.violations += 1
		if st.phase != &"riding" and gap < 2.5:
			for r in riders:
				if oracle_in_car(box, r.actor.body):
					res.encounters += 1
					break
		k += 1
	return res

func test_the_car_is_safe(t: T) -> void:
	var want := _golden(t, "safe")
	var n: int = SIZES[t.size_key()]["safe"]
	var c := {"runs": n, "violations": 0, "encounterRuns": 0, "encounterTicks": 0, "caught": 0, "rides": 0, "events": 0}
	for i in n:
		var r := safe_run(i)
		c["violations"] += r.violations
		c["encounterRuns"] += 1 if r.encounters > 0 else 0
		c["encounterTicks"] += r.encounters
		c["caught"] += r.caught
		c["rides"] += r.rides
		c["events"] += r.events
	t.eq(c["violations"], 0, "the Orderly in (or overlapping) the car, or someone caught inside it")
	t.check(t.quick or c["encounterRuns"] > n / 10 and c["caught"] > 10 * n / 300, "not vacuous: %s" % str(c))
	t.expect("properties.json", "%s.safe" % t.size_key(), c, "the counts")
	t.note("%d runs: %d with the Orderly within 2.5 m of an occupied car (%d ticks), %d catches outside, %d rides, %d events%s" % [
		n, c["encounterRuns"], c["encounterTicks"], c["caught"], c["rides"], c["events"],
		"" if want.is_empty() else "; golden: %d (%d), %d, %d, %d" % [want["encounterRuns"], want["encounterTicks"], want["caught"], want["rides"], want["events"]]])

# =============================================================================================
# 5. The day (docs/floors/prison.md P7, loop/NIGHT-PLAN.md A2), behind the days setting: BANK banks
# the tapes aboard, the day is settled on the banked total floored, the car rides up to the prison
# (depth 0, no resident), F held on a bunk lies you down, the bedtime count is sim/day.gd's and cannot be
# stopped, and the next day starts at depth 1 on the seed "<seed>:day<n>". After a wipe everyone wakes on
# a bunk. No tape is ever banked twice, and none left on a floor. The oracles are the design's words and
# sim/day.gd's and sim/prison.gd's own functions, not run.gd's.

const DayRigLib = preload("res://tests/day_rig.gd")
const Day = preload("res://sim/day.gd")
const Prison = preload("res://sim/prison.gd")
const Places = preload("res://sim/places.gd")
const HostRules = preload("res://net/host_rules.gd")

static func _ids(n: int) -> Array[String]:
	var out: Array[String] = []
	for k in n:
		out.append("p%d" % k)
	return out

## The bunk a player wakes on: the n-th bunk in sorted-id order (prison.md section 6, Day.bunk_of).
static func _bunk_cell(ids: Array[String], id: String) -> Vector2i:
	var sorted := ids.duplicate()
	sorted.sort()
	return Prison.bunk_positions()[sorted.find(id)]

static func _cell(plan: Floor.FloorPlan, b: Move.Body) -> Vector2i:
	var c := Move.cell_of(plan, b)
	return Vector2i(c.x, c.y)

static func _tape_of(held: Dictionary, id: String) -> String:
	for k: String in held:
		if held[k] == id:
			return k
	return ""

static func _sorted(a: Array) -> Array:
	var b := a.duplicate()
	b.sort()
	return b

static func _last(events: Array[Dictionary], type: String) -> Dictionary:
	var out := {}
	for e in events:
		if e["type"] == type:
			out = e
	return out

static func _all_caught(s: Run.RunState) -> Run.RunState:
	var out := s.copy()
	var players: Array[Run.RunPlayer] = []
	for p in s.players:
		var np := p.copy()
		np.status = &"caught"
		players.append(np)
	out.players = players
	return out

func test_the_day_is_off_unless_asked(t: T) -> void:
	var ids := _ids(2)
	t.check(not Run.create_run("off", ids).days, "a run made as before has no days")
	t.check(not HostRules.new(true, 1).prepare(Run.create_run("off", ids)).days, "host rules made as before add no days")
	var on := HostRules.new(true, 1, [], true).prepare(Run.create_run("off", ids))
	t.check(on.days, "host rules asked for days turn them on")
	t.eq(on.seed, "off", "day 1 keeps the run's seed")
	t.eq(on.base_seed, "off", "the run's own seed is kept")
	t.eq(on.day_index, 1, "day index")
	t.eq(on.day_state.day, 1, "day number")
	t.eq(on.day_state.crew_size, 2, "the crew that rides down sets the quota")
	t.eq(Run.day_seed("off", 1), "off", "day 1's seed")
	t.eq(Run.day_seed("off", 2), "off:day2", "day 2's seed")
	# Without days a bank still ends the run, exactly as every stored result has it.
	var rig := DayRigLib.DayRig.new("off-bank", ids, false)
	var e := rig.until_event("banked", 200.0)
	t.check(not e.is_empty(), "the run without days never banked")
	t.eq(rig.st.phase, &"ended", "a bank without days ends the run")
	t.check(rig.st.depth == 1 and rig.st.day_result == null, "no day settled without days")

func test_bank_rides_up_and_bed_starts_the_next_day(t: T) -> void:
	var ids := _ids(3)
	var rig := DayRigLib.DayRig.new("day-a", ids)
	rig.vote["p2"] = "out"  # left on the landing with a tape: it is lost and p2 wakes on a bunk
	var day1_hash := Floor.hash_plan(rig.st.plan)
	if not t.check(rig.until(func(s: Run.RunState) -> bool: return s.phase == &"boarding", 200.0), "the car never came"):
		return
	var s := rig.st
	s = DayRigLib.give(s, "p0", 123.7, "fx-0")
	s = DayRigLib.give(s, "p1", 50.25, "fx-1")
	s = DayRigLib.give(s, "p2", 999.0, "fx-2")
	s = DayRigLib.drop(s, "fx-floor", 400.0, Run.car_body(s.car, -1.5, 0.0))
	rig.st = s
	var held_before := DayRigLib.held(s)
	var day1_tapes := DayRigLib.all_tape_ids(s)
	var banked := rig.until_event("banked", 30.0)
	if not t.check(not banked.is_empty(), "never banked"):
		return
	var sm: Run.RunSummary = banked["summary"]
	t.eq(_sorted(Array(sm.tapes)), _sorted([_tape_of(held_before, "p0"), _tape_of(held_before, "p1")]), "the tapes aboard are banked, no others")
	t.check(not sm.tapes.has("fx-floor"), "the tape on the floor was banked")
	t.check(not sm.tapes.has(_tape_of(held_before, "p2")), "the tape of a player left on the landing was banked")
	var ended: Dictionary = _last(rig.events, "dayEnded").get("result", {})
	if not t.check(not ended.is_empty(), "no dayEnded with the bank"):
		return
	t.eq(int(ended["banked"]), floori(123.7 + 50.25), "the day is settled on the banked total, floored")
	var quota := Day.quota_for(0, 3, Run.DAY_FLOOR_QUOTA)
	t.eq(int(ended["quota"]), quota, "day 1's quota for three")
	t.eq(String(ended["kind"]), "missed" if floori(123.7 + 50.25) < quota else "made", "made or missed by sim/day.gd")
	var share_sum := 0
	for id: String in (ended["shares"] as Dictionary):
		share_sum += int(ended["shares"][id])
	t.eq(share_sum, int(ended["banked"]), "the shares sum to the banked total")
	t.check(rig.st.phase == &"riding" and rig.st.going_up, "the car rides up")
	t.check(DayRigLib.held(rig.st).is_empty() and rig.st.crew.floor.is_empty(), "tapes left in the crew after the bank")
	# The ride up, then home.
	var up := rig.until_event("rodeUp", Run.RIDE_UP_TIME + 1.0)
	if not t.check(not up.is_empty(), "never arrived home"):
		return
	t.check(absf(float(up["t"]) - float(banked["t"]) - Run.RIDE_UP_TIME) <= DayRigLib.DT + 1e-6, "the ride up takes RIDE_UP_TIME")
	t.eq(rig.st.depth, 0, "home is depth 0")
	t.eq(rig.st.plan.place, &"prison", "home is the prison")
	t.eq(Floor.hash_plan(rig.st.plan), Floor.hash_plan(Prison.prison_plan()), "the prison plan")
	t.eq(Places.resident(rig.st.plan.place).name, "", "no resident at home")
	for p in rig.st.players:
		t.eq(p.status, &"ok", "%s is on their feet at home" % p.id)
		if p.id == "p2":
			t.eq(_cell(rig.st.plan, p.body), _bunk_cell(ids, "p2"), "the one left behind wakes on their own bunk")
			t.check(not Run.in_car(rig.st.car, p.body), "p2 is not in the car")
		else:
			t.check(Run.in_car(rig.st.car, p.body), "%s rode up in the car" % p.id)
	var o0 := rig.st.orderly.body
	# Bed: each goes to their bunk holding F; BED_HOLD later they are in.
	var lights := rig.until_event("lightsOut", 30.0)
	if not t.check(not lights.is_empty(), "lights never went out"):
		return
	var in_at := {}
	for e in rig.events:
		if e["type"] == "bed" and bool(e["inBed"]):
			in_at[e["playerId"]] = float(e["t"])
	t.eq(in_at.size(), 3, "everyone lay down")
	t.eq((lights["assisted"] as Array).size(), 0, "nobody was still up")
	var all_in := 0.0
	for id: String in in_at:
		all_in = maxf(all_in, float(in_at[id]))
	t.check(absf(float(lights["t"]) - all_in) < 1e-6, "lights out the moment everyone is in")
	var o1 := rig.st.orderly.body
	t.check(o1.x == o0.x and o1.z == o0.z and rig.st.orderly.mode == &"dormant", "something moved at home")
	var morning := rig.until_event("newDay", Day.LIGHTS_OUT_SECONDS + 1.0)
	if not t.check(not morning.is_empty(), "no morning"):
		return
	t.check(absf(float(morning["t"]) - float(lights["t"]) - Day.LIGHTS_OUT_SECONDS) <= DayRigLib.DT + 1e-6, "the morning comes LIGHTS_OUT_SECONDS after lights out")
	t.eq(rig.st.seed, "day-a:day2", "day 2's seed")
	t.eq(rig.st.day_index, 2, "day index 2")
	t.eq(rig.st.day_state.day, 2, "day 2")
	t.eq(rig.st.depth, 1, "day 2 starts at depth 1")
	t.eq(rig.st.phase, &"arriving", "the doors are about to open")
	var want := Places.generate("day-a:day2", 1, rig.st.deck)
	t.eq(Floor.hash_plan(rig.st.plan), Floor.hash_plan(want), "day 2's floor 1 is made from day 2's seed")
	t.check(Floor.hash_plan(rig.st.plan) != day1_hash, "day 2's floor 1 is day 1's")
	t.check(rig.st.day_result == null, "the day's facts are cleared in the morning")
	for p in rig.st.players:
		t.check(Run.in_car(rig.st.car, p.body) and p.status == &"ok", "%s wakes in the car" % p.id)
	for id in DayRigLib.all_tape_ids(rig.st):
		t.check(not day1_tapes.has(id), "day 2 reuses tape id %s" % id)
	t.note("day 1 banked %d of %d (%s); home at %.2f s, lights out at %.2f s, day 2 on %s at %.2f s" % [
		int(ended["banked"]), quota, ended["kind"], float(up["t"]), float(lights["t"]), rig.st.seed, float(morning["t"])])

func test_after_a_wipe_everyone_wakes_on_a_bunk(t: T) -> void:
	var ids := _ids(3)
	var rig := DayRigLib.DayRig.new("day-wipe", ids)
	if not t.check(rig.until(func(s: Run.RunState) -> bool: return s.phase == &"away", 60.0), "never away"):
		return
	rig.st = _all_caught(DayRigLib.give(rig.st, "p1", 80.0, "fx-w"))
	var wiped := rig.until_event("wiped", 1.0)
	if not t.check(not wiped.is_empty(), "no wipe"):
		return
	var ended: Dictionary = _last(rig.events, "dayEnded").get("result", {})
	t.eq(int(ended.get("banked", -1)), 0, "a wipe banks nothing")
	t.eq(String(ended.get("kind", "")), "missed", "a wipe is a missed day")
	var up := rig.until_event("rodeUp", Run.RIDE_UP_TIME + 1.0)
	if not t.check(not up.is_empty(), "never home after the wipe"):
		return
	for p in rig.st.players:
		t.eq(p.status, &"ok", "%s is on their feet" % p.id)
		t.eq(_cell(rig.st.plan, p.body), _bunk_cell(ids, p.id), "%s wakes on their own bunk" % p.id)
		t.check(not p.aboard, "%s is not in the car" % p.id)
	t.check(DayRigLib.held(rig.st).is_empty(), "the tapes held at the wipe came home")
	for id in ids:
		rig.to_bed[id] = false
	t.check(rig.until(func(st: Run.RunState) -> bool: return st.phase == &"night", 20.0), "the empty car never shut for the night")
	t.note("wiped at %.2f s; home at %.2f s, everyone on their own bunk" % [float(wiped["t"]), float(up["t"])])

## A crew at home, standing (nobody in bed yet).
static func _home(seed: String, n: int) -> DayRigLib.DayRig:
	var rig := DayRigLib.DayRig.new(seed, _ids(n))
	for id in rig.ids:
		rig.to_bed[id] = false
	rig.until(func(s: Run.RunState) -> bool: return s.phase == &"night", 300.0)
	return rig

func test_the_bedtime_count_cannot_be_stopped(t: T) -> void:
	var rig := _home("day-count", 3)
	if not t.check(rig.st.phase == &"night", "never home"):
		return
	rig.to_bed["p0"] = true
	rig.to_bed["p1"] = true
	var count := rig.until_event("bedCount", 10.0)
	if not t.check(not count.is_empty(), "the count never started with two of three in bed"):
		return
	var starts := float(count["t"])
	t.check(absf(float(count["lightsOutAt"]) - starts - Day.LIGHTS_OUT_DELAY) < 1e-6, "lights out LIGHTS_OUT_DELAY after the count starts")
	# p1 gets up (lets go of F, presses again): the count goes on.
	rig.use["p1"] = false
	rig.step()
	rig.use["p1"] = true
	var out := rig.until_event("bed", 2.0)
	t.check(not out.is_empty() and out["playerId"] == "p1" and not bool(out["inBed"]), "p1 did not get up with a new press: %s" % str(out))
	t.check(not rig.st.bed.in_bed.has("p1"), "p1 still in bed")
	# Holding on does not put them back: they must let go first.
	for _k in roundi(2.0 * Run.BED_HOLD / DayRigLib.DT):
		rig.step()
	t.check(not rig.st.bed.in_bed.has("p1"), "p1 went back to bed without letting go of F")
	var lights := rig.until_event("lightsOut", Day.LIGHTS_OUT_DELAY + 1.0)
	if not t.check(not lights.is_empty(), "lights never went out"):
		return
	t.check(absf(float(lights["t"]) - starts - Day.LIGHTS_OUT_DELAY) <= DayRigLib.DT + 1e-6, "lights out at %.2f, the count started at %.2f" % [float(lights["t"]), starts])
	t.eq(Array(lights["assisted"]), ["p1", "p2"], "the ones still up are assisted to bed")
	t.check(not rig.until_event("newDay", Day.LIGHTS_OUT_SECONDS + 1.0).is_empty(), "no morning after the count")
	t.eq(rig.st.day_index, 2, "day 2")
	t.note("count from %.2f s, p1 got up, lights out at %.2f s regardless" % [starts, float(lights["t"])])

func test_f_at_the_windows_and_the_kiosk_does_nothing(t: T) -> void:
	var rig := _home("day-windows", 2)
	if not t.check(rig.st.phase == &"night", "never home"):
		return
	var spots: Array[Vector2i] = Prison.window_positions()
	spots.append(Prison.kiosk_position())
	var wallets := rig.st.wallets
	var events := 0
	for cell in spots:
		t.check(Prison.station_at(cell) != &"", "%s is a station" % str(cell))
		var b := Move.body_at_cell(rig.st.plan, Floor.Pos.make(0, cell.x, cell.y))
		for _k in roundi(3.0 / DayRigLib.DT):
			var inputs: Array[Run.PlayerInput] = []
			for id in rig.ids:
				var inp := Run.PlayerInput.make(id, b, 1.65, 0.0, 0.0, 90.0, 70.0)
				inp.use = true
				inp.pick_up = true
				inp.call = true
				inputs.append(inp)
			var r := Run.step_run(rig.st, inputs, DayRigLib.DT)
			events += r.events.size()
			rig.st = r.state
	t.check(rig.st.bed.in_bed.is_empty(), "someone lay down at a window")
	t.eq(rig.st.phase, &"night", "the night goes on")
	t.check(rig.st.wallets == wallets, "the wallets changed")
	t.eq(events, 0, "events at the windows and the kiosk")

func test_no_tape_is_banked_twice_or_from_the_floor(t: T) -> void:
	var days := 6 if t.quick else (200 if t.full else 40)
	var ids := _ids(3)
	var rig := DayRigLib.DayRig.new("day-tapes", ids)
	var rng := Rng.make_rng("day-tapes")
	var banked_ever := {}
	var floor_ever := {}
	var banks := 0
	var wipes := 0
	var total := 0
	var k := 0
	for d in days:
		var wipe := rng.chance(0.25)
		for id in ids:
			rig.vote[id] = "out" if (id != "p0" and rng.chance(0.25)) else "bank"
		var want_phase := &"away" if wipe else &"boarding"
		if not t.check(rig.until(func(s: Run.RunState) -> bool: return s.phase == want_phase, 200.0), "day %d: the car never came" % d):
			return
		var s := rig.st
		for id in ids:
			if rng.chance(0.7):
				k += 1
				s = DayRigLib.give(s, id, 10.0 + rng.next() * 200.0, "fx-%d" % k)
		if rng.chance(0.6):
			k += 1
			s = DayRigLib.drop(s, "fx-floor-%d" % k, 50.0, Run.car_body(s.car, -1.5, 0.0))
		if wipe:
			s = _all_caught(s)
		rig.st = s
		var held_now := DayRigLib.held(s)
		for id: String in DayRigLib.on_floor(s):
			floor_ever[id] = true
		var from := rig.events.size()
		var ended := rig.until_event("dayEnded", 30.0)
		if not t.check(not ended.is_empty(), "day %d: never settled" % d):
			return
		for i in range(from, rig.events.size()):
			var e := rig.events[i]
			if e["type"] == "wiped":
				wipes += 1
				t.eq(int(ended["result"]["banked"]), 0, "day %d: a wipe banks nothing" % d)
			if e["type"] != "banked":
				continue
			banks += 1
			var sm: Run.RunSummary = e["summary"]
			for id in sm.tapes:
				t.check(not banked_ever.has(id), "day %d: tape %s banked twice" % [d, id])
				t.check(not floor_ever.has(id), "day %d: tape %s banked from the floor" % [d, id])
				t.check(held_now.has(id) and rig.vote[held_now[id]] == "bank", "day %d: tape %s was not held by anyone aboard" % [d, id])
				banked_ever[id] = true
			for id: String in held_now:
				if rig.vote[held_now[id]] == "bank":
					t.check(sm.tapes.has(id), "day %d: tape %s aboard was not banked (held by %s; banked %s)" % [d, id, held_now[id], str(sm.tapes)])
			t.eq(int(ended["result"]["banked"]), floori(sm.total), "day %d: settled on the floored total" % d)
			total += int(ended["result"]["banked"])
		if not t.check(not rig.until_event("newDay", 120.0).is_empty(), "day %d: no next morning" % d):
			return
		t.eq(rig.st.seed, Run.day_seed("day-tapes", d + 2), "day %d: the next day's seed" % d)
	t.check(t.quick or (banks > 0 and wipes > 0), "not vacuous: %d banks, %d wipes" % [banks, wipes])
	t.note("%d days: %d banks (%d tapes, %d credits in all), %d wipes, %d tapes left on floors, none banked" % [days, banks, banked_ever.size(), total, wipes, floor_ever.size()])
