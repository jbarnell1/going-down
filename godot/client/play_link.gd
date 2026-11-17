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
#
# The Playroom (docs/floors/playarea.md sections 3, 4 and 9; sim/seek.gd): F at a hide's front (or in a
# hide) is a hide press (LocalFrame.hide, hide_fast with sprint held), W held in a hide is a peek. The
# body stays still while the rules hold it: getting in or out, inside, found, at the party table (the
# host places it there). Inside, the camera sits back in the hide, or leans to the gap at the hide's eye
# and turns only within the gap (`hideCam`). The snapshot carries the seek block, this player's row in
# it, the newest count event, the hide in reach; other players in hides are drawn in them (crouched,
# sunk to the hide's eye, side by side in a hide that holds several), and those at the party table sit.
#
# Down first, then out (sim/run.gd downs; T8a): down, the player's own body crawls at CRAWL_PACE (the
# rules' crawl, a little under) and nothing else they press counts; the eyes are on the floor
# (eye_height.gd). F held goes to the host for a player on their feet whenever the run has days or downs.
# The snapshot carries the host's downs block ("downs") for client/down_view.gd.
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
const Day = preload("res://sim/day.gd")
const Prison = preload("res://sim/prison.gd")
const Places = preload("res://sim/places.gd")
const Playroom = preload("res://sim/playroom.gd")
const Seek = preload("res://sim/seek.gd")
const Hides = preload("res://sim/hides.gd")

const PLAYER_RADIUS := 0.3
## The eyes of a player lying on their bunk (whole centimetres: it goes to the host as the frame's eye).
const BED_EYE := 0.8
## The door-hold button inside the car, car-local v: where client/lift.gd draws it.
const HOLD_BUTTON_V := Lift.HOLD_BUTTON.x
## Where a spectator's camera stands until the host admits them (car-local u): the middle of the car.
const WATCH_U := Run.CAR_DEPTH / 2.0
## The Playroom. Sat back in a hide: the eyes this far down from the hide's eye, and this far back from
## the inside spot (away from the gap). At the party table: the eyes of a seated player.
const SAT_DROP := 0.12
const SAT_BACK := 0.3
const SEAT_EYE := 0.95
## Seen from outside, a player in a hide is drawn crouched with the mask at the hide's eye, sunk to it
## (CREW_CROUCH_MASK: the crouched figure's mask, EyeHeight.CREEP); in the ball pit a little higher, so
## the head shows between the balls. Several in one hide sit SLOT_GAP apart.
const CREW_CROUCH_MASK := 1.13
const PIT_HEAD := 0.5
const SLOT_GAP := 0.55
## Peeking from the ball pit the camera is just over the balls' tops (the pit's eye, 0.3 m, is under them).
const PIT_PEEK_EYE := 0.47
## Peeking: how far up or down the gap lets you look.
const PEEK_PITCH := 0.35
## After F for a hide, the body waits this long at most for the host's answer before it may move.
const HIDE_WAIT := 1.0
## A downed player crawls this fast (m/s): a little under the rules' crawl speed, so the run's body follows
## the screen's exactly (sim/run.gd CRAWL_SPEED).
const CRAWL_PACE := Run.CRAWL_SPEED * 0.95

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
var _auto_gait: StringName = &"walk"
var _orderly_tpl: Entity.OrderlyState = null
var _prev_seeing := false
var _prev_pose: Variant = null
## The bunk prompt's fill: seconds F has been held on a bunk (display only: the host decides), and
## whether F must be let go first (it was held when the player got up, as the rules want).
var _bed_hold := 0.0
var _bed_release := false
## The Playroom: the floor's hides and party-table seats (pure functions of the plan; [] elsewhere).
var hides: Array[Playroom.Hide] = []
var seats: Array[Playroom.Seat] = []
## Seconds left of waiting for the host after a hide press (the body stays still meanwhile).
var _hide_wait := 0.0
var _hide_wait_phase := ""

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
## call, hold, pickUp, still, use (F held: on a prison bunk it lies you down; beside a downed crewmate it
## heals them). Down, the player crawls (f and r at CRAWL_PACE) and nothing else counts. Returns {} while there is
## no run (lobby, connecting, closed), {"waiting": true} until the run's welcome has come, else the
## snapshot (see the file header). With days the snapshot also has "day" (the host's day block),
## "hostNow" (the host clock as estimated here), "goingUp" (riding up to the prison) and "bed" (in bed,
## at a bunk, the hold prompt's fill 0..1, this player's bunk cell). With the down rule it has "downs"
## (the host's downs block: client/down_view.gd).
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
	# Down first, then out: a downed player crawls (the run follows their body at its crawl speed) and does
	# nothing else; F held goes to the host for everyone on their feet (held beside a downed crewmate, it
	# heals them).
	var downs_on: bool = latest.get("downs") != null
	var crawling := downs_on and c.playing and body != null and not still and phase != "ended" and status == "down"
	# The day loop: lying on your bunk you stay put (F gets you up: the host's call).
	var day: Variant = latest.get("day")
	var in_bed := day != null and int(latest["depth"]) == 0 and ((day as Dictionary)["inBed"] as Array).has(str(c.id))
	var in_yaw := float(inp.get("yaw", 0.0))
	var in_pitch := float(inp.get("pitch", 0.0))
	var want_raised: bool = playing and inp.get("raised") == true
	# The Playroom: this player's row in the seek block (null elsewhere), and whether the rules hold the
	# body (getting in or out of a hide, inside it, found, at the party table, down).
	var seek_row: Variant = seek_row_of(latest, str(c.id))
	var s_phase := str(seek_row["phase"]) if seek_row != null else "out"
	var s_status := str(seek_row["status"]) if seek_row != null else "ok"
	if _hide_wait > 0.0:
		_hide_wait -= clampf(float(inp.get("dt", 0.0)), 0.0, 0.1)
		if s_phase != _hide_wait_phase:
			_hide_wait = 0.0
	var held_here := seek_row != null and (s_phase != "out" or s_status != "ok" or _hide_wait > 0.0) and not crawling

	# 1. The player's own body (src/game/player.ts control), or the test's auto-walk.
	tank = c.correct_stamina(tank)
	var placed_yaw: Variant = null
	speed = 0.0
	var before := body
	if held_here:
		_auto = null
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
		gait = _auto_gait
		speed = M.hypot2(body.x - b0.x, body.z - b0.z) / dt if dt > 0.0 else 0.0
	elif body != null:
		var free := (playing and not in_bed and not held_here) or crawling
		var fw := clampf(float(inp.get("f", 0.0)), -1.0, 1.0) if free else 0.0
		var rt := clampf(float(inp.get("r", 0.0)), -1.0, 1.0) if free else 0.0
		var moving := fw != 0.0 or rt != 0.0
		var cap := Instr.max_walk_speed(true, Stamina.WALK_SPEED) if want_raised else INF
		gait = Stamina.gait_for(tank, inp.get("sprint") == true and not crawling, inp.get("creep") == true or crawling, moving, cap)
		if moving:
			var wl := M.hypot2(fw, rt)
			var nf := fw / maxf(1.0, wl)
			var nr := rt / maxf(1.0, wl)
			var sp := Stamina.speed_for(&"sprint", cap) if gait == &"sprint" else minf(cap, Stamina.speed_for(gait))
			if crawling:
				sp = CRAWL_PACE
			var sn := M.sin_js(in_yaw)
			var cs := M.cos_js(in_yaw)
			body = Session.move_local(plan, phase, body, (-sn * nf + cs * nr) * sp * dt, (-cs * nf - sn * nr) * sp * dt, PLAYER_RADIUS)
			speed = sp
	if before != null and body != null and dt > 0.0:
		tank = Stamina.step_stamina(tank, gait, M.hypot2(body.x - before.x, body.z - before.z) / dt, dt)
	# The eyes: standing, creeping or down (a spectator stands), eased; this frame's camera height.
	var want_eye := EyeHeight.target(status, String(gait)) if body != null else EyeHeight.STAND
	# The Playroom: found players stand rooted; at the party table they sit; in a hide the hide decides.
	var hide_cam := {}
	if seek_row != null and body != null:
		if s_status == "found":
			want_eye = EyeHeight.STAND
		elif s_status == "taken":
			want_eye = SEAT_EYE
		elif s_status == "ok" and s_phase == "inside":
			hide_cam = hide_camera(seek_row, latest, str(c.id), in_yaw, in_pitch, float(inp.get("f", 0.0)) > 0.0 or inp.get("peek") == true)
			if not hide_cam.is_empty():
				want_eye = EyeHeight.to_cm(float(hide_cam["y"]) - body.y)
				in_yaw = float(hide_cam["yaw"])
				in_pitch = float(hide_cam["pitch"])
	eye = _eye.update(BED_EYE if in_bed else want_eye, dt)
	# F held (the bunk; beside a downed crewmate, the heal): only sent when the run has days or downs.
	var use: bool = (day != null or downs_on) and playing and inp.get("use") == true
	var at_bunk := day != null and int(latest["depth"]) == 0 and body != null and Run.at_bunk(plan, body)
	if not use or in_bed:
		_bed_hold = 0.0
		_bed_release = use and in_bed
	if _bed_release and not use:
		_bed_release = false
	if use and at_bunk and not in_bed and not _bed_release:
		_bed_hold += dt
	elif not in_bed:
		_bed_hold = 0.0
	var depth_before := c.local_depth
	var day_before := c.day_index

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
	lf.use = use
	lf.stamina = tank if body != null else null
	# The Playroom: F for a hide (into the one in reach, or out of the one you are in), quick and loud
	# with sprint held; W held inside is a peek. The body waits for the host's answer before it moves.
	# Off the Playroom (the Clinic and the Annex, sim/hiding.gd) the floor's hides are there before anyone
	# has hidden (the host sends the seek block from the first press on).
	var hides_here := seek_row != null or (not hides.is_empty() and status == "ok")
	var near_hide := -1
	if hides_here and body != null and s_status == "ok" and s_phase == "out":
		near_hide = hide_in_reach(body)
	if hides_here and playing and inp.get("hide") == true and s_status == "ok" and (s_phase == "inside" or near_hide >= 0):
		lf.hide = true
		lf.hide_fast = inp.get("hideFast") == true
		_hide_wait = HIDE_WAIT
		_hide_wait_phase = s_phase
	lf.peek = seek_row != null and s_status == "ok" and s_phase == "inside" and not hide_cam.is_empty() and bool(hide_cam["peek"])
	var f := rc.frame(now, lf)
	frame = f
	var placed: Variant = null
	if f.placed != null:
		body = f.placed
		placed = _body_plain(body)
		var moved_on := c.local_depth != depth_before or c.day_index != day_before
		_use_floor(str(c.seed), c.local_depth)
		if _face_on_place or (moved_on and Run.in_car(car, body)):
			# A new floor, a new day or home: in the car, face out of its doors.
			_face_on_place = false
			placed["yaw"] = _want_dir(Landing.landing_facing(plan))
		elif moved_on and c.local_depth == 0:
			# Woken on your bunk (left behind, or a wipe): face the hall.
			placed["yaw"] = 0.0 if body.z > (Prison.HALL_ROW + 0.5) * Prison.CELL_SIZE else PI
		elif not moved_on and seek_row != null:
			# The Playroom: into a hide, face its gap; at the party table, face across it.
			var row: Variant = seek_row_of(c.latest, str(c.id))
			if row != null and str(row["status"]) == "taken" and int(row["seat"]) >= 0 and int(row["seat"]) < seats.size():
				placed["yaw"] = Seek.yaw_toward(float(Floor.dir_dx(seats[int(row["seat"])].facing)), float(Floor.dir_dy(seats[int(row["seat"])].facing)))
			elif row != null and str(row["phase"]) in ["entering", "inside"] and int(row["hide"]) >= 0 and int(row["hide"]) < hides.size():
				placed["yaw"] = gap_yaw(hides[int(row["hide"])])
		if _auto != null:
			auto_status = "interrupted"
		_auto = null
	# What this screen showed (the fairness rule, counted for the tests): two frames running with every eye
	# mark lit (with one watcher needed, every frame it is seen).
	var all_lit := f.seeing and f.eyes_all
	if all_lit and _prev_seeing and f.orderly != null and _prev_pose != null:
		watched_pairs += 1
		if not Pose.same_pose(f.orderly, _prev_pose):
			watched_moves += 1
	_prev_seeing = all_lit
	_prev_pose = f.orderly

	# 3. What to draw and play.
	var snap := _snapshot(c, f, latest, me_row, phase, want_raised)
	snap["placed"] = placed
	snap["autoYaw"] = placed_yaw
	# The day loop, as the host has it (null in a run without days). Host-timed things (the bedtime count,
	# lights out, the morning) are shown against the host clock as this client estimates it.
	snap["day"] = day
	snap["hostNow"] = c.clock.host_time(rc._now)
	snap["goingUp"] = day != null and phase == "riding" and (day as Dictionary)["result"] != null
	var ids: Array[String] = []
	for p: Dictionary in latest["players"]:
		ids.append(str(p["id"]))
	var bunk := Day.bunk_of(ids, str(c.id))
	snap["bed"] = {"inBed": in_bed, "atBunk": at_bunk, "hold": clampf(_bed_hold / Run.BED_HOLD, 0.0, 1.0), "bunk": [bunk.x, bunk.y]}
	# The Playroom (null / {} / -1 elsewhere): the host's seek block, this player's row in it, the newest
	# count event (client.gd count_event: host times), the hide in reach, the camera in a hide.
	snap["seek"] = latest.get("seek")
	snap["mySeek"] = seek_row
	snap["countEvent"] = c.count_event() if seek_row != null else {}
	snap["nearHide"] = near_hide
	snap["nearHideKind"] = String(hides[near_hide].kind) if near_hide >= 0 and near_hide < hides.size() else ""
	snap["hideCam"] = hide_cam
	# Down first, then out (null in a run without it): the host's downs block, as client.gd downs() and
	# spots() read it; its times are host times, counted against "hostNow" (client/down_view.gd).
	snap["downs"] = latest.get("downs")
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
	_bed_hold = 0.0
	_bed_release = false
	_hide_wait = 0.0
	_hide_wait_phase = ""
	_auto_gait = &"walk"

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
	hides = []
	seats = []
	if p.place == Places.PLAYROOM:
		seats = Playroom.seats(p)
	# The floor's hides (sim/hides.gd): the Playroom's own list, the Clinic's and the Annex's; none at home.
	hides = Hides.hides_for(p, p.seed)

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
		# Its sound goes on under a lone watcher of two (not held on this screen); held, it cuts dead.
		if not f.held and moving and _orderly_tpl != null:
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
			# Two-watcher Stillness: the eye marks, and where the one watcher it walks at stands (the watched walk).
			"eyes": {"on": f.eyes_on, "need": f.eyes_need, "lit": f.eyes_lit, "all": f.eyes_all},
			"watchedAt": _watcher_at(f, vb),
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

## Two-watcher Stillness: the eye point of the one watcher it walks at ([x, y, z]), or null.
func _watcher_at(f: Client.Frame, vb: Move.Body) -> Variant:
	if f.watched_by == "":
		return null
	if f.watched_by == str(_client.id):
		return [vb.x, vb.y + eye, vb.z]
	for p: Dictionary in f.players:
		if str(p["id"]) == f.watched_by:
			var b: Move.Body = p["body"]
			return [b.x, b.y + 1.6, b.z]
	return null

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
		var o := {"id": id, "name": nm.get(id, id), "index": int(order.get(id, 0)), "x": b.x, "y": b.y, "z": b.z, "level": b.level,
			"yaw": p["yaw"], "pitch": p["pitch"], "gait": p["gait"], "status": p["status"], "active": p["active"],
			"raised": bool(raised.get(id, false)), "face": str(faces.get(id, ""))}
		_seek_figure(o, latest)
		out.append(o)
	return out

## The Playroom: how another player is drawn from their seek row. In a hide: crouched, facing out of
## the gap, sunk to the hide's eye, beside the others in it. At the party table: sitting, facing across
## it, in a paper hat. Found: standing where they were found. Down: downed (the run's "caught"). The
## row's facts ride along for the views and the tests (hide, seekPhase, seekStatus, seat, hat).
func _seek_figure(o: Dictionary, latest: Dictionary) -> void:
	var row: Variant = seek_row_of(latest, str(o["id"]))
	if row == null:
		return
	var st := str(row["status"])
	var ph := str(row["phase"])
	o["hide"] = int(row["hide"])
	o["seekPhase"] = ph
	o["seekStatus"] = st
	o["seat"] = int(row["seat"])
	o["hat"] = st == "taken"
	if st == "found" or st == "taken":
		o["status"] = "ok"
	if st == "taken":
		o["gait"] = "creep"
		var si := int(row["seat"])
		if si >= 0 and si < seats.size():
			var sf := seats[si].facing
			o["yaw"] = Seek.yaw_toward(float(Floor.dir_dx(sf)), float(Floor.dir_dy(sf)))
			o["y"] = float(o["y"]) - (CREW_CROUCH_MASK - SEAT_EYE)
	elif st == "ok" and ph == "inside" and int(row["hide"]) >= 0 and int(row["hide"]) < hides.size():
		var h := hides[int(row["hide"])]
		var off := slot_offset(h, latest, str(o["id"]))
		o["x"] = float(o["x"]) + off.x
		o["z"] = float(o["z"]) + off.y
		o["gait"] = "creep"
		o["yaw"] = gap_yaw(h)
		var mask := PIT_HEAD if h.kind == &"pit" else h.eye / 100.0
		o["y"] = float(o["y"]) + mask - CREW_CROUCH_MASK
	elif st == "ok" and ph != "out":
		o["gait"] = "creep"

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

# --- the Playroom ---------------------------------------------------------------------------------

## A player's row in the snapshot's seek block, or null (another floor, or not in it).
static func seek_row_of(latest: Variant, id: String) -> Variant:
	if not latest is Dictionary:
		return null
	var k: Variant = (latest as Dictionary).get("seek")
	if not k is Dictionary or not (k as Dictionary).has("players"):
		return null
	for p: Dictionary in k["players"]:
		if str(p["id"]) == id:
			return p
	return null

## The hide whose front is in reach of `b` (the rules' Seek.HIDE_REACH, a little inside it), or -1.
func hide_in_reach(b: Move.Body) -> int:
	var best := -1
	var best_d := Seek.HIDE_REACH - 0.05
	for h in hides:
		if h.level != b.level:
			continue
		var d := M.hypot2(h.front.x / 100.0 - b.x, h.front.y / 100.0 - b.z)
		if d <= best_d:
			best = h.id
			best_d = d
	return best

## The way a hide's gap faces, as a yaw (out of the hide into the room).
static func gap_yaw(h: Playroom.Hide) -> float:
	return Seek.yaw_toward(float(Floor.dir_dx(h.gap)), float(Floor.dir_dy(h.gap)))

## Where in a hide player `id` sits, side by side with the others in it (ordered by id, so every screen
## agrees): an offset from the inside spot across the gap. One-person hides: none.
static func slot_offset(h: Playroom.Hide, latest: Variant, id: String) -> Vector2:
	if h.capacity <= 1 or not latest is Dictionary or (latest as Dictionary).get("seek") == null:
		return Vector2.ZERO
	var ids: Array[String] = []
	for p: Dictionary in (latest as Dictionary)["seek"]["players"]:
		if int(p["hide"]) == h.id and str(p["phase"]) != "out":
			ids.append(str(p["id"]))
	ids.sort()
	var i := maxi(0, ids.find(id))
	var gx := float(Floor.dir_dx(h.gap))
	var gz := float(Floor.dir_dy(h.gap))
	if h.kind == &"pit":
		# Round the middle of the pit, the first towards the gap.
		var a := TAU * i / float(h.capacity)
		var fwd := Vector2(gx, gz) * cos(a) + Vector2(-gz, gx) * sin(a)
		return fwd * SLOT_GAP
	return Vector2(-gz, gx) * SLOT_GAP * (float(i) - (h.capacity - 1) * 0.5)

## The camera in a hide (playarea.md 4): sat back by default, low and back from the gap, looking out
## through the dark; peeking (W), at the hide's eye at the inside spot, turned only within the gap.
## Returns {x, y, z, yaw, pitch, peek, hide, kind, gapYaw, gapHalf} (yaw and pitch clamped).
func hide_camera(row: Dictionary, latest: Dictionary, id: String, want_yaw: float, want_pitch: float, peek: bool) -> Dictionary:
	var hid := int(row["hide"])
	if hid < 0 or hid >= hides.size() or plan == null:
		return {}
	var h := hides[hid]
	var ins := Seek.hide_inside_body(plan, h)
	var off := slot_offset(h, latest, id)
	var gy := gap_yaw(h)
	var half := deg_to_rad(float(h.gap_half))
	var eye_h := h.eye / 100.0
	if h.kind == &"pit":
		eye_h = PIT_PEEK_EYE
	var yaw := want_yaw
	if half < PI - 1e-3:
		var rel := wrapf(want_yaw - gy, -PI, PI)
		yaw = gy + clampf(rel, -half, half)
	var pitch := clampf(want_pitch, -PEEK_PITCH, PEEK_PITCH)
	var gx := float(Floor.dir_dx(h.gap))
	var gz := float(Floor.dir_dy(h.gap))
	var x := ins.x + off.x
	var z := ins.z + off.y
	var y := ins.y + eye_h
	if not peek:
		# Sat back: lower, and back from the gap (in the pit, down among the balls; in a cabinet or under a
		# desk only as far as its back panel allows).
		y = ins.y + (0.3 if h.kind == &"pit" else maxf(0.25, eye_h - SAT_DROP))
		var back := 0.0 if h.kind == &"pit" else (0.12 if h.kind == &"cabinet" else (0.2 if h.kind == &"desk" else SAT_BACK))
		x -= gx * back
		z -= gz * back
	return {"x": x, "y": y, "z": z, "yaw": yaw, "pitch": pitch, "peek": peek, "hide": hid, "kind": String(h.kind), "gapYaw": gy, "gapHalf": half}

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

## Walks along the rules' own path to a cell. With friends no faster than walking (the server checks),
## or creeping (`gait` creep: silent on the Playroom's squeaker tiles), or sprinting (`gait` sprint, for
## as long as the tank lasts).
func walk_to(level: int, x: int, y: int, pace: float, walk_gait: StringName = &"walk") -> Dictionary:
	if plan == null or body == null:
		return {"ok": false}
	var path := Floor.find_path(plan, Move.cell_of(plan, body), Floor.Pos.make(level, x, y))
	if path.is_empty():
		auto_status = "failed: no path"
		return {"ok": false}
	_auto = Follow.start_path_walk(path)
	_auto_stuck = 0.0
	_auto_gait = walk_gait
	var cap := Stamina.CREEP_SPEED * 0.95 if walk_gait == &"creep" else (Stamina.SPRINT_SPEED * 0.95 if walk_gait == &"sprint" else Stamina.WALK_SPEED * 0.95)
	_auto_pace = minf(pace, cap) if (not local or walk_gait == &"creep") else pace
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
