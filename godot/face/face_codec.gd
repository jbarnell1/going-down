# A drawn face as a short text: 32 x 32 pixels, each one of seven fixed colours, written as plain
# URL-safe characters so it can ride inside one network message (JSON needs no escaping for it).
#
#   "F1" + "R" + 512 characters      raw: each character holds two pixels (3 bits each, high first)
#   "F1" + "L" + run tokens          runs: each token is a colour and a run length
#
# "F" says this is a face, "1" is the format version, "R" or "L" the packing. Pixels go row by row,
# top row first, left to right, as the player drew them (pixel 0 is the top-left corner). The encoder
# writes both packings and keeps the shorter (runs on a tie), so one picture always gives one text.
# The longest possible text is 515 characters (a face of random noise); a typical face is 150 to 300.
#
# A run token is one character v (0..63): colour = v >> 3, n = v & 7. n 0..6 is a run of n + 1
# pixels; n = 7 means the next character e (0..63) follows and the run is 8 + e pixels (8..71).
#
# Why 32 x 32 and seven colours: the mask's screen is a 16.6 cm square at head height. In the game's
# 480 x 270 view (70 degree vertical field) it is about 32 pixels tall at 1 m, 16 at 2 m, 11 at 3 m
# and 5 at 6 m, so 32 is the most detail the avatar can ever show; anything finer is lost before
# the tape filter even starts. A coarse grid also makes a mouse drawing come out bold, which is
# what survives the filter. The filter keeps brightness and smears colour, so the colours differ
# mostly in brightness and hue family, not shades of one hue.
#
# Why a lit screen with dark ink: the screen glows (crew_view.gd SCREEN_GLOW) inside a black mask.
# Pictures of crewmates in a real corridor showed bright strokes on a dark screen reading only at 1 to
# 2 m (past that the dark screen melts into the black bezel), while dark ink on the lit screen read at
# 3 m and still showed as a glowing face at 6 m. So colour 0, the screen and what the eraser paints,
# is the pale lit green of crew_view.gd's default face; ink comes first; red, blue and green are dark
# enough to stand off the screen; yellow and white are lighter than it, for highlights.
#
# Decoding takes text from other players' machines: it checks the type, the length before looking
# at anything, the header, every character, every colour index (7 is not a colour) and that the runs
# add up to exactly 1024 pixels, and gives back an empty result (never an error) when anything is off.
class_name FaceCodec
extends RefCounted

const SIZE := 32
const PIXELS := SIZE * SIZE
const MAGIC := "F"
const VERSION := "1"
const RAW := "R"
const RUNS := "L"
const HEADER_LEN := 3
const RAW_LEN := PIXELS / 2
const MAX_LENGTH := HEADER_LEN + RAW_LEN      # 515: nothing longer is ever read
const RUN_SHORT := 7                          # n 0..6 -> runs of 1..7
const RUN_LONG_MIN := 8
const RUN_LONG_MAX := 8 + 63                  # 71
## Index 0 is the screen itself (and what the eraser paints). sRGB, as drawn on the mask.
const PALETTE: Array[Color] = [
	Color("#b8ccbd"),   # 0 screen (lit), and the eraser
	Color("#14161a"),   # 1 ink
	Color("#d0202c"),   # 2 red
	Color("#2050d8"),   # 3 blue
	Color("#12963a"),   # 4 green
	Color("#ffd21f"),   # 5 yellow
	Color("#ffffff"),   # 6 white
]
const COLOURS := 7
## The last face drawn on this computer. Nothing else is written, and nothing leaves the machine.
const SAVE_PATH := "user://face/last_face.txt"
## Where save_last / load_last read and write (tests point it elsewhere so a player's face is safe).
static var save_path := SAVE_PATH

# --- encode ------------------------------------------------------------------------------------------

## The text for a picture of SIZE x SIZE colour indices (0..6), or "" if the picture is not one.
static func encode(indices: PackedByteArray) -> String:
	if indices.size() != PIXELS:
		return ""
	for v in indices:
		if v >= COLOURS:
			return ""
	var runs := _encode_runs(indices)
	var raw := _encode_raw(indices)
	return runs if runs.length() <= raw.length() else raw

static func _encode_raw(indices: PackedByteArray) -> String:
	var out := PackedStringArray()
	out.resize(RAW_LEN)
	for i in RAW_LEN:
		out[i] = _char((indices[i * 2] << 3) | indices[i * 2 + 1])
	return MAGIC + VERSION + RAW + "".join(out)

static func _encode_runs(indices: PackedByteArray) -> String:
	var out := PackedStringArray()
	var i := 0
	while i < PIXELS:
		var c := indices[i]
		var j := i
		while j < PIXELS and indices[j] == c:
			j += 1
		var left := j - i
		while left > 0:
			if left >= RUN_LONG_MIN:
				var n := mini(left, RUN_LONG_MAX)
				out.append(_char((c << 3) | 7))
				out.append(_char(n - RUN_LONG_MIN))
				left -= n
			else:
				out.append(_char((c << 3) | (left - 1)))
				left = 0
		i = j
	return MAGIC + VERSION + RUNS + "".join(out)

# --- decode ------------------------------------------------------------------------------------------

## The picture's colour indices, or an empty array if `code` is not a valid face.
static func decode_indices(code: Variant) -> PackedByteArray:
	return _decode(code)[0]

## Why `code` would be refused ("" when it is a valid face). For tests and logs.
static func check(code: Variant) -> String:
	return _decode(code)[1]

static func is_valid(code: Variant) -> bool:
	return check(code) == ""

## The face as a texture for the mask (32 x 32, with mipmaps so it averages, not sparkles, far
## away), or null if `code` is not a valid face.
static func decode(code: Variant, palette: Array[Color] = PALETTE) -> ImageTexture:
	var px := decode_indices(code)
	if px.is_empty():
		return null
	return ImageTexture.create_from_image(to_image(px, palette, true))

## Colour indices to an RGB image (size x size). Indices outside the palette draw as index 0.
static func to_image(indices: PackedByteArray, palette: Array[Color] = PALETTE, mipmaps := false) -> Image:
	var side := int(sqrt(float(indices.size())))
	var data := PackedByteArray()
	data.resize(side * side * 3)
	var lut := PackedByteArray()
	for c: Color in palette:
		lut.append(c.r8)
		lut.append(c.g8)
		lut.append(c.b8)
	for i in side * side:
		var v := indices[i]
		if v * 3 + 2 >= lut.size():
			v = 0
		data[i * 3] = lut[v * 3]
		data[i * 3 + 1] = lut[v * 3 + 1]
		data[i * 3 + 2] = lut[v * 3 + 2]
	var img := Image.create_from_data(side, side, false, Image.FORMAT_RGB8, data)
	if mipmaps:
		img.generate_mipmaps()
	return img

# [indices, reason]: indices empty and reason set when refused.
static func _decode(code: Variant) -> Array:
	var none := PackedByteArray()
	if typeof(code) != TYPE_STRING:
		return [none, "not text"]
	var s: String = code
	if s.length() < HEADER_LEN:
		return [none, "too short"]
	if s.length() > MAX_LENGTH:
		return [none, "too long"]
	if s[0] != MAGIC:
		return [none, "not a face"]
	if s[1] != VERSION:
		return [none, "unknown version"]
	var mode := s[2]
	if mode == RAW:
		return _decode_raw(s)
	if mode == RUNS:
		return _decode_runs(s)
	return [none, "unknown packing"]

static func _decode_raw(s: String) -> Array:
	var none := PackedByteArray()
	if s.length() != HEADER_LEN + RAW_LEN:
		return [none, "wrong length"]
	var px := PackedByteArray()
	px.resize(PIXELS)
	for i in RAW_LEN:
		var v := _value(s.unicode_at(HEADER_LEN + i))
		if v < 0:
			return [none, "bad character"]
		var a := v >> 3
		var b := v & 7
		if a >= COLOURS or b >= COLOURS:
			return [none, "colour out of range"]
		px[i * 2] = a
		px[i * 2 + 1] = b
	return [px, ""]

static func _decode_runs(s: String) -> Array:
	var none := PackedByteArray()
	var px := PackedByteArray()
	px.resize(PIXELS)
	var at := 0
	var i := HEADER_LEN
	var n := s.length()
	while i < n:
		var v := _value(s.unicode_at(i))
		if v < 0:
			return [none, "bad character"]
		var c := v >> 3
		if c >= COLOURS:
			return [none, "colour out of range"]
		var run := (v & 7) + 1
		i += 1
		if (v & 7) == RUN_SHORT:
			if i >= n:
				return [none, "run cut short"]
			var e := _value(s.unicode_at(i))
			if e < 0:
				return [none, "bad character"]
			run = RUN_LONG_MIN + e
			i += 1
		if at + run > PIXELS:
			return [none, "too many pixels"]
		_fill(px, c, at, run)
		at += run
	if at != PIXELS:
		return [none, "too few pixels"]
	return [px, ""]

static func _fill(px: PackedByteArray, c: int, from: int, count: int) -> void:
	for k in count:
		px[from + k] = c

# The 64 characters: A-Z a-z 0-9 - _ (URL- and JSON-safe).
static func _char(v: int) -> String:
	if v < 26:
		return String.chr(65 + v)
	if v < 52:
		return String.chr(97 + v - 26)
	if v < 62:
		return String.chr(48 + v - 52)
	return "-" if v == 62 else "_"

static func _value(u: int) -> int:
	if u >= 65 and u <= 90:
		return u - 65
	if u >= 97 and u <= 122:
		return u - 97 + 26
	if u >= 48 and u <= 57:
		return u - 48 + 52
	if u == 45:
		return 62
	if u == 95:
		return 63
	return -1

# --- remembering the last face -------------------------------------------------------------------

## Keeps `code` as this computer's last face (only if it is valid). True when written.
static func save_last(code: String) -> bool:
	if not is_valid(code):
		return false
	DirAccess.make_dir_recursive_absolute(save_path.get_base_dir())
	var f := FileAccess.open(save_path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(code)
	f.close()
	return true

## The last face saved on this computer, or "" if there is none or the file is not a valid face.
static func load_last() -> String:
	if not FileAccess.file_exists(save_path):
		return ""
	var f := FileAccess.open(save_path, FileAccess.READ)
	if f == null:
		return ""
	if f.get_length() > MAX_LENGTH + 16:
		return ""
	var code := f.get_as_text().strip_edges()
	return code if is_valid(code) else ""
