# JavaScript arithmetic in GDScript (sim/jsmath.gd), and the float literals the rules are written with.
# The samples' arguments are tests/inputs/math.json; the results are goldens (tests/golden/math.json,
# first proved bit-identical to V8's, pow within 1 ulp of Node's: check_goldens_against_typescript.mjs),
# compared exactly.
extends RefCounted

const M = preload("res://sim/jsmath.gd")
const T = preload("res://tests/t.gd")
const Bot = preload("res://sim/bot.gd")
const Golden = preload("res://tests/golden.gd")

## Every float literal in godot/sim must be read by GDScript's parser as the correctly rounded
## double (the one JavaScript reads). The correctly rounded reading is worked out here, exactly, with
## big integers (`decimal_bits`), and that reader is itself checked against JavaScript's readings of
## the literals the rules were first written with (tests/inputs/literals.json, from Node).
func test_literals(t: T) -> void:
	var table: Array = Golden.input("literals.json")
	var reader_wrong := 0
	for row: Array in table:
		var got := decimal_bits(row[0])
		if got != row[1]:
			reader_wrong += 1
			t.check(false, "the decimal reader reads %s as %s, JavaScript as %s" % [row[0], got, row[1]])
	var lits := sim_literals()
	var parsed := parse_with_gdscript(lits)
	var wrong := 0
	if parsed.size() != lits.size():
		t.check(false, "could not compile the literals (%d of %d read)" % [parsed.size(), lits.size()])
	else:
		for i in lits.size():
			var want := decimal_bits(lits[i])
			var got := M.to_hex(parsed[i])
			if got != want:
				wrong += 1
				t.check(false, "literal %s reads as %s in GDScript, correctly rounded %s (build it from its bits, see jsmath.gd)" % [lits[i], got, want])
	t.note("%d float literals in sim/ read by GDScript's parser, %d read differently from the correct rounding; the reader agrees with JavaScript on %d of %d table literals" % [
		lits.size(), wrong, table.size() - reader_wrong, table.size()])

## Every distinct float literal in godot/sim/*.gd, in file order (strings and comments left out).
static func sim_literals() -> PackedStringArray:
	var re := RegEx.create_from_string("(?<![\\w.])(\\d+\\.\\d*(?:[eE][-+]?\\d+)?|\\d+[eE][-+]?\\d+)(?![\\w.])")
	var strings := RegEx.create_from_string("\"(?:[^\"\\\\]|\\\\.)*\"")
	var out := PackedStringArray()
	var names := DirAccess.get_files_at("res://sim")
	names.sort()
	for name in names:
		if not name.ends_with(".gd"):
			continue
		for line in FileAccess.get_file_as_string("res://sim/" + name).split("\n"):
			var code := strings.sub(line, "\"\"", true)
			var hash := code.find("#")
			if hash >= 0:
				code = code.substr(0, hash)
			for m in re.search_all(code):
				if not out.has(m.get_string(1)):
					out.append(m.get_string(1))
	return out

## The doubles GDScript's own parser makes of these literals (one small script compiled at run time).
static func parse_with_gdscript(lits: PackedStringArray) -> Array:
	var s := GDScript.new()
	s.source_code = "extends RefCounted\nconst V: Array[float] = [\n%s,\n]\n" % ",\n".join(lits)
	if s.reload() != OK:
		return []
	return s.get_script_constant_map()["V"]

# ---------------------------------------------------------------------------------------------
# A correctly rounded decimal reader (round half to even), for normal doubles: the literal is an
# exact fraction of big integers (base 2^24 limbs, little endian), divided out to 56+ bits.

const LIMB := 16777216

static func _big(n: int) -> Array[int]:
	var out: Array[int] = []
	while n > 0:
		out.append(n % LIMB)
		n /= LIMB
	return out

static func _mul_add(a: Array[int], m: int, add: int) -> Array[int]:
	var out: Array[int] = []
	var carry := add
	for x in a:
		var v := x * m + carry
		out.append(v % LIMB)
		carry = v / LIMB
	while carry > 0:
		out.append(carry % LIMB)
		carry /= LIMB
	return out

static func _bitlen(a: Array[int]) -> int:
	var n := a.size()
	while n > 0 and a[n - 1] == 0:
		n -= 1
	if n == 0:
		return 0
	var top := a[n - 1]
	var b := 0
	while top > 0:
		b += 1
		top >>= 1
	return (n - 1) * 24 + b

static func _bit(a: Array[int], i: int) -> int:
	var limb := i / 24
	if limb >= a.size():
		return 0
	return (a[limb] >> (i % 24)) & 1

static func _cmp(a: Array[int], b: Array[int]) -> int:
	var la := _bitlen(a)
	var lb := _bitlen(b)
	if la != lb:
		return 1 if la > lb else -1
	for i in range(maxi(a.size(), b.size()) - 1, -1, -1):
		var x := a[i] if i < a.size() else 0
		var y := b[i] if i < b.size() else 0
		if x != y:
			return 1 if x > y else -1
	return 0

static func _sub(a: Array[int], b: Array[int]) -> Array[int]:
	var out: Array[int] = []
	var borrow := 0
	for i in a.size():
		var v := a[i] - borrow - (b[i] if i < b.size() else 0)
		borrow = 0
		if v < 0:
			v += LIMB
			borrow = 1
		out.append(v)
	return out

## Bits of the correctly rounded double nearest the decimal literal `text` (16 hex digits).
static func decimal_bits(text: String) -> String:
	var s := text.to_lower()
	var exp10 := 0
	var e := s.find("e")
	if e >= 0:
		exp10 = int(s.substr(e + 1))
		s = s.substr(0, e)
	var dot := s.find(".")
	if dot >= 0:
		exp10 -= s.length() - dot - 1
		s = s.substr(0, dot) + s.substr(dot + 1)
	var n: Array[int] = []
	for c in s:
		n = _mul_add(n, 10, int(c))
	if _bitlen(n) == 0:
		return M.to_hex(0.0)
	var q: Array[int]
	var sticky := false
	var exp2 := 0
	if exp10 >= 0:
		for i in exp10:
			n = _mul_add(n, 10, 0)
		q = n
	else:
		var den: Array[int] = _big(1)
		for i in -exp10:
			den = _mul_add(den, 10, 0)
		var k := maxi(0, 56 + _bitlen(den) - _bitlen(n))
		for i in k:
			n = _mul_add(n, 2, 0)
		exp2 = -k
		# Long division, bit by bit.
		var r: Array[int] = []
		q = []
		for i in range(_bitlen(n) - 1, -1, -1):
			r = _mul_add(r, 2, _bit(n, i))
			var b := 0
			if _cmp(r, den) >= 0:
				r = _sub(r, den)
				b = 1
			q = _mul_add(q, 2, b)
		sticky = _bitlen(r) > 0
	var bits := _bitlen(q)
	var shift := maxi(0, bits - 53)
	var mant := 0
	for i in range(bits - 1, shift - 1, -1):
		mant = mant * 2 + _bit(q, i)
	if shift > 0:
		var half := _bit(q, shift - 1) == 1
		var lower := sticky
		for i in shift - 1:
			if _bit(q, i) == 1:
				lower = true
		if half and (lower or mant % 2 == 1):
			mant += 1
			if mant == 9007199254740992:
				mant /= 2
				shift += 1
	var x := float(mant)
	var p := shift + exp2
	while p > 0:
		x *= 2.0
		p -= 1
	while p < 0:
		x *= 0.5
		p += 1
	return M.to_hex(x)

# ---------------------------------------------------------------------------------------------

func test_transcendentals_bit_exact(t: T) -> void:
	var a: Dictionary = Golden.input("math.json")
	var rows := {}
	rows["sin"] = _rows1(a["sin"], func(x: float) -> float: return M.sin_js(x))
	rows["cos"] = _rows1(a["cos"], func(x: float) -> float: return M.cos_js(x))
	rows["tan"] = _rows1(a["tan"], func(x: float) -> float: return M.tan_js(x))
	rows["atan"] = _rows1(a["atan"], func(x: float) -> float: return M.atan_js(x))
	rows["exp"] = _rows1(a["exp"], func(x: float) -> float: return M.exp_js(x))
	var atan2: Array = []
	for r: Array in a["atan2"]:
		atan2.append([r[0], r[1], M.atan2_js(r[0], r[1])])
	rows["atan2"] = atan2
	var h2: Array = []
	for r: Array in a["hypot2"]:
		h2.append([r[0], r[1], M.hypot2(r[0], r[1])])
	rows["hypot2"] = h2
	var h3: Array = []
	for r: Array in a["hypot3"]:
		h3.append([r[0], r[1], r[2], M.hypot3(r[0], r[1], r[2])])
	rows["hypot3"] = h3
	var n := 0
	for k: String in ["sin", "cos", "tan", "atan", "atan2", "exp", "hypot2", "hypot3"]:
		n += (rows[k] as Array).size()
		t.expect("math.json", k, rows[k], k)
	t.expect("math.json", "hfov", Bot.BOT_HFOV_DEG, "BOT_HFOV_DEG")
	t.note("%d samples of sin, cos, tan, atan, atan2, exp, hypot: all bit-identical to the golden" % n if t.failures.is_empty() else "")

static func _rows1(args: Array, f: Callable) -> Array:
	var out: Array = []
	for x: Variant in args:
		out.append([x, f.call(float(x))])
	return out

## sim/jsmath.gd pow_js (fdlibm's pow; JavaScript's ** is the platform's pow and differed from it in
## the last bit for some of these: the first goldens were checked within 1 ulp of Node's).
func test_pow(t: T) -> void:
	var a: Dictionary = Golden.input("math.json")
	var rows: Array = []
	for r: Array in a["powInt"]:
		rows.append([r[0], r[1], M.pow_js(r[0], float(r[1]))])
	t.expect("math.json", "powInt", rows, "pow")
	t.note("pow: %d samples (x^2, x^3, 1.35^n) bit-identical to the golden" % rows.size())

func test_to_fixed(t: T) -> void:
	var a: Dictionary = Golden.input("math.json")
	var rows: Array = []
	for v: Variant in a["fixed"]:
		var x := float(v)
		rows.append([v, M.to_fixed(x, 0), M.to_fixed(x, 1), M.to_fixed(x, 2)])
	t.expect("math.json", "fixed", rows, "toFixed")

func test_imul_and_uint32(t: T) -> void:
	t.eq(M.imul(0x7fffffff, 2), -2, "imul overflow")
	t.eq(M.imul(-1, -1), 1, "imul negatives")
	t.eq(M.imul(0xFFFFFFFF, 16777619), M.to_int32((0xFFFFFFFF * 16777619) & 0xFFFFFFFF), "imul wraps")
	t.eq(M.to_uint32(-1), 4294967295, ">>> 0 of -1")
	t.eq(M.to_int32(4294967295), -1, "| 0 of 2^32-1")
