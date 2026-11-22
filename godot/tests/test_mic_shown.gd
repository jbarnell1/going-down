# VC3: the microphone meter is really on screen.
#   1. The meter layer (client/mic_hud.gd) made in code under a CanvasLayer, as client/main.gd makes it, fills the
#      screen at 480x270 and 1280x720, so the meter (top right), MIC OFF / NO MIC and the consent and calibration
#      cards draw inside it (it was 0x0, clipped off the top-left corner).
#   2. The host's world carries the "mic" list (what turns the meter on, client/main.gd _mic_list) to a solo player
#      on floor 1: a solo run started as PLAY ALONE starts it, the floor picker's floor 1, and the orientation
#      prelude a new campaign starts with.
#   3. The same from the dedicated server's room (server/room.gd) with two players: floor 1 and the prelude.
extends RefCounted

const T = preload("res://tests/t.gd")
const MicHud = preload("res://client/mic_hud.gd")
const Mic = preload("res://client/mic.gd")
const LocalRoom = preload("res://net/local_room.gd")
const Session = preload("res://net/session.gd")
const Places = preload("res://sim/places.gd")
const Room = preload("res://server/room.gd")
const WsServer = preload("res://net/ws_server.gd")
const Hud = preload("res://client/hud.gd")
const Main = preload("res://client/main.gd")
const MicMeter = preload("res://client/mic_meter.gd")

func _hud_rect(w: int, h: int) -> Array:
	var root := (Engine.get_main_loop() as SceneTree).root
	var vp := SubViewport.new()
	vp.size = Vector2i(w, h)
	root.add_child(vp)
	var layer := CanvasLayer.new()
	vp.add_child(layer)
	var hud := MicHud.new()
	hud.mic = Mic.new()
	layer.add_child(hud)
	var r := hud.get_rect()
	var m: Node = hud.mic
	vp.free()
	m.free()
	return [r, Rect2(Vector2.ZERO, Vector2(w, h))]

func test_layer_fills_the_screen(t: T) -> void:
	for sz: Vector2i in [Vector2i(480, 270), Vector2i(1280, 720)]:
		var got: Array = _hud_rect(sz.x, sz.y)
		var r: Rect2 = got[0]
		var screen: Rect2 = got[1]
		t.eq(r.size, screen.size, "%dx%d: the mic layer is the whole screen (meter top right, cards centred)" % [sz.x, sz.y])
		t.check(screen.encloses(r), "%dx%d: the mic layer lies inside the screen" % [sz.x, sz.y])
		# Where the meter's box and the consent card's middle land, by the same sums _draw uses.
		var px := maxf(2.0, floorf(r.size.y / 320.0))
		# The meter's row in the top left (VC4), with its longest hint, inside the screen.
		var hud: MicHud = MicHud.new()
		for hint: String in ["TALKING", MicHud.hint_text("none"), MicHud.hint_text("off")]:
			t.check(screen.encloses(hud.meter_rect(px, hint)), "%dx%d: the meter's row with %s is on screen" % [sz.x, sz.y, hint])
		hud.free()
		t.check(screen.has_point(r.size * 0.5), "%dx%d: the consent card's centre is on screen" % [sz.x, sz.y])

## VC4: the meter's row clears the Playroom's ANGER bar and its rate line (client/hud.gd _draw_anger: its own
## margin, 6 % of the screen in from the top left) at the window sizes players use.
## PL1: and at the internal 480x270 (Fable's window: the row touched ANGER there), where the anger bar now starts
## below the meter (client/hud.gd anger_at).
func test_the_meter_clears_the_anger_bar(t: T) -> void:
	var hud: MicHud = MicHud.new()
	for sz: Vector2 in [Vector2(480, 270), Vector2(640, 360), Vector2(960, 540), Vector2(1280, 720), Vector2(1600, 900),
			Vector2(1920, 1080), Vector2(2560, 1440)]:
		var px := maxf(2.0, floorf(sz.y / 320.0))
		var at: Vector2 = Hud.anger_at(sz, px)
		var anger := Rect2(at - Vector2(px, 2.0 * px), Vector2(200.0 * px, 26.0 * px))
		t.check(Rect2(Vector2.ZERO, sz).encloses(anger), "%dx%d: the anger bar and its rate line are on screen" % [sz.x, sz.y])
		for hint: String in ["TALKING", MicHud.hint_text("none"), MicHud.hint_text("off")]:
			t.check(not hud.meter_rect(px, hint).intersects(anger), "%dx%d: the meter (%s) is clear of ANGER" % [sz.x, sz.y, hint])
	hud.free()

## PL1: no microphone, or one switched off, reads NOISE in the plain colour with nothing alarming; the orange NO SIGNAL
## is only for a microphone that was allowed, switched on and calibrated and then went quiet.
func test_no_mic_is_not_an_error(t: T) -> void:
	var base := {"listening": false, "allowed": true, "enabled": true, "calibrated": true, "status": "on"}
	var cases := [
		["no voice in this run", false, {}, "NOISE", ""],
		["a browser or a machine that cannot listen", true, {"listening": false, "allowed": false, "enabled": false, "calibrated": false, "status": "none"}, "NOISE", ""],
		["said yes once, on a machine that cannot listen now", true, {"listening": false, "allowed": false, "enabled": true, "calibrated": true, "status": "none"}, "NOISE", ""],
		["never said yes", true, {"listening": false, "allowed": true, "enabled": false, "calibrated": false, "status": "off"}, "NOISE", "M: MIC ON"],
		["switched off with M", true, {"listening": false, "allowed": true, "enabled": false, "calibrated": true, "status": "off"}, "NOISE", "M: MIC ON"],
		["switched on, never calibrated, no signal", true, {"listening": false, "allowed": true, "enabled": true, "calibrated": false, "status": "none"}, "NOISE", ""],
	]
	for c: Array in cases:
		var lab: Array = MicHud.meter_label(bool(c[1]), c[2] as Dictionary)
		t.eq(str(lab[0]), str(c[3]), "%s: the meter reads %s" % [c[0], c[3]])
		t.eq(str(lab[2]), str(c[4]), "%s: hint '%s'" % [c[0], c[4]])
		t.check(lab[1] == MicHud.DIM and lab[3] == MicHud.DIM, "%s: the plain colour, nothing orange" % c[0])
		t.check(str(lab[0]) != "NO MIC" and str(lab[2]) != "NO SIGNAL", "%s: no NO MIC, no NO SIGNAL" % c[0])
	var on := base.duplicate()
	on["listening"] = true
	t.eq(MicHud.meter_label(true, on), ["MIC", MicHud.GREEN, "", MicHud.DIM], "listening: MIC in green")
	var lost := base.duplicate()
	lost["status"] = "none"
	var ll: Array = MicHud.meter_label(true, lost)
	t.check(str(ll[0]) == "MIC" and str(ll[2]) == "NO SIGNAL" and ll[3] == MicHud.AMBER, "allowed, on, calibrated, then silent: the orange NO SIGNAL (%s)" % [ll])
	# The real microphone node's own describe() for a browser player (never allowed): NOISE.
	var m := Mic.new()
	m.meter.persist = false
	m.allowed = false
	m._apply()
	t.eq(str(MicHud.meter_label(true, m.describe())[0]), "NOISE", "a real Mic that cannot listen reads NOISE (status %s)" % m.status)
	m.free()

## PL1: holding Tab (DISPLAY) shows the noise meter even in silence (client/main.gd _sync_display sets force_show).
func test_tab_shows_the_meter_in_silence(t: T) -> void:
	var main := Main.new()
	main.hud = Hud.new()
	main.mic_hud = MicHud.new()
	main.mic_hud.in_run = true
	main.t_display = true
	main._sync_display()
	t.check(main.mic_hud.force_show, "Tab held: the meter is forced on")
	main.mic_hud._process(0.0)
	t.eq(main.mic_hud.modulate.a, 1.0, "Tab held in silence: the meter is drawn whole")
	main.t_display = false
	main._sync_display()
	t.check(not main.mic_hud.force_show, "Tab let go: no longer forced")
	main.mic_hud._process(0.0)
	t.eq(main.mic_hud.modulate.a, 0.0, "Tab let go, never a sound: the meter is hidden")
	main.mic_hud.free()
	main.hud.free()
	main.free()

## PL1: `micui consent|calib|off` draws the cards from a stand-in microphone: only with testport=, the player's settings
## never read or written, the real microphone never touched or opened, the keys left alone; the cards centred and whole.
func test_micui_draws_the_cards_without_the_settings(t: T) -> void:
	var path := MicMeter.SAVE_PATH
	var existed := FileAccess.file_exists(path)
	var stamp := FileAccess.get_modified_time(path) if existed else 0
	var main := Main.new()
	main.hud = Hud.new()
	var real := Mic.new()
	real.meter.persist = false
	real.allowed = false
	real.meter.asked = true
	main.mic = real
	main.mic_hud = MicHud.new()
	main.mic_hud.mic = real
	t.eq(main._command("micui consent"), "micui needs testport", "without testport= it is refused")
	t.check(not main.mic_hud.consent_open(), "and nothing is drawn")
	main._test_port = 4870
	var got: Variant = JSON.parse_string(main._command("micui consent"))
	t.check(got is Dictionary and bool(got["consent"]) and main.mic_hud.consent_open(), "micui consent: the consent card is up (%s)" % [got])
	var stand: Node = main.mic_hud.card_mic
	t.check(stand != null and stand != real, "drawn from a stand-in microphone")
	t.check(stand != null and not bool(stand.get(&"allowed")) and not (stand.get(&"meter") as MicMeter).persist, "the stand-in can never open or save")
	var y := InputEventKey.new()
	y.pressed = true
	y.physical_keycode = KEY_Y
	t.check(not main.mic_hud.key(y), "the card shown for a photograph takes no keys")
	t.check(not real.meter.enabled and real.meter.asked and not real.calib_open, "the real microphone is untouched by Y")
	got = JSON.parse_string(main._command("micui calib"))
	t.check(got is Dictionary and bool(got["calib"]) and not bool(got["consent"]), "micui calib: the calibration card is up")
	var cm: Node = main.mic_hud.card_mic
	t.check(str(cm.call(&"calib_line")).begins_with("SAY THIS") and int(cm.call(&"level")) == MicMeter.TALK_LEVEL, "mid-reading, the bar at a talking voice: %s" % cm.call(&"calib_line"))
	t.check(cm.get(&"_player") == null, "the stand-in never opened a microphone")
	got = JSON.parse_string(main._command("micui off"))
	t.check(got is Dictionary and str(got["card"]) == "" and not main.mic_hud.consent_open() and not main.mic_hud.calib_open(), "micui off: gone")
	t.check(main.mic_hud.card_mic == null, "the stand-in is freed")
	t.eq(FileAccess.file_exists(path), existed, "the settings file neither made nor removed")
	if existed:
		t.eq(FileAccess.get_modified_time(path), stamp, "the settings file not written")
	# Both cards centred and whole at the sizes players use, the small internal size included.
	for sz: Vector2 in [Vector2(480, 270), Vector2(1280, 720), Vector2(1920, 1080)]:
		for units: Vector2 in [MicHud.consent_units(), MicHud.calib_units()]:
			var r := MicHud.card_rect(sz, units)
			t.check(Rect2(Vector2.ZERO, sz).encloses(r), "%dx%d: a card (%s) is whole on screen: %s" % [sz.x, sz.y, units, r])
			t.check((r.get_center() - sz * 0.5).length() < 1.0, "%dx%d: centred" % [sz.x, sz.y])
			t.check(MicHud.card_px(sz, units) >= (2.0 if sz.y >= 720 else 1.0), "%dx%d: letters at the HUD's size" % [sz.x, sz.y])
	# The calibration bar's WHISPER and TALK labels (the photograph showed WHISTALK): apart, and inside the card, from
	# 480x270 up. The bar's top left by the same sums _draw_calib uses.
	for sz: Vector2 in [Vector2(480, 270), Vector2(640, 360), Vector2(960, 540), Vector2(1280, 720), Vector2(1920, 1080), Vector2(2560, 1440)]:
		var units := MicHud.calib_units()
		var px := MicHud.card_px(sz, units)
		var card := MicHud.card_rect(sz, units)
		var bar_at := card.position + Vector2(12.0 * px, 10.0 * px + 11.0 * px * 4.0)
		var labs: Array = MicHud.calib_mark_labels(px, bar_at)
		var a: Rect2 = labs[0][1]
		var b: Rect2 = labs[1][1]
		t.check(not a.grow(px * 0.5).intersects(b), "%dx%d: %s and %s do not overlap (%s, %s)" % [sz.x, sz.y, labs[0][0], labs[1][0], a, b])
		t.check(card.encloses(a) and card.encloses(b), "%dx%d: both labels inside the card" % [sz.x, sz.y])
	main.mic_hud.free()
	main.hud.free()
	real.free()
	main.free()

func test_the_esc_card_names_m(t: T) -> void:
	var hud: Control = load("res://client/hud.gd").new()
	var found := false
	for row: Array in hud.call(&"menu_rows"):
		found = found or (str(row[0]) == "M" and str(row[1]).contains("MICROPHONE"))
	t.check(found, "the Esc controls card has M: MICROPHONE ON / OFF")
	hud.free()

static func _mic_of(room: LocalRoom) -> Variant:
	return (room.client.latest as Dictionary).get("mic") if room.client.latest is Dictionary else null

static func _settle(room: LocalRoom) -> void:
	for i in 8:
		room.poll(0.05 * i)

func test_solo_floor_one_carries_the_mic_list(t: T) -> void:
	var original := Session.deck
	Session.deck = Places.FULL
	# The floor picker's floor 1.
	var a := LocalRoom.new()
	a.open_local("vc3-a", "Tester", true)
	a.late_archive_root = ""
	a.start_playtest(1)
	_settle(a)
	t.eq(int(a.host.state.depth), 1, "the floor picker: floor 1")
	t.check(a.host.state.voice, "the floor picker's floor 1 has the voice on")
	t.check(_mic_of(a) is Array, "the floor picker's floor 1: the world carries the mic list")
	a.leave()
	# PLAY ALONE as a scripted run starts it (no orientation): straight to floor 1.
	var b := LocalRoom.new()
	b.open_local("vc3-b", "Tester", true)
	b.late_archive_root = ""
	b.orientation_campaign = false
	b.start_run()
	_settle(b)
	t.check(b.host.state.voice, "PLAY ALONE: the voice is on")
	t.check(_mic_of(b) is Array, "PLAY ALONE (depth %d): the world carries the mic list" % int(b.host.state.depth))
	b.leave()
	# PLAY ALONE as a player starts it: the orientation prelude first.
	var c := LocalRoom.new()
	c.open_local("vc3-c", "Tester", true)
	c.late_archive_root = ""
	c.orientation_campaign = true
	c.start_run()
	_settle(c)
	t.check(c.host.state.orientation, "a new campaign starts in the orientation prelude")
	t.check(c.host.state.voice, "the orientation prelude has the voice on")
	t.check(_mic_of(c) is Array, "the orientation prelude: the world carries the mic list")
	var resume: Variant = c.host.state.orientation_resume
	t.check(resume != null and resume.voice, "the campaign the prelude hands back to keeps the voice on")
	c.leave()
	Session.deck = original

func test_server_carries_the_mic_list(t: T) -> void:
	var quiet := func(_line: String) -> void: pass
	for prelude: bool in [false, true]:
		var room := Room.new(WsServer.new("", true, quiet), quiet)
		room.fixed_seed = "vc3-server"
		room.orientation_campaign = prelude
		room.people = {"c1": "ANN", "c2": "BOB"}
		room.ready = {"c1": 0.0, "c2": 0.0}
		room._start(0.0)
		var what := "the server's orientation prelude" if prelude else "the server's floor 1"
		t.eq(bool(room.host.state.orientation), prelude, "%s: the room is where it should be" % what)
		t.check(room.host.state.voice, "%s: the voice is on" % what)
		t.check(room.host.world().get("mic") is Array, "%s: the world carries the mic list to both clients" % what)
		if prelude:
			var resume: Variant = room.host.state.orientation_resume
			t.check(resume != null and resume.voice, "%s: the campaign after it keeps the voice on" % what)
		room.host.close()
