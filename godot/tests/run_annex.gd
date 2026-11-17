# Runs tests/prop_annex.gd on its own, the way run_tests.gd runs a file, until it is registered there.
#   "$GODOT" --headless --path godot --script res://tests/run_annex.gd            (800 floors)
#   "$GODOT" --headless --path godot --script res://tests/run_annex.gd -- --quick (40 floors)
# One line per test, then `N passed, M failed in S s`. Exit code 0 only if all pass. Any engine or
# script error while a test runs fails that test (copied from run_tests.gd's ErrorCounter).
extends SceneTree

const T = preload("res://tests/t.gd")

class ErrorCounter extends Logger:
	var count := 0
	var first := ""
	var mutex := Mutex.new()

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		mutex.lock()
		count += 1
		if first.is_empty():
			first = "%s (%s:%d %s)" % [rationale if not rationale.is_empty() else code, file, line, function]
		mutex.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	func take() -> String:
		mutex.lock()
		var out := "" if count == 0 else "%d engine/script error(s), first: %s" % [count, first]
		count = 0
		first = ""
		mutex.unlock()
		return out

func _init() -> void:
	var errors := ErrorCounter.new()
	OS.add_logger(errors)
	var args := OS.get_cmdline_user_args()
	var full := args.has("--full")
	var quick := args.has("--quick") and not full
	var passed := 0
	var failed := 0
	var t_start := Time.get_ticks_msec()
	var name := "prop_annex"
	var script: GDScript = load("res://tests/%s.gd" % name)
	var load_errors := errors.take()
	if script == null or not script.can_instantiate() or not load_errors.is_empty():
		print("FAIL  %s  (does not load: %s)" % [name, load_errors])
		OS.remove_logger(errors)
		quit(1)
		return
	var suite: Object = script.new()
	var methods: Array[String] = []
	for m: Dictionary in script.get_script_method_list():
		var mname: String = m["name"]
		if mname.begins_with("test_") and not methods.has(mname):
			methods.append(mname)
	for mname in methods:
		var t := T.new()
		t.full = full
		t.quick = quick
		var t0 := Time.get_ticks_msec()
		suite.call(mname, t)
		var ms := Time.get_ticks_msec() - t0
		var errs := errors.take()
		if not errs.is_empty():
			t.failures.append(errs)
		var label := "%s.%s" % [name, mname.substr(5)]
		if t.failures.is_empty():
			passed += 1
			print("PASS  %s  (%.1f s)" % [label, ms / 1000.0])
		else:
			failed += 1
			print("FAIL  %s  (%.1f s)" % [label, ms / 1000.0])
			for i in mini(t.failures.size(), 12):
				print("        - " + t.failures[i])
			if t.failures.size() > 12:
				print("        - ... %d more" % (t.failures.size() - 12))
		for n in t.notes:
			if not n.is_empty():
				print("        " + n)
	var secs := (Time.get_ticks_msec() - t_start) / 1000.0
	print("%d passed, %d failed in %.1f s" % [passed, failed, secs])
	OS.remove_logger(errors)
	quit(0 if failed == 0 and passed > 0 else 1)
