# The face format, the paint and the editor, headless. From the repository root:
#   Godot --headless --path godot --script res://face/face_tests.gd
# Prints one summary line ("face tests: N passed, 0 failed") and exits non-zero on any failure.
# Never touches the player's own saved face: save_path points at a scratch file that is deleted.
extends SceneTree

const Codec := preload("res://face/face_codec.gd")
const Paint := preload("res://face/face_paint.gd")
const EditorScene := preload("res://face/face_editor.tscn")
const TEST_SAVE := "user://face/test_only_face.txt"

var passed := 0
var failed := 0

func ok(cond: bool, what: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		print("  FAIL: ", what)

func _initialize() -> void:
	Codec.save_path = TEST_SAVE
	_palette()
	_round_trips()
	_golden()
	_size_budget()
	_malformed()
	_fuzz()
	_paint()
	_save_load()
	await _editor()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SAVE))
	print("face tests: %d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)

# --- pictures to test with -------------------------------------------------------------------------

func blank(c := 0) -> PackedByteArray:
	var px := PackedByteArray()
	px.resize(Codec.PIXELS)
	px.fill(c)
	return px

func noise(seed_v: int) -> PackedByteArray:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var px := blank()
	for i in px.size():
		px[i] = rng.randi_range(0, Codec.COLOURS - 1)
	return px

func checker(a: int, b: int) -> PackedByteArray:
	var px := blank()
	for y in Codec.SIZE:
		for x in Codec.SIZE:
			px[y * Codec.SIZE + x] = a if (x + y) % 2 == 0 else b
	return px

## A busy hand-drawn face: every colour, many short strokes, a filled background.
func busy_face() -> PackedByteArray:
	var p := Paint.new(Codec.SIZE)
	p.clear(6)
	p.fill(Vector2i(0, 0), 6)
	for i in 14:
		var a := Vector2(2.0 + i * 2.1, 2.0 + fmod(i * 7.3, 28.0))
		p.line(a, a + Vector2(5.0, 3.0 - (i % 5)), 2.0, i % 7)
	p.dab(Vector2(10.5, 12.0), 6.0, 1)
	p.dab(Vector2(21.5, 12.0), 6.0, 1)
	p.dab(Vector2(10.5, 12.0), 2.0, 0)
	p.dab(Vector2(21.5, 12.0), 2.0, 0)
	for x in range(6, 27, 3):
		p.line(Vector2(x, 22.0), Vector2(x + 1.5, 27.0), 2.0, 4 if x % 2 == 0 else 2)
	return p.px

# --- the tests ---------------------------------------------------------------------------------------

func _palette() -> void:
	# Lit screen, dark ink: the screen is the crewmate's default lit face colour, and every other
	# colour but the two highlights stands well off it in brightness, so it survives the tape filter.
	ok(Codec.PALETTE.size() == Codec.COLOURS, "palette: %d colours" % Codec.COLOURS)
	ok(Codec.PALETTE[0].to_html(false) == "b8ccbd", "palette: colour 0 is the lit screen (got %s)" % Codec.PALETTE[0].to_html(false))
	var screen := Codec.PALETTE[0].get_luminance()
	ok(Codec.PALETTE[1].get_luminance() < 0.1, "palette: colour 1 is dark ink")
	for i: int in [1, 2, 3, 4]:
		ok(screen - Codec.PALETTE[i].get_luminance() > 0.3, "palette: colour %d is much darker than the screen" % i)
	for i: int in [5, 6]:
		ok(Codec.PALETTE[i].get_luminance() > screen, "palette: colour %d is a highlight, lighter than the screen" % i)

func _round_trips() -> void:
	var cases := {"blank": blank(), "all ink": blank(1), "all white": blank(6), "noise 1": noise(1),
		"noise 2": noise(2), "checker": checker(1, 2), "checker screen": checker(0, 6), "busy": busy_face()}
	for s: String in Paint.STARTERS:
		cases["starter " + s] = Paint.starter(s)
	for name: String in cases:
		var px: PackedByteArray = cases[name]
		var code := Codec.encode(px)
		ok(code != "", "%s: encodes" % name)
		ok(Codec.check(code) == "", "%s: valid (%s)" % [name, Codec.check(code)])
		ok(Codec.decode_indices(code) == px, "%s: round trip" % name)
		ok(Codec.encode(px) == code, "%s: same text twice" % name)
		ok(Codec.encode(Codec.decode_indices(code)) == code, "%s: decode then encode gives the same text" % name)
		var tex := Codec.decode(code)
		ok(tex != null and tex.get_width() == 32 and tex.get_height() == 32, "%s: 32x32 texture" % name)
		if tex:
			var img := tex.get_image()
			ok(img.get_pixel(0, 0).to_html(false) == Codec.PALETTE[px[0]].to_html(false), "%s: top-left pixel colour" % name)
			var last := Codec.PIXELS - 1
			ok(img.get_pixel(31, 31).to_html(false) == Codec.PALETTE[px[last]].to_html(false), "%s: bottom-right pixel colour" % name)
	# Each packing decodes on its own, whichever the encoder picked.
	var smile := Paint.starter("smile")
	ok(Codec.decode_indices(Codec._encode_raw(smile)) == smile, "raw packing round trip")
	ok(Codec.decode_indices(Codec._encode_runs(busy_face())) == busy_face(), "run packing round trip on a busy face")
	# Noise packed as runs is longer than any face the encoder writes, so it is refused, and the
	# encoder picks the raw packing for it instead.
	ok(Codec._encode_runs(noise(3)).length() > Codec.MAX_LENGTH, "noise as runs is over the maximum")
	ok(Codec.check(Codec._encode_runs(noise(3))) == "too long", "noise as runs is refused")
	ok(Codec.encode(noise(3)).begins_with("F1R"), "noise is written raw")
	# Not a picture: refused by the encoder.
	ok(Codec.encode(PackedByteArray()) == "", "encode refuses an empty picture")
	ok(Codec.encode(blank().slice(1)) == "", "encode refuses 1023 pixels")
	var bad := blank()
	bad[500] = 7
	ok(Codec.encode(bad) == "", "encode refuses colour 7")

func _golden() -> void:
	# Pins the format: these exact texts must never change meaning.
	var blank_code := "F1L" + "H_".repeat(14) + "HW"
	ok(Codec.encode(blank()) == blank_code, "blank face text is fixed (got %s)" % Codec.encode(blank()))
	var row_a := "K".repeat(16)
	var row_b := "R".repeat(16)
	var chk := "F1R" + (row_a + row_b).repeat(16)
	ok(Codec.encode(checker(1, 2)) == chk, "checker face text is fixed")
	# A hand-written run text: 1000 dark pixels, then 24 white.
	var hand := "F1L" + "H_".repeat(14) + "F" + "PQ"
	var px := Codec.decode_indices(hand)
	ok(px.size() == Codec.PIXELS and px[999] == 0 and px[1000] == 1 and px[1023] == 1, "hand-written run text decodes")
	ok(Codec.decode_indices("F1L" + "H_".repeat(14) + "HW") == blank(), "blank text decodes to blank")

func _size_budget() -> void:
	var worst := 0
	for s in 20:
		worst = maxi(worst, Codec.encode(noise(100 + s)).length())
	ok(worst <= Codec.MAX_LENGTH, "noise fits the maximum (%d <= %d)" % [worst, Codec.MAX_LENGTH])
	ok(Codec.MAX_LENGTH < 2000, "maximum is well under 2000 characters")
	var busy := Codec.encode(busy_face()).length()
	var simple := Codec.encode(Paint.starter("smile")).length()
	ok(busy <= Codec.MAX_LENGTH, "busy face fits")
	ok(simple < busy, "a simple face is shorter than a busy one")
	# The face inside a JSON message, as it will travel: still far under the server's 4096 bytes.
	var msg := JSON.stringify({"t": "hello", "name": "SIXTEEN_LETTERS_", "face": Codec.encode(noise(7))})
	ok(msg.to_utf8_buffer().size() < 700, "worst face in a JSON message is %d bytes" % msg.to_utf8_buffer().size())
	print("  sizes: blank %d, smile %d, frown %d, shock %d, busy %d, noise (worst case) %d characters" % [
		Codec.encode(blank()).length(), simple, Codec.encode(Paint.starter("frown")).length(),
		Codec.encode(Paint.starter("shock")).length(), busy, worst])

func _refused(code: Variant, what: String, reason := "") -> void:
	var why := Codec.check(code)
	ok(why != "", "%s: refused" % what)
	if reason != "":
		ok(why == reason, "%s: refused as '%s' (got '%s')" % [what, reason, why])
	ok(Codec.decode_indices(code).is_empty(), "%s: no pixels" % what)
	ok(Codec.decode(code) == null, "%s: no texture" % what)

func _malformed() -> void:
	var good_raw := Codec._encode_raw(Paint.starter("smile"))
	var good_runs := Codec.encode(blank())
	# Not text at all.
	_refused(null, "null", "not text")
	_refused(42, "a number", "not text")
	_refused(["F1L"], "an array", "not text")
	_refused(good_raw.to_utf8_buffer(), "bytes", "not text")
	_refused({"face": good_raw}, "a dictionary", "not text")
	# Short.
	_refused("", "empty", "too short")
	_refused("F", "one character", "too short")
	_refused("F1", "header only", "too short")
	_refused("F1R", "raw with no pixels", "wrong length")
	_refused(good_raw.left(good_raw.length() - 1), "raw one short", "wrong length")
	_refused("F1L", "runs with no pixels", "too few pixels")
	_refused(good_runs.left(good_runs.length() - 2), "runs one token short", "too few pixels")
	# Long.
	_refused(good_raw + "A", "raw one long", "too long")
	_refused("F1L" + "A".repeat(Codec.MAX_LENGTH), "runs longer than the maximum", "too long")
	_refused("F1R" + "A".repeat(100000), "100 000 characters", "too long")
	_refused(good_runs + "A", "runs one pixel too many", "too many pixels")
	_refused(good_runs + "H_", "runs 71 pixels too many", "too many pixels")
	# Wrong header.
	_refused("G" + good_raw.substr(1), "wrong magic", "not a face")
	_refused("f" + good_raw.substr(1), "lower-case magic", "not a face")
	_refused("F2" + good_raw.substr(2), "version 2", "unknown version")
	_refused("F0" + good_raw.substr(2), "version 0", "unknown version")
	_refused("FAR" + good_raw.substr(3), "version letter", "unknown version")
	_refused("F1X" + good_raw.substr(3), "unknown packing", "unknown packing")
	_refused("F1r" + good_raw.substr(3), "lower-case packing", "unknown packing")
	# Bad characters, at the start, middle and end of the pixels.
	for ch: String in [" ", "+", "/", "=", ".", "\"", "\\", "\n", "\t", String.chr(0xFFFD), "é", "ж", "😀", String.chr(127)]:
		for at: int in [3, 200, good_raw.length() - 1]:
			var s := good_raw.left(at) + ch + good_raw.substr(at + 1)
			_refused(s, "raw with character %d at %d" % [ch.unicode_at(0) if ch != "" else -1, at], "bad character")
	_refused("F1L" + "H_".repeat(14) + "H ", "runs with a bad length character", "bad character")
	_refused("F1L=" + good_runs.substr(3), "runs with a bad token", "bad character")
	# Out-of-range colour (7 is not a colour) in each place it can hide.
	_refused("F1R4" + good_raw.substr(4), "raw: colour 7 in the first pixel of a pair", "colour out of range")
	_refused("F1RH" + good_raw.substr(4), "raw: colour 7 in the second pixel of a pair", "colour out of range")
	_refused(good_raw.left(514) + "_", "raw: colour 7 in the last pixel", "colour out of range")
	_refused("F1L4" + good_runs.substr(3), "runs: a colour 7 run", "colour out of range")
	_refused("F1L" + "H_".repeat(14) + "_W", "runs: colour 7 long run", "colour out of range")
	# A long-run marker with nothing after it.
	_refused("F1L" + "H_".repeat(14) + "H", "runs cut after a long marker", "run cut short")

func _fuzz() -> void:
	# Every one-character change, and random junk, either decodes to a proper picture or is refused.
	var rng := RandomNumberGenerator.new()
	rng.seed = 2026
	var bases: Array[String] = [Codec.encode(Paint.starter("smile")), Codec._encode_raw(busy_face()),
		Codec.encode(busy_face()), Codec.encode(blank())]
	var alphabet := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_ +/=!F1RL"
	var bad := 0
	var tried := 0
	for base: String in bases:
		for i in 1500:
			var s := base
			match rng.randi_range(0, 3):
				0:
					var at := rng.randi_range(0, s.length() - 1)
					s = s.left(at) + alphabet[rng.randi_range(0, alphabet.length() - 1)] + s.substr(at + 1)
				1:
					s = s.left(rng.randi_range(0, s.length()))
				2:
					var at := rng.randi_range(0, s.length())
					s = s.left(at) + alphabet[rng.randi_range(0, alphabet.length() - 1)] + s.substr(at)
				3:
					s = ""
					for k in rng.randi_range(0, 600):
						s += alphabet[rng.randi_range(0, alphabet.length() - 1)]
			tried += 1
			var px := Codec.decode_indices(s)
			if px.is_empty():
				if Codec.check(s) == "":
					bad += 1
				continue
			var top := 0
			for v in px:
				top = maxi(top, v)
			if px.size() != Codec.PIXELS or top >= Codec.COLOURS or Codec.check(s) != "":
				bad += 1
	ok(bad == 0, "fuzz: %d changed texts all decode cleanly or are refused (%d bad)" % [tried, bad])

func _paint() -> void:
	var p := Paint.new(Codec.SIZE)
	ok(not p.can_undo(), "paint: nothing to undo at first")
	p.stroke_begin()
	p.line(Vector2(4.5, 4.5), Vector2(27.5, 4.5), 3.0, 2)
	p.stroke_end()
	ok(p.at(4, 4) == 2 and p.at(27, 4) == 2 and p.at(15, 3) == 2 and p.at(15, 5) == 2, "paint: a medium line is 3 cells thick")
	ok(p.at(15, 7) == 0, "paint: and no thicker")
	ok(p.can_undo(), "paint: the stroke can be undone")
	p.stroke_begin()
	p.stroke_end()
	p.undo()
	ok(p.px == blank(), "paint: one undo takes the whole stroke away (an empty stroke is not a step)")
	p.dab(Vector2(0.0, 0.0), 1.0, 3)
	ok(p.at(0, 0) == 3, "paint: a dab on a corner paints the cell under it")
	p.dab(Vector2(-5.0, 40.0), 5.0, 3)
	ok(p.px.count(3) == 1, "paint: dabs off the canvas paint nothing")
	p.clear()
	p.line(Vector2(0.0, 16.0), Vector2(32.0, 16.0), 2.0, 1)
	p.fill(Vector2i(5, 5), 4)
	ok(p.at(5, 5) == 4 and p.at(31, 0) == 4 and p.at(5, 25) == 0, "paint: the bucket stops at a line")
	p.undo()
	ok(p.at(5, 5) == 0, "paint: the bucket is one undo step")
	p.fill(Vector2i(5, 5), 0)
	ok(p.at(5, 5) == 0, "paint: filling with the same colour does nothing")
	for i in Paint.UNDO_MAX + 10:
		p.clear(i % 2 + 1)
	var undos := 0
	while p.undo():
		undos += 1
	ok(undos == Paint.UNDO_MAX, "paint: undo keeps the last %d steps (kept %d)" % [Paint.UNDO_MAX, undos])
	for s: String in Paint.STARTERS:
		var px := Paint.starter(s)
		var lit := Codec.PIXELS - px.count(0)
		ok(px.size() == Codec.PIXELS and lit > 120, "starter %s: drawn (%d lit cells)" % [s, lit])
		# Left-right balance: a face, roughly symmetric, not drawn off to one side.
		var left := 0
		for y in Codec.SIZE:
			for x in 16:
				if px[y * Codec.SIZE + x] != 0:
					left += 1
		ok(absf(float(left) / lit - 0.5) < 0.15, "starter %s: centred (%d of %d on the left)" % [s, left, lit])
	ok(Paint.starter("nonsense").is_empty(), "unknown starter is empty")

func _save_load() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SAVE))
	ok(Codec.load_last() == "", "save: nothing saved yet")
	var code := Codec.encode(Paint.starter("shock"))
	ok(Codec.save_last(code), "save: writes a valid face")
	ok(Codec.load_last() == code, "save: reads it back")
	ok(not Codec.save_last("F9junk"), "save: refuses an invalid face")
	ok(Codec.load_last() == code, "save: an invalid face does not replace the saved one")
	var f := FileAccess.open(TEST_SAVE, FileAccess.WRITE)
	f.store_string("F1Rnot a face")
	f.close()
	ok(Codec.load_last() == "", "save: a damaged file loads as nothing")
	f = FileAccess.open(TEST_SAVE, FileAccess.WRITE)
	f.store_string("A".repeat(100000))
	f.close()
	ok(Codec.load_last() == "", "save: a huge file loads as nothing")
	f = FileAccess.open(TEST_SAVE, FileAccess.WRITE)
	f.store_string(code + "\n")
	f.close()
	ok(Codec.load_last() == code, "save: a trailing newline is fine")

# The editor in a tree, driven by mouse events and keys as a player would.
func _editor() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SAVE))
	var ed: FaceEditor = EditorScene.instantiate()
	root.add_child(ed)
	await process_frame
	ok(ed.paint.px == Paint.starter("smile"), "editor: with nothing saved it starts from the smile")
	ed.press("clear")
	ok(ed.paint.px == blank(), "editor: clear")
	ed.press("undo")
	ok(ed.paint.px == Paint.starter("smile"), "editor: undo the clear")
	ed.press("clear")
	# Draw a line across the middle with the mouse, in green, large brush.
	ed.key(_key(KEY_5))
	ed.key(_key(KEY_BRACKETRIGHT))
	ok(ed.colour == 4 and ed.brush == 2, "editor: keys pick colour 5 and the large brush")
	_mouse_button(ed, ed.cell_to_screen(Vector2(0.5, 16.5)), true)
	for x in range(1, 32):
		_mouse_move(ed, ed.cell_to_screen(Vector2(x + 0.5, 16.5)), MOUSE_BUTTON_MASK_LEFT)
	_mouse_button(ed, ed.cell_to_screen(Vector2(31.5, 16.5)), false)
	ok(ed.paint.at(4, 16) == 4 and ed.paint.at(27, 16) == 4 and ed.paint.at(16, 14) == 4 and ed.paint.at(16, 18) == 4,
		"editor: a mouse stroke paints a thick line")
	ok(ed.paint.at(16, 10) == 0, "editor: and nothing far from it")
	# The right button erases.
	_mouse_button(ed, ed.cell_to_screen(Vector2(16.5, 16.5)), true, MOUSE_BUTTON_RIGHT)
	_mouse_button(ed, ed.cell_to_screen(Vector2(16.5, 16.5)), false, MOUSE_BUTTON_RIGHT)
	ok(ed.paint.at(16, 16) == 0 and ed.paint.at(4, 16) == 4, "editor: the right button erases")
	ed.key(_key(KEY_Z))
	ok(ed.paint.at(16, 16) == 4, "editor: Z undoes the erase")
	# Bucket the top half.
	ed.press("fill")
	ed.press("colour:2")
	_mouse_button(ed, ed.cell_to_screen(Vector2(3.5, 3.5)), true)
	_mouse_button(ed, ed.cell_to_screen(Vector2(3.5, 3.5)), false)
	ok(ed.paint.at(10, 2) == 2 and ed.paint.at(10, 28) == 0, "editor: the bucket fills above the line only")
	# A click outside the canvas changes nothing.
	var before := ed.paint.px.duplicate()
	_mouse_button(ed, Vector2(2, 2), true)
	_mouse_button(ed, Vector2(2, 2), false)
	ok(ed.paint.px == before, "editor: a click outside the canvas paints nothing")
	ed.press("starter:frown")
	ok(ed.paint.px == Paint.starter("frown"), "editor: starter button")
	# Done: the signal carries the text and a texture, and the face is remembered.
	var got := []
	ed.done.connect(func(code: String, tex: ImageTexture) -> void: got.append([code, tex]))
	ed.key(_key(KEY_ENTER))
	ok(got.size() == 1, "editor: Enter is Done")
	if got.size() == 1:
		ok(got[0][0] == Codec.encode(Paint.starter("frown")), "editor: done carries the face's text")
		ok(got[0][1] is ImageTexture and (got[0][1] as ImageTexture).get_width() == 32, "editor: done carries a texture")
	ok(Codec.load_last() == Codec.encode(Paint.starter("frown")), "editor: done saved the face")
	ed.press("clear")
	ok(ed.paint.px == Paint.starter("frown"), "editor: nothing changes after done")
	# A new editor starts from the saved face.
	var ed2: FaceEditor = EditorScene.instantiate()
	root.add_child(ed2)
	await process_frame
	ok(ed2.paint.px == Paint.starter("frown"), "editor: the next one starts from the saved face")
	var cancelled := [false]
	ed2.cancelled.connect(func() -> void: cancelled[0] = true)
	ed2.key(_key(KEY_ESCAPE))
	ok(cancelled[0], "editor: Esc is Cancel")
	# The sketchbook set-up: its own palette, no remembering, a time limit that ends it.
	var sk: FaceEditor = EditorScene.instantiate()
	sk.palette = [Color.BLACK, Color.WHITE, Color.RED]
	sk.remember = false
	sk.show_starters = false
	sk.time_limit = 0.2
	sk.title = "DRAW WHAT YOU SAW"
	var sk_got := []
	sk.done.connect(func(code: String, tex: ImageTexture) -> void: sk_got.append(code))
	root.add_child(sk)
	await process_frame
	ok(sk.paint.px == blank(), "sketchbook: starts empty")
	sk.key(_key(KEY_7))
	ok(sk.colour == 1, "sketchbook: a key past its palette does nothing (colour %d)" % sk.colour)
	sk.press("colour:9")
	ok(sk.colour == 2, "sketchbook: colours are clamped to its palette")
	for i in 40:
		await process_frame
		if not sk_got.is_empty():
			break
		await create_timer(0.02).timeout
	ok(sk_got.size() == 1, "sketchbook: the time limit ends it by itself")
	ok(Codec.load_last() == Codec.encode(Paint.starter("frown")), "sketchbook: does not touch the saved face")
	for n: Node in [ed, ed2, sk]:
		n.queue_free()
	await process_frame

func _key(code: Key) -> InputEventKey:
	var k := InputEventKey.new()
	k.keycode = code
	k.pressed = true
	return k

func _mouse_button(ed: Control, at: Vector2, down: bool, button := MOUSE_BUTTON_LEFT) -> void:
	var e := InputEventMouseButton.new()
	e.position = at
	e.button_index = button
	e.pressed = down
	ed._gui_input(e)

func _mouse_move(ed: Control, at: Vector2, mask: int) -> void:
	var e := InputEventMouseMotion.new()
	e.position = at
	e.button_mask = mask
	ed._gui_input(e)
