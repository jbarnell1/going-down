# VC1, the microphone on the player's own machine (North Star B5 "Your real voice counts. The game reads how loud
# your microphone is."). Pure: no audio here. client/mic.gd measures each 50 ms window of the microphone (RMS, in dB)
# and throws the window away; this turns that one number into a level 0 to 15 by this player's own marks, keeps the
# "talking" state, and holds the player's choices. Only the level ever leaves the machine (net/client.gd "voice").
#
# The level (the HUD's meter shows exactly this number, the one the host is sent):
#   0        below the whisper mark: silent to the residents
#   1 to 4   a whisper (sim/noise.gd VOICE_WHISPER_AT .. VOICE_TALK_AT - 1)
#   5 to 10  talking (the talk mark is level 5)
#   11 to 15 a shout or a scream
# Each level is one step (step_db) louder than the one below. The marks come from this player's two readings (the
# calibration right after they say yes, client/mic.gd): the room's floor (quiet_db) and their normal talking voice
# (talk_db). Their normal voice lands in the middle of the talk band, TALK_LEVEL (8 of 15), and the floor sits below
# the whisper mark: the step is the gap between the two (less FLOOR_GAP) over TALK_LEVEL - 0.5, kept between STEP_MIN
# and STEP_MAX. A reading whose voice is less than MIN_SPAN dB over the floor, or with no signal, is refused
# (calibration_problem). Skipped, the defaults: a room at -60 dBFS, a voice at -30 (a headset at a normal distance; the
# spike on the owner's PC read a quiet room at -60 to -70). SENSITIVITY moves every mark: each point above 50 lowers
# them SENS_DB. On speakers every mark is SPEAKER_LIFT_DB higher (the game's own sound and friends' voices come back
# into the microphone).
#
# "Talking" (for the HUD and the intercom's hush, VC2): the level at or above the talk mark for TALK_HOLD seconds;
# it ends after TALK_RELEASE seconds below it (the gaps between words).
#
# Kept in the player's own settings file (user://settings.cfg, section "mic", beside the sound sliders of
# client/volume.gd): the choice on the consent screen, on or off, headphones or speakers, the sensitivity and the
# two calibrated numbers. Nothing about the voice itself is ever stored. Automated runs (`auto=1`) set persist = false
# and never open the microphone (client/mic.gd).
extends RefCounted

const SAVE_PATH := "user://settings.cfg"
const SECTION := "mic"
const WINDOW := 0.05
const MAX := 15
const WHISPER_AT := 1
const TALK_AT := 5
const SHOUT_AT := 11
const TALK_HOLD := 0.2
const TALK_RELEASE := 0.4
const QUIET_DB := -60.0
const TALK_DB := -30.0
const TALK_LEVEL := 8
const FLOOR_GAP := 3.0
const MIN_SPAN := 14.0
const NO_SIGNAL_DB := -95.0
const STEP_MIN := 1.5
const STEP_MAX := 3.5
const SENS_DEFAULT := 50
const SENS_STEP := 5
const SENS_DB := 0.3
const SPEAKER_LIFT_DB := 6.0
const SILENT_DB := -120.0
const EPS := 1e-6

## The consent screen was answered (yes or not now). Until then the microphone stays closed and the screen shows.
var asked := false
## The player wants the microphone on (a yes on the consent screen, then M or the settings page).
var enabled := false
var speakers := false
var sensitivity := SENS_DEFAULT
var quiet_db := QUIET_DB
var talk_db := TALK_DB
## The marks are this player's own (a calibration was accepted); false: the defaults.
var calibrated := false
var persist := true
var save_path := SAVE_PATH

## The newest window's level and the talking state.
var level := 0
var talking := false
var _above := 0.0
var _below := 0.0

## RMS of a window of stereo frames, in dB (SILENT_DB for silence or nothing).
static func rms_db(frames: PackedVector2Array) -> float:
	if frames.is_empty():
		return SILENT_DB
	var sum := 0.0
	for f in frames:
		sum += f.x * f.x + f.y * f.y
	var rms := sqrt(sum / (2.0 * frames.size()))
	return maxf(SILENT_DB, linear_to_db(rms)) if rms > 0.0 else SILENT_DB

## Every mark moved by sensitivity and speakers: positive lowers them (more sensitive).
func _shift() -> float:
	return float(sensitivity - SENS_DEFAULT) * SENS_DB - (SPEAKER_LIFT_DB if speakers else 0.0)

## dB of one level step.
func step_db() -> float:
	return clampf((talk_db - quiet_db - FLOOR_GAP) / (float(TALK_LEVEL) - 0.5), STEP_MIN, STEP_MAX)

## The dB at which `lv` (1 to 15) starts: the normal voice in the middle of TALK_LEVEL.
func mark_db(lv: int) -> float:
	return talk_db - _shift() + (float(lv - TALK_LEVEL) - 0.5) * step_db()

## The level (0 to 15) of a window at `db`.
func level_of(db: float) -> int:
	var one := mark_db(WHISPER_AT)
	if db < one - EPS:
		return 0
	return clampi(WHISPER_AT + floori((db - one) / step_db() + EPS), WHISPER_AT, MAX)

## One window's level: the meter and the talking state.
func feed(lv: int, dt: float = WINDOW) -> void:
	level = clampi(lv, 0, MAX)
	if level >= TALK_AT:
		_above += dt
		_below = 0.0
		if _above >= TALK_HOLD - EPS:
			talking = true
	else:
		_below += dt
		_above = 0.0
		if _below >= TALK_RELEASE - EPS:
			talking = false

## Back to silence (the microphone closed).
func reset() -> void:
	level = 0
	talking = false
	_above = 0.0
	_below = 0.0

## Why two readings (the room `quiet`, a normal voice `talk`, dB) cannot set the marks, in words for the screen, or "".
static func calibration_problem(quiet: float, talk: float) -> String:
	if talk <= NO_SIGNAL_DB:
		return "NO MICROPHONE SIGNAL"
	if talk - quiet < MIN_SPAN:
		return "YOUR VOICE WAS BARELY LOUDER THAN THE ROOM"
	return ""

## The calibration's two numbers. False (nothing changed) when calibration_problem refuses them.
func calibrate(quiet: float, talk: float) -> bool:
	if calibration_problem(quiet, talk) != "":
		return false
	quiet_db = clampf(quiet, -110.0, -10.0)
	talk_db = clampf(talk, quiet_db + MIN_SPAN, 0.0)
	calibrated = true
	return true

## Skip: the default marks.
func use_defaults() -> void:
	quiet_db = QUIET_DB
	talk_db = TALK_DB
	calibrated = false

## A calibration's measurement: `share` (0 to 1) of the way up the sorted windows (the room's middle, a voice's
## loud end: speech has gaps).
static func percentile(dbs: PackedFloat32Array, share: float) -> float:
	if dbs.is_empty():
		return SILENT_DB
	var s := dbs.duplicate()
	s.sort()
	return s[clampi(roundi(share * float(s.size() - 1)), 0, s.size() - 1)]

func set_sensitivity(v: int) -> void:
	sensitivity = clampi(v, 0, 100)

func load_saved() -> void:
	asked = false
	enabled = false
	speakers = false
	sensitivity = SENS_DEFAULT
	use_defaults()
	if not persist:
		return
	var cf := ConfigFile.new()
	if cf.load(save_path) != OK:
		return
	asked = bool(cf.get_value(SECTION, "asked", false))
	enabled = asked and bool(cf.get_value(SECTION, "on", false))
	speakers = bool(cf.get_value(SECTION, "speakers", false))
	set_sensitivity(int(cf.get_value(SECTION, "sensitivity", SENS_DEFAULT)))
	if bool(cf.get_value(SECTION, "calibrated", false)):
		calibrate(float(cf.get_value(SECTION, "quiet_db", QUIET_DB)), float(cf.get_value(SECTION, "talk_db", TALK_DB)))

func save() -> void:
	if not persist:
		return
	var cf := ConfigFile.new()
	cf.load(save_path)   # keep anything else the file holds (the sound, the brightness)
	cf.set_value(SECTION, "asked", asked)
	cf.set_value(SECTION, "on", enabled)
	cf.set_value(SECTION, "speakers", speakers)
	cf.set_value(SECTION, "sensitivity", sensitivity)
	cf.set_value(SECTION, "quiet_db", quiet_db)
	cf.set_value(SECTION, "talk_db", talk_db)
	cf.set_value(SECTION, "calibrated", calibrated)
	cf.save(save_path)
