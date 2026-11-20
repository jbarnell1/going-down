# WN4: "Everything about a floor comes from one seed, identical for every player." The Hanging Ward's model
# (sim/ward: layout, houses, walls, jambs, stairs, fixtures, and walk_clear over a grid of the floor) is the same:
#   1. built twice in this process;
#   2. built in fresh processes (tests/ward_digest.gd run on its own, as a standalone script);
#   3. as recorded (GOLDEN, from the Windows build): the Linux server must print the same lines (CI runs this on Linux).
extends RefCounted

const T = preload("res://tests/t.gd")
const Ward = preload("res://sim/ward/state.gd")
const Digest = preload("res://tests/ward_digest.gd")

const SEEDS: Array[int] = [183025965, 0, 26, 8143, 31827, 4059166054]

## Recorded on Windows (Godot 4.7.2) by `godot --headless --path godot --script res://tests/ward_digest.gd -- <seeds>`.
const GOLDEN := {
	183025965: "WARD 183025965 a5ebfff8b90ee0d8 54315eb6 c2ee62f6 237022e3 b8b0ac16",
	0: "WARD 0 4df912f0ef54e384 71f83242 1c202214 65f6099a 909e1415",
	26: "WARD 26 2f993b4791d33859 845b2066 a50b4c9a 2f4cf4fa 3c592413",
	8143: "WARD 8143 6a9f8e32fdf6a7f7 8a86c967 7167a5ed a1d9249f 600000f7",
	31827: "WARD 31827 6564d3be450372bf bddaa2d7 7e14e671 c703c9b3 23aada87",
	4059166054: "WARD 4059166054 92ebba4d3442ab17 df1adc9d 883705a7 446d6349 e7570b6e",
}

func test_a_point_is_clear_on_one_seed_and_not_another(t: T) -> void:
	# WN3's oddity: the screen stood at this point on seed "wn3-a" (279287019); a standalone script built seed
	# "late-5" (183025965) and found it inside a jamb. Different seeds, not different processes.
	var p := Vector3(2.075268, 0.0, -2.519225)
	t.eq("wn3-a".hash(), 279287019, "the rig's Ward seed (String.hash is the same everywhere; the host sends the number)")
	t.check(Ward.new(279287019).walk_clear(p, p), "clear on wn3-a's Ward")
	t.check(not Ward.new(183025965).walk_clear(p, p), "inside a jamb on late-5's")

func test_the_same_model_twice_in_one_process(t: T) -> void:
	for s in SEEDS:
		t.eq(Digest.line(s), Digest.line(s), "seed %d: built twice here, the same" % s)

func test_the_same_model_in_fresh_processes(t: T) -> void:
	var args: Array[String] = ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", "res://tests/ward_digest.gd", "--"]
	for s in SEEDS:
		args.append(str(s))
	var mine := {}
	for s in SEEDS:
		mine[s] = Digest.line(s)
	for run in 2:
		var out: Array = []
		var code := OS.execute(OS.get_executable_path(), args, out, true)
		if not t.check(code == 0, "a fresh process ran the digest (exit %d)" % code):
			return
		var lines := {}
		for chunk: String in out:
			for l: String in chunk.split("\n"):
				if l.begins_with("WARD "):
					lines[int(l.split(" ")[1])] = l.strip_edges()
		for s in SEEDS:
			t.eq(lines.get(s, "missing"), mine[s], "seed %d: a fresh process (run %d) builds the same Ward as this one" % [s, run + 1])

func test_the_same_model_as_recorded(t: T) -> void:
	for s in SEEDS:
		if GOLDEN.has(s):
			t.eq(Digest.line(s), GOLDEN[s], "seed %d: the same Ward as recorded on Windows (%s)" % [s, OS.get_name()])
	t.eq(GOLDEN.size(), SEEDS.size(), "every seed has a recorded line")
