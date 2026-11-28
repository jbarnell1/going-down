# CAM1: a floor's security cameras as text, for comparing processes (tests/test_cameras.gd). Run on its own:
#   godot --headless --path godot --script res://tests/cameras_digest.gd -- <seed> ...
# prints one line per seed and floor: "CAMS <seed> <depth> <place> <count> <digest>", and one per Ward seed with
# --ward: "WARDCAMS <seed> <count> <digest>".
extends SceneTree

const Places = preload("res://sim/places.gd")
const Cameras = preload("res://sim/cameras.gd")
const Ward = preload("res://sim/ward/state.gd")
const Layout = preload("res://sim/ward/layout.gd")

## The floors digested: one of each place (the game's deck with the Reactor): the Clinic, the Annex, the Playroom, the
## Arboretum, the Reactor.
const DEPTHS: Array[int] = [1, 3, 4, 5, 7]

func _init() -> void:
	var ward := OS.get_cmdline_user_args().has("--ward")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			continue
		if ward:
			print(ward_line(int(a)))
		else:
			for d in DEPTHS:
				print(line(a, d))
	quit()

static func deck() -> Array[StringName]:
	return Places.with_reactor(Places.with_cycles(Places.FULL))

## One camera as text, to the millimetre and the thousandth of a radian.
static func text(c: Dictionary) -> String:
	var p: Vector3 = c["pos"]
	var a: Vector3 = c["aim"]
	return "%d %s %d %d,%d,%d %d,%d,%d %d %d %s" % [int(c["n"]), c["kind"], int(c["level"]), roundi(p.x * 1000.0), roundi(p.y * 1000.0),
		roundi(p.z * 1000.0), roundi(a.x * 1000.0), roundi(a.y * 1000.0), roundi(a.z * 1000.0), roundi(float(c["yaw"]) * 1000.0),
		roundi(float(c["pitch"]) * 1000.0), c["area"]]

static func digest(list: Array[Dictionary]) -> String:
	var parts: PackedStringArray = []
	for c in list:
		parts.append(text(c))
	return "|".join(parts).sha256_text().substr(0, 16)

static func line(seed: String, depth: int) -> String:
	var plan := Places.generate(seed, depth, deck())
	var list := Cameras.for_plan(plan)
	return "CAMS %s %d %s %d %s" % [seed, depth, plan.place, list.size(), digest(list)]

static func ward_line(seed_value: int) -> String:
	var list := Cameras.for_ward(Ward.new(seed_value), seed_value)
	return "WARDCAMS %d %d %s" % [seed_value, list.size(), digest(list)]
