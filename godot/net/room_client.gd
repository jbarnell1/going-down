# A player's connection to the home server's room (server/room.gd): the WebSocket, the passphrase
# hello, the lobby, and one NetClient (net/client.gd) per run. Works the same in the Windows build and
# in the browser build (WebSocketPeer is both). See net/README.md for how a game uses it.
extends RefCounted

const ProfileStore = preload("res://net/profile_store.gd")

const Client = preload("res://net/client.gd")
const Transport = preload("res://net/transport.gd")
const Session = preload("res://net/session.gd")
const Protocol = preload("res://net/protocol.gd")
const BuildInfo = preload("res://net/build_info.gd")

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
## Ready-up (server/room.gd): the host's id; when the count ends and when the host may start without the
## others, on this client's clock (-1: no count / not yet); the run's floor (-1 with no run). Each people
## row is [id, name, ready, tape, inRun, face] (older servers: [id, name]).
var host_id := ""
var start_at := -1.0
var without_at := -1.0
var run_depth := -1
var orientation_active := false
var orientation_paid := 0
## What this client last said: ready, and watching the tape.
var my_ready := false
var my_tape := false
## The NetClient of the current run (null in the lobby).
var client: Client = null
## Tests: seconds added to every message in each direction (a slow link), and how many arrived.
var delay := 0.0
var received := 0
## Bytes of WebSocket text received and sent (the game's measurement of what a player costs the link).
var bytes_in := 0
var bytes_out := 0

## Live settings (docs/floors/live-settings.md LS2; net/tuning_desk.gd): what the host has asked for ({id:
## number}, only what differs from the game's), the desk's revision, who the host is, the values in force when
## some wait for the next floor or tomorrow ({id: number}, else the asked-for list), whether the server keeps a
## file and when it was last saved; the one-line notices not yet shown (the panel takes them), and the newest
## refusals of this player's own changes ({id, why}).
var tune_asked := {}
var tune_force: Variant = null
var tune_rev := 0
var tune_host := ""
var tune_file := false
var tune_saved := ""
var tune_lines: Array[String] = []
var tune_refusals: Array[Dictionary] = []

var _ws := WebSocketPeer.new()
var _secret: String
var _name: String
var profile_directory := ProfileStore.DEFAULT_DIR
var _profile_path := ""
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
	_profile_path = ProfileStore.remote_path(profile_directory, url)
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
	if status == "lobby" or status == "running":
		_send_lobby_face()
	if client != null and not client.ended:
		client.change_face(face, _now)
	_flush(_now)
	return true

## The host's START WITHOUT (server/room.gd: the host only, 30 s after readying; ignored otherwise).
func start_run() -> void:
	_queue("m|" + JSON.stringify({"t": "start"}))

## Ready or not (the Ready-up screen's I'M READY). `tape`: not ready, watching the orientation tape.
func set_ready(on: bool, tape: bool = false) -> void:
	my_ready = on
	my_tape = tape and not on
	var m := {"t": "ready", "on": on}
	if my_tape:
		m["tape"] = true
	_queue("m|" + JSON.stringify(m))
	_flush(_now)

## The face shown beside this player's name on the Ready-up list.
func _send_lobby_face() -> void:
	if _face != "":
		_queue("m|" + JSON.stringify({"t": "face", "face": _face}))

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

## Telemetry for the server's log (client/telemetry.gd): a Protocol "telemetry" message, on its own
## "t|" frame. False (nothing sent) unless connected to a server, or if it does not encode.
func send_telemetry(m: Dictionary) -> bool:
	if status != "lobby" and status != "running":
		return false
	var text := Protocol.encode(m)
	if text.is_empty():
		return false
	_queue("t|" + text)
	_flush(_now)
	return true

## Whether this player is the host (the only one whose changes the room takes).
func is_host() -> bool:
	return my_id != "" and my_id == tune_host

## The host asks for a value. False (nothing sent) unless this player is the host.
func tune_set(id: StringName, value: float) -> bool:
	return _tune_send({"t": "tune", "id": String(id), "v": value})

## The host puts one setting back to the game's value.
func tune_reset(id: StringName) -> bool:
	return _tune_send({"t": "tune", "id": String(id), "reset": true})

## The host puts every setting back.
func tune_reset_all() -> bool:
	return _tune_send({"t": "tune", "reset": "all"})

func _tune_send(m: Dictionary) -> bool:
	if not is_host():
		return false
	_queue("m|" + JSON.stringify(m))
	_flush(_now)
	return true

## The values in force (the asked-for list unless some wait).
func tune_in_force() -> Dictionary:
	return tune_force if tune_force != null else tune_asked

## A room "tune" message (also net/local_room.gd's own desk): the host's list, and its line once.
func _take_tune(p: Dictionary) -> void:
	tune_rev = int(p.get("rev", 0))
	tune_host = str(p.get("host", ""))
	tune_file = p.get("file", false) == true
	tune_saved = str(p.get("saved", ""))
	var set := {}
	var given: Variant = p.get("set")
	if given is Dictionary:
		for k: Variant in given:
			if given[k] is float or given[k] is int:
				set[StringName(str(k))] = float(given[k])
	tune_asked = set
	tune_force = null
	if p.get("force") is Dictionary:
		var force := {}
		for k: Variant in p["force"]:
			force[StringName(str(k))] = float(p["force"][k])
		tune_force = force
	if p.get("line") is String and not (p["line"] as String).is_empty():
		tune_lines.append(p["line"])

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
		_ws.send_text(JSON.stringify(["hello", 1, _secret, _name, BuildInfo.id()]))
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
				if p.get("profile") == true:
					var line := ProfileStore.read(_profile_path)
					_queue("m|" + JSON.stringify({"t": "profile", "line": line}))
				_send_lobby_face()
			"profile":
				var line: Variant = p.get("line")
				if line is String and line.begins_with("GDS1|"):
					ProfileStore.store(_profile_path, line)
			"tune":
				_take_tune(p)
			"tuneNo":
				tune_refusals.append({"id": str(p.get("id", "")), "why": str(p.get("why", ""))})
			"lobby":
				people = p["people"]
				epoch = int(p["epoch"])
				var was_on := run_on
				run_on = bool(p["running"])
				host_id = str(p.get("host", ""))
				# The server's clock to this one's: what is left, from now.
				var srv := float(p.get("now", 0.0))
				var sa := float(p.get("startAt", -1.0))
				var wa := float(p.get("withoutAt", -1.0))
				start_at = now + (sa - srv) if sa >= 0.0 else -1.0
				without_at = now + (wa - srv) if wa >= 0.0 else -1.0
				run_depth = int(p.get("depth", -1))
				orientation_active = p.get("orientationPrelude") == true
				orientation_paid = maxi(0, int(p.get("orientationPaid", 0)))
				if was_on and not run_on:
					# Back on the Ready-up screen: the server has forgotten everyone's ready.
					my_ready = false
				if run_on and epoch > _epoch_joined:
					_join_run(epoch, now, p.get("garden"), p.get("gardenDense") == true, p.get("orientation") == true, p.get("cycles") == true, p.get("reactorPlace") == true)
					client.orientation_prelude = orientation_active
				elif not run_on and client != null:
					client = null
					_pipe = null
					status = "lobby"
		return
	if text.begins_with("n") and _pipe != null:
		var bar := text.find("|")
		if bar > 1 and int(text.substr(1, bar - 1)) == _epoch_joined:
			_pipe.push("host", text.substr(bar + 1))

func _join_run(e: int, now: float, garden: Variant, garden_dense: bool, orientation := false, cycles := false, reactor_place := false) -> void:
	_epoch_joined = e
	# Weak, so the pipe's callables do not keep this object alive.
	var me: WeakRef = weakref(self)
	var out := func(data: String) -> void:
		var rc: Object = me.get_ref()
		if rc != null:
			rc.call("_queue", "n%d|%s" % [e, data])
	_pipe = Transport.Pipe.new(my_id, func(_to: String, data: String) -> void: out.call(data), out)
	client = Client.new(_pipe, "host", _name, now, Session.INTERP_DELAY, Session.INPUT_INTERVAL, _face)
	const Places = preload("res://sim/places.gd")
	if orientation:
		client.floor_deck = Places.ORIENTATION_ONLY
	elif garden is bool:
		client.floor_deck = Places.FULL if garden else Places.BEFORE_ARBORETUM
		client.garden_dense = garden and garden_dense
		# Cycles (FL2, the lobby's "cycles"): the run's deck repeats its floors in sevens (sim/places.gd).
		if cycles:
			client.floor_deck = Places.with_cycles(client.floor_deck)
		# RN1 (the lobby's "reactorPlace"): floor 7 is the generated station (sim/places.gd REACTOR).
		if reactor_place:
			client.floor_deck = Places.with_reactor(client.floor_deck)
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

func reactor_screening(operation: String, ticket := 0) -> bool:
	if not run_on or operation not in ["watch","skip","end"]: return false
	_queue("m|"+JSON.stringify({"t":"rxFilm","op":operation,"ticket":ticket,"epoch":epoch}))
	_flush(_now)
	return true
