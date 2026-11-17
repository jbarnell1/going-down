# How fast a player may move, and for how long. Pure logic, shared by the game, bots and tests.
# Port of src/sim/stamina.ts.
#
# The Orderly hunts faster than a walk. A player who only walks is slowly run down; a player who
# sprints pulls away but tires. Mixing the two over a long stretch keeps you ahead of it, but only
# just: on the numbers below a perfect run-and-walk cycle averages about 3.8 m/s against the
# Orderly's 3.7. So fleeing is never a plan by itself. You have to look back and freeze it.
extends RefCounted

## Metres per second.
const WALK_SPEED := 3.0
const SPRINT_SPEED := 5.0
const CREEP_SPEED := 1.2

## Seconds of sprinting on a full tank.
const SPRINT_SECONDS := 5.0
## The paced runs' tank (sim/run.gd paced, owner 17 Nov: "a bit more stamina"): seconds of sprinting on a
## full tank. The residents hunt faster to match (run.gd PACED_HUNT_SPEED). A tank carries its own size
## (Stamina.tank), so the host, the game and the bots all step it the same way.
const PACED_SPRINT_SECONDS := 7.0
## Seconds to refill from empty while walking, and while standing still or creeping.
const RECOVER_WALKING := 8.0
const RECOVER_RESTING := 5.0
## After running dry you cannot sprint again until the tank is back to this share.
const WINDED_UNTIL := 0.35
## Sprinting only counts when you are actually covering ground (m/s).
const MOVING := 0.5

# Gait: 'creep' | 'walk' | 'sprint'

class Stamina:
	## 0 (empty) to 1 (full).
	var level: float = 1.0
	## True from running dry until the tank passes WINDED_UNTIL; the sprint key does nothing meanwhile.
	var winded: bool = false
	## Seconds of sprinting it holds when full: SPRINT_SECONDS, or PACED_SPRINT_SECONDS in a paced run.
	var tank: float = SPRINT_SECONDS

	static func make(level_: float, winded_: bool, tank_: float = SPRINT_SECONDS) -> Stamina:
		var s := Stamina.new()
		s.level = level_
		s.winded = winded_
		s.tank = tank_
		return s

static func fresh_stamina(tank: float = SPRINT_SECONDS) -> Stamina:
	return Stamina.make(1.0, false, tank)

## The gait a player actually gets this tick. Creep wins over sprint; a capped player cannot sprint.
## (TypeScript takes a GaitWish object; `cap` is a speed cap from something held, INF for none.)
static func gait_for(st: Stamina, sprint: bool, creep: bool, moving: bool, cap: float) -> StringName:
	if creep:
		return &"creep"
	if sprint and moving and not st.winded and st.level > 0.0 and cap >= SPRINT_SPEED:
		return &"sprint"
	return &"walk"

static func speed_for(gait: StringName, cap: float = INF) -> float:
	var s := SPRINT_SPEED if gait == &"sprint" else (CREEP_SPEED if gait == &"creep" else WALK_SPEED)
	return minf(s, cap)

## Advances stamina by dt seconds. `ground_speed` is how fast the player really moved (m/s), so that
## sprinting into a wall costs nothing and standing still recovers fastest.
static func step_stamina(st: Stamina, gait: StringName, ground_speed: float, dt: float) -> Stamina:
	var level := st.level
	var winded := st.winded
	if gait == &"sprint" and ground_speed > MOVING:
		level -= dt / st.tank
		if level <= 0.0:
			level = 0.0
			winded = true
	else:
		var resting := gait == &"creep" or ground_speed <= MOVING
		level = minf(1.0, level + dt / (RECOVER_RESTING if resting else RECOVER_WALKING))
		if winded and level >= WINDED_UNTIL:
			winded = false
	return Stamina.make(level, winded, st.tank)

## How out of breath a player is: 0 on a full tank, rising as it empties, and from 0.7 up to 1 while
## winded. The game turns it into breathing and a darkening at the edge of the view (no meter).
static func exertion(st: Stamina) -> float:
	if st.winded:
		return 0.7 + 0.3 * maxf(0.0, 1.0 - st.level / WINDED_UNTIL)
	return maxf(0.0, minf(1.0, 1.0 - st.level))

## Average speed of the best endless run-then-walk cycle: what a fleeing player can sustain.
static func sustained_flee_speed(tank: float = SPRINT_SECONDS) -> float:
	# Sprint from full to empty, walk until the winded mark is passed, sprint again from there.
	var sprint_time := tank * WINDED_UNTIL
	var walk_time := RECOVER_WALKING * WINDED_UNTIL
	# The first cycle from a full tank is better; this is the steady state once tired.
	return (sprint_time * SPRINT_SPEED + walk_time * WALK_SPEED) / (sprint_time + walk_time)
