# A trace of a scene, tick by tick (the format of dump_reference.ts Recorder): per tick two digests
# of the whole state (`full`, and `exact` with the pay fields masked), every event in order, the
# full state every `every` ticks and at the last, and per-tick extra values. While godot:golden
# records, it builds that record; otherwise it compares every tick with the golden record as it
# goes. Every comparison is exact: `full` must match on every tick.
extends RefCounted

const T = preload("res://tests/t.gd")
const Snap = preload("res://tests/snap.gd")
const Golden = preload("res://tests/golden.gd")

var want: Variant
var name: String
var every: int
var recording: bool
var ticks := 0
var exact_first := -1
var exact_bad := 0
var full_first := -1
var full_bad := 0
var events: Array = []
var extra: Array = []
var snap_diff := Snap.Diff.new()
# Recording.
var _exact := PackedStringArray()
var _full := PackedStringArray()
var _snaps := {}
var _last: Variant = null

## `want_`: this scene's golden record (null while recording, or when the golden has none).
func _init(name_: String, every_: int, want_: Variant) -> void:
	name = name_
	every = every_
	want = want_
	recording = Golden.recording

func tick(state: Variant, tick_events: Array, extra_values: Variant = null) -> void:
	var k := ticks
	ticks += 1
	var f := Snap.digest(state, false)
	if recording:
		_full.append(f)
		_exact.append(Snap.digest(state, true))
		if k % every == 0:
			_snaps[str(k)] = state
		_last = state
	elif want is Dictionary:
		var wf: String = want["full"]
		if k * 8 >= wf.length() or f != wf.substr(k * 8, 8):
			full_bad += 1
			if full_first < 0:
				full_first = k
			# Whether the state outside the pay differs too (the masked digest).
			var we: String = want["exact"]
			var e := Snap.digest(state, true)
			if k * 8 >= we.length() or e != we.substr(k * 8, 8):
				exact_bad += 1
				if exact_first < 0:
					exact_first = k
		var snaps: Dictionary = want["snaps"]
		if snaps.has(str(k)):
			snap_diff.add(Snap.compare(state, snaps[str(k)], "%s@%d" % [name, k]))
	for ev: Variant in tick_events:
		events.append([k, Snap.plain(ev)])
	if extra_values != null:
		extra.append(extra_values)

## The golden record of this trace (recording).
func to_golden() -> Dictionary:
	var snaps := _snaps.duplicate()
	if ticks > 0:
		snaps[str(ticks - 1)] = _last
	return {"name": name, "ticks": ticks, "exact": "".join(_exact), "full": "".join(_full), "snaps": snaps, "events": events, "extra": extra}

## Checks everything against the golden record (nothing while recording) and returns the diff of
## the values compared one by one (events, snapshots, per-tick values).
func finish(t: T) -> Snap.Diff:
	var total := Snap.Diff.new()
	if recording:
		return total
	if not (want is Dictionary):
		t.check(false, "%s: no golden record of this scene (run npm run godot:golden)" % name)
		return total
	t.eq(name, String(want["name"]), "scene name")
	t.eq(ticks, int(want["ticks"]), "%s: ticks" % name)
	t.check(full_bad == 0, "%s: state differs from the golden from tick %d (%d ticks differ; %s)" % [name, full_first, full_bad, first_difference()])
	var ed := Snap.compare(events, want["events"], "%s.events" % name)
	t.check(ed.ok(), "%s: events: %s" % [name, ed.summary()])
	total.add(ed)
	t.check(snap_diff.ok(), "%s: snapshots: %s" % [name, snap_diff.summary()])
	total.add(snap_diff)
	var wx: Array = want.get("extra", [])
	if not wx.is_empty() or not extra.is_empty():
		var xd := Snap.compare(extra, wx, "%s.extra" % name)
		t.check(xd.ok(), "%s: per-tick values: %s" % [name, xd.summary()])
		total.add(xd)
	return total

## When the state first differed from the golden: "never", or the tick, and whether outside the pay.
func first_difference() -> String:
	if recording:
		return "recorded"
	if full_first < 0:
		return "never"
	if exact_first < 0:
		return "from tick %d, in the pay fields only" % full_first
	return "from tick %d (outside the pay from tick %d)" % [full_first, exact_first]

## Records the traces at `path` of golden `file` (recording), or checks each against its golden
## record and the number of scenes. Returns the summed diff.
static func finish_all(t: T, file: String, path: String, traces: Array, wants: Variant) -> Snap.Diff:
	var total := Snap.Diff.new()
	if Golden.recording:
		var out: Array = []
		for tr: Variant in traces:
			out.append(tr.to_golden())
		Golden.put(file, path, out)
		return total
	t.eq(traces.size(), (wants as Array).size() if wants is Array else -1, "%s %s: scenes" % [file, path])
	for tr: Variant in traces:
		total.add(tr.finish(t))
	return total
