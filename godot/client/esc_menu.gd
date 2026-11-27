# EM1: the Esc menu, the way players expect a pause menu to read (.local/reviews/esc-menu-design.md): a short list
# walked with the arrows (or W and S) and Enter, or the mouse; Esc backs out one level and closes at the top.
#   top        RESUME (BACK on the start screen), SETTINGS, CONTROLS, HOST TOOLS (the host only), LEAVE RUN (in a
#              run), QUIT GAME (not on the web build)
#   settings   HU2: tabs, GAME, SOUND, MICROPHONE, PICTURE, CONTROLS (client/settings_tabs.gd), each a list of rows
#              changed in place with left and right (or a click on < and >); Q and E (or left and right on the tab
#              bar, or a click) change the tab; BACK last on every tab
#   controls   the key list, read-only: the HUD's own card (client/hud.gd menu_rows), drawn by the HUD
#   leave/quit a confirm with STAY chosen first
#   end        HP1b: END RUN: BACK TO THE LOBBY, the host of a host-playtest run only; a confirm with STAY first
# The menu owns only where it is (page and row). Every setting keeps its one home: the sound page, the microphone
# rows and the caught scenes on the settings panel's YOUR SOUND page (client/settings_panel.gd), brightness on its
# card (client/brightness_card.gd), the hints on the announcer (client/hints.gd); the game (client/main.gd) does what a
# row asks through `chose`. The run does not pause behind it; the menu says so. No row names a resident's rule.
extends Control

## A row was chosen that the game carries out: "resume", "host", "leave", "quit", "sound", "mic", "brightness",
## "hints", "caught"; HU2: "bright_card" (the brightness card), "mic_calib" (calibrate the microphone).
signal chose(id: String)

const SettingsTabs = preload("res://client/settings_tabs.gd")
## HU2: the settings' tabs and what each row changes (the game sets its owners).
var tabs := SettingsTabs.new()
## HU2: the tab shown (an index of SettingsTabs.TABS); on the settings page `sel` -1 is the tab bar itself.
var tab := 0
## HU2: the first row shown of a tab longer than VIS rows (CONTROLS).
var scroll := 0
const VIS := 9
const SETTINGS_FOOT := "Q E: TAB   UP DOWN: CHOOSE   LEFT RIGHT: CHANGE   ESC: BACK"
## HU2: the value column's width (font pixels): < bar value > for a per cent, < value > for the rest.
const VAL_W := 100
const BAR_W := 44
## HU2: the CONTROLS tab's key column (font pixels): the longest key the card has, HOLD F BY A FRIEND.
const KEY_COL_W := 107

const TITLE := "PAUSE"
const RUN_NOTE := "THE RUN DOES NOT PAUSE"
const FOOT := "UP DOWN: CHOOSE   ENTER: OPEN   ESC: BACK"
const LEAVE_ASK := "LEAVE THIS RUN? YOUR CREW CARRIES ON WITHOUT YOU."
const QUIT_ASK := "QUIT TO DESKTOP? THIS RUN ENDS FOR YOU."
const QUIT_ASK_START := "QUIT TO DESKTOP?"
const END_ASK := "END THIS PLAYTEST? EVERYONE RETURNS TO THE LOBBY."
const MARGIN := 16.0
const LINE := 14
const AMBER := Color("#ffd27a")
const PALE := Color("#f4f4ec")
const GREY := Color(0.62, 0.64, 0.62)
## LK1: the menu's own canvas layer (client/main.gd), above the HUD (layer 0), the noise meter and microphone cards
## (49) and the host's settings panel (50): nothing the game draws shows over the card or a confirm.
const LAYER := 52
## LK1: the dim over the whole window, and the card itself: opaque, so no HUD counter shows through it.
const DIM := Color(0, 0, 0, 0.7)
const CARD := Color(0.02, 0.02, 0.025, 1.0)
## The confirms: while one shows, it is the top-most thing and keeps the keys (F8 does not open the panel over it).
const CONFIRMS: Array[String] = ["leave", "quit", "end"]

## "top", "settings", "controls", "leave", "quit".
var page := "top"
var sel := 0
## What the game is doing (set by client/main.gd every frame).
var in_run := true
var is_host := false
## HP1b: the run on is a host playtest of a shared room (the room's lobby says "playtest").
var playtest := false
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
			# HP1b: the host of a host-playtest run (never a campaign run) can end it for everyone.
			if in_run and is_host and playtest:
				out.append({"id": "end_ask", "label": "END RUN: BACK TO THE LOBBY"})
			if in_run:
				out.append({"id": "leave_ask", "label": "LEAVE RUN"})
			if not web:
				out.append({"id": "quit_ask", "label": "QUIT GAME"})
		"settings":
			return tabs.rows(tab_id())
		"leave":
			out.append({"id": "back", "label": "STAY"})
			out.append({"id": "leave", "label": "LEAVE RUN"})
		"quit":
			out.append({"id": "back", "label": "STAY"})
			out.append({"id": "quit", "label": "QUIT GAME"})
		"end":
			out.append({"id": "back", "label": "STAY"})
			out.append({"id": "end", "label": "END RUN"})
	return out

func _heading() -> String:
	match page:
		"settings":
			return "SETTINGS"
		"leave":
			return LEAVE_ASK
		"quit":
			return QUIT_ASK if in_run else QUIT_ASK_START
		"end":
			return END_ASK
	# Nothing to pause on the start screen.
	return TITLE if in_run else "MENU"

func _note() -> String:
	return RUN_NOTE if in_run and page in ["top", "settings"] else ""

## HU2: the tab shown, by name ("game", "sound", "mic", "picture", "controls").
func tab_id() -> String:
	return SettingsTabs.TABS[clampi(tab, 0, SettingsTabs.TABS.size() - 1)]

## HU2: tab `i` (wrapping), its first row chosen (or the tab bar kept when it had the keys).
func set_tab(i: int) -> void:
	tab = posmod(i, SettingsTabs.TABS.size())
	scroll = 0
	if sel >= 0:
		sel = 0
	queue_redraw()

## HU2: the chosen row's setting `dir` steps (Shift: five). True when it changed.
func nudge(dir: int, n := 1) -> bool:
	var r := rows()
	if page != "settings" or sel < 0 or sel >= r.size():
		return false
	var changed := tabs.nudge(str(r[sel]["id"]), dir, n)
	queue_redraw()
	return changed

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
	if page == "settings":
		# HU2: a row of a tab: a toggle or choice moves on in place; an action is the game's; BACK goes up.
		if sel < 0:
			sel = 0
			queue_redraw()
			return
		var act := tabs.activate(str(r[clampi(sel, 0, r.size() - 1)]["id"]))
		if act == "back":
			back()
		elif act != "":
			chose.emit(act)
		queue_redraw()
		return
	var id: String = r[clampi(sel, 0, r.size() - 1)]["id"]
	match id:
		"settings", "controls":
			_top_sel = sel
			page = id
			sel = 0
			if id == "settings":
				tab = 0
				scroll = 0
		"leave_ask":
			_top_sel = sel
			page = "leave"
			sel = 0   # STAY first
		"quit_ask":
			_top_sel = sel
			page = "quit"
			sel = 0   # STAY first
		"end_ask":
			_top_sel = sel
			page = "end"
			sel = 0   # STAY first
		"back":
			back()
		_:
			chose.emit(id)
	queue_redraw()

func move(d: int) -> void:
	var n := rows().size()
	if page == "settings":
		# HU2: -1 is the tab bar, above the first row; the list scrolls to keep the chosen row in view.
		sel = posmod(sel + 1 + d, n + 1) - 1
		if sel >= 0:
			scroll = clampi(scroll, sel - VIS + 1, sel)
		scroll = clampi(scroll, 0, maxi(0, n - VIS))
	elif n > 0:
		sel = posmod(sel + d, n)
	queue_redraw()

## A key while the menu shows. True when the menu used it; every other key (the old direct keys H, B, V, M, N, T,
## F6, F8 and the game's own) is left for the game.
func key(k: InputEventKey) -> bool:
	if not k.pressed:
		return k.physical_keycode in [KEY_ESCAPE, KEY_UP, KEY_DOWN, KEY_W, KEY_S, KEY_ENTER, KEY_KP_ENTER, KEY_SPACE] \
			or (page == "settings" and k.physical_keycode in [KEY_LEFT, KEY_RIGHT, KEY_A, KEY_D, KEY_Q, KEY_E, KEY_PAGEUP, KEY_PAGEDOWN])
	if page == "settings" and _settings_key(k):
		return true
	if page == "controls":
		if k.physical_keycode in [KEY_ESCAPE, KEY_ENTER, KEY_KP_ENTER, KEY_SPACE, KEY_BACKSPACE] and not k.echo:
			back()
			return true
		return false
	# LK1: a confirm stays the top-most thing: the host panel's F8 waits until it is answered.
	if page in CONFIRMS and k.physical_keycode == KEY_F8:
		return true
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
			if page in ["leave", "quit", "end"]:
				move(1 if k.physical_keycode in [KEY_RIGHT, KEY_D] else -1)
				return true
			var r := rows()
			if not r.is_empty() and str(r[clampi(sel, 0, r.size() - 1)]["id"]) in ["hints", "caught"] and not k.echo:
				activate()
				return true
			return page != "top" and page != "settings"
	return false

## HU2: the settings page's own keys: Q and E (Page Up and Down) the tab; left and right (A and D) the chosen row's
## setting, or the tab on the tab bar. True when used.
func _settings_key(k: InputEventKey) -> bool:
	var code := k.physical_keycode
	if code == KEY_Q or code == KEY_PAGEUP:
		set_tab(tab - 1)
		return true
	if code == KEY_E or code == KEY_PAGEDOWN:
		set_tab(tab + 1)
		return true
	if code in [KEY_LEFT, KEY_RIGHT, KEY_A, KEY_D]:
		var dir := 1 if code in [KEY_RIGHT, KEY_D] else -1
		if sel < 0:
			set_tab(tab + dir)
		else:
			var r := rows()
			var kind := str(r[clampi(sel, 0, r.size() - 1)]["kind"])
			# A toggle moves only on a fresh press; a slider repeats while held.
			if kind in ["pct", "level"] or not k.echo:
				nudge(dir, 5 if k.shift_pressed else 1)
		return true
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
	if page == "settings":
		return _settings_mouse(e, lay, at)
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

## HU2: the settings page's mouse: hover chooses a row, a click on a tab shows it, on < or > steps the row, anywhere
## else on a row does what Enter would; the wheel scrolls a long tab; the right button backs out.
func _settings_mouse(e: InputEvent, lay: Dictionary, at: Vector2) -> bool:
	var rects: Array = lay["rows"]
	var first: int = lay["first"]
	var hit := -1
	for i in rects.size():
		if (rects[i] as Rect2).has_point(at):
			hit = first + i
	if hit >= 0 and hit != sel:
		sel = hit
		queue_redraw()
	if not e is InputEventMouseButton:
		return true
	var mb := e as InputEventMouseButton
	if not mb.pressed:
		return true
	match mb.button_index:
		MOUSE_BUTTON_RIGHT:
			back()
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
			var n := rows().size()
			scroll = clampi(scroll + (-1 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1), 0, maxi(0, n - VIS))
			queue_redraw()
		MOUSE_BUTTON_LEFT:
			var tab_rects: Array = lay["tabs"]
			for i in tab_rects.size():
				if (tab_rects[i] as Rect2).has_point(at):
					sel = -1
					set_tab(i)
					return true
			if hit < 0:
				return true
			var arrows: Array = lay["arrows"]
			var pair: Array = arrows[hit - first]
			if not pair.is_empty() and (pair[0] as Rect2).has_point(at):
				nudge(-1)
			elif not pair.is_empty() and (pair[1] as Rect2).has_point(at):
				nudge(1)
			else:
				activate()
	return true

## HU2: the settings page in a window of `s`. The card is the same size on every tab (wide enough for the widest row
## of any tab, tall enough for VIS rows), so it does not jump when the tab changes. {sc, rect, title, note, tabs (Rect2
## each), rows (Rect2 each of the rows shown), first (the first row shown), arrows ([< rect, > rect] per row shown, []
## for none), foot, w, h}.
func settings_layout(s: Vector2) -> Dictionary:
	var heading := _heading()
	var note := _note()
	var w := maxi(PixelFont.width(heading), PixelFont.width(SETTINGS_FOOT))
	w = maxi(w, PixelFont.width(note))
	var tab_w := 0
	for t: String in SettingsTabs.TABS:
		tab_w += PixelFont.width(str(SettingsTabs.TAB_NAMES[t])) + 12
	w = maxi(w, tab_w + 4 * (SettingsTabs.TABS.size() - 1))
	for t: String in SettingsTabs.TABS:
		for row: Dictionary in tabs.rows(t):
			w = maxi(w, _row_width(row) + 16)
	w += 20
	var top := 10 + 12 + (12 if note != "" else 0) + 4
	var rows_y := top + 13 + 8
	var h := rows_y + VIS * LINE + 10 + 12 + 6
	var sc := maxf(1.0, floorf(minf((s.x - 2.0 * MARGIN) / w, (s.y - 2.0 * MARGIN) / h)))
	sc = minf(sc, 6.0)
	var origin := Vector2(floorf((s.x - w * sc) * 0.5), floorf((s.y - h * sc) * 0.5))
	var trs: Array[Rect2] = []
	var x := floorf((w - tab_w - 4 * (SettingsTabs.TABS.size() - 1)) * 0.5)
	for t: String in SettingsTabs.TABS:
		var tw := PixelFont.width(str(SettingsTabs.TAB_NAMES[t])) + 12
		trs.append(Rect2(origin + Vector2(x, top) * sc, Vector2(tw, 13) * sc))
		x += tw + 4
	var r := rows()
	scroll = clampi(scroll, 0, maxi(0, r.size() - VIS))
	var rects: Array[Rect2] = []
	var arrows: Array = []
	for i in range(scroll, mini(r.size(), scroll + VIS)):
		var box := Rect2(origin + Vector2(8, rows_y + (i - scroll) * LINE - 3) * sc, Vector2(w - 16, LINE - 1) * sc)
		rects.append(box)
		if str(r[i]["kind"]) in ["pct", "level", "toggle", "choice"]:
			var vx := box.end.x - (VAL_W + 4) * sc
			arrows.append([Rect2(Vector2(vx, box.position.y), Vector2(12, LINE - 1) * sc),
				Rect2(Vector2(box.end.x - 16 * sc, box.position.y), Vector2(12, LINE - 1) * sc)])
		else:
			arrows.append([])
	return {"sc": sc, "w": w, "h": h, "rect": Rect2(origin, Vector2(w, h) * sc),
		"title": origin + Vector2(floorf((w - PixelFont.width(heading)) / 2.0), 10) * sc,
		"note": origin + Vector2(floorf((w - PixelFont.width(note)) / 2.0), 22) * sc,
		"tabs": trs, "rows": rects, "first": scroll, "arrows": arrows,
		"foot": origin + Vector2(floorf((w - PixelFont.width(SETTINGS_FOOT)) / 2.0), h - 6 - 9) * sc}

## HU2: the font pixels a settings row needs: its words and its value column (a key row: the key, a gap, its action).
static func _row_width(row: Dictionary) -> int:
	match str(row["kind"]):
		"key":
			return 6 + KEY_COL_W + 8 + PixelFont.width(str(row["value"])) + 4
		"pct", "level", "toggle", "choice":
			return 6 + PixelFont.width(str(row["label"])) + 12 + VAL_W + 4
	return PixelFont.width(str(row["label"])) + 16

## Where everything goes in a window of `s`: {sc, rect (the card), title, note (positions, window pixels), rows
## (Rect2 each), foot, w, h (font pixels)}.
func layout(s: Vector2) -> Dictionary:
	if page == "settings":
		return settings_layout(s)
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
	# LK1: on its own canvas layer it follows the window itself (as the HUD does).
	var want := get_viewport_rect().size
	if size != want:
		position = Vector2.ZERO
		size = want
	if shown:
		queue_redraw()

func _draw() -> void:
	if not shown or page == "controls":
		return
	var lay := layout(size)
	var sc: float = lay["sc"]
	draw_rect(Rect2(Vector2.ZERO, size), DIM)
	var card: Rect2 = lay["rect"]
	draw_rect(card, CARD)
	# The company's tape: an amber strip across the card's top.
	draw_rect(Rect2(card.position, Vector2(card.size.x, 3 * sc)), AMBER)
	PixelFont.draw_shadowed(self, _heading(), lay["title"], sc, AMBER)
	var note := _note()
	if note != "":
		PixelFont.draw_shadowed(self, note, lay["note"], sc, GREY)
	if page == "settings":
		_draw_settings(lay, sc)
		return
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
		if str(r[i]["id"]) in ["leave_ask", "quit_ask", "leave", "quit", "end_ask", "end"] and not on:
			col = Color("#d8a090")
		PixelFont.draw_shadowed(self, label, Vector2(box.position.x + floorf((box.size.x - PixelFont.width(label) * sc) * 0.5), box.position.y + 3 * sc), sc, col)
	PixelFont.draw_shadowed(self, FOOT, lay["foot"], sc, GREY)

## LK1: whether the menu is drawn, given whether the game wants it, whether the host's settings panel (F8, HOST
## TOOLS) is open and whether the brightness card is: a panel or card opened from the menu replaces it (the menu comes
## back when it closes), so the menu's text never ghosts behind the panel.
static func drawn_over(wanted: bool, panel_open: bool, card_open: bool) -> bool:
	return wanted and not panel_open and not card_open

## Tests: where the menu is.
func describe() -> Dictionary:
	var d := {"page": page, "sel": sel, "rows": rows().map(func(r: Dictionary) -> String: return str(r["id"])), "shown": shown}
	if page == "settings":
		d["tab"] = tab_id()
		d["values"] = rows().map(func(r: Dictionary) -> String: return "%s=%s" % [str(r["label"]), str(r.get("value", ""))])
	return d

## HU2: the tab bar, the tab's rows (the words left, the value right between < and >; a per cent as a bar), the
## scroll marks of a long tab, the foot.
func _draw_settings(lay: Dictionary, sc: float) -> void:
	var trs: Array = lay["tabs"]
	for i in trs.size():
		var tb: Rect2 = trs[i]
		var name := str(SettingsTabs.TAB_NAMES[SettingsTabs.TABS[i]])
		var on := i == tab
		draw_rect(tb, Color(AMBER, 0.85) if on else Color(0.12, 0.12, 0.13))
		if on and sel < 0:
			draw_rect(tb.grow(sc), PALE, false, sc)
		PixelFont.draw(self, name, tb.position + Vector2(6, 3) * sc, sc, Color(0.05, 0.04, 0.02) if on else PALE)
	if not trs.is_empty():
		var under: Rect2 = trs[0]
		var card: Rect2 = lay["rect"]
		draw_rect(Rect2(Vector2(card.position.x + 8 * sc, under.end.y), Vector2(card.size.x - 16 * sc, sc)), Color(AMBER, 0.85))
	var r := rows()
	var rects: Array = lay["rows"]
	var first: int = lay["first"]
	var arrows: Array = lay["arrows"]
	for j in rects.size():
		var i := first + j
		var box: Rect2 = rects[j]
		var row: Dictionary = r[i]
		var on := i == sel
		if on:
			draw_rect(box, Color(AMBER, 0.16))
			draw_rect(box, AMBER, false, sc)
		var kind := str(row["kind"])
		var label := str(row["label"])
		var ty := box.position.y + 3 * sc
		match kind:
			"back":
				PixelFont.draw_shadowed(self, label, Vector2(box.position.x + floorf((box.size.x - PixelFont.width(label) * sc) * 0.5), ty), sc, AMBER if on else PALE)
			"key":
				var kx := box.position.x + (6 + KEY_COL_W) * sc
				PixelFont.draw_shadowed(self, label, Vector2(kx - PixelFont.width(label) * sc, ty), sc, AMBER)
				PixelFont.draw_shadowed(self, str(row["value"]), Vector2(kx + 8 * sc, ty), sc, PALE)
			"action":
				PixelFont.draw_shadowed(self, label, Vector2(box.position.x + 6 * sc, ty), sc, AMBER if on else PALE)
				if on:
					PixelFont.draw_shadowed(self, "ENTER", Vector2(box.end.x - (PixelFont.width("ENTER") + 6) * sc, ty), sc, GREY)
			_:
				PixelFont.draw_shadowed(self, label, Vector2(box.position.x + 6 * sc, ty), sc, AMBER if on else PALE)
				_draw_value(row, box, arrows[j] as Array, on, sc)
	var n := r.size()
	if first > 0 and not rects.is_empty():
		var b0: Rect2 = rects[0]
		PixelFont.draw(self, "▲", Vector2(b0.end.x + sc, b0.position.y + 3 * sc), sc, GREY)
	if first + rects.size() < n and not rects.is_empty():
		var b1: Rect2 = rects[rects.size() - 1]
		PixelFont.draw(self, "▼", Vector2(b1.end.x + sc, b1.position.y + 3 * sc), sc, GREY)
	PixelFont.draw_shadowed(self, SETTINGS_FOOT, lay["foot"], sc, GREY)

## HU2: a row's value between its arrows; a per cent also as a bar (the microphone's live level under it).
func _draw_value(row: Dictionary, box: Rect2, pair: Array, on: bool, sc: float) -> void:
	if pair.is_empty():
		return
	var lt: Rect2 = pair[0]
	var rt: Rect2 = pair[1]
	var arrow_col := AMBER if on else Color(GREY, 0.6)
	var ty := box.position.y + 3 * sc
	PixelFont.draw(self, "<", Vector2(lt.position.x + 3 * sc, ty), sc, arrow_col)
	PixelFont.draw(self, ">", Vector2(rt.position.x + 3 * sc, ty), sc, arrow_col)
	var value := str(row["value"])
	var left := lt.end.x + 2 * sc
	var right := rt.position.x - 2 * sc
	var frac := float(row["frac"])
	if frac >= 0.0:
		var bar := Rect2(Vector2(left, box.position.y + 5 * sc), Vector2(BAR_W * sc, 3 * sc))
		draw_rect(bar.grow(sc * 0.5), Color(0, 0, 0, 0.8))
		draw_rect(Rect2(bar.position, Vector2(bar.size.x * clampf(frac, 0.0, 1.0), bar.size.y)), AMBER if on else Color(PALE, 0.75))
		var meter := int(row.get("meter", -1))
		if meter >= 0:
			draw_rect(Rect2(bar.position + Vector2(0, 4 * sc), Vector2(bar.size.x * clampf(meter / 15.0, 0.0, 1.0), sc)), Color("#9fe0a0"))
		PixelFont.draw_shadowed(self, value, Vector2(right - PixelFont.width(value) * sc, ty), sc, AMBER if on else PALE)
	else:
		PixelFont.draw_shadowed(self, value, Vector2(floorf((left + right - PixelFont.width(value) * sc) * 0.5), ty), sc, AMBER if on else PALE)
