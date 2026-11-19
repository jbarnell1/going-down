# The player's brightness (owner, 18 Nov: "We probably need a dimness setting to set relative contrast levels
# at the start of the game or in settings"). Per player, never a host setting: it changes only this screen's
# final picture, as the tape filter's last step (client/tape.gdshader bright_lift, bright_gamma), so it
# composes with everything drawn before it (the floors, the residents, any light in the dark). No rule reads
# it and nothing about it is sent to the host (tests/prop_brightness_curve.gd).
#
# One number, 0..STEPS, DEFAULT in the middle. The default is the game as built (no change at all).
#   Above the default (unchanged since the first card): black lifted by up to LIFT_HIGH, gamma down to
#   1 / GAMMA_HIGH. At the top a blackout is still dark (tools/playthrough.mjs measures it).
#   Below the default (T27a): a black point. Every grey under it shows as pure black and the rest is
#   stretched back to white, (x - b) / (1 - b). b falls in even steps from GAME_BLACK at the bottom to 0 at
#   the default. The shader needs no change for it: the same sum with a negative lift, -b / (1 - b), then
#   the clamp it already has.
# Why a black point and not a gamma (owner, 18 Nov: "You can see brightness on both extremes. (badge on
# left)"): any curve that keeps two greys apart keeps the left badge apart from the black, so the old bottom
# (a gamma and a lift of -0.005) left the left badge 8 levels out of 255 above the black on the owner's
# screen. Only a black point can make two greys the same. tools/brightness_table.gd prints the numbers.
#
# The calibration card (client/brightness_card.gd) draws three badges on true black (BLACK). LEFT is the
# game's own black in the dark (the tape's lifted black, GAME_BLACK): a player who can just tell it from
# true black sees everything the game draws. RIGHT is darker than anything the game draws. At the bottom
# both are pure black; one step up the left badge is 2 levels over the black and the right one is still
# black; at the default the left one is about 17 levels over and the right about 5.
#
# Kept in the player's own settings file (SAVE_PATH, as client/announcer.gd keeps user://hints.cfg) with the
# curve it was chosen on (CURVE). A value saved on the first card (no curve in the file) keeps its number,
# but the card is shown once more at the next start, opened at that number: that card could not be set
# right, so the choice is asked again. Automated runs (`auto=1`) set persist = false: they never read or
# write it and always play at the default.
extends RefCounted

const SAVE_PATH := "user://settings.cfg"
const STEPS := 20
const DEFAULT := 10
## The curve a saved value was chosen on. 1 (or no key) is the first card; 2 is the black point below.
const CURVE := 2
## At the top of the range: black lifted by LIFT_HIGH, the gamma 1 / GAMMA_HIGH. Measured on a Clinic
## blackout frame (tools/playthrough.mjs, the picture without the display): the top about 2.2 times the
## default's mean.
const LIFT_HIGH := 0.028
const GAMMA_HIGH := 1.3

## The game's black in the dark at the picture's centre (tape.gdshader: 0.04 + 0.025 in red, a little more
## in green and blue). The bottom of the range puts the black point here.
const GAME_BLACK := 0.065
const BLACK_POINT_LOW := GAME_BLACK

## The card's greys (final-picture greys, 0..1): its background, and the three badges.
const BLACK := 0.0
const RIGHT := 0.02
const LEFT := GAME_BLACK
const MIDDLE := 0.42

var level := DEFAULT
## False under automation: never read or write the file, always the default.
var persist := true
## True once the player has chosen on this card (the file holds a value with CURVE): the card is not shown
## again at the start.
var saved := false
var save_path := SAVE_PATH

## A level kept in range.
static func clamp_level(v: int) -> int:
	return clampi(v, 0, STEPS)

## -1 at the bottom of the range, 0 at the default, 1 at the top.
static func t_of(lv: int) -> float:
	return float(lv - DEFAULT) / float(DEFAULT)

## The black point at a level: GAME_BLACK at the bottom, 0 from the default up.
static func black_point(lv: int) -> float:
	return BLACK_POINT_LOW * maxf(0.0, -t_of(lv))

## The shader's two numbers for a level: {"lift": black level change, "gamma": the power}. Below the default
## the lift is negative: lift + (1 - lift) * x is then (x - b) / (1 - b), and the clamp after it makes every
## grey under b pure black.
static func params(lv: int) -> Dictionary:
	var t := t_of(lv)
	if t >= 0.0:
		return {"lift": LIFT_HIGH * t, "gamma": pow(GAMMA_HIGH, -t)}
	var b := black_point(lv)
	return {"lift": -b / (1.0 - b), "gamma": 1.0}

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
	# A value from the first card keeps its number, but the card is due again.
	saved = int(cf.get_value("picture", "brightness_curve", 1)) >= CURVE

func save() -> void:
	if not persist:
		return
	var cf := ConfigFile.new()
	cf.load(save_path)   # keep anything else the file holds
	cf.set_value("picture", "brightness", level)
	cf.set_value("picture", "brightness_curve", CURVE)
	if cf.save(save_path) == OK:
		saved = true
