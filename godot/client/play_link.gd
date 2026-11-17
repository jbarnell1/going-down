# The game's one way to play, alone or with friends: the network client. Playing alone is a room on
# this machine (net/local_room.gd: the server's own host code over in-memory pipes); playing together
# is net/room_client.gd over a WebSocket. Both are a RoomClient, and this file is the only client
# script that talks to it. The rules run in exactly one place: the host.
#
# Per frame (step), like the network README's example:
#   rc.poll -> move the player's own body with the rules (net/session.gd move_local, the stamina rules'
#   gait and speed, the instrument's walk cap: instant, the host checks it) -> rc.frame with the REAL
#   camera and fields of view -> one snapshot Dictionary for main.gd with the names the single-player
#   bridge used (phase, me, orderly, inst, tapes, events, plan, ...), built from the frame
#   (`f.orderly`, `f.visible`, `f.dark`: drawn exactly as given), `client.latest` and `client.events`.
# Everything rule-like here is read-only geometry the client needs to draw and to move its own body:
# whether a call button is in reach, which half of the car you stand on, the squeak's audibility from
# where the Orderly is DRAWN. The run itself is never stepped here.
extends RefCounted

const RoomClient = preload("res://net/room_client.gd")
const LocalRoom = preload("res://net/local_room.gd")
const Client = preload("res://net/client.gd")
const Session = preload("res://net/session.gd")
const Pose = preload("res://net/pose.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const Run = preload("res://sim/run.gd")
const Entity = preload("res://sim/entity.gd")
const Floor = preload("res://sim/floor.gd")
const Follow = preload("res://sim/follow.gd")
const Instr = preload("res://sim/instrument.gd")
const Landing = preload("res://sim/landing.gd")
const Move = preload("res://sim/move.gd")
const Sight = preload("res://sim/sight.gd")
const Stamina = preload("res://sim/stamina.gd")
const M = preload("res://sim/jsmath.gd")
const EyeHeight = preload("res://client/eye_height.gd")

const PLAYER_RADIUS := 0.3
## The door-hold button inside the car, car-local (src/render/elevator.ts HOLD_BUTTON; main.ts nearHoldButton).
const HOLD_BUTTON_V := 0.84
## Where a spectator's camera stands until the host admits them (car-local u).
const WATCH_U := 1.45

var rc: RoomClient
var local := false
## The player's own body (null until the host places it), their tank, gait and speed this frame.
var body: Move.Body = null
var tank: Stamina.Stamina = Stamina.fresh_stamina()
var gait: StringName = &"walk"
var speed := 0.0
## The eyes' height above the feet this frame (eye_height.gd: standing, creeping, down, eased). The
## camera is drawn from it (snapshot `me.eye`, camera_point) and the client's frame carries the same
## number to the rules, so what counts as looking is what the screen shows.
var eye := EyeHeight.STAND
var _eye := EyeHeight.new()
## The floor the player is on, and its dump (built once per floor).
var plan: Floor.FloorPlan = null
var car: Run.CarGeometry = null
var plan_dict: Dictionary = {}
var plan_depth := -1
## Milliseconds the last step took (poll, the player's move, the client's frame, the snapshot), and
## the newest frame.
var last_ms := 0.0
var frame: Client.Frame = null
## Test hook: walking along the rules' own path.
var auto_status := "idle"
## Counts per run of what this screen showed (tests): frames on which it saw the Orderly on two frames
## running, and those of them on which the drawn pose changed (must stay 0).
var watched_pairs := 0
var watched_moves := 0
var _client: Client = null
var _ev_index := 0
var _em_index := 0
var _face_on_place := false
var _call_floors := 0
var _false_stop := false
var _auto: Follow.PathWalk = null
var _auto_stuck := 0.0
var _auto_pace := 0.0
var _orderly_tpl: Entity.OrderlyState = null
var _prev_seeing := false
var _prev_pose: Variant = null

func _init(room: RoomClient, is_local: bool) -> void:
	rc = room
	local = is_local

## The NetClient of the run being played (null in the lobby).
func client() -> Client:
	return rc.client

func my_id() -> String:
	return str(rc.client.id) if rc.client != null and rc.client.id != null else rc.my_id

## Names by player id, from the room.
func names() -> Dictionary:
	var out := {}
	for p: Variant in rc.people:
		if p is Array and (p as Array).size() >= 2:
			out[str(p[0])] = str(p[1])
	return out

# --- the frame ------------------------------------------------------------------------------------

## One frame. `inp` as the bridge took it: dt, f, r, sprint, creep, yaw, pitch, hfov, vfov, raised,
## call, hold, pickUp, still. Returns {} while there is no run (lobby, connecting, closed), {"waiting":
## true} until the run's welcome has come, else the snapshot (see the file header).
func step(now: float, inp: Dictionary) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	rc.poll(now)
	var c := rc.client
	if c == null:
		_client = null
		last_ms = (Time.get_ticks_usec() - t0) / 1000.0
		return {}
	if c != _client:
		_new_run(c)
	if c.seed == null or c.latest == null:
		rc.frame(now, _idle_frame())
		last_ms = (Time.get_ticks_usec() - t0) / 1000.0
		return {"waiting": true}
	var latest: Dictionary = c.latest
	_use_floor(str(c.seed), c.local_depth)
	var phase := str(latest["phase"])
	var me_row: Variant = _row(latest, str(c.id))
	var status := str(me_row["status"]) if me_row != null else "ok"
	var dt := clampf(float(inp.get("dt", 0.0)), 0.0, 0.1)
	var still: bool = inp.get("still") == true
	var playing := c.playing and body != null and not still and phase != "ended" and status == "ok"
	var in_yaw := float(inp.get("yaw", 0.0))
	var in_pitch := float(inp.get("pitch", 0.0))
	var want_raised: bool = playing and inp.get("raised") == true

	# 1. The player's own body (src/game/player.ts control), or the test's auto-walk.
	tank = c.correct_stamina(tank)
	var placed_yaw: Variant = null
	speed = 0.0
	var before := body
	if playing and _auto != null:
		var b0 := body
		if Follow.path_done(plan, _auto, body):
			_auto = null
			auto_status = "done"
		else:
			body = Follow.step_path_walk(plan, _auto, b0, _auto_pace * dt, PLAYER_RADIUS)
			var mx := body.x - b0.x
			var mz := body.z - b0.z
			if M.hypot2(mx, mz) > 1e-4:
				placed_yaw = M.atan2_js(-mx, -mz)
				_auto_stuck = 0.0
			else:
				_auto_stuck += dt
				if _auto_stuck > 3.0:
					_auto = null
					auto_status = "failed: stuck"
		gait = &"walk"
		speed = M.hypot2(body.x - b0.x, body.z - b0.z) / dt if dt > 0.0 else 0.0
	elif body != null:
		var fw := clampf(float(inp.get("f", 0.0)), -1.0, 1.0) if playing else 0.0
		var rt := clampf(float(inp.get("r", 0.0)), -1.0, 1.0) if playing else 0.0
		var moving := fw != 0.0 or rt != 0.0
		var cap := Instr.max_walk_speed(true, Stamina.WALK_SPEED) if want_raised else INF
		gait = Stamina.gait_for(tank, inp.get("sprint") == true, inp.get("creep") == true, moving, cap)
		if moving:
			var wl := M.hypot2(fw, rt)
			var nf := fw / maxf(1.0, wl)
			var nr := rt / maxf(1.0, wl)
			var sp := Stamina.speed_for(&"sprint", cap) if gait == &"sprint" else minf(cap, Stamina.speed_for(gait))
			var sn := M.sin_js(in_yaw)
			var cs := M.cos_js(in_yaw)
			body = Session.move_local(plan, phase, body, (-sn * nf + cs * nr) * sp * dt, (-cs * nf - sn * nr) * sp * dt, PLAYER_RADIUS)
			speed = sp
	if before != null and body != null and dt > 0.0:
		tank = Stamina.step_stamina(tank, gait, M.hypot2(body.x - before.x, body.z - before.z) / dt, dt)
	# The eyes: standing, creeping or down (a spectator stands), eased; this frame's camera height.
	eye = _eye.update(EyeHeight.target(status, String(gait)) if body != null else EyeHeight.STAND, dt)

	# 2. The client's frame: the real camera (drawn from this same eye), the intents.
	var cam_yaw: float = placed_yaw if placed_yaw != null else in_yaw
	var lf := Client.LocalFrame.new()
	lf.body = body if body != null else _watch_body()
	lf.eye = eye
	lf.yaw = cam_yaw
	lf.pitch = in_pitch
	lf.h_fov_deg = float(inp.get("hfov", 90.0))
	lf.v_fov_deg = float(inp.get("vfov", 70.0))
	lf.raised = want_raised
	lf.hold_doors = playing and inp.get("hold") == true
	lf.gait = String(gait)
	lf.call = playing and inp.get("call") == true
	lf.pick_up = playing and inp.get("pickUp") == true
	lf.stamina = tank if body != null else null
	var f := rc.frame(now, lf)
	frame = f
	var placed: Variant = null
	if f.placed != null:
		body = f.placed
		placed = _body_plain(body)
		if _face_on_place:
			_face_on_place = false
			placed["yaw"] = _want_dir(Landing.landing_facing(Session.plan_for(str(c.seed), c.local_depth)))
		if _auto != null:
			auto_status = "interrupted"
		_auto = null
		_use_floor(str(c.seed), c.local_depth)
	# What this screen showed (the fairness rule, counted for the tests).
	if f.seeing and _prev_seeing and f.orderly != null and _prev_pose != null:
		watched_pairs += 1
		if not Pose.same_pose(f.orderly, _prev_pose):
			watched_moves += 1
	_prev_seeing = f.seeing
	_prev_pose = f.orderly

	# 3. What to draw and play.
	var snap := _snapshot(c, f, latest, me_row, phase, want_raised)
	snap["placed"] = placed
	snap["autoYaw"] = placed_yaw
	if plan_dict.has("_new"):
		plan_dict.erase("_new")
		snap["plan"] = plan_dict
	last_ms = (Time.get_ticks_usec() - t0) / 1000.0
	return snap

func _new_run(c: Client) -> void:
	_client = c
	_ev_index = 0
	_em_index = 0
	body = null
	tank = Stamina.fresh_stamina()
	gait = &"walk"
	speed = 0.0
	_eye.reset()
	eye = _eye.eye
	_face_on_place = true
	_call_floors = 0
	_false_stop = false
	_auto = null
	auto_status = "idle"
	plan_depth = -1
	watched_pairs = 0
	watched_moves = 0
	_prev_seeing = false
	_prev_pose = null

func _use_floor(seed: String, depth: int) -> void:
	var p := Session.plan_for(seed, depth)
	if p == plan and depth == plan_depth:
		return
	plan = p
	car = Session.car_for(p)
	plan_depth = depth
	plan_dict = PlanDump.dump(p, car)
	plan_dict["_new"] = true
	_orderly_tpl = Entity.create_orderly(p)

func _idle_frame() -> Client.LocalFrame:
	var lf := Client.LocalFrame.new()
	lf.body = Move.Body.make(0.0, 0.0, 0, 0.0)
	return lf

## Where a spectator's camera stands: inside the car.
func _watch_body() -> Move.Body:
	return Run.car_body(car, WATCH_U, 0.0)

## The camera's body: the player's own, or the spectator's spot.
func view_body() -> Move.Body:
	if body != null:
		return body
	return _watch_body() if car != null else Move.Body.make(0.0, 0.0, 0, 0.0)

static func _row(latest: Dictionary, id: String) -> Variant:
	for p: Dictionary in latest["players"]:
		if p["id"] == id:
			return p
	return null

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

static func _body_plain(b: Move.Body) -> Dictionary:
	return {"x": b.x, "z": b.z, "y": b.y, "level": b.level}

## Loudness of the instrument's ticking from what the snapshot carries (instrument.gd _set_ticking).
static func _loudness(open: float, tick_hz: float) -> float:
	if open > 0.0:
		var k := clampf((tick_hz - Instr.TICK_MIN_HZ) / (Instr.TICK_MAX_HZ - Instr.TICK_MIN_HZ), 0.0, 1.0)
		return Instr.LOUDNESS_MIN + (Instr.LOUDNESS_MAX - Instr.LOUDNESS_MIN) * k
	return Instr.LOUDNESS_REST if tick_hz > 0.0 else 0.0

func _snapshot(c: Client, f: Client.Frame, latest: Dictionary, me_row: Variant, phase: String, want_raised: bool) -> Dictionary:
	var vb := view_body()
	var mid := str(c.id)
	# Events, each once.
	var events: Array = []
	while _ev_index < c.events.size():
		var e: Dictionary = c.events[_ev_index]
		_ev_index += 1
		events.append(e)
		match str(e.get("type", "")):
			"called":
				_call_floors = int(e.get("floorsAway", 0))
				_false_stop = false
			"falseStop":
				_false_stop = true
			"indicator", "carArrived":
				_false_stop = false
	var emotes: Array = []
	while _em_index < c.emotes.size():
		emotes.append(c.emotes[_em_index])
		_em_index += 1
	var b: Variant = latest["blink"]
	var blink_v: Variant = null
	var warn := false
	var blackout := false
	if b != null:
		var bd: Dictionary = b
		blink_v = {"at": bd["at"], "len": bd["len"], "warn": bd["warn"], "blackout": bd["blackout"], "announced": bd["announced"],
			"on": bd["endsAt"] != null, "endsAt": bd["endsAt"]}
		warn = bool(bd["announced"]) and bd["endsAt"] == null
		blackout = bd["endsAt"] != null and bool(bd["blackout"])
	var call_v: Variant = null
	if latest["floorsAway"] != null:
		call_v = {"floorsAway": latest["floorsAway"], "floors": maxi(_call_floors, int(latest["floorsAway"])), "falseStop": _false_stop}
	# The Orderly: exactly the frame's pose (held while seen), never drawn on a dark frame.
	var lo: Dictionary = latest["orderly"]
	var pose: Variant = f.orderly
	var moving := float(lo["speed"]) > 0.0
	var squeak := {"gain": 0.0, "muffled": false}
	var ox := float(lo["x"])
	var oz := float(lo["z"])
	var olevel := int(lo["level"])
	if pose != null:
		var pd: Dictionary = pose
		ox = float(pd["x"])
		oz = float(pd["z"])
		olevel = int(pd["level"])
		if not f.seeing and not f.held and moving and _orderly_tpl != null:
			var drawn := _orderly_tpl.copy()
			drawn.body = Pose.pose_body(pd)
			drawn.moving = true
			var a := Entity.audibility(plan, drawn, vb, eye)
			squeak = {"gain": a.gain, "muffled": a.muffled}
	var distance := M.hypot2(vb.x - ox, vb.z - oz)
	# The instrument and the tapes.
	var mem: Variant = c.me()
	var inst_v: Variant = null
	var tape_count := 0
	var tape_value := 0.0
	if mem != null:
		var md: Dictionary = mem
		var open := float(md["open"])
		var tick_hz := float(md["tickHz"])
		var feet: Variant = null
		if pose != null:
			var pd: Dictionary = pose
			feet = M.hypot3(vb.x - float(pd["x"]), vb.y - float(pd["y"]), vb.z - float(pd["z"]))
		inst_v = {"raised": want_raised, "hostRaised": md["raised"], "needle": md["needle"], "value": open, "rate": md["rate"], "tickHz": tick_hz,
			"loudness": _loudness(open, tick_hz), "distance": feet}
		var all: Array = [md["tape"]]
		all.append_array(md["carrying"])
		for t: Dictionary in all:
			if int(t["readings"]) > 0:
				tape_count += 1
			tape_value += float(t["total"])
	var floor_tapes: Array = []
	for ft: Dictionary in latest["floor"]:
		floor_tapes.append({"id": ft["id"], "at": _body_plain(ft["at"])})
	var bank := 0
	var down := 0
	for p: Dictionary in latest["players"]:
		if p["side"] == "bank":
			bank += 1
		elif p["side"] == "down":
			down += 1
	var in_car_now := Run.in_car(car, vb)
	var local_uv := Run.car_local(car, vb.x, vb.z)
	var standing: Variant = Run.car_side(car, vb)
	var others := _others(f, latest)
	return {
		"t": latest["ht"],
		"seed": str(c.seed),
		"depth": int(latest["depth"]),
		"localDepth": c.local_depth,
		"multiplier": Run.depth_multiplier(int(latest["depth"])),
		"phase": phase,
		"timer": latest["timer"],
		"bellLeft": latest["bellLeft"],
		"holdLeft": latest["holdLeft"],
		"held": latest["held"],
		"call": call_v,
		"blink": blink_v,
		"dark": f.dark,
		"blackout": blackout,
		"warn": warn,
		"doorsOpen": Session.doors_open_in(phase),
		"playing": c.playing,
		"me": {
			"id": mid,
			"x": vb.x, "y": vb.y, "z": vb.z, "level": vb.level, "eye": eye,
			"status": str(me_row["status"]) if me_row != null else "ok",
			"aboard": in_car_now,
			"side": me_row["side"] if me_row != null else null,
			"standing": String(standing) if standing != null else null,
			"gait": String(gait),
			"speed": speed,
			"stamina": tank.level,
			"winded": tank.winded,
			"exertion": Stamina.exertion(tank),
			"canCall": phase == "away" and body != null and vb.level == car.level and not in_car_now and M.hypot2(vb.x - car.door_x, vb.z - car.door_z) <= Run.CALL_REACH - 0.05,
			"nearHold": phase == "boarding" and in_car_now and M.hypot2(local_uv[0] - 0.3, local_uv[1] - HOLD_BUTTON_V) <= 0.75,
			"cell": Floor.pos_plain(Move.cell_of(plan, vb)),
		},
		"orderly": {
			"pose": (pose as Dictionary).duplicate() if pose != null else null,
			"visible": f.visible,
			"seeing": f.seeing,
			"held": f.held,
			"taken": f.taken,
			"mode": lo["mode"],
			"frozen": lo["frozen"],
			"moving": moving,
			"speed": lo["speed"],
			"x": ox,
			"z": oz,
			"level": olevel,
			"squeak": squeak,
			"distance": distance,
		},
		"inst": inst_v,
		"tapes": {"count": tape_count, "value": tape_value},
		"floorTapes": floor_tapes,
		"votes": {"bank": bank, "down": down},
		"summary": latest["summary"],
		"events": events,
		"emotes": emotes,
		"others": others,
		"auto": auto_status,
	}

## Everyone else, interpolated by the client: what to draw for each.
func _others(f: Client.Frame, latest: Dictionary) -> Array:
	var order := {}
	var i := 0
	for p: Dictionary in latest["players"]:
		order[p["id"]] = i
		i += 1
	var raised := {}
	for m: Dictionary in latest["crew"]:
		raised[m["id"]] = m["raised"]
	var nm := names()
	var faces: Dictionary = rc.client.faces if rc.client != null else {}
	var out: Array = []
	for p: Dictionary in f.players:
		var id := str(p["id"])
		var b: Move.Body = p["body"]
		out.append({"id": id, "name": nm.get(id, id), "index": int(order.get(id, 0)), "x": b.x, "y": b.y, "z": b.z, "level": b.level,
			"yaw": p["yaw"], "pitch": p["pitch"], "gait": p["gait"], "status": p["status"], "active": p["active"],
			"raised": bool(raised.get(id, false)), "face": str(faces.get(id, ""))})
	return out

## Every crewmate's face in the run's player order, this player's own included (FaceCodec text, ""
## for one who sent none): what the lift's monitor shows.
func crew_faces() -> Array[String]:
	var out: Array[String] = []
	var c := rc.client
	if c == null or c.latest == null:
		return out
	for p: Dictionary in c.latest["players"]:
		var id := str(p["id"])
		out.append(c.face if id == str(c.id) else str(c.faces.get(id, "")))
	return out

## Where the camera is drawn from, for a snapshot's `me`: the feet raised by this frame's eye height.
## main.gd places the camera here; it is the eye point of the client's frame (what the rules are sent).
static func camera_point(me: Dictionary) -> Vector3:
	return Vector3(float(me["x"]), float(me["y"]) + float(me["eye"]), float(me["z"]))

## Whether a point can be seen from the camera through the floor's walls (the rules' own line of
## sight), and not hidden by the car's shut doors.
func can_see_point(from_body: Move.Body, to: Vector3, to_level: int, doors_open: bool) -> bool:
	if plan == null:
		return false
	var from := Sight.eye_point(from_body, eye)
	if not Sight.has_line_of_sight(plan, from, Sight.Point3.make(to.x, to.y, to.z, to_level)):
		return false
	if not doors_open:
		var tb := Move.Body.make(to.x, to.z, to_level, to.y)
		if Run.in_car(car, from_body) != Run.in_car(car, tb):
			return false
	return true

# --- test hooks -----------------------------------------------------------------------------------

## Alone only: put the player on a cell (the host trusts the local player's body).
func teleport(level: int, x: int, y: int) -> Dictionary:
	if not local or plan == null or body == null:
		return {"ok": false, "error": "teleport is for playing alone"}
	body = Move.body_at_cell(plan, Floor.Pos.make(level, x, y))
	_auto = null
	auto_status = "idle"
	rc.client.forget_orderly()
	return {"ok": true, "placed": _body_plain(body)}

## Alone only: put the player down (the host's "caught" status, which stands for being down until the
## downed-and-healed rules come) or back on their feet, with no catch played. For the camera checks.
func set_down(on: bool) -> Dictionary:
	if not local or (rc as LocalRoom).host == null:
		return {"ok": false, "error": "down is for playing alone"}
	for p in (rc as LocalRoom).host.state.players:
		if p.id == my_id():
			p.status = &"caught" if on else &"ok"
			return {"ok": true}
	return {"ok": false, "error": "not in the run"}

## Moves the player by (dx, dz) metres with the rules' own collision.
func nudge(dx: float, dz: float) -> Dictionary:
	if plan == null or body == null or rc.client == null or rc.client.latest == null:
		return {"ok": false}
	if not local and M.hypot2(dx, dz) > 0.7:
		return {"ok": false, "error": "too far for the server"}
	body = Session.move_local(plan, rc.client.latest["phase"], body, dx, dz, PLAYER_RADIUS)
	return {"ok": true, "body": _body_plain(body)}

## Walks along the rules' own path to a cell. With friends no faster than walking (the server checks).
func walk_to(level: int, x: int, y: int, pace: float) -> Dictionary:
	if plan == null or body == null:
		return {"ok": false}
	var path := Floor.find_path(plan, Move.cell_of(plan, body), Floor.Pos.make(level, x, y))
	if path.is_empty():
		auto_status = "failed: no path"
		return {"ok": false}
	_auto = Follow.start_path_walk(path)
	_auto_stuck = 0.0
	_auto_pace = pace if local else minf(pace, Stamina.WALK_SPEED * 0.95)
	auto_status = "walking"
	return {"ok": true, "cells": path.size()}

func stop_walk() -> Dictionary:
	_auto = null
	auto_status = "idle"
	return {"ok": true}

## Alone only: the host's run as it stands (the old bridge's debug hook, in part).
func debug_info() -> Dictionary:
	if not local or (rc as LocalRoom).host == null:
		return {"error": "debug is for playing alone"}
	var h := (rc as LocalRoom).host
	var o := h.state.orderly
	return {"phase": String(h.state.phase), "t": h.state.t, "tick": h.tick, "orderly": {"x": o.body.x, "z": o.body.z, "level": o.body.level,
		"mode": String(o.mode), "speed": o.speed}, "softCatches": (rc as LocalRoom).rules.soft_catches,
		"emotesRelayed": h.emotes_relayed, "emotesDropped": h.emotes_dropped}
