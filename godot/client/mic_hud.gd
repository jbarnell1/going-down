# VC1: the microphone on screen (client/mic.gd). Two things, over the HUD:
#   - In a run (VC4: in the top LEFT corner, with or without the voice), a small meter: MIC and a bar of 15 steps, lit to the level
#     this machine sends the host (the instrument never lies: the same number), with a mark at the whisper (level 1)
#     and the talk mark (level 5), W and T under them. Nothing says who hears or how far. Beside it the state: MIC (on,
#     listening); NOISE (PL1: no microphone, or switched off: the steps' and opens' meter, nothing alarming; switched
#     off adds a dim M: MIC ON); MIC and an orange NO SIGNAL only for a microphone that was allowed, switched on and
#     calibrated and then stopped giving signal.
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
const OwnNoise = preload("res://client/own_noise.gd")
const Mic = preload("res://client/mic.gd")

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
## VC4: the player is on a floor of a run (set by client/main.gd): the noise meter may show, with or without a mic.
var in_run := false
## VC4: show the meter even when quiet (client/main.gd sets it while Tab, DISPLAY, is held).
var force_show := false
## PL1: the test channel's `micui consent|calib|off` (client/main.gd, testport only): which card to draw over the game
## from a stand-in microphone (card_mic: never opened, never reads or writes the settings file), or "" for none. While
## a card is shown this way it takes no keys and no clicks.
var card := ""
var card_mic: Node = null
## The meter's state words, kept in one column as wide as the widest, so the bar never moves.
const WORDS: Array[String] = ["NOISE", "MIC"]
## The meter's state: a level 0 to 15 from each named source (&"voice", &"steps", &"open"), the bands' colours and
## the flash.
var noise := NoiseMeter.new()
## VC4: this player's steps and opens at the rules' loudness (client/own_noise.gd), fed by client/main.gd.
var own := OwnNoise.new()
var _hits: Array = []

func _ready() -> void:
	# VC3: anchors AND offsets, so a layer made in code is the whole screen (anchors alone left it 0x0, off screen).
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func consent_open() -> bool:
	if card != "":
		return card == "consent"
	return mic != null and bool(mic.call(&"needs_consent"))

func calib_open() -> bool:
	if card != "":
		return card == "calib"
	return mic != null and bool(mic.get(&"calib_open"))

## PL1: the microphone the cards are drawn from: the stand-in while the test channel shows a card, else the real one.
func _cm() -> Node:
	return card_mic if card != "" else mic

## PL1: the test channel's cards. "consent" or "calib" draws that card from a fresh stand-in microphone (its settings
## never loaded or saved, never opened: allowed is false and it is never in the tree); "off" (or anything else) takes
## it away.
func show_card(which: String) -> void:
	if card_mic != null:
		card_mic.free()
		card_mic = null
	card = which if which in ["consent", "calib"] else ""
	if card == "":
		return
	var m: Node = Mic.new()
	var meter: MicMeter = m.get(&"meter")
	meter.persist = false
	m.set(&"allowed", false)
	if card == "calib":
		# The middle of the reading: the printed line, 2 s left, the live bar at a normal talking voice.
		m.set(&"fake_level", MicMeter.TALK_LEVEL)
		meter.level = MicMeter.TALK_LEVEL
		m.set(&"calib", [&"talk", 2.0, PackedFloat32Array()])
	card_mic = m

func _exit_tree() -> void:
	if card_mic != null:
		card_mic.free()
		card_mic = null

func _process(_dt: float) -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP if (consent_open() or calib_open()) and card == "" else Control.MOUSE_FILTER_IGNORE
	var now := Time.get_ticks_msec()
	noise.feed(&"voice", int(mic.call(&"level")) if mic != null and voice_on else 0, now)
	noise.feed(&"steps", own.steps if in_run else 0, now)
	noise.feed(&"open", own.pulse_level(now) if in_run else 0, now)
	var cards := consent_open() or calib_open()
	modulate.a = 1.0 if cards else noise.alpha(now, force_show)
	queue_redraw()

## The consent card's keys (Y, N, H). True when it took the key; while it is up it takes every key.
func key(k: InputEventKey) -> bool:
	if card != "":
		return false
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
	if card != "" or not (consent_open() or calib_open()) or not (e is InputEventMouseButton):
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
	var px := _px()
	if consent_open():
		_draw_consent(card_px(size, consent_units()))
		return
	if calib_open():
		_draw_calib(card_px(size, calib_units()))
		return
	if in_run or voice_on:
		_draw_meter(px)

## PL1: the meter's word, its colour, the hint right of the bar and the hint's colour, from `voice_on` (the run has the
## voice) and the microphone's describe() ({} for none). No microphone, or switched off: NOISE in the plain colour (a
## dim M: MIC ON when it is only switched off). Orange only for a microphone that was allowed, switched on and
## calibrated and then stopped giving signal.
static func meter_label(voice_on: bool, d: Dictionary) -> Array:
	if not voice_on or d.is_empty():
		return ["NOISE", DIM, "", DIM]
	if bool(d.get("listening", false)):
		return ["MIC", GREEN, "", DIM]
	var allowed := bool(d.get("allowed", false))
	var st := str(d.get("status", ""))
	if st == "none" and allowed and bool(d.get("enabled", false)) and bool(d.get("calibrated", false)):
		return ["MIC", AMBER, hint_text("none"), AMBER]
	if st == "off" and allowed:
		return ["NOISE", DIM, hint_text("off"), DIM]
	return ["NOISE", DIM, "", DIM]

## The meter: the state word, then 15 cells, the whisper and talk marks under them.
func _draw_meter(px: float) -> void:
	# Without the voice in this run (or no microphone object) the meter is the steps' and opens' alone: NOISE.
	var with_mic := voice_on and mic != null
	var lab := meter_label(voice_on, mic.call(&"describe") if with_mic else {})
	var word := str(lab[0])
	var col: Color = lab[1]
	var cell := 3.0 * px
	var gap := px
	var bar_w := 15.0 * (cell + gap)
	# VC4: the top LEFT corner (the top right holds the tape's PLAY and the floor's counts, and the hint under the
	# meter ran off the right edge). The word sits in a column as wide as the widest word, so the bar never moves.
	var word_col := 0.0
	for w: String in WORDS:
		word_col = maxf(word_col, PixelFont.width(w) * px)
	var left := 6.0 * px
	var top := 5.0 * px
	var bar_x := left + word_col + 4.0 * px
	_text(word, Vector2(left, top), px, col)
	var lv := noise.level
	var talking: bool = with_mic and bool(mic.call(&"talking"))
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
		# The whisper and talk marks: ticks through the bar (one row, so the Playroom's ANGER under it stays clear).
		draw_rect(Rect2(Vector2(x - px * 0.5, top - 2.0 * px), Vector2(px, 11.0 * px)), INK)
	# One row: TALKING, or what to do about the microphone, right of the bar.
	var after := Vector2(bar_x + bar_w + 4.0 * px, top)
	if talking:
		_text("TALKING", after, px, AMBER)
	elif str(lab[2]) != "":
		_text(str(lab[2]), after, px, lab[3] as Color)

## VC4: the meter's whole row, for the no-overlap test (`st`: the microphone's status, or "" for none).
func meter_rect(px: float, hint: String) -> Rect2:
	var word_col := 0.0
	for w: String in WORDS:
		word_col = maxf(word_col, PixelFont.width(w) * px)
	var left := 6.0 * px
	var top := 5.0 * px
	var bar_w := 15.0 * 4.0 * px
	var right := left + word_col + 4.0 * px + bar_w + 4.0 * px + PixelFont.width(hint) * px
	return Rect2(Vector2(left - px, top - 2.0 * px), Vector2(right - left + px, 11.0 * px))

static func hint_text(st: String) -> String:
	return "M: MIC ON" if st != "none" else "NO SIGNAL"

## PL1: a card's size in pixel-font units (multiply by px): the calibration card's and the consent card's.
static func calib_units() -> Vector2:
	return Vector2(PixelFont.width("SAY THIS AT YOUR NORMAL TALKING VOICE... 3") + 60.0, 11.0 * 12.0)

static func consent_units() -> Vector2:
	var w := 0.0
	for l in CONSENT_LINES:
		w = maxf(w, PixelFont.width(l))
	return Vector2(w + 24.0, 11.0 * (CONSENT_LINES.size() + 6))

## PL1: a card's pixel size: the HUD's, made smaller (never under 1) when the card would not fit a small window.
static func card_px(sz: Vector2, units: Vector2) -> float:
	var px := maxf(2.0, floorf(sz.y / 320.0))
	while px > 1.0 and (units.x * px > sz.x * 0.96 or units.y * px > sz.y * 0.96):
		px -= 1.0
	return px

## PL1: where a card lies on a screen of `sz` (tests: centred and whole).
static func card_rect(sz: Vector2, units: Vector2) -> Rect2:
	var box := units * card_px(sz, units)
	return Rect2((sz - box) * 0.5, box)

## PL1 (the photograph: WHISPER and TALK printed over each other): the calibration bar's mark labels, each under its
## mark, the second a row lower so they never overlap. [[word, its rect, the mark's x]] for a bar whose top left is
## `at`.
static func calib_mark_labels(px: float, at: Vector2) -> Array:
	var cell := 4.0 * px
	var out: Array = []
	var row := 0
	for mk: Array in [[MicMeter.WHISPER_AT, "WHISPER"], [MicMeter.TALK_AT, "TALK"]]:
		var mx := at.x + float(int(mk[0]) - 1) * (cell + px) - px * 0.5
		var r := Rect2(Vector2(mx, at.y + (10.0 + 10.0 * row) * px), Vector2(PixelFont.width(str(mk[1])) * px, 7.0 * px))
		out.append([str(mk[1]), r, mx])
		row += 1
	return out

func _draw_calib(px: float) -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.72))
	var lh := 11.0 * px
	var box := calib_units() * px
	var at := (size - box) * 0.5
	draw_rect(Rect2(at, box), Color(0.06, 0.07, 0.07, 0.96))
	draw_rect(Rect2(at, box), Color(INK, 0.6), false, maxf(1.0, px * 0.5))
	var x := at.x + 12.0 * px
	var y := at.y + 10.0 * px
	_text("YOUR MICROPHONE", Vector2(x, y), px, AMBER)
	y += lh * 1.5
	var cm := _cm()
	var running := not (cm.get(&"calib") as Array).is_empty()
	var res := str(cm.get(&"calib_result"))
	var line := str(cm.call(&"calib_line"))
	_text(line, Vector2(x, y), px, INK if running or res == "ok" else RED)
	y += lh
	if running and str((cm.get(&"calib") as Array)[0]) == "talk":
		_text(str(cm.call(&"calib_words")), Vector2(x, y), px, GREEN)
	elif not running and res == "ok":
		_text("ONLY TWO NUMBERS ARE KEPT, ON THIS COMPUTER.", Vector2(x, y), px, DIM)
	elif not running:
		_text("TRY AGAIN, OR CARRY ON WITH THE MICROPHONE OFF.", Vector2(x, y), px, DIM)
	y += lh * 1.5
	# The live bar, with its whisper and talk marks.
	var cell := 4.0 * px
	var lv: int = cm.call(&"level")
	for i in 15:
		draw_rect(Rect2(Vector2(x + i * (cell + px), y), Vector2(cell, 7.0 * px)), Color(NoiseMeter.color_of(lv) if i < lv else DIM, 1.0 if i < lv else 0.35))
	for lab: Array in calib_mark_labels(px, Vector2(x, y)):
		var r: Rect2 = lab[1]
		var mx := float(lab[2])
		draw_rect(Rect2(Vector2(mx - px * 0.5, y - 2.0 * px), Vector2(px, r.end.y - y + 2.0 * px)), Color(INK, 0.5) if r.position.y > y + 12.0 * px else INK)
		_text(str(lab[0]), r.position, px, DIM)
	y += lh * 3.5
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
	var box := consent_units() * px
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
	var m: MicMeter = _cm().get(&"meter")
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
