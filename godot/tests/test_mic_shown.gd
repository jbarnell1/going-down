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
func test_the_meter_clears_the_anger_bar(t: T) -> void:
	var hud: MicHud = MicHud.new()
	for sz: Vector2 in [Vector2(1280, 720), Vector2(1600, 900), Vector2(1920, 1080), Vector2(2560, 1440)]:
		var px := maxf(2.0, floorf(sz.y / 320.0))
		var margin := Vector2(maxf(sz.x * 0.06, 16.0), maxf(sz.y * 0.06, 12.0))
		var anger := Rect2(margin - Vector2(px, 2.0 * px), Vector2(200.0 * px, 26.0 * px))
		for hint: String in ["TALKING", MicHud.hint_text("none"), MicHud.hint_text("off")]:
			t.check(not hud.meter_rect(px, hint).intersects(anger), "%dx%d: the meter (%s) is clear of ANGER" % [sz.x, sz.y, hint])
	hud.free()

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
