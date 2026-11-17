# The Temp's own mechanic: Lonely (docs/floors/traits-and-hiding.md section 2 "The Temp: Lonely" and the T19c
# piece of section 6; sim/lonely.gd). Proved here, by the test's own geometry and numbers (not the rules'):
#   1. Over seeded bot runs on Annexes (40, 6 in the quick set): three wandering bots, instruments up, with
#      Lonely, relocation and the down rule on. In every tick:
#        - it never advances on (walks towards, in an approach or a chase), winds up on or catches a player who
#          is not lonely by this test's oracle: no crewmate (on their feet or down) within 8 m on their level,
#          and none with a clear line eye to eye within 20 m;
#        - an instrument records it only while it chases, and only the chased player's;
#        - after every break-off it relocates near a player other than the one it left when there is one, and a
#          note naming that player goes up where it left from;
#        - bent over a downed player (the caught scene as built: there is no drag yet) it never moves.
#   2. A lonely player in its line within 16 m, inside its face's view, is chased from that tick at 3.9 m/s; in a
#      solo run at a pace below a walk and above a walk with the instrument up; not beyond 16 m, not behind it.
#   3. A bot that walks away alone is caught; a bot that reaches a friend within 8 m is never caught, and it
#      breaks off and goes to see the third.
#   4. Two players 15 m apart in each other's sight are not lonely: it never goes for them.
#   5. A wind-up never finishes once its target has company.
#   6. Off unless asked: without the rule the Temp keeps Stillness and nothing here happens.
#   7. On the wire: a Lonely floor's snapshots say who it chases, and a client then never holds the figure.
# Deliberate breaks (section 6): distance only, no line test (4 goes red); let a wind-up finish after the
# target gains company (5 goes red); record for every holder (test_records_only_for_the_chased goes red).
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Entity = preload("res://sim/entity.gd")
const Instr = preload("res://sim/instrument.gd")
const Sight = preload("res://sim/sight.gd")
const Rng = preload("res://sim/rng.gd")
const M = preload("res://sim/jsmath.gd")
const Bot = preload("res://sim/bot.gd")
const Places = preload("res://sim/places.gd")
const Follow = preload("res://sim/follow.gd")
const Lonely = preload("res://sim/lonely.gd")
const Transport = preload("res://net/transport.gd")
const Host = preload("res://net/host.gd")
const Client = preload("res://net/client.gd")
const HostRules = preload("res://net/host_rules.gd")
const Protocol = preload("res://net/protocol.gd")

const DT := 0.05
const EPS := 1e-6
const EYE := 1.65
## The design's numbers (section 2), restated on purpose.
const O_NEAR := 8.0
const O_LINE := 20.0
const O_CHASE := 3.9
const O_RANGE := 16.0
const O_WALK := 3.0
const O_RAISED := 2.2
const IDS: Array[String] = ["b0", "b1", "b2"]

static func of_type(evs: Array[Dictionary], type: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in evs:
		if e["type"] == type:
			out.append(e)
	return out

static func flat(a: Move.Body, b: Move.Body) -> float:
	return M.hypot2(a.x - b.x, a.z - b.z)

static func player(s: Run.RunState, id: String) -> Run.RunPlayer:
	for p in s.players:
		if p.id == id:
			return p
	return null

static func body_of(v: Variant) -> Move.Body:
	if v is Move.Body:
		return v
	var d: Dictionary = v
	return Move.Body.make(float(d["x"]), float(d["z"]), int(d["level"]), float(d["y"]))

# ---------------------------------------------------------------------------------------------
# The oracle.

## Company between two players standing at `a` and `b`: within 8 m on one level, or a clear line eye to eye
## within 20 m.
static func o_company(plan: Floor.FloorPlan, a: Move.Body, b: Move.Body) -> bool:
	if a.level == b.level and flat(a, b) <= O_NEAR + EPS:
		return true
	var ea := Sight.Point3.make(a.x, a.y + EYE, a.z, a.level)
	var eb := Sight.Point3.make(b.x, b.y + EYE, b.z, b.level)
	return M.hypot3(ea.x - eb.x, ea.y - eb.y, ea.z - eb.z) <= O_LINE + EPS and Sight.has_line_of_sight(plan, ea, eb)

## Whether player `id` is lonely in run state `s`: every other player on their feet or down is no company.
static func o_lonely(s: Run.RunState, id: String) -> bool:
	var p := player(s, id)
	if p == null or p.status != &"ok":
		return false
	for q in s.players:
		if q.id == id or (q.status != &"ok" and q.status != &"down"):
			continue
		if o_company(s.plan, p.body, q.body):
			return false
	return true

# ---------------------------------------------------------------------------------------------
# Runs.

## An Annex run out on the floor: the car gone, Lonely on (and relocation, downs as asked).
static func floor_run(seed: String, ids: Array[String], relocation: bool, downs: bool, lonely: bool = true) -> Run.RunState:
	var s := Run.create_run(seed, ids, [&"annex"], false, false, downs)
	if lonely:
		s = Run.with_lonely(s)
	if relocation:
		s = Run.with_relocation(s)
	s = s.copy()
	s.phase = &"away"
	s.call = null
	s.blink = null
	s.lure = false
	return s

## Players stood at `bodies` ({id: Move.Body}).
static func stand(s0: Run.RunState, bodies: Dictionary) -> Run.RunState:
	var s := s0.copy()
	var players: Array[Run.RunPlayer] = []
	for p in s0.players:
		var np := p.copy()
		if bodies.has(p.id):
			np.body = bodies[p.id]
		np.aboard = false
		players.append(np)
	s.players = players
	return s

## The Temp hunting at `body`, facing `yaw`, lurking.
static func temp_at(s0: Run.RunState, body: Move.Body, yaw: float) -> Run.RunState:
	var s := s0.copy()
	var o := s.orderly.copy()
	o.body = body
	o.yaw = yaw
	o.mode = &"hunting"
	o.lonely_phase = &"lurk"
	o.replan_in = 0.0
	o.path = []
	s.orderly = o
	return s

## Inputs for every player on their feet at their bodies in `bodies` (else where they are), instruments `raised`.
static func inputs(s: Run.RunState, bodies: Dictionary, raised: bool) -> Array[Run.PlayerInput]:
	var out: Array[Run.PlayerInput] = []
	for p in s.players:
		if p.status != &"ok" and p.status != &"down":
			continue
		var b: Move.Body = bodies.get(p.id, p.body)
		var inp := Run.PlayerInput.make(p.id, b, EYE, 0.0, 0.0, 90.0, 70.0)
		if p.status == &"down":
			inp.blind = true
		else:
			inp.raised = raised
		out.append(inp)
	return out

static func cell_body(plan: Floor.FloorPlan, c: Floor.Pos) -> Move.Body:
	return Move.body_at_cell(plan, c)

static func walkable_cells(plan: Floor.FloorPlan) -> Array[Floor.Pos]:
	var out: Array[Floor.Pos] = []
	for level in 2:
		for y in plan.height:
			for x in plan.width:
				if Floor.is_walkable(plan, level, x, y):
					out.append(Floor.Pos.make(level, x, y))
	return out

## A clear line from a 1.6 m face at `a` to eyes at `b`.
static func face_line(plan: Floor.FloorPlan, a: Move.Body, b: Move.Body) -> bool:
	return Sight.has_line_of_sight(plan, Sight.Point3.make(a.x, a.y + 1.6, a.z, a.level), Sight.Point3.make(b.x, b.y + EYE, b.z, b.level))

## A cell far from all of `bodies` (40 m or more by walking, no company with any), out of the car, or null.
static func far_cell(plan: Floor.FloorPlan, rng: Rng, bodies: Array[Move.Body]) -> Floor.Pos:
	var cells := walkable_cells(plan)
	var fields: Array[PackedInt32Array] = []
	for b in bodies:
		fields.append(Floor.distances_from(plan, Move.cell_of(plan, b)))
	var car := Run.car_geometry(plan)
	for _n in 400:
		var c: Floor.Pos = cells[rng.int_in(0, cells.size() - 1)]
		# Out of the car: a player in it is company, never prey.
		var ok := not Run.in_car(car, cell_body(plan, c))
		for k in bodies.size():
			var d := fields[k][Floor.pos_index(plan, c)]
			if d >= 0 and d * plan.cell_size < 40.0:
				ok = false
				break
			if o_company(plan, cell_body(plan, c), bodies[k]):
				ok = false
				break
		if ok:
			return c
	return null

# ---------------------------------------------------------------------------------------------
# 1. Bot runs.

class Tally:
	var ticks := 0
	var chase_ticks := 0
	var approach_moves := 0
	var wind_ups := 0
	var catches := 0
	var break_offs := 0
	var relocations := {}
	var notes_gone := 0
	var record_ticks := 0
	var bend_ticks := 0
	var failures := 0

func _fail(t: T, tl: Tally, ok: bool, msg: String) -> bool:
	if not ok:
		tl.failures += 1
		if tl.failures <= 12:
			t.check(false, msg)
	return ok

func _bot_run(t: T, tl: Tally, i: int, secs: float) -> void:
	var seed := "lonely-%d" % i
	var s := floor_run(seed, IDS, true, true)
	var plan := s.plan
	var bots: Array[Bot.Bot] = []
	var bodies := {}
	for n in IDS.size():
		var b := Bot.create_bot(plan, IDS[n], "%s:bots" % seed, 0.25 + 0.25 * n)
		bots.append(b)
		bodies[IDS[n]] = b.body
	s = stand(s, bodies)
	var o := s.orderly.copy()
	o.mode = &"hunting"
	s.orderly = o
	var pending_note := {}   # near -> [from, deadline]
	for _n in roundi(secs / DT):
		var ins: Array[Run.PlayerInput] = []
		for n in IDS.size():
			var p := player(s, IDS[n])
			var b := bots[n]
			if p.status == &"ok":
				Bot.step_bot(plan, b, DT, s.orderly.body, O_WALK)
				var inp := Run.PlayerInput.make(p.id, b.body, EYE, b.yaw, b.pitch, Bot.BOT_HFOV_DEG, Bot.BOT_VFOV_DEG)
				inp.raised = true
				ins.append(inp)
			elif p.status == &"down":
				var dn := Run.PlayerInput.make(p.id, p.body, EYE, b.yaw, b.pitch, Bot.BOT_HFOV_DEG, Bot.BOT_VFOV_DEG)
				dn.blind = true
				ins.append(dn)
		var before := s
		var r := Run.step_run(s, ins, DT)
		s = r.state
		tl.ticks += 1
		var a := before.orderly
		var z := s.orderly
		var tag := "%s t %.2f" % [seed, s.t]
		# Never advances on, winds up on or catches a player who is not lonely.
		var moved := flat(a.body, z.body) > 1e-9 or a.body.level != z.body.level
		if moved and not z.relocated and a.mode == &"hunting" and (z.lonely_phase == &"approach" or z.lonely_phase == &"chase"):
			var tid := str(z.target_id)
			if z.lonely_phase == &"chase":
				tl.chase_ticks += 1
			else:
				tl.approach_moves += 1
			_fail(t, tl, o_lonely(s, tid), "%s: walked towards %s (%s), who is not lonely" % [tag, tid, z.lonely_phase])
		if z.mode == &"windUp":
			_fail(t, tl, o_lonely(s, str(z.wind_up_target)), "%s: winding up on %s, who is not lonely" % [tag, str(z.wind_up_target)])
		for e in of_type(r.events, "windUp"):
			tl.wind_ups += 1
		for e in of_type(r.events, "caught"):
			tl.catches += 1
			# The catch is decided on this tick's positions; the down rule already put them down.
			var victim := str(e["playerId"])
			_fail(t, tl, _lonely_at(s, victim), "%s: caught %s, who is not lonely" % [tag, victim])
		for e in of_type(r.events, "chaseEnded"):
			if str(e["why"]) == "company":
				tl.break_offs += 1
		# Records only while chasing, only the chased.
		var who := Lonely.chased(a, z)
		for m in s.crew.members:
			if m.instrument.needle == &"recording":
				tl.record_ticks += 1
				_fail(t, tl, who != "" and m.id == who, "%s: %s recording while it chases '%s'" % [tag, m.id, who])
		# Bent over a downed player, it never moves.
		if a.mode == &"bending" and z.mode == &"bending":
			tl.bend_ticks += 1
			_fail(t, tl, not moved, "%s: moved while bent over %s" % [tag, str(z.bend_target)])
		# After a break-off: near someone else, and a note naming them where it left from.
		for e in of_type(r.events, "relocated"):
			var why := str(e["why"])
			tl.relocations[why] = int(tl.relocations.get(why, 0)) + 1
			var near := str(e["near"])
			if why == "brokeOff":
				var left := str(a.lonely_left)
				var other := false
				for p in s.players:
					if p.status == &"ok" and p.id != left and not Run.in_car(s.car, p.body):
						other = true
				_fail(t, tl, not other or near != left, "%s: broke off from %s and went back to them" % [tag, left])
			pending_note[near] = [body_of(e["from"]), s.t + 2.0]
		for e in of_type(r.events, "note"):
			if str(e["trigger"]) != "relocate":
				continue
			for near: String in pending_note.keys():
				if String(e["text"]) == "Gone to see %s." % Run.name_of(s, near):
					var from: Move.Body = pending_note[near][0]
					_fail(t, tl, M.hypot2(float(e["x"]) - from.x, float(e["z"]) - from.z) <= 3.0 and int(e["level"]) == from.level, "%s: the note for %s is not where it left" % [tag, near])
					pending_note.erase(near)
					tl.notes_gone += 1
		for near: String in pending_note.keys():
			if s.t > float(pending_note[near][1]):
				# The floor's cap (14 notes) is the one excuse.
				var full := s.annex != null and int(s.annex.notes_state.get("count", 0)) >= 14
				_fail(t, tl, full, "%s: no note named %s after it went to them" % [tag, near])
				pending_note.erase(near)
		if s.phase == &"ended" or s.depth != before.depth:
			break

## Lonely by the oracle, with a downed victim counted as standing (the catch was on their feet).
static func _lonely_at(s: Run.RunState, id: String) -> bool:
	var c := s.copy()
	var players: Array[Run.RunPlayer] = []
	for p in s.players:
		var np := p.copy()
		if np.id == id:
			np.status = &"ok"
		players.append(np)
	c.players = players
	return o_lonely(c, id)

func test_bot_runs(t: T) -> void:
	var tl := Tally.new()
	var floors := 6 if t.quick else 40
	for i in floors:
		_bot_run(t, tl, i, 90.0)
	t.eq(tl.failures, 0, "failures")
	t.note("%d floors, %d ticks: %d chase ticks, %d approach steps, %d wind-ups, %d catches, %d break-offs, relocations %s, %d 'Gone to see' notes, %d recording ticks, %d bent ticks" % [floors, tl.ticks, tl.chase_ticks, tl.approach_moves, tl.wind_ups, tl.catches, tl.break_offs, str(tl.relocations), tl.notes_gone, tl.record_ticks, tl.bend_ticks])
	t.check(tl.chase_ticks > 100, "not vacuous: it chased (%d ticks)" % tl.chase_ticks)
	t.check(tl.catches > 0, "not vacuous: it caught someone (%d)" % tl.catches)
	t.check(tl.record_ticks > 0, "not vacuous: someone recorded it (%d ticks)" % tl.record_ticks)

# ---------------------------------------------------------------------------------------------
# 2. The chase starts from that tick, at its speed.

## Setups: [plan cell of the Temp, of the lonely player, of the far player] with a clear line from the Temp's face
## to the player 8 to `max_d` m away on one level, the far one 40 m or more by walking from both.
func _line_setups(n: int, min_d: float, max_d: float) -> Array:
	var out: Array = []
	var i := 0
	while out.size() < n and i < n * 6:
		var seed := "lonely-line-%d" % i
		i += 1
		var s := floor_run(seed, IDS, false, false)
		var plan := s.plan
		var rng := Rng.make_rng(seed + ":pick")
		var cells := walkable_cells(plan)
		for _try in 300:
			var a: Floor.Pos = cells[rng.int_in(0, cells.size() - 1)]
			var b: Floor.Pos = cells[rng.int_in(0, cells.size() - 1)]
			var ab := cell_body(plan, a)
			var bb := cell_body(plan, b)
			var d := flat(ab, bb)
			if a.level != b.level or d < min_d or d > max_d or not face_line(plan, ab, bb):
				continue
			var path := Floor.find_path(plan, a, b)
			if path.size() < 2 or not face_line(plan, ab, cell_body(plan, path[1])):
				continue
			var c := far_cell(plan, rng, [ab, bb])
			if c == null:
				continue
			out.append([seed, a, b, c])
			break
	return out

func test_chased_from_that_tick(t: T) -> void:
	var n := 8 if t.quick else 40
	var setups := _line_setups(n, 8.0, 15.0)
	t.check(setups.size() >= n / 2, "setups found: %d of %d" % [setups.size(), n])
	var worst := 0.0
	for row: Array in setups:
		for solo: bool in [false, true]:
			var ids: Array[String] = ["b0"]
			if not solo:
				ids.append("b1")
			var s := floor_run(str(row[0]), ids, false, false)
			var plan := s.plan
			var tb := cell_body(plan, row[1])
			var pb := cell_body(plan, row[2])
			var bodies := {"b0": pb}
			if not solo:
				bodies["b1"] = cell_body(plan, row[3])
			s = temp_at(stand(s, bodies), tb, Entity.yaw_toward(pb.x - tb.x, pb.z - tb.z))
			t.check(o_lonely(s, "b0"), "%s: the setup's player is lonely" % row[0])
			var r := Run.step_run(s, inputs(s, bodies, false), DT)
			var started := of_type(r.events, "chaseStarted")
			if not t.check(started.size() == 1 and str(started[0]["playerId"]) == "b0", "%s%s: a lonely player %.1f m off in its line was not chased that tick" % [row[0], " solo" if solo else "", flat(tb, pb)]):
				continue
			var sp := r.state.orderly.speed
			if solo:
				t.check(sp < O_WALK - 0.1 and sp > O_RAISED + 0.1, "%s solo: chases at %.3f m/s, not between a raised walk and a walk" % [row[0], sp])
			else:
				worst = maxf(worst, absf(sp - O_CHASE))
				t.check(absf(sp - O_CHASE) < 1e-6, "%s: chases at %.4f m/s, want %.1f" % [row[0], sp, O_CHASE])
			# Behind its face, or beyond 16 m: not chased.
			var back := temp_at(stand(floor_run(str(row[0]), ids, false, false), bodies), tb, Entity.yaw_toward(tb.x - pb.x, tb.z - pb.z))
			var rb := Run.step_run(back, inputs(back, bodies, false), DT)
			t.eq(of_type(rb.events, "chaseStarted").size(), 0, "%s: chased a player behind it" % row[0])
	var far := _line_setups(maxi(2, n / 4), 17.0, 30.0)
	for row: Array in far:
		var s := floor_run(str(row[0]), IDS.slice(0, 2), false, false)
		var tb := cell_body(s.plan, row[1])
		var pb := cell_body(s.plan, row[2])
		var bodies := {"b0": pb, "b1": cell_body(s.plan, row[3])}
		s = temp_at(stand(s, bodies), tb, Entity.yaw_toward(pb.x - tb.x, pb.z - tb.z))
		var r := Run.step_run(s, inputs(s, bodies, false), DT)
		t.eq(of_type(r.events, "chaseStarted").size(), 0, "%s: chased a player %.1f m off" % [row[0], flat(tb, pb)])
		t.check(r.state.orderly.lonely_phase == &"approach", "%s: does not approach a lonely player %.1f m off (%s)" % [row[0], flat(tb, pb), r.state.orderly.lonely_phase])
	t.note("%d setups (each with a crew and solo), %d beyond 16 m; worst speed error %.9f m/s" % [setups.size(), far.size(), worst])

# ---------------------------------------------------------------------------------------------
# 3. Walking alone, caught; reaching a friend, never.

func test_a_walker_is_caught(t: T) -> void:
	var n := 6 if t.quick else 30
	var setups := _line_setups(n, 8.0, 12.0)
	var caught := 0
	var company := 0
	for row: Array in setups:
		var s := floor_run(str(row[0]), IDS.slice(0, 2), false, false)
		var plan := s.plan
		var tb := cell_body(plan, row[1])
		var bot := Bot.create_bot(plan, "b0", str(row[0]) + ":walker", 0.0, false, row[2])
		var bodies := {"b0": bot.body, "b1": cell_body(plan, row[3])}
		s = temp_at(stand(s, bodies), tb, Entity.yaw_toward(bot.body.x - tb.x, bot.body.z - tb.z))
		var had_company := false
		var got := false
		for _k in roundi(120.0 / DT):
			Bot.step_bot(plan, bot, DT, s.orderly.body, O_WALK)
			bodies["b0"] = bot.body
			var r := Run.step_run(s, inputs(s, bodies, false), DT)
			s = r.state
			if not _lonely_at(s, "b0"):
				had_company = true
			if not of_type(r.events, "caught").is_empty():
				got = true
				break
		if had_company:
			company += 1
		elif got:
			caught += 1
		else:
			t.check(false, "%s: a walker alone for two minutes was never caught" % row[0])
	t.note("%d walkers: %d caught alone, %d met someone on the way" % [setups.size(), caught, company])
	t.check(caught >= setups.size() / 2, "not vacuous: most walkers were caught alone (%d)" % caught)

## [seed, the Temp's cell, the path the walker takes to the friend's cell, the third player's cell]: the walker
## 8 m along a path from the Temp, the friend 20 m on by walking, the walker lonely at the start.
func _friend_setups(n: int) -> Array:
	var out: Array = []
	var i := 0
	while out.size() < n and i < n * 6:
		var seed := "lonely-friend-%d" % i
		i += 1
		var s := floor_run(seed, IDS, true, false)
		var plan := s.plan
		var rng := Rng.make_rng(seed + ":pick")
		var cells := walkable_cells(plan)
		for _try in 200:
			var a: Floor.Pos = cells[rng.int_in(0, cells.size() - 1)]
			var b: Floor.Pos = cells[rng.int_in(0, cells.size() - 1)]
			var path := Floor.find_path(plan, a, b)
			if path.size() != 15 or a.level != b.level:
				continue
			var walker := cell_body(plan, path[4])
			var friend := cell_body(plan, b)
			if o_company(plan, walker, friend):
				continue
			var c := far_cell(plan, rng, [cell_body(plan, a), walker, friend])
			if c == null:
				continue
			out.append([seed, a, path.slice(4), c])
			break
	return out

func test_a_walker_who_reaches_a_friend_is_never_caught(t: T) -> void:
	var n := 6 if t.quick else 30
	var setups := _friend_setups(n)
	var broke := 0
	var went := 0
	var noted := 0
	var reached := 0
	var early := 0
	for row: Array in setups:
		var seed := str(row[0])
		var s := floor_run(seed, IDS, true, false)
		var plan := s.plan
		var path: Array[Floor.Pos] = []
		path.assign(row[2])
		var walker := cell_body(plan, path[0])
		var friend := cell_body(plan, path[path.size() - 1])
		var bodies := {"b0": walker, "b1": friend, "b2": cell_body(plan, row[3])}
		var tb := cell_body(plan, row[1])
		s = temp_at(stand(s, bodies), tb, Entity.yaw_toward(walker.x - tb.x, walker.z - tb.z))
		var walk := Follow.PathWalk.make(path, 1)
		var together := false
		var broke_here := false
		var went_to := ""
		for _k in roundi(60.0 / DT):
			if not together:
				walker = Follow.step_path_walk(plan, walk, walker, O_WALK * DT, Bot.BOT_RADIUS)
				bodies["b0"] = walker
			var a := s.orderly
			var r := Run.step_run(s, inputs(s, bodies, false), DT)
			s = r.state
			var b0_caught := false
			for e in of_type(r.events, "caught"):
				b0_caught = b0_caught or str(e["playerId"]) == "b0"
			if b0_caught:
				# Caught still alone on the way is the rule working; beside a friend it never may be.
				t.check(not together, "%s t %.2f: caught beside a friend" % [seed, s.t])
				if not together:
					early += 1
				break
			if flat(walker, friend) <= O_NEAR - 1.0:
				if not together:
					reached += 1
				together = true
			for e in of_type(r.events, "chaseEnded"):
				broke_here = broke_here or str(e["why"]) == "company"
			for e in of_type(r.events, "relocated"):
				# The first relocation after breaking off from the walker (it may have gone for the third
				# player first, alone as they are, and caught them: then nobody is left lonely).
				if went_to == "" and str(e["why"]) == "brokeOff" and str(a.lonely_left) == "b0":
					went_to = str(e["near"])
					if t.check(went_to == "b2", "%s t %.2f: broke off from b0 (%s, left %s, last phase %s) and went to %s, not the third player" % [seed, s.t, str(e["why"]), str(a.lonely_left), a.lonely_phase, went_to]):
						went += 1
			for e in of_type(r.events, "note"):
				if str(e["trigger"]) == "relocate" and String(e["text"]) == "Gone to see b2.":
					noted += 1
		if broke_here:
			broke += 1
	t.note("%d walkers: %d reached a friend and were never caught after (%d caught alone on the way); %d break-offs, %d went to the third player, %d 'Gone to see b2.' notes" % [setups.size(), reached, early, broke, went, noted])
	t.check(setups.size() >= n / 2 and reached >= setups.size() / 2, "setups found: %d, reached a friend: %d" % [setups.size(), reached])
	t.check(broke > 0 and went > 0 and noted > 0, "not vacuous: break-offs, relocations and notes happened")

# ---------------------------------------------------------------------------------------------
# 4. In sight of each other, 15 m apart: company.

func test_two_in_sight_are_never_chased(t: T) -> void:
	var n := 6 if t.quick else 30
	var found := 0
	var i := 0
	while found < n and i < n * 8:
		var seed := "lonely-pair-%d" % i
		i += 1
		var s := floor_run(seed, IDS.slice(0, 2), false, false)
		var plan := s.plan
		var rng := Rng.make_rng(seed + ":pick")
		var cells := walkable_cells(plan)
		for _try in 400:
			var a: Floor.Pos = cells[rng.int_in(0, cells.size() - 1)]
			var dir := rng.int_in(0, 3)
			var dx: int = [1, -1, 0, 0][dir]
			var dz: int = [0, 0, 1, -1][dir]
			var ab := cell_body(plan, a)
			var bb := Move.Body.make(ab.x + dx * 15.0, ab.z + dz * 15.0, ab.level, ab.y)
			var tc := Floor.Pos.make(a.level, a.x - dx * 3, a.y - dz * 3)
			if not Floor.is_walkable(plan, tc.level, tc.x, tc.y):
				continue
			var bc := Move.cell_of(plan, bb)
			if not Floor.is_walkable(plan, bc.level, bc.x, bc.y):
				continue
			var tb := cell_body(plan, tc)
			if not o_company(plan, ab, bb) or not face_line(plan, tb, ab) or flat(ab, bb) <= O_NEAR:
				continue
			found += 1
			var bodies := {"b0": ab, "b1": bb}
			s = temp_at(stand(s, bodies), tb, Entity.yaw_toward(ab.x - tb.x, ab.z - tb.z))
			var moved := false
			var chased := 0
			for _k in roundi(8.0 / DT):
				var r := Run.step_run(s, inputs(s, bodies, false), DT)
				chased += of_type(r.events, "chaseStarted").size()
				moved = moved or flat(r.state.orderly.body, s.orderly.body) > 1e-9
				s = r.state
			t.check(chased == 0 and not moved, "%s: two players %.0f m apart in each other's sight: chased %d time(s)%s" % [seed, flat(ab, bb), chased, ", it moved" if moved else ""])
			break
	t.note("%d pairs 15 m apart in sight, 6 m in front of it, for 8 s each" % found)
	t.check(found >= n / 2, "setups found: %d" % found)

# ---------------------------------------------------------------------------------------------
# 5. A wind-up never finishes once its target has company.

func test_a_wind_up_ends_when_company_comes(t: T) -> void:
	var n := 6 if t.quick else 30
	var setups := _line_setups(n, 8.0, 10.0)
	var cancelled := 0
	for row: Array in setups:
		var s := floor_run(str(row[0]), IDS.slice(0, 2), false, false)
		var plan := s.plan
		var pb := cell_body(plan, row[2])
		var tb := cell_body(plan, row[1])
		var bodies := {"b0": pb, "b1": cell_body(plan, row[3])}
		s = temp_at(stand(s, bodies), tb, Entity.yaw_toward(pb.x - tb.x, pb.z - tb.z))
		var wound := false
		var caught := false
		for _k in roundi(15.0 / DT):
			if wound:
				# The friend arrives beside them the tick after the wind-up starts.
				bodies["b1"] = Move.Body.make(pb.x, pb.z, pb.level, pb.y)
			var r := Run.step_run(s, inputs(s, bodies, false), DT)
			s = r.state
			caught = caught or not of_type(r.events, "caught").is_empty()
			if wound and not of_type(r.events, "windUpCancelled").is_empty():
				cancelled += 1
				t.check(s.orderly.lonely_phase == &"breakoff", "%s: cancelled but not breaking off (%s)" % [row[0], s.orderly.lonely_phase])
				break
			if s.orderly.mode == &"windUp":
				wound = true
		t.check(not caught, "%s: a wind-up finished after its target had company" % row[0])
	t.note("%d wind-ups cancelled the tick a friend arrived" % cancelled)
	t.check(cancelled >= setups.size() / 2 and cancelled > 0, "not vacuous: %d of %d wind-ups" % [cancelled, setups.size()])

# ---------------------------------------------------------------------------------------------
# Recording: only the chased player's instrument.

## [seed, Temp cell, chased cell, other holder cell, far cell]: the chased 4-6 m off in its face's line; the other
## holder within 7 m of it on its level, out of its line, no company with the chased.
func _record_setups(n: int) -> Array:
	var out: Array = []
	var i := 0
	while out.size() < n and i < n * 8:
		var seed := "lonely-rec-%d" % i
		i += 1
		var s := floor_run(seed, IDS, false, false)
		var plan := s.plan
		var rng := Rng.make_rng(seed + ":pick")
		var cells := walkable_cells(plan)
		for _try in 3000:
			var tc: Floor.Pos = cells[rng.int_in(0, cells.size() - 1)]
			var ac: Floor.Pos = cells[rng.int_in(0, cells.size() - 1)]
			var bc: Floor.Pos = cells[rng.int_in(0, cells.size() - 1)]
			var tb := cell_body(plan, tc)
			var ab := cell_body(plan, ac)
			var bb := cell_body(plan, bc)
			if tc.level != ac.level or tc.level != bc.level:
				continue
			if flat(tb, ab) < 4.0 or flat(tb, ab) > 6.0 or flat(tb, bb) > 7.0 or flat(tb, bb) < 2.0:
				continue
			if not face_line(plan, tb, ab) or face_line(plan, tb, bb) or o_company(plan, ab, bb):
				continue
			var c := far_cell(plan, rng, [ab, bb])
			if c == null:
				continue
			out.append([seed, tc, ac, bc, c])
			break
	return out

func test_records_only_for_the_chased(t: T) -> void:
	var n := 6 if t.quick else 30
	var setups := _record_setups(n)
	var mine := 0
	var near_other := 0
	for row: Array in setups:
		var s := floor_run(str(row[0]), IDS, false, false)
		var plan := s.plan
		var tb := cell_body(plan, row[1])
		var ab := cell_body(plan, row[2])
		var bodies := {"b0": ab, "b1": cell_body(plan, row[3]), "b2": cell_body(plan, row[4])}
		s = temp_at(stand(s, bodies), tb, Entity.yaw_toward(ab.x - tb.x, ab.z - tb.z))
		for _k in roundi(6.0 / DT):
			var r := Run.step_run(s, inputs(s, bodies, true), DT)
			var a := s.orderly
			s = r.state
			var who := Lonely.chased(a, s.orderly)
			for m in s.crew.members:
				if m.instrument.needle != &"recording":
					continue
				if m.id == "b0" and who == "b0":
					mine += 1
				else:
					t.check(false, "%s t %.2f: %s recorded it while it chased '%s'" % [row[0], s.t, m.id, who])
			if who == "b0" and flat(s.orderly.body, bodies["b1"]) <= 9.0:
				near_other += 1
			if not of_type(r.events, "caught").is_empty():
				break
	t.note("%d setups: %d ticks recorded by the chased, %d chase ticks with another holder in reach" % [setups.size(), mine, near_other])
	t.check(mine > 0 and near_other > 0, "not vacuous")

# ---------------------------------------------------------------------------------------------
# 6. Off unless asked, and the trait.

func test_off_unless_asked(t: T) -> void:
	t.check(Places.resident(Places.ANNEX).trait_name == &"stillness", "the Annex's resident without the rule: Stillness")
	t.check(Places.resident_in(Places.ANNEX, true).trait_name == &"lonely", "with it: Lonely")
	t.check(not Places.resident_in(Places.ANNEX, true).stillness, "Lonely is not Stillness")
	t.check(Places.resident_in(Places.CLINIC, true).trait_name == &"stillness", "the Clinic keeps Stillness")
	t.check(Places.resident_in(Places.PLAYROOM, true).trait_name == &"hearing", "the Playroom keeps Hearing")
	var setups := _line_setups(2, 8.0, 14.0)
	for row: Array in setups:
		var s := floor_run(str(row[0]), IDS.slice(0, 2), false, false, false)
		t.check(Run.resident_of(s).trait_name == &"stillness", "%s: off, the Temp is Stillness" % row[0])
		var tb := cell_body(s.plan, row[1])
		var pb := cell_body(s.plan, row[2])
		var bodies := {"b0": pb, "b1": cell_body(s.plan, row[3])}
		s = temp_at(stand(s, bodies), tb, 0.0)
		var n := 0
		for _k in roundi(10.0 / DT):
			var r := Run.step_run(s, inputs(s, bodies, false), DT)
			s = r.state
			n += of_type(r.events, "chaseStarted").size() + of_type(r.events, "chaseEnded").size()
			t.check(s.orderly.lonely_phase == &"lurk" or s.orderly.lonely_phase == &"", "%s: a Lonely phase with the rule off" % row[0])
		t.eq(n, 0, "%s: chase events with the rule off" % row[0])

## On the wire: a Lonely floor's snapshots say who it chases ("" for nobody) and a client then never holds the
## figure; a run without the rule sends exactly what it did.
func test_on_the_wire(t: T) -> void:
	var ids: Array[String] = ["p0", "p1"]
	for lonely: bool in [true, false]:
		var net := Transport.MemoryNetwork.new("lonely-wire-%s" % str(lonely))
		var rules := HostRules.new(true, 3, [&"annex"], false, false, false, false, false, false, false, false, lonely)
		var host := Host.new(net.connect_peer("host"), "lonely-wire", ids, 0.0, Callable(rules, "prepare"), Callable(rules, "step"))
		var w := host.world(true)
		t.eq(w.has("lonely"), lonely, "lonely=%s: the world says who it chases" % str(lonely))
		var back: Variant = Protocol.decode(Protocol.encode({"type": "welcome", "you": "p0", "seed": "lonely-wire", "playing": true, "evFrom": 0, "world": w}))
		if not t.check(back is Dictionary, "lonely=%s: the welcome decodes" % str(lonely)):
			continue
		var bw: Dictionary = (back as Dictionary)["world"]
		t.eq(bw.get("lonely"), "" if lonely else null, "lonely=%s: decoded" % str(lonely))
		t.eq(Client._still(&"annex", bw, bw), not lonely, "lonely=%s: the client holds the figure on a look" % str(lonely))
		# Chasing someone: their id goes out.
		var s := host.state.copy()
		var o := s.orderly.copy()
		o.lonely_phase = &"chase"
		o.lonely_target = "p1"
		s.orderly = o
		host.state = s
		if lonely:
			var w2 := host.world(true)
			t.eq(w2.get("lonely"), "p1", "the chased player's id")
			var back2: Variant = Protocol.decode(Protocol.encode({"type": "welcome", "you": "p0", "seed": "lonely-wire", "playing": true, "evFrom": 0, "world": w2}))
			t.eq(((back2 as Dictionary)["world"] as Dictionary).get("lonely"), "p1", "the chased player's id, decoded")

func test_slip(t: T) -> void:
	t.eq(String(Instr.SLIP_TEXT[&"lonely"]), "recorded while: subject pursuing. operator alone.", "Lonely's slip")
