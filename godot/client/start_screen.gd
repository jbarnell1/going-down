# Before the game: the title, "Play alone" and "Join friends" (the server's address, your name, the
# passphrase), the plain-words errors, the orientation tape, and Ready-up (the lobby: the controls card, the
# crew, I'M READY; docs/floors/findables-and-day.md section 2, FD6). After either button comes "draw your
# face" (face/face_editor.tscn, North Star H1): it opens on this
# computer's last face, so Enter keeps it; Cancel keeps the last saved face (or none). The face is kept
# for the session (`face_code`) and sent only to the other players in the same run. Drawn
# crisp in the camcorder's pixel font over the taped picture, like the HUD. Keyboard (Tab / arrows,
# Enter, typing, Backspace, Ctrl+V) and mouse both work. It decides nothing about the network: main.gd
# connects and tells it what happened.
#
# The address and the name are remembered in user://join.cfg (not under automation). The passphrase
# is kept only in memory while the game runs: never written to disk, never printed.
#
# The orientation tape (client/orientation_tape.gd, docs/floors/story.md ST1) plays after joining and the
# face, before Ready-up, on this screen only, the first time on this PC: play_tape(). When it reaches its
# last shot or is skipped, `tape_seen` is kept in user://tape.cfg (never when it merely starts; never read or
# written under automation, like the hints' record). Ready-up's WATCH THE TAPE plays it again.
#
# Ready-up (the "lobby" screen): the controls card on the left (CARD_ROWS and CARD_LINES; Q and G of the
# design's table are left out until those keys do something in the game), I'M READY under it (Enter or a
# click; pressed again it is undone), and the crew on the right: face, name, READY, READING or WATCHING THE
# TAPE, a key by the host. Then GOING DOWN IN n while the count runs, the late joiner's line while a run is
# on, and START WITHOUT n for the host once allowed. main.gd tells it what the room says (people, host_id,
# count_left, ...) and does what its signals ask.
class_name StartScreen
extends Control

signal alone_pressed
signal join_pressed(address: String, player_name: String, passphrase: String)
signal back_pressed
signal start_pressed
signal leave_pressed
## Ready-up: I'M READY pressed (on) or undone (off); WATCH THE TAPE; the tape ended (shown again or first).
signal ready_pressed(on: bool)
signal watch_tape_pressed
signal tape_finished(skipped: bool)
## The screen shown changed ("" while playing): main.gd keeps its mode in step.
signal screen_shown(which: String)

const SETTINGS := "user://join.cfg"
## Where this player's `tape_seen` is kept (the orientation tape: once per player on this PC).
const TAPE_SAVE := "user://tape.cfg"
const OrientationTape = preload("res://client/orientation_tape.gd")
## The controls card (findables-and-day.md section 2): what a first-timer needs in the first minute. The
## design's Q (STICK AN ARROW) and G (DRINK) rows are left out: neither does anything in the game yet. The
## four-slot inventory (S1, skill-tree.md) adds its two rows after F; its brief gives G to dropping what you hold.
const CARD_ROWS: Array[Array] = [
	["W A S D, MOUSE", "WALK, LOOK"],
	["SHIFT", "SPRINT. IT TIRES YOU"],
	["CTRL OR C", "CREEP. QUIET"],
	["E", "INSTRUMENT OUT / AWAY"],
	["RIGHT MOUSE", "HOLD IT UP TO RECORD"],
	["F", "USE: CALL THE LIFT, SEARCH, HIDE, PICK UP"],
	["1 2 3 4, WHEEL", "PICK WHAT YOU HOLD"],
	["G", "DROP WHAT YOU HOLD"],
	["HOLD R", "EMOTES"],
	["ESC", "THIS CARD AGAIN"],
]
## The three lines under the card: the job, and nothing about how recording works (North Star C2).
const CARD_LINES: Array[String] = ["RECORD WHAT LIVES ON EACH FLOOR.", "MEET THE QUOTA. CALL THE LIFT.", "STAND ON BANK TO GO HOME, DOWN TO GO DEEPER."]
const READY_LINE := "ENTER OR CLICK: I'M READY"
const UNREADY_LINE := "READY. ENTER OR CLICK: NOT YET"
## The card's action column wraps at this many characters.
const CARD_WRAP := 26
## Ready-up ignores Enter and clicks this long after the tape ends (the skip is a held Enter or button).
const AFTER_TAPE_GUARD := 0.5
const MAX_ADDRESS := 200
const MAX_NAME := 16
const MAX_PASS := 128
const PALE := Color("#f4f4ec")
const AMBER := Color("#ffd27a")
const DIM := Color("#8f958f")
const WARN := Color("#ff8a6a")

## "title", "face", "join", "connecting", "tape", "lobby" (hidden while playing).
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
## Ready-up, as main.gd has it from the room: the host's id; seconds left of the count (-1: none); this
## player's READY; whether START WITHOUT is open to this player (the host, 30 s after readying); the run's
## floor (-1: none).
var host_id := ""
var count_left := -1.0
var my_ready := false
var without_ok := false
var run_depth := -1
## The orientation tape: seen by this player on this PC; kept in TAPE_SAVE (false under automation: never
## read or written, like the hints' record); the player while it plays.
var tape_seen := false
var persist_tape := true
var tape: OrientationTape = null
var _tape_ended_at := -INF
var _faces := {}  # face code -> texture (the crew list)
var focus := 0
## The face for this session (FaceCodec text, "" for none), and what comes after the face step:
## "alone" (the run), "join" (the form) or "join_submit" (the form, filled in by arguments, pressed).
var face_code := ""
var face_next := ""
var editor: FaceEditor = null
var _hover := -1
## The focusable items on the screen drawn last: [{kind: "button"|"field", id, rect}].
var _items: Array[Dictionary] = []
var _caret_t := 0.0

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_load()
	load_tape_seen()

## Reads `tape_seen` (nothing under automation: persist_tape false).
func load_tape_seen() -> void:
	if not persist_tape:
		return
	var cf := ConfigFile.new()
	if cf.load(TAPE_SAVE) == OK:
		tape_seen = bool(cf.get_value("tape", "seen", false))

## Whether the tape plays by itself on joining: never seen on this PC; under automation only when asked
## (`asked`: the tape=1 argument), so every scripted playthrough goes straight to Ready-up.
static func wants_tape(seen: bool, automated: bool, asked: bool) -> bool:
	if automated:
		return asked
	return not seen

## Plays the orientation tape full screen (the first join, or WATCH THE TAPE). `tape_seen` is not touched
## here: only when it reaches its last shot or is skipped (_on_tape_finished).
func play_tape() -> void:
	if tape == null:
		tape = OrientationTape.new()
		tape.name = "OrientationTape"
		tape.finished.connect(_on_tape_finished)
		add_child(tape)
	tape.visible = true
	tape.start()
	show_screen("tape")

func _on_tape_finished(skipped: bool) -> void:
	tape_seen = true
	if persist_tape:
		var cf := ConfigFile.new()
		cf.set_value("tape", "seen", true)
		cf.save(TAPE_SAVE)
	if tape != null:
		tape.visible = false
	_tape_ended_at = _caret_t
	tape_finished.emit(skipped)

## Players in the room not ready (START WITHOUT n leaves them).
func stragglers() -> int:
	var n := 0
	for p: Variant in people:
		var row: Array = p
		if not (row.size() > 2 and bool(row[2])) and not (row.size() > 4 and bool(row[4])):
			n += 1
	return n

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
	if editor != null:
		editor.visible = which == "face"
	if tape != null and which != "tape":
		tape.visible = false
		tape.playing = false
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
	screen_shown.emit(which)

## The face step, then `next` ("alone", "join" or "join_submit"). The editor opens on this session's
## face, else this computer's last one, else the smile: a returning player presses Enter.
func open_face(next: String) -> void:
	face_next = next
	if editor == null:
		editor = (load("res://face/face_editor.tscn") as PackedScene).instantiate() as FaceEditor
		editor.name = "FaceEditor"
		editor.remember = true
		editor.start_code = face_code
		editor.set_anchors_preset(Control.PRESET_FULL_RECT)
		editor.done.connect(_face_done)
		editor.cancelled.connect(_face_cancelled)
		add_child(editor)
	else:
		editor.begin(face_code)
	show_screen("face")

func _face_done(code: String, _texture: ImageTexture) -> void:
	face_code = code
	_after_face()

func _face_cancelled() -> void:
	face_code = FaceCodec.load_last()
	_after_face()

func _after_face() -> void:
	match face_next:
		"alone":
			alone_pressed.emit()
		"join":
			error = ""
			show_screen("join")
		"join_submit":
			show_screen("join")
			submit()

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
		"face":
			return []
		"join":
			return ["address", "name", "pass", "go", "back"]
		"connecting":
			return ["back"]
		"lobby":
			var o: Array[String] = ["ready"]
			if without_ok and stragglers() > 0 and run_depth < 0:
				o.append("without")
			o.append_array(["watch", "leave"])
			return o
	return []

func focused_id() -> String:
	var o := _order()
	return o[clampi(focus, 0, o.size() - 1)] if not o.is_empty() else ""

## Presses an item by id (the mouse, Enter, and the test hook all come here).
func press(id: String) -> void:
	match id:
		"alone":
			open_face("alone")
		"join":
			error = ""
			open_face("join")
		"go":
			submit()
		"back":
			back_pressed.emit()
		"start", "without":
			start_pressed.emit()
		"ready":
			if _caret_t - _tape_ended_at < AFTER_TAPE_GUARD:
				return
			my_ready = not my_ready
			ready_pressed.emit(my_ready)
		"watch":
			watch_tape_pressed.emit()
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
	if screen == "face":
		if editor != null:
			editor.key(k)
		return
	if screen == "tape":
		return   # the tape reads its own skip (Space or Enter held)
	if not k.pressed or (k.echo and screen == "lobby"):
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
	if screen == "face" or screen == "tape":
		return   # the editor (or the tape) draws the whole screen
	var px := _scale()
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.35))
	var big := px * 2.0
	var top := size.y * 0.14
	if screen != "lobby":   # Ready-up lays out its own, smaller title (_draw_ready)
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
			_draw_ready(px)
		"tape":
			pass

func _wrapped(text: String, y: float, px: float, col: Color) -> void:
	var rows := PixelFont.wrap(text, int(size.x / px / 6.0) - 4)
	for i in rows.size():
		_centred(rows[i], y + i * 10 * px, px, col)

# --- Ready-up -------------------------------------------------------------------------------------

## The label of a crew member's state: READY, READING or WATCHING THE TAPE (in the run: DOWN THERE).
static func crew_state(row: Array) -> String:
	if row.size() > 4 and bool(row[4]):
		return "DOWN THERE"
	if row.size() > 2 and bool(row[2]):
		return "READY"
	if row.size() > 3 and bool(row[3]):
		return "WATCHING THE TAPE"
	return "READING"

## The line over the crew: the count, the late joiner's wait, or nothing.
func status_line() -> String:
	if run_depth >= 0:
		var where := "IN THE PRISON" if run_depth == 0 else "ON FLOOR %d" % run_depth
		return "THE CREW IS %s. YOU JOIN AT THE NEXT STOP." % where
	if count_left >= 0.0:
		return "GOING DOWN IN %d" % maxi(1, ceili(count_left))
	return ""

## The card's rows as drawn: [key, action line] with long actions wrapped onto a second row.
static func card_lines() -> Array[Array]:
	var out: Array[Array] = []
	for row: Array in CARD_ROWS:
		var parts := PixelFont.wrap(str(row[1]), CARD_WRAP)
		for i in parts.size():
			out.append([str(row[0]) if i == 0 else "", parts[i]])
	return out

func _face_tex(code: String) -> Texture2D:
	if code == "":
		return null
	if not _faces.has(code):
		_faces[code] = FaceCodec.decode(code)
	return _faces[code]

func _draw_ready(_screen_px: float) -> void:
	var key_w := 0
	for row: Array in CARD_ROWS:
		key_w = maxi(key_w, PixelFont.width(str(row[0])))
	var card_w := key_w + 8 + CARD_WRAP * 6 + 12
	var under: Array[String] = []
	for l in CARD_LINES:
		under.append_array(Array(PixelFont.wrap(l, int((card_w - 12) / 6.0))))
	var lines := card_lines()
	var card_h := 16 + lines.size() * 10 + 6 + under.size() * 10 + 26
	var px := maxf(1.0, floorf(minf(size.x * 0.56 / card_w, size.y * 0.8 / (card_h + 30))))
	var pale := PALE
	# The title, small, then the count or the late joiner's line across the top.
	var top := floorf(size.y * 0.05)
	_centred("GOING DOWN", top, px * 2.0, AMBER)
	var line := status_line()
	if line != "":
		_centred(line, top + 22 * px, px * (2.0 if count_left >= 0.0 and run_depth < 0 else 1.0), AMBER if run_depth < 0 else pale)
	# The card, left.
	var o := Vector2(floorf(size.x * 0.04), top + 40 * px)
	draw_rect(Rect2(o, Vector2(card_w, card_h) * px), Color(0.02, 0.02, 0.025, 0.88))
	_text("CONTROLS", o + Vector2(6, 5) * px, px, AMBER)
	var y := 18.0
	for l: Array in lines:
		_text(str(l[0]), o + Vector2(6, y) * px, px, AMBER)
		_text(str(l[1]), o + Vector2(6 + key_w + 8, y) * px, px, pale)
		y += 10
	y += 6
	for u in under:
		_text(u, o + Vector2(6, y) * px, px, DIM)
		y += 10
	# I'M READY: the card's own button (Enter or a click).
	var label := UNREADY_LINE if my_ready else READY_LINE
	_button("ready", label, o + Vector2(card_w * 0.5, y + 10) * px, px, card_w - 12)
	# The crew, right.
	var cx := o.x + (card_w + 14) * px
	var cy := o.y
	_text("THE CREW", Vector2(cx, cy + 5 * px), px, AMBER)
	cy += 18 * px
	for p: Variant in people:
		var row: Array = p
		var id := str(row[0])
		var face := _face_tex(str(row[5]) if row.size() > 5 else "")
		var box := Rect2(Vector2(cx, cy), Vector2(16, 16) * px)
		draw_rect(box, Color(0.1, 0.1, 0.1, 0.9))
		if face != null:
			draw_texture_rect(face, box, false)
		draw_rect(box, DIM, false, maxf(1.0, px * 0.5))
		var nm := str(row[1]).to_upper() + ("  < YOU" if id == my_id else "")
		var nx := cx + 20 * px
		if id == host_id:
			_key_mark(Vector2(nx, cy + 2 * px), px)
			nx += 12 * px
		_text(nm, Vector2(nx, cy + 1 * px), px, AMBER if id == my_id else pale)
		var st := crew_state(row)
		_text(st, Vector2(cx + 20 * px, cy + 9 * px), px, AMBER if st == "READY" else DIM)
		cy += 21 * px
	# The host's valve, the tape again, and the way out.
	var bx := cx + 50 * px
	var by := maxf(cy + 12 * px, o.y + (card_h - 40) * px)
	if "without" in _order():
		_button("without", "START WITHOUT %d" % stragglers(), Vector2(bx, by), px, 96)
		by += 20 * px
	_button("watch", "WATCH THE TAPE", Vector2(bx, by), px, 96)
	by += 20 * px
	_button("leave", "LEAVE", Vector2(bx, by), px, 96)

## The host's key beside their name: a ring and a bit.
func _key_mark(at: Vector2, px: float) -> void:
	var c := AMBER
	draw_rect(Rect2(at, Vector2(4, 4) * px), c, false, px)
	draw_rect(Rect2(at + Vector2(4, 1.5) * px, Vector2(5, 1) * px), c)
	draw_rect(Rect2(at + Vector2(7, 2.5) * px, Vector2(1, 2) * px), c)
