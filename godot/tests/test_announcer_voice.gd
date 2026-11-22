# ES1a: the player's own ANNOUNCER VOICE (client/voice_pref.gd; the settings panel's YOUR SOUND page, the Esc menu's V).
# The owner, 21 Nov: "Can we make the male voice default as well? And where do I switch the voice? It should be in
# every player's escape settings screen."
#   1. a fresh settings file hears Brian; a saved choice survives a load; persist off never reads or writes it;
#   2. the YOUR SOUND page offers every voice in the manifest, in its order, and left/right, a click and Backspace
#      choose (Backspace: back to Brian), saved at once;
#   3. choosing tells the announcer at once, and the next line's file is in the chosen voice; a line the chosen voice
#      has no recording of (the Bella-only tape, the Ward's lift lines) is read in a voice that has one;
#   4. Brian's recordings are in the game for every line the manifest gives him.
extends RefCounted

const T = preload("res://tests/t.gd")
const VoicePref = preload("res://client/voice_pref.gd")
const SettingsPanelScript = preload("res://client/settings_panel.gd")
const AnnouncerScript = preload("res://client/announcer.gd")

const TEST_PATH := "user://test_announcer_voice.cfg"

static func _manifest() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string("res://assets/voice/manifest.json"))

static func _clean() -> void:
	if FileAccess.file_exists(TEST_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))

static func _fresh() -> Object:
	var v := VoicePref.new()
	v.save_path = TEST_PATH
	return v

func test_a_fresh_file_hears_brian_and_a_choice_is_kept(t: T) -> void:
	_clean()
	var v := _fresh()
	v.load_saved()
	t.eq(v.voice, "brian", "a player who never chose hears Brian")
	t.eq(v.text(), "BRIAN", "shown as BRIAN")
	t.check(v.choose("bella"), "choosing Bella changes it")
	v.save()
	var w := _fresh()
	w.load_saved()
	t.eq(w.voice, "bella", "a saved choice survives a load")
	# The file keeps what else it holds.
	var cf := ConfigFile.new()
	cf.load(TEST_PATH)
	cf.set_value("sound", "master", 40)
	cf.save(TEST_PATH)
	w.choose("brian")
	w.save()
	cf = ConfigFile.new()
	cf.load(TEST_PATH)
	t.eq(int(cf.get_value("sound", "master", 100)), 40, "saving the voice keeps the sound sliders")
	t.eq(str(cf.get_value("sound", "announcer_voice", "")), "brian", "saved under sound/announcer_voice")
	t.check(not w.choose("nobody"), "a voice not in the manifest is refused")
	t.eq(w.voice, "brian", "and changes nothing")
	var off := _fresh()
	off.persist = false
	w.choose("bella")
	w.save()
	off.load_saved()
	t.eq(off.voice, "brian", "persist off (a test) never reads it: Brian")
	off.choose("brian")
	off.save()
	w.load_saved()
	t.eq(w.voice, "bella", "persist off never writes it")
	_clean()

func test_the_page_offers_every_manifest_voice(t: T) -> void:
	_clean()
	var want: Array = (_manifest()["voices"] as Array).map(func(v: Dictionary) -> String: return str(v["id"]))
	t.check(want.size() >= 2 and want.has("brian") and want.has("bella"), "the manifest ships Bella and Brian (%s)" % str(want))
	var p: Control = SettingsPanelScript.new()
	var v := _fresh()
	v.load_saved()
	p.voice_pref = v
	var vol := preload("res://client/volume.gd").new()
	vol.persist = false
	p.volume = vol
	p.open()
	p.show_sound(true)
	var d: Dictionary = p.describe()
	t.eq(d["sound"]["voices"], want, "the page offers every manifest voice, in its order")
	t.eq(str(d["sound"]["voice"]), "brian", "Brian chosen at first")
	t.eq(p.voice_buttons().map(func(b: Array) -> String: return str(b[0])), want, "one button per manifest voice")
	t.eq(p.voice_buttons().map(func(b: Array) -> String: return str(b[1])), ["BELLA", "BRIAN"], "labelled with the manifest's names")
	var k := InputEventKey.new()
	k.pressed = true
	while p._sound_row != p.voice_row_index():
		k.physical_keycode = KEY_DOWN
		p.key(k)
		if p._sound_row >= p._sound_rows_n() - 1:
			break
	t.eq(p._sound_row, p.voice_row_index(), "down reaches the ANNOUNCER VOICE row")
	k.physical_keycode = KEY_RIGHT
	p.key(k)
	t.check(str(v.voice) != "brian", "right: the next voice (%s)" % v.voice)
	var saved := _fresh()
	saved.load_saved()
	t.eq(saved.voice, v.voice, "saved at once")
	k.physical_keycode = KEY_BACKSPACE
	p.key(k)
	t.eq(str(v.voice), "brian", "Backspace: back to Brian")
	# A click on a voice's button (the hit the drawing records for it).
	p._hits = [[Rect2(Vector2(10, 10), Vector2(40, 10)), "voice_pick", "bella"]]
	t.check(p.click(Vector2(20, 15)), "the click hits the button")
	t.eq(str(v.voice), "bella", "a click on BELLA chooses her")
	t.eq(p._sound_row, p.voice_row_index(), "and selects the row")
	p.free()
	_clean()

func test_choosing_changes_the_announcers_voice(t: T) -> void:
	var a: Node = AnnouncerScript.new()
	a.use_manifest(_manifest())
	t.eq(str(a.voice), "brian", "a new announcer reads in Brian")
	var v := VoicePref.new()
	v.persist = false
	v.target = a
	v.load_saved()
	t.eq(str(a.voice), "brian", "a fresh player: the announcer is Brian")
	t.eq(a.voice_path("arrived_1"), "res://assets/voice/brian/arrived_1.mp3", "a line in Brian's folder")
	v.choose("bella")
	t.eq(str(a.voice), "bella", "choosing Bella tells the announcer at once")
	t.eq(a.voice_path("arrived_1"), "res://assets/voice/bella/arrived_1.mp3", "the next line is Bella's")
	v.choose("brian")
	t.eq(a.voice_path("tape_orient_a"), "res://assets/voice/bella/tape_orient_a.mp3", "the Bella-only tape falls back to Bella")
	t.eq(a.voice_path("ward_station", "res://assets/ward/voice"), "res://assets/ward/voice/bella/ward_station.mp3", "a Ward line Brian lacks falls back to Bella")
	t.eq(a.voice_path("no_such_line"), "res://assets/voice/brian/no_such_line.mp3", "a line nobody recorded: the chosen voice's path (a caption only)")
	a.free()

func test_brians_recordings_are_in_the_game(t: T) -> void:
	var m := _manifest()
	var missing: Array = []
	var n := 0
	for l: Dictionary in m["lines"]:
		var vs: Array = l.get("voices", ["bella", "brian"])
		if not vs.has("brian"):
			continue
		n += 1
		if not ResourceLoader.exists("res://assets/voice/brian/%s.mp3" % str(l["id"])):
			missing.append(str(l["id"]))
	t.check(n > 150, "the manifest gives Brian %d lines" % n)
	t.eq(missing, [], "every one of them is in the game")
