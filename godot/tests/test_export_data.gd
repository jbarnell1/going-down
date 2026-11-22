# Every exported build carries the data files the rules read (res://data/*.json).
# On 18 Nov the Linux server's export left data/ out: on the real server the Annex's sticky notes
# (sim/notes.gd), the incident report's awards (sim/report.gd) and the upgrade list (sim/upgrades.gd)
# could not have loaded, and nothing noticed, because every network test runs the server from the
# project folder, where the files are. This reads export_presets.cfg and fails if any preset leaves
# them out, and if a rules script names a data file that is not there.
extends RefCounted

const T = preload("res://tests/t.gd")

func test_every_export_carries_the_data(t: T) -> void:
	var text := FileAccess.get_file_as_string("res://export_presets.cfg")
	t.check(not text.is_empty(), "export_presets.cfg is read")
	var presets := 0
	var name := ""
	var include := ""
	for raw: String in text.split("\n"):
		var line := raw.strip_edges()
		if line.begins_with("name="):
			name = line.trim_prefix("name=").trim_prefix("\"").trim_suffix("\"")
		elif line.begins_with("include_filter="):
			include = line
		elif line.begins_with("exclude_filter="):
			presets += 1
			t.check(include.contains("data/*.json"), "%s: include_filter has data/*.json (%s)" % [name, include])
			t.check(not line.contains("data/"), "%s: exclude_filter does not leave data/ out (%s)" % [name, line])
	t.check(presets >= 3, "three presets read (web, Windows, the Linux server): %d" % presets)

func test_the_data_files_the_rules_name_exist(t: T) -> void:
	var n := 0
	for dir: String in ["sim", "net", "server"]:
		var d := DirAccess.open("res://" + dir)
		if d == null:
			continue
		for f: String in d.get_files():
			if not f.ends_with(".gd"):
				continue
			var src := FileAccess.get_file_as_string("res://%s/%s" % [dir, f])
			var at := src.find("\"res://data/")
			while at >= 0:
				var end := src.find("\"", at + 1)
				var path := src.substr(at + 1, end - at - 1)
				if path.ends_with(".json"):
					n += 1
					t.check(FileAccess.file_exists(path), "%s/%s names %s, which exists" % [dir, f, path])
				at = src.find("\"res://data/", end)
	t.check(n >= 2, "the rules name at least two data files (%d found)" % n)
	t.note("%d data file references checked" % n)

## IP1: the Hanging Ward's and the Reactor's files ship in the game builds like every other floor's (no extra file
## beside the game): each is in the project, and neither the web nor the Windows preset leaves it out. The tape is
## the one split: the full copy in the Windows build, the lighter one in the browser build.
const FLOOR_FILES: Array[String] = [
	"assets/ward/rigger.glb", "assets/ward/search-hand.glb",
	# MR1: the hand-rigged Meshy figure (shown with figures=new) and the albedo the import extracts from it.
	"assets/ward/rigger_v2.glb", "assets/ward/rigger_v2_rigger_v2_albedo.png",
	"assets/ward/voice/bella/ward_lift_departed.mp3", "assets/ward/voice/bella/ward_lift_last_minute.mp3",
	"assets/ward/voice/bella/ward_lift_returned.mp3", "assets/ward/voice/bella/ward_lift_final_call.mp3",
	"assets/ward/voice/bella/ward_lift_closed.mp3", "assets/sfx/playroom/net_flap.ogg",
	"assets/ward/voice/bella/ward_station.mp3", "assets/ward/voice/bella/ward_called.mp3",
	"assets/ward/voice/bella/ward_hung.mp3", "assets/ward/voice/bella/ward_cut.mp3",
	"assets/ward/voice/bella/ward_left_behind.mp3",
	"assets/station/crew_zombie.glb", "assets/station/faces/seat-1.png", "assets/station/faces/seat-2.png",
	"assets/station/faces/seat-3.png", "assets/station/faces/seat-4.png",
	# MT1: the Temp's new figure (figures=new), loaded by name rather than preloaded, so named here.
	"assets/entities/temp_v2.glb",
	"assets/entities/groundskeeper_v2.glb",
	"assets/entities/minder_v2.glb",
	# MO1: the Orderly's second model (drawn with figures=new) and the texture Godot takes out of it.
	"assets/entities/orderly_v2.glb", "assets/entities/orderly_v2_Orderly_v2_albedo.webp",
	# AR1: the Reactor's photo maps (loaded by name, client/station_dress.gd tex) and its two Meshy pieces with the
	# colour maps Godot takes out of them.
	"assets/reactor/wall_concrete.webp", "assets/reactor/wall_paint.webp", "assets/reactor/floor_concrete.webp",
	"assets/reactor/ceiling_concrete.webp", "assets/reactor/steel_plate.webp", "assets/arboretum/painted_iron.webp",
	"assets/reactor/growth_c.glb", "assets/reactor/growth_c_Image_0.webp", "assets/reactor/rotor_b.glb", "assets/reactor/rotor_b_Image_0.webp",
	# AW1: the Hanging Ward's CC0 photographs (client/ward/skin.gd loads them by name).
	"assets/ward/surfaces/brick.webp", "assets/ward/surfaces/plaster.webp", "assets/ward/surfaces/planks.webp",
	"assets/ward/surfaces/floorboards.webp", "assets/ward/surfaces/slates.webp", "assets/ward/surfaces/rock.webp",
	"assets/ward/surfaces/iron.webp", "assets/ward/surfaces/doorwood.webp", "assets/ward/surfaces/paper.webp",
	# PR1: the Playroom's two Meshy pieces (client/playroom_view.gd loads them by name) and their colour maps.
	"assets/playroom/slide.glb", "assets/playroom/slide_Image_0.webp", "assets/playroom/frame.glb", "assets/playroom/frame_Image_0.webp",
]
const TAPE := {"Web": "assets/station/tape/crew23_web.ogv", "Windows": "assets/station/tape/crew23.ogv"}
## MU1: the owner's five music tracks (client/music.gd), loaded by name rather than preloaded, so named here.
const MUSIC_FILES: Array[String] = ["assets/music/abandoned_jingle.ogg", "assets/music/elevator_muzak.ogg",
	"assets/music/wistful_regret.ogg", "assets/music/sub_bass_drone.ogg", "assets/music/final_stamp.ogg"]

func test_the_music_ships_in_every_game_build(t: T) -> void:
	for f: String in MUSIC_FILES:
		t.check(ResourceLoader.exists("res://" + f) and load("res://" + f) is AudioStreamOggVorbis, "res://%s is in the project, an Ogg Vorbis stream" % f)
	var text := FileAccess.get_file_as_string("res://export_presets.cfg")
	var name := ""
	var seen := 0
	for raw: String in text.split("\n"):
		var line := raw.strip_edges()
		if line.begins_with("name="):
			name = line.trim_prefix("name=").trim_prefix("\"").trim_suffix("\"")
		elif line.begins_with("export_filter=") and TAPE.has(name):
			t.eq(line, "export_filter=\"all_resources\"", "%s exports every resource" % name)
		elif line.begins_with("exclude_filter=") and TAPE.has(name):
			seen += 1
			for dir: String in ["assets/*", "assets/music", ".ogg", "music"]:
				t.check(not line.contains(dir), "%s: exclude_filter does not name %s (%s)" % [name, dir, line])
	t.eq(seen, 2, "the web and Windows presets were read")

func test_the_late_floors_files_ship_in_every_game_build(t: T) -> void:
	for f: String in FLOOR_FILES + TAPE.values():
		t.check(FileAccess.file_exists("res://" + f), "res://%s is in the project" % f)
	var text := FileAccess.get_file_as_string("res://export_presets.cfg")
	var name := ""
	var include := ""
	var seen := 0
	for raw: String in text.split("\n"):
		var line := raw.strip_edges()
		if line.begins_with("name="):
			name = line.trim_prefix("name=").trim_prefix("\"").trim_suffix("\"")
		elif line.begins_with("include_filter="):
			include = line
		elif line.begins_with("exclude_filter=") and TAPE.has(name):
			seen += 1
			for dir: String in ["assets/*", "assets/ward", "assets/station/*", "assets/station/faces", "assets/sfx", "assets/reactor", ".glb", ".mp3", ".png", ".webp"]:
				t.check(not line.contains(dir), "%s: exclude_filter does not name %s (%s)" % [name, dir, line])
			var other: String = TAPE["Web" if name == "Windows" else "Windows"]
			t.check(include.contains(TAPE[name]), "%s: include_filter carries its tape %s" % [name, TAPE[name]])
			t.check(line.contains(other) and not line.contains(TAPE[name] + "\"") and not line.contains(TAPE[name] + ","), "%s: exclude_filter leaves out only the other build's tape %s" % [name, other])
	t.eq(seen, 2, "the web and Windows presets were read")
