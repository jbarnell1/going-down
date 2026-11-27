# HU2: the Esc menu's SETTINGS as tabs, the way players expect a settings screen to read (the owner, 21 Nov: "make it
# more like what other games do so that we don't confuse players"; .local/reviews/esc-menu-design.md). Five tabs:
#   GAME        HINTS ON/OFF, CAUGHT SCENES FULL/SOFT
#   SOUND       MASTER, MUSIC, EFFECTS (per cent), ANNOUNCER VOICE
#   MICROPHONE  MICROPHONE ON/OFF, HEADPHONES/SPEAKERS, SENSITIVITY (with the live level), CALIBRATE
#   PICTURE     BRIGHTNESS (a step of the card's), TEST PICTURE (the brightness card), TAPE LOOK ON/OFF (the T key)
#   CONTROLS    the key list, read-only (client/hud.gd menu_rows)
# Every row changes the same setting its old home did, through the same code, saved the same way: the sound levels
# (client/volume.gd), the caught scenes (client/caught_pref.gd), the voice (client/voice_pref.gd), the microphone
# (client/mic.gd and its meter, as client/settings_panel.gd mic_nudge does), the brightness (client/brightness.gd, applied
# through the game as the card's `changed` is), the hints and the tape look through the game's own calls. Nothing here
# is a rule; no row names a resident's rule. The page itself (keys, mouse, drawing) is client/esc_menu.gd's.
extends RefCounted

const Volume = preload("res://client/volume.gd")
const Brightness = preload("res://client/brightness.gd")

const TABS: Array[String] = ["game", "sound", "mic", "picture", "controls"]
const TAB_NAMES := {"game": "GAME", "sound": "SOUND", "mic": "MICROPHONE", "picture": "PICTURE", "controls": "CONTROLS"}

## The settings' owners, set by the game (client/main.gd); a null owner has no rows.
var volume: Object = null
var caught_pref: Object = null
var voice_pref: Object = null
var mic: Object = null
var brightness: Object = null
## The game's own calls: hints on or off (and their state), the tape look on or off (and its state), the brightness
## applied to the picture (its level).
var hints_get := Callable()
var hints_set := Callable()
var tape_get := Callable()
var tape_set := Callable()
var bright_apply := Callable()
## The key list for CONTROLS: [[key, what], ...].
var key_rows: Array = []

## The rows of tab `tab`: [{id, label, value, kind ("pct", "toggle", "choice", "level", "action", "key", "back"),
## frac (0..1 for a bar, -1 none), meter (the microphone's live level 0..15, -1 none)}]. BACK is always last.
func rows(tab: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	match tab:
		"game":
			if hints_get.is_valid():
				out.append(_row("hints", "HINTS", "ON" if bool(hints_get.call()) else "OFF", "toggle"))
			if caught_pref != null:
				out.append(_row("caught", "CAUGHT SCENES", "SOFT" if bool(caught_pref.get(&"soft")) else "FULL", "toggle"))
		"sound":
			if volume != null:
				for r: Array in Volume.ROWS:
					var pct: int = volume.call(&"get_pct", str(r[0]))
					out.append(_row(str(r[0]), str(r[1]), "%d" % pct, "pct", pct / 100.0))
			if voice_pref != null:
				out.append(_row("voice", "ANNOUNCER VOICE", str(voice_pref.call(&"text")), "choice"))
		"mic":
			if mic != null:
				var m: Object = mic.get(&"meter")
				out.append(_row("mic_on", "MICROPHONE", "ON" if bool(m.get(&"enabled")) else "OFF", "toggle"))
				out.append(_row("mic_out", "YOU HEAR THE GAME ON", "SPEAKERS" if bool(m.get(&"speakers")) else "HEADPHONES", "toggle"))
				var sens := int(m.get(&"sensitivity"))
				var row := _row("mic_sens", "SENSITIVITY", "%d" % sens, "pct", sens / 100.0)
				row["meter"] = int(mic.call(&"level")) if bool(mic.call(&"listening")) else -1
				out.append(row)
				out.append(_row("mic_calib", "CALIBRATE", "", "action"))
		"picture":
			if brightness != null:
				var lv := int(brightness.get(&"level"))
				out.append(_row("brightness", "BRIGHTNESS", "%d" % lv, "level", float(lv) / float(Brightness.STEPS)))
				out.append(_row("bright_card", "TEST PICTURE", "", "action"))
			if tape_get.is_valid():
				out.append(_row("tape", "TAPE LOOK", "ON" if bool(tape_get.call()) else "OFF", "toggle"))
		"controls":
			for k: Array in key_rows:
				out.append(_row("key", str(k[0]), str(k[1]), "key"))
	out.append(_row("back", "BACK", "", "back"))
	return out

static func _row(id: String, label: String, value: String, kind: String, frac := -1.0) -> Dictionary:
	return {"id": id, "label": label, "value": value, "kind": kind, "frac": frac, "meter": -1}

## Row `id` one step `dir` (-1 or +1; `n` steps at once for the sliders). True when the setting changed. A toggle's
## right is its second word (ON, SOFT, SPEAKERS) and left its first, as the sound page's [FULL] / [SOFT] were.
func nudge(id: String, dir: int, n := 1) -> bool:
	match id:
		"hints":
			var was := bool(hints_get.call())
			var want := dir > 0 if dir != 0 else not was
			if want == was:
				return false
			hints_set.call(want)
			return true
		"caught":
			var was := bool(caught_pref.get(&"soft"))
			var want := dir > 0 if dir != 0 else not was
			if want == was:
				return false
			caught_pref.call(&"set_soft", want)
			caught_pref.call(&"save")
			return true
		"master", "music", "effects":
			var was: int = volume.call(&"get_pct", id)
			volume.call(&"set_pct", id, was + dir * n * Volume.STEP)
			volume.call(&"apply")
			volume.call(&"save")
			return int(volume.call(&"get_pct", id)) != was
		"voice":
			var changed: bool = voice_pref.call(&"step", 1 if dir >= 0 else -1)
			voice_pref.call(&"save")
			return changed
		"mic_on":
			var m: Object = mic.get(&"meter")
			var was := bool(m.get(&"enabled"))
			var want := dir > 0 if dir != 0 else not was
			if want == was:
				return false
			mic.call(&"set_enabled", want)
			return true
		"mic_out":
			var m: Object = mic.get(&"meter")
			var was := bool(m.get(&"speakers"))
			var want := dir > 0 if dir != 0 else not was
			if want == was:
				return false
			m.set(&"speakers", want)
			m.call(&"save")
			return true
		"mic_sens":
			var m: Object = mic.get(&"meter")
			var was := int(m.get(&"sensitivity"))
			m.call(&"set_sensitivity", was + dir * n * 5)
			m.call(&"save")
			return int(m.get(&"sensitivity")) != was
		"brightness":
			var was := int(brightness.get(&"level"))
			brightness.call(&"set_level", was + dir * n)
			if int(brightness.get(&"level")) == was:
				return false
			if bright_apply.is_valid():
				bright_apply.call(int(brightness.get(&"level")))
			brightness.call(&"save")
			return true
		"tape":
			var was := bool(tape_get.call())
			var want := dir > 0 if dir != 0 else not was
			if want == was:
				return false
			tape_set.call(want)
			return true
	return false

## Backspace on row `id`: back to the game's default (as the sound page's Backspace). True when it changed.
func reset(id: String) -> bool:
	match id:
		"master", "music", "effects":
			var was: int = volume.call(&"get_pct", id)
			volume.call(&"set_pct", id, Volume.DEFAULT)
			volume.call(&"apply")
			volume.call(&"save")
			return was != Volume.DEFAULT
		"caught":
			return nudge(id, -1)
		"voice":
			var changed: bool = voice_pref.call(&"choose", str(voice_pref.call(&"default_voice")))
			voice_pref.call(&"save")
			return changed
		"mic_sens":
			var m: Object = mic.get(&"meter")
			var was := int(m.get(&"sensitivity"))
			m.call(&"set_sensitivity", 50)
			m.call(&"save")
			return was != 50
		"brightness":
			return _bright_to(Brightness.DEFAULT)
	return false

func _bright_to(lv: int) -> bool:
	var was := int(brightness.get(&"level"))
	return nudge("brightness", 1 if lv > was else -1, absi(lv - was)) if lv != was else false

## Enter or a click on row `id`: a toggle or a choice moves on; an action is the game's to do ("bright_card",
## "mic_calib", "back"). Returns the game's action, or "" when the row did it itself.
func activate(id: String) -> String:
	match id:
		"bright_card", "mic_calib", "back":
			return id
		"hints", "caught", "mic_on", "mic_out", "tape":
			nudge(id, 0)
		"voice":
			nudge(id, 1)
	return ""
