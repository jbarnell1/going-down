# Helpers of the day-loop tests (prop_run.gd, prop_day_net.gd): tape fixtures put straight into a run's
# crew (a reading on a member's tape, a tape lying on the floor), and DayRig, a crew driven through
# whole days on the pure rules (sim/run.gd with days on): out onto the landing, the call, the vote, home,
# each to their own bunk holding F, and the next morning. Bodies are placed, not walked: the rules do
# not police speed (the host does).
extends RefCounted

const Run = preload("res://sim/run.gd")
const Move = preload("res://sim/move.gd")
const Floor = preload("res://sim/floor.gd")
const Instr = preload("res://sim/instrument.gd")
const TapeLib = preload("res://sim/tape.gd")
const HostRules = preload("res://net/host_rules.gd")

const DT := 0.05

static func reading(rid: String, player_id: String, entity_id: String, value: float, t: float) -> TapeLib.Reading:
	var r := TapeLib.Reading.new()
	r.id = rid
	r.player_id = player_id
	r.entity_id = entity_id
	r.trait_name = &"stillness"
	r.value = value
	r.duration = 1.0
	r.peak_rate = value
	r.closed_at = t
	return r

## A copy of the run with one more reading (worth `value`) on member `id`'s own tape.
static func give(st: Run.RunState, id: String, value: float, rid: String) -> Run.RunState:
	var s := st.copy()
	var c := st.crew.copy()
	var members: Array[Instr.CrewMember] = []
	for m in st.crew.members:
		if m.id == id:
			var nm := m.copy()
			nm.tape = TapeLib.add_reading(m.tape, reading(rid, id, st.entity_id, value, st.t))
			members.append(nm)
		else:
			members.append(m)
	c.members = members
	s.crew = c
	return s

## give(), counted as recorded: the floor quota's earned (with the quota on) and the day's (with the day
## lock on) rise by `value`, as a reading closing on this floor would make them.
static func record(st: Run.RunState, id: String, value: float, rid: String) -> Run.RunState:
	var s := give(st, id, value, rid)
	if s.quota:
		s.floor_earned += value
	if s.day_lock:
		s.day_earned += value
	return s

## A copy of the run in which player `id` has dropped their own tape where they stand (the instrument's
## "caught" drop): it lies on the floor, and they carry a fresh empty one.
static func drop_own(st: Run.RunState, id: String) -> Run.RunState:
	var s := st.copy()
	var c := st.crew.copy()
	var members: Array[Instr.CrewMember] = []
	var fl: Array[Instr.FloorTape] = st.crew.floor.duplicate()
	for m in st.crew.members:
		if m.id == id and not m.tape.readings.is_empty():
			var nm := m.copy()
			fl.append(Instr.FloorTape.make(m.tape, m.body))
			nm.tape = TapeLib.empty_tape("tape-%d" % c.next_tape, id)
			c.next_tape += 1
			members.append(nm)
		else:
			members.append(m)
	c.members = members
	c.floor = fl
	s.crew = c
	return s

## A copy of the run with a tape (one reading worth `value`, id `tape_id`) lying on the floor at `at`.
static func drop(st: Run.RunState, tape_id: String, value: float, at: Move.Body) -> Run.RunState:
	var s := st.copy()
	var c := st.crew.copy()
	var tp := TapeLib.add_reading(TapeLib.empty_tape(tape_id, "nobody"), reading("%s-r" % tape_id, "nobody", st.entity_id, value, st.t))
	var fl: Array[Instr.FloorTape] = st.crew.floor.duplicate()
	fl.append(Instr.FloorTape.make(tp, at))
	c.floor = fl
	s.crew = c
	return s

## Every tape with readings held by a member (own and carried): {tape id: member id}.
static func held(st: Run.RunState) -> Dictionary:
	var out := {}
	for m in st.crew.members:
		for tp: TapeLib.Tape in [m.tape] + m.carrying:
			if not tp.readings.is_empty():
				out[tp.id] = m.id
	return out

## The ids of the tapes lying on the floor.
static func on_floor(st: Run.RunState) -> Dictionary:
	var out := {}
	for f in st.crew.floor:
		out[f.tape.id] = true
	return out

## Every tape id in the crew, empty or not, and on the floor.
static func all_tape_ids(st: Run.RunState) -> Array[String]:
	var out: Array[String] = []
	for m in st.crew.members:
		out.append(m.tape.id)
		for tp in m.carrying:
			out.append(tp.id)
	for f in st.crew.floor:
		out.append(f.tape.id)
	return out

## A crew driven through days on the pure rules.
class DayRig:
	var st: Run.RunState
	var ids: Array[String] = []
	var bodies := {}
	## Where each player goes when the doors open for boarding: "bank", "down" or "out" (stays on the landing).
	var vote := {}
	## At home: walk to the bunk and hold F (else stand where they are, F up).
	var to_bed := {}
	## F held, overriding the above (id -> bool).
	var use := {}
	## Players who press the call when the car is away (the first player by default).
	var caller := ""
	var events: Array[Dictionary] = []
	var ticks := 0

	func _init(seed: String, ids_: Array[String], days: bool = true, deck: Array = []) -> void:
		ids = ids_
		st = Run.create_run(seed, ids, deck, days)
		st = st.copy()
		st.orderly = HostRules.parked_orderly(st)
		caller = ids[0]
		for p in st.players:
			bodies[p.id] = p.body
			vote[p.id] = "bank"
			to_bed[p.id] = true

	func index_of(id: String) -> int:
		return ids.find(id)

	func inputs() -> Array[Run.PlayerInput]:
		var out: Array[Run.PlayerInput] = []
		var home := Run.at_home(st)
		for id in ids:
			var b: Move.Body = bodies[id]
			var call := false
			var u := false
			var i := index_of(id)
			if not home:
				match st.phase:
					&"unloading", &"away", &"coming":
						b = Run.car_body(st.car, -1.0, -0.5 + 0.5 * (i % 3))
						call = st.phase == &"away" and id == caller
					&"boarding":
						match String(vote[id]):
							"bank":
								b = Run.car_body(st.car, 1.0 + 0.6 * (i % 4), -1.0)
							"down":
								b = Run.car_body(st.car, 1.0 + 0.6 * (i % 4), 1.0)
							_:
								b = Run.car_body(st.car, -1.0, -0.5 + 0.5 * (i % 3))
			elif st.phase != &"arriving" and bool(to_bed[id]):
				b = Run.bunk_body(st.plan, ids, id)
				u = true
			bodies[id] = b
			var inp := Run.PlayerInput.make(id, b, 1.65, 0.0, 0.0, 90.0, 70.0)
			inp.call = call
			inp.use = bool(use.get(id, u))
			out.append(inp)
		return out

	func step() -> Run.RunStep:
		var r := Run.step_run(st, inputs(), DT)
		ticks += 1
		for e in r.events:
			match String(e["type"]):
				"rodeDown", "rodeUp", "newDay":
					var bs: Dictionary = e["bodies"]
					for id: String in bs:
						bodies[id] = bs[id]
				"doorsClosed":
					var pushed: Dictionary = e["pushedOut"]
					for id: String in pushed:
						bodies[id] = pushed[id]
		events.append_array(r.events)
		st = r.state
		for e in r.events:
			if e["type"] == "newDay" or e["type"] == "rodeDown":
				# Every floor's and every day's resident parked too, as the host does with the resident off
				# (net/host_rules.gd step): a crew that rides down is never caught by the next floor's.
				st = st.copy()
				st.orderly = HostRules.parked_orderly(st)
		return r

	## Steps until `done` (RunState -> bool) is true, at most `seconds`. False if it never was.
	func until(done: Callable, seconds: float) -> bool:
		for _k in roundi(seconds / DT):
			if done.call(st):
				return true
			step()
		return done.call(st)

	## Steps until an event of this type (returns it), at most `seconds`; {} if none came.
	func until_event(type: String, seconds: float) -> Dictionary:
		for _k in roundi(seconds / DT):
			var r := step()
			for e in r.events:
				if e["type"] == type:
					return e
		return {}
