# The party table from the owner's words of 19 Nov (T15h; sim/seek.gd "Party table", sim/run.gd party_table):
# "make it a requirement that the players find their teammate. If the elevator leaves with them still at the
# table, they are effectively dead ... the party horn should be heard pretty far away ... I love the f at the
# table for 3s to free everyone seated with 50 health, but freeing the table should trigger half the aggro bar.
# And the aggro bar should not go down on its own." Each point with the flag on and, as the control, off:
#   1. Fetch: F held 3.0 s at the table frees everyone seated, at their seat's spot with heal.health (50); 2.9 s
#      or a hold let go does nothing; freeing adds half the anger bar, by the fetcher, and starts a count when that
#      fills it; it works during a count too. Off: holding F at the table does nothing.
#   2. The bar never cools by itself (120 quiet seconds) with the flag on; off it cools as before. A count still
#      fills it and the calm after it still empties it.
#   3. The lift leaving with someone seated leaves them out for the day (left_out, "leftBehind" on the next floor),
#      and the warning is on every screen from the moment they sit until the car leaves. Off: they ride down.
#   4. The table is far from the lift on every quick floor of prop_playroom (walking steps from the landing).
#   5. The words on screen, the horn's reach, the flag's parameter, and two clients over the network agreeing on
#      who is seated and who was freed.
extends RefCounted

const T = preload("res://tests/t.gd")
const Seek = preload("res://sim/seek.gd")
const Run = preload("res://sim/run.gd")
const Move = preload("res://sim/move.gd")
const Floor = preload("res://sim/floor.gd")
const Follow = preload("res://sim/follow.gd")
const Playroom = preload("res://sim/playroom.gd")
const Places = preload("res://sim/places.gd")
const Settings = preload("res://sim/settings.gd")
const M = preload("res://sim/jsmath.gd")
const HostRules = preload("res://net/host_rules.gd")
const Host = preload("res://net/host.gd")
const Client = preload("res://net/client.gd")
const Session = preload("res://net/session.gd")
const Transport = preload("res://net/transport.gd")
const Harness = preload("res://tests/net_harness.gd")
const HideView = preload("res://client/hide_view.gd")
const Sfx = preload("res://client/sfx.gd")
const PS = preload("res://tests/prop_seek.gd")
const MH = preload("res://tests/prop_minder_hunt.gd")
const CR = preload("res://tests/prop_count_run.gd")

const DT := 0.05
const TEPS := 1e-6

# The owner's numbers (19 Nov), restated, not imported.
const O_HOLD := 3.0
const O_HEALTH := 50.0
const O_ANGER := 0.5
## The table is at least this far from the lift by walking, on every generated floor. The design only promises
## 12 steps of 2 m (playarea.md section 6); measured on 19 Nov the nearest of prop_playroom's 800 floors is 62 m.
const O_MIN_WALK := 60.0
## The horn is heard across the whole floor: never more than this many dB under its level at the table (the
## orchestrator's reading of "heard pretty far away"; before T15h it fell to 14 dB under by 28 m).
const O_HORN_FLOOR := 10.0

# ---------------------------------------------------------------------------------------------
# Helpers.

## A tuned, hunting seek state on prop_seek's floor `i`, with the party table on or off.
static func sk(i: int, ids: Array[String], party: bool) -> MH.Sk:
	var k := MH.sk(i, ids, true, true)
	if party:
		k.s = Seek.with_party(k.s)
	park(k.s)
	return k

## Puts the Minder on the level-0 walkway cell furthest from both the table and the landing, standing still
## (a straightening that never ends), so it grabs nobody at the table.
static func park(s: Seek.SeekState) -> void:
	var plan := s.floor.plan
	var seat := Seek.point_body(plan, s.floor.seats[0].at, s.floor.seats[0].level)
	var land := Move.body_at_cell(plan, plan.landing)
	var best: Floor.Pos = null
	var best_d := -1.0
	for y in plan.height:
		for x in plan.width:
			if Floor.cell_at(plan, 0, x, y) != Floor.CORRIDOR:
				continue
			var b := Move.body_at_cell(plan, Floor.Pos.make(0, x, y))
			var d := minf(M.hypot2(b.x - seat.x, b.z - seat.z), M.hypot2(b.x - land.x, b.z - land.z))
			if d > best_d:
				best_d = d
				best = Floor.Pos.make(0, x, y)
	var m := s.minder
	m.body = Move.body_at_cell(plan, best)
	m.timer = 1e6
	m.mode = &"wander"
	m.goal_kind = &""
	m.path = []

## Seats `id` at seat `i` (as Seek._take does).
static func seat(s: Seek.SeekState, id: String, i: int) -> void:
	var p := Seek.player_of(s, id)
	var st := s.floor.seats[i]
	p.status = &"taken"
	p.seat = i
	p.phase = &"out"
	p.hide = -1
	p.body = Seek.point_body(s.floor.plan, st.at, st.level)

static func seat_body(s: Seek.SeekState, i: int) -> Move.Body:
	var st := s.floor.seats[i]
	return Seek.point_body(s.floor.plan, st.at, st.level)

## The fetcher's input: standing at seat `i`'s spot (still, a creep), F held or not.
static func holder(s: Seek.SeekState, id: String, i: int, hold: bool) -> Seek.SeekInput:
	var inp := PS.inp(id, seat_body(s, i), &"creep")
	inp.hold = hold
	return inp

static func n_of(evs: Array[Dictionary], ty: String) -> int:
	return MH.of_type(evs, ty).size()

## A Playroom run on floor 4 of the game's deck with the game's switches for it (the car waits, the tuned
## Playroom, the Minder's hunt) and the party table on or off; F held per player in `use`.
class PRig extends CR.Rig:
	var use := {}

	func _init(seed: String, party: bool) -> void:
		super(seed)
		var rules := HostRules.new(true, 4, Places.FULL)
		rules.car_waits = true
		rules.playroom_tuned = true
		rules.minder_hunt = true
		rules.party_table = party
		st = rules.prepare(Run.create_run(seed, CR.IDS, Places.FULL))
		bodies = {}
		for p in st.players:
			bodies[p.id] = p.body
			gait[p.id] = &"creep"

	func inputs() -> Array[Run.PlayerInput]:
		var out := super.inputs()
		for i in out:
			i.use = bool(use.get(i.id, false))
		return out

## Seats `id` in the run as the rules would (seek "taken" at seat `i`, the run's "caught" at the seat).
static func seat_in_run(r: PRig, id: String, i: int) -> void:
	var ss: Seek.SeekState = r.st.seek
	seat(ss, id, i)
	var players: Array[Run.RunPlayer] = []
	for p in r.st.players:
		var np := p.copy()
		if p.id == id:
			np.status = &"caught"
			np.side = null
			np.body = Seek.player_of(ss, id).body
			np.aboard = false
		players.append(np)
	r.st.players = players
	r.bodies[id] = Seek.player_of(ss, id).body

# ---------------------------------------------------------------------------------------------
# 1. Fetch.

func test_three_seconds_frees_everyone_seated_and_costs_half_the_bar(t: T) -> void:
	var n := 3 if t.quick else 6
	var ids: Array[String] = ["a", "b", "c"]
	for i in n:
		for party: bool in [true, false]:
			var tag := "floor %d, party %s" % [i, str(party)]
			var k := sk(i, ids, party)
			seat(k.s, "a", 0)
			seat(k.s, "b", 1)
			var first_t := k.s.t + DT
			var evs: Array[Dictionary] = []
			# 2.9 s: nothing yet.
			for _j in roundi(2.9 / DT):
				evs.append_array(k.step([holder(k.s, "c", 7, true)] as Array[Seek.SeekInput]))
			t.eq(n_of(evs, "tableFreed"), 0, "%s: freed after 2.9 s" % tag)
			t.eq([Seek.player_of(k.s, "a").status, Seek.player_of(k.s, "b").status], [&"taken", &"taken"], "%s: still seated after 2.9 s" % tag)
			if party:
				var st := MH.of_type(evs, "fetchStart")
				t.check(st.size() == 1 and st[0]["playerId"] == "c" and absf(float(st[0]["from"]) - (first_t - DT)) < TEPS and absf(float(st[0]["done"]) - (first_t - DT + O_HOLD)) < TEPS,
					"%s: one fetchStart by c, counting from the start of its first tick (%s)" % [tag, str(st)])
			else:
				t.eq(n_of(evs, "fetchStart"), 0, "%s: off, no fetch" % tag)
			# To 3.0 s.
			var anger0 := k.s.anger
			for _j in 2:
				evs.append_array(k.step([holder(k.s, "c", 7, true)] as Array[Seek.SeekInput]))
			var freed := MH.of_type(evs, "tableFreed")
			if not party:
				t.eq(freed.size(), 0, "%s: off, F held at the table frees nobody" % tag)
				t.eq(Seek.player_of(k.s, "a").status, &"taken", "%s: off, still seated" % tag)
				continue
			t.check(freed.size() == 1 and freed[0]["playerId"] == "c" and freed[0]["freed"] == ["a", "b"] and float(freed[0]["health"]) == O_HEALTH,
				"%s: freed both after 3.0 s (%s)" % [tag, str(freed)])
			t.check(absf(float(freed[0].get("t", 0.0)) - (first_t - DT + O_HOLD)) < TEPS if not freed.is_empty() else false, "%s: freed at exactly 3.0 s held" % tag)
			for q: Array in [["a", 0], ["b", 1]]:
				var p := Seek.player_of(k.s, q[0])
				var sb := seat_body(k.s, q[1])
				t.check(p.status == &"ok" and p.seat == -1 and p.phase == &"out" and p.health == O_HEALTH and p.body.x == sb.x and p.body.z == sb.z,
					"%s: %s back on their feet beside the table with 50 (%s %d %.1f)" % [tag, q[0], p.status, p.seat, p.health])
			t.check(absf(k.s.anger - (anger0 + O_ANGER)) < TEPS, "%s: half the bar added (%.3f -> %.3f)" % [tag, anger0, k.s.anger])
			t.eq(n_of(evs, "count"), 0, "%s: half a bar starts no count" % tag)
			t.eq(Seek.seated_ids(k.s).size(), 0, "%s: nobody seated" % tag)
			# Again, with the bar already over half: freeing fills it and starts a count, by the fetcher, "fetch".
			seat(k.s, "a", 2)
			k.s.anger = 0.6
			var evs2: Array[Dictionary] = []
			for _j in roundi(O_HOLD / DT):
				evs2.append_array(k.step([holder(k.s, "c", 7, true)] as Array[Seek.SeekInput]))
			var cnt := MH.of_type(evs2, "count")
			t.check(n_of(evs2, "tableFreed") == 1 and cnt.size() == 1 and cnt[0]["by"] == "c" and cnt[0]["why"] == "fetch",
				"%s: freeing a bar at 60 fills it: a count by c, fetch (%s)" % [tag, str(cnt)])

func test_a_hold_let_go_starts_again(t: T) -> void:
	var ids: Array[String] = ["a", "c"]
	for i in (2 if t.quick else 5):
		var k := sk(i, ids, true)
		seat(k.s, "a", 0)
		var evs: Array[Dictionary] = []
		for _j in roundi(2.9 / DT):
			evs.append_array(k.step([holder(k.s, "c", 6, true)] as Array[Seek.SeekInput]))
		evs.append_array(k.step([holder(k.s, "c", 6, false)] as Array[Seek.SeekInput]))
		t.eq(n_of(evs, "fetchStop"), 1, "floor %d: letting go stops the hold" % i)
		for _j in roundi(2.9 / DT):
			evs.append_array(k.step([holder(k.s, "c", 6, true)] as Array[Seek.SeekInput]))
		t.eq(n_of(evs, "tableFreed"), 0, "floor %d: two holds of 2.9 s free nobody" % i)
		for _j in 2:
			evs.append_array(k.step([holder(k.s, "c", 6, true)] as Array[Seek.SeekInput]))
		t.eq(n_of(evs, "tableFreed"), 1, "floor %d: the second hold reaches 3.0 s" % i)
		# Out of reach, F held, does nothing.
		seat(k.s, "a", 0)
		var far := PS.cell_body(k.s.floor.plan, k.s.floor.plan.landing)
		var ef: Array[Dictionary] = []
		for _j in roundi(4.0 / DT):
			var inp := PS.inp("c", far, &"creep")
			inp.hold = true
			ef.append_array(k.step([inp] as Array[Seek.SeekInput]))
		t.eq(n_of(ef, "fetchStart") + n_of(ef, "tableFreed"), 0, "floor %d: F held at the landing frees nobody" % i)

func test_freeing_works_during_a_count_and_heals_by_the_setting(t: T) -> void:
	var ids: Array[String] = ["a", "c", "x"]
	for i in (2 if t.quick else 5):
		var k := sk(i, ids, true)
		k.tuning = Settings.make({&"heal.health": 80.0})
		seat(k.s, "a", 0)
		var ev0: Array[Dictionary] = []
		Seek._start_count(k.s, k.s.t, "x", &"sprint", false, ev0)
		var t0 := k.s.t0
		var evs: Array[Dictionary] = []
		for _j in roundi(O_HOLD / DT):
			evs.append_array(k.step([holder(k.s, "c", 5, true)] as Array[Seek.SeekInput]))
		var freed := MH.of_type(evs, "tableFreed")
		t.check(freed.size() == 1 and float(freed[0]["health"]) == 80.0 and Seek.player_of(k.s, "a").health == 80.0, "floor %d: freed in a count with heal.health 80 (%s)" % [i, str(freed)])
		t.check(k.s.counting and k.s.counts == 1 and k.s.t0 == t0 and k.s.anger == 1.0 and n_of(evs, "count") == 0, "floor %d: the count runs on, the bar full" % i)
	t.note("freeing works during a count (in its time to hide here; any phase is allowed)")

func test_off_the_hide_key_at_the_table_is_unchanged(t: T) -> void:
	var ids: Array[String] = ["a", "c"]
	var applied := 0
	for i in (PS.QUICK_FLOORS if t.quick else PS.FLOORS):
		for si in 8:
			var probe := sk(i, ids, true)
			var b := seat_body(probe.s, si)
			if Seek._hide_in_reach(probe.s, b) == null or si == 0:
				continue
			applied += 1
			for party: bool in [true, false]:
				var k := sk(i, ids, party)
				seat(k.s, "a", 0)
				var inp := PS.inp("c", b, &"creep")
				inp.use = true
				k.step([inp] as Array[Seek.SeekInput])
				var ph := Seek.player_of(k.s, "c").phase
				if party:
					t.eq(ph, &"out", "floor %d seat %d: with someone seated, F at the table gets nobody into a hide" % [i, si])
				else:
					t.eq(ph, &"entering", "floor %d seat %d: off, F at the table's hide gets in as before" % [i, si])
			break
	t.check(applied > 0, "no table seat with a hide in reach (vacuous)")
	t.note("%d floors with a hide in reach of a seat" % applied)

# ---------------------------------------------------------------------------------------------
# 2. The bar never cools by itself.

func test_the_bar_never_cools_by_itself(t: T) -> void:
	var ids: Array[String] = ["q"]
	for i in (2 if t.quick else 5):
		for party: bool in [true, false]:
			var k := sk(i, ids, party)
			var gone := MH.gone("q", PS.cell_body(k.s.floor.plan, k.s.floor.plan.landing))
			k.step([gone] as Array[Seek.SeekInput])
			k.s.anger = 0.4
			k.run([gone] as Array[Seek.SeekInput], 120.0)
			if party:
				t.eq(k.s.anger, 0.4, "floor %d: 120 quiet seconds, the bar stays at 40" % i)
			else:
				t.eq(k.s.anger, 0.0, "floor %d: off, 120 quiet seconds cool it to 0" % i)
			# A count fills it; the calm after it empties it (the resets kept).
			var ev0: Array[Dictionary] = []
			Seek._start_count(k.s, k.s.t, "q", &"sprint", false, ev0)
			k.step([gone] as Array[Seek.SeekInput])
			t.eq(k.s.anger, 1.0, "floor %d party %s: full through a count" % [i, str(party)])
			var evs := k.run([gone] as Array[Seek.SeekInput], k.s.hide_len + k.s.len + Seek.CALM_TIME + 1.0)
			t.check(n_of(evs, "countEnd") == 1 and k.s.anger == 0.0, "floor %d party %s: the calm after the count empties it (%.3f)" % [i, str(party), k.s.anger])

# ---------------------------------------------------------------------------------------------
# 3. The lift leaves with someone seated.

## The rig to the moment the car has left after unloading, p1 seated, the Minder parked.
static func seated_run(t: T, seed: String, party: bool) -> PRig:
	var r := PRig.new(seed, party)
	r.run(0.1)
	CR.to_away(t, r)
	park(r.st.seek)
	seat_in_run(r, "p1", 0)
	return r

func test_left_at_the_table_when_the_lift_leaves(t: T) -> void:
	var names := {"p0": "Ann", "p1": "Bob", "p2": "Cy"}
	for i in (1 if t.quick else 3):
		for party: bool in [true, false]:
			var tag := "%d party %s" % [i, str(party)]
			var r := seated_run(t, "party-left-%d" % i, party)
			# [ticks with the warning up, ticks with no warning] (an Array: a lambda captures locals by value).
			var tally := [0, 0]
			var check_warning := func() -> void:
				var w := HideView.party_warning(Host.seek_block(r.st), names)
				if w == "BOB IS AT THE PARTY TABLE. THE LIFT LEAVES WITHOUT THEM.":
					tally[0] += 1
				elif w == "":
					tally[1] += 1
			check_warning.call()
			r.bodies["p0"] = CR.at_door(r)
			r.step()
			r.call_by = "p0"
			r.step()
			t.eq(r.st.phase, &"coming", "%s: called" % tag)
			# Both crewmates wait in the car; p1 stays at the table.
			r.bodies["p0"] = Run.car_body(r.st.car, 2.0, -0.6)
			r.bodies["p2"] = Run.car_body(r.st.car, 2.0, 0.6)
			var left := {}
			for _k in roundi(150.0 / DT):
				var res := r.step()
				check_warning.call()
				for e in res.events:
					if e["type"] == "carLeft" and str(e["reason"]) == "ride":
						left = e
				if not left.is_empty():
					break
			t.check(not left.is_empty(), "%s: the car left (phase %s)" % [tag, r.st.phase])
			var warned: int = tally[0]
			var silent: int = tally[1]
			if party:
				t.check(warned > 0 and silent == 0, "%s: the warning was up every tick from the seat to the car leaving (%d up, %d not)" % [tag, warned, silent])
				t.check(r.st.left_out.has("p1") and not r.st.left_out.has("p0") and not r.st.left_out.has("p2"), "%s: p1 left out for the day (%s)" % [tag, str(r.st.left_out)])
			else:
				t.check(warned == 0, "%s: off, no warning (there is no such rule)" % tag)
				t.check(not r.st.left_out.has("p1"), "%s: off, nobody left out" % tag)
			r.until_event("rodeDown", 10.0)
			t.eq(r.st.depth, 5, "%s: the next floor" % tag)
			if party:
				t.eq(r.rp("p1").status, &"leftBehind", "%s: p1 stays out on the next floor, as a player the car left" % tag)
			else:
				t.check(r.rp("p1").status == &"ok" and r.rp("p1").aboard, "%s: off, p1 rides down with the crew (%s)" % [tag, r.rp("p1").status])
			t.check(r.rp("p0").status == &"ok" and r.rp("p2").status == &"ok", "%s: the crew in the car rode down" % tag)

func test_freed_in_the_run_and_off_unchanged(t: T) -> void:
	for i in (1 if t.quick else 3):
		var lanes: Array = []
		for party: bool in [true, false]:
			var r := seated_run(t, "party-free-%d" % i, party)
			var ss: Seek.SeekState = r.st.seek
			var spot := seat_body(ss, 7)
			r.bodies["p0"] = spot
			r.step()
			r.use["p0"] = true
			var evs := r.run(O_HOLD + DT)
			var freed := CR.of_type(evs, "tableFreed")
			if party:
				var b := r.rp("p1").body
				var sb := seat_body(r.st.seek, 0)
				# Health: 50 as freed; standing still gives back from the next tick on (the hunt's rest).
				var hp := Seek.player_of(r.st.seek, "p1").health
				t.check(freed.size() == 1 and float(freed[0]["health"]) == O_HEALTH and r.rp("p1").status == &"ok" and b.x == sb.x and b.z == sb.z and hp >= O_HEALTH and hp <= O_HEALTH + 1.0,
					"%d: freed in the run, on their feet beside the table (%s, %s)" % [i, str(freed), r.rp("p1").status])
				t.check(absf((r.st.seek as Seek.SeekState).anger - O_ANGER) < TEPS, "%d: the run's bar at half" % i)
			else:
				t.check(freed.is_empty() and r.rp("p1").status == &"caught", "%d: off, still caught at the table" % i)
			lanes.append(r)
		# Off: F held at the table is inert. The same run with nobody holding F is the same tick for tick.
		var a := seated_run(t, "party-free-%d" % i, false)
		var b2 := seated_run(t, "party-free-%d" % i, false)
		var spot2 := seat_body(a.st.seek, 7)
		a.bodies["p0"] = spot2
		b2.bodies["p0"] = spot2
		a.use["p0"] = true
		var differ := 0
		for _k in roundi(20.0 / DT):
			var ea := a.step().events
			var eb := b2.step().events
			if MH.canon_state(a.st.seek) != MH.canon_state(b2.st.seek) or str(ea) != str(eb) or a.st.phase != b2.st.phase:
				differ += 1
				break
		t.eq(differ, 0, "%d: off, F held at the table changes nothing, tick for tick" % i)

# ---------------------------------------------------------------------------------------------
# 4. The table is far from the lift on every generated floor (the generator is not changed).

func test_the_table_is_far_from_the_lift(t: T) -> void:
	var n := 10 if t.quick else 200
	var least := INF
	var least_at := ""
	var too_close: Array[String] = []
	for depth: int in [1, 2, 3, 4]:
		for i in n:
			var plan := Playroom.generate_playroom("seed-%d" % i, depth)
			var dist := Floor.distances_from(plan, plan.landing)
			var best := INF
			for st in Playroom.seats(plan):
				var c := Move.cell_of(plan, Seek.point_body(plan, st.at, st.level))
				var d := dist[Floor.pos_index(plan, c)]
				if d >= 0:
					best = minf(best, float(d) * float(plan.cell_size))
			if best < least:
				least = best
				least_at = "seed-%d/%d" % [i, depth]
			if best < O_MIN_WALK:
				too_close.append("seed-%d/%d %.0f m" % [i, depth, best])
	t.check(too_close.is_empty(), "tables nearer the landing than %.0f m by walking: %s" % [O_MIN_WALK, str(too_close)])
	t.note("%d floors: the nearest table is %.0f m from the landing by walking (%s); at least %.0f m everywhere" % [4 * n, least, least_at, O_MIN_WALK])

# ---------------------------------------------------------------------------------------------
# 5. Words, the horn, the flag, the network.

func test_the_words_on_screen(t: T) -> void:
	var names := {"a": "Ann", "b": "Bob", "c": "Cy"}
	var block := {"anger": 0.0, "party": {"by": "", "from": -1.0}, "players": [
		{"id": "a", "status": "taken", "seat": 0}, {"id": "b", "status": "ok", "seat": -1}, {"id": "c", "status": "taken", "seat": 3}]}
	t.eq(HideView.party_warning(block, names), "ANN AND CY ARE AT THE PARTY TABLE. THE LIFT LEAVES WITHOUT THEM.", "two seated")
	t.eq(HideView.party_warning(block, names, true), "THE LIFT LEAVES WITHOUT YOU. A CREWMATE HOLDING F HERE FOR 3 S FREES YOU.", "the seated player's own")
	(block["players"] as Array)[2]["status"] = "ok"
	t.eq(HideView.party_warning(block, names), "ANN IS AT THE PARTY TABLE. THE LIFT LEAVES WITHOUT THEM.", "one seated")
	(block["players"] as Array)[0]["status"] = "ok"
	t.eq(HideView.party_warning(block, names), "", "nobody seated")
	block.erase("party")
	(block["players"] as Array)[0]["status"] = "taken"
	t.eq(HideView.party_warning(block, names), "", "without the party table, no warning")
	t.eq(HideView.fetch_note(2, -1.0), "HOLD F 3 S  FREE THE PARTY TABLE (2 SEATED)   ITS ANGER +50", "the fetcher's prompt prints what it costs")
	t.eq(HideView.fetch_note(1, 1.24),"FREEING THE PARTY TABLE... 1.2 S   ITS ANGER +50", "the hold's seconds left")
	t.eq(HideView.anger_rates_text(null, true, true), HideView.anger_rates_text(null, true) + ". ONLY A SEARCH EMPTIES IT", "the bar's words say it does not cool by itself")
	t.check(not HideView.anger_rates_text(null, true, false).contains("COOL"), "off: unchanged")
	t.eq(HideView.WHY["fetch"], "FREEING THE PARTY TABLE", "a count's cause")
	# Health's printed rates follow the settings, and are today's words unchanged.
	t.eq(HideView.health_rates_text(true), HideView.HUNT_HEALTH_RATES, "untuned, the hunt's words")
	t.eq(HideView.health_rates_text(false), HideView.HEALTH_RATES, "untuned, the old words")
	t.eq(HideView.health_rates_text(true, Settings.make({&"health.walk": 4.5, &"health.sprint": 12.0, &"health.rest": 0.25})),
		"WALK -4.5/S  SPRINT -12/S ONLY WHILE IT SEARCHES  STILL OR CREEP +0.25/S", "the host's numbers")

func test_the_horn_carries_across_the_floor(t: T) -> void:
	var last := 1.0
	for d: float in [0.0, 5.0, 10.0, 20.0, 40.0, 80.0, 200.0]:
		var db := Sfx.horn_db(d)
		t.check(db <= last + 1e-9 and db >= -O_HORN_FLOOR - 1e-9, "at %.0f m %.1f dB: never quieter than %.0f dB under the table, never louder further off" % [d, db, O_HORN_FLOOR])
		last = db
	t.check(Sfx.horn_db(40.0) > -minf(14.0, 40.0 * 0.5), "it carries further than before T15h (40 m: %.1f dB)" % Sfx.horn_db(40.0))
	t.check(Sfx.HORN_CUTOFF_MIN >= 4000.0, "never muffled past hearing")

static func _one_tick(s: Run.RunState) -> Run.RunState:
	var inputs: Array[Run.PlayerInput] = []
	for p in s.players:
		inputs.append(Run.PlayerInput.make(p.id, p.body, 1.65, 0.0, 0.0, 90.0, 70.0))
	return Run.step_run(s, inputs, DT).state

func test_the_flag_is_the_last_parameter(t: T) -> void:
	var off := HostRules.new(true, 4, Places.FULL, false, false, false, false, false, false, false, true, false, true,
		false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, true)
	t.check(not off.party_table and not off.late_floors, "38 parameters: the party table off")
	var on := HostRules.new(true, 4, Places.FULL, false, false, false, false, false, false, false, true, false, true,
		false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, true, false, true)
	t.check(on.party_table and not on.late_floors, "the 40th parameter turns it on (late_floors_ the 39th)")
	var st := _one_tick(on.prepare(Run.create_run("party-flag", CR.IDS, Places.FULL)))
	t.check(st.party_table and st.seek != null and (st.seek as Seek.SeekState).party, "the run and its seek state have it")
	var st0 := _one_tick(off.prepare(Run.create_run("party-flag", CR.IDS, Places.FULL)))
	t.check(not st0.party_table and st0.seek != null and not (st0.seek as Seek.SeekState).party, "off: neither has it")
	t.check(not Host.seek_block(st0).has("party") and Host.seek_block(st).has("party"), "the seek block carries it only when on")

# The network: two clients, the real NetHost and NetClient over the test network (0 and 100 ms, lossy).

const STEP := 0.025
const FRAME := 0.05
const WALK := 2.6
const RADIUS := 0.3

class NBot:
	var id: String
	var client: Client
	var offset: float
	var next_frame: float
	var body: Move.Body = null
	var path: Array[Floor.Pos] = []
	var next := 0
	var hold := false
	var goal: Move.Body = null
	## Seek block rows seen for p1 in this client's snapshots, in order (status changes only).
	var p1_seen: Array[String] = []
	## A snapshot's seek block said p0 was freeing the table.
	var saw_hold := false

static func _p1_status(c: Client) -> String:
	if c.latest == null or c.latest.get("seek") == null:
		return ""
	for p: Dictionary in c.latest["seek"]["players"]:
		if p["id"] == "p1":
			return str(p["status"])
	return ""

func _nbot_frame(host: Host, b: NBot, g: float) -> void:
	var c := b.client
	var local := g + b.offset
	var lf := Client.LocalFrame.new()
	lf.body = b.body if b.body != null else Move.Body.make(0.0, 0.0, 0, 0.0)
	lf.gait = "walk"
	if c.seed != null and c.latest != null and b.body != null and int(c.latest["depth"]) == c.local_depth:
		var plan := Session.plan_for(str(c.seed), c.local_depth)
		var car := Session.car_for(plan)
		var phase := str(c.latest["phase"])
		if Run.in_car(car, b.body):
			var to := Run.car_body(car, 0.6, 0.0) if Run.car_local(car, b.body.x, b.body.z)[0] > 0.7 else Run.car_body(car, -1.2, 0.0)
			b.body = CountNet.walk_to(plan, phase, b.body, to, WALK)
		elif b.goal != null:
			if b.path.is_empty():
				b.path = Floor.find_path(plan, Move.cell_of(plan, b.body), Move.cell_of(plan, b.goal))
				b.next = 1 if b.path.size() > 1 else 0
			if not Follow.path_done(plan, Follow.PathWalk.make(b.path, b.next), b.body):
				var w := Follow.PathWalk.make(b.path, b.next)
				b.body = Follow.step_path_walk(plan, w, b.body, WALK * FRAME, RADIUS)
				b.next = w.next
			else:
				b.body = CountNet.walk_to(plan, phase, b.body, b.goal, WALK)
		lf.body = b.body
		lf.gait = "walk"
	lf.use = b.hold
	var f := c.frame(local, lf)
	if f.placed != null:
		b.body = f.placed
		b.path = []
	var st := _p1_status(c)
	if st != "" and (b.p1_seen.is_empty() or b.p1_seen[-1] != st):
		b.p1_seen.append(st)
	if c.latest != null and c.latest.get("seek") is Dictionary:
		var pt: Variant = (c.latest["seek"] as Dictionary).get("party")
		if pt is Dictionary and str(pt["by"]) == "p0" and float(pt["from"]) >= 0.0:
			b.saw_hold = true

const CountNet = preload("res://tests/prop_count_net.gd")

func test_two_clients_agree_on_who_is_seated_and_freed(t: T) -> void:
	var saved := Session.deck
	Session.deck = Places.FULL
	var seed := "party-net"
	var n := Harness.lossy()
	var net := Transport.MemoryNetwork.new("%s:net" % seed)
	var ht := net.connect_peer("host")
	var rules := HostRules.new(true, 4, Places.FULL)
	rules.car_waits = true
	rules.playroom_tuned = true
	rules.minder_hunt = true
	rules.party_table = true
	var ids: Array[String] = ["p0", "p1"]
	var host := Host.new(ht, seed, ids, 0.0, Callable(rules, "prepare"), Callable(rules, "step"))
	var bots: Array[NBot] = []
	var delays := [0.0, 0.1]
	for i in ids.size():
		var tr := net.connect_peer(ids[i])
		for pair: Array in [["host", ids[i]], [ids[i], "host"]]:
			net.set_link(pair[0], pair[1], Transport.LinkConfig.make(delays[i], n.jitter, n.loss, n.reorder, n.reorder_delay, n.duplicate))
		var b := NBot.new()
		b.id = ids[i]
		b.offset = 30.0 * i - 10.0
		b.next_frame = 0.013 * i
		b.client = Client.new(tr, "host", ids[i], b.offset)
		bots.append(b)
	var g := 0.0
	var stage := "out"
	var seat_at := -1.0
	var freed_at := -1.0
	while g < 120.0:
		g += STEP
		net.now = g
		host.update(g)
		for b in bots:
			b.client.receive(g + b.offset)
		for b in bots:
			while b.next_frame <= g + 1e-9:
				b.next_frame += FRAME
				_nbot_frame(host, b, g)
		var st := host.state
		if stage == "out" and st.phase == &"away" and st.seek != null:
			# The car has gone: p1 is taken to the table (as the Minder's catch would), the Minder parked away.
			var ss: Seek.SeekState = (st.seek as Seek.SeekState).copy()
			var list: Array[Seek.SeekPlayer] = []
			for q in ss.players:
				list.append(q.copy())
			ss.players = list
			ss.minder = ss.minder.copy()
			park(ss)
			seat(ss, "p1", 0)
			var ns := st.copy()
			ns.seek = ss
			var players: Array[Run.RunPlayer] = []
			for p in st.players:
				var np := p.copy()
				if p.id == "p1":
					np.status = &"caught"
					np.body = Seek.player_of(ss, "p1").body
				players.append(np)
			ns.players = players
			host.state = ns
			host._place("p1", Seek.player_of(ss, "p1").body, ns.depth, ns)
			bots[0].goal = seat_body(ss, 7)
			bots[0].path = []
			stage = "walk"
			seat_at = g
		elif stage == "walk" and bots[0].body != null and bots[0].goal != null and M.hypot2(bots[0].body.x - bots[0].goal.x, bots[0].body.z - bots[0].goal.z) < 0.3:
			bots[0].hold = true
			stage = "hold"
		elif stage == "hold" and freed_at < 0.0:
			for le in host.event_log:
				if le.e["type"] == "tableFreed":
					freed_at = g
			if freed_at >= 0.0:
				bots[0].hold = false
				stage = "after"
		elif stage == "after" and g > freed_at + 3.0:
			break
	Session.deck = saved
	t.check(seat_at >= 0.0, "the car never left (phase %s)" % host.state.phase)
	t.check(freed_at >= 0.0, "the table was never freed (stage %s, p0 at %s)" % [stage, str(bots[0].body)])
	var host_freed: Array = []
	for le in host.event_log:
		if le.e["type"] == "tableFreed":
			host_freed.append([le.e["playerId"], le.e["freed"]])
	t.eq(host_freed, [["p0", ["p1"]]], "the host freed p1, by p0, once")
	for b in bots:
		var mine: Array = []
		var starts := 0
		for e: Dictionary in b.client.events:
			if e.get("type") == "tableFreed":
				mine.append([e["playerId"], e["freed"]])
			elif e.get("type") == "fetchStart" and e.get("playerId") == "p0":
				starts += 1
		t.eq(mine, host_freed, "%s: the same tableFreed as the host" % b.id)
		t.check(starts >= 1, "%s: saw p0 start the hold" % b.id)
		t.check(b.saw_hold, "%s: a snapshot's seek block showed p0 freeing the table" % b.id)
		t.check(b.p1_seen.has("taken") and b.p1_seen[-1] == "ok" and b.p1_seen.find("taken") < b.p1_seen.rfind("ok"), "%s: saw p1 seated, then on their feet (%s)" % [b.id, str(b.p1_seen)])
	var hp1 := Seek.player_of(host.state.seek, "p1")
	t.check(hp1 != null and hp1.status == &"ok" and hp1.health >= O_HEALTH, "the host has p1 on their feet")
	var hf: Array = []
	for le in host.event_log:
		if le.e["type"] == "tableFreed":
			hf.append(float(le.e["health"]))
	t.eq(hf, [O_HEALTH], "freed with 50")
	var sb := seat_body(host.state.seek, 0)
	t.check(bots[1].body != null and absf(bots[1].body.x - sb.x) < 1e-3 and absf(bots[1].body.z - sb.z) < 1e-3, "p1's own client was placed beside the table (%s)" % str(bots[1].body))
	t.note("seated at %.1f s, freed at %.1f s of play" % [seat_at, freed_at])
