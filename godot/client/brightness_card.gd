# The brightness card (client/brightness.gd): a black screen with three old crew badges in a row, drawn in
# code in the greys the setting is judged by, the game's pixel font for the words, and a slider. Shown once
# on a PC before its first game (main.gd _ready, the title on a first launch), and any time from the Esc
# menu (B, BRIGHTNESS). Its own small screen: start() opens it, `finished` says it is closed (the choice is
# saved then). Left / right arrows or A / D move the slider a step, the mouse drags it; Enter, Esc or a
# click off the slider is done.
extends Control

const Brightness = preload("res://client/brightness.gd")

signal changed(level: int)
signal finished

## The setting it changes (main.gd's, saved with the player's settings).
var setting: Brightness = Brightness.new()
var open := false
var _dragging := false
## Where the slider's track was drawn (window pixels), for the mouse.
var _track := Rect2()

const LINE_1 := "RAISE UNTIL THE LEFT BADGE IS BARELY THERE."
const LINE_2 := "THE RIGHT ONE SHOULD STAY HIDDEN."
const DONE := "ENTER OR CLICK: DONE"
const LATER := "YOU CAN CHANGE THIS LATER: ESC, BRIGHTNESS"

func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false

func is_open() -> bool:
	return open

func start() -> void:
	open = true
	visible = true
	_dragging = false
	queue_redraw()

## Done: saved (never under automation), closed.
func done() -> void:
	if not open:
		return
	open = false
	visible = false
	_dragging = false
	setting.save()
	finished.emit()

func step(by: int) -> void:
	_set_level(setting.level + by)

func _set_level(v: int) -> void:
	var before := setting.level
	setting.set_level(v)
	if setting.level != before:
		changed.emit(setting.level)
	queue_redraw()

func key(k: InputEventKey) -> void:
	if not open or not k.pressed:
		return
	match k.physical_keycode:
		KEY_LEFT, KEY_A:
			step(-1)
		KEY_RIGHT, KEY_D:
			step(1)
		KEY_ENTER, KEY_KP_ENTER, KEY_ESCAPE, KEY_SPACE:
			if not k.echo:
				done()

func _gui_input(event: InputEvent) -> void:
	if not open:
		return
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			if _track.grow_individual(8, 14, 8, 14).has_point(mb.position):
				_dragging = true
				_drag_to(mb.position.x)
			else:
				done()
		else:
			_dragging = false
		accept_event()
	elif event is InputEventMouseMotion and _dragging:
		_drag_to((event as InputEventMouseMotion).position.x)
		accept_event()

func _drag_to(x: float) -> void:
	if _track.size.x <= 0.0:
		return
	_set_level(roundi(clampf((x - _track.position.x) / _track.size.x, 0.0, 1.0) * Brightness.STEPS))

## The window's pixel size for the font and the badges.
func _scale() -> float:
	return maxf(1.0, floorf(minf(size.x / 320.0, size.y / 180.0)))

func _grey(g: float) -> Color:
	var v := Brightness.apply(g, setting.level)
	return Color(v, v, v)

func _draw() -> void:
	if not open:
		return
	var px := _scale()
	var lv := setting.level
	# The game's black (a touch of the tape's blue in it), through the setting like everything else.
	draw_rect(Rect2(Vector2.ZERO, size), Brightness.apply_color(Color(Brightness.BLACK, Brightness.BLACK + 0.004, Brightness.BLACK + 0.008), lv))
	var pale := Color("#f4f4ec")
	var amber := Color("#ffd27a")
	var cx := size.x * 0.5
	# The words over the badges.
	var y := floorf(size.y * 0.12)
	_centred(LINE_1, y, px, pale)
	_centred(LINE_2, y + 11 * px, px, pale)
	# Three badges in a row: left (barely there), middle (plain), right (hidden).
	var bw := 34.0 * px
	var bh := 46.0 * px
	var gap := 22.0 * px
	var top := floorf(size.y * 0.30)
	var greys := [Brightness.LEFT, Brightness.MIDDLE, Brightness.RIGHT]
	for i in 3:
		var x := floorf(cx - bw * 1.5 - gap + i * (bw + gap))
		_badge(Rect2(x, top, bw, bh), _grey(greys[i]), px)
	# The slider, its number, and how to finish.
	var ty := floorf(top + bh + 22 * px)
	var tw := floorf(minf(size.x * 0.6, 200.0 * px))
	_track = Rect2(floorf(cx - tw * 0.5), ty, tw, 2 * px)
	draw_rect(_track, Color(0.45, 0.45, 0.42))
	for s in Brightness.STEPS + 1:
		var sx := floorf(_track.position.x + _track.size.x * float(s) / Brightness.STEPS)
		var tall := 3 if s == Brightness.DEFAULT else 1
		draw_rect(Rect2(sx, ty - tall * px, px, (2 + tall * 2) * px), Color(0.45, 0.45, 0.42))
	var kx := floorf(_track.position.x + _track.size.x * float(lv) / Brightness.STEPS)
	draw_rect(Rect2(kx - 2 * px, ty - 5 * px, 5 * px, 12 * px), amber)
	PixelFont.draw(self, "<", Vector2(_track.position.x - 12 * px, ty - 3 * px), px, amber)
	PixelFont.draw(self, ">", Vector2(_track.end.x + 8 * px, ty - 3 * px), px, amber)
	_centred(str(lv), ty + 12 * px, px * 2.0, amber)
	_centred(DONE, ty + 30 * px, px, amber)
	_centred(LATER, size.y - 12 * px, px, Color(0.62, 0.62, 0.58))

## One old crew badge: a card with a clip slot, a photo of a head and shoulders and two lines of type, all
## cut out of the one grey (so the badge is a single grey on black).
func _badge(r: Rect2, g: Color, px: float) -> void:
	var bg := Brightness.apply_color(Color(Brightness.BLACK, Brightness.BLACK + 0.004, Brightness.BLACK + 0.008), setting.level)
	# The card, its corners clipped by a pixel.
	draw_rect(Rect2(r.position + Vector2(px, 0), Vector2(r.size.x - 2 * px, r.size.y)), g)
	draw_rect(Rect2(r.position + Vector2(0, px), Vector2(r.size.x, r.size.y - 2 * px)), g)
	# The clip slot.
	draw_rect(Rect2(r.position + Vector2(r.size.x * 0.5 - 5 * px, 3 * px), Vector2(10 * px, 2 * px)), bg)
	# The photo: a frame of black with a head and shoulders in the badge's grey.
	var photo := Rect2(r.position + Vector2(7 * px, 9 * px), Vector2(r.size.x - 14 * px, 20 * px))
	draw_rect(photo, bg)
	var hc := photo.position + Vector2(photo.size.x * 0.5, 8 * px)
	draw_circle(hc, 4.5 * px, g)
	draw_rect(Rect2(Vector2(hc.x - 7 * px, photo.end.y - 6 * px), Vector2(14 * px, 6 * px)), g)
	# Two lines of type.
	draw_rect(Rect2(r.position + Vector2(5 * px, 33 * px), Vector2(r.size.x - 10 * px, 2 * px)), bg)
	draw_rect(Rect2(r.position + Vector2(5 * px, 38 * px), Vector2(r.size.x - 16 * px, 2 * px)), bg)

func _centred(t: String, y: float, px: float, col: Color) -> void:
	PixelFont.draw(self, t, Vector2(floorf(size.x * 0.5 - PixelFont.width(t) * px * 0.5), y), px, col)

func _process(_delta: float) -> void:
	if open:
		queue_redraw()
