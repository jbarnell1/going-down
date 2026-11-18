# The Arboretum's sounds, every one a STAND-IN synthesised here (no files) until the owner's recordings arrive
# (docs: the Arboretum, "Sound, needed from the owner"). Each name below is one recording to replace:
#   wind       wind in leaves, a loop
#   crickets   crickets, a loop
#   sprinkler  a sprinkler ticking somewhere, a loop
#   step_gravel_1..4, step_leaves_1..4, step_moss_1..4   footsteps by surface (a creep plays them quieter)
#   twig_1..3  a twig crack
#   clink_1..6 small metal badges clinking on a cord, single clinks (one per step of the Groundskeeper)
#   swing      the badges swinging beside a face, a loop (the lean)
#   breath     slow wet breathing through something, a loop (within 4 m of it)
#   shears     shears closing (the strike)
# Not made yet (nothing plays them): an owl far off, a pinecone landing, a shed door, a slow sniff, the garden
# with the insects gone (the ring of silence fades wind, crickets and sprinkler instead).
# Client only: nothing here is a rule. The rules' noises are sim/noise.gd's; these are what the player hears.
extends RefCounted

const RATE := 22050

static var _cache := {}

## The stand-in for `name` (see the list above), made once.
static func stream(name: String) -> AudioStreamWAV:
	if _cache.has(name):
		return _cache[name]
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("garden:" + name)
	var s: AudioStreamWAV = null
	if name == "wind":
		s = _wav(_wind(rng), true)
	elif name == "crickets":
		s = _wav(_crickets(rng), true)
	elif name == "sprinkler":
		s = _wav(_sprinkler(rng), true)
	elif name.begins_with("step_gravel"):
		s = _wav(_gravel(rng), false)
	elif name.begins_with("step_leaves"):
		s = _wav(_leaves(rng), false)
	elif name.begins_with("step_moss"):
		s = _wav(_moss(rng), false)
	elif name.begins_with("twig"):
		s = _wav(_twig(rng), false)
	elif name.begins_with("clink"):
		s = _wav(_clink(rng), false)
	elif name == "swing":
		s = _wav(_swing(rng), true)
	elif name == "breath":
		s = _wav(_breath(rng), true)
	elif name == "shears":
		s = _wav(_shears(rng), false)
	_cache[name] = s
	return s

## Every stand-in's name, for the list the owner records against.
static func names() -> PackedStringArray:
	var out := PackedStringArray(["wind", "crickets", "sprinkler", "swing", "breath", "shears"])
	for k in range(1, 5):
		out.append("step_gravel_%d" % k)
		out.append("step_leaves_%d" % k)
		out.append("step_moss_%d" % k)
	for k in range(1, 4):
		out.append("twig_%d" % k)
	for k in range(1, 7):
		out.append("clink_%d" % k)
	return out

static func _wav(samples: PackedFloat32Array, loop: bool) -> AudioStreamWAV:
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

static func _buf(seconds: float) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(int(seconds * RATE))
	return a

static func _wind(rng: RandomNumberGenerator) -> PackedFloat32Array:
	# Leaves moving: soft high noise that swells and falls, whole swells to a loop.
	var secs := 8.0
	var a := _buf(secs)
	var lo := 0.0
	var hi := 0.0
	for i in a.size():
		var t := float(i) / RATE
		var n := rng.randf() - 0.5
		lo += (n - lo) * 0.02
		hi += (n - hi) * 0.35
		var swell := 0.45 + 0.3 * sin(TAU * t / secs * 2.0) + 0.2 * sin(TAU * t / secs * 5.0 + 1.3)
		var rustle := (hi - lo) * (0.5 + 0.5 * sin(TAU * t / secs * 7.0 + 0.4))
		a[i] = lo * 2.2 * swell + rustle * 0.5 * swell
	return a

static func _crickets(rng: RandomNumberGenerator) -> PackedFloat32Array:
	# Three crickets: bursts of quick pulses on a high note, each at its own pace (whole cycles to a loop).
	var secs := 6.0
	var a := _buf(secs)
	var voices: Array = [[4300.0, 15.0, 0.30], [4750.0, 18.0, 0.22], [3900.0, 12.0, 0.16]]
	for v: Array in voices:
		var f: float = v[0]
		var groups: float = v[1]
		var level: float = v[2]
		var ph := rng.randf()
		for i in a.size():
			var t := float(i) / RATE
			var g := fmod(t * groups / secs + ph, 1.0)      # one chirp group per cycle
			var on := 1.0 if g < 0.45 else 0.0
			var pulse := maxf(0.0, sin(TAU * g * 14.0))        # the wing strokes inside it
			a[i] += sin(TAU * f * t) * pulse * pulse * on * level
	return a

static func _sprinkler(_rng: RandomNumberGenerator) -> PackedFloat32Array:
	# Tick, tick, tick, then the head swings back.
	var secs := 4.0
	var a := _buf(secs)
	for i in a.size():
		var t := float(i) / RATE
		var x := 0.0
		if t < 2.8:
			var k := fmod(t, 0.2)
			x = sin(TAU * 1700.0 * k) * exp(-k * 160.0) * 0.5
		else:
			var k := (t - 2.8) / 1.2
			x = sin(TAU * 900.0 * t) * sin(PI * k) * 0.05 * (1.0 if fmod(t, 0.05) < 0.02 else 0.3)
		a[i] = x
	return a

static func _gravel(rng: RandomNumberGenerator) -> PackedFloat32Array:
	# Stones grinding under a boot: a string of sharp little clicks under a crunch.
	var a := _buf(0.24)
	var hp := 0.0
	var prev := 0.0
	for i in a.size():
		var t := float(i) / RATE
		var n := rng.randf() - 0.5
		hp = 0.6 * (hp + n - prev)
		prev = n
		var grain := 1.0 if rng.randf() < 0.08 else 0.25
		var env := minf(1.0, t * 90.0) * exp(-t * 16.0)
		a[i] = hp * grain * env * 2.4
	return a

static func _leaves(rng: RandomNumberGenerator) -> PackedFloat32Array:
	# Dry leaves: a papery rustle that swishes rather than clicks.
	var a := _buf(0.3)
	var bp := 0.0
	var lp := 0.0
	for i in a.size():
		var t := float(i) / RATE
		var n := rng.randf() - 0.5
		lp += (n - lp) * 0.5
		bp += (lp - bp) * 0.12
		var env := sin(PI * minf(1.0, t / 0.3)) * exp(-t * 7.0)
		var flutter := 0.6 + 0.4 * sin(TAU * 31.0 * t + rng.randf() * 0.4)
		a[i] = (lp - bp) * env * flutter * 2.6
	return a

static func _moss(rng: RandomNumberGenerator) -> PackedFloat32Array:
	# Almost nothing: a soft press.
	var a := _buf(0.14)
	var lp := 0.0
	for i in a.size():
		var t := float(i) / RATE
		lp += ((rng.randf() - 0.5) - lp) * 0.04
		a[i] = (sin(TAU * 62.0 * t) * 0.25 + lp * 1.6) * exp(-t * 38.0)
	return a

static func _twig(rng: RandomNumberGenerator) -> PackedFloat32Array:
	# A dry stick snapping: a hard click, a short woody ring, splinters.
	var a := _buf(0.32)
	var f := 1300.0 + rng.randf() * 700.0
	for i in a.size():
		var t := float(i) / RATE
		var click := (rng.randf() - 0.5) * exp(-t * 900.0) * 3.0
		var ring := sin(TAU * f * t) * exp(-t * 70.0) * 0.7 + sin(TAU * f * 2.7 * t) * exp(-t * 120.0) * 0.4
		var tail := (rng.randf() - 0.5) * exp(-t * 22.0) * 0.25 * (1.0 if rng.randf() < 0.05 else 0.1)
		a[i] = click + ring + tail
	return a

static func _clink(rng: RandomNumberGenerator) -> PackedFloat32Array:
	# Two thin metal badges touching: bright partials that do not line up, gone quickly.
	var a := _buf(0.22)
	var base := 2300.0 + rng.randf() * 1500.0
	var second := 0.02 + rng.randf() * 0.03
	for i in a.size():
		var t := float(i) / RATE
		var x := 0.0
		for hit: float in [0.0, second]:
			var u := t - hit
			if u < 0.0:
				continue
			x += (sin(TAU * base * u) * 0.5 + sin(TAU * base * 1.71 * u) * 0.32 + sin(TAU * base * 2.93 * u) * 0.2) * exp(-u * 48.0)
		a[i] = x * 0.6
	return a

static func _swing(rng: RandomNumberGenerator) -> PackedFloat32Array:
	# Badges swinging on their cord: soft clinks, to and fro.
	var secs := 2.4
	var a := _buf(secs)
	for k in 6:
		var at := (k + 0.5 * rng.randf()) * secs / 6.0
		var base := 2400.0 + rng.randf() * 1800.0
		var level := 0.18 + 0.2 * rng.randf()
		for i in range(int(at * RATE), mini(a.size(), int((at + 0.2) * RATE))):
			var u := float(i) / RATE - at
			a[i] += (sin(TAU * base * u) * 0.5 + sin(TAU * base * 1.83 * u) * 0.3) * exp(-u * 40.0) * level
	return a

static func _breath(rng: RandomNumberGenerator) -> PackedFloat32Array:
	# Slow, wet, patient: a long draw in, a longer one out through something that bubbles.
	var secs := 4.6
	var a := _buf(secs)
	var lp := 0.0
	var lp2 := 0.0
	var bubble := 0.0
	for i in a.size():
		var t := float(i) / RATE
		var n := rng.randf() - 0.5
		lp += (n - lp) * 0.16
		lp2 += (n - lp2) * 0.03
		var env := 0.0
		if t < 1.6:
			env = sin(PI * t / 1.6) * 0.7
		elif t > 2.0 and t < 4.3:
			env = sin(PI * (t - 2.0) / 2.3)
		if rng.randf() < 0.0012:
			bubble = 1.0
		bubble *= 0.994
		var out_ := t > 2.0
		a[i] = ((lp - lp2) * (1.2 if out_ else 2.0) + lp2 * (2.2 if out_ else 0.6)) * env * 1.5 + sin(TAU * 140.0 * t) * bubble * env * (0.25 if out_ else 0.0)
	return a

static func _shears(rng: RandomNumberGenerator) -> PackedFloat32Array:
	# Long blades sliding shut and meeting.
	var a := _buf(0.5)
	for i in a.size():
		var t := float(i) / RATE
		var slide := (rng.randf() - 0.5) * (1.0 - smoothstep(0.0, 0.16, t)) * 0.5 * (0.4 + 0.6 * sin(TAU * 2600.0 * t))
		var u := t - 0.16
		var snap := 0.0
		if u >= 0.0:
			snap = (sin(TAU * 1900.0 * u) * 0.6 + sin(TAU * 3170.0 * u) * 0.4 + sin(TAU * 5230.0 * u) * 0.25) * exp(-u * 26.0)
		a[i] = slide + snap * 0.9
	return a
