# Runs tests/prop_day.gd alone and prints "N passed, M failed".
#   godot --headless --path godot --script res://tests/run_day.gd
extends SceneTree

const T = preload("res://tests/t.gd")

func _init() -> void:
	var script: GDScript = load("res://tests/prop_day.gd")
	if script == null or not script.can_instantiate():
		print("0 passed, 1 failed (prop_day.gd does not load)")
		quit(1)
		return
	var suite: Object = script.new()
	var passed := 0
	var failed := 0
	var methods: Array[String] = []
	for m: Dictionary in script.get_script_method_list():
		var mname: String = m["name"]
		if mname.begins_with("test_") and not methods.has(mname):
			methods.append(mname)
	for mname in methods:
		var t := T.new()
		suite.call(mname, t)
		if t.failures.is_empty():
			passed += 1
			print("ok    ", mname)
		else:
			failed += 1
			print("FAIL  ", mname)
			for f in t.failures.slice(0, 5):
				print("      ", f)
		for n in t.notes:
			print("      ", n)
	print("%d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)
