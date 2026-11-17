# A player's connection to the home server's room (server/room.gd): the WebSocket, the passphrase
# hello, the lobby, and one NetClient (net/client.gd) per run. Works the same in the Windows build and
# in the browser build (WebSocketPeer is both). See net/README.md for how a game uses it.
extends RefCounted

const Client = preload("res://net/client.gd")
const Transport = preload("res://net/transport.gd")
const Session = preload("res://net/session.gd")
const Protocol = preload("res://net/protocol.gd")

## "connecting", "lobby" (connected; no run, or a run this client is not in yet), "running" (a NetClient
## for the current run exists), "closed" (see close_code / close_reason).
var status := "connecting"
var close_code := 0
var close_reason := ""
## This connection's id (also the player id in runs), once the server said it.
var my_id := ""
## The room: [[id, name], ...] in arrival order, the newest run's number, whether one is on.
var people: Array = []
var epoch := 0
var run_on := false
## The NetClient of the current run (null in the lobby).
var client: Client = null
## Tests: seconds added to every message in each direction (a slow link), and how many arrived.
var delay := 0.0
var received := 0
## Bytes of WebSocket text received and sent (the game's measurement of what a player costs the link).
var bytes_in := 0
var bytes_out := 0

var _ws := WebSocketPeer.new()
var _secret: String
var _name: String
## The player's drawn face (FaceCodec text) sent in every run's join, or "". It goes only to the host,
## which passes it to the other players in the run.
var _face := ""
var _hello_sent := false
var _epoch_joined := 0
var _pipe: Transport.Pipe = null
var _out: Array = []  # [due, text]
var _in: Array = []  # [due, text]
var _last_ping := 0.0
var _now := 0.0

## Connects to `url` (ws://host:port or wss://...). Call poll() every frame from then on. `face`: the
## player's drawn face, sent with the join of every run ("" for none).
func connect_to(url: String, secret: String, name: String, face: String = "") -> Error:
	_secret = secret
	_name = name
	_face = face
	_ws.inbound_buffer_size = 1 << 20
	_ws.outbound_buffer_size = 1 << 16
	return _ws.connect_to_url(url)

## Changes the player's face (the face kiosk): the run's client sends it now (or after the host's gap),
## and every later run's join carries it. False if `face` is not a valid face.
func set_face(face: String) -> bool:
	if Protocol.valid_face(face) == "":
		return false
	_face = face
	if client != null and not client.ended:
		client.change_face(face, _now)
		_flush(_now)
	return true

## Starts a run (from the lobby; the server ignores it while one is on).
func start_run() -> void:
	_queue("m|" + JSON.stringify({"t": "start"}))

func set_player_name(n: String) -> void:
	_name = n
	_queue("m|" + JSON.stringify({"t": "name", "name": n}))

## Leaves the run and closes the connection.
func leave() -> void:
	if client != null and not client.ended:
		client.leave()
	_flush(INF)
	_ws.close(1000, "bye")
	status = "closed"

func _queue(text: String) -> void:
	_out.append([_now + delay, text])

func _flush(now: float) -> void:
	while not _out.is_empty() and float(_out[0][0]) <= now:
		if _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			_ws.send_text(_out[0][1])
			bytes_out += String(_out[0][1]).length()
		_out.pop_front()

## Pumps the socket and the lobby, and takes in the run's messages. `now`: local seconds.
func poll(now: float) -> void:
	_now = now
	_ws.poll()
	var st := _ws.get_ready_state()
	if st == WebSocketPeer.STATE_CLOSED:
		if status != "closed":
			status = "closed"
			close_code = _ws.get_close_code()
			close_reason = _ws.get_close_reason()
		if client != null and _pipe != null:
			_pipe.push_peer({"kind": "left", "peer": "host"})
			client.receive(now)
		return
	if st != WebSocketPeer.STATE_OPEN:
		return
	if not _hello_sent:
		_hello_sent = true
		_ws.send_text(JSON.stringify(["hello", 1, _secret, _name]))
		_secret = ""
	while _ws.get_available_packet_count() > 0:
		var pkt := _ws.get_packet()
		var text := pkt.get_string_from_utf8()
		received += 1
		bytes_in += pkt.size()
		_in.append([now + delay, text])
	while not _in.is_empty() and float(_in[0][0]) <= now:
		_on_text(_in.pop_front()[1], now)
	if client != null:
		client.receive(now)
	if now - _last_ping >= 2.0 and client == null:
		_last_ping = now
		_queue("m|" + JSON.stringify({"t": "ping"}))
	_flush(now)

func _on_text(text: String, now: float) -> void:
	if text.begins_with("m|"):
		var p: Variant = JSON.parse_string(text.substr(2))
		if not p is Dictionary:
			return
		match String(p.get("t", "")):
			"you":
				my_id = String(p["id"])
				status = "lobby"
			"lobby":
				people = p["people"]
				epoch = int(p["epoch"])
				run_on = bool(p["running"])
				if run_on and epoch > _epoch_joined:
					_join_run(epoch, now)
				elif not run_on and client != null:
					client = null
					_pipe = null
					status = "lobby"
		return
	if text.begins_with("n") and _pipe != null:
		var bar := text.find("|")
		if bar > 1 and int(text.substr(1, bar - 1)) == _epoch_joined:
			_pipe.push("host", text.substr(bar + 1))

func _join_run(e: int, now: float) -> void:
	_epoch_joined = e
	# Weak, so the pipe's callables do not keep this object alive.
	var me: WeakRef = weakref(self)
	var out := func(data: String) -> void:
		var rc: Object = me.get_ref()
		if rc != null:
			rc.call("_queue", "n%d|%s" % [e, data])
	_pipe = Transport.Pipe.new(my_id, func(_to: String, data: String) -> void: out.call(data), out)
	client = Client.new(_pipe, "host", _name, now, Session.INTERP_DELAY, Session.INPUT_INTERVAL, _face)
	# The game (client/main.gd sets the full deck) draws a Stillness resident in the dark too (T20a).
	client.draw_in_dark = Session.deck == preload("res://sim/places.gd").FULL
	status = "running"
	_flush(now)

## One rendered frame of the run (null in the lobby): see net/client.gd frame(). Sends the input.
func frame(now: float, local: Client.LocalFrame) -> Client.Frame:
	if client == null:
		return null
	var f := client.frame(now, local)
	_flush(now)
	return f
