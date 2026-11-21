# LS1, the wipe's scene (North Star B7: "A wipe is a scene too. Everyone watches the elevator arrive at an empty landing.
# The doors open. A pause. Something steps in, and it rides up."). Every screen plays it from the host's "wipe" block
# (sim/last_stand.gd; net/protocol.gd "wipe" {at, depth, day, by, n, last}), timed by host time from `at`, so it is the
# same shot on every screen to the frame its host clock allows. Nobody can skip it, and it changes nothing the rules do:
# it fits inside the empty car's ride up to the prison (sim/run.gd RIDE_UP_TIME, 8 s), so the report waits for nothing.
#
# The shot, from a fixed camera on the floor's landing a few metres out from the doors (as far as the landing's floor
# goes, at most CAM_FAR), looking at them:
#    0.0 s  the closed doors of the empty landing; the car arrives (the indicator's ding at DING)
#    OPEN   the doors open (the lift's own door sound and slide)
#    WALK   after a pause of about two seconds, the resident that made the last catch steps past the camera and walks in:
#           its own 3D figure and walk clip (the Orderly, the second Orderly in its own look, the Temp, the Minder, the
#           Groundskeeper), into the middle of the car, where it turns to face out
#    CLOSE  the doors close on it
#    RIDE   the car rides up (the ride's rumble) and the picture fades to black by LEN
# On a floor this cannot show (the Reactor's four and the Ward's Rigger are drawn by their floors' own views, and the
# Ward's lift house is not the plan's lift) it falls back to black with the lift's sounds at the same times.
extends Node3D

const Entity = preload("res://sim/entity.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const GroundskeeperView = preload("res://client/groundskeeper_view.gd")

const DING := 0.9
const OPEN := 1.3
const WALK := 4.2
const WALK_END := 6.0
const TURN_END := 6.4
const CLOSE := 6.4
const RIDE := 7.0
const FADE_FROM := 7.2
const LEN := 8.0
## The camera: at most this far out from the doors (car-local z), never nearer than CAM_NEAR, at CAM_X to the side.
const CAM_FAR := 4.2
const CAM_NEAR := 1.6
const CAM_X := 0.85
const CAM_Y := 1.55
## The residents whose figure walks in; any other falls back to black.
const WALKERS: Array[String] = ["orderly", "temp", "minder", "groundskeeper"]

# ---------------------------------------------------------------------------------------------
# Pure: the timeline (tests/test_wipe_scene.gd).

## Whether the scene is playing at `host_now` for a "wipe" block (null or {} for none).
static func playing(wipe: Variant, host_now: float) -> bool:
	if not wipe is Dictionary or (wipe as Dictionary).is_empty():
		return false
	var e := host_now - float(wipe["at"])
	return e >= 0.0 and e < LEN

## Whether this resident's figure can walk in (else the fallback: black, the lift's sounds).
static func shows_figure(by: String, ward_native: bool) -> bool:
	return not ward_native and WALKERS.has(by)

## The doors at `e` seconds in: open from OPEN until CLOSE.
static func doors_open(e: float) -> bool:
	return e >= OPEN and e < CLOSE

## The picture's black at `e`: 0 until FADE_FROM, 1 at LEN.
static func fade(e: float) -> float:
	return clampf((e - FADE_FROM) / (LEN - FADE_FROM), 0.0, 1.0)

## The sound cues due by `e`, in order: [name, at].
static func cues() -> Array:
	return [["ding", DING], ["doors", OPEN], ["doors", CLOSE], ["ride", RIDE]]

## The camera in the car's frame (client/lift.gd: x to the right walking in, z out of the car, y up) for a landing
## `d` metres deep: [position, the point it looks at].
static func camera_local(d: float) -> Array:
	return [Vector3(CAM_X, CAM_Y, d), Vector3(0.0, 1.25, -1.2)]

## The figure in the car's frame at `e` for a landing `d` deep: {show, pos, face (a direction), anim}. It comes from
## behind the camera on the left, walks to the doorway and into the middle of the car, and turns to face out.
static func figure_local(e: float, d: float, car_depth: float) -> Dictionary:
	var start := Vector3(-0.9, 0.0, d + 0.8)
	var door := Vector3(0.0, 0.0, 0.35)
	var inside := Vector3(0.0, 0.0, -car_depth * 0.55)
	if e < WALK:
		return {"show": false, "pos": start, "face": door - start, "anim": "idle"}
	if e < WALK_END:
		var k := (e - WALK) / (WALK_END - WALK)
		var first := start.distance_to(door)
		var whole := first + door.distance_to(inside)
		var along := k * whole
		if along <= first:
			return {"show": true, "pos": start.lerp(door, along / first), "face": door - start, "anim": "walk"}
		return {"show": true, "pos": door.lerp(inside, (along - first) / (whole - first)), "face": inside - door, "anim": "walk"}
	var k2 := clampf((e - WALK_END) / (TURN_END - WALK_END), 0.0, 1.0)
	var face := (inside - door).normalized().slerp(Vector3(0, 0, 1), k2) if k2 < 1.0 else Vector3(0, 0, 1)
	return {"show": true, "pos": inside, "face": face, "anim": "idle"}

## How deep the landing is in front of the doors: the furthest the plan's floor goes straight out from the doorway
## (on the camera's side), within CAM_NEAR .. CAM_FAR. `lift_xf` the lift's transform (client/lift.gd build).
static func landing_depth(plan: Floor.FloorPlan, lift_xf: Transform3D, level: int) -> float:
	if plan == null:
		return 2.4
	var ok := CAM_NEAR
	var z := 0.5
	while z <= CAM_FAR + 0.4 + 1e-6:
		var p := lift_xf * Vector3(CAM_X, 0.0, z)
		var c := Move.cell_of(plan, Move.Body.make(p.x, p.z, level, p.y))
		if c.x < 0 or c.y < 0 or c.x >= plan.width or c.y >= plan.height or not Floor.is_walkable(plan, level, c.x, c.y):
			break
		ok = z
		z += 0.25
	return clampf(ok - 0.4, CAM_NEAR, CAM_FAR)

## Everything one screen shows at `e` (for the tests and the scripted checks): the same numbers on every screen.
static func frame_at(wipe: Dictionary, host_now: float, d: float, car_depth: float, ward_native: bool) -> Dictionary:
	var e := host_now - float(wipe["at"])
	var fig := figure_local(e, d, car_depth)
	var shows := shows_figure(str(wipe["by"]), ward_native)
	return {"e": e, "by": str(wipe["by"]), "n": int(wipe["n"]), "doors": doors_open(e), "fade": 1.0 if not shows else fade(e),
		"figure": shows and bool(fig["show"]), "pos": fig["pos"], "face": fig["face"], "anim": fig["anim"], "camera": camera_local(d)}

# ---------------------------------------------------------------------------------------------
# On screen (client/main.gd: begin() when a new wipe block plays, show_at() every frame while it plays, end() after).

var wipe: Dictionary = {}
var depth_out := 2.4
var car_depth := 4.0
var figure: Node3D = null
var ward_native := false
var _played := {}
var _last := {}

## A new scene: the figure for `wipe.by` (made here, its own instance, set up as client/main.gd sets up the floor's).
func begin(w: Dictionary, plan: Floor.FloorPlan, lv: Level, lift: Node3D, crew_seed: String, faces: Array[String], native: bool) -> void:
	end()
	wipe = w
	ward_native = native
	_played = {}
	car_depth = float(lift.get("depth")) if lift != null and lift.get("depth") != null else 4.0
	depth_out = landing_depth(plan, lift.global_transform, plan.landing.level if plan != null else 0) if lift != null else 2.4
	if not shows_figure(str(w["by"]), native):
		return
	match str(w["by"]):
		"temp":
			var tv := TempView.new()
			add_child(tv)
			tv.set_crew(crew_seed, faces)
			tv.set_floor(plan, lv)
			figure = tv
		"minder":
			var mv := MinderView.new()
			add_child(mv)
			mv.set_floor(plan, lv)
			figure = mv
		"groundskeeper":
			var gv := GroundskeeperView.new()
			add_child(gv)
			gv.call(&"set_floor", lv)
			figure = gv
		_:
			var ov := OrderlyView.new()
			add_child(ov)
			ov.set_floor(plan, lv.pieces)
			if int(w.get("n", 1)) == 2:
				ov.use_second_look()
			figure = ov
	figure.name = "WipeFigure"

## This frame at `host_now`: the camera, the figure, the doors (lift.set_doors before its update), the cues. Returns
## frame_at's dictionary.
func show_at(host_now: float, cam: Camera3D, lift: Node3D, sfx: Node) -> Dictionary:
	var f := frame_at(wipe, host_now, depth_out, car_depth, ward_native)
	_last = f
	var e := float(f["e"])
	if lift != null:
		var xf := lift.global_transform
		var cp: Array = f["camera"]
		cam.look_at_from_position(xf * (cp[0] as Vector3), xf * (cp[1] as Vector3), Vector3.UP)
		lift.call(&"set_doors", bool(f["doors"]))
		if figure != null:
			var p: Vector3 = xf * (f["pos"] as Vector3)
			var dir: Vector3 = xf.basis * (f["face"] as Vector3)
			var pose := {"x": p.x, "y": p.y, "z": p.z, "level": 0, "yaw": Entity.yaw_toward(dir.x, dir.z), "anim": f["anim"], "animTime": e}
			figure.call(&"show_pose", pose, bool(f["figure"]))
	for c: Array in cues():
		var key := "%s@%s" % [c[0], c[1]]
		if e >= float(c[1]) and not _played.has(key):
			_played[key] = true
			# A screen that came in late plays only what is due now, not the whole list at once.
			if e - float(c[1]) < 0.5 and sfx != null:
				if str(c[0]) == "ride":
					sfx.call(&"ride", true)
				else:
					sfx.call(&"play", str(c[0]))
	return f

## The scene is over (or a new floor): the figure goes.
func end() -> void:
	if figure != null and is_instance_valid(figure):
		figure.queue_free()
	figure = null
	wipe = {}

## Tests and the scripted checks: what was shown last.
func describe() -> Dictionary:
	var out := _last.duplicate()
	if out.has("pos"):
		out["pos"] = [float(out["pos"].x), float(out["pos"].y), float(out["pos"].z)]
		out["face"] = [float(out["face"].x), float(out["face"].y), float(out["face"].z)]
		out.erase("camera")
	out["figureDrawn"] = figure != null and is_instance_valid(figure) and figure.visible
	out["figureKind"] = str(wipe.get("by", ""))
	return out
