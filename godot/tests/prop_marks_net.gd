# The Annex's crew marks and the Temp's sticky notes in the run and on the network (docs/floors/annex.md
# sections 2 and 4; loop/NIGHT-PLAN.md A6; T16h). Proved here:
#   1. In the run (pure rules, floor 3 of the game's deck, the Annex):
#        - one pad for the whole crew, Marks.DEFAULT_PAD a floor: Q starts a placing at the feet, the run
#          finishes it half a second later by itself; refused in the car, sprinting, or with the pad empty;
#          a peel needs to stand within reach and puts it back on the pad;
#        - marks are immune: while the Temp hunts and posts notes, no mark moves or changes;
#        - a new floor has a full pad and no notes; off the Annex there are no marks at all;
#        - the notes come at their triggers (the lobby's as the arrival doors open; the call and the wake;
#          a catch; the quota met; every 25 s of hunting), only in ticks the Temp is not held (nobody
#          looking), name the crew by the host's names, and stop at the floor's cap.
#   2. Over the network: three bots (Ana, Bo, Cy), each on its own lossy link to the host (tests/
#      net_harness.gd's LOSSY: up to 250 ms delay, 60 ms jitter, 5% loss, reordering and duplicates) and its
#      own clock, play the Annex through the real NetHost (net/host.gd with net/host_rules.gd, the resident
#      on) and the real NetClient, sending only what a player sends (a body, a view, Q, a peel, the call):
#      out of the car, three marks from the one pad, a refusal, a peel and a mark again, back to the lift,
#      the call (the Temp wakes), the car, the ride down. A fourth player (Di) joins in the middle of the
#      floor, as a spectator. Proved: every snapshot's marks and pad on every client are the host's at that
#      tick; every client (the joiner too) ends the floor with the host's notes, in order, and its marks;
#      no mark ever moved; and on the next floor everyone's marks and notes are gone.
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Follow = preload("res://sim/follow.gd")
const Entity = preload("res://sim/entity.gd")
const Places = preload("res://sim/places.gd")
const Annex = preload("res://sim/annex.gd")
const Marks = preload("res://sim/marks.gd")
const Notes = preload("res://sim/notes.gd")
const Rng = preload("res://sim/rng.gd")
const M = preload("res://sim/jsmath.gd")
const Session = preload("res://net/session.gd")
const Transport = preload("res://net/transport.gd")
const Protocol = preload("res://net/protocol.gd")
const Host = preload("res://net/host.gd")
const Client = preload("res://net/client.gd")
const HostRules = preload("res://net/host_rules.gd")
const Harness = preload("res://tests/net_harness.gd")
const DayNet = preload("res://tests/prop_day_net.gd")

const TICK := Session.TICK
const STEP := 0.025
const FRAME := 0.05
const SPEED := 2.0
const RADIUS := 0.3
## Those waiting at the lift look at the Temp once it is this close (metres).
const GUARD := 7.0
const NAMES := {"p0": "Ana", "p1": "Bo", "p2": "Cy", "p3": "Di"}

# ---------------------------------------------------------------------------------------------
# Helpers.

## A run on floor 3 of the game's deck (the Annex), the crew in the car, the doors about to open.
static func annex_run(seed: String, ids: Array[String], quota: bool = false) -> Run.RunState:
	var s := HostRules.new(true, 3, Places.FULL, false, quota).prepare(Run.create_run(seed, ids))
	s.names = {}
	for id in ids:
		s.names[id] = NAMES.get(id, id)
	return s

static func one(x: Run.PlayerInput) -> Array[Run.PlayerInput]:
	var a: Array[Run.PlayerInput] = [x]
	return a

static func inp(id: String, body: Move.Body, yaw: float = 0.0) -> Run.PlayerInput:
	return Run.PlayerInput.make(id, body, 1.65, yaw, 0.0, 90.0, 70.0)

## Walkable cells on the landing's level, `d` steps from the landing, in index order.
static func cells_at(plan: Floor.FloorPlan, d: int) -> Array[Floor.Pos]:
	var dist := Floor.distances_from(plan, plan.landing)
	var out: Array[Floor.Pos] = []
	for i in dist.size():
		var p := Floor.pos_from_index(plan, i)
		if dist[i] == d and p.level == plan.landing.level:
			out.append(p)
	return out

## Marks as comparable rows (quantised as the wire carries them).
static func marks_rows(list: Array) -> Array:
	var out: Array = []
	for m: Dictionary in list:
		out.append([int(m["id"]), Protocol.q2(float(m["x"])), Protocol.q2(float(m["z"])), int(m["level"]), int(m["dir"]), str(m["player"]), Protocol.q3(float(m["placedAt"]))])
	return out

## Notes as comparable rows (quantised as the wire carries them).
static func notes_rows(list: Array) -> Array:
	var out: Array = []
	for n: Dictionary in list:
		out.append([int(n["id"]), int(n["n"]), str(n["trigger"]), int(n["template"]), str(n["text"]), Protocol.q2(float(n["x"])), Protocol.q2(float(n["z"])),
			int(n["level"]), Protocol.q3(float(n["yaw"])), Protocol.q3(float(n["t"]))])
	return out

static func of_type(events: Array, ty: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e: Dictionary in events:
		if str(e.get("type")) == ty:
			out.append(e)
	return out

## Whether a template has a slot that is a crew member's name.
static func names_someone(template: int) -> bool:
	for tpl: Dictionary in Notes.data()["templates"]:
		if int(tpl["id"]) == template:
			for slot: String in tpl["slots"]:
				if slot == "name" or slot == "name2":
					return true
	return false

static func names_crew(text: String, crew: Array) -> bool:
	for n: Variant in crew:
		if text.contains(str(n)):
			return true
	return false

## Each mark by id as a row, for "never moved or changed".
static func mark_fields(s: Run.RunState) -> Dictionary:
	var out := {}
	if s.annex != null:
		for m in s.annex.marks.marks:
			out[m.id] = [m.x, m.z, m.level, m.dir, m.player, m.placed_at]
	return out

# ---------------------------------------------------------------------------------------------
# 1. In the run.

func test_marks_share_one_pad_and_never_move(t: T) -> void:
	var ids: Array[String] = ["p0", "p1", "p2"]
	var s := annex_run("marks-run", ids)
	if not t.eq(s.plan.place, Places.ANNEX, "floor 3 of the game's deck is the Annex"):
		return
	var plan := s.plan
	var car := s.car
	var bodies := {}
	for p in s.players:
		bodies[p.id] = p.body
	# The first tick makes the floor's state: a full pad, nothing down, no notes.
	var none: Array[Run.PlayerInput] = []
	var r := Run.step_run(s, none, TICK)
	s = r.state
	t.check(s.annex != null and s.annex.marks.pad == Marks.DEFAULT_PAD and s.annex.marks.marks.is_empty() and s.annex.notes.is_empty(), "a new Annex floor: a full pad, no marks")
	# Q in the car: refused.
	var press := inp("p0", bodies["p0"])
	press.mark = true
	r = Run.step_run(s, one(press), TICK)
	s = r.state
	var refused := of_type(r.events, "markRefused")
	t.check(refused.size() == 1 and refused[0]["reason"] == "in_car", "Q in the car is refused: %s" % str(refused))
	# Out on the floor: three spots a few cells out.
	var spots := cells_at(plan, 3)
	if not t.check(spots.size() >= 3, "three cells 3 steps out"):
		return
	for i in 3:
		bodies[ids[i]] = Move.body_at_cell(plan, spots[i])
	var all := func(extra: Dictionary) -> Array[Run.PlayerInput]:
		var out: Array[Run.PlayerInput] = []
		for id in ids:
			var x: Run.PlayerInput = inp(id, bodies[id], 0.7)
			if extra.has(id):
				for k: String in extra[id]:
					x.set(k, extra[id][k])
			out.append(x)
		return out
	# p0 places: the placing takes half a second, and only then is one gone from the pad.
	r = Run.step_run(s, all.call({"p0": {"mark": true}}), TICK)
	s = r.state
	var start := of_type(r.events, "markStart")
	t.check(start.size() == 1 and int(start[0]["dir"]) == Marks.snap_dir(0.7), "Q starts a placing, pointing where p0 faces: %s" % str(start))
	var ticks := 1
	var placed: Array[Dictionary] = []
	while placed.is_empty() and ticks < 40:
		r = Run.step_run(s, all.call({}), TICK)
		s = r.state
		ticks += 1
		placed = of_type(r.events, "markPlaced")
	t.check(absf(ticks * TICK - Marks.PLACE_SECONDS) < TICK + 1e-6, "placed %.2f s after Q (want %.2f)" % [ticks * TICK, Marks.PLACE_SECONDS])
	t.eq(s.annex.marks.pad, Marks.DEFAULT_PAD - 1, "the crew's pad after one mark")
	if not placed.is_empty():
		var m: Dictionary = placed[0]["mark"]
		t.check(absf(float(m["x"]) - bodies["p0"].x) < 0.006 and absf(float(m["z"]) - bodies["p0"].z) < 0.006 and m["player"] == "p0", "the mark is at p0's feet with p0's initial: %s" % str(m))
		t.eq(float(placed[0]["radius"]), Marks.NOISE_RADIUS, "the slap's reach")
	# p1 sprinting: refused. Walking: placed.
	r = Run.step_run(s, all.call({"p1": {"mark": true, "gait": &"sprint"}}), TICK)
	s = r.state
	refused = of_type(r.events, "markRefused")
	t.check(refused.size() == 1 and refused[0]["reason"] == "sprinting", "Q while sprinting is refused: %s" % str(refused))
	r = Run.step_run(s, all.call({"p1": {"mark": true}}), TICK)
	s = r.state
	for _k in 12:
		s = Run.step_run(s, all.call({}), TICK).state
	t.eq(s.annex.marks.pad, Marks.DEFAULT_PAD - 2, "the crew's pad after two marks (one each by p0 and p1)")
	# p0 and p2 both press with one left: one is placed, the other finds the pad empty.
	bodies["p0"] = Move.body_at_cell(plan, cells_at(plan, 4)[0])
	r = Run.step_run(s, all.call({"p0": {"mark": true}, "p2": {"mark": true}}), TICK)
	s = r.state
	t.eq(of_type(r.events, "markStart").size(), 2, "two placings start with one mark left")
	var evs: Array[Dictionary] = []
	for _k in 12:
		r = Run.step_run(s, all.call({}), TICK)
		s = r.state
		evs.append_array(r.events)
	var last := of_type(evs, "markRefused")
	t.check(of_type(evs, "markPlaced").size() == 1 and last.size() == 1 and last[0]["reason"] == "pad_empty", "the last mark goes to one of them, the other finds the pad empty: %s" % str(evs))
	t.eq(s.annex.marks.pad, 0, "the pad is empty")
	r = Run.step_run(s, all.call({"p1": {"mark": true}}), TICK)
	s = r.state
	refused = of_type(r.events, "markRefused")
	t.check(refused.size() == 1 and refused[0]["reason"] == "pad_empty", "Q with the pad empty is refused")
	# Peels: from far away refused; standing on it, back on the pad.
	var first: Marks.Mark = s.annex.marks.marks[0]
	r = Run.step_run(s, all.call({"p2": {"peel": first.id}}), TICK)
	s = r.state
	refused = of_type(r.events, "markRefused")
	t.check(refused.size() == 1 and refused[0]["reason"] == "far", "a peel from far away is refused: %s" % str(refused))
	bodies["p2"] = Move.Body.make(first.x + 0.5, first.z, first.level, bodies["p2"].y)
	r = Run.step_run(s, all.call({"p2": {"peel": first.id}}), TICK)
	s = r.state
	var peeled := of_type(r.events, "markPeeled")
	t.check(peeled.size() == 1 and int(peeled[0]["id"]) == first.id and peeled[0]["owner"] == "p0" and peeled[0]["playerId"] == "p2", "p2 peels p0's mark: %s" % str(peeled))
	t.eq(s.annex.marks.pad, 1, "the peeled mark is back on the crew's pad")
	r = Run.step_run(s, all.call({"p2": {"mark": true}}), TICK)
	s = r.state
	for _k in 12:
		s = Run.step_run(s, all.call({}), TICK).state
	t.check(s.annex.marks.pad == 0 and s.annex.marks.marks.size() == Marks.DEFAULT_PAD, "p2 places it again: %d down, pad %d" % [s.annex.marks.marks.size(), s.annex.marks.pad])
	t.eq(s.annex.marks.pad + s.annex.marks.marks.size(), s.annex.marks.pad_size, "pad and marks add up to the pad size")

	# Immune: the car called (the Temp wakes), everyone with their back to it, so it hunts and posts.
	var kept := mark_fields(s)
	s = s.copy()
	s.phase = &"away"
	var call_body := Run.car_body(car, -0.6, 0.0)
	var moved := 0
	var temp_notes := 0
	var held_notes := 0
	var catches := 0
	for k in 400:
		var ins: Array[Run.PlayerInput] = []
		for p in s.players:
			if p.status != &"ok":
				continue
			var b: Move.Body = call_body if (k == 0 and p.id == "p1") else bodies[p.id]
			var away := Entity.yaw_toward(b.x - s.orderly.body.x, b.z - s.orderly.body.z)
			var x := inp(p.id, b, away)
			x.call = k == 0 and p.id == "p1"
			ins.append(x)
		r = Run.step_run(s, ins, TICK)
		s = r.state
		for e in r.events:
			if e["type"] == "note":
				temp_notes += 1
				if s.orderly.held:
					held_notes += 1
			elif e["type"] == "caught":
				catches += 1
		if s.annex == null:
			break
		var now := mark_fields(s)
		for id: int in kept:
			if now.get(id) != kept[id]:
				moved += 1
		if now.size() != kept.size():
			moved += 1
	t.check(temp_notes >= 2, "the Temp posted notes while the marks were down: %d" % temp_notes)
	t.eq(held_notes, 0, "notes posted in a tick the Temp was held")
	t.eq(moved, 0, "ticks a mark moved, changed or went (marks are immune; only a peel removes one)")
	t.note("one pad of %d: placed %.2f s after Q; the Temp posted %d notes and caught %d while %d marks lay untouched" % [Marks.DEFAULT_PAD, Marks.PLACE_SECONDS, temp_notes, catches, kept.size()])

func test_marks_and_notes_reset_per_floor_and_only_on_the_annex(t: T) -> void:
	var ids: Array[String] = ["p0", "p1"]
	var s := annex_run("marks-reset", ids)
	var spot := Move.body_at_cell(s.plan, cells_at(s.plan, 3)[0])
	var none: Array[Run.PlayerInput] = []
	for _k in 30:
		s = Run.step_run(s, none, TICK).state
	var x := inp("p0", spot)
	x.mark = true
	s = Run.step_run(s, one(x), TICK).state
	for _k in 12:
		s = Run.step_run(s, one(inp("p0", spot)), TICK).state
	t.check(s.annex.marks.marks.size() == 1 and not s.annex.notes.is_empty(), "a mark and the lobby note on floor 3")
	var seq := s.note_seq
	# Another Annex plan (a new floor): a full pad, no marks, no notes, note ids carry on.
	var other := s.copy()
	other.plan = Annex.generate_annex("marks-reset", 5)
	other.car = Run.car_geometry(other.plan)
	other.orderly = Places.create_resident(other.plan)
	var o2 := Run.step_run(other, none, TICK).state
	t.check(o2.annex != null and o2.annex.plan == o2.plan and o2.annex.marks.pad == Marks.DEFAULT_PAD and o2.annex.marks.marks.is_empty() and o2.annex.notes.is_empty(),
		"a new Annex floor: a full pad and no notes")
	t.eq(o2.annex.notes_from, seq, "the new floor's notes are numbered on from the run's count")
	# The ride down: the next floor (the Playroom) has no marks and no notes.
	var ride := s.copy()
	ride.phase = &"riding"
	ride.timer = TICK / 2.0
	var arrived := Run.step_run(ride, none, TICK)
	t.check(of_type(arrived.events, "rodeDown").size() == 1 and arrived.state.depth == 4, "rode down to floor 4")
	t.check(arrived.state.annex == null, "floor 4 has no marks and no notes")
	# A Clinic run: Q does nothing at all.
	var c := Run.create_run("marks-clinic", ids)
	var cspot := Move.body_at_cell(c.plan, cells_at(c.plan, 3)[0])
	var events: Array[Dictionary] = []
	for k in 60:
		var y := inp("p0", cspot)
		y.mark = k % 5 == 0
		var cr := Run.step_run(c, one(y), TICK)
		c = cr.state
		events.append_array(cr.events)
	t.check(c.annex == null, "the Clinic has no marks")
	for ty: String in ["markStart", "markPlaced", "markRefused", "note"]:
		t.eq(of_type(events, ty).size(), 0, "%s events on the Clinic" % ty)

func test_notes_come_at_their_triggers_and_name_the_crew(t: T) -> void:
	var ids: Array[String] = ["p0", "p1", "p2"]
	var s := annex_run("notes-run", ids)
	var crew: Array = ["Ana", "Bo", "Cy"]
	var plan := s.plan
	var car := s.car
	var all_notes: Array[Dictionary] = []
	var held := {"notes": 0}
	var trace := func(r: Run.RunStep) -> void:
		for e in r.events:
			if e["type"] == "note":
				all_notes.append(e)
				if e["trigger"] != "lobby" and r.state.orderly.held:
					held["notes"] += 1
	# The lobby note: posted in the tick the arrival doors open.
	var none: Array[Run.PlayerInput] = []
	var opened_tick := -1
	var lobby_tick := -1
	for k in 60:
		var r := Run.step_run(s, none, TICK)
		trace.call(r)
		s = r.state
		if of_type(r.events, "doorsOpened").size() > 0 and opened_tick < 0:
			opened_tick = k
		for e in of_type(r.events, "note"):
			if e["trigger"] == "lobby":
				lobby_tick = k
	t.check(opened_tick >= 0 and lobby_tick == opened_tick, "the lobby note goes up as the doors open (doors at tick %d, note at %d)" % [opened_tick, lobby_tick])
	t.eq(of_type(all_notes, "note").size(), 1, "one note so far")
	# p0 on the landing, looking at the Temp two cells off; the others in the car. p0 calls the car.
	var dir := Vector2i.ZERO
	for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var a := Floor.Pos.make(plan.landing.level, plan.landing.x + d.x, plan.landing.y + d.y)
		var b := Floor.Pos.make(plan.landing.level, plan.landing.x + 2 * d.x, plan.landing.y + 2 * d.y)
		if Floor.can_step(plan, plan.landing, a) and Floor.can_step(plan, a, b):
			dir = d
			break
	if not t.check(dir != Vector2i.ZERO, "a straight two cells from the landing"):
		return
	var here := Move.body_at_cell(plan, plan.landing)
	var o := s.orderly.copy()
	o.body = Move.body_at_cell(plan, Floor.Pos.make(plan.landing.level, plan.landing.x + 2 * dir.x, plan.landing.y + 2 * dir.y))
	o.mode = &"waiting"
	s = s.copy()
	s.orderly = o
	s.phase = &"away"
	var inside := {"p1": Run.car_body(car, 1.0, -0.8), "p2": Run.car_body(car, 1.0, 0.8)}
	var look := Entity.yaw_toward(float(dir.x), float(dir.y))
	var ins := func(p0_yaw: float, p0_call: bool, p0_body: Move.Body) -> Array[Run.PlayerInput]:
		var out: Array[Run.PlayerInput] = []
		for p in s.players:
			if p.status != &"ok":
				continue
			if p.id == "p0":
				var x := inp("p0", p0_body, p0_yaw)
				x.call = p0_call
				out.append(x)
			else:
				out.append(inp(p.id, inside[p.id], 0.0))
		return out
	var r0 := Run.step_run(s, ins.call(look, true, here), TICK)
	trace.call(r0)
	s = r0.state
	t.check(of_type(r0.events, "called").size() == 1 and of_type(r0.events, "startedHunting").size() == 1, "the call is taken and wakes the Temp")
	# Watched: nothing is posted, however long.
	var before := all_notes.size()
	for _k in 40:
		var r := Run.step_run(s, ins.call(look, false, here), TICK)
		trace.call(r)
		s = r.state
	t.check(s.orderly.held, "p0 holds the Temp by looking")
	t.eq(all_notes.size(), before, "notes posted while the Temp was watched")
	# p0 turns away: the call's and the wake's notes go up, one a tick; then it comes for p0.
	var turned := all_notes.size()
	var caught := false
	for _k in 200:
		var r := Run.step_run(s, ins.call(look + PI, false, here), TICK)
		trace.call(r)
		s = r.state
		if of_type(r.events, "caught").size() > 0:
			caught = true
		if caught and all_notes.size() >= turned + 3:
			break
	var triggers: Array = []
	for n: Dictionary in all_notes.slice(turned):
		triggers.append(n["trigger"])
	t.check(triggers.size() >= 2 and triggers.slice(0, 2).has("lift") and triggers.slice(0, 2).has("wake"), "the call's and the wake's notes once it is unwatched: %s" % str(triggers))
	t.check(caught and triggers.has("catch"), "a catch is a note: %s" % str(triggers))
	for n in all_notes:
		if n["trigger"] == "catch" and (int(n["template"]) == 11 or int(n["template"]) == 19):
			t.check(str(n["text"]).contains("Ana"), "the catch note names who was caught: %s" % n["text"])
	# The quota met: a note naming who did most of it (the run's own quotaMet, from its own numbers).
	s = s.copy()
	s.quota = true
	s.floor_needed = 5
	s.floor_earned = 10.0
	s.floor_by = {"p1": 10.0}
	s.quota_met = false
	var quota_note := ""
	for _k in 40:
		var r := Run.step_run(s, ins.call(0.0, false, Run.car_body(car, 1.0, 0.0)), TICK)
		trace.call(r)
		s = r.state
		for n in of_type(r.events, "note"):
			if n["trigger"] == "quota":
				quota_note = n["text"]
		if quota_note != "":
			break
	t.check(quota_note.contains("Bo"), "the quota note names Bo, who did most of it: '%s'" % quota_note)
	# Hunting with nobody to catch (the crew in the car, the doors shut): a note every 25 s, up to the cap.
	s = s.copy()
	s.phase = &"away"
	s.call = null
	s.blink = null
	s.lure = false
	var o2 := s.orderly.copy()
	o2.mode = &"hunting"
	s.orderly = o2
	var hunt_at: Array[float] = []
	var aboard: Array[Run.PlayerInput] = []
	for p in s.players:
		if p.status == &"ok":
			aboard.append(inp(p.id, Run.car_body(car, 1.0, -0.8 + 0.8 * aboard.size()), 0.0))
	for _k in int(400.0 / TICK):
		var r := Run.step_run(s, aboard, TICK)
		trace.call(r)
		s = r.state
		for n in of_type(r.events, "note"):
			if n["trigger"] == "hunt":
				hunt_at.append(s.t)
	var gaps_ok := true
	for i in range(1, hunt_at.size()):
		gaps_ok = gaps_ok and absf(hunt_at[i] - hunt_at[i - 1] - Run.NOTE_HUNT_EVERY) < TICK * 2.0
	t.check(hunt_at.size() >= 2 and gaps_ok, "a hunt note every %.0f s of hunting: at %s" % [Run.NOTE_HUNT_EVERY, str(hunt_at)])
	var cap := Notes.cap_per_floor()
	t.eq(all_notes.size(), cap, "notes on the floor stop at the cap")
	t.eq(s.annex.notes.size(), cap, "the floor's notes")
	t.eq(int(held["notes"]), 0, "notes the Temp posted while held")
	for i in all_notes.size():
		var n: Dictionary = all_notes[i]
		t.eq(int(n["id"]), s.annex.notes_from + i + 1, "note ids count up")
		t.eq(int(n["n"]), i + 1, "the floor's note number")
		if names_someone(int(n["template"])):
			t.check(names_crew(str(n["text"]), crew), "note %d names the crew by name: '%s'" % [i + 1, n["text"]])
	var texts: Array = []
	for n in all_notes:
		texts.append("%s: %s" % [n["trigger"], n["text"]])
	t.note("%d notes: %s" % [all_notes.size(), " | ".join(PackedStringArray(texts.slice(0, 6)))])

# ---------------------------------------------------------------------------------------------
# 2. Over the network.

class Bot:
	var id: String
	var index: int
	var client: Client
	var offset: float
	var next_frame: float
	var body: Move.Body = null
	var walk: Follow.PathWalk = null
	var frames := 0
	## The bot's errand on the floor: a list of steps, each {go: Floor.Pos} (walk there), {mark: true}
	## (press Q), {peel: player id} (walk onto that player's first mark and peel it), {wait: seconds};
	## then back to the lift.
	var plan_steps: Array = []
	var step := 0
	var wait_left := 0.0
	var peel_target: Variant = null
	var home := false
	var drawn: Move.Body = null
	var spectator := false

class Sess:
	var net: Transport.MemoryNetwork
	var host: Host
	var rules: HostRules
	var bots: Array[Bot] = []
	var g := 0.0
	var seed: String
	var ids: Array[String] = ["p0", "p1", "p2"]
	var rng: Rng
	var stage := "floor"
	var board_tick := -1
	var final_done := false
	var deep_checked := {}
	## Every client snapshot's marks against the host's at that tick.
	var compared := 0
	var mismatches: Array[String] = []
	## Marks as first seen on the host, and ticks one differed later.
	var marks_seen := {}
	var moved := 0
	## What each client holds at the end of the floor: {id: {marks, pad, notes}} and the host's.
	var final_clients := {}
	var final_host := {}

	func _init(seed_: String) -> void:
		seed = seed_
		rng = Rng.make_rng("%s:session" % seed)
		net = Transport.MemoryNetwork.new("%s:net" % seed)
		var ht := net.connect_peer("host")
		rules = HostRules.new(true, 3, Places.FULL, false, false)
		host = Host.new(ht, seed, ids, 0.0, Callable(rules, "prepare"), Callable(rules, "step"))
		for i in ids.size():
			var b := add_bot(ids[i])
			b.index = i

	func add_bot(id: String) -> Bot:
		var n := Harness.lossy()
		var tr := net.connect_peer(id)
		for pair: Array in [["host", id], [id, "host"]]:
			var delay := n.delay_min + rng.next() * (n.delay_max - n.delay_min)
			net.set_link(pair[0], pair[1], Transport.LinkConfig.make(delay, n.jitter, n.loss, n.reorder, n.reorder_delay, n.duplicate))
		var b := Bot.new()
		b.id = id
		b.index = bots.size()
		b.offset = (rng.next() - 0.5) * 200.0
		b.next_frame = g + rng.next() * FRAME
		b.client = Client.new(tr, "host", NAMES[id], g + b.offset)
		bots.append(b)
		return b

## The first mark of a player as this client has it, or null.
static func _mark_of(c: Client, player: String) -> Variant:
	for m: Dictionary in c.marks():
		if m["player"] == player:
			return m
	return null

func _bot_frame(s: Sess, b: Bot) -> void:
	var c := b.client
	b.frames += 1
	var lf := Client.LocalFrame.new()
	lf.body = b.body if b.body != null else Move.Body.make(0.0, 0.0, 0, 0.0)
	if not b.spectator and c.seed != null and c.latest != null and b.body != null:
		var latest: Dictionary = c.latest
		var plan := Session.plan_for(str(c.seed), c.local_depth)
		var car := Session.car_for(plan)
		var here := int(latest["depth"]) == c.local_depth
		var phase := str(latest["phase"]) if here else ""
		var body := b.body
		lf.yaw = Entity.yaw_toward(car.in_x, car.in_z)
		if c.local_depth == 3 and phase != "boarding" and phase != "riding" and phase != "arriving" and not b.home:
			if Run.in_car(car, body) or Run.car_local(car, body.x, body.z)[0] > -0.9:
				body = DayNet.walk_toward(plan, phase, car, body, Run.car_body(car, -1.0, -0.5 + 0.5 * b.index))
			elif b.step < b.plan_steps.size():
				var st: Dictionary = b.plan_steps[b.step]
				if st.has("go") or st.has("peel"):
					var to: Variant = st.get("go")
					var m: Variant = null
					if st.has("peel"):
						m = _mark_of(c, str(st["peel"]))
						if m == null:
							b.step += 1  # nothing of theirs to peel
						else:
							to = Move.cell_of(plan, Move.Body.make(float(m["x"]), float(m["z"]), int(m["level"]), 0.0))
					if to != null:
						if b.walk == null:
							b.walk = Follow.start_path_walk(Floor.find_path(plan, Move.cell_of(plan, body), to))
						if not Follow.path_done(plan, b.walk, body):
							body = Follow.step_path_walk(plan, b.walk, body, SPEED * FRAME, RADIUS)
						else:
							b.walk = null
							b.step += 1
							if m != null:
								lf.peel = int(m["id"])
				elif st.has("mark"):
					lf.mark = true
					b.step += 1
				elif st.has("wait"):
					if b.wait_left <= 0.0:
						b.wait_left = float(st["wait"])
					b.wait_left -= FRAME
					if b.wait_left <= 1e-9:
						b.wait_left = 0.0
						b.step += 1
			else:
				# Back to the lift.
				if b.walk == null:
					b.walk = Follow.start_path_walk(Floor.find_path(plan, Move.cell_of(plan, body), plan.landing))
				if not Follow.path_done(plan, b.walk, body):
					body = Follow.step_path_walk(plan, b.walk, body, SPEED * FRAME, RADIUS)
				else:
					b.walk = null
					b.home = true
		elif here and b.home:
			var to: Move.Body = null
			match phase:
				"unloading", "away", "coming":
					to = Run.car_body(car, -0.8, -0.5 + 0.5 * b.index)
				"boarding":
					if s.final_done:
						to = Run.car_body(car, 1.0 + 0.9 * b.index, 1.0)
					else:
						to = Run.car_body(car, -0.8, -0.5 + 0.5 * b.index)
			if to != null:
				body = DayNet.walk_toward(plan, phase, car, body, to)
			var o := b.drawn
			if o != null and o.level == body.level and M.hypot2(o.x - body.x, o.z - body.z) <= GUARD:
				lf.yaw = Entity.yaw_toward(o.x - body.x, o.z - body.z)
			var everyone_home := true
			for x in s.bots:
				everyone_home = everyone_home and (x.spectator or x.home)
			lf.call = everyone_home and b.id == "p0" and phase == "away" and b.frames % 30 == 0 \
				and M.hypot2(body.x - car.door_x, body.z - car.door_z) <= Run.CALL_REACH - 0.3
		b.body = body
		lf.body = body
	var f := c.frame(s.g + b.offset, lf)
	if f.orderly != null:
		var od: Dictionary = f.orderly
		b.drawn = Move.Body.make(float(od["x"]), float(od["z"]), int(od["level"]), float(od["y"]))
	if f.placed != null:
		b.body = f.placed
		b.walk = null
	_check_snapshot(s, b)

## The client's marks and pad against the host's at the snapshot's tick; on floor 4, nothing.
func _check_snapshot(s: Sess, b: Bot) -> void:
	var c := b.client
	if c.latest == null:
		return
	var latest: Dictionary = c.latest
	var hs := s.host.state_at(int(latest["tick"]))
	if hs == null:
		return
	if int(latest["depth"]) == 4:
		s.deep_checked[b.id] = c.marks().is_empty() and c.mark_pad() == null and c.notes().is_empty()
		return
	if hs.annex == null:
		return
	s.compared += 1
	var want: Dictionary = Host.annex_block(hs)
	var got := marks_rows(c.marks())
	var pad: Variant = c.mark_pad()
	if got != marks_rows(want["marks"]) or pad == null or int(pad["pad"]) != int(want["pad"]) or int(pad["size"]) != int(want["padSize"]):
		s.mismatches.append("%s at tick %d: marks %s pad %s, the host's %s pad %d" % [b.id, int(latest["tick"]), str(got), str(pad), str(marks_rows(want["marks"])), int(want["pad"])])

func _on_tick(s: Sess) -> void:
	var st := s.host.state
	# Marks are immune: once placed, a mark is never moved or changed (a peel removes it).
	var now := mark_fields(st)
	for id: int in now:
		if s.marks_seen.has(id) and s.marks_seen[id] != now[id]:
			s.moved += 1
		s.marks_seen[id] = now[id]
	if s.bots.size() == 3 and st.annex != null and of_type(_host_events(s), "markPlaced").size() >= 2:
		# A player joins in the middle of the floor (a spectator until the next stop).
		var j := s.add_bot("p3")
		j.spectator = true
	if st.phase == &"boarding" and s.board_tick < 0:
		# The car is here: the Temp is parked, so the floor goes quiet.
		s.board_tick = s.host.tick
		var o := st.orderly.copy()
		o.mode = &"dormant"
		o.dormant_left = INF
		o.wind_up_target = null
		o.wind_up_left = 0.0
		s.host.replace_orderly(o)
	if s.board_tick >= 0 and not s.final_done and s.host.tick >= s.board_tick + 100:
		# Quiet for five seconds: what every client holds now must be the host's.
		s.final_done = true
		var hb: Dictionary = Host.annex_block(st, true)
		s.final_host = {"marks": marks_rows(hb["marks"]), "pad": int(hb["pad"]), "notes": notes_rows(hb["notes"])}
		for b in s.bots:
			var pad: Variant = b.client.mark_pad()
			s.final_clients[b.id] = {"marks": marks_rows(b.client.marks()), "pad": int(pad["pad"]) if pad != null else -1, "notes": notes_rows(b.client.notes())}

static func _host_events(s: Sess) -> Array:
	var out: Array = []
	for le in s.host.event_log:
		out.append(le.e)
	return out

func _play(s: Sess, limit: float) -> void:
	var last_tick := -1
	while s.g < limit:
		s.g += STEP
		s.net.now = s.g
		s.host.update(s.g)
		if s.host.tick != last_tick:
			last_tick = s.host.tick
			_on_tick(s)
		for b in s.bots:
			b.client.receive(s.g + b.offset)
		for b in s.bots:
			while b.next_frame <= s.g + 1e-9:
				b.next_frame += FRAME
				_bot_frame(s, b)
		if s.deep_checked.size() == s.bots.size():
			var all_ok := true
			for id: String in s.deep_checked:
				all_ok = all_ok and bool(s.deep_checked[id])
			if all_ok:
				return

func test_three_bots_on_a_lossy_link_share_marks_and_notes(t: T) -> void:
	var saved := Session.deck
	Session.deck = Places.FULL
	var s := Sess.new("marks-net")
	var plan := s.host.state.plan
	var out3 := cells_at(plan, 3)
	var out4 := cells_at(plan, 4)
	var out5 := cells_at(plan, 5)
	# p0: two marks at two spots; p1: one; p2: one (the pad may be empty by then), then peels p1's and marks
	# again where it stood.
	s.bots[0].plan_steps = [{"go": out3[0]}, {"mark": true}, {"wait": 1.0}, {"go": out5[0]}, {"mark": true}, {"wait": 1.0}]
	s.bots[1].plan_steps = [{"go": out4[out4.size() - 1]}, {"mark": true}, {"wait": 3.0}]
	s.bots[2].plan_steps = [{"go": out3[out3.size() - 1]}, {"wait": 4.0}, {"mark": true}, {"wait": 1.0}, {"peel": "p1"}, {"wait": 1.0}, {"mark": true}, {"wait": 1.0}]
	var t0 := Time.get_ticks_msec()
	_play(s, 240.0)
	var secs := (Time.get_ticks_msec() - t0) / 1000.0
	Session.deck = saved
	var host_events := _host_events(s)
	t.eq(s.host.state.depth, 4, "the crew rode down from the Annex")
	var placed := of_type(host_events, "markPlaced")
	var peeled := of_type(host_events, "markPeeled")
	var refused := of_type(host_events, "markRefused")
	var notes := of_type(host_events, "note")
	t.check(placed.size() >= Marks.DEFAULT_PAD + 1, "marks placed from the one pad (a peel gave one back): %d" % placed.size())
	t.check(peeled.size() >= 1, "a mark was peeled: %d" % peeled.size())
	var who := {}
	for e in placed:
		who[str(e["playerId"])] = true
	t.check(who.size() >= 3, "every bot placed from the shared pad: %s" % str(who.keys()))
	# Each mark lies where its placing began.
	var starts := {}
	for e: Dictionary in host_events:
		if e["type"] == "markStart":
			starts[str(e["playerId"])] = [float(e["x"]), float(e["z"])]
		elif e["type"] == "markPlaced":
			var m: Dictionary = e["mark"]
			var at: Array = starts.get(str(e["playerId"]), [INF, INF])
			t.check(absf(float(m["x"]) - float(at[0])) < 1e-9 and absf(float(m["z"]) - float(at[1])) < 1e-9, "mark %d lies where its placing began" % int(m["id"]))
	t.eq(s.moved, 0, "ticks a mark moved or changed on the host")
	var triggers := {}
	for n in notes:
		triggers[str(n["trigger"])] = true
	t.check(triggers.has("lobby") and triggers.has("lift") and triggers.has("wake"), "the lobby's, the call's and the wake's notes: %s" % str(triggers.keys()))
	var crew: Array = ["Ana", "Bo", "Cy"]
	var named := 0
	for n in notes:
		if names_someone(int(n["template"])):
			named += 1
			t.check(names_crew(str(n["text"]), crew), "a note names the crew by name: '%s'" % n["text"])
	# Every snapshot's marks and pad on every client: the host's.
	for m: String in s.mismatches.slice(0, 6):
		t.check(false, m)
	t.eq(s.mismatches.size(), 0, "snapshots whose marks or pad differ from the host's")
	t.check(s.compared > 1000, "snapshots compared: %d" % s.compared)
	# The end of the floor: every client's lists, the joiner's too, are the host's.
	if t.check(s.final_done, "the floor's end was reached"):
		t.check(s.final_host["notes"].size() >= 3, "notes on the floor: %d" % s.final_host["notes"].size())
		t.eq(s.final_clients.size(), 4, "clients compared at the floor's end (three bots and the joiner)")
		for id: String in s.final_clients:
			var c: Dictionary = s.final_clients[id]
			t.eq(c["marks"], s.final_host["marks"], "%s's marks at the floor's end" % id)
			t.eq(c["pad"], s.final_host["pad"], "%s's pad at the floor's end" % id)
			t.eq(c["notes"], s.final_host["notes"], "%s's notes at the floor's end" % id)
	# The next floor: nobody has marks or notes.
	for b in s.bots:
		t.check(bool(s.deep_checked.get(b.id, false)), "%s on floor 4: no marks, no pad, no notes" % b.id)
	var lost := 0
	for k: String in s.net.stats:
		lost += (s.net.stats[k] as Transport.LinkStats).lost
	var texts: Array = []
	for n in notes:
		texts.append(str(n["text"]))
	t.note("%.0f s of play in %.1f s: %d placed, %d peeled, %d refused (%s); %d notes (%d naming the crew): %s; %d snapshots compared; %d messages lost" % [
		s.g, secs, placed.size(), peeled.size(), refused.size(), ", ".join(PackedStringArray(refused.map(func(e: Dictionary) -> String: return str(e["reason"])))),
		notes.size(), named, " | ".join(PackedStringArray(texts)), s.compared, lost])
