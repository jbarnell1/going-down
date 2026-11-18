# A headless GDScript player (or a hostile probe) for the local end-to-end check (tools/net_local.mjs).
#   godot --headless --path godot --script res://tests/net_e2e_client.gd -- url=ws://127.0.0.1:4451 secret=test-passphrase
#       role=player name=A delay=0.05 behave=watch|away|door expect=3 [starts=1]
#   ... role=probe kind=wrongpass|oversize|flood|ninth|garbage|oldbuild
#   build=ID: the build id this client says in its hello (net/build_info.gd; the server is given the same).
# A player also sends the server one heartbeat, one error line and one F9 report (client/telemetry.gd's
# message shapes), for the night's log (server/night_log.gd; tools/net_local.mjs checks it).
# A player plays a scripted session through net/room_client.gd at 60 frames a second: out of the
# car, watch the Orderly (or keep it behind you, or watch the door), call the lift, board on the bank
# half, bank. It checks its own screen as it goes and prints one line `RESULT {json}`:
#   watchedPairs / watchedMoves: consecutive frames on which this screen saw the Orderly, and those of
#     them on which the drawn pose changed (must be 0);
#   caughtWhileSeen: catches of this player whose wind-up this screen drew while seeing it (must be 0);
#   banked, phase, frames, events, ...
# A probe prints `RESULT {"kind": ..., "code": close code, ...}`.
extends SceneTree

const RoomClient = preload("res://net/room_client.gd")
const Client = preload("res://net/client.gd")
const Session = preload("res://net/session.gd")
const Pose = preload("res://net/pose.gd")
const Move = preload("res://sim/move.gd")
const Run = preload("res://sim/run.gd")
const Entity = preload("res://sim/entity.gd")
const BuildInfo = preload("res://net/build_info.gd")
const Telemetry = preload("res://client/telemetry.gd")

var args := {}
var rc: RoomClient
var t0 := 0
var body: Move.Body = null
var route: Array[Move.Body] = []
var yaw := 0.0
var pitch := 0.0
var out_done := -1
var boarded := -1
var called := false
var started := false
var prev: Client.Frame = null
var res := {"watchedPairs": 0, "watchedMoves": 0, "caughtWhileSeen": 0, "seenFrames": 0, "frames": 0, "banked": false, "catches": 0, "latches": 0, "placements": 0}
var frames_log: Array = []  # [render time, seeing] per frame
var done_at := -1.0
var probes: Array[WebSocketPeer] = []
var probe_stage := 0
var probe_at := 0.0

func _init() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	Engine.max_fps = 60
	t0 = Time.get_ticks_usec()
	if args.has("build"):
		BuildInfo._id = args["build"]
	if args.get("role") == "probe":
		return
	rc = RoomClient.new()
	rc.delay = float(args.get("delay", "0"))
	rc.connect_to(args["url"], args["secret"], args.get("name", "player"))

func now() -> float:
	return (Time.get_ticks_usec() - t0) / 1000000.0

func finish(r: Dictionary, code: int = 0) -> void:
	print("RESULT " + JSON.stringify(r))
	quit(code)

func _process(_delta: float) -> bool:
	var t := now()
	if t > float(args.get("timeout", "200")):
		res["timeout"] = true
		finish(res, 1)
		return true
	if args.get("role") == "probe":
		_probe(t)
		return false
	_player(t)
	return false

# ---------------------------------------------------------------------------------------------

func _player(t: float) -> void:
	rc.poll(t)
	if rc.status == "closed":
		res["closed"] = rc.close_code
		finish(res, 1)
		return
	if rc.status == "lobby" and not _told:
		_told = true
		_tell()
	if rc.status == "lobby" and not rc.run_on:
		if args.get("starts") == "1" and not started and rc.people.size() >= int(args.get("expect", "1")):
			started = true
			rc.start_run()
		return
	var c := rc.client
	if c == null or c.seed == null:
		rc.frame(t, _local())
		return
	var latest: Dictionary = c.latest
	var plan := Session.plan_for(c.seed, c.local_depth)
	var car := Session.car_for(plan)
	var phase: String = latest["phase"]
	var f := rc.frame(t, _local())
	if f == null:
		return
	if f.placed != null:
		body = f.placed
		route.clear()
		res["placements"] += 1
	res["frames"] += 1
	# Checks: on consecutive frames this screen saw the Orderly, the drawn pose never changes.
	if f.seeing:
		res["seenFrames"] += 1
	if prev != null and prev.seeing and f.seeing and prev.orderly != null and f.orderly != null and prev.depth == f.depth:
		res["watchedPairs"] += 1
		if not Pose.same_pose(prev.orderly, f.orderly) and not _bending_in_place(prev.orderly, f.orderly):
			res["watchedMoves"] += 1
	prev = f
	frames_log.append([f.render_time, f.seeing])
	if body == null:
		return
	# The script.
	var behave: String = args.get("behave", "watch")
	var me: Variant = null
	for p: Dictionary in latest["players"]:
		if p["id"] == c.id:
			me = p
	var ok: bool = me != null and me["status"] == "ok"
	if out_done != c.local_depth and (phase == "unloading" or phase == "away"):
		out_done = c.local_depth
		var spot := {"A": [-1.0, -0.5], "B": [-1.0, 0.5], "C": [-1.5, 0.0]}.get(args.get("name"), [-1.2, 0.0]) as Array
		route = [Run.car_body(car, 0.45, 0.0), Run.car_body(car, -0.6, 0.0), Run.car_body(car, spot[0], spot[1])]
	if phase == "boarding" and boarded != c.local_depth:
		boarded = c.local_depth
		var seat := {"A": [0.9, -0.5], "B": [1.5, -0.5], "C": [1.2, 0.5]}.get(args.get("name"), [1.2, -0.3]) as Array
		route = [Run.car_body(car, -0.6, 0.0), Run.car_body(car, 0.45, 0.0), Run.car_body(car, seat[0], seat[1])]
	if behave == "watch" and phase == "away" and not called and route.is_empty() and M_hyp(body.x - car.door_x, body.z - car.door_z) <= Run.CALL_REACH - 0.3:
		called = true
		_call_next = true
	# Walk (never while taken).
	var budget := 3.0 / 60.0 if (ok and not f.taken) else 0.0
	while budget > 1e-9 and not route.is_empty():
		var w := route[0]
		var d := M_hyp(w.x - body.x, w.z - body.z)
		if d < 0.03:
			route.pop_front()
			continue
		var stp := minf(budget, d)
		var nb := Session.move_local(plan, phase, body, (w.x - body.x) / d * stp, (w.z - body.z) / d * stp)
		budget -= stp
		if M_hyp(nb.x - body.x, nb.z - body.z) < 1e-6:
			route.pop_front()
			break
		body = nb
	# Look.
	var o: Variant = f.orderly
	if phase == "boarding" or phase == "riding" or phase == "ended":
		_look_at(car.door_x, car.door_z, body.y + 1.65)
	elif behave == "watch" and o != null:
		_look_at(o["x"], o["z"], float(o["y"]) + 1.7)
	elif behave == "away" and o != null:
		yaw = Entity.yaw_toward(body.x - float(o["x"]), body.z - float(o["z"]))
		pitch = 0.0
	else:
		_look_at(car.door_x, car.door_z, body.y + 1.65)
	# The run is over at "ended"; with the day loop on (the server's game), a bank or a wipe rides the
	# crew up to the prison instead, so seeing that settle is the end of this session too.
	if done_at < 0.0 and (phase == "ended" or _settled(c)):
		done_at = t
	if done_at >= 0.0 and t - done_at > 3.0:
		_report(c)

var _call_next := false
var _told := false

## What a game sends for the night's log: a heartbeat, an error line, an F9 report (two lines).
func _tell() -> void:
	var who: String = args.get("name", "player")
	var delay := float(args.get("delay", "0"))
	rc.send_telemetry({"type": "telemetry", "kind": "hb", "body": JSON.stringify({"build": BuildInfo.id(), "os": OS.get_name(), "mode": "lobby",
		"fps": 60, "avg_ms": 16.7, "worst_ms": 20.0 + delay * 200.0, "ping_ms": delay * 2000.0, "errors": 1})})
	rc.send_telemetry({"type": "telemetry", "kind": "log", "body": "err net_local test error from every player (res://tests/net_e2e_client.gd:1 _tell)"})
	for m in Telemetry.report_parts("rep", 1, PackedStringArray(["player pressed F9 at %s, lobby (net_local test)" % who, "a line before it"])):
		rc.send_telemetry(m)

## The one movement a watched Orderly makes (B6, the owner's call: "Anyone looking sees it bend down
## too"): bent over a downed player, it works at them where it stands. Only the bend's own clock may
## run; any step, turn or other clip still counts as moving while seen.
func _bending_in_place(a: Dictionary, b: Dictionary) -> bool:
	return a["anim"] == "bend" and b["anim"] == "bend" and a["x"] == b["x"] and a["y"] == b["y"] \
		and a["z"] == b["z"] and a["level"] == b["level"] and a["yaw"] == b["yaw"]


## Over when the run banks or wipes, or (against a server with the floor quota on, which scripted players
## who never record cannot meet) once the call has been refused.
func _settled(c: Client) -> bool:
	var refused := 0
	for e: Dictionary in c.events:
		if e.get("type") == "banked" or e.get("type") == "wiped":
			return true
		if e.get("type") == "callRefused":
			refused += 1
	return refused >= 1

static func M_hyp(a: float, b: float) -> float:
	return sqrt(a * a + b * b)

func _look_at(x: float, z: float, y: float) -> void:
	yaw = Entity.yaw_toward(x - body.x, z - body.z)
	pitch = atan2(y - (body.y + 1.65), maxf(M_hyp(x - body.x, z - body.z), 0.1))

func _local() -> Client.LocalFrame:
	var lf := Client.LocalFrame.new()
	lf.body = body if body != null else Move.Body.make(0.0, 0.0, 0, 0.0)
	lf.yaw = yaw
	lf.pitch = pitch
	lf.eye = 1.65
	lf.h_fov_deg = 105.0
	lf.v_fov_deg = 70.0
	lf.raised = args.get("behave") == "watch"
	lf.call = _call_next
	_call_next = false
	return lf

func _report(c: Client) -> void:
	var wind := -1.0
	for e: Dictionary in c.events:
		if e.get("type") == "windUp" and e.get("playerId") == c.id:
			wind = float(e["t"])
		if e.get("type") == "caught" and e.get("playerId") == c.id:
			res["catches"] += 1
			for fr: Array in frames_log:
				if fr[1] and float(fr[0]) >= wind and float(fr[0]) < float(e["t"]) and wind >= 0.0:
					res["caughtWhileSeen"] += 1
		if e.get("type") == "banked":
			res["banked"] = true
			res["total"] = e["summary"]["total"]
		if e.get("type") == "callRefused":
			res["refused"] = int(res.get("refused", 0)) + 1
			res["quota"] = [e.get("earned"), e.get("needed")]
	res["phase"] = c.latest["phase"]
	res["events"] = c.events.size()
	res["latches"] = c.stats.latches
	res["reports"] = c.stats.reports
	res["inputs"] = c.stats.inputs
	res["inputBytes"] = c.stats.input_bytes
	res["snapshots"] = c.stats.snapshots
	res["received"] = rc.received
	res["id"] = c.id
	rc.leave()
	finish(res, 0)

# ---------------------------------------------------------------------------------------------
# Probes: each opens connections that the server must refuse, and reports the close code it got.

func _open(secret: Variant) -> WebSocketPeer:
	var ws := WebSocketPeer.new()
	ws.connect_to_url(args["url"])
	probes.append(ws)
	ws.set_meta("secret", secret)
	ws.set_meta("hello", false)
	return ws

func _pump() -> void:
	for ws in probes:
		ws.poll()
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN and not ws.get_meta("hello"):
			ws.set_meta("hello", true)
			if ws.get_meta("secret") != null:
				ws.send_text(JSON.stringify(["hello", 1, ws.get_meta("secret"), "probe", ws.get_meta("build") if ws.has_meta("build") else BuildInfo.id()]))
		while ws.get_available_packet_count() > 0:
			var txt := ws.get_packet().get_string_from_utf8()
			if txt.begins_with("m|{\"id\""):
				pass
			if txt.contains("\"t\":\"you\""):
				ws.set_meta("you", true)

func _probe(t: float) -> void:
	var kind: String = args.get("kind")
	_pump()
	match kind:
		"wrongpass":
			# Four tries with a wrong passphrase: refused (4001); from the third failure on the address is
			# refused before any handshake.
			if probe_stage < 4 and (probes.is_empty() or probes[-1].get_ready_state() == WebSocketPeer.STATE_CLOSED):
				_open("not-the-passphrase")
				probe_stage += 1
			if probe_stage == 4 and probes[-1].get_ready_state() == WebSocketPeer.STATE_CLOSED:
				var codes: Array = []
				for ws in probes:
					codes.append(ws.get_close_code())
				finish({"kind": kind, "codes": codes, "code": codes[0]})
		"oversize", "flood":
			if probes.is_empty():
				_open(args["secret"])
			var ws := probes[0]
			if ws.has_meta("you") and probe_stage == 0:
				probe_stage = 1
				if kind == "oversize":
					ws.send_text("m|" + "x".repeat(20000))
				else:
					for i in 400:
						ws.send_text("m|{\"t\":\"ping\"}")
			if ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
				finish({"kind": kind, "code": ws.get_close_code(), "sent": probe_stage == 1})
		"ninth":
			# One at a time (the server lets only a few wait for their hello at once).
			var ready := 0
			for i in mini(8, probes.size()):
				if probes[i].has_meta("you"):
					ready += 1
			if probes.size() < 8 and ready == probes.size():
				_open(args["secret"])
			elif ready == 8 and probes.size() == 8:
				_open(args["secret"])
			if probes.size() == 9 and probes[8].get_ready_state() == WebSocketPeer.STATE_CLOSED:
				var r := {"kind": kind, "code": probes[8].get_close_code(), "admitted": ready}
				for i in 8:
					probes[i].close()
				finish(r)
		"oldbuild":
			# The right passphrase from another build: closed (4007) with the out-of-date reason.
			if probes.is_empty():
				_open(args["secret"]).set_meta("build", "an-old-build")
			if probes[0].get_ready_state() == WebSocketPeer.STATE_CLOSED:
				finish({"kind": kind, "code": probes[0].get_close_code(), "reason": probes[0].get_close_reason()})
		"garbage":
			# A run message that is not the protocol: closed (4005).
			if probes.is_empty():
				_open(args["secret"])
			var ws := probes[0]
			if ws.has_meta("you") and probe_stage == 0:
				probe_stage = 1
				ws.send_text("n1|[1,\"I\",1,0,[1e999,0,0,0]]")
				ws.send_text("m|{\"t\":\"nonsense\"}")
			if ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
				finish({"kind": kind, "code": ws.get_close_code()})
