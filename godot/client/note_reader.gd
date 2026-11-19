# The note reader and the search's small HUD bits (FD10; client/search_view.gd has the words, sim/findables.gd and
# data/poems.json the notes). Drawn over the HUD (a child of it, the same rect), in the camcorder's pixel font:
#  - a found note or page as a slip of paper in the middle of the picture: a poem on a torn page in one hand, a
#    page on somebody's own paper with who wrote it under it. F or moving closes it (main.gd);
#  - the notes read tonight: N in the Esc menu lists them (this screen's, kept while the game is open), 1 to 9
#    opens one again;
#  - under the search prompt, the rushed search's trade; above it, the result line for 2 s;
#  - the cartons carried: a small carton and its number by the tape count (nothing drinks it yet).
extends Control

const Findables = preload("res://sim/findables.gd")

const PAPER := Color("#e8e2cf")
const PAPER_PAGE := Color("#f1ecd8")
const INK := Color("#2a2622")
const PAGE_COLS := 34

## The note or page open now ("" for none), the ones read tonight in the order first read, the list shown.
var open_id := ""
var wall_text := ""
var read: Array[String] = []
var list_on := false
## Set by main.gd each frame: the Esc menu is up; the prompt is shown; the second line, the result, the cartons.
var menu_on := false
var prompt_on := false
var prompt2 := ""
var result := ""
var juice := 0
var black := false

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_glyphs()

## The marks a page needs that the OSD font lacks.
static func _glyphs() -> void:
	PixelFont.known("A")
	PixelFont._glyphs["("] = ["00010", "00100", "01000", "01000", "01000", "00100", "00010"]
	PixelFont._glyphs[")"] = ["01000", "00100", "00010", "00010", "00010", "00100", "01000"]
	PixelFont._glyphs[";"] = ["00000", "01100", "01100", "00000", "01100", "00100", "01000"]
	PixelFont._glyphs["\""] = ["01010", "01010", "00000", "00000", "00000", "00000", "00000"]

func open(id: String) -> void:
	if Findables.note_lines(id).is_empty():
		return
	open_id = id
	wall_text = ""
	list_on = false
	if not read.has(id):
		read.append(id)

## An Annex sticky stays on its wall and is only readable here while deliberately held up.
func open_wall(id: int, text: String) -> void:
	if text.is_empty():
		return
	open_id = "annex-%d" % id
	wall_text = text
	list_on = false

func close() -> void:
	open_id = ""
	wall_text = ""

func is_open() -> bool:
	return open_id != "" or list_on

## A key press. Returns true when the reader took it.
func key(k: InputEventKey) -> bool:
	if list_on:
		if k.physical_keycode >= KEY_1 and k.physical_keycode <= KEY_9:
			var i := int(k.physical_keycode - KEY_1)
			if i < read.size():
				open(read[i])
			return true
		if k.physical_keycode == KEY_N or k.physical_keycode == KEY_F:
			list_on = false
			return true
		return false
	if open_id != "" and k.physical_keycode == KEY_F:
		close()
		return true
	if menu_on and k.physical_keycode == KEY_N:
		list_on = true
		close()
		return true
	return false

## The lines a note shows: a poem's own lines; a page's text wrapped, in capitals.
static func lines_of(id: String) -> PackedStringArray:
	var ls := Findables.note_lines(id)
	if Findables.is_poem(id):
		return ls
	if ls.is_empty():
		return ls
	return PixelFont.wrap(ls[0].to_upper(), PAGE_COLS)

static func _author(id: String) -> String:
	for e: Dictionary in Findables.data().get("pages", []):
		if str(e["id"]) == id:
			return str(e.get("author", "")).to_upper()
	return ""

static func attribution_rows(id: String) -> PackedStringArray:
	return PixelFont.wrap(_author(id), PAGE_COLS)

func _process(_d: float) -> void:
	queue_redraw()

func _scale() -> float:
	return maxf(2.0, floor(size.y / 320.0))

func _draw() -> void:
	if black:
		return
	var px := _scale()
	if prompt_on and prompt2 != "":
		var w := PixelFont.width(prompt2) * px
		var at := Vector2(floorf((size.x - w) * 0.5), floorf(size.y * 0.62) + 16 * px)
		draw_rect(Rect2(at - Vector2(3, 2) * px, Vector2(w + 6 * px, 11 * px)), Color(0, 0, 0, 0.4))
		PixelFont.draw_shadowed(self, prompt2, at, px, Color("#d8ddd9"))
	if result != "":
		var p2 := px * 1.5
		var w2 := PixelFont.width(result) * p2
		PixelFont.draw_shadowed(self, result, Vector2(floorf((size.x - w2) * 0.5), floorf(size.y * 0.53)), p2, Color("#ffd27a"))
	if juice > 0:
		_draw_carton(px)
	if open_id != "":
		_draw_card(px)
	elif list_on:
		_draw_list(px)
	elif menu_on:
		var t := "N  NOTES READ TONIGHT: %d" % read.size()
		PixelFont.draw_shadowed(self, t, Vector2(maxf(size.x * 0.06, 16.0), size.y - maxf(size.y * 0.06, 12.0) - 9 * px), px, Color("#ffd27a"))

## A small carton of juice and how many, by the tape count (bottom right).
func _draw_carton(px: float) -> void:
	var margin := Vector2(maxf(size.x * 0.06, 16.0), maxf(size.y * 0.06, 12.0))
	var label := "x%d" % juice
	var lw := PixelFont.width(label) * px
	var base := Vector2(size.x - margin.x - lw, size.y - margin.y - 9 * px - 26 * px)
	PixelFont.draw_shadowed(self, label, base, px, Color("#f4f4ec"))
	var c := base + Vector2(-9 * px, -2 * px)
	# The carton: a box with a gabled top and a straw.
	draw_rect(Rect2(c + Vector2(0, 3 * px), Vector2(6 * px, 8 * px)), Color(0, 0, 0, 0.5))
	draw_rect(Rect2(c + Vector2(-px, 2 * px), Vector2(6 * px, 8 * px)), Color("#f2efe6"))
	draw_rect(Rect2(c + Vector2(-px, 5 * px), Vector2(6 * px, 3 * px)), Color("#e8a23a"))
	draw_colored_polygon(PackedVector2Array([c + Vector2(-px, 2 * px), c + Vector2(5 * px, 2 * px), c + Vector2(2 * px, -px)]), Color("#d9d4c6"))
	draw_rect(Rect2(c + Vector2(3 * px, -4 * px), Vector2(px, 4 * px)), Color("#d84a3a"))

## The slip of paper: a poem torn at the top, a page square with its writer under it.
func _draw_card(px: float) -> void:
	var lines := _open_lines()
	var poem := Findables.is_poem(open_id)
	var attribution := PackedStringArray() if poem else attribution_rows(open_id)
	var cols := 0 if poem else PAGE_COLS
	for l in lines:
		cols = maxi(cols, l.length())
	var lp := px
	var w := (cols * 6 + 16) * lp
	var h := (lines.size() * 11 + 26 + attribution.size() * 11) * lp
	var at := Vector2(floorf((size.x - w) * 0.5), floorf((size.y - h) * 0.42))
	draw_rect(Rect2(at + Vector2(3, 4) * px, Vector2(w, h)), Color(0, 0, 0, 0.5))
	var paper := Color("#f0d985") if wall_text != "" else (PAPER if poem else PAPER_PAGE)
	draw_rect(Rect2(at, Vector2(w, h)), paper)
	if poem:
		# The torn top edge.
		var n := int(w / (4 * px))
		for i in n:
			draw_rect(Rect2(at + Vector2(i * 4 * px, 0), Vector2(2 * px, (i % 3) * px)), Color(0.1, 0.1, 0.1, 0.55))
	else:
		# Ruled lines, as on a pad.
		for i in lines.size():
			draw_rect(Rect2(at + Vector2(4 * lp, (10 + i * 11 + 9) * lp), Vector2(w - 8 * lp, lp * 0.5)), Color(0.55, 0.65, 0.8, 0.5))
	for i in lines.size():
		PixelFont.draw(self, lines[i], at + Vector2(8, 10 + i * 11) * lp, lp, INK)
	var y := (10 + lines.size() * 11 + 4) * lp
	for line in attribution:
		PixelFont.draw(self, line, at + Vector2(8 * lp, y), lp, Color(0.45, 0.4, 0.36))
		y += 11 * lp
	var foot := "F OR MOVE TO PUT IT DOWN"
	PixelFont.draw_shadowed(self, foot, Vector2(floorf((size.x - PixelFont.width(foot) * px) * 0.5), at.y + h + 8 * px), px, Color("#f4f4ec"))

## The notes read tonight.
func _draw_list(px: float) -> void:
	var rows: Array[String] = ["NOTES READ TONIGHT"]
	if read.is_empty():
		rows.append("NONE YET")
	for i in mini(read.size(), 9):
		var ls := lines_of(read[i])
		var first := ls[0] if not ls.is_empty() else read[i]
		rows.append("%d  %s" % [i + 1, first.left(34)])
	rows.append("")
	rows.append("1-9 TO READ   N TO CLOSE")
	var w := 0
	for r in rows:
		w = maxi(w, PixelFont.width(r))
	var at := Vector2(floorf((size.x - (w + 16) * px) * 0.5), floorf(size.y * 0.25))
	draw_rect(Rect2(at, Vector2((w + 16) * px, (rows.size() * 12 + 12) * px)), Color(0, 0, 0, 0.75))
	for i in rows.size():
		PixelFont.draw_shadowed(self, rows[i], at + Vector2(8, 8 + i * 12) * px, px, Color("#ffd27a") if i == 0 else Color("#f4f4ec"))

func _open_lines() -> PackedStringArray:
	return PixelFont.wrap(wall_text.to_upper(), PAGE_COLS) if wall_text != "" else lines_of(open_id)

func describe() -> Dictionary:
	return {"open": open_id, "lines": Array(_open_lines()) if open_id != "" else [], "wallText": wall_text, "attribution": Array(attribution_rows(open_id)), "read": read.duplicate(), "list": list_on,
		"prompt2": prompt2 if prompt_on else "", "result": result, "juice": juice}
