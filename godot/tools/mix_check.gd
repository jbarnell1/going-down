# The mix, measured: plays a busy minute of the real game headless (the welcome line, a lit floor, the
# Orderly watched and then coming on unseen, the lift called, the announcer answering, the blinks and the
# blackout), records what every bus actually outputs (an AudioEffectCapture at the end of each bus, the
# Master one after its limiter) as raw float32 stereo, and logs what the rules said 10 times a second.
# tools/mix_check.mjs runs this, measures the recordings (ffmpeg ebur128) and judges them.
# Usage: godot --headless --path godot -s res://tools/mix_check.gd -- <out folder>
extends SceneTree

const BUSES: Array[String] = ["Master", "Voice", "Entity", "Scare", "Effects", "Ambience", "UI"]
const MAX_SECONDS := 110.0

var out := ""
var main: Node
var caps := {}         # bus -> AudioEffectCapture
var data := {}         # bus -> PackedFloat32Array (interleaved L R)
var frames := 0        # Master frames captured so far (the timeline's clock)
var rate := 44100.0
var timeline: Array = []
var _next_log := 0.0
var _played_seen := 0

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	out = args[0] if args.size() > 0 else "user://mix_check"
	DirAccess.make_dir_recursive_absolute(out)
	rate = AudioServer.get_mix_rate()
	# The game first: its sound code adds its own effects to the buses (the Ambience low-pass), and adding
	# an effect to a bus starts that bus' effects afresh, emptying a capture already there. Captures added
	# before it lost up to 2 s of the Ambience recording, so the Ambience ran early against the timeline
	# and the duck seemed to let go before the voice ended. Added after, every bus starts on the same frame.
	main = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for b in BUSES:
		var i := AudioServer.get_bus_index(b)
		if i < 0:
			push_error("no bus " + b)
			continue
		var c := AudioEffectCapture.new()
		c.buffer_length = 2.0
		AudioServer.add_bus_effect(i, c)
		caps[b] = c
		data[b] = PackedFloat32Array()
	_run.call_deferred()

func _process(_delta: float) -> bool:
	_drain()
	return false

func _drain() -> void:
	var n_master := 0
	for b: String in caps:
		var c: AudioEffectCapture = caps[b]
		var n := c.get_frames_available()
		if n <= 0:
			continue
		var buf := c.get_buffer(n)
		var arr: PackedFloat32Array = data[b]
		var base := arr.size()
		arr.resize(base + n * 2)
		# The capture sits before the bus' fader: apply it (the duck moves the fader), so this is what the
		# bus sends to Master.
		var k_gain := db_to_linear(AudioServer.get_bus_volume_db(AudioServer.get_bus_index(b))) if b != "Master" else 1.0
		for k in n:
			arr[base + k * 2] = buf[k].x * k_gain
			arr[base + k * 2 + 1] = buf[k].y * k_gain
		data[b] = arr
		if b == "Master":
			n_master = n
	frames += n_master
	var t := frames / rate
	if t >= _next_log:
		_next_log = t + 0.1
		_log(t)

func _cmd(c: String) -> String:
	return str(main.call("_command", c))

func _state() -> Dictionary:
	var v: Variant = JSON.parse_string(_cmd("state"))
	return v if v is Dictionary else {}

func _log(t: float) -> void:
	var s := _state()
	var row := {"t": t}
	if s.has("orderly"):
		var o: Dictionary = s["orderly"]
		var sq: Dictionary = o["squeak"]
		row["o"] = {"moving": o["moving"], "held": o["held"], "seeing": o["seeing"], "d": o["distance"], "g": sq["gain"], "m": sq["muffled"], "mode": o["mode"]}
		row["dark"] = s["dark"]
		row["blackout"] = s["blackout"]
		row["phase"] = s["phase"]
	var ann: Node = main.get("announcer")
	var ap: AudioStreamPlayer = ann.get("player")
	row["voice"] = ap.playing
	var sfx: Node = main.get("sfx")
	var played: Array = sfx.get("played")
	var names: Array = []
	for p: Dictionary in played:
		if int(p["ms"]) > _played_seen:
			names.append(p["name"])
	if not played.is_empty():
		_played_seen = maxi(_played_seen, int(played[played.size() - 1]["ms"]))
	row["played"] = names
	var loops: Array = []
	var d: Dictionary = sfx.call("describe")
	for k: String in d["loops"]:
		if bool(d["loops"][k]["playing"]):
			loops.append(k)
	row["loops"] = loops
	row["duck"] = d["duck"]
	row["speaking"] = ann.call("speaking")
	row["amb_db"] = AudioServer.get_bus_volume_db(AudioServer.get_bus_index("Ambience"))
	row["amb_lag"] = ((data["Master"] as PackedFloat32Array).size() - (data["Ambience"] as PackedFloat32Array).size()) / 2
	timeline.append(row)

func _wait(sec: float) -> void:
	var end := Time.get_ticks_msec() + int(sec * 1000.0)
	while Time.get_ticks_msec() < end:
		await process_frame

func _until(pred: Callable, sec: float) -> Dictionary:
	var end := Time.get_ticks_msec() + int(sec * 1000.0)
	var s := _state()
	while not pred.call(s) and Time.get_ticks_msec() < end:
		await process_frame
		s = _state()
	return s

func _run() -> void:
	Engine.max_fps = 60
	# Start every recording on the same frame once the game's beds are playing: even with the captures added
	# after the game, the Ambience came out 0.28 s short (all of it lost in the first 0.3 s, before its beds
	# start; a bus with nothing on it seems not to run its effects), so early against the rest.
	await _wait(1.0)
	for b: String in caps:
		(caps[b] as AudioEffectCapture).clear_buffer()
		data[b] = PackedFloat32Array()
	frames = 0
	_next_log = 0.0
	timeline.clear()
	for i in 200:
		if _cmd("ui alone") == "ok":
			break
		await process_frame
	await _until(func(s: Dictionary) -> bool: return (s.get("screen", {}) as Dictionary).get("screen", "") == "face", 5.0)
	_cmd("draw done")
	await _until(func(s: Dictionary) -> bool: return s.has("phase"), 20.0)
	_cmd("click")
	var plan: Dictionary = JSON.parse_string(_cmd("plan"))
	await _until(func(s: Dictionary) -> bool: return s.get("phase") == "unloading" and float((s["client"] as Dictionary)["doors"]) > 0.95, 15.0)
	# Step out while the welcome plays (the voice over a lit floor: the duck).
	_cmd("move 1 0 0 0")
	await _wait(1.2)
	_cmd("stopmove")
	await _wait(5.0)
	# The Orderly: watch it from down its corridor, then turn away and let it come on unseen.
	# Where it really waits (since the Orderly fix, sim/orderly_fix.gd, a seeded cell in the dirty part, not the
	# plan's entityStart): the rules' body now.
	var o0: Dictionary = _state()["orderly"]
	var es := {"level": int(o0["level"]), "x": floori(float(o0["x"]) / 2.0), "y": floori(float(o0["z"]) / 2.0)}
	var spots: Array[Dictionary] = []
	var spot := _watch_spot(plan, es)
	if not spot.is_empty():
		spots.append(spot)
	spots.append_array(_near_spots(plan, es))
	var ex := float(o0["x"])
	var ez := float(o0["z"])
	for i in mini(spots.size(), 12):
		_cmd("teleport %d %d %d" % [int(es["level"]), int(spots[i]["x"]), int(spots[i]["y"])])
		await _wait(0.3)
		var on: Dictionary = _state()["orderly"]
		ex = float(on["x"])
		ez = float(on["z"])
		_cmd("face %f %f %f" % [ex, ez, (float((on["pose"] as Dictionary)["y"]) if on["pose"] is Dictionary else float(es["level"]) * 3.2) + 1.4])
		var seen := await _until(func(st: Dictionary) -> bool: return bool((st["orderly"] as Dictionary)["seeing"]), 1.5)
		if bool((seen["orderly"] as Dictionary)["seeing"]):
			break
	await _wait(3.0)
	var s := _state()
	ex = float((s["orderly"] as Dictionary)["x"])
	ez = float((s["orderly"] as Dictionary)["z"])
	var me: Dictionary = s["me"]
	_cmd("face %f %f" % [2.0 * float(me["x"]) - ex, 2.0 * float(me["z"]) - ez])
	s = await _until(func(st: Dictionary) -> bool: return float((st["orderly"] as Dictionary)["distance"]) < 3.0, 14.0)
	var o: Dictionary = s["orderly"]
	_cmd("face %f %f %f" % [float(o["x"]), float(o["z"]), float((o["pose"] as Dictionary)["y"]) + 1.3 if o["pose"] is Dictionary else 1.3])
	await _wait(2.5)
	# The lift: call it, and wait out the blinks and the blackout facing away from the Orderly.
	var landing: Dictionary = plan["landing"]
	_cmd("teleport %d %d %d" % [int(landing["level"]), int(landing["x"]), int(landing["y"])])
	var car: Dictionary = plan["car"]
	_cmd("face %f %f 2.0" % [float(car["doorX"]), float(car["doorZ"])])
	s = await _until(func(st: Dictionary) -> bool: return bool((st["me"] as Dictionary).get("canCall", false)), 4.0)
	_cmd("call")
	var t0 := Time.get_ticks_msec()
	s = await _until(func(st: Dictionary) -> bool: return st.get("phase") != "coming" and Time.get_ticks_msec() - t0 > 3000 or frames / rate > MAX_SECONDS, MAX_SECONDS)
	await _wait(3.0)
	_save()
	quit(0)

func _watch_spot(plan: Dictionary, es: Dictionary) -> Dictionary:
	var best := {}
	for sl: Dictionary in plan["sightlines"]:
		if int(sl["level"]) != int(es["level"]):
			continue
		var x1 := int(sl["x1"])
		var x2 := int(sl["x2"])
		var y1 := int(sl["y1"])
		var y2 := int(sl["y2"])
		var on := (x1 == x2 and x1 == int(es["x"]) and int(es["y"]) >= mini(y1, y2) and int(es["y"]) <= maxi(y1, y2)) or (y1 == y2 and y1 == int(es["y"]) and int(es["x"]) >= mini(x1, x2) and int(es["x"]) <= maxi(x1, x2))
		if not on:
			continue
		for x in range(mini(x1, x2), maxi(x1, x2) + 1):
			for y in range(mini(y1, y2), maxi(y1, y2) + 1):
				var d := Vector2(x - int(es["x"]), y - int(es["y"])).length() * 2.0
				if d <= 12.0 and (best.is_empty() or d > float(best["d"])):
					best = {"x": x, "y": y, "d": d}
	return best

## The far start is not always on a listed sightline: the walkable cells of its level 4 to 10 m off with an open
## straight line of cells to it, those in its row or column first, the farthest first.
func _near_spots(plan: Dictionary, es: Dictionary) -> Array[Dictionary]:
	var w := int(plan["width"])
	var h := int(plan["height"])
	var lv := int(es["level"])
	var cells: Array = (plan["cells"] as Array)[lv]
	var dist: Array = plan["liftDist"]
	var walk := func(x: int, y: int) -> bool:
		return x >= 0 and y >= 0 and x < w and y < h and str(cells[y * w + x]) in ["corridor", "room", "landing", "atriumOpen"] and float(dist[lv * w * h + y * w + x]) >= 0.0
	var out: Array[Dictionary] = []
	var sx := int(es["x"])
	var sy := int(es["y"])
	for y in h:
		for x in w:
			var d := Vector2(x - sx, y - sy).length() * 2.0
			if d < 4.0 or d > 10.0 or not walk.call(x, y):
				continue
			var n := int(ceil(d / 2.0)) * 2
			var clear := true
			for i in range(1, n):
				if not walk.call(floori(sx + 0.5 + float((x - sx) * i) / n), floori(sy + 0.5 + float((y - sy) * i) / n)):
					clear = false
					break
			if clear:
				out.append({"x": x, "y": y, "d": d, "line": 1 if x == sx or y == sy else 0})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["line"] > b["line"] if a["line"] != b["line"] else float(a["d"]) > float(b["d"]))
	return out

func _save() -> void:
	_drain()
	for b: String in data:
		var f := FileAccess.open(out.path_join(b + ".f32"), FileAccess.WRITE)
		f.store_buffer((data[b] as PackedFloat32Array).to_byte_array())
		f.close()
	var meta := {"rate": rate, "seconds": frames / rate, "timeline": timeline}
	var j := FileAccess.open(out.path_join("timeline.json"), FileAccess.WRITE)
	j.store_string(JSON.stringify(meta))
	j.close()
	print("mix_check: %.1f s recorded at %d Hz into %s" % [frames / rate, int(rate), out])
