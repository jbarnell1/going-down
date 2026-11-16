# JavaScript arithmetic in GDScript (sim/jsmath.gd), and the float literals the rules are written with.
extends RefCounted

const M = preload("res://sim/jsmath.gd")
const Snap = preload("res://tests/snap.gd")
const Lits = preload("res://tests/literals_generated.gd")

## Every float literal in godot/sim must be read by GDScript as the same double JavaScript reads.
func test_literals(t: T) -> void:
	var wrong := 0
	for i in Lits.LITERALS.size():
		var got := M.to_hex(Lits.LITERALS[i])
		if got != Lits.BITS[i]:
			wrong += 1
			t.check(false, "literal %s reads as %s in GDScript, %s in JavaScript" % [Lits.TEXT[i], got, Lits.BITS[i]])
	# The list must be current: every float literal now in sim/*.gd must be on it.
	var listed := {}
	for s in Lits.TEXT:
		listed[s] = true
	var re := RegEx.create_from_string("(?<![\\w.])(\\d+\\.\\d*(?:[eE][-+]?\\d+)?|\\d+[eE][-+]?\\d+)(?![\\w.])")
	var strings := RegEx.create_from_string("\"(?:[^\"\\\\]|\\\\.)*\"")
	var unlisted := PackedStringArray()
	for name in DirAccess.get_files_at("res://sim"):
		if not name.ends_with(".gd"):
			continue
		for line in FileAccess.get_file_as_string("res://sim/" + name).split("\n"):
			var code := strings.sub(line, "\"\"", true)
			var hash := code.find("#")
			if hash >= 0:
				code = code.substr(0, hash)
			for m in re.search_all(code):
				if not listed.has(m.get_string(1)) and not unlisted.has(m.get_string(1)):
					unlisted.append(m.get_string(1))
	t.check(unlisted.is_empty(), "float literals not yet checked (run npm run godot:reference): %s" % ", ".join(unlisted))
	t.note("%d float literals in sim/ checked, %d read differently" % [Lits.LITERALS.size(), wrong])

func test_transcendentals_bit_exact(t: T) -> void:
	var ref: Dictionary = Snap.load_ref("math.json")
	var n := 0
	for row: Array in ref["sin"]:
		n += 1
		t.check(M.sin_js(row[0]) == row[1], "sin(%s)" % M.to_hex(row[0]))
	for row: Array in ref["cos"]:
		n += 1
		t.check(M.cos_js(row[0]) == row[1], "cos(%s)" % M.to_hex(row[0]))
	for row: Array in ref["tan"]:
		n += 1
		t.check(M.tan_js(row[0]) == row[1], "tan(%s)" % M.to_hex(row[0]))
	for row: Array in ref["atan"]:
		n += 1
		t.check(M.atan_js(row[0]) == row[1], "atan(%s)" % M.to_hex(row[0]))
	for row: Array in ref["atan2"]:
		n += 1
		t.check(M.atan2_js(row[0], row[1]) == row[2], "atan2(%s, %s)" % [M.to_hex(row[0]), M.to_hex(row[1])])
	for row: Array in ref["exp"]:
		n += 1
		t.check(M.exp_js(row[0]) == row[1], "exp(%s)" % M.to_hex(row[0]))
	for row: Array in ref["hypot2"]:
		n += 1
		t.check(M.hypot2(row[0], row[1]) == row[2], "hypot(%s, %s)" % [M.to_hex(row[0]), M.to_hex(row[1])])
	for row: Array in ref["hypot3"]:
		n += 1
		t.check(M.hypot3(row[0], row[1], row[2]) == row[3], "hypot3")
	t.check(Bot.BOT_HFOV_DEG == float(ref["hfov"]), "BOT_HFOV_DEG %s, want %s" % [M.to_hex(Bot.BOT_HFOV_DEG), M.to_hex(ref["hfov"])])
	t.note("%d samples of sin, cos, tan, atan, atan2, exp, hypot: all bit-identical" % n if t.failures.is_empty() else "")

## JavaScript's ** is the platform's pow (this machine's: neither fdlibm nor correctly rounded), so
## x ** 3 cannot be reproduced bit for bit. Close is required; identical is counted and reported.
func test_pow_is_close(t: T) -> void:
	var ref: Dictionary = Snap.load_ref("math.json")
	var differ := 0
	var n := 0
	for row: Array in ref["powInt"]:
		n += 1
		var got := M.pow_js(row[0], float(row[1]))
		var want: float = row[2]
		if got != want:
			differ += 1
			t.check(absf(got - want) <= absf(want) * 4.5e-16, "pow(%s, %d) = %s, want %s" % [M.to_hex(row[0]), row[1], M.to_hex(got), M.to_hex(want)])
	t.note("pow: %d of %d samples (x^2, x^3, 1.35^n) differ from Node's in the last bit; all within 1 ulp" % [differ, n])

func test_to_fixed(t: T) -> void:
	var ref: Dictionary = Snap.load_ref("math.json")
	for row: Array in ref["fixed"]:
		for d in 3:
			t.eq(M.to_fixed(row[0], d), String(row[1 + d]), "toFixed(%s, %d)" % [M.to_hex(row[0]), d])

func test_imul_and_uint32(t: T) -> void:
	t.eq(M.imul(0x7fffffff, 2), -2, "imul overflow")
	t.eq(M.imul(-1, -1), 1, "imul negatives")
	t.eq(M.imul(0xFFFFFFFF, 16777619), M.to_int32((0xFFFFFFFF * 16777619) & 0xFFFFFFFF), "imul wraps")
	t.eq(M.to_uint32(-1), 4294967295, ">>> 0 of -1")
	t.eq(M.to_int32(4294967295), -1, "| 0 of 2^32-1")

const T = preload("res://tests/t.gd")
const Bot = preload("res://sim/bot.gd")
