# The 24 recorded intercom lines of game night (assets_src/voice/lines.json groups deal, reactor, ward2, hush),
# each played through client/announcer.gd with its recording present:
#   1. the elevator deal: every spoken line (sim/deal.gd read_line, outcome_line, passed_line, double_line) maps to
#      its recording id, a name in the line does not matter, the caption keeps the name, and the clip file exists;
#   2. the Reactor's refused call for want of power plays reactor_no_power (once per 8 s);
#   3. the hush plays hush_1 to hush_3 in turn;
#   4. the Ward's call station, called, hung, cut and left-behind lines go through the queue with their recordings.
# A missing mp3 fails the clip's `found` check.
extends RefCounted

const T = preload("res://tests/t.gd")
const AnnouncerScript = preload("res://client/announcer.gd")
const Deal = preload("res://sim/deal.gd")

static func _ann(seed_text: String) -> Node:
	var m: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://assets/voice/manifest.json"))
	var a: Node = AnnouncerScript.new()
	a.fake = true
	a.persist = false
	a.clock_ms = 0
	a.my_id = "ann"
	a.days_on = true
	a._rng.seed = hash(seed_text)
	a.use_manifest(m if m is Dictionary else {})
	a.start_run(true, "night-" + seed_text)
	a.queue.clear()
	a.clock_ms = 5000
	return a

static func _wait(a: Node, ms: int) -> void:
	var end: int = a.clock_ms + ms
	while a.clock_ms < end:
		a.clock_ms += 100
		a.update()
		a.shown()

static func _found(a: Node, id: String) -> bool:
	for c: Dictionary in a.clips:
		if str(c["id"]) == id:
			return bool(c["found"])
	return false

func test_the_deal_lines_play_their_recordings(t: T) -> void:
	var a := _ann("vb-deal")
	var cases: Array = []
	for card: StringName in [&"squeak", &"torch", &"second", &"dark", &"express"]:
		cases.append([Deal.read_line(card), "deal_offer_%s" % card])
	for face: StringName in [&"hazard", &"squeak", &"torch", &"second", &"dark_pay", &"dark", &"express", &"express_awake"]:
		cases.append([Deal.outcome_line(face, "Ann"), "deal_out_%s" % face])
	cases.append([Deal.passed_line(), "deal_passed"])
	cases.append([Deal.double_line(), "deal_double"])
	t.eq(cases.size(), 15, "fifteen deal lines")
	for c: Array in cases:
		var text: String = c[0]
		var id: String = c[1]
		t.eq(AnnouncerScript.deal_line_id(text), id, "%s: its recording" % id)
		a.deal_say(text)
		_wait(a, 12000)
		t.check(_found(a, id), "%s: played, and its recording is in the game" % id)
	t.check("Ann" in Deal.outcome_line(&"hazard", "Ann") and AnnouncerScript.deal_line_id(Deal.outcome_line(&"hazard", "Zed")) == "deal_out_hazard",
		"the carrier's name stays in the caption, the recording does not need it")

func test_the_reactor_no_power_line(t: T) -> void:
	var a := _ann("vb-power")
	a.on_events([{"type": "callRefused", "t": 1.0, "playerId": "x", "earned": 0, "needed": 0, "reason": "power"}])
	_wait(a, 6000)
	t.check(_found(a, "reactor_no_power"), "a call refused for want of power plays reactor_no_power")
	var n: int = a.clips.size()
	a.on_events([{"type": "callRefused", "t": 2.0, "playerId": "x", "earned": 0, "needed": 0, "reason": "power"}])
	_wait(a, 6000)
	t.eq(a.clips.size(), n, "a second press within 8 s says nothing more")

func test_the_hush_plays_its_three_lines(t: T) -> void:
	var a := _ann("vb-hush")
	for i in 3:
		a.request("called")
		_wait(a, 800)
		t.check(a.hush(), "hush %d fires" % (i + 1))
		t.check(_found(a, "hush_%d" % (i + 1)), "hush_%d: played, and its recording is in the game" % (i + 1))
		_wait(a, 70000)
	t.eq(AnnouncerScript.HUSH_CAPTIONS[0], "AHEM. THANK YOU. AS I WAS SAYING.", "the caption of hush_1")

func test_the_ward_lines_go_through_the_queue(t: T) -> void:
	for id: String in ["ward_station", "ward_called", "ward_hung", "ward_cut", "ward_left_behind"]:
		var a := _ann("vb-" + id)
		a.late_floor = "ward"
		a.ward_line(id)
		t.check(a.queue.any(func(q: Dictionary) -> bool: return q.moment == id), "%s waits in the queue" % id)
		t.check(ResourceLoader.exists(str(a.lines[id].path)), "%s: its recording is in the game (%s)" % [id, str(a.lines[id].path)])
		_wait(a, 500)
		t.eq(str(a.current.get("id", "")), id, "%s speaks" % id)
		t.check(str(a.subtitle) != "", "%s has its caption" % id)
