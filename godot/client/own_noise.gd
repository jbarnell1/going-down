# VC4: the noise this player makes, for the HUD's one meter (client/noise_meter.gd, drawn by client/mic_hud.gd). The
# owner, 21 Nov: "Should those walking and running things be tied into the live microphone so you can see how much
# noise you're making as a player as well as your voice? And don't forget about opening things. If you do shift F,
# it's a lot louder noise jump in the live meter than if you're doing the slow regular F open."
# The instrument never lies: every number here is the rules' own (sim/noise.gd, the same live settings), never a
# new loudness. A noise in the rules is a radius in metres; the meter's 0 to 15 is the voice's scale, where the
# rules' whisper (2 m), talk (8 m) and shout (16 m) land in the meter's green, yellow and red: level = metres x 15 / 16,
# rounded, at most 15. Sources:
#   steps   while the host's snapshot has this player moving faster than the rules' MOVING: the gait's radius on
#           the ground under them (sim/noise.gd gait_radius; ground with no surface reads as gravel, as the rules do;
#           the Arboretum's own surfaces there), Soft Shoes 0.75 for a walk or creep, as the rules apply it.
#           The Playroom: "Walking is not a noise" (North Star A11), so a walk or a creep is 0 there; a sprint is not.
#   open    this player's own search events, as the rules make them: a slow open (F) at its end (searchDone),
#           a fast one (Shift+F) at its start (searchStart); never one marked silent. Held PULSE_MS on the meter.
#   hide    getting into or out of a hide (hideStart, hideLeave): the rules' hide noise, held PULSE_MS.
# Nothing here says who hears or how far; the meter never shows or hides by which resident is on the floor.
extends RefCounted

const Noises = preload("res://sim/noise.gd")
const Settings = preload("res://sim/settings.gd")
const Places = preload("res://sim/places.gd")

const PULSE_MS := 700
## A step level stays this long after the last snapshot that showed movement (snapshots come about 20 a second).
const STEP_HOLD_MS := 250

var steps := 0
var pulse := 0
var pulse_until := -1
var _at: Variant = null
var _at_ms := -1
var _moved_ms := -1

static func metres_to_level(m: float) -> int:
	return clampi(roundi(m * 15.0 / 16.0), 0, Noises.VOICE_MAX)

## The steps' level for a gait on a surface (sim/noise.gd's surface index), moving or not, on `place`.
static func step_level(gait: String, surface: int, moving: bool, place: StringName, soft_shoes := false, tuning: Settings.Values = null) -> int:
	if not moving:
		return 0
	if place == Places.PLAYROOM and gait != "sprint":
		return 0
	var r := Noises.gait_radius(StringName(gait), surface, tuning)
	if soft_shoes and gait != "sprint":
		r *= Noises.SOFT_SHOES
	return metres_to_level(r)

## An open's level: F (slow) or Shift+F (fast).
static func open_level(fast: bool, tuning: Settings.Values = null) -> int:
	return metres_to_level(Noises.search_radius(fast, tuning))

static func hide_level(tuning: Settings.Values = null) -> int:
	return metres_to_level(Settings.f(tuning, &"noise.hide", Noises.HIDE))

## The host's row for this player (`me`: x, z, gait, status), seen at `now_ms`. `surface`: the ground under them.
func feed_me(me: Dictionary, now_ms: int, surface: int, place: StringName, soft_shoes: bool, tuning: Settings.Values = null) -> void:
	if str(me.get("status", "")) != "ok" or not me.has("x"):
		steps = 0
		_at = null
		return
	# In the car: the rules make no noise for a player in the car (sim/noise.gd).
	if me.get("aboard", false) == true:
		steps = 0
		_at = null
		return
	var at := Vector2(float(me["x"]), float(me["z"]))
	# The frame's own speed when the row carries it (client/play_link.gd), else from the rows' positions.
	if me.has("speed"):
		if float(me["speed"]) > Noises.MOVING:
			_moved_ms = now_ms
	elif _at is Vector2 and now_ms > _at_ms and at != _at:
		var speed := at.distance_to(_at as Vector2) / (float(now_ms - _at_ms) / 1000.0)
		if speed > Noises.MOVING:
			_moved_ms = now_ms
	if not (_at is Vector2) or at != _at:
		_at = at
		_at_ms = now_ms
	var moving := _moved_ms >= 0 and now_ms - _moved_ms <= STEP_HOLD_MS
	steps = step_level(str(me.get("gait", "walk")), surface, moving, place, soft_shoes, tuning)

## This player's events from the host: opens and hides.
func on_events(events: Array, my: String, now_ms: int, tuning: Settings.Values = null) -> void:
	for e: Dictionary in events:
		if str(e.get("playerId", "")) != my or e.get("silent", false):
			continue
		var ty := str(e.get("type", ""))
		var lv := 0
		if ty == "searchStart" and bool(e.get("fast", false)):
			lv = open_level(true, tuning)
		elif ty == "searchDone" and not bool(e.get("fast", false)):
			lv = open_level(false, tuning)
		elif ty == "hideStart" or ty == "hideLeave":
			lv = hide_level(tuning)
		if lv > 0:
			pulse = lv if now_ms >= pulse_until else maxi(pulse, lv)
			pulse_until = now_ms + PULSE_MS

func pulse_level(now_ms: int) -> int:
	return pulse if now_ms < pulse_until else 0
