# Comparing a recorded trace (dump_reference.ts Recorder) tick by tick: both digests every tick,
# every event in order, the full state at the recorded ticks, and per-tick extra values.
extends RefCounted

const T = preload("res://tests/t.gd")
const Snap = preload("res://tests/snap.gd")

var want: Dictionary
var name: String
var ticks := 0
var exact_first := -1
var exact_bad := 0
var full_first := -1
var full_bad := 0
var events: Array = []
var extra: Array = []
var snap_diff := Snap.Diff.new()
var snap_first := ""

func _init(want_: Dictionary) -> void:
	want = want_
	name = want["name"]

func tick(state: Variant, tick_events: Array, extra_values: Variant = null) -> void:
	var k := ticks
	ticks += 1
	var we: String = want["exact"]
	var wf: String = want["full"]
	# If the whole state's text matches, the masked text matches too: only hash it when needed.
	var f := Snap.digest(state, false)
	if k * 8 >= wf.length() or f != wf.substr(k * 8, 8):
		full_bad += 1
		if full_first < 0:
			full_first = k
		var e := Snap.digest(state, true)
		if k * 8 >= we.length() or e != we.substr(k * 8, 8):
			exact_bad += 1
			if exact_first < 0:
				exact_first = k
	for ev: Variant in tick_events:
		events.append([k, Snap.plain(ev)])
	if extra_values != null:
		extra.append(extra_values)
	var snaps: Dictionary = want["snaps"]
	if snaps.has(str(k)):
		var d := Snap.compare(state, snaps[str(k)], "%s@%d" % [name, k])
		snap_diff.add(d)

## Checks everything and adds a note. `pay_may_differ`: the full digest (which includes the
## pay fields that come from pow) may differ, as long as those values are within 1e-9.
func finish(t: T, pay_may_differ: bool = false) -> Snap.Diff:
	var total := Snap.Diff.new()
	t.eq(ticks, int(want["ticks"]), "%s: ticks" % name)
	t.check(exact_bad == 0, "%s: state differs from tick %d (%d ticks differ)" % [name, exact_first, exact_bad])
	if not pay_may_differ:
		t.check(full_bad == 0, "%s: full state differs from tick %d (%d ticks differ)" % [name, full_first, full_bad])
	var ed := Snap.compare(events, want["events"], "%s.events" % name)
	t.check(ed.ok(), "%s: events: %s" % [name, ed.summary()])
	total.add(ed)
	t.check(snap_diff.ok(), "%s: snapshots: %s" % [name, snap_diff.summary()])
	total.add(snap_diff)
	if want.has("extra") and not (want["extra"] as Array).is_empty():
		var xd := Snap.compare(extra, want["extra"], "%s.extra" % name)
		t.check(xd.ok(), "%s: per-tick values: %s" % [name, xd.summary()])
		total.add(xd)
	return total

## When the state first differed: "never", or the tick (state without pay / pay fields).
func first_difference() -> String:
	if exact_first < 0 and full_first < 0:
		return "never"
	if exact_first < 0:
		return "state never, pay last bits from tick %d" % full_first
	return "state from tick %d" % exact_first
