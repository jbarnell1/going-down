# play_day's server: the home server (server/server.gd) on 127.0.0.1 with its own room code (tools/day_room.gd:
# the game's room, days, the floor quota and the day lock on, its resident parked for good), and a control line
# for the check on 127.0.0.1:`ctl` (one command a line, one JSON reply a line): `earn <n>` records n credits for
# the crew (the day's earned, and this floor's quota met); `info` reads the host; `dayat <tick>` the host's day
# block at that tick. Tests only; the passphrase is the environment's GD_JOIN_SECRET, as for the real server.
#   godot --headless --path godot -s res://tools/day_server.gd -- port=4470 ctl=4473 seed=day-1
extends SceneTree

const WsServer = preload("res://net/ws_server.gd")
const DayRoom = preload("res://tools/day_room.gd")
const Session = preload("res://net/session.gd")
const Places = preload("res://sim/places.gd")

var _ws: WsServer
var _room: DayRoom
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
	var port := int(args.get("port", "4470"))
	_ws = WsServer.new(secret, false, say)
	if _ws.listen(port, "127.0.0.1") != OK:
		say("not started: cannot listen on %d" % port)
		quit(3)
		return
	_ctl = TCPServer.new()
	if _ctl.listen(int(args.get("ctl", "4473")), "127.0.0.1") != OK:
		say("not started: cannot listen for the test on %s" % args.get("ctl", "4473"))
		quit(3)
		return
	Session.deck = Places.FULL
	_room = DayRoom.new(_ws, say)
	_room.fixed_seed = str(args.get("seed", ""))
	Engine.max_fps = 250
	_t0 = Time.get_ticks_usec()
	say("day server listening on 127.0.0.1:%d, control on %s" % [port, args.get("ctl", "4473")])

func _now() -> float:
	return (Time.get_ticks_usec() - _t0) / 1000000.0

func _process(_delta: float) -> bool:
	if _ws == null:
		return false
	var now := _now()
	_ws.poll(now)
	_room.update(now)
	_poll_ctl()
	return false

func _poll_ctl() -> void:
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
			peer.put_data((JSON.stringify(_command(line.strip_edges())) + "\n").to_utf8_buffer())

func _command(line: String) -> Dictionary:
	var p := line.split(" ", false)
	if p.is_empty():
		return {"ok": false, "error": "empty"}
	match p[0]:
		"earn":
			var r := _room.earn(float(p[1]) if p.size() > 1 else 0.0)
			say("test: earn %s: %s" % [p[1] if p.size() > 1 else "0", JSON.stringify(r)])
			return r
		"info":
			return _room.info()
		"dayat":
			return _room.day_at(int(p[1]) if p.size() > 1 else -1)
	return {"ok": false, "error": "unknown command"}
