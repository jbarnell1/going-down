# The game's own rules around the run, applied by the host. Port of src/game/runHost.ts (HostRules,
# startSpot, startBody, parkedOrderly). Work-arounds for gaps in the run's logic, kept visible here:
#  - create_run always starts at depth 1. A depth above 1 swaps in floor N's plan, car and Orderly.
#  - The run's deck (sim/places.gd): Clinic only unless one is given; the game (server/room.gd,
#    net/local_room.gd) gives Places.FULL. prepare() puts it on the run and makes floor N with it.
#  - run.gd wipes the run when its last active player is caught. The design says a catch is a wipe
#    only when the car is gone and nobody can call it; while the car is here or coming, a catch is
#    the "YOU WENT DOWN" placeholder and the player must still be able to finish the run. So when a
#    catch would wipe and the car was not 'away', the tick is re-run without the caught players to
#    recover the run's own phase, call and blink; the Orderly and crew are kept from the real tick
#    (the dropped tape, the dormant Orderly), and the players are put back on their feet ('ok').
#  - entity off: the run always has an Orderly. The host parks it, dormant for ever, where it starts.
#  - A test may press the call button "from the landing" wherever the player stands (force_call).
# Typed and immutable like godot/sim: a step never edits the state it was given.
extends RefCounted

const Run = preload("res://sim/run.gd")
const Entity = preload("res://sim/entity.gd")
const Places = preload("res://sim/places.gd")
const Move = preload("res://sim/move.gd")
const Instr = preload("res://sim/instrument.gd")

## Where a player stands alone in the car at the start: the middle, so the doorway is straight ahead.
const START_U := Run.CAR_DEPTH / 2.0

## Catches turned from a wipe into the placeholder (see the header). (TypeScript: softCatches)
var soft_catches := 0
## Players put back on their feet since the glue last asked.
var revived: Array[String] = []
var _forced_id := ""
var _forced_body: Move.Body = null
var _entity_on: bool
var _depth: int
## The places the run's floors are drawn from.
var deck: Array[StringName]

func _init(entity_on: bool, depth: int, deck_: Array = []) -> void:
	_entity_on = entity_on
	_depth = depth
	deck = Run.deck_of(deck_)

## Where player `i` of `n` stands in the car at the start (car-local u, v).
static func start_spot(i: int, n: int) -> PackedFloat64Array:
	if n <= 1:
		return PackedFloat64Array([START_U, 0.0])
	var spots: Array[PackedFloat64Array] = [
		PackedFloat64Array([1.3, -1.0]), PackedFloat64Array([1.3, 1.0]),
		PackedFloat64Array([2.7, -1.0]), PackedFloat64Array([2.7, 1.0]),
	]
	return spots[i % spots.size()]

static func start_body(car: Run.CarGeometry, i: int, n: int) -> Move.Body:
	var uv := start_spot(i, n)
	return Run.car_body(car, uv[0], uv[1])

## A dormant Orderly that never wakes, standing where the floor's Orderly would start.
static func parked_orderly(state: Run.RunState) -> Entity.OrderlyState:
	var o := Entity.create_orderly(state.plan)
	o.mode = &"dormant"
	o.dormant_left = INF
	return o

## The first state of a run (create_run's, adjusted).
func prepare(s0: Run.RunState) -> Run.RunState:
	var s := s0
	if s.deck != deck:
		s = s.copy()
		s.deck = deck
	if _depth > 1:
		var plan := Places.generate(s.seed, _depth, deck)
		s = s.copy()
		s.depth = _depth
		s.plan = plan
		s.car = Run.car_geometry(plan)
		s.orderly = Places.create_resident(plan)
		s.entity_id = Places.entity_id(plan.place, _depth)
	var n := s.players.size()
	var bodies := {}
	for i in n:
		bodies[s.players[i].id] = start_body(s.car, i, n)
	s = s.copy()
	var players: Array[Run.RunPlayer] = []
	for p in s.players:
		var np := p.copy()
		if bodies.has(p.id):
			np.body = bodies[p.id]
		players.append(np)
	s.players = players
	if _depth > 1:
		var c := s.crew.copy()
		var members: Array[Instr.CrewMember] = []
		for m in s.crew.members:
			var nm := m.copy()
			nm.body = bodies[m.id] if bodies.has(m.id) else null
			members.append(nm)
		c.members = members
		s = s.copy()
		s.crew = c
	if not _entity_on:
		s = s.copy()
		s.orderly = parked_orderly(s)
	return s

## Tests: the next tick presses the call button for `id` from `body`.
func force_call(id: String, body: Move.Body) -> void:
	_forced_id = id
	_forced_body = body

## One tick of the run, with the rules above.
func step(before: Run.RunState, raw: Array[Run.PlayerInput], dt: float) -> Run.RunStep:
	var inputs := raw
	if _forced_body != null:
		var fid := _forced_id
		var fbody := _forced_body
		_forced_id = ""
		_forced_body = null
		inputs = []
		for i in raw:
			if i.id == fid:
				var ni := _copy_input(i)
				ni.body = Move.Body.make(fbody.x, fbody.z, fbody.level, fbody.y)
				ni.call = true
				inputs.append(ni)
			else:
				inputs.append(i)
	var r := Run.step_run(before, inputs, dt)
	var events := r.events
	var caught := {}
	var wiped := false
	for e in events:
		if e["type"] == "caught":
			caught[str(e["playerId"])] = true
		elif e["type"] == "wiped":
			wiped = true
	if not caught.is_empty() and wiped and before.phase != &"away":
		# Not a wipe by the design's rule: the car is here or coming. See the header.
		var kept: Array[Run.PlayerInput] = []
		for i in inputs:
			if not caught.has(i.id):
				kept.append(i)
		var alt := Run.step_run(before, kept, dt)
		var players: Array[Run.RunPlayer] = []
		for p in r.state.players:
			if caught.has(p.id):
				var np := p.copy()
				np.status = &"ok"
				players.append(np)
			else:
				players.append(p)
		var st := alt.state.copy()
		st.orderly = r.state.orderly
		st.crew = r.state.crew
		st.players = players
		st.summary = null
		var kept_events: Array[Dictionary] = []
		for e in events:
			if e["type"] != "wiped":
				kept_events.append(e)
		events = kept_events
		r = Run.RunStep.new()
		r.state = st
		r.events = events
		soft_catches += 1
		for id: String in caught:
			revived.append(id)
	var state := r.state
	if not _entity_on:
		for e in events:
			if e["type"] == "rodeDown":
				state = state.copy()
				state.orderly = parked_orderly(state)
				break
	var out := Run.RunStep.new()
	out.state = state
	out.events = events
	return out

static func _copy_input(i: Run.PlayerInput) -> Run.PlayerInput:
	var n := Run.PlayerInput.make(i.id, i.body, i.eye, i.yaw, i.pitch, i.h_fov_deg, i.v_fov_deg)
	n.call = i.call
	n.hold_doors = i.hold_doors
	n.raised = i.raised
	n.pick_up = i.pick_up
	n.blind = i.blind
	return n
