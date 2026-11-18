# The server's data check (server/data_check.gd) knows every data file the rules read, and every one of
# them reads. On 18 Nov the Linux server build left data/* out and no test noticed; the server now refuses
# to start without them, but only for the files in DataCheck.FILES. This test fails if a `res://data/....json`
# path is written anywhere in sim/, net/ or server/ without being in that list, so a new data file cannot be
# forgotten by the check.
extends RefCounted

const T = preload("res://tests/t.gd")
const DataCheck = preload("res://server/data_check.gd")

## The folders whose code a server runs (client/ is the game's own and never runs on a server).
const DIRS: Array[String] = ["res://sim", "res://net", "res://server"]

func test_every_data_path_in_server_code_is_checked(t: T) -> void:
	var re := RegEx.create_from_string("res://data/[A-Za-z0-9_./-]+\\.json")
	var found := {}  # path -> first file that names it
	var scripts := 0
	for dir in DIRS:
		var files: Array[String] = []
		_collect(dir, files)
		for f in files:
			scripts += 1
			for m in re.search_all(FileAccess.get_file_as_string(f)):
				if not found.has(m.get_string()):
					found[m.get_string()] = f
	for path: String in found:
		t.check(DataCheck.FILES.has(path), "%s names %s, which is not in server/data_check.gd FILES (add it, with its loader in read())" % [found[path], path])
	# Not vacuous: the three files of 18 Nov are named in the rules' own code, not only in the list.
	var outside := 0
	for path: String in found:
		if not String(found[path]).ends_with("data_check.gd"):
			outside += 1
	t.check(scripts > 30 and outside >= 3, "searched %d scripts, %d data paths named outside the list (expected over 30 and at least 3)" % [scripts, outside])
	t.note("%d scripts, data paths %s" % [scripts, ", ".join(found.keys())])

func test_every_listed_file_reads(t: T) -> void:
	for path in DataCheck.FILES:
		t.check(FileAccess.file_exists(path), "%s exists in the project" % path)
		t.check(DataCheck.read(path) > 0, "%s reads through its loader (%d entries)" % [path, DataCheck.read(path)])
	var r := DataCheck.run()
	t.check(r["ok"] and int(r["files"]) == DataCheck.FILES.size(), "the check passes on the project: %s" % JSON.stringify(r))

func test_a_missing_file_is_refused(t: T) -> void:
	for path in DataCheck.FILES:
		var r := DataCheck.run(path.get_file())
		t.check(not r["ok"] and r["missing"] == path.get_file() and r["why"] == "did not read", "with %s unreadable the check fails naming it: %s" % [path.get_file(), JSON.stringify(r)])
	t.eq(DataCheck.read("res://data/no_such_file.json"), -1, "a file the check has no loader for reads as -1")

func _collect(dir: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		if f.get_extension() == "gd":
			out.append(dir.path_join(f))
	for sub in d.get_directories():
		_collect(dir.path_join(sub), out)
