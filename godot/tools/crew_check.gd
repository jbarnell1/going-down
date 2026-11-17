# The crewmate's feet, headless (client/crew_view.gd): one figure driven along the ground the way the
# network drives the others (placed every frame, its gait and ground speed given), at the rules' walk,
# sprint and creep speeds, forwards, sideways, diagonally and backwards. For each it measures foot slip
# on the skeleton as drawn: how far a planted toe moves over the ground against how far the body moves
# meanwhile (CrewView.slip). Also: the creep plays at a sensible rate (not a slowed-down sneak), and the
# creeping mask stays at the creeping eye (eye_height.gd CREEP). Exit code 0 when all hold.
#   "$GODOT" --headless --fixed-fps 60 --path godot --script res://tools/crew_check.gd [-- break=rate|swing]
# break=rate plays every gait at 1x whatever the speed (CrewView.test_break); break=swing drops the short
# sneak's swing but keeps its stride. Either must turn the check red.
extends SceneTree

const Stamina = preload("res://sim/stamina.gd")
const EyeHeight = preload("res://client/eye_height.gd")

## Slip above this share of the body's own travel fails: over each plant, the planted toe may end up at
## most 12 cm from where it touched down for every metre the body covers meanwhile (the clips' own small
## skate is 1-4 %; a gait played at 1x whatever the speed slides 13-49 %, a sneak at its full swing 67 %).
const SLIP_MAX := 0.12
## The creep's playback rate must be at least this (the old sneak played at 0.54x: slow motion).
const CREEP_RATE_MIN := 0.75
const CREEP_RATE_MAX := 1.3
const MASK_TOL := 0.06
const SECONDS := 4.0
const TURN_SECONDS := 1.5

var view: CrewView
var problems: Array[String] = []

func _init() -> void:
	for raw in OS.get_cmdline_user_args():
		var a := raw.trim_prefix("--")
		if a.begins_with("break="):
			CrewView.test_break = a.get_slice("=", 1)
	_run.call_deferred()

func _frames(n: int) -> void:
	for i in n:
		await process_frame

func _run() -> void:
	view = CrewView.new()
	root.add_child(view)
	await _frames(2)
	print("strides (m/s at 1x, measured from the planted toe; root motion said walk 1.78, run 2.58, sneak 2.22):")
	for c: String in CrewView.SWING:
		print("  %-6s %.2f  (swing %.2f)" % [c, CrewView.stride(c), float(CrewView.SWING[c])])
	var cases := [
		["walk", Stamina.WALK_SPEED, 0.0], ["sprint", Stamina.SPRINT_SPEED, 0.0], ["creep", Stamina.CREEP_SPEED, 0.0],
		["walk", Stamina.WALK_SPEED, 90.0], ["walk", Stamina.WALK_SPEED, -45.0], ["walk", Stamina.WALK_SPEED, 180.0],
		["sprint", Stamina.SPRINT_SPEED, 60.0], ["creep", Stamina.CREEP_SPEED, 90.0], ["creep", Stamina.CREEP_SPEED, 180.0],
		["walk", 1.6, 0.0],
		# Turning round and walking off at once (standing facing away, the look flips, the walk starts):
		# measured over the first TURN_SECONDS only.
		["walk", Stamina.WALK_SPEED, 0.0, true], ["sprint", Stamina.SPRINT_SPEED, 0.0, true],
	]
	var worst := 0.0
	for c: Array in cases:
		var turn := c.size() > 3 and bool(c[3])
		var r: Dictionary = await _drive(StringName(c[0]), float(c[1]), float(c[2]), turn)
		var ratio: float = r["ratio"]
		worst = maxf(worst, ratio)
		var ok := ratio <= SLIP_MAX
		print("%s %-6s %.1f m/s, %4.0f deg from the look%s: clip %s at %.2fx%s, planted %.2f s, toe %.3f m/s against body %.3f m/s, slip %.1f %%" % [
			"PASS" if ok else "FAIL", c[0], c[1], c[2], ", turning round first" if turn else "", r["clip"], absf(r["rate"]), " reversed" if r["reverse"] else "", r["t"], r["footv"], r["bodyv"], 100.0 * ratio])
		if not ok:
			problems.append("%s %.1f m/s at %.0f deg slips %.1f %% (limit %.0f %%)" % [c[0], c[1], c[2], 100.0 * ratio, 100.0 * SLIP_MAX])
		if r["t"] < (0.25 if turn else 0.5):
			problems.append("%s at %.0f deg: a toe was planted only %.2f s (not measured)" % [c[0], c[2], r["t"]])
		if c[0] == "creep" and c[2] == 0.0:
			var rate := absf(float(r["rate"]))
			var rate_ok := rate >= CREEP_RATE_MIN and rate <= CREEP_RATE_MAX
			print("%s the creep plays the sneak at %.2fx (want %.2f-%.2f; the clip's own swing would be %.2fx)" % ["PASS" if rate_ok else "FAIL", rate, CREEP_RATE_MIN, CREEP_RATE_MAX, Stamina.CREEP_SPEED / CrewView.STRIDE["sneak"]])
			if not rate_ok:
				problems.append("creep plays at %.2fx" % rate)
			var m: Vector2 = r["mask"]
			var mask_ok := absf(m.x - EyeHeight.CREEP) < MASK_TOL + 0.03 and absf(m.y - EyeHeight.CREEP) < MASK_TOL + 0.03
			print("%s creeping, the mask is %.2f-%.2f m high (the creeping eye %.2f)" % ["PASS" if mask_ok else "FAIL", m.x, m.y, EyeHeight.CREEP])
			if not mask_ok:
				problems.append("creeping mask %.2f-%.2f m" % [m.x, m.y])
	# Creeping in place: the sneak held, its mask at the creeping eye (what play_net checks over the network).
	view.set_body(Vector3.ZERO, 0.0)
	view.set_gait(&"creep", 0.0)
	await _frames(60)
	var still := view.mask_height()
	var still_ok := absf(still - EyeHeight.CREEP) < MASK_TOL
	print("%s creeping in place: clip %s, mask %.3f m (the creeping eye %.2f)" % ["PASS" if still_ok else "FAIL", view.clip, still, EyeHeight.CREEP])
	if not still_ok:
		problems.append("creeping in place, mask %.3f m" % still)
	view.set_gait(&"still", 0.0)
	await _frames(60)
	var stand := view.mask_height()
	var stand_ok := absf(stand - EyeHeight.STAND) < MASK_TOL
	print("%s standing: mask %.3f m (the standing eye %.2f)" % ["PASS" if stand_ok else "FAIL", stand, EyeHeight.STAND])
	if not stand_ok:
		problems.append("standing mask %.3f m" % stand)
	print("worst slip %.1f %% (limit %.0f %%)" % [100.0 * worst, 100.0 * SLIP_MAX])
	if not problems.is_empty():
		for p in problems:
			print("  problem: ", p)
	print("crew check: %s" % ("PASS" if problems.is_empty() else "FAIL, %d problems" % problems.size()))
	quit(0 if problems.is_empty() else 1)

# Looks along -Z (yaw 0) and moves at `deg` from it; settles one second, then measures SECONDS. With
# `turn` it first stands looking the other way (yaw PI), and is measured from the first step for
# TURN_SECONDS.
func _drive(gait: StringName, sp: float, deg: float, turn := false) -> Dictionary:
	var dir := Vector3(-sin(deg_to_rad(deg)), 0.0, -cos(deg_to_rad(deg)))
	var pos := Vector3(50.0, 0.0, 50.0)
	view.set_gait(&"still", 0.0)
	for i in 60:
		view.set_body(pos, PI if turn else 0.0)
		await process_frame
	var dt := 1.0 / 60.0
	var before := {}
	var mask := Vector2(99.0, -99.0)
	var n := int((TURN_SECONDS if turn else 1.0 + SECONDS) / dt)
	var from := 0 if turn else int(1.0 / dt)
	var rate := 0.0
	for i in n:
		if i == n / 2:
			rate = view.ap.speed_scale
		if i == from:
			before = view.slip.duplicate(true)
		pos += dir * sp * dt
		view.set_body(pos, 0.0)
		view.set_gait(gait, sp)
		await process_frame
		if i > int(1.0 / dt):
			var h := view.mask_height()
			mask = Vector2(minf(mask.x, h), maxf(mask.y, h))
	await process_frame
	var c := view.clip
	var a: Dictionary = view.slip.get(c, {})
	var b: Dictionary = before.get(c, {})
	var t := float(a.get("t", 0.0)) - float(b.get("t", 0.0))
	var foot := float(a.get("foot", 0.0)) - float(b.get("foot", 0.0))
	var body := float(a.get("body", 0.0)) - float(b.get("body", 0.0))
	return {"clip": c, "rate": rate, "reverse": view.reverse, "t": t, "footv": foot / maxf(t, 1e-6),
		"bodyv": body / maxf(t, 1e-6), "ratio": foot / maxf(body, 1e-6), "mask": mask}
