# ES1a: the player's own ANNOUNCER VOICE (the owner, 21 Nov: "Can we make the male voice default as well? And where
# do I switch the voice? It should be in every player's escape settings screen."). The voices are the voice
# manifest's (res://assets/voice/manifest.json "voices", written from assets_src/voice/lines.json voices.ship); the
# only name here is the default for a player who has never chosen, Brian. A player who chose keeps the choice.
# Per player, never a host setting: nothing here is sent anywhere, and no rule reads it.
#
# Kept in the player's own settings file (user://settings.cfg, section "sound", key "announcer_voice", beside the
# sound sliders of client/volume.gd). Automated runs (`auto=1`) set persist = false: never read or written, always
# the default. The announcer (`target`, client/announcer.gd) takes the voice at once: the next line it starts is read
# in it; a line that voice has no recording of is read in another voice that has one (client/announcer.gd voice_path).
extends RefCounted

const SAVE_PATH := "user://settings.cfg"
const SECTION := "sound"
const KEY := "announcer_voice"
const MANIFEST := "res://assets/voice/manifest.json"
## A player who has never chosen hears Brian (the owner, 21 Nov).
const DEFAULT := "brian"
## The panel's row (client/settings_panel.gd).
const NAME := "ANNOUNCER VOICE"

## [{id, name}] in the manifest's order.
var voices: Array = []
var voice := DEFAULT
var persist := true
var save_path := SAVE_PATH
## The announcer (or anything with a `voice` property), told on every change; null for none.
var target: Object = null

func _init(manifest: Variant = null) -> void:
	if manifest == null:
		manifest = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST)) if FileAccess.file_exists(MANIFEST) else {}
	if manifest is Dictionary:
		for v: Variant in (manifest as Dictionary).get("voices", []):
			if v is Dictionary and str(v.get("id", "")) != "":
				voices.append({"id": str(v["id"]), "name": str(v.get("name", v["id"]))})
	voice = default_voice()

func ids() -> Array:
	return voices.map(func(v: Dictionary) -> String: return str(v["id"]))

## Brian when the manifest has him, else the manifest's first voice.
func default_voice() -> String:
	var all := ids()
	if all.has(DEFAULT) or all.is_empty():
		return DEFAULT
	return str(all[0])

## The chosen voice's name as shown ("BRIAN").
func text() -> String:
	for v: Dictionary in voices:
		if str(v["id"]) == voice:
			return str(v["name"]).to_upper()
	return voice.to_upper()

## Choose voice `id` (one of the manifest's). True when it changed. Tells the target at once.
func choose(id: String) -> bool:
	if not ids().has(id):
		return false
	var was := voice
	voice = id
	_tell()
	return was != voice

## The next (dir +1) or previous (-1) voice in the manifest's order, wrapping. True when it changed.
func step(dir: int) -> bool:
	var all := ids()
	if all.size() < 2:
		return false
	var i := maxi(0, all.find(voice))
	return choose(str(all[(i + dir + all.size()) % all.size()]))

func _tell() -> void:
	if target != null:
		target.set(&"voice", voice)

func load_saved() -> void:
	voice = default_voice()
	if persist:
		var cf := ConfigFile.new()
		if cf.load(save_path) == OK:
			var saved := str(cf.get_value(SECTION, KEY, ""))
			if ids().has(saved):
				voice = saved
	_tell()

func save() -> void:
	if not persist:
		return
	var cf := ConfigFile.new()
	cf.load(save_path)   # keep anything else the file holds (the sound, the brightness, the microphone)
	cf.set_value(SECTION, KEY, voice)
	cf.save(save_path)

func to_dict() -> Dictionary:
	return {"announcerVoice": voice}
