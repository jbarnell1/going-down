# SH1: the quick tests run in several engine processes side by side, and two suites may run at once in two
# checkouts. A test that opens a socket must take its port from its process's block (tests/test_ports.gd):
#   1. the block's first port comes from --port-base=, else GD_TEST_PORT_BASE, else the default;
#   2. every offset is inside the block and no two tests share one;
#   3. no test file names a port number of its own (a literal would collide between two shards).
extends RefCounted

const T = preload("res://tests/t.gd")
const TestPorts = preload("res://tests/test_ports.gd")

func test_the_base_comes_from_the_argument_then_the_environment(t: T) -> void:
	t.eq(TestPorts.parse_base(PackedStringArray(["--quick", "--port-base=4930"]), ""), 4930, "--port-base= names the block")
	t.eq(TestPorts.parse_base(PackedStringArray(["--port-base=4930"]), "5100"), 4930, "the argument wins over the environment")
	t.eq(TestPorts.parse_base(PackedStringArray(["--quick"]), "5100"), 5100, "GD_TEST_PORT_BASE when there is no argument")
	t.eq(TestPorts.parse_base(PackedStringArray([]), ""), TestPorts.DEFAULT_BASE, "the default when neither is given")
	t.eq(TestPorts.parse_base(PackedStringArray([]), "x"), TestPorts.DEFAULT_BASE, "a variable that is not a number is ignored")
	t.eq(TestPorts.port(3), TestPorts.base() + 3, "port(k) is the base plus k")

func test_every_offset_is_in_the_block_and_its_own(t: T) -> void:
	var seen := {}
	for k: String in (TestPorts as GDScript).get_script_constant_map():
		if k == "SIZE" or k == "DEFAULT_BASE":
			continue
		var v: Variant = (TestPorts as GDScript).get_script_constant_map()[k]
		if typeof(v) != TYPE_INT:
			continue
		t.check(v >= 0 and v < TestPorts.SIZE, "%s = %d is inside the block of %d" % [k, v, TestPorts.SIZE])
		t.check(not seen.has(v), "%s has an offset of its own (%d is also %s)" % [k, v, seen.get(v, "")])
		seen[v] = k
	t.check(seen.size() >= 10, "the offsets are all listed (%d)" % seen.size())

func test_no_test_names_a_port_of_its_own(t: T) -> void:
	var literal := RegEx.create_from_string("(listen\\(\\s*\\d{4,5}\\b|127\\.0\\.0\\.1:\\d{4,5}\\b|\\bPORT\\w*\\s*:?=\\s*\\d{4,5}\\b|_session\\(t,\\s*\\d{4,5}\\b)")
	var files := DirAccess.get_files_at("res://tests")
	var looked := 0
	for f: String in files:
		if not f.ends_with(".gd") or f == "test_test_ports.gd":
			continue
		looked += 1
		var lines := FileAccess.get_file_as_string("res://tests/" + f).split("\n")
		for i in lines.size():
			var line := lines[i].strip_edges()
			if line.begins_with("#"):
				continue
			var m := literal.search(line)
			t.check(m == null, "tests/%s:%d names a port number (%s): take one from tests/test_ports.gd" % [f, i + 1, m.get_string() if m != null else ""])
	t.check(looked > 100, "every test file was read (%d)" % looked)
