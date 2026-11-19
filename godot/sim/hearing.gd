# The Groundskeeper's trait: Hearing (North Star B1: "it comes to footsteps, noise and your real voice"). The
# Arboretum's resident cannot see. It listens, and it comes to where a noise WAS. Pure and deterministic;
# sim/run.gd calls step() once a tick on an Arboretum floor (a plan with a Noises.Ground and the place
# "arboretum": nothing here runs anywhere else, so every stored result is as recorded).
#
# The owner, 18 Nov: "if you don't move when he's coming you die. Like if he comes to where the sound was (and
# he's scary quick), and you're within 2 m or some configurable distance, he can snatch you). If you're just
# outside it, you get the motherload of credits. If you're just out of reach it still does a similar look so
# you don't know till the last second if the lean has caught you or not." / "I'm thinking sprinting away never
# works."
#
# The six states (Keeper.mode), the same on every screen:
#   listening  it stands, its head slowly turning (TURN degrees a second). It hears every noise made inside
#              that noise's radius of where it stands (sim/noise.gd: straight distance, nothing muffles it).
#   tilt       on hearing one it stops and grabs its head for TILT seconds: the wind-up, and
#              the last moment to go silent somewhere else. The tilt starts on the tick of the noise.
#   coming     it walks to where the noise was: straight there where the ground is open, round the thicket
#              where it is not, at its coming speed (faster in the blackout). Its own steps clink.
#   lean       at the place it turns to the nearest player on their feet within the lean range (LEAN_RANGE of
#              the PLACE) and leans down to their face for LEAN seconds. The lean is the same whether that
#              player is inside its reach or not: same pose, same length, to its last tick.
#   beat       the lean ended with nobody in its reach: it holds the same pose BEAT seconds more, straightens,
#              and listens again.
#   sweep      it arrived and nobody was inside the lean range: it sweeps the shears through the place for
#              SWEEP seconds, then listens again.
#   strike     it took someone: the shears open and close once (STRIKE seconds), then it listens again.
#
# The rules, exactly:
#  - Heard: a noise inside its own radius of where the Groundskeeper stood at the start of the tick, on its
#    level. It never fails to hear one, and it never comes to anything but the place of a noise it heard.
#  - A noise that goes on is heard wherever it goes: while it tilts or comes to a player's noise, a noise by
#    that same player that is as loud or louder is also heard when it is inside its radius of the PLACE the
#    Groundskeeper is going to. (Without this a sprinter 10 m off outran its hearing during the tilt: the
#    design's "sprinting away never works" was not true of the six states as written. With it every step of a
#    sprint moves the place to the sprinter's feet, however far they have got, and only going quiet ends it.
#    A quieter noise, a creep on litter after a whistle, is still heard only from where it stands.)
#  - Heard up close: a noise made within its REACH by a player on their feet is a snatch at once, in any
#    state. (A noise up close that nobody on their feet made, a crawl or a cone, is a noise like any other.)
#  - Of the noises of one tick it goes for the louder; equal, the nearer; equal, the lower player id.
#  - While it tilts or comes, the tick's noise takes the place of the one it is going to when it is as loud or
#    louder, or nearer to it than that place is. So a sprinter's every step moves the place to their feet, a
#    decoy's louder or nearer noise pulls it off a friend, and a quieter noise further off is let go. The tilt
#    does not start again.
#  - While it leans, holds the beat, sweeps or strikes, a noise further off than its reach is a new noise like
#    any other: the tilt, and it comes. (This is how a friend's whistle pulls it off someone it leans over.)
#  - When the lean ends it takes exactly the players on their feet within REACH of where it stands, the one it
#    leaned to and anyone else who stood there. Nobody further off, ever.
#  - A player in a hide is silent and safe: it never leans to them or takes them, unless the noise it came to
#    was that hide's own (getting in or out makes a noise): then it leans on the hide and takes whoever is
#    still inside when the lean ends.
#  - A player in the car, down or out is never leaned to and never taken.
# What follows, on purpose: never be where the noise was when it gets there. A silent bystander standing where
# a friend's noise was is taken like anyone else. Sprinting away never works: every sprinting step is a noise
# at the sprinter's feet and it is always at least a fifth faster than a sprint (the settings' pair rule).
#
# Recording (acting): only while it comes or leans. During the lean the pay is multiplied by how close the
# holder stands to its reach (lean_pay): 1.5 at the lean range and beyond, rising to 3 at its reach.
#
# Numbers. Reach, lean range, lean time, the two coming speeds (and, in sim/run.gd, the heals) are live
# settings ("groundskeeper.*", sim/settings.gd), read through Settings.f with today's constant as the
# fallback; the rest are constants here, listed in the registry for the panel to come.
#
# It walks by the plan alone, like every resident: thicket is wall, and trunks (furniture) do not stop it.
extends RefCounted

const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Noises = preload("res://sim/noise.gd")
const Settings = preload("res://sim/settings.gd")
const Entity = preload("res://sim/entity.gd")
const M = preload("res://sim/jsmath.gd")

## Coming speed, lit and in the blackout (m/s): "scary quick", a fifth faster than a sprint at the least.
const SPEED := 6.0
const DARK_SPEED := 6.5
## The hearing reaction (seconds).
const TILT := 0.8
## Its reach (metres, from where it stands).
const REACH := 2.0
## It leans to the nearest player within this of the place (metres).
const LEAN_RANGE := 4.0
## The lean (seconds), the beat after a lean that took nobody, the sweep, and the strike.
const LEAN := 2.5
const BEAT := 0.5
const SWEEP := 2.0
const STRIKE := 0.6
## Its head turns this fast while it listens (degrees a second).
const TURN := 30.0
## How fast it turns to a noise and to a face (radians a second).
const FACE_RATE := 9.0
## The lean's pay: this at the lean range and beyond, rising to LEAN_PAY_NEAR at its reach.
const LEAN_PAY_FAR := 1.5
const LEAN_PAY_NEAR := 3.0
## Its body's radius (a player's: wherever a player stood, it can stand).
const RADIUS := 0.3
## Sampling step of the straight-line test, metres.
const LINE_STEP := 0.25

const EPS := 1e-9

## The tests' deliberate breaks (tests/prop_hearing.gd): "far_take" takes the leaned-to player anywhere in the
## lean range; "short_lean" makes the lean shorter when the player is out of reach as it starts;
## "record_listening" records while it listens.
static var test_break := ""

## A player as the Groundskeeper's rules need them. Players in the car, caught or out are not given at all.
class Person extends RefCounted:
	var id: String
	var body: Move.Body
	var gait: StringName = &"walk"
	## On their feet on the floor: can be leaned to and taken.
	var up: bool = true
	## Down and crawling.
	var down: bool = false
	## Sitting inside this hide (silent and safe unless it came to the hide's own noise), else -1.
	var hide: int = -1
	## A sound emote this tick; the hide they got into or out of this tick (-1); healed up this tick.
	var emote: bool = false
	var gasp_radius := 0.0
	var soft_shoes := false
	var hide_noise: int = -1
	var search_radius := 0.0
	var healed: bool = false

	static func make(id_: String, body_: Move.Body, gait_: StringName = &"walk") -> Person:
		var p := Person.new()
		p.id = id_
		p.body = body_
		p.gait = gait_
		return p

## The Groundskeeper. Replaced, never edited, once in a run's state (copy() first).
class Keeper extends RefCounted:
	var t: float = 0.0
	var body: Move.Body
	var yaw: float = 0.0
	## &"listening" | &"tilt" | &"coming" | &"lean" | &"beat" | &"sweep" | &"strike"
	var mode: StringName = &"listening"
	## Seconds left of a timed state (tilt, lean, beat, sweep, strike).
	var left: float = 0.0
	## The noise it tilts to or comes to (null otherwise).
	var target: Noises.Sound = null
	## The place it arrived at last (the lean and the sweep are there), and when.
	var place_x: float = 0.0
	var place_z: float = 0.0
	var arrived_at: float = -1.0
	## Who it leans to ("" for nobody), and the hide it leans on (-1: none).
	var lean_id: String = ""
	var open_hide: int = -1
	## What the views play, and for how long it has: idle, tilt, walk, lean, sweep, catch.
	var anim: StringName = &"idle"
	var anim_time: float = 0.0
	var moving: bool = false
	var speed: float = 0.0
	## Its route round the thicket (cells), the cell it was made to, and whether the straight line is clear.
	var path: Array[Floor.Pos] = []
	var path_next: int = 0
	var path_goal: int = -1
	var straight: bool = false
	var stuck: int = 0
	## Where each player was on the tick before, {id: Move.Body}, and the twig fall that has cracked under
	## each this crossing, {id: fall}. Replaced, never edited.
	var last: Dictionary = {}
	var cracked: Dictionary = {}

	func copy() -> Keeper:
		var k := Keeper.new()
		k.t = t
		k.body = body
		k.yaw = yaw
		k.mode = mode
		k.left = left
		k.target = target
		k.place_x = place_x
		k.place_z = place_z
		k.arrived_at = arrived_at
		k.lean_id = lean_id
		k.open_hide = open_hide
		k.anim = anim
		k.anim_time = anim_time
		k.moving = moving
		k.speed = speed
		k.path = path
		k.path_next = path_next
		k.path_goal = path_goal
		k.straight = straight
		k.stuck = stuck
		k.last = last
		k.cracked = cracked
		return k

class Step extends RefCounted:
	var state: Keeper
	var events: Array[Dictionary] = []
	## Every noise made this tick, and those of them it heard.
	var noises: Array[Noises.Sound] = []
	var heard: Array[Noises.Sound] = []
	## Who it took this tick, in order.
	var taken: Array[String] = []

## The Groundskeeper standing at `body`, listening.
static func create(body: Move.Body, yaw: float = 0.0) -> Keeper:
	var k := Keeper.new()
	k.body = body
	k.yaw = yaw
	return k

# ---------------------------------------------------------------------------------------------
# The numbers in force.

static func reach(tuning: Settings.Values) -> float:
	return Settings.f(tuning, &"groundskeeper.reach", REACH)

static func lean_range(tuning: Settings.Values) -> float:
	return Settings.f(tuning, &"groundskeeper.lean_range", LEAN_RANGE)

static func lean_time(tuning: Settings.Values) -> float:
	return Settings.f(tuning, &"groundskeeper.lean", LEAN)

static func coming_speed(tuning: Settings.Values, dark: bool) -> float:
	return Settings.f(tuning, &"groundskeeper.dark_speed", DARK_SPEED) if dark else Settings.f(tuning, &"groundskeeper.speed", SPEED)

# ---------------------------------------------------------------------------------------------
# The instrument.

## Its rule is being tested this tick: it is coming or leaning. Never while it listens, tilts, holds the beat,
## sweeps or strikes.
static func acting(k: Keeper) -> bool:
	if test_break == "record_listening" and k.mode == &"listening":
		return true
	return k.mode == &"coming" or k.mode == &"lean"

## The pay multiplier of a holder standing `d` metres from it this tick: 1 unless it leans; in the lean
## LEAN_PAY_FAR at the lean range and beyond, rising in a straight line to LEAN_PAY_NEAR at its reach (and
## inside it).
static func lean_pay(k: Keeper, d: float, tuning: Settings.Values = null) -> float:
	if k.mode != &"lean":
		return 1.0
	var near := reach(tuning)
	var far := maxf(near + 0.01, lean_range(tuning))
	var w := clampf((far - d) / (far - near), 0.0, 1.0)
	return LEAN_PAY_FAR + (LEAN_PAY_NEAR - LEAN_PAY_FAR) * w

# ---------------------------------------------------------------------------------------------
# The step.

static func _flat(ax: float, az: float, bx: float, bz: float) -> float:
	return M.hypot2(ax - bx, az - bz)

static func _person(people: Array[Person], id: String) -> Person:
	for p in people:
		if p.id == id:
			return p
	return null

## Advances the Groundskeeper by dt seconds. `ground`: the floor's surfaces (null: every gait is on gravel);
## `people`: every player on the floor (see Person); `extra`: noises nobody's gait made (a dropped tape, a
## cone); `dark`: the blackout is on. Never mutates `prev`.
static func step(plan: Floor.FloorPlan, ground: Noises.Ground, prev: Keeper, people: Array[Person], extra: Array[Noises.Sound], dark: bool, dt: float, tuning: Settings.Values = null) -> Step:
	var t := prev.t + dt
	var k := prev.copy()
	k.t = t
	k.moving = false
	k.speed = 0.0
	k.anim_time = prev.anim_time + dt
	var res := Step.new()
	res.state = k
	var events := res.events
	var near := reach(tuning)

	# ---- This tick's noises: one per player, the loudest thing they did, then the things.
	var cracked := prev.cracked.duplicate()
	var last := {}
	for p in people:
		last[p.id] = p.body
		if p.hide >= 0 and p.hide_noise < 0:
			continue  # Sitting in a hide: silent.
		var a := Noises.Act.make(p.id, p.body, prev.last.get(p.id), p.gait)
		a.down = p.down
		a.emote = p.emote
		a.gasp_radius = p.gasp_radius
		a.soft_shoes = p.soft_shoes
		a.hide = p.hide_noise
		a.healed = p.healed
		a.search_radius = p.search_radius
		var n := Noises.of(ground, a, dt, cracked)
		if n != null:
			n.t = t
			res.noises.append(n)
			if n.kind == &"twig":
				events.append({"type": "twigCrack", "t": t, "playerId": p.id, "x": n.x, "z": n.z})
	for n in extra:
		res.noises.append(n)
	k.last = last
	k.cracked = cracked

	# ---- What it hears: every noise inside its own radius of where it stands.
	var far: Array[Noises.Sound] = []
	var going := prev.target if (prev.mode == &"tilt" or prev.mode == &"coming") else null
	for n in res.noises:
		var hears := Noises.heard_at(n, prev.body.x, prev.body.z, prev.body.level)
		if not hears and going != null and n.by != "" and n.by == going.by and n.r >= going.r - EPS:
			# A noise that goes on (see the header): heard from the place it is going to.
			hears = Noises.heard_at(n, going.x, going.z, going.level)
		if not hears:
			continue
		res.heard.append(n)
		# Heard up close: a noise within its reach, made by a player on their feet, is a snatch at once.
		var maker := _person(people, n.by) if n.by != "" else null
		if maker != null and maker.up and _flat(n.x, n.z, prev.body.x, prev.body.z) <= near + EPS:
			if not res.taken.has(maker.id):
				res.taken.append(maker.id)
				events.append({"type": "keeperSnatch", "t": t, "playerId": maker.id, "why": "close", "x": maker.body.x, "z": maker.body.z})
		else:
			far.append(n)
	if not res.taken.is_empty():
		_strike(k, _person(people, res.taken[0]))
		return res
	var best := Noises.pick(far, prev.body.x, prev.body.z)

	match k.mode:
		&"listening":
			if best != null:
				_tilt(k, best, events)
			else:
				k.yaw = Entity._wrap_angle(k.yaw + deg_to_rad(TURN) * dt)
				k.anim = &"idle"
		&"tilt":
			_retarget(k, best)
			_face(k, k.target.x, k.target.z, dt)
			k.left -= dt
			if k.left <= EPS:
				k.mode = &"coming"
				k.left = 0.0
				k.anim = &"walk"
				k.anim_time = 0.0
				k.path = []
				k.path_goal = -1
				k.straight = false
				k.stuck = 0
				events.append({"type": "keeperComing", "t": t, "x": k.target.x, "z": k.target.z, "by": k.target.by})
		&"coming":
			_retarget(k, best)
			var arrived := _walk(plan, k, coming_speed(tuning, dark) * dt, dt)
			if arrived:
				_arrive(k, people, tuning, events)
		&"lean":
			if best != null:
				events.append({"type": "keeperLeanEnd", "t": t, "playerId": k.lean_id, "taken": [], "why": "noise"})
				_tilt(k, best, events)
			else:
				var who := _person(people, k.lean_id)
				if who != null:
					_face(k, who.body.x, who.body.z, dt)
				k.left -= dt
				if k.left <= EPS:
					_end_lean(k, people, near, res)
		&"beat", &"sweep", &"strike":
			if best != null:
				_tilt(k, best, events)
			else:
				k.left -= dt
				if k.left <= EPS:
					_listen(k)
	return res

static func _listen(k: Keeper) -> void:
	k.mode = &"listening"
	k.left = 0.0
	k.target = null
	k.lean_id = ""
	k.open_hide = -1
	k.anim = &"idle"
	k.anim_time = 0.0

static func _tilt(k: Keeper, n: Noises.Sound, events: Array[Dictionary]) -> void:
	k.mode = &"tilt"
	k.left = TILT
	k.target = n
	k.lean_id = ""
	k.open_hide = -1
	k.anim = &"tilt"
	k.anim_time = 0.0
	events.append({"type": "keeperTilt", "t": k.t, "x": n.x, "z": n.z, "r": n.r, "by": n.by, "kind": String(n.kind)})

## While it tilts or comes: the tick's noise takes the place of the one it goes to when it is as loud or
## louder, or nearer to it.
static func _retarget(k: Keeper, n: Noises.Sound) -> void:
	if n == null or k.target == null:
		return
	var cur := k.target
	if n.r >= cur.r - EPS or _flat(n.x, n.z, k.body.x, k.body.z) < _flat(cur.x, cur.z, k.body.x, k.body.z) - EPS:
		k.target = n
		k.straight = false

static func _face(k: Keeper, x: float, z: float, dt: float) -> void:
	var dx := x - k.body.x
	var dz := z - k.body.z
	if M.hypot2(dx, dz) > 1e-6:
		k.yaw = Entity._turn_toward(k.yaw, Entity.yaw_toward(dx, dz), FACE_RATE * dt)

static func _strike(k: Keeper, victim: Person) -> void:
	k.mode = &"strike"
	k.left = STRIKE
	k.target = null
	k.lean_id = ""
	k.open_hide = -1
	k.anim = &"catch"
	k.anim_time = 0.0
	k.path = []
	if victim != null:
		var dx := victim.body.x - k.body.x
		var dz := victim.body.z - k.body.z
		if M.hypot2(dx, dz) > 1e-6:
			k.yaw = Entity.yaw_toward(dx, dz)

## It is at the place: the lean, to the nearest player on their feet within the lean range of the place (and
## whoever sits in the hide whose noise it came to), or the sweep.
static func _arrive(k: Keeper, people: Array[Person], tuning: Settings.Values, events: Array[Dictionary]) -> void:
	var n := k.target
	k.place_x = n.x
	k.place_z = n.z
	k.arrived_at = k.t
	k.open_hide = n.hide if n.kind == &"hide" else -1
	k.target = null
	k.path = []
	var range_ := lean_range(tuning)
	var who: Person = null
	var who_d := 0.0
	for p in people:
		if p.body.level != k.body.level:
			continue
		var leanable := (p.up and p.hide < 0) or (p.hide >= 0 and p.hide == k.open_hide)
		if not leanable:
			continue
		var d := _flat(p.body.x, p.body.z, n.x, n.z)
		if d > range_ + EPS:
			continue
		if who == null or d < who_d - EPS or (absf(d - who_d) <= EPS and p.id < who.id):
			who = p
			who_d = d
	events.append({"type": "keeperArrived", "t": k.t, "x": n.x, "z": n.z})
	if who == null:
		k.mode = &"sweep"
		k.left = SWEEP
		k.anim = &"sweep"
		k.anim_time = 0.0
		k.lean_id = ""
		k.open_hide = -1
		events.append({"type": "keeperSweep", "t": k.t, "x": n.x, "z": n.z, "len": SWEEP})
		return
	k.mode = &"lean"
	k.left = lean_time(tuning)
	if test_break == "short_lean" and _flat(who.body.x, who.body.z, k.body.x, k.body.z) > reach(tuning) + EPS:
		k.left *= 0.6
	k.lean_id = who.id
	k.anim = &"lean"
	k.anim_time = 0.0
	events.append({"type": "keeperLean", "t": k.t, "playerId": who.id, "len": k.left, "hide": k.open_hide})

## The lean is over: it takes exactly the players on their feet within its reach (and those still in the hide
## it leaned on), then strikes; or nobody, and holds the beat.
static func _end_lean(k: Keeper, people: Array[Person], near: float, res: Step) -> void:
	var first: Person = null
	var order: Array[Person] = []
	var leaned := _person(people, k.lean_id)
	if leaned != null:
		order.append(leaned)
	for p in people:
		if p != leaned:
			order.append(p)
	for p in order:
		if p.body.level != k.body.level:
			continue
		var takeable := (p.up and p.hide < 0) or (p.hide >= 0 and p.hide == k.open_hide)
		if not takeable:
			continue
		var d := _flat(p.body.x, p.body.z, k.body.x, k.body.z)
		var inside := d <= near + EPS
		if test_break == "far_take" and p == leaned:
			inside = true
		if not inside:
			continue
		res.taken.append(p.id)
		res.events.append({"type": "keeperSnatch", "t": k.t, "playerId": p.id, "why": "lean", "x": p.body.x, "z": p.body.z})
		if first == null:
			first = p
	res.events.append({"type": "keeperLeanEnd", "t": k.t, "playerId": k.lean_id, "taken": res.taken.duplicate(), "why": "end"})
	if first != null:
		_strike(k, first)
		return
	k.mode = &"beat"
	k.left = BEAT
	k.open_hide = -1
	# The same pose: the animation runs on.

# ---------------------------------------------------------------------------------------------
# Walking to the place: straight there where the line is clear, else along the shortest any-angle route round
# the thicket (an eight-way route over the cells, cut straight between the cells it can see). The route is
# never more than a twelfth longer than the true shortest way, so at a fifth faster than a sprint it always
# gains on a sprinter.

## The plan's open cells of one level as bytes (1: walkable), cached for the last few plans.
static var _grids := {}
static var _grid_order: Array = []

static func _grid(plan: Floor.FloorPlan, level: int) -> PackedByteArray:
	var key := [plan, level]
	if _grids.has(key):
		return _grids[key]
	var g := PackedByteArray()
	g.resize(plan.width * plan.height)
	for y in plan.height:
		for x in plan.width:
			g[y * plan.width + x] = 1 if Floor.is_walkable(plan, level, x, y) else 0
	_grids[key] = g
	_grid_order.append(key)
	if _grid_order.size() > 8:
		_grids.erase(_grid_order.pop_front())
	return g

## Whether a body of RADIUS can walk the straight line from (ax, az) to (bx, bz) on `level`: every cell the
## body's square touches along the way is open ground.
static func clear_line(plan: Floor.FloorPlan, level: int, ax: float, az: float, bx: float, bz: float) -> bool:
	var g := _grid(plan, level)
	var w := plan.width
	var h := plan.height
	var s := float(plan.cell_size)
	var d := M.hypot2(bx - ax, bz - az)
	var n := maxi(1, int(ceil(d / LINE_STEP)))
	var r := RADIUS - 0.01
	for i in range(0, n + 1):
		var f := float(i) / n
		var x := ax + (bx - ax) * f
		var z := az + (bz - az) * f
		var x0 := int(floor((x - r) / s))
		var x1 := int(floor((x + r) / s))
		var z0 := int(floor((z - r) / s))
		var z1 := int(floor((z + r) / s))
		if x0 < 0 or z0 < 0 or x1 >= w or z1 >= h:
			return false
		if g[z0 * w + x0] == 0 or g[z0 * w + x1] == 0 or g[z1 * w + x0] == 0 or g[z1 * w + x1] == 0:
			return false
	return true

const _STEPS: Array[Vector3i] = [Vector3i(1, 0, 10), Vector3i(-1, 0, 10), Vector3i(0, 1, 10), Vector3i(0, -1, 10),
	Vector3i(1, 1, 14), Vector3i(1, -1, 14), Vector3i(-1, 1, 14), Vector3i(-1, -1, 14)]

## The eight-way shortest route over open cells from `from` to `to` (both included), or none. A diagonal step
## needs both cells beside it open, so a body fits round every corner.
static func route(plan: Floor.FloorPlan, from: Floor.Pos, to: Floor.Pos) -> Array[Floor.Pos]:
	var out: Array[Floor.Pos] = []
	var g := _grid(plan, from.level)
	var w := plan.width
	var h := plan.height
	if from.x < 0 or from.y < 0 or from.x >= w or from.y >= h or to.x < 0 or to.y < 0 or to.x >= w or to.y >= h:
		return out
	var start := from.y * w + from.x
	var goal := to.y * w + to.x
	if g[start] == 0 or g[goal] == 0:
		return out
	var cost := PackedInt32Array()
	cost.resize(w * h)
	cost.fill(-1)
	var came := PackedInt32Array()
	came.resize(w * h)
	came.fill(-1)
	var heap := PackedInt64Array()
	cost[start] = 0
	Move._heap_push(heap, 0, start)
	while not heap.is_empty():
		var top := Move._heap_pop(heap)
		var cur := int(top & 0xFFFFFFFF)
		if cur == goal:
			break
		var cx := cur % w
		var cy := cur / w
		var base := cost[cur]
		# A stale entry (a cheaper way was found since it was pushed).
		var dxg := absi(to.x - cx)
		var dyg := absi(to.y - cy)
		if (top >> 32) > base + 10 * maxi(dxg, dyg) + 4 * mini(dxg, dyg):
			continue
		for st in _STEPS:
			var nx := cx + st.x
			var ny := cy + st.y
			if nx < 0 or ny < 0 or nx >= w or ny >= h:
				continue
			var ni := ny * w + nx
			if g[ni] == 0:
				continue
			if st.z == 14 and (g[cy * w + nx] == 0 or g[ny * w + cx] == 0):
				continue
			var c := base + st.z
			if cost[ni] >= 0 and cost[ni] <= c:
				continue
			cost[ni] = c
			came[ni] = cur
			var ddx := absi(to.x - nx)
			var ddy := absi(to.y - ny)
			Move._heap_push(heap, c + 10 * maxi(ddx, ddy) + 4 * mini(ddx, ddy), ni)
	if cost[goal] < 0:
		return out
	var at := goal
	while at >= 0:
		out.append(Floor.Pos.make(from.level, at % w, at / w))
		at = came[at]
	out.reverse()
	return out

## One tick of walking toward its target, at most `dist` metres. True when it is there (or can get no nearer).
static func _walk(plan: Floor.FloorPlan, k: Keeper, dist: float, dt: float) -> bool:
	var goal := k.target
	var from := k.body
	var left := dist
	var s := float(plan.cell_size)
	var level := k.body.level
	for _hop in 8:
		if left <= 1e-9:
			break
		if _flat(goal.x, goal.z, k.body.x, k.body.z) <= 1e-6:
			break
		var wx := goal.x
		var wz := goal.z
		if not k.straight:
			k.straight = clear_line(plan, level, k.body.x, k.body.z, goal.x, goal.z)
		if not k.straight:
			var gc := Floor.Pos.make(level, int(floor(goal.x / s)), int(floor(goal.z / s)))
			var gi := Floor.pos_index(plan, gc)
			if k.path_goal != gi or k.path.is_empty():
				k.path = route(plan, Move.cell_of(plan, k.body), gc)
				k.path_next = 1 if k.path.size() > 1 else 0
				k.path_goal = gi
			if k.path.is_empty():
				return true  # No way there at all: it can get no nearer.
			# Cut straight to the furthest cell of the route it can walk to in a line.
			for _n in 12:
				if k.path_next >= k.path.size() - 1:
					break
				var c := k.path[k.path_next + 1]
				if not clear_line(plan, level, k.body.x, k.body.z, (c.x + 0.5) * s, (c.y + 0.5) * s):
					break
				k.path_next += 1
			var pc := k.path[k.path_next]
			wx = (pc.x + 0.5) * s
			wz = (pc.y + 0.5) * s
		var dx := wx - k.body.x
		var dz := wz - k.body.z
		var d := M.hypot2(dx, dz)
		if d <= 1e-6:
			if k.straight or k.path_next >= k.path.size() - 1:
				break
			k.path_next += 1
			continue
		var go := minf(left, d)
		var before := k.body
		k.body = Move.move_with_collision(plan, before, dx / d * go, dz / d * go, RADIUS)
		var went := _flat(k.body.x, k.body.z, before.x, before.z)
		left -= maxf(went, go * 0.5)
		if went < go * 0.25:
			break
	var mx := k.body.x - from.x
	var mz := k.body.z - from.z
	var moved := M.hypot2(mx, mz)
	k.moving = moved > 1e-9
	k.speed = moved / maxf(dt, EPS)
	if k.moving:
		k.yaw = Entity._turn_toward(k.yaw, Entity.yaw_toward(mx, mz), FACE_RATE * dt)
	k.anim = &"walk"
	if _flat(goal.x, goal.z, k.body.x, k.body.z) <= 1e-4:
		return true
	# It cannot get any nearer (a place its body does not fit): it is as there as it will be.
	k.stuck = k.stuck + 1 if moved < dist * 0.1 else 0
	return k.stuck >= 4
