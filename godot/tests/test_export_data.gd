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
