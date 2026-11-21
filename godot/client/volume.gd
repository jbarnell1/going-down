# The player's own sound levels (owner, 20 Nov: "make the music and SFX settings with a master slider that can be
# adjusted. That shouldn't just be the host, that should be everyone."). Three sliders, 0 to 100 %: MASTER (the
# Master bus, everything), MUSIC (the Music bus, client/music.gd) and EFFECTS (the EffectsGroup bus every other
# sound reaches Master through: the voice, the residents, the scares, the effects, the room tones, the HUD's).
# Per player, never a host setting: nothing here is sent anywhere, and no rule reads it.
#
# 100 % is the game as built (0 dB); 0 % is silent (-80 dB, and the group's own bus muted). Between, the
# slider is squared before it becomes a gain, so its middle sounds like the middle (50 % is -12 dB).
#
# Kept in the player's own settings file (user://settings.cfg, section "sound", as client/brightness.gd keeps the
# brightness beside it). Automated runs (`auto=1`) set persist = false: they never read or write it and always
# play at 100 %, so every mix measurement hears the game as built.
extends RefCounted

const Music = preload("res://client/music.gd")

const SAVE_PATH := "user://settings.cfg"
const SECTION := "sound"
## The three sliders, in the panel's order: [key, the words on the panel].
const ROWS: Array = [["master", "MASTER"], ["music", "MUSIC"], ["effects", "EFFECTS"]]
const DEFAULT := 100
const STEP := 5
const SILENT_DB := -80.0

var master := DEFAULT
var music := DEFAULT
var effects := DEFAULT
## False under automation: never read or write the file, always 100 %.
var persist := true
var save_path := SAVE_PATH

## The gain (dB) of a slider at `pct` %: 0 dB at 100, SILENT_DB at 0.
static func db_of(pct: int) -> float:
	var p := clampi(pct, 0, 100)
	if p == 0:
		return SILENT_DB
	return maxf(SILENT_DB, linear_to_db(pow(p / 100.0, 2.0)))

func get_pct(key: String) -> int:
	match key:
		"master":
			return master
		"music":
			return music
		"effects":
			return effects
	return DEFAULT

func set_pct(key: String, pct: int) -> void:
	var p := clampi(pct, 0, 100)
	match key:
		"master":
			master = p
		"music":
			music = p
		"effects":
			effects = p

## The bus each slider drives.
static func bus_of(key: String) -> String:
	match key:
		"music":
			return Music.BUS
		"effects":
			return Music.EFFECTS_BUS
	return "Master"

## Sets the three buses (creating Music and EffectsGroup first if this is the first call).
func apply() -> void:
	Music.ensure_buses()
	for r: Array in ROWS:
		var key := str(r[0])
		var i := AudioServer.get_bus_index(bus_of(key))
		if i < 0:
			continue
		AudioServer.set_bus_volume_db(i, db_of(get_pct(key)))
		# Master's mute belongs to the `mute=1` option (client/main.gd _audio_options): only the groups' own buses
		# are muted at 0 %.
		if key != "master":
			AudioServer.set_bus_mute(i, get_pct(key) == 0)

func load_saved() -> void:
	master = DEFAULT
	music = DEFAULT
	effects = DEFAULT
	if not persist:
		return
	var cf := ConfigFile.new()
	if cf.load(save_path) != OK:
		return
	for r: Array in ROWS:
		var key := str(r[0])
		set_pct(key, int(cf.get_value(SECTION, key, DEFAULT)))

func save() -> void:
	if not persist:
		return
	var cf := ConfigFile.new()
	cf.load(save_path)   # keep anything else the file holds (the brightness)
	for r: Array in ROWS:
		var key := str(r[0])
		cf.set_value(SECTION, key, get_pct(key))
	cf.save(save_path)

func to_dict() -> Dictionary:
	return {"master": master, "music": music, "effects": effects}
