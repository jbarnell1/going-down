# HU2 (the screen, stage 2, and the pause menu's settings as tabs; .local/reviews/hud-plan.md stage 2, the owner's
# answers of 21 Nov; .local/reviews/esc-menu-design.md):
#   1. the settings page has five tabs, GAME, SOUND, MICROPHONE, PICTURE, CONTROLS; every setting that was on the old
#      settings page or behind its pages (the three sound levels, the voice, the microphone's three rows and its
#      calibration, the brightness and its card, the hints, the caught scenes, the tape look, the key list) is a row;
#   2. each row changes its own setting's value, by the keys (left and right) and by the mouse (< and >), and the
#      row then says the new value; Enter on a toggle flips it;
#   3. Q and E, left and right on the tab bar, and a click on a tab change the tab; Esc goes back to the top;
#   4. at every window size of test_esc_card the card is the same size on every tab, the tabs sit inside it without
#      overlapping, each value fits between its arrows, and CONTROLS scrolls; the card is opaque;
#   5. the Tenant's STAIRS lamp row over the lift's doors lights from the host's clock alone: one lamp at the doors,
#      one more each tenth, the last minute red, all red once the Tenant is here, nothing without a clock; it is in
#      the world (on the lift), above the car's indicator and under the ceiling;
#   6. nothing new is on the glass while walking: at rest only PLAY, the menu not drawn; on Tab the Tenant line and
#      the rates, the same rates as the lift's sheets.
extends RefCounted

const T = preload("res://tests/t.gd")
const EscMenu = preload("res://client/esc_menu.gd")
const SettingsTabs = preload("res://client/settings_tabs.gd")
const Volume = preload("res://client/volume.gd")
const Brightness = preload("res://client/brightness.gd")
const CaughtPref = preload("res://client/caught_pref.gd")
const VoicePref = preload("res://client/voice_pref.gd")
const MicMeter = preload("res://client/mic_meter.gd")
const StairsLamps = preload("res://client/stairs_lamps.gd")
const TenantClock = preload("res://client/tenant_clock.gd")
const HudScript = preload("res://client/hud.gd")
const LiftScript = preload("res://client/lift.gd")
const Run = preload("res://sim/run.gd")
const Clinic = preload("res://sim/clinic.gd")
const PlanDump = preload("res://client/plan_dump.gd")

const SIZES: Array[Vector2] = [Vector2(1024, 600), Vector2(1280, 720), Vector2(1366, 768), Vector2(1920, 1080), Vector2(2560, 1440), Vector2(3840, 2160), Vector2(1280, 1024), Vector2(1600, 900)]

## A stand-in for client/mic.gd: the real meter (never saved), on and off as the real one's set_enabled.
class FakeMic extends RefCounted:
	var meter: Object
	var calib := 0
	func _init() -> void:
		meter = MicMeter.new()
		meter.set(&"persist", false)
	func set_enabled(on: bool) -> void:
		meter.set(&"asked", true)
		meter.set(&"enabled", on)
	func listening() -> bool:
		return bool(meter.get(&"enabled"))
	func level() -> int:
		return 4
	func open_calibration() -> void:
		calib += 1

## Gives `tabs` real owners that never save, and the game's calls on a plain dictionary. Used by tests/test_esc_menu.gd.
static func wire(tabs: Object) -> Dictionary:
	var game := {"hints": true, "tape": true, "bright": -1}
	var v := Volume.new()
	v.persist = false
	var c := CaughtPref.new()
	c.persist = false
	var vp := VoicePref.new({"voices": [{"id": "brian", "name": "Brian"}, {"id": "anne", "name": "Anne"}]})
	vp.persist = false
	var b := Brightness.new()
	b.persist = false
	tabs.set(&"volume", v)
	tabs.set(&"caught_pref", c)
	tabs.set(&"voice_pref", vp)
	tabs.set(&"mic", FakeMic.new())
	tabs.set(&"brightness", b)
	tabs.set(&"hints_get", func() -> bool: return bool(game["hints"]))
	tabs.set(&"hints_set", func(on: bool) -> void: game["hints"] = on)
	tabs.set(&"tape_get", func() -> bool: return bool(game["tape"]))
	tabs.set(&"tape_set", func(on: bool) -> void: game["tape"] = on)
	tabs.set(&"bright_apply", func(lv: int) -> void: game["bright"] = lv)
	var hud: Hud = HudScript.new()
	tabs.set(&"key_rows", hud.menu_rows())
	hud.free()
	return game

static func _menu() -> Control:
	var m: Control = EscMenu.new()
	m.in_run = true
	m.shown = true
	m.size = Vector2(1280, 720)
	m.open_menu()
	m.sel = 1
	m.activate()   # SETTINGS
	return m

static func _key(code: Key, shift := false) -> InputEventKey:
	var k := InputEventKey.new()
	k.physical_keycode = code
	k.pressed = true
	k.shift_pressed = shift
	return k

static func _ids(m: Control) -> Array:
	return m.describe()["rows"]

static func _value(m: Control, id: String) -> String:
	for r: Dictionary in m.rows():
		if str(r["id"]) == id:
			return str(r["value"])
	return "?"

## Shows the tab holding row `id` and chooses it.
static func _choose(m: Control, id: String) -> bool:
	for i in SettingsTabs.TABS.size():
		m.set_tab(i)
		var at := _ids(m).find(id)
		if at >= 0:
			m.sel = at
			return true
	return false

func test_every_setting_is_on_a_tab(t: T) -> void:
	var m := _menu()
	wire(m.tabs)
	t.eq(str(m.page), "settings", "SETTINGS opens the tabs")
	t.eq(m.tab_id(), "game", "on the first tab, GAME")
	t.eq(int(m.sel), 0, "its first row chosen")
	var want := {"game": ["hints", "caught", "back"], "sound": ["master", "music", "effects", "voice", "back"],
		"mic": ["mic_on", "mic_out", "mic_sens", "mic_calib", "back"], "picture": ["brightness", "bright_card", "tape", "back"]}
	for i in SettingsTabs.TABS.size():
		m.set_tab(i)
		var id: String = m.tab_id()
		if want.has(id):
			t.eq(_ids(m), want[id], "the %s tab's rows" % id)
		else:
			var hud: Hud = HudScript.new()
			t.eq(_ids(m).size(), hud.menu_rows().size() + 1, "CONTROLS: every key of the key card, then BACK")
			hud.free()
	t.eq(SettingsTabs.TAB_NAMES.values(), ["GAME", "SOUND", "MICROPHONE", "PICTURE", "CONTROLS"], "the tab names")
	# A setting whose owner the game has not got (no microphone on this machine) has no row; BACK stays.
	m.tabs.mic = null
	m.set_tab(SettingsTabs.TABS.find("mic"))
	t.eq(_ids(m), ["back"], "no microphone: only BACK")
	m.free()

func test_each_row_changes_its_value(t: T) -> void:
	var m := _menu()
	var game := wire(m.tabs)
	var tabs: Object = m.tabs
	# Keys: right and left on each row, and the row says the new value.
	var cases := [
		["master", func() -> Variant: return tabs.volume.get_pct("master"), KEY_LEFT],
		["music", func() -> Variant: return tabs.volume.get_pct("music"), KEY_LEFT],
		["effects", func() -> Variant: return tabs.volume.get_pct("effects"), KEY_LEFT],
		["voice", func() -> Variant: return tabs.voice_pref.voice, KEY_RIGHT],
		["hints", func() -> Variant: return game["hints"], KEY_LEFT],
		["caught", func() -> Variant: return tabs.caught_pref.soft, KEY_RIGHT],
		["mic_on", func() -> Variant: return tabs.mic.meter.enabled, KEY_RIGHT],
		["mic_out", func() -> Variant: return tabs.mic.meter.speakers, KEY_RIGHT],
		["mic_sens", func() -> Variant: return tabs.mic.meter.sensitivity, KEY_RIGHT],
		["brightness", func() -> Variant: return tabs.brightness.level, KEY_RIGHT],
		["tape", func() -> Variant: return game["tape"], KEY_LEFT],
	]
	for c: Array in cases:
		var id: String = c[0]
		var get_it: Callable = c[1]
		t.check(_choose(m, id), "%s is on a tab" % id)
		var was: Variant = get_it.call()
		var shown_was := _value(m, id)
		t.check(m.key(_key(c[2])), "%s: the menu takes the arrow" % id)
		t.check(get_it.call() != was, "%s: the arrow changes the setting (%s to %s)" % [id, str(was), str(get_it.call())])
		t.check(_value(m, id) != shown_was, "%s: the row says the new value (%s to %s)" % [id, shown_was, _value(m, id)])
	t.eq(int(game["bright"]), tabs.brightness.level, "the brightness reaches the picture through the game's own call")
	t.eq(tabs.volume.get_pct("master"), 95, "one step of a sound level is the sound page's 5 %")
	_choose(m, "master")
	m.key(_key(KEY_LEFT, true))
	t.eq(tabs.volume.get_pct("master"), 70, "Shift: five steps")
	# Enter flips a toggle.
	_choose(m, "hints")
	var h: bool = game["hints"]
	m.key(_key(KEY_ENTER))
	t.eq(game["hints"], not h, "Enter on HINTS flips it")
	# The mouse: a click on > steps up, on < steps down, the row under the pointer chosen first.
	_choose(m, "effects")
	var lay: Dictionary = m.layout(m.size)
	var row_i: int = _ids(m).find("effects") - int(lay["first"])
	var pair: Array = lay["arrows"][row_i]
	var e0: int = tabs.volume.get_pct("effects")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = (pair[0] as Rect2).get_center()
	m.sel = 0
	m.mouse(click)
	t.eq(tabs.volume.get_pct("effects"), e0 - Volume.STEP, "a click on < lowers EFFECTS a step")
	click.position = (pair[1] as Rect2).get_center()
	m.mouse(click)
	m.mouse(click)
	t.eq(tabs.volume.get_pct("effects"), e0 + Volume.STEP, "two clicks on > raise it two")
	# Actions are the game's: the brightness card and the calibration.
	var got: Array = []
	m.chose.connect(func(id: String) -> void: got.append(id))
	_choose(m, "bright_card")
	m.key(_key(KEY_ENTER))
	_choose(m, "mic_calib")
	m.key(_key(KEY_ENTER))
	t.eq(got, ["bright_card", "mic_calib"], "TEST PICTURE and CALIBRATE ask the game")
	m.free()

func test_tabs_change_by_key_and_mouse(t: T) -> void:
	var m := _menu()
	wire(m.tabs)
	m.key(_key(KEY_E))
	t.eq(m.tab_id(), "sound", "E: the next tab")
	m.key(_key(KEY_Q))
	m.key(_key(KEY_Q))
	t.eq(m.tab_id(), "controls", "Q: the one before, wrapping")
	m.set_tab(0)
	m.key(_key(KEY_UP))
	t.eq(int(m.sel), -1, "Up from the first row: the tab bar")
	m.key(_key(KEY_RIGHT))
	t.eq(m.tab_id(), "sound", "right on the tab bar: the next tab")
	t.eq(tabs_value(m, "master"), "100", "and nothing changed on it")
	m.key(_key(KEY_DOWN))
	t.eq(int(m.sel), 0, "Down: its first row")
	var lay: Dictionary = m.layout(m.size)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = (lay["tabs"][3] as Rect2).get_center()
	m.mouse(click)
	t.eq(m.tab_id(), "picture", "a click on PICTURE shows it")
	# CONTROLS scrolls to keep the chosen row in view; BACK is last.
	m.set_tab(4)
	m.sel = 0
	var n := _ids(m).size()
	for i in n - 1:
		m.key(_key(KEY_DOWN))
	t.eq(str(_ids(m)[m.sel]), "back", "the last row of CONTROLS is BACK")
	lay = m.layout(m.size)
	var first: int = lay["first"]
	t.check(m.sel >= first and m.sel < first + (lay["rows"] as Array).size(), "the chosen row is in view (first %d, chosen %d)" % [first, m.sel])
	m.key(_key(KEY_ENTER))
	t.eq(str(m.page), "top", "BACK: the top of the menu")
	m.sel = 1
	m.activate()
	t.eq([str(m.page), m.tab_id()], ["settings", "game"], "SETTINGS again opens on GAME")
	m.key(_key(KEY_ESCAPE))
	t.eq(str(m.page), "top", "Esc: back to the top")
	m.free()

static func tabs_value(m: Control, id: String) -> String:
	return _value(m, id)

func test_the_card_at_every_size(t: T) -> void:
	var m := _menu()
	wire(m.tabs)
	t.eq(EscMenu.CARD.a, 1.0, "the card is opaque")
	for k: Array in m.tabs.key_rows:
		t.check(PixelFont.width(str(k[0])) <= EscMenu.KEY_COL_W, "CONTROLS: the key %s fits its column" % k[0])
	for s: Vector2 in SIZES:
		var card0 := Rect2()
		for i in SettingsTabs.TABS.size():
			m.set_tab(i)
			var tag := "%s %dx%d" % [m.tab_id(), int(s.x), int(s.y)]
			var lay: Dictionary = m.layout(s)
			var card: Rect2 = lay["rect"]
			var sc: float = lay["sc"]
			if i == 0:
				card0 = card
			t.check(card == card0, "%s: the card is the same on every tab" % tag)
			var tbs: Array = lay["tabs"]
			for j in tbs.size():
				t.check(card.encloses(tbs[j]), "%s: tab %d inside the card" % [tag, j])
				if j > 0:
					t.check(not (tbs[j - 1] as Rect2).intersects(tbs[j]), "%s: tabs %d and %d apart" % [tag, j - 1, j])
				t.check(PixelFont.width(str(SettingsTabs.TAB_NAMES[SettingsTabs.TABS[j]])) * sc + 12 * sc <= (tbs[j] as Rect2).size.x + 0.5, "%s: tab %d's name fits" % [tag, j])
			var rects: Array = lay["rows"]
			var r: Array = m.rows()
			var first: int = lay["first"]
			t.check(rects.size() <= EscMenu.VIS, "%s: at most %d rows shown" % [tag, EscMenu.VIS])
			for k in rects.size():
				var box: Rect2 = rects[k]
				var row: Dictionary = r[first + k]
				t.check(box.position.y >= (tbs[0] as Rect2).end.y, "%s: row %d under the tabs" % [tag, k])
				var pair: Array = lay["arrows"][k]
				if pair.is_empty():
					continue
				var lt: Rect2 = pair[0]
				var rt: Rect2 = pair[1]
				t.check(box.encloses(lt) and box.encloses(rt), "%s: %s's arrows inside its row" % [tag, row["id"]])
				var room := rt.position.x - lt.end.x - 4 * sc
				var need := PixelFont.width(str(row["value"])) * sc + (EscMenu.BAR_W + 4) * sc * (1 if float(row["frac"]) >= 0.0 else 0)
				t.check(need <= room, "%s: %s's value fits between its arrows (%d of %d)" % [tag, row["id"], int(need), int(room)])
				t.check(lt.position.x >= box.position.x + (6 + PixelFont.width(str(row["label"])) + 4) * sc, "%s: %s's words clear of its value" % [tag, row["id"]])
	m.free()

## A snapshot as the client decodes it: a floor with the Tenant's clock of `length` s and `left` s to go.
static func _latest(left: float, length := 600.0, extra := {}) -> Dictionary:
	var d := {"phase": "playing", "depth": 2, "ht": 1000.0, "tenant": {"at": 1000.0 + left, "len": length}}
	d.merge(extra, true)
	return d

func test_the_stairs_lamps(t: T) -> void:
	t.eq(StairsLamps.lit_of(600.0, 600.0), 1, "the doors: the first lamp")
	t.eq(StairsLamps.lit_of(541.0, 600.0), 1, "still one at 9:01")
	t.eq(StairsLamps.lit_of(540.0, 600.0), 2, "a tenth gone: two")
	t.eq(StairsLamps.lit_of(300.0, 600.0), 6, "half way: six")
	t.eq(StairsLamps.lit_of(60.0, 600.0), 10, "the last minute: the last lamp")
	t.eq(StairsLamps.lit_of(0.0, 600.0), 10, "here: every lamp")
	t.eq(StairsLamps.lit_of(210.0, 420.0), 6, "a seven-minute clock: by its own tenths")
	var prev := 0
	for s in range(600, -1, -1):
		var n := StairsLamps.lit_of(float(s), 600.0)
		if n < prev:
			t.check(false, "never goes out as the clock runs (%d s)" % s)
		prev = n
	var st := StairsLamps.state_of(_latest(45.0))
	t.eq([st["on"], st["lit"], st["warn"], st["here"]], [true, 10, true, false], "45 s: all lit, red, not yet here")
	t.eq(bool(st["warn"]), TenantClock.warn(45.0), "red exactly when the screen line is")
	st = StairsLamps.state_of(_latest(-3.0))
	t.eq([st["lit"], st["here"]], [10, true], "the Tenant here")
	st = StairsLamps.state_of(_latest(400.0))
	t.eq([st["lit"], st["warn"]], [4, false], "6:40 left: four, amber")
	for c: Array in [[{"phase": "riding"}, "a ride"], [{"ward": {}}, "the Ward's own clock"], [{"reactor": {}}, "the Reactor's"]]:
		t.eq(bool(StairsLamps.state_of(_latest(300.0, 600.0, c[0]))["on"]), false, "no row on %s" % c[1])
	var none := {"phase": "playing", "ht": 5.0}
	t.eq(bool(StairsLamps.state_of(none)["on"]), false, "no row without a clock")
	# On the lift, in the world: over the landing doors, above the indicator, under the ceiling, hidden with no clock.
	var lift: Lift = LiftScript.new()
	lift.build(PlanDump.car_plain(Run.car_geometry(Clinic.generate_clinic("hu2-car", 1))))
	var row: Node3D = lift.get_node_or_null("StairsLamps")
	t.check(row != null, "the lift has its STAIRS row")
	if row != null:
		var bottom := row.position.y - (StairsLamps.SIZE.y + 0.06) * 0.5
		var top := row.position.y + (StairsLamps.SIZE.y + 0.06) * 0.5
		t.check(bottom >= Lift.DOOR_H + 0.38 + 0.15, "above the car's indicator (bottom %.2f m)" % bottom)
		t.check(top <= Level.LH - 0.05, "under the ceiling (top %.2f m)" % top)
		t.check(row.position.z > Lift.LAND, "on the landing side")
		lift.show_stairs(_latest(200.0))
		t.eq([row.visible, int(lift.stairs_state()["lit"])], [true, 7], "3:20 left: seen, seven lit")
		lift.show_stairs(null)
		t.eq(row.visible, false, "no snapshot: not there")
	lift.free()

func test_nothing_new_on_the_glass_while_walking(t: T) -> void:
	var hud: Hud = HudScript.new()
	hud.tenant_line = TenantClock.text(400.0)
	hud.tenant_beat = TenantClock.shown(400.0, 600.0)
	hud.place = "2clinic"
	hud.anger = -1.0
	hud.visible_lines(0)
	var rest := hud.visible_lines(20000)
	t.eq(Array(rest), ["PLAY >"], "walking at 6:40: only PLAY on the glass")
	hud.display = true
	var tab := hud.visible_lines(20001)
	t.check(tab.has(TenantClock.text(400.0)), "Tab: the Tenant's time (%s)" % [tab])
	hud.display = false
	hud.anger = 0.2
	hud.anger_rates = "SPRINT 1 S OR 2 NOISES FILL IT"
	hud.health = 80.0
	hud.health_rates = "WALK -0.5/S"
	hud.visible_lines(30000)
	var walking := hud.visible_lines(40000)
	t.check(not walking.has(hud.anger_rates) and not walking.has(hud.health_rates), "the rates are not on the glass: %s" % [walking])
	hud.display = true
	var held := hud.visible_lines(40001)
	t.check(held.has(hud.anger_rates) and held.has(hud.health_rates), "on Tab the rates are: %s" % [held])
	# The lift prints the same words (client/main.gd passes the HUD's own rates to it).
	var sheets := LiftScript.rate_sheets(PackedStringArray([hud.anger_rates, hud.health_rates]))
	t.eq(" ".join(sheets[0].slice(1)), hud.anger_rates, "the lift's sheet says the anger rates word for word")
	var src := FileAccess.get_file_as_string("res://client/main.gd")
	t.check(src.contains("lift.show_notice(_notice_minutes, PackedStringArray([hud.anger_rates, hud.health_rates]))"), "the game gives the lift the HUD's own rates")
	t.check(src.contains("lift.show_stairs(lc.latest if lc != null else null)"), "and the lamp row the newest snapshot")
	hud.free()
	# The menu is not drawn unless shown.
	var m: Control = EscMenu.new()
	t.eq(bool(m.shown), false, "the menu is not drawn while walking")
	m.free()
