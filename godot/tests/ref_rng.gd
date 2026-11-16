# The seeded RNG against src/sim/rng.ts: sequences, ints, chances, picks and forks for 50 seeds.
extends RefCounted

const T = preload("res://tests/t.gd")
const Snap = preload("res://tests/snap.gd")
const Rng = preload("res://sim/rng.gd")

func test_sequences_and_forks(t: T) -> void:
	var cases: Array = Snap.load_ref("rng.json")
	var compared := 0
	for c: Dictionary in cases:
		var seed: Variant = c["seed"]
		if c["hash"] != null:
			t.eq(Rng.hash_seed(seed), int(c["hash"]), "hashSeed(%s)" % seed)
		var r := Rng.make_rng(seed)
		var got := {"next": [], "ints": [], "chance": [], "pick": [], "fork": [], "forkfork": [], "after": []}
		for i in 12:
			got["next"].append(r.next())
		for i in 12:
			got["ints"].append(r.int_in(-5, 17))
		for i in 12:
			got["chance"].append(r.chance(0.3))
		var items := ["a", "b", "c", "d", "e", "f", "g"]
		for i in 6:
			got["pick"].append(r.pick(items))
		var f := r.fork("floor-3")
		for i in 6:
			got["fork"].append(f.next())
		var ff := r.fork("a").fork("b")
		for i in 4:
			got["forkfork"].append(ff.next())
		for i in 4:
			got["after"].append(r.next())
		for k: String in got:
			var d := Snap.compare(got[k], c[k], "%s.%s" % [seed, k])
			compared += d.compared
			t.check(d.bad == 0 and d.inexact == 0, "seed %s %s: %s" % [seed, k, d.summary()])
	t.note("50 seeds, %d values compared, all identical" % compared if t.failures.is_empty() else "")
