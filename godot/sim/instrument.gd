# The instrument: how the crew earns. Pure, deterministic logic; no rendering or audio.
# Port of src/sim/instrument.ts.
#
# Pay comes from holding the instrument near an entity. It works by closeness, not by aim, and
# holding it is not looking (nothing here touches a PlayerView). It only records the scary part:
# a trait records only while the entity is doing the thing its safety rule protects you from. For
# the Orderly's Stillness that is "while it moves", which is only while nobody is looking at it. For
# the Temp's Lonely (sim/lonely.gd, T19c) it is "while it chases", and only on the instrument of the
# player it chases: the run says so (EntityTick.acting and holders), as it does for Hearing.
#
# Per tick, AFTER the entity has been stepped, the game calls step_crew once. Each raised
# instrument decides its needle and grows its current reading; a reading closes after a short gap
# without recording and goes onto its holder's tape. A caught player drops every tape they hold.
#
# Choices made here:
#  - Distance is the straight 3D distance between the holder's feet and the entity's feet after
#    the tick. Same level: that distance alone. Different levels: also needs line of sight from
#    the instrument (INSTRUMENT_HEIGHT) to the entity's chest.
#  - "Moved this tick": its position changed, or its catching wind-up advanced (started,
#    progressed or completed) this tick, i.e. it was in or finishing a wind-up and not held.
#  - Raised with no entity within SENSE_RANGE (3D distance, walls ignored): needle 'idle'.
#    Lowered, or holder inactive: 'off'.
#  - The repeat factor is read live each tick from the crew's memory, so two players recording the
#    same entity at once both get the same factor; each reading that closes steps it down.
#  - Readings shorter than READING_MIN_TIME are discarded silently and do not step the factor.
#  - On a catch, the victim's open reading closes at once (onto their tape) before the drop, and
#    their instrument is lowered. Empty tapes are not dropped.
extends RefCounted

const Entity = preload("res://sim/entity.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Sight = preload("res://sim/sight.gd")
const TapeLib = preload("res://sim/tape.gd")
const M = preload("res://sim/jsmath.gd")
const Settings = preload("res://sim/settings.gd")

# ---------------------------------------------------------------------------------------------
# Tuning.

## Walking speed cap (m/s) while the instrument is raised: you cannot sprint away while recording.
const RAISED_SPEED_CAP := 2.2
## Recording range (metres, straight line) from the holder to the entity.
const RECORD_RANGE := 9.0
## Within this distance (metres, straight line, walls ignored) the needle wakes to 'dormant'.
const SENSE_RANGE := 16.0
## At or inside this distance (metres) the rate is at its maximum.
const NEAR_DISTANCE := 1.5
## Pay per second at the edge of RECORD_RANGE.
const RATE_EDGE := 8.0
## Pay per second at NEAR_DISTANCE or closer.
const RATE_NEAR := 140.0
## Shape of the rate curve between edge and near: 2 means most of the gain is in the last metres.
const RATE_CURVE := 3.0
## A reading closes once recording has stopped for this long (seconds).
const READING_GAP := 1.5
## A closed reading counts only if it recorded for at least this long (seconds).
const READING_MIN_TIME := 0.5
## Repeat factors by how many readings of this entity and trait the crew already closed this run; the last repeats.
const REPEAT_FACTORS: Array[float] = [1.0, 0.5, 0.2]
## Tick rate (Hz) of a raised instrument with no reading open.
const TICK_REST_HZ := 1.0
## Tick rate (Hz) the moment a reading opens...
const TICK_MIN_HZ := 3.0
## ...rising toward this as the reading grows.
const TICK_MAX_HZ := 14.0
## Reading value at which the ticking has covered about 63% of the way from min to max.
const TICK_SCALE := 120.0
## Loudness (0..1) of the rest tick.
const LOUDNESS_REST := 0.1
## Loudness when a reading opens...
const LOUDNESS_MIN := 0.45
## ...rising toward this. The ticking is loud on purpose.
const LOUDNESS_MAX := 1.0
## Reach for picking up a tape (metres, straight line from feet to the tape).
const PICKUP_REACH := 1.3
## Height above the feet at which the instrument is held (for line of sight across levels).
const INSTRUMENT_HEIGHT := 1.2
## Height above the entity's feet that line of sight across levels aims at.
const ENTITY_CHEST := 1.7
## What the slip says, per trait. Printed the first time a trait is recorded in a run.
const SLIP_TEXT := {&"stillness": "recorded while: subject moving", &"hearing": "recorded while: subject searching",
	&"lonely": "recorded while: subject pursuing. operator alone.", &"listening": "recorded while: subject coming to a sound.",
	&"rigger": "recorded while: contact under load."}

const EPS := 1e-9

# ---------------------------------------------------------------------------------------------
# Types.

# Needle: 'off' | 'idle' | 'dormant' | 'recording' | 'contaminated' ('idle': raised, nothing near;
# 'contaminated' is reserved for later and never produced).

## Immutable: changes make a new one.
class OpenReading:
	var entity_id: String  # TypeScript: entityId
	var trait_name: StringName  # TypeScript: trait
	var value: float
	## Seconds of recording so far.
	var duration: float
	## Seconds since the last recording tick (0 on a recording tick).
	var quiet: float
	var peak_rate: float  # TypeScript: peakRate

	func copy() -> OpenReading:
		var o := OpenReading.new()
		o.entity_id = entity_id
		o.trait_name = trait_name
		o.value = value
		o.duration = duration
		o.quiet = quiet
		o.peak_rate = peak_rate
		return o

class Instrument:
	var raised: bool = false
	var needle: StringName = &"off"
	var current: OpenReading = null
	## Pay per second added this tick (after the repeat factor); 0 unless recording.
	var rate: float = 0.0
	## The repeat factor applied this tick (1 when not recording).
	var factor: float = 1.0
	## Distance to the nearest entity this tick, or null if none was given.
	var distance: Variant = null
	## Ticking, for sound and for entities that hear: ticks per second and loudness 0..1.
	var tick_hz: float = 0.0  # TypeScript: tickHz
	var loudness: float = 0.0
	## Fractional tick carried between steps.
	var tick_phase: float = 0.0  # TypeScript: tickPhase
	## Audible ticks that fell within this step.
	var ticks: int = 0
	## Everything ever added to any reading by this instrument (kept or discarded). Never decreases.
	var recorded: float = 0.0

	func copy() -> Instrument:
		var i := Instrument.new()
		i.raised = raised
		i.needle = needle
		i.current = current
		i.rate = rate
		i.factor = factor
		i.distance = distance
		i.tick_hz = tick_hz
		i.loudness = loudness
		i.tick_phase = tick_phase
		i.ticks = ticks
		i.recorded = recorded
		return i

## One entity's tick, as the instrument needs it.
class EntityTick:
	var id: String
	var trait_name: StringName
	var prev: Entity.OrderlyState
	var next: Entity.OrderlyState
	var events: Array[Dictionary] = []
	## Hearing (the Playroom's Minder, sim/seek.gd): its rule is being tested this tick (a count, after
	## the 6 s). The run says so; nothing here can tell from the poses. Unused by Stillness.
	var acting: bool = false
	## The holders who may record it this tick ({player id: true}), or null for every holder. The run
	## gates Hearing per player (docs/floors/playarea.md section 11) and Lonely to the chased player
	## (sim/lonely.gd). Stillness leaves it null.
	var holders: Variant = null
	## The Arboretum's Groundskeeper (sim/hearing.gd): each holder's pay multiplier this tick ({player id:
	## number}; a holder it does not name is paid as usual), or null for none: the lean pays by closeness to
	## its reach. Every other resident leaves it null, and the rate is then computed exactly as before.
	var pay: Variant = null
	## A Ward limb in world space, or empty for the normal body-based distance.
	var limb := PackedVector3Array()

	static func make(id_: String, trait_: StringName, prev_: Entity.OrderlyState, next_: Entity.OrderlyState, events_: Array[Dictionary]) -> EntityTick:
		var e := EntityTick.new()
		e.id = id_
		e.trait_name = trait_
		e.prev = prev_
		e.next = next_
		e.events = events_
		return e

## A player as the crew needs them (TypeScript: CrewPlayer; Holder is body + active).
class CrewPlayer:
	var id: String
	var body: Move.Body
	var active: bool

	static func make(id_: String, body_: Move.Body, active_: bool) -> CrewPlayer:
		var p := CrewPlayer.new()
		p.id = id_
		p.body = body_
		p.active = active_
		return p

class CrewMember:
	var id: String
	## Where they were at the last step_crew (null before the first).
	var body: Move.Body = null
	var active: bool = true
	var instrument: Instrument
	## Their own tape: what their instrument records onto.
	var tape: TapeLib.Tape
	## Other tapes they picked up.
	var carrying: Array[TapeLib.Tape] = []

	func copy() -> CrewMember:
		var m := CrewMember.new()
		m.id = id
		m.body = body
		m.active = active
		m.instrument = instrument
		m.tape = tape
		m.carrying = carrying.duplicate()
		return m

class FloorTape:
	var tape: TapeLib.Tape
	var at: Move.Body

	static func make(tape_: TapeLib.Tape, at_: Move.Body) -> FloorTape:
		var f := FloorTape.new()
		f.tape = tape_
		f.at = at_
		return f

class CrewState:
	var t: float = 0.0
	var members: Array[CrewMember] = []
	var floor: Array[FloorTape] = []
	## Traits that already printed a slip this run (once per trait for the whole crew).
	var slips_printed: Array[StringName] = []  # TypeScript: slipsPrinted
	## Closed readings per "entityId/trait" this run.
	var repeats: Dictionary = {}
	var next_tape: int = 1  # TypeScript: nextTape
	var next_reading: int = 1  # TypeScript: nextReading

	func copy() -> CrewState:
		var c := CrewState.new()
		c.t = t
		c.members = members.duplicate()
		c.floor = floor.duplicate()
		c.slips_printed = slips_printed.duplicate()
		c.repeats = repeats.duplicate()
		c.next_tape = next_tape
		c.next_reading = next_reading
		return c

# CrewEvent: Dictionaries with the TypeScript shapes:
#   {type: "slip", t, playerId, entityId, trait, text}
#   {type: "readingClosed", t, playerId, tapeId, reading (a TapeLib.Reading), value}
#   {type: "tapeDropped", t, playerId, tapeId, at (a Move.Body)}
#   {type: "tapePickedUp", t, playerId, tapeId}

# ---------------------------------------------------------------------------------------------
# Helpers.

## The walking speed the game should allow: capped while the instrument is raised.
static func max_walk_speed(raised: bool, base_speed: float) -> float:
	return minf(base_speed, RAISED_SPEED_CAP) if raised else base_speed

## Pay per second at a distance, before the repeat factor. 0 outside RECORD_RANGE.
## TypeScript writes `k ** RATE_CURVE`; JavaScript's ** calls the platform's pow, which no GDScript
## code can reproduce bit for bit (see jsmath.gd and godot/README.md), so this is fdlibm's pow.
## `tuning` (live settings; null: none): the host's record.reach (the range) and record.rate (the rate up close).
static func rate_at(distance: float, tuning: Settings.Values = null) -> float:
	var reach := Settings.f(tuning, &"record.reach", RECORD_RANGE)
	if distance > reach + EPS:
		return 0.0
	var k := maxf(0.0, minf(1.0, (reach - distance) / (reach - NEAR_DISTANCE)))
	return RATE_EDGE + (Settings.f(tuning, &"record.rate", RATE_NEAR) - RATE_EDGE) * M.pow_js(k, RATE_CURVE)

## The repeat factor after `closed` readings of the same entity and trait.
static func repeat_factor(closed: int) -> float:
	var i := maxi(0, mini(REPEAT_FACTORS.size() - 1, closed))
	return REPEAT_FACTORS[i]

static func _repeat_key(entity_id: String, trait_name: StringName) -> String:
	return "%s/%s" % [entity_id, trait_name]

## Straight 3D distance between two bodies' feet.
static func feet_distance(a: Move.Body, b: Move.Body) -> float:
	return M.hypot3(a.x - b.x, a.y - b.y, a.z - b.z)

## Stillness: the Orderly moved this tick, or its wind-up advanced this tick. A relocation is not a move.
static func stillness_acting(prev: Entity.OrderlyState, next: Entity.OrderlyState) -> bool:
	if next.relocated:
		return false
	var a := prev.body
	var b := next.body
	if a.x != b.x or a.z != b.z or a.y != b.y or a.level != b.level:
		return true
	if next.held:
		return false
	return next.mode == &"windUp" or (prev.mode == &"windUp" and next.mode == &"dormant")

## Whether the trait's dangerous behaviour is happening this tick. Never on the tick it relocated (it left
## one place and arrived at another: sim/relocate.gd) nor while it stands after arriving, whatever its trait:
## the instrument never records a relocation, and an open reading on the old spot closes by the usual quiet.
static func trait_acting(e: EntityTick) -> bool:
	if e.next.relocated or e.next.stand_left > EPS:
		return false
	match e.trait_name:
		&"stillness":
			return stillness_acting(e.prev, e.next)
		&"hearing", &"lonely", &"listening", &"rigger":
			return e.acting
	return false

## Whether this holder may record the entity this tick (EntityTick.holders).
static func may_record(e: EntityTick, holder_id: String) -> bool:
	return e.holders == null or (e.holders as Dictionary).has(holder_id)

## In recording range: within RECORD_RANGE, and with line of sight if on different levels.
static func in_record_range(plan: Floor.FloorPlan, holder: Move.Body, entity: Move.Body, distance: float, tuning: Settings.Values = null) -> bool:
	if distance > Settings.f(tuning, &"record.reach", RECORD_RANGE) + EPS:
		return false
	if holder.level == entity.level:
		return true
	return Sight.has_line_of_sight(plan,
		Sight.Point3.make(holder.x, holder.y + INSTRUMENT_HEIGHT, holder.z, holder.level),
		Sight.Point3.make(entity.x, entity.y + ENTITY_CHEST, entity.z, entity.level))

static func create_instrument() -> Instrument:
	return Instrument.new()

# ---------------------------------------------------------------------------------------------
# One instrument.

class InstrumentStep:
	var instrument: Instrument
	## Set on a tick that recorded: which entity and trait (TypeScript: recordedFrom, or null).
	var recorded_entity: String = ""
	var recorded_trait: StringName = &""
	var recorded := false
	## Readings that closed this tick (any length; the crew decides whether they count).
	var closed: Array[OpenReading] = []

## Advances one instrument by dt. Call after the entities have been stepped for this tick.
## `factor_for(entity_id, trait)` gives the current repeat factor for an entity and trait. `holder_id`:
## whose instrument it is (an entity tick may name the holders who can record it).
static func step_instrument(plan: Floor.FloorPlan, prev: Instrument, holder_body: Move.Body, holder_active: bool, entities: Array[EntityTick], factor_for: Callable, dt: float, holder_id: String = "", tuning: Settings.Values = null) -> InstrumentStep:
	var inst := prev.copy()
	inst.rate = 0.0
	inst.factor = 1.0
	inst.ticks = 0
	inst.distance = null
	var out := InstrumentStep.new()
	out.instrument = inst
	var live := inst.raised and holder_active

	var best: EntityTick = null
	var best_d := 0.0
	var sensed := false
	for e in entities:
		var d := feet_distance(holder_body, e.next.body)
		if not e.limb.is_empty():
			d = INF
			var held_at := Vector3(holder_body.x, holder_body.y + INSTRUMENT_HEIGHT, holder_body.z)
			for index in range(1, e.limb.size()):
				var nearest := Geometry3D.get_closest_point_to_segment(held_at, e.limb[index - 1], e.limb[index])
				d = minf(d, held_at.distance_to(nearest))
		if inst.distance == null or d < float(inst.distance):
			inst.distance = d
		if d <= SENSE_RANGE + EPS:
			sensed = true
		if not live:
			continue
		if trait_acting(e) and may_record(e, holder_id) and (d <= Settings.f(tuning, &"record.reach", RECORD_RANGE) + EPS if not e.limb.is_empty() else in_record_range(plan, holder_body, e.next.body, d, tuning)) and (best == null or d < best_d):
			best = e
			best_d = d

	var cur := inst.current
	if best != null:
		if cur != null and (cur.entity_id != best.id or cur.trait_name != best.trait_name):
			out.closed.append(cur)
			cur = null
		var factor: float = factor_for.call(best.id, best.trait_name)
		var rate := rate_at(best_d, tuning) * factor
		if best.pay != null:
			rate *= float((best.pay as Dictionary).get(holder_id, 1.0))
		var add := rate * dt
		if cur != null:
			var n := cur.copy()
			n.value = cur.value + add
			n.duration = cur.duration + dt
			n.quiet = 0.0
			n.peak_rate = maxf(cur.peak_rate, rate)
			cur = n
		else:
			cur = OpenReading.new()
			cur.entity_id = best.id
			cur.trait_name = best.trait_name
			cur.value = add
			cur.duration = dt
			cur.quiet = 0.0
			cur.peak_rate = rate
		inst.rate = rate
		inst.factor = factor
		inst.recorded = prev.recorded + add
		inst.needle = &"recording"
		out.recorded = true
		out.recorded_entity = best.id
		out.recorded_trait = best.trait_name
	else:
		if cur != null:
			var quiet := cur.quiet + dt
			if quiet >= READING_GAP - EPS:
				out.closed.append(cur)
				cur = null
			else:
				cur = cur.copy()
				cur.quiet = quiet
		inst.needle = &"off" if not live else (&"dormant" if sensed else &"idle")
	inst.current = cur
	_set_ticking(inst, live, dt)
	return out

static func _set_ticking(inst: Instrument, live: bool, dt: float) -> void:
	if inst.current != null:
		var k := 1.0 - M.exp_js(-inst.current.value / TICK_SCALE)
		inst.tick_hz = TICK_MIN_HZ + (TICK_MAX_HZ - TICK_MIN_HZ) * k
		inst.loudness = LOUDNESS_MIN + (LOUDNESS_MAX - LOUDNESS_MIN) * k
	elif live:
		inst.tick_hz = TICK_REST_HZ
		inst.loudness = LOUDNESS_REST
	else:
		inst.tick_hz = 0.0
		inst.loudness = 0.0
		inst.tick_phase = 0.0
	var phase := inst.tick_phase + inst.tick_hz * dt
	inst.ticks = int(floor(phase + EPS))
	inst.tick_phase = maxf(0.0, phase - inst.ticks)

# ---------------------------------------------------------------------------------------------
# The crew.

## A fresh crew for a run: instruments lowered, one empty tape each (ids tape-1, tape-2, ...).
static func create_crew(player_ids: Array[String]) -> CrewState:
	var c := CrewState.new()
	for i in player_ids.size():
		var m := CrewMember.new()
		m.id = player_ids[i]
		m.body = null
		m.active = true
		m.instrument = create_instrument()
		m.tape = TapeLib.empty_tape("tape-%d" % (i + 1), player_ids[i])
		c.members.append(m)
	c.next_tape = player_ids.size() + 1
	c.next_reading = 1
	return c

## Raises or lowers a player's instrument. Unknown players: unchanged.
static func set_raised(crew: CrewState, player_id: String, raised: bool) -> CrewState:
	var found := false
	for m in crew.members:
		if m.id == player_id:
			found = true
	if not found:
		return crew
	var c := crew.copy()
	for i in c.members.size():
		if c.members[i].id == player_id:
			var m := c.members[i].copy()
			m.instrument = m.instrument.copy()
			m.instrument.raised = raised
			c.members[i] = m
	return c

static func member(crew: CrewState, player_id: String) -> CrewMember:
	for m in crew.members:
		if m.id == player_id:
			return m
	return null

class CrewStep:
	var crew: CrewState
	var events: Array[Dictionary] = []

## The running parts of a step_crew call (TypeScript keeps them in closure variables).
class _CrewTick:
	var t: float
	var events: Array[Dictionary] = []
	var repeats: Dictionary
	var next_reading: int

static func _finish(ctx: _CrewTick, m: CrewMember, open: OpenReading) -> CrewMember:
	if open.duration < READING_MIN_TIME - EPS:
		return m
	var reading := TapeLib.Reading.new()
	reading.id = "reading-%d" % ctx.next_reading
	ctx.next_reading += 1
	reading.player_id = m.id
	reading.entity_id = open.entity_id
	reading.trait_name = open.trait_name
	reading.value = open.value
	reading.duration = open.duration
	reading.peak_rate = open.peak_rate
	reading.closed_at = ctx.t
	var key := _repeat_key(open.entity_id, open.trait_name)
	ctx.repeats[key] = int(ctx.repeats.get(key, 0)) + 1
	ctx.events.append({"type": "readingClosed", "t": ctx.t, "playerId": m.id, "tapeId": m.tape.id, "reading": reading, "value": reading.value})
	var out := m.copy()
	out.tape = TapeLib.add_reading(m.tape, reading)
	return out

## Advances the whole crew by one tick, after the entities have been stepped. Steps every
## instrument, writes closed readings to tapes, prints slips, and drops the tapes of anyone the
## entities caught this tick. Players missing from `players` count as inactive where they last were.
static func step_crew(plan: Floor.FloorPlan, crew: CrewState, players: Array[CrewPlayer], entities: Array[EntityTick], dt: float, tuning: Settings.Values = null) -> CrewStep:
	var ctx := _CrewTick.new()
	ctx.t = crew.t + dt
	ctx.repeats = crew.repeats.duplicate()
	ctx.next_reading = crew.next_reading
	var slips: Array[StringName] = crew.slips_printed.duplicate()
	var floor_tapes: Array[FloorTape] = crew.floor.duplicate()
	var next_tape := crew.next_tape
	# Factors as they stood at the start of the tick: everyone recording this tick gets the same one.
	var start_repeats := crew.repeats
	var factor_for := func(entity_id: String, trait_name: StringName) -> float:
		return repeat_factor(int(start_repeats.get(_repeat_key(entity_id, trait_name), 0)))

	var members: Array[CrewMember] = []
	for old in crew.members:
		var p: CrewPlayer = null
		for q in players:
			if q.id == old.id:
				p = q
				break
		var m := old.copy()
		m.body = p.body if p != null else old.body
		m.active = p.active if p != null else false
		if m.body == null:
			members.append(m)
			continue
		var r := step_instrument(plan, m.instrument, m.body, m.active, entities, factor_for, dt, m.id, tuning)
		m.instrument = r.instrument
		if r.recorded and not slips.has(r.recorded_trait):
			slips.append(r.recorded_trait)
			ctx.events.append({"type": "slip", "t": ctx.t, "playerId": m.id, "entityId": r.recorded_entity, "trait": String(r.recorded_trait), "text": SLIP_TEXT[r.recorded_trait]})
		for c in r.closed:
			m = _finish(ctx, m, c)
		members.append(m)

	for e in entities:
		for ev in e.events:
			if ev["type"] != "caught":
				continue
			var i := -1
			for k in members.size():
				if members[k].id == ev["playerId"]:
					i = k
					break
			if i < 0:
				continue
			var m := members[i].copy()
			var open := m.instrument.current
			m.instrument = m.instrument.copy()
			m.instrument.current = null
			m.instrument.raised = false
			m.instrument.needle = &"off"
			m.instrument.rate = 0.0
			m.instrument.tick_hz = 0.0
			m.instrument.loudness = 0.0
			m.instrument.tick_phase = 0.0
			if open != null:
				m = _finish(ctx, m, open)
			var at := m.body
			if at != null:
				var held: Array[TapeLib.Tape] = [m.tape]
				held.append_array(m.carrying)
				for tape in held:
					if tape.readings.is_empty():
						continue
					floor_tapes.append(FloorTape.make(tape, at))
					ctx.events.append({"type": "tapeDropped", "t": ctx.t, "playerId": m.id, "tapeId": tape.id, "at": at})
				m = m.copy()
				m.tape = TapeLib.empty_tape("tape-%d" % next_tape, m.id)
				next_tape += 1
				m.carrying = []
			members[i] = m

	var out := CrewStep.new()
	var c := CrewState.new()
	c.t = ctx.t
	c.members = members
	c.floor = floor_tapes
	c.slips_printed = slips
	c.repeats = ctx.repeats
	c.next_tape = next_tape
	c.next_reading = ctx.next_reading
	out.crew = c
	out.events = ctx.events
	return out

class PickUp:
	var crew: CrewState
	var ok: bool = false
	var event: Variant = null  # a Dictionary or null
	## 'ok' | 'noPlayer' | 'inactive' | 'noTape' | 'tooFar'
	var reason: StringName

	static func make(crew_: CrewState, ok_: bool, event_: Variant, reason_: StringName) -> PickUp:
		var p := PickUp.new()
		p.crew = crew_
		p.ok = ok_
		p.event = event_
		p.reason = reason_
		return p

## An active player picks up a tape lying on the floor, if it is within PICKUP_REACH of where they
## stood at the last step_crew. They can carry any number.
static func pick_up_tape(crew: CrewState, player_id: String, tape_id: String) -> PickUp:
	var m := member(crew, player_id)
	if m == null or m.body == null:
		return PickUp.make(crew, false, null, &"noPlayer")
	if not m.active:
		return PickUp.make(crew, false, null, &"inactive")
	var ft: FloorTape = null
	for f in crew.floor:
		if f.tape.id == tape_id:
			ft = f
			break
	if ft == null:
		return PickUp.make(crew, false, null, &"noTape")
	if feet_distance(m.body, ft.at) > PICKUP_REACH + EPS:
		return PickUp.make(crew, false, null, &"tooFar")
	var next := crew.copy()
	next.floor = []
	for f in crew.floor:
		if f != ft:
			next.floor.append(f)
	for i in next.members.size():
		if next.members[i].id == player_id:
			var x := next.members[i].copy()
			x.carrying.append(ft.tape)
			next.members[i] = x
	return PickUp.make(next, true, {"type": "tapePickedUp", "t": crew.t, "playerId": player_id, "tapeId": tape_id}, &"ok")

## PN2: an active player puts down the last tape they picked up (not their own, which their instrument records
## onto), at `at` (their body now; null: where they stood at the last step_crew). "tapeDropped" {playerId, tapeId, at, why: "put"}; it lies on the
## floor as any dropped tape and pick_up_tape takes it again. Fails ("noTape") when they carry none.
static func put_down_tape(crew: CrewState, player_id: String, at: Move.Body = null) -> PickUp:
	var m := member(crew, player_id)
	if m == null or m.body == null:
		return PickUp.make(crew, false, null, &"noPlayer")
	if not m.active:
		return PickUp.make(crew, false, null, &"inactive")
	if m.carrying.is_empty():
		return PickUp.make(crew, false, null, &"noTape")
	var next := crew.copy()
	var x := m.copy()
	var tape: TapeLib.Tape = x.carrying.pop_back()
	for i in next.members.size():
		if next.members[i].id == player_id:
			next.members[i] = x
	var where := at if at != null else m.body
	next.floor.append(FloorTape.make(tape, where))
	return PickUp.make(next, true, {"type": "tapeDropped", "t": crew.t, "playerId": player_id, "tapeId": tape.id, "at": where, "why": "put"}, &"ok")

class Departure:
	## Tapes that leave with the crew (non-empty only).
	var carried: Array[TapeLib.Tape] = []
	## Tapes left behind: on the floor, or held by someone not aboard.
	var lost: Array[TapeLib.Tape] = []
	var carried_value: float = 0.0
	var lost_value: float = 0.0

## The elevator leaves. Everything held by a member who is aboard goes with it; everything on the
## floor is lost. `aboard` null means every member (who boarded is the elevator's business).
static func leave_floor(crew: CrewState, aboard: Variant = null) -> Departure:
	var d := Departure.new()
	for f in crew.floor:
		d.lost.append(f.tape)
	for m in crew.members:
		var held: Array[TapeLib.Tape] = []
		for tp: TapeLib.Tape in [m.tape] + m.carrying:
			if not tp.readings.is_empty():
				held.append(tp)
		if aboard == null or (aboard as Array).has(m.id):
			d.carried.append_array(held)
		else:
			d.lost.append_array(held)
	d.carried_value = TapeLib.tape_value(d.carried)
	d.lost_value = TapeLib.tape_value(d.lost)
	return d
