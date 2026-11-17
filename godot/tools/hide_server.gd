# play_hide's server: the home server (server/server.gd) on 127.0.0.1 with its own room code, the run
# starting on the Playroom (tools/hide_room.gd). Tests only; the passphrase is the environment's
# GD_JOIN_SECRET, as for the real server.
#   godot --headless --path godot -s res://tools/hide_server.gd -- port=4470 seed=hide-54 depth=4
extends SceneTree

const WsServer = preload("res://net/ws_server.gd")
const HideRoom = preload("res://tools/hide_room.gd")
const Session = preload("res://net/session.gd")
const Places = preload("res://sim/places.gd")

var _ws: WsServer
var _room: HideRoom
var _t0 := 0

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
	Session.deck = Places.FULL
	_room = HideRoom.new(_ws, say)
	_room.fixed_seed = str(args.get("seed", ""))
	_room.start_depth = int(args.get("depth", "4"))
	Engine.max_fps = 250
	_t0 = Time.get_ticks_usec()
	say("hide server listening on 127.0.0.1:%d, runs start at depth %d" % [port, _room.start_depth])

func _process(_delta: float) -> bool:
	if _ws == null:
		return false
	var now := (Time.get_ticks_usec() - _t0) / 1000000.0
	_ws.poll(now)
	_room.update(now)
	return false
