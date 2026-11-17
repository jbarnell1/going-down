# Live settings, piece LS1 (docs/floors/live-settings.md section 7): the registry (sim/settings.gd), the run's
# tuning (sim/run.gd RunState.tuning) and the first ten settings the rules read. Proved here:
#   1. Every registry row: today's value is the game's (the constant this file names for it, with the rooms'
#      switches on), least <= today <= most, today lies on the step, the id is unique, the name is unique in
#      its section and at most 32 characters, it holds in one of the four kinds; 59 rows in the panel's groups;
#      exactly the ten LS1 rows are wired.
#   2. Settings.check refuses under least, over most, NaN, infinity, a string, an unknown id, fewest floors
#      above most and a shortest wait under 15 s (and the other pair rules); it accepts today's and a fair change.
#   3. Untuned is untouched: with the game's switches on, bot floors (Clinic, Annex and Playroom: the call, the
#      blackout, catches, downs, the count) with a null tuning, an empty one, and all ten set to today's value
#      give the same state and events on every tick.
#   4. The ten proofs, each at least, today's and most: the Orderly's and the Temp's metres in 5 s unwatched, lit
#      and in the blackout, follow their own speeds (and only their own); the Minder's search and run pace follow
#      theirs; over 500 call plans a set the wait lies within delay + floors x seconds for the set bounds and never
#      repeats a floor count, and in a run the car arrives when its plan said, whatever is changed during the wait;
#      "out" comes down.time after "downed" at 5, 10 and 60 s, and a player already down when it changes goes
#      out at the time their "downed" event gave.
#   5. Every wired id has a proof here (PROOFS): a slider can never be wired to nothing.
extends RefCounted

const T = preload("res://tests/t.gd")
const Settings = preload("res://sim/settings.gd")
const Run = preload("res://sim/run.gd")
const Entity = preload("res://sim/entity.gd")
const Seek = preload("res://sim/seek.gd")
const Stamina = preload("res://sim/stamina.gd")
const Instr = preload("res://sim/instrument.gd")
const Relocate = preload("res://sim/relocate.gd")
const Day = preload("res://sim/day.gd")
const Marks = preload("res://sim/marks.gd")
const Places = preload("res://sim/places.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Rng = preload("res://sim/rng.gd")
const Bot = preload("res://sim/bot.gd")
const M = preload("res://sim/jsmath.gd")
const HostRules = preload("res://net/host_rules.gd")
const Snap = preload("res://tests/snap.gd")
const CountRun = preload("res://tests/prop_count_run.gd")
const PropSeek = preload("res://tests/prop_seek.gd")

const DT := 0.05
const EPS := 1e-9

## The ten LS1 wires, in the registry's order.
const TEN: Array[StringName] = [&"orderly.speed", &"orderly.dark_speed", &"temp.speed", &"temp.dark_speed",
	&"minder.search_speed", &"minder.run_speed", &"lift.floors_min", &"lift.floors_max", &"lift.floor_time", &"down.time"]

## Every wired id's proof: the test in this file that measures the thing it changes.
const PROOFS := {
	&"orderly.speed": "test_orderly_and_temp_speeds_lit",
	&"orderly.dark_speed": "test_orderly_and_temp_speeds_in_the_blackout",
	&"temp.speed": "test_orderly_and_temp_speeds_lit",
	&"temp.dark_speed": "test_orderly_and_temp_speeds_in_the_blackout",
	&"minder.search_speed": "test_minder_search_and_run_pace",
	&"minder.run_speed": "test_minder_search_and_run_pace",
	&"lift.floors_min": "test_lift_wait_over_500_plans_and_in_a_run",
	&"lift.floors_max": "test_lift_wait_over_500_plans_and_in_a_run",
	&"lift.floor_time": "test_lift_wait_over_500_plans_and_in_a_run",
	&"down.time": "test_down_time",
}

## The game's value of every setting: the constant the game uses, with the rooms' switches on (paced, the long
## dark, the car waits: net/host_rules.gd). This table, not the registry, is the test's oracle.
static func game_values() -> Dictionary:
	return {
		&"resident.wind_up": Entity.WIND_UP_TIME,
		&"resident.rest": Entity.DORMANT_TIME,
		&"resident.wake_near": Entity.WAKE_DISTANCE,
		&"resident.wake_after": Entity.WAKE_TIMEOUT,
		&"reloc.rest": Relocate.REST,
		&"reloc.near_min": Relocate.NEAR_MIN,
		&"reloc.near_max": Relocate.NEAR_MAX,
		&"orderly.speed": Run.PACED_HUNT_SPEED,
		&"orderly.dark_speed": Run.PACED_BLACKOUT_HUNT_SPEED,
		# The Temp is stepped by the same call as the Orderly (sim/run.gd), at the same paced speeds.
		&"temp.speed": Run.PACED_HUNT_SPEED,
		&"temp.dark_speed": Run.PACED_BLACKOUT_HUNT_SPEED,
		&"minder.stroll": Seek.WANDER_SPEED,
		&"minder.search_speed": Seek.SEARCH_SPEED,
		&"minder.run_speed": Seek.RUN_SPEED,
		&"minder.hide_time": Seek.HIDE_TIME,
		&"minder.last_count": Seek.LAST_LENGTH,
		&"minder.calm": Seek.CALM_TIME,
		&"minder.sight": Seek.SIGHT_RANGE,
		&"minder.found_after": Seek.FOUND_TIME,
		&"lift.floors_min": float(Run.CALL_FLOORS_MIN),
		&"lift.floors_max": float(Run.CALL_FLOORS_MAX),
		&"lift.floor_time": Run.FLOOR_TIME,
		&"lift.false_stop": Run.FALSE_STOP_CHANCE * 100.0,
		&"lift.board": Run.BOARD_TIME_WAITS,
		&"lift.hold": Run.HOLD_LIMIT,
		&"lift.ride": Run.RIDE_TIME,
		&"dark.min": Run.LONG_BLACKOUT_MIN,
		&"dark.max": Run.LONG_BLACKOUT_MAX,
		&"dark.first_min": Run.LONG_BLACKOUT_FIRST_MIN,
		&"dark.first_max": Run.LONG_BLACKOUT_FIRST_MAX,
		&"dark.warning": Run.BLACKOUT_WARNING,
		&"player.walk": Stamina.WALK_SPEED,
		&"player.sprint": Stamina.SPRINT_SPEED,
		&"player.creep": Stamina.CREEP_SPEED,
		&"player.raised": Instr.RAISED_SPEED_CAP,
		&"stamina.tank": Stamina.PACED_SPRINT_SECONDS,
		&"stamina.refill_walk": Stamina.RECOVER_WALKING,
		&"stamina.refill_rest": Stamina.RECOVER_RESTING,
		&"stamina.winded": Stamina.WINDED_UNTIL * 100.0,
		&"down.time": Run.DOWN_TIME,
		&"heal.time": Run.HEAL_TIME,
		&"heal.reach": Run.HEAL_REACH,
		&"down.crawl": Run.CRAWL_SPEED,
		&"heal.quiet": Run.HEAL_QUIET,
		&"health.walk": Seek.WALK_DRAIN,
		&"health.sprint": Seek.SPRINT_DRAIN,
		&"health.rest": Seek.REST_GAIN,
		&"heal.health": Run.HEAL_HEALTH,
		&"quota.each": float(Run.QUOTA_PER_PLAYER),
		&"quota.step": Run.QUOTA_DEPTH_STEP,
		&"pay.step": Run.DEPTH_PAY_STEP,
		&"record.reach": Instr.RECORD_RANGE,
		&"record.rate": Instr.RATE_NEAR,
		&"day.first": Day.START_HALVES / 2.0,
		&"day.lights_out": Day.LIGHTS_OUT_DELAY,
		&"marks.pad": float(Marks.DEFAULT_PAD),
		&"hide.in_slow": Seek.IN_SLOW,
		&"hide.in_fast": Seek.IN_FAST,
		&"hide.reach": Seek.HIDE_REACH,
	}

## All ten LS1 settings at today's value (the "all at today's" tuning).
static func ten_at_today() -> Dictionary:
	var out := {}
	for id in TEN:
		out[id] = Settings.today(id)
	return out

# ---------------------------------------------------------------------------------------------
# 1. The registry.

func test_registry_rows(t: T) -> void:
	var game := game_values()
	var rows := Settings.list()
	t.eq(rows.size(), 59, "rows in the registry")
	var ids := {}
	var names := {}
	var by_group := {}
	var sections := {}
	for sec in Settings.sections():
		sections[sec["id"]] = sec["group"]
	var groups := {}
	for g in Settings.groups():
		groups[g["id"]] = true
	var last_group := -1
	var group_order: Array = []
	for g in Settings.groups():
		group_order.append(g["id"])
	for s in rows:
		var tag := String(s.id)
		t.check(not ids.has(s.id), "%s: the id is listed twice" % tag)
		ids[s.id] = true
		var key := "%s/%s" % [s.section, s.name]
		t.check(not names.has(key), "%s: the name %s is used twice in its section" % [tag, s.name])
		names[key] = true
		t.check(s.name.length() <= 32 and not s.name.is_empty(), "%s: name %s is %d characters (at most 32)" % [tag, s.name, s.name.length()])
		t.check(sections.get(s.section, &"") == s.group and groups.has(s.group), "%s: section %s in group %s" % [tag, s.section, s.group])
		t.check(Settings.HOLDS_SHOWN.has(s.holds), "%s: holds %s" % [tag, s.holds])
		t.check(game.has(s.id), "%s: the test's table does not name its game value" % tag)
		if game.has(s.id):
			t.check(absf(float(game[s.id]) - s.today) < 1e-9, "%s: today %s, the game's %s" % [tag, str(s.today), str(game[s.id])])
		t.check(s.lo <= s.today + EPS and s.today <= s.hi + EPS and s.lo < s.hi, "%s: %s <= today %s <= %s" % [tag, str(s.lo), str(s.today), str(s.hi)])
		t.check(s.step > 0.0 and Settings.snap(s.id, s.today) == s.today, "%s: today %s is on the step %s" % [tag, str(s.today), str(s.step)])
		t.check(Settings.snap(s.id, s.lo) == s.lo and Settings.snap(s.id, s.hi) == s.hi, "%s: least and most on the step" % tag)
		t.check(not s.whole or (roundf(s.today) == s.today and roundf(s.step) == s.step), "%s: a whole number with a whole step" % tag)
		t.check(Settings.check(s.id, s.today) == &"", "%s: today's value passes the check (%s)" % [tag, Settings.check(s.id, s.today)])
		t.check(Settings.row(s.id) == s and Settings.today(s.id) == s.today, "%s: row() and today() find it" % tag)
		# The panel's order: group by group, never back to an earlier group.
		var gi := group_order.find(s.group)
		t.check(gi >= last_group, "%s: out of the panel's group order" % tag)
		last_group = maxi(last_group, gi)
		by_group[s.group] = int(by_group.get(s.group, 0)) + 1
	for id: StringName in game:
		t.check(ids.has(id), "%s: in the test's table but not in the registry" % id)
	var wired: Array[StringName] = []
	for s in Settings.list(true):
		wired.append(s.id)
	t.check(wired == TEN, "the wired rows are exactly the ten of LS1, in order: %s" % str(wired))
	t.eq(by_group.get(&"residents", 0), 19, "residents")
	t.eq(by_group.get(&"lift", 0), 12, "the lift and the dark")
	t.eq(by_group.get(&"players", 0), 17, "players")
	t.eq(by_group.get(&"earning", 0), 8, "earning")
	t.eq(by_group.get(&"hiding", 0), 3, "hiding")
	t.eq(Settings.LIFT_DELAY_MIN, Run.CALL_START_DELAY_MIN, "the pair rule's start delay is the run's")
	t.check(Settings.pair_broken({}).is_empty(), "today's values keep every pair rule: %s" % Settings.pair_broken({}))
	t.eq(Settings.text(&"orderly.speed", 3.6), "3.60 M/S", "the panel's words")
	t.eq(Settings.text(&"lift.floors_min", 6.0), "6 FLOORS", "the panel's words")
	t.note("%d rows: %s; wired: %d" % [rows.size(), str(by_group), wired.size()])

# ---------------------------------------------------------------------------------------------
# 2. The checker.

func test_check_refuses_and_accepts(t: T) -> void:
	var refused := [
		["under least", &"orderly.speed", 2.35, {}, &"range"],
		["over most", &"orderly.speed", 4.85, {}, &"range"],
		["NaN", &"down.time", NAN, {}, &"range"],
		["infinity", &"down.time", INF, {}, &"range"],
		["minus infinity", &"down.time", -INF, {}, &"range"],
		["a string", &"down.time", "12", {}, &"range"],
		["a bool", &"down.time", true, {}, &"range"],
		["null", &"down.time", null, {}, &"range"],
		["an unknown id", &"orderly.sped", 3.6, {}, &"id"],
		["fewest floors above most", &"lift.floors_min", 13, {}, &"pair"],
		["fewest floors equal to most", &"lift.floors_max", 6, {}, &"pair"],
		["fewest above most already asked", &"lift.floors_max", 9, {&"lift.floors_min": 10.0}, &"pair"],
		["a shortest wait under 15 s", &"lift.floor_time", 2.0, {}, &"pair"],
		["a shortest wait under 15 s (fewer floors)", &"lift.floors_min", 3, {}, &"pair"],
		["a blackout's shortest over its longest", &"dark.min", 25.0, {}, &"pair"],
		["the first floor's shortest over its longest", &"dark.first_max", 13.0, {}, &"pair"],
		["arrives no nearer within 2 m of no further", &"reloc.near_min", 19.0, {}, &"pair"],
		["the instrument's cap at creep", &"player.raised", 1.2, {}, &"pair"],
		["sprint at walk", &"player.sprint", 3.5, {&"player.walk": 3.5}, &"pair"],
	]
	for r: Array in refused:
		var got := Settings.check(StringName(r[1]), r[2], r[3] as Dictionary)
		t.check(got == r[4], "%s: %s = %s gives %s, want %s" % [r[0], r[1], str(r[2]), got, r[4]])
	var accepted := [
		["today's", &"orderly.speed", 3.8, {}],
		["slower", &"orderly.speed", 3.6, {}],
		["least", &"orderly.speed", 2.4, {}],
		["most", &"orderly.speed", 4.8, {}],
		["a whole number as an int", &"down.time", 14, {}],
		["off the step, snapped", &"orderly.speed", 3.61, {}],
		["the shortest wait exactly 15 s", &"lift.floor_time", 7.0, {&"lift.floors_min": 2.0}],
		["fewest one under most", &"lift.floors_min", 11, {}],
	]
	for r: Array in accepted:
		var got := Settings.check(StringName(r[1]), r[2], r[3] as Dictionary)
		t.check(got == &"", "%s: %s = %s is refused (%s)" % [r[0], r[1], str(r[2]), got])
	t.eq(Settings.snap(&"orderly.speed", 3.61), 3.6, "snapped to the step")
	t.eq(Settings.snap(&"minder.run_speed", 6.9), 7.0, "snapped to a quarter")
	t.check(not Settings.has(&"resident.grace") and not Settings.has(&"watchers"), "nothing from the fairness contract")

# ---------------------------------------------------------------------------------------------
# 3. Untuned is untouched.

## A floor of `depth` of the game's deck (1, 2 Clinic; 3 Annex; 4 Playroom) with the game's switches on (as the
## server's room: downs, two watchers, relocation, the long dark, paced, the car waits), the car away, the crew
## of `n` on the landing, the resident hunting 6 to 14 cells' walk away (as tests/waits.gd wait_start).
static func game_floor(seed: String, depth: int, n: int) -> Run.RunState:
	var ids: Array[String] = []
	for k in n:
		ids.append("p%d" % k)
	var rules := HostRules.new(true, depth, Places.FULL, false, false, true, true, true, true, true, true)
	var st := rules.prepare(Run.create_run(seed, ids, Places.FULL))
	var plan := st.plan
	var dist := Floor.distances_from(plan, plan.landing)
	var cands: Array = []
	for i in dist.size():
		var d := dist[i]
		if d < 6 or d > 14:
			continue
		var p := Floor.pos_from_index(plan, i)
		if Floor.is_walkable(plan, p.level, p.x, p.y):
			cands.append(p)
	var at: Floor.Pos = Rng.make_rng(seed).fork("orderly").pick(cands)
	var o := Places.create_resident(plan)
	o.body = Move.body_at_cell(plan, at)
	o.mode = &"hunting"
	var s := st.copy()
	s.orderly = o
	s.phase = &"away"
	s.timer = 0.0
	var players: Array[Run.RunPlayer] = []
	for p in st.players:
		var np := p.copy()
		np.aboard = false
		players.append(np)
	s.players = players
	return s

## Everything a tick decides, as plain values (compared with ==: every float exactly).
static func fingerprint(s: Run.RunState, events: Array[Dictionary]) -> Array:
	var down: Array = []
	for id: String in s.down:
		var d: Run.Downed = s.down[id]
		down.append([id, d.at, d.until, d.healer, d.heal_from])
	var seek: Variant = null
	if s.seek != null:
		var m := (s.seek as Seek.SeekState).minder
		seek = [m.body.x, m.body.z, m.body.level, m.yaw, String(m.mode), m.speed, (s.seek as Seek.SeekState).counting]
	return [Snap.run(s), Snap.events(events), down, seek, s.spots.size(), s.left_out.size()]

class Lane:
	var st: Run.RunState
	var bots: Array[Bot.WaitBot] = []
	var caught := {}

	func _init(s: Run.RunState, style: StringName) -> void:
		st = s
		for k in st.players.size():
			var b := Bot.create_wait_bot(st, st.players[k].id, k, style)
			b.stamina = Stamina.fresh_stamina(Run.sprint_seconds(st))
			bots.append(b)
		var s2 := st.copy()
		s2.players = []
		for k in st.players.size():
			var np := st.players[k].copy()
			np.body = bots[k].body
			s2.players.append(np)
		st = s2

	## One tick as tests/waits.gd plays a wait: the first bot calls on tick 0.
	func tick(k: int) -> Array[Dictionary]:
		var live: Array[Bot.WaitBot] = []
		for b in bots:
			var p: Run.RunPlayer = null
			for q in st.players:
				if q.id == b.id:
					p = q
			if not caught.has(b.id) and (p == null or p.status == &"ok"):
				live.append(b)
		if k > 0:
			for b in live:
				Bot.step_wait_bot(st, b, DT)
		var waiting := false
		for b in live:
			if not Run.in_car(st.car, b.body):
				waiting = true
		var inputs: Array[Run.PlayerInput] = []
		for j in live.size():
			var b := live[j]
			inputs.append(Bot.wait_bot_input(b, b.mode == &"aboard" and waiting, k == 0 and j == 0))
		var r := Run.step_run(st, inputs, DT)
		st = r.state
		for e in r.events:
			if e["type"] == "caught":
				caught[e["playerId"]] = true
		return r.events

func test_untuned_empty_and_all_at_today_match_tick_for_tick(t: T) -> void:
	var floors := 4 if t.quick else (200 if t.full else 24)
	var secs := 70.0
	var ticks := 0
	var differ := 0
	var calls := 0
	var blackouts := 0
	var downs := 0
	var counts := 0
	var places := {}
	for i in floors:
		var depth := 1 + i % 4
		var n := 1 + (i / 4) % 4
		var seed := "ls1-same-%d" % i
		var base := game_floor(seed, depth, n)
		places[base.plan.place] = int(places.get(base.plan.place, 0)) + 1
		var style: StringName = &"stay" if i % 2 == 0 else &"flee"
		var lanes: Array[Lane] = [Lane.new(base, style), Lane.new(Run.with_tuning(base, {}), style), Lane.new(Run.with_tuning(base, ten_at_today()), style)]
		t.check(lanes[0].st.tuning == null and lanes[1].st.tuning != null and lanes[1].st.tuning.size() == 0 and lanes[2].st.tuning.size() == 10, "%s: the three tunings" % seed)
		for k in roundi(secs / DT):
			var prints: Array = []
			var evs0: Array[Dictionary] = []
			for li in lanes.size():
				var evs := lanes[li].tick(k)
				if li == 0:
					evs0 = evs
				prints.append(fingerprint(lanes[li].st, evs))
			ticks += 1
			for e in evs0:
				match String(e["type"]):
					"called":
						calls += 1
					"blinkStart":
						if e["blackout"]:
							blackouts += 1
					"downed":
						downs += 1
					"count":
						counts += 1
			if prints[1] != prints[0] or prints[2] != prints[0]:
				differ += 1
				t.check(false, "%s (depth %d, %d players, %s) tick %d: %s differs from the untuned run" % [seed, depth, n, style, k, "the empty tuning" if prints[1] != prints[0] else "all ten at today's"])
				break
			if lanes[0].st.phase == &"ended":
				break
	t.eq(differ, 0, "floors that differ")
	t.check(places.size() == 3 or t.quick, "every place played: %s" % str(places))
	t.check(calls > 0 and blackouts > 0 and downs > 0, "not vacuous: calls %d, blackouts %d, downs %d" % [calls, blackouts, downs])
	t.note("%d floors (%s), %d ticks x 3 runs, every tick the same: %d calls, %d blackouts, %d downs, %d count events" % [floors, str(places), ticks, calls, blackouts, downs, counts])

# ---------------------------------------------------------------------------------------------
# 4. The proofs. Each value at least, today's and most.

## A floor of `depth` (1 the Orderly's Clinic, 3 the Temp's Annex) with the game's switches but relocation (it
## would carry the resident off mid-measure), p0 on the landing facing the car, the car away and the resident
## parked; the tuning `given`.
static func chase_floor(seed: String, depth: int, given: Dictionary) -> Run.RunState:
	var rules := HostRules.new(true, depth, Places.FULL, false, false, true, false, false, true, true, true)
	var st := rules.prepare(Run.create_run(seed, ["p0"] as Array[String], Places.FULL))
	var s := Run.with_tuning(st, given)
	s.orderly = HostRules.parked_orderly(s)
	s.phase = &"away"
	s.timer = 0.0
	var np := s.players[0].copy()
	np.aboard = false
	np.body = Run.car_body(s.car, -1.0, 0.0)
	s.players = [np] as Array[Run.RunPlayer]
	return s

static func landing_input(s: Run.RunState, call: bool = false) -> Run.PlayerInput:
	var i := Run.PlayerInput.make("p0", Run.car_body(s.car, -1.0, 0.0), 1.65, Entity.yaw_toward(s.car.in_x, s.car.in_z), 0.0, 90.0, 70.0)
	i.call = call
	return i

## The resident hunting from the walkable cell of the landing's level furthest from it.
static func hunting_far(s0: Run.RunState) -> Run.RunState:
	var plan := s0.plan
	var dist := Floor.distances_from(plan, plan.landing)
	var best := -1
	for i in dist.size():
		if dist[i] > (dist[best] if best >= 0 else -1) and Floor.pos_from_index(plan, i).level == plan.landing.level:
			best = i
	var s := s0.copy()
	var o := Places.create_resident(plan)
	o.body = Move.body_at_cell(plan, Floor.pos_from_index(plan, best))
	o.mode = &"hunting"
	o.replan_in = 0.0
	s.orderly = o
	return s

class Pace:
	var metres := 0.0
	var top := 0.0
	var dark_ticks := 0
	var ticks := 0
	var body: StringName

## Metres the resident covers in 5 s unwatched (p0 on the landing facing the car), lit or (dark) in the blackout.
static func pace(seed: String, depth: int, given: Dictionary, dark: bool) -> Pace:
	var s := chase_floor(seed, depth, given)
	if dark:
		s = Run.step_run(s, [landing_input(s, true)] as Array[Run.PlayerInput], DT).state
		for _k in roundi(80.0 / DT):
			if Run.blacked_out(s):
				break
			s = Run.step_run(s, [landing_input(s)] as Array[Run.PlayerInput], DT).state
	s = hunting_far(s)
	var out := Pace.new()
	out.body = Entity.kind_of(s.orderly).name
	for _k in roundi(5.0 / DT):
		var before := s.orderly.body
		var lit_before := not Run.blacked_out(s)
		s = Run.step_run(s, [landing_input(s)] as Array[Run.PlayerInput], DT).state
		if s.orderly.mode != &"hunting":
			break
		out.metres += M.hypot2(s.orderly.body.x - before.x, s.orderly.body.z - before.z)
		out.top = maxf(out.top, s.orderly.speed)
		out.ticks += 1
		if not lit_before:
			out.dark_ticks += 1
	return out

func _speed_proof(t: T, dark: bool) -> void:
	var seeds := 1 if t.quick else 3
	var lines: Array[String] = []
	for who: Array in [[&"orderly", 1], [&"temp", 3]]:
		var id := StringName("%s.%s" % [who[0], "dark_speed" if dark else "speed"])
		# The other resident's id at the other end of its range: a read of the wrong id shows.
		var other := StringName("%s.%s" % ["temp" if who[0] == &"orderly" else "orderly", "dark_speed" if dark else "speed"])
		var row := Settings.row(id)
		for i in seeds:
			var seed := "ls1-pace-%d" % i
			var last := -1.0
			var untuned := pace(seed, who[1], {}, dark)
			for v: float in [row.lo, row.today, row.hi]:
				var given := {id: v, other: row.hi if v < row.hi else row.lo}
				var p := pace(seed, who[1], given, dark)
				var tag := "%s %s = %.2f (%s)" % [seed, id, v, "dark" if dark else "lit"]
				t.eq(p.body, who[0], "%s: the resident's body" % tag)
				t.check(p.ticks == roundi(5.0 / DT), "%s: hunted for the whole 5 s (%d ticks)" % [tag, p.ticks])
				t.check(not dark or p.dark_ticks == p.ticks, "%s: in the blackout all 5 s (%d of %d ticks)" % [tag, p.dark_ticks, p.ticks])
				t.check(absf(p.top - v) < 0.02, "%s: top speed %.3f m/s" % [tag, p.top])
				t.check(p.metres <= v * 5.0 + 0.05 and p.metres >= v * 5.0 * 0.85, "%s: %.2f m in 5 s, want about %.2f" % [tag, p.metres, v * 5.0])
				t.check(p.metres > last, "%s: %.2f m is not more than at the slower speed (%.2f m)" % [tag, p.metres, last])
				last = p.metres
				if v == row.today:
					t.check(absf(p.metres - untuned.metres) < 1e-9 and p.top == untuned.top, "%s: today's value is the untuned run (%.4f m against %.4f m)" % [tag, p.metres, untuned.metres])
				if i == 0:
					lines.append("%s %.2f: %.2f m" % [id, v, p.metres])
	t.note("5 s unwatched %s: %s" % ["in the blackout" if dark else "lit", ", ".join(lines)])

func test_orderly_and_temp_speeds_lit(t: T) -> void:
	_speed_proof(t, false)

func test_orderly_and_temp_speeds_in_the_blackout(t: T) -> void:
	_speed_proof(t, true)

## The Minder's top pace while it searches and while it runs someone down, in one count on the Playroom: p0
## sprints once to start it; 3 s into the search p1 stands in its view (as tests/prop_seek.gd standing_in_view).
static func minder_pace(seed: String, given: Dictionary, t: T) -> Vector2:
	var r := CountRun.Rig.new(seed)
	r.st = Run.with_tuning(r.st, given)
	CountRun.to_away(t, r)
	r.gait["p0"] = &"sprint"
	r.step()
	r.gait["p0"] = &"creep"
	var search := 0.0
	var run := 0.0
	var seek_for := 0.0
	var placed := false
	var cells := CountRun.safe_cells(r.plan(), 0.0, seed + ":view")
	for _k in roundi(60.0 / DT):
		var ss: Seek.SeekState = r.st.seek
		if ss == null or not ss.counting:
			break
		if Seek.phase_of(ss) == &"seek":
			seek_for += DT
		var m := ss.minder
		if not placed and seek_for >= 3.0:
			for c in cells:
				var cb := Move.body_at_cell(r.plan(), c)
				var d := PropSeek.horiz(cb, m.body)
				if d >= 5.0 and d <= 10.0 and PropSeek.o_sight(r.plan(), m.body, m.yaw, cb) == 1:
					r.bodies["p1"] = cb
					placed = true
					break
		var mode_before := m.mode
		r.step()
		if r.st.seek == null:
			break
		var m2 := (r.st.seek as Seek.SeekState).minder
		if mode_before == m2.mode and m2.mode == &"search":
			search = maxf(search, m2.speed)
		if mode_before == m2.mode and m2.mode == &"run":
			run = maxf(run, m2.speed)
	return Vector2(search, run)

func test_minder_search_and_run_pace(t: T) -> void:
	var seeds := 2 if t.quick else 4
	var lines: Array[String] = []
	for id: StringName in [&"minder.search_speed", &"minder.run_speed"]:
		var row := Settings.row(id)
		var axis := 0 if id == &"minder.search_speed" else 1
		for v: float in [row.lo, row.today, row.hi]:
			var seen := 0
			for i in seeds:
				var seed := "ls1-minder-%d" % i
				# The other speed at the other end of its range.
				var other := &"minder.run_speed" if axis == 0 else &"minder.search_speed"
				var orow := Settings.row(other)
				var got := minder_pace(seed, {id: v, other: orow.hi if v < row.hi else orow.lo}, t)
				var top := got[axis]
				if top <= 0.0:
					continue
				seen += 1
				t.check(absf(top - v) < 0.02, "%s %s = %.2f: its top pace %.3f m/s" % [seed, id, v, top])
			t.check(seen > 0, "%s = %.2f: never seen at that pace in %d counts (vacuous)" % [id, v, seeds])
			lines.append("%s %.2f in %d of %d counts" % [id, v, seen, seeds])
	t.note("the Minder's top pace matched: %s" % ", ".join(lines))

## The bound sets of the lift proof: [fewest, most, seconds a floor], each keeping the pair rules.
const LIFT_SETS: Array = [[6, 12, 4.0], [2, 3, 7.0], [14, 20, 1.0], [19, 20, 8.0], [9, 10, 2.5]]

func test_lift_wait_over_500_plans_and_in_a_run(t: T) -> void:
	var n := 100 if t.quick else 500
	var lines: Array[String] = []
	for b: Array in LIFT_SETS:
		var lo: int = b[0]
		var hi: int = b[1]
		var sec: float = b[2]
		var given := {&"lift.floors_min": lo, &"lift.floors_max": hi, &"lift.floor_time": sec}
		var tag := "%d-%d floors x %.1f s" % [lo, hi, sec]
		t.check(Settings.pair_broken(given).is_empty(), "%s: keeps the pair rules" % tag)
		for id: StringName in given:
			t.eq(Settings.check(id, given[id], given), &"", "%s: %s passes the check" % [tag, id])
		var tuning := Settings.make(given)
		var seen := {}
		var short := INF
		var long := 0.0
		var bad := 0
		for i in n:
			var seed := "ls1-lift-%d" % i
			var prev := -1 if i % 5 == 0 else lo + (i * 7) % (hi - lo + 1)
			var depth := 1 + i % 3
			var p := Run.call_plan(seed, i % 3, prev, depth, true, tuning)
			var ok := p.floors >= lo and p.floors <= hi and p.floors != prev and p.floor_time == sec \
				and p.wait == p.delay + p.floors * sec + p.extra \
				and p.wait >= Run.CALL_START_DELAY_MIN + lo * sec - EPS \
				and p.wait <= Run.CALL_START_DELAY_MAX + hi * sec + Run.FALSE_STOP_EXTRA_MAX + EPS
			if not ok:
				bad += 1
				if bad <= 3:
					t.check(false, "%s %s: %d floors (prev %d) x %.2f s, wait %.3f" % [tag, seed, p.floors, prev, p.floor_time, p.wait])
			seen[p.floors] = true
			short = minf(short, p.wait - p.extra)
			long = maxf(long, p.wait)
			# The same draws: the plan's other numbers are the untuned plan's.
			var u := Run.call_plan(seed, i % 3, -1, depth, true)
			var tp := Run.call_plan(seed, i % 3, -1, depth, true, tuning)
			if u.delay != tp.delay or u.false_stop != tp.false_stop or u.extra != tp.extra:
				bad += 1
				t.check(false, "%s %s: a draw moved" % [tag, seed])
		t.eq(bad, 0, "%s: plans out of bounds" % tag)
		t.check(seen.has(lo) and seen.has(hi), "%s: both bounds drawn over %d plans: %s" % [tag, n, str(seen.keys())])
		lines.append("%s: %d floor counts, waits %.1f to %.1f s" % [tag, seen.size(), short, long])
		# In a run: the car arrives when its plan said, though the host changes all three during the wait.
		var s := chase_floor("ls1-lift-run-%d" % lo, 1, given)
		var r := Run.step_run(s, [landing_input(s, true)] as Array[Run.PlayerInput], DT)
		s = r.state
		var called_at := -1.0
		var indicators := 0
		for e in r.events:
			if e["type"] == "called":
				called_at = float(e["t"])
			if e["type"] == "indicator":
				indicators += 1
		t.check(s.call != null and called_at >= 0.0, "%s: the car was called" % tag)
		if s.call == null:
			continue
		var plan := s.call.plan
		t.check(plan.floors >= lo and plan.floors <= hi and plan.floor_time == sec, "%s: the run's plan %d floors x %.1f s" % [tag, plan.floors, plan.floor_time])
		var arrived := -1.0
		var changed := false
		for _k in roundi((plan.wait + 5.0) / DT):
			if not changed and s.t >= called_at + plan.delay + sec:
				# Mid-wait: every lift number changed. The call keeps the plan it was given.
				s = Run.with_tuning(s, {&"lift.floors_min": 2, &"lift.floors_max": 3, &"lift.floor_time": 8.0} if lo != 2 else {&"lift.floors_min": 19, &"lift.floors_max": 20, &"lift.floor_time": 1.0})
				changed = true
			r = Run.step_run(s, [landing_input(s)] as Array[Run.PlayerInput], DT)
			s = r.state
			for e in r.events:
				if e["type"] == "indicator":
					indicators += 1
				if e["type"] == "carArrived" and arrived < 0.0:
					arrived = float(e["t"])
			if arrived >= 0.0:
				break
		t.check(changed and arrived >= 0.0 and absf(arrived - called_at - plan.wait) <= DT + 1e-6,
			"%s: the car arrived %.3f s after the call, its plan said %.3f s" % [tag, arrived - called_at, plan.wait])
		t.eq(indicators, plan.floors + 1, "%s: the indicator showed every floor" % tag)
	t.note("%d plans a set: %s" % [n, "; ".join(lines)])

## p0, alone, caught by the resident 1.2 m behind them (as tests/prop_downs.gd); the tuning `given`.
## Returns [the downed event's t and until, the out event's t] (-1 for none). `retune`: set this tuning
## 1 s after the down.
static func down_and_out(seed: String, given: Dictionary, retune: Variant = null) -> PackedFloat64Array:
	var rng := Rng.make_rng(seed)
	var s := Run.with_paced(Run.create_run(seed, ["p0"] as Array[String], [], false, false, true))
	s = Run.with_tuning(s, given)
	var plan := s.plan
	var dist := Floor.distances_from(plan, plan.landing)
	var cells: Array[Floor.Pos] = []
	for i in dist.size():
		var p := Floor.pos_from_index(plan, i)
		if dist[i] >= 3 and p.level == plan.landing.level:
			cells.append(p)
	var vb := Move.body_at_cell(plan, cells[rng.int_in(0, cells.size() - 1)])
	var ob := Move.body_at_cell(plan, plan.landing)
	for j in 8:
		var a := (rng.int_in(0, 7) + j) * PI / 4.0
		var b := Move.move_with_collision(plan, vb, cos(a) * 1.2, sin(a) * 1.2, Entity.ORDERLY_RADIUS)
		if M.hypot2(b.x - vb.x, b.z - vb.z) >= 1.15:
			ob = b
			break
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
	var np := s.players[0].copy()
	np.body = vb
	np.aboard = false
	s.players = [np] as Array[Run.RunPlayer]
	var yaw := Entity.yaw_toward(vb.x - ob.x, vb.z - ob.z)
	var out := PackedFloat64Array([-1.0, -1.0, -1.0])
	for _k in roundi(75.0 / DT):
		var ins: Array[Run.PlayerInput] = [Run.PlayerInput.make("p0", vb, 1.65, yaw, 0.0, 90.0, 70.0)]
		var r := Run.step_run(s, ins, DT)
		s = r.state
		for e in r.events:
			if e["type"] == "downed" and e["playerId"] == "p0" and out[0] < 0.0:
				out[0] = float(e["t"])
				out[1] = float(e["until"])
			if e["type"] == "out" and e["playerId"] == "p0":
				out[2] = s.t
				return out
		if retune != null and out[0] >= 0.0 and s.t >= out[0] + 1.0:
			s = Run.with_tuning(s, retune)
			retune = null
	return out

func test_down_time(t: T) -> void:
	var seeds := 2 if t.quick else 6
	var lines: Array[String] = []
	for d: float in [5.0, 10.0, 60.0]:
		var caught := 0
		for i in seeds:
			var seed := "ls1-down-%d" % i
			var got := down_and_out(seed, {&"down.time": d})
			if got[0] < 0.0:
				continue
			caught += 1
			t.check(absf(got[1] - got[0] - d) < 1e-6, "%s down.time %.0f: downed at %.3f, until %.3f" % [seed, d, got[0], got[1]])
			t.check(got[2] >= got[1] - 1e-6 and got[2] < got[1] + DT + 1e-6, "%s down.time %.0f: out at %.3f, until %.3f" % [seed, d, got[2], got[1]])
		t.check(caught > 0, "down.time %.0f: no seed caught p0 (vacuous)" % d)
		lines.append("%.0f s (%d downs)" % [d, caught])
	# Already down when it changes: out when their "downed" said (10 s), not at the new 60 or 5.
	for retune: float in [60.0, 5.0]:
		var got := down_and_out("ls1-down-0", {}, {&"down.time": retune})
		t.check(got[0] >= 0.0 and absf(got[1] - got[0] - Run.DOWN_TIME) < 1e-6 and got[2] >= got[1] - 1e-6 and got[2] < got[1] + DT + 1e-6,
			"changed to %.0f s while down: downed %.3f, until %.3f, out %.3f" % [retune, got[0], got[1], got[2]])
	t.note("out came down.time after downed at %s; already down keeps its time" % ", ".join(lines))

# ---------------------------------------------------------------------------------------------
# 5. Every wired id has a proof.

func test_every_wired_setting_has_a_proof(t: T) -> void:
	var wired := {}
	for s in Settings.list(true):
		wired[s.id] = true
		t.check(PROOFS.has(s.id) and has_method(String(PROOFS.get(s.id, ""))), "%s is wired and has no proof in tests/prop_settings.gd" % s.id)
	for id: StringName in PROOFS:
		t.check(wired.has(id), "%s has a proof but is not wired" % id)
