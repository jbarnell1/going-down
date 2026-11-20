# Wandering bot players: deterministic stand-ins for people, used by tests now and the game later.
# Port of src/sim/bot.ts.
#
# Each picks a reachable cell, walks there with the real collision code (sometimes creeping,
# sometimes stopping), and turns its head with a mix of looking where it goes, glancing behind and
# looking around. `watchfulness` (0..1) sets how often it looks anywhere but ahead; an `oblivious`
# bot never looks behind and only looks a little to the sides.
#
# Bots have the players' tank (stamina.gd) and, given where the Orderly is, use it as a person
# would: a bot that glances behind and sees it within BOT_FLEE_RANGE is alarmed for BOT_ALARM_TIME
# seconds, and while alarmed it sprints whenever the Orderly is close behind it (same level, in
# range, behind its direction of travel) and the tank allows; otherwise it walks, creeps or stops as
# before. So a watchful bot runs for it and an oblivious one (it never looks behind) never knows.
# Deterministic: no extra random draws.
extends RefCounted

const Floor = preload("res://sim/floor.gd")
const Follow = preload("res://sim/follow.gd")
const Move = preload("res://sim/move.gd")
const Rng = preload("res://sim/rng.gd")
const Entity = preload("res://sim/entity.gd")
const Run = preload("res://sim/run.gd")
const Stamina = preload("res://sim/stamina.gd")
const M = preload("res://sim/jsmath.gd")

const BOT_WALK_SPEED := Stamina.WALK_SPEED
const BOT_CREEP_SPEED := Stamina.CREEP_SPEED
## A bot flees (sprints) from an Orderly within this many metres behind it...
const BOT_FLEE_RANGE := 10.0
## ...for this many seconds after it last glanced back and saw it there.
const BOT_ALARM_TIME := 5.0
const BOT_RADIUS := 0.3
const BOT_EYE := 1.65
## The game camera: 70 degrees vertical at 16:9.
const BOT_VFOV_DEG := 70.0
## (2 * atan(tan(35 deg) * 16/9) * 180) / pi, computed with JavaScript's atan and tan (see _static_init).
static var BOT_HFOV_DEG := 0.0
## Head turn rate, radians per second.
const BOT_TURN_RATE := 6.0

static func _static_init() -> void:
	BOT_HFOV_DEG = (2.0 * M.atan_js(M.tan_js((35.0 * PI) / 180.0) * (16.0 / 9.0)) * 180.0) / PI

# BotGait: 'walk' | 'creep' | 'stop'. BotLook: 'ahead' | 'behind' | 'around'.

class Bot:
	var id: String
	var body: Move.Body
	## Where the head points (yaw, pitch), three.js style.
	var yaw: float
	var pitch: float = 0.0
	## Direction of travel.
	var heading: float
	var gait: StringName = &"walk"
	var gait_left: float  # TypeScript: gaitLeft
	var look: StringName = &"ahead"
	var look_left: float  # TypeScript: lookLeft
	var look_offset: float = 0.0  # TypeScript: lookOffset
	var pitch_want: float = 0.0  # TypeScript: pitchWant
	var walk: Follow.PathWalk = null
	var stuck: float = 0.0
	var watchfulness: float
	var oblivious: bool
	var rng: Rng
	var stamina: Stamina.Stamina
	## The gait it actually moved with on the last step (what a player's input would say). (TypeScript: moveGait)
	var move_gait: StringName = &"walk"
	## Seconds of alarm left: it glanced back and saw the Orderly close.
	var alarm: float = 0.0

## Every position reachable from the landing, ascending pos_index (cached on the plan).
static func _reachable_cells(plan: Floor.FloorPlan) -> PackedInt32Array:
	if plan._has_reachable:
		return plan._reachable
	plan._reachable = Floor.reachable_from(plan, plan.landing)
	plan._has_reachable = true
	return plan._reachable

static func _wrap(a: float) -> float:
	var r := fmod(a, 2.0 * PI)
	if r > PI:
		r -= 2.0 * PI
	if r < -PI:
		r += 2.0 * PI
	return r

## createBot(plan, id, seed, { watchfulness, oblivious, start }); `start` null means a random
## reachable cell, `watchfulness` < 0 means the default 0.5.
static func create_bot(plan: Floor.FloorPlan, id: String, seed: Variant, watchfulness: float = -1.0, oblivious: bool = false, start: Floor.Pos = null) -> Bot:
	var rng := Rng.make_rng(seed).fork("bot:%s" % id)
	var cells := _reachable_cells(plan)
	var at := start if start != null else Floor.pos_from_index(plan, rng.pick_int(cells))
	var heading := (rng.next() * 2.0 - 1.0) * PI
	var b := Bot.new()
	b.id = id
	b.body = Move.body_at_cell(plan, at)
	b.yaw = heading
	b.pitch = 0.0
	b.heading = heading
	b.gait = &"walk"
	b.gait_left = 2.0 + rng.next() * 6.0
	b.look = &"ahead"
	b.look_left = rng.next() * 2.0
	b.look_offset = 0.0
	b.pitch_want = 0.0
	b.walk = null
	b.stuck = 0.0
	b.watchfulness = maxf(0.0, minf(1.0, watchfulness if watchfulness >= 0.0 else 0.5))
	b.oblivious = oblivious
	b.rng = rng
	b.stamina = Stamina.fresh_stamina()
	b.move_gait = &"walk"
	b.alarm = 0.0
	return b

static func _new_goal(plan: Floor.FloorPlan, bot: Bot) -> void:
	var cells := _reachable_cells(plan)
	var from := Move.cell_of(plan, bot.body)
	for _tries in 8:
		var goal := Floor.pos_from_index(plan, bot.rng.pick_int(cells))
		if not Floor.is_walkable(plan, goal.level, goal.x, goal.y):
			continue
		var path := Floor.find_path(plan, from, goal)
		if path.size() > 1:
			bot.walk = Follow.PathWalk.make(path, 1)
			return
	bot.walk = null

static func _new_gait(bot: Bot) -> void:
	var r := bot.rng.next()
	if r < 0.72:
		bot.gait = &"walk"
		bot.gait_left = 3.0 + bot.rng.next() * 8.0
	elif r < 0.88:
		bot.gait = &"creep"
		bot.gait_left = 2.0 + bot.rng.next() * 4.0
	else:
		bot.gait = &"stop"
		bot.gait_left = 0.8 + bot.rng.next() * 3.0

static func _new_look(bot: Bot) -> void:
	var w := bot.watchfulness
	var stopped := bot.gait == &"stop"
	var p_behind := 0.0 if bot.oblivious else 0.04 + 0.3 * w
	var p_around := (0.1 if bot.oblivious else 0.12 + 0.35 * w) + (0.3 if stopped else 0.0)
	var r := bot.rng.next()
	if r < p_behind:
		bot.look = &"behind"
		bot.look_left = 0.4 + bot.rng.next() * 0.9
		bot.look_offset = PI + (bot.rng.next() - 0.5) * 0.8
	elif r < p_behind + p_around:
		bot.look = &"around"
		bot.look_left = 0.8 + bot.rng.next() * 1.8
		var span := PI / 3.0 if bot.oblivious else (PI * 5.0) / 6.0
		bot.look_offset = (bot.rng.next() * 2.0 - 1.0) * span
	else:
		bot.look = &"ahead"
		bot.look_left = (1.5 + bot.rng.next() * 4.0) * (1.0 - 0.6 * w)
		bot.look_offset = (bot.rng.next() - 0.5) * 0.4
	bot.pitch_want = ((bot.rng.next() - 0.6) * 20.0 * PI) / 180.0

## Whether a threat is close behind a bot: same level, in range, behind its direction of travel.
static func threat_behind(bot: Bot, threat: Move.Body) -> bool:
	if threat == null or threat.level != bot.body.level:
		return false
	var dx := threat.x - bot.body.x
	var dz := threat.z - bot.body.z
	var d := M.hypot2(dx, dz)
	if d > BOT_FLEE_RANGE or d < 1e-6:
		return false
	# Forward is (-sin h, -cos h), three.js style.
	return -M.sin_js(bot.heading) * dx - M.cos_js(bot.heading) * dz < 0.0

## A bot looking back over its shoulder at a threat close behind it notices it.
static func _notices_behind(bot: Bot, threat: Move.Body) -> bool:
	return bot.look == &"behind" and threat_behind(bot, threat)

## Advances a bot by dt seconds (mutates it). `threat` is where the Orderly is, if the bot knows: it
## sprints away while that is close behind and its tank allows. `cap` limits its pace (a raised
## instrument); a capped bot cannot sprint, like a player. `solids`: the run's solid furniture (Run.solids_in),
## which the bot walks round like a player; null (every stored run) for none.
static func step_bot(plan: Floor.FloorPlan, bot: Bot, dt: float, threat: Move.Body = null, cap: float = INF, solids: Move.Solids = null) -> void:
	bot.gait_left -= dt
	if bot.gait_left <= 0.0:
		_new_gait(bot)
	var before0 := bot.body
	bot.alarm = BOT_ALARM_TIME if _notices_behind(bot, threat) else maxf(0.0, bot.alarm - dt)
	var flee := bot.gait != &"stop" and bot.alarm > 0.0 and threat_behind(bot, threat)
	bot.move_gait = &"walk" if bot.gait == &"stop" else Stamina.gait_for(bot.stamina, flee, bot.gait == &"creep" and not flee, true, cap)

	if bot.gait != &"stop":
		if bot.walk == null or Follow.path_done(plan, bot.walk, bot.body) or bot.stuck > 1.0:
			bot.stuck = 0.0
			_new_goal(plan, bot)
			if bot.walk != null and bot.rng.chance(0.2):
				bot.gait = &"stop"
				bot.gait_left = 0.5 + bot.rng.next() * 2.5
		if bot.walk != null and bot.gait != &"stop":
			var speed := Stamina.speed_for(bot.move_gait, cap)
			var before := bot.body
			bot.body = Follow.step_path_walk(plan, bot.walk, before, speed * dt, BOT_RADIUS, solids)
			var mx := bot.body.x - before.x
			var mz := bot.body.z - before.z
			var moved := M.hypot2(mx, mz)
			if moved > 1e-4:
				bot.heading = M.atan2_js(-mx, -mz)
				bot.stuck = 0.0
			else:
				bot.stuck += dt

	var moved0 := M.hypot2(bot.body.x - before0.x, bot.body.z - before0.z)
	bot.stamina = Stamina.step_stamina(bot.stamina, bot.move_gait, moved0 / dt if dt > 0.0 else 0.0, dt)

	bot.look_left -= dt
	if bot.look_left <= 0.0:
		_new_look(bot)
	var want := _wrap(bot.heading + bot.look_offset)
	var d := _wrap(want - bot.yaw)
	var mx2 := BOT_TURN_RATE * dt
	bot.yaw = _wrap(bot.yaw + maxf(-mx2, minf(mx2, d)))
	bot.pitch += maxf(-mx2, minf(mx2, bot.pitch_want - bot.pitch))

## The bot as a player the Orderly can look for.
static func bot_view(bot: Bot) -> Entity.PlayerView:
	return Entity.PlayerView.make(bot.id, bot.body, BOT_EYE, bot.yaw, bot.pitch, BOT_HFOV_DEG, BOT_VFOV_DEG, true)

# ---------------------------------------------------------------------------------------------
# Waiting for the car: two ways a crew can live through the wait, for the blackout's tuning tests.
#
#   'stay'  stands on the landing the whole wait, watching the Orderly whenever the lights are on,
#           and boards when the doors open. In the dark it can do nothing.
#   'flee'  watches it while the lights are on and keeps a few metres from it. When a dark stretch
#           is announced that would let it reach them, and always for the blackout, it gets moving
#           during the warning (walking, still watching it), then runs in the dark: away from where it
#           is heard, to places it can reach first, never into a room (rooms are dead ends), choosing
#           again whenever it gets there, sprinting while it is heard close. When the lights come
#           back it heads for the landing, watching it whenever it can, and boards; whoever is aboard
#           holds the doors while someone is still coming.
# Deterministic: no random draws at all; ties go to the lower cell index.

## Within this straight-line distance (m) a waiting bot hears the Orderly in the dark.
const WAIT_HEAR_RANGE := Entity.HEAR_RANGE
## A 'flee' bot backs off when the lit Orderly is closer than this (m)...
const WAIT_KEEP_AWAY := 4.5
## ...runs from a short blink if the Orderly could cover the distance in it plus this margin (m)...
const WAIT_BLINK_MARGIN := 6.0
## ...and sprints in the dark while it is heard within this distance (m).
const WAIT_SPRINT_RANGE := 14.0

# WaitStyle: 'stay' | 'flee'. WaitMode: 'hold' | 'flee' | 'return' | 'board' | 'aboard'.

class WaitBot:
	var id: String
	var style: StringName
	var body: Move.Body
	var yaw: float = 0.0
	var pitch: float = 0.0
	var stamina: Stamina.Stamina
	var gait: StringName = &"walk"
	var mode: StringName = &"hold"
	## Where it stands on the landing, car-local (u, v).
	var spot_u: float
	var spot_v: float
	## Where it boards, car-local.
	var seat_u: float
	var seat_v: float
	var walk: Follow.PathWalk = null
	var route: Array[Move.Body] = []
	## Last place the Orderly was seen or heard.
	var heard: Move.Body = null
	## Seconds until the flee goal is chosen again.
	var rethink: float = 0.0

## A waiting bot standing at landing spot `k` of the car.
static func create_wait_bot(st: Run.RunState, id: String, k: int, style: StringName) -> WaitBot:
	var b := WaitBot.new()
	b.id = id
	b.style = style
	b.spot_u = -0.8 - 0.4 * floorf(k / 2.0)
	b.spot_v = 0.45 if k % 2 != 0 else -0.45
	b.body = Run.car_body(st.car, b.spot_u, b.spot_v)
	b.yaw = 0.0
	b.pitch = 0.0
	b.stamina = Stamina.fresh_stamina()
	b.gait = &"walk"
	b.mode = &"hold"
	b.seat_u = 1.0 + 0.8 * floorf(k / 2.0)
	b.seat_v = 1.0 if k % 2 != 0 else -1.0
	b.walk = null
	b.route = []
	b.heard = null
	b.rethink = 0.0
	return b

## The input a waiting bot gives the run this tick.
static func wait_bot_input(bot: WaitBot, hold_doors: bool = false, call: bool = false) -> Run.PlayerInput:
	var p := Run.PlayerInput.make(bot.id, bot.body, BOT_EYE, bot.yaw, bot.pitch, BOT_HFOV_DEG, BOT_VFOV_DEG)
	p.hold_doors = hold_doors
	p.call = call
	return p

## Straight-line distance on the same level, else INF.
static func _flat_gap(a: Move.Body, b: Move.Body) -> float:
	return M.hypot2(a.x - b.x, a.z - b.z) if a.level == b.level else INF

## Where to run to: a corridor, stair or atrium cell as far from the Orderly as possible, never a
## room; in the dark, only one the bot reaches well before the Orderly could. Null if there is none.
static func flee_goal(plan: Floor.FloorPlan, from: Move.Body, threat: Move.Body, lit: bool) -> Floor.Pos:
	var dB := Floor.distances_from(plan, Move.cell_of(plan, from))
	var has_threat := threat != null
	var dO := Floor.distances_from(plan, Move.cell_of(plan, threat)) if has_threat else PackedInt32Array()
	var best := -1
	var best_score := -INF
	for i in dB.size():
		var b := dB[i]
		if b < 3 or b > 14:
			continue
		var p := Floor.pos_from_index(plan, i)
		var kind := Floor.cell_at(plan, p.level, p.x, p.y)
		if kind == Floor.ROOM or kind == Floor.VOID:
			continue
		var o := dO[i] if has_threat else 99
		if o < 0:
			continue
		# In the dark, only places it reaches first by a clear margin. In the light it is held still by
		# being watched, so walking past it to the far side is fine.
		if not lit and o < b + 3:
			continue
		var score := o - 0.25 * b
		if score > best_score:
			best_score = score
			best = i
	return null if best < 0 else Floor.pos_from_index(plan, best)

## Aims the head at a body's chest.
static func _aim_at(bot: WaitBot, target: Move.Body) -> void:
	bot.yaw = M.atan2_js(-(target.x - bot.body.x), -(target.z - bot.body.z))
	var d := maxf(0.1, M.hypot2(target.x - bot.body.x, target.z - bot.body.z))
	bot.pitch = M.atan2_js(target.y + 1.7 - (bot.body.y + BOT_EYE), d)

## Moves along the bot's straight route, or else its path, up to `dist` metres; returns whether it moved.
static func _follow(st: Run.RunState, bot: WaitBot, dist: float) -> bool:
	var before := bot.body
	if not bot.route.is_empty():
		var budget := dist
		while budget > 1e-9 and not bot.route.is_empty():
			var w := bot.route[0]
			var d := M.hypot2(w.x - bot.body.x, w.z - bot.body.z)
			if d < 0.03:
				bot.route.pop_front()
				continue
			var step := minf(budget, d)
			var prev := bot.body
			bot.body = Run.move_in_run(st, bot.body, ((w.x - bot.body.x) / d) * step, ((w.z - bot.body.z) / d) * step, BOT_RADIUS)
			budget -= step
			if M.hypot2(bot.body.x - prev.x, bot.body.z - prev.z) < 1e-6:
				break
	elif bot.walk != null:
		bot.body = Follow.step_path_walk(st.plan, bot.walk, bot.body, dist, BOT_RADIUS, Run.solids_in(st))
	return M.hypot2(bot.body.x - before.x, bot.body.z - before.z) > 1e-6

## Whether the body stands in the landing cell.
static func _on_landing(plan: Floor.FloorPlan, body: Move.Body) -> bool:
	var c := Move.cell_of(plan, body)
	return c.level == plan.landing.level and c.x == plan.landing.x and c.y == plan.landing.y

## Advances a waiting bot by dt (mutates it). It reads the run as a person could: where the Orderly
## is while the lights are on (it watches it), where it is heard in the dark (within WAIT_HEAR_RANGE),
## the warnings, and the doors.
static func step_wait_bot(st: Run.RunState, bot: WaitBot, dt: float) -> void:
	var plan := st.plan
	# A second Orderly (T9b): the bot minds the nearer one.
	var o := Run.nearest_orderly(st, bot.body).body
	var b := st.blink
	var dark := b != null and b.ends_at != null
	var warn: Run.BlinkState = b if (b != null and b.announced and b.ends_at == null) else null
	var open := Run.doors_open(st)
	if not dark or _flat_gap(bot.body, o) <= WAIT_HEAR_RANGE:
		bot.heard = o
	var threat := bot.heard
	var near := _flat_gap(bot.body, threat) if threat != null else INF
	var sprint := false
	var moved := false

	# The doors open (and the lights are on): everyone heads for the car.
	if open and not dark and bot.mode != &"board" and bot.mode != &"aboard":
		if _on_landing(plan, bot.body):
			bot.mode = &"board"
			bot.walk = null
			bot.route = [Run.car_body(st.car, -0.6, 0.0), Run.car_body(st.car, 0.45, 0.0), Run.car_body(st.car, bot.seat_u, bot.seat_v)]
		elif bot.mode != &"return":
			bot.mode = &"return"
			bot.walk = null
			bot.route = []

	match bot.mode:
		&"hold":
			if bot.style == &"flee":
				var blink_threat := warn != null and not warn.blackout and near < Entity.HUNT_SPEED * warn.len + WAIT_BLINK_MARGIN
				if warn != null and (warn.blackout or blink_threat):
					bot.mode = &"flee"
					bot.route = []
					bot.walk = null
					bot.rethink = 0.0
				elif not dark and threat != null and near < WAIT_KEEP_AWAY and bot.route.is_empty():
					# Back off, straight away from it, still watching it.
					var d := maxf(near, 1e-6)
					var prev := bot.body
					bot.body = Run.move_in_run(st, bot.body, ((bot.body.x - threat.x) / d) * Stamina.WALK_SPEED * dt, ((bot.body.z - threat.z) / d) * Stamina.WALK_SPEED * dt, BOT_RADIUS)
					moved = M.hypot2(bot.body.x - prev.x, bot.body.z - prev.z) > 1e-6
		&"flee":
			if not dark and not (b != null and b.announced):
				# The lights are back and nothing is announced: home.
				bot.mode = &"return"
				bot.walk = null
			else:
				bot.rethink -= dt
				if bot.walk == null or Follow.path_done(plan, bot.walk, bot.body) or bot.rethink <= 0.0:
					var goal := flee_goal(plan, bot.body, threat, not dark)
					var path: Array[Floor.Pos] = []
					if goal != null:
						path = Floor.find_path(plan, Move.cell_of(plan, bot.body), goal)
					if path.size() > 1:
						bot.walk = Follow.PathWalk.make(path, 1)
					bot.rethink = 1.5
				# Lit (the warning): walk, watching it. Dark: run while it is heard close.
				sprint = dark and near < WAIT_SPRINT_RANGE
		&"return":
			if (warn != null and warn.blackout) or (dark and b.blackout):
				bot.mode = &"flee"
				bot.walk = null
				bot.rethink = 0.0
			else:
				if bot.walk == null:
					var path := Floor.find_path(plan, Move.cell_of(plan, bot.body), plan.landing)
					bot.walk = Follow.PathWalk.make(path, 1 if path.size() > 1 else 0) if not path.is_empty() else null
				if bot.walk != null and Follow.path_done(plan, bot.walk, bot.body):
					bot.walk = null
					if not open:
						bot.mode = &"hold"
						bot.route = [Run.car_body(st.car, bot.spot_u, bot.spot_v)]
				# Hurry while there is far to go (it is watched while the lights are on).
				sprint = not dark and (bot.walk.path.size() - bot.walk.next > 6 if bot.walk != null else false)

	if bot.mode == &"flee" or bot.mode == &"return" or bot.mode == &"board" or (bot.mode == &"hold" and not bot.route.is_empty()):
		bot.gait = Stamina.gait_for(bot.stamina, sprint, false, true, INF)
		moved = _follow(st, bot, Stamina.speed_for(bot.gait) * dt) or moved
		if bot.mode == &"board" and bot.route.is_empty():
			bot.mode = &"aboard"
	else:
		bot.gait = &"walk"
	bot.stamina = Stamina.step_stamina(bot.stamina, bot.gait, Stamina.speed_for(bot.gait) if moved else 0.0, dt)

	# Eyes: on the Orderly whenever the lights are on (that is what holds it still); ahead in the dark.
	if not dark and threat != null:
		_aim_at(bot, threat)
	elif bot.walk != null:
		if bot.walk.next >= 0 and bot.walk.next < bot.walk.path.size():
			var wp := bot.walk.path[bot.walk.next]
			bot.yaw = M.atan2_js(-((wp.x + 0.5) * plan.cell_size - bot.body.x), -((wp.y + 0.5) * plan.cell_size - bot.body.z))
		bot.pitch = 0.0

# =============================================================================================
# The Reactor's crews (RX2): bot players for floor 7, the generated station (sim/station_floor.gd), used by
# tests/prop_station_crews.gd and tools/station_crews.gd to measure the floor. Nothing above uses any of it.
# They know only what a player could know:
#   - the plan (the rooms they walk) and the fuse spots as the places to search, but not which one holds the
#     fuse until one of them sees it (a clear line within STATION_SEE_FUSE, or standing within STATION_SEARCH);
#   - the four where one of them sees them (a clear line within STATION_SEE_LIT while the light is on, STATION_SEE
#     in the emergency light, inside the skill's cone of view) or hears them (a standing body's run within the
#     skill's hearing; a crawl's scrape within STATION_HEAR_CRAWL); where one was is remembered, not followed;
#   - the crew shares what any one of them knows (they talk), as a party on voice does.
# The skills (STATION_SKILLS):
#   careless  walks; searches the nearest spot nobody has searched; at the cut the nearest fetches the fuse straight
#             and walks it to the cabinet; sprints only once a body it knows of is within 5 m, fleeing to the
#             cell with the most time in hand; never creeps into the crawl; heals a downed crewmate at once; the
#             rest wait by the lift.
#   sensible  splits the search; whoever finds the fuse waits by it for the cut; every move goes through cells it
#             reaches a margin before any body it knows of could, so it breaks off and takes another way, or
#             creeps into the crawl to lose a chaser; sprints once one is within 10 m; with two or more, one draws
#             the four (stays 8-12 m off them, far from the carrier) while another carries; the rest wait by a
#             crawl mouth; heals only when no body it knows of is within 9 m of the downed crewmate.
#   expert    as sensible, with a wider margin and hearing, and sprints whenever a body is within 14 m.
# Deterministic: no random draws (ties go to the lower index).

const SR = preload("res://sim/station_floor.gd")
const StationPlan = preload("res://sim/station.gd")
const Sight = preload("res://sim/sight.gd")
const Settings = preload("res://sim/settings.gd")

const STATION_SKILLS := {
	&"careless": {"cone": 60.0, "hear": 8.0, "chase": 5.0, "crawl": false, "plan": false, "split": false, "wait_fuse": false,
		"decoy": false, "heal_clear": 0.0, "margin": 0.0},
	&"sensible": {"cone": 180.0, "hear": 12.0, "chase": 10.0, "crawl": true, "plan": true, "split": true, "wait_fuse": true,
		"decoy": true, "heal_clear": 9.0, "margin": 1.0},
	&"expert": {"cone": 180.0, "hear": 16.0, "chase": 14.0, "crawl": true, "plan": true, "split": true, "wait_fuse": true,
		"decoy": true, "heal_clear": 9.0, "margin": 1.6},
}
const STATION_SEE := 12.0
const STATION_SEE_LIT := 30.0
const STATION_SEE_FUSE := 5.0
const STATION_SEE_FUSE_LIT := 9.0
const STATION_SEARCH := 2.0
const STATION_HEAR_CRAWL := 4.0
## Seconds a body's last known place still counts as where it is.
const STATION_MEMORY := 20.0
## Seconds between re-planning the crew's moves.
const STATION_REPLAN := 0.25
## Seconds in the crawl before a careful player makes a break for it.
const STATION_PATIENCE := 8.0
## RX3: a careful player creeps while a searching body it knows of is this near; the draw whistles this often.
const STATION_SNEAK := 12.0
const STATION_SHOUT_GAP := 8.0
## RX3: beyond this from a running body a careful player creeps rather than sprints (a sprint is heard far).
const STATION_QUIET := 6.0
## RX3: with this many seconds left before the bell a careful player makes for the open car whatever is about.
const STATION_BELL_DASH := 15.0

class StationMind:
	var skill: StringName = &"sensible"
	var k: Dictionary = {}
	var plan: Floor.FloorPlan = null
	var adj: Floor.Adjacency = null
	var crawl := {}
	var mouths: Array[int] = []
	var cab_goal: Vector2
	var fuse_known := false
	var searched := {}
	var claim := {}
	## Per body (by index): [known, x, z, t_seen, threat].
	var seen: Array = []
	var stamina := {}
	var heading := {}
	var carrier := ""
	var decoy := ""
	var healer := {}
	var tape_taker := ""
	var d_threat := PackedInt32Array()
	var threat_at := -INF
	var routes := {}
	## The landing's cell while the car stands open after the power is back (the car is out of the four's reach), else -1.
	var refuge := -1
	## Seconds each player has been in the crawl this time.
	var hid := {}
	## Seconds each player has waited with no way to its goal.
	var stuck := {}
	## RX3: host time of the draw's last whistle.
	var shout_at := -INF

static func station_mind(skill: StringName) -> StationMind:
	var m := StationMind.new()
	m.skill = skill
	m.k = STATION_SKILLS[skill]
	return m

static func _station_reset(m: StationMind, s: Run.RunState, st: SR.StationFloor) -> void:
	var plan := st.plan
	m.plan = plan
	m.adj = Floor.adjacency_of(plan)
	m.crawl = {}
	for c: Vector2i in plan.station["crawl"]:
		m.crawl[c.y * plan.width + c.x] = true
	# The cells just outside the crawl's mouths (where it can be slipped into).
	m.mouths.clear()
	for at: int in m.crawl.keys():
		for k in range(m.adj.start[at], m.adj.start[at + 1]):
			var to := m.adj.list[k]
			if to < plan.width * plan.height and not m.crawl.has(to) and not m.mouths.has(to):
				m.mouths.append(to)
	m.mouths.sort()
	var cab: Dictionary = plan.station["cabinet"]
	var at3: Vector3 = cab["at"]
	var yaw := float(cab["yaw"])
	m.cab_goal = Vector2(at3.x - sin(yaw) * 0.6, at3.z - cos(yaw) * 0.6)
	m.seen = []
	for i in st.bodies.size():
		m.seen.append([false, 0.0, 0.0, -INF, false, false])
	m.fuse_known = false
	m.searched = {}
	m.claim = {}
	m.carrier = ""
	m.decoy = ""
	m.threat_at = -INF
	m.routes = {}
	m.tape_taker = s.players[s.players.size() - 1].id

## This tick's inputs for every player of the run, on the Reactor's station (anything else: everyone stands).
static func station_inputs(s: Run.RunState, m: StationMind, dt: float) -> Array[Run.PlayerInput]:
	var out: Array[Run.PlayerInput] = []
	var st: SR.StationFloor = s.station
	if st == null or s.phase == &"riding" or s.phase == &"ended":
		for p in s.players:
			out.append(Run.PlayerInput.make(p.id, p.body, BOT_EYE, 0.0, 0.0, 90.0, 70.0))
		return out
	if m.plan != st.plan:
		_station_reset(m, s, st)
	_station_perceive(s, st, m)
	m.refuge = st.plan.landing.y * st.plan.width + st.plan.landing.x if st.power == SR.Power.RESTORED and s.phase == &"boarding" else -1
	if s.t - m.threat_at >= STATION_REPLAN - 1e-9:
		m.threat_at = s.t
		m.d_threat = _station_threat_map(s, st, m)
		m.routes = {}
	_station_roles(s, st, m)
	for n in s.players.size():
		out.append(_station_one(s, st, m, n, dt))
	return out

static func _cell_index(plan: Floor.FloorPlan, x: float, z: float) -> int:
	var c := StationPlan.cell_of(x, z)
	if c.x < 0 or c.y < 0 or c.x >= plan.width or c.y >= plan.height:
		return -1
	return c.y * plan.width + c.x

static func _station_perceive(s: Run.RunState, st: SR.StationFloor, m: StationMind) -> void:
	var plan := st.plan
	var lit := st.power != SR.Power.EMERGENCY
	var spots: Array = plan.station["fuse_spots"]
	if not st.holder.is_empty():
		m.fuse_known = true
	for p in s.players:
		if p.status != &"ok" or Run.in_car(s.car, p.body):
			continue
		var eye := Sight.Point3.make(p.body.x, 1.6, p.body.z, 0)
		for i in st.bodies.size():
			var b := st.bodies[i]
			var dx := b.body.x - p.body.x
			var dz := b.body.z - p.body.z
			var d := M.hypot2(dx, dz)
			var know := false
			if (b.phase == "zombie_run" and d <= float(m.k["hear"])) or (b.phase == "zombie_walk" and d <= 0.6 * float(m.k["hear"])):
				know = true
			elif b.phase == "zombie_crawl" and d <= STATION_HEAR_CRAWL:
				know = true
			elif d <= (STATION_SEE_LIT if lit else STATION_SEE) and _station_in_cone(m, p.id, dx, dz) \
					and Sight.has_line_of_sight(plan, eye, Sight.Point3.make(b.body.x, 0.5, b.body.z, 0)):
				know = true
			if know:
				m.seen[i] = [true, b.body.x, b.body.z, s.t, st.power != SR.Power.NORMAL, b.phase == "zombie_run"]
		if m.fuse_known:
			continue
		for j in spots.size():
			if m.searched.has(j):
				continue
			var f: Vector3 = spots[j]
			var d2 := M.hypot2(f.x - p.body.x, f.z - p.body.z)
			if d2 <= STATION_SEARCH or (d2 <= (STATION_SEE_FUSE_LIT if lit else STATION_SEE_FUSE) and _station_in_cone(m, p.id, f.x - p.body.x, f.z - p.body.z) \
					and Sight.has_line_of_sight(plan, eye, Sight.Point3.make(f.x, 0.3, f.z, 0))):
				m.searched[j] = true
				if st.holder.is_empty() and M.hypot2(st.fuse.x - f.x, st.fuse.z - f.z) < 0.5:
					m.fuse_known = true
		# A dropped fuse is found as a spot is.
		if not m.fuse_known and st.holder.is_empty() and M.hypot2(st.fuse.x - p.body.x, st.fuse.z - p.body.z) <= STATION_SEARCH:
			m.fuse_known = true

static func _station_in_cone(m: StationMind, id: String, dx: float, dz: float) -> bool:
	var cone := float(m.k["cone"])
	if cone >= 180.0 or not m.heading.has(id):
		return true
	var h: Vector2 = m.heading[id]
	var v := Vector2(dx, dz)
	if v.length() < 1e-6:
		return true
	return rad_to_deg(absf(h.angle_to(v))) <= cone

## Per cell, the cells (2 m) a body the crew knows of is from it in the time the crew can count on: the walk
## from where it was last known (the crawl excluded), less the ground it may have covered since (its age at the
## run speed), plus, for one still crawling, the few seconds it takes to stand (the crew hears the stir and has
## seen how long a crawl lasts). -1 where none can walk. After the cut every one of the four is a threat.
static func _station_threat_map(s: Run.RunState, st: SR.StationFloor, m: StationMind) -> PackedInt32Array:
	var plan := st.plan
	var n := plan.width * plan.height
	var dist := PackedInt32Array()
	dist.resize(n)
	dist.fill(-1)
	if st.power == SR.Power.NORMAL:
		return dist
	var run_speed := SR.pursuit_speed(s.players.size(), s.tuning)
	var crawl_time := Settings.f(s.tuning, &"reactor.crawl_time", SR.CRAWL_TIME)
	for i in m.seen.size():
		var e: Array = m.seen[i]
		if not bool(e[0]) or not bool(e[4]) or s.t - float(e[3]) > STATION_MEMORY:
			continue
		var c := _cell_index(plan, float(e[1]), float(e[2]))
		if c < 0:
			continue
		var up_in := maxf(0.0, crawl_time - (st.awake - SR.wake_time(st, i, s.tuning))) if st.bodies[i].phase == "zombie_crawl" or st.bodies[i].phase == "still" else 0.0
		# RX3: a body not seen running (searching or crawling) has sensed nobody; it is a danger only close by.
		var slow := not bool(e[5])
		var head_start := int(floor((up_in * run_speed - (s.t - float(e[3])) * run_speed) / float(plan.cell_size)))
		var one := PackedInt32Array()
		one.resize(n)
		one.fill(-1)
		one[c] = 0
		var queue := PackedInt32Array([c])
		var head := 0
		while head < queue.size():
			var at := queue[head]
			head += 1
			for k in range(m.adj.start[at], m.adj.start[at + 1]):
				var to := m.adj.list[k]
				if to >= n or one[to] >= 0 or m.crawl.has(to):
					continue
				one[to] = one[at] + 1
				queue.append(to)
		for j in n:
			if one[j] < 0:
				continue
			# A slow one (searching or crawling) is only a danger close by: a careful player creeps past it.
			var cells := one[j] if not slow or one[j] <= 2 else 1000
			var v := maxi(0, cells + head_start)
			if dist[j] < 0 or v < dist[j]:
				dist[j] = v
	return dist

## Metres from `b` to the nearest body the crew knows of this second, INF if none.
static func _station_near_threat(s: Run.RunState, st: SR.StationFloor, m: StationMind, b: Move.Body) -> float:
	var best := INF
	for i in st.bodies.size():
		var e: Array = m.seen[i]
		if not bool(e[0]) or not bool(e[4]) or s.t - float(e[3]) > 1.0:
			continue
		best = minf(best, M.hypot2(float(e[1]) - b.x, float(e[2]) - b.z))
	return best

## RX3: the same for a body seen running (it has sensed someone), and for one seen walking (searching).
static func _station_near_kind(s: Run.RunState, st: SR.StationFloor, m: StationMind, b: Move.Body, running: bool) -> float:
	var best := INF
	for i in st.bodies.size():
		var e: Array = m.seen[i]
		if not bool(e[0]) or not bool(e[4]) or s.t - float(e[3]) > 1.0 or bool(e[5]) != running:
			continue
		best = minf(best, M.hypot2(float(e[1]) - b.x, float(e[2]) - b.z))
	return best

static func _station_roles(s: Run.RunState, st: SR.StationFloor, m: StationMind) -> void:
	var ok: Array[Run.RunPlayer] = []
	var ok_ids: Array[String] = []
	for p in s.players:
		if p.status == &"ok" and not Run.in_car(s.car, p.body):
			ok.append(p)
			ok_ids.append(p.id)
	if not st.holder.is_empty():
		m.carrier = st.holder
	elif m.fuse_known and st.power != SR.Power.RESTORED:
		if not bool(m.k["split"]) or not ok_ids.has(m.carrier):
			m.carrier = ""
			var best := INF
			for p in ok:
				var d := M.hypot2(st.fuse.x - p.body.x, st.fuse.z - p.body.z)
				if d < best - 1e-9:
					best = d
					m.carrier = p.id
	else:
		m.carrier = ""
	if bool(m.k["decoy"]) and ok.size() >= 2 and st.power == SR.Power.EMERGENCY:
		if not ok_ids.has(m.decoy) or m.decoy == m.carrier:
			m.decoy = ""
			for p in ok:
				if p.id != m.carrier:
					m.decoy = p.id
					break
	else:
		m.decoy = ""
	# Healers: for each downed crewmate, the nearest on their feet who is not carrying (the carrier when alone).
	m.healer = {}
	for q in s.players:
		if q.status != &"down":
			continue
		var best := INF
		var who := ""
		for p in ok:
			if m.healer.values().has(p.id):
				continue
			if p.id == m.carrier and ok.size() > 1:
				continue
			var d := M.hypot2(q.body.x - p.body.x, q.body.z - p.body.z)
			if d < best - 1e-9:
				best = d
				who = p.id
		if not who.is_empty():
			m.healer[q.id] = who

static func _station_search_goal(st: SR.StationFloor, m: StationMind, p: Run.RunPlayer) -> Vector2:
	var spots: Array = st.plan.station["fuse_spots"]
	if bool(m.k["split"]) and m.claim.has(p.id) and not m.searched.has(int(m.claim[p.id])):
		var f0: Vector3 = spots[int(m.claim[p.id])]
		return Vector2(f0.x, f0.z)
	var taken := {}
	if bool(m.k["split"]):
		for id: String in m.claim:
			if id != p.id:
				taken[int(m.claim[id])] = true
	var best := INF
	var pick := -1
	for j in spots.size():
		if m.searched.has(j) or taken.has(j):
			continue
		var f: Vector3 = spots[j]
		var d := M.hypot2(f.x - p.body.x, f.z - p.body.z)
		if d < best - 1e-9:
			best = d
			pick = j
	if pick < 0:
		for j in spots.size():
			if not m.searched.has(j):
				pick = j
				break
	if pick < 0:
		var hall: Rect2 = st.plan.station["hall"]
		return hall.get_center()
	m.claim[p.id] = pick
	var f2: Vector3 = spots[pick]
	return Vector2(f2.x, f2.z)

## The draw's place: a cell 8-12 m (by walking) from the nearest known body, as far as can be from the carrier,
## near a crawl mouth; the hall's middle when no body is known.
static func _station_lure_goal(s: Run.RunState, st: SR.StationFloor, m: StationMind) -> Vector2:
	var plan := st.plan
	var hall: Rect2 = plan.station["hall"]
	var carrier_at := hall.get_center()
	for p in s.players:
		if p.id == m.carrier:
			carrier_at = Vector2(p.body.x, p.body.z)
	var best := -INF
	var pick := -1
	for c in m.d_threat.size():
		var d := m.d_threat[c]
		if d < 4 or d > 6 or m.crawl.has(c):
			continue
		var x := StationPlan.wc(c % plan.width)
		var z := StationPlan.wc(c / plan.width)
		var mouth := INF
		for mc in m.mouths:
			mouth = minf(mouth, M.hypot2(StationPlan.wc(mc % plan.width) - x, StationPlan.wc(mc / plan.width) - z))
		var score := M.hypot2(x - carrier_at.x, z - carrier_at.y) - 0.5 * mouth
		if score > best + 1e-9:
			best = score
			pick = c
	if pick < 0:
		return hall.get_center()
	return Vector2(StationPlan.wc(pick % plan.width), StationPlan.wc(pick / plan.width))

## Per cell, the seconds a player at `start` takes to get there (the crawl at the creep), and the parent cell; with
## `safe`, only through cells it reaches `margin` seconds before any body the crew knows of could.
static func _station_reach(m: StationMind, start: int, speed: float, run_speed: float, margin: float, allow_crawl: bool, safe: bool) -> Array:
	var plan := m.plan
	var n := plan.width * plan.height
	var time := PackedFloat32Array()
	time.resize(n)
	time.fill(-1.0)
	var parent := PackedInt32Array()
	parent.resize(n)
	parent.fill(-2)
	if start < 0:
		return [time, parent]
	time[start] = 0.0
	parent[start] = -1
	var queue := PackedInt32Array([start])
	var head := 0
	while head < queue.size():
		var at := queue[head]
		head += 1
		for k in range(m.adj.start[at], m.adj.start[at + 1]):
			var to := m.adj.list[k]
			if to >= n:
				continue
			var in_crawl := m.crawl.has(to)
			if in_crawl and not allow_crawl:
				continue
			var nt := time[at] + float(plan.cell_size) / (Stamina.CREEP_SPEED if in_crawl else speed)
			if safe and not in_crawl and m.d_threat.size() == n and m.d_threat[to] >= 0 \
					and nt + (0.0 if to == m.refuge else margin) >= float(m.d_threat[to] * plan.cell_size) / run_speed:
				continue
			if time[to] < 0.0 or nt < time[to] - 1e-6:
				time[to] = nt
				parent[to] = at
				queue.append(to)
	return [time, parent]

static func _station_path(plan: Floor.FloorPlan, parent: PackedInt32Array, goal: int) -> Array[Floor.Pos]:
	var rev: Array[Floor.Pos] = []
	var cur := goal
	var guard := 0
	while cur >= 0 and guard < 10000:
		rev.append(Floor.Pos.make(0, cur % plan.width, cur / plan.width))
		cur = parent[cur]
		guard += 1
	var out: Array[Floor.Pos] = []
	for i in range(rev.size() - 1, -1, -1):
		out.append(rev[i])
	return out

## Metres from cell `c` to the nearest body the crew has seen (INF when none).
static func _station_far(m: StationMind, c: int) -> float:
	var x := StationPlan.wc(c % m.plan.width)
	var z := StationPlan.wc(c / m.plan.width)
	var best := INF
	for e: Array in m.seen:
		if bool(e[0]):
			best = minf(best, M.hypot2(float(e[1]) - x, float(e[2]) - z))
	return best

## The way to flee: the reachable cell with the most time in hand before the nearest body (the crawl first when
## allowed); failing any, the next cell furthest from them.
static func _station_flee(m: StationMind, start: int, reach: Array, run_speed: float) -> Array[Floor.Pos]:
	var plan := m.plan
	var time: PackedFloat32Array = reach[0]
	var parent: PackedInt32Array = reach[1]
	var best := -INF
	var pick := -1
	for c in time.size():
		if time[c] < 0.0 or c == start or time[c] > 8.0:
			continue
		var score: float
		if c == m.refuge:
			score = 2000.0 - time[c]
		elif m.crawl.has(c):
			# Deeper in, away from the bodies at the mouths.
			score = 1000.0 - time[c] * 0.2 + minf(10.0, _station_far(m, c))
		elif m.d_threat[c] < 0:
			score = 500.0 - time[c]
		else:
			score = float(m.d_threat[c] * plan.cell_size) / run_speed - time[c]
		if score > best + 1e-9:
			best = score
			pick = c
	if pick >= 0:
		return _station_path(plan, parent, pick)
	var out: Array[Floor.Pos] = [Floor.Pos.make(0, start % plan.width, start / plan.width)]
	var far := m.d_threat[start]
	var go := -1
	for k in range(m.adj.start[start], m.adj.start[start + 1]):
		var to := m.adj.list[k]
		if to >= time.size() or (m.crawl.has(to) and not bool(m.k["crawl"])):
			continue
		var d := 99 if m.crawl.has(to) else m.d_threat[to]
		if d > far:
			far = d
			go = to
	if go >= 0:
		out.append(Floor.Pos.make(0, go % plan.width, go / plan.width))
	return out

static func _station_one(s: Run.RunState, st: SR.StationFloor, m: StationMind, n: int, dt: float) -> Run.PlayerInput:
	var plan := st.plan
	var p := s.players[n]
	var b := p.body
	if p.status == &"down":
		# Crawl towards the nearest crewmate on their feet (whoever is coming to heal).
		var to: Move.Body = null
		var best := INF
		for q in s.players:
			if q.status == &"ok" and not Run.in_car(s.car, q.body):
				var d := M.hypot2(q.body.x - b.x, q.body.z - b.z)
				if d < best:
					best = d
					to = q.body
		if to != null and best > 1.0:
			var step := minf(Run.CRAWL_SPEED * 0.95 * dt, best - 1.0)
			b = Run.move_in_run(s, b, (to.x - b.x) / best * step, (to.z - b.z) / best * step, BOT_RADIUS)
		return Run.PlayerInput.make(p.id, b, 0.5, 0.0, 0.0, 90.0, 70.0)
	if p.status != &"ok":
		return Run.PlayerInput.make(p.id, b, BOT_EYE, 0.0, 0.0, 90.0, 70.0)
	var goal := Vector2(b.x, b.z)
	var to_car := false
	var use := false
	var call := false
	var hall: Rect2 = plan.station["hall"]
	var heal_for: Run.RunPlayer = null
	for q in s.players:
		if m.healer.get(q.id, "") == p.id:
			heal_for = q
	var heal_ok := false
	if heal_for != null:
		var qc := _cell_index(plan, heal_for.body.x, heal_for.body.z)
		var clear := float(m.k["heal_clear"])
		heal_ok = clear <= 0.0 or qc < 0 or m.d_threat[qc] < 0 or float(m.d_threat[qc] * plan.cell_size) >= clear
		if heal_ok:
			goal = Vector2(heal_for.body.x, heal_for.body.z)
			use = M.hypot2(heal_for.body.x - b.x, heal_for.body.z - b.z) < 1.3
	if not heal_ok:
		if st.power == SR.Power.RESTORED:
			to_car = true
			call = s.phase == &"away"
		elif p.id == m.tape_taker and not st.collected and st.cassette_holder.is_empty() and st.power == SR.Power.NORMAL \
				and M.hypot2(st.tape.x - b.x, st.tape.z - b.z) < 12.0:
			goal = Vector2(st.tape.x, st.tape.z)
			use = M.hypot2(st.tape.x - b.x, st.tape.z - b.z) < 1.8
		elif st.power == SR.Power.NORMAL:
			if st.hold_left < 0.0:
				goal = hall.get_center()
			elif not m.fuse_known:
				goal = _station_search_goal(st, m, p)
			elif p.id == m.carrier and bool(m.k["wait_fuse"]):
				goal = Vector2(st.fuse.x, st.fuse.z)
			elif bool(m.k["plan"]) and not m.mouths.is_empty():
				var mc := m.mouths[n % m.mouths.size()]
				goal = Vector2(StationPlan.wc(mc % plan.width), StationPlan.wc(mc / plan.width))
			else:
				goal = hall.get_center()
		elif st.holder == p.id:
			goal = m.cab_goal
			use = M.hypot2(st.cabinet.x - b.x, st.cabinet.z - b.z) < 1.8
		elif m.carrier == p.id:
			goal = Vector2(st.fuse.x, st.fuse.z)
			use = M.hypot2(st.fuse.x - b.x, st.fuse.z - b.z) < 1.8
		elif not m.fuse_known:
			goal = _station_search_goal(st, m, p)
		elif m.decoy == p.id:
			goal = _station_lure_goal(s, st, m)
		elif bool(m.k["plan"]) and not m.mouths.is_empty():
			var mc2 := m.mouths[n % m.mouths.size()]
			goal = Vector2(StationPlan.wc(mc2 % plan.width), StationPlan.wc(mc2 / plan.width))
		else:
			to_car = true
	var in_car := Run.in_car(s.car, b)
	var spot := Run.car_body(s.car, Run.CAR_DEPTH - 0.7, -1.2 + 0.8 * float(n % 4))
	if to_car and in_car:
		var before0 := b
		b = _station_straight(s, b, Vector2(spot.x, spot.z), Stamina.WALK_SPEED * dt)
		_station_stamina(s, m, p.id, &"walk", M.hypot2(b.x - before0.x, b.z - before0.z) / dt, dt)
		var inp0 := Run.PlayerInput.make(p.id, b, BOT_EYE, 0.0, 0.0, 90.0, 70.0)
		inp0.call = call
		return inp0
	var start := _cell_index(plan, b.x, b.z)
	if in_car or start < 0 or not Floor.is_walkable(plan, 0, start % plan.width, start / plan.width):
		# Out of the car first: a step onto the landing.
		var land := plan.landing
		b = _station_straight(s, b, Vector2(StationPlan.wc(land.x), StationPlan.wc(land.y)), Stamina.WALK_SPEED * dt)
		return Run.PlayerInput.make(p.id, b, BOT_EYE, 0.0, 0.0, 90.0, 70.0)
	var goal_cell := plan.landing.y * plan.width + plan.landing.x if to_car else _cell_index(plan, goal.x, goal.y)
	if goal_cell < 0 or not Floor.is_walkable(plan, 0, goal_cell % plan.width, goal_cell / plan.width):
		goal_cell = start
	var threat := _station_near_threat(s, st, m, b)
	var run_speed := SR.pursuit_speed(s.players.size(), s.tuning)
	var stam: Stamina.Stamina = m.stamina.get(p.id, Stamina.fresh_stamina(Run.sprint_seconds(s, p.id)))
	# The pace it plans with: a sprint only on a tank at least half full.
	var speed := Stamina.SPRINT_SPEED if not stam.winded and stam.level > 0.5 else Stamina.WALK_SPEED
	var chased := threat <= float(m.k["chase"])
	var sneak := false
	if Settings.f(s.tuning, &"reactor.senses", SR.SENSES) > 0.5 and st.power != SR.Power.NORMAL:
		# RX3: only a running body has sensed someone; a careful player creeps (silent, seen only close) past a
		# searching one and sprints (loud) only from a running one.
		var hunter := _station_near_kind(s, st, m, b, true)
		chased = hunter <= float(m.k["chase"])
		sneak = bool(m.k["plan"]) and not chased and _station_near_kind(s, st, m, b, false) <= STATION_SNEAK and not to_car
		# Out of a running body's earshot for a walk and its sight, a careful player goes quiet instead of sprinting.
		if bool(m.k["plan"]) and chased and hunter > STATION_QUIET and not to_car:
			sneak = true
	var path: Array[Floor.Pos] = []
	# Patience: a player who has hidden in the crawl STATION_PATIENCE seconds makes a break for it (plans with no
	# margin, at a sprint), as people do.
	if m.crawl.has(start):
		m.hid[p.id] = float(m.hid.get(p.id, 0.0)) + dt
	else:
		m.hid[p.id] = 0.0
	var bold := float(m.hid[p.id]) >= STATION_PATIENCE or float(m.stuck.get(p.id, 0.0)) >= STATION_PATIENCE
	# The bell is coming: a careful player makes for the car anyway.
	if to_car and s.phase == &"boarding" and s.bell_left < STATION_BELL_DASH:
		bold = true
	if bold:
		speed = Stamina.SPRINT_SPEED if not stam.winded else Stamina.WALK_SPEED
	var key := "%d>%d>%s>%s" % [start, goal_cell, chased, bold]
	var cached: Array = m.routes.get(p.id, [])
	if not cached.is_empty() and cached[0] == key:
		path = cached[1]
	else:
		if bool(m.k["plan"]):
			var reach := _station_reach(m, start, speed, run_speed, -1.0 if bold else float(m.k["margin"]), true, true)
			# Where it stands, could a body it knows of be on it within the margin and a second and a half? Then go.
			var danger := not m.crawl.has(start) and start != m.refuge and m.d_threat[start] >= 0 \
				and float(m.d_threat[start] * plan.cell_size) / run_speed <= float(m.k["margin"]) + 1.5
			if (danger or (chased and sneak)) and goal_cell != m.refuge:
				# RX3: a running body is coming: get away from where it last sensed us, quietly when it is far enough.
				path = _station_flee(m, start, reach, run_speed)
			elif (reach[0] as PackedFloat32Array)[goal_cell] >= 0.0:
				path = _station_path(plan, reach[1], goal_cell)
			elif m.d_threat[start] >= 0 and float(m.d_threat[start] * plan.cell_size) <= float(m.k["chase"]) + 2.0:
				path = _station_flee(m, start, reach, run_speed)
			if path.is_empty() and bold:
				var plain := _station_reach(m, start, speed, run_speed, 0.0, true, false)
				if (plain[0] as PackedFloat32Array)[goal_cell] >= 0.0:
					path = _station_path(plan, plain[1], goal_cell)
		elif chased:
			path = _station_flee(m, start, _station_reach(m, start, speed, run_speed, 0.0, false, true), run_speed)
		else:
			var reach2 := _station_reach(m, start, speed, run_speed, 0.0, false, false)
			if (reach2[0] as PackedFloat32Array)[goal_cell] >= 0.0:
				path = _station_path(plan, reach2[1], goal_cell)
		m.routes[p.id] = [key, path]
	# Waiting with no way to its goal counts towards patience as hiding does.
	if path.size() < 2 and goal_cell != start:
		m.stuck[p.id] = float(m.stuck.get(p.id, 0.0)) + dt
	else:
		m.stuck[p.id] = 0.0
	var sprint := chased and st.power != SR.Power.NORMAL and not sneak
	var creep := sneak or m.crawl.has(start) or (path.size() >= 2 and m.crawl.has(path[1].y * plan.width + path[1].x))
	var gait := Stamina.gait_for(stam, sprint, creep, true, INF)
	var dist := Stamina.speed_for(gait) * dt
	var before := b
	if path.size() >= 2:
		var here := 0
		for i in path.size():
			if path[i].y * plan.width + path[i].x == start:
				here = i
		if here + 1 < path.size():
			var walk := Follow.PathWalk.make(path, here + 1)
			b = Follow.step_path_walk(plan, walk, b, dist, BOT_RADIUS)
		else:
			b = _station_straight(s, b, Vector2(StationPlan.wc(path[here].x), StationPlan.wc(path[here].y)), dist)
	elif to_car:
		# Line up on the door's middle first, then straight in (as tests/prop_station.gd walks a player in).
		var l := Run.car_local(s.car, b.x, b.z)
		var aim := spot if absf(l[1]) < 0.3 else Run.car_body(s.car, -0.5, 0.0)
		b = _station_straight(s, b, Vector2(aim.x, aim.z), dist)
	elif goal_cell == start or (path.is_empty() and not bool(m.k["plan"])):
		b = _station_straight(s, b, goal, dist)
	var moved := M.hypot2(b.x - before.x, b.z - before.z)
	if moved > 1e-6:
		m.heading[p.id] = Vector2(b.x - before.x, b.z - before.z)
	_station_stamina(s, m, p.id, gait, moved / dt, dt)
	var inp := Run.PlayerInput.make(p.id, b, 0.9 if gait == &"creep" else BOT_EYE, 0.0, 0.0, 90.0, 70.0)
	inp.gait = gait
	inp.use = use
	inp.call = call
	# RX3: the draw whistles to pull the four off the carrier (a sound emote), at most every STATION_SHOUT_GAP s,
	# when one the crew knows of is near the carrier and none near itself.
	if p.id == m.decoy and st.power == SR.Power.EMERGENCY and s.t - m.shout_at >= STATION_SHOUT_GAP \
			and Settings.f(s.tuning, &"reactor.senses", SR.SENSES) > 0.5:
		var cb: Move.Body = null
		for q in s.players:
			if q.id == m.carrier and q.status == &"ok":
				cb = q.body
		if cb != null and _station_near_threat(s, st, m, cb) <= 14.0 and threat >= 8.0 and M.hypot2(cb.x - b.x, cb.z - b.z) >= 10.0:
			inp.emote_sound = true
			m.shout_at = s.t
	return inp

static func _station_stamina(s: Run.RunState, m: StationMind, id: String, gait: StringName, ground: float, dt: float) -> void:
	var stam: Stamina.Stamina = m.stamina.get(id, Stamina.fresh_stamina(Run.sprint_seconds(s, id)))
	m.stamina[id] = Stamina.step_stamina(stam, gait, ground, dt)

static func _station_straight(s: Run.RunState, b: Move.Body, goal: Vector2, dist: float) -> Move.Body:
	var dx := goal.x - b.x
	var dz := goal.y - b.z
	var d := M.hypot2(dx, dz)
	if d < 1e-6:
		return b
	var step := minf(dist, d)
	return Run.move_in_run(s, b, dx / d * step, dz / d * step, BOT_RADIUS)
