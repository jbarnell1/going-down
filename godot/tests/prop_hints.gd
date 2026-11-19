# The announcer's hints (docs/floors/announcer-hints.md, AH1; client/hints.gd, client/announcer.gd) over
# scripted nights of random events with a fake clock and no audio (each line "plays" for its estimated
# length): no hint starts while any of the three players is playing and no hint ever stops a line; no
# hint is heard more often than its repeat rule allows, none twice within 60 s, no two within 30 s
# unless the second is priority 4; a hint that expired or was cut is not heard; "replaces" asks for
# exactly one of the hint and its line; the place rules (the Playroom's own hints, hint_reroll, the four
# lines a place makes wrong); no hint starts in the last 11 s of a count or 6 s before a number; every
# hint's words are 20 or fewer and name no trait and no body. Also: the table matches the recordings,
# the first-timer hints retire after two nights, HINTS: OFF stops them. And the Minder's grab outside a
# count (T15m): its own line dealt per grab (never the same twice running, the caption the line), on the
# count's player, so no hint starts over it either.
extends RefCounted

const T = preload("res://tests/t.gd")
const Rng = preload("res://sim/rng.gd")
const Hints = preload("res://client/hints.gd")
const AnnouncerScript = preload("res://client/announcer.gd")

const STEP_MS := 100
const PLACES := ["clinic", "annex", "playroom"]
const CAPS := ["night", "day", "floor", "count"]
## The hints a screen asks for itself (client/hint_cues.gd), asked at random here.
const CUES := ["hint_left_you", "hint_left_crew", "hint_straggler", "hint_winded", "hint_hide", "hint_hide_idle",
	"hint_car_stay", "hint_car_no_record", "hint_quiet_needle", "hint_play_no_run", "hint_last_miss"]
const REPLACED := {"hint_board": "arrived", "hint_play_arrive": "doors", "hint_new_floor": "doors", "hint_reroll": "doors"}

var _manifest: Dictionary = {}

func _load_manifest() -> Dictionary:
	if _manifest.is_empty():
		var m: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://assets/voice/manifest.json"))
		_manifest = m if m is Dictionary else {}
	return _manifest

func _make(seed_text: String) -> Node:
	var a: Node = AnnouncerScript.new()
	a.fake = true
	a.persist = false
	a.clock_ms = 0
	a.my_id = "ann"
	a.days_on = true
	a._rng.seed = hash(seed_text)
	a.use_manifest(_load_manifest())
	return a

# ---- the scripted night -------------------------------------------------------------------------

## What one night broke, counted by rule.
class Night:
	var a: Node
	var rng: Rng
	var now := 0
	var place := ""
	var count := {}
	var heard := {}        # cap -> {moment: n}: started and not cut, by this test's own count
	var starts := {}       # moment -> [ms] of starts not cut
	var last_start := -1
	var last_start_pri := 0
	var log_seen := 0
	var said_seen := 0
	var count_lines: Array = []   # [from, to] of every count line and number "playing"
	var last_count_start := {}
	var bad := {}
	var counted := {"started": 0, "expired": 0, "cut": 0, "replaces": 0, "playroom_counts": 0, "grabs": 0}
	var last_grab := ""

	func fail(rule: String, what: String) -> void:
		if not bad.has(rule):
			bad[rule] = []
		if (bad[rule] as Array).size() < 4:
			(bad[rule] as Array).append(what)

	func reset_cap(cap: String) -> void:
		heard[cap] = {}

	## One step of the clock: the announcer's update, then every new log entry checked.
	func step(ms := STEP_MS) -> void:
		now += ms
		a.clock_ms = now
		a.update()
		_check_logs()

	func events(evs: Array) -> void:
		a.on_events(evs, 1)

	func ask(id: String) -> bool:
		var before: Dictionary = a.current.duplicate()
		var ok: bool = a.hint(id)
		# A hint never stops a line, playing or not.
		if a.current.get("id", "") != before.get("id", "") or a.current.get("at", 0) != before.get("at", 0):
			fail("a hint stopped a line", "%s at %d stopped %s" % [id, now, before.get("id", "")])
		_check_logs()
		return ok

	## The Minder's grab outside a count: its own line, never the same twice running, the caption its words.
	func grab() -> void:
		counted["grabs"] += 1
		var id: String = a.say_grab(2200)
		# (said_count keeps its last 80: the newest is the last.)
		var said: Dictionary = a.said_count[-1] if not a.said_count.is_empty() else {}
		if id == "" or str(said.get("id", "")) != id or str(a.lines[id].moment) != "grab":
			fail("grab", "at %d: dealt %s, said %s" % [now, id, str(said)])
		elif str(said["text"]) != str(a.lines[id].plain) or str(said["line"]) != "grab":
			fail("grab", "at %d: %s captioned \"%s\"" % [now, id, said["text"]])
		if id != "" and id == last_grab:
			fail("grab", "at %d: %s twice running" % [now, id])
		last_grab = id
		_check_logs()

	func say(line: String, text: String, ms: int, number := -1, length := 0) -> void:
		a.say_count(line, text, ms, number, length)
		_check_logs()

	# Requests can be deferred at the search transition. The actual start is reported separately.
	func _track_count_start() -> void:
		if a.said_count.is_empty():
			return
		var started: Dictionary = a.said_count[-1]
		if is_same(started, last_count_start):
			return
		last_count_start = started
		if str(started["id"]) == "":
			return
		var at := int(started["at"])
		var slot := "number" if started["line"] == "number" else "count"
		for c: Array in count_lines:
			var search_ends_numbers: bool = started["line"] == "search" and place == "playroom" and c[2] == "number"
			if (c[2] == slot or search_ends_numbers) and int(c[1]) > at:
				c[1] = at
		count_lines.append([at, at + a._length_ms(str(started["id"]), 2000), slot])

	func _check_logs() -> void:
		_track_count_start()
		var hl: Array = a.hint_log
		for e: Dictionary in hl:
			var m := str(e["moment"])
			match str(e["what"]):
				"requested":
					if not Hints.place_ok(m, str(e.get("place", ""))):
						fail("place", "%s requested on %s" % [m, e.get("place", "")])
				"started":
					counted["started"] += 1
					_on_start(m, int(e["at"]), bool(e.get("busy", false)))
				"cut":
					counted["cut"] += 1
					for cap: String in CAPS:
						var h: Dictionary = heard.get(cap, {})
						h[m] = int(h.get(m, 0)) - 1
					var list: Array = starts.get(m, [])
					if not list.is_empty():
						list.pop_back()
					_same_counts(m, "cut")
				"expired":
					counted["expired"] += 1
					_same_counts(m, "expired")
		# The lines dealt: the four a place makes wrong.
		hl.clear()
		for r: Dictionary in a.request_log:
			var id := str(r["id"])
			var pl := str(r["place"])
			if (id == "doors_1" or id == "slip_2") and pl != "clinic":
				fail("place line", "%s dealt on %s" % [id, pl])
			if (id == "arrived_5" or id == "blackout_3") and pl == "playroom":
				fail("place line", "%s dealt on the Playroom" % id)
		a.request_log.clear()
		while not count_lines.is_empty() and int(count_lines[0][1]) < now - 1000:
			count_lines.pop_front()

	## The gate's own heard count equals this test's (started minus cut): a hint that expired or was cut
	## is not heard.
	func _same_counts(m: String, why: String) -> void:
		var mine := int((heard.get("night", {}) as Dictionary).get(m, 0))
		var gate := int(a.hints.heard_night.get(m, 0))
		if mine != gate:
			fail("expired or cut is not heard", "%s %s at %d: the gate has it heard %d times, started-not-cut %d" % [m, why, now, gate, mine])

	func _on_start(m: String, at: int, busy: bool) -> void:
		# Never over another line: none of the three players busy, by the gate and by this test's own record.
		if busy or not a.current.get("hint", true):
			fail("a hint started over a line", "%s at %d" % [m, at])
		for c: Array in count_lines:
			if at >= int(c[0]) and at < int(c[1]):
				fail("a hint started over a line", "%s at %d over a count line %s" % [m, at, str(c)])
		# The count: never 6 s or less before a number, never in its last 11 s.
		if Hints.number_in(count) <= Hints.NUMBER_CLEAR_S:
			fail("count", "%s at %d with a number %.1f s away" % [m, at, Hints.number_in(count)])
		if str(count.get("phase", "")) == "seek" and float(count.get("left", 0.0)) <= Hints.COUNT_TAIL_S:
			fail("count", "%s at %d in the count's last %.1f s" % [m, at, float(count["left"])])
		# The repeat rule.
		var row: Dictionary = Hints.TABLE[m]
		for cap: String in CAPS:
			if not heard.has(cap):
				heard[cap] = {}
			var h: Dictionary = heard[cap]
			h[m] = int(h.get(m, 0)) + 1
			var most := int(row.get(cap, 0))
			if most > 0 and int(h[m]) > most:
				fail("repeat", "%s heard %d times this %s (at most %d)" % [m, h[m], cap, most])
		if int(a.hints.floor_n) > Hints.FLOOR_MAX:
			fail("repeat", "more than %d hints on a floor" % Hints.FLOOR_MAX)
		# Spacing.
		var list: Array = starts.get(m, [])
		if not list.is_empty() and at - int(list[-1]) < Hints.SAME_GAP_MS:
			fail("same within 60 s", "%s at %d and %d" % [m, list[-1], at])
		list.append(at)
		starts[m] = list
		var pri := Hints.priority(m)
		var lasts := _last_heard_start(m, at)
		if lasts >= 0 and at - lasts < (Hints.URGENT_GAP_MS if pri >= Hints.URGENT else Hints.ANY_GAP_MS):
			fail("spacing", "%s at %d, %d ms after the last hint" % [m, at, at - lasts])

	## The latest start of any hint before this one that was not cut.
	func _last_heard_start(m: String, at: int) -> int:
		var best := -1
		for k: String in starts:
			for s: int in starts[k]:
				if s < at:
					best = maxi(best, s)
		return best

	## Waits `ms`, stepping the clock.
	func wait(ms: int) -> void:
		var end := now + ms
		while now < end:
			step()

	## A Playroom count: "Hide.", 6 s, "Coming, ready or not!", the numbers, "All done!".
	func run_count(length: int, last: bool) -> void:
		counted["playroom_counts"] += 1
		count = {"phase": "hide", "left": Hints.HIDE_TIME, "len": length, "last": last}
		a.count_ctx = count
		say("hide", "HIDE.", 2200)
		var t0 := now
		while now < t0 + int(Hints.HIDE_TIME * 1000.0):
			count["left"] = Hints.HIDE_TIME - (now - t0) / 1000.0
			_maybe_noise()
			step()
		count = {"phase": "seek", "left": float(length), "len": length, "last": last}
		a.count_ctx = count
		say("search", "COMING, READY OR NOT!", 2000)
		var ts := now
		var said := {}
		while now < ts + length * 1000:
			var left := float(length) - (now - ts) / 1000.0
			count["left"] = left
			var i := int(floorf((now - ts) / 1000.0))
			var num := length - i
			if not said.has(num) and i >= int(Hints.COMING_TIME) and Hints.NUMBERS.has(num):
				said[num] = true
				say("number", "%d." % num, 950, num, length)
			_maybe_noise()
			step()
		count = {}
		a.count_ctx = count
		say("done", "ALL DONE!", 2200)

	## Something else happening now and then: a cue hint, an event, a found line.
	func _maybe_noise() -> void:
		var r := rng.next()
		if r < 0.006:
			ask(CUES[rng.int_in(0, CUES.size() - 1)])
		elif r < 0.009:
			events([{"type": rng.pick(["caught", "startedHunting", "callRefused", "out", "downed"]), "playerId": rng.pick(["ann", "bo"])}])
		elif r < 0.0105 and place == "playroom" and not count.is_empty():
			say("found", "FOUND YOU, BO!", 2200)

	## One floor at `depth` on `pl`.
	func floor_at(depth: int, pl: String) -> void:
		place = pl
		a.place = pl
		events([{"type": "rodeDown", "depth": depth}])
		reset_cap("floor")
		reset_cap("count")
		wait(1000)
		var t := now
		events([{"type": "doorsOpened", "reason": "arrival", "depth": depth}])
		_check_replace(t, ["hint_play_arrive", "hint_new_floor", "hint_reroll"], "doors", depth > 1)
		_check_logs()
		var len_ms := rng.int_in(40, 200) * 1000
		var end := now + len_ms
		var counts := 0
		while now < end:
			var r := rng.next()
			if pl == "playroom" and counts < 3 and r < 0.004:
				counts += 1
				reset_cap("count")
				run_count(rng.pick([30, 35, 40, 45]), counts == 3)
				continue
			if r < 0.01:
				ask(CUES[rng.int_in(0, CUES.size() - 1)])
			elif r < 0.016:
				var ty: String = rng.pick(["callRefused", "caught", "downed", "out", "startedHunting", "markPlaced", "quotaMet", "called", "blinkStart", "voteChanged", "carLeft", "bed"])
				var e := {"type": ty, "playerId": rng.pick(["ann", "bo", "cy"]), "blackout": rng.next() < 0.5, "side": rng.pick([null, "bank", "down"]),
					"reason": rng.pick(["unloaded", "empty", "ride"]), "inBed": false}
				events([e])
			elif r < 0.0172 and pl == "playroom":
				# Outside a count the Minder grabs someone.
				grab()
			elif r < 0.018:
				var bt := now
				var was_dark: bool = a.blackout_on
				events([{"type": "carArrived"}])
				if not was_dark:
					_check_replace(bt, ["hint_board"], "arrived", true)
				_check_logs()
			step()

	## "Replaces": at the event at `t`, exactly one of the hints and the replaced line was asked for.
	func _check_replace(t: int, hints: Array, line: String, expected: bool) -> void:
		if not expected:
			return
		var n := 0
		for e: Dictionary in a.hint_log:
			if int(e["at"]) == t and str(e["what"]) == "requested" and hints.has(str(e["moment"])):
				n += 1
		for r: Dictionary in a.request_log:
			if int(r["at"]) == t and str(r["moment"]) == line:
				n += 1
		counted["replaces"] += 1
		if n != 1:
			fail("replaces", "at %d: %d of %s / %s asked for" % [t, n, str(hints), line])

	## A night: days of floors, then home.
	func play(days: int) -> void:
		a.start_run(true, "night-%d" % rng.int_in(0, 1 << 30))
		for cap: String in CAPS:
			reset_cap(cap)
		for d in days:
			if d > 0:
				a.start_run(false)
				reset_cap("day")
				reset_cap("floor")
				reset_cap("count")
			var floors := rng.int_in(1, 6)
			for f in floors:
				var depth := f + 1
				var pl: String = "clinic" if depth < 3 else rng.pick(PLACES)
				floor_at(depth, pl)
			# Home.
			place = "prison"
			a.place = "prison"
			events([{"type": "rodeUp", "depth": 0}])
			reset_cap("floor")
			reset_cap("count")
			wait(1000)
			events([{"type": "doorsOpened", "reason": "arrival", "depth": 0}])
			wait(40000)

func _nights(t: T, n: int, label: String) -> Dictionary:
	var totals := {}
	var bad := {}
	for i in n:
		var night := Night.new()
		night.rng = Rng.make_rng("%s-%d" % [label, i])
		night.a = _make("%s-%d" % [label, i])
		night.play(night.rng.int_in(1, 3))
		for k: String in night.counted:
			totals[k] = int(totals.get(k, 0)) + int(night.counted[k])
		for rule: String in night.bad:
			if not bad.has(rule):
				bad[rule] = night.bad[rule]
		night.a.free()
	for rule: String in bad:
		t.check(false, "%s: %s" % [rule, "; ".join(PackedStringArray(bad[rule]))])
	return totals

func test_nights(t: T) -> void:
	var n := 20 if t.quick else 200
	var totals := _nights(t, n, "hints")
	t.note("%d nights: %d hints started, %d expired, %d cut, %d replace checks, %d Playroom counts, %d grabs" % [n, totals.started, totals.expired, totals.cut, totals.replaces, totals.playroom_counts, totals.grabs])
	t.check(int(totals.grabs) > 0, "no grab in the nights: the grab line is untested")
	# Not vacuous: hints play, some expire, some are cut, the Playroom counts run.
	t.check(int(totals.started) > n, "too few hints started (%d)" % totals.started)
	t.check(int(totals.expired) > 0, "no hint ever expired: the expiry rule is untested")
	t.check(int(totals.replaces) > n, "too few replace checks (%d)" % totals.replaces)

## The deliberate breaks (AH1): each one turns its check red.
func test_breaks(t: T) -> void:
	for brk: Array in [["heard_on_request", "expired or cut is not heard"], ["no_same_gap", "same within 60 s"]]:
		Hints.test_break = brk[0]
		var probe := T.new()
		_nights(probe, 20, "break-" + str(brk[0]))
		Hints.test_break = ""
		var red := false
		for f: String in probe.failures:
			if f.begins_with(str(brk[1])):
				red = true
		t.check(red, "the break %s did not turn \"%s\" red (failures: %s)" % [brk[0], brk[1], "; ".join(probe.failures)])

# ---- the table, the words, the gate's small rules -----------------------------------------------

func test_table_matches_recordings(t: T) -> void:
	var m := _load_manifest()
	t.check(not m.is_empty(), "no manifest")
	var by_moment := {}
	for l: Dictionary in m.get("lines", []):
		if not by_moment.has(l.moment):
			by_moment[l.moment] = []
		by_moment[l.moment].append(l)
	var wired := 0
	for id: String in Hints.TABLE:
		var ls: Array = by_moment.get(id, [])
		t.eq(ls.size(), 2, "%s: lines recorded (A and B)" % id)
		t.eq(int(m.moments.get(id, {}).get("priority", -1)), Hints.priority(id), "%s: priority in the manifest" % id)
		var row: Dictionary = Hints.TABLE[id]
		t.check(bool(row.get("wired", false)) != row.has("waits"), "%s: either wired or waits for a named piece" % id)
		if bool(row.get("wired", false)):
			wired += 1
	for mo: String in by_moment:
		if mo.begins_with("hint_"):
			t.check(Hints.TABLE.has(mo), "%s recorded but not in the table" % mo)
	t.eq(Hints.TABLE.size(), 38, "hints in the table")
	t.note("%d of %d hints wired" % [wired, Hints.TABLE.size()])

func test_words(t: T) -> void:
	for l: Dictionary in _load_manifest().get("lines", []):
		# The hints, and the grab's lines (they must not say the Minder's rule either: C2).
		if not str(l.moment).begins_with("hint_") and str(l.moment) != "grab":
			continue
		var plain := str(l.plain)
		var words := plain.split(" ", false)
		t.check(words.size() <= 20, "%s: %d words" % [l.id, words.size()])
		var low := " " + plain.to_lower() + " "
		for w: String in Hints.TRAIT_WORDS + Hints.BODY_WORDS:
			var re := RegEx.create_from_string("[^a-z]" + w + "[^a-z]")
			t.check(re.search(low) == null, "%s names \"%s\": %s" % [l.id, w, plain])

func test_number_in(t: T) -> void:
	# A 30 s count: the first number said is twenty, 10 s into the search.
	t.check(absf(Hints.number_in({"phase": "seek", "left": 30.0, "len": 30}) - 10.0) < 0.001, "seek 30 left: twenty in 10 s")
	t.check(absf(Hints.number_in({"phase": "hide", "left": 4.0, "len": 30}) - 14.0) < 0.001, "hide 4 left: twenty in 14 s")
	t.check(absf(Hints.number_in({"phase": "seek", "left": 12.5, "len": 45}) - 2.5) < 0.001, "seek 12.5 left: ten in 2.5 s")
	t.check(absf(Hints.number_in({"phase": "seek", "left": 44.5, "len": 45}) - 4.5) < 0.001, "45 s count: forty in 4.5 s")
	t.check(is_inf(Hints.number_in({})), "no count: no number")

func test_retire_and_off(t: T) -> void:
	var a := _make("retire")
	for night in 3:
		a.start_run(true, "n%d" % night)
		# The boarding line plays and ends first.
		for i in 150:
			a.clock_ms += 100
			a.update()
		var ok: bool = a.hint("hint_winded")
		if night < 2:
			t.check(ok, "night %d: hint_winded asked for" % night)
			a.clock_ms += 500
			a.update()
			t.eq(str(a.current.get("moment", "")), "hint_winded", "night %d: it starts" % night)
			for i in 100:
				a.clock_ms += 100
				a.update()
		else:
			t.check(not ok, "night 3: hint_winded retired after two nights")
	# Every-time hints never retire.
	t.check(not a.hints.retired("hint_left_you"), "hint_left_you never retires")
	# A save round trip keeps the record.
	var h := Hints.new()
	h.from_save(a.hints.to_save())
	h.night_key = "n9"
	t.check(h.retired("hint_winded"), "the saved record retires it too")
	# HINTS: OFF.
	a.set_hints_on(false)
	a.clock_ms += 120000
	t.check(not a.hint("hint_left_you"), "off: no hint")
	a.set_hints_on(true)
	t.check(a.hint("hint_left_you"), "on again: the hint is asked for")
	a.free()

## The Minder's grab outside a count (T15m): its own three lines, one dealt per grab and never the same twice
## running, the caption the line itself; a count's find still says "Found you"; and hint_listen_1 no longer
## says anything about being alone.
func test_grab_lines(t: T) -> void:
	var m := _load_manifest()
	var grabs: Array = (m.get("lines", []) as Array).filter(func(l: Dictionary) -> bool: return str(l.moment) == "grab")
	t.eq(grabs.size(), 3, "grab lines recorded")
	t.check(int(m.moments.get("grab", {}).get("priority", -1)) >= 4, "the grab's priority in the manifest")
	var a := _make("grab")
	a.start_run(true, "g")
	a.place = "playroom"
	var seen := {}
	var last := ""
	var n := 60 if t.quick else 600
	for i in n:
		a.clock_ms += 3000
		var id: String = a.say_grab(2200)
		var said: Dictionary = a.said_count[-1]
		t.check(id.begins_with("grab_"), "grab %d dealt %s" % [i, id])
		t.check(id != last, "grab %d: %s twice running" % [i, id])
		t.check(str(said["id"]) == id and str(said["text"]) == str(a.lines[id].plain), "grab %d: said %s, the caption \"%s\"" % [i, said["id"], said["text"]])
		t.check(not str(said["text"]).to_upper().begins_with("FOUND YOU"), "grab %d says Found you" % i)
		last = id
		seen[id] = true
	t.eq(seen.size(), 3, "every grab line dealt over %d grabs" % n)
	# A count's find is still "Found you!".
	a.say_count("found", "FOUND YOU, BO!", 2200)
	t.eq(str(a.said_count[-1]["id"]), "count_found_1", "a count's find says Found you")
	a.free()
	for l: Dictionary in m.get("lines", []):
		if str(l.id) == "hint_listen_1":
			t.check(not str(l.plain).to_lower().contains("alone"), "hint_listen_1 no longer says alone: %s" % l.plain)

func test_place_lines(t: T) -> void:
	var a := _make("places")
	a.start_run(true, "p")
	for pl: String in ["clinic", "annex", "playroom", "prison"]:
		a.place = pl
		for i in 40:
			var d: String = a._deal("doors")
			var ar: String = a._deal("arrived")
			var bl: String = a._deal("blackout")
			var sl: String = a._deal("slip")
			t.check(d != "doors_1" or pl == "clinic", "doors_1 dealt on %s" % pl)
			t.check(sl != "slip_2" or pl == "clinic", "slip_2 dealt on %s" % pl)
			t.check(not (pl == "playroom" and (ar == "arrived_5" or bl == "blackout_3")), "%s / %s dealt on the Playroom" % [ar, bl])
	a.place = "clinic"
	var seen := {}
	for i in 40:
		seen[a._deal("doors")] = true
	t.check(seen.has("doors_1"), "doors_1 still dealt on the Clinic")
	a.free()


func test_playroom_search_preserves_the_timed_voice_and_caption(t: T) -> void:
	var a := _make("search voice")
	a.place = "playroom"
	a.count_ctx = {"phase":"hide", "left":1.0, "len":30, "last":false}
	a.request("quota", 9000, "FLOOR RECORDED 1200 OF 1200. CALL READY.", "quota_1")
	a.update()
	a.playroom_call_ready = true
	a.say_count("number", "1.", 850, 1, 30)
	a.clock_ms = 400
	a.say_count("search", "COMING, READY OR NOT!", 2000)
	a.count_ctx.phase = "seek"
	t.check(a._busy("count") and not a._busy("main") and not a._busy("number"), "only the search line speaks at the handoff")
	t.eq(a.shown(), "COMING, READY OR NOT!", "the caption follows the protected search cue")
	a.request("called")
	a.say_count("search", "DUPLICATE", 2000)
	a.say_count("number", "STALE NUMBER", 850, 1, 30)
	t.eq(a.shown(), "COMING, READY OR NOT!", "duplicate search and stale number do not replace the caption")
	t.eq(a.said_count.size(), 2, "search presents once")
	a.clock_ms = 2100
	a.update()
	t.check(not a._busy("main"), "company stays silent through the cue caption")
	a.clock_ms = 2450
	a.update()
	t.eq(str(a.current.get("id", "")), "quota_1", "the still-actionable quota announcement returns once")
	t.check(a.shown().contains("FLOOR RECORDED 1200 OF 1200. CALL READY."), "the deferred quota keeps its matching caption")
	a.playroom_call_ready = false
	a.clock_ms = 2510
	a.update()
	t.check(not a._busy("main"), "a call makes the deferred quota immediately stop")
	a.clock_ms = 5500
	a.update()
	t.check(a.history.filter(func(h: Dictionary) -> bool: return h.moment == "quota").size() == 2, "the original plus exactly one valid replay")
	t.check(a.history.all(func(h: Dictionary) -> bool: return h.moment != "called"), "a transient called line is not replayed after the handoff")
	a.free()


func test_playroom_search_drops_stale_quota_and_keeps_catch_cue(t: T) -> void:
	for stale: String in ["called", "next phase", "next floor", "expired"]:
		var a := _make("search stale " + stale)
		a.place = "playroom"
		a.playroom_call_ready = true
		a.count_ctx = {"phase":"seek", "left":30.0, "len":30, "last":false}
		a.say_count("search", "COMING, READY OR NOT!", 2000)
		a.request("quota", 1000 if stale == "expired" else 9000, "", "quota_1")
		a.clock_ms = 900
		a.say_count("found", "FOUND YOU, ANN!", 2000)
		a.update()
		t.eq(a.shown(), "COMING, READY OR NOT!", "%s cannot replace the search cue with a catch caption" % stale)
		match stale:
			"called": a.playroom_call_ready = false
			"next phase": a.count_ctx.phase = "over"
			"next floor":
				a.on_events([{"type":"rodeDown"}])
				a.place = "clinic"
		a.clock_ms = 2100
		a.update()
		if stale != "next floor":
			t.eq(a.shown(), "FOUND YOU, ANN!", "%s does not suppress the deferred catch line" % stale)
		else:
			t.check(not a._busy("count"), "changing floors drops unplayed Playroom followups")
		a.clock_ms = 4800
		a.update()
		t.check(a.history.all(func(h: Dictionary) -> bool: return h.moment != "quota"), "%s cannot replay a stale quota prompt" % stale)
		a.place = "playroom"
		a.clock_ms = 7000
		a.say_count("search", "NEXT SEARCH", 2000)
		t.eq(a.shown(), "NEXT SEARCH", "a later count can reserve a new window")
		a.free()


func test_playroom_search_control_keeps_other_voice_paths(t: T) -> void:
	var a := _make("search off floor")
	a.place = "clinic"
	a.request("blackout")
	a.update()
	a.say_count("search", "TEST COUNT", 2000)
	t.check(not a.current.is_empty() and a._busy("main"), "the Playroom gate does not cut other floors' lines")
	a.free()
	a = _make("playroom catch outside handoff")
	a.place = "playroom"
	a.say_count("found", "FOUND YOU, ANN!", 2000)
	t.check(a._busy("count") and a.shown() == "FOUND YOU, ANN!", "catch speech outside the search handoff is immediate")
	a.free()
