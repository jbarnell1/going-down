# The game's sounds, made here from a few lines of arithmetic (no files): the trolley squeak (in the
# world, at the Orderly, louder and clearer the nearer and the more in view, from the rules'
# audibility), the instrument's ticking, the lift's chimes, dings, doors, bell and machinery, the
# lights failing, being taken, the ride, and breathing when winded. Stand-ins in the spirit of
# src/game/audio.ts; nobody has listened to them yet.
class_name Sfx
extends Node

const RATE := 22050

var streams := {}
var _one_shots: Array[AudioStreamPlayer] = []
var squeak: AudioStreamPlayer3D
var machinery: AudioStreamPlayer3D
var breath: AudioStreamPlayer
var ride_loop: AudioStreamPlayer
var hum: AudioStreamPlayer
var _squeak_bus := -1
var _tick_phase := 0.0
var _rng := RandomNumberGenerator.new()

func setup(world_parent: Node3D) -> void:
	_rng.seed = 7
	_make_buses()
	streams["tick"] = _wav(_tick(), false)
	streams["chime"] = _wav(_tones([[660.0, 0.0], [880.0, 0.32]], 1.3, 0.5), false)
	streams["chime_far"] = _wav(_tones([[660.0, 0.0], [880.0, 0.32]], 1.3, 0.18), false)
	streams["ding"] = _wav(_tones([[1320.0, 0.0]], 0.35, 0.25), false)
	streams["bell"] = _wav(_bell(), false)
	streams["bell_warn"] = _wav(_tones([[1760.0, 0.0]], 0.22, 0.3), false)
	streams["doors"] = _wav(_doors(), false)
	streams["doors_far"] = _wav(_scale(_doors(), 0.3), false)
	streams["blink_warn"] = _wav(_buzz(0.6), false)
	streams["blackout_warn"] = _wav(_winddown(3.0), false)
	streams["blink"] = _wav(_thump(), false)
	streams["caught"] = _wav(_noise(2.0, 0.6), false)
	streams["slip"] = _wav(_printer(), false)
	streams["closed"] = _wav(_tones([[990.0, 0.0], [1480.0, 0.08]], 0.4, 0.25), false)
	for i in 6:
		var p := AudioStreamPlayer.new()
		p.bus = "Sfx"
		add_child(p)
		_one_shots.append(p)
	squeak = AudioStreamPlayer3D.new()
	squeak.stream = _wav(_squeak(), true)
	squeak.bus = "Squeak"
	squeak.unit_size = 6.0
	squeak.max_distance = 40.0
	squeak.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
	world_parent.add_child(squeak)
	machinery = AudioStreamPlayer3D.new()
	machinery.stream = _wav(_rumble(2.0, 55.0), true)
	machinery.bus = "Sfx"
	machinery.unit_size = 5.0
	world_parent.add_child(machinery)
	breath = AudioStreamPlayer.new()
	breath.stream = _wav(_breathing(), true)
	breath.bus = "Sfx"
	add_child(breath)
	# The ceiling tubes' hum: always there while the lights are on, gone in the dark.
	hum = AudioStreamPlayer.new()
	hum.stream = _wav(_hum(), true)
	hum.bus = "Sfx"
	hum.volume_db = -20.0
	add_child(hum)
	ride_loop = AudioStreamPlayer.new()
	ride_loop.stream = _wav(_rumble(2.0, 42.0), true)
	ride_loop.bus = "Sfx"
	add_child(ride_loop)

## The buses (Sfx, Squeak with its low-pass, Voice as a ceiling speaker: band-limited and
## compressed) are declared in res://default_bus_layout.tres, NOT added here at run time: in the
## browser's "Sample" playback mode (the web default) buses added with AudioServer.add_bus left the
## whole web audio graph silent (measured with tools/sound_web.mjs). In the browser the bus effects
## do not apply (Sample mode plays through Web Audio directly); on the desktop they do.
func _make_buses() -> void:
	_squeak_bus = AudioServer.get_bus_index("Squeak")
	if _squeak_bus >= 0 and AudioServer.get_bus_effect_count(_squeak_bus) == 0:
		_squeak_bus = -1

func play(name: String, gain_db := 0.0) -> void:
	if not streams.has(name):
		return
	for p in _one_shots:
		if not p.playing:
			p.stream = streams[name]
			p.volume_db = gain_db
			p.play()
			return
	_one_shots[0].stream = streams[name]
	_one_shots[0].volume_db = gain_db
	_one_shots[0].play()

## Per frame: the squeak from the rules' audibility, the ticking, breathing, the lift's machinery.
func update(delta: float, sq: Dictionary, pose: Variant, tick_hz: float, loudness: float, exertion: float, winded: bool, machine: float, door_pos: Vector3) -> void:
	var g := float(sq.get("gain", 0.0))
	if g > 0.001 and pose != null:
		squeak.global_position = Vector3(float(pose.x), float(pose.y) + 0.4, float(pose.z))
		squeak.volume_db = linear_to_db(g) + 2.0
		if not squeak.playing:
			squeak.play()
		if _squeak_bus >= 0:
			var lp := AudioServer.get_bus_effect(_squeak_bus, 0) as AudioEffectLowPassFilter
			lp.cutoff_hz = 900.0 if sq.get("muffled", false) else 20000.0
	elif squeak.playing:
		squeak.stop()
	# Ticking: tickHz ticks a second at the given loudness.
	if tick_hz > 0.0:
		_tick_phase += tick_hz * delta
		if _tick_phase >= 1.0:
			_tick_phase -= floor(_tick_phase)
			play("tick", linear_to_db(maxf(0.02, loudness)))
	else:
		_tick_phase = 0.0
	# Breathing that rises as the tank empties, ragged when winded.
	if exertion > 0.15:
		breath.volume_db = linear_to_db(clampf((exertion - 0.15) * 1.1, 0.0, 1.0)) - (0.0 if winded else 6.0)
		breath.pitch_scale = 1.15 if winded else 1.0
		if not breath.playing:
			breath.play()
	elif breath.playing:
		breath.stop()
	if machine > 0.0:
		machinery.global_position = door_pos
		machinery.volume_db = linear_to_db(clampf(machine, 0.05, 1.0)) - 4.0
		if not machinery.playing:
			machinery.play()
	elif machinery.playing:
		machinery.stop()

## The hum follows the lights (1 as built, 0 out).
func set_hum(light: float) -> void:
	if light < 0.05:
		if hum.playing:
			hum.stop()
		return
	hum.volume_db = -20.0 + linear_to_db(clampf(light, 0.05, 1.0))
	if not hum.playing:
		hum.play()

func ride(on: bool) -> void:
	if on and not ride_loop.playing:
		ride_loop.play()
	elif not on:
		ride_loop.stop()

# --- synthesis ------------------------------------------------------------------------------------

func _wav(samples: PackedFloat32Array, loop: bool) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = samples.size()
	return w

func _buf(seconds: float) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(int(seconds * RATE))
	return a

func _scale(a: PackedFloat32Array, k: float) -> PackedFloat32Array:
	for i in a.size():
		a[i] *= k
	return a

func _tick() -> PackedFloat32Array:
	var a := _buf(0.012)
	for i in a.size():
		var t := float(i) / RATE
		a[i] = (1.0 if fmod(t * 2400.0, 1.0) < 0.5 else -1.0) * exp(-t * 500.0) * 0.6 + (_rng.randf() - 0.5) * exp(-t * 900.0) * 0.6
	return a

func _tones(list: Array, seconds: float, amp: float) -> PackedFloat32Array:
	var a := _buf(seconds)
	for tone: Array in list:
		var f: float = tone[0]
		var at: float = tone[1]
		for i in range(int(at * RATE), a.size()):
			var t := float(i) / RATE - at
			a[i] += (sin(TAU * f * t) + 0.3 * sin(TAU * f * 2.0 * t)) * exp(-t * 3.2) * amp
	return a

func _bell() -> PackedFloat32Array:
	var a := _buf(1.8)
	var parts := [[523.0, 1.0], [1046.0, 0.6], [1567.0, 0.35], [2637.0, 0.2]]
	for i in a.size():
		var t := float(i) / RATE
		var s := 0.0
		for p: Array in parts:
			s += sin(TAU * p[0] * t) * p[1]
		a[i] = s * exp(-t * 2.2) * 0.22
	return a

func _doors() -> PackedFloat32Array:
	var a := _buf(1.0)
	var lp := 0.0
	for i in a.size():
		var t := float(i) / RATE
		lp += ((_rng.randf() - 0.5) - lp) * 0.08
		var env := sin(clampf(t / 0.9, 0.0, 1.0) * PI)
		a[i] = lp * env * 1.6 + sin(TAU * 70.0 * t) * env * 0.08
	# The clunk at the end.
	for i in range(int(0.88 * RATE), a.size()):
		var t := float(i) / RATE - 0.88
		a[i] += sin(TAU * 90.0 * t) * exp(-t * 40.0) * 0.5
	return a

func _buzz(seconds: float) -> PackedFloat32Array:
	var a := _buf(seconds)
	for i in a.size():
		var t := float(i) / RATE
		var on := 1.0 if fmod(t * 9.0, 1.0) < 0.6 else 0.2
		a[i] = (fmod(t * 120.0, 1.0) * 2.0 - 1.0) * 0.18 * on
	return a

func _winddown(seconds: float) -> PackedFloat32Array:
	var a := _buf(seconds)
	var ph := 0.0
	for i in a.size():
		var t := float(i) / RATE
		var f := lerpf(240.0, 40.0, t / seconds)
		ph += f / RATE
		var stutter := 1.0 if fmod(t * lerpf(4.0, 14.0, t / seconds), 1.0) < 0.55 else 0.25
		a[i] = (fmod(ph, 1.0) * 2.0 - 1.0) * 0.2 * stutter * (1.0 - 0.4 * t / seconds)
	return a

func _thump() -> PackedFloat32Array:
	var a := _buf(0.5)
	for i in a.size():
		var t := float(i) / RATE
		a[i] = sin(TAU * 55.0 * t) * exp(-t * 9.0) * 0.7 + (_rng.randf() - 0.5) * exp(-t * 30.0) * 0.4
	return a

func _noise(seconds: float, amp: float) -> PackedFloat32Array:
	var a := _buf(seconds)
	for i in a.size():
		var t := float(i) / RATE
		a[i] = (_rng.randf() - 0.5) * 2.0 * amp * (1.0 - 0.6 * t / seconds)
	return a

func _printer() -> PackedFloat32Array:
	var a := _buf(1.1)
	for i in a.size():
		var t := float(i) / RATE
		a[i] = (_rng.randf() - 0.5) * 0.25 * (1.0 if fmod(t * 38.0, 1.0) < 0.5 else 0.3)
	return a

func _squeak() -> PackedFloat32Array:
	# A wheel that squeaks once a turn, over a low rattle.
	var a := _buf(1.2)
	var lp := 0.0
	for i in a.size():
		var t := float(i) / RATE
		var turn := fmod(t, 0.6) / 0.6
		var env := smoothstep(0.0, 0.08, turn) * (1.0 - smoothstep(0.25, 0.45, turn))
		var f := 1900.0 + 500.0 * sin(TAU * 3.0 * t)
		lp += ((_rng.randf() - 0.5) - lp) * 0.05
		a[i] = sin(TAU * f * t) * env * 0.35 + lp * 0.6
	return a

func _rumble(seconds: float, f: float) -> PackedFloat32Array:
	var a := _buf(seconds)
	var lp := 0.0
	for i in a.size():
		var t := float(i) / RATE
		lp += ((_rng.randf() - 0.5) - lp) * 0.02
		a[i] = sin(TAU * f * t) * 0.25 + sin(TAU * f * 1.5 * t) * 0.1 + lp * 1.5
	return a

func _hum() -> PackedFloat32Array:
	# Mains hum and its buzzy harmonics; 1 s loops cleanly (whole cycles of 50 Hz).
	var a := _buf(1.0)
	for i in a.size():
		var t := float(i) / RATE
		a[i] = sin(TAU * 100.0 * t) * 0.25 + sin(TAU * 200.0 * t) * 0.12 + sin(TAU * 300.0 * t) * 0.06 + sin(TAU * 50.0 * t) * 0.1
	return a

func _breathing() -> PackedFloat32Array:
	var a := _buf(1.6)
	var lp := 0.0
	for i in a.size():
		var t := float(i) / RATE
		lp += ((_rng.randf() - 0.5) - lp) * 0.3
		var env := pow(maxf(0.0, sin(TAU * t / 0.8)), 2.0)
		a[i] = lp * env * 0.9
	return a
