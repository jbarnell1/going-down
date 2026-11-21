# LS1, the last one standing and the wipe (North Star B7; sim/last_stand.gd, sim/run.gd with_last_stand, net/host_rules.gd
# `last_stand_`). "When one living player remains, every camera feed locks onto them, the music cuts, and their tape gains
# a sole-survivor bonus. ... A wipe is a scene too. ... Later, the lobby gains a standee with the face of the last player
# caught." Proved here, the rules' side:
#   1. The spotlight starts on the tick exactly one of a crew of two or more is still up and ends on the tick that stops
#      being true (a heal, the survivor down too, the floor ending), for crews of 2 and 4; never for a crew of 1. Its two
#      events come on those ticks. Over bot floors with the game's switches, on every tick it is exactly that.
#   2. The bonus: only the survivor, only while alone, only with the flag on, at the number stamped as the spotlight
#      began (the live setting last_stand.bonus); the tick the spotlight begins is paid as before, so the snapshot that
#      prints the number reaches every screen before any of it is earned.
#   3. Flag off: nothing is ever made, no event, and bot floors are the same tick for tick as without the flag.
#   4. The wipe: a real catch, down and out ends a crew of two; the wipe keeps the host time, the floor, the resident
#      that made the last catch and who it caught, and the standee is that player; the next wipe replaces it; a new
#      day keeps it.
#   5. The world's blocks: "stand", "wipe", "standee" on the wire and off it with the flag off.
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const LastStand = preload("res://sim/last_stand.gd")
const Instr = preload("res://sim/instrument.gd")
const Entity = preload("res://sim/entity.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Rng = preload("res://sim/rng.gd")
const M = preload("res://sim/jsmath.gd")
const Places = preload("res://sim/places.gd")
const Settings = preload("res://sim/settings.gd")
const HostRules = preload("res://net/host_rules.gd")
const Protocol = preload("res://net/protocol.gd")
const Host = preload("res://net/host.gd")
const Transport = preload("res://net/transport.gd")
const PropSettings = preload("res://tests/prop_settings.gd")

const DT := 0.05

static func ids_of(n: int) -> Array[String]:
	var out: Array[String] = []
	for k in n:
		out.append("p%d" % k)
	return out

## A Clinic floor with the resident parked for ever (it catches nobody), downs on, the car away, the crew of `n`
## standing on the landing; with LS1 when `on`.
static func parked_floor(seed: String, n: int, on: bool) -> Run.RunState:
	var rules := HostRules.new(false, 1, [], true, false, true)
	rules.last_stand = on
	var s := rules.prepare(Run.create_run(seed, ids_of(n), [], true, false, true))
	s = s.copy()
	s.phase = &"away"
	s.timer = 0.0
	s.call = null
	s.blink = null
	var players: Array[Run.RunPlayer] = []
	for i in s.players.size():
		var np := s.players[i].copy()
		np.aboard = false
		np.body = Run.car_body(s.car, -1.0 - 0.4 * i, 0.0)
		players.append(np)
	s.players = players
	return s

static func inputs_of(s: Run.RunState) -> Array[Run.PlayerInput]:
	var out: Array[Run.PlayerInput] = []
	for p in s.players:
		out.append(Run.PlayerInput.make(p.id, p.body, 1.65, 0.0, 0.0, 90.0, 70.0))
	return out

## `s` with player `id` put in `status` ("out", "ok"), or put down by a real catch-down (Run._go_down) for "down".
static func set_status(s0: Run.RunState, id: String, status: StringName) -> Run.RunState:
	var s := s0.copy()
	var players: Array[Run.RunPlayer] = s.players.duplicate()
	for k in players.size():
		if players[k].id != id:
			continue
		if status == &"down":
			var evs: Array[Dictionary] = []
			s.down = s.down.duplicate()
			Run._go_down(s, players, k, s.t, &"catch", evs)
		else:
			var np := players[k].copy()
			np.status = status
			players[k] = np
			if s.down.has(id):
				s.down = s.down.duplicate()
				s.down.erase(id)
	s.players = players
	return s

## Steps `s` once; returns [state, events].
static func tick(s: Run.RunState) -> Array:
	var r := Run.step_run(s, inputs_of(s), DT)
	return [r.state, r.events]

static func events_of(evs: Array, ty: String) -> Array:
	return evs.filter(func(e: Dictionary) -> bool: return str(e["type"]) == ty)

# ---------------------------------------------------------------------------------------------
# 1. The ticks.

## The script for a crew of `n`: {tick: [[id, status], ...]} applied just before that tick, and what the spotlight must
## be after each listed tick.
func test_spotlight_starts_and_ends_on_the_right_ticks(t: T) -> void:
	for n: int in [2, 4]:
		var s := parked_floor("ls1-ticks-%d" % n, n, true)
		var plan := {}
		# Everyone but p0 and the last goes out at tick 10 (a crew of 2: nobody); the last at 20: p0 is alone.
		var middle: Array = []
		for k in range(1, n - 1):
			middle.append(["p%d" % k, &"out"])
		plan[10] = middle
		plan[20] = [["p%d" % (n - 1), &"out"]]
		plan[30] = [["p%d" % (n - 1), &"ok"]]          # back up: two up again
		plan[40] = [["p%d" % (n - 1), &"down"]]        # down by a catch: p0 alone again
		plan[50] = [["p0", &"down"]]                   # the survivor down too: nobody up
		var want := {}
		for k in 61:
			want[k] = "p0" if (k >= 20 and k < 30) or (k >= 40 and k < 50) else ""
		var starts: Array = []
		var ends: Array = []
		var began_t := -1.0
		for k in 61:
			for ch: Array in plan.get(k, []):
				s = set_status(s, str(ch[0]), ch[1])
			var r := tick(s)
			s = r[0]
			var evs: Array = r[1]
			t.check(s.stand.id == str(want[k]), "crew %d tick %d: the spotlight is %s (want %s)" % [n, k, s.stand.id, str(want[k])])
			for e: Dictionary in events_of(evs, "lastStand"):
				starts.append([k, str(e["playerId"]), absf(float(e["t"]) - s.t) < 1e-9])
				began_t = s.t
			for e: Dictionary in events_of(evs, "lastStandEnd"):
				ends.append([k, str(e["playerId"]), str(e["why"])])
			if s.stand.id != "":
				t.check(absf(s.stand.since - began_t) < 1e-9, "crew %d tick %d: since is the tick it began" % [n, k])
		t.eq(starts, [[20, "p0", true], [40, "p0", true]], "crew %d: lastStand on ticks 20 and 40, at their host time" % n)
		t.eq(ends, [[30, "p0", "healed"], [50, "p0", "caught"]], "crew %d: lastStandEnd on ticks 30 (healed) and 50 (caught)" % n)

func test_never_for_a_crew_of_one(t: T) -> void:
	var s := parked_floor("ls1-solo", 1, true)
	var any := 0
	for k in 40:
		if k == 10:
			s = set_status(s, "p0", &"down")
		var r := tick(s)
		s = r[0]
		any += events_of(r[1], "lastStand").size()
		t.check(s.stand.id == "", "solo tick %d: no spotlight" % k)
	t.eq(any, 0, "no lastStand event playing alone")

func test_ends_when_the_floor_ends(t: T) -> void:
	# The survivor rides away: the spotlight ends on the tick the car leaves (riding), why "left".
	var s := set_status(parked_floor("ls1-left", 2, true), "p1", &"out")
	var r := tick(s)
	s = r[0]
	t.eq(s.stand.id, "p0", "p1 out: p0 alone")
	var ride := s.copy()
	ride.phase = &"riding"
	ride.timer = 5.0
	r = tick(ride)
	t.eq((r[0] as Run.RunState).stand.id, "", "riding: no spotlight")
	var e: Array = events_of(r[1], "lastStandEnd")
	t.check(e.size() == 1 and str(e[0]["why"]) == "left", "it ends, why left: %s" % str(e))
	var home := Run.create_run("ls1-home", ids_of(2), [], true)
	home.depth = 0
	t.check(not Run.stand_floor(home), "never in the prison")

## Over bot floors with the game's switches (prop_settings' lanes: calls, blackouts, catches, downs): on every tick the
## spotlight is exactly the one id up in a crew of two or more, and its events are on the ticks it changes.
func test_every_tick_of_bot_floors(t: T) -> void:
	var floors := 8 if t.quick else 32
	var spotlights := 0
	var by_crew := {}
	for i in floors:
		var depth := 1 + i % 4
		var n := 1 + (i / 2) % 4
		var base := Run.with_last_stand(PropSettings.game_floor("ls1-bots-%d" % i, depth, n))
		var lane := PropSettings.Lane.new(base, &"stay" if i % 2 == 0 else &"flee")
		var prev_id := ""
		for k in roundi(70.0 / DT):
			var evs: Array = lane.tick(k)
			var st: Run.RunState = lane.st
			var want := LastStand.survivor(Run.stand_up_ids(st), st.players.size(), Run.stand_floor(st))
			if st.stand.id != want:
				t.check(false, "floor %d (crew %d) tick %d: spotlight %s, want %s" % [i, n, k, st.stand.id, want])
				break
			var began := events_of(evs, "lastStand").size()
			var ended := events_of(evs, "lastStandEnd").size()
			var want_began := 1 if want != "" and want != prev_id else 0
			var want_ended := 1 if prev_id != "" and want != prev_id else 0
			if began != want_began or ended != want_ended:
				t.check(false, "floor %d tick %d: events began %d ended %d, want %d %d" % [i, k, began, ended, want_began, want_ended])
				break
			spotlights += want_began
			if want_began > 0:
				by_crew[n] = int(by_crew.get(n, 0)) + 1
			prev_id = want
			if st.phase == &"ended":
				break
	t.check(not by_crew.has(1), "never for a crew of one: %s" % str(by_crew))
	t.check(spotlights > 0, "not vacuous: %d spotlights (%s)" % [spotlights, str(by_crew)])
	t.note("%d floors: %d spotlights by crew size %s" % [floors, spotlights, str(by_crew)])

# ---------------------------------------------------------------------------------------------
# 2. The bonus.

## The two players' instrument rates for one crew tick of `s` (sim/run.gd _crew_tick): p0 and p1 the same distance
## from a Stillness resident that moved this tick, both raised. Returns {p0, p1}.
static func rates(s0: Run.RunState) -> Dictionary:
	var s := s0.copy()
	var o := s.orderly.copy()
	var at := Move.body_at_cell(s.plan, s.plan.landing)
	o.body = at
	var moved := o.copy()
	moved.body = Move.Body.make(at.x + 0.05, at.z, at.level, at.y)
	var tick := Instr.EntityTick.make("orderly-1", &"stillness", o, moved, [])
	var players: Array[Instr.CrewPlayer] = []
	var crew := s.crew
	for k in 2:
		var id := "p%d" % k
		crew = Instr.set_raised(crew, id, true)
		players.append(Instr.CrewPlayer.make(id, Move.Body.make(moved.body.x + (2.0 if k == 0 else -2.0), moved.body.z, at.level, at.y), true))
	s.crew = crew
	var ticks: Array[Instr.EntityTick] = [tick]
	var out := Run._crew_tick(s, players, ticks, DT)
	return {"p0": Instr.member(out.crew, "p0").instrument.rate, "p1": Instr.member(out.crew, "p1").instrument.rate}

static func with_stand(s0: Run.RunState, id: String, mult: float) -> Run.RunState:
	var s := s0.copy()
	var st := LastStand.State.new() if s.stand == null else s.stand.copy()
	st.id = id
	st.mult = mult
	st.since = s.t
	s.stand = st
	return s

func test_the_bonus_only_for_the_survivor_only_with_the_flag(t: T) -> void:
	var on := Run.with_last_stand(Run.create_run("ls1-pay", ids_of(2)))
	var plain := rates(on)
	t.check(plain["p0"] > 0.0 and absf(plain["p0"] - plain["p1"]) < 1e-9, "both record the same at the same distance: %s" % str(plain))
	var alone := rates(with_stand(on, "p1", 1.5))
	t.check(absf(alone["p1"] - 1.5 * plain["p1"]) < 1e-9, "the survivor's rate is 1.5 times: %s against %s" % [str(alone), str(plain)])
	t.check(absf(alone["p0"] - plain["p0"]) < 1e-9, "the other's is not")
	var off := Run.create_run("ls1-pay", ids_of(2))
	off = with_stand(off, "p1", 1.5)
	var off_rates := rates(off)
	t.check(not off.last_stand and absf(off_rates["p1"] - plain["p1"]) < 1e-9, "flag off: no bonus even with a spotlight set: %s" % str(off_rates))
	var two := rates(with_stand(on, "p1", 2.0))
	t.check(absf(two["p1"] - 2.0 * plain["p1"]) < 1e-9, "the stamped number is the one paid (2.0)")

## The bonus, at least, today's and most of the live setting (prop_settings' proof for last_stand.bonus): the number is
## stamped as the spotlight begins and is the one paid; a change while it lasts waits for the next spotlight.
static func bonus_proof(t: T) -> void:
	var row := Settings.row(&"last_stand.bonus")
	for v: float in [row.lo, row.today, row.hi]:
		var s := set_status(Run.with_tuning(parked_floor("ls1-set", 2, true), {&"last_stand.bonus": v}), "p1", &"out")
		var r := tick(s)
		s = r[0]
		t.check(absf(s.stand.mult - v) < 1e-9, "last_stand.bonus %s: stamped %s" % [str(v), str(s.stand.mult)])
		var e: Array = events_of(r[1], "lastStand")
		t.check(e.size() == 1 and absf(float(e[0]["mult"]) - v) < 1e-9, "the event says %s" % str(v))
		var base := rates(Run.with_last_stand(Run.create_run("ls1-set-r", ids_of(2))))
		var paid := rates(with_stand(Run.with_last_stand(Run.create_run("ls1-set-r", ids_of(2))), "p1", s.stand.mult))
		t.check(absf(paid["p1"] - v * base["p1"]) < 1e-9, "%s times is paid" % str(v))
		# A change while it lasts: the stamp stays.
		var changed := Run.with_tuning(s, {&"last_stand.bonus": row.lo if v != row.lo else row.hi})
		var r2 := tick(changed)
		t.check(absf((r2[0] as Run.RunState).stand.mult - v) < 1e-9, "a change during the spotlight waits for the next one")

func test_printed_before_it_is_earned(t: T) -> void:
	var a := parked_floor("ls1-first", 2, true)
	var r := tick(set_status(a, "p1", &"out"))
	var b: Run.RunState = r[0]
	t.eq(b.stand.id, "p0", "the tick p1 went out begins the spotlight on p0")
	# That tick was stepped from a state without the spotlight: paid as before.
	var pre := rates(a)
	var post := rates(b)
	t.check(absf(pre["p0"] - rates(Run.create_run("ls1-first", ids_of(2)))["p0"]) < 1e-9, "the tick that begins it pays as before")
	t.check(absf(post["p0"] - b.stand.mult * pre["p0"]) < 1e-9, "the next pays the bonus: %s then %s" % [str(pre), str(post)])
	# The state that begins it carries the number on the wire already.
	var net := Transport.MemoryNetwork.new("ls1-wire")
	var host := Host.new(net.connect_peer("host"), "ls1-first", ids_of(2), 0.0)
	host.state = b
	var w: Variant = JSON.parse_string(Protocol.world_json(host.world()))
	var dec := Protocol.dec_world(Protocol._V.new(), w)
	t.check(dec.get("stand") is Dictionary and str(dec["stand"]["id"]) == "p0" and absf(float(dec["stand"]["mult"]) - b.stand.mult) < 1e-3,
		"the world of that tick prints it: %s" % str(dec.get("stand")))

# ---------------------------------------------------------------------------------------------
# 3. Flag off.

func test_flag_off_changes_nothing(t: T) -> void:
	var r := HostRules.new(true, 1, Places.FULL)
	t.check(not r.last_stand, "off by default")
	var st := r.prepare(Run.create_run("ls1-off", ids_of(2), Places.FULL))
	t.check(not st.last_stand and st.stand == null, "off: the run has no spotlight state")
	# Bot floors: the same tick for tick with the flag off as the run always was, and with it on up to the first spotlight.
	var floors := 4 if t.quick else 16
	var compared := 0
	for i in floors:
		var depth := 1 + i % 4
		var n := 1 + i % 4
		var base := PropSettings.game_floor("ls1-same-%d" % i, depth, n)
		t.check(not base.last_stand, "the game floor has it off")
		var plain := PropSettings.Lane.new(base, &"stay")
		var lit := PropSettings.Lane.new(Run.with_last_stand(base), &"stay")
		for k in roundi(60.0 / DT):
			var e0: Array = plain.tick(k)
			var e1: Array = lit.tick(k)
			t.check(events_of(e0, "lastStand").is_empty() and events_of(e0, "lastStandEnd").is_empty(), "off: no event")
			if not events_of(e1, "lastStand").is_empty():
				break
			if PropSettings.fingerprint(plain.st, e0) != PropSettings.fingerprint(lit.st, e1):
				t.check(false, "floor %d (crew %d) tick %d: on differs from off before any spotlight" % [i, n, k])
				break
			compared += 1
			if plain.st.phase == &"ended":
				break
	t.check(compared > 100, "not vacuous: %d ticks compared" % compared)

# ---------------------------------------------------------------------------------------------
# 4. The wipe and the standee.

## A Clinic run with days and the down rule, crew p0 and p1, p1 already out; the Orderly a little over a metre from p0
## and coming, p0 facing away (as tests/prop_down_ring.gd). Steps until the wipe; returns [state, wipe tick events].
static func caught_wipe(seed: String, on: bool) -> Array:
	var rng := Rng.make_rng(seed)
	var s := Run.with_paced(Run.create_run(seed, ids_of(2), [], true, false, true))
	if on:
		s = Run.with_last_stand(s)
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
	var p0 := s.players[0].copy()
	p0.body = vb
	p0.aboard = false
	var p1 := s.players[1].copy()
	p1.body = Move.body_at_cell(plan, plan.landing)
	p1.aboard = false
	p1.status = &"out"
	s.players = [p0, p1] as Array[Run.RunPlayer]
	var yaw := Entity.yaw_toward(vb.x - ob.x, vb.z - ob.z)
	for _k in roundi(80.0 / DT):
		var ins: Array[Run.PlayerInput] = [Run.PlayerInput.make("p0", vb, 1.65, yaw, 0.0, 90.0, 70.0)]
		var r := Run.step_run(s, ins, DT)
		s = r.state
		if not events_of(r.events, "wiped").is_empty():
			return [s, r.events]
	return [s, []]

func test_the_wipe_keeps_the_last_catch(t: T) -> void:
	var got := 0
	for i in (3 if t.quick else 8):
		var seed := "ls1-wipe-%d" % i
		var r := caught_wipe(seed, true)
		var s: Run.RunState = r[0]
		if (r[1] as Array).is_empty():
			continue
		got += 1
		var w := s.stand.wipe
		var wiped: Dictionary = events_of(r[1], "wiped")[0]
		t.check(absf(float(w["at"]) - float(wiped["t"])) < 1e-9, "%s: the wipe's host time" % seed)
		t.check(str(w["by"]) == "orderly" and int(w["n"]) == 1 and str(w["last"]) == "p0", "%s: the Orderly caught p0 last: %s" % [seed, str(w)])
		t.check(int(w["depth"]) == 1 and int(w["day"]) == s.day_index, "%s: the floor and the day" % seed)
		t.eq(s.stand.standee, "p0", "%s: the standee is p0" % seed)
		# The empty car rides up to the prison: the standee is kept there, and the scene's block until the morning.
		var home := s
		for _k in roundi(12.0 / DT):
			home = Run.step_run(home, [] as Array[Run.PlayerInput], DT).state
		t.check(home.depth == 0 and home.stand.standee == "p0" and not home.stand.wipe.is_empty(), "%s: at home the standee is p0 (depth %d)" % [seed, home.depth])
		var off := caught_wipe(seed, false)
		t.check((off[0] as Run.RunState).stand == null, "%s: flag off keeps nothing" % seed)
	t.check(got > 0, "a seed wiped (not vacuous)")

func test_the_next_wipe_replaces_the_standee(t: T) -> void:
	var st := LastStand.State.new()
	var evs: Array[Dictionary] = [{"type": "caught", "t": 1.0, "playerId": "p1", "n": 2}]
	st = LastStand.after_tick(st, ["p0"] as Array[String], 2, true, 1.0, "1:2", 2, 1, "orderly", null, evs)
	var wipe: Array[Dictionary] = [{"type": "wiped", "t": 3.0}]
	st = LastStand.after_tick(st, [] as Array[String], 2, false, 3.0, "1:2", 2, 1, "orderly", null, wipe)
	t.check(st.standee == "p1" and int(st.wipe["n"]) == 2 and str(st.wipe["by"]) == "orderly", "the second Orderly caught p1: %s" % str(st.wipe))
	# The morning: a new floor forgets the catch, not the standee.
	var none: Array[Dictionary] = []
	st = LastStand.after_tick(st, ["p0", "p1"] as Array[String], 2, true, 50.0, "2:1", 1, 2, "temp", null, none)
	t.check(st.standee == "p1" and st.catch_id == "", "a new day keeps the standee and forgets the catch")
	var c2: Array[Dictionary] = [{"type": "caught", "t": 60.0, "playerId": "p0"}]
	st = LastStand.after_tick(st, ["p1"] as Array[String], 2, true, 60.0, "2:1", 1, 2, "temp", null, c2)
	var w2: Array[Dictionary] = [{"type": "wiped", "t": 70.0}]
	st = LastStand.after_tick(st, [] as Array[String], 2, false, 70.0, "2:1", 1, 2, "temp", null, w2)
	t.check(st.standee == "p0" and str(st.wipe["by"]) == "temp" and str(st.wipe["last"]) == "p0", "the next wipe replaces it: %s" % str(st.wipe))
	# The Playroom's found counts as the Minder's catch; the Ward's is the Rigger's.
	var f: Array[Dictionary] = [{"type": "found", "t": 80.0, "playerId": "p1"}]
	st = LastStand.after_tick(st, ["p0"] as Array[String], 2, true, 80.0, "2:4", 4, 2, "minder", null, f)
	t.check(st.catch_id == "p1" and st.catch_by == "minder", "found by the Minder")
	t.eq(LastStand.resident_of(&"reactor", false), "four", "the Reactor's four")
	t.eq(LastStand.resident_of(&"clinic", true), "rigger", "the Ward's Rigger")
	t.eq(LastStand.resident_of(&"arboretum", false), "groundskeeper", "the Groundskeeper")

# ---------------------------------------------------------------------------------------------
# 5. The wire.

func test_the_blocks_on_the_wire(t: T) -> void:
	var net := Transport.MemoryNetwork.new("ls1-blocks")
	var host := Host.new(net.connect_peer("host"), "ls1-blocks", ids_of(2), 0.0)
	var off_json := Protocol.world_json(host.world())
	t.check(not off_json.contains("stand") and not off_json.contains("wipe"), "flag off: no block")
	var s := Run.with_last_stand(host.state)
	var st := LastStand.State.new()
	st.wipe = {"at": 12.5, "depth": s.depth, "day": s.day_index, "by": "minder", "n": 1, "last": "p1"}
	st.standee = "p1"
	s.stand = st
	host.state = s
	var dec := Protocol.dec_world(Protocol._V.new(), JSON.parse_string(Protocol.world_json(host.world())))
	t.check(dec.get("wipe") is Dictionary and str(dec["wipe"]["by"]) == "minder" and str(dec["wipe"]["last"]) == "p1" and absf(float(dec["wipe"]["at"]) - 12.5) < 1e-3,
		"the wipe block: %s" % str(dec.get("wipe")))
	t.eq(dec.get("standee"), "p1", "the standee block")
	t.check(not dec.has("stand"), "no spotlight, no stand block")
