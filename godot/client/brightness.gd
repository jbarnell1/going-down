# The player's brightness (owner, 18 Nov: "We probably need a dimness setting to set relative contrast levels
# at the start of the game or in settings"). Per player, never a host setting: it changes only this screen's
# final picture, as the tape filter's last step (client/tape.gdshader bright_lift, bright_gamma), so it
# composes with everything drawn before it (the floors, the residents, any light in the dark).
#
# One number, 0..STEPS, DEFAULT in the middle. The default is the game as built (no change at all). The range
# is CLAMPED as a fairness guard: at the top a blackout is still dark (tools/playthrough.mjs measures a
# blackout frame's mean at the lowest, the default and the highest setting), at the bottom the darkest grey
# the game asks anyone to see (THRESHOLD) still shows.
#
# The calibration card (client/brightness_card.gd) draws three badges in these greys on the game's black:
# LEFT is the darkest grey a player must be able to tell from black in the game's dark, MIDDLE is plain to
# see at any setting, RIGHT is darker than anything the game ever asks anyone to see. For every setting in
# range RIGHT < THRESHOLD < LEFT < MIDDLE after the change, so "raise until the left badge is barely there,
# the right one should stay hidden" is always possible (tests/prop_brightness.gd).
#
# Kept in the player's own settings file (SAVE_PATH, as client/announcer.gd keeps user://hints.cfg). Automated
# runs (`auto=1`) set persist = false: they never read or write it and always play at the default.
extends RefCounted

const SAVE_PATH := "user://settings.cfg"
const STEPS := 20
const DEFAULT := 10
## At the top of the range: black lifted by this much, and the gamma 1 / GAMMA_SPAN. At the bottom: black
## pressed down by LIFT_LOW, the gamma GAMMA_SPAN.
const LIFT_HIGH := 0.03
const LIFT_LOW := 0.02
const GAMMA_SPAN := 1.3

## The game's black on screen: the tape's lifted black in the dark at the picture's centre (tape.gdshader:
## 0.04 + 0.025 in the dark, a little more in green and blue).
const BLACK := 0.065
## The card's three badges and the line between them (final-picture greys, 0..1).
const RIGHT := 0.072
const THRESHOLD := 0.09
const LEFT := 0.105
const MIDDLE := 0.42

var level := DEFAULT
## False under automation: never read or write the file, always the default.
var persist := true
## True once the player has chosen (the file holds a value): the card is not shown again at the start.
var saved := false
var save_path := SAVE_PATH

## A level kept in range.
static func clamp_level(v: int) -> int:
	return clampi(v, 0, STEPS)

## -1 at the bottom of the range, 0 at the default, 1 at the top.
static func t_of(lv: int) -> float:
	return float(lv - DEFAULT) / float(DEFAULT)

## The shader's two numbers for a level: {"lift": black level change, "gamma": the power}.
static func params(lv: int) -> Dictionary:
	var t := t_of(lv)
	var lift := (LIFT_HIGH * t) if t >= 0.0 else (LIFT_LOW * t)
	return {"lift": lift, "gamma": pow(GAMMA_SPAN, -t)}

## One grey (0..1) through the change at a level: the same sum as tape.gdshader's last step.
static func apply(x: float, lv: int) -> float:
	var p := params(lv)
	var lift: float = p["lift"]
	return clampf(lift + (1.0 - lift) * pow(clampf(x, 0.0, 1.0), float(p["gamma"])), 0.0, 1.0)

static func apply_color(c: Color, lv: int) -> Color:
	return Color(apply(c.r, lv), apply(c.g, lv), apply(c.b, lv), c.a)

func set_level(v: int) -> void:
	level = clamp_level(v)

func load_saved() -> void:
	level = DEFAULT
	saved = false
	if not persist:
		return
	var cf := ConfigFile.new()
	if cf.load(save_path) != OK or not cf.has_section_key("picture", "brightness"):
		return
	level = clamp_level(int(cf.get_value("picture", "brightness", DEFAULT)))
	saved = true

func save() -> void:
	if not persist:
		return
	var cf := ConfigFile.new()
	cf.load(save_path)   # keep anything else the file holds
	cf.set_value("picture", "brightness", level)
	if cf.save(save_path) == OK:
		saved = true
