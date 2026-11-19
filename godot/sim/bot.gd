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
