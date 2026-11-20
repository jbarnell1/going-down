# The four drawn faces of the crew on the Reactor's floor, on damaged TV screens (the-intact-crew.md: "Their
# screen masks carry faces drawn by people like Crew 41"; "Preserve the seat numbers and the exact four face
# drawings seen on the zombies"). The drawings themselves: assets/station/faces/seat-N.png (drawn by
# assets_src/station/draw_faces.py, the same four the recovered tape shows), else this file's own four marker
# drawings, one per seat, were that file ever missing. Either way the screen is cracked from one knock, has a dead
# band across it, and stays pale so the drawing reads in the dark through the tape filter.
extends RefCounted

const FACE := "res://assets/station/faces/seat-%d.png"
const N := 64
const SCREEN := Color(0.80, 0.85, 0.79)
const INK := Color(0.08, 0.08, 0.07)
const CRACK := Color(0.2, 0.22, 0.2)

static var _cache := {}

## The drawing for seat n (1 to 4), undamaged: the game's file for the seat, or this file's own.
static func drawing(n: int) -> Image:
	var path := FACE % n
	if ResourceLoader.exists(path):
		var t: Texture2D = load(path)
		if t != null:
			var img := t.get_image().duplicate() as Image
			if img.is_compressed():
				img.decompress()
			img.clear_mipmaps()
			img.convert(Image.FORMAT_RGB8)
			img.resize(N, N, Image.INTERPOLATE_BILINEAR)
			return img
	return own_drawing(n)

static func _dot(img: Image, c: Vector2i, r: int, col: Color) -> void:
	for y in range(-r, r + 1):
		for x in range(-r, r + 1):
			if x * x + y * y <= r * r + 1:
				var p := c + Vector2i(x, y)
				if p.x >= 0 and p.y >= 0 and p.x < N and p.y < N:
					img.set_pixelv(p, col)

## A marker line two pixels wide.
static func _line(img: Image, a: Vector2, b: Vector2, col: Color, w := 1) -> void:
	var steps := int(maxf(1.0, a.distance_to(b) * 2.0))
	for i in steps + 1:
		var p := a.lerp(b, float(i) / steps)
		_dot(img, Vector2i(roundi(p.x), roundi(p.y)), w, col)

## This file's own four: seat 1 the crooked mouth, seat 2 wide eyes over a row of teeth, seat 3 crossed-out eyes
## and a flat mouth, seat 4 a spiral cheek and a too-wide smile.
static func own_drawing(n: int) -> Image:
	var img := Image.create(N, N, false, Image.FORMAT_RGB8)
	img.fill(SCREEN)
	match n:
		1:
			_dot(img, Vector2i(21, 25), 4, INK)
			_dot(img, Vector2i(43, 23), 3, INK)
			_line(img, Vector2(18, 44), Vector2(30, 40), INK)
			_line(img, Vector2(30, 40), Vector2(37, 47), INK)
			_line(img, Vector2(37, 47), Vector2(47, 41), INK)
		2:
			for e: Vector2i in [Vector2i(20, 24), Vector2i(44, 24)]:
				_dot(img, e, 7, INK)
				_dot(img, e, 4, SCREEN)
				_dot(img, e + Vector2i(1, 1), 2, INK)
			_line(img, Vector2(16, 44), Vector2(48, 44), INK)
			for x in range(18, 48, 6):
				_line(img, Vector2(x, 44), Vector2(x + 3, 50), INK)
				_line(img, Vector2(x + 3, 50), Vector2(x + 6, 44), INK)
		3:
			for e: Vector2i in [Vector2i(20, 25), Vector2i(44, 25)]:
				_line(img, Vector2(e.x - 5, e.y - 5), Vector2(e.x + 5, e.y + 5), INK)
				_line(img, Vector2(e.x + 5, e.y - 5), Vector2(e.x - 5, e.y + 5), INK)
			_line(img, Vector2(22, 45), Vector2(42, 45), INK)
		_:
			_dot(img, Vector2i(22, 24), 3, INK)
			_dot(img, Vector2i(42, 24), 3, INK)
			var prev := Vector2(48, 36)
			for k in 24:
				var a := k * 0.55
				var p := Vector2(48, 36) + Vector2(cos(a), sin(a)) * (k * 0.28)
				_line(img, prev, p, INK, 0)
				prev = p
			for k in 17:
				var u := k / 16.0
				var p2 := Vector2(lerpf(12, 52, u), 40 + 9 * sin(u * PI))
				_dot(img, Vector2i(roundi(p2.x), roundi(p2.y)), 1, INK)
	return img

## The screen of seat n as worn: the drawing, cracked from one knock (seeded by seat), a dead band across it.
static func damaged(n: int) -> Texture2D:
	if _cache.has(n):
		return _cache[n]
	var img := drawing(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("station-screen-%d" % n)
	var hit := Vector2(rng.randf_range(10, 54), rng.randf_range(8, 30))
	for k in rng.randi_range(5, 8):
		var a := rng.randf() * TAU
		var p := hit
		for seg in 4:
			var q := p + Vector2(cos(a), sin(a)) * rng.randf_range(5.0, 11.0)
			_line(img, p, q, CRACK, 0)
			p = q
			a += rng.randf_range(-0.5, 0.5)
	var band := rng.randi_range(30, 52)
	for y in range(band, mini(N, band + 3)):
		for x in N:
			img.set_pixel(x, y, img.get_pixel(x, y).lerp(Color(0.95, 0.97, 0.94), 0.75))
	_dot(img, Vector2i(roundi(hit.x), roundi(hit.y)), 2, CRACK)
	img.generate_mipmaps()
	var t := ImageTexture.create_from_image(img)
	_cache[n] = t
	return t
