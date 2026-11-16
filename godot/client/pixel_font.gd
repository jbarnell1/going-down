# The camcorder's 5x7 character-generator font (src/render/pixelFont.ts, written to
# data/pixel_font.json by tools/build_rules.mjs). Draws on a CanvasItem or into an Image.
class_name PixelFont
extends RefCounted

static var _glyphs := {}

static func _load() -> void:
	if not _glyphs.is_empty():
		return
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/pixel_font.json"))
	if d is Dictionary:
		_glyphs = d
	# The few marks speech needs that the OSD font lacks (src/game/announcer.ts EXTRA).
	_glyphs[","] = ["00000", "00000", "00000", "00000", "01100", "00100", "01000"]
	_glyphs["!"] = ["00100", "00100", "00100", "00100", "00100", "00000", "00100"]
	_glyphs["?"] = ["01110", "10001", "00001", "00010", "00100", "00000", "00100"]

static func known(ch: String) -> bool:
	_load()
	return _glyphs.has(ch)

static func rows(ch: String) -> Array:
	_load()
	if _glyphs.has(ch):
		return _glyphs[ch]
	var up := ch.to_upper()
	if _glyphs.has(up):
		return _glyphs[up]
	return _glyphs.get(" ", [])

## Width in font pixels (6 per character, no trailing gap).
static func width(text: String) -> int:
	return maxi(0, text.length() * 6 - 1)

static func draw(ci: CanvasItem, text: String, pos: Vector2, px: float, col: Color) -> void:
	for i in text.length():
		var r := rows(text[i])
		for y in r.size():
			var row: String = r[y]
			var x := 0
			while x < 5:
				if row[x] == "1":
					# Merge runs of lit pixels into one rectangle.
					var x1 := x
					while x1 + 1 < 5 and row[x1 + 1] == "1":
						x1 += 1
					ci.draw_rect(Rect2(pos + Vector2((i * 6 + x) * px, y * px), Vector2((x1 - x + 1) * px, px)), col)
					x = x1 + 1
				else:
					x += 1

## Text with the camcorder's one-pixel dark drop shadow.
static func draw_shadowed(ci: CanvasItem, text: String, pos: Vector2, px: float, col: Color, shadow := Color(0, 0, 0, 0.55)) -> void:
	draw(ci, text, pos + Vector2(px, px), px, shadow)
	draw(ci, text, pos, px, col)

static func blit(img: Image, text: String, at: Vector2i, col: Color, scale := Vector2i(1, 1), flip := false) -> void:
	var w := width(text)
	for i in text.length():
		var r := rows(text[i])
		for y in r.size():
			var row: String = r[y]
			for x in 5:
				if row[x] != "1":
					continue
				var fx := i * 6 + x
				var fy := y
				if flip:
					fx = w - 1 - fx
					fy = 6 - fy
				for sy in scale.y:
					for sx in scale.x:
						var p := at + Vector2i(fx * scale.x + sx, fy * scale.y + sy)
						if p.x >= 0 and p.y >= 0 and p.x < img.get_width() and p.y < img.get_height():
							img.set_pixelv(p, col)

## Wraps text into lines of at most `max_chars` characters, on spaces.
static func wrap(text: String, max_chars: int) -> PackedStringArray:
	var out := PackedStringArray()
	var line := ""
	for word in text.split(" ", false):
		if line == "":
			line = word
		elif line.length() + 1 + word.length() <= max_chars:
			line += " " + word
		else:
			out.append(line)
			line = word
	if line != "":
		out.append(line)
	return out
