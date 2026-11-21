# VC1: the microphone on screen (client/mic.gd). Two things, over the HUD:
#   - In a run with the voice on, a small meter in the top right corner: MIC and a bar of 15 steps, lit to the level
#     this machine sends the host (the instrument never lies: the same number), with a mark at the whisper (level 1)
#     and the talk mark (level 5), W and T under them. Nothing says who hears or how far. Beside it the state: MIC (on,
#     listening), MIC OFF (turned off; M turns it on), NO MIC (none found or no signal).
#   - The first time the game starts on a machine that can listen, the consent card (the plan's words): Y uses the
#     microphone, N is not now, H switches headphones and speakers. Kept in the player's settings file; changed later on
#     the settings page (F8, S: YOUR SOUND) or with M.
#   - Right after a yes, the calibration card (required; the brightness card is its model): 2 s "stay quiet" (the room),
#     then "say this at your normal talking voice" with one printed company line for 3 s, a live bar moving as they
#     speak. Then DONE (Enter carries on, R does it again) or, for a reading that cannot set the marks, the reason in
#     plain words (R tries again, N carries on with the microphone off). S skips at any time: the default marks.
extends Control

const MicMeter = preload("res://client/mic_meter.gd")
const NoiseMeter = preload("res://client/noise_meter.gd")

const INK := Color(0.96, 0.96, 0.92)
const DIM := Color(0.55, 0.56, 0.52)
const GREEN := Color(0.55, 0.9, 0.5)
const AMBER := Color(1.0, 0.72, 0.25)
const RED := Color(1.0, 0.42, 0.32)
const CONSENT_LINES: Array[String] = [
	"THE GAME CAN LISTEN TO HOW LOUD YOU ARE,",
	"SO THE RESIDENTS CAN HEAR YOU.",
	"",
	"IT NEVER RECORDS, KEEPS OR SENDS YOUR VOICE:",
	"ONLY A NUMBER FOR HOW LOUD.",
	"",
	"IT HEARS YOU EVEN WHEN DISCORD'S PUSH TO TALK",
	"IS NOT PRESSED.",
	"",
	"ON SPEAKERS, YOUR FRIENDS' VOICES MAY COUNT AS YOURS.",
	"HEADPHONES ARE BEST.",
]

## Set by client/main.gd.
var mic: Node = null
## The run has the voice on (the world's "mic" list is there): the meter shows.
var voice_on := false
## The meter's state: a level 0 to 15 from each named source (today &"voice"), the bands' colours and the flash.
var noise := NoiseMeter.new()
var _hits: Array = []

func _ready() -> void:
	# VC3: anchors AND offsets, so a layer made in code is the whole screen (anchors alone left it 0x0, off screen).
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func consent_open() -> bool:
	return mic != null and bool(mic.call(&"needs_consent"))

func calib_open() -> bool:
	return mic != null and bool(mic.get(&"calib_open"))

func _process(_dt: float) -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP if consent_open() or calib_open() else Control.MOUSE_FILTER_IGNORE
	if mic != null:
		noise.feed(&"voice", int(mic.call(&"level")), Time.get_ticks_msec())
	queue_redraw()

## The consent card's keys (Y, N, H). True when it took the key; while it is up it takes every key.
func key(k: InputEventKey) -> bool:
	if calib_open():
		if k.pressed and not k.echo:
			_calib_key(k.physical_keycode)
		return true
	if not consent_open():
		return false
	if k.pressed and not k.echo:
		match k.physical_keycode:
			KEY_Y, KEY_ENTER, KEY_KP_ENTER:
				mic.call(&"answer", true)
			KEY_N, KEY_ESCAPE:
				mic.call(&"answer", false)
			KEY_H:
				_flip_speakers()
	return true

## The calibration card's keys: R again, S skip, Enter carry on (after DONE), N carry on with the microphone off.
func _calib_key(code: int) -> void:
	var running := not (mic.get(&"calib") as Array).is_empty()
	var res := str(mic.get(&"calib_result"))
	match code:
		KEY_R:
			mic.call(&"start_calibration")
		KEY_S:
			mic.call(&"skip_calibration")
		KEY_ENTER, KEY_KP_ENTER, KEY_Y:
			if not running and res == "ok":
				mic.call(&"close_calibration", false)
		KEY_N, KEY_ESCAPE:
			if not running and res != "ok":
				mic.call(&"close_calibration", true)

func _flip_speakers() -> void:
	var m: MicMeter = mic.get(&"meter")
	m.speakers = not m.speakers

func _gui_input(e: InputEvent) -> void:
	if not (consent_open() or calib_open()) or not (e is InputEventMouseButton):
		return
	var mb := e as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	for h: Array in _hits:
		if (h[0] as Rect2).has_point(mb.position):
			match str(h[1]):
				"yes":
					mic.call(&"answer", true)
				"no":
					mic.call(&"answer", false)
				"speakers":
					_flip_speakers()
				"again":
					_calib_key(KEY_R)
				"skip":
					_calib_key(KEY_S)
				"carry":
					_calib_key(KEY_ENTER)
				"off":
					_calib_key(KEY_N)
	accept_event()

func _px() -> float:
	return maxf(2.0, floorf(size.y / 320.0))

func _text(t: String, at: Vector2, px: float, col: Color) -> void:
	PixelFont.draw_shadowed(self, t, at, px, col)

func _draw() -> void:
	_hits = []
	if mic == null:
		return
	var px := _px()
	if consent_open():
		_draw_consent(px)
		return
	if calib_open():
		_draw_calib(px)
		return
	if voice_on:
		_draw_meter(px)

## The meter: the state word, then 15 cells, the whisper and talk marks under them.
func _draw_meter(px: float) -> void:
	var st := str(mic.get(&"status"))
	var listening: bool = mic.call(&"listening")
	var word := "MIC" if listening else ("NO MIC" if st == "none" else "MIC OFF")
	var col := GREEN if listening else (AMBER if st == "none" else DIM)
	var cell := 3.0 * px
	var gap := px
	var bar_w := 15.0 * (cell + gap)
	var word_w := PixelFont.width(word) * px
	var right := size.x - 6.0 * px
	var top := 6.0 * px
	var bar_x := right - bar_w
	_text(word, Vector2(bar_x - word_w - 4.0 * px, top), px, col)
	var lv := noise.level
	var talking: bool = mic.call(&"talking")
	var box := Rect2(Vector2(bar_x - px, top - px), Vector2(bar_w + px, 9.0 * px))
	draw_rect(box, Color(0, 0, 0, 0.45))
	# The filled part in the colour of the band the level is in (green, yellow, red); unlit cells dim.
	var fill := NoiseMeter.color_of(lv)
	for i in 15:
		var on := i < lv
		draw_rect(Rect2(Vector2(bar_x + i * (cell + gap), top), Vector2(cell, 7.0 * px)), Color(fill if on else DIM, 1.0 if on else 0.35))
	# The flash: 150 ms, a bright outline in the new band's colour, each time the level crosses up into a band.
	if noise.flashing(Time.get_ticks_msec()):
		draw_rect(box.grow(px), noise.flash_color(), false, 2.0 * px)
	for mark: Array in [[MicMeter.WHISPER_AT, "W"], [MicMeter.TALK_AT, "T"]]:
		var x := bar_x + float(int(mark[0]) - 1) * (cell + gap) - gap * 0.5
		draw_rect(Rect2(Vector2(x - px * 0.5, top - 2.0 * px), Vector2(px, 11.0 * px)), INK)
		_text(str(mark[1]), Vector2(x - 2.0 * px, top + 10.0 * px), px, DIM)
	if talking:
		_text("TALKING", Vector2(bar_x, top + 10.0 * px + 9.0 * px), px, AMBER)
	if not listening:
		_text("M: MIC ON" if st != "none" else "NO MICROPHONE SIGNAL", Vector2(bar_x - word_w - 4.0 * px, top + 19.0 * px), px, DIM)

func _draw_calib(px: float) -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.72))
	var lh := 11.0 * px
	var box := Vector2(PixelFont.width("SAY THIS AT YOUR NORMAL TALKING VOICE... 3") * px + 60.0 * px, lh * 12.0)
	var at := (size - box) * 0.5
	draw_rect(Rect2(at, box), Color(0.06, 0.07, 0.07, 0.96))
	draw_rect(Rect2(at, box), Color(INK, 0.6), false, maxf(1.0, px * 0.5))
	var x := at.x + 12.0 * px
	var y := at.y + 10.0 * px
	_text("YOUR MICROPHONE", Vector2(x, y), px, AMBER)
	y += lh * 1.5
	var running := not (mic.get(&"calib") as Array).is_empty()
	var res := str(mic.get(&"calib_result"))
	var line := str(mic.call(&"calib_line"))
	_text(line, Vector2(x, y), px, INK if running or res == "ok" else RED)
	y += lh
	if running and str((mic.get(&"calib") as Array)[0]) == "talk":
		_text(str(mic.call(&"calib_words")), Vector2(x, y), px, GREEN)
	elif not running and res == "ok":
		_text("ONLY TWO NUMBERS ARE KEPT, ON THIS COMPUTER.", Vector2(x, y), px, DIM)
	elif not running:
		_text("TRY AGAIN, OR CARRY ON WITH THE MICROPHONE OFF.", Vector2(x, y), px, DIM)
	y += lh * 1.5
	# The live bar, with its whisper and talk marks.
	var cell := 4.0 * px
	var lv: int = mic.call(&"level")
	for i in 15:
		draw_rect(Rect2(Vector2(x + i * (cell + px), y), Vector2(cell, 7.0 * px)), Color(NoiseMeter.color_of(lv) if i < lv else DIM, 1.0 if i < lv else 0.35))
	for mk: Array in [[MicMeter.WHISPER_AT, "WHISPER"], [MicMeter.TALK_AT, "TALK"]]:
		var mx := x + float(int(mk[0]) - 1) * (cell + px) - px * 0.5
		draw_rect(Rect2(Vector2(mx - px * 0.5, y - 2.0 * px), Vector2(px, 11.0 * px)), INK)
		_text(str(mk[1]), Vector2(mx, y + 10.0 * px), px, DIM)
	y += lh * 2.5
	var buttons: Array = []
	if running:
		buttons = [["S: SKIP", "skip", DIM]]
	elif res == "ok":
		buttons = [["ENTER: CARRY ON", "carry", GREEN], ["R: DO IT AGAIN", "again", INK], ["S: SKIP", "skip", DIM]]
	else:
		buttons = [["R: TRY AGAIN", "again", GREEN], ["N: CARRY ON WITH THE MIC OFF", "off", INK], ["S: SKIP", "skip", DIM]]
	for b: Array in buttons:
		var label := str(b[0])
		var r := Rect2(Vector2(x, y) - Vector2(2, 2) * px, Vector2(PixelFont.width(label) * px + 4.0 * px, 11.0 * px))
		draw_rect(r, Color(b[2] as Color, 0.6), false, maxf(1.0, px * 0.5))
		_text(label, Vector2(x, y), px, b[2] as Color)
		_hits.append([r, str(b[1])])
		x = r.end.x + 8.0 * px

func _draw_consent(px: float) -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.72))
	var lh := 11.0 * px
	var w := 0.0
	for l in CONSENT_LINES:
		w = maxf(w, PixelFont.width(l) * px)
	var box := Vector2(w + 24.0 * px, lh * (CONSENT_LINES.size() + 6))
	var at := (size - box) * 0.5
	draw_rect(Rect2(at, box), Color(0.06, 0.07, 0.07, 0.96))
	draw_rect(Rect2(at, box), Color(INK, 0.6), false, maxf(1.0, px * 0.5))
	var y := at.y + 10.0 * px
	_text("THE MICROPHONE", Vector2(at.x + 12.0 * px, y), px, AMBER)
	y += lh * 1.5
	for l in CONSENT_LINES:
		_text(l, Vector2(at.x + 12.0 * px, y), px, INK)
		y += lh
	y += lh * 0.5
	var m: MicMeter = mic.get(&"meter")
	var sp := "H: " + ("SPEAKERS" if m.speakers else "HEADPHONES")
	var yes := "Y: USE MICROPHONE"
	var no := "N: NOT NOW"
	var x := at.x + 12.0 * px
	for b: Array in [[yes, "yes", GREEN], [no, "no", INK], [sp, "speakers", AMBER if m.speakers else DIM]]:
		var label := str(b[0])
		var r := Rect2(Vector2(x, y) - Vector2(2, 2) * px, Vector2(PixelFont.width(label) * px + 4.0 * px, 11.0 * px))
		draw_rect(r, Color(b[2] as Color, 0.6), false, maxf(1.0, px * 0.5))
		_text(label, Vector2(x, y), px, b[2] as Color)
		_hits.append([r, str(b[1])])
		x = r.end.x + 8.0 * px
