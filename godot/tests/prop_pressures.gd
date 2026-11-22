# The pressures of floor 8 and deeper (DF1; sim/run.gd "Pressures", docs/floors/difficulty.md section 2, the first cut).
# The owner, 19 Nov: "When crews go back down, they start at floor 8, but it's just the clinic again, with either
# difficulties increased or curses implemented to make the next 'day' harder." The numbers are Claude's proposals, each
# a live setting (tests/prop_settings.gd test_pressure_settings proves every row moves its number).
# Proved here:
#   1. The flag is HostRules' last parameter, off by default, and only with cycles (and so the late floors).
#   2. Off, or on in cycle 1, nothing changes: the same seeded run with reading bots on floor 1 and floor 2 (the quota,
#      the down rule, two-watcher Stillness and the Tenant on) is the same, tick for tick, with the flag off and on; the
#      host's world text through a real host and client is the same tick for tick; and no "pressure" block is sent.
#   3. Quota outgrows pockets: floor 8's quota is x1.5 and floor 15's x2.25 of the quota without the pressure, the
#      quota the host sends ("quota" block) is the one the rules use, and the day quota follows (x1.5 on a cycle-2 day).
#   4. The Tenant comes sooner: its clock is 8 minutes on floor 8 and 6 on floor 15 (10 on floor 1), through the rules.
#   5. One heal per floor: two heals for the crew on floor 8, then a hold never starts and the screen says why; one on
#      floor 15; no limit in cycle 1; Field Dressing's first help does not count; salts are refused with none left.
#   6. Three watchers: with four up on floor 8 a Stillness resident needs three; never more than the up players less
#      one, so one and two up still need one, three up still two.
#   7. Dead lamps: the host's block carries 1.5 m on floor 8 and none on floor 15, and survives the wire.
#   8. A crew of one and of two still meet a cycle-2 Clinic's quota before the Tenant: the reading bots' rate on floor 8
#      with the pressures, against floor 1's (t.note prints both).
# Deliberate breaks used (each went red, then green when undone): see the report of DF1.
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Entity = preload("res://sim/entity.gd")
const Places = preload("res://sim/places.gd")
const Move = preload("res://sim/move.gd")
const Day = preload("res://sim/day.gd")
const Settings = preload("res://sim/settings.gd")
const Upgrades = preload("res://sim/upgrades.gd")
const HostRules = preload("res://net/host_rules.gd")
const Host = preload("res://net/host.gd")
const Protocol = preload("res://net/protocol.gd")
const Session = preload("res://net/session.gd")
const NetLib = preload("res://tests/net_lib.gd")
const Rig = preload("res://tests/cycles_rig.gd")
const QuotaNet = preload("res://tests/prop_quota_net.gd")
const DownView = preload("res://client/down_view.gd")

const DT := 0.05

## HostRules with the named parameters on (by name, as tests/prop_cycles.gd does, so nothing counts positions).
static func rules_with(depth: int, on: Array[String], entity_on := true) -> HostRules:
	var init: Dictionary = {}
	for m: Dictionary in (HostRules as Script).get_script_method_list():
		if m["name"] == "_init":
			init = m
	var args: Array = []
	for a: Dictionary in init["args"]:
		var name := str(a["name"])
		if name == "entity_on":
			args.append(entity_on)
		elif name == "depth":
			args.append(depth)
		elif name == "deck_":
			args.append(Places.FULL)
		else:
			args.append(on.has(name))
	return Callable(HostRules, "new").callv(args)

## The game's switches this file cares about, with the pressures `on` or not.
static func game(depth: int, on: bool, more: Array[String] = [], entity_on := true) -> HostRules:
	var names: Array[String] = ["days_", "quota_", "downs_", "watchers_", "late_floors_", "cycles_", "tenant_timer_"]
	names.append_array(more)
	if on:
		names.append("pressures_")
	return rules_with(depth, names, entity_on)

static func ids_of(n: int) -> Array[String]:
	var ids: Array[String] = []
	for i in n:
		ids.append("p%d" % i)
	return ids

static func still(s: Run.RunState) -> Array[Run.PlayerInput]:
	var out: Array[Run.PlayerInput] = []
	for p in s.players:
		if p.status == &"ok" or p.status == &"down":
			out.append(Run.PlayerInput.make(p.id, p.body, 1.65, 0.0, 0.0, 90.0, 70.0))
	return out

# ---------------------------------------------------------------------------------------------
# 1. The flag.

func test_the_flag_is_last_off_by_default_and_needs_cycles(t: T) -> void:
	var init: Dictionary = {}
	for m: Dictionary in (HostRules as Script).get_script_method_list():
		if m["name"] == "_init":
			init = m
	var names: Array[String] = []
	for a: Dictionary in init["args"]:
		names.append(str(a["name"]))
	t.eq(names.slice(names.size() - 19), ["cycles_", "ward_place_", "reactor_place_", "pressures_", "ward_call_", "ward_web_", "rigger_roam_", "ward_layout_", "orderly_fix_", "minder_calm_", "down_ring_", "pn_fixes_", "last_stand_", "deal_", "split_", "economy_fix_", "voice_", "ward_lift_clear_", "ward_homes_"] as Array[String], "pressures_ after reactor_place_, then WC1's ward_call_ and ward_web_, RR1's rigger_roam_, WG1's ward_layout_, OR2's orderly_fix_, MA1's three, LS1's last_stand_, ED1's deal_, SR1's split_, then PY1's economy_fix_, then VC1's voice_, then RL1's ward_lift_clear_, then WH1's ward_homes_")
	t.check(not HostRules.new(true, 8, Places.FULL, true).pressures, "off by default")
	t.check(not rules_with(8, ["pressures_", "late_floors_"] as Array[String]).pressures, "not without cycles")
	t.check(not rules_with(8, ["pressures_", "cycles_"] as Array[String]).pressures, "not without the late floors")
	var on := game(8, true)
	t.check(on.pressures, "on with cycles and the late floors")
	var s := on.prepare(Run.create_run("df1-flag", ids_of(1)))
	t.check(s.pressures and Run.pressure_cycle(s) == 2, "prepare turns it on; floor 8 is cycle 2")
	t.check(not game(8, false).prepare(Run.create_run("df1-flag", ids_of(1))).pressures, "and not with the flag off")
	t.eq(Run.pressure_cycle(game(1, true).prepare(Run.create_run("df1-flag", ids_of(1)))), 1, "floor 1 is cycle 1")

# ---------------------------------------------------------------------------------------------
# 2. Off, or in cycle 1: nothing changes.

## One tick's digest: every event's text, every player's body and status, the resident, the quota.
static func _digest(s: Run.RunState, events: Array) -> String:
	var parts := PackedStringArray()
	for e: Dictionary in events:
		parts.append(str(Protocol.plain(e)))
	for p in s.players:
		parts.append("%s %s %.6f %.6f %.6f" % [p.id, p.status, p.body.x, p.body.z, p.body.y])
	parts.append("%s %.6f %.6f %d %d" % [s.orderly.mode, s.orderly.body.x, s.orderly.body.z, s.orderly.need, s.floor_needed])
	parts.append("%d %.6f %s" % [s.depth, s.t, s.phase])
	return "|".join(parts)

## Reading bots (tests/prop_quota_net.gd Reader) on `rules` for `seconds`, riding on once at `ride_at`: a digest a tick.
static func _bot_lane(seed: String, rules: HostRules, n: int, seconds: float, ride_at: float) -> PackedStringArray:
	var s := NetLib.hunt_setup(rules.prepare(Run.create_run(seed, ids_of(n))))
	var readers: Array = []
	for i in n:
		readers.append(QuotaNet.Reader.new())
	var out := PackedStringArray()
	var tt := 0.0
	var rode := false
	while tt < seconds:
		if not rode and tt >= ride_at:
			rode = true
			var r := s.copy()
			r.phase = &"riding"
			r.going_up = false
			r.timer = 0.0
			s = r
		var inputs: Array[Run.PlayerInput] = []
		for i in n:
			var p := s.players[i]
			if p.status != &"ok" and p.status != &"down":
				continue
			var st := s
			var mover := func(from: Move.Body, dx: float, dz: float) -> Move.Body:
				return Run.move_in_run(st, from, dx, dz, QuotaNet.RADIUS)
			var r: Dictionary = (readers[i] as QuotaNet.Reader).step(s.plan, p.body, s.orderly.body, Session.TICK, mover) if p.status == &"ok" else {"body": p.body, "yaw": 0.0, "raised": false}
			var inp := Run.PlayerInput.make(p.id, r["body"], 1.65, r["yaw"], 0.0, 90.0, 70.0)
			inp.raised = r["raised"]
			inputs.append(inp)
		var step := rules.step(s, inputs, Session.TICK)
		s = step.state
		tt += Session.TICK
		out.append(_digest(s, step.events))
	return out

func test_cycle_one_with_the_flag_on_is_tick_for_tick_the_flag_off(t: T) -> void:
	var seconds := 50.0 if t.quick else 140.0
	for n: int in [1, 4]:
		var off := _bot_lane("df1-same-%d" % n, game(1, false), n, seconds, seconds * 0.5)
		var on := _bot_lane("df1-same-%d" % n, game(1, true), n, seconds, seconds * 0.5)
		var first := -1
		for k in mini(off.size(), on.size()):
			if off[k] != on[k]:
				first = k
				break
		t.check(off.size() == on.size() and first < 0, "crew %d: floors 1 and 2 differ from tick %d with the pressures on" % [n, first])
	t.note("floors 1 and 2, crews of 1 and 4 with reading bots: %.0f s each, the same tick for tick" % seconds)

func test_cycle_one_world_text_is_the_same_and_has_no_block(t: T) -> void:
	var a := Rig.Crew.new("df1-world", game(1, false), ["one", "two"] as Array[String], true)
	var b := Rig.Crew.new("df1-world", game(1, true), ["one", "two"] as Array[String], true)
	for c: Rig.Crew in [a, b]:
		c.tick_for(8.0)
		Rig.ride_down(c.host)
		c.tick_for(10.0)
	t.check(a.ticks.size() > 100 and a.ticks == b.ticks, "the host's world text, tick for tick (%d ticks)" % a.ticks.size())
	t.eq(a.log_text(), b.log_text(), "the same events")
	t.check(not b.host.world().has("pressure") and not (b.clients[0].latest as Dictionary).has("pressure"), "no pressure block in cycle 1")

# ---------------------------------------------------------------------------------------------
# 3. Quota outgrows pockets.

func test_quota_is_x1_5_in_cycle_two_and_x2_25_in_cycle_three(t: T) -> void:
	for n: int in [1, 2, 4]:
		for depth: int in [8, 15]:
			var off := game(depth, false).prepare(Run.create_run("df1-quota", ids_of(n)))
			var on := game(depth, true).prepare(Run.create_run("df1-quota", ids_of(n)))
			var mult := 1.5 if depth == 8 else 2.25
			t.eq(off.floor_needed, Run.floor_quota(depth, n), "floor %d, crew %d, off: the quota without the pressure" % [depth, n])
			t.eq(on.floor_needed, Run.floor_quota(depth, n, null, mult), "floor %d, crew %d, on: x%.2f" % [depth, n, mult])
			t.check(absf(float(on.floor_needed) / float(off.floor_needed) - mult) < 0.01, "floor %d crew %d: %d over %d is x%.2f" % [depth, n, on.floor_needed, off.floor_needed, mult])
			t.eq(Run.day_quota_now(on), Day.day_quota(on.day_state, roundi(Run.DAY_FLOOR_QUOTA * mult)), "floor %d crew %d: the day quota x%.2f" % [depth, n, mult])
			t.eq(Run.day_quota_now(off), Day.day_quota(off.day_state, Run.DAY_FLOOR_QUOTA), "floor %d crew %d: the day quota off" % [depth, n])
	# Floor 1 with the flag on asks what it always did.
	var one := game(1, true).prepare(Run.create_run("df1-quota", ids_of(2)))
	t.eq(one.floor_needed, Run.floor_quota(1, 2), "floor 1 with the flag on")
	# Through a real host and client: the numbers on screen are the rules'.
	var crew := Rig.Crew.new("df1-quota-wire", game(8, true), ["one", "two"] as Array[String], true)
	crew.tick_for(1.0)
	var needed := crew.host.state.floor_needed
	t.eq(needed, Run.floor_quota(8, 2, null, 1.5), "the host's quota on floor 8")
	t.eq(int(Host.quota_block(crew.host.state)["needed"]), needed, "the quota block the host sends")
	t.eq(int((crew.clients[0].quota() as Dictionary)["needed"]), needed, "the quota the client shows")
	t.eq(int(Host.day_block(crew.host.state)["quota"]), Run.day_quota_now(crew.host.state), "the day block's quota is the rules'")
	# The quota grows by the real depth: floor 8's without the pressure is not floor 1's (it does not restart a cycle).
	t.check(Run.floor_quota(8, 1) > Run.floor_quota(1, 1) * 10, "the floor quota grows with the real depth: %d on floor 8 against %d on floor 1" % [Run.floor_quota(8, 1), Run.floor_quota(1, 1)])

func test_tomorrows_quota_after_the_reactor_is_the_next_cycles(t: T) -> void:
	var s := game(14, true).prepare(Run.create_run("df1-next", ids_of(2)))
	t.eq(Run._tomorrow_floor_quota(s, ""), roundi(Run.DAY_FLOOR_QUOTA * 1.5), "before the Reactor is done: cycle 2 tomorrow")
	s.cycles_done = 2
	t.eq(Run._tomorrow_floor_quota(s, ""), roundi(Run.DAY_FLOOR_QUOTA * 2.25), "with cycle 2 done: cycle 3 tomorrow")
	t.eq(Run._tomorrow_floor_quota(s, "game_over"), Run.DAY_FLOOR_QUOTA, "after a game over: floor 1 tomorrow")
	var off := game(14, false).prepare(Run.create_run("df1-next", ids_of(2)))
	t.eq(Run._tomorrow_floor_quota(off, ""), Run.DAY_FLOOR_QUOTA, "flag off: the plain number")

# ---------------------------------------------------------------------------------------------
# 4. The Tenant comes sooner.

static func _tenant_len(depth: int, on: bool, given: Dictionary = {}) -> float:
	var r := game(depth, on)
	var s := r.prepare(Run.create_run("df1-tenant", ids_of(1)))
	if not given.is_empty():
		s = Run.with_tuning(s, given)
	var k := 0
	while r.tenant_at < 0.0 and k < 400:
		var st := r.step(s, still(s), DT)
		s = st.state
		k += 1
	return r.tenant_len

func test_the_tenant_comes_sooner(t: T) -> void:
	t.eq(_tenant_len(1, true), 600.0, "floor 1: 10 minutes")
	t.eq(_tenant_len(8, false), 600.0, "floor 8, off: 10 minutes")
	t.eq(_tenant_len(8, true), 480.0, "floor 8: 8 minutes")
	t.eq(_tenant_len(15, true), 360.0, "floor 15: 6 minutes")
	t.eq(_tenant_len(8, true, {&"pressure.tenant_minutes": 0.0}), 600.0, "pressure.tenant_minutes 0 is off")
	t.eq(_tenant_len(8, true, {&"pressure.tenant_minutes": 5.0}), 300.0, "set to 5")

# ---------------------------------------------------------------------------------------------
# 5. One heal per floor.

## A crew out of the car on floor `depth` with the resident parked, the down rule on.
static func _heal_floor(depth: int, n: int, given: Dictionary = {}, more: Array[String] = []) -> Array:
	var r := game(depth, true, more, false)
	var s := r.prepare(Run.create_run("df1-heal", ids_of(n)))
	s = NetLib.hunt_setup(s)
	s.orderly = HostRules.parked_orderly(s)
	if not given.is_empty():
		s = Run.with_tuning(s, given)
	return [r, s]

## Puts p1 down beside p0 and has p0 hold F for up to 5 s: [the state, the events].
static func _down_and_help(r: HostRules, s0: Run.RunState, helper := 0) -> Array:
	var s := s0.copy()
	var players: Array[Run.RunPlayer] = s.players.duplicate()
	var ev: Array[Dictionary] = []
	Run._go_down(s, players, 1, s.t, &"catch", ev)
	var near := players[helper].copy()
	near.body = Move.Body.make(players[1].body.x + 0.6, players[1].body.z, players[1].body.level, players[1].body.y)
	players[helper] = near
	s.players = players
	var events: Array = []
	for k in int(5.0 / DT):
		var inputs := still(s)
		for inp in inputs:
			if inp.id == s.players[helper].id:
				inp.use = true
		var st := r.step(s, inputs, DT)
		s = st.state
		events.append_array(st.events)
		if s.players[1].status != &"down":
			break
	return [s, events]

static func _count(events: Array, type: String) -> int:
	var k := 0
	for e: Dictionary in events:
		if e["type"] == type:
			k += 1
	return k

func test_two_heals_on_floor_8_then_none_and_the_screen_says_why(t: T) -> void:
	var rs := _heal_floor(8, 3)
	var r: HostRules = rs[0]
	var s: Run.RunState = rs[1]
	t.eq(Run.pressure_heals_left(s), 2, "two heals for the crew on floor 8")
	for k in 2:
		var out := _down_and_help(r, s)
		s = out[0]
		t.eq(_count(out[1], "healed"), 1, "heal %d is given" % (k + 1))
		t.eq(Run.pressure_heals_left(s), 1 - k, "then %d left" % (1 - k))
	var last := _down_and_help(r, s)
	s = last[0]
	t.eq(_count(last[1], "healStart"), 0, "with none left a hold never starts")
	t.eq(_count(last[1], "healed"), 0, "and nobody is healed")
	t.eq(s.players[1].status, &"down", "the third stays down (and can crawl)")
	var block: Dictionary = Host.pressure_block(s)
	t.eq(int(block["heals"]), 0, "the host's block says none are left")
	# The screen: the helper's prompt and the downed player's line say why.
	var w := {"downs": Host.downs_block(s), "hostNow": s.t,
		"me": {"status": "ok", "x": s.players[0].body.x, "z": s.players[0].body.z, "level": s.players[0].body.level},
		"others": [{"id": "p1", "status": "down", "level": s.players[1].body.level, "x": s.players[1].body.x, "z": s.players[1].body.z}]}
	var dv := DownView.new()
	dv.update(w, "p0", {}, true, "", block)
	t.eq(dv.prompt, DownView.NO_HEALS, "the helper reads why")
	var wd := w.duplicate()
	wd["me"] = {"status": "down", "x": s.players[1].body.x, "z": s.players[1].body.z, "level": s.players[1].body.level}
	wd["others"] = [{"id": "p0", "status": "ok", "level": 0, "x": 0.0, "z": 0.0}]
	dv.update(wd, "p1", {}, false, "", block)
	t.eq(dv.line, DownView.NO_HEALS, "the downed reads why")
	t.eq(dv.line2, "CRAWL: W A S D", "and can still crawl")
	# With heals left the prompt counts them.
	var one := block.duplicate()
	one["heals"] = 1
	dv.update(w, "p0", {}, false, "", one)
	t.check(dv.prompt.begins_with("HOLD F TO HELP") and dv.prompt.contains("1 HEAL LEFT"), "the prompt says one heal is left: %s" % dv.prompt)
	# A new floor has its own two.
	var next := s.copy()
	next.depth = 9
	t.eq(Run.pressure_heals_left(next), 2, "floor 9 starts with two again")

func test_one_heal_on_floor_15_and_no_limit_in_cycle_one_or_off(t: T) -> void:
	var rs := _heal_floor(15, 2)
	var out := _down_and_help(rs[0], rs[1])
	t.eq(_count(out[1], "healed"), 1, "floor 15: the first heal")
	var again := _down_and_help(rs[0], out[0])
	t.eq(_count(again[1], "healed"), 0, "floor 15: no second")
	for label: String in ["floor 1", "pressure.heals 0"]:
		var r2 := _heal_floor(1, 2) if label == "floor 1" else _heal_floor(8, 2, {&"pressure.heals": 0.0})
		var s: Run.RunState = r2[1]
		var healed := 0
		for k in 4:
			var o := _down_and_help(r2[0], s)
			s = o[0]
			healed += _count(o[1], "healed")
		t.eq(healed, 4, "%s: four heals, no limit" % label)
		t.eq(Run.pressure_heals_left(s), -1, "%s: no count" % label)
	var three := _heal_floor(8, 2, {&"pressure.heals": 3.0})
	var s3: Run.RunState = three[1]
	var given := 0
	for k in 4:
		var o := _down_and_help(three[0], s3)
		s3 = o[0]
		given += _count(o[1], "healed")
	t.eq(given, 3, "pressure.heals 3: three heals")

func test_field_dressing_first_help_is_free_and_salts_count(t: T) -> void:
	var rs := _heal_floor(8, 2, {&"pressure.heals": 1.0})
	var s: Run.RunState = rs[1]
	s.field_dressing = true
	var w := Upgrades.UpgradeState.make(0)
	w.owned.append("field_dressing")
	s.wallets = {"p0": w}
	t.check(Run.pressure_free_help(s, "p0") and not Run.pressure_free_help(s, "p1"), "p0 has a free help")
	var a := _down_and_help(rs[0], s)
	t.eq(_count(a[1], "healed"), 1, "the free help")
	t.eq(Run.pressure_heals_left(a[0]), 1, "did not count")
	var b := _down_and_help(rs[0], a[0])
	t.eq(_count(b[1], "healed"), 1, "the crew's one heal")
	t.eq(Run.pressure_heals_left(b[0]), 0, "now none")
	var c := _down_and_help(rs[0], b[0])
	t.eq(_count(c[1], "healed"), 0, "then none, Field Dressing or not")
	t.check(Run.pressure_heal_refused(c[0], "p0", true), "salts are refused with none left")
	var fresh: Run.RunState = _heal_floor(8, 2)[1]
	t.check(not Run.pressure_heal_refused(fresh, "p0", true), "and allowed with heals left")
	Run._pressure_count_heal(fresh, "p0", true)
	t.eq(Run.pressure_heals_left(fresh), 1, "salts count as a heal")

# ---------------------------------------------------------------------------------------------
# 6. Three watchers.

## The watchers the Stillness resident needs after one tick on floor `depth` with `n` up players.
static func _need(depth: int, n: int, on: bool) -> int:
	var r := game(depth, on)
	var s := NetLib.hunt_setup(r.prepare(Run.create_run("df1-watch-%d" % depth, ids_of(n))))
	var st := r.step(s, still(s), DT)
	return st.state.orderly.need

func test_three_watchers_within_what_the_crew_can_field(t: T) -> void:
	t.eq(Run.resident_of(game(8, true).prepare(Run.create_run("df1-watch-8", ids_of(1)))).stillness, true, "floor 8's resident is held by watching")
	var got: Array = []
	var want: Array = [1, 1, 2, 3, 3]
	for n in range(1, 6):
		got.append(_need(8, n, true))
	t.eq(got, want, "floor 8, one to five up: 1, 1, 2, 3, 3")
	var plain: Array = []
	for n in range(1, 6):
		plain.append(_need(8, n, false))
	t.eq(plain, [1, 1, 2, 2, 2], "floor 8 off: the old count")
	var one: Array = []
	for n in range(1, 6):
		one.append(_need(1, n, true))
	t.eq(one, [1, 1, 2, 2, 2], "floor 1 on: the old count")
	for up in range(1, 9):
		var s := game(15, true).prepare(Run.create_run("df1-watch", ids_of(1)))
		var need := Run.pressure_watch_need(s, up, Entity.watch_need(up))
		t.check(need <= maxi(1, up - 1) and need >= Entity.watch_need(up), "floor 15, %d up: %d needed is within the crew" % [up, need])

# ---------------------------------------------------------------------------------------------
# 7. Dead lamps: the block on the wire.

func test_the_near_light_rides_in_the_block(t: T) -> void:
	for depth: int in [8, 15]:
		var crew := Rig.Crew.new("df1-light-%d" % depth, game(depth, true), ["one"] as Array[String], true)
		crew.tick_for(0.5)
		var w := crew.host.world()
		var want := 1.5 if depth == 8 else 0.0
		t.eq(float((w["pressure"] as Dictionary)["light"]), want, "floor %d: the host's near light" % depth)
		var got: Variant = (crew.clients[0].latest as Dictionary).get("pressure")
		t.check(got is Dictionary and absf(float(got["light"]) - want) < 1e-6 and int(got["heals"]) == int(w["pressure"]["heals"]), "floor %d: the client decoded it: %s" % [depth, str(got)])
	var off := Rig.Crew.new("df1-light-off", game(8, false), ["one"] as Array[String], true)
	off.tick_for(0.5)
	t.check(not off.host.world().has("pressure"), "floor 8 off: no block")
	var tuned := game(8, true).prepare(Run.create_run("df1-light", ids_of(1)))
	tuned = Run.with_tuning(tuned, {&"pressure.near_light": 3.0})
	t.eq(float(Host.pressure_block(tuned)["light"]), 3.0, "the setting moves it")

# ---------------------------------------------------------------------------------------------
# 8. A crew of one and of two can still finish a cycle-2 Clinic.

## Seconds from the doors to the quota for reading bots on floor `depth` (tests/prop_quota_net.gd's way), INF if not
## met within `limit` or the crew is gone.
static func _time_to_quota(seed: String, n: int, depth: int, on: bool, limit: float) -> float:
	var rules := rules_with(depth, ["quota_", "late_floors_", "cycles_", "pressures_"] as Array[String] if on else ["quota_", "late_floors_", "cycles_"] as Array[String])
	var s := NetLib.hunt_setup(rules.prepare(Run.create_run(seed, ids_of(n))))
	var readers: Array = []
	for i in n:
		readers.append(QuotaNet.Reader.new())
	var tt := 0.0
	while tt < limit:
		var inputs: Array[Run.PlayerInput] = []
		for i in n:
			var p := s.players[i]
			if p.status != &"ok":
				continue
			var st := s
			var mover := func(from: Move.Body, dx: float, dz: float) -> Move.Body:
				return Run.move_in_run(st, from, dx, dz, QuotaNet.RADIUS)
			var r: Dictionary = (readers[i] as QuotaNet.Reader).step(s.plan, p.body, s.orderly.body, Session.TICK, mover)
			var inp := Run.PlayerInput.make(p.id, r["body"], 1.65, r["yaw"], 0.0, 90.0, 70.0)
			inp.raised = r["raised"]
			inputs.append(inp)
		var step := rules.step(s, inputs, Session.TICK)
		s = step.state
		tt += Session.TICK
		for e in step.events:
			if e["type"] == "quotaMet":
				return tt
		if s.phase == &"ended":
			break
	return INF

func test_crews_of_one_and_two_finish_a_cycle_two_clinic(t: T) -> void:
	var seeds := 2 if t.quick else 5
	var parts: Array[String] = []
	t.eq(Places.generate("df1-finish-0-1", 8, Places.with_cycles(Places.FULL)).place, Places.CLINIC, "floor 8 is a Clinic")
	for n: int in [1, 2]:
		var rows: Array[String] = []
		for cond: Array in [[1, true, 600.0, "floor 1"], [8, true, 480.0, "floor 8 with the pressures"]]:
			var met := 0
			var times := PackedStringArray()
			for k in seeds:
				var x := _time_to_quota("df1-finish-%d-%d" % [k, n], n, int(cond[0]), bool(cond[1]), float(cond[2]))
				if not is_inf(x):
					met += 1
				times.append("never" if is_inf(x) else "%d:%02d" % [int(x) / 60, int(x) % 60])
			rows.append("%s %d of %d before the Tenant (%s)" % [cond[3], met, seeds, ", ".join(times)])
			if int(cond[0]) == 8:
				t.check(met * 2 >= seeds, "crew %d: a cycle-2 Clinic's quota met before the Tenant in at least half the seeds: %d of %d" % [n, met, seeds])
		parts.append("crew %d: %s" % [n, "; ".join(rows)])
	t.note("reading bots to the quota: " + " | ".join(parts))
