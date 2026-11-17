# The mix on the Annex and the Playroom, measured (MIX.md, the owner's V21): the busy minute
# (tools/mix_check.gd) plays the Clinic; this plays each newer floor's loudest moments through the real
# sound code (client/sfx.gd, temp_view.gd, minder_view.gd) and the real buses, headless, from a camera at
# the origin with nothing in the way (no walls: the worst case), and records what every bus outputs
# (an AudioEffectCapture at the end of each bus, as mix_check.gd does). tools/mix_check.mjs measures and
# judges it against the voice heard in the same run (four elevator lines on the Voice bus at the
# announcer's -5 dB, the beds ducking under them).
#   The Annex: the office tone; the voice while the Temp walks up clicking, its steps near; the phone from
#   everywhere and the photocopier at 3 m; the blink and blackout warnings (the sagging buzz); the Temp
#   standing at 1 m clicking; a catch (the roar, then the stapler going in); the lift's bell.
#   The Playroom: the play-centre tone and the tune; the voice while the Minder walks up with its music
#   box, then stands wheezing; the count (the three notes, the bell once a second rising in the last five,
#   the tune sagging); the Minder scrambling past at 3 m on all fours; squeaker tiles, the ball pit, hides;
#   its huff at 2 m; the found-you sting; going down.
#   The prison: the block's night; the voice; the call panel refusing, then the quota met; the ride up; a
#   bunk creaking 2 m off and your own; lights out.
# Usage: godot --headless --path godot -s res://tools/mix_check_floors.gd -- <out folder> <annex|playroom|prison> [break=office|sting]
#   break=office  the Annex's office tone 12 dB up (the mix check must fail)
#   break=sting   the found-you sting 8 dB up (the mix check must fail)
extends SceneTree

const BUSES: Array[String] = ["Master", "Voice", "Entity", "Scare", "Effects", "Ambience", "UI"]
const Places = preload("res://sim/places.gd")
const Floor = preload("res://sim/floor.gd")
const TempViewScript = preload("res://client/temp_view.gd")
const MinderViewScript = preload("res://client/minder_view.gd")
const LINES: Array[String] = ["arrived_1", "called_2", "doors_3", "board_1"]

var out := ""
var floor_name := "annex"
var brk := ""
var caps := {}
var data := {}
var frames := 0
var rate := 44100.0
var marks: Array = []          # [{t, what}]
var world: Node3D
var cam: Camera3D
var sfx: Sfx
var voice: AudioStreamPlayer
var _voice_on := false

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	out = args[0] if args.size() > 0 else "user://mix_floors"
	floor_name = args[1] if args.size() > 1 else "annex"
	for a in args:
		if a.begins_with("break="):
			brk = a.substr(6)
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
	world = Node3D.new()
	root.add_child(world)
	cam = Camera3D.new()
	world.add_child(cam)
	cam.position = Vector3(0, 1.6, 0)
	cam.current = true
	sfx = Sfx.new()
	root.add_child(sfx)
	sfx.setup(world)
	voice = AudioStreamPlayer.new()
	voice.bus = "Voice"
	voice.volume_db = -5.0
	root.add_child(voice)
	_run.call_deferred()

func _process(delta: float) -> bool:
	_drain()
	if sfx != null:
		sfx.duck(_voice_on and voice.playing, delta)
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
		# Before the bus fader: apply it (the duck moves it), so this is what the bus sends to Master.
		var k_gain := db_to_linear(AudioServer.get_bus_volume_db(AudioServer.get_bus_index(b))) if b != "Master" else 1.0
		for k in n:
			arr[base + k * 2] = buf[k].x * k_gain
			arr[base + k * 2 + 1] = buf[k].y * k_gain
		data[b] = arr
		if b == "Master":
			n_master = n
	frames += n_master

func _t() -> float:
	return frames / rate

func _mark(what: String) -> void:
	marks.append({"t": _t(), "what": what})

func _wait(sec: float, each: Callable = Callable()) -> void:
	var end := Time.get_ticks_msec() + int(sec * 1000.0)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() < end:
		if each.is_valid():
			each.call((Time.get_ticks_msec() - t0) / 1000.0)
		await process_frame

## The four elevator lines one after another, the beds ducking under them.
func _speak(during: Callable = Callable()) -> void:
	_mark("voice")
	_voice_on = true
	var t0 := Time.get_ticks_msec()
	for id in LINES:
		voice.stream = load("res://assets/voice/bella/%s.mp3" % id)
		voice.play()
		await process_frame
		while voice.playing:
			if during.is_valid():
				during.call((Time.get_ticks_msec() - t0) / 1000.0)
			await process_frame
	_voice_on = false
	_mark("voice_end")

func _plan_dict(fp: Floor.FloorPlan, place: String, depth: int) -> Dictionary:
	var rooms: Array = []
	for r in fp.rooms:
		rooms.append({"kind": String(r.kind), "x": r.x, "y": r.y, "w": r.w, "h": r.h, "level": r.level})
	return {"place": place, "depth": depth, "rooms": rooms, "doors": []}

func _pose(at: Vector3, anim: String, t: float) -> Dictionary:
	return {"x": at.x, "y": at.y, "z": at.z, "level": 0, "yaw": 0.0, "anim": anim, "animTime": t}

func _run() -> void:
	Engine.max_fps = 60
	for i in 10:
		await process_frame
	if floor_name == "playroom":
		await _playroom()
	elif floor_name == "prison":
		await _prison()
	else:
		await _annex()
	await _wait(1.0)
	_save()
	quit(0)

func _annex() -> void:
	var fp := Places.generate("mix-annex", 3)
	sfx.set_floor(_plan_dict(fp, "annex", 3), "mix-annex")
	var temp: Node3D = TempViewScript.new()
	world.add_child(temp)
	var bed := func(_t: float) -> void:
		sfx.set_hum(1.0, false)
		if brk == "office":
			sfx.hum.volume_db += 12.0
		sfx.world(1.0 / 60.0, {"t": 0.0}, 0.0)
	_mark("bed")
	await _wait(4.0, bed)
	# The voice, while the Temp walks up from 14 m to 2 m in front (clicking every 1.2 m, its steps near).
	var walk_t := [0.0]
	await _speak(func(t: float) -> void:
		bed.call(t)
		walk_t[0] = t
		var d := maxf(2.0, 14.0 - t * 1.2)
		temp.call("show_pose", _pose(Vector3(0, 0, -d), "walk", t), true))
	# The phone from everywhere, the photocopier 3 m off.
	_mark("phone")
	sfx.play("phone", Sfx.PHONE_DB)
	await _wait(1.5, bed)
	sfx.play_at("copier", Vector3(3, 1, 0))
	await _wait(6.0, bed)
	# The blink warning and the blackout's (the sagging buzz), cut as the lights go.
	_mark("warn")
	sfx.play("blink_warn")
	await _wait(0.6, bed)
	sfx.stop("blink_warn")
	await _wait(1.5, bed)
	sfx.play("blackout_warn")
	await _wait(3.0, bed)
	sfx.stop("blackout_warn")
	# The Temp standing 1 m away, clicking every 4 s of its clock, then walking the last metre.
	_mark("temp_close")
	await _wait(9.0, func(t: float) -> void:
		bed.call(t)
		var d := 1.0 if t < 8.0 else 1.0 - (t - 8.0)
		temp.call("show_pose", _pose(Vector3(0, 0, -maxf(0.4, d)), "idle" if t < 8.0 else "walk", 20.0 + t), true))
	temp.call("show_pose", null, false)
	# A catch: the roar in your face, then the stapler going in.
	_mark("caught")
	sfx.caught(true, null)
	await _wait(4.0, func(t: float) -> void:
		bed.call(t)
		sfx.update(1.0 / 60.0, {}, null, 0.0, 0.0, 0.0, false, 0.0, Vector3.ZERO))
	# The lift's bell from every ceiling speaker.
	_mark("chime")
	sfx.play("chime")
	await _wait(3.0, bed)
	_mark("end")

func _playroom() -> void:
	var fp := Places.generate("mix-playroom", 4)
	sfx.set_floor(_plan_dict(fp, "playroom", 4), "mix-playroom")
	var minder: Node3D = MinderViewScript.new()
	world.add_child(minder)
	var sag := [0.0]
	var bed := func(_t: float) -> void:
		sfx.set_hum(1.0, false)
		sfx.playroom(true, sag[0])
		sfx.world(1.0 / 60.0, {"t": 0.0}, 0.0)
		sfx.update(1.0 / 60.0, {}, null, 0.0, 0.0, 0.0, false, 0.0, Vector3.ZERO)
	_mark("bed")
	await _wait(4.0, bed)
	# The voice while the Minder walks up with its music box from 20 m to 2 m, then stands wheezing.
	await _speak(func(t: float) -> void:
		bed.call(t)
		var d := 20.0 - t * 1.6
		if d > 2.0:
			minder.call("show_pose", _pose(Vector3(0, 0, -d), "walk", t), true)
		else:
			minder.call("show_pose", _pose(Vector3(0, 0, -2.0), "stand", t), true))
	_mark("wheeze")
	await _wait(4.0, func(t: float) -> void:
		bed.call(t)
		minder.call("show_pose", _pose(Vector3(0, 0, -2.0), "stand", 30.0 + t), true))
	# The count: the three notes, then a bell stroke a second, rising in the last five, the tune sagging.
	_mark("count")
	sfx.play("xylo")
	await _wait(1.5, func(t: float) -> void:
		sag[0] = clampf(t / 1.5, 0.0, 1.0)
		bed.call(t))
	_mark("bell")
	for left in range(10, 0, -1):
		sfx.count_bell(left)
		await _wait(1.0, bed)
	_mark("bell_end")
	sag[0] = 0.0
	# On all fours past at 3 m, fast (the scramble and the box).
	_mark("run")
	await _wait(3.0, func(t: float) -> void:
		bed.call(t)
		minder.call("show_pose", _pose(Vector3(-10.0 + t * 7.0, 0, -3.0), "run", 40.0 + t), true))
	minder.call("show_pose", null, false)
	# Squeaker tiles, the ball pit, hides (yours, here).
	_mark("toys")
	sfx.squeaker(null)
	await _wait(0.6, bed)
	sfx.squeaker(null)
	await _wait(0.8, bed)
	sfx.ball_pit(true, null)
	await _wait(2.0, bed)
	sfx.hide_move("chest", true, true, null)
	await _wait(2.0, bed)
	sfx.hide_move("den", false, true, null)
	await _wait(2.0, bed)
	# Its huff at an empty hide 2 m away.
	_mark("huff")
	sfx.huff_at(Vector3(0, 1.4, -2.0))
	await _wait(4.0, bed)
	# Found: the sting in your ear.
	_mark("found")
	if brk == "sting":
		sfx.play("found", 8.0)
	else:
		sfx.found_me()
	await _wait(3.5, bed)
	_mark("down")
	sfx.went_down(null)
	await _wait(2.5, bed)
	_mark("end")

## The prison and the lift (the rest of the 17 Nov list): the block's night, the voice, the call panel
## refusing and then the quota met, the ride up, a bunk creaking near you and your own, lights out.
func _prison() -> void:
	sfx.set_floor({"place": "prison", "depth": 0, "rooms": [], "doors": []}, "mix-prison")
	var bed := func(_t: float) -> void:
		sfx.set_hum(1.0, false)
		sfx.world(1.0 / 60.0, {"t": 0.0}, 0.0)
	_mark("bed")
	await _wait(4.0, bed)
	await _speak(bed)
	_mark("panel")
	sfx.play("refused")
	await _wait(1.5, bed)
	sfx.play("quota_met")
	await _wait(2.5, bed)
	_mark("up")
	sfx.world(1.0 / 60.0, {"t": 0.0, "events": [{"type": "carLeft", "t": 1.0, "reason": "up"}]}, 0.0)
	sfx.ride(true)
	await _wait(8.5, bed)
	sfx.ride(false)
	_mark("bunks")
	sfx.world(1.0 / 60.0, {"t": 0.0, "me": {"id": "me"}, "others": [{"id": "b", "x": 2.0, "y": 0.0, "z": -1.0}],
		"events": [{"type": "bed", "t": 2.0, "playerId": "b", "inBed": true}]}, 0.0)
	await _wait(2.0, bed)
	sfx.world(1.0 / 60.0, {"t": 0.0, "me": {"id": "me"}, "events": [{"type": "bed", "t": 3.0, "playerId": "me", "inBed": true}]}, 0.0)
	await _wait(2.5, bed)
	_mark("lights_out")
	sfx.world(1.0 / 60.0, {"t": 0.0, "events": [{"type": "lightsOut", "t": 4.0}]}, 0.0)
	await _wait(7.5, func(t: float) -> void:
		sfx.set_hum(0.0, false)
		sfx.world(1.0 / 60.0, {"t": 0.0}, 0.0))
	_mark("end")

func _save() -> void:
	_drain()
	for b: String in data:
		var f := FileAccess.open(out.path_join(b + ".f32"), FileAccess.WRITE)
		f.store_buffer((data[b] as PackedFloat32Array).to_byte_array())
		f.close()
	var meta := {"rate": rate, "seconds": frames / rate, "floor": floor_name, "break": brk, "marks": marks, "played": sfx.played.map(func(p: Dictionary) -> String: return str(p["name"]))}
	var j := FileAccess.open(out.path_join("timeline.json"), FileAccess.WRITE)
	j.store_string(JSON.stringify(meta))
	j.close()
	print("mix_check_floors: %s, %.1f s recorded at %d Hz into %s" % [floor_name, frames / rate, int(rate), out])
