# VC1, the microphone (North Star B5 "Your real voice counts. The game reads how loud your microphone is. Hearing
# entities react to it"; B1 hearing "comes to footsteps, noise and your real voice"). sim/noise.gd voice_radius,
# sim/run.gd "VC1". Proved here:
#   1. The three bands: levels 1 to 4 carry noise.voice_whisper (2 m), 5 to 10 noise.voice_talk (8 m), 11 to 15
#      noise.voice_shout (16 m); 0 is silent; each band follows its live setting.
#   2. In a run on the Arboretum, a talking player 6 m from the Groundskeeper is heard and a whispering one is not;
#      a shout carries 12 m and talking does not.
#   3. It comes to where the voice WAS: the player speaks once and is somewhere else the next tick; its target is
#      the place they spoke from (Residents always obey their rule; delay never makes one look as if it cheated).
#   4. A voice is its own noise (kind "voice"): standing still and silent, nothing; Soft Shoes does not quieten it.
#   5. Nobody in the car or down makes one.
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Places = preload("res://sim/places.gd")
const Settings = preload("res://sim/settings.gd")
const Noises = preload("res://sim/noise.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const M = preload("res://sim/jsmath.gd")
const HostRules = preload("res://net/host_rules.gd")

const DT := 0.05

static func input(id: String, body: Move.Body, level: int = 0) -> Run.PlayerInput:
	var i := Run.PlayerInput.make(id, body, 1.65, 0.0, 0.0, 90.0, 70.0)
	i.voice_level = level
	return i

static func one(i: Run.PlayerInput) -> Array[Run.PlayerInput]:
	var out: Array[Run.PlayerInput] = [i]
	return out

## The game's floor 5 (the Arboretum) for one player, the voice on or off, the doors open and the car gone.
static func garden(on: bool, seed := "vc1-garden") -> Run.RunState:
	var ids: Array[String] = ["a"]
	var rules := HostRules.new(true, 5, Places.FULL)
	rules.voice = on
	var s := rules.prepare(Run.create_run(seed, ids, Places.FULL))
	# The garden's state is made on the first tick.
	return Run.step_run(s, one(input("a", s.players[0].body)), DT).state

## A walkable cell's middle on the keeper's level at about `d` metres (flat) from it, out of the car, or null.
static func spot_at(s: Run.RunState, d: float) -> Move.Body:
	var k: Move.Body = s.garden.keeper.body
	var plan := s.plan
	var best: Move.Body = null
	var err := 0.6
	for cy in plan.height:
		for cx in plan.width:
			if not Floor.is_walkable(plan, k.level, cx, cy):
				continue
			var b := Move.body_at_cell(plan, Floor.Pos.make(k.level, cx, cy))
			if b.level != k.level or Run.in_car(s.car, b):
				continue
			var e := absf(M.hypot2(b.x - k.x, b.z - k.z) - d)
			if e < err:
				err = e
				best = b
	return best

## One tick: the player at `at` speaking at `level`. Returns the new state.
static func tick(s: Run.RunState, at: Move.Body, level: int) -> Run.RunState:
	s.players[0].body = at
	return Run.step_run(s, one(input("a", at, level)), DT).state

## Stands the player at `at` silent for a moment (the first tick there is a move), then speaks once at `level` and
## goes quiet. Returns [state after the voice's tick, the keeper's target or null].
static func speak_once(s0: Run.RunState, at: Move.Body, level: int) -> Array:
	var s := s0
	for _k in 3:
		s = tick(s, at, 0)
	s = tick(s, at, level)
	var tg: Noises.Sound = s.garden.keeper.target
	return [s, tg]

static func heard_voice(s0: Run.RunState, at: Move.Body, level: int) -> bool:
	var r := speak_once(s0, at, level)
	var tg: Noises.Sound = r[1]
	return tg != null and tg.kind == &"voice"

# ---------------------------------------------------------------------------------------------
# 1. The bands.

func test_the_bands(t: T) -> void:
	t.eq(Noises.voice_radius(0), 0.0, "level 0: silent")
	for lv in range(1, 5):
		t.eq(Noises.voice_radius(lv), 2.0, "level %d: a whisper, 2 m" % lv)
	for lv in range(5, 11):
		t.eq(Noises.voice_radius(lv), 8.0, "level %d: talking, 8 m" % lv)
	for lv in range(11, 16):
		t.eq(Noises.voice_radius(lv), 16.0, "level %d: a shout, 16 m" % lv)
	t.eq(Noises.voice_radius(-3), 0.0, "below 0: silent")
	var tun := Settings.make({&"noise.voice_whisper": 1.0, &"noise.voice_talk": 5.0, &"noise.voice_shout": 20.0})
	t.eq(Noises.voice_radius(2, tun), 1.0, "the whisper follows its row")
	t.eq(Noises.voice_radius(7, tun), 5.0, "talking follows its row")
	t.eq(Noises.voice_radius(13, tun), 20.0, "the shout follows its row")
	var s := Noises.voice_sound("a", Move.Body.make(3.0, 4.0, 0, 0.0), 8, 1.0)
	t.check(s != null and s.kind == &"voice" and s.x == 3.0 and s.z == 4.0 and s.r == 8.0 and s.by == "a", "a voice is a noise of its own kind at the speaker")
	t.check(Noises.voice_sound("a", Move.Body.make(3.0, 4.0, 0, 0.0), 8, 0.0) == null, "a deaf hearer (share 0): no noise")
	t.check(Noises.voice_sound("a", Move.Body.make(3.0, 4.0, 0, 0.0), 0, 1.0) == null, "silence: no noise")

# ---------------------------------------------------------------------------------------------
# 2 and 3. The Groundskeeper.

func test_the_groundskeeper_hears_talking_not_a_whisper(t: T) -> void:
	var s := garden(true)
	if not t.check(s.garden != null and s.plan.place == Places.ARBORETUM, "floor 5 of the game's deck is the Arboretum"):
		return
	var at6 := spot_at(s, 6.0)
	var at12 := spot_at(s, 12.0)
	if not t.check(at6 != null and at12 != null, "spots 6 m and 12 m from the Groundskeeper"):
		return
	t.check(not heard_voice(s, at6, 0), "6 m, silent: nothing heard")
	t.check(not heard_voice(s, at6, 3), "6 m, a whisper (2 m): not heard")
	t.check(heard_voice(s, at6, 7), "6 m, talking (8 m): heard")
	t.check(not heard_voice(s, at12, 8), "12 m, talking (8 m): not heard")
	t.check(heard_voice(s, at12, 14), "12 m, a shout (16 m): heard")
	t.check(not heard_voice(garden(false), at6, 15), "the voice off: a shout 6 m away is not heard")
	# Its live setting: 0 is deaf, 200 doubles the reach.
	var deaf := Run.with_tuning(garden(true), {&"groundskeeper.voice": 0.0})
	t.check(not heard_voice(deaf, at6, 15), "groundskeeper.voice 0: deaf to a shout")
	var keen := Run.with_tuning(garden(true), {&"groundskeeper.voice": 200.0})
	t.check(heard_voice(keen, at12, 8), "groundskeeper.voice 200: talking carries 16 m")

func test_it_comes_to_where_the_voice_was(t: T) -> void:
	var s := garden(true)
	var at := spot_at(s, 6.0)
	var far := spot_at(s, 30.0)
	if not t.check(at != null and far != null, "spots 6 m and 30 m from the Groundskeeper"):
		return
	var r := speak_once(s, at, 9)
	s = r[0]
	var tg: Noises.Sound = r[1]
	t.check(tg != null and tg.kind == &"voice" and tg.by == "a", "the voice is its target")
	# The player is somewhere else at once, silent; it goes on to the place they spoke from.
	var went := false
	for _k in int(6.0 / DT):
		s = tick(s, far, 0)
		var k := s.garden.keeper
		if k.target != null and (absf(k.target.x - at.x) > 1e-6 or absf(k.target.z - at.z) > 1e-6):
			went = true
	var k2 := s.garden.keeper
	t.check(not went, "its target never moved off the place the voice was")
	t.check(M.hypot2(k2.body.x - at.x, k2.body.z - at.z) < M.hypot2(k2.body.x - far.x, k2.body.z - far.z), "it went toward where they spoke (%.1f m from it), not where they are" % M.hypot2(k2.body.x - at.x, k2.body.z - at.z))

func test_nobody_in_the_car_or_down_speaks(t: T) -> void:
	var s := garden(true)
	var p := s.players[0]
	var inp := input("a", p.body, 15)
	t.eq(Run.voice_level_of(s, p, inp), 0 if Run.in_car(s.car, p.body) else 15, "in the car at the start: silent")
	var at := spot_at(s, 6.0)
	p.body = at
	p.aboard = false
	t.eq(Run.voice_level_of(s, p, inp), 15, "on the floor: the level")
	inp.voice_level = 99
	t.eq(Run.voice_level_of(s, p, inp), 15, "a level over 15 is 15")
	inp.voice_level = 15
	p.status = &"down"
	t.eq(Run.voice_level_of(s, p, inp), 0, "down: silent")
	p.status = &"out"
	t.eq(Run.voice_level_of(s, p, inp), 0, "out: silent")
	p.status = &"ok"
	p.aboard = true
	t.eq(Run.voice_level_of(s, p, inp), 0, "aboard: silent")
	p.aboard = false
	t.eq(Run.voice_level_of(s, p, null), 0, "no input this tick: silent")
	t.eq(Run.voice_level_of(garden(false), p, inp), 0, "the voice off: silent")
