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
	main = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(main)
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
	var es: Dictionary = plan["entityStart"]
	var spot := _watch_spot(plan, es)
	if not spot.is_empty():
		_cmd("teleport %d %d %d" % [int(es["level"]), int(spot["x"]), int(spot["y"])])
	await _wait(0.3)
	var ex := (float(es["x"]) + 0.5) * 2.0
	var ez := (float(es["y"]) + 0.5) * 2.0
	_cmd("face %f %f %f" % [ex, ez, float(es["level"]) * 3.2 + 1.4])
	await _wait(3.0)
	var s := _state()
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
