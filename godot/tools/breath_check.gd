# BR1: what can be heard on the Clinic, measured. Plays the real game headless on floor 1 (the playtest picker),
# stands the camera at the lift landing, about 2 m from the Orderly, and on another storey, and at each spot lists
# every sound player that is playing: its file, bus, volume, distance model and range, the distance to the ear and
# the level that reaches the ear (volume_db plus Godot's own distance attenuation for that model, capped at max_db,
# silent past max_distance, plus the bus fader). It also records each bus' output level over the same time.
# Usage: godot --headless --path godot -s res://tools/breath_check.gd -- [out.json]
extends SceneTree

const BUSES: Array[String] = ["Master", "Entity", "Effects", "Ambience", "Scare", "Voice", "UI"]

var out := ""
var main: Node
var caps := {}
var report := {"spots": []}

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	out = args[0] if args.size() > 0 else "user://breath_check.json"
	main = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for b in BUSES:
		var i := AudioServer.get_bus_index(b)
		if i < 0:
			continue
		var c := AudioEffectCapture.new()
		c.buffer_length = 1.0
		AudioServer.add_bus_effect(i, c)
		caps[b] = c
	_run.call_deferred()

func _cmd(c: String) -> String:
	return str(main.call("_command", c))

func _state() -> Dictionary:
	var v: Variant = JSON.parse_string(_cmd("state"))
	return v if v is Dictionary else {}

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

## Godot 4's AudioStreamPlayer3D distance attenuation (scene/3d/audio_stream_player_3d.cpp _get_attenuation_db).
static func att_db(p: AudioStreamPlayer3D, d: float) -> float:
	if p.max_distance > 0.0 and d > p.max_distance:
		return -200.0
	var a := 0.0
	var k := d / maxf(p.unit_size, 0.0001)
	match p.attenuation_model:
		AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE:
			a = linear_to_db(1.0 / (k + 0.000001))
		AudioStreamPlayer3D.ATTENUATION_INVERSE_SQUARE_DISTANCE:
			a = linear_to_db(1.0 / (k * k + 0.000001))
		AudioStreamPlayer3D.ATTENUATION_LOGARITHMIC:
			a = -20.0 * log(k + 0.000001)
	a += p.volume_db
	return minf(a, p.max_db)

static func _model(p: AudioStreamPlayer3D) -> String:
	return ["inverse", "inverse_square", "log", "disabled"][p.attenuation_model]

func _file(n: Node) -> String:
	var st: AudioStream = n.get("stream")
	if st == null:
		return "(none)"
	if st.resource_path != "":
		return st.resource_path.get_file()
	return "(copy) " + str(st.get_meta("src", ""))

func _bus_db(bus: StringName) -> float:
	var i := AudioServer.get_bus_index(bus)
	return AudioServer.get_bus_volume_db(i) if i >= 0 else 0.0

## Every playing player and the level it reaches the ear at.
func _playing() -> Array:
	# The ear is the game's camera, in the picture's SubViewport, where every 3D sound player of the game lives.
	var cam: Camera3D = main.get("cam")
	var ear := cam.global_position if cam != null else Vector3.ZERO
	var rows: Array = []
	for n: Node in root.find_children("*", "AudioStreamPlayer", true, false):
		var p := n as AudioStreamPlayer
		if p.playing:
			rows.append({"node": str(p.get_parent().name) + "/" + str(p.name), "file": _file(p), "kind": "2D", "bus": str(p.bus),
				"vol": snappedf(p.volume_db, 0.1), "ear_db": snappedf(p.volume_db + _bus_db(p.bus), 0.1)})
	for n: Node in root.find_children("*", "AudioStreamPlayer3D", true, false):
		var q := n as AudioStreamPlayer3D
		if q.playing:
			var d := ear.distance_to(q.global_position)
			rows.append({"node": str(q.get_parent().name) + "/" + str(q.name), "file": _file(q), "kind": "3D", "bus": str(q.bus),
				"vol": snappedf(q.volume_db, 0.1), "model": _model(q), "unit": q.unit_size, "max_d": q.max_distance, "max_db": q.max_db,
				"d": snappedf(d, 0.1), "ear_db": snappedf(att_db(q, d) + _bus_db(q.bus), 0.1)})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["ear_db"]) > float(b["ear_db"]))
	return rows

## Each bus' RMS level (dBFS) over what was mixed since the last call.
func _bus_rms() -> Dictionary:
	var r := {}
	for b: String in caps:
		var c: AudioEffectCapture = caps[b]
		var n := c.get_frames_available()
		if n <= 0:
			r[b] = -200.0
			continue
		var buf := c.get_buffer(n)
		var acc := 0.0
		for v: Vector2 in buf:
			acc += v.x * v.x + v.y * v.y
		r[b] = snappedf(linear_to_db(sqrt(acc / (2.0 * n)) + 1e-10), 0.1)
	return r

func _sample(label: String, seconds: float) -> void:
	for b: String in caps:
		(caps[b] as AudioEffectCapture).clear_buffer()
	var seen := {}
	var worst := {}
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	var o: Dictionary = {}
	while Time.get_ticks_msec() < end:
		await _wait(0.25)
		for row: Dictionary in _playing():
			var key := str(row["node"]) + " " + str(row["file"])
			seen[key] = int(seen.get(key, 0)) + 1
			if not worst.has(key) or float(row["ear_db"]) > float(worst[key]["ear_db"]):
				worst[key] = row
		var st := _state()
		if st.has("orderly"):
			var od: Dictionary = st["orderly"]
			o = {"mode": od["mode"], "distance": od["distance"], "level": od["level"], "seeing": od["seeing"], "exertion": (st["me"] as Dictionary).get("exertion")}
	var rows: Array = worst.values()
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["ear_db"]) > float(b["ear_db"]))
	var s := _state()
	var sfx: Node = main.get("sfx")
	var sc: Camera3D = sfx.call("ear_camera") if sfx.has_method("ear_camera") else sfx.get_viewport().get_camera_3d()
	print("   the ear the Sfx node uses: ", sc.get_path() if sc != null else "none (every distance reads 0 m)", " at ", sc.global_position if sc != null else "-")
	var spot := {"label": label, "cam": s.get("camPos"), "orderly": o, "buses_rms_db": _bus_rms(), "playing_loudest": rows, "samples": seen}
	report["spots"].append(spot)
	print("== ", label, " cam ", s.get("camPos"), " orderly ", o)
	print("   buses ", spot["buses_rms_db"])
	for r: Dictionary in rows:
		print("   ", r)

func _walk(plan: Dictionary, lv: int, x: int, y: int) -> bool:
	var w := int(plan["width"])
	var h := int(plan["height"])
	if x < 0 or y < 0 or x >= w or y >= h or lv < 0 or lv >= (plan["cells"] as Array).size():
		return false
	var cells: Array = (plan["cells"] as Array)[lv]
	var dist: Array = plan["liftDist"]
	return str(cells[y * w + x]) in ["corridor", "room", "landing", "atriumOpen"] and float(dist[lv * w * h + y * w + x]) >= 0.0

## A walkable cell on level `lv` whose distance to (cx, cy) in metres is nearest to `want`.
func _cell_at(plan: Dictionary, lv: int, cx: float, cy: float, want: float) -> Variant:
	var best: Variant = null
	var bd := 1e9
	for y in int(plan["height"]):
		for x in int(plan["width"]):
			if not _walk(plan, lv, x, y):
				continue
			var d := Vector2((x + 0.5) * 2.0 - cx, (y + 0.5) * 2.0 - cy).length()
			if absf(d - want) < bd:
				bd = absf(d - want)
				best = [x, y, d]
	return best

func _run() -> void:
	Engine.max_fps = 60
	await _wait(1.5)
	for i in 300:
		if _cmd("ui playtest") == "ok":
			break
		await process_frame
	await _wait(1.0)
	_cmd("ui 1")
	var s := await _until(func(st: Dictionary) -> bool: return st.has("phase"), 40.0)
	_cmd("click")
	s = await _until(func(st: Dictionary) -> bool: return st.get("phase") == "unloading" and float((st["client"] as Dictionary)["doors"]) > 0.95, 30.0)
	var plan: Dictionary = JSON.parse_string(_cmd("plan"))
	report["place"] = s.get("place")
	report["depth"] = s.get("depth")
	print("place ", s.get("place"), " depth ", s.get("depth"), " phase ", s.get("phase"))
	var landing: Dictionary = plan["landing"]
	var llv := int(landing["level"])
	# (a) The lift landing, just out of the car, the Orderly far and asleep.
	_cmd("teleport %d %d %d" % [llv, int(landing["x"]), int(landing["y"])])
	await _sample("A landing, orderly asleep", 6.0)
	var o0: Dictionary = _state()["orderly"]
	var olv := int(o0["level"])
	var ox := float(o0["x"])
	var oz := float(o0["z"])
	# (b) About 2 m from it, looking away (unseen, so it breathes).
	var near: Variant = _cell_at(plan, olv, ox, oz, 2.0)
	if near != null:
		_cmd("teleport %d %d %d" % [olv, int(near[0]), int(near[1])])
		var me: Dictionary = _state()["me"]
		_cmd("face %f %f" % [2.0 * float(me["x"]) - ox, 2.0 * float(me["z"]) - oz])
		await _sample("B ~2 m from the orderly (cell d %.1f m), facing away" % float(near[2]), 6.0)
	# (c) Another storey: straight above or below it, then far on that storey.
	var other := olv + 1 if olv + 1 < (plan["cells"] as Array).size() else olv - 1
	if other >= 0 and other != olv:
		var over: Variant = _cell_at(plan, other, ox, oz, 0.0)
		if over != null:
			_cmd("teleport %d %d %d" % [other, int(over[0]), int(over[1])])
			await _sample("C other storey (level %d) over the orderly (level %d)" % [other, olv], 6.0)
	# (d) The landing again, after it has been near (active or waking).
	_cmd("teleport %d %d %d" % [llv, int(landing["x"]), int(landing["y"])])
	await _sample("D landing again, after", 10.0)
	# (e) Stay near it longer so it wakes and moves (active), then the landing while it hunts.
	if near != null:
		_cmd("teleport %d %d %d" % [olv, int(near[0]), int(near[1])])
		await _sample("E near again, 15 s", 15.0)
		_cmd("teleport %d %d %d" % [llv, int(landing["x"]), int(landing["y"])])
		await _sample("F landing, orderly after waking", 10.0)
	# (g) Close behind it wherever it is now, facing away, on its storey.
	var o1: Dictionary = _state()["orderly"]
	var g: Variant = _cell_at(plan, int(o1["level"]), float(o1["x"]), float(o1["z"]), 2.5)
	if g != null:
		_cmd("teleport %d %d %d" % [int(o1["level"]), int(g[0]), int(g[1])])
		var me2: Dictionary = _state()["me"]
		_cmd("face %f %f" % [2.0 * float(me2["x"]) - float(o1["x"]), 2.0 * float(me2["z"]) - float(o1["z"])])
		await _sample("G close behind the orderly (cell d %.1f m), facing away" % float(g[2]), 4.0)
	var f := FileAccess.open(out, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(report, "  "))
	print("BREATH_CHECK_DONE ", out)
	quit(0)
