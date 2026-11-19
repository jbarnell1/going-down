# The Orderly as a screen draws it, and whether a camera could be showing it. Ports of
# src/net/protocol.ts (q2, q3, quantPose, lerpPose, samePose, poseBody) and src/net/session.ts
# (thresholdCamera, cameraSees). A pose is a Dictionary with the TypeScript keys:
#   {x, y, z, level, yaw, anim (String), animTime}
extends RefCounted

const Run = preload("res://sim/run.gd")
const Entity = preload("res://sim/entity.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Orientation = preload("res://sim/orientation.gd")

## JavaScript's Math.round (halves round up), exact as V8 does it: ceil, then step back if that
## went more than half up.
static func round_js(x: float) -> float:
	var r := ceilf(x)
	if r - 0.5 > x:
		r -= 1.0
	return r

## To the centimetre (never -0).
static func q2(x: float) -> float:
	var r := round_js(x * 100.0) / 100.0
	return 0.0 if r == 0.0 else r

## To the thousandth (never -0).
static func q3(x: float) -> float:
	var r := round_js(x * 1000.0) / 1000.0
	return 0.0 if r == 0.0 else r

static func _wrap_angle(a: float) -> float:
	var r := fmod(a, 2.0 * PI)
	if r > PI:
		r -= 2.0 * PI
	if r < -PI:
		r += 2.0 * PI
	return r

static func pose_of(o: Entity.OrderlyState) -> Dictionary:
	return {"x": o.body.x, "y": o.body.y, "z": o.body.z, "level": o.body.level, "yaw": o.yaw, "anim": String(o.anim), "animTime": o.anim_time}

static func quant_pose(p: Dictionary) -> Dictionary:
	return {"x": q2(p["x"]), "y": q2(p["y"]), "z": q2(p["z"]), "level": p["level"], "yaw": q3(p["yaw"]), "anim": p["anim"], "animTime": q3(p["animTime"])}

## The pose drawn between two tick poses, `alpha` of the way from a to b, quantised. Across a change
## of level it does not blend: it shows a until b's time.
static func lerp_pose(a: Dictionary, b: Dictionary, alpha: float) -> Dictionary:
	if a["level"] != b["level"] or alpha <= 0.0:
		return quant_pose(a)
	if alpha >= 1.0:
		return quant_pose(b)
	var k := alpha
	var pick := a if k < 0.5 else b
	var ax: float = a["x"]
	var ay: float = a["y"]
	var az: float = a["z"]
	var ayaw: float = a["yaw"]
	var bx: float = b["x"]
	var by: float = b["y"]
	var bz: float = b["z"]
	var byaw: float = b["yaw"]
	var at: float = a["animTime"]
	var bt: float = b["animTime"]
	var anim_time: float = at + (bt - at) * k if a["anim"] == b["anim"] else float(pick["animTime"])
	return quant_pose({
		"x": ax + (bx - ax) * k,
		"y": ay + (by - ay) * k,
		"z": az + (bz - az) * k,
		"level": a["level"],
		"yaw": _wrap_angle(ayaw + _wrap_angle(byaw - ayaw) * k),
		"anim": pick["anim"],
		"animTime": anim_time,
	})

static func same_pose(a: Dictionary, b: Dictionary) -> bool:
	return a["x"] == b["x"] and a["y"] == b["y"] and a["z"] == b["z"] and a["level"] == b["level"] \
		and a["yaw"] == b["yaw"] and a["anim"] == b["anim"] and a["animTime"] == b["animTime"]

static func pose_body(p: Dictionary) -> Move.Body:
	return Move.Body.make(p["x"], p["z"], p["level"], p["y"])

## A camera: where the eyes are and where they look (src/net/session.ts Camera).
class Camera:
	var body: Move.Body
	var eye: float
	var yaw: float
	var pitch: float
	var h_fov_deg: float
	var v_fov_deg: float

	static func make(body_: Move.Body, eye_: float, yaw_: float, pitch_: float, h_fov: float, v_fov: float) -> Camera:
		var c := Camera.new()
		c.body = body_
		c.eye = eye_
		c.yaw = yaw_
		c.pitch = pitch_
		c.h_fov_deg = h_fov
		c.v_fov_deg = v_fov
		return c

## The view a player inside the car has of the floor with the doors open (as run.gd judges it).
static func _threshold_view(car: Run.CarGeometry, cam: Camera) -> Entity.PlayerView:
	var v := Run.car_local(car, cam.body.x, cam.body.z)[1]
	var half := car.door_width / 2.0
	var at := Run.car_body(car, -0.02, maxf(-half, minf(half, v)))
	var body := Move.Body.make(at.x, at.z, at.level, cam.body.y)
	return Entity.PlayerView.make("me", body, cam.eye, cam.yaw, cam.pitch, cam.h_fov_deg, cam.v_fov_deg, true)

## Whether a camera could be showing the Orderly drawn at `pose`: the logic's own generous test
## (Entity.seen_by). From inside the car with the doors open it also looks from the threshold, as the
## logic does; either view counts. `car` is Run.car_geometry(plan) (session.ts carFor).
static func camera_sees(plan: Floor.FloorPlan, car: Run.CarGeometry, cam: Camera, pose: Dictionary, doors_open: bool) -> bool:
	var views: Array[Entity.PlayerView] = [Entity.PlayerView.make("me", cam.body, cam.eye, cam.yaw, cam.pitch, cam.h_fov_deg, cam.v_fov_deg, true)]
	if doors_open and Run.in_car(car, cam.body):
		views.append(_threshold_view(car, cam))
	var shape := Orientation.target_body() if plan.place == Orientation.PLACE else null
	return Entity.seen_by(plan, pose_body(pose), views, shape) != null
