# ES1b (first step): the Esc card in a run says the run does not pause (players expect a pause menu to pause; in a
# co-op game it cannot, and the card says so), and the card still fits every window from 1024x600 to 3840x2160 with
# every row it had (the settings keys H, B, V, M and the host's F6 and F8 included).
#   1. in a run the card carries THE RUN DOES NOT PAUSE under its title; on the start screen (no run) it does not;
#   2. every old row is still on it, and the V row names the announcer's voice (ES1a);
#   3. at every size the card is inside the window, its note, rows and foot inside the card, with the host's rows.
extends RefCounted

const T = preload("res://tests/t.gd")
const HudScript = preload("res://client/hud.gd")

const SIZES: Array[Vector2] = [Vector2(1024, 600), Vector2(1280, 720), Vector2(1366, 768), Vector2(1920, 1080), Vector2(2560, 1440), Vector2(3840, 2160), Vector2(1280, 1024), Vector2(800, 600)]

func test_the_card_says_the_run_does_not_pause(t: T) -> void:
	var hud: Variant = HudScript.new()
	t.eq(hud.menu_note, "THE RUN DOES NOT PAUSE", "in a run (the default) the card says the run goes on")
	var main_src := FileAccess.get_file_as_string("res://client/main.gd")
	t.check(main_src.contains("hud.menu_note = hud.RUN_NOTE if mode == \"game\" else \"\""), "main.gd shows it only in a run, every frame")
	var with_note: Dictionary = hud.menu_card(Vector2(1280, 720))
	hud.menu_note = ""
	var without: Dictionary = hud.menu_card(Vector2(1280, 720))
	t.eq(int(with_note["h"]) - int(without["h"]), 12, "the note takes one line of its own")
	hud.free()

func test_every_old_row_is_still_there(t: T) -> void:
	var hud: Variant = HudScript.new()
	hud.f6_row = true
	hud.f8_row = "host"
	var keys: Array = (hud.menu_rows() as Array).map(func(r: Array) -> String: return str(r[0]))
	for k: String in ["W A S D", "SHIFT", "CTRL OR C", "MOUSE", "E", "F", "G", "T", "HOLD R", "HOLD TAB", "ESC", "F6", "F8", "H", "B", "V", "M"]:
		t.check(keys.has(k), "%s is on the card" % k)
	var v: Array = (hud.menu_rows() as Array).filter(func(r: Array) -> bool: return str(r[0]) == "V")
	t.eq(str(v[0][1]) if not v.is_empty() else "", "SOUND AND ANNOUNCER VOICE", "V names the announcer's voice")
	hud.free()

func test_the_card_fits_at_every_size(t: T) -> void:
	for note: String in ["THE RUN DOES NOT PAUSE", ""]:
		for host: bool in [true, false]:
			var hud: Variant = HudScript.new()
			hud.menu_note = note
			hud.f6_row = host
			hud.f8_row = "host" if host else "guest"
			hud.menu_foot = "CLICK TO PLAY" if note != "" else "ESC TO GO BACK"
			for s: Vector2 in SIZES:
				var c: Dictionary = hud.menu_card(s)
				var r: Rect2 = c["rect"]
				var sc: float = c["sc"]
				var tag := "%dx%d%s%s" % [int(s.x), int(s.y), " run" if note != "" else " start", " host" if host else ""]
				t.check(Rect2(Vector2.ZERO, s).encloses(r), "%s: the card is inside the window (%s)" % [tag, str(r)])
				# The widest line and the foot's line, in the card's own pixels.
				var widest := 0
				for row: Array in c["rows"]:
					widest = maxi(widest, 8 + int(c["key_w"]) + 10 + PixelFont.width(str(row[1])))
				t.check(widest <= int(c["w"]) and PixelFont.width(note) + 8 <= int(c["w"]), "%s: every row and the note fit across" % tag)
				var foot_y := 6 + ((c["rows"] as Array).size() + 3 + int(c["note_rows"])) * 12
				t.check(foot_y + 9 <= int(c["h"]), "%s: the foot is inside the card" % tag)
				t.check(sc >= 1.0 and sc == floorf(sc), "%s: whole-pixel scale %.1f" % [tag, sc])
			hud.free()
