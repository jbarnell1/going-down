# A run: the ride down. Pure, deterministic logic for the shape of a run and the elevator's rules;
# no rendering, audio or engine code. The game calls step_run once per logic tick.
# Port of src/sim/run.ts.
#
# The elevator is the bank, the briefing room and the only safe place. Per tick, in this order:
#   1. run rules: phase timers, the call and its indicator, light blinks, boarding, votes, the
#      bell, departures and arrivals;
#   2. the Orderly, with every player `blind` during a blink, players inside the car never
#      huntable, and (while the car is coming) the call itself as a blind target at the landing;
#   3. the crew's instruments, then pick-ups; readings that close are multiplied by the depth's pay.
#
# The car is the void 2 m cell on the far side of the landing's elevator wall (landing.gd says which
# wall). It is outside the floor plan, so nothing that moves with the plan's collision (the Orderly)
# can ever enter it; run.gd checks that anyway every tick and puts it back if it ever ended inside.
# Players get in and out through the doorway with move_in_run, which knows when the doors are open.
#
# Choices made where the design is silent (also listed in the report):
#  - Seeing out of the car: with the doors open, a player inside sees the floor as if their eyes stood
#    on the threshold (generous: it can only add sightings). With the doors shut they see nothing out.
#  - "Drawn to the call": the call is an extra blind target at the landing; the Orderly hunts the
#    nearest of it and the players by walking distance, and the pull ends once it is within
#    LURE_DROP_DISTANCE of the landing. A waiting Orderly is not woken by the call.
#  - Arrival: anyone still in the car when the arrival doors close is put out onto the landing.
#  - Caught players stay inactive until the car next RIDES DOWN (not when it leaves empty).
#  - The depth multiplier compounds and is applied when a reading closes onto a tape.
#  - Each floor's Orderly is a new subject (entity id `orderly-<depth>`), so repeat factors restart.
#  - The lights while the car comes (dark_schedule): blinks that grow, then the blackout, ending on the
#    tick the car arrives. A false stop (one floor above, in the last few seconds) always falls inside
#    the blackout: it is heard in the dark, and the blackout still ends as the doors really open.
#  - In the blackout the Orderly hunts at BLACKOUT_HUNT_SPEED and does not creep up on still prey (the
#    creep is there so a recorder can time a turn; nobody can see to do that in the dark). In the
#    short blinks it hunts exactly as before.
#  - BANK is the left half of the car as you walk in, DOWN the right half.
#
# Events are Dictionaries with the TypeScript shapes (see RunEvent in run.ts), carrying Move.Body,
# TapeLib.Reading and RunSummary objects where TypeScript carries those objects.
extends RefCounted

const Entity = preload("res://sim/entity.gd")
const Clinic = preload("res://sim/clinic.gd")
const Floor = preload("res://sim/floor.gd")
const Instr = preload("res://sim/instrument.gd")
const Landing = preload("res://sim/landing.gd")
const Move = preload("res://sim/move.gd")
const Rng = preload("res://sim/rng.gd")
const TapeLib = preload("res://sim/tape.gd")
const M = preload("res://sim/jsmath.gd")

# ---------------------------------------------------------------------------------------------
# Tuning.

## Width of the car along the elevator wall, metres (one cell).
const CAR_WIDTH := 2.0
## Depth of the car away from the landing, metres (one cell).
const CAR_DEPTH := 2.0
## Width of the door opening, centred on the landing cell's elevator wall, metres.
const CAR_DOOR_WIDTH := 1.2
## Seconds the car sits with its doors shut on arrival before they open.
const ARRIVE_DOOR_DELAY := 1.0
## On arrival the doors close this long after the last active player stepped out (seconds)...
const UNLOAD_EMPTY_CLOSE := 2.0
## ...or after this long regardless (seconds); then the car leaves. It is not waiting for you.
const UNLOAD_TIME := 12.0
## A player whose feet are within this distance (metres) of the door's centre can call the car.
const CALL_REACH := 2.2
## Seconds between the call and the car starting to move (drawn per call, uniform).
const CALL_START_DELAY_MIN := 1.0
const CALL_START_DELAY_MAX := 3.0
## How many floors away the car starts (drawn per call, never the same as the previous call).
const CALL_FLOORS_MIN := 6
const CALL_FLOORS_MAX := 12
## Seconds per floor on the indicator. Constant, so a player can read the wait: floors x 4 s.
const FLOOR_TIME := 4.0
## Chance per call that the car stops one floor above first.
const FALSE_STOP_CHANCE := 0.25
## Extra seconds a false stop costs (drawn per call, uniform).
const FALSE_STOP_EXTRA_MIN := 3.5
const FALSE_STOP_EXTRA_MAX := 5.0
## During a false stop, doors are heard opening this long after the chime (seconds)...
const FALSE_STOP_DOORS_OPEN_AT := 0.8
## ...and heard closing this long before the car moves on (seconds).
const FALSE_STOP_DOORS_CLOSE_BEFORE := 1.2
## The lights while the car is coming (see dark_schedule): blinks that grow, then the blackout that ends
## as the doors open. Blink lengths in order (seconds); a short wait uses only the first few.
const BLINK_LADDER: Array[float] = [1.0, 1.5, 2.5, 4.0, 6.0]
## The lit gap after each blink, before the next warning (seconds, drawn uniform per gap), nearest the
## blackout first: the gaps shrink as the blackout nears. Spare time in a long wait stretches them
## (each to at most BLINK_GAP_STRETCH_MAX).
const BLINK_GAPS: Array[Array] = [[3.0, 4.0], [3.5, 4.5], [4.0, 5.0], [4.5, 5.5], [5.0, 6.0]]
const BLINK_GAP_STRETCH_MAX := 9.0
## The first warning comes no sooner than this after the call (seconds).
const BLINK_FIRST_AFTER := 2.5
## How far ahead of a blink the game is told, so the screen and sound can telegraph it (seconds).
const BLINK_WARNING := 0.6
## The blackout: the last dark stretch of a wait, ending as the car's doors open (seconds, uniform)...
const BLACKOUT_MIN := 12.0
const BLACKOUT_MAX := 15.0
## ...shorter on the first floor of a run...
const BLACKOUT_FIRST_MIN := 9.0
const BLACKOUT_FIRST_MAX := 10.0
## ...and its warning, long and unmistakable (seconds).
const BLACKOUT_WARNING := 3.0
## The Orderly's hunting speed while the blackout is on (m/s; see entity.gd HUNT_SPEED).
const BLACKOUT_HUNT_SPEED := Entity.HUNT_SPEED
## The boarding window: seconds from the doors opening to the bell, not counting holds.
const BOARD_TIME := 20.0
## Total seconds the doors can be held per stop.
const HOLD_LIMIT := 15.0
## Seconds the ride down takes, doors shut.
const RIDE_TIME := 6.0
## Pay multiplier per floor of depth: readings closed at depth d are worth DEPTH_PAY_STEP^(d-1).
const DEPTH_PAY_STEP := 1.35
## The call stops pulling the Orderly once its centre is within this distance (metres) of the landing's centre.
const LURE_DROP_DISTANCE := 3.0
## Longest tick step_run takes in one go (seconds); longer dt is split. Keeps the lure provably uncatchable.
const MAX_TICK := 0.1
## Id the call uses as a target in the Orderly's player list. Never a real player id.
const LURE_ID := "#call"

const EPS := 1e-9
## How far onto the landing side of the wall line the doorway channel reaches, beyond a body's radius.
const DOOR_ZONE_SLACK := 0.01

# ---------------------------------------------------------------------------------------------
# The car.

class Rect:
	var x0: float
	var z0: float
	var x1: float
	var z1: float

## Where the car is, in world metres. Local coordinates: u is the distance past the wall line into the
## car (0 at the doors, CAR_DEPTH at the back), v is sideways, positive to the right as you walk in.
class CarGeometry:
	## Which side of the landing cell the doors are on.
	var wall: StringName
	var level: int
	## Height of the car floor. (TypeScript: floorY)
	var floor_y: float
	## Centre of the door opening on the wall line. (TypeScript: doorX, doorZ)
	var door_x: float
	var door_z: float
	## Unit vector from the landing into the car, and the unit vector to the right walking in.
	var in_x: float
	var in_z: float
	var right_x: float
	var right_z: float
	var width: float
	var depth: float
	var door_width: float  # TypeScript: doorWidth
	## The car's floor as an axis-aligned rectangle (it is one plan cell).
	var rect: Rect
	## The BANK half (left walking in) and the DOWN half (right walking in).
	var bank: Rect
	var down: Rect

static func _rect_of(points: Array[PackedFloat64Array]) -> Rect:
	var r := Rect.new()
	r.x0 = INF
	r.z0 = INF
	r.x1 = -INF
	r.z1 = -INF
	for p in points:
		r.x0 = minf(r.x0, p[0])
		r.z0 = minf(r.z0, p[1])
		r.x1 = maxf(r.x1, p[0])
		r.z1 = maxf(r.z1, p[1])
	return r

static func _car_at(c: CarGeometry, u: float, w: float) -> PackedFloat64Array:
	return PackedFloat64Array([c.door_x + c.in_x * u + c.right_x * w, c.door_z + c.in_z * u + c.right_z * w])

## The car for a floor plan.
static func car_geometry(plan: Floor.FloorPlan) -> CarGeometry:
	var wall := Landing.elevator_wall(plan)
	if wall == &"":
		wall = &"n"
	var vx := float(Floor.dir_dx(wall))
	var vy := float(Floor.dir_dy(wall))
	var s := float(plan.cell_size)
	var c := CarGeometry.new()
	c.wall = wall
	c.level = plan.landing.level
	c.floor_y = Move.LEVEL_HEIGHT if c.level == 1 else 0.0
	c.door_x = (plan.landing.x + 0.5) * s + vx * (s / 2.0)
	c.door_z = (plan.landing.y + 0.5) * s + vy * (s / 2.0)
	c.in_x = vx
	c.in_z = vy
	# Right as you face (in_x, in_z), three.js style top-down: facing -z, right is +x.
	c.right_x = -c.in_z
	c.right_z = c.in_x
	var hw := CAR_WIDTH / 2.0
	c.width = CAR_WIDTH
	c.depth = CAR_DEPTH
	c.door_width = CAR_DOOR_WIDTH
	c.rect = _rect_of([_car_at(c, 0.0, -hw), _car_at(c, CAR_DEPTH, hw)])
	c.bank = _rect_of([_car_at(c, 0.0, -hw), _car_at(c, CAR_DEPTH, 0.0)])
	c.down = _rect_of([_car_at(c, 0.0, 0.0), _car_at(c, CAR_DEPTH, hw)])
	return c

## World position to car-local: Vector of (u into the car, v to the right), as [u, v].
static func car_local(car: CarGeometry, x: float, z: float) -> PackedFloat64Array:
	var dx := x - car.door_x
	var dz := z - car.door_z
	return PackedFloat64Array([dx * car.in_x + dz * car.in_z, dx * car.right_x + dz * car.right_z])

## A body standing at car-local (u, v).
static func car_body(car: CarGeometry, u: float, v: float) -> Move.Body:
	return Move.Body.make(car.door_x + car.in_x * u + car.right_x * v, car.door_z + car.in_z * u + car.right_z * v, car.level, car.floor_y)

## Whether a body's centre is inside the car.
static func in_car(car: CarGeometry, b: Move.Body) -> bool:
	if b.level != car.level:
		return false
	var l := car_local(car, b.x, b.z)
	return l[0] > 0.0 and l[0] <= car.depth + EPS and absf(l[1]) <= car.width / 2.0 + EPS

## Which half of the car a body stands on (&"bank" or &"down"), or null if it is not inside.
static func car_side(car: CarGeometry, b: Move.Body) -> Variant:
	if not in_car(car, b):
		return null
	return &"bank" if car_local(car, b.x, b.z)[1] < 0.0 else &"down"

## Spawn spots inside the car, by player index.
static func _car_slot(car: CarGeometry, i: int) -> Move.Body:
	var us: Array[float] = [0.7, 0.7, 1.4, 1.4]
	var vs: Array[float] = [-0.5, 0.5, -0.5, 0.5]
	return car_body(car, us[i % 4], vs[i % 4])

## Spots on the landing just outside the doors, by index.
static func _landing_slot(car: CarGeometry, i: int) -> Move.Body:
	var vs: Array[float] = [-0.5, 0.5, -0.1, 0.3]
	return car_body(car, -0.8 - 0.3 * floorf(i / 4.0), vs[i % vs.size()])

# ---------------------------------------------------------------------------------------------
# The call schedule.

## One dark stretch of a wait. Times in seconds after the call.
class DarkStretch:
	## When the lights go out.
	var at: float
	## How long they stay out (the blackout's ends as the car arrives: at + len == wait).
	var len: float
	## How long before `at` the warning starts.
	var warn: float
	## The last and longest: the blackout.
	var blackout: bool

	static func make(at_: float, len_: float, warn_: float, blackout_: bool) -> DarkStretch:
		var d := DarkStretch.new()
		d.at = at_
		d.len = len_
		d.warn = warn_
		d.blackout = blackout_
		return d

class CallPlan:
	## Seconds before the car starts moving.
	var delay: float
	## Floors away it starts.
	var floors: int
	var false_stop: bool  # TypeScript: falseStop
	## Extra seconds the false stop costs (0 without one).
	var extra: float
	## Total seconds from the call to the car arriving.
	var wait: float
	## The dark stretches of this wait, in order; the last is the blackout.
	var darks: Array[DarkStretch] = []

## The schedule of the `index`-th call of a run (0-based) at `depth`. Never starts from `prev_floors`
## floors away (pass -1 for none: TypeScript null).
static func call_plan(seed: String, index: int, prev_floors: int, depth: int = 1) -> CallPlan:
	var rng := Rng.make_rng(seed).fork("call:%d" % index)
	var p := CallPlan.new()
	p.delay = CALL_START_DELAY_MIN + rng.next() * (CALL_START_DELAY_MAX - CALL_START_DELAY_MIN)
	var floors := rng.int_in(CALL_FLOORS_MIN, CALL_FLOORS_MAX)
	if floors == prev_floors:
		floors = CALL_FLOORS_MIN if floors == CALL_FLOORS_MAX else floors + 1
	p.floors = floors
	p.false_stop = rng.chance(FALSE_STOP_CHANCE)
	p.extra = FALSE_STOP_EXTRA_MIN + rng.next() * (FALSE_STOP_EXTRA_MAX - FALSE_STOP_EXTRA_MIN) if p.false_stop else 0.0
	p.wait = p.delay + floors * FLOOR_TIME + p.extra
	p.darks = dark_schedule(seed, index, p.wait, depth)
	return p

static func _need(gaps: Array[float], n: int) -> float:
	var s := 0.0
	for k in n:
		s += (BLINK_LADDER[k] + BLINK_WARNING) + gaps[k]
	return s

## The lights of one wait, laid out when the car is called, from the run's seed alone. The last dark
## stretch is the blackout: BLACKOUT_MIN..MAX seconds (less on the first floor), ending exactly when the
## car arrives, after a BLACKOUT_WARNING warning. Before it, blinks of BLINK_LADDER lengths, each longer
## than the last, with lit gaps that shrink toward the blackout. As many blinks as fit after
## BLINK_FIRST_AFTER (a short wait gets fewer, never no blackout); spare time stretches the gaps
## and delays the first blink.
## Every wait draws the same seven numbers, whatever fits.
static func dark_schedule(seed: String, index: int, wait: float, depth: int) -> Array[DarkStretch]:
	var rng := Rng.make_rng(seed).fork("call:%d:dark" % index)
	var lo := BLACKOUT_FIRST_MIN if depth <= 1 else BLACKOUT_MIN
	var hi := BLACKOUT_FIRST_MAX if depth <= 1 else BLACKOUT_MAX
	var black := minf(lo + rng.next() * (hi - lo), maxf(1.0, wait - BLACKOUT_WARNING))
	var gaps: Array[float] = []
	for g: Array in BLINK_GAPS:
		var a: float = g[0]
		var b: float = g[1]
		gaps.append(a + rng.next() * (b - a))
	# Of any spare time, this share (up to half) goes before the first blink, the rest into the gaps.
	var lead := rng.next() * 0.5
	var black_at := wait - black
	var room := black_at - BLACKOUT_WARNING - BLINK_FIRST_AFTER
	var n := BLINK_LADDER.size()
	while n > 0 and _need(gaps, n) > room + 1e-9:
		n -= 1
	# Spare time stretches the gaps evenly (each capped), so a long wait keeps its blinks spread out.
	var spare := room - _need(gaps, n)
	var stretch := (spare * (1.0 - lead)) / n if n > 0 else 0.0
	var gap: Array[float] = []
	for k in n:
		gap.append(minf(BLINK_GAP_STRETCH_MAX, gaps[k] + stretch))
	var out: Array[DarkStretch] = [DarkStretch.make(black_at, black, BLACKOUT_WARNING, true)]
	var cursor := black_at - BLACKOUT_WARNING
	# Backwards from the blackout: the longest blink nearest it.
	for k in range(n - 1, -1, -1):
		var length := BLINK_LADDER[k]
		var end := cursor - gap[n - 1 - k]
		var at := end - length
		out.push_front(DarkStretch.make(at, length, BLINK_WARNING, false))
		cursor = at - BLINK_WARNING
	return out

## Readings closed at this depth are worth this many times their recorded value.
## (TypeScript writes DEPTH_PAY_STEP ** n; see rate_at in instrument.gd about pow.)
static func depth_multiplier(depth: int) -> float:
	return M.pow_js(DEPTH_PAY_STEP, float(maxi(0, depth - 1)))

# ---------------------------------------------------------------------------------------------
# Types.

# RunPhase: 'arriving' (car here, doors shut, about to open onto the floor) | 'unloading' (doors
# open on arrival; they close once everyone is out or after UNLOAD_TIME) | 'away' (car gone; it
# must be called) | 'coming' (called and on its way) | 'boarding' (doors open, the bell is
# counting) | 'riding' (doors shut, going down) | 'ended'
# PlayerStatus: 'ok' | 'caught' | 'leftBehind'

class RunPlayer:
	var id: String
	## Where the run last knew them (from the inputs, or where it placed them).
	var body: Move.Body
	var status: StringName = &"ok"
	## Inside the car this tick.
	var aboard: bool = false
	## Their vote: the half of the car they stand on (null when not aboard or not active).
	var side: Variant = null

	func copy() -> RunPlayer:
		var p := RunPlayer.new()
		p.id = id
		p.body = body
		p.status = status
		p.aboard = aboard
		p.side = side
		return p

class CallState:
	var index: int
	## Run time of the call.
	var at: float
	var plan: CallPlan
	## What the indicator shows: floors away. (TypeScript: floorsAway)
	var floors_away: int
	## Run time the indicator next changes (or the car arrives). (TypeScript: nextAt)
	var next_at: float
	## False stop in progress: run time it ends (or null), and which of its sounds have played.
	var stop_until: Variant = null  # TypeScript: stopUntil
	var stop_doors_opened: bool = false  # TypeScript: stopDoorsOpened
	var stop_doors_closed: bool = false  # TypeScript: stopDoorsClosed

	func copy() -> CallState:
		var c := CallState.new()
		c.index = index
		c.at = at
		c.plan = plan
		c.floors_away = floors_away
		c.next_at = next_at
		c.stop_until = stop_until
		c.stop_doors_opened = stop_doors_opened
		c.stop_doors_closed = stop_doors_closed
		return c

class BlinkState:
	var call_index: int  # TypeScript: callIndex
	## Blink number within the call.
	var n: int
	## Run time this blink starts.
	var at: float
	## Seconds it lasts (the blackout's is nominal: it ends when the car arrives).
	var len: float
	## Seconds of warning before `at`.
	var warn: float
	## The wait's last dark stretch: the blackout.
	var blackout: bool
	var announced: bool = false
	## Run time it ends once started, else null. (TypeScript: endsAt)
	var ends_at: Variant = null

	func copy() -> BlinkState:
		var b := BlinkState.new()
		b.call_index = call_index
		b.n = n
		b.at = at
		b.len = len
		b.warn = warn
		b.blackout = blackout
		b.announced = announced
		b.ends_at = ends_at
		return b

class RunSummary:
	## Deepest floor reached.
	var depth: int
	## Readings on the banked tapes.
	var readings: int
	var total: float
	## Each player's share: the total split evenly between everyone in the run (insertion-ordered).
	var shares: Dictionary = {}
	## Tapes banked.
	var tapes: Array[String] = []
	var wiped: bool

class RunState:
	var seed: String
	## Run time, seconds.
	var t: float = 0.0
	var depth: int = 1
	var plan: Floor.FloorPlan
	var car: CarGeometry
	var orderly: Entity.OrderlyState
	## Entity id of this floor's Orderly. (TypeScript: entityId)
	var entity_id: String
	var crew: Instr.CrewState
	var players: Array[RunPlayer] = []
	var phase: StringName = &"arriving"
	## Seconds left in a timed phase (arriving, unloading, riding).
	var timer: float = 0.0
	## Unloading: seconds the car has been empty of active players. (TypeScript: emptyFor)
	var empty_for: float = 0.0
	var calls: int = 0
	## TypeScript: lastFloors (null before the first call: -1 here).
	var last_floors: int = -1
	var call: CallState = null
	var blink: BlinkState = null
	## The Orderly is being pulled toward the landing by the call.
	var lure: bool = false
	## Boarding: seconds of boarding window left, hold seconds left, whether the doors are held.
	var bell_left: float = 0.0  # TypeScript: bellLeft
	var hold_left: float = 0.0  # TypeScript: holdLeft
	var held: bool = false
	## Set when the run ends (banked or wiped).
	var summary: RunSummary = null

	func copy() -> RunState:
		var s := RunState.new()
		s.seed = seed
		s.t = t
		s.depth = depth
		s.plan = plan
		s.car = car
		s.orderly = orderly
		s.entity_id = entity_id
		s.crew = crew
		s.players = players
		s.phase = phase
		s.timer = timer
		s.empty_for = empty_for
		s.calls = calls
		s.last_floors = last_floors
		s.call = call
		s.blink = blink
		s.lure = lure
		s.bell_left = bell_left
		s.hold_left = hold_left
		s.held = held
		s.summary = summary
		return s

class PlayerInput:
	var id: String
	var body: Move.Body
	## Eye height above the feet, yaw/pitch three.js style, full fields of view in degrees.
	var eye: float
	var yaw: float
	var pitch: float
	var h_fov_deg: float
	var v_fov_deg: float
	## Pressing the call button.
	var call: bool = false
	## Holding the doors (only counts from inside the car while boarding). (TypeScript: holdDoors)
	var hold_doors: bool = false
	## Instrument raised: true, false, or null for "not said" (TypeScript: undefined).
	var raised: Variant = null
	## Pick up a tape: its id (String), true for the nearest one within reach, or null.
	var pick_up: Variant = null  # TypeScript: pickUp
	## Sees nothing this tick, though present and huntable (the host's call).
	var blind: bool = false

	static func make(id_: String, body_: Move.Body, eye_: float, yaw_: float, pitch_: float, h_fov: float, v_fov: float) -> PlayerInput:
		var p := PlayerInput.new()
		p.id = id_
		p.body = body_
		p.eye = eye_
		p.yaw = yaw_
		p.pitch = pitch_
		p.h_fov_deg = h_fov
		p.v_fov_deg = v_fov
		return p

class RunStep:
	var state: RunState
	var events: Array[Dictionary] = []

# ---------------------------------------------------------------------------------------------
# Creating a run.

class _FloorFor:
	var plan: Floor.FloorPlan
	var car: CarGeometry
	var orderly: Entity.OrderlyState
	var entity_id: String

static func _floor_for(seed: String, depth: int) -> _FloorFor:
	var f := _FloorFor.new()
	f.plan = Clinic.generate_clinic(seed, depth)
	f.car = car_geometry(f.plan)
	f.orderly = Entity.create_orderly(f.plan)
	f.entity_id = "orderly-%d" % depth
	return f

## A new run: the crew in the car at floor 1's landing, doors about to open.
static func create_run(seed: String, player_ids: Array[String]) -> RunState:
	assert(not player_ids.is_empty(), "a run needs at least one player")
	var f := _floor_for(seed, 1)
	var s := RunState.new()
	s.seed = seed
	s.t = 0.0
	s.depth = 1
	s.plan = f.plan
	s.car = f.car
	s.orderly = f.orderly
	s.entity_id = f.entity_id
	s.crew = Instr.create_crew(player_ids)
	for i in player_ids.size():
		var p := RunPlayer.new()
		p.id = player_ids[i]
		p.body = _car_slot(f.car, i)
		p.status = &"ok"
		p.aboard = true
		p.side = null
		s.players.append(p)
	s.phase = &"arriving"
	s.timer = ARRIVE_DOOR_DELAY
	return s

## Whether the car's doors are open at this floor's landing.
static func doors_open(state: RunState) -> bool:
	return state.phase == &"unloading" or state.phase == &"boarding"

## Whether every player is blind this tick (a blink is on).
static func blinking(state: RunState) -> bool:
	return state.blink != null and state.blink.ends_at != null

## Whether the blackout (the wait's last, long dark) is on this tick.
static func blacked_out(state: RunState) -> bool:
	return blinking(state) and state.blink.blackout

## The `n`-th dark stretch of a call as run state (unannounced), or null past the last.
static func _blink_of(call: CallState, n: int) -> BlinkState:
	if n >= call.plan.darks.size():
		return null
	var d := call.plan.darks[n]
	var b := BlinkState.new()
	b.call_index = call.index
	b.n = n
	b.at = call.at + d.at
	b.len = d.len
	b.warn = d.warn
	b.blackout = d.blackout
	b.announced = false
	b.ends_at = null
	return b

# ---------------------------------------------------------------------------------------------
# Moving bodies with the car in mind.

## Moves a player's body by (dx, dz) like move_with_collision, except that the car's doorway is open
## while the doors are, and inside the car the car's walls hold. A body caught in the doorway when
## the doors shut is pushed to whichever side its centre is on.
static func move_in_run(state: RunState, body: Move.Body, dx: float, dz: float, radius: float) -> Move.Body:
	var dist := M.hypot2(dx, dz)
	var n := maxi(1, int(ceil(dist / 0.05)))
	var cur := body
	var open := doors_open(state)
	for _i in n:
		cur = _move_step(state.plan, state.car, open, cur, dx / n, dz / n, radius)
	return cur

static func _clamp(x: float, lo: float, hi: float) -> float:
	return maxf(lo, minf(hi, x))

static func _move_step(plan: Floor.FloorPlan, car: CarGeometry, open: bool, cur: Move.Body, sx: float, sz: float, r: float) -> Move.Body:
	if cur.level != car.level:
		return Move.move_with_collision(plan, cur, sx, sz, r)
	var here := car_local(car, cur.x, cur.z)
	var next := car_local(car, cur.x + sx, cur.z + sz)
	var band := car.door_width / 2.0 - r
	var out := -(r + DOOR_ZONE_SLACK)
	var here_in_channel := here[0] > out and absf(here[1]) <= band + EPS
	var next_in_channel := next[0] > out and absf(next[1]) <= band + EPS
	var zone := here[0] > 0.0 or here_in_channel
	if not zone:
		if open and next_in_channel:
			return car_body(car, next[0], next[1])
		return Move.move_with_collision(plan, cur, sx, sz, r)
	var inside_v := car.width / 2.0 - r
	var max_u := car.depth - r
	if open and absf(next[1]) <= band + EPS:
		return car_body(car, minf(next[0], max_u), next[1])
	if here[0] > 0.0:
		# Inside: the car's walls hold. In the open doorway, slide along it; otherwise stay clear of the front wall.
		if open and here[0] < r:
			return car_body(car, minf(next[0], max_u), _clamp(next[1], -band, band))
		return car_body(car, _clamp(next[0], r, max_u), _clamp(next[1], -inside_v, inside_v))
	# On the landing side of the doorway with the doors shut (or stepping sideways out of the gap): back out.
	return car_body(car, minf(next[0], out - 0.001), _clamp(next[1], -inside_v, inside_v))

# ---------------------------------------------------------------------------------------------
# Helpers.

static func _view_of(inp: PlayerInput, active: bool, blind: bool) -> Entity.PlayerView:
	return Entity.PlayerView.make(inp.id, inp.body, inp.eye, inp.yaw, inp.pitch, inp.h_fov_deg, inp.v_fov_deg, active, blind)

## The view a player inside the car has of the floor: eyes moved onto the threshold.
static func _threshold_view(car: CarGeometry, inp: PlayerInput) -> Entity.PlayerView:
	var v := car_local(car, inp.body.x, inp.body.z)[1]
	var at := car_body(car, -0.02, _clamp(v, -car.door_width / 2.0, car.door_width / 2.0))
	var body := Move.Body.make(at.x, at.z, at.level, inp.body.y)
	return Entity.PlayerView.make(inp.id, body, inp.eye, inp.yaw, inp.pitch, inp.h_fov_deg, inp.v_fov_deg, true, false)

## Distance from a point to a rectangle (0 inside).
static func rect_distance(r: Rect, x: float, z: float) -> float:
	var dx := maxf(maxf(r.x0 - x, 0.0), x - r.x1)
	var dz := maxf(maxf(r.z0 - z, 0.0), z - r.z1)
	return M.hypot2(dx, dz)

static func _scaled(tape: TapeLib.Tape, ids: Dictionary, mult: float) -> TapeLib.Tape:
	var any := false
	for r in tape.readings:
		if ids.has(r.id):
			any = true
	if not any:
		return tape
	var t := tape.copy()
	t.readings = []
	var total := 0.0
	for r in tape.readings:
		var nr := r
		if ids.has(r.id):
			nr = r.copy()
			nr.value = r.value * mult
			nr.peak_rate = r.peak_rate * mult
		t.readings.append(nr)
		total = total + nr.value
	t.total = total
	return t

## Every tape held by members, carried, or on the floor, with readings scaled by id.
static func _scale_readings(crew: Instr.CrewState, ids: Dictionary, mult: float) -> Instr.CrewState:
	if ids.is_empty() or mult == 1.0:
		return crew
	var c := crew.copy()
	c.members = []
	for m in crew.members:
		var nm := m.copy()
		nm.tape = _scaled(m.tape, ids, mult)
		nm.carrying = []
		for tp in m.carrying:
			nm.carrying.append(_scaled(tp, ids, mult))
		c.members.append(nm)
	c.floor = []
	for f in crew.floor:
		c.floor.append(Instr.FloorTape.make(_scaled(f.tape, ids, mult), f.at))
	return c

## step_crew, with closed readings multiplied by the depth's pay (tapes and events both).
static func _crew_tick(s: RunState, players: Array[Instr.CrewPlayer], entities: Array[Instr.EntityTick], dt: float) -> Instr.CrewStep:
	var out := Instr.step_crew(s.plan, s.crew, players, entities, dt)
	var mult := depth_multiplier(s.depth)
	var ids := {}
	for e in out.events:
		if e["type"] == "readingClosed":
			ids[(e["reading"] as TapeLib.Reading).id] = true
	if ids.is_empty() or mult == 1.0:
		return out
	var events: Array[Dictionary] = []
	for e in out.events:
		if e["type"] == "readingClosed":
			var ne := e.duplicate()
			ne["value"] = float(e["value"]) * mult
			var rd := (e["reading"] as TapeLib.Reading).copy()
			rd.value = rd.value * mult
			rd.peak_rate = rd.peak_rate * mult
			ne["reading"] = rd
			events.append(ne)
		else:
			events.append(e)
	var res := Instr.CrewStep.new()
	res.crew = _scale_readings(out.crew, ids, mult)
	res.events = events
	return res

static func _held_tapes(m: Instr.CrewMember) -> Array[TapeLib.Tape]:
	var out: Array[TapeLib.Tape] = []
	for tp: TapeLib.Tape in [m.tape] + m.carrying:
		if not tp.readings.is_empty():
			out.append(tp)
	return out

static func _summarize(s: RunState, tapes: Array[TapeLib.Tape], wiped: bool) -> RunSummary:
	var r := RunSummary.new()
	r.depth = s.depth
	r.total = 0.0 if wiped else TapeLib.tape_value(tapes)
	var share := r.total / s.players.size()
	var n := 0
	for tp in tapes:
		n += tp.readings.size()
	r.readings = 0 if wiped else n
	for p in s.players:
		r.shares[p.id] = share
	if not wiped:
		for tp in tapes:
			r.tapes.append(tp.id)
	r.wiped = wiped
	return r

static func _with_t(e: Dictionary, t: float) -> Dictionary:
	var ne := e.duplicate()
	ne["t"] = t
	return ne

# ---------------------------------------------------------------------------------------------
# The tick.

## Advances the run by dt seconds. Never mutates `prev`. Inputs for unknown ids are ignored.
static func step_run(prev: RunState, inputs: Array[PlayerInput], dt: float) -> RunStep:
	if dt > MAX_TICK + EPS:
		var n := int(ceil(dt / MAX_TICK - EPS))
		var state := prev
		var out := RunStep.new()
		for _i in n:
			var r := _step_once(state, inputs, dt / n)
			state = r.state
			out.events.append_array(r.events)
		out.state = state
		return out
	return _step_once(prev, inputs, dt)

## The lights. Blinks run on their own clock: once announced, a blink always happens, even after the
## car arrives (the schedule ends each one before the blackout, so that does not happen). The blackout
## ends when the car arrives, on the tick its doors open.
static func _step_blink(s: RunState, t: float, events: Array[Dictionary]) -> void:
	var b := s.blink
	if b == null:
		return
	if not b.announced and t >= b.at - b.warn - EPS:
		# While the car is coming, or later if it was already scheduled to be announced before arrival.
		if s.phase != &"coming":
			s.blink = null
			return
		var nb := b.copy()
		nb.announced = true
		s.blink = nb
		events.append({"type": "blinkSoon", "t": t, "at": b.at, "len": b.len, "blackout": b.blackout})
	var c := s.blink
	if c != null and c.announced and c.ends_at == null and t >= c.at - EPS:
		var nc := c.copy()
		nc.ends_at = t + c.len
		s.blink = nc
		events.append({"type": "blinkStart", "t": t, "len": c.len, "blackout": c.blackout})
	var d := s.blink
	if d != null and d.ends_at != null and ((s.phase != &"coming") if d.blackout else (t >= float(d.ends_at) - EPS)):
		events.append({"type": "blinkEnd", "t": t, "blackout": d.blackout})
		s.blink = _blink_of(s.call, d.n + 1) if (s.phase == &"coming" and s.call != null) else null

static func _step_once(prev: RunState, inputs: Array[PlayerInput], dt: float) -> RunStep:
	var res := RunStep.new()
	if prev.phase == &"ended":
		var ended := prev.copy()
		ended.t = prev.t + dt
		res.state = ended
		return res
	var t := prev.t + dt
	var s := prev.copy()
	s.t = t
	res.state = s
	var events := res.events
	var car := s.car

	# Each player's input this tick; players without one stay where they were, inactive.
	var input_of := {}
	for inp in inputs:
		input_of[inp.id] = inp

	var players: Array[RunPlayer] = []
	for p in prev.players:
		var np := p.copy()
		var given: PlayerInput = input_of.get(p.id)
		np.body = given.body if given != null else p.body
		np.aboard = in_car(car, np.body)
		players.append(np)

	# ---- 1. Run rules.
	match s.phase:
		&"arriving":
			s.timer -= dt
			if s.timer <= EPS:
				s.phase = &"unloading"
				s.timer = UNLOAD_TIME
				s.empty_for = 0.0
				events.append({"type": "doorsOpened", "t": t, "depth": s.depth, "reason": "arrival"})
		&"unloading":
			s.timer -= dt
			s.empty_for = s.empty_for + dt if _active_aboard(players, input_of).is_empty() else 0.0
			if s.empty_for >= UNLOAD_EMPTY_CLOSE - EPS or s.timer <= EPS:
				var pushed_out := {}
				var k := 0
				for i in players.size():
					var p := players[i]
					if not p.aboard:
						continue
					var body := _landing_slot(car, k)
					k += 1
					pushed_out[p.id] = body
					var np := p.copy()
					np.body = body
					np.aboard = false
					players[i] = np
				s.phase = &"away"
				events.append({"type": "doorsClosed", "t": t, "aboard": [], "pushedOut": pushed_out})
				events.append({"type": "carLeft", "t": t, "reason": "unloaded"})
		&"away":
			var caller: RunPlayer = null
			for p in players:
				if _is_active(p, input_of) and not p.aboard and _inp(p, input_of).call \
					and M.hypot2(p.body.x - car.door_x, p.body.z - car.door_z) <= CALL_REACH + EPS and p.body.level == car.level:
					caller = p
					break
			if caller != null:
				var index := s.calls
				var plan := call_plan(s.seed, index, s.last_floors, s.depth)
				s.calls = index + 1
				s.last_floors = plan.floors
				var c := CallState.new()
				c.index = index
				c.at = t
				c.plan = plan
				c.floors_away = plan.floors
				c.next_at = t + plan.delay + FLOOR_TIME
				s.call = c
				s.phase = &"coming"
				s.lure = true
				# The call is loud. If the Orderly was still standing where the floor began, it wakes now.
				if s.orderly.mode == &"waiting":
					var o := s.orderly.copy()
					o.mode = &"hunting"
					o.replan_in = 0.0
					s.orderly = o
					events.append({"type": "startedHunting", "t": t})
				s.blink = _blink_of(s.call, 0)
				events.append({"type": "called", "t": t, "playerId": caller.id, "floorsAway": plan.floors, "at": caller.body})
				events.append({"type": "indicator", "t": t, "floorsAway": plan.floors, "floor": s.depth - plan.floors})
		&"coming":
			var c: CallState = s.call
			if c != null:
				# The indicator, floor by floor; the false stop one floor above.
				for _guard in 64:
					if c.stop_until != null:
						var stop: float = c.stop_until
						if not c.stop_doors_opened and t >= stop - c.plan.extra + FALSE_STOP_DOORS_OPEN_AT - EPS:
							c = c.copy()
							c.stop_doors_opened = true
							events.append({"type": "falseStopDoors", "t": t, "open": true})
						if not c.stop_doors_closed and t >= stop - FALSE_STOP_DOORS_CLOSE_BEFORE - EPS:
							c = c.copy()
							c.stop_doors_closed = true
							events.append({"type": "falseStopDoors", "t": t, "open": false})
						if t < stop - EPS:
							break
						c = c.copy()
						c.next_at = stop + FLOOR_TIME
						c.stop_until = null
						continue
					if t < c.next_at - EPS:
						break
					var floors_away := c.floors_away - 1
					events.append({"type": "indicator", "t": t, "floorsAway": floors_away, "floor": s.depth - floors_away})
					if floors_away == 1 and c.plan.false_stop:
						c = c.copy()
						c.floors_away = floors_away
						c.stop_until = c.next_at + c.plan.extra
						events.append({"type": "falseStop", "t": t, "extra": c.plan.extra})
						continue
					c = c.copy()
					c.floors_away = floors_away
					c.next_at = c.next_at + FLOOR_TIME
					if floors_away <= 0:
						break
				s.call = c
				if c.floors_away <= 0:
					s.phase = &"boarding"
					s.lure = false
					s.bell_left = BOARD_TIME
					s.hold_left = HOLD_LIMIT
					s.held = false
					events.append({"type": "carArrived", "t": t, "wait": t - c.at})
					events.append({"type": "doorsOpened", "t": t, "depth": s.depth, "reason": "boarding"})
					s.call = null
		&"boarding":
			var aboard := _active_aboard(players, input_of)
			var any_hold := false
			for p in aboard:
				if _inp(p, input_of).hold_doors:
					any_hold = true
					break
			var holding := s.hold_left > EPS and any_hold
			if holding != s.held:
				s.held = holding
				events.append({"type": "holdChanged", "t": t, "held": holding, "holdLeft": s.hold_left})
			if holding:
				s.hold_left = maxf(0.0, s.hold_left - dt)
				if s.hold_left <= EPS:
					s.held = false
					events.append({"type": "holdChanged", "t": t, "held": false, "holdLeft": 0.0})
			else:
				s.bell_left -= dt
		&"riding":
			s.timer -= dt
	_step_blink(s, t, events)

	# Votes: the half of the car each active player stands on, while boarding and before the bell.
	if s.phase == &"boarding":
		for i in players.size():
			var p := players[i]
			var side: Variant = car_side(car, p.body) if _is_active(p, input_of) else null
			if side != p.side:
				events.append({"type": "voteChanged", "t": t, "playerId": p.id, "side": side})
			var np := p.copy()
			np.side = side
			players[i] = np

	# The bell: count, close the doors, and go (or not).
	var departing := &""
	if s.phase == &"boarding" and s.bell_left <= EPS:
		var aboard := _active_aboard(players, input_of)
		var bank := 0
		var down := 0
		for p in aboard:
			if p.side == &"bank":
				bank += 1
			elif p.side == &"down":
				down += 1
		var outcome := "empty" if aboard.is_empty() else ("bank" if bank > down else "ride")
		events.append({"type": "bell", "t": t, "bank": bank, "down": down, "outcome": outcome})
		var ids: Array = []
		for p in aboard:
			ids.append(p.id)
		events.append({"type": "doorsClosed", "t": t, "aboard": ids, "pushedOut": {}})
		s.held = false
		if outcome == "empty":
			s.phase = &"away"
			events.append({"type": "carLeft", "t": t, "reason": "empty"})
		else:
			departing = StringName(outcome)

	if departing == &"bank":
		# Flush open readings of those aboard onto their tapes, then bank everything aboard.
		var aboard_ids: Array[String] = []
		for p in _active_aboard(players, input_of):
			aboard_ids.append(p.id)
		var crew := s.crew
		for p in players:
			crew = Instr.set_raised(crew, p.id, false)
		var crew_players: Array[Instr.CrewPlayer] = []
		for p in players:
			crew_players.append(Instr.CrewPlayer.make(p.id, p.body, aboard_ids.has(p.id)))
		var flush_state := s.copy()
		flush_state.crew = crew
		var no_entities: Array[Instr.EntityTick] = []
		for _k in 20:
			var out := _crew_tick(flush_state, crew_players, no_entities, 0.1)
			flush_state.crew = out.crew
			for e in out.events:
				events.append(_with_t(e, t))
		s.crew = flush_state.crew
		var dep := Instr.leave_floor(s.crew, aboard_ids)
		s.players = players
		var summary := _summarize(s, dep.carried, false)
		s.summary = summary
		s.phase = &"ended"
		s.blink = null
		events.append({"type": "banked", "t": t, "summary": summary})
		return res

	if departing == &"ride":
		var aboard_ids := {}
		for p in _active_aboard(players, input_of):
			aboard_ids[p.id] = true
		# Everyone not aboard is lost for this floor, with what they hold; so is everything on the floor.
		var next_tape := s.crew.next_tape
		var members: Array[Instr.CrewMember] = []
		for m in s.crew.members:
			if aboard_ids.has(m.id):
				members.append(m)
				continue
			var lost := _held_tapes(m)
			var lost_ids: Array = []
			for tp in lost:
				lost_ids.append(tp.id)
			events.append({"type": "leftBehind", "t": t, "playerId": m.id, "lostTapes": lost_ids, "lostValue": TapeLib.tape_value(lost)})
			var nm := m.copy()
			nm.tape = TapeLib.empty_tape("tape-%d" % next_tape, m.id)
			next_tape += 1
			nm.carrying = []
			nm.instrument = m.instrument.copy()
			nm.instrument.current = null
			nm.instrument.raised = false
			members.append(nm)
		if not s.crew.floor.is_empty():
			var lost: Array[TapeLib.Tape] = []
			var lost_ids: Array = []
			for f in s.crew.floor:
				lost.append(f.tape)
				lost_ids.append(f.tape.id)
			events.append({"type": "floorTapesLost", "t": t, "tapes": lost_ids, "lostValue": TapeLib.tape_value(lost)})
		var nc := s.crew.copy()
		nc.members = members
		nc.floor = []
		nc.next_tape = next_tape
		s.crew = nc
		for i in players.size():
			var p := players[i]
			if aboard_ids.has(p.id):
				continue
			var np := p.copy()
			np.status = &"caught" if p.status == &"caught" else &"leftBehind"
			np.side = null
			players[i] = np
		s.phase = &"riding"
		s.timer = RIDE_TIME
		s.blink = null
		s.lure = false
		events.append({"type": "carLeft", "t": t, "reason": "ride"})

	# ---- 2. The Orderly (not while riding: that floor is behind the crew).
	var entity_ticks: Array[Instr.EntityTick] = []
	if s.phase != &"riding":
		var blind := blinking(s)
		var open := doors_open(s)
		var views: Array[Entity.PlayerView] = []
		for p in players:
			var i := _inp(p, input_of)
			if not _is_active(p, input_of):
				views.append(_view_of(i, false, false))
			elif p.aboard:
				# Never huntable inside the car. With the doors open and the lights on, they still watch the floor.
				var w := _threshold_view(car, i)
				var just_w: Array[Entity.PlayerView] = [w]
				if open and not blind and not i.blind and Entity.seen_by(s.plan, s.orderly.body, just_w) != null:
					views.append(w)
				else:
					views.append(_view_of(i, false, false))
			else:
				views.append(_view_of(i, true, blind or i.blind))
		# The call pulls it toward the landing, until it gets there.
		var s2 := float(s.plan.cell_size)
		var lx := (s.plan.landing.x + 0.5) * s2
		var lz := (s.plan.landing.y + 0.5) * s2
		if s.lure and M.hypot2(s.orderly.body.x - lx, s.orderly.body.z - lz) <= LURE_DROP_DISTANCE:
			s.lure = false
		if s.lure:
			views.append(Entity.PlayerView.make(LURE_ID, Move.Body.make(lx, lz, s.plan.landing.level, car.floor_y), 1.6, 0.0, 0.0, 1.0, 1.0, true, true))
		var before := s.orderly
		# In the blackout it runs its prey down: no creeping up on the still (that is for recording it,
		# and nobody can see to time a turn in the dark), at BLACKOUT_HUNT_SPEED.
		var er: Entity.StepResult
		if blacked_out(s):
			er = Entity.step_entity(s.plan, before, views, dt, BLACKOUT_HUNT_SPEED, false)
		else:
			er = Entity.step_entity(s.plan, before, views, dt)
		var next := er.state
		# Belt and braces: it can never end a tick in (or overlapping) the car.
		if rect_distance(car.rect, next.body.x, next.body.z) < Entity.ORDERLY_RADIUS - 1e-3 and next.body.level == car.level:
			next = next.copy()
			next.body = before.body
			next.moving = false
			next.speed = 0.0
		s.orderly = next
		var o_events: Array[Dictionary] = []
		for e in er.events:
			if not e.has("playerId") or e["playerId"] != LURE_ID:
				o_events.append(e)
		for e in o_events:
			events.append(_with_t(e, t))
		entity_ticks = [Instr.EntityTick.make(s.entity_id, &"stillness", before, next, o_events)]
		for e in o_events:
			if e["type"] != "caught":
				continue
			for k in players.size():
				if players[k].id == e["playerId"]:
					var np := players[k].copy()
					np.status = &"caught"
					np.side = null
					players[k] = np

	# ---- 3. The crew.
	var crew := s.crew
	for p in players:
		var i: PlayerInput = input_of.get(p.id)
		if i != null and i.raised != null:
			crew = Instr.set_raised(crew, p.id, bool(i.raised) and p.status == &"ok")
	s.crew = crew
	var crew_players: Array[Instr.CrewPlayer] = []
	for p in players:
		crew_players.append(Instr.CrewPlayer.make(p.id, p.body, _is_active(p, input_of)))
	var out := _crew_tick(s, crew_players, entity_ticks, dt)
	s.crew = out.crew
	for e in out.events:
		events.append(_with_t(e, t))
	for p in players:
		var given: PlayerInput = input_of.get(p.id)
		if given == null or given.pick_up == null or not _is_active(p, input_of):
			continue
		var want: Variant = given.pick_up
		var m := Instr.member(s.crew, p.id)
		var tape_id: Variant = null
		if want is bool and want == true:
			var best := INF
			for f in s.crew.floor:
				var d := Instr.feet_distance(m.body, f.at) if (m != null and m.body != null) else INF
				if d <= Instr.PICKUP_REACH + EPS and d < best:
					best = d
					tape_id = f.tape.id
		elif want is String:
			tape_id = want
		if tape_id == null:
			continue
		var up := Instr.pick_up_tape(s.crew, p.id, tape_id)
		if up.ok:
			s.crew = up.crew
			if up.event != null:
				events.append(_with_t(up.event, t))

	# ---- Arriving on the next floor.
	if s.phase == &"riding" and s.timer <= EPS:
		var depth := s.depth + 1
		var f := _floor_for(s.seed, depth)
		var bodies := {}
		for i in players.size():
			var p := players[i]
			var body: Move.Body
			if p.status == &"ok" and in_car(car, p.body):
				var l := car_local(car, p.body.x, p.body.z)
				body = car_body(f.car, l[0], l[1])
			else:
				body = _car_slot(f.car, i)
			bodies[p.id] = body
			var np := p.copy()
			np.body = body
			np.status = &"ok"
			np.aboard = true
			np.side = null
			players[i] = np
		s.depth = depth
		s.plan = f.plan
		s.car = f.car
		s.orderly = f.orderly
		s.entity_id = f.entity_id
		var nc := s.crew.copy()
		nc.members = []
		for m in s.crew.members:
			var nm := m.copy()
			nm.body = bodies.get(m.id, m.body)
			nm.active = true
			nc.members.append(nm)
		s.crew = nc
		s.phase = &"arriving"
		s.timer = ARRIVE_DOOR_DELAY
		events.append({"type": "rodeDown", "t": t, "depth": depth, "bodies": bodies})

	s.players = players

	# ---- A wipe: nobody left who can call or board.
	var everyone_out := true
	for p in players:
		if p.status == &"ok":
			everyone_out = false
	if s.phase != &"riding" and everyone_out:
		var no_tapes: Array[TapeLib.Tape] = []
		var summary := _summarize(s, no_tapes, true)
		s.summary = summary
		s.phase = &"ended"
		s.blink = null
		events.append({"type": "wiped", "t": t, "summary": summary})
	return res

static func _inp(p: RunPlayer, input_of: Dictionary) -> PlayerInput:
	var given: PlayerInput = input_of.get(p.id)
	if given != null:
		return given
	return PlayerInput.make(p.id, p.body, 1.65, 0.0, 0.0, 90.0, 70.0)

static func _is_active(p: RunPlayer, input_of: Dictionary) -> bool:
	return p.status == &"ok" and input_of.has(p.id)

static func _active_aboard(players: Array[RunPlayer], input_of: Dictionary) -> Array[RunPlayer]:
	var out: Array[RunPlayer] = []
	for p in players:
		if _is_active(p, input_of) and p.aboard:
			out.append(p)
	return out
