# The Playroom look's check, headless (client/playroom_view.gd check and check_dark), on floors drawn
# from the real generator: every hide's furniture within 5 cm of its inside spot, every squeaker tile
# in the rules drawn and no other, every zone's signs reading its hide count from the rules, the real
# lights under the renderer's limit, and the count-dark switch. Exit code 0 when all hold.
#   "$GODOT" --headless --path godot --script res://tools/playroom_look_check.gd [-- floors=40 break=sign|squeak]
# floors=N: seed play-0.. at depths 1 to 4 (N floors). break= applies a deliberate break
# (PlayroomView.test_break): "sign" guesses each sign's number from its zone's kind, "squeak" leaves
# one squeaker tile out. Prints one line per problem (the first 12) and a summary line.
extends SceneTree

const Playroom = preload("res://sim/playroom.gd")
const Run = preload("res://sim/run.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const PlayroomView = preload("res://client/playroom_view.gd")

func _init() -> void:
	var count := 40
	for raw in OS.get_cmdline_user_args():
		var a := raw.trim_prefix("--")
		if a.begins_with("floors="):
			count = int(a.get_slice("=", 1))
		elif a.begins_with("break="):
			PlayroomView.test_break = a.get_slice("=", 1)
	var t0 := Time.get_ticks_msec()
	var problems: Array[String] = []
	var totals := {"hides": 0, "squeakers": 0, "signs": 0, "zones": 0, "max_lights": 0, "min_lights": 1 << 30, "max_offset_cm": 0.0}
	for i in count:
		var s := "play-%d" % (i / 4)
		var d := 1 + i % 4
		var fp := Playroom.generate_playroom(s, d)
		var lv := Level.new()
		lv.build(PlanDump.dump(fp, Run.car_geometry(fp)), s)
		var v: Object = lv.get_meta("playroom")
		var stats := {}
		var p: Array[String] = v.call(&"check", stats)
		problems.append_array(p)
		if i == 0:
			var pd: Array[String] = v.call(&"check_dark")
			for line in pd:
				problems.append("%s/%d: %s" % [s, d, line])
		totals.hides += int(stats.hides)
		totals.squeakers += int(stats.squeakers_rules)
		totals.signs += int(stats.signs)
		totals.zones += int(stats.zones)
		totals.max_lights = maxi(int(totals.max_lights), int(stats.lights))
		totals.min_lights = mini(int(totals.min_lights), int(stats.lights))
		totals.max_offset_cm = maxf(float(totals.max_offset_cm), float(stats.max_offset_cm))
		lv.free()
	print("playroom look check: %s, %d floors, %d hides (furniture at most %.2f cm off), %d squeaker tiles, %d zones, %d signs, %d to %d real lights a floor (limit %d), %d ms" % [
		"PASS" if problems.is_empty() else "FAIL (%d problems)" % problems.size(), count, totals.hides, totals.max_offset_cm, totals.squeakers,
		totals.zones, totals.signs, totals.min_lights, totals.max_lights, PlayroomView.LIGHT_LIMIT, Time.get_ticks_msec() - t0])
	for line: String in problems.slice(0, 12):
		print("  ", line)
	quit(0 if problems.is_empty() else 1)
