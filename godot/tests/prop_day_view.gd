# The day quota on screen and in voice (FD3; docs/floors/findables-and-day.md section 1, "Where it is shown"
# and "The lines"), headless. The two-client check over a lossy link (every frame's HUD line, monitor rows
# and BANK paint against the host's own block at the same tick) is tests/prop_day_net.gd's lock session.
#   1. client/day_view.gd: the HUD's corner line ("DAY 1650/2400", "... MET" once met), the monitor's rows
#      (sim/day.gd monitor_rows from the block's numbers; the third only while boarding), LOCKED exactly
#      when the host says locked, CLOSED UNTIL MORNING at home once the car is shut; nothing without the lock.
#   2. The lift (client/lift.gd) as built: the day monitor shows the rows; the BANK paint reads LOCKED on
#      every sampled block the host says is locked, and never otherwise.
#   3. The announcer (fake clock, no audio): each refused vote plays one bank_refused line with its caption
#      EARNED N OF Q, never the same line twice running, in place of that bell's ride line; dayMet plays a
#      day_met line with its caption; hint_day stands in for the night's first ride line.
#   4. The prison's boards: a wipe after the quota was met never reads "SHORT BY 0"; the day board gives
#      today's result, tomorrow's quota and the misses.
#   5. The recordings: every bank_refused and day_met line is in the manifest, in both shipped voices.
extends RefCounted

const T = preload("res://tests/t.gd")
const Rng = preload("res://sim/rng.gd")
const Day = preload("res://sim/day.gd")
const Run = preload("res://sim/run.gd")
const Clinic = preload("res://sim/clinic.gd")
const DayView = preload("res://client/day_view.gd")
const LiftScript = preload("res://client/lift.gd")
const LevelScript = preload("res://client/level.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const AnnouncerScript = preload("res://client/announcer.gd")
const PrisonView = preload("res://client/prison_view.gd")

static func block(day: int, earned: int, quota: int, aboard: int, each: int, stakes := "IF NOBODY COMES BACK: NOTHING TO TAKE. MISS 1 OF 3.") -> Dictionary:
	return {"index": day, "day": day, "quota": quota, "streak": 0, "misses": 0, "inBed": [], "countFrom": null, "lightsOutAt": null,
		"result": null, "crew": 2, "earned": earned, "locked": earned < quota, "aboard": aboard, "each": each, "stakes": stakes}

static func frame(d: Variant, depth: int, phase: String, up := false) -> Dictionary:
	return {"day": d, "depth": depth, "phase": phase, "goingUp": up, "events": []}

func test_the_hud_line_and_the_monitor_rows_are_the_hosts_numbers(t: T) -> void:
	var v := DayView.new()
	v.update(frame(block(2, 1650, 2400, 900, 450), 1, "away"))
	t.eq(v.hud_line, "DAY 1650/2400", "the corner line while owed")
	t.check(not v.met and v.locked, "owed: not met, BANK locked")
	t.eq(v.rows, PackedStringArray(["DAY 2. EARNED 1650 OF 2400.", "BANK LOCKED. 750 TO GO."]), "two rows off boarding")
	v.update(frame(block(2, 2610, 2400, 2380, 595), 3, "boarding"))
	t.eq(v.hud_line, "DAY 2610/2400 MET", "met: amber, MET")
	t.check(v.met and not v.locked, "met: BANK open")
	t.eq(v.rows, PackedStringArray(["DAY 2. EARNED 2610 OF 2400.", "BANK OPEN. ABOARD 2380. EACH GETS 595.", "IF NOBODY COMES BACK: NOTHING TO TAKE. MISS 1 OF 3."]), "three rows while boarding")
	v.update(frame(block(2, 2610, 2400, 0, 0), 0, "night"))
	t.check(v.hud_line == "" and v.rows.is_empty() and v.closed == DayView.CLOSED_TEXT, "home for the night: no line, no rows, CLOSED UNTIL MORNING")
	v.update(frame(block(2, 2610, 2400, 0, 0), 0, "unloading"))
	t.eq(v.closed, "", "home, the doors still open: not yet closed")
	v.update(frame(block(2, 2610, 2400, 0, 0), 4, "riding", true))
	t.eq(v.hud_line, "DAY 2610/2400 MET", "riding up: still the day's line")
	# Without the lock (no earned in the block, or no block at all): nothing.
	var plain := block(1, 0, 600, 0, 0)
	plain.erase("earned")
	v.update(frame(plain, 1, "boarding"))
	t.check(v.hud_line == "" and v.rows.is_empty() and not v.locked and v.closed == "", "a day block without the lock shows nothing")
	v.update(frame(null, 1, "boarding"))
	t.check(v.hud_line == "" and v.rows.is_empty(), "no day block shows nothing")
	# Random blocks against the rules' own rows.
	var rng := Rng.make_rng("day-view")
	for i in (300 if t.quick else 2000):
		var q := rng.int_in(1, 9000)
		var e := q + rng.int_in(-q, q)
		var a := rng.int_in(0, 6000)
		var b := block(rng.int_in(1, 9), e, q, a, a / 3)
		var boarding := rng.chance(0.5)
		v.update(frame(b, rng.int_in(1, 6), "boarding" if boarding else "away"))
		var want := Day.monitor_rows(int(b["day"]), e, q, a, a / 3, str(b["stakes"]))
		if not boarding:
			want = want.slice(0, 2)
		t.eq(v.rows, want, "case %d: the monitor rows are sim/day.gd's from the host's numbers" % i)
		t.eq(v.locked, e < q, "case %d: locked exactly when the host says" % i)
		t.eq(v.hud_line, "DAY %d/%d%s" % [e, q, "" if e < q else " MET"], "case %d: the corner line" % i)

func test_the_lift_monitor_and_the_bank_paint(t: T) -> void:
	var p := Clinic.generate_clinic("day-lift", 1)
	var c := Run.car_geometry(p)
	var lv: Node3D = LevelScript.new()
	lv.set("props_on", false)
	lv.call("build", PlanDump.dump(p, c), "day-lift")
	var lift: Node3D = LiftScript.new()
	lift.call("build", PlanDump.car_plain(c), lv.call("lift_left_wall"))
	var v := DayView.new()
	var rng := Rng.make_rng("day-paint")
	var locked_n := 0
	for i in 400:
		var q := rng.int_in(100, 3000)
		var b := block(1, rng.int_in(0, 2 * q), q, rng.int_in(0, 3000), 0)
		var phase := "boarding" if rng.chance(0.5) else "unloading"
		v.update(frame(b, 1, phase))
		lift.call("show_day", v.rows)
		lift.call("set_bank_locked", v.locked)
		if bool(b["locked"]):
			locked_n += 1
		t.eq(bool(lift.get("bank_locked")), bool(b["locked"]), "sample %d: the BANK paint reads LOCKED exactly when the host says locked" % i)
		t.eq(Array(lift.get("day_rows")), Array(v.rows), "sample %d: the monitor shows the rows" % i)
		# Readable from the car: no line longer than DAY_COLS, rows 1 and 2 shown whole (wrapped), row 3 a window of it.
		var lines: PackedStringArray = lift.call("day_lines")
		var first := v.rows.slice(0, 2)
		var whole := PackedStringArray()
		for k in lines.size():
			t.check(lines[k].length() <= LiftScript.DAY_COLS, "sample %d: line %d is %d characters" % [i, k, lines[k].length()])
			if k < lines.size() - (1 if v.rows.size() > 2 else 0):
				whole.append(lines[k])
		t.eq(" ".join(whole), " ".join(first), "sample %d: rows 1 and 2 are on the monitor whole" % i)
		if v.rows.size() > 2:
			t.check((v.rows[2] + "    " + v.rows[2]).contains(lines[lines.size() - 1]), "sample %d: the last line is a window of row 3" % i)
	t.check(locked_n > 50 and locked_n < 350, "not vacuous: %d of 400 locked" % locked_n)
	var d: Dictionary = lift.call("drawn_car")
	t.check((d["bank"] as AABB).size.x > 1.5, "the BANK half is still drawn its full width")
	lift.free()
	lv.free()

func _announcer(seed_text: String) -> Node:
	var a: Node = AnnouncerScript.new()
	a.fake = true
	a.persist = false
	a.clock_ms = 0
	a.my_id = "ann"
	a.days_on = true
	a.day_lock_on = true
	a._rng.seed = hash(seed_text)
	var m: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://assets/voice/manifest.json"))
	a.use_manifest(m if m is Dictionary else {})
	return a

## Runs the fake announcer until it is quiet; returns the history entries started since `from`.
static func _drain(a: Node, from: int) -> Array:
	for _k in 400:
		a.clock_ms = int(a.clock_ms) + 100
		a.update()
	return (a.history as Array).slice(from)

func test_a_refused_vote_plays_one_bank_refused_line_with_its_caption(t: T) -> void:
	var a := _announcer("refused")
	var last := ""
	var ids := {}
	for i in 24:
		var from: int = (a.history as Array).size()
		var earned := 300 + 37 * i
		a.on_events([{"type": "bell", "t": 1.0, "bank": 2, "down": 0, "outcome": "ride", "refused": true},
			{"type": "bankRefused", "t": 1.0, "bank": 2, "down": 0, "day": 1, "earned": earned, "quota": 1800},
			{"type": "doorsClosed", "t": 1.0, "aboard": ["ann"], "pushedOut": {}},
			{"type": "carLeft", "t": 1.0, "reason": "ride"}], 1)
		var caption := ""
		var said: Array = []
		for _k in 400:
			a.clock_ms = int(a.clock_ms) + 100
			a.update()
			if str(a.subtitle).contains("EARNED"):
				caption = str(a.subtitle)
		said = (a.history as Array).slice(from)
		var refused_n := 0
		var ride_n := 0
		for h: Dictionary in said:
			if str(h.moment) == "bank_refused":
				refused_n += 1
				t.check(str(h.id) != last, "refusal %d: %s twice running" % [i, h.id])
				last = str(h.id)
				ids[last] = true
			elif str(h.moment) == "ride" or str(h.moment) == "hint_day":
				ride_n += 1
		t.eq(refused_n, 1, "refusal %d: one bank_refused line" % i)
		t.eq(ride_n, 0, "refusal %d: no ride line over it" % i)
		t.check(caption.ends_with("\nEARNED %d OF 1800" % earned), "refusal %d: the caption carries the fact: %s" % [i, caption.replace("\n", " / ")])
	t.check(ids.size() >= 6, "the lines are dealt round: %d different over 24 refusals" % ids.size())
	a.free()

func test_day_met_and_the_first_ride(t: T) -> void:
	var a := _announcer("met")
	a.start_run(true, "night-1")
	_drain(a, 0)
	var from: int = (a.history as Array).size()
	a.on_events([{"type": "carLeft", "t": 5.0, "reason": "ride"}], 1)
	var first := _drain(a, from)
	t.check(first.size() == 1 and str((first[0] as Dictionary).moment) == "hint_day", "the night's first ride: hint_day in place of the ride line: %s" % str(first))
	from = (a.history as Array).size()
	a.clock_ms = int(a.clock_ms) + 70000
	a.on_events([{"type": "carLeft", "t": 90.0, "reason": "ride"}], 1)
	var second := _drain(a, from)
	t.check(second.size() == 1 and str((second[0] as Dictionary).moment) == "ride", "the second ride: the ride line: %s" % str(second))
	from = (a.history as Array).size()
	a.on_events([{"type": "dayMet", "t": 95.0, "day": 1, "earned": 1810, "quota": 1800}], 1)
	var caption := ""
	for _k in 200:
		a.clock_ms = int(a.clock_ms) + 100
		a.update()
		if str(a.subtitle).contains("EARNED"):
			caption = str(a.subtitle)
	var met := (a.history as Array).slice(from)
	t.check(met.size() == 1 and str((met[0] as Dictionary).moment) == "day_met", "dayMet: a day_met line: %s" % str(met))
	t.check(caption.ends_with("\nEARNED 1810 OF 1800"), "its caption: %s" % caption.replace("\n", " / "))
	# The floor's quota met in the same tick: the day_met line stands in for the quota line.
	var c := _announcer("met-and-quota")
	c.on_events([{"type": "quotaMet", "t": 9.0, "depth": 2, "earned": 1700, "needed": 1160, "top": "ann"},
		{"type": "dayMet", "t": 9.0, "day": 1, "earned": 1700, "quota": 1200}], 1)
	var both := _drain(c, 0)
	t.check(both.size() == 1 and str((both[0] as Dictionary).moment) == "day_met", "quotaMet and dayMet together: one day_met line, no quota line: %s" % str(both))
	c.free()
	# Without the lock the first ride is the ride line, as before.
	var b := _announcer("nolock")
	b.day_lock_on = false
	b.start_run(true, "night-2")
	_drain(b, 0)
	from = (b.history as Array).size()
	b.on_events([{"type": "carLeft", "t": 5.0, "reason": "ride"}], 1)
	var plain := _drain(b, from)
	t.check(plain.size() == 1 and str((plain[0] as Dictionary).moment) == "ride", "no lock: the ride line: %s" % str(plain))
	a.free()
	b.free()

func test_the_prison_boards_word_a_wipe_and_the_day(t: T) -> void:
	var wipe := {"kind": "missed", "day": 3, "quota": 2400, "banked": 0, "earned": 2600, "wiped": true, "short_by": 0, "streak": 0,
		"misses": 1, "misses_left": 2, "odds": "nothing to take", "taken": [], "shares": {"a": 0}, "credits": {"a": 10}, "next_quota": 2400}
	var lines := PrisonView.report_text(wipe, {"a": "Ann"})
	t.eq(lines[0], "DAY 3  NOBODY CAME BACK", "the verdict of a wipe")
	for l in lines:
		t.check(not l.begins_with("SHORT"), "a wipe after the quota was met never says %s" % l)
	t.check(lines.has("EARNED 2600: NOTHING CAME BACK"), "what was earned, and that nothing came back: %s" % str(lines))
	var short := wipe.duplicate()
	short["wiped"] = false
	short["earned"] = 300
	short["short_by"] = 2100
	t.check(PrisonView.report_text(short, {}).has("SHORT BY 2100"), "a short BANK (a run without the lock) still says SHORT BY")
	var day := block(3, 2600, 2400, 0, 0)
	day["result"] = wipe
	t.eq(PrisonView.day_text(day, "IN BED 0 OF 2"), ["DAY 3", "TODAY NOBODY CAME BACK", "TOMORROW OWES 2400", "MISSES 1 OF 3", "IN BED 0 OF 2"] as Array[String], "the day board")
	var made := wipe.duplicate()
	made["kind"] = "made"
	made["wiped"] = false
	made["misses"] = 0
	made["next_quota"] = 3000
	day["result"] = made
	t.eq(PrisonView.day_text(day, ""), ["DAY 3", "TODAY MADE", "TOMORROW OWES 3000", "MISSES 0 OF 3"] as Array[String], "the day board after a made day")

func test_the_day_lines_are_recorded_in_both_voices(t: T) -> void:
	var m: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://assets/voice/manifest.json"))
	if not t.check(m is Dictionary, "the manifest loads"):
		return
	var ids := {}
	for l: Dictionary in (m as Dictionary)["lines"]:
		ids[str(l["id"])] = l
	for id: String in ["bank_refused_1", "bank_refused_2", "bank_refused_3", "bank_refused_4", "bank_refused_5", "bank_refused_6", "bank_refused_7", "bank_refused_8", "day_met_1", "day_met_2", "day_met_3"]:
		t.check(ids.has(id), "%s is in the manifest" % id)
		t.check(ResourceLoader.exists("res://assets/voice/bella/%s.mp3" % id), "%s is in the game (Bella)" % id)
		if ids.has(id):
			t.check(not str(ids[id]["plain"]).contains("0") and not str(ids[id]["plain"]).contains("1"), "%s carries no numbers" % id)
	t.check((m as Dictionary)["moments"].has("bank_refused") and (m as Dictionary)["moments"].has("day_met"), "both moments have priorities")
