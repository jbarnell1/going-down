# Tapes: where a player's readings sit until the crew banks them. Pure data and small helpers;
# the crew logic that drops and picks tapes up lives in instrument.gd. Port of src/sim/tape.ts.
extends RefCounted

# Trait: a trait an entity has. Each trait's safety rule says when it can be recorded. Only
# &"stillness" so far.

## One closed reading: a continuous stretch of recording one trait of one entity. Immutable.
class Reading:
	## Unique within a run.
	var id: String
	## Who held the instrument.
	var player_id: String  # TypeScript: playerId
	var entity_id: String  # TypeScript: entityId
	var trait_name: StringName  # TypeScript: trait ('trait' is reserved in GDScript)
	## Pay, already multiplied by the repeat factor that applied while it was recorded.
	var value: float
	## Seconds of actual recording in it (gaps not counted).
	var duration: float
	## Highest per-second rate reached (after the repeat factor).
	var peak_rate: float  # TypeScript: peakRate
	## Simulation time it was closed.
	var closed_at: float  # TypeScript: closedAt

	func copy() -> Reading:
		var r := Reading.new()
		r.id = id
		r.player_id = player_id
		r.entity_id = entity_id
		r.trait_name = trait_name
		r.value = value
		r.duration = duration
		r.peak_rate = peak_rate
		r.closed_at = closed_at
		return r

## Immutable: changes make a new Tape.
class Tape:
	var id: String
	## Whose instrument recorded onto it (it may be carried by someone else).
	var owner_id: String  # TypeScript: ownerId
	var readings: Array[Reading] = []
	## Sum of the readings' values.
	var total: float = 0.0

	func copy() -> Tape:
		var t := Tape.new()
		t.id = id
		t.owner_id = owner_id
		t.readings = readings.duplicate()
		t.total = total
		return t

static func empty_tape(id: String, owner_id: String) -> Tape:
	var t := Tape.new()
	t.id = id
	t.owner_id = owner_id
	return t

## A copy of the tape with one more reading on it.
static func add_reading(tape: Tape, reading: Reading) -> Tape:
	var t := tape.copy()
	t.readings.append(reading)
	t.total = tape.total + reading.value
	return t

## What a set of tapes is worth (TypeScript: tapeValue(tapes); pass [tape] for one).
static func tape_value(tapes: Array[Tape]) -> float:
	var sum := 0.0
	for t in tapes:
		for r in t.readings:
			sum += r.value
	return sum
