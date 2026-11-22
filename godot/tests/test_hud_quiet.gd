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
const LiftScript = preload("res://client/lift.gd")
const InventoryViewScript = preload("res://client/inventory_view.gd")
const Run = preload("res://sim/run.gd")
const Clinic = preload("res://sim/clinic.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const HideView = preload("res://client/hide_view.gd")

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

## HUD1b: the lift's paper notice: the host's minutes, the floor's rates, and on the built car's wall.
func test_the_lift_notice_prints_the_hosts_minutes(t: T) -> void:
	var ten := " ".join(LiftScript.notice_rows(10))
	t.check(ten.contains("EACH LEVEL: 10 MINUTES, THEN THE TENANT COMES."), "ten minutes on paper: " + ten)
	t.check(" ".join(LiftScript.notice_rows(7)).contains("7 MINUTES"), "the host's seven when it is seven")
	t.eq(LiftScript.notice_rows(0).size(), 0, "no Tenant clock: no notice")
	t.check(LiftScript.notice_rows(10).size() <= LiftScript.NOTICE_ROWS, "the notice fits its sheet")
	for r: String in LiftScript.notice_rows(10):
		t.check(r.length() <= LiftScript.NOTICE_COLS, "a line fits the sheet's width: " + r)
	# HUD1c: readable at 1.5 m. The picture is 270 px tall over the camera's 70 degree vertical view (client/main.gd
	# VFOV), so at 1.5 m one screen pixel is 2 * 1.5 * tan(35 deg) / 270 m tall. The font is 7 rows: a glyph must cover
	# at least 1.5 screen pixels a row (10.5 px), and be at least twice the first notice's 0.045 m.
	var px_m := 2.0 * 1.5 * tan(deg_to_rad(Main.VFOV * 0.5)) / 270.0
	var min_m := maxf(7.0 * 1.5 * px_m, 2.0 * 0.045)
	t.check(LiftScript.NOTICE_GLYPH_M >= min_m, "glyphs %.3f m tall, readable minimum at 1.5 m %.3f m" % [LiftScript.NOTICE_GLYPH_M, min_m])
	t.check(LiftScript.NOTICE_SIZE.x <= 1.35 and LiftScript.NOTICE_SIZE.y <= 1.5, "a sheet is at most about 1.2 by 1.5 m: %s" % [LiftScript.NOTICE_SIZE])
	# The Playroom's real rate lines, on their own sheets, whole, with their numbers exact.
	var tuned := HideView.anger_rates_text(null, true, true)
	var health := HideView.health_rates_text(true)
	# PL1: under a first line naming its bar in the HUD bar's word (ANGER, HEALTH), whichever rates the floor has.
	var health_hunt := HideView.health_rates_text(true, null)
	for pair: Array in [[HideView.ANGER_RATES, 0], [tuned, 0], [HideView.anger_rates_text(null, true, false), 0],
			[health, 1], [health_hunt, 1], [HideView.health_rates_text(false), 1]]:
		var rate := str(pair[0])
		var both := PackedStringArray(["", ""])
		both[int(pair[1])] = rate
		var sheets: Array = LiftScript.rate_sheets(both)
		var rows := sheets[0] as PackedStringArray if not sheets.is_empty() else PackedStringArray()
		var head: String = ["ANGER", "HEALTH"][int(pair[1])]
		t.check(sheets.size() == 1 and rows.size() > 1 and rows[0] == head, "the %s rates' sheet starts %s: %s" % [head, head, rows])
		var printed := " ".join(rows.slice(1))
		t.check(printed == " ".join(rate.split(" ", false)), "the rate whole under its heading: %s / %s" % [rate, rows])
		t.check(rows.size() <= LiftScript.NOTICE_ROWS, "the heading and the rate fit the sheet: %d lines" % rows.size())
		for r: String in rows:
			t.check(r.length() <= LiftScript.NOTICE_COLS, "a line fits the sheet's width: " + r)
	t.check(LiftScript.NOTICE_GLYPH_M >= 0.09, "the letters stay at least 0.09 m: %.3f" % LiftScript.NOTICE_GLYPH_M)
	# The heading is the HUD bar's own word: the HUD's lines say ANGER and HEALTH.
	var hud_words: Control = HudScript.new()
	hud_words.set("anger", 0.2)
	hud_words.set("health", 80.0)
	hud_words.set("osd_on", false)
	var shown := Array(hud_words.call("visible_lines", 0))
	t.check(shown.has(LiftScript.RATE_HEADINGS[0]) and shown.has(LiftScript.RATE_HEADINGS[1]), "the HUD's bars are called %s: %s" % [LiftScript.RATE_HEADINGS, shown])
	hud_words.free()
	t.eq(LiftScript.rate_sheets(PackedStringArray(["", ""])).size(), 0, "no rates: no rate sheets")
	var car := Run.car_geometry(Clinic.generate_clinic("notice", 1))
	var lift: Node3D = LiftScript.new()
	lift.call("build", PlanDump.car_plain(car))
	var paper := lift.get_node("TenantNotice") as MeshInstance3D
	var sheet1 := lift.get_node("RateSheet1") as MeshInstance3D
	var sheet2 := lift.get_node("RateSheet2") as MeshInstance3D
	t.check(paper != null and not paper.visible, "the paper is up only once a clock is known")
	lift.call("show_notice", 10, PackedStringArray(["", ""]))
	t.check(paper.visible and (lift.get("notice_lines") as PackedStringArray) == LiftScript.notice_rows(10), "printed with the clock's minutes")
	t.check(not sheet1.visible and not sheet2.visible, "no rates on this floor: no rate sheets")
	lift.call("show_notice", 10, PackedStringArray([tuned, health]))
	t.check(sheet1.visible and sheet2.visible and (lift.get("rate_lines") as Array).size() == 2, "the Playroom: both rate sheets up")
	var w := float(car.width) * 0.5
	var d := float(car.depth)
	for mi: MeshInstance3D in [paper, sheet1, sheet2]:
		var zs := [mi.position.z - LiftScript.NOTICE_W * 0.5, mi.position.z + LiftScript.NOTICE_W * 0.5]
		t.check(absf(absf(mi.position.x) - w) < 0.05 and zs[0] > -d and zs[1] < -LiftScript.FRONT, "%s inside the car on a side wall" % mi.name)
	t.check(absf(paper.position.z - sheet1.position.z) >= LiftScript.NOTICE_W, "the notice and the first rate sheet do not overlap")
	lift.free()

## HUD1b: the inventory squares dim at rest; IN HAND for 2 s after a change.
func test_the_squares_dim_and_in_hand_is_brief(t: T) -> void:
	var inv: Control = InventoryViewScript.new()
	inv.set("block", {})
	inv.set("slots", [["juice", 1], ["", 0], ["", 0], ["", 0]])
	inv.set("sel", 0)
	t.eq(inv.call("row_alpha", 0), 1.0, "full on arrival")
	t.eq(inv.call("held_alpha", 0), 1.0, "IN HAND shows on arrival")
	t.eq(inv.call("held_text"), "IN HAND: " + InventoryViewScript.Inventory.long_name("juice"), "with the item's name")
	t.eq(inv.call("held_alpha", 2000), 1.0, "for 2 s")
	t.eq(inv.call("held_alpha", 3100), 0.0, "then gone")
	t.eq(inv.call("row_alpha", 10000), InventoryViewScript.IDLE_ALPHA, "the squares dim at rest, never vanish")
	inv.set("sel", 1)
	t.eq(inv.call("row_alpha", 11000), 1.0, "a change of hand: full again")
	t.eq(inv.call("held_alpha", 11000), 0.0, "an empty hand: no IN HAND line")
	inv.set("sel", 0)
	inv.call("row_alpha", 12000)
	inv.set("display", true)
	t.eq(inv.call("row_alpha", 30000), 1.0, "Tab: full")
	t.eq(inv.call("held_alpha", 30000), 1.0, "Tab: IN HAND too")
	inv.free()

func test_car_waiting_is_for_a_crew(t: T) -> void:
	var text := "CAR WAITING FOR: YOU"
	var solo := {"players": [{"id": "p0", "active": true}]}
	t.eq(Main.car_waiting_shown(text, solo), "", "alone: not shown")
	var left := {"players": [{"id": "p0", "active": true}, {"id": "p1", "active": false}]}
	t.eq(Main.car_waiting_shown(text, left), "", "a friend who left: still alone")
	var two := {"players": [{"id": "p0", "active": true}, {"id": "p1", "active": true}]}
	t.eq(Main.car_waiting_shown(text, two), text, "with a crew: shown")
	t.eq(Main.car_waiting_shown("", two), "", "nothing to show: nothing")
