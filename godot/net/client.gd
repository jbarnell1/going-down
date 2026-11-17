# A player's machine. Port of src/net/client.ts (NetClient). It owns that player's body and camera
# (moved locally, so walking feels instant), sends the host its body, view and intents about 20 times
# a second, and draws everyone else and the Orderly from the host's snapshots, INTERP_DELAY behind
# the newest it could have.
#
# The Orderly is never seen to move on this screen. Every frame (frame()):
#  1. The drawn Orderly is checked against the real camera where it is DRAWN, with the logic's own
#     generous sight test (Session.camera_sees).
#  2. While the local player can see the drawn figure, the drawing is frozen: same pose, animation
#     clock stopped, whatever snapshots say. The moment it is first seen the client sends the host a
#     seen report at once: the exact pose it froze on and the two snapshots it was blended from.
#     Reports repeat in every input until the host acknowledges them.
#  3. It only goes back to following snapshots on a frame where neither the frozen pose nor the
#     snapshots' pose can be seen, so the jump between the two (if any) is never on screen.
# Consequence: a pose can change between two frames only if at least one of them did not show it.
#
# Blinks: the screen is dark (a) while the estimated host clock is within the blink's blind window
# widened by the clock's error bound plus a tick, and (b) while the snapshots being drawn come from
# inside the blind window, so the movement a blink allows is never drawn lit.
#
# The local body is never taken from snapshots, except when the host moves the player (start, rides,
# being pushed out of the car, joining): those come as a numbered placement, applied here once and
# acknowledged in every input; the host ignores bodies until it is acknowledged.
#
# Being taken: a wind-up aimed at this player that its displayed timeline has followed to its end,
# without any frame of it showing the Orderly, latches "taken": from that frame the screen is blind
# (Frame.dark, no Orderly drawn, nothing can be seen) and the input that confirms it to the host goes
# out at once. It is let go when the catch has been drawn up to, when the snapshots show the host did
# not complete it, or after LATCH_MAX seconds of displayed time with nothing pending.
#
# The tank: the game steps its own copy every frame so a sprint answers at once; the host owns the
# truth and sends it back in every snapshot, as it stood after input `ackIn`. correct_stamina()
# moves the local copy by the difference.
extends RefCounted

const Move = preload("res://sim/move.gd")
const Stamina = preload("res://sim/stamina.gd")
const M = preload("res://sim/jsmath.gd")
const Protocol = preload("res://net/protocol.gd")
const Session = preload("res://net/session.gd")
const Pose = preload("res://net/pose.gd")
const Transport = preload("res://net/transport.gd")

const TICK := Session.TICK
const LAG_WINDOW := 60
const SNAP_KEEP := 3.0
## Inputs whose tank is remembered for correct_stamina().
const TANK_KEEP := 120
## Differences in the tank smaller than this are rounding (the snapshot carries it to 0.001).
const TANK_EPS := 0.004
## A taken latch with nothing pending on the host is let go after this much displayed time (s)...
const LATCH_IDLE := 1.0
## ...and any latch after this much (s), the host's own limit on waiting being CATCH_CONFIRM_MAX.
const LATCH_MAX := 2.5

## What the game hands the client each frame: the camera, and the player's intents.
class LocalFrame:
	var body: Move.Body
	var eye := 1.65
	var yaw := 0.0
	var pitch := 0.0
	var h_fov_deg := 90.0
	var v_fov_deg := 70.0
	var raised := false
	var hold_doors := false
	## The call button was pressed this frame.
	var call := false
	## The pick-up key was pressed this frame.
	var pick_up := false
	## How the player is moving ("walk", "creep", "sprint"), and the game's own copy of their tank (or null).
	var gait := "walk"
	var stamina: Stamina.Stamina = null

## One rendered frame: what to draw.
class Frame:
	## Screen dark for a blink (or taken).
	var dark := false
	## Where the Orderly is on this screen's timeline (a pose Dictionary, the same one for as long as it
	## is held), or null.
	var orderly: Variant = null
	## Whether to draw it. Never on a dark frame: in the dark it is heard (its sound still comes from
	## `orderly`), not seen.
	var visible := false
	## The drawing is frozen (seen, or held until a jump can happen out of view).
	var held := false
	## The local player sees the drawn Orderly on this frame.
	var seeing := false
	## Latched as taken: the screen is blind (also `dark`) until the catch is drawn or called off.
	var taken := false
	## Depth of the floor drawn.
	var depth := 1
	## Everyone else, interpolated: {id, body (Move.Body), yaw, pitch, active, status, gait}.
	var players: Array[Dictionary] = []
	## Host time of the state being drawn (-1 before the first).
	var render_time := -1.0
	## The host moved the local player: adopt this body (else null).
	var placed: Move.Body = null

class ClientStats:
	var frames := 0
	var dark_frames := 0
	var guard_dark_frames := 0
	var reports := 0
	var inputs := 0
	var input_bytes := 0
	var max_input_bytes := 0
	var snapshots := 0
	var max_release_jump := 0.0
	var releases := 0
	var big_releases := 0
	var latches := 0
	var false_latches := 0

## Assigned by the host's welcome.
var id: Variant = null
var seed: Variant = null
## In the run (otherwise watching until the next elevator stop).
var playing := false
## The host is gone: the session is over.
var ended := false
## The newest snapshot (or the welcome's state): phase, depth, crew, tapes, summary.
var latest: Variant = null
## Every event in host order, each exactly once (plain Dictionaries).
var events: Array[Dictionary] = []
## Depth of the floor the local player is on.
var local_depth := 1
## Sequence number of this client's first event (1 unless it joined a run in progress).
var first_event := 1
var clock := Session.HostClock.new()
var stats := ClientStats.new()
## Every input's size in bytes, when a test asks.
var keep_sizes := false
var input_sizes: Array[int] = []
## The local player's tank as the host last said it was (the truth, a round trip old), or null.
var host_stamina: Stamina.Stamina = null
## A false latch was let go on the last frame (the game shows it as a drop-out).
var latch_released := false
## Other players' emotes as the host passed them on, in arrival order: {player, emote, t (host time)}.
## Keep your own index into it, as with `events`.
var emotes: Array[Dictionary] = []
## This player's drawn face (FaceCodec text, sent in the join) or "", and the other players' faces as
## the host passed them on: player id -> FaceCodec text (only valid faces get this far).
var face := ""
var faces := {}

var host_id: String
var name: String
var _transport: Transport.Transport
var _ev_next := 1
var _ev_buf := {}
var _snaps: Array[Dictionary] = []
var _pin: Variant = null  # {pose, id, depth}
var _lags := PackedFloat64Array()
var _rt: Variant = null
var _rt_local := 0.0
var _drawn: Variant = null
var _drawn_depth := -1
var _frozen := false
var _report_id := 0
var _unacked: Array[Dictionary] = []
var _seq := 0
var _last_send := -INF
var _seeing_latch := false
var _calls := 0
var _pick_ups := 0
var _ack_ht := -INF
var _place_applied := 0
var _pending_place: Variant = null
var _blinks := {}  # at -> {at, len, warn, announced}
var _last_join := -INF
var _interp_delay: float
var _input_interval: float
var _tank_at := {}  # input seq -> Stamina
var _host_tank_seq := 0
var _host_tank_fresh := false
var _wind_up_on := false
var _wind_up_saw := false
var _armed_end: Variant = null
var _latched_end := -INF
var _latch: Variant = null  # {rt, armed, depth}
var _caught_at := -INF
var _orderly_from := -1

## `interp_delay` (default INTERP_DELAY) and `input_interval` (default INPUT_INTERVAL; 0 sends every frame).
## `face`: the player's drawn face (FaceCodec text) to send in the join, or "" for none.
func _init(transport: Transport.Transport, host_id_: String, name_: String, now: float, interp_delay: float = Session.INTERP_DELAY, input_interval: float = Session.INPUT_INTERVAL, face_: String = "") -> void:
	_transport = transport
	host_id = host_id_
	name = name_
	face = Protocol.valid_face(face_)
	_interp_delay = interp_delay
	_input_interval = input_interval
	_send_join(now)

func _send_join(now: float) -> void:
	_last_join = now
	var m := {"type": "join", "name": name, "ct": now}
	if face != "":
		m["face"] = face
	_transport.send(host_id, Protocol.encode(m))

## Plays an emote for the others (one of Protocol.EMOTES; the host passes it on, rate limited).
func emote(which: String) -> void:
	if id != null and not ended and which in Protocol.EMOTES:
		_transport.send(host_id, Protocol.encode({"type": "emote", "emote": which}))

## Leaves the session.
func leave() -> void:
	_transport.send(host_id, Protocol.encode({"type": "leave"}))
	_transport.close()
	ended = true

## The local player's instrument and tapes, from the newest snapshot (or null).
func me() -> Variant:
	if latest == null:
		return null
	for m: Dictionary in latest["crew"]:
		if m["id"] == id:
			return m
	return null

## Blink starts the client knows of (host time).
func known_blinks() -> Array[float]:
	var out: Array[float] = []
	for k: float in _blinks.keys():
		out.append(k)
	out.sort()
	return out

## When the screen goes dark for each known blink, in LOCAL time, by the clock alone: [{start, end}].
func blink_windows() -> Array[Dictionary]:
	var guard := clock.error_bound() + 0.01
	var off := clock.offset()
	var out: Array[Dictionary] = []
	for at in known_blinks():
		var k: Dictionary = _blinks[at]
		out.append({"start": float(k["at"]) - TICK - guard - off, "end": float(k["at"]) + float(k["len"]) + TICK + guard - off})
	return out

# -------------------------------------------------------------------------------------------
# Receiving.

## Takes in everything that has arrived (call whenever; `now` is the local clock).
func receive(now: float) -> void:
	for pe in _transport.peer_events():
		if pe["kind"] == "left" and pe["peer"] == host_id:
			ended = true
	for d in _transport.receive():
		if d["from"] != host_id:
			continue
		var m: Variant = Protocol.decode(d["data"])
		if m == null:
			continue
		match String(m["type"]):
			"welcome":
				if id != null:
					continue
				id = m["you"]
				seed = m["seed"]
				playing = m["playing"]
				_ev_next = m["evFrom"]
				first_event = m["evFrom"]
				var w: Dictionary = m["world"]
				latest = w
				local_depth = w["depth"]
				_insert(w)
				_learn_blink(w)
			"snap":
				if id == null:
					continue
				stats.snapshots += 1
				if m["echo"] != null:
					clock.sample(m["echo"][0], m["echo"][1], m["st"], now)
				_lags.append(now - float(m["st"]))
				if _lags.size() > LAG_WINDOW:
					_lags.remove_at(0)
				_ack_ht = maxf(_ack_ht, m["ht"])
				var evs: Array = m["events"]
				var ev_from: int = m["evFrom"]
				for i in evs.size():
					var n := ev_from + i
					if n >= _ev_next and not _ev_buf.has(n):
						_ev_buf[n] = evs[i]
				while _ev_buf.has(_ev_next):
					var ev: Dictionary = _ev_buf[_ev_next]
					if ev.get("type") == "caught" and ev.get("playerId") == id:
						_caught_at = maxf(_caught_at, float(ev["t"]))
					events.append(ev)
					_ev_buf.erase(_ev_next)
					_ev_next += 1
				var kept: Array[Dictionary] = []
				for r in _unacked:
					if int(r["id"]) > int(m["ackSeen"]):
						kept.append(r)
				_unacked = kept
				var pl: Variant = m["place"]
				if pl != null and int(pl["seq"]) > _place_applied and (_pending_place == null or int(pl["seq"]) > int(_pending_place["seq"])):
					_pending_place = pl
				var ack_in: int = m["ackIn"]
				if m["stamina"] != null and ack_in >= _host_tank_seq:
					host_stamina = m["stamina"]
					_host_tank_fresh = _host_tank_fresh or ack_in > _host_tank_seq or _host_tank_seq == 0
					_host_tank_seq = ack_in
				var world: Dictionary = m
				_insert(world)
				if latest == null or int(m["tick"]) > int(latest["tick"]):
					latest = world
					for p: Dictionary in m["players"]:
						if p["id"] == id:
							playing = true
							break
				_learn_blink(world)
			"pong":
				clock.sample(m["ct"], float(m["st"]) - float(m["hr"]), m["st"], now)
			"emoted":
				if id != null and m["player"] != id:
					emotes.append({"player": m["player"], "emote": m["emote"], "t": m["t"]})
			"face":
				# Before or after the welcome (it follows the welcome, but a repeated join may cross it).
				if m["player"] != id:
					faces[m["player"]] = m["face"]

func _insert(w: Dictionary) -> void:
	var s := _snaps
	var i := s.size()
	var t: int = w["tick"]
	while i > 0 and int(s[i - 1]["tick"]) > t:
		i -= 1
	if i > 0 and int(s[i - 1]["tick"]) == t:
		return
	s.insert(i, w)
	var newest: float = s[s.size() - 1]["ht"]
	while s.size() > 2 and float(s[0]["ht"]) < newest - SNAP_KEEP:
		s.remove_at(0)

func _learn_blink(w: Dictionary) -> void:
	var wb: Variant = w["blink"]
	if wb != null:
		var at: float = wb["at"]
		var k: Variant = _blinks.get(at)
		_blinks[at] = {"at": at, "len": wb["len"], "warn": wb["warn"], "announced": bool(wb["announced"]) or (k != null and bool(k["announced"]))}
	# Only the newest state may say a scheduled blink was dropped (the car came first).
	if not is_same(latest, w):
		return
	var ht: float = w["ht"]
	for b: Dictionary in _blinks.values().duplicate():
		var bat: float = b["at"]
		if bat + float(b["len"]) + 10.0 < ht:
			_blinks.erase(bat)
		elif not bool(b["announced"]) and ht >= bat - float(b["warn"]) + TICK and (wb == null or float(wb["at"]) != bat):
			_blinks.erase(bat)

# -------------------------------------------------------------------------------------------
# A frame.

## The host time to draw at: INTERP_DELAY behind the newest snapshot this client could have, judged
## by the fastest recent arrival. Advances with the local clock, slewed by at most 10% toward that
## target, and never runs backwards (except to recover from being more than a second ahead). Null
## until a snapshot has arrived.
func _render_time(now: float) -> Variant:
	if _lags.is_empty():
		return _rt
	var lag := INF
	for l in _lags:
		lag = minf(lag, l)
	var target := now - lag - _interp_delay
	if _rt == null:
		_rt = target
	else:
		var rt: float = _rt
		var dt := maxf(0.0, now - _rt_local)
		var adv := rt + dt
		var err := target - adv
		if err > 0.3:
			adv = target
		elif err < -1.0:
			adv = target
		elif err < -0.3:
			adv = rt  # ahead: wait for it
		else:
			adv += maxf(-0.1 * dt, minf(0.1 * dt, err))
		_rt = adv if err < -1.0 else maxf(rt, adv)
	_rt_local = now
	return _rt

## [a, b, alpha] for drawing at host time `rt` (INF: the newest), or [] with nothing to draw.
func _bracket(rt: float) -> Array:
	var s := _snaps
	if s.is_empty():
		return []
	var i := s.size() - 1
	while i >= 0 and float(s[i]["ht"]) > rt:
		i -= 1
	if i < 0:
		return [s[0], s[0], 0.0]
	var a: Dictionary = s[i]
	if i + 1 >= s.size():
		return [a, a, 0.0]
	var b: Dictionary = s[i + 1]
	if int(b["depth"]) != int(a["depth"]):
		return [a, a, 0.0]
	var aht: float = a["ht"]
	var bht: float = b["ht"]
	return [a, b, maxf(0.0, minf(1.0, (rt - aht) / (bht - aht)))]

## [dark, by clock only]: whether a blink makes the screen dark, by the estimated host clock or by
## what is being drawn.
func _is_dark(host_now: float, show: Array) -> Array:
	var guard := clock.error_bound() + 0.01
	var dark := false
	var real := false
	for k: Dictionary in _blinks.values():
		var lo := float(k["at"]) - TICK
		var hi := float(k["at"]) + float(k["len"]) + TICK
		if host_now >= lo - guard and host_now <= hi + guard:
			dark = true
		if host_now >= lo and host_now <= hi:
			real = true
		if not show.is_empty() and float(show[0]["ht"]) <= hi and float(show[1]["ht"]) >= lo:
			dark = true
	return [dark, dark and not real]

## One rendered frame at local time `now`: what to draw, and (when due) the input to the host. Call
## receive() first. If the host placed the local player, `placed` says where: adopt it.
func frame(now: float, local: LocalFrame) -> Frame:
	stats.frames += 1
	if local.call:
		_calls += 1
	if local.pick_up:
		_pick_ups += 1
	latch_released = false
	if id == null or seed == null:
		if now - _last_join >= 0.5:
			_send_join(now)
		var e := Frame.new()
		e.depth = local_depth
		return e
	var placed: Move.Body = null
	if _pending_place != null and int(_pending_place["seq"]) > _place_applied:
		placed = _pending_place["body"]
		_place_applied = _pending_place["seq"]
		local_depth = _pending_place["depth"]
		_pending_place = null
	var cam := Pose.Camera.make(placed if placed != null else local.body, local.eye, local.yaw, local.pitch, local.h_fov_deg, local.v_fov_deg)
	var clock_rt: Variant = _render_time(now)
	var show := _bracket(INF if clock_rt == null else float(clock_rt))
	# The host time of the state actually drawn (behind the clock when snapshots are late).
	var rt := -1.0
	if not show.is_empty():
		var aht: float = show[0]["ht"]
		var bht: float = show[1]["ht"]
		rt = aht + (bht - aht) * float(show[2])
	var host_now := clock.host_time(now)
	var dk := _is_dark(host_now, show)
	if dk[0]:
		stats.dark_frames += 1
	if dk[1]:
		stats.guard_dark_frames += 1
	var latched_now := _update_latch(show, rt)
	var taken := _latch != null
	var blind: bool = dk[0] or taken

	# The Orderly.
	var seeing_now := false
	var report: Variant = null
	var orderly: Variant = null
	if not show.is_empty() and int(show[0]["depth"]) == local_depth and int(show[0]["tick"]) > _orderly_from:
		var a: Dictionary = show[0]
		var b: Dictionary = show[1]
		var alpha: float = show[2]
		var a_depth: int = a["depth"]
		# Pinned: until the snapshots drawn show the host has handled our last report, they are the
		# timeline it is about to abandon (it puts the Orderly back where we froze it), so keep that.
		if _pin != null and (int(_pin["depth"]) != a_depth or int(a.get("ackSeen", 0)) >= int(_pin["id"])):
			_pin = null
		var pinned := _pin != null
		var cand: Dictionary = _pin["pose"] if pinned else Pose.lerp_pose(a["orderly"], b["orderly"], alpha)
		var plan := Session.plan_for(seed, a_depth)
		var open := Session.doors_open_in(a["phase"]) or Session.doors_open_in(b["phase"]) or (latest != null and Session.doors_open_in(latest["phase"]))
		var same := _drawn != null and _drawn_depth == a_depth
		if _frozen and same and _sees(plan, cam, _drawn, open, blind):
			# Seen: held exactly where it is, whatever the snapshots say.
			seeing_now = true
		elif _frozen and same and _sees(plan, cam, cand, open, blind):
			# The held pose has left the view but the snapshots' pose is in it: keep holding until
			# neither is, so the jump between them never happens on screen.
			pass
		else:
			if _frozen and _drawn != null:
				var d: Dictionary = _drawn
				stats.releases += 1
				var jump := M.hypot3(float(d["x"]) - float(cand["x"]), float(d["y"]) - float(cand["y"]), float(d["z"]) - float(cand["z"]))
				stats.max_release_jump = maxf(stats.max_release_jump, jump)
				if jump > 0.25:
					stats.big_releases += 1
			if _sees(plan, cam, cand, open, blind):
				_frozen = true
				seeing_now = true
				if not pinned:
					report = _make_report(a, b, alpha, cand)
			else:
				_frozen = false
			if _drawn == null or not Pose.same_pose(_drawn, cand):
				_drawn = cand
		_drawn_depth = a_depth
		orderly = _drawn
	else:
		_drawn = null
		_frozen = false
	if seeing_now:
		_seeing_latch = true
	if seeing_now and _wind_up_on:
		_wind_up_saw = true

	# Everyone else.
	var players: Array[Dictionary] = []
	if not show.is_empty():
		var a: Dictionary = show[0]
		var b: Dictionary = show[1]
		var alpha: float = show[2]
		for pa: Dictionary in a["players"]:
			if pa["id"] == id:
				continue
			var pb := pa
			for q: Dictionary in b["players"]:
				if q["id"] == pa["id"]:
					pb = q
					break
			var ba: Move.Body = pa["body"]
			var bb: Move.Body = pb["body"]
			var k := alpha if ba.level == bb.level else 0.0
			var pay: float = pa["yaw"]
			var pby: float = pb["yaw"]
			var pap: float = pa["pitch"]
			var pbp: float = pb["pitch"]
			players.append({
				"id": pa["id"],
				"body": Move.Body.make(ba.x + (bb.x - ba.x) * k, ba.z + (bb.z - ba.z) * k, ba.level, ba.y + (bb.y - ba.y) * k),
				"yaw": pay + _angle_diff(pay, pby) * k,
				"pitch": pap + (pbp - pap) * k,
				"active": pa["active"],
				"status": pa["status"],
				"gait": pa["gait"] if k < 0.5 else pb["gait"],
			})

	# The input: every INPUT_INTERVAL, and at once on a new sighting.
	if report != null or latched_now or now - _last_send >= _input_interval - 1e-9:
		_send(now, cam, local, rt)
	var shown: Variant = null if taken else orderly
	var f := Frame.new()
	f.dark = blind
	f.orderly = shown
	f.visible = shown != null and not blind
	f.held = _frozen
	f.seeing = seeing_now
	f.taken = taken
	f.depth = int(show[0]["depth"]) if not show.is_empty() else local_depth
	f.players = players
	f.render_time = rt
	f.placed = placed
	return f

static func _sees(plan: Variant, cam: Pose.Camera, p: Dictionary, open: bool, blind: bool) -> bool:
	return not blind and Session.camera_sees(plan, cam, p, open)

func _end_latch() -> void:
	_latch = null
	_wind_up_on = false
	_wind_up_saw = false
	_armed_end = null

func _mine(w: Variant) -> bool:
	if w == null:
		return false
	var o: Dictionary = w["orderly"]
	return o["mode"] == "windUp" and o.has("windUp") and o["windUp"]["target"] == id

## The taken latch, per frame, from the snapshots being drawn (`show`, at displayed time `rt`) and the
## newest one received. Returns true on the frame it fires (the confirming input goes at once).
func _update_latch(show: Array, rt: float) -> bool:
	var newest: Variant = latest
	if _latch != null:
		var l: Dictionary = _latch
		if _caught_at > float(l["armed"]):
			# The catch happened: blind until the frame drawn is past it.
			if rt >= _caught_at - 1e-9:
				_end_latch()
			return false
		var pending: bool = newest != null and int(newest["depth"]) == int(l["depth"]) and (_mine(newest) or newest["orderly"]["mode"] == "dormant")
		var elapsed := rt - float(l["rt"])
		if local_depth != int(l["depth"]) or not pending or (elapsed > LATCH_IDLE and not _mine(newest)) or elapsed > LATCH_MAX:
			_end_latch()
			stats.false_latches += 1
			latch_released = true
		return false
	if show.is_empty() or int(show[0]["depth"]) != local_depth:
		_wind_up_on = false
		_wind_up_saw = false
		_armed_end = null
		return false
	var a: Dictionary = show[0]
	var on_me := _mine(a)
	if on_me:
		if not _wind_up_on:
			_wind_up_on = false
			_wind_up_saw = false
			_armed_end = null
			_wind_up_on = true
		var w: Dictionary = a["orderly"]["windUp"]
		if _armed_end == null and float(w["left"]) <= TICK + 1e-6:
			_armed_end = float(a["ht"]) + float(w["left"])
	var end: Variant = _armed_end
	# The displayed wind-up has reached its end unseen. Only if the host's snapshots agree it ran to
	# its end: still pending (held for our confirmation), or the catch made.
	var due: bool = _wind_up_on and not _wind_up_saw and end != null and float(end) > _latched_end + 1e-6 and rt >= float(end) - 1e-6
	var ran_to_end: bool = end != null and (_caught_at >= float(end) - 1e-6 or (newest != null and int(newest["depth"]) == int(a["depth"]) and (_mine(newest) or newest["orderly"]["mode"] == "dormant")))
	if not on_me:
		_wind_up_on = false
		_wind_up_saw = false
		_armed_end = null
	if not due or not ran_to_end or end == null:
		return false
	_latch = {"rt": rt, "armed": float(end) - TICK, "depth": int(a["depth"])}
	_latched_end = end
	stats.latches += 1
	return true

## Forgets the Orderly as drawn (and any pose held because it was in view): the next frame draws it
## from the snapshots. For a test hook's teleport, which is not a move the rule has to hide.
func forget_orderly() -> void:
	_orderly_from = int(latest["tick"]) if latest != null else -1
	_drawn = null
	_frozen = false
	_pin = null
	_drawn_depth = -1

## The game's own tank, corrected toward the host's: by how far the host's tank after input `ackIn`
## differs from what this game had when it sent that input. Call once a frame with the current copy.
func correct_stamina(local: Stamina.Stamina) -> Stamina.Stamina:
	if not _host_tank_fresh or host_stamina == null:
		return local
	_host_tank_fresh = false
	if not _tank_at.has(_host_tank_seq):
		return local
	var sent: Stamina.Stamina = _tank_at[_host_tank_seq]
	var host := host_stamina
	var d := host.level - sent.level
	var wind_change := host.winded != sent.winded
	if absf(d) < TANK_EPS and not wind_change:
		return local
	var fix := func(st: Stamina.Stamina) -> Stamina.Stamina:
		var out := Stamina.Stamina.new()
		out.level = maxf(0.0, minf(1.0, st.level + (0.0 if absf(d) < TANK_EPS else d)))
		out.winded = st.winded
		if wind_change:
			out.winded = host.winded and out.level < Stamina.WINDED_UNTIL
		return out
	# Later inputs were sent from the uncorrected copy: move them too, or the next snapshot corrects twice.
	for k: int in _tank_at.keys():
		if k >= _host_tank_seq:
			_tank_at[k] = fix.call(_tank_at[k])
	return fix.call(local)

func _make_report(a: Dictionary, b: Dictionary, alpha: float, pose: Dictionary) -> Dictionary:
	_report_id += 1
	var r := {"id": _report_id, "depth": a["depth"], "a": a["tick"], "b": b["tick"], "alpha": Protocol.q3(alpha), "pose": pose}
	_unacked.append(r)
	_pin = {"pose": pose, "id": r["id"], "depth": a["depth"]}
	stats.reports += 1
	return r

func _send(now: float, cam: Pose.Camera, local: LocalFrame, rt: float) -> void:
	_seq += 1
	var seen: Array = _unacked.slice(maxi(0, _unacked.size() - 2))
	var m := {
		"type": "input", "seq": _seq, "ct": now, "body": cam.body, "eye": cam.eye, "yaw": cam.yaw, "pitch": cam.pitch,
		"hFovDeg": cam.h_fov_deg, "vFovDeg": cam.v_fov_deg, "raised": local.raised, "holdDoors": local.hold_doors,
		"gait": local.gait, "seeing": _seeing_latch, "calls": _calls, "pickUps": _pick_ups, "ackEvent": _ev_next - 1,
		"ackHt": _ack_ht if not is_inf(_ack_ht) else -1.0, "renderTime": rt, "placeAck": _place_applied, "seen": seen,
	}
	if local.stamina != null:
		var copy := Stamina.Stamina.new()
		copy.level = local.stamina.level
		copy.winded = local.stamina.winded
		_tank_at[_seq] = copy
		_tank_at.erase(_seq - TANK_KEEP)
	var text := Protocol.encode(m)
	_transport.send(host_id, text)
	_last_send = now
	_seeing_latch = false
	stats.inputs += 1
	stats.input_bytes += text.length()
	stats.max_input_bytes = maxi(stats.max_input_bytes, text.length())
	if keep_sizes:
		input_sizes.append(text.length())

static func _angle_diff(a: float, b: float) -> float:
	var d := fmod(b - a, 2.0 * PI)
	if d > PI:
		d -= 2.0 * PI
	if d < -PI:
		d += 2.0 * PI
	return d
