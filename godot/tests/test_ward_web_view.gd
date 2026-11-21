# WC1 on screen (client/ward/web_view.gd, client/ward/view.gd, client/ward/floor.gd):
#   1. the caught player's sequence runs on the host's times: the grab holds the camera where it was, the pull draws it
#      out along the arm and rolls it upside down in grey, then the main scene's watch view is asked for (DV1's
#      watch_crewmate) after defer_watching, and stop_watching when cut free, in that order; without those hooks the
#      screen holds the grey, upside-down view at the hang point; cut free, the grey peels away;
#   2. the HUD's words for the called lift (every floor's where true; no clock);
#   3. the cocoon is a solid wrapped shape hanging about two metres under its tie, not a flat picture.
extends RefCounted

const T = preload("res://tests/t.gd")
const WebView = preload("res://client/ward/web_view.gd")
const WardView = preload("res://client/ward/view.gd")
const WardFloor = preload("res://client/ward/floor.gd")

class Stub extends RefCounted:
	var calls: Array[String] = []
	func defer_watching() -> void:
		calls.append("defer_watching")
	func watch_crewmate() -> void:
		calls.append("watch_crewmate")
	func stop_watching() -> void:
		calls.append("stop_watching")

func _run(w: WebView, row: Variant, from: float, to: float, eye: Transform3D, limb: Array, hang: Vector3) -> void:
	var t := from
	while t <= to + 1e-9:
		w.update(row, t, eye, limb, hang)
		t += 0.05

func test_sequence_calls_the_watch_view_in_order(t: T) -> void:
	var w := WebView.new()
	var stub := Stub.new()
	w.scene = stub
	var eye := Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	var limb := [[5.0, 2.0, 0.0], [2.0, 1.4, 0.0], [0.0, 1.4, 0.0]]
	var row := {"point": 0, "caughtAt": 10.0, "hangAt": 12.0}
	_run(w, row, 10.0, 10.2, eye, limb, Vector3(3, 0, 3))
	t.eq(w.phase, "grab", "the grab first")
	t.check(w.camera() is Transform3D and (w.camera() as Transform3D).origin.distance_to(eye.origin) < 1e-6, "the camera holds where the player looked")
	t.check(w.grab_point().y < eye.origin.y, "the hand closes under the camera")
	_run(w, row, 10.25, 11.2, eye, limb, Vector3(3, 0, 3))
	t.eq(w.phase, "pull", "then the pull")
	var mid: Transform3D = w.camera()
	t.check(mid.origin.x > 0.3, "drawn out along the arm (x %.2f)" % mid.origin.x)
	t.check(w.grey > 0.4 and w.web > 0.4, "going grey, the web closing")
	_run(w, row, 11.25, 12.5, eye, limb, Vector3(3, 0, 3))
	t.eq(w.phase, "held", "then held")
	t.check(w.camera() == null, "the watch view has the camera")
	t.check(absf(w.roll - PI) < 1e-6 and w.grey == 1.0, "upside down and grey")
	_run(w, null, 30.0, 31.0, eye, limb, Vector3(3, 0, 3))
	t.eq(stub.calls, ["defer_watching", "watch_crewmate", "stop_watching"] as Array[String], "the hooks, in order")
	t.check(w.grey < 1e-6 and w.web < 1e-6 and w.phase == "", "cut free: the grey has peeled away")
	t.check(w.camera() == null, "the player's own camera again")
	w.free()

func test_without_the_watch_view_the_screen_holds_upside_down(t: T) -> void:
	var w := WebView.new()
	var eye := Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	var row := {"point": 0, "caughtAt": 0.0, "hangAt": 2.0}
	_run(w, row, 0.0, 3.0, eye, [], Vector3(4, 0, 4))
	t.eq(w.phase, "held", "held")
	var cam: Variant = w.camera()
	t.check(cam is Transform3D and (cam as Transform3D).basis.y.y < 0.0, "upside down")
	t.check(cam is Transform3D and Vector2((cam as Transform3D).origin.x - 4.0, (cam as Transform3D).origin.z - 4.0).length() < 0.2, "at the hang point")
	t.eq(w.calls, ["defer_watching", "watch_crewmate"] as Array[String], "asked for the watch view; none here")
	w.free()

func test_called_lift_words(t: T) -> void:
	t.eq(WardView.called_line({"phase": "unloading"}, "unloading", {}, "a", "X"), "STEP OUT OF THE LIFT", "arrival")
	t.eq(WardView.called_line({"phase": "away"}, "away", {}, "a", "LAMPKEEPERS COTTAGE"), "THE LIFT'S CALL BUTTON IS IN THE LAMPKEEPERS COTTAGE", "away: where to call it")
	t.eq(WardView.called_line({"phase": "coming", "floorsAway": 3}, "away", {}, "a", ""), "LIFT COMING: 3 FLOORS AWAY", "coming")
	t.eq(WardView.called_line({"phase": "boarding", "bellLeft": 12.2}, "boarding", {}, "a", ""), "DOORS CLOSE IN 13   LEFT: BANK   RIGHT: DOWN", "boarding")
	t.eq(WardView.called_line({"phase": "riding"}, "departed", {"boarded": ["a"]}, "a", ""), "ABOARD", "aboard")
	var called := {"phase": "away", "extras": {"called": true}, "lift": {"phase": "away"}, "collectionAt": 600.0}
	t.check(not WardFloor.lift_line(called, 0.0, "a").contains("RETURNS"), "no clock when called: %s" % WardFloor.lift_line(called, 0.0, "a"))
	t.eq(WardFloor.lift_line({"phase": "away", "collectionAt": 600.0}, 0.0, "a"), "LIFT RETURNS IN 10:00", "the clock as before without the call")
	t.eq(WardView.house_words("lampkeepers_cottage"), "LAMPKEEPERS COTTAGE", "a house's name")

func test_cocoon_is_a_solid_shape(t: T) -> void:
	var c := WardView.make_cocoon({})
	var wrap := c.get_node("Wrap") as MeshInstance3D
	t.check(wrap != null and wrap.mesh != null, "a wrapped mesh")
	var box := wrap.mesh.get_aabb()
	t.check(absf(box.size.y - 2.05) < 0.05 and box.end.y <= 0.01, "hangs about 2.05 m under its tie (%s)" % str(box))
	t.check(box.size.x > 0.4 and box.size.z > 0.4, "round: a body's width, not a flat card (%s)" % str(box))
	t.check(c.get_child_count() > 5, "wound with strands")
	c.free()
