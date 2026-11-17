# Runs tests/prop_notes.gd alone. Usage:
#   godot --headless --path godot --script res://tests/run_notes.gd
extends SceneTree

const T = preload("res://tests/t.gd")
const PropNotes = preload("res://tests/prop_notes.gd")

func _init() -> void:
	var passed := 0
	var failed := 0
	var suite := PropNotes.new()
	for m: Dictionary in suite.get_method_list():
		var name: String = m["name"]
		if not name.begins_with("test_"):
			continue
		var t := T.new()
		suite.call(name, t)
		if t.failures.is_empty():
			passed += 1
			print("ok   ", name)
		else:
			failed += 1
			print("FAIL ", name)
			for f in t.failures.slice(0, 5):
				print("     ", f)
		for n in t.notes:
			print("     ", n)
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)
