## A companion in a local room. It sends the usual camera and action inputs
## through a real NetClient. It has no special host commands.
extends RefCounted

const Bot = preload("res://sim/bot.gd")
const Client = preload("res://net/client.gd")
const Entity = preload("res://sim/entity.gd")
const Floor = preload("res://sim/floor.gd")
const Follow = preload("res://sim/follow.gd")
const Instr = preload("res://sim/instrument.gd")
const Move = preload("res://sim/move.gd")
const Run = preload("res://sim/run.gd")
const Stamina = preload("res://sim/stamina.gd")

const HOLD_RANGE := 3.1
const RECORD_SECONDS := 8.0
const REST_SECONDS := 2.0
const LOOK_CYCLE := 5.0
const LOOK_AWAY_SECONDS := 1.15

var peer: Client
var id: String
var number: int
var _plan: Floor.FloorPlan
var _walker: Bot.WaitBot
var _scout: Bot.Bot
var _destination: Floor.Pos
var _returning := false
var _repath_at := 0.0

func _init(id_: String, number_: int, peer_: Client) -> void:
	id = id_
	number = number_
	peer = peer_

## DG0, test only (client/main.gd `standin`): stand still here facing stand_yaw (null: the bot plays as usual).
var stand_at: Move.Body = null
var stand_yaw := 0.0
## DG0, test only: walk to stand_at instead of being put there; hold F (a heal, a cut down, a pull up).
var stand_walk := false
var stand_use := false

func poll(s: Run.RunState, now: float, dt: float, human_id: String) -> void:
	var own: Run.RunPlayer
	var human: Run.RunPlayer
	for player in s.players:
		if player.id == id:
			own = player
		elif player.id == human_id:
			human = player
	if own == null:
		return
	if _plan != s.plan:
		_plan = s.plan
		_walker = Bot.create_wait_bot(s, id, number, &"flee")
		_walker.body = own.body
		_scout = null
		_destination = null
		_returning = false
	var input := Client.LocalFrame.new()
	input.eye = Bot.BOT_EYE
	input.h_fov_deg = Bot.BOT_HFOV_DEG
	input.v_fov_deg = Bot.BOT_VFOV_DEG
	if stand_at != null and (own.status == &"ok" or own.status == &"down"):
		# DG0's test channel `standin`: a friend for pictures. Standing still at a spot (the host places it there), or
		# walking straight to it at a walk (`standin walk`), holding F when asked (`standin use 1`). Down, it stays put.
		if own.status == &"ok" and stand_walk:
			var to := Vector2(stand_at.x - _walker.body.x, stand_at.z - _walker.body.z)
			var step := to.limit_length(Stamina.WALK_SPEED * dt)
			if step.length() > 1e-6:
				_walker.body = Run.move_in_run(s, _walker.body, step.x, step.y, Bot.BOT_RADIUS)
		elif own.status == &"ok":
			_walker.body = stand_at
		else:
			_walker.body = own.body
		_walker.yaw = stand_yaw
		_walker.walk = null
		input.use = stand_use
		input.gait = "walk"
	elif own.status == &"ok" and s.phase != &"riding":
		_decide(s, dt, human, input)
	input.body = _walker.body
	input.yaw = _walker.yaw
	input.pitch = _walker.pitch
	peer.receive(now)
	var frame := peer.frame(now, input)
	if frame.placed != null:
		_walker.body = frame.placed
		_walker.walk = null
		_destination = null
		_scout = null

func _decide(s: Run.RunState, dt: float, human: Run.RunPlayer, input: Client.LocalFrame) -> void:
	if s.phase == &"arriving":
		return
	var aboard := Run.in_car(s.car, _walker.body)
	if s.phase == &"unloading" and aboard:
		var spot := Run.car_local(s.car, _walker.body.x, _walker.body.z)
		_enter_or_exit(s, Run.car_body(s.car, 0.33 if spot[0] > 0.43 else -0.84, 0.0), dt)
		return
	if Run.at_home(s):
		# A bot cannot start bedtime while its human is still shopping or reading.
		if human != null and s.bed != null and s.bed.in_bed.has(human.id) and not s.bed.in_bed.has(id):
			var bunk := Run.bunk_body(s.plan, s.bed.crew, id)
			_walk_to(s, Move.cell_of(s.plan, bunk), dt, Stamina.WALK_SPEED)
			input.use = Run.at_bunk(s.plan, _walker.body)
		return
	if s.phase in [&"coming", &"boarding"]:
		if aboard:
			_vote(s, human, dt)
			input.hold_doors = human != null and human.status == &"ok" and not human.aboard
			return
		if not _returning:
			_returning = true
			_walker.mode = &"return"
			_walker.walk = null
			_walker.route.clear()
		Bot.step_wait_bot(s, _walker, dt)
		input.gait = str(_walker.gait)
		return
	_returning = false
	if s.orientation:
		# Leave the course's demonstration to the human.
		_walk_to(s, s.plan.landing, dt, Stamina.WALK_SPEED)
		if Move.cell_of(s.plan, _walker.body).equals(s.plan.landing):
			Bot._aim_at(_walker, Run.car_body(s.car, 1.0, 0.0))
		return
	if s.quota and Run.quota_reached(s) and not Run.day_locked(s):
		_walk_to(s, s.plan.landing, dt, Stamina.WALK_SPEED)
		Bot._aim_at(_walker, Run.nearest_orderly(s, _walker.body).body)
		return
	_read_or_scout(s, dt, input)

func _vote(s: Run.RunState, human: Run.RunPlayer, dt: float) -> void:
	# The human chooses by standing on a side. Bots walk onto that side too.
	# They never replace or skip the ordinary vote.
	var side: Variant = Run.car_side(s.car, human.body) if human != null and human.status == &"ok" else (&"down" if Run.day_locked(s) else &"bank")
	if side == null:
		return
	var sign_ := -1.0 if side == &"bank" else 1.0
	_enter_or_exit(s, Run.car_body(s.car, 1.0 + 0.5 * number, sign_ * 0.8), dt)

func _read_or_scout(s: Run.RunState, dt: float, input: Client.LocalFrame) -> void:
	# A second Orderly (T9b): the nearer one.
	var resident := Run.nearest_orderly(s, _walker.body).body
	var gap := Bot._flat_gap(_walker.body, resident)
	if gap <= Entity.HEAR_RANGE:
		var active := fposmod(s.t + 2.0 * number, RECORD_SECONDS + REST_SECONDS) < RECORD_SECONDS
		input.raised = active and gap < Instr.RECORD_RANGE
		if gap > HOLD_RANGE:
			_walk_to(s, Move.cell_of(s.plan, resident), dt, Instr.RAISED_SPEED_CAP if input.raised else Stamina.WALK_SPEED)
		elif gap < HOLD_RANGE - 0.35:
			var away := Vector2(_walker.body.x - resident.x, _walker.body.z - resident.z).normalized()
			var step := away * dt * Instr.RAISED_SPEED_CAP
			_walker.body = Run.move_in_run(s, _walker.body, step.x, step.y, Bot.BOT_RADIUS)
		Bot._aim_at(_walker, resident)
		# The instrument can record a dangerous action, not an Orderly that
		# the entire crew keeps frozen. Take short risks, with staggered looks.
		if fposmod(s.t + 0.06 * number, LOOK_CYCLE) < LOOK_AWAY_SECONDS:
			_walker.yaw = wrapf(_walker.yaw + PI, -PI, PI)
			_walker.pitch = 0.0
		_scout = null
		return
	if _scout == null:
		_scout = Bot.create_bot(s.plan, id, "%s/%d" % [s.seed, s.depth], -1.0, false, Move.cell_of(s.plan, _walker.body))
	_scout.body = _walker.body
	Bot.step_bot(s.plan, _scout, dt, null, Stamina.WALK_SPEED, Run.solids_in(s))
	_walker.body = _scout.body
	_walker.yaw = _scout.yaw
	_walker.pitch = _scout.pitch

func _walk_to(s: Run.RunState, goal: Floor.Pos, dt: float, speed: float) -> void:
	if s.t >= _repath_at and (_destination == null or Floor.pos_index(s.plan, _destination) != Floor.pos_index(s.plan, goal)):
		var line := Floor.find_path(s.plan, Move.cell_of(s.plan, _walker.body), goal)
		_walker.walk = Follow.PathWalk.make(line, 1 if line.size() > 1 else 0) if not line.is_empty() else null
		_walker.route.clear()
		_destination = goal
		_repath_at = s.t + 0.4
	if _walker.walk != null and not Follow.path_done(s.plan, _walker.walk, _walker.body):
		Bot._aim_at(_walker, Move.body_at_cell(s.plan, _walker.walk.path[_walker.walk.next]))
		Bot._follow(s, _walker, dt * speed)

func _enter_or_exit(s: Run.RunState, goal: Move.Body, dt: float) -> void:
	var delta := Vector2(goal.x - _walker.body.x, goal.z - _walker.body.z)
	if delta.length_squared() <= 0.0004:
		return
	Bot._aim_at(_walker, goal)
	var step := delta.limit_length(dt * Stamina.WALK_SPEED)
	_walker.body = Run.move_in_run(s, _walker.body, step.x, step.y, Bot.BOT_RADIUS)
