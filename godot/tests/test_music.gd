# MU1: the soundtrack (client/music.gd) and the player's own sound sliders (client/volume.gd, the settings panel's
# YOUR SOUND page). The owner, 20 Nov: the main theme on the start screen, the muzak riding the lift, the wistful one
# in the prison, the drone as a bed on a floor, the stamp once for the end-of-run report; "a master slider that can
# be adjusted. That shouldn't just be the host, that should be everyone."
#   1. which track each place plays, and the report's stamp: once a day, carried into the prison, stopped by a ride
#      down, again on a new run;
#   2. a change of track is a cross-fade of FADE seconds and two tracks are never both at full;
#   3. the music ducks DUCK_DB while the announcer speaks (a fake announcer, as tests/test_intercom.gd runs it);
#   4. a slider maps to its bus (0 % silent, 100 % 0 dB), survives a save and a load, and is never read or written
#      with persist off; the panel's page is live for a player who is not the host and sends nothing;
#   5. the music sits under everything else: every track's gain is under 0 dB and the floor's bed is the quietest
#      loop.
extends RefCounted

const T = preload("res://tests/t.gd")
const Music = preload("res://client/music.gd")
const Volume = preload("res://client/volume.gd")
const SettingsPanelScript = preload("res://client/settings_panel.gd")
const AnnouncerScript = preload("res://client/announcer.gd")

func _node() -> Node:
	return (load("res://client/music.gd") as GDScript).new()

## Drives `m` with one state for `seconds` in 0.05 s steps.
static func _run(m: Node, st: String, key: String, ducked: bool, seconds: float) -> void:
	var n := roundi(seconds / 0.05)
	for i in n:
		m.drive(st, key, ducked)
		m.step(0.05)

func test_the_track_for_each_place(t: T) -> void:
	t.eq(Music.state_of(false, "", false, false), "title", "the start screens and the lobby: the title")
	t.eq(Music.state_of(true, "riding", false, false), "lift", "inside the car between floors: the lift")
	t.eq(Music.state_of(true, "riding", true, false), "lift", "riding up out of the prison is still the lift")
	t.eq(Music.state_of(true, "boarding", true, false), "prison", "at home in the prison: the prison")
	for ph: String in ["away", "arriving", "unloading", "coming", "boarding"]:
		t.eq(Music.state_of(true, ph, false, false), "floor", "on a floor (%s): the floor" % ph)
	t.eq(Music.state_of(true, "ended", false, true), "report", "the end screen: the report")
	var files := {"title": "abandoned_jingle", "lift": "elevator_muzak", "prison": "wistful_regret", "floor": "sub_bass_drone", "report": "final_stamp"}
	for st: String in files:
		t.eq(str(Music.TRACKS[st][0]), files[st], "%s plays the owner's %s" % [st, files[st]])
		t.check(ResourceLoader.exists(Music.DIR + files[st] + ".ogg"), "%s.ogg is in the project" % files[st])
	for st: String in ["title", "lift", "prison", "floor"]:
		t.check(bool(Music.TRACKS[st][2]), "%s loops" % st)
		t.eq(Music.track_of(st), st, "%s's own track when no stamp holds" % st)
	t.check(not bool(Music.TRACKS["report"][2]), "the stamp plays once")
	t.eq(Music.track_of("report"), "", "after the stamp, the end screen is quiet")

func test_the_report_key(t: T) -> void:
	var up := {"goingUp": true, "day": {"result": {"day": 3, "kind": "made"}}}
	t.eq(Music.report_key_of(up, false), "day 3", "the settled day riding up")
	t.eq(Music.report_key_of({"goingUp": false, "day": {"result": {"day": 3}}}, false), "", "riding down: no report")
	t.eq(Music.report_key_of({"goingUp": true, "day": {"result": null}}, false), "", "no settled day: no report")
	t.eq(Music.report_key_of({}, true), "end", "the end screen")

func test_the_stamp_once_a_day(t: T) -> void:
	var m := _node()
	_run(m, "floor", "", false, 3.0)
	t.eq(m.track, "floor", "on the floor: the bed")
	_run(m, "lift", "day 1", false, 2.0)
	t.eq(m.track, "report", "the ride up with the day settled: the stamp")
	_run(m, "prison", "", false, 2.0)
	t.eq(m.track, "report", "it carries on into the prison until it ends")
	_run(m, "prison", "day 1", false, 2.0)
	t.eq(m.track, "report", "the same day does not start it again")
	_run(m, "lift", "", false, 0.1)
	t.eq(m.track, "lift", "a ride down stops it: the lift's muzak")
	_run(m, "prison", "day 1", false, 1.0)
	t.eq(m.track, "prison", "the same day's report does not stamp twice")
	_run(m, "lift", "day 2", false, 0.1)
	t.eq(m.track, "report", "the next day's report stamps again")
	_run(m, "floor", "", false, 0.1)
	t.eq(m.track, "floor", "a floor stops it")
	_run(m, "title", "", false, 0.1)
	_run(m, "lift", "day 1", false, 0.1)
	t.eq(m.track, "report", "a new run's day 1 stamps again")
	_run(m, "report", "end", false, 0.5)
	t.eq(m.track, "report", "the end screen's stamp")
	m.free()

func test_a_cross_fade_never_has_two_at_full(t: T) -> void:
	var m := _node()
	_run(m, "title", "", false, Music.FADE + 0.1)
	t.eq(float(m.levels["title"]), 1.0, "the title is at full after FADE")
	var worst := 0.0
	var both_full := false
	var steps := 0
	while float(m.levels["lift"]) < 1.0 and steps < 200:
		m.drive("lift", "", false)
		m.step(0.05)
		steps += 1
		var sum := 0.0
		var full := 0
		for st: String in Music.TRACKS:
			sum += float(m.levels[st])
			full += 1 if float(m.levels[st]) >= 0.999 else 0
		worst = maxf(worst, sum)
		both_full = both_full or full > 1
	t.check(not both_full, "never two tracks at full at once")
	t.check(worst <= 1.0001, "the levels never add up to more than one track (%.3f)" % worst)
	t.check(absf(steps * 0.05 - Music.FADE) < 0.11, "the cross-fade takes FADE seconds (%.2f s)" % (steps * 0.05))
	t.eq(float(m.levels["title"]), 0.0, "the title is gone")
	m.free()

func test_the_music_ducks_while_the_announcer_speaks(t: T) -> void:
	var a: Node = AnnouncerScript.new()
	a.fake = true
	a.persist = false
	a.clock_ms = 0
	a.my_id = "ann"
	var manifest: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://assets/voice/manifest.json"))
	a.use_manifest(manifest if manifest is Dictionary else {})
	a.start_run(true, "night-music")
	a.queue.clear()
	a.clock_ms = 5000
	var m := _node()
	_run(m, "floor", "", Music.duck_wanted(a.speaking(), false, false), 2.0)
	t.eq(float(m.duck_db), 0.0, "nobody speaking: no duck")
	var full_db: float = (m._players["floor"] as AudioStreamPlayer).volume_db
	a.request("doors")
	a.update()
	t.check(a.speaking(), "the announcer speaks")
	_run(m, "floor", "", Music.duck_wanted(a.speaking(), false, false), 1.0)
	t.eq(float(m.duck_db), Music.DUCK_DB, "the music is down DUCK_DB while it speaks")
	t.check(absf((m._players["floor"] as AudioStreamPlayer).volume_db - (full_db + Music.DUCK_DB)) < 0.01, "on the playing track's own volume")
	t.check(Music.DUCK_DB <= -8.0, "by at least 8 dB (%.1f)" % Music.DUCK_DB)
	t.check(Music.duck_wanted(false, true, false), "a catch's scene ducks it")
	t.check(Music.duck_wanted(false, false, true), "the ride-up reel or the cassette ducks it")
	t.check(Music.catch_recent([{"name": "roar", "ms": 1000}], 3000), "a roar 2 s ago is a catch's scene")
	t.check(not Music.catch_recent([{"name": "roar", "ms": 1000}], 1000 + Music.CATCH_MS + 1), "and over after CATCH_MS")
	t.check(not Music.catch_recent([{"name": "step", "ms": 1000}], 1500), "a footstep is not")
	_run(m, "floor", "", false, 1.0)
	t.eq(float(m.duck_db), 0.0, "back up when it stops")
	m.free()
	a.free()

func test_the_music_sits_under_the_effects(t: T) -> void:
	for st: String in Music.TRACKS:
		t.check(float(Music.TRACKS[st][1]) < 0.0, "%s plays under the game's level (%.1f dB)" % [st, float(Music.TRACKS[st][1])])
	for st: String in ["lift", "prison", "title"]:
		t.check(float(Music.TRACKS["floor"][1]) <= float(Music.TRACKS[st][1]), "the floor's bed is no louder than %s" % st)

func test_a_slider_maps_to_its_bus(t: T) -> void:
	t.eq(Volume.db_of(100), 0.0, "100 % is 0 dB")
	t.eq(Volume.db_of(0), Volume.SILENT_DB, "0 % is silent")
	t.check(absf(Volume.db_of(50) - (-12.041)) < 0.01, "50 %% is -12 dB (%.2f)" % Volume.db_of(50))
	t.check(Volume.db_of(5) > Volume.SILENT_DB and Volume.db_of(5) < Volume.db_of(10), "every step up is louder")
	var v := Volume.new()
	v.persist = false
	v.set_pct("music", 50)
	v.set_pct("effects", 0)
	v.set_pct("master", 80)
	v.apply()
	var mi := AudioServer.get_bus_index(Music.BUS)
	var ei := AudioServer.get_bus_index(Music.EFFECTS_BUS)
	t.check(mi > 0 and ei > 0, "the Music and EffectsGroup buses are made")
	t.check(absf(AudioServer.get_bus_volume_db(mi) - Volume.db_of(50)) < 0.01, "MUSIC 50 %% sets the Music bus (%.2f)" % AudioServer.get_bus_volume_db(mi))
	t.check(AudioServer.is_bus_mute(ei) and AudioServer.get_bus_volume_db(ei) <= Volume.SILENT_DB, "EFFECTS 0 % mutes the effects")
	t.check(absf(AudioServer.get_bus_volume_db(0) - Volume.db_of(80)) < 0.01, "MASTER 80 % sets Master")
	t.eq(StringName(AudioServer.get_bus_send(mi)), &"Master", "Music goes straight to Master")
	for b: String in ["Voice", "Entity", "Scare", "Effects", "Ambience", "UI"]:
		var i := AudioServer.get_bus_index(b)
		if i >= 0:
			t.eq(StringName(AudioServer.get_bus_send(i)), StringName(Music.EFFECTS_BUS), "%s goes through the EFFECTS slider" % b)
	var count := AudioServer.bus_count
	Music.ensure_buses()
	t.eq(AudioServer.bus_count, count, "a second call makes no more buses")
	# Back to the game as built for the tests after this one.
	v.set_pct("music", 100)
	v.set_pct("effects", 100)
	v.set_pct("master", 100)
	v.apply()
	t.check(not AudioServer.is_bus_mute(ei) and AudioServer.get_bus_volume_db(ei) == 0.0 and AudioServer.get_bus_volume_db(0) == 0.0, "100 % puts every bus back to 0 dB")

func test_the_sliders_survive_a_save_and_a_load(t: T) -> void:
	var path := "user://test_volume_mu1.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var cf := ConfigFile.new()
	cf.set_value("picture", "brightness", 7)
	cf.save(path)
	var v := Volume.new()
	v.save_path = path
	v.set_pct("master", 35)
	v.set_pct("music", 0)
	v.set_pct("effects", 90)
	v.save()
	var w := Volume.new()
	w.save_path = path
	w.load_saved()
	t.eq(w.to_dict(), {"master": 35, "music": 0, "effects": 90}, "a load gives back what was saved")
	var back := ConfigFile.new()
	back.load(path)
	t.eq(int(back.get_value("picture", "brightness", -1)), 7, "the brightness beside it is kept")
	var off := Volume.new()
	off.save_path = path
	off.persist = false
	off.load_saved()
	t.eq(off.to_dict(), {"master": 100, "music": 100, "effects": 100}, "persist off (a test) never reads it: 100 %")
	off.set_pct("master", 5)
	off.save()
	w.load_saved()
	t.eq(w.master, 35, "persist off never writes it")
	w.set_pct("music", 250)
	t.eq(w.music, 100, "a slider stays in 0..100")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func test_the_panel_page_is_every_players(t: T) -> void:
	var p: Control = SettingsPanelScript.new()
	var v := Volume.new()
	v.persist = false
	p.volume = v
	p.open()
	t.check(not p.is_host(), "no room: this player is not the host")
	var k := InputEventKey.new()
	k.pressed = true
	k.physical_keycode = KEY_S
	p.key(k)
	t.check(p.is_sound(), "S opens YOUR SOUND")
	var d: Dictionary = p.describe()
	t.eq((d["sound"]["rows"] as Array).map(func(r: Dictionary) -> String: return str(r["name"])), ["MASTER", "MUSIC", "EFFECTS"], "three sliders")
	k.physical_keycode = KEY_DOWN
	p.key(k)
	k.physical_keycode = KEY_LEFT
	p.key(k)
	t.eq(v.music, 100 - Volume.STEP, "down then left: MUSIC one step down, for a player who is not the host")
	k.shift_pressed = true
	p.key(k)
	t.eq(v.music, 100 - 6 * Volume.STEP, "Shift: five steps")
	k.shift_pressed = false
	k.physical_keycode = KEY_BACKSPACE
	p.key(k)
	t.eq(v.music, 100, "Backspace: back to 100 %")
	t.check(p.sound_set(2, 0) and v.effects == 0, "EFFECTS to 0")
	t.eq(str((p.describe()["sound"]["rows"] as Array)[2]["text"]), "OFF", "0 % reads OFF")
	p.sound_set(2, 100)
	t.check(p.foot_line().contains("S: BACK"), "the foot says how to go back")
	k.physical_keycode = KEY_S
	p.key(k)
	t.check(not p.is_sound(), "S again goes back to the host's settings")
	t.check(p.foot_line().contains("S: YOUR SOUND"), "a guest's foot names the sound page")
	t.check(p.rc == null, "nothing to send it to: the page never needs a room")
	p.free()
