# PN2 and PN3, the owner's playtest of 20 Nov (sim/run.gd pn_fixes, sim/instrument.gd put_down_tape):
#   PN2 "Interestingly, I can't drop the cassette. It says there's nothing in my hand." The cause: a tape picked up
#       off the floor is carried by the crew's tapes (Instr.CrewMember.carrying), not in the four slots, and G (the
#       inventory's drop) only ever put down the slot in the hand, so with that slot empty it refused "empty"
#       (NOTHING IN YOUR HAND.). With the flag on, G with nothing in the hand puts down the last tape picked up, where
#       the player stands; F picks it up again. With something in the hand, G drops that, as before. Off: the refusal.
#   PN3 "ctrl + walk under desk doesn't work for annex." / "Same for hiding in cabinet." The cause: the game's rooms
#       run the Annex's Temp with Lonely (sim/run.gd _step_lonely), and that branch never stepped the floor's hides
#       (sim/hiding.gd), which only the Stillness branch did: every press of a hide on the Annex did nothing. With the
#       flag on the hides are stepped first, as on a Stillness floor, and a player sitting in one is never the Temp's
#       prey (traits-and-hiding.md section 4: "Lonely | not chased: it has no line"). Off: as before.
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Instr = preload("res://sim/instrument.gd")
const TapeLib = preload("res://sim/tape.gd")
const Inventory = preload("res://sim/inventory.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const M = preload("res://sim/jsmath.gd")
const Places = preload("res://sim/places.gd")
const Hides = preload("res://sim/hides.gd")
const Hiding = preload("res://sim/hiding.gd")
const Seek = preload("res://sim/seek.gd")
const Playroom = preload("res://sim/playroom.gd")
const HostRules = preload("res://net/host_rules.gd")

const DT := 0.05
const IDS: Array[String] = ["p0", "p1"]

static func of_type(evs: Array[Dictionary], ty: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in evs:
		if e["type"] == ty:
			out.append(e)
	return out

## A body on an open cell of the landing's level at least `steps` from the landing.
static func open_body(plan: Floor.FloorPlan, steps: int, k: int = 0) -> Move.Body:
	var dist := Floor.distances_from(plan, plan.landing)
	var n := 0
	for i in dist.size():
		var p := Floor.pos_from_index(plan, i)
		if dist[i] >= steps and p.level == plan.landing.level:
			if n == k:
				return Move.body_at_cell(plan, p)
			n += 1
	return Move.body_at_cell(plan, plan.landing)

## The run with the players placed, the car away, and no resident awake to interfere.
static func placed(s0: Run.RunState, bodies: Dictionary) -> Run.RunState:
	var s := s0.copy()
	s.phase = &"away"
	s.call = null
	s.blink = null
	var players: Array[Run.RunPlayer] = []
	for p in s.players:
		var np := p.copy()
		if bodies.has(p.id):
			np.body = bodies[p.id]
			np.aboard = false
		players.append(np)
	s.players = players
	return s

static func inputs(s: Run.RunState, bodies: Dictionary, extra: Callable = Callable()) -> Array[Run.PlayerInput]:
	var out: Array[Run.PlayerInput] = []
	for p in s.players:
		var b: Move.Body = bodies.get(p.id, p.body)
		var inp := Run.PlayerInput.make(p.id, b, 1.65, 0.0, 0.0, 90.0, 70.0)
		inp.gait = &"creep"
		if extra.is_valid():
			extra.call(inp)
		out.append(inp)
	return out

# ---------------------------------------------------------------------------------------------
# PN2: put a carried tape down.

## [state after picking a tape up off the floor at p0's feet, p0's body, the tape's id].
static func carrying(fixes: bool) -> Array:
	var s := Run.with_inventory(Run.create_run("pn2-tape", IDS, [], false, false, true))
	if fixes:
		s = Run.with_pn_fixes(s)
	var b := open_body(s.plan, 4)
	var bodies := {"p0": b, "p1": open_body(s.plan, 4, 6)}
	s = placed(s, bodies)
	# A crewmate's tape lying where p0 stands (as a catch leaves it).
	var tape := TapeLib.empty_tape("tape-lost", "p1")
	var c := s.crew.copy()
	c.floor = [Instr.FloorTape.make(tape, b)] as Array[Instr.FloorTape]
	s.crew = c
	s = Run.step_run(s, inputs(s, bodies), DT).state
	var r := Run.step_run(s, inputs(s, bodies, func(i: Run.PlayerInput) -> void:
		if i.id == "p0":
			i.pick_up = true), DT)
	return [r.state, b, tape.id, r.events]

func test_a_carried_tape_can_be_put_down(t: T) -> void:
	for fixes: bool in [true, false]:
		var got := carrying(fixes)
		var s: Run.RunState = got[0]
		var b: Move.Body = got[1]
		var picked := of_type(got[3], "tapePickedUp")
		var m := Instr.member(s.crew, "p0")
		t.check(picked.size() == 1 and m.carrying.size() == 1 and s.crew.floor.is_empty(), "fixes %s: F picks the tape up (%d carried, %d on the floor)" % [str(fixes), m.carrying.size(), s.crew.floor.size()])
		var bag := Inventory.bag_of(s.bags, "p0")
		t.check(bag.count(bag.sel) == 0, "fixes %s: and the hand's slot is empty (the tape is not in the four slots)" % str(fixes))
		var bodies := {"p0": b, "p1": (s.players[1] as Run.RunPlayer).body}
		var r := Run.step_run(s, inputs(s, bodies, func(i: Run.PlayerInput) -> void:
			if i.id == "p0":
				i.inv_op = &"drop"), DT)
		var refused := of_type(r.events, "invRefused")
		var dropped := of_type(r.events, "tapeDropped")
		var s2 := r.state
		var m2 := Instr.member(s2.crew, "p0")
		if not fixes:
			t.check(refused.size() == 1 and refused[0]["why"] == "empty" and dropped.is_empty() and m2.carrying.size() == 1,
				"off: G refuses \"empty\" (NOTHING IN YOUR HAND.) and the tape stays carried (%s)" % str(refused))
			continue
		t.check(refused.is_empty() and dropped.size() == 1 and dropped[0]["tapeId"] == got[2] and dropped[0]["playerId"] == "p0",
			"G with an empty hand puts the tape down (%s, refused %s)" % [str(dropped), str(refused)])
		t.check(m2.carrying.is_empty() and s2.crew.floor.size() == 1 and s2.crew.floor[0].tape.id == got[2], "it is on the floor, no longer carried")
		var at := s2.crew.floor[0].at
		t.check(at.level == b.level and M.hypot2(at.x - b.x, at.z - b.z) < 1e-6 and Move.cell_of(s2.plan, at).equals(Move.cell_of(s2.plan, b)),
			"where the player stands, on their cell (%.2f, %.2f)" % [at.x, at.z])
		# F picks it up again.
		var r2 := Run.step_run(s2, inputs(s2, bodies, func(i: Run.PlayerInput) -> void:
			if i.id == "p0":
				i.pick_up = true), DT)
		t.check(of_type(r2.events, "tapePickedUp").size() == 1 and Instr.member(r2.state.crew, "p0").carrying.size() == 1, "and F picks it up again")
		# A second G with nothing carried and nothing in the hand: the refusal, as before.
		var r3 := Run.step_run(s2, inputs(s2, bodies, func(i: Run.PlayerInput) -> void:
			if i.id == "p0":
				i.inv_op = &"drop"), DT)
		var ref3 := of_type(r3.events, "invRefused")
		t.check(ref3.size() == 1 and ref3[0]["why"] == "empty", "nothing carried: still NOTHING IN YOUR HAND.")

func test_something_in_the_hand_is_dropped_first(t: T) -> void:
	var got := carrying(true)
	var s: Run.RunState = got[0]
	var b: Move.Body = got[1]
	var bags := s.bags.duplicate()
	bags["p0"] = Inventory.add(Inventory.bag_of(bags, "p0"), "juice", 1, 4).bag
	s = s.copy()
	s.bags = bags
	var bodies := {"p0": b, "p1": (s.players[1] as Run.RunPlayer).body}
	var r := Run.step_run(s, inputs(s, bodies, func(i: Run.PlayerInput) -> void:
		if i.id == "p0":
			i.inv_op = &"drop"), DT)
	t.check(of_type(r.events, "itemDropped").size() == 1 and of_type(r.events, "tapeDropped").is_empty()
		and Instr.member(r.state.crew, "p0").carrying.size() == 1, "the juice in the hand goes down, the tape stays carried")

# ---------------------------------------------------------------------------------------------
# PN3: the Annex's desks and cabinets under Lonely.

## The game's Annex (floor 3 of the full deck, Lonely on, two players), with the fixes on or off.
static func annex(fixes: bool) -> Run.RunState:
	var rules := HostRules.new(true, 3, Places.FULL, false, false, true, false, false, false, false, false, true)
	rules.pn_fixes = fixes
	return rules.prepare(Run.create_run("pn3-annex", IDS, Places.FULL))

## The first hide of `kind` on the landing's level, or null.
static func hide_of(plan: Floor.FloorPlan, kind: StringName) -> Playroom.Hide:
	for h in Hides.hides_for(plan, plan.seed):
		if h.kind == kind and h.level == plan.landing.level:
			return h
	return null

## p0 at the hide's front, p1 far off; F (`press`) once, then `secs` of standing there. Returns [state, events].
static func try_hide(fixes: bool, kind: StringName) -> Array:
	var s := annex(fixes)
	var h := hide_of(s.plan, kind)
	if h == null:
		return []
	var front := Seek.hide_front_body(s.plan, h)
	var bodies := {"p0": front, "p1": open_body(s.plan, 3)}
	s = placed(s, bodies)
	var evs: Array[Dictionary] = []
	var r := Run.step_run(s, inputs(s, bodies), DT)
	s = r.state
	r = Run.step_run(s, inputs(s, bodies, func(i: Run.PlayerInput) -> void:
		if i.id == "p0":
			i.hide_use = true), DT)
	s = r.state
	evs.append_array(r.events)
	for _k in roundi(2.0 / DT):
		r = Run.step_run(s, inputs(s, bodies), DT)
		s = r.state
		evs.append_array(r.events)
	return [s, evs, h]

func test_the_annex_desk_and_cabinet_hide_you(t: T) -> void:
	var s0 := annex(true)
	t.check(s0.plan.place == Places.ANNEX and Run.resident_of(s0).trait_name == &"lonely", "the game's Annex has the Lonely Temp (%s, %s)" % [s0.plan.place, Run.resident_of(s0).trait_name])
	for kind: StringName in [&"desk", &"cabinet"]:
		for fixes: bool in [true, false]:
			var got := try_hide(fixes, kind)
			t.check(not got.is_empty(), "the Annex has a %s hide on the landing's level" % kind)
			if got.is_empty():
				continue
			var s: Run.RunState = got[0]
			var evs: Array[Dictionary] = got[1]
			var h: Playroom.Hide = got[2]
			var inside := s.hiding != null and Hiding.player_of(s.hiding, "p0") != null and Hiding.player_of(s.hiding, "p0").phase == &"inside"
			if fixes:
				t.check(of_type(evs, "hideStart").size() == 1 and of_type(evs, "hideIn").size() == 1 and inside, "%s: in after the press (%d starts, %d in)" % [kind, of_type(evs, "hideStart").size(), of_type(evs, "hideIn").size()])
				var p0: Run.RunPlayer = s.players[0]
				var ins := Seek.hide_inside_body(s.plan, h)
				t.check(M.hypot2(p0.body.x - ins.x, p0.body.z - ins.z) < 1e-6, "%s: the rules hold them at its inside spot" % kind)
				var input_of := {}
				for i in inputs(s, {"p0": p0.body}):
					input_of[i.id] = i
				var people := Run.lonely_people(s, s.players, input_of)
				t.check(not people[0].prey and people[1].prey, "%s: sitting in it, the Temp may not go for them; their crewmate it may" % kind)
			else:
				t.check(of_type(evs, "hideStart").is_empty() and not inside, "%s off: the press does nothing, as before" % kind)
