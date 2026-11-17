# The one room the home server runs: a lobby until a player presses start, then a run (the authoritative
# NetHost of net/host.gd, stepping the rules through net/host_rules.gd exactly as the game does), then
# back to the lobby a few seconds after the run banks or is wiped (or at once if everyone has gone).
#
# On the wire (text WebSocket messages, after the hello that ws_server.gd checks):
#   server -> client  m|{"t":"you","id":"c3"}                                       once, after the hello
#                     m|{"t":"lobby","epoch":E,"running":true|false,"people":[[id,name],...]}
#                                                                                   on every change and every 2 s
#                     n<E>|<protocol text>                                           the run's messages (net/protocol.gd),
#                                                                                   including the other players' drawn faces ("F")
#   client -> server  m|{"t":"start"}        start a run (in the lobby; ignored while one runs)
#                     m|{"t":"name","name":"..."}
#                     m|{"t":"ping"}         keeps a lobby connection alive (any message does)
#                     n<E>|<protocol text>   input, join, leave, ping, emote or face change ("C") of run E
#                                            (the host passes emotes on to the others, rate limited; a
#                                            join may carry the player's drawn face, which the host passes
#                                            on once and nothing logs; a face change is passed on the same
#                                            way, at most one per player every Host.FACE_GAP seconds, and
#                                            a "C" whose face is not valid is ignored, not kicked; a client
#                                            may not send "F"); anything else, or a
#                                            message that does not decode exactly (net/protocol.gd
#                                            decode validates every field), closes the connection.
# A client's run messages are passed to the host as coming from that connection's own id, so it can
# only ever speak for its own player.
#
# The run has the day loop (`days`, on unless a test turns it off: sim/run.gd): BANK rides up to the
# prison and bed starts the next day, so the run does not end on a bank or a wipe; the room goes back to
# the lobby when everyone has gone. A run without days ends as before.
#
# The run has the floor quota (`quota`, on unless a test turns it off: sim/run.gd, North Star C9): the
# call button does nothing until the crew has recorded enough on the floor. A server started with the
# argument `quota=0` has none (test-only: tools/play_net.mjs passes it; HostRules.quota_off_by_arg).
#
# The run has down first, then out (`downs`, on unless a test turns it off: sim/run.gd, North Star B6): a
# catch puts the player down for ten seconds, a crewmate holding F beside them for three puts them back up,
# and otherwise they are out until the car next rides down.
#
# The run has two-watcher Stillness (`watchers`, on unless a test turns it off: sim/run.gd two_watchers;
# T19a): from three up players on the floor it takes two of them looking to hold a Stillness resident.
#
# The run has relocation (`relocation`, on unless a test turns it off: sim/run.gd, sim/relocate.gd; T19e): a
# resident may leave where nobody can see it and arrive where nobody can, near a player, heard as it arrives.
extends RefCounted

const Run = preload("res://sim/run.gd")
const Protocol = preload("res://net/protocol.gd")
const Transport = preload("res://net/transport.gd")
const Host = preload("res://net/host.gd")
const HostRules = preload("res://net/host_rules.gd")
const Places = preload("res://sim/places.gd")
const WsServer = preload("res://net/ws_server.gd")

## Seconds after a bank or a wipe before the room goes back to the lobby.
const END_LINGER := 10.0
const LOBBY_EVERY := 2.0
## The run messages (net/protocol.gd types) a client may send; anything else closes the connection.
const ACCEPTED: Array[String] = ["input", "join", "leave", "ping", "emote", "setFace"]

## What NetHost talks through: the room pushes what arrives, sends go out framed with the run's epoch.
class RoomTransport extends Transport.Transport:
	var _room: WeakRef
	var _inbox: Array[Dictionary] = []
	var _events: Array[Dictionary] = []

	func _init(room: Object) -> void:
		_room = weakref(room)
		self_id = "host"

	func push(from: String, data: String) -> void:
		_inbox.append({"from": from, "data": data})

	func push_peer(e: Dictionary) -> void:
		_events.append(e)

	func send(to: String, data: String) -> void:
		var r: Object = _room.get_ref()
		if r != null:
			r.call("send_run", to, data)

	func receive() -> Array[Dictionary]:
		var out := _inbox
		_inbox = []
		return out

	func peer_events() -> Array[Dictionary]:
		var out := _events
		_events = []
		return out

var epoch := 0
var host: Host = null
var rules: HostRules = null
var people := {}  # id -> name, in arrival order
## Seed of the next run ("" draws one at random); tests set it.
var fixed_seed := ""
## The day loop in the next run (the game's; tests may turn it off).
var days := true
## The floor quota in the next run (the game's; tests may turn it off): the call button does nothing
## until the crew has recorded enough on the floor (sim/run.gd quota).
var quota := true
## Down first, then out in the next run (the game's; tests may turn it off: sim/run.gd downs).
var downs := true
## Two-watcher Stillness in the next run (the game's; tests may turn it off: sim/run.gd two_watchers):
## from three up players it takes two watchers to hold a Stillness resident.
var watchers := true
## Relocation in the next run (the game's; tests may turn it off: sim/run.gd relocation, sim/relocate.gd).
var relocation := true
## Tick cost, for the log: total and worst microseconds, and ticks.
var tick_us := 0
var tick_max_us := 0
var ticks := 0
var _ws: WsServer
var _transport: RoomTransport = null
var _ended_at := -1.0
var _last_lobby := -INF
var _dirty := false
var _log: Callable
var _day_logged := 1

func _init(ws: WsServer, log: Callable) -> void:
	_ws = ws
	_log = log

func running() -> bool:
	return host != null

func send_run(to: String, data: String) -> void:
	_ws.send(to, "n%d|%s" % [epoch, data])

func _lobby_text() -> String:
	var list: Array = []
	for id: String in people:
		list.append([id, people[id]])
	return "m|" + JSON.stringify({"t": "lobby", "epoch": epoch, "running": running(), "people": list})

## Handles the door's events and runs the host. `now`: seconds.
func update(now: float) -> void:
	for e in _ws.events:
		match String(e["kind"]):
			"joined":
				people[e["id"]] = e["name"]
				_ws.send(e["id"], "m|" + JSON.stringify({"t": "you", "id": e["id"]}))
				_dirty = true
			"left":
				people.erase(e["id"])
				if _transport != null:
					_transport.push_peer({"kind": "left", "peer": e["id"]})
				_dirty = true
			"message":
				_on_message(e["id"], e["data"], now)
	_ws.events.clear()
	if host != null:
		var tick0 := host.tick
		var t0 := Time.get_ticks_usec()
		host.update(now)
		var dt := Time.get_ticks_usec() - t0
		var n := host.tick - tick0
		if n > 0:
			ticks += n
			tick_us += dt
			tick_max_us = maxi(tick_max_us, dt / n)
		if host.state.days and host.state.day_index != _day_logged:
			_day_logged = host.state.day_index
			_log.call("run %d: day %d begins (day %d of this run)" % [epoch, host.state.day_state.day, host.state.day_index])
		if host.state.phase == &"ended" and _ended_at < 0.0:
			_ended_at = now
			var s := host.state.summary
			_log.call("run %d ended: %s, depth %d, total %.2f" % [epoch, "wiped" if s != null and s.wiped else "banked", host.state.depth, s.total if s != null else 0.0])
		if (_ended_at >= 0.0 and now - _ended_at >= END_LINGER) or people.is_empty():
			_end_run()
	if _dirty or now - _last_lobby >= LOBBY_EVERY:
		_dirty = false
		_last_lobby = now
		var text := _lobby_text()
		for id: String in people:
			_ws.send(id, text)

func _end_run() -> void:
	_log.call("run %d over, back to the lobby" % epoch)
	host.close()
	host = null
	rules = null
	_transport = null
	_ended_at = -1.0
	_dirty = true

func _start(now: float) -> void:
	if host != null or people.is_empty():
		return
	epoch += 1
	var seed := fixed_seed
	if seed.is_empty():
		seed = Crypto.new().generate_random_bytes(6).hex_encode()
	var roster: Array[String] = []
	for id: String in people:
		roster.append(id)
	# The game's deck: the third floor down is the Annex, the fourth the Playroom (sim/places.gd).
	rules = HostRules.new(true, 1, Places.FULL, days, quota and not HostRules.quota_off_by_arg(false), downs, watchers, relocation)
	_transport = RoomTransport.new(self)
	_day_logged = 1
	host = Host.new(_transport, seed, roster, now, Callable(rules, "prepare"), Callable(rules, "step"))
	_dirty = true
	_log.call("run %d started with %d players" % [epoch, roster.size()])

func _on_message(id: String, data: String, now: float) -> void:
	if data.begins_with("m|"):
		var p: Variant = JSON.parse_string(data.substr(2))
		if not p is Dictionary or not (p as Dictionary).get("t") is String:
			_ws.kick(id, WsServer.CLOSE_PROTOCOL, "bad message")
			return
		match String(p["t"]):
			"start":
				_start(now)
			"name":
				if p.get("name") is String:
					people[id] = WsServer._clean_name(p["name"])
					_dirty = true
			"ping":
				pass
			_:
				_ws.kick(id, WsServer.CLOSE_PROTOCOL, "bad message")
		return
	if data.begins_with("n"):
		var bar := data.find("|")
		var e := data.substr(1, bar - 1)
		if bar < 2 or not e.is_valid_int():
			_ws.kick(id, WsServer.CLOSE_PROTOCOL, "bad message")
			return
		if int(e) != epoch or _transport == null:
			return  # a late message of a finished run
		var text := data.substr(bar + 1)
		var m: Variant = Protocol.decode(text)
		if m == null or not (String(m["type"]) in ACCEPTED):
			_ws.kick(id, WsServer.CLOSE_PROTOCOL, "bad message")
			return
		_transport.push(id, text)
		return
	_ws.kick(id, WsServer.CLOSE_PROTOCOL, "bad message")
