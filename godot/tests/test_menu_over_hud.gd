extends RefCounted
## LK1: the Esc menu is never ghosted by what is behind or over it (pictures 1a, 1b and 5e of the unseen review):
##   1. it has its own canvas layer above the HUD, the noise meter's layer and the host's settings panel's;
##   2. its card is opaque, so the Tenant clock and PLAY do not show through the card's top;
##   3. HOST TOOLS (or F8) replaces the menu with the panel; the menu comes back when the panel closes;
##   4. a confirm (LEAVE, QUIT, END RUN) is the top-most thing: F8 does not open the panel over it.

const T = preload("res://tests/t.gd")
const EscMenu = preload("res://client/esc_menu.gd")

static func _layer_in_main(src: String, name: String) -> int:
	# The literal layer main.gd gives a CanvasLayer held in `name`.
	var at := src.find("%s.layer = " % name)
	if at < 0:
		return -9999
	var tail := src.substr(at + name.length() + 9, 8)
	return int(tail.split("\n")[0])

func test_the_menu_is_above_the_hud_and_the_panel(t: T) -> void:
	var src := FileAccess.get_file_as_string("res://client/main.gd")
	t.check(src.contains("menu_layer.layer = EscMenuScript.LAYER") and src.contains("menu_layer.add_child(esc_menu)"),
		"the menu is drawn on its own layer, not inside the HUD")
	t.check(not src.contains("hud.add_child(esc_menu)"), "the menu is no longer a child of the HUD")
	var panel := _layer_in_main(src, "panel_layer")
	var mic := _layer_in_main(src, "mic_layer")
	t.check(panel > 0 and mic > 0, "found the settings panel's (%d) and the noise meter's (%d) layers" % [panel, mic])
	t.check(EscMenu.LAYER > panel and EscMenu.LAYER > mic, "the menu's layer %d is above the panel's %d and the meter's %d" % [EscMenu.LAYER, panel, mic])

func test_the_card_is_opaque(t: T) -> void:
	t.eq(EscMenu.CARD.a, 1.0, "the card hides what is behind it")
	t.check(EscMenu.DIM.a >= 0.6 and EscMenu.DIM.a < 1.0, "the game is dimmed behind the menu, still seen (%.2f)" % EscMenu.DIM.a)
	var src := FileAccess.get_file_as_string("res://client/esc_menu.gd")
	t.check(src.contains("draw_rect(card, CARD)"), "the card is drawn in CARD")

func test_host_tools_replace_the_menu(t: T) -> void:
	t.check(EscMenu.drawn_over(true, false, false), "the menu shows when wanted")
	t.check(not EscMenu.drawn_over(true, true, false), "the host's panel open: the menu is not drawn under it")
	t.check(not EscMenu.drawn_over(true, false, true), "the brightness card open: the menu is not drawn under it")
	t.check(not EscMenu.drawn_over(false, false, false), "not wanted, not drawn")
	var src := FileAccess.get_file_as_string("res://client/main.gd")
	t.check(src.contains("esc_menu.shown = EscMenuScript.drawn_over("), "the game decides the menu's showing with that rule")
	t.check(src.contains("hud.menu_page = esc_menu.page if esc_menu.shown else (\"\" if settings_panel.is_open() or bright_card.is_open() else \"controls\")"),
		"the HUD's key list is not drawn under the panel either")

func test_a_confirm_is_on_top(t: T) -> void:
	for page: String in ["leave", "quit", "end"]:
		var m: Control = EscMenu.new()
		m.in_run = true
		m.is_host = true
		m.playtest = true
		m.shown = true
		m.open_menu()
		m.page = page
		var k := InputEventKey.new()
		k.physical_keycode = KEY_F8
		k.pressed = true
		t.check(m.key(k), "%s: the confirm keeps F8" % page)
		t.eq(str(m.page), page, "%s: still asking" % page)
		m.free()
	var src := FileAccess.get_file_as_string("res://client/main.gd")
	t.check(src.contains("KEY_F8 and not kiosk.is_open() and not (_esc_menu_shown() and esc_menu.page in EscMenuScript.CONFIRMS)"),
		"F8 does not open the panel over a confirm")
