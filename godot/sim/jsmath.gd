# JavaScript's number maths, bit for bit, for the rules ported from src/sim.
#
# GDScript floats are IEEE doubles like JavaScript numbers, and + - * / sqrt floor fmod are exact
# the same way on both. These are not:
#   - sin, cos, tan, atan, atan2, exp, pow: Godot calls the C library (MSVC's on Windows, another
#     in a browser build); V8 (Node 20, the reference) uses its own port of fdlibm. They disagree in
#     the last bit for a few percent of inputs (measured: 129 to 4746 of 4000 to 12000 samples each).
#     So the fdlibm routines V8 uses are ported here, line for line from V8's src/base/ieee754.cc.
#   - Math.hypot: V8 scales by the largest argument and sums with Kahan compensation, which is not
#     sqrt(x*x + y*y) (38% of samples differ). Ported below.
#   - 32-bit integer operators (Math.imul, |0, >>>): GDScript ints are 64-bit, so they are masked.
# Everything here is static and allocation-free except the shared 8-byte scratch buffer, so it is
# not safe to call from two threads at once.

const MASK32 := 0xFFFFFFFF
const PI_JS := PI  # Math.PI: GDScript's PI is the same double (0x400921FB54442D18)

static var _b := PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0])

## GDScript parses long decimal literals inexactly (measured: 886 of 3011 shortest-form literals
## came out wrong), so every constant here with more than 15 significant digits is set from its
## exact bits, written beside it in decimal.
static func _static_init() -> void:
	_INVPIO2 = from_hex("3fe45f306dc9c883")  # 6.36619772367581382433e-01
	_PIO2_1 = from_hex("3ff921fb54400000")  # 1.57079632673412561417e+00
	_PIO2_1T = from_hex("3dd0b4611a626331")  # 6.07710050650619224932e-11
	_PIO2_2 = from_hex("3dd0b4611a600000")  # 6.07710050630396597660e-11
	_PIO2_2T = from_hex("3ba3198a2e037073")  # 2.02226624879595063154e-21
	_PIO2_3 = from_hex("3ba3198a2e000000")  # 2.02226624871116645580e-21
	_PIO2_3T = from_hex("397b839a252049c1")  # 8.47842766036889956997e-32
	_S1 = from_hex("bfc5555555555549")  # -1.66666666666666324348e-01
	_S2 = from_hex("3f8111111110f8a6")  # 8.33333333332248946124e-03
	_S3 = from_hex("bf2a01a019c161d5")  # -1.98412698298579493134e-04
	_S4 = from_hex("3ec71de357b1fe7d")  # 2.75573137070700676789e-06
	_S5 = from_hex("be5ae5e68a2b9ceb")  # -2.50507602534068634195e-08
	_S6 = from_hex("3de5d93a5acfd57c")  # 1.58969099521155010221e-10
	_C1 = from_hex("3fa555555555554c")  # 4.16666666666666019037e-02
	_C2 = from_hex("bf56c16c16c15177")  # -1.38888888888741095749e-03
	_C3 = from_hex("3efa01a019cb1590")  # 2.48015872894767294178e-05
	_C4 = from_hex("be927e4f809c52ad")  # -2.75573143513906633035e-07
	_C5 = from_hex("3e21ee9ebdb4b1c4")  # 2.08757232129817482790e-09
	_C6 = from_hex("bda8fae9be8838d4")  # -1.13596475577881948265e-11
	_PIO4 = from_hex("3fe921fb54442d18")  # 7.85398163397448278999e-01
	_PIO4LO = from_hex("3c81a62633145c07")  # 3.06161699786838301793e-17
	_PI_O_4 = from_hex("3fe921fb54442d18")  # 7.8539816339744827900E-01
	_PI_O_2 = from_hex("3ff921fb54442d18")  # 1.5707963267948965580E+00
	_PI = from_hex("400921fb54442d18")  # 3.1415926535897931160E+00
	_PI_LO = from_hex("3ca1a62633145c07")  # 1.2246467991473531772E-16
	_O_THRESHOLD = from_hex("40862e42fefa39ef")  # 7.09782712893383973096e+02
	_U_THRESHOLD = from_hex("c0874910d52d3051")  # -7.45133219101941108420e+02
	_INVLN2 = from_hex("3ff71547652b82fe")  # 1.44269504088896338700e+00
	_P1 = from_hex("3fc555555555553e")  # 1.66666666666666019037e-01
	_P2 = from_hex("bf66c16c16bebd93")  # -2.77777777770155933842e-03
	_P3 = from_hex("3f11566aaf25de2c")  # 6.61375632143793436117e-05
	_P4 = from_hex("bebbbd41c5d26bf1")  # -1.65339022054652515390e-06
	_P5 = from_hex("3e66376972bea4d0")  # 4.13813679705723846039e-08
	_E = from_hex("4005bf0a8b145769")  # 2.718281828459045
	_TWOM1000 = from_hex("0170000000000000")  # 9.33263618503218878990e-302
	_TWO1023 = from_hex("7fe0000000000000")  # 8.988465674311579539e307
	_TWO53 = from_hex("4340000000000000")  # 9007199254740992.0
	_L1 = from_hex("3fe3333333333303")  # 5.99999999999994648725e-01
	_L2 = from_hex("3fdb6db6db6fabff")  # 4.28571428578550184252e-01
	_L3 = from_hex("3fd55555518f264d")  # 3.33333329818377432918e-01
	_L4 = from_hex("3fd17460a91d4101")  # 2.72728123808534006489e-01
	_L5 = from_hex("3fcd864a93c9db65")  # 2.30660745775561754067e-01
	_L6 = from_hex("3fca7e284a454eef")  # 2.06975017800338417784e-01
	_LG2 = from_hex("3fe62e42fefa39ef")  # 6.93147180559945286227e-01
	_LG2_H = from_hex("3fe62e4300000000")  # 6.93147182464599609375e-01
	_LG2_L = from_hex("be205c610ca86c39")  # -1.90465429995776804525e-09
	_OVT = from_hex("3c971547652b82fe")  # 8.0085662595372944372e-17
	_CP = from_hex("3feec709dc3a03fd")  # 9.61796693925975554329e-01
	_CP_H = from_hex("3feec709e0000000")  # 9.61796700954437255859e-01
	_CP_L = from_hex("be3e2fe0145b01f5")  # -7.02846165095275826516e-09
	_IVLN2 = from_hex("3ff71547652b82fe")  # 1.44269504088896338700e+00
	_IVLN2_H = from_hex("3ff7154760000000")  # 1.44269502162933349609e+00
	_IVLN2_L = from_hex("3e54ae0bf85ddf44")  # 1.92596299112661746887e-08
	_T = [from_hex("3fd5555555555563"), from_hex("3fc111111110fe7a"), from_hex("3faba1ba1bb341fe"), from_hex("3f9664f48406d637"), from_hex("3f8226e3e96e8493"), from_hex("3f6d6d22c9560328"), from_hex("3f57dbc8fee08315"), from_hex("3f4344d8f2f26501"), from_hex("3f3026f71a8d1068"), from_hex("3f147e88a03792a6"), from_hex("3f12b80f32f0a7e9"), from_hex("bef375cbdb605373"), from_hex("3efb2a7074bf7ad4")]
	_ATANHI = [from_hex("3fddac670561bb4f"), from_hex("3fe921fb54442d18"), from_hex("3fef730bd281f69b"), from_hex("3ff921fb54442d18")]
	_ATANLO = [from_hex("3c7a2b7f222f65e2"), from_hex("3c81a62633145c07"), from_hex("3c7007887af0cbbd"), from_hex("3c91a62633145c07")]
	_AT = [from_hex("3fd555555555550d"), from_hex("bfc999999998ebc4"), from_hex("3fc24924920083ff"), from_hex("bfbc71c6fe231671"), from_hex("3fb745cdc54c206e"), from_hex("bfb3b0f2af749a6d"), from_hex("3fb10d66a0d03d51"), from_hex("bfadde2d52defd9a"), from_hex("3fa97b4b24760deb"), from_hex("bfa2b4442c6a6c2f"), from_hex("3f90ad3ae322da11")]
	_LN2HI = [from_hex("3fe62e42fee00000"), from_hex("bfe62e42fee00000")]
	_LN2LO = [from_hex("3dea39ef35793c76"), from_hex("bdea39ef35793c76")]
	_DP_H = [from_hex("0000000000000000"), from_hex("3fe2b80340000000")]
	_DP_L = [from_hex("0000000000000000"), from_hex("3e4cfdeb43cfd006")]

# ---------------------------------------------------------------------------------------------
# 32-bit integers, JavaScript style.

## Math.imul: the low 32 bits of a * b, as a signed 32-bit integer.
static func imul(a: int, b: int) -> int:
	a &= MASK32
	b &= MASK32
	var lo := (a & 0xFFFF) * (b & 0xFFFF)
	var mid := (((a >> 16) * (b & 0xFFFF)) + ((a & 0xFFFF) * (b >> 16))) & 0xFFFF
	return to_int32((lo + (mid << 16)) & MASK32)

## x | 0 for a value already integral: wrap to a signed 32-bit integer.
static func to_int32(x: int) -> int:
	x &= MASK32
	return x - 0x100000000 if x >= 0x80000000 else x

## x >>> 0: wrap to an unsigned 32-bit integer.
static func to_uint32(x: int) -> int:
	return x & MASK32

# ---------------------------------------------------------------------------------------------
# Double bits.

static func high_word(x: float) -> int:
	_b.encode_double(0, x)
	return _b.decode_s32(4)

static func low_word(x: float) -> int:
	_b.encode_double(0, x)
	return _b.decode_u32(0)

static func from_words(hi: int, lo: int) -> float:
	_b.encode_u32(4, hi & MASK32)
	_b.encode_u32(0, lo & MASK32)
	return _b.decode_double(0)

static func with_low_word(x: float, lo: int) -> float:
	_b.encode_double(0, x)
	_b.encode_u32(0, lo & MASK32)
	return _b.decode_double(0)

static func with_high_word(x: float, hi: int) -> float:
	_b.encode_double(0, x)
	_b.encode_u32(4, hi & MASK32)
	return _b.decode_double(0)

## The 16 hex digits of a double's bits (how the reference files carry floats exactly).
static func to_hex(x: float) -> String:
	_b.encode_double(0, x)
	return "%08x%08x" % [_b.decode_u32(4), _b.decode_u32(0)]

static func from_hex(h: String) -> float:
	return from_words(h.substr(0, 8).hex_to_int(), h.substr(8, 8).hex_to_int())

# ---------------------------------------------------------------------------------------------
# Math.hypot (V8: builtins/math.tq MathHypot).

static func hypot2(a: float, b: float) -> float:
	var x := absf(a)
	var y := absf(b)
	if is_inf(x) or is_inf(y):
		return INF
	if is_nan(x) or is_nan(y):
		return NAN
	var m := maxf(x, y)
	if m == 0.0:
		return 0.0
	var sum := 0.0
	var comp := 0.0
	var n := x / m
	var s := n * n - comp
	var p := sum + s
	comp = (p - sum) - s
	sum = p
	n = y / m
	s = n * n - comp
	p = sum + s
	comp = (p - sum) - s
	sum = p
	return sqrt(sum) * m

static func hypot3(a: float, b: float, c: float) -> float:
	var x := absf(a)
	var y := absf(b)
	var z := absf(c)
	if is_inf(x) or is_inf(y) or is_inf(z):
		return INF
	if is_nan(x) or is_nan(y) or is_nan(z):
		return NAN
	var m := maxf(maxf(x, y), z)
	if m == 0.0:
		return 0.0
	var sum := 0.0
	var comp := 0.0
	for v: float in [x, y, z]:
		var n := v / m
		var s := n * n - comp
		var p := sum + s
		comp = (p - sum) - s
		sum = p
	return sqrt(sum) * m

# ---------------------------------------------------------------------------------------------
# fdlibm, as in V8's src/base/ieee754.cc.

const _NPIO2_HW: Array[int] = [
	0x3FF921FB, 0x400921FB, 0x4012D97C, 0x401921FB, 0x401F6A7A, 0x4022D97C, 0x4025FDBB, 0x402921FB,
	0x402C463A, 0x402F6A7A, 0x4031475C, 0x4032D97C, 0x40346B9C, 0x4035FDBB, 0x40378FDB, 0x403921FB,
	0x403AB41B, 0x403C463A, 0x403DD85A, 0x403F6A7A, 0x40407E4C, 0x4041475C, 0x4042106C, 0x4042D97C,
	0x4043A28C, 0x40446B9C, 0x404534AC, 0x4045FDBB, 0x4046C6CB, 0x40478FDB, 0x404858EB, 0x404921FB,
]
static var _INVPIO2 := 0.0
static var _PIO2_1 := 0.0
static var _PIO2_1T := 0.0
static var _PIO2_2 := 0.0
static var _PIO2_2T := 0.0
static var _PIO2_3 := 0.0
static var _PIO2_3T := 0.0

# __ieee754_rem_pio2 results, returned through these (single-threaded, see the header).
static var _y0 := 0.0
static var _y1 := 0.0

## Reduces x to y0 + y1 in [-pi/4, pi/4] and returns n with x = n * pi/2 + y. Only the small and
## medium ranges (|x| <= 2^19 * pi/2) are ported: the rules never take sin or cos of anything larger.
static func _rem_pio2(x: float) -> int:
	var hx := high_word(x)
	var ix := hx & 0x7fffffff
	var z := 0.0
	if ix <= 0x3fe921fb:
		_y0 = x
		_y1 = 0.0
		return 0
	if ix < 0x4002d97c:
		if hx > 0:
			z = x - _PIO2_1
			if ix != 0x3ff921fb:
				_y0 = z - _PIO2_1T
				_y1 = (z - _y0) - _PIO2_1T
			else:
				z -= _PIO2_2
				_y0 = z - _PIO2_2T
				_y1 = (z - _y0) - _PIO2_2T
			return 1
		else:
			z = x + _PIO2_1
			if ix != 0x3ff921fb:
				_y0 = z + _PIO2_1T
				_y1 = (z - _y0) + _PIO2_1T
			else:
				z += _PIO2_2
				_y0 = z + _PIO2_2T
				_y1 = (z - _y0) + _PIO2_2T
			return -1
	if ix <= 0x413921fb:
		var t := absf(x)
		var n := int(t * _INVPIO2 + 0.5)
		var fn := float(n)
		var r := t - fn * _PIO2_1
		var w := fn * _PIO2_1T
		if n < 32 and ix != _NPIO2_HW[n - 1]:
			_y0 = r - w
		else:
			var j := ix >> 20
			_y0 = r - w
			var high := high_word(_y0)
			var i := j - ((high >> 20) & 0x7ff)
			if i > 16:
				t = r
				w = fn * _PIO2_2
				r = t - w
				w = fn * _PIO2_2T - ((t - r) - w)
				_y0 = r - w
				high = high_word(_y0)
				i = j - ((high >> 20) & 0x7ff)
				if i > 49:
					t = r
					w = fn * _PIO2_3
					r = t - w
					w = fn * _PIO2_3T - ((t - r) - w)
					_y0 = r - w
		_y1 = (r - _y0) - w
		if hx < 0:
			_y0 = -_y0
			_y1 = -_y1
			return -n
		return n
	push_error("jsmath: argument too large for the ported range reduction: %s" % x)
	return 0

static var _S1 := 0.0
static var _S2 := 0.0
static var _S3 := 0.0
static var _S4 := 0.0
static var _S5 := 0.0
static var _S6 := 0.0

static func _kernel_sin(x: float, y: float, iy: int) -> float:
	var ix := high_word(x) & 0x7fffffff
	if ix < 0x3e400000:
		if int(x) == 0:
			return x
	var z := x * x
	var v := z * x
	var r := _S2 + z * (_S3 + z * (_S4 + z * (_S5 + z * _S6)))
	if iy == 0:
		return x + v * (_S1 + z * r)
	return x - ((z * (0.5 * y - v * r) - y) - v * _S1)

static var _C1 := 0.0
static var _C2 := 0.0
static var _C3 := 0.0
static var _C4 := 0.0
static var _C5 := 0.0
static var _C6 := 0.0

static func _kernel_cos(x: float, y: float) -> float:
	var ix := high_word(x) & 0x7fffffff
	if ix < 0x3e400000:
		if int(x) == 0:
			return 1.0
	var z := x * x
	var r := z * (_C1 + z * (_C2 + z * (_C3 + z * (_C4 + z * (_C5 + z * _C6)))))
	if ix < 0x3FD33333:
		return 1.0 - (0.5 * z - (z * r - x * y))
	var qx: float
	if ix > 0x3fe90000:
		qx = 0.28125
	else:
		qx = from_words(ix - 0x00200000, 0)
	var iz := 0.5 * z - qx
	var a := 1.0 - qx
	return a - (iz - (z * r - x * y))

## Math.sin
static func sin_js(x: float) -> float:
	var ix := high_word(x) & 0x7fffffff
	if ix <= 0x3fe921fb:
		return _kernel_sin(x, 0.0, 0)
	if ix >= 0x7ff00000:
		return x - x
	var n := _rem_pio2(x)
	match n & 3:
		0:
			return _kernel_sin(_y0, _y1, 1)
		1:
			return _kernel_cos(_y0, _y1)
		2:
			return -_kernel_sin(_y0, _y1, 1)
		_:
			return -_kernel_cos(_y0, _y1)

## Math.cos
static func cos_js(x: float) -> float:
	var ix := high_word(x) & 0x7fffffff
	if ix <= 0x3fe921fb:
		return _kernel_cos(x, 0.0)
	if ix >= 0x7ff00000:
		return x - x
	var n := _rem_pio2(x)
	match n & 3:
		0:
			return _kernel_cos(_y0, _y1)
		1:
			return -_kernel_sin(_y0, _y1, 1)
		2:
			return -_kernel_cos(_y0, _y1)
		_:
			return _kernel_sin(_y0, _y1, 1)

static var _T: Array[float] = []
static var _PIO4 := 0.0
static var _PIO4LO := 0.0

static func _kernel_tan(x: float, y: float, iy: int) -> float:
	var z: float
	var r: float
	var v: float
	var w: float
	var s: float
	var hx := high_word(x)
	var ix := hx & 0x7fffffff
	if ix < 0x3e300000:
		if int(x) == 0:
			var low := low_word(x)
			if ((ix | low) | (iy + 1)) == 0:
				return 1.0 / absf(x)
			if iy == 1:
				return x
			w = x + y
			z = with_low_word(w, 0)
			v = y - (z - x)
			var a := -1.0 / w
			var t := with_low_word(a, 0)
			s = 1.0 + t * z
			return t + a * (s + t * v)
	if ix >= 0x3FE59428:
		if hx < 0:
			x = -x
			y = -y
		z = _PIO4 - x
		w = _PIO4LO - y
		x = z + w
		y = 0.0
	z = x * x
	w = z * z
	r = _T[1] + w * (_T[3] + w * (_T[5] + w * (_T[7] + w * (_T[9] + w * _T[11]))))
	v = z * (_T[2] + w * (_T[4] + w * (_T[6] + w * (_T[8] + w * (_T[10] + w * _T[12])))))
	s = z * x
	r = y + z * (s * (r + v) + y)
	r += _T[0] * s
	w = x + r
	if ix >= 0x3FE59428:
		v = float(iy)
		return float(1 - ((hx >> 30) & 2)) * (v - 2.0 * (x - (w * w / (w + v) - r)))
	if iy == 1:
		return w
	z = with_low_word(w, 0)
	v = r - (z - x)
	var a2 := -1.0 / w
	var t2 := with_low_word(a2, 0)
	s = 1.0 + t2 * z
	return t2 + a2 * (s + t2 * v)

## Math.tan
static func tan_js(x: float) -> float:
	var ix := high_word(x) & 0x7fffffff
	if ix <= 0x3fe921fb:
		return _kernel_tan(x, 0.0, 1)
	if ix >= 0x7ff00000:
		return x - x
	var n := _rem_pio2(x)
	return _kernel_tan(_y0, _y1, 1 - ((n & 1) << 1))

static var _ATANHI: Array[float] = []
static var _ATANLO: Array[float] = []
static var _AT: Array[float] = []

## Math.atan
static func atan_js(x: float) -> float:
	var hx := high_word(x)
	var ix := hx & 0x7fffffff
	var id: int
	if ix >= 0x44100000:
		var low := low_word(x)
		if ix > 0x7ff00000 or (ix == 0x7ff00000 and low != 0):
			return x + x
		if hx > 0:
			return _ATANHI[3] + _ATANLO[3]
		return -_ATANHI[3] - _ATANLO[3]
	if ix < 0x3fdc0000:
		if ix < 0x3e400000:
			if 1.0e300 + x > 1.0:
				return x
		id = -1
	else:
		x = absf(x)
		if ix < 0x3ff30000:
			if ix < 0x3fe60000:
				id = 0
				x = (2.0 * x - 1.0) / (2.0 + x)
			else:
				id = 1
				x = (x - 1.0) / (x + 1.0)
		else:
			if ix < 0x40038000:
				id = 2
				x = (x - 1.5) / (1.0 + 1.5 * x)
			else:
				id = 3
				x = -1.0 / x
	var z := x * x
	var w := z * z
	var s1 := z * (_AT[0] + w * (_AT[2] + w * (_AT[4] + w * (_AT[6] + w * (_AT[8] + w * _AT[10])))))
	var s2 := w * (_AT[1] + w * (_AT[3] + w * (_AT[5] + w * (_AT[7] + w * _AT[9]))))
	if id < 0:
		return x - x * (s1 + s2)
	z = _ATANHI[id] - ((x * (s1 + s2) - _ATANLO[id]) - x)
	return -z if hx < 0 else z

static var _PI_O_4 := 0.0
static var _PI_O_2 := 0.0
static var _PI := 0.0
static var _PI_LO := 0.0

## Math.atan2(y, x)
static func atan2_js(y: float, x: float) -> float:
	_b.encode_double(0, x)
	var hx := _b.decode_s32(4)
	var lx := _b.decode_u32(0)
	_b.encode_double(0, y)
	var hy := _b.decode_s32(4)
	var ly := _b.decode_u32(0)
	var ix := hx & 0x7fffffff
	var iy := hy & 0x7fffffff
	if is_nan(x) or is_nan(y):
		return x + y
	if ((hx - 0x3ff00000) | lx) == 0:
		return atan_js(y)
	var m := ((hy >> 31) & 1) | ((hx >> 30) & 2)
	if (iy | ly) == 0:
		match m:
			0, 1:
				return y
			2:
				return _PI
			_:
				return -_PI
	if (ix | lx) == 0:
		return -_PI_O_2 if hy < 0 else _PI_O_2
	if ix == 0x7ff00000:
		if iy == 0x7ff00000:
			match m:
				0:
					return _PI_O_4
				1:
					return -_PI_O_4
				2:
					return 3.0 * _PI_O_4
				_:
					return -3.0 * _PI_O_4
		else:
			match m:
				0:
					return 0.0
				1:
					return -0.0
				2:
					return _PI
				_:
					return -_PI
	if iy == 0x7ff00000:
		return -_PI_O_2 if hy < 0 else _PI_O_2
	var k := (iy - ix) >> 20
	var z: float
	if k > 60:
		z = _PI_O_2 + 0.5 * _PI_LO
		m &= 1
	elif hx < 0 and k < -60:
		z = 0.0
	else:
		z = atan_js(absf(y / x))
	match m:
		0:
			return z
		1:
			return -z
		2:
			return _PI - (z - _PI_LO)
		_:
			return (z - _PI_LO) - _PI

const _HALF: Array[float] = [0.5, -0.5]
static var _O_THRESHOLD := 0.0
static var _U_THRESHOLD := 0.0
static var _LN2HI: Array[float] = []
static var _LN2LO: Array[float] = []
static var _INVLN2 := 0.0
static var _P1 := 0.0
static var _P2 := 0.0
static var _P3 := 0.0
static var _P4 := 0.0
static var _P5 := 0.0
static var _E := 0.0
static var _TWOM1000 := 0.0
static var _TWO1023 := 0.0

## Math.exp
static func exp_js(x: float) -> float:
	var hi := 0.0
	var lo := 0.0
	var k := 0
	var hx := high_word(x)
	var xsb := (hx >> 31) & 1
	hx &= 0x7fffffff
	if hx >= 0x40862E42:
		if hx >= 0x7ff00000:
			if is_nan(x):
				return x + x
			return x if xsb == 0 else 0.0
		if x > _O_THRESHOLD:
			return INF
		if x < _U_THRESHOLD:
			return 0.0
	if hx > 0x3fd62e42:
		if hx < 0x3FF0A2B2:
			if x == 1.0:
				return _E
			hi = x - _LN2HI[xsb]
			lo = _LN2LO[xsb]
			k = 1 - xsb - xsb
		else:
			k = int(_INVLN2 * x + _HALF[xsb])
			var tk := float(k)
			hi = x - tk * _LN2HI[0]
			lo = tk * _LN2LO[0]
		x = hi - lo
	elif hx < 0x3e300000:
		if 1.0e300 + x > 1.0:
			return 1.0 + x
	else:
		k = 0
	var t := x * x
	var twopk: float
	if k >= -1021:
		twopk = from_words(0x3ff00000 + (k << 20), 0)
	else:
		twopk = from_words(0x3ff00000 + ((k + 1000) << 20), 0)
	var c := x - t * (_P1 + t * (_P2 + t * (_P3 + t * (_P4 + t * _P5))))
	if k == 0:
		return 1.0 - ((x * c) / (c - 2.0) - x)
	var y := 1.0 - ((lo - (x * c) / (2.0 - c)) - hi)
	if k >= -1021:
		if k == 1024:
			return y * 2.0 * _TWO1023
		return y * twopk
	return y * twopk * _TWOM1000

const _BP: Array[float] = [1.0, 1.5]
static var _DP_H: Array[float] = []
static var _DP_L: Array[float] = []
static var _TWO53 := 0.0
static var _L1 := 0.0
static var _L2 := 0.0
static var _L3 := 0.0
static var _L4 := 0.0
static var _L5 := 0.0
static var _L6 := 0.0
static var _LG2 := 0.0
static var _LG2_H := 0.0
static var _LG2_L := 0.0
static var _OVT := 0.0
static var _CP := 0.0
static var _CP_H := 0.0
static var _CP_L := 0.0
static var _IVLN2 := 0.0
static var _IVLN2_H := 0.0
static var _IVLN2_L := 0.0

## Math.pow and the ** operator (V8's ieee754::legacy::pow, fdlibm's __ieee754_pow).
static func pow_js(x: float, y: float) -> float:
	_b.encode_double(0, x)
	var hx := _b.decode_s32(4)
	var lx := _b.decode_u32(0)
	_b.encode_double(0, y)
	var hy := _b.decode_s32(4)
	var ly := _b.decode_u32(0)
	var ix := hx & 0x7fffffff
	var iy := hy & 0x7fffffff
	var i: int
	var j: int
	var k: int
	var n: int
	var z: float
	var t: float
	var t1: float
	var t2: float
	var u: float
	var v: float
	var w: float
	var r: float
	var s: float
	var p_h: float
	var p_l: float
	if (iy | ly) == 0:
		return 1.0
	if is_nan(x) or is_nan(y):
		return x + y
	var yisint := 0
	if hx < 0:
		if iy >= 0x43400000:
			yisint = 2
		elif iy >= 0x3ff00000:
			k = (iy >> 20) - 0x3ff
			if k > 20:
				j = ly >> (52 - k)
				if ((j << (52 - k)) & MASK32) == ly:
					yisint = 2 - (j & 1)
			elif ly == 0:
				j = iy >> (20 - k)
				if (j << (20 - k)) == iy:
					yisint = 2 - (j & 1)
	if ly == 0:
		if iy == 0x7ff00000:
			if ((ix - 0x3ff00000) | lx) == 0:
				return y - y
			elif ix >= 0x3ff00000:
				return y if hy >= 0 else 0.0
			else:
				return -y if hy < 0 else 0.0
		if iy == 0x3ff00000:
			if hy < 0:
				return 1.0 / x
			return x
		if hy == 0x40000000:
			return x * x
		if hy == 0x3fe00000:
			if hx >= 0:
				return sqrt(x)
	var ax := absf(x)
	if lx == 0:
		if ix == 0x7ff00000 or ix == 0 or ix == 0x3ff00000:
			z = ax
			if hy < 0:
				z = 1.0 / z
			if hx < 0:
				if ((ix - 0x3ff00000) | yisint) == 0:
					z = NAN
				elif yisint == 1:
					z = -z
			return z
	n = ((hx & MASK32) >> 31) - 1
	if (n | yisint) == 0:
		return NAN
	s = 1.0
	if (n | (yisint - 1)) == 0:
		s = -1.0
	if iy > 0x41e00000:
		if iy > 0x43f00000:
			if ix <= 0x3fefffff:
				return INF if hy < 0 else 0.0
			if ix >= 0x3ff00000:
				return INF if hy > 0 else 0.0
		if ix < 0x3fefffff:
			return s * INF if hy < 0 else s * 0.0
		if ix > 0x3ff00000:
			return s * INF if hy > 0 else s * 0.0
		t = ax - 1.0
		w = (t * t) * (0.5 - t * ((1.0 / 3.0) - t * 0.25))
		u = _IVLN2_H * t
		v = t * _IVLN2_L - w * _IVLN2
		t1 = with_low_word(u + v, 0)
		t2 = v - (t1 - u)
	else:
		n = 0
		if ix < 0x00100000:
			ax *= _TWO53
			n -= 53
			ix = high_word(ax)
		n += (ix >> 20) - 0x3ff
		j = ix & 0x000fffff
		ix = j | 0x3ff00000
		if j <= 0x3988E:
			k = 0
		elif j < 0xBB67A:
			k = 1
		else:
			k = 0
			n += 1
			ix -= 0x00100000
		ax = with_high_word(ax, ix)
		u = ax - _BP[k]
		v = 1.0 / (ax + _BP[k])
		var ss := u * v
		var s_h := with_low_word(ss, 0)
		var t_h := from_words(((ix >> 1) | 0x20000000) + 0x00080000 + (k << 18), 0)
		var t_l := ax - (t_h - _BP[k])
		var s_l := v * ((u - s_h * t_h) - s_h * t_l)
		var s2 := ss * ss
		r = s2 * s2 * (_L1 + s2 * (_L2 + s2 * (_L3 + s2 * (_L4 + s2 * (_L5 + s2 * _L6)))))
		r += s_l * (s_h + ss)
		s2 = s_h * s_h
		t_h = with_low_word(3.0 + s2 + r, 0)
		t_l = r - ((t_h - 3.0) - s2)
		u = s_h * t_h
		v = s_l * t_h + t_l * ss
		p_h = with_low_word(u + v, 0)
		p_l = v - (p_h - u)
		var z_h := _CP_H * p_h
		var z_l := _CP_L * p_h + p_l * _CP + _DP_L[k]
		t = float(n)
		t1 = with_low_word((((z_h + z_l) + _DP_H[k]) + t), 0)
		t2 = z_l - (((t1 - t) - _DP_H[k]) - z_h)
	var y1 := with_low_word(y, 0)
	p_l = (y - y1) * t1 + y * t2
	p_h = y1 * t1
	z = p_l + p_h
	_b.encode_double(0, z)
	j = _b.decode_s32(4)
	i = _b.decode_u32(0)
	if j >= 0x40900000:
		if ((j - 0x40900000) | i) != 0:
			return s * INF
		elif p_l + _OVT > z - p_h:
			return s * INF
	elif (j & 0x7fffffff) >= 0x4090cc00:
		if (((j - 0xc090cc00) & MASK32) | i) != 0:
			return s * 0.0
		elif p_l <= z - p_h:
			return s * 0.0
	i = j & 0x7fffffff
	k = (i >> 20) - 0x3ff
	n = 0
	if i > 0x3fe00000:
		n = j + (0x00100000 >> (k + 1))
		k = ((n & 0x7fffffff) >> 20) - 0x3ff
		t = from_words(n & ~(0x000fffff >> k), 0)
		n = ((n & 0x000fffff) | 0x00100000) >> (20 - k)
		if j < 0:
			n = -n
		p_h -= t
	t = with_low_word(p_l + p_h, 0)
	u = t * _LG2_H
	v = (p_l - (t - p_h)) * _LG2 + t * _LG2_L
	z = u + v
	w = v - (z - u)
	t = z * z
	t1 = z - t * (_P1 + t * (_P2 + t * (_P3 + t * (_P4 + t * _P5))))
	r = (z * t1) / (t1 - 2.0) - (w + z * w)
	z = 1.0 - (r - z)
	j = high_word(z)
	j = to_int32(j + ((n << 20) & MASK32))
	if (j >> 20) <= 0:
		z = _scalbn(z, n)
	else:
		z = with_high_word(z, high_word(z) + ((n << 20) & MASK32))
	return s * z

static func _scalbn(x: float, n: int) -> float:
	# Only reached for results below the normal range; the rules never get there.
	var r := x
	while n > 0:
		r *= 2.0
		n -= 1
	while n < 0:
		r *= 0.5
		n += 1
	return r

# ---------------------------------------------------------------------------------------------
# Number formatting.

## Number.prototype.toFixed(digits) for 0 <= digits <= 3 and |x| < 2^40: exact decimal rounding of
## the double, ties away from zero, as the specification says. (printf-style formatting rounds
## exact ties to even, and Godot's own formatting is not exact.)
static func to_fixed(x: float, digits: int) -> String:
	assert(digits >= 0 and digits <= 3)
	var neg := x < 0.0
	var a := absf(x)
	var scale := 1
	for _d in digits:
		scale *= 10
	# a = m * 2^e exactly, with m a 53-bit integer.
	_b.encode_double(0, a)
	var hi := _b.decode_u32(4)
	var lo := _b.decode_u32(0)
	var exp_bits := (hi >> 20) & 0x7ff
	var mant := ((hi & 0xfffff) << 32) | lo
	var e: int
	if exp_bits == 0:
		e = -1074
	else:
		mant |= 1 << 52
		e = exp_bits - 1075
	var q: int
	if e >= 0:
		q = (mant << e) * scale
	elif -e > 62:
		q = 0 if -e > 72 or digits < 3 else (1 if a >= 0.0005 else 0)  # below 2^-10 (an exact tie cannot occur there)
	else:
		var sh := -e
		var num := mant * scale  # < 2^63
		q = num >> sh
		var rem := num - (q << sh)
		if rem * 2 >= (1 << sh):
			q += 1
	var whole := q / scale
	var frac := q % scale
	var text := str(whole)
	if digits > 0:
		text += "." + str(frac).pad_zeros(digits)
	if neg:
		text = "-" + text
	return text
