# What is drawn crisp over the tape picture, in the camcorder's pixel font: the on-screen display
# (PLAY, the tape counter, the value of the tapes held), the announcer's subtitles, the lift prompt,
# the black cut and the line of being taken, being down (the timer) and out, and the end screen. Like src/render/osd.ts,
# endScreen.ts, caughtFx.ts and the subtitles in src/game/announcer.ts.
class_name Hud
extends Control

const JUMP_MS := 900
const JUMP_BLINK_MS := 150
## Two-watcher Stillness (docs/floors/traits-and-hiding.md section 1, "What the screen shows"; T19a): the eye
## marks at the bottom of the picture. The owner has not yet said whether to show them: false hides them
## everywhere, and nothing else changes.
const EYE_MARKS := true

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
## The menu shown while the mouse is free (Esc, or before the first click): the controls.
## The game does not stop behind it; with friends in the run it cannot.
var menu_on := false
const MENU_ROWS: Array[Array] = [
	["W A S D", "WALK"],
	["SHIFT", "SPRINT"],
	["CTRL OR C", "CREEP"],
	["MOUSE", "LOOK"],
	["E", "INSTRUMENT OUT / AWAY"],
	["RIGHT MOUSE", "HOLD THE INSTRUMENT UP"],
	["F", "CALL / HOLD DOORS / PICK UP / SLEEP / HIDE"],
	["HOLD F BY A FRIEND", "HELP THEM UP"],
	["W IN A HIDE", "LEAN TO THE GAP"],
	["T", "TAPE LOOK ON / OFF"],
	["HOLD R", "EMOTE WHEEL: AIM, LET GO"],
	["TAP R", "CLOSE THE WHEEL"],
	["ESC", "THIS MENU"],
]
## The menu's setting row: the announcer's hints (H; client/hints.gd, kept per player).
var hints_on := true
## The line under the menu (the start screen says how to go back instead).
var menu_foot := "CLICK TO PLAY"
## Name tags over other players: [{text, pos (window pixels, the text's bottom centre), alpha}].
var tags: Array = []
## The emote wheel: open, the labels clockwise from the top, the one aimed at (-1: none).
var wheel_on := false
var wheel_labels: Array = []
var wheel_sel := -1
## A short line under the prompt (the emote you just sent).
var note := ""
## The day loop. The bed count over the cell doors ("IN BED 1 OF 2", the lights-out countdown), drawn
## at the top; how far the bunk prompt's hold has got (0..1, or -1 for no bar); a big line in the middle
## ("LIGHTS OUT", "DAY 2"); black over the picture (0..1: lights out going to sleep); the report board,
## read crisp beside the picture while standing in the bank room (one string per line, first the title).
var count_text := ""
var prompt_fill := -1.0
var big_note := ""
var fade := 0.0
var board_lines: Array = []
## The Playroom (client/hide_view.gd): what started the count, under the count line; a line of what you
## can do here (F to hide, W to peek, LOWER IT); the health bar (0..100; below 0 not shown) with its
## rates printed beside it (North Star: the numbers are always printed).
var count_by := ""
var seek_note := ""
var health := -1.0
var health_rates := ""
## The floor quota (client/quota_view.gd): the call panel's words, printed under the prompt while the
## call button is in reach or a refusal flashes; its tone ("count", "met", "refused").
var quota_line := ""
var quota_tone := ""
## Down first, then out (client/down_view.gd). Down: the timer in big red ("DOWN  7"), how much of it is
## left (0..1, a bar that drains; below 0 not shown), a line of what can happen now, a second line (what
## you can do), and how far a heal has got (0..1, or -1 for none). Out: the screen goes dark and says so.
var down_head := ""
var down_left := -1.0
var down_line := ""
var down_line2 := ""
var down_heal := -1.0
var out_on := false
var out_lines: Array = []
## The eye marks (see EYE_MARKS), from the frame: {on (the resident is in your view), need (1 or 2), lit,
## all}, or {} for none. One mark per watcher needed; one lit per watcher the host counts, your own the frame
## you look; all lit, the row closes into a bar (it is held); one of two lit, the second pulses ("one more").
var eyes: Dictionary = {}

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
	if fade > 0.0:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, clampf(fade, 0.0, 1.0)))
	if out_on and not black:
		_draw_out(px)
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
		if prompt_fill >= 0.0:
			# The hold's progress, under the prompt.
			var bar := Rect2(pp + Vector2(0, 11 * px), Vector2(pw, 2 * px))
			draw_rect(bar, Color(0, 0, 0, 0.55))
			draw_rect(Rect2(bar.position, Vector2(bar.size.x * clampf(prompt_fill, 0.0, 1.0), bar.size.y)), Color("#ffd27a"))
	if quota_line != "" and not black:
		_draw_quota(px, now)
	if not board_lines.is_empty() and not black:
		_draw_board(px)
	if count_text != "" and not black:
		var cw := PixelFont.width(count_text) * px
		var cp := Vector2(floorf((size.x - cw) * 0.5), maxf(size.y * 0.06, 12.0))
		draw_rect(Rect2(cp - Vector2(4, 3) * px, Vector2(cw + 8 * px, 13 * px)), Color(0, 0, 0, 0.45))
		PixelFont.draw_shadowed(self, count_text, cp, px, Color("#ffd27a"))
	if count_by != "" and not black:
		var bw2 := PixelFont.width(count_by) * px
		var bp := Vector2(floorf((size.x - bw2) * 0.5), maxf(size.y * 0.06, 12.0) + 14 * px)
		PixelFont.draw_shadowed(self, count_by, bp, px, Color("#f4f4ec"))
	if seek_note != "" and not black and prompt == "":
		var sw := PixelFont.width(seek_note) * px
		var sp := Vector2(floorf((size.x - sw) * 0.5), floorf(size.y * 0.66))
		draw_rect(Rect2(sp - Vector2(4, 3) * px, Vector2(sw + 8 * px, 13 * px)), Color(0, 0, 0, 0.45))
		PixelFont.draw_shadowed(self, seek_note, sp, px, Color("#f4f4ec"))
	if health >= 0.0 and not black:
		_draw_health(px)
	if down_head != "" and not black:
		_draw_down(px)
	if EYE_MARKS and not black and not eyes.is_empty() and bool(eyes.get("on", false)):
		_draw_eyes(px, now)
	if big_note != "" and not black:
		var p3 := px * 2.0
		PixelFont.draw_shadowed(self, big_note, Vector2(floorf((size.x - PixelFont.width(big_note) * p3) * 0.5), floorf(size.y * 0.42)), p3, Color("#f4f4ec"))
	if went_down:
		var t := "YOU WENT DOWN"
		var p2 := px * 2.0
		PixelFont.draw_shadowed(self, t, Vector2((size.x - PixelFont.width(t) * p2) * 0.5, size.y * 0.42), p2, Color("#f4f4ec"))
	if not black and not wheel_on and not out_on:   # the wheel's labels sit where the tags would
		_draw_tags(px)
	if note != "" and not black:
		PixelFont.draw_shadowed(self, note, Vector2((size.x - PixelFont.width(note) * px) * 0.5, size.y * 0.7), px, Color("#ffd27a"))
	if center_note != "":
		PixelFont.draw_shadowed(self, center_note, Vector2((size.x - PixelFont.width(center_note) * px) * 0.5, size.y * 0.3), px, Color("#ffd27a"))
	if subtitle != "":
		_draw_subtitle(px)
	if wheel_on and not black:
		_draw_wheel(px)
	if menu_on and not black:
		_draw_menu()

## The call panel's words under the prompt: amber while counting, green once met, red (blinking) when a
## press was refused.
func _draw_quota(px: float, now: int) -> void:
	var qw := PixelFont.width(quota_line) * px
	var qp := Vector2(floorf((size.x - qw) * 0.5), floorf(size.y * 0.62) + (15 * px if prompt != "" else 0.0))
	draw_rect(Rect2(qp - Vector2(4, 3) * px, Vector2(qw + 8 * px, 13 * px)), Color(0, 0, 0, 0.55))
	var ink := Color("#ffd27a")
	if quota_tone == "met":
		ink = Color("#9fe0a0")
	elif quota_tone == "refused":
		ink = Color("#ff7a6a") if (now / 160) % 2 == 0 else Color("#7a2a22")
	PixelFont.draw_shadowed(self, quota_line, qp, px, ink)

## Down: the timer big and red near the top with a bar draining under it, then the lines under the middle
## (where a prompt would be) and, while a crewmate holds F beside you, their hold's bar.
func _draw_down(px: float) -> void:
	var red := Color("#ff7a6a")
	var p2 := px * 2.0
	var hw := PixelFont.width(down_head) * p2
	var hp := Vector2(floorf((size.x - hw) * 0.5), floorf(size.y * 0.2))
	PixelFont.draw_shadowed(self, down_head, hp, p2, red)
	if down_left >= 0.0:
		var bw := 90.0 * px
		var bar := Rect2(Vector2(floorf((size.x - bw) * 0.5), hp.y + 20 * px), Vector2(bw, 3 * px))
		draw_rect(bar.grow(px), Color(0, 0, 0, 0.6))
		draw_rect(Rect2(bar.position, Vector2(bw * clampf(down_left, 0.0, 1.0), bar.size.y)), red)
	var y := floorf(size.y * 0.5)
	for l: String in [down_line, down_line2]:
		if l == "":
			continue
		var lw := PixelFont.width(l) * px
		var lp := Vector2(floorf((size.x - lw) * 0.5), y)
		draw_rect(Rect2(lp - Vector2(4, 3) * px, Vector2(lw + 8 * px, 13 * px)), Color(0, 0, 0, 0.45))
		PixelFont.draw_shadowed(self, l, lp, px, Color("#f4f4ec") if l == down_line else Color("#ffd27a"))
		if l == down_line and down_heal >= 0.0:
			var hb := Rect2(lp + Vector2(0, 11 * px), Vector2(lw, 2 * px))
			draw_rect(hb, Color(0, 0, 0, 0.55))
			draw_rect(Rect2(hb.position, Vector2(hb.size.x * clampf(down_heal, 0.0, 1.0), hb.size.y)), Color("#9fe0a0"))
		y += 16 * px

## Out: the picture goes nearly black; the lines in the middle, the first big and red.
func _draw_out(px: float) -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.01, 0.0, 0.0, 0.93))
	var y := floorf(size.y * 0.38)
	for i in out_lines.size():
		var l := str(out_lines[i])
		var sc := px * 2.0 if i == 0 else px
		var lw := PixelFont.width(l) * sc
		PixelFont.draw_shadowed(self, l, Vector2(floorf((size.x - lw) * 0.5), y), sc, Color("#ff7a6a") if i == 0 else Color("#d8ddd9"))
		y += (24 if i == 0 else 13) * px
## The eye marks, bottom middle (see `eyes`): a pale outline each, amber with a pupil when lit, joined by a
## bar when every one is; a lone lit one of two makes the other pulse.
func _draw_eyes(px: float, now: int) -> void:
	var need := clampi(int(eyes.get("need", 1)), 1, 2)
	var lit := clampi(int(eyes.get("lit", 0)), 0, need)
	var all := lit >= need
	var w := 13.0 * px
	var h := 7.0 * px
	var gap := 7.0 * px
	var total := need * w + (need - 1) * gap
	var y := floorf(size.y * 0.84)
	if subtitle != "":
		# Above the subtitles, never over them.
		y = minf(y, floorf(_subtitle_top() - h * 0.5 - 6.0 * px))
	var x0 := floorf((size.x - total) * 0.5)
	var amber := Color("#ffd27a")
	var pale := Color(0.96, 0.96, 0.92, 0.55)
	if all:
		var bar := Rect2(Vector2(x0 - 4.0 * px, y - h * 0.5 - 3.0 * px), Vector2(total + 8.0 * px, h + 6.0 * px))
		draw_rect(bar, Color(0, 0, 0, 0.5))
		draw_rect(bar, amber, false, px)
		draw_rect(Rect2(Vector2(x0, y - px * 0.5), Vector2(total, px)), amber)
	for i in need:
		var c := Vector2(x0 + i * (w + gap) + w * 0.5, y)
		var on := i < lit
		var col := amber if on else pale
		if not on and need == 2 and lit == 1:
			col = Color(amber, 0.3 + 0.6 * (0.5 + 0.5 * sin(float(now) * 0.012)))
		_draw_eye(c, w, h, col, on, px)

## One almond eye centred on `c`, `w` by `h`: outlined, with a pupil when `open`.
func _draw_eye(c: Vector2, w: float, h: float, col: Color, open: bool, px: float) -> void:
	var n := 10
	var pts := PackedVector2Array()
	for k in n + 1:
		var u := float(k) / n
		pts.append(c + Vector2(-w * 0.5 + w * u, -h * 0.5 * sin(PI * u)))
	for k in range(n - 1, 0, -1):
		var u := float(k) / n
		pts.append(c + Vector2(-w * 0.5 + w * u, h * 0.5 * sin(PI * u)))
	var ring := pts.duplicate()
	ring.append(pts[0])
	draw_colored_polygon(pts, Color(0, 0, 0, 0.45))
	draw_polyline(ring, Color(0, 0, 0, 0.7), px * 2.0)
	draw_polyline(ring, col, px)
	if open:
		draw_circle(c, h * 0.3, col)

## The health bar, bottom left: HEALTH and the number, the bar, the rates under it.
func _draw_health(px: float) -> void:
	var margin := Vector2(maxf(size.x * 0.06, 16.0), maxf(size.y * 0.06, 12.0))
	var label := "HEALTH %d" % ceili(health)
	var bar_w := 80.0 * px
	var y := size.y - margin.y - 44 * px
	var low := health < 30.0
	PixelFont.draw_shadowed(self, label, Vector2(margin.x, y), px, Color("#ff7a6a") if low else Color("#f4f4ec"))
	var bar := Rect2(Vector2(margin.x, y + 10 * px), Vector2(bar_w, 4 * px))
	draw_rect(bar.grow(px), Color(0, 0, 0, 0.6))
	draw_rect(Rect2(bar.position, Vector2(bar_w * clampf(health / 100.0, 0.0, 1.0), bar.size.y)), Color("#ff7a6a") if low else Color("#9fe0a0"))
	if health_rates != "":
		PixelFont.draw_shadowed(self, health_rates, Vector2(margin.x, y + 17 * px), px, Color("#d8ddd9"))

## The report board, crisp, down the left of the picture: a dark card, the title amber.
func _draw_board(px: float) -> void:
	var w := 10
	for l: Variant in board_lines:
		w = maxi(w, PixelFont.width(str(l)))
	var line := 10
	var h := board_lines.size() * line + 6
	var origin := Vector2(maxf(size.x * 0.04, 8.0), floorf(size.y * 0.16))
	draw_rect(Rect2(origin - Vector2(5, 4) * px, Vector2(w + 10, h + 4) * px), Color(0.02, 0.03, 0.025, 0.82))
	for i in board_lines.size():
		PixelFont.draw_shadowed(self, str(board_lines[i]), origin + Vector2(0, i * line) * px, px, Color("#ffd27a") if i == 0 else Color("#d8f0dc"))

func _draw_tags(px: float) -> void:
	for t: Dictionary in tags:
		var text: String = t["text"]
		var a := float(t["alpha"])
		if a <= 0.01:
			continue
		# Half as big again as the HUD (main.gd), whole pixels; a dark outline all round reads on any wall.
		var tp := roundf(px * float(t.get("size", 1.0)))
		var w := PixelFont.width(text) * tp
		var p: Vector2 = t["pos"]
		var at := Vector2(floorf(p.x - w * 0.5), floorf(p.y - 9 * tp))
		var o := maxf(1.0, floorf(tp * 0.5))
		var ink := Color(0, 0, 0, 0.8 * a)
		for dv: Vector2 in [Vector2(-o, 0), Vector2(o, 0), Vector2(0, -o), Vector2(0, o), Vector2(-o, -o), Vector2(o, -o), Vector2(-o, o), Vector2(o, o)]:
			PixelFont.draw(self, text, at + dv, tp, ink)
		PixelFont.draw(self, text, at, tp, Color(0.96, 0.96, 0.92, a))

## Six labels round the middle of the screen, the one aimed at lit; a line toward it.
func _draw_wheel(px: float) -> void:
	var c := size * 0.5
	var n := wheel_labels.size()
	if n == 0:
		return
	var r := minf(size.x, size.y) * 0.3
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.35))
	draw_arc(c, r * 0.22, 0.0, TAU, 32, Color(0.95, 0.95, 0.9, 0.5), px)
	for i in n:
		var ang := -PI / 2.0 + TAU * i / n
		var p := c + Vector2(cos(ang), sin(ang)) * r
		var label: String = wheel_labels[i]
		var w := PixelFont.width(label) * px
		var on := i == wheel_sel
		var box := Rect2(p - Vector2(w * 0.5 + 4 * px, 6 * px), Vector2(w + 8 * px, 13 * px))
		draw_rect(box, Color(0.02, 0.02, 0.025, 0.85))
		draw_rect(box, Color("#ffd27a") if on else Color(0.55, 0.57, 0.55), false, px)
		PixelFont.draw_shadowed(self, label, Vector2(floorf(p.x - w * 0.5), floorf(p.y - 3 * px)), px, Color("#ffd27a") if on else Color("#f4f4ec"))
		if on:
			draw_line(c + Vector2(cos(ang), sin(ang)) * r * 0.22, c + Vector2(cos(ang), sin(ang)) * (r - 10 * px), Color("#ffd27a"), px)
	var mid := "EMOTE"
	PixelFont.draw_shadowed(self, mid, Vector2(floorf(c.x - PixelFont.width(mid) * px * 0.5), floorf(c.y - 3 * px)), px, Color("#f4f4ec"))

## The menu's rows: the controls, then the settings.
func menu_rows() -> Array[Array]:
	var rows: Array[Array] = MENU_ROWS.duplicate()
	rows.append(["H", "HINTS: ON" if hints_on else "HINTS: OFF"])
	return rows

func _draw_menu() -> void:
	var key_w := 0
	var act_w := 0
	var all_rows := menu_rows()
	for row: Array in all_rows:
		var key: String = row[0]
		var act: String = row[1]
		key_w = maxi(key_w, PixelFont.width(key))
		act_w = maxi(act_w, PixelFont.width(act))
	var title := "CONTROLS"
	var foot := menu_foot
	var gap := 10
	var w := key_w + gap + act_w + 16
	var line := 12
	var h := (all_rows.size() + 4) * line + 8
	var sc := maxf(1.0, floor(minf(size.x * 0.92 / w, size.y * 0.86 / h)))
	var origin := Vector2(floorf((size.x - w * sc) * 0.5), floorf((size.y - h * sc) * 0.5))
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.5))
	draw_rect(Rect2(origin, Vector2(w, h) * sc), Color(0.02, 0.02, 0.025, 0.88))
	var amber := Color("#ffd27a")
	var pale := Color("#f4f4ec")
	PixelFont.draw_shadowed(self, title, origin + Vector2(floorf((w - PixelFont.width(title)) / 2.0), 6) * sc, sc, amber)
	for i in all_rows.size():
		var row: Array = all_rows[i]
		var key: String = row[0]
		var act: String = row[1]
		var y := 6 + (i + 2) * line
		PixelFont.draw_shadowed(self, key, origin + Vector2(8 + key_w - PixelFont.width(key), y) * sc, sc, amber)
		PixelFont.draw_shadowed(self, act, origin + Vector2(8 + key_w + gap, y) * sc, sc, pale)
	if (Time.get_ticks_msec() / 600) % 2 == 0:
		PixelFont.draw_shadowed(self, foot, origin + Vector2(floorf((w - PixelFont.width(foot)) / 2.0), 6 + (all_rows.size() + 3) * line) * sc, sc, amber)

## The subtitle's rows as drawn (upper case, only the font's characters, wrapped).
func _subtitle_rows() -> PackedStringArray:
	var text := subtitle.to_upper().replace("’", "'").replace("‘", "'").replace("…", "...")
	# A second caption line (the waiting car's names) starts on its own row.
	var rows := PackedStringArray()
	for part: String in text.split("\n"):
		var clean := ""
		for ch: String in part:
			if ch == " " or _known(ch):
				clean += ch
		rows.append_array(PixelFont.wrap(clean, 38))
	return rows

## Where the subtitle box's top edge is (window pixels).
func _subtitle_top() -> float:
	var rows := _subtitle_rows()
	var w := 10
	for r in rows:
		w = maxi(w, PixelFont.width(r))
	w += 6
	var sc := clampf(floor(size.x * 0.92 / w), 1.0, 4.0)
	return size.y * 0.91 - (rows.size() * 10 + 4) * sc

func _draw_subtitle(_px: float) -> void:
	var rows := _subtitle_rows()
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
