# The dedicated server: ONE room (server/room.gd) behind one WebSocket port (net/ws_server.gd). It
# draws nothing, opens no file for writing, starts no process and makes no outgoing connection.
#
#   GD_JOIN_SECRET=... GoingDownServer.x86_64 --headless -- server port=4450
#   godot --headless --path godot res://server/server.tscn -- server port=4450 bind=127.0.0.1
#
# Arguments (after --): `server` (required: this is the server), `port=N` (default 4450),
# `bind=ADDRESS` (default * for every interface; 127.0.0.1 for local tests), `seed=TEXT` (tests: every
# run on this seed), `insecure=1` (no passphrase: local tests only, with a loud warning), `quit_after=S`
# (tests: stop after S seconds), `stats=S` (seconds between cost lines in the log, default 60).
# The passphrase: the environment variable GD_JOIN_SECRET, or the first line of the file named by
# GD_JOIN_SECRET_FILE (keep it outside the repository). Without one the server refuses to start.
extends Node

const WsServer = preload("res://net/ws_server.gd")
const Room = preload("res://server/room.gd")
const Session = preload("res://net/session.gd")
const Places = preload("res://sim/places.gd")

var _ws: WsServer
var _room: Room
var _t0 := 0
var _quit_after := -1.0
var _stats_every := 60.0
var _last_stats := 0.0

static func say(text: String) -> void:
	print("[%s] %s" % [Time.get_time_string_from_system(), text])

func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	if not args.has("server"):
		say("not started: pass -- server port=N")
		get_tree().quit(2)
		return
	var insecure: bool = args.get("insecure", "0") == "1"
	var secret := OS.get_environment("GD_JOIN_SECRET")
	var file := OS.get_environment("GD_JOIN_SECRET_FILE")
	if secret.is_empty() and not file.is_empty():
		var f := FileAccess.open(file, FileAccess.READ)
		if f == null:
			say("not started: cannot read GD_JOIN_SECRET_FILE")
			get_tree().quit(2)
			return
		secret = f.get_line().strip_edges()
		f.close()
	if secret.is_empty() and not insecure:
		say("not started: no passphrase. Set GD_JOIN_SECRET (or GD_JOIN_SECRET_FILE); insecure=1 is for local tests only")
		get_tree().quit(2)
		return
	if insecure:
		for i in 3:
			say("WARNING: INSECURE MODE: ANYONE WHO CAN REACH THIS PORT CAN JOIN. LOCAL TESTS ONLY.")
	elif secret.length() < 8:
		say("WARNING: the passphrase is shorter than 8 characters")
	var port := int(args.get("port", "4450"))
	var bind: String = args.get("bind", "*")
	_quit_after = float(args.get("quit_after", "-1"))
	_stats_every = float(args.get("stats", "60"))
	_ws = WsServer.new(secret, insecure, say)
	secret = ""
	var err := _ws.listen(port, bind)
	if err != OK:
		say("not started: cannot listen on %s:%d (error %d)" % [bind, port, err])
		get_tree().quit(3)
		return
	# The game's deck, as every client's (client/main.gd); the room gives it to each run.
	Session.deck = Places.FULL
	_room = Room.new(_ws, say)
	_room.fixed_seed = args.get("seed", "")
	# A server needs no frame rate of its own: 250 loops a second is a 4 ms step for the 20 Hz ticks.
	Engine.max_fps = 250
	_t0 = Time.get_ticks_usec()
	say("Going Down server listening on %s:%d (one room, at most %d players)" % [bind, port, WsServer.MAX_PLAYERS])

func _now() -> float:
	return (Time.get_ticks_usec() - _t0) / 1000000.0

func _process(_delta: float) -> void:
	if _ws == null:
		return
	var now := _now()
	_ws.poll(now)
	_room.update(now)
	if _stats_every > 0.0 and now - _last_stats >= _stats_every:
		_last_stats = now
		var mean := (_room.tick_us / 1000.0 / _room.ticks) if _room.ticks > 0 else 0.0
		say("players %d, pending %d, run %s, ticks %d, %.3f ms a tick (worst %.2f ms), refused %s" % [_ws.players(), _ws.pending(),
			str(_room.epoch) if _room.running() else "none", _room.ticks, mean, _room.tick_max_us / 1000.0, JSON.stringify(_ws.refused)])
	if _quit_after > 0.0 and now >= _quit_after:
		say("stopping (quit_after)")
		_ws.stop()
		get_tree().quit(0)
