# VC1, the microphone on the player's machine (client/mic_meter.gd, client/mic.gd). No audio is used: a fake level
# source stands in for the microphone, as the test channel's `mic <level>` does. Proved here:
#   1. The level from a window's loudness: silence and the default room are 0, the default voice level 8, each level
#      one step louder; the sensitivity lowers the marks, speakers raise them; RMS of a window.
#   1b. The calibration (required after a yes): fake room and voice readings put the voice at level 8 and the room
#      under the whisper mark; a voice too near the room, or silence, is refused in plain words and the marks kept;
#      skip gives the defaults; the screen's flow (room, then the line, then done or the reason).
#   2. "Talking": at or above the talk mark for 200 ms (not 150), and it ends 400 ms after the voice drops below it.
#   3. The fake source moves the meter, the talking state and the loudest-since-last level the input carries; the
#      microphone's level is 0 unless it is listening; an automated run never opens it (and never reads or writes the
#      player's file); the browser never opens it.
#   3b. The HUD's noise meter (client/noise_meter.gd; the owner: green for a whisper, yellow for talk, red for a
#      shout, and a brief flash): the band colour of each level; a flash only when the level crosses UP into a higher
#      band, lasting 150 ms, in the new band's colour; the loudest named source is shown.
#   4. The choices round-trip through the settings file; nothing about the voice is stored.
extends RefCounted

const T = preload("res://tests/t.gd")
const MicMeter = preload("res://client/mic_meter.gd")
const Mic = preload("res://client/mic.gd")
const NoiseMeter = preload("res://client/noise_meter.gd")

func test_levels_from_loudness(t: T) -> void:
	var m := MicMeter.new()
	# The defaults (a room at -60 dBFS, a voice at -30): a step of 3.5 dB, the voice in the middle of level 8.
	t.eq(m.step_db(), 3.5, "the default step: 3.5 dB")
	t.eq(m.level_of(MicMeter.SILENT_DB), 0, "silence: 0")
	t.eq(m.level_of(-60.0), 0, "the default room (-60 dBFS): 0")
	t.eq(m.level_of(-30.0), 8, "the default normal voice (-30): level 8, the middle of the talk band")
	t.eq(m.level_of(-56.5), 0, "just under the whisper mark (-56.25): 0")
	t.eq(m.level_of(-56.0), 1, "the whisper mark: 1")
	t.eq(m.level_of(-42.5), 4, "just under the talk mark (-42.25): 4")
	t.eq(m.level_of(-42.0), 5, "the talk mark: 5")
	t.eq(m.level_of(-21.0), 11, "the shout mark (-21.25): 11")
	t.eq(m.level_of(40.0), 15, "never over 15")
	for lv in range(1, 16):
		t.eq(m.level_of(m.mark_db(lv)), lv, "level %d starts at its mark (%.2f dB)" % [lv, m.mark_db(lv)])
	m.set_sensitivity(100)
	t.eq(m.level_of(-45.0), 8, "sensitivity 100: the marks 15 dB lower")
	m.set_sensitivity(0)
	t.eq(m.level_of(-30.0), 4, "sensitivity 0: the marks 15 dB higher, a normal voice is a whisper")
	m.set_sensitivity(MicMeter.SENS_DEFAULT)
	m.speakers = true
	t.check(m.level_of(-30.0) < 8, "on speakers, the marks 6 dB higher (%d)" % m.level_of(-30.0))
	t.eq(m.level_of(-24.0), 8, "and the same level 6 dB louder")
	m.speakers = false

## VC1: the required calibration (the owner, 21 Nov: a normal talking level, like the brightness step).
func test_calibration_sets_the_marks(t: T) -> void:
	# A noisy room at -45 and a loud headset voice at -15: the voice reads 8, the room 0, the marks in order.
	var m := MicMeter.new()
	t.check(m.calibrate(-45.0, -15.0) and m.calibrated, "the readings are taken")
	t.eq(m.level_of(-15.0), MicMeter.TALK_LEVEL, "their normal voice reads %d" % MicMeter.TALK_LEVEL)
	t.eq(m.level_of(-45.0), 0, "their room is under the whisper mark")
	t.check(m.mark_db(1) > -45.0 and m.mark_db(5) > m.mark_db(1) and m.mark_db(11) > m.mark_db(5), "marks in order (%.1f, %.1f, %.1f)" % [m.mark_db(1), m.mark_db(5), m.mark_db(11)])
	# A quiet room and a soft voice 20 dB over it: a smaller step, still 8 and 0.
	t.check(m.calibrate(-70.0, -50.0), "a soft voice in a quiet room is taken")
	t.eq(m.level_of(-50.0), 8, "the soft voice reads 8 (step %.2f)" % m.step_db())
	t.eq(m.level_of(-70.0), 0, "the quiet room 0")
	t.eq(m.level_of(-69.0), 0, "a little over the room: still 0")
	# Refused: too little over the room, or no signal; the marks stay as they were.
	var before := m.mark_db(5)
	t.check(not m.calibrate(-40.0, -30.0), "a voice 10 dB over the room is refused")
	t.eq(MicMeter.calibration_problem(-40.0, -30.0), "YOUR VOICE WAS BARELY LOUDER THAN THE ROOM", "and says why")
	t.eq(m.mark_db(5), before, "the marks did not move")
	t.check(not m.calibrate(MicMeter.SILENT_DB, MicMeter.SILENT_DB), "silence is refused")
	t.eq(MicMeter.calibration_problem(MicMeter.SILENT_DB, MicMeter.SILENT_DB), "NO MICROPHONE SIGNAL", "as no signal")
	# Skip: the defaults.
	m.use_defaults()
	t.check(not m.calibrated and m.quiet_db == MicMeter.QUIET_DB and m.talk_db == MicMeter.TALK_DB and m.level_of(-30.0) == 8, "skip gives the default marks")

func test_the_calibration_screen_flow(t: T) -> void:
	var mic := Mic.new()
	mic.setup(true)
	mic.fake_level = 0
	t.check(mic.start_calibration(), "listening (the fake source): the readings start")
	# 2 s of the room at -62, then 3 s of speech at -20 with gaps at -60.
	for _k in roundi(Mic.CALIB_QUIET / 0.05):
		mic.calib_window(-62.0)
	t.check(str(mic.calib_line()).begins_with("SAY THIS AT YOUR NORMAL TALKING VOICE"), "then the line to read: %s" % mic.calib_line())
	for k in roundi(Mic.CALIB_TALK / 0.05):
		mic.calib_window(-60.0 if k % 4 == 0 else -20.0)
	t.eq(mic.calib_result, "ok", "the readings set the marks")
	t.eq(mic.meter.level_of(-20.0), 8, "their voice reads 8")
	t.eq(mic.meter.level_of(-62.0), 0, "their room 0")
	# Again, mumbling: refused, the reason shown, the marks kept.
	var kept := mic.meter.mark_db(5)
	mic.start_calibration()
	for _k in roundi(Mic.CALIB_QUIET / 0.05):
		mic.calib_window(-50.0)
	for _k in roundi(Mic.CALIB_TALK / 0.05):
		mic.calib_window(-45.0)
	t.eq(mic.calib_result, "YOUR VOICE WAS BARELY LOUDER THAN THE ROOM", "a mumble is refused in plain words")
	t.eq(mic.calib_line(), "YOUR VOICE WAS BARELY LOUDER THAN THE ROOM", "and the screen says so")
	t.eq(mic.meter.mark_db(5), kept, "the marks from before are kept")
	mic.calib_open = true
	mic.skip_calibration()
	t.check(not mic.calib_open and not mic.meter.calibrated and mic.meter.level_of(-30.0) == 8, "skip: the defaults, the card closed")
	mic.fake_level = -1
	t.check(not mic.start_calibration() and mic.calib_result == "NO MICROPHONE SIGNAL", "not listening: no signal, said plainly")
	mic.free()

func test_rms(t: T) -> void:
	# RMS: a full-scale square wave is 0 dB, a tenth of it -20 dB.
	var w := PackedVector2Array()
	for i in 2400:
		var v := 1.0 if i % 2 == 0 else -1.0
		w.append(Vector2(v, v))
	t.check(absf(MicMeter.rms_db(w)) < 1e-3, "full-scale square: 0 dB (%.3f)" % MicMeter.rms_db(w))
	for i in w.size():
		w[i] = w[i] * 0.1
	t.check(absf(MicMeter.rms_db(w) + 20.0) < 1e-3, "a tenth: -20 dB (%.3f)" % MicMeter.rms_db(w))
	t.eq(MicMeter.rms_db(PackedVector2Array()), MicMeter.SILENT_DB, "no frames: silence")
	t.eq(MicMeter.percentile(PackedFloat32Array([-50.0, -10.0, -30.0, -40.0, -20.0]), 0.5), -30.0, "the middle of five")

func test_talking_needs_200_ms(t: T) -> void:
	var m := MicMeter.new()
	for _k in 3:
		m.feed(7)
	t.check(not m.talking, "150 ms at talking level: not yet talking")
	m.feed(7)
	t.check(m.talking, "200 ms: talking")
	m.feed(3)
	m.feed(2)
	m.feed(0)
	m.feed(0)
	m.feed(0)
	m.feed(0)
	m.feed(0)
	t.check(m.talking, "350 ms of quiet between words: still talking")
	m.feed(0)
	t.check(not m.talking, "400 ms below the mark: no longer talking")
	# A whisper never talks; a shout does, after the same hold.
	m.reset()
	for _k in 40:
		m.feed(4)
	t.check(not m.talking, "two seconds of whispering: never talking")
	m.reset()
	for _k in 3:
		m.feed(14)
	t.check(not m.talking, "a 150 ms yelp: not talking")
	m.feed(14)
	t.check(m.talking, "a shout held 200 ms: talking")
	# Short bursts with gaps never add up.
	m.reset()
	for _k in 10:
		m.feed(8)
		m.feed(8)
		m.feed(8)
		m.feed(0)
	t.check(not m.talking, "150 ms bursts with gaps: never talking")

func test_the_fake_source_moves_the_meter(t: T) -> void:
	var mic := Mic.new()
	mic.setup(true)
	t.check(not mic.allowed and not mic.meter.persist, "an automated run never opens the microphone or touches the file")
	t.check(not mic.needs_consent(), "and never shows the consent screen")
	t.eq(mic.level(), 0, "not listening: level 0")
	t.eq(mic.take(), 0, "and nothing to send")
	mic.fake_level = 8
	mic._process(0.05)
	mic._process(0.05)
	mic._process(0.05)
	t.eq(mic.level(), 8, "the fake level moves the meter")
	t.check(not mic.talking(), "150 ms: not talking yet")
	mic._process(0.05)
	t.check(mic.talking(), "200 ms: talking")
	t.eq(mic.take(), 8, "the input carries the loudest since the last one")
	mic.fake_level = 3
	mic._process(0.05)
	t.eq(mic.take(), 3, "then the next")
	t.eq(mic.take(), 0, "and nothing twice")
	mic.fake_level = 30
	mic._process(0.05)
	t.eq(mic.level(), 15, "a fake level over 15 is 15")
	mic.fake_level = -1
	t.eq(mic.level(), 0, "the fake source off: not listening, 0")
	t.check(not mic.talking(), "and not talking")
	var d := mic.describe()
	t.check(d.has("status") and d.has("level") and d.has("talking"), "the test channel's view: %s" % str(d))
	mic.free()

func test_choices_round_trip_and_no_voice_is_kept(t: T) -> void:
	var path := "user://test_mic_settings.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var m := MicMeter.new()
	m.save_path = path
	m.load_saved()
	t.check(not m.asked and not m.enabled, "a new player: never asked, the microphone off")
	m.asked = true
	m.enabled = true
	m.speakers = true
	m.set_sensitivity(70)
	t.check(m.calibrate(-55.0, -25.0), "a good reading")
	m.feed(9)
	m.save()
	var n := MicMeter.new()
	n.save_path = path
	n.load_saved()
	t.check(n.asked and n.enabled and n.speakers and n.sensitivity == 70, "the choices come back")
	t.check(absf(n.quiet_db + 55.0) < 1e-6 and absf(n.talk_db + 25.0) < 1e-6, "and the two calibrated numbers")
	var cf := ConfigFile.new()
	cf.load(path)
	var keys := cf.get_section_keys(MicMeter.SECTION)
	keys.sort()
	t.eq(keys, PackedStringArray(["asked", "calibrated", "on", "quiet_db", "sensitivity", "speakers", "talk_db"]), "only the choices and two numbers are stored")
	var off := MicMeter.new()
	off.save_path = path
	off.persist = false
	off.load_saved()
	t.check(not off.asked and not off.enabled, "not persisting: the defaults, the file unread")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	t.check(Mic.can_listen() == (not OS.has_feature("web") and bool(ProjectSettings.get_setting("audio/driver/enable_input", false))), "the browser never listens")
	t.check(bool(ProjectSettings.get_setting("audio/driver/enable_input", false)), "the desktop build has audio input on (project.godot)")

func test_the_noise_meter_bands_and_flash(t: T) -> void:
	t.eq(NoiseMeter.color_of(0), NoiseMeter.OFF, "0: unlit")
	for lv in range(1, 5):
		t.eq(NoiseMeter.color_of(lv), NoiseMeter.GREEN, "level %d (whisper): green" % lv)
	for lv in range(5, 11):
		t.eq(NoiseMeter.color_of(lv), NoiseMeter.YELLOW, "level %d (talk): yellow" % lv)
	for lv in range(11, 16):
		t.eq(NoiseMeter.color_of(lv), NoiseMeter.RED, "level %d (shout): red" % lv)
	t.check(NoiseMeter.WHISPER_AT == MicMeter.WHISPER_AT and NoiseMeter.TALK_AT == MicMeter.TALK_AT and NoiseMeter.SHOUT_AT == MicMeter.SHOUT_AT, "the meter's bands are the microphone's")
	var m := NoiseMeter.new()
	m.feed(&"voice", 3, 1000)
	t.check(m.flashing(1000) and m.flash_band == &"whisper", "silent to a whisper: a flash, green")
	t.check(m.flashing(1149) and not m.flashing(1150), "it lasts 150 ms")
	m.feed(&"voice", 4, 1200)
	t.check(not m.flashing(1200), "louder inside the band: no flash")
	m.feed(&"voice", 8, 1300)
	t.check(m.flashing(1300) and m.flash_color() == NoiseMeter.YELLOW, "up into talking: a yellow flash")
	m.feed(&"voice", 13, 1500)
	t.check(m.flashing(1500) and m.flash_color() == NoiseMeter.RED, "up into a shout: a red flash")
	m.feed(&"voice", 6, 1700)
	t.check(not m.flashing(1700), "down to talking: no flash")
	m.feed(&"voice", 0, 1800)
	t.check(not m.flashing(1800), "down to silence: no flash")
	# Named sources: the loudest is shown (the next stage adds footsteps and the like).
	m.feed(&"steps", 6, 2000)
	m.feed(&"voice", 2, 2000)
	t.eq(m.level, 6, "the loudest source is shown")
	m.feed(&"steps", 0, 2100)
	t.eq(m.level, 2, "then the next")
