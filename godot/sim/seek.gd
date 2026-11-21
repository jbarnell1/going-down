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
# T15m, the owner's first play (on only for a state made with tune(): sim/run.gd playroom_tuned, which the
# game's rooms turn on; every stored result has it off, and then none of this happens). See the "T15m"
# section at the end for the rules and their numbers:
#   - the time to hide is TUNED_HIDE_LENGTHS (30, 35, 40, 45 s, 45 after that; the last count TUNED_LAST_HIDE),
#     and every search after it lasts TUNED_SEARCH; the count event carries "hide" (its hiding seconds);
#   - anger (0 to 1, the HUD's bar): each provocation adds to it (ANGER_RATES a second while it lasts,
#     ANGER_LUMPS once), it cools by ANGER_COOL a second while nobody provokes, and a count starts the tick
#     it is full ("by" and "why" are the provocation that filled it). Full through a count, draining to
#     empty over the CALM_TIME after it;
#   - outside a count, anyone out of a hide within GRAB_RANGE of the Minder is grabbed ("found" cause
#     "grab"): it holds them GRAB_TIME, then drags them to the party table at DRAG_SPEED, where they are
#     "taken". A count starting meanwhile seats them at once;
#   - hint events for the announcer: "playroomArrived" (the first tick on the floor) and "sprintDuringHunt"
#     (a player starts sprinting while it searches).
#
# PT1, the owner's playtest of 19 Nov (on only for a state made with with_hunt(): sim/run.gd minder_hunt, which the
# game's rooms turn on; off, nothing of this happens). "The goal is to make it so that when it hunts, players don't
# just run from it, they actually hide." See the "PT1" section at the end:
#   - an instrument ticking is never anything the Minder acts on: never a reason to look in a hide;
#   - the anger bar fills sooner: HUNT_ANGER_SPRINT seconds of sprinting, or HUNT_ANGER_NOISE in 100 a noise
#     (still the host's minder.anger_sprint and minder.anger_noise when set);
#   - health drains only while it hunts (a count's search, after the time to hide, until the count ends):
#     walking WALK_DRAIN a second, sprinting SPRINT_DRAIN. Standing, creeping or being in a hide gives back
#     REST_GAIN a second at any time on the floor; walking or sprinting outside a search costs nothing. Never
#     in a ride.
#
# The party table, from the owner's words of 19 Nov (T15h; on only for a state made with with_party(): sim/run.gd
# party_table, which the game's rooms turn on with the tuned Playroom; off, nothing of this happens). "Make it a
# requirement that the players find their teammate ... hold F at the table for 3s to free everyone seated with 50
# health, but freeing the table should trigger half the aggro bar. And the aggro bar should not go down on its
# own." See the "Party table" section at the end:
#   - a player out of a hide holding F (SeekInput.hold) within FETCH_REACH of a party-table seat, on its level,
#     while anyone is seated, fetches: FETCH_TIME seconds held frees everyone seated ("fetchStart", "fetchStop",
#     "tableFreed"). Any time, a count included. Each is back on their feet at their seat's spot with the host's
#     heal.health (HEAL_HEALTH 50). At the table F does not get anyone into a hide while someone is seated;
#   - freeing the table is a provocation of the fetcher's (WHY_FETCH): FETCH_ANGER (half the bar) with the
#     tuned Playroom, so it can start a count as any other one (outside a count and its calm);
#   - the anger bar never cools by itself (minder.anger_cool does nothing). It is still full through a count
#     and drains to empty over the calm after it, as before.
# The lift leaving with someone still seated is the run's (sim/run.gd party_table): they are left out.
#
# Health's rates are the host's health.walk, health.sprint and health.rest when set (WALK_DRAIN, SPRINT_DRAIN,
# REST_GAIN otherwise: an untuned state drains exactly as before).
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
## A wind-up toy starting to rattle (the shop, S2: sim/shop.gd), its owner's noise, once, as a dropped tape is.
const WHY_TOY := &"toy"
## Freeing the party table (with_party; see the section at the end), the fetcher's.
const WHY_FETCH := &"fetch"
## MA1 (with_calm): getting into a hide, and opening something (a drawer, a box).
const WHY_HIDE := &"hide"
const WHY_OPEN := &"open"

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
	## The shop (S2): this player's wind-up toy starts rattling this tick (a provocation, as a noise is).
	var toy: bool = false
	## Their instrument ticked this tick.
	var ticking: bool = false
	## Their voice was heard (the hook for when the microphone is built).
	var voice: bool = false
	## Their lamp or flash, or null.
	var light: Light = null
	## F held this tick (with_party: at the party table it fetches).
	var hold: bool = false
	## MA1 (with_calm): they began opening something this tick (a drawer, a box: the run's "searchStart").
	var opened: bool = false

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
	## (T15m, outside a count: &"grab" holding a grabbed player, &"drag" taking them to the party table)
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
	## T15m (tune(); see the section at the end). Off: hide_len stays HIDE_TIME and the rest is never read.
	var tuned: bool = false
	## The running (or last) count's seconds to hide.
	var hide_len: float = HIDE_TIME
	## How angry it is, 0 to 1: the HUD's bar.
	var anger: float = 0.0
	## "playroomArrived" has been said.
	var arrived: bool = false
	## player id -> true: sprinting on the last tick of a search (for "sprintDuringHunt").
	var sprinting: Dictionary = {}
	## The grabbed player being dragged to the party table: the seat it drags them to, and the drag's start.
	var drag_seat: int = -1
	var drag_t0: float = 0.0
	## PT1 (with_hunt; see the section at the end). Off: every rule above is as every stored result has it.
	var hunt: bool = false
	## The party table (with_party; see the section at the end). Off: every rule above is as before.
	var party: bool = false
	## Who is holding F at the table to free it, and the host time the hold counts from (-1: nobody).
	var fetch_by: String = ""
	var fetch_from: float = -1.0
	## The hold's length, stamped as it began (the host's party.free_time then): a hold already under way ends
	## when its "fetchStart" said, whatever is changed meanwhile.
	var fetch_len: float = FETCH_TIME
	## MA1 (with_calm; see the section at the end). Off: every rule above is as before.
	var calm: bool = false

	func copy() -> SeekState:
		var s := SeekState.new()
		s.calm = calm
		s.hunt = hunt
		s.party = party
		s.fetch_by = fetch_by
		s.fetch_from = fetch_from
		s.fetch_len = fetch_len
		s.tuned = tuned
		s.hide_len = hide_len
		s.anger = anger
		s.arrived = arrived
		s.sprinting = sprinting
		s.drag_seat = drag_seat
		s.drag_t0 = drag_t0
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
#   {type: "found", t, playerId, cause, hide}          cause: "look" | "touch" | "sight" | "gap" (T15m: "grab")
#   {type: "taken", t, playerId, seat}                 {type: "down", t, playerId}
# T15m only: "count" gains "hide" (its seconds to hide); {type: "playroomArrived", t, depth} on the first
# tick on the floor; {type: "sprintDuringHunt", t, playerId, n} the tick a player starts sprinting while it
# searches.

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
	return &"hide" if s.t < s.t0 + s.hide_len - EPS else &"seek"

static func party_horn(s: SeekState, id: String, t: float) -> Dictionary:
	if not s.tuned:
		return {}
	var player := player_of(s, id)
	if player == null or player.status != &"taken" or player.seat < 0 or player.body == null:
		return {}
	return {"type": "partyHorn", "playerId": id, "t": t, "x": player.body.x, "y": player.body.y + 1.0, "z": player.body.z}

static func player_of(s: SeekState, id: String) -> SeekPlayer:
	for p in s.players:
		if p.id == id:
			return p
	return null

## The running count as its event (for a player who joins mid-count), or an empty Dictionary.
static func count_event(s: SeekState) -> Dictionary:
	if not s.counting:
		return {}
	var e := {"type": "count", "t": s.t0, "n": s.counts, "t0": s.t0, "len": s.len, "last": s.last, "by": s.by, "why": String(s.why)}
	if s.tuned:
		e["hide"] = s.hide_len
	return e

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

## Whether the directed light reaches the figure, using the Minder's dimensions by default.
static func lights(plan: Floor.FloorPlan, l: Light, body: Move.Body, height := 2.3, radius := MINDER_RADIUS) -> bool:
	var v := Sight.Viewer.new()
	v.body = Move.Body.make(l.x, l.z, l.level, l.y)
	v.eye = 0.0
	v.yaw = l.yaw
	v.pitch = l.pitch
	v.h_fov_deg = 2.0 * l.half_deg
	v.v_fov_deg = 2.0 * l.half_deg
	return Sight.can_see(plan, v, body, 0.0, l.range, height, radius)

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
	_live = tuning
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
	if s.counting and t >= s.t0 + s.hide_len + s.len - EPS:
		_end_count(s, t, events)
	if not s.counting and not s.done and s.last_at != null and t >= float(s.last_at) - EPS:
		s.last_at = null
		_start_count(s, t, s.call_by, WHY_CALL, true, events)
	# 2. The call starts the last count, now or after the running one.
	if fl.call and not s.called and not s.done:
		s.called = true
		s.call_by = fl.call_by
		if s.counting:
			s.last_at = s.t0 + s.hide_len + s.len + LAST_AFTER
		else:
			_start_count(s, t, fl.call_by, WHY_CALL, true, events)
	var phase := phase_of(s)
	var seeking := phase == &"seek"

	# 3. Players: moving, hides in and out, noises.
	var noisy := {}  # player id -> this tick's provocations, in order (Array[StringName])
	var calm_gain := {}  # MA1: player id -> anger this tick from getting into a hide or opening something
	var moved_of := {}
	var level := 0.0
	# The party table: with someone seated, F at the table frees them and gets nobody into a hide.
	var table_busy := s.party and seated_ids(s).size() > 0
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
		if inp.toy:
			_note(noisy, p.id, WHY_TOY)
		if p.status != &"ok":
			continue
		if s.calm and inp.opened:
			_calm_note(calm_gain, p.id, calm_open_anger(_live), WHY_OPEN)
		var flap := false
		match p.phase:
			&"out":
				p.body = inp.body
				if inp.use and not (table_busy and at_table(s, inp.body)):
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
							if s.calm:
								_calm_note(calm_gain, p.id, calm_hide_anger(_live), WHY_HIDE)
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
		# PT1: the Minder never acts on an instrument.
		if inp.ticking and seeking and p.phase == &"inside" and not s.hunt:
			var hh: Playroom.Hide = s.floor.hide_by_id[p.hide]
			var hb := hide_inside_body(plan, hh)
			if _touching(m.body, hb, TICK_REASON_RANGE):
				_reason(s, p.hide, &"tick", p.id, t, events)
	# The party table: the fetcher's hold, after everyone has moved (see the section at the end).
	if s.party:
		_fetch_step(s, input_of, t, dt, noisy, events)
	if not noisy.is_empty():
		level = NOISE_FULL
	s.noise = level

	# 4. Provocations: one tick of any starts a count (T15m: they fill the anger bar, and a full bar does).
	if s.tuned:
		_tuned_provoke(s, t, dt, noisy, moved_of, input_of, fl, events, calm_gain)
	elif _may_provoke(s, t, fl) and not noisy.is_empty():
		for p in s.players:
			if noisy.has(p.id):
				_start_count(s, t, p.id, noisy[p.id][0], false, events)
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
	elif s.tuned and (m.mode == &"grab" or m.mode == &"drag"):
		_drag_step(s, m, t, dt, events)
	elif s.tuned and s.calm and _stalk_step(s, m, input_of, dt):
		pass
	else:
		_wander_step(s, m, dt)
	m.speed = M.hypot2(m.body.x - before.x, m.body.z - before.z) / maxf(dt, EPS)
	m.moving = m.speed > 1e-9
	if phase != &"hide":
		m.anim_time += dt
	# T15m: outside a count it grabs anyone who comes within GRAB_RANGE.
	if s.tuned and phase == &"none" and not fl.riding:
		_tuned_grab(s, m, input_of, t, events)

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
	if s.hunt:
		_hunt_health(s, input_of, moved_of, seeking, fl, dt, t, events)
		return res
	var health_on := s.ended >= 1 and not s.counting and not fl.riding
	if health_on:
		for p in s.players:
			var inp: SeekInput = input_of.get(p.id, null)
			if inp == null or not inp.active or p.status != &"ok":
				continue
			var rate := Settings.f(tuning, &"health.rest", REST_GAIN)
			if p.phase == &"out" and moved_of.get(p.id, false):
				if inp.gait == &"sprint":
					rate = -Settings.f(tuning, &"health.sprint", SPRINT_DRAIN)
				elif inp.gait == &"walk":
					rate = -Settings.f(tuning, &"health.walk", WALK_DRAIN)
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
		noisy[id] = [] as Array[StringName]
	(noisy[id] as Array[StringName]).append(why)

static func _may_provoke(s: SeekState, t: float, fl: FloorInput) -> bool:
	return not s.counting and not s.called and not s.done and not fl.riding and not fl.boarding \
		and (s.ended == 0 or t >= s.calm_until - EPS)

static func _start_count(s: SeekState, t: float, by: String, why: StringName, last: bool, events: Array[Dictionary]) -> void:
	s.counts += 1
	s.counting = true
	s.t0 = t
	s.len = LAST_LENGTH if last else COUNT_LENGTHS[mini(s.counts - 1, COUNT_LENGTHS.size() - 1)]
	if s.tuned:
		_tuned_count(s, t, last, events)
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
	var ev := {"type": "count", "t": t, "n": s.counts, "t0": t, "len": s.len, "last": last, "by": by, "why": String(why)}
	if s.tuned:
		ev["hide"] = s.hide_len
	events.append(ev)

static func _end_count(s: SeekState, t: float, events: Array[Dictionary]) -> void:
	# Anyone found before the count ends is taken, caught or not.
	for p in s.players:
		if p.status == &"found":
			_take(s, p, t, events)
	s.counting = false
	s.ended += 1
	s.calm_until = t + CALM_TIME
	if s.calm and s.tuned:
		# MA1: the one place the bar comes down: a hunt over, it resets (to empty by default; see calm_after_hunt).
		s.anger = calm_after_hunt(_live, s.ended)
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
	var r := _walk(plan, m, Settings.f(_live, &"minder.stroll", WANDER_SPEED), dt, false)
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

# ---------------------------------------------------------------------------------------------
# T15m: the Playroom tuned from the owner's first play (see the header). Everything below is read only
# for a state made with tune(); a state without it is stepped exactly as every stored result has it.
# Owner, 17 Nov: "You need more time to hide ... 30-45 seconds"; "a bar that fills up to show how angry
# the monster is"; "Minder kinda just wanders, unless you get too close, within a meter, where it grabs
# and drags you to the party table. Once it's aggro'd, that's when it hunts actively for players."

## Seconds to hide, by the count's number on the floor (45 after that), and for the last count; then the
## search, the same for every count.
const TUNED_HIDE_LENGTHS: Array[float] = [30.0, 35.0, 40.0, 45.0]
const TUNED_LAST_HIDE := 30.0
const TUNED_SEARCH := 30.0
## Anger, 0 to 1. A provocation that lasts adds its rate a second for as long as it lasts (two seconds of
## sprinting fill an empty bar; a walk across a squeaky tile, about a third); one that happens once adds
## its lump (three of them fill it). Nobody provoking, it cools by ANGER_COOL a second (full to empty in
## 50 s). The bar is full through a count and drains to empty over the CALM_TIME after it.
const ANGER_RATES := {&"sprint": 0.5, &"squeaker": 0.5, &"bump": 1.0, &"light": 0.5, &"voice": 0.5}
const ANGER_LUMPS := {&"ballpit": 0.34, &"flap": 0.34, &"tape": 0.34, &"emote": 0.34, &"toy": 0.34}
const ANGER_COOL := 0.02
## Outside a count: within this of it (out of a hide, same level) it grabs you; holds you this long
## (its mask in your face), then drags you to the party table at DRAG_SPEED, DRAG_BEHIND behind it. A drag
## that has not got there after DRAG_MAX seconds seats them anyway.
const GRAB_RANGE := 1.0
const GRAB_TIME := 1.0
const DRAG_SPEED := 2.0
const DRAG_BEHIND := 0.6
const DRAG_MAX := 60.0
const DRAG_RADIUS := 0.3

## The state with T15m on (a copy).
static func tune(s0: SeekState) -> SeekState:
	var s := s0.copy()
	s.tuned = true
	return s

## Live settings (sim/settings.gd): the tuning of the step in progress (step_seek sets it first; null: none). Only
## the T15m numbers below and the stroll read it, each with today's constant when the host has not set it.
static var _live: Settings.Values = null

## What a provocation adds to the anger this tick. `tuning`: the host's minder.anger_sprint (seconds of sprinting
## to a full bar) and minder.anger_noise (a lump, in 100).
## `hunt` (PT1): the fallbacks are HUNT_ANGER_SPRINT and HUNT_ANGER_NOISE instead of today's rates.
static func anger_gain(why: StringName, dt: float, tuning: Settings.Values = null, hunt: bool = false) -> float:
	if why == WHY_FETCH:
		return fetch_anger(tuning)
	if hunt and why == &"sprint":
		return dt / Settings.f(tuning, &"minder.anger_sprint", HUNT_ANGER_SPRINT)
	if hunt and ANGER_LUMPS.has(why):
		return Settings.f(tuning, &"minder.anger_noise", HUNT_ANGER_NOISE) / 100.0
	if why == &"sprint" and tuning != null and tuning.has(&"minder.anger_sprint"):
		return dt / Settings.f(tuning, &"minder.anger_sprint", 2.0)
	if ANGER_RATES.has(why):
		return float(ANGER_RATES[why]) * dt
	if ANGER_LUMPS.has(why) and tuning != null and tuning.has(&"minder.anger_noise"):
		return Settings.f(tuning, &"minder.anger_noise", 34.0) / 100.0
	return float(ANGER_LUMPS.get(why, 0.0))

## How much the anger cools a second (ANGER_COOL, or one over the host's minder.anger_cool seconds).
static func anger_cool(tuning: Settings.Values = null) -> float:
	if tuning != null and tuning.has(&"minder.anger_cool"):
		return 1.0 / Settings.f(tuning, &"minder.anger_cool", 50.0)
	return ANGER_COOL

## A tuned count's seconds to hide: TUNED_HIDE_LENGTHS by the count's number (TUNED_LAST_HIDE for the last), or
## the host's minder.hide_time plus minder.hide_more a count after the first (to the fourth), minder.last_hide.
static func tuned_hide(tuning: Settings.Values, counts: int, last: bool) -> float:
	if last:
		return Settings.f(tuning, &"minder.last_hide", TUNED_LAST_HIDE)
	var k := mini(counts - 1, TUNED_HIDE_LENGTHS.size() - 1)
	if tuning == null or not (tuning.has(&"minder.hide_time") or tuning.has(&"minder.hide_more")):
		return TUNED_HIDE_LENGTHS[k]
	return Settings.f(tuning, &"minder.hide_time", TUNED_HIDE_LENGTHS[0]) + Settings.f(tuning, &"minder.hide_more", TUNED_HIDE_LENGTHS[1] - TUNED_HIDE_LENGTHS[0]) * k

## Step 4 with T15m on: the hint events, then the anger, and a count when it is full.
static func _tuned_provoke(s: SeekState, t: float, dt: float, noisy: Dictionary, moved_of: Dictionary, input_of: Dictionary,
		fl: FloorInput, events: Array[Dictionary], calm_gain: Dictionary = {}) -> void:
	if not s.arrived and not fl.riding:
		s.arrived = true
		events.append({"type": "playroomArrived", "t": t, "depth": s.floor.plan.depth})
	var now_sprinting := {}
	if phase_of(s) == &"seek":
		for p in s.players:
			var inp: SeekInput = input_of.get(p.id, null)
			if inp == null or not inp.active or p.status != &"ok" or p.phase != &"out":
				continue
			if inp.gait == &"sprint" and moved_of.get(p.id, false):
				now_sprinting[p.id] = true
				if not s.sprinting.has(p.id):
					events.append({"type": "sprintDuringHunt", "t": t, "playerId": p.id, "n": s.counts})
	s.sprinting = now_sprinting
	if s.counting:
		s.anger = 1.0
		return
	if s.ended >= 1 and t < s.calm_until - EPS:
		if s.calm:
			# MA1: the bar holds where the hunt's end left it (calm_after_hunt); it never drains.
			return
		# The party table: the bar never cools by itself afterwards, so the calm's drain reaches empty on its own
		# last tick (one tick sooner) rather than leaving the last tick's crumb.
		var left := s.calm_until - t - (dt if s.party else 0.0)
		s.anger = clampf(left / CALM_TIME, 0.0, 1.0)
		return
	if not _may_provoke(s, t, fl):
		s.anger = _cooled(s, s.anger, dt)
		return
	var level := s.anger
	var gained := false
	for p in s.players:
		# MA1: getting into a hide or opening something, before the noises.
		if calm_gain.has(p.id):
			var cg: Array = calm_gain[p.id]
			if float(cg[0]) > 0.0:
				gained = true
				level += float(cg[0])
				if level >= 1.0 - EPS:
					_start_count(s, t, p.id, cg[1], false, events)
					return
		if not noisy.has(p.id):
			continue
		for why: StringName in noisy[p.id]:
			var g := anger_gain(why, dt, _live, s.hunt)
			if g <= 0.0:
				continue
			gained = true
			level += g
			if level >= 1.0 - EPS:
				_start_count(s, t, p.id, why, false, events)
				return
	s.anger = level if gained else _cooled(s, level, dt)

## The anger after a quiet tick: cooled by anger_cool, or (the party table) never by itself.
static func _cooled(s: SeekState, level: float, dt: float) -> float:
	if s.party or s.calm:
		return level
	return maxf(0.0, level - anger_cool(_live) * dt)

## A count starting with T15m on: its hiding and search lengths, the bar full, and a player being dragged
## to the table seated at once.
static func _tuned_count(s: SeekState, t: float, last: bool, events: Array[Dictionary]) -> void:
	s.hide_len = tuned_hide(_live, s.counts, last)
	s.len = Settings.f(_live, &"minder.search", TUNED_SEARCH)
	s.anger = 1.0
	var m := s.minder
	if (m.mode == &"grab" or m.mode == &"drag") and m.victim != "":
		var v := player_of(s, m.victim)
		if v != null and v.status == &"found":
			_take(s, v, t, events)
	s.drag_seat = -1

## The first free party-table seat (as _take picks it), or -1.
static func _free_seat(s: SeekState) -> int:
	var used := {}
	for q in s.players:
		if q.seat >= 0:
			used[q.seat] = true
	for i in s.floor.seats.size():
		if not used.has(i):
			return i
	return -1

## Outside a count (after the Minder has moved): the first player in order within GRAB_RANGE, out of a
## hide (getting in or out is out) and on its level, is grabbed. Not while it already holds someone.
static func _tuned_grab(s: SeekState, m: MinderState, input_of: Dictionary, t: float, events: Array[Dictionary]) -> void:
	if m.mode == &"grab" or m.mode == &"drag":
		return
	for p in s.players:
		var inp: SeekInput = input_of.get(p.id, null)
		if inp == null or not inp.active or p.status != &"ok" or p.body == null or p.phase == &"inside":
			continue
		if not _touching(m.body, p.body, GRAB_RANGE):
			continue
		_found(s, p, &"grab", t, events)
		if p.phase == &"leaving" and p.hide >= 0:
			p.body = hide_front_body(s.floor.plan, s.floor.hide_by_id[p.hide])
		p.phase = &"out"
		p.hide = -1
		p.phase_left = 0.0
		m.mode = &"grab"
		m.anim = &"catch"
		m.anim_time = 0.0
		m.timer = GRAB_TIME
		m.victim = p.id
		m.yaw = yaw_toward(p.body.x - m.body.x, p.body.z - m.body.z)
		m.path = []
		m.goal_kind = &""
		m.goal_cell = null
		m.stuck = 0.0
		s.drag_seat = _free_seat(s)
		s.drag_t0 = t
		return

## Holding a grabbed player, then dragging them to the party table.
static func _drag_step(s: SeekState, m: MinderState, t: float, dt: float, events: Array[Dictionary]) -> void:
	var plan := s.floor.plan
	var v := player_of(s, m.victim)
	if v == null or v.status != &"found":
		_drag_end(s, m)
		return
	if m.mode == &"grab":
		m.anim = &"catch"
		m.timer -= dt
		if m.timer > EPS:
			return
		m.timer = 0.0
		m.mode = &"drag"
		m.anim_time = 0.0
	m.anim = &"walk"
	if s.drag_seat < 0 or s.drag_seat >= s.floor.seats.size():
		_take(s, v, t, events)
		_drag_end(s, m)
		return
	var st := s.floor.seats[s.drag_seat]
	_goal_body(plan, m, &"drag", s.drag_seat, point_body(plan, st.at, st.level))
	var r := _walk(plan, m, DRAG_SPEED, dt, false)
	# The player comes along behind it.
	v.body = Move.move_with_collision(plan, m.body, M.sin_js(m.yaw) * DRAG_BEHIND, M.cos_js(m.yaw) * DRAG_BEHIND, DRAG_RADIUS)
	if r != 0 or t - s.drag_t0 >= DRAG_MAX - EPS:
		_take(s, v, t, events)
		_drag_end(s, m)

# ---------------------------------------------------------------------------------------------
# PT1: the owner's playtest of 19 Nov (see the header). Everything below is read only for a state made with
# with_hunt(); a state without it is stepped exactly as every stored result has it.
# Owner: "Making it so that it can hear the clicker going off when hunting means it is really difficult to get
# readings. It takes too long to anger it. And the running being painful should only happen when it is aggrod,
# not when it's not searching/hunting."

## With the hunt rules on: seconds of sprinting that fill an empty anger bar, and one noise's lump in 100.
const HUNT_ANGER_SPRINT := 1.0
## 55, not 50: two noises a few seconds apart still fill it after the cooling between them.
const HUNT_ANGER_NOISE := 55.0

## The state with PT1 on (a copy).
static func with_hunt(s0: SeekState) -> SeekState:
	var s := s0.copy()
	s.hunt = true
	return s

## Step 7 with PT1 on: walking or sprinting out of a hide drains only while it searches; standing, creeping or
## being in a hide gives back at any time on the floor; nothing in a ride. 0 is down.
static func _hunt_health(s: SeekState, input_of: Dictionary, moved_of: Dictionary, seeking: bool, fl: FloorInput, dt: float,
		t: float, events: Array[Dictionary]) -> void:
	if fl.riding:
		return
	for p in s.players:
		var inp: SeekInput = input_of.get(p.id, null)
		if inp == null or not inp.active or p.status != &"ok":
			continue
		var rate := Settings.f(_live, &"health.rest", REST_GAIN)
		if p.phase == &"out" and moved_of.get(p.id, false) and inp.gait != &"creep":
			rate = 0.0
			if seeking:
				rate = -Settings.f(_live, &"health.sprint", SPRINT_DRAIN) if inp.gait == &"sprint" else -Settings.f(_live, &"health.walk", WALK_DRAIN)
		p.health = clampf(p.health + rate * dt, 0.0, HEALTH_MAX)
		if p.health <= 0.0:
			p.health = 0.0
			p.status = &"down"
			p.phase = &"out"
			p.hide = -1
			p.peeking = false
			events.append({"type": "down", "t": t, "playerId": p.id})

static func _drag_end(s: SeekState, m: MinderState) -> void:
	m.mode = &"wander"
	m.anim = &"stand"
	m.victim = ""
	m.goal_kind = &""
	m.goal_cell = null
	m.path = []
	m.timer = 0.0
	m.stuck = 0.0
	s.drag_seat = -1

# ---------------------------------------------------------------------------------------------
# The party table (T15h; see the header). Everything below is read only for a state made with with_party(); a
# state without it is stepped exactly as every stored result has it.
# Owner, 19 Nov: "make it a requirement that the players find their teammate. If the elevator leaves with them
# still at the table, they are effectively dead ... I love the f at the table for 3s to free everyone seated with
# 50 health, but freeing the table should trigger half the aggro bar. And the aggro bar should not go down on its
# own."

## Seconds of F held at the table that free everyone seated; how near a seat (feet to the seat's spot, same
## level) the holder must stand; what freeing it adds to the anger (half the bar); the health the freed get back
## when the host has not set heal.health (sim/run.gd HEAL_HEALTH, the same 50).
const FETCH_TIME := 3.0
const FETCH_REACH := 1.5
const FETCH_ANGER := 0.5
const FETCH_HEALTH := 50.0

## Live settings (sim/settings.gd; null tuning: today's constant): the hold's seconds (party.free_time), what
## freeing adds to the anger (party.free_anger, in 100) and how near a seat F works (party.reach). The client's
## table prompt reads these same three functions with its own tuning.
static func fetch_time(tuning: Settings.Values = null) -> float:
	return Settings.f(tuning, &"party.free_time", FETCH_TIME)

static func fetch_anger(tuning: Settings.Values = null) -> float:
	if tuning == null or not tuning.has(&"party.free_anger"):
		return FETCH_ANGER
	return Settings.f(tuning, &"party.free_anger", FETCH_ANGER * 100.0) / 100.0

static func fetch_reach(tuning: Settings.Values = null) -> float:
	return Settings.f(tuning, &"party.reach", FETCH_REACH)

## The state with the party table on (a copy).
static func with_party(s0: SeekState) -> SeekState:
	var s := s0.copy()
	s.party = true
	return s

## The ids of everyone seated at the party table, in player order.
static func seated_ids(s: SeekState) -> Array[String]:
	var out: Array[String] = []
	for p in s.players:
		if p.status == &"taken" and p.seat >= 0:
			out.append(p.id)
	return out

## Whether a body stands at the party table: within FETCH_REACH (the host's party.reach) of a seat's spot, on its
## level.
static func at_table(s: SeekState, b: Move.Body, tuning: Settings.Values = null) -> bool:
	if b == null:
		return false
	var reach := fetch_reach(tuning)
	for st in s.floor.seats:
		if st.level == b.level and M.hypot2(st.at.x / 100.0 - b.x, st.at.y / 100.0 - b.z) <= reach:
			return true
	return false

## Whether this player can fetch this tick: on their feet out of a hide, F held, at the table.
static func _can_fetch(s: SeekState, p: SeekPlayer, inp: SeekInput) -> bool:
	return inp != null and inp.active and inp.hold and p.status == &"ok" and p.phase == &"out" and at_table(s, p.body, _live)

## Step 3's end with the party table on: the hold, and freeing everyone seated once it is held FETCH_TIME. The
## hold counts from the start of the tick it began, as a heal's does (sim/run.gd). One holder at a time: the one
## already holding, else the first in player order. Freeing is the fetcher's provocation (WHY_FETCH).
static func _fetch_step(s: SeekState, input_of: Dictionary, t: float, dt: float, noisy: Dictionary, events: Array[Dictionary]) -> void:
	var seated := seated_ids(s)
	var by := ""
	if not seated.is_empty():
		var cur := player_of(s, s.fetch_by) if s.fetch_by != "" else null
		if cur != null and _can_fetch(s, cur, input_of.get(cur.id, null)):
			by = cur.id
		else:
			for p in s.players:
				if _can_fetch(s, p, input_of.get(p.id, null)):
					by = p.id
					break
	if by != s.fetch_by:
		if s.fetch_by != "":
			events.append({"type": "fetchStop", "t": t, "playerId": s.fetch_by})
		s.fetch_by = by
		s.fetch_from = t - dt if by != "" else -1.0
		if by != "":
			s.fetch_len = fetch_time(_live)
			events.append({"type": "fetchStart", "t": t, "playerId": by, "from": s.fetch_from, "done": s.fetch_from + s.fetch_len, "seated": seated.duplicate()})
	if by == "" or t - s.fetch_from < s.fetch_len - EPS:
		return
	var health := clampf(Settings.f(_live, &"heal.health", FETCH_HEALTH), 0.0, HEALTH_MAX)
	for p in s.players:
		if not seated.has(p.id):
			continue
		var st := s.floor.seats[p.seat]
		p.status = &"ok"
		p.seat = -1
		p.phase = &"out"
		p.hide = -1
		p.phase_left = 0.0
		p.peeking = false
		p.sight = 0.0
		p.gap = 0.0
		p.seen_entering = false
		p.health = health
		p.body = point_body(s.floor.plan, st.at, st.level)
		p.last = p.body
	events.append({"type": "tableFreed", "t": t, "playerId": by, "freed": seated.duplicate(), "health": health})
	s.fetch_by = ""
	s.fetch_from = -1.0
	_note(noisy, by, WHY_FETCH)

# ---------------------------------------------------------------------------------------------
# MA1, the owner's playtest of 20 Nov (on only for a state made with with_calm(): sim/run.gd minder_calm, which the
# game's rooms turn on with the tuned Playroom; off, nothing of this happens). "I don't want the cool down mechanism
# at all. It should only ever go up or stay the same. Any time hiding takes place, a drawer is opened, etc it should
# aggro a bit. If it sees a user it should start walking towards them, and if close enough should take them down
# when not aggrod. It shouldn't be fast, and if it loses eyesight of a player, it should go back to wandering."
#   - the anger bar never cools and never drains over the calm after a count. The one time it comes down is the
#     tick a count ends: it restarts from calm_after_hunt (CALM_AFTER_HUNT in 100 for each count ended so far, at
#     most CALM_AFTER_MAX). The owner, 20 Nov: "Minder's bar resets after a count. But it can only ever creep up
#     until the next hunt is over, when it resets again and the cycle starts over." So CALM_AFTER_HUNT is 0: empty
#     after every hunt (the live setting minder.after_hunt can still raise it);
#   - getting into a hide adds CALM_HIDE_ANGER, and opening something (the run's "searchStart") CALM_OPEN_ANGER;
#     either can start a count, as a noise can ("why" "hide" or "open");
#   - between counts, a player out of a hide and in its view (in_view: SIGHT_RANGE, the cone, a clear line) is walked
#     to at CALM_STALK_SPEED, slower than a walking player, its face on them (the goal "stalk"; its mode stays
#     "wander"). Within GRAB_RANGE the T15m grab takes them. Out of its view, it goes back to its round.

## Each count ended leaves the bar at this much more (0 to 1), up to CALM_AFTER_MAX (never full). 0: empty every time.
const CALM_AFTER_HUNT := 0.0
const CALM_AFTER_MAX := 0.6
## Getting into a hide, and opening something: what each adds to the bar (0 to 1).
const CALM_HIDE_ANGER := 0.1
const CALM_OPEN_ANGER := 0.1
## Walking to a player it sees between counts (m/s): under a walk (sim/stamina.gd WALK_SPEED 3), over a creep (1.2).
const CALM_STALK_SPEED := 1.5

## The state with MA1 on (a copy).
static func with_calm(s0: SeekState) -> SeekState:
	var s := s0.copy()
	s.calm = true
	return s

## Live settings: minder.after_hunt (in 100 a count ended), minder.anger_hide and minder.anger_open (in 100), and
## minder.stalk (m/s); today's constants when the host has not set them.
static func calm_after_hunt(tuning: Settings.Values, ended: int) -> float:
	var step := Settings.f(tuning, &"minder.after_hunt", CALM_AFTER_HUNT * 100.0) / 100.0
	return clampf(step * float(ended), 0.0, CALM_AFTER_MAX)

static func calm_hide_anger(tuning: Settings.Values = null) -> float:
	return Settings.f(tuning, &"minder.anger_hide", CALM_HIDE_ANGER * 100.0) / 100.0

static func calm_open_anger(tuning: Settings.Values = null) -> float:
	return Settings.f(tuning, &"minder.anger_open", CALM_OPEN_ANGER * 100.0) / 100.0

static func calm_stalk_speed(tuning: Settings.Values = null) -> float:
	return Settings.f(tuning, &"minder.stalk", CALM_STALK_SPEED)

static func _calm_note(gain: Dictionary, id: String, amount: float, why: StringName) -> void:
	if gain.has(id):
		var g: Array = gain[id]
		gain[id] = [float(g[0]) + amount, g[1]]
	else:
		gain[id] = [amount, why]

## Step 5 between counts with MA1 on: the nearest player out of a hide in its view, walked to with its face on them.
## Returns false (and lets go of a stalk) when nobody is in its view: the wander goes on.
static func _stalk_step(s: SeekState, m: MinderState, input_of: Dictionary, dt: float) -> bool:
	var plan := s.floor.plan
	var best := -1
	var best_d := INF
	for i in s.players.size():
		var p := s.players[i]
		if not _hunted(p, input_of) or p.phase == &"inside":
			continue
		if not in_view(plan, m.body, m.yaw, p.body):
			continue
		var d := M.hypot2(p.body.x - m.body.x, p.body.z - m.body.z)
		if d < best_d:
			best = i
			best_d = d
	if best < 0:
		if m.goal_kind == &"stalk":
			m.goal_kind = &""
			m.goal_cell = null
			m.path = []
		return false
	m.mode = &"wander"
	m.anim = &"walk"
	m.timer = 0.0
	_goal_body(plan, m, &"stalk", best, s.players[best].body)
	var from := m.body
	var speed := calm_stalk_speed(_live)
	_walk(plan, m, speed, dt, true)
	# "It shouldn't be fast": never more than its speed in a tick. Move.move_with_collision pushes a step that grazes a
	# wall back out sideways (_push_out), so a tick along a wall can land a hair past the budget (seen on prop_seek's
	# floor 9: 1.5026 m/s for one tick). Then the same net move is shrunk until it fits, or it stands this tick.
	var most := speed * dt
	var dx := m.body.x - from.x
	var dz := m.body.z - from.z
	var d := M.hypot2(dx, dz)
	if d > most + 1e-12:
		var f := most / d
		var fitted := from
		for _k in 8:
			var back := Move.move_with_collision(plan, from, dx * f, dz * f, MINDER_RADIUS)
			var got := M.hypot2(back.x - from.x, back.z - from.z)
			if got <= most + 1e-12:
				fitted = back
				break
			f *= most / got * 0.999
		m.body = fitted
	return true
