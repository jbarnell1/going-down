# The Minder's hunt from the owner's playtest of 19 Nov (PT1; sim/seek.gd "PT1", sim/run.gd minder_hunt). Each
# point is proved with the flag on and, as the control, off (every stored result has it off):
#   1. The instrument: with the flag on, a ticking instrument in a hide within 5 m of the searching Minder is
#      never a reason, and a whole stretch of search with ticking is tick for tick the same as one without.
#      Off: the same tick gives the "tick" reason, as before.
#   2. Anger: on, 1 s of sprinting fills the bar and one noise adds 55 in 100 (two noises fill it, even a few
#      seconds apart); the host's
#      minder.anger_sprint and minder.anger_noise still set them. Off: 2 s, 34 in 100, three noises.
#   3. Health: on, walking and sprinting drain only while it searches (after the time to hide, until the count
#      ends); never in the time to hide, the calm or between counts; standing, creeping and hiding give back;
#      nothing in a ride; 0 is down. Off: drains outside counts after the first one, never in the search.
#   4. The flag: off unless asked, the new last parameter of HostRules; the run hands it to the seek state.
extends RefCounted

const T = preload("res://tests/t.gd")
const Seek = preload("res://sim/seek.gd")
const Run = preload("res://sim/run.gd")
const Move = preload("res://sim/move.gd")
const Floor = preload("res://sim/floor.gd")
const Playroom = preload("res://sim/playroom.gd")
const Places = preload("res://sim/places.gd")
const Settings = preload("res://sim/settings.gd")
const M = preload("res://sim/jsmath.gd")
const HostRules = preload("res://net/host_rules.gd")
const PS = preload("res://tests/prop_seek.gd")
const CR = preload("res://tests/prop_count_run.gd")

const DT := 0.05
const TEPS := 1e-6

# The owner's numbers (19 Nov), restated, not imported.
const O_HUNT_SPRINT := 1.0
const O_HUNT_NOISE := 0.55
## "Two noises a few seconds apart fill the bar" (the orchestrator, 19 Nov).
const O_NOISE_GAP := 3.0
const O_OLD_SPRINT := 2.0
const O_WALK := 3.0
const O_SPRINT := 8.0
const O_REST := 1.0
const O_HIDE := 6.0

## A seek state on floor `i` of prop_seek's floors, stepped with its own clock and an optional host tuning.
class Sk:
	var s: Seek.SeekState
	var tuning: Settings.Values = null
	var events: Array[Dictionary] = []
	func step(inputs: Array[Seek.SeekInput], fl: Seek.FloorInput = null) -> Array[Dictionary]:
		var r := Seek.step_seek(s, inputs, DT, fl, tuning)
		s = r.state
		events.append_array(r.events)
		return r.events
	func run(inputs: Array[Seek.SeekInput], secs: float, fl: Seek.FloorInput = null) -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		for _k in roundi(secs / DT):
			out.append_array(step(inputs, fl))
		return out

static func sk(i: int, ids: Array[String], tuned: bool, hunt: bool) -> Sk:
	var f := PS.floor_of(i)
	var k := Sk.new()
	k.s = Seek.create_seek(f.plan, ids, f.data)
	if tuned:
		k.s = Seek.tune(k.s)
	if hunt:
		k.s = Seek.with_hunt(k.s)
	return k

static func of_type(evs: Array[Dictionary], ty: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in evs:
		if e["type"] == ty:
			out.append(e)
	return out

## The walkway spot (no squeaker under it, with an open neighbour cell) furthest from the Minder now, and that
## neighbour: [a, b], to walk to and fro between.
static func far_pair(k: Sk, i: int) -> Array:
	var f := PS.floor_of(i)
	var mb := k.s.minder.body
	var best: Array = []
	var best_d := -1.0
	for c in f.walkway:
		if f.squeak.has(Floor.pos_index(f.plan, c)):
			continue
		for d: Vector2i in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]:
			var nb := Floor.Pos.make(0, c.x + d.x, c.y + d.y)
			if Floor.cell_at(f.plan, 0, nb.x, nb.y) != Floor.CORRIDOR or not Floor.can_step(f.plan, c, nb) or f.squeak.has(Floor.pos_index(f.plan, nb)):
				continue
			var b := PS.cell_body(f.plan, c)
			var dd := M.hypot2(b.x - mb.x, b.z - mb.z)
			if dd > best_d:
				best_d = dd
				best = [b, PS.cell_body(f.plan, nb)]
			break
	return best

## One tick's input for `id` walking to and fro between a and b at `gait` (moving every tick).
static func pace(id: String, pair: Array, n: int, gait: StringName) -> Seek.SeekInput:
	return PS.inp(id, pair[n % 2], gait)

static func gone(id: String, b: Move.Body) -> Seek.SeekInput:
	var g := PS.inp(id, b)
	g.active = false
	return g

## A canonical string of a state's Minder and its players, to compare two runs tick for tick.
static func canon_state(s: Seek.SeekState) -> String:
	var m := s.minder
	var out := "%.9f %.9f %d %.9f %s %s %s %d %d %d|" % [m.body.x, m.body.z, m.body.level, m.yaw, m.mode, m.anim, m.goal_kind, m.goal_id, m.draw_hide, m.look_hide]
	for p in s.players:
		out += "%s %s %s %d %.9f %.9f;" % [p.id, p.status, p.phase, p.hide, p.sight, p.health]
	return out + str(s.reasons)

# ---------------------------------------------------------------------------------------------
# 1. The instrument is never a reason.

## Floor i: player "a" gets into a hide before any count; "x" starts a count and leaves; once the search is on,
## the Minder is set at the hide's front spot. Returns [k, hide] with the state at that moment, or [] when the
## floor gives no usable hide.
static func ticking_setup(i: int, hunt: bool) -> Array:
	var f := PS.floor_of(i)
	var k := sk(i, ["a", "x"], false, hunt)
	var pair := far_pair(k, i)
	var hide: Playroom.Hide = null
	for h in f.hide_list:
		if h.level == 0 and h.capacity >= 1:
			hide = h
			break
	if hide == null:
		return []
	var front := PS.pt(f.plan, hide.front, hide.level)
	var u := PS.inp("a", front)
	u.use = true
	k.step([u, PS.inp("x", pair[0])])
	k.run([PS.inp("a", front), PS.inp("x", pair[0])], 2.0)
	if Seek.player_of(k.s, "a").phase != &"inside":
		return []
	k.step([PS.inp("a", front), PS.inp("x", pair[0], &"sprint")])
	if not k.s.counting:
		return []
	while Seek.phase_of(k.s) != &"seek":
		k.step([PS.inp("a", front), gone("x", pair[0])])
	var m := k.s.minder
	m.body = Seek.hide_front_body(f.plan, hide)
	m.path = []
	m.goal_kind = &""
	m.goal_cell = null
	return [k, hide]

func test_the_instrument_is_never_a_reason(t: T) -> void:
	var floors := 3 if t.quick else 8
	var tried := 0
	for i in floors:
		var on := ticking_setup(i, true)
		var off := ticking_setup(i, false)
		if on.is_empty() or off.is_empty():
			continue
		tried += 1
		var hide: Playroom.Hide = on[1]
		var front := PS.pt(PS.floor_of(i).plan, hide.front, hide.level)
		var tick_in := PS.inp("a", front)
		tick_in.ticking = true
		# Off (the control): the very first tick within 5 m gives the "tick" reason.
		var ko: Sk = off[0]
		var oevs := ko.step([tick_in, gone("x", front)])
		var oreason := of_type(oevs, "reason")
		t.check(oreason.size() == 1 and oreason[0]["why"] == "tick" and int(oreason[0]["hide"]) == hide.id,
			"floor %d off: ticking in hide %d with the Minder at its front is a reason: %s" % [i, hide.id, str(oreason)])
		# On: never a "tick" reason, and ticking or not, the search is the same tick for tick.
		var k1: Sk = on[0]
		var k2 := Sk.new()
		k2.s = k1.s.copy()
		var quiet := PS.inp("a", front)
		var same := true
		var first_diff := ""
		var ticks := 0
		for _n in roundi(5.0 / DT):
			var e1 := k1.step([tick_in, gone("x", front)])
			var e2 := k2.step([quiet, gone("x", front)])
			ticks += 1
			for e in e1:
				if e["type"] == "reason" and e["why"] == "tick":
					same = false
					first_diff = "a tick reason at %.2f s" % k1.s.t
			if same and (str(e1) != str(e2) or canon_state(k1.s) != canon_state(k2.s)):
				same = false
				first_diff = "tick %d: %s / %s" % [ticks, canon_state(k1.s), canon_state(k2.s)]
			if not same or not k1.s.counting:
				break
		t.check(same, "floor %d on: ticking in hide %d changed nothing the Minder does (%s)" % [i, hide.id, first_diff])
	t.check(tried >= 2, "the instrument was tried on %d floors" % tried)
	t.note("%d floors: off, a ticking instrument within 5 m is a reason; on, 5 s of search are the same with or without it" % tried)

# ---------------------------------------------------------------------------------------------
# 2. Anger.

## Seconds of sprinting in place from an empty bar to the count, or -1.
static func sprint_secs(i: int, hunt: bool, tuning: Settings.Values) -> float:
	var k := sk(i, ["a"], true, hunt)
	k.tuning = tuning
	var pair := far_pair(k, i)
	k.run([PS.inp("a", pair[0])], 0.5)
	var t0 := k.s.t
	for _n in 200:
		if not of_type(k.step([PS.inp("a", pair[0], &"sprint")]), "count").is_empty():
			return k.s.t - t0
	return -1.0

## Emotes `gap` seconds of quiet apart (0: consecutive ticks) until a count starts (at most 5): how many.
static func noises_to_count(i: int, hunt: bool, tuning: Settings.Values, gap: float = 0.0) -> int:
	var k := sk(i, ["a"], true, hunt)
	k.tuning = tuning
	var pair := far_pair(k, i)
	k.run([PS.inp("a", pair[0])], 0.5)
	var em := PS.inp("a", pair[0])
	em.emote_sound = true
	for n in 5:
		if not of_type(k.step([em]), "count").is_empty():
			return n + 1
		if not of_type(k.run([PS.inp("a", pair[0])], gap), "count").is_empty():
			return -1
	return -1

func test_anger_fills_sooner(t: T) -> void:
	var floors := 2 if t.quick else 5
	for i in floors:
		var on := sprint_secs(i, true, null)
		var off := sprint_secs(i, false, null)
		t.check(absf(on - O_HUNT_SPRINT) <= DT + TEPS, "floor %d on: a sprint filled the bar in %.2f s, want %.1f" % [i, on, O_HUNT_SPRINT])
		t.check(absf(off - O_OLD_SPRINT) <= DT + TEPS, "floor %d off: a sprint filled the bar in %.2f s, want %.1f" % [i, off, O_OLD_SPRINT])
		t.eq(noises_to_count(i, true, null), 2, "floor %d on: two noises start the count" % i)
		t.eq(noises_to_count(i, true, null, O_NOISE_GAP), 2, "floor %d on: two noises %.0f s apart start the count" % [i, O_NOISE_GAP])
		t.eq(noises_to_count(i, false, null), 3, "floor %d off: three noises start the count" % i)	# The host's numbers still rule when set, flag or no flag.
	for v: float in [0.5, 2.0, 3.0]:
		var got := sprint_secs(0, true, Settings.make({&"minder.anger_sprint": v}))
		t.check(absf(got - v) <= DT + TEPS, "on, minder.anger_sprint = %.1f: filled in %.2f s" % [v, got])
	t.eq(noises_to_count(0, true, Settings.make({&"minder.anger_noise": 34.0})), 3, "on, minder.anger_noise = 34: three noises")
	t.eq(noises_to_count(0, true, Settings.make({&"minder.anger_noise": 100.0})), 1, "on, minder.anger_noise = 100: one noise")
	# The rule's own numbers.
	t.eq(Seek.anger_gain(&"emote", DT, null, true), O_HUNT_NOISE, "on: one noise adds 55 in 100")
	t.eq(Seek.anger_gain(&"sprint", DT, null, true), DT / O_HUNT_SPRINT, "on: a tick of sprint adds DT / 1 s")
	t.eq(Seek.anger_gain(&"squeaker", DT, null, true), Seek.anger_gain(&"squeaker", DT, null, false), "on: a squeaker tile is as before")
	t.eq(Seek.anger_gain(&"emote", DT, null), Seek.anger_gain(&"emote", DT, null, false), "off: the untuned lump unchanged")
	t.note("on: 1 s of sprint or 2 noises; off: 2 s or 3; the host's minder.anger_sprint and minder.anger_noise still apply")

# ---------------------------------------------------------------------------------------------
# 3. Health.

## Floor i, untuned (6 s to hide, then the search): "w" paces far from the Minder; "x" starts a count and leaves.
## Returns {name: health change} over each stretch. `k` is left in the calm after the count.
static func health_script(i: int, hunt: bool) -> Dictionary:
	var k := sk(i, ["w", "x"], false, hunt)
	var pair := far_pair(k, i)
	var out := {}
	var n := [0]
	var stretch := func(name: String, gait: StringName, secs: float, fl: Seek.FloorInput = null) -> void:
		var h0 := Seek.player_of(k.s, "w").health
		for _j in roundi(secs / DT):
			n[0] += 1
			k.step([pace("w", pair, n[0], gait), gone("x", pair[0])], fl)
		out[name] = Seek.player_of(k.s, "w").health - h0
	# Before any count: walking (health is full).
	stretch.call("before", &"walk", 1.0)
	# x starts the count; w walks through the time to hide.
	k.step([PS.inp("w", pair[0]), PS.inp("x", pair[0], &"sprint")])
	out["counting"] = k.s.counting
	stretch.call("hide_walk", &"walk", 3.0)
	stretch.call("hide_sprint", &"sprint", 2.0)
	while Seek.phase_of(k.s) != &"seek":
		k.step([PS.inp("w", pair[0]), gone("x", pair[0])])
	# The search: the Minder starts far away (the furthest walkway cell), so w is not found in these 3 s.
	stretch.call("seek_walk", &"walk", 1.0)
	stretch.call("seek_sprint", &"sprint", 1.0)
	stretch.call("seek_creep", &"creep", 0.5)
	out["found"] = Seek.player_of(k.s, "w").status != &"ok"
	# w leaves the floor for the rest of the count (not hunted, nothing changes).
	while k.s.counting:
		k.step([gone("w", pair[0]), gone("x", pair[0])])
	# The calm after it, and between counts.
	stretch.call("calm_walk", &"walk", 1.0)
	stretch.call("calm_sprint", &"sprint", 1.0)
	var h0 := Seek.player_of(k.s, "w").health
	k.run([PS.inp("w", pair[0]), gone("x", pair[0])], 1.0)
	out["calm_stand"] = Seek.player_of(k.s, "w").health - h0
	stretch.call("ride_walk", &"walk", 1.0, PS.flin(false, "", false, true))
	h0 = Seek.player_of(k.s, "w").health
	k.run([PS.inp("w", pair[0]), gone("x", pair[0])], 1.0, PS.flin(false, "", false, true))
	out["ride_stand"] = Seek.player_of(k.s, "w").health - h0
	return out

static func near(a: Variant, b: float) -> bool:
	return absf(float(a) - b) < 1e-9

func test_health_drains_only_while_it_hunts(t: T) -> void:
	var floors := 2 if t.quick else 5
	for i in floors:
		var on := health_script(i, true)
		var off := health_script(i, false)
		var tag := "floor %d" % i
		t.check(bool(on["counting"]) and bool(off["counting"]) and not bool(on["found"]) and not bool(off["found"]), "%s: the count ran and w stayed unfound: %s / %s" % [tag, str(on), str(off)])
		# On.
		t.check(near(on["before"], 0.0) and near(on["hide_walk"], 0.0) and near(on["hide_sprint"], 0.0), "%s on: nothing before the count or in the time to hide: %s" % [tag, str(on)])
		t.check(near(on["seek_walk"], -O_WALK) and near(on["seek_sprint"], -O_SPRINT) and near(on["seek_creep"], O_REST * 0.5),
			"%s on: while it searches, walk -3/s, sprint -8/s, creep +1/s: %s" % [tag, str(on)])
		t.check(near(on["calm_walk"], 0.0) and near(on["calm_sprint"], 0.0) and near(on["calm_stand"], O_REST),
			"%s on: in the calm walking and sprinting cost nothing, standing gives back 1/s: %s" % [tag, str(on)])
		t.check(near(on["ride_walk"], 0.0) and near(on["ride_stand"], 0.0), "%s on: nothing in a ride: %s" % [tag, str(on)])
		# Off: the old rule, as every stored result has it.
		t.check(near(off["before"], 0.0) and near(off["hide_walk"], 0.0) and near(off["seek_walk"], 0.0) and near(off["seek_sprint"], 0.0) and near(off["seek_creep"], 0.0),
			"%s off: nothing before the first count or in it: %s" % [tag, str(off)])
		t.check(near(off["calm_walk"], -O_WALK) and near(off["calm_sprint"], -O_SPRINT) and near(off["calm_stand"], O_REST) and near(off["ride_walk"], 0.0),
			"%s off: after the first count walk -3/s, sprint -8/s, stand +1/s, nothing in a ride: %s" % [tag, str(off)])
	# On: 0 is down, while it searches.
	var k := sk(0, ["w", "x"], false, true)
	var pair := far_pair(k, 0)
	k.step([PS.inp("w", pair[0]), PS.inp("x", pair[0], &"sprint")])
	while Seek.phase_of(k.s) != &"seek":
		k.step([PS.inp("w", pair[0]), gone("x", pair[0])])
	Seek.player_of(k.s, "w").health = 0.3
	var down := false
	for n in 10:
		for e in k.step([pace("w", pair, n, &"sprint"), gone("x", pair[0])]):
			down = down or (e["type"] == "down" and e["playerId"] == "w")
	t.check(down and Seek.player_of(k.s, "w").status == &"down", "on: sprinting to 0 in the search puts them down")
	t.note("on: walk -3/s and sprint -8/s only while it searches; off: after the first count, outside counts")

# ---------------------------------------------------------------------------------------------
# 4. The flag.

func test_the_flag_is_off_unless_asked(t: T) -> void:
	# The rooms' old positional call (37 parameters, annex_drag last) still builds, with the flag off.
	var old := HostRules.new(true, 4, Places.FULL, false, false, false, false, false, false, false, false, false, true, false, false, false, false, false, false,
		false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false)
	t.check(not old.minder_hunt, "HostRules with 37 parameters: the hunt is off")
	var st_old := old.prepare(Run.create_run("hunt-run", ["p0"] as Array[String], Places.FULL))
	t.check(st_old.playroom_tuned and not st_old.minder_hunt, "off unless asked (tuned Playroom on, hunt off)")
	var rules := HostRules.new(true, 4, Places.FULL, false, false, false, false, false, false, false, false, false, true, false, false, false, false, false, false,
		false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, true)
	var st := rules.prepare(Run.create_run("hunt-run", ["p0"] as Array[String], Places.FULL))
	t.check(rules.minder_hunt and st.minder_hunt, "the new last parameter turns it on")
	# The run hands it to the floor's seek state, and only then.
	var r := CR.Rig.new("hunt-flag-0")
	r.st = Run.with_minder_hunt(r.st)
	r.run(0.1)
	t.check(r.seek() != null and r.seek().hunt, "the run's seek state has the hunt")
	t.check(Run.with_minder_hunt(r.st).seek.hunt, "turned on with a seek state already made")
	var r0 := CR.Rig.new("hunt-flag-0")
	r0.run(0.1)
	t.check(r0.seek() != null and not r0.seek().hunt and not r0.st.minder_hunt, "off: the seek state has no hunt")
	t.check(not Seek.create_seek(PS.floor_of(0).plan, ["a"] as Array[String], PS.floor_of(0).data).hunt, "a new seek state has no hunt")
	t.check(Seek.with_hunt(Seek.create_seek(PS.floor_of(0).plan, ["a"] as Array[String], PS.floor_of(0).data)).copy().hunt, "the hunt survives a copy")
