# ES1b (first step): the Esc card in a run says the run does not pause (players expect a pause menu to pause; in a
# co-op game it cannot, and the card says so), and the card still fits every window from 1024x600 to 3840x2160 with
# every row it had (the settings keys H, B, V, M and the host's F6 and F8 included).
#   1. in a run the card carries THE RUN DOES NOT PAUSE under its title; on the start screen (no run) it does not;
#   2. every old row is still on it, and the V row names the announcer's voice (ES1a);
#   3. at every size the card is inside the window, its note, rows and foot inside the card, with the host's rows;
#   4. ES1c: the card is drawn at the largest whole scale that fits (in two columns when that reads larger: at
#      1280x720 one column only fitted at scale 1); 1280x720 is at least scale 2;
#   5. ES1c: the YOUR SOUND page (sliders, CAUGHT SCENES, ANNOUNCER VOICE, the microphone) stays inside its card above
#      the foot at every size, scrolling with the chosen row: the chosen row always shows, every row shows for some
#      choice, and no shown row, title, MORE marker or foot leaves the card or overlaps another.
extends RefCounted

const T = preload("res://tests/t.gd")
const HudScript = preload("res://client/hud.gd")
const SettingsPanelScript = preload("res://client/settings_panel.gd")
const VoicePref = preload("res://client/voice_pref.gd")
const CaughtPref = preload("res://client/caught_pref.gd")
const Volume = preload("res://client/volume.gd")

const SIZES: Array[Vector2] = [Vector2(1024, 600), Vector2(1280, 720), Vector2(1366, 768), Vector2(1920, 1080), Vector2(2560, 1440), Vector2(3840, 2160), Vector2(1280, 1024), Vector2(1600, 900)]

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
				var mg: float = HudScript.MENU_MARGIN
				t.check(Rect2(Vector2(mg, mg), s - Vector2(mg, mg) * 2.0).encloses(r), "%s: the card is inside the window with the margin (%s)" % [tag, str(r)])
				# Every row once, each column's widest line and the foot's line, in the card's own pixels.
				var n := 0
				var cols: Array = c["cols"]
				for i in cols.size():
					var col: Dictionary = cols[i]
					n += (col["rows"] as Array).size()
					var widest := 0
					for row: Array in col["rows"]:
						widest = maxi(widest, int(col["x"]) + int(col["key_w"]) + 10 + PixelFont.width(str(row[1])))
					var next_x: int = int(cols[i + 1]["x"]) if i + 1 < cols.size() else int(c["w"])
					t.check(widest <= next_x - (0 if i + 1 == cols.size() else 6), "%s: column %d fits before the next" % [tag, i + 1])
				t.eq(n, (hud.menu_rows() as Array).size(), "%s: every row once" % tag)
				t.check(PixelFont.width(note) + 8 <= int(c["w"]), "%s: the note fits across" % tag)
				var foot_y := 6 + (int(c["per"]) + 3 + int(c["note_rows"])) * 12
				t.check(foot_y + 9 <= int(c["h"]), "%s: the foot is inside the card" % tag)
				t.check(sc >= 1.0 and sc == floorf(sc), "%s: whole-pixel scale %.1f" % [tag, sc])
				# ES1c: the largest scale that fits: one more, in one column or two, would not fit.
				var bigger := false
				for k: int in [1, 2]:
					var d: Dictionary = hud.menu_card_dims(k)
					var big := Vector2(int(d["w"]), int(d["h"])) * (sc + 1.0)
					if big.x <= s.x - 2.0 * mg and big.y <= s.y - 2.0 * mg:
						bigger = true
				t.check(not bigger, "%s: scale %d is the largest that fits" % [tag, int(sc)])
				if s == Vector2(1280, 720):
					t.check(sc >= 2.0, "%s: readable at 1280x720 (scale %d, %d column(s))" % [tag, int(sc), cols.size()])
			hud.free()

## A sound page with every row it can have: the sliders, CAUGHT SCENES, ANNOUNCER VOICE and the microphone (the layout
## only asks whether a microphone is there).
static func _sound_panel() -> Control:
	var p: Control = SettingsPanelScript.new()
	var vol := Volume.new()
	vol.persist = false
	p.volume = vol
	var cp := CaughtPref.new()
	cp.persist = false
	p.caught_pref = cp
	var vp := VoicePref.new()
	vp.persist = false
	p.voice_pref = vp
	p.mic = Node.new()
	p.open()
	p.show_sound(true)
	return p

func test_the_sound_page_fits_its_card_at_every_size(t: T) -> void:
	var p := _sound_panel()
	var n: int = p._sound_rows_n()
	t.eq(n, 3 + 1 + 1 + 3, "eight rows: three sliders, caught scenes, the voice, three microphone rows")
	# The longest words each block prints, in font pixels from the block's left (the widest at once).
	var widest := {"slider": 0, "caught": 6 + PixelFont.width("SOFT: NO SNAP, HALF THE FLASH AND NOISE"),
		"voice": 0, "mic": 6 + 12 * 6 + PixelFont.width("HEADPHONES") + 4 + 6 + PixelFont.width("SPEAKERS") + 4,
		"mic_test": maxi(PixelFont.width("TEST: NO MICROPHONE SIGNAL   TALKING"), PixelFont.width("ONLY HOW LOUD YOU ARE IS SENT. M: ON / OFF.")),
		"note": PixelFont.width("NOT SENT. HOST SETTINGS: ON THE LEFT.")}
	for s: Vector2 in SIZES:
		var ever := {}
		for sel in n:
			p._sound_row = sel
			var lay: Dictionary = p.sound_layout(s)
			var px: float = lay["px"]
			var card: Rect2 = lay["card"]
			var foot: Rect2 = lay["foot"]
			var foot_line_y := card.end.y - 16.0 * px
			var tag := "%dx%d row %d" % [int(s.x), int(s.y), sel]
			t.check(card.grow(0.5).encloses(foot), "%s: the foot is inside the card (%s in %s)" % [tag, str(foot), str(card)])
			var title_at: Vector2 = lay["title_at"]
			var title_end := title_at.x + PixelFont.width("YOUR SOUND: ON THIS COMPUTER ONLY") * px
			var more := SettingsPanelScript.more_words(lay)
			if more != "":
				var more_x: float = float(lay["right"]) - PixelFont.width(more) * px - 2.0 * px
				t.check(more_x - 2.0 * px > title_end, "%s: MORE does not touch the page's title" % tag)
			var chosen_shown := false
			var last_bottom := -INF
			for b: Dictionary in lay["blocks"]:
				if not bool(b["shown"]):
					continue
				var r: Rect2 = b["rect"]
				ever[str(b["kind"]) + str(b["row"])] = true
				if int(b["row"]) == sel:
					chosen_shown = true
				t.check(r.position.y > title_at.y + 9.0 * px, "%s: %s is under the page's title" % [tag, b["kind"]])
				t.check(r.end.y <= foot_line_y, "%s: %s ends above the foot's line (%.0f > %.0f)" % [tag, b["kind"], r.end.y, foot_line_y])
				t.check(r.position.y >= last_bottom, "%s: %s does not overlap the block above" % [tag, b["kind"]])
				last_bottom = r.end.y
				var need := float(widest[str(b["kind"])]) * px
				t.check(r.position.x + need <= card.end.x - 4.0 * px and r.end.x <= card.end.x, "%s: %s fits across the card" % [tag, b["kind"]])
			t.check(chosen_shown, "%s: the chosen row shows" % tag)
		for b: Dictionary in p.sound_layout(s)["blocks"]:
			if int(b["row"]) >= 0:
				var key := str(b["kind"]) + str(b["row"])
				t.check(ever.has(key), "%dx%d: %s is reachable" % [int(s.x), int(s.y), key])
	# The test bar shows beside the microphone rows at the smallest size, and MORE says when rows are hidden.
	p._sound_row = p.mic_row_index() + 2
	var small: Dictionary = p.sound_layout(Vector2(1024, 600))
	var test_shown := false
	for b: Dictionary in small["blocks"]:
		if str(b["kind"]) == "mic_test":
			test_shown = bool(b["shown"])
	t.check(test_shown, "1024x600, MIC SENSITIVITY chosen: the test bar and C: CALIBRATE AGAIN show")
	p._sound_row = 0
	var top: Dictionary = p.sound_layout(Vector2(1280, 720))
	t.eq(SettingsPanelScript.more_words(top), "MORE BELOW", "1280x720, the first slider chosen: the rest is below, and it says so")
	var target: int = SettingsPanelScript.more_target(top)
	t.check(target > 0, "a click on MORE BELOW chooses a hidden row (%d)" % target)
	var spx := SettingsPanelScript.px_at(Vector2(1024, 600))
	t.check(PixelFont.width(p.foot_line()) * spx <= SettingsPanelScript.card_rect(Vector2(1024, 600)).size.x - 16.0 * spx, "1024x600: the sound page's foot fits across")
	p.mic.free()
	p.free()
