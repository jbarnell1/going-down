# The other players in the world: one CrewView (crew_view.gd) each, placed every frame from the network
# frame's interpolated bodies (play_link.gd `others`), with their gait, the instrument raised or not,
# being caught (set_downed for as long as the host says so), their emotes, and their footsteps from
# where they are. Each is dressed from their player index (skin, headwear, the number on the patch)
# so friends can tell each other apart; the name tag is the HUD's (main.gd projects it).
# Your own figure is never here: the frame lists everyone else, and a figure standing at the camera
# is hidden.
class_name OthersView
extends Node3D

const HEADWEAR: Array[StringName] = [&"knit", &"hair", &"none"]
const GAITS := {"walk": &"walk", "creep": &"creep", "sprint": &"sprint"}
## Metres between footsteps, by gait, and how loud each is (dB).
const STEP_LEN := {"walk": 0.75, "creep": 0.55, "sprint": 1.05}
const STEP_DB := {"walk": -8.0, "creep": -20.0, "sprint": -3.0}
## A figure this close to the camera is not drawn (it would fill the screen from inside).
const NEAR_CAMERA := 0.35

var sfx: Sfx
## id -> {view: CrewView, index, last: Vector3, speed, steps}
var figures := {}

## Per frame. `others` from play_link.gd; `cam` the camera's position.
func update(dt: float, others: Array, cam: Vector3) -> void:
	var seen := {}
	for o: Dictionary in others:
		var id := str(o["id"])
		seen[id] = true
		var fig: Dictionary = figures.get(id, {})
		if fig.is_empty():
			var v := CrewView.new()
			v.name = "Crew_%s" % id
			add_child(v)
			fig = {"view": v, "index": -1, "last": Vector3.INF, "speed": 0.0, "steps": 0.0}
			figures[id] = fig
		var view: CrewView = fig["view"]
		var index := int(o["index"])
		if index != int(fig["index"]):
			fig["index"] = index
			view.set_skin(index % 4)
			view.set_headwear(HEADWEAR[index % 3])
			view.set_number(index + 1)
		var pos := Vector3(float(o["x"]), float(o["y"]), float(o["z"]))
		var last: Vector3 = fig["last"]
		var sp := float(fig["speed"])
		if last != Vector3.INF and dt > 0.0:
			var d := Vector2(pos.x - last.x, pos.z - last.z).length()
			if d < 2.0:
				sp = lerpf(sp, d / dt, minf(1.0, dt * 10.0))
			else:
				sp = 0.0  # a ride or a placement, not a walk
		fig["last"] = pos
		fig["speed"] = sp
		var gait := str(o["gait"])
		view.set_body(pos, float(o["yaw"]))
		view.set_gait(GAITS.get(gait, &"walk"), sp)
		view.set_raised(bool(o["raised"]))
		view.set_downed(str(o["status"]) == "caught")
		view.visible = Vector2(pos.x - cam.x, pos.z - cam.z).length() > NEAR_CAMERA or absf(pos.y - cam.y) > 2.5
		# Footsteps, from where they are.
		if sp > CrewView.MOVING and str(o["status"]) == "ok" and sfx != null:
			var steps := float(fig["steps"]) + sp * dt / float(STEP_LEN.get(gait, 0.75))
			if steps >= 1.0:
				steps -= floorf(steps)
				sfx.step_at(pos + Vector3(0, 0.05, 0), float(STEP_DB.get(gait, -8.0)))
			fig["steps"] = steps
		else:
			fig["steps"] = 0.5
	for id: String in figures.keys():
		if not seen.has(id):
			(figures[id]["view"] as Node).queue_free()
			figures.erase(id)

func play_emote(id: String, which: String) -> void:
	var fig: Dictionary = figures.get(id, {})
	if not fig.is_empty():
		(fig["view"] as CrewView).play_emote(StringName(which))

func clear() -> void:
	for id: String in figures.keys():
		(figures[id]["view"] as Node).queue_free()
	figures.clear()

## What a test sees of one figure: drawn or not, the clip playing, downed, the emote on.
func describe(id: String) -> Dictionary:
	var fig: Dictionary = figures.get(id, {})
	if fig.is_empty():
		return {}
	var v: CrewView = fig["view"]
	return {"drawn": v.visible and v.is_visible_in_tree(), "at": [v.position.x, v.position.y, v.position.z], "clip": v.clip, "emote": String(v.emote), "downed": v.downed, "raised": v.raised,
		"index": fig["index"], "speed": fig["speed"], "gait": String(v.gait)}
