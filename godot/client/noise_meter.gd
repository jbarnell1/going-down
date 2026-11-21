# VC1: the HUD's noise meter's state, pure (client/mic_hud.gd draws it). Its input is "a noise level 0 to 15 from a
# named source": today only &"voice" (client/mic.gd), later the player's own footsteps, running and opening noises too.
# The meter shows the loudest source's level this frame. The owner, 21 Nov: "have it green when it's whisper, get into
# the yellow for talk, and then get into red when you're shouting", and "the brief flash of the meter": each time the
# shown level crosses UP into a higher band the whole meter flashes for FLASH_MS in the new band's colour (never on the
# way down). Colour is never the only cue: the bar's length and the whisper and talk marks stay.
extends RefCounted

const WHISPER_AT := 1
const TALK_AT := 5
const SHOUT_AT := 11
const MAX := 15
const FLASH_MS := 150
## Muted for the HUD's palette, still plainly green, yellow and red through the tape filter.
const GREEN := Color(0.45, 0.85, 0.42)
const YELLOW := Color(0.95, 0.83, 0.3)
const RED := Color(0.95, 0.33, 0.27)
const OFF := Color(0.55, 0.56, 0.52)

## source -> its newest level.
var levels := {}
var level := 0
var flash_until := -1
var flash_band: StringName = &"silent"

## &"silent", &"whisper", &"talk" or &"shout".
static func band_of(lv: int) -> StringName:
	if lv >= SHOUT_AT:
		return &"shout"
	if lv >= TALK_AT:
		return &"talk"
	if lv >= WHISPER_AT:
		return &"whisper"
	return &"silent"

static func band_rank(b: StringName) -> int:
	return [&"silent", &"whisper", &"talk", &"shout"].find(b)

static func color_of(lv: int) -> Color:
	match band_of(lv):
		&"shout":
			return RED
		&"talk":
			return YELLOW
		&"whisper":
			return GREEN
	return OFF

## One source's level now (`now_ms`: the clock). The shown level is the loudest source's.
func feed(source: StringName, lv: int, now_ms: int) -> void:
	levels[source] = clampi(lv, 0, MAX)
	var was := level
	level = 0
	for s: StringName in levels:
		level = maxi(level, int(levels[s]))
	if band_rank(band_of(level)) > band_rank(band_of(was)):
		flash_until = now_ms + FLASH_MS
		flash_band = band_of(level)

func flashing(now_ms: int) -> bool:
	return now_ms < flash_until

func flash_color() -> Color:
	return color_of(SHOUT_AT if flash_band == &"shout" else (TALK_AT if flash_band == &"talk" else WHISPER_AT))
