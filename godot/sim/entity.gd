# The Orderly: a 2.6 m figure pushing a squeaking trolley. Its trait is Stillness: it only moves
# while too few are looking at it: with one or two up players any one look stops it, with three or more
# it takes two (see "Watchers" below; docs/floors/traits-and-hiding.md section 1). Below, "seen" means
# seen by enough watchers. Pure, deterministic logic; the renderer plays `anim` and `yaw`,
# the audio plays audibility(). Port of src/sim/entity.ts.
#
# The fairness contract: entities always obey their traits, and anything that depends on looking
# is decided in the player's favour. So, within every tick:
#   1. decide whether any active player could be seeing it (sight.gd, with a widened cone and
#      generous geometry);
#   2. only then act. It never moves, turns, advances its animation, or progresses a wind-up in a
#      tick in which it is seen, nor for GRACE seconds after the last tick it was seen (so a player
#      whose view reaches the server late never sees it move);
#   3. looking at it during a wind-up always cancels the wind-up.
# The first promise has one exception, "except while it has someone" (North Star B6, down first then out):
# while it is bent over a downed player (mode "bending", which only sim/run.gd puts it in, with the down
# rule on) its bend is the one movement it makes while watched: the "bend" pose and its clock go on
# whether anyone looks or not. It never moves, turns or reaches while bending, and it goes after nobody.
# When the run lets it go (stand_off) it is dormant, still bent: it straightens up only on a tick nobody
# sees it, and while held it keeps the bend.
#
# Modes: waiting (standing at plan.entity_start) -> hunting -> windUp -> dormant -> hunting ...
# With the down rule: windUp -> (caught) bending -> dormant (a heal: HEAL_QUIET s; out: 0 s) -> hunting.
#
# Bodies. The trait logic above is shared; what differs between residents is a body setting
# (BodySettings): its height, collision radius, the outline that counts as "seen", its speeds and its
# sound. The state carries its body (`kind`); create_orderly(plan) makes the Orderly, the default, and
# create_orderly(plan, temp_body()) makes the Temp (docs/floors/annex.md section 4): 1.8 m tall, and
# a stapler instead of a trolley. The stapler clicks once per CLICK_STEP metres walked and once per
# CLICK_WAIT seconds standing unwatched, as "click" events in the rules, so every player hears the
# same clicks. A held body makes no sound and its click clocks stop: the clicking stops dead the
# moment anyone looks.
extends RefCounted

const Floor = preload("res://sim/floor.gd")
const Follow = preload("res://sim/follow.gd")
const Move = preload("res://sim/move.gd")
const Sight = preload("res://sim/sight.gd")
const Walls = preload("res://sim/walls.gd")
const M = preload("res://sim/jsmath.gd")

# ---------------------------------------------------------------------------------------------
# Tuning.

const ORDERLY_HEIGHT := 2.6
const ORDERLY_RADIUS := 0.35
## How big it counts as being for the purpose of "can anyone see it". Larger than the body it
## collides with, on purpose: the drawn figure's cap reaches 2.82 m and its reaching arm 2.0 m from
## its centre, and an arm seen moving round a corner would break the rule as surely as the body.
const SEEN_HEIGHT := 2.9
const SEEN_RADIUS := 2.1
## The swinging arms in the walk reach about 1.05 m from its centre.
const SEEN_RADIUS_WALK := 1.1
## Seconds it stays frozen after the last tick anyone could see it. Absorbs network delay.
const GRACE := 0.3
## Waiting ends after it has been seen for this long in total (seconds)...
const WAKE_SEEN_TIME := 1.0
## ...or a player's walking distance to it drops under this (metres)...
const WAKE_DISTANCE := 12.0
## ...or this much time has passed (seconds).
const WAKE_TIMEOUT := 60.0
## Hunting speed in m/s: faster than a walk (3.0), slower than a sprint (5.0); see stamina.gd.
const HUNT_SPEED := 3.7
## It runs down prey that runs, and creeps up on prey that stands still. Within CREEP_DISTANCE of a
## target moving slower than CREEP_PREY_SPEED it slows to CREEP_SPEED. This is what makes recording it
## a gamble a person can play: at full speed the last five metres take a second and a half, too fast
## to choose when to turn; at a creep they take about four, with the ticking climbing all the way.
## A player who flees still gets chased at full speed, so turning your back and walking away is no escape.
const CREEP_DISTANCE := 5.5
const CREEP_PREY_SPEED := 1.6
const CREEP_SPEED := 1.3
## Seconds between route re-plans while hunting.
const REPLAN_INTERVAL := 0.5
## Horizontal distance (metres) to a player on the same level at which it starts reaching.
const CATCH_RANGE := 0.9
## Wind-up of the reach, seconds.
const WIND_UP_TIME := 0.6
## A wind-up completes only if its target is still this close (metres) and on the same level.
const REACH_RANGE := 1.6
## After a catch it does nothing for this long (seconds).
const DORMANT_TIME := 10.0
## OR2 (the Orderly fix, sim/run.gd with_orderly_fix; off unless asked): see "The Orderly fix" below.
## In its reach it keeps walking at this many in 100 of its hunt speed (the live setting orderly.reach_walk).
const REACH_WALK := 100
## A second Orderly chasing the first's target takes its own way round: cells on the first's route cost this many
## steps more, except the last FLANK_FREE before the target; it heads FLANK_AHEAD cells along its own route until
## the target is within FLANK_NEAR metres in a straight line.
const FLANK_COST := 4
const FLANK_FREE := 3
const FLANK_AHEAD := 4
const FLANK_NEAR := 8.0
## When it shares a cell with its target it walks straight at them, stopping this far away.
const APPROACH_STOP := 0.6
## Maximum turn rate, radians per second.
const TURN_RATE := 5.0
## Within this straight-line distance (metres, same level) it faces its target while it walks.
const FACE_TARGET_RANGE := 6.0
## It ducks while its centre is within this distance (metres) of a door's edge line.
const DUCK_DISTANCE := 0.6
## The trolley squeak: audible out to this straight-line distance (metres) while it moves.
const HEAR_RANGE := 34.0
## Gain multiplier when there is no line of sight to it.
const MUFFLED_GAIN := 0.45
## Height of the squeaking wheels above its feet (metres).
const SQUEAK_HEIGHT := 0.4

## The Temp (docs/floors/annex.md section 4). Where annex.md is silent it keeps the Orderly's
## numbers: collision radius, hunting and creeping speeds, and the muffling through walls.
const TEMP_HEIGHT := 1.8
## The drawn figure (client/temp_view.gd): hair to about 1.81 m; in the reach the stapler arm comes
## about 1 m forward of its centre; walking and standing, the hands, stapler and pad stay within
## about 0.55 m. Generous, as the Orderly's are.
const TEMP_SEEN_HEIGHT := 2.0
const TEMP_SEEN_RADIUS := 1.1
const TEMP_SEEN_RADIUS_WALK := 0.7
## One stapler click per this many metres walked...
const TEMP_CLICK_STEP := 1.2
## ...and one per this many seconds standing unwatched.
const TEMP_CLICK_WAIT := 4.0
## The click is heard out to this straight-line distance (metres), from its hand.
const TEMP_HEAR_RANGE := 30.0
const TEMP_CLICK_HEIGHT := 1.0

## Below this, timers count as run out (float sums of dt are not exact).
const EPS := 1e-9

# ---------------------------------------------------------------------------------------------
# Types.

## A resident's body: everything about it that is not trait logic. Shared and read-only: get them
## from orderly_body() and temp_body(), never change one.
class BodySettings extends RefCounted:
	var name: StringName
	## Height and collision radius of the body (metres).
	var height: float
	var radius: float
	## The larger outlines that also count as "seen" (see seen_by): any height with seen_radius, and
	## the body's height with seen_radius_walk.
	var seen_height: float
	var seen_radius: float
	var seen_radius_walk: float
	## Hunting speed (step_entity's default) and the creep near still prey, m/s.
	var hunt_speed: float
	var creep_speed: float
	## It ducks through doors (the "duck" animation hint).
	var ducks: bool
	## Its sound: heard to hear_range (metres) from sound_height above its feet.
	var hear_range: float
	var sound_height: float
	## The stapler: a click per click_step metres walked and per click_wait seconds standing
	## unwatched. Both 0: no clicks; it sounds while it moves (the Orderly's trolley).
	var click_step: float = 0.0
	var click_wait: float = 0.0

	func clicks() -> bool:
		return click_step > 0.0 or click_wait > 0.0

static var _orderly_body: BodySettings = null
static var _temp_body: BodySettings = null

## The Orderly: the default body, made of the constants above.
static func orderly_body() -> BodySettings:
	if _orderly_body == null:
		var k := BodySettings.new()
		k.name = &"orderly"
		k.height = ORDERLY_HEIGHT
		k.radius = ORDERLY_RADIUS
		k.seen_height = SEEN_HEIGHT
		k.seen_radius = SEEN_RADIUS
		k.seen_radius_walk = SEEN_RADIUS_WALK
		k.hunt_speed = HUNT_SPEED
		k.creep_speed = CREEP_SPEED
		k.ducks = true
		k.hear_range = HEAR_RANGE
		k.sound_height = SQUEAK_HEIGHT
		_orderly_body = k
	return _orderly_body

## The Temp (docs/floors/annex.md section 4).
static func temp_body() -> BodySettings:
	if _temp_body == null:
		var k := BodySettings.new()
		k.name = &"temp"
		k.height = TEMP_HEIGHT
		k.radius = ORDERLY_RADIUS
		k.seen_height = TEMP_SEEN_HEIGHT
		k.seen_radius = TEMP_SEEN_RADIUS
		k.seen_radius_walk = TEMP_SEEN_RADIUS_WALK
		k.hunt_speed = HUNT_SPEED
		k.creep_speed = CREEP_SPEED
		k.ducks = false
		k.hear_range = TEMP_HEAR_RANGE
		k.sound_height = TEMP_CLICK_HEIGHT
		k.click_step = TEMP_CLICK_STEP
		k.click_wait = TEMP_CLICK_WAIT
		_temp_body = k
	return _temp_body

## A state's body (an unset one is the Orderly).
static func kind_of(s: OrderlyState) -> BodySettings:
	return s.kind if s.kind != null else orderly_body()

# OrderlyMode: 'waiting' | 'hunting' | 'windUp' | 'dormant'
# OrderlyAnim (what the renderer plays; a frozen Orderly keeps its last hint and its clock stops):
#   'idle' | 'walk' | 'duck' | 'reach'

## A player as the Orderly sees them. `eye` is the eye height above the feet.
class PlayerView extends Sight.Viewer:
	var id: String
	var active: bool
	## Present and huntable (it can target, reach for and catch them) but seeing nothing this tick,
	## e.g. during a light blink. Never counts as looking. Default false.
	var blind: bool = false
	## A confirmed directed light adds one watch only while this view actually sees the resident.
	var steady_gaze: bool = false
	## Inside a hide (T19b, sim/hiding.gd; see "Hidden players" below): never hunted or reached for. Their
	## hide's id, whether it has a reason, its front and inside spots, and where they were last seen out.
	var hidden: bool = false
	var hide: int = -1
	var hide_reason: bool = false
	var hide_front: Move.Body = null
	var hide_at: Move.Body = null
	var hide_spot: Move.Body = null

	static func make(id_: String, body_: Move.Body, eye_: float, yaw_: float, pitch_: float, h_fov: float, v_fov: float, active_: bool, blind_: bool = false) -> PlayerView:
		var v := PlayerView.new()
		v.id = id_
		v.body = body_
		v.eye = eye_
		v.yaw = yaw_
		v.pitch = pitch_
		v.h_fov_deg = h_fov
		v.v_fov_deg = v_fov
		v.active = active_
		v.blind = blind_
		return v

class OrderlyState:
	## Simulation time in seconds.
	var t: float = 0.0
	var body: Move.Body
	## Facing, radians, three.js style (0 faces -z).
	var yaw: float = 0.0
	var mode: StringName = &"waiting"
	var anim: StringName = &"idle"
	## Animation clock in seconds; stops whenever it is held still. (TypeScript: animTime)
	var anim_time: float = 0.0
	## Some active player could see it this tick.
	var seen: bool = false
	## Held still this tick: seen now, or within GRACE of the last seen tick.
	var held: bool = false
	## Held while hunting or winding up (what `froze` and `released` report).
	var frozen: bool = false
	## It changed position this tick.
	var moving: bool = false
	var ever_seen: bool = false  # TypeScript: everSeen
	## Total seconds seen while waiting. (TypeScript: seenTotal)
	var seen_total: float = 0.0
	## Time of the last tick it was seen, or null. (TypeScript: lastSeenAt)
	var last_seen_at: Variant = null
	var target_id: Variant = null  # String or null
	## Its current walking speed in m/s (0 when not moving); the renderer and the squeak follow it.
	var speed: float = 0.0
	## Smoothed speed of its target and where the target was on the last hunting tick.
	var prey_speed: float = HUNT_SPEED
	var prey_x: float = 0.0
	var prey_z: float = 0.0
	var prey_id: Variant = null  # String or null
	## The route; empty means none (TypeScript: null). Never written to once made.
	var path: Array[Floor.Pos] = []
	var path_next: int = 0
	var resident_walk: Follow.ResidentWalk = null
	var replan_in: float = 0.0
	var wind_up_left: float = 0.0
	var wind_up_target: Variant = null  # String or null
	var dormant_left: float = 0.0
	## Its body (null: the Orderly). Never changes after create_orderly.
	var kind: BodySettings = null
	## The stapler: metres walked since the last walking click, seconds stood unwatched since the
	## last click (both stop while it is held), and the clicks it made this tick.
	var click_walk: float = 0.0
	var click_wait: float = 0.0
	var clicks: int = 0
	## Bending: the downed player it is bent over (sim/run.gd), else null.
	var bend_target: Variant = null
	## Hidden players (see "Hidden players" below). Mode "look": the hide it goes to and the seconds of
	## looking left. Mode "search": where it stands, the seconds of standing left, the player it lost.
	var look_hide: int = -1
	var look_left: float = 0.0
	var search_spot: Move.Body = null
	var search_left: float = 0.0
	var search_lost: Variant = null

	## Two-watcher Stillness (see "Watchers" below). How many watchers hold it this tick (1 or 2, from the
	## up players: watch_need); who the tick counted, with grace, in the order given; the host time of each
	## player's last looking tick (never written to once made: replaced); the last tick the count was met.
	var need: int = 1
	var watchers: Array[String] = []
	var looked_at: Dictionary = {}
	var last_met_at: Variant = null

	## Relocation (see "Relocation" below; sim/relocate.gd). It left and arrived this tick (the instrument never
	## records that tick); relocations on this floor so far; seconds of the stand after arriving still to go;
	## host time of the last arrival and of the next try after none passed; seconds it has been ready to leave
	## and out of view without a break (sim/relocate.gd keeps it); seconds since a watcher last counted; and
	## its dormant spell has ended since it last relocated or reached for anyone (the Stillness trigger).
	var relocated: bool = false
	var relocations: int = 0
	var stand_left: float = 0.0
	var arrived_at: float = -INF
	var retry_at: float = -INF
	var hidden_for: float = 0.0
	var unwatched_for: float = 0.0
	var reloc_wish: bool = false

	## Lonely (sim/lonely.gd; T19c), the Temp's own mechanic; untouched by every other trait. What it is doing
	## while it hunts ("" until it has hunted, "lurk", "approach", "chase", "breakoff"); who it chases; who it
	## broke off from last (relocation never takes it back to them when there is another); seconds without a
	## clear line to the chased (in a break-off: seconds since it began); seconds nobody has been lonely.
	var lonely_phase: StringName = &""
	var lonely_target: Variant = null
	var lonely_left: Variant = null
	var lonely_lost: float = 0.0
	var lonely_quiet: float = 0.0

	## OR2 (the Orderly fix): a second Orderly's waypoint on its own way round to the first's target, or null.
	## Always null with the fix off.
	var flank_goal: Variant = null

	## TypeScript: { ...state }.
	func copy() -> OrderlyState:
		var s := OrderlyState.new()
		s.flank_goal = flank_goal
		s.lonely_phase = lonely_phase
		s.lonely_target = lonely_target
		s.lonely_left = lonely_left
		s.lonely_lost = lonely_lost
		s.lonely_quiet = lonely_quiet
		s.relocated = relocated
		s.relocations = relocations
		s.stand_left = stand_left
		s.arrived_at = arrived_at
		s.retry_at = retry_at
		s.hidden_for = hidden_for
		s.unwatched_for = unwatched_for
		s.reloc_wish = reloc_wish
		s.need = need
		s.watchers = watchers
		s.looked_at = looked_at
		s.last_met_at = last_met_at
		s.kind = kind
		s.bend_target = bend_target
		s.look_hide = look_hide
		s.look_left = look_left
		s.search_spot = search_spot
		s.search_left = search_left
		s.search_lost = search_lost
		s.click_walk = click_walk
		s.click_wait = click_wait
		s.clicks = clicks
		s.t = t
		s.body = body
		s.yaw = yaw
		s.mode = mode
		s.anim = anim
		s.anim_time = anim_time
		s.seen = seen
		s.held = held
		s.frozen = frozen
		s.moving = moving
		s.ever_seen = ever_seen
		s.seen_total = seen_total
		s.last_seen_at = last_seen_at
		s.target_id = target_id
		s.speed = speed
		s.prey_speed = prey_speed
		s.prey_x = prey_x
		s.prey_z = prey_z
		s.prey_id = prey_id
		s.path = path
		s.path_next = path_next
		s.resident_walk = resident_walk
		s.replan_in = replan_in
		s.wind_up_left = wind_up_left
		s.wind_up_target = wind_up_target
		s.dormant_left = dormant_left
		return s

# OrderlyEvent: Dictionaries with the TypeScript shapes:
#   {type: "firstSeen", t, playerId} {type: "startedHunting", t} {type: "froze", t, playerId (or null)}
#   {type: "released", t} {type: "windUp", t, playerId} {type: "windUpCancelled", t, playerId}
#   {type: "caught", t, playerId}
#   {type: "click", t, why: "walk" | "wait"}   (bodies with a stapler only)

class StepResult:
	var state: OrderlyState
	var events: Array[Dictionary] = []

# ---------------------------------------------------------------------------------------------
# Helpers.

## Yaw that faces along (dx, dz), three.js style.
static func yaw_toward(dx: float, dz: float) -> float:
	return M.atan2_js(-dx, -dz)

static func _wrap_angle(a: float) -> float:
	var r := fmod(a, 2.0 * PI)
	if r > PI:
		r -= 2.0 * PI
	if r < -PI:
		r += 2.0 * PI
	return r

static func _turn_toward(yaw: float, want: float, max_turn: float) -> float:
	var d := _wrap_angle(want - yaw)
	return _wrap_angle(yaw + maxf(-max_turn, minf(max_turn, d)))

## One distance field per plan, for the cell asked for last: a waiting Orderly asks for the same one every tick.
static func _distances_cached(plan: Floor.FloorPlan, from: Floor.Pos) -> PackedInt32Array:
	var index := Floor.pos_index(plan, from)
	if plan._field_index == index:
		return plan._field
	var dist := Floor.distances_from(plan, from)
	plan._field_index = index
	plan._field = dist
	return dist

class Nearest:
	var player: PlayerView
	var steps: int
	var line: float

## The nearest active player by walking distance (ties: straight-line distance, then list order).
static func _nearest_by_walk(plan: Floor.FloorPlan, body: Move.Body, players: Array[PlayerView]) -> Nearest:
	var dist := _distances_cached(plan, Move.cell_of(plan, body))
	var best: Nearest = null
	for p in players:
		if not p.active or p.hidden:
			continue
		var steps := dist[Floor.pos_index(plan, Move.cell_of(plan, p.body))]
		if steps < 0:
			continue
		var line := M.hypot2(p.body.x - body.x, p.body.z - body.z)
		if best == null or steps < best.steps or (steps == best.steps and line < best.line):
			best = Nearest.new()
			best.player = p
			best.steps = steps
			best.line = line
	return best

static func _same_cell(a: Floor.Pos, b: Floor.Pos) -> bool:
	return a.level == b.level and a.x == b.x and a.y == b.y

## Whether a body's centre is within DUCK_DISTANCE of a door on one of its cell's edges.
static func near_door(plan: Floor.FloorPlan, body: Move.Body, radius: float = ORDERLY_RADIUS) -> bool:
	var s := float(plan.cell_size)
	var c := Move.cell_of(plan, body)
	var half := Walls.DOOR_WIDTH / 2.0 + radius
	var lx := body.x - c.x * s
	var lz := body.z - c.y * s
	var along_z := absf(lz - s / 2.0) <= half
	var along_x := absf(lx - s / 2.0) <= half
	if along_z and lx <= DUCK_DISTANCE and Walls.west_edge(plan, c.level, c.x, c.y) == Walls.DOOR:
		return true
	if along_z and s - lx <= DUCK_DISTANCE and Walls.west_edge(plan, c.level, c.x + 1, c.y) == Walls.DOOR:
		return true
	if along_x and lz <= DUCK_DISTANCE and Walls.north_edge(plan, c.level, c.x, c.y) == Walls.DOOR:
		return true
	if along_x and s - lz <= DUCK_DISTANCE and Walls.north_edge(plan, c.level, c.x, c.y + 1) == Walls.DOOR:
		return true
	return false

static func _find_player(players: Array[PlayerView], id: Variant) -> PlayerView:
	for p in players:
		if id != null and p.id == id:
			return p
	return null

# ---------------------------------------------------------------------------------------------
# The state machine.

## A waiting resident at plan.entity_start, facing the landing: the Orderly, or the body given
## (e.g. temp_body()).
static func create_orderly(plan: Floor.FloorPlan, kind: BodySettings = null) -> OrderlyState:
	var body := Move.body_at_cell(plan, plan.entity_start)
	var s := plan.cell_size
	var st := OrderlyState.new()
	st.kind = kind if kind != null else orderly_body()
	st.body = body
	st.yaw = yaw_toward((plan.landing.x + 0.5) * s - body.x, (plan.landing.y + 0.5) * s - body.z)
	return st

## The down rule (sim/run.gd): right after it caught `target`, it bends over them where it stands. It holds
## the bend (mode "bending") until the run lets it go with stand_off. Never mutates `o`.
static func bend_over(o: OrderlyState, target: String) -> OrderlyState:
	var s := o.copy()
	s.mode = &"bending"
	s.bend_target = target
	s.dormant_left = 0.0
	s.wind_up_target = null
	s.wind_up_left = 0.0
	s.target_id = null
	s.path = []
	s.moving = false
	s.speed = 0.0
	s.frozen = false
	s.anim = &"bend"
	s.anim_time = 0.0
	return s

## Lets a bending resident go: dormant for `quiet` seconds (a heal sends it off quiet for a spell; when its
## player goes out, 0: it hunts from the next tick), still bent until a tick nobody sees it. Never mutates `o`.
static func stand_off(o: OrderlyState, quiet: float) -> OrderlyState:
	var s := o.copy()
	s.mode = &"dormant"
	s.dormant_left = quiet
	s.bend_target = null
	s.replan_in = 0.0
	return s

## Whether any active player's screen could be showing it, and who (first in list order). `kind` is
## its body (null: the Orderly).
static func seen_by(plan: Floor.FloorPlan, body: Move.Body, players: Array[PlayerView], kind: BodySettings = null) -> PlayerView:
	var k := kind if kind != null else orderly_body()
	for p in players:
		if not p.active or p.blind:
			continue
		# The true body first, then the larger outlines the drawn figure can reach. Each extra pass can
		# only add sightings: checking the big outline INSTEAD of the body moved the sample points above
		# door frames and missed real ones, which the independent oracle caught.
		var look := Sight.look_of(p, Sight.SIGHT_MARGIN_DEG)
		if Sight.can_see_with(plan, look, body, Sight.SIGHT_FAR, k.height, k.radius) \
			or Sight.can_see_with(plan, look, body, Sight.SIGHT_FAR, k.height, k.seen_radius_walk) \
			or Sight.can_see_with(plan, look, body, Sight.SIGHT_FAR, k.seen_height, k.seen_radius):
			return p
	return null

## Advances the resident by dt seconds. Never mutates `prev`. (TypeScript HuntOptions: speed, creep.)
## `hunt_speed` below 0 means its body's own. `need`: watchers needed to hold it this tick (watch_need of
## the up players; 1, the default, is the rule every stored result was made with).
## OR2 (the Orderly fix; see "The Orderly fix" below): `reach_walk` is the part of its hunt speed it keeps walking at
## in its reach (0, the default: it stands to reach, as every stored result was made); `other` is the first Orderly
## when this is the second (null, the default: it chases the nearest, as always).
static func step_entity(plan: Floor.FloorPlan, prev: OrderlyState, players: Array[PlayerView], dt: float, hunt_speed: float = -1.0, creep: bool = true, need: int = 1, solids: Move.Solids = null, stunned := false, reach_walk := 0.0, other: OrderlyState = null) -> StepResult:
	var k := kind_of(prev)
	var res := _step_rules(plan, prev, players, dt, k.hunt_speed if hunt_speed < 0.0 else hunt_speed, creep, k, need, solids, stunned, reach_walk, other)
	if k.clicks() and not stunned:
		_stapler(prev, res, dt, k)
	return res

## The stapler, after the tick's rules. Stillness: a held body makes no sound and its clocks stop.
static func _stapler(prev: OrderlyState, res: StepResult, dt: float, k: BodySettings) -> void:
	var s := res.state
	s.clicks = 0
	if s.held or s.mode == &"bending":
		return
	if s.moving:
		s.click_wait = 0.0
		s.click_walk += M.hypot2(s.body.x - prev.body.x, s.body.z - prev.body.z)
		while k.click_step > 0.0 and s.click_walk >= k.click_step - EPS:
			s.click_walk -= k.click_step
			s.clicks += 1
			res.events.append({"type": "click", "t": s.t, "why": "walk"})
	elif k.click_wait > 0.0:
		s.click_wait += dt
		if s.click_wait >= k.click_wait - EPS:
			s.click_wait -= k.click_wait
			s.clicks += 1
			res.events.append({"type": "click", "t": s.t, "why": "wait"})

static func _step_rules(plan: Floor.FloorPlan, prev: OrderlyState, players: Array[PlayerView], dt: float, hunt_speed: float, creep: bool, k: BodySettings, need: int, solids: Move.Solids, stunned: bool, reach_walk := 0.0, other: OrderlyState = null) -> StepResult:
	var t := prev.t + dt
	var s := prev.copy()
	s.t = t
	s.moving = false
	s.speed = 0.0
	s.relocated = false
	var res := StepResult.new()
	res.state = s
	var events := res.events

	# 1. Is it seen? Decided before anything else, from where it stands now.
	var seer := seen_by(plan, prev.body, players, k)
	var seen := seer != null
	s.seen = seen
	if seen:
		s.last_seen_at = t
	# Held: seen now, or the time since it was last seen, measured from the start of this tick's
	# movement interval, is still under GRACE. With two watchers needed, by the count (see "Watchers").
	var held := _count_watchers(plan, prev, s, players, seer, dt, need, k)
	s.held = held
	# Relocation's clocks (see "Relocation"): no watcher since; the stand after an arrival runs down, seen or not.
	s.unwatched_for = 0.0 if (seen or not s.watchers.is_empty()) else prev.unwatched_for + dt
	var standing := prev.stand_left > EPS
	if standing:
		s.stand_left = maxf(0.0, prev.stand_left - dt)
	if seer != null and not prev.ever_seen:
		s.ever_seen = true
		events.append({"type": "firstSeen", "t": t, "playerId": seer.id})

	# 2. Mode changes that do not need it to move.
	if s.mode == &"waiting":
		if seen:
			s.seen_total += dt
		var near := _nearest_by_walk(plan, s.body, players)
		var close := near != null and near.steps * plan.cell_size < WAKE_DISTANCE
		if s.seen_total >= WAKE_SEEN_TIME - EPS or close or t >= WAKE_TIMEOUT - EPS:
			s.mode = &"hunting"
			s.replan_in = 0.0
			events.append({"type": "startedHunting", "t": t})
	elif s.mode == &"dormant":
		s.dormant_left -= dt
		if s.dormant_left <= EPS:
			s.dormant_left = 0.0
			s.mode = &"hunting"
			s.replan_in = 0.0
			# The end of a dormant spell (after a catch or a heal): the Stillness trigger to relocate.
			s.reloc_wish = true
			events.append({"type": "startedHunting", "t": t})
	elif s.mode == &"windUp" and (seer != null if s.need <= 1 else _met(s)):
		# Looking at it always saves you (enough eyes, when two are needed).
		events.append({"type": "windUpCancelled", "t": t, "playerId": s.wind_up_target if s.wind_up_target != null else ""})
		s.mode = &"hunting"
		s.wind_up_target = null
		s.wind_up_left = 0.0

	s.frozen = stunned or (held and (s.mode == &"hunting" or s.mode == &"windUp"))
	if s.frozen and not prev.frozen:
		events.append({"type": "froze", "t": t, "playerId": seer.id if seer != null else null})
	if not s.frozen and prev.frozen and (s.mode == &"hunting" or s.mode == &"windUp"):
		events.append({"type": "released", "t": t})
	if stunned:
		return res

	# Bent over a downed player (the documented exception, see the header): the bend goes on, seen or
	# not, and nothing else happens. The run decides when it ends.
	if s.mode == &"bending":
		s.anim = &"bend"
		s.anim_time += dt
		return res

	# 3. Held: nothing else changes. Position, facing, animation hint and clock all stay as they are.
	# Let go from a bend (stand_off), it keeps the bend until a tick nobody sees it.
	if held:
		if s.mode == &"waiting" or (s.mode == &"dormant" and s.anim != &"bend"):
			s.anim = &"idle"
		return res
	# Just arrived (see "Relocation"): it stands. No move, no turn, no chase, no catch, its clip's clock stopped.
	if standing:
		s.anim = &"idle"
		return res
	s.anim_time += dt

	# 4. Act.
	if s.mode == &"waiting" or s.mode == &"dormant":
		s.anim = &"idle"
		return res

	# Hidden players: going to look into a hide, or standing where it lost someone (see below).
	if s.mode == &"look" or s.mode == &"search":
		_step_hidden(plan, s, players, dt, hunt_speed, k, events, solids)
		return res

	if s.mode == &"windUp":
		var target := _find_player(players, s.wind_up_target)
		var ok := target != null and target.active and not target.hidden and target.body.level == s.body.level \
			and M.hypot2(target.body.x - s.body.x, target.body.z - s.body.z) <= REACH_RANGE
		if not ok:
			events.append({"type": "windUpCancelled", "t": t, "playerId": s.wind_up_target if s.wind_up_target != null else ""})
			s.mode = &"hunting"
			s.wind_up_target = null
			s.wind_up_left = 0.0
		else:
			# The Orderly fix: it keeps coming while it reaches, so a steady walk away no longer outpaces the reach.
			if reach_walk > 0.0 and k.name == &"orderly":
				_reach_walk(plan, s, target.body, hunt_speed * reach_walk, dt, k, solids)
			s.yaw = _turn_toward(s.yaw, yaw_toward(target.body.x - s.body.x, target.body.z - s.body.z), TURN_RATE * dt)
			s.wind_up_left -= dt
			s.anim = &"reach"
			if s.wind_up_left <= EPS:
				events.append({"type": "caught", "t": t, "playerId": target.id})
				s.mode = &"dormant"
				s.dormant_left = DORMANT_TIME
				s.wind_up_target = null
				s.wind_up_left = 0.0
				s.path = []
				s.target_id = null
				s.anim = &"idle"
			return res

	# Hunting and free to act. Close enough to someone on this level? Start reaching, do not move.
	var victim: PlayerView = null
	var victim_dist := INF
	for p in players:
		if not p.active or p.hidden or p.body.level != s.body.level:
			continue
		var d := M.hypot2(p.body.x - s.body.x, p.body.z - s.body.z)
		if d <= CATCH_RANGE and d < victim_dist:
			victim = p
			victim_dist = d
	if victim != null:
		s.mode = &"windUp"
		s.reloc_wish = false
		s.wind_up_target = victim.id
		s.wind_up_left = WIND_UP_TIME
		s.anim = &"reach"
		s.anim_time = 0.0
		events.append({"type": "windUp", "t": t, "playerId": victim.id})
		return res

	if _turn_to_hides(plan, s, players, events):
		_step_hidden(plan, s, players, dt, hunt_speed, k, events, solids)
		return res
	_hunt(plan, s, players, dt, hunt_speed, creep, k, solids, other)
	return res

## One tick of walking toward the nearest player. Mutates the (already copied) state. `other`: the first Orderly
## when this is the second with the Orderly fix (see "The Orderly fix"), else null.
static func _hunt(plan: Floor.FloorPlan, s: OrderlyState, players: Array[PlayerView], dt: float, hunt_speed: float, creep: bool, k: BodySettings, solids: Move.Solids = null, other: OrderlyState = null) -> void:
	s.replan_in -= dt
	if s.replan_in <= EPS or (solids == null and s.path.is_empty()):
		s.replan_in = REPLAN_INTERVAL
		var avoid := chasing(other)
		var near := _nearest_by_walk(plan, s.body, players) if other == null else _nearest_except(plan, s.body, players, avoid)
		s.target_id = near.player.id if near != null else null
		var flank: Array[Floor.Pos] = []
		if other != null:
			s.flank_goal = null
			if near != null and avoid != "" and str(near.player.id) == avoid:
				flank = flank_path(plan, Move.cell_of(plan, s.body), Move.cell_of(plan, near.player.body), Move.cell_of(plan, other.body))
				if solids != null and flank.size() > FLANK_AHEAD + 1:
					s.flank_goal = flank[FLANK_AHEAD]
		if near != null and solids == null:
			s.path = flank if not flank.is_empty() else Floor.find_path(plan, Move.cell_of(plan, s.body), Move.cell_of(plan, near.player.body))
		else:
			s.path = []
		s.path_next = 1 if s.path.size() > 1 else 0
	var target: PlayerView = null
	for p in players:
		if s.target_id != null and p.id == s.target_id and p.active and not p.hidden:
			target = p
			break
	if target == null or (solids == null and s.path.is_empty()):
		s.anim = &"idle"
		s.path = []
		s.resident_walk = null
		if solids != null:
			s.replan_in = 0.0
		return

	var before := s.body

	# How fast is the prey moving? Measured between hunting ticks and smoothed over about a quarter
	# of a second. A new target is assumed to be running until shown otherwise.
	if s.prey_id != null and s.prey_id == target.id and dt > EPS:
		var inst := minf(6.0, M.hypot2(target.body.x - s.prey_x, target.body.z - s.prey_z) / dt)
		s.prey_speed += (inst - s.prey_speed) * minf(1.0, dt * 4.0)
	else:
		s.prey_speed = HUNT_SPEED
	s.prey_id = target.id
	s.prey_x = target.body.x
	s.prey_z = target.body.z
	var gap := M.hypot2(target.body.x - before.x, target.body.z - before.z)
	var creeping := creep and target.body.level == before.level and gap < CREEP_DISTANCE and s.prey_speed < CREEP_PREY_SPEED
	var pace := k.creep_speed if creeping else hunt_speed

	var here := Move.cell_of(plan, before)
	if solids != null and s.flank_goal != null and (target.body.level != before.level or gap > FLANK_NEAR):
		# The Orderly fix: the second's own way round to the first's target (see "The Orderly fix").
		_resident_walk(plan, s, Move.body_at_cell(plan, s.flank_goal), pace * dt, k.radius, solids, 0.0)
	elif solids != null:
		_resident_walk(plan, s, target.body, pace * dt, k.radius, solids, APPROACH_STOP)
	elif _same_cell(here, Move.cell_of(plan, target.body)):
		var dx := target.body.x - before.x
		var dz := target.body.z - before.z
		var d := M.hypot2(dx, dz)
		var step := minf(pace * dt, d - APPROACH_STOP)
		if step > 1e-6:
			s.body = Move.move_with_collision(plan, before, (dx / d) * step, (dz / d) * step, k.radius)
	else:
		# step_path_walk only advances `next`; the path itself is never written to.
		var walk := Follow.PathWalk.make(s.path, s.path_next)
		s.body = Follow.step_path_walk(plan, walk, before, pace * dt, k.radius)
		s.path_next = walk.next
	s.speed = M.hypot2(s.body.x - before.x, s.body.z - before.z) / maxf(dt, EPS)

	var mx := s.body.x - before.x
	var mz := s.body.z - before.z
	var moved := M.hypot2(mx, mz)
	s.moving = moved > 1e-9
	if moved < 1e-4 and solids == null:
		s.replan_in = 0.0  # blocked or arrived: think again next tick

	var tx := target.body.x - s.body.x
	var tz := target.body.z - s.body.z
	var face_target := target.body.level == s.body.level and M.hypot2(tx, tz) <= FACE_TARGET_RANGE
	if face_target:
		s.yaw = _turn_toward(s.yaw, yaw_toward(tx, tz), TURN_RATE * dt)
	elif s.moving:
		s.yaw = _turn_toward(s.yaw, yaw_toward(mx, mz), TURN_RATE * dt)
	if s.moving:
		s.anim = &"duck" if k.ducks and near_door(plan, s.body, k.radius) else &"walk"
	else:
		s.anim = &"idle"

# ---------------------------------------------------------------------------------------------
# The Orderly fix (OR2; the owner's 20 Nov playtest). Only through step_entity's last two parameters, which sim/run.gd
# passes only in a run made with it (with_orderly_fix); their defaults are exactly the old rules.
#   - "The orderly will never catch you if you keep walking. He stops to swipe and then you go out of range so he
#     starts walking again." In its reach (windUp) it keeps walking at `reach_walk` of its hunt speed toward the
#     one it reaches for, stopping APPROACH_STOP short, so a walker (3 m/s) no longer opens the gap past
#     REACH_RANGE before the reach lands. A sprinter (5 m/s) still opens it and gets away while their stamina lasts.
#     Looking at it still cancels the reach the same tick, held it does not move: the reach is part of the hunt.
#   - "The two orderlies need to have different pathings and chase different players when multiplayer." The second
#     (given `other`, the first as it stands after its own step this tick) chases the nearest player by walking
#     other than the one the first chases (chasing(): hunting, its target; in its reach, the one it reaches for),
#     and only with nobody else to chase the same one. Chasing the same one, it plans its own way round
#     (flank_path): the shortest route on which cells of the first's route cost FLANK_COST more, so it takes
#     another corridor where there is one and comes at the target from another side.

## The player an Orderly is going after now ("" for nobody, and never the call's pull).
static func chasing(o: OrderlyState) -> String:
	if o == null:
		return ""
	if o.mode == &"windUp" and o.wind_up_target != null:
		return str(o.wind_up_target)
	if o.mode == &"hunting" and o.target_id != null and not str(o.target_id).begins_with("#"):
		return str(o.target_id)
	return ""

## The nearest active player by walking other than `avoid`; with nobody else, the nearest of all.
static func _nearest_except(plan: Floor.FloorPlan, body: Move.Body, players: Array[PlayerView], avoid: String) -> Nearest:
	if avoid == "":
		return _nearest_by_walk(plan, body, players)
	var rest: Array[PlayerView] = []
	for p in players:
		if p.id != avoid:
			rest.append(p)
	var near := _nearest_by_walk(plan, body, rest)
	return near if near != null else _nearest_by_walk(plan, body, players)

## Its own way from `from` to `to`, with the cells of the route from `first` to `to` (but its last FLANK_FREE) costing
## FLANK_COST steps more: from and to included, or [] when there is none. Ties go as Floor's searches do.
static func flank_path(plan: Floor.FloorPlan, from: Floor.Pos, to: Floor.Pos, first: Floor.Pos) -> Array[Floor.Pos]:
	var none: Array[Floor.Pos] = []
	if not Floor.is_walkable(plan, from.level, from.x, from.y) or not Floor.is_walkable(plan, to.level, to.x, to.y):
		return none
	var theirs := Floor.find_path(plan, first, to)
	var dear := {}
	for i in maxi(0, theirs.size() - FLANK_FREE):
		dear[Floor.pos_index(plan, theirs[i])] = true
	var adj := Floor.adjacency_of(plan)
	var total := plan.width * plan.height * 2
	var dist := PackedInt32Array()
	dist.resize(total)
	dist.fill(-1)
	var back := PackedInt32Array()
	back.resize(total)
	back.fill(-1)
	var goal := Floor.pos_index(plan, to)
	var start := Floor.pos_index(plan, from)
	# Dial's buckets: the costs are 1 and 1 + FLANK_COST.
	var buckets: Array[PackedInt32Array] = []
	for i in FLANK_COST + 2:
		buckets.append(PackedInt32Array())
	dist[start] = 0
	buckets[0].append(start)
	var d := 0
	var left := 1
	while left > 0:
		var b := buckets[d % buckets.size()]
		buckets[d % buckets.size()] = PackedInt32Array()
		for pi in b:
			left -= 1
			if dist[pi] != d:
				continue
			if pi == goal:
				left = 0
				break
			for k in range(adj.start[pi], adj.start[pi + 1]):
				var qi := adj.list[k]
				var nd := d + 1 + (FLANK_COST if dear.has(qi) else 0)
				if dist[qi] == -1 or nd < dist[qi]:
					dist[qi] = nd
					back[qi] = pi
					buckets[nd % buckets.size()].append(qi)
					left += 1
		d += 1
	if dist[goal] < 0:
		return none
	var rev: Array[Floor.Pos] = []
	var at := goal
	while at != -1:
		rev.append(Floor.pos_from_index(plan, at))
		at = back[at] if at != start else -1
	var out: Array[Floor.Pos] = []
	for i in range(rev.size() - 1, -1, -1):
		out.append(rev[i])
	return out

## In its reach, a step of `pace` m/s toward `goal`, stopping APPROACH_STOP short (the same walk as its hunt).
static func _reach_walk(plan: Floor.FloorPlan, s: OrderlyState, goal: Move.Body, pace: float, dt: float, k: BodySettings, solids: Move.Solids) -> void:
	var before := s.body
	if solids != null:
		_resident_walk(plan, s, goal, pace * dt, k.radius, solids, APPROACH_STOP)
	else:
		var dx := goal.x - before.x
		var dz := goal.z - before.z
		var d := M.hypot2(dx, dz)
		var step := minf(pace * dt, d - APPROACH_STOP)
		if step > 1e-6:
			s.body = Move.move_with_collision(plan, before, (dx / d) * step, (dz / d) * step, k.radius)
	var moved := M.hypot2(s.body.x - before.x, s.body.z - before.z)
	s.moving = moved > 1e-9
	s.speed = moved / maxf(dt, EPS)

# ---------------------------------------------------------------------------------------------
# Watchers: two-watcher Stillness (docs/floors/traits-and-hiding.md section 1, T19a).
#
# It is held when enough up players look at it: watch_need(up) of them, 1 with one or two up players and
# 2 with three or more (sim/run.gd counts the up players every tick, so a crew of three with one down needs
# one). A watcher is a player the view list gives as active (sim/run.gd: up; never a down, taken or
# left-behind player) whose view passes seen_by's test this tick (so never one who is blind), or did
# within GRACE: each watcher keeps counting for GRACE after their own last looking tick, so two glances
# that overlap by less than a frame still hold it. One player is one watcher, however long or well they look.
#   - Two needed: held while the count is met, and for GRACE after the last tick it was met. A lone
#     watcher does not hold it; a wind-up is cancelled the tick the count is met.
#   - One needed: exactly the old rule (held while anyone looks, and for GRACE after), so every one- and
#     two-player result is what it was. The count is kept all the same, for the screen.
# The host's holds (net/host.gd) reach the count through note_look (a player whose own screen says it sees
# it) and hold_met (a seen report it honours, a catch waiting for its victim's screen).

## Up players from which two watchers are needed.
const WATCH_CREW := 3

## Watchers needed to hold it with `up` up players on the floor: 1, 1, then 2.
static func watch_need(up: int) -> int:
	return 2 if up >= WATCH_CREW else 1

## The count this tick (s.watchers, s.need) is met.
static func _met(s: OrderlyState) -> bool:
	return s.watchers.size() >= s.need

## Counts this tick's watchers into `s` (need, watchers, looked_at, last_met_at) and returns whether it is
## held. `seer`: seen_by's answer this tick (the first player looking, in list order).
static func _count_watchers(plan: Floor.FloorPlan, prev: OrderlyState, s: OrderlyState, players: Array[PlayerView], seer: PlayerView, dt: float, need: int, k: BodySettings) -> bool:
	var t := s.t
	s.need = maxi(1, need)
	var looked := prev.looked_at
	var copied := false
	var watchers: Array[String] = []
	var after := false
	for p in players:
		if not p.active:
			continue
		var looks := false
		if seer != null:
			if p == seer:
				looks = true
				after = true
			elif after and not p.blind:
				# seen_by stopped at the first; the ones before it did not look.
				var one: Array[PlayerView] = [p]
				looks = seen_by(plan, prev.body, one, k) != null
		if looks:
			if not copied:
				looked = looked.duplicate()
				copied = true
			looked[p.id] = t
			watchers.append(p.id)
			if p.steady_gaze:
				watchers.append(p.id)
		elif looked.has(p.id) and t - dt - float(looked[p.id]) < GRACE - EPS:
			watchers.append(p.id)
	s.looked_at = looked
	s.watchers = watchers
	if watchers.size() >= s.need:
		s.last_met_at = t
	if s.need <= 1:
		return s.seen or (prev.last_seen_at != null and t - dt - float(prev.last_seen_at) < GRACE - EPS)
	return watchers.size() >= s.need or (prev.last_met_at != null and t - dt - float(prev.last_met_at) < GRACE - EPS)

## The host's hold: the count met at host time `at` (it is held then and for GRACE after). Never mutates `o`.
static func hold_met(o: OrderlyState, at: float) -> OrderlyState:
	if o.last_met_at != null and float(o.last_met_at) >= at:
		return o
	var s := o.copy()
	s.last_met_at = at
	return s

## Player `id` looked at it at host time `at` (their own screen says so): a watcher for GRACE after. Never
## mutates `o`.
static func note_look(o: OrderlyState, id: String, at: float) -> OrderlyState:
	if o.looked_at.has(id) and float(o.looked_at[id]) >= at:
		return o
	var s := o.copy()
	var l := o.looked_at.duplicate()
	l[id] = at
	s.looked_at = l
	return s

## Held by grace alone on the tick after `o`, whatever anyone does then.
static func held_by_grace(o: OrderlyState) -> bool:
	var last: Variant = o.last_seen_at if o.need <= 1 else o.last_met_at
	return last != null and o.t - float(last) < GRACE - EPS

## Keeps `from`'s count on `o` (a state rebuilt from an older one, the host's put-back). Mutates `o`.
static func keep_count(o: OrderlyState, from: OrderlyState) -> void:
	o.need = from.need
	o.watchers = from.watchers
	o.looked_at = from.looked_at
	o.last_met_at = from.last_met_at

# ---------------------------------------------------------------------------------------------
# Relocation: losing track of it (docs/floors/traits-and-hiding.md section 5; T19e). sim/relocate.gd decides
# when it leaves and where it arrives (sim/run.gd calls it after this step, only in a run with it on); what
# the resident itself does about it lives here:
#   - the Stillness trigger's clocks: unwatched_for (seconds since a watcher last counted, or it was seen) and
#     reloc_wish (set when a dormant spell ends, after a catch or a heal; cleared by a wind-up or a relocation);
#   - arrive(): the leaving and the arriving are one tick, `relocated` (the instrument never records it);
#     its walking sound stops that tick (it is not moving) and its arrival cue plays at full reach
#     (audibility, on that tick only);
#   - the stand: RELOCATE_STAND seconds after arriving it does not move, turn, chase or catch, its clip's
#     clock stopped, seen or not (the step above). Seen meanwhile, it is held as always.
# With relocation off nothing here ever runs (relocated stays false, stand_left 0), so every stored result is
# what it was.

## Seconds it stands after arriving.
const RELOCATE_STAND := 3.0

## The resident gone from where it stood and arrived at `body` this tick (host time `t`), facing `yaw`, going for
## `target` (a player id, or null). Never mutates `o`.
static func arrive(o: OrderlyState, body: Move.Body, yaw: float, t: float, target: Variant) -> OrderlyState:
	var s := o.copy()
	s.body = body
	s.yaw = yaw
	s.relocated = true
	s.relocations = o.relocations + 1
	s.stand_left = RELOCATE_STAND
	s.arrived_at = t
	s.hidden_for = 0.0
	s.unwatched_for = 0.0
	s.reloc_wish = false
	s.mode = &"hunting"
	s.anim = &"idle"
	s.anim_time = 0.0
	s.moving = false
	s.speed = 0.0
	s.frozen = false
	s.target_id = target
	s.path = []
	s.path_next = 0
	s.resident_walk = null
	s.replan_in = 0.0
	s.wind_up_target = null
	s.wind_up_left = 0.0
	s.dormant_left = 0.0
	s.prey_id = null
	s.prey_speed = HUNT_SPEED
	s.click_walk = 0.0
	s.click_wait = 0.0
	s.clicks = 0
	# Lonely (sim/lonely.gd): it lurks where it arrived, near the player it came for.
	if o.lonely_phase != &"":
		s.lonely_phase = &"lurk"
	s.lonely_target = null
	s.lonely_lost = 0.0
	s.lonely_quiet = 0.0
	return s

## Keeps `from`'s relocation bookkeeping on `o` (a state rebuilt from an older one, the host's put-back).
## Mutates `o`.
static func keep_relocation(o: OrderlyState, from: OrderlyState) -> void:
	o.relocated = false
	o.relocations = from.relocations
	o.stand_left = from.stand_left
	o.arrived_at = from.arrived_at
	o.retry_at = from.retry_at
	o.hidden_for = 0.0
	o.unwatched_for = 0.0
	o.reloc_wish = from.reloc_wish

# ---------------------------------------------------------------------------------------------
# Hidden players (docs/floors/traits-and-hiding.md section 4, T19b; sim/hiding.gd, stepped by sim/run.gd
# off the Playroom). One rule: it never sees into a hide and never takes a player out of one without a
# reason. A player inside a hide (PlayerView.hidden) is never hunted, reached for or a wake-up; sitting
# back they see nothing (the run makes them blind), peeking they look out of the gap (the run's view).
#   - A hide with a reason and someone in it (PlayerView.hide_reason): when it is free to hunt and that
#     hide's front is no further by walking than the nearest player it can hunt, it goes to the front
#     spot ("look" {hide}) and looks in for LOOK_TIME (mode "look", pose "reach"); then everyone in the
#     hide is caught by its own catch ("caught" for each, "lookDone" {hide, found}) and it is dormant as
#     after any catch. If the hide is empty, or has lost its reason, when it gets there: "emptyHide".
#   - Its target got into a hide without a reason: it walks to where it last saw them (where they began
#     getting in), stands there STAND_TIME ("search" mode; "lostTrack" {playerId}), then hunts someone else.
#     The lost player coming out ends the stand at once.
# Both are moving, so Stillness rules them: held, the walk, the look and the stand all stop. A player it
# can hunt within CATCH_RANGE is reached for as always. Nothing here happens while nobody is hidden.

## Looking into a hide takes this long; it looks from no further than LOOK_REACH from the front spot.
const LOOK_TIME := 2.0
const LOOK_REACH := 0.5
## Standing where it lost someone, seconds; it has arrived within SEARCH_ARRIVE metres.
const STAND_TIME := 4.0
const SEARCH_ARRIVE := 0.3

## The tests' deliberate break (tests/prop_hides.gd): "no_reason" looks into any hide with someone in it.
static var hide_break := ""

## While hunting, free to act and with nobody in reach: turns to a hide with a reason, or to standing where
## its target hid. Returns whether it did (mode "look" or "search"). Mutates the (already copied) state.
static func _turn_to_hides(plan: Floor.FloorPlan, s: OrderlyState, players: Array[PlayerView], events: Array[Dictionary]) -> bool:
	var any := false
	for p in players:
		if p.active and p.hidden:
			any = true
			break
	if not any:
		return false
	var best := -1
	var best_steps := 1 << 30
	var dist := PackedInt32Array()
	for p in players:
		if not p.active or not p.hidden or p.hide_front == null or (not p.hide_reason and hide_break != "no_reason"):
			continue
		if dist.is_empty():
			dist = _distances_cached(plan, Move.cell_of(plan, s.body))
		var steps := dist[Floor.pos_index(plan, Move.cell_of(plan, p.hide_front))]
		if steps >= 0 and steps < best_steps:
			best = p.hide
			best_steps = steps
	if best >= 0:
		var near := _nearest_by_walk(plan, s.body, players)
		if near == null or best_steps <= near.steps:
			s.mode = &"look"
			s.look_hide = best
			s.look_left = LOOK_TIME
			s.path = []
			s.replan_in = 0.0
			s.target_id = null
			events.append({"type": "look", "t": s.t, "hide": best})
			return true
	if s.target_id != null:
		var tp := _find_player(players, s.target_id)
		if tp != null and tp.active and tp.hidden and not tp.hide_reason:
			s.mode = &"search"
			s.search_spot = tp.hide_spot if tp.hide_spot != null else tp.hide_front
			s.search_left = STAND_TIME
			s.search_lost = tp.id
			s.path = []
			s.replan_in = 0.0
			s.target_id = null
			events.append({"type": "lostTrack", "t": s.t, "playerId": tp.id})
			return s.search_spot != null or _end_hidden(s)
	return false

## Back to hunting from "look" or "search". Returns false (for the caller's convenience).
static func _end_hidden(s: OrderlyState) -> bool:
	s.mode = &"hunting"
	s.look_hide = -1
	s.look_left = 0.0
	s.search_spot = null
	s.search_left = 0.0
	s.search_lost = null
	s.path = []
	s.replan_in = 0.0
	s.target_id = null
	return false

## One tick of "look" or "search", free to act. Mutates the (already copied) state.
static func _step_hidden(plan: Floor.FloorPlan, s: OrderlyState, players: Array[PlayerView], dt: float, hunt_speed: float, k: BodySettings, events: Array[Dictionary], solids: Move.Solids) -> void:
	# Someone it can hunt within reach: reached for as always.
	var victim: PlayerView = null
	var victim_dist := INF
	for p in players:
		if not p.active or p.hidden or p.body.level != s.body.level:
			continue
		var d := M.hypot2(p.body.x - s.body.x, p.body.z - s.body.z)
		if d <= CATCH_RANGE and d < victim_dist:
			victim = p
			victim_dist = d
	if victim != null:
		_end_hidden(s)
		s.mode = &"windUp"
		s.wind_up_target = victim.id
		s.wind_up_left = WIND_UP_TIME
		s.anim = &"reach"
		s.anim_time = 0.0
		events.append({"type": "windUp", "t": s.t, "playerId": victim.id})
		return
	if s.mode == &"look":
		var found: Array = []
		var front: Move.Body = null
		var at: Move.Body = null
		var reason := false
		for p in players:
			if p.active and p.hidden and p.hide == s.look_hide:
				found.append(p.id)
				front = p.hide_front
				at = p.hide_at
				reason = reason or p.hide_reason
		if found.is_empty() or front == null or (not reason and hide_break != "no_reason"):
			events.append({"type": "emptyHide", "t": s.t, "hide": s.look_hide})
			_end_hidden(s)
			s.anim = &"idle"
			return
		if M.hypot2(front.x - s.body.x, front.z - s.body.z) > LOOK_REACH or front.level != s.body.level:
			_walk_to(plan, s, front, hunt_speed, dt, k, solids)
			return
		if at != null:
			s.yaw = _turn_toward(s.yaw, yaw_toward(at.x - s.body.x, at.z - s.body.z), TURN_RATE * dt)
		s.anim = &"reach"
		s.look_left -= dt
		if s.look_left <= EPS:
			for id: String in found:
				events.append({"type": "caught", "t": s.t, "playerId": id})
			events.append({"type": "lookDone", "t": s.t, "hide": s.look_hide, "found": found})
			_end_hidden(s)
			s.mode = &"dormant"
			s.dormant_left = DORMANT_TIME
			s.anim = &"idle"
		return
	# "search": the lost player came out, or nothing to stand at.
	var lost := _find_player(players, s.search_lost)
	if s.search_spot == null or (lost != null and lost.active and not lost.hidden):
		_end_hidden(s)
		s.anim = &"idle"
		return
	var spot := s.search_spot
	if s.search_left >= STAND_TIME - EPS and (M.hypot2(spot.x - s.body.x, spot.z - s.body.z) > SEARCH_ARRIVE or spot.level != s.body.level):
		if _walk_to(plan, s, spot, hunt_speed, dt, k, solids):
			return
	# There (or as near as it can get): it stands.
	s.anim = &"idle"
	s.search_left -= dt
	if s.search_left <= EPS:
		events.append({"type": "searchEnd", "t": s.t, "playerId": str(s.search_lost)})
		_end_hidden(s)

## Walks toward a point at `speed` along the floor's paths (straight within its cell). Returns whether it
## moved. Mutates the (already copied) state.
static func _walk_to(plan: Floor.FloorPlan, s: OrderlyState, goal: Move.Body, speed: float, dt: float, k: BodySettings, solids: Move.Solids = null) -> bool:
	var before := s.body
	var here := Move.cell_of(plan, before)
	var there := Move.cell_of(plan, goal)
	s.replan_in -= dt
	if solids == null and (s.replan_in <= EPS or s.path.is_empty()):
		s.replan_in = REPLAN_INTERVAL
		s.path = Floor.find_path(plan, here, there)
		s.path_next = 1 if s.path.size() > 1 else 0
	if solids != null:
		_resident_walk(plan, s, goal, speed * dt, k.radius, solids)
	elif _same_cell(here, there):
		var dx := goal.x - before.x
		var dz := goal.z - before.z
		var d := M.hypot2(dx, dz)
		var step := minf(speed * dt, d)
		if step > 1e-6:
			s.body = Move.move_with_collision(plan, before, (dx / d) * step, (dz / d) * step, k.radius)
	elif not s.path.is_empty():
		var walk := Follow.PathWalk.make(s.path, s.path_next)
		s.body = Follow.step_path_walk(plan, walk, before, speed * dt, k.radius)
		s.path_next = walk.next
	var mx := s.body.x - before.x
	var mz := s.body.z - before.z
	var moved := M.hypot2(mx, mz)
	s.speed = moved / maxf(dt, EPS)
	s.moving = moved > 1e-9
	if moved < 1e-4:
		s.replan_in = 0.0
	if s.moving:
		s.yaw = _turn_toward(s.yaw, yaw_toward(mx, mz), TURN_RATE * dt)
		s.anim = &"duck" if k.ducks and near_door(plan, s.body, k.radius) else &"walk"
	else:
		s.anim = &"idle"
	return moved >= 1e-4

## The follow cursor belongs to this tick's copy; previous states retain their routes for reconciliation.
static func _resident_walk(plan: Floor.FloorPlan, s: OrderlyState, goal: Move.Body, max_dist: float, radius: float, solids: Move.Solids, stop: float = 0.0) -> void:
	s.resident_walk = s.resident_walk.copy() if s.resident_walk != null else Follow.ResidentWalk.new()
	s.body = Follow.step_resident_walk(plan, s.resident_walk, s.body, goal, max_dist, radius, solids, stop)

# ---------------------------------------------------------------------------------------------
# Sound.

class Audibility:
	## 0 (silent) to 1.
	var gain: float = 0.0
	## No line of sight: play it through a low-pass filter.
	var muffled: bool = false

	static func make(gain_: float, muffled_: bool) -> Audibility:
		var a := Audibility.new()
		a.gain = gain_
		a.muffled = muffled_
		return a

## How loud its sound is for a listener this tick. The Orderly's trolley squeak is silent unless it
## moved this tick: squeaking means nobody is watching it; silence means it is watched, or standing
## still. A body with a stapler is heard only in a tick it clicked (never while held). Falls off with
## straight-line distance to nothing at its hearing range; muffled and quieter without line of sight.
## On the tick it relocated (`relocated`) it is its arrival cue instead, at the same full reach (see "Relocation").
static func audibility(plan: Floor.FloorPlan, state: OrderlyState, listener_body: Move.Body, listener_eye: float) -> Audibility:
	var k := kind_of(state)
	if not state.relocated and not (state.clicks > 0 if k.clicks() else state.moving):
		return Audibility.make(0.0, false)
	var ear := Sight.eye_point(listener_body, listener_eye)
	var b := state.body
	var d := M.hypot3(b.x - ear.x, b.y + k.sound_height - ear.y, b.z - ear.z)
	if d >= k.hear_range:
		return Audibility.make(0.0, false)
	var base := M.pow_js(1.0 - d / k.hear_range, 2.0)
	var src := Sight.Point3.make(b.x, b.y + k.sound_height, b.z, b.level)
	var clear := Sight.has_line_of_sight(plan, ear, src)
	if not clear:
		for p in Sight.figure_points(b, ear.x, ear.z, k.height, k.radius):
			if Sight.has_line_of_sight(plan, ear, p):
				clear = true
				break
	return Audibility.make(base, false) if clear else Audibility.make(base * MUFFLED_GAIN, true)
