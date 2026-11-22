# EM1: the Esc menu reads like other games' pause menus (client/esc_menu.gd; .local/reviews/esc-menu-design.md).
#   1. the top level: RESUME first and chosen, SETTINGS, CONTROLS, HOST TOOLS for the host only, LEAVE RUN in a run
#      only, QUIT GAME except on the web; on the start screen RESUME reads BACK;
#   2. every setting that was behind a key before is reachable from the menu (sound and voice, microphone,
#      brightness, hints, caught scenes, the key list, the host's panel) and does what that key did;
#   3. Esc backs out one level and at the top closes the menu (the game resumes); RESUME takes the mouse again
#      exactly as a click on the old card did (never under automation);
#   4. LEAVE RUN and QUIT GAME do nothing until confirmed, and the confirm starts on STAY;
#   5. at the eight window sizes of test_esc_card, on every page, the card is inside the window, every row inside the
#      card, no two rows, the heading, the note or the foot overlap, and each label fits its row; 1280x720 is big;
#   6. the old direct keys (H, B, V, M, N, T, F6, F8) are left for the game; the mouse hovers and clicks rows;
#   7. the HUD hides world prompts while the menu shows and draws its key list only on CONTROLS.
extends RefCounted

const T = preload("res://tests/t.gd")
const EscMenu = preload("res://client/esc_menu.gd")
const Main = preload("res://client/main.gd")

const SIZES: Array[Vector2] = [Vector2(1024, 600), Vector2(1280, 720), Vector2(1366, 768), Vector2(1920, 1080), Vector2(2560, 1440), Vector2(3840, 2160), Vector2(1280, 1024), Vector2(1600, 900)]

static func _menu(in_run: bool, host: bool, web := false) -> Control:
	var m: Control = EscMenu.new()
	m.in_run = in_run
	m.is_host = host
	m.web = web
	m.shown = true
	m.size = Vector2(1280, 720)
	m.open_menu()
	return m

static func _ids(m: Control) -> Array:
	return m.describe()["rows"]

static func _key(code: Key) -> InputEventKey:
	var k := InputEventKey.new()
	k.physical_keycode = code
	k.pressed = true
	return k

func test_the_top_level(t: T) -> void:
	var m := _menu(true, true)
	t.eq(_ids(m), ["resume", "settings", "controls", "host", "leave_ask", "quit_ask"], "a host in a run: every row")
	t.eq(int(m.sel), 0, "RESUME is chosen on open")
	t.eq(str(m.rows()[0]["label"]), "RESUME", "it reads RESUME in a run")
	m.free()
	m = _menu(true, false)
	t.eq(_ids(m), ["resume", "settings", "controls", "leave_ask", "quit_ask"], "a guest has no HOST TOOLS")
	m.free()
	m = _menu(false, true)
	t.eq(_ids(m), ["resume", "settings", "controls", "quit_ask"], "the start screen: no LEAVE RUN, no HOST TOOLS")
	t.eq(str(m.rows()[0]["label"]), "BACK", "on the start screen RESUME reads BACK")
	m.free()
	m = _menu(true, false, true)
	t.check(not _ids(m).has("quit_ask"), "the web build has no QUIT GAME")
	m.free()

func test_every_setting_is_reachable(t: T) -> void:
	var m := _menu(true, true)
	var got: Array = []
	m.chose.connect(func(id: String) -> void: got.append(id))
	m.sel = _ids(m).find("settings")
	m.activate()
	t.eq(str(m.page), "settings", "SETTINGS opens its page")
	for id: String in ["sound", "mic", "brightness", "hints", "caught"]:
		var at := _ids(m).find(id)
		t.check(at >= 0, "%s is on the settings page" % id)
		m.sel = at
		m.activate()
		t.eq(got.back() if not got.is_empty() else "", id, "choosing %s asks the game for it" % id)
	m.back()
	m.sel = _ids(m).find("host")
	m.activate()
	t.eq(got.back(), "host", "HOST TOOLS asks for the F8 panel")
	m.sel = _ids(m).find("controls")
	m.activate()
	t.eq(str(m.page), "controls", "CONTROLS shows the key list")
	m.free()
	# The game does each with the code the old key used: one home per setting.
	var src := FileAccess.get_file_as_string("res://client/main.gd")
	var body := src.substr(src.find("func _esc_chose("), 1400)
	for want: String in ["settings_panel.open()", "_open_sound()", "mic_row_index()", "_open_brightness()", "_set_hints(not announcer.hints.enabled)", "settings_panel.caught_set(not caught_pref.soft)", "_back_to_title()", "get_tree().quit()"]:
		t.check(body.contains(want), "the menu uses %s" % want)
	# The labels follow the settings they show.
	m = _menu(true, false)
	m.page = "settings"
	m.hints_on = false
	m.caught_soft = true
	var labels: Array = m.rows().map(func(r: Dictionary) -> String: return str(r["label"]))
	t.check(labels.has("HINTS: OFF") and labels.has("CAUGHT SCENES: SOFT"), "the rows say the setting as it is (%s)" % str(labels))
	m.free()

func test_esc_backs_out_one_level(t: T) -> void:
	var m := _menu(true, false)
	var got: Array = []
	m.chose.connect(func(id: String) -> void: got.append(id))
	m.sel = 1
	m.activate()
	t.eq(str(m.page), "settings", "into SETTINGS")
	t.check(m.key(_key(KEY_ESCAPE)), "Esc is the menu's")
	t.eq([str(m.page), int(m.sel)], ["top", 1], "Esc: back to the top, on SETTINGS")
	t.check(got.is_empty(), "nothing closed yet")
	m.sel = 2
	m.activate()
	t.eq(str(m.page), "controls", "into CONTROLS")
	m.key(_key(KEY_ESCAPE))
	t.eq(str(m.page), "top", "Esc from CONTROLS: the top")
	m.key(_key(KEY_ESCAPE))
	t.eq(got, ["resume"], "Esc at the top closes the menu (resume)")
	m.sel = 0
	m.key(_key(KEY_ENTER))
	t.eq(got, ["resume", "resume"], "Enter on RESUME resumes")
	m.key(_key(KEY_DOWN))
	t.eq(int(m.sel), 1, "Down chooses the next row")
	m.key(_key(KEY_W))
	t.eq(int(m.sel), 0, "W the one before")
	m.key(_key(KEY_UP))
	t.eq(int(m.sel), _ids(m).size() - 1, "Up from the first wraps to the last")
	m.free()
	t.eq(Main.esc_resume_mode(false, Input.MOUSE_MODE_VISIBLE), Input.MOUSE_MODE_CAPTURED, "RESUME takes the mouse again")
	t.eq(Main.esc_resume_mode(true, Input.MOUSE_MODE_VISIBLE), Input.MOUSE_MODE_VISIBLE, "never under automation")
	var src := FileAccess.get_file_as_string("res://client/main.gd")
	var body := src.substr(src.find("func _esc_resume("), 400)
	t.check(body.contains("_esc_menu = false") and body.contains("Input.mouse_mode = esc_resume_mode(automated, Input.mouse_mode)"), "RESUME clears the menu and sets the mouse")

func test_leave_and_quit_need_a_confirm(t: T) -> void:
	for ask: String in ["leave_ask", "quit_ask"]:
		var m := _menu(true, false)
		var got: Array = []
		m.chose.connect(func(id: String) -> void: got.append(id))
		m.sel = _ids(m).find(ask)
		m.activate()
		t.check(got.is_empty(), "%s: nothing happens on choosing it" % ask)
		t.eq(str(m.page), "leave" if ask == "leave_ask" else "quit", "%s: the confirm shows" % ask)
		t.eq(str(m.rows()[m.sel]["label"]), "STAY", "%s: STAY is chosen first" % ask)
		m.key(_key(KEY_ENTER))
		t.check(got.is_empty() and m.page == "top", "%s: Enter on STAY goes back, nothing done" % ask)
		m.sel = _ids(m).find(ask)
		m.activate()
		m.key(_key(KEY_ESCAPE))
		t.check(got.is_empty() and m.page == "top", "%s: Esc on the confirm goes back, nothing done" % ask)
		m.sel = _ids(m).find(ask)
		m.activate()
		m.key(_key(KEY_RIGHT))
		m.key(_key(KEY_ENTER))
		t.eq(got, ["leave" if ask == "leave_ask" else "quit"], "%s: only the confirm does it" % ask)
		m.free()
	var m2 := _menu(true, false)
	m2.page = "leave"
	t.eq(m2._heading(), "LEAVE THIS RUN? YOUR CREW CARRIES ON WITHOUT YOU.", "the leave question")
	m2.page = "quit"
	t.eq(m2._heading(), "QUIT TO DESKTOP? THIS RUN ENDS FOR YOU.", "the quit question")
	m2.free()

func test_every_page_fits_at_every_size(t: T) -> void:
	var cases := [[true, true, "top"], [false, false, "top"], [true, false, "settings"], [false, false, "settings"], [true, false, "leave"], [true, false, "quit"], [false, false, "quit"]]
	for c: Array in cases:
		var m := _menu(c[0], c[1])
		m.page = c[2]
		for s: Vector2 in SIZES:
			var tag := "%s %s %dx%d" % [c[2], "run" if c[0] else "start", int(s.x), int(s.y)]
			var lay: Dictionary = m.layout(s)
			var card: Rect2 = lay["rect"]
			var sc: float = lay["sc"]
			var mg := EscMenu.MARGIN
			t.check(Rect2(Vector2(mg, mg), s - Vector2(mg, mg) * 2.0).encloses(card), "%s: the card is inside the window (%s)" % [tag, str(card)])
			var rects: Array = lay["rows"]
			var r: Array = m.rows()
			var heading_bottom: float = (lay["note"] as Vector2).y + 7 * sc if m._note() != "" else (lay["title"] as Vector2).y + 7 * sc
			for i in rects.size():
				var box: Rect2 = rects[i]
				t.check(card.encloses(box), "%s: row %d inside the card" % [tag, i])
				t.check(box.position.y >= heading_bottom, "%s: row %d below the heading" % [tag, i])
				t.check(box.end.y <= (lay["foot"] as Vector2).y, "%s: row %d above the foot" % [tag, i])
				t.check(PixelFont.width(str(r[i]["label"])) * sc <= box.size.x, "%s: row %d's label fits" % [tag, i])
				if i > 0:
					t.check(not (rects[i - 1] as Rect2).intersects(box), "%s: rows %d and %d do not overlap" % [tag, i - 1, i])
			t.check((lay["foot"] as Vector2).y + 7 * sc <= card.end.y, "%s: the foot is inside the card" % tag)
			t.check(PixelFont.width(m._heading()) * sc + 16 <= card.size.x, "%s: the heading fits across" % tag)
			if s == Vector2(1280, 720):
				t.check(sc >= 3.0, "%s: large at 1280x720 (scale %d)" % [tag, int(sc)])
		m.free()

func test_old_keys_and_the_mouse(t: T) -> void:
	for page: String in ["top", "settings"]:
		var m := _menu(true, true)
		m.page = page
		for code: Key in [KEY_H, KEY_B, KEY_V, KEY_M, KEY_N, KEY_T, KEY_F6, KEY_F8]:
			t.check(not m.key(_key(code)), "%s: %s is left for the game" % [page, OS.get_keycode_string(code)])
		m.free()
	var m := _menu(true, false)
	var got: Array = []
	m.chose.connect(func(id: String) -> void: got.append(id))
	var lay: Dictionary = m.layout(m.size)
	var settings_box: Rect2 = lay["rows"][1]
	var mv := InputEventMouseMotion.new()
	mv.position = settings_box.get_center()
	m.mouse(mv)
	t.eq(int(m.sel), 1, "hovering SETTINGS chooses it")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = settings_box.get_center()
	m.mouse(click)
	t.eq(str(m.page), "settings", "a click opens it")
	click.position = Vector2(2, 2)
	m.mouse(click)
	t.eq(str(m.page), "settings", "a click outside the rows does nothing")
	m.free()
	var main_src := FileAccess.get_file_as_string("res://client/main.gd")
	t.check(main_src.contains("if _esc_menu_input(event):\n\t\treturn\n\tif mode != \"game\":"), "the menu takes its keys before the start screen and the game")
	t.check(main_src.contains("not bright_card.is_open() and not _esc_menu_shown():\n\t\tf = Input.get_action_strength"), "W and S walk the menu, not the player")

func test_the_hud_behind_the_menu(t: T) -> void:
	var src := FileAccess.get_file_as_string("res://client/hud.gd")
	t.check(src.contains("if prompt != \"\" and not black and not menu_on:"), "world prompts hide while the menu shows")
	t.check(src.contains("if menu_on and not black and menu_page == \"controls\":"), "the key list is drawn only on CONTROLS")
	var hud: Hud = Hud.new()
	t.eq(hud.menu_page, "controls", "the HUD alone still draws its card (test_esc_card's)")
	hud.free()
