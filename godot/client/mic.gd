# VC1, the microphone's capture (North Star B5; the plan in .local/reviews/voice-plan.md section 4). One node under
# client/main.gd. It plays an AudioStreamMicrophone into its own bus BUS, MUTED, with an AudioEffectCapture on it: the
# player never hears themselves, and nothing is played anywhere. Every 50 ms window of frames is measured (RMS) and
# thrown away; client/mic_meter.gd turns the number into a level 0 to 15. NOTHING IS RECORDED, KEPT, LOGGED OR SENT
# except that level (net/client.gd "voice").
#
# Needs the project setting audio/driver/enable_input (project.godot: on, off in the web and server builds). The bus
# is made here at run time, as client/music.gd makes its own, because the import pass rewrites default_bus_layout.tres.
# The browser build never opens it (a browser player is a NO MIC player), nor does an automated run (`auto=1`): a test
# drives the level with fake_level (the test channel's `mic <level>`).
#
# status: &"on" listening; &"off" the player turned it off or has not said yes; &"none" no microphone, or no signal
# from it for NO_SIGNAL seconds (Windows' privacy setting, a mic held by another program, the browser).
extends Node

const MicMeter = preload("res://client/mic_meter.gd")

const BUS := "MicIn"
const NO_SIGNAL := 2.0

var meter := MicMeter.new()
var status: StringName = &"off"
## Tests and the test channel: a level (0 to 15) in place of the microphone, or -1.
var fake_level := -1
## False: never open the microphone (automated runs, the browser, a build without audio input).
var allowed := true
## The loudest level since take() was last called (each frame's input, net/client.gd keeps the loudest between sends).
var _peak := 0
## The newest window's loudness, dB (for the test channel's check of a real microphone only).
var last_db := -120.0
var _player: AudioStreamPlayer = null
var _cap: AudioEffectCapture = null
var _quiet := 0.0
var _acc := 0.0
## The calibration (VC1, required after a yes): CALIB_QUIET s of "stay quiet" (the room's floor, the middle window),
## then CALIB_TALK s of CALIB_LINE read at a normal voice (the loud end, 80 % up: speech has gaps). In progress:
## [phase, seconds left, PackedFloat32Array of window dB], phases &"quiet" and &"talk"; [] when not running.
const CALIB_QUIET := 2.0
const CALIB_TALK := 3.0
const CALIB_LINE := "THE COMPANY THANKS YOU FOR YOUR DESCENT."
var calib: Array = []
var calib_quiet := 0.0
## The calibration screen is up (client/mic_hud.gd): after a yes, or "calibrate again".
var calib_open := false
## The last calibration's outcome: "" (none yet), "ok", or the refusal's words (MicMeter.calibration_problem).
var calib_result := ""

static func can_listen() -> bool:
	return not OS.has_feature("web") and bool(ProjectSettings.get_setting("audio/driver/enable_input", false))

## Reads the player's choices and opens the microphone if they said yes. `automated`: a scripted run, never opened.
func setup(automated: bool) -> void:
	meter.persist = not automated
	meter.load_saved()
	allowed = not automated and can_listen()
	# A check of the real microphone on this machine (`-- mic=1`, with or without auto=1): listening at once, the
	# defaults, nothing read or saved. Only ever asked for on the command line.
	if OS.get_cmdline_user_args().has("mic=1") and can_listen():
		meter.persist = false
		allowed = true
		meter.asked = true
		meter.enabled = true
	_apply()

## The consent screen's answer: yes opens it at once; not now keeps it off. Saved either way.
func answer(yes: bool) -> void:
	meter.asked = true
	meter.enabled = yes
	meter.save()
	_apply()
	if yes:
		open_calibration()

## The calibration screen, started at once.
func open_calibration() -> void:
	calib_open = true
	start_calibration()

## Skip: the default marks, the screen closed.
func skip_calibration() -> void:
	calib = []
	meter.use_defaults()
	meter.save()
	calib_result = ""
	calib_open = false

## The screen's "carry on" (after a good reading) or "carry on with the microphone off" (after a refusal).
func close_calibration(mic_off: bool) -> void:
	calib = []
	calib_open = false
	if mic_off:
		set_enabled(false)

func set_enabled(on: bool) -> void:
	meter.asked = true
	meter.enabled = on
	meter.save()
	_apply()

## M: on or off at once.
func toggle() -> void:
	set_enabled(not meter.enabled)

## The consent screen is due: never answered, and this machine could listen.
func needs_consent() -> bool:
	return not meter.asked and allowed

## Listening: a level reaches the host.
func listening() -> bool:
	return fake_level >= 0 or status == &"on"

## The level the HUD shows and the host is sent (0 unless listening).
func level() -> int:
	return meter.level if listening() else 0

func talking() -> bool:
	return listening() and meter.talking

## The loudest level since the last call (0 unless listening).
func take() -> int:
	var p := _peak if listening() else 0
	_peak = 0
	return p

func _apply() -> void:
	if meter.enabled and allowed:
		_open()
	else:
		_close()
		status = &"off" if allowed else &"none"

func _open() -> void:
	if _player != null:
		return
	var i := AudioServer.get_bus_index(BUS)
	if i < 0:
		AudioServer.add_bus()
		i = AudioServer.bus_count - 1
		AudioServer.set_bus_name(i, BUS)
	AudioServer.set_bus_mute(i, true)
	_cap = null
	for k in AudioServer.get_bus_effect_count(i):
		if AudioServer.get_bus_effect(i, k) is AudioEffectCapture:
			_cap = AudioServer.get_bus_effect(i, k) as AudioEffectCapture
	if _cap == null:
		_cap = AudioEffectCapture.new()
		_cap.buffer_length = 0.5
		AudioServer.add_bus_effect(i, _cap)
	_cap.clear_buffer()
	_player = AudioStreamPlayer.new()
	_player.stream = AudioStreamMicrophone.new()
	_player.bus = BUS
	add_child(_player)
	_player.play.call_deferred()
	status = &"on"
	_quiet = 0.0
	meter.reset()

func _close() -> void:
	if _player != null:
		_player.stop()
		_player.queue_free()
		_player = null
	if _cap != null:
		_cap.clear_buffer()
	meter.reset()
	calib = []

func _process(delta: float) -> void:
	if fake_level >= 0:
		_acc += delta
		while _acc >= MicMeter.WINDOW:
			_acc -= MicMeter.WINDOW
			_window(clampi(fake_level, 0, MicMeter.MAX), MicMeter.SILENT_DB)
		return
	if _player == null or _cap == null:
		return
	var need := maxi(1, int(AudioServer.get_mix_rate() * MicMeter.WINDOW))
	var got := false
	while _cap.get_frames_available() >= need:
		var db := MicMeter.rms_db(_cap.get_buffer(need))
		_window(meter.level_of(db), db)
		got = true
	if got:
		_quiet = 0.0
		status = &"on"
	else:
		_quiet += delta
		if _quiet >= NO_SIGNAL:
			status = &"none"
			meter.reset()
			if not calib.is_empty():
				calib = []
				calib_result = "NO MICROPHONE SIGNAL"

func _window(lv: int, db: float) -> void:
	last_db = db
	meter.feed(lv)
	_peak = maxi(_peak, meter.level)
	if not calib.is_empty():
		calib_window(db)

## One 50 ms window's loudness (dB) into the calibration in progress. Only the two resulting numbers are kept.
func calib_window(db: float) -> void:
	if calib.is_empty():
		return
	# A packed array is a value: append to it and put it back.
	var dbs: PackedFloat32Array = calib[2]
	dbs.append(db)
	calib[2] = dbs
	calib[1] = float(calib[1]) - MicMeter.WINDOW
	if float(calib[1]) > 1e-6:
		return
	if calib[0] == &"quiet":
		calib_quiet = MicMeter.percentile(calib[2], 0.5)
		calib = [&"talk", CALIB_TALK, PackedFloat32Array()]
	else:
		finish_calibration(calib_quiet, MicMeter.percentile(calib[2], 0.8))

## The two readings: the marks set and saved, or the refusal kept for the screen (the marks as they were).
func finish_calibration(quiet: float, talk: float) -> bool:
	calib = []
	var why := MicMeter.calibration_problem(quiet, talk)
	if why != "" or not meter.calibrate(quiet, talk):
		calib_result = why if why != "" else "THAT READING DID NOT WORK"
		return false
	meter.save()
	calib_result = "ok"
	return true

## The printed line read aloud in the calibration.
func calib_words() -> String:
	return CALIB_LINE

## Starts (or restarts) the two readings. A fake source (tests) may calibrate too, through calib_window.
func start_calibration() -> bool:
	calib_result = ""
	calib = [&"quiet", CALIB_QUIET, PackedFloat32Array()]
	if not listening():
		calib = []
		calib_result = "NO MICROPHONE SIGNAL"
		return false
	return true

## The calibration's words for the screen: what to do now, or how it went; "" when none has run.
func calib_line() -> String:
	if not calib.is_empty():
		if calib[0] == &"quiet":
			return "STAY QUIET... %d" % ceili(float(calib[1]))
		return "SAY THIS AT YOUR NORMAL TALKING VOICE... %d" % ceili(float(calib[1]))
	if calib_result == "ok":
		return "DONE: YOUR NORMAL VOICE READS ABOUT %d" % MicMeter.TALK_LEVEL
	return calib_result

## For the HUD and the test channel.
func describe() -> Dictionary:
	return {"status": String(status), "listening": listening(), "level": level(), "talking": talking(), "enabled": meter.enabled,
		"asked": meter.asked, "speakers": meter.speakers, "sensitivity": meter.sensitivity, "fake": fake_level, "allowed": allowed,
		"calibrating": calib_line(), "calibOpen": calib_open, "calibrated": meter.calibrated, "db": snappedf(last_db, 0.1)}
