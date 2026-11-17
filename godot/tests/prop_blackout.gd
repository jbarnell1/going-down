# The blackout (ported from tests/sim/blackout.test.ts): 1. the dark schedule over many seeds and
# depths; 2. fairness by simulation with wait bots (tests/waits.gd): a crew that stays at the lift
# loses someone in at least 70% of waits; a crew that flees and comes back loses someone in at most
# 30% and boards at least 80% of the time. Tables must equal the golden tables.
extends RefCounted

const T = preload("res://tests/t.gd")
const Snap = preload("res://tests/snap.gd")
const Waits = preload("res://tests/waits.gd")
const Run = preload("res://sim/run.gd")
const M = preload("res://sim/jsmath.gd")

func test_dark_schedule(t: T) -> void:
	var problems := PackedStringArray()
	var steps := {}
	var false_stops := 0
	var stops_in_blackout := 0
	var same := 0
	for depth: int in [1, 2, 3, 6]:
		for i in 500:
			var p := Run.call_plan("sched-%d" % i, i % 3, -1, depth)
			var tag := "depth %d seed %d" % [depth, i]
			var d := p.darks
			var last := d[d.size() - 1]
			if not last.blackout:
				problems.append("%s: no blackout" % tag)
				continue
			steps[d.size() - 1] = int(steps.get(d.size() - 1, 0)) + 1
			var lo := Run.BLACKOUT_FIRST_MIN if depth == 1 else Run.BLACKOUT_MIN
			var hi := Run.BLACKOUT_FIRST_MAX if depth == 1 else Run.BLACKOUT_MAX
			if last.len < lo - 1e-9 or last.len > hi + 1e-9:
				problems.append("%s: blackout %s s" % [tag, last.len])
			if absf(last.at + last.len - p.wait) > 1e-9:
				problems.append("%s: blackout ends at %s, car at %s" % [tag, last.at + last.len, p.wait])
			if last.warn != Run.BLACKOUT_WARNING:
				problems.append("%s: blackout warning %s" % [tag, last.warn])
			for k in d.size() - 1:
				if d[k].blackout or d[k].warn != Run.BLINK_WARNING:
					problems.append("%s: a blink unlike a blink" % tag)
				if d[k].len != Run.BLINK_LADDER[k]:
					problems.append("%s: blink %d is %s s" % [tag, k, d[k].len])
			for k in range(1, d.size()):
				if d[k].len <= d[k - 1].len:
					problems.append("%s: dark %d not longer" % [tag, k])
			if d[0].at - d[0].warn < Run.BLINK_FIRST_AFTER - 1e-9:
				problems.append("%s: first warning at %s s" % [tag, d[0].at - d[0].warn])
			for k in range(1, d.size()):
				if d[k].at - d[k].warn < d[k - 1].at + d[k - 1].len + 2.9:
					problems.append("%s: dark %d warned too soon after the last" % [tag, k])
			if p.false_stop:
				false_stops += 1
				if p.wait - Run.FLOOR_TIME - p.extra >= last.at - 1e-9:
					stops_in_blackout += 1
			# The same for every player: the same seed and call give the same schedule.
			if Snap.compare(Snap.call_plan(p), Snap.call_plan(Run.call_plan("sched-%d" % i, i % 3, -1, depth))).ok():
				same += 1
	for i in mini(problems.size(), 10):
		t.check(false, problems[i])
	t.check(steps.size() >= 4, "short waits get fewer blinks, long ones more: %s" % str(steps))
	t.check(stops_in_blackout > false_stops * 0.9, "false stops inside the blackout: %d of %d" % [stops_in_blackout, false_stops])
	t.eq(same, 2000, "schedules repeat")
	var keys := steps.keys()
	keys.sort()
	var parts := PackedStringArray()
	for k: int in keys:
		parts.append("\"%d\":%d" % [k, steps[k]])
	t.note("dark schedules: blinks before the blackout {%s}; false stops %d, inside the blackout %d (the TypeScript printed {\"1\":346,\"2\":516,\"3\":678,\"4\":457,\"5\":3}; false stops 440, inside the blackout 440)" % [",".join(parts), false_stops, stops_in_blackout])

## Waits per table cell and size (tools/property_counts.ts QUICK, SUB, FULL waits).
const SIZES := {"quick": 2, "sub": 20, "full": 300}

func test_fairness(t: T) -> void:
	var waits: int = SIZES[t.size_key()]
	var tables: Array = []
	var lines := PackedStringArray()
	for depth: int in [1, 2, 3]:
		for style: StringName in [&"stay", &"flee"]:
			var tb := Waits.wait_table(style, depth, waits)
			tables.append({"style": String(style), "depth": depth, "waits": waits, "lost": tb.lost, "boarded": tb.boarded, "caught": tb.caught,
				"caughtInBlackout": tb.caught_in_blackout, "caughtAfter": tb.caught_after, "chased": tb.chased, "medianFarthest": tb.median_farthest})
			lines.append(Waits.table_line(tb))
			if t.quick:
				pass  # two waits per cell: the shares below are for the default and full runs
			elif style == &"stay":
				t.check(float(tb.lost) / waits >= 0.7, "depth %d: a crew that stays lost someone in only %d of %d" % [depth, tb.lost, waits])
			else:
				t.check(float(tb.lost) / waits <= 0.3, "depth %d: a crew that flees lost someone in %d of %d" % [depth, tb.lost, waits])
				t.check(float(tb.boarded) / waits >= 0.8, "depth %d: a crew that flees boarded only %d of %d" % [depth, tb.boarded, waits])
				t.check(tb.median_farthest > 20.0 and float(tb.chased) / waits > 0.1, "depth %d: a chase, not a walk: %s" % [depth, Waits.table_line(tb)])
	var g: Variant = t.golden("properties.json", "%s.blackout" % t.size_key())
	t.expect("properties.json", "%s.blackout" % t.size_key(), {"waits": waits, "tables": tables, "lines": Array(lines)}, "the tables")
	var wl: Array = g["lines"] if g is Dictionary else []
	for i in lines.size():
		t.note("now:    " + lines[i])
		if i < wl.size() and wl[i] != lines[i]:
			t.note("golden: " + String(wl[i]))
