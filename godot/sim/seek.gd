# The Minder and the count: the Playroom's rules, pure and deterministic. Design:
# docs/floors/playarea.md sections 2 to 5, 7 and 8. No TypeScript twin: tests/prop_seek.gd is its proof.
#
# The Minder is a Hearing resident, not a Stillness one: looking at it does nothing. Outside a count it
# wanders a seeded round of the zones at 1.2 m/s and NEVER takes anyone. Any one tick of a provocation
# (sprinting, a squeaker tile or the ball pit at more than a creep, a flap let go, a dropped tape, an emote
# with a sound, bumping it, a light on it, a voice) starts a count: 6 s to hide, then 30, 35, 40, 45 s
# (45 after that). The party horn is harmless (owner): it never starts a count. For 15 s after a count
# nothing provokes. Calling the lift starts the last count (40 s), after which nothing provokes.
#
# During a count, after the 6 s, a player is found the tick one of these is true (judged after the
# Minder has moved this tick, from its new position and facing):
#   touch  out of a hide (getting in or out is out), same level, within TOUCH_RANGE of it;
#   sight  out of a hide, within SIGHT_RANGE horizontally, within SIGHT_HALF_DEG of its facing, and a
#          clear line (Sight.has_line_of_sight) from its head (MINDER_HEAD above its feet) to one of
#          BODY_POINTS on them; these ticks add up over the count, found at FOUND_TIME in total;
#   gap    peeking from inside a hide, the hide's inside spot within GAP_RANGE, within GAP_HALF_DEG of its
#          facing, with a clear line from its head to the hide's eye; found at FOUND_TIME in total;
#   look   it finished looking in the hide (LOOK_TIME at the front spot): everyone in it.
# One event names one cause; if several hold in one tick the order is look, touch, sight, gap.
#
# It searches in this order: a drawn hide not yet looked in; a reason (a hide it saw someone get into, a
# flap let go, an instrument ticking inside within 5 m, a horn blown from it); a player in its view in
# the open; the nearest hidden or unseen player's zone not yet cleared (way in, a 3 s full turn, then one
# draw of the zone's n hides from Rng "seek:<seed>:<depth>:<k>:<zone id>"); else the lift lobby.
# Found players are run down at 7 m/s and caught (3 s); taken players get a party-table seat.
#
# Health (from the end of the first count, outside counts and their 6 s, until the ride): walking
# drains 3/s, sprinting 8/s; standing, creeping or being in a hide restores 1/s; 0 is down.
#
# Units: Move.Body metres; hides from playroom.gd are whole centimetres. Maths through jsmath.gd.
# State is treated as immutable: step_seek copies and never edits what it was given.
extends RefCounted

const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Follow = preload("res://sim/follow.gd")
const Sight = preload("res://sim/sight.gd")
const Rng = preload("res://sim/rng.gd")
const Playroom = preload("res://sim/playroom.gd")
const M = preload("res://sim/jsmath.gd")
const Settings = preload("res://sim/settings.gd")

# ---------------------------------------------------------------------------------------------
# Tuning (playarea.md).

## The count: seconds to hide, then the count's length by its number on the floor (45 after that).
const HIDE_TIME := 6.0
const COUNT_LENGTHS: Array[float] = [30.0, 35.0, 40.0, 45.0]
const LAST_LENGTH := 40.0
## A call during a count: the last count starts this long after that count ends.
const LAST_AFTER := 6.0
## After a count ends nothing provokes for this long.
const CALM_TIME := 15.0

## Speeds, m/s.
const WANDER_SPEED := 1.2
const SEARCH_SPEED := 3.0
const RUN_SPEED := 7.0
const REPLAN := 0.5
const TURN_RATE := 6.0
const MINDER_RADIUS := 0.35
## Height of its head (the mask) above its feet, for sight. One number: on all fours is only a look.
const MINDER_HEAD := 1.4

## Found.
const SIGHT_RANGE := 12.0
const SIGHT_HALF_DEG := 60.0
const FOUND_TIME := 1.0
const TOUCH_RANGE := 0.9
const GAP_RANGE := 4.0
const GAP_HALF_DEG := 30.0
const LOOK_TIME := 2.0
## It looks in from no further than this from the hide's front spot.
const LOOK_REACH := 0.5
## Heights above a player's feet tested for a line from its head.
const BODY_POINTS: Array[float] = [0.3, 0.9, 1.5]

## Provocations.
const BUMP_RANGE := 0.5
const TICK_REASON_RANGE := 5.0

## Hides.
const HIDE_REACH := 1.2
const IN_SLOW := 1.5
const IN_FAST := 0.5
const OUT_SLOW := 1.0
const OUT_FAST := 0.4

## The search and the catch.
const SWEEP_TIME := 3.0
const CATCH_TIME := 3.0
const SLUMP_TIME := 1.0
const STRAIGHTEN_TIME := 3.0
const ARRIVE := 0.1
const STUCK_TIME := 1.0

## Health.
const HEALTH_MAX := 100.0
const WALK_DRAIN := 3.0
const SPRINT_DRAIN := 8.0
const REST_GAIN := 1.0

## The crew's noise level for the instrument's needle: walking, and anything that would start a count.
const NOISE_WALK := 0.2
const NOISE_FULL := 1.0

const EPS := 1e-9

# Provocation causes (the count event's "why").
const WHY_SPRINT := &"sprint"
const WHY_SQUEAKER := &"squeaker"
const WHY_BALLPIT := &"ballpit"
const WHY_FLAP := &"flap"
const WHY_TAPE := &"tape"
const WHY_EMOTE := &"emote"
const WHY_BUMP := &"bump"
const WHY_LIGHT := &"light"
const WHY_VOICE := &"voice"
const WHY_CALL := &"call"

static var SIGHT_COS := 0.0
static var GAP_COS := 0.0

static func _static_init() -> void:
	SIGHT_COS = M.cos_js(SIGHT_HALF_DEG * PI / 180.0)
	GAP_COS = M.cos_js(GAP_HALF_DEG * PI / 180.0)

# ---------------------------------------------------------------------------------------------
# Inputs.

## A lamp or flash: a cone from a point. It lights the Minder when Sight.can_see says the cone (no
## margin) reaches the Minder's figure within `range`. Built now and driven by a test light.
class Light:
	var x: float
	var y: float
	var z: float
	var level: int
	var yaw: float
	var pitch: float
	var half_deg: float
	var range: float

	static func make(x_: float, y_: float, z_: float, level_: int, yaw_: float, pitch_: float, half_deg_: float, range_: float) -> Light:
		var l := Light.new()
		l.x = x_
		l.y = y_
		l.z = z_
		l.level = level_
		l.yaw = yaw_
		l.pitch = pitch_
		l.half_deg = half_deg_
		l.range = range_
		return l

## One player's input for one tick.
class SeekInput:
	var id: String
	var body: Move.Body
	## &"creep" | &"walk" | &"sprint": the gait the player actually has this tick (stamina.gd gait_for).
	var gait: StringName = &"walk"
	var active: bool = true
	## F pressed this tick (an edge, not held): get into the hide in reach, or out of the one you are in.
	var use: bool = false
	## Sprint held as F is pressed: the fast way, which lets the flap go (a noise).
	var fast: bool = false
	## W held inside a hide: lean to the gap.
	var peek: bool = false
	## An emote that plays a sound (BUTTON and the like) was sent this tick.
	var emote_sound: bool = false
	## A tape of theirs hit the floor this tick (including the drop when they go down).
	var dropped_tape: bool = false
	## The party horn was blown. Harmless: never a provocation (owner).
	var horn: bool = false
	## Their instrument ticked this tick.
	var ticking: bool = false
	## Their voice was heard (the hook for when the microphone is built).
	var voice: bool = false
	## Their lamp or flash, or null.
	var light: Light = null

	static func make(id_: String, body_: Move.Body, gait_: StringName = &"walk") -> SeekInput:
		var i := SeekInput.new()
		i.id = id_
		i.body = body_
		i.gait = gait_
		return i

## What the run says about the floor this tick.
class FloorInput:
	## The call was accepted this tick (the quota met); who pressed it.
	var call: bool = false
	var call_by: String = ""
	## The car doors are open for boarding / the car is riding: no count can start. Health stops in a ride.
	var boarding: bool = false
	var riding: bool = false

# ---------------------------------------------------------------------------------------------
# The floor's lists, worked out once.

class SeekFloor:
	var plan: Floor.FloorPlan
	var hides: Array[Playroom.Hide] = []
	## hide id -> Playroom.Hide
	var hide_by_id: Dictionary = {}
	var zones: Array[Playroom.Zone] = []
	## zone id -> PackedInt32Array of its hide ids, in list order (the draw's order).
	var zone_hides: Dictionary = {}
	## zone id -> Array[Floor.Pos]: the room-side cells of its ways in.
	var way_in: Dictionary = {}
	## room id -> zone id, or -1.
	var room_zone: PackedInt32Array = PackedInt32Array()
	## pos_index -> true for every squeaker tile.
	var squeak: Dictionary = {}
	var seats: Array[Playroom.Seat] = []
	## The wander round: zone ids in a seeded order.
	var round: PackedInt32Array = PackedInt32Array()

	## `hide_list` null means Playroom.hides(plan); a test may pass its own (for a zone with none).
	static func make(plan_: Floor.FloorPlan, hide_list: Variant = null) -> SeekFloor:
		var f := SeekFloor.new()
		f.plan = plan_
		if hide_list == null:
			f.hides = Playroom.hides(plan_, plan_.seed)
		else:
			for h: Playroom.Hide in hide_list:
				f.hides.append(h)
		f.zones = Playroom.zones(plan_)
		var lay := Playroom.layout_of(plan_)
		if lay != null:
			f.room_zone = lay.room_zone
		for z in f.zones:
			f.zone_hides[z.id] = PackedInt32Array()
			var cells: Array[Floor.Pos] = []
			for di in z.doors:
				var d := plan_.doors[di]
				var ra := Floor.room_id_at(plan_, d.level, d.ax, d.ay)
				if ra >= 0 and f.room_zone[ra] == z.id:
					cells.append(Floor.Pos.make(d.level, d.ax, d.ay))
				else:
					cells.append(Floor.Pos.make(d.level, d.bx, d.by))
			f.way_in[z.id] = cells
		for h in f.hides:
			f.hide_by_id[h.id] = h
			if f.zone_hides.has(h.zone):
				var list: PackedInt32Array = f.zone_hides[h.zone]
				list.append(h.id)
				f.zone_hides[h.zone] = list
		for k in Playroom.squeakers(plan_, plan_.seed):
			f.squeak[k] = true
		f.seats = Playroom.seats(plan_)
		var order: Array[int] = []
		for z in f.zones:
			var cells: Array[Floor.Pos] = f.way_in[z.id]
			if not cells.is_empty():
				order.append(z.id)
		var rng := Rng.make_rng("seek:%s:%d:round" % [plan_.seed, plan_.depth])
		for i in range(order.size() - 1, 0, -1):
			var j := rng.int_in(0, i)
			var tmp := order[i]
			order[i] = order[j]
			order[j] = tmp
		f.round = PackedInt32Array(order)
		return f

# ---------------------------------------------------------------------------------------------
# State.

class SeekPlayer:
	var id: String
	## &"ok" | &"found" (rooted, the Minder is coming) | &"taken" (at the party table) | &"down" (health 0)
	var status: StringName = &"ok"
	## Where the rules hold the body: the input body, or the hide's inside spot while inside, or its
	## front spot while getting out. The run places the player here.
	var body: Move.Body = null
	## Last tick's input body, to tell whether they moved.
	var last: Move.Body = null
	## &"out" | &"entering" | &"inside" | &"leaving"
	var phase: StringName = &"out"
	## The hide being got into, sat in, or got out of; -1 when out.
	var hide: int = -1
	var phase_left: float = 0.0
	## In its view on some tick of getting in (a reason once they are in).
	var seen_entering: bool = false
	var peeking: bool = false
	## Seconds in its view this count, and seconds of the eye in the gap. Never drain within a count.
	var sight: float = 0.0
	var gap: float = 0.0
	var health: float = HEALTH_MAX
	## The zone they are in (a hidden player's is the hide's), or -1.
	var zone: int = -1
	## Party-table seat once taken, else -1.
	var seat: int = -1

	func copy() -> SeekPlayer:
		var p := SeekPlayer.new()
		p.id = id
		p.status = status
		p.body = body
		p.last = last
		p.phase = phase
		p.hide = hide
		p.phase_left = phase_left
		p.seen_entering = seen_entering
		p.peeking = peeking
		p.sight = sight
		p.gap = gap
		p.health = health
		p.zone = zone
		p.seat = seat
		return p

## The Minder: the same shape the network carries for a resident (body, yaw, mode, anim).
class MinderState:
	var t: float = 0.0
	var body: Move.Body
	## Facing, radians, three.js style (0 faces -z): the way its drawn face points.
	var yaw: float = 0.0
	## &"wander" | &"cover" (the 6 s) | &"search" | &"sweep" | &"look" | &"slump" | &"run" | &"catch"
	var mode: StringName = &"wander"
	## The pose: &"stand" | &"walk" | &"straighten" | &"cover" | &"prowl" | &"sweep" | &"look" | &"slump" | &"run" | &"catch"
	var anim: StringName = &"stand"
	var anim_time: float = 0.0
	var speed: float = 0.0
	var moving: bool = false
	var path: Array[Floor.Pos] = []
	var path_next: int = 0
	var replan_in: float = 0.0
	var stuck: float = 0.0
	## What it is walking to: kind (&"" none, &"round", &"draw", &"reason", &"player", &"zone", &"spot",
	## &"lobby", &"victim"), an id (zone, hide or player index), the cell and the point.
	var goal_kind: StringName = &""
	var goal_id: int = -1
	var goal_cell: Floor.Pos = null
	var goal_x: float = 0.0
	var goal_z: float = 0.0
	## Seconds left of a sweep, look, slump, catch or straightening.
	var timer: float = 0.0
	var round_i: int = 0
	## The hide drawn in the zone just swept, not yet looked in; the hide being looked in.
	var draw_hide: int = -1
	var look_hide: int = -1
	## The player being run down or caught.
	var victim: String = ""

	func copy() -> MinderState:
		var m := MinderState.new()
		m.t = t
		m.body = body
		m.yaw = yaw
		m.mode = mode
		m.anim = anim
		m.anim_time = anim_time
		m.speed = speed
		m.moving = moving
		m.path = path
		m.path_next = path_next
		m.replan_in = replan_in
		m.stuck = stuck
		m.goal_kind = goal_kind
		m.goal_id = goal_id
		m.goal_cell = goal_cell
		m.goal_x = goal_x
		m.goal_z = goal_z
		m.timer = timer
		m.round_i = round_i
		m.draw_hide = draw_hide
		m.look_hide = look_hide
		m.victim = victim
		return m

class SeekState:
	var t: float = 0.0
	var floor: SeekFloor
	var minder: MinderState
	var players: Array[SeekPlayer] = []
	## Counts started on this floor; the running (or last) count's number, start, length and cause.
	var counts: int = 0
	var counting: bool = false
	var t0: float = 0.0
	var len: float = 0.0
	var last: bool = false
	var by: String = ""
	var why: StringName = &""
	## Counts ended (health runs from the first).
	var ended: int = 0
	## Nothing provokes before this run time.
	var calm_until: float = 0.0
	## The lift was called: nothing provokes any more; the last count is running, pending or over.
	var called: bool = false
	var call_by: String = ""
	## Run time the pending last count starts, or null.
	var last_at: Variant = null
	## The last count is over.
	var done: bool = false
	## Hide ids with a reason this count, in the order logged.
	var reasons: PackedInt32Array = PackedInt32Array()
	## player id -> Vector2i(zone, hide): hidden (or standing) in a zone it has cleared this count.
	var ignored: Dictionary = {}
	## zone id -> draws made there this count.
	var visits: Dictionary = {}
	## The crew's loudest noise this tick, 0 to 1 (the instrument's needle outside a count).
	var noise: float = 0.0

	func copy() -> SeekState:
		var s := SeekState.new()
		s.t = t
		s.floor = floor
		s.minder = minder
		s.players = players
		s.counts = counts
		s.counting = counting
		s.t0 = t0
		s.len = len
		s.last = last
		s.by = by
		s.why = why
		s.ended = ended
		s.calm_until = calm_until
		s.called = called
		s.call_by = call_by
		s.last_at = last_at
		s.done = done
		s.reasons = reasons
		s.ignored = ignored
		s.visits = visits
		s.noise = noise
		return s

class SeekStep:
	var state: SeekState
	var events: Array[Dictionary] = []

# Events (Dictionaries of plain values):
#   {type: "count", t, n, t0, len, last, by, why}      a count starts (t0 == t: the 6 s start now)
#   {type: "countEnd", t, n, last}
#   {type: "hideStart", t, playerId, hide, fast}       getting in begins   {type: "hideIn", t, playerId, hide}
#   {type: "hideLeave", t, playerId, hide, fast}       getting out begins  {type: "hideOut", t, playerId, hide}
#   {type: "hideFull", t, playerId, hide}              a full hide refuses you
#   {type: "flap", t, playerId, hide}                  a flap or lid let go (a sound)
#   {type: "reason", t, hide, why, playerId}           why: "seen" | "flap" | "tick" | "horn"
#   {type: "sweep", t, zone}  {type: "draw", t, zone, n, hide, k}   (hide -1 when the zone has none)
#   {type: "look", t, hide}   {type: "lookDone", t, hide, found}    {type: "emptyHide", t, hide}
#   {type: "found", t, playerId, cause, hide}          cause: "look" | "touch" | "sight" | "gap"
#   {type: "taken", t, playerId, seat}                 {type: "down", t, playerId}

# ---------------------------------------------------------------------------------------------
# Small helpers.

static func yaw_toward(dx: float, dz: float) -> float:
	return M.atan2_js(-dx, -dz)

static func _wrap(a: float) -> float:
	var r := fmod(a, 2.0 * PI)
	if r > PI:
		r -= 2.0 * PI
	if r < -PI:
		r += 2.0 * PI
	return r

static func _turn(yaw: float, want: float, max_turn: float) -> float:
	var d := _wrap(want - yaw)
	return _wrap(yaw + maxf(-max_turn, minf(max_turn, d)))

static func _yaw_of_dir(d: StringName) -> float:
	return yaw_toward(float(Floor.dir_dx(d)), float(Floor.dir_dy(d)))

## A body standing at a whole-centimetre point of a level.
static func point_body(plan: Floor.FloorPlan, p: Vector2i, level: int) -> Move.Body:
	var x := p.x / 100.0
	var z := p.y / 100.0
	return Move.Body.make(x, z, level, Move.feet_height(plan, level, x, z))

static func hide_inside_body(plan: Floor.FloorPlan, h: Playroom.Hide) -> Move.Body:
	return point_body(plan, h.inside, h.level)

static func hide_front_body(plan: Floor.FloorPlan, h: Playroom.Hide) -> Move.Body:
	return point_body(plan, h.front, h.level)

## The count's phase at the state's time: &"none", &"hide" (the 6 s) or &"seek".
static func phase_of(s: SeekState) -> StringName:
	if not s.counting:
		return &"none"
	return &"hide" if s.t < s.t0 + HIDE_TIME - EPS else &"seek"

static func player_of(s: SeekState, id: String) -> SeekPlayer:
	for p in s.players:
		if p.id == id:
			return p
	return null

## The running count as its event (for a player who joins mid-count), or an empty Dictionary.
static func count_event(s: SeekState) -> Dictionary:
	if not s.counting:
		return {}
	return {"type": "count", "t": s.t0, "n": s.counts, "t0": s.t0, "len": s.len, "last": s.last, "by": s.by, "why": String(s.why)}

## The cosine of the angle between its facing and the way to (x, z); 1 when on top of it.
static func _facing_cos(m_body: Move.Body, yaw: float, x: float, z: float) -> float:
	var dx := x - m_body.x
	var dz := z - m_body.z
	var d := M.hypot2(dx, dz)
	if d < 1e-9:
		return 1.0
	return (dx * -M.sin_js(yaw) + dz * -M.cos_js(yaw)) / d

static func _head(m_body: Move.Body) -> Sight.Point3:
	return Sight.Point3.make(m_body.x, m_body.y + MINDER_HEAD, m_body.z, m_body.level)

## Rule 1's view: within SIGHT_RANGE, within SIGHT_HALF_DEG of its facing, a clear line from its head.
static func in_view(plan: Floor.FloorPlan, m_body: Move.Body, yaw: float, b: Move.Body) -> bool:
	if M.hypot2(b.x - m_body.x, b.z - m_body.z) > SIGHT_RANGE:
		return false
	if _facing_cos(m_body, yaw, b.x, b.z) < SIGHT_COS:
		return false
	var head := _head(m_body)
	for h in BODY_POINTS:
		if Sight.has_line_of_sight(plan, head, Sight.Point3.make(b.x, b.y + h, b.z, b.level)):
			return true
	return false

## Rule 4's eye in the gap (the peeking itself is the caller's to check).
static func eye_in_gap(plan: Floor.FloorPlan, m_body: Move.Body, yaw: float, h: Playroom.Hide) -> bool:
	var e := hide_inside_body(plan, h)
	if M.hypot2(e.x - m_body.x, e.z - m_body.z) > GAP_RANGE:
		return false
	if _facing_cos(m_body, yaw, e.x, e.z) < GAP_COS:
		return false
	return Sight.has_line_of_sight(plan, _head(m_body), Sight.Point3.make(e.x, e.y + h.eye / 100.0, e.z, e.level))

static func _touching(m_body: Move.Body, b: Move.Body, reach: float) -> bool:
	return b.level == m_body.level and M.hypot2(b.x - m_body.x, b.z - m_body.z) <= reach

## Whether a light lights the Minder.
static func lights(plan: Floor.FloorPlan, l: Light, m_body: Move.Body) -> bool:
	var v := Sight.Viewer.new()
	v.body = Move.Body.make(l.x, l.z, l.level, l.y)
	v.eye = 0.0
	v.yaw = l.yaw
	v.pitch = l.pitch
	v.h_fov_deg = 2.0 * l.half_deg
	v.v_fov_deg = 2.0 * l.half_deg
	return Sight.can_see(plan, v, m_body, 0.0, l.range, 2.3, MINDER_RADIUS)

static func _zone_at(f: SeekFloor, plan: Floor.FloorPlan, b: Move.Body) -> int:
	var c := Move.cell_of(plan, b)
	var r := Floor.room_id_at(plan, c.level, c.x, c.y)
	if r < 0 or r >= f.room_zone.size():
		return -1
	return f.room_zone[r]

static func _room_kind(plan: Floor.FloorPlan, b: Move.Body) -> StringName:
	var c := Move.cell_of(plan, b)
	var r := Floor.room_id_at(plan, c.level, c.x, c.y)
	return plan.rooms[r].kind if r >= 0 else &""

static func _room_id(plan: Floor.FloorPlan, b: Move.Body) -> int:
	var c := Move.cell_of(plan, b)
	return Floor.room_id_at(plan, c.level, c.x, c.y)

## The way to the nearest wall from the body's cell: the direction with the fewest open steps before a
## wall (n, e, s, w on a tie).
static func _wall_yaw(plan: Floor.FloorPlan, b: Move.Body) -> float:
	var c := Move.cell_of(plan, b)
	var best := 1 << 30
	var best_d := &"n"
	for d: StringName in [&"n", &"e", &"s", &"w"]:
		var dx := Floor.dir_dx(d)
		var dy := Floor.dir_dy(d)
		var x := c.x
		var y := c.y
		var steps := 0
		while steps < 8 and Floor.can_step_xy(plan, c.level, x, y, c.level, x + dx, y + dy):
			x += dx
			y += dy
			steps += 1
		if steps < best:
			best = steps
			best_d = d
	return _yaw_of_dir(best_d)

# ---------------------------------------------------------------------------------------------
# Creating.

## A floor's seek state: the Minder at the entity start facing its wall, everyone out of a hide at 100.
static func create_seek(plan: Floor.FloorPlan, player_ids: Array[String], floor_data: SeekFloor = null) -> SeekState:
	var s := SeekState.new()
	s.floor = floor_data if floor_data != null else SeekFloor.make(plan)
	var m := MinderState.new()
	m.body = Move.body_at_cell(plan, plan.entity_start)
	m.yaw = _yaw_of_dir(Playroom.entity_facing(plan))
	s.minder = m
	for id in player_ids:
		var p := SeekPlayer.new()
		p.id = id
		s.players.append(p)
	return s

# ---------------------------------------------------------------------------------------------
# The step.

## `tuning`: live settings (sim/settings.gd; null: none), the host's search and run speeds.
static func step_seek(prev: SeekState, inputs: Array[SeekInput], dt: float, fl: FloorInput = null, tuning: Settings.Values = null) -> SeekStep:
	if fl == null:
		fl = FloorInput.new()
	var s := prev.copy()
	var t := prev.t + dt
	s.t = t
	var plan := s.floor.plan
	var res := SeekStep.new()
	res.state = s
	var events := res.events
	var m := prev.minder.copy()
	m.t = t
	s.minder = m
	s.players = []
	for p in prev.players:
		s.players.append(p.copy())
	s.reasons = prev.reasons.duplicate()
	s.ignored = prev.ignored.duplicate()
	s.visits = prev.visits.duplicate()
	var input_of := {}
	for inp in inputs:
		input_of[inp.id] = inp
		if player_of(s, inp.id) == null:
			var np := SeekPlayer.new()
			np.id = inp.id
			s.players.append(np)

	# 1. The count clock.
	if s.counting and t >= s.t0 + HIDE_TIME + s.len - EPS:
		_end_count(s, t, events)
	if not s.counting and not s.done and s.last_at != null and t >= float(s.last_at) - EPS:
		s.last_at = null
		_start_count(s, t, s.call_by, WHY_CALL, true, events)
	# 2. The call starts the last count, now or after the running one.
	if fl.call and not s.called and not s.done:
		s.called = true
		s.call_by = fl.call_by
		if s.counting:
			s.last_at = s.t0 + HIDE_TIME + s.len + LAST_AFTER
		else:
			_start_count(s, t, fl.call_by, WHY_CALL, true, events)
	var phase := phase_of(s)
	var seeking := phase == &"seek"

	# 3. Players: moving, hides in and out, noises.
	var noisy := {}  # player id -> first provocation this tick
	var moved_of := {}
	var level := 0.0
	for p in s.players:
		var inp: SeekInput = input_of.get(p.id, null)
		if inp == null or not inp.active:
			continue
		var moved := p.last != null and (p.last.level != inp.body.level or M.hypot2(inp.body.x - p.last.x, inp.body.z - p.last.z) > 1e-6)
		var prev_body := p.last
		p.last = inp.body
		moved_of[p.id] = moved
		if inp.dropped_tape:
			_note(noisy, p.id, WHY_TAPE)
		if p.status != &"ok":
			continue
		var flap := false
		match p.phase:
			&"out":
				p.body = inp.body
				if inp.use:
					var h := _hide_in_reach(s, inp.body)
					if h != null:
						if _occupants(s, h.id) >= h.capacity:
							events.append({"type": "hideFull", "t": t, "playerId": p.id, "hide": h.id})
						else:
							p.phase = &"entering"
							p.hide = h.id
							p.phase_left = IN_FAST if inp.fast else IN_SLOW
							p.seen_entering = false
							events.append({"type": "hideStart", "t": t, "playerId": p.id, "hide": h.id, "fast": inp.fast})
							flap = inp.fast
			&"entering":
				p.body = inp.body
				p.phase_left -= dt
				if p.phase_left <= EPS:
					p.phase_left = 0.0
					p.phase = &"inside"
					p.body = hide_inside_body(plan, s.floor.hide_by_id[p.hide])
					events.append({"type": "hideIn", "t": t, "playerId": p.id, "hide": p.hide})
					if p.seen_entering and seeking:
						_reason(s, p.hide, &"seen", p.id, t, events)
			&"inside":
				var h: Playroom.Hide = s.floor.hide_by_id[p.hide]
				p.body = hide_inside_body(plan, h)
				if inp.use:
					p.phase = &"leaving"
					p.phase_left = OUT_FAST if inp.fast else OUT_SLOW
					p.body = hide_front_body(plan, h)
					events.append({"type": "hideLeave", "t": t, "playerId": p.id, "hide": h.id, "fast": inp.fast})
					flap = inp.fast
			&"leaving":
				var h: Playroom.Hide = s.floor.hide_by_id[p.hide]
				p.body = hide_front_body(plan, h)
				p.phase_left -= dt
				if p.phase_left <= EPS:
					events.append({"type": "hideOut", "t": t, "playerId": p.id, "hide": p.hide})
					p.phase_left = 0.0
					p.phase = &"out"
					p.hide = -1
		p.peeking = p.phase == &"inside" and inp.peek
		if flap:
			events.append({"type": "flap", "t": t, "playerId": p.id, "hide": p.hide})
			_note(noisy, p.id, WHY_FLAP)
			if seeking:
				_reason(s, p.hide, &"flap", p.id, t, events)
		if p.phase == &"out":
			var fast_gait := moved and inp.gait != &"creep"
			if inp.gait == &"sprint":
				_note(noisy, p.id, WHY_SPRINT)
			if fast_gait and s.floor.squeak.has(Floor.pos_index(plan, Move.cell_of(plan, inp.body))):
				_note(noisy, p.id, WHY_SQUEAKER)
			if fast_gait and prev_body != null and _room_kind(plan, inp.body) == &"ballpit" and _room_id(plan, prev_body) != _room_id(plan, inp.body):
				_note(noisy, p.id, WHY_BALLPIT)
			if fast_gait:
				level = maxf(level, NOISE_WALK)
		if inp.emote_sound:
			_note(noisy, p.id, WHY_EMOTE)
		if p.phase != &"inside" and _touching(m.body, p.body, BUMP_RANGE):
			_note(noisy, p.id, WHY_BUMP)
		if inp.light != null and lights(plan, inp.light, m.body):
			_note(noisy, p.id, WHY_LIGHT)
		if inp.voice:
			_note(noisy, p.id, WHY_VOICE)
		# The party horn is harmless (owner): it makes a sound but is never a provocation. From a hide
		# during a count it is a reason (section 9), though a seated player is never in one.
		if inp.horn and seeking and p.phase == &"inside":
			_reason(s, p.hide, &"horn", p.id, t, events)
		# The instrument ticking is a reason inside a hide within 5 m; outside a count it cannot happen.
		if inp.ticking and seeking and p.phase == &"inside":
			var hh: Playroom.Hide = s.floor.hide_by_id[p.hide]
			var hb := hide_inside_body(plan, hh)
			if _touching(m.body, hb, TICK_REASON_RANGE):
				_reason(s, p.hide, &"tick", p.id, t, events)
	if not noisy.is_empty():
		level = NOISE_FULL
	s.noise = level

	# 4. Provocations: one tick of any starts a count.
	if _may_provoke(s, t, fl) and not noisy.is_empty():
		for p in s.players:
			if noisy.has(p.id):
				_start_count(s, t, p.id, noisy[p.id], false, events)
				break
	phase = phase_of(s)
	seeking = phase == &"seek"

	# Zones and cleared marks.
	for p in s.players:
		if p.body == null:
			continue
		p.zone = s.floor.hide_by_id[p.hide].zone if p.phase == &"inside" else _zone_at(s.floor, plan, p.body)
		if s.ignored.has(p.id):
			var mark: Vector2i = s.ignored[p.id]
			if p.status != &"ok" or mark.x != p.zone or mark.y != (p.hide if p.phase == &"inside" else -1):
				s.ignored.erase(p.id)

	# 5. The Minder.
	var before := m.body
	m.moving = false
	m.speed = 0.0
	if phase == &"hide":
		m.mode = &"cover"
		m.anim = &"cover"
	elif seeking:
		_seek_step(s, m, input_of, dt, events, tuning)
	else:
		_wander_step(s, m, dt)
	m.speed = M.hypot2(m.body.x - before.x, m.body.z - before.z) / maxf(dt, EPS)
	m.moving = m.speed > 1e-9
	if phase != &"hide":
		m.anim_time += dt

	# 6. Found.
	if seeking:
		for p in s.players:
			var inp: SeekInput = input_of.get(p.id, null)
			if inp == null or not inp.active or p.status != &"ok":
				continue
			var cause := &""
			if p.phase != &"inside":
				var seen := in_view(plan, m.body, m.yaw, p.body)
				if seen:
					p.sight += dt
					if p.phase == &"entering":
						p.seen_entering = true
				if _touching(m.body, p.body, TOUCH_RANGE):
					cause = &"touch"
				elif p.sight >= FOUND_TIME - EPS:
					cause = &"sight"
			elif p.peeking and eye_in_gap(plan, m.body, m.yaw, s.floor.hide_by_id[p.hide]):
				p.gap += dt
				if p.gap >= FOUND_TIME - EPS:
					cause = &"gap"
			if cause != &"":
				_found(s, p, cause, t, events)

	# 7. Health.
	var health_on := s.ended >= 1 and not s.counting and not fl.riding
	if health_on:
		for p in s.players:
			var inp: SeekInput = input_of.get(p.id, null)
			if inp == null or not inp.active or p.status != &"ok":
				continue
			var rate := REST_GAIN
			if p.phase == &"out" and moved_of.get(p.id, false):
				if inp.gait == &"sprint":
					rate = -SPRINT_DRAIN
				elif inp.gait == &"walk":
					rate = -WALK_DRAIN
			p.health = clampf(p.health + rate * dt, 0.0, HEALTH_MAX)
			if p.health <= 0.0:
				p.health = 0.0
				p.status = &"down"
				p.phase = &"out"
				p.hide = -1
				p.peeking = false
				events.append({"type": "down", "t": t, "playerId": p.id})
	return res

static func _note(noisy: Dictionary, id: String, why: StringName) -> void:
	if not noisy.has(id):
		noisy[id] = why

static func _may_provoke(s: SeekState, t: float, fl: FloorInput) -> bool:
	return not s.counting and not s.called and not s.done and not fl.riding and not fl.boarding \
		and (s.ended == 0 or t >= s.calm_until - EPS)

static func _start_count(s: SeekState, t: float, by: String, why: StringName, last: bool, events: Array[Dictionary]) -> void:
	s.counts += 1
	s.counting = true
	s.t0 = t
	s.len = LAST_LENGTH if last else COUNT_LENGTHS[mini(s.counts - 1, COUNT_LENGTHS.size() - 1)]
	s.last = last
	s.by = by
	s.why = why
	s.reasons = PackedInt32Array()
	s.ignored = {}
	s.visits = {}
	for p in s.players:
		p.sight = 0.0
		p.gap = 0.0
		p.seen_entering = false
	var m := s.minder
	m.mode = &"cover"
	m.anim = &"cover"
	m.anim_time = 0.0
	m.yaw = _wall_yaw(s.floor.plan, m.body)
	m.path = []
	m.goal_kind = &""
	m.goal_cell = null
	m.timer = 0.0
	m.draw_hide = -1
	m.look_hide = -1
	m.victim = ""
	m.stuck = 0.0
	events.append({"type": "count", "t": t, "n": s.counts, "t0": t, "len": s.len, "last": last, "by": by, "why": String(why)})

static func _end_count(s: SeekState, t: float, events: Array[Dictionary]) -> void:
	# Anyone found before the count ends is taken, caught or not.
	for p in s.players:
		if p.status == &"found":
			_take(s, p, t, events)
	s.counting = false
	s.ended += 1
	s.calm_until = t + CALM_TIME
	if s.last:
		s.done = true
	s.reasons = PackedInt32Array()
	s.ignored = {}
	events.append({"type": "countEnd", "t": t, "n": s.counts, "last": s.last})
	var m := s.minder
	m.mode = &"wander"
	m.anim = &"stand"
	m.path = []
	m.goal_kind = &""
	m.goal_cell = null
	m.timer = 0.0
	m.draw_hide = -1
	m.look_hide = -1
	m.victim = ""
	m.stuck = 0.0

static func _reason(s: SeekState, hide: int, why: StringName, by: String, t: float, events: Array[Dictionary]) -> void:
	if hide < 0 or s.reasons.has(hide):
		return
	s.reasons.append(hide)
	events.append({"type": "reason", "t": t, "hide": hide, "why": String(why), "playerId": by})

static func _found(s: SeekState, p: SeekPlayer, cause: StringName, t: float, events: Array[Dictionary]) -> void:
	p.status = &"found"
	p.peeking = false
	events.append({"type": "found", "t": t, "playerId": p.id, "cause": String(cause), "hide": p.hide if p.phase != &"out" else -1})

static func _take(s: SeekState, p: SeekPlayer, t: float, events: Array[Dictionary]) -> void:
	var used := {}
	for q in s.players:
		if q.seat >= 0:
			used[q.seat] = true
	var seat := -1
	for i in s.floor.seats.size():
		if not used.has(i):
			seat = i
			break
	p.status = &"taken"
	p.seat = seat
	p.phase = &"out"
	p.hide = -1
	p.peeking = false
	if seat >= 0:
		var st := s.floor.seats[seat]
		p.body = point_body(s.floor.plan, st.at, st.level)
	events.append({"type": "taken", "t": t, "playerId": p.id, "seat": seat})

static func _hide_in_reach(s: SeekState, b: Move.Body) -> Playroom.Hide:
	var best: Playroom.Hide = null
	var best_d := INF
	for h in s.floor.hides:
		if h.level != b.level:
			continue
		var d := M.hypot2(h.front.x / 100.0 - b.x, h.front.y / 100.0 - b.z)
		if d <= HIDE_REACH and d < best_d:
			best = h
			best_d = d
	return best

static func _occupants(s: SeekState, hide: int) -> int:
	var n := 0
	for p in s.players:
		if (p.status == &"ok" or p.status == &"found") and p.phase != &"out" and p.hide == hide:
			n += 1
	return n

# ---------------------------------------------------------------------------------------------
# Moving.

## Walks toward the goal (cell and point) at `speed`. Returns 0 still going, 1 arrived, 2 stuck.
static func _walk(plan: Floor.FloorPlan, m: MinderState, speed: float, dt: float, face_point: bool) -> int:
	if m.goal_cell == null:
		return 2
	var before := m.body
	var here := Move.cell_of(plan, before)
	if m.replan_in <= EPS or m.path.is_empty():
		m.replan_in = REPLAN
		m.path = Floor.find_path(plan, here, m.goal_cell)
		m.path_next = 1 if m.path.size() > 1 else 0
		if m.path.is_empty():
			return 2
	m.replan_in -= dt
	if here.equals(m.goal_cell):
		var dx := m.goal_x - before.x
		var dz := m.goal_z - before.z
		var d := M.hypot2(dx, dz)
		var step := minf(speed * dt, d)
		if step > 1e-9:
			m.body = Move.move_with_collision(plan, before, (dx / d) * step, (dz / d) * step, MINDER_RADIUS)
	else:
		var walk := Follow.PathWalk.make(m.path, m.path_next)
		m.body = Follow.step_path_walk(plan, walk, before, speed * dt, MINDER_RADIUS)
		m.path_next = walk.next
	var mx := m.body.x - before.x
	var mz := m.body.z - before.z
	var moved := M.hypot2(mx, mz)
	if face_point and Move.cell_of(plan, m.body).level == m.goal_cell.level:
		var fx := m.goal_x - m.body.x
		var fz := m.goal_z - m.body.z
		if M.hypot2(fx, fz) > 1e-6:
			m.yaw = _turn(m.yaw, yaw_toward(fx, fz), TURN_RATE * dt)
	elif moved > 1e-9:
		m.yaw = _turn(m.yaw, yaw_toward(mx, mz), TURN_RATE * dt)
	var now := Move.cell_of(plan, m.body)
	if now.equals(m.goal_cell) and M.hypot2(m.goal_x - m.body.x, m.goal_z - m.body.z) <= ARRIVE:
		m.stuck = 0.0
		return 1
	if moved < 1e-4:
		m.stuck += dt
		m.replan_in = 0.0
		if m.stuck >= STUCK_TIME - EPS:
			m.stuck = 0.0
			return 2
	else:
		m.stuck = 0.0
	return 0

static func _set_goal(m: MinderState, kind: StringName, id: int, cell: Floor.Pos, x: float, z: float) -> void:
	var same := m.goal_kind == kind and m.goal_id == id and m.goal_cell != null and m.goal_cell.equals(cell)
	m.goal_kind = kind
	m.goal_id = id
	m.goal_x = x
	m.goal_z = z
	if not same:
		m.goal_cell = cell
		m.path = []
		m.replan_in = 0.0
		m.stuck = 0.0

static func _goal_body(plan: Floor.FloorPlan, m: MinderState, kind: StringName, id: int, b: Move.Body) -> void:
	_set_goal(m, kind, id, Move.cell_of(plan, b), b.x, b.z)

## Outside a count: the seeded round of the zones, stopping at each way in to straighten things.
static func _wander_step(s: SeekState, m: MinderState, dt: float) -> void:
	var plan := s.floor.plan
	m.mode = &"wander"
	if s.floor.round.is_empty():
		m.anim = &"stand"
		return
	if m.timer > EPS:
		m.timer -= dt
		m.anim = &"straighten"
		if m.timer <= EPS:
			m.timer = 0.0
			m.round_i = (m.round_i + 1) % s.floor.round.size()
			m.goal_kind = &""
		return
	var zid := s.floor.round[m.round_i % s.floor.round.size()]
	var cells: Array[Floor.Pos] = s.floor.way_in[zid]
	var c := cells[0]
	_goal_body(plan, m, &"round", zid, Move.body_at_cell(plan, c))
	var r := _walk(plan, m, WANDER_SPEED, dt, false)
	m.anim = &"walk"
	if r == 1:
		m.timer = STRAIGHTEN_TIME
		m.anim = &"straighten"
	elif r == 2:
		m.round_i = (m.round_i + 1) % s.floor.round.size()
		m.goal_kind = &""

## During a count, after the 6 s.
static func _seek_step(s: SeekState, m: MinderState, input_of: Dictionary, dt: float, events: Array[Dictionary], tuning: Settings.Values = null) -> void:
	var plan := s.floor.plan
	var t := s.t
	if m.mode == &"cover" or m.mode == &"wander":
		m.mode = &"search"
		m.goal_kind = &""
		m.path = []
	# Committed acts finish first: a sweep, a look, a slump, a catch.
	match m.mode:
		&"sweep":
			m.anim = &"sweep"
			m.timer -= dt
			m.yaw = _wrap(m.yaw + (2.0 * PI / SWEEP_TIME) * dt)
			if m.timer <= EPS:
				m.timer = 0.0
				_after_sweep(s, m, t, events)
			return
		&"look":
			m.anim = &"look"
			m.timer -= dt
			if m.timer <= EPS:
				m.timer = 0.0
				_look_done(s, m, t, events)
			return
		&"slump":
			m.anim = &"slump"
			m.timer -= dt
			if m.timer <= EPS:
				m.timer = 0.0
				m.mode = &"search"
				m.goal_kind = &""
			return
		&"catch":
			m.anim = &"catch"
			m.timer -= dt
			if m.timer <= EPS:
				m.timer = 0.0
				var v := player_of(s, m.victim)
				if v != null and v.status == &"found":
					var hide := v.hide if v.phase != &"out" else -1
					_take(s, v, t, events)
					if hide >= 0:
						for q in s.players:
							if q.status == &"found" and q.phase != &"out" and q.hide == hide:
								_take(s, q, t, events)
				m.victim = ""
				m.mode = &"search"
				m.goal_kind = &""
			return
	# Someone found: run them down.
	var victim := player_of(s, m.victim)
	if victim == null or victim.status != &"found":
		victim = null
		m.victim = ""
		for p in s.players:
			var inp: SeekInput = input_of.get(p.id, null)
			if p.status == &"found" and inp != null and inp.active:
				victim = p
				m.victim = p.id
				break
	if victim != null:
		m.mode = &"run"
		m.anim = &"run"
		var target := hide_front_body(plan, s.floor.hide_by_id[victim.hide]) if victim.phase != &"out" else victim.body
		_goal_body(plan, m, &"victim", 0, target)
		var r := _walk(plan, m, Settings.f(tuning, &"minder.run_speed", RUN_SPEED), dt, true)
		if r != 0 or M.hypot2(target.x - m.body.x, target.z - m.body.z) <= TOUCH_RANGE:
			m.mode = &"catch"
			m.timer = CATCH_TIME
			m.anim = &"catch"
		return
	m.mode = &"search"
	m.anim = &"prowl"
	if m.replan_in <= EPS or m.goal_kind == &"" or m.goal_cell == null:
		_choose(s, m, input_of)
	var face := m.goal_kind == &"player"
	var r2 := _walk(plan, m, Settings.f(tuning, &"minder.search_speed", SEARCH_SPEED), dt, face)
	if r2 == 0:
		return
	match m.goal_kind:
		&"draw", &"reason":
			var h: Playroom.Hide = s.floor.hide_by_id[m.goal_id]
			var front := hide_front_body(plan, h)
			if M.hypot2(front.x - m.body.x, front.z - m.body.z) <= LOOK_REACH and front.level == m.body.level:
				m.mode = &"look"
				m.timer = LOOK_TIME
				m.look_hide = h.id
				m.anim = &"look"
				var ins := hide_inside_body(plan, h)
				m.yaw = yaw_toward(ins.x - m.body.x, ins.z - m.body.z)
				events.append({"type": "look", "t": t, "hide": h.id})
			else:
				# Cannot stand there: give that look up.
				if m.goal_kind == &"draw":
					m.draw_hide = -1
				else:
					_drop_reason(s, h.id)
			m.goal_kind = &""
		&"zone", &"spot":
			m.mode = &"sweep"
			m.timer = SWEEP_TIME
			m.anim = &"sweep"
			events.append({"type": "sweep", "t": t, "zone": m.goal_id if m.goal_kind == &"zone" else -1})
		_:
			m.goal_kind = &""
			m.replan_in = REPLAN

static func _drop_reason(s: SeekState, hide: int) -> void:
	var out := PackedInt32Array()
	for h in s.reasons:
		if h != hide:
			out.append(h)
	s.reasons = out

static func _after_sweep(s: SeekState, m: MinderState, t: float, events: Array[Dictionary]) -> void:
	m.mode = &"search"
	var kind := m.goal_kind
	var zid := m.goal_id
	m.goal_kind = &""
	if kind != &"zone":
		return
	var list: PackedInt32Array = s.floor.zone_hides.get(zid, PackedInt32Array())
	var n := list.size()
	var v: int = s.visits.get(zid, 0)
	s.visits[zid] = v + 1
	var hide := -1
	if n > 0:
		var key := "seek:%s:%d:%d:%d" % [s.floor.plan.seed, s.floor.plan.depth, s.counts, zid]
		if v > 0:
			key += ":%d" % v
		hide = list[Rng.make_rng(key).int_in(0, n - 1)]
		m.draw_hide = hide
	events.append({"type": "draw", "t": t, "zone": zid, "n": n, "hide": hide, "k": s.counts})
	# The zone is cleared: everyone in it now is ignored until they give a reason, come out or leave.
	for p in s.players:
		if p.status == &"ok" and p.zone == zid:
			s.ignored[p.id] = Vector2i(zid, p.hide if p.phase == &"inside" else -1)

static func _look_done(s: SeekState, m: MinderState, t: float, events: Array[Dictionary]) -> void:
	var h := m.look_hide
	m.look_hide = -1
	if m.draw_hide == h:
		m.draw_hide = -1
	_drop_reason(s, h)
	var found := 0
	for p in s.players:
		if p.status == &"ok" and p.phase != &"out" and p.hide == h:
			found += 1
	events.append({"type": "lookDone", "t": t, "hide": h, "found": found})
	for p in s.players:
		if p.status == &"ok" and p.phase != &"out" and p.hide == h:
			_found(s, p, &"look", t, events)
	if found == 0:
		events.append({"type": "emptyHide", "t": t, "hide": h})
		m.mode = &"slump"
		m.timer = SLUMP_TIME
		m.anim = &"slump"
	else:
		m.mode = &"search"
	m.goal_kind = &""

## Picks what to walk to, in the design's order of priority.
static func _choose(s: SeekState, m: MinderState, input_of: Dictionary) -> void:
	var plan := s.floor.plan
	var here := Move.cell_of(plan, m.body)
	var dist := Floor.distances_from(plan, here)
	# 0. The hide it drew, not yet looked in.
	if m.draw_hide >= 0:
		var hb := hide_front_body(plan, s.floor.hide_by_id[m.draw_hide])
		_goal_body(plan, m, &"draw", m.draw_hide, hb)
		return
	# 1. The nearest reason.
	var best := -1
	var best_d := 1 << 30
	for h in s.reasons:
		var fb := hide_front_body(plan, s.floor.hide_by_id[h])
		var d := dist[Floor.pos_index(plan, Move.cell_of(plan, fb))]
		if d >= 0 and d < best_d:
			best = h
			best_d = d
	if best >= 0:
		_goal_body(plan, m, &"reason", best, hide_front_body(plan, s.floor.hide_by_id[best]))
		return
	# 2. A player in its view in the open: straight at the nearest.
	var view_i := -1
	var view_d := INF
	for i in s.players.size():
		var p := s.players[i]
		if not _hunted(p, input_of) or p.phase == &"inside":
			continue
		if in_view(plan, m.body, m.yaw, p.body):
			var d := M.hypot2(p.body.x - m.body.x, p.body.z - m.body.z)
			if d < view_d:
				view_i = i
				view_d = d
	if view_i >= 0:
		_goal_body(plan, m, &"player", view_i, s.players[view_i].body)
		return
	# 3. The nearest hidden or unseen player's zone not yet cleared (or, out of every zone, their spot).
	var pick_kind := &""
	var pick_id := -1
	var pick_cell: Floor.Pos = null
	best_d = 1 << 30
	for i in s.players.size():
		var p := s.players[i]
		if not _hunted(p, input_of) or s.ignored.has(p.id):
			continue
		if p.zone >= 0 and s.floor.way_in.has(p.zone):
			var cells: Array[Floor.Pos] = s.floor.way_in[p.zone]
			for c in cells:
				var d := dist[Floor.pos_index(plan, c)]
				if d >= 0 and (d < best_d or (d == best_d and pick_kind == &"zone" and p.zone < pick_id)):
					best_d = d
					pick_kind = &"zone"
					pick_id = p.zone
					pick_cell = c
		else:
			var c := Move.cell_of(plan, p.body)
			# A spot keeps the cell it set off for until it gets there.
			if m.goal_kind == &"spot" and m.goal_id == i and m.goal_cell != null:
				c = m.goal_cell
			var d := dist[Floor.pos_index(plan, c)]
			if d >= 0 and d < best_d:
				best_d = d
				pick_kind = &"spot"
				pick_id = i
				pick_cell = c
	if pick_cell != null:
		_goal_body(plan, m, pick_kind, pick_id, Move.body_at_cell(plan, pick_cell))
		return
	# 4. Nobody left to look for: towards the lift lobby.
	_goal_body(plan, m, &"lobby", 0, Move.body_at_cell(plan, plan.landing))

static func _hunted(p: SeekPlayer, input_of: Dictionary) -> bool:
	var inp: SeekInput = input_of.get(p.id, null)
	return p.status == &"ok" and inp != null and inp.active and p.body != null
