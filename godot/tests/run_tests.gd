# Runs every test: one line per test, then a summary. Exit code 0 only if all pass.
#   godot --headless --path godot --script res://tests/run_tests.gd
#   godot --headless --path godot --script res://tests/run_tests.gd -- ref_rng prop_clinic   (only these files)
#   godot --headless --path godot --script res://tests/run_tests.gd -- --full                (full-size property runs)
#   godot --headless --path godot --script res://tests/run_tests.gd -- --quick               (about a minute: first seeds only)
#   ... -- --port-base=N   the first of the ports this engine's socket tests may open (tests/test_ports.gd);
#       tools/godot.mjs test passes one to every engine it starts, and splits the files over several with --shards=
#   godot --headless --path godot --script res://tests/run_tests.gd -- --golden [files] [--full]
#       records the goldens instead of comparing (npm run godot:golden: see tests/README.md); never
#       part of a test run. ref_* and test_jsmath run at the default size, prop_* at the quick and the
#       default sizes; with --full only the full property sizes are recorded.
# A test file is a script under tests/ whose methods named test_* take one argument, the T
# context (tests/t.gd). Any engine or script error while a test runs (a failed call, a push_error
# from the rules, a script that does not compile) fails that test.
extends SceneTree

const T = preload("res://tests/t.gd")
const Golden = preload("res://tests/golden.gd")

const FILES: Array[String] = [
	"test_scripts_load", "test_export_data", "test_jsmath", "ref_rng", "ref_floors", "ref_move", "ref_sight", "ref_entity", "ref_instrument", "ref_run", "ref_bots", "ref_bridge", "ref_net",
	"prop_stamina", "prop_clinic", "prop_entity", "prop_instrument", "prop_run", "prop_blackout", "prop_net",
	"prop_lift", "prop_annex", "prop_prison", "prop_notes", "prop_marks", "test_marks_view", "test_annex_notes_view", "prop_upgrades", "prop_report", "prop_day", "prop_save", "prop_profiles", "prop_face_net",
	"prop_playroom", "prop_seek", "prop_places", "prop_temp", "prop_day_net", "prop_count_run", "prop_door_shadow", "prop_count_net", "prop_quota_net", "prop_marks_net",
	"prop_downs", "prop_down_view", "prop_watchers", "prop_relocate", "prop_hides", "prop_owner_0833", "prop_lonely", "prop_annex_drag", "prop_playroom_tuned", "prop_minder_hunt", "prop_minder_hunt_view", "test_minder_v2","prop_party_table",
	"prop_settings", "prop_settings_net", "prop_tenant", "prop_hints", "prop_tapes", "prop_telemetry", "prop_day_view", "prop_furniture", "prop_ready", "prop_ready_screen", "test_local_bots", "test_solo_diagnostics",
	"prop_orientation", "prop_flare", "prop_lamp", "prop_nerve", "prop_shaken",
	"prop_hearing", "prop_arboretum", "prop_garden_cones", "prop_garden_search", "test_garden_recordings", "test_keeper_figure", "prop_ward_net",
	"test_data_check",
	"prop_brightness", "prop_brightness_curve",
	"prop_findables", "prop_badge_search", "prop_search", "prop_search_view", "test_findables_data",
	"prop_inventory", "prop_inventory_net",
	"test_crew_motion", "test_orderly_motion", "test_temp_animation", "test_temp_motion",
	"test_temp_v2",
	"prop_furniture_layout",
	"prop_resident_navigation", "test_floor_materials", "test_action_sfx", "prop_host_playtest", "test_host_tools",
	"prop_cabinet", "prop_shop", "prop_shop_net", "prop_deep_pockets", "prop_second_wind", "prop_soft_shoes", "prop_quick_fingers", "prop_long_burn", "prop_field_dressing", "prop_steady_gaze", "prop_throwing_arm", "test_reactor",
	"prop_late_floors",
	"test_floor_entry",
	"prop_second_orderly",
	"prop_cycles",
	"prop_pressures",
	"prop_orderly_fix",
	"test_cycle_entry",
	"prop_station",
	"prop_station_crews",
	"test_ward_exit",
	"test_ward_look",
	"test_ward_native",
	"test_ward_kit",
	"test_station_look",
	"prop_ward_walk_net",
	"prop_ward_same",
	"test_ward_rigger",
	"prop_ward_reach",
	"test_station_view",
	"test_floor_media",
	"test_rigger_v2",
	"test_rigger_look",
	"prop_rigger_graph",
	"prop_rigger_roam",
	"prop_rigger_quota",
	"test_orderly_v2",
	"test_ward_route",
	"test_late_archive",
	"test_figures",
	"prop_late_admit",
	"test_prison_deck",
	"test_intercom",
	"test_crew_watch",
	"test_test_ports",
	"prop_ward_call",
	"test_ward_web_view",
	"test_music",
	"prop_ward_layout",
	"test_ward_dress",
	"prop_minder_calm",
	"prop_down_ring",
	"prop_pn_fixes",
	"test_annex_lookalikes",
	"prop_last_stand",
	"test_wipe_scene",
	"test_caught_scene",
	"prop_deal",
	"prop_split",
	"test_split_view",
]

## Counts every error the engine reports (GDScript has no exceptions to catch).
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
	# Animation and skeleton tests attach real scenes to this tree.
	_run.call_deferred()

func _run() -> void:
	var errors := ErrorCounter.new()
	OS.add_logger(errors)
	var args := OS.get_cmdline_user_args()
	var full := args.has("--full")
	var quick := args.has("--quick") and not full
	var recording := args.has("--golden")
	Golden.recording = recording
	if recording:
		print("RECORDING GOLDENS (npm run godot:golden): results are written to tests/golden/, nothing is compared")
		print("  sizes: %s" % ("the FULL property sizes only (properties.json key full)" if full else "ref_* and test_jsmath at the default size; prop_* at the quick and default sizes (properties.json keys quick, sub, clinic, clinicQuick)"))
	elif quick:
		print("quick set: every test file, first seeds only (the default run is the full check)")
	var only: Array[String] = []
	for a in args:
		if not a.begins_with("--"):
			only.append(a)
	for a in only:
		if not FILES.has(a):
			print("FAIL  %s  (no such test file; the files are: %s)" % [a, ", ".join(FILES)])
			OS.remove_logger(errors)
			quit(1)
			return
	var passed := 0
	var failed := 0
	var engine_errors := 0
	var t_start := Time.get_ticks_msec()
	for name in FILES:
		if not only.is_empty() and not only.has(name):
			continue
		# The runs of this file: [quick, full] pairs.
		var passes: Array = [[quick, full]]
		if recording:
			if name.begins_with("prop_"):
				passes = [[false, true]] if full else [[true, false], [false, false]]
			else:
				passes = [] if full else [[false, false]]
		for pass_: Array in passes:
			errors.take()
			var path := "res://tests/%s.gd" % name
			var script: GDScript = load(path)
			var load_errors := errors.take()
			if script == null or not script.can_instantiate() or not load_errors.is_empty():
				print("FAIL  %s  (does not load: %s)" % [name, load_errors])
				failed += 1
				engine_errors += 1
				continue
			var suite: Object = script.new()
			var methods: Array[String] = []
			for m: Dictionary in script.get_script_method_list():
				var mname: String = m["name"]
				if mname.begins_with("test_") and not methods.has(mname):
					methods.append(mname)
			for mname in methods:
				var t := T.new()
				t.quick = pass_[0]
				t.full = pass_[1]
				var t0 := Time.get_ticks_msec()
				suite.call(mname, t)
				var ms := Time.get_ticks_msec() - t0
				var errs := errors.take()
				if not errs.is_empty():
					t.failures.append(errs)
					engine_errors += 1
				var label := "%s.%s" % [name, mname.substr(5)]
				if recording and name.begins_with("prop_"):
					label += " [%s]" % t.size_key()
				if t.failures.is_empty():
					passed += 1
					print("%s  %s  (%.1f s)" % ["REC " if recording else "PASS", label, ms / 1000.0])
				else:
					failed += 1
					# While recording nothing is compared: a failure is a design rule (or an error).
					print("%s  %s  (%.1f s)" % ["FAIL (rule)" if recording and errs.is_empty() else "FAIL", label, ms / 1000.0])
					for i in mini(t.failures.size(), 12):
						print("        - " + t.failures[i])
					if t.failures.size() > 12:
						print("        - ... %d more" % (t.failures.size() - 12))
				for n in t.notes:
					if not n.is_empty():
						print("        " + n)
	var secs := (Time.get_ticks_msec() - t_start) / 1000.0
	if recording:
		if engine_errors > 0:
			print("GOLDENS NOT WRITTEN: %d test(s) raised engine or script errors (see above)" % engine_errors)
			OS.remove_logger(errors)
			quit(1)
			return
		var written := Golden.write_all()
		print("goldens written: %s" % (", ".join(written) if not written.is_empty() else "none"))
		print("%d recorded, %d design-rule failures in %.1f s" % [passed, failed, secs])
		var write_errors := errors.take()
		if not write_errors.is_empty():
			print("FAIL  writing the goldens: " + write_errors)
		OS.remove_logger(errors)
		quit(0 if failed == 0 and write_errors.is_empty() else 1)
		return
	print("%d passed, %d failed in %.1f s" % [passed, failed, secs])
	OS.remove_logger(errors)
	quit(0 if failed == 0 and passed > 0 else 1)
