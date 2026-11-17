# The seeded RNG: sequences, ints, chances, picks and forks for 50 seeds (35 strings, 15 numbers),
# against tests/golden/rng.json (first proved equal to src/sim/rng.ts).
extends RefCounted

const T = preload("res://tests/t.gd")
const Rng = preload("res://sim/rng.gd")

## The seeds (dump_reference.ts dumpRng): seed-0..34, then fifteen numbers.
static func seeds() -> Array:
	var out: Array = []
	for i in 35:
		out.append("seed-%d" % i)
	out.append_array([0, 1, 4294967295, 4294967296 + 5, -1, -123456789, 2654435761, 12345, 99, 7, 1 << 30, 3000000000, 42, 65535, 31337])
	return out

func test_sequences_and_forks(t: T) -> void:
	var cases: Array = []
	var n := 0
	for seed: Variant in seeds():
		var r := Rng.make_rng(seed)
		var c := {"seed": seed, "hash": Rng.hash_seed(seed) if seed is String else null}
		var keys := ["next", "ints", "chance", "pick", "fork", "forkfork", "after"]
		for k: String in keys:
			c[k] = []
		for i in 12:
			c["next"].append(r.next())
		for i in 12:
			c["ints"].append(r.int_in(-5, 17))
		for i in 12:
			c["chance"].append(r.chance(0.3))
		var items := ["a", "b", "c", "d", "e", "f", "g"]
		for i in 6:
			c["pick"].append(r.pick(items))
		var f := r.fork("floor-3")
		for i in 6:
			c["fork"].append(f.next())
		var ff := r.fork("a").fork("b")
		for i in 4:
			c["forkfork"].append(ff.next())
		for i in 4:
			c["after"].append(r.next())
		cases.append(c)
		n += 1
	var d := t.expect("rng.json", "", cases, "rng")
	t.note("%d seeds, %d values compared, all identical" % [n, d.compared] if t.failures.is_empty() and not t.recording else "")
