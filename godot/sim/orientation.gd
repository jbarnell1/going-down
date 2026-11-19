# A3: a harmless exercise in the same movement, sight and instrument rules as the live floors.
extends RefCounted

const Entity = preload("res://sim/entity.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Rng = preload("res://sim/rng.gd")

const PLACE := &"orientation"
## The paid deck keeps its own depths. A prelude has no day block and uses this separate stop.
const PRELUDE_DEPTH := 0
const PRELUDE_RIDE_SECONDS := 3.0
const WIDTH := 11
const HEIGHT := 10
const CELL := 2
const CENTRE := 5
const LANDING_ROW := 8
const TARGET_ROW := 3
const CONTACT := 0.7
const REARM_DISTANCE := 1.1
const SPEED := 0.9
const PAY_SCALE := 0.025
const QUOTA := 1
const STANDEE_BAYS := [Vector2(8.65, 14.2), Vector2(13.35, 10.8)]
const STANDEES_UNTRIGGERED := Vector2(-1.0, -1.0)
static var _target_body: Entity.BodySettings

static func generate(seed: String, depth: int) -> Floor.FloorPlan:
	var plan := Floor.FloorPlan.new()
	plan.seed = seed
	plan.depth = depth
	plan.place = PLACE
	plan.width = WIDTH
	plan.height = HEIGHT
	plan.cell_size = CELL
	for level in 2:
		plan.cells[level].resize(WIDTH * HEIGHT)
		plan.cells[level].fill(Floor.VOID)
	for z in range(1, LANDING_ROW):
		for x in range(CENTRE - 1, CENTRE + 2):
			plan.cells[0][z * WIDTH + x] = Floor.CORRIDOR
	# The threshold shares the corridor's open edge, with the car mounted on the far side.
	plan.cells[0][LANDING_ROW * WIDTH + CENTRE] = Floor.CORRIDOR
	plan.landing = Floor.Pos.make(0, CENTRE, LANDING_ROW)
	var target_column := CENTRE + (1 if Rng.make_rng(seed).fork("orientation").pick([false, true]) else -1)
	plan.entity_start = Floor.Pos.make(0, target_column, TARGET_ROW)
	plan.sightlines = Floor.find_sightlines(plan, 3)
	return plan

## Stepping into a marked stretch of the corridor trips its physical rehearsal prop once per run.
static func trigger_standees(stamps: Vector2, body: Move.Body, at: float) -> Vector2:
	if body.level != 0 or absf(body.x - (CENTRE + 0.5) * CELL) > 2.6:
		return stamps
	for slot in STANDEE_BAYS.size():
		if stamps[slot] < 0.0 and absf(body.z - STANDEE_BAYS[slot].y) <= 0.9:
			stamps[slot] = at
	return stamps

static func target_body() -> Entity.BodySettings:
	if _target_body == null:
		var body := Entity.BodySettings.new()
		body.name = &"practice_target"
		body.height = 1.75
		body.radius = 0.35
		body.seen_height = body.height
		body.seen_radius = body.radius
		body.seen_radius_walk = body.radius
		body.hunt_speed = SPEED
		body.hear_range = 12.0
		body.sound_height = 0.4
		_target_body = body
	return _target_body

## Rolls up to a player and honks once until the player makes room again. Contact changes no player state.
static func step_target(plan: Floor.FloorPlan, prev: Entity.OrderlyState, players: Array[Entity.PlayerView],
		watchers: Array[Entity.PlayerView], dt: float, stunned := false) -> Entity.StepResult:
	var out := Entity.StepResult.new()
	var next := prev.copy()
	out.state = next
	next.t += dt
	next.moving = false
	next.speed = 0.0
	next.seen = Entity.seen_by(plan, prev.body, watchers, Entity.kind_of(prev)) != null
	if next.seen:
		next.last_seen_at = next.t
	next.held = next.seen or Entity.held_by_grace(prev)
	next.frozen = next.held or stunned

	var target: Entity.PlayerView = null
	var distance := INF
	var at := Vector2(prev.body.x, prev.body.z)
	for player in players:
		var away := at.distance_to(Vector2(player.body.x, player.body.z))
		if player.active and player.body.level == prev.body.level and away < distance:
			target = player
			distance = away
	if distance >= REARM_DISTANCE:
		next.mode = &"hunting"
	if next.frozen or target == null or next.mode == &"dormant":
		return out

	var offset := Vector2(target.body.x, target.body.z) - at
	var shift := offset.normalized() * minf(SPEED * dt, maxf(0.0, distance - CONTACT))
	next.body = Move.move_with_collision(plan, prev.body, shift.x, shift.y, Entity.kind_of(prev).radius)
	var moved := at.distance_to(Vector2(next.body.x, next.body.z))
	if moved > 0.0:
		next.yaw = Entity.yaw_toward(shift.x, shift.y)
		next.moving = true
		next.speed = moved / dt
		next.anim = &"walk"
		next.anim_time += dt
	if Vector2(next.body.x - target.body.x, next.body.z - target.body.z).length() <= CONTACT + 0.001:
		next.mode = &"dormant"
		out.events.append({"type": "orientationHonk", "t": next.t, "at": next.body})
	return out
