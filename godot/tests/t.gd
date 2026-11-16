# What a test gets: checks that collect failures, and notes printed under the test's line.
extends RefCounted

var failures := PackedStringArray()
var notes := PackedStringArray()
## Long runs (the full-size property tests) only when asked: see run_tests.gd.
var full := false

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
