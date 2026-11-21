# The start screen at every window size (MH1a, the owner after the 21 Nov playtest: the tag line went under
# PLAY ALONE in fullscreen, and Esc's controls came up behind the menu). client/start_screen.gd, headless:
#   - at 1024x600, 1280x720, 1920x1080, 1920x1200, 2560x1440 and 3840x2160 (and an ultrawide), with and
#     without HOST PLAYTEST and with no, one or two rows of error, no two pieces of the title screen (the
#     title, the tag line, the buttons, the error, the ESC line) overlap and every one is inside the window;
#   - the pieces keep the same places relative to each other at every size (counted in steps of the scale);
#   - with the Esc card open on the start screen, the HUD that draws it is lifted over the start screen,
#     the start screen draws only its dim and takes no clicks, and both go back when the card closes.
extends RefCounted

const T = preload("res://tests/t.gd")
const StartScreenScript = preload("res://client/start_screen.gd")
const HudScript = preload("res://client/hud.gd")

const SIZES: Array[Vector2] = [
	Vector2(1024, 600), Vector2(1280, 720), Vector2(1920, 1080), Vector2(1920, 1200), Vector2(2560, 1440),
	Vector2(3840, 2160), Vector2(2560, 1080), Vector2(1366, 768), Vector2(1600, 900),
]

func test_nothing_overlaps_at_any_size(t: T) -> void:
	for sz in SIZES:
		var px := StartScreenScript.scale_for(sz)
		for playtest: bool in [false, true]:
			for errs in 3:
				var pieces := StartScreenScript.title_layout(sz, px, playtest, errs)
				var window := Rect2(Vector2.ZERO, sz)
				var bad := ""
				for i in pieces.size():
					var a: Rect2 = pieces[i]["rect"]
					if not window.encloses(a):
						bad += " %s outside the window %s;" % [pieces[i]["id"], a]
					for j in range(i + 1, pieces.size()):
						var b: Rect2 = pieces[j]["rect"]
						if a.intersects(b):
							bad += " %s %s overlaps %s %s;" % [pieces[i]["id"], a, pieces[j]["id"], b]
				t.check(bad == "", "%dx%d, playtest %s, %d error rows: nothing overlaps%s" % [sz.x, sz.y, playtest, errs, bad])
				var alone: Rect2 = pieces.filter(func(p: Dictionary) -> bool: return p["id"] == "alone")[0]["rect"]
				t.check(alone.has_point(sz * 0.5), "%dx%d: PLAY ALONE covers the middle of the window (the scripted playthroughs click there)" % [sz.x, sz.y])

func test_the_same_layout_at_every_size(t: T) -> void:
	# Each piece's place, in steps of the scale from the middle of the window, is the same at every size.
	var want: Array = []
	for sz in SIZES:
		var px := StartScreenScript.scale_for(sz)
		var got: Array = []
		for p: Dictionary in StartScreenScript.title_layout(sz, px, true, 1):
			var r: Rect2 = p["rect"]
			got.append([p["id"], (r.position.y - floorf(sz.y * 0.5)) / px, r.size.y / px])
		if want.is_empty():
			want = got
		# A button's edge is floored to a whole window pixel: under one step of difference is the same place.
		var same := got.size() == want.size()
		for i in mini(got.size(), want.size()):
			same = same and got[i][0] == want[i][0] and absf(got[i][1] - want[i][1]) < 1.0 and absf(got[i][2] - want[i][2]) < 0.01
		t.check(same, "%dx%d lays out as 1024x600 does: %s vs %s" % [sz.x, sz.y, got, want])

func test_the_title_screen_draws_the_layout(t: T) -> void:
	# The tag line and the buttons the screen draws are the layout's (no second set of places in _draw).
	var src := FileAccess.get_file_as_string("res://client/start_screen.gd")
	t.check(src.contains("in title_layout(size, px, playtest_available"), "the title screen draws from title_layout")
	t.check(not src.contains("size.y - 16 * px"), "no piece is placed from the window's bottom edge")
	t.check(not src.contains("size.y * 0.14"), "nor as a share of the window's height")

func test_the_controls_card_comes_in_front_of_the_menu(t: T) -> void:
	# main.gd's order: the HUD is added before the start screen, so by tree order it draws under it.
	var root := Control.new()
	var hud: Control = HudScript.new()
	var ss: StartScreen = StartScreenScript.new()
	ss.persist_tape = false
	root.add_child(hud)
	root.add_child(ss)
	t.check(not _draws_over(hud, ss), "by tree order the HUD (and its Esc card) is under the start screen")
	StartScreenScript.menu_in_front(hud, ss, true, true)
	t.check(_draws_over(hud, ss), "Esc on the start screen: the card's HUD draws in front of the menu")
	t.check(ss.under_menu, "and the start screen draws only its dim (nothing of the menu through the card) and takes no clicks")
	StartScreenScript.menu_in_front(hud, ss, false, true)
	t.check(not _draws_over(hud, ss) and not ss.under_menu and hud.z_index == 0, "Esc again: the card goes and the menu is back as it was")
	StartScreenScript.menu_in_front(hud, ss, true, false)
	t.check(hud.z_index == 0 and not ss.under_menu, "in the run nothing is lifted (the start screen is hidden there)")
	var main_src := FileAccess.get_file_as_string("res://client/main.gd")
	t.check(main_src.contains("StartScreen.menu_in_front(hud, start, menu_overlay, mode != \"game\")"), "main.gd lifts the card every frame")
	root.free()

## Whether `a` is drawn after (over) `b`: the higher z first, then the later sibling.
func _draws_over(a: CanvasItem, b: CanvasItem) -> bool:
	if a.z_index != b.z_index:
		return a.z_index > b.z_index
	return a.get_index() > b.get_index()
