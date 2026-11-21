# MA1, the owner's playtest of 20 Nov (sim/seek.gd "MA1", sim/run.gd minder_calm): "the aggro bar went back to
# cooling down after the first hunt. I don't want the cool down mechanism at all. It should only ever go up or stay
# the same. Any time hiding takes place, a drawer is opened, etc it should aggro a bit. If it sees a user it should
# start walking towards them, and if close enough should take them down when not aggrod. It shouldn't be fast, and if
# it loses eyesight of a player, it should go back to wandering." Each with the flag on and, as the control, off:
#   1. The bar never goes down over a long calm with counts in it, except the tick a count ends, when it resets to
#      empty (the owner, 20 Nov: "Minder's bar resets after a count. But it can only ever creep up until the next
#      hunt is over, when it resets again and the cycle starts over."; the live setting minder.after_hunt, 0, can
#      still raise where it restarts). Off: the calm drains it to 0.
#   2. Getting into a hide adds 10 in 100, opening something 10 (the live settings minder.anger_hide and
#      minder.anger_open); off neither adds anything.
#   3. Between counts it walks to a player in its view, slower than a walk, and grabs them within 1 m; out of its
#      view it goes back to its round. Off: it never leaves its round for a player.
#   4. The flag: off by default in HostRules, and on it reaches the run and the Playroom's seek state.
extends RefCounted

const T = preload("res://tests/t.gd")
const Seek = preload("res://sim/seek.gd")
const Run = preload("res://sim/run.gd")
const Move = preload("res://sim/move.gd")
const Floor = preload("res://sim/floor.gd")
const Places = preload("res://sim/places.gd")
const Settings = preload("res://sim/settings.gd")
const M = preload("res://sim/jsmath.gd")
const HostRules = preload("res://net/host_rules.gd")
const PS = preload("res://tests/prop_seek.gd")
const MH = preload("res://tests/prop_minder_hunt.gd")
const PT = preload("res://tests/prop_party_table.gd")
const CR = preload("res://tests/prop_count_run.gd")

const DT := 0.05
const TEPS := 1e-6

# The owner's words, as numbers chosen for them (the live settings' game values), restated, not imported.
## "resets after a count ... resets again": empty after every hunt.
const O_AFTER := 0.0
const O_AFTER_MAX := 0.6
## What hiding and opening add between counts, set by hand: the bar has crept up before the next hunt ends.
const O_CREPT := 0.35
const O_HIDE := 0.1
const O_OPEN := 0.1
## "It shouldn't be fast": slower than a player's walk (3 m/s).
const O_WALK := 3.0

## The game's Playroom (tuned, the hunt, the party table) on prop_seek's floor `i`, with MA1 on or off, the Minder
## parked far from everything.
static func sk(i: int, ids: Array[String], calm: bool) -> MH.Sk:
	var k := PT.sk(i, ids, true)
	if calm:
		k.s = Seek.with_calm(k.s)
	return k

# ---------------------------------------------------------------------------------------------
# 1. The bar only goes up or stays the same.

func test_the_bar_never_goes_down_but_at_a_counts_end(t: T) -> void:
	var ids: Array[String] = ["q"]
	for i in (2 if t.quick else 6):
		for calm: bool in [true, false]:
			var k := sk(i, ids, calm)
			var gone := MH.gone("q", PS.cell_body(k.s.floor.plan, k.s.floor.plan.landing))
			var quiet: Array[Seek.SeekInput] = [gone]
			k.step(quiet)
			k.s.anger = 0.4
			var drops := 0
			var bad := ""
			var ends := 0
			var prev := k.s.anger
			# Three counts, each started by hand, with the quiet between them; then a long quiet.
			for c in 3:
				var ev0: Array[Dictionary] = []
				Seek._start_count(k.s, k.s.t, "q", &"sprint", false, ev0)
				prev = k.s.anger
				for _n in roundi((k.s.hide_len + k.s.len + Seek.CALM_TIME + 20.0) / DT):
					var evs := k.step(quiet)
					var ended := MH.of_type(evs, "countEnd").size() > 0
					if ended:
						ends += 1
						var want := minf(O_AFTER * float(ends), O_AFTER_MAX)
						if calm and absf(k.s.anger - want) > TEPS:
							bad = "count %d ended: the bar restarts at %.3f, not %.3f" % [ends, k.s.anger, want]
						# It creeps up again before the next hunt (hides, drawers), so the next end has something to reset.
						if calm:
							k.s.anger = O_CREPT
					elif k.s.anger < prev - TEPS:
						drops += 1
					prev = k.s.anger
			var held := k.s.anger
			k.run(quiet, 120.0)
			if calm:
				t.check(drops == 0 and bad == "" and ends == 3, "floor %d: the bar never went down but at the 3 counts' ends, each to empty (%d drops) %s" % [i, drops, bad])
				t.check(absf(held - O_CREPT) < TEPS and k.s.anger == held, "floor %d: crept up to %.3f after the last count, and 120 quiet seconds leave it there (%.3f)" % [i, held, k.s.anger])
			else:
				t.check(drops > 0 and k.s.anger == 0.0, "floor %d off: the calm drains it as before (%d drops, %.3f)" % [i, drops, k.s.anger])

func test_the_floor_after_a_hunt_is_capped_and_never_full(t: T) -> void:
	for n in 12:
		var f := Seek.calm_after_hunt(null, n)
		t.check(absf(f - minf(O_AFTER * n, O_AFTER_MAX)) < TEPS and f < 1.0, "after %d counts it restarts at %.3f (empty)" % [n, f])
	var tuning := Settings.make({&"minder.after_hunt": 30.0})
	t.check(absf(Seek.calm_after_hunt(tuning, 1) - 0.3) < TEPS, "the live setting minder.after_hunt moves it")

# ---------------------------------------------------------------------------------------------
# 2. Hiding and opening things add to it.

func test_hiding_and_opening_add_a_bit(t: T) -> void:
	var ids: Array[String] = ["q"]
	var tried := 0
	for i in (3 if t.quick else 8):
		var f := PS.floor_of(i)
		# The hide whose front spot is furthest from the parked Minder.
		var k0 := sk(i, ids, true)
		var best: Variant = null
		var best_d := -1.0
		for h in f.hide_list:
			var fb := Seek.hide_front_body(f.plan, h)
			var d := M.hypot2(fb.x - k0.s.minder.body.x, fb.z - k0.s.minder.body.z)
			if fb.level == 0 and d > best_d:
				best_d = d
				best = h
		if best == null:
			continue
		tried += 1
		for calm: bool in [true, false]:
			var k := sk(i, ids, calm)
			var front := Seek.hide_front_body(f.plan, best)
			var stand := PS.inp("q", front, &"creep")
			k.step([stand] as Array[Seek.SeekInput])
			k.s.anger = 0.2
			var press := PS.inp("q", front, &"creep")
			press.use = true
			var evs := k.step([press] as Array[Seek.SeekInput])
			var started := MH.of_type(evs, "hideStart").size() == 1
			if calm:
				t.check(started and absf(k.s.anger - (0.2 + O_HIDE)) < TEPS, "floor %d: getting into a hide adds 10 in 100 (%.3f)" % [i, k.s.anger])
			else:
				t.check(started and absf(k.s.anger - 0.2) < TEPS, "floor %d off: getting in adds nothing (%.3f)" % [i, k.s.anger])
			var k2 := sk(i, ids, calm)
			k2.step([stand] as Array[Seek.SeekInput])
			k2.s.anger = 0.2
			var open := PS.inp("q", front, &"creep")
			open.opened = true
			k2.step([open] as Array[Seek.SeekInput])
			t.check(absf(k2.s.anger - (0.2 + (O_OPEN if calm else 0.0))) < TEPS, "floor %d calm %s: opening something (%.3f)" % [i, str(calm), k2.s.anger])
			# Enough of them start a count, named by what filled it.
			if calm:
				var k3 := sk(i, ids, true)
				k3.step([stand] as Array[Seek.SeekInput])
				k3.s.anger = 0.95
				var evs3 := k3.step([press] as Array[Seek.SeekInput])
				var counts := MH.of_type(evs3, "count")
				t.check(counts.size() == 1 and counts[0]["why"] == "hide" and counts[0]["by"] == "q", "floor %d: a hide that fills the bar starts a count (%s)" % [i, str(counts)])
	t.check(tried > 0, "some floor had a hide (vacuous)")
	var tuning := Settings.make({&"minder.anger_hide": 25.0, &"minder.anger_open": 40.0})
	t.check(absf(Seek.calm_hide_anger(tuning) - 0.25) < TEPS and absf(Seek.calm_open_anger(tuning) - 0.4) < TEPS, "the live settings move both")

# ---------------------------------------------------------------------------------------------
# 3. Sees, walks, loses, wanders.

## A level-0 open spot in the Minder's view now (clear line, in the cone), `near` to `far` metres away, or null.
static func spot_in_view(s: Seek.SeekState, near: float, far: float) -> Variant:
	var plan := s.floor.plan
	var m := s.minder
	for y in plan.height:
		for x in plan.width:
			var c := Floor.Pos.make(m.body.level, x, y)
			if not Floor.is_walkable(plan, c.level, c.x, c.y):
				continue
			var b := Move.body_at_cell(plan, c)
			var d := M.hypot2(b.x - m.body.x, b.z - m.body.z)
			if d < near or d > far:
				continue
			if Seek.in_view(plan, m.body, m.yaw, b):
				return b
	return null

## The same spot turned to behind it: the Minder's own body moved `d` metres the other way it faces, if open.
static func spot_behind(s: Seek.SeekState) -> Variant:
	var plan := s.floor.plan
	var m := s.minder
	for d: float in [2.0, 3.0, 4.0, 5.0]:
		var bx := m.body.x - M.sin_js(m.yaw) * -d
		var bz := m.body.z - M.cos_js(m.yaw) * -d
		var b := Move.body_at_cell(plan, Move.cell_of(plan, Move.Body.make(bx, bz, m.body.level, m.body.y)))
		if Floor.is_walkable(plan, m.body.level, Move.cell_of(plan, b).x, Move.cell_of(plan, b).y) and not Seek.in_view(plan, m.body, m.yaw, b) \
			and M.hypot2(b.x - m.body.x, b.z - m.body.z) > 1.5:
			return b
	return null

func test_it_walks_to_a_player_it_sees_and_wanders_when_it_loses_them(t: T) -> void:
	var ids: Array[String] = ["q"]
	var tried := 0
	for i in (4 if t.quick else 10):
		for calm: bool in [true, false]:
			var k := sk(i, ids, calm)
			var m := k.s.minder
			# Let it walk its round a little, so it faces somewhere along a walkway.
			m.timer = 0.0
			var gone := MH.gone("q", PS.cell_body(k.s.floor.plan, k.s.floor.plan.landing))
			k.run([gone] as Array[Seek.SeekInput], 2.0)
			var at: Variant = spot_in_view(k.s, 4.0, 8.0)
			if at == null:
				continue
			if calm:
				tried += 1
			var b: Move.Body = at
			var d0 := M.hypot2(b.x - k.s.minder.body.x, b.z - k.s.minder.body.z)
			var still := PS.inp("q", b, &"creep")
			var fastest := 0.0
			var stalked := 0
			var before := k.s.minder.body
			for _n in 10:
				k.step([still] as Array[Seek.SeekInput])
				fastest = maxf(fastest, M.hypot2(k.s.minder.body.x - before.x, k.s.minder.body.z - before.z) / DT)
				before = k.s.minder.body
				if k.s.minder.goal_kind == &"stalk":
					stalked += 1
			var d1 := M.hypot2(b.x - k.s.minder.body.x, b.z - k.s.minder.body.z)
			if not calm:
				t.check(stalked == 0, "floor %d off: it never walks to a player it sees (%d ticks)" % [i, stalked])
				continue
			t.check(stalked == 10 and d1 < d0 - 0.3, "floor %d: it walks to the player it sees (%.2f m then %.2f m, %d ticks)" % [i, d0, d1, stalked])
			t.check(fastest <= Seek.CALM_STALK_SPEED + 1e-3 and fastest < O_WALK, "floor %d: not fast (%.2f m/s, a walk is 3)" % [i, fastest])
			t.check(k.s.minder.mode == &"wander" and k.s.minder.anim == &"walk", "floor %d: walking, not hunting (%s, %s)" % [i, k.s.minder.mode, k.s.minder.anim])
			# Out of its view: back to its round.
			var away: Variant = spot_behind(k.s)
			if away == null:
				continue
			var hid := PS.inp("q", away, &"creep")
			k.step([hid] as Array[Seek.SeekInput])
			t.check(k.s.minder.goal_kind != &"stalk", "floor %d: out of its view it lets go (%s)" % [i, k.s.minder.goal_kind])
			k.step([hid] as Array[Seek.SeekInput])
			t.check(k.s.minder.goal_kind == &"round" or k.s.minder.anim == &"straighten",
				"floor %d: and goes back to its round (%s)" % [i, k.s.minder.goal_kind])
	t.check(tried >= 2, "floors with a spot in its view: %d (vacuous)" % tried)

func test_close_enough_it_takes_them(t: T) -> void:
	var ids: Array[String] = ["q"]
	var took := 0
	for i in (4 if t.quick else 10):
		var k := sk(i, ids, true)
		k.s.minder.timer = 0.0
		var gone := MH.gone("q", PS.cell_body(k.s.floor.plan, k.s.floor.plan.landing))
		k.run([gone] as Array[Seek.SeekInput], 2.0)
		var at: Variant = spot_in_view(k.s, 3.0, 6.0)
		if at == null:
			continue
		var still := PS.inp("q", at, &"creep")
		var evs := k.run([still] as Array[Seek.SeekInput], 8.0)
		var grabs := MH.of_type(evs, "found")
		t.check(grabs.size() == 1 and grabs[0]["cause"] == "grab", "floor %d: standing still in its view, it comes and takes them (%s)" % [i, str(grabs)])
		t.check(MH.of_type(evs, "count").is_empty(), "floor %d: and no count was needed" % i)
		took += 1
	t.check(took >= 2, "floors tried: %d (vacuous)" % took)

# ---------------------------------------------------------------------------------------------
# 4. The flag.

func test_the_flag_reaches_the_run_and_is_off_by_default(t: T) -> void:
	var off := HostRules.new(true, 4, Places.FULL)
	t.check(not off.minder_calm and not off.down_ring and not off.pn_fixes, "off by default")
	var st0 := off.prepare(Run.create_run("calm-flag", CR.IDS, Places.FULL))
	t.check(not st0.minder_calm, "off: the run does not have it")
	var on := HostRules.new(true, 4, Places.FULL)
	on.playroom_tuned = true
	on.minder_calm = true
	var st := on.prepare(Run.create_run("calm-flag", CR.IDS, Places.FULL))
	t.check(st.minder_calm, "on: the run has it")
	var r := Run.step_run(st, [] as Array[Run.PlayerInput], DT)
	var s1 := r.state
	for _n in 4:
		s1 = Run.step_run(s1, [] as Array[Run.PlayerInput], DT).state
	t.check(s1.seek != null and (s1.seek as Seek.SeekState).calm, "on: the Playroom's seek state has it")
	t.check(Run.with_minder_calm(st0).copy().minder_calm, "copy() keeps it")
