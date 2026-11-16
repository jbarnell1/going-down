# What is drawn crisp over the tape picture, in the camcorder's pixel font: the on-screen display
# (PLAY, the tape counter, the value of the tapes held), the announcer's subtitles, the lift prompt,
# the black cut and the line of being taken, and the end screen. Like src/render/osd.ts,
# endScreen.ts, caughtFx.ts and the subtitles in src/game/announcer.ts.
class_name Hud
extends Control

const JUMP_MS := 900
const JUMP_BLINK_MS := 150

var start_sec := 1500
var t0 := 0
var tape_count := 0
var tape_value := 0.0
var _jump_at := -100000
var subtitle := ""
var prompt := ""
var black := false
var went_down := false
var end_lines: Array = []      # [{text, strong}]
var center_note := ""
var osd_on := true
var tape_text := ""

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	t0 = Time.get_ticks_msec()

func set_seed(seed: String) -> void:
	# The counter starts part-way into the tape, picked from the seed (this is not the first recording).
	start_sec = 1500 + (hash(seed) & 0x7fffffff) % 4800

func set_tapes(count: int, value: float) -> void:
	if floor(value) > floor(tape_value):
		_jump_at = Time.get_ticks_msec()
	tape_count = count
	tape_value = value

func _process(_d: float) -> void:
	# Parented to a plain Node, so it follows the window itself.
	var want := get_viewport_rect().size
	if size != want:
		position = Vector2.ZERO
		size = want
	queue_redraw()

func _scale() -> float:
	return maxf(2.0, floor(size.y / 320.0))

func _draw() -> void:
	var px := _scale()
	var now := Time.get_ticks_msec()
	if black:
		draw_rect(Rect2(Vector2.ZERO, size), Color.BLACK)
	if not end_lines.is_empty():
		_draw_end()
		return
	if osd_on:
		var blink_on := (now / 700) % 2 == 0
		var top := "PLAY >" if blink_on else "PLAY  "
		var tw := PixelFont.width(top) * px
		var margin := Vector2(maxf(size.x * 0.06, 16.0), maxf(size.y * 0.06, 12.0))
		PixelFont.draw_shadowed(self, top, Vector2(size.x - margin.x - PixelFont.width("PLAY >") * px, margin.y), px, Color("#f4f4ec"))
		var s := start_sec + (now - t0) / 1000
		var bottom := "SP %d:%02d:%02d" % [s / 3600, (s / 60) % 60, s % 60]
		var bw := PixelFont.width(bottom) * px
		var by := size.y - margin.y - 9 * px
		PixelFont.draw_shadowed(self, bottom, Vector2(size.x - margin.x - bw, by), px, Color("#f4f4ec"))
		var since := now - _jump_at
		var blink_off := since < JUMP_MS and (since / JUMP_BLINK_MS) % 2 == 1
		tape_text = ""
		if (tape_count > 0 or tape_value > 0.0):
			tape_text = "#x%d %04d" % [tape_count, int(floor(tape_value))]
			if not blink_off:
				PixelFont.draw_shadowed(self, tape_text, Vector2(size.x - margin.x - PixelFont.width(tape_text) * px, by - 12 * px), px, Color("#f4f4ec"))
	if prompt != "" and not black:
		var pw := PixelFont.width(prompt) * px
		var pp := Vector2((size.x - pw) * 0.5, size.y * 0.62)
		draw_rect(Rect2(pp - Vector2(4, 3) * px, Vector2(pw + 8 * px, 13 * px)), Color(0, 0, 0, 0.45))
		PixelFont.draw_shadowed(self, prompt, pp, px, Color("#f4f4ec"))
	if went_down:
		var t := "YOU WENT DOWN"
		var p2 := px * 2.0
		PixelFont.draw_shadowed(self, t, Vector2((size.x - PixelFont.width(t) * p2) * 0.5, size.y * 0.42), p2, Color("#f4f4ec"))
	if center_note != "":
		PixelFont.draw_shadowed(self, center_note, Vector2((size.x - PixelFont.width(center_note) * px) * 0.5, size.y * 0.3), px, Color("#ffd27a"))
	if subtitle != "":
		_draw_subtitle(px)

func _draw_subtitle(_px: float) -> void:
	var text := subtitle.to_upper().replace("’", "'").replace("‘", "'").replace("…", "...")
	var clean := ""
	for ch: String in text:
		if ch == " " or _known(ch):
			clean += ch
	var rows := PixelFont.wrap(clean, 38)
	var w := 10
	for r in rows:
		w = maxi(w, PixelFont.width(r))
	w += 6
	var h := rows.size() * 10 + 4
	var sc := clampf(floor(size.x * 0.92 / w), 1.0, 4.0)
	var origin := Vector2((size.x - w * sc) * 0.5, size.y * 0.91 - h * sc)
	draw_rect(Rect2(origin, Vector2(w, h) * sc), Color(0, 0, 0, 0.45))
	for i in rows.size():
		var r: String = rows[i]
		var x := floorf((w - PixelFont.width(r)) / 2.0)
		var p := origin + Vector2(x, 2 + i * 10) * sc
		PixelFont.draw(self, r, p + Vector2(sc, sc), sc, Color(0, 0, 0, 0.7))
		PixelFont.draw(self, r, p, sc, Color("#f4f4ec"))

func _known(ch: String) -> bool:
	return PixelFont.known(ch)

func _draw_end() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.02, 0.025))
	var w := 10
	for l: Dictionary in end_lines:
		w = maxi(w, PixelFont.width(l.text))
	w += 4
	var h := end_lines.size() * 11 + 2
	var sc := maxf(2.0, floor(minf(size.x * 0.8 / w, size.y * 0.7 / h)))
	var origin := Vector2((size.x - w * sc) * 0.5, (size.y - h * sc) * 0.5)
	for i in end_lines.size():
		var l: Dictionary = end_lines[i]
		var x := floorf((w - PixelFont.width(l.text)) / 2.0)
		var p := origin + Vector2(x, 2 + i * 11) * sc
		PixelFont.draw(self, l.text, p + Vector2(sc, sc), sc, Color(0, 0, 0, 0.6))
		PixelFont.draw(self, l.text, p, sc, Color("#ffd27a") if l.get("strong", false) else Color("#d8ddd9"))
