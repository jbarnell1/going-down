# Every .gd script of the game loads (parses and compiles): client, face, net, server, sim, tools, tests.
# On 17 Nov a merge left a duplicate constant (PHONE_DB) in client/sfx.gd; the game could not load its
# sounds and every other test still passed, because none of them loads the client's scripts. This one
# loads them all. Any parse or compile error the engine reports while loading fails the test (run_tests.gd
# counts engine errors), and so does a script that comes back null or cannot be instantiated.
extends RefCounted

const T = preload("res://tests/t.gd")

## The folders under res:// that hold the game's scripts. A new folder of scripts belongs here; the test
## also fails on a .gd file in any other folder, so one cannot be missed.
const DIRS: Array[String] = ["client", "face", "net", "server", "sim", "tools", "tests"]
## Folders never searched: the engine's import cache and the exported builds.
const SKIP: Array[String] = [".godot", "export", "addons"]

func test_every_script_loads(t: T) -> void:
	var files: Array[String] = []
	_collect("res://", files)
	var n := 0
	for path in files:
		var top := path.trim_prefix("res://").get_slice("/", 0)
		if not DIRS.has(top):
			t.check(false, "%s is a script outside the folders this test knows (%s): add its folder to DIRS" % [path, ", ".join(DIRS)])
			continue
		var s: Variant = load(path)
		n += 1
		if s == null or not (s is GDScript):
			t.check(false, "%s does not load" % path)
			continue
		var g: GDScript = s
		t.check(g.can_instantiate(), "%s does not compile (can_instantiate false)" % path)
	# Not vacuous: the game has well over a hundred scripts, and sfx.gd is one of them.
	t.check(n > 100 and files.has("res://client/sfx.gd"), "loaded %d scripts (expected over 100, with client/sfx.gd)" % n)
	t.note("%d scripts loaded" % n)

func _collect(dir: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		if f.get_extension() == "gd":
			out.append(dir.path_join(f))
	for sub in d.get_directories():
		if dir == "res://" and SKIP.has(sub):
			continue
		_collect(dir.path_join(sub), out)
