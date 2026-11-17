# What a test gets: checks that collect failures, and notes printed under the test's line.
extends RefCounted

const Golden = preload("res://tests/golden.gd")
const Snap = preload("res://tests/snap.gd")

var failures := PackedStringArray()
var notes := PackedStringArray()
## Long runs (the full-size property tests) only when asked: see run_tests.gd.
var full := false
## The quick set (--quick): every test, on the first seeds only, sameness still exact; the
## statistical "not vacuous" and fairness thresholds are left to the default and full runs.
var quick := false

## Which sizes of tests/golden/properties.json this run uses.
func size_key() -> String:
	return "full" if full else ("quick" if quick else "sub")

## True while godot:golden records (run_tests.gd --golden): results are stored, not compared.
var recording: bool:
	get:
		return Golden.recording

## Records a failure unless `ok`. Returns `ok`.
func check(ok: bool, message: String) -> bool:
	if not ok:
		failures.append(message)
	return ok

## Exact equality (typeof and value).
func eq(got: Variant, want: Variant, message: String) -> bool:
	return check(typeof(got) == typeof(want) and got == want, "%s: got %s, want %s" % [message, str(got), str(want)])

func note(message: String) -> void:
	notes.append(message)

## The golden value at `path` of `file` (tests/golden/), null while recording.
func golden(file: String, path: String = "") -> Variant:
	return Golden.want(file, path)

## While recording: stores `got` as the golden value at `path` of `file`. Otherwise compares `got`
## with that golden value exactly (every number, string, flag and shape) and records a failure
## naming `what` and the first difference. Returns the comparison (empty while recording).
func expect(file: String, path: String, got: Variant, what: String) -> Snap.Diff:
	if recording:
		Golden.put(file, path, got)
		return Snap.Diff.new()
	var want: Variant = Golden.want(file, path)
	var d := Snap.compare(got, want, what)
	check(d.ok(), "%s differs from the golden (tests/golden/%s %s): %s" % [what, file, path, d.summary()])
	return d
