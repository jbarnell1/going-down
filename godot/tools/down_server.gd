# play_down's server: the home server (server/server.gd) on 127.0.0.1 with its own room code
# (tools/down_room.gd: the game's room, its resident moved only when the test asks), and a control line for
# the test on 127.0.0.1:`ctl` (one command a line, one JSON reply a line): `behind <name>` sends the resident
# after that player from just behind them; `info` reads the host; `finds` the floor's findables (play_search.mjs). Tests only; the passphrase is the
# environment's GD_JOIN_SECRET, as for the real server.
#   godot --headless --path godot -s res://tools/down_server.gd -- port=4466 ctl=4469 seed=down-1
extends SceneTree

const WsServer = preload("res://net/ws_server.gd")
const DownRoom = preload("res://tools/down_room.gd")
const Session = preload("res://net/session.gd")
const Places = preload("res://sim/places.gd")
const Findables = preload("res://sim/findables.gd")

var _ws: WsServer
var _room: DownRoom
var _t0 := 0
var _ctl: TCPServer
var _peers: Array[StreamPeerTCP] = []
var _bufs: Array[String] = []

static func say(text: String) -> void:
	print("[%s] %s" % [Time.get_time_string_from_system(), text])

func _initialize() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var secret := OS.get_environment("GD_JOIN_SECRET")
	if secret.is_empty():
		say("not started: set GD_JOIN_SECRET")
		quit(2)
		return
	var port := int(args.get("port", "4466"))
	_ws = WsServer.new(secret, false, say)
	if _ws.listen(port, "127.0.0.1") != OK:
		say("not started: cannot listen on %d" % port)
		quit(3)
		return
	_ctl = TCPServer.new()
	if _ctl.listen(int(args.get("ctl", "4469")), "127.0.0.1") != OK:
		say("not started: cannot listen for the test on %s" % args.get("ctl", "4469"))
		quit(3)
		return
	Session.deck = Places.FULL
	_room = DownRoom.new(_ws, say)
	_room.fixed_seed = str(args.get("seed", ""))
	Engine.max_fps = 250
	_t0 = Time.get_ticks_usec()
	say("down server listening on 127.0.0.1:%d, control on %s" % [port, args.get("ctl", "4469")])

func _now() -> float:
	return (Time.get_ticks_usec() - _t0) / 1000000.0

func _process(_delta: float) -> bool:
	if _ws == null:
		return false
	var now := _now()
	_ws.poll(now)
	_room.update(now)
	_poll_ctl(now)
	return false

func _poll_ctl(now: float) -> void:
	while _ctl.is_connection_available():
		_peers.append(_ctl.take_connection())
		_bufs.append("")
	for i in _peers.size():
		var peer := _peers[i]
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			continue
		var n := peer.get_available_bytes()
		if n > 0:
			_bufs[i] += peer.get_utf8_string(n)
		while _bufs[i].contains("\n"):
			var line := _bufs[i].get_slice("\n", 0)
			_bufs[i] = _bufs[i].substr(line.length() + 1)
			peer.put_data((JSON.stringify(_command(line.strip_edges(), now)) + "\n").to_utf8_buffer())

func _command(line: String, now: float) -> Dictionary:
	var p := line.split(" ", false)
	if p.is_empty():
		return {"ok": false, "error": "empty"}
	match p[0]:
		"behind":
			if p.size() < 2:
				return {"ok": false, "error": "behind whom"}
			var r := _room.behind(p[1], now)
			say("test: the resident behind %s: %s" % [p[1], JSON.stringify(r)])
			return r
		"info":
			return _room.info()
		"finds":
			# Findables (tools/play_search.mjs): this floor's fill and sheet and what the host has opened.
			var h: Variant = _room.host
			if h == null or h.state.find == null:
				return {"ok": false, "error": "no findables here"}
			var ff: Variant = h.state.find
			var contents := {}
			for id: int in ff.fill.contents:
				contents[str(id)] = ff.fill.contents[id]
			return {"ok": true, "sheet": Findables.sheet_text(ff.fill), "base": ff.fill.base, "contents": contents, "opened": Findables.opened_rows(ff)}
	return {"ok": false, "error": "unknown command"}
