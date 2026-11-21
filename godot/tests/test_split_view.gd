# SR1: split reality on one screen (client/split_view.gd), from a hand-made "split" block as the host sends it:
#   1. The tells: a heartbeat and the warm lamp from exposure, none below TELL_FROM, none in false calm, none when the
#      player is out (watching a crewmate shows the true world). The split view never touches the instrument.
#   2. Phantom figure: heard first (its sound plays, the figure is not drawn) until `from`, then drawn standing; once
#      the host marks it gone it flickers false and true.
#   3. Phantom exit: the lift door is drawn where the block says, on the wall's face.
#   4. Wrong face: the crewmate's own figure is hidden, the resident is drawn where they stand, and main.gd is told
#      whose name tag to drop.
extends RefCounted

const T = preload("res://tests/t.gd")
const SplitView = preload("res://client/split_view.gd")
const Split = preload("res://sim/split.gd")
const Run = preload("res://sim/run.gd")
const Places = preload("res://sim/places.gd")
const Floor = preload("res://sim/floor.gd")

const BASE_NEAR := Color(0.62, 0.72, 1.0)
const BASE_BEAM := Color(1.0, 0.90, 0.71)

class Rig:
	var root: Node3D
	var view: SplitView
	var hud: Control
	var crew: OthersView
	var near: OmniLight3D
	var plan: Floor.FloorPlan

	func _init() -> void:
		root = Node3D.new()
		(Engine.get_main_loop() as SceneTree).root.add_child(root)
		hud = Control.new()
		root.add_child(hud)
		view = SplitView.new()
		root.add_child(view)
		view.setup(hud)
		crew = OthersView.new()
		root.add_child(crew)
		near = OmniLight3D.new()
		near.light_color = BASE_NEAR
		root.add_child(near)
		plan = Run.create_run("split-view", ["me"], [Places.CLINIC]).plan

	func frame(block: Variant, now: float, others: Array = [], ok := true, dt := 0.016) -> void:
		crew.update(dt, others, Vector3(0, 1.6, 0))
		view.update(dt, block, now, "orderly", plan, "split-view", [] as Array[String], others, crew, [near, null], BASE_NEAR, BASE_BEAM, ok, Vector3(0, 1.6, 0))

	func done() -> void:
		root.queue_free()

static func sight(kind: String, from: float, gone := -1.0, who := "") -> Dictionary:
	return {"kind": kind, "id": 7, "who": who, "x": 4.0, "y": 0.0, "z": -8.0, "level": 0, "yaw": 0.3, "from": from, "until": from + 10.0, "gone": gone}

func test_tells_follow_exposure_and_stop_in_false_calm(t: T) -> void:
	var r := Rig.new()
	r.frame({"e": 0.05, "calm": false, "sights": []}, 1.0)
	t.check(not r.view.check().heart, "low exposure: no heartbeat")
	t.eq(r.near.light_color, BASE_NEAR, "low exposure: the lamp is its own colour")
	r.frame({"e": 0.8, "calm": false, "sights": []}, 1.0)
	t.check(r.view.heart.stream != null, "the heartbeat is the game's own recording")
	t.check(r.view.check().heart, "exposed: the heartbeat plays")
	t.check(r.near.light_color.r >= BASE_NEAR.r and r.near.light_color.b < BASE_NEAR.b, "exposed: the lamp is warmer")
	var fast := r.view.heart.pitch_scale
	r.frame({"e": 0.4, "calm": false, "sights": []}, 1.0)
	t.check(r.view.heart.pitch_scale < fast, "less exposed: a slower heart")
	var peak := 0.0
	for k in 120:
		r.frame({"e": 0.8, "calm": false, "sights": []}, 1.0)
		peak = maxf(peak, r.view.check().pulse)
	t.check(peak > 0.0, "the edge pulse beats")
	r.frame({"e": 0.95, "calm": true, "sights": []}, 1.0)
	var c := r.view.check()
	t.check(not c.heart and c.pulse == 0.0 and r.near.light_color == BASE_NEAR, "false calm: the heart stops, the picture is clean")
	r.frame({"e": 0.8, "calm": false, "sights": []}, 1.0, [], false)
	t.check(not r.view.check().heart, "out and watching: no tells")
	var src := FileAccess.get_file_as_string("res://client/split_view.gd")
	t.check(not src.contains("InstrumentView") and not src.contains("inst_view"), "the split view never reaches the instrument")
	r.done()

func test_phantom_heard_first_then_seen_then_revealed(t: T) -> void:
	var r := Rig.new()
	r.frame({"e": 0.8, "calm": false, "sights": [sight("phantom", 10.0)]}, 9.0)
	var c := r.view.check()
	t.check(c.drawn.get("heard", false) and not c.drawn.get("seen", true), "before its time: heard, not seen")
	t.check(not c.figure, "the figure is not drawn yet")
	t.check(r.view.cue.stream != null, "it makes its own sound")
	r.frame({"e": 0.8, "calm": false, "sights": [sight("phantom", 10.0)]}, 10.5)
	c = r.view.check()
	t.check(c.figure and c.drawn.get("seen", false), "then it stands there, drawn")
	t.check(r.view.figure is OrderlyView, "the Clinic's phantom is the Orderly's own figure")
	t.check(absf(r.view.figure.position.x - 4.0) < 1e-4 and absf(r.view.figure.position.z + 8.0) < 1e-4, "where the host put it")
	r.frame({"e": 0.8, "calm": false, "sights": [sight("phantom", 10.0, 11.0)]}, 11.02)
	t.check(not r.view.check().figure, "touched: it flickers off")
	r.frame({"e": 0.8, "calm": false, "sights": [sight("phantom", 10.0, 11.0)]}, 11.1)
	t.check(r.view.check().figure, "and on")
	r.frame({"e": 0.8, "calm": false, "sights": []}, 12.0)
	t.check(not r.view.check().figure, "then gone")
	r.done()

func test_phantom_exit_drawn(t: T) -> void:
	var r := Rig.new()
	r.frame({"e": 0.8, "calm": false, "sights": [sight("exit", 1.0)]}, 2.0)
	t.check(r.view.exit_door != null and r.view.exit_door.visible, "the lift door is drawn")
	t.check(Vector2(r.view.exit_door.position.x - 4.0, r.view.exit_door.position.z + 8.0).length() < 0.2, "on the wall the host chose")
	r.frame({"e": 0.8, "calm": false, "sights": []}, 3.0)
	t.check(not r.view.exit_door.visible, "and gone with the sight")
	r.done()

func test_wrong_face_hides_the_crewmate(t: T) -> void:
	var r := Rig.new()
	var others := [{"id": "b", "index": 1, "status": "ok", "x": 3.0, "y": 0.0, "z": -5.0, "level": 0, "yaw": 0.2, "pitch": 0.0, "gait": "walk", "raised": false}]
	r.frame({"e": 0.8, "calm": false, "sights": []}, 1.0, others)
	var mate: Node3D = r.crew.figures["b"]["view"]
	t.check(mate.visible, "the crewmate drawn as themselves")
	r.frame({"e": 0.8, "calm": false, "sights": [sight("face", 1.0, -1.0, "b")]}, 2.0, others)
	t.check(not mate.visible, "wrong face: their own figure is hidden")
	t.eq(r.view.masked(), "b", "and their name tag goes")
	t.check(r.view.check().figure and absf(r.view.figure.position.x - 3.0) < 1e-4, "the resident is drawn where they stand")
	r.frame({"e": 0.8, "calm": false, "sights": []}, 3.0, others)
	t.check(mate.visible and r.view.masked() == "" and not r.view.check().figure, "after it, themselves again")
	r.done()
