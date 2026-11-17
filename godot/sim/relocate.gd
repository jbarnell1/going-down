# Relocation: losing track of it (docs/floors/traits-and-hiding.md section 5; T19e). The owner: "Players should
# be able to lose track of the entities." A resident may leave a place nobody can see and arrive at another
# nobody can see. Pure and deterministic; sim/run.gd calls step() once a tick, after the resident's own step,
# in a run with relocation on (Run.with_relocation; net/host_rules.gd turns it on for the game's rooms).
#
# Out of view (out_of_view): no eye has a clear line (Sight.has_line_of_sight, whichever way anyone faces) to a
# figure standing there, from the player's own eyes or from eye height over the centre of their own cell or any
# of the eight cells round it that one can stand on. Ignoring facing is what makes it safe over a network: a
# player can turn in a frame but cannot cross a cell in one. The figure is the resident's own body at its full
# height and the larger outline its walk reaches (BodySettings: height and radius, seen_height and
# seen_radius_walk). Eyes are every player on their feet or down, in the open car or not; never a caught, out
# or left-behind one (sim/run.gd builds the list: relocation_eyes).
#
# It leaves when all of these hold (step):
#   - its trait's own trigger is true (the rows below, wants_to_leave);
#   - it is hunting: not waiting, in a wind-up, bent over someone or dormant, and not standing after an arrival;
#   - nobody holds it and no watcher is counted (relocating is moving: Stillness obeys the rule);
#   - at least REST seconds since it last arrived, and not before a retry is due;
#   - the run allows it this tick (`free`: no blink, blackout or warning, the lift not boarding: sim/run.gd);
#   - it has been out of view, by the test above, for OUT_OF_VIEW_TIME without a break while all the above held.
#     (Counted only while the rest holds, so the out-of-view test runs only on the ticks it could matter.)
#
# Where it arrives (arrival): a walkable cell that is out of view, NEAR_MIN to NEAR_MAX metres by walking from
# the player it goes to (so joined to them by a path) and at least NEAR_MIN from every other eye with a place on
# the floor, never a hide's inside or front spot, the lobby, the landing, the car's zone or a stair (barred).
# The pick is Rng "reloc:<seed>:<depth>:<k>" (k: relocations on the floor so far): a seeded shuffle of the cells
# that pass the distances and the bars, in cell order, then the first of them out of view. That is a seeded
# uniform pick among every cell that passes, without testing the sight lines of them all. None passes: it stays
# and tries again in RETRY seconds.
#
# Arriving (Entity.arrive): it is at the new cell's centre facing the player it came for, `relocated` this tick
# (the instrument never records it, sim/instrument.gd), its walking sound gone and its arrival cue playing at
# full reach (Entity.audibility; the "relocated" event: sim/run.gd), standing Entity.RELOCATE_STAND seconds.
# It arrives within NEAR_MAX of someone, under every resident's hearing reach, so someone always hears it.
#
# The rows, per trait (section 5 "Per trait"; wants_to_leave and goes_to). A trait with no row never relocates.
#   stillness  leaves: no watcher for STILL_UNWATCHED s and more than STILL_FAR m by walking from its target;
#              or its dormant spell (after a catch or a heal) has ended since it last relocated or reached for
#              anyone (Entity reloc_wish). Goes to: the player it was hunting, else the nearest by walking.
#   lonely     (T19c, sim/lonely.gd) leaves: it broke off a chase and is walking off or standing out of view
#              ("brokeOff"); or nobody has been lonely for LONELY_QUIET s while it lurks or approaches
#              ("nobodyLonely"); never during a chase. Goes to: the most isolated player, the one furthest (in a
#              straight line; another level is furthest) from their nearest crewmate, on their feet or down;
#              never the one it just left (the one it broke off from, else the one it was near) when there is
#              another. sim/run.gd's Lonely branch calls _relocate as the Stillness branch does.
#   hearing    away from the Playroom, T19f: the loudest noise of the last 10 s more than 30 m off; goes to the
#              noise. The Playroom's Minder: off until the owner has played the Playroom (sim/run.gd steps it
#              with sim/seek.gd and never asks).
#   watched    when built: no eyes for 15 s; a cell round the next corner on the nearest player's route.
#
# Hides: the cells of every hide's inside and front spot are barred. The list is sim/hides.gd's hides_for(plan,
# seed) once that file exists (T19b: every place with a resident), else the Playroom's own (Playroom.hides) on
# a Playroom and none elsewhere.
extends RefCounted

const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Sight = preload("res://sim/sight.gd")
const Entity = preload("res://sim/entity.gd")
const Rng = preload("res://sim/rng.gd")
const Playroom = preload("res://sim/playroom.gd")
const M = preload("res://sim/jsmath.gd")

## Seconds out of view, without a break, before it may leave.
const OUT_OF_VIEW_TIME := 1.0
## Seconds after an arrival before it may leave again.
const REST := 20.0
## Seconds before it tries again when no cell passed.
const RETRY := 5.0
## Its arrival, by walking from the player it goes to: at least NEAR_MIN (its wake distance: it never arrives
## nearer than it could have started) and at most NEAR_MAX metres. At least NEAR_MIN from everyone else.
const NEAR_MIN := 12.0
const NEAR_MAX := 20.0
## Cells within this many metres of the car's floor are its zone.
const CAR_ZONE := 2.0
## Stillness: no watcher for this many seconds, and further than this many metres by walking from its target.
const STILL_UNWATCHED := 12.0
const STILL_FAR := 30.0
## Lonely: nobody lonely for this many seconds.
const LONELY_QUIET := 20.0
## T19b's hide list, when it exists.
const HIDES_SCRIPT := "res://sim/hides.gd"
const EPS := 1e-9

## A player as relocation sees them: eyes, and a place on the floor to measure walking from.
class Eye:
	var id: String
	## Where they stand, and their eye height above it.
	var body: Move.Body
	var eye: float
	## The cell walking distances are measured from (the landing for a player in the car), or null when they
	## have no place on the floor.
	var walk: Floor.Pos
	## On their feet and on the floor: one it may go to.
	var up: bool

	static func make(id_: String, body_: Move.Body, eye_: float, walk_: Floor.Pos, up_: bool) -> Eye:
		var e := Eye.new()
		e.id = id_
		e.body = body_
		e.eye = eye_
		e.walk = walk_
		e.up = up_
		return e

## What one tick of relocation did: the resident's state, and the "relocated" event or null.
class Step:
	var state: Entity.OrderlyState
	var event: Variant = null

# ---------------------------------------------------------------------------------------------
# Out of view.

## The points the eyes are tested from for one player: their own eyes, then eye height over the centre of
## their own cell and the eight round it, those that can be stood on (on their level).
static func viewpoints(plan: Floor.FloorPlan, e: Eye) -> Array[Sight.Point3]:
	var out: Array[Sight.Point3] = [Sight.eye_point(e.body, e.eye)]
	var cs := float(plan.cell_size)
	var c := Move.cell_of(plan, e.body)
	var y := e.body.y + e.eye
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var x := c.x + dx
			var z := c.y + dy
			if Floor.is_walkable(plan, c.level, x, z):
				out.append(Sight.Point3.make((x + 0.5) * cs, y, (z + 0.5) * cs, c.level))
	return out

## The figure's points as seen from (from_x, from_z): its body, and the larger outline its walk reaches.
static func figure(body: Move.Body, k: Entity.BodySettings, from_x: float, from_z: float) -> Array[Sight.Point3]:
	var out := Sight.figure_points(body, from_x, from_z, k.seen_height, k.seen_radius_walk)
	out.append_array(Sight.figure_points(body, from_x, from_z, k.height, k.radius))
	return out

## Whether no eye has a clear line to a figure (body `k`) standing at `body`. See the header.
static func out_of_view(plan: Floor.FloorPlan, eyes: Array[Eye], body: Move.Body, k: Entity.BodySettings) -> bool:
	for e in eyes:
		for v in viewpoints(plan, e):
			for p in figure(body, k, v.x, v.z):
				if Sight.has_line_of_sight(plan, v, p):
					return false
	return true

# ---------------------------------------------------------------------------------------------
# Where it may not arrive.

static var _barred_plan: Floor.FloorPlan = null
static var _barred_key := ""
static var _barred: Dictionary = {}

## Every hide on the floor (Playroom.Hide-shaped: level, inside, front in whole centimetres). See the header.
static func hides_of(plan: Floor.FloorPlan, seed: String) -> Array:
	if ResourceLoader.exists(HIDES_SCRIPT):
		var script: Script = load(HIDES_SCRIPT)
		if script != null and script.has_method("hides_for"):
			return script.call("hides_for", plan, seed)
	if plan.place == &"playroom":
		return Playroom.hides(plan, seed)
	return []

## The cells it may never arrive on, {pos_index: true}: hide spots, the lobby, the landing, the car's zone
## (`car`: the car's floor as [x0, z0, x1, z1] on `car_level`), stairs. Cached for the last plan asked.
static func barred(plan: Floor.FloorPlan, seed: String, car: PackedFloat64Array, car_level: int) -> Dictionary:
	var key := "%s|%s|%d" % [seed, str(car), car_level]
	if _barred_plan == plan and _barred_key == key:
		return _barred
	var out := {}
	var cm := plan.cell_size * 100
	for h: Variant in hides_of(plan, seed):
		for spot: Vector2i in [h.inside, h.front]:
			out[Floor.pos_index(plan, Floor.Pos.make(int(h.level), floori(float(spot.x) / cm), floori(float(spot.y) / cm)))] = true
	for r in plan.rooms:
		if r.kind != &"lobby":
			continue
		for y in range(r.y, r.y + r.h):
			for x in range(r.x, r.x + r.w):
				out[Floor.pos_index(plan, Floor.Pos.make(r.level, x, y))] = true
	out[Floor.pos_index(plan, plan.landing)] = true
	var cs := float(plan.cell_size)
	for y in plan.height:
		for x in plan.width:
			for level in 2:
				if Floor.cell_at(plan, level, x, y) == Floor.STAIR:
					out[Floor.pos_index(plan, Floor.Pos.make(level, x, y))] = true
			# The car's zone: cells whose square comes within CAR_ZONE of the car's floor.
			var gx := maxf(0.0, maxf(car[0] - (x + 1) * cs, x * cs - car[2]))
			var gz := maxf(0.0, maxf(car[1] - (y + 1) * cs, y * cs - car[3]))
			if M.hypot2(gx, gz) <= CAR_ZONE + EPS:
				out[Floor.pos_index(plan, Floor.Pos.make(car_level, x, y))] = true
	_barred_plan = plan
	_barred_key = key
	_barred = out
	return out

# ---------------------------------------------------------------------------------------------
# The rows, per trait (see the header).

static func _eye(eyes: Array[Eye], id: Variant) -> Eye:
	for e in eyes:
		if id != null and e.id == str(id):
			return e
	return null

## Walking metres from the resident to an eye's place (INF when there is no path).
static func _walk_to(plan: Floor.FloorPlan, from: Move.Body, e: Eye) -> float:
	if e == null or e.walk == null:
		return INF
	var d := Entity._distances_cached(plan, Move.cell_of(plan, from))[Floor.pos_index(plan, e.walk)]
	return INF if d < 0 else d * float(plan.cell_size)

## Why the trait's own trigger to leave is true this tick (the "relocated" event's `why`), or &"" if it is not.
static func wants_to_leave(trait_name: StringName, plan: Floor.FloorPlan, o: Entity.OrderlyState, eyes: Array[Eye]) -> StringName:
	match trait_name:
		&"stillness":
			if o.reloc_wish:
				return &"dormant"
			if o.unwatched_for < STILL_UNWATCHED - EPS:
				return &""
			var target := _eye(eyes, o.target_id)
			return &"far" if target != null and target.up and _walk_to(plan, o.body, target) > STILL_FAR + EPS else &""
		&"lonely":
			if o.lonely_phase == &"breakoff":
				return &"brokeOff"
			if o.lonely_phase != &"chase" and o.lonely_quiet >= LONELY_QUIET - EPS:
				return &"nobodyLonely"
		# &"hearing" (away from the Playroom): T19f. &"watched": when built.
	return &""

## The player it goes to (an up eye with a place on the floor), or "" for none.
static func goes_to(trait_name: StringName, plan: Floor.FloorPlan, o: Entity.OrderlyState, eyes: Array[Eye]) -> String:
	match trait_name:
		&"stillness":
			var hunted := _eye(eyes, o.target_id)
			if hunted != null and hunted.up and hunted.walk != null:
				return hunted.id
			var best := ""
			var best_d := INF
			var dist := Entity._distances_cached(plan, Move.cell_of(plan, o.body))
			for e in eyes:
				if not e.up or e.walk == null:
					continue
				var d := dist[Floor.pos_index(plan, e.walk)]
				if d >= 0 and float(d) < best_d:
					best_d = float(d)
					best = e.id
			return best
		&"lonely":
			var left: Variant = o.lonely_left if o.lonely_left != null else o.target_id
			var best := ""
			var best_d := -1.0
			var only := ""
			for e in eyes:
				if not e.up or e.walk == null:
					continue
				if left != null and e.id == str(left):
					only = e.id
					continue
				var near := INF
				for f in eyes:
					if f != e and f.body.level == e.body.level:
						near = minf(near, M.hypot2(f.body.x - e.body.x, f.body.z - e.body.z))
				if near > best_d:
					best_d = near
					best = e.id
			return best if best != "" else only
	return ""

# ---------------------------------------------------------------------------------------------
# Leaving and arriving.

## Whether its state lets it leave at host time `t` (see the header): hunting, free, rested.
static func may_leave(o: Entity.OrderlyState, t: float) -> bool:
	return o.mode == &"hunting" and o.stand_left <= EPS and not o.held and o.watchers.is_empty() \
		and t - o.arrived_at >= REST - EPS and t >= o.retry_at - EPS

## The cell it arrives on going to `to` (an eye's id), or null if none passes. `k`: relocations so far.
static func arrival(plan: Floor.FloorPlan, seed: String, depth: int, k: int, to: String, eyes: Array[Eye], bars: Dictionary, kind: Entity.BodySettings) -> Floor.Pos:
	var target := _eye(eyes, to)
	if target == null or target.walk == null:
		return null
	var cs := float(plan.cell_size)
	var dist := Floor.distances_from(plan, target.walk)
	var others: Array[PackedInt32Array] = []
	for e in eyes:
		if e != target and e.walk != null:
			others.append(Floor.distances_from(plan, e.walk))
	var cands: Array[int] = []
	for i in dist.size():
		var d := dist[i]
		if d < 0 or d * cs < NEAR_MIN - EPS or d * cs > NEAR_MAX + EPS or bars.has(i):
			continue
		var p := Floor.pos_from_index(plan, i)
		if not Floor.is_walkable(plan, p.level, p.x, p.y):
			continue
		var apart := true
		for od in others:
			if od[i] >= 0 and od[i] * cs < NEAR_MIN - EPS:
				apart = false
				break
		if apart:
			cands.append(i)
	var rng := Rng.make_rng("reloc:%s:%d:%d" % [seed, depth, k])
	for n in cands.size():
		var j := rng.int_in(n, cands.size() - 1)
		var c := cands[j]
		cands[j] = cands[n]
		cands[n] = c
		var p := Floor.pos_from_index(plan, c)
		if out_of_view(plan, eyes, Move.body_at_cell(plan, p), kind):
			return p
	return null

## One tick of relocation for the resident `o`, already stepped this tick (host time `t`). `free`: the run
## allows it this tick (see the header); `bars`: barred(). Never mutates `o`.
static func step(plan: Floor.FloorPlan, seed: String, depth: int, trait_name: StringName, o: Entity.OrderlyState, eyes: Array[Eye], bars: Dictionary, free: bool, t: float, dt: float) -> Step:
	var out := Step.new()
	out.state = o
	var why: StringName = wants_to_leave(trait_name, plan, o, eyes) if free and may_leave(o, t) else &""
	if why == &"":
		if o.hidden_for != 0.0:
			out.state = o.copy()
			out.state.hidden_for = 0.0
		return out
	var k := Entity.kind_of(o)
	var s := o.copy()
	s.hidden_for = o.hidden_for + dt if out_of_view(plan, eyes, o.body, k) else 0.0
	out.state = s
	if s.hidden_for < OUT_OF_VIEW_TIME - EPS:
		return out
	var to := goes_to(trait_name, plan, o, eyes)
	var cell: Floor.Pos = arrival(plan, seed, depth, o.relocations, to, eyes, bars, k) if to != "" else null
	if cell == null:
		s.retry_at = t + RETRY
		s.hidden_for = 0.0
		return out
	var body := Move.body_at_cell(plan, cell)
	var target := _eye(eyes, to)
	var yaw := Entity.yaw_toward(target.body.x - body.x, target.body.z - body.z)
	out.state = Entity.arrive(s, body, yaw, t, to)
	out.event = {"type": "relocated", "t": t, "from": o.body, "to": body, "near": to, "k": out.state.relocations,
		"who": String(k.name), "reach": k.hear_range, "why": String(why)}
	return out
