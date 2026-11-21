# CS1: the player's own CAUGHT SCENES setting, FULL or SOFT (client/caught_scene.gd). SOFT keeps each resident's
# caught scene but without the camera snap or shove, with the flash and the picture noise halved. FULL is the default.
# Per player, never a host setting: nothing here is sent anywhere, and no rule reads it.
#
# Kept in the player's own settings file (user://settings.cfg, section "screen", beside the sound sliders of
# client/volume.gd and the brightness). Automated runs (`auto=1`) set persist = false: never read or written, always FULL.
extends RefCounted

const SAVE_PATH := "user://settings.cfg"
const SECTION := "screen"
const KEY := "caught_scenes"
## The panel's row (client/settings_panel.gd, on the YOUR SOUND page).
const NAME := "CAUGHT SCENES"

var soft := false
var persist := true
var save_path := SAVE_PATH

func text() -> String:
	return "SOFT" if soft else "FULL"

func set_soft(on: bool) -> void:
	soft = on

func load_saved() -> void:
	soft = false
	if not persist:
		return
	var cf := ConfigFile.new()
	if cf.load(save_path) != OK:
		return
	soft = str(cf.get_value(SECTION, KEY, "full")) == "soft"

func save() -> void:
	if not persist:
		return
	var cf := ConfigFile.new()
	cf.load(save_path)   # keep anything else the file holds (the sound, the brightness)
	cf.set_value(SECTION, KEY, "soft" if soft else "full")
	cf.save(save_path)

func to_dict() -> Dictionary:
	return {"caughtScenes": text()}
