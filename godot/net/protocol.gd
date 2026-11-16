# The wire protocol between the host (the home server) and the players' machines. Port of
# src/net/protocol.ts: every message is a JSON text, versioned, and the two 20 Hz messages (input and
# snapshot) travel in the same compact positional-array form as the TypeScript host wrote them.
# Nothing here touches the network; transports move strings.
#
# Units: positions in metres, angles in radians, times in seconds. "Host time" is the run's own clock
# (RunState.t): the host's tick k is at host time k * TICK. Client times are the client's local clock.
#
# Quantisation: positions to the centimetre, angles and clocks to the millisecond. A quantised number
# survives the JSON round trip bit for bit (net/jsjson.gd writes and reads numbers exactly as
# JavaScript does), so the host can compute exactly what a client drew from the same quantised poses
# the client was sent (see Pose.lerp_pose and host.gd).
#
# The readable (decoded) messages are Dictionaries with the TypeScript (camelCase) keys. Bodies are
# Move.Body; poses are Dictionaries {x, y, z, level, yaw, anim, animTime} (net/pose.gd); phases,
# statuses, gaits, needles and modes are Strings; events are plain Dictionaries (bodies inside them
# are {x, z, level, y} Dictionaries, as JSON.parse gave them in TypeScript). Every number that came
# off the wire is a float; counters (tick, seq, depth, ...) are ints.
#
# decode() validates everything it accepts (types, ranges, finite numbers): a client's input that
# does not fit the protocol exactly is null, and never reaches the rules.
extends RefCounted

const Pose = preload("res://net/pose.gd")
const JsJson = preload("res://net/jsjson.gd")
const Move = preload("res://sim/move.gd")
const Entity = preload("res://sim/entity.gd")
const Run = preload("res://sim/run.gd")
const TapeLib = preload("res://sim/tape.gd")
const Stamina = preload("res://sim/stamina.gd")

const PROTOCOL_VERSION := 1

const PHASES: Array[String] = ["arriving", "unloading", "away", "coming", "boarding", "riding", "ended"]
const ANIMS: Array[String] = ["idle", "walk", "duck", "reach"]
const MODES: Array[String] = ["waiting", "hunting", "windUp", "dormant"]
const NEEDLES: Array[String] = ["off", "idle", "dormant", "recording", "contaminated"]
const STATUSES: Array[String] = ["ok", "caught", "leftBehind"]
const GAITS: Array[String] = ["walk", "creep", "sprint"]

## Limits on what a client may send (the server refuses anything outside them).
const MAX_NAME := 32
const MAX_SEEN := 8
const MAX_COORD := 10000.0
const MAX_CLOCK := 1e9
const MAX_COUNT := 2147483647

# ---------------------------------------------------------------------------------------------
# Numbers.

static func q2(x: float) -> float:
	return Pose.q2(x)

static func q3(x: float) -> float:
	return Pose.q3(x)

static func q_body(b: Move.Body) -> Move.Body:
	return Move.Body.make(q2(b.x), q2(b.z), b.level, q2(b.y))

## Math.floor(x * 1000) / 1000 (rounded down: a bound stays a bound).
static func floor3(x: float) -> float:
	var r := floorf(x * 1000.0) / 1000.0
	return 0.0 if r == 0.0 else r

# ---------------------------------------------------------------------------------------------
# The Orderly as drawn.

## The snapshot form of the logic's Orderly (quantised): a pose plus speed, frozen, mode, windUp.
static func orderly_snap(o: Entity.OrderlyState) -> Dictionary:
	var d := {
		"x": q2(o.body.x), "y": q2(o.body.y), "z": q2(o.body.z), "level": o.body.level, "yaw": q3(o.yaw),
		"anim": String(o.anim), "animTime": q3(o.anim_time), "speed": q2(o.speed), "frozen": o.held, "mode": String(o.mode),
	}
	if o.mode == &"windUp" and o.wind_up_target != null:
		d["windUp"] = {"target": String(o.wind_up_target), "left": q3(o.wind_up_left)}
	return d

# ---------------------------------------------------------------------------------------------
# Plain data (what JSON.parse(JSON.stringify(x)) gives in TypeScript).

static func body_plain(b: Move.Body) -> Dictionary:
	return {"x": b.x, "z": b.z, "level": b.level, "y": b.y}

static func reading_plain(r: TapeLib.Reading) -> Dictionary:
	return {"id": r.id, "playerId": r.player_id, "entityId": r.entity_id, "trait": String(r.trait_name), "value": r.value,
		"duration": r.duration, "peakRate": r.peak_rate, "closedAt": r.closed_at}

static func summary_plain(s: Run.RunSummary) -> Variant:
	if s == null:
		return null
	var tapes: Array = []
	for t in s.tapes:
		tapes.append(t)
	return {"depth": s.depth, "readings": s.readings, "total": s.total, "shares": s.shares.duplicate(), "tapes": tapes, "wiped": s.wiped}

## An event (or anything in one) as plain data.
static func plain(v: Variant) -> Variant:
	if v is StringName:
		return String(v)
	if v is Move.Body:
		return body_plain(v)
	if v is TapeLib.Reading:
		return reading_plain(v)
	if v is Run.RunSummary:
		return summary_plain(v)
	if v is float and (is_inf(v) or is_nan(v)):
		return null
	if v is Array:
		var out: Array = []
		for x: Variant in v:
			out.append(plain(x))
		return out
	if v is Dictionary:
		var d: Dictionary = v
		var out := {}
		for k: Variant in d:
			out[k] = plain(d[k])
		return out
	return v

# ---------------------------------------------------------------------------------------------
# The compact wire form.

static func _enc_body(b: Move.Body) -> Array:
	return [q2(b.x), q2(b.z), q2(b.y), b.level]

static func _enc_pose(p: Dictionary) -> Array:
	return [p["x"], p["z"], p["y"], p["level"], p["yaw"], ANIMS.find(String(p["anim"])), p["animTime"]]

static func _enc_tape(t: Dictionary) -> Array:
	return [t["id"], t["owner"], t["readings"], q2(t["total"])]

static func enc_world(w: Dictionary) -> Array:
	var o: Dictionary = w["orderly"]
	var blink: Variant = 0
	if w["blink"] != null:
		var b: Dictionary = w["blink"]
		blink = [b["at"], 1 if b["announced"] else 0, b["endsAt"], b["len"], b["warn"], 1 if b["blackout"] else 0]
	var ow := _enc_pose(o)
	ow.append(o["speed"])
	ow.append(1 if o["frozen"] else 0)
	ow.append(MODES.find(String(o["mode"])))
	if o.has("windUp"):
		ow.append(o["windUp"]["target"])
		ow.append(o["windUp"]["left"])
	var players: Array = []
	for p: Dictionary in w["players"]:
		var side: Variant = p["side"]
		var flags := (1 if p["active"] else 0) | (2 if p["aboard"] else 0) | (4 if p["connected"] else 0) \
			| (8 if side == "bank" else (16 if side == "down" else 0)) | (STATUSES.find(String(p["status"])) << 5) | (GAITS.find(String(p["gait"])) << 7)
		var row: Array = [p["id"]]
		row.append_array(_enc_body(p["body"]))
		row.append(q3(p["yaw"]))
		row.append(q3(p["pitch"]))
		row.append(flags)
		players.append(row)
	var crew: Array = []
	for m: Dictionary in w["crew"]:
		var carrying: Array = []
		for t: Dictionary in m["carrying"]:
			carrying.append(_enc_tape(t))
		crew.append([m["id"], NEEDLES.find(String(m["needle"])), 1 if m["raised"] else 0, q2(m["open"]), q2(m["rate"]), q2(m["tickHz"]), _enc_tape(m["tape"]), carrying])
	var fl: Array = []
	for f: Dictionary in w["floor"]:
		var row := _enc_tape(f)
		row.append(_enc_body(f["at"]))
		fl.append(row)
	return [w["tick"], w["ht"], PHASES.find(String(w["phase"])), w["depth"], q2(w["timer"]), w["floorsAway"], q2(w["bellLeft"]), q2(w["holdLeft"]),
		1 if w["held"] else 0, blink, ow, players, crew, fl, w["summary"]]

## The JSON text of a world snapshot (computed once per tick, shared by every client's snapshot).
static func world_json(w: Dictionary) -> String:
	return JsJson.stringify(enc_world(w))

## A snapshot's wire text. `head` has st, ackIn, echo, ackSeen, evFrom, place, stamina; `event_texts`
## are the JSON texts of its events; `world` is world_json() of the shared part.
static func snapshot_text(head: Dictionary, event_texts: PackedStringArray, world: String) -> String:
	var echo: Variant = head["echo"]
	var place: Variant = head["place"]
	var st: Variant = head.get("stamina")
	var parts := PackedStringArray([
		JsJson.num(head["st"]), str(head["ackIn"]),
		JsJson.stringify(echo) if echo != null else "0",
		str(head["ackSeen"]), str(head["evFrom"]),
		"[" + ",".join(event_texts) + "]",
		JsJson.stringify([place["seq"], place["depth"], _enc_body(place["body"])]) if place != null else "0",
		JsJson.stringify([q3(st.level), 1 if st.winded else 0]) if st != null else "0",
	])
	return "[%d,\"S\",[%s],%s]" % [PROTOCOL_VERSION, ",".join(parts), world]

## Serialises a message (input, join, welcome, leave, ping, pong) to its wire text.
static func encode(m: Dictionary) -> String:
	match String(m["type"]):
		"input":
			var seen: Array = []
			for r: Dictionary in m["seen"]:
				seen.append([r["id"], r["depth"], r["a"], r["b"], q3(r["alpha"]), _enc_pose(r["pose"])])
			var flags := (1 if m["raised"] else 0) | (2 if m["holdDoors"] else 0) | (4 if m["seeing"] else 0) | (GAITS.find(String(m.get("gait", "walk"))) << 3)
			return JsJson.stringify([PROTOCOL_VERSION, "I", m["seq"], floor3(m["ct"]), _enc_body(m["body"]), q2(m["eye"]), q3(m["yaw"]), q3(m["pitch"]),
				q2(m["hFovDeg"]), q2(m["vFovDeg"]), flags, m["calls"], m["pickUps"], m["ackEvent"], m["ackHt"], floor3(m["renderTime"]), m["placeAck"], seen])
		"join":
			return JsJson.stringify([PROTOCOL_VERSION, "J", m["name"], m["ct"]])
		"welcome":
			return JsJson.stringify([PROTOCOL_VERSION, "W", m["you"], m["seed"], 1 if m["playing"] else 0, m["evFrom"], enc_world(m["world"])])
		"leave":
			return JsJson.stringify([PROTOCOL_VERSION, "L"])
		"ping":
			return JsJson.stringify([PROTOCOL_VERSION, "P", m["ct"]])
		"pong":
			return JsJson.stringify([PROTOCOL_VERSION, "O", m["ct"], m["hr"], m["st"]])
	push_error("protocol: cannot encode %s" % str(m["type"]))
	return ""

# ---------------------------------------------------------------------------------------------
# Reading (and validating) the wire form.

class _V:
	var bad := false

static func _is_num(v: Variant) -> bool:
	return (v is float and not is_nan(v) and not is_inf(v)) or v is int

static func _f(c: _V, v: Variant, lo: float = -MAX_CLOCK, hi: float = MAX_CLOCK) -> float:
	if not _is_num(v) or float(v) < lo or float(v) > hi:
		c.bad = true
		return 0.0
	return float(v)

## An integral number in [lo, hi].
static func _i(c: _V, v: Variant, lo: int, hi: int) -> int:
	if not _is_num(v) or float(v) != floorf(float(v)) or float(v) < lo or float(v) > hi:
		c.bad = true
		return 0
	return int(v)

static func _s(c: _V, v: Variant, max_len: int = 64) -> String:
	if not v is String or (v as String).length() > max_len:
		c.bad = true
		return ""
	return v

static func _a(c: _V, v: Variant, min_size: int, max_size: int) -> Array:
	if not v is Array or (v as Array).size() < min_size or (v as Array).size() > max_size:
		c.bad = true
		return []
	return v

static func _code(c: _V, list: Array[String], v: Variant) -> String:
	var k := _i(c, v, 0, list.size() - 1)
	return "" if c.bad else list[k]

static func _dec_body(c: _V, w: Variant) -> Move.Body:
	var a := _a(c, w, 4, 4)
	if c.bad:
		return null
	var x := _f(c, a[0], -MAX_COORD, MAX_COORD)
	var z := _f(c, a[1], -MAX_COORD, MAX_COORD)
	var y := _f(c, a[2], -MAX_COORD, MAX_COORD)
	var level := _i(c, a[3], 0, 1)
	return Move.Body.make(x, z, level, y)

static func _dec_pose(c: _V, w: Variant, min_size: int = 7, max_size: int = 7) -> Dictionary:
	var a := _a(c, w, min_size, max_size)
	if c.bad:
		return {}
	return {"x": _f(c, a[0], -MAX_COORD, MAX_COORD), "z": _f(c, a[1], -MAX_COORD, MAX_COORD), "y": _f(c, a[2], -MAX_COORD, MAX_COORD),
		"level": _i(c, a[3], 0, 1), "yaw": _f(c, a[4], -MAX_COORD, MAX_COORD), "anim": _code(c, ANIMS, a[5]), "animTime": _f(c, a[6])}

static func _dec_tape(c: _V, w: Variant, min_size: int = 4) -> Dictionary:
	var a := _a(c, w, min_size, min_size)
	if c.bad:
		return {}
	return {"id": _s(c, a[0]), "owner": _s(c, a[1]), "readings": _i(c, a[2], 0, MAX_COUNT), "total": _f(c, a[3])}

static func _opt_num(c: _V, v: Variant) -> Variant:
	return null if v == null else _f(c, v)

static func dec_world(c: _V, w: Variant) -> Dictionary:
	var a := _a(c, w, 15, 15)
	if c.bad:
		return {}
	var blink: Variant = null
	if not (_is_num(a[9]) and float(a[9]) == 0.0):
		var b := _a(c, a[9], 6, 6)
		if c.bad:
			return {}
		blink = {"at": _f(c, b[0]), "announced": _f(c, b[1]) == 1.0, "endsAt": _opt_num(c, b[2]), "len": _f(c, b[3]), "warn": _f(c, b[4]), "blackout": _f(c, b[5]) == 1.0}
	var ow := _a(c, a[10], 10, 12)
	if c.bad or ow.size() == 11:
		c.bad = true
		return {}
	var orderly := _dec_pose(c, ow, 10, 12)
	orderly["speed"] = _f(c, ow[7])
	orderly["frozen"] = _f(c, ow[8]) == 1.0
	orderly["mode"] = _code(c, MODES, ow[9])
	if ow.size() > 11:
		orderly["windUp"] = {"target": _s(c, ow[10]), "left": _f(c, ow[11])}
	var players: Array = []
	for pw: Variant in _a(c, a[11], 0, 64):
		var p := _a(c, pw, 8, 8)
		if c.bad:
			return {}
		var f := _i(c, p[7], 0, 1023)
		players.append({
			"id": _s(c, p[0]), "body": _dec_body(c, p.slice(1, 5)), "yaw": _f(c, p[5]), "pitch": _f(c, p[6]),
			"active": (f & 1) != 0, "aboard": (f & 2) != 0, "connected": (f & 4) != 0,
			"side": "bank" if f & 8 else ("down" if f & 16 else null),
			"status": _code(c, STATUSES, (f >> 5) & 3), "gait": _code(c, GAITS, (f >> 7) & 3),
		})
	var crew: Array = []
	for mw: Variant in _a(c, a[12], 0, 64):
		var m := _a(c, mw, 8, 8)
		if c.bad:
			return {}
		var carrying: Array = []
		for tw: Variant in _a(c, m[7], 0, 256):
			carrying.append(_dec_tape(c, tw))
		crew.append({"id": _s(c, m[0]), "needle": _code(c, NEEDLES, m[1]), "raised": _f(c, m[2]) == 1.0, "open": _f(c, m[3]),
			"rate": _f(c, m[4]), "tickHz": _f(c, m[5]), "tape": _dec_tape(c, m[6]), "carrying": carrying})
	var fl: Array = []
	for fw: Variant in _a(c, a[13], 0, 1024):
		var fa := _a(c, fw, 5, 5)
		if c.bad:
			return {}
		var t := _dec_tape(c, fa.slice(0, 4))
		t["at"] = _dec_body(c, fa[4])
		fl.append(t)
	var summary: Variant = a[14]
	if summary != null and not summary is Dictionary:
		c.bad = true
	return {
		"tick": _i(c, a[0], 0, MAX_COUNT), "ht": _f(c, a[1]), "phase": _code(c, PHASES, a[2]), "depth": _i(c, a[3], 0, 100000),
		"timer": _f(c, a[4]), "floorsAway": null if a[5] == null else _i(c, a[5], -100000, 100000), "bellLeft": _f(c, a[6]),
		"holdLeft": _f(c, a[7]), "held": _f(c, a[8]) == 1.0, "blink": blink, "orderly": orderly, "players": players, "crew": crew,
		"floor": fl, "summary": summary,
	}

static func _dec_report(c: _V, w: Variant) -> Dictionary:
	var a := _a(c, w, 6, 6)
	if c.bad:
		return {}
	return {"id": _i(c, a[0], 1, MAX_COUNT), "depth": _i(c, a[1], 0, 100000), "a": _i(c, a[2], 0, MAX_COUNT), "b": _i(c, a[3], 0, MAX_COUNT),
		"alpha": _f(c, a[4], 0.0, 1.0), "pose": _dec_pose(c, a[5])}

## Parses wire text; null for anything malformed, out of range or from another protocol version.
static func decode(text: String) -> Variant:
	var p := JsJson.parse(text)
	if not p.ok or not p.value is Array:
		return null
	var a: Array = p.value
	if a.size() < 2 or not _is_num(a[0]) or float(a[0]) != PROTOCOL_VERSION or not a[1] is String:
		return null
	var c := _V.new()
	var out: Dictionary
	match String(a[1]):
		"S":
			if a.size() != 4:
				return null
			var h := _a(c, a[2], 7, 8)
			if c.bad:
				return null
			out = dec_world(c, a[3])
			if c.bad:
				return null
			out["type"] = "snap"
			out["st"] = _f(c, h[0])
			out["ackIn"] = _i(c, h[1], 0, MAX_COUNT)
			if _is_num(h[2]) and float(h[2]) == 0.0:
				out["echo"] = null
			else:
				var e := _a(c, h[2], 2, 2)
				out["echo"] = [_f(c, e[0]), _f(c, e[1])] if not c.bad else null
			out["ackSeen"] = _i(c, h[3], 0, MAX_COUNT)
			out["evFrom"] = _i(c, h[4], 0, MAX_COUNT)
			var evs := _a(c, h[5], 0, 100000)
			for e: Variant in evs:
				if not e is Dictionary:
					c.bad = true
			out["events"] = evs
			if _is_num(h[6]) and float(h[6]) == 0.0:
				out["place"] = null
			else:
				var pl := _a(c, h[6], 3, 3)
				out["place"] = {"seq": _i(c, pl[0], 0, MAX_COUNT), "depth": _i(c, pl[1], 0, 100000), "body": _dec_body(c, pl[2])} if not c.bad else null
			out["stamina"] = null
			if h.size() > 7 and not (_is_num(h[7]) and float(h[7]) == 0.0):
				var sa := _a(c, h[7], 2, 2)
				if not c.bad:
					var st := Stamina.Stamina.new()
					st.level = maxf(0.0, minf(1.0, _f(c, sa[0])))
					st.winded = _f(c, sa[1]) == 1.0
					out["stamina"] = st
		"I":
			if a.size() != 18:
				return null
			var f := _i(c, a[10], 0, 31)
			var gait := (f >> 3) & 3
			if gait > 2:
				return null
			var seen: Array = []
			for r: Variant in _a(c, a[17], 0, MAX_SEEN):
				seen.append(_dec_report(c, r))
			out = {
				"type": "input", "seq": _i(c, a[2], 1, MAX_COUNT), "ct": _f(c, a[3]), "body": _dec_body(c, a[4]),
				"eye": _f(c, a[5], 0.0, 10.0), "yaw": _f(c, a[6], -MAX_COORD, MAX_COORD), "pitch": _f(c, a[7], -MAX_COORD, MAX_COORD),
				"hFovDeg": _f(c, a[8], 1.0, 180.0), "vFovDeg": _f(c, a[9], 1.0, 180.0),
				"raised": (f & 1) != 0, "holdDoors": (f & 2) != 0, "seeing": (f & 4) != 0, "gait": GAITS[gait],
				"calls": _i(c, a[11], 0, MAX_COUNT), "pickUps": _i(c, a[12], 0, MAX_COUNT), "ackEvent": _i(c, a[13], 0, MAX_COUNT),
				"ackHt": _f(c, a[14]), "renderTime": _f(c, a[15]), "placeAck": _i(c, a[16], 0, MAX_COUNT), "seen": seen,
			}
		"J":
			if a.size() != 4:
				return null
			out = {"type": "join", "name": _s(c, a[2], MAX_NAME), "ct": _f(c, a[3])}
		"W":
			if a.size() != 7:
				return null
			out = {"type": "welcome", "you": _s(c, a[2]), "seed": _s(c, a[3], 256), "playing": _f(c, a[4]) == 1.0, "evFrom": _i(c, a[5], 0, MAX_COUNT), "world": dec_world(c, a[6])}
		"L":
			if a.size() != 2:
				return null
			out = {"type": "leave"}
		"P":
			if a.size() != 3:
				return null
			out = {"type": "ping", "ct": _f(c, a[2])}
		"O":
			if a.size() != 5:
				return null
			out = {"type": "pong", "ct": _f(c, a[2]), "hr": _f(c, a[3]), "st": _f(c, a[4])}
		_:
			return null
	return null if c.bad else out

## Size of a message on the wire in bytes (its UTF-8 text).
static func message_bytes(text: String) -> int:
	return text.to_utf8_buffer().size()
