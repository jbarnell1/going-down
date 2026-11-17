# Draw your face: a square canvas of 32 x 32 cells, a few bold colours, three brush sizes, the bucket,
# an eraser, undo, clear and three starting faces, Done and Cancel. A Control any screen can embed:
# give it a rect (anchors or size) and listen for `done` / `cancelled`. Drawn in the camcorder's pixel
# font, like the start screen. The mouse is never captured.
#
#   Mouse   left draws with the tool, right erases
#   Keys    1-7 colour, - and + (or [ and ]) brush size, B pen, F fill, E eraser, Z or Ctrl+Z undo,
#           Delete clear, Enter done, Esc cancel
#
# Reusable as the sketchbook (draw the entity from memory): set `palette` (at most 7 colours, index 0
# is the background), `time_limit` (seconds; Done fires by itself at zero), `title`,
# `show_starters = false` and `remember = false` before adding it to the tree.
class_name FaceEditor
extends Control

## The finished picture: the text (FaceCodec format) and the texture for the mask.
signal done(code: String, texture: ImageTexture)
signal cancelled

const Font5 := preload("res://client/pixel_font.gd")
const Codec := preload("res://face/face_codec.gd")
const Paint := preload("res://face/face_paint.gd")

const PALE := Color("#f4f4ec")
const AMBER := Color("#ffd27a")
const DIM := Color("#8f958f")
const PANEL := Color(0.035, 0.04, 0.042)
const BRUSHES: Array[float] = [2.0, 3.0, 5.0]
## The whole layout is 320 x 180 units, scaled by a whole number to fit.
const W := 320.0
const H := 180.0
const CELL_UNITS := 4.0
const CANVAS := Vector2(8, 20)

var palette: Array[Color] = Codec.PALETTE.duplicate()
var time_limit := 0.0
var title := "DRAW YOUR FACE"
## A face (FaceCodec text) to start from instead of the saved one.
var start_code := ""
var show_starters := true
## Load the last saved face to start from, and save the result on Done.
var remember := true
## Draw an opaque backdrop behind the editor (false when the host draws its own).
var backdrop := true

var paint: FacePaint = Paint.new(Codec.SIZE)
var colour := 1
var brush := 1                     # index into BRUSHES
var tool := "pen"                  # "pen" | "fill" | "erase"
var time_left := 0.0
var finished := false

var _items: Array[Dictionary] = []    # {id, rect} of what was drawn last
var _hover := ""
var _mouse := Vector2(-1, -1)          # in cells, while over the canvas
var _drawing := 0                       # mouse button held on the canvas (0 none)
var _last_cell := Vector2.ZERO
var _preview: ImageTexture
var _preview_dirty := true

func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	colour = mini(colour, palette.size() - 1)
	begin(start_code)

## (Re)opens the editor for a new drawing. It starts from, in order: `code` if it is a valid face,
## the last saved face (if `remember`), the smile (if `show_starters`), or an empty screen.
func begin(code := "") -> void:
	finished = false
	_drawing = 0
	time_left = time_limit
	var px := Codec.decode_indices(code)
	if px.is_empty() and remember:
		px = Codec.decode_indices(Codec.load_last())
	if px.is_empty() and show_starters:
		px = Paint.starter("smile")
	if px.is_empty():
		px.resize(Codec.PIXELS)
		px.fill(0)
	paint.set_all(px)
	paint.forget_undo()
	_changed()
	grab_focus.call_deferred()

## The picture as text (FaceCodec format).
func get_code() -> String:
	return Codec.encode(paint.px)

## Shows a face from its text; false (and nothing changes) if the text is not a valid face.
func load_code(code: String) -> bool:
	var px := Codec.decode_indices(code)
	if px.is_empty():
		return false
	paint.set_all(px)
	_changed()
	return true

## Presses a control by id (the mouse, the keys and tests all come here): "colour:N", "brush:N",
## "pen", "fill", "erase", "undo", "clear", "starter:NAME", "done", "cancel".
func press(id: String) -> void:
	if finished:
		return
	if id.begins_with("colour:"):
		colour = clampi(int(id.substr(7)), 0, palette.size() - 1)
		if tool == "erase":
			tool = "pen"
	elif id.begins_with("brush:"):
		brush = clampi(int(id.substr(6)), 0, BRUSHES.size() - 1)
	elif id.begins_with("starter:"):
		var px := Paint.starter(id.substr(8))
		if not px.is_empty():
			paint.set_all(px)
	else:
		match id:
			"pen", "fill", "erase":
				tool = id
			"undo":
				paint.undo()
			"clear":
				paint.clear(0)
			"done":
				finish()
				return
			"cancel":
				finished = true
				cancelled.emit()
				return
	_changed()

## Ends the drawing: saves it (if `remember`) and sends `done`.
func finish() -> void:
	if finished:
		return
	finished = true
	_drawing = 0
	paint.stroke_end()
	var code := get_code()
	if remember:
		Codec.save_last(code)
	done.emit(code, Codec.decode(code, palette))

func _changed() -> void:
	_preview_dirty = true
	queue_redraw()

func _process(delta: float) -> void:
	if time_limit > 0.0 and not finished and is_visible_in_tree():
		time_left = maxf(0.0, time_left - delta)
		queue_redraw()
		if time_left <= 0.0:
			finish()

# --- input ----------------------------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if finished:
		return
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		_mouse = _to_cell(mm.position)
		var over := _item_at(mm.position)
		if over != _hover:
			_hover = over
		if _drawing != 0:
			var col := _stroke_colour(_drawing)
			paint.line(_last_cell, _mouse, BRUSHES[brush], col)
			_last_cell = _mouse
			_preview_dirty = true
		queue_redraw()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT and mb.button_index != MOUSE_BUTTON_RIGHT:
			return
		var cell := _to_cell(mb.position)
		if mb.pressed:
			grab_focus()
			if _on_canvas(cell):
				if mb.button_index == MOUSE_BUTTON_LEFT and tool == "fill":
					paint.fill(Vector2i(int(cell.x), int(cell.y)), colour)
				else:
					_drawing = mb.button_index
					_last_cell = cell
					paint.stroke_begin()
					paint.dab(cell, BRUSHES[brush], _stroke_colour(_drawing))
				_changed()
			elif mb.button_index == MOUSE_BUTTON_LEFT:
				var id := _item_at(mb.position)
				if id != "":
					press(id)
		elif mb.button_index == _drawing:
			_drawing = 0
			paint.stroke_end()
			_changed()
		accept_event()
	elif event is InputEventKey:
		if key(event as InputEventKey):
			accept_event()

## Keys (a host that routes keys itself can call this). True when the key was used.
func key(k: InputEventKey) -> bool:
	if not k.pressed or finished:
		return false
	var cmd := k.is_command_or_control_pressed()
	if k.keycode >= KEY_1 and k.keycode <= KEY_9 and not cmd:
		var n := int(k.keycode - KEY_1)
		if n < palette.size():
			press("colour:%d" % n)
			return true
		return false
	match k.keycode:
		KEY_BRACKETLEFT, KEY_MINUS:
			press("brush:%d" % (brush - 1))
		KEY_BRACKETRIGHT, KEY_EQUAL, KEY_PLUS:
			press("brush:%d" % (brush + 1))
		KEY_B, KEY_P:
			press("pen")
		KEY_F:
			press("fill")
		KEY_E:
			press("erase")
		KEY_Z:
			press("undo")
		KEY_DELETE:
			press("clear")
		KEY_ENTER, KEY_KP_ENTER:
			press("done")
		KEY_ESCAPE:
			press("cancel")
		_:
			return false
	return true

func _stroke_colour(button: int) -> int:
	if button == MOUSE_BUTTON_RIGHT or tool == "erase":
		return 0
	return colour

# --- layout ---------------------------------------------------------------------------------------

func _scale() -> float:
	return maxf(1.0, floorf(minf(size.x / W, size.y / H)))

func _origin() -> Vector2:
	var px := _scale()
	return ((size - Vector2(W, H) * px) * 0.5).floor()

## Units to screen.
func _u(p: Vector2) -> Vector2:
	return _origin() + p * _scale()

func _canvas_rect() -> Rect2:
	var px := _scale()
	return Rect2(_u(CANVAS), Vector2.ONE * Codec.SIZE * CELL_UNITS * px)

## Screen to continuous cell coordinates.
func _to_cell(p: Vector2) -> Vector2:
	var r := _canvas_rect()
	return (p - r.position) / (r.size.x / Codec.SIZE)

func _on_canvas(cell: Vector2) -> bool:
	return cell.x >= 0.0 and cell.y >= 0.0 and cell.x < Codec.SIZE and cell.y < Codec.SIZE

func _item_at(p: Vector2) -> String:
	for it: Dictionary in _items:
		if (it["rect"] as Rect2).has_point(p):
			return it["id"]
	return ""

## Where a control is on screen (tests click through this).
func rect_of(id: String) -> Rect2:
	for it: Dictionary in _items:
		if it["id"] == id:
			return it["rect"]
	return Rect2()

## The screen point at the centre of a cell (tests draw through this).
func cell_to_screen(cell: Vector2) -> Vector2:
	var r := _canvas_rect()
	return r.position + cell * (r.size.x / Codec.SIZE)

# --- drawing --------------------------------------------------------------------------------------

func _text(t: String, at: Vector2, col: Color, mul := 1.0) -> void:
	Font5.draw_shadowed(self, t, _u(at).floor(), _scale() * mul, col)

func _button(id: String, label: String, at: Vector2, w: float, selected := false) -> void:
	var px := _scale()
	var r := Rect2(_u(at), Vector2(w, 15) * px)
	var hot := _hover == id
	draw_rect(r, Color(0.02, 0.02, 0.025, 0.95))
	var edge := AMBER if (selected or hot) else DIM
	draw_rect(r, edge, false, px * (2.0 if selected else 1.0))
	var tx := at.x + floorf((w - Font5.width(label)) * 0.5)
	_text(label, Vector2(tx, at.y + 4), AMBER if selected else (PALE if not hot else AMBER))
	_items.append({"id": id, "rect": r})

func _draw() -> void:
	_items.clear()
	var px := _scale()
	if backdrop:
		draw_rect(Rect2(Vector2.ZERO, size), PANEL)
	_text(title, Vector2(8, 3), AMBER, 2.0)
	if time_limit > 0.0:
		var t := "%d" % ceili(time_left)
		_text(t, Vector2(W - 8 - Font5.width(t) * 2, 3), AMBER if time_left > 3.0 else Color("#ff8a6a"), 2.0)
	_draw_canvas(px)
	_draw_previews(px)
	# The right-hand panel.
	var x0 := 148.0
	_text("COLOUR   1-%d" % palette.size(), Vector2(x0, 20), DIM)
	for i in palette.size():
		var at := Vector2(x0 + i * 22.0, 29)
		var r := Rect2(_u(at), Vector2(18, 14) * px)
		var sel := i == colour and tool != "erase"
		draw_rect(r.grow(px * (2.0 if sel else 1.0)), AMBER if sel else (DIM if _hover == "colour:%d" % i else Color(0.25, 0.27, 0.26)))
		draw_rect(r, palette[i])
		_items.append({"id": "colour:%d" % i, "rect": r.grow(px)})
	_button("pen", "PEN", Vector2(x0, 49), 50, tool == "pen")
	_button("fill", "FILL", Vector2(x0 + 57, 49), 50, tool == "fill")
	_button("erase", "ERASE", Vector2(x0 + 114, 49), 50, tool == "erase")
	for i in BRUSHES.size():
		var at := Vector2(x0 + i * 23.0, 70)
		_button("brush:%d" % i, "", at, 20, i == brush)
		var c := _u(at + Vector2(10, 7.5))
		draw_circle(c, BRUSHES[i] * 1.1 * px, PALE)
	_button("undo", "UNDO", Vector2(x0 + 72, 70), 42)
	_button("clear", "CLEAR", Vector2(x0 + 118, 70), 46)
	if show_starters:
		_text("START FROM", Vector2(x0, 93), DIM)
		_button("starter:smile", "SMILE", Vector2(x0, 102), 50)
		_button("starter:frown", "FROWN", Vector2(x0 + 57, 102), 50)
		_button("starter:shock", "SHOCK", Vector2(x0 + 114, 102), 50)
	_text("BIG AND BOLD READS BEST", Vector2(x0, 126), DIM)
	_button("done", "DONE", Vector2(x0, 141), 78, true)
	_button("cancel", "CANCEL", Vector2(x0 + 86, 141), 78)
	_text("Z UNDO  - + SIZE  ENTER DONE", Vector2(x0 - 2, 166), DIM)

func _draw_canvas(px: float) -> void:
	var r := _canvas_rect()
	var cs := r.size.x / Codec.SIZE
	draw_rect(r.grow(px * 2.0), Color(0.3, 0.32, 0.31))
	for y in Codec.SIZE:
		var x := 0
		while x < Codec.SIZE:
			var c := paint.px[y * Codec.SIZE + x]
			var x1 := x
			while x1 + 1 < Codec.SIZE and paint.px[y * Codec.SIZE + x1 + 1] == c:
				x1 += 1
			var col: Color = palette[c] if c < palette.size() else palette[0]
			draw_rect(Rect2(r.position + Vector2(x, y) * cs, Vector2(x1 - x + 1, 1) * cs), col)
			x = x1 + 1
	# The brush under the mouse: the cells it would paint, outlined.
	if _on_canvas(_mouse) and tool != "fill":
		var rad := maxf(BRUSHES[brush] * 0.5, 0.5)
		draw_arc(r.position + _mouse * cs, rad * cs, 0.0, TAU, 32, AMBER if tool == "pen" else DIM, maxf(1.0, px * 0.5))
	elif _on_canvas(_mouse):
		var cell := _mouse.floor()
		draw_rect(Rect2(r.position + cell * cs, Vector2.ONE * cs), AMBER, false, maxf(1.0, px * 0.5))

## How the face reads on the mask: about as big as it is in the game's view at 1, 3 and 6 metres.
func _draw_previews(px: float) -> void:
	if _preview_dirty:
		_preview = Codec.decode(get_code(), palette)
		_preview_dirty = false
	_text("SEEN AT 1M", Vector2(8, 160), DIM)
	if _preview == null:
		return
	var y := 155.0
	var view_h := H                           # the game's view is the full height here
	var at1 := 32.0 / 270.0 * view_h          # the screen's size in a 270-line view at 1 m
	draw_texture_rect(_preview, Rect2(_u(Vector2(70, y)), Vector2.ONE * at1 * px), false)
	_text("3M", Vector2(99, 160), DIM)
	var at3 := 11.0 / 270.0 * view_h
	draw_texture_rect(_preview, Rect2(_u(Vector2(113, y + (at1 - at3) * 0.5)), Vector2.ONE * at3 * px), false)
	_text("6M", Vector2(124, 160), DIM)
	var at6 := 5.4 / 270.0 * view_h
	draw_texture_rect(_preview, Rect2(_u(Vector2(138, y + (at1 - at6) * 0.5)), Vector2.ONE * at6 * px), false)
