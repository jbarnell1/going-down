# HUD1 (the screen plan, stage 1; the owner's answers of 21 Nov): a quiet screen.
#   1. client/hud_fade.gd: a line shows on change, holds 4 s, fades over 1 s; it stays while urgent or on Tab; the
#      value is never changed, only how visible it is.
#   2. A resting Clinic frame (nothing changed for 10 s, nothing urgent) shows at most 2 lines of words.
#   3. Tab (DISPLAY) held: every counter, every rate line and the nerve.
#   4. The Tenant clock shows at the doors, 5:00, 2:00 and through the last minute; the voice's moments come once each
#      at those times, from the host's clock; the doors line carries the floor's own minutes.
#   5. CAR WAITING FOR is not shown in a run of one.
extends RefCounted

const T = preload("res://tests/t.gd")
const HudFade = preload("res://client/hud_fade.gd")
const HudScript = preload("res://client/hud.gd")
const TenantClock = preload("res://client/tenant_clock.gd")
const AnnouncerScript = preload("res://client/announcer.gd")
const Main = preload("res://client/main.gd")

func test_the_fade_helper(t: T) -> void:
	t.eq(HudFade.alpha(1000, 1000, false), 1.0, "full when it changes")
	t.eq(HudFade.alpha(1000, 5000, false), 1.0, "full through the 4 s hold")
	t.check(absf(HudFade.alpha(1000, 5500, false) - 0.5) < 1e-6, "half way through the 1 s fade")
	t.eq(HudFade.alpha(1000, 6000, false), 0.0, "gone after 5 s")
	t.eq(HudFade.alpha(1000, 60000, true), 1.0, "full while urgent, however long since")
	var f := HudFade.new()
	t.eq(f.see("floor", "FLOOR RECORDED 0/400", 0), 1.0, "a line seen for the first time shows")
	t.eq(f.see("floor", "FLOOR RECORDED 0/400", 10000), 0.0, "unchanged for 10 s: faded")
	t.eq(f.see("floor", "FLOOR RECORDED 0/400", 10000, false, true), 1.0, "on Tab: full")
	t.eq(f.see("floor", "FLOOR RECORDED 40/400", 11000), 1.0, "a new value: full again")
	t.eq(f.see("floor", "FLOOR RECORDED 40/400", 14900), 1.0, "and held")
	t.eq(f.see("floor", "FLOOR RECORDED 40/400", 16500), 0.0, "then gone")

## A Clinic floor as the screenshot showed it: the corner stack, the tape counter, the nerve preview.
func _clinic_hud() -> Hud:
	var hud: Hud = HudScript.new()
	hud.floor_quota_line = "FLOOR RECORDED 0/400"
	hud.day_line = "DAY EARNED 0/600"
	hud.tenant_line = "TENANT ARRIVES IN 09:21"
	hud.tenant_beat = TenantClock.shown(561.0, 600.0)
	hud.place = "1clinic"
	hud.set_tapes(1, 150.0)
	hud.nerve = [73.0, -3.0, -2.0, -1.0, 1.0, -15.0, 0.0]
	return hud

func test_a_resting_clinic_frame_is_quiet(t: T) -> void:
	var hud := _clinic_hud()
	var first := hud.visible_lines(0)
	t.check(first.has("FLOOR RECORDED 0/400") and first.has("DAY EARNED 0/600") and first.has("SP"), "on arrival the counters show: %s" % [first])
	var rest := hud.visible_lines(10000)
	t.check(rest.size() <= 2, "10 s with nothing changed: at most 2 lines, got %d %s" % [rest.size(), rest])
	t.check(rest.has("PLAY >"), "PLAY stays")
	t.eq(hud.floor_quota_line, "FLOOR RECORDED 0/400", "the value itself is untouched")
	t.eq(hud.tape_text_of(), "#x1 0150", "the tape's value is untouched")
	# A change brings the line back, then it goes again.
	hud.floor_quota_line = "FLOOR RECORDED 40/400"
	t.check(hud.visible_lines(11000).has("FLOOR RECORDED 40/400"), "a reading recorded: the floor line shows")
	t.check(not hud.visible_lines(17000).has("FLOOR RECORDED 40/400"), "and fades after")
	# Shaken is urgent: the nerve stays.
	hud.nerve = [20.0, -3.0, -2.0, -1.0, 1.0, -15.0, 1.0]
	hud.visible_lines(18000)
	t.check(hud.visible_lines(40000).has("NERVE 20/100  SHAKEN"), "SHAKEN stays on the glass")
	hud.free()

func test_tab_shows_every_counter_rate_and_the_nerve(t: T) -> void:
	var hud := _clinic_hud()
	hud.health = 80.0
	hud.health_rates = "WALK -0.5/S SPRINT -2/S STILL OR CREEP +1/S"
	hud.anger = 0.2
	hud.anger_rates = "SPRINT 1 S OR 2 NOISES FILL IT. ONLY A SEARCH EMPTIES IT"
	hud.visible_lines(0)
	var rest := hud.visible_lines(10000)
	t.check(not rest.has(hud.anger_rates) and not rest.has(hud.health_rates) and not rest.has("DARK -3/S  RESIDENT -2/S"), "without Tab: no rate line on the glass %s" % [rest])
	hud.display = true
	var all := hud.visible_lines(10000)
	for want: String in ["FLOOR RECORDED 0/400", "DAY EARNED 0/600", "TENANT ARRIVES IN 09:21", "SP", "#x1 0150",
			"NERVE 73/100", "DARK -3/S  RESIDENT -2/S", "APART -1/S  WITH CREW +1/S", "SEE A CATCH -15", "ANGER",
			hud.anger_rates, "HEALTH", hud.health_rates]:
		t.check(all.has(want), "Tab shows %s (got %s)" % [want, all])
	hud.free()

func test_the_tenant_clock_at_its_moments(t: T) -> void:
	for c: Array in [[599.0, true, "the doors"], [561.0, false, "mid-floor"], [300.0, true, "5:00"], [296.0, true, "just after 5:00"],
			[290.0, false, "after the 5:00 beat"], [120.0, true, "2:00"], [100.0, false, "after 2:00"], [60.0, true, "1:00"],
			[30.0, true, "the last minute"], [0.5, true, "the last second"], [-3.0, true, "just arrived"], [-10.0, false, "long arrived"]]:
		t.eq(TenantClock.shown(float(c[0]), 600.0), bool(c[1]), "%s (%.1f s left)" % [c[2], c[0]])
	# The screen's steps over a whole floor, every half second of the host's clock.
	var clock := TenantClock.new()
	var said := []
	var shown_last_minute := true
	var left := 600.0
	while left > -5.0:
		var r := clock.step({"phase": "away", "depth": 1, "ht": 600.0 - left, "tenant": {"at": 600.0, "len": 600.0}})
		if str(r["moment"]) != "":
			said.append(str(r["moment"]))
		if left <= 60.0 and not bool(r["show"]):
			shown_last_minute = false
		left -= 0.5
	t.eq(said, ["tenant_doors", "tenant_five", "tenant_two", "tenant_one"], "the voice's moments, once each, in order")
	t.check(shown_last_minute, "the line shows through the whole last minute")
	var late := TenantClock.new()
	var r2 := late.step({"phase": "away", "depth": 1, "ht": 200.0, "tenant": {"at": 600.0, "len": 600.0}})
	t.eq(str(r2["moment"]), "", "a late joiner hears no doors line")
	t.eq(TenantClock.new().step({"phase": "riding", "depth": 1, "ht": 0.0, "tenant": {"at": 600.0, "len": 600.0}})["show"], false, "no clock on a ride")
	# The announcer's captions (no recordings yet): the floor's own minutes, three lines a moment, never twice running.
	var a: Node = AnnouncerScript.new()
	a.fake = true
	a.persist = false
	a.clock_ms = 0
	t.check(str(a.tenant_beat("tenant_doors", 10)).contains("10 minutes"), "the doors line says the clock's ten minutes")
	t.check(str(a.tenant_beat("tenant_doors", 7)).contains("7 minutes"), "and a host's seven when it is seven")
	t.check(str(a.shown()).contains("7 minutes"), "shown as the caption")
	var prev := ""
	for i in 12:
		a.tenant_beat("tenant_one", 10)
		var id := str(a.tenant_said[-1]["id"])
		t.check(id != prev, "never the same line twice running")
		prev = id
	for m: String in AnnouncerScript.TENANT_BEAT_LINES:
		t.eq((AnnouncerScript.TENANT_BEAT_LINES[m] as Array).size(), 3, "three lines for %s" % m)
	a.free()

func test_car_waiting_is_for_a_crew(t: T) -> void:
	var text := "CAR WAITING FOR: YOU"
	var solo := {"players": [{"id": "p0", "active": true}]}
	t.eq(Main.car_waiting_shown(text, solo), "", "alone: not shown")
	var left := {"players": [{"id": "p0", "active": true}, {"id": "p1", "active": false}]}
	t.eq(Main.car_waiting_shown(text, left), "", "a friend who left: still alone")
	var two := {"players": [{"id": "p0", "active": true}, {"id": "p1", "active": true}]}
	t.eq(Main.car_waiting_shown(text, two), text, "with a crew: shown")
	t.eq(Main.car_waiting_shown("", two), "", "nothing to show: nothing")
