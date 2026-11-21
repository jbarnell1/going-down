# What is drawn crisp over the tape picture, in the camcorder's pixel font: the on-screen display
# (PLAY, the tape counter, the value of the tapes held), the announcer's subtitles, the lift prompt,
# the black cut and the line of being taken, being down (the timer) and out, and the end screen. Like src/render/osd.ts,
# endScreen.ts, caughtFx.ts and the subtitles in src/game/announcer.ts.
class_name Hud
extends Control

const JUMP_MS := 900
const JUMP_BLINK_MS := 150
const Nerve = preload("res://sim/nerve.gd")
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
## The mouse is free on entering the run (the browser) or after the window lost it: one undimmed line, CLICK
## TO LOOK, where the controls menu used to show (findables-and-day.md section 2; Esc still shows the menu).
var click_to_look := false
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
	# The four-slot inventory (S1, client/inventory_view.gd).
	["1 2 3 4 / WHEEL", "PICK WHAT YOU HOLD"],
	["G", "DROP WHAT YOU HOLD"],
	# The shop's items (S2, client/shop_view.gd): the left mouse button uses the one in your hand.
	["LEFT MOUSE", "USE WHAT YOU HOLD"],
	["F FACING A FRIEND", "GIVE THEM WHAT YOU HOLD"],
	["W IN A HIDE", "LEAN TO THE GAP"],
	["T", "TAPE LOOK ON / OFF"],
	["HOLD R", "EMOTE WHEEL: AIM, LET GO"],
	["TAP R", "CLOSE THE WHEEL"],
	# HUD1: the camcorder's DISPLAY button: every count, rate and the nerve while held.
	["HOLD TAB", "DISPLAY: EVERY COUNT"],
	["ESC", "THIS MENU"],
]
## The host's tools on the card (PT6), only where each works (client/main.gd _host_tools_hud): F6 in a game played
## alone; F8 in any game, live for the host ("host"), read-only for everyone else ("guest"), "" for none.
const F6_ROW: Array = ["F6", "JUMP TO A FLOOR"]
const F8_HOST_ROW: Array = ["F8", "HOST SETTINGS"]
const F8_GUEST_ROW: Array = ["F8", "SEE THE HOST'S SETTINGS"]
var f6_row := false
var f8_row := ""
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
## The viewer's host reading and four passive rates. Empty when the preview is off.
var nerve: Array = []
## The tuned Playroom (T15m): how angry the Minder is, 0..1 (below 0 not shown), the host's own number;
## what fills it, printed under it.
var anger := -1.0
var anger_rates := ""
## The party table (T15h, client/hide_view.gd party_warning): who is seated and that the lift leaves without
## them, on every screen while anyone is ("" none).
var party_note := ""
## The floor quota (client/quota_view.gd): the call panel's words, printed under the prompt while the
## call button is in reach or a refusal flashes; its tone ("count", "met", "refused").
var quota_line := ""
var quota_tone := ""
## Down first, then out (client/down_view.gd). Down: `down_head` non-empty says you are down (DR1, the owner on 20
## Nov: "Instead of text, float an O in the center of player screen that slowly runs out": its words are no longer
## drawn); how much of the time is left (0..1) is a red ring in the centre that empties clockwise from the top (below
## 0 not shown); a line of what can happen now, a second line (what you can do), and how far a heal has got (0..1, or
## -1 for none). Out: the screen goes dark and says so.
var down_head := ""
var down_left := -1.0
var down_line := ""
var down_line2 := ""
var down_heal := -1.0
var out_on := false
var out_lines: Array = []
## DV1: out and watching a crewmate (client/crew_watch.gd): the out screen's words in one line, red, near the top.
var watch_note := ""
## The eye marks (see EYE_MARKS), from the frame: {on (the resident is in your view), need (1 or 2), lit,
## all}, or {} for none. One mark per watcher needed; one lit per watcher the host counts, your own the frame
## you look; all lit, the row closes into a bar (it is held); one of two lit, the second pulses ("one more").
var eyes: Dictionary = {}
## The day quota (client/day_view.gd, FD3): the corner line under PLAY ("DAY 1650/2400"), "" for none, and
## whether it is met (then amber, "... MET").
var floor_quota_line := ""
var mark_line := ""
var floor_quota_met := false
var day_line := ""
var loss_rows := PackedStringArray()
var day_met := false
## The Tenant clock (client/tenant_clock.gd, TT1): its line, last in the corner stack under PLAY ("" for none), and
## whether it is in the warning colour (the last minute).
var tenant_line := ""
var tenant_warn := false
## LS1 (North Star B7; client/last_stand_view.gd): the spotlight's line, at the top, in the survivor's amber or the
## watchers' red ("" for none); and the wipe's scene (client/wipe_scene.gd): black bars top and bottom, nothing else.
var stand_line := ""
var stand_self := false
var letterbox := false

## HUD1 (the screen plan, stage 1, the owner's yes of 21 Nov: "Lift and tab, no keeping them on screen"): the counters
## show when they change and fade (client/hud_fade.gd); urgent ones stay. `display`: Tab (DISPLAY) is held, so every
## counter, every rate line and the nerve show at full. The values are never changed here, only how visible they are.
const HudFade = preload("res://client/hud_fade.gd")
var fades := HudFade.new()
var display := false
## The Tenant clock's moments (client/tenant_clock.gd TenantBeats): true while the line belongs on the glass (the
## doors, 5:00, 2:00, the last minute). True by default, so a clock that sets no beats (the Ward's) keeps showing.
var tenant_beat := true
var _tenant_beat_ms := -100000
## The place shown ("" none; client/main.gd sets the floor's depth): the tape's timecode shows on each arrival, then fades.
var place := ""
## How visible each managed element is this frame (plan()): floor, day, tenant, time, tape, nerve, anger.
var _a := {}

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

var annex_forehead_note := false

## HUD1: works out how visible each counter is at `now` (ms) and keeps it for the draw. Called once a frame by _draw;
## tests call it with their own times.
func plan(now: int) -> Dictionary:
	_a = {}
	_a["floor"] = fades.see("floor", floor_quota_line, now, false, display) if floor_quota_line != "" else 0.0
	_a["day"] = fades.see("day", day_line, now, false, display) if day_line != "" else 0.0
	if tenant_beat or display:
		_tenant_beat_ms = now
	_a["tenant"] = HudFade.alpha(_tenant_beat_ms, now, false, 0) if tenant_line != "" else 0.0
	_a["time"] = fades.see("time", place, now, false, display)
	_a["tape"] = fades.see("tape", tape_text_of(), now, false, display) if tape_text_of() != "" else 0.0
	if nerve.is_empty():
		_a["nerve"] = 0.0
	else:
		_a["nerve"] = fades.see("nerve", ceili(float(nerve[0])) / 10, now, nerve_shaken(), display)
	if anger < 0.0:
		_a["anger"] = 0.0
	else:
		_a["anger"] = fades.see("anger", roundi(anger * 20.0), now, anger >= 0.75 or count_text != "", display)
	return _a

## The tape value's words ("" for none), as drawn.
func tape_text_of() -> String:
	if tape_count > 0 or tape_value > 0.0:
		return "#x%d %04d" % [tape_count, int(floor(tape_value))]
	return ""

## HUD1: the words the managed parts of the HUD show at `now` (each line whose visibility is above zero), plus PLAY.
## Tests count them; the state command reports them.
func visible_lines(now: int) -> PackedStringArray:
	plan(now)
	var out := PackedStringArray()
	if osd_on:
		out.append("PLAY >")
		if float(_a["floor"]) > 0.01:
			out.append(floor_quota_line)
		if float(_a["day"]) > 0.01:
			out.append(day_line)
		out.append_array(loss_rows)
		if float(_a["tenant"]) > 0.01 and down_head == "" and not out_on:
			out.append(tenant_line)
		if float(_a["time"]) > 0.01:
			out.append("SP")
		if float(_a["tape"]) > 0.01:
			out.append(tape_text_of())
	if not nerve.is_empty() and float(_a["nerve"]) > 0.01:
		var nl := nerve_lines()
		out.append(nl[0])
		if display:
			out.append_array(nl.slice(1))
	if anger >= 0.0 and float(_a["anger"]) > 0.01:
		out.append("ANGER")
		if display and anger_rates != "":
			out.append(anger_rates)
	if health >= 0.0:
		out.append("HEALTH")
		if display and health_rates != "":
			out.append(health_rates)
	return out

## A colour at `a` of its own alpha.
static func _fa(c: Color, a: float) -> Color:
	return Color(c, c.a * clampf(a, 0.0, 1.0))

func _draw() -> void:
	var px := _scale()
	var now := Time.get_ticks_msec()
	plan(now)
	if black:
		draw_rect(Rect2(Vector2.ZERO, size), Color.BLACK)
	if not end_lines.is_empty():
		_draw_end()
		return
	if letterbox:
		# The wipe's scene: the shot alone, between two bars, then its fade (and the voice's subtitles, if it speaks).
		var bar := floorf(size.y * 0.12)
		draw_rect(Rect2(Vector2.ZERO, Vector2(size.x, bar)), Color.BLACK)
		draw_rect(Rect2(Vector2(0, size.y - bar), Vector2(size.x, bar)), Color.BLACK)
		if fade > 0.0:
			draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, clampf(fade, 0.0, 1.0)))
		if subtitle != "":
			_draw_subtitle(px)
		return
	if fade > 0.0:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, clampf(fade, 0.0, 1.0)))
	if stand_line != "" and not black:
		var sw0 := PixelFont.width(stand_line) * px
		var sp0 := Vector2(floorf((size.x - sw0) * 0.5), floorf(size.y * 0.13))
		draw_rect(Rect2(sp0 - Vector2(4, 3) * px, Vector2(sw0 + 8 * px, 13 * px)), Color(0, 0, 0, 0.55))
		PixelFont.draw_shadowed(self, stand_line, sp0, px, Color("#ffd27a") if stand_self else Color("#ff7a6a"))
	if annex_forehead_note and not black:
		var w := size.x
		var h := size.y
		draw_colored_polygon(PackedVector2Array([Vector2(w * 0.30, 0), Vector2(w * 0.65, 0),
			Vector2(w * 0.63, h * 0.17), Vector2(w * 0.34, h * 0.20)]), Color("#d3b14f"))
	if out_on and not black:
		_draw_out(px)
	if watch_note != "" and not out_on and not black:
		var ww := PixelFont.width(watch_note) * px
		var wp := Vector2(floorf((size.x - ww) * 0.5), floorf(size.y * 0.2))
		draw_rect(Rect2(wp - Vector2(4, 3) * px, Vector2(ww + 8 * px, 13 * px)), Color(0, 0, 0, 0.45))
		PixelFont.draw_shadowed(self, watch_note, wp, px, Color("#ff7a6a"))
	if osd_on:
		var blink_on := (now / 700) % 2 == 0
		var top := "PLAY >" if blink_on else "PLAY  "
		var tw := PixelFont.width(top) * px
		var margin := Vector2(maxf(size.x * 0.06, 16.0), maxf(size.y * 0.06, 12.0))
		PixelFont.draw_shadowed(self, top, Vector2(size.x - margin.x - PixelFont.width("PLAY >") * px, margin.y), px, Color("#f4f4ec"))
		if not black:
			_draw_quota_corner(px, margin)
		var s := start_sec + (now - t0) / 1000
		var bottom := "SP %d:%02d:%02d" % [s / 3600, (s / 60) % 60, s % 60]
		var bw := PixelFont.width(bottom) * px
		var by := size.y - margin.y - 9 * px
		var ta := float(_a["time"])
		if ta > 0.01:
			PixelFont.draw_shadowed(self, bottom, Vector2(size.x - margin.x - bw, by), px, _fa(Color("#f4f4ec"), ta), _fa(Color(0, 0, 0, 0.55), ta))
		var since := now - _jump_at
		var blink_off := since < JUMP_MS and (since / JUMP_BLINK_MS) % 2 == 1
		tape_text = tape_text_of()
		var tpa := float(_a["tape"])
		if tape_text != "" and tpa > 0.01:
			if not blink_off:
				PixelFont.draw_shadowed(self, tape_text, Vector2(size.x - margin.x - PixelFont.width(tape_text) * px, by - 12 * px), px, _fa(Color("#f4f4ec"), tpa), _fa(Color(0, 0, 0, 0.55), tpa))
	if prompt != "" and not black:
		var pw := PixelFont.width(prompt) * px
		var pp := Vector2((size.x - pw) * 0.5, _prompt_y(px))
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
	if mark_line != "" and not black:
		var at := Vector2(maxf(size.x * 0.06, 16.0), maxf(size.y * 0.06, 12.0))
		draw_rect(Rect2(at - Vector2(4, 3) * px, Vector2(PixelFont.width(mark_line) + 8, 13) * px), Color(0, 0, 0, 0.58))
		PixelFont.draw_shadowed(self, mark_line, at, px, Color("#ffd27a"))
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
	if not nerve.is_empty() and not black and not out_on and down_head.is_empty() and watch_note == "":
		_draw_nerve(px)
	if anger >= 0.0 and not black:
		_draw_anger(px)
	if party_note != "" and not black:
		var nw := PixelFont.width(party_note) * px
		var np := Vector2(floorf((size.x - nw) * 0.5), floorf(size.y * 0.22))
		draw_rect(Rect2(np - Vector2(4, 3) * px, Vector2(nw + 8 * px, 13 * px)), Color(0, 0, 0, 0.5))
		PixelFont.draw_shadowed(self, party_note, np, px, Color("#ff7a6a"))
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
	if click_to_look and not menu_on and not black and end_lines.is_empty():
		var cl := "CLICK TO LOOK"
		PixelFont.draw_shadowed(self, cl, Vector2(floorf((size.x - PixelFont.width(cl) * px) * 0.5), floorf(size.y * 0.42)), px, Color("#f4f4ec"))
	if menu_on and not black:
		_draw_menu()

func _draw_quota_corner(px: float, margin: Vector2) -> void:
	# The Playroom count uses two centered rows near PLAY. Keep the quota rows below it.
	var y := margin.y + (31.0 if count_text != "" or count_by != "" else 12.0) * px
	# HUD1: each line shows on change and fades (its place is kept only while it shows).
	var fa := float(_a.get("floor", 0.0))
	if floor_quota_line != "" and fa > 0.01:
		var x := size.x - margin.x - PixelFont.width(floor_quota_line) * px
		PixelFont.draw_shadowed(self, floor_quota_line, Vector2(x, y), px, _fa(Color("#ffd27a") if floor_quota_met else Color("#f4f4ec"), fa), _fa(Color(0, 0, 0, 0.55), fa))
		y += 10.0 * px
	var da := float(_a.get("day", 0.0))
	if day_line != "" and da > 0.01:
		var x := size.x - margin.x - PixelFont.width(day_line) * px
		PixelFont.draw_shadowed(self, day_line, Vector2(x, y), px, _fa(Color("#ffd27a") if day_met else Color("#f4f4ec"), da), _fa(Color(0, 0, 0, 0.55), da))
		y += 10.0 * px
	for i in loss_rows.size():
		var x := size.x - margin.x - PixelFont.width(loss_rows[i]) * px
		PixelFont.draw_shadowed(self, loss_rows[i], Vector2(x, y), px, Color("#ffd27a") if i == 0 else Color("#f4f4ec"))
		y += 10.0 * px
	# Not over the down timer (big, at a fifth of the height) or the out screen.
	var tna := float(_a.get("tenant", 0.0))
	if tenant_line != "" and down_head == "" and not out_on and tna > 0.01:
		PixelFont.draw_shadowed(self, tenant_line, Vector2(size.x - margin.x - PixelFont.width(tenant_line) * px, y), px, _fa(Color("#ff7a6a") if tenant_warn else Color("#f4f4ec"), tna), _fa(Color(0, 0, 0, 0.55), tna))

## The call panel's words under the prompt: amber while counting, green once met, red (blinking) when a
## press was refused.
func _prompt_y(px: float) -> float:
	var y := size.y * 0.62
	if quota_line != "" and subtitle != "":
		var panel_offset := 15.0 if prompt != "" else 0.0
		y = minf(y, _subtitle_top() - (panel_offset + 13.0) * px)
	return y

## The call panel's words under the prompt: amber while counting, green once met, red (blinking) for a refusal.
func _draw_quota(px: float, now: int) -> void:
	var qw := PixelFont.width(quota_line) * px
	var qp := Vector2(floorf((size.x - qw) * 0.5), floorf(_prompt_y(px)) + (15 * px if prompt != "" else 0.0))
	draw_rect(Rect2(qp - Vector2(4, 3) * px, Vector2(qw + 8 * px, 13 * px)), Color(0, 0, 0, 0.55))
	var ink := Color("#ffd27a")
	if quota_tone == "met":
		ink = Color("#9fe0a0")
	elif quota_tone == "refused":
		ink = Color("#ff7a6a") if (now / 160) % 2 == 0 else Color("#7a2a22")
	PixelFont.draw_shadowed(self, quota_line, qp, px, ink)

## DR1: the down ring's radius and line width, in HUD pixels (times px).
const RING_RADIUS := 18.0
const RING_WIDTH := 3.0

## DR1: the arc of the down ring still left, as [start, end] angles (radians, Godot's: 0 along +x, growing
## clockwise on screen): full is the whole circle from the top; it empties clockwise from the top, so the arc left
## always ends at the top and starts `1 - left` of a turn round from it. Empty (left 0) is [end, end].
static func ring_arc(left: float) -> PackedFloat64Array:
	var f := clampf(left, 0.0, 1.0)
	var top := -PI * 0.5
	return PackedFloat64Array([top + TAU * (1.0 - f), top + TAU])

## Down: the ring in the centre of the screen, draining (DR1: no words, no number), then the lines under it
## and, while a crewmate holds F beside you, their hold's bar.
func _draw_down(px: float) -> void:
	var red := Color("#ff7a6a")
	var centre := Vector2(floorf(size.x * 0.5), floorf(size.y * 0.5))
	var r := RING_RADIUS * px
	if down_left >= 0.0:
		draw_arc(centre, r, 0.0, TAU, 64, Color(0, 0, 0, 0.55), (RING_WIDTH + 2.0) * px, true)
		var arc := ring_arc(down_left)
		if arc[1] - arc[0] > 1e-4:
			draw_arc(centre, r, arc[0], arc[1], maxi(2, ceili(64.0 * (arc[1] - arc[0]) / TAU)), red, RING_WIDTH * px, true)
	var y := floorf(centre.y + r + 10 * px)
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
	# HUD1: the rates are read on Tab (DISPLAY), not kept on the glass.
	if health_rates != "" and display:
		PixelFont.draw_shadowed(self, health_rates, Vector2(margin.x, y + 17 * px), px, Color("#d8ddd9"))

func nerve_lines() -> PackedStringArray:
	if nerve.is_empty():
		return []
	var rates: Array[String] = []
	for i in range(1, mini(nerve.size(), 6)):
		rates.append(String.num(nerve[i], 2).trim_suffix(".0"))
	var low := nerve_shaken()
	var shown := ceili(float(nerve[0]))
	if low:
		shown = mini(shown, int(Nerve.SHAKEN_BELOW) - 1)
	var lines := PackedStringArray(["NERVE %d/100%s" % [shown, "  SHAKEN" if low else ""],
		"DARK %s/S  RESIDENT %s/S" % [rates[0], rates[1]],
		"APART %s/S  WITH CREW +%s/S" % [rates[2], rates[3]]])
	if rates.size() > 4:
		lines.append("SEE A CATCH %s" % rates[4])
	return lines

func nerve_shaken() -> bool:
	return nerve.size() == 7 and nerve[6] == 1.0

func _draw_nerve(px: float) -> void:
	# HUD1: the level and its bar show on change (each ten points), stay while SHAKEN; the rates only on Tab.
	var na := float(_a.get("nerve", 0.0))
	if na <= 0.01:
		return
	var lines := nerve_lines()
	if not display:
		lines = lines.slice(0, 1)
	var x := maxf(size.x * 0.06, 16.0)
	var extra := (lines.size() - 3) * 9.0
	var y := size.y - maxf(size.y * 0.06, 12.0) - ((79.0 if health >= 0.0 else 50.0) + extra) * px
	var width := 80 * px
	for l in lines:
		width = maxf(width, PixelFont.width(l) * px)
	draw_rect(Rect2(Vector2(x - 3 * px, y - 2 * px), Vector2(width + 6 * px, (35 + extra) * px)), Color(0, 0, 0, 0.52 * na))
	PixelFont.draw_shadowed(self, lines[0], Vector2(x, y), px, _fa(Color("#f4f4ec"), na), _fa(Color(0, 0, 0, 0.55), na))
	var bar := Rect2(Vector2(x, y + 9 * px), Vector2(80 * px, 3 * px))
	draw_rect(bar, _fa(Color("#59584d"), na))
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * float(nerve[0]) / 100.0, bar.size.y)), _fa(Color("#ffd27a"), na))
	for i in range(1, lines.size()):
		PixelFont.draw_shadowed(self, lines[i], Vector2(x, y + (6 + i * 9) * px), px, Color("#d8ddd9"))

## The anger bar (T15m), top left (clear of the count's lines in the middle and the tape's PLAY): ANGER and the number out of 100, the bar (amber, red and pulsing once nearly full or while it
## counts), and what fills it under it.
func _draw_anger(px: float) -> void:
	var margin := Vector2(maxf(size.x * 0.06, 16.0), maxf(size.y * 0.06, 12.0))
	var bar_w := 80.0 * px
	var x := margin.x
	var y := margin.y
	var hot := anger >= 0.75
	# HUD1: the bar shows when it moves and stays from 75 and during a count; what fills it only on Tab.
	var aa := float(_a.get("anger", 1.0))
	if aa <= 0.01:
		return
	var label := "ANGER %d/100" % roundi(anger * 100.0)
	PixelFont.draw_shadowed(self, label, Vector2(x, y), px, _fa(Color("#ff7a6a") if hot else Color("#f4f4ec"), aa), _fa(Color(0, 0, 0, 0.55), aa))
	var bar := Rect2(Vector2(x, y + 10 * px), Vector2(bar_w, 4 * px))
	draw_rect(bar.grow(px), Color(0, 0, 0, 0.6 * aa))
	var col := Color("#ff5a4a") if hot else Color("#ffd27a")
	if hot:
		col.a = 0.75 + 0.25 * sin(Time.get_ticks_msec() / 120.0)
	draw_rect(Rect2(bar.position, Vector2(bar_w * clampf(anger, 0.0, 1.0), bar.size.y)), _fa(col, aa))
	# What fills it, while it can still fill (a full bar is a count: its own lines are under the count line).
	if anger_rates != "" and anger < 1.0 and display:
		PixelFont.draw_shadowed(self, anger_rates, Vector2(x, y + 17 * px), px, Color("#d8ddd9"))

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
	var at := rows.size() - 1   # before ESC
	if f8_row != "":
		rows.insert(at, F8_HOST_ROW if f8_row == "host" else F8_GUEST_ROW)
	if f6_row:
		rows.insert(at, F6_ROW)
	rows.append(["H", "HINTS: ON" if hints_on else "HINTS: OFF"])
	rows.append(["B", "BRIGHTNESS"])
	# MU1: every player's own MASTER, MUSIC and EFFECTS (the settings panel's YOUR SOUND page).
	rows.append(["V", "SOUND: MASTER MUSIC EFFECTS"])
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
func _subtitle_bottom() -> float:
	return size.y * (0.87 if quota_line != "" else 0.91)

func _subtitle_top() -> float:
	var rows := _subtitle_rows()
	var w := 10
	for r in rows:
		w = maxi(w, PixelFont.width(r))
	w += 6
	var sc := clampf(floor(size.x * 0.92 / w), 1.0, 4.0)
	return _subtitle_bottom() - (rows.size() * 10 + 4) * sc

func _draw_subtitle(_px: float) -> void:
	var rows := _subtitle_rows()
	var w := 10
	for r in rows:
		w = maxi(w, PixelFont.width(r))
	w += 6
	var h := rows.size() * 10 + 4
	var sc := clampf(floor(size.x * 0.92 / w), 1.0, 4.0)
	var origin := Vector2((size.x - w * sc) * 0.5, _subtitle_bottom() - h * sc)
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
