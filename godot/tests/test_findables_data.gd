# The Linux server reads the findables' words too (sim/findables.gd reads data/poems.json): the rules' one data file
# is under res://data/, which every export preset must carry (tests/test_export_data.gd fails a preset leaving data/
# out), so the server, the desktop and the web builds all have it.
extends RefCounted

const T = preload("res://tests/t.gd")
const Findables = preload("res://sim/findables.gd")

func test_the_rules_read_their_data_under_res_data(t: T) -> void:
	t.check(Findables.DATA_PATH.begins_with("res://data/") and Findables.DATA_PATH.get_base_dir() == "res://data",
		"the rules read %s, under res://data/" % Findables.DATA_PATH)
	t.check(FileAccess.file_exists(Findables.DATA_PATH), "%s exists" % Findables.DATA_PATH)
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(Findables.DATA_PATH))
	t.check(parsed is Dictionary and (parsed as Dictionary).has("poems") and (parsed as Dictionary).has("pages"), "it parses, with poems and pages")
	t.check(Findables.note_lines("stillness-1").size() > 0 and Findables.note_lines("C1").size() == 1, "a poem and a page read back through the rules")
	# No other path: the rules' source names only this one data file.
	var src := FileAccess.get_file_as_string("res://sim/findables.gd")
	var re := RegEx.create_from_string("res://[A-Za-z0-9_/.]+\\.json")
	var paths := {}
	for m in re.search_all(src):
		paths[m.get_string()] = true
	t.eq(paths.keys(), [Findables.DATA_PATH], "the JSON files sim/findables.gd reads")
