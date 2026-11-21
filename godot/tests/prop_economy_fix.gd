# PY1, the owner's pay and stakes fixes of 20-21 Nov (sim/run.gd "PY1", net/host_rules.gd economy_fix). The owner:
# "I'm good with your intercom and pay fixes too."; "Credits can survive the third wipe I guess?"; "Reactor lift needs
# power"; on the Ward, "Car can come back while some are still strung up. Act as if they didn't make it to the elevator
# car which is what happened." Soft Shoes against every listener was in the same approved list. Proved here:
#   1. Off by default; the game's rooms ask for it; with it off every number is the old one (pay, quota, the day
#      quota, the game-over wallets, the refusal, the Ward's hung player, Soft Shoes).
#   2. The pay and quota table for three cycles: floor 8 pays and asks floor 1's times pay.cycle2, floor 15 floor 1's
#      times pay.cycle3; a reading closed on floor 8 is worth what the table says; the day quota follows the cycle.
#   3. What the screens print is what is paid: the host's quota and day blocks reach a client as the rule's numbers,
#      the client knows the rule ("economy") and works out the ride's sheet from the host's own fill quota.
#   4. The third wipe keeps the credits (upgrades still reset); the lift monitor and the prison's report say so.
#   5. The Reactor: the call is refused without power and the panel says why; once the power is back the car comes;
#      a fuse whose holder leaves is dropped where they stood and the next player restores the power; everyone out is
#      the wipe, so the floor always ends.
#   6. The Ward: a player still hung in the web when the car leaves after its 30 s of boarding is left out for the day
#      (no share, not brought back on the next floor), exactly as anyone not aboard.
#   7. Soft Shoes shortens the Reactor's four's and the Rigger's hearing of a walk by the Groundskeeper's share.
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Day = preload("res://sim/day.gd")
const Places = preload("res://sim/places.gd")
const Upgrades = preload("res://sim/upgrades.gd")
const Settings = preload("res://sim/settings.gd")
const Instr = preload("res://sim/instrument.gd")
const Noises = preload("res://sim/noise.gd")
const SR = preload("res://sim/station_floor.gd")
const Station = preload("res://sim/station.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const M = preload("res://sim/jsmath.gd")
const HostRules = preload("res://net/host_rules.gd")
const Host = preload("res://net/host.gd")
const Client = preload("res://net/client.gd")
const Transport = preload("res://net/transport.gd")
const Ward = preload("res://sim/ward/state.gd")
const House = preload("res://sim/ward/house.gd")
const PS = preload("res://tests/prop_station.gd")
const QuotaView = preload("res://client/quota_view.gd")
const PrisonView = preload("res://client/prison_view.gd")
const Sfx = preload("res://client/sfx.gd")

const DT := 0.05

static func _ids(n: int) -> Array[String]:
	var out: Array[String] = []
	for i in n:
		out.append("p%d" % i)
	return out

## A run of the game's rooms (cycles, the pressures) standing on floor `depth`, with the fix on or off.
static func _at(depth: int, on: bool, crew := 2) -> Run.RunState:
	var s := Run.create_run("py1-%d" % depth, _ids(crew), Places.with_cycles(Places.with_reactor(Places.FULL)), true, true, true)
	s = Run.with_pressures(s)
	if on:
		s = Run.with_economy_fix(s)
	s.depth = depth
	s.cycles_done = (depth - 1) / 7
	return s

# ---------------------------------------------------------------------------------------------
# 1. The flag.

func test_off_by_default_and_on_in_the_rooms(t: T) -> void:
	t.check(not HostRules.new(true, 1).economy_fix, "HostRules: off unless asked")
	t.check(not Run.create_run("py1", _ids(2)).economy_fix, "a run made as before: off")
	var r := HostRules.new(true, 1, Places.FULL, true, true)
	r.economy_fix = true
	var s := r.prepare(Run.create_run("py1", _ids(2), Places.FULL))
	t.check(s.economy_fix, "asked for: the prepared run has it")
	t.check(Run.with_economy_fix(Run.create_run("py1", _ids(2))).copy().economy_fix, "copy() keeps it")
	t.check(HostRules.economy_fix_by_arg(), "no economy_fix=0 on this command line: the rooms ask for it")
	var src := FileAccess.get_file_as_string("res://server/room.gd")
	t.check(src.contains("HostRules.economy_fix_by_arg()"), "server/room.gd passes it")
	src = FileAccess.get_file_as_string("res://net/local_room.gd")
	t.check(src.contains("HostRules.economy_fix_by_arg()"), "net/local_room.gd passes it")

func test_flag_off_changes_nothing(t: T) -> void:
	for d in range(1, 22):
		t.eq(Run.pay_multiplier_at(d, false), Run.depth_multiplier(d), "floor %d: pay as before" % d)
		var off := _at(d, false)
		t.eq(Run.pay_multiplier(off), Run.depth_multiplier(d), "floor %d: the run's pay as before" % d)
		for crew: int in [1, 3]:
			var m := Run.pressure_quota_mult(off, null)
			t.eq(Run.floor_quota(d, crew, null, m), Run.floor_quota(d, crew, null, m, false), "floor %d crew %d: the quota as before" % [d, crew])
	# Every flag-off piece, against the old rule written out.
	t.eq(Run.floor_quota(8, 1), 5390, "floor 8 asks 400 x 1.45^7 (rounded to 5)")
	t.eq(Run.floor_quota(8, 1, null, 1.5), 8085, "and x1.5 with the pressures")
	var day := _game_over_day(false)
	t.eq((day.wallets["a"] as Upgrades.UpgradeState).credits, 0, "off: game over takes the credits")
	t.check(not day.credits_kept and not day.facts.has("credits_kept"), "off: no credits_kept fact")
	t.check(Day.stakes_row(Day.bank_preview(_two_misses(), 0, 0, ["a"] as Array[String], _wallets(), 400), 1).ends_with("THIRD MISS: GAME OVER."), "off: the monitor's old row 3")
	var crew := SR.Crew.make("p", Move.Body.make(0, 0, 0, 0.0), &"ok", &"walk", false, true)
	t.check(not crew.soft, "a station crew row is not soft unless the run says so")

# ---------------------------------------------------------------------------------------------
# 2. The table.

func test_pay_and_quota_by_the_cycle(t: T) -> void:
	var lines := PackedStringArray()
	for d in range(1, 22):
		var place := 1 + (d - 1) % 7
		var cycle := 1 + (d - 1) / 7
		var cm := 1.0 if cycle == 1 else (2.0 if cycle == 2 else 4.0)
		var on := _at(d, true)
		t.check(absf(Run.pay_multiplier(on) - M.pow_js(1.35, float(place - 1)) * cm) < 1e-9, "floor %d: pays 1.35^%d x %.0f" % [d, place - 1, cm])
		var pm := Run.pressure_quota_mult(on, null)
		t.eq(pm, 1.0 if cycle == 1 else (1.5 if cycle == 2 else 2.25), "floor %d: the pressures' quota on top" % d)
		for crew: int in [1, 2, 4]:
			var want := maxi(5, roundi(400.0 * crew * M.pow_js(1.45, float(place - 1)) * cm * pm / 5.0) * 5)
			t.eq(Run.floor_quota(d, crew, null, pm, true), want, "floor %d crew %d: asks %d" % [d, crew, want])
		lines.append("%d:%.2f/%d" % [d, Run.pay_multiplier(on), Run.floor_quota(d, 1, null, pm, true)])
		if d <= 7:
			t.eq(Run.pay_multiplier(on), Run.pay_multiplier(_at(d, false)), "floor %d: cycle 1 pays as before" % d)
	t.note("pay x / quota each, floors 1-21: %s" % " ".join(lines))
	# The day quota: a cycle's day owes the cycle's multiplier of cycle 1's (with the pressures on top).
	for cycle: int in [1, 2, 3]:
		var first := Places.cycle_start(cycle - 1)
		var cm := 1.0 if cycle == 1 else (2.0 if cycle == 2 else 4.0)
		var pm := 1.0 if cycle == 1 else (1.5 if cycle == 2 else 2.25)
		t.eq(Run.day_floor_quota(_at(first, true)), roundi(400.0 * cm * pm), "cycle %d: the day's unit is 400 x %.0f x %.2f" % [cycle, cm, pm])
		t.eq(Run.day_floor_quota(_at(first, false)), roundi(400.0 * pm), "cycle %d: off, the day's unit as before" % cycle)
	# Tomorrow's (the prison's board) is the next descent's cycle.
	var home := _at(1, true)
	home.depth = 0
	home.cycles_done = 1
	t.eq(Run._tomorrow_floor_quota(home, ""), roundi(400.0 * 2.0 * 1.5), "in the prison after cycle 1: tomorrow owes cycle 2's")
	t.eq(Run._tomorrow_floor_quota(home, "game_over"), 400, "after a game over: floor 1's")

func test_a_reading_on_floor_8_is_worth_the_table(t: T) -> void:
	for on: bool in [false, true]:
		var s := _at(8, on, 1)
		var c := s.crew.copy()
		var m := c.members[0].copy()
		var inst := m.instrument.copy()
		var r := Instr.OpenReading.new()
		r.entity_id = "orderly-8"
		r.trait_name = &"stillness"
		r.value = 100.0
		r.duration = 2.0
		r.quiet = 5.0
		r.peak_rate = 50.0
		inst.current = r
		m.instrument = inst
		c.members = [m] as Array[Instr.CrewMember]
		s.crew = c
		var holders: Array[Instr.CrewPlayer] = [Instr.CrewPlayer.make("p0", Move.Body.make(0, 0, 0, 0.0), true)]
		var none: Array[Instr.EntityTick] = []
		var out := Run._crew_tick(s, holders, none, DT)
		var closed := out.events.filter(func(e: Dictionary) -> bool: return e["type"] == "readingClosed")
		var want := 100.0 * (2.0 if on else M.pow_js(1.35, 7.0))
		t.check(closed.size() == 1 and absf(float(closed[0]["value"]) - want) < 1e-6, "%s: a 100 reading closed on floor 8 is worth %.2f (%s)" % ["on" if on else "off", want, str(closed)])

# ---------------------------------------------------------------------------------------------
# 3. What the screens print.

class Rig:
	var net: Transport.MemoryNetwork
	var host: Host
	var rules: HostRules
	var clients: Array[Client] = []
	var names: Array[String] = ["one", "two"]
	var now := 0.0

	func _init(rules_: HostRules) -> void:
		net = Transport.MemoryNetwork.new("py1", Transport.LinkConfig.make(0.02, 0.05, 0.0, 0.0, 0.0, 0.0))
		rules = rules_
		host = Host.new(net.connect_peer("host"), "py1", names, now, Callable(rules, "prepare"), Callable(rules, "step"), names)
		for id in names:
			clients.append(Client.new(net.connect_peer(id), "host", id, now))

	func tick_for(seconds: float) -> void:
		for _frame in ceili(seconds / 0.025 - 1e-6):
			now += 0.025
			net.now = now
			for i in clients.size():
				var c := clients[i]
				c.receive(now)
				var local := Client.LocalFrame.new()
				local.body = Move.Body.make(0, 0, 0, 0.0)
				for p in host.state.players:
					if p.id == names[i]:
						local.body = p.body
				c.frame(now, local)
			host.update(now)

func test_printed_numbers_are_the_paid_numbers(t: T) -> void:
	for on: bool in [false, true]:
		var r := PS.rules(8, null)
		r.pressures = true
		r.economy_fix = on
		var rig := Rig.new(r)
		rig.tick_for(2.0)
		var s := rig.host.state
		var tag := "on" if on else "off"
		t.eq(s.depth, 8, "%s: the run is on floor 8" % tag)
		var want := Run.floor_quota(8, 2, null, 1.5, on)
		t.eq(s.floor_needed, want, "%s: the host asks floor 8's quota by the rule (%d)" % [tag, want])
		for c in rig.clients:
			var q: Variant = c.quota()
			t.check(q is Dictionary and int(q["needed"]) == s.floor_needed, "%s: the client's call panel prints the host's %d (%s)" % [tag, s.floor_needed, str(q)])
			var day: Variant = (c.latest as Dictionary).get("day")
			t.check(day is Dictionary and int(day["quota"]) == Run.day_quota_now(s), "%s: the client's day board prints the host's day quota %d (%s)" % [tag, Run.day_quota_now(s), str(day)])
			var marked := (c.latest as Dictionary).get("economy") != null
			t.eq(marked, on, "%s: the client knows the rule" % tag)
			# The ride's sheet (client/main.gd _ride_rows) works out the fill from the host's own fill quota.
			t.eq(Run.floor_quota(8, 2, c.tuning, 1.0, marked), Run.find_base(s, s.players), "%s: the sheet's quota is the host's fill quota" % tag)
			t.check(absf(Run.pay_multiplier_at(8, marked, c.tuning) - Run.pay_multiplier(s)) < 1e-9, "%s: the client's pay multiplier is the host's" % tag)
		if on:
			t.eq(Run.day_quota_now(s), Day.quota_for(s.day_state.level, 2, roundi(400.0 * 2.0 * 1.5)), "on: the day owes cycle 2's (x2, then the pressures' x1.5)")

# ---------------------------------------------------------------------------------------------
# 4. The third wipe keeps the credits.

static func _two_misses() -> Day.DayState:
	var d := Day.DayState.fresh()
	d.misses = 2
	d.day = 3
	d.crew_size = 2
	return d

static func _wallets() -> Dictionary:
	var a := Upgrades.UpgradeState.make(1234)
	a.owned = ["deep_pockets"] as Array[String]
	return {"a": a, "b": Upgrades.UpgradeState.make(77)}

static func _game_over_day(keep: bool) -> Day.DayResult:
	return Day.end_day(_two_misses(), 0, 0, ["a", "b"] as Array[String], _wallets(), 400, "py1", true, false, keep)

func test_the_third_wipe_keeps_credits(t: T) -> void:
	var r := _game_over_day(true)
	t.eq(String(r.outcome), "game_over", "the third miss is still game over")
	t.check(r.game_over and r.state.day == 1 and r.state.misses == 0 and r.state.level == 0, "the night ends as before: day 1, no misses, level 0")
	t.eq((r.wallets["a"] as Upgrades.UpgradeState).credits, 1234, "a keeps 1234 credits")
	t.eq((r.wallets["b"] as Upgrades.UpgradeState).credits, 77, "b keeps 77")
	t.check((r.wallets["a"] as Upgrades.UpgradeState).owned.is_empty(), "the upgrades still go")
	t.eq(r.banked, 0, "the wipe still pays nothing (the day's pay is lost)")
	t.check(r.credits_kept and r.facts.get("credits_kept") == true, "the facts say the credits were kept")
	var pv := Day.bank_preview(_two_misses(), 0, 0, ["a", "b"] as Array[String], _wallets(), 400, false, true)
	t.eq(Day.stakes_row(pv, 2), "IF NOBODY COMES BACK: THIRD MISS: GAME OVER. UPGRADES RESET, CREDITS KEPT.", "the lift monitor prints the stakes before the vote")
	# Through the run: the crew all out on its third miss.
	for on: bool in [false, true]:
		var s := _at(3, on)
		var ds := s.day_state.copy()
		ds.misses = 2
		s.day_state = ds
		var w := {}
		for id: String in ["p0", "p1"]:
			var u := Upgrades.UpgradeState.make(500)
			u.owned = ["second_wind"] as Array[String]
			w[id] = u
		s.wallets = w
		t.check(str(Run.day_preview(s).rows[2]).contains("CREDITS KEPT") == on, "%s: the run's monitor row 3 (%s)" % ["on" if on else "off", Run.day_preview(s).rows[2]])
		var players := s.players.duplicate()
		for i in players.size():
			var p: Run.RunPlayer = players[i].copy()
			p.status = &"out"
			players[i] = p
		s.players = players
		s.phase = &"away"
		var ev: Array[Dictionary] = []
		Run._wipe_if_out(s, s.players, s.t, ev)
		var ended := ev.filter(func(e: Dictionary) -> bool: return e["type"] == "dayEnded")
		t.check(ended.size() == 1 and str(ended[0]["result"]["kind"]) == "game_over", "%s: all out on the third miss is game over" % ("on" if on else "off"))
		var credits: Dictionary = ended[0]["result"]["credits"] if not ended.is_empty() else {}
		t.eq(int(credits.get("p0", -1)), 500 if on else 0, "%s: p0's credits after game over" % ("on" if on else "off"))
		t.eq((s.wallets["p0"] as Upgrades.UpgradeState).owned.size(), 0, "%s: the upgrades reset" % ("on" if on else "off"))
		var report := PrisonView.report_text(ended[0]["result"] if not ended.is_empty() else null, {})
		t.check(report.has("THIRD MISS: UPGRADES RESET, CREDITS KEPT") == on and report.has("THIRD MISS: ALL RESET") == (not on), "%s: the prison's report says what was kept (%s)" % ["on" if on else "off", str(report)])

# ---------------------------------------------------------------------------------------------
# 5. The Reactor's lift needs power.

## The Reactor (floor 7) with the crew out of the car and the car away.
static func _reactor(on: bool, seed := "py1-reactor") -> Array:
	var r := PS.rules(7, true)
	r.economy_fix = on
	var s := r.prepare(Run.create_run(seed, _ids(2), r.deck, true, true, true))
	for k in 400:
		var inputs: Array[Run.PlayerInput] = []
		for i in s.players.size():
			var p := s.players[i]
			var b := p.body
			if s.station != null:
				b = PS._toward(s, b, Run.car_body(s.car, -1.2, -0.5 + float(i)), 3.0 * DT)
			inputs.append(Run.PlayerInput.make(p.id, b, 1.65, 0.0, 0.0, 90.0, 70.0))
		s = r.step(s, inputs, DT).state
		if s.station != null and s.phase == &"away":
			break
	return [r, s]

static func _stand(s: Run.RunState, at: Dictionary, use: Dictionary = {}, call: Dictionary = {}) -> Array[Run.PlayerInput]:
	var out: Array[Run.PlayerInput] = []
	for p in s.players:
		if not at.has(p.id):
			continue
		var b: Move.Body = at[p.id]
		var inp := Run.PlayerInput.make(p.id, b, 1.65, 0.0, 0.0, 90.0, 70.0)
		inp.use = bool(use.get(p.id, false))
		inp.call = bool(call.get(p.id, false))
		out.append(inp)
	return out

func test_reactor_lift_needs_power_and_never_strands(t: T) -> void:
	var sfx := Sfx.new()
	for on: bool in [false, true]:
		var tag := "on" if on else "off"
		var rs := _reactor(on)
		var r: HostRules = rs[0]
		var s: Run.RunState = rs[1]
		t.check(s.station != null and s.phase == &"away", "%s: on the Reactor, the car gone (%s)" % [tag, s.phase])
		var door := Run.car_body(s.car, -1.0, 0.0)
		var here := {"p0": door, "p1": Run.car_body(s.car, -1.2, 0.6)}
		var refusals: Array[Dictionary] = []
		for k in 20:
			var step := r.step(s, _stand(s, here, {}, {"p0": k % 2 == 0}), DT)
			s = step.state
			for e in step.events:
				if e["type"] == "callRefused":
					refusals.append(e)
		t.check(not refusals.is_empty() and refusals.all(func(e: Dictionary) -> bool: return str(e.get("reason", "")) == "power"), "%s: lit, before any cut: the call is refused for want of power" % tag)
		t.eq(s.phase, &"away", "%s: the car does not come" % tag)
		t.eq(refusals[0].has("line") if not refusals.is_empty() else false, on, "%s: the refusal carries the panel's words only with the fix" % tag)
		if on and not refusals.is_empty():
			t.eq(str(refusals[0]["line"]), Run.POWER_REFUSED_LINE, "on: the Company's words")
		# The panel shows them (client/quota_view.gd), where the Reactor asks no quota.
		var qv := QuotaView.new()
		qv.on_events(refusals.slice(0, 1), "p0", sfx, 1000)
		var line := qv.update({"earned": 0, "needed": 0}, null, QuotaView.CALL_PROMPT, 1100)
		t.eq(line, Run.POWER_REFUSED_LINE if on else "", "%s: the call panel's line after the press" % tag)
		# The power goes out; the holder takes the fuse and leaves the game halfway; the fuse lies where they were; p1
		# takes it, installs it, and the held car opens: boarding, at the Reactor's own boarding time.
		var st := (s.station as SR.StationFloor).copy()
		st.power = SR.Power.EMERGENCY
		st.hold_left = 0.0
		s.station = st
		var fuse := Move.Body.make(st.fuse.x, st.fuse.z, 0, 0.0)
		s = r.step(s, _stand(s, {"p0": fuse, "p1": here["p1"]}, {"p0": true}), DT).state
		t.eq((s.station as SR.StationFloor).holder, "p0", "%s: p0 holds the fuse" % tag)
		var mid := Move.Body.make((st.fuse.x + st.cabinet.x) / 2.0, (st.fuse.z + st.cabinet.z) / 2.0, 0, 0.0)
		s = r.step(s, _stand(s, {"p0": mid, "p1": here["p1"]}), DT).state
		var gone := r.step(s, _stand(s, {"p1": here["p1"]}), DT)
		s = gone.state
		var dropped := gone.events.filter(func(e: Dictionary) -> bool: return e["type"] == "fuseDropped")
		var st2: SR.StationFloor = s.station
		t.check(st2.holder == "" and absf(st2.fuse.x - mid.x) < 0.5 and absf(st2.fuse.z - mid.z) < 0.5, "%s: p0 gone, the fuse lies where they were (%s, %s)" % [tag, str(st2.fuse), str(dropped)])
		var at_fuse := Move.Body.make(st2.fuse.x, st2.fuse.z, 0, 0.0)
		s = r.step(s, _stand(s, {"p1": at_fuse}, {"p1": true}), DT).state
		s = r.step(s, _stand(s, {"p1": at_fuse}), DT).state
		t.eq((s.station as SR.StationFloor).holder, "p1", "%s: p1 picks it up" % tag)
		var at_cab := Move.Body.make(st2.cabinet.x, st2.cabinet.z, 0, 0.0)
		var lit := r.step(s, _stand(s, {"p1": at_cab}, {"p1": true}), DT)
		s = lit.state
		t.check(lit.events.any(func(e: Dictionary) -> bool: return e["type"] == "powerRestored"), "%s: p1 restores the power" % tag)
		t.eq(s.phase, &"boarding", "%s: with power the car comes (its doors open)" % tag)
		t.check(absf(s.bell_left - Settings.f(s.tuning, &"reactor.board", SR.BOARD)) < DT + 1e-6, "%s: for the Reactor's boarding time" % tag)
	sfx.free()

func test_reactor_everyone_out_is_the_wipe(t: T) -> void:
	var rs := _reactor(true)
	var s: Run.RunState = rs[1]
	var st := (s.station as SR.StationFloor).copy()
	st.power = SR.Power.EMERGENCY
	s.station = st
	var players := s.players.duplicate()
	for i in players.size():
		var p: Run.RunPlayer = players[i].copy()
		p.status = &"out"
		players[i] = p
	s.players = players
	var step: Run.RunStep = (rs[0] as HostRules).step(s, [] as Array[Run.PlayerInput], DT)
	t.check(step.events.any(func(e: Dictionary) -> bool: return e["type"] == "wiped"), "no power and nobody on their feet: the floor ends as a wipe")

# ---------------------------------------------------------------------------------------------
# 6. The Ward: the car does not wait for the hung.

class WardRig:
	var net: Transport.MemoryNetwork
	var host: Host
	var rules: HostRules
	var clients: Array[Client] = []
	var names: Array[String] = ["one", "two"]
	var bodies: Array[Vector3] = [Vector3(7.0, 0, 7.0), Vector3(7.0, 0, 7.0)]
	var calling: Array[bool] = [false, false]
	var now := 0.0

	func _init(fix: bool) -> void:
		net = Transport.MemoryNetwork.new("py1-ward", Transport.LinkConfig.make(0.02, 0.05, 0.0, 0.0, 0.0, 0.0))
		rules = HostRules.new(true, 1, [], true, true)
		rules.ward_call = true
		rules.ward_web = true
		rules.car_waits = true
		rules.economy_fix = fix
		host = Host.new(net.connect_peer("host"), "py1-ward", names, now, Callable(rules, "prepare"), Callable(rules, "step"), names)
		for id in names:
			clients.append(Client.new(net.connect_peer(id), "host", id, now))
		# Walks and the call are not heard: the only catch is the one the test makes.
		host.state = Run.with_tuning(host.state, {&"rigger.steps_reach": 0.0, &"rigger.call_heard": 0.0, &"rigger.door_heard": 0.0, &"rigger.open_heard": 0.0})
		host.start_ward_review(8143)

	func ward() -> Ward:
		return host._ward_review

	func tick_for(seconds: float) -> void:
		for _frame in ceili(seconds / 0.025 - 1e-6):
			now += 0.025
			net.now = now
			for i in clients.size():
				var c := clients[i]
				c.receive(now)
				var local := Client.LocalFrame.new()
				local.body = Move.Body.make(bodies[i].x, bodies[i].z, 0, bodies[i].y)
				local.call = calling[i]
				calling[i] = false
				var f := c.frame(now, local)
				if f != null and f.placed != null:
					bodies[i] = Vector3(f.placed.x, f.placed.y, f.placed.z)
			host.update(now)

	func until(done: Callable, limit: float) -> bool:
		var spent := 0.0
		while spent < limit:
			if done.call():
				return true
			tick_for(0.1)
			spent += 0.1
		return done.call()

	func events(type: String) -> Array:
		var out := []
		for row in host.event_log:
			var e: Dictionary = JSON.parse_string(row.text)
			if str(e.get("type", "")) == type:
				out.append(e)
		return out

	func player(id: String) -> Run.RunPlayer:
		for p in host.state.players:
			if p.id == id:
				return p
		return null

func test_ward_car_leaves_the_hung_behind(t: T) -> void:
	for fix: bool in [false, true]:
		var tag := "on" if fix else "off"
		var rig := WardRig.new(fix)
		var w := rig.ward()
		rig.tick_for(1.5)
		# "two" is caught in a house with a hang point and hung there.
		var fixture: House = w.houses[int(w.hang_points[0].house)]
		rig.bodies[1] = fixture.to_world(Vector3(fixture.areas[&"entry"].x, 0.0, fixture.areas[&"entry"].z))
		rig.tick_for(0.3)
		rig.host.test_ward_noise(rig.bodies[1])
		t.check(rig.until(func() -> bool: return w.caught.has("two"), 20.0), "%s: two is caught" % tag)
		rig.tick_for(Ward.CARRY_TIME + 0.5)
		t.eq(String(rig.player("two").status), "caught", "%s: hung in the web" % tag)
		t.check(rig.until(func() -> bool: return w.encounter == &"idle", 40.0), "%s: the hand has gone" % tag)
		# "one" meets the quota, calls the car at the station and gets in on DOWN; nobody cuts two down.
		var s := rig.host.state.copy()
		s.floor_earned = float(s.floor_needed) + 1.0
		rig.host.state = s
		rig.bodies[0] = w.station
		rig.tick_for(0.3)
		rig.calling[0] = true
		rig.tick_for(0.3)
		t.check(not rig.events("called").is_empty(), "%s: one calls the car" % tag)
		t.check(rig.until(func() -> bool: return String(rig.host.state.phase) == "boarding", 120.0), "%s: the car arrives" % tag)
		t.check(absf(rig.host.state.bell_left - Run.BOARD_TIME_WAITS) < 0.3, "%s: boarding is the normal 30 s (%.2f)" % [tag, rig.host.state.bell_left])
		var arrived := float(rig.events("carArrived")[0]["t"])
		var door := w.lift_door()
		rig.bodies[0] = door + Vector3(0.35, 0.0, -1.0)
		t.check(rig.until(func() -> bool: return not rig.events("bell").is_empty(), Run.BOARD_TIME_WAITS + 3.0), "%s: the bell" % tag)
		var bell: Dictionary = rig.events("bell")[0]
		t.check(str(bell["outcome"]) == "ride" and absf(float(bell["t"]) - arrived - Run.BOARD_TIME_WAITS) < 0.15, "%s: the car leaves 30 s after it came, with one aboard on DOWN (%s, %.2f s)" % [tag, str(bell), float(bell["t"]) - arrived])
		t.eq(String(rig.player("two").status), "caught", "%s: the car did not wait for two" % tag)
		var left := rig.events("leftBehind").filter(func(e: Dictionary) -> bool: return str(e["playerId"]) == "two")
		t.eq(left.size(), 1, "%s: two loses what they held (leftBehind)" % tag)
		t.eq(rig.host.state.left_out.has("two"), fix, "%s: two left out for the day" % tag)
		t.check(rig.until(func() -> bool: return rig.host.state.depth == 2 and rig.host.state.phase != &"riding", 30.0), "%s: the ride arrives on floor 2" % tag)
		# Off: the hung player came back on their feet in the car (the fault the owner saw). On: left out, as anyone the
		# car leaves is; and no share of the day.
		t.eq(String(rig.player("two").status), "leftBehind" if fix else "ok", "%s: two on floor 2" % tag)
		t.eq(Run.day_crew(rig.host.state).has("two"), not fix, "%s: two shares today's pay" % tag)

# ---------------------------------------------------------------------------------------------
# 7. Soft Shoes against every listener.

func test_soft_shoes_reactor(t: T) -> void:
	var rs := _reactor(true)
	var s: Run.RunState = rs[1]
	var st: SR.StationFloor = (s.station as SR.StationFloor).copy()
	st.power = SR.Power.EMERGENCY
	var plan := st.plan
	var wall := SR.HEAR_WALL
	var tried := 0
	var wins := 0
	var bad := 0
	# Every body against walkers on a ring at 2.4 to 2.9 m (inside the wall's 3 m, outside its 2.25 m with Soft Shoes),
	# out of their sight: heard without, not with.
	for b in st.bodies:
		for k in 72:
			var a := TAU * float(k) / 72.0
			for r: float in [2.4, 2.65, 2.9]:
				var at := Move.Body.make(b.body.x + cos(a) * r, b.body.z + sin(a) * r, b.body.level, 0.0)
				var cc := Move.cell_of(plan, at)
				if not Floor.is_walkable(plan, at.level, cc.x, cc.y) or Station.creep_only(plan, cc.x, cc.y):
					continue
				tried += 1
				var plain := SR.Crew.make("p", at, &"ok", &"walk", false, true)
				var soft := SR.Crew.make("p", at, &"ok", &"walk", false, true)
				soft.soft = true
				var hp := SR.senses_player(st, b, false, plain, true, null)
				var hs := SR.senses_player(st, b, false, soft, true, null)
				if hs and not hp:
					bad += 1
				if hp and not hs:
					wins += 1
	t.check(tried > 0 and wins > 0, "a walk through a wall at 2.4-2.9 m is heard without Soft Shoes and not with (%d of %d spots)" % [wins, tried])
	t.eq(bad, 0, "Soft Shoes never makes a walker easier to sense")
	t.eq(wall * Noises.SOFT_SHOES, 2.25, "the wall's reach with Soft Shoes: 3 m x 0.75")
	# The run marks a Soft Shoes owner's row, only with the fix.
	for on: bool in [false, true]:
		var s2 := _at(7, on)
		s2 = Run.with_soft_shoes(s2)
		var u := Upgrades.UpgradeState.make(0)
		u.owned = ["soft_shoes"] as Array[String]
		s2.wallets = {"p0": u}
		t.check(Run.owns_soft_shoes(s2, "p0") and not Run.owns_soft_shoes(s2, "p1"), "p0 owns Soft Shoes, p1 does not")
	t.check(not Run.owns_soft_shoes(_at(7, true), "p0"), "a run that does not sell them: nobody owns them")

func test_soft_shoes_rigger(t: T) -> void:
	t.eq(Ward.SOFT_SHOES, Noises.SOFT_SHOES, "the Rigger's share is the Groundskeeper's")
	var w0 := Ward.new(8143)
	w0.leave(0.0)
	var lair := w0.lair
	# A room on some house's ground floor at least 3 m from the middle of the house he is under.
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
	# The reach set so this room is inside a walk's reach and outside it with Soft Shoes (d / reach = 0.875).
	var reach := d / 0.875
	var heard := {}
	for soft: bool in [false, true]:
		var w := Ward.new(8143)
		w.tuning = Settings.make({&"rigger.steps_reach": reach})
		w.leave(0.0)
		var b := a + Vector3(0.6, 0, 0)
		var evs: Array[Dictionary] = []
		var now := 0.0
		while now < 10.0:
			now += 0.05
			var k := fmod(now * 3.0, 1.2) / 0.6
			var row := {"position": a.lerp(b, k if k <= 1.0 else 2.0 - k)}
			if soft:
				row["soft"] = true
			evs.append_array(w.step(now, 0.05, 30.0, {"p1": row}))
		heard[soft] = evs.any(func(e: Dictionary) -> bool: return e.kind == &"line_loaded")
	t.check(d >= 3.0, "a room %.2f m from his house's middle (the test needs some distance)" % d)
	t.check(heard[false], "a walk %.2f m off with the reach at %.2f m: heard" % [d, reach])
	t.check(not heard[true], "the same walk in Soft Shoes (reach %.2f m): not heard" % (reach * Noises.SOFT_SHOES))
	# The host marks the Ward row only with the fix (net/host.gd _step_ward_review).
	var src := FileAccess.get_file_as_string("res://net/host.gd")
	t.check(src.contains("if s.economy_fix and Run.owns_soft_shoes(s, i.id):"), "net/host.gd marks a Soft Shoes owner's Ward row only with the fix")
