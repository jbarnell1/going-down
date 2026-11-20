# The Reactor's crews, measured (RX2): bot crews of each size and skill play floor 7 over many seeds in a real run
# (tests/prop_station_crews.gd measure, sim/bot.gd "The Reactor's crews") and the table is printed: finish rate
# (power restored and at least one rides up), tape carried out, players lost, cut to restore, chased, and where and
# when the catches come. Headless, no window:
#   "$GODOT" --headless --path godot --script res://tools/station_crews.gd -- seeds=200 [sizes=1,2,4,6]
#       [skills=careless,sensible,expert] [first=0] [set=reactor.run_speed:3.0,...] [trace=seed:size:skill]
extends SceneTree

const C = preload("res://tests/prop_station_crews.gd")

func _init() -> void:
	var seeds := 40
	var first := 0
	var sizes: Array[int] = [1, 2, 4, 6]
	var skills: Array[StringName] = [&"careless", &"sensible", &"expert"]
	var given := {}
	var trace := ""
	for raw in OS.get_cmdline_user_args():
		var a := raw.trim_prefix("--")
		var key := a.get_slice("=", 0)
		var val := a.get_slice("=", 1)
		match key:
			"seeds": seeds = int(val)
			"first": first = int(val)
			"sizes":
				sizes.clear()
				for v in val.split(","):
					sizes.append(int(v))
			"skills":
				skills.clear()
				for v in val.split(","):
					skills.append(StringName(v))
			"set":
				for kv in val.split(","):
					given[kv.get_slice(":", 0)] = float(kv.get_slice(":", 1))
			"trace": trace = val
			"still":
				# still=gap: a player standing still that many metres' walk from seat 1, over 30 seeds.
				for i in 30:
					print(C.standing_still("still-%d" % i, float(val), given))
				quit(0)
				return
	if not trace.is_empty():
		var p := trace.split(":")
		C.trace = true
		print(C.measure(p[0], int(p[1]), StringName(p[2]), given))
		quit(0)
		return
	print("seeds %d from %d, settings %s" % [seeds, first, given])
	print("size skill     finish  tape(of finished)  lost/run chased  catch-or-within-2m  finished-with-a-catch(of finished)  finished-leaving-someone  never-chased  shortest-tell  cut->restore  lead(stir->stand)  stir->first-reach  catches: n, after-cut median, lift-dist median, by phase")
	for size in sizes:
		for skill in skills:
			var t0 := Time.get_ticks_msec()
			var c: Dictionary = C.cell(size, skill, seeds, given, first)
			var after: Array = []
			var lift: Array = []
			var phases := {}
			for e: Dictionary in c["catches"]:
				after.append(float(e["after"]))
				lift.append(float(e["lift"]))
				var ph := str(e["phase"]) + ("*" if bool(e["carrier"]) else "")
				phases[ph] = int(phases.get(ph, 0)) + 1
			after.sort()
			lift.sort()
			print("%d    %-9s %3d%%   %3d%% (%d)  %.2f     %3d%%   %3d%%   %d   %d   %d   %4.1f s   %5.1f s       %4.1f s             %4.1f s             %d, %.0f s, %.0f m, %s   (%.0f s)" % [
				size, skill, 100 * int(c["finished"]) / seeds, 100 * int(c["tape"]) / seeds, int(c["tape_fin"]), float(c["lost"]) / seeds,
				100 * int(c["chased"]) / seeds, 100 * int(c["tense"]) / seeds, int(c["caught_fin"]), int(c["left_fin"]), int(c["calm"]), float(c["tell"]), float(c["restore"]), float(c["lead"]), float(c["reach"]),
				after.size(), after[after.size() / 2] if not after.is_empty() else -1.0, lift[lift.size() / 2] if not lift.is_empty() else -1.0,
				phases, (Time.get_ticks_msec() - t0) / 1000.0])
	quit(0)
