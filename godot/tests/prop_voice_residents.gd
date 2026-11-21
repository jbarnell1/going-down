# VC1, which residents hear a player's real voice (sim/run.gd "VC1"). The design: hearing residents react to it
# (North Star B5); residents keep one rule each, so the Orderly (Stillness) and the Temp (Lonely) never hear it. Each
# hearing resident's share is a live setting, 0 deaf. Proved here:
#   1. The Orderly and the Temp ignore voices: with the flag on, a crew shouting the whole time on a Clinic and an
#      Annex floor is the same run, tick for tick, as a silent one.
#   2. The Minder: talking within its reach angers it at the voice rate; beyond it, nothing; a talking hider during a
#      count is heard (a reason at their hide); minder.voice 0 is deaf.
#   3. The Reactor's four: a talking player out of sight through a wall is sensed, a silent one is not; Soft Shoes
#      does not quieten a voice; reactor.voice 0 is deaf.
#   4. The Rigger: talking at a house within rigger.voice_reach is heard standing still; a whisper there is not;
#      Soft Shoes does not quieten it; 0 is never.
#   5. The Groundskeeper's 0 is deaf (prop_voice_noise shows it hears); each share reads its own row.
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Places = preload("res://sim/places.gd")
const Settings = preload("res://sim/settings.gd")
const Noises = preload("res://sim/noise.gd")
const Seek = preload("res://sim/seek.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const M = preload("res://sim/jsmath.gd")
const SR = preload("res://sim/station_floor.gd")
const Station = preload("res://sim/station.gd")
const Ward = preload("res://sim/ward/state.gd")
const HostRules = preload("res://net/host_rules.gd")
const Off = preload("res://tests/prop_voice_off.gd")
const MH = preload("res://tests/prop_minder_hunt.gd")
const PS = preload("res://tests/prop_seek.gd")
const EF = preload("res://tests/prop_economy_fix.gd")

const DT := 0.05

# ---------------------------------------------------------------------------------------------
# 1. The Orderly and the Temp.

func test_the_orderly_and_the_temp_never_hear_a_voice(t: T) -> void:
	var secs := 30.0 if t.quick else 90.0
	var seen := {}
	for seed: String in ["vc1-off-0", "vc1-off-1", "vc1-off-2", "vc1-off-3"]:
		for depth in range(1, 5):
			var place := Places.generate(seed, depth, Places.FULL).place
			if place != &"clinic" and place != &"annex":
				continue
			if seen.has(place) and t.quick:
				continue
			seen[place] = true
			var quiet := Off._bot_run(seed, depth, true, 0, secs)
			var loud := Off._bot_run(seed, depth, true, 15, secs)
			var at := Off._first_diff(quiet, loud)
			t.check(at < 0, "%s floor %d (%s): the voice on, shouting is the same run as silence (first differs at tick %d)" % [seed, depth, place, at])
	t.check(seen.has(&"clinic") and seen.has(&"annex"), "a Clinic and an Annex floor were tried (%s)" % str(seen.keys()))

# ---------------------------------------------------------------------------------------------
# 2. The Minder.

static func _minder(i: int) -> MH.Sk:
	var ids: Array[String] = ["q"]
	return MH.sk(i, ids, true, false)

## The player `d` metres from the Minder (along x), its voice carrying `r` metres, for `secs`. Returns the anger.
static func _anger_after(k: MH.Sk, d: float, r: float, secs: float) -> float:
	var m := k.s.minder.body
	var at := Move.Body.make(m.x + d, m.z, m.level, 0.0)
	for _n in roundi(secs / DT):
		var inp := PS.inp("q", at)
		inp.voice_r = r
		var ins: Array[Seek.SeekInput] = [inp]
		k.step(ins)
	return k.s.anger

func test_the_minder_hears_talking(t: T) -> void:
	for i in (2 if t.quick else 5):
		var near := _anger_after(_minder(i), 3.0, 8.0, 0.5)
		var far := _anger_after(_minder(i), 10.0, 8.0, 0.5)
		var silent := _anger_after(_minder(i), 3.0, 0.0, 0.5)
		t.check(near > 0.1, "floor %d: talking 3 m from it for 0.5 s angers it (%.3f)" % [i, near])
		t.check(absf(near - Seek.ANGER_RATES[&"voice"] * 0.5) < 0.06, "floor %d: at the voice rate (%.3f, want about %.3f)" % [i, near, Seek.ANGER_RATES[&"voice"] * 0.5])
		t.eq(far, 0.0, "floor %d: talking 10 m away (8 m reach): nothing" % i)
		t.eq(silent, 0.0, "floor %d: silent: nothing" % i)

func test_a_talking_hider_is_heard_in_a_count(t: T) -> void:
	var heard := 0
	var tried := 0
	for i in (2 if t.quick else 5):
		# The Minder is parked far off (prop_minder_hunt): 500 m is a voice that reaches it, 2 m one that does not.
		for r: float in [0.0, 2.0, 500.0]:
			var k := _minder(i)
			var h: Seek.Playroom.Hide = k.s.floor.hides[0]
			var inside := Seek.hide_inside_body(k.s.floor.plan, h)
			var p := k.s.players[0]
			p.phase = &"inside"
			p.hide = h.id
			p.body = inside
			var ev0: Array[Dictionary] = []
			Seek._start_count(k.s, k.s.t, "q", &"sprint", false, ev0)
			var got := false
			for _n in roundi((k.s.hide_len + 2.0) / DT):
				var inp := PS.inp("q", inside)
				inp.voice_r = r if Seek.phase_of(k.s) == &"seek" else 0.0
				var ins: Array[Seek.SeekInput] = [inp]
				for e in k.step(ins):
					if e["type"] == "reason" and e["why"] == "voice" and int(e["hide"]) == h.id:
						got = true
			if r > 100.0:
				tried += 1
				if got:
					heard += 1
			else:
				t.check(not got, "floor %d: a hider silent or out of its reach (%.0f m) is no reason" % [i, r])
	t.check(tried > 0 and heard == tried, "a talking hider in the search is a reason at their hide (%d of %d)" % [heard, tried])

static func _garden_like_run(on: bool) -> Run.RunState:
	var ids: Array[String] = ["a"]
	var s := Run.create_run("vc1-share", ids)
	return Run.with_voice(s) if on else s

func test_each_share_reads_its_own_row_and_0_is_deaf(t: T) -> void:
	var s := _garden_like_run(true)
	var p := s.players[0].copy()
	p.aboard = false
	p.body = Move.Body.make(-50.0, -50.0, 0, 0.0)
	var inp := Run.PlayerInput.make("a", p.body, 1.65, 0.0, 0.0, 90.0, 70.0)
	inp.voice_level = 8
	for id: StringName in [&"groundskeeper.voice", &"minder.voice", &"reactor.voice"]:
		t.eq(Run.voice_reach(s, p, inp, id), 8.0, "%s: talking carries 8 m" % id)
		var others := {&"groundskeeper.voice": 150.0, &"minder.voice": 150.0, &"reactor.voice": 150.0}
		others[id] = 0.0
		var deaf := Run.with_tuning(s, others)
		t.eq(Run.voice_reach(deaf, p, inp, id), 0.0, "%s 0 (the others 150): deaf" % id)
		var half := Run.with_tuning(s, {id: 50.0})
		t.eq(Run.voice_reach(half, p, inp, id), 4.0, "%s 50: half the reach" % id)
	t.eq(Run.voice_reach(_garden_like_run(false), p, inp, &"minder.voice"), 0.0, "the voice off: nothing")
	# The run gives the Minder and the four their own rows (sim/run.gd).
	var src := FileAccess.get_file_as_string("res://sim/run.gd")
	t.check(src.contains("si.voice_r = voice_reach(s, p, i, &\"minder.voice\")"), "the Minder reads minder.voice")
	t.check(src.contains("sc.voice_r = voice_reach(s, p, inp, &\"reactor.voice\")"), "the four read reactor.voice")
	t.check(src.contains("Noises.voice_share(&\"groundskeeper.voice\", s.tuning)"), "the Groundskeeper reads groundskeeper.voice")

# ---------------------------------------------------------------------------------------------
# 3. The Reactor's four.

func test_the_four_hear_a_voice_through_walls(t: T) -> void:
	var rs := EF._reactor(true, "vc1-reactor")
	var s: Run.RunState = rs[1]
	if not t.check(s.station != null, "a Reactor floor"):
		return
	var st: SR.StationFloor = (s.station as SR.StationFloor).copy()
	st.power = SR.Power.EMERGENCY
	var plan := st.plan
	var tried := 0
	var heard := 0
	var bad := 0
	var soft_bad := 0
	for b in st.bodies:
		for k in 36:
			var a := TAU * float(k) / 36.0
			for r: float in [4.0, 6.0]:
				var at := Move.Body.make(b.body.x + cos(a) * r, b.body.z + sin(a) * r, b.body.level, 0.0)
				var cc := Move.cell_of(plan, at)
				if not Floor.is_walkable(plan, at.level, cc.x, cc.y) or Station.creep_only(plan, cc.x, cc.y):
					continue
				var silent := SR.Crew.make("p", at, &"ok", &"walk", false, true)
				if SR.senses_player(st, b, false, silent, false, null):
					continue
				tried += 1
				var talk := SR.Crew.make("p", at, &"ok", &"walk", false, true)
				talk.voice_r = Noises.VOICE_TALK
				if SR.senses_player(st, b, false, talk, false, null):
					heard += 1
				var soft := SR.Crew.make("p", at, &"ok", &"walk", false, true)
				soft.voice_r = Noises.VOICE_TALK
				soft.soft = true
				if not SR.senses_player(st, b, false, soft, false, null):
					soft_bad += 1
				var whisper := SR.Crew.make("p", at, &"ok", &"walk", false, true)
				whisper.voice_r = Noises.VOICE_WHISPER
				if SR.senses_player(st, b, false, whisper, false, null):
					bad += 1
	t.check(tried > 0 and heard == tried, "a standing player out of their sense 4 to 6 m off, talking: sensed (%d of %d)" % [heard, tried])
	t.eq(soft_bad, 0, "Soft Shoes never quietens a voice")
	t.eq(bad, 0, "a whisper (2 m) 4 to 6 m off: not sensed")

# ---------------------------------------------------------------------------------------------
# 4. The Rigger.

## A room on some house's ground floor 3 to 20 m from the middle of the house he is under, and its distance.
static func _rigger_room() -> Array:
	var w0 := Ward.new(8143)
	w0.leave(0.0)
	var lair := w0.lair
	var a := Vector3.ZERO
	var d := 0.0
	for h in w0.houses.size():
		for area: StringName in w0.houses[h].areas:
			var p: Vector3 = w0.houses[h].areas[area]
			var at: Vector3 = w0.houses[h].to_world(Vector3(p.x, 0.0, p.z))
			var dd := w0._flat(at, lair)
			if d < 3.0 and dd >= 3.0 and dd <= 20.0:
				a = at
				d = dd
	return [a, d]

## Whether the Rigger hears a player standing at `at` with the row `extra` for 5 s, rigger.voice_reach `reach`.
static func _rigger_hears(at: Vector3, reach: float, extra: Dictionary) -> bool:
	var w := Ward.new(8143)
	w.tuning = Settings.make({&"rigger.voice_reach": reach})
	w.leave(0.0)
	var evs: Array[Dictionary] = []
	var now := 0.0
	while now < 5.0:
		now += 0.05
		var row := {"position": at}
		row.merge(extra)
		evs.append_array(w.step(now, 0.05, 30.0, {"p1": row}))
	return evs.any(func(e: Dictionary) -> bool: return e.kind == &"line_loaded")

func test_the_rigger_hears_talking(t: T) -> void:
	t.eq(Ward.VOICE_TALK, Noises.VOICE_TALK, "the Rigger's talking is sim/noise.gd's")
	t.eq(Ward.VOICE_SHOUT, Noises.VOICE_SHOUT, "and his shout")
	var room := _rigger_room()
	var a: Vector3 = room[0]
	var d: float = room[1]
	t.check(d >= 3.0, "a room %.2f m from his house's middle" % d)
	var reach := d / 0.875
	t.check(not _rigger_hears(a, reach, {}), "standing silent %.1f m off: not heard" % d)
	t.check(_rigger_hears(a, reach, {"voice": Noises.VOICE_TALK}), "standing talking %.1f m off, the reach %.1f m: heard" % [d, reach])
	t.check(_rigger_hears(a, reach, {"voice": Noises.VOICE_TALK, "soft": true}), "talking in Soft Shoes: still heard")
	t.check(not _rigger_hears(a, reach, {"voice": Noises.VOICE_WHISPER}), "a whisper (a quarter of the reach): not heard")
	t.check(not _rigger_hears(a, 0.0, {"voice": Noises.VOICE_SHOUT}), "rigger.voice_reach 0: never")
	t.check(not _rigger_hears(a, d * 0.9, {"voice": Noises.VOICE_TALK}), "the reach under the distance: not heard")
	t.check(_rigger_hears(a, d * 0.6, {"voice": Noises.VOICE_SHOUT}), "a shout carries twice talking's reach")
