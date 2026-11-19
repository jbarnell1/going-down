# The dedicated server: ONE room (server/room.gd) behind one WebSocket port (net/ws_server.gd). It
# draws nothing, starts no process and makes no outgoing connection. It opens no file for writing but the live
# settings file, and that only when asked for one (below).
#
#   GD_JOIN_SECRET=... GoingDownServer.x86_64 --headless -- server port=4450
#   godot --headless --path godot res://server/server.tscn -- server port=4450 bind=127.0.0.1
#
# Arguments (after --): `server` (required: this is the server), `port=N` (default 4450),
# `bind=ADDRESS` (default * for every interface; 127.0.0.1 for local tests), `seed=TEXT` (tests: every
# run on this seed), `insecure=1` (no passphrase: local tests only, with a loud warning), `quit_after=S`
# (tests: stop after S seconds), `stats=S` (seconds between cost lines in the log, default 60; the worst tick
# is the worst since the last line), `build=ID` (tests: this server's build id, net/build_info.gd), `settings=PATH`
# (the live settings file, docs/floors/live-settings.md: the host's changes are saved there, with PATH.tmp,
# PATH.log and PATH.bad beside it, read again at start and whenever it is edited by hand; also the environment
# variable GD_SETTINGS_FILE; with neither, the changes last until the server stops and nothing is written),
# `depth=N` (tests: every run starts on floor N, so tools/exported_server_check.mjs reaches the Annex without
# riding down; printed as a TEST line), `test_unreadable=FILE` (tests: the data check treats data/FILE as
# missing, so the refusal below can be proved).
# Before it listens it reads every data file the rules need (server/data_check.gd): `data: N files read`,
# or `not started: the build is missing data/<file>`, a night-log line {"ev":"notStarted"} and exit code 4.
# Beside the plain lines it writes the night's log, one JSON object per line (server/night_log.gd).
# The passphrase: the environment variable GD_JOIN_SECRET, or the first line of the file named by
# GD_JOIN_SECRET_FILE (keep it outside the repository). Without one the server refuses to start.
extends Node

const SaveSlip = preload("res://net/save_slip.gd")

const WsServer = preload("res://net/ws_server.gd")
const Room = preload("res://server/room.gd")
const Session = preload("res://net/session.gd")
const Places = preload("res://sim/places.gd")
const HostRules = preload("res://net/host_rules.gd")
const NightLog = preload("res://server/night_log.gd")
const DataCheck = preload("res://server/data_check.gd")

var _ws: WsServer
var _room: Room
var _t0 := 0
var _quit_after := -1.0
var _stats_every := 60.0
var _last_stats := 0.0
var _night: NightLog

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
	# Everything the rules read from data/ at run time, through their own loaders (server/data_check.gd),
	# before anything else: a build without them must not take players.
	var data := DataCheck.run(args.get("test_unreadable", ""))
	if not data["ok"]:
		say("not started: the build is missing data/%s (%s)" % [data["missing"], data["why"]])
		NightLog.new().emit("notStarted", {"reason": "data", "file": "data/" + String(data["missing"]), "why": data["why"]})
		get_tree().quit(4)
		return
	say("data: %d files read" % data["files"])
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
	if args.has("build"):
		_ws.build = args["build"]
	var err := _ws.listen(port, bind)
	if err != OK:
		say("not started: cannot listen on %s:%d (error %d)" % [bind, port, err])
		get_tree().quit(3)
		return
	# The game's deck, as every client's (client/main.gd); the room gives it to each run.
	Session.deck = Places.FULL
	_room = Room.new(_ws, say)
	_room.orientation_review = bind == "127.0.0.1" and args.get("orientation", "0") == "1"
	if not _room.orientation_review:
		var save := SaveSlip.key_from_env()
		if save.ok:
			_room.enable_stamped_profiles(save.key)
	_room.fixed_seed = args.get("seed", "")
	_room.ward_review = not _room.orientation_review and bind == "127.0.0.1" and args.get("ward_review", "0") == "1"
	_room.reactor_review = not _room.orientation_review and not _room.ward_review and bind == "127.0.0.1" and args.get("reactor_review","0")=="1"
	if _room.reactor_review:
		_room.reactor_archive_path = "user://reactor-campaigns/"+str(args.get("reactor_campaign","owner-review")).sha256_text()
	if args.has("depth"):
		_room.first_depth = HostRules.start_depth_by_arg(true)
		say("TEST: every run starts at depth %d (depth=; tools/exported_server_check.mjs only)" % _room.first_depth)
	var settings_file: String = args.get("settings", OS.get_environment("GD_SETTINGS_FILE"))
	if not settings_file.is_empty():
		_room.desk = Room.TuningDesk.new(settings_file, say)
		say("live settings: %s, %d changed, revision %d" % [settings_file, _room.desk.asked.size(), _room.desk.rev])
	# A server needs no frame rate of its own: 250 loops a second is a 4 ms step for the 20 Hz ticks.
	Engine.max_fps = 250
	_t0 = Time.get_ticks_usec()
	say("Going Down server listening on %s:%d (one room, at most %d players), build %s" % [bind, port, WsServer.MAX_PLAYERS, _ws.build])
	_night = NightLog.new()
	OS.add_logger(_night.tap)
	_night.started(_ws.build, port)

func _now() -> float:
	return (Time.get_ticks_usec() - _t0) / 1000000.0

func _process(_delta: float) -> void:
	if _ws == null:
		return
	var now := _now()
	_ws.poll(now)
	_night.pump(_ws, _room, now)
	if _stats_every > 0.0 and now - _last_stats >= _stats_every:
		_last_stats = now
		var mean := (_room.tick_us / 1000.0 / _room.ticks) if _room.ticks > 0 else 0.0
		say("players %d, pending %d, run %s, ticks %d, %.3f ms a tick (worst %.2f ms), refused %s" % [_ws.players(), _ws.pending(),
			str(_room.epoch) if _room.running() else "none", _room.ticks, mean, _room.tick_max_us / 1000.0, JSON.stringify(_ws.refused)])
		_night.tick_stats(_room, _ws.players())
	if _quit_after > 0.0 and now >= _quit_after:
		say("stopping (quit_after)")
		_ws.stop()
		get_tree().quit(0)
