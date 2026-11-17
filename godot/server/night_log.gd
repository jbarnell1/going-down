# The night's log: one JSON object per line on standard output, beside the server's plain lines. The
# container's file system is read-only (only a 1 MB /tmp), so standard output is the store: Docker keeps
# it (`docker logs going-down`) until the container is removed, and tools/night_logs.mjs fetches and
# summarises it. NOTE: run-on-host.sh removes the old container, so fetch the logs BEFORE a redeploy
# (tools/hotfix.mjs prints the commands in that order).
#
# Every line: {"gd":1,"t":"<UTC time>","night":"<id of this server start>","ev":"<event>", ...}
#   start    the server is up: build, port
#   join     a player is in: id, name, build, addr (a salted hash, never the address: net/ws_server.gd)
#   name     a player renamed: id, name
#   leave    a player left: id, name, code, reason (WebSocket close), secs connected
#   refused  connections refused since the last line, by kind (passphrase, full, version, flood, ...)
#   run      a run started: run (its number), seed, players (names)
#   game     what happened in the run: type (rodeDown, carArrived, carLeft, caught, downed, healed, out,
#            leftBehind, wiped, banked, quotaMet, dayEnded, newDay, rodeUp), run, t (host time), depth,
#            player (a name) and a few plain fields of the event
#   runEnd   the run is over: run
#   tick     the host's cost since the last one: ticks, ms (mean a tick), worst (ms), players
#   hb       a client's heartbeat: id, name, data (build, os, gpu, frame times, ping, floor, phase, ...)
#   clog     a client's error or warning line: id, name, line
#   report   part of a client's F9 report or crash tail: id, name, kind (rep|crash), rid, part, parts, body
#   dropped  client lines over the rate limit (or not decoding) in the last minute: id, name, counts
#   serr     an engine or script error on the server itself: kind, text
# Never in it: the passphrase (the server keeps only its hash), an address, a face, anything a client
# sends that is not a telemetry message. What a client sends is only ever logged (as JSON text, escaped),
# never parsed into anything that acts.
extends RefCounted

const Protocol = preload("res://net/protocol.gd")
const WsServer = preload("res://net/ws_server.gd")
const Room = preload("res://server/room.gd")
const Host = preload("res://net/host.gd")

## Per player and per WINDOW seconds: heartbeats, log lines, report parts (F9 and crash share it).
const WINDOW := 60.0
const LIMITS := {"hb": 4, "log": 20, "rep": 16}
## Server errors logged per WINDOW (the rest are counted in the next serr line).
const SERR_PER_WINDOW := 30
## The rules' events that go in the log, and the plain fields kept from them.
const GAME_EVENTS: Array[String] = ["rodeDown", "carArrived", "carLeft", "caught", "downed", "healed", "out", "leftBehind",
	"wiped", "banked", "quotaMet", "dayEnded", "newDay", "rodeUp"]
const GAME_FIELDS: Array[String] = ["reason", "by", "day", "dayIndex", "earned", "needed", "wait", "depth"]
## What a heartbeat may carry: key -> max length of a string value (0: numbers only).
const HB_KEYS := {"build": 64, "os": 40, "gpu": 80, "renderer": 40, "mode": 16, "place": 24, "phase": 16, "depth": 0,
	"fps": 0, "avg_ms": 0, "worst_ms": 0, "ping_ms": 0, "errors": 0, "warnings": 0, "mem_mb": 0, "up_s": 0, "dropped": 0}

## Engine and script errors on the server (GDScript has no exceptions; a Logger sees every error).
## Called on any thread, so it only buffers; after() writes them out.
class ErrorTap extends Logger:
	var mutex := Mutex.new()
	var buf: Array = []
	var lost := 0

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		mutex.lock()
		if buf.size() < 200:
			buf.append([["error", "warning", "script", "shader"][clampi(error_type, 0, 3)], "%s (%s:%d %s)" % [rationale if not rationale.is_empty() else code, file, line, function]])
		else:
			lost += 1
		mutex.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	func take() -> Array:
		mutex.lock()
		var out := buf
		buf = []
		if lost > 0:
			out.append(["error", "%d more server errors not logged" % lost])
			lost = 0
		mutex.unlock()
		return out

## This server start's id (in every line).
var night := ""
## Lines written (tests read it).
var lines := 0
var tap := ErrorTap.new()
var _print: Callable
var _rates := {}  # id -> {bucket: [window start, count]}
var _dropped := {}  # id -> {kind: count}
var _names := {}  # id -> name, of the players in
var _since := {}  # id -> now at join
var _host: Host = null
var _epoch := 0
var _ev_index := 0
var _refused := {}
var _last_tick := {"ticks": 0, "us": 0}
var _window_at := 0.0
var _serr_in_window := 0
var _now := 0.0

## `print_fn`: Callable(String) for each line (tests collect them); empty for print().
func _init(print_fn: Callable = Callable()) -> void:
	_print = print_fn
	night = Crypto.new().generate_random_bytes(4).hex_encode()

func emit(ev: String, fields: Dictionary = {}) -> void:
	var d := {"gd": 1, "t": Time.get_datetime_string_from_system(true) + "Z", "night": night, "ev": ev}
	d.merge(fields)
	# Keys in the order written ("gd" first, which is how tools/night_logs.mjs finds a line).
	var text := JSON.stringify(d, "", false)
	lines += 1
	if _print.is_valid():
		_print.call(text)
	else:
		print(text)

func started(build: String, port: int) -> void:
	emit("start", {"build": build, "port": port})

## One loop of the server: the door's events (telemetry taken out here, so the room never sees it), the
## room, then what changed.
func pump(ws: WsServer, room: Room, now: float) -> void:
	before(ws, now)
	room.update(now)
	after(ws, room, now)

func before(ws: WsServer, now: float) -> void:
	_now = now
	var keep: Array[Dictionary] = []
	for e in ws.events:
		var kind := String(e["kind"])
		if kind == "message" and String(e["data"]).begins_with("t|"):
			client_line(String(e["id"]), String(e["data"]).substr(2), now)
			continue
		if kind == "joined":
			var id := String(e["id"])
			_names[id] = String(e["name"])
			_since[id] = now
			emit("join", {"id": id, "name": e["name"], "build": e.get("build", ""), "addr": e.get("addr", "")})
		keep.append(e)
	ws.events = keep

func after(ws: WsServer, room: Room, now: float) -> void:
	var people: Dictionary = room.people
	for id: String in _names.keys():
		if not people.has(id):
			var why: Array = ws.closed.get(id, [0, ""])
			ws.closed.erase(id)
			emit("leave", {"id": id, "name": _names[id], "code": why[0], "reason": why[1], "secs": snappedf(now - float(_since.get(id, now)), 0.1)})
			_names.erase(id)
			_since.erase(id)
			_rates.erase(id)
		elif String(people[id]) != String(_names[id]):
			_names[id] = String(people[id])
			emit("name", {"id": id, "name": _names[id]})
	var host: Host = room.host
	if host != _host:
		if _host != null:
			_game_events(_host)
			emit("runEnd", {"run": _epoch})
		_host = host
		_ev_index = 0
		if host != null:
			_epoch = room.epoch
			var names: Array = []
			for id: String in people:
				names.append(people[id])
			emit("run", {"run": _epoch, "seed": host.seed, "players": names})
	if _host != null:
		_game_events(_host)
	var changed := {}
	for k: String in ws.refused:
		var n := int(ws.refused[k]) - int(_refused.get(k, 0))
		if n > 0:
			changed[k] = n
	if not changed.is_empty():
		_refused = ws.refused.duplicate()
		emit("refused", {"counts": changed})
	if now - _window_at >= WINDOW:
		_window_at = now
		_serr_in_window = 0
		for id: String in _dropped:
			emit("dropped", {"id": id, "name": _names.get(id, ""), "counts": _dropped[id]})
		_dropped.clear()
	for e: Array in tap.take():
		_serr_in_window += 1
		if _serr_in_window <= SERR_PER_WINDOW:
			emit("serr", {"kind": e[0], "text": String(e[1]).left(Protocol.MAX_TELEMETRY_LINE)})

## The host's cost since the last call (server.gd calls it with its stats line). Resets the room's worst.
func tick_stats(room: Room, players: int) -> void:
	var ticks := room.ticks - int(_last_tick["ticks"])
	var us := room.tick_us - int(_last_tick["us"])
	_last_tick = {"ticks": room.ticks, "us": room.tick_us}
	emit("tick", {"ticks": ticks, "ms": snappedf(us / 1000.0 / ticks, 0.001) if ticks > 0 else 0.0,
		"worst": snappedf(room.tick_max_us / 1000.0, 0.01), "players": players})
	room.tick_max_us = 0

## A telemetry message from player `id` (the text after "t|"). Logged if it decodes and is within the
## rate limit; otherwise counted, and never an error: a bad line must not cost the player their game.
func client_line(id: String, text: String, now: float) -> void:
	var m: Variant = Protocol.decode(text)
	if m == null or String(m["type"]) != "telemetry":
		_drop(id, "bad")
		return
	var kind := String(m["kind"])
	var bucket := "rep" if kind == "crash" else kind
	if not allow(id, bucket, now):
		_drop(id, kind)
		return
	var who := {"id": id, "name": _names.get(id, "")}
	match kind:
		"hb":
			who["data"] = clean_heartbeat(String(m["body"]))
			emit("hb", who)
		"log":
			who["line"] = m["body"]
			emit("clog", who)
		_:
			who.merge({"kind": kind, "rid": m["id"], "part": m["part"], "parts": m["parts"], "body": m["body"]})
			emit("report", who)

## The rate limit: at most LIMITS[bucket] per player in each WINDOW seconds.
func allow(id: String, bucket: String, now: float) -> bool:
	if not _rates.has(id):
		_rates[id] = {}
	var r: Dictionary = _rates[id]
	var w: Array = r.get(bucket, [now, 0])
	if now - float(w[0]) >= WINDOW:
		w = [now, 0]
	if int(w[1]) >= int(LIMITS.get(bucket, 0)):
		r[bucket] = w
		return false
	w[1] = int(w[1]) + 1
	r[bucket] = w
	return true

func _drop(id: String, kind: String) -> void:
	if not _dropped.has(id):
		_dropped[id] = {}
	_dropped[id][kind] = int(_dropped[id].get(kind, 0)) + 1

## A heartbeat's body (JSON text from the client) cut down to HB_KEYS: numbers, and strings no longer
## than their key allows. Anything else is left out.
static func clean_heartbeat(body: String) -> Dictionary:
	var p: Variant = JSON.parse_string(body)
	var out := {}
	if not p is Dictionary:
		return out
	for k: Variant in p:
		if not k is String or not HB_KEYS.has(k):
			continue
		var v: Variant = p[k]
		var cap := int(HB_KEYS[k])
		if (v is float or v is int) and is_finite(float(v)):
			out[k] = v
		elif v is String and cap > 0:
			out[k] = (v as String).left(cap)
	return out

func _game_events(host: Host) -> void:
	var evs: Array[Host.LoggedEvent] = host.event_log
	while _ev_index < evs.size():
		var e: Dictionary = evs[_ev_index].e
		_ev_index += 1
		var type := String(e.get("type", ""))
		if not type in GAME_EVENTS:
			continue
		var d := {"run": _epoch, "type": type, "t": snappedf(float(e.get("t", 0.0)), 0.01), "depth": host.state.depth if host.state != null else -1}
		for k in GAME_FIELDS:
			var v: Variant = e.get(k)
			if v is String or v is int or (v is float and is_finite(v)):
				d[k] = (v as String).left(40) if v is String else v
		if e.get("playerId") is String:
			d["player"] = _names.get(e["playerId"], e["playerId"])
		var s: Variant = e.get("summary")
		if s is Dictionary:
			d["total"] = (s as Dictionary).get("total")
		emit("game", d)
