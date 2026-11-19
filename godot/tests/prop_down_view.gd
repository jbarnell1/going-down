# Down first, then out on screen (client/down_view.gd; T8c), headless: what the screen says for a snapshot
# with the host's downs block, against the check's own reading of B6 (ten seconds, three held, 1.5 m).
#   1. Down: the timer is the host's (until - hostNow, rounded up), its bar the share left of the host's
#      own down time; the line says a crewmate can help, or that nobody is left, or who is helping and how far.
#   2. A crewmate down within reach: HOLD F TO HELP; the bar is the host's hold only while it is yours and F
#      is held; empty when you let go, when another holds, out of reach or on another level.
#   3. Out: the out screen. Without the down rule: nothing at all.
extends RefCounted

const T = preload("res://tests/t.gd")
const DownView = preload("res://client/down_view.gd")
const Protocol = preload("res://net/protocol.gd")

static func snap(status: String, down: Array, others: Array, host_now: float, me := Vector3(0, 0, 0)) -> Dictionary:
	return {"downs": {"down": down, "spots": []}, "hostNow": host_now,
		"me": {"id": "a", "status": status, "x": me.x, "z": me.z, "level": int(me.y)}, "others": others}

static func row(id: String, at: float, healer := "", heal_from: Variant = null) -> Dictionary:
	return {"id": id, "at": at, "until": at + 10.0, "by": "catch", "healer": healer, "healFrom": heal_from}

static func fig(id: String, status: String, x: float, z: float, level := 0) -> Dictionary:
	return {"id": id, "status": status, "x": x, "z": z, "level": level}

const NAMES := {"a": "Ann", "b": "Bob", "c": "Cy"}

func test_down_timer_and_lines(t: T) -> void:
	var v := DownView.new()
	v.update(snap("down", [row("a", 100.0)], [fig("b", "ok", 5, 0)], 103.2), "a", NAMES, false)
	t.eq(v.head, "DOWN  7", "the timer, 6.8 s left")
	t.check(absf(v.left - 0.68) < 1e-6, "the bar: %f of the ten seconds left" % v.left)
	t.eq(v.line, "A CREWMATE CAN HOLD F BESIDE YOU", "a crewmate on their feet")
	t.eq(v.line2, "CRAWL: W A S D", "what you can do")
	t.eq(v.prompt, "", "no help prompt for the downed")
	v.update(snap("down", [row("a", 100.0)], [fig("b", "out", 5, 0)], 109.99), "a", NAMES, false)
	t.eq(v.head, "DOWN  1", "the last fraction of a second still reads 1")
	t.eq(v.line, "NOBODY IS LEFT TO HELP YOU UP", "nobody left on their feet")
	v.update(snap("down", [row("a", 100.0, "b", 104.0)], [fig("b", "ok", 1, 0)], 105.5), "a", NAMES, false)
	t.eq(v.line, "BOB IS HELPING YOU UP", "who is helping")
	t.check(absf(v.heal - 0.5) < 1e-6, "the heal's bar is the host's hold, 1.5 of 3 s: %f" % v.heal)

func test_help_prompt_and_its_bar(t: T) -> void:
	var v := DownView.new()
	var down := [row("b", 100.0, "a", 101.0)]
	v.update(snap("ok", down, [fig("b", "down", 1.0, 0.5)], 102.5), "a", NAMES, true)
	t.eq(v.prompt, "HOLD F TO HELP", "in reach")
	t.check(absf(v.fill - 0.5) < 1e-6, "the bar: 1.5 of 3 s held: %f" % v.fill)
	t.eq(v.target, "b", "for Bob")
	v.update(snap("ok", down, [fig("b", "down", 1.0, 0.5)], 102.5), "a", NAMES, false)
	t.eq(v.fill, 0.0, "let go: empty at once")
	v.update(snap("ok", [row("b", 100.0)], [fig("b", "down", 1.0, 0.5)], 102.5), "a", NAMES, true)
	t.eq(v.fill, 0.0, "held but the host has no hold yet: empty")
	v.update(snap("ok", [row("b", 100.0, "c", 101.0)], [fig("b", "down", 1.0, 0.5)], 102.5), "a", NAMES, true)
	t.eq(v.prompt, "CY IS HELPING", "another holds")
	t.eq(v.fill, -1.0, "no bar of yours")
	v.update(snap("ok", down, [fig("b", "down", 1.6, 0.0)], 102.5), "a", NAMES, true)
	t.eq(v.prompt, "", "1.6 m away: out of reach")
	v.update(snap("ok", down, [fig("b", "down", 1.0, 0.0, 1)], 102.5), "a", NAMES, true)
	t.eq(v.prompt, "", "on the other level")
	v.update(snap("down", down, [fig("b", "down", 1.0, 0.0)], 102.5), "c", NAMES, true)
	t.eq(v.prompt, "", "down yourself: no prompt")

func test_out_and_off(t: T) -> void:
	var v := DownView.new()
	v.update(snap("out", [], [fig("b", "ok", 1, 0)], 120.0), "a", NAMES, false)
	t.check(v.out and v.out_lines.has("YOU REJOIN WHEN THE CAR NEXT MOVES"), "the out screen: %s" % str(v.out_lines))
	t.eq(v.head, "", "no timer once out")
	var off := snap("caught", [], [fig("b", "down", 1, 0)], 120.0)
	off["downs"] = null
	v.update(off, "a", NAMES, true)
	t.check(not v.out and v.head == "" and v.prompt == "", "without the down rule nothing is shown")

static func drag_sample(rear: Variant, held: bool, status := "down", at := 10.0) -> Dictionary:
	var down := row("a", at)
	down["drag"] = {"rear": rear, "held": held}
	return snap(status, [down], [fig("b", "ok", 2.0, 0.0)], at + 1.0)


func test_annex_drag_rear_view_uses_host_signal_after_snapshot_gap(t: T) -> void:
	var view := DownView.new()
	var ordinary := snap("down", [row("a", 10.0)], [fig("b","ok",2.0,0.0)], 11.0)
	ordinary["orderly"] = {"mode":"bending", "x":0.8, "z":0.0}
	ordinary["placed"] = {"x":0.0, "z":0.0}
	view.update(ordinary, "a", {}, false, "annex")
	ordinary.orderly.x = 0.05 + 0.8
	ordinary.placed.x = 0.05
	view.update(ordinary, "a", {}, false, "annex")
	t.check(not view.dragged and view.line2 == "CRAWL: W A S D", "old or no-flag rows do not infer a drag from movements")
	view.update(drag_sample(null, true), "a", {}, false, "annex")
	t.check(view.dragged and view.drag_yaw == null and view.line2 == "BEING DRAGGED", "a watch-held drag is known before any movement")
	var next := drag_sample(-PI * 0.5, false)
	next.hostNow = 13.0
	view.update(next, "a", {}, false, "annex")
	t.check(view.drag_yaw != null and is_equal_approx(float(view.drag_yaw), -PI * 0.5), "the first snapshot after a gap already knows to look back")
	t.check(view.line.contains("HOLD F") and view.seconds > 0.0, "the timer and recovery instruction still show")
	ordinary.hostNow = 14.0
	view.update(ordinary, "a", {}, false, "annex")
	t.check(not view.dragged, "a missing host signal releases presentation even if the old pose still bends")


func test_annex_drag_free_look_and_heal_release(t: T) -> void:
	var view := DownView.new()
	view.update(drag_sample(null, true), "a", {}, false, "annex")
	view.keep_drag_look()
	view.update(drag_sample(0.0, false), "a", {}, false, "annex")
	view.update(drag_sample(PI * 0.5, false), "a", {}, false, "annex")
	t.check(view.dragged and view.drag_yaw == null, "manual look during a pause stays free through a real turn")
	view.update(drag_sample(PI * 0.5, false, "ok"), "a", {}, false, "annex")
	t.check(not view.dragged and view.drag_yaw == null, "a healed placement resets the camera even with a late drag row")
	view.update(drag_sample(0.0, false, "down", 30.0), "a", {}, false, "annex")
	t.check(view.dragged and view.drag_yaw != null, "new catch does not inherit the earlier free-look latch")
	view.update(drag_sample(PI, false, "down", 30.0), "a", {}, false, "clinic")
	t.check(not view.dragged and view.line2 == "CRAWL: W A S D", "other floors retain ordinary down presentation")


func test_annex_drag_wire_keeps_old_rows_exact(t: T) -> void:
	var old := [[["a",10.0,20.0,0,"",null],["b",10.0,20.0,0,"a",11.0,1.5]],[]]
	var c := Protocol._V.new()
	var decoded := Protocol.dec_downs(c, old)
	t.check(not c.bad and not decoded.down[0].has("drag") and not decoded.down[1].has("drag"), "both legacy row shapes decode without any signal")
	t.eq(JSON.stringify(Protocol.enc_downs(decoded)), JSON.stringify(old), "disabled rows have exactly the old bytes")
	decoded.down[0]["drag"] = {"rear":null, "held":true}
	decoded.down[1]["drag"] = {"rear":-PI * 0.5, "held":false}
	var opt_in := Protocol.enc_downs(decoded)
	var current := Protocol._V.new()
	var roundtrip := Protocol.dec_downs(current, JSON.parse_string(JSON.stringify(opt_in)))
	t.check(not current.bad and roundtrip.down[0].drag.rear == null and roundtrip.down[0].drag.held, "stationary hold preserves absence of a rear heading")
	t.check(absf(float(roundtrip.down[1].drag.rear) + PI * 0.5) < 0.001 and float(roundtrip.down[1].healFor) == 1.5, "heading and existing private heal timer round-trip together")
	for invalid: Variant in [[],[0,2],[4,0],["north",0],null]:
		var wire: Array = opt_in.duplicate(true)
		wire[0][0][7] = invalid
		var wrong := Protocol._V.new()
		Protocol.dec_downs(wrong, wire)
		t.check(wrong.bad, "malformed drag suffix %s is rejected" % str(invalid))
