# JSON exactly as JavaScript writes and reads it, for the wire protocol.
#
# Godot's own float formatting and parsing are not exact (measured on 90000 doubles from the game's
# ranges: String.to_float and JSON.parse_string read 9019 of JavaScript's shortest texts as a
# different double; str() and JSON.stringify wrote 46690 of them differently from JavaScript). The
# protocol needs a number to survive a round trip bit for bit (the host computes what a client drew
# from the same quantised poses the client was sent), and the message sizes and texts should be the
# ones the TypeScript host wrote. So:
#   - num(x) is Number.prototype.toString: the shortest digits that read back as x (Burger and Dybvig's
#     free-format algorithm on exact big integers), laid out as JavaScript lays them out.
#   - parse() reads JSON text; every number is read as the double nearest its decimal value (a fast
#     exact path for up to 15 digits, otherwise an estimate corrected by exact big-integer comparison).
#   - stringify() writes Arrays, Dictionaries (in insertion order), Strings, bools, null, ints and
#     floats as JSON.stringify does (non-finite numbers as null).
# Static and allocation-light; one shared 8-byte scratch buffer, so not for two threads at once.
extends RefCounted

const BASE_BITS := 24
const BASE := 1 << 24
const LIMB := BASE - 1
## Deepest nesting parse() accepts (the protocol needs 6).
const MAX_DEPTH := 16

static var _b := PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0])
## Exact powers of ten 1e0 .. 1e22 (built by multiplication: every one is a double exactly).
static var _p10 := PackedFloat64Array()

static func _static_init() -> void:
	var p := 1.0
	for i in 23:
		_p10.append(p)
		p *= 10.0

# ---------------------------------------------------------------------------------------------
# Small non-negative big integers: little-endian limbs of 24 bits.

static func _bn(v: int) -> PackedInt64Array:
	var a := PackedInt64Array()
	while v > 0:
		a.append(v & LIMB)
		v >>= BASE_BITS
	return a

static func _mul_small(a: PackedInt64Array, m: int) -> PackedInt64Array:
	var out := PackedInt64Array()
	out.resize(a.size())
	var carry := 0
	for i in a.size():
		var v := a[i] * m + carry
		out[i] = v & LIMB
		carry = v >> BASE_BITS
	while carry > 0:
		out.append(carry & LIMB)
		carry >>= BASE_BITS
	return out

static func _shl(a: PackedInt64Array, bits: int) -> PackedInt64Array:
	if a.is_empty() or bits == 0:
		return a
	var limbs := bits / BASE_BITS
	var sh := bits % BASE_BITS
	var out := PackedInt64Array()
	out.resize(limbs)
	out.fill(0)
	var carry := 0
	for i in a.size():
		var v := (a[i] << sh) | carry
		out.append(v & LIMB)
		carry = v >> BASE_BITS
	if carry > 0:
		out.append(carry)
	return out

static func _add(a: PackedInt64Array, b: PackedInt64Array) -> PackedInt64Array:
	var n := maxi(a.size(), b.size())
	var out := PackedInt64Array()
	out.resize(n)
	var carry := 0
	for i in n:
		var v := (a[i] if i < a.size() else 0) + (b[i] if i < b.size() else 0) + carry
		out[i] = v & LIMB
		carry = v >> BASE_BITS
	if carry > 0:
		out.append(carry)
	return out

## a - b, for a >= b.
static func _sub(a: PackedInt64Array, b: PackedInt64Array) -> PackedInt64Array:
	var out := PackedInt64Array()
	out.resize(a.size())
	var borrow := 0
	for i in a.size():
		var v := a[i] - (b[i] if i < b.size() else 0) - borrow
		if v < 0:
			v += BASE
			borrow = 1
		else:
			borrow = 0
		out[i] = v
	var n := out.size()
	while n > 0 and out[n - 1] == 0:
		n -= 1
	out.resize(n)
	return out

static func _cmp(a: PackedInt64Array, b: PackedInt64Array) -> int:
	if a.size() != b.size():
		return -1 if a.size() < b.size() else 1
	var i := a.size() - 1
	while i >= 0:
		if a[i] != b[i]:
			return -1 if a[i] < b[i] else 1
		i -= 1
	return 0

static func _mul_pow10(a: PackedInt64Array, k: int) -> PackedInt64Array:
	var out := a
	while k >= 6:
		out = _mul_small(out, 1000000)
		k -= 6
	if k > 0:
		out = _mul_small(out, int(_p10[k]))
	return out

# ---------------------------------------------------------------------------------------------
# Double bits.

## [mantissa, exponent] with x = mantissa * 2^exponent exactly (x finite, > 0).
static func _decompose(x: float) -> PackedInt64Array:
	_b.encode_double(0, x)
	var bits := _b.decode_s64(0)
	var exp_bits := (bits >> 52) & 0x7ff
	var mant := bits & ((1 << 52) - 1)
	if exp_bits == 0:
		return PackedInt64Array([mant, -1074])
	return PackedInt64Array([mant | (1 << 52), exp_bits - 1075])

static func _next(x: float, step: int) -> float:
	_b.encode_double(0, x)
	_b.encode_s64(0, _b.decode_s64(0) + step)
	return _b.decode_double(0)

# ---------------------------------------------------------------------------------------------
# Writing numbers.

## Number.prototype.toString(): the text JavaScript writes for x (JSON writes null for non-finite).
static func num(x: float) -> String:
	if is_nan(x) or is_inf(x):
		return "null"
	if x == 0.0:
		return "0"
	var neg := x < 0.0
	var a := absf(x)
	# Fast path: a decimal of at most 15 digits with up to 3 places (integers, centimetres,
	# thousandths) whose nearest double is x. Any other text that reads back as x differs from it by
	# less than one unit of x's last place, which is finer than 10^-j there, so this is the shortest.
	if a < 1e15:
		for j in 4:
			var p := _p10[j]
			var v := a * p
			var n := roundf(v)
			if n < 1e15 and n / p == a:
				var text := _place(str(int(n)), j)
				return "-" + text if neg else text
	var r := _shortest(a)
	var text := _layout(r[0], r[1])
	return "-" + text if neg else text

## An integer's digits with `j` of them after the point, trailing zeros removed.
static func _place(digits: String, j: int) -> String:
	if j == 0:
		return digits
	while digits.length() <= j:
		digits = "0" + digits
	var whole := digits.substr(0, digits.length() - j)
	var frac := digits.substr(digits.length() - j)
	while frac.ends_with("0"):
		frac = frac.substr(0, frac.length() - 1)
	return whole if frac.is_empty() else whole + "." + frac

## [digits, n]: x = 0.digits * 10^n with the fewest digits that read back as x (Burger and Dybvig,
## "Printing Floating-Point Numbers Quickly and Accurately", free-format with exact integers).
static func _shortest(x: float) -> Array:
	var fe := _decompose(x)
	var f := fe[0]
	var e := fe[1]
	var round_ok := f % 2 == 0
	var r: PackedInt64Array
	var s: PackedInt64Array
	var mp: PackedInt64Array
	var mm: PackedInt64Array
	var hidden := 1 << 52
	if e >= 0:
		var be := _shl(_bn(1), e)
		if f != hidden:
			r = _shl(_bn(f), e + 1)
			s = _bn(2)
			mp = be
			mm = be
		else:
			r = _shl(_bn(f), e + 2)
			s = _bn(4)
			mp = _shl(be, 1)
			mm = be
	else:
		if e == -1074 or f != hidden:
			r = _bn(f * 2)
			s = _shl(_bn(1), 1 - e)
			mp = _bn(1)
			mm = _bn(1)
		else:
			r = _bn(f * 4)
			s = _shl(_bn(1), 2 - e)
			mp = _bn(2)
			mm = _bn(1)
	var k := int(ceilf(log(x) / log(10.0) - 1e-10))
	if k >= 0:
		s = _mul_pow10(s, k)
	else:
		r = _mul_pow10(r, -k)
		mp = _mul_pow10(mp, -k)
		mm = _mul_pow10(mm, -k)
	# Fixup: the estimate may be one too low.
	var hi := _cmp(_add(r, mp), s)
	if (hi >= 0) if round_ok else (hi > 0):
		k += 1
	else:
		r = _mul_small(r, 10)
		mp = _mul_small(mp, 10)
		mm = _mul_small(mm, 10)
	var digits := ""
	for _guard in 40:
		var d := 0
		while _cmp(r, s) >= 0:
			r = _sub(r, s)
			d += 1
		var lo_c := _cmp(r, mm)
		var tc1 := (lo_c <= 0) if round_ok else (lo_c < 0)
		var hi_c := _cmp(_add(r, mp), s)
		var tc2 := (hi_c >= 0) if round_ok else (hi_c > 0)
		if not tc1 and not tc2:
			digits += str(d)
			r = _mul_small(r, 10)
			mp = _mul_small(mp, 10)
			mm = _mul_small(mm, 10)
			continue
		if tc1 and not tc2:
			digits += str(d)
		elif tc2 and not tc1:
			digits += str(d + 1)
		else:
			# Both ends reach x: the nearer digit, and on an exact tie the even one (as V8 does).
			var tie := _cmp(_mul_small(r, 2), s)
			digits += str(d) if tie < 0 or (tie == 0 and d % 2 == 0) else str(d + 1)
		break
	return [digits, k]

## JavaScript's layout of 0.digits * 10^n (Number::toString, radix 10).
static func _layout(digits: String, n: int) -> String:
	var k := digits.length()
	if k <= n and n <= 21:
		return digits + "0".repeat(n - k)
	if 0 < n and n <= 21:
		return digits.substr(0, n) + "." + digits.substr(n)
	if -6 < n and n <= 0:
		return "0." + "0".repeat(-n) + digits
	var ex := n - 1
	var es := ("+" if ex >= 0 else "-") + str(absi(ex))
	if k == 1:
		return digits + "e" + es
	return digits.substr(0, 1) + "." + digits.substr(1) + "e" + es

# ---------------------------------------------------------------------------------------------
# Reading numbers.

## The double nearest m * 10^e10 (m >= 0).
static func _from_decimal(m: int, e10: int) -> float:
	if m == 0:
		return 0.0
	if m < (1 << 53) and e10 >= -22 and e10 <= 22:
		return float(m) * _p10[e10] if e10 >= 0 else float(m) / _p10[-e10]
	if e10 > 330:
		return INF
	if e10 < -360:
		return 0.0
	# An estimate within a few units of the last place, then corrected exactly.
	var c := float(m)
	var k := e10
	while k > 22:
		c *= _p10[22]
		k -= 22
	while k < -22:
		c /= _p10[22]
		k += 22
	c = c * _p10[k] if k >= 0 else c / _p10[-k]
	if is_inf(c):
		c = 1.7976931348623157e308
	if c == 0.0:
		c = 5e-324
	for _i in 8:
		var fe := _decompose(c)
		var mant := fe[0]
		var ex := fe[1]
		# Above: the midpoint between c and the next double up.
		var up := _cmp_decimal(m, e10, 2 * mant + 1, ex - 1)
		if up > 0 or (up == 0 and mant % 2 == 1):
			c = _next(c, 1)
			continue
		var down: int
		if mant == (1 << 52) and ex > -1074:
			down = _cmp_decimal(m, e10, 4 * mant - 1, ex - 2)
		else:
			down = _cmp_decimal(m, e10, 2 * mant - 1, ex - 1)
		if down < 0 or (down == 0 and mant % 2 == 1):
			c = _next(c, -1)
			continue
		break
	return c

## Compares m * 10^e10 with h * 2^f exactly.
static func _cmp_decimal(m: int, e10: int, h: int, f: int) -> int:
	var l := _bn(m)
	var r := _bn(h)
	if e10 >= 0:
		l = _mul_pow10(l, e10)
	else:
		r = _mul_pow10(r, -e10)
	if f >= 0:
		r = _shl(r, f)
	else:
		l = _shl(l, -f)
	return _cmp(l, r)

# ---------------------------------------------------------------------------------------------
# Writing JSON.

static func quote(s: String) -> String:
	var plain := true
	for i in s.length():
		var c := s.unicode_at(i)
		if c < 0x20 or c == 0x22 or c == 0x5c:
			plain = false
			break
	if plain:
		return "\"" + s + "\""
	var out := "\""
	for i in s.length():
		var c := s.unicode_at(i)
		match c:
			0x22:
				out += "\\\""
			0x5c:
				out += "\\\\"
			0x08:
				out += "\\b"
			0x0c:
				out += "\\f"
			0x0a:
				out += "\\n"
			0x0d:
				out += "\\r"
			0x09:
				out += "\\t"
			_:
				if c < 0x20:
					out += "\\u%04x" % c
				else:
					out += String.chr(c)
	return out + "\""

## JSON.stringify of plain data.
static func stringify(v: Variant) -> String:
	match typeof(v):
		TYPE_NIL:
			return "null"
		TYPE_BOOL:
			return "true" if v else "false"
		TYPE_INT:
			return str(v)
		TYPE_FLOAT:
			return num(v)
		TYPE_STRING, TYPE_STRING_NAME:
			return quote(String(v))
		TYPE_ARRAY:
			var a: Array = v
			var parts := PackedStringArray()
			for x: Variant in a:
				parts.append(stringify(x))
			return "[" + ",".join(parts) + "]"
		TYPE_PACKED_FLOAT64_ARRAY:
			var pa: PackedFloat64Array = v
			var parts2 := PackedStringArray()
			for x in pa:
				parts2.append(num(x))
			return "[" + ",".join(parts2) + "]"
		TYPE_DICTIONARY:
			var d: Dictionary = v
			var parts3 := PackedStringArray()
			for k: Variant in d:
				parts3.append(quote(str(k)) + ":" + stringify(d[k]))
			return "{" + ",".join(parts3) + "}"
	push_error("jsjson: cannot write a %s" % type_string(typeof(v)))
	return "null"

# ---------------------------------------------------------------------------------------------
# Reading JSON.

## The result of parse(): `ok` false for anything that is not one complete JSON value.
class Parsed:
	var ok := false
	var value: Variant = null

## Reads JSON text (strict: one value, standard grammar, at most MAX_DEPTH deep). Numbers are floats.
static func parse(text: String) -> Parsed:
	var p := _Reader.new()
	p.s = text
	p.n = text.length()
	var out := Parsed.new()
	_r_ws(p)
	var v: Variant = _r_value(p, 0)
	_r_ws(p)
	if p.err or p.i != p.n:
		return out
	out.ok = true
	out.value = v
	return out

class _Reader:
	var s: String
	var n := 0
	var i := 0
	var err := false


static func _r_ws(r: _Reader) -> void:
	while r.i < r.n:
		var c := r.s.unicode_at(r.i)
		if c == 0x20 or c == 0x0a or c == 0x0d or c == 0x09:
			r.i += 1
		else:
			return

static func _r_value(r: _Reader, depth: int) -> Variant:
	if r.err or r.i >= r.n or depth > MAX_DEPTH:
		r.err = true
		return null
	var c := r.s.unicode_at(r.i)
	if c == 0x5b:  # [
		r.i += 1
		var a: Array = []
		_r_ws(r)
		if r.i < r.n and r.s.unicode_at(r.i) == 0x5d:
			r.i += 1
			return a
		while not r.err:
			_r_ws(r)
			a.append(_r_value(r, depth + 1))
			_r_ws(r)
			if r.i >= r.n:
				r.err = true
				break
			var d := r.s.unicode_at(r.i)
			r.i += 1
			if d == 0x5d:
				return a
			if d != 0x2c:
				r.err = true
		return null
	if c == 0x7b:  # {
		r.i += 1
		var o := {}
		_r_ws(r)
		if r.i < r.n and r.s.unicode_at(r.i) == 0x7d:
			r.i += 1
			return o
		while not r.err:
			_r_ws(r)
			if r.i >= r.n or r.s.unicode_at(r.i) != 0x22:
				r.err = true
				break
			var k := _r_string(r)
			_r_ws(r)
			if r.i >= r.n or r.s.unicode_at(r.i) != 0x3a:
				r.err = true
				break
			r.i += 1
			_r_ws(r)
			o[k] = _r_value(r, depth + 1)
			_r_ws(r)
			if r.i >= r.n:
				r.err = true
				break
			var d := r.s.unicode_at(r.i)
			r.i += 1
			if d == 0x7d:
				return o
			if d != 0x2c:
				r.err = true
		return null
	if c == 0x22:
		return _r_string(r)
	if c == 0x74 and r.s.substr(r.i, 4) == "true":
		r.i += 4
		return true
	if c == 0x66 and r.s.substr(r.i, 5) == "false":
		r.i += 5
		return false
	if c == 0x6e and r.s.substr(r.i, 4) == "null":
		r.i += 4
		return null
	if c == 0x2d or (c >= 0x30 and c <= 0x39):
		return _r_number(r)
	r.err = true
	return null

static func _r_string(r: _Reader) -> String:
	r.i += 1  # the opening quote
	var start := r.i
	var out := ""
	while r.i < r.n:
		var c := r.s.unicode_at(r.i)
		if c == 0x22:
			out += r.s.substr(start, r.i - start)
			r.i += 1
			return out
		if c < 0x20:
			break
		if c == 0x5c:
			out += r.s.substr(start, r.i - start)
			r.i += 1
			if r.i >= r.n:
				break
			var e := r.s.unicode_at(r.i)
			r.i += 1
			match e:
				0x22: out += "\""
				0x5c: out += "\\"
				0x2f: out += "/"
				0x62: out += "\b"
				0x66: out += "\f"
				0x6e: out += "\n"
				0x72: out += "\r"
				0x74: out += "\t"
				0x75:
					var h := r.s.substr(r.i, 4)
					if h.length() != 4 or not h.is_valid_hex_number():
						r.err = true
						return ""
					out += String.chr(h.hex_to_int())
					r.i += 4
				_:
					r.err = true
					return ""
			start = r.i
			continue
		r.i += 1
	r.err = true
	return ""

static func _r_number(r: _Reader) -> float:
	var neg := false
	if r.s.unicode_at(r.i) == 0x2d:
		neg = true
		r.i += 1
	var m := 0
	var sig := 0
	var dropped := 0
	var frac := 0
	if r.i >= r.n:
		r.err = true
		return 0.0
	var c := r.s.unicode_at(r.i)
	if c == 0x30:
		r.i += 1
	elif c >= 0x31 and c <= 0x39:
		while r.i < r.n:
			c = r.s.unicode_at(r.i)
			if c < 0x30 or c > 0x39:
				break
			if sig < 18:
				m = m * 10 + (c - 0x30)
				if m > 0:
					sig += 1
			else:
				dropped += 1
			r.i += 1
	else:
		r.err = true
		return 0.0
	if r.i < r.n and r.s.unicode_at(r.i) == 0x2e:
		r.i += 1
		var any := false
		while r.i < r.n:
			c = r.s.unicode_at(r.i)
			if c < 0x30 or c > 0x39:
				break
			any = true
			if sig < 18:
				m = m * 10 + (c - 0x30)
				frac += 1
				if m > 0:
					sig += 1
			r.i += 1
		if not any:
			r.err = true
			return 0.0
	var ex := 0
	if r.i < r.n and (r.s.unicode_at(r.i) == 0x65 or r.s.unicode_at(r.i) == 0x45):
		r.i += 1
		var eneg := false
		if r.i < r.n and (r.s.unicode_at(r.i) == 0x2b or r.s.unicode_at(r.i) == 0x2d):
			eneg = r.s.unicode_at(r.i) == 0x2d
			r.i += 1
		var any_e := false
		while r.i < r.n:
			c = r.s.unicode_at(r.i)
			if c < 0x30 or c > 0x39:
				break
			any_e = true
			if ex < 100000:
				ex = ex * 10 + (c - 0x30)
			r.i += 1
		if not any_e:
			r.err = true
			return 0.0
		if eneg:
			ex = -ex
	var v := _from_decimal(m, ex - frac + dropped)
	return -v if neg else v
