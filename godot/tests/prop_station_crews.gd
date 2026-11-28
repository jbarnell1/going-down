# RX2, the Reactor's crews by measurement (sim/bot.gd "The Reactor's crews", sim/station_floor.gd). Crews of 1, 2,
# 4 and 6 bot players at three skills (careless, sensible, expert) play floor 7 in a real run (the game's rules,
# HostRules with the Reactor on, downs and heals), knowing only what a player could. measure() is one run and its
# numbers; tools/station_crews.gd runs hundreds of seeds a cell and prints the table. Checked here, on a small fixed
# seed set (the quick set smaller still):
#   - the crews: a sensible crew restores the power without being told the fuse spot, and crews are chased on most
#     runs (it stays frightening); the finish rates are printed, not asserted (RX2 did not reach its bands);
#   - crawlers keep off (the two-client report's fault): a crawling body stops reactor.crawl_keep short of anyone on
#     their feet, so it never stands up already within reach of them;
#   - warning: the first stand comes crawl_time after the stir, and no standing body reaches anyone sooner than
#     crawl_time + (crawl_keep - reach) / speed after it;
#   - the catcher feeds: a body that has put someone down stays over them (goes after nobody else) until they are
#     healed or out, then stands off; so a crewmate can heal;
#   - the scaling by crew size reads from the live settings.
extends RefCounted

const T = preload("res://tests/t.gd")
const PS = preload("res://tests/prop_station.gd")
const Bot = preload("res://sim/bot.gd")
const SR = preload("res://sim/station_floor.gd")
const Run = preload("res://sim/run.gd")
const Move = preload("res://sim/move.gd")
const M = preload("res://sim/jsmath.gd")
const Settings = preload("res://sim/settings.gd")
const Sight = preload("res://sim/sight.gd")
const HostRules = preload("res://net/host_rules.gd")

const DT := 0.05
## A run longer than this (host seconds) is a stall: counted as not finished.
const LIMIT := 420.0
## Prints the run every half second (tools/station_crews.gd trace=...); tests leave it off.
static var trace := false

static func _ids(n: int) -> Array[String]:
	var out: Array[String] = []
	for i in n:
		out.append("p%d" % i)
	return out

## The rules for a crew run: floor 7 with the Reactor, and RX3's seek fix as the game's rooms run it (`seek`).
static func crew_rules(seek: bool) -> HostRules:
	var r := PS.rules(7, true)
	# The rooms pass reactor_seek_ as HostRules' last parameter; PS.rules stops before it, so it is set here as
	# _init would (only with the Reactor as a place).
	r.reactor_seek = seek and r.reactor_place
	return r

## One run of a bot crew on floor 7. `given`: live settings for the run ({} = the game's numbers). `seek`: RX3's
## seek fix (on in the game's rooms).
static func measure(seed: String, size: int, skill: StringName, given: Dictionary = {}, seek := true) -> Dictionary:
	var r := crew_rules(seek)
	var s := r.prepare(Run.create_run(seed, _ids(size), r.deck, true, true, true))
	if not given.is_empty():
		s = Run.with_tuning(s, given)
	var mind := Bot.station_mind(skill)
	var out := {"finished": false, "restored": false, "tape": false, "aboard": 0, "size": size, "catches": [],
		"chased": false, "cut": -1.0, "restore": -1.0, "stir": -1.0, "stand": -1.0, "reach": -1.0, "downs": 0, "heals": 0,
		"why": "time", "end": 0.0, "near": false, "tell": INF, "opened": -1.0, "closed": -1.0}
	var lift := Vector3.ZERO
	# When each of the four last began to run (it had sensed someone): the tell a catch gives.
	var run_since := [INF, INF, INF, INF]
	for k in int(LIMIT / DT):
		var st: SR.StationFloor = s.station
		if st != null and lift == Vector3.ZERO:
			lift = st.plan.station["lift_door"]
		var inputs := Bot.station_inputs(s, mind, DT)
		var phase_before := "search"
		if st != null:
			if st.power == SR.Power.RESTORED:
				phase_before = "board"
			elif not st.holder.is_empty():
				phase_before = "carry"
			elif mind.fuse_known:
				phase_before = "fetch"
		var step := r.step(s, inputs, DT)
		s = step.state
		if trace and st != null and k % 10 == 0:
			var line := "%.1f pw%d hold%.0f c=%s d=%s fk=%s |" % [s.t, st.power, st.hold_left, mind.carrier, mind.decoy, mind.fuse_known]
			for i in s.players.size():
				var p := s.players[i]
				line += " %s:%s(%.1f,%.1f)%s" % [p.id, p.status, p.body.x, p.body.z, inputs[i].gait]
			line += " |"
			for b in st.bodies:
				line += " %s(%.1f,%.1f)" % [b.phase.right(4), b.body.x, b.body.z]
			line += " | fuse(%.1f,%.1f) cab(%.1f,%.1f)" % [st.fuse.x, st.fuse.z, st.cabinet.x, st.cabinet.z]
			print(line)
		if trace:
			for e in step.events:
				if str(e["type"]) in ["caught", "downed", "healed", "out", "fuseTaken", "powerRestored", "doorsOpened", "doorsClosed", "bodyStands", "stationStir", "powerCut", "tapeTaken", "wiped"]:
					print("   EV %.2f %s" % [s.t, str(e).left(140)])
		for e in step.events:
			match str(e["type"]):
				"powerCut": out["cut"] = s.t
				"stationStir":
					if float(out["stir"]) < 0.0:
						out["stir"] = s.t
				"bodyStands":
					if float(out["stand"]) < 0.0:
						out["stand"] = s.t
				"powerRestored":
					out["restored"] = true
					out["restore"] = s.t
				"tapeExtracted": out["tape"] = true
				"downed": out["downs"] = int(out["downs"]) + 1
				"healed": out["heals"] = int(out["heals"]) + 1
				"caught":
					if str(e.get("by", "")) == "station":
						var who := str(e["playerId"])
						var at := Vector2.ZERO
						for p in s.players:
							if p.id == who:
								at = Vector2(p.body.x, p.body.z)
						var tell := INF
						var st3: SR.StationFloor = s.station
						if st3 != null:
							var bd := INF
							for j in st3.bodies.size():
								var bb := st3.bodies[j]
								var dd := at.distance_to(Vector2(bb.body.x, bb.body.z))
								if bb.phase == "zombie_run" and dd < bd:
									bd = dd
									tell = s.t - float(run_since[j])
						out["tell"] = minf(float(out["tell"]), tell)
						(out["catches"] as Array).append({"after": s.t - float(out["cut"]), "lift": at.distance_to(Vector2(lift.x, lift.z)),
							"phase": phase_before, "carrier": who == mind.carrier, "tell": tell})
				"doorsOpened":
					if str(e.get("reason", "")) == "boarding" and float(out["opened"]) < 0.0:
						out["opened"] = s.t
				"doorsClosed":
					if float(out["opened"]) >= 0.0 and float(out["closed"]) < 0.0:
						out["closed"] = s.t
					var aboard: Array = e["aboard"]
					if bool(out["restored"]) and not aboard.is_empty():
						out["finished"] = true
						out["aboard"] = aboard.size()
						out["why"] = ""
				"wiped": out["why"] = "wiped"
		# Chased: a standing body within 6 m of someone on their feet; reach: within the catch reach.
		var st2: SR.StationFloor = s.station
		if st2 != null and st2.power != SR.Power.NORMAL:
			for j in st2.bodies.size():
				var b := st2.bodies[j]
				if b.phase != "zombie_run":
					run_since[j] = INF
					if b.phase == "zombie_walk":
						for p in s.players:
							if p.status == &"ok" and M.hypot2(p.body.x - b.body.x, p.body.z - b.body.z) < 2.0:
								out["near"] = true
					continue
				if run_since[j] == INF:
					run_since[j] = s.t
				for p in s.players:
					if p.status != &"ok":
						continue
					var d := M.hypot2(p.body.x - b.body.x, p.body.z - b.body.z)
					if d < 6.0:
						out["chased"] = true
					if d < 2.0:
						out["near"] = true
					if d < SR.REACH and float(out["reach"]) < 0.0:
						out["reach"] = s.t
		if bool(out["finished"]) or str(out["why"]) == "wiped":
			break
	out["end"] = s.t
	return out

## The two-client report's case (item 2 of RX2): the four's rules alone (StationFloor.step), the power just cut, one
## player standing still `gap` metres (by the plan's walk) from seat 1's body, with the tuning `given`. The other
## three are where the plan puts them, which on some seeds is nearer the player than seat 1 (RX3: keep-6 and keep-28,
## where seat 2 stands 3 m off and makes the catch). Returns, for every body, when it stood, how far it was from the
## player then and how far it started ("stands": [[stood, gap, start], ...]); "stood" / "gap_at_stand" / "start_gap"
## of seat 1 as before; when they were caught ("caught", -1 never), by which body ("by", -1 never), and when that
## body stood and how far off ("by_stood", "by_gap").
static func standing_still(seed: String, gap: float, given: Dictionary, seconds := 60.0, seek := true) -> Dictionary:
	const Station = preload("res://sim/station.gd")
	const Floor = preload("res://sim/floor.gd")
	var plan := Station.generate_station(seed, 7)
	var st := SR.make(plan)
	st.seek_fix = seek
	var tuning := Settings.make(given)
	st.power = SR.Power.EMERGENCY
	st.hold_left = 0.0
	# The cell nearest `gap` metres' walk from seat 1, outside the crawl.
	var b0 := st.bodies[0].body
	var from := Move.cell_of(plan, b0)
	var dist := Floor.distances_from(plan, from)
	var pick := Vector2i(-1, -1)
	var best := INF
	for cy in plan.height:
		for cx in plan.width:
			var d := dist[cy * plan.width + cx]
			if d < 0 or Station.creep_only(plan, cx, cy):
				continue
			var e := absf(float(d * plan.cell_size) - gap)
			if e < best - 1e-9:
				best = e
				pick = Vector2i(cx, cy)
	var me := Move.Body.make(Station.wc(pick.x), Station.wc(pick.y), 0, 0.0)
	var stands: Array = []
	for b in st.bodies:
		stands.append([-1.0, -1.0, M.hypot2(me.x - b.body.x, me.z - b.body.z)])
	var out := {"stood": -1.0, "gap_at_stand": -1.0, "caught": -1.0, "start_gap": float(stands[0][2]), "by": -1, "stands": stands}
	var t := 0.0
	var events: Array[Dictionary] = []
	while t < seconds:
		t += DT
		var crew: Array[SR.Crew] = [SR.Crew.make("p0", me, &"ok", &"walk", false, true)]
		var caught := SR.step(st, crew, t, DT, tuning, events)
		for j in st.bodies.size():
			var b := st.bodies[j]
			if (b.phase == "zombie_run" or b.phase == "zombie_walk") and float(stands[j][0]) < 0.0:
				stands[j][0] = st.awake
				stands[j][1] = M.hypot2(me.x - b.body.x, me.z - b.body.z)
		if not caught.is_empty():
			out["caught"] = st.awake
			# The catcher: the body now feeding on p0 (reactor.feed on), else the nearest standing one in reach.
			var near := INF
			for j in st.bodies.size():
				var b := st.bodies[j]
				var d := M.hypot2(me.x - b.body.x, me.z - b.body.z)
				if b.feeding == "p0":
					out["by"] = j
					break
				if float(stands[j][0]) >= 0.0 and d <= SR.REACH + 1e-6 and d < near:
					near = d
					out["by"] = j
			break
	out["stood"] = float(stands[0][0])
	out["gap_at_stand"] = float(stands[0][1])
	if int(out["by"]) >= 0:
		out["by_stood"] = float(stands[int(out["by"])][0])
		out["by_gap"] = float(stands[int(out["by"])][1])
	return out

## The heal beside a catch, with the four's rules alone: seat 1 (the others removed) stands and catches p0, who
## then lies down; p1 kneels 1 m from p0 (on the far side from the body) holding the heal for HEAL_TIME; then p0 is
## up (with the run's grace). Returns whether p1 was caught during the heal and how long the body stayed still after it.
static func feeding_case(seed: String, given: Dictionary) -> Dictionary:
	const Station = preload("res://sim/station.gd")
	const Floor = preload("res://sim/floor.gd")
	var plan := Station.generate_station(seed, 7)
	var st := SR.make(plan)
	st.seek_fix = true
	st.bodies = [st.bodies[0]]
	# RX3: the body must see its catch to make it (this case is about the feeding, not the senses).
	var g := given.duplicate()
	if not g.has(&"reactor.sight_dark"):
		g[&"reactor.sight_dark"] = 30.0
	var tuning := Settings.make(g)
	st.power = SR.Power.EMERGENCY
	st.hold_left = 0.0
	var b0 := st.bodies[0].body
	var from := Move.cell_of(plan, b0)
	var dist := Floor.distances_from(plan, from)
	var pick := Vector2i(-1, -1)
	for cy in plan.height:
		for cx in plan.width:
			if pick.x < 0 and dist[cy * plan.width + cx] == 3 and not Station.creep_only(plan, cx, cy) and Sight.has_line_of_sight(plan, Sight.Point3.make(b0.x, 1.6, b0.z, 0), Sight.Point3.make(Station.wc(cx), 1.2, Station.wc(cy), 0)):
				pick = Vector2i(cx, cy)
	var p0 := Move.Body.make(Station.wc(pick.x), Station.wc(pick.y), 0, 0.0)
	var out := {"healer_caught": false, "still_after_heal": -1.0, "p0_caught": false}
	var t := 0.0
	var events: Array[Dictionary] = []
	var status0 := &"ok"
	var p1: Move.Body = null
	var phase := "catch"
	var heal_at := -1.0
	while t < 40.0:
		t += DT
		var crew: Array[SR.Crew] = [SR.Crew.make("p0", p0, status0, &"walk", false, true)]
		if p1 != null:
			crew.append(SR.Crew.make("p1", p1, &"ok", &"walk", false, true))
		var before := st.bodies[0].body
		var caught := SR.step(st, crew, t, DT, tuning, events)
		var b := st.bodies[0].body
		match phase:
			"catch":
				if caught.has("p0"):
					out["p0_caught"] = true
					status0 = &"down"
					var dx := p0.x - b.x
					var dz := p0.z - b.z
					var d := maxf(1e-6, M.hypot2(dx, dz))
					p1 = Move.Body.make(p0.x + dx / d * 1.0, p0.z + dz / d * 1.0, 0, 0.0)
					phase = "heal"
					heal_at = t + 3.0
			"heal":
				if caught.has("p1"):
					out["healer_caught"] = true
					break
				if t >= heal_at - 1e-9:
					status0 = &"ok"
					st.grace["p0"] = t + SR.GRACE
					phase = "after"
					heal_at = t
			"after":
				if not b.same(before) or not caught.is_empty() or st.bodies[0].wind > 0.0:
					out["still_after_heal"] = t - DT - heal_at
					break
	return out

# ---------------------------------------------------------------------------------------------
# The rules.

## Item 2 of RX2: a player standing still while the four crawl a long time (the two-client report's panel: crawl
## 30 s, pursuit 1.5 m/s). Before RX2 every crawler parked 0.35 m from them and caught them 0.4 s after standing.
func test_crawlers_keep_off(t: T) -> void:
	var seeds := 6 if t.quick else 30
	var slow := {&"reactor.crawl_time": 30.0, &"reactor.run_speed": 1.5}
	for i in seeds:
		var r := standing_still("keep-%d" % i, 10.0, slow, 40.0)
		# Every body that stood kept off (not only seat 1: on some seeds another of the four lies nearer the player).
		for j in (r["stands"] as Array).size():
			var sj: Array = r["stands"][j]
			if float(sj[0]) >= 0.0:
				t.check(float(sj[1]) >= minf(SR.CRAWL_KEEP, float(sj[2])) - SR.RUN_SPEED * DT - 1e-6, "keep-%d: seat %d stood %.2f m off (start %.2f)" % [i, j + 1, float(sj[1]), float(sj[2])])
		if float(r["caught"]) < 0.0:
			continue
		t.check(int(r["by"]) >= 0, "keep-%d: the catcher is known" % i)
		if int(r["by"]) < 0:
			continue
		var gap := float(r["by_gap"])
		# From the catcher's stand it must still cover the gap to the reach at its speed and wind up.
		# The pursuit to the lunge's range, the lunge to the reach, then the wind-up.
		var least := maxf(0.0, gap - SR.LUNGE_RANGE) / 1.5 + (minf(gap, SR.LUNGE_RANGE) - SR.REACH) / SR.LUNGE_SPEED + SR.WIND - DT
		t.check(float(r["caught"]) - float(r["by_stood"]) >= least, "keep-%d: caught by seat %d %.2f s after it stood %.2f m off (least %.2f)" % [i, int(r["by"]) + 1, float(r["caught"]) - float(r["by_stood"]), gap, least])
	var game := standing_still("keep-game", 10.0, {}, 30.0)
	t.note("game numbers, a player standing still 10 m off: stood %.2f m away at %.2f s, caught %.2f s later" % [float(game["gap_at_stand"]), float(game["stood"]), float(game["caught"]) - float(game["stood"])])

## Warning: the stir (the floor's sound) comes crawl_time before the first body stands, and the first stand is at
## least CRAWL_KEEP from everyone, so no catch can come sooner than crawl_time + (CRAWL_KEEP - REACH) / speed + WIND
## after the stir. Checked over crew runs: the first moment any standing body is within reach of anyone.
func test_warning(t: T) -> void:
	var least := SR.CRAWL_TIME + (SR.CRAWL_KEEP - SR.LUNGE_RANGE) / SR.RUN_SPEED + (SR.LUNGE_RANGE - SR.REACH) / SR.LUNGE_SPEED - DT
	var seeds := 3 if t.quick else 10
	var worst := INF
	for size: int in [1, 4]:
		for i in seeds:
			var res := measure("warn-%d" % i, size, &"careless")
			t.check(float(res["stand"]) - float(res["stir"]) >= SR.CRAWL_TIME - DT - 1e-6, "warn-%d/%d: stood %.2f s after the stir" % [i, size, float(res["stand"]) - float(res["stir"])])
			if float(res["reach"]) > 0.0:
				worst = minf(worst, float(res["reach"]) - float(res["stir"]))
				t.check(float(res["reach"]) - float(res["stir"]) >= least, "warn-%d/%d: a body in reach %.2f s after the stir (least %.2f)" % [i, size, float(res["reach"]) - float(res["stir"]), least])
	t.note("the soonest a standing body reached anyone after the stir: %.2f s (rule's least %.2f s)" % [worst, least])

## The catcher stays over its catch: a crewmate kneeling beside the downed player is not caught by it, and once the
## heal is done it stands off for reactor.stand_off seconds. With reactor.feed 0 it goes straight for the healer.
func test_catcher_feeds(t: T) -> void:
	for i in (3 if t.quick else 10):
		var on := feeding_case("feed-%d" % i, {})
		t.check(bool(on["p0_caught"]) and not bool(on["healer_caught"]), "feed-%d: the healer beside the catch is safe (%s)" % [i, on])
		t.check(absf(float(on["still_after_heal"]) - SR.STAND_OFF) <= DT + 1e-6, "feed-%d: still %.2f s after the heal" % [i, float(on["still_after_heal"])])
		var off := feeding_case("feed-%d" % i, {&"reactor.feed": 0.0})
		t.check(bool(off["healer_caught"]), "feed-%d off: the healer is caught" % i)

## The pursuit by crew size reads the settings: alone and in twos scaled, three or more at the full speed.
func test_pursuit_by_crew(t: T) -> void:
	t.check(absf(SR.pursuit_speed(1, null) - SR.RUN_SPEED * SR.ALONE_SCALE / 100.0) < 1e-9, "alone")
	t.check(absf(SR.pursuit_speed(2, null) - SR.RUN_SPEED * SR.PAIR_SCALE / 100.0) < 1e-9, "in twos")
	for n: int in [3, 4, 6, 8]:
		t.check(absf(SR.pursuit_speed(n, null) - SR.RUN_SPEED) < 1e-9, "a crew of %d" % n)
	var slow := Settings.make({&"reactor.alone_scale": 75.0, &"reactor.pair_scale": 90.0})
	t.check(absf(SR.pursuit_speed(1, slow) - SR.RUN_SPEED * 0.75) < 1e-6 and absf(SR.pursuit_speed(2, slow) - SR.RUN_SPEED * 0.9) < 1e-6 and absf(SR.pursuit_speed(3, slow) - SR.RUN_SPEED) < 1e-6, "scaled by the settings")

# ---------------------------------------------------------------------------------------------
# RX3, the senses.

## What one body senses (StationFloor.senses_player), down the hall's clear centreline from the lift door.
func test_senses_reach(t: T) -> void:
	const Station = preload("res://sim/station.gd")
	var plan := Station.generate_station("senses-0", 7)
	var st := SR.make(plan)
	st.power = SR.Power.EMERGENCY
	var door: Vector3 = plan.station["lift_door"]
	var b := st.bodies[0]
	b.body = Move.Body.make(door.x, door.z - 1.5, 0, 0.0)
	var at := func(d: float, gait: StringName) -> SR.Crew:
		return SR.Crew.make("p", Move.Body.make(door.x, door.z - 1.5 - d, 0, 0.0), &"ok", gait, false, true)
	var cases := [
		# [metres, gait, moving, lit, power restored, sensed?, what]
		[5.0, &"walk", false, false, false, true, "seen standing in the dark within sight"],
		[10.0, &"walk", false, false, false, false, "not seen standing in the dark beyond sight"],
		[10.0, &"walk", true, false, false, false, "a walk not heard beyond its hearing"],
		[5.0, &"creep", true, false, false, false, "a creep neither heard nor seen beyond the creep's sight"],
		[2.0, &"creep", true, false, false, true, "a creep seen close"],
		[9.0, &"sprint", true, false, false, true, "a sprint heard"],
		[9.0, &"walk", false, true, false, true, "a lit lamp seen further"],
		[12.0, &"walk", false, true, false, false, "a lit lamp not seen beyond its range"],
		[13.0, &"walk", false, false, true, true, "seen further once the power is back"],
	]
	for c: Array in cases:
		var who: SR.Crew = at.call(float(c[0]), c[1])
		who.lit = bool(c[3])
		st.power = SR.Power.RESTORED if bool(c[4]) else SR.Power.EMERGENCY
		t.eq(SR.senses_player(st, b, false, who, bool(c[2]), null), bool(c[5]), "%s (%.0f m %s)" % [c[6], float(c[0]), c[1]])
	st.power = SR.Power.EMERGENCY
	st.cassette_holder = "p"
	t.check(SR.senses_player(st, b, false, at.call(9.0, &"walk"), false, null), "the glowing tape is seen further")
	st.cassette_holder = ""
	# In the crawl a player is neither seen nor heard, even a body's length away.
	var cr: Vector2i = (plan.station["crawl"] as Array)[0]
	var in_crawl := SR.Crew.make("p", Move.Body.make(Station.wc(cr.x), Station.wc(cr.y), 0, 0.0), &"ok", &"creep", false, true)
	var near := st.bodies[1]
	near.body = Move.Body.make(Station.wc(cr.x) + 0.8, Station.wc(cr.y), 0, 0.0)
	t.check(not SR.senses_player(st, near, false, in_crawl, true, null), "a player in the crawl is not sensed")
	t.check(not SR.senses_player(st, near, false, in_crawl, true, Settings.make({&"reactor.sight_creep": 10.0, &"reactor.hear_wall": 10.0})), "nor with long senses")
	t.check(not SR.senses_player(st, b, false, at.call(7.0, &"walk"), false, null), "seen standing 7 m off: no (the dark sight is 6 m)")
	t.check(not SR.senses_player(st, b, false, at.call(7.0, &"walk"), false, Settings.make({&"reactor.sight_dark": 5.0})), "sight_dark reads its setting")

## A player creeping still in the landing's corner after the cut: with the senses the four never find them (they
## search and drift round the hall); with reactor.senses 0 (today's chase) they do.
func test_senses_hide(t: T) -> void:
	for on: bool in [true, false]:
		var caught_any := 0
		var hunted_any := 0
		for i in (3 if t.quick else 8):
			var r := _corner_case("hide-%d" % i, {} if on else {&"reactor.senses": 0.0}, false)
			caught_any += 1 if bool(r["caught"]) else 0
			hunted_any += 1 if bool(r["hunted"]) else 0
		if on:
			t.check(caught_any == 0 and hunted_any == 0, "senses on: a still creeper in the corner found %d, caught %d" % [hunted_any, caught_any])
		else:
			t.check(caught_any > 0, "senses off: the all-knowing four catch the creeper (%d)" % caught_any)

## One whistle draws at most reactor.noise_draws of the four (the nearest that hear it) to where it was.
func test_noise_draws(t: T) -> void:
	for n: int in [1, 2, 4]:
		var r := _corner_case("draw-0", {&"reactor.noise_draws": float(n), &"noise.emote": 60.0}, true)
		t.eq(int(r["drawn"]), n, "noise_draws %d: drawn by the whistle" % n)

# ---------------------------------------------------------------------------------------------
# RX3, the seek fix (net/host_rules.gd reactor_seek, sim/station_floor.gd seek_fix).

## The senses-on runs that stalled before the fix (rx2-1000..1023, a sensible four: the power never restored in
## LIMIT, with two to four of the four running on the spot at the crawl's mouth, seeking a goal inside it).
const STALLED: Array[String] = ["rx2-1003", "rx2-1004", "rx2-1005", "rx2-1009", "rx2-1011", "rx2-1013", "rx2-1016",
	"rx2-1017", "rx2-1021", "rx2-1023"]
## The longest a body may stand in a seek without moving with the fix: the seek's time, plus the flinch at the
## lights (it holds still, its seek paused), plus a margin.
const SEEK_STILL_MOST := SR.SEEK_TIME + SR.FLINCH + 1.0

## One bot crew run (as measure, the sensible bots) for `seconds`: the longest any of the four stood in "seek"
## without moving ("still", and where: "at"), and a digest of the whole run (every tick: the players, the four,
## the events) to compare runs by.
static func seek_watch(seed: String, size: int, seconds: float, seek: bool) -> Dictionary:
	var r := crew_rules(seek)
	var s := r.prepare(Run.create_run(seed, _ids(size), r.deck, true, true, true))
	var mind := Bot.station_mind(&"sensible")
	var still := [0.0, 0.0, 0.0, 0.0]
	var worst := 0.0
	var at := ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	for k in int(seconds / DT):
		var before: Array = []
		var st0: SR.StationFloor = s.station
		if st0 != null:
			for b in st0.bodies:
				before.append(Vector2(b.body.x, b.body.z))
		var inputs := Bot.station_inputs(s, mind, DT)
		var step := r.step(s, inputs, DT)
		s = step.state
		var line := "%d" % k
		for p in s.players:
			line += "|%s %.3f %.3f %s" % [p.id, p.body.x, p.body.z, p.status]
		var st: SR.StationFloor = s.station
		if st != null:
			for j in st.bodies.size():
				var b := st.bodies[j]
				line += "|%s %s %.3f %.3f" % [b.phase, b.mode, b.body.x, b.body.z]
				var moved := j >= before.size() or Vector2(b.body.x, b.body.z).distance_to(before[j]) > 1e-4
				if st.power != SR.Power.NORMAL and b.mode == "seek" and b.phase != "zombie_crawl" and b.phase != "still" and not moved:
					still[j] = float(still[j]) + DT
					if float(still[j]) > worst:
						worst = float(still[j])
						at = "seat %d at %.1f s (%.1f, %.1f) seeking (%.1f, %.1f)" % [b.seat, s.t, b.body.x, b.body.z, b.goal.x, b.goal.y]
				else:
					still[j] = 0.0
		for e in step.events:
			line += "|%s %.3f" % [str(e["type"]), float(e.get("t", 0.0))]
		ctx.update(line.to_utf8_buffer())
	return {"still": worst, "at": at, "digest": ctx.finish().hex_encode(), "t": s.t}

## With the fix, on the runs that stalled, no body stands in a seek without moving for longer than its seek's time
## (and the flinch) plus a margin. Without it, the first of them shows the old fault (a body still for minutes).
func test_seek_never_freezes(t: T) -> void:
	var seeds: Array[String] = STALLED.slice(0, 1) if t.quick else STALLED
	var worst := 0.0
	for seed in seeds:
		var on := seek_watch(seed, 4, LIMIT, true)
		worst = maxf(worst, float(on["still"]))
		t.check(float(on["still"]) <= SEEK_STILL_MOST, "%s: a body stood %.2f s in a seek (most %.2f): %s" % [seed, float(on["still"]), SEEK_STILL_MOST, on["at"]])
	var off := seek_watch(STALLED[0], 4, 200.0, false)
	t.check(float(off["still"]) > 60.0, "%s without the fix: the old freeze (%.2f s still: %s)" % [STALLED[0], float(off["still"]), off["at"]])
	t.note("the longest still seek with the fix: %.2f s over %d stalled runs; without it %.1f s on %s" % [worst, seeds.size(), float(off["still"]), STALLED[0]])

## A whistle from inside the crawl, the four standing (crawl 0, all awake): with the fix the ones it draws go to the
## nearest place they can walk to (the crawl's mouth, never into it), and then search; none freezes. Returns how
## many it drew, how many of those then searched, how many reached their goal, whether any entered the crawl or
## had a goal in it, and the longest still seek.
static func crawl_whistle(seed: String, seek: bool) -> Dictionary:
	const Station = preload("res://sim/station.gd")
	var plan := Station.generate_station(seed, 7)
	var st := SR.make(plan)
	st.seek_fix = seek
	var tuning := Settings.make({&"reactor.crawl_time": 0.0, &"reactor.wake_alone": 4.0, &"noise.emote": 60.0, &"reactor.noise_draws": 4.0})
	st.power = SR.Power.EMERGENCY
	st.hold_left = 0.0
	var crawl: Array = plan.station["crawl"]
	var cr: Vector2i = crawl[crawl.size() / 2]
	var me := Move.Body.make(Station.wc(cr.x), Station.wc(cr.y), 0, 0.0)
	var out := {"drawn": 0, "searched": 0, "arrived": 0, "entered": false, "goal_in_crawl": false, "still": 0.0, "seeking_at_end": 0}
	var drawn := [false, false, false, false]
	var goal := [Vector2.INF, Vector2.INF, Vector2.INF, Vector2.INF]
	var searched := [false, false, false, false]
	var arrived := [false, false, false, false]
	var still := [0.0, 0.0, 0.0, 0.0]
	var tt := 0.0
	var events: Array[Dictionary] = []
	while tt < 40.0:
		tt += DT
		var c := SR.Crew.make("p0", me, &"ok", &"creep", false, true)
		c.shout = absf(tt - 4.0) < DT / 2.0
		var before: Array = []
		for b in st.bodies:
			before.append(Vector2(b.body.x, b.body.z))
		SR.step(st, [c] as Array[SR.Crew], tt, DT, tuning, events)
		for j in st.bodies.size():
			var b := st.bodies[j]
			var here := Vector2(b.body.x, b.body.z)
			var cell := Station.cell_of(b.body.x, b.body.z)
			if Station.creep_only(plan, cell.x, cell.y):
				out["entered"] = true
			if c.shout and b.mode == "seek":
				drawn[j] = true
				goal[j] = b.goal
				var gc := Station.cell_of(b.goal.x, b.goal.y)
				if Station.creep_only(plan, gc.x, gc.y):
					out["goal_in_crawl"] = true
			if bool(drawn[j]) and not bool(searched[j]):
				if here.distance_to(goal[j]) <= SR.ARRIVE + 1e-6:
					arrived[j] = true
				if b.mode == "search":
					searched[j] = true
			if b.mode == "seek" and here.distance_to(before[j]) <= 1e-4:
				still[j] = float(still[j]) + DT
				out["still"] = maxf(float(out["still"]), float(still[j]))
			else:
				still[j] = 0.0
	for j in 4:
		out["drawn"] = int(out["drawn"]) + (1 if drawn[j] else 0)
		out["searched"] = int(out["searched"]) + (1 if drawn[j] and searched[j] else 0)
		out["arrived"] = int(out["arrived"]) + (1 if drawn[j] and arrived[j] else 0)
		out["seeking_at_end"] = int(out["seeking_at_end"]) + (1 if st.bodies[j].mode == "seek" else 0)
	return out

func test_crawl_whistle(t: T) -> void:
	for i in (2 if t.quick else 6):
		var seed := "whistle-%d" % i
		var on := crawl_whistle(seed, true)
		t.check(int(on["drawn"]) > 0, "%s: the whistle draws some of the four (%s)" % [seed, on])
		t.check(not bool(on["goal_in_crawl"]) and not bool(on["entered"]), "%s: drawn to the crawl's mouth, never into it (%s)" % [seed, on])
		t.check(int(on["arrived"]) > 0, "%s: a drawn body reaches the mouth (%s)" % [seed, on])
		t.check(int(on["searched"]) == int(on["drawn"]), "%s: every drawn body then searches (%s)" % [seed, on])
		t.check(float(on["still"]) <= SR.SEEK_TIME + 1.0, "%s: none stands in a seek longer than its time (%s)" % [seed, on])
		if i == 0:
			var off := crawl_whistle(seed, false)
			t.check(not bool(off["entered"]), "%s without the fix: none enters the crawl either (%s)" % [seed, off])
			t.note("%s: with the fix %s; without %s" % [seed, on, off])

## Flag off, nothing changes: these bot runs (no seek fix) give the digests recorded from the rules before RX3's
## seek fix (aab3fd7, the same harness); with the fix the stalled run differs (the flag reaches the rules).
const OFF_DIGESTS := [
	["rx2-1003", 4, 200.0, "a4d2d7db59a541c9ad064be3737fd3c9"],
	["rx2-1000", 2, 200.0, "c46caa207635210f4104528d61c23909"],
	["rx2-1001", 1, 150.0, "76c3290247f067f5e9fe278ae62b0925"],
]

func test_seek_off_unchanged(t: T) -> void:
	for row: Array in (OFF_DIGESTS.slice(0, 1) if t.quick else OFF_DIGESTS):
		var off := seek_watch(str(row[0]), int(row[1]), float(row[2]), false)
		t.eq(str(off["digest"]), str(row[3]), "%s, %d players, %.0f s, no seek fix: as before" % [row[0], int(row[1]), float(row[2])])
	var on := seek_watch(str(OFF_DIGESTS[0][0]), int(OFF_DIGESTS[0][1]), float(OFF_DIGESTS[0][2]), true)
	t.check(str(on["digest"]) != str(OFF_DIGESTS[0][3]), "%s with the seek fix differs" % OFF_DIGESTS[0][0])
	var r := HostRules.new(true, 7)
	t.check(not r.reactor_seek, "HostRules: the seek fix is off by default")

## The corner case: the power out, the four standing (crawl 0), p0 creeping still in the landing's corner for 40 s;
## with `shout`, p0 whistles once at 4 s (all four awake). Returns whether any body hunted or caught p0, and how many sought the
## whistle on its tick.
static func _corner_case(seed: String, given: Dictionary, shout: bool, seek := true) -> Dictionary:
	const Station = preload("res://sim/station.gd")
	var plan := Station.generate_station(seed, 7)
	var st := SR.make(plan)
	st.seek_fix = seek
	var g := given.duplicate()
	g[&"reactor.crawl_time"] = 0.0
	if not g.has(&"reactor.wake_alone"):
		g[&"reactor.wake_alone"] = 4.0
	var tuning := Settings.make(g)
	st.power = SR.Power.EMERGENCY
	st.hold_left = 0.0
	var land: Rect2 = plan.station["landing"]
	var me := Move.Body.make(land.position.x + 0.6, land.end.y - 0.6, 0, 0.0)
	var out := {"caught": false, "hunted": false, "drawn": 0}
	var tt := 0.0
	var events: Array[Dictionary] = []
	while tt < 40.0:
		tt += DT
		var c := SR.Crew.make("p0", me, &"ok", &"creep", false, true)
		c.shout = shout and absf(tt - 4.0) < DT / 2.0
		var caught := SR.step(st, [c] as Array[SR.Crew], tt, DT, tuning, events)
		if c.shout:
			for b in st.bodies:
				if b.mode == "seek":
					out["drawn"] = int(out["drawn"]) + 1
			return out
		for b in st.bodies:
			if b.mode == "hunt":
				out["hunted"] = true
		if not caught.is_empty():
			out["caught"] = true
			break
	return out

# ---------------------------------------------------------------------------------------------
# The crews.

## The crews on a fixed seed set. RX2 did not reach its finish-rate bands with these bots (see tools/station_crews.gd
## and the RX2 report), so the rates are printed, not asserted; what is asserted: a sensible crew finds the fuse
## and restores the power on most seeds without knowing the spot, and every crew is chased (it stays frightening).
func test_crew_bands(t: T) -> void:
	# RX3's floors, below its measured rates with a margin (tools/station_crews.gd, 16 seeds a cell: sensible alone
	# 75%, in twos 62%, fours 56%, sixes 50%); the bands the design lead asked for (55-70 / 70-85 / 85-95) are not
	# all reached, see the RX3 report. Fixed seeds: the runs are deterministic, so these do not flake.
	var seeds := 4 if t.quick else 12
	var floors := {1: 0.5, 2: 0.4, 4: 0.3, 6: 0.3}
	for size: int in ([1, 4] if t.quick else [1, 2, 4, 6]):
		var c := cell(size, &"sensible", seeds, {}, 1000)
		t.note("sensible %d: %d of %d finished, %.2f lost a run, chased %d, cut to restore %.1f s" % [size, int(c["finished"]), seeds,
			float(c["lost"]) / seeds, int(c["chased"]), float(c["restore"])])
		t.check(float(c["finished"]) >= float(floors[size]) * seeds - 1e-9, "sensible crew of %d finishes at least %.0f%% (%d of %d)" % [size, float(floors[size]) * 100.0, int(c["finished"]), seeds])
		t.check(int(c["chased"]) * 10 >= seeds * 7, "sensible crew of %d chased on most runs (%d of %d)" % [size, int(c["chased"]), seeds])
	if not t.quick:
		var off := cell(4, &"sensible", seeds, {&"reactor.senses": 0.0}, 1000)
		var on := cell(4, &"sensible", seeds, {}, 1000)
		t.check(int(on["finished"]) > int(off["finished"]), "the senses make a four's run winnable: %d against %d all-knowing" % [int(on["finished"]), int(off["finished"])])
	var careless := cell(4, &"careless", seeds, {}, 1000)
	t.note("careless 4: %d of %d finished, %.2f lost a run" % [int(careless["finished"]), seeds, float(careless["lost"]) / seeds])

## A cell of the table: `seeds` runs; finish rate, tape out, players lost, cut to restore, chased, catches.
static func cell(size: int, skill: StringName, seeds: int, given: Dictionary = {}, first := 0, seek := true) -> Dictionary:
	var fin := 0
	var tape := 0
	var lost := 0
	var chased := 0
	var restore_sum := 0.0
	var restores := 0
	var catches: Array = []
	var lead_min := INF
	var reach_min := INF
	var tense := 0
	var tell_min := INF
	var tape_fin := 0
	var caught_fin := 0
	var left_fin := 0
	var calm := 0
	for i in range(first, first + seeds):
		var res := measure("rx2-%d" % i, size, skill, given, seek)
		if bool(res["finished"]):
			fin += 1
		if bool(res["tape"]):
			tape += 1
		lost += size - int(res["aboard"])
		if bool(res["chased"]):
			chased += 1
		if bool(res["restored"]):
			restores += 1
			restore_sum += float(res["restore"]) - float(res["cut"])
		catches.append_array(res["catches"])
		if bool(res["near"]) or not (res["catches"] as Array).is_empty():
			tense += 1
		tell_min = minf(tell_min, float(res["tell"]))
		if bool(res["tape"]) and bool(res["finished"]):
			tape_fin += 1
		if bool(res["finished"]) and not (res["catches"] as Array).is_empty():
			caught_fin += 1
		if bool(res["finished"]) and int(res["aboard"]) < size:
			left_fin += 1
		if not bool(res["chased"]):
			calm += 1
		if float(res["stand"]) > 0.0:
			lead_min = minf(lead_min, float(res["stand"]) - float(res["stir"]))
		if float(res["reach"]) > 0.0:
			reach_min = minf(reach_min, float(res["reach"]) - float(res["stir"]))
	return {"size": size, "skill": skill, "seeds": seeds, "finished": fin, "tape": tape, "lost": lost, "chased": chased,
		"restore": restore_sum / maxf(1.0, float(restores)), "catches": catches, "lead": lead_min, "reach": reach_min,
		"tense": tense, "tell": tell_min, "tape_fin": tape_fin, "caught_fin": caught_fin, "calm": calm, "left_fin": left_fin}
