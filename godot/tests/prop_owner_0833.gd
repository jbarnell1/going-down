# The owner's notes on build 0833 (17 Nov), each proved with its rule on and, as the control, off (every
# stored result has them off):
#   T20a. The Orderly is drawn in the dark (net/client.gd draw_in_dark): over lossy and zero-delay network
#         sessions with blinks and blackouts (tests/prop_net.gd run_session), every dark frame draws it when
#         it has a pose and is never held or seeing (looking in the dark still never counts), and a watched
#         Orderly still never moves on a lit frame. Off: no dark frame draws it, as before.
#   T20c. The long dark (sim/run.gd long_dark): every call plan's blackout is LONG_BLACKOUT_* seconds (capped
#         so the ladder's first blink still fits), ends as the car arrives, and the blinks before it fit in
#         order; the rest of the plan is as before. A run made with it uses those plans.
#   T20h. Paced (sim/run.gd paced): a full tank sprints Stamina.PACED_SPRINT_SECONDS, fleeing is as near the
#         hunt as before, the Orderly hunts at PACED_HUNT_SPEED, the host steps every tank at the paced size
#         and every client is told it.
#   FD4.  The car waits (sim/run.gd car_waits; docs/floors/findables-and-day.md section 2), scripted with two
#         players and the day loop: the arrival doors stay open while anyone active is aboard (120 s) and close
#         2 s after the car empties, pushing nobody; a player aboard records nothing; boarding lasts 30 s; the
#         player the car leaves is left out for the day (not back on the next floor, no share of the bank) and
#         wakes on their bunk at home. Off: the 12 s push-out, 20 s of boarding, and back on the next floor.
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Entity = preload("res://sim/entity.gd")
const Stamina = preload("res://sim/stamina.gd")
const Instr = preload("res://sim/instrument.gd")
const TapeLib = preload("res://sim/tape.gd")
const Move = preload("res://sim/move.gd")
const HostRules = preload("res://net/host_rules.gd")
const Harness = preload("res://tests/net_harness.gd")
const PropNet = preload("res://tests/prop_net.gd")
const Waits = preload("res://tests/waits.gd")

const DT := 0.05
const EPS := 1e-9

# ---------------------------------------------------------------------------------------------
# T20a. Drawn in the dark.

func test_t20a_the_orderly_is_drawn_in_the_dark(t: T) -> void:
	var n := 2 if t.quick else 6
	var secs := 40.0 if t.quick else 60.0
	var shown := 0
	var dark := 0
	var bad: Array[String] = []
	var moved: Array[String] = []
	var blackouts := 0
	for i in n:
		var cfg := Harness.lossy() if i % 2 == 0 else Harness.zero()
		var r := PropNet.run_session(i, cfg, secs, true)
		shown += r.dark_shown
		dark += r.dark_frames
		bad.append_array(r.dark_drawn)
		moved.append_array(r.violations)
		blackouts += r.blackouts
	t.check(bad.is_empty(), "dark frames that did not draw it as the snapshots say, or held or saw it: %d, first %s" % [bad.size(), bad[0] if not bad.is_empty() else ""])
	t.check(moved.is_empty(), "lit frame pairs where a watched Orderly moved: %d, first %s" % [moved.size(), moved[0] if not moved.is_empty() else ""])
	t.check(dark > 0 and shown > 0, "not vacuous: dark frames %d, of them drawing it %d" % [dark, shown])
	# The control: off, as every stored result has it, no dark frame draws it.
	var off := PropNet.run_session(0, Harness.lossy(), secs)
	t.check(off.dark_drawn.is_empty() and off.dark_shown == 0, "off: dark frames drawing it %d" % off.dark_drawn.size())
	t.note("%d sessions: %d dark frames, %d of them drew the Orderly (never held, never seeing), %d blackouts; off: %d dark frames, none drew it" % [n, dark, shown, blackouts, off.dark_frames])

# ---------------------------------------------------------------------------------------------
# T20c. The long dark.

func test_t20c_the_blackout_is_longer_and_the_ladder_still_fits(t: T) -> void:
	var n := 60 if t.quick else 400
	var sum_on := 0.0
	var sum_off := 0.0
	var count := 0
	var lo_seen := INF
	var hi_seen := 0.0
	var blinks := 0
	var capped := 0
	for i in n:
		for depth: int in [1, 2, 3]:
			var seed := "ld-%d" % i
			var off := Run.call_plan(seed, i % 3, -1, depth)
			var on := Run.call_plan(seed, i % 3, -1, depth, true)
			var tag := "%s depth %d" % [seed, depth]
			t.check(on.wait == off.wait and on.floors == off.floors and on.false_stop == off.false_stop, "%s: the wait itself is unchanged" % tag)
			var b := on.darks[on.darks.size() - 1]
			t.check(b.blackout and absf(b.at + b.len - on.wait) < 1e-9, "%s: the blackout ends as the car arrives" % tag)
			var lo := Run.LONG_BLACKOUT_FIRST_MIN if depth == 1 else Run.LONG_BLACKOUT_MIN
			var hi := Run.LONG_BLACKOUT_FIRST_MAX if depth == 1 else Run.LONG_BLACKOUT_MAX
			# The cap: the first blink (at most 1 + 0.6 + 4 s with its gap) still fits after BLINK_FIRST_AFTER.
			var cap := on.wait - Run.BLACKOUT_WARNING - Run.BLINK_FIRST_AFTER - (Run.BLINK_LADDER[0] + Run.BLINK_WARNING + 4.0)
			t.check(b.len <= hi + 1e-9 and b.len >= minf(lo, cap) - 1e-9, "%s: blackout %.2f s, want %.0f-%.0f (or the cap %.2f)" % [tag, b.len, lo, hi, cap])
			if b.len < lo - 1e-9:
				capped += 1
			t.check(on.darks.size() >= 2, "%s: at least one blink before the blackout (%d darks)" % [tag, on.darks.size()])
			t.check(on.darks[0].at - on.darks[0].warn >= Run.BLINK_FIRST_AFTER - 1e-9, "%s: the first warning comes after %.1f s" % [tag, Run.BLINK_FIRST_AFTER])
			for k in on.darks.size() - 1:
				var d := on.darks[k]
				var nx := on.darks[k + 1]
				t.check(d.at + d.len <= nx.at - nx.warn + 1e-9, "%s: dark %d is over before the next warning" % [tag, k])
				t.check(k == 0 or d.len > on.darks[k - 1].len, "%s: each blink longer than the last" % tag)
			sum_on += b.len
			sum_off += off.darks[off.darks.size() - 1].len
			lo_seen = minf(lo_seen, b.len)
			hi_seen = maxf(hi_seen, b.len)
			blinks += on.darks.size() - 1
			count += 1
	t.check(sum_on / count >= sum_off / count + 5.0, "the blackout is longer on average: %.1f s against %.1f s" % [sum_on / count, sum_off / count])
	# A run made with it uses those plans; without it, the old ones.
	for flag: bool in [true, false]:
		var s := _parked(Run.create_run("ld-run", ["a"] as Array[String]))
		if flag:
			s = Run.with_long_dark(s)
		s = _call_from_landing(s)
		var want := Run.call_plan("ld-run", 0, -1, 1, flag)
		t.check(s.call != null and s.call.plan.darks[s.call.plan.darks.size() - 1].len == want.darks[want.darks.size() - 1].len,
			"a run %s the long dark: its call has the %s blackout" % ["with" if flag else "without", "long" if flag else "short"])
	t.note("%d plans: blackout mean %.1f s (was %.1f), %.1f-%.1f s, %d capped to fit the first blink; %.2f blinks before it on average" % [
		count, sum_on / count, sum_off / count, lo_seen, hi_seen, capped, float(blinks) / count])

# ---------------------------------------------------------------------------------------------
# T20h. Paced.

func test_t20h_a_bigger_tank_and_residents_to_match(t: T) -> void:
	# The tank: a full one sprints this long before it runs dry.
	for tank: float in [Stamina.SPRINT_SECONDS, Stamina.PACED_SPRINT_SECONDS]:
		var st := Stamina.fresh_stamina(tank)
		var secs := 0.0
		while not st.winded and secs < 30.0:
			st = Stamina.step_stamina(st, &"sprint", Stamina.SPRINT_SPEED, DT)
			secs += DT
		t.check(absf(secs - tank) <= DT + 1e-6, "a full %.0f s tank sprints %.2f s" % [tank, secs])
	# Fleeing stays near the hunt: never a plan by itself (within 5 %), never worse than today, and the
	# residents are faster than today.
	var today := Stamina.sustained_flee_speed() / Entity.HUNT_SPEED
	var paced := Stamina.sustained_flee_speed(Stamina.PACED_SPRINT_SECONDS) / Run.PACED_HUNT_SPEED
	t.check(paced >= today and paced < 1.05 and Run.PACED_HUNT_SPEED > Entity.HUNT_SPEED, "sustained flee over the hunt: %.4f paced, %.4f today" % [paced, today])
	# The run: the Orderly hunts at the paced speed (and the tank's size is the paced one).
	for flag: bool in [false, true]:
		var top := 0.0
		for i in 6:
			var s := Waits.wait_start("pace-%d" % i, 2, 1)
			if flag:
				s = Run.with_paced(s)
			t.eq(Run.sprint_seconds(s), Stamina.PACED_SPRINT_SECONDS if flag else Stamina.SPRINT_SECONDS, "the run's tank")
			var body := Run.car_body(s.car, -0.8, 0.0)
			for k in 60:
				# Facing the car: it comes from behind, unseen.
				var inp := Run.PlayerInput.make(s.players[0].id, body, 1.65, Entity.yaw_toward(s.car.in_x, s.car.in_z), 0.0, 90.0, 70.0)
				s = Run.step_run(s, [inp] as Array[Run.PlayerInput], DT).state
				top = maxf(top, s.orderly.speed)
		var want := Run.PACED_HUNT_SPEED if flag else Entity.HUNT_SPEED
		# (Its reported speed is the distance it covered over the tick: a hair over on a stair or a corner.)
		t.check(absf(top - want) < 0.02, "%s: the Orderly's top hunting speed %.3f, want %.3f" % ["paced" if flag else "off", top, want])
	t.eq(HostRules.new(true, 1, [], false, false, false, false, false, false, true).prepare(Run.create_run("p", ["a"] as Array[String])).paced, true, "the rules, asked")
	t.eq(HostRules.new(true, 1).prepare(Run.create_run("p", ["a"] as Array[String])).paced, false, "the rules' default")
	# Over the network: the host steps the paced tank, and every client is told its size.
	for flag: bool in [false, true]:
		var h := Harness.new("pace-net", 1, Harness.lossy())
		if flag:
			h.host.state = Run.with_paced(h.host.state)
		h.run(4.0)
		for m in h.machines:
			var hs := m.client.host_stamina
			var want := Stamina.PACED_SPRINT_SECONDS if flag else Stamina.SPRINT_SECONDS
			t.check(hs != null and hs.tank == want, "%s: %s is told a %.0f s tank (got %s)" % ["paced" if flag else "off", m.id, want, str(hs.tank) if hs != null else "none"])
			t.check(m.client.correct_stamina(Stamina.fresh_stamina()).tank == want, "%s: %s's own tank takes the host's size" % ["paced" if flag else "off", m.id])
	t.note("tanks 5 and 7 s; sustained flee over the hunt %.4f today, %.4f paced; the Orderly hunts at %.2f m/s paced" % [today, paced, Run.PACED_HUNT_SPEED])

# ---------------------------------------------------------------------------------------------
# FD4. The car waits.

## A player's input: standing at `body`, facing (fx, fz).
static func _inp(id: String, body: Move.Body, fx: float = 0.0, fz: float = -1.0, raised: Variant = null) -> Run.PlayerInput:
	var p := Run.PlayerInput.make(id, body, 1.65, Entity.yaw_toward(fx, fz), 0.0, 90.0, 70.0)
	p.raised = raised
	return p

## The run with its resident parked for good (dormant, where it starts): these scripts are about the car.
static func _parked(s: Run.RunState) -> Run.RunState:
	var c := s.copy()
	c.orderly = HostRules.parked_orderly(s)
	return c

## Steps until the car has been called from the landing by the first player.
static func _call_from_landing(s0: Run.RunState) -> Run.RunState:
	var s := s0
	for k in 200:
		if s.phase == &"away":
			break
		var ins: Array[Run.PlayerInput] = []
		for p in s.players:
			ins.append(_inp(p.id, Run.car_body(s.car, -1.2, 0.0)))
		s = Run.step_run(s, ins, DT).state
	var ins2: Array[Run.PlayerInput] = []
	for p in s.players:
		var i := _inp(p.id, Run.car_body(s.car, -1.0, 0.0))
		i.call = p.id == s.players[0].id
		ins2.append(i)
	return Run.step_run(s, ins2, DT).state

## The FD4 script: players A and B with the day loop, the resident parked. `where` gives each player's spot
## per tick ("in", "bank", "down", "out"); returns the events.
class Fd4Script:
	var s: Run.RunState
	var events: Array[Dictionary] = []
	var where := {"A": "in", "B": "in"}

	func _init(waits: bool) -> void:
		s = Run.create_run("fd4", ["A", "B"] as Array[String], [], true)
		if waits:
			s = Run.with_car_waits(s)
		s = _park(s)

	static func _park(st: Run.RunState) -> Run.RunState:
		var c := st.copy()
		c.orderly = HostRules.parked_orderly(st)
		return c

	func spot(id: String) -> Move.Body:
		var v := -1.0 if id == "A" else 1.0
		match String(where[id]):
			"in":
				return Run.car_body(s.car, 1.3, v)
			"bank":
				return Run.car_body(s.car, 2.0, -1.0)
			"down":
				return Run.car_body(s.car, 2.0, 1.0)
		return Run.car_body(s.car, -1.0, v * 0.5)

	## One tick; A presses the call when `call`. Returns this tick's events.
	func tick(call: bool = false) -> Array[Dictionary]:
		var ins: Array[Run.PlayerInput] = []
		for p in s.players:
			# As the host: only a player on their feet gives the run an input.
			if p.status != &"ok":
				continue
			var i := Run.PlayerInput.make(p.id, spot(p.id), 1.65, Entity.yaw_toward(s.car.in_x, s.car.in_z), 0.0, 90.0, 70.0)
			i.call = call and p.id == "A"
			ins.append(i)
		var r := Run.step_run(s, ins, DT)
		s = r.state
		for e in r.events:
			if e["type"] == "rodeDown" or e["type"] == "rodeUp":
				s = _park(s)
		events.append_array(r.events)
		return r.events

	## Ticks until an event of `type` (at most `secs`); returns it, or null.
	func until(type: String, secs: float, call: bool = false) -> Variant:
		for k in int(secs / DT):
			for e in tick(call and k == 0):
				if e["type"] == type:
					return e
		return null

	func player(id: String) -> Run.RunPlayer:
		for p in s.players:
			if p.id == id:
				return p
		return null

func test_fd4_the_car_waits(t: T) -> void:
	for waits: bool in [true, false]:
		var tag := "waits" if waits else "off"
		var sc := Fd4Script.new(waits)
		t.check(sc.until("doorsOpened", 2.0) != null, "%s: the doors open on arrival" % tag)
		# A stays aboard, B steps out.
		sc.where["B"] = "out"
		var opened := sc.s.t
		var closed: Variant = sc.until("doorsClosed", 120.0)
		if waits:
			t.check(closed == null and sc.s.phase == &"unloading", "%s: the doors stay open while A is aboard (120 s; phase %s)" % [tag, sc.s.phase])
			sc.where["A"] = "out"
			var out_at := sc.s.t
			closed = sc.until("doorsClosed", 10.0)
			t.check(closed != null and (closed["pushedOut"] as Dictionary).is_empty(), "%s: the doors close with nobody pushed out" % tag)
			if closed != null:
				var after := float(closed["t"]) - out_at
				t.check(after >= Run.UNLOAD_EMPTY_CLOSE - DT - EPS and after <= Run.UNLOAD_EMPTY_CLOSE + DT + EPS, "%s: they close %.2f s after the car empties" % [tag, after])
		else:
			t.check(closed != null and absf(float(closed["t"]) - opened - Run.UNLOAD_TIME) <= DT + EPS and (closed["pushedOut"] as Dictionary).has("A"),
				"%s: A is pushed out after %.0f s" % [tag, Run.UNLOAD_TIME])
			sc.where["A"] = "out"
		# A calls the car; it comes back; A boards DOWN, B stays out.
		t.check(sc.s.phase == &"away", "%s: the car is away" % tag)
		var arrived: Variant = sc.until("carArrived", 90.0, true)
		t.check(arrived != null, "%s: the car comes back" % tag)
		sc.where["A"] = "down"
		var bell: Variant = sc.until("bell", 40.0)
		var want_board := Run.BOARD_TIME_WAITS if waits else Run.BOARD_TIME
		t.check(bell != null and arrived != null and absf(float(bell["t"]) - float(arrived["t"]) - want_board) <= DT + EPS,
			"%s: boarding lasts %.0f s (bell %.2f s after the doors opened)" % [tag, want_board, float(bell["t"]) - float(arrived["t"]) if bell != null and arrived != null else -1.0])
		t.eq(String(sc.player("B").status), "leftBehind", "%s: B is left behind as the car leaves" % tag)
		t.eq(sc.s.left_out.has("B"), waits, "%s: B is left out for the day" % tag)
		var rode: Variant = sc.until("rodeDown", 10.0)
		t.check(rode != null, "%s: the car rides down" % tag)
		var b := sc.player("B")
		if waits:
			t.check(b.status == &"leftBehind" and not b.aboard and not Run.in_car(sc.s.car, b.body), "%s: B is not back on floor 2 (status %s, aboard %s)" % [tag, b.status, b.aboard])
		else:
			t.check(b.status == &"ok" and b.aboard, "%s: B is back in the car on floor 2" % tag)
			continue
		# Floor 2: B stays out of the run; A steps out, calls, and banks a reading alone.
		sc.until("doorsOpened", 2.0)
		sc.where["A"] = "out"
		sc.until("doorsClosed", 10.0)
		t.eq(String(sc.player("B").status), "leftBehind", "%s: B is still out of the run on floor 2" % tag)
		t.check(sc.until("carArrived", 90.0, true) != null, "%s: the car comes back on floor 2" % tag)
		sc.s = _with_reading(sc.s, "A", 5000.0)
		sc.where["A"] = "bank"
		var day: Variant = sc.until("dayEnded", 40.0)
		t.check(day != null, "%s: A banks and the day is settled" % tag)
		var banked: Variant = null
		for e in sc.events:
			if e["type"] == "banked":
				banked = e
		if banked != null:
			var sm: Run.RunSummary = banked["summary"]
			t.check(float(sm.shares.get("B", -1.0)) == 0.0 and float(sm.shares.get("A", 0.0)) == sm.total and sm.total > 0.0,
				"%s: the bank's summary gives B nothing and A all %.1f (shares %s)" % [tag, sm.total, str(sm.shares)])
		if day != null:
			var credits: Dictionary = (day["result"] as Dictionary)["credits"]
			t.check(int(credits.get("B", 0)) == 0 and int(credits.get("A", 0)) > 0, "%s: credits paid: %s" % [tag, str(credits)])
		t.check(sc.until("rodeUp", 12.0) != null, "%s: the car rides home" % tag)
		b = sc.player("B")
		t.check(b.status == &"ok" and Run.at_bunk(sc.s.plan, b.body) and sc.s.left_out.is_empty(), "%s: B wakes on their bunk at home" % tag)

## `s` with a closed reading of `value` on player `id`'s tape (what a floor's work would have put there).
static func _with_reading(s0: Run.RunState, id: String, value: float) -> Run.RunState:
	var s := s0.copy()
	var c := s.crew.copy()
	var members: Array[Instr.CrewMember] = []
	for m in s.crew.members:
		var nm := m.copy()
		if m.id == id:
			var r := TapeLib.Reading.new()
			r.id = "fd4-reading"
			r.player_id = id
			r.entity_id = s.entity_id
			r.trait_name = &"stillness"
			r.value = value
			r.duration = 3.0
			r.peak_rate = value / 3.0
			r.closed_at = s.t
			nm.tape = TapeLib.add_reading(m.tape, r)
		members.append(nm)
	c.members = members
	s.crew = c
	return s

func test_fd4_a_player_aboard_records_nothing(t: T) -> void:
	var n := 6 if t.quick else 20
	var recorded_off := 0.0
	var seeds_off := 0
	var recorded_on := 0.0
	var closed_on := 0
	for waits: bool in [false, true]:
		for i in n:
			# The doors open on arrival, A aboard with the instrument up (facing the back wall), B on the
			# landing facing the car, the Orderly hunting some way off: it comes for B past the open car.
			var s := Waits.wait_start("fd4-rec-%d" % i, 1 + i % 3, 2)
			if waits:
				s = Run.with_car_waits(s)
			s.phase = &"unloading"
			s.timer = Run.UNLOAD_TIME
			s.empty_for = 0.0
			var a_id := s.players[0].id
			var b_id := s.players[1].id
			var rec := 0.0
			for k in int(8.0 / DT):
				var ins: Array[Run.PlayerInput] = []
				ins.append(_inp(a_id, Run.car_body(s.car, 0.8, 0.0), s.car.in_x, s.car.in_z, true))
				ins.append(_inp(b_id, Run.car_body(s.car, -0.9, 0.6), s.car.in_x, s.car.in_z))
				var r := Run.step_run(s, ins, DT)
				s = r.state
				for e in r.events:
					if e["type"] == "readingClosed" and e["playerId"] == a_id and waits:
						closed_on += 1
			rec = Instr.member(s.crew, a_id).instrument.recorded
			if waits:
				recorded_on += rec
			else:
				recorded_off += rec
				if rec > 0.0:
					seeds_off += 1
	t.check(recorded_on == 0.0 and closed_on == 0, "the car waits: a player aboard recorded %.1f, %d readings" % [recorded_on, closed_on])
	t.check(seeds_off > 0, "not vacuous: off, the player aboard recorded in %d of %d waits (%.1f in all)" % [seeds_off, n, recorded_off])
	t.note("%d scenes each way: aboard with the instrument up, off %.1f recorded (%d scenes), the car waits 0" % [n, recorded_off, seeds_off])
