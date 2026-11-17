# The place deck: which place each floor is, and the one way a floor plan is made. North Star A2 (every
# floor is a different place, drawn from a deck by the shared seed; the place decides its resident) and
# B11 (the Orderly lives in the Clinic, the Temp in the Annex); owner decisions of 17 Nov: the prison is
# depth 0, the floor after the Annex is the Playroom (its resident the Minder hunts by hearing, not by
# Stillness), and from floor 5 the deck draws Clinic, Annex or Playroom by the seed, never the same twice
# running. Pure and deterministic; the host and every client call the same functions.
#
#   place_at(seed, depth, deck)  prison at 0; Clinic at 1 and 2, Annex at 3, Playroom at 4; from 5 a
#                                seeded draw from the deck, never the place of the floor above.
#   generate(seed, depth, deck)  THE way a plan is made: the generator of place_at's place.
#   resident(place)              who lives there: name, whether Stillness rules it, its instrument trait.
#   wander_step(...)             the Minder's harmless wander while its count is not wired (T15d).
#
# A deck is the list of places a run may draw. Runs default to CLINIC_ONLY (every floor a Clinic, as
# every stored run result was recorded); the game passes FULL. With a deck that lacks a fixed floor's
# place (depths 1 to 4), that floor is drawn like the floors from 5.
extends RefCounted

const Floor = preload("res://sim/floor.gd")
const Clinic = preload("res://sim/clinic.gd")
const Annex = preload("res://sim/annex.gd")
const Playroom = preload("res://sim/playroom.gd")
const Prison = preload("res://sim/prison.gd")
const Entity = preload("res://sim/entity.gd")
const Follow = preload("res://sim/follow.gd")
const Move = preload("res://sim/move.gd")
const Rng = preload("res://sim/rng.gd")
const M = preload("res://sim/jsmath.gd")

const PRISON := &"prison"
const CLINIC := &"clinic"
const ANNEX := &"annex"
const PLAYROOM := &"playroom"

## Every floor a Clinic: the default of a run, so the stored goldens stay as recorded.
const CLINIC_ONLY: Array[StringName] = [&"clinic"]
## The game's deck.
const FULL: Array[StringName] = [&"clinic", &"annex", &"playroom"]
## The fixed floors, by depth (index 0 is the prison, which is never drawn).
const FIXED: Array[StringName] = [&"prison", &"clinic", &"clinic", &"annex", &"playroom"]

## The Minder's wander (seek.gd WANDER_SPEED, a stroll) and its pause at each stop (seek.gd STRAIGHTEN_TIME).
const WANDER_SPEED := 1.2
const WANDER_PAUSE := 3.0
## A wander stop is this many cells or more (by walking) from where it stands, when the floor allows.
const WANDER_MIN_STEPS := 6

## Who lives in a place.
class Resident:
	## "Orderly", "Temp", "Minder", or "" (the prison has none).
	var name: String
	## Ruled by Stillness: it only moves while nobody is looking (entity.gd).
	var stillness: bool
	## What the instruments call its trait (instrument.gd records only "stillness" so far).
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
	return Resident.make("", false, &"")

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
	return Clinic.generate_clinic(seed, depth)

## The resident a floor starts with, at plan.entity_start in its own body. THE one place a floor's
## resident is made (run.gd, net/host_rules.gd).
static func create_resident(plan: Floor.FloorPlan) -> Entity.OrderlyState:
	return Entity.create_orderly(plan, resident(plan.place).body)

# ---------------------------------------------------------------------------------------------
# The Minder's wander. seek.gd holds the Playroom's real rules (the count, the search, being found);
# wiring them into the run is a later piece (T15d). Until then the Minder strolls from stop to stop,
# pauses, and goes on: it never sees, freezes, reaches or catches. It keeps the Orderly's state shape so
# the snapshot and the views carry it unchanged ("hunting" while it walks, "dormant" while it pauses).

## One tick of the wander. `key` seeds its choice of stops (the run passes the entity id and seed).
static func wander_step(plan: Floor.FloorPlan, prev: Entity.OrderlyState, dt: float, key: String) -> Entity.OrderlyState:
	var s := prev.copy()
	s.t = prev.t + dt
	s.moving = false
	s.speed = 0.0
	s.seen = false
	s.held = false
	s.frozen = false
	s.wind_up_left = 0.0
	s.wind_up_target = null
	s.target_id = null
	s.anim_time += dt
	if s.mode == &"dormant":
		s.anim = &"idle"
		s.dormant_left -= dt
		if s.dormant_left > 1e-9:
			return s
		s.dormant_left = 0.0
		s.path = []
	s.mode = &"hunting"
	if s.path.is_empty():
		s.path = _wander_route(plan, s.body, "%s:%d" % [key, roundi(s.t * 20.0)])
		s.path_next = 1 if s.path.size() > 1 else 0
		if s.path.is_empty():
			s.anim = &"idle"
			return s
	var walk := Follow.PathWalk.make(s.path, s.path_next)
	var before := s.body
	if Follow.path_done(plan, walk, before):
		s.mode = &"dormant"
		s.dormant_left = WANDER_PAUSE
		s.anim = &"idle"
		return s
	s.body = Follow.step_path_walk(plan, walk, before, WANDER_SPEED * dt, Entity.ORDERLY_RADIUS)
	s.path_next = walk.next
	var mx := s.body.x - before.x
	var mz := s.body.z - before.z
	var moved := M.hypot2(mx, mz)
	s.moving = moved > 1e-9
	s.speed = moved / maxf(dt, 1e-9)
	if s.moving:
		s.yaw = Entity._turn_toward(s.yaw, Entity.yaw_toward(mx, mz), Entity.TURN_RATE * dt)
		s.anim = &"walk"
	else:
		# Stuck on a corner: pause, then choose again.
		s.anim = &"idle"
		s.mode = &"dormant"
		s.dormant_left = WANDER_PAUSE
	return s

## A route from `body` to a seeded walkable cell some way off (any level the stairs reach).
static func _wander_route(plan: Floor.FloorPlan, body: Move.Body, key: String) -> Array[Floor.Pos]:
	var here := Move.cell_of(plan, body)
	if not Floor.is_walkable(plan, here.level, here.x, here.y):
		return []
	var dist := Floor.distances_from(plan, here)
	var far: Array = []
	var near: Array = []
	for i in dist.size():
		var d := dist[i]
		if d <= 0:
			continue
		if d >= WANDER_MIN_STEPS:
			far.append(i)
		else:
			near.append(i)
	var pool := far if not far.is_empty() else near
	if pool.is_empty():
		return []
	var to := Floor.pos_from_index(plan, int(Rng.make_rng("wander:%s" % key).pick(pool)))
	return Floor.find_path(plan, here, to)
