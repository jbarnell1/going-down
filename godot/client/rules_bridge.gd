# THE boundary between the client and the game's rules. Everything rule-related the client knows
# comes through here: the floor plan, and each frame's state (the player's body, the Orderly's pose
# and whether it may be drawn, the lights and the dark, the lift, the instrument, the tapes, the
# events). The rest of the client never computes a rule; it draws and plays what this returns.
#
# The rules are the GDScript ones (res://sim, ported from src/sim and proved the same by tests/ref_*),
# called directly: no TypeScript, no Node. This file is the port of the interim TypeScript host
# (tools/rules_host.ts, which stays as the reference the bridge test compares against): per frame it
#   1. moves the player's body by Run.move_in_run at the gait the stamina rules allow (src/game/player.ts
#      control), capped while the instrument is up;
#   2. steps the run at 20 Hz through HostRules (host_rules.gd, src/game/runHost.ts), with this frame's
#      camera as the player's view;
#   3. picks the Orderly to draw: the last two tick poses blended (pose.gd lerp_pose), held still while
#      this camera could be showing it (the hold of src/net/client.ts frame(), with pose.gd camera_sees),
#      never drawn in the dark;
#   4. returns everything the screen and the speakers need in one snapshot Dictionary with the
#      TypeScript (camelCase) names, exactly as rules_host.ts snapshot() and planDump write them.
#
# One call per frame (step), so the Orderly drawn on a frame was decided with that frame's camera.
# Never written by tools/sync_client.mjs (the client's own copy of this file talks to TypeScript).
class_name RulesBridge
extends Node

const Run = preload("res://sim/run.gd")
const Entity = preload("res://sim/entity.gd")
const Floor = preload("res://sim/floor.gd")
const Follow = preload("res://sim/follow.gd")
const Instr = preload("res://sim/instrument.gd")
const Landing = preload("res://sim/landing.gd")
const Move = preload("res://sim/move.gd")
const Stamina = preload("res://sim/stamina.gd")
const TapeLib = preload("res://sim/tape.gd")
const Walls = preload("res://sim/walls.gd")
const M = preload("res://sim/jsmath.gd")
const HostRules = preload("res://net/host_rules.gd")
const PoseLib = preload("res://net/pose.gd")

const ME := "me"
## src/game/player.ts
const EYE_HEIGHT := 1.65
const PLAYER_RADIUS := 0.3
## The door-hold button inside the car, car-local (src/render/elevator.ts HOLD_BUTTON; main.ts nearHoldButton).
const HOLD_BUTTON_V := 0.84
## Most run ticks one frame may run (a test's time scale), so a stall never freezes the page.
const MAX_TICKS_PER_FRAME := 400
## src/net/session.ts TICK (1 / TICK_HZ).
const TICK := 1.0 / 20.0

## "gdscript" once open, "" when not connected.
var mode := ""
var error := ""
## The floor being played: the plan as the rules built it, plus edges, the car and the walking
## distance from the lift (planDump).
var plan: Dictionary = {}
## The newest snapshot (see step()).
var state: Dictionary = {}
## Milliseconds the last call took.
var last_ms := 0.0

var _rules: HostRules = HostRules.new(true, 1)
var _run: Run.RunState = null
var _body: Move.Body = Move.Body.make(0.0, 0.0, 0, 0.0)
var _stamina: Stamina.Stamina = Stamina.fresh_stamina()
var _gait: StringName = &"walk"
var _speed := 0.0
var _acc := 0.0
var _pending_call := false
var _pending_pick := false
var _prev_pose: Variant = null  # Dictionary or null
var _cur_pose: Variant = null
var _drawn: Variant = null
var _frozen := false
var _auto: Follow.PathWalk = null
var _auto_stuck := 0.0
var _auto_pace := 0.0
var _auto_status := "idle"
var _plan_depth := -1
var _ticks := 0
var _seed := "alpha"
## session.ts carFor: the car of a plan, built once.
var _car_plan: Floor.FloorPlan = null
var _car_of_plan: Run.CarGeometry = null

func open() -> bool:
	mode = "gdscript"
	return true

func close() -> void:
	mode = ""

# --- the calls ------------------------------------------------------------------------------------

## A new run. Returns the first snapshot, with `plan` and `placed` (where the player stands, and yaw).
func start(seed: String, depth := 1, entity := true) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	_seed = seed
	_rules = HostRules.new(entity, maxi(1, floori(float(depth))))
	var ids: Array[String] = [ME]
	var s := _rules.prepare(Run.create_run(seed, ids))
	_run = s
	_body = s.players[0].body if not s.players.is_empty() else HostRules.start_body(s.car, 0, 1)
	_stamina = Stamina.fresh_stamina()
	_gait = &"walk"
	_speed = 0.0
	_acc = 0.0
	_pending_call = false
	_pending_pick = false
	_reset_orderly()
	_auto = null
	_auto_status = "idle"
	_ticks = 0
	_plan_depth = -1
	var face := _want_dir(Landing.landing_facing(s.plan))
	var snap := _snapshot([], face, 0.0, 100.0, 70.0)
	var placed := _body_plain(_body)
	placed["yaw"] = face
	snap["placed"] = placed
	last_ms = (Time.get_ticks_usec() - t0) / 1000.0
	return _take(snap)

## One frame. `input`: dt, f, r (walk wish -1..1), sprint, creep, yaw, pitch, hfov, vfov (camera,
## radians/degrees), raised, call, hold, pickUp, still, timeScale. Returns the snapshot:
##   t, depth, phase, timer, bellLeft, holdLeft, held, call{floorsAway,floors,falseStop,eta,darks},
##   blink{at,len,warn,blackout,announced,on}, dark, blackout, warn, doorsOpen,
##   me{x,y,z,level,eye,status,aboard,side,standing,gait,speed,stamina,winded,exertion,canCall,nearHold},
##   orderly{pose{x,y,z,level,yaw,anim,animTime}, visible, seeing, held, mode, moving, speed, squeak{gain,muffled}},
##   inst{raised,needle,value,rate,tickHz,loudness,distance}, tapes{count,value}, floorTapes, votes{bank,down},
##   summary, events[], placed (the rules moved the player: adopt this body), autoYaw, plan (on a new floor).
func step(input: Dictionary) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var d := _frame(input)
	last_ms = (Time.get_ticks_usec() - t0) / 1000.0
	return _take(d)

func _take(d: Dictionary) -> Dictionary:
	if d.has("plan"):
		plan = d["plan"]
	if not d.has("error"):
		state = d
	return d

# --- test hooks (the scripted playthrough) ------------------------------------------------------

func teleport(level: int, x: int, y: int) -> Dictionary:
	if _run == null:
		return _no_run()
	_body = Move.body_at_cell(_run.plan, Floor.Pos.make(level, x, y))
	_auto = null
	_auto_status = "idle"
	return {"ok": true, "placed": _body_plain(_body)}

## Moves the player by (dx, dz) metres with the rules' own collision (Run.move_in_run).
func nudge(dx: float, dz: float) -> Dictionary:
	if _run == null:
		return _no_run()
	_body = Run.move_in_run(_run, _body, dx, dz, PLAYER_RADIUS)
	return {"ok": true, "body": _body_plain(_body)}

## Walks the player along the rules' own path to a cell, with the rules' collision.
func walk_to(level: int, x: int, y: int, pace := 3.0) -> Dictionary:
	if _run == null:
		return _no_run()
	var from := Move.cell_of(_run.plan, _body)
	var path := Floor.find_path(_run.plan, from, Floor.Pos.make(level, x, y))
	if path.is_empty():
		_auto_status = "failed: no path"
		return {"ok": false}
	_auto = Follow.start_path_walk(path)
	_auto_stuck = 0.0
	_auto_pace = pace
	_auto_status = "walking"
	return {"ok": true, "cells": path.size()}

func stop_walk() -> Dictionary:
	_auto = null
	_auto_status = "idle"
	return {"ok": true}

func debug_info() -> Dictionary:
	if _run == null:
		return _no_run()
	var s := _run
	var blink_v: Variant = null
	if s.blink != null:
		var b := s.blink
		blink_v = {"callIndex": b.call_index, "n": b.n, "at": b.at, "len": b.len, "warn": b.warn, "blackout": b.blackout, "announced": b.announced, "endsAt": b.ends_at}
	var call_v: Variant = null
	if s.call != null:
		var c := s.call
		var darks: Array = []
		for dk in c.plan.darks:
			darks.append({"at": dk.at, "len": dk.len, "warn": dk.warn, "blackout": dk.blackout})
		call_v = {"index": c.index, "at": c.at, "plan": {"delay": c.plan.delay, "floors": c.plan.floors, "falseStop": c.plan.false_stop,
			"extra": c.plan.extra, "wait": c.plan.wait, "darks": darks}, "floorsAway": c.floors_away, "nextAt": c.next_at,
			"stopUntil": c.stop_until, "stopDoorsOpened": c.stop_doors_opened, "stopDoorsClosed": c.stop_doors_closed}
	return {"orderly": _orderly_plain(s.orderly), "phase": String(s.phase), "t": s.t, "blink": blink_v, "call": call_v, "ticks": _ticks, "body": _body_plain(_body)}

func _no_run() -> Dictionary:
	push_error("rules: no run: send start first")
	return {"error": "no run: send start first"}

# --- the frame ------------------------------------------------------------------------------------

static func _num(v: Variant, fallback: float = 0.0) -> float:
	if v is float or v is int:
		var f := float(v)
		return fallback if is_nan(f) else f
	if v is bool:
		return 1.0 if v else 0.0
	return fallback

static func _want_dir(d: StringName) -> float:
	# yawForDir in src/game/player.ts
	match d:
		&"w":
			return PI / 2.0
		&"s":
			return PI
		&"e":
			return -PI / 2.0
	return 0.0

func _reset_orderly() -> void:
	_cur_pose = PoseLib.pose_of(_run.orderly) if _run != null else null
	_prev_pose = _cur_pose
	_drawn = null
	_frozen = false

func _camera(yaw: float, pitch: float, hfov: float, vfov: float) -> PoseLib.Camera:
	return PoseLib.Camera.make(Move.Body.make(_body.x, _body.z, _body.level, _body.y), EYE_HEIGHT, yaw, pitch, hfov, vfov)

func _frame(inp: Dictionary) -> Dictionary:
	if _run == null:
		return _no_run()
	var s := _run
	var dt := maxf(0.0, minf(0.1, _num(inp.get("dt"))))
	var still: bool = inp.get("still") == true
	var playing := not still and s.phase != &"ended"
	if inp.get("call") == true:
		_pending_call = true
	if inp.get("pickUp") == true:
		_pending_pick = true
	var in_yaw := _num(inp.get("yaw"))
	var in_pitch := _num(inp.get("pitch"))
	var in_hfov := _num(inp.get("hfov"))
	var in_vfov := _num(inp.get("vfov"))

	# The instrument answers at once (the walk cap and the drawing follow on this frame), as on the host's page.
	var want_raised: bool = playing and inp.get("raised") == true
	var m0 := Instr.member(s.crew, ME)
	if m0 != null and m0.instrument.raised != want_raised:
		s = s.copy()
		s.crew = Instr.set_raised(s.crew, ME, want_raised)
		_run = s
	var m1 := Instr.member(s.crew, ME)
	var raised := m1.instrument.raised if m1 != null else false

	# 1. Walking (src/game/player.ts control), or the test's auto-walk.
	var placed_yaw: Variant = null
	var before := _body
	_speed = 0.0
	if _auto != null and playing:
		var step_len := _auto_pace * dt
		if Follow.path_done(s.plan, _auto, _body):
			_auto = null
			_auto_status = "done"
		else:
			var b0 := _body
			_body = Follow.step_path_walk(s.plan, _auto, b0, step_len, PLAYER_RADIUS)
			var mx := _body.x - b0.x
			var mz := _body.z - b0.z
			if M.hypot2(mx, mz) > 1e-4:
				placed_yaw = M.atan2_js(-mx, -mz)
				_auto_stuck = 0.0
			else:
				_auto_stuck += dt
				if _auto_stuck > 3.0:
					_auto = null
					_auto_status = "failed: stuck"
		_gait = &"walk"
		_speed = M.hypot2(_body.x - before.x, _body.z - before.z) / dt if dt > 0.0 else 0.0
	else:
		var f := maxf(-1.0, minf(1.0, _num(inp.get("f")))) if playing else 0.0
		var r := maxf(-1.0, minf(1.0, _num(inp.get("r")))) if playing else 0.0
		var moving := f != 0.0 or r != 0.0
		var cap := Instr.max_walk_speed(true, Stamina.WALK_SPEED) if raised else INF
		_gait = Stamina.gait_for(_stamina, inp.get("sprint") == true, inp.get("creep") == true, moving, cap)
		if moving:
			var wl := M.hypot2(f, r)
			var nf := f / maxf(1.0, wl)
			var nr := r / maxf(1.0, wl)
			var speed := Stamina.speed_for(&"sprint", cap) if _gait == &"sprint" else minf(cap, Stamina.speed_for(_gait))
			var sn := M.sin_js(in_yaw)
			var cs := M.cos_js(in_yaw)
			var dx := (-sn * nf + cs * nr) * speed * dt
			var dz := (-cs * nf - sn * nr) * speed * dt
			_body = Run.move_in_run(s, _body, dx, dz, PLAYER_RADIUS)
			_speed = speed
	var moved := M.hypot2(_body.x - before.x, _body.z - before.z)
	_stamina = Stamina.step_stamina(_stamina, _gait, moved / dt if dt > 0.0 else 0.0, dt)

	# 2. The run's ticks that are due.
	var scale_in := _num(inp.get("timeScale", 1.0), 1.0)
	var scale := maxf(0.0, scale_in if scale_in != 0.0 else 1.0)
	_acc += dt * scale
	var events: Array = []
	var placed: Variant = null
	var cam_yaw: float = placed_yaw if placed_yaw != null else in_yaw
	var n := 0
	while _acc >= TICK - 1e-9 and n < MAX_TICKS_PER_FRAME:
		n += 1
		_acc -= TICK
		var input := Run.PlayerInput.make(ME, Move.Body.make(_body.x, _body.z, _body.level, _body.y), EYE_HEIGHT, cam_yaw, in_pitch, in_hfov, in_vfov)
		input.raised = want_raised
		input.hold_doors = playing and inp.get("hold") == true
		input.call = _pending_call and playing
		input.pick_up = true if (_pending_pick and playing) else null
		_pending_call = false
		_pending_pick = false
		var depth_before := _run.depth
		var inputs: Array[Run.PlayerInput] = [input]
		var res := _rules.step(_run, inputs, TICK)
		_run = res.state
		_ticks += 1
		for e in res.events:
			events.append(_plain(e))
		# The run moved the player: a ride, being put out of the car, a catch turned into a placeholder.
		for e in res.events:
			if e["type"] == "rodeDown":
				var bodies: Dictionary = e["bodies"]
				if bodies.has(ME):
					placed = _body_plain(bodies[ME])
			if e["type"] == "doorsClosed":
				var out: Dictionary = e["pushedOut"]
				if out.has(ME):
					placed = _body_plain(out[ME])
		var revived := _rules.revived.duplicate()
		_rules.revived.clear()
		for id: String in revived:
			if id != ME:
				continue
			var p := _run.plan
			placed = _body_plain(Move.body_at_cell(p, p.landing))
			placed["yaw"] = _want_dir(Landing.landing_facing(p))
		if placed != null:
			var pd: Dictionary = placed
			_body = Move.Body.make(pd["x"], pd["z"], pd["level"], pd["y"])
			if _auto != null:
				_auto_status = "interrupted"
			_auto = null
		if _run.depth != depth_before:
			_reset_orderly()
		else:
			_prev_pose = _cur_pose
			_cur_pose = PoseLib.pose_of(_run.orderly)
		if _run.phase == &"ended":
			break
	var snap := _snapshot(events, cam_yaw, in_pitch, in_hfov, in_vfov)
	snap["placed"] = placed
	snap["autoYaw"] = placed_yaw
	return snap

## The Orderly as this screen draws it (src/net/client.ts frame(), for one local player).
## Returns [pose (Dictionary or null), seeing, held].
func _draw_orderly(s: Run.RunState, cam: PoseLib.Camera, dark: bool) -> Array:
	if _prev_pose == null or _cur_pose == null:
		return [null, false, false]
	var cand := PoseLib.lerp_pose(_prev_pose as Dictionary, _cur_pose as Dictionary, maxf(0.0, minf(1.0, _acc / TICK)))
	var open := Run.doors_open(s)
	var car := _car_for(s.plan)
	var seeing := false
	if _frozen and _drawn != null and not dark and PoseLib.camera_sees(s.plan, car, cam, _drawn as Dictionary, open):
		seeing = true
	elif _frozen and _drawn != null and not dark and PoseLib.camera_sees(s.plan, car, cam, cand, open):
		pass  # The held pose left the view but the new one is in it: keep holding until neither is.
	else:
		if not dark and PoseLib.camera_sees(s.plan, car, cam, cand, open):
			_frozen = true
			seeing = true
		else:
			_frozen = false
		if _drawn == null or not PoseLib.same_pose(_drawn as Dictionary, cand):
			_drawn = cand
	var pose: Variant = _drawn
	# Frozen within reach of you while hunting, it is drawn reaching (src/main.ts freezePose).
	if pose != null and _frozen:
		var pd: Dictionary = pose
		var near := M.hypot2(_body.x - float(pd["x"]), _body.z - float(pd["z"])) <= Entity.REACH_RANGE and absf(_body.y - float(pd["y"])) < 1.0
		var omode := s.orderly.mode
		if near and pd["anim"] != "reach" and (omode == &"hunting" or omode == &"windUp"):
			var np := pd.duplicate()
			np["anim"] = "reach"
			np["animTime"] = Entity.WIND_UP_TIME * 0.85
			pose = np
	return [pose, seeing, _frozen]

func _car_for(p: Floor.FloorPlan) -> Run.CarGeometry:
	if _car_plan != p:
		_car_plan = p
		_car_of_plan = Run.car_geometry(p)
	return _car_of_plan

func _snapshot(events: Array, yaw: float, pitch: float, hfov: float, vfov: float) -> Dictionary:
	var s := _run
	var car := s.car
	var me: Run.RunPlayer = null
	for p in s.players:
		if p.id == ME:
			me = p
			break
	var mem := Instr.member(s.crew, ME)
	var inst: Instr.Instrument = mem.instrument if mem != null else null
	var dark := Run.blinking(s)
	var b := s.blink
	var warn := b != null and b.announced and b.ends_at == null
	var cam := _camera(yaw, pitch, hfov, vfov)
	var o: Array = [null, false, false]
	if s.phase != &"riding" and s.phase != &"ended":
		o = _draw_orderly(s, cam, dark)
	var pose: Variant = o[0]
	var seeing: bool = o[1]
	var held: bool = o[2]
	var moving := s.orderly.moving
	var squeak := {"gain": 0.0, "muffled": false}
	if pose != null and not seeing and not held and moving:
		var drawn := s.orderly.copy()
		drawn.body = PoseLib.pose_body(pose as Dictionary)
		drawn.moving = moving
		var a := Entity.audibility(s.plan, drawn, _body, EYE_HEIGHT)
		squeak = {"gain": a.gain, "muffled": a.muffled}
	var in_car_now := Run.in_car(car, _body)
	var tapes: Array[TapeLib.Tape] = []
	if mem != null:
		tapes.append(mem.tape)
		tapes.append_array(mem.carrying)
	var local := Run.car_local(car, _body.x, _body.z)
	var c := s.call
	var call_v: Variant = null
	if c != null:
		var darks: Array = []
		for dk in c.plan.darks:
			darks.append({"at": c.at + dk.at, "len": dk.len, "warn": dk.warn, "blackout": dk.blackout})
		call_v = {"floorsAway": c.floors_away, "floors": c.plan.floors, "falseStop": c.stop_until != null,
			"eta": maxf(0.0, c.at + c.plan.wait - s.t), "darks": darks}
	var blink_v: Variant = null
	if b != null:
		blink_v = {"at": b.at, "len": b.len, "warn": b.warn, "blackout": b.blackout, "announced": b.announced, "on": b.ends_at != null, "endsAt": b.ends_at}
	var tape_count := 0
	for tp in tapes:
		if not tp.readings.is_empty():
			tape_count += 1
	var floor_tapes: Array = []
	for ft in s.crew.floor:
		floor_tapes.append({"id": ft.tape.id, "at": _body_plain(ft.at)})
	var bank := 0
	var down := 0
	for p in s.players:
		if p.side == &"bank":
			bank += 1
		elif p.side == &"down":
			down += 1
	var inst_v: Variant = null
	if inst != null:
		inst_v = {"raised": inst.raised, "needle": String(inst.needle), "value": inst.current.value if inst.current != null else 0.0,
			"rate": inst.rate, "tickHz": inst.tick_hz, "loudness": inst.loudness, "distance": inst.distance}
	var out := {
		"t": s.t,
		"seed": _seed,
		"depth": s.depth,
		"multiplier": Run.depth_multiplier(s.depth),
		"phase": String(s.phase),
		"timer": s.timer,
		"bellLeft": s.bell_left,
		"holdLeft": s.hold_left,
		"held": s.held,
		"calls": s.calls,
		"call": call_v,
		"blink": blink_v,
		"dark": dark,
		"blackout": Run.blacked_out(s),
		"warn": warn,
		"doorsOpen": Run.doors_open(s),
		"me": {
			"x": _body.x,
			"y": _body.y,
			"z": _body.z,
			"level": _body.level,
			"eye": EYE_HEIGHT,
			"status": String(me.status) if me != null else "ok",
			"aboard": in_car_now,
			"side": _str_or_null(me.side) if me != null else null,
			"standing": _str_or_null(Run.car_side(car, _body)),
			"gait": String(_gait),
			"speed": _speed,
			"stamina": _stamina.level,
			"winded": _stamina.winded,
			"exertion": Stamina.exertion(_stamina),
			"canCall": s.phase == &"away" and _body.level == car.level and not in_car_now and M.hypot2(_body.x - car.door_x, _body.z - car.door_z) <= Run.CALL_REACH - 0.05,
			"nearHold": s.phase == &"boarding" and in_car_now and M.hypot2(local[0] - 0.3, local[1] - HOLD_BUTTON_V) <= 0.75,
			"cell": Floor.pos_plain(Move.cell_of(s.plan, _body)),
		},
		"orderly": {
			"pose": (pose as Dictionary).duplicate() if pose != null else null,
			"visible": pose != null and not dark,
			"seeing": seeing,
			"held": held,
			"mode": String(s.orderly.mode),
			"frozen": s.orderly.frozen,
			"moving": moving,
			"speed": s.orderly.speed,
			"x": s.orderly.body.x,
			"z": s.orderly.body.z,
			"level": s.orderly.body.level,
			"squeak": squeak,
			"distance": M.hypot2(_body.x - s.orderly.body.x, _body.z - s.orderly.body.z),
		},
		"inst": inst_v,
		"tapes": {"count": tape_count, "value": TapeLib.tape_value(tapes)},
		"floorTapes": floor_tapes,
		"votes": {"bank": bank, "down": down},
		"summary": _summary_plain(s.summary),
		"events": events,
		"auto": _auto_status,
		"ticks": _ticks,
	}
	if s.depth != _plan_depth:
		_plan_depth = s.depth
		out["plan"] = _plan_dump(s)
	return out

## The floor as the client builds it: the plan itself plus what it needs and must not compute.
static func _plan_dump(s: Run.RunState) -> Dictionary:
	var p := s.plan
	var w := p.width
	var h := p.height
	var edges: Array = []
	for level in 2:
		var vertical: Array = []
		for y in h:
			for x in w + 1:
				vertical.append(String(Walls.west_edge(p, level, x, y)))
		var horizontal: Array = []
		for y in h + 1:
			for x in w:
				horizontal.append(String(Walls.north_edge(p, level, x, y)))
		edges.append({"vertical": vertical, "horizontal": horizontal})
	# Walking distance (cells) from the landing to every position, -1 where unreachable: the client's
	# clean-to-corrupted gradient.
	var lift_dist: Array = []
	for v: int in Floor.distances_from(p, p.landing):
		lift_dist.append(v)
	var out := Floor.plan_to_plain(p)
	out["edges"] = edges
	var wall := Landing.elevator_wall(p)
	out["elevatorWall"] = null if wall == &"" else String(wall)
	out["landingFacing"] = String(Landing.landing_facing(p))
	out["car"] = _car_plain(s.car)
	out["liftDist"] = lift_dist
	return out

# --- plain data (what JSON from the TypeScript host gave the client) -----------------------------

static func _str_or_null(v: Variant) -> Variant:
	if v == null:
		return null
	return String(v)

static func _body_plain(b: Move.Body) -> Dictionary:
	return {"x": b.x, "z": b.z, "y": b.y, "level": b.level}

static func _rect_plain(r: Run.Rect) -> Dictionary:
	return {"x0": r.x0, "z0": r.z0, "x1": r.x1, "z1": r.z1}

static func _car_plain(c: Run.CarGeometry) -> Dictionary:
	return {"wall": String(c.wall), "level": c.level, "floorY": c.floor_y, "doorX": c.door_x, "doorZ": c.door_z, "inX": c.in_x, "inZ": c.in_z,
		"rightX": c.right_x, "rightZ": c.right_z, "width": c.width, "depth": c.depth, "doorWidth": c.door_width,
		"rect": _rect_plain(c.rect), "bank": _rect_plain(c.bank), "down": _rect_plain(c.down)}

static func _summary_plain(sm: Run.RunSummary) -> Variant:
	if sm == null:
		return null
	var tapes: Array = []
	for t in sm.tapes:
		tapes.append(t)
	return {"depth": sm.depth, "readings": sm.readings, "total": sm.total, "shares": sm.shares.duplicate(), "tapes": tapes, "wiped": sm.wiped}

static func _reading_plain(r: TapeLib.Reading) -> Dictionary:
	return {"id": r.id, "playerId": r.player_id, "entityId": r.entity_id, "trait": String(r.trait_name), "value": r.value,
		"duration": r.duration, "peakRate": r.peak_rate, "closedAt": r.closed_at}

static func _orderly_plain(o: Entity.OrderlyState) -> Dictionary:
	var path: Variant = null
	if not o.path.is_empty():
		var pa: Array = []
		for q in o.path:
			pa.append(Floor.pos_plain(q))
		path = pa
	return {
		"t": o.t, "body": _body_plain(o.body), "yaw": o.yaw, "mode": String(o.mode), "anim": String(o.anim), "animTime": o.anim_time,
		"seen": o.seen, "held": o.held, "frozen": o.frozen, "moving": o.moving, "everSeen": o.ever_seen, "seenTotal": o.seen_total,
		"lastSeenAt": o.last_seen_at, "targetId": o.target_id, "speed": o.speed, "preySpeed": o.prey_speed, "preyX": o.prey_x,
		"preyZ": o.prey_z, "preyId": o.prey_id, "path": path, "pathNext": o.path_next, "replanIn": o.replan_in,
		"windUpLeft": o.wind_up_left, "windUpTarget": o.wind_up_target, "dormantLeft": _finite_or_null(o.dormant_left),
	}

## JSON has no Infinity: JSON.stringify writes null.
static func _finite_or_null(f: float) -> Variant:
	return f if is_finite(f) else null

## An event (or anything inside one) as plain data: bodies, readings and summaries become dictionaries.
static func _plain(v: Variant) -> Variant:
	if v is StringName:
		return String(v)
	if v is float:
		return _finite_or_null(v)
	if v is Move.Body:
		return _body_plain(v)
	if v is TapeLib.Reading:
		return _reading_plain(v)
	if v is Run.RunSummary:
		return _summary_plain(v)
	if v is Array:
		var out: Array = []
		for x: Variant in v:
			out.append(_plain(x))
		return out
	if v is Dictionary:
		var d: Dictionary = v
		var out := {}
		for k: Variant in d:
			out[k] = _plain(d[k])
		return out
	return v
