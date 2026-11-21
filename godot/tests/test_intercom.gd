# IV1 (game night): the intercom's fixes, items 2 to 7 (item 1, the prison's deck, is tests/test_prison_deck.gd).
# The announcer (client/announcer.gd) with a fake clock and no audio, as tests/prop_hints.gd runs it:
#   2. the Ward's five lift lines go through the announcer's one queue: subtitled with their words, at the announcer's
#      level on its player, and never over another line (the doors line on arrival finishes first);
#   3. a call refused for the Reactor's power plays no quota line ("That button works when the floor quota is met");
#   4. on the Ward the floor quota met says nothing about calling the car: no quota line, no "CALL READY";
#   5. danger lines (a player taken, a player down) outlive a long lift line and are heard soon after it, never
#      dropped by the queue's old 3 or 4 s life; a down line refused only for the hints' spacing waits, not lost;
#   6. lines whose words are wrong are not dealt where they are wrong: "Welcome back to the surface", "storage halls",
#      "Red side goes down" on the Reactor, "Call any time" and "press the button" while the quota locks the call (and
#      on the Reactor), and "You may recognise the staff here" on a place met for the first time today;
#   7. while the ride-up reel or the cassette plays, chatter waits (its life stands still) and speaks after; a line
#      speaking when the reel starts stops and waits; danger lines still speak.
extends RefCounted

const T = preload("res://tests/t.gd")
const AnnouncerScript = preload("res://client/announcer.gd")
const WardView = preload("res://client/ward/view.gd")

var _manifest: Dictionary = {}

func _make(seed_text: String) -> Node:
	if _manifest.is_empty():
		var m: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://assets/voice/manifest.json"))
		_manifest = m if m is Dictionary else {}
	var a: Node = AnnouncerScript.new()
	a.fake = true
	a.persist = false
	a.clock_ms = 0
	a.my_id = "ann"
	a.days_on = true
	a._rng.seed = hash(seed_text)
	a.use_manifest(_manifest)
	a.start_run(true, "night-" + seed_text)
	a.queue.clear()
	a.clock_ms = 5000
	return a

## Steps the fake clock `ms` in 100 ms steps.
static func _wait(a: Node, ms: int) -> void:
	var end: int = a.clock_ms + ms
	while a.clock_ms < end:
		a.clock_ms += 100
		a.update()

static func _queued(a: Node, moment: String) -> bool:
	return a.queue.any(func(q: Dictionary) -> bool: return q.moment == moment)

static func _heard(a: Node, moment: String) -> Dictionary:
	for h: Dictionary in a.history:
		if h.moment == moment:
			return h
	return {}

## No two lines in the history overlap in time.
static func _no_overlap(a: Node) -> bool:
	for i in range(1, a.history.size()):
		var before: Dictionary = a.history[i - 1]
		if int(before.end) < 0 or int(before.end) > int(a.history[i].at):
			return false
	return true

func test_ward_lift_lines_go_through_the_queue(t: T) -> void:
	var a := _make("ward")
	a.late_floor = "ward"
	a.request("doors")
	a.update()
	t.eq(str(a.current.get("moment", "")), "doors", "the doors line on arrival speaks")
	var view := WardView.new(11, Vector3.ZERO)
	view.say = a.ward_line
	view.play_event({"type": "ward_departed"})
	t.check(_queued(a, "ward_lift_departed"), "the Ward's \"lift returns\" line waits in the announcer's queue")
	t.check(view.cue_player.stream == null, "and not on the Ward's own speaker")
	t.check(ResourceLoader.exists(str(a.lines["ward_lift_departed"].path)), "its recording is the Ward's take: " + str(a.lines["ward_lift_departed"].path))
	_wait(a, 15000)
	var h := _heard(a, "ward_lift_departed")
	t.check(not h.is_empty(), "it is heard after the doors line")
	t.check(_no_overlap(a), "never over another line: %s" % str(a.history))
	for ty: String in ["ward_last_minute", "ward_returned", "ward_final_call", "ward_closed"]:
		view.play_event({"type": ty})
		var sub := ""
		for k in 40:
			a.clock_ms += 100
			a.update()
			if a.subtitle != "":
				sub = a.subtitle
				break
		t.check(sub != "" and AnnouncerScript.WARD_LINES.values().has(sub), "%s speaks with its words as the subtitle: \"%s\"" % [ty, sub])
		_wait(a, 8000)
	t.eq(a.history.filter(func(x: Dictionary) -> bool: return str(x.moment).begins_with("ward_lift_")).size(), 5, "all five Ward lines heard through the one queue")
	# The view never entered the tree: its own nodes made in advance are freed with it.
	for n: Node in [view.player, view.camera, view.cue_player, view.load_sound, view.hud, view.prompt, view.subtitles, view.rope]:
		if is_instance_valid(n) and n.get_parent() == null:
			n.free()
	view.free()
	a.free()

func test_a_call_refused_for_power_says_no_quota_line(t: T) -> void:
	var a := _make("power")
	a.late_floor = "reactor"
	a.place = "reactor"
	a.on_events([{"type": "callRefused", "t": 10.0, "playerId": "ann", "earned": 0, "needed": 0, "reason": "power"}], 1, {"needed": 0, "earned": 0})
	_wait(a, 8000)
	t.check(not _queued(a, "hint_call_dead") and _heard(a, "hint_call_dead").is_empty(), "no \"works when the floor quota is met\" for a power refusal")
	# The same refusal for the quota still teaches it.
	var b := _make("quota-refused")
	b.place = "clinic"
	b.on_events([{"type": "callRefused", "t": 10.0, "playerId": "ann", "earned": 100, "needed": 900}], 1, {"needed": 900, "earned": 100})
	_wait(b, 8000)
	t.check(not _heard(b, "hint_call_dead").is_empty(), "a quota refusal still plays the quota hint")
	a.free()
	b.free()

func test_the_ward_quota_met_says_nothing_about_calling(t: T) -> void:
	var a := _make("ward-quota")
	a.late_floor = "ward"
	a.day_lock_on = true
	a.on_events([{"type": "quotaMet", "t": 20.0, "depth": 6, "earned": 900, "needed": 900}], 1, {"needed": 900, "earned": 900})
	_wait(a, 10000)
	t.check(_heard(a, "quota").is_empty() and not _queued(a, "quota"), "no \"you may now call the car\" on the Ward")
	t.check(not a.shown().contains("CALL READY") and not a.caption.contains("CALL READY") and not a.caption.contains("called"), "and no CALL READY caption")
	# The day met on the same tick: the day's line with only the day's caption.
	a.on_events([{"type": "quotaMet", "t": 30.0, "depth": 6, "earned": 900, "needed": 900},
		{"type": "dayMet", "t": 30.0, "earned": 2400, "quota": 2400}], 1, {"needed": 900, "earned": 900})
	var said := ""
	for k in 60:
		a.clock_ms += 100
		a.update()
		if a.subtitle != "":
			said = a.subtitle
			break
	t.check(said != "" and not said.contains("CALL"), "the day's line on the Ward says nothing of a call: \"%s\"" % said)
	# Elsewhere the quota line still plays.
	var b := _make("clinic-quota")
	b.place = "clinic"
	b.day_lock_on = true
	b.on_events([{"type": "quotaMet", "t": 20.0, "depth": 2, "earned": 900, "needed": 900}], 1, {"needed": 900, "earned": 900})
	_wait(b, 10000)
	t.check(not _heard(b, "quota").is_empty(), "on another floor the quota line still plays")
	a.free()
	b.free()

## WC1: with the Ward's lift called from its station (net/host_rules.gd ward_call; client/main.gd ward_called_on), the
## call is every floor's again, so its quota line plays there; the clock's five lines are never asked for (the host sends
## none of their cues: tests/prop_ward_call.gd).
func test_the_called_ward_quota_met_says_call(t: T) -> void:
	var a := _make("ward-called")
	a.late_floor = "ward"
	a.ward_called = true
	a.day_lock_on = true
	a.on_events([{"type": "quotaMet", "t": 20.0, "depth": 6, "earned": 900, "needed": 900}], 1, {"needed": 900, "earned": 900})
	_wait(a, 10000)
	t.check(not _heard(a, "quota").is_empty(), "the called Ward says the call is open, as every floor does")
	t.check(a.history.filter(func(x: Dictionary) -> bool: return str(x.moment).begins_with("ward_lift_")).is_empty(), "and none of the clock's lines")
	var latest := {"depth": 6, "ward": {"extras": {"called": true}}}
	t.check(preload("res://client/main.gd").ward_called_on(latest), "the main scene reads the call from the Ward's block")
	t.check(not preload("res://client/main.gd").ward_called_on({"depth": 6, "ward": {}}), "and not without it")
	a.free()

func test_danger_lines_outlive_a_lift_line(t: T) -> void:
	var a := _make("danger")
	a.place = "clinic"
	a.request("called", AnnouncerScript.EXPIRE_LONG_MS, "", "called_1")
	a.update()
	var called_ms: int = a._length_ms("called_1", 0)
	t.check(called_ms > 4500, "the lift line is longer than the old 4 s life (%d ms)" % called_ms)
	# A crewmate down and another taken just after the call.
	a.clock_ms += 200
	a.on_events([{"type": "downed", "t": 1.0, "playerId": "bob"}, {"type": "caught", "t": 1.0, "playerId": "cy"}], 1)
	t.check(_queued(a, "taken") and _queued(a, "hint_down_crew"), "both danger lines wait in the queue")
	_wait(a, 20000)
	var called := _heard(a, "called")
	var taken := _heard(a, "taken")
	var down := _heard(a, "hint_down_crew")
	t.check(not taken.is_empty() and not down.is_empty(), "both are heard (history %s)" % str(a.history.map(func(h: Dictionary) -> String: return h.id)))
	if not taken.is_empty() and not down.is_empty():
		var first: Dictionary = taken if int(taken.at) < int(down.at) else down
		t.check(int(first.at) - int(called.end) <= 1000, "the first within a second of the lift line's end (%d ms)" % (int(first.at) - int(called.end)))
		t.check(int(first.at) < int(called.at) + called_ms + 1000, "and ahead of anything else waiting")
	t.check(_no_overlap(a), "never two at once")
	# A down line refused only for the hints' spacing (a hint just heard) waits for it, it is not lost.
	var b := _make("danger-spacing")
	b.place = "clinic"
	t.check(b.hint("hint_job"), "a hint")
	b.update()
	b.clock_ms += 1000
	b.on_events([{"type": "downed", "t": 2.0, "playerId": "bob"}], 1)
	_wait(b, 20000)
	t.check(not _heard(b, "hint_down_crew").is_empty(), "the down line is heard after the hints' spacing")
	a.free()
	b.free()

func test_wrong_words_are_not_dealt_where_wrong(t: T) -> void:
	var a := _make("words")
	a.place = "clinic"
	var dealt := {}
	for i in 60:
		for mo: String in ["banked", "ride"]:
			dealt[a._deal(mo)] = true
	t.check(not dealt.has("banked_3"), "never \"Welcome back to the surface\"")
	t.check(not dealt.has("ride_2"), "never \"storage halls\"")
	t.check(dealt.has("banked_1") and dealt.has("ride_1"), "the other lines still dealt")
	a.place = "reactor"
	a.late_floor = "reactor"
	var bells := {}
	var lefts := {}
	for i in 60:
		bells[a._deal("bell")] = true
		lefts[a._deal("left")] = true
	t.check(not bells.has("bell_3") and bells.has("bell_1"), "no \"Red side goes down\" on the Reactor")
	t.check(not lefts.has("left_1") and not lefts.has("left_5"), "no \"Call any time\" on the Reactor (the call needs its power)")
	a.place = "clinic"
	a.late_floor = ""
	a.call_locked = true
	lefts = {}
	for i in 60:
		lefts[a._deal("left")] = true
	t.check(not lefts.has("left_1") and not lefts.has("left_5") and lefts.has("left_2"), "no \"Call any time\" or \"press the button\" while the quota locks the call")
	# Through on_events: the car leaves a fresh floor whose quota is not met.
	for i in 12:
		a.queue.clear()
		a.on_events([{"type": "carLeft", "t": 1.0, "reason": "unloaded"}], 1, {"needed": 900, "earned": 0})
		var q: Array = a.queue.filter(func(x: Dictionary) -> bool: return x.moment == "left")
		t.check(not q.is_empty() and not (str(q[0].id) in ["left_1", "left_5"]), "a fresh floor's leaving line is never a call any time line")
	a.call_locked = false
	var free_lefts := {}
	for i in 60:
		free_lefts[a._deal("left")] = true
	t.check(free_lefts.has("left_1"), "without the quota's lock \"Call any time\" is true and still dealt")
	a.free()
	# "You may recognise the staff here": not on the Arboretum met first today; yes on a place met before (cycles).
	var b := _make("reroll")
	for d: Array in [[1, "clinic"], [2, "clinic"], [3, "annex"], [4, "playroom"], [5, "arboretum"]]:
		b.place = d[1]
		b.clock_ms += 40000
		b.on_events([{"type": "doorsOpened", "t": 1.0, "reason": "arrival", "depth": d[0]}], 1)
	t.check(not b.hint_log.any(func(h: Dictionary) -> bool: return h.moment == "hint_reroll"), "the Arboretum (new today) is not greeted as familiar")
	b.place = "clinic"
	b.clock_ms += 40000
	b.on_events([{"type": "doorsOpened", "t": 1.0, "reason": "arrival", "depth": 8}], 1)
	t.check(b.hint_log.any(func(h: Dictionary) -> bool: return h.moment == "hint_reroll" and h.what == "requested"), "the Clinic again (cycles, floor 8) is")
	b.free()

func test_chatter_waits_for_the_reel_and_the_cassette(t: T) -> void:
	var a := _make("reel")
	a.place = "clinic"
	a.request("ride", AnnouncerScript.EXPIRE_MS, "", "ride_1")
	a.update()
	t.eq(str(a.current.get("moment", "")), "ride", "a chatter line speaks")
	a.hold_chatter = true
	a.clock_ms += 100
	a.update()
	t.check(a.current.is_empty(), "the reel starts: the chatter line stops")
	a.request("banked", AnnouncerScript.EXPIRE_LONG_MS)
	_wait(a, 25000)
	t.check(_heard(a, "banked").is_empty() and a.history.filter(func(h: Dictionary) -> bool: return h.moment == "ride").size() == 1, "nothing chatters while the reel plays")
	t.check(_queued(a, "banked") and _queued(a, "ride"), "and it waits, not dropped")
	a.on_events([{"type": "caught", "t": 3.0, "playerId": "bob"}], 1)
	_wait(a, 8000)
	t.check(not _heard(a, "taken").is_empty(), "a danger line still speaks over the reel")
	a.hold_chatter = false
	_wait(a, 20000)
	t.check(not _heard(a, "banked").is_empty(), "after the reel the banked line speaks")
	t.check(a.history.filter(func(h: Dictionary) -> bool: return h.moment == "ride").size() == 2, "and the stopped line again")
	t.check(_no_overlap(a), "never two at once")
	a.free()
