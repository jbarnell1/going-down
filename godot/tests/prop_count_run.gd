# The count in the run (loop/NIGHT-PLAN.md A3, T15d; docs/floors/playarea.md sections 3 to 5, 7, 8 and 11):
# on the Playroom sim/run.gd steps sim/seek.gd instead of the Orderly's rules. Pure rules, three players,
# the game's deck, floor 4 (net/host_rules.gd puts the crew there). Bodies are placed, not walked: the
# rules do not police speed. Proved:
#   - one sprint tick starts one count, and its one event carries host time, length, number, who and why;
#     the snapshot's seek block carries it, with each player's hide, peek, health and sight, and the noise;
#   - hiding is an input: F (hide_use) gets in and out, the run holds the body at the hide's inside spot
#     and front spot, and W (peek) leans to the gap;
#   - found is out of the run (caught) where they were found, their tape drops there, and taken puts them
#     at the party table; no "caught" run event, so nothing on the screen treats it as the Orderly's catch;
#   - a taken player's position never counts as a target: whatever they send, no event names them again,
#     they start no count, and the Minder never sets off for them;
#   - recording is gated as section 11: trait "hearing", only during a count after the 6 s, only for a
#     player out of its view or peeking from a hide;
#   - the call starts the last count (40 s) instead of the usual wait, or after the running one, and the
#     doors open on the tick it ends, never before;
#   - health: walking after the first count drains it, 0 is down (caught, the tape drops), and the dropped
#     tape is heard the next tick;
#   - with the resident off there is no count at all.
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Places = preload("res://sim/places.gd")
const Playroom = preload("res://sim/playroom.gd")
const Seek = preload("res://sim/seek.gd")
const Instr = preload("res://sim/instrument.gd")
const TapeLib = preload("res://sim/tape.gd")
const Rng = preload("res://sim/rng.gd")
const M = preload("res://sim/jsmath.gd")
const HostRules = preload("res://net/host_rules.gd")
const Host = preload("res://net/host.gd")
const Protocol = preload("res://net/protocol.gd")
const DayRigLib = preload("res://tests/day_rig.gd")
const JsJson = preload("res://net/jsjson.gd")

const DT := 0.05
const IDS: Array[String] = ["p0", "p1", "p2"]

## Three players on floor 4 of the full deck, driven by placed bodies.
class Rig:
	var st: Run.RunState
	var bodies := {}
	var gait := {}
	var raised := {}
	## One tick only: F for a hide (and the quick way), the call.
	var hide := {}
	var fast := {}
	var call_by := ""
	## Held: W in a hide.
	var peek := {}
	## Players who send no input (not on the floor for the rules).
	var off := {}
	var events: Array[Dictionary] = []
	var ticks := 0

	func _init(seed: String, entity: bool = true) -> void:
		var rules := HostRules.new(entity, 4, Places.FULL)
		st = rules.prepare(Run.create_run(seed, IDS, Places.FULL))
		for p in st.players:
			bodies[p.id] = p.body
			gait[p.id] = &"creep"

	func plan() -> Floor.FloorPlan:
		return st.plan

	func seek() -> Seek.SeekState:
		return st.seek

	func sp(id: String) -> Seek.SeekPlayer:
		return Seek.player_of(st.seek, id) if st.seek != null else null

	func rp(id: String) -> Run.RunPlayer:
		for p in st.players:
			if p.id == id:
				return p
		return null

	func inputs() -> Array[Run.PlayerInput]:
		var out: Array[Run.PlayerInput] = []
		for id in IDS:
			if off.has(id):
				continue
			var inp := Run.PlayerInput.make(id, bodies[id], 1.65, 0.0, 0.0, 90.0, 70.0)
			inp.gait = gait[id]
			inp.hide_use = bool(hide.get(id, false))
			inp.hide_fast = bool(fast.get(id, false))
			inp.peek = bool(peek.get(id, false))
			inp.call = id == call_by
			if raised.has(id):
				inp.raised = raised[id]
			out.append(inp)
		hide = {}
		fast = {}
		call_by = ""
		return out

	func step() -> Run.RunStep:
		var r := Run.step_run(st, inputs(), DT)
		st = r.state
		ticks += 1
		events.append_array(r.events)
		for e in r.events:
			if e["type"] == "doorsClosed":
				var pushed: Dictionary = e["pushedOut"]
				for id: String in pushed:
					bodies[id] = pushed[id]
		# As the host places them: where the rules hold the body.
		for p in st.players:
			var s := sp(p.id)
			if Run._seek_holds(s):
				bodies[p.id] = p.body
		return r

	func run(secs: float) -> Array[Dictionary]:
		var evs: Array[Dictionary] = []
		for _k in roundi(secs / DT):
			evs.append_array(step().events)
		return evs

	## Steps until an event of this type (returned with every event of that tick), at most `secs`.
	func until_event(type: String, secs: float) -> Dictionary:
		for _k in roundi(secs / DT):
			for e in step().events:
				if e["type"] == type:
					return e
		return {}

## Walkway cells of level 0, not squeakers, at least `far` m from the Minder's start, in a seeded order.
static func safe_cells(plan: Floor.FloorPlan, far: float, key: String) -> Array[Floor.Pos]:
	var squeak := {}
	for k in Playroom.squeakers(plan, plan.seed):
		squeak[k] = true
	var start := Move.body_at_cell(plan, plan.entity_start)
	var out: Array[Floor.Pos] = []
	for y in plan.height:
		for x in plan.width:
			var c := Floor.Pos.make(0, x, y)
			if Floor.cell_at(plan, 0, x, y) != Floor.CORRIDOR or squeak.has(Floor.pos_index(plan, c)):
				continue
			var b := Move.body_at_cell(plan, c)
			if M.hypot2(b.x - start.x, b.z - start.z) >= far:
				out.append(c)
	var rng := Rng.make_rng("prop_count_run:%s" % key)
	for i in range(out.size() - 1, 0, -1):
		var j := rng.int_in(0, i)
		var tmp := out[i]
		out[i] = out[j]
		out[j] = tmp
	return out

## Out of the car onto safe cells far from the Minder, until the car has gone (phase away).
static func to_away(t: T, r: Rig) -> void:
	r.until_event("doorsOpened", 3.0)
	var cells := safe_cells(r.plan(), 12.0, r.st.seed)
	for i in IDS.size():
		r.bodies[IDS[i]] = Move.body_at_cell(r.plan(), cells[i * 5 % cells.size()])
	r.until_event("carLeft", 5.0)
	t.eq(r.st.phase, &"away", "%s: the car left after unloading" % r.st.seed)

## A step of `d` metres along whichever way is open, with the rules' walls.
static func nudge(plan: Floor.FloorPlan, b: Move.Body, d: float) -> Move.Body:
	for v: Vector2 in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
		var n := Move.move_with_collision(plan, b, v.x * d, v.y * d, 0.3)
		if M.hypot2(n.x - b.x, n.z - b.z) > d * 0.9:
			return n
	return b

## The events of one type.
static func of_type(evs: Array[Dictionary], type: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in evs:
		if e["type"] == type:
			out.append(e)
	return out

## A hide of level 0 the player can get to, the `k`-th by id.
static func a_hide(plan: Floor.FloorPlan, k: int) -> Playroom.Hide:
	var list: Array[Playroom.Hide] = []
	for h in Playroom.hides(plan, plan.seed):
		if h.level == 0:
			list.append(h)
	return list[k % list.size()]

# ---------------------------------------------------------------------------------------------

func test_one_sprint_tick_starts_one_count(t: T) -> void:
	var n := 2 if t.quick else 6
	for i in n:
		var r := Rig.new("count-run-%d" % i)
		t.eq(r.st.plan.place, &"playroom", "floor 4 is the Playroom")
		r.run(0.1)
		t.check(r.seek() != null, "%s: the run holds no seek state on the Playroom" % r.st.seed)
		to_away(t, r)
		var quiet := r.run(5.0)
		t.eq(of_type(quiet, "count").size(), 0, "%s: a count started with everyone creeping or standing" % r.st.seed)
		# One tick of sprint.
		r.gait["p1"] = &"sprint"
		r.bodies["p1"] = nudge(r.plan(), r.bodies["p1"], 0.25)
		var res := r.step()
		r.gait["p1"] = &"creep"
		var counts := of_type(res.events, "count")
		t.eq(counts.size(), 1, "%s: one sprint tick, counts started" % r.st.seed)
		if counts.is_empty():
			continue
		var c := counts[0]
		t.eq([int(c["n"]), String(c["by"]), String(c["why"]), float(c["len"]), bool(c["last"])], [1, "p1", "sprint", 30.0, false], "%s: the count event" % r.st.seed)
		t.eq(float(c["t0"]), r.st.t, "%s: the count's t0 is the host's time of the tick" % r.st.seed)
		t.eq(float(c["t"]), r.st.t, "%s: the event's time" % r.st.seed)
		# The snapshot carries it, quantised, through the wire form.
		var blk: Dictionary = Host.seek_block(r.st)
		var v := Protocol._V.new()
		var back := Protocol.dec_seek(v, JsJson.parse(JsJson.stringify(Protocol.enc_seek(blk))).value)
		t.check(not v.bad, "%s: the seek block did not decode" % r.st.seed)
		t.eq([back["counting"], back["last"], back["n"], back["by"], back["why"], back["t0"], back["len"]], [true, false, 1, "p1", "sprint", Protocol.q3(r.st.t), 30.0], "%s: the seek block's count" % r.st.seed)
		t.eq(back["noise"], 1.0, "%s: the noise of a sprint" % r.st.seed)
		for p: Dictionary in back["players"]:
			t.eq([p["hide"], p["peek"], p["health"], p["sight"], p["phase"], p["status"]], [-1, false, 100.0, 0.0, "out", "ok"], "%s: %s in the seek block" % [r.st.seed, p["id"]])
		# More sprinting in the count starts nothing more.
		r.gait["p2"] = &"sprint"
		var more: Array[Dictionary] = []
		for _k in 20:
			r.bodies["p2"] = nudge(r.plan(), r.bodies["p2"], 0.25)
			more.append_array(r.step().events)
		r.gait["p2"] = &"creep"
		t.eq(of_type(more, "count").size(), 0, "%s: a sprint during a count started another" % r.st.seed)
		t.eq(r.st.orderly.anim, &"cover", "%s: the Minder covers its face in the 6 s (carried as the resident's pose)" % r.st.seed)
		t.check(not Places.resident(r.st.plan.place).stillness, "the Minder is not a Stillness resident")

func test_hiding_is_an_input(t: T) -> void:
	var n := 2 if t.quick else 6
	for i in n:
		var r := Rig.new("count-hide-%d" % i)
		r.run(0.1)
		to_away(t, r)
		var h := a_hide(r.plan(), i)
		var front := Seek.hide_front_body(r.plan(), h)
		var inside := Seek.hide_inside_body(r.plan(), h)
		r.bodies["p0"] = front
		r.run(0.2)
		r.hide["p0"] = true
		var evs: Array[Dictionary] = r.step().events
		t.eq(of_type(evs, "hideStart").size(), 1, "%s: F at the hide's front starts getting in" % r.st.seed)
		evs = r.run(Seek.IN_SLOW + 0.1)
		t.eq(of_type(evs, "hideIn").size(), 1, "%s: in after the slow way" % r.st.seed)
		t.eq(of_type(evs, "flap").size(), 0, "%s: the slow way let a flap go" % r.st.seed)
		var rp := r.rp("p0")
		t.check(rp.body.x == inside.x and rp.body.z == inside.z, "%s: the run holds the body at the hide's inside spot" % r.st.seed)
		t.eq(r.sp("p0").hide, h.id, "%s: the seek's hide" % r.st.seed)
		# Whatever body the player sends, the rules keep them inside.
		r.bodies["p0"] = front
		r.run(0.5)
		t.check(r.rp("p0").body.x == inside.x and r.rp("p0").body.z == inside.z, "%s: a body sent from inside moved the player" % r.st.seed)
		r.peek["p0"] = true
		r.run(0.1)
		var blk: Dictionary = Host.seek_block(r.st)
		var me: Dictionary = {}
		for p: Dictionary in blk["players"]:
			if p["id"] == "p0":
				me = p
		t.eq([me.get("hide"), me.get("peek"), me.get("phase")], [h.id, true, "inside"], "%s: the seek block says hidden and peeking" % r.st.seed)
		r.peek.erase("p0")
		r.hide["p0"] = true
		evs = r.step().events
		t.eq(of_type(evs, "hideLeave").size(), 1, "%s: F inside starts getting out" % r.st.seed)
		t.check(r.rp("p0").body.x == front.x and r.rp("p0").body.z == front.z, "%s: getting out stands you at the front" % r.st.seed)
		evs = r.run(Seek.OUT_SLOW + 0.1)
		t.eq(of_type(evs, "hideOut").size(), 1, "%s: out after the slow way" % r.st.seed)
		t.eq(of_type(r.events, "count").size(), 0, "%s: the slow way in and out is silent" % r.st.seed)
		# The quick way lets the flap go: a noise, and a count.
		r.hide["p0"] = true
		r.fast["p0"] = true
		evs = r.step().events
		t.eq(of_type(evs, "flap").size(), 1, "%s: the quick way lets the flap go" % r.st.seed)
		var c := of_type(evs, "count")
		t.check(c.size() == 1 and String(c[0]["why"]) == "flap" and String(c[0]["by"]) == "p0", "%s: the flap started a count (%s)" % [r.st.seed, str(c)])

## Runs the Rig until p1 (placed by the Minder in a count) is taken. Returns the found event.
static func get_taken(t: T, r: Rig) -> Dictionary:
	to_away(t, r)
	r.st = DayRigLib.give(r.st, "p1", 120.0, "fixture-p1")
	r.gait["p0"] = &"sprint"
	r.bodies["p0"] = nudge(r.plan(), r.bodies["p0"], 0.25)
	r.step()
	r.gait["p0"] = &"creep"
	r.off["p0"] = true
	r.off["p2"] = true
	r.run(Seek.HIDE_TIME - 0.5)
	var m := r.st.seek.minder as Seek.MinderState
	var back := Vector2(M.sin_js(m.yaw), M.cos_js(m.yaw)) * 0.6
	r.bodies["p1"] = Move.move_with_collision(r.plan(), m.body, back.x, back.y, 0.3)
	return r.until_event("found", 3.0)

func test_found_is_caught_where_found_and_taken_to_the_table(t: T) -> void:
	var n := 2 if t.quick else 6
	for i in n:
		var r := Rig.new("count-found-%d" % i)
		r.run(0.1)
		var found := get_taken(t, r)
		t.eq([found.get("playerId"), found.get("cause")], ["p1", "touch"], "%s: found by touch beside it" % r.st.seed)
		if found.is_empty():
			continue
		var at := r.rp("p1").body
		t.eq(r.rp("p1").status, &"caught", "%s: found is out of the run" % r.st.seed)
		var drops := of_type(r.events, "tapeDropped")
		t.check(drops.size() == 1 and String(drops[0]["tapeId"]) == "tape-2", "%s: the found player's tape dropped (%s)" % [r.st.seed, str(drops)])
		if drops.size() == 1:
			var d: Move.Body = drops[0]["at"]
			t.check(d.x == at.x and d.z == at.z, "%s: the tape lies where they were found" % r.st.seed)
		# Rooted: whatever they send.
		r.bodies["p1"] = nudge(r.plan(), at, 1.0)
		r.run(0.3)
		var still := r.rp("p1").body
		t.check(still.x == at.x and still.z == at.z or of_type(r.events, "taken").size() > 0, "%s: a found player moved" % r.st.seed)
		var taken := r.until_event("taken", 10.0)
		if r.sp("p1").status != &"taken":
			t.check(not taken.is_empty() and taken.get("playerId") == "p1", "%s: never taken" % r.st.seed)
		var seat: Playroom.Seat = Playroom.seats(r.plan())[r.sp("p1").seat]
		var sb := Seek.point_body(r.plan(), seat.at, seat.level)
		var b := r.rp("p1").body
		t.check(b.x == sb.x and b.z == sb.z, "%s: taken sits you at the party table" % r.st.seed)
		t.eq(of_type(r.events, "caught").size(), 0, "%s: a run event 'caught' on the Playroom" % r.st.seed)

func test_a_taken_players_position_is_never_a_target(t: T) -> void:
	var n := 2 if t.quick else 6
	var watched := 0
	for i in n:
		var r := Rig.new("count-taken-%d" % i)
		r.run(0.1)
		get_taken(t, r)
		var tk := r.until_event("taken", 10.0)
		if r.sp("p1") == null or r.sp("p1").status != &"taken":
			t.check(false, "%s: p1 was never taken (%s)" % [r.st.seed, str(tk)])
			continue
		var p1_index := -1
		for k in r.seek().players.size():
			if r.seek().players[k].id == "p1":
				p1_index = k
		var from := r.events.size()
		# Whatever p1 sends from now on (here: sprinting at the Minder's side, through this count and the
		# next ones), nothing it does or where it stands counts.
		r.gait["p1"] = &"sprint"
		var secs := 0.0
		while secs < 140.0:
			var m := r.st.seek.minder as Seek.MinderState
			r.bodies["p1"] = Move.move_with_collision(r.plan(), m.body, 0.4, 0.0, 0.3)
			# p2 starts a count whenever one can start (a sprint where it stands), and is off the floor
			# meanwhile (so it is never found or worn down, and there is always a next count).
			if r.seek().counting or r.st.t < r.seek().calm_until:
				r.off["p2"] = true
			else:
				r.off.erase("p2")
			r.gait["p2"] = &"sprint"
			r.bodies["p2"] = nudge(r.plan(), r.bodies["p2"], 0.2 if r.ticks % 2 == 0 else -0.2)
			r.step()
			secs += DT
			var mm := r.st.seek.minder as Seek.MinderState
			if (mm.goal_kind == &"player" or mm.goal_kind == &"spot") and mm.goal_id == p1_index:
				t.check(false, "%s: the Minder set off for the taken player at %.2f s" % [r.st.seed, r.st.t])
				break
			if r.seek().counting and Seek.phase_of(r.seek()) == &"seek":
				watched += 1
		for e: Dictionary in r.events.slice(from):
			if String(e.get("playerId", "")) == "p1" or String(e.get("by", "")) == "p1":
				t.check(false, "%s: an event names the taken player: %s" % [r.st.seed, str(e)])
				break
		t.eq(r.sp("p1").status, &"taken", "%s: still at the table" % r.st.seed)
		t.check(of_type(r.events.slice(from), "count").size() >= 1, "%s: no later count (vacuous)" % r.st.seed)
	t.check(watched > 0, "never searched with a taken player about (vacuous)")
	t.note("%d floors: %d searching ticks with the taken player sprinting at its side; never named, never a target" % [n, watched])

func test_recording_is_gated(t: T) -> void:
	var n := 2 if t.quick else 6
	var rec_ticks := 0
	var hearing := 0
	var slip := ""
	for i in n:
		var r := Rig.new("count-rec-%d" % i)
		r.run(0.1)
		to_away(t, r)
		for id in IDS:
			r.raised[id] = true
		# p2 in a hide, sitting back; p0 starts the count; p1 follows behind the Minder.
		var h := a_hide(r.plan(), i + 1)
		r.bodies["p2"] = Seek.hide_front_body(r.plan(), h)
		r.run(0.2)
		r.hide["p2"] = true
		r.run(Seek.IN_SLOW + 0.2)
		var quiet := r.run(3.0)
		for id in IDS:
			t.check(Instr.member(r.st.crew, id).instrument.needle != &"recording", "%s: recording outside a count" % r.st.seed)
		r.gait["p0"] = &"sprint"
		r.bodies["p0"] = nudge(r.plan(), r.bodies["p0"], 0.25)
		r.step()
		r.gait["p0"] = &"creep"
		r.off["p0"] = true
		var guard := 0
		while r.seek().counting and guard < 2000:
			guard += 1
			var m := r.st.seek.minder as Seek.MinderState
			var back := Vector2(M.sin_js(m.yaw), M.cos_js(m.yaw)) * 3.0
			if r.sp("p1").status == &"ok":
				r.bodies["p1"] = Move.move_with_collision(r.plan(), m.body, back.x, back.y, 0.3)
			r.peek["p2"] = (guard / 40) % 2 == 1
			r.step()
			var ss := r.seek()
			var mm := ss.minder
			for id in IDS:
				var mem := Instr.member(r.st.crew, id)
				if mem.instrument.needle != &"recording":
					continue
				rec_ticks += 1
				var p := Seek.player_of(ss, id)
				var ok := Seek.phase_of(ss) == &"seek" and p.status == &"ok"
				if p.phase == &"inside":
					ok = ok and p.peeking
				else:
					ok = ok and not Seek.in_view(r.plan(), mm.body, mm.yaw, p.body)
				t.check(ok, "%s: %s recorded at %.2f s (phase %s, %s, peeking %s)" % [r.st.seed, id, r.st.t, Seek.phase_of(ss), p.phase, str(p.peeking)])
		for e in of_type(r.events, "readingClosed"):
			if String((e["reading"] as TapeLib.Reading).trait_name) == "hearing":
				hearing += 1
		for e in of_type(r.events, "slip"):
			slip = String(e["text"])
	t.check(rec_ticks > 0, "nobody ever recorded the Minder (vacuous)")
	t.check(hearing > 0, "no reading of trait hearing closed")
	t.eq(slip, "recorded while: subject searching", "the slip")
	t.note("%d floors: %d recording ticks, all in the search, out of its view or peeking; %d hearing readings" % [n, rec_ticks, hearing])

## The car door's spot on the landing, within reach of the call.
static func at_door(r: Rig) -> Move.Body:
	return Run.car_body(r.st.car, -0.8, 0.0)

func test_the_last_count_then_the_doors(t: T) -> void:
	var n := 2 if t.quick else 6
	for i in n:
		for during: bool in [false, true]:
			var r := Rig.new("count-last-%d-%s" % [i, str(during)])
			r.run(0.1)
			to_away(t, r)
			var first_end := -1.0
			if during:
				r.gait["p1"] = &"sprint"
				r.bodies["p1"] = nudge(r.plan(), r.bodies["p1"], 0.25)
				r.step()
				r.gait["p1"] = &"creep"
				for id in IDS:
					r.off[id] = true
				r.run(10.0)
				r.off.erase("p0")
			r.bodies["p0"] = at_door(r)
			r.step()
			r.call_by = "p0"
			var evs := r.step().events
			# Nobody is on the floor for it from here: inactive players are never hunted.
			for id in IDS:
				r.off[id] = true
			var called := of_type(evs, "called")
			t.check(called.size() == 1 and bool(called[0].get("last", false)), "%s: the call (%s)" % [r.st.seed, str(called)])
			t.eq(r.st.phase, &"coming", "%s: the car is coming" % r.st.seed)
			t.check(r.st.call == null and r.st.blink == null, "%s: the usual wait (call schedule, blinks)" % r.st.seed)
			var lc := of_type(evs, "count")
			if during:
				t.eq(lc.size(), 0, "%s: a call in a count starts nothing yet" % r.st.seed)
				var end := r.until_event("countEnd", 60.0)
				first_end = float(end.get("t", -1.0))
				lc = [r.until_event("count", 10.0)]
				t.check(absf(float(lc[0].get("t0", -1.0)) - (first_end + Seek.LAST_AFTER)) < 1e-6, "%s: the last count starts 6 s after the running one (%s)" % [r.st.seed, str(lc[0])])
			t.check(lc.size() == 1 and bool(lc[0].get("last", false)) and float(lc[0].get("len", 0.0)) == Seek.LAST_LENGTH and String(lc[0].get("why", "")) == "call" and String(lc[0].get("by", "")) == "p0",
				"%s: the last count's event (%s)" % [r.st.seed, str(lc)])
			var t0 := float(lc[0].get("t0", 0.0))
			var opened := {}
			var ended := {}
			for _k in roundi(60.0 / DT):
				var res := r.step()
				for e in res.events:
					if e["type"] == "doorsOpened" and String(e["reason"]) == "boarding":
						opened = e
					if e["type"] == "countEnd" and bool(e["last"]):
						ended = e
				if not opened.is_empty():
					break
				t.eq(r.st.phase, &"coming", "%s: the phase before the doors" % r.st.seed)
			t.check(not ended.is_empty() and not opened.is_empty() and float(opened["t"]) == float(ended["t"]), "%s: the doors opened on the last count's end (%s, %s)" % [r.st.seed, str(ended), str(opened)])
			t.check(absf(float(opened.get("t", 0.0)) - (t0 + Seek.HIDE_TIME + Seek.LAST_LENGTH)) < 1e-6, "%s: the doors opened %.3f s after the last count began" % [r.st.seed, float(opened.get("t", 0.0)) - t0])
			t.eq(r.st.phase, &"boarding", "%s: boarding" % r.st.seed)
			t.eq(of_type(r.events, "carArrived").size(), 1, "%s: the car arrived once" % r.st.seed)

func test_health_and_down(t: T) -> void:
	var n := 2 if t.quick else 6
	var downs := 0
	for i in n:
		var r := Rig.new("count-health-%d" % i)
		r.run(0.1)
		to_away(t, r)
		r.st = DayRigLib.give(r.st, "p1", 80.0, "fixture-p1")
		var spot: Move.Body = r.bodies["p1"]
		var other := nudge(r.plan(), spot, 0.05)
		# Walking (on the spot) before any count: no drain.
		r.gait["p1"] = &"walk"
		for k in roundi(10.0 / DT):
			r.bodies["p1"] = other if k % 2 == 0 else spot
			r.step()
		t.eq(r.sp("p1").health, Seek.HEALTH_MAX, "%s: health before the first count" % r.st.seed)
		t.eq(of_type(r.events, "count").size(), 0, "%s: walking started a count" % r.st.seed)
		# A count, waited out with nobody on the floor.
		r.gait["p0"] = &"sprint"
		r.bodies["p0"] = nudge(r.plan(), r.bodies["p0"], 0.25)
		r.step()
		for id in IDS:
			r.off[id] = true
		r.until_event("countEnd", 40.0)
		r.off.erase("p1")
		var down := {}
		var walked := 0.0
		for k in roundi(40.0 / DT):
			r.bodies["p1"] = other if k % 2 == 0 else spot
			var res := r.step()
			walked += DT
			for e in res.events:
				if e["type"] == "down":
					down = e
			if not down.is_empty():
				break
		t.check(not down.is_empty() and String(down["playerId"]) == "p1", "%s: walking never put p1 down" % r.st.seed)
		if down.is_empty():
			continue
		downs += 1
		t.check(absf(walked - Seek.HEALTH_MAX / Seek.WALK_DRAIN) < 0.2, "%s: down after %.2f s of walking" % [r.st.seed, walked])
		t.eq(r.rp("p1").status, &"caught", "%s: down is out of the run" % r.st.seed)
		t.check(of_type(r.events, "tapeDropped").size() == 1, "%s: the tape dropped" % r.st.seed)
		var next := r.step().events
		var c := of_type(next, "count")
		t.check(c.size() == 1 and String(c[0]["why"]) == "tape" and String(c[0]["by"]) == "p1", "%s: the dropped tape is heard the next tick (%s)" % [r.st.seed, str(c)])
	t.check(downs > 0, "nobody went down (vacuous)")

func test_no_count_with_the_resident_off(t: T) -> void:
	var r := Rig.new("count-off", false)
	r.run(0.1)
	to_away(t, r)
	r.gait["p1"] = &"sprint"
	for _k in 40:
		r.bodies["p1"] = nudge(r.plan(), r.bodies["p1"], 0.2)
		r.step()
	t.check(r.st.seek == null, "a seek state with the resident off")
	t.eq(of_type(r.events, "count").size(), 0, "counts with the resident off")
