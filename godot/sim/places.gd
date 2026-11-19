# The place deck: which place each floor is, and the one way a floor plan is made. North Star A2 (every
# floor is a different place, drawn from a deck by the shared seed; the place decides its resident) and
# B11 (the Orderly lives in the Clinic, the Temp in the Annex); owner decisions of 17 Nov: the prison is
# depth 0, the floor after the Annex is the Playroom (its resident the Minder hunts by hearing, not by
# Stillness); of 18 Nov: the Arboretum is the fifth floor ("It can be fifth"; its Groundskeeper hears:
# sim/hearing.gd), and from floor 6 the deck draws Clinic, Annex, Playroom or Arboretum by the seed, never the
# same twice running. Pure and deterministic; the host and every client call the same functions.
#
#   place_at(seed, depth, deck)  prison at 0; Clinic at 1 and 2, Annex at 3, Playroom at 4, Arboretum at 5;
#                                from 6 a seeded draw from the deck, never the place of the floor above.
#   generate(seed, depth, deck)  THE way a plan is made: the generator of place_at's place.
#   resident(place)              who lives there: name, whether Stillness rules it, its instrument trait.
#
# Cycles (FL2; docs/floors/difficulty.md section 1, the owner's words of 19 Nov): a deck may carry the marker
# CYCLES (with_cycles; never a place, never drawn). With it, floors repeat in cycles of CYCLE_FLOORS: the place
# of floor d >= 8 is the place of floor local_depth(d) = 1 + (d - 1) % 7 (so 8 and 9 are Clinics, 10 the Annex,
# 13 and 14 the floors under the Hanging Ward and the Reactor), while the plan is still generated with the real
# depth (floor 8 is a different Clinic from floor 1). Without the marker every function here returns exactly what
# it returned before, at every depth. The marker rides in the run's deck, so the host, every client (Session
# plan_for) and every reader of place_at agree without a second switch.
#
# The Playroom's Minder is stepped by sim/seek.gd from sim/run.gd (T15d): its wander, the count, the
# search. Its instrument trait is "hearing" (instrument.gd records it only while it searches).
#
# A deck is the list of places a run may draw. Runs default to CLINIC_ONLY (every floor a Clinic, as
# every stored run result was recorded); the game passes FULL. With a deck that lacks a fixed floor's
# place (depths 1 to 5), that floor is drawn like the floors from 6: so BEFORE_ARBORETUM, the game's deck
# as it was before the Arboretum, still gives exactly the floors it always gave, at every depth.
extends RefCounted

const Floor = preload("res://sim/floor.gd")
const Clinic = preload("res://sim/clinic.gd")
const Annex = preload("res://sim/annex.gd")
const Playroom = preload("res://sim/playroom.gd")
const Prison = preload("res://sim/prison.gd")
const Arboretum = preload("res://sim/arboretum.gd")
const Entity = preload("res://sim/entity.gd")
const Rng = preload("res://sim/rng.gd")

const PRISON := &"prison"
const CLINIC := &"clinic"
const ANNEX := &"annex"
const PLAYROOM := &"playroom"
## The Arboretum (North Star A2): a forest indoors; its Groundskeeper hears (sim/hearing.gd).
const ARBORETUM := &"arboretum"
const Orientation = preload("res://sim/orientation.gd")
const ORIENTATION_ONLY: Array[StringName] = [Orientation.PLACE]

## Every floor a Clinic: the default of a run, so the stored goldens stay as recorded.
const CLINIC_ONLY: Array[StringName] = [&"clinic"]
## The game's deck.
const FULL: Array[StringName] = [&"clinic", &"annex", &"playroom", &"arboretum"]
## The game's deck before the Arboretum: every floor it gives is the floor it gave then (anything recorded
## with it, at any depth, is unchanged).
const BEFORE_ARBORETUM: Array[StringName] = [&"clinic", &"annex", &"playroom"]
## The fixed floors, by depth (index 0 is the prison, which is never drawn).
## A depth-five playtest always includes the garden. Fresh full-deck campaigns admit it unless their host requests the rollback.
static func deck_for_start_depth(depth: int, garden_admitted: bool = false) -> Array[StringName]:
	return FULL if garden_admitted or depth == FIXED.find(ARBORETUM) else BEFORE_ARBORETUM

const FIXED: Array[StringName] = [&"prison", &"clinic", &"clinic", &"annex", &"playroom", &"arboretum"]

## Cycles (FL2, see the header): the deck marker, and how many floors one cycle has.
const CYCLES := &"cycles"
const CYCLE_FLOORS := 7

## The deck with the cycles marker (once, at the end; the places keep their order).
static func with_cycles(deck: Array) -> Array[StringName]:
	var out: Array[StringName] = []
	for p: Variant in deck:
		out.append(StringName(p))
	if not out.has(CYCLES):
		out.append(CYCLES)
	return out

## Whether the deck repeats its floors in cycles.
static func cycles_in(deck: Array) -> bool:
	return deck.has(CYCLES)

## The cycle a floor belongs to: 1 for floors 1 to 7, 2 for 8 to 14, ... (the prison and below: 1).
static func cycle_of(depth: int) -> int:
	return 1 + (maxi(depth, 1) - 1) / CYCLE_FLOORS

## The floor of cycle one that floor `depth` repeats: 1 + (depth - 1) % 7 with the marker, else depth itself.
static func local_depth(depth: int, deck: Array) -> int:
	if depth >= 1 and cycles_in(deck):
		return 1 + (depth - 1) % CYCLE_FLOORS
	return depth

## The first floor of the cycle after `cycles_done` finished ones: 1, 8, 15, ...
static func cycle_start(cycles_done: int) -> int:
	return 1 + CYCLE_FLOORS * maxi(0, cycles_done)

## The Minder's stroll outside a count (seek.gd WANDER_SPEED).
const WANDER_SPEED := 1.2

## Who lives in a place.
class Resident:
	## "Orderly", "Temp", "Minder", or "" (the prison has none).
	var name: String
	## Ruled by Stillness: it only moves while nobody is looking (entity.gd).
	var stillness: bool
	## What the instruments call its trait: "stillness" (while it moves unseen), "hearing" (while it
	## searches during a count; sim/run.gd says when, and for whom) or "lonely" (while it chases someone
	## alone, for that one only: resident_in).
	var trait_name: StringName
	## Its body numbers (entity.gd BodySettings: height, seen size, speeds, sound), or null where none is
	## made yet (the Minder stands in with the Orderly's). create_resident gives it to the floor's state,
	## and everything after reads it from there (Entity.kind_of).
	var body: Entity.BodySettings = null

	static func make(name_: String, stillness_: bool, trait_: StringName, body_: Entity.BodySettings = null) -> Resident:
		var r := Resident.new()
		r.name = name_
		r.stillness = stillness_
		r.trait_name = trait_
		r.body = body_
		return r

## The resident of a place. The Temp keeps the Orderly's Stillness rules, in its own body (T16f).
static func resident(place: StringName) -> Resident:
	match place:
		CLINIC:
			return Resident.make("Orderly", true, &"stillness", Entity.orderly_body())
		ANNEX:
			return Resident.make("Temp", true, &"stillness", Entity.temp_body())
		PLAYROOM:
			return Resident.make("Minder", false, &"hearing")
		ARBORETUM:
			# Its instrument trait is "listening": it records only while it comes to a noise or leans.
			return Resident.make("Groundskeeper", false, &"listening")
		Orientation.PLACE:
			return Resident.make("Practice target", true, &"stillness", Orientation.target_body())
	return Resident.make("", false, &"")

## The resident of a place in a run with Lonely on or off (sim/run.gd resident_of; T19c): with it on the Temp
## carries Lonely (sim/lonely.gd), its own mechanic, and not Stillness; every other place is as resident() says.
## Off, every stored result's Stillness Temp.
static func resident_in(place: StringName, lonely: bool) -> Resident:
	if lonely and place == ANNEX:
		return Resident.make("Temp", false, &"lonely", Entity.temp_body())
	return resident(place)

## The entity id of a floor's resident (the Clinic's stays "orderly-<depth>", as recorded).
static func entity_id(place: StringName, depth: int) -> String:
	var r := resident(place)
	return "%s-%d" % [r.name.to_lower() if not r.name.is_empty() else "orderly", depth]

static func _deck_or_clinic(deck: Array) -> Array[StringName]:
	var out: Array[StringName] = []
	for p: Variant in deck:
		var sp := StringName(p)
		if sp != PRISON and sp != CYCLES and not out.has(sp):
			out.append(sp)
	if out.is_empty():
		out.append(CLINIC)
	return out

## The place of floor `depth` for this seed and deck (FULL when not given). With the cycles marker, a floor
## past the first cycle is the place of the floor it repeats (local_depth; see the header).
static func place_at(seed: String, depth: int, deck: Array = FULL) -> StringName:
	if deck == ORIENTATION_ONLY:
		return Orientation.PLACE
	if depth <= 0:
		return PRISON
	if depth > CYCLE_FLOORS and cycles_in(deck):
		return place_at(seed, local_depth(depth, deck), deck)
	var d := _deck_or_clinic(deck)
	var prev := PRISON
	var here := CLINIC
	for k in range(1, depth + 1):
		if k < FIXED.size() and d.has(FIXED[k]):
			here = FIXED[k]
		else:
			var choices: Array = []
			for p in d:
				if p != prev:
					choices.append(p)
			if choices.is_empty():
				choices = d.duplicate()
			here = Rng.make_rng("place:%s:%d" % [seed, k]).pick(choices)
		prev = here
	return here

## THE one way the host and every client make the plan of a floor.
static func generate(seed: String, depth: int, deck: Array = FULL, garden_dense: bool = false) -> Floor.FloorPlan:
	match place_at(seed, depth, deck):
		PRISON:
			return Prison.prison_plan()
		ANNEX:
			return Annex.generate_annex(seed, depth)
		PLAYROOM:
			return Playroom.generate_playroom(seed, depth)
		ARBORETUM:
			return Arboretum.generate_arboretum(seed, depth, garden_dense)
		Orientation.PLACE:
			return Orientation.generate(seed, depth)
	return Clinic.generate_clinic(seed, depth)

## The resident a floor starts with, at plan.entity_start in its own body. THE one place a floor's
## resident is made (run.gd, net/host_rules.gd).
static func create_resident(plan: Floor.FloorPlan) -> Entity.OrderlyState:
	return Entity.create_orderly(plan, resident(plan.place).body)
