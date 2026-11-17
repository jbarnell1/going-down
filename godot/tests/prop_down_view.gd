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
