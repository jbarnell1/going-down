# Before the game: the title, "Play alone" and "Join friends" (the server's address, your name, the
# passphrase), the plain-words errors, and the lobby (who is here, Start for everyone, Leave). Drawn
# crisp in the camcorder's pixel font over the taped picture, like the HUD. Keyboard (Tab / arrows,
# Enter, typing, Backspace, Ctrl+V) and mouse both work. It decides nothing about the network: main.gd
# connects and tells it what happened.
#
# The address and the name are remembered in user://join.cfg (not under automation). The passphrase
# is kept only in memory while the game runs: never written to disk, never printed.
class_name StartScreen
extends Control

signal alone_pressed
signal join_pressed(address: String, player_name: String, passphrase: String)
signal back_pressed
signal start_pressed
signal leave_pressed

const SETTINGS := "user://join.cfg"
const MAX_ADDRESS := 200
const MAX_NAME := 16
const MAX_PASS := 128
const PALE := Color("#f4f4ec")
const AMBER := Color("#ffd27a")
const DIM := Color("#8f958f")
const WARN := Color("#ff8a6a")

## "title", "join", "connecting", "lobby" (hidden while playing).
var screen := "title"
var address := ""
var player_name := ""
var passphrase := ""
## A plain-words error shown on the join form (and the title).
var error := ""
## The lobby: [[id, name], ...] and this player's id; a run is on that this player is not in yet.
var people: Array = []
var my_id := ""
var run_on := false
## Under automation the address and name are not saved (a test must not change the player's own).
var remember := true
var focus := 0
var _hover := -1
## The focusable items on the screen drawn last: [{kind: "button"|"field", id, rect}].
var _items: Array[Dictionary] = []
var _caret_t := 0.0

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_load()

func _load() -> void:
	var cf := ConfigFile.new()
	if cf.load(SETTINGS) == OK:
		address = str(cf.get_value("join", "address", "")).left(MAX_ADDRESS)
		player_name = str(cf.get_value("join", "name", "")).left(MAX_NAME)

## Writes the address and the name (never the passphrase).
func save() -> void:
	if not remember:
		return
	var cf := ConfigFile.new()
	cf.set_value("join", "address", address)
	cf.set_value("join", "name", player_name)
	cf.save(SETTINGS)

func show_screen(which: String) -> void:
	screen = which
	visible = which != ""
	focus = 0
	if which == "join":
		# Start on the first empty field.
		var vals := [address, player_name, passphrase]
		for i in 3:
			if str(vals[i]).is_empty():
				focus = i
				break
		if focus == 0 and not address.is_empty() and not player_name.is_empty() and not passphrase.is_empty():
			focus = 3
	queue_redraw()

func _process(delta: float) -> void:
	var want := get_viewport_rect().size
	if size != want:
		position = Vector2.ZERO
		size = want
	_caret_t += delta
	queue_redraw()

# --- input ----------------------------------------------------------------------------------------

## The ids of the focusable items, in order, for the current screen.
func _order() -> Array[String]:
	match screen:
		"title":
			return ["alone", "join"]
		"join":
			return ["address", "name", "pass", "go", "back"]
		"connecting":
			return ["back"]
		"lobby":
			return ["start", "leave"]
	return []

func focused_id() -> String:
	var o := _order()
	return o[clampi(focus, 0, o.size() - 1)] if not o.is_empty() else ""

## Presses an item by id (the mouse, Enter, and the test hook all come here).
func press(id: String) -> void:
	match id:
		"alone":
			alone_pressed.emit()
		"join":
			error = ""
			show_screen("join")
		"go":
			submit()
		"back":
			back_pressed.emit()
		"start":
			start_pressed.emit()
		"leave":
			leave_pressed.emit()
		"address", "name", "pass":
			focus = _order().find(id)

## The Join button: checks the form, remembers the address and name, and asks to connect.
func submit() -> void:
	address = address.strip_edges()
	player_name = player_name.strip_edges()
	if address.is_empty():
		error = "TYPE THE SERVER'S ADDRESS"
		focus = 0
		return
	if player_name.is_empty():
		error = "TYPE YOUR NAME"
		focus = 1
		return
	if passphrase.is_empty():
		error = "TYPE THE PASSPHRASE FOR TONIGHT"
		focus = 2
		return
	error = ""
	save()
	join_pressed.emit(address, player_name, passphrase)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_hover = _item_at((event as InputEventMouseMotion).position)
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var i := _item_at(mb.position)
			if i >= 0:
				var id: String = _items[i]["id"]
				focus = _order().find(id)
				press(id)
			accept_event()

func _item_at(p: Vector2) -> int:
	for i in _items.size():
		if (_items[i]["rect"] as Rect2).has_point(p):
			return i
	return -1

## Keys while the screen is up (main.gd passes them here; Esc is main's: the controls).
func key(k: InputEventKey) -> void:
	if not k.pressed:
		return
	var o := _order()
	if o.is_empty():
		return
	var id := focused_id()
	var field := id in ["address", "name", "pass"]
	match k.keycode:
		KEY_TAB:
			focus = posmod(focus + (-1 if k.shift_pressed else 1), o.size())
			return
		KEY_DOWN:
			focus = mini(focus + 1, o.size() - 1)
			return
		KEY_UP:
			focus = maxi(focus - 1, 0)
			return
		KEY_ENTER, KEY_KP_ENTER:
			if field and id != "pass":
				focus += 1
			elif field:
				submit()
			else:
				press(id)
			return
		KEY_SPACE:
			if not field:
				press(id)
				return
		KEY_BACKSPACE:
			if field:
				_set_field(id, _field(id).left(maxi(0, _field(id).length() - 1)))
			return
	if field and k.is_command_or_control_pressed() and k.keycode == KEY_V:
		_type(id, DisplayServer.clipboard_get())
		return
	if field and k.unicode >= 32 and k.unicode < 127 and not k.is_command_or_control_pressed():
		_type(id, String.chr(k.unicode))

func _field(id: String) -> String:
	match id:
		"address":
			return address
		"name":
			return player_name
		"pass":
			return passphrase
	return ""

func _set_field(id: String, v: String) -> void:
	match id:
		"address":
			address = v.left(MAX_ADDRESS)
		"name":
			player_name = v.left(MAX_NAME)
		"pass":
			passphrase = v.left(MAX_PASS)

func _type(id: String, text: String) -> void:
	var clean := ""
	for i in text.length():
		var ch := text.unicode_at(i)
		if ch >= 32 and ch < 127:
			clean += String.chr(ch)
	_set_field(id, _field(id) + clean)

# --- drawing --------------------------------------------------------------------------------------

func _scale() -> float:
	return maxf(2.0, floor(minf(size.x / 240.0, size.y / 150.0)))

func _text(t: String, p: Vector2, px: float, col: Color) -> void:
	PixelFont.draw_shadowed(self, t, p, px, col)

func _centred(t: String, y: float, px: float, col: Color) -> void:
	_text(t, Vector2(floorf((size.x - PixelFont.width(t) * px) * 0.5), y), px, col)

func _button(id: String, label: String, centre: Vector2, px: float, wide: float = 0.0) -> void:
	var w := maxf(PixelFont.width(label) + 16, wide) * px
	var h := 15.0 * px
	var r := Rect2(Vector2(floorf(centre.x - w * 0.5), floorf(centre.y - h * 0.5)), Vector2(w, h))
	var on: bool = focused_id() == id or (_hover >= 0 and _hover < _items.size() and _items[_hover]["id"] == id)
	draw_rect(r, Color(0.02, 0.02, 0.025, 0.85))
	draw_rect(r, AMBER if on else DIM, false, px)
	_text(label, Vector2(floorf(centre.x - PixelFont.width(label) * px * 0.5), r.position.y + 4 * px), px, AMBER if on else PALE)
	_items.append({"kind": "button", "id": id, "rect": r})

func _field_box(id: String, label: String, value: String, y: float, px: float, w: float) -> void:
	var x := floorf((size.x - w * px) * 0.5)
	_text(label, Vector2(x, y), px, DIM)
	var r := Rect2(Vector2(x, y + 10 * px), Vector2(w * px, 13 * px))
	var on := focused_id() == id
	draw_rect(r, Color(0.0, 0.0, 0.0, 0.7))
	draw_rect(r, AMBER if on else DIM, false, px)
	var shown := value
	if id == "pass":
		shown = "#".repeat(value.length())
	var room := int((w - 8) / 6)
	if shown.length() > room - 1:
		shown = shown.right(room - 1)
	var caret := "|" if on and fmod(_caret_t, 1.0) < 0.6 else ""
	if shown.is_empty() and not on and id == "address":
		_text("WSS://YOUR-SERVER.EXAMPLE", r.position + Vector2(4, 3) * px, px, Color(0.45, 0.47, 0.45))
	else:
		_text(shown + caret, r.position + Vector2(4, 3) * px, px, PALE)
	_items.append({"kind": "field", "id": id, "rect": r})

func _draw() -> void:
	_items.clear()
	if screen == "":
		return
	var px := _scale()
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.35))
	var big := px * 2.0
	var top := size.y * 0.14
	_centred("GOING DOWN", top, big * (1.5 if screen == "title" else 1.0), AMBER)
	var cy := size.y * 0.5
	match screen:
		"title":
			_centred("A CO-OP HORROR ON TAPE", top + 18 * big + 4 * px, px, DIM)
			_button("alone", "PLAY ALONE", Vector2(size.x * 0.5, cy), px, 110)
			_button("join", "JOIN FRIENDS", Vector2(size.x * 0.5, cy + 22 * px), px, 110)
			if error != "":
				_wrapped(error, cy + 38 * px, px, WARN)
			_centred("ESC  CONTROLS", size.y - 16 * px, px, DIM)
		"join":
			var w := 150.0
			var y0 := top + 14 * big
			_field_box("address", "SERVER ADDRESS", address, y0, px, w)
			_field_box("name", "YOUR NAME", player_name, y0 + 27 * px, px, w)
			_field_box("pass", "PASSPHRASE - NEVER SAVED", passphrase, y0 + 54 * px, px, w)
			var by := y0 + 88 * px
			_button("go", "JOIN", Vector2(size.x * 0.5 - 40 * px, by), px, 64)
			_button("back", "BACK", Vector2(size.x * 0.5 + 40 * px, by), px, 64)
			if error != "":
				_wrapped(error, by + 12 * px, px, WARN)
		"connecting":
			var dots := ".".repeat(int(_caret_t * 3.0) % 4)
			_centred("CONNECTING" + dots, cy - 16 * px, px, PALE)
			_centred(address.to_upper(), cy - 4 * px, px, DIM)
			_button("back", "BACK", Vector2(size.x * 0.5, cy + 18 * px), px, 64)
		"lobby":
			_centred("IN THE ROOM", top + 14 * big, px, PALE)
			var y := top + 14 * big + 14 * px
			for p: Variant in people:
				var row: Array = p
				var label := str(row[1]).to_upper()
				if str(row[0]) == my_id:
					label += "  < YOU"
				_centred(label, y, px, AMBER if str(row[0]) == my_id else PALE)
				y += 11 * px
			var by := maxf(y + 10 * px, cy + 10 * px)
			if run_on:
				_centred("A RUN IS ON: YOU JOIN AT THE NEXT STOP", by - 8 * px, px, DIM)
			_button("start", "START", Vector2(size.x * 0.5 - 40 * px, by + 8 * px), px, 64)
			_button("leave", "LEAVE", Vector2(size.x * 0.5 + 40 * px, by + 8 * px), px, 64)
			_centred("ANYONE CAN START. EVERYONE HERE GOES DOWN.", by + 26 * px, px, DIM)

func _wrapped(text: String, y: float, px: float, col: Color) -> void:
	var rows := PixelFont.wrap(text, int(size.x / px / 6.0) - 4)
	for i in rows.size():
		_centred(rows[i], y + i * 10 * px, px, col)
