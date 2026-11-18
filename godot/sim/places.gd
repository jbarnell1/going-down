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

## Every floor a Clinic: the default of a run, so the stored goldens stay as recorded.
const CLINIC_ONLY: Array[StringName] = [&"clinic"]
## The game's deck.
const FULL: Array[StringName] = [&"clinic", &"annex", &"playroom", &"arboretum"]
## The game's deck before the Arboretum: every floor it gives is the floor it gave then (anything recorded
## with it, at any depth, is unchanged).
const BEFORE_ARBORETUM: Array[StringName] = [&"clinic", &"annex", &"playroom"]
## The fixed floors, by depth (index 0 is the prison, which is never drawn).
const FIXED: Array[StringName] = [&"prison", &"clinic", &"clinic", &"annex", &"playroom", &"arboretum"]

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
		if sp != PRISON and not out.has(sp):
			out.append(sp)
	if out.is_empty():
		out.append(CLINIC)
	return out

## The place of floor `depth` for this seed and deck (FULL when not given).
static func place_at(seed: String, depth: int, deck: Array = FULL) -> StringName:
	if depth <= 0:
		return PRISON
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
static func generate(seed: String, depth: int, deck: Array = FULL) -> Floor.FloorPlan:
	match place_at(seed, depth, deck):
		PRISON:
			return Prison.prison_plan()
		ANNEX:
			return Annex.generate_annex(seed, depth)
		PLAYROOM:
			return Playroom.generate_playroom(seed, depth)
		ARBORETUM:
			return Arboretum.generate_arboretum(seed, depth)
	return Clinic.generate_clinic(seed, depth)

## The resident a floor starts with, at plan.entity_start in its own body. THE one place a floor's
## resident is made (run.gd, net/host_rules.gd).
static func create_resident(plan: Floor.FloorPlan) -> Entity.OrderlyState:
	return Entity.create_orderly(plan, resident(plan.place).body)
