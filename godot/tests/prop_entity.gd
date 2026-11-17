# The Orderly's design rules, by an independent oracle (ported from tests/sim/entity.test.ts; it
# shares nothing with sight.gd): it never moves or turns on a tick any bot could see it; it is never
# visible in two consecutive frames at different positions; looking saves you during a wind-up;
# it stays put for GRACE after the last sighting; and the squeak is heard before it can be seen.
# The counts must equal the golden counts for the same seeds (tests/golden/properties.json, written
# by npm run godot:golden; the first ones were proved equal to TypeScript's, property_counts.ts).
extends RefCounted

const T = preload("res://tests/t.gd")
const Snap = preload("res://tests/snap.gd")
const Plans = preload("res://tests/plans.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Entity = preload("res://sim/entity.gd")
const Bot = preload("res://sim/bot.gd")
const Rng = preload("res://sim/rng.gd")
const M = preload("res://sim/jsmath.gd")

const DT := 0.05
const H := 3.2  # storey height, restated here rather than imported
const ORACLE_STEP := 0.05
const ORACLE_POINTS: Array[float] = [1.7, 2.6]
const RUN_SECONDS := 75.0
const ORACLE_RANGE := 25.0

# The TRUE camera frustum: 70 degrees vertical, 16:9 (computed with JavaScript's tan and atan).
static var TRUE_V_HALF := 0.0
static var TRUE_H_HALF := 0.0

static func _static_init() -> void:
	TRUE_V_HALF = 35.0 * (PI / 180.0)
	TRUE_H_HALF = M.atan_js(M.tan_js(TRUE_V_HALF) * (16.0 / 9.0))

# =============================================================================================
# The oracle: samples the segment every 5 cm and applies the crossing rules read from floor.gd.

static func oracle_stair_top(plan: Floor.FloorPlan, ax: int, ay: int, bx: int, by: int) -> bool:
	for s in plan.stairs:
		var cells := Floor.stair_cells(s)
		var last := cells[s.length - 1]
		var tx := last.x + Floor.dir_dx(s.dir)
		var ty := last.y + Floor.dir_dy(s.dir)
		if (ax == last.x and ay == last.y and bx == tx and by == ty) or (bx == last.x and by == last.y and ax == tx and ay == ty):
			return true
	return false

static func oracle_edge(plan: Floor.FloorPlan, L: int, ax: int, ay: int, bx: int, by: int, lateral: float, h_above: float) -> bool:
	if oracle_stair_top(plan, ax, ay, bx, by):
		return L == 1
	var ka := Floor.cell_at(plan, L, ax, ay)
	var kb := Floor.cell_at(plan, L, bx, by)
	if Floor.can_step(plan, Floor.Pos.make(L, ax, ay), Floor.Pos.make(L, bx, by)):
		var ra := Floor.room_id_at(plan, L, ax, ay)
		var same_room := ra >= 0 and ra == Floor.room_id_at(plan, L, bx, by)
		var both_corr := ka == &"corridor" and kb == &"corridor"
		if same_room or both_corr or not Floor.has_door(plan, L, ax, ay, bx, by):
			return true
		return absf(lateral) <= 0.55 and h_above <= 2.1
	var hole_a := ka == &"atriumOpen" or ka == &"stair"
	if L == 1 and hole_a and ka == kb:
		return true
	if L == 1 and ((ka == &"atriumOpen" and kb == &"corridor") or (kb == &"atriumOpen" and ka == &"corridor")):
		return h_above > 1.1
	return false

static func _hole(plan: Floor.FloorPlan, cx: int, cy: int) -> bool:
	var k := Floor.cell_at(plan, 1, cx, cy)
	return k == &"atriumOpen" or k == &"stair"

static func oracle_los(plan: Floor.FloorPlan, fx: float, fy: float, fz: float, tx: float, ty: float, tz: float) -> bool:
	var cs := float(plan.cell_size)
	var dist := M.hypot3(tx - fx, ty - fy, tz - fz)
	var n := maxi(1, int(ceil(dist / ORACLE_STEP)))
	var px := fx
	var py := fy
	var pz := fz
	for i in range(1, n + 1):
		var t := float(i) / n
		var qx := fx + (tx - fx) * t
		var qy := fy + (ty - fy) * t
		var qz := fz + (tz - fz) * t
		var pcx := int(floor(px / cs))
		var pcy := int(floor(pz / cs))
		var qcx := int(floor(qx / cs))
		var qcy := int(floor(qz / cs))
		if (py >= H) != (qy >= H):
			if not _hole(plan, pcx, pcy) and not _hole(plan, qcx, qcy):
				return false
		if pcx != qcx or pcy != qcy:
			var mx := (px + qx) / 2.0
			var my := (py + qy) / 2.0
			var mz := (pz + qz) / 2.0
			var L := 1 if my >= H else 0
			var h_above := my - (H if L == 1 else 0.0)
			var ddx := absi(qcx - pcx)
			var ddy := absi(qcy - pcy)
			if ddx + ddy == 1:
				if not _pass(plan, L, pcx, pcy, qcx, qcy, mx, mz, h_above, cs):
					return false
			elif ddx == 1 and ddy == 1:
				var via_x := _pass(plan, L, pcx, pcy, qcx, pcy, mx, mz, h_above, cs) and _pass(plan, L, qcx, pcy, qcx, qcy, mx, mz, h_above, cs)
				var via_y := _pass(plan, L, pcx, pcy, pcx, qcy, mx, mz, h_above, cs) and _pass(plan, L, pcx, qcy, qcx, qcy, mx, mz, h_above, cs)
				if not via_x and not via_y:
					return false
			else:
				push_error("oracle step jumped more than one cell")
				return false
		px = qx
		py = qy
		pz = qz
	return true

static func _pass(plan: Floor.FloorPlan, L: int, ax: int, ay: int, bx: int, by: int, mx: float, mz: float, h_above: float, cs: float) -> bool:
	var lateral := mz - (ay + 0.5) * cs if ax != bx else mx - (ax + 0.5) * cs
	return oracle_edge(plan, L, ax, ay, bx, by, lateral, h_above)

## Inside the true camera frustum? Rotates into camera space (three.js YXZ), camera looks down -z.
static func oracle_in_frustum(v: Entity.PlayerView, px: float, py: float, pz: float) -> bool:
	var wx := px - v.body.x
	var wy := py - (v.body.y + v.eye)
	var wz := pz - v.body.z
	var c := M.cos_js(v.yaw)
	var s := M.sin_js(v.yaw)
	var x1 := wx * c - wz * s
	var z1 := wx * s + wz * c
	var cp := M.cos_js(v.pitch)
	var sp := M.sin_js(v.pitch)
	var y2 := wy * cp + z1 * sp
	var z2 := -wy * sp + z1 * cp
	var depth := -z2
	if depth <= 0.0:
		return false
	return M.atan2_js(absf(x1), depth) <= TRUE_H_HALF and M.atan2_js(absf(y2), depth) <= TRUE_V_HALF

static func oracle_sees(plan: Floor.FloorPlan, v: Entity.PlayerView, fig: Move.Body) -> bool:
	var ey := v.body.y + v.eye
	for h in ORACLE_POINTS:
		if oracle_in_frustum(v, fig.x, fig.y + h, fig.z) and oracle_los(plan, v.body.x, ey, v.body.z, fig.x, fig.y + h, fig.z):
			return true
	return false

## Could they see it if they turned to look straight at it? (Line of sight only.)
static func oracle_could_see(plan: Floor.FloorPlan, body: Move.Body, eye: float, fig: Move.Body) -> bool:
	for h in ORACLE_POINTS:
		if oracle_los(plan, body.x, body.y + eye, body.z, fig.x, fig.y + h, fig.z):
			return true
	return false

# =============================================================================================
# The property runs (entity.test.ts runOne).

class RunResult:
	var travelled := 0.0
	var seen_ticks := 0
	var oracle_checks := 0
	var oracle_seen_ticks := 0
	var violations := 0
	var frame_violations := 0
	var catches := 0
	var catches_while_watched := 0
	var grace_checks := 0
	var grace_violations := 0

static func run_one(i: int) -> RunResult:
	var seed := "orderly-%d" % i
	var depth := 1 + (i % 4)
	var n_bots := 1 + ((i / 4) % 4)
	var p := Plans.plan(seed, depth)
	var rng := Rng.make_rng(seed).fork("setup")
	var bots: Array[Bot.Bot] = []
	for b in n_bots:
		var oblivious := b == 0 and i % 3 == 0
		var w := rng.next()
		bots.append(Bot.create_bot(p, "bot%d" % b, "%s:%d" % [seed, b], w, oblivious, p.landing if b == 0 else null))
	var state := Entity.create_orderly(p)
	var start := state.body
	var r := RunResult.new()
	var prev_frame_seen := {}
	var wind_up_watched := {}
	var last_seen_at: Variant = null
	var ticks := int(round(RUN_SECONDS / DT))
	for tick in ticks:
		for b in bots:
			Bot.step_bot(p, b, DT, state.body)
		var views: Array[Entity.PlayerView] = []
		for b in bots:
			views.append(Bot.bot_view(b))
		var before := state
		var res := Entity.step_entity(p, before, views, DT)
		state = res.state
		var moved := state.body.x != before.body.x or state.body.z != before.body.z or state.body.y != before.body.y or state.body.level != before.body.level
		r.travelled += M.hypot2(state.body.x - before.body.x, state.body.z - before.body.z)
		if state.seen:
			r.seen_ticks += 1
		var oracle_seen := false
		var frame_seen := {}
		for v in views:
			var d := M.hypot3(v.body.x - before.body.x, v.body.y + v.eye - before.body.y - 1.7, v.body.z - before.body.z)
			if d > ORACLE_RANGE:
				continue
			r.oracle_checks += 1
			if oracle_sees(p, v, before.body):
				oracle_seen = true
			if moved and oracle_sees(p, v, state.body):
				frame_seen[v.id] = true
		if oracle_seen:
			r.oracle_seen_ticks += 1
			if moved or state.yaw != before.yaw:
				r.violations += 1
		if moved:
			for id: String in frame_seen:
				if prev_frame_seen.has(id):
					r.frame_violations += 1
		prev_frame_seen = {}
		for v in views:
			if M.hypot2(v.body.x - state.body.x, v.body.z - state.body.z) <= ORACLE_RANGE and oracle_sees(p, v, state.body):
				prev_frame_seen[v.id] = true
		for e in res.events:
			if e["type"] == "windUp":
				wind_up_watched[e["playerId"]] = false
		var any_caught := false
		for e in res.events:
			if e["type"] == "caught":
				any_caught = true
		if before.mode == &"windUp" or state.mode == &"windUp" or any_caught:
			for id: String in wind_up_watched.keys():
				for vv in views:
					if vv.id == id:
						if oracle_sees(p, vv, before.body):
							wind_up_watched[id] = true
						break
		for e in res.events:
			if e["type"] == "caught":
				r.catches += 1
				if wind_up_watched.get(e["playerId"], false):
					r.catches_while_watched += 1
				wind_up_watched.erase(e["playerId"])
			if e["type"] == "windUpCancelled":
				wind_up_watched.erase(e["playerId"])
		if last_seen_at != null and not state.seen and state.t - float(last_seen_at) < Entity.GRACE + 1e-9:
			r.grace_checks += 1
			if moved:
				r.grace_violations += 1
		if state.seen:
			last_seen_at = state.t
	r.travelled = maxf(r.travelled, M.hypot2(state.body.x - start.x, state.body.z - start.z))
	return r

static func counts(n: int) -> Dictionary:
	var c := {"runs": n, "oracleChecks": 0, "oracleSeenTicks": 0, "moving": 0, "seenRuns": 0, "catchRuns": 0, "catches": 0, "graceChecks": 0,
		"violations": 0, "frameViolations": 0, "catchesWhileWatched": 0, "graceViolations": 0}
	for i in n:
		var r := run_one(i)
		c["oracleChecks"] += r.oracle_checks
		c["oracleSeenTicks"] += r.oracle_seen_ticks
		c["moving"] += 1 if r.travelled > 5.0 else 0
		c["seenRuns"] += 1 if r.seen_ticks > 0 else 0
		c["catchRuns"] += 1 if r.catches > 0 else 0
		c["catches"] += r.catches
		c["graceChecks"] += r.grace_checks
		c["violations"] += r.violations
		c["frameViolations"] += r.frame_violations
		c["catchesWhileWatched"] += r.catches_while_watched
		c["graceViolations"] += r.grace_violations
	return c

## Runs per size (tools/property_counts.ts QUICK, SUB, FULL: entity and hear).
const SIZES := {"quick": {"entity": 4, "hear": 3}, "sub": {"entity": 24, "hear": 16}, "full": {"entity": 500, "hear": 104}}

## The golden counts of `key` at this run's size, as a Dictionary (empty while recording).
static func golden_counts(t: T, key: String) -> Dictionary:
	var g: Variant = t.golden("properties.json", "%s.%s" % [t.size_key(), key])
	return g if g is Dictionary else {}

func test_stillness_by_the_oracle(t: T) -> void:
	var n: int = SIZES[t.size_key()]["entity"]
	var c := counts(n)
	var frac := float(n) / 500.0
	t.eq(c["violations"], 0, "moved or turned while the oracle saw it")
	t.eq(c["frameViolations"], 0, "visible in two consecutive frames at two positions")
	t.eq(c["catchesWhileWatched"], 0, "caught someone who could see it during the wind-up")
	t.eq(c["graceViolations"], 0, "moved within GRACE of the last sighting")
	if not t.quick:
		t.check(c["oracleSeenTicks"] > 5000 * frac, "not vacuous: seen-ticks %d" % c["oracleSeenTicks"])
		t.check(float(c["moving"]) / n > 0.6 and float(c["seenRuns"]) / n > 0.6, "not vacuous: moving %d, seen %d of %d" % [c["moving"], c["seenRuns"], n])
		t.check(c["catchRuns"] > 10 * frac, "not vacuous: runs with a catch %d" % c["catchRuns"])
		t.check(c["graceChecks"] > 1000 * frac, "not vacuous: grace checks %d" % c["graceChecks"])
	var want := golden_counts(t, "entity")
	t.expect("properties.json", "%s.entity" % t.size_key(), c, "the counts")
	t.note("%d runs x 75 s: oracle checks %d, seen-ticks %d, moved >5 m %d, seen %d, runs with a catch %d (%d catches), grace ticks %d; violations %d/%d/%d/%d" % [
		n, c["oracleChecks"], c["oracleSeenTicks"], c["moving"], c["seenRuns"], c["catchRuns"], c["catches"], c["graceChecks"],
		c["violations"], c["frameViolations"], c["catchesWhileWatched"], c["graceViolations"]])
	if not want.is_empty():
		t.note("golden, same seeds: oracle checks %d, seen-ticks %d, moved %d, seen %d, catch runs %d (%d), grace %d" % [
			want["oracleChecks"], want["oracleSeenTicks"], want["moving"], want["seenRuns"], want["catchRuns"], want["catches"], want["graceChecks"]])

## Heard before seen: a listener at the landing facing away; the squeak (gain > 0.05) leads the first
## moment the oracle says it could be seen, and its coming within 12 m, by at least 1 s.
func test_heard_before_seen(t: T) -> void:
	var want := golden_counts(t, "hear")
	var n: int = SIZES[t.size_key()]["hear"]
	var leads: Array[float] = []
	var see_leads: Array[float] = []
	var plain_sight := 0
	var seen_ever := 0
	for i in n:
		var p := Plans.plan("hear-%d" % i, 1 + (i % 4))
		var me := Move.body_at_cell(p, p.landing)
		var st := Entity.create_orderly(p)
		st.mode = &"hunting"
		if oracle_could_see(p, me, Bot.BOT_EYE, st.body):
			plain_sight += 1
		var heard := -1.0
		var near := -1.0
		var seeable := -1.0
		var k := 0
		while k < 150.0 / DT and (near < 0.0 or seeable < 0.0):
			var yaw := M.atan2_js(-(me.x - st.body.x), -(me.z - st.body.z))
			var views: Array[Entity.PlayerView] = [Entity.PlayerView.make("me", me, Bot.BOT_EYE, yaw, 0.0, Bot.BOT_HFOV_DEG, Bot.BOT_VFOV_DEG, true)]
			st = Entity.step_entity(p, st, views, DT).state
			if st.seen:
				seen_ever += 1
			if heard < 0.0 and Entity.audibility(p, st, me, Bot.BOT_EYE).gain > 0.05:
				heard = st.t
			if seeable < 0.0 and oracle_could_see(p, me, Bot.BOT_EYE, st.body):
				seeable = st.t
			if near < 0.0 and M.hypot2(me.x - st.body.x, me.z - st.body.z) < 12.0 and st.body.level == me.level:
				near = st.t
			k += 1
		t.check(near > 0.0 and seeable > 0.0 and heard > 0.0, "hear-%d: near %s, seeable %s, heard %s" % [i, near, seeable, heard])
		leads.append(near - heard)
		see_leads.append(seeable - heard)
	var c := {"seeds": n, "minSeeLead": see_leads.min(), "medianSeeLead": _median(see_leads), "minNearLead": leads.min(), "medianNearLead": _median(leads), "plainSight": plain_sight, "seenEver": seen_ever}
	t.eq(seen_ever, 0, "seen by a listener facing away")
	t.eq(plain_sight, 0, "in plain sight of the landing at the start")
	t.check(float(c["minSeeLead"]) >= 1.0 and float(c["minNearLead"]) >= 1.0, "heard too late: %s" % str(c))
	t.expect("properties.json", "%s.hear" % t.size_key(), c, "the leads")
	t.note("%d seeds: hearing leads first possible sight by min %s s (median %s s), coming within 12 m by min %s s (median %s s)%s" % [
		n, M.to_fixed(c["minSeeLead"], 2), M.to_fixed(c["medianSeeLead"], 2), M.to_fixed(c["minNearLead"], 2), M.to_fixed(c["medianNearLead"], 2),
		"" if want.is_empty() else "; golden: min %s s / %s s" % [M.to_fixed(want["minSeeLead"], 2), M.to_fixed(want["minNearLead"], 2)]])

static func _median(xs: Array[float]) -> float:
	var s := xs.duplicate()
	s.sort()
	return s[s.size() / 2]
