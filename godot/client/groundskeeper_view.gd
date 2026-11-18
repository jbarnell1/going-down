# The Groundskeeper as drawn: a STAND-IN figure built here from simple meshes until the Blender figure is made
# (docs: the Arboretum, piece AR4). A tall, stooped shape in the rags of a survey coverall, moss up one side,
# roots through a sleeve, bark where the face should be and no eyes, a cord of other people's badges hanging
# from its neck, long shears carried like a walking stick. Enough to read its states (sim/hearing.gd) at game
# resolution through the tape filter: the slow turning head while it listens, the tilt, the coming, the lean
# down to a face, the sweep, the strike.
#
# Nothing here is a rule. It shows the pose the host sent (client/play_link.gd: x, y, z, yaw, anim, animTime;
# anim is idle, tilt, walk, lean, sweep or catch) and makes its own sounds, all stand-ins from
# client/garden_sound.gd: a badge clink for every step it takes (standing, they hang silent), the badges
# swinging while it leans, slow wet breath within about 4 m, the shears closing when it strikes.
# It is drawn in the dark as it is: no glow, no outline, no light of its own (the owner's rule for every
# resident). What lights it is the world's light: a lamp, or the near light on the player's own screen.
extends Node3D

const GardenSound = preload("res://client/garden_sound.gd")

## Metres to a step (a clink each), and how tall it stands upright.
const STEP := 1.3
const HIP := 1.22
const CLOTH := Color(0.34, 0.37, 0.31)
const CLOTH_DARK := Color(0.2, 0.22, 0.2)
const BARK := Color(0.5, 0.38, 0.26)
const BARK_DARK := Color(0.2, 0.14, 0.1)
const MOSS := Color(0.2, 0.4, 0.13)
const METAL := Color(0.62, 0.6, 0.52)
const STEEL := Color(0.3, 0.31, 0.32)

var drawn := {}
var _last := Vector3.INF
var _dist := 0.0
var _step_k := 0
var _last_us := 0
var _anim := ""
var _swing := 0.0        # how hard the badges swing, 0..1
var _swing_t := 0.0
var _struck := false

var _body: Node3D
var _hips: Node3D
var _spine: Node3D
var _neck: Node3D
var _head: Node3D
var _leg_l: Node3D
var _leg_r: Node3D
var _shin_l: Node3D
var _shin_r: Node3D
var _arm_l: Node3D
var _arm_r: Node3D
var _shears: Node3D
var _blade_a: Node3D
var _blade_b: Node3D
var _cord: Node3D
var _badges: Array[Node3D] = []
var _clinks: Array[AudioStreamPlayer3D] = []
var _clink_next := 0
var _breath: AudioStreamPlayer3D
var _swing_snd: AudioStreamPlayer3D
var _snip: AudioStreamPlayer3D
var _rng := RandomNumberGenerator.new()
var _mats := {}

func _ready() -> void:
	_rng.seed = 91
	_build()
	visible = false

func _mat(col: Color, rough := 0.95, metal := 0.0) -> StandardMaterial3D:
	var key := [col, rough, metal]
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = col
		m.roughness = rough
		m.metallic = metal
		m.metallic_specular = 0.25 if metal == 0.0 else 0.6
		_mats[key] = m
	return _mats[key]

func _box(parent: Node3D, size: Vector3, at: Vector3, col: Color, rough := 0.95, metal := 0.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = at
	mi.material_override = _mat(col, rough, metal)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi

func _pivot(parent: Node3D, at: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = at
	parent.add_child(n)
	return n

func _build() -> void:
	_body = _pivot(self, Vector3.ZERO)
	_hips = _pivot(_body, Vector3(0, HIP, 0))
	# Legs: long and thin, a knee each.
	for side: int in [-1, 1]:
		var leg := _pivot(_hips, Vector3(0.13 * side, 0, 0))
		_box(leg, Vector3(0.14, 0.64, 0.15), Vector3(0, -0.32, 0), CLOTH)
		var shin := _pivot(leg, Vector3(0, -0.62, 0))
		_box(shin, Vector3(0.11, 0.6, 0.12), Vector3(0, -0.3, 0), CLOTH_DARK)
		_box(shin, Vector3(0.13, 0.07, 0.3), Vector3(0, -0.585, 0.07), BARK_DARK)
		# Rags at the knee.
		_box(shin, Vector3(0.17, 0.12, 0.05), Vector3(0.01 * side, -0.05, -0.08), CLOTH)
		if side < 0:
			_leg_r = leg
			_shin_r = shin
		else:
			_leg_l = leg
			_shin_l = shin
	# The trunk: a long coverall, hunched, moss up its left side.
	_spine = _pivot(_hips, Vector3.ZERO)
	_box(_spine, Vector3(0.44, 0.5, 0.27), Vector3(0, 0.25, 0), CLOTH)
	_box(_spine, Vector3(0.5, 0.5, 0.3), Vector3(0, 0.72, 0.02), CLOTH)
	_box(_spine, Vector3(0.56, 0.16, 0.34), Vector3(0, 1.0, 0.05), CLOTH_DARK)      # the hunched shoulders
	_box(_spine, Vector3(0.2, 0.5, 0.31), Vector3(0.19, 0.62, 0.0), MOSS)             # moss up one side
	_box(_spine, Vector3(0.14, 0.2, 0.32), Vector3(0.24, 0.95, 0.04), MOSS)
	_box(_spine, Vector3(0.1, 0.07, 0.005), Vector3(-0.12, 0.82, 0.172), Color(0.5, 0.48, 0.4))  # the patch: 9-1
	# Rags hanging from the hem.
	for k in 5:
		_box(_spine, Vector3(0.07, 0.16 + 0.05 * (k % 3), 0.02), Vector3(-0.2 + k * 0.1, -0.07, 0.13 - 0.06 * (k % 2)), CLOTH_DARK)
	# Arms: too long. The left hangs, roots where its hand should be; the right holds the shears.
	_arm_l = _pivot(_spine, Vector3(0.31, 0.98, 0.03))
	_box(_arm_l, Vector3(0.11, 0.62, 0.12), Vector3(0, -0.31, 0), CLOTH)
	_box(_arm_l, Vector3(0.09, 0.56, 0.1), Vector3(0, -0.88, 0.02), MOSS)
	for k in 4:
		var root := _box(_arm_l, Vector3(0.025, 0.34 + 0.07 * k, 0.025), Vector3(-0.03 + 0.02 * k, -1.26 - 0.03 * k, 0.02 * (k - 1.5)), BARK)
		root.rotation = Vector3(0.12 * (k - 1.5), 0, 0.16 * (k - 1.5))
	_arm_r = _pivot(_spine, Vector3(-0.31, 0.98, 0.03))
	_box(_arm_r, Vector3(0.11, 0.62, 0.12), Vector3(0, -0.31, 0), CLOTH)
	_box(_arm_r, Vector3(0.09, 0.58, 0.1), Vector3(0, -0.89, 0.02), CLOTH_DARK)
	_box(_arm_r, Vector3(0.1, 0.12, 0.1), Vector3(0, -1.22, 0.02), BARK)
	# The head: bark, split, no eyes.
	_neck = _pivot(_spine, Vector3(0, 1.06, 0.08))
	_box(_neck, Vector3(0.13, 0.26, 0.13), Vector3(0, 0.1, 0), BARK_DARK)
	_head = _pivot(_neck, Vector3(0, 0.22, 0.02))
	_box(_head, Vector3(0.25, 0.36, 0.26), Vector3(0, 0.15, 0.03), BARK)
	for k in 6:
		# Ridges of bark down the front, uneven: where a face should be.
		var w := 0.022 + 0.012 * (k % 2)
		_box(_head, Vector3(w, 0.3 - 0.04 * (k % 3), 0.03), Vector3(-0.1 + k * 0.04, 0.15 + 0.02 * (k % 2), 0.165), BARK_DARK if k % 2 == 0 else Color(0.62, 0.48, 0.33))
	_box(_head, Vector3(0.05, 0.2, 0.012), Vector3(0.01, 0.12, 0.185), Color(0.02, 0.015, 0.01))   # the split
	for k in 3:
		_box(_head, Vector3(0.05, 0.1 + 0.05 * k, 0.05), Vector3(-0.08 + 0.08 * k, 0.37, -0.02), BARK_DARK)
	# The cord of badges: hung from the neck, kept plumb by _process.
	_cord = _pivot(self, Vector3.ZERO)
	for k in 7:
		var badge := _pivot(_cord, Vector3(-0.09 + 0.03 * k, -0.16 - 0.035 * (k % 3), 0.0))
		_box(badge, Vector3(0.006, 0.16 + 0.035 * (k % 3), 0.006), Vector3(0, 0.08, 0), Color(0.03, 0.03, 0.03))
		_box(badge, Vector3(0.05, 0.075, 0.006), Vector3(0, -0.04, 0), METAL if k != 3 else Color(0.7, 0.62, 0.3), 0.3, 0.9)
		_badges.append(badge)
	# The shears: two long handles and two long blades, closed.
	_shears = _pivot(self, Vector3(-0.46, 0.0, 0.3))
	_box(_shears, Vector3(0.035, 1.05, 0.035), Vector3(-0.025, 1.02, 0), Color(0.12, 0.09, 0.06))
	_box(_shears, Vector3(0.035, 1.05, 0.035), Vector3(0.025, 1.02, 0), Color(0.12, 0.09, 0.06))
	_blade_a = _pivot(_shears, Vector3(0, 0.5, 0))
	_box(_blade_a, Vector3(0.05, 0.5, 0.012), Vector3(-0.012, -0.25, 0.006), STEEL, 0.35, 0.9)
	_blade_b = _pivot(_shears, Vector3(0, 0.5, 0))
	_box(_blade_b, Vector3(0.05, 0.5, 0.012), Vector3(0.012, -0.25, -0.006), STEEL, 0.35, 0.9)
	# Its sounds.
	for k in 4:
		var c := AudioStreamPlayer3D.new()
		c.bus = &"Entity"
		c.unit_size = 5.0
		c.max_distance = 34.0
		c.volume_db = -3.0
		add_child(c)
		c.position = Vector3(0, 1.9, 0.1)
		_clinks.append(c)
	_breath = _loop("breath", 1.6, 5.5, -9.0)
	_swing_snd = _loop("swing", 3.0, 12.0, -60.0)
	_snip = AudioStreamPlayer3D.new()
	_snip.bus = &"Entity"
	_snip.stream = GardenSound.stream("shears")
	_snip.unit_size = 8.0
	_snip.max_distance = 40.0
	add_child(_snip)

func _loop(name: String, unit: float, far: float, db: float) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.bus = &"Entity"
	p.stream = GardenSound.stream(name)
	p.unit_size = unit
	p.max_distance = far
	p.volume_db = db
	p.position = Vector3(0, 1.8, 0.2)
	add_child(p)
	return p

func reset() -> void:
	_last = Vector3.INF
	_dist = 0.0
	_step_k = 0
	_anim = ""
	_swing = 0.0
	_struck = false
	visible = false
	_quiet()

func _quiet() -> void:
	if _breath != null and _breath.playing:
		_breath.stop()
	if _swing_snd != null and _swing_snd.playing:
		_swing_snd.stop()

## (Every resident's view has it; looking does nothing to this one.)
func set_watched(_at: Variant) -> void:
	pass

## The floor it stands on: the Arboretum's view hushes the garden round it (the ring of silence).
func set_floor(level: Node) -> void:
	if level != null and level.has_meta(&"arboretum"):
		level.get_meta(&"arboretum").set(&"keeper", self)

## What a test reads of how it is drawn.
func look() -> Dictionary:
	return {"sig": "groundskeeper-stand-in", "anim": _anim, "glow": false, "unshaded": false, "passes": 0, "overlays": 0, "lights": 0,
		"stoop": snappedf(_spine.rotation.x, 0.01) if _spine != null else 0.0, "headRoll": snappedf(_head.rotation.z, 0.01) if _head != null else 0.0}

func show_pose(pose: Variant, show: bool) -> void:
	if pose == null:
		visible = false
		_quiet()
		return
	var pd: Dictionary = pose
	var p := Vector3(float(pd["x"]), float(pd["y"]), float(pd["z"]))
	var anim := str(pd["anim"])
	var t := float(pd["animTime"])
	var now := Time.get_ticks_usec()
	var dt := 0.016
	if _last_us > 0:
		dt = clampf((now - _last_us) / 1e6, 0.001, 0.1)
	_last_us = now
	var step := 0.0
	if _last != Vector3.INF:
		var d := Vector2(p.x - _last.x, p.z - _last.z).length()
		if d < 1.5:
			step = d
	_last = p
	_dist += step
	drawn = pd
	position = p
	rotation = Vector3(0, float(pd["yaw"]) + PI, 0)
	visible = show
	# A clink for every step it takes; standing, the badges hang silent.
	var k := floori(_dist / STEP)
	if k != _step_k:
		_step_k = k
		_clink()
		_swing = 1.0
	if anim != _anim:
		_anim = anim
		_struck = false
	_pose(anim, t, dt, step / maxf(dt, 0.001))
	_sounds(anim, dt)

func _clink() -> void:
	var c := _clinks[_clink_next]
	_clink_next = (_clink_next + 1) % _clinks.size()
	c.stream = GardenSound.stream("clink_%d" % _rng.randi_range(1, 6))
	c.pitch_scale = 0.9 + _rng.randf() * 0.25
	c.play()

func _sounds(anim: String, dt: float) -> void:
	if not _breath.playing:
		_breath.play()
	var want := -10.0 if anim == "lean" else -60.0
	_swing_snd.volume_db = move_toward(_swing_snd.volume_db, want, 90.0 * dt)
	if _swing_snd.volume_db > -55.0 and not _swing_snd.playing:
		_swing_snd.play()
	elif _swing_snd.volume_db <= -55.0 and _swing_snd.playing:
		_swing_snd.stop()
	if anim == "catch" and not _struck:
		_struck = true
		_snip.play()

static func _ease(x: float) -> float:
	var k := clampf(x, 0.0, 1.0)
	return k * k * (3.0 - 2.0 * k)

## Sets every joint for the pose. `t` is the host's time in the pose, `speed` its ground speed now.
func _pose(anim: String, t: float, dt: float, speed: float) -> void:
	var a := 1.0 - exp(-dt * 12.0)
	var stoop := 0.42
	var head_yaw := 0.0
	var head_roll := 0.0
	var head_pitch := -0.15
	var neck_len := 1.0
	var neck_pitch := 0.1
	var crouch := 0.0
	var leg_l := 0.0
	var leg_r := 0.0
	var knee_l := 0.0
	var knee_r := 0.0
	var arm_l := Vector3(0.06, 0, 0.05)
	var arm_r := Vector3(0.25, 0, -0.08)
	var bob := 0.0
	var shears_at := Vector3(-0.46, 0.0, 0.3)
	var shears_rot := Vector3(0.06, 0, 0.03)
	var open := 0.0
	var swing_want := 0.0
	var lunge := 0.0
	match anim:
		"tilt":
			# It stops. The head goes over to one side, quickly, and stays there.
			var k := _ease(t / 0.18)
			stoop = lerpf(0.42, 0.3, k)
			head_roll = 0.62 * k
			head_pitch = -0.05
			neck_len = 1.0 + 0.15 * k
		"walk":
			# Coming: long, quick strides, the body thrown forward, the head level and still.
			var ph := _dist / STEP * PI
			leg_l = sin(ph) * 0.72
			leg_r = -sin(ph) * 0.72
			knee_l = maxf(0.0, -cos(ph)) * 0.9
			knee_r = maxf(0.0, cos(ph)) * 0.9
			bob = absf(sin(ph)) * 0.07
			stoop = 0.8
			head_pitch = -0.72
			neck_pitch = -0.05
			arm_l = Vector3(-0.5 - 0.2 * sin(ph), 0, 0.12)
			arm_r = Vector3(-0.35 + 0.15 * sin(ph), 0, -0.1)
			shears_at = Vector3(-0.44, 0.75, 0.1)
			shears_rot = Vector3(1.25, 0, 0.0)
			swing_want = 1.0
		"lean":
			# Down to a face: the body folds, the neck comes out, the head turns a little as if reading it.
			var k := _ease(t / 0.55)
			var creep := clampf(t / 2.5, 0.0, 1.2)
			stoop = lerpf(0.42, 1.25, k)
			crouch = 0.3 * k
			lunge = 0.22 * k
			knee_l = 0.5 * k
			knee_r = 0.35 * k
			leg_l = -0.3 * k
			leg_r = -0.22 * k
			neck_pitch = lerpf(0.1, -0.35, k)
			neck_len = 1.0 + 0.9 * k * creep
			head_pitch = lerpf(-0.15, -0.78, k)
			head_roll = 0.22 * sin(t * 1.1) * k
			head_yaw = 0.1 * sin(t * 0.7) * k
			arm_l = Vector3(lerpf(0.06, -0.9, k), 0, 0.3 * k)
			arm_r = Vector3(lerpf(0.25, -0.6, k), 0, -0.2 * k)
			shears_at = Vector3(-0.5, 0.0, 0.05)
			swing_want = 0.45
		"sweep":
			# Nobody there: the shears go through the place, low, side to side.
			stoop = 0.85
			crouch = 0.15
			head_pitch = -0.5
			head_yaw = 0.5 * sin(t * 4.2 + 0.6)
			arm_r = Vector3(-0.9, 0, -0.3)
			shears_at = Vector3(-0.2, 0.45, 0.5)
			shears_rot = Vector3(1.5, 1.15 * sin(t * 4.2), 0)
			open = 0.25 + 0.15 * sin(t * 8.4)
			swing_want = 0.7
		"catch":
			# The strike: open, close once.
			var k := clampf(t / 0.14, 0.0, 1.0)
			var shut := _ease((t - 0.14) / 0.06)
			stoop = lerpf(1.0, 0.7, _ease(t / 0.5))
			head_pitch = -0.6
			arm_r = Vector3(-1.3, 0, -0.2)
			arm_l = Vector3(-1.0, 0, 0.3)
			shears_at = Vector3(-0.12, 0.95, 0.55 + 0.35 * k)
			shears_rot = Vector3(1.45, 0, 0)
			open = 0.55 * k * (1.0 - shut)
			swing_want = 1.0
		_:
			# Listening: it stands, the head slowly turning.
			head_yaw = 0.95 * sin(t * 0.55)
			head_roll = 0.06 * sin(t * 0.31)
			stoop = 0.42 + 0.02 * sin(t * 0.8)
	var snap := anim == "lean" or anim == "catch" or anim == "tilt"
	var b := 1.0 if snap else a
	_hips.position.y = lerpf(_hips.position.y, HIP - crouch + bob, b)
	_body.position.z = lerpf(_body.position.z, lunge, b)
	_spine.rotation.x = lerpf(_spine.rotation.x, stoop, b)
	_neck.rotation.x = lerpf(_neck.rotation.x, neck_pitch, b)
	_neck.scale.y = lerpf(_neck.scale.y, neck_len, b)
	_head.rotation = Vector3(lerpf(_head.rotation.x, head_pitch + stoop * -0.0, b), lerpf(_head.rotation.y, head_yaw, b), lerpf(_head.rotation.z, head_roll, b))
	_head.scale.y = 1.0 / maxf(0.2, _neck.scale.y)
	_leg_l.rotation.x = lerpf(_leg_l.rotation.x, -leg_l, b)
	_leg_r.rotation.x = lerpf(_leg_r.rotation.x, -leg_r, b)
	_shin_l.rotation.x = lerpf(_shin_l.rotation.x, knee_l, b)
	_shin_r.rotation.x = lerpf(_shin_r.rotation.x, knee_r, b)
	_arm_l.rotation = _arm_l.rotation.lerp(arm_l, b)
	_arm_r.rotation = _arm_r.rotation.lerp(arm_r, b)
	_shears.position = _shears.position.lerp(shears_at, a if anim != "catch" else 1.0)
	_shears.rotation = _shears.rotation.lerp(shears_rot, a if anim != "catch" else 1.0)
	_blade_a.rotation.z = open
	_blade_b.rotation.z = -open
	# The badges hang plumb from the neck, wherever the neck has gone, and swing with what it does.
	_swing = move_toward(_swing, swing_want, dt * (3.0 if swing_want > _swing else 0.9))
	_swing_t += dt * (7.0 if speed > 1.0 else 3.2)
	_cord.global_position = _neck.global_position + Vector3(0, -0.02, 0)
	_cord.global_rotation = Vector3(0, global_rotation.y, 0)
	_cord.position.z += 0.1
	for i in _badges.size():
		var ph := _swing_t + i * 0.9
		_badges[i].rotation = Vector3(sin(ph) * 0.5 * _swing, 0, cos(ph * 1.3) * 0.35 * _swing)
