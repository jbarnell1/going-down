# What the host and the clients share: timing constants, the floor plans, the one sight test both
# sides use for "can this player see the Orderly where it is drawn", and the host-clock estimator.
# Port of src/net/session.ts.
#
# Joining a run in progress: a new player is told the seed and the whole state at once (welcome) and
# watches as a spectator; they become a player at the next elevator stop, i.e. the next time the car
# is at a landing with its doors shut and the crew inside ('arriving': the start of the run and every
# arrival after a ride). They appear in the car with an empty tape. Players named in the host's
# starting roster are players from the first tick.
#
# Leaving: a player who leaves (or whose connection drops) becomes inactive at once and stays so: the
# run keeps them in its player list (their share of a bank is still theirs), they are never hunted,
# never vote and never count against a wipe.
extends RefCounted

const Run = preload("res://sim/run.gd")
const Floor = preload("res://sim/floor.gd")
const Clinic = preload("res://sim/clinic.gd")
const Move = preload("res://sim/move.gd")
const Stamina = preload("res://sim/stamina.gd")
const Pose = preload("res://net/pose.gd")

## Logic ticks per second on the host, and snapshots per second.
const TICK_HZ := 20
const TICK := 1.0 / TICK_HZ
## Seconds between a client's inputs (it also sends at once when it starts seeing the Orderly).
const INPUT_INTERVAL := 1.0 / 20.0
## Clients draw other players and the Orderly this far behind the newest snapshot they could have.
const INTERP_DELAY := 0.1
## Seconds of Orderly history the host keeps for put-backs (must exceed the worst round trip plus INTERP_DELAY).
const HISTORY_SECONDS := 3.0
## The host puts the Orderly back to where a client saw it only if that is within this many metres.
const PUT_BACK_MAX := 4.0
## A player's "I can see it" stops counting if no input has come for this long (seconds).
const SEEING_TIMEOUT := 1.0
## A catch whose victim has not confirmed their screen within this long is completed anyway (seconds).
const CATCH_CONFIRM_MAX := 1.5
## Fastest a player's body may move (m/s): a sprint, and only while the host's copy of their tank
## allows it; otherwise walking pace. JUMP_SLACK is the most distance (m) the allowance banks.
const MAX_PLAYER_SPEED := Stamina.SPRINT_SPEED
const JUMP_SLACK := 0.75
## Events per snapshot are capped at roughly this many bytes (at least one event is always sent).
const EVENT_BUDGET := 560
## A body's radius when the client moves its own player.
const PLAYER_RADIUS := 0.3
## A host clock that disagrees with the estimate by more than this (plus a round trip) has jumped.
const CLOCK_JUMP := 0.5

# ---------------------------------------------------------------------------------------------
# Floors.

static var _plans := {}
static var _plan_order: Array[String] = []
static var _cars := {}

## The floor plan of a depth (every machine builds the same one from the seed). Keeps the last 16.
static func plan_for(seed: String, depth: int) -> Floor.FloorPlan:
	var key := "%s/%d" % [seed, depth]
	if _plans.has(key):
		return _plans[key]
	var p := Clinic.generate_clinic(seed, depth)
	_plans[key] = p
	_plan_order.append(key)
	if _plan_order.size() > 16:
		var first: String = _plan_order.pop_front()
		_cars.erase(_plans[first])
		_plans.erase(first)
	return p

## The car of a plan (cached per plan object).
static func car_for(plan: Floor.FloorPlan) -> Run.CarGeometry:
	if _cars.has(plan):
		return _cars[plan]
	var c := Run.car_geometry(plan)
	_cars[plan] = c
	return c

static func doors_open_in(phase: Variant) -> bool:
	return phase == "unloading" or phase == "boarding"

## Moves the local player the way the run does (move_in_run: walls, stairs, the car's doorway while
## the doors are open). move_in_run takes a whole RunState but reads only the plan, the car and the phase.
static func move_local(plan: Floor.FloorPlan, phase: Variant, body: Move.Body, dx: float, dz: float, radius: float = PLAYER_RADIUS) -> Move.Body:
	var view := Run.RunState.new()
	view.plan = plan
	view.car = car_for(plan)
	view.phase = StringName(phase)
	return Run.move_in_run(view, body, dx, dz, radius)

## Whether a camera could be showing the Orderly drawn at `pose` (Pose.camera_sees with the plan's car).
static func camera_sees(plan: Floor.FloorPlan, cam: Pose.Camera, pose: Dictionary, doors_open: bool) -> bool:
	return Pose.camera_sees(plan, car_for(plan), cam, pose, doors_open)

# ---------------------------------------------------------------------------------------------
# The host clock, as a client estimates it.

## Round-trip samples: the client stamps each input with its own clock; the host echoes the stamp of
## the newest input it has with how long it held it, and stamps its own clock on the snapshot. The
## estimate uses the sample with the smallest round trip in a recent window; its offset error is at
## most half that round trip, whatever the asymmetry. That bound is the guard.
class HostClock:
	var _rtts := PackedFloat64Array()
	var _offsets := PackedFloat64Array()
	var _window: int

	func _init(window: int = 120) -> void:
		_window = window

	## One echo: client sent at `t0`, the host held it `hold` s and stamped `host_send`; it arrived at `t3`.
	func sample(t0: float, hold: float, host_send: float, t3: float) -> void:
		var rtt := t3 - t0 - hold
		if not (rtt >= 0.0) or not (hold >= 0.0):
			return
		var off := host_send + rtt / 2.0 - t3
		if ready() and absf(off - offset()) > 0.5 + rtt_best():
			_rtts.clear()
			_offsets.clear()
		_rtts.append(rtt)
		_offsets.append(off)
		if _rtts.size() > _window:
			_rtts.remove_at(0)
			_offsets.remove_at(0)

	func ready() -> bool:
		return _rtts.size() > 0

	func _best() -> int:
		var b := 0
		for i in range(1, _rtts.size()):
			if _rtts[i] < _rtts[b]:
				b = i
		return b

	## Host time minus local time.
	func offset() -> float:
		return _offsets[_best()] if ready() else 0.0

	## The smallest recent round trip, seconds.
	func rtt_best() -> float:
		return _rtts[_best()] if ready() else 0.5

	## How far the estimated host time can be from the real one (seconds).
	func error_bound() -> float:
		return rtt_best() / 2.0 if ready() else 0.5

	func host_time(local: float) -> float:
		return local + offset()
