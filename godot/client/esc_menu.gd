# EM1: the Esc menu, the way players expect a pause menu to read (.local/reviews/esc-menu-design.md): a short list
# walked with the arrows (or W and S) and Enter, or the mouse; Esc backs out one level and closes at the top.
#   top        RESUME (BACK on the start screen), SETTINGS, CONTROLS, HOST TOOLS (the host only), LEAVE RUN (in a
#              run), QUIT GAME (not on the web build)
#   settings   SOUND AND VOICE, MICROPHONE, BRIGHTNESS, HINTS ON/OFF, CAUGHT SCENES FULL/SOFT, BACK
#   controls   the key list, read-only: the HUD's own card (client/hud.gd menu_rows), drawn by the HUD
#   leave/quit a confirm with STAY chosen first
# The menu owns only where it is (page and row). Every setting keeps its one home: the sound page, the microphone
# rows and the caught scenes on the settings panel's YOUR SOUND page (client/settings_panel.gd), brightness on its
# card (client/brightness_card.gd), the hints on the announcer (client/hints.gd); the game (client/main.gd) does what a
# row asks through `chose`. The run does not pause behind it; the menu says so. No row names a resident's rule.
extends Control

## A row was chosen that the game carries out: "resume", "host", "leave", "quit", "sound", "mic", "brightness",
## "hints", "caught".
signal chose(id: String)

const TITLE := "PAUSE"
const RUN_NOTE := "THE RUN DOES NOT PAUSE"
const FOOT := "UP DOWN: CHOOSE   ENTER: OPEN   ESC: BACK"
const LEAVE_ASK := "LEAVE THIS RUN? YOUR CREW CARRIES ON WITHOUT YOU."
const QUIT_ASK := "QUIT TO DESKTOP? THIS RUN ENDS FOR YOU."
const QUIT_ASK_START := "QUIT TO DESKTOP?"
const MARGIN := 16.0
const LINE := 14
const AMBER := Color("#ffd27a")
const PALE := Color("#f4f4ec")
const GREY := Color(0.62, 0.64, 0.62)

## "top", "settings", "controls", "leave", "quit".
var page := "top"
var sel := 0
## What the game is doing (set by client/main.gd every frame).
var in_run := true
var is_host := false
var web := OS.has_feature("web")
var hints_on := true
var caught_soft := false
## Drawn this frame (the game decides: the HUD's menu in a run, the overlay on the start screen).
var shown := false
var _top_sel := 0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)

## Open at the top with the first row (RESUME) chosen.
func open_menu() -> void:
	page = "top"
	sel = 0
	_top_sel = 0
	queue_redraw()

## The rows of the page shown: [{id, label}].
func rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	match page:
		"top":
			out.append({"id": "resume", "label": "RESUME" if in_run else "BACK"})
			out.append({"id": "settings", "label": "SETTINGS"})
			out.append({"id": "controls", "label": "CONTROLS"})
			if in_run and is_host:
				out.append({"id": "host", "label": "HOST TOOLS"})
			if in_run:
				out.append({"id": "leave_ask", "label": "LEAVE RUN"})
			if not web:
				out.append({"id": "quit_ask", "label": "QUIT GAME"})
		"settings":
			out.append({"id": "sound", "label": "SOUND AND ANNOUNCER VOICE"})
			out.append({"id": "mic", "label": "MICROPHONE"})
			out.append({"id": "brightness", "label": "BRIGHTNESS"})
			out.append({"id": "hints", "label": "HINTS: ON" if hints_on else "HINTS: OFF"})
			out.append({"id": "caught", "label": "CAUGHT SCENES: SOFT" if caught_soft else "CAUGHT SCENES: FULL"})
			out.append({"id": "back", "label": "BACK"})
		"leave":
			out.append({"id": "back", "label": "STAY"})
			out.append({"id": "leave", "label": "LEAVE RUN"})
		"quit":
			out.append({"id": "back", "label": "STAY"})
			out.append({"id": "quit", "label": "QUIT GAME"})
	return out

func _heading() -> String:
	match page:
		"settings":
			return "SETTINGS"
		"leave":
			return LEAVE_ASK
		"quit":
			return QUIT_ASK if in_run else QUIT_ASK_START
	# Nothing to pause on the start screen.
	return TITLE if in_run else "MENU"

func _note() -> String:
	return RUN_NOTE if in_run and page in ["top", "settings"] else ""

## Esc: one level back; at the top the menu closes (the game resumes, "resume").
func back() -> void:
	match page:
		"top":
			chose.emit("resume")
		"settings", "controls":
			page = "top"
			sel = _top_sel
		_:
			page = "top"
			sel = _top_sel
	queue_redraw()

## The chosen row: a page of the menu's own, or the game's (`chose`).
func activate() -> void:
	var r := rows()
	if r.is_empty():
		return
	var id: String = r[clampi(sel, 0, r.size() - 1)]["id"]
	match id:
		"settings", "controls":
			_top_sel = sel
			page = id
			sel = 0
		"leave_ask":
			_top_sel = sel
			page = "leave"
			sel = 0   # STAY first
		"quit_ask":
			_top_sel = sel
			page = "quit"
			sel = 0   # STAY first
		"back":
			back()
		_:
			chose.emit(id)
	queue_redraw()

func move(d: int) -> void:
	var n := rows().size()
	if n > 0:
		sel = posmod(sel + d, n)
	queue_redraw()

## A key while the menu shows. True when the menu used it; every other key (the old direct keys H, B, V, M, N, T,
## F6, F8 and the game's own) is left for the game.
func key(k: InputEventKey) -> bool:
	if not k.pressed:
		return k.physical_keycode in [KEY_ESCAPE, KEY_UP, KEY_DOWN, KEY_W, KEY_S, KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]
	if page == "controls":
		if k.physical_keycode in [KEY_ESCAPE, KEY_ENTER, KEY_KP_ENTER, KEY_SPACE, KEY_BACKSPACE] and not k.echo:
			back()
			return true
		return false
	match k.physical_keycode:
		KEY_ESCAPE, KEY_BACKSPACE:
			if not k.echo:
				back()
			return true
		KEY_UP, KEY_W:
			move(-1)
			return true
		KEY_DOWN, KEY_S:
			move(1)
			return true
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			if not k.echo:
				activate()
			return true
		KEY_LEFT, KEY_RIGHT, KEY_A, KEY_D:
			if page in ["leave", "quit"]:
				move(1 if k.physical_keycode in [KEY_RIGHT, KEY_D] else -1)
				return true
			var r := rows()
			if not r.is_empty() and str(r[clampi(sel, 0, r.size() - 1)]["id"]) in ["hints", "caught"] and not k.echo:
				activate()
				return true
			return page != "top" and page != "settings"
	return false

## The mouse while the menu shows: hover chooses, a left click opens. True when used (every mouse event is, so no
## click reaches the game or the screens behind).
func mouse(e: InputEvent) -> bool:
	if page == "controls":
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			back()
		return true
	var lay := layout(size)
	var at := Vector2(-1, -1)
	if e is InputEventMouseMotion:
		at = (e as InputEventMouseMotion).position
	elif e is InputEventMouseButton:
		at = (e as InputEventMouseButton).position
	var hit := -1
	var rects: Array = lay["rows"]
	for i in rects.size():
		if (rects[i] as Rect2).has_point(at):
			hit = i
	if hit >= 0 and hit != sel:
		sel = hit
		queue_redraw()
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and hit >= 0:
			activate()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT:
			back()
	return true

## Where everything goes in a window of `s`: {sc, rect (the card), title, note (positions, window pixels), rows
## (Rect2 each), foot, w, h (font pixels)}.
func layout(s: Vector2) -> Dictionary:
	var r := rows()
	var heading := _heading()
	var note := _note()
	var w := maxi(PixelFont.width(heading), PixelFont.width(FOOT))
	w = maxi(w, PixelFont.width(note))
	for row: Dictionary in r:
		w = maxi(w, PixelFont.width(str(row["label"])) + 16)
	w += 24
	var top := 10 + 12 + (12 if note != "" else 0) + 8
	var h := top + r.size() * LINE + 10 + 12 + 6
	var sc := maxf(1.0, floorf(minf((s.x - 2.0 * MARGIN) / w, (s.y - 2.0 * MARGIN) / h)))
	sc = minf(sc, 6.0)
	var origin := Vector2(floorf((s.x - w * sc) * 0.5), floorf((s.y - h * sc) * 0.5))
	var rects: Array[Rect2] = []
	for i in r.size():
		rects.append(Rect2(origin + Vector2(8, top + i * LINE - 3) * sc, Vector2(w - 16, LINE - 1) * sc))
	return {"sc": sc, "w": w, "h": h, "rect": Rect2(origin, Vector2(w, h) * sc),
		"title": origin + Vector2(floorf((w - PixelFont.width(heading)) / 2.0), 10) * sc,
		"note": origin + Vector2(floorf((w - PixelFont.width(note)) / 2.0), 22) * sc,
		"rows": rects, "foot": origin + Vector2(floorf((w - PixelFont.width(FOOT)) / 2.0), h - 6 - 9) * sc}

func _process(_dt: float) -> void:
	if shown:
		queue_redraw()

func _draw() -> void:
	if not shown or page == "controls":
		return
	var lay := layout(size)
	var sc: float = lay["sc"]
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.62))
	var card: Rect2 = lay["rect"]
	draw_rect(card, Color(0.02, 0.02, 0.025, 0.94))
	# The company's tape: an amber strip across the card's top.
	draw_rect(Rect2(card.position, Vector2(card.size.x, 3 * sc)), AMBER)
	PixelFont.draw_shadowed(self, _heading(), lay["title"], sc, AMBER)
	var note := _note()
	if note != "":
		PixelFont.draw_shadowed(self, note, lay["note"], sc, GREY)
	var r := rows()
	var rects: Array = lay["rows"]
	for i in r.size():
		var box: Rect2 = rects[i]
		var on := i == sel
		if on:
			draw_rect(box, Color(AMBER, 0.16))
			draw_rect(box, AMBER, false, sc)
		var label: String = r[i]["label"]
		var col := AMBER if on else PALE
		if str(r[i]["id"]) in ["leave_ask", "quit_ask", "leave", "quit"] and not on:
			col = Color("#d8a090")
		PixelFont.draw_shadowed(self, label, Vector2(box.position.x + floorf((box.size.x - PixelFont.width(label) * sc) * 0.5), box.position.y + 3 * sc), sc, col)
	PixelFont.draw_shadowed(self, FOOT, lay["foot"], sc, GREY)

## Tests: where the menu is.
func describe() -> Dictionary:
	return {"page": page, "sel": sel, "rows": rows().map(func(r: Dictionary) -> String: return str(r["id"])), "shown": shown}
