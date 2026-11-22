# VC4: one meter for all the noise a player makes (client/own_noise.gd, client/noise_meter.gd, client/mic_hud.gd).
# The instrument never lies, so every number is the rules' own. Proved here:
#   1. Steps: for creep, walk and sprint on every ground (and with Soft Shoes, and with a live setting changed) the
#      meter's level is exactly the rules' noise (sim/noise.gd of(), the function the host runs) in the meter's units
#      (metres x 15 / 16); standing still is 0; sprint > walk > creep.
#   2. Opening: slow F and fast Shift+F are the rules' search noises; fast reads higher than slow; the rules' events
#      (fast at its start, slow at its end, never a silent one, never another player's) feed it, for PULSE_MS.
#   3. The Playroom: "Walking is not a noise": a walk or a creep is 0 there, a sprint is not.
#   4. The host's row moving makes steps, standing does not; the meter shows the loudest source, works with no
#      microphone and with the voice off; quiet by default: hidden until a noise, shown 4 s after, then gone;
#      force_show always shows it.
extends RefCounted

const T = preload("res://tests/t.gd")
const Noises = preload("res://sim/noise.gd")
const Move = preload("res://sim/move.gd")
const Places = preload("res://sim/places.gd")
const Settings = preload("res://sim/settings.gd")
const OwnNoise = preload("res://client/own_noise.gd")
const NoiseMeter = preload("res://client/noise_meter.gd")
const MicHud = preload("res://client/mic_hud.gd")

const DT := 0.05

## The rules' noise radius for one tick of `gait` on `surface` (a one-cell ground), moving 0.1 m (2 m/s).
static func _rules_r(gait: StringName, surface: int, soft := false, tuning: Settings.Values = null) -> float:
	var ground: Noises.Ground = null
	if surface != Noises.NONE:
		ground = Noises.Ground.make(4, 4, 2.0)
		for cx in 4:
			for cy in 4:
				ground.put(cx, cy, surface)
	var a := Noises.Act.make("p", Move.Body.make(3.1, 3.0, 0, 0.0), Move.Body.make(3.0, 3.0, 0, 0.0), gait)
	a.soft_shoes = soft
	var n := Noises.of(ground, a, DT, {}, tuning)
	return n.r if n != null else 0.0

func test_steps_are_the_rules_noise(t: T) -> void:
	var tuned := Settings.make({&"noise.sprint": 9.0, &"noise.walk_gravel": 5.0})
	for surface: int in [Noises.NONE, Noises.MOSS, Noises.LITTER, Noises.GRAVEL]:
		for gait: String in ["creep", "walk", "sprint"]:
			for soft: bool in [false, true]:
				for tn: Variant in [null, tuned]:
					var want := OwnNoise.metres_to_level(_rules_r(StringName(gait), surface, soft, tn))
					var got := OwnNoise.step_level(gait, surface, true, Places.CLINIC, soft, tn)
					t.eq(got, want, "%s on %s%s%s: the meter is the rules' noise" % [gait, Noises.SURFACE_NAMES[surface], " in Soft Shoes" if soft else "", " (tuned)" if tn != null else ""])
	t.eq(OwnNoise.step_level("sprint", Noises.NONE, false, Places.CLINIC), 0, "standing still: 0")
	var creep := OwnNoise.step_level("creep", Noises.NONE, true, Places.CLINIC)
	var walk := OwnNoise.step_level("walk", Noises.NONE, true, Places.CLINIC)
	var sprint := OwnNoise.step_level("sprint", Noises.NONE, true, Places.CLINIC)
	t.check(sprint > walk and walk > creep and creep > 0, "sprint %d > walk %d > creep %d > 0" % [sprint, walk, creep])
	t.eq(NoiseMeter.band_of(creep), &"whisper", "a creep reads green")
	t.eq(NoiseMeter.band_of(walk), &"talk", "a walk reads yellow")
	t.eq(NoiseMeter.band_of(sprint), &"shout", "a sprint reads red")
	# The scale is the voice's: the rules' whisper, talk and shout radii land in the meter's three bands.
	t.eq(NoiseMeter.band_of(OwnNoise.metres_to_level(Noises.VOICE_WHISPER)), &"whisper", "the rules' whisper radius is green")
	t.eq(NoiseMeter.band_of(OwnNoise.metres_to_level(Noises.VOICE_TALK)), &"talk", "the rules' talk radius is yellow")
	t.eq(NoiseMeter.band_of(OwnNoise.metres_to_level(Noises.VOICE_SHOUT)), &"shout", "the rules' shout radius is red")

func test_opening_is_the_rules_noise(t: T) -> void:
	var slow := OwnNoise.open_level(false)
	var fast := OwnNoise.open_level(true)
	t.eq(slow, OwnNoise.metres_to_level(Noises.search_radius(false)), "slow F: the rules' careful-open noise")
	t.eq(fast, OwnNoise.metres_to_level(Noises.search_radius(true)), "Shift+F: the rules' rushed-open noise")
	t.check(fast > slow and slow > 0, "a fast open (%d) reads higher than a slow one (%d)" % [fast, slow])
	var o := OwnNoise.new()
	o.on_events([{"type": "searchStart", "playerId": "me", "fast": false}], "me", 1000)
	t.eq(o.pulse_level(1000), 0, "a slow open makes no noise at its start (the rules make it at the end)")
	o.on_events([{"type": "searchDone", "playerId": "me", "fast": false}], "me", 2000)
	t.eq(o.pulse_level(2000), slow, "a slow open's end: the slow level")
	t.eq(o.pulse_level(2000 + OwnNoise.PULSE_MS), 0, "held PULSE_MS, then gone")
	o.on_events([{"type": "searchStart", "playerId": "me", "fast": true}], "me", 5000)
	t.eq(o.pulse_level(5000), fast, "a fast open's start: the fast level")
	o.on_events([{"type": "searchStart", "playerId": "other", "fast": true}, {"type": "searchStart", "playerId": "me", "fast": true, "silent": true}], "me", 9000)
	t.eq(o.pulse_level(9000), 0, "never another player's open, never a silent one")
	o.on_events([{"type": "hideStart", "playerId": "me", "fast": false}], "me", 12000)
	t.eq(o.pulse_level(12000), OwnNoise.metres_to_level(Settings.f(null, &"noise.hide", Noises.HIDE)), "into a hide: the rules' hide noise")

func test_the_playroom_walk_is_not_a_noise(t: T) -> void:
	t.eq(OwnNoise.step_level("walk", Noises.NONE, true, Places.PLAYROOM), 0, "the Playroom: walking is not a noise")
	t.eq(OwnNoise.step_level("creep", Noises.NONE, true, Places.PLAYROOM), 0, "the Playroom: creeping is not a noise")
	t.check(OwnNoise.step_level("sprint", Noises.NONE, true, Places.PLAYROOM) > 0, "the Playroom: sprinting is")

func test_the_host_row_and_the_meter(t: T) -> void:
	var o := OwnNoise.new()
	var me := {"status": "ok", "x": 3.0, "z": 3.0, "gait": "walk"}
	o.feed_me(me, 1000, Noises.NONE, Places.CLINIC, false)
	t.eq(o.steps, 0, "the first row: not moving yet")
	o.feed_me({"status": "ok", "x": 3.1, "z": 3.0, "gait": "walk"}, 1050, Noises.NONE, Places.CLINIC, false)
	t.eq(o.steps, OwnNoise.step_level("walk", Noises.NONE, true, Places.CLINIC), "moving 2 m/s at a walk: the walk's level")
	o.feed_me({"status": "ok", "x": 3.1, "z": 3.0, "gait": "walk"}, 1500, Noises.NONE, Places.CLINIC, false)
	t.eq(o.steps, 0, "standing still again: 0")
	o.feed_me({"status": "down", "x": 4.0, "z": 3.0, "gait": "walk"}, 1550, Noises.NONE, Places.CLINIC, false)
	t.eq(o.steps, 0, "not on their feet: 0")
	o.feed_me({"status": "ok", "x": 5.0, "z": 3.0, "gait": "sprint", "speed": 5.0, "aboard": true}, 1600, Noises.NONE, Places.CLINIC, false)
	t.eq(o.steps, 0, "in the car: no noise (the rules make none there)")
	o.feed_me({"status": "ok", "x": 6.0, "z": 3.0, "gait": "sprint", "speed": 5.0, "aboard": false}, 1650, Noises.NONE, Places.CLINIC, false)
	t.eq(o.steps, OwnNoise.step_level("sprint", Noises.NONE, true, Places.CLINIC), "the row's own speed: sprinting")
	o.feed_me({"status": "ok", "x": 6.0, "z": 3.0, "gait": "sprint", "speed": 0.0}, 2000, Noises.NONE, Places.CLINIC, false)
	t.eq(o.steps, 0, "the row's own speed 0: still")
	# The meter: hidden until a noise, the loudest source, quiet again 4 s after, force_show.
	var m := NoiseMeter.new()
	t.eq(m.alpha(0, false), 0.0, "quiet by default: hidden before any noise")
	t.eq(m.alpha(0, true), 1.0, "held Tab: shown")
	m.feed(&"voice", 0, 100)
	m.feed(&"steps", 9, 100)
	m.feed(&"open", 4, 100)
	t.eq(m.level, 9, "the loudest source is shown")
	m.feed(&"steps", 0, 200)
	m.feed(&"open", 0, 200)
	t.eq(m.level, 0, "all quiet")
	t.eq(m.alpha(200 + NoiseMeter.SHOW_MS - 100, false), 1.0, "still shown just under 4 s after the last noise")
	t.eq(m.alpha(200 + NoiseMeter.SHOW_MS + NoiseMeter.FADE_MS + 1, false), 0.0, "gone after 4 s and the fade")
	# The HUD with no microphone at all and with the voice off: steps and opens still show.
	var hud := MicHud.new()
	hud.in_run = true
	hud.voice_on = false
	hud.own.steps = 9
	hud._process(0.0)
	t.eq(hud.noise.level, 9, "no microphone, voice off: the meter shows the steps")
	t.eq(hud.modulate.a, 1.0, "and is drawn")
	hud.in_run = false
	hud._process(0.0)
	t.eq(hud.noise.level, 0, "off a floor: nothing")
	hud.free()
